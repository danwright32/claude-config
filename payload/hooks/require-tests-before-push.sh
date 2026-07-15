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
# Fails OPEN: any parse/git/model error allows the push (the floor in step 3
# still guarantees at least one test accompanies source changes).

JUDGE_MODEL="sonnet"
JUDGE_TIMEOUT=90       # seconds for the model call
DIFF_BUDGET=60000      # max bytes of diff sent to the model

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

parsed="$(parse_payload)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0

# ---------------------------------------------------------------------------
# 2. Act only on a `git push`; honor the override.
# ---------------------------------------------------------------------------
is_push=0
while IFS= read -r seg; do
  if printf '%s' "$seg" | grep -Eq '(^|[[:space:]])([^[:space:]]*/)?(rtk[[:space:]]+)?git([[:space:]]+(-[^[:space:]]+|[A-Za-z_]+=[^[:space:]]+))*[[:space:]]+push([[:space:]]|$)'; then
    is_push=1
    break
  fi
done < <(printf '%s\n' "$cmd" | sed -E 's/(&&|\|\||;|\|)/\n/g')
[ "$is_push" -eq 1 ] || exit 0

if printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|])SKIP_TEST_CHECK=1([[:space:]]|$)'; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Resolve repo + the commits being pushed.
# ---------------------------------------------------------------------------
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

base=""
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
if [ -n "$upstream" ]; then
  base="$upstream"
else
  base="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/##')"
  if [ -z "$base" ]; then
    for c in origin/main origin/master main master; do
      if git rev-parse --verify --quiet "$c" >/dev/null 2>&1; then base="$c"; break; fi
    done
  fi
fi

# Does this command commit (and maybe stage) before it pushes? PreToolUse runs
# BEFORE the command, so for `git add ... && git commit ... && git push` the
# pending commit is not in history yet. Fold in staged / unstaged / untracked
# changes so a test added in the same breath is counted.
commit_in_chain=0
add_in_chain=0
printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|])([^[:space:]]*/)?(rtk[[:space:]]+)?git([[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)' && commit_in_chain=1
printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|])([^[:space:]]*/)?(rtk[[:space:]]+)?git([[:space:]]+[^[:space:]]+)*[[:space:]]+add([[:space:]]|$)' && add_in_chain=1
printf '%s' "$cmd" | grep -Eq 'git[[:space:]][^&|;]*commit[[:space:]][^&|;]*-[A-Za-z]*a' && add_in_chain=1

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
[ -n "$files" ] || exit 0

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
  printf '%s' "$f" | grep -Eiq '_spec\.rb$'                           && return 0
  printf '%s' "$f" | grep -Eiq 'Tests?\.(java|kt|cs|swift|scala)$'    && return 0
  printf '%s' "$f" | grep -Eiq '(^|/)conftest\.py$'                   && return 0
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

source_changed=0
test_changed=0
source_list=""
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
  fi
done <<EOF
$files
EOF

# No source touched -> nothing to gate.
[ "$source_changed" -eq 1 ] || exit 0

# Source touched but not a single test in the push -> block without a model.
if [ "$test_changed" -eq 0 ]; then
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
command -v claude >/dev/null 2>&1 || exit 0   # fail open: no judge available
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
rm -rf "$JTMP"
[ -n "$envelope" ] || exit 0   # fail open: model unreachable / timed out

verdict="$(printf '%s' "$envelope" | python3 -c '
import sys, json, re
try:
    env = json.load(sys.stdin)
    if env.get("is_error"):
        print("ERR"); sys.exit(0)
    txt = (env.get("result") or "").strip()
    txt = re.sub(r"^```[a-zA-Z]*", "", txt).strip()
    txt = re.sub(r"```$", "", txt).strip()
    m = re.search(r"\{.*\}", txt, re.S)
    if not m:
        print("ERR"); sys.exit(0)
    obj = json.loads(m.group(0))
    missing = obj.get("missing") or []
    if obj.get("verdict") == "block" and missing:
        print("BLOCK")
        for x in missing:
            print("  - " + str(x))
    else:
        print("PASS")
except Exception:
    print("ERR")
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
  *)
    # PASS or ERR -> fail open.
    exit 0
    ;;
esac
