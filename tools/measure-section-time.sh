#!/usr/bin/env bash
#
# measure-section-time.sh: read the sync suite's section time together with the machine state it
# was read under (claude-config#517).
#
# The suite's section time budget guard (claude-config#492) fails a run whose sections add up past
# a fraction of the ceiling. What nobody had was a MEASUREMENT of the margin. Two readings taken
# hours apart on 2026-09-20, 963s and then 1847s against a 2520s budget, were compared as though
# the difference was work the suite had grown. It was not a comparison: section time is wall clock
# per section, so it inflates on a busy machine, and another project's harness was running during
# the later one. Neither reading recorded what else was on the machine, so neither can be re-read.
#
# So this does three things a hand run does not. It takes SEVERAL readings, because one reading per
# arm cannot be told from noise (L395, L656). It records what else was running beside each number,
# rather than leaving that to be filtered out afterwards (L356). And it can WAIT for the machine to
# be quiet by ITS OWN standard, calibrated from the floor this machine actually sits at, because a
# fixed bar refuses every measurement on a machine that always has something running (L364).
#
# Usage: measure-section-time.sh             (takes the readings)
#        measure-section-time.sh --columns   (prints the record's header, the one list of its columns)
#   MEASURE_RUNS             readings to take (default 3; 1 is allowed and is labelled as not a
#                            measurement, because a single number has no spread to read)
#   MEASURE_LOAD_PROCS       busy loops to start for the duration, for the loaded arm (default 0)
#   MEASURE_WAIT_SECONDS     how long to wait for a quiet window before giving up (default 0, which
#                            takes the machine as it is found and says so)
#   MEASURE_RECORD           a TSV file to append one row per reading to (default: print only)
#   MEASURE_SAMPLE_SECONDS   how often to sample ambient CPU during a run (default 10)
#   MEASURE_QUIET_MARGIN     how far above this machine's own floor still counts as quiet, in
#                            percent of one core (default 100, so one core's worth of movement)
#   MEASURE_CALIBRATE_SAMPLES  samples taken to find the floor (default 6)
#   MEASURE_WAIT_MAX_SAMPLES   the wait's other bound, in samples (default 360). A wait bounded
#                            only by the clock does unbounded work when sampling is cheap (L704).
#   MEASURE_SUITE_CMD        the command that produces one reading (default: the sync suite)
#   MEASURE_SUITE_SOURCE     the file the budget is derived from (default: the sync suite's source)
#   MEASURE_AMBIENT_CMD      prints ambient CPU, in percent of one core (default: a ps sum)
#   MEASURE_LOADAVG_CMD      prints the one minute load average (default: sysctl vm.loadavg)
#   MEASURE_TOP_CMD          prints the busiest processes (default: the same ps snapshot, sorted)
#   MEASURE_SLEEP_CMD        the sleep (default: sleep). A seam, so the tests pay no wall clock.
#
# Exit 0 = measured. Exit 1 = REFUSED: a run that failed, a run that emitted no total, a machine
# that never settled. None of those is a reading of zero, and zero clears every budget there is
# (L90, L98). Exit 2 = a knob that decides what runs is not usable.
set -uo pipefail

# --- run from a COPY of this file, so an edit to it cannot change a run already in flight
# (claude-config#519).
#
# Bash reads a script incrementally as it executes it, seeking by byte offset, so a file edited
# while a long run is executing it is misread from that point on, and the run can still finish and
# report a result belonging to neither version. This tool runs for tens of minutes and this
# checkout is shared by two sessions, so that is not a hypothetical: on 2026-09-20 a measurement
# was thrown away for exactly this.
#
# MEASURE_SELF_HOME carries where the real file lives across the exec, because every default here
# hangs off that directory and BASH_SOURCE after the exec names the copy. MEASURE_SELF_COPY is
# both the guard against re-execing for ever and the path the copy is removed by.
if [ -z "${MEASURE_SELF_COPY:-}" ] && [ -z "${MEASURE_NO_SELF_COPY:-}" ]; then
  _sc_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _sc_copy="$(mktemp "${TMPDIR:-/tmp}/measure-section-time-self.XXXXXXXX")" || {
    printf 'measure-section-time: could not create a copy of this script to run from, so a run could be changed by an edit to it while it is in flight. Refusing rather than running exposed (claude-config#519).\n' >&2
    exit 2
  }
  cat "${BASH_SOURCE[0]}" > "$_sc_copy" || { rm -f "$_sc_copy"; printf 'measure-section-time: could not write the copy of this script.\n' >&2; exit 2; }
  MEASURE_SELF_COPY="$_sc_copy" MEASURE_SELF_HOME="$_sc_home" exec bash "$_sc_copy" "$@"
fi

# The copy goes when this ends, however it ends. Set before anything else can exit, and every
# later trap on EXIT must call this too: a second trap on a signal REPLACES the first rather than
# adding to it, which is how 38 copies were left behind on the day this was written.
self_copy_clean(){ [ -z "${MEASURE_SELF_COPY:-}" ] || rm -f "$MEASURE_SELF_COPY"; }
trap 'self_copy_clean' EXIT

HERE="${MEASURE_SELF_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO="$(cd "$HERE/.." && pwd)"

# Says which file this process is actually executing, and runs nothing. The only way to see that
# the copy is real is to ask, since a run that is working looks identical either way (L102).
if [ "${1:-}" = "--self-path" ]; then
  printf 'SELF-PATH %s\n' "${MEASURE_SELF_COPY:-${BASH_SOURCE[0]}}"
  exit 0
fi

# The record's columns, named ONCE (claude-config#524). The header a new record starts with, the
# row each reading appends and the header an existing record is held to are all this list, and the
# sync suite reads the record by these NAMES rather than by position. A row used to be one printf
# with thirteen arguments in an order written out a second time, under a header nothing compared
# to it, so adding a column meant the reader silently read a different quantity.
RECORD_COLUMNS="taken_utc host arm section_seconds budget_seconds wall_seconds ambient_mean_pct ambient_max_pct floor_pct shards load_max ambient_rise_pct busiest"
record_header(){ printf '%s\n' $RECORD_COLUMNS | paste -sd '\t' -; }
if [ "${1:-}" = "--columns" ]; then
  record_header
  exit 0
fi

# Anything else on the command line is refused rather than ignored. This tool's whole job is a long
# run of the real suite, so an argument it did not recognise used to START one, in place of what
# was asked (claude-config#524).
# --credible and --top are answered further down, once what they read is set up.
if [ "$#" -gt 0 ] && [ "${1:-}" != "--credible" ] && [ "${1:-}" != "--top" ]; then
  printf 'measure-section-time: "%s" is not an argument this takes (it takes --columns, --credible <rows>, --top, --self-path, or none). Refusing rather than starting a suite run nobody asked for.\n' "$1" >&2
  exit 2
fi

RUNS="${MEASURE_RUNS:-3}"
LOAD_PROCS="${MEASURE_LOAD_PROCS:-0}"
WAIT_SECONDS="${MEASURE_WAIT_SECONDS:-0}"
RECORD="${MEASURE_RECORD:-}"
SAMPLE_SECONDS="${MEASURE_SAMPLE_SECONDS:-10}"
QUIET_MARGIN="${MEASURE_QUIET_MARGIN:-100}"
CAL_SAMPLES="${MEASURE_CALIBRATE_SAMPLES:-6}"
WAIT_MAX_SAMPLES="${MEASURE_WAIT_MAX_SAMPLES:-360}"
SUITE_SOURCE="${MEASURE_SUITE_SOURCE:-$REPO/tests/test-claude-sync.sh}"
SUITE_CMD="${MEASURE_SUITE_CMD:-bash $SUITE_SOURCE}"
SLEEP_CMD="${MEASURE_SLEEP_CMD:-sleep}"
RUN_MAX_SAMPLES="${MEASURE_RUN_MAX_SAMPLES:-2000}"

say(){ printf '%s\n' "$*"; }
die2(){ printf 'measure-section-time: %s\n' "$*" >&2; exit 2; }

# Is a ps snapshot believable? A reader that answers with an EMPTY or partial collection when its
# source fails is indistinguishable from a correct read of a quiet machine, and here that is the
# worst possible direction to be wrong in: the reading would be labelled quiet exactly when the
# machine was at its busiest (L215, L98). Measured on this Mac on 2026-09-20, under a four shard
# suite run: consecutive ps snapshots totalled 830%, then 7.9%, then 830% again.
#
# Fewer than fifty processes is not a Mac, it is a snapshot that was cut short. A floor about the
# operating system rather than about how busy this machine happens to be, so it needs no
# calibrating per machine (L376).
#
# A second rule was tried here and removed the same evening: it refused a snapshot whose total
# contradicted the kernel's load average. The load average counts processes blocked on disk, which
# use no CPU, so on 2026-09-20 at load 90, with four backup and indexing daemons reading the disk,
# it refused all six calibration samples and the tool measured nothing. The load average is
# recorded beside each reading now instead, where it says the thing ambient CPU cannot.
#
# Exposed as an argument because a cut short snapshot cannot be produced on demand from a real
# machine, so the only way this rule is ever seen to work is by being driven directly.
credible(){          # $1 = rows in the snapshot
  awk -v rows="$1" 'BEGIN { print (rows + 0 < 50) ? "not credible" : "credible" }'
}
if [ "${1:-}" = "--credible" ]; then
  [ "$#" -eq 2 ] || die2 "--credible takes one number: how many rows the ps snapshot held."
  credible "$2"
  exit 0
fi

for _k in RUNS LOAD_PROCS WAIT_SECONDS SAMPLE_SECONDS QUIET_MARGIN CAL_SAMPLES WAIT_MAX_SAMPLES RUN_MAX_SAMPLES; do
  eval "_v=\$$_k"
  case "$_v" in ''|*[!0-9]*) die2 "MEASURE_${_k}='$_v' is not a whole number, and it decides what runs. Refusing rather than guessing." ;; esac
done
[ "$RUNS" -gt 0 ] || die2 "MEASURE_RUNS=0 would take no readings at all and report that as a clean measurement. Refusing (L98)."
# A record that already exists must carry exactly these columns, checked BEFORE a reading is
# taken: a reading is a long suite run, and appending it under a different header would give its
# numbers the wrong names with nothing to say so.
if [ -n "$RECORD" ] && [ -s "$RECORD" ]; then
  _rec_have="$(head -1 "$RECORD")"
  if [ "$_rec_have" != "$(record_header)" ]; then
    _rec_diff="$( { printf '%s\n' $RECORD_COLUMNS | sed 's/^/wants /'; printf '%s\n' "$_rec_have" | tr '\t' '\n' | sed 's/^/has /'; } \
      | awk '{ c[$2] = c[$2] " " $1 } END { for (k in c) if (c[k] !~ /wants/ || c[k] !~ /has/) printf "%s%s", sep, k (c[k] ~ /wants/ ? " (missing from the record)" : " (not written by this tool)"); sep = ", " }')"
    die2 "MEASURE_RECORD='$RECORD' does not carry the columns this tool writes${_rec_diff:+: $_rec_diff}${_rec_diff:- (same names, different order)}. Refusing before a reading is taken, since appending one would give its numbers the wrong names. Add the columns to the record's header and rows, or point MEASURE_RECORD at a new file."
  fi
fi
[ -f "$SUITE_SOURCE" ] || die2 "MEASURE_SUITE_SOURCE='$SUITE_SOURCE' does not exist, so the budget cannot be derived from the suite's own constants. Refusing rather than falling back to a number written out here, which would go on judging against a superseded one (L41)."

# The ambient reader. ps %CPU on macOS is a decaying average over roughly the last minute rather
# than an instant, which is said out loud because it decides what this number means: it is the
# recent load, not the load at the instant of the call, and that is the right quantity for a run
# lasting minutes. Everything in THIS process group is excluded, so the suite's own work and any
# load this tool started are not counted as ambient. Those are recorded separately, by name.
PGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
default_ambient(){
  local snap rows amb
  snap="$(ps -A -o pgid=,%cpu= 2>/dev/null)"
  rows="$(printf '%s\n' "$snap" | grep -c . || true)"
  amb="$(printf '%s\n' "$snap" | awk -v mine="${PGID:-0}" '$1 + 0 != mine + 0 { s += $2 + 0 } END { printf "%d", s + 0 }')"
  [ "$(credible "$rows")" = "credible" ] || return 0
  printf '%s\n' "$amb"
}

# The kernel's own one minute load average, which counts processes waiting on the disk as well as
# processes wanting the processor. A reading taken while four daemons are reading the disk shows an
# honest, modest ambient CPU and a load average in the nineties, and only the second one says why
# the suite took twice as long (L356).
LOADAVG_CMD="${MEASURE_LOADAVG_CMD:-}"
read_loadavg(){
  local v
  if [ -n "$LOADAVG_CMD" ]; then v="$($LOADAVG_CMD 2>/dev/null)"
  else v="$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{ print $1 + 0 }')"; fi
  case "$v" in ''|*[!0-9.]*) return 0 ;; esac
  printf '%s' "$v"
}
AMBIENT_CMD="${MEASURE_AMBIENT_CMD:-}"
read_ambient(){
  local v
  if [ -n "$AMBIENT_CMD" ]; then v="$($AMBIENT_CMD 2>/dev/null)"; else v="$(default_ambient)"; fi
  v="${v%%$'\n'*}"; v="$(printf '%s' "$v" | tr -cd '0-9')"
  # An unreadable sample is NOT a quiet one. It prints nothing, and every caller treats nothing as
  # a refusal rather than as a zero, for the same reason the totals do.
  printf '%s' "$v"
}

# The three processes using most of the machine that are not ours, so the reading says WHAT was
# running rather than only how much (L356). THREE, biggest first: printed as everything above a
# threshold in whatever order ps returned it, this was eleven names long on the first real run and
# unreadable at exactly the moment somebody wants it.
#
# The formatting is separated from the ps call and reachable as an argument, because a fixture is
# the only way to know it picked the right three: the real machine cannot be asked to have a known
# top three on demand.
top_from(){          # $1 = the pgid to leave out, then ps output on stdin
  awk -v mine="${1:-0}" '$1 + 0 != mine + 0 && $2 + 0 > 5 {
      line = $0
      sub(/^[0-9]+[ \t]+[0-9.]+[ \t]+/, "", line)
      n = split(line, p, "/")
      printf "%.0f\t%s\n", $2, p[n]
    }' \
    | sort -rn | awk -F'\t' 'NR <= 3 { gsub(/ /, "_", $2); printf "%s(%s%%) ", $2, $1 }'
}
if [ "${1:-}" = "--top" ]; then
  top_from "${2:-0}"
  exit 0
fi
TOP_CMD="${MEASURE_TOP_CMD:-}"
top_ambient(){
  if [ -n "$TOP_CMD" ]; then $TOP_CMD 2>/dev/null | cut -c1-160; return 0; fi
  ps -A -o pgid=,%cpu=,comm= 2>/dev/null | top_from "${PGID:-0}" | cut -c1-160
}

# --- the budget, derived from the suite's own two constants and never written out again here.
_to="$(sed -n 's/^SUITE_TIMEOUT="\${SUITE_TIMEOUT:-\([0-9][0-9]*\)}"$/\1/p' "$SUITE_SOURCE")"; _to="${_to%%$'\n'*}"
_pct="$(sed -n 's/^SUITE_WORK_BUDGET_PCT="\${SUITE_WORK_BUDGET_PCT:-\([0-9][0-9]*\)}"$/\1/p' "$SUITE_SOURCE")"; _pct="${_pct%%$'\n'*}"
case "${_to:-}${_pct:-}" in
  ''|*[!0-9]*) die2 "could not read SUITE_TIMEOUT and SUITE_WORK_BUDGET_PCT out of $SUITE_SOURCE, so the budget would have to be a second copy of numbers that live there. Refusing." ;;
esac
BUDGET=$(( _to * _pct / 100 ))
[ "$BUDGET" -gt 0 ] || die2 "the budget derived from $SUITE_SOURCE came out as $BUDGET seconds, which no run could ever breach. Refusing to judge against it."

# --- whatever this starts is stopped with it, however it ends. The trap ENDS the script rather
# than only cleaning up, or an interrupt tidies up and then carries on measuring (L473). The load
# is killed by the pids this tool created, never by matching a name across the machine (L444).
LOAD_PIDS=""
stop_load(){
  local p
  for p in $LOAD_PIDS; do kill "$p" 2>/dev/null; done
  for p in $LOAD_PIDS; do wait "$p" 2>/dev/null; done
  LOAD_PIDS=""
}
trap 'stop_load; self_copy_clean; exit 130' INT TERM
trap 'stop_load; self_copy_clean' EXIT

start_load(){
  local i=1
  [ "$LOAD_PROCS" -gt 0 ] || return 0
  while [ "$i" -le "$LOAD_PROCS" ]; do
    # $0 is set to a name this tool can recognise, so a leftover is identifiable by a person
    # reading ps. The KILL above still goes by pid, because a name match over the whole machine
    # claims work this tool never started.
    bash -c 'while :; do :; done' "measure-section-time-load" &
    LOAD_PIDS="$LOAD_PIDS $!"
    i=$(( i + 1 ))
  done
  return 0
}

# --- the arm. Named from what was actually done, never from what was asked for.
ARM="as-found"
FLOOR=""
BAR=""
if [ "$LOAD_PROCS" -gt 0 ]; then ARM="loaded-$LOAD_PROCS"; fi

# --- calibrate the floor, then wait for a sample at or under it plus the margin.
#
# The bar is THIS machine's floor plus a margin, not a fixed number of percent. A Mac that always
# has a backup, a sync daemon and two editors running has a floor well above zero, and a fixed bar
# would refuse every reading it was ever asked for while reading as a guard doing its job (L364).
calibrate(){
  local i=1 v lo=""
  while [ "$i" -le "$CAL_SAMPLES" ]; do
    v="$(read_ambient)"
    case "$v" in ''|*[!0-9]*) ;; *) if [ -z "$lo" ] || [ "$v" -lt "$lo" ]; then lo="$v"; fi ;; esac
    [ "$i" -eq "$CAL_SAMPLES" ] || $SLEEP_CMD "$SAMPLE_SECONDS"
    i=$(( i + 1 ))
  done
  printf '%s' "${lo:-}"
}

FLOOR="$(calibrate)"
case "$FLOOR" in
  ''|*[!0-9]*)
    printf 'measure-section-time: UNMEASURED: the ambient CPU reader returned nothing usable in %s samples, so the machine state this reading would be taken under is unknown. Refusing rather than recording a number with no conditions attached.\n' "$CAL_SAMPLES" >&2
    exit 1 ;;
esac
BAR=$(( FLOOR + QUIET_MARGIN ))
say "measure-section-time: this machine's floor measured $FLOOR% of one core over $CAL_SAMPLES samples, so quiet here means ambient at or under $BAR%. A reading is comparable only with another taken at a similar floor."

if [ "$WAIT_SECONDS" -gt 0 ]; then
  _w_start=$SECONDS
  _w_n=0
  _w_ok=0
  while :; do
    _w_v="$(read_ambient)"
    _w_n=$(( _w_n + 1 ))
    case "$_w_v" in
      ''|*[!0-9]*) ;;
      *) if [ "$_w_v" -le "$BAR" ]; then _w_ok=1; break; fi ;;
    esac
    # Bounded by the clock AND by a count. With a cheap reader the clock is never reached, and a
    # loop bounded only by wall time does unbounded work (L704).
    if [ $(( SECONDS - _w_start )) -ge "$WAIT_SECONDS" ] || [ "$_w_n" -ge "$WAIT_MAX_SAMPLES" ]; then break; fi
    $SLEEP_CMD "$SAMPLE_SECONDS"
  done
  if [ "$_w_ok" -eq 1 ]; then
    [ "$LOAD_PROCS" -gt 0 ] || ARM="quiet"
    say "measure-section-time: the machine settled to $_w_v% after $_w_n sample(s), so this reading was taken in a quiet window."
  else
    printf 'measure-section-time: UNMEASURED: ambient CPU stayed above %s%% for the whole wait (%s sample(s) over %ss), so the machine never settled. Refusing to take the reading anyway, because a number taken here would be quoted later as a quiet one.\n' "$BAR" "$_w_n" "$(( SECONDS - _w_start ))" >&2
    exit 1
  fi
fi

start_load
[ -z "$LOAD_PIDS" ] || say "measure-section-time: started $LOAD_PROCS busy loop(s) for this arm, so this reading is a loaded one."

# --- the runs.
SECS=""      # the section time each run reported
SHARDS=""    # how many shards produced them, which has to be the same for every run in an arm
REFUSAL=""
i=1
while [ "$i" -le "$RUNS" ]; do
  _out="$(mktemp "${TMPDIR:-/tmp}/measure-section-time.XXXXXXXX")" || { printf 'measure-section-time: could not create a scratch file, so a run could not be read.\n' >&2; exit 1; }
  _t0=$SECONDS
  $SUITE_CMD > "$_out" 2>&1 &
  _pid=$!
  _amax=0; _asum=0; _an=0; _abad=0; _s=0; _lmax=0; _who=""
  # The first sample is taken straight away rather than after a wait, so a run always carries at
  # least one reading of the conditions it was taken under. A short run would otherwise finish
  # before the first sample and report a number with nothing beside it.
  _sample_ambient(){
    local v l
    v="$(read_ambient)"
    case "$v" in
      ''|*[!0-9]*) _abad=$(( _abad + 1 )) ;;
      # Read at the PEAK, not after the run. Taken once at the end it named whatever happened to be
      # running a second after the reading, which is a different question from what the reading was
      # taken alongside, and reads as an answer to the second one.
      *) _an=$(( _an + 1 )); _asum=$(( _asum + v ))
         if [ "$v" -gt "$_amax" ]; then _amax="$v"; _who="$(top_ambient)"; fi ;;
    esac
    l="$(read_loadavg)"
    [ -n "$l" ] || return 0
    # Compared as a decimal, which the shell cannot do, so awk decides.
    [ "$(awk -v a="$l" -v b="$_lmax" 'BEGIN { print (a + 0 > b + 0) ? "y" : "n" }')" = "y" ] && _lmax="$l"
    return 0
  }
  _sample_ambient
  while kill -0 "$_pid" 2>/dev/null; do
    _s=$(( _s + 1 ))
    [ "$_s" -lt "$RUN_MAX_SAMPLES" ] || break
    $SLEEP_CMD "$SAMPLE_SECONDS"
    kill -0 "$_pid" 2>/dev/null || break
    _sample_ambient
  done
  wait "$_pid"; _rc=$?
  _elapsed=$(( SECONDS - _t0 ))
  _amean=0; [ "$_an" -gt 0 ] && _amean=$(( _asum / _an ))

  if [ "$_rc" -ne 0 ]; then
    REFUSAL="run $i of $RUNS FAILED (exit $_rc). A run that failed partway still ran everything before the failure, so whatever it totalled is a fragment of the suite and not a reading of it (L480). The output is at $_out."
    break
  fi
  # The suite's own line: the total, and the budget IT judged itself against.
  _note="$(sed -n 's/^SUITE-NOTE \([0-9][0-9]*\)s of section time against a \([0-9][0-9]*\)s budget.*/\1 \2/p' "$_out")"; _note="${_note%%$'\n'*}"
  if [ -z "$_note" ]; then
    REFUSAL="run $i of $RUNS emitted no section time total, so it measured nothing. Nothing is not a total of zero, which would clear every budget there is (L90, L98). The output is at $_out."
    break
  fi
  _sec="${_note%% *}"; _saidbudget="${_note##* }"
  # How many shards produced that total. The suite runs its PRELUDE once inside each shard and
  # counts every one of them, so the same tree measured at two shard counts gives two different
  # totals. A reading is therefore only comparable with another taken at the same count, and an
  # arm whose count moved partway through is not one arm (L220).
  _shards="$(sed -n 's/.*(\([0-9][0-9]*\) shards in .*/\1/p' "$_out")"; _shards="${_shards%%$'\n'*}"
  if [ -n "$_shards" ]; then
    if [ -z "$SHARDS" ]; then
      SHARDS="$_shards"
    elif [ "$_shards" != "$SHARDS" ]; then
      REFUSAL="run $i of $RUNS ran $_shards shard(s) while an earlier run in this arm ran $SHARDS. The suite counts its prelude once per shard, so those two totals are measurements of different things and averaging them would report a change nobody made."
      break
    fi
  fi
  # Two readings of one quantity: the budget derived from the suite's constants, and the budget the
  # suite printed for itself. Disagreement means one of them is stale, and neither can be trusted.
  if [ "$_saidbudget" -ne "$BUDGET" ]; then
    REFUSAL="run $i of $RUNS judged itself against a ${_saidbudget}s budget while $SUITE_SOURCE derives ${BUDGET}s. Those are two readings of one number and they disagree, so neither is trustworthy."
    break
  fi
  rm -f "$_out"
  SECS="$SECS $_sec"
  # How far ambient sat ABOVE this machine's floor while the run was in flight. Reported on its
  # own rather than folded into the mean, because part of it is work this run PROVOKES in programs
  # it does not own: the indexer reading the scratch the suite writes, a backup client picking up
  # new files. Both arms therefore carry some of their own footprint in the very number meant to
  # separate them, and only a figure named as a rise makes that visible (claude-config#521).
  #
  # A machine QUIETER during the run than at calibration is said to have fallen, never clamped to
  # a rise of zero, which would read as a run that provoked nothing.
  _arise=""
  if [ "$_an" -gt 0 ]; then
    if [ "$_amean" -ge "$FLOOR" ]; then
      _arise="rose $(( _amean - FLOOR ))% above this machine's floor, some of which is work this run provokes elsewhere"
    else
      _arise="fell $(( FLOOR - _amean ))% below this machine's floor, so the machine was quieter during the run than when the floor was taken"
    fi
  fi
  if [ "$_an" -gt 0 ]; then
    say "  run $i: ${_sec}s of section time over ${_shards:-?} shard(s), ${_elapsed}s wall clock, ambient CPU mean ${_amean}% max ${_amax}% of one core over $_an sample(s)${_abad:+, $_abad unreadable}, load average up to ${_lmax}${_who:+ (busiest: $_who)}"
    say "         ambient $_arise"
  else
    say "  run $i: ${_sec}s of section time over ${_shards:-?} shard(s), ${_elapsed}s wall clock, ambient CPU unknown: all $_abad sample(s) were unreadable, so this reading carries no account of the machine it was taken on"
  fi
  if [ -n "$RECORD" ]; then
    # Walked in the order RECORD_COLUMNS names, one value per name, so the row cannot be written
    # in a different order from the header it sits under.
    _row=""; _sep=""
    for _col in $RECORD_COLUMNS; do
      case "$_col" in
        taken_utc)        _val="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" ;;
        host)             _val="$(hostname -s 2>/dev/null)" ;;
        arm)              _val="$ARM" ;;
        section_seconds)  _val="$_sec" ;;
        budget_seconds)   _val="$BUDGET" ;;
        wall_seconds)     _val="$_elapsed" ;;
        ambient_mean_pct) if [ "$_an" -gt 0 ]; then _val="$_amean"; else _val=unknown; fi ;;
        ambient_max_pct)  if [ "$_an" -gt 0 ]; then _val="$_amax"; else _val=unknown; fi ;;
        floor_pct)        _val="$FLOOR" ;;
        shards)           _val="${_shards:-unknown}" ;;
        load_max)         _val="$_lmax" ;;
        ambient_rise_pct) if [ "$_an" -gt 0 ]; then _val="$(( _amean - FLOOR ))"; else _val=unknown; fi ;;
        busiest)          _val="${_who:-none}" ;;
        *) die2 "the record column '$_col' has no value written for it. RECORD_COLUMNS and this list must name the same columns." ;;
      esac
      _row="$_row$_sep$_val"; _sep="$(printf '\t')"
    done
    { [ -s "$RECORD" ] || record_header; printf '%s\n' "$_row"; } >> "$RECORD" \
      || say "  (warning: could not append to $RECORD, so this reading was printed and not recorded)"
  fi
  i=$(( i + 1 ))
done

stop_load

if [ -n "$REFUSAL" ]; then
  printf 'measure-section-time: REFUSED: %s\n' "$REFUSAL" >&2
  exit 1
fi

# --- the verdict.
_n="$(printf '%s' "$SECS" | wc -w | tr -d ' ')"
# Sorted ONCE, into a variable, and read from there. Three pipelines each ending in a consumer
# that leaves early is three chances for pipefail to report a failure that never happened (L183).
_sorted="$(printf '%s\n' $SECS | sort -n)"
_lo="${_sorted%%$'\n'*}"
_hi="${_sorted##*$'\n'}"
_mid="$(printf '%s\n' "$_sorted" | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }')"
_pct_used=$(( _mid * 100 / BUDGET ))
say ""
if [ "$_n" -eq 1 ]; then
  say "measure-section-time: ONE reading on the $ARM arm: ${_mid}s of section time against a ${BUDGET}s budget, which is ${_pct_used}% of it."
  say "  One reading cannot be told from noise, so this is a data point and not a measurement (L395). Take at least three with MEASURE_RUNS."
else
  say "measure-section-time: $_n readings on the $ARM arm: median ${_mid}s of section time against a ${BUDGET}s budget, which is ${_pct_used}% of it."
  say "  The spread was ${_lo}s to ${_hi}s, so the margin is $(( BUDGET - _hi ))s at this arm's worst reading."
fi
if [ -n "$SHARDS" ]; then
  say "  Taken at $SHARDS shards, and the prelude is counted once in each of them, so a reading at another shard count is a different quantity."
else
  say "  The runs named no shard count, so this total is whatever one process measured."
fi
say "  Ambient CPU is reported per run above, and this machine's floor was $FLOOR% of one core. A reading is only comparable with another taken at a similar floor."
exit 0
