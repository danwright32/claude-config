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

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
for bad_setting in FREE_SPACE_FLOOR_GB FREE_SPACE_HORIZON_HOURS FREE_SPACE_MIN_SPAN_MIN FREE_SPACE_WINDOW_HOURS; do
  S_BAD="$TMPROOT/state-bad-$bad_setting"; mkdir -p "$S_BAD"
  bad_msg="$(env "$bad_setting=abc" FREE_SPACE_BYTES="$((1 * GB))" FREE_SPACE_NOW="$T0" \
    FREE_SPACE_STATE_DIR="$S_BAD" FREE_SPACE_PATH=/fixture bash "$CHECK" 2>&1)"; bad_rc=$?
  check "$bad_setting set to something that is not a number is refused, never compared against" \
    "$([ "$bad_rc" -eq 2 ] && grep -qi 'could not' <<< "$bad_msg" && echo ok || echo "exit $bad_rc, said: $bad_msg")"
  check "and the refusal names which setting it was, so it can be fixed" \
    "$(grep -q "$bad_setting" <<< "$bad_msg" && echo ok || echo "said: $bad_msg")"
done

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
many_lines="$(cat "$S_MANY"/* 2>/dev/null | grep -c . || true)"
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
SETTINGS="$DIR/../settings.hooks.json"
check "the nudge is named in the synced hooks block" \
  "$(grep -q 'free-space-nudge.sh' "$SETTINGS" 2>/dev/null && echo ok || echo "not in $SETTINGS")"

# The skill the notice points at has to exist, or the remedy names nothing (L111).
SKILL="$DIR/../skills/disk-full/SKILL.md"
check "the disk-full skill the notice names is actually there" \
  "$([ -f "$SKILL" ] && echo ok || echo "no skill at $SKILL")"
check "and it holds the triage sequence rather than a heading and a promise" \
  "$(grep -q 'df -h' "$SKILL" 2>/dev/null && grep -q 'du -x' "$SKILL" 2>/dev/null && echo ok || echo "no measured sequence in $SKILL")"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
