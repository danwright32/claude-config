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
# processor time for a 306 KB command in require-issue-fields.sh on 2026-11-27, past the hook's
# limit), so the cut
# is made from the end, or by read when the folder holds the byte too. Either way it must give the
# old expression's text byte for byte: a byte lost or added is a command the screen reads
# differently from the gate.
# cut_same <description> <parsed> [<the command, where the row built it: the old expression is itself quadratic>]
cut_same() {
  local want="${3-${2%%$'\x1f'*}}" rc=0
  CS_COMMAND="left over from an earlier call"
  cs_cut "$2" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$CS_COMMAND" = "$want" ] && [ "${#CS_COMMAND}" -eq "${#want}" ]; then
    pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1 (cut status $rc, ${#CS_COMMAND} characters against ${#want})"; fi
}
cut_same "the cut of a plain command" $'uptime; date\x1f/w/app'
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
cut_same "the cut of a 300 KB command" "$big"$'\x1f/w' "$big"
cut_same "the cut of a 300 KB command whose folder holds the separator" "$big"$'\x1f/w\x1fz' "$big"
# The same, for the text ps_parse_payload hands a gate from real payloads holding each of those.
if . "$DIR/lib/push-scope.sh" 2>/dev/null && command -v python3 >/dev/null 2>&1; then
  n=0
  # Written to a file and read back, never through a process substitution, whose child nothing waits for.
  PAYLOADS="$(mktemp)"
  python3 -c '
import json
for c in ["echo '"'"'a'"'"' \"b\" \\\\ p'"''"'r\n\tx\r", "tail\x1fhead", "ends with a break\n\n",
          "caf" + chr(233) + " \u0000 x \ud800 y", "\\\\\n\\\\"]:
    for cwd in ("/w", "/w\x1fz"):
        print(json.dumps({"tool_input": {"command": c}, "cwd": cwd}))
' > "$PAYLOADS"
  while IFS= read -r p; do
    n=$((n + 1))
    parsed="$(ps_parse_payload "$p" raw)"
    cut_same "the cut of parsed payload $n" "$parsed"
  done < "$PAYLOADS"
  rm -f "$PAYLOADS"
  [ "$n" -eq 10 ] || { fail=$((fail + 1)); echo "FAIL: $n parsed payloads were cut, not 10"; }
else
  fail=$((fail + 1)); echo "FAIL: lib/push-scope.sh or python3 is missing, so no parsed payload was cut"
fi

# Cheap on a large command that names the word, which every command a gate judges does (review of
# #3690). The first cut by read cost 0.4 s of processor time on 431 KB under bash 3.2, which reads
# with -d one byte per system call, and so did the scan for a $ and the tr the screen made before
# looking for the word: together more than the gate's own work, so the hook was slower than main on
# exactly the commands it reads. Timed by bash's own clock, best of three, against one scan of the
# same text, which grows with the text and with the machine alike: the cut and the screen may cost
# six such scans and 20 ms more. On 2026-11-27 one scan of this text was 18 ms, the cut and screen
# 52 ms, and the cut by read with the screen as it was 279 ms.
# ms_of <time output "U S">: processor milliseconds
ms_of() { local u="${1% *}" s="${1#* }"; echo $(( 10#${u/./} + 10#${s/./} )); }
# A function, since bash 3.2 cannot parse a case inside $( ).
scan_once() { case "$1" in *'`'*) return 0 ;; esac; return 1; }
TIMEFORMAT='%3U %3S'
yes_parsed="gh issue comment 12 --body-file x.md && $big"$'\x1f/w'
scan_ms=999999; work_ms=999999
for _ in 1 2 3; do
  t="$( { time scan_once "$yes_parsed"; } 2>&1 )"
  [ "$(ms_of "$t")" -lt "$scan_ms" ] && scan_ms="$(ms_of "$t")"
  t="$( { time { cs_cut "$yes_parsed" && cs_may_name "$CS_COMMAND" '*[iI][sS][sS][uU][eE]*' "$PR"; }; } 2>&1 )"
  [ "$(ms_of "$t")" -lt "$work_ms" ] && work_ms="$(ms_of "$t")"
done
unset TIMEFORMAT
if [ "$work_ms" -le $((6 * scan_ms + 20)) ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: the cut and the screen of a 300 KB command naming issue cost $work_ms ms, over six scans of it ($scan_ms ms each) and 20 ms"; fi

# A word already whole in the command is a yes before tr is started: a tr that records each start
# is never started for it, and is for a command whose word only a removed quote joins.
TR_LOG="$(mktemp -d)"
printf '#!/bin/sh\necho started >> "%s/log"\nexec "%s" "$@"\n' "$TR_LOG" "$(command -v tr)" > "$TR_LOG/tr"
chmod +x "$TR_LOG/tr"
( PATH="$TR_LOG:$PATH"; cs_may_name "gh issue comment 1 --body 'a \"b\"'" '*[iI][sS][sS][uU][eE]*' "$PR" )
if [ ! -s "$TR_LOG/log" ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a command naming issue whole, with quotes in it, started tr"; fi
( PATH="$TR_LOG:$PATH"; cs_may_name "gh is''sue comment 1" '*[iI][sS][sS][uU][eE]*' "$PR" )
if [ -s "$TR_LOG/log" ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: control: a word only a removed quote joins must start tr, so the row above can fail"; fi
rm -rf "$TR_LOG"

# A read that fails leaves nothing to judge by, so the cut says so rather than handing the screen an
# empty command, which it would answer no to and the gate would leave on. The folder holds the byte,
# so the cut is made by read.
got=0
( read() { return 1; }; cs_cut $'gh pr create\x1f/w\x1fz' ) || got=$?
if [ "$got" -ne 0 ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a cut whose read failed must fail, not leave an empty command"; fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
