#!/usr/bin/env bash
# Global Stop hook: after a turn that involved REAL work (any tool use other
# than AskUserQuestion), SILENTLY persist anything memory-worthy into the
# CURRENT PROJECT's flat-file memory store (derived from the transcript path, so
# it always matches Claude Code's own per-project memory dir), following the
# memory protocol in CLAUDE.md.
#
# Design (2026-06-18): exactly ONE memory writer; per-project memory stays
# separate (project facts land where that project recalls them); durable
# cross-project rules live in ~/.claude/CLAUDE.md instead. The save is SILENT —
# no banner, no section, no narration (user asked not to see it).
#
# Skips: trivial chat turns, AskUserQuestion-only turns, and self-loops
# (stop_hook_active guard). Fails SAFE on any parse/transcript error.
# To disable, remove its hooks.Stop entry in ~/.claude/settings.json.

set -uo pipefail

input=$(cat)

CC_HOOK_INPUT="$input" python3 <<'PY'
import sys, json, os, re

try:
    data = json.loads(os.environ.get("CC_HOOK_INPUT", "") or "{}")
except Exception:
    sys.exit(0)

# Loop guard: don't re-fire on our own (or another Stop hook's) continuation.
if data.get("stop_hook_active"):
    sys.exit(0)

transcript = data.get("transcript_path") or ""
if not transcript or not os.path.isfile(transcript):
    sys.exit(0)

# Did the latest turn (since the last genuine user message) use any tool other
# than AskUserQuestion? If not, it was a trivial chat / question turn -> skip.
SKIP_TOOLS = {"AskUserQuestion"}
try:
    with open(transcript, "r", encoding="utf-8") as f:
        lines = [ln for ln in f if ln.strip()]
except Exception:
    sys.exit(0)

def is_genuine_user(o):
    if o.get("type") != "user":
        return False
    c = (o.get("message") or {}).get("content")
    if isinstance(c, str):
        return c.strip() != ""
    if isinstance(c, list):
        return any(isinstance(it, dict) and it.get("type") == "text" for it in c)
    return False

worked = False
for ln in reversed(lines):
    try:
        o = json.loads(ln)
    except Exception:
        continue
    if o.get("type") == "assistant":
        for it in ((o.get("message") or {}).get("content") or []):
            if isinstance(it, dict) and it.get("type") == "tool_use" and it.get("name") not in SKIP_TOOLS:
                worked = True
        continue
    if is_genuine_user(o):
        break

if not worked:
    sys.exit(0)

# Derive THIS project's memory dir from the transcript path: the path segment
# right after .../.claude/projects/ is Claude Code's sanitized cwd, and memory/
# lives directly under it. This matches the dir Claude auto-loads for the
# project, whatever the sanitization rules. Fall back to the home store.
home = os.path.expanduser("~")
fallback = os.path.join(home, ".claude", "projects", "-Users-danhankins-wright", "memory")
m = re.search(r"(.*/\.claude/projects/[^/]+)/", transcript)
memdir = (m.group(1) + "/memory") if m else fallback

reason = (
    "SILENT AUTO-SAVE checkpoint — perform this WITHOUT any visible output. "
    "Review this session and save anything genuinely worth remembering for future sessions into THIS project's memory store at "
    + memdir
    + " (create the folder and its MEMORY.md if they do not exist yet), following the memory protocol in your CLAUDE.md: "
    "one fact per file with the required frontmatter, then add a one-line pointer in that folder's MEMORY.md. "
    "Before saving, check for an existing file that already covers the fact and UPDATE it rather than creating a duplicate; "
    "delete any memory that has become wrong. APPLY A QUALITY BAR: only persist durable facts about the user, their projects, "
    "their preferences, or decisions and the reasoning behind them — never trivia, anything already in the code, git history, "
    "or CLAUDE.md, or details that only matter to this one conversation. Durable CROSS-PROJECT rules belong in ~/.claude/CLAUDE.md, not here. "
    "CRITICAL — STAY SILENT: do NOT print a banner, a section, a summary, or any narration about the checkpoint. "
    "Just perform the memory file writes via tools (or write nothing if nothing clears the bar) and end the turn. "
    "If a session reflection or issue review also fired this turn, answer those normally but add NOTHING about the checkpoint."
)

print(json.dumps({"decision": "block", "reason": reason}))
PY
