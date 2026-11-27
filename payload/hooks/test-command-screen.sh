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

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
