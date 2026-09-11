#!/usr/bin/env bash
#
# free-space-nudge.sh: put check-free-space.sh on a real event (claude-config#363).
#
# A check nothing invokes fires only when somebody types the command, which for this one is the
# occasion it adds nothing: a person typing it already suspects the disk. Built is not wired (L3).
# The failure it exists to catch is silent by nature, and on 2026-09-10 the first sign of a full
# disk inside Claude Code was an unrelated hook failing on a temp file it could not create.
#
# So it runs on UserPromptSubmit, the same shape project-list-nudge.sh and rule-files-changed.sh
# use for the same reason (L175): there is no event inside the program for "the disk filled up",
# so a prompt is the thing to hang it on.
#
# The verdict comes from check-free-space.sh rather than being worked out again here, so there is
# one implementation of the question and no second one to drift beside it (L107). This file decides
# only WHEN to speak.
#
# ONE notice per distinct answer per session, and "distinct" is the verdict plus how much is left,
# rounded down to the nearest 5 GB. That is deliberate on both sides. A notice on every prompt is
# the noise the warning exists to escape, and would teach a reader to skip it (L36). But a disk
# that goes on falling is not the same answer as one that has stopped, and going quiet about it
# would leave the most urgent case saying least (L152). So it is quiet while nothing changes, and
# speaks again for every further 5 GB lost. A new session hears it too: that session has been told
# nothing and loaded nothing.
#
# It NEVER blocks the prompt. A UserPromptSubmit hook exiting non-zero stops the turn, and a
# filling disk is something to mention, not a reason to refuse to work (L54). Every path exits 0.
#
# Environment:
#   FREE_SPACE_*                 passed straight through to the check, which owns all of them
#   FREE_SPACE_NUDGE_STATE_DIR   where the per session record is kept (default TMPDIR). A
#                                DIRECTORY, so two sessions at once each get their own and neither
#                                is told about the other's answer.
set -uo pipefail

input="$(cat 2>/dev/null || true)"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$DIR/check-free-space.sh"
[ -f "$CHECK" ] || exit 0

# The answer, and its exit code, which is what separates the four outcomes. Judged by the CODE and
# never by a line of the output (L184).
answer="$(bash "$CHECK" 2>&1)"; verdict=$?

# 0 is measured, and there is room. Nothing to say.
[ "$verdict" -eq 0 ] && exit 0

session="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
print(d.get("session_id") or d.get("transcript_path") or "")
' 2>/dev/null || true)"
[ -n "$session" ] || session="no-session"
session="$(printf '%s' "$session" | tr -c 'A-Za-z0-9' '_')"

STATE_DIR="${FREE_SPACE_NUDGE_STATE_DIR:-${TMPDIR:-/tmp}/claude-free-space-nudge}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE="$STATE_DIR/$session"

# What counts as the same answer. The GB figure is taken from the check's own sentence rather than
# measured again here, so the two cannot disagree about what was reported (L70). A verdict carrying
# no figure (the check could not measure) keys on the verdict alone, which is right: there is one
# such answer and repeating it every prompt would say nothing new.
gb="$(printf '%s' "$answer" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) GB free on.*/\1/p' | head -1)"
case "$gb" in ''|*[!0-9]*) key="$verdict" ;; *) key="$verdict-$((gb / 5))" ;; esac

if [ -f "$STATE" ] && [ "$(cat "$STATE" 2>/dev/null || true)" = "$key" ]; then
  exit 0
fi
printf '%s' "$key" > "$STATE" 2>/dev/null || true

# The remedy is named, and it is a skill rather than a sequence written out here, because the
# sequence is long, it has to be ready before the disk is full, and a message is not where it can
# live (L111: name an action that changes the state they are stuck in).
echo "$answer"
echo "What to do about it is the disk-full skill, which holds the measured triage sequence. It takes readings before it names anything, because a static size cannot say what is filling the disk."
exit 0
