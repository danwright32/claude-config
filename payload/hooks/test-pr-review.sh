#!/usr/bin/env bash
# Tests for the lessons review of a whole branch before a pull request merges (claude-config#560):
# lib/pr-review.sh (start, check), ai-review-on-pr.sh (PostToolUse on `gh pr create`),
# pr-review-gate.sh (PreToolUse on every merge route), the shared runner's pr mode, the nudge's
# cap, and the citation ledger.
#
# Every outcome the design names has a test here that PRODUCES it (L151): finished with findings,
# finished clean, still running, failed, did not finish, came back empty, abandoned, could not run
# (no claude, no python3), too large, and an empty diff.
#
# A fake claude and a fake gh on PATH stand in for the real ones, the state directory is the
# scratch directory's, and the repository is a throwaway with a bare origin, so nothing here can
# reach the network, Dan's reviews, or a real pull request (L2).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/pr-review.sh"
CREATE_HOOK="$DIR/ai-review-on-pr.sh"
GATE="$DIR/pr-review-gate.sh"
NUDGE="$DIR/ai-review-nudge.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1500}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then ok; else bad "$1"; echo "  must not contain: $2"; echo "  actual: ${3:0:1500}"; fi; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }

# The state directory is the scratch directory's, never Dan's (L2). CLAUDECODE is set so the runner's
# removal of it is exercised even in CI.
export AI_REVIEW_STATE_DIR="$WORKDIR/state"
export CLAUDECODE=1
export PR_REVIEW_DEADLINE_SECONDS=30
# The push review's host list names only the work Mac; the PR review must ignore it (the whole point
# of #560 on this Mac), so the suite judges as the Mac the push review skips.
export AI_REVIEW_HOST="Daniels-MacBook-Pro-2"
unset AI_REVIEW_HOSTS SKIP_PR_REVIEW 2>/dev/null || true

# --- the fake claude: records its call, then answers from the environment the test sets ---
FAKEBIN="$WORKDIR/bin"; mkdir -p "$FAKEBIN"
export FAKE_LOG="$WORKDIR/fakelog"; mkdir -p "$FAKE_LOG"
cat > "$FAKEBIN/claude" <<'EOS'
#!/usr/bin/env bash
printf 'called\n' >> "$FAKE_LOG/calls"
printf '%s\x1e' "$@" > "$FAKE_LOG/args"
env > "$FAKE_LOG/env"
cat > "$FAKE_LOG/stdin"
sleep "${FAKE_CLAUDE_SLEEP:-0}"
[ -n "${FAKE_CLAUDE_EXIT:-}" ] && { echo "fake claude: simulated failure" >&2; exit "$FAKE_CLAUDE_EXIT"; }
[ -n "${FAKE_CLAUDE_EMPTY:-}" ] && exit 0
if [ -n "${FAKE_CLAUDE_OUT_FILE:-}" ]; then cat "$FAKE_CLAUDE_OUT_FILE"; exit 0; fi
if [ -n "${FAKE_CLAUDE_OUT:-}" ]; then printf '%s\n' "$FAKE_CLAUDE_OUT"; exit 0; fi
printf 'App/Sync.swift:3: deleteEvent still swallows the error createEvent now reports (L215). Should be: report it the same way. [severity: major]\n'
EOS
chmod +x "$FAKEBIN/claude"

# --- the fake gh: answers `pr view` for the merge gate from files the test writes ---
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
calls(){ [ -f "$FAKE_LOG/calls" ] && grep -c . "$FAKE_LOG/calls" || echo 0; }

# --- fixture: a bare origin, a main branch, and a feature branch carrying Swift and markdown ---
ORIGIN="$WORKDIR/origin.git"
git init -q --bare "$ORIGIN"
REPO="$WORKDIR/repo"
mkdir -p "$REPO/App"
git init -q "$REPO"
G(){ git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
G symbolic-ref HEAD refs/heads/main
printf 'func createEvent() {}\nfunc deleteEvent() {}\n' > "$REPO/App/Sync.swift"
printf '# fixture\n' > "$REPO/README.md"
G add App/Sync.swift README.md
G commit -q -m seed
G remote add origin "$ORIGIN"
G push -q -u origin main 2>/dev/null
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
G remote set-head origin main 2>/dev/null || true

G checkout -q -b feat/sync
printf 'func createEvent() throws {}\nfunc deleteEvent() {}\n// two\n' > "$REPO/App/Sync.swift"
G commit -q -am "one"
printf '# fixture\n\nMore.\n' > "$REPO/README.md"
G commit -q -am "two"
G push -q -u origin feat/sync 2>/dev/null
HEAD_SHA="$(G rev-parse HEAD)"
BASE_SHA="$(G merge-base origin/main HEAD)"

prr(){ bash "$LIB" "$@" 2>&1; }
key(){ bash -c ". '$DIR/lib/ai-review-common.sh'; ar_repo_key '$REPO'"; }
KEY="$(key)"
final_of(){ printf '%s/%s-pr-%s.txt' "$AI_REVIEW_STATE_DIR" "$KEY" "$1"; }
wait_final(){ # wait_final <sha>: waits on the condition, bounded, never a fixed sleep (L290)
  # Only while a review is PENDING: with no marker nothing is running, so there is nothing to wait
  # for and the absence is the answer.
  local f; f="$(final_of "$1")"; local t0=$SECONDS
  while [ ! -e "$f" ] && [ -e "$f.pending" ] && [ $((SECONDS - t0)) -lt 40 ]; do sleep 0.1; done
  [ -e "$f" ]
}
reset_state(){ rm -rf "$AI_REVIEW_STATE_DIR" "$FAKE_LOG"; mkdir -p "$FAKE_LOG"; }
meta(){ awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit } /^$/ { exit }' "$1"; }

# ===========================================================================================
# 1. Recognising `gh pr create` in command position, never a mention of it (L673).
# ===========================================================================================
is_create(){ bash -c ". '$DIR/lib/push-scope.sh'; ps_is_gh_pr_create \"\$1\"" _ "$1"; }
for c in 'gh pr create --fill' \
         'GH_TOKEN=$(gh auth token -u danwright32) gh pr create --title x --body y' \
         'cd /tmp/x && gh pr create --base main' \
         'rtk gh pr create --fill' \
         '/opt/homebrew/bin/gh pr create -f'; do
  is_create "$c" && ok || bad "a pull request creation is recognised: $c"
done
for c in 'echo "gh pr create"' \
         'gh pr view 12' \
         'git commit -m "then gh pr create"' \
         $'cat <<EOF > notes.md\ngh pr create --fill\nEOF' \
         'GH_TOKEN=$(gh auth token -u x) gh pr list'; do
  is_create "$c" && bad "a command that only mentions it is not a creation: $c" || ok
done

# ===========================================================================================
# 2. The PostToolUse hook: a successful creation starts a detached review of the WHOLE branch,
#    every file type, on this Mac too.
# ===========================================================================================
fire_create(){ # fire_create <command> <exit code>
  local p
  p="$(python3 -c 'import json,sys; print(json.dumps({"session_id":"s1","cwd":sys.argv[1],"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[2]},"tool_response":{"exit_code":int(sys.argv[3])}}))' "$REPO" "$1" "$2")"
  printf '%s' "$p" | bash "$CREATE_HOOK" 2>&1
}
reset_state
out="$(fire_create "gh pr create --fill" 1)"
check "a failed creation starts nothing, and says so" "did not succeed" "$out"
check_eq "a failed creation calls no reviewer" "0" "$(calls)"

out="$(fire_create "gh pr create --fill" 0)"
check "a creation says the whole branch review started" "started" "$out"
check "and names the branch range, merge base to head" "${BASE_SHA:0:7}..${HEAD_SHA:0:7}" "$out"
check_not "this Mac is not skipped by the push review's host list" "not one AI_REVIEW_HOSTS names" "$out"
wait_final "$HEAD_SHA" && ok || bad "the review finished and wrote its file"
F="$(final_of "$HEAD_SHA")"
check_eq "the finished review is a pr review" "pr" "$(meta "$F" kind)"
check_eq "and it finished" "ok" "$(meta "$F" status)"
check_eq "with one finding counted" "1" "$(meta "$F" findings)"
check_eq "against the merge base" "$BASE_SHA" "$(meta "$F" base)"
stdin="$(cat "$FAKE_LOG/stdin" 2>/dev/null)"
check "the Swift file is in the diff (every file type)" "App/Sync.swift" "$stdin"
check "markdown is in the diff too" "+More." "$stdin"
check "the first commit of the branch is in it, not only the last" "throws" "$stdin"
check "the reviewer is told this is a whole branch" "WHOLE BRANCH" "$(tr '\036' '\n' < "$FAKE_LOG/args")"
check_not "the reviewer did not inherit CLAUDECODE" "CLAUDECODE=" "$(cat "$FAKE_LOG/env")"
check "the cited lesson reached the durable ledger" "L215" "$(cat "$AI_REVIEW_STATE_DIR/citations.tsv" 2>/dev/null)"

# A second creation for the same head starts nothing new.
out="$(fire_create "gh pr create --fill" 0)"
check "the same head is not reviewed twice" "already" "$out"
check_eq "and no second reviewer ran" "1" "$(calls)"

# ===========================================================================================
# 3. check: every outcome the merge gate can meet.
# ===========================================================================================
# 3a. finished with findings, not yet delivered: refused once WITH the findings, then allowed.
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "undelivered findings refuse the merge this once" "1" "$rc"
check "the refusal carries the finding itself" "deleteEvent still swallows" "$out"
check "and the count" "1 finding" "$out"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "delivered findings no longer refuse" "0" "$rc"

# 3b. finished clean: allowed at once.
reset_state
FAKE_CLAUDE_OUT="No issues found." prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA" || bad "the clean review finished"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "a clean review allows the merge" "0" "$rc"
check "and says it found nothing" "0 findings" "$out"

# 3c. no review for this head: one is started, and the merge is refused while it runs.
reset_state
out="$(FAKE_CLAUDE_SLEEP=3 prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "no review for the head refuses" "1" "$rc"
check "and starts one" "started" "$out"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "a running review refuses" "1" "$rc"
check "and says it is still running, with its elapsed time" "still running" "$out"
check "naming its deadline" "30s" "$out"
wait_final "$HEAD_SHA" || bad "the started review finished"

# 3d. did not finish inside its deadline.
reset_state
out="$(PR_REVIEW_DEADLINE_SECONDS=1 FAKE_CLAUDE_SLEEP=20 prr start --dir "$REPO" --sha "$HEAD_SHA")"
wait_final "$HEAD_SHA" || bad "the slow review was recorded as unfinished"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "a review that ran out of time refuses" "1" "$rc"
check "in its own words" "did not finish" "$out"
check "naming the one command override" "SKIP_PR_REVIEW=1" "$out"
check "and the way to run it again" "pr-review.sh restart" "$out"

# 3e. the reviewer failed.
reset_state
FAKE_CLAUDE_EXIT=3 prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA" || bad "the failed review wrote its file"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "a failed review refuses" "1" "$rc"
check "saying it failed and why" "claude exited 3" "$out"

# 3f. the reviewer came back empty.
reset_state
FAKE_CLAUDE_EMPTY=1 prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA" || bad "the empty review wrote its file"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "an empty answer refuses, never reads as clean" "1" "$rc"
check "in its own words" "printed nothing" "$out"

# 3f2. an answer in neither shape the prompt allows. Measured 2026-09-24, the first real run: the
#      headless claude ran Dan's global hooks, and what came back was the end of turn issue review,
#      not a review. Counted as zero findings it would have allowed the merge as clean (L98, L340).
reset_state
FAKE_CLAUDE_OUT=$'ISSUE REVIEW\n\n1.1 Something about the session, not the diff.\n\nWant me to file that as an issue?' prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA" || bad "the unparsed review wrote its file"
check_eq "an answer in neither allowed shape is its own outcome" "unparsed" "$(meta "$(final_of "$HEAD_SHA")" status)"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "and it refuses, never reads as zero findings" "1" "$rc"
check "saying the answer was not a review" "not in the review's format" "$out"
check "the reviewer runs with every hook switched off" "disableAllHooks" "$(tr '\036' '\n' < "$FAKE_LOG/args")"

# 3g. abandoned: pending past its deadline with no runner left.
reset_state
mkdir -p "$AI_REVIEW_STATE_DIR"
printf 'repo=repo\nbranch=feat/sync\nsha=%s\nstarted=%s\ndeadline=30\nkind=pr\n' "$HEAD_SHA" "$(( $(date +%s) - 600 ))" > "$(final_of "$HEAD_SHA").pending"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "an abandoned review refuses" "1" "$rc"
check "saying the runner died" "never finished" "$out"
[ -e "$(final_of "$HEAD_SHA").pending" ] && bad "the abandoned marker is cleared" || ok

# 3h. could not run: no claude on PATH.
reset_state
NOCLAUDE="$WORKDIR/noclaude"; mkdir -p "$NOCLAUDE"; cp "$FAKEBIN/gh" "$NOCLAUDE/"
out="$(PATH="$NOCLAUDE:$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -x "$FAKEBIN" | tr '\n' ':')" \
      bash -c 'command -v claude >/dev/null && { echo "a real claude is on PATH here"; exit 9; }; bash "$1" check --dir "$2" --sha "$3" 2>&1' _ "$LIB" "$REPO" "$HEAD_SHA")"; rc=$?
if [ "$rc" -eq 9 ]; then echo "UNMEASURED: a real claude is installed on this machine's PATH, so the no-claude case cannot be produced here (L411)"; else
  check_eq "no claude refuses" "1" "$rc"
  check "naming what is missing" "could not run" "$out"
  check "and which tool" "claude" "$out"
fi

# 3i. could not run: no python3 (the runner's interpreter). A PATH built from every tool but python3.
reset_state
NOPY="$WORKDIR/nopy"; mkdir -p "$NOPY"
for d in /bin /usr/bin /usr/local/bin /opt/homebrew/bin "$FAKEBIN"; do
  [ -d "$d" ] || continue
  for t in "$d"/*; do
    b="$(basename "$t")"
    case "$b" in python3*|python) continue ;; esac
    [ -e "$NOPY/$b" ] || ln -s "$t" "$NOPY/$b" 2>/dev/null
  done
done
out="$(PATH="$NOPY" bash "$LIB" check --dir "$REPO" --sha "$HEAD_SHA" 2>&1)"; rc=$?
check_eq "no python3 refuses" "1" "$rc"
check "naming python3" "python3" "$out"
check_eq "and no reviewer was started without its interpreter" "0" "$(calls)"

# 3j. too large for a review to use.
reset_state
out="$(PR_REVIEW_MAX_BYTES=10 prr start --dir "$REPO" --sha "$HEAD_SHA")"
out="$(PR_REVIEW_MAX_BYTES=10 prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "a branch over the size cap refuses" "1" "$rc"
check "saying it is too large, with its size" "too large" "$out"
check_eq "and no reviewer ran" "0" "$(calls)"

# 3k. an empty diff: nothing to review, allowed, said so.
reset_state
out="$(prr check --dir "$REPO" --sha "$BASE_SHA")"; rc=$?
check_eq "a head with nothing on it beyond the base is allowed" "0" "$rc"
check "and says the diff was empty" "empty" "$out"

# 3l. A flag that needs a value, given last, is a usage error at once, never a loop: `shift 2` with
#     one argument left fails without shifting (the class found in find-prior-verdicts.sh, L387).
for flag in --dir --sha --base-ref; do
  bash "$LIB" check "$flag" >"$WORKDIR/trail.out" 2>&1 &
  pid=$!; t0=$SECONDS
  while kill -0 "$pid" 2>/dev/null && [ $((SECONDS - t0)) -lt 5 ]; do sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; bad "$flag given last hangs instead of being refused"
  else
    wait "$pid"; check_eq "$flag given last is a usage error" "64" "$?"
  fi
done

# ===========================================================================================
# 4. The merge gate, on the typed route and its override.
# ===========================================================================================
fire_gate(){ # fire_gate <command>
  python3 -c 'import json,sys; print(json.dumps({"session_id":"s1","cwd":sys.argv[1],"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[2]}}))' "$REPO" "$1" \
    | bash "$GATE" 2>&1
}
reset_state
printf '{"number":7,"headRefOid":"%s","baseRefName":"main","headRefName":"feat/sync"}\n' "$HEAD_SHA" > "$FAKE_LOG/pr-view.json"
out="$(fire_gate "echo hello")"; rc=$?
check_eq "a command that merges nothing passes untouched" "0" "$rc"
check_eq "and says nothing" "" "$out"
out="$(FAKE_CLAUDE_SLEEP=2 fire_gate "gh pr merge 7 --squash")"; rc=$?
check_eq "a merge with no review is refused" "2" "$rc"
check "and the review is started for the pull request's head" "started" "$out"
wait_final "$HEAD_SHA" || bad "the gate's review finished"
out="$(fire_gate "gh pr merge 7 --squash")"; rc=$?
check_eq "the first merge after it finishes is refused with the findings" "2" "$rc"
check "carrying them" "deleteEvent still swallows" "$out"
out="$(fire_gate "gh pr merge 7 --squash")"; rc=$?
check_eq "the next merge is allowed" "0" "$rc"
out="$(fire_gate "./scripts/merge-when-green.sh 7")"; rc=$?
check_eq "a repo's own merge script is judged the same way" "0" "$rc"
rm -f "$(final_of "$HEAD_SHA")"*
out="$(fire_gate "./scripts/merge-when-green.sh 7")"; rc=$?
check_eq "and refused the same way when there is no review" "2" "$rc"
wait_final "$HEAD_SHA"; rm -f "$(final_of "$HEAD_SHA")"*
out="$(fire_gate "venv/bin/python tools/wait_for_checks.py 7 --merge")"; rc=$?
check_eq "PostRoll's REST merge tool, run by its interpreter, is refused the same way" "2" "$rc"
wait_final "$HEAD_SHA"; rm -f "$(final_of "$HEAD_SHA")"*
out="$(fire_gate "bash scripts/merge-when-green.sh 7 && echo merged")"; rc=$?
check_eq "a merge followed by another command is still seen" "2" "$rc"
out="$(fire_gate "SKIP_PR_REVIEW=1 gh pr merge 7 --squash")"; rc=$?
check_eq "the override lets the merge through" "0" "$rc"
check "and says out loud that it did" "SKIP_PR_REVIEW=1" "$out"
rm -f "$FAKE_LOG/pr-view.json"
out="$(fire_gate "gh pr merge 7 --squash")"; rc=$?
check_eq "a pull request gh cannot find is refused, never allowed blind" "2" "$rc"

# ===========================================================================================
# 5. The nudge delivers a pr review under the 10,000 char hook cap, and marks it delivered.
# ===========================================================================================
reset_state
big="$WORKDIR/big.txt"; : > "$big"
for i in $(seq 1 200); do printf 'App/Sync.swift:%d: finding number %d with enough words to be a realistic finding line about something (L1). Should be: fixed. [severity: minor]\n' "$i" "$i" >> "$big"; done
FAKE_CLAUDE_OUT_FILE="$big" prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA" || bad "the big review finished"
out="$(printf '{"session_id":"n1","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$REPO" | bash "$NUDGE" 2>/dev/null)"
check "the nudge names it as the pull request review" "Lessons review of the whole branch" "$out"
check "with the total count" "200 findings" "$out"
check "and where the full list is" "$(final_of "$HEAD_SHA")" "$out"
[ "${#out}" -lt 10000 ] && ok || bad "the nudge stays under the 10,000 char hook cap (was ${#out})"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "findings the nudge delivered do not refuse the merge again" "0" "$rc"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"
[ "${#out}" -lt 10000 ] && ok || bad "the gate's own message stays under the cap too"

# 6. The ledger outlives the 14 day sweep: the nudge's sweep leaves it alone.
touch -t 202601010000 "$AI_REVIEW_STATE_DIR/citations.tsv"
printf '{"session_id":"n2","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$REPO" | bash "$NUDGE" >/dev/null 2>&1
[ -s "$AI_REVIEW_STATE_DIR/citations.tsv" ] && ok || bad "the citation ledger survives the sweep"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
