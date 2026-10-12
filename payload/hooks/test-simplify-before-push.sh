#!/usr/bin/env bash
# Tests for simplify-before-push.sh: a PreToolUse(Bash) gate that blocks a `git push` whose source
# changes carry a material, high-confidence simplification (dead/leftover code, or needless
# complexity with an obviously simpler form). Duplication is deliberately NOT its job: a separate
# gate (check-duplication.sh) owns that, and this one tells the judge to leave it alone, so the two
# never both fire on one copy (L613, L36).
#
# The judge is the local `claude` CLI, stubbed here exactly as test-require-tests-before-push.sh
# stubs it, so these drive the real hook as a subprocess with a JSON payload on stdin.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/simplify-before-push.sh"

pass=0
fail=0

# PATH without claude on it, so the hook's `command -v claude` check can be exercised in both
# directions (claude lives in ~/.local/bin, off this PATH).
PATH_NOCLAUDE="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

STUB_DIR="$(mktemp -d)"
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
if [ -n "${STUB_CLAUDE_STDIN:-}" ]; then cat > "$STUB_CLAUDE_STDIN"; else cat >/dev/null; fi
[ -n "${STUB_CLAUDE_ARGS:-}" ] && printf '%s\n' "$@" > "$STUB_CLAUDE_ARGS"
[ -n "${STUB_CLAUDE_OUT:-}" ] && printf '%s' "$STUB_CLAUDE_OUT"
exit "${STUB_CLAUDE_EXIT:-0}"
STUB
chmod +x "$STUB_DIR/claude"
PATH_STUB="$STUB_DIR:$PATH_NOCLAUDE"

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$STUB_DIR" "$TMPROOT"; }
trap cleanup EXIT

# A scratch repo WITH a bare remote and a tracking branch. Without the upstream the hook has no
# merge base and silently allows everything (the test gate's trap 1).
mk_repo() {
  local root
  root="$(mktemp -d "$TMPROOT/repo.XXXXXX")"
  git init -q --bare "$root/origin.git"
  git init -q "$root/work"
  (
    cd "$root/work" || exit 1
    git config user.email t@example.com
    git config user.name tester
    git config commit.gpgsign false
    echo init > README.md
    git add README.md
    git commit -qm init
    git remote add origin "$root/origin.git"
    git push -qu origin HEAD
  ) >/dev/null 2>&1
  printf '%s' "$root/work"
}

CODE=0
ERR=""
run_hook() {   # <cwd> <command> [PATH]
  local cwd="$1" cmd="$2" usepath="${3:-$PATH_STUB}" payload errf
  errf="$(mktemp)"
  payload="$(HK_CMD="$cmd" HK_CWD="$cwd" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps({"tool_input":{"command":os.environ["HK_CMD"]},"cwd":os.environ["HK_CWD"]}))')"
  printf '%s' "$payload" | env PATH="$usepath" bash "$HOOK" 2>"$errf"
  CODE=$?
  ERR="$(cat "$errf")"
  rm -f "$errf"
}

want_code() { if [ "$CODE" = "$1" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2: expected exit $1, got $CODE"; fi; }
# here-string, not printf | grep -q, to keep test-pipefail-shortcircuit.sh clean of a new site (L183).
want_stderr() { if grep -Eiq "$1" <<< "$ERR"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2: stderr did not match /$1/. Got: [$ERR]"; fi; }
want_silent() { if [ -z "$ERR" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1: expected NO stderr, got: [$ERR]"; fi; }

# Stage a source change, committed against the upstream.
seed_source() {   # $1 = repo
  (
    cd "$1" || exit 1
    mkdir -p lib
    printf 'import os\nimport sys\n\ndef area(w, h):\n    return w * h\n' > lib/calc.py
    git add lib/calc.py
    git commit -qm "add calc"
  ) >/dev/null 2>&1
}

# Verdicts the stub can return.
BLOCK_OUT='{"result":"{\"verdict\":\"block\",\"findings\":[{\"summary\":\"unused import sys in lib/calc.py\",\"kind\":\"unused\"}]}"}'
PASS_OUT='{"result":"{\"verdict\":\"pass\",\"findings\":[]}"}'
BLOCK_EMPTY_OUT='{"result":"{\"verdict\":\"block\",\"findings\":[]}"}'

# --- THE CANARY: a source change the judge blocks MUST block. --------------
# If this ever passes, the harness is lying and every "allowed" case below is void.
W="$(mk_repo)"; seed_source "$W"
STUB_CLAUDE_OUT="$BLOCK_OUT" run_hook "$W" "git push"
want_code 2 "canary: judge BLOCK must block"
want_stderr "unused import sys" "canary: the block names the finding"
want_stderr "SKIP_SIMPLIFY_CHECK=1" "canary: the block names the override"

# --- judge PASS allows, silently ------------------------------------------
W="$(mk_repo)"; seed_source "$W"
STUB_CLAUDE_OUT="$PASS_OUT" run_hook "$W" "git push"
want_code 0 "judge PASS allows"
want_silent "judge PASS allows"

# --- block verdict with NO findings is treated as pass (bias to allow) -----
# A subjective gate errs toward letting work through: a verdict of block with nothing to name is
# not a finding anyone can act on, so it must not strand the push (L36).
W="$(mk_repo)"; seed_source "$W"
STUB_CLAUDE_OUT="$BLOCK_EMPTY_OUT" run_hook "$W" "git push"
want_code 0 "block with empty findings allows"

# --- legitimate silent allows -----------------------------------------------
W="$(mk_repo)"; seed_source "$W"
run_hook "$W" "git status"
want_code 0 "not a push"
want_silent "not a push"

W="$(mk_repo)"; seed_source "$W"
STUB_CLAUDE_OUT="$BLOCK_OUT" run_hook "$W" "SKIP_SIMPLIFY_CHECK=1 git push"
want_code 0 "SKIP_SIMPLIFY_CHECK override"
want_silent "SKIP_SIMPLIFY_CHECK override"

# docs-only: no source changed, so the judge is never called and the push passes silently.
JUDGE_IN="$TMPROOT/judge-stdin"
W="$(mk_repo)"
( cd "$W" && printf 'words only\n' > notes.md && git add notes.md && git commit -qm docs ) >/dev/null 2>&1
rm -f "$JUDGE_IN"
STUB_CLAUDE_STDIN="$JUDGE_IN" STUB_CLAUDE_OUT="$BLOCK_OUT" run_hook "$W" "git push"
want_code 0 "no source touched"
want_silent "no source touched"
if [ -e "$JUDGE_IN" ]; then fail=$((fail+1)); echo "FAIL: docs-only push called the judge"; else pass=$((pass+1)); fi

# test-only: a change to a test file alone is not source to judge (is_test exclusion), so the judge
# is never called. Proves the shared classifier's is_test is actually consulted here.
W="$(mk_repo)"
( cd "$W" && mkdir -p tests && printf 'def test_area():\n    assert True\n' > tests/test_calc.py \
    && git add tests/test_calc.py && git commit -qm "a test" ) >/dev/null 2>&1
rm -f "$JUDGE_IN"
STUB_CLAUDE_STDIN="$JUDGE_IN" STUB_CLAUDE_OUT="$BLOCK_OUT" run_hook "$W" "git push"
want_code 0 "test-only change is not judged"
if [ -e "$JUDGE_IN" ]; then fail=$((fail+1)); echo "FAIL: test-only push called the judge"; else pass=$((pass+1)); fi

# --- the judge actually receives the changed source, and is told to leave duplication alone -------
# A gate may claim only what its check measured (L11): prove the diff reaches the judge, and prove
# the instruction that keeps this gate off the duplication gate's turf is really sent.
ARGS_FILE="$TMPROOT/judge-args"
W="$(mk_repo)"; seed_source "$W"
rm -f "$JUDGE_IN" "$ARGS_FILE"
STUB_CLAUDE_STDIN="$JUDGE_IN" STUB_CLAUDE_ARGS="$ARGS_FILE" STUB_CLAUDE_OUT="$PASS_OUT" run_hook "$W" "git push"
want_code 0 "judge is called on a source change"
if grep -q 'def area' "$JUDGE_IN" 2>/dev/null; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: the changed source never reached the judge"; fi
if grep -qi 'duplicat' "$ARGS_FILE" 2>/dev/null; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: the rubric does not tell the judge to leave duplication to the other gate"; fi

# --- the judge runs isolated: --setting-sources local keeps the global config out -----------------
W="$(mk_repo)"; seed_source "$W"
rm -f "$ARGS_FILE"
STUB_CLAUDE_ARGS="$ARGS_FILE" STUB_CLAUDE_OUT="$PASS_OUT" run_hook "$W" "git push"
if grep -qx -- '--setting-sources' "$ARGS_FILE" 2>/dev/null \
   && [ "$(grep -A1 -x -- '--setting-sources' "$ARGS_FILE" | tail -1)" = "local" ]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL: the judge is not launched with --setting-sources local (flags: $(grep -- '^--' "$ARGS_FILE" 2>/dev/null | tr '\n' ' ' || echo 'judge never ran'))"
fi

# --- fail-open paths must SAY SO (exit 1), never vanish (L98) ---------------
ERRF="$(mktemp)"
printf 'this is not json' | env PATH="$PATH_STUB" bash "$HOOK" 2>"$ERRF"
CODE=$?; ERR="$(cat "$ERRF")"; rm -f "$ERRF"
want_code 1 "unparseable payload"
want_stderr "payload" "unparseable payload"

W="$(mk_repo)"; seed_source "$W"
run_hook "$W" "git push" "$PATH_NOCLAUDE"
want_code 1 "judge CLI missing"
want_stderr "judge" "judge CLI missing"

W="$(mk_repo)"; seed_source "$W"
STUB_CLAUDE_OUT="" run_hook "$W" "git push"
want_code 1 "judge returned nothing"
want_stderr "judge" "judge returned nothing"

W="$(mk_repo)"; seed_source "$W"
STUB_CLAUDE_OUT='{"is_error":true,"result":"boom"}' run_hook "$W" "git push"
want_code 1 "judge is_error envelope"
want_stderr "judge" "judge is_error envelope"

W="$(mk_repo)"; seed_source "$W"
STUB_CLAUDE_OUT='{"result":"sure, looks fine"}' run_hook "$W" "git push"
want_code 1 "judge verdict unparseable"
want_stderr "judge" "judge verdict unparseable"

# --- a genuinely unrelated cwd gates nothing -------------------------------
NOTREPO="$(mktemp -d)"
run_hook "$NOTREPO" "git push"
want_code 0 "a push with no resolvable repo stays out of the way"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
