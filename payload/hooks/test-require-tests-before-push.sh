#!/usr/bin/env bash
# Tests for require-tests-before-push.sh: the docs-only classifier (docs_style_for / diff_docs_only)
# sourced out of the hook, and the whole gate driven end to end as a subprocess. The is_test /
# is_source file classifier moved to lib/source-class.sh (shared with simplify-before-push.sh); its
# cases live in test-source-class.sh and this suite no longer asserts on it directly (the end to end
# runs exercise it through the real hook, which sources the lib itself).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/require-tests-before-push.sh"

# docs_style_for / diff_docs_only are this gate's own, so they are pulled out of the hook. is_test /
# is_source are not used here: they moved to lib/source-class.sh and test-source-class.sh covers them.
eval "$(sed -n '/^docs_style_for() {/,/^}/p' "$HOOK")"
eval "$(sed -n '/^diff_docs_only() {/,/^}/p' "$HOOK")"

pass=0
fail=0
want_docsonly()    { if printf '%s' "$2" | diff_docs_only "$1"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: expected DOCS-ONLY ($1): [$2]"; fi; }
want_notdocsonly() { if printf '%s' "$2" | diff_docs_only "$1"; then fail=$((fail+1)); echo "FAIL: expected NOT-docs-only ($1): [$2]"; else pass=$((pass+1)); fi; }
want_style()       { local got; got="$(docs_style_for "$1")"; if [ "$got" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: style $1 expected $2 got $got"; fi; }

# The is_test / is_source classification cases moved to test-source-class.sh when the classifier
# moved to lib/source-class.sh. The end-to-end cases below still drive the real hook, which sources
# the same lib, so a classification regression that mattered to THIS gate still shows here.

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
# Editing wording inside an EXISTING block comment, with no '/*' opener in what
# the diff shows, cannot be told from leading-operator code, so without the lines
# above it this still blocks rather than reopen the hole above.
want_notdocsonly slash "$(printf -- '--- a/foo.js\n+++ b/foo.js\n@@\n- * old wording\n+ * new wording\n')"

# --- claude-config#1238: judged from the file the line sits in ---------------
# The gate reads each file's diff with every line of the file around it, so a
# '*' line is a comment exactly when its own image has a '/*' open above it and
# no '*/' between. Rewording inside an existing JSDoc passes; the
# leading-operator change still blocks, however many comments sit above it.
want_docsonly slash "$(printf -- 'diff --git a/f.js b/f.js\n--- a/f.js\n+++ b/f.js\n@@ -1,6 +1,6 @@\n /**\n  * keep\n- * old wording\n+ * new wording\n  */\n const a = 1;\n')"
want_docsonly slash "$(printf -- 'diff --git a/f.js b/f.js\n--- a/f.js\n+++ b/f.js\n@@ -1,4 +1,3 @@\n /*\n- * a line taken out\n  * kept\n  */\n')"
want_notdocsonly slash "$(printf -- 'diff --git a/m.js b/m.js\n--- a/m.js\n+++ b/m.js\n@@ -1,3 +1,3 @@\n /* a note */\n const a = b\n-  * 2;\n+  * 3;\n')"
want_notdocsonly slash "$(printf -- 'diff --git a/s.js b/s.js\n--- a/s.js\n+++ b/s.js\n@@ -1,2 +1,2 @@\n const s = "/*";\n-  * 2;\n+  * 3;\n')"
# Lines above the first hunk, or between two, are not shown, so what they leave
# open is unknown and a '*' line there is not trusted.
want_notdocsonly slash "$(printf -- 'diff --git a/g.js b/g.js\n--- a/g.js\n+++ b/g.js\n@@ -4,2 +4,2 @@\n x = 1;\n- * old wording\n+ * new wording\n')"
want_notdocsonly slash "$(printf -- 'diff --git a/h.js b/h.js\n--- a/h.js\n+++ b/h.js\n@@ -1,2 +1,2 @@\n /**\n- * one\n+ * two\n@@ -9,2 +9,2 @@\n x = 1;\n- * three\n+ * four\n')"
# A line holding code beside a comment is code, whichever comes first.
want_notdocsonly slash "$(printf -- 'diff --git a/i.js b/i.js\n--- a/i.js\n+++ b/i.js\n@@ -1,2 +1,2 @@\n x = 1;\n-/* a */ y = 2;\n+/* b */ y = 3;\n')"

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
if [ -n "${STUB_CLAUDE_STDIN:-}" ]; then cat > "$STUB_CLAUDE_STDIN"; else cat >/dev/null; fi
[ -n "${STUB_CLAUDE_ARGS:-}" ] && printf '%s\n' "$@" > "$STUB_CLAUDE_ARGS"
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

# The gate records every push it reaches (claude-config#1075). Pointed at a throwaway ledger so a
# test push is never counted among real ones; LEDGER is what the record cases below read.
export PUSH_GATE_LEDGER_DIR="$TMPROOT/ledger"
LEDGER="$PUSH_GATE_LEDGER_DIR/push-gates.tsv"

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
sys.stdout.write(json.dumps({"tool_input":{"command":os.environ["HK_CMD"]},"cwd":os.environ["HK_CWD"],"tool_use_id":os.environ.get("HK_ID","toolu_test")}))')"
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

# --- The repo comes from the COMMAND when the session sits elsewhere ------
# The payload's cwd is the SESSION's directory, not the project's. A session
# rooted somewhere else reaches a project as `cd <repo> && git push` or
# `git -C <repo> push`, and resolving the cwd alone made the gate see no work
# tree and wave those pushes through untested, silently.
NOTREPO="$(mktemp -d)"
W="$(mk_repo)"; seed_source_only "$W"
run_hook "$NOTREPO" "cd $W && git push"
want_code 2 "cd-then-push from a non-repo cwd must BLOCK"

W="$(mk_repo)"; seed_source_only "$W"
run_hook "$NOTREPO" "git -C $W push"
want_code 2 "git -C push from a non-repo cwd must BLOCK"

# ...and a genuinely unrelated directory still gates nothing.
run_hook "$NOTREPO" "git push"
want_code 0 "a push with no resolvable repo stays out of the way"

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

# --- claude-config#723: the reviewer sees every test change, or is told it does not ---------
# The test changes used to be cut to half the 60 KB budget and then labelled as shown "in full".
# On 2026-10-05 the #714 push's winding down tests sat in tests/register.test.tsx past the cut, the
# reviewer called that change untested, and the push was refused for a test it carried.
seed_big_tests() {   # $1 = repo  $2 = KB of test diff  ->  a source change plus tests, the last line a marker
  local w="$1" kb="$2"
  (
    cd "$w" || exit 1
    mkdir -p lib tests
    printf 'export function windDown() { return 1; }\n' > lib/wind.js
    python3 -c 'import sys
kb = int(sys.argv[1])
for i in range(kb * 1024 // 64):
    print("test(\"case %05d\", () => { expect(pad(%05d)).toBe(%05d); });" % (i, i, i))
print("test(\"winds down\", () => { expect(windDown()).toBe(1); }); // WINDING_DOWN_MARKER")' "$kb" > tests/register.test.js
    git add lib/wind.js tests/register.test.js
    git commit -qm "wind down"
  ) >/dev/null 2>&1
}
JUDGE_IN="$TMPROOT/judge-stdin"

# 40 KB of tests and a small source change fit the budget together: the tests are given what
# they need first, so the test at the end is in front of the reviewer, and the label is true.
W="$(mk_repo)"; seed_big_tests "$W" 40; rm -f "$JUDGE_IN"
STUB_CLAUDE_STDIN="$JUDGE_IN" STUB_CLAUDE_OUT='{"result":"{\"verdict\":\"pass\",\"changes\":[],\"missing\":[]}"}' \
  run_hook "$W" "git push"
want_code 0 "#723 a push with 40 KB of tests is judged"
if grep -q 'WINDING_DOWN_MARKER' "$JUDGE_IN" 2>/dev/null; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #723 a test past 30 KB of test changes never reached the reviewer"; fi
if grep -q 'TRUNCATED' "$JUDGE_IN" 2>/dev/null; then fail=$((fail+1)); echo "FAIL: #723 a push that fits was labelled truncated"
else pass=$((pass+1)); fi

# Tests larger than the whole budget: the prompt says they are cut and names the file, never
# "in full", and a "no test" verdict is refused as COULD NOT JUDGE, naming the file, rather than
# as a finding that tests are missing. It still refuses: a gate that cannot read the push does not
# wave it through (L42); the remedy it names is a smaller push.
W="$(mk_repo)"; seed_big_tests "$W" 90; rm -f "$JUDGE_IN"
STUB_CLAUDE_STDIN="$JUDGE_IN" STUB_CLAUDE_OUT='{"result":"{\"verdict\":\"block\",\"changes\":[],\"missing\":[\"the wind down change\"]}"}' \
  run_hook "$W" "git push"
want_code 2 "#723 a truncated push the reviewer calls untested is still refused"
want_stderr "could not judge" "#723 the refusal says the gate could not judge the push in full"
want_stderr "tests/register.test.js" "#723 and names the test file that was cut"
want_stderr "fewer commits|smaller push|split" "#723 and says how to make it judgeable"
case "$ERR" in
  *'have no test covering them'*) fail=$((fail+1)); echo "FAIL: #723 a truncated push was refused as missing tests: [$ERR]" ;;
  *) pass=$((pass+1)) ;;
esac
if grep -q 'in full' "$JUDGE_IN" 2>/dev/null; then fail=$((fail+1)); echo "FAIL: #723 the prompt claims test changes in full over a cut"
else pass=$((pass+1)); fi
if grep -q 'TRUNCATED' "$JUDGE_IN" 2>/dev/null && grep -q 'tests/register.test.js' "$JUDGE_IN"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #723 the prompt does not say the test changes were cut, naming the file"; fi

# And a truncated push the reviewer PASSES is allowed: the cut only ever withholds a refusal's
# accusation, never adds one.
W="$(mk_repo)"; seed_big_tests "$W" 90
STUB_CLAUDE_OUT='{"result":"{\"verdict\":\"pass\",\"changes\":[],\"missing\":[]}"}' run_hook "$W" "git push"
want_code 0 "#723 a truncated push the reviewer passes is allowed"

# --- claude-config#930, end to end: the push that was refused --------------
# A push changing only a suite file inside an Xcode test target folder changes no source, so the
# gate has nothing to judge and stays silent. Before #930 it was refused at the zero test floor.
W="$(mk_repo)"
( cd "$W" && mkdir -p mac/OvertureTests \
    && printf 'func testDivergence() { XCTAssertTrue(true) }\n' > mac/OvertureTests/EngineDivergenceGate.swift \
    && git add mac/OvertureTests/EngineDivergenceGate.swift && git commit -qm "two more cases" ) >/dev/null 2>&1
run_hook "$W" "git push"
want_code 0 "#930 a push changing only a file in an Xcode test target folder is allowed"
want_silent "#930 a push changing only a file in an Xcode test target folder is allowed"

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

# claude-config#1238: rewording a line inside a block comment that already exists
# is documentation, judged from the file the line sits in. Before this it blocked,
# because the diff shows no '/*' opener, and the comment fix on Bidspoke #2228
# needed a one time override.
# The opener sits more than git's three lines of default context above the changed
# line, so only a diff read with the whole file around it can see it.
DOC_BEFORE='/**\n * Adds two numbers.\n *\n * Both may be negative.\n * Neither may be NaN.\n *\n * Returns their sum.\n */\nfunction add(a, b) {\n  return a + b;\n}\n'
DOC_AFTER='/**\n * Adds two numbers.\n *\n * Both may be negative.\n * Neither may be NaN.\n *\n * Returns the sum of both.\n */\nfunction add(a, b) {\n  return a + b;\n}\n'
W="$(mk_repo)"
( cd "$W" && mkdir -p lib && printf "$DOC_BEFORE" > lib/doc.js && git add lib/doc.js && git commit -qm base && git push -q ) >/dev/null 2>&1
( cd "$W" && printf "$DOC_AFTER" > lib/doc.js && git add lib/doc.js && git commit -qm reword ) >/dev/null 2>&1
run_hook "$W" "git push"
want_code 0 "#1238 rewording inside an existing block comment is allowed"
# The same edit made by the commit in the command, which reads a different diff.
W="$(mk_repo)"
( cd "$W" && mkdir -p lib && printf "$DOC_BEFORE" > lib/doc.js && git add lib/doc.js && git commit -qm base && git push -q ) >/dev/null 2>&1
( cd "$W" && printf "$DOC_AFTER" > lib/doc.js ) >/dev/null 2>&1
run_hook "$W" "git add lib/doc.js && git commit -m reword && git push"
want_code 0 "#1238 the same rewording made by the command's own commit is allowed"
# And a leading-operator change BELOW a closed block comment still blocks: the
# comment above it is closed, so the '*' line is code.
W="$(mk_repo)"
( cd "$W" && mkdir -p lib && printf '/* the factor */\nconst a = b\n  * 2;\n' > lib/n.js && git add lib/n.js && git commit -qm base && git push -q ) >/dev/null 2>&1
( cd "$W" && printf '/* the factor */\nconst a = b\n  * 3;\n' > lib/n.js && git add lib/n.js && git commit -qm bump ) >/dev/null 2>&1
run_hook "$W" "git push"
want_code 2 "#1238 a leading-operator change below a closed block comment still BLOCKS"

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

# --- #736: a base that resolves to HEAD itself means the gate is blind ------
# With no upstream, the base falls back through origin/HEAD, origin/main,
# origin/master, main, master. On an unpushed branch that lands on the CURRENT
# branch, so merge-base is HEAD, the diff is empty, and the hook finds nothing
# to gate. That is the trap that fake-greened the #733 scratch scripts.

# A repo with real commits and NO upstream at all.
mk_repo_no_upstream() {
  local root
  root="$(mktemp -d "$TMPROOT/noup.XXXXXX")"
  git init -q "$root/work"
  (
    cd "$root/work" || exit 1
    git config user.email t@example.com
    git config user.name tester
    git config commit.gpgsign false
    echo init > README.md
    git add README.md
    git commit -qm init
  ) >/dev/null 2>&1
  printf '%s' "$root/work"
}

W="$(mk_repo_no_upstream)"; seed_source_only "$W"
run_hook "$W" "git push"
want_code 1 "no upstream: gate is blind and must say so"
want_stderr "upstream" "no upstream: gate is blind and must say so"

# Nothing new to push, WITH an upstream, is a legitimate empty diff. The gate
# saw everything and there was nothing to gate, so it must stay silent.
W="$(mk_repo)"
run_hook "$W" "git push"
want_code 0 "up to date with upstream: nothing to gate"
want_silent "up to date with upstream: nothing to gate"

# No upstream, but the chain stages the work, so the gate CAN see the pending
# files without needing a base. It must judge them, not cry blindness.
W="$(mk_repo_no_upstream)"
( cd "$W" && mkdir -p lib && printf 'const z = 9;\n' > lib/n.js ) >/dev/null 2>&1
run_hook "$W" "git add . && git commit -m 'x' && git push"
want_code 2 "no upstream but chain staged the work: still BLOCKS on a missing test"

# --- claude-config#457 item 1: the shared range and add helpers -------------
# A test file that is tracked and modified but NOT named by the add stays on disk: the commit does
# not carry it. The gate's own sed parser counted every unstaged tracked change for any add, so a
# test left out of the commit satisfied the gate for the source that went in.
W="$(mk_repo)"
( cd "$W" && mkdir -p lib tests && printf 'const a = 1;\n' > lib/a.js \
    && printf 'test("a", () => {});\n' > tests/a.test.js \
    && git add lib/a.js tests/a.test.js && git commit -qm base && git push -q \
    && printf 'const a = 2;\n' > lib/a.js && printf 'test("a2", () => {});\n' > tests/a.test.js ) >/dev/null 2>&1
run_hook "$W" "git add lib/a.js && git commit -m 'x' && git push"
want_code 2 "an add naming only the source does not count the test it leaves behind"
# The control in the same repository: name the test too and it is counted.
STUB_CLAUDE_OUT='{"result":"{\"verdict\":\"pass\",\"changes\":[],\"missing\":[]}"}' \
  run_hook "$W" "git add lib/a.js tests/a.test.js && git commit -m 'x' && git push"
want_code 0 "and naming the test as well counts it"

# A push level with its upstream after several commits carries nothing, and must not re-judge the
# last commit already on the remote (and bill the judge for it).
W="$(mk_repo)"; seed_source_only "$W"
( cd "$W" && git push -q ) >/dev/null 2>&1
run_hook "$W" "git push"
want_code 0 "a push level with its upstream does not re-judge the last pushed commit"
want_silent "a push level with its upstream does not re-judge the last pushed commit"

# --- the judge runs without the global config ------------------------------
# `--setting-sources local` is what keeps the global CLAUDE.md and the lessons index out of the
# judge: measured 14,802 input tokens with it against 56,808 without (claude-config#540). Nothing
# else says so, so dropping the flag would quietly quadruple every judge call and hand it rules
# meant for the session. Both launches are checked, since which one runs depends on whether a
# timeout binary is on the PATH, and this suite's PATH normally has none.
ARGS_FILE="$TMPROOT/judge-args"
TIMEOUT_STUB_DIR="$TMPROOT/timeout-stub"; mkdir -p "$TIMEOUT_STUB_DIR"
printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$TIMEOUT_STUB_DIR/timeout"; chmod +x "$TIMEOUT_STUB_DIR/timeout"
for judge_path in "$PATH_STUB" "$TIMEOUT_STUB_DIR:$PATH_STUB"; do
  case "$judge_path" in "$TIMEOUT_STUB_DIR"*) how="with a timeout binary" ;; *) how="without a timeout binary" ;; esac
  rm -f "$ARGS_FILE"
  W="$(mk_repo)"; seed_source_and_test "$W"
  STUB_CLAUDE_ARGS="$ARGS_FILE" STUB_CLAUDE_OUT='{"result":"{\"verdict\":\"pass\",\"changes\":[],\"missing\":[]}"}' \
    run_hook "$W" "git push" "$judge_path"
  if [ -f "$ARGS_FILE" ] && grep -qx -- '--setting-sources' "$ARGS_FILE" \
     && [ "$(grep -A1 -x -- '--setting-sources' "$ARGS_FILE" | tail -1)" = "local" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL: the judge $how is not launched with --setting-sources local (flags: $(grep -- '^--' "$ARGS_FILE" 2>/dev/null | tr '\n' ' ' || echo 'judge never ran'))"
  fi
done

# --- a test written in the same command reaches the judge (claude-config#1076) ----------------------
# `git add lib/x.js tests/x.test.js && git commit && git push` with both files new: before the
# command runs they are untracked, so no diff shows them. The gate meant to append their text and
# read a variable it never set, so the judge was told a test existed and shown none of it, and judged
# coverage from a file name.
PASS_JSON='{"result":"{\"verdict\":\"pass\",\"changes\":[],\"missing\":[]}"}'
W="$(mk_repo)"
( cd "$W" && mkdir -p lib tests \
    && printf 'export const wind = () => 1;\n' > lib/wind.js \
    && printf 'test("wind_marker_case", () => {});\n' > tests/wind.test.js \
    && printf 'export const stray_untracked = 2;\n' > lib/stray.js ) >/dev/null 2>&1
JUDGE_IN="$TMPROOT/judge-new-files"; rm -f "$JUDGE_IN"
STUB_CLAUDE_STDIN="$JUDGE_IN" STUB_CLAUDE_OUT="$PASS_JSON" \
  run_hook "$W" "git add lib/wind.js tests/wind.test.js && git commit -m wind && git push"
want_code 0 "a chain adding a new source and its new test is judged"
if grep -q 'wind_marker_case' "$JUDGE_IN" 2>/dev/null; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: the new test file in the commit never reached the judge"; fi
if grep -q 'export const wind' "$JUDGE_IN" 2>/dev/null; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: the new source file in the commit never reached the judge"; fi
if grep -q 'stray_untracked' "$JUDGE_IN" 2>/dev/null; then fail=$((fail+1)); echo "FAIL: an untracked file the commit does not take was shown to the judge"; else pass=$((pass+1)); fi

# --- a push run from a SUBDIRECTORY is judged on the whole push (claude-config#1076) ----------------
W="$(mk_repo)"; seed_source_and_test "$W"; mkdir -p "$W/docs"
JUDGE_IN="$TMPROOT/judge-subdir"; rm -f "$JUDGE_IN"
STUB_CLAUDE_STDIN="$JUDGE_IN" STUB_CLAUDE_OUT='{"result":"{\"verdict\":\"block\",\"changes\":[],\"missing\":[\"the add change\"]}"}' \
  run_hook "$W/docs" "git push"
want_code 2 "a push from a subdirectory is still judged"
if grep -q 'return a + b' "$JUDGE_IN" 2>/dev/null && grep -q 'toBe(3)' "$JUDGE_IN" 2>/dev/null; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a push from a subdirectory did not show the judge the source and test outside it"; fi

# --- a judge that never answers in time is named as such --------------------------------------------
TO_DIR="$TMPROOT/timeout-124"; mkdir -p "$TO_DIR"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 124\n' > "$TO_DIR/timeout"; chmod +x "$TO_DIR/timeout"
W="$(mk_repo)"; seed_source_and_test "$W"
run_hook "$W" "git push" "$TO_DIR:$PATH_STUB"
want_code 1 "judge timed out"
want_stderr "timed out after 90s" "judge timed out"

# --- the record of what the gate did (claude-config#1075, #1077) ------------------------------------
# Recorded like the simplify gate's, into the same ledger, so how often both judges are called on
# one push can be counted rather than guessed.
row_of() { awk -F '\t' -v id="$1" '$7 == id' "$LEDGER" 2>/dev/null | tail -1; }
col() { printf '%s' "$1" | awk -F '\t' -v n="$2" '{ print $n }'; }
want_row() {   # <call id> <outcome> <label> [detail pattern]
  local r; r="$(row_of "$1")"
  if [ "$(col "$r" 3)" = tests ] && [ "$(col "$r" 4)" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $3: expected a tests row with outcome $2, got [$r]"; fi
  if [ -n "${4:-}" ]; then
    if grep -Eq "$4" <<< "$(col "$r" 14)"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $3: the row's detail did not match /$4/: [$(col "$r" 14)]"; fi
  fi
}
W="$(mk_repo)"; seed_source_only "$W"
HK_ID=t-untested run_hook "$W" "git push"
want_row t-untested untested "a push with source and no test is recorded"
HK_ID=t-override run_hook "$W" "SKIP_TEST_CHECK=1 git push"
want_row t-override override "an override is recorded"
W="$(mk_repo)"; seed_source_and_test "$W"
HK_ID=t-block STUB_CLAUDE_OUT='{"result":"{\"verdict\":\"block\",\"changes\":[],\"missing\":[\"the add change\"]}"}' run_hook "$W" "git push"
want_row t-block block "a judged block is recorded with what it named" 'the add change'
if [ "$(col "$(row_of t-block)" 8)" = sonnet ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: the block row does not name the model: [$(row_of t-block)]"; fi
HK_ID=t-pass STUB_CLAUDE_OUT="$PASS_JSON" run_hook "$W" "git push"
want_row t-pass pass "a judged pass is recorded"
HK_ID=t-open STUB_CLAUDE_OUT='{"is_error":true,"result":"boom"}' run_hook "$W" "git push"
want_row t-open failopen "a fail open is recorded with its reason" 'error envelope'
W="$(mk_repo)"
( cd "$W" && printf 'nothing but words\n' > notes.md && git add notes.md && git commit -qm docs ) >/dev/null 2>&1
HK_ID=t-nosource run_hook "$W" "git push"
want_row t-nosource nosource "a push with no source is recorded"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
