#!/usr/bin/env bash
#
# pid-lock.sh: a lock several processes take in turn, holding the pid of whoever took it. Sourced,
# never run.
#
# ONE copy, because there were about to be two (L370). claude-sync took its lesson reservations and
# its watcher hold record with it (claude-config#1863), and the scanners gate needs the same lock
# for its runs left in the background, where a home made lock let two pushes on Linux each start
# their own copy of one scanner (PR #1897). So it moved here from claude-sync, unchanged, and both
# source it.
#
# The lock is a FILE holding the pid of whoever took it, created by hard linking a file that already
# holds that pid. `ln` fails if the name exists, so taking it is atomic, and the lock never exists
# without its pid in it: a lock made first and its pid written after (mkdir, then a write) is left
# EMPTY by a run killed between the two, and an empty lock can never be told from one being written
# this instant, so every later ask would wait out its deadline for ever after.
#
# A holder that has died leaves it behind, so a lock whose pid is not running is taken over rather
# than waited on for ever.
#
# Every turn of the wait reaches the deadline check, a takeover attempt included: a takeover that
# cannot happen (its break lock left behind by a killed run) used to `continue` straight back to the
# top, which is a loop with no deadline and no sleep, spinning for ever.
#
# THE DEADLINE IS HOW LONG ONE HOLDER HAS HELD IT, and it starts again each time the lock changes
# hands (claude-config#3683). Every caller's refusal says another run has held the lock too long,
# and a wait timed from the first try measured the whole queue instead: five lesson number asks at
# once on a busy Mac, each holding the lock for a second or two, left the last ones refused at ten
# seconds with a lock that had never once been held for ten, saying it had (L11). A lock passing
# from holder to holder is a queue that is moving; a holder that keeps it is what the deadline is for.
# A holder is told apart by its pid, so one process that lets the lock go and takes it again in
# between two reads counts as one holder: the wait then gives up as early as it always did, never
# later.
#
#   take_pid_lock <lock file> <seconds one holder may keep it>
#     Returns 0 once held, 1 at the deadline, and 2 when the pid file it links from cannot be
#     written at all, so each caller gives its refusal in its own words. Released by removing the
#     lock file. A test clock that cannot be read (below) also returns 1, after a line of its own
#     on stderr naming the clock, which only a test ever sees.
take_pid_lock(){   # $1 = lock file  $2 = seconds one holder may keep it before this gives up
  local lock="$1" max="$2" t0 now holder seen="" mine="$1.$$"
  { printf '%s\n' "$$" > "$mine"; } 2>/dev/null || { rm -f "$mine" 2>/dev/null || true; return 2; }
  t0="$(pid_lock_now)" || { rm -f "$mine"; return 1; }
  while ! ln "$mine" "$lock" 2>/dev/null; do
    now="$(pid_lock_now)" || { rm -f "$mine"; return 1; }
    holder="$(cat "$lock" 2>/dev/null || true)"
    case "$holder" in
      ''|*[!0-9]*) : ;;   # gone between the ln and the read, or unreadable: try again, never break on a guess
      *) if [ "$holder" != "$seen" ]; then seen="$holder"; t0="$now"; fi
         kill -0 "$holder" 2>/dev/null || break_stale_pid_lock "$lock" "$holder" ;;
    esac
    if [ "$(( now - t0 ))" -ge "$max" ]; then
      rm -f "$mine"
      return 1
    fi
    sleep 0.1
  done
  rm -f "$mine"
  return 0
}

# The clock the deadline is judged by: the real one in whole seconds, unless PID_LOCK_TEST_CLOCK
# names a command that prints the time instead, which only a test sets (L524), so a check of the
# deadline turns on what the wait did rather than on how fast the Mac ran it. A test clock printing
# anything but a whole number is never taken as zero, which would make the deadline fire at once or
# never (L50): it fails, saying what it printed, and the wait gives up.
pid_lock_now(){
  local t
  if [ -n "${PID_LOCK_TEST_CLOCK:-}" ]; then
    t="$("$PID_LOCK_TEST_CLOCK" 2>/dev/null)"
    case "$t" in
      ''|*[!0-9]*) echo "pid-lock: PID_LOCK_TEST_CLOCK ($PID_LOCK_TEST_CLOCK) printed '$t', not a whole number of seconds, so this wait for a lock gave up rather than judge its deadline by a clock it cannot read." >&2
                   return 1 ;;
    esac
    printf '%s\n' "$t"
    return 0
  fi
  date +%s
}

# Taking over a lock whose holder died is itself serialised. Two waiters can both read the same dead
# pid, and if each simply removed the lock, the second would remove the one the first had just
# taken, and both would go ahead at once. So a takeover first takes $lock.break (mkdir, atomic), then
# reads the pid AGAIN and removes the lock only if it still names the same dead holder. A lock taken
# since holds a live pid, and is left alone. A waiter that cannot take the break lock
# simply waits its turn. Nothing can replace the stale lock between the re-read and the removal:
# a new lock can only be made once the old one is gone, and the only remover of a dead holder's
# lock is a takeover, which holds the break lock. A run killed in the instant between taking the
# break lock and releasing it leaves it behind, and then no takeover can happen: every ask stops at
# its deadline, which fails closed rather than letting two in at once, and each caller names both
# files in its refusal.
break_stale_pid_lock(){   # $1 = lock file  $2 = the dead holder's pid
  mkdir "$1.break" 2>/dev/null || return 0
  if [ "$(cat "$1" 2>/dev/null || true)" = "$2" ] && ! kill -0 "$2" 2>/dev/null; then
    rm -f "$1"
  fi
  rmdir "$1.break" 2>/dev/null || true
  return 0
}
