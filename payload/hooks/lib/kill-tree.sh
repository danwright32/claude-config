#!/usr/bin/env bash
#
# kill-tree.sh: kill everything a process started, from the leaves up.
#
# ONE implementation, because there were three (claude-config#169). The sync suite grew one for
# #163, run-all-tests.sh grew a second for #165 the same day, and the deadline watchdog has had a
# third since #31. All three carry the same non-obvious rule, and a correction to it would have had
# to reach three places or it reaches two (L30, and the standing rule about consolidating from the
# start rather than leaving it as cleanup).
#
# A COMMAND rather than a sourced function, because the two callers are in different trees and
# neither is a library. The cost is one process per cleanup, paid on a path that is already tearing
# a run down.
#
# A PROCESS THAT IS STILL RUNNING CAN REPLACE WHAT YOU JUST KILLED, and that is the whole reason
# this file has the shape it does (claude-config#174). Measured 2026-08-22: a run stalled in
# `while :; do sleep 3600 & wait "$!"; done` had its sleep killed, its `wait` returned at once, and
# it started a NEW sleep before the walk had finished. The run was then killed outright and the
# replacement survived as an orphan, holding open the pipe its output was being read through, so
# the thing waiting on that output never saw end of file and hung for ever.
#
# So every process is STOPPED before its children are walked. A stopped process cannot fork, which
# closes the window rather than narrowing it.
#
# What is measured and what is not, said plainly. MEASURED, twice each: with this helper and no
# stop, that run hung for ever; with the stop, it finished in 8 seconds and left nothing; and the
# inline walk this replaced, in the SAME fixture, was clean without any stop at all. So the earlier
# claim here that the old version had the same race and won it by being faster was wrong, and it
# was an inference rather than a measurement, which is how it came to be wrong (L203).
#
# NOT established: why calling this out to a separate process loses a race the identical walk wins
# in-line. The likeliest candidate is the gap between the last child dying and the parent being
# killed, which is wider when the walk has to exit a process first, but that has not been shown. It
# does not change what to do, because stopping first removes the whole class rather than that one
# mechanism, and a smaller version of the same fixture would not reproduce it at all, so a probe
# built at that scale answers nothing.
#
# A caller killing a tree that is not its own must stop the ROOT itself before calling, for the
# same reason: the root is a process too, and it is usually the one doing the spawning. That cannot
# be done here, because a caller passing its own pid would be stopping itself and would never come
# back to kill anything.
#
# It kills DESCENDANTS, never the pid it is given and never anything above it. Two callers pass
# their own pid, so killing the argument would kill the cleanup mid-way through.
#
#   kill-tree.sh <pid>
#
#   kill-tree.sh <pid> <report-file>
#
# Exits 0 when it has finished, whether or not it found anything: nothing here can tell a process
# with no children from one whose children have already gone, and both are the same instruction to
# the caller.
#
# What it killed goes to a FILE when one is named, never to stdout, and that is not a style choice.
# Two of the callers pass their OWN pid, and capturing stdout means a command substitution, which
# is itself a child of that pid, so the capture is inside the tree being killed and dies before it
# can be read. Measured: piping this into `sed` killed the `sed`. A file has no such relationship.
set -uo pipefail

SELF=$$

die_usage(){
  echo "kill-tree.sh: needs one process id to kill the descendants of (got '${1:-<nothing>}')." >&2
  exit 2
}

case "${1:-}" in
  ''|*[!0-9]*) die_usage "${1:-}" ;;
esac
REPORT="${2:-}"
[ -n "$REPORT" ] && : > "$REPORT" 2>/dev/null

kill_tree(){   # $1 = a pid whose descendants are to go
  local c pp
  for c in $(pgrep -P "$1" 2>/dev/null); do
    # Never this process, and never the process that asked. Both would be a cleanup killing itself
    # part way through, and the second is how a helper like this takes its caller down with it.
    [ "$c" = "$SELF" ] && continue
    [ "$c" = "$PPID" ] && continue
    # The parent is read again immediately before acting. The list above comes from a command
    # substitution, which is itself a child of this shell and is therefore IN it, and by the time
    # the loop reaches that entry it has exited, so a kill on the number would land on whatever the
    # system has since given it to. Confirming the parent is what tells a live child from a
    # recycled number: a judgement formed before the act is not a judgement about the thing being
    # acted on (L157).
    pp="$(ps -o ppid= -p "$c" 2>/dev/null | tr -d ' ')"
    [ "$pp" = "$1" ] || continue
    # Stopped BEFORE its own children are walked, so it cannot start a replacement for anything
    # killed underneath it while that is happening. SIGKILL works on a stopped process, so nothing
    # needs waking up again.
    kill -STOP "$c" 2>/dev/null
    kill_tree "$c"
    if kill -9 "$c" 2>/dev/null; then
      [ -n "$REPORT" ] && printf '%s\n' "$c" >> "$REPORT" 2>/dev/null
    else
      # Woken again if the kill did not take. A process left stopped and never killed is worse than
      # one left running: it uses nothing, it never exits, and it does not look wrong in a process
      # listing, so nobody finds it. A failure must leave things as they were rather than in a
      # state this created (L5).
      kill -CONT "$c" 2>/dev/null
    fi
  done
  return 0
}

kill_tree "$1"
exit 0
