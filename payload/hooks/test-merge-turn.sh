#!/usr/bin/env bash
# Tests for lib/merge-turn.sh (claude-config#1515): the per repository turn merge-when-ready.sh takes,
# so a pull request already waiting on its checks is not overtaken by another helper's merge.
#
# The turn is a queue of numbered tickets in a folder per repository. These tests drive the queue
# directly: who holds the turn, a holder whose process has gone or whose turn has run past its bound
# (L409, L523), two repositories, and claimants racing in separate processes (assume it runs twice).
# Time is passed in as a number, so nothing here reads a clock or waits on one (L524, L290). A live
# holder that is not this test is pid 1, which always runs, with its real start time; a dead one is a
# pid no system issues.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/merge-turn.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:2000}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then ok; else bad "$1"; echo "  must not contain: $2"; echo "  actual: ${3:0:2000}"; fi; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }

if ! . "$LIB" 2>/dev/null; then
  bad "#1515 lib/merge-turn.sh is missing or does not load"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 1
fi

LIVE=1
LIVE_START="$(ps -o lstart= -p 1 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//')"
DEAD=99999999
export MWR_TURN_DIR="$WORKDIR/turns"

# A holder that is somebody else: its own process, pid and start time, joining at a time given.
other_joins(){   # $1 = slug, $2 = pr, $3 = now, $4 = pid, $5 = start time it claims
  ( TURN_PID="$4"; TURN_PID_START="$5"; turn_open "$1" && turn_join "$2" "$3" && printf '%s' "$TURN_TICKET" )
}
# Somebody else joining at the front of the line (claude-config#2474, section 10).
other_joins_first(){   # $1 = slug, $2 = pr, $3 = now, $4 = pid, $5 = start time it claims
  ( TURN_PID="$4"; TURN_PID_START="$5"; turn_open "$1" && turn_join "$2" "$3" first && printf '%s' "$TURN_TICKET" )
}
# A look by a run that is not in line, as every waiter's look does: it marks the holder as holding.
observer_looks(){ ( TURN_TICKET=""; turn_open acme/widget; turn_look "$1" 3600 ); }
# A look from a waiter's own place in line: prints what it was told, then how many are ahead of it.
waiter_looks(){   # $1 = its ticket, $2.. = the times it looks at
  ( local tk="$1"; shift; TURN_TICKET="$tk"; TURN_PID="$LIVE"; TURN_PID_START="$LIVE_START"; turn_open acme/widget
    for t in "$@"; do turn_look "$t" 3600; printf 'said[%s] ahead[%s] head[%s]\n' "$TURN_SAID" "$TURN_AHEAD" "$TURN_HEAD_PR"; done )
}
reset(){ rm -rf "$MWR_TURN_DIR"; TURN_TICKET=""; TURN_PID="$$"; TURN_PID_START=""; }

# =================================================================================================
# 1. Alone, a run holds the turn at once; leaving it gives it up.
# =================================================================================================
reset
turn_open acme/widget; turn_join 7 1000; rc=$?
check_eq "#1515 a run alone takes a place" "0" "$rc"
check_eq "#1515 the first place is ticket 1" "1" "$TURN_TICKET"
turn_look 1000 3600
check_eq "#1515 alone, it holds the turn" "1" "$TURN_MINE"
check_eq "#1515 with nobody ahead" "0" "$TURN_AHEAD"
check_eq "#1515 and the holder is its own pull request" "7" "$TURN_HEAD_PR"
turn_leave
check_eq "#1515 leaving removes its ticket" "" "$(ls "$MWR_TURN_DIR/acme/widget" 2>/dev/null | grep -E '^[0-9]+(\.head)?$')"

# =================================================================================================
# 2. A live holder ahead: this run waits, and is told who holds it and since when.
# =================================================================================================
reset
other_joins acme/widget 9 900 "$LIVE" "$LIVE_START" >/dev/null
turn_open acme/widget; turn_join 7 1000
turn_look 1000 3600
check_eq "#1515 behind a live holder, it does not hold the turn" "0" "$TURN_MINE"
check_eq "#1515 one pull request ahead of it" "1" "$TURN_AHEAD"
check_eq "#1515 the holder is #9" "9" "$TURN_HEAD_PR"
check_eq "#1515 held since the first look that saw it hold the turn" "1000" "$TURN_HEAD_SINCE"
turn_look 1500 3600
check_eq "#1515 still held later, since the same moment" "1000" "$TURN_HEAD_SINCE"
check_eq "#1515 and still not this run's" "0" "$TURN_MINE"
check_eq "#1515 the live holder's ticket is kept" "1" "$(ls "$MWR_TURN_DIR/acme/widget" | grep -cxE '1')"
# The holder's ticket is named, so a run in line can tell the turn passing from the line standing
# still (claude-config#1697): the same while #9 holds it, another once it has passed.
check_eq "#1697 the holder's ticket is named" "1" "${TURN_HEAD_TICKET:-unset}"
# Its ticket going (its run finished) passes the turn on.
rm -f "$MWR_TURN_DIR/acme/widget/1" "$MWR_TURN_DIR/acme/widget/1.head"
turn_look 1600 3600
check_eq "#1515 once the holder leaves, the next in line holds it" "1" "$TURN_MINE"
check_eq "#1697 and the holder's ticket named is now this run's" "$TURN_TICKET" "${TURN_HEAD_TICKET:-unset}"
check_eq "#1515 held from the look that saw it pass" "1600" "$TURN_HEAD_SINCE"

# =================================================================================================
# 3. A holder whose process is gone is passed over at once (L409): a lock file outlives its holder.
# =================================================================================================
reset
other_joins acme/widget 9 900 "$DEAD" "Thu Jan  1 00:00:00 1970" >/dev/null
turn_open acme/widget; turn_join 7 1000
turn_look 1000 3600
check_eq "#1515 a dead holder does not keep the turn" "1" "$TURN_MINE"
check "#1515 saying whose turn was passed over, and why" "#9" "$TURN_SAID"
check "#1515 because its run is no longer running" "no longer running" "$TURN_SAID"
check_eq "#1515 and its ticket is gone" "0" "$(ls "$MWR_TURN_DIR/acme/widget" | grep -cxE '1')"

# A live pid that is not the process that joined (the pid was reused): dead too.
reset
other_joins acme/widget 9 900 "$LIVE" "Thu Jan  1 00:00:00 1970" >/dev/null
turn_open acme/widget; turn_join 7 1000
turn_look 1000 3600
check_eq "#1515 a reused pid is not its holder" "1" "$TURN_MINE"
check "#1515 and is said as no longer running" "no longer running" "$TURN_SAID"

# Control: the same live pid WITH its real start time holds.
reset
other_joins acme/widget 9 900 "$LIVE" "$LIVE_START" >/dev/null
turn_open acme/widget; turn_join 7 1000
turn_look 1000 3600
check_eq "#1515 control: pid 1 with its own start time is a live holder" "0" "$TURN_MINE"
check_eq "#1515 control: and nothing was said about passing it over" "" "$TURN_SAID"

# =================================================================================================
# 4. A turn held past its bound is passed on (L523): a stuck pull request must not starve the rest.
# =================================================================================================
reset
other_joins acme/widget 9 900 "$LIVE" "$LIVE_START" >/dev/null
turn_open acme/widget; turn_join 7 1000
turn_look 1000 600
check_eq "#1515 within its bound the holder keeps it" "0" "$TURN_MINE"
turn_look 1599 600
check_eq "#1515 one second short of the bound it still keeps it" "0" "$TURN_MINE"
turn_look 1600 600
check_eq "#1515 at its bound the turn passes to the next in line" "1" "$TURN_MINE"
check "#1515 saying whose turn ran out" "#9" "$TURN_SAID"
check "#1515 and for how long it was held" "ran out after 10m" "$TURN_SAID"
check_eq "#1515 the new holder's time starts now" "1600" "$TURN_HEAD_SINCE"

# The holder itself is never passed over by its own look, however long it holds: only a run that
# is waiting can take a turn over, so with nobody waiting the holder simply goes on.
reset
turn_open acme/widget; turn_join 7 1000
turn_look 1000 600
turn_look 9000 600
check_eq "#1515 a holder with nobody waiting keeps its turn past the bound" "1" "$TURN_MINE"

# A holder whose ticket a waiter took over finds it gone, and is told so.
reset
turn_open acme/widget; turn_join 7 1000
turn_look 1000 600
rm -f "$MWR_TURN_DIR/acme/widget/$TURN_TICKET" "$MWR_TURN_DIR/acme/widget/$TURN_TICKET.head"
turn_look 1700 600
check_eq "#1515 a run whose ticket was taken over knows it" "1" "$TURN_GONE"
check_eq "#1515 and does not hold the turn" "0" "$TURN_MINE"

# =================================================================================================
# 5. Different repositories never block each other.
# =================================================================================================
reset
other_joins acme/other 9 900 "$LIVE" "$LIVE_START" >/dev/null
turn_open acme/widget; turn_join 7 1000
turn_look 1000 3600
check_eq "#1515 a holder in another repository does not hold this one's turn" "1" "$TURN_MINE"
reset
other_joins Acme/Widget 9 900 "$LIVE" "$LIVE_START" >/dev/null
turn_open acme/widget; turn_join 7 1000
turn_look 1000 3600
check_eq "#1515 the same repository in another case is the same turn" "0" "$TURN_MINE"

# =================================================================================================
# 6. Places are handed out in order and never twice, even after the tickets ahead have gone.
# =================================================================================================
reset
a="$(other_joins acme/widget 9 900 "$LIVE" "$LIVE_START")"
b="$(other_joins acme/widget 8 901 "$LIVE" "$LIVE_START")"
check_eq "#1515 the second place is after the first" "1 2" "$a $b"
rm -f "$MWR_TURN_DIR/acme/widget/1" "$MWR_TURN_DIR/acme/widget/2"
c="$(other_joins acme/widget 6 902 "$LIVE" "$LIVE_START")"
check_eq "#1515 a number once given is not given again" "3" "$c"

# =================================================================================================
# 7. Claimants racing, each its own process (assume it runs twice). Six processes join at once, and
#    while all six are alive each looks: every place is different and exactly one holds the turn.
#    They are held together by fifos, so nothing here waits on a clock.
# =================================================================================================
reset
mkfifo "$WORKDIR/report" "$WORKDIR/look" "$WORKDIR/done"
exec 4<>"$WORKDIR/report" 5<>"$WORKDIR/look" 6<>"$WORKDIR/done"
N=6
for i in 1 2 3 4 5 6; do
  bash -c '
    . "$1"; turn_open acme/widget; turn_join "$2" 1000 || { echo "join-failed" > "$3/report"; exit 1; }
    echo "ticket $TURN_TICKET" > "$3/report"
    read -r _ < "$3/look"
    turn_look 1000 3600
    echo "mine $TURN_MINE $TURN_TICKET" > "$3/report"
    read -r _ < "$3/done"
  ' racer "$LIB" "$i" "$WORKDIR" &
done
tickets=""; for _ in 1 2 3 4 5 6; do read -r line <&4; tickets="$tickets ${line#ticket }"; done
distinct="$(printf '%s\n' $tickets | sort -u | grep -c .)"
check_eq "#1515 six racing claimants get six different places" "$N" "$distinct"
check_eq "#1515 numbered one to six" "1 2 3 4 5 6" "$(printf '%s\n' $tickets | sort -n | tr '\n' ' ' | sed 's/ $//')"
for _ in 1 2 3 4 5 6; do printf 'go\n' >&5; done
holders=0; holder_ticket=""
for _ in 1 2 3 4 5 6; do
  read -r line <&4
  case "$line" in "mine 1 "*) holders=$((holders + 1)); holder_ticket="${line#mine 1 }" ;; esac
done
check_eq "#1515 exactly one of the six holds the turn" "1" "$holders"
check_eq "#1515 and it is the first place" "1" "$holder_ticket"
for _ in 1 2 3 4 5 6; do printf 'go\n' >&6; done
wait
exec 4>&- 5>&- 6>&-

# =================================================================================================
# 8. A folder that cannot be written says so, rather than reading as a turn held.
# =================================================================================================
reset
: > "$WORKDIR/not-a-folder"
MWR_TURN_DIR="$WORKDIR/not-a-folder" turn_open acme/widget; rc=$?
if [ "$rc" -eq 0 ]; then MWR_TURN_DIR="$WORKDIR/not-a-folder" turn_join 7 1000; rc=$?; fi
check_eq "#1515 a turn folder that cannot be made is a failure" "1" "$rc"
check "#1515 naming where" "$WORKDIR/not-a-folder" "$TURN_ERR"

# =================================================================================================
# 9. Whether a run is still in line for a pull request, asked from outside (claude-config#2403).
# =================================================================================================
# is-it-live asks this of a merge it has waited on past its window: lib/merge-in-line.sh answers
# "running" only on a ticket for that pull request whose run is alive by the same rule the line
# uses, "gone" otherwise, and it only reads, so asking can never pass anybody over.
INLINE="$DIR/lib/merge-in-line.sh"
reset
other_joins acme/widget 41 1000 "$LIVE" "$LIVE_START" >/dev/null
other_joins acme/widget 42 1000 "$DEAD" "Thu Jan  1 00:00:00 1970" >/dev/null
check_eq "#2403 a pull request whose run is alive in line is running" "running" "$(bash "$INLINE" acme/widget 41 2>&1)"
check_eq "#2403 asked in another case, the same line answers" "running" "$(bash "$INLINE" ACME/Widget 41 2>&1)"
check_eq "#2403 one whose run has gone is not" "gone" "$(bash "$INLINE" acme/widget 42 2>&1)"
check_eq "#2403 asking left that dead run's ticket where it was" "2" "$(ls "$MWR_TURN_DIR/acme/widget" | grep -cE '^[0-9]+$')"
check_eq "#2403 one with no ticket at all is not" "gone" "$(bash "$INLINE" acme/widget 43 2>&1)"
check_eq "#2403 nor is one in a repository with no line" "gone" "$(bash "$INLINE" acme/other 41 2>&1)"
out="$(bash "$INLINE" acme/widget 2>&1)"; rc=$?
check_eq "#2403 asked without a pull request it refuses rather than answering" "2" "$rc"
check "#2403 saying how it is used" "usage" "$out"
out="$(bash "$INLINE" acme/widget 4x1 2>&1)"; rc=$?
check_eq "#2403 a pull request that is not a number is refused too" "2" "$rc"
# A line that is there but cannot be read is no answer, never "gone": nothing was read to say so.
: > "$WORKDIR/line-is-a-file"
out="$(MWR_TURN_DIR="$WORKDIR/line-is-a-file" bash "$INLINE" acme/widget 41 2>&1)"; rc=$?
check_eq "#2403 a turn folder that is a file is a failure to ask" "2" "$rc"
check "#2403 naming where it looked" "$WORKDIR/line-is-a-file" "$out"
[[ "$out" != *gone* ]] && ok || bad "#2403 and it never says gone (said: $out)"
# #2466: a ticket that is there but cannot be read could be the asked pull request's, alive, so it
# is no answer either, never skipped on the way to "gone".
reset
other_joins acme/widget 41 1000 "$LIVE" "$LIVE_START" >/dev/null
locked=""
for t in "$MWR_TURN_DIR/acme/widget"/*; do
  case "${t##*/}" in ''|*[!0-9]*) ;; *) locked="${t##*/}"; break ;; esac
done
if [ -z "$locked" ]; then
  bad "#2466 the line should hold a ticket to make unreadable"
else
  chmod 000 "$MWR_TURN_DIR/acme/widget/$locked"
  if [ -r "$MWR_TURN_DIR/acme/widget/$locked" ]; then
    echo "SUITE-PART-UNMEASURED #2466 an unreadable ticket: this user can read a mode 000 file"
  else
    out="$(bash "$INLINE" acme/widget 41 2>&1)"; rc=$?
    check_eq "#2466 a ticket that cannot be read is a failure to ask" "2" "$rc"
    check "#2466 naming the ticket" "ticket $locked" "$out"
    [[ "$out" != *gone* ]] && ok || bad "#2466 and it never says gone (said: $out)"
  fi
  chmod 600 "$MWR_TURN_DIR/acme/widget/$locked"
fi

# =================================================================================================
# 10. The front of the line (claude-config#2474). On 2026-11-08 #2471 made the sync suite cheaper,
#     which the five pull requests ahead of it needed to pass CI, and it was moved forward by hand by
#     stopping all five helpers. A run joining with "first" goes ahead of every run still waiting,
#     never ahead of the one holding the turn, and runs joining with "first" keep their own order.
# =================================================================================================
# (other_joins_first, observer_looks and waiter_looks are defined beside other_joins, above.)
reset
other_joins acme/widget 9 900 "$LIVE" "$LIVE_START" >/dev/null   # ticket 1, holding the turn
observer_looks 900 >/dev/null
other_joins acme/widget 8 950 "$LIVE" "$LIVE_START" >/dev/null   # ticket 2, waiting
turn_open acme/widget; turn_join 7 1000 first; rc=$?
check_eq "#2474 a run takes a place at the front" "0" "$rc"
check_eq "#2474 with the next number, like any other" "3" "$TURN_TICKET"
turn_look 1000 3600
check_eq "#2474 it never takes the turn from the run holding it" "0" "$TURN_MINE"
check_eq "#2474 which is still #9's" "9" "$TURN_HEAD_PR"
check_eq "#2474 only the holder is ahead of it" "1" "$TURN_AHEAD"
check_eq "#2474 and it knows it went ahead of one run waiting" "1" "$TURN_OVERTOOK"
out="$(waiter_looks 2 1000 1010)"
check "#2474 the run it passed is told who went ahead of it" "#7 went to the front of the line" "$(sed -n 1p <<<"$out")"
check "#2474 and why" "--first" "$(sed -n 1p <<<"$out")"
check "#2474 the run it passed now has two ahead of it" "ahead[2]" "$(sed -n 1p <<<"$out")"
check_eq "#2474 and is told once, not at every look" "said[] ahead[2] head[9]" "$(sed -n 2p <<<"$out")"
# The holder leaves: the turn goes to the front of the line, not to the lowest number.
rm -f "$MWR_TURN_DIR/acme/widget/1" "$MWR_TURN_DIR/acme/widget/1.head"
turn_look 1100 3600
check_eq "#2474 once the holder leaves, the run at the front holds the turn" "1" "$TURN_MINE"
check "#2474 and the run it passed waits for it" "head[7]" "$(waiter_looks 2 1100)"
# Control: without "first", the same arrival waits behind both, as before.
reset
other_joins acme/widget 9 900 "$LIVE" "$LIVE_START" >/dev/null
observer_looks 900 >/dev/null
other_joins acme/widget 8 950 "$LIVE" "$LIVE_START" >/dev/null
turn_open acme/widget; turn_join 7 1000
turn_look 1000 3600
check_eq "#2474 control: a run joining without first has both ahead of it" "2" "$TURN_AHEAD"
check_eq "#2474 control: and went ahead of nobody" "0" "$TURN_OVERTOOK"
check "#2474 control: the waiter is told nothing about it" "said[] ahead[1]" "$(waiter_looks 2 1000)"

# Two at the front keep their order between themselves, both ahead of the run waiting.
reset
other_joins acme/widget 9 900 "$LIVE" "$LIVE_START" >/dev/null          # 1, holding
observer_looks 900 >/dev/null
other_joins acme/widget 8 950 "$LIVE" "$LIVE_START" >/dev/null          # 2, waiting
other_joins_first acme/widget 5 960 "$LIVE" "$LIVE_START" >/dev/null    # 3, at the front
turn_open acme/widget; turn_join 7 1000 first                            # 4, at the front after #5
turn_look 1000 3600
check_eq "#2474 the second run at the front has the holder and the first one ahead of it" "2" "$TURN_AHEAD"
check_eq "#2474 so the first run at the front keeps its place" "9" "$TURN_HEAD_PR"
check_not "#2474 and it is not told #5 went ahead of it, since #5 was there first" "#5 went to the front" "$TURN_SAID"
check "#2474 the run waiting is behind both" "ahead[3]" "$(waiter_looks 2 1000)"
rm -f "$MWR_TURN_DIR/acme/widget/1" "$MWR_TURN_DIR/acme/widget/1.head"
turn_look 1100 3600
check_eq "#2474 when the holder leaves, the earlier run at the front holds it" "5" "$TURN_HEAD_PR"
check_eq "#2474 not the later one" "0" "$TURN_MINE"

# A held turn is never taken by a run at the front, even one whose number is lower than the holder's.
reset
other_joins acme/widget 9 900 "$LIVE" "$LIVE_START" >/dev/null          # 1
other_joins_first acme/widget 5 905 "$LIVE" "$LIVE_START" >/dev/null    # 2, at the front, holds it
observer_looks 905 >/dev/null
turn_open acme/widget; turn_join 7 1000 first                            # 3
turn_look 1000 3600
check_eq "#2474 a run at the front waits for the run at the front that holds the turn" "5" "$TURN_HEAD_PR"
check_eq "#2474 and goes ahead of the waiting run, not the holder" "1" "$TURN_AHEAD"

# A run of a helper started before the front of line existed reads the line in number order, so a
# run at the front never goes ahead of its ticket (one with no "order 2" line): if it did, once the
# holder left, both would decide the turn was theirs and update or merge at once.
reset
other_joins acme/widget 9 900 "$LIVE" "$LIVE_START" >/dev/null          # 1, holding
observer_looks 900 >/dev/null
t2="$(other_joins acme/widget 8 950 "$LIVE" "$LIVE_START")"             # 2, an older helper's ticket
grep -v '^order ' "$MWR_TURN_DIR/acme/widget/$t2" > "$WORKDIR/old-ticket" && mv "$WORKDIR/old-ticket" "$MWR_TURN_DIR/acme/widget/$t2"
other_joins acme/widget 6 960 "$LIVE" "$LIVE_START" >/dev/null          # 3, a current helper's ticket
turn_open acme/widget; turn_join 7 1000 first                            # 4
turn_look 1000 3600
check_eq "#2474 a run at the front stays behind an older helper's ticket, passing only the current one" "2" "$TURN_AHEAD"
check_eq "#2474 so it went ahead of one run, not two" "1" "$TURN_OVERTOOK"
rm -f "$MWR_TURN_DIR/acme/widget/1" "$MWR_TURN_DIR/acme/widget/1.head"
turn_look 1100 3600
check_eq "#2474 when the holder leaves, the older helper's run holds the turn, as it believes it does" "8" "$TURN_HEAD_PR"
check_eq "#2474 and the run at the front does not" "0" "$TURN_MINE"
check "#2474 a ticket this version writes says it reads the front of the line" "order 2" "$(cat "$MWR_TURN_DIR/acme/widget/$TURN_TICKET")"

# Failure paths: an unknown way of joining is refused, never taken as "first" or as an ordinary place.
reset
turn_open acme/widget; turn_join 7 1000 frist; rc=$?
check_eq "#2474 an unknown way of joining is refused" "1" "$rc"
check "#2474 naming what it was given" "frist" "$TURN_ERR"
check_eq "#2474 and no place is taken" "" "$(ls "$MWR_TURN_DIR/acme/widget" 2>/dev/null | grep -E '^[0-9]+$')"
# A ticket whose front of line mark cannot be read is not honoured, and every run it would have
# passed says so, once.
reset
other_joins acme/widget 9 900 "$LIVE" "$LIVE_START" >/dev/null          # 1, holding
observer_looks 900 >/dev/null
turn_open acme/widget; turn_join 7 950                                   # 2, waiting
t3="$(other_joins acme/widget 5 960 "$LIVE" "$LIVE_START")"
printf 'first maybe\n' >> "$MWR_TURN_DIR/acme/widget/$t3"
turn_look 1000 3600
check_eq "#2474 an unreadable front of line mark does not put #5 ahead" "1" "$TURN_AHEAD"
check "#2474 it is said that the mark was ignored" "#5's place at the front of the line was ignored" "$TURN_SAID"
turn_look 1010 3600
check_eq "#2474 and said once, not at every look" "" "$TURN_SAID"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
