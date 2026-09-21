#!/usr/bin/env bash
#
# scratchpad-subagent-gate.sh
# Claude Code PreToolUse(Write|Bash) hook: refuse a SUBAGENT writing a file straight into the
# session's scratchpad directory, rather than into a subdirectory of its own (claude-config#527).
#
# Every agent a session dispatches is handed the SAME scratchpad. On 2026-09-21 in Slate, the agent
# for slate#2572 wrote pr-body.md there and its sibling for slate#2571 overwrote it with its own PR
# body between the Write and the `gh pr create` that read it. It was caught only because the
# harness said the file had changed on disk; otherwise PR #2586 would have carried PR #2585's
# description, and a wrong body on a PR reads as deliberate. A generic name in a shared folder is a
# collision waiting for the first two agents that pick the same obvious name, and a rule telling
# them not to lives only in a prompt (L27).
#
# So a subagent's write directly into the scratchpad ROOT is refused, and the refusal names the
# exact path to use instead: the same file under <scratchpad>/<its agent id>/. ANY subdirectory is
# allowed, because a brief that says "write to scratchpad/2572/" is already doing the right thing.
# The main thread is left alone: it has no sibling to collide with, and it is where a file meant
# for every agent to READ is written.
#
# WHO IS CALLING is read from `agent_id`, present only inside a subagent (measured 2026-09-17, see
# playwright-subagent-gate.sh). A SCRATCHPAD is a directory named `scratchpad` under the harness's
# per user temp folder, /tmp/claude-<uid>/ or its /private spelling, so a project folder that
# happens to be called scratchpad is not touched.
#
# Bash is covered for the shapes that CREATE a file, a redirect (> or >>) and tee, because agents
# write through the shell as often as through Write. It is a scan of the command text, so a write
# spelled another way (a script that opens the file itself, cp, a variable holding the path) is not
# seen; it narrows the collision, it does not prove one impossible.
#
# Fails OPEN on a payload it cannot read, loudly: refusing would stop every write in the session
# with no remedy inside it, and silence would leave the gate off with everything looking normal.

set -uo pipefail

payload="$(cat 2>/dev/null || true)"

# It runs on every Bash call in every session, so the common case leaves before python starts: a
# payload that names no agent id or no scratchpad cannot be a subagent writing into one. A payload
# too broken to contain either is still one this gate cannot judge, and says so below.
case "$payload" in
  *'"agent_id"'*scratchpad*|*scratchpad*'"agent_id"'*) ;;
  *'"tool_name"'*) exit 0 ;;
esac

verdict="$(printf '%s' "$payload" | python3 -c '
import json, os, re, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("unreadable\t" + type(e).__name__); sys.exit()
if not isinstance(d, dict):
    print("unreadable\tthe payload is not a JSON object"); sys.exit()
tool = d.get("tool_name")
if tool not in ("Write", "Bash") or "agent_id" not in d:
    print("allow\t"); sys.exit()
agent = str(d.get("agent_id") or "agent")
inp = d.get("tool_input") or {}
# A scratchpad ROOT file: <temp>/claude-<uid>/<project>/<session>/scratchpad/<name>, nothing deeper.
ROOT_FILE = r"(?:/private)?/tmp/claude-[0-9]+/[^/\s\"\x27]+/[^/\s\"\x27]+/scratchpad/[^/\s\"\x27]+"
def suggest(path):
    head, name = os.path.split(path)
    return os.path.join(head, agent, name)
targets = []
if tool == "Write":
    p = inp.get("file_path") or ""
    if re.fullmatch(ROOT_FILE, p):
        targets.append(p)
else:
    cmd = inp.get("command") or ""
    # The target of a redirect or of tee, quoted or not.
    # The path has to END where the shell word ends, or a file deeper down matches as its own
    # first directory.
    for m in re.finditer(r"(?:>>?|\btee(?:\s+-a)?)\s*[\"\x27]?(" + ROOT_FILE + r")(?=$|[\s\"\x27;|&)<>])", cmd):
        targets.append(m.group(1))
if not targets:
    print("allow\t"); sys.exit()
print("refuse\t" + "; ".join("%s -> %s" % (t, suggest(t)) for t in dict.fromkeys(targets)))
' 2>&1)"

case "$verdict" in
  refuse$'\t'*)
    echo "REFUSED: a subagent is writing straight into the scratchpad every agent in this session shares, where a sibling picking the same name overwrites it between your write and your read (claude-config#527). Write it in a subdirectory of your own instead: ${verdict#*$'\t'}. Create the directory first (mkdir -p), and read the file back from that same path." >&2
    exit 2
    ;;
  allow$'\t'*)
    exit 0
    ;;
  unreadable$'\t'*)
    echo "SCRATCHPAD SUBAGENT GATE DID NOT RUN: scratchpad-subagent-gate.sh could not read the hook payload (${verdict#*$'\t'}), so this write was let through without checking whether a subagent was writing into the shared scratchpad." >&2
    exit 0
    ;;
  *)
    echo "SCRATCHPAD SUBAGENT GATE DID NOT RUN: scratchpad-subagent-gate.sh failed ($(printf '%s' "$verdict" | tr '\n' ' ')), so this write was let through without checking whether a subagent was writing into the shared scratchpad." >&2
    exit 0
    ;;
esac
