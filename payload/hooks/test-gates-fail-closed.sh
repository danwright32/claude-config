#!/usr/bin/env bash
# The class guard for claude-config#1900: a gate allows nothing it could not read.
#
# Two ways a gate allowed what it could not read, each found in one hook and then swept:
#
#   1. A library sourced with `|| exit 0`. With the file missing, or cut short, the gate exited 0 on
#      every call, which looks exactly like a call with nothing to refuse (L10, L1033). Every
#      PreToolUse hook that can refuse is read here, from the settings that register it, and a
#      source of a library under lib/ followed by a bare `exit 0` or `return 0` fails. A library
#      that sources another must say when that one did not load, or it reports itself loaded
#      with half its functions missing. Each gate is then run with each library it sources taken
#      away, and must refuse the command it judges, naming the file, and pass any other.
#
#   2. A python3 reader taking its stdin in text mode. Under a UTF-8 locale a byte that is not UTF-8
#      raises there, where jq reads it as U+FFFD, so a payload jq reads was unreadable to the python3
#      half of the same gate. Every hook and library here reads stdin through its buffer, decoded
#      with errors="replace", and this fails on the next one that does not.
#
# The gates the second half of 1 runs are a table, since each judges a different command. Every
# gate the first half finds must be in it, so a gate added later is not exempt by being unlisted
# (L96).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gfc.XXXXXXXX")" || exit 1
case "${WORK%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;; esac
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }

if [ -z "$SETTINGS" ] || [ ! -f "$SETTINGS" ]; then
  echo "test-gates-fail-closed: no settings file beside $DIR names which hooks are registered, so no gate could be enumerated." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs settings.hooks.json or settings.json one level above the hooks"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 2
fi

# ---------------------------------------------------------------------------
echo "every gate refuses when a library it sources cannot be loaded (claude-config#1900)"

# The PreToolUse hooks that can refuse: registered there, and holding an exit 2 somewhere.
python3 - "$SETTINGS" > "$WORK/pre" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
seen = set()
for g in d.get("hooks", {}).get("PreToolUse", []):
    for h in g.get("hooks", []):
        m = re.search(r"hooks/([A-Za-z0-9_.-]+\.sh)", h.get("command", ""))
        if m and m.group(1) not in seen:
            seen.add(m.group(1))
            print(m.group(1))
PY
GATES=()
while IFS= read -r g; do
  [ -f "$DIR/$g" ] && grep -q 'exit 2' "$DIR/$g" && GATES+=("$g")
done < "$WORK/pre"
[ "${#GATES[@]}" -ge 20 ] && ok || bad "only ${#GATES[@]} refusing PreToolUse gates were found in $SETTINGS, so the enumeration is reading the wrong thing"

# A source line whose failure branch is a bare exit 0 or return 0, on the line itself or on the
# continuation line after a backslash.
SRC_RE='^[[:space:]]*(\{[[:space:]]*)?(\.|source)[[:space:]]+"[^"]*lib/[^"]+\.sh"'
ALLOW_RE='\|\|[[:space:]]*(exit|return)[[:space:]]+0([^0-9]|$)'
# The patterns travel in the environment: awk -v reads backslash escapes and would turn \| into |.
allowing_sources(){ # allowing_sources <file> -> file:line of each library source that allows on failure
  SRC="$SRC_RE" ALLOW="$ALLOW_RE" awk -v f="$1" '
    BEGIN { src = ENVIRON["SRC"]; allow = ENVIRON["ALLOW"] }
    prev != "" { if ($0 ~ "^[[:space:]]*" allow) print f ":" prevn ": " prev; prev = "" }
    $0 ~ src {
      if ($0 ~ allow) print f ":" NR ": " $0
      else if ($0 ~ /\\$/) { prev = $0; prevn = NR }
    }' "$1"
}
found=""
for g in "${GATES[@]}"; do found="$found$(allowing_sources "$DIR/$g")"; done
if [ -z "$found" ]; then ok; else bad "a gate allows every call when a library it sources cannot be loaded:
$found"; fi

# A library a gate sources, sourcing another with nothing after it, carries on with that one's
# functions missing, and the gate that sourced it reads it as loaded.
bare=""
for l in $(for g in "${GATES[@]}"; do grep -E "$SRC_RE" "$DIR/$g" | grep -o -E 'lib/[a-z-]+\.sh'; done | sort -u); do
  [ -f "$DIR/$l" ] || continue
  bare="$bare$(grep -n -E '^(\.|source)[[:space:]]+"[^"]+\.sh"[[:space:]]*$' "$DIR/$l" | sed "s#^#$l:#")"
done
if [ -z "$bare" ]; then ok; else bad "a library a gate sources sources another without saying when it did not load:
$bare"; fi

# The scan is seen to fire on the shapes the hooks held before this change.
printf '%s\n' '. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0' > "$WORK/probe1"
printf '%s\n' '. "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null \' '  || exit 0' > "$WORK/probe2"
printf '%s\n' '. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || not_judged "x"' > "$WORK/probe3"
[ -n "$(allowing_sources "$WORK/probe1")" ] && ok || bad "the scan does not fire on a one line source that exits 0"
[ -n "$(allowing_sources "$WORK/probe2")" ] && ok || bad "the scan does not fire on a source continued onto an exit 0"
[ -z "$(allowing_sources "$WORK/probe3")" ] && ok || bad "the scan fires on a source whose failure branch refuses"

# The behaviour, gate by gate: the command each judges, and the override it honours (or -). A gate
# that allows with exit 1 by recorded decision says so in its third field, with its issue: that
# exit is the only one whose message Claude Code shows while letting the call run (#735, #1065),
# and #1912 holds those four.
declare_gate(){ printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
{
  declare_gate payload-write-gate.sh       "echo hi > payload/LESSONS.md"   SKIP_PAYLOAD_WRITE_CHECK
  declare_gate check-style-guide.sh        "git push origin feature"        SKIP_STYLE_CHECK
  declare_gate check-grep-quiet-invert.sh  "git push origin feature"        SKIP_GREP_QV_CHECK
  declare_gate check-duplication.sh        "git push origin feature"        SKIP_DUPLICATION_CHECK
  declare_gate check-deferrals.sh          "git push origin feature"        SKIP_DEFERRAL_CHECK
  declare_gate check-doc-issue-refs.sh     "git push origin feature"        SKIP_DOC_REFS_CHECK
  declare_gate check-bundle-budget.sh      "git push origin feature"        SKIP_BUNDLE_BUDGET_CHECK
  declare_gate linux-sections-before-push.sh "git push origin feature"      SKIP_LINUX_CHECK
  declare_gate scanners-before-push.sh     "git push origin feature"        SKIP_SCANNERS_CHECK
  declare_gate push-scope-notice.sh        "git push origin feature"        -
  declare_gate check-add-scope.sh          "git add -A"                     SKIP_ADD_SCOPE_CHECK
  declare_gate check-closing-keyword.sh    "git commit -m 'does not close #4'" SKIP_CLOSING_CHECK
  declare_gate block-red-merge.sh          "gh pr merge 5 --squash"         ALLOW_RED_MERGE
  declare_gate check-closing-merge.sh      "gh pr merge 5 --squash"         SKIP_CLOSING_CHECK
  declare_gate require-changelog-tag.sh    "gh pr merge 5 --squash"         ALLOW_UNTAGGED_MERGE
  declare_gate require-verification-run.sh "gh pr merge 5 --squash"         ALLOW_UNVERIFIED_MERGE
  declare_gate design-score-gate.sh        "gh pr merge 5 --squash"         -
  declare_gate check-rtk-init.sh           "rtk init -g"                    -
  declare_gate stacked-branch-delete-gate.sh "git push origin :feat/x"      -
  declare_gate check-wrapped-commands.sh   "eval \$CMD && git status"       -
  declare_gate pr-review-gate.sh           "cat x/helper-key"               -
  declare_gate require-tests-before-push.sh  "git push origin feature"      "exit1 #1065"
  declare_gate simplify-before-push.sh       "git push origin feature"      "exit1 #1065"
  declare_gate check-public-assets.sh        "git push origin feature"      "exit1 #735"
  declare_gate check-gh-watch-interval.sh    "gh run watch 5"               "exit1 #1065"
} > "$WORK/table"

payload_for(){ # payload_for <command> <cwd>
  python3 -c 'import json, sys; print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2], "session_id": "s"}))' "$1" "$2"
}
# The libraries a gate needs, and, for each, the libraries that one sources in turn. Left out are
# the ones it sources as optional, whose absence it carries on past: `|| true`, or a bare `. x &&`
# that only turns a feature on (scanners-before-push.sh's pid lock), since the gate then goes on to
# judge the command with what it has.
libs_of(){ # libs_of <gate file>
  local l
  grep -E "$SRC_RE" "$1" | grep -v -E '\|\|[[:space:]]*true' \
    | grep -v -E '^[[:space:]]*\.[^|]*&&[^|]*$' | grep -o -E 'lib/[a-z-]+\.sh' | sort -u | while IFS= read -r l; do
    printf '%s\n' "${l#lib/}"
    [ -f "$DIR/$l" ] && grep -E '^(\.|source)[[:space:]]+"\$[A-Za-z_]+/[a-z-]+\.sh"' "$DIR/$l" | grep -o -E '/[a-z-]+\.sh' | sed 's#^/##'
  done | sort -u
}

# Each run is fed from a file rather than a pipe from python3, which a gate leaving early would
# kill, and in a folder named by a number: a folder named after the gate or the library would put
# push, merge or payload into the payload's cwd and so into every command's raw text.
run_gate(){ # run_gate <gate copy> <command> <cwd> -> OUT and RC
  payload_for "$2" "$3" > "$WORK/in.json"
  OUT="$( cd "$3" && bash "$1" < "$WORK/in.json" 2>&1 )"; RC=$?
}
n=0
for g in "${GATES[@]}"; do
  grep -q -E "$SRC_RE" "$DIR/$g" || continue
  row="$(awk -F '\t' -v g="$g" '$1 == g' "$WORK/table")"
  if [ -z "$row" ]; then
    bad "$g sources a library and can refuse, and is not in this suite's table, so nothing runs it with that library gone"
    continue
  fi
  IFS=$'\t' read -r _ judged override <<< "$row"
  want=2
  case "$override" in exit1*) want=1 ;; esac
  for lib in $(libs_of "$DIR/$g"); do
    n=$((n + 1))
    T="$WORK/$n"
    mkdir -p "$T/repo"
    cp "$DIR/$g" "$T/$g"
    cp -R "$DIR/lib" "$T/lib"
    rm -f "$T/lib/$lib"
    run_gate "$T/$g" "$judged" "$T/repo"
    if [ "$RC" -eq "$want" ]; then ok; else bad "$g with lib/$lib missing: '$judged' should exit $want, exited $RC, said: ${OUT:0:200}"; fi
    # Named by the file, or for the gates that allow with exit 1 by the library's own name. A
    # library missing beneath another is reported as the one the gate sourced, which is what failed
    # to load from where the gate stands.
    named=0
    case "$OUT" in *"${lib%.sh}"*) named=1 ;; esac
    for d in $(grep -E "$SRC_RE" "$DIR/$g" | grep -o -E 'lib/[a-z-]+\.sh' | sort -u); do
      case "$OUT" in *"$d"*) named=1 ;; esac
    done
    [ "$named" -eq 1 ] && ok || bad "$g with lib/$lib missing: the message should name the library that did not load, said: ${OUT:0:200}"
    [ "$want" -eq 2 ] || continue
    run_gate "$T/$g" "ls -la" "$T/repo"
    if [ "$RC" -eq 0 ]; then ok; else bad "$g with lib/$lib missing: a command it does not judge should pass, exited $RC, said: ${OUT:0:200}"; fi
    if [ "$override" != "-" ]; then
      run_gate "$T/$g" "$override=1 $judged" "$T/repo"
      if [ "$RC" -eq 0 ]; then ok; else bad "$g with lib/$lib missing: its override $override=1 should still pass the command, exited $RC, said: ${OUT:0:200}"; fi
    fi
  done
done

# ---------------------------------------------------------------------------
echo "every python3 reader of stdin reads what jq reads (claude-config#1900)"

# Measured first, so a red below is about the hooks and not this machine: python3 reading its stdin
# in text mode under en_US.UTF-8 raises on a byte that is not UTF-8.
if printf 'a\xffb' | LC_ALL=en_US.UTF-8 python3 -c 'import sys; sys.stdin.read()' 2>/dev/null; then
  echo "SUITE-PART-UNMEASURED #1900 python3 text mode stdin under en_US.UTF-8 here reads a byte that is not UTF-8 without raising, so the fault this guards is not shown on this machine"
else ok; fi
# And the form every reader uses reads it.
if [ "$(printf 'a\xffb' | LC_ALL=en_US.UTF-8 python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8", "replace")))')" = "3" ]; then ok
else bad "sys.stdin.buffer.read().decode(\"utf-8\", \"replace\") did not read a byte that is not UTF-8 as one character"; fi

# Text mode stdin: .read(), iterating it, json.load on it, or handing it on as a file.
TEXT_RE='sys\.stdin\.read\(|json\.load\(sys\.stdin\)|in sys\.stdin([^.]|$)|return sys\.stdin[[:space:]]*$|sys\.stdin\.readline'
text_reads(){ # text_reads <file>... -> file:line of each text mode read of stdin
  grep -n -E "$TEXT_RE" "$@" 2>/dev/null
}
files=()
for f in "$DIR"/*.sh "$DIR"/*.py "$DIR"/lib/*.sh "$DIR"/lib/*.py; do
  case "$(basename "$f")" in test-*|test_*) continue ;; esac
  files+=("$f")
done
hits="$(text_reads "${files[@]}" | sed "s#^$DIR/##")"
if [ -z "$hits" ]; then ok; else bad "a python3 reader takes stdin in text mode, which raises on a byte jq reads as U+FFFD; read sys.stdin.buffer and decode with errors=\"replace\":
$hits"; fi
printf '%s\n' '    d = json.load(sys.stdin)' 'for line in sys.stdin:' 'x = sys.stdin.read()' > "$WORK/probe-py"
[ "$(text_reads "$WORK/probe-py" | wc -l | tr -d ' ')" = "3" ] && ok || bad "the stdin scan does not fire on each of the three shapes the hooks held"
printf '%s\n' 'x = sys.stdin.buffer.read().decode("utf-8", "replace")' > "$WORK/probe-py2"
[ -z "$(text_reads "$WORK/probe-py2")" ] && ok || bad "the stdin scan fires on the buffered read it asks for"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
