#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans settings.hooks.json
# Tests for the gate that refuses a Claude in Chrome script naming a loopback address beside a
# network call (claude-config#2774).
#
# Twice (2026-11-01 and 2026-11-11) a session capturing a production admin page in Dan's Chrome
# started a receiver on 127.0.0.1:8765 and had the page post a copy of itself there. The page's
# content security policy refused the request and paged Dan, with nothing for him to act on. The
# design rounds skill now saves a capture as a download instead; a rule that lives only in a prompt
# is a hope (L27), so this gate stands behind it.
#
# The payloads are in the shape test-chrome-subagent-tab-gate.sh uses (measured on Claude Code
# 2.1.274): the main thread's carries no agent_id, a subagent's carries one. The javascript tool's
# input is {action: "javascript_exec", text, tabId}, and browser_batch carries its calls as a list of
# {name, input}, as the tool schemas declare (read 2026-11-13).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/chrome-loopback-post-gate.sh"
CAPTURE="$DIR/../skills/design-rounds/capture-chrome.js"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "test-chrome-loopback-post-gate: there is no chrome-loopback-post-gate.sh beside this suite at $DIR." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs chrome-loopback-post-gate.sh beside it"
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 2
fi

# payload <tool name> <tool input as JSON> [agent_id]: one PreToolUse payload in the measured shape.
payload() {
  python3 -c '
import json, sys
tool, tool_input, agent_id = sys.argv[1], sys.argv[2], sys.argv[3]
d = {"session_id": "f6017250-8f33-47ac-bbb2-b82a7c319d0d",
     "transcript_path": "/tmp/transcript.jsonl", "cwd": "/tmp", "permission_mode": "default"}
if agent_id:
    d["agent_id"] = agent_id
d.update({"hook_event_name": "PreToolUse", "tool_name": tool,
          "tool_input": json.loads(tool_input), "tool_use_id": "toolu_01X4Qw7JnfYswF7UVX94Z4Sy"})
print(json.dumps(d))
' "$1" "$2" "${3:-}"
}
# js <script text>: the javascript tool's input for that text, on tab 7.
js() { python3 -c 'import json, sys; print(json.dumps({"action": "javascript_exec", "text": sys.argv[1], "tabId": 7}))' "$1"; }

RC=0; OUT=""; ERR=""
run_raw() { # run_raw <stdin text>
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/loopback-gate-err.XXXXXXXX")"
  OUT="$(printf '%s' "$1" | bash "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
run() { run_raw "$(payload "$@")"; }
C=mcp__claude-in-chrome__
JS="${C}javascript_tool"

refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:200}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:200}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:300}" ;; esac; }
. "$DIR/lib/hook-notice.sh"
notices() { local why; why="$(hook_notice_verdict "$OUT" "$2")"; if [ -z "$why" ]; then check "$1" ok; else check "$1" "$why"; fi; }

echo "chrome loopback post gate: the controls go through"

# The controls FIRST, so a refusal below is the loopback address doing it and not a gate that
# refuses every script (L159). The capture script itself, wrapped for the Chrome route, is the call
# the skill tells a session to make, so it must pass.
if [ -f "$CAPTURE" ]; then
  run "$JS" "$(js "await ($(cat "$CAPTURE"))({saveAs: \"chrome-probe-202611130100.html\"})")"
  allowed "the capture script run by the Chrome route goes through"
else
  check "the capture script run by the Chrome route goes through" "capture-chrome.js is not at $CAPTURE"
fi
run "$JS" "$(js 'await fetch("/api/leads").then((r) => r.json())')"
allowed "a fetch to the page's own origin by a relative path goes through"
run "$JS" "$(js 'await fetch("https://example.com/x").then((r) => r.status)')"
allowed "a fetch to an ordinary address goes through"
run "$JS" "$(js 'location.hostname === "localhost" ? "dev" : "prod"')"
allowed "a script naming localhost with no network call goes through"
run "${C}navigate" '{"url": "http://localhost:3000/", "tabId": 7}'
allowed "navigating a tab to a local dev server is not this gate's business"

echo "chrome loopback post gate: a script naming a loopback address beside a network call is refused"

# The call that paged Dan, in the shape the session made it.
run "$JS" "$(js 'const html = document.documentElement.outerHTML; await fetch("http://127.0.0.1:8765/", {method: "POST", body: html}); "sent"')"
refused "a page posting itself to a receiver on 127.0.0.1 is refused"
says "and it says why" "content security policy"
says "and names the route that sends nothing" "saveAs"
says "and where that route is written down" "capture-chrome.js"
# It sees two words in the text, never where a request goes, so it says only that (L11).
says "and claims only what it checked: the address named beside a network call" "names 127.0.0.1 beside a network call"
run "$JS" "$(js 'await fetch("http://127.0.0.1:8765/", {method: "POST", body: "x"})')" a3211051898ed98b1
refused "a subagent's is refused the same"
run "$JS" "$(js 'navigator.sendBeacon("http://localhost:8765/save", document.documentElement.outerHTML)')"
refused "a beacon to localhost is refused"
run "$JS" "$(js 'const x = new XMLHttpRequest(); x.open("POST", "http://[::1]:9000/"); x.send(document.body.innerHTML)')"
refused "an XMLHttpRequest to [::1] is refused"
run "$JS" "$(js 'new WebSocket("ws://0.0.0.0:7000").onopen = function () { this.send("x"); }')"
refused "a WebSocket to 0.0.0.0 is refused"
run "$JS" "$(js 'await fetch("HTTP://LOCALHOST:8765", {method: "POST", body: "x"})')"
refused "the address is matched whatever its case"
run "$JS" "$(js 'await fetch("http://127.4.5.6:8765", {method: "POST", body: "x"})')"
refused "every 127 address is loopback, not only 127.0.0.1"

echo "chrome loopback post gate: inside a batch"

run "${C}browser_batch" "{\"actions\": [{\"name\": \"computer\", \"input\": {\"action\": \"screenshot\", \"tabId\": 7}}, {\"name\": \"javascript_tool\", \"input\": $(js 'fetch("http://127.0.0.1:8765", {method: "POST", body: "x"})')}]}"
refused "a batch with one such script in it is refused"
says "and names the call in it" "call 2"
run "${C}browser_batch" "{\"actions\": [{\"name\": \"mcp__claude-in-chrome__javascript_tool\", \"input\": $(js 'fetch("http://localhost:1/", {method: "POST", body: "x"})')}]}"
refused "a full tool name inside a batch is judged like its short one"
run "${C}browser_batch" "{\"actions\": [{\"name\": \"javascript_tool\", \"input\": $(js 'document.title')}, {\"name\": \"navigate\", \"input\": {\"url\": \"http://localhost:3000\", \"tabId\": 7}}]}"
allowed "a batch with no such script goes through"

echo "chrome loopback post gate: nothing else is touched"

run Bash '{"command": "curl -X POST http://127.0.0.1:8765/ -d x"}'
allowed "a shell command is not this gate's business"
run mcp__notclaude-in-chrome__javascript_tool "$(js 'fetch("http://127.0.0.1:1", {method: "POST", body: "x"})')"
allowed "a server whose name merely contains the words is not Claude in Chrome"

echo "chrome loopback post gate: a payload it cannot read"

# Fails OPEN, loudly, for the reason the tab gate gives: Claude Code writes the payload, so an
# unreadable one means the platform changed, and refusing would take the browser from every caller
# with no remedy inside the session. What it must not do is go quiet (L98).
run_raw 'this is not json'
if [ "$RC" -eq 0 ]; then check "unreadable input is let through" ok; else check "unreadable input is let through" "exit $RC"; fi
notices "#1906 and says the gate did not run where the person sees it" "CHROME LOOPBACK POST GATE DID NOT RUN"
run_raw '{"hook_event_name":"PreToolUse","tool_name":"mcp__claude-in-chrome__javascript_tool","tool_input":{"action":"javascript_exec","text":7}}'
if [ "$RC" -eq 0 ]; then check "a script that is not text is let through" ok; else check "a script that is not text is let through" "exit $RC"; fi
notices "and says the gate did not run" "CHROME LOOPBACK POST GATE DID NOT RUN"
run "${C}browser_batch" '{"actions": "javascript_tool"}'
if [ "$RC" -eq 0 ]; then check "a batch whose calls are not a list is let through" ok; else check "a batch whose calls are not a list is let through" "exit $RC"; fi
notices "and says the gate did not run, rather than passing it in silence" "CHROME LOOPBACK POST GATE DID NOT RUN"
NOPY="$(mktemp -d "${TMPDIR:-/tmp}/loopback-gate-nopy.XXXXXXXX")"
ln -s "$(command -v cat)" "$NOPY/cat"
errf="$(mktemp "${TMPDIR:-/tmp}/loopback-gate-err.XXXXXXXX")"
OUT="$(payload "$JS" "$(js 'fetch("http://127.0.0.1:1", {method: "POST", body: "x"})')" | PATH="$NOPY" "$BASH" "$HOOK" 2>"$errf")"; RC=$?
ERR="$(cat "$errf")"; rm -rf "$errf" "$NOPY"
if [ "$RC" -eq 0 ]; then check "#1906 a reader that cannot start lets the call through" ok; else check "#1906 a reader that cannot start lets the call through" "exit $RC"; fi
notices "#1906 and says the gate did not run where the person sees it" "CHROME LOOPBACK POST GATE DID NOT RUN"

echo "chrome loopback post gate: it is wired"

# A check nothing invokes is the defect this closes (L3).
SETTINGS_DIR="${CHROME_GATE_SETTINGS_DIR:-$DIR/..}"
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$SETTINGS_DIR")"
if [ -z "$SETTINGS" ]; then
  echo "test-chrome-loopback-post-gate: neither settings.hooks.json nor settings.json is in $SETTINGS_DIR, so the wiring could not be checked." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the settings file that registers the hook, and $SETTINGS_DIR holds neither"
else
  wiring="$(python3 - "$SETTINGS" <<'PY'
import json, re, sys
hooks = json.load(open(sys.argv[1])).get("hooks", {})
groups = [g for g in hooks.get("PreToolUse", [])
          if any("chrome-loopback-post-gate.sh" in h.get("command", "") for h in g.get("hooks", []))]
if not groups:
    print("no PreToolUse group runs chrome-loopback-post-gate.sh"); sys.exit()
matchers = [g.get("matcher", "") for g in groups]
for name in ["mcp__claude-in-chrome__javascript_tool", "mcp__claude-in-chrome__browser_batch"]:
    if not any(re.fullmatch(m, name) for m in matchers):
        print("no matcher routes " + name); sys.exit()
for name in ["Bash", "WebFetch", "mcp__claude-in-chrome__navigate"]:
    if any(m == "" or re.fullmatch(m, name) for m in matchers):
        print("a matcher also routes " + name); sys.exit()
for g in groups:
    for h in g.get("hooks", []):
        if "chrome-loopback-post-gate.sh" in h.get("command", "") and h.get("onFailure") != "block":
            print("it is not registered with onFailure block"); sys.exit()
print("ok")
PY
)"
  check "the hook is registered under PreToolUse for the javascript tool and browser_batch only, blocking on failure" "$wiring"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
