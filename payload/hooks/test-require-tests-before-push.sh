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

# docs_style_for / diff_docs_only / py_docstrings_as_comments are this gate's own, so they are
# pulled out of the hook. is_test / is_source are not used here: they moved to lib/source-class.sh
# and test-source-class.sh covers them.
#
# The definitions are copied into a scratch script that runs the one named in its arguments, and
# each is called through it as a process of its own, rather than evaluated into this shell. An
# eval here ends what the Slack drafts gate can follow of this suite's variables, so it could not
# work out the files sourced further down (claude-config#2538). Every case below reaches the
# hook's own definition all the same, and anything a case changes for one call (HOOK_DIR, a
# stand in mktemp on PATH) is handed to that process.
FNS_DIR="$(mktemp -d)"
FNS="$FNS_DIR/hook-functions.sh"
{
  sed -n '/^docs_style_for() {/,/^}/p; /^diff_docs_only() {/,/^}/p; /^py_docstrings_as_comments() {/,/^}/p' "$HOOK"
  printf '%s\n' '"$@"'
} > "$FNS"
pass=0
fail=0
# A function the copy missed would fail every call, which each "expected NOT docs-only" case would
# then count as a pass, so each must be found before any case is believed (L98).
for fn in docs_style_for diff_docs_only py_docstrings_as_comments; do
  grep -q "^$fn() {" "$FNS" || { fail=$((fail+1)); echo "FAIL: $fn() was not found in $HOOK, so the cases calling it prove nothing"; }
done
docs_style_for() { bash "$FNS" docs_style_for "$@"; }
diff_docs_only() { bash "$FNS" diff_docs_only "$@"; }
MKTEMP_STANDIN=""
py_docstrings_as_comments() {
  HOOK_DIR="$HOOK_DIR" PATH="${MKTEMP_STANDIN:+$MKTEMP_STANDIN:}$PATH" bash "$FNS" py_docstrings_as_comments "$@"
}

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

# --- claude-config#2247: a line inside a Python docstring is documentation ---
# A docstring (the first statement of a module, class or function, when it is a plain string, as
# Python defines it) is read by lib/py-docstring-lines.py with Python's own parser, from both images
# of the file, and each changed line lying wholly inside one is handed to the reader as a '#'
# comment. Anything else is judged as before: an ordinary string, a string that is not the first
# statement, code on the docstring's own line, a file either image of which does not parse, and a
# diff not covering the file from its first line.
HOOK_DIR="$DIR"
want_pydocs()    { if printf '%s' "$1" | py_docstrings_as_comments | diff_docs_only hash; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: #2247 expected DOCS-ONLY: [$1]"; fi; }
want_notpydocs() { if printf '%s' "$1" | py_docstrings_as_comments | diff_docs_only hash; then fail=$((fail+1)); echo "FAIL: #2247 expected NOT-docs-only: [$1]"; else pass=$((pass+1)); fi; }
PYH='diff --git a/s.py b/s.py\n--- a/s.py\n+++ b/s.py\n'
# Newly let through: a function, class, async function or module docstring reworded, one line or
# several, with a comment after its closing quotes, or with a comment changed beside it.
want_pydocs "$(printf -- "$PYH"'@@ -1,3 +1,3 @@\n def f():\n-    """Old words."""\n+    """New words."""\n     return 1\n')"
want_pydocs "$(printf -- "$PYH"'@@ -1,5 +1,5 @@\n """Module summary.\n \n-Old detail.\n+New detail.\n """\n import os\n')"
want_pydocs "$(printf -- "$PYH"'@@ -1,4 +1,4 @@\n class A:\n     """Summary.\n-    old\n+    new\n     """\n')"
want_pydocs "$(printf -- "$PYH"'@@ -1,3 +1,3 @@\n async def g():\n-    """Old."""  # note\n+    """New."""  # note\n     return 2\n')"
want_pydocs "$(printf -- "$PYH"'@@ -1,3 +1,4 @@\n def f():\n-    """Old."""\n+    # a comment\n+    """New."""\n     return 1\n')"
want_pydocs "$(printf -- "$PYH"'@@ -1,3 +1,3 @@\n def f():\n-    r"""Raw \\d old."""\n+    r"""Raw \\d new."""\n     return 1\n')"
# Still refused: a docstring and a code line changed together.
want_notpydocs "$(printf -- "$PYH"'@@ -1,3 +1,3 @@\n def f():\n-    """Old words."""\n-    return 1\n+    """New words."""\n+    return 2\n')"
# Still refused: an ordinary string literal, and a string statement that is not the first.
want_notpydocs "$(printf -- "$PYH"'@@ -1,1 +1,1 @@\n-x = """old"""\n+x = """new"""\n')"
want_notpydocs "$(printf -- "$PYH"'@@ -1,3 +1,3 @@\n def f():\n     y = 1\n-    """old"""\n+    """new"""\n')"
# Still refused: a bytes string and an f-string are not docstrings.
want_notpydocs "$(printf -- "$PYH"'@@ -1,2 +1,2 @@\n def f():\n-    b"""old"""\n+    b"""new"""\n')"
want_notpydocs "$(printf -- "$PYH"'@@ -1,2 +1,2 @@\n def f():\n-    f"""old"""\n+    f"""new"""\n')"
# Still refused: code on the docstring's own line, before it or after it.
want_notpydocs "$(printf -- "$PYH"'@@ -1,2 +1,2 @@\n def f():\n-    """Doc."""; x = 1\n+    """Doc."""; x = 2\n')"
want_notpydocs "$(printf -- "$PYH"'@@ -1,1 +1,1 @@\n-def f(): """Old."""\n+def f(): """New."""\n')"
# Still refused: a file that does not parse, in the new image or the old one.
want_notpydocs "$(printf -- "$PYH"'@@ -1,2 +1,2 @@\n def f(:\n-    """Old."""\n+    """New."""\n')"
want_notpydocs "$(printf -- "$PYH"'@@ -1,2 +1,2 @@\n-def f(:\n+def f():\n     """Doc."""\n')"
# Still refused: code moved into a docstring, or out of one, is code in the image it is code in.
want_notpydocs "$(printf -- "$PYH"'@@ -1,3 +1,3 @@\n def f():\n-    """Doc."""\n-    return 1\n+    """Doc.\n+    return 1"""\n')"
want_notpydocs "$(printf -- "$PYH"'@@ -1,3 +1,3 @@\n def f():\n-    """Doc.\n-    return 1"""\n+    """Doc."""\n+    return 1\n')"
# Still refused: a diff not read from the file's first line, or in two hunks, places no line.
want_notpydocs "$(printf -- "$PYH"'@@ -4,3 +4,3 @@\n def f():\n-    """Old words."""\n+    """New words."""\n     return 1\n')"
want_notpydocs "$(printf -- "$PYH"'@@ -1,3 +1,3 @@\n def f():\n-    """Old words."""\n+    """New words."""\n     return 1\n@@ -9,2 +9,2 @@\n def g():\n-    """Old."""\n+    """New."""\n')"
# Still refused: a hunk header that cannot be read.
want_notpydocs "$(printf -- "$PYH"'@@\n def f():\n-    """Old words."""\n+    """New words."""\n     return 1\n')"
# Still refused: a file whose own code reads __doc__ (a usage message or an argparse description
# cut from its docstring, as regal-journey-edits/jdiff.py does) runs on its docstrings, so none
# of them is documentation there.
want_notpydocs "$(printf -- "$PYH"'@@ -1,5 +1,5 @@\n """Tool.\n \n-Usage: old\n+Usage: new\n """\n USAGE = __doc__.split("\\n\\n")[1]\n')"
want_notpydocs "$(printf -- "$PYH"'@@ -1,3 +1,3 @@\n def f():\n-    """Old."""\n+    """New."""\n print(f.__doc__)\n')"
# Still refused: no change at all, as before.
want_notpydocs ""
# When the helper cannot be trusted, the diff goes on exactly as git gave it: a docstring change is
# judged as code again, and a plain '#' comment change still passes as it did before #2247.
PYDOC_OK="$(printf -- "$PYH"'@@ -1,3 +1,3 @@\n def f():\n-    """Old words."""\n+    """New words."""\n     return 1\n')"
PYCOMMENT="$(printf -- "$PYH"'@@ -1,3 +1,3 @@\n def f():\n-    # old words\n+    # new words\n     return 1\n')"
PYFAKE="$(mktemp -d)"
mkdir -p "$PYFAKE/missing/lib" "$PYFAKE/short/lib" "$PYFAKE/dies/lib"
printf '%s\n' 'import sys' 'sys.stdout.write("+# x\n")' > "$PYFAKE/short/lib/py-docstring-lines.py"
printf '%s\n' 'import sys' 'sys.stdout.write("+# x\n")' 'sys.exit(3)' > "$PYFAKE/dies/lib/py-docstring-lines.py"
for PYCASE in missing short dies; do
  HOOK_DIR="$PYFAKE/$PYCASE"
  want_notpydocs "$PYDOC_OK"
  want_pydocs "$PYCOMMENT"
done
HOOK_DIR="$DIR"
# The function runs as a process of its own, so a stand in mktemp reaches it as a command first on
# its PATH (MKTEMP_STANDIN, read by the py_docstrings_as_comments wrapper at the top).
mkdir -p "$PYFAKE/mktemp-fails" "$PYFAKE/mktemp-unwritable"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$PYFAKE/mktemp-fails/mktemp"
printf '%s\n' '#!/bin/sh' "echo '$PYFAKE/no-such-dir/x'" > "$PYFAKE/mktemp-unwritable/mktemp"
chmod +x "$PYFAKE/mktemp-fails/mktemp" "$PYFAKE/mktemp-unwritable/mktemp"
# No scratch file can be made: the diff passes through untouched, judged as before.
MKTEMP_STANDIN="$PYFAKE/mktemp-fails"
want_notpydocs "$PYDOC_OK"
want_pydocs "$PYCOMMENT"
# A scratch file is made but the diff cannot be written to it: nothing goes on, which is never
# documentation, so even a comment change is refused rather than judged on part of its diff.
MKTEMP_STANDIN="$PYFAKE/mktemp-unwritable"
want_notpydocs "$PYCOMMENT"
MKTEMP_STANDIN=""
rm -rf "$PYFAKE"

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

# STUB_CLAUDE_LOG, a directory: each call's input is kept there as call.1, call.2 and so on, so a
# case can count the calls and read what each one was shown. STUB_CLAUDE_RULES, a file of lines
# "<text><TAB><answer>": the first line whose text appears in the call's input gives the answer,
# so the stub answers by what it was SHOWN, as a judge does (#1998); no rule matching, it answers
# STUB_CLAUDE_OUT.
STUB_DIR="$(mktemp -d)"
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
input="$(cat)"
# STUB_CLAUDE_VANISH: the stand in removes itself once it has read its input, so every later call
# finds no claude on the path and fails before it launches (#2153).
[ -n "${STUB_CLAUDE_VANISH:-}" ] && rm -f "$0"
# STUB_CLAUDE_SLEEP: seconds each call takes, so the hook's own clock moves past a deadline while
# a reading runs (#2249); the hook's clock cannot be set mid run, only at its start.
[ -n "${STUB_CLAUDE_SLEEP:-}" ] && sleep "$STUB_CLAUDE_SLEEP"
[ -n "${STUB_CLAUDE_STDIN:-}" ] && printf '%s' "$input" > "$STUB_CLAUDE_STDIN"
if [ -n "${STUB_CLAUDE_LOG:-}" ]; then
  # Claimed with noclobber, because further readings run at once (#2153) and two calls looking for
  # the first free number at the same moment would write one file.
  n=1; while ! ( set -C; : > "$STUB_CLAUDE_LOG/call.$n" ) 2>/dev/null; do n=$((n+1)); done
  printf '%s' "$input" > "$STUB_CLAUDE_LOG/call.$n"
fi
# STUB_CLAUDE_MEET, a directory: a call over the rest of the tests marks itself there and waits, no
# longer than the hang ceiling FAKE_HANG_S hands this stand in (hooks/lib/hang-wait.sh), for a
# second such call to start, recording "met" when one does. Readings made one after another never
# meet; readings made at once do, without any fixed sleep deciding it.
if [ -n "${STUB_CLAUDE_MEET:-}" ]; then
  case "$input" in *'CHANGES THE FIRST READER FOUND NO TEST FOR'*)
    # The mark is taken away when the call ends, so two calls one after the other are never both
    # marked; once two have met, later calls do not wait. The marks are counted by a glob, never a
    # pipeline into grep (test-pipefail-shortcircuit.sh); this call's own mark is always one of them.
    : > "$STUB_CLAUDE_MEET/started.$$"
    t0=$SECONDS; while [ ! -e "$STUB_CLAUDE_MEET/met" ] && [ $((SECONDS - t0)) -lt "${FAKE_HANG_S:-300}" ]; do
      marks=("$STUB_CLAUDE_MEET"/started.*)
      [ "${#marks[@]}" -ge 2 ] && { : > "$STUB_CLAUDE_MEET/met"; break; }
      sleep 0.1
    done
    rm -f "$STUB_CLAUDE_MEET/started.$$" ;;
  esac
fi
[ -n "${STUB_CLAUDE_ARGS:-}" ] && printf '%s\n' "$@" > "$STUB_CLAUDE_ARGS"
if [ -n "${STUB_CLAUDE_RULES:-}" ]; then
  while IFS=$'\t' read -r text answer; do
    [ -n "$text" ] || continue
    case "$input" in *"$text"*) printf '%s' "$answer"; exit "${STUB_CLAUDE_EXIT:-0}" ;; esac
  done < "$STUB_CLAUDE_RULES"
fi
[ -n "${STUB_CLAUDE_OUT:-}" ] && printf '%s' "$STUB_CLAUDE_OUT"
exit "${STUB_CLAUDE_EXIT:-0}"
STUB
chmod +x "$STUB_DIR/claude"
PATH_STUB="$STUB_DIR:$PATH_NOCLAUDE"

# One parent dir for every scratch repo. mk_repo runs inside $(...), a subshell,
# so it cannot append to an array in this shell: a tracking array would silently
# stay empty and leak every repo it made.
TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$STUB_DIR" "$TMPROOT" "$FNS_DIR"; }
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
OUT=""
# run_hook <cwd> <command> [PATH to use]
run_hook() {
  local cwd="$1" cmd="$2" usepath="${3:-$PATH_STUB}" payload errf
  errf="$(mktemp)"
  payload="$(HK_CMD="$cmd" HK_CWD="$cwd" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps({"tool_input":{"command":os.environ["HK_CMD"]},"cwd":os.environ["HK_CWD"],"tool_use_id":os.environ.get("HK_ID","toolu_test")}))')"
  OUT="$(printf '%s' "$payload" | env PATH="$usepath" bash "$HOOK" 2>"$errf")"
  CODE=$?
  ERR="$(cat "$errf")"
  rm -f "$errf"
}

want_code() {
  if [ "$CODE" = "$1" ]; then pass=$((pass+1));
  else fail=$((fail+1)); echo "FAIL: $2: expected exit $1, got $CODE"; fi
}
# A push the gate could not judge is let through with exit 0 and its notice as the systemMessage on
# stdout (claude-config#1912). It was exit 1, the non blocking error, whose first stderr line Claude
# Code shows; exit 1 is also what "onFailure": "block" refuses, so the notice moved to the channel
# that is shown on exit 0. stderr still carries it, for the debug log.
. "$DIR/lib/hook-notice.sh"
want_allowed_notice() {   # want_allowed_notice <desc> [ERE, default the gate's own DID NOT RUN]
  local why
  why="$(hook_notice_verdict "$OUT" "${2:-TEST GATE DID NOT RUN}")"
  if [ "$CODE" = 0 ] && [ -z "$why" ]; then pass=$((pass+1));
  else fail=$((fail+1)); echo "FAIL: #1912 $1: expected exit 0 with the notice as a systemMessage, got exit $CODE. $why"; fi
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

# --- #735: fail-open paths must SAY SO instead of vanishing ---------------
# exit 0 discards stderr entirely, so a notice there would be invisible. #735 said it with exit 1,
# the non blocking error; #1912 moved it to exit 0 with a systemMessage, which is shown and which
# "onFailure": "block" does not count as a failure.

# Unparseable payload.
ERRF="$(mktemp)"
OUT="$(printf 'this is not json' | env PATH="$PATH_STUB" bash "$HOOK" 2>"$ERRF")"
CODE=$?; ERR="$(cat "$ERRF")"; rm -f "$ERRF"
want_allowed_notice "unparseable payload"
want_stderr "payload" "unparseable payload"

# Judge binary missing.
W="$(mk_repo)"; seed_source_and_test "$W"
run_hook "$W" "git push" "$PATH_NOCLAUDE"
want_allowed_notice "judge CLI missing"
want_stderr "judge" "judge CLI missing"

# Judge returns nothing (unreachable or timed out).
W="$(mk_repo)"; seed_source_and_test "$W"
STUB_CLAUDE_OUT="" run_hook "$W" "git push"
want_allowed_notice "judge returned nothing"
want_stderr "judge" "judge returned nothing"

# Judge returns an is_error envelope.
W="$(mk_repo)"; seed_source_and_test "$W"
STUB_CLAUDE_OUT='{"is_error":true,"result":"boom"}' run_hook "$W" "git push"
want_allowed_notice "judge is_error envelope"
want_stderr "judge" "judge is_error envelope"

# Judge returns prose instead of the JSON verdict.
W="$(mk_repo)"; seed_source_and_test "$W"
STUB_CLAUDE_OUT='{"result":"sure thing, looks good to me"}' run_hook "$W" "git push"
want_allowed_notice "judge verdict unparseable"
want_stderr "judge" "judge verdict unparseable"

# A listing of the push that git FAILED is not an empty push (claude-config#2349). lib/push-changes.sh
# answered it as one, and the gate let the canary's untested change through silently, as "empty". It
# now says it could not read what the push carries. git is a stand in failing only that listing.
. "$DIR/lib/test_failing_git_listing.sh" || { fail=$((fail+1)); echo "FAIL: #2349 lib/test_failing_git_listing.sh is missing"; }
GF_DIR="$TMPROOT/gitfail"
failing_git_listing "$GF_DIR" committed || { fail=$((fail+1)); echo "FAIL: #2349 the failing git listing stand in could not be written"; }
W="$(mk_repo)"; seed_source_only "$W"
run_hook "$W" "git push" "$GF_DIR:$PATH_STUB"
want_allowed_notice "#2349 a failed listing of the push says the gate could not list it" "TEST GATE DID NOT RUN.*could not list the files this push carries"

# The same for each DIFF the gate reads (#2349 review): the files were listed, git failed showing
# their changes, and each reader took that as a diff with nothing in it. The stand in fails only the
# one diff each case names, so the case shows which reader it was.
# The docs only check: a diff it could not read is still not docs only, so the zero test floor still
# refuses (fail closed, #733), but the refusal now says why the comment only exemption was not given.
GF_DOCS="$TMPROOT/gitfail-docs"
failing_git_listing "$GF_DOCS" diff '*" diff -U"*' || { fail=$((fail+1)); echo "FAIL: #2349 the failing git diff stand in could not be written"; }
W="$(mk_repo)"
( cd "$W" && mkdir -p lib && printf '// a note on add\n' > lib/calc.js && git add lib/calc.js && git commit -qm note ) >/dev/null 2>&1
run_hook "$W" "git push" "$GF_DOCS:$PATH_STUB"
want_code 2 "#2349 a docs only check whose diff git failed still refuses an untested push"
want_stderr "could not check whether .*only comments" "#2349 the refusal says the docs only check could not read the diff"
want_stderr "git failed reading the diff of the commits since .* for lib/calc.js" "#2349 the refusal names the diff git failed and the file"
# The diff of the tests, and the diff of everything else: either one missing showed the judge a push
# with half of it gone, and a judge passing that half let the push through silently.
GF_TESTS="$TMPROOT/gitfail-tests"; GF_CODE="$TMPROOT/gitfail-code"
failing_git_listing "$GF_TESTS" diff '*" -- tests/calc.test.js "*' || { fail=$((fail+1)); echo "FAIL: #2349 the failing git diff stand in could not be written"; }
failing_git_listing "$GF_CODE" diff '*" -- . "*' || { fail=$((fail+1)); echo "FAIL: #2349 the failing git diff stand in could not be written"; }
for gf in tests:"$GF_TESTS" code:"$GF_CODE"; do
  W="$(mk_repo)"; seed_source_and_test "$W"
  GF_LOG="$TMPROOT/gitfail-log-${gf%%:*}"; rm -rf "$GF_LOG"; mkdir -p "$GF_LOG"
  STUB_CLAUDE_LOG="$GF_LOG" STUB_CLAUDE_OUT='{"result":"{\"verdict\":\"pass\",\"changes\":[],\"missing\":[]}"}' \
    run_hook "$W" "git push" "${gf#*:}:$PATH_STUB"
  want_allowed_notice "#2349 a failed diff of the ${gf%%:*} says the gate could not read it" "TEST GATE DID NOT RUN.*could not read the diff of the ${gf%%:*}"
  if [ ! -e "$GF_LOG/call.1" ]; then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: #2349 a push whose ${gf%%:*} diff git failed was sent to the judge"; fi
done

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
# wave it through (L42); the remedy it names is a smaller push. Since #1998 the rest of the test
# changes go to further calls, and this stub answers every call with a verdict, never the list of
# covered changes those calls ask for, so the push is still refused as could not judge; the first
# call's input is the prompt asserted on.
JUDGE_LOG="$TMPROOT/judge-log-723"; mkdir -p "$JUDGE_LOG"
W="$(mk_repo)"; seed_big_tests "$W" 90; rm -f "$JUDGE_IN"
STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_OUT='{"result":"{\"verdict\":\"block\",\"changes\":[],\"missing\":[\"the wind down change\"]}"}' \
  run_hook "$W" "git push"
cp "$JUDGE_LOG/call.1" "$JUDGE_IN" 2>/dev/null
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

# --- claude-config#1998: test changes past the cut are judged, not refused unseen -----------
# On 2026-10-31 a push carrying 34,407 bytes of test changes beside a large code change was refused:
# the reviewer was shown the first 30,000 bytes of the tests, called a change untested whose test
# sat past the cut, and the push got through only one commit at a time. Now the test changes the
# first call could not show go to further calls, each shown the changes still called untested, the
# code, and the next part of the tests, so a refusal rests only on tests a reviewer was shown.
#
# The judge stubbed here answers by what it is SHOWN: it calls the change covered only when its
# input holds the covering test (the marker), and untested otherwise.
seed_issue_push() {   # $1 = repo  ->  about 31 KB of code and 34 KB of tests, the covering test last
  local w="$1"
  (
    cd "$w" || exit 1
    mkdir -p lib tests
    python3 -c 'for i in range(31 * 1024 // 40):
    print("export const field%05d = () => %05d;   //" % (i, i))' > lib/stand-in.js
    python3 -c 'for i in range(34 * 1024 // 64):
    print("test(\"case %05d\", () => { expect(pad(%05d)).toBe(%05d); });" % (i, i, i))
print("test(\"reads the new field\", () => { expect(field00001()).toBe(1); }); // NEW_FIELD_MARKER")' > tests/stand-in.test.js
    git add lib/stand-in.js tests/stand-in.test.js
    git commit -qm "stand in reads the new field"
  ) >/dev/null 2>&1
}
BLOCK_ONE='{"result":"{\"verdict\":\"block\",\"changes\":[],\"missing\":[\"the stand in reading the new field\"]}"}'
COVERED_ONE='{"result":"{\"covered\":[1]}"}'
COVERED_NONE='{"result":"{\"covered\":[]}"}'
# The heading only a call over the rest of the tests carries, so a rule can answer those calls.
LATER_CALL='CHANGES THE FIRST READER FOUND NO TEST FOR'
RULES="$TMPROOT/judge-rules"
calls_in() { local n=0; while [ -e "$1/call.$((n+1))" ]; do n=$((n+1)); done; echo "$n"; }
ledger_last() { tail -n 1 "$LEDGER" 2>/dev/null | cut -f "$1"; }

# The issue's push: refused before #1998, judged after.
JUDGE_LOG="$TMPROOT/judge-log-1998a"; mkdir -p "$JUDGE_LOG"
printf 'NEW_FIELD_MARKER\t%s\n' "$COVERED_ONE" > "$RULES"
W="$(mk_repo)"; seed_issue_push "$W"
STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$RULES" STUB_CLAUDE_OUT="$BLOCK_ONE" run_hook "$W" "git push"
want_code 0 "#1998 a push whose covering test sits past the cut is judged and allowed"
# The control: the first call really was cut short of the covering test, so the pass above came
# from a later call that was shown it, not from a first call that could see everything.
if [ -f "$JUDGE_LOG/call.1" ] && ! grep -q 'NEW_FIELD_MARKER' "$JUDGE_LOG/call.1"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #1998 the first call held the covering test, so this case never exercised the cut"; fi
n_calls="$(calls_in "$JUDGE_LOG")"
if [ "$n_calls" = 2 ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #1998 the issue's push took $n_calls judge calls, expected 2 (the first and one more for the 34 KB of tests)"; fi
# Every call stays inside the one call budget: 60,000 bytes of diff and the lists around it.
big=0
for f in "$JUDGE_LOG"/call.*; do [ -f "$f" ] && [ "$(wc -c < "$f")" -gt 70000 ] && big=1; done
if [ "$big" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: #1998 a judge call was sent more than 70,000 bytes"; fi
# Every test line was in front of some call: the first case and the last.
if grep -q -h 'case 00000' "$JUDGE_LOG"/call.* && grep -q -h 'NEW_FIELD_MARKER' "$JUDGE_LOG"/call.*; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #1998 some of the test changes reached no judge call"; fi
if [ "$(ledger_last 4)" = pass ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: #1998 the record says $(ledger_last 4), expected pass"; fi
# The record carries what every call was sent, not only the last one.
sent=0; for f in "$JUDGE_LOG"/call.*; do [ -f "$f" ] && sent=$((sent + $(wc -c < "$f"))); done
rec_bytes="$(ledger_last 12)"
if [ -n "$rec_bytes" ] && [ "$rec_bytes" -ge $((sent - 64)) ] 2>/dev/null; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #1998 the record says $rec_bytes bytes were sent, the calls were sent $sent"; fi

# No part of the tests covers the change: an ordinary refusal for a missing test, which the gate
# can now say because every test change was shown, and it says the tests were read in parts.
JUDGE_LOG="$TMPROOT/judge-log-1998b"; mkdir -p "$JUDGE_LOG"
printf '%s\t%s\n' "$LATER_CALL" "$COVERED_NONE" > "$RULES"
W="$(mk_repo)"; seed_issue_push "$W"
STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$RULES" STUB_CLAUDE_OUT="$BLOCK_ONE" run_hook "$W" "git push"
want_code 2 "#1998 a change no part of the tests covers is refused"
want_stderr "have no test covering them" "#1998 and refused as missing a test, every test change having been shown"
want_stderr "in [0-9]+ parts" "#1998 and the refusal says the tests were read in parts"
case "$ERR" in *'could not judge'*) fail=$((fail+1)); echo "FAIL: #1998 a fully read push was refused as could not judge" ;; *) pass=$((pass+1)) ;; esac
if [ "$(ledger_last 4)" = block ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: #1998 the record says $(ledger_last 4), expected block"; fi

# A later call whose answer cannot be read, or that returns nothing: still refused as could not
# judge, never allowed. Before #1998 this push was refused at the first call, so letting it through
# now would loosen the gate (it fails closed here, where the first call fails open).
JUDGE_LOG="$TMPROOT/judge-log-1998c"; mkdir -p "$JUDGE_LOG"
printf '%s\t%s\n' "$LATER_CALL" '{"result":"I could not tell"}' > "$RULES"
W="$(mk_repo)"; seed_issue_push "$W"
STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$RULES" STUB_CLAUDE_OUT="$BLOCK_ONE" run_hook "$W" "git push"
want_code 2 "#1998 a later call with an unreadable answer still refuses"
want_stderr "could not judge" "#1998 as could not judge"
want_stderr "not readable|could not be read" "#1998 naming why the later call failed"
want_stderr "tests/stand-in.test.js" "#1998 and naming the test file not judged"

printf '%s\t\n' "$LATER_CALL" > "$RULES"
W="$(mk_repo)"; seed_issue_push "$W"
STUB_CLAUDE_RULES="$RULES" STUB_CLAUDE_OUT="$BLOCK_ONE" run_hook "$W" "git push"
want_code 2 "#1998 a later call that returns nothing still refuses"
want_stderr "returned nothing" "#1998 naming that the later call returned nothing"
if [ "$(ledger_last 4)" = cantjudge ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: #1998 the record says $(ledger_last 4), expected cantjudge"; fi

# The cost stays bounded: past the gate's cap on readings, what is left is refused as could not
# judge, naming the file, never judged on what was unseen. The cap is 40 parts (#2153), lowered to
# 3 here through the setting that may only lower it, so the case stays the size it was.
JUDGE_LOG="$TMPROOT/judge-log-1998d"; mkdir -p "$JUDGE_LOG"
printf '%s\t%s\n' "$LATER_CALL" "$COVERED_NONE" > "$RULES"
W="$(mk_repo)"; seed_big_tests "$W" 260
REQUIRE_TESTS_MAX_PARTS=3 STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$RULES" STUB_CLAUDE_OUT="$BLOCK_ONE" run_hook "$W" "git push"
want_code 2 "#1998 tests past what the cap of readings can show are refused"
want_stderr "could not judge" "#1998 as could not judge"
want_stderr "tests/register.test.js" "#1998 naming the test file not shown in full"
want_stderr "at most 4 " "#1998 naming the cap it stopped at"
n_calls="$(calls_in "$JUDGE_LOG")"
if [ "$n_calls" = 4 ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #1998 260 KB of tests under a cap of 3 parts took $n_calls judge calls, expected 4"; fi
# The setting can only lower the cap: a value above it, or one that is not a number, leaves 40.
JUDGE_LOG="$TMPROOT/judge-log-2153cap"; mkdir -p "$JUDGE_LOG"
W="$(mk_repo)"; seed_big_tests "$W" 260
REQUIRE_TESTS_MAX_PARTS=9999 STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$RULES" STUB_CLAUDE_OUT="$BLOCK_ONE" run_hook "$W" "git push"
want_code 2 "#2153 260 KB of tests no part covers is refused"
want_stderr "have no test covering them" "#2153 a setting above the cap reads every part, then refuses as missing a test"

# --- claude-config#2153: a large push is read whole, however many parts it needs ----------------
# On 2026-11-03 batch/8's test changes came to 436 KB, needing 16 readings where the gate stopped at
# 4, and it called four tested issues untested. Now the rest of the tests is read in as many parts
# as it takes, up to 40, several at once so they fit the deadline: real judge calls took a median
# of 9 and at most 58 seconds over the 1,836 judged rows in the gate's record on 2026-11-03, so 16
# one after another would not fit the 110 seconds the gate allows itself.
JUDGE_LOG="$TMPROOT/judge-log-2153big"; mkdir -p "$JUDGE_LOG"
MEET="$TMPROOT/meet-2153"; mkdir -p "$MEET"
printf 'WINDING_DOWN_MARKER\t%s\n%s\t%s\n' "$COVERED_ONE" "$LATER_CALL" "$COVERED_NONE" > "$RULES"
W="$(mk_repo)"; seed_big_tests "$W" 400
STUB_CLAUDE_MEET="$MEET" STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$RULES" STUB_CLAUDE_OUT="$BLOCK_ONE" \
  run_hook "$W" "git push"
want_code 0 "#2153 a 400 KB batch whose covering test is in its last part is read whole and allowed"
n_calls="$(calls_in "$JUDGE_LOG")"
if [ "$n_calls" -gt 4 ] 2>/dev/null; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #2153 400 KB of tests took $n_calls judge calls, expected more than the old cap of 4 (each part under 60 KB)"; fi
if grep -q -h 'case 00000' "$JUDGE_LOG"/call.* && grep -q -h 'case 06399' "$JUDGE_LOG"/call.* \
   && grep -q -h 'WINDING_DOWN_MARKER' "$JUDGE_LOG"/call.*; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #2153 some of the 400 KB of test changes reached no judge call"; fi
if [ -f "$JUDGE_LOG/call.1" ] && ! grep -q 'WINDING_DOWN_MARKER' "$JUDGE_LOG/call.1"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #2153 the first call held the covering test, so this case never exercised the later parts"; fi
if [ -e "$MEET/met" ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #2153 no two readings of the rest ran at once, so 16 readings cannot fit the deadline"; fi
big=0
for f in "$JUDGE_LOG"/call.*; do [ -f "$f" ] && [ "$(wc -c < "$f")" -gt 70000 ] && big=1; done
if [ "$big" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: #2153 a judge call was sent more than 70,000 bytes"; fi
if [ "$(ledger_last 4)" = pass ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: #2153 the record says $(ledger_last 4), expected pass"; fi
# The same batch with no part covering the change: every part read, then refused as missing a test.
JUDGE_LOG="$TMPROOT/judge-log-2153none"; mkdir -p "$JUDGE_LOG"
printf '%s\t%s\n' "$LATER_CALL" "$COVERED_NONE" > "$RULES"
W="$(mk_repo)"; seed_big_tests "$W" 400
STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$RULES" STUB_CLAUDE_OUT="$BLOCK_ONE" run_hook "$W" "git push"
want_code 2 "#2153 a 400 KB batch no part covers is still refused"
want_stderr "have no test covering them" "#2153 as missing a test, every part having been read"
# A reading in a wave that fails, with the change in no part that answered: could not judge, never
# allowed, naming the file.
printf '%s\t%s\n' "$LATER_CALL" '{"result":"I could not tell"}' > "$RULES"
W="$(mk_repo)"; seed_big_tests "$W" 400
STUB_CLAUDE_RULES="$RULES" STUB_CLAUDE_OUT="$BLOCK_ONE" run_hook "$W" "git push"
want_code 2 "#2153 readings at once that fail still refuse"
want_stderr "could not judge" "#2153 as could not judge"
want_stderr "tests/register.test.js" "#2153 naming the test file not judged"
# A reading that fails BEFORE it launches leaves its start and end empty. The record of the run must
# not take the reading's byte count for a start time (the fields were once split on a tab, which
# collapses empty ones).
printf '%s\t%s\n' "$LATER_CALL" "$COVERED_NONE" > "$RULES"
W="$(mk_repo)"; seed_big_tests "$W" 400
cp "$STUB_DIR/claude" "$STUB_DIR/claude.keep"
STUB_CLAUDE_VANISH=1 STUB_CLAUDE_RULES="$RULES" STUB_CLAUDE_OUT="$BLOCK_ONE" run_hook "$W" "git push"
cp "$STUB_DIR/claude.keep" "$STUB_DIR/claude"; chmod +x "$STUB_DIR/claude"
want_code 2 "#2153 readings that fail before launch still refuse"
rec_start="$(ledger_last 13)"
case "$rec_start" in
  ''|*[!0-9]*) fail=$((fail+1)); echo "FAIL: #2153 the record's start is '$rec_start', expected epoch seconds" ;;
  *) if [ "$rec_start" -gt 1000000000 ]; then pass=$((pass+1))
     else fail=$((fail+1)); echo "FAIL: #2153 a reading that never launched shifted the record's start to $rec_start (its byte count)"; fi ;;
esac

# --- claude-config#2153: a push is judged against the tests its whole branch adds -----------------
# On 2026-11-03 a work branch pushed its failing database tests first, then the migration and code
# in two later pushes, and the gate refused those as untested: it read only the pushed commits. Now
# the tests the branch changed since it left the default branch (their merge base) count too. The
# source judged is still only what the push carries.
mk_branch_with_earlier_test() {   # $1 = repo  ->  branch feat, its test already on the remote
  (
    cd "$1" || exit 1
    git checkout -qb feat
    mkdir -p tests lib
    printf 'test("adds", () => { expect(add(1,2)).toBe(3); }); // EARLIER_TEST_MARKER\n' > tests/calc.test.js
    git add tests/calc.test.js
    git commit -qm "Add failing calc case"
    git push -qu origin feat
    printf 'export function add(a, b) { return a + b; }\n' > lib/calc.js
    git add lib/calc.js
    git commit -qm "add calc"
  ) >/dev/null 2>&1
}
JUDGE_LOG="$TMPROOT/judge-log-2153branch"; mkdir -p "$JUDGE_LOG"
printf 'EARLIER_TEST_MARKER\t%s\n' '{"result":"{\"verdict\":\"pass\",\"changes\":[],\"missing\":[]}"}' > "$RULES"
W="$(mk_repo)"; mk_branch_with_earlier_test "$W"
STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$RULES" STUB_CLAUDE_OUT="$BLOCK_ONE" run_hook "$W" "git push"
want_code 0 "#2153 a push whose test went up in an earlier push of the branch is judged and allowed"
if grep -q 'EARLIER_TEST_MARKER' "$JUDGE_LOG/call.1" 2>/dev/null && grep -q 'tests/calc.test.js' "$JUDGE_LOG/call.1"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #2153 the judge was not shown the test the branch pushed earlier"; fi
if grep -q 'ALREADY ON THIS BRANCH' "$JUDGE_LOG/call.1" 2>/dev/null; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #2153 the judge was not told which tests were pushed earlier on the branch"; fi
# The source judged is the push's own: the earlier commit's test file is not listed as pushed source.
src_section="$(awk '/^SOURCE FILES CHANGED IN THIS PUSH/,/^FAILURE HANDLING/' "$JUDGE_LOG/call.1" 2>/dev/null)"
case "$src_section" in *'lib/calc.js'*) pass=$((pass+1)) ;;
  *) fail=$((fail+1)); echo "FAIL: #2153 the pushed source was not listed as the push's source" ;; esac

# A code only push on a branch with no test anywhere on it is still refused at the floor, without a
# judge call, even when the default branch had tests before the branch left it: those are not the
# branch's.
JUDGE_LOG="$TMPROOT/judge-log-2153none2"; mkdir -p "$JUDGE_LOG"
W="$(mk_repo)"
(
  cd "$W" || exit 1
  mkdir -p tests lib
  printf 'test("old", () => { expect(1).toBe(1); });\n' > tests/old.test.js
  git add tests/old.test.js; git commit -qm "an old test on main"; git push -q origin HEAD
  git checkout -qb feat
  printf 'export const a = 1;\n' > lib/a.js
  git add lib/a.js; git commit -qm "a"; git push -qu origin feat
  printf 'export const b = 2;\n' > lib/b.js
  git add lib/b.js; git commit -qm "b"
) >/dev/null 2>&1
STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_OUT='{"result":"{\"verdict\":\"pass\",\"changes\":[],\"missing\":[]}"}' run_hook "$W" "git push"
want_code 2 "#2153 a code only push on a branch with no test anywhere is still refused"
want_stderr "adds or modifies no tests" "#2153 at the zero test floor"
if [ "$(calls_in "$JUDGE_LOG")" = 0 ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #2153 a branch with no test reached the judge, so the floor no longer holds"; fi

# The branch's base cannot be worked out (no default branch known for origin): judged as before, on
# the push's own tests alone, so the push is refused, and the refusal says why the branch's earlier
# tests were not counted.
W="$(mk_repo)"; mk_branch_with_earlier_test "$W"
( cd "$W" && git update-ref -d refs/remotes/origin/master && git update-ref -d refs/remotes/origin/main ) >/dev/null 2>&1
STUB_CLAUDE_OUT='{"result":"{\"verdict\":\"pass\",\"changes\":[],\"missing\":[]}"}' run_hook "$W" "git push"
want_code 2 "#2153 with no default branch known the push is judged as before and refused"
want_stderr "adds or modifies no tests" "#2153 at the zero test floor, as before"
want_stderr "earlier on this branch" "#2153 saying the branch's earlier tests could not be counted"

# Tests the branch pushed earlier that cannot all be read are refused as could not judge, never
# allowed, and the refusal says a smaller push does not shrink them, since they are read with every
# push of the branch.
printf '%s\t%s\n' "$LATER_CALL" '{"result":"I could not tell"}' > "$RULES"
W="$(mk_repo)"
(
  cd "$W" || exit 1
  git checkout -qb feat
) >/dev/null 2>&1
seed_big_tests "$W" 120
(
  cd "$W" || exit 1
  git push -qu origin feat
  printf 'export const later = 1;\n' > lib/later.js
  git add lib/later.js; git commit -qm "later code"
) >/dev/null 2>&1
STUB_CLAUDE_RULES="$RULES" STUB_CLAUDE_OUT="$BLOCK_ONE" run_hook "$W" "git push"
want_code 2 "#2153 earlier branch tests too large to read are refused, not allowed"
want_stderr "could not judge" "#2153 as could not judge"
want_stderr "pushed earlier are read with every push" "#2153 saying a smaller push does not shrink the earlier tests"

# Out of time: the hook must finish inside the 120 seconds its registration sets (a setting, not
# measured), so a later call is not started without time for it, and the push is refused saying so.
# Since #2249 the first call keeps to the deadline too, so the deadline here (25) leaves the first
# call its 20 seconds, and the stand in judge taking 6 seconds leaves the later call short of them.
# A machine slow enough to spend 5 seconds reading the push refuses before the first call instead,
# which measures nothing about the later one, so that case is reported unmeasured (L411).
JUDGE_LOG="$TMPROOT/judge-log-1998e"; mkdir -p "$JUDGE_LOG"
printf 'NEW_FIELD_MARKER\t%s\n' "$COVERED_ONE" > "$RULES"
W="$(mk_repo)"; seed_issue_push "$W"
REQUIRE_TESTS_DEADLINE_SECONDS=25 STUB_CLAUDE_SLEEP=6 STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$RULES" STUB_CLAUDE_OUT="$BLOCK_ONE" \
  run_hook "$W" "git push"
n_calls="$(calls_in "$JUDGE_LOG")"
case "$ERR" in *"before its first reading"*) first_refused=1 ;; *) first_refused=0 ;; esac
if [ "$n_calls" = 0 ] && [ "$first_refused" = 1 ]; then
  echo "SUITE-PART-UNMEASURED #1998 later call deadline: reading the push took past 5 s, so the first call was refused instead"
else
  want_code 2 "#1998 no time left for a later call refuses"
  want_stderr "could not judge" "#1998 as could not judge"
  want_stderr "ran out of time" "#1998 saying it ran out of time"
  if [ "$n_calls" = 1 ]; then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: #1998 with no time left the gate made $n_calls calls, expected 1"; fi
fi

# --- claude-config#2021: the deadline setting's two untested edges ----------
# REQUIRE_TESTS_DEADLINE_SECONDS (#2009) can only end the further readings SOONER: it is capped at
# the hook's own 110, and it is read through lib/whole-number.sh, without which the 110 stands. The
# hook times itself with bash's SECONDS, which bash takes from the environment, so a run handed
# SECONDS=95 starts 95 seconds in: under a deadline of 110 that leaves 15, short of the 20 a further
# reading needs, and under anything past 115 it leaves enough. Every number here is one the hook or
# this test sets, not measured. That clock is what both edges are read through, with the judge
# stubbed as above; no real model is called.
#
# The control first: a run started at 0 under a setting of 500 makes the further reading, so a
# refusal below comes from the clock and the cap, not from the large value breaking the reading.
JUDGE_LOG="$TMPROOT/judge-log-2021ctl"; mkdir -p "$JUDGE_LOG"
printf 'NEW_FIELD_MARKER\t%s\n' "$COVERED_ONE" > "$RULES"
W="$(mk_repo)"; seed_issue_push "$W"
REQUIRE_TESTS_DEADLINE_SECONDS=500 STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$RULES" STUB_CLAUDE_OUT="$BLOCK_ONE" \
  run_hook "$W" "git push"
want_code 0 "#2021 the control: a setting of 500 from a start at 0 still makes the further reading and allows"
n_calls="$(calls_in "$JUDGE_LOG")"
if [ "$n_calls" = 2 ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #2021 the control made $n_calls judge calls, expected 2"; fi

# 1. A setting above 110 is held to 110: 95 seconds in, it leaves no time for a further reading
# (a start this test sets, not measured).
JUDGE_LOG="$TMPROOT/judge-log-2021cap"; mkdir -p "$JUDGE_LOG"
W="$(mk_repo)"; seed_issue_push "$W"
SECONDS=95 REQUIRE_TESTS_DEADLINE_SECONDS=500 STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$RULES" STUB_CLAUDE_OUT="$BLOCK_ONE" \
  run_hook "$W" "git push"
want_code 2 "#2021 a setting above 110 is held to 110, so 95 seconds in no reading starts"
want_stderr "ran out of time" "#2021 and the refusal says it ran out of time"
# None at all: 15 seconds is short of the 20 any reading needs, the first one included (#2249);
# both are numbers the hook and this test set, not measured.
n_calls="$(calls_in "$JUDGE_LOG")"
if [ "$n_calls" = 0 ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #2021 a setting of 500 was not held to 110: 95 seconds in the gate made $n_calls judge calls, expected 0"; fi

# 2. Without lib/whole-number.sh the setting cannot be read, and the default 110 stands. A copy of
# the hook and its libraries with that one file taken away, so the real tree is never touched.
NWN="$TMPROOT/no-whole-number"; mkdir -p "$NWN"
cp "$HOOK" "$NWN/require-tests-before-push.sh"
cp -R "$DIR/lib" "$NWN/lib"
rm -f "$NWN/lib/whole-number.sh"
REAL_HOOK="$HOOK"; HOOK="$NWN/require-tests-before-push.sh"
if [ ! -e "$NWN/lib/whole-number.sh" ] && [ -f "$NWN/lib/push-changes.sh" ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #2021 fixture: the copy without lib/whole-number.sh was not made as intended"; fi
# A setting of 1, unread, so the default leaves time for the further reading from a start at 0.
JUDGE_LOG="$TMPROOT/judge-log-2021nw1"; mkdir -p "$JUDGE_LOG"
W="$(mk_repo)"; seed_issue_push "$W"
REQUIRE_TESTS_DEADLINE_SECONDS=1 STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$RULES" STUB_CLAUDE_OUT="$BLOCK_ONE" \
  run_hook "$W" "git push"
want_code 0 "#2021 without lib/whole-number.sh the default deadline stands: a setting of 1 is not read, and the further reading runs"
n_calls="$(calls_in "$JUDGE_LOG")"
if [ "$n_calls" = 2 ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #2021 without lib/whole-number.sh the gate made $n_calls judge calls, expected 2 under the default deadline"; fi
case "$ERR" in *'command not found'*) fail=$((fail+1)); echo "FAIL: #2021 without lib/whole-number.sh the hook printed a shell error: $ERR" ;; *) pass=$((pass+1)) ;; esac
# And the default is 110, not the setting taken raw: 95 seconds in, a setting of 500 still leaves
# no time for a further reading (a start this test sets, not measured).
JUDGE_LOG="$TMPROOT/judge-log-2021nw2"; mkdir -p "$JUDGE_LOG"
W="$(mk_repo)"; seed_issue_push "$W"
SECONDS=95 REQUIRE_TESTS_DEADLINE_SECONDS=500 STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$RULES" STUB_CLAUDE_OUT="$BLOCK_ONE" \
  run_hook "$W" "git push"
want_code 2 "#2021 without lib/whole-number.sh the deadline is the default 110, so 95 seconds in no reading starts"
n_calls="$(calls_in "$JUDGE_LOG")"
if [ "$n_calls" = 0 ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #2021 without lib/whole-number.sh, 95 seconds in, the gate made $n_calls judge calls, expected 0"; fi
HOOK="$REAL_HOOK"

# --- claude-config#2249: the FIRST reading keeps to the deadline too -------
# The further readings were started only with PART_MIN_SECONDS left and timed to end by the deadline
# (#1998), but the first was always given the full JUDGE_TIMEOUT of 90 however late it started. A
# slow scan of a large push before it left the call running past the 120 second hook limit, and
# the hook was killed with no reason given. Every number in this block is one the hook or this
# test sets, not measured. Now the first reading is not started
# with less than PART_MIN_SECONDS left, its timeout is what is left when that is less than 90, and a
# reading cut short by that shortened timeout is refused as could not judge, never let through: a
# killed hook was a refusal already, so no push refused today is allowed by this.
#
# 1. Too late to start: 95 seconds in (a start this test sets) leaves 15, and no reading is made.
JUDGE_LOG="$TMPROOT/judge-log-2249late"; mkdir -p "$JUDGE_LOG"
printf 'NEW_FIELD_MARKER\t%s\n' "$COVERED_ONE" > "$RULES"
W="$(mk_repo)"; seed_issue_push "$W"
SECONDS=95 STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$RULES" STUB_CLAUDE_OUT="$BLOCK_ONE" run_hook "$W" "git push"
want_code 2 "#2249 a first reading with 15 seconds left is refused"
want_stderr "could not judge" "#2249 as could not judge"
want_stderr "ran out of time" "#2249 saying it ran out of time"
n_calls="$(calls_in "$JUDGE_LOG")"
if [ "$n_calls" = 0 ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #2249 with 15 seconds left the gate still made $n_calls judge calls, expected 0"; fi
if [ "$(ledger_last 4)" = cantjudge ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: #2249 the late start is recorded as $(ledger_last 4), expected cantjudge"; fi

# A stand in for `timeout`, first on the PATH, that records the seconds it was handed and answers
# as GNU timeout does when the time runs out (124), without running the judge: what a slow judge
# looks like to the gate, with no real wait.
TSTUB="$TMPROOT/timeout-stub"; mkdir -p "$TSTUB"
cat > "$TSTUB/timeout" <<'TSTUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$STUB_TIMEOUT_ARGS"
cat > /dev/null
exit 124
TSTUB
chmod +x "$TSTUB/timeout"

# 2. Started 60 seconds in, the first reading is given the 50 left, not 90, and when it runs out
# the push is refused as could not judge, never the DID NOT RUN allow. These are numbers this test
# sets, not measured.
TARGS="$TMPROOT/timeout-args-2249short"; : > "$TARGS"
W="$(mk_repo)"; seed_issue_push "$W"
SECONDS=60 STUB_TIMEOUT_ARGS="$TARGS" STUB_CLAUDE_OUT="$BLOCK_ONE" run_hook "$W" "git push" "$TSTUB:$PATH_STUB"
want_code 2 "#2249 a first reading cut short by the deadline is refused"
want_stderr "could not judge" "#2249 a reading cut short is could not judge"
want_stderr "deadline" "#2249 naming the deadline it was cut short by"
case "$OUT$ERR" in *"DID NOT RUN"*) fail=$((fail+1)); echo "FAIL: #2249 a reading cut short by the deadline was let through ungated" ;; *) pass=$((pass+1)) ;; esac
first_t="$(head -n 1 "$TARGS")"
if [ -n "$first_t" ] && [ "$first_t" -ge 45 ] && [ "$first_t" -le 50 ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #2249 started 60 seconds in, the first reading was given a timeout of [$first_t], expected the 50 or so left"; fi
if [ "$(ledger_last 4)" = cantjudge ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: #2249 the reading cut short is recorded as $(ledger_last 4), expected cantjudge"; fi

# 3. The control: started at 0 the first reading keeps its full 90, and a judge that times out
# there is still the DID NOT RUN allow it was, so the change narrows only the late start.
TARGS="$TMPROOT/timeout-args-2249full"; : > "$TARGS"
W="$(mk_repo)"; seed_issue_push "$W"
STUB_TIMEOUT_ARGS="$TARGS" STUB_CLAUDE_OUT="$BLOCK_ONE" run_hook "$W" "git push" "$TSTUB:$PATH_STUB"
want_allowed_notice "#2249 the control: a full length reading that times out is the DID NOT RUN allow, as before"
first_t="$(head -n 1 "$TARGS")"
if [ "$first_t" = 90 ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #2249 started at 0, the first reading was given a timeout of [$first_t], expected the full 90"; fi

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

# claude-config#2247: rewording a line inside a Python docstring is documentation. On 2026-11-04 a
# two line docstring fix in lib/ai-review-run.py needed a one time override. The docstring's opening
# quotes sit more than git's three lines of default context above the changed line, so only a diff
# read with the whole file around it can place the line inside it.
PYDOC_BEFORE='"""Adds numbers.\n\nBoth may be negative.\nNeither may be NaN.\n\nReturns their sum.\n"""\n\n\ndef add(a, b):\n    """Add two numbers.\n\n    Both may be negative.\n    Neither may be NaN.\n\n    Returns their sum.\n    """\n    return a + b\n'
PYDOC_AFTER='"""Adds numbers.\n\nBoth may be negative.\nNeither may be NaN.\n\nReturns the sum of both.\n"""\n\n\ndef add(a, b):\n    """Add two numbers.\n\n    Both may be negative.\n    Neither may be NaN.\n\n    Returns the sum of both.\n    """\n    return a + b\n'
W="$(mk_repo)"
( cd "$W" && mkdir -p lib && printf "$PYDOC_BEFORE" > lib/doc.py && git add lib/doc.py && git commit -qm base && git push -q ) >/dev/null 2>&1
( cd "$W" && printf "$PYDOC_AFTER" > lib/doc.py && git add lib/doc.py && git commit -qm reword ) >/dev/null 2>&1
run_hook "$W" "git push"
want_code 0 "#2247 rewording inside a module and a function docstring is allowed"
# The same edit made by the commit in the command, which reads a different diff.
W="$(mk_repo)"
( cd "$W" && mkdir -p lib && printf "$PYDOC_BEFORE" > lib/doc.py && git add lib/doc.py && git commit -qm base && git push -q ) >/dev/null 2>&1
( cd "$W" && printf "$PYDOC_AFTER" > lib/doc.py ) >/dev/null 2>&1
run_hook "$W" "git add lib/doc.py && git commit -m reword && git push"
want_code 0 "#2247 the same docstring rewording made by the command's own commit is allowed"
# The docstring reworded and the code beside it changed still blocks.
W="$(mk_repo)"
( cd "$W" && mkdir -p lib && printf "$PYDOC_BEFORE" > lib/doc.py && git add lib/doc.py && git commit -qm base && git push -q ) >/dev/null 2>&1
PYDOC_BOTH='"""Adds numbers.\n\nBoth may be negative.\nNeither may be NaN.\n\nReturns the sum of both.\n"""\n\n\ndef add(a, b):\n    """Add two numbers.\n\n    Both may be negative.\n    Neither may be NaN.\n\n    Returns the sum of both.\n    """\n    return a - b\n'
( cd "$W" && printf "$PYDOC_BOTH" > lib/doc.py && git add lib/doc.py && git commit -qm both ) >/dev/null 2>&1
run_hook "$W" "git push"
want_code 2 "#2247 a docstring and a code line changed together still BLOCKS"
# An ordinary triple quoted string is a value, not a docstring, and still blocks.
W="$(mk_repo)"
( cd "$W" && mkdir -p lib && printf 'def f():\n    x = 1\n    return """old\n    words"""\n' > lib/s.py && git add lib/s.py && git commit -qm base && git push -q ) >/dev/null 2>&1
( cd "$W" && printf 'def f():\n    x = 1\n    return """new\n    words"""\n' > lib/s.py && git add lib/s.py && git commit -qm bump ) >/dev/null 2>&1
run_hook "$W" "git push"
want_code 2 "#2247 changing an ordinary triple quoted string still BLOCKS"
# A file Python cannot parse is judged as before, so a docstring edit in it still blocks.
W="$(mk_repo)"
( cd "$W" && mkdir -p lib && printf 'def f(:\n    """Old."""\n' > lib/e.py && git add lib/e.py && git commit -qm base && git push -q ) >/dev/null 2>&1
( cd "$W" && printf 'def f(:\n    """New."""\n' > lib/e.py && git add lib/e.py && git commit -qm bump ) >/dev/null 2>&1
run_hook "$W" "git push"
want_code 2 "#2247 a docstring edit in a file that does not parse still BLOCKS"
# The same triple quoted lines in a Ruby file are judged as before: code.
W="$(mk_repo)"
( cd "$W" && mkdir -p lib && printf 'def f\n  """Old."""\nend\n' > lib/r.rb && git add lib/r.rb && git commit -qm base && git push -q ) >/dev/null 2>&1
( cd "$W" && printf 'def f\n  """New."""\nend\n' > lib/r.rb && git add lib/r.rb && git commit -qm bump ) >/dev/null 2>&1
run_hook "$W" "git push"
want_code 2 "#2247 the same lines in a file that is not Python still BLOCK"

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
want_allowed_notice "no upstream: gate is blind and must say so"
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

# --- the failure path SPECIAL CASE reads the shared predicate (claude-config#1477) -----------------
# The judge is told which files' added CODE handles failure, from lib/failure-handling.sh, so a word
# like "Fail the run" in a test's label is not read as error handling, and a real catch still is.
W="$(mk_repo)"
( cd "$W" && mkdir -p lib tests \
    && printf 'export async function load() {\n  try { return await fetchIt() } catch (e) { report(e); throw e }\n}\n' > lib/load.js \
    && printf 'const options = ["Fail the run", "Skip"];\nexport const pick = (i) => options[i];\n' > lib/options.js \
    && printf 'test("labels", () => { expect(pick(0)).toBe("Fail the run"); stats({ retries_assumed: 2 }); });\n' > tests/options.test.js \
    && git add lib tests && git commit -qm "load and options" ) >/dev/null 2>&1
JUDGE_IN="$TMPROOT/judge-failure-files"; rm -f "$JUDGE_IN"; rm -f "$TMPROOT/judge-failure-args"
STUB_CLAUDE_STDIN="$JUDGE_IN" STUB_CLAUDE_ARGS="$TMPROOT/judge-failure-args" STUB_CLAUDE_OUT="$PASS_JSON" \
  run_hook "$W" "git push"
want_code 0 "a push with a catch and a failure worded label is judged"
fh_line="$(grep -A3 '^FAILURE HANDLING FILES' "$JUDGE_IN" 2>/dev/null)"
case "$fh_line" in
  *lib/load.js*) pass=$((pass+1)) ;;
  *) fail=$((fail+1)); echo "FAIL: the judge was not told lib/load.js handles failure (got: [$fh_line])" ;;
esac
case "$fh_line" in
  *options*) fail=$((fail+1)); echo "FAIL: a label reading 'Fail the run' was listed as failure handling: [$fh_line]" ;;
  *) pass=$((pass+1)) ;;
esac
if grep -q 'FAILURE HANDLING FILES' "$TMPROOT/judge-failure-args" "$JUDGE_IN" 2>/dev/null \
   && grep -q 'never makes a change error handling' "$TMPROOT/judge-failure-args" 2>/dev/null; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: the rubric's failure path SPECIAL CASE does not point the judge at the FAILURE HANDLING FILES list"; fi

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
want_allowed_notice "judge timed out"
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

# A record that cannot be written is said, never swallowed, and never turns a pass into a block.
W="$(mk_repo)"; seed_source_and_test "$W"
printf 'not a directory\n' > "$TMPROOT/ledger-file"
PUSH_GATE_LEDGER_DIR="$TMPROOT/ledger-file" STUB_CLAUDE_OUT="$PASS_JSON" run_hook "$W" "git push"
want_allowed_notice "an unwritable record does not block the push" "allowed this push \(pass\), but its record could not be written"

# --- claude-config#2028: a branch that merges a busy main is judged on its own change ----------------
# On 2026-11-01 four Pivot pull requests (#607, #644, #619, #621) each merged main into their branch
# and were refused, because the gate judged every change main had gained since the branch was last
# pushed: far past the 60,000 byte budget, and full of changes that passed the gate on their own
# branches. Now the push is judged against what merging main into the last pushed tip gives, so only
# the branch's own work is judged, and an edit made inside the merge itself (a conflict resolution,
# or anything else in neither parent) still is.
#
# The setup: lib/shared.js on main, a feature branch changing it with a test and pushed, then main
# gaining a large tested change (BIG_MAIN_MARKER, past the budget on its own) and merged in. $2:
#   own       the branch then adds lib/own.js with tests/own.test.js
#   untested  the branch then adds lib/own.js with no test
#   conflict  main also changed the line the branch changed; resolved to a value in neither parent
#   evil      a clean merge whose commit also adds lib/evil.js, in neither parent
mk_merged_main() {   # $1 = repo  $2 = own | untested | conflict | evil
  local w="$1" kind="$2"
  (
    cd "$w" || exit 1
    main="$(git symbolic-ref --short HEAD)"
    git remote set-head origin "$main"
    mkdir -p lib tests
    printf 'export function shared() { return 0; }\n' > lib/shared.js
    git add lib/shared.js && git commit -qm "shared" && git push -q origin "$main"
    git checkout -qb feature
    printf 'export function shared() { return 1; }\n' > lib/shared.js
    printf 'test("shared", () => { expect(shared()).toBe(1); });\n' > tests/shared.test.js
    git add lib/shared.js tests/shared.test.js && git commit -qm "feature change" && git push -qu origin feature
    git checkout -q "$main"
    mkdir -p lib tests
    python3 -c 'print("// BIG_MAIN_MARKER")
for i in range(80 * 1024 // 48):
    print("export const big%05d = () => %05d; // filler" % (i, i))' > lib/big.js
    printf 'test("big", () => { expect(big00001()).toBe(1); });\n' > tests/big.test.js
    git add lib/big.js tests/big.test.js
    [ "$kind" = conflict ] && printf 'export function shared() { return 2; }\n' > lib/shared.js && git add lib/shared.js
    git commit -qm "MAIN_COMMIT_SUBJECT a large change" && git push -q origin "$main"
    git checkout -q feature
    case "$kind" in
      conflict)
        git merge -q --no-edit "origin/$main"
        printf 'export function shared() { return 4; }\n' > lib/shared.js
        git add lib/shared.js && git commit -q --no-edit ;;
      evil)
        git merge -q --no-edit --no-commit "origin/$main"
        printf 'export const evil = () => 9;\n' > lib/evil.js
        git add lib/evil.js && git commit -q --no-edit ;;
      *)
        git merge -q --no-edit "origin/$main"
        printf 'export function own() { return 5; }\n' > lib/own.js
        git add lib/own.js
        if [ "$kind" = own ]; then
          printf 'test("own", () => { expect(own()).toBe(5); });\n' > tests/own.test.js
          git add tests/own.test.js
        fi
        git commit -qm "own change" ;;
    esac
  ) >/dev/null 2>&1
}
# The stub refuses whatever shows it main's change, and passes anything else, so a pass means the
# judge was shown the branch's change without main's.
MERGE_RULES="$TMPROOT/judge-rules-2028"
printf 'BIG_MAIN_MARKER\t%s\n' '{"result":"{\"verdict\":\"block\",\"changes\":[],\"missing\":[\"main big change\"]}"}' > "$MERGE_RULES"
not_in_call() {   # <file> <text> <label>
  if [ -f "$1" ] && ! grep -q "$2" "$1"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: #2028 $3: the judge was shown $2 (or never called)"; fi
}
in_call() {   # <file> <text> <label>
  if [ -f "$1" ] && grep -q "$2" "$1"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: #2028 $3: the judge was not shown $2"; fi
}
not_in_stderr() {   # <ERE> <label>
  if grep -Eq "$1" <<< "$ERR"; then fail=$((fail+1)); echo "FAIL: #2028 $2: stderr matched /$1/: [$ERR]"; else pass=$((pass+1)); fi
}

# The issue's push: the branch's own tested change, beside a merged main past the budget, passes.
JUDGE_LOG="$TMPROOT/judge-log-2028a"; mkdir -p "$JUDGE_LOG"
W="$(mk_repo)"; mk_merged_main "$W" own
STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$MERGE_RULES" STUB_CLAUDE_OUT="$PASS_JSON" run_hook "$W" "git push"
want_code 0 "#2028 a branch that merged a large main and carries its own tested change passes"
in_call "$JUDGE_LOG/call.1" "lib/own.js" "the branch's own change is judged"
in_call "$JUDGE_LOG/call.1" "tests/own.test.js" "the branch's own test is shown"
not_in_call "$JUDGE_LOG/call.1" "BIG_MAIN_MARKER" "main's merged change is left out of the diff"
not_in_call "$JUDGE_LOG/call.1" "MAIN_COMMIT_SUBJECT" "main's commit subjects are left out of the messages"
if [ "$(calls_in "$JUDGE_LOG")" = 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: #2028 expected one judge call, got $(calls_in "$JUDGE_LOG")"; fi

# The same with its own change untested is refused, naming that change and not main's. The branch
# pushed tests/shared.test.js earlier, so since #2153 that test counts for the push and the judge,
# not the zero test floor, decides: the stub here refuses whatever shows it the named source file,
# as a judge finding the earlier test does not cover it would. The cases check the judge is shown
# the branch's earlier test and not main's change, and that the refusal names the branch's change.
merge_block_rules() {   # $1 = the source file the stub judge finds untested
  printf 'BIG_MAIN_MARKER\t%s\n%s\t%s\n' \
    '{"result":"{\"verdict\":\"block\",\"changes\":[],\"missing\":[\"main big change\"]}"}' \
    "$1" "{\"result\":\"{\\\"verdict\\\":\\\"block\\\",\\\"changes\\\":[],\\\"missing\\\":[\\\"$1 has no test\\\"]}\"}" > "$MERGE_RULES"
}
JUDGE_LOG="$TMPROOT/judge-log-2028b"; mkdir -p "$JUDGE_LOG"
merge_block_rules lib/own.js
W="$(mk_repo)"; mk_merged_main "$W" untested
STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$MERGE_RULES" STUB_CLAUDE_OUT="$PASS_JSON" run_hook "$W" "git push"
want_code 2 "#2028 a branch that merged main with its own untested change is refused"
want_stderr "lib/own\.js" "#2028 the refusal names the branch's change"
not_in_stderr "lib/big\.js" "the refusal does not name main's change"
in_call "$JUDGE_LOG/call.1" "tests/shared.test.js" "the untested push is judged against the test the branch pushed earlier"
not_in_call "$JUDGE_LOG/call.1" "BIG_MAIN_MARKER" "the untested push is judged without main's change"

# A conflict resolution is a change in the merge result in neither parent: it is still judged.
JUDGE_LOG="$TMPROOT/judge-log-2028c"; mkdir -p "$JUDGE_LOG"
merge_block_rules lib/shared.js
W="$(mk_repo)"; mk_merged_main "$W" conflict
STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$MERGE_RULES" STUB_CLAUDE_OUT="$PASS_JSON" run_hook "$W" "git push"
want_code 2 "#2028 an untested conflict resolution is refused"
want_stderr "lib/shared\.js" "#2028 the refusal names the resolved file"
not_in_stderr "lib/big\.js" "the conflict refusal does not name main's change"
not_in_call "$JUDGE_LOG/call.1" "BIG_MAIN_MARKER" "the conflict resolution is judged without main's change"

# So is an edit slipped into a clean merge's commit.
merge_block_rules lib/evil.js
W="$(mk_repo)"; mk_merged_main "$W" evil
STUB_CLAUDE_RULES="$MERGE_RULES" STUB_CLAUDE_OUT="$PASS_JSON" run_hook "$W" "git push"
want_code 2 "#2028 an untested edit made inside a merge commit is refused"
want_stderr "lib/evil\.js" "#2028 the refusal names the edit made in the merge"
not_in_stderr "lib/big\.js" "the merge edit refusal does not name main's change"
# Restored for the cases below, which expect the stub to refuse only main's change.
printf 'BIG_MAIN_MARKER\t%s\n' '{"result":"{\"verdict\":\"block\",\"changes\":[],\"missing\":[\"main big change\"]}"}' > "$MERGE_RULES"

# No default branch known: the gate cannot tell main's commits from the branch's, so it judges
# everything, as before #2028, never nothing, and says main's changes could not be set apart.
JUDGE_LOG="$TMPROOT/judge-log-2028e"; mkdir -p "$JUDGE_LOG"
W="$(mk_repo)"; mk_merged_main "$W" own
( cd "$W" && git remote set-head origin -d; git update-ref -d refs/remotes/origin/main; git update-ref -d refs/remotes/origin/master ) >/dev/null 2>&1
# The control: the upstream is still there, so this case reaches the merge question at all.
if git -C "$W" rev-parse --verify --quiet '@{u}' >/dev/null && ! git -C "$W" rev-parse --verify --quiet refs/remotes/origin/master >/dev/null && ! git -C "$W" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #2028 the no default branch case lost its upstream or kept a default branch"; fi
STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$MERGE_RULES" STUB_CLAUDE_OUT="$PASS_JSON" run_hook "$W" "git push"
want_code 2 "#2028 with no default branch known, the whole push is judged"
in_call "$JUDGE_LOG/call.1" "BIG_MAIN_MARKER" "with no default branch known, main's change is judged too"
want_stderr "could not set apart" "#2028 the refusal says the merged changes could not be set apart"

# The merge cannot be worked out (git merge-tree fails): the same, everything is judged and said so.
GIT_REAL="$(command -v git)"
FAKE_GIT_DIR="$TMPROOT/fake-git-2028"; mkdir -p "$FAKE_GIT_DIR"
printf '#!/usr/bin/env bash\n[ "${1:-}" = merge-tree ] && exit 128\nexec "%s" "$@"\n' "$GIT_REAL" > "$FAKE_GIT_DIR/git"; chmod +x "$FAKE_GIT_DIR/git"
JUDGE_LOG="$TMPROOT/judge-log-2028f"; mkdir -p "$JUDGE_LOG"
W="$(mk_repo)"; mk_merged_main "$W" own
STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_RULES="$MERGE_RULES" STUB_CLAUDE_OUT="$PASS_JSON" run_hook "$W" "git push" "$FAKE_GIT_DIR:$PATH_STUB"
want_code 2 "#2028 when the merge cannot be worked out, the whole push is judged"
in_call "$JUDGE_LOG/call.1" "BIG_MAIN_MARKER" "when the merge cannot be worked out, main's change is judged too"
want_stderr "could not set apart" "#2028 the refusal says why main's changes were judged"

# --- claude-config#2258: a mod's byte identical copy of a mod-kit helper is tested by mod-kit ------
# Every mod keeps copies of mod-kit's helpers at payload/mods/<mod>/hooks/mod-kit/, and the gate
# refused a new mod for them alone (slack-alert-guard, 2026-11-04, for hold.ts and skew.ts). A copy
# whose bytes and mode match payload/mods/mod-kit/hooks/<same name> in the tree the push delivers,
# and which a test under payload/mods/mod-kit/tests/ in that tree imports, is counted as tested.
# Anything short of that is judged as before, and each narrowing is seen to refuse here.
mk_modkit_repo() {   # -> a repo whose remote holds mod-kit's hold.ts and its test, and deliver.ts untested
  local w; w="$(mk_repo)"
  (
    cd "$w" || exit 1
    mkdir -p payload/mods/mod-kit/hooks payload/mods/mod-kit/tests
    printf 'export const HOLD = 1\n' > payload/mods/mod-kit/hooks/hold.ts
    printf 'export const DELIVER = 1\n' > payload/mods/mod-kit/hooks/deliver.ts
    printf "import { HOLD } from '../hooks/hold.ts'\ntest('hold', () => expect(HOLD).toBe(1))\n" > payload/mods/mod-kit/tests/hold.test.ts
    git add payload
    git commit -qm "mod-kit"
    git push -q
  ) >/dev/null 2>&1
  printf '%s' "$w"
}
# put_copy <repo> <helper> <content> [commit message]: writes the new mod's copy, committed when a
# message is given.
put_copy() {
  (
    cd "$1" || exit 1
    mkdir -p payload/mods/newmod/hooks/mod-kit
    printf '%b' "$3" > "payload/mods/newmod/hooks/mod-kit/$2"
    if [ -n "${4:-}" ]; then git add "payload/mods/newmod/hooks/mod-kit/$2"; git commit -qm "$4"; fi
  ) >/dev/null 2>&1
}
call_has() {   # <file> <text> <label>
  if [ -f "$1" ] && grep -qF -- "$2" "$1"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: #2258 $3: the judge was not shown $2"; fi
}
call_lacks() {   # <file> <text> <label>
  if [ -f "$1" ] && ! grep -qF -- "$2" "$1"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: #2258 $3: the judge was shown $2 (or never called)"; fi
}
COPY=payload/mods/newmod/hooks/mod-kit

# The issue's push: a new mod carrying only an identical copy goes through, with no judge called,
# and the record names the copy it counted.
JUDGE_LOG="$TMPROOT/judge-log-2258a"; mkdir -p "$JUDGE_LOG"
W="$(mk_modkit_repo)"; put_copy "$W" hold.ts 'export const HOLD = 1\n' "new mod"
# The control: the copy really is in the commit, so the allow below is not an empty push.
if git -C "$W" cat-file -e "HEAD:$COPY/hold.ts" 2>/dev/null; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #2258 the fixture committed no copy"; fi
STUB_CLAUDE_LOG="$JUDGE_LOG" HK_ID=t-2258a run_hook "$W" "git push"
want_code 0 "#2258 a new mod whose mod-kit copy is byte identical goes through"
want_row t-2258a nosource "#2258 the identical copy is recorded" "$COPY/hold.ts"
if [ "$(calls_in "$JUDGE_LOG")" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: #2258 a push of identical copies alone called the judge"; fi

# One byte different: refused as untested, naming the copy, exactly as before.
W="$(mk_modkit_repo)"; put_copy "$W" hold.ts 'export const HOLD = 2\n' "new mod"
run_hook "$W" "git push"
want_code 2 "#2258 a copy differing by one byte is still refused"
want_stderr "$COPY/hold.ts" "#2258 the refusal names the differing copy"

# Identical, but no mod-kit test imports that helper: refused.
W="$(mk_modkit_repo)"; put_copy "$W" deliver.ts 'export const DELIVER = 1\n' "new mod"
run_hook "$W" "git push"
want_code 2 "#2258 an identical copy of a helper no mod-kit test imports is still refused"

# Identical, but the same push deletes mod-kit's test: the tree the push delivers has none, so refused.
W="$(mk_modkit_repo)"; put_copy "$W" hold.ts 'export const HOLD = 1\n'
( cd "$W" && git rm -q payload/mods/mod-kit/tests/hold.test.ts && git add "$COPY/hold.ts" && git commit -qm "copy, drop test" ) >/dev/null 2>&1
run_hook "$W" "git push"
want_code 2 "#2258 an identical copy is refused when the push removes mod-kit's test of it"

# Identical bytes under another mode (made executable): refused, since it is not the same file.
W="$(mk_modkit_repo)"; put_copy "$W" hold.ts 'export const HOLD = 1\n'
( cd "$W" && chmod +x "$COPY/hold.ts" && git add "$COPY/hold.ts" && git commit -qm "new mod" ) >/dev/null 2>&1
run_hook "$W" "git push"
want_code 2 "#2258 an identical copy under a different mode is still refused"

# A mod-kit test importing the helper without its extension, in double quotes, counts the same.
W="$(mk_modkit_repo)"
( cd "$W" && printf 'export const BARE = 1\n' > payload/mods/mod-kit/hooks/bare.ts \
  && printf 'import { BARE } from "../hooks/bare"\n' > payload/mods/mod-kit/tests/bare.test.ts \
  && git add payload/mods/mod-kit && git commit -qm "bare helper" && git push -q ) >/dev/null 2>&1
put_copy "$W" bare.ts 'export const BARE = 1\n' "new mod"
run_hook "$W" "git push"
want_code 0 "#2258 an identical copy of a helper imported without its extension goes through"

# A symbolic link in mod-kit's hooks is not a helper file, even when the copy is the same link.
W="$(mk_modkit_repo)"
( cd "$W" && ln -s hold.ts payload/mods/mod-kit/hooks/alias.ts \
  && printf "import { HOLD } from '../hooks/alias.ts'\n" > payload/mods/mod-kit/tests/alias.test.ts \
  && git add payload/mods/mod-kit && git commit -qm "alias" && git push -q \
  && mkdir -p "$COPY" && ln -s hold.ts "$COPY/alias.ts" && git add "$COPY/alias.ts" && git commit -qm "new mod" ) >/dev/null 2>&1
if [ "$(git -C "$W" ls-tree HEAD -- "$COPY/alias.ts" | cut -c1-6)" = 120000 ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: #2258 the fixture committed no link copy"; fi
run_hook "$W" "git push"
want_code 2 "#2258 a copy of a symbolic link in mod-kit's hooks is still refused"

# mod-kit's own hooks/mod-kit folder is not a copy of anything.
W="$(mk_modkit_repo)"
( cd "$W" && mkdir -p payload/mods/mod-kit/hooks/mod-kit && printf 'export const HOLD = 1\n' > payload/mods/mod-kit/hooks/mod-kit/hold.ts \
  && git add payload/mods/mod-kit/hooks/mod-kit/hold.ts && git commit -qm "self copy" ) >/dev/null 2>&1
run_hook "$W" "git push"
want_code 2 "#2258 a file under mod-kit's own hooks/mod-kit is not counted as a copy"

# Compared in the tree the push DELIVERS: the committed copy differs, and the command's own commit
# makes it identical, so it goes through; and the other way round it is refused.
W="$(mk_modkit_repo)"; put_copy "$W" hold.ts 'export const HOLD = 2\n' "wrong copy"
put_copy "$W" hold.ts 'export const HOLD = 1\n'
run_hook "$W" "git add $COPY/hold.ts && git commit -qm fix && git push"
want_code 0 "#2258 a copy the command's commit makes identical goes through"
W="$(mk_modkit_repo)"; put_copy "$W" hold.ts 'export const HOLD = 1\n' "right copy"
put_copy "$W" hold.ts 'export const HOLD = 3\n'
run_hook "$W" "git add $COPY/hold.ts && git commit -qm drift && git push"
want_code 2 "#2258 a copy the command's commit makes differ is refused"
want_stderr "$COPY/hold.ts" "#2258 the refusal names the copy the commit made differ"

# Beside the mod's own code and test: the judge is still called, on the mod's own change, and is
# never shown the counted copy among the source files or in the diff.
JUDGE_LOG="$TMPROOT/judge-log-2258b"; mkdir -p "$JUDGE_LOG"
W="$(mk_modkit_repo)"; put_copy "$W" hold.ts 'export const HOLD = 1\n'
( cd "$W" && mkdir -p payload/mods/newmod/tests \
  && printf 'export const OWN_MOD_MARKER = 1\n' > payload/mods/newmod/hooks/index.ts \
  && printf "import { OWN_MOD_MARKER } from '../hooks/index.ts'\n" > payload/mods/newmod/tests/index.test.ts \
  && git add payload/mods/newmod && git commit -qm "new mod with code" ) >/dev/null 2>&1
STUB_CLAUDE_LOG="$JUDGE_LOG" STUB_CLAUDE_OUT="$PASS_JSON" run_hook "$W" "git push"
want_code 0 "#2258 a mod with its own tested code and an identical copy passes"
call_has "$JUDGE_LOG/call.1" "payload/mods/newmod/hooks/index.ts" "the mod's own code is judged"
call_lacks "$JUDGE_LOG/call.1" "$COPY/hold.ts" "the counted copy is left out of what the judge reads"

# claude-config#2337: when the gate cannot read the tree or git fails part way, an otherwise
# identical, tested copy counts as nothing and is judged as untested source (refused, as before
# #2258). A stub git on the path fails one call at a time: STUB_GIT_FAIL names which. The control
# case runs the same stub with nothing to fail and must still let the copy through, so each refusal
# below is the failure's doing and not the stub's.
FAKE_GIT_2337="$TMPROOT/fake-git-2337"; mkdir -p "$FAKE_GIT_2337"
cat > "$FAKE_GIT_2337/git" <<STUB
#!/usr/bin/env bash
case "\${STUB_GIT_FAIL:-}" in
  tree) [ "\${1:-}" = rev-parse ] && [[ "\$*" == *'HEAD^{tree}'* ]] && exit 128 ;;
  copy) [ "\${1:-}" = ls-tree ] && [[ "\$*" == *newmod* ]] && exit 128 ;;
  src)  [ "\${1:-}" = ls-tree ] && [[ "\$*" == *mod-kit/hooks/hold.ts* ]] && [[ "\$*" != *newmod* ]] && exit 128 ;;
  grep) [ "\${1:-}" = grep ] && exit 128 ;;
  emptytree) [ "\${1:-}" = rev-parse ] && [[ "\$*" == *'HEAD^{tree}'* ]] && exit 0 ;;
esac
exec "$GIT_REAL" "\$@"
STUB
chmod +x "$FAKE_GIT_2337/git"
for mode in none tree copy src grep emptytree; do
  W="$(mk_modkit_repo)"; put_copy "$W" hold.ts 'export const HOLD = 1\n' "new mod"
  STUB_GIT_FAIL="$mode" run_hook "$W" "git push" "$FAKE_GIT_2337:$PATH_STUB"
  if [ "$mode" = none ]; then
    want_code 0 "#2337 control: the same stub with nothing failing still counts the identical copy"
  else
    want_code 2 "#2337 an identical copy counts as nothing when git fails at: $mode"
    want_stderr "$COPY/hold.ts" "#2337 the copy is judged as untested source when git fails at: $mode"
  fi
done

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
