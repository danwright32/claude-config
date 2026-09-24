#!/usr/bin/env bash
#
# test-rule-file-budget.sh: how big the files that load into EVERY session have got.
#
# Why this exists (claude-config#353): CLAUDE.md and everything it imports are read at the
# start of every session, in every project, and they only ever grow, by one line each time
# a lesson is recorded. Nothing measured them.
#
# The FIRST version of this file took its ceiling from the docs (4 MiB, "Claude Code loads a
# CLAUDE.md file of up to 4 MiB in full and skips a larger file", read 2026-09-10) and shipped
# a guard 28 times too loose that could never have fired. The number that governs in practice
# was already written down in LESSONS.md the same week, in L429's own provenance, and was not
# read. That is L82 exactly: when a platform's documented guarantee is the whole reason a
# guard is safe, measure it on the real target before shipping.
#
# What was then MEASURED, on the product rather than the docs:
#
#   the WARNING   Claude Code shows a `large-memory-files` banner for any memory file over
#                   150,000 characters. Read out of the 2.1.268 binary: the banner filters
#                   the loaded memory files on `content.length > limit` and does nothing
#                   else, so the file still loads IN FULL at that size. Confirmed twice by
#                   checking a file's last line against what reached the session: once at
#                   150,888 chars (overture#3640, 2026-09-07) and once at 150,830 here.
#                   So the warning costs attention and context, and loses no rule.
#   the LIMIT     is NOT a constant, and there are TWO of them. Read out of the 2.1.281
#                   binary (claude-config#541): per file, the context window times 0.05
#                   times a model factor of 3 or 4, floor 40,000; and a TOTAL, the larger of
#                   120,000 and the per file figure, over the loaded files not already over
#                   the per file one. The memory index counts toward neither. The 150,000
#                   seen here is the per file figure for a 1M window; a 200,000 window gets
#                   40,000 per file and a 120,000 total. This suite gates each file against
#                   the per file figure only, and the TOTAL is gated by nothing: the loaded
#                   set was 144,957 on 2026-09-23. Neither banner drops a rule: a nonce probe
#                   that day loaded 250,000 and every code at the start, middle and end came.
#   the 4 MiB     documented skip is left here as prose and gated by nothing. It is real as
#                   far as anyone knows, but it is unmeasured, and the budget below makes it
#                   unreachable. A guard that can never fire reads as protection while
#                   protecting nothing, so it is better absent than green (L182).
#
# Three thresholds are gated, because they catch different things:
#
#   the BUDGET    a fixed ceiling per file, set BELOW the warning so this fires first and
#                   the banner is never what tells anybody. The point of the gap is that a
#                   push is refused while there is still room to think.
#   the ENTRY CAP the longest single line the generated lessons index may render. This is
#                   what actually holds the index down over time: it is the per-lesson cost,
#                   and the total is just that cost times a number that only grows. A rule
#                   too long for it carries a SHORT: line in LESSONS.md and renders that
#                   instead, with its full text left exactly as written.
#   the RATCHET   each file's recorded size plus half again, or plus a fixed headroom,
#                   whichever is larger. What this catches is ACCIDENTAL bloat: a generator
#                   that duplicates its output, a merge that doubles a file, an import that
#                   pulls in something huge. Raising a recorded number is a deliberate act,
#                   which is the point: it makes the growth visible instead of letting it
#                   happen one line at a time (L316).
#
# The loaded set is DERIVED by following the imports, never listed here, because a list
# maintained beside the thing it mirrors is the defect this repo keeps finding (L41). A
# file that is loaded and has no recorded size FAILS, so a new import cannot arrive
# unmeasured.

set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$(cd "$DIR/.." && pwd)"

# The over-cap rule itself lives in lib/, shared with claude-sync's send staging, which holds an
# over-cap lessons file back before it can reach the other Mac (claude-config#370). Absent, this
# suite refuses rather than skipping that section: a check that quietly stops running reads exactly
# like one that found nothing wrong (L98).
CAP_LIB="$DIR/lib/lesson-index-cap.sh"
if [ ! -f "$CAP_LIB" ]; then
  echo "test-rule-file-budget: no $CAP_LIB, so the entry cap could not be applied to anything. Refusing rather than passing a section that measured nothing." >&2
  exit 2
fi
# shellcheck source=lib/lesson-index-cap.sh
. "$CAP_LIB"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# The measured PER FILE warning threshold, in characters, on this setup (a 1M context window). See
# the header: it is not a platform constant, it is not a cliff, and the banner has a total as well. Re-measure by growing a memory file past it and
# reading the banner, never by reading the docs page.
WARN_LIMIT=150000

# The ceiling this suite actually enforces per file, set below WARN_LIMIT so the suite is what
# reports the crossing rather than a banner somebody happens to have on screen (L429).
#
# Raised from 120,000 on 2026-09-17 (claude-config#390), deliberately, as that issue's own parked
# note allowed. Measured the same day: the index was 99,116 and had grown from 92,464 on
# 2026-09-11, about 1,100 characters a day, which put 120,000 roughly nineteen days out. The only
# lever with a large saving is loading lessons by relevance, which risks a rule not arriving when
# it applies, and that redesign is tracked on its own. 140,000 is a CHOSEN number, not a measured
# one: as high as the gap below still allows.
#
# The deadline that number was about is GONE since claude-config#473, because the index is now one
# file per section of LESSONS.md and this budget and the per file banner are both per file (the
# banner's separate total is in the header): the largest section measured 27,713
# on 2026-09-19, a fifth of the budget, and the whole index would have to grow fivefold before the
# biggest section reached it. The ceiling stays here because it is what stops any ONE file, index
# or not, becoming the thing the banner reports.
BUDGET=140000

# The least room between the budget and the warning. The budget exists so a push is refused while
# there is still time to act, before any banner appears; at the growth rate measured above, 10,000
# characters is about nine days. Chosen, and pinned so the next raise cannot quietly close the gap.
MIN_WARN_GAP=10000

# The longest line the generated lessons index may render, counted as it appears in the file,
# "- L429. " prefix included. A rule longer than this carries a SHORT: line in LESSONS.md.
ENTRY_CAP=160

# The least headroom the ratchet leaves, whatever half again comes to. The index is one file per
# section now, and the smallest of them measured 2,099 on 2026-09-19: half again on that is about
# a thousand characters, which ordinary growth crosses in a handful of lessons, so a pure ratio
# would have refused a push every few weeks per small file and taught everybody to raise the
# number without reading it (L36). 8,000 is about 55 index lines at the 144 characters a line
# measured that day. What it gives up is honest: a 2,000 character file that DOUBLED would not be
# reported, and two thousand characters against a 140,000 budget is not the bloat this catches.
MIN_RATCHET_HEADROOM=8000

# Recorded sizes, re-measured 2026-09-19 with `wc -c` on the payload copies, when the lessons index
# became one file per section (claude-config#473). Re-measure with:
#   wc -c payload/CLAUDE.md payload/RTK.md payload/LESSONS-INDEX-*.md
# Raise a number here only when the growth is understood and wanted. A loaded file with no number
# here FAILS, so a new section cannot arrive unmeasured.
recorded_size() {  # $1 = payload relative path
  case "$1" in
    CLAUDE.md)                                printf '32375' ;;
    RTK.md)                                   printf '966' ;;
    LESSONS-INDEX-proof-over-green.md)        printf '27713' ;;
    LESSONS-INDEX-ux-completeness.md)         printf '13605' ;;
    LESSONS-INDEX-honest-failure.md)          printf '13208' ;;
    LESSONS-INDEX-state-and-identity.md)      printf '10491' ;;
    LESSONS-INDEX-cross-system-reliability.md) printf '9540' ;;
    LESSONS-INDEX-codebase-hygiene.md)        printf '7366' ;;
    LESSONS-INDEX-data-safety.md)             printf '5939' ;;
    LESSONS-INDEX-security-and-privacy.md)    printf '4243' ;;
    LESSONS-INDEX-external-systems.md)        printf '4065' ;;
    LESSONS-INDEX-pipeline-speed.md)          printf '3994' ;;
    LESSONS-INDEX-test-speed.md)              printf '2176' ;;
    LESSONS-INDEX-building-with-ai.md)        printf '2099' ;;
    *)                                        printf '' ;;
  esac
}

# The ratchet ceiling for one recorded size, in one place, because the walk below and the self test
# at the bottom both apply it and two copies of one rule drift (L370).
ratchet_ceiling() {  # $1 = recorded bytes
  local half=$(( $1 + $1 / 2 )) flat=$(( $1 + MIN_RATCHET_HEADROOM ))
  if [ "$half" -gt "$flat" ]; then printf '%s' "$half"; else printf '%s' "$flat"; fi
}

# Every file a session loads at launch: CLAUDE.md plus what it imports, following imports
# recursively. The platform allows four hops; this walk has no depth limit of its own and
# guards against a cycle by not revisiting a file, which is the same protection with no
# second number to keep in step.
loaded_files() {
  local queue="CLAUDE.md" seen="" current rest target
  while [ -n "$queue" ]; do
    current="${queue%%|*}"
    rest="${queue#*|}"
    [ "$rest" = "$queue" ] && rest=""
    queue="$rest"
    case "|$seen|" in *"|$current|"*) continue ;; esac
    seen="${seen:+$seen|}$current"
    printf '%s\n' "$current"
    [ -f "$PAYLOAD/$current" ] || continue
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      queue="${queue:+$queue|}$target"
    done < <(grep -oE '^@[^[:space:]]+' "$PAYLOAD/$current" 2>/dev/null | sed 's/^@//')
  done
}

echo "rule file budget: what loads into every session"

count=0
total=0
while IFS= read -r rel; do
  count=$((count + 1))
  if [ ! -f "$PAYLOAD/$rel" ]; then
    bad "an import points at a file that is not there: $rel"
    continue
  fi
  bytes="$(wc -c < "$PAYLOAD/$rel" | tr -d ' ')"
  total=$((total + bytes))
  want="$(recorded_size "$rel")"

  if [ -z "$want" ]; then
    bad "$rel loads into every session and has no recorded size. Measure it with 'wc -c payload/$rel' and add it to recorded_size, so a new import cannot arrive unmeasured."
    continue
  fi
  ok

  if [ "$bytes" -gt "$BUDGET" ]; then
    bad "$rel is $bytes bytes, over the $BUDGET byte budget for a file that loads into every session. Past $WARN_LIMIT characters Claude Code shows a large-memory-files banner for it; this budget sits below that so there is room to act first. Shorten it, or move what is rarely needed behind a lookup."
  else ok; fi

  ceiling="$(ratchet_ceiling "$want")"
  if [ "$bytes" -gt "$ceiling" ]; then
    bad "$rel is $bytes bytes against a recorded $want, past the $ceiling it is ratcheted to. If that growth is wanted, raise the recorded number; if it is not, something has duplicated content into a file every session reads."
  else ok; fi

  printf '  %-42s %8s bytes (recorded %s, ratchet %s, budget %s, warns at %s)\n' "$rel" "$bytes" "$want" "$ceiling" "$BUDGET" "$WARN_LIMIT"
done < <(loaded_files)

# A walk that found nothing passes every assertion inside it at once, and would read as a
# clean run of a check that measured no files at all (L98).
if [ "$count" -ge 3 ]; then ok; else
  bad "the import walk found only $count file(s); it should find CLAUDE.md and what it imports, so the checks above measured almost nothing"
fi

printf '  %-42s %8s bytes read at the start of every session, in every project\n' "TOTAL" "$total"

echo "rule file budget: no single index entry is longer than the cap"

# The per-lesson cost is what actually decides the total, because the number of lessons only
# ever goes up. Measured on the GENERATED index rather than on LESSONS.md, because the index is
# what a session loads and a count taken over the source would be a claim about a file nobody
# reads (L418).
#
# A rule too long to render is not shortened in place: LESSONS.md keeps the full sentence and
# gains a `SHORT:` line, which the generator renders instead. So this failing is an instruction
# to write a short form, never to cut a rule down.
#
# Measured over the UNION of the generated files, in one pass (claude-config#473). Per file it
# would be a different check: the floor below exists so a scan that matched nothing cannot read
# like an index where every line is short, and no single section holds enough entries to clear a
# floor worth having. The union does, and the cap is a property of a LINE, so where the line sits
# makes no difference to it.
index_files=()
for _cand in "$PAYLOAD"/LESSONS-INDEX-*.md; do
  [ -f "$_cand" ] && index_files+=("$_cand")
done
if [ "${#index_files[@]}" -eq 0 ]; then
  bad "there is no generated lessons index file in the payload, so no entry was measured at all"
else
  # The floor of 100 is THIS site's, passed in rather than baked into the rule: a scan that matched
  # nothing passes the length test on every entry it did not find, and reads exactly like an index
  # where every entry is short (L98). The real index holds hundreds. The send staging shares this
  # rule and passes no floor at all, because a LESSONS.md holding one lesson is legitimate.
  ENTRY_FLOOR=100
  if ! report="$(cat "${index_files[@]}" | lesson_index_cap_scan "$ENTRY_CAP" "$ENTRY_FLOOR")"; then
    bad "the entry cap rule refused the cap it was given ($ENTRY_CAP), so no index entry was measured at all"
    report=""
  fi
  entries="$(printf '%s\n' "$report" | awk '/^ENTRIES /{ print $2 }')"
  longest="$(printf '%s\n' "$report" | awk '/^LONGEST /{ print $2 }')"
  longest_num="$(printf '%s\n' "$report" | awk '/^LONGEST /{ print $3 }')"
  # Counted in awk, never `grep -c`, which prints 0 AND exits non-zero on no match, so a `|| echo 0`
  # beside it fires as well and the variable ends up holding two numbers.
  toolong="$(printf '%s\n' "$report" | awk '/^OVER /{ n++ } END { print n + 0 }')"
  underfloor="$(printf '%s\n' "$report" | awk '/^UNDERFLOOR /{ print "yes" }')"

  if [ -z "$underfloor" ]; then ok; else
    bad "only $entries index entries were found to measure; the index holds hundreds, so the cap above was applied to almost nothing"
  fi

  if [ "$toolong" -gt 0 ]; then
    bad "$toolong of $entries lessons render an index line longer than $ENTRY_CAP characters (longest: $longest_num at $longest). Give each one a 'SHORT: <the rule in one line>' line in its LESSONS.md entry; the full rule stays exactly as it is and the index renders the short form."
  else ok; fi

  printf '  %-42s %8s entries, longest %s chars against a %s cap\n' \
    "${#index_files[@]} index files" "$entries" "$longest" "$ENTRY_CAP"
fi

echo "rule file budget: the check can actually fail"

# The real files are under budget, and a guard that has only ever been run against passing
# input has not been shown to work (L1, L159). These drive the same arithmetic against
# fixtures, so every run proves the thresholds still catch something.
probe="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.rulebudget.XXXXXXXX")" || probe=""
case "${probe%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$probe'" >&2; exit 2 ;;
esac
trap 'rm -rf "$probe"' EXIT

over_ratchet() {  # $1 = actual bytes, $2 = recorded bytes
  local ceiling; ceiling="$(ratchet_ceiling "$2")"
  [ "$1" -gt "$ceiling" ]
}

if over_ratchet 160000 100000; then ok; else bad "a file well past half again as big was not caught"; fi
# The boundary itself, pinned so the rule reads the same way to the next person: the test is
# MORE than half again, so exactly half again is still inside.
if over_ratchet 150000 100000; then bad "exactly half again was reported, but the rule is more than half again"; else ok; fi
if over_ratchet 150001 100000; then ok; else bad "one byte past half again was not caught"; fi
if over_ratchet 149000 100000; then bad "ordinary growth inside the ratchet was reported"; else ok; fi
if over_ratchet 100000 100000; then bad "a file that had not grown at all was reported"; else ok; fi
# THE FLOOR, on a file small enough for half again to be less than it. Half again on 2,000 is
# 3,000, so without the floor a file at 5,000 would be reported; with it the ceiling is 10,000.
if over_ratchet 5000 2000; then
  bad "ordinary growth on a small index file was reported: half again on a 2,000 byte file is about a thousand characters, which is why the floor exists"
else ok; fi
if over_ratchet 10001 2000; then ok; else bad "growth past the fixed headroom on a small file was not caught"; fi
# And the floor never LOOSENS a big file: past the point where half again is the larger of the
# two, the ratio is what governs, or raising the headroom would quietly widen every ceiling.
if [ "$(ratchet_ceiling 100000)" = "150000" ]; then ok; else
  bad "the ratchet on a 100,000 byte file is $(ratchet_ceiling 100000), not half again, so the fixed headroom is overriding the ratio where it should not"
fi
# The thresholds, pinned against the sizes actually observed, so the arithmetic that failed the
# first time around cannot come back. 150,830 is what LESSONS-INDEX.md measured on the day the
# warning banner first appeared for it.
if [ "$BUDGET" -lt "$WARN_LIMIT" ]; then ok; else
  bad "the budget is not below the warning threshold, so the banner reaches Dan before this suite ever refuses a push"
fi
if [ $(( WARN_LIMIT - BUDGET )) -ge "$MIN_WARN_GAP" ]; then ok; else
  bad "the budget sits within $MIN_WARN_GAP characters of the warning threshold, which leaves too few days between a refused push and the banner to act on either"
fi
if [ 150830 -gt "$BUDGET" ]; then ok; else
  bad "the index size that actually produced the platform warning, 150830, sits inside the budget, so the budget cannot be what catches it"
fi
if [ "$ENTRY_CAP" -lt 550 ]; then ok; else
  bad "the entry cap is at or above the longest rule sentence in the file, so it cannot shorten anything"
fi
# And the cap is not so tight that an ordinary one sentence rule cannot fit under it.
if [ "$ENTRY_CAP" -ge 120 ]; then ok; else
  bad "the entry cap leaves under 120 characters for a rule, which is too little for one to carry its own condition"
fi

# And the walk really follows an import rather than answering with its starting point.
mkdir -p "$probe/payload"
printf '@inner.md\n' > "$probe/payload/CLAUDE.md"
printf 'x\n' > "$probe/payload/inner.md"
walked="$(PAYLOAD="$probe/payload"; loaded_files | tr '\n' ' ')"
case "$walked" in
  *"CLAUDE.md"*"inner.md"*) ok ;;
  *) bad "the import walk did not follow an import (saw: $walked)" ;;
esac

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
