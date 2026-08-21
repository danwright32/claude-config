#!/usr/bin/env bash
# A ratchet on hooks that no test suite names (claude-config#124).
#
# Eleven of them had nothing, including subagent-digest.py, whose own docstring spells out a three
# way contract and explains exactly why the three have to stay apart. Nothing anywhere reported the
# gap: a hook with no suite looks identical to one whose suite passes (L98), and the number was
# never written down, so it could grow without anybody noticing it had.
#
# So the list is written down and compared against what the files actually say. It fails in BOTH
# directions on purpose. Growing means a hook arrived without a suite. Shrinking without the file
# being edited means a name here is stale, and a ratchet nobody has to tighten quietly becomes a
# permanent excuse rather than a measurement (L182).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINE="${HOOK_COVERAGE_BASELINE:-$DIR/uncovered-hooks.txt}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

# The predicate, in one place, so the baseline records an answer this produced rather than a second
# definition of the question drifting beside it (L107).
uncovered_now() { # uncovered_now <hooks dir>  -> one basename per line, sorted
  local d="${1%/}" f b
  # The suites are collected FIRST, and only ones that exist are passed to grep. Handed a path
  # that is not there, grep exits 2, and a caller testing only for non-zero reads that error as
  # "found no mention" and reports every hook as uncovered. It did exactly that here, against a
  # fixture whose whole point was one covered file (L184: judge by what the command measured, not
  # by a non-zero exit that could be either answer).
  local suites=()
  for f in "$d"/test-*.sh "$d"/../../tests/test-*.sh; do
    [ -f "$f" ] && suites+=("$f")
  done
  # No suites at all is not "everything is uncovered", it is a derivation that read nothing, and
  # the caller has to be able to tell those apart (L98).
  [ "${#suites[@]}" -gt 0 ] || return 3
  for f in "$d"/*.sh "$d"/*.py "$d"/lib/*.sh; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in test-*|run-all-tests.sh) continue ;; esac
    if ! grep -lF "$b" "${suites[@]}" >/dev/null 2>&1; then
      printf '%s\n' "$b"
    fi
  done | sort -u
}
read_baseline() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | sed 's/[[:space:]]*$//' | sort -u; }

[ -f "$BASELINE" ] || { echo "test-hook-coverage: no baseline at $BASELINE, so there is nothing to compare against and nothing was verified." >&2; exit 2; }

# ---------------------------------------------------------------------------
# The derivation has to be able to see BOTH answers before the real comparison is trusted, or a
# predicate that matched nothing would report a perfectly covered tree (L98, L1).
# ---------------------------------------------------------------------------
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.hookcov.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-hook-coverage: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT
FIX="$TMPROOT/hooks"; mkdir -p "$FIX/lib"
printf '#!/usr/bin/env bash\n' > "$FIX/covered.sh"
printf '#!/usr/bin/env bash\n' > "$FIX/naked.sh"
printf '#!/usr/bin/env bash\nbash "$DIR/covered.sh"\n' > "$FIX/test-covered.sh"
got="$(uncovered_now "$FIX")"
[ "$got" = "naked.sh" ] \
  && check "the derivation names a hook no suite mentions, and only that one" ok \
  || check "the derivation names a hook no suite mentions, and only that one" "it answered: [$got]"

# ---------------------------------------------------------------------------
# The comparison itself, both directions, against a fixture before the real tree.
# ---------------------------------------------------------------------------
# Reading no suites at all is its own answer, not "every hook is uncovered". A directory holding
# hooks and no suites is what a half-copied tree looks like, and reporting nine uncovered hooks
# there is a measurement nobody could act on.
NOSUITES="$TMPROOT/nosuites"; mkdir -p "$NOSUITES/lib"
printf '#!/usr/bin/env bash\n' > "$NOSUITES/lonely.sh"
uncovered_now "$NOSUITES" >/dev/null 2>&1
[ "$?" -eq 3 ] \
  && check "a directory with no suites at all is refused, not reported as all-uncovered" ok \
  || check "a directory with no suites at all is refused, not reported as all-uncovered" "it answered instead of refusing"

printf 'naked.sh\nsomething-that-left.sh\n' > "$TMPROOT/stale-baseline.txt"
stale="$(comm -13 <(uncovered_now "$FIX") <(read_baseline "$TMPROOT/stale-baseline.txt"))"
[ "$stale" = "something-that-left.sh" ] \
  && check "a baseline naming something no longer uncovered is spotted" ok \
  || check "a baseline naming something no longer uncovered is spotted" "it spotted: [$stale]"
printf '# nothing\n' > "$TMPROOT/empty-baseline.txt"
grew="$(comm -23 <(uncovered_now "$FIX") <(read_baseline "$TMPROOT/empty-baseline.txt"))"
[ "$grew" = "naked.sh" ] \
  && check "a hook missing from the baseline is spotted" ok \
  || check "a hook missing from the baseline is spotted" "it spotted: [$grew]"

# ---------------------------------------------------------------------------
# The real tree.
# ---------------------------------------------------------------------------
now="$(uncovered_now "$DIR")"
base="$(read_baseline "$BASELINE")"
n_now="$(printf '%s\n' "$now" | grep -c . || true)"
n_base="$(printf '%s\n' "$base" | grep -c . || true)"

# NOT "the baseline is non empty". It is allowed to reach zero, and reaching zero is the point of a
# ratchet. What must stay true is that the derivation can still SEE an uncovered hook, and that is
# proved above against a fixture built to hold one, every run, whatever the real tree says. A count
# at zero read as proof the thing cannot happen is exactly how a ratchet stops being a measurement
# (L182), so the proof lives in the fixture rather than in the number.
if [ "${n_base:-0}" -eq 0 ]; then
  echo "test-hook-coverage: the baseline is empty, so every hook is named by some suite. The"
  echo "  derivation was still watched finding one, against the fixture above."
fi

new_gaps="$(comm -23 <(printf '%s\n' "$now") <(printf '%s\n' "$base") | grep -v '^$' || true)"
case "$new_gaps" in
  *[![:space:]]*)
    check "no hook has arrived without a suite" "these are named by no test-*.sh and are not in $(basename "$BASELINE"):
$(printf '%s\n' "$new_gaps" | sed 's/^/    /')
  Write it a suite, or add the name to the baseline and say why in the same change." ;;
  *) check "no hook has arrived without a suite" ok ;;
esac

closed="$(comm -13 <(printf '%s\n' "$now") <(printf '%s\n' "$base") | grep -v '^$' || true)"
case "$closed" in
  *[![:space:]]*)
    check "the baseline has been tightened as suites were written" "these are covered now, or gone, and are still listed in $(basename "$BASELINE"):
$(printf '%s\n' "$closed" | sed 's/^/    /')
  Remove them, so the number left keeps meaning something." ;;
  *) check "the baseline has been tightened as suites were written" ok ;;
esac

echo "test-hook-coverage: $n_now hook(s) named by no suite, baseline says $n_base."
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
