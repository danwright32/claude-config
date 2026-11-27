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

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/draft-edit-review-notice.sh"
SETTINGS="$DIR/../settings.hooks.json"
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
