#!/usr/bin/env bash
#
# draft-edit-review-notice.sh
# Claude Code SessionStart hook, and PostToolUse hook after the Slack draft tool alone.
#
# Says, at most once a week on this Mac, that the review of how Dan edits Slack drafts before he
# sends them is due, and how to start it (claude-config#3554). Dan chose a weekly session start
# notice as the trigger on 2026-11-27, on that issue.
#
# IT ONLY SAYS SO. It reads no session record and no message, runs nothing, and asks nothing: a hook
# cannot put a question to Dan, and the review prints Slack message text, which belongs in a session
# only once he has asked for it. The review is the draft-edit-review skill.
#
# WHEN IT IS DUE. A week or more after the last time it said so (WEEK_SECONDS, a setting), AND a
# draft has been saved on this Mac since the last review finished. Without the second half a Mac
# that never drafts a Slack message would be told every week to review nothing (an alert posts only
# when there is something to look into). The mark of a saved draft is this same script, run after
# the draft tool: it records the second and nothing about the draft.
#
# WHERE ITS STATE IS: ~/.claude/state/draft-edit-review/, which a restart does not empty and the
# config sync does not carry, so each Mac keeps its own week. Three files, each one whole number of
# seconds since 1970:
#   draft-saved    the last time the draft tool ran here          (written here, after the tool)
#   last-offered   the last time this said the review was due     (written here, at session start)
#   last-review    the last time a review finished                (written by the skill's decisions.py)
#
# WHAT IT SAYS WHEN IT CANNOT TELL. One line naming the file, and the review is NOT offered: an offer
# made whenever the state cannot be read is an offer at every session start (L98, L11). The same
# when the offer cannot be recorded. And a session start says so when the folder cannot be made, or
# is there and cannot be written or entered, since then no saved draft can be marked and the notice
# would never come due, in silence (L13). Each of these lines comes at EVERY session start until
# the cause is put right, not once a week: only the offer itself is weekly.
#
# WHO HEARS IT. What this prints goes into the session's context, and the session is asked to tell
# Dan. Nothing checks that it did, and the week is recorded when the line is printed.
#
# Two sessions starting in the same second can both say it. Each then records the same week, and
# the cost is one line said twice.
#
# DRAFT_EDIT_REVIEW_NOW (the clock, L290) and DRAFT_EDIT_REVIEW_STATE_DIR are read only under
# HOOK_TESTS_RUNNING=1, so nothing in a real session's environment moves the week or the folder.
#
# stdout on exit 0 is added to the session's context. It never blocks: every path exits 0.

WEEK_SECONDS=604800
NAME="Draft edit review"

input="$(cat 2>/dev/null || true)"
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
# A lone surrogate escape cleaned, where the library is, as every hook takes its payload
# (claude-config#1944); without the library the payload is read as it came.
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && input="$(ps_clean_payload "$input")"

read_out="$(printf '%s' "$input" | python3 -c '
import json, re, sys
sys.stdout.reconfigure(errors="replace")
# The errors the draft tool names when Slack saved nothing: the list in DRAFT_ERROR of
# lib/draft-edit-diff.py, and the suite fails when the two differ.
DRAFT_ERRORS = "attached_draft_exists|channel_not_found|not_in_channel|failed_to_create_draft|invalid_thread_ts|thread_not_found"

def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for inner in value.values():
            yield from strings(inner)
    elif isinstance(value, list):
        for inner in value:
            yield from strings(inner)

try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
    d = d if isinstance(d, dict) else {}
    answer = d.get("tool_response")
    said = "\n".join(strings(answer))
    flagged = isinstance(answer, dict) and (answer.get("is_error") is True or answer.get("isError") is True
                                            or answer.get("ok") is False)
    failed = flagged or re.search(r"\"ok\"\s*:\s*false|\b(?:" + DRAFT_ERRORS + r")\b", said) is not None
    print(str(d.get("hook_event_name") or ""))
    print(str(d.get("tool_name") or ""))
    print("not saved" if failed else "")
except Exception:
    print("")
    print("")
    print("")
' 2>/dev/null)"
{ IFS= read -r event; IFS= read -r tool; IFS= read -r slack; } <<EOF
$read_out
EOF

STATE="${CLAUDE_HOME:-$HOME/.claude}/state/draft-edit-review"
if [ "${HOOK_TESTS_RUNNING:-}" = "1" ]; then
  STATE="${DRAFT_EDIT_REVIEW_STATE_DIR:-$STATE}"
fi
# clock: the second it is now. Called at the moment a time is needed and never before the state
# files are read: a draft another session marks while this one is starting carries a later second
# than a clock read first, and read as "a time later than now" (the review of pull request 3848, S4).
clock() {
  if [ "${HOOK_TESTS_RUNNING:-}" = "1" ] && [ -n "${DRAFT_EDIT_REVIEW_NOW:-}" ]; then
    printf '%s' "$DRAFT_EDIT_REVIEW_NOW"
  else
    date +%s
  fi
}

# put <file> <seconds>: the whole file replaced in one move, so a reader never finds half a number.
put() {
  local tmp="$1.tmp.$$"
  { printf '%s\n' "$2" > "$tmp"; } 2>/dev/null && mv -f "$tmp" "$1" 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null
  return 1
}

# --- after the draft tool: mark that a draft was saved here --------------------------------------
if [ "$event" = "PostToolUse" ]; then
  case "$tool" in
    mcp__*__slack_send_message_draft)
      # Only a draft Slack SAVED is marked. An answer that is marked as an error, or names one of the
      # draft tool's errors, saved nothing, and a review must not come due on it (S8). A payload
      # with no answer in it is marked: a review due with nothing new is the harmless side.
      [ -z "$slack" ] && mkdir -p "$STATE" 2>/dev/null && put "$STATE/draft-saved" "$(clock)" ;;
  esac
  # Nothing is said here when the mark could not be kept: the next session start finds the folder
  # missing or shut, and says so there.
  exit 0
fi
[ "$event" = "SessionStart" ] || exit 0
# A detached run has nobody to tell, and saying it there would spend the week's one notice.
[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0

cannot_tell() {   # $1 = why
  printf '[%s] could not tell whether the weekly review of how Dan edits Slack drafts is due on this Mac: %s. It was not offered, and it will not be until that is put right. Tell Dan.\n' "$NAME" "$1"
  exit 0
}

if ! mkdir -p "$STATE" 2>/dev/null; then
  printf '[%s] could not make %s, where this Mac keeps when a Slack draft was last saved and when the weekly review of how Dan edits them was last offered. Until it can, no saved draft is marked and that review never comes due. Tell Dan.\n' "$NAME" "$STATE"
  exit 0
fi
# A folder that is there and cannot be written loses the same two things, so it is said the same way,
# at every start until it is put right, whether or not a review would have been due.
if ! [ -w "$STATE" ] || ! [ -x "$STATE" ]; then
  printf '[%s] could not record anything in %s, which cannot be written: no saved Slack draft is marked there and no offer of the weekly review of draft edits can be noted, so that review is not being offered. Tell Dan.\n' "$NAME" "$STATE"
  exit 0
fi

# seconds_in <file>: sets VALUE to the number in it, or to nothing when the file is not there.
seconds_in() {
  VALUE=""
  [ -e "$1" ] || return 0
  [ -r "$1" ] || cannot_tell "$1 is there and could not be opened"
  VALUE="$(tr -d '[:space:]' < "$1" 2>/dev/null)"
  case "$VALUE" in
    ''|*[!0-9]*) cannot_tell "$1 does not hold a time this can read" ;;
  esac
  [ "${#VALUE}" -le 12 ] || cannot_tell "$1 does not hold a time this can read"
  # Read as base ten whatever zeros lead it: bash reads 0900 in arithmetic as octal and stops on the 9.
  VALUE=$((10#$VALUE))
}
# not_later <file> <seconds>: a stored time after the clock is one this cannot reason from.
not_later() {
  [ -z "$2" ] || [ "$2" -le "$NOW" ] || cannot_tell "$1 holds a time later than now"
}

seconds_in "$STATE/draft-saved"; saved="$VALUE"
# No draft was ever saved on this Mac: nothing to review, so nothing is said.
[ -n "$saved" ] || exit 0
seconds_in "$STATE/last-review"; reviewed="$VALUE"
seconds_in "$STATE/last-offered"; offered="$VALUE"
# The clock, only now that all three files are read (see clock above).
NOW="$(clock)"
not_later "$STATE/draft-saved" "$saved"
not_later "$STATE/last-review" "$reviewed"
not_later "$STATE/last-offered" "$offered"
# Nothing saved since the last review finished: nothing new to look at.
[ "$saved" -gt "${reviewed:-0}" ] || exit 0
if [ -n "$offered" ] && [ $((NOW - offered)) -lt "$WEEK_SECONDS" ]; then
  exit 0
fi

# Recorded BEFORE it is said, so an offer that cannot be recorded is never made at every start.
if ! put "$STATE/last-offered" "$NOW"; then
  printf '[%s] could not record, in %s, that the weekly review of Slack draft edits was offered, so it is not being offered: it would be offered again at every session start. Tell Dan the folder cannot be written.\n' "$NAME" "$STATE"
  exit 0
fi
printf '[%s] The weekly review of how Dan edits Slack drafts is due on this Mac: drafts have been saved here since the last one. Tell Dan in one line, and run it only when he asks, with the draft-edit-review skill (/draft-edit-review). Nothing has been read yet, and this will not say so again for a week.\n' "$NAME"
exit 0
