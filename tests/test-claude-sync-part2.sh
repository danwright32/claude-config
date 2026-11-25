#!/usr/bin/env bash
# The second half of tests/test-claude-sync.sh, run as a suite of its own (claude-config#3594).
#
# That file holds every section, its harness and its prelude, in one place; the sections from the
# heading its SUITE_PART2_FROM names to the end run here, and the ones before it run there. Being
# two suites to the runner is what lets each be timed, budgeted and dealt by its own cost: the
# section time budget in that file holds the work of one run, and the whole suite had grown to it.
# Every knob that file takes works here too, except SUITE_PART, which this sets.
set -uo pipefail
_p2_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Armed here with no limit of its own: the suite this hands over to arms its own, its SUITE_TIMEOUT
# plus a margin, and a second, shorter one here would stop it first on a loaded Mac. A limit the
# caller sets with SUITE_WALL_TIMEOUT still applies, and arming hands the run its throwaway records,
# which the suite then finds already set.
. "$_p2_dir/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm 0 || exit $?

SUITE_PART=2 exec bash "$_p2_dir/test-claude-sync.sh" "$@"
