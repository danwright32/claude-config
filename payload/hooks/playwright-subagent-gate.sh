#!/usr/bin/env bash
#
# playwright-subagent-gate.sh
# Claude Code PreToolUse hook on the Playwright MCP tools: refuse a call made from a SUBAGENT
# (claude-config#384).
#
# The Playwright MCP server is ONE browser for the whole session, shared by the main thread and every
# agent it dispatches. On 2026-09-14 five research agents ran in parallel in the Child project and
# three reported the page changing underneath them mid read: one navigated to a product page and got
# an NHTSA page back. An evaluate run then answers from a sibling's page, and a quote lifted from the
# wrong page looks exactly like a verified one. A rule that lives only in a prompt is a hope (L27).
#
# WHO IS CALLING is read from `agent_id`. The hooks documentation says it is "present only when the
# hook fires inside a subagent call", and that was measured on Claude Code 2.1.274 on 2026-09-17: the
# main thread's PreToolUse payload carried no agent_id, a general-purpose subagent's carried one. A
# session started with `--agent` carries agent_type on its MAIN thread, so agent_type is not the
# signal. The field's PRESENCE is what counts, so an empty value is still a subagent.
#
# It refuses EVERY subagent, not only concurrent ones. Whether a sibling is on the browser right now
# cannot be read from one payload, and a lease that tried to track it would still leave the main
# thread free to navigate the page an agent is reading. The main session keeps the browser, and a
# subagent has WebFetch and the Claude in Chrome tools, which address a tab by id.
#
# evaluate and run_code_unsafe need nothing extra: they are where the wrong answer comes back, and
# with subagents refused the only caller left is the main thread, which cannot race itself.
#
# Fails OPEN on a payload it cannot read, loudly. Claude Code writes the payload, so an unreadable
# one means the platform changed, and refusing would take the browser away from the main session,
# the one caller this gate exists to leave alone, with no remedy inside the session. Silence would
# leave the gate off with everything looking normal, so it says so on stderr.

set -uo pipefail

payload="$(cat 2>/dev/null || true)"

verdict="$(printf '%s' "$payload" | python3 -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("unreadable\t" + type(e).__name__); sys.exit()
if not isinstance(d, dict):
    print("unreadable\tthe payload is not a JSON object"); sys.exit()
tool = d.get("tool_name")
if not isinstance(tool, str) or not re.match(r"mcp__(plugin_playwright_)?playwright__", tool):
    print("allow\t"); sys.exit()
print(("refuse\t" if "agent_id" in d else "allow\t") + tool)
' 2>&1)"

case "$verdict" in
  refuse$'\t'*)
    tool="${verdict#*$'\t'}"
    echo "REFUSED: $tool was called from a subagent. The Playwright browser is one browser shared by the whole session, so a parallel agent can navigate it underneath you and an evaluate or snapshot then returns that agent's page as your answer (claude-config#384). Use WebFetch to read a page, or the Claude in Chrome tools in a tab you create yourself (tabs_create_mcp, then address that tab id). If this work truly needs Playwright, stop and hand it back to the main session." >&2
    exit 2
    ;;
  allow$'\t'*)
    exit 0
    ;;
  unreadable$'\t'*)
    echo "PLAYWRIGHT SUBAGENT GATE DID NOT RUN: playwright-subagent-gate.sh could not read the hook payload (${verdict#*$'\t'}), so this Playwright call was let through without checking whether a subagent made it." >&2
    exit 0
    ;;
  *)
    echo "PLAYWRIGHT SUBAGENT GATE DID NOT RUN: playwright-subagent-gate.sh failed ($(printf '%s' "$verdict" | tr '\n' ' ')), so this Playwright call was let through without checking whether a subagent made it." >&2
    exit 0
    ;;
esac
