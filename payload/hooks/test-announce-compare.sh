#!/usr/bin/env bash
# Suite for lib/announce-compare.js's judgement of a Slack draft of an announcement for agents
# (claude-config#3667), for its claimed wording check (only wording whose hash the pull request
# claimed in the record of approvals is drafted), and for the one rule the drafting rests on: an announcement is only ever
# saved as a draft, which slack-drafts-only-gate.sh holds and this suite only confirms.
#
# Named test-*.sh so run-all-tests.sh discovers it from disk. The judgement's cases are in
# lib/announce-compare.test.js, which prints the machine readable result line this wrapper adds its
# own counts to. Nothing here calls Slack: the gate is handed a hook payload on standard input, as
# test-slack-drafts-only-gate-scripts.sh hands it one, and answers by its exit code.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0
fail=0
check() { if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not on PATH, so the judgement of a draft cannot be tested."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# ---- the judgement ----
out="$(node "$DIR/lib/announce-compare.test.js" 2>&1)"
rc=$?
printf '%s\n' "$out" | grep -v '^SUITE-RESULT '
# The tally comes from the test file's own counters. A run that died before printing it (a syntax
# error, a crash) has no tally, and that is a failure, never a pass with nothing counted (L98).
tally="$(printf '%s\n' "$out" | grep '^SUITE-RESULT ' | tail -n 1)"
if [ -z "$tally" ]; then
  check "lib/announce-compare.test.js prints its tally" "it exited $rc without one"
else
  lib_passed="${tally#*passed=}"; lib_passed="${lib_passed%% *}"
  lib_failed="${tally#*failed=}"; lib_failed="${lib_failed%% *}"
  case "$lib_passed$lib_failed" in
    *[!0-9]*|'') check "lib/announce-compare.test.js prints a tally of numbers" "it printed: $tally" ;;
    *) pass=$((pass + lib_passed)); fail=$((fail + lib_failed))
       if [ "$lib_passed" -eq 0 ]; then check "lib/announce-compare.test.js ran its cases" "it counted none"; fi ;;
  esac
fi

# ---- R3: an announcement is only ever saved as a draft, never sent or scheduled ----
# The holder is the drafts only gate, unchanged by #3667. Asked here with the very call the is it
# live mod tells a session to make for an announcement (the channel, no thread, the whole post), and
# the control first: the draft goes through, so a refusal below is the tool doing it (L159).
T="$(mktemp -d "${TMPDIR:-/tmp}/announce-compare.XXXXXXXX")" || T=""
if [ -z "$T" ] || [ ! -d "$T" ]; then
  check "a scratch folder for the gate's judgement cache" "it could not be made"
else
  trap 'rm -rf "$T"' EXIT
  export SLACK_GATE_CACHE_DIR="$T/gate-cache"
  HOOK="$DIR/slack-drafts-only-gate.sh"
  payload() { # payload <tool name> <tool input as JSON>
    python3 -c '
import json, sys
print(json.dumps({"session_id": "f6017250-8f33-47ac-bbb2-b82a7c319d0d", "transcript_path": "/tmp/transcript.jsonl",
                  "cwd": sys.argv[3], "permission_mode": "auto", "hook_event_name": "PreToolUse",
                  "tool_name": sys.argv[1], "tool_input": json.loads(sys.argv[2]), "tool_use_id": "toolu_01X4Qw7JnfYswF7UVX94Z4Sy"}))
' "$1" "$2" "$T"
  }
  POST_INPUT='{"channel_id": "C0123456789", "message": "@here\n**Handing a call back**\n\nYou can now hand a call back to the queue.\n\n- Press Hand back\n- Pick a reason"}'
  WHEN_INPUT='{"channel_id": "C0123456789", "message": "@here\n**Handing a call back**\n\nYou can now hand a call back to the queue.", "post_at": 1730000000}'
  RC=0; ERR=""
  run_tool() { ERR="$(payload "$1" "$2" | bash "$HOOK" 2>&1 >/dev/null)"; RC=$?; }

  for tool in mcp__plugin_slack_slack__slack_send_message_draft mcp__claude_ai_Slack__slack_send_message_draft; do
    run_tool "$tool" "$POST_INPUT"
    if [ "$RC" -eq 0 ]; then check "R3 control: $tool, the draft of an announcement, goes through" ok
    else check "R3 control: $tool, the draft of an announcement, goes through" "exit $RC: ${ERR:0:300}"; fi
  done
  for tool in mcp__plugin_slack_slack__slack_send_message mcp__claude_ai_Slack__slack_send_message; do
    run_tool "$tool" "$POST_INPUT"
    if [ "$RC" -eq 2 ]; then check "R3: $tool, a send of an announcement, is refused" ok
    else check "R3: $tool, a send of an announcement, is refused" "exit $RC: ${ERR:0:300}"; fi
    case "$ERR" in *slack_send_message_draft*C0123456789*|*C0123456789*slack_send_message_draft*) check "R3: the refusal of $tool names the draft tool and the channel" ok ;;
      *) check "R3: the refusal of $tool names the draft tool and the channel" "it said: ${ERR:0:300}" ;; esac
  done
  for tool in mcp__plugin_slack_slack__slack_schedule_message mcp__claude_ai_Slack__slack_schedule_message; do
    run_tool "$tool" "$WHEN_INPUT"
    if [ "$RC" -eq 2 ]; then check "R3: $tool, a schedule of an announcement, is refused" ok
    else check "R3: $tool, a schedule of an announcement, is refused" "exit $RC: ${ERR:0:300}"; fi
  done
fi

echo "  $pass passed, $fail failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
