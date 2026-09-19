#!/usr/bin/env bash
#
# suite-deadline.sh: a suite started DIRECTLY bounds its own wall clock, and takes its children with
# it when it is stopped (claude-config#444).
#
# Two gaps, one place. The runner waits on every suite with no deadline of its own, and a suite
# typed straight into a shell (which is how agents run them) has no runner at all, so a suite that
# waits without end holds whatever it started for as long as the Mac stays up. And a suite stopped
# by a signal to its own pid, which is what any caller with a deadline sends, died alone: bash with
# no handler for the signal simply exits, and everything it had started was orphaned. Reproduced on
# 2026-09-18 with test-run-all-tests.sh: stopped that way at its #165 section, it left its runner and
# three fixture suites looping `sleep 3600` at 0 percent CPU for as long as anybody let them, the
# shape of the 559 process pile found that afternoon.
#
# Sourced, then armed once, near the top of the suite. Every suite the runner runs does this, and
# test-suite-deadline.sh fails on one that does not (claude-config#465):
#
#   . "$DIR/lib/suite-deadline.sh" || { ...refuse to run unbounded... }
#   suite_deadline_arm || exit $?
#
# With no argument the suite takes SUITE_WALL_DEFAULT, ONE number for every suite, derived in
# DESIGN.md's measured numbers table from the slowest suite that takes it. A suite passes a number
# of its own only when it is measured to need a different one, and that number gets its own row.
#
# Arming starts a watchdog, OUTSIDE the suite's process tree, that does two things and exits by
# itself once the suite has gone however it went.
#
# It stops the suite once its wall clock passes the limit. It cannot simply signal it, and that is
# the whole difficulty: bash defers a trapped signal until the foreground command returns, and the
# suite this exists for is blocked in a foreground command that never returns. So it flags the suite
# with USR1, stops it, kills the tree UNDER it (which is what ends the blocked command), and lets it
# go again; the flag then runs, says why, and exits 124. A suite still alive after that is sent TERM
# and finally KILL, because a deadline that can be ignored is not one (L110).
#
# And it takes the suite's children with it when the suite is stopped from outside. A handler for
# TERM in the suite cannot do that, for the same reason: it waits for the blocked command. Measured
# while building this, 2026-09-18: a suite with a TERM trap, or with only an EXIT trap, which is
# every suite here because that is where scratch is removed, went on running with its child after
# TERM for as long as the child lived. So the watchdog remembers what the suite had started,
# refreshed every poll, and kills whatever of it is still running once the suite has gone, however
# it went (TERM between two commands, KILL, a crash). A process is killed only when it is alive
# under the same pid with the same command line it had in the suite's tree. What can still slip
# through is anything started within the last poll before the suite died, which is the price of not
# rereading the process table continuously. A TERM that arrives while the suite is blocked is held
# by bash until the deadline breaks the block, so the deadline is also what bounds that case.
#
# Outside the tree on purpose, by a double fork. As a child it would be waited for by a bare `wait`,
# killed by the suite's own cleanup, and counted by every check that inspects what a suite started.
# Its output goes to /dev/null, because a watchdog holding the suite's stdout would keep any caller
# capturing it waiting until the watchdog left (L235).
#
# Environment, each read once and then removed, because it describes THIS run and a suite started
# by this one would otherwise read an injected start as its own (L169):
#   SUITE_WALL_TIMEOUT   seconds before the suite is stopped. 0 turns the watchdog off entirely.
#                        Defaults to the number the suite passes, or SUITE_WALL_DEFAULT when it
#                        passes none; DESIGN.md records and derives both.
#   SUITE_WALL_POLL      how often the watchdog looks (default 2, the same granularity as the sync
#                        suite's SUITE_POLL_INTERVAL).
#   SUITE_WALL_STARTED   the epoch second the clock is counted from. A seam, so a test can put a
#                        suite past its deadline without waiting it out (L524).
#   SUITE_WALL_PIDFILE   where the watchdog writes its own pid. A seam, so a test can prove it left.

_suite_deadline_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The one limit every suite takes unless it passes its own (claude-config#465). Its derivation is
# the DESIGN.md row; test-suite-deadline.sh reads it from this line, so keep it on one line. Not
# read from the environment: SUITE_WALL_TIMEOUT is the one override, for one run.
SUITE_WALL_DEFAULT=1200

_suite_deadline_expired(){
  # Printed on stdout, where the runner collects a suite's FAIL lines, so the reason reaches the
  # report rather than only a terminal nobody is watching (L148).
  echo "FAIL: $_suite_deadline_label ran past its own wall clock of ${_suite_deadline_limit}s and was stopped (SUITE_WALL_TIMEOUT)."
  echo "  Something in it waited without end, so every process it had started was killed and nothing after that step ran."
  echo "  Run it again on its own to see where it stops; raise SUITE_WALL_TIMEOUT only if it is genuinely slower now."
  trap - USR1
  bash "$_suite_deadline_dir/kill-tree.sh" "$$" 2>/dev/null || true
  # The suite's own EXIT trap runs on the way out, which is where its scratch is removed.
  exit 124
}

suite_deadline_arm(){   # [$1] = the suite's own limit in seconds, when it is not SUITE_WALL_DEFAULT
  local limit="${SUITE_WALL_TIMEOUT-${1:-$SUITE_WALL_DEFAULT}}" poll="${SUITE_WALL_POLL:-2}" started="${SUITE_WALL_STARTED:-}"
  local pidfile="${SUITE_WALL_PIDFILE:-}"
  unset SUITE_WALL_TIMEOUT SUITE_WALL_POLL SUITE_WALL_STARTED SUITE_WALL_PIDFILE
  _suite_deadline_label="$(basename "$0")"
  # Refused rather than guessed at. This decides whether a suite is killed, and an unreadable value
  # must not quietly mean either "never" or "at once" (L50).
  case "$limit" in
    ''|*[!0-9]*)
      echo "$_suite_deadline_label: SUITE_WALL_TIMEOUT='$limit' is not a whole number of seconds. Refusing to run rather than guessing when to stop. Set it to 0 to turn the deadline off." >&2
      return 2 ;;
  esac
  case "$poll" in
    ''|*[!0-9.]*|*.*.*|.)
      echo "$_suite_deadline_label: SUITE_WALL_POLL='$poll' is not a number of seconds. Refusing to run rather than guessing how often to look." >&2
      return 2 ;;
  esac
  case "$started" in
    '') started="$(date +%s)" ;;
    *[!0-9]*)
      echo "$_suite_deadline_label: SUITE_WALL_STARTED='$started' is not an epoch second. Refusing to run rather than counting from a time nobody can read." >&2
      return 2 ;;
  esac
  [ "$limit" -eq 0 ] && return 0
  _suite_deadline_limit="$limit"
  trap '_suite_deadline_expired' USR1
  ( bash "$_suite_deadline_dir/suite-deadline.sh" --watch "$$" "$limit" "$started" "$poll" "$pidfile" \
      </dev/null >/dev/null 2>&1 & )
  return 0
}

# The watchdog itself, when this file is RUN rather than sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = "--watch" ]; then
  target="$2"; limit="$3"; started="$4"; poll="$5"; pidfile="${6:-}"
  [ -n "$pidfile" ] && printf '%s\n' "$$" > "$pidfile"
  table(){ ps -axo pid=,ppid=,command= 2>/dev/null; }
  # "pid<TAB>command" for every descendant of $1, read from the process table on stdin.
  descendants(){
    awk -v root="$1" '
      { pid = $1; pp = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); parent[pid] = pp; cmd[pid] = $0 }
      END {
        # Bounded passes rather than recursion, so a table read while things exit cannot loop.
        want[root] = 1
        for (pass = 0; pass < 64; pass++) {
          grew = 0
          for (p in parent) if (!(p in want) && (parent[p] in want)) { want[p] = 1; grew = 1 }
          if (!grew) break
        }
        for (p in want) if (p != root) printf "%s\t%s\n", p, cmd[p]
      }'
  }
  known=""
  while kill -0 "$target" 2>/dev/null; do
    if [ $(( $(date +%s) - started )) -ge "$limit" ]; then
      kill -USR1 "$target" 2>/dev/null
      # Stopped while its tree is walked, so it cannot start a replacement for what is killed
      # underneath it, which is the race lib/kill-tree.sh records (#174).
      kill -STOP "$target" 2>/dev/null
      bash "$(dirname "$0")/kill-tree.sh" "$target" 2>/dev/null
      kill -CONT "$target" 2>/dev/null
      n=0
      while kill -0 "$target" 2>/dev/null && [ "$n" -lt 20 ]; do sleep "$poll"; n=$(( n + 1 )); done
      kill -TERM "$target" 2>/dev/null
      n=0
      while kill -0 "$target" 2>/dev/null && [ "$n" -lt 20 ]; do sleep "$poll"; n=$(( n + 1 )); done
      kill -KILL "$target" 2>/dev/null
      exit 0
    fi
    # Kept only when the suite was still alive AFTER the table was read. A table read just after it
    # died shows its children already handed to init, so it has no descendants at all, and taking
    # that as the snapshot left the sweep below nothing to kill: seen as an intermittent failure of
    # the suite's own check before this was added (L203).
    seen="$(table | descendants "$target")"
    kill -0 "$target" 2>/dev/null && known="$seen"
    # What it has seen, beside the pidfile, so a test can wait until the watchdog knows a child
    # rather than guessing how long that takes (L290).
    [ -n "$pidfile" ] && printf '%s\n' "$known" > "$pidfile.seen"
    sleep "$poll"
  done
  # The suite has gone. Whatever it had started that is still running under the same pid and the
  # same command line is an orphan of it, and so is anything that orphan has started since.
  [ -n "$known" ] || exit 0
  now_table="$(table)"
  # Through the environment rather than -v, which would expand backslashes in a command line and
  # refuse the newlines between the rows.
  doomed="$(printf '%s\n' "$now_table" | SUITE_DEADLINE_KNOWN="$known" awk '
    BEGIN { n = split(ENVIRON["SUITE_DEADLINE_KNOWN"], rows, "\n"); for (i = 1; i <= n; i++) { t = index(rows[i], "\t"); if (t) was[substr(rows[i], 1, t - 1)] = substr(rows[i], t + 1) } }
    { pid = $1; $1 = ""; $2 = ""; sub(/^ +/, ""); if ((pid in was) && was[pid] == $0) print pid }')"
  [ -n "$doomed" ] || exit 0
  for p in $doomed; do kill -STOP "$p" 2>/dev/null; done
  for p in $doomed; do
    for c in $(printf '%s\n' "$now_table" | descendants "$p" | cut -f1); do kill -KILL "$c" 2>/dev/null; done
    kill -KILL "$p" 2>/dev/null
  done
  exit 0
fi
