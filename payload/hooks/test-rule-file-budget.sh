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
#   the LIMIT     is NOT a constant. The binary computes it as a fraction of the model's
#                   context window with a floor under it, so a smaller-context model gets a
#                   smaller limit than the 150,000 seen here. Anything recorded below is
#                   therefore the value observed on THIS setup, not a platform guarantee.
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
#   the RATCHET   each file's recorded size plus half again. What this catches is ACCIDENTAL
#                   bloat: a generator that duplicates its output, a merge that doubles a
#                   file, an import that pulls in something huge. Raising a recorded number
#                   is a deliberate act, which is the point: it makes the growth visible
#                   instead of letting it happen one line at a time (L316).
#
# The loaded set is DERIVED by following the imports, never listed here, because a list
# maintained beside the thing it mirrors is the defect this repo keeps finding (L41). A
# file that is loaded and has no recorded size FAILS, so a new import cannot arrive
# unmeasured.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$(cd "$DIR/.." && pwd)"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# The measured warning threshold, in characters, on this setup. See the header: it is not a
# platform constant and it is not a cliff. Re-measure by growing a memory file past it and
# reading the banner, never by reading the docs page.
WARN_LIMIT=150000

# The ceiling this suite actually enforces per file, set below WARN_LIMIT so the suite is what
# reports the crossing rather than a banner somebody happens to have on screen (L429).
BUDGET=120000

# The longest line the generated lessons index may render, counted as it appears in the file,
# "- L429. " prefix included. A rule longer than this carries a SHORT: line in LESSONS.md.
ENTRY_CAP=160

# Recorded sizes, re-measured 2026-09-10 with `wc -c` on the payload copies, after the lessons
# index moved to short forms. Re-measure with:
#   wc -c payload/CLAUDE.md payload/RTK.md payload/LESSONS-INDEX.md
# Raise a number here only when the growth is understood and wanted.
recorded_size() {  # $1 = payload relative path
  case "$1" in
    CLAUDE.md)         printf '40335' ;;
    RTK.md)            printf '966' ;;
    LESSONS-INDEX.md)  printf '90664' ;;
    *)                 printf '' ;;
  esac
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

  ceiling=$(( want + want / 2 ))
  if [ "$bytes" -gt "$ceiling" ]; then
    bad "$rel is $bytes bytes against a recorded $want, which is more than half again as big. If that growth is wanted, raise the recorded number; if it is not, something has duplicated content into a file every session reads."
  else ok; fi

  printf '  %-20s %8s bytes (recorded %s, ratchet %s, budget %s, warns at %s)\n' "$rel" "$bytes" "$want" "$ceiling" "$BUDGET" "$WARN_LIMIT"
done < <(loaded_files)

# A walk that found nothing passes every assertion inside it at once, and would read as a
# clean run of a check that measured no files at all (L98).
if [ "$count" -ge 3 ]; then ok; else
  bad "the import walk found only $count file(s); it should find CLAUDE.md and what it imports, so the checks above measured almost nothing"
fi

printf '  %-20s %8s bytes read at the start of every session, in every project\n' "TOTAL" "$total"

echo "rule file budget: no single index entry is longer than the cap"

# The per-lesson cost is what actually decides the total, because the number of lessons only
# ever goes up. Measured on the GENERATED index rather than on LESSONS.md, because the index is
# what a session loads and a count taken over the source would be a claim about a file nobody
# reads (L418).
#
# A rule too long to render is not shortened in place: LESSONS.md keeps the full sentence and
# gains a `SHORT:` line, which the generator renders instead. So this failing is an instruction
# to write a short form, never to cut a rule down.
index_rel="LESSONS-INDEX.md"
if [ ! -f "$PAYLOAD/$index_rel" ]; then
  bad "$index_rel is not there, so no entry was measured at all"
else
  entries=0; toolong=0; longest=0; longest_num=""
  while IFS= read -r entry; do
    entries=$((entries + 1))
    len=${#entry}
    if [ "$len" -gt "$longest" ]; then longest=$len; longest_num="${entry%%.*}"; fi
    if [ "$len" -gt "$ENTRY_CAP" ]; then toolong=$((toolong + 1)); fi
  done < <(grep -E '^- L[0-9]+\.' "$PAYLOAD/$index_rel" 2>/dev/null)

  # A scan that matched nothing passes the length test on every entry it did not find, and reads
  # exactly like an index where every entry is short (L98).
  if [ "$entries" -ge 100 ]; then ok; else
    bad "only $entries index entries were found to measure; the index holds hundreds, so the cap above was applied to almost nothing"
  fi

  if [ "$toolong" -gt 0 ]; then
    bad "$toolong of $entries lessons render an index line longer than $ENTRY_CAP characters (longest: ${longest_num#- } at $longest). Give each one a 'SHORT: <the rule in one line>' line in its LESSONS.md entry; the full rule stays exactly as it is and the index renders the short form."
  else ok; fi

  printf '  %-20s %8s entries, longest %s chars against a %s cap\n' "$index_rel" "$entries" "$longest" "$ENTRY_CAP"
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
  local ceiling=$(( $2 + $2 / 2 ))
  [ "$1" -gt "$ceiling" ]
}

if over_ratchet 160000 100000; then ok; else bad "a file well past half again as big was not caught"; fi
# The boundary itself, pinned so the rule reads the same way to the next person: the test is
# MORE than half again, so exactly half again is still inside.
if over_ratchet 150000 100000; then bad "exactly half again was reported, but the rule is more than half again"; else ok; fi
if over_ratchet 150001 100000; then ok; else bad "one byte past half again was not caught"; fi
if over_ratchet 149000 100000; then bad "ordinary growth inside the ratchet was reported"; else ok; fi
if over_ratchet 100000 100000; then bad "a file that had not grown at all was reported"; else ok; fi
# The thresholds, pinned against the sizes actually observed, so the arithmetic that failed the
# first time around cannot come back. 150,830 is what LESSONS-INDEX.md measured on the day the
# warning banner first appeared for it.
if [ "$BUDGET" -lt "$WARN_LIMIT" ]; then ok; else
  bad "the budget is not below the warning threshold, so the banner reaches Dan before this suite ever refuses a push"
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
