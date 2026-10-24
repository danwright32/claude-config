#!/usr/bin/env bash
#
# monitor-action-gate.sh
# Claude Code PreToolUse(Monitor) hook: refuse a Monitor whose command merges a pull request, pushes,
# commits, or runs the merge helper (claude-config#1587).
#
# THE ROUTE IT CLOSES. Every merge and push gate in this config is registered for the Bash tool, and
# Claude Code runs a hook only for the tools its matcher names. A Monitor runs a shell command too,
# but no PreToolUse(Bash) hook is ever run for it, so `until gh pr merge 7 --squash; do sleep 60;
# done` in a Monitor meets no merge gate at all: not the lessons review's read step, not the red
# check, not the changelog record. On 2026-10-23 a Bidspoke builder agent merged #2679 after a
# Monitor retry loop got it past the lessons review's read step. A Monitor is for watching; the action
# belongs in a Bash call, where every gate judges it.
#
# WHAT IT REFUSES, each by the one reading the gates themselves use, so a command that only MENTIONS
# one (a pgrep waiting on a push's process, a tail of the merge helper's log) is not refused:
#   a merge        mt_runs_merge (lib/merge-target.sh): gh pr merge, the API's merge endpoint, a
#                  GraphQL merge, a repo's own merge script, as block-red-merge.sh reads them
#   a push         ps_is_git_push, and a commit, ps_is_git_commit (lib/push-scope.sh)
#   the helper     lib/merge-when-ready.sh, which merges inside itself and takes the review's read key
#                  from its environment, so a loop feeding it a key read from its own output would
#                  merge with nobody having read the findings (agent-overrides.py runs-script)
# The main session is refused as well as an agent: a Monitor's command is unseen by the gates
# whoever starts it.
#
# A command this cannot read (the libraries missing) is refused when its words name a merge, a push
# or a commit at all, since letting one through unread is the route this closes (L42, L490).

set -uo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload="$(cat 2>/dev/null || true)"

# Most Monitors are a tail or a poll naming none of these, and leave before anything is loaded.
case "$payload" in *merge*|*Merge*|*enqueuePullRequest*|*push*|*commit*) ;; *) exit 0 ;; esac

refuse() { printf '%s\n' "$1" >&2; exit 2; }
WHY="no merge or push gate is ever run for a Monitor's command (they are registered for Bash), so a merge, push or commit there is judged by nothing (claude-config#1587)"
DO="Run it as a Bash call instead, in the foreground, or with run_in_background and then wait on it, so every gate judges it; a Monitor may still watch it (tail its log, or wait on its process)."

if ! . "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null; then
  refuse "REFUSED (monitor-action-gate.sh): lib/merge-target.sh is missing, so this gate cannot tell whether the Monitor's command merges, pushes or commits, and $WHY. $DO"
fi
# Every reading below is python3's: without it a merge cannot be told from a mention (L490).
if ps_reader_missing python3; then
  refuse "REFUSED (monitor-action-gate.sh): python3 is not on PATH, so this gate cannot read whether the Monitor's command merges, pushes or commits, and $WHY. Install python3. $DO"
fi
# A payload holding those words that cannot be read is refused like any other command this cannot
# read (lessons review at 310f5f0): passing it is the route this gate closes. A Monitor with no command
# at all (a WebSocket) reads as empty and is allowed.
parsed="$(ps_parse_payload "$payload" raw 2>/dev/null)" \
  || refuse "REFUSED (monitor-action-gate.sh): the Monitor's hook payload names a merge, push or commit and could not be read, and $WHY. $DO"
cmd="${parsed%%$'\x1f'*}"
[ -n "$cmd" ] || exit 0

what=""
if mt_runs_merge "$cmd" </dev/null; then what="merges a pull request"
elif ps_is_git_push "$cmd"; then what="pushes"
elif ps_is_git_commit "$cmd"; then what="commits"
else
  printf '%s' "$cmd" | python3 "$HOOK_DIR/lib/agent-overrides.py" runs-script merge-when-ready.sh >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) what="runs the merge helper, which merges inside itself" ;;
    1) ;;
    *) case "$cmd" in *merge-when-ready*) what="may run the merge helper (lib/agent-overrides.py could not read it, exit $rc)" ;; esac ;;
  esac
fi
[ -n "$what" ] || exit 0

refuse "REFUSED (monitor-action-gate.sh): this Monitor's command $what, and $WHY. $DO"
