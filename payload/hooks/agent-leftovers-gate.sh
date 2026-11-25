#!/usr/bin/env bash
#
# agent-leftovers-gate.sh
# Claude Code PreToolUse(SubagentHandback) and SubagentStop hook: say which processes an agent's
# commands left running (claude-config#3561).
#
# On 2026-11-24 a builder agent's harness started several thousand generated commands with no time
# limit. 19 never ended, the agent handed back and ended, and the 19 shells ran on with no parent
# for about 90 minutes, costing about 40 GB of disk through their temporary files. Nothing said so:
# the job watcher holds an agent's stop only for background work it knows of, and these were
# children of a foreground command that had already returned.
#
# WHAT IS READ is lib/agent-leftovers.py: the processes still alive in the process group of a shell
# one of this agent's own Bash commands ran in. How a process is tied to the session and to the
# agent, what that was measured from, and what cannot be told, are written there and in
# bash-shell-mark.sh, which makes the record the tie rests on.
#
# WHAT IT DOES. It reports; it never stops a process. Stopping stays with whoever started it, by
# the process id named here (L1011).
#   At a hand back: while a process the agent's commands started is alive and the report does not
#     name its process id, the hand back is refused, naming each process's id, start time and
#     command and the agent's command that started it, so the agent stops it or names it in its
#     report with why it stays. A report that names every one goes through in silence, since the
#     report is what tells the orchestrating session. An agent that does neither is let through on
#     the third attempt (the reader's MAX_REFUSALS), so a report is never stranded here, and then
#     what it left is said to Dan and spooled for the orchestrating session's end of turn review.
#   At a stop: never refused. A refusal here would let the findings harvest, which runs at the same
#     event, read an agent that then carries on (claude-config#898); the job watcher refuses a stop
#     above the settings hooks for that reason. So an agent that ends without the hand back tool
#     is not asked anything: what it left is said to Dan and spooled, once.
#   A process already named in the report, or already said, is not said again at a later stop.
#
# WHAT IT CANNOT TELL is said, never passed over: the process table could not be read, this
# session's shells are not recorded, or the agent's transcript could not be read. Each lets the
# hand back through with a systemMessage (lib/hook-notice.sh), the first two once a session.

set -uo pipefail
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
payload="$(cat 2>/dev/null || true)"
# Only an agent's call carries an agent id; this conversation's own calls are not this hook's.
case "$payload" in *'"agent_id"'*) ;; *) exit 0 ;; esac
# Cleaned by the shared reader before python3 parses it (claude-config#1944): a lone surrogate
# escape survives the parse and raises when the text is written back out. Without the library the
# payload is read as it came, so its absence takes nothing away from this hook.
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && payload="$(ps_clean_payload "$payload")"

# shellcheck source=lib/hook-notice.sh
. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }

command -v python3 >/dev/null 2>&1 \
  || hook_allow_notice "LEFTOVER PROCESS CHECK DID NOT RUN: python3 is not on PATH, so agent-leftovers-gate.sh could not tell what this agent left running (claude-config#3561)."

# The reader answers on stdout alone; exit 3 is a payload it could not read as a hook payload, and
# any other failure is the reader's own.
out="$(printf '%s' "$payload" | python3 "$HOOK_DIR/lib/agent-leftovers.py" gate 2>/dev/null)"; rc=$?
if [ "$rc" -eq 3 ]; then
  hook_allow_notice "LEFTOVER PROCESS CHECK DID NOT RUN: lib/agent-leftovers.py could not read this hook payload, so what this agent left running could not be told (claude-config#3561)."
elif [ "$rc" -ne 0 ]; then
  hook_allow_notice "LEFTOVER PROCESS CHECK DID NOT RUN: lib/agent-leftovers.py exited $rc, so what this agent left running could not be told; run python3 $HOOK_DIR/lib/agent-leftovers.py gate on a hook payload to see why (claude-config#3561)."
fi

IFS=$'\x1f' read -r -d '' action text note <<< "$out" || true
note="${note%$'\n'}"
case "$action" in
  none) exit 0 ;;
  refuse)
    printf '%s\n' "$text" >&2
    exit 2 ;;
  notice)
    if [ -n "$note" ]; then
      cwd=""; parent=""
      if [[ "$payload" =~ \"cwd\"[[:space:]]*:[[:space:]]*\"([^\"\\]*)\" ]]; then cwd="${BASH_REMATCH[1]}"; fi
      if [[ "$payload" =~ \"transcript_path\"[[:space:]]*:[[:space:]]*\"([^\"\\]*)\" ]]; then parent="${BASH_REMATCH[1]}"; fi
      bash "$HOOK_DIR/lib/issue-spool.sh" note "${cwd:-.}" "$note" "agent-leftovers-gate.sh" "$parent" >/dev/null 2>&1 \
        || text="$text (This could not be spooled for the orchestrating session's review, so this notice is its only copy.)"
    fi
    hook_allow_notice "$text" ;;
  *)
    hook_allow_notice "LEFTOVER PROCESS CHECK DID NOT RUN: lib/agent-leftovers.py answered in a shape agent-leftovers-gate.sh does not read, so what this agent left running could not be told (claude-config#3561)." ;;
esac
