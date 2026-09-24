#!/usr/bin/env bash
# claude-session-line.sh: print the line that says which Claude session made something
# (claude-config#536).
#
# Commits and pull requests carry a `Claude-Session:` line by the harness's own attribution rule,
# and a filed issue carried nothing, so concurrent sessions could not tell from the issue list which
# of them had filed what: on 2026-09-21 a coordination message went to the wrong session because of
# it. This is the ONE place the line is spelled (L41), used by the issue gate and by every script
# that files issues itself.
#
# Read from the environment Claude Code gives its tool calls and hooks: the claude.ai session link
# when the session has one (CLAUDE_CODE_BRIDGE_SESSION_ID, the same id the commit line carries),
# otherwise the local session id (CLAUDE_CODE_SESSION_ID, which a hook receives even in a headless
# run, measured 2026-09-23). A value that is not the shape of an id is never repeated into an
# issue. Prints nothing and exits 1 when there is no usable identity, so a caller can tell "no
# session" from a line.
set -u
bridge="${CLAUDE_CODE_BRIDGE_SESSION_ID:-}"
local_id="${CLAUDE_CODE_SESSION_ID:-}"
if [[ "$bridge" =~ ^session_[A-Za-z0-9]+$ ]]; then
  printf 'Claude-Session: https://claude.ai/code/%s\n' "$bridge"
elif [[ "$local_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  printf 'Claude-Session: local %s\n' "$local_id"
else
  exit 1
fi
