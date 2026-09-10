#!/usr/bin/env bash
#
# test-rule-file-budget.sh: how big the files that load into EVERY session have got.
#
# Why this exists (claude-config#353): CLAUDE.md and everything it imports are read at the
# start of every session, in every project, and they only ever grow, by one line each time
# a lesson is recorded. Nothing measured them.
#
# The cliff is documented and it is total rather than gradual. From
# https://code.claude.com/docs/en/memory, read 2026-09-10: "Claude Code loads a CLAUDE.md
# file of up to 4 MiB in full and skips a larger file." So past 4 MiB the rules do not
# arrive at all, and a rule that never arrived is indistinguishable from one that was read
# and ignored (L429). The same page asks for under 200 lines per file for adherence, which
# is a soft target with no number anything can check, so it is not gated here.
#
# Two thresholds, because they catch different things:
#
#   the CLIFF     4 MiB, where the file silently stops loading. Catastrophic, and at the
#                   current growth rate unreachable, so on its own it is a guard that can
#                   never fire.
#   the RATCHET   each file's recorded size plus half again. This is the one that will
#                   actually fire, and what it catches is ACCIDENTAL bloat: a generator
#                   that duplicates its output, a merge that doubles a file, an import
#                   that pulls in something huge. Raising a recorded number is a
#                   deliberate act, which is the point: it makes the growth visible
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

# The documented cliff, in bytes. 4 MiB.
CLIFF=4194304

# Recorded sizes, measured 2026-09-10 with `wc -c` on the payload copies. Re-measure with:
#   wc -c payload/CLAUDE.md payload/RTK.md payload/LESSONS-INDEX.md
# Raise a number here only when the growth is understood and wanted.
recorded_size() {  # $1 = payload relative path
  case "$1" in
    CLAUDE.md)         printf '40208' ;;
    RTK.md)            printf '966' ;;
    LESSONS-INDEX.md)  printf '149152' ;;
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

  if [ "$bytes" -ge "$CLIFF" ]; then
    bad "$rel is $bytes bytes, at or past the $CLIFF byte cliff, where Claude Code SKIPS the file entirely rather than truncating it. Every rule in it stops arriving, silently."
  else ok; fi

  ceiling=$(( want + want / 2 ))
  if [ "$bytes" -gt "$ceiling" ]; then
    bad "$rel is $bytes bytes against a recorded $want, which is more than half again as big. If that growth is wanted, raise the recorded number; if it is not, something has duplicated content into a file every session reads."
  else ok; fi

  printf '  %-20s %8s bytes (recorded %s, ratchet %s, cliff %s)\n' "$rel" "$bytes" "$want" "$ceiling" "$CLIFF"
done < <(loaded_files)

# A walk that found nothing passes every assertion inside it at once, and would read as a
# clean run of a check that measured no files at all (L98).
if [ "$count" -ge 3 ]; then ok; else
  bad "the import walk found only $count file(s); it should find CLAUDE.md and what it imports, so the checks above measured almost nothing"
fi

printf '  %-20s %8s bytes read at the start of every session, in every project\n' "TOTAL" "$total"

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
if [ "$CLIFF" -le 149152 ]; then bad "the cliff is set below a file that is loading today, so it cannot be a ceiling"; else ok; fi

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
