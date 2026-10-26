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
#
# Every push it reaches is recorded, override included (claude-config#1075), so whether the cheap
# judge cries wolf is read from what it did rather than guessed: lib/push-gate-report.py.

JUDGE_MODEL="haiku"    # the simplification judgment is coarse (block only on blatant issues), so the
                       # cheap model carries it. Bump to sonnet here if it starts crying wolf: the
                       # record is what says whether it has (claude-config#1075).
JUDGE_TIMEOUT=90       # seconds for the model call
DIFF_BUDGET=60000      # max bytes of source diff sent to the model

# Allow the push, but surface WHY the gate did not run. Exit 1 (non-blocking error): the push still
# runs, and the first stderr line surfaces in the transcript. Exit 0 would discard stderr, so a
# notice there would vanish and this would be theatre (the require-tests-before-push.sh precedent).
# Recorded first once the command is known to be a push, so a gate that could not decide is counted.
fail_open() {   # $1 = why  $2 = judged, when a judge was called
  if [ "${PC_PUSH:-0}" = 1 ]; then pc_record failopen "$1" "${2:-}" || :; fi
  echo "SIMPLIFY GATE DID NOT RUN ($1). Push allowed unjudged." >&2
  exit 1
}

# A silent allow, recorded. A record that could not be written is said in one line (exit 1, the push
# still runs), never swallowed and never turned into a refusal.
allow() {   # $1 = outcome  $2 = detail  $3 = judged
  pc_record "$1" "${2:-}" "${3:-}" && exit 0
  echo "SIMPLIFY GATE allowed this push ($1), but its record could not be written to $(pc_ledger_path)." >&2
  exit 1
}

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || fail_open "shared push-scope library missing"
# shellcheck source=lib/source-class.sh
. "$HOOK_DIR/lib/source-class.sh" 2>/dev/null || fail_open "shared source-class library missing"
# What the push carries, the judge call and the record, shared with the test gate (#1076).
# shellcheck source=lib/push-changes.sh
. "$HOOK_DIR/lib/push-changes.sh" 2>/dev/null || fail_open "shared push-changes library missing"
PC_GATE=simplify

# ---------------------------------------------------------------------------
# 1. Parse the hook payload (JSON on stdin) -> command + cwd.
# ---------------------------------------------------------------------------
payload="$(cat)"
parsed="$(ps_parse_payload "$payload" segmented)" || fail_open "hook payload did not parse"
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || fail_open "hook payload carried no command"
PC_CALL_ID="$(pc_call_id "$payload")"

# ---------------------------------------------------------------------------
# 2. Act only on a `git push`, in the repository it runs in; honor the override.
# ---------------------------------------------------------------------------
ps_is_git_push "$cmd" || exit 0
# Only a push is recorded: a payload that did not parse, or any other command, is not one.
PC_PUSH=1
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
# 3. The files the push carries, from the shared contract (lib/push-changes.sh). Nothing, with an
#    upstream, means the push adds nothing: stay quiet. Without one the gate may be blind (#736).
# ---------------------------------------------------------------------------
pc_resolve "$cmd"
resolved=$?
# An override is recorded with the tree it lets through, read after the resolve because a command
# that commits first delivers a tree no commit holds yet, so it can be matched to a block of it.
ps_has_override "$cmd" SKIP_SIMPLIFY_CHECK && allow override
case $resolved in
  1) allow empty ;;
  2) fail_open "no upstream branch: cannot tell what this push adds" ;;
esac

# ---------------------------------------------------------------------------
# 4. The SOURCE files in the push: is_source and NOT is_test (lib/source-class.sh, shared with the
#    test gate). Tests, generated code, config and docs are not judged for simplification here.
# ---------------------------------------------------------------------------
SRC_PATHSPEC=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  is_test "$f" && continue
  is_source "$f" && SRC_PATHSPEC+=("$f")
done <<EOF
$PC_FILES
EOF

# No source touched -> nothing to judge. Silent: a correct verdict, not a fail-open.
[ "${#SRC_PATHSPEC[@]}" -gt 0 ] || allow nosource

# ---------------------------------------------------------------------------
# 5. Build the source diff and ask the model whether it carries a material simplification.
# ---------------------------------------------------------------------------
diff_all="$(pc_diff "${SRC_PATHSPEC[@]}")"
diff_len=${#diff_all}
diff="$(printf '%s' "$diff_all" | head -c "$DIFF_BUDGET")"
if [ "$diff_len" -gt "$DIFF_BUDGET" ]; then
  trunc_note="(The source diff is $diff_len bytes; only the first $DIFF_BUDGET are shown. Judge only what you can see, and pass if you cannot see enough to be sure.)"
else
  trunc_note=""
fi
# Nothing judgeable after excludes (e.g. the only source change was a deleted file): allow, silent.
[ -n "$(printf '%s' "$diff" | tr -d '[:space:]')" ] || allow empty

msgs="$(pc_messages)"

RUBRIC="$(cat <<'EOF'
You are a strict, conservative simplification gate for a git push. You are given the commit messages
and the diff of the SOURCE files being pushed. Your job is to catch code that should plainly be made
simpler before it ships, and NOTHING else.

Flag a change only when you are highly confident a competent reviewer would agree it should be
simplified before merging. The categories, all judged on the ADDED or CHANGED code in this diff:
  - dead-code: unreachable code, or a function / branch that nothing can call or reach.
  - unused: an imported name, variable, or parameter that is introduced and never used. The diff
    shows only the changed hunks of each file, never the whole file, so a name can be used on
    lines the diff does not show; a use you saw removed is not proof that no use is left. For
    every unused finding give "file" (the path as the diff names it) and "symbol" (the bare name).
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
{"verdict":"pass"|"block","findings":[{"summary":"<what, and which file>","kind":"dead-code|unused|commented-out|debug-left|needless-complexity","file":"<path, for unused>","symbol":"<name, for unused>"}]}
Set verdict to "block" only if findings is non-empty. Keep summaries short and specific.
EOF
)"

judge_input="$(printf 'COMMIT MESSAGES:\n%s\n\n%s\nSOURCE DIFF:\n%s\n' "$msgs" "$trunc_note" "$diff")"

# One isolated model call, shared with the test gate (lib/push-changes.sh). It names a judge that was
# missing, timed out, returned nothing, an error envelope or no JSON object, and this gate fails open
# on each, saying which.
pc_judge "$JUDGE_MODEL" "$JUDGE_TIMEOUT" "$RUBRIC" "$judge_input" || fail_open "$PC_JUDGE_ERR" judged

# AN UNUSED FINDING IS CHECKED AGAINST THE WHOLE FILE (claude-config#1722). The judge sees the diff's
# hunks, never the whole file, so it cannot see a use on an unchanged line far from them. On
# 2026-10-25 it blocked a bidspoke push calling GOOGLE_PRODUCTS "newly imported but no longer used"
# because the diff replaced one use, while line 91, unchanged and unshown, still used it; removing the
# import as told would have broken the build, and the push went out on the override. So an unused
# finding that names its file and symbol is WITHDRAWN when the file as pushed names that symbol, as a
# whole word, on more than one line: the one that introduces it, and a use. The file is read as the
# push delivers it (the commit, or the working tree when the command commits first), and only a file
# the push carries. A finding naming no symbol, a file the push does not carry, or any other kind is
# kept exactly as the judge gave it. A withdrawn finding is said beside a block and recorded beside a
# pass, so how often it happens is read from the record rather than guessed.
verdict="$(printf '%s' "$PC_JUDGE_OBJ" | SIMPLIFY_FILES="$(printf '%s\n' "${SRC_PATHSPEC[@]}")" SIMPLIFY_CHAIN="${PC_COMMIT_IN_CHAIN:-0}" python3 -c '
import sys, json, os, re, subprocess

files = set(os.environ.get("SIMPLIFY_FILES", "").split("\n")) - {""}
chain = os.environ.get("SIMPLIFY_CHAIN") == "1"

def pushed(path):
    try:
        if chain:
            top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
            with open(os.path.join(top, path), encoding="utf-8", errors="replace") as fh:
                return fh.read()
        r = subprocess.run(["git", "show", "HEAD:" + path], capture_output=True, text=True, errors="replace")
        return r.stdout if r.returncode == 0 else None
    except Exception:
        return None

def used_elsewhere(f):
    if not isinstance(f, dict) or f.get("kind") != "unused":
        return False
    sym, path = f.get("symbol"), f.get("file")
    if not isinstance(sym, str) or not isinstance(path, str) or path not in files:
        return False
    if not re.fullmatch(r"[A-Za-z_$][A-Za-z0-9_$]*", sym):
        return False
    text = pushed(path)
    if text is None:
        return False
    word = re.compile(r"(?<![A-Za-z0-9_$])" + re.escape(sym) + r"(?![A-Za-z0-9_$])")
    return sum(1 for line in text.splitlines() if word.search(line)) >= 2

def said(f):
    s = f.get("summary") if isinstance(f, dict) else str(f)
    k = f.get("kind") if isinstance(f, dict) else ""
    return (("[" + str(k) + "] ") if k else "") + str(s)

try:
    obj = json.load(sys.stdin)
    findings = obj.get("findings") or []
    if obj.get("verdict") != "block" or not findings:
        print("PASS")
        sys.exit(0)
    kept = [f for f in findings if not used_elsewhere(f)]
    print("BLOCK" if kept else "PASS")
    for f in kept:
        print("  - " + said(f))
    for f in findings:
        if f not in kept:
            print("W\t" + said(f))
except Exception:
    print("ERR_VERDICT")
' 2>/dev/null)"
withdrawn="$(printf '%s\n' "$verdict" | sed -n $'s/^W\t//p')"

case "$verdict" in
  BLOCK*)
    {
      echo "PUSH BLOCKED: this push carries source code that should be simplified before it ships."
      echo ""
      echo "What the simplification reviewer flagged:"
      printf '%s\n' "$verdict" | sed -n '/^  - /p'
      echo ""
      if [ -n "$withdrawn" ]; then
        echo "Withdrawn, because the file as pushed still names the symbol on another line, which the"
        echo "reviewer, shown only the diff, could not see (claude-config#1722):"
        printf '%s\n' "$withdrawn" | sed 's/^/  - /'
        echo ""
      fi
      echo "Simplify these, re-run the tests (the push ships committed code, so the simplified code"
      echo "must pass its tests), recommit, and push again."
      echo ""
      echo "OVERRIDE: if the reviewer is wrong, or the change is right as written, re-run with:"
      echo "    SKIP_SIMPLIFY_CHECK=1 <your original git push command>"
      echo "BEFORE overriding you MUST explain to the user, in plain non-technical language, WHAT"
      echo "was flagged and WHY shipping it as-is is the right call, so they can judge. Never"
      echo "override silently."
      pc_record block "$(printf '%s\n' "$verdict" | sed -n 's/^  - //p' | paste -sd '|' -)${withdrawn:+ | withdrawn: $(printf '%s\n' "$withdrawn" | paste -sd '|' -)}" judged \
        || echo "(This block could not be written to the gate's record, $(pc_ledger_path).)"
    } >&2
    exit 2
    ;;
  PASS*)
    allow pass "${withdrawn:+withdrawn: $(printf '%s\n' "$withdrawn" | paste -sd '|' -)}" judged
    ;;
  ERR_VERDICT|"")
    # The judge answered a JSON object this gate could not read, or this parser itself threw.
    fail_open "judge verdict was not readable JSON" judged
    ;;
  *)
    fail_open "judge returned an unrecognized verdict" judged
    ;;
esac
