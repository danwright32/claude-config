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
# A WAIT IS NEVER SILENT. A run that has to wait says so at once, naming the holder's pid, its
# checkout and how long it has held the slot, says it again whenever the holder changes, and says
# "still waiting" with the time so far every HOOK_TESTS_SLOT_SAY_EVERY seconds (60), so working,
# still alive and failed are three different things on screen. The wait is bounded by
# HOOK_TESTS_SLOT_WAIT (3600 seconds, more than one hold bound, so the run first in line is never
# refused while the holder is inside its own), and ends in a refusal, exit 75, naming who still
# holds it. claude-sync's pull stops its own run of the suite at 1800 seconds and records that as a
# run it stopped waiting for, which is what such a run is.
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
# Settings, refused when unreadable rather than guessed (L50): HOOK_TESTS_SLOT_WAIT,
# HOOK_TESTS_SLOT_HOLD, HOOK_TESTS_SLOT_SAY_EVERY (whole seconds), HOOK_TESTS_SLOT_POLL (seconds
# between looks, 2). Seams, so its tests never wait on a real clock (L290, L524):
# HOOK_TESTS_SLOT_NOW (a command printing epoch seconds) and HOOK_TESTS_SLOT_SLEEP (the sleep
# between looks).
#
#   full_run_slot_settings          validates the settings; returns 1 with FULL_RUN_SLOT_ERR
#   full_run_slot_take <label>      queues and waits: 0 once held, or when running without the slot
#                                   (said); 75 when refused at the bound (said)
#   full_run_slot_release           gives the slot back; safe to call twice

FULL_RUN_SLOT_HELD=""
FULL_RUN_SLOT_ERR=""

full_run_slot_dir(){ printf '%s' "${HOOK_TESTS_SLOT_DIR:-${CLAUDE_HOME:-$HOME/.claude}/state/full-run-slot}"; }

full_run_slot_now(){
  local t=""
  [ -n "${HOOK_TESTS_SLOT_NOW:-}" ] && t="$(${HOOK_TESTS_SLOT_NOW} 2>/dev/null)"
  case "$t" in ''|*[!0-9]*) t="$(date +%s)" ;; esac
  printf '%s' "$t"
}

full_run_slot_settings(){
  local v isset val
  FULL_RUN_SLOT_ERR=""
  for v in HOOK_TESTS_SLOT_WAIT HOOK_TESTS_SLOT_HOLD HOOK_TESTS_SLOT_SAY_EVERY; do
    eval "isset=\${$v+set}; val=\${$v-}"
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
  local label wait hold say poll sleep_cmd t0 t elapsed last_say=0 last_head="" hpid hlabel ahead msg
  label="$(printf '%s' "${1:-?}" | tr '\n\t' '  ')"
  wait="${HOOK_TESTS_SLOT_WAIT:-3600}"; hold="${HOOK_TESTS_SLOT_HOLD:-2700}"
  say="${HOOK_TESTS_SLOT_SAY_EVERY:-60}"; poll="${HOOK_TESTS_SLOT_POLL:-2}"
  sleep_cmd="${HOOK_TESTS_SLOT_SLEEP:-sleep}"
  TURN_PID="$$"; TURN_PID_START=""; TURN_TICKET=""
  MWR_TURN_DIR="$(full_run_slot_dir)" turn_open "full-run"
  if full_run_slot_ancestor_holds; then
    return 0
  fi
  t0="$(full_run_slot_now)"
  if ! turn_join "$label" "$t0"; then
    echo "run-all-tests: could not take a place in this Mac's full suite slot ($TURN_ERR), so this run goes ahead without queueing and may compete with other full runs on this Mac (claude-config#2012)."
    return 0
  fi
  FULL_RUN_SLOT_HELD=1
  t="$t0"
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
      # Passed over by another waiter as stuck: join again at the back, as merge-when-ready does.
      TURN_TICKET=""
      if ! turn_join "$label" "$t"; then
        FULL_RUN_SLOT_HELD=""
        echo "run-all-tests: lost this run's place in this Mac's full suite slot and could not join again ($TURN_ERR), so it goes ahead without queueing (claude-config#2012)."
        return 0
      fi
      t="$(full_run_slot_now)"; continue
    fi
    if [ "$TURN_MINE" = 1 ]; then
      [ -z "$last_head" ] || echo "run-all-tests: took this Mac's full suite slot after waiting $(turn_dur "$elapsed")."
      return 0
    fi
    hpid="$(turn_field "$TURN_REPO_DIR/$TURN_HEAD_TICKET" pid)"
    hlabel="${TURN_HEAD_PR:-?}"
    ahead=$(( TURN_AHEAD - 1 ))
    msg="pid ${hpid:-?}, a full run in $hlabel, has held it for $(turn_dur $(( t - ${TURN_HEAD_SINCE:-$t} )))"
    if [ "$ahead" -eq 1 ]; then msg="$msg, and 1 other run is waiting ahead of this one"
    elif [ "$ahead" -gt 1 ]; then msg="$msg, and $ahead other runs are waiting ahead of this one"; fi
    if [ "$elapsed" -ge "$wait" ]; then
      echo "run-all-tests: REFUSED: waited $(turn_dur "$elapsed") for this Mac's full suite slot, the most HOOK_TESTS_SLOT_WAIT allows, and $msg. Nothing was run. Run it again once that run ends, or run the one suite you need directly (bash <its path>), which never waits for the slot (claude-config#2012)."
      full_run_slot_release
      return 75
    fi
    if [ "$TURN_HEAD_TICKET" != "$last_head" ]; then
      echo "run-all-tests: waiting for this Mac's full suite slot: $msg. Whole runs take turns so parallel builders do not compete for the Mac (claude-config#2012); a run naming directories that hold under half the suites, a single suite and SECTION_ONLY never wait. Waiting up to $(turn_dur "$wait"), then this run refuses."
      last_head="$TURN_HEAD_TICKET"; last_say="$elapsed"
    elif [ $(( elapsed - last_say )) -ge "$say" ]; then
      echo "run-all-tests: still waiting for this Mac's full suite slot, $(turn_dur "$elapsed") so far: $msg."
      last_say="$elapsed"
    fi
    "$sleep_cmd" "$poll"
    t="$(full_run_slot_now)"
  done
}

full_run_slot_release(){
  [ -n "$FULL_RUN_SLOT_HELD" ] || return 0
  turn_leave
  FULL_RUN_SLOT_HELD=""
  return 0
}
