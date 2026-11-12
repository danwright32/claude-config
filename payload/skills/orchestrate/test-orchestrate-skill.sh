#!/usr/bin/env bash
# Tests for answering each orchestrated item where it came from (claude-config#2199).
#
# On 2026-11-04 Dan asked that every item handed to an orchestrator gets, when done, a reply saved
# as a draft at the alert or post it came from, and that the config makes it mandatory. The same
# day he ruled that a Slack list row gets no reply ("ok ignore slack lists then. just update the
# waiting/in progress/done indicator instead. and make sure the claude config makes that mandatory
# as well"), because a list record's thread refuses a draft with channel_not_found (measured
# 2026-11-04). Two thread drafts in one channel were both accepted, so the one draft per channel
# limit does not stand in the way of one draft per thread.
#
# What this holds the skill to, each a fixed phrase it must carry:
#   1. intake records each item's source in a form a reply can be aimed at;
#   2. the board has a Source column;
#   3. a Slack message item gets a draft reply in its thread, through /no-ai-tells, never sent;
#   4. a Slack list row gets no reply and has its Status moved through the three values;
#   5. an issue is answered where it came from;
#   6. Finish lists every saved draft with its link;
#   7. both halves are stated as mandatory.
#
# ORCHESTRATE_SKILL points the suite at another copy, which is how a broken copy is shown to fail.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="${ORCHESTRATE_SKILL:-$DIR/SKILL.md}"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}

# A section runs from its heading to the next heading of the same or a higher level.
section() { # section <exact heading line>
  awk -v h="$1" '
    BEGIN { n = index(h, " ") - 1 }
    $0 == h { on = 1; next }
    on && /^#+ / { m = index($0, " ") - 1; if (m <= n) exit }
    on { print }
  ' "$SKILL" 2>/dev/null
}
has() { # has <description> <section text> <fixed text>   case insensitive
  check "$1" "$(grep -q -i -F -- "$3" <<< "$2" && echo ok || echo "no '$3' where expected in $SKILL")"
}

[ -r "$SKILL" ] || { check "the orchestrate skill is readable" "cannot read $SKILL"; }

intake="$(section "## 1. Intake")"
board="$(section "## 2. Dispatch board")"
reply="$(section "### Answering each item at its source")"
finish="$(section "## 6. Finish")"

# ---- 1. intake records the source ----
has "intake records a Slack message's channel id and ts" "$intake" "channel id and message ts"
has "intake records a list row's list id and record id" "$intake" "list id and record id"
has "intake records an issue's number" "$intake" "issue number"

# ---- 2. the board has a Source column ----
check "the dispatch board has a Source column" \
  "$(grep -q -E '^\| # \| Item \| Source \|' <<< "$board" && echo ok || echo "no Source column in the board")"

# ---- 3. a Slack message item gets a draft thread reply, never sent ----
check "the skill holds the source reply section exactly once" \
  "$([ "$(grep -c -x -F '### Answering each item at its source' "$SKILL" 2>/dev/null)" = "1" ] && echo ok || echo "the section is missing or repeated")"
has "a Slack message item's reply is saved as a draft" "$reply" "slack_send_message_draft"
has "the draft goes in the message's thread" "$reply" "thread_ts"
has "the draft goes through /no-ai-tells first" "$reply" "/no-ai-tells"
has "the draft is never sent" "$reply" "Nothing is sent"
has "one draft per thread is allowed in one channel" "$reply" "one draft per thread"

# ---- 4. a Slack list row gets its Status moved instead of a reply ----
has "a list row gets no reply" "$reply" "gets no reply"
has "the reason a list row cannot take a draft is recorded" "$reply" "channel_not_found"
has "a list row's Status moves to In progress when its agent reports" "$reply" "In progress when its agent reports"
has "a list row's Status moves to Done once approved follow ons finish" "$reply" "Done once every follow on Dan approved is finished"
has "a list row's Status moves to Waiting when parked" "$reply" "Waiting when it is parked until a later date or event"
has "the Status is moved with the list record tool" "$reply" "slack_update_list_record"

# ---- 5. an issue is answered where it came from ----
has "an issue item is answered on the issue" "$reply" "comment on the issue"

# ---- 6. Finish lists every saved draft ----
has "Finish lists each saved draft with its link" "$finish" "each draft reply saved, with its link"
has "Finish lists each list row whose Status was moved" "$finish" "each list row whose Status moved"

# ---- 7. both halves are mandatory, with Dan's ruling and date ----
has "both halves are stated as mandatory" "$reply" "Both halves are mandatory"
has "the section carries Dan's ruling date" "$reply" "2026-11-04"

# ---- 8. the style rule: no em or en dash in the skill ----
# One -e per character, never a \| alternation, which basic regex grep honours on some systems only.
dashes="$(grep -n -e $'\xe2\x80\x94' -e $'\xe2\x80\x93' "$SKILL" 2>/dev/null)"
check "the orchestrate skill holds no em or en dash" "$([ -z "$dashes" ] && echo ok || echo "$dashes")"

# claude-config#2490: on 2026-11-09 a restart of the work MacBook emptied /private/tmp, taking a
# session's handoff note and a background agent's working tree with an uncommitted fix. Briefs give
# each agent a working folder in the session's notes folder and a worktree inside the repo, never
# anything under the temp folder, and the rules every agent reads say the same.
RULES="${ORCHESTRATE_RULES:-$DIR/agent-rules.md}"
has(){ grep -F -q -- "$2" "$1" && echo ok || echo "missing: $2"; }
check "#2490 a brief's working folder is under the notes folder" "$(has "$SKILL" '5. The working folder: `<notes folder>/')"
check "#2490 a brief's worktree is inside the repo, never the temp folder" "$(has "$SKILL" 'never under `/tmp`, `/private/tmp` or the scratchpad')"
check "#2490 the orchestrator's handoff note is in the notes folder" "$(has "$SKILL" '`handoff.md` at the root of this session'"'"'s notes folder')"
check "#2490 no brief part still names the scratchpad as the working folder" "$(grep -n 'The scratchpad folder:' "$SKILL" >/dev/null && echo 'still names the scratchpad folder' || echo ok)"
check "#2490 agents write working files in the notes folder" "$(has "$RULES" 'never in the scratchpad under `/private/tmp`')"
check "#2490 agents never put a worktree in the temp folder" "$(has "$RULES" 'Never put a worktree under `/tmp`')"

# claude-config#2563: the merge command written in the skill and in the global rules must carry
# every argument the helper's usage marks required, say it runs from inside a checkout, and say how
# the merge method is chosen. Required is read from the helper's own usage line: a token outside [].
HELPER="${MERGE_HELPER:-$DIR/../../hooks/lib/merge-when-ready.sh}"
GLOBAL_RULES="${GLOBAL_RULES_FILE:-$DIR/../../CLAUDE.md}"
usage_line="$(grep -m1 'echo "usage: ' "$HELPER")"
required="$(printf '%s' "$usage_line" | sed 's/.*\$SELF //; s/".*//; s/\[[^]]*\]//g')"
check "#2563 the helper's usage names a required argument" "$([ -n "${required// /}" ] && echo ok || echo "none parsed from: $usage_line")"
for f in "$SKILL" "$GLOBAL_RULES"; do
  cmd_line="$(grep -F 'merge-when-ready.sh' "$f" | head -1)"
  for tok in $required; do
    case "$tok" in
      "<pr>") want='merge-when-ready.sh <' ;;
      *) want="$tok" ;;
    esac
    check "#2563 $(basename "$(dirname "$f")")/$(basename "$f") command carries required $tok" "$(printf '%s' "$cmd_line" | grep -F -q -- "$want" && echo ok || echo "missing $want")"
  done
  check "#2563 $(basename "$f") says it runs from inside a checkout" "$(printf '%s' "$cmd_line" | grep -F -q 'inside a checkout' && echo ok || echo 'no checkout requirement')"
  check "#2563 $(basename "$f") names the merge method and how it is chosen" "$(printf '%s' "$cmd_line" | grep -F -q -- '--squash' && printf '%s' "$cmd_line" | grep -F -q 'its history uses' && echo ok || echo 'no merge method rule')"
done

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
