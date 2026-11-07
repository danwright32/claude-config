#!/usr/bin/env bash
#
# suite-arms-check.sh: the one answer to whether a test suite arms its own wall clock
# (claude-config#465, #2330).
#
# Sourced, never executed. Every suite the runner runs sources lib/suite-deadline.sh and calls
# suite_deadline_arm near its top, so run directly it is bounded and takes what it started with it
# when it stops. Two places ask whether a suite does: test-suite-deadline.sh, over every suite the
# runner runs, in the full suite; and scanners-before-push.sh, over each test-*.sh a push adds or
# changes, as the push delivers it. Until #2330 only the first asked, so on 2026-11-05 a suite pushed
# without it was found in CI about 40 minutes later. Both call this, so they cannot disagree about a file (L655,
# L370).
#
# A suite arms when it SOURCES the helper and CALLS suite_deadline_arm, each on a line of its own
# that is code rather than a comment, so a suite that only talks about the deadline, as
# test-suite-deadline.sh does in its fixtures' text, does not answer for one that has it (L135,
# L178).

# Why a suite that does not arm is refused, in the words both callers use.
SUITE_ARMS_WHY="do not source lib/suite-deadline.sh and call suite_deadline_arm, so run directly they have no wall clock and nothing stops what they start"

# suite_arms_deadline <suite file> -> 0 when it sources the helper and arms it, 1 when it does not,
# and 2 when the file cannot be read, which is neither verdict and is never reported as one (L10).
suite_arms_deadline() {
  [ -f "$1" ] && [ -r "$1" ] || return 2
  grep -Eq '^[[:space:]]*(\.|source)[[:space:]]+[^#]*suite-deadline\.sh' "$1" 2>/dev/null || return 1
  grep -Eq '^[[:space:]]*suite_deadline_arm([[:space:]]|$)' "$1" 2>/dev/null || return 1
  return 0
}
