#!/usr/bin/env bash
# Holds three decisions in .github/workflows/tests.yml that the September 2026 CI review made
# (claude-config#598), each of which a later edit could quietly undo:
#
#   #594 a run on main is never cancelled by the next push. 207 of 602 runs on main that month were
#        cancelled, and those were exactly the runs that would have said which commit turned main red.
#
#   #597 every action is pinned to a full commit hash on a runtime GitHub still supports, so the code
#        that runs cannot change under the same tag and a deprecated runtime cannot fail every run at
#        once on the day it is switched off.
#
#   #597 the runner image is named, never ubuntu-latest, so the image moving underneath (to Ubuntu 26
#        on 2026-10-19) cannot turn main red with no commit to blame. Moving to a new image is then a
#        commit somebody makes and CI judges, rather than a date.
#
# Each rule is a function over a workflow FILE, and each is run against a fixture that breaks it
# before it is believed about the real file. A check never seen to fail could be passing because it
# reads nothing (L1, L159).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS="$DIR/../.github/workflows"
REAL="$WORKFLOWS/tests.yml"

pass=0; fail=0
check(){ if [[ "$2" == "ok" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

[ -f "$REAL" ] || { echo "test-ci-workflow: no workflow at $REAL, so nothing was checked." >&2; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.ciworkflow.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-ci-workflow: refusing to run: the throwaway directory came back as '$TMPROOT'." >&2
    exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# Comments are stripped before anything is read, so the prose explaining a rule can never be what
# satisfies it (L135).
code_of(){ sed 's/[[:space:]]#.*$//; s/^#.*$//' "$1"; }

# ---------------------------------------------------------------------------
# #594: main is never cancelled.
# ---------------------------------------------------------------------------
# Answers "ok" or why not. Cancelling is still wanted on pull request branches, where a newer push
# really does supersede the old one, so what is required is a condition that is false on main, not
# the removal of cancelling altogether.
main_not_cancelled(){ # main_not_cancelled <workflow>
  local v
  v="$(code_of "$1" | sed -n 's/^[[:space:]]*cancel-in-progress:[[:space:]]*//p')"
  case "$v" in
    '') echo ok ;;
    true) echo "cancel-in-progress is plain true, so every run on main is cancelled by the next push" ;;
    false) echo ok ;;
    *"github.ref != 'refs/heads/main'"*) echo ok ;;
    *) echo "cancel-in-progress is '$v', which does not visibly exclude main" ;;
  esac
}
printf 'concurrency:\n  group: tests-${{ github.ref }}\n  cancel-in-progress: true # superseded\n' > "$TMPROOT/cancels.yml"
r="$(main_not_cancelled "$TMPROOT/cancels.yml")"
[ "$r" != ok ] \
  && check "#594 a workflow that cancels every superseded run is refused" ok \
  || check "#594 a workflow that cancels every superseded run is refused" "it passed"
printf 'concurrency:\n  # cancel-in-progress: ${{ github.ref != '"'"'refs/heads/main'"'"' }}\n  cancel-in-progress: true\n' > "$TMPROOT/comment-only.yml"
r="$(main_not_cancelled "$TMPROOT/comment-only.yml")"
[ "$r" != ok ] \
  && check "#594 and a comment holding the right expression does not satisfy it" ok \
  || check "#594 and a comment holding the right expression does not satisfy it" "it passed"
r="$(main_not_cancelled "$REAL")"
[ "$r" = ok ] \
  && check "#594 the real workflow never cancels a run on main" ok \
  || check "#594 the real workflow never cancels a run on main" "$r"
# Still cancelling on pull requests, which is the half that saves minutes for nothing lost.
grep -qE "^[[:space:]]*cancel-in-progress:[[:space:]]*\\$\\{\\{ github.ref != 'refs/heads/main' \\}\\}" "$REAL" \
  && check "#594 and still cancels a superseded run on a pull request branch" ok \
  || check "#594 and still cancels a superseded run on a pull request branch" "cancel-in-progress is no longer the main excluding expression"

# Turning cancel-in-progress off is NOT enough on its own. A concurrency group holds at most one
# running and one PENDING run, and a newer run queuing into the group cancels the pending one
# whatever cancel-in-progress says. So with one group per branch, three commits landing on main
# together still lost the middle verdict. On main the group must be one per commit.
group_per_commit_on_main(){ # group_per_commit_on_main <workflow>
  local g
  g="$(code_of "$1" | sed -n 's/^[[:space:]]*group:[[:space:]]*//p')"
  case "$g" in
    '') echo "no concurrency group, so nothing is ever cancelled" ;;
    *"github.ref == 'refs/heads/main' && github.sha"*) echo ok ;;
    *) echo "the group is '$g', which is shared by every commit on main, so a pending run there is cancelled by the next one queuing" ;;
  esac
}
printf 'concurrency:\n  group: tests-${{ github.ref }}\n  cancel-in-progress: false\n' > "$TMPROOT/shared-group.yml"
r="$(group_per_commit_on_main "$TMPROOT/shared-group.yml")"
[ "$r" != ok ] \
  && check "#594 a group shared by every commit on main is refused, even with cancelling off" ok \
  || check "#594 a group shared by every commit on main is refused, even with cancelling off" "it passed"
printf 'jobs:\n  suite:\n    runs-on: ubuntu-26.04\n' > "$TMPROOT/no-group.yml"
r="$(group_per_commit_on_main "$TMPROOT/no-group.yml")"
[ "$r" != ok ] \
  && check "#594 a workflow with no concurrency group at all is refused too" ok \
  || check "#594 a workflow with no concurrency group at all is refused too" "it passed"
# Strict about the real file: a deleted group would also stop pull requests cancelling a superseded
# run, which is the half of #594 that saves minutes, so it is refused rather than waved through.
r="$(group_per_commit_on_main "$REAL")"
[ "$r" = ok ] \
  && check "#594 on main each commit has its own group, so no pending run is displaced" ok \
  || check "#594 on main each commit has its own group, so no pending run is displaced" "$r"

# ---------------------------------------------------------------------------
# #597: every action is pinned to a commit, on a supported runtime.
# ---------------------------------------------------------------------------
# The oldest major of each action that runs on Node 24 rather than the deprecated Node 20, read off
# each action's action.yml (`runs.using`) on 2026-10-05. An action not listed here is refused rather
# than waved through, so adding one means checking its runtime and writing it down (L96).
min_major_for(){
  case "$1" in
    actions/checkout) echo 5 ;;
    actions/cache|actions/cache/restore|actions/cache/save) echo 5 ;;
    # The parts hand what they measured to the suite job as artifacts (#2463); both moved to Node 24
    # at these majors (upload v6, download v7), read from each pinned commit's action.yml.
    actions/upload-artifact) echo 6 ;;
    actions/download-artifact) echo 7 ;;
    *) echo "" ;;
  esac
}
actions_pinned(){ # actions_pinned <workflow> -> ok, or one line per offending step
  local out="" line ref action sha ver major min n=0
  while IFS= read -r line; do
    n=$((n + 1))
    ref="$(printf '%s\n' "$line" | sed -n 's/^[[:space:]-]*uses:[[:space:]]*\([^[:space:]]*\).*/\1/p')"
    action="${ref%@*}"; sha="${ref#*@}"
    ver="$(printf '%s\n' "$line" | sed -n 's/.*#[[:space:]]*\(v[0-9][0-9.]*\).*/\1/p')"
    if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      out="$out$action is referenced as '$sha', not a full commit hash
"
      continue
    fi
    if [ -z "$ver" ]; then
      out="$out$action is pinned with no version comment, so nobody can tell what it is
"
      continue
    fi
    major="${ver#v}"; major="${major%%.*}"
    min="$(min_major_for "$action")"
    if [ -z "$min" ]; then
      out="$out$action has no recorded runtime here, so whether it runs on a supported Node is unknown
"
    elif [ "$major" -lt "$min" ]; then
      out="$out$action $ver runs on the deprecated Node 20; v$min or later is needed
"
    fi
  done <<EOF
$(grep -E '^[[:space:]-]*uses:' "$1")
EOF
  if [ "$n" -eq 0 ] || [ -z "$(grep -E '^[[:space:]-]*uses:' "$1")" ]; then
    echo "no uses: line was found, so nothing was checked"
  elif [ -z "$out" ]; then
    echo ok
  else
    printf '%s' "$out"
  fi
}
printf 'steps:\n  - uses: actions/checkout@v4\n' > "$TMPROOT/tag.yml"
r="$(actions_pinned "$TMPROOT/tag.yml")"
grep -q 'not a full commit hash' <<< "$r" \
  && check "#597 an action referenced by tag is refused" ok \
  || check "#597 an action referenced by tag is refused" "got: $r"
printf 'steps:\n  - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2\n' > "$TMPROOT/node20.yml"
r="$(actions_pinned "$TMPROOT/node20.yml")"
grep -q 'deprecated Node 20' <<< "$r" \
  && check "#597 a pinned action still on Node 20 is refused" ok \
  || check "#597 a pinned action still on Node 20 is refused" "got: $r"
printf 'steps:\n  - uses: someone/else@3d3c42e5aac5ba805825da76410c181273ba90b1 # v9.0.0\n' > "$TMPROOT/unknown.yml"
r="$(actions_pinned "$TMPROOT/unknown.yml")"
grep -q 'no recorded runtime' <<< "$r" \
  && check "#597 an action whose runtime nobody recorded is refused" ok \
  || check "#597 an action whose runtime nobody recorded is refused" "got: $r"
printf 'steps:\n  - run: true\n' > "$TMPROOT/none.yml"
r="$(actions_pinned "$TMPROOT/none.yml")"
[ "$r" != ok ] \
  && check "#597 a file with no action in it reports that nothing was checked" ok \
  || check "#597 a file with no action in it reports that nothing was checked" "it passed"
r="$(actions_pinned "$REAL")"
[ "$r" = ok ] \
  && check "#597 every action in the real workflow is pinned to a commit on a supported runtime" ok \
  || check "#597 every action in the real workflow is pinned to a commit on a supported runtime" "$r"

# ---------------------------------------------------------------------------
# #597: the runner image is named.
# ---------------------------------------------------------------------------
image_named(){ # image_named <workflow>
  local r
  # Every job's line, and one image across them (#2463): the jobs that run the suites are several
  # now, and run-on-linux.sh reproduces CI in ONE container, so two images would leave one unchecked.
  r="$(code_of "$1" | sed -n 's/^[[:space:]]*runs-on:[[:space:]]*//p' | sort -u)"
  if [ -z "$r" ]; then echo "no runs-on line was found"; return; fi
  if [ "$(printf '%s\n' "$r" | grep -c .)" -gt 1 ]; then echo "its jobs run on different images ($(printf '%s' "$r" | tr '\n' ' ')), and run-on-linux.sh reproduces one"; return; fi
  case "$r" in
    *-latest*) echo "runs on '$r', which GitHub moves to a new image on a date of its choosing" ;;
    ubuntu-[0-9][0-9].[0-9][0-9]) echo ok ;;
    *) echo "runs on '$r', which is not a named Ubuntu image" ;;
  esac
}
printf 'jobs:\n  suite:\n    runs-on: ubuntu-latest\n' > "$TMPROOT/latest.yml"
r="$(image_named "$TMPROOT/latest.yml")"
[ "$r" != ok ] \
  && check "#597 a job on ubuntu-latest is refused" ok \
  || check "#597 a job on ubuntu-latest is refused" "it passed"
printf 'jobs:\n  a:\n    runs-on: ubuntu-26.04\n  b:\n    runs-on: ubuntu-24.04\n' > "$TMPROOT/two-images.yml"
r="$(image_named "$TMPROOT/two-images.yml")"
[ "$r" != ok ] \
  && check "#2463 jobs on two different images are refused" ok \
  || check "#2463 jobs on two different images are refused" "it passed"
r="$(image_named "$REAL")"
[ "$r" = ok ] \
  && check "#597 the real workflow names its runner image" ok \
  || check "#597 the real workflow names its runner image" "$r"
# The container that reproduces CI on a Mac derives its image from this same line and refuses one it
# has no mapping for. Asked directly, so a move to a new image cannot leave it refusing unnoticed.
runner="$(code_of "$REAL" | sed -n 's/^[[:space:]]*runs-on:[[:space:]]*//p' | sort -u | awk 'NR == 1')"
grep -qE "^[[:space:]]*(.*\\|)?$runner(\\|.*)?\\)[[:space:]]+IMAGE=" "$DIR/run-on-linux.sh" \
  && check "#597 run-on-linux.sh has an image for '$runner'" ok \
  || check "#597 run-on-linux.sh has an image for '$runner'" "no case arm names it"

# ---------------------------------------------------------------------------
# #1901: the job's start is recorded first, and its limit is one the runner can read.
# ---------------------------------------------------------------------------
# run-all-tests.sh holds every flake recheck to end before the job is cancelled, reading the job's
# timeout-minutes through lib/workflow-job-timeout.sh and counting it from HOOK_TESTS_JOB_STARTED.
# Counted from the runner's own start instead, the minutes the steps before it took would be
# missing, which is the direction that lets the job be cancelled first. So the very first step
# records the start, before checkout or anything else that takes time.
#
# EVERY JOB THAT RUNS THE RUNNER is held to both, since #2463 split the suites across jobs: the
# runner reads the limit of whichever job it is in (GITHUB_JOB), so a check on one named job would
# go on passing while the job actually running the suites went unchecked (L220).
. "$DIR/../payload/hooks/lib/workflow-job-timeout.sh"
# shellcheck source=../payload/hooks/lib/whole-number.sh
. "$DIR/../payload/hooks/lib/whole-number.sh"
wf_job_block(){ # wf_job_block <workflow> <job> -> that job's lines, comments stripped
  code_of "$1" | awk -v j="$2" '$0 ~ "^  "j":[[:space:]]*$" { s = 1; next } s && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { s = 0 } s { print }'
}
start_recorded_first(){ # start_recorded_first <workflow> -> ok, or what is wrong with each runner job
  local job block first out="" n=0 _file _limit _m
  while IFS="$(printf '\t')" read -r _file job _limit; do
    [ -n "$job" ] || continue
    block="$(wf_job_block "$1" "$job")"
    case "$block" in *run-all-tests.sh*) ;; *) continue ;; esac
    n=$((n + 1))
    first="$(printf '%s\n' "$block" | awk '/^[[:space:]]*steps:[[:space:]]*$/ && !s { s = 1; next } s && /^[[:space:]]*- / { k++ } s && k == 1 { print }')"
    if ! [[ "$first" =~ HOOK_TESTS_JOB_STARTED=\$\(date\ \+%s\).*GITHUB_ENV ]]; then
      out="$out job $job: its first step does not write HOOK_TESTS_JOB_STARTED=\$(date +%s) to GITHUB_ENV;"
    fi
    _m="$(whole_above_zero "$(workflow_job_timeout_minutes "$1" "$job")")" \
      || out="$out job $job: no timeout-minutes the runner can read;"
  done <<JOBS
$(workflow_job_timeouts "$1")
JOBS
  if [ "$n" -eq 0 ]; then echo "no job runs run-all-tests.sh, so nothing was checked"; return; fi
  [ -z "$out" ] && echo ok || echo "${out# }"
}
# The second job is the one that runs the suites, so a check reading only the first is caught.
printf 'jobs:\n  deal:\n    runs-on: ubuntu-26.04\n    timeout-minutes: 5\n    steps:\n      - run: echo "HOOK_TESTS_JOB_STARTED=$(date +%%s)" >> "$GITHUB_ENV"\n  parts:\n    runs-on: ubuntu-26.04\n    timeout-minutes: 40\n    steps:\n      - uses: actions/checkout@abc\n      - run: echo "HOOK_TESTS_JOB_STARTED=$(date +%%s)" >> "$GITHUB_ENV"\n      - run: bash payload/hooks/run-all-tests.sh\n' > "$TMPROOT/start-late.yml"
r="$(start_recorded_first "$TMPROOT/start-late.yml")"
[ "$r" != ok ] \
  && check "#1901 a job running the suites that records its start after another step is refused, even when an earlier job is fine" ok \
  || check "#1901 a job running the suites that records its start after another step is refused, even when an earlier job is fine" "it passed"
printf 'jobs:\n  parts:\n    runs-on: ubuntu-26.04\n    timeout-minutes: ${{ inputs.m }}\n    steps:\n      - run: echo "HOOK_TESTS_JOB_STARTED=$(date +%%s)" >> "$GITHUB_ENV"\n      - run: bash payload/hooks/run-all-tests.sh\n' > "$TMPROOT/no-limit.yml"
r="$(start_recorded_first "$TMPROOT/no-limit.yml")"
[ "$r" != ok ] \
  && check "#1901 a job running the suites with no limit the runner can read is refused" ok \
  || check "#1901 a job running the suites with no limit the runner can read is refused" "it passed"
r="$(start_recorded_first "$REAL")"
[ "$r" = ok ] \
  && check "#1901 every job of the real workflow that runs the suites records its start first and has a readable limit" ok \
  || check "#1901 every job of the real workflow that runs the suites records its start first and has a readable limit" "$r"

# ---------------------------------------------------------------------------
# #2403: the environment step names the processor, not only how many cores there are.
# ---------------------------------------------------------------------------
# CI's runners come in two speeds, the slower about 27% slower on every suite (#1494, #2369), and
# the core count and image the step prints do not differ between the two (read from main's logs on
# 2026-11-07 for #2369), so the cores line cannot say which machine a run had. The processor model can, so the step prints it from /proc/cpuinfo (lscpu reads the same), and
# a run's log then names the hardware behind each group. Read from the step's code with comments
# stripped, so a comment naming the processor cannot satisfy it (L135).
env_step_code(){ # env_step_code <workflow>
  # Reads to the end rather than leaving at the next step, so the pipeline never ends early.
  code_of "$1" | awk '/name:[[:space:]]*Record the environment the suite is judged in/ && !done { s = 1; next } s && /^[[:space:]]*- (name|uses|run):/ { s = 0; done = 1 } s { print }'
}
processor_printed(){ # processor_printed <workflow>
  local step re='echo "processor: \$\(.*(/proc/cpuinfo|lscpu)'
  step="$(env_step_code "$1")"
  if [ -z "$step" ]; then echo "no environment step was found"; return; fi
  if [[ "$step" =~ $re ]]; then
    echo ok
  else
    echo "the environment step does not echo \"processor: \$(...)\" read from /proc/cpuinfo or lscpu"
  fi
}
printf 'jobs:\n  suite:\n    steps:\n      - name: Record the environment the suite is judged in\n        run: |\n          echo "cores: $(nproc)"\n          # echo "processor: $(lscpu)"\n      - name: Next\n        run: echo "processor: $(lscpu)"\n' > "$TMPROOT/no-processor.yml"
r="$(processor_printed "$TMPROOT/no-processor.yml")"
[ "$r" != ok ] \
  && check "#2403 an environment step printing cores but no processor is refused, whatever its comments or the next step say" ok \
  || check "#2403 an environment step printing cores but no processor is refused, whatever its comments or the next step say" "it passed"
r="$(processor_printed "$REAL")"
[ "$r" = ok ] \
  && check "#2403 the real environment step prints the processor model" ok \
  || check "#2403 the real environment step prints the processor model" "$r"

# ---------------------------------------------------------------------------
# #2463: the suites are dealt into parallel jobs by measured cost, and no suite is left out.
# ---------------------------------------------------------------------------
# One job ran every suite and took 30 to 40 minutes on main on 2026-11-09. The workflow now deals
# the suites into parts, one job per part, from what each suite last measured (L315), and the job
# named `suite` waits for all of them and holds the one verdict. Dealt from a list of suites, a
# suite left out of every part would run nowhere and read as a pass (L96, L98), so the runner both
# deals and refuses a deal that does not cover what it discovers, and both are driven here. The
# real tree's deal is held in tests/test-ci-parts-real-tree.sh, a suite of its own because reading
# what the repository tracks makes a suite one the push gate runs, and this one starts the runner on
# a fixture, which is a minute on a busy Mac (as #1997 did for the runner's own suite).
RUNNER="$DIR/../payload/hooks/run-all-tests.sh"

# A throwaway tree, so a deal and a part run can be driven to refuse without the real suites.
FX="$TMPROOT/deal-tree"
mkdir -p "$FX/t" "$FX/store"
# Each fails when it can see the part it was run in: those settings are the runner's alone, and a
# suite inheriting them would hand them to every runner it starts on a fixture of its own, which
# then refuses (the first CI run of the parts, test-fixture-runner-home.sh, 2026-11-09).
for s in a b c d; do
  printf '#!/usr/bin/env bash\nif [ -n "${HOOK_TESTS_PART:-}${HOOK_TESTS_PARTS:-}${HOOK_TESTS_DEALT:-}" ]; then echo "SUITE-RESULT passed=0 failed=1"; else echo "SUITE-RESULT passed=1 failed=0"; fi\n' > "$FX/t/test-$s.sh"
done
git -C "$FX" init -q && git -C "$FX" add t
# Measured cost, not count: a=100 b=60 c=50 d=10 into two parts puts a with d (110) and b with c
# (110). Dealt round robin in name order, as a count based split would, a goes with c and b with d.
printf '100\n' > "$FX/store/t%2Ftest-a.sh"; printf '60\n' > "$FX/store/t%2Ftest-b.sh"
printf '50\n' > "$FX/store/t%2Ftest-c.sh"; printf '10\n' > "$FX/store/t%2Ftest-d.sh"
deal2="$(HOOK_TESTS_ROOT="$FX" HOOK_TESTS_TIMINGS="$FX/store" HOOK_TESTS_DEAL=2 bash "$RUNNER" 2>/dev/null)"
p1="$(printf '%s\n' "$deal2" | awk -F'\t' '$1 == 1 { print $2 }' | sort | tr '\n' ' ')"
p2="$(printf '%s\n' "$deal2" | awk -F'\t' '$1 == 2 { print $2 }' | sort | tr '\n' ' ')"
[ "$p1" = "t/test-a.sh t/test-d.sh " ] && [ "$p2" = "t/test-b.sh t/test-c.sh " ] \
  && check "#2463 suites are dealt by their measured seconds, the longest first into the lightest part" ok \
  || check "#2463 suites are dealt by their measured seconds, the longest first into the lightest part" "part 1 '$p1', part 2 '$p2'"

part_run(){ # part_run <deal file> <part> <parts> -> the runner's output; its exit code in part_rc
  part_out="$(HOOK_TESTS_ROOT="$FX" HOOK_TESTS_TIMINGS= HOOK_TESTS_FLAKY_OUTPUT= HOOK_TESTS_SLOT=0 \
    HOOK_TESTS_DEALT="$1" HOOK_TESTS_PART="$2" HOOK_TESTS_PARTS="$3" bash "$RUNNER" 2>&1)"; part_rc=$?
}
printf '%s\n' "$deal2" > "$FX/deal.tsv"
part_run "$FX/deal.tsv" 2 2
{ [ "$part_rc" -eq 0 ] && grep -q 'test-b.sh' <<< "$part_out" && grep -q 'test-c.sh' <<< "$part_out" \
    && ! grep -qE 'ok +test-(a|d)\.sh' <<< "$part_out"; } \
  && check "#2463 a part runs exactly the suites dealt to it, and none of them sees which part it is in" ok \
  || check "#2463 a part runs exactly the suites dealt to it, and none of them sees which part it is in" "rc=$part_rc: $(tail -3 <<< "$part_out" | tr '\n' ' ')"

# THE GUARD THAT MATTERS MOST: a suite in no part. Added to the tree after the deal was made, it
# is in no line of it, and every part refuses rather than running without it.
printf '#!/usr/bin/env bash\necho "SUITE-RESULT passed=1 failed=0"\n' > "$FX/t/test-e.sh"
git -C "$FX" add t/test-e.sh
part_run "$FX/deal.tsv" 1 2
{ [ "$part_rc" -ne 0 ] && grep -q 'test-e.sh' <<< "$part_out" && ! grep -qE 'ok +test-a\.sh' <<< "$part_out"; } \
  && check "#2463 a suite dealt to no part makes every part refuse, naming it, and run nothing" ok \
  || check "#2463 a suite dealt to no part makes every part refuse, naming it, and run nothing" "rc=$part_rc: $(tail -2 <<< "$part_out" | tr '\n' ' ')"
git -C "$FX" rm -q --cached t/test-e.sh && rm -f "$FX/t/test-e.sh"

# A deal naming a suite the tree does not hold is from another commit, so it is refused too.
{ cat "$FX/deal.tsv"; printf '1\tt/test-gone.sh\t5\tmeasured\n'; } > "$FX/stale.tsv"
part_run "$FX/stale.tsv" 1 2
{ [ "$part_rc" -ne 0 ] && grep -q 'test-gone.sh' <<< "$part_out"; } \
  && check "#2463 a deal naming a suite the tree lacks is refused" ok \
  || check "#2463 a deal naming a suite the tree lacks is refused" "rc=$part_rc"
# A suite dealt to a part no job runs is as lost as one dealt to none.
awk -F'\t' -v OFS='\t' '$1 == 2 { $1 = 3 } { print }' "$FX/deal.tsv" > "$FX/high.tsv"
part_run "$FX/high.tsv" 1 2
{ [ "$part_rc" -ne 0 ] && grep -q 'part 3' <<< "$part_out"; } \
  && check "#2463 a deal into a part beyond the jobs that run is refused" ok \
  || check "#2463 a deal into a part beyond the jobs that run is refused" "rc=$part_rc: $(tail -2 <<< "$part_out" | tr '\n' ' ')"
# A part number that is not a whole number is refused, and the refusal names what it was given.
part_run "$FX/deal.tsv" 1x 2
{ [ "$part_rc" -ne 0 ] && grep -q "got part '1x' of '2'" <<< "$part_out"; } \
  && check "#2463 a part number that is not a whole number is refused, naming it" ok \
  || check "#2463 a part number that is not a whole number is refused, naming it" "rc=$part_rc: $(tail -2 <<< "$part_out" | tr '\n' ' ')"
part_run "$FX/absent.tsv" 1 2
[ "$part_rc" -ne 0 ] \
  && check "#2463 a deal file that is not there is refused" ok \
  || check "#2463 a deal file that is not there is refused" "it ran"
# A suite dealt to TWO parts would run twice, and its second run could pass where its first failed,
# so the count executed would exceed the count expected (L288). The duplicate goes into the other
# part, so a check reading only one part's lines could not see it.
{ cat "$FX/deal.tsv"; awk -F'\t' -v OFS='\t' '$1 == 1 { $1 = 2; print; exit }' "$FX/deal.tsv"; } > "$FX/twice.tsv"
dup="$(awk -F'\t' '$1 == 1 { print $2; exit }' "$FX/deal.tsv")"
part_run "$FX/twice.tsv" 2 2
{ [ -n "$dup" ] && [ "$part_rc" -ne 0 ] && grep -qF "$dup is dealt twice" <<< "$part_out" && ! grep -qE 'ok +test-[a-d]\.sh' <<< "$part_out"; } \
  && check "#2463 a suite dealt to two parts makes the part refuse, naming it, and run nothing" ok \
  || check "#2463 a suite dealt to two parts makes the part refuse, naming it, and run nothing" "rc=$part_rc, dup '$dup': $(tail -2 <<< "$part_out" | tr '\n' ' ')"

# The fan in's verdict, RUN rather than read: the body of the step that decides it is taken from the
# workflow as it stands and executed with each result a part job can end in, so a red part is
# proved to make a red `suite`, the one check every merge waits on (L305). A grep for its wording
# would pass a body that tested the wrong variable or never exited non zero. Both helpers read
# only the `suite` job, so a step of the same name in another job cannot stand in for it.
suite_job_raw(){ # suite_job_raw <workflow> -> the suite job's lines as written, comments kept
  awk '/^  suite:[[:space:]]*$/ { s = 1; next } s && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { s = 0 } s { print }' "$1"
}
# Each reads the job into a variable first: an awk that exits early at the end of a pipe would kill
# its producer, which pipefail reports as a failure that never happened.
fanin_verdict_body(){ # fanin_verdict_body <workflow> -> the run: body of the fan in's verdict step, unindented
  local job; job="$(suite_job_raw "$1")"
  awk '
    /^[[:space:]]*- name:[[:space:]]*The deal and every part passed[[:space:]]*$/ { s = 1; next }
    s && !inrun && /^[[:space:]]*- / { exit }
    s && !inrun && /^[[:space:]]*run:[[:space:]]*\|[[:space:]]*$/ { inrun = 1; match($0, /^[[:space:]]*/); ind = RLENGTH; next }
    inrun { match($0, /^[[:space:]]*/); if ($0 !~ /^[[:space:]]*$/ && RLENGTH <= ind) exit; print substr($0, ind + 3) }
  ' <<< "$job"
}
fanin_verdict_env(){ # fanin_verdict_env <workflow> -> the env: lines of that step, comments stripped
  local job; job="$(wf_job_block "$1" suite)"
  awk '
    /- name:[[:space:]]*The deal and every part passed[[:space:]]*$/ { s = 1; next }
    s && /^[[:space:]]*(- |run:)/ { exit }
    s { print }' <<< "$job"
}
fanin_rc(){ # fanin_rc <body> <deal result> <parts result> -> sets fanin_rc to the body's exit code
  DEAL="$2" PARTS="$3" bash -c "$1" > /dev/null 2>&1; fanin_rc=$?
}
verdict="$(fanin_verdict_body "$REAL")"
venv="$(fanin_verdict_env "$REAL")"
grep -qE 'DEAL:[[:space:]]*\$\{\{[[:space:]]*needs\.deal\.result[[:space:]]*\}\}' <<< "$venv" \
  && grep -qE 'PARTS:[[:space:]]*\$\{\{[[:space:]]*needs\.parts\.result[[:space:]]*\}\}' <<< "$venv" \
  && check "#2463 the fan in's verdict reads the deal's and the parts' own results" ok \
  || check "#2463 the fan in's verdict reads the deal's and the parts' own results" "env is: $(tr '\n' ' ' <<< "$venv")"
if [ -z "$verdict" ]; then
  check "#2463 the fan in's verdict step was found to run" "no run body under 'The deal and every part passed'"
else
  fanin_rc "$verdict" success success
  [ "$fanin_rc" -eq 0 ] \
    && check "#2463 the fan in is green when the deal and every part passed" ok \
    || check "#2463 the fan in is green when the deal and every part passed" "rc=$fanin_rc"
  bad=""
  for pr in failure cancelled skipped ""; do
    fanin_rc "$verdict" success "$pr"; [ "$fanin_rc" -ne 0 ] || bad="$bad parts '$pr' passed;"
  done
  for dr in failure cancelled; do
    fanin_rc "$verdict" "$dr" skipped; [ "$fanin_rc" -ne 0 ] || bad="$bad deal '$dr' passed;"
  done
  [ -z "$bad" ] \
    && check "#2463 a part that failed, was cancelled or never ran, or a failed deal, turns the fan in red" ok \
    || check "#2463 a part that failed, was cancelled or never ran, or a failed deal, turns the fan in red" "${bad# }"
fi

# The workflow: the parts' matrix comes from the deal job's own count, the part number reaches the
# runner, and the job named `suite`, the check every merge reads (block-red-merge.sh and
# merge-when-ready.sh read the whole rollup, so a new job name changes nothing they decide, L305),
# waits for every part and runs even when one failed, so a red part is a red `suite`.
fanin="$(wf_job_block "$REAL" suite)"; parts_job="$(wf_job_block "$REAL" parts)"; deal_job="$(wf_job_block "$REAL" deal)"
[ -n "$fanin" ] && [ -n "$parts_job" ] && [ -n "$deal_job" ] \
  && check "#2463 the workflow has the deal, parts and suite jobs" ok \
  || check "#2463 the workflow has the deal, parts and suite jobs" "missing one of them"
grep -qE 'needs:[[:space:]]*\[[[:space:]]*deal,[[:space:]]*parts[[:space:]]*\]' <<< "$fanin" && grep -qE 'if:[[:space:]]*\$\{\{[[:space:]]*always\(\)' <<< "$fanin" \
  && check "#2463 the suite job waits for the deal and every part, and runs whatever they did" ok \
  || check "#2463 the suite job waits for the deal and every part, and runs whatever they did" "needs or always() missing"
grep -qE 'fromJSON\(needs\.deal\.outputs\.parts\)' <<< "$parts_job" && grep -qE 'HOOK_TESTS_PART:[[:space:]]*\$\{\{[[:space:]]*matrix\.part' <<< "$parts_job" \
  && check "#2463 the parts matrix is the deal's own list, and each job runs its own part" ok \
  || check "#2463 the parts matrix is the deal's own list, and each job runs its own part" "not wired"
# A branch can be run by hand with no pull request open, which is how a change to this file is
# measured before review; read from the trigger block with comments stripped.
triggers="$(code_of "$REAL" | awk '/^on:[[:space:]]*$/ { s = 1; next } s && /^[^[:space:]]/ { s = 0 } s')"
grep -qE '^[[:space:]]+workflow_dispatch:' <<< "$triggers" \
  && check "#2463 the workflow can be started by hand on a branch" ok \
  || check "#2463 the workflow can be started by hand on a branch" "no workflow_dispatch trigger"
grep -qE 'HOOK_TESTS_DEAL:' <<< "$deal_job" \
  && check "#2463 the deal job deals with the runner itself" ok \
  || check "#2463 the deal job deals with the runner itself" "no HOOK_TESTS_DEAL in it"

# ---------------------------------------------------------------------------
# #2690: a pull request run whose exact tree already passed reuses that run instead of running again,
# and #2717: a push to main may stand on a pull request run of its exact tree (the deal passes the ref).
# ---------------------------------------------------------------------------
# Dan's choice, 2026-11-10: keep the merge gate as it is and make the repeat run cheap. The deal job
# asks tools/ci-reuse-green-tree.sh (tested on its own in tools/test-ci-reuse-green-tree.sh); on a
# reuse every job still reports under its own name (L305), each says in its log which run and commit
# it stood on, and the work is skipped step by step. A FULL green run records its tree for the next.
#
# One line per step of a job: its name (or what it uses), a tab, its if: condition.
steps_of(){ # steps_of <workflow> <job>
  local block; block="$(wf_job_block "$1" "$2")"
  awk '
    function out() { if (seen) printf "%s\t%s\n", label, cond }
    /^      - / { out(); seen = 1; label = ""; cond = ""; line = $0; sub(/^      - /, "        ", line); $0 = line }
    seen && /^        name:/ { l = $0; sub(/^        name:[[:space:]]*/, "", l); label = l }
    seen && /^        uses:/ && label == "" { l = $0; sub(/^        uses:[[:space:]]*/, "", l); label = l }
    seen && /^        if:/ { c = $0; sub(/^        if:[[:space:]]*/, "", c); cond = c }
    END { out() }' <<< "$block"
}
# Every step of the parts and suite jobs is skipped on a reuse, except the three that must run on
# both: the start recorder, the fan in's verdict, and the notice naming the reused run, which runs
# ONLY on a reuse. A step added later without the condition would run against a tree never checked
# out, or redo the work, so it is refused by name.
REUSED="needs.deal.outputs.reused-run"
reuse_gated(){ # reuse_gated <workflow> -> ok, or each step that is wrong
  local job label cond js out="" n=0
  for job in parts suite; do
    while IFS="$(printf '\t')" read -r label cond; do
      [ -n "$label$cond" ] || continue
      n=$((n + 1))
      case "$label" in
        "Record when the job started"|"The deal and every part passed")
          case "$cond" in *"$REUSED"*) out="$out $job/$label is conditional on the reuse, but must run on both;" ;; esac ;;
        "Reused a green run of this exact tree")
          case "$cond" in *"$REUSED != ''"*) ;; *) out="$out $job/$label does not run only on a reuse ($cond);" ;; esac ;;
        *)
          case "$cond" in *"$REUSED == ''"*) ;; *) out="$out $job/$label runs on a reuse too (if: '${cond}');" ;; esac ;;
      esac
    done <<STEPS
$(steps_of "$1" "$job")
STEPS
  done
  [ "$n" -gt 0 ] || { echo "no steps were read from the parts and suite jobs"; return; }
  for job in parts suite; do
    js="$(steps_of "$1" "$job")"
    grep -q "^Reused a green run of this exact tree	" <<< "$js" || out="$out $job has no step naming the reused run;"
  done
  [ -z "$out" ] && echo ok || echo "${out# }"
}
# Right in every way but one part step with no condition, so only that step may be named.
cat > "$TMPROOT/ungated.yml" <<'YML'
jobs:
  parts:
    steps:
      - name: Record when the job started
        run: true
      - name: Reused a green run of this exact tree
        if: needs.deal.outputs.reused-run != ''
        run: true
      - uses: actions/checkout@abc
        if: needs.deal.outputs.reused-run == ''
      - name: Install the pinned TypeScript compiler
        run: true
  suite:
    steps:
      - name: Record when the job started
        run: true
      - name: The deal and every part passed
        run: true
      - name: Reused a green run of this exact tree
        if: needs.deal.outputs.reused-run != ''
        run: true
YML
r="$(reuse_gated "$TMPROOT/ungated.yml")"
[ "$r" = "parts/Install the pinned TypeScript compiler runs on a reuse too (if: '');" ] \
  && check "#2690 a part step left running on a reuse is refused, by name, and only it" ok \
  || check "#2690 a part step left running on a reuse is refused, by name, and only it" "got: $r"
r="$(reuse_gated "$REAL")"
[ "$r" = ok ] \
  && check "#2690 on a reuse every part and suite step is skipped but the start, the verdict and the notice naming the run" ok \
  || check "#2690 on a reuse every part and suite step is skipped but the start, the verdict and the notice naming the run" "$r"

# The deal job asks the helper, with what it needs to judge, and may read the Actions API for it:
# the workflow's own token is contents: read only, so actions: read is granted to the deal job alone.
deal_raw="$(code_of "$REAL" | awk '/^  deal:[[:space:]]*$/ { s = 1; next } s && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { s = 0 } s { print }')"
miss=""
for want in 'bash tools/ci-reuse-green-tree\.sh' 'REUSE_EVENT:[[:space:]]*\$\{\{ github\.event_name \}\}' 'REUSE_REPO:[[:space:]]*\$\{\{ github\.repository \}\}' \
  'REUSE_REF:[[:space:]]*\$\{\{ github\.ref \}\}' \
  'REUSE_RUN_ID:[[:space:]]*\$\{\{ github\.run_id \}\}' 'GH_TOKEN:[[:space:]]*\$\{\{ github\.token \}\}' 'reused-run:[[:space:]]*\$\{\{ steps\.reuse\.outputs\.reused-run \}\}' \
  'tree:[[:space:]]*\$\{\{ steps\.reuse\.outputs\.tree \}\}' 'actions:[[:space:]]*read'; do
  grep -qE -- "$want" <<< "$deal_raw" || miss="$miss [$want]"
done
[ -z "$miss" ] \
  && check "#2690 the deal job asks the reuse helper with the event, repository, run and token, may read Actions, and passes the answer on" ok \
  || check "#2690 the deal job asks the reuse helper with the event, repository, run and token, may read Actions, and passes the answer on" "missing:$miss"
top_perms="$(code_of "$REAL" | awk '/^permissions:/ { s = 1; next } s && /^[^[:space:]]/ { s = 0 } s')"
grep -q 'actions:' <<< "$top_perms" \
  && check "#2690 and the workflow wide token is not widened" "the top level permissions grant actions" \
  || check "#2690 and the workflow wide token is not widened" ok

# The deal's decision step, RUN: a helper that answers reuse is passed on, and one that exits non
# zero after printing a reuse is discarded, so a crash in the helper can only ever be a full run.
deal_step_body(){ # deal_step_body <workflow> <step name> -> that step's run: body, unindented
  awk -v want="$2" '
    /^[[:space:]]*- name:/ { l = $0; sub(/^[[:space:]]*- name:[[:space:]]*/, "", l); s = (l == want); inrun = 0; next }
    s && !inrun && /^[[:space:]]*run:[[:space:]]*\|[[:space:]]*$/ { inrun = 1; match($0, /^[[:space:]]*/); ind = RLENGTH; next }
    s && inrun { match($0, /^[[:space:]]*/); if ($0 !~ /^[[:space:]]*$/ && RLENGTH <= ind) { s = 0; inrun = 0; next } print substr($0, ind + 3) }
  ' <<< "$deal_raw"
}
rbody="$(deal_step_body "$REAL" "A green run of this exact tree")"
if [ -z "$rbody" ]; then
  check "#2690 the deal's reuse step was found to run" "no run body under 'A green run of this exact tree'"
else
  RT="$TMPROOT/reuse-step"; mkdir -p "$RT/tools" "$RT/tmp"
  git -C "$RT" init -q && git -C "$RT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
  want_tree="$(git -C "$RT" rev-parse 'HEAD^{tree}')"
  reuse_step(){ # reuse_step <helper exit code> -> sets ro to what reached GITHUB_OUTPUT
    printf '#!/usr/bin/env bash\nprintf "reused-run=5\\nreused-sha=%%s\\nreused-url=u\\n" "$(printf a%%.0s $(seq 40))"\nexit %s\n' "$1" > "$RT/tools/ci-reuse-green-tree.sh"
    : > "$RT/out"
    (cd "$RT" && GITHUB_OUTPUT="$RT/out" RUNNER_TEMP="$RT/tmp" bash -e -o pipefail -c "$rbody" > /dev/null 2>&1)
    ro="$(cat "$RT/out")"
  }
  reuse_step 0
  grep -q '^reused-run=5$' <<< "$ro" && grep -q "^tree=$want_tree$" <<< "$ro" \
    && check "#2690 the deal's reuse step passes a reuse on, with the tree it tested" ok \
    || check "#2690 the deal's reuse step passes a reuse on, with the tree it tested" "output: $(tr '\n' ' ' <<< "$ro")"
  reuse_step 1
  ! grep -q '^reused-run=' <<< "$ro" && grep -q "^tree=$want_tree$" <<< "$ro" \
    && check "#2690 a reuse helper that fails is a full run, whatever it printed" ok \
    || check "#2690 a reuse helper that fails is a full run, whatever it printed" "output: $(tr '\n' ' ' <<< "$ro")"
fi

# A FULL green run records the tree it proved, last in the fan in so only a run whose every step
# passed can upload it, and never from a run that itself reused (no chains of reuse).
suite_steps="$(steps_of "$REAL" suite)"
last="$(tail -1 <<< "$suite_steps")"
suite_code="$(wf_job_block "$REAL" suite)"
case "$last" in
  "Record that this tree passed	"*"$REUSED == ''"*)
    grep -qE 'name:[[:space:]]*green-tree-\$\{\{ needs\.deal\.outputs\.tree \}\}' <<< "$suite_code" \
      && check "#2690 the fan in's last step records the tree, only on a full run, under the name the helper looks for" ok \
      || check "#2690 the fan in's last step records the tree, only on a full run, under the name the helper looks for" "no green-tree-<tree> artifact name" ;;
  *) check "#2690 the fan in's last step records the tree, only on a full run, under the name the helper looks for" "last step is: $last" ;;
esac
grep -q 'green-tree-' "$DIR/../tools/ci-reuse-green-tree.sh" \
  && check "#2690 the helper looks for the same green-tree- name" ok \
  || check "#2690 the helper looks for the same green-tree- name" "the name differs"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
