#!/usr/bin/env bash
#
# builder-project-rules-gate.sh
# Claude Code PreToolUse(Edit|Write|MultiEdit|NotebookEdit) hook: hold an edit by an agent of the
# builder type until that agent has read the project's own CLAUDE.md, or its AGENTS.md where the
# project has no CLAUDE.md (claude-config#3389).
#
# WHY. The builder agent type (skills/orchestrate/render-builder-type.py) starts with
# omitClaudeMd, which is all or nothing: it leaves out the project's own instructions together
# with the global rule files. The type's opening words tell a builder to read the project's file
# before any other work, and a rule that lives only in a prompt is a hope (L27). Dan chose on
# 2026-11-25 ("3.36.1 Add a guard (Recommended)") that a check holds a builder's first edit until
# it has read that file. It ships in the same change as the step that writes the type on a Mac, so
# the type never runs without it.
#
# WHO IS HELD: only an agent whose type is "builder". The type is read from the payload's
# agent_type, which the hooks documentation says is present inside a subagent call and for a
# session started with --agent. Where a subagent's payload carries no agent_type, it is read from
# the record Claude Code writes beside the agent's own transcript (agent-<id>.meta.json, its
# agentType): measured on the personal MacBook on 2026-11-26, all 502 subagent runs of one session
# had that record with the field. So the guard does not go quiet if the payload field is absent
# (L506). A subagent whose type neither source gives is let through, SAYING SO, since it cannot be
# held as a builder on no evidence. The main session and every other agent type pass in silence.
#
# WHICH FILE: the edit's own project. The folder holding the file being edited is walked upward to
# the first one holding .git (a folder in a checkout, a file in a worktree), and that root's
# CLAUDE.md is the file, or its AGENTS.md when it has no CLAUDE.md. So a builder in a worktree is
# held to the worktree's copy, which is the one cut from the branch it builds on. An edit outside
# any repository (the builder's notes folder, the scratchpad) passes, and so does an edit in a
# project that has neither file: there is nothing to read.
#
# WHAT COUNTS AS HAVING READ IT: a call of the Read tool on that file, in the agent's OWN
# transcript, whose result is recorded there and is not an error (lib/agent-overrides.py
# files_read, the one reader of an agent's calls). A read of part of the file counts, since a file
# too long for one read can only be read in parts. A read through the shell does not: the refusal
# names the Read tool, and a shell command's text is not a reliable record of what was read. A
# read whose result has not reached the transcript yet (sent in the same message as the edit) is
# not a read yet, so that edit is held and goes through when sent again.
#
# THE TRANSCRIPT is the agent's own, never the parent's (hooks/review/subagent-harvest.md):
# agent_transcript_path when the payload carries it, else <the parent transcript without
# .jsonl>/subagents/agent-<id>.jsonl, where Claude Code writes it. A session started as the type
# has no agent_id, and its own transcript is transcript_path.
#
# IT REFUSES WHEN IT CANNOT TELL, for a builder: no transcript it can read, no file path on the
# call, a reader that fails. Never a silent pass (L98). The refusal names the file to read. What it
# cannot read at all is the payload itself, and then it cannot know a builder is calling: that is
# let through saying so, in a systemMessage (lib/hook-notice.sh), as the other gates do.
#
# COST. The main session never reaches python3: a payload naming neither agent_id nor agent_type
# leaves at the first line. Another agent type costs one parse. Only a builder's edit reads a
# transcript.

set -uo pipefail
payload="$(cat 2>/dev/null || true)"
case "$payload" in *'"agent_id"'*|*'"agent_type"'*) ;; *) exit 0 ;; esac
# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
# shellcheck source=lib/hook-notice.sh
. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && payload="$(ps_clean_payload "$payload")"

verdict="$(printf '%s' "$payload" | BUILDER_RULES_GATE_LIB="$HOOK_DIR/lib/agent-overrides.py" python3 -c '
import importlib.util, json, os, sys
sys.stdout.reconfigure(errors="replace")
BUILDER_TYPE = "builder"  # the agent type skills/orchestrate/render-builder-type.py renders
EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
def out(*parts):
    print("\x1f".join(str(p).replace("\x1f", " ").replace("\n", " ") for p in parts)); sys.exit()
try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
except Exception as e:
    out("unreadable", type(e).__name__)
if not isinstance(d, dict):
    out("unreadable", "the payload is not a JSON object")
agent = d.get("agent_id") if isinstance(d.get("agent_id"), str) else ""
# The agent own transcript, never the parent one.
own = ""
if "agent_id" in d:
    t = d.get("agent_transcript_path")
    if isinstance(t, str) and t and os.path.isfile(t):
        own = t
    else:
        parent = d.get("transcript_path")
        if isinstance(parent, str) and parent.endswith(".jsonl") and agent:
            own = os.path.join(parent[:-len(".jsonl")], "subagents", "agent-" + agent + ".jsonl")
else:
    t = d.get("transcript_path")
    own = t if isinstance(t, str) else ""
kind = d.get("agent_type")
if not (isinstance(kind, str) and kind):
    if "agent_id" not in d:
        out("allow")
    kind = None
    if own.endswith(".jsonl"):
        try:
            with open(own[:-len(".jsonl")] + ".meta.json", encoding="utf-8", errors="replace") as f:
                meta = json.load(f)
            if isinstance(meta, dict) and isinstance(meta.get("agentType"), str) and meta["agentType"]:
                kind = meta["agentType"]
        except (OSError, ValueError):
            pass
    if kind is None:
        out("untyped", agent or "?")
if kind != BUILDER_TYPE:
    out("allow")
tool = d.get("tool_name") if isinstance(d.get("tool_name"), str) else ""
if tool not in EDIT_TOOLS:
    out("allow")
# From here a builder is editing, so a fault in this check holds the edit and never passes it.
def crashed(kind_of, error, trace):
    print("\x1f".join(["unsure", tool, "", "the check itself failed (%s)" % kind_of.__name__]))
sys.excepthook = crashed
ti = d.get("tool_input")
path = None
if isinstance(ti, dict):
    path = ti.get("file_path") if isinstance(ti.get("file_path"), str) and ti.get("file_path") else ti.get("notebook_path")
if not (isinstance(path, str) and path):
    out("unsure", tool, "", "the call names no file path, so which project it edits could not be told")
if not os.path.isabs(path):
    cwd = d.get("cwd")
    if not (isinstance(cwd, str) and os.path.isabs(cwd)):
        out("unsure", tool, "", "the call names the file by a relative path and the hook payload gives no folder to read it against")
    path = os.path.join(cwd, path)
# The project: the first folder, from the edited file upward, that holds .git.
here = os.path.dirname(os.path.realpath(path))
root = None
while True:
    if os.path.lexists(os.path.join(here, ".git")):
        root = here
        break
    up = os.path.dirname(here)
    if up == here:
        break
    here = up
if root is None:
    out("allow")
need = None
for name in ("CLAUDE.md", "AGENTS.md"):
    if os.path.isfile(os.path.join(root, name)):
        need = os.path.join(root, name)
        break
if need is None:
    out("allow")
if not own or not os.path.isfile(own):
    out("unsure", tool, need, "this agent own transcript could not be found (%s)" % (own or "the hook payload names none"))
try:
    spec = importlib.util.spec_from_file_location("agent_overrides", os.environ["BUILDER_RULES_GATE_LIB"])
    lib = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lib)
    read = lib.files_read(own)
except Exception as e:
    out("unsure", tool, need, "the reader of this agent transcript failed (%s)" % type(e).__name__)
for p in read:
    if not os.path.isabs(p):
        continue
    try:
        if os.path.samefile(p, need):
            out("allow")
    except OSError:
        continue
out("hold", tool, need, len(read))
' 2>&1)"

IFS=$'\x1f' read -r what a b c <<< "$verdict"
case "$what" in
  allow) exit 0 ;;
  hold)
    echo "HELD (builder-project-rules-gate.sh): you run as the builder agent type, which does not load the project's own instructions, and your transcript shows no read of $b (it shows $c file(s) read with the Read tool, none of them that one). Read that file with the Read tool, the whole of it, and follow it as you follow your other rules. Then send this $a call again exactly as it was. A read sent in the same message as the edit does not count until its result is back, so send the edit after it (claude-config#3389)." >&2
    exit 2
    ;;
  unsure)
    if [ -n "$b" ]; then
      echo "HELD (builder-project-rules-gate.sh): you run as the builder agent type, which does not load the project's own instructions, and this check could not tell whether you have read $b: $c. It holds an edit it cannot check. Read that file with the Read tool, the whole of it, then send this $a call again exactly as it was. If it is held again with these same words after you have read the file, the check cannot see your reads: stop editing, and say so in your hand back, quoting this message (claude-config#3389)." >&2
    else
      echo "HELD (builder-project-rules-gate.sh): you run as the builder agent type, which does not load the project's own instructions, and this check could not tell which project this $a call edits: $c. It holds an edit it cannot check. Name the file by its absolute path and send the call again; before that, read the CLAUDE.md at the root of the repository you are editing, or its AGENTS.md where it has no CLAUDE.md, with the Read tool (claude-config#3389)." >&2
    fi
    exit 2
    ;;
  untyped)
    hook_allow_notice "BUILDER PROJECT RULES CHECK DID NOT RUN: builder-project-rules-gate.sh could not tell which agent type agent $a is (the hook payload carries no agent_type, and the record beside its transcript gave none), so this edit was let through without checking that a builder had read the project's CLAUDE.md."
    ;;
  unreadable)
    hook_allow_notice "BUILDER PROJECT RULES CHECK DID NOT RUN: builder-project-rules-gate.sh could not read the hook payload ($a), so this edit was let through without checking that a builder had read the project's CLAUDE.md."
    ;;
  *)
    hook_allow_notice "BUILDER PROJECT RULES CHECK DID NOT RUN: builder-project-rules-gate.sh failed (${verdict//$'\n'/ }), so this edit was let through without checking that a builder had read the project's CLAUDE.md."
    ;;
esac
