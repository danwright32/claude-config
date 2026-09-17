#!/usr/bin/env bash
# Tests for the gate that keeps subagents off the shared Playwright browser (claude-config#384).
#
# The Playwright MCP server is ONE browser for the whole session. On 2026-09-14 five research
# agents ran in parallel in the Child project and three reported the page changing underneath them
# mid read, so an evaluate could return a sibling's page as the agent's own answer. A rule that
# lives only in a prompt is a hope (L27).
#
# The payloads are in the shape measured on Claude Code 2.1.274 on 2026-09-17: a headless session
# with a PreToolUse logger ran one Bash call itself and one through a general-purpose subagent. The
# main thread's payload carried no agent_id and no agent_type; the subagent's carried both
# ("agent_id":"a3211051898ed98b1","agent_type":"general-purpose"). The hooks documentation says the
# same: agent_id is "present only when the hook fires inside a subagent call". A fixture of this
# suite's own invention would only confirm its assumption about that shape (L52).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/playwright-subagent-gate.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "test-playwright-subagent-gate: there is no playwright-subagent-gate.sh beside this suite at $DIR." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs playwright-subagent-gate.sh beside it"
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 2
fi

# payload <tool name> [agent_id] [agent_type]: one PreToolUse payload in the measured shape. An
# argument left empty is a field left OUT, which is how the main thread's payload arrives.
payload() {
  python3 -c '
import json, sys
tool, agent_id, agent_type = sys.argv[1], sys.argv[2], sys.argv[3]
d = {"session_id": "f6017250-8f33-47ac-bbb2-b82a7c319d0d",
     "transcript_path": "/tmp/transcript.jsonl", "cwd": "/tmp",
     "prompt_id": "595670b3-8674-4c72-9066-ef4a993c7f60",
     "permission_mode": "default"}
if agent_id:
    d["agent_id"] = agent_id
if agent_type:
    d["agent_type"] = agent_type
d.update({"hook_event_name": "PreToolUse", "tool_name": tool,
          "tool_input": {"url": "https://example.com"},
          "tool_use_id": "toolu_01X4Qw7JnfYswF7UVX94Z4Sy"})
print(json.dumps(d))
' "$1" "${2:-}" "${3:-}"
}

RC=0; OUT=""; ERR=""
run_raw() { # run_raw <stdin text>
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/pw-gate-err.XXXXXXXX")"
  OUT="$(printf '%s' "$1" | bash "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
run() { run_raw "$(payload "$@")"; }

refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:200}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:200}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:300}" ;; esac; }

echo "playwright subagent gate: the main session keeps the browser"

# The control FIRST. The same call that is refused below goes through from the main thread, so a
# refusal there is the agent_id doing it and not a gate that refuses every Playwright call (L159).
run mcp__playwright__browser_navigate
allowed "the main session may navigate"
run mcp__playwright__browser_evaluate
allowed "and evaluate"
run mcp__playwright__browser_run_code_unsafe
allowed "and run code"

# A session started with --agent carries agent_type on the MAIN thread with no agent_id. That is
# still one caller on the browser, and refusing it would lock that session out entirely.
run mcp__playwright__browser_snapshot "" security-reviewer
allowed "a session started with --agent is still the main thread"

echo "playwright subagent gate: a subagent is refused"

run mcp__playwright__browser_navigate a3211051898ed98b1 general-purpose
refused "a subagent may not navigate the shared browser"
says "and it says why" "one browser"
says "and names WebFetch instead" "WebFetch"
says "and names the Chrome tools instead" "Claude in Chrome"
says "and names the tool it refused" "mcp__playwright__browser_navigate"

# evaluate and run_code are where the wrong page's answer comes back looking verified, so they are
# asserted by name rather than trusted to the prefix.
run mcp__playwright__browser_evaluate a3211051898ed98b1 general-purpose
refused "a subagent may not evaluate on the shared page"
run mcp__playwright__browser_run_code_unsafe a3211051898ed98b1 Explore
refused "nor run code against it"
run mcp__playwright__browser_take_screenshot a3211051898ed98b1 general-purpose
refused "nor screenshot it"

# The documentation describes the field's PRESENCE as the signal, so a present but empty one is a
# subagent too. Reading it as absent would let through exactly the call the gate exists for.
run_raw '{"agent_id":"","agent_type":"general-purpose","hook_event_name":"PreToolUse","tool_name":"mcp__playwright__browser_click","tool_input":{}}'
refused "an agent_id that is present but empty is still a subagent"

# The same server installed as a plugin is the same single browser under a scoped name.
run mcp__plugin_playwright_playwright__browser_navigate a3211051898ed98b1 general-purpose
refused "the plugin scoped Playwright server is the same browser"

echo "playwright subagent gate: nothing else is touched"

run mcp__claude-in-chrome__navigate a3211051898ed98b1 general-purpose
allowed "a subagent may use the Chrome tools"
run WebFetch a3211051898ed98b1 general-purpose
allowed "and WebFetch"
run mcp__notplaywright__browser_navigate a3211051898ed98b1 general-purpose
allowed "a server whose name merely contains the word is not Playwright"

echo "playwright subagent gate: a payload it cannot read"

# Fails OPEN, loudly. The payload is written by Claude Code, so an unreadable one means the platform
# changed underneath the hook, and the one caller this gate exists to leave alone is the main
# session: refusing would take its browser away with no remedy inside the session. What it must not
# do is go quiet, or the gate is off with everything looking normal (L98).
run_raw 'this is not json'
if [ "$RC" -eq 0 ]; then check "unreadable input is let through rather than refusing the main session" ok
else check "unreadable input is let through rather than refusing the main session" "exit $RC"; fi
says "but it says the gate did not run" "PLAYWRIGHT SUBAGENT GATE DID NOT RUN"
run_raw ''
if [ "$RC" -eq 0 ]; then check "an empty payload is the same" ok; else check "an empty payload is the same" "exit $RC"; fi
says "and says so too" "PLAYWRIGHT SUBAGENT GATE DID NOT RUN"
run_raw '["a", "list"]'
if [ "$RC" -eq 0 ]; then check "valid JSON that is not an object is the same" ok; else check "valid JSON that is not an object is the same" "exit $RC"; fi
says "and says so" "PLAYWRIGHT SUBAGENT GATE DID NOT RUN"

echo "playwright subagent gate: it is wired"

# A check nothing invokes is the defect this closes (L3). The registration must route every
# Playwright tool, including the two that return page content, to this hook under PreToolUse. The
# matcher is tested as a regex over whole names, which is the stricter reading of how Claude Code
# applies it.
SETTINGS_DIR="${PLAYWRIGHT_GATE_SETTINGS_DIR:-$DIR/..}"
SETTINGS=""
if [ -f "$SETTINGS_DIR/settings.hooks.json" ]; then SETTINGS="$SETTINGS_DIR/settings.hooks.json"
elif [ -f "$SETTINGS_DIR/settings.json" ]; then SETTINGS="$SETTINGS_DIR/settings.json"; fi
if [ -z "$SETTINGS" ]; then
  echo "test-playwright-subagent-gate: neither settings.hooks.json nor settings.json is in $SETTINGS_DIR, so the wiring could not be checked." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the settings file that registers the hook, and $SETTINGS_DIR holds neither"
else
  wiring="$(python3 - "$SETTINGS" <<'PY'
import json, re, sys
hooks = json.load(open(sys.argv[1])).get("hooks", {})
matchers = [g.get("matcher", "") for g in hooks.get("PreToolUse", [])
            if any("playwright-subagent-gate.sh" in h.get("command", "") for h in g.get("hooks", []))]
if not matchers:
    print("no PreToolUse group runs playwright-subagent-gate.sh"); sys.exit()
must = ["mcp__playwright__browser_navigate", "mcp__playwright__browser_evaluate",
        "mcp__playwright__browser_run_code_unsafe", "mcp__plugin_playwright_playwright__browser_snapshot"]
mustnot = ["Bash", "WebFetch", "mcp__claude-in-chrome__navigate"]
for name in must:
    if not any(re.fullmatch(m, name) for m in matchers):
        print("no matcher routes " + name); sys.exit()
for name in mustnot:
    if any(m == "" or re.fullmatch(m, name) for m in matchers):
        print("a matcher also routes " + name); sys.exit()
print("ok")
PY
)"
  check "the hook is registered under PreToolUse for every Playwright tool and nothing else" "$wiring"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
