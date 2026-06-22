#!/bin/bash
# session-namer.sh — auto-names sessions on first prompt
# Fires via UserPromptSubmit; uses a /tmp marker to run only once per session.
# Output format: projectname-MMDD (e.g. eavesly-web-app-0410)

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)

# Bail if no session ID (shouldn't happen, but be safe)
[ -z "$SESSION_ID" ] && exit 0

# Only fire once per session — marker file prevents re-naming on every prompt
MARKER="/tmp/.claude-session-named-${SESSION_ID}"
[ -f "$MARKER" ] && exit 0

CWD=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)
PROJECT=$(basename "$CWD" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
DATE=$(date +%m%d)

touch "$MARKER"
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","sessionTitle":"%s-%s"}}' "$PROJECT" "$DATE"
