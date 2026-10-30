#!/usr/bin/env bash
#
# bounded-run.sh: run one command for at most N seconds, and kill everything it started when the
# bound runs out. Sourced, never run.
#
# ONE copy, because there were about to be two (claude-config#1770). free-space-nudge.sh bounds
# its Xcode cache sweep this way so the prompt hook stays inside its 10 second timeout, and
# check-free-space.sh now runs `top` to name the processes holding memory, which needs the same
# bound for the same reason; pr-merge-quiz.sh's held release asks GitHub through it too (#1786).
# The rule that makes it work is not obvious, so it lives here once (L30, L370). The 10 second timeout and every bound named here are settings, not measurements.
#
# THE WHOLE PROCESS GROUP IS KILLED, never only the command. Killing only the sweep left its
# children (du, the plist reader) holding the caller's capture open until they finished, which the
# nudge's suite caught as a 1 second bound taking 5 (L235, L321). So the command runs in a process
# group of its own and the group is what is signalled.
#
#   bounded_run <seconds> <command> [args...]
#     sets BOUNDED_OUT to everything it printed (standard error included) and BOUNDED_RC to its
#     exit code, or 124 when the bound ran out. A bound of 0 is NOT handed to perl's alarm, where it
#     would cancel the bound and leave the command unbounded: callers treat 0 as "off" and must not
#     call this with it, so it refuses with 125 rather than run unbounded. Zero written any way
#     (00, 000) is zero: only the literal 0 was refused, so "00" reached alarm and ran the command
#     unbounded (claude-config#1931). Which values are zero is lib/whole-number.sh's answer
#     (claude-config#1948); with that file missing every bound is refused, never run unbounded.

# Its own folder by parameter expansion, never dirname (claude-config#1104, test-lib-self-locate.sh).
_BR_LIB="${BASH_SOURCE[0]%/*}"; [ "$_BR_LIB" != "${BASH_SOURCE[0]}" ] || _BR_LIB=.
# shellcheck source=whole-number.sh
. "$_BR_LIB/whole-number.sh" 2>/dev/null

bounded_run() {
  local seconds="$1"; shift
  BOUNDED_RC=0
  BOUNDED_OUT=""
  if ! declare -F whole_above_zero >/dev/null; then
    BOUNDED_RC=125
    BOUNDED_OUT="bounded-run: $_BR_LIB/whole-number.sh is missing, so the bound could not be read and nothing was run"
    return 0
  fi
  whole_above_zero "$seconds" || { BOUNDED_RC=125; return 0; }
  BOUNDED_OUT="$(perl -e '
    my $t = shift @ARGV;
    my $pid = fork();
    exit 127 unless defined $pid;
    if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127; }
    local $SIG{ALRM} = sub { kill "KILL", -$pid; waitpid($pid, 0); exit 124; };
    alarm $t;
    waitpid($pid, 0);
    alarm 0;
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8);' "$seconds" "$@" 2>&1)" || BOUNDED_RC=$?
  return 0
}
