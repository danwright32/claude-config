#!/usr/bin/env bash
# The placement report, lib/ai-review-placement.py (claude-config#1368).
#
# A finding the review runner cannot place by its quoted line keeps the number it cited and carries
# `[review harness: not placed, <why>, ...]`. Whether a quote or path should be matched more loosely
# was meant to be decided by how often each reason happens, and the first two counts (2026-10-23 and
# 2026-10-24) were made by a script nobody kept. This report is that count, kept: it reads the
# finished reviews in the state folder, counts findings, the not placed ones by reason (the reason
# read back by the runner's own classifier, so a reason it writes cannot fall outside the report's
# kinds), and how the placed ones were placed, from the `placement=` value newer reviews record.
#
# The fixtures are invented review files in a throwaway state folder; nothing here reads the real
# one or starts a review.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$DIR/lib/ai-review-placement.py"

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: $3"; fi }
check_not(){ if [[ "$3" != *"$2"* ]]; then ok; else bad "$1"; echo "  must not contain: $2"; echo "  actual: $3"; fi }

if [ ! -f "$REPORT" ]; then
  echo "FAIL: no report at $REPORT"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.placement.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "test-ai-review-placement: refusing to run: throwaway directory came back as '$WORK'." >&2; exit 2 ;;
esac
trap 'rm -rf "$WORK"' EXIT
STATE="$WORK/state"
mkdir -p "$STATE"
S=" Should be: fix it. [severity: major]"
mark(){ printf ' [review harness: not placed, %s, so line %s is the reviewer'"'"'s own number, unchecked]' "$1" "$2"; }

# A whole branch review that records how its placed findings were placed: two placed, one whose
# path is not a file, one whose quote matched nothing after the marker and part of a line were tried.
{
  printf 'repo=r\nsha=a\nstarted=2000\nfinished=2010\nstatus=ok\nkind=pr\nfindings=4\nplacement=whole:1,marker:0,part:1,path:1,unplaced:2\n\n'
  printf 'src/a.ts:3: one.%s\n' "$S"
  printf 'docs/b.md:9: two.%s\n' "$S"
  printf 'suites/src/a.ts:4: three.%s%s\n' "$S" "$(mark 'suites/src/a.ts is not a file at the reviewed head' 4)"
  printf 'src/a.ts:5: four.%s%s\n' "$S" "$(mark 'its quote matches no line of src/a.ts at the reviewed head, as given or without its leading +, whole or in part: "+ x"' 5)"
} > "$STATE/1-pr-a.txt"
# A push review written before reviews recorded placement=: one finding with no quote, and one
# whose reason is none the runner gives today, which must be counted as other, never dropped.
{
  printf 'repo=r\nsha=b\nstarted=3000\nfinished=3020\nstatus=ok\n\n'
  printf 'Note: a line that is not a finding.\n'
  printf 'src/c.ts:2: five.%s%s\n' "$S" "$(mark 'it quoted no line' 2)"
  printf 'src/c.ts:3: six.%s%s\n' "$S" "$(mark 'some reason from a later runner' 3)"
} > "$STATE/1-b.txt"
# A clean review: counted as a review, adding no finding.
printf 'repo=r\nsha=f\nstarted=4000\nfinished=4005\nstatus=ok\nkind=pr\nfindings=0\nplacement=whole:0,marker:0,part:0,path:0,unplaced:0\n\nNo issues found.\n' > "$STATE/1-pr-f.txt"
# Not a review: a run that failed, whose body only quotes finding shaped text.
printf 'repo=r\nsha=c\nstarted=2500\nfinished=2600\nstatus=error\n\nsrc/a.ts:1: x.%s%s\n' "$S" "$(mark 'it quoted no line' 1)" > "$STATE/1-c.txt"
# A review started before the window asked for.
printf 'repo=r\nsha=d\nstarted=500\nfinished=600\nstatus=ok\nkind=pr\n\nsrc/a.ts:1: x.%s%s\n' "$S" "$(mark 'its Quote line was empty' 1)" > "$STATE/1-pr-d.txt"
# Files beside the reviews that are not reviews.
printf 'read\n' > "$STATE/1-pr-a.txt.prread"
printf 'x\tpr\n' > "$STATE/citations.tsv"

out="$(TZ=America/New_York python3 "$REPORT" --state-dir "$STATE" --since 1000 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "a window holding reviews exits 0 (got $rc): $out"
check "it counts the finished reviews in the window, by kind" "reviews: 3 (pr 2, push 1)" "$out"
check "it counts every finding line" "findings: 6" "$out"
check "placed is findings less the marked ones, with its share" "placed: 2 (33.3%)" "$out"
check "not placed has its share" "not placed: 4 (66.7%)" "$out"
check "a path that is not a file is its own reason" "the cited path is not a file at the reviewed head: 1" "$out"
check "a quote matching nothing is its own reason, with what was tried" "its quote matches no line: 1 (retried without a leading + or -: 1, tried as part of a line: 1, too short for part of a line: 0)" "$out"
check "no quote at all is its own reason" "it quoted no line: 1" "$out"
check "an empty Quote line outside the window is not counted" "its Quote line was empty: 0" "$out"
check "a reason the runner does not give is counted as other, never dropped" "other: 1" "$out"
check "how the placed ones were placed comes from the reviews that record it, saying how many do" "how placed, from the 2 of 3 reviews that record it: whole line 1, without the diff's marker 0, part of a line 1, path corrected 1" "$out"
check "it says when the window starts and what it covers" "started at or after 1969-12-31 19:16 EST" "$out"
check "and when the reviews in it finished" "finished 1969-12-31 19:33 EST to 1969-12-31 20:06 EST" "$out"

all="$(TZ=America/New_York python3 "$REPORT" --state-dir "$STATE" 2>&1)"
check "with no window every finished review counts" "reviews: 4 (pr 3, push 1)" "$all"
check "and the earlier review's reason with it" "its Quote line was empty: 1" "$all"

# A window can be given as a date and time, read on this Mac's clock.
dated="$(TZ=America/New_York python3 "$REPORT" --state-dir "$STATE" --since "1969-12-31 19:40" 2>&1)"
check "a window given as a local date and time is read as one" "reviews: 2 (pr 1, push 1)" "$dated"
bad_since="$(python3 "$REPORT" --state-dir "$STATE" --since "last tuesday" 2>&1)"; rc=$?
[ "$rc" -eq 64 ] && ok || bad "a window it cannot read is refused with 64 (got $rc): $bad_since"

# Nothing to count is said as unmeasured, never as a rate of zero (L90).
mkdir -p "$WORK/empty"
none="$(python3 "$REPORT" --state-dir "$WORK/empty" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok || bad "a folder with no finished review exits 2 (got $rc)"
check "and says it measured nothing" "UNMEASURED" "$none"
check_not "with no rate" "%" "$none"
# Reviews but no findings: the count of reviews, and no rate.
mkdir -p "$WORK/clean"
cp "$STATE/1-pr-f.txt" "$WORK/clean/"
clean="$(python3 "$REPORT" --state-dir "$WORK/clean" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "reviews with no findings still exit 0 (got $rc)"
check "and say there is no rate to give" "no findings, so no rate" "$clean"
check_not "rather than a rate of zero" "%" "$clean"
missing="$(python3 "$REPORT" --state-dir "$WORK/nowhere" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok || bad "a state folder that does not exist exits 2 (got $rc)"
check "and names it" "$WORK/nowhere" "$missing"

echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
