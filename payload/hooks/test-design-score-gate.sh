#!/usr/bin/env bash
# test-design-score-gate.sh: the hooks design-score-gate.sh and design-score-gate.py, which refuse to
# close a "Match the settled design" issue or its milestone below 100% on both halves, and
# `design_score.py post`, which puts the score where they read it (claude-config#1364). GitHub is a
# fake gh; the checks live in skills/design-rounds/score/tests/gate_tests.py, and this arms the suite's wall clock and runs them.
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
python3 -I "$TESTS/gate_tests.py" >"$out" 2>&1
rc=$?
cat "$out"
# A crash before the counts were printed must still read as a failure to the runner.
if ! grep -q '^SUITE-RESULT ' "$out"; then
  echo "FAIL: tests/gate_tests.py ended with exit $rc before reporting its counts"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
exit "$rc"
