#!/bin/bash
# session-namer.sh: auto-names sessions on first prompt
# Fires via UserPromptSubmit; uses a marker file to run only once per session.
# Output format: projectname-MMDD (e.g. eavesly-web-app-0410)

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)

# Bail if no session ID (shouldn't happen, but be safe)
[ -z "$SESSION_ID" ] && exit 0

# Only fire once per session. The marker is what stops the session being renamed on every prompt,
# so a marker that cannot be written is not a small failure: it is that behaviour, for the rest of
# the session, silently.
#
# The id is stripped to a safe alphabet before it goes anywhere near a path, exactly as
# teammate-challenge-gate.sh already does with the identifier it reads out of its own payload
# (L50: a value from input must never feed a path directly). One containing a separator cannot
# escape here, because the prefix ends in a character rather than a slash, so the write simply
# lands on a directory that does not exist and fails. Stripping is what makes it work instead of
# merely being safe.
SAFE_ID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9_.-')
[ -n "$SAFE_ID" ] || exit 0
MARKER="${SESSION_MARKER_DIR:-${TMPDIR:-/tmp}}/.claude-session-named-${SAFE_ID}"
[ -f "$MARKER" ] && exit 0

CWD=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)
PROJECT=$(basename "$CWD" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
DATE=$(date +%m%d)

touch "$MARKER"
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","sessionTitle":"%s-%s"}}' "$PROJECT" "$DATE"
