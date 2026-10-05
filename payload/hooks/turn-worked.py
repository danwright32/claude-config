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
import os, re, sys, json

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


BLOCK = 65536


def lines_from_end(f, counter):
    """The file's lines, last first, read backwards one block at a time.

    Read from the END and only as far as the last genuine user message, because two Stop hooks
    run this on every prompt and a transcript only grows: read whole, the cost per prompt grew
    with every turn before it (claude-config#603). counter[0] is the bytes read, for the guard.
    """
    f.seek(0, 2)
    pos = f.tell()
    tail = b""
    while pos > 0:
        step = min(BLOCK, pos)
        pos -= step
        f.seek(pos)
        chunk = f.read(step)
        counter[0] += len(chunk)
        parts = (chunk + tail).split(b"\n")
        tail = parts[0]
        for part in reversed(parts[1:]):
            if part.strip():
                yield part
    if tail.strip():
        yield tail


def main():
    counter = [0]
    worked = False
    try:
        f = open(sys.argv[1], "rb")
    except Exception:
        print("no")
        return
    try:
        for ln in lines_from_end(f, counter):
            try:
                obj = json.loads(ln.decode("utf-8"))
            except Exception:
                continue
            if not isinstance(obj, dict):
                continue
            if obj.get("type") == "assistant":
                for it in ((obj.get("message") or {}).get("content") or []):
                    if isinstance(it, dict) and it.get("type") == "tool_use" \
                            and is_mutating(it.get("name") or ""):
                        worked = True
                continue
            if is_genuine_user(obj):
                break
    except Exception:
        print("no")
        return
    finally:
        f.close()
        stats = os.environ.get("TURN_WORKED_STATS")
        if stats:
            try:
                with open(stats, "w") as out:
                    out.write("%d\n" % counter[0])
            except Exception:
                pass
    print("yes" if worked else "no")


if __name__ == "__main__":
    main()
