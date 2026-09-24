#!/usr/bin/env bash
#
# lessons-core-notice.sh
# Claude Code UserPromptSubmit hook.
#
# Says, in the session, when the lessons core list is unusable and the WHOLE library is loading
# instead (claude-config#564). claude-sync decides that on every send and apply and records it in
# $CLAUDE_HOME/.lessons-core-state; the sync runs unattended, so a fallback it only prints reaches
# nobody, and a list that went bad would cost the context budget for weeks with nothing said (L357).
#
# Silent when there is no record (a Mac that has not run this version yet), when the core is not in
# use, and when it is. A fallback is said once per session per reason: a new reason is a new thing
# to say, the same one on every prompt would be noise (L36). A record that exists and cannot be read
# is said too, since that is a state nobody can vouch for (L98). Never blocks: every path exits 0.
#
# Cheap, because it runs on every prompt in every project: one file test and, only on a fallback,
# one read and one write. No process is started on the healthy day.

set -uo pipefail
input="$(cat 2>/dev/null || true)"
state_file="${CLAUDE_HOME:-$HOME/.claude}/.lessons-core-state"
[ -e "$state_file" ] || exit 0

session=""
if [[ "$input" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]+)\" ]]; then
  session="${BASH_REMATCH[1]}"
fi

if [ ! -r "$state_file" ]; then
  state="unreadable-record"
else
  IFS= read -r state < "$state_file" 2>/dev/null || state=""
  case "$state" in fallback*) ;; *) exit 0 ;; esac
fi

shown_dir="${LESSONS_CORE_NOTICE_DIR:-${CLAUDE_HOME:-$HOME/.claude}/state/lessons-core-notice}"
mark="$shown_dir/${session:-no-session}"
if [ -n "$session" ] && [ -f "$mark" ] && [ "$(cat "$mark" 2>/dev/null)" = "$state" ]; then
  exit 0
fi
mkdir -p "$shown_dir" 2>/dev/null && printf '%s\n' "$state" > "$mark" 2>/dev/null

if [ "$state" = "unreadable-record" ]; then
  echo "The lessons core state record $state_file could not be read, so nobody can say whether this session loaded the lessons core or the whole library. Check the file, then run 'claude-sync pull' to record it again."
else
  echo "The lessons core list is not usable (${state#fallback }), so the whole library of lessons is loading in every session instead of the core. Nothing is missing from what loads; the cost is context. Set the list again with 'claude-sync core-set <file of lesson numbers>'."
fi
exit 0
