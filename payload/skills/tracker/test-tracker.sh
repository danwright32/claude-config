#!/usr/bin/env bash
# Tests for the tracker skill (claude-config#675).
#
# The skill's Apps Script write token was committed in plain text, in SKILL.md and in
# config.example.json, in a public repository. The token now lives only in
# config.local.json, which never leaves the Mac that holds it, and tracker.sh refuses by
# name when that file is missing or still holds a placeholder.
#
# Every run happens on a COPY of the skill in a throwaway directory, with a fake curl on
# PATH that records what it was asked and reaches nothing (L2). Every token here is
# invented by this file; no real one is read, printed or passed anywhere.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
case "${TMP%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$TMP'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
check() { # check <description> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then ok; else
    bad "$1"; echo "  expected to contain: $2"; echo "  actual: $3"
  fi
}
check_not() { # check_not <description> <forbidden-substring> <actual>
  if [[ "$3" != *"$2"* ]]; then ok; else bad "$1 (output should not contain '$2')"; fi
}
check_eq() { # check_eq <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi
}

# --- the shipped files hold no token ----------------------------------------
# A token is a long run of letters AND digits. Bounded by anything that is not part of an
# identifier, so the sheet id in SKILL.md (which carries a hyphen) is not one, and the
# placeholders (which carry underscores) are not either. Every file the skill ships is
# read, never a list of the ones that held it last time (L96). config.local.json is the
# one file that is meant to hold it, and it never ships.
shipped_secret_lines(){ # $1 = a skill directory; prints file:line for each token shaped run
  python3 - "$1" <<'PY'
import os, re, sys
root = sys.argv[1]
shape = re.compile(r"(?<![A-Za-z0-9_-])[A-Za-z0-9]{32,}(?![A-Za-z0-9_-])")
for name in sorted(os.listdir(root)):
    p = os.path.join(root, name)
    if name == "config.local.json" or not os.path.isfile(p):
        continue
    for i, line in enumerate(open(p, errors="ignore").read().splitlines(), 1):
        for m in shape.finditer(line):
            v = m.group(0)
            if re.search(r"[0-9]", v) and re.search(r"[A-Za-z]", v):
                print("%s:%d" % (name, i))
PY
}
found="$(shipped_secret_lines "$DIR")"
check_eq "no shipped file in the tracker skill holds a token shaped value (file:line listed, value never printed)" "" "$found"
# The control (L1): the scan finds a token where one is planted, so its silence above means something.
mkdir -p "$TMP/planted"
# Assembled from two halves so this file never holds a token shaped run of its own.
printf '{ "url": "x", "token": "%s%s" }\n' "Ab3dEf6hIj9kLm2n" "Op5qRs8tUv1wXy4zAb7cDe0f" > "$TMP/planted/config.example.json"
printf 'kept local\n' > "$TMP/planted/config.local.json"
check_eq "and the same scan finds a planted one, while ignoring config.local.json" "config.example.json:1" "$(shipped_secret_lines "$TMP/planted")"

# The example must still be a template the skill can fill: both keys present, both placeholders.
example_keys="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(sorted(d)))' "$DIR/config.example.json" 2>&1)"
check_eq "config.example.json carries url and token" "token,url" "$example_keys"

# --- config.local.json never travels ------------------------------------------
# Git: the skill's own ignore file keeps it out of every commit.
check "the skill's .gitignore names config.local.json" "config.local.json" "$(cat "$DIR/.gitignore" 2>/dev/null)"

# --- a sandbox copy of the skill, and a curl that reaches nothing -------------
SK="$TMP/skill"
mkdir -p "$SK" "$TMP/bin"
cp "$DIR/tracker.sh" "$DIR/config.example.json" "$DIR/apps-script.gs" "$SK/"
CURL_LOG="$TMP/curl.log"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Records its arguments and whatever arrived on stdin, then answers like the web app.
{ printf 'ARGS:'; printf ' %s' "$@"; printf '\n'; printf 'STDIN:'; cat; printf '\n'; } >> "$CURL_LOG"
printf '{"ok":true}'
STUB
chmod +x "$TMP/bin/curl"
export CURL_LOG

GOOD_URL="https://script.google.com/macros/s/FAKEDEPLOYMENT/exec"
GOOD_TOKEN="test_token_0123456789_abcdef_not_real"
write_local(){ # write_local <url> <token>
  python3 -c 'import json,sys; json.dump({"url":sys.argv[2],"token":sys.argv[3]}, open(sys.argv[1],"w"))' "$SK/config.local.json" "$1" "$2"
}
run(){ # run <args...>; sets OUT and RC
  : > "$CURL_LOG"
  OUT="$(PATH="$TMP/bin:$PATH" bash "$SK/tracker.sh" "$@" 2>&1)"
  RC=$?
}
curl_calls(){ grep -c '^ARGS:' "$CURL_LOG" 2>/dev/null || true; }
EX_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$DIR/config.example.json")"
EX_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$DIR/config.example.json")"
GS_TOKEN="$(sed -n "s/^const TOKEN = '\\(.*\\)';.*/\\1/p" "$DIR/apps-script.gs")"
check "the Apps Script placeholder could be read from apps-script.gs" "REPLACE" "$GS_TOKEN"

# --- the positive control first (L159): a configured skill does reach curl ---
write_local "$GOOD_URL" "$GOOD_TOKEN"
run headers
check_eq "a configured skill's headers call succeeds" 0 "$RC"
check_eq "and reaches curl exactly once" 1 "$(curl_calls)"
check "and asks the configured web app" "FAKEDEPLOYMENT" "$(cat "$CURL_LOG")"
check_not "and never puts the token on curl's command line" "$GOOD_TOKEN" "$(grep '^ARGS:' "$CURL_LOG")"
run append '{"Project Name":"x"}'
check_eq "a configured skill's append succeeds" 0 "$RC"
check_eq "and reaches curl exactly once" 1 "$(curl_calls)"
check "and sends the token in the request body" "\"token\": \"$GOOD_TOKEN\"" "$(grep '^STDIN:' "$CURL_LOG")"
check "and the row with it" '"Project Name": "x"' "$(grep '^STDIN:' "$CURL_LOG")"
check_not "and never puts the token on curl's command line" "$GOOD_TOKEN" "$(grep '^ARGS:' "$CURL_LOG")"

# --- every refusal names its cause, and reaches nothing -----------------------
refuses(){ # refuses <description> <expected words in the message> <args...>
  local d="$1" want="$2"; shift 2
  run "$@"
  if [ "$RC" -ne 0 ]; then ok; else bad "$d: exits non zero (got $RC)"; fi
  check "$d: says why" "$want" "$OUT"
  check_eq "$d: reaches nothing" 0 "$(curl_calls)"
  check_not "$d: never prints the configured token" "$GOOD_TOKEN" "$OUT"
}

rm -f "$SK/config.local.json"
refuses "no config.local.json" "config.local.json is missing" headers
refuses "no config.local.json, on append" "config.local.json is missing" append '{"a":1}'

cp "$DIR/config.example.json" "$SK/config.local.json"
refuses "config.local.json copied straight from the example" "placeholder" headers
check "and it names the url" "url" "$OUT"

write_local "$EX_URL" "$GOOD_TOKEN"
refuses "the example's url placeholder" "url" headers
check "and calls it a placeholder" "placeholder" "$OUT"

write_local "$GOOD_URL" "$EX_TOKEN"
refuses "the example's token placeholder" "token" headers
check "and calls it a placeholder" "placeholder" "$OUT"

write_local "$GOOD_URL" "$GS_TOKEN"
refuses "the Apps Script's own placeholder token" "token" append '{"a":1}'
check "and calls it a placeholder" "placeholder" "$OUT"

write_local "$GOOD_URL" ""
refuses "an empty token" "token" headers
check "and calls it empty" "empty" "$OUT"

python3 -c 'import json,sys; json.dump({"url":sys.argv[2]}, open(sys.argv[1],"w"))' "$SK/config.local.json" "$GOOD_URL"
refuses "a config with no token key" "token" headers

printf '{ not json' > "$SK/config.local.json"
refuses "a config that is not JSON" "config.local.json" headers
check "and says it could not be read" "could not be read" "$OUT"

# The placeholders are read from the shipped files, so a missing one cannot be judged.
write_local "$GOOD_URL" "$GOOD_TOKEN"
mv "$SK/apps-script.gs" "$TMP/apps-script.gs.aside"
refuses "with apps-script.gs missing, placeholders cannot be checked" "apps-script.gs" headers
mv "$TMP/apps-script.gs.aside" "$SK/apps-script.gs"

# --- new-token writes a fresh token without ever showing it -------------------
rm -f "$SK/config.local.json"
run new-token
check_eq "new-token with no config.local.json succeeds" 0 "$RC"
check_eq "and reaches nothing" 0 "$(curl_calls)"
check "and says where the token went" "config.local.json" "$OUT"
NEWTOK="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$SK/config.local.json" 2>/dev/null)"
NEWURL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$SK/config.local.json" 2>/dev/null)"
if [ "${#NEWTOK}" -ge 32 ]; then ok; else bad "new-token writes a token of at least 32 characters (got ${#NEWTOK})"; fi
if [ -n "$NEWTOK" ] && [ "$NEWTOK" != "$EX_TOKEN" ] && [ "$NEWTOK" != "$GS_TOKEN" ]; then ok; else bad "new-token writes a token that is not a placeholder"; fi
if [ -n "$NEWTOK" ] && [[ "$OUT" != *"$NEWTOK"* ]]; then ok; else bad "new-token never prints the token it wrote"; fi
check_eq "and the file is readable by its owner only" "600" "$(python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$SK/config.local.json" 2>&1)"
check_eq "and the url is still the example's, waiting to be filled" "$EX_URL" "$NEWURL"
refuses "a fresh token with the url still a placeholder" "url" headers

write_local "$GOOD_URL" "$GOOD_TOKEN"
run new-token
NEWTOK2="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$SK/config.local.json" 2>/dev/null)"
NEWURL2="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$SK/config.local.json" 2>/dev/null)"
check_eq "new-token over an existing config succeeds" 0 "$RC"
if [ -n "$NEWTOK2" ] && [ "$NEWTOK2" != "$GOOD_TOKEN" ]; then ok; else bad "new-token replaces the old token"; fi
check_eq "and keeps the configured url" "$GOOD_URL" "$NEWURL2"
check_not "and never prints the old token" "$GOOD_TOKEN" "$OUT"
run headers
check_eq "and the skill works with the new token" 0 "$RC"

printf '{ not json' > "$SK/config.local.json"
run new-token
if [ "$RC" -ne 0 ]; then ok; else bad "new-token over an unreadable config refuses rather than overwriting it"; fi
check_eq "and leaves that file as it was" "{ not json" "$(cat "$SK/config.local.json")"

echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
