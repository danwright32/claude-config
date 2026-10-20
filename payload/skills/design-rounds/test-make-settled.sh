#!/usr/bin/env bash
# test-make-settled.sh: chrome_frame.py, which draws a design round inside the product's captured
# chrome (no stand ins), and make-settled.py, which writes the settled design the build is scored
# against (claude-config#1364). The checks live in tests/settled_tests.py; this arms the suite's wall
# clock and runs them.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$(mktemp)"
trap 'rm -f "$out"' EXIT
python3 -I "$HERE/tests/settled_tests.py" >"$out" 2>&1
rc=$?
cat "$out"
# A crash before the counts were printed must still read as a failure to the runner.
if ! grep -q '^SUITE-RESULT ' "$out"; then
  echo "FAIL: tests/settled_tests.py ended with exit $rc before reporting its counts"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
exit "$rc"
