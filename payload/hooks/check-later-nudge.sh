#!/usr/bin/env bash
# Global Stop hook: when a turn leaves work waiting on a later day, send the session to the
# /check-later skill, so the check reaches Dan's Slack list without his having to remember the
# command (claude-config#2079). Dan, 2026-11-02: "I'd love for you to just automatically run
# /check-later without me having to remember anytime something like that comes up for the future."
#
# WHAT FIRES IT is lib/check-later-signals.py: a one shot CronCreate for a later day, a project
# memory naming a date ahead, or the assistant's own promise to check again on a later day. That
# file says why each is in and what is deliberately left out.
#
# IT ONLY POINTS. The reason names the skill file and what was spotted; the skill's own picker
# (step 6) still shows every row before anything is written, and its step 5 leaves out silently
# anything the list already holds. This hook writes nothing anywhere.
#
# ONE STOP, NOT THREE. Claude Code runs every Stop hook on the same stop and hands back every
# reason together as one continuation, so this rides the same refusal as the session reflection and
# the issue review rather than adding one. The reason asks for the check-later rows first, so their
# questions come before the reflection's and the review's pickers. On that continuation
# stop_hook_active is set and all three stand down.
#
# FAILS LOUD. A transcript that cannot be read is never "nothing to check" (L98): the hook still
# refuses the stop, says it could not read the turn, and asks Claude to judge the turn itself,
# since Claude has the conversation even when the file is gone.
#
# Stands down where its siblings do: a detached headless run, sleep mode, its own continuation, and
# a conversation whose Stop hooks are switched off with `touch <transcript>.skip-stop-hooks`.

set -uo pipefail

input=$(cat)
# Cleaned by the shared reader when it loads, as session-reflection.sh does (claude-config#1944).
case "${BASH_SOURCE[0]}" in */*) _ps_dir="${BASH_SOURCE[0]%/*}" ;; *) _ps_dir=. ;; esac
. "$_ps_dir/lib/push-scope.sh" 2>/dev/null && input="$(ps_clean_payload "$input")"

# A headless `claude -p` has nobody to add a list row for (see session-reflection.sh).
[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Asleep (claude-config#841): nobody is there to answer the skill's picker. A sleep record that
# cannot be read counts as awake (lib/sleep.sh).
if . "$SELF_DIR/lib/sleep.sh" 2>/dev/null && sleep_active; then
  exit 0
fi

stop_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$stop_active" = "true" ] && exit 0

# The skill is also where the Slack list id lives (its "## The list" section): the detector reads the
# id from this same file, so the reason's pointer and the row check can never name two lists (L83).
# CHECK_LATER_SKILL points both at another copy, as the skill's own suite does.
SKILL="${CHECK_LATER_SKILL:-$(cd "$SELF_DIR/.." && pwd)/skills/check-later/SKILL.md}"
FIRST="Do this first, before any reflection or issue review."

# The loud payload, for every way the turn could not be judged. One line of plain words, built by
# jq so a cause holding quotes still makes valid JSON.
cannot_read() { # cannot_read <why>
  local why="$1"
  jq -cn --arg r "CHECK LATER could not read this turn's transcript ($why), so it could not tell whether the turn left a check waiting on a later day. If it did (a one shot reminder, a memory naming a coming date, or a promise to check again), read $SKILL and follow it. $FIRST If it did not, say nothing about this." \
    '{decision: "block", reason: $r}' 2>/dev/null \
    || printf '{"decision":"block","reason":"CHECK LATER could not read this turn. If it left a check waiting on a later day, read %s and follow it."}\n' "$SKILL"
  exit 0
}

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$transcript" ] || cannot_read "the stop named no transcript"

# Per conversation kill switch, shared with the other Stop hooks.
[ -f "${transcript}.skip-stop-hooks" ] && exit 0

[ -f "$transcript" ] || cannot_read "there is no file at its path"

# Without python3 nothing can judge the turn. The shared notice says so once per machine.
_SPN="$SELF_DIR/lib/stop-hook-python-notice.sh"
if [ -f "$_SPN" ]; then
  . "$_SPN"
  stop_hook_python3_notice "check-later-nudge.sh"
fi

err="$(mktemp "${TMPDIR:-/tmp}/check-later-nudge.XXXXXX" 2>/dev/null)" || err="/dev/null"
spotted="$(python3 "$SELF_DIR/lib/check-later-signals.py" "$transcript" "$SKILL" 2>"$err")"
rc=$?
why="$( [ "$err" != /dev/null ] && sed -n '1s/^check-later-signals: //p' "$err")"
[ "$err" != /dev/null ] && rm -f "$err"
[ "$rc" -eq 0 ] || [ "$rc" -eq 4 ] || cannot_read "${why:-its reader exited $rc}"
[ -n "$spotted" ] || exit 0

# One sentence listing what was spotted, so Dan sees why the stop was refused.
list="$(printf '%s\n' "$spotted" | awk 'NF { n++; if (n <= 3) s = s (n > 1 ? "; " : "") $0 } END { if (n > 3) s = s "; and " (n - 3) " more"; print s }')"

# Exit 4: the turn left something, but the skill names no list id ($why), so whether its row is
# already written cannot be told. Said as that, never as an unreadable transcript (L11).
if [ "$rc" -eq 4 ]; then
  jq -cn --arg r "CHECK LATER. This turn left $list, but the check-later skill names no list id ($why), so it could not tell whether a row is already written. Tell Dan the skill is missing its list id; if the file is there, read it and follow it. $FIRST" \
    '{decision: "block", reason: $r}'
  exit 0
fi

payload="$(python3 "$SELF_DIR/lib/review-reason.py" \
  --instruction "$SKILL" --label "CHECK LATER" \
  --extra "This turn left $list. $FIRST" \
  --transcript "$transcript" 2>/dev/null)" || payload=""

if [ -n "$payload" ]; then
  printf '%s' "$payload"
else
  jq -cn --arg r "CHECK LATER. Read $SKILL and follow it. This turn left $list. $FIRST" \
    '{decision: "block", reason: $r}'
fi
