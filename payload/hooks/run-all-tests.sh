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
