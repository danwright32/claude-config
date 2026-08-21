#!/usr/bin/env bash
#
# require-tests-before-push.sh
# Claude Code PreToolUse(Bash) hook.
#
# Goal: every `git push` must carry a test for each DISTINCT logical change in
# it. Not one-test-per-file and not one-test-per-push: a single sweeping change
# across many files (e.g. deleting em dashes from 10 files) needs one test, but
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
# everyone to tune the notice out.
fail_open() {
  echo "TEST GATE DID NOT RUN ($1). Push allowed ungated." >&2
  exit 1
}

# Push detection, the inline-override check and the chain/base questions are
# shared with the other push hooks, so they live in one library rather than a
# copy per hook. Deliberately NOT shared: what an empty range means. This gate
# treats it as blindness and says so (see step 3); an advisory hook cannot.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || fail_open "shared push-scope library missing"

# ---------------------------------------------------------------------------
# 1. Parse the hook payload (JSON on stdin) -> command + cwd.
# ---------------------------------------------------------------------------
payload="$(cat)"

parse_payload() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -j '
      ((.tool_input.command // "") | gsub("\n"; " ")) + "\u001f" + (.cwd // "")
    ' 2>/dev/null && return 0
  fi
  printf '%s' "$payload" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
ti = d.get("tool_input") or {}
cmd = (ti.get("command") or "").replace("\n", " ")
sys.stdout.write(cmd + "\x1f" + (d.get("cwd") or ""))
' 2>/dev/null
}

parsed="$(parse_payload)" || fail_open "hook payload did not parse"
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
# An empty command is a malformed payload too: a real Bash tool call always has
# one. A payload that parsed as JSON but carried no command means the gate saw
# nothing to inspect, which is not the same as approving the push.
[ -n "$cmd" ] || fail_open "hook payload carried no command"

# ---------------------------------------------------------------------------
# 2. Act only on a `git push`; honor the override.
# ---------------------------------------------------------------------------
ps_is_git_push "$cmd" || exit 0

if ps_has_override "$cmd" SKIP_TEST_CHECK; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Resolve repo + the commits being pushed.
# ---------------------------------------------------------------------------
# The repo is resolved from the COMMAND first and the payload cwd second. The
# cwd is the SESSION's directory, so a session rooted outside the project reaches
# it as `cd <repo> && git push`, and reading the cwd alone let every one of those
# pushes past the gate while looking exactly like a push it had approved.
repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || exit 0
[ -n "$repo_dir" ] || exit 0
cd "$repo_dir" 2>/dev/null || exit 0

# `upstream` is kept separately from `base`: step 3's blindness check below turns
# on whether a real upstream existed, which the resolved base alone cannot say.
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
base="$(ps_base_ref)"

# Does this command commit (and maybe stage) before it pushes? PreToolUse runs
# BEFORE the command, so for `git add ... && git commit ... && git push` the
# pending commit is not in history yet. Fold in staged / unstaged / untracked
# changes so a test added in the same breath is counted.
commit_in_chain=0
add_in_chain=0
ps_commit_in_chain "$cmd" && commit_in_chain=1
ps_add_in_chain "$cmd" && add_in_chain=1

if [ -n "$base" ] && git rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
  mb="$(git merge-base "$base" HEAD 2>/dev/null)"
else
  mb="$(git rev-parse --verify --quiet HEAD~1 2>/dev/null)"
fi

committed=""
[ -n "$mb" ] && committed="$(git diff --name-only --diff-filter=ACMR "$mb" HEAD 2>/dev/null)"

pending=""
if [ "$commit_in_chain" -eq 1 ]; then
  pending="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)"
  if [ "$add_in_chain" -eq 1 ]; then
    pending="$pending
$(git diff --name-only --diff-filter=ACMR 2>/dev/null)"
    # Untracked files count ONLY if the `git add` in THIS command will actually
    # stage them. Counting every untracked file (the old behavior) let a stray
    # untracked test that isn't being added satisfy the gate yet never reach the
    # commit -- so a change could ship with its test left only on disk.
    add_args="$(printf '%s' "$cmd" | sed -nE 's@.*(^|[&|;[:space:]])git[[:space:]]+add[[:space:]]+([^&|;]*).*@\2@p' | head -1)"
    add_all=0
    for a in $add_args; do
      case "$a" in -A|--all|.) add_all=1; break ;; esac
    done
    if [ "$add_all" -eq 1 ]; then
      pending="$pending
$(git ls-files --others --exclude-standard 2>/dev/null)"
    else
      while IFS= read -r u; do
        [ -z "$u" ] && continue
        for a in $add_args; do
          case "$a" in -*) continue ;; esac
          ad="${a%/}"
          if [ "$u" = "$ad" ]; then pending="$pending
$u"; break; fi
          case "$u" in "$ad"/*) pending="$pending
$u"; break ;; esac
        done
      done < <(git ls-files --others --exclude-standard 2>/dev/null)
    fi
  fi
fi

files="$(printf '%s\n%s\n' "$committed" "$pending" | sed '/^$/d' | sort -u)"
# An empty file list has two very different causes, and only one is benign.
#
# With an upstream, empty means the gate compared against the real remote tip
# and this push genuinely adds nothing. Correct verdict, stay quiet.
#
# Without one, `base` fell back through origin/HEAD, origin/main, origin/master,
# main, master. On an unpushed branch that can land on the CURRENT branch, so
# merge-base is HEAD, the diff is empty, and the hook sees nothing to gate while
# real commits are about to ship. That is the trap that fake-greened the #733
# scratch scripts. "I saw nothing" is not "there is nothing to see". (#736)
#
# Note this deliberately sits AFTER $pending is folded in: a no-upstream
# `add && commit && push` chain still has visible staged work, so the gate is
# not blind there and must judge it rather than cry blindness.
if [ -z "$files" ]; then
  [ -z "$upstream" ] && fail_open "no upstream branch: cannot tell what this push adds"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Classify: did the push change source? did it touch any test?
# ---------------------------------------------------------------------------
is_test() {
  local f="$1"
  printf '%s' "$f" | grep -Eiq '(^|/)(tests?|spec|__tests__|__mocks__)/' && return 0
  printf '%s' "$f" | grep -Eiq '\.(test|spec)\.[a-z0-9]+$'            && return 0
  # `test-foo.ts` / `test_foo.js` runnable test scripts (common in a scripts/
  # dir), but NOT test-only helpers like test-utils / test-setup / test-mocks.
  if printf '%s' "$f" | grep -Eiq '(^|/)test[-_][^/]+\.(ts|tsx|js|jsx|mjs|cjs)$' \
     && ! printf '%s' "$f" | grep -Eiq '(^|/)test[-_](utils?|helpers?|setup|fixtures?|mocks?|data|config)\.'; then
    return 0
  fi
  printf '%s' "$f" | grep -Eiq '(^|/)test_[^/]+\.py$'                 && return 0
  printf '%s' "$f" | grep -Eiq '_test\.(py|go|rb|dart|exs?)$'         && return 0
  # Deno names its tests `foo_test.ts`, which is the convention Supabase edge
  # function tests follow. Without this they read as untested source code.
  printf '%s' "$f" | grep -Eiq '_test\.(ts|tsx|js|jsx|mjs|cjs)$'       && return 0
  printf '%s' "$f" | grep -Eiq '_spec\.rb$'                           && return 0
  printf '%s' "$f" | grep -Eiq 'Tests?\.(java|kt|cs|swift|scala)$'    && return 0
  printf '%s' "$f" | grep -Eiq '(^|/)conftest\.py$'                   && return 0
  # Shell suites (claude-config#95). A whole language of tests was invisible here, and the config
  # repo's suite is entirely shell: a push carrying a one line Python change and the assertion
  # covering it, in the same commit, was blocked as untested and the change was dropped rather
  # than overridden. A gate that refuses correct work teaches the override habit, and once that is
  # habit it stops blocking the pushes it should.
  #
  # Same helper exclusion as the JavaScript branch above, for the same reason: a file of shared
  # fixtures is not a test of anything, and counting one would let a real change ride in beside it.
  #
  # Deliberately NOT paired with adding .sh to is_source. That would start gating every shell edit
  # in every project at once, which is a separate decision with a much wider blast radius, and one
  # nobody has asked for. The consequence of leaving it is stated rather than hidden: a change to a
  # shell script still needs no test of its own here.
  if printf '%s' "$f" | grep -Eiq '(^|/)(test[-_][^/]+|[^/]+[-_]test)\.(sh|bash|zsh)$' \
     && ! printf '%s' "$f" | grep -Eiq '(^|/)test[-_](utils?|helpers?|setup|fixtures?|mocks?|data|config)\.'; then
    return 0
  fi
  return 1
}

is_source() {
  local f="$1"
  printf '%s' "$f" | grep -Eiq '\.(ts|tsx|js|jsx|mjs|cjs|py|go|rs|rb|java|kt|kts|swift|scala|c|cc|cpp|h|hpp|cs|php|ex|exs|dart|m|mm)$' || return 1
  printf '%s' "$f" | grep -Eiq '(^|/)(node_modules|vendor|dist|build|out|coverage|\.next|__generated__|generated|migrations?)/' && return 1
  printf '%s' "$f" | grep -Eiq '\.d\.ts$' && return 1
  printf '%s' "$f" | grep -Eiq '(^|/)[^/]*\.(config|setup|conf)\.[a-z0-9]+$' && return 1
  # One-off analysis scripts (scripts/check-*.js etc.) are throwaway
  # investigation tools, not shipped behavior -> exempt from the gate.
  printf '%s' "$f" | grep -Eiq '(^|/)scripts/check[-_][^/]+\.(ts|tsx|js|jsx|mjs|cjs|py)$' && return 1
  # Production smoke scripts (scripts/smoke-*.ts) are hand-run verification tools
  # that hit the live system, so they cannot carry their own CI unit test ->
  # exempt them too, else every new smoke script needs a SKIP_TEST_CHECK
  # override (Slate #529, hit adding scripts/smoke-523-stickiness.ts in PR #528).
  printf '%s' "$f" | grep -Eiq '(^|/)scripts/smoke[-_][^/]+\.(ts|tsx|js|jsx|mjs|cjs|py)$' && return 1
  # Hand-run diagnostics (scripts/diag-*.mjs, e.g. the live Google/SF credential
  # probes) are the same class as check-*/smoke-*: not shipped behavior and not
  # CI-testable -> exempt from the gate.
  printf '%s' "$f" | grep -Eiq '(^|/)scripts/diag[-_][^/]+\.(ts|tsx|js|jsx|mjs|cjs|py)$' && return 1
  return 0
}

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
test_paths=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  # A test file counts the same whether it is brand-new or an existing file with
  # added/changed cases ($files comes from --diff-filter=ACMR, so M is included).
  if is_test "$f"; then
    test_changed=1
    test_list="${test_list}  - ${f}"$'\n'
    test_paths="${test_paths}${f}"$'\n'
    continue
  fi
  if is_source "$f"; then
    source_changed=1
    source_list="${source_list}  - ${f}"$'\n'
    source_paths="${source_paths}${f}"$'\n'
  fi
done <<EOF
$files
EOF

# No source touched -> nothing to gate.
[ "$source_changed" -eq 1 ] || exit 0

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
    d="$( { [ -n "$mb" ] && git diff "$mb" HEAD -- "$f" 2>/dev/null; \
            [ "$commit_in_chain" -eq 1 ] && git diff HEAD -- "$f" 2>/dev/null; } )"
    if [ -z "$d" ] && [ -f "$f" ]; then
      d="$(git diff --no-index -- /dev/null "$f" 2>/dev/null)"
    fi
    if ! printf '%s\n' "$d" | diff_docs_only "$style"; then
      docs_only=0; break
    fi
  done <<DOCS_ONLY_EOF
$source_paths
DOCS_ONLY_EOF
  [ "$examined" -ge 1 ] && [ "$docs_only" -eq 1 ] && exit 0

  {
    echo "PUSH BLOCKED: this push changes source code but adds or modifies no tests."
    echo ""
    echo "Source files in this push:"
    printf '%s' "$source_list"
    echo ""
    echo "Add a test for each distinct change, then push again."
    echo "OVERRIDE: if a test genuinely does not apply (docs / config / copy only,"
    echo "or a refactor already covered by existing tests), or the gate missed a"
    echo "test that IS in this push (false positive), re-run with:"
    echo "    SKIP_TEST_CHECK=1 <your original git push command>"
    echo "BEFORE overriding you MUST explain to the user, in plain non-technical"
    echo "language, WHY skipping is legitimate here -- what changed, and why no"
    echo "test is needed or where the existing test already covers it -- so they"
    echo "can judge whether it makes sense. Never override silently."
  } >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# 5. Tests are present. Ask the model whether every distinct change is covered.
# ---------------------------------------------------------------------------
command -v claude >/dev/null 2>&1 || fail_open "judge unavailable: no claude CLI on PATH"
# GNU `timeout` is absent on stock macOS (it ships as `gtimeout` via coreutils).
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"

msgs="$(git log --no-merges --format='- %s' "${mb:-HEAD}"..HEAD 2>/dev/null | head -c 4000)"

EXCLUDES=(':(exclude)*.lock' ':(exclude)*-lock.json' ':(exclude)*.snap'
  ':(exclude)*.min.js' ':(exclude)*.min.css' ':(exclude)*.svg'
  ':(exclude)*.png' ':(exclude)*.jpg' ':(exclude)*.jpeg' ':(exclude)*.gif')

diff_committed=""
[ -n "$mb" ] && diff_committed="$(git diff "$mb" HEAD -- . "${EXCLUDES[@]}" 2>/dev/null)"

diff_working=""
untracked_blob=""
if [ "$commit_in_chain" -eq 1 ]; then
  diff_working="$(git diff HEAD -- . "${EXCLUDES[@]}" 2>/dev/null)"
  if [ "$add_in_chain" -eq 1 ]; then
    while IFS= read -r u; do
      [ -z "$u" ] && continue
      [ -f "$u" ] || continue
      untracked_blob="${untracked_blob}
--- NEW FILE: ${u} ---
$(head -c 8000 "$u" 2>/dev/null)"
    done <<UNTRACKED
$(git ls-files --others --exclude-standard 2>/dev/null)
UNTRACKED
  fi
fi

# The judge once blocked pushes that DID edit an existing test, because the test
# file's hunk fell past the 60 KB budget (git orders the diff by path) and the
# model never saw it. Pull the test files' diffs out separately and place them
# first, untruncated, so an edit to an existing test is always visible.
TEST_PATHSPEC=()
while IFS= read -r tp; do [ -n "$tp" ] && TEST_PATHSPEC+=("$tp"); done <<EOF
$test_paths
EOF

diff_tests=""
if [ "${#TEST_PATHSPEC[@]}" -gt 0 ]; then
  [ -n "$mb" ] && diff_tests="$(git diff "$mb" HEAD -- "${TEST_PATHSPEC[@]}" "${EXCLUDES[@]}" 2>/dev/null)"
  if [ "$commit_in_chain" -eq 1 ]; then
    diff_tests="${diff_tests}
$(git diff HEAD -- "${TEST_PATHSPEC[@]}" "${EXCLUDES[@]}" 2>/dev/null)"
  fi
fi

diff_all="$(printf '%s\n%s\n%s\n' "$diff_committed" "$diff_working" "$untracked_blob")"
# Reserve up to half the budget for the (guaranteed) test diff, fill the rest
# with the full diff. ${#var} is bytes under the C locale these hooks run in.
test_diff="$(printf '%s' "$diff_tests" | head -c "$((DIFF_BUDGET / 2))")"
remaining=$(( DIFF_BUDGET - ${#test_diff} ))
[ "$remaining" -lt 0 ] && remaining=0
diff="$(printf 'TEST FILE CHANGES (new OR modified existing tests in this push):\n%s\n\nFULL DIFF (may be truncated; test changes are shown above in full):\n%s\n' \
  "$test_diff" "$(printf '%s' "$diff_all" | head -c "$remaining")")"
[ -n "$diff_all$test_diff" ] || exit 0

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

# Run the judge isolated: an empty working dir + only `local` setting sources so
# it does NOT inherit the user's hooks, CLAUDE.md memory, skills, or MCP servers
# (those otherwise hijack the result). Keychain auth still works (no --bare).
JTMP="$(mktemp -d)"
if [ -n "$TIMEOUT_BIN" ]; then
  envelope="$(printf '%s' "$judge_input" | ( cd "$JTMP" && "$TIMEOUT_BIN" "$JUDGE_TIMEOUT" \
    claude -p --model "$JUDGE_MODEL" --output-format json \
      --strict-mcp-config --setting-sources local --system-prompt "$RUBRIC" ) 2>/dev/null )"
else
  envelope="$(printf '%s' "$judge_input" | ( cd "$JTMP" && \
    claude -p --model "$JUDGE_MODEL" --output-format json \
      --strict-mcp-config --setting-sources local --system-prompt "$RUBRIC" ) 2>/dev/null )"
fi
judge_status=$?
rm -rf "$JTMP"
# `timeout` reports a killed command as 124, which is the difference between
# "the judge is down" and "the judge was too slow". Name the one that happened:
# they have different fixes.
if [ -z "$envelope" ]; then
  if [ "$judge_status" -eq 124 ]; then
    fail_open "judge timed out after ${JUDGE_TIMEOUT}s"
  fi
  fail_open "judge unreachable: returned nothing (exit $judge_status)"
fi

verdict="$(printf '%s' "$envelope" | python3 -c '
import sys, json, re
try:
    env = json.load(sys.stdin)
    if env.get("is_error"):
        print("ERR_ENVELOPE"); sys.exit(0)
    txt = (env.get("result") or "").strip()
    txt = re.sub(r"^```[a-zA-Z]*", "", txt).strip()
    txt = re.sub(r"```$", "", txt).strip()
    m = re.search(r"\{.*\}", txt, re.S)
    if not m:
        print("ERR_VERDICT"); sys.exit(0)
    obj = json.loads(m.group(0))
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
    {
      echo "PUSH BLOCKED: some changes in this push have no test covering them."
      echo ""
      echo "Distinct changes still needing a test:"
      printf '%s\n' "$verdict" | sed '1d'
      echo ""
      echo "Add a test for each, then push again."
      echo "OVERRIDE: if the gate is wrong (the change is genuinely test-exempt,"
      echo "or an existing test already covers it), re-run with:"
      echo "    SKIP_TEST_CHECK=1 <your original git push command>"
      echo "BEFORE overriding you MUST explain to the user, in plain non-technical"
      echo "language, WHY skipping is legitimate here so they can judge whether it"
      echo "makes sense. Never override silently."
    } >&2
    exit 2
    ;;
  PASS)
    exit 0
    ;;
  ERR_ENVELOPE)
    fail_open "judge returned an error envelope"
    ;;
  ERR_VERDICT|"")
    # Includes the judge answering in prose, and this parser itself throwing.
    fail_open "judge verdict was not readable JSON"
    ;;
  *)
    fail_open "judge returned an unrecognized verdict"
    ;;
esac
