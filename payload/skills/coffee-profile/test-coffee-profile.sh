#!/usr/bin/env bash
# Suite for the coffee-profile skill. Named test-*.sh so run-all-tests.sh
# discovers it from disk; the tests themselves are Python (stdlib unittest).
#
# Every suite ends with the machine readable result line that
# hooks/test-suite-result-line.sh requires and run-all-tests.sh reads. The
# counts come from unittest's own result object rather than from scraping its
# printed summary (L107), and the line is printed when tests fail too, because
# a suite that exits before printing it reports "no tally could be read"
# instead of the failures it found. Finding no tests at all is a failure, not a
# pass, since an empty run looks exactly like a clean one (L98).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

cd "$(dirname "$0")"

python3 - <<'PY'
import sys
import unittest

suite = unittest.defaultTestLoader.discover("tests", pattern="test_*.py")
result = unittest.TextTestRunner(verbosity=2).run(suite)

# A module that fails to import is reported by discover as an error, so it is
# counted here rather than silently shrinking the run.
failed = len(result.failures) + len(result.errors) + len(result.unexpectedSuccesses)
passed = result.testsRun - failed - len(result.skipped)

if result.testsRun == 0:
    print("test-coffee-profile: discovered no tests under tests/, refusing to report a pass.")
    failed += 1

print(f"passed: {passed}, failed: {failed}")
print(f"SUITE-RESULT passed={passed} failed={failed}")
sys.exit(0 if failed == 0 else 1)
PY
