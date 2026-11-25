#!/usr/bin/env bash
cat >> "$ST/changelog-gate-payloads"; printf '\n' >> "$ST/changelog-gate-payloads"
[ -s "$ST/changelog-gate-deny" ] && jq -nc --arg r "$(cat "$ST/changelog-gate-deny")" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
