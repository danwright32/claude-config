#!/usr/bin/env bash
# Tests for builder-project-rules-gate.sh (claude-config#3389).
#
# The builder agent type does not load the project's own CLAUDE.md, and Dan chose on 2026-11-25
# ("3.36.1 Add a guard (Recommended)") that a check holds a builder's first edit until it has read
# that file. What this holds the gate to:
#   1. only the builder type is held: the main session and every other agent type pass in silence;
#   2. a builder is held until its OWN transcript shows a read of the project's file that returned,
#      and the refusal names that file and the Read tool;
#   3. which file: CLAUDE.md at the root of the edited file's checkout, AGENTS.md where there is no
#      CLAUDE.md, the worktree's own copy in a worktree, nothing where the project has neither or
#      the edit is outside any repository;
#   4. it refuses, naming the file, when it cannot tell whether the file was read, and never
#      passes in silence on something it could not read;
#   5. it is registered for the four edit tools, failing closed.
# Every path here is a fixture under a temp folder.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/builder-project-rules-gate.sh"
. "$DIR/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
if [ ! -f "$HOOK" ]; then
  echo "test-builder-project-rules-gate: there is no builder-project-rules-gate.sh beside this suite at $DIR." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs builder-project-rules-gate.sh beside it"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

_tmp="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${_tmp%/}/builder-rules-gate.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

# The projects. A .git folder marks a checkout and a .git file a worktree; the gate reads neither.
P="$WORK/proj"; W="$WORK/proj/.claude/worktrees/wt"; A="$WORK/agentsmd"; BOTH="$WORK/both"; NONE="$WORK/neither"; OUT="$WORK/outside"
mkdir -p "$P/.git" "$P/src" "$W/src" "$A/.git" "$BOTH/.git" "$NONE/.git" "$OUT/notes"
printf 'gitdir: elsewhere\n' > "$W/.git"
printf '# project rules\n' > "$P/CLAUDE.md"; printf '# worktree rules\n' > "$W/CLAUDE.md"
printf '# agents rules\n' > "$A/AGENTS.md"
printf '# rules\n' > "$BOTH/CLAUDE.md"; printf '# agents\n' > "$BOTH/AGENTS.md"
ln -s "$P" "$WORK/link"

# A transcript: each argument is "<tool>|<path or command>|<ok, error, pending>".
transcript(){   # $1 = file  $2.. = entries
  local f="$1"; shift
  python3 -I - "$f" "$@" <<'PY'
import json, sys
out = open(sys.argv[1], "w")
for n, entry in enumerate(sys.argv[2:]):
    tool, what, result = entry.split("|")
    key = "command" if tool == "Bash" else "file_path"
    out.write(json.dumps({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": "t%d" % n, "name": tool, "input": {key: what}}]}}) + "\n")
    if result != "pending":
        out.write(json.dumps({"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": "t%d" % n, "is_error": result == "error", "content": "text"}]}}) + "\n")
PY
}
# A hook payload: key=value pairs; tool_input keys are written as in.<key>.
payload(){
  python3 -I - "$@" <<'PY'
import json, sys
d = {"hook_event_name": "PreToolUse", "tool_input": {}}
for pair in sys.argv[1:]:
    k, v = pair.split("=", 1)
    if k.startswith("in."):
        d["tool_input"][k[3:]] = v
    else:
        d[k] = v
print(json.dumps(d))
PY
}
run(){   # $1 = payload -> sets RC, ERR (stderr), SAID (stdout)
  SAID="$(printf '%s' "$1" | bash "$HOOK" 2> "$WORK/err.txt")"; RC=$?
  ERR="$(cat "$WORK/err.txt")"
}
passes_silently(){   # $1 = name  $2 = payload
  run "$2"
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ -z "$SAID" ]; then ok; else bad "$1 (exit $RC, said: $SAID $ERR)"; fi
}
held(){   # $1 = name  $2 = payload  $3.. = words the refusal must hold
  local name="$1" w; run "$2"; shift 2
  if [ "$RC" -ne 2 ]; then bad "$name (exit $RC, not a refusal; said: $SAID $ERR)"; return; fi
  for w in "$@"; do
    case "$ERR" in *"$w"*) ;; *) bad "$name (the refusal lacks '$w': $ERR)"; return ;; esac
  done
  ok
}
T="$WORK/t"; mkdir -p "$T"
builder(){   # $1 = transcript  $2.. = more pairs -> a builder's Edit payload
  local t="$1"; shift
  payload tool_name=Edit agent_id=a1 agent_type=builder "agent_transcript_path=$t" "transcript_path=$WORK/parent.jsonl" "cwd=$P" "$@"
}

# ---------------------------------------------------------------- 1. who is held
transcript "$T/none.jsonl" "Read|$P/src/other.txt|ok"
passes_silently "the main session passes in silence" "$(payload tool_name=Edit "in.file_path=$P/src/x.sh" "transcript_path=$T/none.jsonl" "cwd=$P")"
passes_silently "a general purpose agent that has read nothing passes in silence" \
  "$(payload tool_name=Edit agent_id=a1 agent_type=general-purpose "agent_transcript_path=$T/none.jsonl" "in.file_path=$P/src/x.sh" "cwd=$P")"
passes_silently "so does a plan agent" \
  "$(payload tool_name=Write agent_id=a1 agent_type=plan-redteam "agent_transcript_path=$T/none.jsonl" "in.file_path=$P/src/x.sh" "cwd=$P")"
held "a builder that has not read the project's file is held, and told which file and how" \
  "$(builder "$T/none.jsonl" "in.file_path=$P/src/x.sh")" "$P/CLAUDE.md" "Read tool" "builder agent type"
# The type from the record beside the transcript, where the payload carries no agent_type.
cp "$T/none.jsonl" "$T/agent-m1.jsonl"; printf '{"agentType": "builder"}\n' > "$T/agent-m1.meta.json"
held "a builder known only from the record beside its transcript is held too" \
  "$(payload tool_name=Edit agent_id=m1 "agent_transcript_path=$T/agent-m1.jsonl" "in.file_path=$P/src/x.sh" "cwd=$P")" "$P/CLAUDE.md"
cp "$T/none.jsonl" "$T/agent-m2.jsonl"; printf '{"agentType": "general-purpose"}\n' > "$T/agent-m2.meta.json"
passes_silently "another type known only from that record passes in silence" \
  "$(payload tool_name=Edit agent_id=m2 "agent_transcript_path=$T/agent-m2.jsonl" "in.file_path=$P/src/x.sh" "cwd=$P")"
cp "$T/none.jsonl" "$T/agent-m3.jsonl"
run "$(payload tool_name=Edit agent_id=m3 "agent_transcript_path=$T/agent-m3.jsonl" "in.file_path=$P/src/x.sh" "cwd=$P")"
if [ "$RC" -eq 0 ] && [[ "$SAID" == *systemMessage* ]] && [[ "$SAID" == *"DID NOT RUN"* ]] && [[ "$SAID" == *"agent type"* ]]; then ok
else bad "an agent whose type neither source gives is let through SAYING SO (exit $RC, said: $SAID $ERR)"; fi
# A session started as the type has no agent_id, and its own transcript is transcript_path.
held "a session started as the builder type is held on its own transcript" \
  "$(payload tool_name=Edit agent_type=builder "transcript_path=$T/none.jsonl" "in.file_path=$P/src/x.sh" "cwd=$P")" "$P/CLAUDE.md"
passes_silently "a builder's call of a tool that is not an edit is not this gate's" \
  "$(payload tool_name=Read agent_id=a1 agent_type=builder "agent_transcript_path=$T/none.jsonl" "in.file_path=$P/src/x.sh" "cwd=$P")"

# ---------------------------------------------------------------- 2. what counts as read
transcript "$T/read.jsonl" "Read|$P/src/other.txt|ok" "Read|$P/CLAUDE.md|ok"
passes_silently "a builder that has read the project's file edits" "$(builder "$T/read.jsonl" "in.file_path=$P/src/x.sh")"
passes_silently "and writes a new file in a folder that does not exist yet" \
  "$(payload tool_name=Write agent_id=a1 agent_type=builder "agent_transcript_path=$T/read.jsonl" "in.file_path=$P/new/deeper/x.sh" "cwd=$P")"
transcript "$T/error.jsonl" "Read|$P/CLAUDE.md|error"
held "a read that returned an error is not a read" "$(builder "$T/error.jsonl" "in.file_path=$P/src/x.sh")" "$P/CLAUDE.md"
transcript "$T/pending.jsonl" "Read|$P/CLAUDE.md|pending"
held "a read whose result is not in the transcript yet is not a read yet" "$(builder "$T/pending.jsonl" "in.file_path=$P/src/x.sh")" "$P/CLAUDE.md" "same message"
transcript "$T/shell.jsonl" "Bash|cat $P/CLAUDE.md|ok"
held "a read through the shell does not count" "$(builder "$T/shell.jsonl" "in.file_path=$P/src/x.sh")" "$P/CLAUDE.md"
transcript "$T/link.jsonl" "Read|$WORK/link/CLAUDE.md|ok"
passes_silently "a read of the same file by another path to it counts" "$(builder "$T/link.jsonl" "in.file_path=$P/src/x.sh")"
held "a new file in a new folder is held like any other edit" \
  "$(payload tool_name=Write agent_id=a1 agent_type=builder "agent_transcript_path=$T/none.jsonl" "in.file_path=$P/new/deeper/x.sh" "cwd=$P")" "$P/CLAUDE.md"
held "a notebook edit is held" \
  "$(payload tool_name=NotebookEdit agent_id=a1 agent_type=builder "agent_transcript_path=$T/none.jsonl" "in.notebook_path=$P/src/n.ipynb" "cwd=$P")" "$P/CLAUDE.md"
held "a file named by a relative path is read against the payload's folder" \
  "$(builder "$T/none.jsonl" "in.file_path=src/x.sh")" "$P/CLAUDE.md"
# The transcript derived from the parent's, where the payload names none.
mkdir -p "$WORK/parent/subagents"; cp "$T/read.jsonl" "$WORK/parent/subagents/agent-d1.jsonl"
passes_silently "the agent's own transcript is found beside the parent's when the payload names none" \
  "$(payload tool_name=Edit agent_id=d1 agent_type=builder "transcript_path=$WORK/parent.jsonl" "in.file_path=$P/src/x.sh" "cwd=$P")"
# The parent's transcript is never the one read: a read recorded there is not this agent's.
cp "$T/read.jsonl" "$WORK/parent.jsonl"
held "a read in the PARENT's transcript is not this agent's read" "$(builder "$T/none.jsonl" "in.file_path=$P/src/x.sh")" "$P/CLAUDE.md"

# ---------------------------------------------------------------- 3. which file
held "in a worktree the file is the worktree's own copy, and the main checkout's does not stand in" \
  "$(builder "$T/read.jsonl" "in.file_path=$W/src/x.sh")" "$W/CLAUDE.md"
transcript "$T/wt.jsonl" "Read|$W/CLAUDE.md|ok"
passes_silently "and reading the worktree's copy lets the edit through" "$(builder "$T/wt.jsonl" "in.file_path=$W/src/x.sh")"
held "a project with only AGENTS.md is held to that file" "$(builder "$T/none.jsonl" "in.file_path=$A/x.sh")" "$A/AGENTS.md"
transcript "$T/agents.jsonl" "Read|$A/AGENTS.md|ok" "Read|$BOTH/AGENTS.md|ok"
passes_silently "and reading it lets the edit through" "$(builder "$T/agents.jsonl" "in.file_path=$A/x.sh")"
held "a project with both is held to CLAUDE.md, and AGENTS.md does not stand in" "$(builder "$T/agents.jsonl" "in.file_path=$BOTH/x.sh")" "$BOTH/CLAUDE.md"
passes_silently "a project with neither file passes" "$(builder "$T/none.jsonl" "in.file_path=$NONE/x.sh")"
passes_silently "an edit outside any repository passes" "$(builder "$T/none.jsonl" "in.file_path=$OUT/notes/pr-body.md")"

# ---------------------------------------------------------------- 4. it refuses what it cannot tell
held "a builder whose transcript cannot be found is refused, naming the file" \
  "$(payload tool_name=Edit agent_id=a9 agent_type=builder "agent_transcript_path=$T/no-such.jsonl" "in.file_path=$P/src/x.sh" "cwd=$P")" "$P/CLAUDE.md" "could not tell"
held "a builder's edit naming no file is refused" \
  "$(payload tool_name=Edit agent_id=a1 agent_type=builder "agent_transcript_path=$T/read.jsonl" "cwd=$P")" "could not tell"
mkdir -p "$WORK/nolib/lib"; cp "$HOOK" "$WORK/nolib/"; cp "$DIR/lib/hook-notice.sh" "$WORK/nolib/lib/" 2>/dev/null
SAID="$(builder "$T/read.jsonl" "in.file_path=$P/src/x.sh" | bash "$WORK/nolib/builder-project-rules-gate.sh" 2> "$WORK/err.txt")"; RC=$?
if [ "$RC" -eq 2 ] && grep -q "could not tell" "$WORK/err.txt" && grep -qF "$P/CLAUDE.md" "$WORK/err.txt"; then ok
else bad "with its transcript reader missing a builder is refused, never passed (exit $RC: $(cat "$WORK/err.txt"))"; fi
run 'not json at all "agent_id" "agent_type"'
if [ "$RC" -eq 0 ] && [[ "$SAID" == *systemMessage* ]] && [[ "$SAID" == *"DID NOT RUN"* ]]; then ok
else bad "a payload it cannot read is let through SAYING SO, never in silence (exit $RC, said: $SAID $ERR)"; fi

# ---------------------------------------------------------------- 5. registered, failing closed
reg="$(python3 -I - "$DIR/../settings.hooks.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
groups = [g for g in d.get("hooks", {}).get("PreToolUse", [])
          if any("builder-project-rules-gate.sh" in h.get("command", "") for h in g.get("hooks", []))]
if len(groups) != 1:
    print("%d PreToolUse groups run builder-project-rules-gate.sh" % len(groups)); sys.exit()
g = groups[0]
tools = set(g.get("matcher", "").split("|"))
if tools != {"Edit", "Write", "MultiEdit", "NotebookEdit"}:
    print("its matcher is %s" % g.get("matcher")); sys.exit()
h = [h for h in g["hooks"] if "builder-project-rules-gate.sh" in h.get("command", "")][0]
if h.get("onFailure") != "block":
    print("it is not registered with onFailure block"); sys.exit()
print("ok")
PY
)"
if [ "$reg" = ok ]; then ok; else bad "the gate is registered for the four edit tools, failing closed ($reg)"; fi

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
