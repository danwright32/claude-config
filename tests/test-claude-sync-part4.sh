#!/usr/bin/env bash
# One later part of tests/test-claude-sync.sh, run as a suite of its own (claude-config#3594, #3680).
#
# That file holds every section, its harness and its prelude, in one place. Its SUITE_PARTS_FROM
# names the heading each later part starts at; part k runs from its heading up to the next part's,
# and the sections before the first of them run there, as part 1. Being separate suites to the
# runner is what lets each be timed, budgeted and dealt by its own cost.
#
# Every part's file is this same file, and the part it runs is read from its own name
# (test-claude-sync-part3.sh runs part 3), so the files cannot drift apart: that file's checks
# hold them identical, and hold one to exist for every part and none for a part that does not.
# Every knob that file takes works here too, except SUITE_PART, which this sets.
set -uo pipefail
_p2_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Its own file name with any folder taken off first, so a bare name (run from inside tests/) is
# read the same as a path.
_p2_part="${BASH_SOURCE[0]##*/}"; _p2_part="${_p2_part#test-claude-sync-part}"; _p2_part="${_p2_part%.sh}"
case "$_p2_part" in
  [2-9]|[1-9][0-9]) ;;
  *) echo "FAIL: $(basename "$0"): its name does not end in -part<n>.sh with n of 2 or more, so which part of the suite it runs is not decided. Refusing to run a set nobody chose."
     printf 'SUITE-RESULT passed=0 failed=1\n'
     exit 1 ;;
esac

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

SUITE_PART="$_p2_part" exec bash "$_p2_dir/test-claude-sync.sh" "$@"
