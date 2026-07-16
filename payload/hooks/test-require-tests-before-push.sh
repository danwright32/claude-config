#!/usr/bin/env bash
# Tests for the file classifier (is_test / is_source) inside
# require-tests-before-push.sh. We source ONLY those two function definitions
# out of the hook so we exercise the real code without running the whole hook.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/require-tests-before-push.sh"

# Pull the pure functions out of the hook and define them here.
eval "$(sed -n '/^is_test() {/,/^}/p' "$HOOK")"
eval "$(sed -n '/^is_source() {/,/^}/p' "$HOOK")"
eval "$(sed -n '/^docs_style_for() {/,/^}/p' "$HOOK")"
eval "$(sed -n '/^diff_docs_only() {/,/^}/p' "$HOOK")"

pass=0
fail=0
want_test()    { if is_test "$1";    then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: expected TEST: $1"; fi; }
want_nottest() { if is_test "$1";    then fail=$((fail+1)); echo "FAIL: expected NOT-test: $1"; else pass=$((pass+1)); fi; }
want_source()    { if is_source "$1"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: expected SOURCE: $1"; fi; }
want_notsource() { if is_source "$1"; then fail=$((fail+1)); echo "FAIL: expected NOT-source: $1"; else pass=$((pass+1)); fi; }
want_docsonly()    { if printf '%s' "$2" | diff_docs_only "$1"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: expected DOCS-ONLY ($1): [$2]"; fi; }
want_notdocsonly() { if printf '%s' "$2" | diff_docs_only "$1"; then fail=$((fail+1)); echo "FAIL: expected NOT-docs-only ($1): [$2]"; else pass=$((pass+1)); fi; }
want_style()       { local got; got="$(docs_style_for "$1")"; if [ "$got" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: style $1 expected $2 got $got"; fi; }

# --- the reported gap: scripts/test-*.ts convention ---
want_test "scripts/test-cron-routes.ts"
want_test "scripts/test-sync.js"
want_test "scripts/test_legacy_thing.ts"   # underscore variant too

# --- existing conventions must still register (regression) ---
want_test "src/components/Foo.test.ts"
want_test "src/components/Foo.spec.tsx"
want_test "tests/foo.ts"
want_test "test_foo.py"
want_test "foo_test.go"

# --- must NOT over-match real source or test-only helpers ---
want_nottest "src/app/api/cron/route.ts"   # the source file from the report
want_nottest "scripts/deploy.ts"
want_nottest "scripts/test-utils.ts"        # helper, not a runnable test
want_nottest "src/test-helpers.ts"
want_nottest "scripts/testimonials.ts"      # 'test' substring, not a test file

# --- one-off analysis scripts in scripts/ are exempt from the gate ---
want_notsource "scripts/check-menjivar.js"
want_notsource "scripts/check-menjivar-beyond.js"
want_notsource "scripts/check_enrollment_gaps.py"
want_notsource "apps/worker/scripts/check-export-state.ts"

# --- but the exemption must not leak beyond scripts/check-* ---
want_source "src/app/api/check-email/route.ts"   # real route, not a script
want_source "scripts/checkout.ts"                # 'check' substring only
want_source "scripts/deploy.ts"
want_source "lib/check-utils.ts"                 # not under scripts/

# --- #733: docs-only (comment/blank) diffs need no test ---
want_docsonly slash "$(printf 'diff --git a/lib/foo.js b/lib/foo.js\n--- a/lib/foo.js\n+++ b/lib/foo.js\n@@ -1,2 +1,3 @@\n const x = 1;\n+// explain the thing\n const y = 2;\n')"
want_docsonly slash "$(printf -- '--- a/lib/foo.js\n+++ b/lib/foo.js\n@@\n+/**\n+ * Does the thing.\n+ */\n')"
want_docsonly slash "$(printf -- '--- a/foo.js\n+++ b/foo.js\n@@\n+\n+    \n')"
want_docsonly slash "$(printf -- '--- a/foo.js\n+++ b/foo.js\n@@\n-  // old note\n')"
want_docsonly slash "$(printf -- '--- a/foo.js\n+++ b/foo.js\n@@\n+ */\n')"
# A diff with NO changed content lines at all (a mode/permission change, a pure
# rename) must NOT count as docs-only -- we saw no documentation change, so the
# hard floor applies. See the fail-closed guard in diff_docs_only.
want_notdocsonly slash ""
want_docsonly    hash "$(printf -- '--- a/s.py\n+++ b/s.py\n@@\n+# a python comment\n')"

# --- real code must STILL block (these guard against over-allowing) ---
want_notdocsonly slash "$(printf -- '--- a/lib/foo.js\n+++ b/lib/foo.js\n@@\n+const z = 3;\n')"
want_notdocsonly slash "$(printf -- '--- a/lib/foo.js\n+++ b/lib/foo.js\n@@\n+  #count = 0;\n')"
want_notdocsonly slash "$(printf -- '--- a/x.c\n+++ b/x.c\n@@\n+  *ptr = value;\n')"
want_notdocsonly slash "$(printf -- '--- a/foo.js\n+++ b/foo.js\n@@\n+// good\n+const q = 4;\n')"
want_notdocsonly slash "$(printf -- '--- a/foo.js\n+++ b/foo.js\n@@\n+const a = 1; // note\n')"
want_notdocsonly hash "$(printf -- '--- a/s.py\n+++ b/s.py\n@@\n+x = 1\n')"
want_notdocsonly hash "$(printf -- '--- a/s.py\n+++ b/s.py\n@@\n+y = a // b\n')"

# --- comment style routing by extension ---
want_style foo.py hash
want_style foo.rb hash
want_style path/to/foo.ex hash
want_style foo.exs hash
want_style foo.js slash
want_style foo.ts slash
want_style foo.go slash
want_style foo.c slash

# --- #733 follow-up: a leading-operator code line must NOT read as a comment ---
# "const a = b" / "  * 2;" -> changing 2 to 3 is a real behavior change whose
# only diff lines start with '*'. It must block.
want_notdocsonly slash "$(printf -- '--- a/calc.js\n+++ b/calc.js\n@@\n-  * 2;\n+  * 3;\n')"
want_notdocsonly slash "$(printf -- '--- a/calc.js\n+++ b/calc.js\n@@\n+  * factor;\n')"
# Editing wording inside an EXISTING block comment has no '/*' opener in the
# diff, so it conservatively blocks rather than reopen the hole above.
want_notdocsonly slash "$(printf -- '--- a/foo.js\n+++ b/foo.js\n@@\n- * old wording\n+ * new wording\n')"

# ===========================================================================
# END TO END: drive the real hook and assert its exit code. (#734)
#
# The unit tests above source pure classifiers out of the hook, so they cannot
# see a gate that has stopped gating: both #733 bugs shipped behind a fully
# green unit suite. Everything below runs the hook as a subprocess with a JSON
# payload on stdin, exactly as Claude Code invokes it.
#
# Two traps that make these tests FAKE GREEN if you get them wrong:
#   1. A scratch repo with no upstream makes the hook diff a branch against
#      itself, so it finds no files and exits 0. Every "allowed" assertion then
#      passes for the wrong reason. Hence the bare remote and `push -u`.
#   2. Double quotes in a hand built JSON payload break the parse, and the hook
#      exits 0. Hence python json.dumps, never a printf template.
# The must-block canary below is the guard: if it ever stops blocking, the
# harness itself is broken, no matter how green the rest reads.
# ===========================================================================

# PATH without claude on it (claude lives in ~/.local/bin), so the hook's
# `command -v claude` check can be exercised in both directions.
PATH_NOCLAUDE="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

STUB_DIR="$(mktemp -d)"
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
[ -n "${STUB_CLAUDE_OUT:-}" ] && printf '%s' "$STUB_CLAUDE_OUT"
exit "${STUB_CLAUDE_EXIT:-0}"
STUB
chmod +x "$STUB_DIR/claude"
PATH_STUB="$STUB_DIR:$PATH_NOCLAUDE"

# One parent dir for every scratch repo. mk_repo runs inside $(...), a subshell,
# so it cannot append to an array in this shell: a tracking array would silently
# stay empty and leak every repo it made.
TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$STUB_DIR" "$TMPROOT"; }
trap cleanup EXIT

# A scratch repo WITH a bare remote and a tracking branch. Without the upstream
# the hook has no merge base and silently allows everything (trap 1 above).
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
# run_hook <cwd> <command> [PATH to use]
run_hook() {
  local cwd="$1" cmd="$2" usepath="${3:-$PATH_STUB}" payload errf
  errf="$(mktemp)"
  payload="$(HK_CMD="$cmd" HK_CWD="$cwd" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps({"tool_input":{"command":os.environ["HK_CMD"]},"cwd":os.environ["HK_CWD"]}))')"
  printf '%s' "$payload" | env PATH="$usepath" bash "$HOOK" 2>"$errf"
  CODE=$?
  ERR="$(cat "$errf")"
  rm -f "$errf"
}

want_code() {
  if [ "$CODE" = "$1" ]; then pass=$((pass+1));
  else fail=$((fail+1)); echo "FAIL: $2: expected exit $1, got $CODE"; fi
}
want_stderr() {
  if printf '%s' "$ERR" | grep -Eiq "$1"; then pass=$((pass+1));
  else fail=$((fail+1)); echo "FAIL: $2: stderr did not match /$1/. Got: [$ERR]"; fi
}
want_silent() {
  if [ -z "$ERR" ]; then pass=$((pass+1));
  else fail=$((fail+1)); echo "FAIL: $1: expected NO stderr, got: [$ERR]"; fi
}

# Stage a source change plus a real test file, committed against the upstream.
seed_source_and_test() {
  local w="$1"
  (
    cd "$w" || exit 1
    mkdir -p lib tests
    printf 'export function add(a, b) { return a + b; }\n' > lib/calc.js
    printf 'test("add", () => { expect(add(1,2)).toBe(3); });\n' > tests/calc.test.js
    git add lib/calc.js tests/calc.test.js
    git commit -qm "add calc"
  ) >/dev/null 2>&1
}

seed_source_only() {
  local w="$1"
  (
    cd "$w" || exit 1
    mkdir -p lib
    printf 'export function add(a, b) { return a + b; }\n' > lib/calc.js
    git add lib/calc.js
    git commit -qm "add calc"
  ) >/dev/null 2>&1
}

# --- THE CANARY: a plain code change with no test MUST block. -------------
# If this ever passes, the harness is lying and every other case below is void.
W="$(mk_repo)"; seed_source_only "$W"
run_hook "$W" "git push"
want_code 2 "canary: source with no test must BLOCK"

# --- #735: fail-open paths must SAY SO (exit 1) instead of vanishing ------
# exit 0 discards stderr entirely, so a notice on exit 0 would be invisible.
# exit 1 is a non-blocking error: the push still runs, and the first stderr
# line surfaces in the transcript.

# Unparseable payload.
ERRF="$(mktemp)"
printf 'this is not json' | env PATH="$PATH_STUB" bash "$HOOK" 2>"$ERRF"
CODE=$?; ERR="$(cat "$ERRF")"; rm -f "$ERRF"
want_code 1 "unparseable payload"
want_stderr "payload" "unparseable payload"

# Judge binary missing.
W="$(mk_repo)"; seed_source_and_test "$W"
run_hook "$W" "git push" "$PATH_NOCLAUDE"
want_code 1 "judge CLI missing"
want_stderr "judge" "judge CLI missing"

# Judge returns nothing (unreachable or timed out).
W="$(mk_repo)"; seed_source_and_test "$W"
STUB_CLAUDE_OUT="" run_hook "$W" "git push"
want_code 1 "judge returned nothing"
want_stderr "judge" "judge returned nothing"

# Judge returns an is_error envelope.
W="$(mk_repo)"; seed_source_and_test "$W"
STUB_CLAUDE_OUT='{"is_error":true,"result":"boom"}' run_hook "$W" "git push"
want_code 1 "judge is_error envelope"
want_stderr "judge" "judge is_error envelope"

# Judge returns prose instead of the JSON verdict.
W="$(mk_repo)"; seed_source_and_test "$W"
STUB_CLAUDE_OUT='{"result":"sure thing, looks good to me"}' run_hook "$W" "git push"
want_code 1 "judge verdict unparseable"
want_stderr "judge" "judge verdict unparseable"

# --- the gate's real verdicts must be unaffected by the above -------------
W="$(mk_repo)"; seed_source_and_test "$W"
STUB_CLAUDE_OUT='{"result":"{\"verdict\":\"pass\",\"changes\":[],\"missing\":[]}"}' \
  run_hook "$W" "git push"
want_code 0 "judge PASS allows"
want_silent "judge PASS allows"

W="$(mk_repo)"; seed_source_and_test "$W"
STUB_CLAUDE_OUT='{"result":"{\"verdict\":\"block\",\"changes\":[],\"missing\":[\"the add() fix\"]}"}' \
  run_hook "$W" "git push"
want_code 2 "judge BLOCK blocks"

# --- legitimate silent allows must STAY silent ----------------------------
# These are correct passes, not fail-opens. Making them talk would train
# everyone to ignore the signal.
W="$(mk_repo)"; seed_source_only "$W"
run_hook "$W" "git status"
want_code 0 "not a push"
want_silent "not a push"

W="$(mk_repo)"; seed_source_only "$W"
run_hook "$W" "SKIP_TEST_CHECK=1 git push"
want_code 0 "SKIP_TEST_CHECK override"
want_silent "SKIP_TEST_CHECK override"

W="$(mk_repo)"
( cd "$W" && printf 'nothing but words\n' > notes.md && git add notes.md && git commit -qm docs ) >/dev/null 2>&1
run_hook "$W" "git push"
want_code 0 "no source touched"
want_silent "no source touched"

W="$(mk_repo)"
( cd "$W" && mkdir -p lib && printf 'const x = 1;\n' > lib/a.js && git add lib/a.js && git commit -qm base && git push -q ) >/dev/null 2>&1
( cd "$W" && printf 'const x = 1;\n// explain the thing\n' > lib/a.js && git add lib/a.js && git commit -qm comment ) >/dev/null 2>&1
run_hook "$W" "git push"
want_code 0 "comment-only change"
want_silent "comment-only change"

# --- #733 regression probes, end to end this time -------------------------
# Leading-operator code: every changed line starts with '*', but 2 -> 3 is a
# real behavior change and must block.
W="$(mk_repo)"
( cd "$W" && mkdir -p lib && printf 'const a = b\n  * 2;\n' > lib/m.js && git add lib/m.js && git commit -qm base && git push -q ) >/dev/null 2>&1
( cd "$W" && printf 'const a = b\n  * 3;\n' > lib/m.js && git add lib/m.js && git commit -qm bump ) >/dev/null 2>&1
run_hook "$W" "git push"
want_code 2 "leading-operator change must BLOCK"

# Mode-only change: the diff has no content lines, which is not the same as
# having no change to see. Must block.
W="$(mk_repo)"
( cd "$W" && mkdir -p lib && printf 'const x = 1;\n' > lib/p.js && git add lib/p.js && git commit -qm base && git push -q ) >/dev/null 2>&1
( cd "$W" && chmod +x lib/p.js && git add lib/p.js && git commit -qm chmod ) >/dev/null 2>&1
run_hook "$W" "git push"
want_code 2 "mode-only change must BLOCK"

# --- the add && commit && push chain is a different code path -------------
W="$(mk_repo)"
( cd "$W" && mkdir -p lib && printf 'const y = 2;\n' > lib/chain.js ) >/dev/null 2>&1
run_hook "$W" "git add . && git commit -m 'x' && git push"
want_code 2 "chain: source with no test must BLOCK"

W="$(mk_repo)"
( cd "$W" && mkdir -p lib tests && printf 'const y = 2;\n' > lib/chain.js \
    && printf 'test("y", () => {});\n' > tests/chain.test.js ) >/dev/null 2>&1
STUB_CLAUDE_OUT='{"result":"{\"verdict\":\"pass\",\"changes\":[],\"missing\":[]}"}' \
  run_hook "$W" "git add . && git commit -m 'x' && git push"
want_code 0 "chain: source with a test reaches the judge and passes"

echo
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
