#!/usr/bin/env bash
# Tests for lib/merge-when-ready.sh (claude-config#851): a pull request sent back for being behind its
# base is updated, waited on and merged in one step, and only ever through the same gates a typed
# merge meets.
#
# A fake gh holds the pull request's state in files (head, checks, distance behind, merged), and
# moves it the way GitHub does: `pr update-branch` gives the pull request a NEW head with its checks
# pending. The sleep is injected, and each fake sleep runs a step the test chose (checks go green,
# main moves again), so nothing here waits on a clock (L524, L290). The three gates and the review
# checker are stubs that log what they were asked and answer from files, except in section 6, where
# the REAL block-red-merge.sh judges, so the helper's reading of a real refusal is proved (L52).
# Nothing reaches the network or a real pull request (L2).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$DIR/lib/merge-when-ready.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:2000}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then ok; else bad "$1"; echo "  must not contain: $2"; echo "  actual: ${3:0:2000}"; fi; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }

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
case "$*" in
  "auth status"*) exit 0 ;;
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
    jq -nc --arg h "$(rd head)" --arg s "$state" --arg ms "$ms" --argjson r "$(rd rollup)" --argjson l "${lb:-[]}" --argjson x "${cx:-false}" --arg fo "${fo:-acme}" \
      '{number:7,state:$s,headRefOid:$h,headRefName:"feat/x",baseRefName:"main",isCrossRepository:$x,headRepositoryOwner:{login:$fo},headRepository:{name:"widget"},statusCheckRollup:$r,mergeStateStatus:$ms,mergeable:"MERGEABLE",url:"https://github.com/acme/widget/pull/7",author:{login:"dwright-pennie"},labels:$l,body:""}'
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
  "pr list"*)
    fail_read list
    jq -nc --rawfile s "$ST/stacked" '[$s | split("\n")[] | select(. != "") | {number: tonumber}]'
    ;;
  "api -X PATCH repos/acme/widget/pulls/"*)
    n="$(printf '%s\n' "$*" | sed -nE 's#.*pulls/([0-9]+).*#\1#p')"
    b="$(printf '%s\n' "$*" | sed -nE 's#.* base=([^ ]+).*#\1#p')"
    [ -e "$ST/retarget-fails-$n" ] && { echo "gh: Validation Failed (HTTP 422)" >&2; exit 1; }
    # retarget-ignored-<n>: GitHub answers as if it moved the pull request, and it did not.
    if [ ! -e "$ST/retarget-ignored-$n" ]; then
      { grep -vx "$n" "$ST/stacked" || true; } > "$ST/stacked.tmp"; mv "$ST/stacked.tmp" "$ST/stacked"
      printf '%s %s\n' "$n" "$b" >> "$ST/retargeted"
    fi
    printf '{"number":%s,"base":{"ref":"%s"}}\n' "$n" "$b"
    ;;
  "api -X DELETE repos/acme/widget/git/refs/heads/feat/x"*)
    [ -s "$ST/delete-fails" ] && { cat "$ST/delete-fails" >&2; exit 1; }
    gone
    ;;
  "api repos/acme/widget/compare/"*)
    fail_read compare
    b="$(rd behind)"; st=ahead; [ "$b" != 0 ] && st=diverged
    # base_commit is the base branch's tip, as GitHub's compare reports it (claude-config#1271);
    # main-tip moves when a test makes main move.
    mt="$(rd main-tip)"
    printf '{"status":"%s","ahead_by":1,"behind_by":%s,"base_commit":{"sha":"%s"}}\n' "$st" "$b" "${mt:-aaaaaaa}"
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
    pinned="$(printf '%s\n' "$*" | sed -nE 's/.*--match-head-commit ([0-9a-f]+).*/\1/p')"
    # GitHub refuses to merge a pull request whose head is not its branch's tip, whatever the pin
    # (Bidspoke #2577, claude-config#1458).
    bt="$(rd branch-tip)"
    [ -n "$bt" ] && [ "$bt" != "$(rd head)" ] && { echo "GraphQL: Head branch is out of date. Review and try the merge again. (mergePullRequest)" >&2; exit 1; }
    [ "$pinned" = "$(rd head)" ] || { echo "Head branch was modified. Review and try the merge again." >&2; exit 1; }
    : > "$ST/merged"
    # auto-delete: the repository deletes head branches itself once merged. tip-after-merge: a push
    # lands on the branch just after the merge.
    [ -e "$ST/auto-delete" ] && gone
    [ -s "$ST/tip-after-merge" ] && cp "$ST/tip-after-merge" "$ST/branch-tip"
    # gh pr merge --delete-branch deletes the branch through the API as soon as the merge lands.
    case " $* " in *" --delete-branch "*|*" -d "*) gone ;; esac
    ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 3 ;;
esac
EOS
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# --- the injected sleep: runs the next step the test queued, then returns at once -----------------
# It also moves the injected clock on by the seconds asked (claude-config#1271), so a wait for main to
# be still for minutes, and a deadline hours long, are crossed in no real time at all.
cat > "$BIN/fake-sleep" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$ST/sleeps"
printf '%s' "$(( $(cat "$ST/clock") + $1 ))" > "$ST/clock"
if [ -s "$ST/on-sleep" ]; then
  step="$(head -1 "$ST/on-sleep")"; tail -n +2 "$ST/on-sleep" > "$ST/on-sleep.tmp"; mv "$ST/on-sleep.tmp" "$ST/on-sleep"
  eval "$step"
fi
EOS
chmod +x "$BIN/fake-sleep"
export MWR_SLEEP="$BIN/fake-sleep"
printf '#!/usr/bin/env bash\ncat "$ST/clock"\n' > "$BIN/fake-now"; chmod +x "$BIN/fake-now"
export MWR_NOW="$BIN/fake-now"
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

# --- stub gates and review checker: log the payload or arguments, answer from files ---------------
STUBS="$WORKDIR/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/red-gate.sh" <<'EOS'
#!/usr/bin/env bash
cat >> "$ST/red-gate-payloads"; printf '\n' >> "$ST/red-gate-payloads"
[ -s "$ST/red-gate-deny" ] && jq -nc --arg r "$(cat "$ST/red-gate-deny")" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
EOS
cat > "$STUBS/review-gate.sh" <<'EOS'
#!/usr/bin/env bash
cat >> "$ST/review-gate-payloads"; printf '\n' >> "$ST/review-gate-payloads"
[ -s "$ST/review-gate-refuse" ] && { cat "$ST/review-gate-refuse" >&2; exit 2; }
exit 0
EOS
cat > "$STUBS/pr-review.sh" <<'EOS'
#!/usr/bin/env bash
printf '%s PR_REVIEW_READ=%s\n' "$*" "${PR_REVIEW_READ:-}" >> "$ST/review-calls"
case "$1" in
  start) echo "The lessons review started."; exit 0 ;;
  check)
    # on-review: a step run once, while the review is asked, the last thing before the merge's gates.
    if [ -s "$ST/on-review" ]; then s="$(cat "$ST/on-review")"; : > "$ST/on-review"; eval "$s"; fi
    if [ -s "$ST/review-answers" ]; then
      rc="$(head -1 "$ST/review-answers")"; tail -n +2 "$ST/review-answers" > "$ST/review-answers.tmp"; mv "$ST/review-answers.tmp" "$ST/review-answers"
    else rc=0; fi
    case "$rc" in
      0) echo "The lessons review finished with 0 findings." ;;
      3) echo "Refusing to merge yet: the lessons review is still running (1m of 10m)." ;;
      1) printf 'Refusing to merge until these are read: 1 finding.\n    PR_REVIEW_READ=abc123 <the merge command>\nApp/x.swift:3: swallows the error (L215).\n' ;;
    esac
    exit "$rc" ;;
esac
EOS
cat > "$STUBS/changelog-gate.sh" <<'EOS'
#!/usr/bin/env bash
cat >> "$ST/changelog-gate-payloads"; printf '\n' >> "$ST/changelog-gate-payloads"
[ -s "$ST/changelog-gate-deny" ] && jq -nc --arg r "$(cat "$ST/changelog-gate-deny")" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
EOS
cat > "$STUBS/design-gate.sh" <<'EOS'
#!/usr/bin/env bash
cat >> "$ST/design-gate-payloads"; printf '\n' >> "$ST/design-gate-payloads"
[ -s "$ST/design-gate-deny" ] && jq -nc --arg r "$(cat "$ST/design-gate-deny")" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
EOS
cat > "$STUBS/verify-gate.sh" <<'EOS'
#!/usr/bin/env bash
cat >> "$ST/verify-gate-payloads"; printf '\n' >> "$ST/verify-gate-payloads"
if [ -s "$ST/verify-gate-deny" ]; then
  jq -nc --arg r "$(cat "$ST/verify-gate-deny")" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
elif [ -s "$ST/verify-gate-context" ]; then
  jq -nc --arg c "$(cat "$ST/verify-gate-context")" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
fi
exit 0
EOS
chmod +x "$STUBS"/*.sh
export MWR_RED_GATE="$STUBS/red-gate.sh" MWR_REVIEW_GATE="$STUBS/review-gate.sh" MWR_REVIEW_LIB="$STUBS/pr-review.sh"
export MWR_CHANGELOG_GATE="$STUBS/changelog-gate.sh" MWR_DESIGN_GATE="$STUBS/design-gate.sh"
export MWR_VERIFY_GATE="$STUBS/verify-gate.sh"

# --- a checkout of acme/widget to run from ---------------------------------------------------------
REPO="$(cd "$WORKDIR" && pwd -P)/widget"
git init -q "$REPO"
git -C "$REPO" remote add origin https://github.com/acme/widget.git

fresh(){ # fresh <head> <behind> <rollup>
  rm -rf "$ST" "$GH_POLL_STATE_DIR" "$MWR_TURN_DIR"; mkdir -p "$ST"
  printf '%s' "$1" > "$ST/head"; printf '%s' "$2" > "$ST/behind"; printf '%s' "$3" > "$ST/rollup"
  printf '%s' "$PENDING" > "$ST/rollup-after-update"
  : > "$ST/next-heads"; : > "$ST/on-sleep"; : > "$ST/stacked"
  printf '1000000' > "$ST/clock"; printf 'm0' > "$ST/main-tip"
}
run(){ (cd "$REPO" && bash "$HELPER" "$@" 2>&1); }
count(){ if [ -f "$ST/$1" ]; then grep -c -- "$2" "$ST/$1"; else echo 0; fi; }

# =================================================================================================
# 1. Refuses what it was not built to carry, before it touches anything (no weakening, L448).
# =================================================================================================
fresh "$OLD" 0 "$GREEN"
for bad_args in "7 --admin" "7 --auto --squash" "7 --squash --match-head-commit $OLD" "7 --body ALLOW_RED_MERGE=1" "7 --squash --repo acme/widget;rm"; do
  # shellcheck disable=SC2086
  out="$(run $bad_args)"; rc=$?
  check_eq "#851 refuses arguments it does not carry: $bad_args" "64" "$rc"
  check_eq "#851 and makes no call to GitHub for them: $bad_args" "" "$(cat "$ST/gh-calls" 2>/dev/null)"
done
out="$(run --squash)"; rc=$?
check_eq "#851 refuses with no pull request number" "64" "$rc"
out="$(cd "$WORKDIR" && bash "$HELPER" 7 --squash 2>&1)"; rc=$?
check_eq "#851 refuses outside a checkout, where no review can be run" "64" "$rc"

# =================================================================================================
# 2. Already up to date, green and reviewed: merged at once, pinned, through both gates.
# =================================================================================================
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --repo acme/widget --squash --delete-branch)"; rc=$?
check_eq "#851 an up to date green pull request merges" "0" "$rc"
check "#851 and says it merged that head" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_eq "#851 the branch is not updated when it is not behind" "0" "$(count gh-calls 'pr update-branch')"
check_eq "#851 exactly one merge" "1" "$(count gh-calls 'pr merge')"
check "#851 the merge pins the head it judged" "pr merge 7 --repo acme/widget --squash --match-head-commit $OLD" "$(cat "$ST/gh-calls")"
check "#851 the checks gate is asked about that exact merge command" "gh pr merge 7 --repo acme/widget --squash --match-head-commit $OLD" "$(cat "$ST/red-gate-payloads")"
check "#851 and so is the lessons review gate" "gh pr merge 7 --repo acme/widget --squash --match-head-commit $OLD" "$(cat "$ST/review-gate-payloads")"
check "#851 the review is asked about the pull request's head, base and branch" "check --dir $REPO --sha $OLD --base-ref origin/main --branch feat/x" "$(cat "$ST/review-calls")"
check "#1161 and is started naming the pull request, whose comments it reads" "start --dir $REPO --sha $OLD --base-ref origin/main --branch feat/x --pr 7" "$(cat "$ST/review-calls")"
# A review that allows says what it found, once: since #1338 an allow can carry findings that repeat
# ones already answered, shown as answered, and the helper is where the session reads them.
check "#1338 the review's verdict is shown when it allows" "The lessons review finished with 0 findings." "$out"
check_eq "#1338 once, however often it is asked" "1" "$(grep -c 'The lessons review finished with 0 findings.' <<<"$out")"

# =================================================================================================
# 3. Behind: updated, then the NEW head's checks and review are waited for, and that head merged.
# =================================================================================================
fresh "$OLD" 4 "$GREEN"
printf '%s\n' "$NEW" > "$ST/next-heads"
# The first sleep follows the update, when the new head's checks have only just started.
printf '%s\n%s\n' ":" "printf '%s' '$GREEN' > \"\$ST/rollup\"" > "$ST/on-sleep"
printf '3\n0\n' > "$ST/review-answers"
out="$(run 7 --squash)"; rc=$?
check_eq "#851 a pull request behind main is updated and merged" "0" "$rc"
check_eq "#851 the branch was updated once" "1" "$(count gh-calls 'pr update-branch 7')"
check "#851 it says why it updated, with the distance" "4 commits behind main" "$out"
check "#851 the merge is pinned to the UPDATED head, never the one sent back" "--match-head-commit $NEW" "$(grep 'pr merge' "$ST/gh-calls")"
check_not "#851 the old head is never merged" "--match-head-commit $OLD" "$(grep 'pr merge' "$ST/gh-calls" || true)"
check "#851 the new head's review was started at once, in parallel with its checks" "start --dir $REPO --sha $NEW" "$(cat "$ST/review-calls")"
check "#851 it waited while the new head's checks ran" "checks still running" "$out"
check "#851 and while its lessons review ran" "lessons review still running" "$out"
check "#851 every wait line carries the elapsed time" "merge-when-ready: [" "$out"
[ "$(count sleeps 30)" -ge 2 ] && ok || bad "#851 it slept through the injected sleep while waiting ($(count sleeps 30))"

# =================================================================================================
# 4. Main moves again while the new head is being checked: updated again. There is no count of
#    updates since #1271; the deadline bounds the run, and section 11 proves both.
# =================================================================================================
fresh "$OLD" 2 "$GREEN"
printf '%s\n%s\n' "$NEW" "$NEWER" > "$ST/next-heads"
printf '%s\n%s\n' "printf '%s' '$GREEN' > \"\$ST/rollup\"; printf 3 > \"\$ST/behind\"" "printf '%s' '$GREEN' > \"\$ST/rollup\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#851 main moving again means a second update, then the merge" "0" "$rc"
check_eq "#851 two updates" "2" "$(count gh-calls 'pr update-branch 7')"
check "#851 merging the newest head" "--match-head-commit $NEWER" "$(grep 'pr merge' "$ST/gh-calls")"


# =================================================================================================
# 5. Every way it stops without merging, each in its own words.
# =================================================================================================
fresh "$OLD" 0 "$GREEN"
printf 'PR #7 is not green: tests=FAILURE.' > "$ST/red-gate-deny"
out="$(run 7 --squash)"; rc=$?
check_eq "#851 a refusal from the checks gate stops it" "1" "$rc"
check "#851 carrying the gate's own reason" "tests=FAILURE" "$out"
check_eq "#851 and nothing is merged past it" "0" "$(count gh-calls 'pr merge')"

fresh "$OLD" 0 "$GREEN"
printf 'Refusing to merge: the lessons review could not run.' > "$ST/review-gate-refuse"
out="$(run 7 --squash)"; rc=$?
check_eq "#851 a refusal from the lessons review gate stops it" "1" "$rc"
check "#851 carrying that gate's reason" "could not run" "$out"
check_eq "#851 and nothing is merged past it either" "0" "$(count gh-calls 'pr merge')"

fresh "$OLD" 0 "$GREEN"
printf '1\n' > "$ST/review-answers"
out="$(run 7 --squash)"; rc=$?
check_eq "#851 findings to read stop it: only the session can read them" "1" "$rc"
check "#851 showing the findings" "swallows the error" "$out"
check "#851 and how to come back with their key" "PR_REVIEW_READ=<key> bash ~/.claude/hooks/lib/merge-when-ready.sh 7" "$out"
check_eq "#851 nothing merged with findings unread" "0" "$(count gh-calls 'pr merge')"

fresh "$OLD" 0 "$GREEN"
out="$(PR_REVIEW_READ=abc123 run 7 --squash)"; rc=$?
check_eq "#851 with the read key it merges" "0" "$rc"
check "#851 the key reaches the review checker" "PR_REVIEW_READ=abc123" "$(grep '^check' "$ST/review-calls")"
check "#851 and stands in front of the merge the review gate judges" "PR_REVIEW_READ=abc123 gh pr merge 7" "$(cat "$ST/review-gate-payloads")"
fresh "$OLD" 0 "$GREEN"
out="$(PR_REVIEW_READ='abc; rm -rf x' run 7 --squash)"; rc=$?
check_eq "#851 a key that is not a key is refused" "64" "$rc"

fresh "$OLD" 3 "$GREEN"
: > "$ST/update-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#851 an update GitHub refuses stops it" "1" "$rc"
check "#851 with GitHub's reason" "merge conflict" "$out"

fresh "$OLD" 0 "$PENDING"
out="$(MWR_DEADLINE_SECONDS=0 run 7 --squash)"; rc=$?
check_eq "#851 out of time while still waiting is its own exit" "3" "$rc"
check "#851 saying what it was still waiting for" "checks still running" "$out"
check_eq "#851 and nothing merged" "0" "$(count gh-calls 'pr merge')"

fresh "$OLD" 0 "$PENDING"
out="$(MWR_MAX_POLLS=2 run 7 --squash)"; rc=$?
check_eq "#851 the wait is bounded by a count too, not only the clock (L704)" "3" "$rc"

fresh "$OLD" 0 "$GREEN"
: > "$ST/merged"
out="$(run 7 --squash)"; rc=$?
check_eq "#851 a pull request already merged is reported, not merged again" "0" "$rc"
check "#851 saying it was already merged" "already merged" "$out"
check_eq "#851 with no second merge" "0" "$(count gh-calls 'pr merge')"

# The merge itself refused because the head moved in the last second: it goes round again.
fresh "$OLD" 0 "$GREEN"
cat > "$STUBS/review-gate.sh" <<'EOS'
#!/usr/bin/env bash
cat >> "$ST/review-gate-payloads"; printf '\n' >> "$ST/review-gate-payloads"
# A push lands between the gates and the merge, once.
[ -e "$ST/pushed" ] || { : > "$ST/pushed"; printf '%s' "$NEWHEAD" > "$ST/head"; }
exit 0
EOS
out="$(NEWHEAD="$NEW" run 7 --squash)"; rc=$?
check_eq "#851 a head that moves under the merge is judged again, then merged" "0" "$rc"
check "#851 the first attempt was refused by GitHub's pin" "--match-head-commit $OLD" "$(grep 'pr merge' "$ST/gh-calls" | sed -n 1p)"
check "#851 and the merge that landed is the new head's" "--match-head-commit $NEW" "$(grep 'pr merge' "$ST/gh-calls" | tail -1)"
cat > "$STUBS/review-gate.sh" <<'EOS'
#!/usr/bin/env bash
cat >> "$ST/review-gate-payloads"; printf '\n' >> "$ST/review-gate-payloads"
exit 0
EOS

# =================================================================================================
# 6. The REAL checks gate decides: a red pull request is not merged, in the gate's own words (L52).
# =================================================================================================
fresh "$OLD" 0 "$RED"
out="$(MWR_RED_GATE="$DIR/block-red-merge.sh" run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#851 the real block-red-merge.sh refuses a red pull request through the helper" "1" "$rc"
check "#851 its reason is shown" "not green" "$out"
check_eq "#851 and nothing is merged" "0" "$(count gh-calls 'pr merge')"
fresh "$OLD" 0 "$GREEN"
out="$(MWR_RED_GATE="$DIR/block-red-merge.sh" run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#851 the real gate lets a green, up to date, pinned merge through the helper" "0" "$rc"

# The gate's behind refusal naming this helper is asserted on the real refusal, in
# test-block-red-merge.sh, rather than by reading its source here (L135).

# =================================================================================================
# 7. Its default pace (claude-config#1014). Every look reads the pull request through GitHub's
#    GraphQL allowance, which every session on the Mac shares, so with no MWR_POLL_SECONDS of its own
#    it looks once a minute, never every 30 seconds (both are paces the helper sets, not a measurement).
# =================================================================================================
fresh "$OLD" 0 "$PENDING"
printf '%s\n' "printf '%s' '$GREEN' > \"\$ST/rollup\"" > "$ST/on-sleep"
out="$(env -u MWR_POLL_SECONDS bash -c "cd '$REPO' && bash '$HELPER' 7 --squash" 2>&1)"; rc=$?
check_eq "#1014 with no poll setting it still waits and merges" "0" "$rc"
check_eq "#1014 the wait between looks defaults to 60 seconds" "60" "$(cat "$ST/sleeps" 2>/dev/null)"
check_eq "#1014 one pull request read per look, plus the read back after the merge" "3" "$(count gh-calls 'pr view 7')"

# =================================================================================================
# 8. A read GitHub fails to answer is tried again before the wait is thrown away (claude-config#1061).
#    On 2026-10-09 two queued merges each waited 7 to 16 minutes for CI and then stopped on ONE
#    "TLS handshake timeout" or "connection reset by peer" reading the compare. Stopping when it
#    cannot confirm the head contains main's tip stays: only a transport fault or a GitHub server
#    error is tried again, a few times over about a minute, and a real answer (a 404, a pull request
#    that is not there) is believed the first time. The retry waits go through the injected sleep,
#    at MWR_READ_RETRY_SECONDS (7 here, so they are told apart from the 30 second looks).
# =================================================================================================
fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'Get "https://api.github.com/repos/acme/widget/compare/main...x": read tcp 10.0.0.2:51234->140.82.112.6:443: read: connection reset by peer' > "$ST/compare-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#1061 a compare that fails once and then answers still merges" "0" "$rc"
check "#1061 and the merge landed" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_eq "#1061 the compare was asked twice" "2" "$(count gh-calls 'compare/')"
check_eq "#1061 after one retry wait" "1" "$(count sleeps '^7$')"
check "#1061 the retry is said, with GitHub's own error" "connection reset by peer" "$out"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'Get "https://api.github.com/repos/acme/widget/compare/main...x": net/http: TLS handshake timeout' > "$ST/compare-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#1061 a compare that keeps failing still stops" "1" "$rc"
check "#1061 naming the last error" "TLS handshake timeout" "$out"
check "#1061 and saying it could not confirm the head contains main's tip" "could not read whether #7 contains the tip of main" "$out"
check_eq "#1061 nothing was merged on an unconfirmed read" "0" "$(count gh-calls 'pr merge')"
check_eq "#1061 the compare was tried four times" "4" "$(count gh-calls 'compare/')"
check_eq "#1061 with three retry waits between" "3" "$(count sleeps '^7$')"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'gh: Not Found (HTTP 404)' > "$ST/compare-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#1061 a compare GitHub refuses (404) stops at once" "1" "$rc"
check_eq "#1061 asked once, a real answer is not asked again" "1" "$(count gh-calls 'compare/')"
check_eq "#1061 with no retry wait" "0" "$(count sleeps '^7$')"
check_eq "#1061 and nothing merged" "0" "$(count gh-calls 'pr merge')"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'HTTP 502: Bad Gateway (https://api.github.com/graphql)' > "$ST/view-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#1061 a pull request read that fails once with a server error still merges" "0" "$rc"
check_eq "#1061 after one retry wait for it" "1" "$(count sleeps '^7$')"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'Post "https://api.github.com/graphql": net/http: TLS handshake timeout' > "$ST/view-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#1061 a pull request read that keeps failing stops" "1" "$rc"
check "#1061 naming GitHub's last error" "TLS handshake timeout" "$out"
check_eq "#1061 nothing merged" "0" "$(count gh-calls 'pr merge')"
check_eq "#1061 three retry waits" "3" "$(count sleeps '^7$')"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'GraphQL: Could not resolve to a PullRequest with the number of 7. (repository.pullRequest)' > "$ST/view-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#1061 a pull request GitHub says is not there stops at once" "1" "$rc"
check_eq "#1061 with no retry wait" "0" "$(count sleeps '^7$')"
check_eq "#1061 asked once" "1" "$(count gh-calls 'pr view 7')"

# The read back after the merge: a transient failure there is tried again, so the merge is reported
# as merged rather than as a head that moved.
fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'read tcp 10.0.0.2:51234->140.82.112.6:443: i/o timeout' > "$ST/readback-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#1061 a read back that fails once still reports the merge" "0" "$rc"
check "#1061 as merged" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_not "#1061 never as a head that moved" "head moved" "$out"
check_eq "#1061 exactly one merge" "1" "$(count gh-calls 'pr merge')"

# Its default retry pace: about a minute in all, through the injected sleep.
fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'Get "https://api.github.com/repos/acme/widget/compare/main...x": net/http: TLS handshake timeout' > "$ST/compare-down"
out="$(env -u MWR_READ_RETRY_SECONDS bash -c "cd '$REPO' && bash '$HELPER' 7 --squash" 2>&1)"; rc=$?
check_eq "#1061 with no retry setting it still stops when GitHub stays unreachable" "1" "$rc"
check_eq "#1061 the default retry waits are 20 seconds each, a minute in all" "20 20 20" "$(tr '\n' ' ' < "$ST/sleeps" | sed 's/ $//')"

# =================================================================================================
# 9. A fast check reporting first is not the head's CI (claude-config#1087). On 2026-10-12 Slate
#    #3645 was merged at 22:25:56 with one check on its head, a green one from a separate fast
#    workflow, while its CI run had existed since 22:24:52 waiting on a concurrency group: its jobs
#    were created at 22:26:05. The helper read "every reported check is green" as "the head is green".
#    The run itself is the record that more is coming, so an unfinished workflow run for the head is
#    waited on like a pending check, whatever its checks will be called.
# =================================================================================================
FAST='[{"__typename":"CheckRun","name":"merge-gap","workflowName":"Merge-gap guard","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-12T22:24:49Z"}]'
FAST_CI_RUNNING='[{"__typename":"CheckRun","name":"merge-gap","workflowName":"Merge-gap guard","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-12T22:24:49Z"},{"__typename":"CheckRun","name":"build","workflowName":"CI","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-10-12T22:26:07Z"}]'
FAST_CI_GREEN='[{"__typename":"CheckRun","name":"merge-gap","workflowName":"Merge-gap guard","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-12T22:24:49Z"},{"__typename":"CheckRun","name":"build","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-12T22:26:07Z"}]'
RUNS_CI_PENDING='{"total_count":2,"workflow_runs":[{"name":"CI","status":"pending","conclusion":null},{"name":"Merge-gap guard","status":"completed","conclusion":"success"}]}'
RUNS_CI_RUNNING='{"total_count":2,"workflow_runs":[{"name":"CI","status":"in_progress","conclusion":null},{"name":"Merge-gap guard","status":"completed","conclusion":"success"}]}'
RUNS_DONE='{"total_count":2,"workflow_runs":[{"name":"CI","status":"completed","conclusion":"success"},{"name":"Merge-gap guard","status":"completed","conclusion":"success"}]}'

fresh "$OLD" 0 "$FAST"
printf '%s' "$RUNS_CI_PENDING" > "$ST/runs"
printf '%s\n%s\n' \
  "printf '%s' '$FAST_CI_RUNNING' > \"\$ST/rollup\"; printf '%s' '$RUNS_CI_RUNNING' > \"\$ST/runs\"" \
  "printf '%s' '$FAST_CI_GREEN' > \"\$ST/rollup\"; printf '%s' '$RUNS_DONE' > \"\$ST/runs\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#1087 a head whose only reported check is a fast green one still merges once its CI is green" "0" "$rc"
check "#1087 it waited, naming the run whose checks had not registered" "CI (pending)" "$out"
check_eq "#1087 it looked three times: the fast check alone, CI running, CI green" "2" "$(count sleeps '^30$')"
check_eq "#1087 the gates were asked only once, after CI finished" "1" "$(grep -c 'gh pr merge' "$ST/red-gate-payloads" 2>/dev/null || echo 0)"
check_eq "#1087 exactly one merge" "1" "$(count gh-calls 'pr merge')"
check "#1087 the runs were read for the head being merged" "actions/runs?head_sha=$OLD" "$(cat "$ST/gh-calls")"

# No check has reported at all, past the grace for a fresh head, but a run exists: still waited on.
fresh "$OLD" 0 '[]'
printf '%s' '{"total_count":1,"workflow_runs":[{"name":"CI","status":"queued","conclusion":null}]}' > "$ST/runs"
printf '%s\n' "printf '%s' '$FAST_CI_GREEN' > \"\$ST/rollup\"; printf '%s' '$RUNS_DONE' > \"\$ST/runs\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#1087 a head with no checks yet but a queued run merges only after it" "0" "$rc"
check "#1087 waiting on the queued run" "CI (queued)" "$out"
check_eq "#1087 after one wait" "1" "$(count sleeps '^30$')"

# Every run finished, checks green: merged at the first look, no wait added (the control).
fresh "$OLD" 0 "$FAST_CI_GREEN"
printf '%s' "$RUNS_DONE" > "$ST/runs"
out="$(run 7 --squash)"; rc=$?
check_eq "#1087 control: finished runs and green checks merge at once" "0" "$rc"
check_eq "#1087 control: with no wait" "0" "$(count sleeps '^30$')"

# The runs read is retried like the others, and a read that never succeeds stops: not knowing
# whether CI is still to come is not knowing it is not (L42).
fresh "$OLD" 0 "$FAST_CI_GREEN"
printf '%s\n' 'Get "https://api.github.com/repos/acme/widget/actions/runs": net/http: TLS handshake timeout' > "$ST/runs-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#1087 a runs read that fails once and then answers still merges" "0" "$rc"
check_eq "#1087 after one retry wait" "1" "$(count sleeps '^7$')"

fresh "$OLD" 0 "$FAST_CI_GREEN"
printf '%s\n' 'gh: Server Error (HTTP 502)' > "$ST/runs-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#1087 a runs read that keeps failing stops" "1" "$rc"
check "#1087 saying what it could not read" "could not read which workflow runs" "$out"
check_eq "#1087 and nothing was merged" "0" "$(count gh-calls 'pr merge')"

fresh "$OLD" 0 "$FAST_CI_GREEN"
printf '%s\n' 'gh: Resource not accessible by integration (HTTP 403)' > "$ST/runs-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#1087 a runs read GitHub refuses stops at once" "1" "$rc"
check_eq "#1087 with no retry wait" "0" "$(count sleeps '^7$')"

# =================================================================================================
# 10. The changelog record gate is asked too (claude-config#1178). Nine Slate pull requests merged
#     through this helper between 2026-10-07 and 2026-10-12 with no changelog/* label: the helper
#     asked only the checks and review gates, and the typed command that started it is not a merge
#     the changelog gate recognises, so require-changelog-tag.sh saw none of them.
# =================================================================================================
fresh "$OLD" 0 "$GREEN"
printf 'PR #7 carries no usable changelog record. It has no changelog/* label.' > "$ST/changelog-gate-deny"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1178 a refusal from the changelog record gate stops it" "1" "$rc"
check "#1178 carrying that gate's own reason" "no changelog/* label" "$out"
check "#1178 and naming the gate that refused" "require-changelog-tag.sh refused" "$out"
check_eq "#1178 and nothing is merged past it" "0" "$(count gh-calls 'pr merge')"

# Asked FIRST, before any wait: the record does not depend on the head or its checks, so a missing
# label is known at once, and finding it after a twelve minute CI run and a lessons review costs
# both (L667).
fresh "$OLD" 0 "$PENDING"
printf 'PR #7 carries no usable changelog record.' > "$ST/changelog-gate-deny"
out="$(MWR_MAX_POLLS=3 run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1178 a missing record stops it before it waits on checks" "1" "$rc"
check_eq "#1178 with no wait at all" "0" "$(count sleeps '^30$')"
check_eq "#1178 and no lessons review started for a merge that cannot happen" "0" "$(count review-calls '^start')"

# A run resumed after the merge landed reports it merged, not refused: the record is asked only of an
# open pull request.
fresh "$OLD" 0 "$GREEN"
: > "$ST/merged"
printf 'PR #7 carries no usable changelog record.' > "$ST/changelog-gate-deny"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1178 an already merged pull request is reported merged, whatever its record" "0" "$rc"
check "#1178 in those words" "already merged" "$out"

# And asked again at the merge, about the exact pinned command, because a label can be taken off
# while the helper waits.
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --repo acme/widget --squash --delete-branch)"; rc=$?
check_eq "#1178 with a record the merge goes through" "0" "$rc"
check "#1178 the changelog gate judges the exact pinned merge command" "gh pr merge 7 --repo acme/widget --squash --match-head-commit $OLD" "$(cat "$ST/changelog-gate-payloads" 2>/dev/null)"
check "#1178 the merge line names every gate, not two" "every merge gate allows it" "$out"

fresh "$OLD" 0 "$PENDING"
printf '%s\n' "printf '%s' '$GREEN' > \"\$ST/rollup\"; printf 'label removed' > \"\$ST/changelog-gate-deny\"" > "$ST/on-sleep"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1178 a record removed during the wait stops the merge" "1" "$rc"
check "#1178 in the gate's words" "label removed" "$out"
check_eq "#1178 and nothing is merged" "0" "$(count gh-calls 'pr merge')"

# A gate that cannot be run is a refusal, never a pass (L98).
fresh "$OLD" 0 "$GREEN"
out="$(MWR_CHANGELOG_GATE="$WORKDIR/no-such-gate.sh" run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1178 a changelog gate that is not there stops it" "1" "$rc"
check_eq "#1178 and nothing is merged" "0" "$(count gh-calls 'pr merge')"

# The REAL gate decides, against a registry that gates acme/widget (L52).
REG="$WORKDIR/repos.json"
printf '%s\n' '{"repos":[{"name":"Widget","repo":"acme/widget","changelogFrom":"2026-01-01"}]}' > "$REG"
fresh "$OLD" 0 "$GREEN"
out="$(CHANGELOG_REGISTRY="$REG" MWR_CHANGELOG_GATE="$DIR/require-changelog-tag.sh" run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1178 the real require-changelog-tag.sh refuses an unlabelled pull request through the helper" "1" "$rc"
check "#1178 its reason is shown" "carries no usable changelog record" "$out"
check_eq "#1178 and nothing is merged" "0" "$(count gh-calls 'pr merge')"
fresh "$OLD" 0 "$GREEN"
printf '%s' '[{"name":"changelog/technical"}]' > "$ST/labels"
out="$(CHANGELOG_REGISTRY="$REG" MWR_CHANGELOG_GATE="$DIR/require-changelog-tag.sh" run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1178 control: the real gate lets a labelled pull request through the helper" "0" "$rc"

# The design score gate (#1364) is asked at the merge as well: a pull request whose closing keywords
# name a Match the settled design issue below 100% is not merged through the helper any more than
# when typed.
fresh "$OLD" 0 "$GREEN"
printf 'Match the settled design is below 100%% on the code being merged.' > "$ST/design-gate-deny"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1364 a merge the design score gate refuses stops the helper" "1" "$rc"
check "#1364 in the gate's words" "below 100% on the code being merged" "$out"
check_eq "#1364 and nothing is merged" "0" "$(count gh-calls 'pr merge')"
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1364 with the design score gate allowing it, the merge goes through" "0" "$rc"
check "#1364 the design score gate judges the exact pinned merge command" "gh pr merge 7 --repo acme/widget --squash --match-head-commit $OLD" "$(cat "$ST/design-gate-payloads" 2>/dev/null)"

# The verification run gate (#1529) is asked at the merge, about the exact pinned command: its
# records are about a head, so a verdict read before the wait would be about a head that may move.
fresh "$OLD" 0 "$GREEN"
printf 'Refusing to merge PR #7 at 1111111 until every area it touches has a passing verification run there.' > "$ST/verify-gate-deny"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1529 a merge the verification run gate refuses stops the helper" "1" "$rc"
check "#1529 in the gate's words" "has a passing verification run there" "$out"
check "#1529 and the stop names the gate" "require-verification-run.sh refused" "$out"
check_eq "#1529 and nothing is merged" "0" "$(count gh-calls 'pr merge')"
fresh "$OLD" 0 "$GREEN"
printf 'Verification merge check, warn mode, so this merge is allowed. PR #7 would be refused in block mode.' > "$ST/verify-gate-context"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1529 a warn mode allow lets the merge through" "0" "$rc"
check "#1529 the verification gate judges the exact pinned merge command" "gh pr merge 7 --repo acme/widget --squash --match-head-commit $OLD" "$(cat "$ST/verify-gate-payloads" 2>/dev/null)"
check "#1529 and the warn verdict it hands back is shown in the log, not dropped" "would be refused in block mode" "$out"

# THE CLASS (L30, L96): the gates this helper asks must be every gate a typed merge meets. The list
# here is written by hand, so it is checked against the hooks block: every PreToolUse Bash hook that
# recognises a merge through the shared reader (mt_runs_merge or mt_is_pr_merge) must be asked, or
# a merge through this helper skips it, which is exactly how the changelog gate was skipped.
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
if [ -z "$SETTINGS" ]; then
  bad "#1178 neither settings.hooks.json nor settings.json beside $DIR, so the merge gates cannot be listed"
else
  typed_gates="$(jq -r '.hooks.PreToolUse[]? | select((.matcher // "") | test("(^|[|])Bash($|[|])")) | .hooks[]?.command' "$SETTINGS" \
    | sed 's#.*/##' | sort -u | while IFS= read -r h; do
        [ -f "$DIR/$h" ] && grep -Eq 'mt_runs_merge|mt_is_pr_merge' "$DIR/$h" && printf '%s\n' "$h"
      done)"
  helper_gates="$(grep -oE '\$MWR_HOOKS/[A-Za-z0-9_.-]+\.sh' "$HELPER" | sed 's#.*/##' | sort -u)"
  # The control: the listing must find the gate this suite already proves the helper asks, or an
  # empty listing would agree with anything (L98).
  check "#1178 control: the hooks block lists block-red-merge.sh as a merge gate" "block-red-merge.sh" "$typed_gates"
  missing="$(comm -23 <(printf '%s\n' "$typed_gates") <(printf '%s\n' "$helper_gates"))"
  check_eq "#1178 every merge gate a typed merge meets is asked by merge-when-ready.sh" "" "$missing"
fi

# =================================================================================================
# 11. Main keeps moving: the helper waits for it to be still, then updates, and never gives up on a
#     count (claude-config#1271). On 2026-10-16, with several pull requests merging at once and each
#     head's checks taking 15 to 30 minutes, #1267 stopped twice and #1257 once at the old limit of
#     three updates, and each time a person waited for main to go quiet and started it again. The
#     clock here is injected and moved only by the fake sleep, so minutes of quiet and hours of
#     deadline pass in no real time (L524, L290).
# =================================================================================================
H4="4444444444444444444444444444444444444444"
H5="5555555555555555555555555555555555555555"
H6="6666666666666666666666666666666666666666"

# Main moves three times in a row after the first update: one more update, made only once main has
# been still for the settle window, not one per move.
fresh "$OLD" 2 "$GREEN"
printf '%s' "$GREEN" > "$ST/rollup-after-update"
printf '%s\n%s\n' "$NEW" "$NEWER" > "$ST/next-heads"
printf '%s\n%s\n%s\n' \
  "printf 3 > \"\$ST/behind\"; printf m1 > \"\$ST/main-tip\"" \
  "printf 4 > \"\$ST/behind\"; printf m2 > \"\$ST/main-tip\"" \
  "printf 5 > \"\$ST/behind\"; printf m3 > \"\$ST/main-tip\"" > "$ST/on-sleep"
out="$(MWR_SETTLE_SECONDS=90 run 7 --squash)"; rc=$?
check_eq "#1271 main moving three times while it waits still ends in a merge" "0" "$rc"
check_eq "#1271 with one update for the whole burst, not one per move" "2" "$(count gh-calls 'pr update-branch 7')"
check_eq "#1271 the first update at once, the second 90s after main last moved" "1000000 1000180" "$(tr '\n' ' ' < "$ST/update-times" | sed 's/ $//')"
check "#1271 it says it is waiting for main to be still" "main still moving" "$out"
check "#1271 the merge is pinned to the head made after main settled" "--match-head-commit $NEWER" "$(grep 'pr merge' "$ST/gh-calls")"
check_eq "#1271 the checks gate was asked once, about that pinned head" "1" "$(grep -c "match-head-commit $NEWER" "$ST/red-gate-payloads" 2>/dev/null || echo 0)"
check_eq "#1271 and never about a head main had moved past" "0" "$(grep -c "match-head-commit $NEW\"" "$ST/red-gate-payloads" 2>/dev/null || true)"
check "#1271 so was the lessons review gate" "--match-head-commit $NEWER" "$(cat "$ST/review-gate-payloads" 2>/dev/null)"
check "#1271 and the changelog record gate" "--match-head-commit $NEWER" "$(tail -2 "$ST/changelog-gate-payloads" 2>/dev/null)"
check "#1271 the review checked was the pinned head's" "check --dir $REPO --sha $NEWER" "$(cat "$ST/review-calls")"

# Its default settle window, with no MWR_SETTLE_SECONDS: five minutes of quiet (a setting, not a
# measurement).
fresh "$OLD" 1 "$GREEN"
printf '%s' "$GREEN" > "$ST/rollup-after-update"
printf '%s\n%s\n' "$NEW" "$NEWER" > "$ST/next-heads"
printf '%s\n' "printf 2 > \"\$ST/behind\"; printf m1 > \"\$ST/main-tip\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#1271 with the default window it merges" "0" "$rc"
check_eq "#1271 updating 300s after main last moved" "1000000 1000330" "$(tr '\n' ' ' < "$ST/update-times" | sed 's/ $//')"

# Main moves after every update, four times, each a 20 minute check run apart (a fixture, not a
# measurement): five updates, more
# than the old limit of three, and well past the old one hour deadline, then the merge.
fresh "$OLD" 1 "$GREEN"
printf '%s\n%s\n%s\n%s\n%s\n' "$NEW" "$NEWER" "$H4" "$H5" "$H6" > "$ST/next-heads"
for k in 1 2 3 4; do
  printf '%s\n' "printf '%s' \$(( \$(cat \"\$ST/clock\") + 1200 )) > \"\$ST/clock\"; printf '%s' '$GREEN' > \"\$ST/rollup\"; printf 2 > \"\$ST/behind\"; printf m$k > \"\$ST/main-tip\"" >> "$ST/on-sleep"
done
printf '%s\n%s\n' "printf '%s' \$(( \$(cat \"\$ST/clock\") + 1200 )) > \"\$ST/clock\"" "printf '%s' '$GREEN' > \"\$ST/rollup\"" >> "$ST/on-sleep"
out="$(MWR_SETTLE_SECONDS=0 run 7 --squash)"; rc=$?
check_eq "#1271 main moving after each of four updates no longer stops it" "0" "$rc"
check_eq "#1271 five updates" "5" "$(count gh-calls 'pr update-branch 7')"
check "#1271 and the newest head is the one merged" "--match-head-commit $H6" "$(grep 'pr merge' "$ST/gh-calls")"
check_eq "#1271 exactly one merge" "1" "$(count gh-calls 'pr merge')"
check "#1271 each update is counted as it is made" "update 5" "$out"
check_not "#1271 with no limit named" "at most" "$out"

# Main never goes still: the deadline still bounds it, and nothing merges.
fresh "$OLD" 1 "$GREEN"
printf '%s\n' "$NEW" > "$ST/next-heads"
MOVE='n=$(( $(cat "$ST/n" 2>/dev/null || echo 0) + 1 )); printf %s "$n" > "$ST/n"; printf m%s "$n" > "$ST/main-tip"; printf 1 > "$ST/behind"'
for _ in $(seq 1 30); do printf '%s\n' "$MOVE" >> "$ST/on-sleep"; done
out="$(MWR_SETTLE_SECONDS=90 MWR_DEADLINE_SECONDS=300 run 7 --squash)"; rc=$?
check_eq "#1271 a main that never goes still ends at the deadline, resumable" "3" "$rc"
check "#1271 saying it is out of time" "Out of time" "$out"
check "#1271 and that main was still moving" "main still moving" "$out"
check_eq "#1271 it did not chase main with an update per move" "1" "$(count gh-calls 'pr update-branch 7')"
check_eq "#1271 and nothing merged" "0" "$(count gh-calls 'pr merge')"

# Its default deadline, measured by running it out (L107): three hours, so a busy afternoon of
# 15 to 30 minute check runs (as on 2026-10-16) is waited through rather than handed back to a person.
fresh "$OLD" 0 "$PENDING"
out="$(MWR_POLL_SECONDS=600 run 7 --squash)"; rc=$?
default_deadline=$(( $(cat "$ST/clock") - 1000000 ))
check_eq "#1271 with no deadline set it runs out only after three hours" "3 10800" "$rc $default_deadline"

# THE RATIO (L227): is-it-live asks GitHub about a merge this helper makes in the background for
# WAIT_MS after the command, so that window must stay well past the helper's deadline, or a merge
# landing late in the run is never owed its card. Read from the mod's own source, here, so raising
# either number without the other fails.
wait_line="$(grep -E '^export const WAIT_MS = ' "$DIR/../mods/is-it-live/hooks/merges.ts" 2>/dev/null)"
wait_expr="$(printf '%s' "${wait_line#*= }" | tr -d '_ ')"
if [[ "$wait_expr" =~ ^[0-9*]+$ ]]; then
  wait_s=$(( wait_expr / 1000 ))
  [ "$wait_s" -ge $(( 2 * default_deadline )) ] && ok || bad "#1271 is-it-live's WAIT_MS (${wait_s}s) is not at least twice the helper's deadline (${default_deadline}s)"
else
  bad "#1271 could not read WAIT_MS from is-it-live's merges.ts (read: '$wait_line')"
fi

# =================================================================================================
# 12. Pull requests stacked on the merged branch are moved onto its base before the branch is
#     deleted (claude-config#1337). On 2026-10-19 this merged bidspoke#2478 with
#     --delete-branch, GitHub closed #2482, which was based on that branch, and a closed pull
#     request's base can never be changed, so it was opened again as a new one, losing its review
#     thread and a CI round. The fake gh closes whatever is still based on the branch when it is
#     deleted, by gh's own --delete-branch or by the API, as GitHub does.
# =================================================================================================
line_of(){ grep -n -m1 -- "$1" "$ST/gh-calls" | cut -d: -f1; }

fresh "$OLD" 0 "$GREEN"
printf '8\n9\n' > "$ST/stacked"
out="$(run 7 --repo acme/widget --squash --delete-branch)"; rc=$?
check_eq "#1337 a merge with pull requests stacked on its branch ends merged" "0" "$rc"
check_eq "#1337 no stacked pull request is closed" "" "$(cat "$ST/closed" 2>/dev/null)"
check_eq "#1337 each is moved onto the merged pull request's base" "8 main 9 main" "$(tr '\n' ' ' < "$ST/retargeted" 2>/dev/null | sed 's/ $//')"
check_eq "#1337 and the branch is deleted, once" "feat/x" "$(cat "$ST/deleted" 2>/dev/null)"
check_not "#1337 gh pr merge is never handed --delete-branch, which deletes before anything can move" "delete-branch" "$(grep 'pr merge' "$ST/gh-calls")"
check "#1337 the stacked pull requests are listed by the branch they are based on" "pr list --repo acme/widget --base feat/x --state open" "$(cat "$ST/gh-calls")"
ml="$(line_of 'pr merge')"; pl="$(line_of 'X PATCH')"; dl="$(line_of 'X DELETE')"
[ -n "$ml" ] && [ -n "$pl" ] && [ -n "$dl" ] && [ "$ml" -lt "$pl" ] && [ "$pl" -lt "$dl" ] && ok \
  || bad "#1337 the order is merge, then move, then delete (lines: merge $ml, move $pl, delete $dl)"
check "#1337 it says which pull requests it moved" "#8 #9" "$out"
check "#1337 and that it deleted the branch" "Deleted its branch feat/x" "$out"

# Nothing stacked: listed, then deleted.
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --squash --delete-branch)"; rc=$?
check_eq "#1337 with nothing stacked the branch is still deleted" "0 feat/x" "$rc $(cat "$ST/deleted" 2>/dev/null)"
check_eq "#1337 having moved nothing" "0" "$(count gh-calls 'X PATCH')"

# No --delete-branch: the branch is not read, listed or touched.
fresh "$OLD" 0 "$GREEN"
printf '8\n' > "$ST/stacked"
out="$(run 7 --squash)"; rc=$?
check_eq "#1337 without --delete-branch it merges" "0" "$rc"
check_eq "#1337 and leaves the branch and its stacked pull requests alone" "0 0 0" "$(count gh-calls 'pr list') $(count gh-calls 'X PATCH') $(count gh-calls 'X DELETE')"

# A merge that does not happen moves nothing: a stacked pull request moved onto main while its
# parent is still open would show the parent's commits as its own.
fresh "$OLD" 0 "$RED"
printf '8\n' > "$ST/stacked"
printf 'tests=FAILURE' > "$ST/red-gate-deny"
out="$(run 7 --squash --delete-branch)"; rc=$?
check_eq "#1337 a refused merge stops as before" "1" "$rc"
check_eq "#1337 and nothing stacked on it is moved or deleted" "0 0" "$(count gh-calls 'X PATCH') $(count gh-calls 'X DELETE')"

# The list GitHub refuses is not "nothing stacked": the branch stays, and it says why.
fresh "$OLD" 0 "$GREEN"
printf '8\n' > "$ST/stacked"
printf 'gh: Resource not accessible by integration (HTTP 403)\n' > "$ST/list-down"
out="$(run 7 --squash --delete-branch)"; rc=$?
check_eq "#1337 a list that fails leaves the branch in place, merged, with its own exit" "4" "$rc"
check_eq "#1337 the merge itself landed" "yes" "$([ -e "$ST/merged" ] && echo yes)"
check_eq "#1337 the branch was not deleted" "0" "$(count gh-calls 'X DELETE')"
check_eq "#1337 so nothing stacked was closed" "" "$(cat "$ST/closed" 2>/dev/null)"
check "#1337 it says the branch was left in place" "branch feat/x was left in place" "$out"
check "#1337 and why, in GitHub's words" "could not list the open pull requests based on it" "$out"
check "#1337 carrying GitHub's error" "HTTP 403" "$out"

# A list that fails in transit is asked again, through the injected sleep, and then goes on.
fresh "$OLD" 0 "$GREEN"
printf '8\n' > "$ST/stacked"
printf 'read tcp: connection reset by peer\n' > "$ST/list-fails"
out="$(run 7 --squash --delete-branch)"; rc=$?
check_eq "#1337 a list that failed in transit once is asked again, and the merge finishes" "0" "$rc"
check_eq "#1337 asked again, then once more to confirm nothing is left on the branch" "3" "$(count gh-calls 'pr list')"
check "#1337 waiting the injected retry interval, never a real one" "7" "$(cat "$ST/sleeps" 2>/dev/null)"
check_eq "#1337 then moving the stacked pull request" "8 main" "$(cat "$ST/retargeted" 2>/dev/null)"

# One move refused: the branch stays, naming which pull request was not moved.
fresh "$OLD" 0 "$GREEN"
printf '8\n9\n' > "$ST/stacked"
: > "$ST/retarget-fails-9"
out="$(run 7 --squash --delete-branch)"; rc=$?
check_eq "#1337 a move GitHub refuses leaves the branch in place" "4" "$rc"
check_eq "#1337 the branch was not deleted" "0" "$(count gh-calls 'X DELETE')"
check_eq "#1337 and nothing was closed" "" "$(cat "$ST/closed" 2>/dev/null)"
check "#1337 it names the pull request that was not moved" "#9" "$out"
check "#1337 with GitHub's reason" "HTTP 422" "$out"
check "#1337 and says how to finish" "run the same command again" "$out"

# Run again once the cause is dealt with: it finds the merge done and finishes the branch, moving
# only what is still based on it and merging nothing twice (L33).
rm -f "$ST/retarget-fails-9"
out="$(run 7 --squash --delete-branch)"; rc=$?
check_eq "#1337 running it again finishes the branch" "0" "$rc"
check_eq "#1337 one merge across both runs" "1" "$(count gh-calls 'pr merge')"
check_eq "#1337 each pull request moved once" "8 main 9 main" "$(tr '\n' ' ' < "$ST/retargeted" | sed 's/ $//')"
check_eq "#1337 the branch deleted" "feat/x" "$(cat "$ST/deleted" 2>/dev/null)"
check_eq "#1337 with nothing closed" "" "$(cat "$ST/closed" 2>/dev/null)"

# A move GitHub answers yes to that did not happen is caught by reading the list again.
fresh "$OLD" 0 "$GREEN"
printf '8\n' > "$ST/stacked"
: > "$ST/retarget-ignored-8"
out="$(run 7 --squash --delete-branch)"; rc=$?
check_eq "#1337 a pull request still based on the branch after the move keeps it in place" "4" "$rc"
check_eq "#1337 judged by the list read again, not by the answer" "0" "$(count gh-calls 'X DELETE')"
check "#1337 naming it" "#8" "$out"

# The branch now holds commits the merge did not: never deleted. The push lands just after the
# merge, since one landing before it is a head GitHub would refuse to merge (#1458, section 16).
fresh "$OLD" 0 "$GREEN"
printf '%s' "$NEW" > "$ST/tip-after-merge"
out="$(run 7 --squash --delete-branch)"; rc=$?
check_eq "#1337 a branch that moved past the merged head is left in place" "4" "$rc"
check_eq "#1337 and not deleted" "0" "$(count gh-calls 'X DELETE')"
check "#1337 saying what it points at" "points at ${NEW:0:7}" "$out"

# GitHub deleted it already (the repository deletes head branches itself): nothing left to do.
fresh "$OLD" 0 "$GREEN"
: > "$ST/auto-delete"
out="$(run 7 --squash --delete-branch)"; rc=$?
check_eq "#1337 a branch already gone is not an error" "0" "$rc"
check_eq "#1337 and is not deleted again" "0" "$(count gh-calls 'X DELETE')"
check "#1337 saying so" "already deleted" "$out"

# A 404 is also GitHub's answer for what the account cannot see, so it reads as deleted only when
# the base branch, asked the same way, can be seen (a positive control, L248).
fresh "$OLD" 0 "$GREEN"
: > "$ST/auto-delete"; : > "$ST/base-hidden"
out="$(run 7 --squash --delete-branch)"; rc=$?
check_eq "#1337 a 404 GitHub also gives for the base is not read as deleted" "4" "$rc"
check_not "#1337 and is not reported as deleted" "already deleted" "$out"
check "#1337 it says the branch was left in place" "branch feat/x was left in place" "$out"

# A pull request from a fork: its branch is not in this repository, so nothing here deletes one.
fresh "$OLD" 0 "$GREEN"
printf 'true' > "$ST/cross"; printf 'someone' > "$ST/fork-owner"
out="$(run 7 --squash --delete-branch)"; rc=$?
check_eq "#1337 a fork's pull request merges" "0" "$rc"
check_eq "#1337 and no branch of this repository is read or deleted" "0 0" "$(count gh-calls 'repos/acme/widget/git/ref') $(count gh-calls 'X DELETE')"
check "#1337 saying why" "fork" "$out"

# The delete itself refused: merged, branch in place, said.
fresh "$OLD" 0 "$GREEN"
printf 'gh: Reference update failed (HTTP 422)\n' > "$ST/delete-fails"
out="$(run 7 --squash --delete-branch)"; rc=$?
check_eq "#1337 a delete GitHub refuses ends merged with the branch in place" "4" "$rc"
check "#1337 with GitHub's words" "Reference update failed" "$out"

# =================================================================================================
# 13. The REAL checks gate's rerun hint keeps --delete-branch (claude-config#1351). Since #1337 the
#     helper hands gh, and so the gates, a merge without --delete-branch, and the gate built the
#     helper command it suggests from that merge's flags, so following its hint exactly merged and
#     left the branch on GitHub. Here main moves between the helper's last look and the gate's own
#     read (the review check is the step between them), so the real gate sends the merge back.
# =================================================================================================
cat > "$STUBS/pr-review-main-moves.sh" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  start) exit 0 ;;
  check) printf '1' > "$ST/behind"; exit 0 ;;
esac
EOS
chmod +x "$STUBS/pr-review-main-moves.sh"

fresh "$OLD" 0 "$GREEN"
out="$(MWR_RED_GATE="$DIR/block-red-merge.sh" MWR_REVIEW_LIB="$STUBS/pr-review-main-moves.sh" run 7 --repo acme/widget --squash --delete-branch)"; rc=$?
check_eq "#1351 the real gate sends back a merge whose base moved under it" "1" "$rc"
check "#1351 its rerun hint carries --delete-branch when the helper was asked for it" "merge-when-ready.sh 7 --repo acme/widget --squash --delete-branch ." "$out"
check_eq "#1351 and nothing is merged" "0" "$(count gh-calls 'pr merge')"

fresh "$OLD" 0 "$GREEN"
out="$(MWR_RED_GATE="$DIR/block-red-merge.sh" MWR_REVIEW_LIB="$STUBS/pr-review-main-moves.sh" run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1351 control: the real gate sends it back without --delete-branch too" "1" "$rc"
check "#1351 control: with the rerun hint" "merge-when-ready.sh 7 --repo acme/widget --squash ." "$out"
check_not "#1351 which does not add --delete-branch the helper was not asked for" "--delete-branch" "$out"

# =================================================================================================
# 14. Minor findings are advisory (claude-config#1356): a review with only minor ones allows, so
#     the helper merges, and the advisory the review printed is shown in its log, once. The review
#     gate hands an advisory allow back as JSON with no permission decision, which is not a refusal.
# =================================================================================================
ADV='Advisory, minor findings: the lessons review finished with 1 minor finding, which does not stop the merge and needs no fix round.
App/x.swift:1: the comment says seconds (L118). Should be: milliseconds. [severity: minor]'
cat > "$STUBS/pr-review-advisory.sh" <<EOS
#!/usr/bin/env bash
case "\$1" in
  start) exit 0 ;;
  check) printf '%s\n' '$ADV'; exit 0 ;;
esac
EOS
cat > "$STUBS/review-gate-advisory.sh" <<'EOS'
#!/usr/bin/env bash
cat >> "$ST/review-gate-payloads"; printf '\n' >> "$ST/review-gate-payloads"
jq -nc '{systemMessage: "pr-review-gate: Advisory, minor findings", hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: "pr-review-gate: Advisory, minor findings"}}'
exit 0
EOS
chmod +x "$STUBS/pr-review-advisory.sh" "$STUBS/review-gate-advisory.sh"
fresh "$OLD" 0 "$GREEN"
out="$(MWR_REVIEW_LIB="$STUBS/pr-review-advisory.sh" MWR_REVIEW_GATE="$STUBS/review-gate-advisory.sh" run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1356 a review with only minor findings lets the helper merge" "0" "$rc"
check_eq "#1356 exactly one merge" "1" "$(count gh-calls 'pr merge')"
check "#1356 the advisory is shown in its log" "App/x.swift:1: the comment says seconds" "$out"
check_eq "#1356 once" "1" "$(grep -c 'App/x.swift:1: the comment says seconds' <<<"$out")"

# =================================================================================================
# 15. After three rounds of findings the review asks to step back (claude-config#1358). The helper
#     shows that refusal in full, and its own stop line asks for the step back too, rather than only
#     to fix what is real, which is the one finding at a time habit the review is asking to break.
# =================================================================================================
STEP='Refusing to merge until these are read: the lessons review of the whole branch repo feat/x at abc1234 finished (2m 01s) with 1 finding.
    PR_REVIEW_READ=0123abcd <the merge command>
Step back: this is round 3 of lessons review findings on this pull request. Stop fixing findings one at a time and reconsider the approach.
App/x.swift:2: the retry loop has no bound (L524). Should be: bound it. [severity: major]'
cat > "$STUBS/pr-review-step-back.sh" <<EOS
#!/usr/bin/env bash
case "\$1" in
  start) exit 0 ;;
  check) printf '%s\n' '$STEP'; exit 1 ;;
esac
EOS
chmod +x "$STUBS/pr-review-step-back.sh"
fresh "$OLD" 0 "$GREEN"
out="$(MWR_REVIEW_LIB="$STUBS/pr-review-step-back.sh" run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1358 a refusal asking to step back stops the helper" "1" "$rc"
check "#1358 showing the request in its log" "Step back: this is round 3 of" "$out"
check "#1358 with the finding" "the retry loop has no bound" "$out"
check "#1358 and the helper's own stop line asks for the step back" "step back and reconsider the approach" "$(grep 'Stopped:' <<<"$out")"
check_eq "#1358 nothing merged" "0" "$(count gh-calls 'pr merge')"
# A finding that only QUOTES the words, mid line, is not a request to step back.
QUOTED='Refusing to merge until these are read: the lessons review of the whole branch repo feat/x at abc1234 finished (2m 01s) with 1 finding.
lib/x.sh:3: the check matches "Step back:" anywhere in the text (L11). Should be: match it at the start of a line. [severity: major]'
cat > "$STUBS/pr-review-quoted.sh" <<EOS
#!/usr/bin/env bash
case "\$1" in
  start) exit 0 ;;
  check) printf '%s\n' '$QUOTED'; exit 1 ;;
esac
EOS
chmod +x "$STUBS/pr-review-quoted.sh"
fresh "$OLD" 0 "$GREEN"
out="$(MWR_REVIEW_LIB="$STUBS/pr-review-quoted.sh" run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1358 a finding quoting the words still stops the helper" "1" "$rc"
check_not "#1358 but its stop line does not ask to step back" "step back" "$(grep 'Stopped:' <<<"$out")"
# Control: an ordinary refusal's stop line is as before.
fresh "$OLD" 0 "$GREEN"
printf '1\n' > "$ST/review-answers"
out="$(run 7 --squash)"; rc=$?
check_not "#1358 control: an ordinary refusal does not ask to step back" "step back" "$(grep 'Stopped:' <<<"$out")"

# =================================================================================================
# 16. GitHub's head for the pull request lags the branch's tip (claude-config#1458). On 2026-10-21
#     Bidspoke #2577's head stayed at 30ff7b1 for over ten minutes after its branch was pushed to
#     d854a1a (git ls-remote and the branches API both showed d854a1a), so the helper merged pinned
#     to the old head and gh pr merge was refused twice with "Head branch is out of date". A no op
#     re-set of the pull request's base made GitHub pick up d854a1a at once. The fake gh refuses a
#     merge whose head is not the branch's tip the same way, and its base re-set resyncs the head
#     only when the test says it takes.
# =================================================================================================
printf '%s' "$GREEN" > "$WORKDIR/green"
# On each sleep while the pull request shows NEW, count; at the second, NEW's checks go green, so the
# helper is seen waiting on the real head's checks before merging it.
NEW_GOES_GREEN='if [ "$(cat "$ST/head")" = "'"$NEW"'" ]; then k=$(( $(cat "$ST/k" 2>/dev/null || echo 0) + 1 )); printf %s "$k" > "$ST/k"; [ "$k" -ge 2 ] && cp "'"$WORKDIR"'/green" "$ST/rollup"; fi'
queue_new_goes_green(){ for _ in $(seq 1 12); do printf '%s\n' "$NEW_GOES_GREEN" >> "$ST/on-sleep"; done; }

# Lagging from the first look, and the re-set of the base fixes it.
fresh "$OLD" 0 "$GREEN"
printf '%s' "$NEW" > "$ST/branch-tip"
: > "$ST/resync-takes"; printf '%s' "$PENDING" > "$ST/rollup-after-resync"
queue_new_goes_green
out="$(run 7 --squash)"; rc=$?
check_eq "#1458 a head lagging its branch is resynced and the branch's tip merged" "0" "$rc"
check "#1458 it says GitHub still shows the old head while the branch has moved" "GitHub still shows it for #7, but branch feat/x is at ${NEW:0:7}" "$out"
check_eq "#1458 the base is re-set once" "1" "$(count gh-calls 'X PATCH repos/acme/widget/pulls/7 ')"
check "#1458 to the base it already has" "api -X PATCH repos/acme/widget/pulls/7 -f base=main" "$(cat "$ST/gh-calls")"
check_eq "#1458 only after two minutes of waiting for GitHub to catch up on its own" "1000120" "$(cat "$ST/resyncs" 2>/dev/null)"
check "#1458 and it says it did" "set again to main" "$out"
check "#1458 then it waits on the real head's checks" "Head ${NEW:0:7}: waiting, checks still running" "$out"
check_eq "#1458 exactly one merge" "1" "$(count gh-calls 'pr merge')"
check "#1458 pinned to the branch's tip" "--match-head-commit $NEW" "$(grep 'pr merge' "$ST/gh-calls")"
check_not "#1458 no gate is ever asked to merge the stale head" "--match-head-commit $OLD" "$(cat "$ST/red-gate-payloads" 2>/dev/null)"
check_not "#1458 and no lessons review is started for it" "--sha $OLD" "$(cat "$ST/review-calls" 2>/dev/null)"
check "#1458 the review started is the real head's" "start --dir $REPO --sha $NEW" "$(cat "$ST/review-calls" 2>/dev/null)"

# GitHub catches up on its own inside the wait: no re-set at all.
fresh "$OLD" 0 "$GREEN"
printf '%s' "$NEW" > "$ST/branch-tip"
printf '%s\n' "printf '%s' '$NEW' > \"\$ST/head\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#1458 a lag GitHub clears by itself ends in the merge" "0" "$rc"
check_eq "#1458 with no re-set of the base" "0" "$(count gh-calls 'X PATCH')"
check "#1458 of the branch's tip" "--match-head-commit $NEW" "$(grep 'pr merge' "$ST/gh-calls")"
check_eq "#1458 merged once" "1" "$(count gh-calls 'pr merge')"

# The re-set does not take: it stops, bounded, saying so, and merges nothing.
fresh "$OLD" 0 "$GREEN"
printf '%s' "$NEW" > "$ST/branch-tip"
out="$(run 7 --squash)"; rc=$?
check_eq "#1458 a resync that does not take stops it" "1" "$rc"
check "#1458 saying GitHub still shows the old head" "Stopped: GitHub still shows head ${OLD:0:7} for #7, but branch feat/x is at ${NEW:0:7}" "$out"
check "#1458 after the base was set again" "after its base was set again" "$out"
check_eq "#1458 nothing is merged" "0" "$(count gh-calls 'pr merge')"
check_eq "#1458 the base was re-set once, never in a loop" "1" "$(count gh-calls 'X PATCH repos/acme/widget/pulls/7 ')"
check_eq "#1458 and it gave up after two minutes before the re-set and two after" "240" "$(( $(cat "$ST/clock") - 1000000 ))"

# The push lands while the helper waits on the old head's checks, and GitHub does not pick it up:
# found at the merge, before any gate is asked, and the real head is waited on and merged.
fresh "$OLD" 0 "$PENDING"
printf '%s\n' "cp '$WORKDIR/green' \"\$ST/rollup\"; printf '%s' '$NEW' > \"\$ST/branch-tip\"" > "$ST/on-sleep"
queue_new_goes_green
: > "$ST/resync-takes"; printf '%s' "$PENDING" > "$ST/rollup-after-resync"
out="$(run 7 --squash)"; rc=$?
check_eq "#1458 a lag that starts during the wait is resynced before the merge" "0" "$rc"
check_eq "#1458 one merge" "1" "$(count gh-calls 'pr merge')"
check "#1458 of the branch's tip" "--match-head-commit $NEW" "$(grep 'pr merge' "$ST/gh-calls")"
check_not "#1458 the gates were never asked about the stale head" "--match-head-commit $OLD" "$(cat "$ST/red-gate-payloads" 2>/dev/null)"
check_eq "#1458 resynced once" "1" "$(count gh-calls 'X PATCH repos/acme/widget/pulls/7 ')"

# Control: head and tip agree, so it behaves as before, with the tip read before the review starts
# and again before the merge.
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --squash)"; rc=$?
check_eq "#1458 control: a head that is its branch's tip merges at once" "0" "$rc"
check_eq "#1458 control: with no re-set and no wait" "0 0" "$(count gh-calls 'X PATCH') $(count sleeps .)"
check_not "#1458 control: and no word of a lag" "still shows" "$out"
check_eq "#1458 control: the tip is read when the head is first seen and before the merge" "2" "$(count gh-calls 'git/ref/heads/feat/x')"
tl="$(grep -n 'git/ref/heads/feat/x' "$ST/gh-calls" | tail -1 | cut -d: -f1)"; ml="$(line_of 'pr merge')"
[ -n "$tl" ] && [ -n "$ml" ] && [ "$tl" -lt "$ml" ] && ok || bad "#1458 control: the tip is read before the merge (tip $tl, merge $ml)"
check "#1458 the pull request read asks for the head's repository, for a fork's branch" "headRepositoryOwner" "$(grep -m1 'pr view' "$ST/gh-calls")"

# The branch is not on GitHub while the pull request is open: no tip to confirm, so it stops.
fresh "$OLD" 0 "$GREEN"
: > "$ST/branch-deleted"
out="$(run 7 --squash)"; rc=$?
check_eq "#1458 an open pull request whose branch is gone stops" "1" "$rc"
check "#1458 saying the branch is not there" "branch feat/x of #7 is not on GitHub" "$out"
check_eq "#1458 nothing merged, nothing re-set, no review started" "0 0 0" "$(count gh-calls 'pr merge') $(count gh-calls 'X PATCH') $(count review-calls '^start')"

# A 404 GitHub also gives for the base: could not read, a different cause in its own words (L11).
fresh "$OLD" 0 "$GREEN"
: > "$ST/branch-deleted"; : > "$ST/base-hidden"
out="$(run 7 --squash)"; rc=$?
check_eq "#1458 a branch GitHub will not show stops" "1" "$rc"
check "#1458 saying it could not read the tip" "could not read the tip of branch feat/x" "$out"
check_not "#1458 not claiming the branch is gone" "is not on GitHub" "$out"
check_eq "#1458 and nothing merged" "0" "$(count gh-calls 'pr merge')"

# A tip read that fails in transit is asked again, through the injected sleep.
fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'read tcp: connection reset by peer' > "$ST/ref-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#1458 a tip read that fails once in transit still merges" "0" "$rc"
check_eq "#1458 after one retry wait" "1" "$(count sleeps '^7$')"

# A fork's branch is read from the fork, and a lag there is caught the same way.
fresh "$OLD" 0 "$GREEN"
printf 'true' > "$ST/cross"; printf 'someone' > "$ST/fork-owner"; printf '%s' "$NEW" > "$ST/fork-tip"
out="$(run 7 --squash)"; rc=$?
check_eq "#1458 a fork's pull request lagging its branch is not merged" "1" "$rc"
check "#1458 its tip read from the fork" "api repos/someone/widget/git/ref/heads/feat/x" "$(cat "$ST/gh-calls")"
check "#1458 and the stop names the fork's branch" "branch someone/widget:feat/x is at ${NEW:0:7}" "$out"
check_eq "#1458 nothing merged" "0" "$(count gh-calls 'pr merge')"

# The deadline still bounds a lag wait.
fresh "$OLD" 0 "$GREEN"
printf '%s' "$NEW" > "$ST/branch-tip"
out="$(MWR_DEADLINE_SECONDS=60 run 7 --squash)"; rc=$?
check_eq "#1458 a lag wait that reaches the deadline ends resumable" "3" "$rc"
check "#1458 saying what it waited for" "Out of time" "$out"
check_eq "#1458 and nothing merged" "0" "$(count gh-calls 'pr merge')"

# =================================================================================================
# 17. An update GitHub's record of the pull request does not show (claude-config#1500). During
#     GitHub's 2026-10-22 incident PET #1885's branch moved to 9e50f0c when it was updated, but the
#     pull request kept showing 60a80b8 for over 45 minutes, mergeable UNKNOWN and no CI run started,
#     and the helper read the unmoved head as still behind and updated it seven more times, then
#     stopped on a 404 reading the compare. The fake's update-unseen is that: the update is accepted
#     and the pull request's head and distance behind stay as they were.
# =================================================================================================
el(){ printf '%s' "$(( $(cat "$ST/clock") - 1000000 ))"; }

# The branch moved and the pull request never shows it: one update, a wait, the one re-set of the
# base #1458 makes for a lag, a wait for that, then a plain stop. Never a second update.
fresh "$OLD" 1 "$GREEN"
printf '%s\n' "$NEW" > "$ST/next-heads"; : > "$ST/update-unseen"; : > "$ST/branch-moves"
out="$(MWR_HEARTBEAT_SECONDS=60 run 7 --squash)"; rc=$?
check_eq "#1500 a pull request that never shows its update stops, needing a person" "1" "$rc"
check_eq "#1500 updated once, never again while its head has not moved" "1" "$(count gh-calls 'pr update-branch 7')"
check_not "#1500 the unmoved head is never counted as a second update" "update 2" "$out"
check "#1500 it says the pull request has not caught up with its branch" "#7 has not caught up with its branch" "$out"
check "#1500 and names both commits while it waits" "GitHub still shows head ${OLD:0:7}, but branch feat/x is at ${NEW:0:7}" "$out"
check "#1500 the wait says it will not update again" "without updating again" "$out"
check_eq "#1500 the base is set again once, two minutes into the lag" "1000150" "$(cat "$ST/resyncs" 2>/dev/null)"
check "#1500 the stop is plain" "Stopped: #7 has not caught up with its branch" "$out"
check_eq "#1500 two minutes after the re-set" "270" "$(el)"
check_eq "#1500 nothing merged" "0" "$(count gh-calls 'pr merge')"
check "#1476 the wait for the update to show is heard from while it lasts" "Still waiting" "$(grep 'has not caught up' <<<"$out")"

# The same lag, and the re-set takes: the branch's tip, which holds main, is waited on and merged.
fresh "$OLD" 1 "$GREEN"
printf '%s\n' "$NEW" > "$ST/next-heads"; : > "$ST/update-unseen"; : > "$ST/branch-moves"
: > "$ST/resync-takes"; printf '%s' "$GREEN" > "$ST/rollup-after-resync"; printf 0 > "$ST/behind-after-resync"
out="$(run 7 --squash)"; rc=$?
check_eq "#1500 a lag after an update that the re-set clears ends in the merge" "0" "$rc"
check_eq "#1500 with the one update" "1" "$(count gh-calls 'pr update-branch 7')"
check "#1500 of the branch's tip" "--match-head-commit $NEW" "$(grep 'pr merge' "$ST/gh-calls")"

# Neither the pull request nor its branch shows the update: waited on, never updated again, and a
# plain stop four minutes after the update (the two lag windows #1458 allows a lag in all).
fresh "$OLD" 1 "$GREEN"
: > "$ST/update-unseen"
out="$(run 7 --squash)"; rc=$?
check_eq "#1500 an update nothing shows stops, needing a person" "1" "$rc"
check_eq "#1500 updated once" "1" "$(count gh-calls 'pr update-branch 7')"
check "#1500 saying it has not caught up" "#7 has not caught up with its branch" "$out"
check "#1500 in a plain stop" "Stopped: #7 has not caught up" "$out"
check_eq "#1500 four minutes after the update" "240" "$(el)"
check_eq "#1500 nothing merged" "0" "$(count gh-calls 'pr merge')"

# Control: GitHub shows the update during that wait, and the new head is merged with no second update.
fresh "$OLD" 1 "$GREEN"
: > "$ST/update-unseen"
printf '%s\n%s\n' ":" "printf '%s' '$NEW' > \"\$ST/head\"; printf 0 > \"\$ST/behind\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#1500 control: an update GitHub shows late is merged" "0" "$rc"
check_eq "#1500 control: after one update" "1" "$(count gh-calls 'pr update-branch 7')"
check "#1500 control: pinned to the head it shows" "--match-head-commit $NEW" "$(grep 'pr merge' "$ST/gh-calls")"

# A 404 reading the compare just after an update is GitHub catching up, so it is waited through.
fresh "$OLD" 1 "$GREEN"
printf '%s\n' "$NEW" > "$ST/next-heads"; printf '%s' "$GREEN" > "$ST/rollup-after-update"
printf '%s\n' "printf 'gh: Not Found (HTTP 404)\ngh: Not Found (HTTP 404)\n' > \"\$ST/compare-fails\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#1500 a 404 comparing just after an update is waited through" "0" "$rc"
check "#1500 saying the pull request has not caught up" "has not caught up" "$out"
check "#1500 and the updated head merges" "--match-head-commit $NEW" "$(grep 'pr merge' "$ST/gh-calls")"
check_eq "#1500 after one update" "1" "$(count gh-calls 'pr update-branch 7')"

# A 404 that lasts: a plain stop, four minutes after the update.
fresh "$OLD" 1 "$GREEN"
printf '%s\n' "$NEW" > "$ST/next-heads"; printf '%s' "$GREEN" > "$ST/rollup-after-update"
printf '%s\n' "printf 'gh: Not Found (HTTP 404)' > \"\$ST/compare-down\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#1500 a 404 that lasts after an update stops" "1" "$rc"
check "#1500 saying the pull request has not caught up" "Stopped: #7 has not caught up" "$out"
check "#1500 and that GitHub cannot compare it" "404" "$(grep 'Stopped' <<<"$out")"
check_eq "#1500 four minutes after the update" "240" "$(el)"
check_eq "#1500 nothing merged" "0" "$(count gh-calls 'pr merge')"

# Control: a 404 with no update in this run is not a lag, and stops at once as before.
fresh "$OLD" 0 "$GREEN"
printf 'gh: Not Found (HTTP 404)' > "$ST/compare-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#1500 control: a 404 comparing with no update made stops" "1" "$rc"
check "#1500 control: in the words it always used" "could not read whether #7 contains the tip of main" "$out"
check_eq "#1500 control: at once" "0" "$(count sleeps .)"

# =================================================================================================
# 18. No merge method passed (claude-config#1476). On 2026-10-21 about a dozen PET merges reached a
#     green, reviewed, up to date head and stopped on gh's "--merge, --rebase, or --squash required
#     when not running interactively". Now the repository's own settings decide when they allow one
#     method, and when they allow more it refuses before anything is waited on.
# =================================================================================================
only(){ printf '{"full_name":"acme/widget","allow_squash_merge":%s,"allow_merge_commit":%s,"allow_rebase_merge":%s}' "$1" "$2" "$3" > "$ST/methods"; }

fresh "$OLD" 0 "$GREEN"; only true false false
out="$(run 7)"; rc=$?
check_eq "#1476 a repository allowing only squash merges with no method passed" "0" "$rc"
check "#1476 by squash" "pr merge 7 --repo acme/widget --squash --match-head-commit $OLD" "$(cat "$ST/gh-calls")"
check "#1476 and the gates judge that command" "gh pr merge 7 --repo acme/widget --squash --match-head-commit $OLD" "$(cat "$ST/red-gate-payloads")"
check "#1476 saying why" "squash, the only merge method acme/widget allows" "$out"

fresh "$OLD" 0 "$GREEN"; only false false true
out="$(run 7)"; rc=$?
check_eq "#1476 rebase only: merged" "0" "$rc"
check "#1476 by rebase" "pr merge 7 --repo acme/widget --rebase --match-head-commit $OLD" "$(cat "$ST/gh-calls")"

fresh "$OLD" 0 "$GREEN"; only false true false
out="$(run 7)"; rc=$?
check_eq "#1476 merge commits only: merged" "0" "$rc"
check "#1476 by merge commit" "pr merge 7 --repo acme/widget --merge --match-head-commit $OLD" "$(cat "$ST/gh-calls")"
check "#1476 named as a merge commit" "Merging by merge commit, the only merge method acme/widget allows" "$out"

# All three allowed, as PET and claude-config do: nothing decides, so it refuses before any wait.
fresh "$OLD" 2 "$PENDING"
out="$(run 7)"; rc=$?
check_eq "#1476 several methods allowed and none passed is refused" "64" "$rc"
check "#1476 naming the methods the repository allows" "acme/widget allows squash, merge commit and rebase merges" "$out"
check "#1476 and the command to run instead" "merge-when-ready.sh 7 --repo acme/widget --squash" "$out"
check_eq "#1476 before any update, wait, review or merge" "0 0 0 0" "$(count gh-calls 'pr update-branch') $(count sleeps .) $(count review-calls .) $(count gh-calls 'pr merge')"

fresh "$OLD" 0 "$GREEN"; only true false true
out="$(run 7)"; rc=$?
check_eq "#1476 two allowed is refused too" "64" "$rc"
check "#1476 naming both" "acme/widget allows squash and rebase merges" "$out"

# GitHub does not say (it leaves the settings out for an account that may not change them).
fresh "$OLD" 0 "$GREEN"; printf '{"full_name":"acme/widget"}' > "$ST/methods"
out="$(run 7)"; rc=$?
check_eq "#1476 settings GitHub leaves out are refused, not guessed" "64" "$rc"
check "#1476 saying GitHub did not say" "GitHub did not say which merge methods acme/widget allows" "$out"
check_eq "#1476 nothing merged" "0" "$(count gh-calls 'pr merge')"

# A read GitHub refuses stops; one that fails in transit is asked again.
fresh "$OLD" 0 "$GREEN"; only true false false; printf 'gh: Forbidden (HTTP 403)' > "$ST/repo-down"
out="$(run 7)"; rc=$?
check_eq "#1476 a refused read of the settings stops" "1" "$rc"
check "#1476 saying so" "could not read which merge methods acme/widget allows" "$out"
check_eq "#1476 nothing merged" "0" "$(count gh-calls 'pr merge')"
fresh "$OLD" 0 "$GREEN"; only true false false; printf 'read tcp: connection reset by peer\n' > "$ST/repo-fails"
out="$(run 7)"; rc=$?
check_eq "#1476 a settings read that fails once in transit still merges" "0" "$rc"
check "#1476 by the one method" "--squash --match-head-commit $OLD" "$(grep 'pr merge' "$ST/gh-calls")"

# Control: a method passed is used as given, and the settings are never read.
fresh "$OLD" 0 "$GREEN"; only true false false
out="$(run 7 --merge)"; rc=$?
check_eq "#1476 control: a method passed merges" "0" "$rc"
check "#1476 control: by that method" "--merge --match-head-commit $OLD" "$(grep 'pr merge' "$ST/gh-calls")"
check_eq "#1476 control: with no read of the settings" "0" "$(count gh-calls '^api repos/acme/widget$')"

# =================================================================================================
# 19. A heartbeat while it waits (claude-config#1476). On PET #1857 it updated the branch and then
#     said nothing long enough that the agent stopped it. Every wait now says, at a fixed interval,
#     what it is still waiting on and for how long, on the injected clock (L524).
# =================================================================================================
fresh "$OLD" 0 "$PENDING"
for _ in 1 2 3 4 5 6 7; do printf ':\n' >> "$ST/on-sleep"; done
printf '%s\n' "cp '$WORKDIR/green' \"\$ST/rollup\"" >> "$ST/on-sleep"
out="$(MWR_HEARTBEAT_SECONDS=90 run 7 --squash)"; rc=$?
check_eq "#1476 a long wait on checks still merges" "0" "$rc"
check_eq "#1476 with a heartbeat every 90s of it, and only then" "2" "$(grep -c 'Still waiting' <<<"$out")"
check "#1476 the first at 90s, naming what and how long" "[1m 30s] Head ${OLD:0:7}: waiting, checks still running (1 of 1). Still waiting, for 1m 30s so far." "$out"
check "#1476 the second at 180s" "[3m 00s] Head ${OLD:0:7}: waiting, checks still running (1 of 1). Still waiting, for 3m 00s so far." "$out"

# Its default interval: two minutes, two looks at the default pace.
fresh "$OLD" 0 "$PENDING"
for _ in 1 2 3 4 5; do printf ':\n' >> "$ST/on-sleep"; done
printf '%s\n' "cp '$WORKDIR/green' \"\$ST/rollup\"" >> "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#1476 default: merged" "0" "$rc"
check_eq "#1476 default: one heartbeat in three minutes of waiting" "1" "$(grep -c 'Still waiting' <<<"$out")"
check "#1476 default: at two minutes" "[2m 00s] Head ${OLD:0:7}: waiting" "$(grep 'Still waiting' <<<"$out")"

# =================================================================================================
# 20. The merged branch's agent worktree is removed at the merge (claude-config#1521). On 2026-10-22
#     this repository held 66 agent worktrees, 63 for merged pull requests, because the sweep ran
#     only at a session's first prompt. Now the merge removes its own branch's worktree, through
#     check-stale-worktrees.sh --just-merged, so every rule is the check's (L370): only the six hour
#     recency is off. The caller's own folder is never removed, and nothing here can turn a merge
#     that landed into a failure.
# =================================================================================================
G(){ git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
WREPO="$(cd "$WORKDIR" && pwd -P)/wtrepo"
G init -q -b main "$WREPO"
G -C "$WREPO" remote add origin https://github.com/acme/widget.git
printf 'x\n' > "$WREPO/f.txt"; G -C "$WREPO" add f.txt; G -C "$WREPO" commit -qm base
AGENT="$WREPO/.claude/worktrees/agent-x"
wt_fresh(){ # a fresh state, and a fresh agent worktree on feat/x whose head the merged list names
  fresh "$OLD" 0 "$GREEN"
  G -C "$WREPO" worktree remove --force "$AGENT" >/dev/null 2>&1
  G -C "$WREPO" branch -q -D feat/x >/dev/null 2>&1
  mkdir -p "$WREPO/.claude/worktrees"
  G -C "$WREPO" worktree add -q -b feat/x "$AGENT" >/dev/null 2>&1
  printf 'feat/x\t%s\t7\n' "$(G -C "$AGENT" rev-parse HEAD)" > "$ST/merged-list"
}
wrun(){ (cd "$WREPO" && bash "$HELPER" "$@" 2>&1); }
there(){ [ -d "$AGENT" ] && echo yes || echo no; }
CAN_SEE_USE=0
{ command -v lsof >/dev/null 2>&1 || [ -d /proc/self/cwd ]; } && CAN_SEE_USE=1

# Merged, clean, and every file in it minutes old: removed, its branch kept.
wt_fresh
out="$(wrun 7 --squash)"; rc=$?
check_eq "#1521 a merge whose branch has a clean agent worktree succeeds" "0" "$rc"
check "#1521 and says it merged" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_eq "#1521 the worktree is removed at the merge, although everything in it is new" "no" "$(there)"
check "#1521 and it says so, in the check's words" "removed agent-x [feat/x]: PR #7 merged" "$out"
check_eq "#1521 its local branch is kept" "0" "$(G -C "$WREPO" rev-parse -q --verify feat/x >/dev/null; echo $?)"

# Control: a repository with no agent worktree for the branch says nothing about worktrees.
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --squash)"; rc=$?
check_eq "#1521 control: a merge with no agent worktree merges" "0" "$rc"
check_not "#1521 control: and says nothing about a worktree" "worktree" "$out"
check_eq "#1521 control: nor asks GitHub for the merged list" "0" "$(count gh-calls 'pr list --state merged')"

# Uncommitted work keeps it, and the reason is said.
wt_fresh; printf 'half done\n' > "$AGENT/wip.txt"
out="$(wrun 7 --squash)"; rc=$?
check_eq "#1521 a dirty worktree does not stop the merge" "0" "$rc"
check_eq "#1521 a worktree holding uncommitted work is kept" "yes" "$(there)"
check "#1521 saying why" "keeping agent-x [feat/x]: it holds 1 uncommitted change(s)" "$out"
check_eq "#1521 with the work still in it" "half done" "$(cat "$AGENT/wip.txt")"

# Commits the pull request never held keep it.
wt_fresh; G -C "$AGENT" commit -q --allow-empty -m "after the merge"
out="$(wrun 7 --squash)"; rc=$?
check_eq "#1521 an unmerged commit does not stop the merge" "0" "$rc"
check_eq "#1521 a worktree with commits the pull request never held is kept" "yes" "$(there)"
check "#1521 saying why" "keeping agent-x [feat/x]: it has commits PR #7 never held" "$out"

# A process standing in it keeps it.
wt_fresh
(cd "$AGENT" && exec sleep 120) &
WBUSY=$!
out="$(wrun 7 --squash)"; rc=$?
kill "$WBUSY" 2>/dev/null; wait "$WBUSY" 2>/dev/null
check_eq "#1521 a busy worktree does not stop the merge" "0" "$rc"
if [ "$CAN_SEE_USE" -eq 1 ]; then
  check_eq "#1521 a worktree a running process stands in is kept" "yes" "$(there)"
  check "#1521 saying why" "keeping agent-x [feat/x]: a running process is working in it" "$out"
else
  echo "SUITE-PART-UNMEASURED neither lsof nor /proc here, so a busy worktree at the merge cannot be tested"
fi

# The caller's own folder: an agent merging from inside its worktree keeps it, and says the sweep
# will take it, rather than deleting the floor under itself.
wt_fresh
out="$(cd "$AGENT" && bash "$HELPER" 7 --squash 2>&1)"; rc=$?
check_eq "#1521 a merge run from inside the worktree succeeds" "0" "$rc"
check_eq "#1521 the caller's own worktree is never removed" "yes" "$(there)"
check "#1521 saying it is the folder the merge was run from, left to the sweep" "is the folder this merge was run from" "$out"
check "#1521 and naming the sweep that takes it later" "stale worktree sweep" "$out"
mkdir -p "$AGENT/sub"
out="$(cd "$AGENT/sub" && bash "$HELPER" 7 --squash 2>&1)"; rc=$?
check_eq "#1521 so is one run from a folder inside it" "yes" "$(there)"
rmdir "$AGENT/sub"

# A removal that cannot be judged or breaks never turns the merge into a failure.
wt_fresh; : > "$ST/merged-list-fails"
out="$(wrun 7 --squash)"; rc=$?
check_eq "#1521 a merged list GitHub will not give still leaves a merge that landed at exit 0" "0" "$rc"
check "#1521 and the merge is still said" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_eq "#1521 and the worktree is kept" "yes" "$(there)"
check "#1521 saying it could not be judged" "could not read the merged pull requests" "$out"
wt_fresh
printf '#!/usr/bin/env bash\necho "line 3: syntax error" >&2\nexit 3\n' > "$WORKDIR/broken-check.sh"
out="$(cd "$WREPO" && MWR_WORKTREE_CHECK="$WORKDIR/broken-check.sh" bash "$HELPER" 7 --squash 2>&1)"; rc=$?
check_eq "#1521 a check that breaks still leaves the merge at exit 0" "0" "$rc"
check "#1521 and says the check broke, with what it said" "syntax error" "$out"
check_eq "#1521 and the worktree is kept" "yes" "$(there)"
wt_fresh
out="$(cd "$WREPO" && MWR_WORKTREE_CHECK="$WORKDIR/not-there.sh" bash "$HELPER" 7 --squash 2>&1)"; rc=$?
check_eq "#1521 a check that is missing still leaves the merge at exit 0" "0" "$rc"
check_eq "#1521 and the worktree is kept" "yes" "$(there)"

# Merged with the branch left in place (stop 4) still removes the worktree, and so does a run that
# finds the pull request already merged.
wt_fresh; printf '%s' "$NEW" > "$ST/tip-after-merge"
out="$(wrun 7 --squash --delete-branch)"; rc=$?
check_eq "#1521 merged with the branch left in place exits 4 as before" "4" "$rc"
check_eq "#1521 and the worktree is still removed" "no" "$(there)"
wt_fresh; : > "$ST/merged"
out="$(wrun 7 --squash)"; rc=$?
check_eq "#1521 a pull request found already merged exits 0" "0" "$rc"
check_eq "#1521 and its worktree is removed too" "no" "$(there)"

# =================================================================================================
# 21. The shared polling policy (claude-config#1482, lib/gh-poll.sh). On 2026-10-22 GitHub's
#     secondary (burst) limit refused every session on the account for about 40 minutes while several
#     agents ran this helper and gh pr view loops at once. The wait between looks now grows while a
#     look sees nothing new and starts again at the base on any change; a rate limit answer pauses the
#     session's looks for as long as GitHub says; and the looks a minute are capped per session, the
#     cap shared by every loop in it through one state file.
# =================================================================================================
TWO_PENDING='[{"__typename":"CheckRun","name":"tests","workflowName":"ci","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-10-06T10:05:00Z"},{"__typename":"CheckRun","name":"lint","workflowName":"ci","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-10-06T10:05:00Z"}]'
ONE_DONE='[{"__typename":"CheckRun","name":"tests","workflowName":"ci","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-10-06T10:05:00Z"},{"__typename":"CheckRun","name":"lint","workflowName":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-06T10:05:00Z"}]'
printf '%s' "$ONE_DONE" > "$WORKDIR/one-done"
LIMITED="gh: API rate limit exceeded for user ID 241846707. (HTTP 403)"

# The wait grows while nothing changes, starts again on a change, and the look that sees the checks
# finished merges with no further wait.
fresh "$OLD" 0 "$TWO_PENDING"
printf ':\n:\n:\n%s\n%s\n' "cp '$WORKDIR/one-done' \"\$ST/rollup\"" "cp '$WORKDIR/green' \"\$ST/rollup\"" > "$ST/on-sleep"
out="$(MWR_POLL_MAX_SECONDS=120 MWR_HEARTBEAT_SECONDS=1000 run 7 --squash)"; rc=$?
check_eq "#1482 a long wait on checks still merges" "0" "$rc"
check_eq "#1482 the wait doubles on each unchanged look up to its ceiling, and a change starts it again" "30 60 120 120 30" "$(tr '\n' ' ' < "$ST/sleeps" | sed 's/ $//')"
check_eq "#1482 the look that finds the checks done merges at once" "1" "$(count gh-calls 'pr merge')"

# Its default ceiling: three minutes from a one minute base.
fresh "$OLD" 0 "$PENDING"
for _ in 1 2 3 4; do printf ':\n' >> "$ST/on-sleep"; done
printf '%s\n' "cp '$WORKDIR/green' \"\$ST/rollup\"" >> "$ST/on-sleep"
out="$(env -u MWR_POLL_SECONDS -u MWR_POLL_MAX_SECONDS MWR_HEARTBEAT_SECONDS=1000 bash -c "cd '$REPO' && bash '$HELPER' 7 --squash" 2>&1)"; rc=$?
check_eq "#1482 default pace: merged" "0" "$rc"
check_eq "#1482 default pace: 1, 2, then 3 minutes at most" "60 120 180 180 180" "$(tr '\n' ' ' < "$ST/sleeps" | sed 's/ $//')"

# A wait longer than the heartbeat is said again inside it, naming the next look, so the log never
# goes quiet for longer than the heartbeat.
fresh "$OLD" 0 "$PENDING"
for _ in 1 2 3 4 5 6; do printf ':\n' >> "$ST/on-sleep"; done
printf '%s\n' "cp '$WORKDIR/green' \"\$ST/rollup\"" >> "$ST/on-sleep"
out="$(MWR_POLL_MAX_SECONDS=120 MWR_HEARTBEAT_SECONDS=100 run 7 --squash)"; rc=$?
check_eq "#1482 sliced wait: merged" "0" "$rc"
check "#1482 a heartbeat inside a long wait names the next look" "[3m 10s] Head ${OLD:0:7}: waiting, checks still running (1 of 1). Still waiting, for 3m 10s so far; next look in 20s." "$out"

# A rate limit answer: paused until GitHub's reset time, said as a rate limit, and never as checks.
fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$LIMITED" > "$ST/view-fails"
printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n{"resources":{"core":{"limit":5000,"remaining":4989,"reset":1003600},"graphql":{"limit":5000,"remaining":0,"reset":1000300}}}\n' > "$ST/probe"
out="$(run 7 --squash)"; rc=$?
check_eq "#1482 rate limited: merged once it lifted" "0" "$rc"
check "#1482 it says GitHub refused for its rate limit" "for its rate limit" "$out"
check "#1482 naming the reset time as the reason" "graphql" "$out"
check_eq "#1482 the next read waits until the reset" "yes" "$( [ "$(sed -n 2p "$ST/view-times")" -ge 1000300 ] && echo yes || echo no)"
check_eq "#1482 and is not asked again in between: the refused read, the one at the reset, the read back" "3" "$(grep -c . "$ST/view-times")"
check "#1482 the heartbeat while paused says paused for the rate limit" "Still paused for GitHub's rate limit" "$out"
check_not "#1482 and never that it waits on checks" "checks still running" "$out"
check_eq "#1482 the limits are asked once" "1" "$(grep -c . "$ST/probe-times")"
check_not "#1482 a rate limit is not a stop" "Stopped" "$out"

# An update refused for a burst limit naming no time: paused a minute, then updated once.
fresh "$OLD" 4 "$GREEN"
printf '%s\n' "$NEW" > "$ST/next-heads"; : > "$ST/update-limited"
printf 'HTTP/2.0 200 OK\r\n\r\n{"resources":{"core":{"limit":5000,"remaining":4989,"reset":1003600},"graphql":{"limit":5000,"remaining":4900,"reset":1003600}}}\n' > "$ST/probe"
printf '%s\n%s\n' ":" "printf '%s' '$GREEN' > \"\$ST/rollup\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#1482 an update refused for the rate limit is made once it lifts" "0" "$rc"
check_eq "#1482 exactly one update landed" "1" "$(grep -c . "$ST/update-times")"
check "#1482 the pause is a minute when GitHub names no time" "named no time" "$out"
check_eq "#1482 and the update came a minute after the refusal" "yes" "$( [ "$(head -1 "$ST/update-times")" -ge 1000060 ] && echo yes || echo no)"

# Two loops in one session share the cap: another loop's four looks this minute make this one wait.
fresh "$OLD" 0 "$GREEN"
for _ in 1 2 3 4; do CLAUDE_CODE_SESSION_ID=mwr-suite bash -c ". '$DIR/lib/gh-poll.sh' && ghp_take 1000000" >/dev/null 2>&1; done
out="$(GH_POLL_PER_MINUTE=4 run 7 --squash)"; rc=$?
check_eq "#1482 held by the session's cap: still merged" "0" "$rc"
check "#1482 it says it waits for the session's next look, and why" "the most one session may" "$out"
check_eq "#1482 its first read waits until the oldest look is a minute old" "1000060" "$(head -1 "$ST/view-times")"
# Control: another session's looks do not hold it.
fresh "$OLD" 0 "$GREEN"
for _ in 1 2 3 4; do CLAUDE_CODE_SESSION_ID=another bash -c ". '$DIR/lib/gh-poll.sh' && ghp_take 1000000" >/dev/null 2>&1; done
out="$(GH_POLL_PER_MINUTE=4 run 7 --squash)"; rc=$?
check_eq "#1482 control: another session's looks leave it free" "1000000" "$(head -1 "$ST/view-times")"
check_not "#1482 control: and it says nothing of a cap" "the most one session may" "$out"

# =================================================================================================
# 22. A per repository turn (claude-config#1515). On 2026-10-22 PET #1885 sat here about 112 minutes:
#     four other pull requests merged under it while its 23 minute checks ran, each one restarting
#     them. Now a run takes the repository's turn before it updates, waits or merges, and holds it
#     until it has merged or stopped; another run waits for it, saying so as its own state with the
#     holder and how long it has held it. A holder whose run has gone is passed over at once, and
#     one that has held it past MWR_TURN_HOLD_SECONDS is passed over by a run waiting for it. The
#     queue itself is proved in test-merge-turn.sh; here, what the helper does with it.
# =================================================================================================
TURN_LIB="$DIR/lib/merge-turn.sh"
LIVE_START="$(ps -o lstart= -p 1 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//')"
# take-turn <slug> <pr> [pid] [start]: another run joins the line, by default a live one (pid 1,
# which always runs, with its own start time).
cat > "$BIN/take-turn" <<EOS
#!/usr/bin/env bash
. "$TURN_LIB"
TURN_PID="\${3:-1}"; TURN_PID_START="\${4:-$LIVE_START}"
turn_open "\$1" && turn_join "\$2" "\$(cat "\$ST/clock")"
EOS
chmod +x "$BIN/take-turn"
tickets(){ ls "$MWR_TURN_DIR/${1:-acme/widget}" 2>/dev/null | grep -E '^[0-9]+$' | tr '\n' ' ' | sed 's/ $//'; }
ticket_prs(){ local t out=""; for t in $(tickets "$@"); do out="$out $(sed -n 's/^pr //p' "$MWR_TURN_DIR/${1:-acme/widget}/$t")"; done; printf '%s' "${out# }"; }

# A live run holds the turn: this one waits, updating and merging nothing, and says it is waiting for
# its turn, naming the holder and how long it has held it, never as a wait on checks.
fresh "$OLD" 2 "$GREEN"; printf '%s\n' "$NEW" > "$ST/next-heads"
"$BIN/take-turn" acme/widget 9
out="$(MWR_MAX_POLLS=3 run 7 --squash)"; rc=$?
check_eq "#1515 behind a live holder it is still waiting when its looks run out" "3" "$rc"
check "#1515 saying it waits for its turn, and who holds it" "waiting for its turn to merge in acme/widget, which #9 holds (1 ahead of it in line)." "$out"
check "#1515 and how long #9 has held it" "#9 has held it for 0s, of the 60m any one pull request may hold it." "$out"
check_not "#1515 a wait for the turn is never said as a wait on checks" "checks still running" "$out"
check "#1515 out of time, it names the turn it was waiting for" "is waiting for its turn to merge in acme/widget, which #9 holds" "$out"
check_eq "#1515 nothing was updated while another held the turn" "0" "$(count gh-calls 'pr update-branch')"
check_eq "#1515 nothing was merged" "0" "$(count gh-calls 'pr merge')"
check_eq "#1515 no lessons review was started for a head it may not merge yet" "0" "$(count review-calls 'start')"
check_eq "#1515 on stopping it gave up its place, and #9's is kept" "9" "$(ticket_prs)"

# The heartbeat says the holder's time again as it grows, though the wait's own line is unchanged.
fresh "$OLD" 0 "$GREEN"
"$BIN/take-turn" acme/widget 9
out="$(MWR_MAX_POLLS=6 MWR_HEARTBEAT_SECONDS=60 run 7 --squash)"; rc=$?
check "#1515 a heartbeat names how long the holder has held it by then" "#9 has held it for 1m 00s, of the 60m any one pull request may hold it. Still waiting, for 1m 00s so far." "$out"
check_eq "#1515 and the wait's line is said once, then only on the heartbeat" "1" "$(grep -c 'which #9 holds' <<<"$(grep -v 'Still waiting' <<<"$out" | grep -v 'Out of time')")"

# The holder finishes: the turn passes, and this one merges.
fresh "$OLD" 0 "$GREEN"
"$BIN/take-turn" acme/widget 9
printf '%s\n' "rm -f \"\$MWR_TURN_DIR/acme/widget/1\" \"\$MWR_TURN_DIR/acme/widget/1.head\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#1515 once the holder leaves, the next in line merges" "0" "$rc"
check "#1515 saying it is its turn now, after how long" "It is #7's turn to merge in acme/widget now, after waiting 30s for it" "$out"
check "#1515 and merging that head" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_eq "#1515 its place is given up once merged" "" "$(tickets)"

# A holder whose run has gone (L409): passed over at once, with no wait at all.
fresh "$OLD" 0 "$GREEN"
"$BIN/take-turn" acme/widget 9 99999999 "Thu Jan  1 00:00:00 1970"
out="$(run 7 --squash)"; rc=$?
check_eq "#1515 a dead holder does not hold up a merge" "0" "$rc"
check "#1515 saying whose place was passed over, and why" "#9's place in line was passed over: its run (pid 99999999) is no longer running." "$out"
check_eq "#1515 without a single wait" "0" "$(count sleeps .)"
check_eq "#1515 and leaves no ticket behind" "" "$(tickets)"

# A live holder past the bound (L523): the waiting run takes the turn over, on the injected clock.
fresh "$OLD" 0 "$GREEN"
"$BIN/take-turn" acme/widget 9
out="$(MWR_TURN_HOLD_SECONDS=90 run 7 --squash)"; rc=$?
check_eq "#1515 a holder past its bound does not hold up a merge for ever" "0" "$rc"
check "#1515 saying whose turn ran out, after how long" "#9's turn ran out after 1m 30s, past the 1m 30s any one pull request may hold it" "$out"
check_eq "#1515 after waiting the bound, in fake time" "3" "$(count sleeps 30)"
check "#1515 and merging" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"

# Different repositories never block each other.
fresh "$OLD" 0 "$GREEN"
"$BIN/take-turn" acme/other 9
out="$(run 7 --squash)"; rc=$?
check_eq "#1515 a holder in another repository does not hold up this one" "0" "$rc"
check_not "#1515 and this one never waits for it" "waiting for its turn" "$out"
check_eq "#1515 the other repository's holder is untouched" "9" "$(ticket_prs acme/other)"

# Its own turn taken over while it waits on its checks: it joins the line again and never merges
# under the run that took it over, though its checks have gone green.
fresh "$OLD" 0 "$PENDING"
printf '%s\n' "rm -f \"\$MWR_TURN_DIR/acme/widget/1\" \"\$MWR_TURN_DIR/acme/widget/1.head\"; \"\$BIN_DIR/take-turn\" acme/widget 9; printf '%s' '$GREEN' > \"\$ST/rollup\"" > "$ST/on-sleep"
out="$(BIN_DIR="$BIN" MWR_MAX_POLLS=4 run 7 --squash)"; rc=$?
check_eq "#1515 a run whose turn was taken over does not merge" "3" "$rc"
check "#1515 it took the turn first" "Took the turn to merge in acme/widget" "$out"
check "#1515 then says its place is gone and joins the line again" "#7's place in the line to merge in acme/widget is gone" "$out"
check "#1515 and waits behind the run that took it" "which #9 holds (1 ahead of it in line)" "$out"
check_eq "#1515 nothing merged under #9" "0" "$(count gh-calls 'pr merge')"

# The same, at the last moment: taken over while its review is asked, just before the gates.
fresh "$OLD" 0 "$GREEN"
printf '%s\n' "rm -f \"\$MWR_TURN_DIR/acme/widget/1\" \"\$MWR_TURN_DIR/acme/widget/1.head\"; \"\$BIN_DIR/take-turn\" acme/widget 9" > "$ST/on-review"
out="$(BIN_DIR="$BIN" MWR_MAX_POLLS=2 run 7 --squash)"; rc=$?
check_eq "#1515 the turn is asked again right before the merge" "3" "$rc"
check_eq "#1515 so nothing merged under the run that took it" "0" "$(count gh-calls 'pr merge')"
check_eq "#1515 and no gate was asked about a merge it may not make" "" "$(cat "$ST/red-gate-payloads" 2>/dev/null)"

# A run stopped by a signal while it holds the turn gives it up, so the next in line is not left to
# wait for the bound. The step signals the helper itself, the fake sleep's parent.
fresh "$OLD" 0 "$PENDING"
printf '%s\n' "kill -TERM \$PPID" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#1515 a holder sent TERM stops" "143" "$rc"
check "#1515 having held the turn" "Took the turn to merge in acme/widget" "$out"
check_eq "#1515 and gives its place up as it goes" "" "$(tickets)"

# A turn that cannot be taken is said, and the merge goes on as it did before: the turn decides only
# the order helpers merge in, and every gate still judges the merge.
fresh "$OLD" 0 "$GREEN"
: > "$WORKDIR/turns-not-a-folder"
out="$(MWR_TURN_DIR="$WORKDIR/turns-not-a-folder" run 7 --squash)"; rc=$?
check_eq "#1515 a turn folder that cannot be made does not stop a merge" "0" "$rc"
check "#1515 but says it goes on without a turn, and where" "Could not take a turn to merge in acme/widget (could not make $WORKDIR/turns-not-a-folder/acme/widget)" "$out"
check "#1515 and merges through the gates as before" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
