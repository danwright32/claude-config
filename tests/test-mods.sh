#!/bin/bash
# Tests for tools/check-mods.sh, the gate that holds every mod in payload/mods to what Claude Code
# itself accepts (claude-config#606), on the real tree. The mods load on both Macs, so a broken one is
# broken twice; this is where it is caught, before the push, rather than as a refusal line in a
# session.
#
# This is part 1 of the real tree (case 8, tests/mods-real-tree.sh): the mods dealt to it are run
# with the real binary where there is one, and it says UNMEASURED where there is not (CI's Linux
# runner without MODS_CLAUDE), rather than passing (L411). Its siblings test-mods-real-tree-2.sh and
# test-mods-real-tree-3.sh hold the other parts; together they check every mod, and one run's parts
# together record the build the mods last passed on.
#
# This file held every check of the mods gate, 516 of them, until it read up to 777 seconds on
# GitHub's runners (six runs on 2026-11-24 and 25 read 498 to 777), past half of run-all-tests.sh's
# 1,200 second wall limit (claude-config#3622, L315). Its sections are now suites sharing one harness,
# tests/mods-harness.sh, which says what each holds and what each cost: the real tree's parts,
# test-mods-shared-parts.sh (section 9) and test-mods-fixtures.sh (every other section, on the stub
# claude). Then its one remaining check, the real tree, read 490 and 667 s by itself on a runner, so it
# was cut into parts as well. A comment saying "above" or "below", or naming a case by its number,
# means in whichever piece holds it. The daily run on the newest Claude Code runs the real tree's
# parts, since they alone depend on which Claude Code is installed.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
# The world every mods suite runs in (tests/mods-harness.sh, claude-config#3622). Without it there is
# no check-mods.sh to run and no stub to run it with, so the suite refuses, by the agreed line.
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

mods_real_tree_part 1 "$MODS_REAL_TREE_PARTS"

mods_harness_result
