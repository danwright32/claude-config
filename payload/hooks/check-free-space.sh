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
# IT MEASURES NO CAUSE. It reports how much is left and, when it can, how fast that is falling. What
# is eating the disk is the skill's job, from measurements taken at the time (L11: a message may
# claim only what its check measured).
#
# ONE SUSPECT IS NAMED, AND SAID TO BE UNMEASURED. This does not contradict the paragraph above:
# the message still says nothing measured a cause, and names the folder as somewhere to look, never
# as what is using the disk. Measured 2026-10-04 on
# Daniels-MacBook-Pro-2: the disk fell from 25 GB to 8 GB free more than once while Overture agents
# built and crash tested, and neither this warning nor the disk-full skill could see why. Dan's
# cleaner app found /System/Library/Caches/com.apple.coresymbolicationd at 194 GB. That is macOS's
# symbol cache (coresymbolicationd(8)), added to whenever a crash report is written or a process is
# sampled (sample, spindump, Instruments), so every fresh build of an app that crashes or is sampled
# adds more. It is root only (drwx------ root wheel), so its size cannot be read here and the
# message says so rather than implying one. What CAN be read is the folder's own change time, which
# moves when a file is added or removed (not when one grows), so that is stated as exactly that.
# Clearing it is Dan's call and needs his password, so the message hands him the commands and runs
# nothing, sizing first and clearing only if Dan decides to. The folder carries no SIP restricted
# flag (ls -lO shows none), so sudo can empty it. `find -mindepth 1 -delete` rather than `rm -rf
# dir/*`: it takes hidden files too, and needs no glob, which Dan's zsh would refuse before sudo ran
# because his user cannot list the folder. Emptying rather than removing the folder keeps its root
# only permissions in place.
#
# Environment, all of it a seam so the suite measures this code rather than the machine (L2, L504):
#   FREE_SPACE_PATH           the volume to measure (default the data volume, else /)
#   FREE_SPACE_BYTES          a reading supplied directly, instead of running df
#   FREE_SPACE_NOW            epoch seconds, instead of the clock
#   FREE_SPACE_FLOOR_GB       the floor in GiB (default 20); the warning words it, like every size, by dcu_human
#   FREE_SPACE_HORIZON_HOURS  reaching zero within this many hours is "falling fast" (default 6)
#   FREE_SPACE_MIN_SPAN_MIN   no rate is reported from a span shorter than this (default 10)
#   FREE_SPACE_WINDOW_HOURS   readings older than this are pruned and never used (default 6)
#   FREE_SPACE_RECOVERY_GB    a rise larger than this means the disk recovered, so no rate
#   FREE_SPACE_PERSIST_MIN    only a fall that has lasted this long is projected (default 30, #1754)
#   FREE_SPACE_STATE_DIR      where the readings are kept
#   FREE_SPACE_SYMBOL_CACHE   the macOS symbol cache folder to look for (default the real one)
#   FREE_SPACE_SWAP_SHARE_PCT swap above this share of the disk names the memory holders (default 2)
#   FREE_SPACE_TOP_SECONDS    the bound on `top` when it names them (default 2, 0 turns it off)
#   FREE_SPACE_SWAP_CMD, FREE_SPACE_TOP_CMD, FREE_SPACE_DISK_BYTES  the swap, top and disk size
#                             readers, described where swap is read (claude-config#1770)
#
# ONE CAUSE IS MEASURED: SWAP (claude-config#1770). Swap lives on a volume of its own that shares
# the disk and that no folder size reaches, so when it is over its share of the disk the verdict says
# so, from sysctl, and names the processes holding the most memory, from top. That is a measurement,
# so the first line says swap is measured below rather than that nothing is.
#
# ONE ARGUMENT, --report (claude-config#683). The disk-full skill's rate step reads this check
# rather than measuring a rate a second way: its own copy used awk strftime, which macOS awk does
# not have, and a five minute foreground sleep the Bash tool refuses. Without --report a disk with
# room prints nothing, which is right for a warning run on every prompt and useless to somebody
# triaging. With it, every verdict says how much is left and then either the rate or exactly why
# there is none (first reading, span too short, a recovery, not falling). The exit codes are the
# same four either way. Anything else on the command line is refused rather than ignored, because a
# mistyped flag would otherwise run the quiet mode and read as a report with nothing in it (L320).
set -uo pipefail

REPORT=0
for _arg in "$@"; do
  case "$_arg" in
    --report) REPORT=1 ;;
    *) echo "claude-sync: check-free-space.sh does not know the argument '$_arg' (the only one is --report), so it measured nothing."; exit 2 ;;
  esac
done

GIB=$((1024 * 1024 * 1024))

# Every size this warning states is worded by lib/disk-clean-units.sh, the one rule disk-clean's
# scan, review page and disk-remove use (decimal units as Finder writes them, #1807), so the free
# space, the floor, the rate, swap and the scan's total read in one unit on one warning (L118).
# Only the words: every threshold is still compared in GiB, as before. Should the library not
# load, the warning still speaks, in GiB and saying so, rather than not at all (L71).
_fs_here="."; case "${BASH_SOURCE[0]}" in */*) _fs_here="${BASH_SOURCE[0]%/*}" ;; esac
. "$_fs_here/lib/disk-clean-units.sh" 2>/dev/null || true
fs_words_to(){ # <variable> <bytes>: the size in words, with no process started
  if declare -F dcu_human_to >/dev/null; then dcu_human_to "$1" $(( $2 / 1024 )); else printf -v "$1" '%s GiB' $(( $2 / GIB )); fi
}

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
PERSIST_MIN="${FREE_SPACE_PERSIST_MIN:-30}"
SWAP_SHARE_PCT="${FREE_SPACE_SWAP_SHARE_PCT:-2}"
TOP_SECONDS="${FREE_SPACE_TOP_SECONDS:-2}"
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
for _setting in FREE_SPACE_FLOOR_GB:"$FLOOR_GB" FREE_SPACE_HORIZON_HOURS:"$HORIZON_HOURS" \
                FREE_SPACE_MIN_SPAN_MIN:"$MIN_SPAN_MIN" FREE_SPACE_WINDOW_HOURS:"$WINDOW_HOURS" FREE_SPACE_RECOVERY_GB:"$RECOVERY_GB" \
                FREE_SPACE_PERSIST_MIN:"$PERSIST_MIN" FREE_SPACE_SWAP_SHARE_PCT:"$SWAP_SHARE_PCT" FREE_SPACE_TOP_SECONDS:"$TOP_SECONDS"; do
  is_number "${_setting#*:}" || cannot "${_setting%%:*} is set to '${_setting#*:}', which is not a number"
done

now="${FREE_SPACE_NOW:-$(date +%s 2>/dev/null || true)}"
is_number "$now" || cannot "the clock gave '$now'"

# The disk's whole size, which the swap share is a share of (claude-config#1770). Read from the same
# df row as the free space when df is run; a reading supplied directly carries no size unless one is
# supplied beside it, and then the swap share is said to be unread rather than guessed.
disk_bytes="${FREE_SPACE_DISK_BYTES:-}"
if [ -n "${FREE_SPACE_BYTES:-}" ]; then
  free_bytes="$FREE_SPACE_BYTES"
else
  # -k, so the unit is stated rather than inherited from whatever BLOCKSIZE happens to be set to in
  # the environment this hook is invoked from. -P, so a long device name cannot wrap onto a second
  # line and make the row this reads a continuation of the header rather than the answer: the POSIX
  # format guarantees one line per filesystem, and macOS and Linux agree on it.
  df_row="$(df -Pk "$VOLUME" 2>/dev/null | awk 'NR == 2 { print $2, $4 }' || true)"
  avail_k="${df_row#* }"
  is_number "$avail_k" || cannot "df said '${avail_k:-<nothing>}'"
  free_bytes=$((avail_k * 1024))
  size_k="${df_row%% *}"
  if [ -z "$disk_bytes" ] && is_number "$size_k"; then disk_bytes=$((size_k * 1024)); fi
fi
is_number "$free_bytes" || cannot "the reading was '$free_bytes'"

free_gb=$((free_bytes / GIB))
fs_words_to free_words "$free_bytes"; fs_words_to floor_words $((FLOOR_GB * GIB))

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
seg_lines=""   # every reading of the current segment, oldest first, for the persistence rule below
_prev_b=""
while IFS=' ' read -r _t _b; do
  is_number "${_t:-}" || continue
  is_number "${_b:-}" || continue
  if [ -n "$_prev_b" ] && [ $((_b - _prev_b)) -gt $((RECOVERY_GB * GIB)) ]; then
    recovered=1; seg_t="$_t"; seg_b="$_b"; seg_n=1; seg_lines=""
  elif [ -z "$seg_t" ]; then
    seg_t="$_t"; seg_b="$_b"; seg_n=1
  else
    seg_n=$((seg_n + 1))
  fi
  seg_lines="$seg_lines$_t $_b
"
  _prev_b="$_b"
done <<EOF
$(printf '%s%s %s\n' "$kept" "$now" "$free_bytes" | sort -n -k1,1)
EOF

# The other end of the span is the start of the current segment: the oldest reading when nothing
# recovered, the reading the disk recovered TO when something did.
# Why no rate is stated, kept for --report, which owes the reader the reason (L540: an absent
# answer carries a measured reason, never membership by failing to match the good case).
no_rate_clause=""
if [ -z "$kept" ]; then
  oldest_t=""
  no_rate_clause=" No rate yet: this is the first reading in the last $WINDOW_HOURS hour(s), so there is nothing to compare it with."
elif [ "$recovered" -eq 1 ] && [ "$seg_n" -lt 3 ]; then
  oldest_t=""
  no_rate_clause=" No rate: free space went back up by more than $RECOVERY_GB GB within the last $WINDOW_HOURS hour(s), which is space being given back, and too few readings have been taken since then to state a trend."
elif [ -n "$seg_t" ] && [ "$seg_t" -lt "$now" ]; then
  oldest_t="$seg_t"; oldest_b="$seg_b"
else
  oldest_t=""
  no_rate_clause=" No rate: there is no earlier reading to compare with."
fi

# ---------- the rate, when there is one worth stating ----------
# ONLY A FALL THAT HAS LASTED IS PROJECTED (claude-config#1754). Measured 2026-10-26 on the work
# MacBook: Claude sessions' pre push checks (lint, a production build and the test suite in a
# temporary tree, plus a local database stack) each took 1.4 to 4.4 GB and gave most of it back
# minutes later, two of them inside 27 minutes (36.0 GB free at 11:00 ET, 36.2 GB at 11:27). The
# recovery rule above helps only once a burst has given its space back. While one was still in
# progress, the oldest reading and the bottom of the dip made a slope, and the warning said "17 GB
# per hour ... zero in about 2 hour(s)" for space that came back within minutes (L36).
#
# So the newer end of the rate is not the latest reading but the MOST free space seen in the last
# FREE_SPACE_PERSIST_MIN minutes (default 30, longer than both bursts measured that morning took to
# fill and give back): the level the disk has stayed at or below for that long, which is the least
# space the disk has been USING over it. A dip that comes back inside the window never lowers it; a
# fall that lasts lowers it, a window late. The rate runs from the start of the segment to the
# reading that set that level, and zero is projected from that level, less the time since it.
#
# WHAT THIS COSTS, said rather than hidden (L93): a real fall is not projected until readings span
# the window, so a fast fill starting from nothing is reported up to 30 minutes later than before,
# about 10 GB at the 19 GB an hour of 2026-09-10. The floor does not wait, and it is the warning for
# a disk already nearly full. A push check that holds its space for longer than the window is still
# projected, until it gives the space back and the recovery rule takes over. 0 turns the window off,
# which is the rule as it was before #1754: the latest reading is the newer end.
rate_clause=""
falling_fast=0
if [ -n "$oldest_t" ]; then
  span=$((now - oldest_t))
  if [ "$span" -lt $((MIN_SPAN_MIN * 60)) ]; then
    no_rate_clause=" No rate yet: the readings span only $((span / 60)) minute(s), and a rate is stated only over at least $MIN_SPAN_MIN minutes."
  elif [ "$span" -lt $((PERSIST_MIN * 60)) ]; then
    no_rate_clause=" No rate yet: the readings span only $((span / 60)) minute(s), and a fall is stated only once it has lasted $PERSIST_MIN minutes, longer than a build or push check that gives its space back when it ends."
  else
    # The level held over the window, and when it was last seen. Ties go to the later reading,
    # because the disk was at that level as late as that.
    held_b=""; held_t=""
    while IFS=' ' read -r _t _b; do
      is_number "${_t:-}" || continue
      is_number "${_b:-}" || continue
      [ "$_t" -ge $((now - PERSIST_MIN * 60)) ] || continue
      if [ -z "$held_b" ] || [ "$_b" -ge "$held_b" ]; then held_b="$_b"; held_t="$_t"; fi
    done <<EOF
$seg_lines
EOF
    [ -n "$held_b" ] || { held_b="$free_bytes"; held_t="$now"; }
    fall=$((oldest_b - held_b))
    span=$((held_t - oldest_t))
    if [ "$fall" -le 0 ]; then
      if [ "$PERSIST_MIN" -gt 0 ]; then
        no_rate_clause=" It is not falling: the most free space seen in the last $PERSIST_MIN minutes is as much as there was $(((now - oldest_t) / 60)) minute(s) ago, or more, so any drop since has not lasted."
      else
        no_rate_clause=" It is not falling: there is as much free space now as there was $(((now - oldest_t) / 60)) minute(s) ago, or more."
      fi
    elif [ "$span" -lt $((MIN_SPAN_MIN * 60)) ]; then
      no_rate_clause=" No rate yet: the fall that has lasted $PERSIST_MIN minutes spans only $((span / 60)) minute(s) of readings, and a rate is stated only over at least $MIN_SPAN_MIN minutes."
    else
      fs_words_to rate_words $(( fall * 3600 / span ))
      # Seconds rather than hours, so a fall that empties the disk inside an hour is not rounded down
      # to zero hours and read as no time at all.
      to_zero=$(( held_b * span / fall - (now - held_t) ))
      [ "$to_zero" -ge 0 ] || to_zero=0
      if [ "$span" -ge 3600 ]; then span_words="$((span / 3600)) hour(s)"; else span_words="$((span / 60)) minute(s)"; fi
      if [ "$to_zero" -ge 3600 ]; then zero_words="about $((to_zero / 3600)) hour(s)"; else zero_words="under an hour"; fi
      if [ "$PERSIST_MIN" -gt 0 ]; then
        rate_clause=" It is falling at about $rate_words per hour, measured over $span_words and counting only space that has stayed gone for $PERSIST_MIN minutes, which reaches zero in $zero_words."
      else
        rate_clause=" It is falling at about $rate_words per hour, measured over the last $span_words, which reaches zero in $zero_words."
      fi
      [ "$to_zero" -le $((HORIZON_HOURS * 3600)) ] && falling_fast=1
    fi
  fi
fi

# ---------- swap, which fills this disk where no folder size reaches (claude-config#1770) ----------
# On 2026-10-26 the disk on Daniels-MacBook-Pro-2 reached 1.1 GB free and the cause was 95 GB of
# swap (`sysctl vm.swapusage`), held by two processes leaking memory: Backblaze's bzserv at 117 GB
# and fseventsd at 105 GB by top's MEM, both running since boot six days earlier. Swap is kept on
# /System/Volumes/VM, a volume of its own that shares the disk's space, so every `du` came back clean
# and this warning named only the symbol cache, which did not exist that day. A restart gave it all
# back.
#
# THE 2% IS MEASURED, AND THIN (L172). Every `sysctl vm.swapusage` reading found in this Mac's Claude
# transcripts (Daniels-MacBook-Pro-2: 96 GB of memory, a 926 GB disk), read on 2026-10-26, falls in
# two clusters with nothing between them. Ordinary days: 0 (2026-10-08, and twice on 2026-10-26 after
# the restart), 0.56 MB (2026-09-25), 136 MB (2026-10-04), all under 0.02% of the disk. Leaking: 34.6
# GB (2026-10-24, the disk at 94% used), 82.6 GB (2026-10-13), 94.7 GB (2026-10-26), 3.7% to 10.2%.
# 2% sits in the empty middle, a hundred times above the highest ordinary reading and under the
# lowest leaking one by almost half, so a small shift in either cluster moves nothing across it. The
# work MacBook has no reading at all, and a Mac with less memory swaps more on an ordinary day, which
# is why every reading is now recorded (below) and why the share is a setting,
# FREE_SPACE_SWAP_SHARE_PCT. Its false positive costs little by construction: it is said only on a
# warning that is already firing, never as a warning of its own.
#
# THE READINGS ARE RECORDED so the 2% can be recalibrated rather than re-argued: the highest reading
# of each day (UTC), with the disk's size, one line per day in <state dir>/<volume>.swap-days, the
# newest 120 days kept. The readings file beside it keeps six hours, too short to show an ordinary
# day. That is a sysctl and an awk on every prompt; `top`, which takes most of a second (0.6 s
# measured on 2026-10-26 at a load average of 159), runs only when swap is over the share AND the
# verdict is low or falling, and is bounded by FREE_SPACE_TOP_SECONDS (default 2, 0 turns it off),
# its whole process group killed when the bound runs out, so the prompt hook stays inside its 10
# second timeout with the nudge's 6 second Xcode step beside it.
#
# Environment (seams, so the suite never reads this machine's swap or runs its top, L2):
#   FREE_SPACE_SWAP_CMD   an executable printing a `sysctl vm.swapusage` line (default that command)
#   FREE_SPACE_TOP_CMD    an executable printing top's PID COMMAND MEM table (default the real top)
#   FREE_SPACE_DISK_BYTES the disk's size, instead of df's
swap_bytes=""; swap_why=""
if [ -n "${FREE_SPACE_SWAP_CMD:-}" ]; then swap_out="$("$FREE_SPACE_SWAP_CMD" 2>&1)"; else swap_out="$(sysctl vm.swapusage 2>&1)"; fi
# Read from a here string rather than a pipe: awk stops at the first match, and a producer it stops
# reading from is a failure under pipefail that never happened (L183).
swap_bytes="$(awk '{
  for (i = 1; i < NF - 1; i++) if ($i == "used" && $(i + 1) == "=") {
    v = $(i + 2); u = substr(v, length(v)); n = substr(v, 1, length(v) - 1)
    m = (u == "K") ? 1024 : (u == "M") ? 1048576 : (u == "G") ? 1073741824 : (u == "T") ? 1099511627776 : 0
    if (m && n ~ /^[0-9]+(\.[0-9]+)?$/) printf "%.0f\n", n * m
    exit
  } }' <<< "$swap_out" 2>/dev/null || true)"
if ! is_number "$swap_bytes"; then
  _said="${swap_out:-<nothing>}"; _said="${_said//$'\n'/ }"
  swap_bytes=""; swap_why="sysctl vm.swapusage said '${_said:0:120}'"
elif ! is_number "$disk_bytes" || [ "$disk_bytes" -le 0 ]; then
  swap_why="the disk's size could not be read, so swap's share of it is not known"
fi

# Over the share, swap is a measured cause, so the verdict's first line stops saying nothing here
# says what is using the disk (L11: a message claims what was measured, no less and no more).
swap_over=0
cause_clause=" Nothing here says what is using it."
if [ -z "$swap_why" ] && [ $((swap_bytes * 100)) -gt $((disk_bytes * SWAP_SHARE_PCT)) ]; then
  swap_over=1
  cause_clause=" Swap is measured below; nothing here says what else is using it."
fi

# The day's highest swap reading, kept so the share above can be recalibrated (L172).
swap_day="$(date -u -r "$now" +%F 2>/dev/null || date -u -d "@$now" +%F 2>/dev/null || true)"
if [ -n "$swap_bytes" ] && [ -n "$swap_day" ]; then
  SWAP_DAYS="$STATE.swap-days"
  _days=""; _today_max="$swap_bytes"
  if [ -f "$SWAP_DAYS" ]; then
    while IFS=' ' read -r _d _s _rest; do
      [ -n "${_d:-}" ] || continue
      if [ "$_d" = "$swap_day" ]; then
        is_number "${_s:-}" && [ "$_s" -gt "$_today_max" ] && _today_max="$_s"
        continue
      fi
      _days="$_days$_d ${_s:-} ${_rest:-}
"
    done < "$SWAP_DAYS"
  fi
  _tmp="$SWAP_DAYS.$$"
  { printf '%s' "$_days"; printf '%s %s %s\n' "$swap_day" "$_today_max" "${disk_bytes:--}"; } | tail -n 120 > "$_tmp" 2>/dev/null \
    && mv -f "$_tmp" "$SWAP_DAYS" 2>/dev/null || rm -f "$_tmp" 2>/dev/null || true
fi

swap_note(){
  local swap_words=""
  is_number "${swap_bytes:-}" && fs_words_to swap_words "$swap_bytes"
  if [ -n "$swap_why" ] && [ -n "$swap_bytes" ]; then
    # Swap WAS read; only the disk's size was not, so its share cannot be judged. Said as exactly
    # that, never as swap being unread (L11).
    echo ""
    echo "Swap holds $swap_words by sysctl vm.swapusage, but the disk's size could not be read, so whether that is a large share of this disk is not known and the processes holding it are not named here. Swap is kept on /System/Volumes/VM, which shares this disk and which no folder size reaches. To name them:"
    echo '```'
    echo "top -l 1 -o mem -n 10 -stats pid,command,mem,time"
    echo '```'
    return 0
  fi
  if [ -n "$swap_why" ]; then
    echo ""
    echo "Could not read swap here ($swap_why), so whether memory is filling this disk is not known. Swap is kept on /System/Volumes/VM, which shares this disk and which no folder size reaches. To read it:"
    echo '```'
    echo "sysctl vm.swapusage"
    echo '```'
    return 0
  fi
  [ "$swap_over" -eq 1 ] || return 0
  local pct=$(( (swap_bytes * 1000 / disk_bytes + 5) / 10 )) holders=""
  echo ""
  echo "Swap holds $swap_words, about $pct% of this disk, by sysctl vm.swapusage. More than $SWAP_SHARE_PCT% is memory that processes are holding rather than ordinary paging, and it is kept on /System/Volumes/VM, which shares this disk and which no folder size reaches."
  if [ "$TOP_SECONDS" -eq 0 ]; then
    echo "Naming the processes holding it is turned off here (FREE_SPACE_TOP_SECONDS=0)."
  else
    # The bound is lib/bounded-run.sh's, the one copy the nudge's Xcode step uses too. Read only
    # here, on the rare path that needs it, so an ordinary prompt pays nothing for it.
    local here="."
    case "${BASH_SOURCE[0]}" in */*) here="${BASH_SOURCE[0]%/*}" ;; esac
    . "$here/lib/bounded-run.sh" 2>/dev/null || bounded_run() { BOUNDED_OUT="lib/bounded-run.sh is missing, so top was not run"; BOUNDED_RC=127; }
    if [ -n "${FREE_SPACE_TOP_CMD:-}" ]; then
      bounded_run "$TOP_SECONDS" "$FREE_SPACE_TOP_CMD"
    else
      bounded_run "$TOP_SECONDS" top -l 1 -o mem -n 5 -stats pid,command,mem
    fi
    if [ "$BOUNDED_RC" -eq 124 ]; then
      echo "top did not answer within ${TOP_SECONDS}s, so the processes holding it are not named here."
    else
      # After the PID COMMAND MEM header: the pid first, MEM last, and the command between them,
      # which can hold spaces ("Google Chrome He"). top marks a value that moved with + or -.
      holders="$(awk '
        found && $1 ~ /^[0-9]+$/ && NF >= 3 {
          mem = $NF; sub(/[+-]$/, "", mem); cmd = $2
          for (i = 3; i < NF; i++) cmd = cmd " " $i
          printf "  %s (pid %s): %s\n", cmd, $1, mem
          if (++n >= 5) exit
        }
        $1 == "PID" && $2 == "COMMAND" { found = 1 }' <<< "$BOUNDED_OUT" 2>/dev/null || true)"
      if [ -n "$holders" ]; then
        echo "Nothing here measured whose swap it is; these hold the most memory now by top's MEM, which counts pages swapped out to disk (ps's resident size cannot see them):"
        printf '%s\n' "$holders"
      else
        echo "top named no process (it exited $BOUNDED_RC), so the processes holding it are not named here."
      fi
    fi
  fi
  echo "Swap is given back only when the memory is: restarting the process holding it (quitting its app, or restarting its service), or restarting the Mac, frees the space. Deleting files does not. To list the holders again:"
  echo '```'
  echo "top -l 1 -o mem -n 10 -stats pid,command,mem,time"
  echo '```'
}

# ---------- the one known cause, named only when the verdict is low or falling ----------
# The commands below always name the REAL folder, whatever the seam points at, because they are
# for Dan to paste; the seam only decides whether the folder exists and what its change time is.
SYMBOL_CACHE="${FREE_SPACE_SYMBOL_CACHE:-/System/Library/Caches/com.apple.coresymbolicationd}"
REAL_SYMBOL_CACHE=/System/Library/Caches/com.apple.coresymbolicationd
symbol_cache_note(){
  [ -d "$SYMBOL_CACHE" ] || return 0
  local changed="" age age_words=""
  # GNU first, then BSD: on macOS `stat -c` refuses and the BSD form answers. Anything that is not a
  # number, or lies in the future, is treated as unread, and then no time is stated at all (L11).
  changed="$(stat -c %Y "$SYMBOL_CACHE" 2>/dev/null || stat -f %m "$SYMBOL_CACHE" 2>/dev/null || true)"
  if is_number "$changed" && [ "$changed" -le "$now" ]; then
    age=$((now - changed))
    if [ "$age" -ge 172800 ]; then age_words="$((age / 86400)) day(s) ago"
    elif [ "$age" -ge 3600 ]; then age_words="$((age / 3600)) hour(s) ago"
    else age_words="$((age / 60)) minute(s) ago"; fi
  fi
  echo ""
  echo "Nothing measured it, but one suspect is worth checking because it has filled a disk before: $REAL_SYMBOL_CACHE, macOS's symbol cache, which reached 194 GB on Daniels-MacBook-Pro-2 on 2026-10-04. macOS adds to it whenever a crash report is written or a process is sampled, and each new build of an app that crashes or is sampled can add another copy. It is a cache macOS rebuilds when it needs it (coresymbolicationd(8)), so clearing it should cost only the time to rebuild it. Only an administrator can read its size, so this check cannot say how big it is now, or whether it is the cause."
  if [ -n "$age_words" ]; then
    echo "A file was last added to it or removed from it $age_words. That says it has been in use, not how much it holds."
  fi
  echo "First see its size (asks for your Mac password):"
  echo '```'
  echo "sudo du -sh $REAL_SYMBOL_CACHE"
  echo '```'
  echo "Only if that shows it is large, and you decide to clear it, this empties the folder (hidden files included) and keeps the folder itself:"
  echo '```'
  echo "sudo find $REAL_SYMBOL_CACHE -mindepth 1 -delete"
  echo '```'
}

# ---------- what the last disk-clean scan found that is still there to remove (claude-config#1809) ----------
# A warning that the disk is nearly full, while a scan from two days ago already found 14 GB that
# could go, leaves Dan to find that out again. So a low or falling verdict adds ONE line: the total
# disk-clean's last scan offered that disk-remove has not marked removed, how old that scan is, and
# /disk-clean. It is said only on a warning, never on a disk with room.
#
# THE LINE IS AN EXTRA, NEVER A CONDITION. A record that is missing, unreadable, cut off before its
# closing line, holding an item line it cannot read, missing scanned_at, dated in the future, or 7
# days old or more adds nothing, and nothing here can change the verdict or the exit code: this
# function only prints, and every way out of it is a return. A record with an item it cannot read
# is refused whole rather than totalled without that item, because the layout's own rule is that an
# unreadable part is never read as a smaller scan (lib/disk-clean-record.sh, L211).
#
# UNREAD IS NEVER 0 (L90). An offerable item with no bytes, or whose size is partial, denied or
# unread rather than measured or reported, makes the total "at least" that much; offerable items
# with no size read at all are counted as items, never as 0 GB.
#
# PART IN iCLOUD IS SAID, NEVER SIZED. The scan never reads a folder iCloud keeps only in the cloud
# (reading it makes iCloud download it), so an item with one beneath it is sized from what is stored
# on this Mac alone and flagged icloud-only-part (lib/disk-clean-record.sh). The total is right about
# this Mac; the line adds how many offered items have such a part, in the review page's words ("kept
# only in iCloud", L118), and that the part was not measured, with no figure for it (L11). Only
# sized items are counted, because the note qualifies the total: an item with no size is not in it
# at all, and the total already says "at least" for it.
#
# ONLY ON THE WARNING, AND READ ONCE PER RECORD. Every prompt runs this hook, so nothing here runs
# on a disk with room. Reading the record goes through lib/disk-clean-record.sh, which owns the
# layout (L370), and costs about 0.14 ms an item: 0.76 s for a 5,264 item record, measured
# 2026-10-28, on every prompt for as long as the disk stays low. So the tally (scanned_at and the
# counts below) is kept in <state dir>/disk-clean-tally, keyed on the record's inode, modification
# time, size and path, and the record is read again only when one of those moves (L431: one stat is far
# cheaper than the read). Every writer of the record renames a new file into place (dcr_write,
# dcr_mark), so even a mark that keeps the size inside the same second is a new inode. A kept tally
# that is not nine numbers (one kept in the eight number form from before the iCloud count, too) is
# read past, never shown. Sizes are worded by lib/disk-clean-units.sh,
# the one copy disk-clean's scan and disk-remove use.
#
# Environment: FREE_SPACE_SCAN_RECORD, the record to read (default ~/.claude/state/disk-clean/
# last-scan.json, where disk-clean's scan writes it), so the suite never reads this Mac's (L2).
scan_note(){
  local record="${FREE_SPACE_SCAN_RECORD:-${HOME:-}/.claude/state/disk-clean/last-scan.json}"
  [ -f "$record" ] && [ -r "$record" ] || return 0
  local here="." at age age_words tally n unsized kib bad partial taken unjudged icloud total cloud_note=""
  local stamp="" key="" kept_key="" kept="" _extra="" cache="$STATE_DIR/disk-clean-tally"
  case "${BASH_SOURCE[0]}" in */*) here="${BASH_SOURCE[0]%/*}" ;; esac
  . "$here/lib/disk-clean-units.sh" 2>/dev/null || return 0
  scan_tally_ok(){ is_number "${at:-}" && is_number "${n:-}" && is_number "${unsized:-}" && is_number "${kib:-}" \
    && is_number "${bad:-}" && is_number "${partial:-}" && is_number "${taken:-}" && is_number "${unjudged:-}" \
    && is_number "${icloud:-}"; }
  # GNU first, then BSD, the order the symbol cache's age is read in above.
  stamp="$(stat -c '%i %Y %s' "$record" 2>/dev/null || stat -f '%i %m %z' "$record" 2>/dev/null || true)"
  [ -n "$stamp" ] && key="$stamp $record"
  if [ -n "$key" ] && [ -f "$cache" ]; then
    { IFS= read -r kept_key; IFS= read -r kept; } < "$cache" 2>/dev/null || true
  fi
  read -r at n unsized kib bad partial taken unjudged icloud _extra <<< "$kept"
  if [ -z "$key" ] || [ "$kept_key" != "$key" ] || [ -n "${_extra:-}" ] || ! scan_tally_ok; then
    . "$here/lib/disk-clean-record.sh" 2>/dev/null || return 0
    dcr_complete "$record" 2>/dev/null || return 0
    at="$(dcr_header "$record" scanned_at 2>/dev/null)" || return 0
    # Fields of dcr_review_items: id, category, method, target, state, bytes, identity, size, flags,
    # detail. flags is a comma list, so icloud-only-part is matched as a whole entry, never inside icloud.
    tally="$(dcr_review_items "$record" 2>/dev/null | awk -F "$DCR_SEP" '
      $5 == "unreadable" { bad = 1 }
      $5 == "removed" || $5 == "trashed" || $5 == "truncated" || $5 == "gone" { taken++ }
      index($5, "unmeasured: ") == 1 { unjudged++ }
      $5 == "offerable" {
        n++
        if ($6 == "") unsized++
        else {
          b += $6; if ($8 != "measured" && $8 != "reported" && $8 != "") partial = 1
          nf = split($9, f, ","); for (i = 1; i <= nf; i++) if (f[i] == "icloud-only-part") { cloud++; break }
        }
      }
      END { printf "%d %d %.0f %d %d %d %d %d\n", n, unsized, b / 1024, bad, partial, taken, unjudged, cloud }')" || return 0
    read -r n unsized kib bad partial taken unjudged icloud <<< "$tally"
    scan_tally_ok || return 0
    if [ -n "$key" ]; then
      { printf '%s\n' "$key"; printf '%s %s %s %s %s %s %s %s %s\n' "$at" "$n" "$unsized" "$kib" "$bad" "$partial" "$taken" "$unjudged" "$icloud"; } > "$cache.$$" 2>/dev/null \
        && mv -f "$cache.$$" "$cache" 2>/dev/null || rm -f "$cache.$$" 2>/dev/null || true
    fi
  fi
  [ "$bad" = 0 ] || return 0
  [ "$at" -le "$now" ] || return 0
  age=$((now - at))
  [ "$age" -lt $((7 * 86400)) ] || return 0
  if [ "$age" -ge 86400 ]; then age_words="$((age / 86400)) day(s) ago"
  elif [ "$age" -ge 3600 ]; then age_words="$((age / 3600)) hour(s) ago"
  else age_words="$((age / 60)) minute(s) ago"; fi
  # Nothing left to offer has two causes, said apart (L11): its offers were taken, or it made none.
  if [ "$n" -eq 0 ] && [ "$taken" -gt 0 ]; then
    echo "A disk-clean scan taken $age_words has nothing left to offer: everything it found to remove has been removed. To scan again, run /disk-clean."
  elif [ "$n" -eq 0 ] && [ "$unjudged" -gt 0 ]; then
    echo "A disk-clean scan taken $age_words found nothing it could remove, and could not judge $unjudged item(s). To scan again, run /disk-clean."
  elif [ "$n" -eq 0 ]; then
    echo "A disk-clean scan taken $age_words found nothing it could remove. To scan again, run /disk-clean."
  elif [ "$n" -eq "$unsized" ]; then
    echo "A disk-clean scan taken $age_words found $n item(s) that it could remove and has not removed yet, but could not read their size. To review them, run /disk-clean."
  else
    total="$(dcu_human "$kib")"
    [ "$icloud" -gt 0 ] && cloud_note=" Part of $icloud item(s) it found is kept only in iCloud: that part was not measured and is not in the total."
    if [ "$unsized" -gt 0 ] || [ "${partial:-0}" = 1 ]; then
      echo "A disk-clean scan taken $age_words found at least $total that it could remove and has not removed yet (it could not read every size in full).$cloud_note To review it and choose what goes, run /disk-clean."
    else
      echo "A disk-clean scan taken $age_words found $total that it could remove and has not removed yet.$cloud_note To review it and choose what goes, run /disk-clean."
    fi
  fi
}

# The reason there is no rate is said only under --report. The prompt warning keeps the sentence it
# always had, so a notice on every prompt does not grow a clause nobody asked for.
[ "$REPORT" -eq 1 ] || no_rate_clause=""

if [ "$free_gb" -lt "$FLOOR_GB" ]; then
  echo "claude-sync: only $free_words free on $VOLUME, under the $floor_words floor.$rate_clause$no_rate_clause$cause_clause"
  scan_note
  swap_note
  symbol_cache_note
  exit 3
fi

if [ "$falling_fast" -eq 1 ]; then
  echo "claude-sync: $free_words free on $VOLUME, which is above the $floor_words floor but not for long.$rate_clause$cause_clause"
  scan_note
  swap_note
  symbol_cache_note
  exit 4
fi

if [ "$REPORT" -eq 1 ]; then
  echo "claude-sync: $free_words free on $VOLUME, above the $floor_words floor.$rate_clause$no_rate_clause"
fi
exit 0
