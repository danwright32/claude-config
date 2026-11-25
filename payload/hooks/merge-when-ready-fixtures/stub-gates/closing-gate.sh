#!/usr/bin/env bash
cat >> "$ST/closing-gate-payloads"; printf '\n' >> "$ST/closing-gate-payloads"
[ -s "$ST/closing-gate-deny" ] && jq -nc --arg r "$(cat "$ST/closing-gate-deny")" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
