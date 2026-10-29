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

# Every Bash call reaches this hook; only one running gh, or a Slack send, can post a comment, so the
# rest skip the Python start (56 to 72 ms a call from a home folder, measured 2026-10-28).
#
# The test is the one the gate itself starts with, gh as a word in the command (\bgh\b), read here
# over the payload's JSON text from the "command" key on, so the cwd, transcript path and session id
# in front of it are never read: a bare *gh* matched "wright" in every home folder on Dan's Macs and
# never skipped anything (claude-config#1880). In the JSON text a character in front of gh may be
# written as an escape, a newline as \n and a control character as \u001f, so the letter or digit
# in front of gh there is part of an escape and counts as a boundary. Every imprecision here runs
# the gate rather than skipping it: the description after the command is read too, and a payload
# with no "command" key at all is read whole. The C locale makes every byte a character, so a byte
# that is not UTF-8 cannot make the match fail and skip the gate.
GH_WORD='(^|[^A-Za-z0-9_]|\\[A-Za-z]|\\u[0-9A-Fa-f]{4})gh([^A-Za-z0-9_]|$)'
may_post() {
  local LC_ALL=C
  case "$1" in *slack*) return 0 ;; esac
  local text="$1"
  case "$1" in *'"command"'*) text="${1#*\"command\"}" ;; esac
  [[ "$text" =~ $GH_WORD ]]
}
may_post "$payload" || exit 0

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
