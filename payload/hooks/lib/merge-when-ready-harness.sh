#!/usr/bin/env bash
#
# merge-when-ready-harness.sh: the one world the suites of lib/merge-when-ready.sh run the helper in
# (claude-config#3572).
#
# test-merge-when-ready.sh held every check of the helper until its section 34, the bypass merge
# and sleep mode's say over it (claude-config#3534, 249 checks), took that suite past
# run-all-tests.sh's 1,200 second wall limit on a slow GitHub runner on 2026-11-24 (exit 124),
# which stopped the config sync between the two Macs. Those checks are now test-merge-when-ready-bypass.sh, a suite
# of their own that the runner deals to a part by its own measured cost (L315). Both suites run the
# helper in the same world, so that world is here, once, and neither suite holds a copy of it
# (L613): a second copy of the fake gh would let the two drift apart until a check in one passed
# against a GitHub the other no longer described.
#
# Sourced, never run, after the suite has armed its own deadline (lib/suite-deadline.sh) and set
# DIR to the hooks folder. Sourcing it sets only what every run of a suite needs, its
# documentation only run included: HELPER, the helper under test; WORKDIR, a temporary folder
# removed when the suite exits; the pass and fail counters with ok, bad, check, check_not and
# check_eq; and mwr_harness_result. mwr_harness_build then makes the rest: the fake gh, which holds
# the pull request's state in files under $ST and moves it as GitHub does; the injected sleep and
# clock; the stub gates and review checker; git with no network; the checkout of acme/widget to
# run from; and fresh, run, present and count.
#
# mwr_harness_build's body is the opening of test-merge-when-ready.sh moved here unchanged, with the
# two answers of GitHub's that both suites read (WRONG and LIMITED) moved up beside it, and the stub
# gates moved, each unchanged, into files under merge-when-ready-fixtures/stub-gates. It is not
# indented, which keeps each heredoc's end marker at the left margin, where bash looks for it. A
# section named in its comments is a section of test-merge-when-ready.sh.
#
# USE, in a suite:
#
#   DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$DIR/lib/merge-when-ready-harness.sh" || { ...refuse to run... }
#   mwr_harness_build
#   fresh "$OLD" 0 "$GREEN"; out="$(run 7 --squash)"; rc=$?
#   check_eq "<what it proves>" "0" "$rc"
#   echo; mwr_harness_result   # last: the totals and the SUITE-RESULT line, returning 1 on a failure

HELPER="$DIR/lib/merge-when-ready.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:2000}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then ok; else bad "$1"; echo "  must not contain: $2"; echo "  actual: ${3:0:2000}"; fi; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }

# The totals and the agreed result line run-all-tests.sh reads, returning 1 when anything failed,
# so a suite whose last command this is exits as it should.
mwr_harness_result(){
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

# The fake GitHub world every case runs the helper in. Called once, before the first case.
mwr_harness_build(){
unset PR_REVIEW_READ SKIP_PR_REVIEW ALLOW_RED_MERGE ALLOW_BEHIND_MERGE ALLOW_UNPINNED_MERGE 2>/dev/null || true

OLD="1111111111111111111111111111111111111111"
NEW="2222222222222222222222222222222222222222"
NEWER="3333333333333333333333333333333333333333"
GREEN='[{"__typename":"CheckRun","name":"tests","workflowName":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-06T10:00:00Z"}]'
PENDING='[{"__typename":"CheckRun","name":"tests","workflowName":"ci","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-10-06T10:05:00Z"}]'
RED='[{"__typename":"CheckRun","name":"tests","workflowName":"ci","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-10-06T10:00:00Z"}]'

# --- the fake gh ---------------------------------------------------------------------------------
BIN="$WORKDIR/bin"; mkdir -p "$BIN"
export ST="$WORKDIR/state"
cat > "$BIN/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ST/gh-calls"
rd(){ cat "$ST/$1" 2>/dev/null; }
# A read can be made to fail (claude-config#1061): <read>-fails holds one error per line, each spent
# by one call, and <read>-down holds an error every call prints, GitHub staying unreachable.
pop(){ local f="$ST/$1" l; [ -s "$f" ] || return 1; l="$(head -1 "$f")"; tail -n +2 "$f" > "$f.tmp"; mv "$f.tmp" "$f"; printf '%s' "$l"; }
fail_read(){
  local e
  if e="$(pop "$1-fails")"; then printf '%s\n' "$e" >&2; exit 1; fi
  [ -s "$ST/$1-down" ] && { cat "$ST/$1-down" >&2; exit 1; }
  return 0
}
gone(){ : > "$ST/branch-deleted"; printf 'feat/x\n' >> "$ST/deleted"; cat "$ST/stacked" >> "$ST/closed" 2>/dev/null; : > "$ST/stacked"; }
# Which signed in account a call is made as (claude-config#2629): accounts lists the names gh is
# signed in to, one per line, the first the active one, and a call scoped to one carries the stand in
# token below. With no accounts file there is one account, the active one, named active.
who(){
  case "${GH_TOKEN:-}" in
    token-for-*) printf '%s' "${GH_TOKEN#token-for-}" ;;
    *) if [ -s "$ST/accounts" ]; then head -1 "$ST/accounts"; else printf active; fi ;;
  esac
}
case "$*" in
  "auth status"*)
    # As gh prints it, with each account's token check and scopes left out.
    if [ -s "$ST/accounts" ]; then
      printf 'github.com\n'; first=true
      while read -r a; do
        printf '  Logged in to github.com account %s (keyring)\n  - Active account: %s\n\n' "$a" "$first"; first=false
      done < "$ST/accounts"
    fi
    exit 0 ;;
  # The token read made after a refused sign in (claude-config#1615): token-empty makes the keyring
  # read come back empty. A stand in, never a token shape. With accounts listed, each account's
  # token names it, so a call scoped to it is answered as that account (claude-config#2629).
  "auth token"*)
    [ -e "$ST/token-empty" ] && exit 0
    if [ -s "$ST/accounts" ]; then printf 'token-for-%s\n' "$(printf '%s\n' "$*" | sed -nE 's/.*-u ([^ ]+).*/\1/p')"
    else echo stand-in; fi
    exit 0 ;;
  # The permission the account asking has on the repository (claude-config#2629): perm-<account>
  # holds it, WRITE when unset, and perm-<account>-fails or -down make that account's read fail.
  "repo view acme/widget --json viewerPermission"*)
    w="$(who)"; printf '%s\n' "$w" >> "$ST/perm-asked"
    fail_read "perm-$w"
    p="$(rd "perm-$w")"
    # The same answer names the repository's default branch (claude-config#3118): default-branch
    # holds it, main when unset, and default-branch-unnamed leaves it out of the answer.
    if [ -e "$ST/default-branch-unnamed" ]; then printf '{"viewerPermission":"%s"}\n' "${p:-WRITE}"
    else db="$(rd default-branch)"; printf '{"viewerPermission":"%s","defaultBranchRef":{"name":"%s"}}\n' "${p:-WRITE}" "${db:-main}"; fi
    ;;
  # The rate limit probe (claude-config#1482): probe holds GitHub's whole answer, headers and body,
  # as `gh api -i` prints it; with none it is a call nothing expected.
  "api -i rate_limit"*)
    printf '%s\n' "$(rd clock)" >> "$ST/probe-times"
    [ -s "$ST/probe" ] || { echo "fake gh: no probe answer set" >&2; exit 3; }
    cat "$ST/probe"
    ;;
  "pr view"*)
    printf '%s\n' "$(rd clock)" >> "$ST/view-times"
    if [ -e "$ST/merged" ]; then fail_read readback; else fail_read view; fi
    state=OPEN; [ -e "$ST/merged" ] && state=MERGED
    ms=CLEAN; [ "$(rd behind)" != 0 ] && ms=BEHIND
    # labels holds the pull request's labels as JSON, for the changelog record gate (#1178).
    lb="$(rd labels)"
    # cross holds true when the pull request's branch lives in a fork (claude-config#1337).
    cx="$(rd cross)"
    # fork-owner names the account a fork's branch lives under (claude-config#1458); acme otherwise.
    fo="$(rd fork-owner)"
    # base-ref names the branch the pull request is based on, main when unset (claude-config#3118).
    br="$(rd base-ref)"
    # review-decision holds what GitHub reads the pull request's reviews as (claude-config#3534):
    # empty when unset, as GitHub answers where no rule asks for a review.
    jq -nc --arg h "$(rd head)" --arg s "$state" --arg ms "$ms" --argjson r "$(rd rollup)" --argjson l "${lb:-[]}" --argjson x "${cx:-false}" --arg fo "${fo:-acme}" --arg br "${br:-main}" --arg rv "$(rd review-decision)" \
      '{number:7,state:$s,headRefOid:$h,headRefName:"feat/x",baseRefName:$br,isCrossRepository:$x,headRepositoryOwner:{login:$fo},headRepository:{name:"widget"},statusCheckRollup:$r,mergeStateStatus:$ms,mergeable:"MERGEABLE",reviewDecision:$rv,url:"https://github.com/acme/widget/pull/7",author:{login:"dwright-pennie"},labels:$l,body:""}'
    ;;
  # A fork's branch, read from the fork (claude-config#1458): fork-tip, or the head when unset.
  "api repos/someone/widget/git/ref/heads/feat/x"*)
    ft="$(rd fork-tip)"
    printf '{"ref":"refs/heads/feat/x","object":{"sha":"%s","type":"commit"}}\n' "${ft:-$(rd head)}"
    ;;
  # Re-setting the pull request's own base to the one it has, the resync (claude-config#1458).
  # resync-takes makes GitHub pick up the branch's tip at once, with that head's checks pending, as
  # it did for Bidspoke #2577; without it the pull request keeps its stale head.
  "api -X PATCH repos/acme/widget/pulls/7 "*)
    printf '%s\n' "$(rd clock)" >> "$ST/resyncs"
    if [ -e "$ST/resync-takes" ]; then
      rd branch-tip > "$ST/head"; printf '%s' "$(rd rollup-after-resync)" > "$ST/rollup"
      # behind-after-resync: the head GitHub now shows is an update's, which holds the base.
      [ -s "$ST/behind-after-resync" ] && cp "$ST/behind-after-resync" "$ST/behind"
    fi
    printf '{"number":7,"base":{"ref":"main"}}\n'
    ;;
  # The merged pull request's branch and the pull requests stacked on it (claude-config#1337).
  # stacked holds the numbers of the open pull requests whose base is feat/x, one per line. Deleting
  # the branch closes every one still there, as GitHub does, into closed: a closed pull request's
  # base can never be changed again, which is the harm the helper must not cause.
  "api repos/acme/widget/git/ref/heads/feat/x"*)
    fail_read ref
    [ -e "$ST/branch-deleted" ] && { echo '{"message":"Not Found","status":"404"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    bt="$(rd branch-tip)"
    printf '{"ref":"refs/heads/feat/x","object":{"sha":"%s","type":"commit"}}\n' "${bt:-$(rd head)}"
    ;;
  # The base branch, read as the positive control for a 404 on the merged branch: base-hidden makes
  # GitHub answer 404 for it too, as it does for anything the account cannot see.
  "api repos/acme/widget/git/ref/heads/main"*)
    [ -e "$ST/base-hidden" ] && { echo '{"message":"Not Found","status":"404"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    printf '{"ref":"refs/heads/main","object":{"sha":"%s","type":"commit"}}\n' "$(rd main-tip)"
    ;;
  # The merged pull requests, as check-stale-worktrees.sh asks for them (claude-config#1521), already
  # in the shape its --jq makes: merged-list holds "<branch><TAB><head><TAB><number>" lines.
  "pr list --state merged"*)
    [ -e "$ST/merged-list-fails" ] && { echo "gh: simulated failure" >&2; exit 1; }
    cat "$ST/merged-list" 2>/dev/null
    ;;
  # The pull requests whose head is the branch this one is based on, its base pull request
  # (claude-config#3118): base-prs holds GitHub's answer, none when unset.
  "pr list --repo acme/widget --head "*)
    fail_read base-prs
    if [ -s "$ST/base-prs" ]; then cat "$ST/base-prs"; else printf '[]\n'; fi
    ;;
  "pr list"*)
    fail_read list
    jq -nc --rawfile s "$ST/stacked" '[$s | split("\n")[] | select(. != "") | {number: tonumber}]'
    ;;
  "api -X PATCH repos/acme/widget/pulls/"*)
    n="$(printf '%s\n' "$*" | sed -nE 's#.*pulls/([0-9]+).*#\1#p')"
    b="$(printf '%s\n' "$*" | sed -nE 's#.* base=([^ ]+).*#\1#p')"
    [ -e "$ST/retarget-fails-$n" ] && { echo "gh: Validation Failed (HTTP 422)" >&2; exit 1; }
    # retarget-already-<n>: GitHub has moved the pull request onto the base itself, after the list
    # was read, and answers the move as it did for #2419 and #2405 on 2026-11-07
    # (claude-config#2431). retarget-exists-<n>: the same answer, with the pull request not moved.
    if [ -e "$ST/retarget-already-$n" ] || [ -e "$ST/retarget-exists-$n" ]; then
      if [ -e "$ST/retarget-already-$n" ]; then
        { grep -vx "$n" "$ST/stacked" || true; } > "$ST/stacked.tmp"; mv "$ST/stacked.tmp" "$ST/stacked"
      fi
      printf '{"message":"Validation Failed","errors":[{"resource":"PullRequest","code":"custom","message":"A pull request already exists for base branch %s and head branch feat/y-%s"}],"status":"422"}\n' "$b" "$n"
      echo "gh: Validation Failed (HTTP 422)" >&2; exit 1
    fi
    # retarget-ignored-<n>: GitHub answers as if it moved the pull request, and it did not.
    if [ ! -e "$ST/retarget-ignored-$n" ]; then
      { grep -vx "$n" "$ST/stacked" || true; } > "$ST/stacked.tmp"; mv "$ST/stacked.tmp" "$ST/stacked"
      printf '%s %s\n' "$n" "$b" >> "$ST/retargeted"
    fi
    printf '{"number":%s,"base":{"ref":"%s"}}\n' "$n" "$b"
    ;;
  # One stacked pull request read on its own (claude-config#2431): based on feat/x while stacked
  # lists it, and on main once it has been moved.
  "api repos/acme/widget/pulls/"*)
    fail_read pull
    n="$(printf '%s\n' "$*" | sed -nE 's#.*pulls/([0-9]+).*#\1#p')"
    b=main; grep -qx "$n" "$ST/stacked" 2>/dev/null && b=feat/x
    printf '{"number":%s,"base":{"ref":"%s"}}\n' "$n" "$b"
    ;;
  "api -X DELETE repos/acme/widget/git/refs/heads/feat/x"*)
    [ -s "$ST/delete-fails" ] && { cat "$ST/delete-fails" >&2; exit 1; }
    gone
    ;;
  # What a bypass merge is decided from (claude-config#3534). rules holds the rules in force on the
  # base branch as GitHub lists them, none when unset, and on-rules-read is a step run once when they
  # are read. ruleset-<id> holds one ruleset as GitHub answers it, a 404 when unset, and
  # ruleset-asked records which account asked, since the answer is about the account asking.
  "api repos/acme/widget/rules/branches/main"*)
    fail_read rules
    if [ -s "$ST/on-rules-read" ]; then s="$(cat "$ST/on-rules-read")"; : > "$ST/on-rules-read"; eval "$s"; fi
    if [ -s "$ST/rules" ]; then cat "$ST/rules"; else echo '[]'; fi
    ;;
  "api repos/acme/widget/rulesets/"*)
    printf '%s\n' "$(who)" >> "$ST/ruleset-asked"
    fail_read ruleset
    id="$(printf '%s\n' "$*" | sed -nE 's#.*rulesets/([0-9]+).*#\1#p')"
    [ -s "$ST/ruleset-$id" ] && { cat "$ST/ruleset-$id"; exit 0; }
    echo '{"message":"Not Found","status":"404"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1
    ;;
  # The base branch's classic protection, which GitHub shows only to an account that administers
  # the repository: classic holds it, classic-hidden answers as GitHub answers any other account,
  # and with neither the branch has none, in GitHub's own words (both measured 2026-11-24).
  "api repos/acme/widget/branches/main/protection"*)
    fail_read classic
    [ -s "$ST/classic" ] && { cat "$ST/classic"; exit 0; }
    if [ -e "$ST/classic-hidden" ]; then echo '{"message":"Not Found","status":"404"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    echo '{"message":"Branch not protected","status":"404"}'; echo "gh: Branch not protected (HTTP 404)" >&2; exit 1
    ;;
  # The base branch as GitHub shows it to anyone who can read the repository: branch-summary holds
  # it, and with none it is a branch that rulesets protect and classic protection does not.
  "api repos/acme/widget/branches/main"*)
    fail_read branch
    if [ -s "$ST/branch-summary" ]; then cat "$ST/branch-summary"
    else echo '{"name":"main","protected":true,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}}'; fi
    ;;
  "api repos/acme/widget/compare/"*)
    fail_read compare
    b="$(rd behind)"; st=ahead; [ "$b" != 0 ] && st=diverged
    # base_commit is the base branch's tip, as GitHub's compare reports it (claude-config#1271);
    # main-tip moves when a test makes main move.
    mt="$(rd main-tip)"
    printf '{"status":"%s","ahead_by":1,"behind_by":%s,"base_commit":{"sha":"%s"}}\n' "$st" "$b" "${mt:-aaaaaaa}"
    ;;
  # The repository's recent successful pull request runs, read for how long its checks take before a
  # turn is taken (claude-config#1604): recent-runs holds GitHub's answer, and with none there are none.
  "api repos/acme/widget/actions/runs?status=success"*)
    printf '%s\n' "$(rd clock)" >> "$ST/recent-runs-times"
    fail_read recent-runs
    if [ -s "$ST/recent-runs" ]; then cat "$ST/recent-runs"; else printf '%s\n' '{"total_count":0,"workflow_runs":[]}'; fi
    ;;
  # The jobs of one workflow run (claude-config#2537): jobs-<id> holds how many it has, one when
  # unset, so a run no test set up is a run that started.
  "api repos/acme/widget/actions/runs/"*"/jobs"*)
    fail_read jobs
    id="$(printf '%s\n' "$*" | sed -nE 's#.*actions/runs/([0-9]+)/jobs.*#\1#p')"
    # jobsjson-<id> holds GitHub's whole answer, a recorded one, for the runner queue (#2714).
    if [ -s "$ST/jobsjson-$id" ]; then cat "$ST/jobsjson-$id"; exit 0; fi
    n="$(rd "jobs-$id")"
    printf '{"total_count":%s,"jobs":[]}\n' "${n:-1}"
    ;;
  # A job's log (claude-config#3312): joblog-<id> holds it, empty when unset, and joblog-fails makes
  # a read fail.
  "api repos/acme/widget/actions/jobs/"*"/logs"*)
    fail_read joblog
    id="$(printf '%s\n' "$*" | sed -nE 's#.*actions/jobs/([0-9]+)/logs.*#\1#p')"
    [ ! -f "$ST/joblog-$id" ] || cat "$ST/joblog-$id"
    ;;
  # The artifacts a workflow run uploaded, listed (claude-config#3312): artifactsjson-<run> holds
  # GitHub's answer, none when unset, and runartifacts-fails makes a read fail.
  "api repos/acme/widget/actions/runs/"*"/artifacts"*)
    fail_read runartifacts
    id="$(printf '%s\n' "$*" | sed -nE 's#.*actions/runs/([0-9]+)/artifacts.*#\1#p')"
    if [ -s "$ST/artifactsjson-$id" ]; then cat "$ST/artifactsjson-$id"; else printf '%s\n' '{"total_count":0,"artifacts":[]}'; fi
    ;;
  # The annotations of one check run (claude-config#3312): annotations-<id> holds GitHub's answer,
  # none when unset, and annotations-fails makes a read fail.
  "api repos/acme/widget/check-runs/"*"/annotations"*)
    fail_read annotations
    id="$(printf '%s\n' "$*" | sed -nE 's#.*check-runs/([0-9]+)/annotations.*#\1#p')"
    if [ -s "$ST/annotations-$id" ]; then cat "$ST/annotations-$id"; else echo '[]'; fi
    ;;
  # Whether the head's tree holds the tool that says what the checks did not test (claude-config#3312):
  # has-untested-tool makes it there, and otherwise GitHub answers 404, as it does for any repository
  # without it. contents-fails makes the read fail.
  "api repos/acme/widget/contents/"*)
    fail_read contents
    if [ -e "$ST/has-untested-tool" ]; then printf '%s\n' 'tools/ci-unmeasured-summary.sh'; exit 0; fi
    printf '%s\n' '{"message":"Not Found","status":"404"}'
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  # A workflow run's artifacts fetched (claude-config#3312): artifacts-<run> is a folder holding one
  # folder per artifact, copied into --dir as gh lays them out. With none, gh's answer for a run whose
  # artifacts have expired.
  "run download"*)
    fail_read download
    id="$(printf '%s\n' "$*" | awk '{ print $3 }')"
    dir="$(printf '%s\n' "$*" | sed -nE 's/.*--dir ([^ ]+).*/\1/p')"
    [ -d "$ST/artifacts-$id" ] || { echo "no valid artifacts found to download" >&2; exit 1; }
    mkdir -p "$dir" && cp -R "$ST/artifacts-$id"/. "$dir"/ ;;
  # A workflow run started again (claude-config#2537): on-rerun is a step run once when it is.
  "run rerun"*)
    fail_read rerun
    if [ -s "$ST/on-rerun" ]; then s="$(cat "$ST/on-rerun")"; : > "$ST/on-rerun"; eval "$s"; fi
    ;;
  # The repository's runs created in a window, read to count the jobs running while one waited for a
  # runner (claude-config#2714): pool-runs holds GitHub's answer.
  "api repos/acme/widget/actions/runs?created="*)
    fail_read pool-runs
    if [ -s "$ST/pool-runs" ]; then cat "$ST/pool-runs"; else printf '%s\n' '{"total_count":0,"workflow_runs":[]}'; fi
    ;;
  "api repos/acme/widget/actions/runs"*)
    # The workflow runs GitHub has created for the head (claude-config#1087): none unless a test
    # writes some to runs, the shape a repository whose runs have all finished answers with too.
    fail_read runs
    if [ -s "$ST/runs" ]; then cat "$ST/runs"; else printf '%s\n' '{"total_count":0,"workflow_runs":[]}'; fi
    ;;
  # The repository's settings, for the merge methods it allows (claude-config#1476): methods holds the
  # JSON GitHub answers with, all three allowed when unset, as PET and claude-config answered on
  # 2026-10-22.
  "api repos/acme/widget")
    fail_read repo
    if [ -s "$ST/methods" ]; then cat "$ST/methods"; echo
    else printf '%s\n' '{"full_name":"acme/widget","allow_squash_merge":true,"allow_merge_commit":true,"allow_rebase_merge":true}'; fi
    ;;
  "pr update-branch"*)
    [ -e "$ST/update-fails" ] && { echo "GraphQL: merge conflict between base and head (updatePullRequestBranch)" >&2; exit 1; }
    # update-limited: GitHub refuses this one update for its rate limit, updating nothing (#1482).
    [ -e "$ST/update-limited" ] && { rm -f "$ST/update-limited"; echo "gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)" >&2; exit 1; }
    printf '%s\n' "$(rd clock)" >> "$ST/update-times"
    # update-unseen: GitHub accepts the update, but its record of the pull request never shows it
    # (claude-config#1500, PET #1885 on 2026-10-22): the head and the distance behind stay as they
    # were. With branch-moves the branch itself moves to the next head, as PET's did, and without it
    # the branch does not move either.
    if [ -e "$ST/update-unseen" ]; then
      if [ -e "$ST/branch-moves" ]; then
        nh="$(head -1 "$ST/next-heads")"; tail -n +2 "$ST/next-heads" > "$ST/next-heads.tmp"; mv "$ST/next-heads.tmp" "$ST/next-heads"
        printf '%s' "$nh" > "$ST/branch-tip"
      fi
      exit 0
    fi
    nh="$(head -1 "$ST/next-heads")"; tail -n +2 "$ST/next-heads" > "$ST/next-heads.tmp"; mv "$ST/next-heads.tmp" "$ST/next-heads"
    printf '%s' "$nh" > "$ST/head"; printf '0' > "$ST/behind"; cat "$ST/rollup-after-update" > "$ST/rollup"
    ;;
  "pr merge"*)
    # gh refuses a merge naming no method when nothing can ask which (claude-config#1476).
    case " $* " in *" --squash "*|*" -s "*|*" --merge "*|*" -m "*|*" --rebase "*|*" -r "*) ;;
      *) echo "--merge, --rebase, or --squash required when not running interactively" >&2; exit 1 ;;
    esac
    # policy-blocks: the base branch's rules leave the pull request BLOCKED, for a review it does
    # not have, and gh refuses that itself, before it asks GitHub to merge anything, unless --admin
    # is passed (claude-config#3534). gh 2.88's own words, with the repository's name invented.
    admin=""; case " $* " in *" --admin "*) admin=1 ;; esac
    if [ -e "$ST/policy-blocks" ] && [ -z "$admin" ]; then
      printf '%s\n' 'X Pull request acme/widget#7 is not mergeable: the base branch policy prohibits the merge.' 'To have the pull request merged after all the requirements have been met, add the `--auto` flag.' 'To use administrator privileges to immediately merge the pull request, add the `--admin` flag.' >&2
      exit 1
    fi
    printf '%s\n' "$(rd clock)" >> "$ST/merge-times"
    # The account the merge is made as, refused as GitHub refuses one that can only read or triage
    # (claude-config#2629, seen 2026-11-10).
    w="$(who)"; printf '%s\n' "$w" >> "$ST/merge-as"
    case "$(rd "perm-$w")" in
      READ|TRIAGE) printf 'GraphQL: %s does not have the correct permissions to execute `MergePullRequest` (mergePullRequest)\n' "$w" >&2; exit 1 ;;
    esac
    # merge-fails holds one error per line, each spent by one merge that merges nothing, as GitHub's
    # "Something went wrong" did on 2026-11-05 (claude-config#2289).
    if [ -z "$admin" ] && e="$(pop merge-fails)"; then printf '%s\n' "$e" >&2; exit 1; fi
    # A merge sent with --admin (claude-config#3534): admin-merge-fails holds one error per line,
    # each spent by one such merge that merges nothing, and bypass-denied holds what GitHub answers
    # every one with, since it refuses a bypass the account may not make whatever gh was passed.
    if [ -n "$admin" ]; then
      if e="$(pop admin-merge-fails)"; then printf '%s\n' "$e" >&2; exit 1; fi
      [ -s "$ST/bypass-denied" ] && { cat "$ST/bypass-denied" >&2; exit 1; }
    fi
    pinned="$(printf '%s\n' "$*" | sed -nE 's/.*--match-head-commit ([0-9a-f]+).*/\1/p')"
    # GitHub refuses to merge a pull request whose head is not its branch's tip, whatever the pin
    # (Bidspoke #2577, claude-config#1458).
    bt="$(rd branch-tip)"
    [ -n "$bt" ] && [ "$bt" != "$(rd head)" ] && { echo "GraphQL: Head branch is out of date. Review and try the merge again. (mergePullRequest)" >&2; exit 1; }
    [ "$pinned" = "$(rd head)" ] || { echo "Head branch was modified. Review and try the merge again." >&2; exit 1; }
    : > "$ST/merged"
    # The branch the merge landed in, the pull request's base at that moment (claude-config#3118).
    br="$(rd base-ref)"; printf '%s\n' "${br:-main}" >> "$ST/merged-into"
    # auto-delete: the repository deletes head branches itself once merged. tip-after-merge: a push
    # lands on the branch just after the merge.
    [ -e "$ST/auto-delete" ] && gone
    [ -s "$ST/tip-after-merge" ] && cp "$ST/tip-after-merge" "$ST/branch-tip"
    # gh pr merge --delete-branch deletes the branch through the API as soon as the merge lands.
    case " $* " in *" --delete-branch "*|*" -d "*) gone ;; esac
    # merge-lands-fails: the merge lands, and gh prints an error anyway (claude-config#2289).
    [ -s "$ST/merge-lands-fails" ] && { cat "$ST/merge-lands-fails" >&2; rm -f "$ST/merge-lands-fails"; exit 1; }
    # A merge that landed with nothing to complain about exits 0, as gh does. Without this the test
    # above was the script's last command, so every merge exited 1 (claude-config#2687).
    exit 0
    ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 3 ;;
esac
EOS
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# --- the injected sleep: runs the next step the test queued, then returns at once -----------------
# It also moves the injected clock on by the seconds asked (claude-config#1271), so a wait for main to
# be still for minutes, and a deadline hours long, are crossed in no real time at all.
# The clock is read with the shell's own read, never a cat that may find no process to run under load,
# and written whole through a rename (claude-config#2327): a read that failed used to write the bare
# seconds asked as the time, and a write cut short left an empty clock, either one a jump of about a
# million seconds for the next read. A clock it cannot read stops it, loudly, with the clock untouched.
# The sleep and the clock are exported shell functions (claude-config#2674): the helper runs whatever
# command MWR_SLEEP and MWR_NOW name, and a function is one, so each read of the clock costs a subshell
# rather than a bash and a cat started for it, and each sleep a subshell rather than a bash. Measured
# on 2026-11-10, a simple merge read the clock 27 times, and the long waits thousands. The sleep runs in a subshell with the
# helper's shell options turned off, as the script it replaces ran, so a step it runs can neither
# change the helper nor be stopped by its set -u. The files remain for the sections that put a sleep
# on the PATH (#2399), and run these same functions. A step that signals the helper names it as
# helper_pid: the shell the subshell belongs to, or the parent of the file that ran it.
mwr_suite_sleep(){ (
  set +e +u; set +o pipefail
  helper_pid="${MWR_SUITE_SLEEP_CALLER:-$$}"
  printf '%s\n' "$1" >> "$ST/sleeps"
  c=""; read -r c < "$ST/clock"
  case "$c" in ''|*[!0-9]*) echo "fake sleep: the injected clock in $ST/clock reads '$c', not a time" >&2; exit 1 ;; esac
  printf '%s' "$(( c + $1 ))" > "$ST/clock.$$" && mv -f "$ST/clock.$$" "$ST/clock"
  if [ -s "$ST/on-sleep" ]; then
    step=""; { IFS= read -r step; cat > "$ST/on-sleep.tmp"; } < "$ST/on-sleep"; mv "$ST/on-sleep.tmp" "$ST/on-sleep"
    eval "$step"
  fi
) }
mwr_suite_now(){ local c=""; read -r c < "$ST/clock"; printf '%s' "$c"; }
export -f mwr_suite_sleep mwr_suite_now
printf '#!/usr/bin/env bash\nMWR_SUITE_SLEEP_CALLER=$PPID mwr_suite_sleep "$@"\n' > "$BIN/fake-sleep"; chmod +x "$BIN/fake-sleep"
printf '#!/usr/bin/env bash\nmwr_suite_now\n' > "$BIN/fake-now"; chmod +x "$BIN/fake-now"
export MWR_SLEEP=mwr_suite_sleep
export MWR_NOW=mwr_suite_now
export MWR_POLL_SECONDS=30
export MWR_READ_RETRY_SECONDS=7
export MWR_NO_CHECKS_GRACE_SECONDS=0
# The shared polling policy (claude-config#1482, lib/gh-poll.sh): every section but 21 runs at a fixed
# pace (no growth, a ceiling under the base is the base) with a cap no section reaches, so each keeps
# measuring what it was written for; section 21 sets each of them itself. Its state is this suite's
# own, in one session of its own, emptied by fresh().
export MWR_POLL_MAX_SECONDS=1
export GH_POLL_PER_MINUTE=1000
export GH_POLL_STATE_DIR="$WORKDIR/gh-poll"
export CLAUDE_CODE_SESSION_ID="mwr-suite"
# The per repository turn (claude-config#1515) is kept here, never in this Mac's own state.
export MWR_TURN_DIR="$WORKDIR/turns"
# And the phase each run publishes for tools/load-window.sh (claude-config#1676), so a run here is
# never read as one of this Mac's helpers.
export MWR_PHASE_DIR="$WORKDIR/phases"
# And the record of refused sign ins (claude-config#1626), so the refusals this suite fakes are never
# counted as this Mac's, on the suite's own clock.
export MT_SIGNIN_LEDGER_DIR="$WORKDIR/gh-signin"
export MT_SIGNIN_CLOCK=mwr_suite_now
# And the record of deliberate load windows (claude-config#1618), so a real window on this Mac never
# adds a sentence to what these sections read.
export LOAD_WINDOW_DIR="$WORKDIR/load-window"
# And the lessons review's state, where the review gate records a read key a typed command presented
# to the helper (claude-config#1673), never this Mac's own.
export AI_REVIEW_STATE_DIR="$WORKDIR/ai-review"

# --- stub gates and review checker: log the payload or arguments, answer from files ---------------
# The stubs are files of their own in merge-when-ready-fixtures/stub-gates, copied in here: a
# script under hooks/ or hooks/lib/ that prints a hook's answer is judged as a hook by
# lib/hook-output.py, and these are not hooks (claude-config#3572).
STUBS="$WORKDIR/stubs"; mkdir -p "$STUBS"
cp "$DIR/merge-when-ready-fixtures/stub-gates/"*.sh "$STUBS/"
chmod +x "$STUBS"/*.sh
export MWR_RED_GATE="$STUBS/red-gate.sh" MWR_REVIEW_GATE="$STUBS/review-gate.sh" MWR_REVIEW_LIB="$STUBS/pr-review.sh"
export MWR_CHANGELOG_GATE="$STUBS/changelog-gate.sh" MWR_DESIGN_GATE="$STUBS/design-gate.sh"
export MWR_VERIFY_GATE="$STUBS/verify-gate.sh" MWR_CLOSING_GATE="$STUBS/closing-gate.sh"
export MWR_WORK_NAMES_GATE="$STUBS/work-names-gate.sh"
# The helper honours MWR_WORK_NAMES_GATE only under HOOK_TESTS_RUNNING=1, the marker run-all-tests.sh
# exports to every suite (claude-config#2231); exported here too, so this suite run on its own behaves
# as it does inside a full run.
export HOOK_TESTS_RUNNING=1

# --- git with no network and no Mac's own settings ------------------------------------------------
# A conflicted update is now merged locally when only README.md's mods table rows conflict
# (claude-config#1867), and that fetches from the checkout's origin. Every GitHub address is pointed
# at a folder that does not exist, so a section that reaches it fails at once rather than going to
# the network, and section 27 points acme/widget at a local bare repository of its own.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$WORKDIR/gitconfig"
printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n[url "%s/offline/"]\n\tinsteadOf = https://github.com/\n' "$WORKDIR" > "$GIT_CONFIG_GLOBAL"

# --- a checkout of acme/widget to run from ---------------------------------------------------------
REPO="$(cd "$WORKDIR" && pwd -P)/widget"
git init -q "$REPO"
git -C "$REPO" remote add origin https://github.com/acme/widget.git

fresh(){ # fresh <head> <behind> <rollup>
  rm -rf "$ST" "$GH_POLL_STATE_DIR" "$MWR_TURN_DIR" "$AI_REVIEW_STATE_DIR" "$MWR_PHASE_DIR"; mkdir -p "$ST"
  printf '%s' "$1" > "$ST/head"; printf '%s' "$2" > "$ST/behind"; printf '%s' "$3" > "$ST/rollup"
  printf '%s' "$PENDING" > "$ST/rollup-after-update"
  : > "$ST/next-heads"; : > "$ST/on-sleep"; : > "$ST/stacked"
  printf '1000000' > "$ST/clock"; printf 'm0' > "$ST/main-tip"
}
run(){ (cd "$REPO" && bash "$HELPER" "$@" 2>&1); }
# What Claude Code does before a Bash call runs: the REAL lessons review gate reads the command as
# typed (claude-config#1673). Prints what it said; exits as it did.
present(){ jq -nc --arg c "$1" --arg d "$REPO" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | bash "$DIR/pr-review-gate.sh" 2>&1; }
count(){ if [ -f "$ST/$1" ]; then grep -c -- "$2" "$ST/$1"; else echo 0; fi; }

# GitHub's own words for two answers both suites give the helper: its "Something went wrong" to a
# merge (claude-config#2289, section 8) and its rate limit refusal (claude-config#1482, section 21).
WRONG='GraphQL: Something went wrong while executing your query. This may be the result of a timeout, or it could be a GitHub bug. Please include `AB12:3C4D:5E6F` when reporting this issue.'
LIMITED="gh: API rate limit exceeded for user ID 241846707. (HTTP 403)"
}
