#!/usr/bin/env bash
# Tests for the lessons review BEFORE a push (claude-config#599): pr-review-push-gate.sh (PreToolUse
# on a push), the commit time start in ai-review-on-pr.sh (PostToolUse on a commit), the push mode
# of lib/pr-review.sh check, and what the merge gate (pr-review-gate.sh) makes of a review a push
# already ran.
#
# Every outcome the push gate names is PRODUCED here (L151): findings not yet read (refused, then
# allowed on their key), 0 findings (allowed), a review that cannot run (refused in its own words),
# still running past the push's wait (refused with the time waited), the override, a push of the
# default branch, and a commit and push in one command. And the merge gate stays exactly as strict:
# a key presented to a PUSH does not read the findings for a MERGE, the merge reuses the push's
# review rather than starting a second, and a review whose range does not cover the pull request's
# is run again rather than reused.
#
# A fake claude and a fake gh on PATH stand in for the real ones, the state directory is the scratch
# directory's, the repository is a throwaway with a bare origin, and the push gate's sleep and clock
# are injected, so nothing here waits for real or reaches the network or Dan's reviews (L2, L524).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/pr-review.sh"
PUSH_GATE="$DIR/pr-review-push-gate.sh"
COMMIT_HOOK="$DIR/ai-review-on-pr.sh"
MERGE_GATE="$DIR/pr-review-gate.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1500}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then ok; else bad "$1"; echo "  must not contain: $2"; echo "  actual: ${3:0:1500}"; fi; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }

export AI_REVIEW_STATE_DIR="$WORKDIR/state"
export PR_REVIEW_DEADLINE_SECONDS=30
export AI_REVIEW_HOST="Daniels-MacBook-Pro-2"
unset AI_REVIEW_HOSTS SKIP_PR_REVIEW PR_REVIEW_READ 2>/dev/null || true

# --- the fake claude: records each call, answers from the environment the test sets ---
FAKEBIN="$WORKDIR/bin"; mkdir -p "$FAKEBIN"
export FAKE_LOG="$WORKDIR/fakelog"; mkdir -p "$FAKE_LOG"
cat > "$FAKEBIN/claude" <<'EOS'
#!/usr/bin/env bash
printf 'called\n' >> "$FAKE_LOG/calls"
cat > "$FAKE_LOG/stdin"
sleep "${FAKE_CLAUDE_SLEEP:-0}"
if [ -n "${FAKE_CLAUDE_OUT:-}" ]; then printf '%s\n' "$FAKE_CLAUDE_OUT"; exit 0; fi
printf 'App/Sync.swift:3: deleteEvent still swallows the error createEvent now reports (L215). Should be: report it the same way. [severity: major]\n'
EOS
chmod +x "$FAKEBIN/claude"
cat > "$FAKEBIN/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG/gh-calls"
case "$*" in
  "auth status"*) exit 0 ;;
  "pr view"*) [ -f "$FAKE_LOG/pr-view.json" ] && { cat "$FAKE_LOG/pr-view.json"; exit 0; }
              echo "no pull requests found for branch" >&2; exit 1 ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 3 ;;
esac
EOS
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"
calls(){ if [ -f "$FAKE_LOG/calls" ]; then grep -c . "$FAKE_LOG/calls"; else echo 0; fi; }

# --- the injected sleep and clock (L524): the clock is a number in a file, and a sleep moves it on
#     by what it was asked for. With FAKE_SLEEP_WAITS set the sleep also waits, bounded, for every
#     running review to finish, so "the review finished while the push waited" is produced on a
#     condition rather than a guess at how long a review takes (L290). ---
export FAKE_CLOCK_FILE="$WORKDIR/clock"
cat > "$FAKEBIN/fake-clock" <<'EOS'
#!/usr/bin/env bash
cat "$FAKE_CLOCK_FILE" 2>/dev/null || echo 1000
EOS
cat > "$FAKEBIN/fake-sleep" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FAKE_LOG/sleeps"
now="$(cat "$FAKE_CLOCK_FILE" 2>/dev/null || echo 1000)"
echo $((now + ${1%.*})) > "$FAKE_CLOCK_FILE"
if [ -n "${FAKE_SLEEP_WAITS:-}" ]; then
  t0=$SECONDS
  while ls "$AI_REVIEW_STATE_DIR"/*.pending >/dev/null 2>&1 && [ $((SECONDS - t0)) -lt 20 ]; do /bin/sleep 0.1; done
fi
exit 0
EOS
chmod +x "$FAKEBIN/fake-clock" "$FAKEBIN/fake-sleep"
export PR_REVIEW_PUSH_CLOCK="$FAKEBIN/fake-clock"
export PR_REVIEW_PUSH_SLEEP="$FAKEBIN/fake-sleep"
export PR_REVIEW_PUSH_POLL_SECONDS=3
export PR_REVIEW_PUSH_WAIT_SECONDS=9
sleeps(){ if [ -f "$FAKE_LOG/sleeps" ]; then grep -c . "$FAKE_LOG/sleeps"; else echo 0; fi; }

# --- fixture: a bare origin, main, and a feature branch ---
ORIGIN="$WORKDIR/origin.git"
git init -q --bare "$ORIGIN"
REPO="$WORKDIR/repo"
mkdir -p "$REPO/App"
git init -q "$REPO"
G(){ git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
G symbolic-ref HEAD refs/heads/main
printf 'func createEvent() {}\nfunc deleteEvent() {}\n' > "$REPO/App/Sync.swift"
G add App/Sync.swift
G commit -q -m seed
G remote add origin "$ORIGIN"
G push -q -u origin main 2>/dev/null
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
G remote set-head origin main 2>/dev/null || true
G checkout -q -b feat/sync
printf 'func createEvent() throws {}\nfunc deleteEvent() {}\n' > "$REPO/App/Sync.swift"
G commit -q -am "one"
HEAD_SHA="$(G rev-parse HEAD)"
BASE_SHA="$(G merge-base origin/main HEAD)"

KEY="$(bash -c ". '$DIR/lib/ai-review-common.sh'; ar_repo_key '$REPO'")"
final_of(){ printf '%s/%s-pr-%s.txt' "$AI_REVIEW_STATE_DIR" "$KEY" "$1"; }
wait_final(){ # bounded, on the condition (L290)
  local f; f="$(final_of "$1")"; local t0=$SECONDS
  while [ ! -e "$f" ] && [ -e "$f.pending" ] && [ $((SECONDS - t0)) -lt 40 ]; do sleep 0.1; done
  [ -e "$f" ]
}
reset_state(){ rm -rf "$AI_REVIEW_STATE_DIR" "$FAKE_LOG"; mkdir -p "$FAKE_LOG"; echo 1000 > "$FAKE_CLOCK_FILE"; }
meta(){ awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit } /^$/ { exit }' "$1"; }
key_in(){ [[ "$1" =~ PR_REVIEW_READ=([a-f0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"; }
pre_payload(){ python3 -c 'import json,sys; print(json.dumps({"session_id":"s1","cwd":sys.argv[1],"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[2]}}))' "$1" "$2"; }
fire_push(){ pre_payload "$REPO" "$1" | bash "$PUSH_GATE" 2>&1; }
fire_merge(){ pre_payload "$REPO" "$1" | bash "$MERGE_GATE" 2>&1; }
fire_commit(){ # fire_commit <command> <exit code>
  python3 -c 'import json,sys; print(json.dumps({"session_id":"s1","cwd":sys.argv[1],"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[2]},"tool_response":{"exit_code":int(sys.argv[3])}}))' "$REPO" "$1" "$2" \
    | bash "$COMMIT_HOOK" 2>&1
}

# ===========================================================================================
# 1. Recognising a commit in command position, never a mention of one (L673).
# ===========================================================================================
is_commit(){ bash -c ". '$DIR/lib/push-scope.sh'; ps_is_git_commit \"\$1\"" _ "$1"; }
for c in 'git commit -m x' 'git -C /a/b commit -F msg.txt' 'rtk git commit --amend --no-edit' \
         'cd /tmp/x && git commit -q -m y' 'GIT_AUTHOR_NAME=a git commit -m z' '(git commit -m w)'; do
  is_commit "$c" && ok || bad "a commit is recognised: $c"
done
for c in 'echo "git commit -m x"' 'git log --grep commit' 'git status' \
         $'cat <<EOF > notes.md\ngit commit -m x\nEOF' 'git push origin feat'; do
  is_commit "$c" && bad "a command that only mentions a commit is not one: $c" || ok
done
# The push recogniser still answers as before after sharing its walker with the commit one.
is_push(){ bash -c ". '$DIR/lib/push-scope.sh'; ps_is_git_push \"\$1\"" _ "$1"; }
is_push 'git push -u origin feat' && ok || bad "a push is still a push"
is_push '(cd x && git push)' && ok || bad "a push closing a subshell is still a push"
is_push 'git commit -m push' && bad "a commit whose message says push is not a push" || ok

# ===========================================================================================
# 2. A push with findings nobody has read is refused, with the findings and their key; the same
#    push with the key goes through. The push waited for the review rather than refusing at once.
# ===========================================================================================
reset_state
out="$(fire_push "echo hello")"; rc=$?
check_eq "a command that pushes nothing passes" "0" "$rc"
check_eq "and says nothing" "" "$out"
check_eq "and starts no review" "0" "$(calls)"

out="$(FAKE_SLEEP_WAITS=1 fire_push "git push -u origin feat/sync")"; rc=$?
check_eq "a push whose review has unread findings is refused" "2" "$rc"
check "the refusal is about the push" "Refusing to push" "$out"
check "and carries the finding itself" "deleteEvent still swallows" "$out"
pk="$(key_in "$out")"
[ -n "$pk" ] && ok || bad "the refusal names a read key to push with: $out"
check "and tells the session to push with the key" "PR_REVIEW_READ=$pk <the push command>" "$out"
check_eq "one review ran" "1" "$(calls)"
[ "$(sleeps)" -ge 1 ] && ok || bad "the push waited for the review it started rather than refusing at once"
F="$(final_of "$HEAD_SHA")"
check_eq "the review is the whole branch's, from the merge base" "$BASE_SHA" "$(meta "$F" base)"

out="$(fire_push "git push -u origin feat/sync")"; rc=$?
check_eq "a second push without the key is refused again, the first refusal may have been hidden" "2" "$rc"
check "carrying the findings again" "deleteEvent still swallows" "$out"
out="$(fire_push "echo PR_REVIEW_READ=$pk && git push -u origin feat/sync")"; rc=$?
check_eq "a key only mentioned in another command does not count" "2" "$rc"
out="$(fire_push "PR_REVIEW_READ=$pk git push -u origin feat/sync")"; rc=$?
check_eq "the push carrying the key is allowed" "0" "$rc"
check "and says the findings were read" "this push presented their key" "$out"
out="$(fire_push "git push")"; rc=$?
check_eq "once read for a push, a later push of the same head is allowed" "0" "$rc"
check_eq "and no second review ran" "1" "$(calls)"

# ===========================================================================================
# 3. The merge gate is exactly as strict, and reuses the push's review rather than starting one.
# ===========================================================================================
printf '{"number":7,"headRefOid":"%s","baseRefName":"main","headRefName":"feat/sync"}\n' "$HEAD_SHA" > "$FAKE_LOG/pr-view.json"
out="$(fire_merge "gh pr merge 7 --squash")"; rc=$?
check_eq "a key presented to a PUSH does not read the findings for a MERGE" "2" "$rc"
check "the merge is refused with the findings" "deleteEvent still swallows" "$out"
check "in the merge's own words" "Refusing to merge until these are read" "$out"
check_eq "and the merge gate started no second review for the head the push reviewed" "1" "$(calls)"
out="$(fire_merge "PR_REVIEW_READ=$pk gh pr merge 7 --squash")"; rc=$?
check_eq "the key the push was shown is a key to this same review, so the merge accepts it" "0" "$rc"
check_eq "still one review" "1" "$(calls)"

# A review whose range does not cover the pull request's is not reused: a branch pushed while its
# pull request targets an older base was reviewed from main's merge base, and the merge must read
# everything the pull request brings (the push gate starts from the default branch).
reset_state
G branch -f release "$BASE_SHA"
printf 'more\n' > "$REPO/App/Other.swift"; G checkout -q main; G add App/Other.swift; G commit -q -m "main moves"
G push -q origin main 2>/dev/null
G push -q origin release 2>/dev/null
G checkout -q feat/sync
G merge -q --no-edit main 2>/dev/null
MERGED="$(G rev-parse HEAD)"
NEW_BASE="$(G merge-base origin/main HEAD)"
FAKE_CLAUDE_OUT='No issues found.' FAKE_SLEEP_WAITS=1 fire_push "git push origin feat/sync" >/dev/null
check_eq "the push reviewed from main's merge base" "$NEW_BASE" "$(meta "$(final_of "$MERGED")" base)"
check_eq "one review" "1" "$(calls)"
out="$(FAKE_CLAUDE_OUT='No issues found.' bash "$LIB" check --dir "$REPO" --sha "$MERGED" --base-ref origin/main 2>&1)"; rc=$?
check_eq "a merge into main reuses it" "0" "$rc"
check_eq "without a second review" "1" "$(calls)"
out="$(FAKE_CLAUDE_OUT='No issues found.' bash "$LIB" check --dir "$REPO" --sha "$MERGED" --base-ref origin/release 2>&1)"; rc=$?
check_eq "a merge into an older base does not reuse a review that left part of it unread" "3" "$rc"
check "and says why it is reviewing again" "does not cover" "$out"
wait_final "$MERGED" || bad "the wider review finished"
check_eq "the wider review reads from the older base" "$BASE_SHA" "$(meta "$(final_of "$MERGED")" base)"
check_eq "and it was a second review" "2" "$(calls)"
G checkout -q feat/sync; G reset -q --hard "$HEAD_SHA"

# ===========================================================================================
# 4. The other outcomes, each produced.
# ===========================================================================================
# 4a. 0 findings: allowed, saying so.
reset_state
out="$(FAKE_CLAUDE_OUT='No issues found.' FAKE_SLEEP_WAITS=1 fire_push "git push")"; rc=$?
check_eq "a push whose review found nothing is allowed" "0" "$rc"
check "and says it found nothing" "0 findings" "$out"

# 4b. still running past the push's wait: refused with how long it waited and the review's time,
#     after waiting no longer than the wait it was given, measured on the injected clock.
reset_state
out="$(FAKE_CLAUDE_SLEEP=3 fire_push "git push")"; rc=$?
check_eq "a push whose review is still running when its wait ends is refused" "2" "$rc"
check "saying the review is still running" "still running" "$out"
check "and how long this push waited for it" "waited 9s" "$out"
check_eq "it slept on the injected sleep, no further than its wait" "3" "$(sleeps)"
check_eq "and the clock it read moved by exactly that" "1009" "$(cat "$FAKE_CLOCK_FILE")"
wait_final "$HEAD_SHA" || bad "the slow review finished afterwards"
out="$(fire_push "git push")"; rc=$?
check_eq "the push after it finishes meets the findings" "2" "$rc"
check "carrying them" "deleteEvent still swallows" "$out"

# 4c. a review that cannot run: refused, in its own words, never as findings and never allowed (L42).
reset_state
NOCLAUDE="$WORKDIR/noclaude"; mkdir -p "$NOCLAUDE"
for d in /bin /usr/bin /usr/local/bin /opt/homebrew/bin "$FAKEBIN"; do
  [ -d "$d" ] || continue
  for t in "$d"/*; do
    b="$(basename "$t")"
    [ "$b" = claude ] && continue
    [ -e "$NOCLAUDE/$b" ] || ln -s "$t" "$NOCLAUDE/$b" 2>/dev/null
  done
done
out="$(pre_payload "$REPO" "git push" | PATH="$NOCLAUDE" bash "$PUSH_GATE" 2>&1)"; rc=$?
check_eq "a push whose review cannot run is refused" "2" "$rc"
check "saying the review could not run" "could not run" "$out"
check "and naming what is missing" "claude" "$out"
check "and the override, explained to Dan first" "SKIP_PR_REVIEW=1 <the push command>" "$out"
check_not "never as findings" "until these are read" "$out"

# 4d. the review's own checker missing: refused, never waved through (L42, L488).
reset_state
HOOKCOPY="$WORKDIR/hookcopy"; mkdir -p "$HOOKCOPY/lib"
cp "$PUSH_GATE" "$HOOKCOPY/"
for f in push-scope.sh merge-target.sh ai-review-common.sh shell-words.py; do
  [ -e "$DIR/lib/$f" ] && cp "$DIR/lib/$f" "$HOOKCOPY/lib/"
done
out="$(pre_payload "$REPO" "git push" | bash "$HOOKCOPY/pr-review-push-gate.sh" 2>&1)"; rc=$?
check_eq "a push gate without its checker refuses" "2" "$rc"
check "and says what is missing" "pr-review.sh" "$out"

# 4e. the override: allowed, with a line saying it was skipped.
reset_state
out="$(fire_push "SKIP_PR_REVIEW=1 git push")"; rc=$?
check_eq "the one command override lets the push through" "0" "$rc"
check "and says to tell Dan" "Tell Dan" "$out"
check_eq "without starting a review" "0" "$(calls)"

# 4f. a push of the default branch is not a branch push: no review, no wait.
reset_state
G checkout -q main
out="$(fire_push "git push origin main")"; rc=$?
check_eq "a push of the default branch is not gated" "0" "$rc"
check_eq "and starts no review" "0" "$(calls)"
G checkout -q feat/sync

# 4g. a commit and a push in one command: the head being pushed does not exist yet, so nothing can
#     have reviewed it. Refused, asking for the commit first, never judged on the old head.
reset_state
out="$(fire_push "git commit -m x && git push")"; rc=$?
check_eq "a commit chained to a push is refused" "2" "$rc"
check "asking for the commit on its own first" "commit first" "$out"
check_eq "and no review of the old head was started" "0" "$(calls)"

# 4h. a delete push sends no commits. Judged on the push's OWN segment: a delete flag anywhere else
#     in the command (another push, an rm) must not wave a real push through (L673; lessons review).
out="$(fire_push "git push origin --delete feat/old")"; rc=$?
check_eq "a push that only deletes a branch is not gated" "0" "$rc"
out="$(FAKE_SLEEP_WAITS=1 fire_push "git push -d origin feat/old; git push origin feat/sync")"; rc=$?
check_eq "a delete beside a real push does not exempt the real push" "2" "$rc"
check "the real push meets the findings" "deleteEvent still swallows" "$out"
out="$(fire_push "rm -d /tmp/nothing-here && git push origin feat/sync")"; rc=$?
check_eq "an rm -d before a push does not exempt it" "2" "$rc"

# ===========================================================================================
# 5. The commit starts the review, so it has usually finished by the push.
# ===========================================================================================
reset_state
out="$(fire_commit "git commit -m two" 1)"
check_eq "a failed commit starts nothing" "0" "$(calls)"
check_eq "and says nothing" "" "$out"
out="$(fire_commit "git commit -m two" 0)"
check "a commit on a branch starts the review of its head" "started" "$out"
wait_final "$HEAD_SHA" && ok || bad "the commit's review finished"
check_eq "one review" "1" "$(calls)"
out="$(FAKE_SLEEP_WAITS=1 fire_push "git push")"; rc=$?
check_eq "the push meets the commit's findings" "2" "$rc"
check_eq "without a second review" "1" "$(calls)"
check_eq "and without waiting" "0" "$(sleeps)"
reset_state
G checkout -q main
out="$(fire_commit "git commit -m on-main" 0)"
check_eq "a commit on the default branch starts no review" "0" "$(calls)"
G checkout -q feat/sync
out="$(fire_commit "echo 'git commit -m x'" 0)"
check_eq "a command that only mentions a commit starts no review" "0" "$(calls)"

# ===========================================================================================
# 6. The gate judges the repository the push runs in, read from the LAST cd before it on any line,
#    and never fires on a push that is only text (claude-config#1017). On 2026-10-09 a push from one
#    worktree, its cd on a line after a heredoc, was refused twice with another repository's
#    findings, and a read only command naming the push verb inside quoted test strings was refused
#    too. OTHER is a checkout standing on the default branch, which the gate does not hold, so a
#    push judged in the wrong one of the two repositories shows as the wrong exit code.
# ===========================================================================================
OTHER="$WORKDIR/other"
git clone -q "$ORIGIN" "$OTHER" 2>/dev/null
fire_push_in(){ pre_payload "$1" "$2" | bash "$PUSH_GATE" 2>&1; }

reset_state
out="$(FAKE_SLEEP_WAITS=1 fire_push_in "$OTHER" $'cat > /dev/null <<\'EOF\'\nit\'s a note\nEOF\ncd '"$REPO"' && git push -u origin feat/sync')"; rc=$?
check_eq "a push whose cd follows a heredoc is judged in the cd's repository, not the session's" "2" "$rc"
check "and meets that branch's findings" "deleteEvent still swallows" "$out"
check_eq "one review, of that branch" "1" "$(calls)"

reset_state
out="$(fire_push_in "$REPO" $'cd '"$REPO"$' && git status\ncd '"$OTHER"' && git push origin main')"; rc=$?
check_eq "of two cds before a push, the last one names the repository judged" "0" "$rc"
check_eq "so the default branch push it really is starts no review" "0" "$(calls)"

reset_state
out="$(fire_push_in "$REPO" $'# don\'t push from here\nbash t.sh \'cd /x && git push origin main\' "git push -u origin feat"')"; rc=$?
check_eq "a read only command naming the push verb only in a comment and quoted strings is not held" "0" "$rc"
check_eq "and the gate says nothing" "" "$out"
check_eq "and starts no review" "0" "$(calls)"

out="$(fire_push_in "$REPO" $'git commit -m "$(cat <<\'EOF\'\nfix: the gate read "cd /x; git push origin " as a push\nEOF\n)"')"; rc=$?
check_eq "a commit whose message quotes a push is not refused as a commit and a push" "0" "$rc"
check_eq "and the gate says nothing about it" "" "$out"

# A push after a reserved word was seen by no push gate; it is held now (#1017).
reset_state
out="$(FAKE_SLEEP_WAITS=1 fire_push_in "$OTHER" "cd $REPO; if true; then git push -u origin feat/sync; fi")"; rc=$?
check_eq "a push right after an if's then is held" "2" "$rc"
check "and meets the branch's findings" "deleteEvent still swallows" "$out"
out="$(fire_push_in "$OTHER" "for r in a; do git -C $REPO push origin feat/sync; done")"; rc=$?
check_eq "a git -C push inside a loop is held in the -C repository" "2" "$rc"

# Nothing the gate held before is let through: the plain shapes, from a session in another checkout.
for c in "cd $REPO && git push" "(cd $REPO && git push origin feat/sync)" "git -C $REPO push" \
         $'git status\ncd '"$REPO"$'\ngit push'; do
  out="$(fire_push_in "$OTHER" "$c")"; rc=$?
  check_eq "still held: $c" "2" "$rc"
done

# The commit time start asks where the COMMIT runs, not where a push later in the command does.
reset_state
out="$(python3 -c 'import json,sys; print(json.dumps({"session_id":"s1","cwd":sys.argv[1],"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[2]},"tool_response":{"exit_code":0}}))' \
  "$OTHER" $'cd '"$REPO"$' && git commit -m two\ncd '"$OTHER"$'\ngit status' | bash "$COMMIT_HOOK" 2>&1)"
check "a commit's review starts in the repository the commit's cd names, from a session elsewhere" "started" "$out"
wait_final "$HEAD_SHA" && ok || bad "the commit's review of its own branch finished"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
