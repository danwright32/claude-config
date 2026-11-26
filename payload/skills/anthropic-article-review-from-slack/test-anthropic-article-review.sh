#!/usr/bin/env bash
# Suite for the anthropic-article-review-from-slack skill's script, review.js (claude-config#3544).
# Named test-*.sh so run-all-tests.sh discovers it from disk; the cases are in tests/review.test.js,
# which prints the machine readable result line this wrapper passes on.
#
# The cases never reach Slack, GitHub or this Mac's real log: HOME is a scratch directory in every
# run, and the app repositories they measure are made there with a local origin.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

for tool in node git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool is not on PATH, so the article review script cannot be tested."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1
  fi
done

out="$(node "$DIR/tests/review.test.js" 2>&1)"
rc=$?
printf '%s\n' "$out" | grep -v '^SUITE-RESULT '
# The tally comes from the test file's own counters. A run that died before printing it (a syntax
# error, a crash) has no tally, and that is a failure, never a pass with nothing counted (L98).
tally="$(printf '%s\n' "$out" | grep '^SUITE-RESULT ' | tail -n 1)"
if [ -z "$tally" ]; then
  echo "FAIL: tests/review.test.js exited $rc without printing its tally."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
printf '%s\n' "$tally"
[ "$rc" -eq 0 ]
