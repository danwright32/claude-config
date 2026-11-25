#!/usr/bin/env bash
# Tests for lib/merge-when-ready.sh, sections 31 to 33 of what was one suite, test-merge-when-ready.sh:
# a run that waited for a runner, a pull request stacked on a branch that has not merged, and
# what the checks did not test, named and then run here before the merge.
#
# test-merge-when-ready.sh ran past run-all-tests.sh's 1,200 second wall limit on GitHub's runners
# on 2026-11-24 (exit 124), which stopped the config sync between the two Macs: one piece held
# against a fixed deadline had grown to most of it (L315). Its sections are now six suites, each
# dealt to a part by its own measured cost (claude-config#3572): test-merge-when-ready.sh (its
# documentation checks and sections 1 to 10), -heads (11 to 21), -turn (22 to 26b), -line (27 to
# 30), -untested (31 to 33) and -bypass (the bypass merge and sleep mode). Every check is as it was,
# and each section keeps its number, so "section N" in a comment names the section of that number
# in whichever of the six holds it.
#
# The world they run in (the fake gh, the injected clock and sleep, the stub gates and review
# checker, the checkout, the counters and the result line) is lib/merge-when-ready-harness.sh, the
# one place every one of them takes it from. Nothing reaches the network or a real pull request (L2).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/merge-when-ready-harness.sh" || {
  echo "FAIL: $(basename "$0"): lib/merge-when-ready-harness.sh is missing, so there is no world to run the helper in. Refusing to run."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
mwr_harness_build
# Section 33 runs the real run-all-tests.sh on fixtures, each run in a config folder of its own.
. "$DIR/lib/fixture-runner-home.sh"

# =================================================================================================
# 31. A run that waited for a runner says so (claude-config#2714). On 2026-11-10 the account's 20
#     concurrent jobs were all in use at about 01:15 and 13:40 ET, and 15 jobs waited over a minute to
#     start, up to 6.6 minutes, which read in the merge logs as slow tests. The answers below are
#     GitHub's own, recorded that day and kept to the fields read: run 42877567710's job deal was
#     created at 18:40:26 UTC and started at 18:47:00, 6m 34s later, while the five runs created in
#     the half minute before it held 20 jobs between them; jobs-42877448181.json is one of those five,
#     every job of which started within 2 seconds of being created.
# =================================================================================================
PW_FIX="$DIR/merge-when-ready-fixtures/pool-wait-2026-11-10"
PW_RUN=42877567710
pw_rollup(){ # pw_rollup <run id> <status> <conclusion>: the run's one check, as the rollup shows it
  jq -nc --arg id "$1" --arg s "$2" --arg c "$3" \
    '[{__typename:"CheckRun",name:"deal",workflowName:"tests",status:$s,conclusion:$c,startedAt:null,detailsUrl:("https://github.com/acme/widget/actions/runs/" + $id + "/job/130044844243")}]'
}
pw_fresh(){ # pw_fresh <run id>: that run's check queued at the first look, finished at the next
  local f
  fresh "$OLD" 0 "$(pw_rollup "$1" QUEUED "")"
  for f in "$PW_FIX"/jobs-*.json; do cp "$f" "$ST/jobsjson-$(basename "$f" .json | sed 's/^jobs-//')"; done
  cp "$PW_FIX/runs.json" "$ST/pool-runs"
  printf '%s\n' "printf '%s' '$(pw_rollup "$1" COMPLETED SUCCESS)' > \"\$ST/rollup\"" > "$ST/on-sleep"
}

pw_fresh "$PW_RUN"
out="$(run 7 --squash)"; rc=$?
check_eq "#2714 a run whose job waited for a runner still merges" "0" "$rc"
check "#2714 it names the job and how long it waited" "job deal waited 6m 34s" "$out"
check "#2714 and how many of the repository's jobs were running when it was queued" "20 of this repository's jobs were running" "$out"
check "#2714 and that the runner pool was full" "the runner pool was full" "$out"
check "#2714 the jobs running are counted from runs created up to two hours before it" "actions/runs?created=2026-11-10T16:40:26Z..2026-11-10T18:40:26Z" "$(cat "$ST/gh-calls")"
check_eq "#2714 the waited run's own jobs are read once" "1" "$(count gh-calls "runs/$PW_RUN/jobs")"
check_eq "#2714 each overlapping run's jobs are read once" "6" "$(count gh-calls '/jobs')"
check_not "#2714 the job that started at once is not said" "job suites part 2 waited" "$out"

# Under the limit: the same wait, with a plan that allows 40, is not called a full pool.
pw_fresh "$PW_RUN"
out="$(MWR_POOL_LIMIT=40 run 7 --squash)"; rc=$?
check_eq "#2714 under the limit it merges" "0" "$rc"
check "#2714 under the limit it still says the wait" "job deal waited 6m 34s" "$out"
check "#2714 and says the count was under the limit" "under the 40" "$out"
check_not "#2714 and never that the pool was full" "the runner pool was full" "$out"

# Two runs waited on for one head, the first under the limit: each is judged on its own count, so
# the second, the run recorded on 2026-11-10 with 20 running, is still called a full pool. Run 1001
# is made up for this, not recorded: one job
# that waited 2 minutes at a time no recorded run overlaps, so it counts 0 running.
pw_fresh "$PW_RUN"
jq -nc '[{__typename:"CheckRun",name:"lint",workflowName:"lint",status:"QUEUED",conclusion:"",startedAt:null,detailsUrl:"https://github.com/acme/widget/actions/runs/1001/job/1"},{__typename:"CheckRun",name:"deal",workflowName:"tests",status:"QUEUED",conclusion:"",startedAt:null,detailsUrl:"https://github.com/acme/widget/actions/runs/42877567710/job/130044844243"}]' > "$ST/rollup"
printf '%s\n' '{"total_count":1,"jobs":[{"id":1,"run_id":1001,"name":"lint","status":"completed","conclusion":"success","created_at":"2026-11-10T20:00:00Z","started_at":"2026-11-10T20:02:00Z","completed_at":"2026-11-10T20:03:00Z"}]}' > "$ST/jobsjson-1001"
out="$(run 7 --squash)"; rc=$?
check_eq "#2714 two waited runs merge" "0" "$rc"
check "#2714 the first run is said under the limit" "job lint waited 2m 00s, and 0 of this repository's jobs" "$out"
check "#2714 the second run is still called a full pool" "job deal waited 6m 34s, and 20 of this repository's jobs were running when it was queued. GitHub runs at most 20 jobs at once" "$out"

# A third party status open beside it, whose link is no Actions run: still counted as open, so the
# head waits for it, and the run beside it is still found and said.
pw_fresh "$PW_RUN"
jq -c '. + [{__typename:"StatusContext",context:"deploy/preview",state:"PENDING",targetUrl:"https://example.com/preview"}]' "$ST/rollup" > "$ST/rollup.tmp"; mv "$ST/rollup.tmp" "$ST/rollup"
out="$(run 7 --squash)"; rc=$?
check_eq "#2714 with a third party status beside it, it merges" "0" "$rc"
check "#2714 the status was waited on as an open check" "checks still running (2 of 2)" "$out"
check "#2714 and the run's wait is still said" "job deal waited 6m 34s" "$out"

# A clean run says nothing, and reads nothing past its own jobs.
pw_fresh 42877448181
out="$(run 7 --squash)"; rc=$?
check_eq "#2714 a run with no wait merges" "0" "$rc"
check_not "#2714 and says nothing about a runner" "waited" "$out"
check_eq "#2714 its own jobs were read once" "1" "$(count gh-calls '/jobs')"
check_eq "#2714 and no window of runs was read" "0" "$(count gh-calls 'runs?created=')"

# A run that had finished before the helper looked was never waited on here, so nothing is read.
fresh "$OLD" 0 "$(pw_rollup "$PW_RUN" COMPLETED SUCCESS)"
cp "$PW_FIX/jobs-$PW_RUN.json" "$ST/jobsjson-$PW_RUN"
out="$(run 7 --squash)"; rc=$?
check_eq "#2714 a run finished before the first look merges" "0" "$rc"
check_eq "#2714 with no jobs read" "0" "$(count gh-calls '/jobs')"
check_not "#2714 and nothing said" "waited" "$out"

# The count unreadable: the wait is still said, with why the count is missing, and it merges.
pw_fresh "$PW_RUN"
printf '%s\n' 'gh: Server Error (HTTP 502)' > "$ST/pool-runs-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#2714 an unreadable count still merges" "0" "$rc"
check "#2714 the wait is still said" "job deal waited 6m 34s" "$out"
check "#2714 with why the count is missing" "could not count the jobs running" "$out"
check "#2714 naming GitHub's answer" "HTTP 502" "$out"

# The run's own jobs unreadable: said once, and it merges as before.
pw_fresh "$PW_RUN"
printf '%s\n' 'gh: Server Error (HTTP 502)' > "$ST/jobs-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#2714 unreadable jobs still merge" "0" "$rc"
check "#2714 saying whether a job waited is unknown" "Could not read the jobs of workflow run $PW_RUN" "$out"

# =================================================================================================
# 32. A pull request stacked on a branch that has not merged waits for it (claude-config#3118). On
# 2026-11-16 six queued pull requests based on other feature branches reached their turn before
# their bases had merged and would each have been squash merged into its base branch, not main: the
# change would then ride into main inside the base's squash, and its Closes lines never fire, since
# GitHub closes issues only from the default branch. They were stopped by hand. Now a run whose base
# is not the repository's default branch (as GitHub names it, never assumed to be main) waits for its
# base pull request to merge, taking no place in line meanwhile, and goes on once it has been moved
# onto the default branch; a base nothing will merge stops it, naming the base pull request.
# =================================================================================================
# What a step run by the injected sleep records: how many tickets the line holds while this waits.
TICKETS='find "$MWR_TURN_DIR" -type f -name "[0-9]*" ! -name "*.*" 2>/dev/null | wc -l | tr -d " " >> "$ST/tickets-at-sleep"'
stacked_fresh(){ # stacked_fresh <behind> <base pull request answer>
  fresh "$OLD" "$1" "$GREEN"
  printf 'feat/base' > "$ST/base-ref"
  printf '%s\n' "$2" > "$ST/base-prs"
}
OPEN6='[{"number":6,"state":"OPEN"}]'

# Its base merges while it waits, and the pull request is moved onto main: it then merges, into main.
stacked_fresh 0 "$OPEN6"
printf '%s\n%s\n' "$TICKETS" "$TICKETS; printf main > \"\$ST/base-ref\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#3118 a stacked pull request merges once it is moved onto main" "0" "$rc"
check_eq "#3118 into main, never into the branch it was stacked on" "main" "$(cat "$ST/merged-into" 2>/dev/null)"
check "#3118 it says what it waits for, naming the base pull request and its branch" "Waiting for #6 (feat/base) to merge" "$out"
check "#3118 and why it does not merge now" "based on feat/base, not main" "$out"
check_eq "#3118 and takes no place in line to merge while it waits" "0 0" "$(paste -sd ' ' - < "$ST/tickets-at-sleep" 2>/dev/null)"
check "#3118 it says when it goes on" "#7 is now based on main" "$out"
check "#3118 and then takes the turn as any run does" "Took the turn to merge in acme/widget" "$out"

# Its base never merges: it waits through the injected sleep until its budget ends, exit 3, and
# never updates, reviews, takes a turn or merges meanwhile, though it is behind.
stacked_fresh 3 "$OPEN6"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do printf '%s\n' "$TICKETS"; done > "$ST/on-sleep"
out="$(MWR_LINE_SECONDS=300 run 7 --squash)"; rc=$?
check_eq "#3118 a base that never merges ends in out of time, to be run again" "3" "$rc"
check "#3118 saying what it was still waiting for" "is based on feat/base, waiting for #6 to merge into main" "$out"
check_eq "#3118 nothing merged" "0" "$(count gh-calls 'pr merge')"
check_eq "#3118 the branch is never updated with a base it will not merge into" "0" "$(count gh-calls 'pr update-branch')"
check_eq "#3118 no lessons review is started" "0" "$(count review-calls '^start')"
check_eq "#3118 no place in line was taken at any look" "0" "$(sort -u "$ST/tickets-at-sleep" 2>/dev/null | paste -sd ' ' -)"
check_eq "#3118 every wait went through the injected sleep" "30" "$(sort -u "$ST/sleeps" 2>/dev/null | paste -sd ' ' -)"

# A base pull request closed without merging: nothing will move it onto main, so it stops at once.
stacked_fresh 0 '[{"number":6,"state":"CLOSED"}]'
out="$(run 7 --squash)"; rc=$?
check_eq "#3118 a base closed without merging stops it for a person" "1" "$rc"
check "#3118 naming the base pull request and how it ended" "#6, the pull request for feat/base, was closed without merging" "$out"
check "#3118 and how to go on" "gh pr edit 7 --repo acme/widget --base main" "$out"
check_eq "#3118 nothing merged" "0" "$(count gh-calls 'pr merge')"
check_eq "#3118 with no wait first" "0" "$(count sleeps .)"

# No pull request for the base branch at all: the same.
stacked_fresh 0 '[]'
out="$(run 7 --squash)"; rc=$?
check_eq "#3118 a base branch no pull request merges stops it" "1" "$rc"
check "#3118 saying so" "no pull request merges feat/base" "$out"
check_eq "#3118 nothing merged" "0" "$(count gh-calls 'pr merge')"

# The base pull request has merged and this one is still on its branch: GitHub, or the run that
# merged it, moves it in moments, so that is waited for, and past the lag it stops.
stacked_fresh 0 '[{"number":6,"state":"MERGED"},{"number":5,"state":"CLOSED"}]'
out="$(MWR_HEAD_LAG_SECONDS=60 run 7 --squash)"; rc=$?
check_eq "#3118 a merged base it was never moved off stops it" "1" "$rc"
check "#3118 saying the base merged and it is still on its branch" "still based on feat/base 1m after #6, the pull request for feat/base, merged" "$out"
check_eq "#3118 having waited the lag first" "2" "$(count sleeps .)"
check_eq "#3118 nothing merged" "0" "$(count gh-calls 'pr merge')"
stacked_fresh 0 '[{"number":6,"state":"MERGED"}]'
printf '%s\n' "printf main > \"\$ST/base-ref\"" > "$ST/on-sleep"
out="$(MWR_HEAD_LAG_SECONDS=60 run 7 --squash)"; rc=$?
check_eq "#3118 moved onto main within the lag, it merges" "0" "$rc"
check_eq "#3118 into main" "main" "$(cat "$ST/merged-into" 2>/dev/null)"

# An open base pull request is the one waited for, wherever GitHub lists it.
stacked_fresh 0 '[{"number":5,"state":"CLOSED"},{"number":6,"state":"OPEN"}]'
printf '%s\n' "printf main > \"\$ST/base-ref\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check "#3118 an open base pull request is named over a closed one" "Waiting for #6 (feat/base) to merge" "$out"

# The base pull request cannot be read: a stop that says so, never a merge.
stacked_fresh 0 "$OPEN6"
printf '%s\n' 'gh: Server Error (HTTP 502)' > "$ST/base-prs-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#3118 an unreadable base pull request stops it" "1" "$rc"
check "#3118 saying what could not be read" "could not read the pull request for #7's base branch feat/base" "$out"
check_eq "#3118 nothing merged" "0" "$(count gh-calls 'pr merge')"

# The default branch is GitHub's, never assumed: based on trunk where trunk is the default, it merges
# as any run does; based on main where trunk is the default, main is the branch it is stacked on.
fresh "$OLD" 0 "$GREEN"
printf 'trunk' > "$ST/default-branch"; printf 'trunk' > "$ST/base-ref"
out="$(run 7 --squash)"; rc=$?
check_eq "#3118 based on a default branch not named main, it merges" "0" "$rc"
check_eq "#3118 into that branch" "trunk" "$(cat "$ST/merged-into" 2>/dev/null)"
check_eq "#3118 with no look for a base pull request" "0" "$(count gh-calls 'pr list --repo acme/widget --head')"
fresh "$OLD" 0 "$GREEN"
printf 'trunk' > "$ST/default-branch"
out="$(run 7 --squash)"; rc=$?
check_eq "#3118 based on main where trunk is the default, it is stacked" "1" "$rc"
check "#3118 and says so against trunk" "based on main, not trunk" "$out"
check_eq "#3118 nothing merged" "0" "$(count gh-calls 'pr merge')"

# GitHub names no default branch: whether the base is it cannot be told, so nothing is merged.
fresh "$OLD" 0 "$GREEN"
: > "$ST/default-branch-unnamed"
out="$(run 7 --squash)"; rc=$?
check_eq "#3118 an unnamed default branch stops it" "1" "$rc"
check "#3118 saying so" "GitHub did not name the default branch of acme/widget" "$out"
check_eq "#3118 nothing merged" "0" "$(count gh-calls 'pr merge')"

# A pull request based on the default branch behaves exactly as before: no base pull request is
# looked for, and nothing is said about a base.
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --squash)"; rc=$?
check_eq "#3118 based on main, it merges as before" "0" "$rc"
check_eq "#3118 with no look for a base pull request" "0" "$(count gh-calls 'pr list --repo acme/widget --head')"
check_not "#3118 and nothing said about a base" "based on" "$out"

# =================================================================================================
# 32. What the checks did not test is named before the merge (claude-config#3312). claude-config's
#     tests workflow puts a notice on its fan in naming every part a suite could not run on the
#     runner; read back here by its title from each check's annotations, so the log of a merge says
#     what its green did not cover. The report itself never stops a merge. Running the suites it
#     names is section 33's, so these cases skip that step with its switch, which is what leaves
#     the report on its own.
# =================================================================================================
export MWR_UNTESTED_SKIP="section 32 reads the report alone"
UT_ROLLUP='[{"__typename":"CheckRun","name":"suite","workflowName":"tests","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-20T10:00:00Z","detailsUrl":"https://github.com/acme/widget/actions/runs/900/job/501"},{"__typename":"CheckRun","name":"deal","workflowName":"tests","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-20T10:00:00Z","detailsUrl":"https://github.com/acme/widget/actions/runs/900/job/502"}]'
ut_fresh(){
  fresh "$OLD" 0 "$UT_ROLLUP"
  jq -nc '[{path:".github",annotation_level:"notice",title:"Not tested by the checks",message:"3 parts in 2 suites were not tested on the runner, so these checks do not cover them:\ntest-a.sh: no claude here\ntest-a.sh: no Chrome here\ntest-b.sh: not macOS"},{path:".github",annotation_level:"notice",title:"Not tested by the checks and more than on main",message:"This run left more untested than main'"'"'s last run: test-b.sh 1 part, none on main."}]' > "$ST/annotations-501"
  jq -nc '[{path:".github",annotation_level:"warning",title:"Node.js 20 actions are deprecated",message:"something else entirely"}]' > "$ST/annotations-502"
}
ut_fresh
out="$(run 7 --squash)"; rc=$?
check_eq "#3312 a head whose checks left parts untested still merges" "0" "$rc"
check "#3312 it names the check and what it said it did not test" "Check suite, Not tested by the checks: 3 parts in 2 suites were not tested on the runner" "$out"
check "#3312 with each part on its own line" "test-a.sh: no Chrome here" "$out"
check "#3312 and that it is more than main" "Check suite, Not tested by the checks and more than on main: This run left more untested than main's last run" "$out"
check_not "#3312 an annotation about something else is not printed" "Node.js 20 actions" "$out"
said_at="$(awk 'index($0, "test-b.sh: not macOS") && !n { n = NR } END { if (n) print n }' <<< "$out")"
merge_at="$(awk 'index($0, "Merging, pinned to that head") && !n { n = NR } END { if (n) print n }' <<< "$out")"
[ -n "$said_at" ] && [ -n "$merge_at" ] && [ "$said_at" -lt "$merge_at" ] \
  && check_eq "#3312 said before it merges" ok ok \
  || check_eq "#3312 said before it merges" "before" "said at ${said_at:-never}, merge at ${merge_at:-never}"
check_eq "#3312 each check's annotations are read once" "1" "$(count gh-calls 'check-runs/501/annotations')"
check_eq "#3312 and the other check's once" "1" "$(count gh-calls 'check-runs/502/annotations')"

# A read that keeps failing is said, and the merge goes on: this reports, it never gates.
ut_fresh
printf '%s\n' 'gh: Server Error (HTTP 502)' > "$ST/annotations-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#3312 an annotations read that fails does not stop the merge" "0" "$rc"
check "#3312 and says what it could not read" "Could not read what check suite said it did not test" "$out"

# Checks with no details link (another repository's, or another kind of check) are not read at all.
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --squash)"; rc=$?
check_eq "#3312 a head with no Actions job links merges" "0" "$rc"
check_eq "#3312 and reads no annotations" "0" "$(count gh-calls '/annotations')"
unset MWR_UNTESTED_SKIP

# =================================================================================================
# 33. What the checks did not test is run here where the change touches it (claude-config#3312).
#     Dan, 2026-11-20 at 6:45 PM ET, asked whether a part the runner did not test must pass on the
#     merging Mac, picked "Only suites the change touches": before merging, the suites the checks
#     left a part of untested that the pull request changed, or whose code it changed, run on this
#     Mac at the head, and one that does not pass refuses the merge. The list is each part's record
#     (the notice is cut at 4096 characters), believed only when it adds up to the notice's count.
# =================================================================================================
UT="$WORKDIR/ut"; UT_TMP="$WORKDIR/ut-tmp"; mkdir -p "$UT"
# The stand in for the head's own run-all-tests.sh. Asked to deal (HOOK_TESTS_DEAL) it lists every
# suite in the tree as part 1, as the real one prints a deal; asked for a part it keeps the deal it
# was handed and answers as runner-mode says.
# It lists them with a find over the fixture's clone, which it is run in, sorted as git orders a
# tree's paths, and never by asking git for the tracked files. The push gate reads that spelling
# anywhere in a suite as a scan of the whole repository, and took this suite for one, which the
# repository's floor of named scanners then failed on (claude-config#3365). This suite scans no
# repository: the clone holds a fixture's three suites.
cat > "$STUBS/untested-runner.sh" <<'EOS'
#!/usr/bin/env bash
if [ -n "${HOOK_TESTS_DEAL:-}" ]; then
  printf 'deal\n' >> "$ST/runner-calls"
  [ -e "$ST/runner-deal-fails" ] && { echo "run-all-tests: the deal could not be made" >&2; exit 1; }
  find . -name 'test-*.sh' ! -type d ! -path './.git/*' | sed 's|^\./||' | LC_ALL=C sort | awk '{ printf "1\t%s\t1\tmedian\n", $0 }'
  exit 0
fi
printf 'part %s of %s, slot %s, record %s\n' "${HOOK_TESTS_PART:-}" "${HOOK_TESTS_PARTS:-}" "${HOOK_TESTS_SLOT:-}" "${HOOK_TESTS_UNMEASURED_FILE:+set}" >> "$ST/runner-calls"
cp "$HOOK_TESTS_DEALT" "$ST/runner-deal"
# What the clone it is run in knows of what is published, asked of git as a push gate run there asks.
{ git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo "origin/HEAD unknown"
  git rev-list --count HEAD ^refs/remotes/origin/main 2>/dev/null || echo "origin/main unknown"
  git config --get remote.origin.url 2>/dev/null || echo "no origin"; } > "$ST/runner-place"
mine="$(awk -F'\t' -v p="$HOOK_TESTS_PART" '$1 == p { print $2 }' "$HOOK_TESTS_DEALT")"
n="$(printf '%s\n' "$mine" | grep -c .)"
mode="$(cat "$ST/runner-mode" 2>/dev/null)"
case "$mode" in
  sleep) printf '%s\n' "$$" > "$ST/runner-pid"; sleep 30; echo woke > "$ST/runner-woke"; exit 0 ;;
  slow) sleep 2 ;;
  # A failing suite whose own output runs long, so the verdict is far down the runner's lines.
  longfail) for i in $(seq 1 250); do echo "    noise line $i"; done; mode=fail ;;
esac
# The suite that fails in mode fail: test-a.sh, or the one runner-fails names.
bad="$(cat "$ST/runner-fails" 2>/dev/null)"; bad="${bad:-test-a.sh}"
for s in $mine; do
  name="${s##*/}"
  if [ "$mode" = fail ] && [ "$name" = "$bad" ]; then printf '  FAIL  %-38s %-26s %s\n' "$name" "1 failed" "1s"
  elif [ "$mode" = notrun ] && [ "$name" = test-a.sh ]; then printf '  NOT RUN %-37s %s\n' "$name" "could not measure: no Chrome"
  else printf '  ok    %-38s %-26s %s\n' "$name" "passed" "1s"; fi
done
[ "$mode" = unmeasured ] && printf 'test-a.sh\tno Chrome on this Mac either\n' >> "$HOOK_TESTS_UNMEASURED_FILE"
case "$mode" in
  fail) echo "    expected 1, got 2"; echo "1 of $n SUITES FAILED: $bad"; exit 1 ;;
  notrun) echo "1 SUITE(S) COULD NOT RUN HERE: test-a.sh"; echo "ALL $((n - 1)) SUITES THAT COULD RUN PASSED, and 1 could not run here"; exit 0 ;;
esac
echo "ALL $n SUITES PASSED"
EOS
chmod +x "$STUBS/untested-runner.sh"
UT_NOTICE='3 parts in 3 suites were not tested on the runner, so these checks do not cover them:\ntest-a.sh: no Chrome\ntest-b.sh: no zsh\ntest-c.sh: not macOS'
# ut_state [<notice's message>]: GitHub's side, for the head the fixture made: a green suite check
# carrying the notice, and each part's record as the run's artifacts. This Mac's record of passes
# goes too, so each case runs its suites, unless UT_KEEP_PASSES is set. The head's tree holds the
# tool that writes the notice, as any tree whose checks carry one does; a case about a repository
# without it removes has-untested-tool.
ut_state(){
  fresh "$UT_HEAD" 0 "$UT_ROLLUP"
  : > "$ST/has-untested-tool"
  [ -n "${UT_KEEP_PASSES:-}" ] || rm -rf "$UT/records"
  jq -nc --arg m "$(printf "${1:-$UT_NOTICE}")" '[{path:".github",annotation_level:"notice",title:"Not tested by the checks",message:$m}]' > "$ST/annotations-501"
  mkdir -p "$ST/artifacts-900/part-unmeasured-1" "$ST/artifacts-900/part-unmeasured-2"
  printf 'test-a.sh\tno Chrome\ntest-b.sh\tno zsh\n' > "$ST/artifacts-900/part-unmeasured-1/unmeasured.tsv"
  printf 'test-c.sh\tnot macOS\n' > "$ST/artifacts-900/part-unmeasured-2/unmeasured.tsv"
  rm -rf "$UT_TMP"; mkdir -p "$UT_TMP"
}
# ut_fixture <name> <the branch's edit>: a bare acme/widget whose main holds three suites and the code
# they name, and whose feat/x (also refs/pull/7/head, as GitHub keeps it) makes the edit. test-a.sh
# names nothing, test-b.sh names hooks/lib/b-code.sh, test-c.sh names mods/one/register.ts (a name
# mods/two/register.ts shares), and notes.txt shares its name with hooks/lib/notes.txt all the way up.
ut_fixture(){
  UB="$UT/$1.git"; UW="$UT/$1-work"; US="$UT/$1-session"; UT_CONF="$UT/$1.gitconfig"
  git init -q --bare "$UB"; git init -q "$UW"
  mkdir -p "$UW/hooks/lib" "$UW/tests" "$UW/mods/one" "$UW/mods/two"
  printf '#!/usr/bin/env bash\necho a\n' > "$UW/hooks/test-a.sh"
  printf '#!/usr/bin/env bash\n. "$HERE/../hooks/lib/b-code.sh"\n' > "$UW/tests/test-b.sh"
  printf '#!/usr/bin/env bash\ncat "$ROOT/mods/one/register.ts"\ncat "$ROOT/hooks/lib/b-code.sh.orig"\n' > "$UW/tests/test-c.sh"
  printf 'echo b\n' > "$UW/hooks/lib/b-code.sh"; printf 'echo b2\n' > "$UW/hooks/lib/b-code.sh.orig"
  printf 'one\n' > "$UW/mods/one/register.ts"; printf 'two\n' > "$UW/mods/two/register.ts"
  printf 'n\n' > "$UW/notes.txt"; printf 'n\n' > "$UW/hooks/lib/notes.txt"
  # UT_REAL: suites that run and report as real ones do, beside a copy of the real runner and its
  # libraries where a claude-config tree holds them, which the step runs when no stand in is named.
  if [ -n "${UT_REAL:-}" ]; then
    printf '#!/usr/bin/env bash\necho a\nprintf "SUITE-RESULT passed=1 failed=0\\n"\n' > "$UW/hooks/test-a.sh"
    printf '#!/usr/bin/env bash\n# reads "$HERE/../hooks/lib/b-code.sh"\nprintf "SUITE-RESULT passed=1 failed=0\\n"\n' > "$UW/tests/test-b.sh"
    printf '#!/usr/bin/env bash\n# reads "$ROOT/mods/one/register.ts"\nprintf "SUITE-RESULT passed=1 failed=0\\n"\n' > "$UW/tests/test-c.sh"
    chmod +x "$UW/hooks/test-a.sh" "$UW/tests/test-b.sh" "$UW/tests/test-c.sh"
    mkdir -p "$UW/payload/hooks"; cp "$DIR/run-all-tests.sh" "$UW/payload/hooks/"; cp -R "$DIR/lib" "$UW/payload/hooks/lib"
  fi
  git -C "$UW" add -A; git -C "$UW" commit -qm base
  git -C "$UW" checkout -q -b feat/x
  (cd "$UW" && eval "$2"); git -C "$UW" add -A; git -C "$UW" commit -qm "the branch's edit"
  git -C "$UW" push -q "$UB" main feat/x feat/x:refs/pull/7/head
  git clone -q "$UB" "$US"
  git -C "$US" remote set-url origin https://github.com/acme/widget.git
  printf '[include]\n\tpath = %s\n[url "%s"]\n\tinsteadOf = https://github.com/acme/widget.git\n' "$GIT_CONFIG_GLOBAL" "$UB" > "$UT_CONF"
  UT_HEAD="$(git -C "$UB" rev-parse feat/x)"
  ut_state
}
UT_ROLLUP='[{"__typename":"CheckRun","name":"suite","workflowName":"tests","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-20T10:00:00Z","detailsUrl":"https://github.com/acme/widget/actions/runs/900/job/501"}]'
ut_run(){ (cd "$US" && TMPDIR="$UT_TMP" GIT_CONFIG_GLOBAL="$UT_CONF" MWR_UNTESTED_RUNNER="${UT_RUNNER-$STUBS/untested-runner.sh}" MWR_UNTESTED_DIR="$UT/records" bash "$HELPER" "$@" 2>&1); }
ut_left(){ find "$UT_TMP" -mindepth 1 -maxdepth 1 -name 'mwr-untested*' | wc -l | tr -d ' '; }
ut_before(){ # ut_before <text> <later text> <output>: ok when the first is said before the second
  local a b
  a="$(awk -v t="$1" 'index($0, t) && !n { n = NR } END { if (n) print n }' <<< "$3")"
  b="$(awk -v t="$2" 'index($0, t) && !n { n = NR } END { if (n) print n }' <<< "$3")"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo ok; else echo "at ${a:-never}, then ${b:-never}"; fi
}

# The pull request changes test-a.sh itself and the code test-b.sh names: those two run here, in a
# part of their own, test-c.sh does not, and the merge goes on once both pass.
ut_fixture touch 'echo "echo more" >> hooks/test-a.sh; echo "echo more" >> hooks/lib/b-code.sh'
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 suites the change touches pass here, and it merges" "0" "$rc"
check "#3312 it names the suite it changed" "test-a.sh (changed by this pull request)" "$out"
check "#3312 and the suite that names code it changed" "test-b.sh (names hooks/lib/b-code.sh)" "$out"
check_not "#3312 a longer name is not a mention (test-c.sh names b-code.sh.orig, not b-code.sh)" "test-c.sh (names" "$out"
check_eq "#3312 the two run as part 1, the rest as part 2" "$(printf '1\thooks/test-a.sh\n1\ttests/test-b.sh\n2\ttests/test-c.sh')" "$(cut -f1,2 "$ST/runner-deal" 2>/dev/null | sort -k2)"
check "#3312 run as one part of two, outside the Mac's full run slot, with the record of what is still untested asked for" "part 1 of 2, slot 0, record set" "$(cat "$ST/runner-calls" 2>/dev/null)"
check "#3312 it says it started them" "Running on this Mac the 2 suites" "$out"
check "#3312 and that they passed" "All 2 suites passed on this Mac at ${UT_HEAD:0:7}" "$out"
check_eq "#3312 said before it merges" ok "$(ut_before "All 2 suites passed on this Mac" "Merging, pinned to that head" "$out")"
check_eq "#3312 merged once" "1" "$(count gh-calls 'pr merge')"
check_eq "#3312 the throwaway clone is removed" "0" "$(ut_left)"
# THE CLONE KNOWS WHAT IS PUBLISHED. The step's first real merge, of #3392 on 2026-11-21, stopped on
# a suite the pull request had not broken: the clone knew no remote at all, so the push gate that
# suite asks about its own checkout took all 3347 commits of the history for ones a push would add,
# and refused on the message of one from 2026-10-29. Suites are written for a builder's worktree and
# a runner's checkout, which both know the remote and its default branch. So the stand in asks git,
# in the clone, what such a gate asks: the default branch, how many commits are on the head and not
# on it (one, the branch's edit, of the two in the history), and where origin is.
check_eq "#3312 the clone the suites run in knows the remote's default branch, counts only the pull request's commit as unpublished, and names origin" \
  "$(printf 'origin/main\n1\nhttps://github.com/acme/widget.git')" "$(cat "$ST/runner-place" 2>/dev/null)"
# A clone that cannot be told is not run in: the suites would judge a repository that looks as if
# nothing of it were published. git here fails the one write that names the default branch.
mkdir -p "$STUBS/nodefault"
cat > "$STUBS/nodefault/git" <<EOS
#!/usr/bin/env bash
case " \$* " in *" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/"*) echo "fatal: stub: the ref could not be written" >&2; exit 128 ;; esac
exec "$(command -v git)" "\$@"
EOS
chmod +x "$STUBS/nodefault/git"
# The pass just recorded is kept, for the case after this one: this refusal comes before it is read.
UT_KEEP_PASSES=1 ut_state
out="$(PATH="$STUBS/nodefault:$PATH" ut_run 7 --squash)"; rc=$?
check_eq "#3312 a clone that could not be told what is published refuses the merge" "1" "$rc"
check "#3312 saying what it could not record, in git's words" "could not be told which branch of acme/widget is published (fatal: stub: the ref could not be written)" "$out"
check_eq "#3312 and no suite is run in it" "0" "$(count runner-calls 'part ')"
check_eq "#3312 nothing merged from a clone it could not set up" "0" "$(count gh-calls 'pr merge')"
check_eq "#3312 and that clone is removed" "0" "$(ut_left)"
# Run again at the same head (a restart after a stop): the pass recorded for this head is believed,
# and nothing runs a second time.
UT_KEEP_PASSES=1 ut_state
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 run again at the same head, it merges" "0" "$rc"
check "#3312 saying they already passed here at this head" "already passed on this Mac at ${UT_HEAD:0:7}" "$out"
check_eq "#3312 and runs nothing again" "0" "$(count runner-calls 'part ')"

# A new head with the same change is run again: a pass belongs to the head it ran at.
UT_KEEP_PASSES=1 ut_fixture touch2 'echo "echo more" >> hooks/test-a.sh; echo "echo more" >> hooks/lib/b-code.sh'
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 another head merges" "0" "$rc"
check_eq "#3312 after its own run, not the other head's pass" "1" "$(count runner-calls 'part ')"

# A file sharing its name is named by the shortest end of its path nobody else has: one/register.ts
# chooses test-c.sh, and two/register.ts chooses nothing, which is said.
ut_fixture one 'echo more >> mods/one/register.ts'
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a change to mods/one/register.ts merges" "0" "$rc"
check "#3312 after running test-c.sh, which names it" "test-c.sh (names mods/one/register.ts)" "$out"
ut_fixture two 'echo more >> mods/two/register.ts'
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a change no untested suite is touched by merges" "0" "$rc"
check "#3312 saying none of them runs here" "None of the 3 suites the checks left a part of untested is changed by this pull request or names a file it changed, so none was run here" "$out"
check_eq "#3312 and runs no suite" "0" "$(count runner-calls 'part ')"

# A pull request that only deletes a file no suite names chooses nothing. A deleted file is named as
# it was in the tree the head left the base at (claude-config#3403), where two/register.ts is the
# shortest end of its path nobody else has. Named against the head's tree, which no longer holds it,
# register.ts would be its name, held there once by mods/one/register.ts, and test-c.sh would be run
# for a file it never named. And an empty list of the files changed at the head never reads as every
# suite changed (test-two-file-awk.sh).
ut_fixture deleted 'git rm -q mods/two/register.ts'
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a change that only deletes a file merges" "0" "$rc"
check "#3312 with no suite chosen for it" "None of the 3 suites the checks left a part of untested is changed by this pull request" "$out"
check_not "#3312 and the deleted file is not said to be one no suite can name" "Could not tell which suites test" "$out"
check_eq "#3312 and none run" "0" "$(count runner-calls 'part ')"

# A suite that names a file the pull request deletes is chosen and run (claude-config#3403): deleting
# a file a suite names changes what the suite tests. Until then the files deleted were left out of
# what the change touches, so such a suite never ran here. One pull request, three deletions:
# b-code.sh.orig, which test-c.sh names; b-code.sh, moved to b-core.sh, which git lists as the old
# path deleted and the new one added, and test-b.sh still names the old path; and notes.txt, whose
# path ended the same way as hooks/lib/notes.txt all the way up in the tree it was deleted from.
ut_fixture gone 'git rm -q hooks/lib/b-code.sh.orig notes.txt; git mv hooks/lib/b-code.sh hooks/lib/b-core.sh'
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3403 a change deleting files that suites name merges once those suites pass" "0" "$rc"
check "#3403 the suite naming a deleted file is run, and the deletion is said" "test-c.sh (names hooks/lib/b-code.sh.orig, which this pull request deletes)" "$out"
check "#3403 a moved file's old path is a deleted one, and the suite still naming it is run" "test-b.sh (names hooks/lib/b-code.sh, which this pull request deletes)" "$out"
check_eq "#3403 the two run as part 1, the rest as part 2" "$(printf '2\thooks/test-a.sh\n1\ttests/test-b.sh\n1\ttests/test-c.sh')" "$(cut -f1,2 "$ST/runner-deal" 2>/dev/null | sort -k2)"
check "#3403 a deleted file no suite could name alone is said, as a deleted one" "Could not tell which suites test notes.txt, which this pull request deletes: another file in the tree it was deleted from has a path ending the same way, so no suite can name it alone" "$out"
check_eq "#3403 merged once" "1" "$(count gh-calls 'pr merge')"
# Such a suite failing refuses the merge as any other does: the red says the suite must be brought
# up to date in the same pull request.
ut_state; printf fail > "$ST/runner-mode"; printf test-c.sh > "$ST/runner-fails"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3403 a suite naming a deleted file that fails here refuses the merge" "1" "$rc"
check "#3403 saying a suite failed, at which head" "Stopped: 1 of the suites the checks left a part of untested failed on this Mac at ${UT_HEAD:0:7}" "$out"
check "#3403 with the runner's line for it" "FAIL  test-c.sh" "$out"
check_eq "#3403 nothing merged on that failure" "0" "$(count gh-calls 'pr merge')"

# A file whose name another file shares all the way up cannot be named, so which suites test it is
# not known, and that is said, never passed over.
ut_fixture notes 'echo more >> notes.txt'
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a change it cannot judge still merges" "0" "$rc"
check "#3312 saying which file it could not tell about, and why" "Could not tell which suites test notes.txt: another file in the tree has a path ending the same way, so no suite can name it alone" "$out"

# A suite that fails refuses the merge, with the runner's own lines.
ut_fixture fail 'echo "echo more" >> hooks/test-a.sh'
printf fail > "$ST/runner-mode"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a suite that fails here refuses the merge" "1" "$rc"
check "#3312 saying which, at which head" "Stopped: 1 of the suites the checks left a part of untested failed on this Mac at ${UT_HEAD:0:7}" "$out"
check "#3312 with the runner's own lines" "expected 1, got 2" "$out"
check_eq "#3312 nothing merged on a failure" "0" "$(count gh-calls 'pr merge')"
check_eq "#3312 and nothing recorded as passed" "0" "$(find "$UT/records" -type f -name "$UT_HEAD" 2>/dev/null | wc -l | tr -d ' ')"
check_eq "#3312 the clone is removed after a refusal too" "0" "$(ut_left)"
# A failure far down a long output is still shown: the status lines, then the end, never only the
# first lines.
ut_state; printf longfail > "$ST/runner-mode"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a failure after a long output refuses the merge" "1" "$rc"
check "#3312 showing the failed suite's status line" "FAIL  test-a.sh" "$out"
check "#3312 and the runner's verdict at the end" "1 of 1 SUITES FAILED: test-a.sh" "$out"
check "#3312 saying lines were left out" "the runner printed 253 lines" "$out"

# GitHub's refs/pull/<n>/head behind the head this run judged: the step waits a look before trying
# again, bounded as every other wait is, rather than going round at once. The ref catches up at the
# first wait. The run is bounded by an alarm, so a step that never waits fails rather than hangs.
ut_state; printf '' > "$ST/runner-mode"
git --git-dir="$UB" update-ref refs/pull/7/head "$(git --git-dir="$UB" rev-parse main)"
printf 'git --git-dir=%q update-ref refs/pull/7/head %s\n' "$UB" "$UT_HEAD" > "$ST/on-sleep"
out="$(cd "$US" && TMPDIR="$UT_TMP" GIT_CONFIG_GLOBAL="$UT_CONF" MWR_UNTESTED_RUNNER="$STUBS/untested-runner.sh" MWR_UNTESTED_DIR="$UT/records" perl -e 'alarm 120; exec @ARGV' bash "$HELPER" 7 --squash 2>&1)"; rc=$?
check_eq "#3312 a pull ref behind the head merges once it catches up" "0" "$rc"
check "#3312 saying it waits for GitHub's ref" "GitHub's head of #7 is at" "$out"
check_eq "#3312 after waiting a look, not going round at once" "1" "$(grep -c -x '30' "$ST/sleeps" 2>/dev/null || true)"
check_eq "#3312 asking once whether the tree holds the tool, though the step took two looks" "1" "$(count gh-calls 'contents/tools/ci-unmeasured-summary.sh')"
git --git-dir="$UB" update-ref refs/pull/7/head "$UT_HEAD"

# A suite that could not run is not a pass.
ut_state; printf notrun > "$ST/runner-mode"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a suite that could not run here refuses the merge" "1" "$rc"
check "#3312 saying the runner did not report every one passed" "did not report all 1 passed" "$out"
check_eq "#3312 nothing merged when one could not run" "0" "$(count gh-calls 'pr merge')"

# A part still untested here is said, and the merge goes on: it ran, and nothing failed.
ut_state; printf unmeasured > "$ST/runner-mode"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a part untested here too still merges" "0" "$rc"
check "#3312 and is named" "Not tested on this Mac either: test-a.sh: no Chrome on this Mac either" "$out"
check_eq "#3312 the pass is recorded under the repository and the head" "hooks/test-a.sh" "$(cat "$UT/records/acme_widget/$UT_HEAD" 2>/dev/null)"

# The runner past the step's bound is stopped, all of it, and the merge refused.
ut_state; printf sleep > "$ST/runner-mode"
out="$(MWR_UNTESTED_MAX_SECONDS=60 ut_run 7 --squash)"; rc=$?
check_eq "#3312 suites past their bound refuse the merge" "1" "$rc"
check "#3312 saying they were stopped at the bound" "were still running after 1m 00s, the bound MWR_UNTESTED_MAX_SECONDS sets, so they were stopped" "$out"
pid="$(cat "$ST/runner-pid" 2>/dev/null)"
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then alive=alive; else alive=gone; fi
check_eq "#3312 and the runner is gone" "gone" "$alive"
check_eq "#3312 nothing merged past the bound" "0" "$(count gh-calls 'pr merge')"
# A runner stopped before it has a process group of its own (stopped in its first moments, or a
# setpgrp that did not happen) is stopped by its own pid, and the step does not wait out its work.
mkdir -p "$STUBS/nogroup"
cat > "$STUBS/nogroup/perl" <<'EOS'
#!/usr/bin/env bash
case "${2:-}" in *setpgrp*) shift 2; exec "$@" ;; esac
exec /usr/bin/perl "$@"
EOS
chmod +x "$STUBS/nogroup/perl"
ut_state; printf sleep > "$ST/runner-mode"
out="$(PATH="$STUBS/nogroup:$PATH" MWR_UNTESTED_MAX_SECONDS=60 ut_run 7 --squash)"; rc=$?
check_eq "#3312 a runner with no group of its own past the bound refuses the merge" "1" "$rc"
pid="$(cat "$ST/runner-pid" 2>/dev/null)"
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then alive=alive; else alive=gone; fi
check_eq "#3312 and that runner is gone too" "gone" "$alive"
check_eq "#3312 before its work could finish" "0" "$(count runner-woke woke)"

# While they run it says it is still running, with how long and how many have finished.
ut_state; printf slow > "$ST/runner-mode"
out="$(MWR_HEARTBEAT_SECONDS=10 MWR_UNTESTED_MAX_SECONDS=1000000 ut_run 7 --squash)"; rc=$?
check_eq "#3312 slow suites that pass merge" "0" "$rc"
check "#3312 saying they are still running" "Still running the suites the checks left untested at ${UT_HEAD:0:7}:" "$out"

# A runner that cannot make its deal, or is not there, could not start: refused.
ut_state; : > "$ST/runner-deal-fails"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a runner that cannot deal refuses the merge" "1" "$rc"
check "#3312 saying the suites could not be started" "could not be started on this Mac" "$out"
ut_state
out="$(UT_RUNNER="$UT/no-such-runner.sh" ut_run 7 --squash)"; rc=$?
check_eq "#3312 a missing runner refuses the merge" "1" "$rc"
check "#3312 naming it" "no-such-runner.sh" "$out"

# The switch skips the step for one run, saying so and why.
ut_state
out="$(MWR_UNTESTED_SKIP="the runner's Chrome is broken today" ut_run 7 --squash)"; rc=$?
check_eq "#3312 the switch lets it merge without running them" "0" "$rc"
check "#3312 saying it skipped them and why" "Did not run the suites the checks left untested, because MWR_UNTESTED_SKIP is set: the runner's Chrome is broken today" "$out"
check_eq "#3312 and runs nothing" "0" "$(count runner-calls 'part ')"

# Every way of not knowing the list refuses, saying what could not be read.
ut_state; printf '%s\n' 'gh: Server Error (HTTP 502)' > "$ST/annotations-down"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 an annotations read that fails in a tree with the tool refuses the merge" "1" "$rc"
check "#3312 saying what it could not read" "could not read what check suite said it did not test" "$out"
check_eq "#3312 nothing merged on an unread notice" "0" "$(count gh-calls 'pr merge')"
# A REPOSITORY WITHOUT THE TOOL IS NOT TOUCHED. This helper merges in every project, and most hold no
# such tool, so whether the tree holds it is asked before anything here can refuse. The same failed
# read there stops nothing: the merge goes on in the words of a run with the step skipped, the report
# alone saying what it could not read. The lessons review at c502ecd found the step refusing it.
ut_state; rm -f "$ST/has-untested-tool"; printf '%s\n' 'gh: Server Error (HTTP 502)' > "$ST/annotations-down"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 an annotations read that fails in a tree without the tool does not stop the merge" "0" "$rc"
check_eq "#3312 and it merges" "1" "$(count gh-calls 'pr merge')"
check "#3312 the report alone saying what it could not read" "so any part check suite left untested is not named here. Merging all the same: this is a report, not a gate." "$out"
check_not "#3312 and the step saying nothing" "which suites to run here" "$out"
ut_state; rm -f "$ST/has-untested-tool"; printf '%s\n' 'gh: Server Error (HTTP 502)' > "$ST/annotations-down"
skipped="$(MWR_UNTESTED_SKIP='a run without the step' ut_run 7 --squash | grep -v 'MWR_UNTESTED_SKIP is set')"
check_eq "#3312 in the very words of a run with the step skipped" "" "$(diff <(printf '%s\n' "$skipped") <(printf '%s\n' "$out") | sed -n '1,6p')"
# Nor does a notice there start anything: one the step could not read, in a tree with no tool, is
# printed by the report and no suite is dealt or run.
ut_state 'Something else entirely.'; rm -f "$ST/has-untested-tool"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a notice it cannot read in a tree without the tool does not stop the merge" "0" "$rc"
check_eq "#3312 and no runner is started" "0" "$(count runner-calls .)"
check_eq "#3312 and no record is fetched" "0" "$(count gh-calls 'run download')"
ut_state "Every suite measured every part on the runner."
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 checks that left nothing untested merge" "0" "$rc"
check "#3312 saying nothing runs here" "The checks at ${UT_HEAD:0:7} left no part of any suite untested, so no suite was run here." "$out"
check_eq "#3312 with no record fetched" "0" "$(count gh-calls 'run download')"
ut_state '2 parts in 2 suites were not tested on the runner, so these checks do not cover them:\ntest-a.sh: no Chrome\nPart 2 handed back no record of what it did not test.'
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a part with no record refuses the merge" "1" "$rc"
check "#3312 saying the list is not whole" "not every part of the checks handed back its record" "$out"
ut_state 'Something else entirely.'
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a notice it cannot read refuses the merge" "1" "$rc"
check "#3312 quoting it" "could not read how many parts the notice on check suite counts (Something else entirely.)" "$out"
ut_state; rm -rf "$ST/artifacts-900"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 records that cannot be fetched refuse the merge" "1" "$rc"
check "#3312 saying what to do" "gh run rerun 900 --repo acme/widget" "$out"
# A read GitHub did not answer is asked again, as every other read here is, and a network fault is
# never blamed on records that expired.
ut_state; printf '%s\n' 'Get "https://api.github.com/repos/acme/widget/check-runs/501/annotations": net/http: TLS handshake timeout' > "$ST/annotations-fails"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a notice read that fails once is asked again, and it merges" "0" "$rc"
check_eq "#3312 read twice" "2" "$(count gh-calls 'check-runs/501/annotations')"
ut_state; printf '%s\n' 'Get "https://api.github.com/repos/acme/widget/actions/runs/900/artifacts": net/http: TLS handshake timeout' > "$ST/download-fails"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a records download that fails once is asked again, and it merges" "0" "$rc"
check_eq "#3312 fetched twice" "2" "$(count gh-calls 'run download 900')"
ut_state; printf '%s\n' 'gh: Server Error (HTTP 502)' > "$ST/download-down"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a records download that keeps failing refuses the merge" "1" "$rc"
check "#3312 saying it could not be read" "could not read the record of what each part did not test from workflow run 900" "$out"
check_not "#3312 and not blaming expired records" "keeps them for a day" "$out"

# A fork's head is somebody else's code, never run on this Mac: refused, saying so.
ut_state; printf true > "$ST/cross"; printf someone > "$ST/fork-owner"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a fork's pull request with suites to run refuses the merge" "1" "$rc"
check "#3312 saying its code is not run here" "#7 comes from a fork (someone/widget), so its code is not run on this Mac" "$out"
check_eq "#3312 and nothing is dealt or run" "0" "$(count runner-calls .)"

# Every read the step makes is classed as the helper's other reads are (mt_gh_read_class): a network
# outage is waited through, and a refused sign in is said as one (claude-config#2303, #1615). The
# outage here lasts 5 minutes of the injected clock (a length this case sets, not a measurement), past
# the four tries, and costs no real time.
ut_net_back_at(){ # ut_net_back_at <state file> <clock>: the file is removed once the clock reaches it
  local i; for i in $(seq 1 600); do printf '[ "$(cat "$ST/clock")" -lt %s ] || rm -f "$ST/%s"\n' "$2" "$1" >> "$ST/on-sleep"; done
}
ut_state; printf '%s\n' "$CONNECT" > "$ST/annotations-down"; ut_net_back_at annotations-down 1000300
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a notice read through a network outage merges" "0" "$rc"
check "#3312 saying it waited on the network for that read" "Waiting on the network: GitHub has not been reachable for" "$out"
check "#3312 naming the notice read" "reading what check suite said it did not test" "$out"
ut_state; printf '%s\n' "$SIGNIN" > "$ST/annotations-down"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a notice read whose sign in is refused refuses the merge" "1" "$rc"
check "#3312 said as a refused sign in" "GitHub refused the sign in 4 times reading what check suite said it did not test" "$out"
ut_state; printf '%s\n' "$CONNECT" > "$ST/download-down"; ut_net_back_at download-down 1000300
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a records download through a network outage merges" "0" "$rc"
check "#3312 naming the records it waited on" "reading the record of what each part did not test from workflow run 900" "$out"
ut_state; printf '%s\n' "$SIGNIN" > "$ST/download-down"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a records download whose sign in is refused refuses the merge" "1" "$rc"
check "#3312 said as a refused sign in, for the records" "GitHub refused the sign in 4 times reading the record of what each part did not test" "$out"
ut_state; rm -f "$ST/annotations-501" "$ST/has-untested-tool"; printf '%s\n' "$CONNECT" > "$ST/contents-down"; ut_net_back_at contents-down 1000300
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a read for the tool through a network outage merges" "0" "$rc"
check "#3312 naming the tool read it waited on" "reading whether the tree at ${UT_HEAD:0:7} holds tools/ci-unmeasured-summary.sh" "$out"
ut_state; rm -f "$ST/annotations-501"; printf '%s\n' "$SIGNIN" > "$ST/contents-down"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a read for the tool whose sign in is refused refuses the merge" "1" "$rc"
check "#3312 said as a refused sign in, for the tool" "GitHub refused the sign in 4 times reading whether the tree at ${UT_HEAD:0:7} holds tools/ci-unmeasured-summary.sh" "$out"
ut_state; printf 'test-c.sh\tnot macOS\n' > "$ST/artifacts-900/part-unmeasured-1/unmeasured.tsv"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 records that do not add up to the notice refuse the merge" "1" "$rc"
check "#3312 saying both counts" "the records hold 2 parts and the notice counts 3" "$out"
ut_state; printf 'test-a.sh\tno Chrome\ntest-gone.sh\tno zsh\n' > "$ST/artifacts-900/part-unmeasured-1/unmeasured.tsv"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a record naming a suite the head does not hold refuses the merge" "1" "$rc"
check "#3312 naming it" "test-gone.sh" "$out"

# No notice at all: a repository without the tool is none of this step's business; one with it is
# a run that did not say what it left untested (a run reusing an earlier green run says nothing).
ut_state; rm -f "$ST/annotations-501" "$ST/has-untested-tool"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 no notice and no tool in the tree merges" "0" "$rc"
check_not "#3312 and says nothing about untested suites" "untested" "$out"
ut_state; rm -f "$ST/annotations-501"; : > "$ST/has-untested-tool"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 no notice in a tree with the tool refuses the merge" "1" "$rc"
check "#3312 saying why" "No check at ${UT_HEAD:0:7} says what it did not test, though its tree holds tools/ci-unmeasured-summary.sh" "$out"
check "#3312 and that none says it reused an earlier run" "and none says in its log that it reused an earlier green run" "$out"

# A run that reused an earlier green run of the same tree (claude-config#2690) carries no notice, and
# its checks' logs name the run they stood on, as tests.yml writes it. That run is followed for its
# notice and records, believed only when its own artifacts record that it tested that very tree.
UT_TREE=1111111111111111111111111111111111111111
ut_reused(){ # ut_reused <the tree the earlier run's own record names>
  ut_state; : > "$ST/has-untested-tool"
  mv "$ST/annotations-501" "$ST/annotations-602"; mv "$ST/artifacts-900" "$ST/artifacts-800"
  printf '%s\n' '2026-11-20T10:00:01.0000000Z ##[group]Run echo "NOT RUN AGAIN. Tree $TREE already passed in run $RUN_URL on commit $RUN_SHA, so no suite ran in this run."' \
    "2026-11-20T10:00:01.1000000Z NOT RUN AGAIN. Tree $UT_TREE already passed in run https://github.com/acme/widget/actions/runs/800 on commit 2222222222222222222222222222222222222222, so no suite ran in this run." > "$ST/joblog-501"
  jq -nc --arg t "green-tree-$1" '{total_count: 3, artifacts: [{name: "part-unmeasured-1"}, {name: "part-unmeasured-2"}, {name: $t}]}' > "$ST/artifactsjson-800"
  jq -nc '{total_count: 2, jobs: [{id: 601, name: "suites part 1"}, {id: 602, name: "suite"}]}' > "$ST/jobsjson-800"
}
ut_reused "$UT_TREE"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a run that reused an earlier one of the same tree merges" "0" "$rc"
check "#3312 saying which run it followed" "The checks at ${UT_HEAD:0:7} reused workflow run 800, which tested the same tree (${UT_TREE:0:12}, on commit 2222222), so its list of what it did not test is used." "$out"
check_eq "#3312 its records fetched from that run" "1" "$(count gh-calls 'run download 800')"
check_eq "#3312 and the suite the change touches run here" "1" "$(count runner-calls 'part ')"
ut_reused "$UT_TREE"; rm -rf "$ST/artifacts-800"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a reused run whose records are gone refuses the merge" "1" "$rc"
check "#3312 saying which run was looked in" "from workflow run 800, the run the checks at ${UT_HEAD:0:7} reused" "$out"
check_eq "#3312 nothing merged without them" "0" "$(count gh-calls 'pr merge')"
ut_reused 3333333333333333333333333333333333333333
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a reused run of a different tree refuses the merge" "1" "$rc"
check "#3312 saying which tree it recorded" "workflow run 800, which check suite at ${UT_HEAD:0:7} says it reused for tree ${UT_TREE:0:12}, records no green run of that tree (it records: green-tree-333333333333" "$out"
check_eq "#3312 and fetches none of its records" "0" "$(count gh-calls 'run download')"
ut_reused "$UT_TREE"; rm -f "$ST/annotations-602"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a reused run with no notice of its own refuses the merge" "1" "$rc"
check "#3312 saying so" "No check of workflow run 800, which the checks at ${UT_HEAD:0:7} reused, says what it did not test" "$out"
ut_reused "$UT_TREE"; printf '%s\n' 'gh: Server Error (HTTP 502)' > "$ST/joblog-down"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a check's log that cannot be read refuses the merge" "1" "$rc"
check "#3312 saying which log" "could not read the log of check suite at ${UT_HEAD:0:7}" "$out"
ut_reused "$UT_TREE"; printf '%s\n' 'gh: Server Error (HTTP 502)' > "$ST/runartifacts-down"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a reused run whose artifacts cannot be listed refuses the merge" "1" "$rc"
check "#3312 saying which run" "could not read the artifacts of workflow run 800, which the checks at ${UT_HEAD:0:7} reused" "$out"
ut_reused "$UT_TREE"; printf '%s\n' "$CONNECT" > "$ST/joblog-down"; ut_net_back_at joblog-down 1000300
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a check's log read through a network outage merges" "0" "$rc"
check "#3312 naming the log it waited on" "reading the log of check suite at ${UT_HEAD:0:7}" "$out"
ut_reused "$UT_TREE"; printf '%s\n' "$SIGNIN" > "$ST/joblog-down"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a check's log read whose sign in is refused refuses the merge" "1" "$rc"
check "#3312 said as a refused sign in, for the log" "GitHub refused the sign in 4 times reading the log of check suite" "$out"

ut_state; rm -f "$ST/annotations-501"; printf 'gh: Server Error (HTTP 502)\n' > "$ST/contents-down"
out="$(ut_run 7 --squash)"; rc=$?
check_eq "#3312 a tree that cannot be read for the tool refuses the merge" "1" "$rc"
check "#3312 saying what could not be read" "whether the tree at ${UT_HEAD:0:7} holds tools/ci-unmeasured-summary.sh" "$out"

# The head's own REAL run-all-tests.sh, with no stand in: it deals the tree, runs part 1, and judges
# the suites, so the deal and part it is handed are proved against the runner itself (L3). Its runs
# get a config folder of their own, never this Mac's (lib/fixture-runner-home.sh). Each look while
# it runs moves the injected clock 5 seconds (a step the stand in sets, not measured) in no real
# time, so the bound is lifted here: these cases are about the runner, and the bound has its own
# case above.
export MWR_UNTESTED_MAX_SECONDS=100000000
UT_REAL=1 ut_fixture real 'echo "# more" >> hooks/test-a.sh'
out="$(fixture_runner_home "$UT/real-home" && UT_RUNNER= ut_run 7 --squash)"; rc=$?
check_eq "#3312 the real runner passes the suite the change touches, and it merges" "0" "$rc"
check "#3312 the real runner ran it alone" "All 1 suite passed on this Mac at ${UT_HEAD:0:7}: test-a.sh (changed by this pull request)" "$out"
UT_REAL=1 ut_fixture realfail 'printf "#!/usr/bin/env bash\necho \"passed: 0, failed: 1\"\nexit 1\n" > hooks/test-a.sh'
out="$(fixture_runner_home "$UT/real-home" && UT_RUNNER= ut_run 7 --squash)"; rc=$?
check_eq "#3312 the real runner failing the suite refuses the merge" "1" "$rc"
check "#3312 with the real runner's FAIL line" "FAIL  test-a.sh" "$out"
check_eq "#3312 nothing merged on the real runner's failure" "0" "$(count gh-calls 'pr merge')"
unset MWR_UNTESTED_MAX_SECONDS

echo
mwr_harness_result
