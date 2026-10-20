#!/bin/bash
# design-score-gate.sh: refuse to close a "Match the settled design" issue, or its milestone, below
# 100% on both halves of the design match score (claude-config#1364).
#
# Dan, 2026-10-19: a milestone built from a settled design is done when the build matches the design,
# not when its issues are closed, so its last issue, "Match the settled design", and the milestone
# itself cannot be closed while either half of the score is below 100%. The judging is
# design-score-gate.py's; this wrapper does two things it cannot:
#
#   - leaves at once on a command that names no way of closing anything, so the commonest command
#     costs a string match and no python start;
#   - finds a merge with lib/merge-target.sh, the one reader every merge gate shares, so a pull
#     request whose closing keywords name the Match issue is judged at its head, and so
#     merge-when-ready.sh, which merges inside a script no hook sees, asks this gate as it asks the
#     others (test-merge-when-ready.sh holds that).
#
# FAILS CLOSED. When the judge cannot run, or ends any way but cleanly, a command that may close
# something is refused with exit 2 and the reason on stderr (Claude Code reads that as a refusal, and
# so does merge-when-ready.sh): an unchecked close may be a close below 100%, and unmeasured is never
# 100%. There is no override; a difference Dan means to keep is settled by a new design round or an
# exception he approves, recorded in the design file in his words.
#
# Seam, for the tests only: DESIGN_SCORE_GATE_PY, the judge to run.
set -uo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload=$(cat)

# Every word a closing route can be spelled with, `--input` and PATCH included: a state set from a
# file names no "closed" in the command at all.
case "$payload" in
  *close*|*Close*|*delete*|*DELETE*|*transfer*|*merge*|*Merge*|*enqueuePullRequest*|*PATCH*|*patch*|*--input*|*milestones*) ;;
  *) exit 0 ;;
esac

JUDGE="${DESIGN_SCORE_GATE_PY:-$HOOK_DIR/design-score-gate.py}"
args=()
if command -v jq >/dev/null 2>&1 && . "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null; then
  command="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"
  cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""')"
  [ -n "$cwd" ] || cwd="$PWD"
  if mt_is_pr_merge "$command"; then
    args=(--merge "$(mt_pr_number "$command")" "$(mt_repo_flag "$command")" "$(mt_repo_dir "$command" "$cwd")")
  fi
else
  case "$payload" in
    *merge*|*Merge*|*enqueuePullRequest*)
      echo "Refusing: the design score gate could not check whether this merge closes a Match the settled design issue below 100%, because jq or lib/merge-target.sh could not be loaded. Nothing was run." >&2
      exit 2 ;;
  esac
fi

err="$(mktemp "${TMPDIR:-/tmp}/design-score-gate.XXXXXX")" || err=/dev/null
# Spelled so an empty list is no word at all under set -u on macOS bash 3.2 (L486).
out="$(printf '%s' "$payload" | python3 "$JUDGE" ${args[@]+"${args[@]}"} 2>"$err")"
rc=$?
said="$(tail -n 3 "$err" 2>/dev/null | tr '\n' ' ')"
[ "$err" = /dev/null ] || rm -f "$err"
if [ "$rc" -ne 0 ]; then
  echo "Refusing: the design score gate could not check whether this closes a Match the settled design issue or its milestone below 100% (its judge ended with exit $rc: ${said:-nothing said}). Nothing was run; an unchecked close is never a close at 100%." >&2
  exit 2
fi
printf '%s' "$out"
exit 0
