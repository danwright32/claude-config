#!/usr/bin/env bash
# Tests for lib/push-gate-report.py, the reader of the push gate ledger (claude-config#1075, #1077):
# a fixture ledger with known counts, read back, every figure checked against what was written.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$DIR/lib/push-gate-report.py"
pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

L="$TMPROOT/push-gates.tsv"
NOW=2000000000
# finished host gate outcome repo head call model wall ms cost bytes started detail
row() { printf '%s\th\t%s\t%s\t/r\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" >> "$L"; }
t=$((NOW - 3600))
# simplify: 4 passes, 2 blocks (c5, c6), 1 timeout, 1 no source, 1 override of the blocked commit c5.
for i in 1 2 3 4; do row "$((t + 20))" simplify pass "c$i" "id$i" haiku 10 9000 0.01 5000 "$t" ""; done
row "$((t + 20))" simplify block c5 id5 haiku 12 11000 0.01 5000 "$t" "unused|dead-code"
row "$((t + 20))" simplify block c6 id6 haiku 14 13000 0.01 5000 "$t" "debug-left"
row "$((t + 90))" simplify failopen c7 id7 haiku 90 "" "" 5000 "$t" "judge timed out after 90s"
row "$t" simplify nosource c8 id8 "" "" "" "" "" "$t" ""
row "$((t + 100))" simplify override c5 id9 "" "" "" "" "" "$((t + 100))" ""
# tests: judged on id1..id5 (overlapping simplify's calls on id1..id4, not on id5), plus id10 alone.
for i in 1 2 3 4; do row "$((t + 30))" tests pass "c$i" "id$i" sonnet 30 29000 0.05 9000 "$t" ""; done
row "$((t + 200))" tests block c5 id5 sonnet 30 29000 0.05 9000 "$((t + 170))" "the x change"
row "$((t + 30))" tests pass c10 id10 sonnet 30 29000 0.05 9000 "$t" ""
# Outside a 30 day window, and a line nothing can read.
row "$((NOW - 40 * 86400))" simplify block old idold haiku 10 9000 0.01 5000 "$((NOW - 40 * 86400))" "old"
printf 'garbage line\n' >> "$L"

out="$(python3 "$REPORT" --ledger "$L" --now "$NOW" --days 30 2>&1)"; rc=$?
want() { if grep -Fq -- "$1" <<< "$out"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2: no [$1] in:"; echo "$out"; fi; }
[ "$rc" = 0 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: exit $rc"; }
want "1 lines could not be read" "an unreadable line is named, not dropped"
want "simplify gate (simplify-before-push.sh), judge: haiku" "the simplify gate and its model"
want "reached 9 pushes: judge called on 7, overridden 1, no source 1" "simplify reach counts, the old row left out"
want "of the 7 judged: passed 4, blocked 2 (33% of those it decided), judge failed 1" "simplify verdicts"
want "overridden after a block of the same commit: 1 of 2 blocked commits (UNMEASURED, under 5)" "an override is matched to its block, and a thin rate is not printed as one"
want "judge wall time: median 10s, slowest 90s, over 7 calls" "simplify judge time (10, 10, 10, 10, 12, 14, 90)"
want "judge cost: \$0.06 in all, \$0.0100 a call, from the 6 calls that reported one" "simplify cost"
want "could not decide 1 times: judge timed out after 90s" "fail open reasons"
want "tests gate (require-tests-before-push.sh), judge: sonnet" "the test gate"
want "both judges on one push: 5 of the 8 pushes either judge was called on (62%); their calls overlapped in time on 4 of those 5" "co-firing and overlap"

# No ledger yet: said plainly, exit 0, never an empty report that reads as a quiet gate.
out="$(python3 "$REPORT" --ledger "$TMPROOT/none.tsv" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: a missing ledger exits $rc"; }
want "No push gate record on" "a missing ledger is said"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
