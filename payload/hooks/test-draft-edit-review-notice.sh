#!/usr/bin/env bash
# Tests for draft-edit-review-notice.sh (claude-config#3554): the session start notice that says, at
# most once a week on a Mac, that the review of how Dan edits Slack drafts is due, and the mark it
# keeps of a draft having been saved.
#
# The clock is SET through DRAFT_EDIT_REVIEW_NOW, never waited for (L290).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
# The one wait here (for the second to change, in the clock order case) gives up at the ceiling only
# a hang reaches (lib/hang-wait.sh), never at one a loaded Mac reaches with nothing broken.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/hang-wait.sh" || {
  echo "FAIL: $(basename "$0"): lib/hang-wait.sh is missing, so this suite's wait has no ceiling."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/draft-edit-review-notice.sh"
# Which file holds the hooks block differs between the repository and an installed copy, so the one
# shared lookup answers (lib/settings-file.sh). Neither being there leaves this empty, and the wiring
# cases at the end then fail as unreadable, never as wired to nothing.
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
WORK="$(mktemp -d)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
pass=0; fail=0
check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:700}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected NOT to contain: $2"; echo "  actual: ${3:0:700}"; fi; }
check_eq(){ if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '${3:0:400}')"; fi; }

export HOOK_TESTS_RUNNING=1
unset CLAUDE_DETACHED_RUN
DAY=86400; WEEK=604800
T0=1793631600
STATE=""
fresh(){ STATE="$WORK/$1/state/draft-edit-review"; export DRAFT_EDIT_REVIEW_STATE_DIR="$STATE"; }
# start <now>: a session start at that second. saved <now>: the draft tool having just run.
start(){ printf '{"session_id":"s","cwd":"/tmp","hook_event_name":"SessionStart","source":"startup"}' | DRAFT_EDIT_REVIEW_NOW="$1" bash "$HOOK" 2>&1; }
saved(){ printf '{"session_id":"s","cwd":"/tmp","hook_event_name":"PostToolUse","tool_name":"mcp__claude_ai_Slack__slack_send_message_draft","tool_input":{"channel_id":"C0FIXTURE01","message":"invented"}}' | DRAFT_EDIT_REVIEW_NOW="$1" bash "$HOOK" 2>&1; }
DUE="is due on this Mac: drafts have been saved here since the last one"

# --- nothing to review: silence --------------------------------------------------------------------
fresh quiet
check_eq "a Mac where no draft was ever saved says nothing" "" "$(start $T0)"
check_eq "and again a year on" "" "$(start $((T0 + 365 * DAY)))"

# --- due --------------------------------------------------------------------------------------------
fresh due
check_eq "saving a draft says nothing" "" "$(saved $T0)"
check_eq "and records when" "$T0" "$(cat "$STATE/draft-saved" 2>/dev/null)"
out="$(start $((T0 + 60)))"
check "a draft saved and no review offered yet: due" "$DUE" "$out"
check "it says how to start it" "/draft-edit-review" "$out"
check "it says nothing was read" "Nothing has been read" "$out"
check_eq "in two lines at most" "1" "$([ "$(printf '%s\n' "$out" | wc -l)" -le 2 ] && echo 1 || echo 0)"
check_not "it carries no message text from the draft call" "invented" "$out"
check_eq "the offer is recorded" "$((T0 + 60))" "$(cat "$STATE/last-offered" 2>/dev/null)"

# --- not due ----------------------------------------------------------------------------------------
check_eq "the next session start says nothing" "" "$(start $((T0 + 120)))"
check_eq "nor one six days on" "" "$(start $((T0 + 60 + 6 * DAY)))"
# The week boundary, with the clock set either side of it.
check_eq "one second short of a week: nothing" "" "$(start $((T0 + 60 + WEEK - 1)))"
check "a week to the second: due again" "$DUE" "$(start $((T0 + 60 + WEEK)))"
check_eq "and that offer starts the next week" "" "$(start $((T0 + 60 + WEEK + DAY)))"

# A review finished since the last draft was saved: nothing new to look at, however long ago the offer.
echo $((T0 + 60 + WEEK + 2 * DAY)) > "$STATE/last-review"
check_eq "after a review, with no draft saved since: nothing" "" "$(start $((T0 + 60 + 3 * WEEK)))"
saved $((T0 + 60 + 3 * WEEK + 10)) >/dev/null
check "a draft saved after the review: due at the next start a week past the last offer" "$DUE" "$(start $((T0 + 60 + 3 * WEEK + 20)))"

# Only the draft tool marks a draft, under whichever server name.
fresh other
printf '{"hook_event_name":"PostToolUse","tool_name":"mcp__claude_ai_Slack__slack_read_thread","tool_input":{}}' | DRAFT_EDIT_REVIEW_NOW=$T0 bash "$HOOK" >/dev/null 2>&1
check_eq "a Slack read marks nothing" "" "$(cat "$STATE/draft-saved" 2>/dev/null)"
printf '{"hook_event_name":"PostToolUse","tool_name":"mcp__slack__slack_send_message_draft","tool_input":{}}' | DRAFT_EDIT_REVIEW_NOW=$T0 bash "$HOOK" >/dev/null 2>&1
check_eq "the draft tool under another server name marks one" "$T0" "$(cat "$STATE/draft-saved" 2>/dev/null)"

# A detached run is nobody to tell.
fresh detached
saved $T0 >/dev/null
check_eq "a detached run says nothing" "" "$(CLAUDE_DETACHED_RUN=1 start $((T0 + 60)))"
check_eq "and leaves the offer unrecorded, for a session Dan is in" "" "$(cat "$STATE/last-offered" 2>/dev/null)"

# --- state it cannot read: said, and never offered --------------------------------------------------
fresh garbage
saved $T0 >/dev/null
echo "last tuesday" > "$STATE/last-offered"
out="$(start $((T0 + 60)))"
check "a last offer that is no time: said" "could not tell whether" "$out"
check "naming the file" "last-offered" "$out"
check_not "and the review is not offered" "$DUE" "$out"
check_eq "nor is the file written over" "last tuesday" "$(cat "$STATE/last-offered")"
check_not "at the next start either, however long it stays that way" "$DUE" "$(start $((T0 + 60 + 5 * WEEK)))"

fresh future
saved $T0 >/dev/null
echo $((T0 + 10 * WEEK)) > "$STATE/last-offered"
out="$(start $((T0 + 60)))"
check "a last offer dated after now: said" "could not tell whether" "$out"
check_not "and not offered" "$DUE" "$out"

fresh badmark
mkdir -p "$STATE"; echo "soon" > "$STATE/draft-saved"
out="$(start $((T0 + 60)))"
check "a draft mark that is no time: said" "could not tell whether" "$out"
check_not "and not offered" "$DUE" "$out"

if [ "$(id -u)" != 0 ]; then
  fresh locked
  saved $T0 >/dev/null
  echo $((T0 - 2 * WEEK)) > "$STATE/last-offered"
  chmod 000 "$STATE/last-offered"
  out="$(start $((T0 + 60)))"
  check "a last offer that cannot be opened: said" "could not tell whether" "$out"
  check_not "and not offered" "$DUE" "$out"
  chmod 644 "$STATE/last-offered"

  # Due, and the offer cannot be recorded: offering would repeat at every session start, so it says so.
  fresh readonly
  saved $T0 >/dev/null
  chmod 555 "$STATE"
  out="$(start $((T0 + 60)))"
  check "an offer that cannot be recorded: said" "could not record" "$out"
  check_not "and not made, since it would be made again at every start" "$DUE" "$out"
  check_eq "the same at the next start" "$out" "$(start $((T0 + 60)))"
  chmod 755 "$STATE"

  # A folder that is there and shut before any draft was marked: the mark is lost at the draft tool,
  # in silence there, so the session start is where it is said.
  fresh shutearly
  mkdir -p "$STATE"; chmod 555 "$STATE"
  check_eq "a draft saved into a shut folder says nothing at the tool" "" "$(saved $T0)"
  check_eq "and leaves no mark" "" "$(cat "$STATE/draft-saved" 2>/dev/null)"
  out="$(start $((T0 + 60)))"
  check "the session start says the folder cannot be written" "cannot be written" "$out"
  check "and that no saved draft is marked" "no saved Slack draft is marked" "$out"
  chmod 755 "$STATE"

  # The folder itself cannot be made: the mark of a saved draft is lost, and a session start says so.
  fresh nofolder
  mkdir -p "$WORK/nofolder"; : > "$WORK/nofolder/state"
  out="$(start $((T0 + 60)))"
  check "state that has nowhere to be kept: said at session start" "could not make" "$out"
  check_not "and nothing is offered" "$DUE" "$out"
fi

# --- the review's should fix points -------------------------------------------------------------------
# S8: the mark is of a draft Slack SAVED. answered <now> <the tool's answer, as JSON>.
answered(){ printf '{"session_id":"s","cwd":"/tmp","hook_event_name":"PostToolUse","tool_name":"mcp__claude_ai_Slack__slack_send_message_draft","tool_input":{"channel_id":"C0FIXTURE01","message":"invented"},"tool_response":%s}' "$2" | DRAFT_EDIT_REVIEW_NOW="$1" bash "$HOOK" 2>&1; }
fresh notsaved
answered $T0 '[{"type":"text","text":"{\"ok\": false, \"error\": \"attached_draft_exists\"}"}]' >/dev/null
check_eq "a draft Slack answered with one of its draft errors leaves no mark" "" "$(cat "$STATE/draft-saved" 2>/dev/null)"
answered $T0 '"Error: channel_not_found"' >/dev/null
check_eq "nor one answered with an error as plain text" "" "$(cat "$STATE/draft-saved" 2>/dev/null)"
answered $T0 '{"is_error": true, "content": [{"type": "text", "text": "the draft could not be made"}]}' >/dev/null
check_eq "nor one whose answer is marked as an error" "" "$(cat "$STATE/draft-saved" 2>/dev/null)"
answered $T0 '{"ok": false}' >/dev/null
check_eq "nor one whose answer says it did not work" "" "$(cat "$STATE/draft-saved" 2>/dev/null)"
check_eq "so no review comes due on drafts that were never saved" "" "$(start $((T0 + 60)))"
answered $((T0 + 5)) '[{"type":"text","text":"{\"result\": \"Draft saved\", \"channel_link\": \"https://example.invalid/c\"}"}]' >/dev/null
check_eq "a draft Slack saved is marked" "$((T0 + 5))" "$(cat "$STATE/draft-saved" 2>/dev/null)"
# The hook and the reader hold one list of the draft tool's errors.
IFS= read -r -d '' same_errors <<'PY' || true
import re, sys
sys.stdout.reconfigure(errors="replace")
def names(path, start, end):
    try:
        with open(path, "rb") as f:
            text = f.read().decode("utf-8", "replace")
    except OSError as e:
        return "unreadable %s" % e
    cut = text[text.find(start):]
    return sorted(set(re.findall(r"[a-z]+(?:_[a-z]+)+", cut[:cut.find(end)])))
a = names(sys.argv[1], 'DRAFT_ERRORS = "', '"\n')
b = names(sys.argv[2], "DRAFT_ERROR = re.compile(", "\n\n")
print("same" if a == b and isinstance(a, list) and len(a) == 6 else "hook: %r; reader: %r" % (a, b))
PY
errors="$(python3 -B -c "$same_errors" "$HOOK" "$DIR/lib/draft-edit-diff.py" </dev/null 2>&1)"
check_eq "the errors that mean nothing was saved are the same six in the hook and the reader" "same" "$errors"

# A stored time with leading zeros is a time in base ten, never an octal number bash stops on.
fresh zeros
saved $T0 >/dev/null
echo 0900 > "$STATE/last-offered"
out="$(start $((T0 + 60)))"
check "a last offer written with a leading zero is read as that many seconds: due" "$DUE" "$out"
check_not "and bash does not stop on it as an octal number" "value too great" "$out"
check_eq "nothing else is printed beside the one line" "1" "$(printf '%s\n' "$out" | grep -c .)"

# S4: the clock is read AFTER the state files. The mark is a FIFO here, so the hook waits at it; the
# writer answers only once the hook has opened it and the second has then changed, with that later
# second. A clock read before the files calls that "a time later than now". This case uses the real clock.
if command -v mkfifo >/dev/null 2>&1; then
  fresh clockorder
  mkdir -p "$STATE"; mkfifo "$STATE/draft-saved"
  { s="$(date +%s)"; hang_wait '[ "$(date +%s)" != "$s" ]' 0.05; date +%s; } > "$STATE/draft-saved" 2>/dev/null &
  writer=$!
  out="$(printf '{"hook_event_name":"SessionStart","source":"startup"}' | env -u DRAFT_EDIT_REVIEW_NOW bash "$HOOK" 2>&1)"
  kill "$writer" 2>/dev/null; wait "$writer" 2>/dev/null
  check "a draft marked while the session was starting is not a time later than now" "$DUE" "$out"
  check_not "and is never said to be one" "later than now" "$out"
else
  fail=$((fail + 1)); echo "FAIL: there is no mkfifo here, so the order of the clock and the state files was not tested"
fi

# S5 (a): every path exits 0, so no session start and no tool call can fail on this hook.
code(){ bash "$HOOK" >/dev/null 2>&1; echo $?; }
fresh codes
check_eq "exit 0 after the draft tool" "0" "$(printf '{"hook_event_name":"PostToolUse","tool_name":"mcp__claude_ai_Slack__slack_send_message_draft"}' | DRAFT_EDIT_REVIEW_NOW=$T0 code)"
check_eq "exit 0 when the review is due" "0" "$(printf '{"hook_event_name":"SessionStart"}' | DRAFT_EDIT_REVIEW_NOW=$((T0 + 60)) code)"
check_eq "exit 0 when nothing is due" "0" "$(printf '{"hook_event_name":"SessionStart"}' | DRAFT_EDIT_REVIEW_NOW=$((T0 + 120)) code)"
echo "last tuesday" > "$STATE/last-offered"
check_eq "exit 0 when the state cannot be read" "0" "$(printf '{"hook_event_name":"SessionStart"}' | DRAFT_EDIT_REVIEW_NOW=$((T0 + 180)) code)"
check_eq "exit 0 on a payload that is not JSON" "0" "$(printf 'not json' | code)"
check_eq "exit 0 on no payload at all" "0" "$(: | code)"
check_eq "exit 0 on another event" "0" "$(printf '{"hook_event_name":"Stop"}' | code)"
if [ "$(id -u)" != 0 ]; then
  chmod 555 "$STATE"
  check_eq "exit 0 when the folder cannot be written" "0" "$(printf '{"hook_event_name":"SessionStart"}' | DRAFT_EDIT_REVIEW_NOW=$((T0 + 240)) code)"
  chmod 755 "$STATE"
fi

# S5 (b): the offer is due and the folder can be written, and the move that records it fails (a full
# disk does this). A stand in for mv that fails is first on the path, so that branch itself is run.
fresh cannotrecord
saved $T0 >/dev/null
mkdir -p "$WORK/bin"; printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/mv"; chmod 755 "$WORK/bin/mv"
out="$(printf '{"hook_event_name":"SessionStart"}' | PATH="$WORK/bin:$PATH" DRAFT_EDIT_REVIEW_NOW=$((T0 + 60)) bash "$HOOK" 2>&1)"
check "an offer whose record cannot be written is said as that" "could not record, in" "$out"
check "with why it is not offered" "it would be offered again at every session start" "$out"
check_not "and the review is not offered" "$DUE" "$out"
check_eq "no half written file is left behind" "draft-saved" "$(ls "$STATE" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

# S5 (c): outside the suites neither the folder nor the clock is taken from the environment.
mkdir -p "$WORK/outside"
printf '{"hook_event_name":"PostToolUse","tool_name":"mcp__claude_ai_Slack__slack_send_message_draft"}' | HOOK_TESTS_RUNNING=0 CLAUDE_HOME="$WORK/outside" DRAFT_EDIT_REVIEW_STATE_DIR="$WORK/elsewhere" DRAFT_EDIT_REVIEW_NOW=5 bash "$HOOK" >/dev/null 2>&1
check_eq "outside a suite the state folder is not taken from the environment" "" "$(ls "$WORK/elsewhere" 2>/dev/null)"
mark="$(cat "$WORK/outside/state/draft-edit-review/draft-saved" 2>/dev/null)"
check_eq "and the mark is kept under the config folder, at the real time, not the one in the environment" "1" "$([ -n "$mark" ] && [ "$mark" -gt 1700000000 ] && echo 1 || echo 0)"

# --- wiring -----------------------------------------------------------------------------------------
wired="$(python3 -B - "$SETTINGS" <<'PY'
import json, sys
sys.stdout.reconfigure(errors="replace")
try:
    with open(sys.argv[1], "rb") as f:
        hooks = json.loads(f.read().decode("utf-8", "replace"))["hooks"]
except (OSError, ValueError, KeyError) as e:
    print("unreadable: %s" % e)
    sys.exit(0)
found = []
for event, groups in hooks.items():
    for group in groups:
        for h in group.get("hooks", []):
            if h.get("command", "").endswith("/hooks/draft-edit-review-notice.sh"):
                found.append("%s|%s|%s" % (event, group.get("matcher", ""), h.get("timeout")))
print("\n".join(sorted(found)))
PY
)"
check "wired to SessionStart, with a timeout" "SessionStart||5" "$wired"
check "wired after the draft tool alone" "PostToolUse|mcp__.*__slack_send_message_draft|5" "$wired"
check_eq "and to nothing else: never per prompt, never per tool call" "2" "$(printf '%s\n' "$wired" | grep -c .)"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
