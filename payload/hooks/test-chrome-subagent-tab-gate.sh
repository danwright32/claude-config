#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans settings.hooks.json
# Tests for the gate that makes a subagent name its own tab on every Claude in Chrome call
# (claude-config#2285).
#
# The Claude in Chrome tools put every caller in a session into ONE tab group, and a call that names
# no tabId acts on the group's first tab. On 2026-11-05 three play agents ran side by side, each told
# to work only in a tab it had created, and one typed a lead message into another agent's test
# session because one call left the tab unnamed. A rule that lives only in a prompt is a hope (L27).
#
# The payloads are in the shape the Playwright gate's suite measured on Claude Code 2.1.274 on
# 2026-09-17: the main thread's PreToolUse payload carries no agent_id, a subagent's carries one. The
# tool inputs are in the shape the Claude in Chrome tool schemas declare (read 2026-11-05): tabId is a
# number on every tool that acts on a page, navigate's is optional, and browser_batch carries its
# calls as a list of {name, input} with the tabId inside each input.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/chrome-subagent-tab-gate.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "test-chrome-subagent-tab-gate: there is no chrome-subagent-tab-gate.sh beside this suite at $DIR." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs chrome-subagent-tab-gate.sh beside it"
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 2
fi

# payload <tool name> <tool input as JSON> [agent_id] [agent_type]: one PreToolUse payload in the
# measured shape. An agent_id left empty is a field left OUT, which is how the main thread's arrives.
payload() {
  python3 -c '
import json, sys
tool, tool_input, agent_id, agent_type = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = {"session_id": "f6017250-8f33-47ac-bbb2-b82a7c319d0d",
     "transcript_path": "/tmp/transcript.jsonl", "cwd": "/tmp",
     "prompt_id": "595670b3-8674-4c72-9066-ef4a993c7f60",
     "permission_mode": "default"}
if agent_id:
    d["agent_id"] = agent_id
if agent_type:
    d["agent_type"] = agent_type
d.update({"hook_event_name": "PreToolUse", "tool_name": tool,
          "tool_input": json.loads(tool_input),
          "tool_use_id": "toolu_01X4Qw7JnfYswF7UVX94Z4Sy"})
print(json.dumps(d))
' "$1" "$2" "${3:-}" "${4:-}"
}

RC=0; OUT=""; ERR=""
run_raw() { # run_raw <stdin text>
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/chrome-gate-err.XXXXXXXX")"
  OUT="$(printf '%s' "$1" | bash "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
run() { run_raw "$(payload "$@")"; }
SUB=a3211051898ed98b1
C=mcp__claude-in-chrome__

refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:200}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:200}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:300}" ;; esac; }
# notices <label> <ERE>: a call let through says why in the systemMessage on stdout, the one place
# Claude Code shows a PreToolUse hook that exits 0; its stderr is discarded (claude-config#1906).
. "$DIR/lib/hook-notice.sh"
notices() { local why; why="$(hook_notice_verdict "$OUT" "$2")"; if [ -z "$why" ]; then check "$1" ok; else check "$1" "$why"; fi; }

echo "chrome subagent tab gate: the main session is not asked to name a tab"

# The control FIRST. The same unnamed call refused below goes through from the main thread, so a
# refusal there is the agent_id doing it and not a gate that refuses every unnamed call (L159).
run "${C}navigate" '{"url": "https://example.com"}'
allowed "the main session may navigate without naming a tab"
run "${C}computer" '{"action": "screenshot"}'
allowed "and screenshot without one"
run "${C}computer" '{"action": "screenshot"}' "" security-reviewer
allowed "a session started with --agent is still the main thread"

echo "chrome subagent tab gate: a subagent's call that names no tab is refused"

run "${C}navigate" '{"url": "https://example.com"}' "$SUB" general-purpose
refused "a subagent may not navigate without naming a tab"
says "and it says why" "first tab"
says "and tells it to pass its own tabId" "tabId"
says "and where that tabId comes from" "tabs_create_mcp"
says "and names the tool it refused" "${C}navigate"

# The call that did the damage on 2026-11-05: typing, which lands in whichever tab is first.
run "${C}computer" '{"action": "type", "text": "hello", "action_summary": "Types a message"}' "$SUB" general-purpose
refused "a subagent may not type without naming a tab"
run "${C}javascript_tool" '{"action": "javascript_exec", "text": "1"}' "$SUB" Explore
refused "nor run script without one"
run "${C}navigate" '{"url": "https://example.com", "tabId": null}' "$SUB" general-purpose
refused "a tabId that is null names no tab"
run "${C}navigate" '{"url": "https://example.com", "tabId": ""}' "$SUB" general-purpose
refused "nor does an empty one"
# The documentation describes the field's PRESENCE as the signal, so a present but empty agent_id
# is a subagent too.
run_raw '{"agent_id":"","agent_type":"general-purpose","hook_event_name":"PreToolUse","tool_name":"mcp__claude-in-chrome__find","tool_input":{"query":"search bar"}}'
refused "an agent_id that is present but empty is still a subagent"

echo "chrome subagent tab gate: a subagent's call that names its tab goes through"

run "${C}navigate" '{"url": "https://example.com", "tabId": 1734098512}' "$SUB" general-purpose
allowed "a subagent may navigate the tab it names"
run "${C}computer" '{"action": "type", "text": "hello", "tabId": 1734098512}' "$SUB" general-purpose
allowed "and type into it"
run "${C}tabs_close_mcp" '{"tabId": 1734098512}' "$SUB" general-purpose
allowed "and close it"

echo "chrome subagent tab gate: the tools that make or list tabs take no tabId"

# The schemas give these five no tabId parameter at all, so asking for one would refuse the very
# call (tabs_create_mcp) that hands the agent its tab.
for t in tabs_create_mcp tabs_context_mcp list_connected_browsers select_browser switch_browser; do
  run "${C}$t" '{}' "$SUB" general-purpose
  allowed "a subagent may call $t, which has no tabId"
done

echo "chrome subagent tab gate: a batch names a tab on every call in it"

run "${C}browser_batch" '{"actions": [{"name": "navigate", "input": {"url": "https://example.com", "tabId": 7}}, {"name": "computer", "input": {"action": "screenshot", "tabId": 7}}]}' "$SUB" general-purpose
allowed "a batch whose every call names a tab goes through"
run "${C}browser_batch" '{"actions": [{"name": "navigate", "input": {"url": "https://example.com", "tabId": 7}}, {"name": "computer", "input": {"action": "type", "text": "hi"}}]}' "$SUB" general-purpose
refused "a batch with one call naming no tab is refused"
says "and names the call in it" "computer"
run "${C}browser_batch" '{"actions": [{"name": "tabs_create_mcp", "input": {}}, {"name": "mcp__claude-in-chrome__navigate", "input": {"url": "https://example.com", "tabId": 7}}]}' "$SUB" general-purpose
allowed "a tab free call inside a batch needs no tabId, and a full tool name is read as its short one"
run "${C}browser_batch" '{"actions": [{"name": "mcp__claude-in-chrome__find", "input": {"query": "x"}}]}' "$SUB" general-purpose
refused "a full tool name inside a batch is judged like its short one"
run "${C}browser_batch" '{"actions": "navigate"}' "$SUB" general-purpose
refused "a batch whose calls cannot be read as a list shows no tab, so it is refused"
run "${C}browser_batch" '{"actions": [{"name": "navigate", "input": {"url": "https://example.com"}}]}'
allowed "the main session's unnamed batch goes through"

echo "chrome subagent tab gate: a tool added later"

# A new tool is judged by the rule, never by a list of tools that take a tabId, so one that acts on
# a page is covered on the day it ships. One that has no tabId is refused until it is named tab free,
# and the refusal says where that list lives, so the fault is loud and points at its own remedy.
run "${C}some_future_page_tool" '{"query": "x"}' "$SUB" general-purpose
refused "an unknown Chrome tool called with no tabId is refused"
says "and the refusal names where the tab free tools are listed" "chrome-subagent-tab-gate.sh"
run "${C}some_future_page_tool" '{"query": "x", "tabId": 7}' "$SUB" general-purpose
allowed "and goes through once it names a tab"

echo "chrome subagent tab gate: nothing else is touched"

run WebFetch '{"url": "https://example.com"}' "$SUB" general-purpose
allowed "a subagent's WebFetch is not this gate's business"
run mcp__notclaude-in-chrome__navigate '{"url": "https://example.com"}' "$SUB" general-purpose
allowed "a server whose name merely contains the words is not Claude in Chrome"

echo "chrome subagent tab gate: a payload it cannot read"

# Fails OPEN, loudly, as the Playwright gate does and for its reason: Claude Code writes the payload,
# so an unreadable one means the platform changed, and refusing would take the browser from every
# caller, the main session included, with no remedy inside the session. What it must not do is go
# quiet, or the gate is off with everything looking normal (L98).
run_raw 'this is not json'
if [ "$RC" -eq 0 ]; then check "unreadable input is let through rather than refusing everyone" ok
else check "unreadable input is let through rather than refusing everyone" "exit $RC"; fi
says "but it says the gate did not run" "CHROME SUBAGENT TAB GATE DID NOT RUN"
run_raw ''
if [ "$RC" -eq 0 ]; then check "an empty payload is the same" ok; else check "an empty payload is the same" "exit $RC"; fi
says "and says so too" "CHROME SUBAGENT TAB GATE DID NOT RUN"
run_raw '["a", "list"]'
if [ "$RC" -eq 0 ]; then check "valid JSON that is not an object is the same" ok; else check "valid JSON that is not an object is the same" "exit $RC"; fi
says "and says so" "CHROME SUBAGENT TAB GATE DID NOT RUN"
notices "#1906 where the person sees it" "CHROME SUBAGENT TAB GATE DID NOT RUN"
run_raw '{"agent_id":"a1","hook_event_name":"PreToolUse","tool_name":"mcp__claude-in-chrome__navigate","tool_input":"{\"url\": \"x\"}"}'
if [ "$RC" -eq 0 ]; then check "a tool input that is not an object is let through" ok; else check "a tool input that is not an object is let through" "exit $RC"; fi
notices "and says the gate did not run" "CHROME SUBAGENT TAB GATE DID NOT RUN"
# The other way it can fail: its reader not running at all. python3 is taken off the PATH, so the
# capture holds the shell's own complaint instead of a verdict.
NOPY="$(mktemp -d "${TMPDIR:-/tmp}/chrome-gate-nopy.XXXXXXXX")"
ln -s "$(command -v cat)" "$NOPY/cat"
errf="$(mktemp "${TMPDIR:-/tmp}/chrome-gate-err.XXXXXXXX")"
OUT="$(payload "${C}navigate" '{"url": "https://example.com"}' a1 general-purpose | PATH="$NOPY" "$BASH" "$HOOK" 2>"$errf")"; RC=$?
ERR="$(cat "$errf")"; rm -rf "$errf" "$NOPY"
if [ "$RC" -eq 0 ]; then check "#1906 a reader that cannot start lets the call through" ok; else check "#1906 a reader that cannot start lets the call through" "exit $RC"; fi
notices "#1906 and says the gate did not run where the person sees it" "CHROME SUBAGENT TAB GATE DID NOT RUN"

echo "chrome subagent tab gate: it is wired"

# A check nothing invokes is the defect this closes (L3). The registration must route every Claude
# in Chrome tool to this hook under PreToolUse and nothing else. The matcher is tested as a regex over
# whole names, which is the stricter reading of how Claude Code applies it.
SETTINGS_DIR="${CHROME_GATE_SETTINGS_DIR:-$DIR/..}"
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$SETTINGS_DIR")"
if [ -z "$SETTINGS" ]; then
  echo "test-chrome-subagent-tab-gate: neither settings.hooks.json nor settings.json is in $SETTINGS_DIR, so the wiring could not be checked." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the settings file that registers the hook, and $SETTINGS_DIR holds neither"
else
  wiring="$(python3 - "$SETTINGS" <<'PY'
import json, re, sys
hooks = json.load(open(sys.argv[1])).get("hooks", {})
matchers = [g.get("matcher", "") for g in hooks.get("PreToolUse", [])
            if any("chrome-subagent-tab-gate.sh" in h.get("command", "") for h in g.get("hooks", []))]
if not matchers:
    print("no PreToolUse group runs chrome-subagent-tab-gate.sh"); sys.exit()
must = ["mcp__claude-in-chrome__navigate", "mcp__claude-in-chrome__computer",
        "mcp__claude-in-chrome__browser_batch", "mcp__claude-in-chrome__tabs_create_mcp"]
mustnot = ["Bash", "WebFetch", "mcp__playwright__browser_navigate"]
for name in must:
    if not any(re.fullmatch(m, name) for m in matchers):
        print("no matcher routes " + name); sys.exit()
for name in mustnot:
    if any(m == "" or re.fullmatch(m, name) for m in matchers):
        print("a matcher also routes " + name); sys.exit()
print("ok")
PY
)"
  check "the hook is registered under PreToolUse for every Claude in Chrome tool and nothing else" "$wiring"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
