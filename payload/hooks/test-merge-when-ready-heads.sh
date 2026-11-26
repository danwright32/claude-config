#!/usr/bin/env bash
# Tests for lib/merge-when-ready.sh, sections 11 to 21 of what was one suite, test-merge-when-ready.sh:
# main that keeps moving, pull requests stacked on the merged branch, the REAL checks gate's rerun
# hint, minor findings and the step back after three rounds of findings, a head GitHub shows late or
# an update it does not show, no merge method passed, the heartbeat while it waits, the merged
# branch's agent worktree, and the shared polling policy.
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
mwr_default_deadline
check_eq "#1271 with no deadline set it runs out only after three hours" "3 10800" "$rc $default_deadline"

# THE RATIO (L227): is-it-live asks GitHub about a merge this helper makes in the background for
# WAIT_MS after the command, so that window must stay well past the helper's deadline, or a merge
# landing late in the run is never owed its card. Read from the mod's own source, here, so raising
# either number without the other fails.
mwr_wait_ms
if [[ "$wait_expr" =~ ^[0-9*]+$ ]]; then
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
# line_of is lib/merge-when-ready-harness.sh's, since section 16 reads it too.

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

# GitHub moved a stacked pull request itself and answers the move with "A pull request already
# exists" (claude-config#2431): on 2026-11-07 this left the branch twice (#2390 with #2419, #2377
# with #2405) and called it a move GitHub would not make. Its base is read again, and one already on
# the merged one's base counts as moved, so the branch is deleted in the same run.
fresh "$OLD" 0 "$GREEN"
printf '8\n9\n' > "$ST/stacked"
: > "$ST/retarget-already-8"
out="$(run 7 --squash --delete-branch)"; rc=$?
check_eq "#2431 a stacked pull request GitHub already moved does not leave the branch" "0" "$rc"
check_eq "#2431 the branch is deleted in the same run" "feat/x" "$(cat "$ST/deleted" 2>/dev/null)"
check_eq "#2431 and nothing was closed" "" "$(cat "$ST/closed" 2>/dev/null)"
check "#2431 judged by its base, read again" "api repos/acme/widget/pulls/8" "$(cat "$ST/gh-calls")"
check "#2431 it says GitHub had already moved it" "GitHub had already moved #8 onto main" "$out"
check "#2431 and still names the one it moved itself" "#9" "$out"
check_not "#2431 never calling it a move GitHub would not make" "would not move" "$out"

# Control: the same answer about a pull request still based on the branch is the refusal it was.
fresh "$OLD" 0 "$GREEN"
printf '8\n' > "$ST/stacked"
: > "$ST/retarget-exists-8"
out="$(run 7 --squash --delete-branch)"; rc=$?
check_eq "#2431 that answer with the pull request still on the branch leaves it in place" "4" "$rc"
check_eq "#2431 not deleted" "0" "$(count gh-calls 'X DELETE')"
check "#2431 named as not moved, with GitHub's words" "would not move #8" "$out"
check "#2431 carrying what GitHub said" "A pull request already exists" "$out"

# Control: a base that cannot be read again is not taken for moved.
fresh "$OLD" 0 "$GREEN"
printf '8\n' > "$ST/stacked"
: > "$ST/retarget-already-8"
printf 'gh: Resource not accessible by integration (HTTP 403)\n' > "$ST/pull-down"
out="$(run 7 --squash --delete-branch)"; rc=$?
check_eq "#2431 a base that cannot be read again counts as not moved" "4" "$rc"
check "#2431 and says so with GitHub's first answer" "would not move #8" "$out"

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
# el, the seconds the injected clock has run, is lib/merge-when-ready-harness.sh's, since section 24
# (test-merge-when-ready-turn.sh) reads it too.

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

# A process standing in it keeps it. The process stays until it is stopped here, and the helper runs
# only once the system shows it standing in the worktree, read the way the check reads it (lsof, else
# /proc), so the case waits on the condition it is about rather than on how soon a busy Mac schedules
# a background job, and no lifetime of its own can end before the helper looks (L290, claude-config#2327).
stands_in(){ # stands_in <pid> <folder>: the system shows that process's working directory as the folder
  local o
  if command -v lsof >/dev/null 2>&1; then
    o="$(lsof -a -p "$1" -d cwd -F n 2>/dev/null)"; [[ $'\n'"$o"$'\n' == *$'\n'"n$2"$'\n'* ]]
  else [ "$(readlink "/proc/$1/cwd" 2>/dev/null)" = "$2" ]; fi
}
. "$DIR/lib/hang-wait.sh"
wt_fresh
(cd "$AGENT" && exec tail -f /dev/null) &
WBUSY=$!
if [ "$CAN_SEE_USE" -eq 1 ]; then
  # The shared ceiling only a hang reaches (lib/hang-wait.sh), so a process that never gets there
  # cannot hold the suite; that is its own failure, said as such.
  hang_wait 'stands_in "$WBUSY" "$AGENT"'
  check_eq "#2327 the busy process is seen standing in the worktree before the merge is asked" "yes" "$(stands_in "$WBUSY" "$AGENT" && echo yes || echo no)"
fi
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
# Outside a test run the worktree check named in the environment is never run (claude-config#2317):
# the installed check beside the helper judges, and here removes, the merged branch's worktree.
wt_fresh
out="$(fake_in "$WREPO" bash "$FAKE_HELPER" 7 --squash)"; rc=$?
check_eq "#2317 outside a test run the worktree check named in the environment is never run" "" "$(cat "$ST/decoys-asked" 2>/dev/null)"
check "#2317 the installed worktree check is run instead" "check-stale-worktrees.sh" "$(cat "$ST/installed-asked" 2>/dev/null)"
check_eq "#2317 and its removal happens" "no" "$(there)"

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
# LIMITED, GitHub's rate limit refusal, is set by lib/merge-when-ready-harness.sh.

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

echo
mwr_harness_result
