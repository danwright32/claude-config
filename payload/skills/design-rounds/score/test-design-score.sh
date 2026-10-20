#!/usr/bin/env bash
# test-design-score.sh: the design match score (claude-config#1364). Its PNG reader against an
# encoder of its own and against Pillow's reading of real files, and the score of a build against
# its settled design on both halves, every way it can fail to be measured included. The checks live
# in tests/score_tests.py; this arms the suite's wall clock and runs them.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# -I keeps the folder a test runs from off the import path; the checks put the score's own folder on
# it themselves.
out="$(mktemp)"
trap 'rm -f "$out"' EXIT
python3 -I "$HERE/tests/score_tests.py" >"$out" 2>&1
rc=$?
cat "$out"
# A crash before the counts were printed (python exits 1 on an uncaught error, as it does on a failed
# check) must still read as a failure to the runner, so the counts line is looked for, not the code.
if ! grep -q '^SUITE-RESULT ' "$out"; then
  echo "FAIL: tests/score_tests.py ended with exit $rc before reporting its counts"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
exit "$rc"
