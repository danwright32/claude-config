#!/usr/bin/env bash
#
# session-notes-folder.sh
# Claude Code SessionStart hook (every source: startup, resume, clear, compact): make this session's
# notes folder and tell the session where it is (claude-config#2490).
#
# The scratchpad Claude Code hands each session is under /private/tmp, which macOS empties on every
# restart; on 2026-11-09 a restart of the work MacBook took a session's handoff.md, a guide and a
# background agent's working tree with it. The notes folder, ~/.claude/state/session-notes/
# <project>/<session>/, is on disk, outlives a restart and is never synced. The session is told to
# keep handoff.md there and to give each agent it dispatches a subfolder there, and a handoff note
# still in the scratchpad from before this shipped is copied in once. lib/session_notes.py does the
# work and decides the folder for every caller.
#
# Never blocks a session start: exits 0. A folder that cannot be made, or a payload that cannot be
# read, is said to the session and to Dan, never dropped.

set -uo pipefail
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
python3 "$HOOK_DIR/lib/session_notes.py" start 2>/dev/null \
  || printf '{"systemMessage": "The session notes folder (claude-config#2490) was not set up: lib/session_notes.py could not run, so a handoff note written in the scratchpad is lost if this Mac restarts."}\n'
exit 0
