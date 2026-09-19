#!/usr/bin/env bash
# Tests for the ONE rule deciding whether a rendered lessons index line is too long
# (claude-config#370).
#
# It was written twice: the awk inside test-rule-file-budget.sh that fails a push, and
# over_cap_lesson_entries inside claude-sync that holds an over-cap lessons file back at send time.
# Both were correct and each read as correct on its own, which is the state L370 describes: sharing
# the rule's DATA, here the cap, while copying the code that APPLIES it is not consolidation, and a
# change to how the rule is applied lands in one copy only.
#
# The second copy existed because the first carries a floor of 100 entries, correct against the
# real index and unusable against a small fixture, so the floor is now an ARGUMENT and the
# predicate is shared.
#
# The last section is the one that matters: all three consumers are driven against ONE fixture and
# their answers compared. Two implementations that are merely both present, each with its own
# tests, is what this repo keeps finding (L70): a comparison whose two sides come from one lookup
# can only confirm that lookup is self consistent.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="$(cd "$DIR/.." && pwd)"
REPO="$(cd "$PAYLOAD_DIR/.." && pwd)"
# WHERE THIS IS RUNNING. Two copies of these hooks exist: the repo's payload/hooks, which sits
# beside a claude-sync and a payload/, and the INSTALLED copy under the config root, which does
# not. This suite drives the real claude-sync, so in the installed copy it was measuring a tool
# that is not there and failing for that reason alone. Measured 2026-09-11, by the first
# `claude-sync recheck` that was able to finish.
#
# Said in the one agreed shape the runner reads, so it is reported as NOT RUN rather than as broken
# code, and never as a pass.
if [ ! -f "$REPO/claude-sync" ] || [ ! -d "$REPO/payload" ]; then
  echo "test-lesson-index-cap: $REPO is not a checkout of this repo (no claude-sync and payload/ in it), so the tool this suite drives is not there." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository above it, and $REPO is not one"
  echo "passed: 0, failed: 0"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 2
fi
LIB="$DIR/lib/lesson-index-cap.sh"
BUDGET="$DIR/test-rule-file-budget.sh"
SYNC="$REPO/claude-sync"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}
want() { # want <description> <expected> <actual>
  if [ "$2" = "$3" ]; then check "$1" ok; else check "$1" "wanted '$2', got '$3'"; fi
}
# A copy of a suite arms its own deadline like the original does, and refuses to run without the
# helper (claude-config#465), so every fixture holding a copy carries the helper beside it.
plant_deadline_lib() {   # plant_deadline_lib <the fixture's hooks directory>
  mkdir -p "$1/lib"
  cp "$DIR/lib/suite-deadline.sh" "$1/lib/suite-deadline.sh"
  cp "$DIR/lib/kill-tree.sh" "$1/lib/kill-tree.sh"
}

[ -f "$LIB" ] || { echo "FAIL: no shared predicate at $LIB, so the rule is still written twice"; echo "passed: 0, failed: 1"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
# shellcheck source=lib/lesson-index-cap.sh
. "$LIB" || { echo "FAIL: cannot source $LIB"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.lessoncap.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;;
esac
trap 'rm -rf "$WORK"' EXIT

# A rendered index line of exactly N characters, numbered Lnnn, so every length assertion below is
# about a line whose length is known rather than one that happens to be long.
entry_of() { # entry_of <number> <total characters>
  local head="- L$1. " pad=""
  local n=$(( $2 - ${#head} ))
  [ "$n" -lt 1 ] && n=1
  pad="$(printf '%*s' "$n" '' | tr ' ' 'x')"
  printf '%s%s\n' "$head" "$pad"
}

echo "lesson index cap: the predicate itself"

# ---- what counts as an entry ----
scan() { lesson_index_cap_scan "$@"; }

out="$( { entry_of 1 50; echo "not an entry at all"; echo "## a heading"; entry_of 2 50; } | scan 160 0 )"
want "only index entries are counted" "ENTRIES 2" "$(printf '%s\n' "$out" | grep '^ENTRIES ')"

# ---- the boundary, pinned so the rule reads the same way to the next person ----
out="$(entry_of 1 160 | scan 160 0)"
want "a line exactly at the cap is not over it" "" "$(printf '%s\n' "$out" | grep '^OVER ' || true)"
out="$(entry_of 1 161 | scan 160 0)"
want "one character past the cap is over it" "OVER L1 161" "$(printf '%s\n' "$out" | grep '^OVER ')"

# ---- every over-cap entry is named, not merely counted ----
out="$( { entry_of 1 50; entry_of 2 200; entry_of 3 50; entry_of 4 300; } | scan 160 0 )"
want "every over-cap entry is named, in file order" "L2 L4" \
  "$(printf '%s\n' "$out" | awk '/^OVER /{printf "%s%s", sep, $2; sep=" "} END{print ""}')"
want "and the longest is reported with its number" "LONGEST 300 L4" \
  "$(printf '%s\n' "$out" | grep '^LONGEST ')"

# ---- the floor, which is the whole reason the second copy existed ----
# A scan that matched nothing passes the length test on every entry it did not find, and reads
# exactly like an index where every entry is short (L98). The budget hook wants a floor of 100
# against the real index; the send wants none against a file that may hold one lesson.
out="$( { entry_of 1 50; entry_of 2 50; } | scan 160 100 )"
want "a scan that found fewer entries than the floor says so" "UNDERFLOOR 2 100" \
  "$(printf '%s\n' "$out" | grep '^UNDERFLOOR ')"
out="$( { entry_of 1 50; entry_of 2 50; } | scan 160 0 )"
want "and the same input with no floor does not" "" "$(printf '%s\n' "$out" | grep '^UNDERFLOOR ' || true)"
out="$(printf '' | scan 160 1)"
want "an empty input is under a floor of one, rather than a clean index" "UNDERFLOOR 0 1" \
  "$(printf '%s\n' "$out" | grep '^UNDERFLOOR ')"

# ---- a cap it cannot read is refused, never treated as no cap ----
# The caller has to be able to tell "nothing is over the cap" from "there was no cap to measure
# against", because those are the same silence (L98, L11).
if printf '' | scan "" 0 >/dev/null 2>&1; then
  check "an empty cap is refused rather than read as zero" "it returned 0"
else
  check "an empty cap is refused rather than read as zero" ok
fi
if printf '' | scan "UNREADABLE:/x" 0 >/dev/null 2>&1; then
  check "a cap that is not a number is refused" "it returned 0"
else
  check "a cap that is not a number is refused" ok
fi

echo "lesson index cap: there is only one copy of the rule left"

# Agreement between two implementations is a measurement of today, not a structure. These assert
# the second copy is GONE, because two copies that currently agree are exactly the state #370 was
# opened about: each reads as correct on its own and a change lands in one of them (L370).
check "the budget hook calls the shared rule" \
  "$(grep -q 'lesson_index_cap_scan' "$BUDGET" && echo ok || echo 'it does not mention lesson_index_cap_scan')"
check "and claude-sync calls the shared rule" \
  "$(grep -q 'lesson_index_cap_scan' "$SYNC" && echo ok || echo 'it does not mention lesson_index_cap_scan')"
# The shapes the two copies actually had: a bash string length against the cap in the hook, and an
# awk line length against the cap in the tool.
stray="$(grep -nE '\$\{#[A-Za-z_]+\}[^#]*-gt[^#]*ENTRY_CAP' "$BUDGET" || true)"
want "the budget hook holds no second length-against-the-cap test" "" "$stray"
stray="$(grep -nE 'length\(\$0\)[^#]*>[^#]*cap' "$SYNC" || true)"
want "claude-sync holds no second length-against-the-cap test" "" "$stray"
# And each refuses to run at all without the shared rule, rather than skipping the section, which
# would read exactly like a run that found nothing over the cap (L98).
NOLIB="$WORK/nolib"; mkdir -p "$NOLIB/hooks/lib"
cp "$BUDGET" "$NOLIB/hooks/test-rule-file-budget.sh"
plant_deadline_lib "$NOLIB/hooks"
out="$(bash "$NOLIB/hooks/test-rule-file-budget.sh" 2>&1 || true)"
# Matched with `case` over a variable, never piped into `grep -q`: under pipefail a short
# circuiting consumer kills its producer and the pipeline reports a failure that never happened
# (L183), and this repo ratchets the count of such pipelines down rather than up.
case "$out" in
  *lesson-index-cap.sh*) check "the budget hook refuses when the shared rule is missing" ok ;;
  *) check "the budget hook refuses when the shared rule is missing" "it did not name the missing rule (said: ${out%%$'\n'*})" ;;
esac

echo "lesson index cap: all three consumers agree on one fixture"

# The fixture: three lessons, two of which render past the REAL cap. Written as LESSONS.md, since
# that is what the send reads, and rendered to an index by the tool itself, since that is what the
# budget hook reads. Nothing here restates the cap; it is read from the hook that owns it.
CAP="$(awk -F= '/^ENTRY_CAP=[0-9]+$/ { print $2; exit }' "$BUDGET")"
case "$CAP" in ''|*[!0-9]*) check "the budget hook still carries a readable ENTRY_CAP" "got '$CAP'" ;; *) check "the budget hook still carries a readable ENTRY_CAP" ok ;; esac

long_rule() { printf '%s' "$(printf '%*s' "$(( CAP + 60 ))" '' | tr ' ' 'y')"; }
FHOME="$WORK/home"; FREPO="$WORK/repo"
mkdir -p "$FHOME/hooks" "$FREPO/payload"
echo '{"hooks":{}}' > "$FHOME/settings.json"
printf '# rules\n@LESSONS-INDEX.md\n' > "$FHOME/CLAUDE.md"
cp "$BUDGET" "$FHOME/hooks/test-rule-file-budget.sh"
plant_deadline_lib "$FHOME/hooks"
{
  printf '# Lessons\n\n## Proof over green\n\n'
  printf -- '- **L901. short enough to render inside the cap.** body\n'
  printf -- '- **L902. %s** body\n' "$(long_rule)"
  printf -- '- **L903. %s** body\n' "$(long_rule)"
} > "$FHOME/LESSONS.md"

sendout="$(SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$FHOME" SYNC_REPO="$FREPO" bash "$SYNC" push 2>&1)"

# Side one: what the send held back.
send_nums="$(printf '%s\n' "$sendout" | grep -o 'L90[0-9]' | sort -u | tr '\n' ' ' | sed 's/ $//')"
want "the send names both over-cap lessons and neither of the others" "L902 L903" "$send_nums"

# Side two: the shared predicate, run over the index the tool just generated. The index is one
# file per section of LESSONS.md (claude-config#473), so the predicate reads their union, exactly
# as the budget hook does.
#
# Read from the CONFIG tree rather than the payload (claude-config#483). This fixture is a lessons
# file the send REFUSES, and a refused source takes every file rendered from it with it, so nothing
# generated reaches the payload at all. The generator still writes them beside the lessons file
# here, which is the index this fixture is about: the one rendered from those three entries.
IDXFILES=()
for _ix in "$FHOME"/LESSONS-INDEX-*.md; do [ -f "$_ix" ] && IDXFILES+=("$_ix"); done
check "the send generated an index to measure" "$([ "${#IDXFILES[@]}" -gt 0 ] && echo ok || echo "no index file in $FHOME")"
pred_nums="$(cat "${IDXFILES[@]}" | scan "$CAP" 0 | awk '/^OVER /{print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//')"
want "the shared predicate names the same two" "$send_nums" "$pred_nums"

# Side three: the budget hook, run against a payload holding that same index. Its own output is a
# count rather than a list, so the count is what is compared; a hook that named a different NUMBER
# of entries would be applying a different rule whatever it called them.
BP="$WORK/budgetpayload"; mkdir -p "$BP/hooks/lib"
cp "$LIB" "$BP/hooks/lib/lesson-index-cap.sh"
cp "${IDXFILES[@]}" "$BP/"
: > "$BP/CLAUDE.md"
for _ix in "${IDXFILES[@]}"; do printf '@%s\n' "$(basename "$_ix")" >> "$BP/CLAUDE.md"; done
cp "$BUDGET" "$BP/hooks/test-rule-file-budget.sh"
plant_deadline_lib "$BP/hooks"
budgetout="$(bash "$BP/hooks/test-rule-file-budget.sh" 2>&1 || true)"
budget_over="$(printf '%s\n' "$budgetout" | sed -n 's/^FAIL: \([0-9]*\) of \([0-9]*\) lessons render an index line longer.*/\1/p')"
budget_entries="$(printf '%s\n' "$budgetout" | sed -n 's/^FAIL: \([0-9]*\) of \([0-9]*\) lessons render an index line longer.*/\2/p')"
want "the budget hook counts the same over-cap entries" "2" "$budget_over"
want "and measured the same number of entries in total" "3" "$budget_entries"

# And the floor still bites where it is meant to: this fixture holds 3 entries against the hook's
# floor of 100, so the hook must ALSO say it measured almost nothing. Without this the count above
# could be agreement between two scans that both found nothing.
case "$budgetout" in
  *"index entries were found to measure"*) check "the budget hook still reports a fixture too small to measure against" ok ;;
  *) check "the budget hook still reports a fixture too small to measure against" "it did not say the fixture was too small" ;;
esac

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
