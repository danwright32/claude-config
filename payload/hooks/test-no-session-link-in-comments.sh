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

# A home folder shaped like the one on Dan's Macs, an account name holding "gh" inside a word
# ("wright"). It is assembled from pieces so this file names no real machine's home
# (check-home-paths.sh). HOME_CWD is a copy of it under the temp directory with the same body files
# beside it, so relative paths resolve from it too (claude-config#1880).
FAKE_HOME="/Users""/dana-wright"
HOME_CWD="$TMP_DIR/home-like/dana-wright/Apps/claude-config"
mkdir -p "$HOME_CWD"
cp "$TMP_DIR/with-link.md" "$TMP_DIR/clean.md" "$HOME_CWD/"

# Which payload bash_payload builds: PAYLOAD_CWD is its cwd, and PAYLOAD_SHAPE is "short" (three
# fields) or "claude" (every field Claude Code sends, in its order, compact as JSON.stringify writes
# it, with a transcript path and a description that hold "gh" inside words).
PAYLOAD_CWD="$TMP_DIR"
PAYLOAD_SHAPE=short

# bash_payload <command>: a Bash PreToolUse payload carrying the command.
bash_payload() {
  printf '%s' "$1" | CWD="$PAYLOAD_CWD" SHAPE="$PAYLOAD_SHAPE" FAKE_HOME="$FAKE_HOME" python3 -c '
import os, sys, json
cmd = sys.stdin.read()
if os.environ["SHAPE"] == "claude":
    sid = "5e551011-0000-4000-8000-0000000000aa"
    home = os.environ["FAKE_HOME"]
    json.dump({"session_id": sid,
               "transcript_path": home + "/.claude/projects/" + home.replace("/", "-") + "-Apps-claude-config/" + sid + ".jsonl",
               "cwd": os.environ["CWD"], "permission_mode": "auto", "hook_event_name": "PreToolUse",
               "tool_name": "Bash", "tool_input": {"command": cmd, "description": "Run it right through"},
               "tool_use_id": "toolu_01ABC"}, sys.stdout, separators=(",", ":"), ensure_ascii=False)
else:
    json.dump({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": os.environ["CWD"]}, sys.stdout)
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
  else fail=$((fail + 1)); echo "FAIL: $2 [$PAYLOAD_SHAPE payload, cwd $PAYLOAD_CWD] (expected $1, got: ${out:-<no output>})"; fi
}
denies() { check deny "$1" "$(bash_payload "$2")"; }
allows() { check allow "$1" "$(bash_payload "$2")"; }

# Every Bash case, run once per payload shape and cwd at the bottom of this list.
run_bash_cases() {
# --- Comments, reviews and replies carrying the link are refused ---
denies "pr comment, inline body" "gh pr comment 5 --body \"Agreed.

$LINK\""
denies "issue comment, -b short flag" "gh issue comment 22 -b \"Agreed. $LINK\""
denies "issue comment, the bare url without the label" "gh issue comment 22 --body \"Agreed. https://claude.ai/code/session_01AbCdEf\""
denies "issue comment, heredoc in a substitution" "gh issue comment 22 --repo acme/widgets --body \"\$(cat <<'EOF'
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
denies "review comment reply through gh api" "gh api repos/acme/widgets/pulls/50/comments/123/replies -f body=\"Fixed. $LINK\""
denies "issue comment through gh api" "gh api -X POST repos/acme/widgets/issues/22/comments -f body='Done. $LINK'"
denies "issue close with a closing comment" "gh issue close 14 --reason completed --comment \"Done. $LINK\""
denies "pr close with -c" "gh pr close 76 -c \"Not merging. $LINK\""
allows "issue close with a clean comment" "gh issue close 14 --comment \"Done.\""
denies "a command nobody can tokenize, posting the link" "gh pr comment 5 --body \"Agreed $LINK"
allows "a command nobody can tokenize, posting a clean comment" "gh pr comment 5 --body \"Agreed"
denies "gh api link in a heredoc body after the last argument" "gh api repos/a/b/issues/1/comments -F body=@- <<'EOF'
$LINK
EOF"
denies "gh api body read from a file with @, relative to the payload's directory" "gh api repos/a/b/issues/1/comments -F body=@with-link.md"
printf '{"body": "Done. %s"}' "$LINK" >"$TMP_DIR/with-link.json"
denies "gh api body from --input" "gh api -X POST repos/a/b/issues/1/comments --input $TMP_DIR/with-link.json"
allows "gh api body from a clean file" "gh api repos/a/b/issues/1/comments -F body=@$TMP_DIR/clean.md"
denies "gh api with a flag in front of the subcommand" "gh -R acme/widgets api repos/acme/widgets/issues/22/comments -f body=\"Done. $LINK\""
denies "gh api run through rtk" "rtk gh api repos/acme/widgets/issues/22/comments -f body=\"Done. $LINK\""
allows "gh api with the override, for that one command" "ALLOW_SESSION_LINK_IN_COMMENT=1 gh api repos/acme/widgets/issues/22/comments -f body=\"Done. $LINK\""
denies "comment chained after a commit" "git add a.ts && gh pr comment 5 --body \"Pushed. $LINK\""

# gh wherever a shell can start it. In the JSON payload a newline or tab before gh is written as
# \n or \t, so the letter in front of gh there is n or t: a quick exit reading the payload text must
# still see a command starting there (claude-config#1880).
denies "gh after a newline" "true
gh pr comment 5 --body \"x $LINK\""
denies "gh after a tab" "true;	gh pr comment 5 --body \"x $LINK\""
denies "gh after a backslash newline" "true \\
&& gh pr comment 5 --body \"x $LINK\""
denies "gh after a semicolon with no space" "true;gh pr comment 5 --body \"x $LINK\""
denies "gh inside bash -c" "bash -c 'gh pr comment 5 --body \"x $LINK\"'"
denies "gh inside sh -c in double quotes" "sh -c \"gh pr comment 5 --body 'x $LINK'\""
denies "gh behind env" "env FOO=1 gh pr comment 5 --body \"x $LINK\""
denies "gh in a subshell" "(gh pr comment 5 --body \"x $LINK\")"
denies "gh api behind rtk after a cd" "cd /tmp && rtk gh api repos/a/b/issues/1/comments -f body=\"x $LINK\""
denies "gh by its full path" "/opt/homebrew/bin/gh pr comment 5 --body \"x $LINK\""
denies "gh behind command" "command gh pr comment 5 --body \"x $LINK\""
denies "gh behind time" "time gh pr comment 5 --body \"x $LINK\""
denies "gh reading a piped body" "echo \"x $LINK\" | gh pr comment 5 -F -"

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
}

# The short payload from a temp directory, then Claude Code's whole payload from a home folder whose
# name holds "gh" inside a word.
PAYLOAD_CWD="$TMP_DIR"; PAYLOAD_SHAPE=short
run_bash_cases
PAYLOAD_CWD="$HOME_CWD"; PAYLOAD_SHAPE=claude
run_bash_cases
PAYLOAD_CWD="$TMP_DIR"; PAYLOAD_SHAPE=short

# --- A command that cannot post skips the Python start, whatever the cwd (claude-config#1880) ---
# A python3 on PATH that records each start and then runs the real one.
REAL_PY="$(command -v python3)"
mkdir -p "$TMP_DIR/stub"
printf '#!/bin/sh\necho started >>"%s"\nexec "%s" "$@"\n' "$TMP_DIR/python-starts" "$REAL_PY" >"$TMP_DIR/stub/python3"
chmod +x "$TMP_DIR/stub/python3"
# python_starts <payload>: how many times the hook started python3 on this payload.
python_starts() {
  rm -f "$TMP_DIR/python-starts"
  printf '%s' "$1" | PATH="$TMP_DIR/stub:$PATH" bash "$HOOK" >/dev/null 2>&1
  if [ -f "$TMP_DIR/python-starts" ]; then wc -l <"$TMP_DIR/python-starts" | tr -d ' '; else echo 0; fi
}
skips() { # skips <description> <command> <cwd>
  local p n; PAYLOAD_CWD="$3"; PAYLOAD_SHAPE=claude; p="$(bash_payload "$2")"; PAYLOAD_CWD="$TMP_DIR"; PAYLOAD_SHAPE=short
  n="$(python_starts "$p")"
  if [ "$n" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 should skip the Python start (started $n times)"; fi
}
skips "ls from a home folder holding gh inside a word" "ls" "$FAKE_HOME"
skips "ls of a path holding gh inside a word" "ls $FAKE_HOME/Apps" "$FAKE_HOME"
skips "words holding gh, in the command" "echo high through the night" "$FAKE_HOME"
skips "git push from a home folder" "git push -u origin HEAD" "$FAKE_HOME/Apps/claude-config"
# The stub is seen to count: a comment from the same home folder starts python3 once.
PAYLOAD_CWD="$FAKE_HOME"; PAYLOAD_SHAPE=claude
p="$(bash_payload "gh pr comment 5 --body \"Agreed. $LINK\"")"
PAYLOAD_CWD="$TMP_DIR"; PAYLOAD_SHAPE=short
n="$(python_starts "$p")"
if [ "$n" = 1 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: a gh comment from a home folder should start python3 once (started $n times)"; fi
# A control character in front of gh is written \u001f in the JSON, so a digit sits in front of gh
# there; the gate's own word test sees a boundary, so the quick exit must hand it over.
PAYLOAD_CWD="$FAKE_HOME"; PAYLOAD_SHAPE=claude
p="$(bash_payload "true"$'\x1f'"gh pr comment 5")"
PAYLOAD_CWD="$TMP_DIR"; PAYLOAD_SHAPE=short
n="$(python_starts "$p")"
if [[ "$p" == *'\u001fgh'* && "$n" = 1 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: gh after a control character escaped as \\u001f should start python3 once (started $n times, payload $p)"; fi
# A Slack send carries no command at all, and still reaches the gate.
n="$(python_starts "$(tool_payload mcp__plugin_slack_slack__slack_send_message "Shipped. $LINK")")"
if [ "$n" = 1 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: a Slack send should start python3 once (started $n times)"; fi
# A payload byte that is not valid UTF-8 must not make the quick exit's match fail and skip the gate.
# Under a UTF-8 locale bash's =~ stops matching at such a byte, so the hook runs under one here, with
# the byte in front of gh.
UTF8_LOCALE="$(locale -a 2>/dev/null | grep -i -m1 -E '^(en_US|C)\.utf-?8$')"
p="$(bash_payload "true && gh pr comment 5 --body \"Agreed. $LINK\"")"
p="${p/true/$'\xff'}"
out="$(printf '%s' "$p" | LC_ALL="${UTF8_LOCALE:-C}" bash "$HOOK" 2>&1)"
if [[ "$out" == *'"deny"'* || "$out" == *"SESSION LINK GATE DID NOT RUN"* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a payload with a byte that is not UTF-8 must reach the gate (got: ${out:-<no output>})"; fi

# --- Slack ---
# Every Slack tool that writes text a teammate reads is named once, in lib/slack-write-tools.txt,
# which this gate and the style-check mod both read. Each is tried here under both servers that
# carry it: the Slack plugin's and the claude.ai connector's. The claude.ai connector spells its
# server Slack with a capital S, and Claude Code matches a hook matcher case sensitively (measured
# 2026-10-29, claude-config#1905), so a pattern wanting a lowercase "slack" in the server name never
# saw a claude.ai send. The gate below and the settings check at the end are both held to this list.
SLACK_LIST="$DIR/lib/slack-write-tools.txt"
SLACK_NAMES=()
if [ -r "$SLACK_LIST" ]; then
  while IFS= read -r name; do
    case "$name" in ''|'#'*) ;; *) SLACK_NAMES+=("$name") ;; esac
  done <"$SLACK_LIST"
fi
# The list may grow, never lose these: the sends, and the canvases and lists teammates read.
for name in slack_send_message slack_send_message_draft slack_schedule_message slack_create_canvas \
            slack_update_canvas slack_add_list_record slack_update_list_record; do
  if [[ " ${SLACK_NAMES[*]-} " == *" $name "* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $SLACK_LIST must name $name (it names: ${SLACK_NAMES[*]:-nothing, or it is missing})"; fi
done
SLACK_SEND_TOOLS=()
for name in ${SLACK_NAMES[@]+"${SLACK_NAMES[@]}"}; do
  SLACK_SEND_TOOLS+=("mcp__plugin_slack_slack__$name" "mcp__claude_ai_Slack__$name")
done
# Slack tools that only read, which the gate and the settings leave alone.
SLACK_READ_TOOLS=(
  mcp__plugin_slack_slack__slack_search_public
  mcp__claude_ai_Slack__slack_search_public
  mcp__claude_ai_Slack__slack_read_channel
  mcp__claude_ai_Slack__slack_read_canvas
)
for tool in ${SLACK_SEND_TOOLS[@]+"${SLACK_SEND_TOOLS[@]}"}; do
  check deny "$tool with the link" "$(tool_payload "$tool" "Shipped. $LINK")"
  check allow "$tool without the link" "$(tool_payload "$tool" "Shipped.")"
done
for tool in "${SLACK_READ_TOOLS[@]}"; do
  check allow "$tool mentioning the link" "$(tool_payload "$tool" "$LINK")"
done

# --- The refusal says what to do ---
out="$(bash_payload "gh pr comment 5 --body \"Agreed. $LINK\"" | bash "$HOOK" 2>/dev/null)"
for needle in "Remove" "commits" "ALLOW_SESSION_LINK_IN_COMMENT=1"; do
  if [[ "$out" == *"$needle"* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: the refusal should say '$needle' (got: $out)"; fi
done

out="$(tool_payload mcp__plugin_slack_slack__slack_send_message "Shipped. $LINK" | bash "$HOOK" 2>/dev/null)"
if [[ "$out" == *"Remove"* && "$out" != *"ALLOW_SESSION_LINK_IN_COMMENT"* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a Slack refusal offers no command override (got: $out)"; fi
# The refusal names what was about to be written, so a canvas is not called a message.
for pair in "slack_send_message:Slack message" "slack_create_canvas:Slack canvas" "slack_update_list_record:Slack list"; do
  out="$(tool_payload "mcp__claude_ai_Slack__${pair%%:*}" "Shipped. $LINK" | bash "$HOOK" 2>/dev/null)"
  if [[ "$out" == *"link in a ${pair#*:}."* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: the ${pair%%:*} refusal should say 'in a ${pair#*:}' (got: ${out:-<no output>})"; fi
done

# --- A gate that cannot run says so on stderr and lets the command through ---
err="$(bash_payload "gh pr comment 5 --body \"$LINK\"" | PATH="$TMP_DIR/bin" bash "$HOOK" 2>&1 >/dev/null)"
if [[ "$err" == *"SESSION LINK GATE DID NOT RUN"* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a broken gate must say so on stderr (got: ${err:-<nothing>})"; fi

err="$(printf 'gh not json' | bash "$HOOK" 2>&1 >/dev/null)"
if [[ "$err" == *"SESSION LINK GATE DID NOT RUN"* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a payload that is not JSON must say the gate did not run (got: ${err:-<nothing>})"; fi

# The gate installed without its Slack list: a Slack write says the gate did not run, never passes
# as judged, and a gh comment is still judged, since only an MCP tool reads the list.
mkdir -p "$TMP_DIR/nolist/lib"
cp "$HOOK" "$DIR/session_link_comment_gate.py" "$DIR/gh_issue_scan.py" "$TMP_DIR/nolist/"
cp "$DIR/lib/shell-words.py" "$TMP_DIR/nolist/lib/"
err="$(tool_payload mcp__claude_ai_Slack__slack_send_message "Shipped. $LINK" | bash "$TMP_DIR/nolist/no-session-link-in-comments.sh" 2>&1 >/dev/null)"
if [[ "$err" == *"SESSION LINK GATE DID NOT RUN"* && "$err" == *"slack-write-tools.txt"* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a Slack write with no Slack list must say the gate did not run, naming the list (got: ${err:-<nothing>})"; fi
out="$(bash_payload "gh pr comment 5 --body \"Agreed. $LINK\"" | bash "$TMP_DIR/nolist/no-session-link-in-comments.sh" 2>/dev/null)"
if [[ "$out" == *'"deny"'* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a gh comment must still be judged when the Slack list is missing (got: ${out:-<no output>})"; fi

# --- Wired: the installed settings route Bash and every Slack send tool to the hook ---
# The matcher is read the way Claude Code reads it, measured 2026-10-29 with a headless session
# logging which matchers fired (claude-config#1905): a matcher holding any character beyond letters,
# digits, _, -, spaces, commas and | is a regular expression tested ANYWHERE in the tool name
# ("ea[d]" fired on Read), and case sensitively ("rea[d]" did not fire on Read, "Rea[d]" did; a
# lowercase "slack" server pattern did not fire on mcp__claude_ai_Slack__slack_search_channels). A
# plain matcher is an exact name, or a list of names split on | or commas.
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")" || SETTINGS="$DIR/../no-settings-file-found"
wired="$(python3 - "$SETTINGS" Bash ${SLACK_SEND_TOOLS[@]+"${SLACK_SEND_TOOLS[@]}"} -- "${SLACK_READ_TOOLS[@]}" <<'PY'
import json, re, sys
args = sys.argv[2:]
sep = args.index("--")
routed, unrouted = args[:sep], args[sep + 1:]
pre = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
def fires(matcher, tool):
    if matcher in ("", "*"):
        return True
    if re.fullmatch(r"[A-Za-z0-9_\- ,|]+", matcher):
        return tool in [m.strip() for m in re.split(r"[|,]", matcher)]
    return re.search(matcher, tool) is not None
matchers = [entry.get("matcher", "") for entry in pre
            if any(h.get("command", "").endswith("/no-session-link-in-comments.sh") for h in entry.get("hooks", []))]
for tool in routed:
    if not any(fires(m, tool) for m in matchers):
        print("not routed to the hook: %s (matchers: %s)" % (tool, matchers))
for tool in unrouted:
    if any(fires(m, tool) for m in matchers):
        print("a read tool routed to the hook: %s (matchers: %s)" % (tool, matchers))
PY
)"
if [ $? -eq 0 ] && [ -z "$wired" ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: $SETTINGS must route Bash and every Slack send tool to the hook, and no read tool: ${wired:-the check did not run}"; fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
