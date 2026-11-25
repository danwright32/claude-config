#!/bin/bash
# Tests for tools/check-mods.sh, the gate that holds every mod in payload/mods to what Claude Code
# itself accepts (claude-config#606), on the real tree. The mods load on both Macs, so a broken one is
# broken twice; this is where it is caught, before the push, rather than as a refusal line in a
# session.
#
# The one case here, case 8, runs the real tree with the real binary where there is one, and says
# UNMEASURED where there is not (CI's Linux runner without MODS_CLAUDE), rather than passing (L411).
# It is the only place in the mods suites the real claude is found, to validate and test the mods,
# never to start a session (L2); section 14 of test-mods-fixtures.sh holds every other piece to that.
#
# This file held every check of the mods gate, 516 of them, until it read up to 777 seconds on
# GitHub's runners (six runs on 2026-11-24 and 25 read 498 to 777), past half of run-all-tests.sh's
# 1,200 second wall limit (claude-config#3622, L315). Its sections are now three suites sharing one harness, tests/mods-harness.sh, which says
# what each holds and what each cost: this one, test-mods-shared-parts.sh (section 9) and
# test-mods-fixtures.sh (every other section, on the stub claude). A comment saying "above" or
# "below", or naming a case by its number, means in whichever of the three holds it. This is the one
# the daily run on the newest Claude Code runs, since it alone depends on which Claude Code is
# installed.
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
# The claude the real tree is checked with (case 8): MODS_CLAUDE where the caller installed one for
# the mods alone, as the pull request checks do without putting it on every suite's PATH (#3297),
# else the one on PATH, else ~/.local/bin/claude.
REAL_BIN="${MODS_CLAUDE:-$(command -v claude 2>/dev/null || true)}"
[ -n "$REAL_BIN" ] || { [ -x "$HOME/.local/bin/claude" ] && REAL_BIN="$HOME/.local/bin/claude"; }

# 8. The real tree, with the real binary where this machine has one (REAL_BIN, found at the top).
#    Nothing before this case starts the real claude, so the record of the build the mods last
#    passed on is read and written here alone.
#    Its failures are kept, and its pass recorded as the build the mods last passed on, where the
#    caller said or in the default places, never in this run's scratch. Given MODS_CLAUDE, the caller
#    promised a claude, so a run that could not check the mods with it fails (#3297).
real_env=(env)
if [ "$REAL_KEPT_SET" = set ]; then real_env+=(CHECK_MODS_FAILURE_OUTPUT="$REAL_KEPT"); else real_env+=(-u CHECK_MODS_FAILURE_OUTPUT); fi
if [ "$REAL_LAST_SET" = set ]; then real_env+=(CHECK_MODS_LAST_PASSED="$REAL_LAST"); else real_env+=(-u CHECK_MODS_LAST_PASSED); fi
[ -z "${MODS_CLAUDE:-}" ] || real_env+=(CHECK_MODS_REQUIRE_CLAUDE=1)
if [ ! -d "$ROOT/payload/mods" ]; then
  # The folder is created by the sync the first time a Mac sends a mod, and never by hand: payload/
  # in a development checkout is overwritten by the live daemon (payload-write-gate.sh).
  # Not a pass over mods, so not counted as one (claude-config#1452, L98): said by the agreed line.
  echo "SUITE-PART-UNMEASURED the real mods, because payload/mods does not exist yet (no Mac has sent a mod), so there is nothing to check"
else
  out="$("${real_env[@]}" CLAUDE_BIN="${REAL_BIN:-$TMPROOT/no-such-claude}" bash "$CHECK" "$ROOT/payload/mods" 2>&1)"; code=$?
  # check-mods says first when Claude Code changed since the mods last passed on this Mac (#3297).
  # Marked, so the runner prints it under this suite's line whether the suite passed or failed, and
  # put in front of a failure below, so a red reads as that change before anyone hunts for a commit.
  real_note="$(printf '%s\n' "$out" | sed -n 's/^check-mods: \(Claude Code changed since the mods last passed .*\)$/\1/p' | head -n 1)"
  [ -z "$real_note" ] || echo "SUITE-NOTE $real_note"
  if [ "$code" -eq 3 ]; then
    # Said once, by the agreed line, and counted as nothing (claude-config#1452, L98).
    echo "SUITE-PART-UNMEASURED the real mods against Claude Code's own checks, because there is no claude command on this machine"
    # Their types were checked all the same, wherever the pinned compiler is installed (#953).
    if [ -x "$ROOT/tools/typescript/node_modules/.bin/tsc" ]; then
      nm="$(find "$ROOT/payload/mods" -mindepth 3 -maxdepth 3 -path '*/.claude-plugin/plugin.json' | wc -l | tr -d ' ')"
      printf '%s\n' "$out" | grep -q "^check-mods: $nm of $nm mods type checked against" \
        && check "but every real mod's types were checked, with no claude" ok \
        || check "but every real mod's types were checked, with no claude" "$out"
    fi
  elif [ "$code" -eq 4 ]; then
    # Claude Code's cached rollout switch, which this suite cannot set (#740, L411).
    # Its reasons ride on the one agreed line, which the runner prints; an indented copy below it was
    # dropped like any other chatter (#1444).
    echo "SUITE-PART-UNMEASURED the real mods against Claude Code's own checks, because Claude Code has hooks modules switched off on this machine. check-mods said: $(printf '%s\n' "$out" | grep UNMEASURED | sed 's/^check-mods: //' | tr '\n' ' ')"
  else
    [ "$code" -eq 0 ] && check "every mod in payload/mods passes Claude Code's own checks" ok \
      || check "every mod in payload/mods passes Claude Code's own checks" "${real_note:+$real_note }exit=$code out=$out"
  fi
fi

mods_harness_result
