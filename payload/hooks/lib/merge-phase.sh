#!/usr/bin/env bash
#
# merge-phase.sh: which phase each merge-when-ready.sh run on this Mac is in, local work or waiting
# on GitHub, published where tools/load-window.sh can read it (claude-config#1676). Sourced after
# merge-turn.sh, whose liveness rule it uses; every function takes the time as an argument, so the
# caller's injected clock decides (L524).
#
# WHY. tools/load-window.sh (#1618) refuses to start a deliberate load window while any merge helper
# runs, since a helper's gates and lessons review failed under a builder's load on 2026-10-23. But a
# helper spends most of its life waiting on GitHub (its line for the turn, a CI run of 15 to 30
# minutes), which puts no load on this Mac, and on 2026-10-24 a window got a turn once in 42 tries
# between 3:13 and 7:50 AM ET because another session's helper was nearly always running. So the
# helper says which it is doing, and a window waits only for one doing local work.
#
# WHAT IT IS. One small file per run in $MWR_PHASE_DIR (by default ~/.claude/state/merge-phases,
# this Mac's own state, never synced), named by the run's pid:
#   pid <pid>     start <its start time, as ps prints it>     phase local|waiting
#   what <what it is doing>     since <when this phase began>     until <a waiting record's expiry>
# written whole to a private file and moved into place, so a reader never sees half of one.
#
# WHAT A READER BELIEVES (L409, L617). Only a WAITING record, from a run that is running NOW with the
# start time it recorded (positive evidence, read from ps; a pid ps cannot read is not believed), whose
# until has not passed. Everything else is busy, exactly as every helper was before #1676: no record,
# one that cannot be read, a local one, one naming another pid. So:
#   - a run killed outright leaves its record, but its pid no longer runs (or runs another process
#     with another start time), so the record says nothing, and the run is not seen anyway;
#   - a stale "local" can only make a window wait for a run that has gone, which the run's own
#     absence from the process table already ends;
#   - a stale "waiting" from a run still alive is bounded by its until, which the run sets to the end
#     of the one wait it is about to make plus MP_SLACK_SECONDS, and renews before every wait, so a
#     run that went on to local work without being able to say so reads as busy once that wait is up.
# A write that fails removes the run's record rather than leaving the old one standing, and says so
# by its exit; a run that cannot write at all is busy, as before.
#
#   mp_set <phase> <what> <now> <until>   publishes this run's phase (TURN_PID and TURN_PID_START
#                                         name the run, as in merge-turn.sh); returns 1 when it could
#                                         not, having removed its record
#   mp_clear                              removes this run's record
#   mp_waiting <pid> <now>                0 when that run's record is believed waiting, with MP_WHAT
#                                         and MP_SINCE set; 1 (busy) for anything else
#   mp_reviews_busy <now>                 one line per lessons review believed running, "<pid>" TAB
#                                         "<what>"; nothing when none
#
# A LESSONS REVIEW PUBLISHES ITS OWN PHASE (claude-config#1730). merge-when-ready.sh starts the review
# detached, and it keeps running after the helper exits (a helper that stops on a red check), so the
# helper's own "local" record, gone with the helper, could not show it, and a load window could
# overlap a review still using the Mac. So the reviewer runner (pr-review.sh's run_reviewer) writes a
# record of phase "review" for the reviewer's own pid, through mp_set like a helper's, whose until is
# the reviewer's own deadline plus MP_SLACK_SECONDS (ai-review-run.py stops it at that deadline), and
# removes it when the reviewer ends. A reader counts it as busy ONLY on positive evidence, the
# opposite way round to a waiting record, so a lying record can only fail to count: the pid running
# now with the start time recorded, and the until not passed. A reviewer killed outright leaves a
# record naming a pid no longer running (or running something else), which says nothing and is swept
# by the next write; a hung one stops counting at its until, as its deadline would have stopped it.

MP_SLACK_SECONDS="${MP_SLACK_SECONDS:-60}"
mp_swept=""

mp_dir(){ printf '%s' "${MWR_PHASE_DIR:-$HOME/.claude/state/merge-phases}"; }

# Records whose run has gone, swept once a run on its first write, never the writer's own. Dead only
# on positive evidence (merge-turn.sh's turn_alive), so a run that cannot be read keeps its record.
mp_sweep(){
  local dir f b
  [ -z "$mp_swept" ] || return 0
  mp_swept=1
  dir="$(mp_dir)"
  for f in "$dir"/*; do
    b="${f##*/}"
    case "$b" in ''|*[!0-9]*) continue ;; esac
    [ "$b" = "${TURN_PID:-$$}" ] && continue
    turn_alive "$b" "$(turn_field "$f" start)" || rm -f "$f" 2>/dev/null
  done
  return 0
}

mp_set(){   # $1 = phase (local, waiting or review), $2 = what, $3 = now, $4 = until (waiting, review) or empty
  local dir pid="${TURN_PID:-$$}" start="${TURN_PID_START:-}" f tmp="" what since="$3"
  dir="$(mp_dir)"; f="$dir/$pid"
  [ -n "$start" ] || start="$(turn_proc_start "$pid")"
  what="$(printf '%s' "$2" | tr '\n\t' '  ' | cut -c1-300)"
  # A phase that goes on keeps the moment it began.
  [ "$(turn_field "$f" phase)" = "$1" ] && [ "$(turn_field "$f" pid)" = "$pid" ] && since="$(turn_field "$f" since)"
  case "$since" in ''|*[!0-9]*) since="$3" ;; esac
  if mkdir -p "$dir" 2>/dev/null && [ -d "$dir" ]; then
    mp_sweep
    tmp="$dir/.phase.$pid.$RANDOM"
    if { printf 'pid %s\nstart %s\nphase %s\nwhat %s\nsince %s\nuntil %s\n' "$pid" "$start" "$1" "$what" "$since" "${4:-}" > "$tmp"; } 2>/dev/null \
      && mv -f "$tmp" "$f" 2>/dev/null; then
      return 0
    fi
  fi
  [ -z "$tmp" ] || rm -f "$tmp" 2>/dev/null
  rm -f "$f" 2>/dev/null
  return 1
}

mp_clear(){ rm -f "$(mp_dir)/${TURN_PID:-$$}" 2>/dev/null; return 0; }

mp_waiting(){   # $1 = pid, $2 = now
  local f st cur until
  MP_WHAT=""; MP_SINCE=""
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  f="$(mp_dir)/$1"
  [ -s "$f" ] || return 1
  [ "$(turn_field "$f" pid)" = "$1" ] || return 1
  [ "$(turn_field "$f" phase)" = waiting ] || return 1
  until="$(turn_field "$f" until)"
  case "$until" in ''|*[!0-9]*) return 1 ;; esac
  [ "$2" -le "$until" ] || return 1
  st="$(turn_field "$f" start)"
  [ -n "$st" ] || return 1
  cur="$(turn_proc_start "$1")"
  [ -n "$cur" ] && [ "$cur" = "$st" ] || return 1
  MP_WHAT="$(turn_field "$f" what)"; MP_SINCE="$(turn_field "$f" since)"
  return 0
}

mp_reviews_busy(){   # $1 = now
  local dir f b until st cur
  case "${1:-}" in ''|*[!0-9]*) return 0 ;; esac
  dir="$(mp_dir)"
  for f in "$dir"/*; do
    b="${f##*/}"
    case "$b" in ''|*[!0-9]*) continue ;; esac
    [ -s "$f" ] || continue
    [ "$(turn_field "$f" pid)" = "$b" ] || continue
    [ "$(turn_field "$f" phase)" = review ] || continue
    until="$(turn_field "$f" until)"
    case "$until" in ''|*[!0-9]*) continue ;; esac
    [ "$1" -le "$until" ] || continue
    st="$(turn_field "$f" start)"
    [ -n "$st" ] || continue
    cur="$(turn_proc_start "$b")"
    [ -n "$cur" ] && [ "$cur" = "$st" ] || continue
    printf '%s\t%s\n' "$b" "$(turn_field "$f" what)"
  done
  return 0
}
