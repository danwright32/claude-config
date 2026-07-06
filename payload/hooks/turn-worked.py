#!/usr/bin/env python3
"""Shared Stop-hook helper. Prints "yes" if the latest turn (since the last
genuine user message) used a tool that can change something, else "no".

Read-only turns (Read, Grep, Glob, WebFetch, AskUserQuestion, ...) and pure
chat turns print "no" so end-of-turn hooks stay quiet during short Q&A.
Connected-app (MCP) tools count as work when they act (send, click, create,
apply, ...) but not when they only read (read, list, get, search, snapshot).
Fails safe: any error prints "no".

Usage: turn-worked.py <transcript_path>
"""
import re, sys, json

MUTATING_TOOLS = {"Edit", "Write", "NotebookEdit", "Bash", "Agent", "Workflow"}
MCP_READONLY = re.compile(
    r"(read|list|get|search|query|fetch|snapshot|screenshot|console|network"
    r"|docs|advisors|logs|messages|suggest|authenticate|confirm)",
    re.IGNORECASE,
)


def is_mutating(name):
    if name in MUTATING_TOOLS:
        return True
    if name.startswith("mcp__"):
        return not MCP_READONLY.search(name.rsplit("__", 1)[-1])
    return False


def is_genuine_user(obj):
    if obj.get("type") != "user":
        return False
    content = (obj.get("message") or {}).get("content")
    if isinstance(content, str):
        return content.strip() != ""
    if isinstance(content, list):
        return any(isinstance(it, dict) and it.get("type") == "text" for it in content)
    return False


def main():
    try:
        with open(sys.argv[1], "r", encoding="utf-8") as f:
            lines = [ln for ln in f if ln.strip()]
    except Exception:
        print("no")
        return

    worked = False
    for ln in reversed(lines):
        try:
            obj = json.loads(ln)
        except Exception:
            continue
        if obj.get("type") == "assistant":
            for it in ((obj.get("message") or {}).get("content") or []):
                if isinstance(it, dict) and it.get("type") == "tool_use" \
                        and is_mutating(it.get("name") or ""):
                    worked = True
            continue
        if is_genuine_user(obj):
            break
    print("yes" if worked else "no")


if __name__ == "__main__":
    main()
