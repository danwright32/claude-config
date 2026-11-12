#!/usr/bin/env bash
#
# full-run-slot.sh: this Mac's ONE slot for whole runs of run-all-tests.sh, so parallel full runs
# queue instead of competing (claude-config#2012). Sourced by the runner, never executed.
#
# WHY. The runner sizes its parallelism per RUN (up to 8 processes), not per Mac. Around midnight ET
# on 2026-11-01 five builders each ran the full suite before pushing, at once: load averages of 270
# to 410 on 12 cores, one run finishing 9 of 243 suites in 30 minutes, and test-merge-when-ready.sh
# stopped at its 1200 second wall clock by load alone. The sync suite's lock covered one suite, so
# the rest of each run competed with every other.
#
# WHAT IT IS. Not a new kind of lock (L655): the queue is lib/merge-turn.sh itself, the per
# repository turn merge-when-ready.sh takes and tools/load-window.sh already reuses as this Mac's
# load window turn. Numbered tickets, each naming its run's pid and that process's start time, in
# one folder: ${CLAUDE_HOME:-$HOME/.claude}/state/full-run-slot/full-run, or HOOK_TESTS_SLOT_DIR.
# CLAUDE_HOME is honoured so a suite pointing it at a fixture home never queues behind this Mac's
# real runs. The ticket's label is the checkout the run is about, so a waiting run can say whose
# run it is waiting for.
#
# WHEN ITS HOLDER DIES (L409). A ticket whose pid is not running, or runs with another start time,
# is passed over at once by whoever looks next, and that is said. A live holder past
# HOOK_TESTS_SLOT_HOLD (2700 seconds) is passed over too (L523): a full run that has held the slot
# for 45 minutes on a quiet Mac is stuck, and the next run should not wait out its whole bound.
#
# IN THE ORDER THEY ARRIVED (claude-config#2828). Runs are served by ticket number, which is the order
# they joined. A waiting run whose ticket another run removed (a run reading its start time in another
# time zone took it for gone, before merge-turn.sh judged starts in one fixed form) takes the same
# number back rather than joining at the back behind every run that arrived after it, and says so
# once. On 2026-11-12 a run refused after 60 minutes had in fact been served in order: the three runs
# that held the slot while it waited had all joined before it, and the bound was then on the whole
# wait, so a run fourth in line behind full runs of 20 to 30 minutes each was refused by design.
#
# A WAIT IS NEVER SILENT. A run that has to wait says so at once, naming the holder's pid, its
# checkout and how long it has held the slot, says it again whenever the holder changes, and says
# "still waiting" with the time so far every HOOK_TESTS_SLOT_SAY_EVERY seconds (60), so working,
# still alive and failed are three different things on screen.
#
# THE BOUND IS ON THE LINE STANDING STILL (claude-config#2835). A waiting run refuses, exit 75, once
# the line in front of it has not moved for HOOK_TESTS_SLOT_STILL seconds (3600): no run ahead of it
# finished, left or was passed over, and none took the slot. 3600 is more than one hold bound, so
# the run first in line is never refused while the holder is inside its own. A line that keeps
# moving serves every run in it however long the whole wait: the runs ahead are a fixed number, as
# later arrivals join behind, so each movement brings the turn closer. The whole wait bounded at
# 3600 seconds refused a run fourth in line behind full runs of 20 to 30 minutes with nothing run,
# twice (2026-11-11 and 12), though the line was moving and serving it in order.
#
# HOOK_TESTS_SLOT_WAIT still bounds the WHOLE wait, but only when it is set: claude-sync's pull hands
# its own run half of its 1800 second deadline there, so a run the slot keeps waiting refuses inside
# that deadline however the line moves, and the pull says the suite waited for the slot and ran
# nothing, records it, and runs it again on the next pull (claude-config#2758). With no bound of its
# own the pull stopped the run while it was still queued and reported it as a suite "still running".
# That refusal keeps the words the pull reads ("waited <d> for this Mac's full suite slot, the most
# HOOK_TESTS_SLOT_WAIT allows, and <who>. Nothing was run."). Both refusals name who holds the slot.
#
# WHAT STAYS OUTSIDE. Only a WHOLE run takes the slot: one naming no directories, of the real
# repository (no HOOK_TESTS_ROOT), started from a fresh shell (not inside another run) and not
# under CI, where one job owns the runner. A run naming directories counts as whole when they hold
# half the tree's suites or more, and never when they hold fewer than 3 (claude-config#2034, the
# measured threshold is in the runner). A smaller folder run, a single suite run directly,
# SECTION_ONLY, and the scanners gate (which starts each scanner itself) never wait. And a run
# whose ancestor holds a ticket is a fixture run inside that run, so it takes no place: queued
# behind its own parent it could only ever wait until it refused. The runner decides whether a run
# is whole; this file only queues.
#
# FAILS OPEN. A slot folder that cannot be made or written does not stop the tests: the run goes
# ahead without queueing and says so, because a broken state folder must never be the reason a
# verdict is missing.
#
# Settings, refused when unreadable rather than guessed (L50): HOOK_TESTS_SLOT_STILL,
# HOOK_TESTS_SLOT_WAIT (unset: no bound on the whole wait), HOOK_TESTS_SLOT_HOLD, HOOK_TESTS_SLOT_SAY_EVERY (whole seconds), HOOK_TESTS_SLOT_POLL (seconds
# between looks, 2). Seams, so its tests never wait on a real clock (L290, L524):
# HOOK_TESTS_SLOT_NOW (a command printing epoch seconds) and HOOK_TESTS_SLOT_SLEEP (the sleep
# between looks). A HOOK_TESTS_SLOT_NOW read that is not a whole number refuses the run, exit 1,
# naming what it printed, and gives back any place it took (claude-config#2828).
#
#   full_run_slot_settings          validates the settings; returns 1 with FULL_RUN_SLOT_ERR
#   full_run_slot_take <label>      queues and waits: 0 once held, or when running without the slot
#                                   (said); 75 when refused at either bound (said); 1 when the injected
#                                   clock printed no number (said)
#   full_run_slot_release           gives the slot back; safe to call twice

FULL_RUN_SLOT_HELD=""
FULL_RUN_SLOT_ERR=""

full_run_slot_dir(){ printf '%s' "${HOOK_TESTS_SLOT_DIR:-${CLAUDE_HOME:-$HOME/.claude}/state/full-run-slot}"; }

# Reads the clock into FULL_RUN_SLOT_T, without a subshell so a failure's reason survives. An injected
# clock printing anything but a whole number returns 1 with FULL_RUN_SLOT_ERR (claude-config#2828),
# never answered from the real clock: a wait started on one clock and judged on the other looks
# decades long, so the run was refused, or the holder passed over, for a reason that had nothing to
# do with the bad read (the class of #2778). Without HOOK_TESTS_SLOT_NOW this is the real clock.
FULL_RUN_SLOT_T=""
full_run_slot_clock(){
  local t
  FULL_RUN_SLOT_T=""
  if [ -n "${HOOK_TESTS_SLOT_NOW:-}" ]; then
    t="$(${HOOK_TESTS_SLOT_NOW} 2>/dev/null)"
    case "$t" in
      ''|*[!0-9]*)
        FULL_RUN_SLOT_ERR="HOOK_TESTS_SLOT_NOW (${HOOK_TESTS_SLOT_NOW}) printed '$(printf '%s' "$t" | tr '\n\t' '  ' | cut -c1-80)', not a whole number of seconds"
        return 1 ;;
    esac
    FULL_RUN_SLOT_T="$t"; return 0
  fi
  FULL_RUN_SLOT_T="$(date +%s)"
}
# Says the clock refusal, gives back any place taken, and returns the refusal's status.
full_run_slot_clock_refused(){
  echo "run-all-tests: REFUSED: $FULL_RUN_SLOT_ERR, so this run stopped rather than judge its wait for this Mac's full suite slot by any other clock. Nothing was run (claude-config#2828)."
  full_run_slot_release
  return 1
}

full_run_slot_settings(){
  local v isset val
  FULL_RUN_SLOT_ERR=""
  for v in HOOK_TESTS_SLOT_STILL HOOK_TESTS_SLOT_WAIT HOOK_TESTS_SLOT_HOLD HOOK_TESTS_SLOT_SAY_EVERY; do
    # Read by indirection, never eval: an eval can bind any name, so the Slack drafts gate stopped
    # following a script's variables past it (claude-config#2465).
    isset="${!v+set}"; val="${!v-}"
    [ -n "$isset" ] || continue
    case "$val" in
      ''|*[!0-9]*) FULL_RUN_SLOT_ERR="$v='$val' is not a whole number of seconds"; return 1 ;;
    esac
  done
  case "${HOOK_TESTS_SLOT_POLL:-2}" in
    ''|*[!0-9.]*|*.*.*|.) FULL_RUN_SLOT_ERR="HOOK_TESTS_SLOT_POLL='${HOOK_TESTS_SLOT_POLL:-}' is not a number of seconds"; return 1 ;;
  esac
  return 0
}

# Is pid $1 this process or one of its ancestors? Walked through ps, a few hundred levels at most.
full_run_slot_is_ancestor(){
  local p="$$" d=0
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  while [ -n "$p" ] && [ "$p" != 0 ] && [ "$d" -lt 200 ]; do
    [ "$p" = "$1" ] && return 0
    [ "$p" = 1 ] && return 1
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    d=$((d + 1))
  done
  return 1
}

# Does a live ticket in the queue belong to an ancestor of this run? Read only: a dead holder's
# ticket is left for a waiter to pass over and say so.
full_run_slot_ancestor_holds(){
  local n f
  for n in $(turn_tickets); do
    f="$TURN_REPO_DIR/$n"
    [ -s "$f" ] || continue
    full_run_slot_is_ancestor "$(turn_field "$f" pid)" && return 0
  done
  return 1
}

full_run_slot_take(){   # $1 = what this run is about (its checkout)
  local label wait still hold say poll sleep_cmd t0 t elapsed last_say=0 last_head="" hpid hlabel ahead msg retold=""
  local moved_at prev_head="" prev_ahead="" bounds
  label="$(printf '%s' "${1:-?}" | tr '\n\t' '  ')"
  # The whole wait is bounded only when HOOK_TESTS_SLOT_WAIT is set (claude-sync's pull, #2758); the
  # line standing still always is (#2835).
  wait="${HOOK_TESTS_SLOT_WAIT:-}"; still="${HOOK_TESTS_SLOT_STILL:-3600}"; hold="${HOOK_TESTS_SLOT_HOLD:-2700}"
  say="${HOOK_TESTS_SLOT_SAY_EVERY:-60}"; poll="${HOOK_TESTS_SLOT_POLL:-2}"
  sleep_cmd="${HOOK_TESTS_SLOT_SLEEP:-sleep}"
  TURN_PID="$$"; TURN_PID_START=""; TURN_TICKET=""
  MWR_TURN_DIR="$(full_run_slot_dir)" turn_open "full-run"
  if full_run_slot_ancestor_holds; then
    return 0
  fi
  full_run_slot_clock || { full_run_slot_clock_refused; return; }
  t0="$FULL_RUN_SLOT_T"
  if ! turn_join "$label" "$t0"; then
    echo "run-all-tests: could not take a place in this Mac's full suite slot ($TURN_ERR), so this run goes ahead without queueing and may compete with other full runs on this Mac (claude-config#2012)."
    return 0
  fi
  FULL_RUN_SLOT_HELD=1
  t="$t0"; moved_at="$t0"
  bounds="this run refuses once the line stands still for $(turn_dur "$still"), with no run ahead of it finishing or leaving"
  [ -z "$wait" ] || bounds="$bounds, or once it has waited $(turn_dur "$wait") in all"
  while :; do
    elapsed=$(( t - t0 ))
    turn_look "$t" "$hold"
    if [ -n "$TURN_SAID" ]; then
      printf '%s\n' "$TURN_SAID" | sed \
        -e "s/^#\(.*\)'s place in line was passed over: its run/the full run in \1 was passed over in this Mac's full suite slot: its run/" \
        -e "s/^#\(.*\)'s turn ran out after \(.*\), past the \(.*\) any one pull request may hold it, so it passed to the next in line\./the full run in \1 had held this Mac's full suite slot for \2, past the \3 any one full run may hold it (HOOK_TESTS_SLOT_HOLD), so it passed to the next in line, though that run may still be going./" \
        -e 's/^/run-all-tests: /'
    fi
    if [ -n "$TURN_GONE" ]; then
      # Another run removed this run's ticket while it waited (it judged the run gone). A run here
      # has never held the slot, since one that does returns at once, so it takes the same number
      # back and keeps the order it arrived in (claude-config#2828); joining at the back put every
      # run that arrived after it ahead of it. Said once, however often it happens.
      if turn_retake "$label" "$t0"; then
        [ -n "$retold" ] || echo "run-all-tests: another run removed this run's place in this Mac's full suite slot while it waited, so it took the same place back and keeps the order it arrived in (claude-config#2828)."
        retold=1
      else
        echo "run-all-tests: another run removed this run's place in this Mac's full suite slot while it waited, and it could not take that place back ($TURN_ERR), so it joins again at the back of the line (claude-config#2828)."
        TURN_TICKET=""
        if ! turn_join "$label" "$t"; then
          FULL_RUN_SLOT_HELD=""
          echo "run-all-tests: lost this run's place in this Mac's full suite slot and could not join again ($TURN_ERR), so it goes ahead without queueing (claude-config#2012)."
          return 0
        fi
      fi
      full_run_slot_clock || { full_run_slot_clock_refused; return; }
      t="$FULL_RUN_SLOT_T"; continue
    fi
    if [ "$TURN_MINE" = 1 ]; then
      [ -z "$last_head" ] || echo "run-all-tests: took this Mac's full suite slot after waiting $(turn_dur "$elapsed")."
      return 0
    fi
    # The line moved: the run holding the slot changed, or fewer runs are ahead of this one (one
    # finished, left or was passed over). A run joining behind is not movement (#2835). Judged by
    # the queue's own turn_moved, the same answer the merge helper's time in line uses.
    if turn_moved "$prev_head" "$prev_ahead"; then
      moved_at="$t"
    fi
    prev_head="$TURN_HEAD_TICKET"; prev_ahead="$TURN_AHEAD"
    hpid="$(turn_field "$TURN_REPO_DIR/$TURN_HEAD_TICKET" pid)"
    hlabel="${TURN_HEAD_PR:-?}"
    ahead=$(( TURN_AHEAD - 1 ))
    msg="pid ${hpid:-?}, a full run in $hlabel, has held it for $(turn_dur $(( t - ${TURN_HEAD_SINCE:-$t} )))"
    if [ "$ahead" -eq 1 ]; then msg="$msg, and 1 other run is waiting ahead of this one"
    elif [ "$ahead" -gt 1 ]; then msg="$msg, and $ahead other runs are waiting ahead of this one"; fi
    if [ -n "$wait" ] && [ "$elapsed" -ge "$wait" ]; then
      echo "run-all-tests: REFUSED: waited $(turn_dur "$elapsed") for this Mac's full suite slot, the most HOOK_TESTS_SLOT_WAIT allows, and $msg. Nothing was run. Run it again once that run ends, or run the one suite you need directly (bash <its path>), which never waits for the slot (claude-config#2012)."
      full_run_slot_release
      return 75
    fi
    if [ $(( t - moved_at )) -ge "$still" ]; then
      echo "run-all-tests: REFUSED: waited $(turn_dur "$elapsed") for this Mac's full suite slot, and the line stood still for the last $(turn_dur $(( t - moved_at ))), the most HOOK_TESTS_SLOT_STILL allows, with no run ahead of this one finishing or leaving: $msg. Nothing was run. Run it again once that run ends, or run the one suite you need directly (bash <its path>), which never waits for the slot (claude-config#2835)."
      full_run_slot_release
      return 75
    fi
    if [ "$TURN_HEAD_TICKET" != "$last_head" ]; then
      echo "run-all-tests: waiting for this Mac's full suite slot: $msg. Whole runs take turns so parallel builders do not compete for the Mac (claude-config#2012); a run naming directories that hold under half the suites or only one or two, a single suite and SECTION_ONLY never wait. It waits as long as the line keeps moving: $bounds."
      last_head="$TURN_HEAD_TICKET"; last_say="$elapsed"
    elif [ $(( elapsed - last_say )) -ge "$say" ]; then
      echo "run-all-tests: still waiting for this Mac's full suite slot, $(turn_dur "$elapsed") so far: $msg."
      last_say="$elapsed"
    fi
    "$sleep_cmd" "$poll"
    full_run_slot_clock || { full_run_slot_clock_refused; return; }
    t="$FULL_RUN_SLOT_T"
  done
}

full_run_slot_release(){
  [ -n "$FULL_RUN_SLOT_HELD" ] || return 0
  turn_leave
  FULL_RUN_SLOT_HELD=""
  return 0
}
