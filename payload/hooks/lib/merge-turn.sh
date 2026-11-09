#!/usr/bin/env bash
#
# merge-turn.sh: the per repository turn merge-when-ready.sh takes before it updates, waits on and
# merges a pull request, so one already waiting on its checks is not overtaken by another helper's
# merge (claude-config#1515). Sourced; every function sets globals and returns, and none reads a
# clock: the time is passed in, so the caller's injected clock decides (L524).
#
# WHY. On 2026-10-22 PET #1885 sat in the helper for about 112 minutes: its checks take about 23, and
# four other pull requests from parallel agents merged under it, each one putting it behind main and
# starting its checks again. It merged only once the main session told the other agents to hold.
#
# WHAT IT IS. A queue of numbered tickets in one folder per repository, under this Mac's own state
# (never synced): $MWR_TURN_DIR, by default ~/.claude/state/merge-turns/<owner>/<name>/. A run joins
# by creating the next number with ln, which fails when the name exists, so two runs racing can never
# take the same place and a ticket is never seen half written (it is linked complete from a private
# file). Numbers only grow (the highest given is kept in seq), so a number is never handed to a
# second run while a first may still be judging it. The turn is the first ticket in line whose run
# is alive: every run computes it from the same listing, so there is no separate lock to hand over,
# and a run that leaves (its ticket removed) passes the turn to the next in line.
#
# THE FRONT OF THE LINE (claude-config#2474). The line is in number order, except that a ticket
# joined with "first" goes ahead of every ticket still waiting, though never ahead of the one
# holding the turn (its .head mark names its own pid), and tickets at the front keep their own
# number order. On 2026-11-08 #2471 made the sync suite cheaper, which the five pull requests ahead
# of it needed to pass CI, and moving it forward meant stopping all five helpers by hand. Each run a
# ticket at the front passes is told so once (TURN_SAID), and a "first" line that is not exactly
# "first 1" is not honoured and is said to the runs it would have passed. Only runs of this version
# order the line this way: a helper started before it reads the line in number order until it stops.
#
# WHEN ITS HOLDER DIES (L409). A file lock outlives the process holding it, so a ticket names its
# run's pid and that process's start time. A ticket whose pid the system says is not running, or is
# running with another start time (the pid was reused), is passed over at once and removed, and
# whoever removed it says so. Liveness is judged dead only on that positive evidence: a pid that
# cannot be read either way is taken as alive, and the bound below ends it.
#
# A BOUND ON HOLDING IT (L523). A live run can still be stuck (its checks never finish, a laptop
# asleep), so the moment a ticket first holds the turn is marked (<n>.head, made once with ln by
# whichever run first sees it hold, so every run agrees), and a run that is WAITING passes over a
# holder that has held it for the bound and more. The holder's own look never does: with nobody
# waiting it goes on, and when it is passed over it finds its ticket gone (TURN_GONE) and joins again
# at the back. The bound is the caller's setting.
#
# WHAT IT DOES NOT COVER. Only runs of the helper on this Mac take the turn. The other MacBook's
# helpers, a merge typed by hand and GitHub's own merge queue never see it, so they can still merge
# under a waiting pull request, exactly as before; the helper's waiting for main to settle still
# handles those. The turn decides only the ORDER helpers merge in, never whether a merge is right:
# every gate still judges each merge, so a turn wrongly held costs time, never a bad merge.
#
#   turn_open <owner/name>      sets TURN_REPO_DIR (the repository's folder; case does not matter)
#   turn_join <pr> <now> [first] takes the next place, at the front with "first": TURN_TICKET, or
#                               returns 1 with TURN_ERR (also for any third word but "first")
#   turn_look <now> <bound>     who holds the turn: TURN_MINE (1 when this run does), TURN_HEAD_PR,
#                               TURN_HEAD_SINCE, TURN_AHEAD (live tickets ahead of this one),
#                               TURN_WAITING (live tickets in all), TURN_GONE (1 when this run's
#                               own ticket is no longer there), TURN_SAID (a line per ticket it
#                               passed over, saying why), TURN_HEAD_TICKET (the holder's ticket
#                               number, which changes exactly when the turn passes, so a run in
#                               line can tell the line moving from it standing still, #1697),
#                               TURN_OVERTOOK (live tickets that joined before this one and are
#                               now behind it, because it joined at the front, #2474)
#   turn_leave                  gives up this run's place
#
# TURN_PID and TURN_PID_START name the run (this shell and its start time by default).

TURN_PID="${TURN_PID:-$$}"
TURN_PID_START="${TURN_PID_START:-}"
TURN_TICKET=""; TURN_REPO_DIR=""; TURN_ERR=""

turn_proc_start(){ ps -o lstart= -p "$1" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//'; }
turn_dur(){
  if [ "$1" -ge 60 ]; then
    if [ $(( $1 % 60 )) -eq 0 ]; then printf '%dm' "$(( $1 / 60 ))"; else printf '%dm %02ds' "$(( $1 / 60 ))" "$(( $1 % 60 ))"; fi
  else printf '%ds' "$1"; fi
}
turn_field(){ sed -n "/^$2 /{s/^$2 //p;q;}" "$1" 2>/dev/null; }

# Dead only on evidence: the system says no such process, or the pid runs with another start time.
turn_alive(){   # $1 = pid, $2 = the start time recorded for it
  local out st
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  if ! out="$(kill -0 "$1" 2>&1)"; then
    case "$out" in *"o such process"*) return 1 ;; esac
  fi
  st="$(turn_proc_start "$1")"
  [ -z "$st" ] || [ -z "$2" ] || [ "$st" = "$2" ] || return 1
  return 0
}

turn_open(){   # $1 = owner/name
  local root="${MWR_TURN_DIR:-$HOME/.claude/state/merge-turns}"
  TURN_REPO_DIR="$root/$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  return 0
}

turn_tickets(){   # the ticket numbers in the repository's folder, lowest first
  local f b
  for f in "$TURN_REPO_DIR"/*; do
    b="${f##*/}"
    case "$b" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$b"
  done | sort -n
}

turn_join(){   # $1 = pull request, $2 = now, $3 = "first" to join at the front, or nothing
  local tmp n hw max tries=0 front=""
  TURN_ERR=""; TURN_TICKET=""
  case "${3:-}" in
    '') ;;
    first) front=$'first 1\n' ;;
    *) TURN_ERR="'$3' is not a way to join the line (only first, or nothing)"; return 1 ;;
  esac
  if ! mkdir -p "$TURN_REPO_DIR" 2>/dev/null || [ ! -d "$TURN_REPO_DIR" ]; then
    TURN_ERR="could not make $TURN_REPO_DIR"; return 1
  fi
  [ -n "$TURN_PID_START" ] || TURN_PID_START="$(turn_proc_start "$TURN_PID")"
  tmp="$TURN_REPO_DIR/.join.$TURN_PID.$RANDOM"
  if ! printf 'pr %s\npid %s\nstart %s\njoined %s\n%s' "$1" "$TURN_PID" "$TURN_PID_START" "$2" "$front" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; TURN_ERR="could not write in $TURN_REPO_DIR"; return 1
  fi
  hw="$(cat "$TURN_REPO_DIR/seq" 2>/dev/null)"; case "$hw" in ''|*[!0-9]*) hw=0 ;; esac
  max="$(turn_tickets | tail -1)"; max="${max:-0}"
  [ "$max" -ge "$hw" ] || max="$hw"
  n=$((max + 1))
  # ln fails when the name exists: the place went to a run racing this one, so try the next.
  until ln "$tmp" "$TURN_REPO_DIR/$n" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 100 ]; then
      rm -f "$tmp"; TURN_ERR="could not take a place in $TURN_REPO_DIR after $tries tries"; return 1
    fi
    n=$((n + 1))
  done
  rm -f "$tmp"
  TURN_TICKET="$n"
  hw="$(cat "$TURN_REPO_DIR/seq" 2>/dev/null)"; case "$hw" in ''|*[!0-9]*) hw=0 ;; esac
  if [ "$n" -gt "$hw" ]; then
    tmp="$TURN_REPO_DIR/.seq.$TURN_PID.$RANDOM"
    { printf '%s\n' "$n" > "$tmp" && mv -f "$tmp" "$TURN_REPO_DIR/seq"; } 2>/dev/null || rm -f "$tmp"
  fi
  return 0
}

# The moment ticket $1 first held the turn, made once by whichever run first saw it hold: sets
# turn_since. A mark naming another pid is a leftover of an earlier ticket and is replaced.
turn_mark(){   # $1 = ticket, $2 = its pid, $3 = now
  local m="$TURN_REPO_DIR/$1.head" tmp line
  line="$(cat "$m" 2>/dev/null)"
  if [ -n "$line" ] && [ "${line#* }" != "$2" ]; then rm -f "$m"; line=""; fi
  if [ -z "$line" ]; then
    tmp="$TURN_REPO_DIR/.mark.$TURN_PID.$RANDOM"
    printf '%s %s\n' "$3" "$2" > "$tmp" 2>/dev/null && ln "$tmp" "$m" 2>/dev/null
    rm -f "$tmp"
    line="$(cat "$m" 2>/dev/null)"
  fi
  turn_since="${line%% *}"
  case "$turn_since" in ''|*[!0-9]*) turn_since="$3" ;; esac
}

# The order of the line (claude-config#2474): the ticket holding the turn (its mark names its own
# pid), then the tickets that joined at the front, then the rest, each group by number. A ticket at
# the front therefore goes ahead of every run still waiting and never ahead of the one holding the
# turn, which may be merging, and two at the front keep the order they joined in.
turn_order(){
  local n f pid mark held="" front="" rest=""
  for n in $(turn_tickets); do
    f="$TURN_REPO_DIR/$n"
    [ -s "$f" ] || continue
    pid="$(turn_field "$f" pid)"; mark="$(cat "$f.head" 2>/dev/null)"
    if [ -n "$mark" ] && [ -n "$pid" ] && [ "${mark#* }" = "$pid" ]; then held="$held $n"
    elif [ "$(turn_field "$f" first)" = 1 ]; then front="$front $n"
    else rest="$rest $n"; fi
  done
  printf '%s\n' $held $front $rest
}
# Tickets this run has already been told about (one that went ahead of it, a front of line mark
# that was ignored), so each is said once rather than at every look.
TURN_TOLD="${TURN_TOLD:-}"
turn_tell(){   # $1 = what about (a key), $2 = the line
  case " $TURN_TOLD " in *" $1 "*) return 0 ;; esac
  TURN_TOLD="$TURN_TOLD $1"
  TURN_SAID="${TURN_SAID}$2"$'\n'
}

turn_look(){   # $1 = now, $2 = the bound on holding it, in seconds
  local now="$1" bound="$2" n f pid start pr fv seen_own="" head=""
  TURN_MINE=0; TURN_HEAD_PR=""; TURN_HEAD_SINCE=""; TURN_HEAD_TICKET=""; TURN_AHEAD=0; TURN_WAITING=0; TURN_GONE=""; TURN_SAID=""; TURN_OVERTOOK=0
  for n in $(turn_order); do
    f="$TURN_REPO_DIR/$n"
    [ -s "$f" ] || continue
    pid="$(turn_field "$f" pid)"; start="$(turn_field "$f" start)"; pr="$(turn_field "$f" pr)"; fv="$(turn_field "$f" first)"
    if [ "$n" != "$TURN_TICKET" ] && ! turn_alive "$pid" "$start"; then
      rm -f "$f" "$f.head"
      TURN_SAID="${TURN_SAID}#${pr:-?}'s place in line was passed over: its run (pid $pid) is no longer running."$'\n'
      continue
    fi
    # A front of line mark that cannot be read is not honoured, and the runs it would have passed
    # are told so: never silently taken as a place at the front, nor silently dropped.
    if [ "$fv" != 1 ] && grep -qE '^first( |$)' "$f" 2>/dev/null && [ -n "$TURN_TICKET" ] && [ "$n" -gt "$TURN_TICKET" ]; then
      turn_tell "ignored:$n" "#${pr:-?}'s place at the front of the line was ignored: its ticket says 'first ${fv}', which is not a front of line mark, so it waits behind this one in the order it joined."
    fi
    if [ -z "$head" ]; then
      turn_mark "$n" "$pid" "$now"
      if [ "$n" != "$TURN_TICKET" ] && [ -n "$TURN_TICKET" ] && [ $(( now - turn_since )) -ge "$bound" ]; then
        rm -f "$f" "$f.head"
        TURN_SAID="${TURN_SAID}#${pr:-?}'s turn ran out after $(turn_dur $(( now - turn_since ))), past the $(turn_dur "$bound") any one pull request may hold it, so it passed to the next in line."$'\n'
        continue
      fi
      head="$n"; TURN_HEAD_PR="$pr"; TURN_HEAD_SINCE="$turn_since"; TURN_HEAD_TICKET="$n"
    fi
    TURN_WAITING=$((TURN_WAITING + 1))
    if [ "$n" = "$TURN_TICKET" ]; then seen_own=1
    elif [ -z "$seen_own" ]; then
      TURN_AHEAD=$((TURN_AHEAD + 1))
      # Ahead of this run though it joined after it: it went to the front, said once to each run
      # it passed (claude-config#2474).
      if [ -n "$TURN_TICKET" ] && [ "$fv" = 1 ] && [ "$n" -gt "$TURN_TICKET" ]; then
        turn_tell "front:$n" "#${pr:-?} went to the front of the line to merge, ahead of this one: its helper was started with --first, for a pull request the others need merged first (a fix to CI they are failing on, say). Every gate still judges its merge."
      fi
    elif [ -n "$TURN_TICKET" ] && [ "$n" -lt "$TURN_TICKET" ]; then
      TURN_OVERTOOK=$((TURN_OVERTOOK + 1))
    fi
  done
  TURN_SAID="${TURN_SAID%$'\n'}"
  if [ -n "$TURN_TICKET" ] && [ -z "$seen_own" ]; then TURN_GONE=1; return 0; fi
  [ -n "$TURN_TICKET" ] && [ "$head" = "$TURN_TICKET" ] && TURN_MINE=1
  return 0
}

turn_leave(){
  [ -n "$TURN_TICKET" ] && [ -n "$TURN_REPO_DIR" ] && rm -f "$TURN_REPO_DIR/$TURN_TICKET" "$TURN_REPO_DIR/$TURN_TICKET.head"
  TURN_TICKET=""
  return 0
}
