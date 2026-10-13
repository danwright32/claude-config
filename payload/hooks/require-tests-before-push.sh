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
#
# Override: SKIP_TEST_CHECK=1 git push ...   (docs/config/copy-only, or a
# refactor already covered by existing tests; state why).
#
# Fails OPEN, but never quietly: any parse/git/model error allows the push (the
# floor in step 3 still guarantees at least one test accompanies source changes)
# AND says why, via fail_open() below. Blocking on infrastructure trouble is
# worse than allowing, but a push that was never gated must not look identical
# to a push the gate approved. (#735)
#
# Every push it reaches is recorded, override included, in the ledger the simplify gate writes too
# (claude-config#1075, #1077): lib/push-gate-report.py reads it.

JUDGE_MODEL="sonnet"
JUDGE_TIMEOUT=90       # seconds for the model call
DIFF_BUDGET=60000      # max bytes of diff sent to the model

# Allow the push, but surface WHY the gate did not run.
#
# Exit 1, not 0, is load-bearing. Claude Code discards a PreToolUse hook's
# stderr entirely on exit 0, so a notice printed there would vanish and this
# whole function would be theatre. Exit 1 is a non-blocking error: the push
# still runs, and the FIRST line of stderr surfaces in the transcript as a hook
# error notice (the rest goes to the debug log). Hence one line, reason first.
#
# Reserve this for paths where the gate wanted to decide and could not. The
# ordinary silent allows (not a push, SKIP_TEST_CHECK, no source touched,
# docs-only) are correct verdicts, not failures: making them talk would train
# everyone to tune the notice out. Recorded first once the command is known to be a push.
fail_open() {   # $1 = why  $2 = judged, when a judge was called
  if [ "${PC_PUSH:-0}" = 1 ]; then pc_record failopen "$1" "${2:-}" || :; fi
  echo "TEST GATE DID NOT RUN ($1). Push allowed ungated." >&2
  exit 1
}

# A silent allow, recorded. A record that could not be written is said in one line (exit 1, the push
# still runs), never swallowed and never turned into a refusal.
allow() {   # $1 = outcome  $2 = detail  $3 = judged
  pc_record "$1" "${2:-}" "${3:-}" && exit 0
  echo "TEST GATE allowed this push ($1), but its record could not be written to $(pc_ledger_path)." >&2
  exit 1
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
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# ---------------------------------------------------------------------------
# 1. Parse the hook payload (JSON on stdin) -> command + cwd.
# ---------------------------------------------------------------------------
payload="$(cat)"


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
repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || exit 0
[ -n "$repo_dir" ] || exit 0
cd "$repo_dir" 2>/dev/null || exit 0

# Recorded with the commit it lets through, so it can be matched to a refusal of that same commit.
ps_has_override "$cmd" SKIP_TEST_CHECK && allow override

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
case $? in
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
# '*'-leading lines are only trusted as block-comment continuations when the diff
# ALSO opens a block comment ('/*'). Without that guard, leading-operator code
# style ("const a = b" / "  * 2;") lets a real behavior change (2 -> 3) pass as
# documentation, because every changed line starts with '*'. The cost is that
# editing wording INSIDE an existing block comment now blocks; that is the safe
# direction and the override still exists.
diff_docs_only() {
  local style="$1" comment_re code d changed
  d="$(cat)"
  changed="$(printf '%s\n' "$d" \
    | grep -E '^[+-]' \
    | grep -Ev '^(\+\+\+|---)([[:space:]]|$)')"
  # Zero changed content lines (a permission/mode change such as chmod +x, or a
  # pure rename) means we can SEE no documentation change. "I saw nothing" is not
  # "there is nothing to see": treating it as docs-only let a chmod on a source
  # file pass untested, which the pre-#733 gate blocked. Fail CLOSED here -- the
  # zero-test floor below is the hard floor and must not be softened by a diff we
  # could not read.
  [ -n "$changed" ] || return 1
  changed="$(printf '%s\n' "$changed" \
    | sed -E 's/^[+-]//' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$style" in
    hash) comment_re='^#' ;;
    *)
      if printf '%s\n' "$changed" | grep -q '^/\*'; then
        comment_re='^(//|/\*|\*([[:space:]/]|$))'
      else
        comment_re='^(//|/\*|\*/$)'
      fi
      ;;
  esac
  code="$(printf '%s\n' "$changed" | grep -Ev '^[[:space:]]*$' | grep -Ev "$comment_re")"
  [ -z "$code" ]
}

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
    if ! pc_diff "$f" | diff_docs_only "$style"; then
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
  t_label="TEST FILE CHANGES (TRUNCATED: the first $t_budget of $t_len bytes. Cut partway or not shown at all: $tests_cut. A change whose test may be in those files cannot be called untested from this diff):"
fi
if [ "$c_len" -gt "$c_budget" ]; then
  c_label="THE REST OF THE DIFF (everything that is not a test file; TRUNCATED: the first $c_budget of $c_len bytes):"
else
  c_label="THE REST OF THE DIFF (everything that is not a test file, shown whole):"
fi
diff="$(printf '%s\n%s\n\n%s\n%s\n' "$t_label" "$test_diff" "$c_label" "$code_diff")"
[ -n "$diff_code$test_diff" ] || allow empty

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
  SPECIAL CASE: if the change touches error handling, a retry, a background or
  scheduled job, or a call to an external API/service, hasTest is true ONLY if
  at least one of the tests exercises a failure or edge case for that change
  (a rejected/erroring call, a timeout, a duplicate/concurrent invocation, a
  malformed response) -- a test that only exercises the happy path does not
  satisfy hasTest for that change, even if a happy-path test exists.

Output STRICT JSON on a single line, no prose and no code fence:
{"verdict":"pass"|"block","changes":[{"summary":"...","needsTest":true,"hasTest":false}],"missing":["..."]}
Set verdict to "block" if any change has needsTest true and hasTest false.
"missing" lists the summaries of those uncovered changes.
EOF
)"

test_list_str="$test_list"; [ -n "$test_list_str" ] || test_list_str="  none"
source_list_str="$source_list"; [ -n "$source_list_str" ] || source_list_str="  none"
judge_input="$(printf 'COMMIT MESSAGES:\n%s\n\nTEST FILES CHANGED IN THIS PUSH, new OR modified existing -- all count as tests:\n%s\nSOURCE FILES CHANGED IN THIS PUSH:\n%s\nDIFF:\n%s\n' \
  "$msgs" "$test_list_str" "$source_list_str" "$diff")"

# One isolated model call, shared with the simplify gate (lib/push-changes.sh, which carries the
# measurement behind its flags). It names a judge that was missing, timed out (they have different
# fixes from one that is down), returned nothing, an error envelope or no JSON object, and this gate
# fails open on each, saying which.
pc_judge "$JUDGE_MODEL" "$JUDGE_TIMEOUT" "$RUBRIC" "$judge_input" || fail_open "$PC_JUDGE_ERR" judged

verdict="$(printf '%s' "$PC_JUDGE_OBJ" | python3 -c '
import sys, json
try:
    obj = json.load(sys.stdin)
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
    # A "no test" verdict over test changes the reviewer could not see all of is not a finding
    # that tests are missing: a test past the cut reads to it exactly like no test (#723, L11). It
    # is refused as COULD NOT JUDGE, naming what was cut, rather than waved through: a gate that
    # could not read the push does not approve it (L42), and a smaller push is always judgeable.
    if [ -n "$tests_cut" ]; then
      refuse cantjudge "$missing_detail" judged <<REFUSAL
PUSH BLOCKED: the test gate could not judge this push in full.

The reviewer said these changes have no test:
$(printf '%s\n' "$verdict" | sed '1d')

but the push's test changes are $t_len bytes and it could read only the first $t_budget,
so these test files were cut partway or not shown to it at all:
    $tests_cut
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
    fi
    refuse block "$missing_detail" judged <<REFUSAL
PUSH BLOCKED: some changes in this push have no test covering them.

Distinct changes still needing a test:
$(printf '%s\n' "$verdict" | sed '1d')

Add a test for each, then push again.
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
