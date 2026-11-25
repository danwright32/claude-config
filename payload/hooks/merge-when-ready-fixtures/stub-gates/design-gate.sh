#!/usr/bin/env bash
cat >> "$ST/design-gate-payloads"; printf '\n' >> "$ST/design-gate-payloads"
[ -s "$ST/design-gate-deny" ] && jq -nc --arg r "$(cat "$ST/design-gate-deny")" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
