#!/usr/bin/env bash
#
# pid-lock.sh: a lock several processes take in turn, holding the pid of whoever took it, and the
# one reading of a pid everything here shares (pid_running, process_read, below). Sourced, never run.
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
# A holder that has died leaves it behind, so a lock whose pid has GONE is taken over rather than
# waited on for ever. Gone, and nothing less (claude-config#3601): a holder whose pid the shell
# could not test (pid_running below) keeps its lock, and the take says so in PID_LOCK_UNREAD.
#
# Every turn of the wait reaches the deadline check, a takeover attempt included: a takeover that
# cannot happen (its break lock left behind by a killed run) used to `continue` straight back to the
# top, which is a loop with no deadline and no sleep, spinning for ever.
#
#   take_pid_lock <lock file> <seconds to wait>
#     Returns 0 once held, 1 at the deadline, and 2 when the pid file it links from cannot be
#     written at all, so each caller gives its refusal in its own words. Released by removing the
#     lock file. At 1, PID_LOCK_UNREAD is the holder's pid when the last look could not tell
#     whether that holder is running, and empty otherwise; pid_lock_unread_sentence words it.
#
# THE COST OF THE SAFE SIDE. A lock whose holder really has gone is still taken over wherever the
# shell can say so, which it can even under a sandbox that refuses every signal (kill -0 of a pid
# nobody holds says "No such process" there too, measured 2026-11-26). What keeps its lock now is a
# holder the shell may not signal and has not gone: a live one, which is the point, or a pid the
# system has since given to another account's process. Nothing here has an age rule for that; each
# caller's refusal names the file to remove (claude-config#3601).
take_pid_lock(){   # $1 = lock file  $2 = seconds to wait
  local lock="$1" max="$2" t0 holder mine="$1.$$" alive
  PID_LOCK_UNREAD=""
  { printf '%s\n' "$$" > "$mine"; } 2>/dev/null || { rm -f "$mine" 2>/dev/null || true; return 2; }
  t0="$(date +%s)"
  while ! ln "$mine" "$lock" 2>/dev/null; do
    holder="$(cat "$lock" 2>/dev/null || true)"
    PID_LOCK_UNREAD=""
    case "$holder" in
      ''|*[!0-9]*) : ;;   # gone between the ln and the read, or unreadable: try again, never break on a guess
      *) alive=0; pid_running "$holder" || alive=$?
         case "$alive" in
           0) : ;;
           1) break_stale_pid_lock "$lock" "$holder" ;;
           *) PID_LOCK_UNREAD="$holder" ;;
         esac ;;
    esac
    if [ "$(( $(date +%s) - t0 ))" -ge "$max" ]; then
      rm -f "$mine"
      return 1
    fi
    sleep 0.1
  done
  rm -f "$mine"
  PID_LOCK_UNREAD=""
  return 0
}

# What a refusal says of a holder the last take could not read, in one wording: that whether it is
# running could not be told, the command that shows why, and that this is not the same as it having
# gone. Nothing when the last take read its holder, so a caller can always append it.
pid_lock_unread_sentence(){
  [ -n "${PID_LOCK_UNREAD:-}" ] || return 0
  printf 'Whether process %s, which holds it, is still running could not be told: kill -0 %s was refused rather than answered, so the lock was left with it. That is not the same as it having gone.' "$PID_LOCK_UNREAD" "$PID_LOCK_UNREAD"
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
  local alive=0
  mkdir "$1.break" 2>/dev/null || return 0
  if [ "$(cat "$1" 2>/dev/null || true)" = "$2" ]; then
    # Removed only on the shell's word that the holder has gone, never on a test it could not make.
    pid_running "$2" || alive=$?
    [ "$alive" -ne 1 ] || rm -f "$1"
  fi
  rmdir "$1.break" 2>/dev/null || true
  return 0
}

# THE ONE READING OF A PID (claude-config#3601, L370). Everything here that asks whether a process
# is still there, or what it is, asks these two: the locks above, claude-sync (its sync lock, the
# rerun claim, the watcher rule, a suite it is stopping) and lib/sync-clone.sh (the watcher every
# payload hook asks about). There were two copies, one in claude-sync and one in sync-clone.sh,
# made by #3584 and #3547 to the same shape; this is where they live now.
#
# Is this pid running? Three answers: 0 it is, 1 it is gone, 2 the shell could not tell.
# kill -0 exits 1 both for a pid that is not there and for a process this shell may not signal,
# another account's or any at all under a sandbox that refuses signals, and only its words tell the
# two apart. A refusal was read as a dead pid, so under such a sandbox a live watcher was settled
# as none and a live lock holder's lock was taken (measured on 2026-11-24 and 2026-11-26 with
# sandbox-exec and signals denied, where ps was refused as well). So gone is said only on the
# shell's own words that there is no such process, read in the C locale so they are the words bash
# writes whatever language the Mac is in, and every other failure is "could not tell".
pid_running(){   # $1 = a pid
  local err
  kill -0 "$1" 2>/dev/null && return 0
  # A subshell, so the locale is this one command's and nobody else's.
  err="$( (LC_ALL=C; kill -0 "$1") 2>&1 )" && return 0
  case "$err" in *"No such process"*) return 1 ;; esac
  return 2
}

# WHAT A PROCESS IS, WITH THREE ANSWERS, NEVER TWO (claude-config#3584, #3547, L10). A guard that
# asks what the process a pid file names IS read it with `ps -o command=`, the failure discarded, so
# a ps that could not run gave the same empty answer as a process that is something else. The
# reading is kept as a STATE the caller has to branch on, with no printed answer for an error to
# hide behind:
#
#   PROC_STATE  named   the process is running, and PROC_CMD is its command line
#               gone    it is settled that there is no such process
#               unread  it is running, or the shell could not test whether it is, and what it is
#                       could not be read
#   PROC_WHY    when unread, what failed, as a clause a sentence can carry ("process 12, which is
#               running, and ps -o command= -p 12 exited 1 without saying what it is")
#   PROC_PROBE  when unread, the command a person can run to see the failure for themselves
#
# Returns 0, 1 and 2 in that order. Call it in the caller's own shell, never in a command
# substitution, whose subshell would keep the state to itself.
#
# A ps that fails is asked about twice. It exits non zero both when it could not run and when the
# process ended a moment after it was seen running, so the pid is tested again afterwards: gone is
# gone, and anything else with nothing learned about it is unread. A ps that exits 0 and prints
# nothing about a running process has not answered either. Whether a ps is on PATH at all is asked
# of the shell, so a missing one is said to be missing rather than inferred from an exit code (L11).
process_read(){   # $1 = a pid, a whole number above zero -> PROC_STATE, PROC_CMD, PROC_WHY, PROC_PROBE
  local pid="$1" cmd="" rc=0 alive=0 seen=""
  PROC_STATE=gone; PROC_CMD=""; PROC_WHY=""; PROC_PROBE=""
  pid_running "$pid" || alive=$?
  [ "$alive" -ne 1 ] || return 1                    # gone
  cmd="$(ps -o command= -p "$pid" 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$cmd" ]; then
    PROC_STATE=named; PROC_CMD="$cmd"
    return 0
  fi
  alive=0
  pid_running "$pid" || alive=$?
  [ "$alive" -ne 1 ] || return 1                    # gone since the first look
  PROC_STATE=unread
  PROC_PROBE="ps -o command= -p $pid"
  # Said to be running only when the shell saw that it is (L11).
  if [ "$alive" -eq 0 ]; then seen="which is running"
  else seen="which the shell could not test, its kill -0 of that pid being refused"; fi
  if ! command -v ps >/dev/null 2>&1; then
    PROC_WHY="process $pid, $seen, and no ps is on this run's PATH to say what it is ($PROC_PROBE exited $rc)"
  elif [ "$rc" -eq 0 ]; then
    PROC_WHY="process $pid, $seen, and $PROC_PROBE printed nothing about it"
  else
    PROC_WHY="process $pid, $seen, and $PROC_PROBE exited $rc without saying what it is"
  fi
  return 2
}
