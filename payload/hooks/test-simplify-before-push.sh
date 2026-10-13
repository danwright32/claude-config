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

# The gate records every push it reaches (claude-config#1075). Pointed at a throwaway ledger so a
# test push is never counted among real ones; LEDGER is what the record cases below read.
export PUSH_GATE_LEDGER_DIR="$TMPROOT/ledger"
LEDGER="$PUSH_GATE_LEDGER_DIR/push-gates.tsv"

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
sys.stdout.write(json.dumps({"tool_input":{"command":os.environ["HK_CMD"]},"cwd":os.environ["HK_CWD"],"tool_use_id":os.environ.get("HK_ID","toolu_test")}))')"
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

# An un-added untracked source file is NOT pulled into the judged diff when the command commits a
# different, named file. The judged files come from ps_pending_files (add-scoped) and the untracked
# collection is restricted to that pathspec, so a file the `git add` did not name cannot block the
# push. Without that scoping an unrelated file in the tree gets judged (the test gate's add_in_chain
# guard, review of this branch).
W="$(mk_repo)"
( cd "$W" && mkdir -p lib \
    && printf 'def foo_area(w, h):\n    return w * h\n' > lib/foo.py \
    && printf 'import unused_bar_module\n\ndef bar():\n    return 1\n' > lib/bar.py ) >/dev/null 2>&1
rm -f "$JUDGE_IN"
STUB_CLAUDE_STDIN="$JUDGE_IN" STUB_CLAUDE_OUT="$PASS_OUT" \
  run_hook "$W" "git add lib/foo.py && git commit -m addfoo && git push"
want_code 0 "a named-add commit push is judged"
if grep -q 'foo_area' "$JUDGE_IN" 2>/dev/null; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: the committed file never reached the judge"; fi
if grep -q 'unused_bar_module' "$JUDGE_IN" 2>/dev/null; then fail=$((fail+1)); echo "FAIL: an un-added untracked file was judged and could block the push"; else pass=$((pass+1)); fi

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

# --- a judge that never answers in time is named as such (fail open, exit 1) ------------------------
# A stub timeout that reports what GNU timeout reports for a killed command, 124, with nothing
# printed: no real wait, the condition is set rather than slept for (L290).
TO_DIR="$TMPROOT/timeout-124"; mkdir -p "$TO_DIR"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 124\n' > "$TO_DIR/timeout"; chmod +x "$TO_DIR/timeout"
W="$(mk_repo)"; seed_source "$W"
run_hook "$W" "git push" "$TO_DIR:$PATH_STUB"
want_code 1 "judge timed out"
want_stderr "timed out after 90s" "judge timed out"

# --- a push run from a SUBDIRECTORY is judged on the whole push (claude-config#1076) ----------------
# The diff was asked for with paths relative to the root while git read them from the subdirectory,
# so a change outside it reached the judge as nothing, and the gate allowed the push unjudged and
# silent, exactly like one it had approved.
W="$(mk_repo)"; seed_source "$W"; mkdir -p "$W/docs"
rm -f "$JUDGE_IN"
STUB_CLAUDE_STDIN="$JUDGE_IN" STUB_CLAUDE_OUT="$BLOCK_OUT" run_hook "$W/docs" "git push"
want_code 2 "a push from a subdirectory is still judged"
if grep -q 'def area' "$JUDGE_IN" 2>/dev/null; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a push from a subdirectory sent the judge nothing of the change outside it"; fi

# --- the record of what the gate did (claude-config#1075) ------------------------------------------
# One row per push the gate reaches, read back by lib/push-gate-report.py. Column 3 is the gate,
# 4 the outcome, 6 the commit, 7 the tool call, 8 the model, 14 the detail.
row_of() { awk -F '\t' -v id="$1" '$7 == id' "$LEDGER" 2>/dev/null | tail -1; }
col() { printf '%s' "$1" | awk -F '\t' -v n="$2" '{ print $n }'; }
want_row() {   # <call id> <outcome> <label> [detail pattern]
  local r; r="$(row_of "$1")"
  if [ "$(col "$r" 3)" = simplify ] && [ "$(col "$r" 4)" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $3: expected a simplify row with outcome $2, got [$r]"; fi
  if [ -n "${4:-}" ]; then
    if grep -Eq "$4" <<< "$(col "$r" 14)"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $3: the row's detail did not match /$4/: [$(col "$r" 14)]"; fi
  fi
}

W="$(mk_repo)"; seed_source "$W"
HK_ID=rec-block STUB_CLAUDE_OUT="$BLOCK_OUT" run_hook "$W" "git push"
want_row rec-block block "a block is recorded with what it flagged" 'unused.*unused import sys'
head_blocked="$(git -C "$W" rev-parse HEAD)"
if [ "$(col "$(row_of rec-block)" 6)" = "$head_blocked" ] && [ "$(col "$(row_of rec-block)" 8)" = haiku ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: the block row does not name the commit and the model: [$(row_of rec-block)]"; fi
HK_ID=rec-override run_hook "$W" "SKIP_SIMPLIFY_CHECK=1 git push"
want_code 0 "an override still allows"
want_silent "an override still allows, silently"
want_row rec-override override "an override is recorded"
if [ "$(col "$(row_of rec-override)" 6)" = "$head_blocked" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: the override row does not name the commit it let through, so it cannot be matched to the block: [$(row_of rec-override)]"; fi

W="$(mk_repo)"; seed_source "$W"
HK_ID=rec-pass STUB_CLAUDE_OUT='{"result":"{\"verdict\":\"pass\",\"findings\":[]}","duration_ms":4200,"total_cost_usd":0.0123}' run_hook "$W" "git push"
want_row rec-pass pass "a pass is recorded"
if [ "$(col "$(row_of rec-pass)" 10)" = 4200 ] && [ "$(col "$(row_of rec-pass)" 11)" = 0.0123 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: the pass row does not carry the judge's own time and cost: [$(row_of rec-pass)]"; fi

W="$(mk_repo)"; seed_source "$W"
HK_ID=rec-open STUB_CLAUDE_OUT='{"result":"sure, looks fine"}' run_hook "$W" "git push"
want_row rec-open failopen "a fail open is recorded with its reason" 'not readable JSON'

W="$(mk_repo)"
( cd "$W" && printf 'words only\n' > notes.md && git add notes.md && git commit -qm docs ) >/dev/null 2>&1
HK_ID=rec-nosource run_hook "$W" "git push"
want_row rec-nosource nosource "a push with no source is recorded"

HK_ID=rec-notpush run_hook "$W" "git status"
if [ -z "$(row_of rec-notpush)" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a command that is not a push was recorded"; fi

# A payload that does not parse is not known to be a push, so it fails open without a row.
rows_before="$(wc -l < "$LEDGER" 2>/dev/null || echo 0)"
printf 'this is not json' | env PATH="$PATH_STUB" bash "$HOOK" 2>/dev/null
if [ "$(wc -l < "$LEDGER" 2>/dev/null || echo 0)" = "$rows_before" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a payload that did not parse was recorded as a push"; fi

# No CLI: the push is recorded as a fail open, and with no model, since no judge was ever called.
W="$(mk_repo)"; seed_source "$W"
HK_ID=rec-nocli run_hook "$W" "git push" "$PATH_NOCLAUDE"
want_row rec-nocli failopen "a missing judge is recorded" 'no claude CLI'
if [ -z "$(col "$(row_of rec-nocli)" 8)" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a judge that never ran is recorded with a model, so it counts as a call: [$(row_of rec-nocli)]"; fi

# A record that cannot be written is said, never swallowed, and never turns a pass into a block.
W="$(mk_repo)"; seed_source "$W"
printf 'not a directory\n' > "$TMPROOT/ledger-file"
PUSH_GATE_LEDGER_DIR="$TMPROOT/ledger-file" STUB_CLAUDE_OUT="$PASS_OUT" run_hook "$W" "git push"
want_code 1 "an unwritable record does not block the push"
want_stderr "allowed this push \(pass\), but its record could not be written" "an unwritable record is said"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
