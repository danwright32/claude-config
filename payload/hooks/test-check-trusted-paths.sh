#!/usr/bin/env bash
# Tests for check-trusted-paths.sh (claude-config#2491).
#
# The autoMode.environment list in each Mac's settings.json tells the auto mode classifier which
# checkouts to trust, by absolute path, and nothing checked those paths still existed. On the work
# MacBook one pointed at a folder gone for two weeks after a project move, so the classifier was told
# to trust a checkout that no longer existed while the real one went unrecognised.
#
# Every path below is invented, under a throwaway directory, and HOME is pointed there too, so a
# tilde entry is expanded against the fixture and never against a real home directory.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$DIR/check-trusted-paths.sh"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.trusted.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-check-trusted-paths: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

FAKEHOME="$TMPROOT/home"
mkdir -p "$FAKEHOME/Apps/Present" "$FAKEHOME/Apps/TildeHere" "$FAKEHOME/My Apps/Spaced"

run() { # run <settings file>   -> stdout and stderr together, exit code kept
  HOME="$FAKEHOME" TRUSTED_PATHS_SETTINGS_FILE="$1" bash "$CHECK" 2>&1
}

# The shape a real settings.json carries: other keys around autoMode, one entry per line, entries
# that are free text with paths inside them in several spellings.
mksettings() { # mksettings <name> <environment entries as JSON lines, comma separated>
  local f="$TMPROOT/$1"
  {
    printf '{\n  "permissions": {\n    "allow": ["Bash(ls:*)"]\n  },\n'
    printf '  "autoMode": {\n    "soft_deny": [],\n    "environment": [\n'
    printf '%s\n' "$2"
    printf '    ]\n  }\n}\n'
  } > "$f"
  printf '%s' "$f"
}

PRESENT_ENTRIES="      \"### Trust\",
      \"**Trusted repo**: \`$FAKEHOME/Apps/Present\` (the working directory)\",
      \"**Tilde repo**: ~/Apps/TildeHere\",
      \"**Spaced repo**: \`$FAKEHOME/My Apps/Spaced\`\",
      \"**Source control**: https://github.com/example/app.git and example/app only\",
      \"**Sensitive data locations**: \`.env*\` files, read/write by the app\""
ALL_PRESENT="$(mksettings present.json "$PRESENT_ENTRIES")"

SOME_GONE="$(mksettings gone.json "$PRESENT_ENTRIES,
      \"**Second repo**: $FAKEHOME/Apps/Gone, moved last week.\",
      \"**Tilde gone**: ~/Apps/TildeGone.\"")"

# ---------------------------------------------------------------------------
# Every path present: nothing said. Tilde and backticked paths with a space in them included,
# because a tilde left unexpanded or a path cut at its space would both read as missing.
# ---------------------------------------------------------------------------
out="$(run "$ALL_PRESENT")"; code=$?
[ "$code" -eq 0 ] && check "a list whose paths are all present exits 0" ok \
  || check "a list whose paths are all present exits 0" "exit=$code, said: $out"
[ -z "$out" ] && check "and says nothing" ok || check "and says nothing" "it said: $out"

# ---------------------------------------------------------------------------
# A missing path is named, with the line of the entry holding it.
# ---------------------------------------------------------------------------
out="$(run "$SOME_GONE")"; code=$?
[ "$code" -eq 1 ] && check "a list with a missing path exits 1" ok \
  || check "a list with a missing path exits 1" "exit=$code, said: $out"
case "$out" in
  *"\`$FAKEHOME/Apps/Gone\`"*) check "the missing absolute path is named" ok ;;
  *) check "the missing absolute path is named" "it said: $out" ;;
esac
gone_line="$(grep -n -F 'Apps/Gone,' "$SOME_GONE" | cut -d: -f1)"
case "$out" in
  *"line $gone_line"*) check "and the line of its entry is named (line $gone_line)" ok ;;
  *) check "and the line of its entry is named (line $gone_line)" "it said: $out" ;;
esac
case "$out" in
  *"Second repo"*) check "and the entry itself is named" ok ;;
  *) check "and the entry itself is named" "it said: $out" ;;
esac
# A missing tilde path is named as written, so the reader can find it in the file.
case "$out" in
  *"\`~/Apps/TildeGone\`"*) check "a missing tilde path is named as written" ok ;;
  *) check "a missing tilde path is named as written" "it said: $out" ;;
esac
# Trailing punctuation in free text is not part of the path. Paths are named in backticks, so the
# entry's own text (which keeps its punctuation) cannot satisfy or spoil this.
case "$out" in
  *"Gone,\`"*|*"TildeGone.\`"*) check "trailing punctuation is not read as part of a path" "it said: $out" ;;
  *) check "trailing punctuation is not read as part of a path" ok ;;
esac
# Present paths, a URL and words with a slash in them are never named.
for absent in "Apps/Present" "TildeHere" "Spaced" "github.com" "example/app" "read/write" ".env"; do
  case "$out" in
    *"$absent"*) check "a present or non path text ($absent) is not reported" "it said: $out" ;;
    *) check "a present or non path text ($absent) is not reported" ok ;;
  esac
done
lines="$(printf '%s\n' "$out" | grep -c 'is not on this Mac')"
[ "$lines" -eq 2 ] && check "one line per missing path" ok \
  || check "one line per missing path" "counted $lines in: $out"

# ---------------------------------------------------------------------------
# Read only. The settings file is never changed by the check.
# ---------------------------------------------------------------------------
before="$(shasum < "$SOME_GONE")"
run "$SOME_GONE" > /dev/null
after="$(shasum < "$SOME_GONE")"
[ "$before" = "$after" ] && check "the settings file is left unchanged" ok \
  || check "the settings file is left unchanged" "its checksum moved"

# ---------------------------------------------------------------------------
# Nothing to check is nothing said, and never a crash.
# ---------------------------------------------------------------------------
out="$(run "$TMPROOT/no-such-settings.json")"; code=$?
[ "$code" -eq 0 ] && [ -z "$out" ] && check "a missing settings file is silent and exits 0" ok \
  || check "a missing settings file is silent and exits 0" "exit=$code, said: $out"

NOAUTO="$TMPROOT/noauto.json"
printf '{\n  "permissions": {"allow": ["Bash(ls:*)"]}\n}\n' > "$NOAUTO"
out="$(run "$NOAUTO")"; code=$?
[ "$code" -eq 0 ] && [ -z "$out" ] && check "settings with no autoMode block are silent" ok \
  || check "settings with no autoMode block are silent" "exit=$code, said: $out"

ODD="$TMPROOT/odd.json"
printf '{"autoMode": {"environment": "not a list"}}\n' > "$ODD"
out="$(run "$ODD")"; code=$?
[ "$code" -eq 0 ] && check "an environment that is not a list does not crash" ok \
  || check "an environment that is not a list does not crash" "exit=$code, said: $out"
ODD2="$TMPROOT/odd2.json"
printf '{"autoMode": {"environment": [3, null, {"a": "/nowhere/at/all"}]}}\n' > "$ODD2"
out="$(run "$ODD2")"; code=$?
[ "$code" -eq 0 ] && [ -z "$out" ] && check "non text entries are skipped without a crash" ok \
  || check "non text entries are skipped without a crash" "exit=$code, said: $out"

NOPATHS="$(mksettings nopaths.json "      \"**Organization**: None configured\",
      \"**Source control**: https://github.com/example/app.git only\",
      \"50 / 50 split, and/or either\"")"
out="$(run "$NOPATHS")"; code=$?
[ "$code" -eq 0 ] && [ -z "$out" ] && check "entries holding no path are silent" ok \
  || check "entries holding no path are silent" "exit=$code, said: $out"

# JSON can spell a lone surrogate (\udcff), which Python decodes into a string no encoder will write.
# A missing path holding one must still be reported, not end in a traceback on the way out.
SURR="$(mksettings surrogate.json "      \"Checkout at \`/nowhere/caf\\udcff/app\`\"")"
out="$(run "$SURR")"; code=$?
[ "$code" -eq 1 ] && check "a missing path holding a lone surrogate exits 1" ok \
  || check "a missing path holding a lone surrogate exits 1" "exit=$code, said: $out"
case "$out" in
  *Traceback*) check "and is reported without a traceback" "it said: $out" ;;
  *"/nowhere/caf"*) check "and is reported without a traceback" ok ;;
  *) check "and is reported without a traceback" "it did not name the path: $out" ;;
esac

BROKEN="$TMPROOT/broken.json"
printf '{\n  "autoMode": {\n    "environment": [\n      "/x",\n  }\n' > "$BROKEN"
out="$(run "$BROKEN")"; code=$?
[ "$code" -eq 2 ] && check "an unparsable settings file exits 2" ok \
  || check "an unparsable settings file exits 2" "exit=$code, said: $out"
case "$out" in
  *Traceback*) check "and says so without a traceback" "it said: $out" ;;
  *"$BROKEN"*) check "and says so without a traceback" ok ;;
  *) check "and says so without a traceback" "it did not name the file: $out" ;;
esac
n="$(printf '%s\n' "$out" | grep -c .)"
[ "$n" -eq 1 ] && check "in one line" ok || check "in one line" "$n lines: $out"

# ---------------------------------------------------------------------------
# A check that cannot run says so rather than passing for silence (L98).
# ---------------------------------------------------------------------------
BASH_BIN="$(command -v bash)"
out="$(HOME="$FAKEHOME" TRUSTED_PATHS_SETTINGS_FILE="$SOME_GONE" PATH="$TMPROOT/empty-path" "$BASH_BIN" "$CHECK" 2>&1)"; code=$?
[ "$code" -eq 3 ] && check "with no python3 it exits 3" ok \
  || check "with no python3 it exits 3" "exit=$code, said: $out"
case "$out" in
  *python3*) check "and names what it could not find" ok ;;
  *) check "and names what it could not find" "it said: $out" ;;
esac

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
