#!/usr/bin/env bash
# Tests for the monthly re-rank of the lessons core (claude-config#566): tools/lessons-core-rerank.py,
# the job that runs it (tools/run-lessons-core-rerank.sh) and its installer
# (tools/install-lessons-core-rerank-schedule.sh).
#
# The re-rank only PROPOSES. Dan's decisions it encodes (2026-09-24, #563): a lesson no PR review can
# see stays in the core whatever its rank; the rest of the core is the most cited reviewable
# lessons; new lessons start in the library and earn their way in by citations. Every outcome the
# tool can reach has a fixture that produces it (L151), and the clock is always injected, so nothing
# here waits on real time or reads a real transcript, a real ~/.claude or real counts (L2, L130).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/lessons-core-rerank.py"
JOB="$DIR/run-lessons-core-rerank.sh"
INSTALL="$DIR/install-lessons-core-rerank-schedule.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-config-rerank.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "test-lessons-core-rerank: refusing to run: throwaway directory came back as '$WORK'." >&2; exit 2 ;;
esac
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1500}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (must not contain '$2')"; echo "  actual: ${3:0:1500}"; fi; }
check_rc(){ if [ "$3" = "$2" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected exit $2, got $3)"; fi; }
# The move a lesson is given in the moves table, or nothing.
move(){ awk -F '\t' -v k="$2" '$2 == k { print $1 }' "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------------------------------
# THE FIXTURE. Twelve lessons; the core today is L1 L2 L3 L4 L5 L12.
#   L1 design, L2 operate: no PR review can see them, in the core, never cited.
#   L12: the two tagging passes disagree (design, then diff), in the core, never cited. Dan settled
#        every dispute as staying in the core (#563).
#   L3 L4 L5: reviewable lessons in the core, so the core has three ranked seats. L3 is cited most;
#        L4 never; L5 a little.
#   L6 L7: reviewable, outside the core, cited a lot, L6 ONLY on mac-b and L7 ONLY on mac-a, so both
#        entering proves the two Macs' counts are added together.
#   L8: design, outside the core, cited above the cut: a new lesson no review can see earns its way in.
#   L9: design, outside the core, barely cited: stays in the library.
#   L10, L11: reviewable, outside the core, below the cut.
# All are 85 days old, so every one is exposed for the whole 60 day window and the rates compare.
# ---------------------------------------------------------------------------------------------------
REPO="$WORK/repo"
IDX="$REPO/payload"; mkdir -p "$IDX" "$REPO/lesson-counts" "$REPO/lesson-bands"
{
  printf '# Lessons index: Proof\n\n'
  for n in 1 2 3 4 5 6 7 8 9 10 11 12; do printf -- '- L%s. Lesson number %s says something worth a line of about sixty chars.\n' "$n" "$n"; done
} > "$IDX/LESSONS-INDEX-proof.md"
printf '# The lessons core\n# count 6\nL1\nL2\nL3\nL4\nL5\nL12\n' > "$IDX/LESSONS-CORE.txt"
# The SEATS (Dan, 2026-10-09: "Keep your 355 protected"): the only core lessons a re-rank may swap.
# Every other core lesson is protected because it is not a seat, whatever its tag.
printf '# The seats\nL3\nL4\nL5\n' > "$REPO/lesson-core-seats.txt"
printf 'L1\tdesign\nL2\toperate\nL3\tdiff\nL4\tdiff\nL5\tdiff\nL6\tdiff\nL7\tdiff\nL8\tdesign\nL9\tdesign\nL10\tdiff\nL11\tdiff\nL12\tdesign\nEND 12 lessons tagged\n' > "$REPO/lesson-tags.tsv"
printf 'L1\tdesign\nL2\toperate\nL3\tdiff\nL4\tdiff\nL5\tdiff\nL6\tdiff\nL7\tdiff\nL8\tdesign\nL9\tdesign\nL10\tdiff\nL11\tdiff\nL12\tdiff\nEND 12 lessons tagged\n' > "$REPO/lesson-tags-second.tsv"
{ for n in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'L%s\t2026-07-16\t85\n' "$n"; done; printf 'END\n'; } > "$WORK/ages.txt"
printf '1\n' > "$REPO/lesson-bands/mac-a"; printf '501\n' > "$REPO/lesson-bands/mac-b"

NOW="2026-10-09T12:00:00Z"
counts(){ # counts <host> <AT stamp or "none"> <rows...>: one Mac's counts file, in lesson-citations.py's format
  local host="$1" at="$2"; shift 2
  local f="$REPO/lesson-counts/$host.tsv"
  if [ "$at" = none ]; then printf 'HOST %s DAYS 60 READ 100 UNREAD 0 EXCLUDED subagent=0 claude-config=0 recording=0 LEDGER read DISMISSED 0\n' "$host" > "$f"
  else printf 'HOST %s DAYS 60 READ 100 UNREAD 0 EXCLUDED subagent=0 claude-config=0 recording=0 LEDGER read DISMISSED 0 AT %s\n' "$host" "$at" > "$f"; fi
  for r in "$@"; do printf '%s\n' "$r" >> "$f"; done
  printf 'END\n' >> "$f"
}
# mac-a: L3 30, L7 20, L8 12, L11 4, L5 2, L9 1.   mac-b: L6 25, L8 10.
fresh_counts(){
  counts mac-a "2026-10-05T09:00:00Z" $'L3\t30\t40\t0' $'L7\t18\t20\t2' $'L8\t12\t12\t0' $'L11\t4\t4\t0' $'L5\t2\t2\t0' $'L9\t1\t1\t0'
  counts mac-b "2026-10-01T11:00:00Z" $'L6\t25\t30\t0' $'L8\t10\t10\t0'
}
fresh_counts
OUT="$WORK/out"; mkdir -p "$OUT"
rerank(){ rm -f "$OUT"/*; python3 "$TOOL" --index-dir "$IDX" --core "$IDX/LESSONS-CORE.txt" --counts-dir "$REPO/lesson-counts" \
  --bands-dir "$REPO/lesson-bands" --ages "$WORK/ages.txt" --tags "$REPO/lesson-tags.tsv" --second-tags "$REPO/lesson-tags-second.tsv" \
  --seats "$REPO/lesson-core-seats.txt" --out-seats "$OUT/seats.txt" \
  --now "$NOW" --band 1 --out-tsv "$OUT/moves.tsv" --out-html "$OUT/rerank.html" --out-list "$OUT/core.txt" "$@" 2>&1; }
seat_list(){ awk '{ sub(/#.*/, ""); for (i = 1; i <= NF; i++) if ($i ~ /^L[0-9]+$/) printf "%s ", $i }' "$1" 2>/dev/null; }
seat_count(){ seat_list "$1" | wc -w | tr -d ' '; }

# 1. MOVES IN AND OUT, from both Macs' counts.
out="$(rerank)"; rc=$?
check_rc "a re-rank with both Macs fresh writes a proposal" 0 "$rc"
check "the most cited reviewable lesson outside the core enters" "in" "$(move "$OUT/moves.tsv" L6)"
check "and so does the next, cited only on the other Mac (both Macs' counts are added)" "in" "$(move "$OUT/moves.tsv" L7)"
check "a reviewable core lesson never cited leaves" "out" "$(move "$OUT/moves.tsv" L4)"
check "and so does one cited less than the lessons replacing it" "out" "$(move "$OUT/moves.tsv" L5)"
check "a new lesson no review can see, cited above the cut, earns its way in" "in" "$(move "$OUT/moves.tsv" L8)"
[ -z "$(move "$OUT/moves.tsv" L9)" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: a barely cited design lesson is given no move (got $(move "$OUT/moves.tsv" L9))"; }
[ -z "$(move "$OUT/moves.tsv" L3)" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: the most cited core lesson stays where it is (got $(move "$OUT/moves.tsv" L3))"; }

# 2. A LESSON NO REVIEW CAN SEE NEVER LEAVES BY RANK, and nor does a disputed one: L1, L2 and L12 are
#    never cited at all, ranking below everything, and still stay.
for l in L1 L2 L12; do
  [ -z "$(move "$OUT/moves.tsv" "$l")" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: $l, which no review can see, is given no move (got $(move "$OUT/moves.tsv" "$l"))"; }
done
list="$(tr '\n' ' ' < "$OUT/core.txt" 2>/dev/null)"
check "the proposed list keeps the design lesson" " L1 " " $list"
check "and the operate lesson" " L2 " " $list"
check "and the disputed lesson" " L12 " " $list"
check "and carries the lessons coming in" " L6 " " $list"
check_not "and drops the lessons going out" " L4 " " $list"
check "the proposed list declares its count, the shape core-set writes" "# count 7" "$(cat "$OUT/core.txt" 2>/dev/null)"

# 2b. ONLY THE SEATS SWAP (Dan, 2026-10-09: "Keep your 355 protected"). Protection is the seats
#     file, not the tags: a core lesson that is not a seat never leaves, whatever both passes call it,
#     so a re-tag can never unprotect an approved lesson.
check "the proposed seats are the seats after the swaps" "L3 L6 L7 " "$(seat_list "$OUT/seats.txt")"
check "and the seat count stays three" "3" "$(seat_count "$OUT/seats.txt")"
check_not "an addition no review can see never takes a seat" "L8" "$(seat_list "$OUT/seats.txt")"
# L10 is called diff by BOTH passes and never cited, so by rank it is the worst lesson there is. It is
# on the approved list but not a seat, so it stays.
printf 'L1\nL2\nL3\nL4\nL5\nL10\nL12\n' > "$WORK/core-approved.txt"
out="$(rerank --core "$WORK/core-approved.txt")"; rc=$?
check_rc "a core holding a protected reviewable lesson still re-ranks" 0 "$rc"
[ -z "$(move "$OUT/moves.tsv" L10)" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: a protected lesson both passes call diff is never proposed out (got $(move "$OUT/moves.tsv" L10))"; }
check "the seats still swap beside it" "out" "$(move "$OUT/moves.tsv" L4)"
check "and the seat count stays three" "3" "$(seat_count "$OUT/seats.txt")"
check "the summary names the protected count, from the seats file" "4 protected" "$out"
# Re-tagged: L1, L2 and L12 called diff by both passes now. Still protected, because still not seats.
printf 'L1\tdiff\nL2\tdiff\nL3\tdiff\nL4\tdiff\nL5\tdiff\nL6\tdiff\nL7\tdiff\nL8\tdesign\nL9\tdesign\nL10\tdiff\nL11\tdiff\nL12\tdiff\n' > "$WORK/tags-all-diff.tsv"
out="$(rerank --core "$WORK/core-approved.txt" --tags "$WORK/tags-all-diff.tsv" --second-tags "$WORK/tags-all-diff.tsv")"; rc=$?
check_rc "a re-tag calling every approved lesson diff still re-ranks" 0 "$rc"
for l in L1 L2 L10 L12; do
  [ -z "$(move "$OUT/moves.tsv" "$l")" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: $l, approved and not a seat, stays whatever its tag (got $(move "$OUT/moves.tsv" "$l"))"; }
done
check "and the seat count stays three" "3" "$(seat_count "$OUT/seats.txt")"
# The cap holds the seats at three too: one swap fits in three moves, with the addition.
out="$(rerank --max-moves 3)"
check "a capped re-rank keeps the seat count" "3" "$(seat_count "$OUT/seats.txt")"
check "with the one swap that fit" "L3 L5 L6 " "$(seat_list "$OUT/seats.txt")"
# No seats file: refused by name, never derived from the tags (which is the side effect this replaces).
out="$(rerank --seats "$WORK/no-seats.txt")"; rc=$?
check_rc "no seats file refuses" 1 "$rc"
check "saying so" "NO SEATS" "$out"
# A seats file naming no lesson (emptied, or only comments) is not "no moves this month": refused by
# name (found by the PR lessons review of this change, L98).
printf '# The seats\n# nothing here\n' > "$WORK/seats-empty.txt"
out="$(rerank --seats "$WORK/seats-empty.txt")"; rc=$?
check_rc "a seats file naming no lesson refuses" 1 "$rc"
check "saying it names none" "names no lesson" "$out"
check_not "and never as a healthy month" "No moves this month" "$(cat "$OUT/rerank.html" 2>/dev/null)"
# A seat that is not in the core is a half applied re-rank (core-set ran, the seats file was not
# committed with it), so it refuses rather than shrinking the seats.
printf 'L3\nL4\nL6\n' > "$WORK/seats-drift.txt"
out="$(rerank --seats "$WORK/seats-drift.txt")"; rc=$?
check_rc "a seat outside the core refuses" 1 "$rc"
check "naming it" "L6" "$out"
check "and saying the seats file and the core disagree" "SEAT NOT IN CORE" "$out"

# 2c. SEEDING THE SEATS once, by the re-rank's own ranking: the N most cited reviewable core lessons.
#     In core-approved the reviewable lessons are L3 (cited 30), L5 (2), L4 and L10 (never); L12 is
#     disputed and never a candidate.
rm -f "$OUT"/*
out="$(python3 "$TOOL" --index-dir "$IDX" --core "$WORK/core-approved.txt" --counts-dir "$REPO/lesson-counts" \
  --bands-dir "$REPO/lesson-bands" --ages "$WORK/ages.txt" --tags "$REPO/lesson-tags.tsv" --second-tags "$REPO/lesson-tags-second.tsv" \
  --now "$NOW" --seed-seats 2 --out-seats "$OUT/seeded.txt" --out-tsv "$OUT/moves.tsv" --out-html "$OUT/rerank.html" --out-list "$OUT/core.txt" 2>&1)"; rc=$?
check_rc "seeding the seats succeeds" 0 "$rc"
check "the two most cited reviewable core lessons become the seats" "L3 L5 " "$(seat_list "$OUT/seeded.txt")"
check "and the file says how each was chosen" "rank 1" "$(cat "$OUT/seeded.txt" 2>/dev/null)"
out="$(python3 "$TOOL" --index-dir "$IDX" --core "$WORK/core-approved.txt" --counts-dir "$REPO/lesson-counts" \
  --bands-dir "$REPO/lesson-bands" --ages "$WORK/ages.txt" --tags "$REPO/lesson-tags.tsv" --second-tags "$REPO/lesson-tags-second.tsv" \
  --now "$NOW" --seed-seats 9 --out-seats "$OUT/seeded.txt" --out-tsv "$OUT/moves.tsv" --out-html "$OUT/rerank.html" --out-list "$OUT/core.txt" 2>&1)"; rc=$?
check_rc "asking for more seats than reviewable core lessons refuses" 1 "$rc"

# 2d. THE COMMITTED SEATS FILE: exactly 20 seats (the reviewable lessons Dan's approved list kept by
#     rank), each a real lesson, each named once, and, once the core list is in the payload, each in it.
#     The re-rank also refuses at run time on a seat outside the core (SEAT NOT IN CORE).
SEATS_FILE="$DIR/../lesson-core-seats.txt"
check "the committed seats file holds twenty seats" "20" "$(seat_count "$SEATS_FILE")"
real_seats="$(seat_list "$SEATS_FILE" | tr ' ' '\n' | awk 'NF' | while read -r l; do grep -qh "^- $l\. " "$DIR"/../payload/LESSONS-INDEX-*.md && printf '%s ' "$l"; done)"
check "and every seat is a lesson in the index" "20" "$(printf '%s' "$real_seats" | wc -w | tr -d ' ')"
check "and none is named twice" "20" "$(seat_list "$SEATS_FILE" | tr ' ' '\n' | awk 'NF' | sort -u | grep -c .)"
CORE_FILE="$DIR/../payload/LESSONS-CORE.txt"
if [ -f "$CORE_FILE" ]; then
  in_core="$(seat_list "$SEATS_FILE" | tr ' ' '\n' | awk 'NF' | while read -r l; do grep -qx "$l" "$CORE_FILE" && printf '%s ' "$l"; done)"
  check "and every seat is in the core list" "20" "$(printf '%s' "$in_core" | wc -w | tr -d ' ')"
else
  # Before the cutover there is no core list in the payload to check the seats against, which is
  # said rather than passed (L411); the run time refusal covers it from the first re-rank.
  echo "UNMEASURED: no payload/LESSONS-CORE.txt yet, so the committed seats were not checked against the core list"
fi

# 3. THE SIZE AFTER THE MOVES AGAINST THE CAP, in the unit core-set measures (chars of index lines).
out="$(rerank)"
check "the summary gives the core's size before and after" "after the moves 7 lessons" "$out"
out_over="$(rerank --cap 300)"
check "over the cap, it says so" "OVER CAP" "$out_over"
check "and the command it gives carries the over-cap switch, which is Dan's call" "SYNC_CORE_OVER_CAP=1" "$(cat "$OUT/rerank.html")"
out_under="$(rerank --cap 100000)"
check_not "under the cap, it does not say over" "OVER CAP" "$out_under"
check_not "and the command needs no switch" "SYNC_CORE_OVER_CAP=1" "$(cat "$OUT/rerank.html")"
check "the page gives the command that applies it" "claude-sync core-set" "$(cat "$OUT/rerank.html")"
check "the page is a complete document" "<!doctype html>" "$(cat "$OUT/rerank.html")"
check "and shows each moving lesson's own line" "Lesson number 6 says" "$(cat "$OUT/rerank.html")"
# The tool's default cap is claude-sync's, never a second copy that can drift from it (L41).
sync_cap="$(sed -n 's/.*cap="\${SYNC_CORE_CAP:-\([0-9][0-9]*\)}".*/\1/p' "$DIR/../claude-sync")"; sync_cap="${sync_cap%%$'\n'*}"
out_def="$(SYNC_CORE_CAP= rerank)"
check "the default cap is the one core-set enforces" "cap $sync_cap" "$out_def"
out_env="$(SYNC_CORE_CAP=12345 rerank)"
check "and an SYNC_CORE_CAP set for core-set is the one the re-rank measures against" "cap 12345" "$out_env"

# 4. THE MOVE CAP HOLDS. Five moves are wanted (two swaps and one addition). With a cap of three, the
#    best entrant's swap (2) and the addition (1) fit; the second swap is HELD, named, not dropped.
out="$(rerank --max-moves 3)"; rc=$?
check_rc "a capped re-rank still writes a proposal" 0 "$rc"
check "the best entrant still enters" "in" "$(move "$OUT/moves.tsv" L6)"
check "paired with the worst leaver" "out" "$(move "$OUT/moves.tsv" L4)"
check "the addition fits in what is left" "in" "$(move "$OUT/moves.tsv" L8)"
check "the swap past the cap is held back, not dropped" "held-in" "$(move "$OUT/moves.tsv" L7)"
check "and so is its partner" "held-out" "$(move "$OUT/moves.tsv" L5)"
check "the summary names the move cap" "move cap 3" "$out"
check "the page lists what the cap held back" "Held back" "$(cat "$OUT/rerank.html")"
n_moves="$(awk -F '\t' '$1 == "in" || $1 == "out"' "$OUT/moves.tsv" | grep -c .)"
[ "$n_moves" -le 3 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: no more moves than the cap ($n_moves > 3)"; }
out="$(rerank)"
check "the default move cap is named" "move cap 10" "$out"

# 5. HYSTERESIS: a core lesson only just below the seats does not leave. With --band 2 a leaver must
#    rank below seat 3 + 2 = 5; L5 ranks 5th, L4 6th, so only L4 leaves and L7 waits for a seat.
out="$(rerank --band 2)"
check "a lesson far below the seats leaves" "out" "$(move "$OUT/moves.tsv" L4)"
[ -z "$(move "$OUT/moves.tsv" L5)" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: a lesson just below the seats stays (got $(move "$OUT/moves.tsv" L5))"; }
check "the entrant with no seat free waits, named" "waiting" "$(move "$OUT/moves.tsv" L7)"

# 6. A STALE MAC IS UNMEASURED, never zero (L90, L530). The window is derived from the schedules
#    (L614): a Mac recounts when its counts are 7 days old, the job runs daily, so at the consumer's
#    instant the other Mac's counts are at worst 8 days old while it is in use. 8 days passes; past
#    the 14 day limit refuses, naming the Mac and the age.
counts mac-b "2026-10-01T12:00:00Z" $'L6\t25\t30\t0' $'L8\t10\t10\t0'
out="$(rerank)"; rc=$?
check_rc "counts at the worst case gap between the two schedules are fresh" 0 "$rc"
counts mac-b "2026-09-24T11:00:00Z" $'L6\t25\t30\t0' $'L8\t10\t10\t0'
out="$(rerank)"; rc=$?
check_rc "counts past the limit refuse" 2 "$rc"
check "naming the Mac" "UNMEASURED: mac-b" "$out"
check "and how old its counts are" "15 days" "$out"
check "the page says so too" "UNMEASURED" "$(cat "$OUT/rerank.html")"
[ ! -s "$OUT/core.txt" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: an unmeasured re-rank writes no list to apply"; }
[ -z "$(awk -F '\t' '$1 == "in" || $1 == "out"' "$OUT/moves.tsv" 2>/dev/null)" ] && pass=$((pass + 1)) \
  || { fail=$((fail + 1)); echo "FAIL: an unmeasured re-rank proposes no move"; }

# 7. A MISSING MAC refuses too: its absence is not a Mac that cited nothing.
rm -f "$REPO/lesson-counts/mac-b.tsv"
out="$(rerank)"; rc=$?
check_rc "a Mac with no counts refuses" 2 "$rc"
check "naming it" "UNMEASURED: mac-b" "$out"
check "and saying there are no counts" "no counts" "$out"
# Counts with no time stamp cannot be judged fresh, and counts dated after now are a clock fault.
counts mac-b none $'L6\t25\t30\t0'
out="$(rerank)"; rc=$?
check_rc "counts with no stamp refuse" 2 "$rc"
check "saying their age cannot be told" "no time stamp" "$out"
counts mac-b "2026-10-20T11:00:00Z" $'L6\t25\t30\t0'
out="$(rerank)"; rc=$?
check_rc "counts dated in the future refuse" 2 "$rc"
check "saying so" "in the future" "$out"
# A damaged counts file (a row that is not numbers, or a header with no window) is unmeasured and
# named, never a traceback (found by the PR lessons review of this change).
counts mac-b "2026-10-01T11:00:00Z" $'L6\t25\tx\t0'
out="$(rerank)"; rc=$?
check_rc "a counts row that is not numbers refuses as unmeasured" 2 "$rc"
check "naming the row" "L6" "$out"
check_not "and never as a traceback" "Traceback" "$out"
counts mac-b "2026-10-01T11:00:00Z" $'L6\t25\t30\t0'
sed -i.bak 's/ DAYS 60 / DAYS sixty /' "$REPO/lesson-counts/mac-b.tsv"; rm -f "$REPO/lesson-counts/mac-b.tsv.bak"
out="$(rerank)"; rc=$?
check_rc "a counts header with no window refuses as unmeasured" 2 "$rc"
check "saying the window cannot be read" "window" "$out"
check_not "and never as a traceback" "Traceback" "$out"
# A file under one Mac's name holding another Mac's counts is not that Mac's counts.
counts mac-b "2026-10-01T11:00:00Z" $'L6\t25\t30\t0'
sed -i.bak 's/^HOST mac-b/HOST mac-z/' "$REPO/lesson-counts/mac-b.tsv"; rm -f "$REPO/lesson-counts/mac-b.tsv.bak"
out="$(rerank)"; rc=$?
check_rc "a counts file naming another Mac refuses" 2 "$rc"
check "naming both" "mac-z" "$out"
fresh_counts

# The list of Macs comes from the lesson bands, the Macs that write lessons, never from a hand list
# (L41); one band with no counts is the case above. With --expect-hosts the given list is used.
out="$(rerank --expect-hosts mac-a)"; rc=$?
check_rc "an explicit list of Macs is honoured" 0 "$rc"
rm -f "$REPO/lesson-bands/mac-b"
out="$(rerank)"; rc=$?
check_rc "a Mac with counts but no band is not expected" 0 "$rc"
check "and its counts are said to be left out, not silently added" "left out" "$out"
printf '501\n' > "$REPO/lesson-bands/mac-b"

# 8. AN UNTAGGED NEW LESSON refuses by name, with the command that tags it.
printf -- '- L13. A brand new lesson nobody has tagged yet, long enough to look real.\n' >> "$IDX/LESSONS-INDEX-proof.md"
printf 'L13\t2026-10-08\t1\n' >> "$WORK/ages.txt"
out="$(rerank)"; rc=$?
check_rc "an untagged lesson refuses the re-rank" 1 "$rc"
check "naming it" "UNTAGGED L13" "$out"
check "and naming the command that tags only the untagged" "--skip-tagged" "$out"
check "the page lists it too" "L13" "$(cat "$OUT/rerank.html")"
[ ! -s "$OUT/core.txt" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: a refused re-rank writes no list to apply"; }
printf 'L13\tdiff\n' >> "$REPO/lesson-tags.tsv"
out="$(rerank)"; rc=$?
check_rc "once tagged it is judged" 0 "$rc"
[ -z "$(move "$OUT/moves.tsv" L13)" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: a new uncited lesson starts in the library (got $(move "$OUT/moves.tsv" L13))"; }

# No tag file at all is its own refusal, not 13 UNTAGGED lines.
out="$(rerank --tags "$WORK/no-such-tags.tsv")"; rc=$?
check_rc "a missing tags file refuses" 1 "$rc"
check "saying so" "NO TAGS" "$out"

# 9. NO CORE LIST: the core is not switched on, so there is nothing to re-rank. Its own exit code, so
#    the job can stay quiet rather than alarm every month before the cutover.
out="$(rerank --core "$WORK/no-core.txt")"; rc=$?
check_rc "no core list is its own outcome" 3 "$rc"
check "saying the core is not in use" "INACTIVE" "$out"
# A list naming a lesson that no longer exists is broken: claude-sync already loads the whole library.
printf 'L1\nL2\nL3\nL99\n' > "$WORK/bad-core.txt"
out="$(rerank --core "$WORK/bad-core.txt")"; rc=$?
check_rc "a core list naming no lesson refuses" 1 "$rc"
check "naming it" "L99" "$out"
# Two Macs counting over different windows cannot be added into one rate (L711).
fresh_counts
sed -i.bak 's/ DAYS 60 / DAYS 30 /' "$REPO/lesson-counts/mac-b.tsv"; rm -f "$REPO/lesson-counts/mac-b.tsv.bak"
out="$(rerank)"; rc=$?
check_rc "counts over different windows refuse" 1 "$rc"
check "naming the windows" "60" "$out"
fresh_counts

# ---------------------------------------------------------------------------------------------------
# THE JOB: tools/run-lessons-core-rerank.sh, run daily by launchd. Each Mac recounts its own prose
# citations when its counts are 7 days old and records them through claude-sync, which commits them
# so the next sync carries them to the other Mac. Then it re-ranks, writes the page and notifies,
# ONCE a month per outcome, and only records a notice as given when one was really posted (L368).
# Every outside thing is a fake (L284): the counter, the ages, claude-sync and the notifier.
# ---------------------------------------------------------------------------------------------------
FAKES="$WORK/fakes"; mkdir -p "$FAKES"
cat > "$FAKES/counter" <<'EOS'
#!/usr/bin/env bash
echo "counter $*" >> "$FAKE_LOG"
[ "${FAKE_COUNTER_RC:-0}" = 0 ] || { echo "NOTHING READ"; exit 1; }
printf 'HOST %s DAYS 60 READ 100 UNREAD 0 EXCLUDED subagent=0 claude-config=0 recording=0 LEDGER read DISMISSED 0 AT %s\n' "$FAKE_HOST" "$FAKE_AT"
printf 'L3\t30\t40\t0\nL7\t18\t20\t2\nL8\t12\t12\t0\nEND 3 lessons\n'
EOS
cat > "$FAKES/sync" <<'EOS'
#!/usr/bin/env bash
echo "sync $*" >> "$FAKE_LOG"
[ "$1" = record-lesson-counts ] || exit 9
cp "$2" "$FAKE_REPO/lesson-counts/$FAKE_HOST.tsv"
EOS
cat > "$FAKES/ages" <<'EOS'
#!/usr/bin/env bash
echo "ages $*" >> "$FAKE_LOG"
cat "$FAKE_AGES"
EOS
cat > "$FAKES/notifier" <<'EOS'
#!/usr/bin/env bash
printf 'notify' >> "$FAKE_LOG"; printf ' [%s]' "$@" >> "$FAKE_LOG"; printf '\n' >> "$FAKE_LOG"
exit "${FAKE_NOTIFY_RC:-0}"
EOS
chmod +x "$FAKES"/*
export FAKE_LOG="$WORK/fake.log" FAKE_REPO="$REPO" FAKE_AGES="$WORK/ages.txt" FAKE_HOST=mac-a
STATE="$WORK/state"; CH="$WORK/claude-home"; mkdir -p "$CH"
job(){ # job <now ISO>: one daily run
  : > "$FAKE_LOG"
  FAKE_AT="$1" RERANK_NOW="$1" RERANK_REPO="$REPO" RERANK_HOST=mac-a RERANK_STATE="$STATE" RERANK_LOG="$WORK/job.log" \
  RERANK_COUNTER="$FAKES/counter" RERANK_SYNC="$FAKES/sync" RERANK_AGES="$FAKES/ages" RERANK_NOTIFIER="$FAKES/notifier" \
  CLAUDE_HOME="$CH" bash "$JOB" 2>&1
}
notices(){ grep -c '^notify' "$FAKE_LOG" 2>/dev/null || true; }

# A. Own counts 4 days old: no recount. Both fresh: the proposal is written and notified, once.
fresh_counts
out="$(job "2026-10-09T15:00:00Z")"; rc=$?
check_rc "the job runs" 0 "$rc"
check_not "counts 4 days old are not recounted" "counter" "$(cat "$FAKE_LOG")"
check "the job notifies Dan of the proposal" "notify" "$(cat "$FAKE_LOG")"
check "the notification says how many moves" "move" "$(grep '^notify' "$FAKE_LOG")"
check "and clicking it opens the page in Chrome, never a bare open" "Google Chrome" "$(grep '^notify' "$FAKE_LOG")"
page="$(ls "$STATE"/rerank-2026-10.html 2>/dev/null)"
check "the page is left in the state folder, by month" "rerank-2026-10.html" "$page"
check "and the list to apply beside it" "core-2026-10.txt" "$(ls "$STATE" 2>/dev/null)"
check "and the seats to commit with it" "seats-2026-10.txt" "$(ls "$STATE" 2>/dev/null)"
out="$(job "2026-10-10T15:00:00Z")"
check "a second run in the same month does not notify again" "0" "$(notices)"

# B. Own counts 8 days old: recounted, and recorded through claude-sync so they travel.
rm -rf "$STATE"
counts mac-a "2026-10-01T09:00:00Z" $'L3\t30\t40\t0'
out="$(job "2026-10-09T15:00:00Z")"
check "counts a week old are recounted" "counter" "$(cat "$FAKE_LOG")"
check "and recorded through claude-sync, which commits them for the other Mac" "sync record-lesson-counts" "$(cat "$FAKE_LOG")"
check "the recorded counts are the fresh ones" "AT 2026-10-09T15:00:00Z" "$(head -1 "$REPO/lesson-counts/mac-a.tsv")"
# A counter that read nothing records nothing: an empty table is not a Mac that cited nothing (L98).
counts mac-a "2026-09-20T09:00:00Z" $'L3\t30\t40\t0'
rm -rf "$STATE"
out="$(FAKE_COUNTER_RC=1 job "2026-10-09T15:00:00Z")"
check_not "a counter that failed records nothing" "sync record-lesson-counts" "$(cat "$FAKE_LOG")"
check "and the log says why" "counter" "$(cat "$WORK/job.log")"
check "the stale counts it kept are then unmeasured, and Dan is told once" "UNMEASURED" "$(grep '^notify' "$FAKE_LOG")"

# C. UNMEASURED once a month, then the proposal as soon as the other Mac's counts arrive.
fresh_counts
counts mac-b "2026-09-20T11:00:00Z" $'L6\t25\t30\t0'
rm -rf "$STATE"
out="$(job "2026-10-09T15:00:00Z")"
check "a stale other Mac is said once" "UNMEASURED" "$(grep '^notify' "$FAKE_LOG")"
check "naming the Mac" "mac-b" "$(grep '^notify' "$FAKE_LOG")"
out="$(job "2026-10-10T15:00:00Z")"
check "and not again the next day for the same reason" "0" "$(notices)"
fresh_counts
counts mac-b "2026-10-10T11:00:00Z" $'L6\t25\t30\t0' $'L8\t10\t10\t0'
out="$(job "2026-10-11T15:00:00Z")"
check "once the other Mac's counts arrive the proposal is delivered the same month" "move" "$(grep '^notify' "$FAKE_LOG")"

# D. A notification that could not be posted is not recorded as given: the next day tries again.
rm -rf "$STATE"; fresh_counts
out="$(FAKE_NOTIFY_RC=1 job "2026-10-09T15:00:00Z")"
check "a failed notification is logged" "could not" "$(cat "$WORK/job.log")"
out="$(job "2026-10-10T15:00:00Z")"
check "and tried again the next day" "1" "$(notices)"

# E. Asleep (sleep mode, claude-config#840): nothing is posted and nothing recorded as given.
rm -rf "$STATE"
boot="$(sysctl -n kern.boottime 2>/dev/null | sed -n '1s/^[^0-9]*sec *= *\([0-9][0-9]*\).*/\1/p')"
mkdir -p "$CH/state/sleep"
printf '{"v":1,"until":%s000,"bootTime":%s}\n' "$(( $(date +%s) + 86400 ))" "${boot:-0}" > "$CH/state/sleep/current.json"
out="$(job "2026-10-09T15:00:00Z")"
check "nothing is posted while Dan is asleep" "0" "$(notices)"
check "and the log says that is why" "asleep" "$(tail -3 "$WORK/job.log")"
rm -f "$CH/state/sleep/current.json"
out="$(job "2026-10-09T16:00:00Z")"
check "and it is posted once he is awake" "1" "$(notices)"

# F. Inactive core: logged, never notified, so the job can be installed before the cutover.
rm -rf "$STATE"; mv "$IDX/LESSONS-CORE.txt" "$WORK/core-aside.txt"
out="$(job "2026-10-09T15:00:00Z")"
check "with no core list nothing is posted" "0" "$(notices)"
check "and the log says the core is not in use" "INACTIVE" "$(cat "$WORK/job.log")"
mv "$WORK/core-aside.txt" "$IDX/LESSONS-CORE.txt"

# ---------------------------------------------------------------------------------------------------
# THE INSTALLER writes a DAILY launch agent running the job from this checkout, and loads nothing
# under the tests. Daily, not monthly: the job delivers once a month, and a daily wake is its
# re-attempt when a Mac was off or a count was stale (L533).
# ---------------------------------------------------------------------------------------------------
AGENTS="$WORK/LaunchAgents"
out="$(RERANK_LAUNCHAGENTS="$AGENTS" RERANK_NO_LAUNCHCTL=1 bash "$INSTALL" 2>&1)"; rc=$?
PLIST="$AGENTS/com.claudeconfig.lessonscorererank.plist"
check_rc "the installer runs" 0 "$rc"
check "and writes a launch agent" "run-lessons-core-rerank.sh" "$(cat "$PLIST" 2>/dev/null)"
check "that runs every day at an hour" "<key>Hour</key>" "$(cat "$PLIST" 2>/dev/null)"
check_not "not on one day of the month" "<key>Day</key>" "$(cat "$PLIST" 2>/dev/null)"
check "the installer says where it wrote it" "$PLIST" "$out"
prog="$(sed -n 's|.*<string>\(/[^<]*run-lessons-core-rerank.sh\)</string>.*|\1|p' "$PLIST")"
[ -f "$prog" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: the plist names a job that exists ($prog)"; }
out="$(RERANK_LAUNCHAGENTS="$AGENTS" RERANK_NO_LAUNCHCTL=1 bash "$INSTALL" --remove 2>&1)"
[ ! -f "$PLIST" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: --remove deletes the launch agent"; }

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
