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
#   HOOK_TESTS_FLAKE_RECHECK  0 turns off the second run of a suite that failed (default 1)
#   HOOK_TESTS_FLAKE_RECHECK_MAX   seconds a recheck may take before it is called hung (default 60)
#   HOOK_TESTS_FLAKE_RECHECK_POLL  how long each wait for it lasts (default 1)
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
# How many lines a suite may mark with SUITE-NOTE before the report truncates them
# (claude-config#505). Small on purpose: this is for a measurement worth watching, not a second
# output channel, and a suite that wants more than a few is telling the reader nothing.
SUITE_NOTE_MAX="${SUITE_NOTE_MAX:-3}"
FAIL_DETAIL_MAX="${HOOK_TESTS_FAIL_DETAIL_MAX:-40}"
# Run a suite that FAILED once more, purely to find out whether it is a flake (claude-config#245).
# On by default because the cost is paid only by a run that is already red, and off inside the
# recheck itself so a suite that fails every time cannot recurse.
FLAKE_RECHECK="${HOOK_TESTS_FLAKE_RECHECK:-1}"
# The floor on how long a recheck may take. Raised to three times what the suite measured on its
# first run, so a slow suite is not called hung for being slow, and a suite with no measurement at
# all still has this bound.
FLAKE_RECHECK_MAX="${HOOK_TESTS_FLAKE_RECHECK_MAX:-60}"
# The interval the recheck's deadline is counted in. Injectable from the day it is written, so the
# test that drives the timeout branch is instant instead of waiting the deadline out for real
# (L524). Both numbers are read in the same unit, so setting this alone shortens the wait without
# changing what the deadline MEANS.
FLAKE_RECHECK_POLL="${HOOK_TESTS_FLAKE_RECHECK_POLL:-1}"

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
_ncpu="$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) | awk 'NR <= 1' )"
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

# Did a store only GAIN lines while the run went on? (claude-config#277)
#
# The stores on the list have writers that are not these tests and cannot be told from them by a
# checksum: the sync applying a pull, and another Claude session recording a lesson, which is what
# actually failed two green runs on 2026-09-02. Both of those only ever ADD to these files, in the
# section an entry belongs in, and what a suite bound to the real path does is rewrite the file
# wholesale or truncate it. So the SHAPE of the change is the evidence, and it is read from a copy
# taken before the run rather than guessed at from a size (L63).
#
# This stands down on additions and nothing else. A line removed or changed is still counted, which
# is the destructive shape and the one worth a full re-run. The route a suite would actually take
# into these files is refused at its source now: claude-sync will not apply into the real config
# while CLAUDE_SUITE_RUN_ID is set.
live_store_only_gained(){ # <path> -> 0 when the change only added lines
  local path="$1" copy
  [ -n "${_live_copies:-}" ] || return 1
  [ -f "$_live_copies/index" ] || return 1
  copy="$(awk -F"$(printf '\t')" -v f="$path" '$1 == f { print $2; exit }' "$_live_copies/index")"
  [ -n "$copy" ] && [ -f "$copy" ] || return 1     # absent before, so this is a creation
  [ -f "$path" ] || return 1                        # gone now, which is not a gain
  # Lines present in the copy and missing now are what disqualifies it. `diff` prints those with a
  # leading `<`, so an empty result means every difference was an addition.
  [ -z "$(diff "$copy" "$path" 2>/dev/null | grep '^<' || true)" ]
}

# Did the SYNC apply config into this Mac while the run was going? (claude-config#277)
#
# The stores on the list above are the config the sync installs, and the watch daemon installs it
# the moment the other Mac pushes: a run of 44 suites was failed on 2026-09-02 by LESSONS.md growing
# by 1,177 bytes, which was a lesson the other Mac had recorded arriving here. The guard's own
# comment said nothing else legitimately writes these during a run, and that was false for three
# separate stores in one day (L375).
#
# Read from what the sync writes about ITSELF rather than guessed at: every clone rewrites
# .last-applied on each apply, so its mtime is when the last one happened, and the clone registry
# names the clones. An apply inside this run's own window explains a change to any of these stores,
# because these stores are exactly what an apply writes. Outside that window it explains nothing and
# the change is this run's doing as before.
_file_mtime(){ # <path> -> a unix timestamp, or nothing
  local m
  m="$(stat -f %m "$1" 2>/dev/null || true)"
  case "$m" in ''|*[!0-9]*) m="$(stat -c %Y "$1" 2>/dev/null || true)" ;; esac
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$m"
}
sync_applied_since(){ # <unix timestamp> -> prints the clone and when, empty when none did
  local since="$1" reg clone m
  case "$since" in ''|*[!0-9]*) return 1 ;; esac
  reg="${SYNC_CLONE_REGISTRY:-$HOME/.claude-sync-clones}"
  [ -f "$reg" ] || return 1
  while IFS= read -r clone; do
    [ -n "$clone" ] || continue
    [ -d "$clone" ] || continue
    m="$(_file_mtime "$clone/.last-applied")" || continue
    [ "$m" -ge "$since" ] || continue
    printf '%s at %s' "$clone" "$(date -r "$m" '+%H:%M:%S' 2>/dev/null || printf '%s' "$m")"
    return 0
  done < "$reg"
  return 1
}

# Did something OUTSIDE this run rewrite the watcher marker? (claude-config#272)
#
# The marker is on the live-store list like the rest, and unlike the rest it has a legitimate
# writer that is not a suite: launchd keeps the watch daemon alive and it restarts on its own, 562
# times by 2026-09-02 on this Mac, and one of those restarts landed inside the very run that added
# the store to the list. A plain comparison there is a false red on a green run, priced at a full
# re-run and arriving when the machine is busiest (L36, L293).
#
# Judged rather than compared, and judged positively: the marker names a pid. A watcher a SUITE
# started is a descendant of this run. One a suite started and stopped leaves a pid that is dead,
# and the live daemon's marker never does, because it removes the file on the way out and launchd
# starts a new one. So anything alive that this run is not an ancestor of belongs to somebody else.
watch_marker_is_not_ours(){ # <marker path> -> 0 when something outside this run owns it
  local pid p hops=0
  [ -f "$1" ] || return 1
  # `read` reports failure at end of file even when it filled the variable, and a marker written
  # without a trailing newline is exactly that, so the value is judged rather than the exit code.
  read -r pid < "$1" 2>/dev/null || true
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  p="$pid"
  while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$hops" -lt 40 ]; do
    [ "$p" = "$$" ] && return 1
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    case "$p" in ''|*[!0-9]*) break ;; esac
    hops=$(( hops + 1 ))
  done
  return 0
}

# WHICH copy a re-run verified (claude-config#274). Every other suite in a pull's run is checking
# what the pull just installed; a suite re-run from the checkout is checking the checkout's copy of
# the same file, and the line read as an ordinary pass either way. The gap is normally nil, because
# the pull installed from that checkout moments earlier, and it is exactly non nil in the two cases
# that matter: an edit nobody has sent, and a checkout behind what is deployed (L11).
#
# The checkout holds .last-applied, which the pull writes with the commit whose payload is on this
# Mac, so this SAYS whether the two agree rather than assuming it. No pipes: a pipeline whose
# consumer leaves early can report a failure that never happened (L183), and there is nothing here
# expensive enough to want one.
checkout_provenance(){ # checkout_provenance <checkout dir> -> the sentence for the line under it
  local co="${1%/}" head applied dirty=""
  head="$(git -C "$co" rev-parse --short=7 HEAD 2>/dev/null || true)"
  [ -n "$(git -C "$co" status --porcelain -- payload 2>/dev/null || true)" ] \
    && dirty=" It has uncommitted changes under payload, so this verdict is about an edit that has not been sent."
  if [ -z "$head" ]; then
    printf 'Verified the copy in %s, whose revision could not be read, not the copy installed here.%s' "$co" "$dirty"
    return 0
  fi
  applied=""
  [ -f "$co/.last-applied" ] && read -r applied < "$co/.last-applied" 2>/dev/null
  if [ -z "$applied" ]; then
    printf 'Verified the copy in %s at %s, and nothing there records what the pull applied, not the copy installed here.%s' "$co" "$head" "$dirty"
  elif [ "${applied#"$head"}" != "$applied" ]; then
    printf 'Verified the copy in %s at %s, which is what the pull applied, not the copy installed here.%s' "$co" "$head" "$dirty"
  else
    printf 'Verified the copy in %s at %s, which is NOT what the pull applied (%s), not the copy installed here.%s' "$co" "$head" "$applied" "$dirty"
  fi
}

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
# A record is `<seconds>` or `<seconds> <checks>`. It was seconds alone until #219 needed a second
# perishable number about the same suite, and one record with two fields is the answer rather than
# a second store: the two facts are written by the same run, read by the same reader, and switched
# off by the same empty HOOK_TESTS_TIMINGS. A second store would be a second absence to announce
# and a second thing to key correctly (L15).
#
# Every record on disk the day this ships holds seconds alone, so the second field is OPTIONAL on
# the way in and the first is read the same way either way. A reader of one field that refused a
# record carrying two would have turned the next run into a cold start (L255).
suite_record_field(){   # suite_record_field <suite path> <1 or 2> -> that field, or nothing
  [ -n "$TIMINGS" ] || return 0
  _sr_k="$(suite_key "$1")"
  [ -n "$_sr_k" ] || return 0
  _sr_v="$(awk -v f="$2" 'NR == 1 { print $f }' "$TIMINGS/$_sr_k" 2>/dev/null)"
  case "$_sr_v" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$_sr_v"
}

suite_seconds(){   # suite_seconds <suite path> -> whole seconds, or nothing
  suite_record_field "$1" 1
}

# How many checks that suite ran last time (claude-config#219), or NOTHING, which is what a first
# run, a newly added suite and every record written before this field existed all report. Nothing
# is not zero here and must never be rendered as one: a suite compared against a stored zero has
# dropped nothing by definition, so the one case this exists to catch would be the one it stayed
# quiet about (L90, L98).
suite_checks(){   # suite_checks <suite path> -> whole checks, or nothing
  suite_record_field "$1" 2
}

# The ONE place a suite's own score is read (claude-config#126). Exactly, so there is nothing to
# recognise and nothing to guess: thirty six suites once wrote their totals five different ways and
# the reader got it wrong twice in one day. Two things now need this line, the verdict and the
# check count #219 compares between runs, and a second copy of the parse would be a second rule
# about what a score is (L263).
suite_result_line(){   # suite_result_line <a suite's output> -> the exact line, or nothing
  printf '%s\n' "$1" | grep -E '^SUITE-RESULT passed=[0-9]+ failed=[0-9]+$' | tail -1
}

# How many checks that line reports: passed PLUS failed, which is how many checks RAN. Passed alone
# would read a suite whose checks turned red as a suite that lost checks, and those are opposite
# problems needing opposite reactions (L63).
suite_result_checks(){   # suite_result_checks <a suite's output> -> the count, or nothing
  _src_l="$(suite_result_line "$1")"
  [ -n "$_src_l" ] || return 0
  _src_p="${_src_l#*passed=}"; _src_p="${_src_p%% *}"
  _src_f="${_src_l#*failed=}"
  printf '%s' "$(( _src_p + _src_f ))"
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
flaky=0
flaky_names=""
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
  # never reach whatever started the runner (claude-config#165). Through the one shared
  # implementation, which used to be a third copy of the same walk living here (#169).
  # Overridable so a test can point it at a deliberately broken copy and check that the difference
  # is visible. Nothing in normal use sets it, and the default IS the helper beside this file.
  RUNNER_KILL_TREE="${HOOK_KILL_TREE:-$(dirname "$SELF")/lib/kill-tree.sh}"
  runner_kill_tree(){   # $1 = a pid whose descendants are to go
    [ -f "$RUNNER_KILL_TREE" ] || return 0
    bash "$RUNNER_KILL_TREE" "$1" "" 2>/dev/null || true
    return 0
  }
  if [ ! -f "$RUNNER_KILL_TREE" ]; then
    # Said out loud rather than degraded to doing nothing: a cleanup that silently stops killing
    # anything looks exactly like a run that had nothing to clean up (L98), and leaving the suites
    # running is the state #165 exists to end.
    echo "run-all-tests: no kill-tree helper at $RUNNER_KILL_TREE, so an interrupted run will NOT clean up the suites it started. They will keep running and keep competing for this machine." >&2
  fi
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
  # THE LIVE SPOOL, before anything runs. No suite may write into Dan's real
  # store of subagent findings, and for weeks one did: test-blank-check-cost.sh
  # sourced the spool library and only then set the override, so the location had
  # already been bound to the real one and every run left a fake finding behind.
  # 120 of them accumulated on one machine, and nothing anywhere said so; they
  # were found by looking at what a migration could not place (L2).
  #
  # Fixing that suite does not stop the next one, so this is a ratchet on the
  # class: the whole run is bracketed by a listing of the real spool, and any
  # change at all is reported (L30).
  _live_spool="${CLAUDE_ISSUE_SPOOL_DIR:-$HOME/.claude-issue-spool}"
  _spool_before="$(ls -1 "$_live_spool" 2>/dev/null | sort)"
  _spool_before_bytes="$(cat "$_live_spool"/*.jsonl 2>/dev/null | wc -c | tr -d ' ')"
  # Each file's own size, so what was ADDED can be read back rather than only counted
  # (claude-config#230). The totals alone cannot say WHO wrote, and the spool is a machine wide
  # store with other legitimate writers: this Mac routinely has several Claude sessions going, and
  # a harvest firing in another project during a run reads here as a suite violating L2. Measured
  # 2026-08-30, a green run of all 44 suites was failed by 1,180 bytes written by a session working
  # in a different repository entirely.
  # ONE `wc`, not one per file (claude-config#239). The loop forked once per spool file, and the
  # real spool on this Mac holds 157 of them: measured 2026-09-03, that was 414ms of a 600ms
  # launch, paid by every run of this runner and by 65 of the 69 launches its own suite makes.
  # `wc -c` over the whole glob prints the same size and path per line, and the ordering does not
  # matter because every reader looks a path up by name. It also prints a "total" line, which is
  # dropped for clarity rather than for safety: a row keyed "total" cannot match a path, so leaving
  # it in changes nothing, and a test was written expecting it to matter and did not discriminate.
  _spool_sizes_before="$(wc -c "$_live_spool"/*.jsonl 2>/dev/null \
    | awk '$2 != "total" && NF >= 2 { printf "%s\t%s\n", $1, $2 }')"

  # WHO wrote, answered positively (claude-config#275). Reading the directory off the record tells
  # a suite from another project's session, which is what #230 needed, and it cannot tell a suite
  # from a second Claude session working in THIS repo, which is the normal case here: measured
  # 2026-09-02, a run was failed by two HARVEST FAILED records the real SubagentStop hook wrote for
  # another session, cwd this repo, at a moment when no suite in the tree could have written there.
  #
  # So the run stamps its own writes. Every suite inherits this id, the spool library puts it in
  # every record it appends, and a record carrying one was written under a test run whatever
  # directory it names. A record carrying none was not. That is one fact rather than a heuristic on
  # top of a heuristic (L70).
  CLAUDE_SUITE_RUN_ID="run-all-tests.$$.$(date +%s)"
  export CLAUDE_SUITE_RUN_ID

  # And the stamp is PROVED before an absence is read as evidence. A stamping that quietly stopped
  # would make every write read as somebody else's, which is this guard going blind while passing,
  # and the guard would be the last thing to say so (L345, L98). One record through the real
  # library into a throwaway spool answers it. When it cannot be proved the run says so and falls
  # back to judging by directory, which is what it did before and fails closed.
  _sp_marker_works=0
  _sp_lib="${HOOK_SPOOL_LIB:-$SELF_DIR/lib/issue-spool.sh}"
  if [ -r "$_sp_lib" ]; then
    _sp_canary="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.spool-proof.XXXXXXXX" 2>/dev/null || true)"
    if [ -n "$_sp_canary" ]; then
      (
        # shellcheck disable=SC1090
        . "$_sp_lib" >/dev/null 2>&1 || exit 1
        CLAUDE_ISSUE_SPOOL_DIR="$_sp_canary" issue_spool_note "$_sp_canary" \
          "proving that a write made under a test run is stamped with the run id" run-all-tests \
          >/dev/null 2>&1
      )
      grep -q -- "$CLAUDE_SUITE_RUN_ID" "$_sp_canary"/*.jsonl 2>/dev/null && _sp_marker_works=1
      rm -rf "$_sp_canary" 2>/dev/null || true
    fi
  fi
  if [ "$_sp_marker_works" -eq 0 ]; then
    echo "run-all-tests: a suite's own write to the live spool could not be proved to carry this run's id ($_sp_lib), so a write is attributed by the directory it names instead. That cannot tell a suite from another session working in this repo."
  fi

  # ---- and the other live stores (claude-config#216) ----
  # The bracket above covers the store the incident happened in. The same class of mistake reaches
  # the rule files every session loads, the settings, the clone registry and the shell rc, and
  # each would be just as silent: a suite that sources a library before setting its override binds
  # to the real path, and nothing anywhere would say so.
  #
  # The generated lessons index is one file per section of LESSONS.md since claude-config#473, so
# those are ENUMERATED from disk rather than written out here: a list typed in would cover whatever
# the sections were the day somebody typed it (L41). The retired single name is still listed, so a
# suite that recreates it is caught as a creation. What the enumeration gives up is a file a suite
# CREATES under a section name that did not exist when the run started, which nothing here sees.
#
# A LIST, so adding a store is one line rather than a new guard. Compared on content, which is
  # what a rule file being damaged actually looks like: a suite that rewrites LESSONS.md with the
  # same number of bytes changes no size at all, and a size-only bracket would report that as
  # clean (L63). Attribution is deliberately NOT attempted here: unlike the spool, nothing else on
  # this machine legitimately writes these during a test run, so any change at all is this run's
  # doing and there is nothing to tell apart.
  _live_stores="${CLAUDE_HOME:-$HOME/.claude}/LESSONS.md
${CLAUDE_HOME:-$HOME/.claude}/LESSONS-INDEX.md
${CLAUDE_HOME:-$HOME/.claude}/CLAUDE.md
${CLAUDE_HOME:-$HOME/.claude}/LESSONS-CORE.txt
$(for _lsx in "${CLAUDE_HOME:-$HOME/.claude}"/LESSONS-INDEX-*.md "${CLAUDE_HOME:-$HOME/.claude}"/LESSONS-CORE-*.md; do [ -f "$_lsx" ] && printf '%s\n' "$_lsx"; done)
${CLAUDE_HOME:-$HOME/.claude}/settings.json
${SYNC_CLONE_REGISTRY:-$HOME/.claude-sync-clones}
${SYNC_ZSHRC:-$HOME/.zshrc}
${SYNC_WATCH_PID_FILE:-$HOME/.claude-sync-watch.pid}
${SYNC_HOLD_FILE:-$HOME/.claude-sync-hold}"
  # The last two are the watcher's own markers, added to the list by claude-config#272: they were
  # created in the same commit as this guard and left off it, so a suite that ran `claude-sync
  # watch` or `claude-sync hold` without pointing the seam at its own throwaway path wrote into the
  # real home and nothing said so. The pid marker is the one with teeth, since a stale one makes
  # the live daemon refuse to start, which stops config reaching the other Mac from a green run.
  #
  # A path that is not there is recorded as absent rather than skipped, so a suite that CREATES
  # one is caught by the same comparison. Skipping it would make creating a file the one write
  # this cannot see (L98, L214). That half was a claim until #272: neither it nor the comparison
  # had ever been seen to fire, and both now are (L1).
  _live_fingerprint(){
    local f
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ -f "$f" ]; then printf '%s\t%s\n' "$f" "$(cksum < "$f" 2>/dev/null || echo unreadable)"
      else printf '%s\tabsent\n' "$f"
      fi
    done <<LIVESTORES
$_live_stores
LIVESTORES
  }
  _live_before="$(_live_fingerprint)"
  _live_started="$(date +%s)"
  # A COPY of each store as well as its fingerprint, because the verdict below needs to know what
  # KIND of change happened and a checksum cannot say (claude-config#277). These files total well
  # under a megabyte, so this costs nothing measurable beside a run of minutes.
  _live_copies="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.live-copies.XXXXXXXX" 2>/dev/null || true)"
  if [ -n "$_live_copies" ]; then
    _lcp_n=0
    while IFS= read -r _lcp_f; do
      [ -n "$_lcp_f" ] || continue
      _lcp_n=$((_lcp_n + 1))
      printf '%s\t%s\n' "$_lcp_f" "$_live_copies/$_lcp_n" >> "$_live_copies/index"
      [ -f "$_lcp_f" ] && cp "$_lcp_f" "$_live_copies/$_lcp_n" 2>/dev/null
    done <<LIVECOPY
$_live_stores
LIVECOPY
  fi

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
  # And the order itself, named, before anything starts (claude-config#209). The line above says
  # which RULE was used and this one says what that rule produced, which are different facts: a
  # run can order by measurement and still put the wrong suite first if the records are stale.
  #
  # It is also the only load-proof way to check the rule. The lane a suite is handed is two removes
  # from the order (a lane is reused the moment the suite in it finishes), so a check that reads a
  # lane is really reading how busy the machine was, and one did: it failed once in 233 CI runs and
  # cost a full re-run to learn nothing (L293). This is computed here, before the first launch, so
  # nothing the machine does afterwards can move it.
  echo "run-all-tests: launch order: $(printf '%s\n' "$launch_order" | awk -F"$(printf '\t')" 'NF{printf "%s%s", (NR>1 ? " " : ""), $5}' | sed "s#[^ ]*/##g")"

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
  # What this run ran, and what the LAST one ran, both read before a single record is rewritten
  # (claude-config#219). The order matters and is the whole of it: the write below replaces the
  # record this comparison is against, so reading afterwards would compare every suite with itself
  # and no drop could ever be seen (L105).
  now_checks=(); prev_checks=()
  _ci=0
  for suite in ${suites[@]+"${suites[@]}"}; do
    now_checks[$_ci]="$(suite_result_checks "$(cat "$WORK/$_ci.out" 2>/dev/null)")"
    prev_checks[$_ci]="$(suite_checks "$suite")"
    _ci=$((_ci + 1))
  done

  if [ -n "$TIMINGS" ]; then
    _rec_bad=0
    _rec_dir=1
    mkdir -p "$TIMINGS" 2>/dev/null || _rec_dir=0
    if [ "$_rec_dir" -eq 1 ]; then
      _ri=0
      for suite in ${suites[@]+"${suites[@]}"}; do
        _rk="$(suite_key "$suite")"
        _rv="$(cat "$WORK/$_ri.sec" 2>/dev/null)"
        # The check count joins the duration in the same record. A suite that left no score line
        # (it was killed, it refused, it comes from outside this repo) records its seconds alone
        # rather than a fabricated zero, so the next run reads no count for it and says it had
        # none, instead of reporting that everything it had is gone (L90).
        _rc="${now_checks[$_ri]:-}"
        _ri=$((_ri + 1))
        [ -n "$_rk" ] || continue
        case "$_rv" in ''|*[!0-9]*) continue ;; esac
        # A suite that left NO result line is not recorded at all (claude-config#229). It was
        # recorded, and what it recorded was however long it took to refuse: the sync suite exits
        # in well under a second when it meets its own lock, so one overlapping run wrote a zero
        # over a real measurement, and the launch order then put the slowest suite in this repo
        # second from last while this script reported a measured order for all of them. Observed
        # 2026-08-30, where the record read zero against a suite measured at 231 seconds in the
        # same session. The run is simply slower and nothing reads as wrong (L330).
        #
        # Zero seconds is a true measurement of a suite that did nothing and an honest measurement
        # of a suite that had nothing to do, and the store holds only the number. What separates
        # them is already here: a suite that did its work prints its own SUITE-RESULT line, and one
        # that refused, died, or could not run here does not.
        #
        # The existing record is LEFT ALONE rather than cleared, because the last run that really
        # did the work is a better answer than none, and being wrong about launch order costs wall
        # clock and nothing else.
        case "$_rc" in ''|*[!0-9]*) continue ;; esac
        case "$_rc" in ''|*[!0-9]*) _rline="$_rv" ;; *) _rline="$_rv $_rc" ;; esac
        _rt="$TIMINGS/.writing.$$.$_rk"
        if printf '%s\n' "$_rline" > "$_rt" 2>/dev/null && mv -f "$_rt" "$TIMINGS/$_rk" 2>/dev/null; then
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
# How many suites this run could compare against the last one (claude-config#219). Said out loud
# for the same reason the launch order's rule is: a run that compared NOTHING prints exactly the
# silence of a run in which nothing dropped, and the silence is the entire signal here (L98). A
# first run, a store switched off, a store nobody could write and a suite added today all reach
# this line as a smaller number rather than as no line at all.
if [ "$ran" -gt 0 ]; then
  _cmp=0
  _ci=0
  while [ "$_ci" -lt "$ran" ]; do
    if [ -n "${prev_checks[$_ci]:-}" ] && [ -n "${now_checks[$_ci]:-}" ]; then
      _cmp=$((_cmp + 1))
    fi
    _ci=$((_ci + 1))
  done
  echo "run-all-tests: check counts compared against the last run for $_cmp of $ran suite(s)"
fi

slow_profile=""
unmeasured_names=""
notrun=0
notrun_names=""
divisions=""
idx=0
for suite in ${suites[@]+"${suites[@]}"}; do
    name="$(basename "$suite")"
    out="$(cat "$WORK/$idx.out" 2>/dev/null)"
    code="$(cat "$WORK/$idx.rc" 2>/dev/null)"
    # What this suite said about dividing its OWN work (claude-config#232). A passing suite's
    # output is printed nowhere, so a suite that went back to counting its sections instead of
    # using what it measured would simply be slower, on every run, with nothing anywhere saying so:
    # the silent regression this whole milestone existed to remove, one level up (L3, L98).
    while IFS= read -r _div_line; do
      [ -n "$_div_line" ] || continue
      divisions="$divisions
  $name: $_div_line"
    done <<DIVISIONS
$(printf '%s\n' "$out" | grep -E '^SUITE-DIVISION ' | sort -u || true)
DIVISIONS
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
      # Before giving up on it, try the CHECKOUT (claude-config#237). These suites audit the
      # repository and this is a deployed copy with no repository above it, but the checkout the
      # config came FROM is on this same Mac, so the gap the pull announced on every single run
      # was one it could close itself. Announced and never closed is what teaches a reader to skip
      # the line, and it meant a hook change could ship having been checked by 46 of 49 suites
      # with nobody noticing which three were missed (measured 2026-09-02).
      #
      # The checkout is NAMED by whoever runs this, never guessed: claude-sync passes its own
      # SYNC_REPO, which is the one directory that certainly holds the payload these hooks came
      # from. A guess would be the defect this repo keeps removing.
      rerun_from=""
      if [ -n "${RUN_ALL_TESTS_CHECKOUT:-}" ] && [ -f "${RUN_ALL_TESTS_CHECKOUT%/}/payload/hooks/$name" ]; then
        rerun_from="${RUN_ALL_TESTS_CHECKOUT%/}/payload/hooks"
      fi
      if [ -n "$rerun_from" ]; then
        rr_out="$(cd "$rerun_from" && RUN_ALL_TESTS_CHECKOUT="" bash "./$name" 2>&1)"; rr_rc=$?
        rr_nr="$(printf '%s\n' "$rr_out" | grep -E '^SUITE-NOT-RUN ' | tail -1)"
        if [ -n "$rr_nr" ]; then
          # It could not run THERE either. That is a different fact from having no checkout, and
          # it is reported as its own, because a re-run that changed nothing must not read like
          # one that was never attempted (L98, L11).
          notrun=$((notrun + 1))
          notrun_names="$notrun_names $name"
          printf '  NOT RUN %-37s %s\n' "$name" "$nr_reason (and not from $rerun_from either: ${rr_nr#SUITE-NOT-RUN })"
          continue
        fi
        if [ "$rr_rc" -eq 0 ]; then
          printf '  ok    %-38s %-26s %s\n' "$name" "passed from the checkout" "$dur"
          printf '          %s\n' "$(checkout_provenance "${RUN_ALL_TESTS_CHECKOUT%/}")"
          continue
        fi
        failed=$((failed + 1))
        failed_names="$failed_names $name"
        printf '  FAIL  %-38s %-26s %s\n' "$name" "failed from the checkout" "$dur"
        printf '          %s\n' "$(checkout_provenance "${RUN_ALL_TESTS_CHECKOUT%/}")"
        printf '%s\n' "$rr_out" | tail -25 | sed 's/^/          /'
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
    result="$(suite_result_line "$out")"
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
      # Was it a FLAKE? Run it once more and say so (claude-config#245).
      #
      # Three suites failed three separate full runs on 2026-08-31 on three different assertions and
      # passed cleanly every time they were run on their own. A suite that fails at random teaches
      # everyone to re-run rather than read, so a real regression there arrives looking exactly like
      # the noise, and nothing anywhere counted how often it happened.
      #
      # The re-run does NOT rescue the suite. It stays failed and the run stays red, because a retry
      # that turns a red suite green hides the price the flake is actually costing (L293). What the
      # second run buys is the word FLAKY beside it, which is the thing a reviewer needs and cannot
      # otherwise get without reproducing it by hand.
      #
      # Paid only on a suite that already failed, so a green run costs nothing extra.
      #
      # Run inside a subshell and behind a deadline, because the suite being re-run is by definition
      # one that just misbehaved. `test-vanish.sh` in this runner's own suite kills its PARENT: run
      # directly, that parent is this script, and the first version of this recheck killed the
      # runner mid report. The subshell puts a throwaway process in the way, and the deadline means
      # a suite that hangs on the second run costs a bounded wait rather than the whole run (L110).
      _flake=""
      if [ "$FLAKE_RECHECK" = "1" ]; then
        _fl_max="$FLAKE_RECHECK_MAX"
        case "$secs" in
          ''|*[!0-9]*) ;;
          *) [ "$(( secs * 3 ))" -gt "$_fl_max" ] && _fl_max="$(( secs * 3 ))" ;;
        esac
        # The trailing assignment and explicit exit are load bearing. Bash replaces the subshell
        # with the command when that command is the LAST thing in it, so the plain form left the
        # suite's PPID pointing at this script again and `kill -9 "$PPID"` went on killing the
        # runner. Something after it keeps a real process in between.
        ( HOOK_TESTS_FLAKE_RECHECK=0 bash "$suite" >/dev/null 2>&1; _fl_rc=$?; exit "$_fl_rc" ) &
        _fl_pid=$!
        _fl_waited=0
        while kill -0 "$_fl_pid" 2>/dev/null && [ "$_fl_waited" -lt "$_fl_max" ]; do
          sleep "$FLAKE_RECHECK_POLL"
          _fl_waited=$(( _fl_waited + 1 ))
        done
        if kill -0 "$_fl_pid" 2>/dev/null; then
          # It outlasted its deadline, so it is not a flake and it is not a clean failure either.
          # Said out loud rather than folded into the FAIL line, because a suite that hangs on the
          # second run is a different problem from one that fails on it (L11).
          runner_kill_tree "$_fl_pid" 2>/dev/null || true
          kill -9 "$_fl_pid" 2>/dev/null || true
          _flake=" (recheck timed out after ${_fl_max}s)"
        elif wait "$_fl_pid"; then
          _flake=" FLAKY"
          flaky=$((flaky + 1))
          flaky_names="$flaky_names $name"
        fi
      fi
      printf '  FAIL  %-38s %-26s %s%s\n' "$name" "$summary" "$dur" "$_flake"
      # And WHY. A one line verdict is enough on a machine where you can just run the suite
      # again; it is useless where you cannot, which is the whole point of running these
      # somewhere else (claude-config#101). The failing lines are printed, and the count is
      # said out loud when there are more than fit, so a truncated report cannot read as a
      # complete one.
      # EVERY line of the message, not only the line the word FAIL is on (claude-config#253).
      #
      # This used to be a grep for lines STARTING with FAIL, so a multi line message lost everything
      # after its first line. The suites that give the most useful detail are the ones that lost the
      # most of it: on the red run of b94b29a both messages ended mid sentence, on an open
      # parenthesis, and what was cut off was the files, the counts and the remedy. Diagnosing it
      # meant checking out the failing commit and running the suite by hand to read a message the
      # runner had already been handed (L148).
      #
      # A continuation is a line INDENTED further than the FAIL it follows. That is what the suites
      # here actually write, and it is what stops the rule swallowing the whole of a chatty suite's
      # output: a line back at the margin ends the message.
      detail="$(printf '%s\n' "$out" | awk '
        /^ *(FAIL|not ok)/ { match($0, /^ */); ind = RLENGTH; print; carry = 1; next }
        carry {
          if ($0 ~ /^[[:space:]]*$/) { carry = 0; next }
          match($0, /^ */)
          if (RLENGTH > ind) { print; next }
          carry = 0
        }
      ' || true)"
      [ -n "$detail" ] || detail="$(printf '%s\n' "$out" | tail -n "$FAIL_DETAIL_MAX")"
      shown="$(printf '%s\n' "$detail" | grep -c . || true)"
      printf '%s\n' "$detail" | awk -v n="$FAIL_DETAIL_MAX" 'NR <= n' | sed 's/^/          /'
      if [ "${shown:-0}" -gt "$FAIL_DETAIL_MAX" ]; then
        printf '          ...and %s more line(s) not shown\n' "$(( shown - FAIL_DETAIL_MAX ))"
      fi
    else
      printf '  ok    %-38s %-26s %s\n' "$name" "$summary" "$dur"
    fi
    # A LINE THE SUITE MARKED AS WORTH SEEING (claude-config#505). Everything a suite says is
    # dropped except its summary and, on a failure, its FAIL lines. That is right for chatter and
    # wrong for a MEASUREMENT: #492 put the sync suite's section time budget figure on that suite's
    # own headline, where nothing in CI ever prints it, so the budget could be totalling nothing on
    # every run and this log would read exactly the same. A guard nobody can watch pass is not
    # measuring anything as far as a reader can tell (L98, L557).
    #
    # Printed whether the suite passed or failed, because a measurement is most worth having on the
    # run that went wrong. Capped, because a suite that marked everything would flood the report
    # and the report is the thing this cap exists to keep readable (L36). The cap SAYS when it
    # bites, so a truncated set cannot read as the whole of it.
    notes="$(printf '%s\n' "$out" | grep -E '^SUITE-NOTE ' | sed 's/^SUITE-NOTE //' || true)"
    if [ -n "$notes" ]; then
      n_notes="$(printf '%s\n' "$notes" | grep -c . || true)"
      case "$n_notes" in ''|*[!0-9]*) n_notes=0 ;; esac
      printf '%s\n' "$notes" | awk -v n="$SUITE_NOTE_MAX" 'NR <= n' | sed 's/^/          note: /'
      if [ "$n_notes" -gt "$SUITE_NOTE_MAX" ]; then
        printf '          note: ...and %s more line(s) this suite marked, not shown\n' "$(( n_notes - SUITE_NOTE_MAX ))"
      fi
    fi
    # Fewer checks than last time, said where the verdict is read (claude-config#219). Under both
    # branches, because a suite can lose checks and go red in the same change and the drop is then
    # the more useful half of the two.
    #
    # Not a failure. Counts legitimately fall when tests are deleted, and a guard that goes red on
    # a deliberate deletion is one somebody learns to work around. What it cannot be is invisible:
    # a suite that finished early and honestly (a fixture glob matching nothing, a loop over an
    # empty list, a case table that lost a row) reports its smaller number as a clean pass, and
    # nothing else in this run is comparing it with anything (L288).
    #
    # BOTH numbers, on the line. "fewer checks" alone sends the reader to run the suite again to
    # find out how many fewer, which is the whole cost this is meant to save (L11, L80).
    _pc="${prev_checks[$((idx - 1))]:-}"
    _nc="${now_checks[$((idx - 1))]:-}"
    if [ -n "$_pc" ] && [ -n "$_nc" ] && [ "$_nc" -lt "$_pc" ]; then
      printf '          %s ran fewer checks than the last run: %s now, %s then. Deliberate, or did it finish early?\n' \
        "$name" "$_nc" "$_pc"
    fi
done

echo
# The slowest, named, which is what somebody reads when a run got slower (claude-config#150). Built
# from the suites this run actually FOUND and actually measured, so it can never name a suite that
# is no longer in the repo, and a suite nobody measured is named separately rather than sorted in
# at zero.
# Did the run LEAD with the suite that turned out to be slowest (claude-config#229)? The launch
# order decides which suite gets the largest share of the budget and is the only thing still
# running at the end, so getting it wrong costs the whole run. Nothing said so: a store holding a
# bad record still produces a confident "launch order from measured wall clock" line naming every
# suite it ran, and the only symptom is a run that took longer than it needed to.
#
# Said only when it is WRONG. A run that led correctly is the ordinary case and a line on every run
# is one nobody reads (L36).
if [ -n "$slow_profile" ] && [ -n "${launch_order:-}" ]; then
  _lead_first="$(printf '%s\n' "$launch_order" | awk -F"$(printf '\t')" 'NR == 1 { print $5 }')"
  _lead_first="${_lead_first##*/}"
  _lead_slowest="$(printf '%s' "$slow_profile" | sort -r | awk -F"$(printf '\t')" 'NR == 1 { print $2 }')"
  if [ -n "$_lead_first" ] && [ -n "$_lead_slowest" ] && [ "$_lead_first" != "$_lead_slowest" ]; then
    echo "run-all-tests: the suite launched first is not the one that took longest: it led with $_lead_first and $_lead_slowest took the longest."
    echo "  Lane 1 carries the largest share of the budget and is whatever launches first, so this run spent the machine on the wrong suite."
    echo "  The order comes from $TIMINGS. A record there that measured a refusal rather than a run is how this happens (#229)."
  fi
fi

# Echoed where the run's own verdict is read, and only when a suite said something. A line printed
# on every run whether or not anything divides its work is a line nobody reads (L36).
if [ -n "$divisions" ]; then
  echo "how each suite divided its own work:$divisions"
fi

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
# Did the run leave anything in the real spool? Compared on BOTH the file list
# and the total size, because a suite that appends to a file that already exists
# changes no name at all, and a listing alone would report that as clean (L63).
_spool_after="$(ls -1 "${_live_spool:-}" 2>/dev/null | sort)"
_spool_after_bytes="$(cat "${_live_spool:-}"/*.jsonl 2>/dev/null | wc -c | tr -d ' ')"
if [ "${_spool_before:-}" != "$_spool_after" ] || [ "${_spool_before_bytes:-}" != "$_spool_after_bytes" ]; then
  # Something wrote. WHO is a separate question, and asking it is the whole of #230: the old form
  # reported any change at all as a suite violating L2, and on a machine running several Claude
  # sessions that is a false red on a green run, priced at a full re-run (L293) and arriving
  # exactly when the machine is busy.
  #
  # Every record carries the working directory it came from, so the added lines are read and each
  # one is judged. A record naming a path inside THIS repo, or inside a throwaway directory, is a
  # suite's doing and is the defect this exists to catch: a suite that sources lib/issue-spool.sh
  # or runs a hook without setting CLAUDE_ISSUE_SPOOL_DIR first. A record naming another project's
  # checkout was written by somebody else's session and is not this run's business.
  _sp_mine=""; _sp_theirs=""; _sp_unknown=0
  for _sp_f in "${_live_spool:-}"/*.jsonl; do
    [ -e "$_sp_f" ] || continue
    _sp_was="$(printf '%s\n' "${_spool_sizes_before:-}" | awk -F"$(printf '\t')" -v f="$_sp_f" '$2 == f { print $1; exit }')"
    case "$_sp_was" in ''|*[!0-9]*) _sp_was=0 ;; esac
    _sp_now="$(wc -c < "$_sp_f" | tr -d ' ')"
    [ "$_sp_now" -gt "$_sp_was" ] || continue
    # Only the bytes this run added, so an existing record cannot be re-reported for ever.
    while IFS= read -r _sp_line; do
      [ -n "$_sp_line" ] || continue
      _sp_cwd="$(printf '%s' "$_sp_line" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      _sp_run="$(printf '%s' "$_sp_line" | sed -n 's/.*"suite_run"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      if [ -n "$_sp_run" ]; then
        # Stamped, so a suite wrote it (claude-config#275). ANY run's id counts, not only this
        # one's: a suite that launches a nested run replaces the id its own children carry, and a
        # record from the inner run is still a test writing into Dan's real spool.
        _sp_mine="$_sp_mine
    ${_sp_cwd:-(no directory recorded)} (written under this test run, id $_sp_run)"
      elif [ -z "$_sp_cwd" ]; then
        # No working directory to judge it by. Reported as unattributable and counted against the
        # run, because that is also the shape a writer nobody expected would take, and a change
        # this cannot explain must not read as a clean one (L98, L11).
        _sp_unknown=$(( _sp_unknown + 1 ))
      elif [ "$_sp_marker_works" -eq 0 ] && [ -n "$root" ] && [ "${_sp_cwd#"$root"}" != "$_sp_cwd" ]; then
        # Only reached when the stamp could not be proved, and announced above when that happens.
        # With the stamp working this branch is what produced the false red: a record naming this
        # repo is far more often another session's than a suite's.
        _sp_mine="$_sp_mine
    $_sp_cwd (attributed by directory, because the run id could not be proved)"
      elif [ "${_sp_cwd#"${TMPDIR:-/tmp}"}" != "$_sp_cwd" ] || [ "${_sp_cwd#/tmp}" != "$_sp_cwd" ]; then
        _sp_mine="$_sp_mine
    $_sp_cwd (a throwaway directory, so a suite wrote it)"
      else
        _sp_theirs="$_sp_theirs
    $_sp_cwd"
      fi
    done <<SPOOLADDED
$(tail -c "+$(( _sp_was + 1 ))" "$_sp_f" 2>/dev/null)
SPOOLADDED
  done
  if [ -n "$_sp_mine" ] || [ "$_sp_unknown" -gt 0 ]; then
    echo "SUITES WROTE INTO THE LIVE SPOOL at $_live_spool. A test must be structurally unable to"
    echo "  touch live data (L2). Bytes went from ${_spool_before_bytes:-?} to ${_spool_after_bytes:-?}."
    [ -n "$_sp_mine" ] && { echo "  Records written from inside this repo or a throwaway directory:"; printf '%s\n' "$_sp_mine"; }
    [ "$_sp_unknown" -gt 0 ] && echo "  And $_sp_unknown record(s) with no working directory recorded, which could not be attributed to anything."
    echo "  Find the suite that sources lib/issue-spool.sh, or runs a hook, without setting"
    echo "  CLAUDE_ISSUE_SPOOL_DIR to its own throwaway directory FIRST."
    # Counted as a failed suite, so the run's own verdict says so rather than
    # leaving the notice to be scrolled past.
    failed=$((failed + 1))
    failed_names="$failed_names live-spool-pollution"
  elif [ -n "$_sp_theirs" ]; then
    # Said, not silent. The spool changed and this run did not do it, which is worth knowing when
    # reading any timing this run reports, but it is not a fault in these tests.
    echo "The live spool at $_live_spool grew while this ran, from work in other directories:"
    printf '%s\n' "$_sp_theirs" | sort -u
    echo "  Another Claude session was working elsewhere on this machine. Not this run's doing, and not counted against it."
  fi
fi
# The other live stores, the same bracket (claude-config#216).
_live_after="$(_live_fingerprint 2>/dev/null || true)"
if [ -n "${_live_before:-}" ] && [ "$_live_before" != "$_live_after" ]; then
  # NAMED, not counted: which file changed is the whole of what a person needs, and a count sends
  # them to diff six paths by hand (L11, L80).
  #
  # Built first and printed after, because one of these stores has a legitimate writer that is not
  # a suite and the verdict depends on which changes are left once it is accounted for.
  _lc_blamed=""; _lc_noted=""
  # Asked ONCE, before the loop: it is a fact about the run rather than about any one store, and
  # asking per store would read the registry six times to get the same answer.
  _lc_applied="$(sync_applied_since "${_live_started:-}" || true)"
  while IFS= read -r _lc_line; do
    [ -n "$_lc_line" ] || continue
    _lc_path="${_lc_line%%	*}"
    _lc_was="$(printf '%s\n' "$_live_before" | awk -F"$(printf '\t')" -v f="$_lc_path" '$1 == f { print $2; exit }')"
    _lc_now="${_lc_line#*	}"
    [ "$_lc_was" = "$_lc_now" ] && continue
    if [ -n "$_lc_applied" ]; then
      _lc_noted="$_lc_noted  $_lc_path: was [$_lc_was], now [$_lc_now]
"
      continue
    fi
    if live_store_only_gained "$_lc_path"; then
      _lc_noted="$_lc_noted  $_lc_path: lines were added to it and none were removed or changed, which is what the sync and another session recording a lesson both do, and not what a suite bound to the real path does.
"
      continue
    fi
    if [ "$_lc_path" = "${SYNC_WATCH_PID_FILE:-$HOME/.claude-sync-watch.pid}" ] && watch_marker_is_not_ours "$_lc_path"; then
      _lc_noted="$_lc_noted  $_lc_path: rewritten by a watcher this run did not start, so it is the live daemon restarting rather than a suite.
"
      continue
    fi
    _lc_blamed="$_lc_blamed  $_lc_path: was [$_lc_was], now [$_lc_now]
"
  done <<LIVEAFTER
$_live_after
LIVEAFTER
  if [ -n "$_lc_blamed" ]; then
    echo "SUITES CHANGED A LIVE STORE. A test must be structurally unable to touch live data (L2)."
    printf '%s' "$_lc_blamed"
    echo "  Find the suite that sources a library, or runs a hook, without pointing CLAUDE_HOME (or"
    echo "  the relevant override) at its own throwaway directory FIRST."
    failed=$((failed + 1))
    failed_names="$failed_names live-store-pollution"
  fi
  [ -n "${_live_copies:-}" ] && rm -rf "$_live_copies" 2>/dev/null
  if [ -n "$_lc_noted" ]; then
    # Said, not silent, and not counted. The same shape as the spool line above: a store this run
    # did not write still changed while it ran, which is worth knowing when reading anything else
    # the run reports (L98).
    echo "A live store changed while this ran, and not because of these tests:"
    printf '%s' "$_lc_noted"
    [ -n "$_lc_applied" ] && echo "  The sync applied config into this Mac while these ran ($_lc_applied), and these stores are what an apply writes."
  fi
fi
if [ -n "$unmeasured_names" ]; then
  echo "NO DURATION was measured for:$unmeasured_names"
  echo "  They are missing from the timings above rather than counted as instant."
fi
if [ -n "$flaky_names" ]; then
  # Named and counted, where the verdict is read (claude-config#245, L293). A flake is a speed cost
  # priced at a full re-run, and the only way it stops being rediscovered every few weeks is for the
  # count to sit in front of whoever reads the run.
  echo "$flaky PASSED ON A SECOND RUN, so they are FLAKY rather than broken:$flaky_names"
  echo "  They are still counted as failures above. A suite that fails at random teaches everyone"
  echo "  to re-run rather than read, so a real regression there arrives looking like the noise."
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
