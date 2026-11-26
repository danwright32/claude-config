#!/usr/bin/env bash
cat >> "$ST/red-gate-payloads"; printf '\n' >> "$ST/red-gate-payloads"
printf '%s\n' "${MT_GATE_READ_BUDGET_SECONDS:-unset}" >> "$ST/red-gate-budgets"
# The phase the helper published while it asked (claude-config#1676).
sed -n 's/^phase //p' "$MWR_PHASE_DIR"/[0-9]* >> "$ST/phase-at-gate" 2>/dev/null
[ -s "$ST/red-gate-deny" ] && jq -nc --arg r "$(cat "$ST/red-gate-deny")" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
# red-gate-deny-admin: refuses only the last command it was asked about when that one carries
# --admin, the bypass merge (claude-config#3534), and allows the plain merge before it.
if [ -s "$ST/red-gate-deny-admin" ]; then
  last="$(tail -n 1 "$ST/red-gate-payloads")"
  case "$last" in *" --admin "*) jq -nc --arg r "$(cat "$ST/red-gate-deny-admin")" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' ;; esac
fi
# on-red-gate-admin: a step run once, while the gate is asked about the bypass merge, for something
# that changes between the helper's last look and the merge it sends (claude-config#3534).
if [ -s "$ST/on-red-gate-admin" ]; then
  case "$(tail -n 1 "$ST/red-gate-payloads")" in *" --admin "*) s="$(cat "$ST/on-red-gate-admin")"; : > "$ST/on-red-gate-admin"; eval "$s" ;; esac
fi
exit 0
