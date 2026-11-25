#!/usr/bin/env bash
cat >> "$ST/verify-gate-payloads"; printf '\n' >> "$ST/verify-gate-payloads"
printf '%s\n' "${MT_GATE_READ_BUDGET_SECONDS:-unset}" >> "$ST/verify-gate-budgets"
printf '%s\n' "${MT_SIGNIN_RUN:-unset}" >> "$ST/verify-gate-runs"
if [ -s "$ST/verify-gate-deny" ]; then
  jq -nc --arg r "$(cat "$ST/verify-gate-deny")" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
elif [ -s "$ST/verify-gate-context" ]; then
  jq -nc --arg c "$(cat "$ST/verify-gate-context")" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
fi
exit 0
