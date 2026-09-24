#!/usr/bin/env bash
# Tests for tools/lessons-core-proposal.py, which turns the evidence into the list Dan approves
# (claude-config#563). Every decision it can make has a fixture that produces it (L151): core because
# no review can see it, core on probation, core by rank, library by rank, and undecided at the cut.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/lessons-core-proposal.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1500}"; fi; }
check_rc(){ if [ "$3" = "$2" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected exit $2, got $3)"; fi; }
dec(){ awk -F '\t' -v k="$2" '$1 == k { print $7 }' "$1"; }

IDX="$WORK/idx"; mkdir -p "$IDX"
{
  printf '# Lessons index: Proof\n\n'
  for n in 1 2 3 4 5 6 7 8; do printf -- '- L%s. Lesson number %s says something worth a line of about sixty chars.\n' "$n" "$n"; done
} > "$IDX/LESSONS-INDEX-proof.md"
# Counts from ONE Mac: L3 is cited most, then L4, L5, L6; L7 never.
printf 'HOST mac-a DAYS 60 READ 100 UNREAD 0\nL1\t1\t1\t0\nL3\t30\t40\t2\nL4\t20\t25\t0\nL5\t10\t12\t0\nL6\t5\t5\t0\nL8\t9\t9\t0\nEND\n' > "$WORK/counts-a.txt"
# Ages: L8 is ten days old; the rest are old enough.
printf 'L1\t2026-07-01\t85\nL2\t2026-07-01\t85\nL3\t2026-07-01\t85\nL4\t2026-07-01\t85\nL5\t2026-07-01\t85\nL6\t2026-07-01\t85\nL7\t2026-07-01\t85\nL8\t2026-09-14\t10\nEND\n' > "$WORK/ages.txt"
# Tags: L1 operate, L2 design, the rest diff.
printf 'L1\toperate\nL2\tdesign\nL3\tdiff\nL4\tdiff\nL5\tdiff\nL6\tdiff\nL7\tdiff\nL8\tdiff\nEND 8 lessons tagged\n' > "$WORK/tags.txt"

run(){ python3 "$TOOL" --index-dir "$IDX" --counts "$WORK/counts-a.txt" --ages "$WORK/ages.txt" --tags "$WORK/tags.txt" \
  --expect-hosts mac-a,mac-b --out-tsv "$WORK/out.tsv" --out-html "$WORK/out.html" "$@" 2>&1; }

# A budget with room for the mandatory four plus two ranked ones, with a band of one either side.
# Probation asked for explicitly: it is off by default since 2026-09-24, and still an outcome.
out="$(run --budget 440 --band 1 --probation-days 30)"; rc=$?
check_rc "the proposal is written" 0 "$rc"
check "an operate lesson is core whatever its rank" "core-unreviewable" "$(dec "$WORK/out.tsv" L1)"
check "a design lesson is core whatever its rank" "core-unreviewable" "$(dec "$WORK/out.tsv" L2)"
check "a young lesson is core on probation" "core-probation" "$(dec "$WORK/out.tsv" L8)"
check "the most cited diff lesson is core by rank" "core-ranked" "$(dec "$WORK/out.tsv" L3)"
check "the least cited is left to the library" "library" "$(dec "$WORK/out.tsv" L7)"
check "a lesson next to the cut is undecided" "undecided" "$(dec "$WORK/out.tsv" L5)"
check "the summary gives the core's size" "core size" "$out"
page="$(cat "$WORK/out.html")"
check "the page names the Mac whose counts are missing" "mac-b" "$page"
check "and says its counts are unmeasured" "UNMEASURED" "$page"
check "the page shows each lesson's own line" "Lesson number 3 says" "$page"
check "the page is a complete document" "<!doctype html>" "$page"

# Mandatory lessons alone over budget: said plainly, and the decision is Dan's.
out="$(run --budget 100 --band 1)"
check "a core over budget before any ranking is said plainly" "OVER BUDGET" "$out"
check "and the page says so too" "OVER BUDGET" "$(cat "$WORK/out.html")"

# A SECOND TAGGING PASS (Dan, 2026-09-24: audit the design and operate tags). Where the passes
# disagree the lesson keeps loading (core, the safe side) and is listed as disputed with both tags,
# for Dan to settle. L3 is diff in pass one and design in pass two; L2 is design in both.
# L1 is operate then design: both unreviewable, so the decision does not depend on which, and it is
# NOT a dispute for Dan to settle.
printf 'L1\tdesign\nL2\tdesign\nL3\tdesign\nL4\tdiff\nL5\tdiff\nL6\tdiff\nL7\tdiff\nL8\tdiff\nEND\n' > "$WORK/tags2.txt"
out="$(run --budget 440 --band 1 --second-tags "$WORK/tags2.txt")"
check "a lesson the passes disagree on stays in the core" "core-disputed" "$(dec "$WORK/out.tsv" L3)"
check "one they agree on is decided as before" "core-unreviewable" "$(dec "$WORK/out.tsv" L2)"
check "design against operate is not a dispute: both keep it loading" "core-unreviewable" "$(dec "$WORK/out.tsv" L1)"
check "the summary counts the disputes" "1 disputed" "$out"
check "the page lists the disputed lesson with both tags" "diff, then design" "$(cat "$WORK/out.html")"

# Probation off BY DEFAULT (Dan, 2026-09-24): with no flag, a young diff lesson is ranked like the rest.
out="$(run --budget 440 --band 1)"
check "with probation off no lesson is on probation" "0 on probation" "$out"
l8="$(dec "$WORK/out.tsv" L8)"
case "$l8" in core-ranked|undecided|library) pass=$((pass + 1)) ;; *) fail=$((fail + 1)); echo "FAIL: with probation off the young lesson is ranked (got '$l8')" ;; esac

# A lesson with no tag is refused, never defaulted, since the tag decides whether it loads.
printf 'L1\toperate\nEND\n' > "$WORK/tags-short.txt"
out="$(python3 "$TOOL" --index-dir "$IDX" --counts "$WORK/counts-a.txt" --ages "$WORK/ages.txt" --tags "$WORK/tags-short.txt" --out-tsv "$WORK/o.tsv" --out-html "$WORK/o.html" 2>&1)"; rc=$?
check_rc "untagged lessons refuse the proposal" 1 "$rc"
check "naming them" "UNTAGGED" "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
