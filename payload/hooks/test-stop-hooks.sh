#!/usr/bin/env bash
# Tests for the Stop hooks' "did this turn change anything" gating.
# session-reflection.sh and feature-issue-review.sh must both:
#   - stay SILENT on chat-only turns
#   - stay SILENT on read-only turns (Read/Grep/WebFetch only)
#   - FIRE on turns that used a mutating tool (Edit/Write/Bash/Agent/...)
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFLECT="$DIR/session-reflection.sh"
REVIEW="$DIR/feature-issue-review.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

make_transcript() {
  # $1 = path, $2 = tool name to use in the assistant turn ("" = chat only)
  local path="$1" tool="${2:-}"
  {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"do the thing"}}'
    if [ -n "$tool" ]; then
      printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"%s","id":"t1","input":{}}]}}\n' "$tool"
      printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
    fi
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}'
  } > "$path"
}

pass=0
fail=0

run_hook() {
  # $1 = hook script, $2 = transcript path; unique project dir defeats the
  # issue-review cooldown stamp between cases.
  local hook="$1" transcript="$2"
  printf '{"transcript_path":"%s","stop_hook_active":false}' "$transcript" | \
    CLAUDE_PROJECT_DIR="$(mktemp -d "$WORK/proj.XXXXXX")" bash "$hook"
}

expect_silent() {
  local label="$1" hook="$2" transcript="$3" out
  out="$(run_hook "$hook" "$transcript")"
  if [ -z "$out" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $label should be silent, got output"; fi
}

expect_fires() {
  local label="$1" hook="$2" transcript="$3" out
  out="$(run_hook "$hook" "$transcript")"
  if printf '%s' "$out" | grep -q '"decision"'; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $label should fire, got nothing"; fi
}

t_chat="$WORK/chat.jsonl";  make_transcript "$t_chat" ""
t_read="$WORK/read.jsonl";  make_transcript "$t_read" "Read"
t_grep="$WORK/grep.jsonl";  make_transcript "$t_grep" "Grep"
t_edit="$WORK/edit.jsonl";  make_transcript "$t_edit" "Edit"
t_bash="$WORK/bash.jsonl";  make_transcript "$t_bash" "Bash"
t_agent="$WORK/agent.jsonl"; make_transcript "$t_agent" "Agent"
t_slack_send="$WORK/slack-send.jsonl"; make_transcript "$t_slack_send" "mcp__claude_ai_Slack__slack_send_message"
t_slack_read="$WORK/slack-read.jsonl"; make_transcript "$t_slack_read" "mcp__claude_ai_Slack__slack_read_thread"
t_click="$WORK/click.jsonl";  make_transcript "$t_click" "mcp__playwright__browser_click"
t_snap="$WORK/snap.jsonl";    make_transcript "$t_snap" "mcp__playwright__browser_snapshot"
t_dblist="$WORK/dblist.jsonl"; make_transcript "$t_dblist" "mcp__supabase__list_tables"
t_dbmig="$WORK/dbmig.jsonl";  make_transcript "$t_dbmig" "mcp__supabase__apply_migration"

expect_silent "reflection/chat-only"  "$REFLECT" "$t_chat"
expect_silent "reflection/read-only"  "$REFLECT" "$t_read"
expect_silent "reflection/grep-only"  "$REFLECT" "$t_grep"
expect_fires  "reflection/edit"       "$REFLECT" "$t_edit"
expect_fires  "reflection/bash"       "$REFLECT" "$t_bash"
expect_fires  "reflection/agent"      "$REFLECT" "$t_agent"

# Connected apps: writes/sends/clicks are work, reads/snapshots/lists are not.
expect_fires  "reflection/mcp-slack-send"  "$REFLECT" "$t_slack_send"
expect_silent "reflection/mcp-slack-read"  "$REFLECT" "$t_slack_read"
expect_fires  "reflection/mcp-browser-click" "$REFLECT" "$t_click"
expect_silent "reflection/mcp-browser-snapshot" "$REFLECT" "$t_snap"
expect_silent "reflection/mcp-db-list"     "$REFLECT" "$t_dblist"
expect_fires  "reflection/mcp-db-migrate"  "$REFLECT" "$t_dbmig"

expect_silent "issue-review/chat-only" "$REVIEW" "$t_chat"
expect_silent "issue-review/read-only" "$REVIEW" "$t_read"
expect_fires  "issue-review/edit"      "$REVIEW" "$t_edit"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
