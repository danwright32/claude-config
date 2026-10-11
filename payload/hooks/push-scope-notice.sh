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
#
# Since claude-config#1062 it refuses a second shape the gates stand down on: one command pushing
# from more than one repository. Every gate judges one repository per command and judged the first
# push's, so the rest went out unjudged. That refusal has its own sentence and remedy (run each
# repository's push on its own), because a resolved path is not the problem there (L11).
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" || exit 0

payload="$(cat 2>/dev/null || true)"
parsed="$(ps_parse_payload "$payload" segmented)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
ps_is_git_push "$cmd" || exit 0

# Asked through ps_repo_dirs, the list ps_repo_dir is built on, so the two causes of a gate standing
# down get their own sentence and their own remedy (L11, L111): a directory that could not be
# resolved (exit 2), or pushes into MORE THAN ONE repository (claude-config#1062), each of which
# resolved, where every gate judges one repository per command and would judge only the first.
# One capture: on exit 0 it holds the directories and nothing else, on exit 2 the sentence saying why.
out="$(ps_repo_dirs "$cmd" "$cwd" 2>&1; printf '\035%s' "$?")"
rc="${out##*$'\035'}"; out="${out%$'\035'*}"
dirs="$out"; err="$out"
# rc 1 (no repository named and none at the session directory) is a push git itself will refuse, and
# a single repository is a push the gates do judge.
if [ "$rc" -eq 0 ]; then
  case "$dirs" in *$'\n'?*) ;; *) exit 0 ;; esac
  printf 'PUSH REFUSED: this command pushes from more than one repository (%s), and every push gate (tests, style, scanners, docs and the rest) judges one repository per command, so the pushes after the first would go out with no gate having looked at them (claude-config#1062). Run each repository'"'"'s push as a command of its own.\n' \
    "$(printf '%s' "$dirs" | awk 'NF' | paste -sd ',' - | sed 's/,/, /g')" >&2
  exit 2
fi
[ "$rc" -eq 2 ] || exit 0

printf 'PUSH REFUSED: no push gate could judge this push (tests, style, scanners, docs and the rest would all stand down), because it names a directory they could not resolve, and they do not fall back to %s in its place (claude-config#532, #589). %s Push again with the path spelled so it resolves (spell it absolutely, with no variable, or cd into the repository first).\n' \
  "${cwd:-the session directory}" "$err" >&2
exit 2
