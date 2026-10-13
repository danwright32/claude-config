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
    # The lessons core (#565), one file per section, measured 2026-10-09 by rendering the list Dan
    # approved on #563 (355 lessons) with `claude-sync core-set` and a push into a throwaway home,
    # since no live Mac had it set yet. Re-measure the same way, or with
    #   wc -c payload/LESSONS-CORE-*.md
    # once the core is in use.
    LESSONS-CORE-proof-over-green.md)         printf '14685' ;;
    LESSONS-CORE-ux-completeness.md)          printf '6256' ;;
    LESSONS-CORE-honest-failure.md)           printf '4934' ;;
    LESSONS-CORE-cross-system-reliability.md) printf '4932' ;;
    LESSONS-CORE-codebase-hygiene.md)         printf '4615' ;;
    LESSONS-CORE-data-safety.md)              printf '3897' ;;
    LESSONS-CORE-pipeline-speed.md)           printf '3814' ;;
    LESSONS-CORE-state-and-identity.md)       printf '3306' ;;
    LESSONS-CORE-external-systems.md)         printf '2634' ;;
    LESSONS-CORE-security-and-privacy.md)     printf '2187' ;;
    LESSONS-CORE-test-speed.md)               printf '1700' ;;
    LESSONS-CORE-building-with-ai.md)         printf '1412' ;;
    # The library's table of contents, imported after the core (#566), measured the same way.
    LESSONS-CORE-_TOC.md)                     printf '1111' ;;
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
#
# The same walk reads a file from disk or, with LF_REPO and LF_REV set, as it stood at a commit of the
# checkout's history, which is how the growth reading below measures the loaded set in the past. One
# walk for both, so the set measured then is decided by the rule that decides it now (L370).
rule_file_text() {  # $1 = payload relative path; prints it, nothing when it is not there
  if [ -n "${LF_REV:-}" ]; then
    git -C "$LF_REPO" show "$LF_REV:payload/$1" 2>/dev/null
  elif [ -f "$PAYLOAD/$1" ]; then
    cat "$PAYLOAD/$1"
  fi
  return 0
}
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
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      queue="${queue:+$queue|}$target"
    done < <(rule_file_text "$current" | grep -oE '^@[^[:space:]]+' 2>/dev/null | sed 's/^@//')
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

echo "rule file budget: the lessons core"

# THE CORE (claude-config#565). Since Dan's reversal on 2026-09-24 a session loads the lessons core
# (LESSONS-CORE-<section>.md, rendered by claude-sync from LESSONS-CORE.txt) in place of the whole
# library whenever a list is set, and the whole library only when none is or the list is unusable.
# The list is set on a live Mac with `claude-sync core-set`, not by a change here, so the moment it
# is set the payload starts importing core files. Every core file a section can produce therefore
# needs its recorded size BEFORE that happens, or the walk above fails every push and every pull on
# the day the core is switched on. The names are derived from the library files present, never
# listed, so a section added later is asked for here at once (L41).
for _lib in "$PAYLOAD"/LESSONS-INDEX-*.md; do
  [ -f "$_lib" ] || continue
  _core="LESSONS-CORE-${_lib##*/LESSONS-INDEX-}"
  if [ -n "$(recorded_size "$_core")" ]; then ok; else
    bad "$_core has no recorded size, and the lessons core renders it the moment a core list names a lesson in that section. Measure it from a core render (see recorded_size) and add it, so switching the core on cannot fail this suite."
  fi
done
# And the library's table of contents, which loads beside ANY core (#566). Its name is claude-sync's
# LESSON_CORE_TOC, spelled here because this suite also runs from ~/.claude, where claude-sync is not.
if [ -n "$(recorded_size LESSONS-CORE-_TOC.md)" ]; then ok; else
  bad "LESSONS-CORE-_TOC.md has no recorded size, and it loads beside any lessons core. Measure it from a core render and add it to recorded_size."
fi

# THE CORE'S OWN TOTAL, ratcheted like a file. The per file ratchets above each allow at least
# MIN_RATCHET_HEADROOM of growth, which over a dozen core files is more than the whole core, so they
# cannot see the core as a whole doubling. A re-rank that moves lessons in is a list change nobody
# reviews here, so this is what makes growth in the core a deliberate act (L316). Recorded from the
# list Dan approved on 2026-09-24 (#563): 355 lessons, 50,246 index characters, 54,372 bytes with
# the file headers, plus 1,111 for the library's table of contents (#566), rendered against
# LESSONS.md on 2026-10-09. The cap `claude-sync core-set` enforces (SYNC_CORE_CAP, 20,000) is a
# separate decision, made at the list, and Dan chose to go over it for this list.
CORE_RECORDED=55483
core_total=0
core_files=0
while IFS= read -r rel; do
  case "$rel" in LESSONS-CORE-*.md) ;; *) continue ;; esac
  [ -f "$PAYLOAD/$rel" ] || continue
  core_files=$((core_files + 1))
  core_total=$((core_total + $(wc -c < "$PAYLOAD/$rel" | tr -d ' ')))
done < <(loaded_files)
core_ceiling="$(ratchet_ceiling "$CORE_RECORDED")"
if [ "$core_files" -eq 0 ]; then
  ok
  printf '  %-42s %8s (no core list is set, so the whole library loads)\n' "lessons core" "off"
elif [ "$core_total" -gt "$core_ceiling" ]; then
  bad "the lessons core loads $core_total bytes across $core_files files against a recorded $CORE_RECORDED, past the $core_ceiling it is ratcheted to. If a re-rank grew it on purpose, raise CORE_RECORDED; if not, the list holds lessons nobody chose."
else
  ok
  printf '  %-42s %8s bytes in %s files (recorded %s, ratchet %s)\n' "lessons core" "$core_total" "$core_files" "$CORE_RECORDED" "$core_ceiling"
fi

# THE TOTAL, reported and never refused (claude-config#546). Claude Code shows its large-memory-files
# banner for the SUM of the loaded instruction files as well as for any one of them: the larger of
# 120,000 and the per file figure, which is 150,000 on a 1M window (read out of the 2.1.281 binary;
# see the header). This set measured 144,957 on 2026-09-23. A refusal was considered and declined by
# Dan on 2026-09-23: the banner drops no rule, and this suite also runs inside every pull, so a
# refusal here would stall the config syncing between the Macs for a warning. So it is a SUITE-NOTE,
# which the runner prints for a passing suite and the pull carries into its summary, stating the
# total, the room left or the amount over, and how long the room lasts at the rate the set grows.
# The project's own CLAUDE.md is loaded as well and counts toward the same sum, so the room shown
# is an upper bound.
TOTAL_WARN=150000
TOTAL_WARN_SMALL_WINDOW=120000

# HOW FAST THE LOADED SET GROWS, measured from its own git history every run (claude-config#1060).
# It used to be a constant, 1,100 characters a day, measured on 2026-09-11 while every session
# loaded the whole library, so every new lesson grew the loaded set. Since the lessons core went
# live (#565, imports switched 2026-10-09) a session loads a fixed core: a new lesson enters the
# library, not the loaded set, which grows only when the core list or CLAUDE.md changes. The
# constant went on projecting a deadline for a total that was not on that path, and a stale
# projection can prompt pruning lessons for nothing. So the premise is re-measured rather than
# recorded (L316): the growth of exactly the files loaded now, over the last GROWTH_WINDOW_DAYS of
# history, and never across the commit that last changed WHICH files load (switching the core on or
# off, a section added), because the growth of a different set says nothing about this one.
#
# The end point is the newest commit and the start is a commit's tree, so the reading is decided by
# history alone and never by the clock (L713). A reading that cannot be made says UNMEASURED and why,
# never a number (L460): no git history here and no checkout handed in, a set that took its current
# shape fewer than GROWTH_MIN_DAYS ago, history that does not reach back, or an installed copy that
# loads a different set from the checkout's history (a Mac with no core set loads the library).
#
# The 30 days and the 14 are CHOSEN: a re-rank moves the core at most once a month, so a window
# shorter than a month can read a growing core as flat, and two weeks is the least history worth a
# rate at all. Re-measure the rate itself by running this suite in a checkout.
GROWTH_WINDOW_DAYS=30
GROWTH_MIN_DAYS=14
# The checkout whose history describes $1: the git work tree it sits in as payload/, else the one a
# pull hands the runner in RUN_ALL_TESTS_CHECKOUT (the installed copy in ~/.claude has no history of
# its own). Nothing when neither.
growth_repo() {  # $1 = payload directory
  local top
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || top=""
  if [ -n "$top" ] && [ "$top/payload" -ef "$1" ]; then printf '%s' "$top"; return 0; fi
  top="${RUN_ALL_TESTS_CHECKOUT:-}"
  if [ -n "$top" ] && [ -f "$top/payload/CLAUDE.md" ] && git -C "$top" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    printf '%s' "${top%/}"; return 0
  fi
  return 0
}
loaded_total_at() {  # $1 = repo  $2 = revision -> bytes of the set loaded at that revision
  local rel n sum=0
  while IFS= read -r rel; do
    n="$(git -C "$1" cat-file -s "$2:payload/$rel" 2>/dev/null)" || n=0
    sum=$(( sum + ${n:-0} ))
  done < <(LF_REPO="$1" LF_REV="$2" loaded_files)
  printf '%s' "$sum"
}
# One line: RATE <grown> <days> <newest date> | FLAT <days> <newest date> | UNMEASURED <why>.
growth_reading() {  # $1 = payload directory
  local repo now_set head_set end start shape shape_at base days grown paths=() rel
  repo="$(growth_repo "$1")"
  if [ -z "$repo" ]; then
    printf 'UNMEASURED %s has no git history and no checkout was handed in (RUN_ALL_TESTS_CHECKOUT), so how fast the set grows cannot be read' "$1"; return 0
  fi
  now_set="$(PAYLOAD="$1" loaded_files | LC_ALL=C sort | tr '\n' ' ')"
  head_set="$(LF_REPO="$repo" LF_REV=HEAD loaded_files | LC_ALL=C sort | tr '\n' ' ')"
  if [ "$now_set" != "$head_set" ]; then
    printf 'UNMEASURED this Mac loads %sand the checkout at %s loads %s, so the checkout'"'"'s history is not the history of this set' "$now_set" "$repo" "${head_set% }"; return 0
  fi
  end="$(git -C "$repo" log -1 --format=%ct HEAD 2>/dev/null)"
  case "$end" in ''|*[!0-9]*) printf 'UNMEASURED the newest commit of %s has no readable date' "$repo"; return 0 ;; esac
  while IFS= read -r rel; do paths+=("payload/$rel"); done < <(LF_REPO="$repo" LF_REV=HEAD loaded_files)
  # The newest commit that added or removed an import line in a loaded file: where this set began.
  shape="$(git -C "$repo" log -1 --format='%H %ct' -G'^@[^[:space:]]' HEAD -- "${paths[@]}" 2>/dev/null)"
  start=$(( end - GROWTH_WINDOW_DAYS * 86400 ))
  shape_at="${shape#* }"
  if [ -n "$shape" ] && [ "$shape_at" -ge "$start" ]; then
    start="$shape_at"; base="${shape%% *}"
  else
    base="$(git -C "$repo" rev-list -1 --first-parent --before="$start" HEAD 2>/dev/null)"
  fi
  days=$(( (end - start) / 86400 ))
  if [ "$days" -lt "$GROWTH_MIN_DAYS" ]; then
    printf 'UNMEASURED the files loaded now took their current shape on %s, %s days before the newest commit, under the %s days of history a rate needs' \
      "$(git -C "$repo" log -1 --format=%cd --date=short "$base" 2>/dev/null)" "$days" "$GROWTH_MIN_DAYS"; return 0
  fi
  if [ -z "$base" ]; then
    printf 'UNMEASURED the history of %s does not reach back %s days' "$repo" "$GROWTH_WINDOW_DAYS"; return 0
  fi
  grown=$(( $(loaded_total_at "$repo" HEAD) - $(loaded_total_at "$repo" "$base") ))
  if [ "$grown" -gt 0 ]; then
    printf 'RATE %s %s %s' "$grown" "$days" "$(git -C "$repo" log -1 --format=%cd --date=short HEAD)"
  else
    printf 'FLAT %s %s' "$days" "$(git -C "$repo" log -1 --format=%cd --date=short HEAD)"
  fi
}
total_note() {  # $1 = total bytes  $2 = a growth_reading line -> the one line note
  local t="$1" g="${2:-UNMEASURED no growth reading was taken}" grown days to room
  if [ "$t" -gt "$TOTAL_WARN" ]; then
    printf 'the rule files every session loads total %s characters, %s past the %s at which Claude Code shows its size warning on a 1M window (%s on a 200k one). Nothing is dropped; each session carries the warning and the context it costs.' \
      "$t" "$(( t - TOTAL_WARN ))" "$TOTAL_WARN" "$TOTAL_WARN_SMALL_WINDOW"
    return 0
  fi
  room=$(( TOTAL_WARN - t ))
  # The 200k window's own figure, read against the total rather than asserted: the sentence used to
  # say "already past" it whatever the total, which stopped being true once the core loaded 94,464.
  local small
  if [ "$t" -gt "$TOTAL_WARN_SMALL_WINDOW" ]; then small="already past the $TOTAL_WARN_SMALL_WINDOW of a 200k window"
  else small="$(( TOTAL_WARN_SMALL_WINDOW - t )) under the $TOTAL_WARN_SMALL_WINDOW of a 200k window"; fi
  printf 'the rule files every session loads total %s characters, %s under the %s at which Claude Code shows its size warning on a 1M window (%s)' \
    "$t" "$room" "$TOTAL_WARN" "$small"
  case "$g" in
    RATE\ *)
      read -r _ grown days to <<< "$g"
      printf ', about %s days at the rate they grew, %s characters over the last %s days of their history to %s.' \
        "$(( room * days / grown ))" "$grown" "$days" "$to" ;;
    FLAT\ *)
      read -r _ days to <<< "$g"
      printf ', and they did not grow over the last %s days of their history to %s, so no date is projected.' "$days" "$to" ;;
    *)
      printf '. How fast they grow is UNMEASURED: %s.' "${g#UNMEASURED }" ;;
  esac
}
printf 'SUITE-NOTE %s\n' "$(total_note "$total" "$(growth_reading "$PAYLOAD")")"

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
# The total note, every reading, so none can quietly stop saying what it measured (L151).
case "$(total_note 140000 "RATE 2000 20 2026-01-21")" in *"10000 under the 150000"*"about 100 days"*"2000 characters over the last 20 days"*) ok ;; *) bad "the total note under the warning does not give the room left, the days, and the growth they come from: $(total_note 140000 "RATE 2000 20 2026-01-21")" ;; esac
case "$(total_note 140000 "FLAT 20 2026-01-21")" in *"10000 under the 150000"*"did not grow over the last 20 days"*) ok ;; *) bad "the total note for a set that is not growing does not say so: $(total_note 140000 "FLAT 20 2026-01-21")" ;; esac
case "$(total_note 140000 "FLAT 20 2026-01-21")" in *"days at"*|*"about "*" days"*) bad "a set that is not growing was still given a number of days: $(total_note 140000 "FLAT 20 2026-01-21")" ;; *) ok ;; esac
case "$(total_note 140000 "UNMEASURED there is no history")" in *"10000 under the 150000"*"UNMEASURED"*"there is no history"*) ok ;; *) bad "the total note with no measured growth does not say UNMEASURED and why: $(total_note 140000 "UNMEASURED there is no history")" ;; esac
case "$(total_note 140000 "FLAT 20 2026-01-21")" in *"already past the 120000"*) ok ;; *) bad "a total over the 200k window's figure does not say it is past it: $(total_note 140000 "FLAT 20 2026-01-21")" ;; esac
case "$(total_note 100000 "FLAT 20 2026-01-21")" in *"already past"*) bad "a total under the 200k window's figure is said to be past it: $(total_note 100000 "FLAT 20 2026-01-21")" ;; *"20000 under the 120000"*) ok ;; *) bad "a total under the 200k window's figure does not give the room left under it: $(total_note 100000 "FLAT 20 2026-01-21")" ;; esac
case "$(total_note 151000 "RATE 2000 20 2026-01-21")" in *"1000 past the 150000"*"Nothing is dropped"*) ok ;; *) bad "the total note past the warning does not say how far past, or that nothing is dropped: $(total_note 151000 "RATE 2000 20 2026-01-21")" ;; esac

# THE GROWTH RATE, derived from the loaded set's own git history (claude-config#1060), never a
# constant. It was 1,100 a day, measured on 2026-09-11 while every session loaded the whole library;
# with a lessons core set, a session loads a fixed core and grows only when the core changes, so the
# constant projected a deadline for a total that was not on that path (L316). Driven against fixture
# histories with committed dates, so nothing here reads the clock.
if ! command -v git >/dev/null 2>&1; then
  echo "UNMEASURED: git is not installed here, so the growth readings were not checked"
else
  GH_EPOCH=1767225600   # 2026-01-01T00:00:00Z
  gh_commit(){ # gh_commit <repo> <day> <message>: commit the whole tree as of that day
    local when=$(( GH_EPOCH + $2 * 86400 ))
    git -C "$1" add -A >/dev/null 2>&1
    GIT_AUTHOR_DATE="$when +0000" GIT_COMMITTER_DATE="$when +0000" git -C "$1" -c user.name=t -c user.email=t@e commit -q -m "$3" >/dev/null 2>&1
  }
  gh_bytes(){ head -c "$1" /dev/zero | tr '\0' 'x'; }
  GH="$probe/history"; mkdir -p "$GH/payload"; git -C "$GH" init -q >/dev/null 2>&1
  # No core: the whole library loads, and it grows by 1,000 characters every ten days.
  printf '@LESSONS-INDEX-a.md\nrules\n' > "$GH/payload/CLAUDE.md"
  gh_bytes 1000 > "$GH/payload/LESSONS-INDEX-a.md"; gh_commit "$GH" 0 "library"
  gh_bytes 2000 > "$GH/payload/LESSONS-INDEX-a.md"; gh_commit "$GH" 10 "a lesson"
  gh_bytes 3000 > "$GH/payload/LESSONS-INDEX-a.md"; gh_commit "$GH" 20 "a lesson"
  reading="$(RUN_ALL_TESTS_CHECKOUT="" growth_reading "$GH/payload")"
  case "$reading" in "RATE 2000 20 "*) ok ;; *) bad "with no core, the library's growth over its 20 days of history was not measured as 2000 over 20 days: $reading" ;; esac
  # A lesson added to the LIBRARY after a core is set does not count: the core is what loads.
  printf '@LESSONS-CORE-a.md\nrules\n' > "$GH/payload/CLAUDE.md"
  gh_bytes 500 > "$GH/payload/LESSONS-CORE-a.md"; gh_commit "$GH" 25 "the core is set"
  reading="$(RUN_ALL_TESTS_CHECKOUT="" growth_reading "$GH/payload")"
  case "$reading" in "UNMEASURED "*"2026-01-26"*) ok ;; *) bad "a core set the same day was given a growth rate from the library's history before it: $reading" ;; esac
  gh_bytes 9000 > "$GH/payload/LESSONS-INDEX-a.md"; gh_commit "$GH" 35 "library lessons the core does not load"
  printf '@LESSONS-CORE-a.md\nRULES\n' > "$GH/payload/CLAUDE.md"; gh_commit "$GH" 45 "an edit that imports nothing new"
  reading="$(RUN_ALL_TESTS_CHECKOUT="" growth_reading "$GH/payload")"
  case "$reading" in "FLAT 20 "*) ok ;; *) bad "with a core set 20 days ago and unchanged since, the loaded set was not read as not growing over those 20 days: $reading" ;; esac
  # The core grows when a re-rank moves lessons in: measured over the window, from the core's start.
  gh_bytes 900 > "$GH/payload/LESSONS-CORE-a.md"; gh_commit "$GH" 50 "a re-rank adds lessons"
  reading="$(RUN_ALL_TESTS_CHECKOUT="" growth_reading "$GH/payload")"
  case "$reading" in "RATE 400 25 "*) ok ;; *) bad "a core that grew 400 characters in the 25 days since it was set was not measured so: $reading" ;; esac
  # The window: with history older than it, only the last GROWTH_WINDOW_DAYS count. From day 40 to
  # day 70 the core went from 500 (as it stood on day 40) to 1,300, both re-ranks.
  gh_bytes 1300 > "$GH/payload/LESSONS-CORE-a.md"; gh_commit "$GH" 70 "another re-rank"
  reading="$(RUN_ALL_TESTS_CHECKOUT="" growth_reading "$GH/payload")"
  case "$reading" in "RATE 800 $GROWTH_WINDOW_DAYS "*) ok ;; *) bad "growth was not measured over the last $GROWTH_WINDOW_DAYS days only (expected 800 over $GROWTH_WINDOW_DAYS): $reading" ;; esac
  # A payload with no history of its own is read through the checkout a pull hands the runner.
  INST="$probe/installed"; mkdir -p "$INST"; cp "$GH/payload/CLAUDE.md" "$GH/payload/LESSONS-CORE-a.md" "$INST/"
  reading="$(RUN_ALL_TESTS_CHECKOUT="" growth_reading "$INST")"
  case "$reading" in "UNMEASURED "*) ok ;; *) bad "a payload with no git history and no checkout handed in was given a rate: $reading" ;; esac
  reading="$(RUN_ALL_TESTS_CHECKOUT="$GH" growth_reading "$INST")"
  case "$reading" in "RATE 800 $GROWTH_WINDOW_DAYS "*) ok ;; *) bad "an installed copy was not measured from the checkout handed in RUN_ALL_TESTS_CHECKOUT: $reading" ;; esac
  # But only while it loads the same set as that checkout's history: a Mac with no core set loads
  # the library, and the checkout's core history says nothing about it.
  printf '@LESSONS-INDEX-a.md\nrules\n' > "$INST/CLAUDE.md"; cp "$GH/payload/LESSONS-INDEX-a.md" "$INST/"
  reading="$(RUN_ALL_TESTS_CHECKOUT="$GH" growth_reading "$INST")"
  case "$reading" in "UNMEASURED "*"LESSONS-INDEX-a.md"*) ok ;; *) bad "an installed copy loading a different set from the checkout was given the checkout's rate: $reading" ;; esac
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
