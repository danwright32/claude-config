#!/usr/bin/env bash
#
# chrome-subagent-tab-gate.sh
# Claude Code PreToolUse(mcp__claude-in-chrome__.*) hook: refuse a Claude in Chrome call made from a
# SUBAGENT that names no tabId (claude-config#2285). The tools in that line are where the settings
# must register this hook and nowhere else, and test-hook-coverage.sh checks it (claude-config#413).
#
# Every caller in a session shares ONE Claude in Chrome tab group, and a call that names no tabId
# acts on the group's first tab. On 2026-11-05 three play agents ran side by side, each told to work
# only in a tab it had created, and one typed a lead message into another agent's test session,
# because one of its calls left the tab unnamed. Nothing refused it. A rule that lives only in a
# prompt is a hope (L27), so the brief rule in skills/orchestrate/agent-rules.md has this behind it.
#
# WHO IS CALLING is read from `agent_id`, exactly as playwright-subagent-gate.sh reads it: present
# only when the hook fires inside a subagent (measured on Claude Code 2.1.274, 2026-09-17), and its
# PRESENCE is what counts, so an empty value is still a subagent. The main session is never asked:
# it is one caller, and the tab it drives is its own.
#
# WHICH TOOLS: every mcp__claude-in-chrome__ tool needs a tabId from a subagent, EXCEPT the ones named
# in TAB_FREE below. Those are the tools whose schemas carry no tabId parameter at all (read from the
# tool schemas on 2026-11-05): tabs_create_mcp and tabs_context_mcp make and list tabs, and
# list_connected_browsers, select_browser and switch_browser choose the browser. Asking them for a
# tabId would refuse the very call (tabs_create_mcp) that hands an agent its tab. browser_batch has
# no tabId of its own either; its calls are judged one by one, each by the same rule, a full tool
# name in it read as its short one.
#
# The list is of tools that take NO tab, never of tools that take one, so it cannot go stale in the
# dangerous direction: a tool added to the server later that acts on a page is covered the day it
# ships. A new tool that takes no tab is refused from a subagent until it is added to TAB_FREE, and
# the refusal names this file, so that fault is loud and points at its own remedy.
#
# It checks that a tab is NAMED, not that the tab is the agent's own: nothing in one payload says
# which agent created a tab. The brief rule covers that half (pass the id tabs_create_mcp returned,
# never one read from tabs_context_mcp).
#
# Fails OPEN on a payload it cannot read, loudly, for the Playwright gate's reason: Claude Code writes
# the payload, so an unreadable one means the platform changed, and refusing would take the browser
# from every caller, the main session included, with no remedy inside the session. Silence would
# leave the gate off with everything looking normal, so it says so in a systemMessage
# (lib/hook-notice.sh): Claude Code discards a PreToolUse hook's stderr on exit 0 (#1906).

set -uo pipefail

payload="$(cat 2>/dev/null || true)"
# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
# shellcheck source=lib/hook-notice.sh
. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }

# Cleaned by the shared reader before python3 parses it: a lone surrogate escape survives the parse
# and raises when the tool name is written back out (claude-config#1944). Without the library the
# payload is read as it came, so its absence takes nothing away from this gate.
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && payload="$(ps_clean_payload "$payload")"

verdict="$(printf '%s' "$payload" | python3 -c '
import json, re, sys
sys.stdout.reconfigure(errors="replace")
PREFIX = "mcp__claude-in-chrome__"
# The tools whose schemas take no tabId. Keep in step with the header above.
TAB_FREE = {"tabs_create_mcp", "tabs_context_mcp", "list_connected_browsers",
            "select_browser", "switch_browser"}
try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
except Exception as e:
    print("unreadable\t" + type(e).__name__); sys.exit()
if not isinstance(d, dict):
    print("unreadable\tthe payload is not a JSON object"); sys.exit()
tool = d.get("tool_name")
if not isinstance(tool, str) or not tool.startswith(PREFIX):
    print("allow\t"); sys.exit()
if "agent_id" not in d:
    print("allow\t"); sys.exit()
ti = d.get("tool_input")
if not isinstance(ti, dict):
    print("unreadable\tthe tool input is not a JSON object"); sys.exit()

def names_tab(inp):
    if not isinstance(inp, dict):
        return False
    t = inp.get("tabId")
    return t is not None and t != "" and not isinstance(t, bool)

short = tool[len(PREFIX):]
if short in TAB_FREE:
    print("allow\t"); sys.exit()
if short == "browser_batch":
    actions = ti.get("actions")
    if not isinstance(actions, list):
        print("refuse\t" + tool + "\tits actions are not a list, so no call in it can be seen to name a tab"); sys.exit()
    for i, a in enumerate(actions):
        name = a.get("name") if isinstance(a, dict) else None
        name = name if isinstance(name, str) else ""
        inner = name[len(PREFIX):] if name.startswith(PREFIX) else name
        if inner in TAB_FREE:
            continue
        if not names_tab(a.get("input") if isinstance(a, dict) else None):
            print("refuse\t" + tool + "\tcall " + str(i + 1) + " in it (" + (inner or "unnamed") + ") names no tabId"); sys.exit()
    print("allow\t"); sys.exit()
if names_tab(ti):
    print("allow\t"); sys.exit()
print("refuse\t" + tool + "\tit names no tabId")
' 2>&1)"

case "$verdict" in
  refuse$'\t'*)
    rest="${verdict#*$'\t'}"
    tool="${rest%%$'\t'*}"
    why="${rest#*$'\t'}"
    echo "REFUSED: $tool was called from a subagent and $why. Every caller in this session shares one Claude in Chrome tab group, and a call naming no tab acts on the group's first tab, which can be another agent's: on 2026-11-05 one agent typed into another agent's test session this way (claude-config#2285). Call tabs_create_mcp once, keep the tabId it returns, and pass that tabId on every Claude in Chrome call, inside browser_batch too. Never use a tabId read from tabs_context_mcp, which lists every agent's tabs. If this tool genuinely takes no tabId, it belongs in TAB_FREE in chrome-subagent-tab-gate.sh." >&2
    exit 2
    ;;
  allow$'\t'*)
    exit 0
    ;;
  unreadable$'\t'*)
    hook_allow_notice "CHROME SUBAGENT TAB GATE DID NOT RUN: chrome-subagent-tab-gate.sh could not read the hook payload (${verdict#*$'\t'}), so this Claude in Chrome call was let through without checking that a subagent named its tab."
    ;;
  *)
    hook_allow_notice "CHROME SUBAGENT TAB GATE DID NOT RUN: chrome-subagent-tab-gate.sh failed (${verdict//$'\n'/ }), so this Claude in Chrome call was let through without checking that a subagent named its tab."
    ;;
esac
