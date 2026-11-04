#!/usr/bin/env bash
# Tests for lib/wrapped-refusal-report.py, the reader of the record check-wrapped-commands.sh keeps of
# every refusal (claude-config#1492): a fixture record with known counts, read back, every figure
# checked against what was written.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$DIR/lib/wrapped-refusal-report.py"
pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "test-wrapped-refusal-report: python3 is not on PATH, so nothing was verified." >&2; exit 2; }

L="$TMPROOT/refusals.tsv"
NOW=2000000000
row() { printf '%s\tmac\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$L"; }
t=$((NOW - 3600))
# In a 7 day window: bash -c variable refused 3 and overridden 1; bash script-file refused 2;
# eval eval-cd overridden 1; sh input refused 1, two days back.
row "$t" "bash -c" variable refused
row "$t" "bash -c" variable refused
row "$t" "bash -c" variable refused
row "$t" "bash -c" variable overridden
row "$t" bash script-file refused
row "$t" bash script-file refused
row "$t" eval eval-cd overridden
row "$((NOW - 2 * 86400))" sh input refused
# Outside the window, and lines nothing can read: too few fields, an outcome nobody writes, no time.
row "$((NOW - 9 * 86400))" "bash -c" variable refused
printf 'garbage line\n' >> "$L"
row "$t" bash input maybe
row "soon" bash input refused

out="$(python3 "$REPORT" --ledger "$L" --now "$NOW" --days 7 2>&1)"; rc=$?
want() { if grep -Fq -- "$1" <<< "$out"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2: no [$1] in:"; echo "$out"; fi; }
lacks() { if grep -Fq -- "$1" <<< "$out"; then fail=$((fail+1)); echo "FAIL: $2: [$1] in:"; echo "$out"; else pass=$((pass+1)); fi; }
[ "$rc" = 0 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: exit $rc"; }
want "the last 7 days" "the window is named"
want "8 refusals: 6 refused, 2 overridden" "the totals, the old line left out"
want "3 lines could not be read and are not counted" "an unreadable line is named, not dropped"
want "4  bash -c, variable: refused 3, overridden 1" "the commonest shape, with its overrides"
want "2  bash, script-file: refused 2, overridden 0" "a second shape"
want "1  eval, eval-cd: refused 0, overridden 1" "an override only shape"
want "1  sh, input: refused 1, overridden 0" "a shape from two days back"
# Most first, so the shape to look at is the first line read.
order="$(grep -m 1 -E '^ +[0-9]+  ' <<< "$out")"
case "$order" in *"bash -c, variable"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL: the commonest shape is not first: $order" ;; esac
want "the record runs from" "how far back the record goes is said, so a short window is not read as a quiet gate"

# A wider window takes the old line in.
out="$(python3 "$REPORT" --ledger "$L" --now "$NOW" --days 30 2>&1)"
want "9 refusals: 7 refused, 2 overridden" "a 30 day window counts the old line"
want "5  bash -c, variable: refused 4, overridden 1" "and counts it under its shape"

# A record with nothing in the window says so, never an empty table that reads as a broken reader.
L2="$TMPROOT/quiet.tsv"
printf '%s\tmac\tbash\tinput\trefused\n' "$((NOW - 20 * 86400))" > "$L2"
out="$(python3 "$REPORT" --ledger "$L2" --now "$NOW" --days 7 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: a quiet window exits $rc"; }
want "No refusal in the last 7 days" "a quiet window is said"
want "the record runs from" "with how far back the record goes"

# No record yet: said plainly, exit 0, and told apart from a quiet window.
out="$(python3 "$REPORT" --ledger "$TMPROOT/none.tsv" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: a missing record exits $rc"; }
want "No wrapped command refusal recorded on" "a missing record is said"
lacks "No refusal in the last" "and is not reported as a quiet window"

# The default record is this Mac's own, under ~/.claude/state, which the sync never carries, and
# WRAPPED_REFUSAL_LEDGER_DIR moves it, as it moves the gate's.
out="$(env -u WRAPPED_REFUSAL_LEDGER_DIR HOME="$TMPROOT/home" python3 "$REPORT" 2>&1)"
want "$TMPROOT/home/.claude/state/wrapped-commands/refusals.tsv" "the default record is under ~/.claude/state"
out="$(WRAPPED_REFUSAL_LEDGER_DIR="$TMPROOT/elsewhere" python3 "$REPORT" 2>&1)"
want "$TMPROOT/elsewhere/refusals.tsv" "the seam moves it"

# An unreadable record is an error, never a quiet report.
mkdir -p "$TMPROOT/isdir.tsv"
out="$(python3 "$REPORT" --ledger "$TMPROOT/isdir.tsv" 2>&1)"; rc=$?
[ "$rc" = 1 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: an unreadable record exits $rc: $out"; }
want "could not read" "and says so"

# The fail closed suite's own refusals (claude-config#2157). Until #2155, a direct run of
# test-gates-fail-closed.sh wrote "eval, reader-lib-missing" refusals into the real record: one per
# run while the gate loaded one library (before #1963, merged 1793406500), two in the same second or
# a second apart after it. Those are skipped, only in that shape and only before #2155 merged
# (1793743801); every other row counts, so a real refusal is never lost to the rule. Times are
# written out of order, as nothing promises the record is sorted.
L3="$TMPROOT/suite.tsv"
: > "$L3"
srow() { printf '%s\tmac\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$L3"; }
srow 1793500000 eval reader-lib-missing refused          # a pair a second apart: skipped
srow 1793500100 eval reader-lib-missing refused          # a pair in one second: skipped
srow 1793500100 eval reader-lib-missing refused
srow 1793350000 eval reader-lib-missing refused          # alone, before #1963: skipped
srow 1793500001 eval reader-lib-missing refused          # the first pair's second half, written late
srow 1793600000 eval reader-lib-missing refused          # alone, after #1963: counts
srow 1793500200 eval reader-lib-missing refused          # three in a burst: counts
srow 1793500200 eval reader-lib-missing refused
srow 1793500201 eval reader-lib-missing refused
srow 1793750000 eval reader-lib-missing refused          # a pair after #2155: counts
srow 1793750001 eval reader-lib-missing refused
srow 1793500300 eval reader-lib-missing overridden       # a pair overridden: counts
srow 1793500300 eval reader-lib-missing overridden
srow 1793500400 bash reader-lib-missing refused          # a pair under another wrapper: counts
srow 1793500400 bash reader-lib-missing refused
srow 1793500500 eval reader-lib-missing refused          # two seconds apart: counts
srow 1793500502 eval reader-lib-missing refused
srow 1793500600 eval reader-lib-missing refused          # beside another shape: both count
srow 1793500600 "bash -c" variable refused
printf 'eval\treader-lib-missing\n' >> "$L3"             # unreadable: said, as ever
out="$(python3 "$REPORT" --ledger "$L3" --now 1793800000 --days 30 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: #2157 exit $rc: $out"; }
want "14 refusals: 12 refused, 2 overridden" "#2157 only the suite's own shape is left out of the totals"
want "11  eval, reader-lib-missing: refused 9, overridden 2" "#2157 every eval, reader-lib-missing row outside that shape counts"
want "2  bash, reader-lib-missing: refused 2, overridden 0" "#2157 another wrapper with that reason counts"
want "1  bash -c, variable: refused 1, overridden 0" "#2157 a row beside the shape counts"
want "5 lines are the fail closed suite's own test refusals and are not counted" "#2157 the report says how many it skipped"
want "before 2026-11-03 17:10 ET (#2155" "#2157 and states the cutoff it skipped them by"
want "claude-config#2157" "#2157 and names where the rule is recorded"
want "1 lines could not be read and are not counted" "#2157 an unreadable line is still said"
# A window holding none of them says nothing about them.
out="$(python3 "$REPORT" --ledger "$L3" --now 1793800000 --days 1 2>&1)"
want "2 refusals: 2 refused, 0 overridden" "#2157 a window after the cutoff counts its pair"
lacks "test refusals" "#2157 and names no skipped line it does not hold"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
