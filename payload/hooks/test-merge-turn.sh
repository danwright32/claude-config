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
# Its ticket going (its run finished) passes the turn on.
rm -f "$MWR_TURN_DIR/acme/widget/1" "$MWR_TURN_DIR/acme/widget/1.head"
turn_look 1600 3600
check_eq "#1515 once the holder leaves, the next in line holds it" "1" "$TURN_MINE"
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

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
