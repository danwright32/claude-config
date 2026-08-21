#!/usr/bin/env bash
#
# run-all-tests.sh — run every hook test suite and report one verdict.
#
# The suites are discovered from disk (`test-*.sh`), never from a list kept here.
# A hand written list would only ever run the suites someone remembered to add,
# so a new suite could sit unrun while this reported everything green
# (LESSONS.md L96).
#
# Run:  bash ~/.claude/hooks/run-all-tests.sh
#       bash ~/.claude/hooks/run-all-tests.sh <dir>   # a different suite dir
#
# Exit 0 = every suite passed. Exit 1 = at least one failed, or none were found.
# Finding NO suites is a failure, not a pass: an empty run is indistinguishable
# from a clean one otherwise (LESSONS.md L98).

set -uo pipefail

DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
[ -d "$DIR" ] || { echo "run-all-tests: no such directory: $DIR" >&2; exit 1; }

# How many lines of a failing suite's own output to print. Enough to act on, bounded so one
# broken suite cannot bury the other fourteen verdicts.
FAIL_DETAIL_MAX="${HOOK_TESTS_FAIL_DETAIL_MAX:-40}"

ran=0
failed=0
failed_names=""

for suite in "$DIR"/test-*.sh; do
  [ -e "$suite" ] || continue
  name="$(basename "$suite")"
  ran=$((ran+1))
  out="$(bash "$suite" 2>&1)"
  code=$?
  # Trust the exit code, and fall back to the printed summary only when a suite
  # exits 0 while its own tally says otherwise.
  tally="$(printf '%s' "$out" | grep -Eio 'failed:? *[0-9]+' | tail -1 | grep -Eo '[0-9]+' || true)"
  if [ "$code" -ne 0 ] || { [ -n "$tally" ] && [ "$tally" -gt 0 ]; }; then
    failed=$((failed+1))
    failed_names="$failed_names $name"
    printf '  FAIL  %-38s %s\n' "$name" "$(printf '%s' "$out" | grep -Ei 'passed' | tail -1)"
    # And WHY. A one line verdict is enough on a machine where you can just run the suite
    # again; it is useless where you cannot, which is the whole point of running these
    # somewhere else (claude-config#101). The failing lines are printed, and the count is
    # said out loud when there are more than fit, so a truncated report cannot read as a
    # complete one.
    detail="$(printf '%s\n' "$out" | grep -E '^ *(FAIL|not ok)' || true)"
    [ -n "$detail" ] || detail="$(printf '%s\n' "$out" | tail -n "$FAIL_DETAIL_MAX")"
    shown="$(printf '%s\n' "$detail" | grep -c . || true)"
    printf '%s\n' "$detail" | head -n "$FAIL_DETAIL_MAX" | sed 's/^/          /'
    if [ "${shown:-0}" -gt "$FAIL_DETAIL_MAX" ]; then
      printf '          ...and %s more line(s) not shown\n' "$(( shown - FAIL_DETAIL_MAX ))"
    fi
  else
    printf '  ok    %-38s %s\n' "$name" "$(printf '%s' "$out" | grep -Ei 'passed' | tail -1)"
  fi
done

echo
if [ "$ran" -eq 0 ]; then
  echo "NO TEST SUITES FOUND in $DIR — nothing was verified. Treat this as a failure."
  exit 1
fi
if [ "$failed" -eq 0 ]; then
  echo "ALL $ran HOOK SUITES PASSED"
  exit 0
fi
echo "$failed of $ran HOOK SUITES FAILED:$failed_names"
exit 1
