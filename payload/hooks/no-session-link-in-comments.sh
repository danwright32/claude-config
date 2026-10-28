#!/usr/bin/env bash
# Block a GitHub comment, review or reply, or a Slack message, that carries the Claude session link.
# The link stays on commits, pull request descriptions and issue bodies (Dan, 2026-10-27).
#
# The rule and its message live in session_link_comment_gate.py. This is only the wrapper: read the
# payload, run the gate, and make a crash visible.
#
# Override for one command: ALLOW_SESSION_LINK_IN_COMMENT=1 <the command>.

set -uo pipefail

payload="$(cat)"

# Every Bash call reaches this hook; only one naming gh or a Slack tool can post a comment, so the
# rest skip the Python start.
case "$payload" in
  *gh*|*slack*) ;;
  *) exit 0 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A crash must not block work, but it must not be invisible either.
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
out="$(printf '%s' "$payload" | GATE_DIR="$HERE" python3 "$HERE/session_link_comment_gate.py" 2>"$err")"
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "SESSION LINK GATE DID NOT RUN: no-session-link-in-comments.sh failed (rc=$rc). A comment may post with the Claude session link in it. $(tr '\n' ' ' <"$err")" >&2
  exit 0
fi

printf '%s' "$out"
exit 0
