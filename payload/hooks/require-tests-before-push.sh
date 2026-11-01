#!/usr/bin/env bash
#
# require-tests-before-push.sh
# Claude Code PreToolUse(Bash) hook.
#
# Goal: every `git push` must carry a test for each DISTINCT logical change in
# it. Not one-test-per-file and not one-test-per-push: a single sweeping change
# across many files (e.g. deleting em dashes from 10 files, a figure invented for the example
# and not measured) needs one test, but
# two unrelated bug fixes need two. That judgment is semantic, so when tests are
# present this hook asks a model (sonnet, via the local `claude` CLI) to grade
# whether each distinct change is covered, and blocks if any is not.
#
# Pipeline (cheap to expensive):
#   1. Not a `git push`, or SKIP_TEST_CHECK=1 override .......... allow
#   2. No source files changed in the pushed commits ........... allow
#   3. Source changed but push contains ZERO tests ............. BLOCK (no model)
#   4. Source + some tests -> model grades per-change coverage . allow / BLOCK
#      Test changes too large for one call are read in further calls, at most 1 + TEST_PARTS_MAX
#      in all, so no refusal rests on a test the model was not shown (#1998, step 6 below).
#
# Override: SKIP_TEST_CHECK=1 git push ...   (docs/config/copy-only, or a
# refactor already covered by existing tests; state why).
#
# Fails OPEN, but never quietly: any parse/git/model error allows the push (the
# floor in step 3 still guarantees at least one test accompanies source changes)
# AND says why, via fail_open() below. Blocking on infrastructure trouble is
# worse than allowing, but a push that was never gated must not look identical
# to a push the gate approved. (#735)
# One exception: a further call reading tests past the first call's cut refuses, as could not
# judge, when it fails. The first call has already called a change untested by then, and before
# #1998 that alone refused the push, so failing open there would loosen the gate.
#
# Every push it reaches is recorded, override included, in the ledger the simplify gate writes too
# (claude-config#1075, #1077): lib/push-gate-report.py reads it.

JUDGE_MODEL="sonnet"
JUDGE_TIMEOUT=90       # seconds for the model call
DIFF_BUDGET=60000      # max bytes of diff sent to the model in one call
# Test changes past the first call's cut go to further calls (claude-config#1998), each within
# DIFF_BUDGET. At most this many, so a push's judge cost is bounded at 1 + TEST_PARTS_MAX calls.
TEST_PARTS_MAX=3
PART_OVERLAP=4096      # bytes of a file repeated at the start of the next part, so a test cut in two is whole in one
# The hook's own finish line, inside the 120 seconds its registration in settings.hooks.json sets
# (a setting, not measured; these two are settings too): a further call is
# started only with PART_MIN_SECONDS left, and its timeout never runs past this. A hook killed at
# its timeout refuses with no reason ("onFailure": "block"), so the gate stops first and says why.
# REQUIRE_TESTS_DEADLINE_SECONDS sets another, for the suite; it can only end the readings sooner.
TESTS_DEADLINE=110
PART_MIN_SECONDS=20

# The notice library, loaded first because every allow below speaks through it.
TG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/hook-notice.sh
. "$TG_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }

# Allow the push, but surface WHY the gate did not run.
#
# The channel is load-bearing. Claude Code discards a PreToolUse hook's stderr
# entirely on exit 0, so a notice printed only there would vanish and this whole
# function would be theatre. #735 said it with exit 1, the non-blocking error
# whose first stderr line the transcript shows; but "onFailure": "block" (#1899)
# refuses the call on exit 1, which would turn "allowed ungated" into a refusal
# saying the push was allowed. So it is exit 0 with the notice as a JSON
# systemMessage, which the person is shown (lib/hook-notice.sh, #1912). One line,
# reason first, as before.
#
# Reserve this for paths where the gate wanted to decide and could not. The
# ordinary silent allows (not a push, SKIP_TEST_CHECK, no source touched,
# docs-only) are correct verdicts, not failures: making them talk would train
# everyone to tune the notice out. Recorded first once the command is known to be a push.
fail_open() {   # $1 = why  $2 = judged, when a judge was called
  if [ "${PC_PUSH:-0}" = 1 ]; then pc_record failopen "$1" "${2:-}" || :; fi
  hook_allow_notice "TEST GATE DID NOT RUN ($1). Push allowed ungated."
}

# A silent allow, recorded. A record that could not be written is said in one line (a systemMessage,
# the push still runs), never swallowed and never turned into a refusal.
allow() {   # $1 = outcome  $2 = detail  $3 = judged
  pc_record "$1" "${2:-}" "${3:-}" && exit 0
  hook_allow_notice "TEST GATE allowed this push ($1), but its record could not be written to $(pc_ledger_path)."
}

# A refusal, recorded, its message on stdin. A record that could not be written is added to the
# message rather than lost.
refuse() {   # $1 = outcome  $2 = detail  $3 = judged
  cat >&2
  pc_record "$1" "${2:-}" "${3:-}" || echo "(This refusal could not be written to the gate's record, $(pc_ledger_path).)" >&2
  exit 2
}

# Push detection, the inline-override check and the chain/base questions are
# shared with the other push hooks, so they live in one library rather than a
# copy per hook. Deliberately NOT shared: what an empty range means. This gate
# treats it as blindness and says so (see step 3); an advisory hook cannot.
HOOK_DIR="$TG_DIR"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || fail_open "shared push-scope library missing"
# is_test / is_source: the file classifier, shared with simplify-before-push.sh so the two gates
# cannot drift over what counts as source (L263). It moved to the lib verbatim from here.
# shellcheck source=lib/source-class.sh
. "$HOOK_DIR/lib/source-class.sh" 2>/dev/null || fail_open "shared source-class library missing"
# What the push carries, the judge call and the record, shared with simplify-before-push.sh
# (claude-config#1076): the two gates each kept a copy, and the copies had drifted.
# shellcheck source=lib/push-changes.sh
. "$HOOK_DIR/lib/push-changes.sh" 2>/dev/null || fail_open "shared push-changes library missing"
PC_GATE=tests
# Whether a file's added code handles failure: the one predicate the lessons advisory and the
# lessons review read too (claude-config#1477). It tells the judge's failure path SPECIAL CASE which
# files it applies to, so a label reading "Fail the run" is not error handling.
# shellcheck source=lib/failure-handling.sh
. "$HOOK_DIR/lib/failure-handling.sh" 2>/dev/null || fail_open "shared failure-handling library missing"
# The one reader of a number above zero (claude-config#1948), for the deadline setting only. Missing,
# whole_above_zero is not found, which reads as a value that failed, so the default deadline stands.
# shellcheck source=lib/whole-number.sh
. "$HOOK_DIR/lib/whole-number.sh" 2>/dev/null || true
whole_above_zero "${REQUIRE_TESTS_DEADLINE_SECONDS:-}" TESTS_DEADLINE 2>/dev/null || :
[ "$TESTS_DEADLINE" -le 110 ] 2>/dev/null || TESTS_DEADLINE=110

# ---------------------------------------------------------------------------
# 1. Parse the hook payload (JSON on stdin) -> command + cwd.
# ---------------------------------------------------------------------------
payload="$(ps_read_payload)"


parsed="$(ps_parse_payload "$payload" segmented)" || fail_open "hook payload did not parse"
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
# An empty command is a malformed payload too: a real Bash tool call always has
# one. A payload that parsed as JSON but carried no command means the gate saw
# nothing to inspect, which is not the same as approving the push.
[ -n "$cmd" ] || fail_open "hook payload carried no command"
PC_CALL_ID="$(pc_call_id "$payload")"

# ---------------------------------------------------------------------------
# 2. Act only on a `git push`, in the repository it runs in; honor the override.
# ---------------------------------------------------------------------------
ps_is_git_push "$cmd" || exit 0
# Only a push is recorded: a payload that did not parse, or any other command, is not one.
PC_PUSH=1

# The repo is resolved from the COMMAND first and the payload cwd second. The
# cwd is the SESSION's directory, so a session rooted outside the project reaches
# it as `cd <repo> && git push`, and reading the cwd alone let every one of those
# pushes past the gate while looking exactly like a push it had approved.
# Exit 2 here is ps_repo_dir refusing: the command pushes from more than one repository, or names a
# directory it could not resolve. Standing down on it says nothing to the session (stderr is shown
# only on a nonzero exit), and that is deliberate: push-scope-notice.sh refuses the same push, once,
# for every gate, with the reason and the remedy, so a second message here would only repeat it.
# test-push-scope-notice.sh drives this gate beside that hook and fails if the two stop agreeing
# (claude-config#1122).
repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || exit 0
[ -n "$repo_dir" ] || exit 0
cd "$repo_dir" 2>/dev/null || exit 0

# ---------------------------------------------------------------------------
# 3. The files the push carries: the committed range plus, when the command commits before it
# pushes, what that commit will take (lib/push-changes.sh, from lib/push-scope.sh's contract).
# ---------------------------------------------------------------------------
# An empty file list has two very different causes, and only one is benign.
#
# With an upstream, empty means the gate compared against the real remote tip
# and this push genuinely adds nothing. Correct verdict, stay quiet.
#
# Without one, the base fell back through origin/HEAD, origin/main, origin/master,
# main, master. On an unpushed branch that can land on the CURRENT branch, so
# merge-base is HEAD, the diff is empty, and the hook sees nothing to gate while
# real commits are about to ship. That is the trap that fake-greened the #733
# scratch scripts. "I saw nothing" is not "there is nothing to see". (#736)
#
# The pending files are folded in before that decision: a no-upstream
# `add && commit && push` chain still has visible staged work, so the gate is
# not blind there and must judge it rather than cry blindness.
pc_resolve "$cmd"
resolved=$?
# An override is recorded with the tree it lets through, read after the resolve because a command
# that commits first delivers a tree no commit holds yet, so it can be matched to a refusal of it.
ps_has_override "$cmd" SKIP_TEST_CHECK && allow override
case $resolved in
  1) allow empty ;;
  2) fail_open "no upstream branch: cannot tell what this push adds" ;;
esac

# When the add could not be read, every change in the working tree was counted, and a refusal has
# to say its file list came from that wider reading rather than from what the commit will carry.
widened_note() {
  [ "$PC_WIDENED" -eq 1 ] || return 0
  echo "Note: the git add in this command could not be read, so every change in the"
  echo "working tree was counted as part of the commit it is about to make."
  echo ""
}

# ---------------------------------------------------------------------------
# 4. Classify: did the push change source? did it touch any test?
# is_test / is_source now live in lib/source-class.sh, sourced above, so this gate and
# simplify-before-push.sh share one classifier (L263). test-source-class.sh owns their cases.
# ---------------------------------------------------------------------------

# Comment style for a source file, by extension. Hash-comment languages use
# '#'; everything else in is_source() is a slash/star family (//, /*, *).
docs_style_for() {
  case "$1" in
    *.py|*.rb|*.ex|*.exs) echo hash ;;
    *) echo slash ;;
  esac
}

# Read a git diff on stdin, return 0 (docs-only) iff every ADDED/REMOVED content
# line is blank or a comment for the given style. Conservative: a line it cannot
# confidently call a comment counts as CODE, so the push still blocks (author can
# override). That is why '#' is a comment ONLY for hash-style files -- in JS/TS
# '#foo' is a private field, i.e. real code, and a bare '*ptr' in C is a deref.
#
# A '*'-leading line is a block comment continuation only when its own file has a
# '/*' open above it and no '*/' between (claude-config#1238). Leading-operator code
# ("const a = b" / "  * 2;") starts with '*' too, so a real behavior change (2 to 3)
# must not pass as documentation. Deciding that from the diff alone meant trusting
# '*' lines only when the diff itself opened a '/*', which blocked every wording
# fix inside a comment that already existed. So the gate reads each source file's
# diff with the whole file around it (DOCS_ONLY_CONTEXT below), and this tracks
# whether each line sits inside a block comment, separately for the old image
# (context and removed lines) and the new one (context and added lines). Where the
# lines above were not shown (a hunk not starting at line 1, a gap between hunks,
# a bare @@), that state is unknown and a '*' line is code, as before. A line with
# code beside a comment ('/* a */ y = 2;') is code. A string is skipped whole, so
# a "/*" inside one opens nothing.
#
# Zero changed content lines (a permission/mode change such as chmod +x, or a pure
# rename) means we can SEE no documentation change. "I saw nothing" is not "there
# is nothing to see": treating it as docs-only let a chmod on a source file pass
# untested, which the pre-#733 gate blocked. That fails CLOSED: the zero-test floor
# below is the hard floor and must not be softened by a diff we could not read.
diff_docs_only() {
  LC_ALL=C awk -v style="$1" '
    function reset() { ost = "unknown"; nst = "unknown"; on = -1; nn = -1 }
    # One line read in state st (out, in, unknown): sets CODE when anything on it
    # sits outside a comment, and returns the state after it.
    function lex(s, st,    i, j, n, c, two, q) {
      CODE = 0; i = 1; n = length(s)
      while (i <= n) {
        if (st == "in") {
          j = index(substr(s, i), "*/")
          if (!j) return "in"
          i += j + 1; st = "out"; continue
        }
        c = substr(s, i, 1); two = substr(s, i, 2)
        if (c == " " || c == "\t" || c == "\r") { i++; continue }
        if (two == "//") return st
        if (two == "/*") { st = "in"; i += 2; continue }
        if (st == "unknown" && two == "*/") { st = "out"; i += 2; continue }
        CODE = 1
        if (c == "\"" || c == "'\''" || c == "`") {
          q = c; i++
          while (i <= n && substr(s, i, 1) != q) { if (substr(s, i, 1) == "\\") i++; i++ }
        }
        i++
      }
      return st
    }
    function hash_code(s) { gsub(/^[ \t]+|[ \t\r]+$/, "", s); return s != "" && s !~ /^#/ }
    BEGIN { reset(); changed = 0; bad = 0 }
    /^diff --git / { reset(); next }
    /^(\+\+\+|---)([ \t]|$)/ { next }
    /^@@/ {
      # Where each image resumes. Contiguous with what was read, the state carries
      # on; starting at line 1 it is out; anywhere else it is unknown.
      if (match($0, /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+/)) {
        split(substr($0, 5, RLENGTH - 4), p, " ")
        a = p[1]; sub(/,.*/, "", a); c = substr(p[2], 2); a += 0; c += 0
        if (a == 0) a = 1
        if (c == 0) c = 1
        if (on == -1 && a == 1) ost = "out"; else if (on != a) ost = "unknown"
        if (nn == -1 && c == 1) nst = "out"; else if (nn != c) nst = "unknown"
        on = a; nn = c
      } else { ost = "unknown"; nst = "unknown"; on = -2; nn = -2 }
      next
    }
    /^\+/ {
      changed++; s = substr($0, 2)
      if (style == "hash") { if (hash_code(s)) bad = 1 }
      else { nst = lex(s, nst); if (CODE) bad = 1 }
      if (nn > 0) nn++
      next
    }
    /^-/ {
      changed++; s = substr($0, 2)
      if (style == "hash") { if (hash_code(s)) bad = 1 }
      else { ost = lex(s, ost); if (CODE) bad = 1 }
      if (on > 0) on++
      next
    }
    /^ / || /^$/ {
      s = substr($0, 2)
      if (style != "hash") { nst = lex(s, nst); ost = lex(s, ost) }
      if (on > 0) on++
      if (nn > 0) nn++
      next
    }
    END { exit (changed == 0 || bad) ? 1 : 0 }
  '
}

# Lines of context the docs-only check reads around each change: the whole file, so a
# '*' line can be placed inside or outside the block comment it sits in.
DOCS_ONLY_CONTEXT=1000000

source_changed=0
test_changed=0
source_list=""
source_paths=""
test_list=""
TEST_PATHSPEC=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  # A test file counts the same whether it is brand-new or an existing file with
  # added/changed cases (PC_FILES holds added, copied, modified and renamed files, so M is included).
  if is_test "$f"; then
    test_changed=1
    test_list="${test_list}  - ${f}"$'\n'
    TEST_PATHSPEC+=("$f")
    continue
  fi
  if is_source "$f"; then
    source_changed=1
    source_list="${source_list}  - ${f}"$'\n'
    source_paths="${source_paths}${f}"$'\n'
  fi
done <<EOF
$PC_FILES
EOF

# No source touched -> nothing to gate.
[ "$source_changed" -eq 1 ] || allow nosource

# Source touched but not a single test in the push -> block without a model.
if [ "$test_changed" -eq 0 ]; then
  # Documentation-only change: if EVERY changed line in EVERY source file that
  # tripped the gate is blank or a comment, there is no behavior to test -> pass.
  # Mirrors the model rubric's needsTest=false for comments; this path exists
  # because the zero-test floor below never reaches the model. (#733)
  docs_only=1; examined=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    examined=$((examined+1))
    style="$(docs_style_for "$f")"
    if ! PC_DIFF_CONTEXT="$DOCS_ONLY_CONTEXT" pc_diff "$f" | diff_docs_only "$style"; then
      docs_only=0; break
    fi
  done <<DOCS_ONLY_EOF
$source_paths
DOCS_ONLY_EOF
  [ "$examined" -ge 1 ] && [ "$docs_only" -eq 1 ] && allow docsonly

  refuse untested "$(printf '%s' "$source_list" | sed 's/^  - //' | paste -sd ',' -)" <<REFUSAL
PUSH BLOCKED: this push changes source code but adds or modifies no tests.

Source files in this push:
${source_list}
Add a test for each distinct change, then push again.
$(widened_note)
OVERRIDE: if a test genuinely does not apply (docs / config / copy only,
or a refactor already covered by existing tests), or the gate missed a
test that IS in this push (false positive), re-run with:
    SKIP_TEST_CHECK=1 <your original git push command>
BEFORE overriding you MUST explain to the user, in plain non-technical
language, WHY skipping is legitimate here -- what changed, and why no
test is needed or where the existing test already covers it -- so they
can judge whether it makes sense. Never override silently.
REFUSAL
fi

# ---------------------------------------------------------------------------
# 5. Tests are present. Ask the model whether every distinct change is covered.
# ---------------------------------------------------------------------------
msgs="$(pc_messages)"

# The judge once blocked pushes that DID edit an existing test, because the test
# file's hunk fell past the 60 KB budget (git orders the diff by path) and the
# model never saw it. Pull the test files' diffs out separately and place them
# first, untruncated, so an edit to an existing test is always visible. A test
# file new in this very command is in them too, as a diff against nothing (#1076).
diff_tests="$(pc_diff "${TEST_PATHSPEC[@]}")"

# Everything that is NOT a test file, so the budget is not spent showing the tests twice.
TEST_EXCLUDES=()
for tp in "${TEST_PATHSPEC[@]}"; do TEST_EXCLUDES+=(":(exclude)$tp"); done
diff_code="$(pc_diff . "${TEST_EXCLUDES[@]}")"

# THE BUDGET, test changes first (claude-config#723). They are what this gate judges, so they get
# what they need, and the rest of the diff gets what is left, down to half the budget: when both
# are larger than it, each gets half. They used to be cut at half the budget whatever their size,
# and then labelled as shown "in full", so a test past the cut was invisible to a reviewer told it
# was looking at all of them, which called its change untested and refused the push (L11).
# ${#var} is bytes under the C locale these hooks run in.
t_len=${#diff_tests}; c_len=${#diff_code}
if [ $(( t_len + c_len )) -le "$DIFF_BUDGET" ]; then
  t_budget=$t_len
else
  t_budget=$(( DIFF_BUDGET - c_len ))
  [ "$t_budget" -lt $(( DIFF_BUDGET / 2 )) ] && t_budget=$(( DIFF_BUDGET / 2 ))
  [ "$t_budget" -gt "$t_len" ] && t_budget=$t_len
fi
c_budget=$(( DIFF_BUDGET - t_budget ))
test_diff="$(printf '%s' "$diff_tests" | head -c "$t_budget")"
code_diff="$(printf '%s' "$diff_code" | head -c "$c_budget")"

# Which test files the cut reaches: the one it lands in and every one after it, read from the
# `diff --git` headers by byte offset, so a cut is reported by NAME (L11).
tests_cut=""
if [ "$t_len" -gt "$t_budget" ]; then
  tests_cut="$(printf '%s' "$diff_tests" | LC_ALL=C awk -v cut="$t_budget" '
    /^diff --git / { if (name != "" && end > cut) print name; name = $NF; sub(/^b\//, "", name) }
    { end += length($0) + 1 }
    END { if (name != "" && end > cut) print name }' | sort -u | tr '\n' ' ')"
  tests_cut="${tests_cut% }"
  [ -n "$tests_cut" ] || tests_cut="(a test file past the cut)"
fi
if [ -z "$tests_cut" ]; then
  t_label="TEST FILE CHANGES (new OR modified existing tests in this push, every one of them shown whole):"
else
  # The rest of the tests is shown to further calls (#1998), so this one is asked to judge only what
  # it was shown. It was told a change whose test might be in the unseen files could not be called
  # untested, which invited a pass resting on tests nobody had read.
  t_label="TEST FILE CHANGES (TRUNCATED: the first $t_budget of $t_len bytes. Cut partway or not shown at all: $tests_cut. The gate shows the rest of the test changes to further reviewers, so judge only from the test changes shown here: a change that nothing shown here tests is untested here):"
fi
if [ "$c_len" -gt "$c_budget" ]; then
  c_label="THE REST OF THE DIFF (everything that is not a test file; TRUNCATED: the first $c_budget of $c_len bytes):"
else
  c_label="THE REST OF THE DIFF (everything that is not a test file, shown whole):"
fi
diff="$(printf '%s\n%s\n\n%s\n%s\n' "$t_label" "$test_diff" "$c_label" "$code_diff")"
[ -n "$diff_code$test_diff" ] || allow empty

# Read from the WHOLE diff, before the budget cut, so a file past the cut is still named.
failure_files="$(printf '%s\n%s\n' "$diff_tests" "$diff_code" | fh_files | sed 's/^/  - /')"
[ -n "$failure_files" ] || failure_files="  none: no file in this push adds error handling or retry code"

RUBRIC="$(cat <<'EOF'
You are a strict test-coverage gate for a git push. You are given the commit
messages and the code diff being pushed (the diff includes any test files).

Identify the DISTINCT logical changes in this push:
- Group edits that are the same mechanical or thematic change across many files
  into ONE change (e.g. removing em dashes from 10 files is one change).
- Split UNRELATED bug fixes or features into separate changes, even if each
  touches only a file or two.

For each distinct change, decide:
- needsTest: true if it changes runtime/library/UI behavior or fixes a bug.
  false for pure formatting, comments, copy/text, docs, config, or type-only
  edits.
- hasTest: true only if THIS diff adds or modifies a test that would fail if
  that specific change were reverted or broken. A MODIFIED existing test file
  counts exactly the same as a brand-new test file -- judge by whether the test
  change exercises the behavior, NOT by whether the test file is new. The test
  files in this push are listed explicitly below; trust that list even if a
  given test diff hunk looks truncated.
  SPECIAL CASE: if the change touches error handling or a retry, or a background
  or scheduled job, or a call to an external API/service, hasTest is true ONLY if
  at least one of the tests exercises a failure or edge case for that change
  (a rejected/erroring call, a timeout, a duplicate/concurrent invocation, a
  malformed response) -- a test that only exercises the happy path does not
  satisfy hasTest for that change, even if a happy-path test exists.
  Which files add error handling or a retry is decided from the code, not by
  you: it is the FAILURE HANDLING FILES list in the input, read with string
  literals and comments removed. A word such as fail, error or retry in a
  string, a label, a test name, fixture data or a comment
  never makes a change error handling. A background or scheduled job or an
  external call is still judged from the diff.

Output STRICT JSON on a single line, no prose and no code fence:
{"verdict":"pass"|"block","changes":[{"summary":"...","needsTest":true,"hasTest":false}],"missing":["..."]}
Set verdict to "block" if any change has needsTest true and hasTest false.
"missing" lists the summaries of those uncovered changes.
EOF
)"

test_list_str="$test_list"; [ -n "$test_list_str" ] || test_list_str="  none"
source_list_str="$source_list"; [ -n "$source_list_str" ] || source_list_str="  none"
judge_input="$(printf 'COMMIT MESSAGES:\n%s\n\nTEST FILES CHANGED IN THIS PUSH, new OR modified existing -- all count as tests:\n%s\nSOURCE FILES CHANGED IN THIS PUSH:\n%s\nFAILURE HANDLING FILES (their added code catches, raises, branches on an error or status, or retries):\n%s\nDIFF:\n%s\n' \
  "$msgs" "$test_list_str" "$source_list_str" "$failure_files" "$diff")"

# ---------------------------------------------------------------------------
# 6. The rest of the tests, when the first call was cut short of them (claude-config#1998).
# ---------------------------------------------------------------------------
# A cut used to end the judging: a "no test" verdict over tests the reviewer was not shown all of
# was refused as COULD NOT JUDGE, so a push whose test sat past the cut (34,407 bytes of test
# changes on 2026-10-31) could only get through one commit at a time. Now the test changes past the
# cut are split into parts, each shown to a further call beside the code the first call saw and the
# changes it found untested, and a change stays untested only if no part tests it. So a refusal
# for a missing test rests on every test change having been in front of a reviewer (L11), and
# whatever could not be shown, past TEST_PARTS_MAX parts or the deadline, or a part whose call
# failed, is still refused as could not judge, naming its files: this path refused before #1998
# and must not start letting pushes through unjudged.
#
# Per file pairs (each source file with the tests that name it) were the other way the issue named.
# They were not chosen: a test that reaches a file through another (an index, a script run by path)
# names nothing, so the pair leaves it out and the refusal rests on a test the reviewer never saw.
#
# Cost. The limit: at most 1 + TEST_PARTS_MAX calls for any push, each of at most DIFF_BUDGET bytes
# of diff, the further ones made only when the first call says untested. The issue's push, as the
# issue recorded it on 2026-10-31, carried 34,407 bytes of test changes beside more than DIFF_BUDGET
# / 2 of code, so the first call shows half the budget of each and the test bytes past that, plus up
# to PART_OVERLAP repeated, fit one further call. Measured on 2026-11-01 with the suite's stub judge
# on a push of that shape (35,072 bytes of test changes, about 31 KB of code): two calls, sent
# 60,781 and 39,788 bytes.

# Splits the test changes from byte $1 on into parts of at most $2 bytes, in directory $3, as
# part.1, part.2 and so on, each with part.N.files naming the test files it holds. A part that starts
# inside a file opens with that file's header line and up to PART_OVERLAP bytes of the lines before,
# so a test the split cuts through is whole in one part; the first part starts that far before the
# cut. A line longer than half a part is carried in pieces. Prints the number of parts.
split_rest_of_tests() {   # $1 = cut offset  $2 = part size  $3 = directory; the diff on stdin
  python3 -c '
import sys
cut, limit, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
overlap = min(int(sys.argv[4]), limit // 4)
data = sys.stdin.buffer.read()
piece = max(limit // 2, 1)
lines = []
for l in data.splitlines(keepends=True):
    while len(l) > piece:
        lines.append(l[:piece]); l = l[piece:]
    lines.append(l)
hdr, cur = [], None
for i, l in enumerate(lines):
    if l.startswith(b"diff --git "):
        cur = i
    hdr.append(cur)
def name(h):
    w = lines[h].split()[-1].decode("utf-8", "replace")
    return w[2:] if w.startswith("b/") else w
off, s = 0, len(lines)
for i, l in enumerate(lines):
    if off + len(l) > cut:
        s = i; break
    off += len(l)
back = 0
while s < len(lines) and hdr[s] is not None and s > hdr[s] + 1 and back + len(lines[s - 1]) <= overlap:
    s -= 1; back += len(lines[s])
if s < len(lines) and hdr[s] is not None and s == hdr[s] + 1:
    s = hdr[s]
NOTE = b"(this file continues from the reading before)\n"
def opening(i, repeat):
    h = hdr[i]
    if h is None or i == h:
        return [], set()
    pre, j, got = [], i - 1, 0
    while repeat and j > h and got + len(lines[j]) <= overlap:
        pre.insert(0, lines[j]); got += len(lines[j]); j -= 1
    return [lines[h], NOTE] + pre, {name(h)}
parts = []
i = s
body, files = opening(i, False)
size, real = sum(map(len, body)), 0
while i < len(lines):
    l = lines[i]
    if real and size + len(l) > limit:
        parts.append((body, files))
        body, files = opening(i, True)
        size, real = sum(map(len, body)), 0
    if l.startswith(b"diff --git "):
        files.add(name(i))
    body.append(l); size += len(l); real += 1; i += 1
if real:
    parts.append((body, files))
for n, (body, files) in enumerate(parts, 1):
    with open("%s/part.%d" % (out, n), "wb") as f:
        f.write(b"".join(body))
    with open("%s/part.%d.files" % (out, n), "w", encoding="utf-8", errors="replace") as f:
        f.write("".join(x + "\n" for x in sorted(files)))
print(len(parts))
' "$1" "$2" "$3" "$PART_OVERLAP"
}

# What every call cost, summed into the PC_JUDGE_* values the record reads, so the row for the push
# carries all of its calls rather than the last one.
J_BYTES=0; J_MS=""; J_COST=""; J_START=""; J_END=""
add_call_cost() {
  [ -n "$J_START" ] || J_START="$PC_JUDGE_START"
  [ -n "$PC_JUDGE_END" ] && J_END="$PC_JUDGE_END"
  J_BYTES=$(( J_BYTES + ${PC_JUDGE_BYTES:-0} ))
  case "$PC_JUDGE_MS" in ''|*[!0-9]*) ;; *) J_MS=$(( ${J_MS:-0} + PC_JUDGE_MS )) ;; esac
  case "$PC_JUDGE_COST" in ''|*[!0-9.eE-]*) ;; *) J_COST="$(awk -v a="${J_COST:-0}" -v b="$PC_JUDGE_COST" 'BEGIN { printf "%.6f", a + b }')" ;; esac
}
use_call_costs() {
  PC_JUDGE_MODEL="$JUDGE_MODEL"; PC_JUDGE_START="$J_START"; PC_JUDGE_END="$J_END"
  PC_JUDGE_BYTES="$J_BYTES"; PC_JUDGE_MS="$J_MS"; PC_JUDGE_COST="$J_COST"
}

# Read outside a command substitution: macOS bash 3.2 refuses a quoted heredoc inside one the day
# its body gains an unpaired apostrophe (#1690).
PART_RUBRIC=""
IFS= read -r -d '' PART_RUBRIC <<'EOF' || true
You are a further reader for a strict test-coverage gate on a git push. The push's test changes
were too large to show in one reading. A first reader was shown the code being pushed and the
first part of the test changes, and found that the numbered changes listed in the input have no
test in that part. You are shown the code again and ANOTHER part of the push's test changes, one
the first reader was not shown in full.

For each numbered change, decide whether THESE test changes add or modify a test that would fail if
that specific change were reverted or broken. A MODIFIED existing test counts exactly the same as a
brand-new test. Judge only the numbered changes, and only from the test changes shown to you.
SPECIAL CASE: if the change touches error handling or a retry, or a background or scheduled job, or
a call to an external API/service, it is covered ONLY if these test changes exercise a failure or
edge case for it (a rejected/erroring call, a timeout, a duplicate/concurrent invocation, a
malformed response). Which files add error handling or a retry is the FAILURE HANDLING FILES list
in the input, decided from the code; a word such as fail, error or retry in a string, a label, a
test name, fixture data or a comment never makes a change error handling.

Output STRICT JSON on a single line, no prose and no code fence:
{"covered":[1,3]}
"covered" lists the numbers of the changes these test changes cover, and is [] when they cover none.
EOF

# Sets RT_STATE to pass (every change found tested), block (every part read, some change in none of
# them) or cantjudge (stopped before every part was read, RT_WHY saying why and RT_UNSEEN naming the
# test files no reading was shown in full), RT_MISSING to the changes still untested, one per line,
# and RT_READINGS to the readings made, the first call included. $1 = the first call's missing
# changes, one per line.
judge_rest_of_tests() {
  local dir n k i left t nums part_in list obj answer covered x
  local -a miss=()
  RT_STATE=cantjudge; RT_WHY=""; RT_UNSEEN=""; RT_MISSING="$1"; RT_READINGS=1
  i=0
  while IFS= read -r x; do [ -n "$x" ] || continue; i=$((i+1)); miss[i]="$x"; nums="${nums:+$nums }$i"; done <<MISSING_EOF
$1
MISSING_EOF
  dir="$(mktemp -d)" || { RT_WHY="the gate could not make a scratch directory to split the test changes in"; RT_UNSEEN="$tests_cut"; return 0; }
  n="$(printf '%s' "$diff_tests" | split_rest_of_tests "$t_budget" "$(( DIFF_BUDGET - ${#code_diff} ))" "$dir" 2>/dev/null)"
  if ! [ "$n" -ge 1 ] 2>/dev/null; then
    rm -rf "$dir"; RT_WHY="the gate could not split the rest of the test changes into parts"; RT_UNSEEN="$tests_cut"; return 0
  fi
  k=1
  while [ "$k" -le "$n" ]; do
    if [ "$k" -gt "$TEST_PARTS_MAX" ]; then
      RT_WHY="the test changes needed $((n + 1)) readings and the gate makes at most $((TEST_PARTS_MAX + 1)) for one push"; break
    fi
    left=$(( TESTS_DEADLINE - SECONDS ))
    if [ "$left" -lt "$PART_MIN_SECONDS" ]; then
      RT_WHY="it ran out of time: ${SECONDS} seconds had gone and the hook must finish inside 120"; break
    fi
    t=$JUDGE_TIMEOUT; [ "$left" -lt "$t" ] && t=$left
    list=""
    for x in $nums; do list="${list}${x}. ${miss[x]}"$'\n'; done
    part_in="$(printf 'COMMIT MESSAGES:\n%s\n\nCHANGES THE FIRST READER FOUND NO TEST FOR:\n%s\nFAILURE HANDLING FILES (their added code catches, raises, branches on an error or status, or retries):\n%s\n\n%s\n%s\n\nMORE TEST FILE CHANGES (reading %s of %s of the test changes the first reader was not shown in full):\n%s\n' \
      "$msgs" "$list" "$failure_files" "$c_label" "$code_diff" "$k" "$n" "$(cat "$dir/part.$k")")"
    RT_READINGS=$((RT_READINGS + 1))
    if ! pc_judge "$JUDGE_MODEL" "$t" "$PART_RUBRIC" "$part_in"; then
      add_call_cost
      RT_WHY="reading $k of the rest failed: $PC_JUDGE_ERR"; break
    fi
    add_call_cost
    answer="$(printf '%s' "$PC_JUDGE_OBJ" | python3 -c '
import sys, json
sys.stdout.reconfigure(errors="replace")
try:
    obj = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
    cov = obj.get("covered")
    if not isinstance(cov, list) or any(isinstance(x, bool) or not isinstance(x, int) for x in cov):
        print("ERR")
    else:
        print("OK " + " ".join(str(x) for x in cov))
except Exception:
    print("ERR")
' 2>/dev/null)"
    case "$answer" in
      OK*) covered=" ${answer#OK} " ;;
      *) RT_WHY="reading $k of the rest answered without a list of covered changes, so its answer could not be read"; break ;;
    esac
    local still=""
    for x in $nums; do case "$covered" in *" $x "*) ;; *) still="${still:+$still }$x" ;; esac; done
    nums="$still"
    k=$((k + 1))
    [ -n "$nums" ] || break
  done
  RT_MISSING=""
  for x in $nums; do RT_MISSING="${RT_MISSING}  - ${miss[x]}"$'\n'; done
  if [ -z "$nums" ]; then
    RT_STATE=pass
  elif [ -z "$RT_WHY" ]; then
    RT_STATE=block
  else
    RT_UNSEEN="$(i=$k; while [ "$i" -le "$n" ]; do cat "$dir/part.$i.files"; i=$((i + 1)); done | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
    RT_UNSEEN="${RT_UNSEEN% }"
    [ -n "$RT_UNSEEN" ] || RT_UNSEEN="$tests_cut"
  fi
  rm -rf "$dir"
  return 0
}

# One isolated model call, shared with the simplify gate (lib/push-changes.sh, which carries the
# measurement behind its flags). It names a judge that was missing, timed out (they have different
# fixes from one that is down), returned nothing, an error envelope or no JSON object, and this gate
# fails open on each, saying which.
pc_judge "$JUDGE_MODEL" "$JUDGE_TIMEOUT" "$RUBRIC" "$judge_input" || fail_open "$PC_JUDGE_ERR" judged
add_call_cost

verdict="$(printf '%s' "$PC_JUDGE_OBJ" | python3 -c '
import sys, json
sys.stdout.reconfigure(errors="replace")
try:
    obj = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
    missing = obj.get("missing") or []
    if obj.get("verdict") == "block" and missing:
        print("BLOCK")
        for x in missing:
            print("  - " + str(x))
    else:
        print("PASS")
except Exception:
    print("ERR_VERDICT")
' 2>/dev/null)"

case "$verdict" in
  BLOCK*)
    missing_detail="$(printf '%s\n' "$verdict" | sed '1d; s/^  - //' | paste -sd '|' -)"
    missing_shown="$(printf '%s\n' "$verdict" | sed '1d')"
    parts_note=""
    # A "no test" verdict over test changes the reviewer could not see all of is not a finding
    # that tests are missing: a test past the cut reads to it exactly like no test (#723, L11). So
    # the rest of the tests is read in further calls (#1998, step 6 above). What those calls could
    # not read is refused as COULD NOT JUDGE, naming its files, rather than waved through: a gate
    # that could not read the push does not approve it (L42), and a smaller push is always judgeable.
    if [ -n "$tests_cut" ]; then
      judge_rest_of_tests "$(printf '%s\n' "$verdict" | sed '1d; s/^  - //')"
      use_call_costs
      missing_detail="$(printf '%s' "$RT_MISSING" | sed 's/^  - //' | paste -sd '|' -)"
      missing_shown="${RT_MISSING%$'\n'}"
      case "$RT_STATE" in
        pass) allow pass "test changes read in $RT_READINGS readings" judged ;;
        block) parts_note="The push's test changes ($t_len bytes) were too many for one reading, so the
reviewer read them in $RT_READINGS parts, every byte of them, and no part held a test
for the changes above."$'\n\n' ;;
        *)
      refuse cantjudge "$missing_detail" judged <<REFUSAL
PUSH BLOCKED: the test gate could not judge this push in full.

The reviewer said these changes have no test:
$missing_shown

The push's test changes are $t_len bytes, too many for one reading. The first reading
was shown $t_budget bytes of them and the rest was split into further readings, but
the gate stopped after $RT_READINGS readings, because
$RT_WHY.
These test files were not shown in full to any reading that answered:
    $RT_UNSEEN
A test in one of them reads to the reviewer exactly like no test, so this is not a
finding that tests are missing. Push fewer commits at a time (one commit, or split the
branch) so each push's tests fit, then push again.
$(widened_note)
OVERRIDE: if you have checked that each change named above IS tested, re-run with:
    SKIP_TEST_CHECK=1 <your original git push command>
BEFORE overriding you MUST explain to the user, in plain non-technical
language, WHY skipping is legitimate here so they can judge whether it
makes sense. Never override silently.
REFUSAL
          ;;
      esac
    fi
    refuse block "$missing_detail" judged <<REFUSAL
PUSH BLOCKED: some changes in this push have no test covering them.

Distinct changes still needing a test:
$missing_shown

${parts_note}Add a test for each, then push again.
$(widened_note)
OVERRIDE: if the gate is wrong (the change is genuinely test-exempt,
or an existing test already covers it), re-run with:
    SKIP_TEST_CHECK=1 <your original git push command>
BEFORE overriding you MUST explain to the user, in plain non-technical
language, WHY skipping is legitimate here so they can judge whether it
makes sense. Never override silently.
REFUSAL
    ;;
  PASS)
    allow pass "" judged
    ;;
  ERR_VERDICT|"")
    # The judge answered a JSON object this gate could not read, or this parser itself threw.
    fail_open "judge verdict was not readable JSON" judged
    ;;
  *)
    fail_open "judge returned an unrecognized verdict" judged
    ;;
esac
