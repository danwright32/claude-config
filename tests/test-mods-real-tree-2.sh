#!/bin/bash
# Part 2 of the real tree (case 8, tests/mods-real-tree.sh, claude-config#3622): the mods dealt to this
# part are held by tools/check-mods.sh to what Claude Code itself accepts, with the real binary where
# there is one, and UNMEASURED where there is not (L411). tests/test-mods.sh says why the real tree
# is checked in parts.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
. "$DIR/mods-harness.sh" || {
  echo "FAIL: $(basename "$0"): tests/mods-harness.sh is missing or could not be read, so there is no world to run check-mods.sh in. Refusing to run."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
. "$DIR/mods-real-tree.sh" || {
  echo "FAIL: $(basename "$0"): tests/mods-real-tree.sh is missing or could not be read, so the real tree cannot be checked. Refusing to run."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

mods_real_tree_part 2 "$MODS_REAL_TREE_PARTS"

mods_harness_result
