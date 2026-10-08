#!/usr/bin/env bash
# Suite for the pennie-dev-update skill's scripts, gather.js and lint-post.js (claude-config#680).
# Named test-*.sh so run-all-tests.sh discovers it from disk; the cases themselves are in
# tests/scripts.test.js, which prints the machine readable result line this wrapper passes on.
#
# The cases never reach GitHub, Slack or the real state file: GitHub is tests/fake-gh.js through
# the PENNIE_DEV_UPDATE_GH seam, and a gh that fails loudly is put first on PATH beside it.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not on PATH, so the pennie-dev-update scripts cannot be tested."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

out="$(node "$DIR/tests/scripts.test.js" 2>&1)"
rc=$?
printf '%s\n' "$out" | grep -v '^SUITE-RESULT '
# The tally comes from the test file's own counters. A run that died before printing it (a syntax
# error, a crash) has no tally, and that is a failure, never a pass with nothing counted (L98).
tally="$(printf '%s\n' "$out" | grep '^SUITE-RESULT ' | tail -n 1)"
if [ -z "$tally" ]; then
  echo "FAIL: tests/scripts.test.js exited $rc without printing its tally."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
printf '%s\n' "$tally"
[ "$rc" -eq 0 ]
