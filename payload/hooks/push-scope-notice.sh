#!/usr/bin/env bash
#
# push-scope-notice.sh
# Claude Code PreToolUse(Bash) hook: tell the session when no push gate judged a push, because the
# push named a directory the shared resolver could not resolve (claude-config#552).
#
# Since #532, ps_repo_dir refuses a directory the command names but that cannot be used (missing,
# not a repository, a variable it cannot expand) rather than judging the SESSION repository in its
# place, and every push gate exits 0 on that refusal. That is the right answer, and it was silent:
# the refusal's sentence went to stderr, which a PreToolUse hook exiting 0 shows to nobody, so a
# push nothing judged read exactly like a push judged clean (L98, L148).
#
# ONE hook says it, once, as additionalContext the model receives, rather than each of the thirteen
# gates adding its own copy of one sentence. It asks the same two library questions the gates ask
# (is this a push, which repository), so it cannot disagree with them about when they stood down.
# It never blocks: the push itself is not wrong, only unjudged.
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
# rc 2 is the refusal this exists to announce. rc 1 (no repository named and none at the session
# directory) is a push git itself will refuse, and a 0 is a push the gates did judge.
[ "$rc" -eq 2 ] || exit 0

PS_WHY="$err" PS_CWD="$cwd" python3 -c '
import json, os
why = os.environ.get("PS_WHY", "").strip()
cwd = os.environ.get("PS_CWD", "") or "the session directory"
msg = ("PUSH NOT JUDGED: no push gate judged this push (tests, style, scanners, docs and the rest all "
       "stood down), because it names a directory they could not resolve, and they no longer fall back "
       "to %s in its place (claude-config#532). %s If the push goes ahead it is unchecked: resolve the "
       "path (spell it absolutely, or cd into the repository first) and push again, or say plainly "
       "that this push was not checked." % (cwd, why))
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": msg}}))
' 2>/dev/null || true
exit 0
