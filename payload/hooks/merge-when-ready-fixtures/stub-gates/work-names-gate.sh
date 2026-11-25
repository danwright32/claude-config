#!/usr/bin/env bash
cat >> "$ST/work-names-gate-payloads"; printf '\n' >> "$ST/work-names-gate-payloads"
# work-names-gate-queue: one answer per ask, taken from the top (a blank line allows), for a gate whose
# answer changes from one ask to the next (claude-config#2558); once it is empty, the file below.
if [ -s "$ST/work-names-gate-queue" ]; then
  r="$(head -1 "$ST/work-names-gate-queue")"; tail -n +2 "$ST/work-names-gate-queue" > "$ST/work-names-gate-queue.tmp"; mv "$ST/work-names-gate-queue.tmp" "$ST/work-names-gate-queue"
  [ -z "$r" ] || jq -nc --arg r "$r" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi
[ -s "$ST/work-names-gate-deny" ] && jq -nc --arg r "$(cat "$ST/work-names-gate-deny")" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
