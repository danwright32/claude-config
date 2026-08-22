#!/usr/bin/env bash
#
# run-all-tests.sh: run every test suite in this repo and report one verdict.
#
# The suites are discovered from disk (`test-*.sh`), never from a list kept here.
# A hand written list would only ever run the suites someone remembered to add,
# so a new suite could sit unrun while this reported everything green
# (LESSONS.md L96).
#
# That was true of the FILES and false of the DIRECTORIES until #120. It read one
# directory, the one it lives in, so `tests/`, `tools/` and
# `payload/skills/milestone/` were outside it. The first three were run only
# because four hand written steps in .github/workflows/tests.yml named them, and
# the fourth was named by nothing at all: 233 checks, written down 2026-08-21,
# that had never run anywhere.
# The boundary was the same hand maintained list, drawn one level up.
#
# So with no arguments it asks the REPO which directories hold a suite, and reads
# all of them. A suite added anywhere is found by that on the day it lands.
#
# Run:  bash ~/.claude/hooks/run-all-tests.sh              # every suite in the repo
#       bash ~/.claude/hooks/run-all-tests.sh <dir>...     # only these directories
#
# Exit 0 = every suite passed. Exit 1 = at least one failed, or a directory it was
# told to read held no suites, or nothing was found to run. Finding NO suites is a
# failure, not a pass: an empty run is indistinguishable from a clean one
# otherwise (LESSONS.md L98).
#
# Environment:
#   HOOK_TESTS_ROOT           read this repo instead of the one above this script
#   HOOK_TESTS_LIST_ONLY=1    print the directories it would read, run nothing
#   HOOK_TESTS_FAIL_DETAIL_MAX  lines of a failing suite's output to print
#   HOOK_TESTS_JOBS           how many suites run at once
#   HOOK_TESTS_BUDGET         processes this whole run may have in flight (default: cores, max 8)
#   HOOK_TESTS_SLOTS          set BY this script FOR each suite: its share of that budget
#   HOOK_TESTS_TIMINGS        where each suite's measured wall clock is kept between runs.
#                             Empty turns the record off entirely: nothing is read, nothing written.

set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SELF_DIR="${SELF%/*}"

# This script's own directory holds `test-*.sh` files, and one of them tests this
# script, so a bare run discovers that suite and runs it, and it runs this script
# again. Measured the first time the suite existed: it recursed until the run was
# killed by hand. A depth marker rather than a lock, because the legitimate case
# (a suite invoking the runner against a FIXTURE directory) has to keep working,
# and only the bare re-entry is refused.
# HOOK_TESTS_LIST_ONLY is exempt, because it runs nothing at all: it prints the directories and
# exits, so it cannot be the step that recurses, and refusing it makes the one question a suite
# legitimately asks about the real repo unanswerable from inside a run.
if [ "${HOOK_TESTS_RUNNING:-0}" = "1" ] && [ "$#" -eq 0 ] \
   && [ -z "${HOOK_TESTS_ROOT:-}" ] && [ "${HOOK_TESTS_LIST_ONLY:-0}" != "1" ]; then
  echo "run-all-tests: refusing to run the whole repo from inside a run of the whole repo, which recurses without end. Name the directories to read, or set HOOK_TESTS_ROOT." >&2
  exit 1
fi
export HOOK_TESTS_RUNNING=1

# How many lines of a failing suite's own output to print. Enough to act on, bounded so one
# broken suite cannot bury the other verdicts.
FAIL_DETAIL_MAX="${HOOK_TESTS_FAIL_DETAIL_MAX:-40}"

# How many suites run at once (claude-config#125). Since #120 this reads every directory in the
# repo, which was 37 suites and about five minutes run one after another when #125 was written,
# and is 38 suites in 84 seconds measured on 2026-08-21, over half of that spent on the single
# longest suite after every other one has finished. Five minutes is how a full run stops being run
# at all, which is the exact failure #120 exists to close, so the answer is to make the full run
# fast rather than to make a partial run the default.
#
# The suites are independent: each builds its own throwaway state and writes a self contained
# verdict. What is NOT independent is the report, so results are collected to files and printed in
# the order the suites were FOUND, never the order they finished, or two runs cannot be compared.
#
# 1 runs them one at a time, which is what to reach for when a suite only fails alongside others.
# A value that is not a positive whole number is REFUSED rather than guessed at: this decides how
# much runs at once, and guessing could mean no parallelism at all or a great many processes (L50).
#
# How much of the machine the whole run may take is ONE number, and both halves are derived from
# it (claude-config#136). This starts several suites at once, and one of those suites splits
# ITSELF into shards, so the processes actually in flight were the product of two numbers set
# independently and compared nowhere: a four core runner could be running a dozen heavy ones, each
# spawning git and python of its own. That never failed outright, which is the difficulty with it.
# Oversubscription does not go red, it makes timing sensitive checks intermittently wrong, and the
# sync suite's own deadline guard was measured firing at 1192s against a normal 200 on a loaded
# Mac. So the budget below is granted to the suites running at once, each is TOLD its share in
# HOOK_TESTS_SLOTS, and the total is printed rather than left to be worked out. The shares are not
# equal: see the lanes further down (#139).
_ncpu="$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) | head -1 )"
case "$_ncpu" in ''|*[!0-9]*) _ncpu=4 ;; esac
[ "$_ncpu" -gt 0 ] || _ncpu=4
_default_budget=$(( _ncpu > 8 ? 8 : _ncpu ))
[ "$_default_budget" -gt 0 ] || _default_budget=1
BUDGET="${HOOK_TESTS_BUDGET-$_default_budget}"
case "$BUDGET" in
  ''|*[!0-9]*|0)
    echo "run-all-tests: HOOK_TESTS_BUDGET='$BUDGET' is not a positive whole number of processes this run may have in flight. Refusing rather than guessing, because it decides how much of the machine the tests take." >&2
    exit 1 ;;
esac
# Half the budget runs at once by default, so the suites that shard still shard and the machine is
# not oversubscribed four times over. Setting HOOK_TESTS_JOBS overrides how many run at once and
# the shares follow from it, which keeps the total one number either way.
#
# The floor of two is for the small machine, which is where this arithmetic goes wrong quietly: the
# CI runner has two cores, half of two is one, and the 38 suites counted on 2026-08-21 would have
# run strictly one after another while two slots sat reserved for whichever of them could use
# them. Capped by the budget,
# so a single core is one suite and not two.
_jobs_default=$(( BUDGET / 2 ))
[ "$_jobs_default" -ge 2 ] || _jobs_default=2
[ "$_jobs_default" -le "$BUDGET" ] || _jobs_default="$BUDGET"
JOBS="${HOOK_TESTS_JOBS-$_jobs_default}"
case "$JOBS" in
  ''|*[!0-9]*|0)
    echo "run-all-tests: HOOK_TESTS_JOBS='$JOBS' is not a positive whole number of suites to run at once. Refusing rather than guessing, because this decides how many processes start. Use 1 to run them one at a time." >&2
    exit 1 ;;
esac

# The repo this run is about, worked out BEFORE the directories are chosen, because two things
# need it now: discovery (further down) and the timing record (#144), which keys a suite on its
# path INSIDE this repo.
root="${HOOK_TESTS_ROOT:-}"
[ -n "$root" ] || root="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"

# Whether there is a REPOSITORY here at all (claude-config#155). Three suites in this repo audit
# the repository itself: the tracked files, and every suite in it. A deployed copy under the config
# directory has no repository above it, so those three cannot run there, and they reported that as
# a FAILURE: `bash ~/.claude/hooks/run-all-tests.sh`, which is the command CLAUDE.md tells people
# to run, said "3 of 32 SUITES FAILED" on 2026-08-22 while the same tree passed 38 of 38 from the
# checkout. Repeated fake failures are how a real one gets skimmed past (L36).
#
# So a suite may say it could not run here, and this is the runner's OWN answer to the same
# question, worked out from a different place than the suite's claim. Where a repository is
# present the claim is refused, so no suite can excuse itself from running anywhere at all (L70).
repo_present=0
if [ -n "$root" ] && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  repo_present=1
fi

# Where each suite's measured wall clock is kept between runs (claude-config#144). NOT under the
# config directory, which mirrors itself to another Mac within seconds: a duration measured on this
# machine is not configuration, and shipping it would make the other Mac order its runs by numbers
# from hardware it does not have.
#
# Set HOOK_TESTS_TIMINGS to move it, or to EMPTY to turn the record off, which is what a run that
# must leave no trace needs. `-` and not `:-`, so an empty value means off rather than default.
_timings_default="${XDG_CACHE_HOME:-$HOME/.cache}/claude-config/suite-timings"
TIMINGS="${HOOK_TESTS_TIMINGS-$_timings_default}"

# A record is keyed on the suite's path WITHIN the repo, so the same suite is recognised in a
# worktree, in a second clone, and on the other Mac. A suite that is not under the repo has no such
# path, so it gets no key and no record at all: there is nothing stable to key it on, and it is
# also what keeps a run over a throwaway fixture structurally unable to write into the real store.
# Nothing is truncated or trusted to be unique by luck: `/` and `%` are the only characters
# encoded, and both are encoded, so two different paths cannot produce one file name (L15).
suite_key(){   # suite_key <suite path> -> the record's file name, or nothing
  [ -n "$root" ] || return 0
  _sk="$1"
  case "$_sk" in /*) ;; *) _sk="$PWD/$_sk" ;; esac
  case "$_sk" in "$root"/*) ;; *) return 0 ;; esac
  printf '%s' "${_sk#"$root"/}" | sed 's/%/%25/g; s#/#%2F#g'
}

# What that suite was last measured at, or NOTHING. A record that is not a whole number of seconds
# is treated as no record rather than guessed at as a number: the store is a cache, and a corrupt
# entry there is not a reason to refuse to run the tests. Falling back is safe here in a way it
# usually is not, because the only thing the record decides is the launch ORDER, and being wrong
# about that costs wall clock and nothing else.
suite_seconds(){   # suite_seconds <suite path> -> whole seconds, or nothing
  [ -n "$TIMINGS" ] || return 0
  _ss_k="$(suite_key "$1")"
  [ -n "$_ss_k" ] || return 0
  _ss_v="$(cat "$TIMINGS/$_ss_k" 2>/dev/null)"
  case "$_ss_v" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$_ss_v"
}

dirs=""     # newline separated, deduplicated in the order found
add_dir(){  # add_dir <path>
  case "
$dirs" in *"
$1
"*) return 0 ;; esac
  dirs="$dirs$1
"
}

if [ "$#" -gt 0 ]; then
  for d in "$@"; do add_dir "$d"; done
  source_of_dirs="named on the command line"
else
  # Asked of git rather than of `find`, so a suite living in an untracked scratch
  # copy of the repo is not picked up and an ignored build directory costs nothing
  # to walk. The root itself was worked out further up, because the timing record
  # needs it too.
  if [ -n "$root" ] && [ -d "$root" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      base="${f##*/}"
      case "$base" in test-*.sh) ;; *) continue ;; esac
      sub="${f%/*}"
      if [ "$sub" = "$f" ]; then add_dir "$root"; else add_dir "$root/$sub"; fi
    done <<EOF
$(git -C "$root" ls-files 2>/dev/null || true)
EOF
    # A repo that was READ and held no suite is a failure, and specifically NOT a
    # reason to fall back to this script's own directory. That fallback is for the
    # case below, where there is no repo at all; reaching it from here reads the
    # REAL hooks directory while claiming to have read the one it was pointed at,
    # runs this script's own test suite, and recurses without end. Measured the
    # first time the empty-repo check existed: the run had to be killed by hand.
    # A remedy scoped to the symptom that was observed is absent in the
    # neighbouring, worse failure (L173).
    if [ -z "$dirs" ]; then
      echo "run-all-tests: $root holds no test-*.sh at all, so NOTHING would be verified. Refusing to report that as a clean run." >&2
      exit 1
    fi
    source_of_dirs="discovered in $root"
  else
    # No repo above this script, which is what an installed copy under the config
    # directory looks like. Its own directory is still worth reading, and saying
    # that a narrower run happened keeps it from reading as the full one (L11).
    add_dir "$SELF_DIR"
    source_of_dirs="no repo above $SELF_DIR, so only its own directory was read"
  fi
fi

if [ "${HOOK_TESTS_LIST_ONLY:-0}" = "1" ]; then
  printf '%s' "$dirs"
  exit 0
fi

echo "run-all-tests: $(printf '%s' "$dirs" | grep -c .) directory(ies), $source_of_dirs"

ran=0
failed=0
failed_names=""
empty_dirs=""
guessed_names=""

# Everything is discovered BEFORE anything runs, so the report order is fixed up front and an empty
# directory is known without waiting for the run.
suites=()
while IFS= read -r d; do
  [ -n "$d" ] || continue
  if [ ! -d "$d" ]; then
    empty_dirs="$empty_dirs  $d (no such directory)
"
    continue
  fi
  here=0
  for suite in "$d"/test-*.sh; do
    [ -e "$suite" ] || continue
    # The runner's own test suite is a suite like any other and is run as one. It
    # never invokes this script bare, and the guard at the top is what makes that
    # true rather than a convention anybody has to remember.
    [ "$suite" = "$SELF" ] && continue
    here=$((here + 1))
    suites+=("$suite")
  done
  if [ "$here" -eq 0 ]; then
    empty_dirs="$empty_dirs  $d
"
  fi
done <<EOF
$dirs
EOF

ran="${#suites[@]}"
if [ "$ran" -gt 0 ]; then
  # The share each suite may take. Worked out HERE, because it depends on how many suites there
  # actually are: naming one directory holding one suite gives that suite the whole machine, which
  # is what keeps a single suite run as fast as it was. The floor of 1 is not decoration, integer
  # division reaches 0 as soon as more suites run at once than the budget, and a suite told it may
  # start nothing would either refuse or ignore the grant.
  at_once=$(( JOBS < ran ? JOBS : ran ))
  [ "$at_once" -gt 0 ] || at_once=1

  # The budget is granted to LANES, not divided equally between suites (claude-config#139). An
  # equal division gave the one suite taking most of the wall clock no more of the machine than a
  # suite finishing in a second, and that suite is launched first and is the only thing still
  # running at the end, so for most of a run there was idle budget nothing could use: measured on
  # 2026-08-21, 124 seconds against 88 the oversubscribed way it replaced.
  #
  # There are `at_once` lanes, each with a share, and a suite is granted the share of the lane it
  # launches into. Lane 1 is the first launch, which is the longest suite, because the launch order
  # is longest first. It takes the largest share the budget allows while still leaving every other
  # lane a slot of its own.
  #
  # Never more than half the budget while anything else has to run. A grant is fixed for the life
  # of the suite, so handing one suite most of the machine would leave a second long suite crawling
  # on the remainder for the whole run, which is the same defect one level down.
  #
  # Nothing here learns WHICH suite shards, or is told that any suite is slow. The shares follow
  # from the budget and from how many suites can run at once, and a hand written list of the slow
  # ones is the thing this script exists to avoid (L96).
  if [ "$at_once" -eq 1 ]; then
    _lane_first="$BUDGET"
  else
    _half=$(( (BUDGET + 1) / 2 ))
    _lane_first=$(( BUDGET - (at_once - 1) ))
    [ "$_lane_first" -le "$_half" ] || _lane_first="$_half"
  fi
  # The floor of 1 is not decoration: subtraction and integer division both reach 0 as soon as more
  # suites run at once than the budget, and a suite told it may start nothing would either refuse
  # or ignore the grant. It is also the one case where the shares add up to more than the budget,
  # and the line below says so rather than printing the budget as if it had been kept to.
  [ "$_lane_first" -ge 1 ] || _lane_first=1
  LANES=("" "$_lane_first")
  _rest=$(( BUDGET - _lane_first ))
  [ "$_rest" -ge 0 ] || _rest=0
  _others=$(( at_once - 1 ))
  if [ "$_others" -gt 0 ]; then
    _base=$(( _rest / _others ))
    _extra=$(( _rest - _base * _others ))
    _l=2
    while [ "$_l" -le "$at_once" ]; do
      _g="$_base"
      [ "$(( _l - 1 ))" -le "$_extra" ] && _g=$(( _g + 1 ))
      [ "$_g" -ge 1 ] || _g=1
      LANES[$_l]="$_g"
      _l=$(( _l + 1 ))
    done
  fi

  # Said out loud, and as a total, because the number that matters is what will be in flight and
  # that number used to be printed nowhere at all: it could only be found by multiplying a default
  # in this file by a default in another one (L182). Equal shares are printed as one number, and
  # unequal ones are listed in lane order, because a single number would be a different fact from
  # what is actually granted.
  _in_flight=0; _shares=""; _shares_equal=1
  _l=1
  while [ "$_l" -le "$at_once" ]; do
    _in_flight=$(( _in_flight + ${LANES[$_l]} ))
    _shares="$_shares, ${LANES[$_l]}"
    [ "${LANES[$_l]}" = "${LANES[1]}" ] || _shares_equal=0
    _l=$(( _l + 1 ))
  done
  if [ "$_shares_equal" -eq 1 ]; then
    _how="${LANES[1]} slot(s) each"
  else
    _how="slots of ${_shares#, }"
  fi
  echo "run-all-tests: up to $at_once suite(s) at once, $_how, so at most $_in_flight process(es) at once, against a budget of $BUDGET"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.runner.XXXXXXXX")"
  case "${WORK%/}" in
    ''|/|"${HOME%/}") echo "run-all-tests: refusing to run: throwaway directory came back as '$WORK'." >&2; exit 1 ;;
  esac
  # Everything this run started, killed from the leaves up, and only ever DESCENDANTS: this must
  # never reach whatever started the runner (claude-config#165).
  runner_kill_tree(){   # $1 = a pid whose descendants are to go
    local c pp
    for c in $(pgrep -P "$1" 2>/dev/null); do
      [ "$c" = "$$" ] && continue
      # The parent is read again immediately before acting. The list above comes from a command
      # substitution, which is itself a child of this shell and is therefore IN it, and has exited
      # by the time the loop reaches it, so a kill on that number would land on whatever the system
      # has since given it to. Confirming the parent is what tells a live child from a recycled
      # number (L157).
      pp="$(ps -o ppid= -p "$c" 2>/dev/null | tr -d ' ')"
      [ "$pp" = "$1" ] || continue
      runner_kill_tree "$c"
      kill -9 "$c" 2>/dev/null || true
    done
    return 0
  }
  runner_cleanup(){
    # The suites first, then the scratch. This runner launches as many suites at once as the budget
    # worked out above allows, and a run killed from outside left every one of them going, each still
    # holding whatever lock its own suite takes and all of them competing for the machine. Removing WORK while they are alive
    # would take their output files with them and leave the processes behind, which is the worse
    # half of the same problem.
    runner_kill_tree "$$"
    [ -n "${WORK:-}" ] && rm -rf "$WORK"
    return 0
  }
  trap runner_cleanup EXIT
  # And on the signals an interrupt actually arrives as, which is how a run in development stops: a
  # harness timeout, a Ctrl-C, a terminal closing. EXIT alone covers a run that finishes, which is
  # the case that needed no help. Each handler ends in the status its own signal means; the EXIT
  # trap fires again on the way out and everything here is safe to do twice.
  trap 'runner_cleanup; exit 130' INT
  trap 'runner_cleanup; exit 143' TERM
  trap 'runner_cleanup; exit 129' HUP

  # Launched LONGEST FIRST, judged by what each suite was last MEASURED to cost (#144). Lane 1
  # carries the largest share of the budget and lane 1 is whatever launches first, so this line
  # decides which suite the machine is actually spent on.
  #
  # It used to be judged by file SIZE, which was right only because the largest file happened to
  # be the slowest suite. Bytes are not seconds, and the day those two came apart the big share
  # would have gone to a suite that cannot use it while the slow one ran on one slot. Nothing
  # would have reported that: the run would simply be slower, which is the symptom #139 existed
  # to remove.
  #
  # Size is still the fallback, and it is the honest one for a suite nobody has measured yet: a
  # first run and a newly added suite have no record, and inventing a duration for them would be
  # a number the code made up sitting beside numbers the machine reported (L192).
  #
  # Measured suites lead, in duration order, and unmeasured ones follow in size order. The other
  # way round would hand the largest share to a brand new suite every time one was added, purely
  # for being unknown. Which of the two a run used is printed below, because a run that fell back
  # to size reads exactly like one that ordered by measurement (L11).
  #
  # Nothing here learns WHICH suite is slow from a list anybody maintains. The record is written
  # by the run itself, at the bottom of this file, from the clock (L96).
  _timed=0
  launch_order="$(
    i=0
    for suite in "${suites[@]}"; do
      _sec="$(suite_seconds "$suite")"
      if [ -n "$_sec" ]; then _have=1; else _have=0; _sec=0; fi
      printf '%s	%s	%s	%s	%s\n' \
        "$_have" "$_sec" "$(wc -c < "$suite" | tr -d ' ')" "$i" "$suite"
      i=$((i + 1))
    done | sort -t "$(printf '\t')" -k1,1nr -k2,2nr -k3,3nr
  )"
  _timed="$(printf '%s\n' "$launch_order" | awk -F"$(printf '\t')" '$1 == 1' | grep -c . || true)"
  echo "run-all-tests: launch order from measured wall clock for ${_timed:-0} of $ran suite(s), file size for the rest"

  lane_pid=()
  _l=1
  while [ "$_l" -le "$at_once" ]; do lane_pid[$_l]=""; _l=$(( _l + 1 )); done
  while IFS="$(printf '\t')" read -r _have _sec _size idx suite; do
    [ -n "$suite" ] || continue
    # Wait for a LANE, and remember which one: the share a suite is handed is its lane's, so a
    # suite launching into a share that has just come free takes that share and the total in flight
    # stays put. bash 3.2 has no `wait -n`, so the lanes are polled; the sleep is short enough not
    # to matter beside a suite that takes seconds, and the loop can never spin free because it only
    # continues once a pid has really gone.
    lane=0
    while [ "$lane" -eq 0 ]; do
      _l=1
      while [ "$_l" -le "$at_once" ]; do
        p="${lane_pid[$_l]:-}"
        if [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; then lane="$_l"; break; fi
        _l=$(( _l + 1 ))
      done
      [ "$lane" -eq 0 ] && sleep 0.2
    done
    # SECONDS is a bash builtin reset to zero in this subshell, so timing a suite costs no
    # process of its own and cannot perturb what it is measuring. The exit status is written
    # LAST, because that file is what marks a suite finished and a reader of it must not find a
    # suite that has an exit status but no duration.
    ( SECONDS=0
      HOOK_TESTS_SLOTS="${LANES[$lane]}" bash "$suite" > "$WORK/$idx.out" 2>&1; _src=$?
      printf '%s' "$SECONDS" > "$WORK/$idx.sec"
      printf '%s' "$_src" > "$WORK/$idx.rc" ) &
    lane_pid[$lane]=$!
  done <<LAUNCH
$launch_order
LAUNCH
  wait

  # What this run MEASURED, written down for the next one (claude-config#144). This is the whole
  # source of the launch order above: no list anywhere names the slow suites, and nobody has to
  # remember to update one when a suite gets slower (L96).
  #
  # Written by the parent, after everything has finished, so there is exactly one writer and the
  # children never touch the store. Each record is its own file, written to a temporary name and
  # renamed over the old one, so two runs at once cannot interleave into a half written record and
  # neither can lose the other's work beyond the last one winning, which is the correct answer for
  # a measurement anyway.
  #
  # A suite that FAILED is recorded like any other. What is being measured is what the suite costs
  # the machine, and a suite that fails after doing all its work costs exactly what it did.
  #
  # Nothing is ever deleted here. A record for a suite that no longer exists is never read, since
  # records are looked up by the paths of the suites this run actually found, and a run over ONE
  # named directory legitimately mentions almost none of them. Deleting whatever a run did not
  # mention would turn every narrow run into a purge of everything else (L211).
  if [ -n "$TIMINGS" ]; then
    _rec_bad=0
    _rec_dir=1
    mkdir -p "$TIMINGS" 2>/dev/null || _rec_dir=0
    if [ "$_rec_dir" -eq 1 ]; then
      _ri=0
      for suite in ${suites[@]+"${suites[@]}"}; do
        _rk="$(suite_key "$suite")"
        _rv="$(cat "$WORK/$_ri.sec" 2>/dev/null)"
        _ri=$((_ri + 1))
        [ -n "$_rk" ] || continue
        case "$_rv" in ''|*[!0-9]*) continue ;; esac
        _rt="$TIMINGS/.writing.$$.$_rk"
        if printf '%s\n' "$_rv" > "$_rt" 2>/dev/null && mv -f "$_rt" "$TIMINGS/$_rk" 2>/dev/null; then
          :
        else
          rm -f "$_rt" 2>/dev/null
          _rec_bad=$((_rec_bad + 1))
        fi
      done
    fi
    # Said out loud, never swallowed. A store that cannot be written leaves every future run
    # ordering by file size while reading as though it were ordering by measurement, and the only
    # symptom of that is a run that is slower than it needs to be (L11, L98).
    if [ "$_rec_dir" -eq 0 ]; then
      echo "run-all-tests: could not create $TIMINGS, so nothing was recorded and the next run will order by file size. Set HOOK_TESTS_TIMINGS to somewhere writable, or to empty to turn the record off." >&2
    elif [ "$_rec_bad" -gt 0 ]; then
      echo "run-all-tests: $_rec_bad suite time(s) could not be written to $TIMINGS, so the next run will order those by file size." >&2
    fi
  fi
fi

# Reported in the order they were FOUND. Two runs of the same tree then produce the same page, so a
# difference between them is a difference in the suites rather than in the machine's mood.
#
# Each line also carries what that suite COST (claude-config#150). #144 already measured it and
# wrote it down, and the launch order is decided by it, but nothing said the number to a person, so
# "the full run got slower" named no suite anybody could act on. That is the gap #107 closed one
# level down, inside the sync suite, by giving every section its own duration and ending with the
# slowest ones named.
#
# Read from what THIS run measured, never from the timing store. The two hold the same figure by
# the time this loop runs, and the measurement is the one that survives the store being switched
# off, unwritable, or absent for a suite that lives outside the repo and has no key. The store also
# keeps records for suites that no longer exist, deliberately unpruned, so a summary fed from it
# would name suites this run never found.
slow_profile=""
unmeasured_names=""
notrun=0
notrun_names=""
idx=0
for suite in ${suites[@]+"${suites[@]}"}; do
    name="$(basename "$suite")"
    out="$(cat "$WORK/$idx.out" 2>/dev/null)"
    code="$(cat "$WORK/$idx.rc" 2>/dev/null)"
    # A suite that left no duration is SAID to have left none. Printing 0s instead would be the
    # most reassuring figure available: it reads as a suite that cost nothing rather than as one
    # nobody measured, and a run where everything was killed would read as an instant run (L11,
    # L90). The duration is written before the exit status, so a suite with neither was killed or
    # never started and the line below already says that too.
    secs="$(cat "$WORK/$idx.sec" 2>/dev/null)"
    case "$secs" in
      ''|*[!0-9]*)
        dur="(not measured)"
        unmeasured_names="$unmeasured_names $name" ;;
      *)
        dur="(${secs}s)"
        slow_profile="$slow_profile$(printf '%06d\t%s' "$secs" "$name")
" ;;
    esac
    case "$code" in ''|*[!0-9]*) code=1; out="$out
run-all-tests: this suite left no exit status, so it was killed or never started." ;; esac
    idx=$((idx + 1))
    # A suite that could not run HERE, said in one agreed shape exactly as the score is
    # (claude-config#155). Its own outcome, never folded into ok and never into FAIL: a suite that
    # did not run must not read as one that passed (L98), and it must not read as broken code
    # either, or the reader is sent looking for a fault that is not there (L11).
    nr_line="$(printf '%s\n' "$out" | grep -E '^SUITE-NOT-RUN ' | tail -1)"
    if [ -n "$nr_line" ]; then
      nr_reason="${nr_line#SUITE-NOT-RUN }"
      if [ "$repo_present" -eq 1 ]; then
        # It says it cannot run, and the runner found a repository, so the two disagree. That is a
        # broken suite rather than a place it cannot run, and it fails the run.
        failed=$((failed + 1))
        failed_names="$failed_names $name"
        printf '  FAIL  %-38s %-26s %s\n' "$name" "claimed it could not run" "$dur"
        printf '          It printed SUITE-NOT-RUN, but a repository WAS found at %s, so nothing was stopping it.\n' "$root"
        printf '          The reason it gave: %s\n' "$nr_reason"
        continue
      fi
      notrun=$((notrun + 1))
      notrun_names="$notrun_names $name"
      printf '  NOT RUN %-37s %s\n' "$name" "$nr_reason"
      continue
    fi
    # The suite's own result line, which is ONE agreed shape every suite in this repo prints:
    # `SUITE-RESULT passed=<n> failed=<n>`. Read exactly, so there is nothing to recognise and
    # nothing to guess (claude-config#126).
    #
    # Before it, thirty six suites wrote their totals five different ways and this had to work out
    # which line was the score. It got that wrong twice in one day: it printed
    # `ok: #105 even though every check inside it passed` in the column where a verdict belongs,
    # and once that was fixed it read `PASS=805 FAIL=0` as 805 failures, because the two count
    # forms read as one alternation match "805 FAIL". A number the producer already knows exactly
    # should never be recovered by pattern matching its prose (L107).
    result="$(printf '%s\n' "$out" | grep -E '^SUITE-RESULT passed=[0-9]+ failed=[0-9]+$' | tail -1)"
    guessed=0
    if [ -n "$result" ]; then
      p_count="${result#*passed=}"; p_count="${p_count%% *}"
      tally="${result#*failed=}"
      summary="$p_count passed, $tally failed"
    else
      # The fallback, kept because a suite can legitimately exit before it prints anything (no
      # python3, no jq, a refusal), and because a suite from outside this repo would not know the
      # convention. It SAYS it was used: a reader that quietly guesses is how the two defects above
      # survived, and drift back to guessing has to be visible rather than comfortable (L93).
      guessed=1
      guessed_names="$guessed_names $name"
      summary="$(printf '%s\n' "$out" | grep -EI '[Pp][Aa][Ss][Ss][A-Za-z]*[^0-9]{0,4}[0-9]+|[0-9]+[^0-9]{0,4}[Pp][Aa][Ss][Ss]' \
                   | grep -EI '[Ff][Aa][Ii][Ll][A-Za-z]*[^0-9]{0,4}[0-9]+|[0-9]+[^0-9]{0,4}[Ff][Aa][Ii][Ll]' | tail -1)"
      # The count AFTER the word is tried first and the count before it only if that finds nothing,
      # because the two forms are not exclusive and read as one alternation `PASS=805 FAIL=0`
      # matches "805 FAIL".
      tally="$(printf '%s' "$summary" | grep -Eio 'fail(ed|ure)?[^0-9A-Za-z]{0,3}[0-9]+' | tail -1 | grep -Eo '[0-9]+' || true)"
      if [ -z "$tally" ]; then
        tally="$(printf '%s' "$summary" | grep -Eio '[0-9]+ +fail(ed|ure)?' | tail -1 | grep -Eo '[0-9]+' || true)"
      fi
      [ -n "$summary" ] || summary="(no result line, and no tally could be read)"
    fi
    if [ "$code" -ne 0 ] || { [ -n "$tally" ] && [ "$tally" -gt 0 ]; }; then
      failed=$((failed + 1))
      failed_names="$failed_names $name"
      printf '  FAIL  %-38s %-26s %s\n' "$name" "$summary" "$dur"
      # And WHY. A one line verdict is enough on a machine where you can just run the suite
      # again; it is useless where you cannot, which is the whole point of running these
      # somewhere else (claude-config#101). The failing lines are printed, and the count is
      # said out loud when there are more than fit, so a truncated report cannot read as a
      # complete one.
      detail="$(printf '%s\n' "$out" | grep -E '^ *(FAIL|not ok)' || true)"
      [ -n "$detail" ] || detail="$(printf '%s\n' "$out" | tail -n "$FAIL_DETAIL_MAX")"
      shown="$(printf '%s\n' "$detail" | grep -c . || true)"
      printf '%s\n' "$detail" | head -n "$FAIL_DETAIL_MAX" | sed 's/^/          /'
      if [ "${shown:-0}" -gt "$FAIL_DETAIL_MAX" ]; then
        printf '          ...and %s more line(s) not shown\n' "$(( shown - FAIL_DETAIL_MAX ))"
      fi
    else
      printf '  ok    %-38s %-26s %s\n' "$name" "$summary" "$dur"
    fi
done

echo
# The slowest, named, which is what somebody reads when a run got slower (claude-config#150). Built
# from the suites this run actually FOUND and actually measured, so it can never name a suite that
# is no longer in the repo, and a suite nobody measured is named separately rather than sorted in
# at zero.
if [ -n "$slow_profile" ]; then
  echo "slowest suites:"
  # `awk NR<=5` rather than `head -5`, which leaves on its fifth line and can kill its own producer
  # under pipefail (claude-config#132, L183).
  printf '%s' "$slow_profile" | sort -r | awk 'NR <= 5' | while IFS="$(printf '\t')" read -r _pd _pn; do
    [ -n "$_pn" ] || continue
    printf '  %ds %s\n' "$((10#$_pd))" "$_pn"
  done
  echo
fi
if [ -n "$unmeasured_names" ]; then
  echo "NO DURATION was measured for:$unmeasured_names"
  echo "  They are missing from the timings above rather than counted as instant."
fi
if [ -n "$guessed_names" ]; then
  # Named, not counted. A suite whose score had to be guessed is one whose verdict this run is less
  # sure of, and the two defects that guessing caused were both found by reading the column, so the
  # names are what a person needs (L11).
  echo "NO RESULT LINE from:$guessed_names"
  echo "  Their scores were guessed from their prose. A suite that ran should print"
  echo "  SUITE-RESULT passed=<n> failed=<n> as the last thing it says."
fi
if [ -n "$empty_dirs" ]; then
  echo "NO TEST SUITES FOUND in these directories, so whatever lives in them was NOT verified:"
  printf '%s' "$empty_dirs"
fi
if [ "$ran" -eq 0 ]; then
  echo "NOTHING WAS RUN. Treat this as a failure."
  exit 1
fi
if [ "$notrun" -gt 0 ]; then
  # Named and counted, above the verdict, because the verdict below deliberately no longer says
  # "ALL n SUITES PASSED" when some of them never ran (claude-config#155, L98).
  echo "$notrun SUITE(S) COULD NOT RUN HERE:$notrun_names"
  echo "  They audit the repository, and this is a copy with no repository above it."
  echo "  Run them from the checkout to have them verified."
  echo
fi
if [ "$failed" -eq 0 ] && [ -z "$empty_dirs" ]; then
  if [ "$notrun" -gt 0 ]; then
    echo "ALL $(( ran - notrun )) SUITES THAT COULD RUN PASSED, and $notrun could not run here"
  else
    echo "ALL $ran SUITES PASSED"
  fi
  exit 0
fi
[ "$failed" -eq 0 ] || echo "$failed of $ran SUITES FAILED:$failed_names"
exit 1
