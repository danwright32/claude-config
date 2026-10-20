#!/bin/bash
# design-score-gate.sh: refuse to close a "Match the settled design" issue, or its milestone, below
# 100% on both halves of the design match score (claude-config#1364).
#
# Dan, 2026-10-19: a milestone built from a settled design is done when the build matches the design,
# not when its issues are closed, so its last issue, "Match the settled design", and the milestone
# itself cannot be closed while either half of the score is below 100%. The judging is
# design-score-gate.py's; this wrapper does what it cannot:
#
#   - leaves at once on a command that names no way of closing anything, so the commonest command
#     costs a string match and no python start;
#   - reads the payload and any merge with the readers every gate shares (lib/push-scope.sh's
#     ps_parse_payload, lib/merge-target.sh), so a pull request whose closing keywords name the Match
#     issue is judged at its head, and merge-when-ready.sh, which merges inside a script no hook
#     sees, asks this gate as it asks the others (test-merge-when-ready.sh holds that).
#
# Two closes it lets through below 100%, both decided in the judge: an issue that only QUOTES the
# mark in code to document it is not a Match issue (#1394), and a close as "not planned" means the
# design was abandoned (Dan, 2026-10-20, #1405), as does a milestone whose Match issue was so closed.
#
# FAILS CLOSED. When a reader is missing, the merge cannot be read, or the judge ends any way but
# cleanly, a command that may close something is refused with exit 2 and the reason on stderr
# (Claude Code reads that as a refusal, and so does merge-when-ready.sh): an unchecked close may be
# a close below 100%, and unmeasured is never 100%. There is no override; a difference Dan means to
# keep is settled by a new design round or an exception he approves, in his words.
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

refuse() {  # $1 = why
  echo "Refusing to close: $1 Nothing was run; an unchecked close is never a close at 100% of the design match score (claude-config#1364)." >&2
  exit 2
}

# shellcheck source=lib/merge-target.sh
. "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null \
  || refuse "the design score gate could not load lib/merge-target.sh, so whether this command closes a Match the settled design issue below 100% could not be checked."

# The judge is python, so python3 is the one reader this gate cannot stand down without: every command
# reaching here may close something.
if ps_reader_missing python3; then
  refuse "$(ps_reader_absent_why 'python3 is not on PATH' 'design-score-gate.py, which reads this command and the score posted on GitHub, runs on it, so with python3 absent nothing here can tell whether this closes a Match the settled design issue below 100%.' 'python3')"
fi

parsed=$(ps_parse_payload "$payload" raw) || parsed=""
command="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cwd" ] || cwd="$PWD"

args=()
if mt_is_pr_merge "$command"; then
  mt_reader_missing && refuse "$(mt_reader_absent_why) Which pull request this merge closes issues with could not be read."
  # Asked in this shell, so a GraphQL merge's node is resolved once and the readings below take it.
  if mt_api_merge_untold "$command"; then
    refuse "$MT_API_WHY"
  fi
  args=(--merge "$(mt_pr_number "$command")" "$(mt_repo_flag "$command")" "$(mt_repo_dir "$command" "$cwd")")
fi

JUDGE="${DESIGN_SCORE_GATE_PY:-$HOOK_DIR/design-score-gate.py}"
err="$(mktemp "${TMPDIR:-/tmp}/design-score-gate.XXXXXX")" || err=/dev/null
# Spelled so an empty list is no word at all under set -u on macOS bash 3.2 (L486).
out="$(printf '%s' "$payload" | python3 "$JUDGE" ${args[@]+"${args[@]}"} 2>"$err")"
rc=$?
said="$(tail -n 3 "$err" 2>/dev/null | tr '\n' ' ')"
[ "$err" = /dev/null ] || rm -f "$err"
if [ "$rc" -ne 0 ]; then
  refuse "the design score gate could not check whether this closes a Match the settled design issue or its milestone below 100% (its judge ended with exit $rc: ${said:-nothing said})."
fi
printf '%s' "$out"
exit 0
