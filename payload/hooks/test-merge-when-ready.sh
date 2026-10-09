#!/usr/bin/env bash
# Tests for lib/merge-when-ready.sh (claude-config#851): a pull request sent back for being behind its
# base is updated, waited on and merged in one step, and only ever through the same gates a typed
# merge meets.
#
# A fake gh holds the pull request's state in files (head, checks, distance behind, merged), and
# moves it the way GitHub does: `pr update-branch` gives the pull request a NEW head with its checks
# pending. The sleep is injected, and each fake sleep runs a step the test chose (checks go green,
# main moves again), so nothing here waits on a clock (L524, L290). The two gates and the review
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
case "$*" in
  "auth status"*) exit 0 ;;
  "pr view"*)
    state=OPEN; [ -e "$ST/merged" ] && state=MERGED
    ms=CLEAN; [ "$(rd behind)" != 0 ] && ms=BEHIND
    jq -nc --arg h "$(rd head)" --arg s "$state" --arg ms "$ms" --argjson r "$(rd rollup)" \
      '{number:7,state:$s,headRefOid:$h,headRefName:"feat/x",baseRefName:"main",statusCheckRollup:$r,mergeStateStatus:$ms,mergeable:"MERGEABLE",url:"https://github.com/acme/widget/pull/7"}'
    ;;
  "api repos/acme/widget/compare/"*)
    b="$(rd behind)"; st=ahead; [ "$b" != 0 ] && st=diverged
    printf '{"status":"%s","ahead_by":1,"behind_by":%s}\n' "$st" "$b"
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
chmod +x "$STUBS"/*.sh
export MWR_RED_GATE="$STUBS/red-gate.sh" MWR_REVIEW_GATE="$STUBS/review-gate.sh" MWR_REVIEW_LIB="$STUBS/pr-review.sh"

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
count(){ [ -f "$ST/$1" ] && grep -c -- "$2" "$ST/$1" || true; }

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
#    it looks once a minute, never every 30 seconds.
# =================================================================================================
fresh "$OLD" 0 "$PENDING"
printf '%s\n' "printf '%s' '$GREEN' > \"\$ST/rollup\"" > "$ST/on-sleep"
out="$(env -u MWR_POLL_SECONDS bash -c "cd '$REPO' && bash '$HELPER' 7 --squash" 2>&1)"; rc=$?
check_eq "#1014 with no poll setting it still waits and merges" "0" "$rc"
check_eq "#1014 the wait between looks defaults to 60 seconds" "60" "$(cat "$ST/sleeps" 2>/dev/null)"
check_eq "#1014 one pull request read per look, plus the read back after the merge" "3" "$(count gh-calls 'pr view 7')"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
