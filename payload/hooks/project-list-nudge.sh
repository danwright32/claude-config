#!/usr/bin/env bash
#
# project-list-nudge.sh: say, unprompted, when a project the list claims this Mac holds is not
# there (claude-config#157).
#
# check-project-list.sh already answered this question correctly and nothing ever asked it. It was
# named in no settings file and driven by nothing, so it fired only when a person typed the
# command, which is the one occasion it adds nothing: somebody typing it already suspects the list
# is wrong. The failure it exists to catch is silent by nature. The stale path loads at the start of
# every session, everything reading the list is sent somewhere that does not exist, and nothing
# anywhere complains. Built is not wired, and wired is not proven (L3).
#
# So the check runs on UserPromptSubmit, which is an action inside the program to hang it on, the
# same shape rule-files-changed.sh uses for the same reason (L175).
#
# ONE notice per distinct answer per session, not one per prompt. After speaking it records what it
# said, so the next prompt is quiet until the answer CHANGES. A notice on every prompt is the noise
# this exists to prevent, and a notice that never repeats would hide a second project going missing
# later (L152). A new session is told again on purpose: that session loaded the stale list at its
# own startup and has been told nothing.
#
# It NEVER blocks the prompt. A UserPromptSubmit hook exiting non-zero stops the turn, and a moved
# project is something to mention, not a reason to refuse to work (L54). Every path here exits 0.
#
# The verdict comes from check-project-list.sh rather than being worked out again here, so there is
# one implementation of the question and no second one to drift (L107). This file decides only WHEN
# to speak.
#
# Environment:
#   PROJECT_LIST_FILE       passed through: read this file instead of the synced CLAUDE.md
#   PROJECT_LIST_HOST       passed through: judge as this machine instead of the real hostname
#   PROJECT_LIST_STATE_DIR  where the per session record is kept (default TMPDIR). A DIRECTORY, so
#                           two sessions at once each get their own and neither is told about the
#                           other's answer.
set -uo pipefail

input="$(cat 2>/dev/null || true)"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$DIR/check-project-list.sh"
[ -f "$CHECK" ] || exit 0

# The answer, and its exit code, which is what separates the three outcomes. Judged by the CODE and
# never by a line of the output: a tool's last line is routinely a different measurement than its
# verdict and is usually the more reassuring of the two (L184).
answer="$(bash "$CHECK" 2>&1)"; verdict=$?

# 0 is "every listed path is there", or "this machine has no block in the list at all", which is
# also nothing to act on: both Macs read one list and the other one's block is not this Mac's
# business. Nothing to say either way.
[ "$verdict" -eq 0 ] && exit 0

# Keyed on the session, so two open at once each get their own record.
session="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
print(d.get("session_id") or d.get("transcript_path") or "")
' 2>/dev/null || true)"

say() { printf '%s\n' "$1"; exit 0; }

# With no session there is nothing to deduplicate against. It SPEAKS rather than staying silent:
# a moved project mentioned twice is a smaller failure than one never mentioned, and silence here
# is exactly what this hook exists to end (L11, L98). Why it could not deduplicate goes to stderr,
# which a UserPromptSubmit hook does not show the person.
if [ -z "$session" ]; then
  echo "project-list-nudge: the hook payload carried neither a session id nor a transcript path, so this notice could not be deduplicated and may repeat." >&2
  say "$answer"
fi

key="$(printf '%s' "$session" | shasum | cut -c1-12)"
STATE_DIR="${PROJECT_LIST_STATE_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE="$STATE_DIR/claude-project-list-${key}.state"

# Compared as the whole answer, so a project appearing, going away, or the check changing from a
# refusal to a list of missing paths all count as a change. A record that cannot be read is treated
# as no record, which speaks: erring towards saying it once too often is the right direction for a
# notice that is otherwise silent for ever.
previous="$(cat "$STATE" 2>/dev/null || true)"
[ "$answer" = "$previous" ] && exit 0

# Recorded BEFORE speaking, so a notice cannot repeat itself if anything below fails.
printf '%s' "$answer" > "$STATE" 2>/dev/null || true
say "$answer"
