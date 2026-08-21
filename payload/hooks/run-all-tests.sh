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
# the fourth was named by nothing at all: 233 checks that had never run anywhere.
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
# repo, which is 37 suites and about five minutes, dominated by one that takes three of them. Five
# minutes is how a full run stops being run at all, which is the exact failure #120 exists to
# close, so the answer is to make the full run fast rather than to make a partial run the default.
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
# CI runner has two cores, half of two is one, and 38 suites would have run strictly one after
# another while two slots sat reserved for whichever of them could use them. Capped by the budget,
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
  # to walk.
  root="${HOOK_TESTS_ROOT:-}"
  [ -n "$root" ] || root="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
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
  # running at the end, so for most of a run there was idle budget nothing could use: 124 seconds
  # against 88 the oversubscribed way it replaced.
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
  trap 'rm -rf "$WORK"' EXIT

  # Launched LONGEST FIRST, judged by file size. It is a heuristic and says so: bytes are not
  # seconds. What it buys is that the one suite taking three of the five minutes starts
  # immediately instead of possibly last, and being wrong about the order costs some wall clock
  # and nothing else, because every result is collected and reported the same way regardless.
  launch_order="$(
    i=0
    for suite in "${suites[@]}"; do
      printf '%s	%s	%s
' "$(wc -c < "$suite" | tr -d ' ')" "$i" "$suite"
      i=$((i + 1))
    done | sort -rn -k1,1
  )"

  lane_pid=()
  _l=1
  while [ "$_l" -le "$at_once" ]; do lane_pid[$_l]=""; _l=$(( _l + 1 )); done
  while IFS="$(printf '\t')" read -r _size idx suite; do
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
    ( HOOK_TESTS_SLOTS="${LANES[$lane]}" bash "$suite" > "$WORK/$idx.out" 2>&1; printf '%s' "$?" > "$WORK/$idx.rc" ) &
    lane_pid[$lane]=$!
  done <<LAUNCH
$launch_order
LAUNCH
  wait
fi

# Reported in the order they were FOUND. Two runs of the same tree then produce the same page, so a
# difference between them is a difference in the suites rather than in the machine's mood.
idx=0
for suite in ${suites[@]+"${suites[@]}"}; do
    name="$(basename "$suite")"
    out="$(cat "$WORK/$idx.out" 2>/dev/null)"
    code="$(cat "$WORK/$idx.rc" 2>/dev/null)"
    case "$code" in ''|*[!0-9]*) code=1; out="$out
run-all-tests: this suite left no exit status, so it was killed or never started." ;; esac
    idx=$((idx + 1))
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
      printf '  FAIL  %-38s %s\n' "$name" "$summary"
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
      printf '  ok    %-38s %s\n' "$name" "$summary"
    fi
done

echo
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
if [ "$failed" -eq 0 ] && [ -z "$empty_dirs" ]; then
  echo "ALL $ran SUITES PASSED"
  exit 0
fi
[ "$failed" -eq 0 ] || echo "$failed of $ran SUITES FAILED:$failed_names"
exit 1
