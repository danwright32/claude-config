#!/usr/bin/env bash
# test-design-score-reopen.sh: the daily check that reopens a "Match the settled design" issue, or
# its milestone, closed below 100% where the close gate could not see it, and the SessionStart hook
# that starts it (claude-config#1386). GitHub is a fake that remembers what is written to it; the
# checks live in skills/design-rounds/score/tests/reopen_tests.py, and this arms the suite's wall
# clock and runs them.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/design-rounds/score/tests" && pwd)"
out="$(mktemp)"
trap 'rm -f "$out"' EXIT
python3 -I "$TESTS/reopen_tests.py" >"$out" 2>&1
rc=$?
cat "$out"
# A crash before the counts were printed must still read as a failure to the runner.
if ! grep -q '^SUITE-RESULT ' "$out"; then
  echo "FAIL: tests/reopen_tests.py ended with exit $rc before reporting its counts"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
exit "$rc"
