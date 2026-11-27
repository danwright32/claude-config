#!/usr/bin/env bash
cat >> "$ST/lessons-gate-payloads"; printf '\n' >> "$ST/lessons-gate-payloads"
[ -s "$ST/lessons-gate-deny" ] && jq -nc --arg r "$(cat "$ST/lessons-gate-deny")" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
