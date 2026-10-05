#!/usr/bin/env bash
#
# push-scope-notice.sh
# Claude Code PreToolUse(Bash) hook: REFUSE a push no push gate can judge, because the push names a
# directory the shared resolver could not resolve (claude-config#552, refusing since #589).
#
# Since #532, ps_repo_dir refuses a directory the command names but that cannot be used (missing,
# not a repository, a variable it cannot expand) rather than judging the SESSION repository in its
# place, and every push gate exits 0 on that refusal. That is right for each gate, and it left the
# push unjudged. #552 made this hook SAY so, as context the model received, and let the push
# through; on 2026-09-29 an Ovation subagent pushed with `git -C "<worktree path>" push`, the quoted
# path did not resolve, and no global gate (tests, style, the lessons scan) checked the push. A gate
# that cannot find its target and then lets the command through fails open (L42, L320), so this now
# refuses with the reason, ONCE, here, rather than each of the thirteen gates refusing in its own
# words. It asks the same two library questions the gates ask (is this a push, which repository),
# so it cannot disagree with them about when they stood down.
#
# The remedy is in the refusal: spell the path so it resolves, or cd into the repository first.
# Nothing is wrong with the push itself, only with how it names where it runs.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" || exit 0

payload="$(cat 2>/dev/null || true)"
parsed="$(ps_parse_payload "$payload" segmented)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
ps_is_git_push "$cmd" || exit 0

err="$(ps_repo_dir "$cmd" "$cwd" 2>&1 >/dev/null)"; rc=$?
# rc 2 is the refusal this exists to act on. rc 1 (no repository named and none at the session
# directory) is a push git itself will refuse, and a 0 is a push the gates do judge.
[ "$rc" -eq 2 ] || exit 0

printf 'PUSH REFUSED: no push gate could judge this push (tests, style, scanners, docs and the rest would all stand down), because it names a directory they could not resolve, and they do not fall back to %s in its place (claude-config#532, #589). %s Push again with the path spelled so it resolves (spell it absolutely, with no variable, or cd into the repository first).\n' \
  "${cwd:-the session directory}" "$err" >&2
exit 2
