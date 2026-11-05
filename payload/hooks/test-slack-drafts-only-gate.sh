#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans settings.hooks.json
# Tests for slack-drafts-only-gate.sh and its rule, slack_drafts_only_gate.py: the gate that leaves
# sessions only able to save Slack drafts (claude-config#2302).
#
# On 2026-11-05 two sessions on the work MacBook each posted a Slack reply after Dan picked a "Post"
# option in a picker, and he did not know either had gone out; one had reworded the text after he
# chose. Dan: "it should only ever save as draft in slack, never send directly." The written rule
# alone did not stop it, and a rule that lives only in a prompt is a hope (L27).
#
# The payloads are in the PreToolUse shape the Playwright gate's suite measured on Claude Code
# 2.1.274 (session_id, transcript_path, cwd, permission_mode, hook_event_name, tool_name,
# tool_input, tool_use_id). The Slack tool names are the ones the two integrations list today: the
# Slack plugin's mcp__plugin_slack_slack__* and the claude.ai connector's mcp__claude_ai_Slack__*.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/slack-drafts-only-gate.sh"
NUDGE="$(cd "$DIR/.." && pwd)/skills/nudge/nudge.py"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "FAIL: there is no slack-drafts-only-gate.sh beside this suite at $DIR, so no Slack send is refused."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/slack-gate.XXXXXXXX")" || exit 1
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$T'" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT

# payload <tool name> <tool_input JSON> [cwd]: one PreToolUse payload in the measured shape.
payload() {
  python3 -c '
import json, sys
tool, inp, cwd = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
print(json.dumps({"session_id": "f6017250-8f33-47ac-bbb2-b82a7c319d0d",
                  "transcript_path": "/tmp/transcript.jsonl", "cwd": cwd,
                  "permission_mode": "auto", "hook_event_name": "PreToolUse", "tool_name": tool,
                  "tool_input": inp, "tool_use_id": "toolu_01X4Qw7JnfYswF7UVX94Z4Sy"}))
' "$1" "$2" "${3:-$T}"
}
bash_input() { python3 -c 'import json, sys; print(json.dumps({"command": sys.argv[1], "description": "d"}))' "$1"; }

RC=0; OUT=""; ERR=""
run_raw() { # run_raw <stdin text>
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  OUT="$(printf '%s' "$1" | bash "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
run_tool() { run_raw "$(payload "$1" "$2")"; }
run_bash() { run_raw "$(payload Bash "$(bash_input "$1")")"; }

refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:400}" ;; esac; }

SEND_INPUT='{"channel_id": "C0TEST1", "thread_ts": "1730000000.000100", "message": "hello"}'

echo "slack drafts only: the draft tool and reading Slack still work"

# The control FIRST: the draft, with the same input the sends below carry, goes through, so a
# refusal below is the tool name doing it and not a gate that refuses every Slack call (L159).
run_tool mcp__plugin_slack_slack__slack_send_message_draft "$SEND_INPUT"
allowed "the Slack plugin's draft tool"
run_tool mcp__claude_ai_Slack__slack_send_message_draft "$SEND_INPUT"
allowed "the claude.ai connector's draft tool"
run_tool mcp__claude_ai_Slack__slack_read_channel '{"channel_id": "C0TEST1"}'
allowed "reading a channel"
run_tool mcp__plugin_slack_slack__slack_search_public '{"query": "chat.postMessage"}'
allowed "a search whose text names the endpoint"

echo "slack drafts only: every send and schedule tool is refused"

for tool in mcp__plugin_slack_slack__slack_send_message mcp__plugin_slack_slack__slack_schedule_message \
            mcp__claude_ai_Slack__slack_send_message mcp__claude_ai_Slack__slack_schedule_message \
            mcp__some_future_connector__slack_send_message mcp__Another_Slack__slack_schedule_message; do
  run_tool "$tool" "$SEND_INPUT"
  refused "$tool is refused"
  says "the refusal for $tool names the tool" "$tool"
done

run_tool mcp__claude_ai_Slack__slack_send_message "$SEND_INPUT"
says "the refusal names the draft tool" "slack_send_message_draft"
says "and the same channel" "C0TEST1"
says "and the same thread" "1730000000.000100"
says "and to tell Dan where the draft is" "tell Dan where the draft is"
run_tool mcp__plugin_slack_slack__slack_schedule_message '{"channel_id": "C0TEST2", "message": "x", "post_at": 1730000000}'
says "a schedule without a thread names its channel" "C0TEST2"

echo "slack drafts only: a command that posts is refused"

posts=(
  "curl -X POST https://slack.com/api/chat.postMessage -H 'Authorization: Bearer x' -d channel=C1 -d text=hi"
  "curl -s https://slack.com/api/chat.scheduleMessage -d post_at=1730000000"
  "wget --post-data='{\"text\":\"hi\"}' https://hooks.slack.com/services/T0/B0/x"
  "sudo -u bob curl -d '{}' https://hooks.slack.com/services/T0/B0/x"
  "echo '{\"text\":\"hi\"}' | curl -d @- https://hooks.slack.com/services/T0/B0/x"
  "U=https://hooks.slack.com/services/T0/B0/x; curl -d '{}' \"\$U\""
  "curl -X POST -d '{\"text\":\"hi\"}' \"\$SLACK_WEBHOOK_URL\""
  "python3 -c 'import urllib.request; urllib.request.urlopen(\"https://slack.com/api/chat.postMessage\", data=b\"x\")'"
  "node -e 'fetch(\"https://hooks.slack.com/services/x\", {method: \"POST\", body: \"{}\"})'"
  "bash -c 'curl https://slack.com/api/chat.postMessage -d text=hi'"
  "python3 - <<'EOF'
import urllib.request
urllib.request.urlopen('https://hooks.slack.com/services/T0/B0/x', data=b'{}')
EOF"
)
for c in "${posts[@]}"; do
  run_bash "$c"
  refused "refused: ${c:0:90}"
done
run_bash "curl -X POST https://slack.com/api/chat.postMessage -d channel=C1 -d text=hi"
says "a refused command names the draft tool" "slack_send_message_draft"
says "and the same channel and thread" "same channel and thread"
says "and to tell Dan where the draft is" "tell Dan where the draft is"

echo "slack drafts only: a command that only mentions an endpoint passes"

mentions=(
  "grep -rn chat.postMessage ."
  "grep -rn 'hooks.slack.com' src | head -5"
  "rg -n 'chat.scheduleMessage|SLACK_WEBHOOK' payload"
  "[ \"\$method\" = chat.postMessage ] && echo yes"
  "echo 'curl https://slack.com/api/chat.postMessage is refused'"
  "bash -c 'grep -n chat.postMessage nudge.py'"
  "git log --grep chat.postMessage --oneline"
  "curl -s https://example.com/status"
  "git status"
)
for c in "${mentions[@]}"; do
  run_bash "$c"
  allowed "passes: ${c:0:90}"
done

echo "slack drafts only: a script that posts is refused, one that only mentions the endpoint passes"

cat > "$T/alert.py" <<'PY'
import json, urllib.request
req = urllib.request.Request("https://slack.com/api/chat.postMessage", data=json.dumps({"text": "hi"}).encode())
urllib.request.urlopen(req)
PY
printf '%s\n' '#!/bin/bash' "curl -s -X POST -d '{\"text\":\"hi\"}' https://hooks.slack.com/services/T0/B0/x" > "$T/alert.sh"
chmod +x "$T/alert.sh"
printf '%s\n' '#!/bin/bash' "python3 $T/alert.py" > "$T/calls-alert.sh"
printf '%s\n' '#!/bin/bash' 'grep -rn "chat.postMessage" .' 'echo "hooks.slack.com is where a webhook posts"' > "$T/mentions.sh"
printf '%s\n' 'print("hello")' > "$T/plain.py"
mkdir -p "$T/copy"
cp "$NUDGE" "$T/copy/nudge.py"

run_bash "python3 $T/alert.py"
refused "a python script that posts"
says "the refusal names the script" "alert.py"
run_bash "cd $T && python3 alert.py"
refused "the same script named relative to the directory the command moved to"
run_bash "bash $T/alert.sh"
refused "a shell script that posts, run by bash"
run_bash "$T/alert.sh"
refused "the same script run by its path"
run_bash "bash $T/calls-alert.sh"
refused "a shell script that runs a script that posts"
run_bash "bash $T/mentions.sh"
allowed "a shell script that only mentions the endpoints"
run_bash "python3 $T/plain.py"
allowed "a script that names no endpoint"
run_bash "python3 $T/missing.py"
allowed "a script that does not exist runs nothing"

# What a heredoc feeds is its own body, not every line of the script around it. Measured before this
# was cut that way: running this very suite was refused, because one of its python3 heredocs sat in
# a file whose other lines name chat.postMessage as test data.
printf '%s\n' '#!/bin/bash' 'echo "chat.postMessage is only test data here"' "python3 - <<'PY'" 'print(1)' 'PY' > "$T/heredoc-clean.sh"
run_bash "bash $T/heredoc-clean.sh"
allowed "a script whose heredoc names no endpoint, beside a line that does"
run_bash "bash $DIR/test-slack-drafts-only-gate.sh"
allowed "running this suite itself"
run_bash "bash <<'EOF'
curl -d '{}' https://hooks.slack.com/services/T0/B0/x
EOF"
refused "a shell fed a posting command by a heredoc"
run_bash "bash <<'EOF'
grep -rn chat.postMessage .
EOF"
allowed "a shell fed a heredoc that only greps for the endpoint"

echo "slack drafts only: /nudge is the one script let through"

if [ -f "$NUDGE" ]; then check "nudge.py is where the gate expects it, beside the hooks" ok
else check "nudge.py is where the gate expects it, beside the hooks" "missing $NUDGE"; fi
run_bash "python3 $NUDGE 'https://example.slack.com/archives/C0TEST1/p1730000000000100'"
allowed "the nudge script passes"
run_bash "python3 $T/copy/nudge.py 'https://example.slack.com/archives/C0TEST1/p1730000000000100'"
refused "a copy of the nudge script anywhere else is refused"

echo "slack drafts only: a payload it cannot read"

# Fails CLOSED on a call whose raw text names a send route: Claude Code writes the payload, so an
# unreadable one means the platform changed, and letting a send through unjudged is the harm this
# gate exists to stop. One that names no route passes, as every refusing gate does (#1922).
run_raw '{"tool_name": "mcp__claude_ai_Slack__slack_send_message", "tool_input": {"channel_id": "C1"'
refused "a send tool payload cut short"
says "and names the payload as the reason" "payload"
run_raw '{"tool_name": "Bash", "tool_input": {"command": "curl https://slack.com/api/chat.postMessage -d x"'
refused "a posting command cut short"
run_raw '{"tool_name": "Bash", "tool_input": {"command": ["curl", "https://hooks.slack.com/services/x"]}}'
refused "a posting command whose command came as a list of words"
run_raw '{"tool_name": "Bash", "tool_input": {"command": "ls -la"'
allowed "an unrelated call cut short"
# The reader not running at all: python3 off the PATH on a call it judges.
NOPY="$(mktemp -d "${TMPDIR:-/tmp}/slack-gate-nopy.XXXXXXXX")"
ln -s "$(command -v cat)" "$NOPY/cat"
errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
OUT="$(payload Bash "$(bash_input "python3 $T/alert.py")" | PATH="$NOPY" "$BASH" "$HOOK" 2>"$errf")"; RC=$?
ERR="$(cat "$errf")"; rm -rf "$errf" "$NOPY"
refused "a reader that cannot start refuses a call that runs a script"
says "and says the gate could not judge it" "could not"

echo "slack drafts only: it is wired"

. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
if [ -z "$SETTINGS" ]; then
  check "a settings file registers the gate" "neither settings.hooks.json nor settings.json is in $DIR/.."
else
  wiring="$(python3 - "$SETTINGS" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
matchers = []
for g in d.get("hooks", {}).get("PreToolUse", []):
    for h in g.get("hooks", []):
        if h.get("command", "").endswith("hooks/slack-drafts-only-gate.sh"):
            if h.get("onFailure") != "block":
                print("the gate is not registered with onFailure block"); sys.exit()
            matchers.append(g.get("matcher", ""))
if not matchers:
    print("no PreToolUse group runs slack-drafts-only-gate.sh"); sys.exit()
must = ["Bash", "mcp__plugin_slack_slack__slack_send_message", "mcp__plugin_slack_slack__slack_schedule_message",
        "mcp__claude_ai_Slack__slack_send_message", "mcp__claude_ai_Slack__slack_schedule_message",
        "mcp__some_future_connector__slack_send_message"]
mustnot = ["Read", "Write", "mcp__playwright__browser_navigate"]
for name in must:
    if not any(re.fullmatch(m, name) for m in matchers):
        print("no matcher routes " + name); sys.exit()
for name in mustnot:
    if any(m == "" or re.fullmatch(m, name) for m in matchers):
        print("a matcher also routes " + name); sys.exit()
print("ok")
PY
)"
  check "the gate is registered under PreToolUse for Bash and every Slack tool, to block" "$wiring"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
