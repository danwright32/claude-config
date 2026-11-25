#!/usr/bin/env bash
printf "ran %s\n" "$*" >> "$ST/decoys-asked"
echo "decoy: a script named in the environment ran" >&2
jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"decoy"}}'
exit 3
