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
# "first 1" is not honoured and is said to the runs it would have passed. A helper started before
# this version reads the line in number order, so its ticket (one without "order 2") is never
# passed: a run at the front stays behind it, and the two never both believe the turn is theirs.
#
# WHEN ITS HOLDER DIES (L409). A file lock outlives the process holding it, so a ticket names its
# run's pid and that process's start time. A ticket whose pid the system says is not running, or is
# running with another start time (the pid was reused), is passed over at once and removed, and
# whoever removed it says so. Liveness is judged dead only on that positive evidence: a pid that
# cannot be read either way is taken as alive, and the bound below ends it.
#
# ONE FORM OF A START TIME (claude-config#2828). ps prints a start time in the time zone and language
# of the process READING it, so a run started under TZ=UTC0 (or another locale) and read by a run in
# the Mac's own zone looked like a reused pid: its ticket was removed and it lost its place. A ticket
# this version writes for a run whose start it read itself also carries "startc", the start read in
# the C locale and UTC0, which every reader reads the same way, and a ticket carrying it is judged by
# it. A ticket without it (an older helper's, or one whose start the caller named) is judged by
# "start" as before, so an older helper reading a new ticket sees nothing it does not know.
#
# TAKING A PLACE BACK (claude-config#2828). A run that finds its ticket gone while it was only
# waiting can take the same number back (turn_retake): numbers are never handed out twice, so the
# number is still free and still sits where the run arrived, and every reader, old or new, puts it
# back in that order. Joining again at the back put every run that arrived after it ahead of it.
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
#   turn_retake <pr> <joined>   takes this run's own number (TURN_TICKET) back after another run
#                               removed it, keeping when it first joined; returns 1 with TURN_ERR
#                               when that place is taken or the run never had one
#   turn_leave                  gives up this run's place
#
# TURN_PID and TURN_PID_START name the run (this shell and its start time by default).

TURN_PID="${TURN_PID:-$$}"
TURN_PID_START="${TURN_PID_START:-}"
# The fixed form of this run's start, and the "<pid> <start>" it was read with: written only for
# that same pid and start, so a start the caller names is never paired with one read elsewhere.
TURN_PID_STARTC=""; TURN__STARTC_OF=""
TURN_TICKET=""; TURN_REPO_DIR=""; TURN_ERR=""

# Every reader here runs in the shell's own builtins, never a sed, cat or grep per field (claude-config
# #2694): a look reads every ticket in the line, and at a program per field a line of 15 started about
# 150 programs a look, at every look of every helper waiting in it.
# turn__trim <text>: the text without its leading and trailing spaces, as sed 's/^ *//;s/ *$//' gave.
turn__trim(){ local s="$1"; s="${s#"${s%%[! ]*}"}"; s="${s%"${s##*[! ]}"}"; printf '%s' "$s"; }
turn_proc_start(){   # $1 = pid [$2 = c: in the fixed form, the C locale and UTC0]
  local s
  if [ "${2:-}" = c ]; then s="$(LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" 2>/dev/null)"
  else s="$(ps -o lstart= -p "$1" 2>/dev/null)"; fi
  case "$s" in
    *$'\n'*) printf '%s\n' "$s" | sed -e 's/^ *//' -e 's/ *$//' ;;
    *) turn__trim "$s" ;;
  esac
}
turn_dur(){
  if [ "$1" -ge 60 ]; then
    if [ $(( $1 % 60 )) -eq 0 ]; then printf '%dm' "$(( $1 / 60 ))"; else printf '%dm %02ds' "$(( $1 / 60 ))" "$(( $1 % 60 ))"; fi
  else printf '%ds' "$1"; fi
}
# The rest of the first line that starts "<key> ", or nothing (a file that cannot be read included).
turn_field(){
  local l
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in "$2 "*) printf '%s' "${l#"$2 "}"; return 0 ;; esac
  done 2>/dev/null < "$1"
  return 0
}
# turn__slurp <file>: sets TURN__TEXT to the file as $(cat) gives it (trailing newlines dropped), or
# empty when it cannot be read.
turn__slurp(){
  local l t=""
  TURN__TEXT=""
  while IFS= read -r l || [ -n "$l" ]; do t="$t$l"$'\n'; done 2>/dev/null < "$1"
  while [ "${t%$'\n'}" != "$t" ]; do t="${t%$'\n'}"; done
  TURN__TEXT="$t"
}
# turn__first_line <file>: 0 when a line of it is "first", or starts "first ".
turn__first_line(){
  local l
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in first|"first "*) return 0 ;; esac
  done 2>/dev/null < "$1"
  return 1
}

# The start times of a look's runs, read with ONE ps for all of them (claude-config#2694) rather than
# one each. turn__batch [c] <pid>...: sets TURN__STARTS ("<pid> <start>" lines) and TURN__BATCHED
# (the pids asked), or with c, TURN__STARTCS and TURN__BATCHEDC in the fixed form (#2828), so a look
# whose tickets all carry the fixed form still starts one ps. A ps that fails (it refuses the whole
# list over one pid it calls too large, and says nothing for it) leaves nothing batched, so every pid
# is read alone as before. A pid the list answered without is not running, which its own read would
# have found too. turn__unbatch ends both.
TURN__STARTS=""; TURN__BATCHED=""; TURN__STARTCS=""; TURN__BATCHEDC=""
turn__batch(){
  local list="" p out l pid canon="" batched="" starts=""
  if [ "${1:-}" = c ]; then canon=1; shift; fi
  for p in "$@"; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    case " $batched " in *" $p "*) continue ;; esac
    batched="$batched $p"; list="$list${list:+,}$p"
  done
  if [ -n "$list" ]; then
    if [ -n "$canon" ]; then out="$(LC_ALL=C TZ=UTC0 ps -o pid=,lstart= -p "$list" 2>/dev/null)" || batched=""
    else out="$(ps -o pid=,lstart= -p "$list" 2>/dev/null)" || batched=""; fi
    if [ -n "$batched" ]; then
      while IFS= read -r l; do
        l="$(turn__trim "$l")"; pid="${l%% *}"
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        starts="$starts$pid $(turn__trim "${l#"$pid"}")"$'\n'
      done <<<"$out"
    fi
  fi
  if [ -n "$canon" ]; then TURN__STARTCS="$starts"; TURN__BATCHEDC="$batched"
  else TURN__STARTS="$starts"; TURN__BATCHED="$batched"; fi
}
turn__unbatch(){ TURN__STARTS=""; TURN__BATCHED=""; TURN__STARTCS=""; TURN__BATCHEDC=""; }
# turn__start <pid> [c]: prints its start time, from the batch when it was asked there.
turn__start(){
  local l asked starts
  if [ "${2:-}" = c ]; then asked="$TURN__BATCHEDC"; starts="$TURN__STARTCS"
  else asked="$TURN__BATCHED"; starts="$TURN__STARTS"; fi
  case " $asked " in
    *" $1 "*)
      while IFS= read -r l; do
        [ "${l%% *}" = "$1" ] && { printf '%s' "${l#* }"; return 0; }
      done <<<"$starts"
      return 0 ;;
  esac
  turn_proc_start "$1" "${2:-}"
}

# Dead only on evidence: the system says no such process, or the pid runs with another start time.
# Judged by the fixed form when the ticket carries one (#2828), else by the start as it was written.
turn_alive(){   # $1 = pid, $2 = the start time recorded for it [$3 = its start in the fixed form]
  local out st
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  if ! out="$(kill -0 "$1" 2>&1)"; then
    case "$out" in *"o such process"*) return 1 ;; esac
  fi
  if [ -n "${3:-}" ]; then
    st="$(turn__start "$1" c)"
    [ -z "$st" ] || [ "$st" = "$3" ] || return 1
    return 0
  fi
  st="$(turn__start "$1")"
  [ -z "$st" ] || [ -z "$2" ] || [ "$st" = "$2" ] || return 1
  return 0
}

turn_open(){   # $1 = owner/name
  local root="${MWR_TURN_DIR:-$HOME/.claude/state/merge-turns}"
  TURN_REPO_DIR="$root/$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  return 0
}

turn_tickets(){   # the ticket numbers in the repository's folder, lowest first
  # Sorted in the shell, as sort -n would (equal numbers by their text), and by sort -n itself for a
  # name too long for the shell's arithmetic (claude-config#2694).
  local f b out="" long="" rest t placed
  for f in "$TURN_REPO_DIR"/*; do
    b="${f##*/}"
    case "$b" in ''|*[!0-9]*) continue ;; esac
    [ "${#b}" -le 15 ] || long=1
    out="$out$b"$'\n'
  done
  [ -n "$out" ] || return 0
  if [ -n "$long" ]; then printf '%s' "$out" | sort -n; return 0; fi
  rest=""
  for b in $out; do
    placed=""; t=""
    for f in $rest; do
      if [ -z "$placed" ] && { [ $((10#$b)) -lt $((10#$f)) ] || { [ $((10#$b)) -eq $((10#$f)) ] && [[ "$b" < "$f" ]]; }; }; then
        t="$t $b"; placed=1
      fi
      t="$t $f"
    done
    [ -n "$placed" ] || t="$t $b"
    rest="$t"
  done
  for b in $rest; do printf '%s\n' "$b"; done
}

# turn__ticket <pr> <joined> <front line or nothing>: writes this run's ticket to a private file,
# TURN__TMP, complete before it is linked into the line, or returns 1 with TURN_ERR.
turn__ticket(){
  local startc=""
  if ! mkdir -p "$TURN_REPO_DIR" 2>/dev/null || [ ! -d "$TURN_REPO_DIR" ]; then
    TURN_ERR="could not make $TURN_REPO_DIR"; return 1
  fi
  if [ -z "$TURN_PID_START" ]; then
    TURN_PID_START="$(turn_proc_start "$TURN_PID")"
    TURN_PID_STARTC="$(turn_proc_start "$TURN_PID" c)"; TURN__STARTC_OF="$TURN_PID $TURN_PID_START"
  fi
  [ "$TURN__STARTC_OF" = "$TURN_PID $TURN_PID_START" ] && [ -n "$TURN_PID_STARTC" ] && startc="startc $TURN_PID_STARTC"$'\n'
  TURN__TMP="$TURN_REPO_DIR/.join.$TURN_PID.$RANDOM"
  # "order 2": this run reads the line with its front (see turn_order), so a run at the front may
  # go ahead of it; a ticket without it is an older helper's, which reads the line in number order.
  if ! printf 'pr %s\npid %s\nstart %s\n%sjoined %s\norder 2\n%s' "$1" "$TURN_PID" "$TURN_PID_START" "$startc" "$2" "$3" > "$TURN__TMP" 2>/dev/null; then
    rm -f "$TURN__TMP"; TURN_ERR="could not write in $TURN_REPO_DIR"; return 1
  fi
  return 0
}

turn_join(){   # $1 = pull request, $2 = now, $3 = "first" to join at the front, or nothing
  local tmp n hw max tries=0 front=""
  TURN_ERR=""; TURN_TICKET=""
  case "${3:-}" in
    '') ;;
    first) front=$'first 1\n' ;;
    *) TURN_ERR="'$3' is not a way to join the line (only first, or nothing)"; return 1 ;;
  esac
  turn__ticket "$1" "$2" "$front" || return 1
  tmp="$TURN__TMP"
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
  turn__slurp "$m"; line="$TURN__TEXT"
  if [ -n "$line" ] && [ "${line#* }" != "$2" ]; then rm -f "$m"; line=""; fi
  if [ -z "$line" ]; then
    tmp="$TURN_REPO_DIR/.mark.$TURN_PID.$RANDOM"
    printf '%s %s\n' "$3" "$2" > "$tmp" 2>/dev/null && ln "$tmp" "$m" 2>/dev/null
    rm -f "$tmp"
    turn__slurp "$m"; line="$TURN__TEXT"
  fi
  turn_since="${line%% *}"
  case "$turn_since" in ''|*[!0-9]*) turn_since="$3" ;; esac
}

# The order of the line (claude-config#2474): the ticket holding the turn (its mark names its own
# pid), then the tickets that joined at the front, then the rest, each group by number. A ticket at
# the front therefore goes ahead of every run still waiting and never ahead of the one holding the
# turn, which may be merging, and two at the front keep the order they joined in. A ticket without
# "order 2" belongs to a helper started before the front existed, which reads the line in number
# order: a run at the front stays behind it, since going ahead would leave both believing the turn
# theirs once the holder left. So each ticket at the front goes in just after the last ticket
# already placed that is at the front or an older helper's, ahead of the rest.
turn_order(){
  # placed: the tickets not holding the turn, in order, each marked F (at the front), O (an older
  # helper's) or N (the rest). Plain words, not an array, so bash 3.2 under set -u reads it empty.
  local n f pid mark tok before after held="" placed=""
  for n in $(turn_tickets); do
    f="$TURN_REPO_DIR/$n"
    [ -s "$f" ] || continue
    pid="$(turn_field "$f" pid)"; turn__slurp "$f.head"; mark="$TURN__TEXT"
    if [ -n "$mark" ] && [ -n "$pid" ] && [ "${mark#* }" = "$pid" ]; then held="$held $n"; continue; fi
    if [ "$(turn_field "$f" first)" = 1 ]; then
      before=""; after=""
      for tok in $placed; do
        case "$tok" in F*|O*) before="$before $after $tok"; after="" ;; *) after="$after $tok" ;; esac
      done
      placed="$before F$n $after"
    elif [ "$(turn_field "$f" order)" = 2 ]; then placed="$placed N$n"
    else placed="$placed O$n"; fi
  done
  for tok in $held; do printf '%s\n' "$tok"; done
  for tok in $placed; do printf '%s\n' "${tok#?}"; done
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
  local now="$1" bound="$2" n f pid start startc pr fv seen_own="" head="" order pids cpids
  TURN_MINE=0; TURN_HEAD_PR=""; TURN_HEAD_SINCE=""; TURN_HEAD_TICKET=""; TURN_AHEAD=0; TURN_WAITING=0; TURN_GONE=""; TURN_SAID=""; TURN_OVERTOOK=0
  order="$(turn_order)"
  # Every other run's start time in one ps, read before the loop (claude-config#2694): one for the
  # tickets carrying the fixed form (#2828), and one more only while an older ticket is in line.
  pids=""; cpids=""
  for n in $order; do
    [ "$n" = "$TURN_TICKET" ] && continue
    f="$TURN_REPO_DIR/$n"
    if [ -n "$(turn_field "$f" startc)" ]; then cpids="$cpids $(turn_field "$f" pid)"
    else pids="$pids $(turn_field "$f" pid)"; fi
  done
  # shellcheck disable=SC2086
  turn__batch $pids
  # shellcheck disable=SC2086
  turn__batch c $cpids
  for n in $order; do
    f="$TURN_REPO_DIR/$n"
    [ -s "$f" ] || continue
    pid="$(turn_field "$f" pid)"; start="$(turn_field "$f" start)"; startc="$(turn_field "$f" startc)"
    pr="$(turn_field "$f" pr)"; fv="$(turn_field "$f" first)"
    if [ "$n" != "$TURN_TICKET" ] && ! turn_alive "$pid" "$start" "$startc"; then
      rm -f "$f" "$f.head"
      TURN_SAID="${TURN_SAID}#${pr:-?}'s place in line was passed over: its run (pid $pid) is no longer running."$'\n'
      continue
    fi
    # A front of line mark that cannot be read is not honoured, and the runs it would have passed
    # are told so: never silently taken as a place at the front, nor silently dropped.
    if [ "$fv" != 1 ] && turn__first_line "$f" && [ -n "$TURN_TICKET" ] && [ "$n" -gt "$TURN_TICKET" ]; then
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
  turn__unbatch
  TURN_SAID="${TURN_SAID%$'\n'}"
  if [ -n "$TURN_TICKET" ] && [ -z "$seen_own" ]; then TURN_GONE=1; return 0; fi
  [ -n "$TURN_TICKET" ] && [ "$head" = "$TURN_TICKET" ] && TURN_MINE=1
  return 0
}

# Takes this run's own number back after another run removed its ticket (#2828). ln fails when the
# name exists, so a place another ticket now holds is never taken over.
turn_retake(){   # $1 = pull request, $2 = when this run first joined
  local n="$TURN_TICKET"
  TURN_ERR=""
  case "$n" in ''|*[!0-9]*) TURN_ERR="this run has no place in line to take back"; return 1 ;; esac
  turn__ticket "$1" "$2" "" || return 1
  if ! ln "$TURN__TMP" "$TURN_REPO_DIR/$n" 2>/dev/null; then
    rm -f "$TURN__TMP"; TURN_ERR="place $n in $TURN_REPO_DIR is taken"; return 1
  fi
  rm -f "$TURN__TMP"
  return 0
}

turn_leave(){
  [ -n "$TURN_TICKET" ] && [ -n "$TURN_REPO_DIR" ] && rm -f "$TURN_REPO_DIR/$TURN_TICKET" "$TURN_REPO_DIR/$TURN_TICKET.head"
  TURN_TICKET=""
  return 0
}
