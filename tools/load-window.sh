#!/usr/bin/env bash
#
# load-window.sh: run a deliberate load reproduction in one shared, bounded window on this Mac
# (claude-config#1618). Not installed: builders run it from a checkout.
#
# WHY. A check that fails only when the Mac is busy has to be reproduced busy before it is fixed
# (L681), so builders started hand written busy loops. On 2026-10-23 one of those windows (#1577's)
# overlapped four builders' full suites and other sessions' merges, the load average reached 342,
# merge-when-ready.sh 1606 stopped five times on GitHub reads, and #1616's first merge was refused
# the same way. Nothing said a load window was running, and nothing stopped two from running at once.
#
# WHAT IT DOES, in order:
#   1. Takes this Mac's ONE load window turn, a queue that is lib/merge-turn.sh itself (the
#      merge helper's turn, #1549, not a second lock): numbered tickets naming a pid and its start
#      time, so a holder whose process has gone is passed over at once (L409), and a live holder
#      past LOAD_WINDOW_HOLD_SECONDS is passed over by whoever waits (L523). Two windows never run
#      at once.
#   2. Waits until no merge-when-ready.sh run and no full suite run (run-all-tests.sh) is active,
#      for LOAD_WINDOW_WAIT_SECONDS at most, then refuses (exit 75) naming what was running.
#      HOW THEY ARE SEEN, cheaply: one `ps` per look (lib/suite-pile.sh's table, the same seam the
#      suite pile notice reads), matching a shell running a script NAMED merge-when-ready.sh or
#      run-all-tests.sh, and, as a second source that does not depend on how a command line is
#      spelled (L1011), every live ticket in the merge helper's own turn folders, which every
#      merge-when-ready.sh run on this Mac holds from its first look to its merge. Anything this
#      window started itself is never counted.
#   3. Records the window's start and its deadline in lib/load-window.sh's record, which the merge
#      helper and the suite pile notice read back and name, in ET.
#   4. Starts the busy workers and the command, each in a process group of its own, and runs until
#      the command ends, the deadline (at most 180 seconds, the three minute cap set on 2026-10-23
#      while other merges were failing on the Mac's load), or a merge or full suite starts, in which
#      case the window YIELDS: it stops early and says so (exit 75), because a window must not
#      overlap them.
#   5. Stops everything it started on every way out (a trap on EXIT, HUP, INT and TERM): each group
#      is signalled as a group (L321), what is left is killed by lib/kill-tree.sh, the groups are
#      confirmed empty, and the end is recorded. A run killed outright (SIGKILL) cannot do that, so
#      every group also carries its own watchdog that kills the whole group at the deadline plus
#      five seconds of real time, and the busy loops end themselves then too: nothing it starts can
#      outlive the window by more than that.
#
# Usage:
#   tools/load-window.sh --seconds S [--workers N] [--spawners M] [--label TEXT] [-- command ...]
#   tools/load-window.sh --status
#     --seconds   the window's ceiling, 1 to 180
#     --workers   busy loops (default: this Mac's core count)
#     --spawners  process launching loops, which load the kernel's process table the way a suite
#                 does (default 0)
#     --label     what the window is for, named wherever it is reported (default: the command)
#     command     run in the window, in the foreground, its output passed through; without one the
#                 window holds the load until its ceiling
#     --status    read only (L206): the windows recorded, the turn's queue, and what merge or full
#                 suite runs are active now
#
# Exit: the command's own exit when it finished inside the window (0 without a command); 124 when
# the command was cut off at the ceiling; 75 when the window was refused (it never started) or
# yielded; 2 for a usage fault; 1 when something it started could not be confirmed stopped, or the
# record could not be written.
#
# Seams, so its tests never wait on a real clock (L290, L524): LOAD_WINDOW_NOW (a command printing
# epoch seconds), LOAD_WINDOW_SLEEP (the sleep between looks), SYNC_PS_FIXTURE (the process table),
# LOAD_WINDOW_MERGE_TURNS (the merge helper's turn folders, default MWR_TURN_DIR or
# ~/.claude/state/merge-turns), LOAD_WINDOW_DIR (the record and this turn, see lib/load-window.sh).
# Settings: LOAD_WINDOW_POLL (1: seconds between looks in the window), LOAD_WINDOW_WAIT_POLL (5),
# LOAD_WINDOW_WAIT_SECONDS (360), LOAD_WINDOW_HOLD_SECONDS (600). At the defaults the wait, the
# ceiling and the watchdogs' five second margin come to 545 seconds at most, so the whole run fits
# one foreground command's ten minute limit. These are settings, not measurements.
set -uo pipefail

SELF_DIR="${BASH_SOURCE[0]%/*}"; [ "$SELF_DIR" != "${BASH_SOURCE[0]}" ] || SELF_DIR=.
SELF_DIR="$(cd "$SELF_DIR" && pwd)"
LIB="$SELF_DIR/../payload/hooks/lib"
for f in load-window.sh merge-turn.sh suite-pile.sh load-average.sh; do
  # shellcheck disable=SC1090
  . "$LIB/$f" 2>/dev/null || { echo "load-window: $LIB/$f is missing, so no window was started." >&2; exit 1; }
done
KILL_TREE="$LIB/kill-tree.sh"

MAX_SECONDS=180
num(){ case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
setting(){ if num "${1:-}"; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
POLL="$(setting "${LOAD_WINDOW_POLL:-}" 1)"
WAIT_POLL="$(setting "${LOAD_WINDOW_WAIT_POLL:-}" 5)"
WAIT_MAX="$(setting "${LOAD_WINDOW_WAIT_SECONDS:-}" 360)"
HOLD="$(setting "${LOAD_WINDOW_HOLD_SECONDS:-}" 600)"
SLEEP="${LOAD_WINDOW_SLEEP:-sleep}"
MERGE_TURNS="${LOAD_WINDOW_MERGE_TURNS:-${MWR_TURN_DIR:-$HOME/.claude/state/merge-turns}}"

now(){
  local t=""
  [ -n "${LOAD_WINDOW_NOW:-}" ] && t="$(${LOAD_WINDOW_NOW} 2>/dev/null)"
  num "$t" || t="$(date +%s)"
  printf '%s' "$t"
}
say(){ printf 'load-window: %s\n' "$*"; }
usage(){ printf 'load-window: %s\n' "$1" >&2; sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//' >&2; exit 2; }

seconds=""; workers=""; spawners=0; label=""; status=""
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) [ $# -ge 2 ] || usage "--seconds needs a number."; seconds="$2"; shift 2 ;;
    --workers) [ $# -ge 2 ] || usage "--workers needs a number."; workers="$2"; shift 2 ;;
    --spawners) [ $# -ge 2 ] || usage "--spawners needs a number."; spawners="$2"; shift 2 ;;
    --label) [ $# -ge 2 ] || usage "--label needs text."; label="$2"; shift 2 ;;
    --status) status=1; shift ;;
    --) shift; break ;;
    *) usage "$1 is not an option this takes; a command goes after --." ;;
  esac
done
cmd=("$@")

# What is running that a window must not overlap: one line per run, "<pid> <what>", nothing when
# clear. A process this run started (its descendants in the table) is never counted.
busy_now(){
  local table seen="" f pid st pr slug
  if table="$(suite_pile_table)"; then
    seen="$(printf '%s\n' "$table" | awk -v self="$$" '
      function base(w) { sub(/.*\//, "", w); return w }
      {
        p = $1; parent[p] = $2; c = ""
        for (i = 4; i <= NF; i++) c = c (i > 4 ? " " : "") $i
        cmd[p] = c; order[++n] = p
      }
      END {
        for (k = 1; k <= n; k++) {
          p = order[k]; q = p; mine = 0
          for (d = 0; d < 100 && q != "" && q != "0"; d++) { if (q == self) { mine = 1; break }; q = parent[q] }
          if (mine) continue
          m = split(cmd[p], w, " "); script = ""
          if (base(w[1]) ~ /^(merge-when-ready|run-all-tests)\.sh$/) script = base(w[1])
          else if (base(w[1]) ~ /^(ba|z|da)?sh$/) {
            for (j = 2; j <= m; j++) if (w[j] !~ /^-/) { if (base(w[j]) ~ /^(merge-when-ready|run-all-tests)\.sh$/) script = base(w[j]); break }
          }
          if (script == "merge-when-ready.sh") printf "%s a merge-when-ready.sh run (%s)\n", p, substr(cmd[p], 1, 120)
          else if (script == "run-all-tests.sh") printf "%s a full suite run (%s)\n", p, substr(cmd[p], 1, 120)
        }
      }')"
  else
    seen="? the process table could not be read, so whether a merge or a full suite is running is unknown"
  fi
  for f in "$MERGE_TURNS"/*/*/*; do
    case "${f##*/}" in ''|*[!0-9]*) continue ;; esac
    [ -s "$f" ] || continue
    pid="$(turn_field "$f" pid)"; st="$(turn_field "$f" start)"; pr="$(turn_field "$f" pr)"
    turn_alive "$pid" "$st" || continue
    case $'\n'"$seen"$'\n' in *$'\n'"$pid "*) continue ;; esac
    slug="${f%/*}"; slug="${slug#"$MERGE_TURNS"/}"
    seen="${seen:+$seen$'\n'}$pid a merge-when-ready.sh run holding a place to merge $slug#$pr"
  done
  [ -z "$seen" ] || printf '%s\n' "$seen"
}

if [ -n "$status" ]; then
  t="$(now)"
  say "Windows recorded in $(load_window_record), latest last:"
  list="$(load_window_list | tail -n 10)"
  if [ -z "$list" ]; then say "  none."; fi
  while IFS=$'\t' read -r id st dl en pid w s how lb; do
    [ -n "$id" ] || continue
    if [ "$en" = "-" ] && [ "$t" -lt "$dl" ]; then
      say "  RUNNING since $(load_window_et "$st"), until $(load_window_et "$dl") at the latest: pid $pid, $w busy and $s process launching workers, \"$lb\""
    elif [ "$en" = "-" ]; then
      say "  $(load_window_et "$st") to $(load_window_et "$dl") (no end recorded; its workers ended themselves then): pid $pid, $w busy and $s process launching workers, \"$lb\""
    else
      say "  $(load_window_et "$st") to $(load_window_et "$en"), $how: pid $pid, $w busy and $s process launching workers, \"$lb\""
    fi
  done <<<"$list"
  # Counted here rather than by turn_look, which tidies a dead holder's ticket away: --status changes
  # nothing (L206).
  MWR_TURN_DIR="$(load_window_dir)" turn_open "queue/turn"; live=0
  for n in $(turn_tickets); do
    f="$TURN_REPO_DIR/$n"
    turn_alive "$(turn_field "$f" pid)" "$(turn_field "$f" start)" && live=$((live + 1))
  done
  say "The load window turn: $live window run(s) holding or waiting for it."
  b="$(busy_now)"
  if [ -n "$b" ]; then say "Running now, which a window waits for:"; printf '%s\n' "$b" | sed 's/^[^ ]* /  /; s/^/load-window: /'
  else say "Running now: no merge-when-ready.sh run and no full suite run."; fi
  exit 0
fi

num "$seconds" || usage "--seconds is required, a whole number of seconds."
[ "$seconds" -ge 1 ] && [ "$seconds" -le "$MAX_SECONDS" ] || usage "--seconds $seconds is outside 1 to $MAX_SECONDS: a window is three minutes at most, so other sessions' merges and suites are not starved."
[ -n "$workers" ] || workers="$(load_average_cores 2>/dev/null)"
[ -n "$workers" ] || workers="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
num "$workers" || usage "--workers must be a whole number."
num "$spawners" || usage "--spawners must be a whole number."
[ $(( workers + spawners )) -ge 1 ] || usage "a window needs at least one worker."
[ $(( workers + spawners )) -le 256 ] || usage "$workers busy and $spawners process launching workers is more than 256, more than any reproduction here has needed."
[ -n "$label" ] || label="${cmd[*]:-load only}"

# --- every way out stops everything, records the end and gives up the turn -----------------------
wpid=""; cpid=""; window_id=""; how=""; finished=""
# Whether anything in the group still RUNS: a killed process not yet reaped (state Z) runs nothing.
group_left(){
  local p
  for p in $(pgrep -g "$1" 2>/dev/null); do
    case "$(ps -o stat= -p "$p" 2>/dev/null)" in *Z*|'') ;; *) return 0 ;; esac
  done
  return 1
}
stop_group(){   # $1 = group leader's pid: the group, then what it left, then confirm (L321, L212)
  local g="$1" i
  [ -n "$g" ] || return 0
  kill -TERM -- "-$g" 2>/dev/null
  bash "$KILL_TREE" "$g" 2>/dev/null
  # A second for TERM, then KILL, then a ceiling only something unkillable reaches: on a Mac at load
  # 300 a killed process can take more than a moment to go, and that is not a process left running.
  # Each wait is on the group being empty, and the leader, this run's own child, is reaped after.
  for i in 1 2 3 4 5 6 7 8 9 10; do group_left "$g" || { wait "$g" 2>/dev/null; return 0; }; sleep 0.1; done
  kill -KILL -- "-$g" 2>/dev/null
  for i in $(seq 1 300); do group_left "$g" || { wait "$g" 2>/dev/null; return 0; }; sleep 0.1; done
  return 1
}
finish(){
  local rc=$? left=""
  [ -z "$finished" ] || return 0
  finished=1
  stop_group "$wpid" || left="${left} the busy workers (process group $wpid)"
  stop_group "$cpid" || left="${left} the command (process group $cpid)"
  if [ -n "$window_id" ]; then
    load_window_finish "$window_id" "$(now)" "${how:-ended (exit $rc)}" \
      || say "Could not record this window's end in $(load_window_record); readers will take its deadline as its end."
    say "Window ended at $(load_window_et "$(now)"): ${how:-ended (exit $rc)}."
  fi
  turn_leave
  if [ -n "$left" ]; then
    say "STILL RUNNING after TERM and KILL:$left. Find them with: pgrep -g <group>."
    exit 1
  fi
}
trap 'finish' EXIT
trap 'how="stopped by signal HUP"; exit 129' HUP
trap 'how="stopped by signal INT"; exit 130' INT
trap 'how="stopped by signal TERM"; exit 143' TERM

# --- 1 and 2: the turn, then nothing a window must not overlap ------------------------------------
TURN_PID=$$; TURN_PID_START=""; TURN_TICKET=""
MWR_TURN_DIR="$(load_window_dir)" turn_open "queue/turn"
t0="$(now)"
turn_join "$$" "$t0" || { say "Could not take a place in the load window turn ($TURN_ERR), so no window was started."; exit 75; }
last_said=""; looks=0; max_looks=$(( WAIT_MAX / (WAIT_POLL > 0 ? WAIT_POLL : 1) + 10 ))
while :; do
  t="$(now)"
  turn_look "$t" "$HOLD"
  [ -z "$TURN_SAID" ] || printf '%s\n' "$TURN_SAID" | sed -e "s/#\([0-9][0-9]*\)'s place in line/the window run by pid \1/" \
    -e "s/#\([0-9][0-9]*\)'s turn/the window run by pid \1/" -e 's/any one pull request/any one window/' -e 's/^/load-window: /'
  if [ -n "$TURN_GONE" ]; then
    TURN_TICKET=""; turn_join "$$" "$t" || { say "Lost this run's place in the load window turn and could not join again ($TURN_ERR), so no window was started."; exit 75; }
    continue
  fi
  if [ "$TURN_MINE" != 1 ]; then
    waiting="another load window, run by pid ${TURN_HEAD_PR:-?} ($TURN_AHEAD ahead of this one)"
  else
    busy="$(busy_now)"
    [ -n "$busy" ] || break
    waiting="$(printf '%s\n' "$busy" | sed 's/^[^ ]* //' | paste -sd ';' - | sed 's/;/; /g')"
  fi
  if [ $(( t - t0 )) -ge "$WAIT_MAX" ] || [ "$looks" -ge "$max_looks" ]; then
    how="refused before it started"
    say "Refused: after $(( t - t0 ))s this is still waiting for $waiting, and a deliberate load window must not overlap other sessions' merges or full suites (claude-config#1618). Nothing was started; run it again later."
    exit 75
  fi
  [ "$waiting" = "$last_said" ] || say "Waiting for $waiting, for up to ${WAIT_MAX}s in all."
  last_said="$waiting"
  looks=$((looks + 1))
  "$SLEEP" "$WAIT_POLL"
done

# --- 3 and 4: record it, then start the workers and the command -----------------------------------
start="$(now)"; deadline=$(( start + seconds )); limit=$(( seconds + 5 ))
window_id="$start.$$"
load_window_begin "$window_id" "$start" "$deadline" "$$" "$workers" "$spawners" "$label" || {
  window_id=""; how="refused before it started"
  say "Could not write the window record in $(load_window_dir), so no window was started: one nobody can see is what the record exists to prevent."
  exit 1
}
load_window_trim
say "Window started at $(load_window_et "$start"), until $(load_window_et "$deadline") at the latest: $workers busy and $spawners process launching workers, \"$label\"."
set -m
# The workers' group: each loop ends itself at the limit (bash's SECONDS, no fork), and a watchdog
# in the same group kills the whole group then, which holds even if this run is killed outright.
bash -c '
  lim=$1; n=$2; m=$3
  (sleep "$lim"; kill -KILL 0) &
  i=0; while [ "$i" -lt "$n" ]; do bash -c "while [ \$SECONDS -lt $lim ]; do :; done" & i=$((i + 1)); done
  i=0; while [ "$i" -lt "$m" ]; do bash -c "while [ \$SECONDS -lt $lim ]; do /usr/bin/true; done" & i=$((i + 1)); done
  wait' load-window-workers "$limit" "$workers" "$spawners" </dev/null >/dev/null 2>&1 &
wpid=$!
if [ ${#cmd[@]} -gt 0 ]; then
  # The command's group carries the same watchdog. Its output is the run's output; the watchdog's
  # is not, so it never holds the caller's pipe open after the window (L235).
  LOAD_WINDOW_WORKERS_PGID="$wpid" bash -c 'lim=$1; shift; (sleep "$lim"; kill -KILL 0) >/dev/null 2>&1 & "$@"' load-window-command "$limit" "${cmd[@]}" </dev/null &
  cpid=$!
fi
set +m

looks=0; max_looks=$(( seconds / (POLL > 0 ? POLL : 1) + 10 )); rc=0
while :; do
  if [ -n "$cpid" ] && ! kill -0 "$cpid" 2>/dev/null; then
    wait "$cpid"; rc=$?
    how="the command finished (exit $rc)"
    exit "$rc"
  fi
  t="$(now)"
  if [ "$t" -ge "$deadline" ] || [ "$looks" -ge "$max_looks" ]; then
    if [ -n "$cpid" ]; then how="cut off at its ${seconds}s ceiling, the command still running"; exit 124; fi
    how="held for its ${seconds}s"; exit 0
  fi
  busy="$(busy_now)"
  if [ -n "$busy" ]; then
    how="yielded after $(( t - start ))s to $(printf '%s\n' "$busy" | sed 's/^[^ ]* //' | paste -sd ';' - | sed 's/;/; /g')"
    say "Stopping early: ${how#yielded after * to } started, and a deliberate load window must not overlap it."
    exit 75
  fi
  looks=$((looks + 1))
  "$SLEEP" "$POLL"
done
