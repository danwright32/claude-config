#!/usr/bin/env bash
#
# check-free-space.sh: is the disk about to fill (claude-config#363)?
#
# On 2026-09-10 the boot volume hit zero free space. The first sign of it inside Claude Code was an
# unrelated hook failing with "cannot create temp file for here document", followed by every Bash
# call failing with ENOSPC before it could run. Reaching the actual cause took about forty minutes,
# most of it rediscovering a sequence of read only commands. A full disk is the one state where the
# tool that would diagnose it cannot run, so the warning has to arrive while there is still room to
# act, and the sequence has to be written down in advance. That sequence is the disk-full skill;
# this is the warning.
#
# It answers with an EXIT CODE, and a caller must judge by that rather than by a line of the output
# (L184). The four answers are kept apart on purpose, because a check that reports "fine" when it
# could not read anything is indistinguishable from a healthy disk (L98, L11):
#
#   0  measured, and there is room
#   2  COULD NOT MEASURE, which is not the same as fine
#   3  under the floor
#   4  above the floor, but falling fast enough to reach zero inside the horizon
#
# WHY BOTH 3 AND 4. A floor alone is a threshold nobody measured: at the rate seen that night
# (about 19 GB an hour) a 20 GB floor is one hour of notice, which is not enough to find out what
# is writing. A rate alone says nothing about a disk that is already nearly full and not moving.
# Neither answers for the other, so both are here (L53).
#
# WHY THE RATE IS REFUSED MORE OFTEN THAN IT IS GIVEN. Two readings a few minutes apart measure
# whatever happened to be writing between two prompts, and extrapolating that produces a
# catastrophe on every ordinary build. So a rate is reported only across a span of real length, and
# only from readings inside a window this can honestly describe. Refusing is the common case, and
# it is what keeps the warning worth reading (L36, L253).
#
# IT NAMES NO CAUSE. It reports how much is left and, when it can, how fast that is falling. What
# is eating the disk is the skill's job, from measurements taken at the time (L11: a message may
# claim only what its check measured).
#
# Environment, all of it a seam so the suite measures this code rather than the machine (L2, L504):
#   FREE_SPACE_PATH           the volume to measure (default the data volume, else /)
#   FREE_SPACE_BYTES          a reading supplied directly, instead of running df
#   FREE_SPACE_NOW            epoch seconds, instead of the clock
#   FREE_SPACE_FLOOR_GB       the floor (default 20)
#   FREE_SPACE_HORIZON_HOURS  reaching zero within this many hours is "falling fast" (default 6)
#   FREE_SPACE_MIN_SPAN_MIN   no rate is reported from a span shorter than this (default 10)
#   FREE_SPACE_WINDOW_HOURS   readings older than this are pruned and never used (default 6)
#   FREE_SPACE_RECOVERY_GB    a rise larger than this means the disk recovered, so no rate
#   FREE_SPACE_STATE_DIR      where the readings are kept
set -uo pipefail

GIB=$((1024 * 1024 * 1024))

VOLUME="${FREE_SPACE_PATH:-}"
if [ -z "$VOLUME" ]; then
  # The data volume is where a Mac's home directory actually lives; / is the read only system
  # snapshot and reports headroom that has nothing to do with anybody's files.
  if [ -d /System/Volumes/Data ]; then VOLUME=/System/Volumes/Data; else VOLUME=/; fi
fi
FLOOR_GB="${FREE_SPACE_FLOOR_GB:-20}"
HORIZON_HOURS="${FREE_SPACE_HORIZON_HOURS:-6}"
MIN_SPAN_MIN="${FREE_SPACE_MIN_SPAN_MIN:-10}"
WINDOW_HOURS="${FREE_SPACE_WINDOW_HOURS:-6}"
# A reading higher than an earlier one by MORE than this is a recovery rather than jitter.
# Every write and delete on a live machine moves the number a little, so a rule that refused
# on any increase at all would refuse always, which is the same as deleting the warning.
RECOVERY_GB="${FREE_SPACE_RECOVERY_GB:-1}"
STATE_DIR="${FREE_SPACE_STATE_DIR:-${TMPDIR:-/tmp}/claude-free-space}"

cannot(){   # $1 = what could not be done
  echo "claude-sync: could not measure free space on $VOLUME ($1), so nothing here says whether the disk is filling. Check it by hand with: df -h $VOLUME"
  exit 2
}

is_number(){ case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# THE SETTINGS ARE VALIDATED TOO, not only the reading (L50). A floor of "abc" makes every
# arithmetic test below error, which the shell reads as false, so the check falls through to "there
# is room" on a disk with 1 GB left. A value parsed from input that feeds a comparison directly
# lands on the permissive side when it is bad, and nothing says so. Refused here instead, by name,
# because a message that does not say which of the four is wrong cannot be acted on (L11, L80).
for _setting in FREE_SPACE_FLOOR_GB:"$FLOOR_GB" FREE_SPACE_HORIZON_HOURS:"$HORIZON_HOURS"                 FREE_SPACE_MIN_SPAN_MIN:"$MIN_SPAN_MIN" FREE_SPACE_WINDOW_HOURS:"$WINDOW_HOURS" FREE_SPACE_RECOVERY_GB:"$RECOVERY_GB"; do
  is_number "${_setting#*:}" || cannot "${_setting%%:*} is set to '${_setting#*:}', which is not a number"
done

now="${FREE_SPACE_NOW:-$(date +%s 2>/dev/null || true)}"
is_number "$now" || cannot "the clock gave '$now'"

if [ -n "${FREE_SPACE_BYTES:-}" ]; then
  free_bytes="$FREE_SPACE_BYTES"
else
  # -k, so the unit is stated rather than inherited from whatever BLOCKSIZE happens to be set to in
  # the environment this hook is invoked from. -P, so a long device name cannot wrap onto a second
  # line and make the row this reads a continuation of the header rather than the answer: the POSIX
  # format guarantees one line per filesystem, and macOS and Linux agree on it.
  avail_k="$(df -Pk "$VOLUME" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
  is_number "$avail_k" || cannot "df said '${avail_k:-<nothing>}'"
  free_bytes=$((avail_k * 1024))
fi
is_number "$free_bytes" || cannot "the reading was '$free_bytes'"

free_gb=$((free_bytes / GIB))

# ---------- the readings, which are what makes a rate possible at all ----------
# Keyed on the volume, so measuring two of them never mixes their histories (L15).
key="$(printf '%s' "$VOLUME" | tr -c 'A-Za-z0-9' '_')"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE="$STATE_DIR/$key"

cutoff=$((now - WINDOW_HOURS * 3600))
kept=""
oldest_t=""
oldest_b=""
if [ -f "$STATE" ]; then
  while IFS=' ' read -r t b _rest; do
    is_number "$t" || continue
    is_number "$b" || continue
    # Anything at or past this instant is a reading from a clock that has moved backwards, or a
    # leftover from a run with a pinned time. Dropped rather than used as the other end of a span.
    [ "$t" -lt "$now" ] || continue
    [ "$t" -ge "$cutoff" ] || continue
    kept="$kept$t $b
"
    if [ -z "$oldest_t" ] || [ "$t" -lt "$oldest_t" ]; then oldest_t="$t"; oldest_b="$b"; fi
  done < "$STATE"
fi

# Written to a temp file and moved into place, so a run interrupted mid write leaves the previous
# readings rather than a truncated file (L5).
tmp="$STATE.$$"
{ printf '%s' "$kept"; printf '%s %s\n' "$now" "$free_bytes"; } > "$tmp" 2>/dev/null \
  && mv -f "$tmp" "$STATE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true

# ---------- did it ever go back up? ----------
# A SAWTOOTH IS NOT A FALL (claude-config#436). The rate used to come from the oldest reading and
# the newest, and every reading in between was kept and then ignored, so two points set the verdict
# however the disk behaved between them.
#
# That is not a rare shape, it is the ordinary one: an Xcode test build takes tens of GB and gives
# every one of them back when it finishes. Measured on 2026-09-18, three notices went out in a
# morning claiming 23, 135 and 163 GB an hour while the disk sat far above the floor the whole time.
#
# A rate is a claim about a TREND, and a series that recovered has no trend BEFORE the recovery.
# So the trend is measured only from the readings SINCE the last recovery.
#
# NOT "refuse once it has ever recovered", which was the first version of this fix and was wrong in
# the costly direction: a recovery is exactly what a finishing build looks like, so a genuine fill
# starting afterwards, a backup say, went unreported for up to the whole window. That is the failure
# this warning exists to prevent, and it is the shape L695 names: stand down on recent samples, never
# on an aggregate that cannot let go of an old event.
#
# AFTER A RECOVERY, TWO READINGS ARE NOT ENOUGH. The machine has just shown it gives space back, and
# two points after a recovery are one tooth of the same sawtooth: the 150 then 86 in the fixture is
# a build taking its space again, not a trend. So a segment that follows a recovery needs at least
# three readings falling together before it is believed (L656: several samples, never one pair).
# A series that has NOT recovered keeps the two reading rate it always had, because nothing has
# shown that machine is oscillating.
#
# Sorted by time rather than trusted to be in order: the file is appended to, but a clock that
# moved or a run with a pinned time can put a line out of sequence, and comparing unsorted readings
# would invent a recovery that never happened.
recovered=0
seg_t=""; seg_b=""; seg_n=0
_prev_b=""
while IFS=' ' read -r _t _b; do
  is_number "${_t:-}" || continue
  is_number "${_b:-}" || continue
  if [ -n "$_prev_b" ] && [ $((_b - _prev_b)) -gt $((RECOVERY_GB * GIB)) ]; then
    recovered=1; seg_t="$_t"; seg_b="$_b"; seg_n=1
  elif [ -z "$seg_t" ]; then
    seg_t="$_t"; seg_b="$_b"; seg_n=1
  else
    seg_n=$((seg_n + 1))
  fi
  _prev_b="$_b"
done <<EOF
$(printf '%s%s %s\n' "$kept" "$now" "$free_bytes" | sort -n -k1,1)
EOF

# The other end of the span is the start of the current segment: the oldest reading when nothing
# recovered, the reading the disk recovered TO when something did.
if [ "$recovered" -eq 1 ] && [ "$seg_n" -lt 3 ]; then
  oldest_t=""
elif [ -n "$seg_t" ] && [ "$seg_t" -lt "$now" ]; then
  oldest_t="$seg_t"; oldest_b="$seg_b"
else
  oldest_t=""
fi

# ---------- the rate, when there is one worth stating ----------
rate_clause=""
falling_fast=0
if [ -n "$oldest_t" ]; then
  span=$((now - oldest_t))
  fall=$((oldest_b - free_bytes))
  if [ "$span" -ge $((MIN_SPAN_MIN * 60)) ] && [ "$fall" -gt 0 ]; then
    rate_gb=$(( (fall * 3600 / span) / GIB ))
    # Seconds rather than hours, so a fall that empties the disk inside an hour is not rounded down
    # to zero hours and read as no time at all.
    to_zero=$((free_bytes * span / fall))
    if [ "$span" -ge 3600 ]; then span_words="$((span / 3600)) hour(s)"; else span_words="$((span / 60)) minute(s)"; fi
    if [ "$to_zero" -ge 3600 ]; then zero_words="about $((to_zero / 3600)) hour(s)"; else zero_words="under an hour"; fi
    rate_clause=" It is falling at about $rate_gb GB per hour, measured over the last $span_words, which reaches zero in $zero_words."
    [ "$to_zero" -le $((HORIZON_HOURS * 3600)) ] && falling_fast=1
  fi
fi

if [ "$free_gb" -lt "$FLOOR_GB" ]; then
  echo "claude-sync: only $free_gb GB free on $VOLUME, under the $FLOOR_GB GB floor.$rate_clause Nothing here says what is using it."
  exit 3
fi

if [ "$falling_fast" -eq 1 ]; then
  echo "claude-sync: $free_gb GB free on $VOLUME, which is above the $FLOOR_GB GB floor but not for long.$rate_clause Nothing here says what is using it."
  exit 4
fi

exit 0
