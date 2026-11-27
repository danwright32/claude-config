#!/usr/bin/env bash
# Tests for lib/command-screen.sh (claude-config#3690): cs_may_name answers no only for a command
# whose letters, as the shell reader reads them, cannot spell any word asked about. A no lets a gate
# leave before its python3 starts, so a no on a command the reader would judge is a gate passing
# what it exists to stop. The gates' own suites pin their decisions; these pin the reading.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/command-screen.sh"

pass=0
fail=0
PR='*[pP][rR]*'
COMMIT='*[cC][oO][mM][mM][iI][tT]*'

# may <description> <yes|no> <command> <pattern>...
may() {
  local desc="$1" want="$2" cmd="$3" got=no
  shift 3
  cs_may_name "$cmd" "$@" && got=yes
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $desc (wanted $want, got $got)"; fi
}

may "a plain pr is a yes" yes 'gh pr create --title x' "$PR"
may "a quote inside the word is a yes, as the reader joins it" yes "gh p''r create" "$PR"
may "a double quoted word is a yes" yes 'gh "pr" create' "$PR"
may "a backslash inside the word is a yes" yes 'gh p\r create' "$PR"
may "a backslash and a line break inside the word is a yes" yes $'gh p\\\nr create' "$PR"
may "a carriage return inside the word is a yes" yes $'gh p\\\r\nr create' "$PR"
may "upper case is a yes" yes 'gh PR create' "$PR"
may "any \$ is a yes, as an expansion can spell anything" yes 'X=p; gh ${X}r create' "$PR"
may "a bare \$ word is a yes" yes 'echo $HOME' "$PR"
may "a backtick is a yes" yes 'echo `id`' "$PR"
may "the second pattern is asked too" yes "git co''mmit -m x" "$PR" "$COMMIT"
may "uptime; date is a no" no 'uptime; date' "$PR" "$COMMIT"
may "a quoted sed range is a no" no "sed -n '40,57p' /tmp/notes.txt" "$PR" "$COMMIT"
may "a grep with a quoted word is a no" no 'grep -n "timeout" /tmp/x.json | head -20' "$PR" "$COMMIT"
may "a line break that parts no word is a no" no $'ls\nwc -l /tmp/x' "$PR" "$COMMIT"

# No program to remove quotes with is a yes: without tr nothing here can read the command (L42).
got=no
( PATH=/nonexistent; cs_may_name "sed -n '1,2p' /tmp/x" "$PR" ) && got=yes
if [ "$got" = yes ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: with no tr a quoted command is a yes (got $got)"; fi

# Linear in the length of the command. bash 3.2's own ${text//x/} took 4 s of processor time for
# 16 KB on 2026-11-26, and a commit message can be hundreds of KB, so 400 KB with quotes on every
# line must be read in a few seconds, never minutes.
big="$(i=0; while [ "$i" -lt 8000 ]; do printf "echo 'line %s of a long message here, quoted'\n" "$i"; i=$((i + 1)); done)"
[ "${#big}" -gt 300000 ] || { fail=$((fail + 1)); echo "FAIL: the long command is only ${#big} bytes"; }
start=$SECONDS
may "a 300 KB quoted command naming neither is a no" no "$big" "$PR" "$COMMIT"
if [ $((SECONDS - start)) -le 5 ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: the 300 KB command took $((SECONDS - start)) s to screen"; fi
may "the same command with a commit at its end is a yes" yes "$big"$'\ngit commit -m x' "$PR" "$COMMIT"

# cs_cut takes the command from a parsed payload, everything before the first unit separator, as
# ${parsed%%$'\x1f'*} did (review of #3690). That expression is quadratic on bash 3.2 (15 s of
# processor time for a 306 KB command in require-issue-fields.sh, past the hook's limit), so the cut
# is made by read. It must give the old expression's text byte for byte: a byte lost or added is a
# command the screen reads differently from the gate.
# cut_same <description> <parsed>
cut_same() {
  local want="${2%%$'\x1f'*}" rc=0
  CS_COMMAND="left over from an earlier call"
  cs_cut "$2" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$CS_COMMAND" = "$want" ] && [ "${#CS_COMMAND}" -eq "${#want}" ]; then
    pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1 (cut status $rc, ${#CS_COMMAND} characters against ${#want})"; fi
}
cut_same "the cut of a plain command" $'uptime; date\x1f/Users/x/app'
cut_same "the cut keeps single and double quotes" $'echo \'a b\' "c d" p\'\'r\x1f/w'
cut_same "the cut keeps backslashes, a backslash at its end included" $'printf \'%s\\n\' a\\\\b \\\x1f/w'
cut_same "the cut keeps line breaks, one ending the command included" $'ls\nwc -l x\n\n\x1f/w'
cut_same "the cut keeps tabs and carriage returns" $'\tcut -f1\tx\r\n\t\x1f/w'
cut_same "the cut keeps spaces at either end" $'  echo x  \x1f/w'
cut_same "the cut keeps the separator's stand in and other non ASCII" $'echo a\xef\xbf\xbdb caf\xc3\xa9\x1f/w'
cut_same "the cut stops at the first separator when the folder holds another" $'echo x\x1f/w\x1fz\x1f'
cut_same "the cut of an empty command" $'\x1f/w'
cut_same "the cut with an empty folder" $'echo x\x1f'
cut_same "the cut with no separator at all" 'echo x'
cut_same "the cut of nothing" ''
cut_same "the cut of a 300 KB command" "$big"$'\x1f/w'
# The same, for the text ps_parse_payload hands a gate from real payloads holding each of those.
if . "$DIR/lib/push-scope.sh" 2>/dev/null && command -v python3 >/dev/null 2>&1; then
  n=0
  while IFS= read -r p; do
    n=$((n + 1))
    parsed="$(ps_parse_payload "$p" raw)"
    cut_same "the cut of parsed payload $n" "$parsed"
  done < <(python3 -c '
import json
for c in ["echo '"'"'a'"'"' \"b\" \\\\ p'"''"'r\n\tx\r", "tail\x1fhead", "ends with a break\n\n",
          "café \u0000 x \ud800 y", "\\\\\n\\\\"]:
    print(json.dumps({"tool_input": {"command": c}, "cwd": "/w\x1fz"}))
')
  [ "$n" -eq 5 ] || { fail=$((fail + 1)); echo "FAIL: $n parsed payloads were cut, not 5"; }
else
  fail=$((fail + 1)); echo "FAIL: lib/push-scope.sh or python3 is missing, so no parsed payload was cut"
fi

# A read that fails leaves nothing to judge by, so the cut says so rather than handing the screen an
# empty command, which it would answer no to and the gate would leave on.
got=0
( read() { return 1; }; cs_cut $'gh pr create\x1f/w' ) || got=$?
if [ "$got" -ne 0 ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a cut whose read failed must fail, not leave an empty command"; fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
