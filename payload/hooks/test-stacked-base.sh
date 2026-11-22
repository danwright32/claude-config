#!/usr/bin/env bash
# Tests for the base a stacked branch is judged from at a push (claude-config#3444):
# lib/stacked-base.sh, the one function both gates ask, and the two gates driven end to end as
# Claude Code runs them, the pre push test gate (require-tests-before-push.sh) and the lessons
# review before a push (pr-review-push-gate.sh, with the review a commit starts).
#
# Every fixture is a real repository with a bare origin: main, a base branch whose change carries
# BASE_ONLY_MARKER, and a child branch cut from it. The stand in judge and reviewer answer by what
# they are SHOWN: a refusal whenever the marker reaches them, so "judged from the base" is measured
# by what the model was handed, never by a message. gh is a stand in that answers from one file per
# branch, so each case states what GitHub says about the base.
#
# The two refusals of 2026-11-21 and 2026-11-22 are cases T1 and L1, seen red on the unchanged
# gates first. Every other T and L case is a push that must STAY judged from main.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/hang-wait.sh" || { echo "FAIL: lib/hang-wait.sh is missing"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
export FAKE_HANG_S="$HANG_S"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1200}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then ok; else bad "$1"; echo "  must not contain: $2"; echo "  actual: ${3:0:1200}"; fi; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }

unset SKIP_TEST_CHECK SKIP_PR_REVIEW PR_REVIEW_READ AI_REVIEW_HOSTS 2>/dev/null || true
# No claude and no gh of this Mac's own: only the stand ins below.
SYS_PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

# --- gh: one file per branch says what GitHub holds for it; no file is "no pull request" ---
GHBIN="$WORKDIR/ghbin"; mkdir -p "$GHBIN"
cat > "$GHBIN/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_DIR/calls"
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr view")
    f="$FAKE_GH_DIR/$(printf '%s' "$3" | tr '/' '_').json"
    if [ -f "$f" ]; then cat "$f"; exit 0; fi
    echo "no pull requests found for branch \"$3\"" >&2; exit 1 ;;
esac
echo "fake gh: unexpected call: $*" >&2; exit 3
EOS
chmod +x "$GHBIN/gh"
pr_json() {   # $1 = branch  $2 = state  $3 = head commit  $4 = true when from a fork
  printf '{"number":7,"state":"%s","headRefName":"%s","headRefOid":"%s","isCrossRepository":%s}\n' \
    "$2" "$1" "$3" "${4:-false}" > "$FAKE_GH_DIR/$(printf '%s' "$1" | tr '/' '_').json"
}
gh_calls() { if [ -f "$FAKE_GH_DIR/calls" ]; then grep -c 'pr view' "$FAKE_GH_DIR/calls"; else echo 0; fi; }

# --- the test gate's judge: refuses whenever it is shown the base's change ---
JUDGEBIN="$WORKDIR/judgebin"; mkdir -p "$JUDGEBIN"
cp "$GHBIN/gh" "$JUDGEBIN/gh"
cat > "$JUDGEBIN/claude" <<'EOS'
#!/usr/bin/env bash
input="$(cat)"
printf '%s' "$input" > "$JUDGE_LOG"
if [ "${JUDGE_MODE:-marker}" != pass ]; then
  case "$input" in *BASE_ONLY_MARKER*)
    printf '%s' '{"result":"{\"verdict\":\"block\",\"changes\":[],\"missing\":[\"the base change in lib/base.js\"]}"}'; exit 0 ;;
  esac
fi
printf '%s' '{"result":"{\"verdict\":\"pass\",\"changes\":[],\"missing\":[]}"}'
EOS
chmod +x "$JUDGEBIN/claude"

# --- the lessons reviewer: a stopping finding whenever it is shown the base's change ---
REVIEWBIN="$WORKDIR/reviewbin"; mkdir -p "$REVIEWBIN"
cp "$GHBIN/gh" "$REVIEWBIN/gh"
export FAKE_STREAM="$DIR/lib/fake-claude-stream.py"
cat > "$REVIEWBIN/claude" <<'EOS'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = stream-json ] && [ -z "${FAKE_STREAM_INNER:-}" ]; then
    FAKE_STREAM_INNER=1 "$0" "$@" | python3 "$FAKE_STREAM"; exit "${PIPESTATUS[0]}"
  fi
done
input="$(cat)"
printf '%s' "$input" > "$REVIEW_LOG"
if [ -n "${FAKE_CLAUDE_OUT:-}" ]; then printf '%s\n' "$FAKE_CLAUDE_OUT"; exit 0; fi
case "$input" in
  *BASE_ONLY_MARKER*) printf 'lib/base.js:1: the base change swallows the error it should report (L215). Should be: report it. [severity: major]\n' ;;
  *) printf 'No issues found.\n' ;;
esac
EOS
chmod +x "$REVIEWBIN/claude"
export FAKE_CLOCK_FILE="$WORKDIR/clock"
cat > "$REVIEWBIN/fake-clock" <<'EOS'
#!/usr/bin/env bash
cat "$FAKE_CLOCK_FILE" 2>/dev/null || echo 1000
EOS
cat > "$REVIEWBIN/fake-sleep" <<'EOS'
#!/usr/bin/env bash
now="$(cat "$FAKE_CLOCK_FILE" 2>/dev/null || echo 1000)"
echo $((now + ${1%.*})) > "$FAKE_CLOCK_FILE"
t0=$SECONDS
while ls "$AI_REVIEW_STATE_DIR"/*.pending >/dev/null 2>&1 && [ $((SECONDS - t0)) -lt "${FAKE_HANG_S:-300}" ]; do /bin/sleep 0.1; done
exit 0
EOS
chmod +x "$REVIEWBIN/fake-clock" "$REVIEWBIN/fake-sleep"
export PR_REVIEW_PUSH_CLOCK="$REVIEWBIN/fake-clock" PR_REVIEW_PUSH_SLEEP="$REVIEWBIN/fake-sleep"
export PR_REVIEW_PUSH_POLL_SECONDS=3 PR_REVIEW_PUSH_WAIT_SECONDS=9
export PR_REVIEW_DEADLINE_SECONDS=30 AI_REVIEW_HOST="Daniels-MacBook-Pro-2"

G(){ git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
payload_of(){ python3 -c 'import json,sys; print(json.dumps({"session_id":"s1","cwd":sys.argv[1],"hook_event_name":sys.argv[3],"tool_name":"Bash","tool_use_id":"toolu_test","tool_input":{"command":sys.argv[2]},"tool_response":{"exit_code":0}}))' "$REPO" "$1" "${2:-PreToolUse}"; }

# The pre push test gate, as Claude Code runs it. TG_RC is its exit, TG_ERR what it told the session.
run_tests_gate() {   # $1 = command
  local errf="$WORKDIR/tg-err"
  : > "$JUDGE_LOG"
  payload_of "$1" | env PATH="$JUDGEBIN:$SYS_PATH" bash "$DIR/require-tests-before-push.sh" >"$WORKDIR/tg-out" 2>"$errf"
  TG_RC=$?
  TG_ERR="$(cat "$errf")"
}
# The lessons review before a push. The injected sleep waits for the review, so one call decides.
run_review_gate() {   # $1 = command
  : > "$REVIEW_LOG"; echo 1000 > "$FAKE_CLOCK_FILE"
  RG_OUT="$(payload_of "$1" | env PATH="$REVIEWBIN:$PATH" bash "$DIR/pr-review-push-gate.sh" 2>&1)"
  RG_RC=$?
}
# The review of one head, found by the commit in its name: each fixture has a state folder of its
# own, so no other repository's review can be there.
review_file() {   # $1 = head commit
  local f
  for f in "$AI_REVIEW_STATE_DIR"/*-pr-"$1".txt; do
    if [ -e "$f" ]; then printf '%s' "$f"; return 0; fi
  done
  printf '%s/no-review-of-%s.txt' "$AI_REVIEW_STATE_DIR" "$1"
}
meta(){ awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit } /^$/ { exit }' "$1" 2>/dev/null; }
# The one function, asked as a gate asks it.
sb() {   # $1 = floor, or empty
  env PATH="$JUDGEBIN:$SYS_PATH" bash -c '. "$1/lib/stacked-base.sh" && sb_stacked_base "$2" "$3"' _ "$DIR" "$REPO" "${1:-}" 2>&1
}

# A stack: main on origin, base/one cut from it (a source change carrying the marker, with its
# test), child/two cut from base/one (its own source and test). $2 says how far the base got:
#   judged    the test gate passed its push on this Mac, and it is on origin (the default)
#   pushed    it is on origin, and no gate of this Mac ever judged it
#   local     it was never pushed
mk_stack() {   # $1 = name  $2 = judged | pushed | local
  local how="${2:-judged}"
  ROOT="$WORKDIR/$1"; REPO="$ROOT/repo"
  export FAKE_GH_DIR="$ROOT/gh" PUSH_GATE_LEDGER_DIR="$ROOT/ledger" AI_REVIEW_STATE_DIR="$ROOT/state"
  export JUDGE_LOG="$ROOT/judge-input" REVIEW_LOG="$ROOT/review-input"
  mkdir -p "$REPO/lib" "$REPO/tests" "$FAKE_GH_DIR"
  git init -q --bare "$ROOT/origin.git"
  git init -q "$REPO"
  G symbolic-ref HEAD refs/heads/main
  G config branch.autoSetupMerge false
  printf 'notes\n' > "$REPO/README.md"
  printf 'export const app = 1;\n' > "$REPO/lib/app.js"
  G add README.md lib/app.js; G commit -q -m seed
  G remote add origin "$ROOT/origin.git"
  G push -q -u origin main 2>/dev/null
  git -C "$ROOT/origin.git" symbolic-ref HEAD refs/heads/main
  G remote set-head origin main 2>/dev/null || true
  G checkout -q -b base/one
  printf 'export function base() { return 1; } // BASE_ONLY_MARKER\n' > "$REPO/lib/base.js"
  printf 'test("base", () => { expect(base()).toBe(1); });\n' > "$REPO/tests/base.test.js"
  G add lib/base.js tests/base.test.js; G commit -q -m "the base change"
  BASE_TIP="$(G rev-parse HEAD)"
  if [ "$how" = judged ]; then
    JUDGE_MODE=pass run_tests_gate "git push origin base/one"
    [ "$TG_RC" -eq 0 ] || bad "fixture $1: the base's own push was not passed by the test gate (exit $TG_RC): $TG_ERR"
  fi
  [ "$how" = local ] || G push -q origin base/one 2>/dev/null
  G checkout -q -b child/two
  printf 'export function child() { return 2; }\n' > "$REPO/lib/child.js"
  printf 'test("child", () => { expect(child()).toBe(2); });\n' > "$REPO/tests/child.test.js"
  G add lib/child.js tests/child.test.js; G commit -q -m "the child change"
  CHILD_TIP="$(G rev-parse HEAD)"
}

# ===========================================================================================
# S. The one function: when a base is established, and every way it is not.
# ===========================================================================================
mk_stack s1
pr_json base/one OPEN "$BASE_TIP"
check_eq "S1 an open pull request at the base's pushed head, under this branch: established" "base origin/base/one $BASE_TIP 7" "$(sb)"

# The commonest stack: a branch cut from origin's copy of its base tracks that base. The upstream is
# a candidate on the same terms as any other branch, and the lessons review reads from it.
mk_stack s1b
pr_json base/one OPEN "$BASE_TIP"
G branch -q --set-upstream-to=origin/base/one
check_eq "S1b the base is also the branch's upstream: established" "base origin/base/one $BASE_TIP 7" "$(sb)"
run_review_gate "git push origin HEAD:refs/heads/child/two"
check_eq "S1b and the lessons review reads from it: allowed" "0" "$RG_RC"
check_not "S1b without the base's change" "BASE_ONLY_MARKER" "$(cat "$REVIEW_LOG")"

mk_stack s2
out="$(sb)"
check "S2 the base has no pull request: not established" "none " "$out"
check_not "S2 and no base is named" "base origin" "$out"

mk_stack s3
pr_json base/one CLOSED "$BASE_TIP"
check "S3 the base's pull request is closed: not established" "none " "$(sb)"
pr_json base/one MERGED "$BASE_TIP"
check "S3 the base's pull request is merged: not established" "none " "$(sb)"
pr_json base/one OPEN "$BASE_TIP" true
check "S3 the pull request is from a fork: not established" "none " "$(sb)"

# The pusher controls this checkout's refs: a remote branch ref moved by hand onto an unpushed
# commit is an ancestor of HEAD, and GitHub's own head for the pull request is what refuses it.
mk_stack s4
pr_json base/one OPEN "$BASE_TIP"
G update-ref refs/remotes/origin/base/one "$CHILD_TIP~0"
printf 'more\n' >> "$REPO/README.md"; G commit -q -am "one more on the child"
check "S4 this checkout's copy of the base is not the commit GitHub has: not established" "none " "$(sb)"

# A base the branch only CLAIMS: an upstream, the setting gh pr create records and the branch's own
# pull request all name base/one, and the branch does not descend from it.
mk_stack s5
pr_json base/one OPEN "$BASE_TIP"
G checkout -q main; G checkout -q -b claims/base
printf 'export function claimed() { return 3; } // BASE_ONLY_MARKER\n' > "$REPO/lib/claimed.js"
G add lib/claimed.js; G commit -q -m "a change that claims a base"
G branch -q --set-upstream-to=origin/base/one
G config "branch.claims/base.gh-merge-base" base/one
check "S5 a branch that does not descend from the base it names: not established" "none " "$(sb)"

mk_stack s6 local
pr_json base/one OPEN "$BASE_TIP"
check "S6 a base that was never pushed: not established, whatever GitHub is said to hold" "none " "$(sb)"

mk_stack s7
pr_json base/one OPEN "$BASE_TIP"
G push -q origin --delete base/one 2>/dev/null
check "S7 a base deleted from origin: not established" "none " "$(sb)"

mk_stack s8
pr_json base/one OPEN "$BASE_TIP"
G checkout -q --detach
check "S8 a detached HEAD: not established" "none " "$(sb)"

# Two deep: the nearest base is the one judged from, and only it is asked about.
mk_stack s9
pr_json base/one OPEN "$BASE_TIP"
G push -q origin child/two 2>/dev/null
pr_json child/two OPEN "$CHILD_TIP"
G checkout -q -b grand/three
printf 'three\n' >> "$REPO/README.md"; G commit -q -am "the grandchild change"
check_eq "S9 two deep: judged from the nearest base" "base origin/child/two $CHILD_TIP 7" "$(sb)"
rm -f "$FAKE_GH_DIR/child_two.json"
check "S9 the nearest base has no pull request: not established, never the one under it" "none " "$(sb)"

# A branch cut from main asks GitHub nothing.
mk_stack s10
G checkout -q main; G checkout -q -b plain/four
printf 'four\n' >> "$REPO/README.md"; G commit -q -am "a plain change"
check "S10 a branch cut from main: not established" "none " "$(sb)"
check_eq "S10 and GitHub was not asked" "0" "$(gh_calls)"

# ===========================================================================================
# T. The pre push test gate.
# ===========================================================================================
# T1 is the refusal of 2026-11-21: the child's push refused for the base's change.
mk_stack t1
pr_json base/one OPEN "$BASE_TIP"
run_tests_gate "git push -u origin child/two"
check_eq "T1 a branch stacked on an open, judged base is judged from that base: allowed" "0" "$TG_RC"
check_not "T1 the judge was not shown the base's change" "BASE_ONLY_MARKER" "$(cat "$JUDGE_LOG")"
check "T1 the judge was shown the child's own change" "lib/child.js" "$(cat "$JUDGE_LOG")"
check "T1 the ledger records a judged pass" $'\ttests\tpass\t' "$(tail -n 1 "$PUSH_GATE_LEDGER_DIR/push-gates.tsv")"

# A branch based on main is judged exactly as before.
mk_stack t2
G checkout -q main; G checkout -q -b plain/src
mkdir -p "$REPO/tests"
printf 'export function plain() { return 4; } // BASE_ONLY_MARKER\n' > "$REPO/lib/plain.js"
printf 'test("plain", () => { expect(plain()).toBe(4); });\n' > "$REPO/tests/plain.test.js"
G add lib/plain.js tests/plain.test.js; G commit -q -m "a plain change"
run_tests_gate "git push -u origin plain/src"
check_eq "T2 a branch cut from main is judged from main: its own refused change is refused" "2" "$TG_RC"
check "T2 in the gate's own words" "PUSH BLOCKED" "$TG_ERR"
check_eq "T2 and GitHub was not asked" "0" "$(gh_calls)"

mk_stack t3
run_tests_gate "git push -u origin child/two"
check_eq "T3 the base has no open pull request: judged from main, refused" "2" "$TG_RC"
check "T3 for the base's change" "the base change in lib/base.js" "$TG_ERR"

mk_stack t4
pr_json base/one MERGED "$BASE_TIP"
run_tests_gate "git push -u origin child/two"
check_eq "T4 the base's pull request is merged: judged from main, refused" "2" "$TG_RC"
G push -q origin --delete base/one 2>/dev/null
pr_json base/one OPEN "$BASE_TIP"
run_tests_gate "git push -u origin child/two"
check_eq "T4 the base is deleted from origin: judged from main, refused" "2" "$TG_RC"

mk_stack t5 local
pr_json base/one OPEN "$BASE_TIP"
run_tests_gate "git push -u origin child/two"
check_eq "T5 the base was never pushed: judged from main, refused" "2" "$TG_RC"

# An open pull request does not say the test gate judged the base: only this Mac's ledger does.
mk_stack t6 pushed
pr_json base/one OPEN "$BASE_TIP"
run_tests_gate "git push -u origin child/two"
check_eq "T6 no record that the test gate judged the base's push: judged from main, refused" "2" "$TG_RC"

mk_stack t7 pushed
pr_json base/one OPEN "$BASE_TIP"
G checkout -q base/one
SKIP_TEST_CHECK=1 run_tests_gate "SKIP_TEST_CHECK=1 git push origin base/one"
G checkout -q child/two
check "T7 fixture: the base's push was let through by an override" $'\ttests\toverride\t' "$(cat "$PUSH_GATE_LEDGER_DIR/push-gates.tsv" 2>/dev/null)"
run_tests_gate "git push -u origin child/two"
check_eq "T7 the base's push was an override, never judged: judged from main, refused" "2" "$TG_RC"

# Named by what the pusher alone controls: a setting on the push, the setting gh pr create records,
# the branch's own pull request naming the base, and a remote ref moved by hand.
mk_stack t8
pr_json child/two OPEN "$CHILD_TIP"
G config "branch.child/two.gh-merge-base" base/one
run_tests_gate "STACKED_BASE=origin/base/one PUSH_BASE=base/one git push -u origin child/two"
check_eq "T8 a base named only by the pusher's own settings: judged from main, refused" "2" "$TG_RC"

mk_stack t9
pr_json base/one OPEN "$BASE_TIP"
G checkout -q main; G checkout -q -b claims/base
printf 'export function claimed() { return 3; } // BASE_ONLY_MARKER\n' > "$REPO/lib/claimed.js"
mkdir -p "$REPO/tests"
printf 'test("claimed", () => { expect(claimed()).toBe(3); });\n' > "$REPO/tests/claimed.test.js"
G add lib/claimed.js tests/claimed.test.js; G commit -q -m "a change that claims a base"
G config "branch.claims/base.gh-merge-base" base/one
run_tests_gate "git push -u origin claims/base"
check_eq "T9 a branch that claims a base it does not descend from: judged from main, refused" "2" "$TG_RC"

# Judged from its base, a stacked branch answers for its own tests: the base's test file is not a
# test "this branch pushed earlier", so source with no test of its own is refused without a model.
mk_stack t10
pr_json base/one OPEN "$BASE_TIP"
printf 'export function more() { return 5; }\n' > "$REPO/lib/more.js"
G add lib/more.js; G commit -q -m "source with no test, on the child"
G rm -q tests/child.test.js; G commit -q -m "and the child's own test gone"
run_tests_gate "git push -u origin child/two"
check_eq "T10 a stacked branch with source and no test of its own: refused" "2" "$TG_RC"
check "T10 by the floor, which the base's test does not satisfy" "adds or modifies no tests" "$TG_ERR"
check "T10 and the refusal says the branch was judged from its base" "stacked on origin/base/one" "$TG_ERR"

# ===========================================================================================
# L. The lessons review before a push, and the review a commit starts.
# ===========================================================================================
# L1 is the refusal of 2026-11-22: a stopping finding in a file the base branch owns.
mk_stack l1
pr_json base/one OPEN "$BASE_TIP"
run_review_gate "git push -u origin child/two"
check_eq "L1 a branch stacked on an open base is reviewed from that base: allowed" "0" "$RG_RC"
check_not "L1 the reviewer was not shown the base's change" "BASE_ONLY_MARKER" "$(cat "$REVIEW_LOG")"
check "L1 the reviewer was shown the child's own change" "lib/child.js" "$(cat "$REVIEW_LOG")"
check_eq "L1 the review records the base's head as where it read from" "$BASE_TIP" "$(meta "$(review_file "$CHILD_TIP")" base)"

# L1b: that review stops answering once the base is no longer an open pull request.
pr_json base/one CLOSED "$BASE_TIP"
run_review_gate "git push -u origin child/two"
check_eq "L1b the base's pull request closed after the review: read again from main, refused" "2" "$RG_RC"
check "L1b with the finding in the base's file" "lib/base.js:1" "$RG_OUT"

mk_stack l2
G checkout -q main; G checkout -q -b plain/src
printf 'export function plain() { return 4; } // BASE_ONLY_MARKER\n' > "$REPO/lib/base.js"
G add lib/base.js; G commit -q -m "a plain change"
run_review_gate "git push -u origin plain/src"
check_eq "L2 a branch cut from main is reviewed from main: its stopping finding refuses" "2" "$RG_RC"
check "L2 with the finding" "lib/base.js:1" "$RG_OUT"

mk_stack l3
run_review_gate "git push -u origin child/two"
check_eq "L3 the base has no open pull request: reviewed from main, refused" "2" "$RG_RC"
check "L3 with the finding in the base's file" "lib/base.js:1" "$RG_OUT"

mk_stack l4 local
pr_json base/one OPEN "$BASE_TIP"
run_review_gate "git push -u origin child/two"
check_eq "L4 the base was never pushed: reviewed from main, refused" "2" "$RG_RC"

mk_stack l5
pr_json base/one MERGED "$BASE_TIP"
run_review_gate "git push -u origin child/two"
check_eq "L5 the base's pull request is merged: reviewed from main, refused" "2" "$RG_RC"

mk_stack l6
pr_json child/two OPEN "$CHILD_TIP"
G config "branch.child/two.gh-merge-base" base/one
run_review_gate "STACKED_BASE=origin/base/one git push -u origin child/two"
check_eq "L6 a base named only by the pusher's own settings: reviewed from main, refused" "2" "$RG_RC"

# The second open question, the narrower answer: a stopping finding the review raises in a file the
# base owns still stops the stacked push. Nothing is waived for where a finding points.
mk_stack l7
pr_json base/one OPEN "$BASE_TIP"
FAKE_CLAUDE_OUT='lib/base.js:1: the base change swallows the error it should report (L215). Should be: report it. [severity: major]' \
  run_review_gate "git push -u origin child/two"
check_eq "L7 a stopping finding in a base file, raised by the narrowed review, still refuses" "2" "$RG_RC"
check "L7 and the refusal says where the review read from" "origin/base/one" "$RG_OUT"

# The review a commit starts reads the same range, so the push finds it and does not start a wider one.
mk_stack l8
pr_json base/one OPEN "$BASE_TIP"
payload_of "git commit -m x" PostToolUse | env PATH="$REVIEWBIN:$PATH" bash "$DIR/ai-review-on-pr.sh" >/dev/null 2>&1
hang_wait '[ -e "$(review_file "$CHILD_TIP")" ]'
check_eq "L8 the review a commit starts on a stacked branch reads from the base's head" "$BASE_TIP" "$(meta "$(review_file "$CHILD_TIP")" base)"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
