#!/usr/bin/env bash
# Tests for lib/merge-phase.sh (claude-config#1676): the phase each merge-when-ready.sh run publishes,
# local work or waiting on GitHub, which tools/load-window.sh reads so a helper only waiting on CI no
# longer keeps a deliberate load window from ever running (one window in 42 tries on 2026-10-24).
#
# What matters most is what a record says once its run has DIED or gone quiet (L409, L617): a record
# is believed only for a pid running now with the start time recorded, a "waiting" record only until
# the time it names, and anything else (no record, a garbled one, one it could not write) reads as
# busy, so a stale marker can only ever make a window wait, never let it overlap local work. Time is
# passed in as a number, so nothing here reads a clock or waits on one (L524, L290). A live run that
# is not this shell is pid 1, which always runs, with its real start time; a dead one is a pid no
# system issues.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(mktemp -d)"
trap 'chmod -R u+w "$WORKDIR" 2>/dev/null; rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1000}"; fi; }

if ! . "$DIR/lib/merge-turn.sh" 2>/dev/null || ! . "$DIR/lib/merge-phase.sh" 2>/dev/null; then
  bad "#1676 lib/merge-phase.sh is missing or does not load"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 1
fi

export MWR_PHASE_DIR="$WORKDIR/phases"
LIVE_START="$(ps -o lstart= -p 1 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//')"
DEAD=99999999
# The answer for a pid, as one word: waiting (believed, still in date) or busy.
verdict(){ if mp_waiting "$1" "$2"; then printf 'waiting'; else printf 'busy'; fi; }
# Another run's record: written as that run, in a subshell, so this shell's own pid is never used.
as_run(){   # $1 = pid, $2 = start time it claims, then mp_set's arguments
  ( TURN_PID="$1"; TURN_PID_START="$2"; shift 2; mp_set "$@" )
}

# =================================================================================================
# 1. A live run waiting on GitHub is believed, until the time its record names; one doing local work,
#    and one with no record at all, are busy.
# =================================================================================================
as_run 1 "$LIVE_START" waiting "Head 1111111: waiting, checks still running (1 of 3)." 1000 1300
check_eq "#1676 a live run waiting on GitHub is not busy" "waiting" "$(verdict 1 1000)"
mp_waiting 1 1000
check_eq "#1676 and says what it waits on" "Head 1111111: waiting, checks still running (1 of 3)." "$MP_WHAT"
check_eq "#1676 and since when" "1000" "$MP_SINCE"
check_eq "#1676 believed up to the time it names" "waiting" "$(verdict 1 1300)"
check_eq "#1676 and busy after it, as a run that stopped saying it waits" "busy" "$(verdict 1 1301)"
as_run 1 "$LIVE_START" local "asking block-red-merge.sh about the merge of #7" 1000 ""
check_eq "#1676 the same run doing local work is busy" "busy" "$(verdict 1 1000)"
rm -rf "$MWR_PHASE_DIR"
check_eq "#1676 a run with no record is busy, as every run was before #1676" "busy" "$(verdict 1 1000)"

# =================================================================================================
# 2. When the run has died: its record says nothing (L409). A dead pid, and a pid reused by another
#    process (another start time), are never believed, whatever their record says.
# =================================================================================================
as_run "$DEAD" "Thu Jan  1 00:00:00 1970" waiting "waiting for its turn" 1000 99999
check_eq "#1676 a record whose run has gone is not believed" "busy" "$(verdict "$DEAD" 1000)"
as_run 1 "Thu Jan  1 00:00:00 1970" waiting "waiting for its turn" 1000 99999
check_eq "#1676 a record whose pid now runs with another start time is not believed" "busy" "$(verdict 1 1000)"
# A record that names another pid than the file it is in (a copy, a hand edit) is not believed either.
as_run 1 "$LIVE_START" waiting "waiting for its turn" 1000 99999
sed -i.bak 's/^pid 1$/pid 2/' "$MWR_PHASE_DIR/1"; rm -f "$MWR_PHASE_DIR/1.bak"
check_eq "#1676 a record naming another pid is not believed" "busy" "$(verdict 1 1000)"
printf 'garbage\n' > "$MWR_PHASE_DIR/1"
check_eq "#1676 a record that cannot be read is busy" "busy" "$(verdict 1 1000)"
as_run 1 "$LIVE_START" waiting "waiting for its turn" 1000 "soon"
check_eq "#1676 a waiting record with no time it holds until is busy" "busy" "$(verdict 1 1000)"

# =================================================================================================
# 3. Written whole or not at all: a record that could not be written leaves none behind to believe,
#    and the writer says so by its exit.
# =================================================================================================
rm -rf "$MWR_PHASE_DIR"
as_run 1 "$LIVE_START" waiting "waiting for its turn" 1000 1300
mkdir -p "$WORKDIR/blocked"; : > "$WORKDIR/blocked/phases"
MWR_PHASE_DIR="$WORKDIR/blocked/phases" as_run 1 "$LIVE_START" waiting "waiting for its turn" 1000 1300; rc=$?
check_eq "#1676 a record that cannot be written fails" "1" "$rc"
check_eq "#1676 and nothing is believed from where it could not write" "busy" "$(MWR_PHASE_DIR="$WORKDIR/blocked/phases" verdict 1 1000)"
# A write of local work that fails takes away the waiting record it would have replaced, so the run
# reads as busy rather than as still waiting (L617).
chmod a-w "$MWR_PHASE_DIR"
as_run 1 "$LIVE_START" local "asking the gates" 1000 ""; rc=$?
chmod u+w "$MWR_PHASE_DIR"
if [ "$rc" -ne 0 ] && [ -e "$MWR_PHASE_DIR/1" ]; then
  # The folder refused both the write and the removal: the waiting record stands, and its own time
  # bounds the lie to the wait it was written for.
  check_eq "#1676 a waiting record nothing could replace lapses at the time it names" "busy" "$(verdict 1 1301)"
else
  check_eq "#1676 a failed write of local work leaves no waiting record" "busy" "$(verdict 1 1000)"
fi

# =================================================================================================
# 4. A run clears its own record, and only its own; one whose run has gone is swept by the next.
# =================================================================================================
rm -rf "$MWR_PHASE_DIR"
as_run 1 "$LIVE_START" waiting "waiting for its turn" 1000 1300
as_run "$DEAD" "Thu Jan  1 00:00:00 1970" local "asking the gates" 1000 ""
( TURN_PID=$$; TURN_PID_START=""; mp_set waiting "on checks" 1000 1300 && mp_clear )
check_eq "#1676 a run's clear removes its own record" "no" "$( [ -e "$MWR_PHASE_DIR/$$" ] && echo yes || echo no)"
check_eq "#1676 and leaves a live run's" "yes" "$( [ -e "$MWR_PHASE_DIR/1" ] && echo yes || echo no)"
check_eq "#1676 while a record whose run has gone is swept away by the next write" "no" "$( [ -e "$MWR_PHASE_DIR/$DEAD" ] && echo yes || echo no)"
# This shell's own record, written with no start time given, carries the start ps reports for it.
( TURN_PID=$$; TURN_PID_START=""; mp_set waiting "on checks" 1000 1300 )
check_eq "#1676 a record written with no start time given carries the run's own" "waiting" "$(verdict $$ 1000)"
rm -f "$MWR_PHASE_DIR/$$"

# =================================================================================================
# 5. A lessons review publishes its own phase (claude-config#1730). One started by merge-when-ready.sh
#    keeps running after the helper exits (a helper that stops on a red check), and the load window,
#    which saw it only through the helper, could not see it at all. So the review writes a "review"
#    record for its own pid, and mp_reviews_busy names every one believed: the pid running now with
#    the start time recorded, and the until (its deadline plus slack) not passed. A review that
#    crashed names a pid no longer running, so it says nothing (L409, L617), and a review record is
#    never read as a helper waiting on GitHub.
# =================================================================================================
rm -rf "$MWR_PHASE_DIR"
reviews(){ mp_reviews_busy "$1" | awk -F '\t' '{ print $1 }' | sort | tr '\n' ' ' | sed 's/ $//'; }
as_run 1 "$LIVE_START" review "the lessons review of acme/widget feat/x at 1111111" 1000 1700
check_eq "#1730 a running review is named busy" "1" "$(reviews 1000)"
check_eq "#1730 with what it is" "1	the lessons review of acme/widget feat/x at 1111111" "$(mp_reviews_busy 1000)"
check_eq "#1730 up to the time its record names" "1" "$(reviews 1700)"
check_eq "#1730 and not after it, a review past its own deadline" "" "$(reviews 1701)"
check_eq "#1730 a review record is never a helper waiting on GitHub" "busy" "$(verdict 1 1000)"
as_run "$DEAD" "Thu Jan  1 00:00:00 1970" review "the lessons review of acme/widget feat/y at 2222222" 1000 1700
check_eq "#1730 a review whose process has gone, a crash, is not named" "1" "$(reviews 1000)"
as_run 1 "Thu Jan  1 00:00:00 1970" review "the lessons review of acme/widget feat/z at 3333333" 1000 1700
check_eq "#1730 nor one whose pid now runs something else" "" "$(reviews 1000)"
as_run 1 "$LIVE_START" local "asking block-red-merge.sh about the merge of #7" 1000 ""
check_eq "#1730 a helper's own local record is not a review" "" "$(reviews 1000)"
printf 'garbage\n' > "$MWR_PHASE_DIR/1"
check_eq "#1730 nor is a record that cannot be read" "" "$(reviews 1000)"
as_run 1 "$LIVE_START" review "the lessons review of acme/widget feat/x at 1111111" 1000 ""
check_eq "#1730 nor a review record with no until, which could otherwise never lapse" "" "$(reviews 1000)"
rm -rf "$MWR_PHASE_DIR"
check_eq "#1730 and with no records at all, nothing" "" "$(reviews 1000)"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
