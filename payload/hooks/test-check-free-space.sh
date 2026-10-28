#!/usr/bin/env bash
# Tests for check-free-space.sh and free-space-nudge.sh (claude-config#363).
#
# On 2026-09-10 the boot volume hit zero free space, and the first sign of it inside Claude Code
# was an unrelated hook failing with "cannot create temp file for here document", followed by every
# Bash call failing with ENOSPC before it could run. A full disk is the one state where the tool
# that would diagnose it cannot run, so the warning has to arrive while there is still room to act,
# and the diagnosis has to be written down in advance.
#
# Two things are measured here. That the check answers each of its states apart from the others,
# including the one where it could not measure at all, because a check that reports "fine" when it
# read nothing is indistinguishable from a healthy disk (L98, L11). And that the rate half refuses
# to speak from readings too close together to mean anything, because a rate taken over seconds of
# a machine's ordinary churn would fire constantly and teach everyone to skip the warning (L36).
#
# Nothing here runs df or reads the real clock: every reading and every instant is supplied, so the
# suite measures the code rather than the machine it happens to run on (L2, L504).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Every wait on a condition gives up at the one ceiling only a hang reaches (claude-config#1620).
. "$DIR/lib/hang-wait.sh" || { echo "FAIL: lib/hang-wait.sh is missing"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
CHECK="$DIR/check-free-space.sh"
NUDGE="$DIR/free-space-nudge.sh"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.freespace.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-check-free-space: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# The symbol cache the warning names is a real folder on this Mac, so every run points the check at
# a folder of the suite's own instead, and none reads the machine (L2, L284). The default is one
# that does not exist; the cases about the folder make one and name it.
export FREE_SPACE_SYMBOL_CACHE="$TMPROOT/no-symbol-cache-here"
# The same for Xcode's DerivedData, which the nudge sizes when it speaks (claude-config#1369): a
# folder of the suite's own that does not exist, unless a case makes one and names it.
export XCODE_DERIVED_DATA_ROOT="$TMPROOT/no-derived-data-here"
# The automatic sweep the warning starts keeps its lock and its record in a folder of the suite's
# own, never ~/.claude/state, and asks a process list of the suite's own (L2).
export DERIVED_DATA_SWEEP_STATE_DIR="$TMPROOT/no-sweep-state-here"
QUIET_PS="$TMPROOT/quiet-ps"
printf '#!/bin/sh\necho "  77 /usr/bin/login -f someone"\n' > "$QUIET_PS"; chmod +x "$QUIET_PS"
export DERIVED_DATA_PS="$QUIET_PS"
# Swap and the memory holders (claude-config#1770) are read from the machine by default, so every
# run hands the check a swap reader of the suite's own that reports none, a disk size of its own, and
# a top that records being called and prints nothing. No case here runs the real sysctl or top; the
# cases about swap swap in readers of their own (L2).
SWAP_NONE="$TMPROOT/swap-none"
printf '#!/bin/sh\necho "vm.swapusage: total = 0.00M  used = 0.00M  free = 0.00M  (encrypted)"\n' > "$SWAP_NONE"; chmod +x "$SWAP_NONE"
export FREE_SPACE_SWAP_CMD="$SWAP_NONE"
TOP_CALLED="$TMPROOT/top-called"
TOP_SILENT="$TMPROOT/top-silent"
printf '#!/bin/sh\n: >> "%s"\n' "$TOP_CALLED" > "$TOP_SILENT"; chmod +x "$TOP_SILENT"
export FREE_SPACE_TOP_CMD="$TOP_SILENT"
export FREE_SPACE_DISK_BYTES=$((926 * 1024 * 1024 * 1024))
# The disk-clean scan record a low or falling warning reads (claude-config#1809) is per Mac, under
# ~/.claude/state, so every run points the check at one of the suite's own that does not exist,
# unless a case writes one and names it (L2).
export FREE_SPACE_SCAN_RECORD="$TMPROOT/no-scan-here/last-scan.json"

GB=$((1024 * 1024 * 1024))
T0=1757500000            # a fixed instant, so every span below is arithmetic rather than a race

# One reading, at a stated instant, against a state directory of its own unless one is named. Every
# seam the script honours is set here; none is left to the machine (L284).
#
# The message goes to a FILE and the caller reads $PROBE_MSG afterwards, rather than the obvious
# `probe ...; msg="$PROBE_MSG"`. A command substitution runs in a subshell, so an exit code this function
# assigns to a variable inside one never reaches the caller: every rc assertion then read whatever
# the previous direct call had left behind, and four of them passed against a check that had not
# run yet. Caught only because those four disagreed with the messages printed beside them.
PROBE_MSG=""
PROBE_RC=0
probe(){   # probe <free bytes> <epoch> [state dir] -> sets PROBE_RC and PROBE_MSG
  local state="${3:-$TMPROOT/state-$RANDOM}" out="$TMPROOT/probe-out"
  mkdir -p "$state"
  FREE_SPACE_BYTES="$1" FREE_SPACE_NOW="$2" FREE_SPACE_STATE_DIR="$state" \
    FREE_SPACE_PATH=/fixture bash "$CHECK" > "$out" 2>&1
  PROBE_RC=$?
  PROBE_MSG="$(cat "$out" 2>/dev/null || true)"
  return 0
}
rprobe(){   # rprobe <free bytes> <epoch> <state dir> -> sets PROBE_RC and PROBE_MSG, with --report
  local out="$TMPROOT/rprobe-out"
  mkdir -p "$3"
  FREE_SPACE_BYTES="$1" FREE_SPACE_NOW="$2" FREE_SPACE_STATE_DIR="$3" \
    FREE_SPACE_PATH=/fixture bash "$CHECK" --report > "$out" 2>&1
  PROBE_RC=$?
  PROBE_MSG="$(cat "$out" 2>/dev/null || true)"
}

# ---- a disk with room, and a check that has to say so by SAYING NOTHING and exiting 0 ----
S_FINE="$TMPROOT/state-fine"; mkdir -p "$S_FINE"
probe "$((200 * GB))" "$T0" "$S_FINE"
check "a disk with room exits 0" "$([ "$PROBE_RC" -eq 0 ] && echo ok || echo "exit $PROBE_RC")"

# ---- under the floor ----
S_LOW="$TMPROOT/state-low"; mkdir -p "$S_LOW"
probe "$((7 * GB))" "$T0" "$S_LOW"; low_msg="$PROBE_MSG"
check "under the floor exits 3" "$([ "$PROBE_RC" -eq 3 ] && echo ok || echo "exit $PROBE_RC")"
check "under the floor says how much is left, in a unit a person reads" \
  "$(grep -q '7 GB free on' <<< "$low_msg" && echo ok || echo "said: $low_msg")"
check "under the floor names the volume it measured" \
  "$(grep -q '/fixture' <<< "$low_msg" && echo ok || echo "said: $low_msg")"
# The whole point of the issue: the warning must not guess at what is eating the disk.
check "under the floor names no cause, because nothing here measured one" \
  "$(grep -q 'GB free on' <<< "$low_msg" && ! grep -qiE 'synology|backblaze|icloud|backup is|caused by' <<< "$low_msg" && echo ok || echo "said: $low_msg")"

# ---- could not measure, which is its own answer and never 'fine' ----
S_BLIND="$TMPROOT/state-blind"; mkdir -p "$S_BLIND"
blind_msg="$(FREE_SPACE_BYTES=nonsense FREE_SPACE_NOW="$T0" FREE_SPACE_STATE_DIR="$S_BLIND" \
  FREE_SPACE_PATH=/fixture bash "$CHECK" 2>&1)"; blind_rc=$?
check "a reading that cannot be parsed exits 2, not 0" \
  "$([ "$blind_rc" -eq 2 ] && echo ok || echo "exit $blind_rc")"
check "and says it could not measure, rather than reporting a number it does not have" \
  "$(grep -qi 'could not' <<< "$blind_msg" && echo ok || echo "said: $blind_msg")"

# ---- a SETTING that is not a number is refused, not compared against ----
# The reading is validated, and the four numbers that judge it were not. A floor of "abc" makes
# every arithmetic test error, which bash reads as false, so the check falls through to "there is
# room" on a disk with 1 GB left: silently landing on the permissive side is exactly the failure
# L50 describes, and nothing anywhere would have said so.
for bad_setting in FREE_SPACE_FLOOR_GB FREE_SPACE_HORIZON_HOURS FREE_SPACE_MIN_SPAN_MIN FREE_SPACE_WINDOW_HOURS FREE_SPACE_RECOVERY_GB \
                   FREE_SPACE_PERSIST_MIN FREE_SPACE_SWAP_SHARE_PCT FREE_SPACE_TOP_SECONDS; do
  S_BAD="$TMPROOT/state-bad-$bad_setting"; mkdir -p "$S_BAD"
  bad_msg="$(env "$bad_setting=abc" FREE_SPACE_BYTES="$((1 * GB))" FREE_SPACE_NOW="$T0" \
    FREE_SPACE_STATE_DIR="$S_BAD" FREE_SPACE_PATH=/fixture bash "$CHECK" 2>&1)"; bad_rc=$?
  check "$bad_setting set to something that is not a number is refused, never compared against" \
    "$([ "$bad_rc" -eq 2 ] && grep -qi 'could not' <<< "$bad_msg" && echo ok || echo "exit $bad_rc, said: $bad_msg")"
  check "and the refusal names which setting it was, so it can be fixed" \
    "$(grep -q "$bad_setting" <<< "$bad_msg" && echo ok || echo "said: $bad_msg")"
done

# ---- a SAWTOOTH IS NOT A FALL (claude-config#436) ----
# The readings between the ends were being kept and then ignored: the rate came from the oldest and
# the newest alone, so any two points could set the verdict however the disk behaved in between.
#
# This is the real shape, measured on 2026-09-18: an Xcode test build takes tens of GB and gives
# every one of them back when it finishes. Across a morning that draws a sawtooth, and a sawtooth's
# endpoints can be given any slope you like by choosing when to look. Three notices went out that
# day, at 23, 135 and 163 GB an hour, while the disk sat comfortably above the floor and the last
# reading before each was HIGHER than an earlier one.
#
# A rate is a claim about a trend, and a series that recovers has no trend to state. So the answer
# is the one this file already uses for a span too short to mean anything: say how much is left,
# and say nothing about where it is going (L36, L656, L216).
S_SAW="$TMPROOT/state-sawtooth"; mkdir -p "$S_SAW"
saw() {
  FREE_SPACE_BYTES="$1" FREE_SPACE_NOW="$2" FREE_SPACE_STATE_DIR="$S_SAW" \
    FREE_SPACE_PATH=/fixture bash "$CHECK" 2>&1
}
saw "$((150 * GB))" "$((T0 - 3600))"  > /dev/null
saw "$((35 * GB))"  "$((T0 - 2400))"  > /dev/null
saw "$((150 * GB))" "$((T0 - 1200))"  > /dev/null
saw_msg="$(saw "$((86 * GB))" "$T0")"; saw_rc=$?
check "a disk that recovered inside the window states no rate" \
  "$(grep -qi 'per hour' <<< "$saw_msg" && echo "said: $saw_msg" || echo ok)"
check "and does not call it falling fast, because there is no trend to be fast" \
  "$([ "$saw_rc" -ne 4 ] && echo ok || echo "exit $saw_rc, said: $saw_msg")"

# THE POSITIVE CONTROL, and it has to be here or the case above is satisfied by a check that simply
# stopped reporting rates at all (L159). Same span, same endpoints, no recovery in between.
S_MONO="$TMPROOT/state-monotonic"; mkdir -p "$S_MONO"
mono() {
  FREE_SPACE_BYTES="$1" FREE_SPACE_NOW="$2" FREE_SPACE_STATE_DIR="$S_MONO" \
    FREE_SPACE_PATH=/fixture bash "$CHECK" 2>&1
}
mono "$((150 * GB))" "$((T0 - 3600))" > /dev/null
mono "$((128 * GB))" "$((T0 - 2400))" > /dev/null
mono "$((107 * GB))" "$((T0 - 1200))" > /dev/null
mono_msg="$(mono "$((86 * GB))" "$T0")"; mono_rc=$?
check "a fall that never recovered still states its rate" \
  "$(grep -qi 'per hour' <<< "$mono_msg" && echo ok || echo "said: $mono_msg")"
check "and still fires when zero is inside the horizon" \
  "$([ "$mono_rc" -eq 4 ] && echo ok || echo "exit $mono_rc, said: $mono_msg")"

# A RECOVERY MUST NOT SILENCE THE WARNING FOR THE REST OF THE WINDOW. The first version of this
# fix refused any rate once the series had ever gone back up, which is exactly the moment a build
# finishes. A genuine fill that began afterwards, a backup say, then went unreported for up to the
# whole six hour window, which is the failure the warning exists to prevent (L695: decide from
# recent samples, never an aggregate that cannot stand down). So the trend is measured from the
# readings SINCE the last recovery, and here that trend is real, sustained and fast.
S_AFTER="$TMPROOT/state-fall-after-build"; mkdir -p "$S_AFTER"
after() {
  FREE_SPACE_BYTES="$1" FREE_SPACE_NOW="$2" FREE_SPACE_STATE_DIR="$S_AFTER" \
    FREE_SPACE_PATH=/fixture bash "$CHECK" 2>&1
}
after "$((150 * GB))" "$((T0 - 5400))" > /dev/null
after "$((35 * GB))"  "$((T0 - 4800))" > /dev/null
after "$((150 * GB))" "$((T0 - 4200))" > /dev/null
after "$((120 * GB))" "$((T0 - 2800))" > /dev/null
after "$((90 * GB))"  "$((T0 - 1400))" > /dev/null
after_msg="$(after "$((60 * GB))" "$T0")"; after_rc=$?
check "a real fall that starts after a build recovered still states its rate" \
  "$(grep -qi 'per hour' <<< "$after_msg" && echo ok || echo "said: $after_msg")"
check "and still fires, because zero is inside the horizon" \
  "$([ "$after_rc" -eq 4 ] && echo ok || echo "exit $after_rc, said: $after_msg")"
# From the recovery at T0 - 4200 to the most free space seen in the last 30 minutes, the 90 GB at
# T0 - 1400: 46 minutes. Measured from before the recovery (T0 - 5400) it would be 66, which reads
# as 1 hour, so the figure tells the two apart (claude-config#1754). Fixture times, not measured.
check "and measures from the recovery, not from before it" \
  "$(grep -qi 'over 46 minute(s)' <<< "$after_msg" && echo ok || echo "said: $after_msg")"

# A RECOVERY OF A FEW BYTES IS NOISE, NOT A RECOVERY. Every write and delete on a live machine
# jitters the reading, so a rule that refused on any increase at all would refuse always, which is
# the same as deleting the feature (L104: check what it must PRESERVE, not only what it must catch).
S_JIT="$TMPROOT/state-jitter"; mkdir -p "$S_JIT"
jit() {
  FREE_SPACE_BYTES="$1" FREE_SPACE_NOW="$2" FREE_SPACE_STATE_DIR="$S_JIT" \
    FREE_SPACE_PATH=/fixture bash "$CHECK" 2>&1
}
jit "$((150 * GB))" "$((T0 - 3600))" > /dev/null
jit "$((128 * GB))" "$((T0 - 2400))" > /dev/null
jit "$(((107 * GB) + 200 * 1024 * 1024))" "$((T0 - 1200))" > /dev/null
jit_msg="$(jit "$((86 * GB))" "$T0")"
check "a fall that jittered up by a fraction of a GB still states its rate" \
  "$(grep -qi 'per hour' <<< "$jit_msg" && echo ok || echo "said: $jit_msg")"

# ---- A BURST THAT COMES BACK IS NOT A FALL (claude-config#1754) ----
# Measured on 2026-10-26 on the work MacBook: Claude sessions' pre push checks (lint, a production
# build and the test suite in a temporary tree, plus a local database stack) each took 1.4 to 4.4 GB
# and gave most of it back minutes later: 36.0 GB free at 11:00 ET, 36.2 GB at 11:27 after two
# bursts. The warning said "17 GB per hour ... zero in about 2 hour(s)", then "7 GB per hour ... 4
# hour(s)", while the space was coming back. The recovery rule above only helps AFTER a burst has
# given its space back; while one is still in progress the oldest reading and the dip made a slope.
#
# The series below is that morning's shape, a reading every few minutes, in tenths of a GB: a level
# 36 GB for half an hour, a 4.4 GB burst that holds for fifteen minutes, back up, a second smaller
# burst, back up. At no reading may the check project zero or state a rate.
S_BURST="$TMPROOT/state-burst"; mkdir -p "$S_BURST"
burst_fired=""
for _reading in -30:360 -20:360 -10:361 0:360 5:335 10:316 15:314 20:359 24:330 27:362; do
  probe "$(( ${_reading#*:} * GB / 10 ))" "$((T0 + ${_reading%%:*} * 60))" "$S_BURST"
  if [ "$PROBE_RC" -eq 4 ] || grep -qi 'per hour' <<< "$PROBE_MSG"; then
    burst_fired="$burst_fired [minute ${_reading%%:*}: exit $PROBE_RC, said: $PROBE_MSG]"
  fi
done
check "a push check's burst that comes back never projects zero, at any reading in the series" \
  "$([ -z "$burst_fired" ] && echo ok || echo "$burst_fired")"

# The same burst seen from a shorter history, which is how the 17 GB an hour of 2026-10-26 was
# reached (the times below are the fixture's, not measured): the first
# reading in the window is 25 minutes before the dip's bottom. A fall seen for less time than a push
# check lasts is not stated as a rate, and --report says that is why (L540).
S_BURST2="$TMPROOT/state-burst-short"
rprobe "$((36 * GB))" "$((T0 - 1500))" "$S_BURST2"
rprobe "$((316 * GB / 10))" "$T0" "$S_BURST2"
check "a drop seen for less than the persistence window states no rate, and says it has not lasted" \
  "$([ "$PROBE_RC" -eq 0 ] && ! grep -qi 'per hour' <<< "$PROBE_MSG" && grep -q 'lasted 30 minutes' <<< "$PROBE_MSG" && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"

# THE CONTROL: a real, sustained fall from the same starting point still projects (L159, L248). Half
# a GB every five minutes for an hour, 6 GB an hour, which reaches zero inside the six hour horizon.
S_SUSTAIN="$TMPROOT/state-sustained"; mkdir -p "$S_SUSTAIN"
_m=-60
while [ "$_m" -lt 0 ]; do
  probe "$(( (300 - _m) * GB / 10 ))" "$((T0 + _m * 60))" "$S_SUSTAIN"
  _m=$((_m + 5))
done
probe "$((30 * GB))" "$T0" "$S_SUSTAIN"; sustain_msg="$PROBE_MSG"
check "a sustained fall from the same level still fires" \
  "$([ "$PROBE_RC" -eq 4 ] && echo ok || echo "exit $PROBE_RC, said: $sustain_msg")"
check "and states the rate it measured" \
  "$(grep -q 'about 6 GB per hour' <<< "$sustain_msg" && echo ok || echo "said: $sustain_msg")"
# A persistence window of 0 is the old behaviour, a rate from the newest reading, so the burst that
# the default refuses is projected again: proof the window is what refuses it (L1001).
S_BURST0="$TMPROOT/state-burst-off"; mkdir -p "$S_BURST0"
for _reading in -30:360 -20:360 -10:361 0:360 5:335 10:316; do
  FREE_SPACE_PERSIST_MIN=0 probe "$(( ${_reading#*:} * GB / 10 ))" "$((T0 + ${_reading%%:*} * 60))" "$S_BURST0"
done
check "with the persistence window set to 0 the same burst is projected, so the window is what refuses it" \
  "$([ "$PROBE_RC" -eq 4 ] && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"

# ---- falling fast, while still above the floor ----
# 240 GB now, 300 GB three hours ago: 20 GB an hour, so zero is twelve hours out. That is outside
# the six hour horizon, so it must NOT fire: a warning that fires on any fall at all is the noise
# this is trying to avoid.
S_SLOW="$TMPROOT/state-slow"; mkdir -p "$S_SLOW"
probe "$((300 * GB))" "$((T0 - 10800))" "$S_SLOW"
probe "$((240 * GB))" "$T0" "$S_SLOW"; slow_msg="$PROBE_MSG"
check "a fall that does not reach zero inside the horizon stays quiet" \
  "$([ "$PROBE_RC" -eq 0 ] && echo ok || echo "exit $PROBE_RC, said: $slow_msg")"

# 60 GB now, 300 GB three hours ago: 80 GB an hour, so zero is 45 minutes out. Every number in
# this section is set by the fixture beside it and not measured from anything.
S_FAST="$TMPROOT/state-fast"; mkdir -p "$S_FAST"
probe "$((300 * GB))" "$((T0 - 10800))" "$S_FAST"
probe "$((60 * GB))" "$T0" "$S_FAST"; fast_msg="$PROBE_MSG"
check "a fall that reaches zero inside the horizon exits 4" \
  "$([ "$PROBE_RC" -eq 4 ] && echo ok || echo "exit $PROBE_RC, said: $fast_msg")"
check "and reports the RATE it measured, not just the number left" \
  "$(grep -qi 'per hour' <<< "$fast_msg" && echo ok || echo "said: $fast_msg")"
# A rate is only a measurement if the reader can tell what it was measured over (L11, L316).
check "and says over how long it measured that rate" \
  "$(grep -qiE 'over .*(hour|minute)' <<< "$fast_msg" && echo ok || echo "said: $fast_msg")"

# ---- two readings too close together are not a rate ----
# The same 240 GB fall, over four minutes instead of three hours. Extrapolated it is a catastrophe;
# measured, it is one prompt following another while something wrote a file. Refusing here is what
# keeps the warning worth reading.
S_TWITCH="$TMPROOT/state-twitch"; mkdir -p "$S_TWITCH"
probe "$((300 * GB))" "$((T0 - 240))" "$S_TWITCH"
probe "$((60 * GB))" "$T0" "$S_TWITCH"; twitch_msg="$PROBE_MSG"
check "a fall measured over minutes is not reported as a rate" \
  "$([ "$PROBE_RC" -eq 0 ] && echo ok || echo "exit $PROBE_RC, said: $twitch_msg")"

# ---- a disk both low AND falling fast reports the floor, and still carries the rate ----
S_BOTH="$TMPROOT/state-both"; mkdir -p "$S_BOTH"
probe "$((100 * GB))" "$((T0 - 10800))" "$S_BOTH"
probe "$((5 * GB))" "$T0" "$S_BOTH"; both_msg="$PROBE_MSG"
check "a disk that is low and falling reports the more urgent of the two" \
  "$([ "$PROBE_RC" -eq 3 ] && echo ok || echo "exit $PROBE_RC, said: $both_msg")"
check "and still carries the rate, so the reader knows how long they have" \
  "$(grep -qi 'per hour' <<< "$both_msg" && echo ok || echo "said: $both_msg")"

# ---- space going back UP is not a warning ----
S_UP="$TMPROOT/state-up"; mkdir -p "$S_UP"
probe "$((100 * GB))" "$((T0 - 10800))" "$S_UP"
probe "$((250 * GB))" "$T0" "$S_UP"; up_msg="$PROBE_MSG"
check "space being freed is not reported as a fall" \
  "$([ "$PROBE_RC" -eq 0 ] && echo ok || echo "exit $PROBE_RC, said: $up_msg")"

# ---- readings older than the window are not used ----
# 300 GB two days ago and 240 GB now is a fall of 60 GB, but across a window nothing here claims to
# describe. The old reading is pruned, which leaves one reading and therefore no rate at all.
S_OLD="$TMPROOT/state-old"; mkdir -p "$S_OLD"
probe "$((300 * GB))" "$((T0 - 172800))" "$S_OLD"
probe "$((10 * GB))" "$T0" "$S_OLD"; old_msg="$PROBE_MSG"
check "a reading from outside the window is not used as the other end of a rate" \
  "$(grep -q 'GB free on' <<< "$old_msg" && ! grep -qi 'per hour' <<< "$old_msg" && echo ok || echo "said: $old_msg")"
check "and the floor is still reported from the reading it does have" \
  "$([ "$PROBE_RC" -eq 3 ] && echo ok || echo "exit $PROBE_RC, said: $old_msg")"

# ---- the state file does not grow without bound ----
S_MANY="$TMPROOT/state-many"; mkdir -p "$S_MANY"
i=0
while [ "$i" -lt 60 ]; do
  probe "$((200 * GB))" "$((T0 - 172800 + i * 60))" "$S_MANY"
  i=$((i + 1))
done
probe "$((200 * GB))" "$T0" "$S_MANY"
# The readings file by name: the daily swap record beside it is bounded by a case of its own.
many_lines="$(grep -c . "$S_MANY/_fixture" 2>/dev/null || true)"
check "readings outside the window are pruned rather than accumulating for ever" \
  "$([ "${many_lines:-0}" -ge 1 ] && [ "${many_lines:-999}" -le 5 ] && echo ok || echo "$many_lines line(s) kept")"

# ---- the check is what takes the reading, so running it records one ----
S_REC="$TMPROOT/state-rec"; mkdir -p "$S_REC"
probe "$((200 * GB))" "$T0" "$S_REC"
rec_lines="$(cat "$S_REC"/* 2>/dev/null | grep -c . || true)"
check "a run records the reading it took, so the next run has something to compare against" \
  "$([ "${rec_lines:-0}" -ge 1 ] && echo ok || echo "$rec_lines line(s) recorded")"

# ---- the reading itself, which every check above deliberately supplies rather than takes ----
# Every scenario above hands the check a number, so none of them exercises the one line that turns
# a real filesystem into one (L3, L535: the branch that ships is the branch nothing ran). This does
# run df, against `/`, which exists on this Mac and on every Linux runner, and it is still not a
# test about how full this machine happens to be: with a floor of 0 nothing can be under it, and
# with an absurd floor everything is. What is actually asserted is that the parse produced a
# number at all, in the unit it claims.
S_DF="$TMPROOT/state-df"; mkdir -p "$S_DF"
df_ok="$(FREE_SPACE_NOW="$T0" FREE_SPACE_STATE_DIR="$S_DF" FREE_SPACE_PATH=/ FREE_SPACE_FLOOR_GB=0 \
  bash "$CHECK" 2>&1)"; df_ok_rc=$?
check "a real df reading parses, and nothing is under a floor of zero" \
  "$([ "$df_ok_rc" -eq 0 ] && [ -z "$df_ok" ] && echo ok || echo "exit $df_ok_rc, said: $df_ok")"
S_DF2="$TMPROOT/state-df2"; mkdir -p "$S_DF2"
df_low="$(FREE_SPACE_NOW="$T0" FREE_SPACE_STATE_DIR="$S_DF2" FREE_SPACE_PATH=/ \
  FREE_SPACE_FLOOR_GB=99999999 bash "$CHECK" 2>&1)"; df_low_rc=$?
check "and the same reading is reported against a floor nothing can clear" \
  "$([ "$df_low_rc" -eq 3 ] && echo ok || echo "exit $df_low_rc, said: $df_low")"
# The positive control on the two above: a floor test passes whatever df said, including nothing,
# so this is what actually proves a NUMBER came out of the parse (L171, L98).
check "and that reading really is a number of GB, which is what proves df was parsed" \
  "$(grep -qE '^claude-sync: only [0-9]+ GB free on /,' <<< "$df_low" && echo ok || echo "said: $df_low")"

# ---- --report: the disk-full skill's rate step reads this, rather than measuring again (#683) ----
# The skill's step 2 used to compute a rate itself, with awk strftime (macOS awk has no such
# function, so it failed on the Mac it was written for) and a five minute foreground sleep (which
# the Bash tool refuses). This check already measures the rate, with refusals that keep a twitch
# from reading as a trend, so the skill asks it. But the quiet default prints NOTHING on a healthy
# disk, which is right for a warning on every prompt and useless to somebody triaging: so --report
# always says how much is left, and either the rate or exactly why there is none (L11, L540).
# The exit codes are the same four in both modes, because callers judge by those (L184).
# (rprobe, the --report form of probe, is defined beside probe at the top.)

# The quiet default stays quiet: the nudge relies on exit 0 saying nothing (claude-config#363).
S_QUIET="$TMPROOT/state-quiet"; mkdir -p "$S_QUIET"
probe "$((200 * GB))" "$T0" "$S_QUIET"
check "without --report a disk with room still prints nothing" \
  "$([ "$PROBE_RC" -eq 0 ] && [ -z "$PROBE_MSG" ] && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"

# First reading in the window: room, no rate, and the reason is that there is nothing to compare.
rprobe "$((200 * GB))" "$T0" "$TMPROOT/state-r-first"
check "--report on a disk with room exits 0, the same answer as the quiet mode" \
  "$([ "$PROBE_RC" -eq 0 ] && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"
check "--report says how much is left even when there is room" \
  "$(grep -q '^claude-sync: 200 GB free on /fixture' <<< "$PROBE_MSG" && echo ok || echo "said: $PROBE_MSG")"
check "--report on a first reading states no rate, and says it is the first reading" \
  "$(! grep -qi 'per hour' <<< "$PROBE_MSG" && grep -qi 'first reading' <<< "$PROBE_MSG" && echo ok || echo "said: $PROBE_MSG")"

# A slow fall over three hours: exit 0 (zero is outside the horizon) and the quiet mode says
# nothing, which is exactly the case somebody triaging needs the number for.
S_RSLOW="$TMPROOT/state-r-slow"
rprobe "$((300 * GB))" "$((T0 - 10800))" "$S_RSLOW"
rprobe "$((240 * GB))" "$T0" "$S_RSLOW"
check "--report states the rate of a fall the quiet mode keeps to itself" \
  "$([ "$PROBE_RC" -eq 0 ] && grep -q 'about 20 GB per hour' <<< "$PROBE_MSG" && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"

# Two readings minutes apart: no rate, and the reason is the span, with the minimum named.
S_RSHORT="$TMPROOT/state-r-short"
rprobe "$((300 * GB))" "$((T0 - 240))" "$S_RSHORT"
rprobe "$((280 * GB))" "$T0" "$S_RSHORT"
check "--report over a span too short states no rate and says the span is the reason" \
  "$([ "$PROBE_RC" -eq 0 ] && ! grep -qi 'per hour' <<< "$PROBE_MSG" && grep -q 'span only 4 minute(s)' <<< "$PROBE_MSG" && grep -q 'at least 10 minutes' <<< "$PROBE_MSG" && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"

# Free space went up across the window: not falling, said in those words.
S_RUP="$TMPROOT/state-r-up"
rprobe "$((100 * GB))" "$((T0 - 10800))" "$S_RUP"
rprobe "$((101 * GB))" "$T0" "$S_RUP"
check "--report on a disk that is not falling says so rather than stating a rate" \
  "$([ "$PROBE_RC" -eq 0 ] && ! grep -qi 'per hour' <<< "$PROBE_MSG" && grep -qi 'not falling' <<< "$PROBE_MSG" && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"

# A sawtooth: no rate, and the reason is the recovery, not a missing history.
S_RSAW="$TMPROOT/state-r-saw"
rprobe "$((150 * GB))" "$((T0 - 3600))" "$S_RSAW"
rprobe "$((35 * GB))"  "$((T0 - 2400))" "$S_RSAW"
rprobe "$((150 * GB))" "$((T0 - 1200))" "$S_RSAW"
rprobe "$((86 * GB))"  "$T0" "$S_RSAW"
check "--report after a recovery states no rate and names the recovery as the reason" \
  "$(! grep -qi 'per hour' <<< "$PROBE_MSG" && grep -qi 'went back up' <<< "$PROBE_MSG" && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"

# Under the floor with no rate: still exit 3, and the reason travels with it.
rprobe "$((7 * GB))" "$T0" "$TMPROOT/state-r-low"
check "--report under the floor still exits 3 and still says why there is no rate" \
  "$([ "$PROBE_RC" -eq 3 ] && grep -q '7 GB free on /fixture' <<< "$PROBE_MSG" && grep -qi 'first reading' <<< "$PROBE_MSG" && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"

# A mistyped flag must not fall back to the quiet mode, which on a healthy disk prints nothing and
# would read as a report with nothing in it (L320).
S_RTYPO="$TMPROOT/state-r-typo"; mkdir -p "$S_RTYPO"
typo_msg="$(FREE_SPACE_BYTES="$((200 * GB))" FREE_SPACE_NOW="$T0" FREE_SPACE_STATE_DIR="$S_RTYPO" \
  FREE_SPACE_PATH=/fixture bash "$CHECK" --reprot 2>&1)"; typo_rc=$?
check "an argument it does not know is refused by name, never run as the quiet mode" \
  "$([ "$typo_rc" -eq 2 ] && grep -q -- '--reprot' <<< "$typo_msg" && echo ok || echo "exit $typo_rc, said: $typo_msg")"

# And the report against a real df, which on this Mac is BSD df: the reading parses into GB.
S_RDF="$TMPROOT/state-r-df"; mkdir -p "$S_RDF"
rdf_msg="$(FREE_SPACE_NOW="$T0" FREE_SPACE_STATE_DIR="$S_RDF" FREE_SPACE_PATH=/ FREE_SPACE_FLOOR_GB=0 \
  bash "$CHECK" --report 2>&1)"; rdf_rc=$?
check "--report against a real df parses a number of GB" \
  "$([ "$rdf_rc" -eq 0 ] && grep -qE '^claude-sync: [0-9]+ GB free on /,' <<< "$rdf_msg" && echo ok || echo "exit $rdf_rc, said: $rdf_msg")"

# ---- the macOS symbol cache, named as a known cause on a low or falling verdict ----
# Measured 2026-10-04: the disk fell from 25 GB to 8 GB free, more than once, while Overture agents
# built and crash tested, and this warning said only that nothing here knew what was using it.
# The cause was /System/Library/Caches/com.apple.coresymbolicationd at 194 GB, filled by macOS
# whenever a crash report is written or a process is sampled. Only root can read inside it, so the
# check cannot size it, and the message has to say so rather than imply a size (L11). What it CAN
# read is when a file was last added to or removed from it.
SYMDIR="$TMPROOT/symbol-cache"; mkdir -p "$SYMDIR"
sym_mtime="$(stat -c %Y "$SYMDIR" 2>/dev/null || stat -f %m "$SYMDIR" 2>/dev/null)"
sym_probe(){   # sym_probe <free bytes> <epoch> <state dir> [cache dir]
  local out="$TMPROOT/sym-out"
  FREE_SPACE_BYTES="$1" FREE_SPACE_NOW="$2" FREE_SPACE_STATE_DIR="$3" FREE_SPACE_PATH=/fixture \
    FREE_SPACE_SYMBOL_CACHE="${4:-$SYMDIR}" bash "$CHECK" > "$out" 2>&1
  PROBE_RC=$?
  PROBE_MSG="$(cat "$out" 2>/dev/null || true)"
}
check "the suite could read the fixture folder's own change time" \
  "$([ -n "$sym_mtime" ] && echo ok || echo "stat gave nothing for $SYMDIR")"

S_SYM="$TMPROOT/state-sym-low"; mkdir -p "$S_SYM"
sym_probe "$((7 * GB))" "$((sym_mtime + 1800))" "$S_SYM"; sym_low="$PROBE_MSG"; sym_low_rc=$PROBE_RC
check "a low verdict still exits 3 with the symbol cache named" \
  "$([ "$sym_low_rc" -eq 3 ] && echo ok || echo "exit $sym_low_rc, said: $sym_low")"
check "a low verdict names the macOS symbol cache folder as a known cause" \
  "$(grep -q '/System/Library/Caches/com.apple.coresymbolicationd' <<< "$sym_low" && echo ok || echo "said: $sym_low")"
check "and says it is a cache macOS rebuilds" \
  "$(grep -qi 'rebuilds' <<< "$sym_low" && echo ok || echo "said: $sym_low")"
check "and says reading its size needs an administrator, rather than claiming one" \
  "$(grep -qi 'administrator' <<< "$sym_low" && grep -qi 'cannot say how big' <<< "$sym_low" && echo ok || echo "said: $sym_low")"
check "and gives the command that sizes it" \
  "$(grep -qxF 'sudo du -sh /System/Library/Caches/com.apple.coresymbolicationd' <<< "$sym_low" && echo ok || echo "said: $sym_low")"
check "and the command that clears it, emptying the folder rather than removing it" \
  "$(grep -qxF 'sudo find /System/Library/Caches/com.apple.coresymbolicationd -mindepth 1 -delete' <<< "$sym_low" && echo ok || echo "said: $sym_low")"
# A suspect, never a finding: the check measured no cause and must not read as if it had (L11).
check "and calls it a suspect nothing measured, not the cause" \
  "$(grep -q 'Nothing measured it' <<< "$sym_low" && grep -q 'or whether it is the cause' <<< "$sym_low" && echo ok || echo "said: $sym_low")"
# Sizing comes before clearing, and clearing is conditional on what the size shows (L9).
check "and puts sizing before clearing, with clearing left as Dan's decision" \
  "$(awk '/sudo du -sh/ { d = NR } /sudo find/ { f = NR } END { exit !(d && f && d < f) }' <<< "$sym_low" && grep -q 'you decide to clear it' <<< "$sym_low" && echo ok || echo "said: $sym_low")"
# One copy paste command per block, so Dan never has to pick a line out of a block (global rule).
sym_blocks="$(awk '/^```/ { if (inb) { print n; inb=0 } else { inb=1; n=0 }; next } inb { n++ }' <<< "$sym_low")"
check "each command sits alone in its own code block" \
  "$([ "$sym_blocks" = "$(printf '1\n1')" ] && echo ok || echo "block line counts: $(tr '\n' ' ' <<< "$sym_blocks"), said: $sym_low")"
check "and the change time it read is stated, as an age" \
  "$(grep -q '30 minute(s) ago' <<< "$sym_low" && echo ok || echo "said: $sym_low")"
check "and the folder is named only after the free space sentence, so the nudge still reads its figure" \
  "$(grep -q '^claude-sync: only 7 GB free on /fixture' <<< "${sym_low%%$'\n'*}" && echo ok || echo "first line: ${sym_low%%$'\n'*}")"

# Falling fast, above the floor, is the other verdict that names it.
S_SYMF="$TMPROOT/state-sym-fast"; mkdir -p "$S_SYMF"
sym_probe "$((300 * GB))" "$((sym_mtime - 10800))" "$S_SYMF"
sym_probe "$((60 * GB))" "$sym_mtime" "$S_SYMF"; sym_fast="$PROBE_MSG"
check "a falling fast verdict names the symbol cache too" \
  "$([ "$PROBE_RC" -eq 4 ] && grep -q 'com.apple.coresymbolicationd' <<< "$sym_fast" && echo ok || echo "exit $PROBE_RC, said: $sym_fast")"

# A healthy disk says nothing at all, the folder included, however recently it changed.
S_SYMH="$TMPROOT/state-sym-healthy"; mkdir -p "$S_SYMH"
sym_probe "$((200 * GB))" "$((sym_mtime + 60))" "$S_SYMH"; sym_ok="$PROBE_MSG"
check "a healthy verdict does not mention the symbol cache" \
  "$([ "$PROBE_RC" -eq 0 ] && [ -z "$sym_ok" ] && echo ok || echo "exit $PROBE_RC, said: $sym_ok")"

# Where the folder does not exist (a Linux runner, a later macOS) it cannot be the cause, so it is
# not named.
S_SYMN="$TMPROOT/state-sym-none"; mkdir -p "$S_SYMN"
sym_probe "$((7 * GB))" "$T0" "$S_SYMN" "$TMPROOT/absent-symbol-cache"; sym_none="$PROBE_MSG"
check "a low verdict on a machine without the folder does not name it" \
  "$([ "$PROBE_RC" -eq 3 ] && ! grep -q 'coresymbolicationd' <<< "$sym_none" && echo ok || echo "exit $PROBE_RC, said: $sym_none")"

# ---- swap, and the processes holding the memory, named when swap is filling the disk (#1770) ----
# On 2026-10-26 the disk on Daniels-MacBook-Pro-2 reached 1.1 GB free and the cause was 95 GB of
# swap, held by two processes leaking memory (Backblaze's bzserv at 117 GB and fseventsd at 105 GB
# by top's MEM). Swap lives on its own volume, /System/Volumes/VM, which shares the disk and which no
# folder size reaches, and the warning named only the symbol cache, which did not exist that day.
# The readers below print what sysctl and top printed that day, shaped as they print it; the suite
# never runs either (L2).
swap_reader(){   # swap_reader <file> <used, as sysctl prints it, e.g. 94658.81M>
  printf '#!/bin/sh\necho "vm.swapusage: total = 95232.00M  used = %s  free = 573.19M  (encrypted)"\n' "$2" > "$1"
  chmod +x "$1"
}
SWAP_BIG="$TMPROOT/swap-big"; swap_reader "$SWAP_BIG" 94658.81M
SWAP_SMALL="$TMPROOT/swap-small"; swap_reader "$SWAP_SMALL" 136.25M
TOP_BUSY="$TMPROOT/top-busy"
cat > "$TOP_BUSY" <<TOP
#!/bin/sh
: >> "$TOP_CALLED"
cat <<'OUT'
Processes: 812 total, 4 running, 808 sleeping, 4210 threads
2026/10/26 15:58:01
Load Avg: 5.10, 4.80, 4.62
PhysMem: 95G used (6100M wired, 39G compressor), 849M unused.

PID    COMMAND          MEM
612    bzserv           117G
377    fseventsd        105G
1290   Google Chrome He 2310M+
OUT
TOP
chmod +x "$TOP_BUSY"
swap_probe(){   # swap_probe <free bytes> <state dir> <swap reader> [top] [VAR=value...]
  local free="$1" state="$2" swap="$3" top="${4:-$TOP_BUSY}" out="$TMPROOT/swap-out"
  shift 3; [ "$#" -gt 0 ] && shift
  mkdir -p "$state"; rm -f "$TOP_CALLED"
  env FREE_SPACE_BYTES="$free" FREE_SPACE_NOW="$T0" FREE_SPACE_STATE_DIR="$state" FREE_SPACE_PATH=/fixture \
    FREE_SPACE_SWAP_CMD="$swap" FREE_SPACE_TOP_CMD="$top" "$@" bash "$CHECK" > "$out" 2>&1
  PROBE_RC=$?
  PROBE_MSG="$(cat "$out" 2>/dev/null || true)"
}

swap_probe "$((1 * GB))" "$TMPROOT/state-swap-big" "$SWAP_BIG"; swap_big="$PROBE_MSG"
check "a low disk with swap above its share still exits 3" \
  "$([ "$PROBE_RC" -eq 3 ] && echo ok || echo "exit $PROBE_RC, said: $swap_big")"
check "and says how much swap there is, read from sysctl" \
  "$(grep -q 'Swap holds 92 GB' <<< "$swap_big" && echo ok || echo "said: $swap_big")"
check "and names the processes holding the most memory, with what top measured" \
  "$(grep -q 'bzserv (pid 612): 117G' <<< "$swap_big" && grep -q 'fseventsd (pid 377): 105G' <<< "$swap_big" && echo ok || echo "said: $swap_big")"
check "and keeps a command name that has a space in it whole" \
  "$(grep -q 'Google Chrome He (pid 1290): 2310M' <<< "$swap_big" && echo ok || echo "said: $swap_big")"
check "and says a restart gives the space back, and deleting files does not" \
  "$(grep -qi 'restart' <<< "$swap_big" && grep -qi 'deleting files does not' <<< "$swap_big" && echo ok || echo "said: $swap_big")"
check "and the swap is said only after the free space sentence, so the nudge still reads its figure" \
  "$(grep -q '^claude-sync: only 1 GB free on /fixture' <<< "${swap_big%%$'\n'*}" && echo ok || echo "first line: ${swap_big%%$'\n'*}")"
check "and the first line no longer says nothing measured a cause, since swap was measured" \
  "$(grep -q 'Swap is measured below' <<< "${swap_big%%$'\n'*}" && ! grep -q 'Nothing here says what is using it' <<< "$swap_big" && echo ok || echo "first line: ${swap_big%%$'\n'*}")"
check "and hands over the top command that lists them, alone in its block" \
  "$(grep -qxF 'top -l 1 -o mem -n 10 -stats pid,command,mem,time' <<< "$swap_big" && echo ok || echo "said: $swap_big")"

# Below the share, on the same low disk: no memory holders, and top is never run. The two readings
# sit either side of the line (L497: shift the input both ways).
swap_probe "$((1 * GB))" "$TMPROOT/state-swap-small" "$SWAP_SMALL"; swap_small="$PROBE_MSG"
check "a low disk with ordinary swap names no memory holders" \
  "$([ "$PROBE_RC" -eq 3 ] && ! grep -q 'bzserv' <<< "$swap_small" && ! grep -qi 'Swap holds' <<< "$swap_small" && echo ok || echo "exit $PROBE_RC, said: $swap_small")"
check "and its first line still says nothing here measured what is using the disk" \
  "$(grep -q 'Nothing here says what is using it' <<< "${swap_small%%$'\n'*}" && echo ok || echo "first line: ${swap_small%%$'\n'*}")"
check "and never runs top, which costs a second on every warning" \
  "$([ ! -e "$TOP_CALLED" ] && echo ok || echo "top was run")"
SWAP_19="$TMPROOT/swap-19"; swap_reader "$SWAP_19" 1945.60M   # 1.9 GB of a 100 GB disk
SWAP_21="$TMPROOT/swap-21"; swap_reader "$SWAP_21" 2150.40M   # 2.1 GB of it
swap_probe "$((1 * GB))" "$TMPROOT/state-swap-19" "$SWAP_19" "" FREE_SPACE_DISK_BYTES=$((100 * GB))
check "swap just under 2% of the disk is not named" \
  "$(! grep -qi 'Swap holds' <<< "$PROBE_MSG" && echo ok || echo "said: $PROBE_MSG")"
swap_probe "$((1 * GB))" "$TMPROOT/state-swap-21" "$SWAP_21" "" FREE_SPACE_DISK_BYTES=$((100 * GB))
check "and just over 2% of it is" \
  "$(grep -qi 'Swap holds 2 GB' <<< "$PROBE_MSG" && echo ok || echo "said: $PROBE_MSG")"

# A disk with room says nothing, however much swap there is: the holders ride on a warning that is
# already firing, never on one of their own.
swap_probe "$((200 * GB))" "$TMPROOT/state-swap-room" "$SWAP_BIG"
check "a disk with room says nothing about swap, and runs no top" \
  "$([ "$PROBE_RC" -eq 0 ] && [ -z "$PROBE_MSG" ] && [ ! -e "$TOP_CALLED" ] && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"

# Swap that cannot be read is said to be unread, never taken as none (L98, L11).
SWAP_BROKEN="$TMPROOT/swap-broken"
printf '#!/bin/sh\necho "sysctl: unknown oid vm.swapusage" >&2\nexit 1\n' > "$SWAP_BROKEN"; chmod +x "$SWAP_BROKEN"
swap_probe "$((1 * GB))" "$TMPROOT/state-swap-broken" "$SWAP_BROKEN"
check "swap that cannot be read is said to be unread on a low disk, and the verdict still stands" \
  "$([ "$PROBE_RC" -eq 3 ] && grep -qi 'could not read swap' <<< "$PROBE_MSG" && grep -qF 'sysctl vm.swapusage' <<< "$PROBE_MSG" && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"

# Swap read but the disk's size not: the share cannot be judged, and that is what is said, never
# that swap went unread.
swap_probe "$((1 * GB))" "$TMPROOT/state-swap-nosize" "$SWAP_BIG" "" FREE_SPACE_DISK_BYTES=
check "swap read with no disk size says how much swap and that its share is not known" \
  "$([ "$PROBE_RC" -eq 3 ] && grep -q 'Swap holds 92 GB' <<< "$PROBE_MSG" && grep -qi 'size could not be read' <<< "$PROBE_MSG" && ! grep -qi 'could not read swap' <<< "$PROBE_MSG" && [ ! -e "$TOP_CALLED" ] && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"

# A top that prints nothing, or that hangs, still leaves the swap said and the command handed over.
swap_probe "$((1 * GB))" "$TMPROOT/state-swap-top-empty" "$SWAP_BIG" "$TOP_SILENT"
check "a top that names nobody is said, never read as nobody holding memory" \
  "$([ "$PROBE_RC" -eq 3 ] && grep -q 'Swap holds 92 GB' <<< "$PROBE_MSG" && grep -qi 'top named no process' <<< "$PROBE_MSG" && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"
TOP_HANG="$TMPROOT/top-hang"
cat > "$TOP_HANG" <<TOP
#!/bin/sh
n=0; while [ ! -e "$TMPROOT/release-top" ] && [ "\$n" -lt $((HANG_S * 10)) ]; do sleep 0.1; n=\$((n + 1)); done
echo "612 bzserv 117G"
TOP
chmod +x "$TOP_HANG"
swap_probe "$((1 * GB))" "$TMPROOT/state-swap-top-hang" "$SWAP_BIG" "$TOP_HANG" FREE_SPACE_TOP_SECONDS=1
: > "$TMPROOT/release-top"
check "a top that hangs is stopped at its bound, and the warning still arrives saying so" \
  "$([ "$PROBE_RC" -eq 3 ] && grep -qF 'did not answer within 1s' <<< "$PROBE_MSG" && ! grep -q 'bzserv' <<< "$PROBE_MSG" && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"

# ---- the swap readings are recorded, one maximum per day, so the 2% can be recalibrated ----
# The threshold rests on eight readings found in transcripts (see the check's header). Recalibrating
# it needs the healthy days' readings, which nothing kept: the readings file holds six hours.
S_SWD="$TMPROOT/state-swap-days"
swap_probe "$((200 * GB))" "$S_SWD" "$SWAP_BIG"
swap_probe "$((200 * GB))" "$S_SWD" "$SWAP_SMALL"
swd_day="$(date -u -r "$T0" +%F 2>/dev/null || date -u -d "@$T0" +%F)"
check "a day's swap record keeps that day's highest reading and the disk size" \
  "$(grep -qxF "$swd_day 99256956355 $FREE_SPACE_DISK_BYTES" "$S_SWD/_fixture.swap-days" 2>/dev/null && echo ok || echo "record: $(cat "$S_SWD/_fixture.swap-days" 2>/dev/null)")"
check "and one line per day, not one per reading" \
  "$([ "$(grep -c . "$S_SWD/_fixture.swap-days" 2>/dev/null)" = 1 ] && echo ok || echo "record: $(cat "$S_SWD/_fixture.swap-days" 2>/dev/null)")"
S_SWD2="$TMPROOT/state-swap-days-many"; mkdir -p "$S_SWD2"
awk 'BEGIN { for (i = 0; i < 200; i++) printf "2020-01-%03d 0 1\n", i }' > "$S_SWD2/_fixture.swap-days"
swap_probe "$((200 * GB))" "$S_SWD2" "$SWAP_SMALL"
check "and the record keeps a bounded number of days" \
  "$([ "$(grep -c . "$S_SWD2/_fixture.swap-days")" -le 120 ] && grep -q "^$swd_day " <<< "$(tail -n 1 "$S_SWD2/_fixture.swap-days")" && echo ok || echo "$(grep -c . "$S_SWD2/_fixture.swap-days") line(s), last: $(tail -n 1 "$S_SWD2/_fixture.swap-days")")"

# ---- the disk-clean scan's remaining total, added to a low or falling warning (#1809) ----
# A warning that says the disk is nearly full, while a scan from two days ago already found 14 GB
# that could go, leaves Dan to rediscover it. So on verdict 3 or 4 the warning adds one line: what
# that scan offered and disk-clean has not removed yet, and how old the scan is. The record belongs
# to disk-clean, so the fixtures are written by its own writer, lib/disk-clean-record.sh, rather
# than typed here (L370), and every way the record can be absent or wrong must leave the warning
# exactly as it was, exit code included (L5: the line is an extra, never a condition).
. "$DIR/lib/disk-clean-record.sh" || { echo "FAIL: lib/disk-clean-record.sh is missing"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
SCANS="$TMPROOT/scans"; mkdir -p "$SCANS"
US=$'\037'
DAY=86400
EMDASH="$(printf '\xe2\x80\x94')"; ENDASH="$(printf '\xe2\x80\x93')"
# scan_record <file> <scanned_at> <item line>...   each item line: id|category|method|target|bytes|state|size
scan_record(){
  local f="$1" at="$2" items="$SCANS/items-$RANDOM"; shift 2
  : > "$items"
  local line
  for line in "$@"; do
    IFS='|' read -r _id _cat _m _t _b _st _sz <<< "$line"
    printf '%s\n' "$_id$US$_cat$US$_m$US$_t$US$_b$US$_st$US$US$_sz" >> "$items"
  done
  dcr_write "$f" "scan-$RANDOM" "$at" "$items" || echo "FAIL: the fixture writer refused $f"
}
# scan_probe <record> <free bytes> [state dir] -> PROBE_RC and PROBE_MSG, from a reading of its own
scan_probe(){
  local state="${3:-$TMPROOT/state-scan-$RANDOM}"
  FREE_SPACE_SCAN_RECORD="$1" probe "$2" "$T0" "$state"
}

# The warning as it reads with no scan at all, which every refusal below must reproduce exactly.
# Each of those probes reuses this state folder, so the reading history (and so the rate clause)
# is the same first reading every time: the probe at T0 is dropped as a reading not before now.
scan_probe "$TMPROOT/no-scan-here/last-scan.json" "$((7 * GB))" "$TMPROOT/state-scan-base"
base_rc="$PROBE_RC"; base_msg="$PROBE_MSG"
check "with no scan record a low warning still exits 3" "$([ "$base_rc" -eq 3 ] && echo ok || echo "exit $base_rc")"
check "and says nothing about disk-clean" "$(! grep -q 'disk-clean' <<< "$base_msg" && echo ok || echo "said: $base_msg")"

# Two offerable items (10 GB and 4.5 GB), one already removed, one refused, one unmeasured. Only the
# first two are what is left to offer.
SC_FRESH="$SCANS/fresh.json"
scan_record "$SC_FRESH" "$((T0 - 2 * DAY - 3600))" \
  "a1|caches|trash|/x/caches|$((10 * GB))|offerable|measured" \
  "a2|xcode|trash|/x/derived|$((9 * GB / 2))|offerable|measured" \
  "a3|trash|empty|/x/.Trash|$((50 * GB))|removed|measured" \
  "a4|worktrees|trash|/x/wt|$((20 * GB))|not offerable: it has uncommitted work|measured" \
  "a5|docker|prune|images|$((30 * GB))|unmeasured: docker did not answer|unread"
scan_probe "$SC_FRESH" "$((7 * GB))" "$TMPROOT/state-scan-base"; fresh_msg="$PROBE_MSG"
check "a fresh scan leaves the low verdict's exit code at 3" "$([ "$PROBE_RC" -eq 3 ] && echo ok || echo "exit $PROBE_RC")"
check "and the warning's first line exactly as it was" \
  "$([ "$(head -n 1 <<< "$fresh_msg")" = "$(head -n 1 <<< "$base_msg")" ] && echo ok || echo "first line: $(head -n 1 <<< "$fresh_msg")")"
check "and adds exactly one line, the rest of the warning untouched" \
  "$([ "$(grep -vF 'disk-clean' <<< "$fresh_msg")" = "$base_msg" ] && [ "$(grep -cF 'disk-clean' <<< "$fresh_msg")" = 1 ] && echo ok || echo "said: $fresh_msg")"
fresh_line="$(grep -F 'disk-clean' <<< "$fresh_msg")"
check "the line totals only what is offerable and not yet removed (10 + 4.5 GB)" \
  "$(grep -qF ' 14.5 GB ' <<< "$fresh_line" && ! grep -qF 'at least' <<< "$fresh_line" && echo ok || echo "said: $fresh_line")"
check "and says how old the scan is" "$(grep -qF 'taken 2 day(s) ago' <<< "$fresh_line" && echo ok || echo "said: $fresh_line")"
check "and suggests /disk-clean" "$(grep -qF 'run /disk-clean' <<< "$fresh_line" && echo ok || echo "said: $fresh_line")"
check "and holds no dash as punctuation" \
  "$(! grep -qE "[[:space:]]-[[:space:]]|$EMDASH|$ENDASH" <<< "$fresh_line" && echo ok || echo "said: $fresh_line")"
printf '%s\n' "$fresh_line" > "$SCANS/line-exact"

# Falling fast (exit 4) carries the same line.
S_SCF="$TMPROOT/state-scan-falling"; mkdir -p "$S_SCF"
FREE_SPACE_SCAN_RECORD="$SC_FRESH" probe "$((300 * GB))" "$((T0 - 10800))" "$S_SCF"
FREE_SPACE_SCAN_RECORD="$SC_FRESH" probe "$((60 * GB))" "$T0" "$S_SCF"
check "a falling verdict keeps exit 4 and adds the same line" \
  "$([ "$PROBE_RC" -eq 4 ] && grep -qxF "$fresh_line" <<< "$PROBE_MSG" && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"

# A disk with room says nothing, report or not: the line belongs to a warning.
scan_probe "$SC_FRESH" "$((200 * GB))"
check "a disk with room adds no line, even with a fresh scan" "$([ "$PROBE_RC" -eq 0 ] && [ -z "$PROBE_MSG" ] && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"
FREE_SPACE_SCAN_RECORD="$SC_FRESH" rprobe "$((200 * GB))" "$T0" "$TMPROOT/state-scan-report"
check "nor does --report on a disk with room" "$([ "$PROBE_RC" -eq 0 ] && ! grep -q 'disk-clean' <<< "$PROBE_MSG" && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"

# Every record that cannot be trusted adds nothing and changes nothing: the output is byte for
# byte the no scan warning, and the exit code is still 3.
same_as_base(){ [ "$PROBE_RC" -eq "$base_rc" ] && [ "$PROBE_MSG" = "$base_msg" ] && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG"; }
SC_STALE="$SCANS/stale.json"
scan_record "$SC_STALE" "$((T0 - 8 * DAY))" "s1|caches|trash|/x/c|$((10 * GB))|offerable|measured"
scan_probe "$SC_STALE" "$((7 * GB))" "$TMPROOT/state-scan-base"
check "a scan 8 days old adds nothing" "$(same_as_base)"
SC_EDGE="$SCANS/seven.json"
scan_record "$SC_EDGE" "$((T0 - 7 * DAY))" "s1|caches|trash|/x/c|$((10 * GB))|offerable|measured"
scan_probe "$SC_EDGE" "$((7 * GB))" "$TMPROOT/state-scan-base"
check "a scan exactly 7 days old adds nothing (under 7 days, not up to)" "$(same_as_base)"
SC_INSIDE="$SCANS/inside.json"
scan_record "$SC_INSIDE" "$((T0 - 7 * DAY + 60))" "s1|caches|trash|/x/c|$((10 * GB))|offerable|measured"
scan_probe "$SC_INSIDE" "$((7 * GB))" "$TMPROOT/state-scan-base"
check "a scan a minute under 7 days old is still used, and said to be 6 days old" \
  "$(grep -qF 'taken 6 day(s) ago' <<< "$PROBE_MSG" && echo ok || echo "said: $PROBE_MSG")"
SC_FUTURE="$SCANS/future.json"
scan_record "$SC_FUTURE" "$((T0 + 3600))" "s1|caches|trash|/x/c|$((10 * GB))|offerable|measured"
scan_probe "$SC_FUTURE" "$((7 * GB))" "$TMPROOT/state-scan-base"
check "a scan dated in the future adds nothing, since its age cannot be stated" "$(same_as_base)"
scan_probe "$SCANS/absent.json" "$((7 * GB))" "$TMPROOT/state-scan-base"
check "a missing scan file adds nothing" "$(same_as_base)"
SC_CUT="$SCANS/cut.json"
sed '$d' "$SC_FRESH" > "$SC_CUT"
scan_probe "$SC_CUT" "$((7 * GB))" "$TMPROOT/state-scan-base"
check "a scan file cut off before its closing line adds nothing" "$(same_as_base)"
SC_JUNK="$SCANS/junk.json"
printf 'not a record at all\n]}\n' > "$SC_JUNK"
scan_probe "$SC_JUNK" "$((7 * GB))" "$TMPROOT/state-scan-base"
check "a file that is not a scan record adds nothing" "$(same_as_base)"
SC_NOAT="$SCANS/noat.json"
{ printf '{"version":1,"scan_id":"x","items":[\n'; sed -n '2,$p' "$SC_FRESH"; } > "$SC_NOAT"
scan_probe "$SC_NOAT" "$((7 * GB))" "$TMPROOT/state-scan-base"
check "a record with no scanned_at adds nothing" "$(same_as_base)"
SC_BADITEM="$SCANS/baditem.json"
awk 'NR == 3 { print "{\"id\":\"broken\",\"category\":\"caches\",\"bytes\":5}," ; next } { print }' "$SC_FRESH" > "$SC_BADITEM"
scan_probe "$SC_BADITEM" "$((7 * GB))" "$TMPROOT/state-scan-base"
check "a record holding an item line it cannot read adds nothing, rather than a total missing that item" "$(same_as_base)"
: > "$SCANS/empty.json"
scan_probe "$SCANS/empty.json" "$((7 * GB))" "$TMPROOT/state-scan-base"
check "an empty scan file adds nothing" "$(same_as_base)"
mkdir -p "$SCANS/dir.json"
scan_probe "$SCANS/dir.json" "$((7 * GB))" "$TMPROOT/state-scan-base"
check "a folder where the scan file should be adds nothing" "$(same_as_base)"
SC_LOCKED="$SCANS/locked.json"
cp "$SC_FRESH" "$SC_LOCKED"; chmod 000 "$SC_LOCKED"
if cat "$SC_LOCKED" >/dev/null 2>&1; then
  check "an unreadable scan file adds nothing" "UNMEASURED: this user can read a mode 000 file (root?), so unreadability cannot be set up here"
else
  scan_probe "$SC_LOCKED" "$((7 * GB))" "$TMPROOT/state-scan-base"
  check "an unreadable scan file adds nothing" "$(same_as_base)"
fi
chmod 600 "$SC_LOCKED"

# Sizes that were not read in full are never counted as 0, and the total is said to be a floor.
SC_PART="$SCANS/partial.json"
scan_record "$SC_PART" "$((T0 - DAY))" \
  "p1|caches|trash|/x/c|$((10 * GB))|offerable|measured" \
  "p2|large-files|trash|/x/big|$((3 * GB))|offerable|partial"
scan_probe "$SC_PART" "$((7 * GB))"
check "a partly read size makes the total 'at least' that much" \
  "$([ "$PROBE_RC" -eq 3 ] && grep -qF 'at least 13.0 GB' <<< "$PROBE_MSG" && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"
printf '%s\n' "$(grep -F 'disk-clean' <<< "$PROBE_MSG")" > "$SCANS/line-at-least"
SC_UNREAD="$SCANS/unread.json"
scan_record "$SC_UNREAD" "$((T0 - DAY))" \
  "u1|caches|trash|/x/c|$((10 * GB))|offerable|measured" \
  "u2|playwright|trash|/x/pw||offerable|unread"
scan_probe "$SC_UNREAD" "$((7 * GB))"
check "an offerable item with no size read makes the total 'at least', never a 0 added in" \
  "$(grep -qF 'at least 10.0 GB' <<< "$PROBE_MSG" && echo ok || echo "said: $PROBE_MSG")"
SC_ALLUNREAD="$SCANS/allunread.json"
scan_record "$SC_ALLUNREAD" "$((T0 - DAY))" "v1|playwright|trash|/x/pw||offerable|unread" "v2|caches|trash|/x/c|$((5 * GB))|removed|measured"
scan_probe "$SC_ALLUNREAD" "$((7 * GB))"
check "offerable items whose sizes were all unread are said to be unsized, never '0 GB'" \
  "$(grep -qF '1 item(s)' <<< "$PROBE_MSG" && grep -qF 'could not read' <<< "$PROBE_MSG" && ! grep -qE ' 0(\.0)? ?[KMG]B' <<< "$PROBE_MSG" && echo ok || echo "said: $PROBE_MSG")"
printf '%s\n' "$(grep -F 'disk-clean' <<< "$PROBE_MSG")" > "$SCANS/line-unsized"

# Everything already removed: the scan has nothing left, which is said rather than a total of 0.
SC_DONE="$SCANS/done.json"
scan_record "$SC_DONE" "$((T0 - 3 * 3600))" "d1|caches|trash|/x/c|$((10 * GB))|removed|measured" "d2|trash|empty|/x/t|$((2 * GB))|trashed|measured"
scan_probe "$SC_DONE" "$((7 * GB))"
check "a scan with everything removed says nothing is left, in hours when under a day old" \
  "$([ "$PROBE_RC" -eq 3 ] && grep -qF 'taken 3 hour(s) ago' <<< "$PROBE_MSG" && grep -qF 'nothing left' <<< "$PROBE_MSG" && echo ok || echo "exit $PROBE_RC, said: $PROBE_MSG")"
printf '%s\n' "$(grep -F 'disk-clean' <<< "$PROBE_MSG")" > "$SCANS/line-nothing-left"
# A scan that offered nothing at all is not one whose offers were taken, and one that could not
# judge some of what it found says so (L540: no answer without its measured reason). Measured on
# 2026-10-28: a real claude-temp scan found 376 folders and judged none, because the session map
# was empty while Claude Code ran.
SC_NONE="$SCANS/none.json"
scan_record "$SC_NONE" "$((T0 - 3600))" "n1|claude-temp|trash|/x/t1|4096|unmeasured: the session map is empty|measured" \
  "n2|claude-temp|trash|/x/t2|4096|unmeasured: the session map is empty|measured" "n3|caches|trash|/x/c|$GB|not offerable: in use|measured"
scan_probe "$SC_NONE" "$((7 * GB))"
check "a scan that offered nothing says it found nothing it could remove, and how many it could not judge" \
  "$(grep -qF 'found nothing it could remove' <<< "$PROBE_MSG" && grep -qF 'could not judge 2 item(s)' <<< "$PROBE_MSG" && ! grep -qF 'nothing left' <<< "$PROBE_MSG" && echo ok || echo "said: $PROBE_MSG")"
printf '%s\n' "$(grep -F 'disk-clean' <<< "$PROBE_MSG")" > "$SCANS/line-found-nothing"

# THE TALLY IS KEPT BETWEEN PROMPTS. Reading a record costs about 0.14 ms an item (0.76 s for 5,264
# items, measured 2026-10-28), and this runs on every prompt while the disk is low, so the tally is
# kept beside the readings, keyed on the record's inode, change time, size and path, and read again
# only when one of them moves. Every writer of the record (the scan, disk-remove's marks) renames a
# new file into place, so each write is a new inode even inside one second at one size.
S_TALLY="$TMPROOT/state-scan-tally"; mkdir -p "$S_TALLY"
SC_MARK="$SCANS/mark.json"; cp "$SC_FRESH" "$SC_MARK"
scan_probe "$SC_MARK" "$((7 * GB))" "$S_TALLY"
check "the first warning reads the record and keeps its tally" \
  "$(grep -qF ' 14.5 GB ' <<< "$PROBE_MSG" && [ -s "$S_TALLY/disk-clean-tally" ] && echo ok || echo "tally file: $(ls "$S_TALLY"), said: $PROBE_MSG")"
mark_sid="$(dcr_header "$SC_MARK" scan_id)"
printf 'a2%sremoved\n' "$US" > "$SCANS/marks-1"; dcr_mark "$SC_MARK" "$mark_sid" "$SCANS/marks-1"
scan_probe "$SC_MARK" "$((7 * GB))" "$S_TALLY"
check "a removal marked in the record after that is in the next warning's total" \
  "$(grep -qF ' 10.0 GB ' <<< "$PROBE_MSG" && echo ok || echo "said: $PROBE_MSG")"
# "truncated" is as long as "offerable", so this mark leaves the record the same size, and it lands
# inside the same second: only the new file's inode tells the two apart.
printf 'a1%struncated\n' "$US" > "$SCANS/marks-2"; dcr_mark "$SC_MARK" "$mark_sid" "$SCANS/marks-2"
scan_probe "$SC_MARK" "$((7 * GB))" "$S_TALLY"
check "and a mark that leaves the record the same size is seen too" \
  "$(grep -qF 'has nothing left to offer' <<< "$PROBE_MSG" && echo ok || echo "said: $PROBE_MSG")"
# The kept tally is what a matching warning reads: one planted with the record's own key is believed,
# which is the proof the read is skipped, and one that is not a tally is read past, never shown.
SC_KEEP="$SCANS/keep.json"; cp "$SC_FRESH" "$SC_KEEP"
S_KEEP="$TMPROOT/state-scan-keep"; mkdir -p "$S_KEEP"
scan_probe "$SC_KEEP" "$((7 * GB))" "$S_KEEP"
keep_key="$(sed -n 1p "$S_KEEP/disk-clean-tally")"
printf '%s\n%s 2 0 %s 0 0 0 0\n' "$keep_key" "$((T0 - DAY))" "$((99 * 1024 * 1024))" > "$S_KEEP/disk-clean-tally"
scan_probe "$SC_KEEP" "$((7 * GB))" "$S_KEEP"
check "a kept tally whose key matches the record is used without reading the record again" \
  "$(grep -qF ' 99.0 GB ' <<< "$PROBE_MSG" && grep -qF 'taken 1 day(s) ago' <<< "$PROBE_MSG" && echo ok || echo "said: $PROBE_MSG")"
printf '%s\nnot a tally at all\n' "$keep_key" > "$S_KEEP/disk-clean-tally"
scan_probe "$SC_KEEP" "$((7 * GB))" "$S_KEEP"
check "a kept tally that is not one is read past, and the record read again" \
  "$(grep -qxF "$fresh_line" <<< "$PROBE_MSG" && echo ok || echo "said: $PROBE_MSG")"

# Unset, the record is read where disk-clean's scan writes it, under HOME (scan-lib.sh's DCS_RECORD).
FAKE_HOME="$TMPROOT/fake-home"; mkdir -p "$FAKE_HOME/.claude/state/disk-clean"
cp "$SC_FRESH" "$FAKE_HOME/.claude/state/disk-clean/last-scan.json"
FREE_SPACE_BYTES="$((7 * GB))" FREE_SPACE_NOW="$T0" FREE_SPACE_STATE_DIR="$TMPROOT/state-scan-home" FREE_SPACE_PATH=/fixture \
  HOME="$FAKE_HOME" FREE_SPACE_SCAN_RECORD= bash "$CHECK" > "$TMPROOT/scan-home-out" 2>&1
check "with no seam set, the record is read from ~/.claude/state/disk-clean/last-scan.json" \
  "$(grep -qxF "$fresh_line" "$TMPROOT/scan-home-out" && echo ok || echo "said: $(cat "$TMPROOT/scan-home-out")")"
check "and the /disk-clean skill the line suggests is there to run (L111)" \
  "$([ -f "$DIR/../skills/disk-clean/SKILL.md" ] && grep -q '^name: disk-clean$' "$DIR/../skills/disk-clean/SKILL.md" && echo ok || echo "no disk-clean skill beside $DIR")"
check "which is where disk-clean's scan writes it" \
  "$(grep -qF 'DCS_RECORD="$DCS_STATE/last-scan.json"' "$DIR/../skills/disk-clean/scan-lib.sh" && grep -qF 'DCS_STATE="$HOME/.claude/state/disk-clean"' "$DIR/../skills/disk-clean/scan-lib.sh" && echo ok || echo "scan-lib.sh no longer names that path")"

# ================== the nudge: WHEN the answer is spoken ==================
# The check answers the question; the nudge decides when to say it. Same split as
# project-list-nudge.sh, so there is one implementation of the question (L107).
NSTATE="$TMPROOT/nudge-state"; mkdir -p "$NSTATE"
payload(){ printf '{"session_id": "%s", "prompt": "hello"}' "${1:-sess-a}"; }
nudge(){   # nudge <free bytes> <epoch> <check state dir> [session] -> prints all output
  payload "${4:-sess-a}" | FREE_SPACE_BYTES="$1" FREE_SPACE_NOW="$2" FREE_SPACE_STATE_DIR="$3" \
    FREE_SPACE_PATH=/fixture FREE_SPACE_NUDGE_STATE_DIR="$NSTATE" bash "$NUDGE" 2>&1
}

NS1="$TMPROOT/ns1"; mkdir -p "$NS1"
n_fine="$(nudge "$((200 * GB))" "$T0" "$NS1" sess-fine)"; n_fine_rc=$?
check "a healthy disk gets no notice at all" \
  "$([ -z "$n_fine" ] && echo ok || echo "said: $n_fine")"
check "and the prompt is never blocked" "$([ "$n_fine_rc" -eq 0 ] && echo ok || echo "exit $n_fine_rc")"

NS2="$TMPROOT/ns2"; mkdir -p "$NS2"
n_first="$(nudge "$((7 * GB))" "$T0" "$NS2" sess-low)"
check "a low disk is said unprompted" \
  "$(grep -q 'GB free on' <<< "$n_first" && echo ok || echo "said: $n_first")"
check "and the notice names the skill that knows what to do next" \
  "$(grep -q 'disk-full' <<< "$n_first" && echo ok || echo "said: $n_first")"
NS_SYM="$TMPROOT/ns-sym"; mkdir -p "$NS_SYM"
n_sym="$(payload sess-sym | FREE_SPACE_BYTES="$((7 * GB))" FREE_SPACE_NOW="$T0" FREE_SPACE_STATE_DIR="$NS_SYM" \
  FREE_SPACE_PATH=/fixture FREE_SPACE_SYMBOL_CACHE="$SYMDIR" FREE_SPACE_NUDGE_STATE_DIR="$NSTATE" bash "$NUDGE" 2>&1)"
check "the notice carries the symbol cache commands through to the session" \
  "$(grep -qxF 'sudo du -sh /System/Library/Caches/com.apple.coresymbolicationd' <<< "$n_sym" && echo ok || echo "said: $n_sym")"
n_again="$(nudge "$((7 * GB))" "$((T0 + 60))" "$NS2" sess-low)"
check "the same answer is not repeated on the next prompt" \
  "$([ -z "$n_again" ] && echo ok || echo "said: $n_again")"
# Quiet while nothing changes, and loud again when it gets worse: a disk that goes on falling is
# not the same answer as one that has stopped (L152).
n_worse="$(nudge "$((1 * GB))" "$((T0 + 120))" "$NS2" sess-low)"
check "but a materially worse answer is said again" \
  "$(grep -q 'GB free on' <<< "$n_worse" && echo ok || echo "said: $n_worse")"
# A new session loaded nothing and has been told nothing, so it hears it too.
n_other="$(nudge "$((7 * GB))" "$((T0 + 180))" "$NS2" sess-other)"
check "a different session is told as well, having heard nothing itself" \
  "$(grep -q 'GB free on' <<< "$n_other" && echo ok || echo "said: $n_other")"

# Swap crossing its share is a new answer even when the free space has not moved, so the memory
# holders are named once when it appears, and then not again on every prompt (#1770).
NS_SWAP="$TMPROOT/ns-swap"; mkdir -p "$NS_SWAP"
swap_nudge(){   # swap_nudge <epoch> <swap reader>
  payload sess-swap | FREE_SPACE_BYTES="$((7 * GB))" FREE_SPACE_NOW="$1" FREE_SPACE_STATE_DIR="$NS_SWAP" \
    FREE_SPACE_PATH=/fixture FREE_SPACE_NUDGE_STATE_DIR="$NSTATE" FREE_SPACE_SWAP_CMD="$2" \
    FREE_SPACE_TOP_CMD="$TOP_BUSY" FREE_SPACE_DERIVED_DATA_SECONDS=0 bash "$NUDGE" 2>&1
}
swap_nudge "$T0" "$SWAP_SMALL" > /dev/null
n_swap="$(swap_nudge "$((T0 + 60))" "$SWAP_BIG")"
check "swap crossing its share is said, holders and all, though the free space has not moved" \
  "$(grep -q 'bzserv (pid 612)' <<< "$n_swap" && echo ok || echo "said: $n_swap")"
n_swap_again="$(swap_nudge "$((T0 + 120))" "$SWAP_BIG")"
check "and the holders are not named again on the next prompt" \
  "$([ -z "$n_swap_again" ] && echo ok || echo "said: $n_swap_again")"

# When the warning speaks it clears Xcode's build caches whose project folder is gone, on its own:
# Dan's decision on claude-config#1369, 2026-10-20. Which folders those are is decided by
# derived-data-sweep.sh, the one copy of the orphan rule, never a second reading here (L370). The
# deletion runs DETACHED, so a slow sweep can neither slow the warning nor be killed with it at the
# hook's 10 second timeout, and what it did reaches the next warning through its record (L13, L98).
dd_folder() {   # dd_folder <root> <name> <workspace>: one build folder, written long ago
  mkdir -p "$1/$2/Build"
  head -c 40000 /dev/zero > "$1/$2/Build/a.o"
  cat > "$1/$2/info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>WorkspacePath</key>
	<string>$3</string>
</dict>
</plist>
PLIST
  find "$1/$2" -exec touch -t 202601011200 {} +
}
# Waits on the condition (a finished record and nothing marked in progress), never a fixed time
# (L290), with lib/hang-wait.sh's ceiling, which only a sweep that never finishes reaches. It was 30
# s, the ceiling that failed 16 of 16 loaded copies of test-derived-data-sweep.sh (#1577, on 2026-10-23; #1620).
sweep_finished() {   # sweep_finished <state dir>
  hang_wait "[ -f '$1/last-result' ] && [ ! -e '$1/in-progress' ]"
}
run_logs() { find "$1" -name 'run-*.log' 2>/dev/null | wc -l | tr -d ' '; }
dd_nudge() {   # dd_nudge <session> <derived data root> <sweep state> [VAR=value...] -> prints all output
  local sess="$1" root="$2" state="$3"; shift 3
  mkdir -p "$TMPROOT/fs-$sess"
  payload "$sess" | env FREE_SPACE_BYTES="$((7 * GB))" FREE_SPACE_NOW="$T0" FREE_SPACE_STATE_DIR="$TMPROOT/fs-$sess" \
    FREE_SPACE_PATH=/fixture XCODE_DERIVED_DATA_ROOT="$root" DERIVED_DATA_SWEEP_STATE_DIR="$state" \
    FREE_SPACE_NUDGE_STATE_DIR="$NSTATE" FREE_SPACE_DERIVED_DATA_SECONDS="$HANG_S" "$@" bash "$NUDGE" 2>&1
}

DD_ROOT="$TMPROOT/nudge-derived-data"; SW1="$TMPROOT/sweep-1"
mkdir -p "$DD_ROOT/ModuleCache.noindex" "$TMPROOT/live-checkout/App.xcodeproj"
dd_folder "$DD_ROOT" App-orphan "$TMPROOT/removed-worktree/App.xcodeproj"
dd_folder "$DD_ROOT" App-live "$TMPROOT/live-checkout/App.xcodeproj"
dd_folder "$DD_ROOT" App-fresh "$TMPROOT/removed-fresh/App.xcodeproj"
printf 'new' > "$DD_ROOT/App-fresh/Build/b.o"
n_dd="$(dd_nudge sess-dd "$DD_ROOT" "$SW1")"; n_dd_rc=$?
check "a low disk notice says it started clearing the orphaned Xcode build caches" \
  "$(grep -qF 'Started clearing Xcode build caches whose project folder is gone' <<< "$n_dd" && echo ok || echo "said: $n_dd")"
check "and names the switch that turns that off on one Mac" \
  "$(grep -qF 'FREE_SPACE_DERIVED_DATA_AUTO_DELETE=0' <<< "$n_dd" && echo ok || echo "said: $n_dd")"
check "and still does not block the prompt" "$([ "$n_dd_rc" -eq 0 ] && echo ok || echo "exit $n_dd_rc")"
check "the sweep it started finishes and records what it did" \
  "$(sweep_finished "$SW1" && echo ok || echo "no finished record in $SW1")"
check "and it deleted the orphan" "$([ ! -d "$DD_ROOT/App-orphan" ] && echo ok || echo "App-orphan is still there")"
check "and kept the cache whose project is still on disk" "$([ -d "$DD_ROOT/App-live" ] && echo ok || echo "App-live was removed")"
check "and kept the orphan written in the last hour" "$([ -d "$DD_ROOT/App-fresh" ] && echo ok || echo "App-fresh was removed")"
check "and never touched the shared cache" "$([ -d "$DD_ROOT/ModuleCache.noindex" ] && echo ok || echo "ModuleCache.noindex was removed")"
n_dd_next="$(dd_nudge sess-dd-next "$DD_ROOT" "$SW1")"
check "the next warning reports what the last sweep deleted and the df gain" \
  "$(grep -qF 'deleted 1 of 1 orphaned folder(s)' <<< "$n_dd_next" && grep -qF 'df measured' <<< "$n_dd_next" && echo ok || echo "said: $n_dd_next")"
sweep_finished "$SW1" || true

# A slow sweep never slows the warning, and a second warning while it runs starts no second sweep.
# The process list blocks until the suite releases it, so the first sweep is still running, by
# construction, when the second warning arrives.
DD2="$TMPROOT/nudge-derived-data-slow"; SW2="$TMPROOT/sweep-2"; RELEASE2="$TMPROOT/release-2"
dd_folder "$DD2" Slow-orphan "$TMPROOT/removed-slow/App.xcodeproj"
BLOCKING_PS="$TMPROOT/blocking-ps"
cat > "$BLOCKING_PS" <<PS
#!/bin/sh
n=0
while [ ! -e "$RELEASE2" ] && [ "\$n" -lt $((HANG_S * 10)) ]; do sleep 0.1; n=\$((n + 1)); done
echo "  77 /usr/bin/login -f someone"
PS
chmod +x "$BLOCKING_PS"
# Judged by the STATE the warning leaves, never by seconds (L290): the sweep's process list is held
# until the suite releases it, so when the warning returns the sweep it started must still be marked
# in progress with no record, which is untrue only if the warning waited for it. This was "within 5
# s", which a loaded Mac reaches with nothing broken (#1620; 5 s was a setting, not a measurement).
n_slow1="$(dd_nudge sess-slow1 "$DD2" "$SW2" DERIVED_DATA_PS="$BLOCKING_PS")"
slow1_state="$([ -e "$SW2/in-progress" ] && echo in-progress || echo "in-progress absent"), $([ -f "$SW2/last-result" ] && echo "record present" || echo "no record")"
n_slow2="$(dd_nudge sess-slow2 "$DD2" "$SW2" DERIVED_DATA_PS="$BLOCKING_PS")"
: > "$RELEASE2"
check "a warning whose sweep is slow still arrives, without waiting for the sweep" \
  "$(grep -q 'GB free on' <<< "$n_slow1" && [ "$slow1_state" = "in-progress, no record" ] && echo ok || echo "when it returned the sweep it started was $slow1_state though its process list was held, said: $n_slow1")"
check "and says it started the sweep" "$(grep -qF 'Started clearing' <<< "$n_slow1" && echo ok || echo "said: $n_slow1")"
check "a second warning while that sweep runs says one is already running" \
  "$(grep -qF 'already running' <<< "$n_slow2" && ! grep -qF 'Started clearing' <<< "$n_slow2" && echo ok || echo "said: $n_slow2")"
check "the one sweep finishes" "$(sweep_finished "$SW2" && echo ok || echo "no finished record in $SW2")"
check "and only one sweep ran" "$([ "$(run_logs "$SW2")" = 1 ] && echo ok || echo "$(run_logs "$SW2") sweeps ran")"
check "and it deleted the orphan" "$([ ! -d "$DD2/Slow-orphan" ] && echo ok || echo "Slow-orphan is still there")"

# A sweep that fails is reported by the next warning as failing, never as one that freed nothing.
DD3="$TMPROOT/nudge-derived-data-stuck"; SW3="$TMPROOT/sweep-3"
dd_folder "$DD3" Stuck-orphan "$TMPROOT/removed-stuck/App.xcodeproj"
chmod 500 "$DD3/Stuck-orphan/Build"
dd_nudge sess-stuck1 "$DD3" "$SW3" >/dev/null
check "a failing sweep still records" "$(sweep_finished "$SW3" && echo ok || echo "no finished record in $SW3")"
n_stuck="$(dd_nudge sess-stuck2 "$DD3" "$SW3")"
sweep_finished "$SW3" || true
chmod 700 "$DD3/Stuck-orphan/Build"
check "the next warning says the last sweep FAILED and what it could not delete" \
  "$(grep -qF 'FAILED' <<< "$n_stuck" && grep -qF 'could not delete 1 of 1' <<< "$n_stuck" && echo ok || echo "said: $n_stuck")"

# The off switch, for one Mac: nothing is started and nothing deleted, and the warning falls back to
# the count and the commands, saying the automatic delete is off so the switch is never forgotten
# (L523).
DD4="$TMPROOT/nudge-derived-data-off"; SW4="$TMPROOT/sweep-4"
dd_folder "$DD4" Off-orphan "$TMPROOT/removed-off/App.xcodeproj"
n_off="$(dd_nudge sess-off "$DD4" "$SW4" FREE_SPACE_DERIVED_DATA_AUTO_DELETE=0)"
check "with the off switch the warning says automatic deletion is off on this Mac" \
  "$(grep -qF 'is off on this Mac' <<< "$n_off" && echo ok || echo "said: $n_off")"
check "and falls back to the count" \
  "$(grep -qF 'Xcode build caches whose project folder is gone: 1 folder(s)' <<< "$n_off" && echo ok || echo "said: $n_off")"
check "and hands over the command that deletes them" \
  "$(grep -qxF 'bash ~/.claude/hooks/derived-data-sweep.sh --delete' <<< "$n_off" && echo ok || echo "said: $n_off")"
check "and started no sweep" "$([ ! -e "$SW4/in-progress" ] && [ "$(run_logs "$SW4")" = 0 ] && echo ok || echo "a sweep was started in $SW4")"
check "and deleted nothing" "$([ -d "$DD4/Off-orphan" ] && echo ok || echo "Off-orphan was removed")"
# A value that is neither 0 nor 1 keeps the caches (L50): an unreadable switch never deletes.
n_odd="$(dd_nudge sess-odd "$DD4" "$SW4" FREE_SPACE_DERIVED_DATA_AUTO_DELETE=maybe)"
check "a switch that is neither 0 nor 1 is said and treated as off" \
  "$(grep -qF "FREE_SPACE_DERIVED_DATA_AUTO_DELETE is set to 'maybe'" <<< "$n_odd" && [ "$(run_logs "$SW4")" = 0 ] && [ -d "$DD4/Off-orphan" ] && echo ok || echo "said: $n_odd")"
# The whole count is bounded, not only the sizing inside it: reading every folder's info.plist forks
# a reader per folder, so a DerivedData with hundreds of folders could otherwise carry the hook past
# its 10 second timeout (a setting, not a measurement) and lose the free space warning with it.
#
# Judged by STATE, never by seconds (claude-config#1620, L290). These were "returned within 5 s",
# which a loaded Mac reaches with nothing broken. The stand in sweep logs each call (its pid and its
# argument) and then HOLDS until the suite releases it, with a ceiling only a hang reaches, so it can
# end on its own only if nothing stopped it. When the warning returns, every call the bound stopped
# must be GONE (killed, its group with it), which is untrue only if the warning waited for it; and
# which calls were made says whether the bound was one for the whole step or one per call.
SLOW_SWEEP="$TMPROOT/slow-sweep.sh"
cat > "$SLOW_SWEEP" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\$\$" "\${1:-}" >> "\$SWEEP_CALLS"
n=0; while [ ! -e "\$SWEEP_RELEASE" ] && [ "\$n" -lt $((HANG_S * 10)) ]; do sleep 0.1; n=\$((n + 1)); done
echo "should never be printed"
SH
# One that answers --last at once and holds only on --start.
STALL_START="$TMPROOT/stall-start-sweep.sh"
cat > "$STALL_START" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\$\$" "\${1:-}" >> "\$SWEEP_CALLS"
if [ "\${1:-}" = --start ]; then
  n=0; while [ ! -e "\$SWEEP_RELEASE" ] && [ "\$n" -lt $((HANG_S * 10)) ]; do sleep 0.1; n=\$((n + 1)); done
fi
echo "should never be printed"
SH
calls_of(){ awk '{ print $2 }' "$1" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
# The calls still RUNNING (a stopped one not yet reaped runs nothing), or nothing.
calls_running(){
  local p r=""
  for p in $(awk '{ print $1 }' "$1" 2>/dev/null); do
    kill -0 "$p" 2>/dev/null || continue
    case "$(ps -o stat= -p "$p" 2>/dev/null)" in *Z*|'') ;; *) r="$r $p" ;; esac
  done
  printf '%s' "${r# }"
}
bound_nudge(){   # bound_nudge <session> <sweep> <seconds> [VAR=value...] -> prints all output
  local sess="$1" sw="$2" secs="$3"; shift 3
  mkdir -p "$TMPROOT/ns-$sess"
  payload "$sess" | env FREE_SPACE_BYTES="$((7 * GB))" FREE_SPACE_NOW="$T0" FREE_SPACE_STATE_DIR="$TMPROOT/ns-$sess" \
    FREE_SPACE_PATH=/fixture FREE_SPACE_DERIVED_DATA_SWEEP="$sw" FREE_SPACE_DERIVED_DATA_SECONDS="$secs" \
    FREE_SPACE_NUDGE_STATE_DIR="$NSTATE" SWEEP_CALLS="$TMPROOT/calls-$sess" SWEEP_RELEASE="$TMPROOT/release-$sess" "$@" bash "$NUDGE" 2>&1
}
n_slow="$(bound_nudge sess-slow "$SLOW_SWEEP" 1 FREE_SPACE_DERIVED_DATA_AUTO_DELETE=0)"
left_running="$(calls_running "$TMPROOT/calls-sess-slow")"; : > "$TMPROOT/release-sess-slow"
check "a count that runs past its bound is stopped, and the warning still arrives" \
  "$(grep -q 'GB free on' <<< "$n_slow" && [ "$(calls_of "$TMPROOT/calls-sess-slow")" = --summary ] && [ -z "$left_running" ] && echo ok || echo "calls: $(calls_of "$TMPROOT/calls-sess-slow"), still running when it returned: '${left_running}', said: $n_slow")"
check "and the notice says the count did not finish rather than saying nothing" \
  "$(grep -qF 'did not finish within 1s' <<< "$n_slow" && ! grep -qF 'should never be printed' <<< "$n_slow" && echo ok || echo "said: $n_slow")"
# The same bound holds the steps that report the last sweep and start the next one, which normally
# answer at once: a sweep script that hangs there must not carry the hook past its timeout either.
n_slow_auto="$(bound_nudge sess-slow-auto "$SLOW_SWEEP" 1)"
left_running="$(calls_running "$TMPROOT/calls-sess-slow-auto")"; : > "$TMPROOT/release-sess-slow-auto"
check "a sweep script that hangs when asked to start is stopped, and the warning still arrives" \
  "$(grep -q 'GB free on' <<< "$n_slow_auto" && [ -z "$left_running" ] && ! grep -qF 'should never be printed' <<< "$n_slow_auto" && echo ok || echo "still running when it returned: '${left_running}', said: $n_slow_auto")"
check "and the notice says reading the last sweep did not answer rather than saying nothing" \
  "$(grep -qF 'did not answer within 1s' <<< "$n_slow_auto" && ! grep -qF 'Started clearing' <<< "$n_slow_auto" && echo ok || echo "said: $n_slow_auto")"
# A sweep script that answers --last at once but hangs on --start reaches the start's own bound.
n_stall="$(bound_nudge sess-stall "$STALL_START" 2)"
left_running="$(calls_running "$TMPROOT/calls-sess-stall")"; : > "$TMPROOT/release-sess-stall"
check "a start that hangs is stopped at the bound, and the notice says whether it started is not known" \
  "$([ "$(calls_of "$TMPROOT/calls-sess-stall")" = "--last --start" ] && [ -z "$left_running" ] && grep -qF 'Starting the automatic sweep of Xcode build caches did not answer within' <<< "$n_stall" && ! grep -qF 'Started clearing' <<< "$n_stall" && echo ok || echo "calls: $(calls_of "$TMPROOT/calls-sess-stall"), still running when it returned: '${left_running}', said: $n_stall")"
# The bound is for the whole Xcode step, not for each call in it: reading the last result and
# starting the next sweep are two calls, and two full bounds back to back (12 seconds at the default
# of 6) would carry the hook past its 10 second timeout (settings, not measurements). With a 3 second
# bound and a --last that hangs, the step must end inside one bound: --last spends all of it, so
# --start is never called. One bound per call would call it.
n_slow_sum="$(bound_nudge sess-slow-sum "$SLOW_SWEEP" 3)"
left_running="$(calls_running "$TMPROOT/calls-sess-slow-sum")"; : > "$TMPROOT/release-sess-slow-sum"
check "the bound covers the whole Xcode step, so two hanging calls cannot add up past it" \
  "$([ "$(calls_of "$TMPROOT/calls-sess-slow-sum")" = --last ] && [ -z "$left_running" ] && grep -q 'GB free on' <<< "$n_slow_sum" && echo ok || echo "calls: $(calls_of "$TMPROOT/calls-sess-slow-sum"), still running when it returned: '${left_running}', said: $n_slow_sum")"
check "and a sweep it had no time left to start is said, never claimed" \
  "$(grep -qF 'no time was left to start' <<< "$n_slow_sum" && ! grep -qF 'Started clearing' <<< "$n_slow_sum" && echo ok || echo "said: $n_slow_sum")"
# Zero turns the count off. Handed to perl's alarm it would mean no bound at all, the opposite of
# what a zero reads as. Off means the sweep is never called.
n_zero="$(bound_nudge sess-zero "$SLOW_SWEEP" 0)"
: > "$TMPROOT/release-sess-zero"
check "a bound of 0 turns the count off rather than leaving it unbounded" \
  "$(grep -q 'GB free on' <<< "$n_zero" && [ -z "$(calls_of "$TMPROOT/calls-sess-zero")" ] && ! grep -qF 'should never be printed' <<< "$n_zero" && echo ok || echo "calls: $(calls_of "$TMPROOT/calls-sess-zero"), said: $n_zero")"
NS_DD="$TMPROOT/ns-dd"; mkdir -p "$NS_DD"
n_dd_fine="$(payload sess-dd-fine | FREE_SPACE_BYTES="$((200 * GB))" FREE_SPACE_NOW="$T0" FREE_SPACE_STATE_DIR="$NS_DD" \
  FREE_SPACE_PATH=/fixture XCODE_DERIVED_DATA_ROOT="$DD_ROOT" FREE_SPACE_NUDGE_STATE_DIR="$NSTATE" bash "$NUDGE" 2>&1)"
check "a disk with room says nothing about Xcode caches either" \
  "$([ -z "$n_dd_fine" ] && echo ok || echo "said: $n_dd_fine")"

# A check that could not run must reach the person too, or the one state where the warning matters
# most is the one that says nothing (L98).
NS3="$TMPROOT/ns3"; mkdir -p "$NS3"
n_blind="$(payload sess-blind | FREE_SPACE_BYTES=nonsense FREE_SPACE_NOW="$T0" \
  FREE_SPACE_STATE_DIR="$NS3" FREE_SPACE_PATH=/fixture FREE_SPACE_NUDGE_STATE_DIR="$NSTATE" \
  bash "$NUDGE" 2>&1)"; n_blind_rc=$?
check "a check that could not measure is reported rather than passed over" \
  "$(grep -qi 'could not' <<< "$n_blind" && echo ok || echo "said: $n_blind")"
check "and still does not block the prompt" "$([ "$n_blind_rc" -eq 0 ] && echo ok || echo "exit $n_blind_rc")"

# The hook is wired, not merely written: built is not wired (L3).
#
# WHERE the hooks block lives depends on which copy of the tree this is running from. In the repo
# it is payload/settings.hooks.json. Installed under ~/.claude it is the hooks section of
# settings.json, which is the file Claude Code actually reads and the only copy that makes the hook
# fire. The first version of this named the repo's spelling alone, so it passed in the checkout and
# failed on the machine the config was installed on, which is the side where wired actually means
# something. Caught by the hook suite claude-sync runs after a pull.
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
# Neither being there is NOT a pass. A check with no file to read would otherwise answer exactly as
# one that found the hook properly wired (L98).
check "there is a settings file holding the hooks block to read" \
  "$([ -n "$SETTINGS" ] && echo ok || echo "neither settings.hooks.json nor settings.json beside $DIR")"
check "the nudge is named in the hooks block that is actually loaded" \
  "$([ -n "$SETTINGS" ] && grep -q 'free-space-nudge.sh' "$SETTINGS" 2>/dev/null && echo ok || echo "not in ${SETTINGS:-<no settings file>}")"

# The skill the notice points at has to exist, or the remedy names nothing (L111).
SKILL="$DIR/../skills/disk-full/SKILL.md"
check "the disk-full skill the notice names is actually there" \
  "$([ -f "$SKILL" ] && echo ok || echo "no skill at $SKILL")"
check "and it holds the triage sequence rather than a heading and a promise" \
  "$(grep -q 'df -h' "$SKILL" 2>/dev/null && grep -q 'du -x' "$SKILL" 2>/dev/null && echo ok || echo "no measured sequence in $SKILL")"
check "and it names the macOS symbol cache with the command that sizes it" \
  "$(grep -qF 'sudo du -sh /System/Library/Caches/com.apple.coresymbolicationd' "$SKILL" 2>/dev/null && echo ok || echo "no symbol cache step in $SKILL")"
# The one deleting command must be the same in both places, so the skill cannot drift from what
# the warning hands Dan (L41). Read from the warning's own output rather than typed again here.
sym_clear="$(grep -F 'sudo find ' <<< "$sym_low")"
check "and its clearing command is the very one the warning prints" \
  "$([ -n "$sym_clear" ] && grep -qxF "$sym_clear" "$SKILL" 2>/dev/null && echo ok || echo "warning prints '$sym_clear', not found as a line in $SKILL")"

# And the top command the warning hands over for swap is the very one the skill's swap step runs,
# read from the warning's own output (claude-config#1769, #1770).
swap_top="$(grep -F 'top -l 1 ' <<< "$swap_big")"
check "and the skill's swap step runs the very top command the warning prints" \
  "$([ -n "$swap_top" ] && grep -qxF "$swap_top" "$SKILL" 2>/dev/null && echo ok || echo "warning prints '$swap_top', not found as a line in $SKILL")"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
