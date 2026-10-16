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
case "$*" in
  "auth status"*) exit 0 ;;
  "pr view"*)
    if [ -e "$ST/merged" ]; then fail_read readback; else fail_read view; fi
    state=OPEN; [ -e "$ST/merged" ] && state=MERGED
    ms=CLEAN; [ "$(rd behind)" != 0 ] && ms=BEHIND
    # labels holds the pull request's labels as JSON, for the changelog record gate (#1178).
    lb="$(rd labels)"
    jq -nc --arg h "$(rd head)" --arg s "$state" --arg ms "$ms" --argjson r "$(rd rollup)" --argjson l "${lb:-[]}" \
      '{number:7,state:$s,headRefOid:$h,headRefName:"feat/x",baseRefName:"main",statusCheckRollup:$r,mergeStateStatus:$ms,mergeable:"MERGEABLE",url:"https://github.com/acme/widget/pull/7",author:{login:"dwright-pennie"},labels:$l,body:""}'
    ;;
  "api repos/acme/widget/compare/"*)
    fail_read compare
    b="$(rd behind)"; st=ahead; [ "$b" != 0 ] && st=diverged
    printf '{"status":"%s","ahead_by":1,"behind_by":%s}\n' "$st" "$b"
    ;;
  "api repos/acme/widget/actions/runs"*)
    # The workflow runs GitHub has created for the head (claude-config#1087): none unless a test
    # writes some to runs, the shape a repository whose runs have all finished answers with too.
    fail_read runs
    if [ -s "$ST/runs" ]; then cat "$ST/runs"; else printf '%s\n' '{"total_count":0,"workflow_runs":[]}'; fi
    ;;
  "pr update-branch"*)
    [ -e "$ST/update-fails" ] && { echo "GraphQL: merge conflict between base and head (updatePullRequestBranch)" >&2; exit 1; }
    nh="$(head -1 "$ST/next-heads")"; tail -n +2 "$ST/next-heads" > "$ST/next-heads.tmp"; mv "$ST/next-heads.tmp" "$ST/next-heads"
    printf '%s' "$nh" > "$ST/head"; printf '0' > "$ST/behind"; cat "$ST/rollup-after-update" > "$ST/rollup"
    ;;
  "pr merge"*)
    pinned="$(printf '%s\n' "$*" | sed -nE 's/.*--match-head-commit ([0-9a-f]+).*/\1/p')"
    [ "$pinned" = "$(rd head)" ] || { echo "Head branch was modified. Review and try the merge again." >&2; exit 1; }
    : > "$ST/merged"
    ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 3 ;;
esac
EOS
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# --- the injected sleep: runs the next step the test queued, then returns at once -----------------
cat > "$BIN/fake-sleep" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$ST/sleeps"
if [ -s "$ST/on-sleep" ]; then
  step="$(head -1 "$ST/on-sleep")"; tail -n +2 "$ST/on-sleep" > "$ST/on-sleep.tmp"; mv "$ST/on-sleep.tmp" "$ST/on-sleep"
  eval "$step"
fi
EOS
chmod +x "$BIN/fake-sleep"
export MWR_SLEEP="$BIN/fake-sleep"
export MWR_POLL_SECONDS=30
export MWR_READ_RETRY_SECONDS=7
export MWR_NO_CHECKS_GRACE_SECONDS=0

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
chmod +x "$STUBS"/*.sh
export MWR_RED_GATE="$STUBS/red-gate.sh" MWR_REVIEW_GATE="$STUBS/review-gate.sh" MWR_REVIEW_LIB="$STUBS/pr-review.sh"
export MWR_CHANGELOG_GATE="$STUBS/changelog-gate.sh"

# --- a checkout of acme/widget to run from ---------------------------------------------------------
REPO="$(cd "$WORKDIR" && pwd -P)/widget"
git init -q "$REPO"
git -C "$REPO" remote add origin https://github.com/acme/widget.git

fresh(){ # fresh <head> <behind> <rollup>
  rm -rf "$ST"; mkdir -p "$ST"
  printf '%s' "$1" > "$ST/head"; printf '%s' "$2" > "$ST/behind"; printf '%s' "$3" > "$ST/rollup"
  printf '%s' "$PENDING" > "$ST/rollup-after-update"
  : > "$ST/next-heads"; : > "$ST/on-sleep"
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
check "#851 the merge pins the head it judged" "pr merge 7 --repo acme/widget --squash --delete-branch --match-head-commit $OLD" "$(cat "$ST/gh-calls")"
check "#851 the checks gate is asked about that exact merge command" "gh pr merge 7 --repo acme/widget --squash --delete-branch --match-head-commit $OLD" "$(cat "$ST/red-gate-payloads")"
check "#851 and so is the lessons review gate" "gh pr merge 7 --repo acme/widget --squash --delete-branch --match-head-commit $OLD" "$(cat "$ST/review-gate-payloads")"
check "#851 the review is asked about the pull request's head, base and branch" "check --dir $REPO --sha $OLD --base-ref origin/main --branch feat/x" "$(cat "$ST/review-calls")"
check "#1161 and is started naming the pull request, whose comments it reads" "start --dir $REPO --sha $OLD --base-ref origin/main --branch feat/x --pr 7" "$(cat "$ST/review-calls")"

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
# 4. Main moves again while the new head is being checked: updated again, and bounded.
# =================================================================================================
fresh "$OLD" 2 "$GREEN"
printf '%s\n%s\n' "$NEW" "$NEWER" > "$ST/next-heads"
printf '%s\n%s\n' "printf '%s' '$GREEN' > \"\$ST/rollup\"; printf 3 > \"\$ST/behind\"" "printf '%s' '$GREEN' > \"\$ST/rollup\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#851 main moving again means a second update, then the merge" "0" "$rc"
check_eq "#851 two updates" "2" "$(count gh-calls 'pr update-branch 7')"
check "#851 merging the newest head" "--match-head-commit $NEWER" "$(grep 'pr merge' "$ST/gh-calls")"

fresh "$OLD" 2 "$GREEN"
printf '%s\n%s\n' "$NEW" "$NEWER" > "$ST/next-heads"
printf '%s\n' "printf '%s' '$GREEN' > \"\$ST/rollup\"; printf 3 > \"\$ST/behind\"" > "$ST/on-sleep"
out="$(MWR_MAX_UPDATES=1 run 7 --squash)"; rc=$?
check_eq "#851 past its update limit it stops rather than chasing main for ever" "1" "$rc"
check "#851 saying how many times it updated" "updated it 1 time" "$out"
check_eq "#851 and nothing was merged" "0" "$(count gh-calls 'pr merge')"

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
check "#1178 the changelog gate judges the exact pinned merge command" "gh pr merge 7 --repo acme/widget --squash --delete-branch --match-head-commit $OLD" "$(cat "$ST/changelog-gate-payloads" 2>/dev/null)"
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

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
