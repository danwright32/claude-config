#!/usr/bin/env bash
#
# simplify-before-push.sh
# Claude Code PreToolUse(Bash) hook.
#
# Goal: nothing reaches GitHub un-simplified. Code is written to pass its tests, then this gate gives
# the source changes in a push one more read, through a model, and BLOCKS the push when it carries a
# material, high-confidence simplification: dead or unreachable code, an unused import / variable /
# parameter, commented-out code or a stray debug print left in, or needless complexity that has an
# obviously simpler equivalent. When it blocks, the fix is to simplify, re-run the tests (the push
# only ships committed code, so the simplified code must be re-tested), recommit, and push again.
#
# NOT this gate's job, deliberately:
#   - Duplication. check-duplication.sh already blocks newly added copies, deterministically and with
#     measured thresholds. Two gates on one fault would both cry wolf on the same copy and wear the
#     override habit in (L36, L613), so the rubric below tells the judge to leave duplication alone.
#   - Style, formatting, naming, or anything subjective enough that a competent reviewer would shrug.
#     The judge is told to pass when in doubt; a gate that blocks on taste rots into theatre (L36).
#
# Pipeline (cheap to expensive), mirroring require-tests-before-push.sh:
#   1. Not a `git push`, or SKIP_SIMPLIFY_CHECK=1 override ..... allow (silent)
#   2. No SOURCE files changed (docs/config/tests only) ....... allow (silent, judge never called)
#   3. Source changed -> model judges the diff ................ allow / BLOCK
#
# Override: SKIP_SIMPLIFY_CHECK=1 git push ...  (explain to the user first, never silently: what the
# judge flagged and why shipping it as-is is the right call. One push only.)
#
# Fails OPEN, never quietly: any parse / git / judge error allows the push AND says why via
# fail_open(), because blocking on infrastructure trouble is worse than allowing, but a push that was
# never judged must not look identical to one the gate approved (L98, L42).

JUDGE_MODEL="haiku"    # the simplification judgment is coarse (block only on blatant issues), so the
                       # cheap model carries it. Bump to sonnet here if it starts crying wolf.
JUDGE_TIMEOUT=90       # seconds for the model call
DIFF_BUDGET=60000      # max bytes of source diff sent to the model

# Allow the push, but surface WHY the gate did not run. Exit 1 (non-blocking error): the push still
# runs, and the first stderr line surfaces in the transcript. Exit 0 would discard stderr, so a
# notice there would vanish and this would be theatre (the require-tests-before-push.sh precedent).
fail_open() {
  echo "SIMPLIFY GATE DID NOT RUN ($1). Push allowed unjudged." >&2
  exit 1
}

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || fail_open "shared push-scope library missing"
# shellcheck source=lib/source-class.sh
. "$HOOK_DIR/lib/source-class.sh" 2>/dev/null || fail_open "shared source-class library missing"

# ---------------------------------------------------------------------------
# 1. Parse the hook payload (JSON on stdin) -> command + cwd.
# ---------------------------------------------------------------------------
payload="$(cat)"
parsed="$(ps_parse_payload "$payload" segmented)" || fail_open "hook payload did not parse"
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || fail_open "hook payload carried no command"

# ---------------------------------------------------------------------------
# 2. Act only on a `git push`; honor the override.
# ---------------------------------------------------------------------------
ps_is_git_push "$cmd" || exit 0
ps_has_override "$cmd" SKIP_SIMPLIFY_CHECK && exit 0

# ---------------------------------------------------------------------------
# 3. Resolve repo + the commits being pushed. Shared contract with the test gate.
# ---------------------------------------------------------------------------
repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || exit 0
[ -n "$repo_dir" ] || exit 0
cd "$repo_dir" 2>/dev/null || exit 0

upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
base="$(ps_base_ref)"

commit_in_chain=0
ps_commit_in_chain "$cmd" && commit_in_chain=1

# Where the committed range starts (claude-config#441, #456), from the shared contract. The same
# no-upstream-base-is-HEAD guard the test gate carries (#736): a local base that IS the current
# commit is not a measurement of what this push adds, so read no committed range and let an empty
# file list below decide the gate is looking at nothing rather than guessing.
mb=""
base_is_head=0
if [ -z "$upstream" ] && [ -n "$base" ]; then
  case "$(git rev-parse --symbolic-full-name "$base" 2>/dev/null)" in
    refs/remotes/*) : ;;
    *) [ "$(git rev-parse --verify --quiet "$base" 2>/dev/null)" = "$(git rev-parse --verify --quiet HEAD 2>/dev/null)" ] && base_is_head=1 ;;
  esac
fi
[ "$base_is_head" -eq 1 ] || mb="$(ps_pending_base "$base")"

committed=""
[ -n "$mb" ] && committed="$(git diff --name-only --diff-filter=ACMR "$mb" HEAD 2>/dev/null)"

# The PENDING files when this command commits before it pushes (claude-config#457): the index plus
# what the shared reader says the commit takes beyond it, counting only files that exist (a test or
# source left on disk, untracked and unnamed, never reaches the commit).
pending=""
if [ "$commit_in_chain" -eq 1 ]; then
  pending="$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)"
  top="$(git rev-parse --show-toplevel 2>/dev/null)"
  while IFS= read -r f; do
    [ -n "$f" ] && [ -e "$top/$f" ] || continue
    pending="$pending
$f"
  done < <(ps_pending_files "$cmd" | tail -n +2)
fi

files="$(printf '%s\n%s\n' "$committed" "$pending" | sed '/^$/d' | sort -u)"

# An empty file list: with an upstream it means the push genuinely adds nothing (stay quiet). Without
# one, the base may have fallen back to HEAD and the gate is blind to real commits (#736) -> say so.
if [ -z "$files" ]; then
  [ -z "$upstream" ] && fail_open "no upstream branch: cannot tell what this push adds"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. The SOURCE files in the push: is_source and NOT is_test (lib/source-class.sh, shared with the
#    test gate). Tests, generated code, config and docs are not judged for simplification here.
# ---------------------------------------------------------------------------
source_paths=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  is_test "$f" && continue
  is_source "$f" && source_paths="${source_paths}${f}"$'\n'
done <<EOF
$files
EOF

# No source touched -> nothing to judge. Silent: a correct verdict, not a fail-open.
[ -n "$source_paths" ] || exit 0

# ---------------------------------------------------------------------------
# 5. Build the source diff and ask the model whether it carries a material simplification.
# ---------------------------------------------------------------------------
command -v claude >/dev/null 2>&1 || fail_open "judge unavailable: no claude CLI on PATH"
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"

SRC_PATHSPEC=()
while IFS= read -r sp; do [ -n "$sp" ] && SRC_PATHSPEC+=("$sp"); done <<EOF
$source_paths
EOF

EXCLUDES=(':(exclude)*.lock' ':(exclude)*-lock.json' ':(exclude)*.snap'
  ':(exclude)*.min.js' ':(exclude)*.min.css' ':(exclude)*.svg'
  ':(exclude)*.png' ':(exclude)*.jpg' ':(exclude)*.jpeg' ':(exclude)*.gif')

diff_committed=""
[ -n "$mb" ] && diff_committed="$(git diff "$mb" HEAD -- "${SRC_PATHSPEC[@]}" "${EXCLUDES[@]}" 2>/dev/null)"

diff_working=""
untracked_blob=""
if [ "$commit_in_chain" -eq 1 ]; then
  diff_working="$(git diff HEAD -- "${SRC_PATHSPEC[@]}" "${EXCLUDES[@]}" 2>/dev/null)"
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    [ -f "$u" ] || continue
    untracked_blob="${untracked_blob}
--- NEW FILE: ${u} ---
$(head -c 8000 "$u" 2>/dev/null)"
  done < <(git ls-files --others --exclude-standard -- "${SRC_PATHSPEC[@]}" 2>/dev/null)
fi

diff_all="$(printf '%s\n%s\n%s\n' "$diff_committed" "$diff_working" "$untracked_blob")"
diff_len=${#diff_all}
diff="$(printf '%s' "$diff_all" | head -c "$DIFF_BUDGET")"
if [ "$diff_len" -gt "$DIFF_BUDGET" ]; then
  trunc_note="(The source diff is $diff_len bytes; only the first $DIFF_BUDGET are shown. Judge only what you can see, and pass if you cannot see enough to be sure.)"
else
  trunc_note=""
fi
# Nothing judgeable after excludes (e.g. the only source change was a deleted file): allow, silent.
[ -n "$(printf '%s' "$diff" | tr -d '[:space:]')" ] || exit 0

msgs="$(git log --no-merges --format='- %s' "${mb:-HEAD}"..HEAD 2>/dev/null | head -c 4000)"

RUBRIC="$(cat <<'EOF'
You are a strict, conservative simplification gate for a git push. You are given the commit messages
and the diff of the SOURCE files being pushed. Your job is to catch code that should plainly be made
simpler before it ships, and NOTHING else.

Flag a change only when you are highly confident a competent reviewer would agree it should be
simplified before merging. The categories, all judged on the ADDED or CHANGED code in this diff:
  - dead-code: unreachable code, or a function / branch that nothing can call or reach.
  - unused: an imported name, variable, or parameter that is introduced and never used.
  - commented-out: blocks of real code left commented out.
  - debug-left: stray debugging output left in (console.log, print, dbg!, fmt.Println for tracing).
  - needless-complexity: logic with an OBVIOUSLY simpler equivalent of the same behavior, e.g. a
    redundant wrapper that only forwards, a conditional that reduces to a boolean, hand-rolling
    something the language or an already-imported library does in one call.

Do NOT flag, ever:
  - Duplication or copied code. A separate gate owns that; stay off its turf.
  - Style, formatting, naming, comments, or ordering.
  - Anything needing domain knowledge, or any judgement you are not highly confident about.
  - A simplification that would change behavior, lose a case, or is merely your preference.
When in doubt, PASS. It is far worse to block correct work than to let a small imperfection through.

Output STRICT JSON on a single line, no prose and no code fence:
{"verdict":"pass"|"block","findings":[{"summary":"<what, and which file>","kind":"dead-code|unused|commented-out|debug-left|needless-complexity"}]}
Set verdict to "block" only if findings is non-empty. Keep summaries short and specific.
EOF
)"

judge_input="$(printf 'COMMIT MESSAGES:\n%s\n\n%s\nSOURCE DIFF:\n%s\n' "$msgs" "$trunc_note" "$diff")"

# Run the judge isolated: an empty working dir + --setting-sources local so it does NOT inherit the
# user's hooks, CLAUDE.md memory, skills, or MCP servers (measured in claude-config#540 to keep the
# global config and lessons index out of its context). Keychain auth still works.
JTMP="$(mktemp -d)"
if [ -n "$TIMEOUT_BIN" ]; then
  # claude-mds-ok: --setting-sources local keeps the global config out, measured in #540.
  envelope="$(printf '%s' "$judge_input" | ( cd "$JTMP" && "$TIMEOUT_BIN" "$JUDGE_TIMEOUT" \
    claude -p --model "$JUDGE_MODEL" --output-format json \
      --strict-mcp-config --setting-sources local --system-prompt "$RUBRIC" ) 2>/dev/null )"
else
  # claude-mds-ok: --setting-sources local keeps the global config out, measured in #540.
  envelope="$(printf '%s' "$judge_input" | ( cd "$JTMP" && \
    claude -p --model "$JUDGE_MODEL" --output-format json \
      --strict-mcp-config --setting-sources local --system-prompt "$RUBRIC" ) 2>/dev/null )"
fi
judge_status=$?
rm -rf "$JTMP"
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
    findings = obj.get("findings") or []
    if obj.get("verdict") == "block" and findings:
        print("BLOCK")
        for f in findings:
            s = f.get("summary") if isinstance(f, dict) else str(f)
            k = f.get("kind") if isinstance(f, dict) else ""
            print("  - " + (("[" + str(k) + "] ") if k else "") + str(s))
    else:
        print("PASS")
except Exception:
    print("ERR_VERDICT")
' 2>/dev/null)"

case "$verdict" in
  BLOCK*)
    {
      echo "PUSH BLOCKED: this push carries source code that should be simplified before it ships."
      echo ""
      echo "What the simplification reviewer flagged:"
      printf '%s\n' "$verdict" | sed '1d'
      echo ""
      echo "Simplify these, re-run the tests (the push ships committed code, so the simplified code"
      echo "must pass its tests), recommit, and push again."
      echo ""
      echo "OVERRIDE: if the reviewer is wrong, or the change is right as written, re-run with:"
      echo "    SKIP_SIMPLIFY_CHECK=1 <your original git push command>"
      echo "BEFORE overriding you MUST explain to the user, in plain non-technical language, WHAT"
      echo "was flagged and WHY shipping it as-is is the right call, so they can judge. Never"
      echo "override silently."
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
    fail_open "judge verdict was not readable JSON"
    ;;
  *)
    fail_open "judge returned an unrecognized verdict"
    ;;
esac
