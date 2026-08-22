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
# TWO callers, not three. The deadline watchdog still has its own copy. Calling this from there was
# tried on 2026-08-22 and left a run hung; why is NOT established, and claude-config#172 is open to
# find out. There is a good argument that a watchdog should not depend on an extra process at the
# moment of killing (L71), and it may well be the reason, but it has not been shown to be (L203).
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
    kill_tree "$c"
    if kill -9 "$c" 2>/dev/null; then
      [ -n "$REPORT" ] && printf '%s\n' "$c" >> "$REPORT" 2>/dev/null
    fi
  done
  return 0
}

kill_tree "$1"
exit 0
