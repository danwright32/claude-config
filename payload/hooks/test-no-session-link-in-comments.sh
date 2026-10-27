#!/usr/bin/env bash
# Tests for no-session-link-in-comments.sh and session_link_comment_gate.py.
#
# The session link belongs on commits, pull request descriptions and issue bodies, never in a
# comment, review or reply addressed to people (Dan, 2026-10-27, after removing it by hand from a
# Pivot issue comment; 32 Pivot comments carried it). Each case feeds a PreToolUse payload on stdin
# and asserts whether the hook denied. No network and no gh.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/no-session-link-in-comments.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"
for b in bash mktemp cat tr printf; do
  src="$(command -v "$b" 2>/dev/null)"
  [ -n "$src" ] && ln -sf "$src" "$TMP_DIR/bin/$b"
done

LINK="Claude-Session: https://claude.ai/code/session_01AbCdEf"
printf 'Agreed.\n\n%s\n' "$LINK" >"$TMP_DIR/with-link.md"
printf 'Agreed.\n' >"$TMP_DIR/clean.md"

pass=0
fail=0

# bash_payload <command>: a Bash PreToolUse payload whose cwd is the temp directory.
bash_payload() {
  printf '%s' "$1" | CWD="$TMP_DIR" python3 -c '
import os, sys, json
json.dump({"tool_name": "Bash", "tool_input": {"command": sys.stdin.read()}, "cwd": os.environ["CWD"]}, sys.stdout)
'
}
# tool_payload <tool name> <text>: an MCP tool payload carrying the text as its message.
tool_payload() {
  printf '%s' "$2" | TOOL="$1" python3 -c '
import os, sys, json
json.dump({"tool_name": os.environ["TOOL"], "tool_input": {"channel_id": "C1", "message": sys.stdin.read()}}, sys.stdout)
'
}
check() { # check <deny|allow> <description> <payload>
  local out; out="$(printf '%s' "$3" | bash "$HOOK" 2>/dev/null)"
  if [ "$1" = deny ] && [[ "$out" == *'"deny"'* ]]; then pass=$((pass + 1))
  elif [ "$1" = allow ] && [[ "$out" != *'"deny"'* ]]; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "FAIL: $2 (expected $1, got: ${out:-<no output>})"; fi
}
denies() { check deny "$1" "$(bash_payload "$2")"; }
allows() { check allow "$1" "$(bash_payload "$2")"; }

# --- Comments, reviews and replies carrying the link are refused ---
denies "pr comment, inline body" "gh pr comment 5 --body \"Agreed.

$LINK\""
denies "issue comment, -b short flag" "gh issue comment 22 -b \"Agreed. $LINK\""
denies "issue comment, the bare url without the label" "gh issue comment 22 --body \"Agreed. https://claude.ai/code/session_01AbCdEf\""
denies "issue comment, heredoc in a substitution" "gh issue comment 22 --repo Try-Pennie/pivot --body \"\$(cat <<'EOF'
Agreed on all of it.

$LINK
EOF
)\""
denies "pr review comment" "gh pr review 50 --comment -b \"Looks right. $LINK\""
denies "issue comment, --body-file holding the link" "gh issue comment 22 --body-file with-link.md"
denies "pr comment, -F after a cd" "cd $TMP_DIR && gh pr comment 5 -F with-link.md"
denies "issue comment, body on stdin from a heredoc" "gh issue comment 22 -F - <<'EOF'
Agreed.

$LINK
EOF"
denies "review comment reply through gh api" "gh api repos/Try-Pennie/pivot/pulls/50/comments/123/replies -f body=\"Fixed. $LINK\""
denies "issue comment through gh api" "gh api -X POST repos/Try-Pennie/pivot/issues/22/comments -f body='Done. $LINK'"
denies "issue close with a closing comment" "gh issue close 14 --reason completed --comment \"Done. $LINK\""
denies "pr close with -c" "gh pr close 76 -c \"Not merging. $LINK\""
allows "issue close with a clean comment" "gh issue close 14 --comment \"Done.\""
denies "a command nobody can tokenize, posting the link" "gh pr comment 5 --body \"Agreed $LINK"
allows "a command nobody can tokenize, posting a clean comment" "gh pr comment 5 --body \"Agreed"
denies "gh api link in a heredoc body after the last argument" "gh api repos/a/b/issues/1/comments -F body=@- <<'EOF'
$LINK
EOF"
denies "comment chained after a commit" "git add a.ts && gh pr comment 5 --body \"Pushed. $LINK\""

# --- Everything that is allowed to carry it, and comments without it ---
allows "pr comment without the link" "gh pr comment 5 --body \"Agreed.\""
allows "issue comment from a clean body file" "gh issue comment 22 --body-file clean.md"
allows "issue create keeps the link" "gh issue create --title T --milestone Ungrouped --label bug,priority-p2 --body \"x

$LINK\""
allows "pr create keeps the link" "gh pr create --title T --body \"x

$LINK\""
allows "pr edit keeps the link" "gh pr edit 5 --body \"x $LINK\""
allows "commit keeps the link" "git commit -m \"Fix thing

$LINK\""
allows "pr create with the link, then a clean comment" "gh pr create --title T --body \"x $LINK\" && gh pr comment 5 --body \"Opened.\""
allows "a review comment reply without the link" "gh api repos/a/b/pulls/1/comments/2/replies -f body=\"Fixed.\""
allows "reading comments through gh api" "gh api repos/a/b/issues/22/comments --jq '.[] | select(.body | test(\"claude.ai/code/session\"))'"
allows "the override, for that one command" "ALLOW_SESSION_LINK_IN_COMMENT=1 gh pr comment 5 --body \"$LINK\""
allows "not a gh command" "echo \"$LINK\""

# --- Slack ---
check deny "slack message with the link" "$(tool_payload mcp__plugin_slack_slack__slack_send_message "Shipped. $LINK")"
check deny "slack draft with the link" "$(tool_payload mcp__plugin_slack_slack__slack_send_message_draft "Shipped. $LINK")"
check deny "scheduled slack message with the link" "$(tool_payload mcp__plugin_slack_slack__slack_schedule_message "Shipped. $LINK")"
check allow "slack message without the link" "$(tool_payload mcp__plugin_slack_slack__slack_send_message "Shipped.")"
check allow "slack read tool mentioning the link" "$(tool_payload mcp__plugin_slack_slack__slack_search_public "$LINK")"

# --- The refusal says what to do ---
out="$(bash_payload "gh pr comment 5 --body \"Agreed. $LINK\"" | bash "$HOOK" 2>/dev/null)"
for needle in "Remove" "commits" "ALLOW_SESSION_LINK_IN_COMMENT=1"; do
  if [[ "$out" == *"$needle"* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: the refusal should say '$needle' (got: $out)"; fi
done

# --- A gate that cannot run says so on stderr and lets the command through ---
err="$(bash_payload "gh pr comment 5 --body \"$LINK\"" | PATH="$TMP_DIR/bin" bash "$HOOK" 2>&1 >/dev/null)"
if [[ "$err" == *"SESSION LINK GATE DID NOT RUN"* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a broken gate must say so on stderr (got: ${err:-<nothing>})"; fi

err="$(printf 'gh not json' | bash "$HOOK" 2>&1 >/dev/null)"
if [[ "$err" == *"SESSION LINK GATE DID NOT RUN"* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a payload that is not JSON must say the gate did not run (got: ${err:-<nothing>})"; fi

# --- Wired: the installed settings route Bash and the Slack send tools to the hook ---
if python3 - "$DIR/../settings.hooks.json" <<'PY'
import json, re, sys
pre = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
want = {"Bash": False, "mcp__plugin_slack_slack__slack_send_message": False,
        "mcp__plugin_slack_slack__slack_send_message_draft": False,
        "mcp__plugin_slack_slack__slack_schedule_message": False}
for entry in pre:
    if any(h.get("command", "").endswith("/no-session-link-in-comments.sh") for h in entry.get("hooks", [])):
        for tool in want:
            if re.fullmatch(entry.get("matcher", ""), tool):
                want[tool] = True
sys.exit(0 if all(want.values()) else 1)
PY
then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: settings.hooks.json must route Bash and the three Slack send tools to the hook"; fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
