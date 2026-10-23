#!/usr/bin/env bash
# Tests for the gate that refuses an unscoped `git add` in a shared checkout (claude-config#366).
#
# CLAUDE.md already said to scope every `git add` to named paths, never `-A` or `.`, because a
# checkout is routinely shared by concurrent sessions. Nothing enforced it. On 2026-09-10 a session
# working on claude-config#362 committed with an unscoped add and carried another session's half
# finished generator change and its six tests into commits 580842f and after, under a message that
# does not describe them, and pushed them. The work was correct so nothing broke, but it was judged
# by a test gate that was not asked about it and it is recorded as somebody else's change. A rule
# that lives only in a prompt is a hope (L27).
#
# The transcript is a REAL jsonl file in the shape Claude Code writes, because what the gate reads
# out of it is the whole question, and a stub would only confirm this suite's own assumption about
# that shape (L52).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-add-scope.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "test-check-add-scope: there is no check-add-scope.sh beside this suite at $DIR." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs check-add-scope.sh beside it"
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 2
fi

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/check-add-scope.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"' EXIT

REPO="$FIX/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@e
git -C "$REPO" config user.name t
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add seed.txt
git -C "$REPO" -c commit.gpgsign=false commit -q -m seed

STATE="$FIX/state"; mkdir -p "$STATE"
TR="$FIX/transcript.jsonl"

# One transcript line in the shape Claude Code writes: a tool_use block inside an assistant message.
mention_edit(){ # mention_edit <file path>
  python3 -c '
import json, sys
print(json.dumps({"type": "assistant", "message": {"content": [
    {"type": "tool_use", "name": "Edit", "input": {"file_path": sys.argv[1]}}]}}))
' "$1" >> "$TR"
}
mention_bash(){ # mention_bash <command>
  python3 -c '
import json, sys
print(json.dumps({"type": "assistant", "message": {"content": [
    {"type": "tool_use", "name": "Bash", "input": {"command": sys.argv[1]}}]}}))
' "$1" >> "$TR"
}
fresh_cache(){ rm -f "$STATE"/claude-add-scope-* 2>/dev/null; }

RC=0; OUT=""
run(){ # run <command> [transcript]
  local tr="${2-$TR}"
  OUT="$(python3 -c '
import json, sys
d = {"tool_name": "Bash", "cwd": sys.argv[2], "tool_input": {"command": sys.argv[1]}}
if sys.argv[3]:
    d["transcript_path"] = sys.argv[3]
print(json.dumps(d))
' "$1" "$REPO" "$tr" | env CLAUDE_ADD_SCOPE_STATE_DIR="$STATE" bash "$HOOK" 2>&1)"; RC=$?
}
refused(){ if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, said: ${OUT:0:200}"; fi; }
allowed(){ if [ "$RC" -eq 0 ] && [ -z "$(printf '%s' "$OUT" | tr -d '[:space:]')" ]; then check "$1" ok
           else check "$1" "exit $RC, said: ${OUT:0:200}"; fi; }
says(){ case "$OUT" in *"$2"*) check "$1" ok ;; *) check "$1" "did not say '$2'" ;; esac; }
silentabout(){ case "$OUT" in *"$2"*) check "$1" "it named '$2'" ;; *) check "$1" ok ;; esac; }

echo "check add scope: a checkout this session is alone in"

# The control FIRST, and it matters more than the refusal: an unscoped add is fine when a session
# is alone, and a gate that fires on the ordinary case is one nobody reads (L36, L104).
printf 'mine\n' > "$REPO/mine.txt"
mention_edit "$REPO/mine.txt"
fresh_cache
run "git add -A"
allowed "an unscoped add is allowed when every change is this session's"
run "git add ."
allowed "and so is a bare dot"

# A file this session wrote through a Bash heredoc rather than an Edit. A great deal of this
# repo's own editing happens that way, and a gate that could only see Edit calls would call all of
# it foreign and be turned off within the hour.
printf 'via bash\n' > "$REPO/viabash.txt"
mention_bash "cat > $REPO/viabash.txt <<'EOF'
via bash
EOF"
fresh_cache
run "git add -A"
allowed "a file this session wrote through a Bash command is this session's too"

echo "check add scope: a file this session wrote by script, never naming it (claude-config#585)"

# In an Ovation worktree on 2026-09-26 this gate called a session's own python and sed output
# another session's, because the script that wrote those files never named them in its command. A
# file whose change happened WHILE one of this session's own Bash calls was running is this
# session's, judged by the times Claude Code records around every call, not by the words.
bash_call(){ # bash_call <id> <command> <start epoch> <end epoch>
  python3 -c '
import json, sys, datetime
def iso(t):
    return datetime.datetime.fromtimestamp(float(t), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
print(json.dumps({"type": "assistant", "timestamp": iso(sys.argv[3]), "message": {"content": [
    {"type": "tool_use", "id": sys.argv[1], "name": "Bash", "input": {"command": sys.argv[2]}}]}}))
print(json.dumps({"type": "user", "timestamp": iso(sys.argv[4]), "message": {"content": [
    {"type": "tool_result", "tool_use_id": sys.argv[1], "content": "ok"}]}}))
' "$@" >> "$TR"
}
read_call(){ # read_call <id> <start epoch> <end epoch>: a call that is not Bash, over the same kind of window
  python3 -c '
import json, sys, datetime
def iso(t):
    return datetime.datetime.fromtimestamp(float(t), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
print(json.dumps({"type": "assistant", "timestamp": iso(sys.argv[2]), "message": {"content": [
    {"type": "tool_use", "id": sys.argv[1], "name": "Read", "input": {"limit": 5}}]}}))
print(json.dumps({"type": "user", "timestamp": iso(sys.argv[3]), "message": {"content": [
    {"type": "tool_result", "tool_use_id": sys.argv[1], "content": "ok"}]}}))
' "$@" >> "$TR"
}
set_mtime(){ python3 -c 'import os, sys; t = float(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"; }

now="$(date +%s)"
bash_call t585a "python3 $FIX/gen.py" "$((now - 600))" "$((now - 590))"
printf 'generated\n' > "$REPO/generated.txt"
set_mtime "$REPO/generated.txt" "$((now - 595))"
fresh_cache
run "git add -A"
allowed "a file changed while this session's own script ran is this session's"
# The control: the same kind of file, changed long after that call ended, is still foreign.
printf 'later\n' > "$REPO/later.txt"
set_mtime "$REPO/later.txt" "$((now - 300))"
fresh_cache
run "git add -A"
refused "a file changed outside every one of this session's Bash calls is still foreign"
says "and it is the one named" "later.txt"
silentabout "and the scripted file is not accused" "  generated.txt"
# Only a Bash call writes files by script: a Read running over the same moment does not credit it.
rm -f "$REPO/later.txt"
read_call t585b "$((now - 200))" "$((now - 190))"
printf 'during read\n' > "$REPO/duringread.txt"
set_mtime "$REPO/duringread.txt" "$((now - 195))"
fresh_cache
run "git add -A"
refused "a file changed while only a Read was running is not credited"
says "and it is named" "duringread.txt"
rm -f "$REPO/duringread.txt" "$REPO/generated.txt"
# Read incrementally like the mentions: a call recorded after the cache was last topped up counts.
bash_call t585c "python3 $FIX/gen2.py" "$((now - 100))" "$((now - 90))"
printf 'second\n' > "$REPO/second.txt"
set_mtime "$REPO/second.txt" "$((now - 95))"
run "git add -A"
allowed "a scripted write recorded after the last read of the transcript is credited too"
rm -f "$REPO/second.txt"
# A file the session's script DELETED has nothing left to stat, so it is judged by the directory it
# was removed from, whose modification time the removal sets.
mkdir -p "$REPO/gone"; printf 'x\n' > "$REPO/gone/old.txt"
git -C "$REPO" add gone/old.txt; git -C "$REPO" -c commit.gpgsign=false commit -q -m gone
bash_call t585d "python3 $FIX/clean.py" "$((now - 80))" "$((now - 70))"
rm -f "$REPO/gone/old.txt"
set_mtime "$REPO/gone" "$((now - 75))"
fresh_cache
run "git add -A"
allowed "a file this session's script deleted is this session's too"
git -C "$REPO" -c commit.gpgsign=false commit -q -am "gone removed" >/dev/null 2>&1 || true
# A record whose message is not an object (a plain string, as some record kinds carry) must not
# abort the read: every mention in the same chunk would be lost, and this session's own files called
# foreign (lessons review of #799, L215).
printf '{"type": "summary", "timestamp": "2026-10-05T20:00:00Z", "message": "a plain string"}\n' >> "$TR"
printf 'after odd\n' > "$REPO/afterodd.txt"
mention_edit "$REPO/afterodd.txt"
fresh_cache
run "git add -A"
allowed "a transcript record whose message is a plain string does not lose the session's mentions"
rm -f "$REPO/afterodd.txt"

echo "check add scope: a subagent's own work, read from its own transcript (claude-config#1513)"

# On 2026-10-22 a Bidspoke agent in its own isolated worktree was refused three times over files it
# had written itself, and overrode the gate each time. Measured the same day (Claude Code 2.1.307):
# a subagent's PreToolUse payload carries `transcript_path` naming the DISPATCHING session's
# transcript, plus `agent_id`, and the agent's own tool calls live in
# <that transcript minus .jsonl>/subagents/agent-<agent_id>.jsonl, beside an .meta.json naming the
# worktree it was spawned with. Reading only the parent's record called every file the agent wrote,
# through Edit or by script, another session's. The layout below is that real one.
PROJ="$FIX/projects/proj"; mkdir -p "$PROJ/sess1/subagents"
PARENT_TR="$PROJ/sess1.jsonl"; : > "$PARENT_TR"
AGENT_ID="a1513aaaaaaaaaaaa"
AGENT_TR="$PROJ/sess1/subagents/agent-$AGENT_ID.jsonl"; : > "$AGENT_TR"
SIBLING_ID="a1513bbbbbbbbbbbb"
SIBLING_TR="$PROJ/sess1/subagents/agent-$SIBLING_ID.jsonl"; : > "$SIBLING_TR"
run_agent(){ # run_agent <command> <agent id> [repo to run in]
  OUT="$(python3 -c '
import json, sys
d = {"tool_name": "Bash", "cwd": sys.argv[2], "tool_input": {"command": sys.argv[1]},
     "transcript_path": sys.argv[3], "session_id": "sess1", "agent_id": sys.argv[4],
     "agent_type": "general-purpose"}
print(json.dumps(d))
' "$1" "${3:-$REPO}" "$PARENT_TR" "$2" | env CLAUDE_ADD_SCOPE_STATE_DIR="$STATE" bash "$HOOK" 2>&1)"; RC=$?
}
write_meta(){ # write_meta <agent id> <worktree path> <spawned with worktree: true|false>
  python3 -c '
import json, sys
print(json.dumps({"agentType": "general-purpose", "worktreePath": sys.argv[2],
                  "spawnedWithWorktree": sys.argv[3] == "true", "spawnDepth": 1}))
' "$1" "$2" "$3" > "$PROJ/sess1/subagents/agent-$1.meta.json"
}
# A repository of its own, so the tree holds only what each case puts there and the cases after
# this section find the shared one as they left it.
REPO_BEFORE_1513="$REPO"; REPO="$FIX/repo1513"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@e
git -C "$REPO" config user.name t
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add seed.txt
git -C "$REPO" -c commit.gpgsign=false commit -q -m seed

TR_SAVED="$TR"; TR="$AGENT_TR"
printf 'agent edit\n' > "$REPO/agentedit.txt"
mention_edit "$REPO/agentedit.txt"
fresh_cache
run_agent "git add -A" "$AGENT_ID"
allowed "#1513 a file a subagent wrote through Edit is that subagent's, from its own transcript"
now="$(date +%s)"
bash_call t1513a "python3 $FIX/convert.py" "$((now - 500))" "$((now - 490))"
printf 'converted\n' > "$REPO/converted.txt"
set_mtime "$REPO/converted.txt" "$((now - 495))"
fresh_cache
run_agent "git add -A" "$AGENT_ID"
allowed "#1513 a file a subagent's own script wrote, never naming it, is that subagent's"
TR="$TR_SAVED"
# The controls in the SHARED checkout: another session's file, and a file only a SIBLING agent
# mentioned, are still refused. A sibling is a concurrent worker in the same tree, which is the
# hazard this gate exists for, so its transcript is never read for the caller.
printf 'stranger\n' > "$REPO/stranger.txt"
set_mtime "$REPO/stranger.txt" "$((now - 300))"
fresh_cache
run_agent "git add -A" "$AGENT_ID"
refused "#1513 control: another session's file in the shared checkout is still refused for a subagent"
says "and it is the one named" "stranger.txt"
silentabout "and the subagent's own scripted file is not accused" "  converted.txt"
rm -f "$REPO/stranger.txt"
TR="$SIBLING_TR"
printf 'sibling\n' > "$REPO/sibling.txt"
set_mtime "$REPO/sibling.txt" "$((now - 300))"
mention_edit "$REPO/sibling.txt"
TR="$TR_SAVED"
fresh_cache
run_agent "git add -A" "$AGENT_ID"
refused "#1513 control: a file only a sibling agent wrote is not credited to this one"
says "and it is named" "sibling.txt"
rm -f "$REPO/sibling.txt"
# The dispatching session's own record still counts, as it always has.
printf 'parent\n' > "$REPO/parentedit.txt"
TR="$PARENT_TR"; mention_edit "$REPO/parentedit.txt"; TR="$TR_SAVED"
fresh_cache
run_agent "git add -A" "$AGENT_ID"
allowed "#1513 a file the dispatching session wrote is still credited to its subagent, as before"
git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" -c commit.gpgsign=false commit -q -m "agent files" >/dev/null 2>&1

# A subagent whose own transcript is not on disk (a nested agent's never is) is judged on the
# parent's record alone, the refusing direction, and the refusal says why.
printf 'nested\n' > "$REPO/nested.txt"
fresh_cache
run_agent "git add -A" "a1513cccccccccccc"
refused "#1513 a subagent whose own transcript is missing is still refused over an unmentioned file"
says "and says its own transcript was not found" "own transcript"
# An agent id that tries to walk out of the subagents folder reads nothing. The fixture makes the
# walk land on a real transcript that mentions the file, so only the plain name check refuses it.
mkdir -p "$PROJ/sess1/subagents/agent-x"
TR="$PROJ/sess1/elsewhere.jsonl"; mention_edit "$REPO/nested.txt"; TR="$TR_SAVED"
fresh_cache
run_agent "git add -A" "x/../../elsewhere"
refused "#1513 an agent id that is a path reads no file outside the subagents folder"
rm -f "$REPO/nested.txt"

echo "check add scope: a worktree a subagent was spawned with is its own (claude-config#1513)"

# An isolated agent worktree belongs to the one agent Claude Code created it for, and its
# .meta.json says which: every change in it is that agent's, including what a background process it
# started wrote after the call had returned, which no time window can see.
WT="$FIX/wt-agent"
git -C "$REPO" worktree add -q -b wt-agent "$WT" >/dev/null 2>&1
printf 'background output\n' > "$WT/bg.txt"
set_mtime "$WT/bg.txt" "$((now - 50000))"
write_meta "$AGENT_ID" "$WT" true
fresh_cache
run_agent "git add -A" "$AGENT_ID" "$WT"
allowed "#1513 an unmentioned file in the worktree this subagent was spawned with is its own"
# Controls: each half of the rule, removed in turn.
fresh_cache
REPO_MAIN_1513="$REPO"; REPO="$WT"
run "git add -A" "$PARENT_TR"
REPO="$REPO_MAIN_1513"
refused "#1513 control: the main session in the same tree gets no worktree credit"
write_meta "$SIBLING_ID" "$WT" true
rm -f "$PROJ/sess1/subagents/agent-$AGENT_ID.meta.json"
fresh_cache
run_agent "git add -A" "$AGENT_ID" "$WT"
refused "#1513 control: a worktree another agent was spawned with is not this agent's"
rm -f "$PROJ/sess1/subagents/agent-$SIBLING_ID.meta.json"
write_meta "$AGENT_ID" "$WT" false
fresh_cache
run_agent "git add -A" "$AGENT_ID" "$WT"
refused "#1513 control: a meta that says the agent was not spawned with a worktree credits nothing"
# A meta naming the MAIN checkout (shared by every session) is never a blanket credit, even if one
# ever said so: only a linked worktree can belong to one agent.
write_meta "$AGENT_ID" "$REPO" true
printf 'shared\n' > "$REPO/sharedfile.txt"
set_mtime "$REPO/sharedfile.txt" "$((now - 50000))"
fresh_cache
run_agent "git add -A" "$AGENT_ID"
refused "#1513 control: a meta naming the shared main checkout credits nothing in it"
says "and the foreign file is named" "sharedfile.txt"
rm -f "$REPO/sharedfile.txt" "$PROJ/sess1/subagents/agent-$AGENT_ID.meta.json"
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
REPO="$REPO_BEFORE_1513"

echo "check add scope: a worktree the main session created itself (claude-config#1523)"

# A main session that made its own worktree with EnterWorktree was judged on its transcript alone, so
# a file a background process it started wrote there was foreign. Measured on Claude Code 2.1.307,
# 2026-10-22, with throwaway headless sessions and from its own code: the session's transcript gets a
# `worktree-state` record (`worktreeSession` with `worktreePath`, `sessionId`, and `enteredExisting:
# true` when the session entered a worktree that already existed), and EnterWorktree's own result
# (`toolUseResult`) carries `worktreePath` and a message that begins "Created worktree at" only when
# this call made it. "Resumed", "Reused" and "Entered" say it already existed. A worktree RESUMED by
# name gets a worktree-state record identical to a created one (measured: a second session resuming
# one that held a file the first had left got no `enteredExisting`), so the record alone proves
# nothing, and only the Created result does. `claude --worktree` makes no tool call at all, so it
# leaves only that record and gets no credit.
REPO="$FIX/repo1523"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@e
git -C "$REPO" config user.name t
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add seed.txt
git -C "$REPO" -c commit.gpgsign=false commit -q -m seed
WT1523="$FIX/repo1523/.claude/worktrees/own"
git -C "$REPO" worktree add -q -b worktree-own "$WT1523" >/dev/null 2>&1
printf '.claude/\n' >> "$REPO/.git/info/exclude"
SESS1523="5ess1523-0000-4000-8000-000000000001"
MAIN_TR="$FIX/projects/proj1523/$SESS1523.jsonl"; mkdir -p "$(dirname "$MAIN_TR")"
# worktree_state <worktree path or "null"> [enteredExisting|hookBased] [session id in the record]
worktree_state(){
  python3 -c '
import json, sys
path, flag, sid = sys.argv[1], sys.argv[2], sys.argv[3]
ws = None
if path != "null":
    ws = {"originalCwd": "/x", "preEnterOriginalCwd": "/x", "worktreePath": path,
          "worktreeName": "own", "worktreeBranch": "worktree-own", "originalBranch": "main",
          "originalHeadCommit": "0" * 40, "sessionId": sid}
    if flag:
        ws[flag] = True
print(json.dumps({"type": "worktree-state", "worktreeSession": ws, "sessionId": sid}))
' "$1" "${2:-}" "${3:-$SESS1523}" >> "$MAIN_TR"
}
# enter_call <id> <name|path> <Created|Resumed|Reused|Entered> <worktree path> [record session id]
enter_call(){
  python3 -c '
import json, sys
tid, how, verb, path, sid = sys.argv[1:6]
inp = {"path": path} if how == "path" else {"name": "own"}
print(json.dumps({"type": "assistant", "sessionId": sid, "timestamp": "2026-10-22T20:00:00.000Z",
    "message": {"content": [{"type": "tool_use", "id": tid, "name": "EnterWorktree", "input": inp}]}}))
print(json.dumps({"type": "user", "sessionId": sid, "timestamp": "2026-10-22T20:00:01.000Z",
    "message": {"content": [{"type": "tool_result", "tool_use_id": tid, "content": "x"}]},
    "toolUseResult": {"worktreePath": path, "worktreeBranch": "worktree-own",
                      "message": "%s worktree at “%s” on branch worktree-own." % (verb, path)}}))
' "$1" "$2" "$3" "$4" "${5:-$SESS1523}" >> "$MAIN_TR"
}
run_main(){ # run_main <command> <repo to run in> [session id in the payload] [agent id]
  OUT="$(python3 -c '
import json, sys
d = {"tool_name": "Bash", "cwd": sys.argv[2], "tool_input": {"command": sys.argv[1]},
     "transcript_path": sys.argv[3], "session_id": sys.argv[4]}
if sys.argv[5]:
    d["agent_id"] = sys.argv[5]
    d["agent_type"] = "general-purpose"
print(json.dumps(d))
' "$1" "$2" "$MAIN_TR" "${3-$SESS1523}" "${4:-}" | env CLAUDE_ADD_SCOPE_STATE_DIR="$STATE" bash "$HOOK" 2>&1)"; RC=$?
}
now="$(date +%s)"
# A file nothing in the transcript names and no Bash window covers: only the worktree rule credits it.
printf 'background output\n' > "$WT1523/bg.txt"
set_mtime "$WT1523/bg.txt" "$((now - 50000))"

: > "$MAIN_TR"; enter_call t1523a name Created "$WT1523"; worktree_state "$WT1523"
fresh_cache
run_main "git add -A" "$WT1523"
allowed "#1523 an unmentioned file in the worktree this session created with EnterWorktree is its own"
# Read incrementally like everything else: the creation arrives in a later chunk than the first read.
: > "$MAIN_TR"; mention_bash_main(){ TR_SAVED="$TR"; TR="$MAIN_TR"; mention_bash "$1"; TR="$TR_SAVED"; }
mention_bash_main "ls"
fresh_cache
run_main "git add -A" "$WT1523"
refused "#1523 before the session made the worktree, nothing in it is credited"
enter_call t1523b name Created "$WT1523"; worktree_state "$WT1523"
run_main "git add -A" "$WT1523"
allowed "#1523 a creation recorded after the last read of the transcript is credited"

# The controls, each one a way the worktree may not be this session's.
: > "$MAIN_TR"; enter_call t1523c name Resumed "$WT1523"; worktree_state "$WT1523"
fresh_cache
run_main "git add -A" "$WT1523"
refused "#1523 control: a worktree resumed by name, which may hold an earlier session's work, is not credited"
says "and the file is named" "bg.txt"
: > "$MAIN_TR"; enter_call t1523d name Reused "$WT1523"; worktree_state "$WT1523"
fresh_cache
run_main "git add -A" "$WT1523"
refused "#1523 control: a worktree reused by name is not credited"
: > "$MAIN_TR"; enter_call t1523e path Entered "$WT1523"; worktree_state "$WT1523" enteredExisting
fresh_cache
run_main "git add -A" "$WT1523"
refused "#1523 control: a worktree entered by path, made by somebody else, is not credited"
# claude --worktree: the record only, with no EnterWorktree result, cannot tell made from resumed.
: > "$MAIN_TR"; worktree_state "$WT1523"
fresh_cache
run_main "git add -A" "$WT1523"
refused "#1523 control: a worktree-state record alone (claude --worktree) is not credited"
# Another session's worktree: the creation and the record belong to a different session id.
OTHER1523="0ther523-0000-4000-8000-000000000002"
: > "$MAIN_TR"; enter_call t1523f name Created "$WT1523" "$OTHER1523"; worktree_state "$WT1523" "" "$OTHER1523"
fresh_cache
run_main "git add -A" "$WT1523"
refused "#1523 control: a worktree another session created is not this session's"
: > "$MAIN_TR"; enter_call t1523g name Created "$WT1523" "$OTHER1523"; worktree_state "$WT1523"
fresh_cache
run_main "git add -A" "$WT1523"
refused "#1523 control: a creation recorded under another session id is not credited, whatever the record says"
: > "$MAIN_TR"; enter_call t1523o name Created "$WT1523"; worktree_state "$WT1523" "" "$OTHER1523"
fresh_cache
run_main "git add -A" "$WT1523"
refused "#1523 control: a worktree-state record under another session id is not credited, whatever the result says"
# The creation and the record must name the SAME worktree: made one, now in another it never made.
: > "$MAIN_TR"; enter_call t1523p name Created "$FIX/repo1523/.claude/worktrees/elsewhere"; worktree_state "$WT1523"
fresh_cache
run_main "git add -A" "$WT1523"
refused "#1523 control: a worktree made elsewhere does not credit the one the session is in now"
# Made it, then left it: the session no longer works there, and whoever does next is not credited to it.
: > "$MAIN_TR"; enter_call t1523h name Created "$WT1523"; worktree_state "$WT1523"; worktree_state null
fresh_cache
run_main "git add -A" "$WT1523"
refused "#1523 control: a worktree the session made and then left is not credited"
# Made it, then resumed it by name later (a fork carrying the creation in its history does this).
: > "$MAIN_TR"; enter_call t1523i name Created "$WT1523"; worktree_state "$WT1523"
enter_call t1523j name Resumed "$WT1523"; worktree_state "$WT1523"
fresh_cache
run_main "git add -A" "$WT1523"
refused "#1523 control: a later Resumed result outranks an earlier Created one"
# A hook based worktree is not a git worktree Claude Code made, and is never credited.
: > "$MAIN_TR"; enter_call t1523k name Created "$WT1523"; worktree_state "$WT1523" hookBased
fresh_cache
run_main "git add -A" "$WT1523"
refused "#1523 control: a hook based worktree is not credited"
# A SUBAGENT working in the session's worktree is judged by the #1513 rules, never this blanket one:
# sibling agents can share the tree, which is the hazard this gate is for.
: > "$MAIN_TR"; enter_call t1523l name Created "$WT1523"; worktree_state "$WT1523"
fresh_cache
run_main "git add -A" "$WT1523" "$SESS1523" "a1523aaaaaaaaaaaa"
refused "#1523 control: a subagent in the session's own worktree gets no whole worktree credit"
# The SHARED main checkout is never a blanket credit, whatever the records name.
printf 'shared\n' > "$REPO/shared1523.txt"
set_mtime "$REPO/shared1523.txt" "$((now - 50000))"
: > "$MAIN_TR"; enter_call t1523m name Created "$REPO"; worktree_state "$REPO"
fresh_cache
run_main "git add -A" "$REPO"
refused "#1523 control: records naming the main checkout credit nothing in it"
says "and the foreign file is named" "shared1523.txt"
rm -f "$REPO/shared1523.txt"
# A payload with no session id cannot be matched to any record, so it is not credited.
: > "$MAIN_TR"; enter_call t1523n name Created "$WT1523"; worktree_state "$WT1523"
fresh_cache
run_main "git add -A" "$WT1523" ""
refused "#1523 control: with no session id in the payload nothing is credited"
git -C "$REPO" worktree remove --force "$WT1523" >/dev/null 2>&1
REPO="$REPO_BEFORE_1513"

echo "check add scope: a checkout somebody else is working in"

# The incident: another session's file, which this one has never mentioned anywhere.
printf 'theirs\n' > "$REPO/theirs.txt"
fresh_cache
run "git add -A"
refused "an unscoped add is refused when the tree holds a change this session never made"
says "and it names the foreign path" "theirs.txt"
silentabout "and does not accuse this session's own file" "mine.txt is not this session"
says "and hands back the scoped command to run instead" "git -C $REPO add"
says "and that command names this session's own file" "mine.txt"
says "and names the override for the case it has got wrong" "SKIP_ADD_SCOPE_CHECK=1"
# The add is read by the one reading of git (claude-config#1188): env or sudo in front of git is the
# same add, which before walked past this gate as a command named env.
run "env GIT_TRACE=0 git add -A"
refused "#1188 an unscoped add behind env is refused too"
run "sudo git add ."
refused "#1188 and so is one behind sudo"
# Run by another program it is the same add (claude-config#1478): a shell's -c string, eval, env -S
# and the launchers are read by the shared reader.
for c in "bash -c 'git add -A'" "sh -c \"git add .\"" "zsh -c 'git add --all'" "bash -lc 'git add -A'" \
         "bash -c 'cd $REPO && git add -A'" "eval git add -A" "eval 'git add -A && git commit -m x'" \
         "env -S 'git add -A'" "xargs git add -A" "nohup git add -A" "time git add -A" "nice -n 5 git add -A" \
         "timeout 30 git add -A" "caffeinate -i git add -A" "command git add -A" "rtk proxy git add -A" \
         "sudo -u dan bash -c 'git add -A'" "find . -maxdepth 0 -exec git add -A \;" "watch -n 5 'git add -A'" "script -q /dev/null git add -A" "parallel git add -A ::: x"; do
  run "$c"
  refused "#1478 an unscoped add is refused wrapped: $c"
done
run "bash -c 'git add mine.txt'"
allowed "#1478 control: a scoped add in bash -c is allowed"
run "echo \"bash -c 'git add -A'\""
allowed "#1478 control: a wrapped add only echoed is no add"

run "git add ."
refused "a bare dot is refused the same way"
run "git add --all"
refused "and so is --all"
run "git add -u"
refused "and so is -u, which stages every tracked change"
# The shapes the shared parser has to keep reading once this hook asks it rather than its own
# detector (claude-config#457 item 6): a heredoc commit whose body carries an apostrophe, and an
# add inside a subshell.
run "git add -A && git commit -q -F - <<'MSG'
it isn't balanced
MSG"
refused "an unscoped add before a heredoc with an apostrophe is still refused"
run "(cd $REPO && git add .)"
refused "an unscoped add inside a subshell is refused"
# The repository is the one the ADD's cd names, from a session standing outside it, on any line
# and whatever cd follows (claude-config#1017). ps_repo_dir reads the cd in force for the action it
# is asked about, and an add is not a push, so a hook asking about a push here would find no cd.
run "if true; then git add -A; fi"
refused "an unscoped add right after then is refused (lessons review of #1017)"
run "for f in x; do git add .; done"
refused "and so is one right after do"
# A copy of the hook whose lib/ holds push-scope.sh but not the shell-words.py it reads commands
# with: an add whose cd nothing can read is refused by name, never let through as "no repository"
# (lessons review of #1017, L490).
mkdir -p "$FIX/noreader/lib"
cp "$HOOK" "$FIX/noreader/check-add-scope.sh"
cp "$DIR/lib/push-scope.sh" "$FIX/noreader/lib/push-scope.sh"
HOOK_SAVED="$HOOK"; HOOK="$FIX/noreader/check-add-scope.sh"
run "cd $REPO && git add -A"
HOOK="$HOOK_SAVED"
refused "an unscoped add whose cd cannot be read is refused rather than allowed"
says "and the refusal names the missing reader" "shell-words.py"
REPO_SAVED="$REPO"; REPO="$FIX"
run $'echo starting\ncd '"$REPO_SAVED"$' && git add -A\ncd '"$FIX"
REPO="$REPO_SAVED"
refused "an unscoped add whose cd is on a later line is refused from a session outside the repo"
run "git add :/"
refused "and so is :/, which is the whole tree from anywhere"
# EVERY add is judged, not only the first (claude-config#1062). The gate judged the repository of the
# first add in the command, so a scoped add in a clean checkout followed by an unscoped add here,
# where another session's change sits, was judged in the clean one and allowed.
CLEAN="$FIX/clean"
git init -q -b main "$CLEAN"
run "cd $CLEAN && git add nothing.txt; cd $REPO && git add -A"
refused "an unscoped add in a second repository is no longer judged in the first"
says "and the refusal says the adds run in more than one repository" "more than one repository"
run "cd $REPO && git add mine.txt; cd $REPO && git add -A"
refused "control: two adds in this one repository are still judged here"

# The scoped form is the whole point: it must go through even with a foreign change present.
run "git add mine.txt"
allowed "a scoped add is allowed even with another session's work in the tree"
run "git add -- mine.txt viabash.txt"
allowed "and so is an explicit path list"

# The documented override, good for one command.
run "SKIP_ADD_SCOPE_CHECK=1 git add -A"
allowed "the documented override lets one command through"

echo "check add scope: it only fires on a command that really stages"

run "echo 'remember to git add -A next time'"
allowed "a command that merely mentions an unscoped add is not one"
run "git commit -m 'git add -A was wrong here'"
allowed "and neither is a commit message that quotes one"
run "git status"
allowed "an unrelated git command is not one"
run "git add --help"
allowed "asking for help stages nothing"

echo "check add scope: it never goes quiet on its own failure"

# Without the transcript there is no way to tell this session's work from another session's, and
# "everything is yours" is the assumption that produced the incident. Refusing costs one override;
# the other direction costs somebody else's work being committed under a message that does not
# describe it (L42, L98).
run "git add -A" ""
refused "with no transcript to read, it refuses rather than assuming the tree is all this session's"
says "and says that is why" "could not read the session transcript"
run "git add -A" "$FIX/no-such-transcript.jsonl"
refused "a transcript path that is not there is the same failure"

# A transcript that SHRANK is a different file under the same name (a compaction, a fresh session
# reusing the path). Reading on from the old offset would read the middle of a line and the cache
# would hold whatever that produced.
fresh_cache
run "git add mine.txt"
: > "$TR"
mention_edit "$REPO/theirs.txt"
mention_edit "$REPO/mine.txt"
mention_bash "cat > $REPO/viabash.txt <<'EOF'
via bash
EOF"
run "git add -A"
allowed "a transcript rewritten shorter is re-read from the start, not resumed mid line"

echo "check add scope: the reader that says what an add takes (claude-config#480)"

# ps__read_adds in lib/push-scope.sh reads what a `git add` takes with python3, and ps_add_takes_all
# compared its answer against the literal "yes". With no python3 there was no answer at all, which
# compared as NO, so this gate exited 0 on every unscoped add on such a machine with nothing said:
# an absent reader is the one failure indistinguishable from a clean run (L490, L42, L98). The
# transcript this gate tells the session's work from a stranger's by is read with python3 too, so
# nothing is left that could judge the add.
NOPY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/check-add-scope-nopy.XXXXXXXX")"
NOPY="$NOPY_ROOT/bin"; mkdir -p "$NOPY"
for tool in bash sh git grep sed awk tr cat cut head sort dirname basename env uname mkdir mv rm shasum wc tail; do
  toolpath="$(command -v "$tool" 2>/dev/null)"
  [ -n "$toolpath" ] && ln -s "$toolpath" "$NOPY/$tool" 2>/dev/null
done
# The fixture's own premise, asserted rather than assumed: a bare directory that still reaches a
# python3 would make every case below pass for the wrong reason (L159).
if PATH="$NOPY" "$NOPY/bash" -c 'command -v python3 >/dev/null 2>&1'; then
  check "the bare directory really reaches no python3" "it found one, so nothing below measures its absence"
else check "the bare directory really reaches no python3" ok; fi

# The SAME directory with jq linked in beside it. jq reads the payload, so the command is legible
# and only the add's own reader is gone, which is the machine this issue is actually about. Its
# twin above, with jq missing too, is the harder case where nothing read the payload either.
WITHJQ="$NOPY_ROOT/withjq"; mkdir -p "$WITHJQ"
for tool in bash sh git grep sed awk tr cat cut head sort dirname basename env uname mkdir mv rm shasum wc tail jq; do
  toolpath="$(command -v "$tool" 2>/dev/null)"
  [ -n "$toolpath" ] && ln -s "$toolpath" "$WITHJQ/$tool" 2>/dev/null
done
if PATH="$WITHJQ" "$WITHJQ/bash" -c 'command -v python3 >/dev/null 2>&1'; then
  check "the jq only directory reaches no python3" "it found one, so nothing below measures its absence"
else check "the jq only directory reaches no python3" ok; fi
if PATH="$WITHJQ" "$WITHJQ/bash" -c 'command -v jq >/dev/null 2>&1'; then
  check "the jq only directory really does reach jq" ok
else check "the jq only directory really does reach jq" "there is no jq in it, so it is the same case as the other one"; fi

# RUN FROM the repository, not merely naming it in the payload. Where nothing can read the payload
# at all the gate cannot read its cwd either, and the session's own working directory is what
# Claude Code starts a hook in, so that is what it has left to ask about. A run from anywhere else
# would be judging whichever checkout this suite happens to sit in, and would pass or fail with
# that checkout's state rather than with the fixture's (L2, L411).
run_nopy(){ # run_nopy <command> [bin dir, default the one with no python3 and no jq]
  OUT="$(python3 -c '
import json, sys
d = {"tool_name": "Bash", "cwd": sys.argv[2], "tool_input": {"command": sys.argv[1]},
     "transcript_path": sys.argv[3]}
print(json.dumps(d))
' "$1" "$REPO" "$TR" | ( cd "$REPO" && env CLAUDE_ADD_SCOPE_STATE_DIR="$STATE" PATH="${2:-$NOPY}" "${2:-$NOPY}/bash" "$HOOK" 2>&1 ))"; RC=$?
}

fresh_cache
run_nopy "git add -A" "$WITHJQ"
refused "with jq but no python3 an unscoped add is refused rather than allowed in silence"
says "and that refusal names the reader that is missing" "python3"
fresh_cache
run_nopy "git add mine.txt" "$WITHJQ"
refused "and an add nobody can read the scope of is refused whatever it names"

fresh_cache
run_nopy "git add -A"
refused "with no reader at all the add is refused too, rather than passing unseen"
says "and the refusal names the reader that is missing" "python3"

# A command with no `git add` in it takes nothing from the missing reader, so there is nothing to
# refuse over. Without this the gate would be refusing commands it was never about (L54, L324).
fresh_cache
run_nopy "git status"
allowed "a command with no add is not refused over a reader it never needed"

# The documented override still clears it, or the refusal is a dead end nothing in the session can
# answer (L109).
fresh_cache
run_nopy "SKIP_ADD_SCOPE_CHECK=1 git add -A"
allowed "the visible override still clears the missing reader refusal"

# The control, the same command on the same tree with python3 on PATH: allowed, because by now the
# transcript mentions every change in it. So the refusal above is the reader's absence rather than
# a fixture that refuses everything (L159).
fresh_cache
run "git add -A"
allowed "the control still allows the same unscoped add with python3 present"

rm -rf "$NOPY_ROOT"

echo "check add scope: the real agent records still have the shape the gate reads (claude-config#1523)"

# The subagent layout and its .meta.json are Claude Code internals, measured on 2.1.307. If either
# moves, the gate does not break loudly: it falls back to refusing an agent's own files, which is
# felt as false refusals and taught as overriding (L36). So the newest real record on this machine
# is read (read only) and every file and field the gate relies on is asserted. Where no record
# exists (CI, a fresh machine) that is said as UNMEASURED, never as a pass (L411). Nothing from a
# transcript is ever printed: only the name of each check, and the Claude Code version that wrote it.
record_drift(){ # record_drift <projects root>: prints PART <name> OK|UNMEASURED <why>|DRIFT <what>
  python3 -I - "$1" <<'PY'
import datetime, glob, json, os, sys
root = sys.argv[1]
SCAN = 50
def out(part, verdict, why=""):
    print(("PART %s %s %s" % (part, verdict, why)).rstrip())
def records(path):
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except Exception:
                    continue
                if isinstance(r, dict):
                    yield r
    except OSError:
        return
if not os.path.isdir(root) or not glob.glob(os.path.join(glob.escape(root), "*", "*.jsonl")):
    for p in ("layout", "transcript", "isolation"):
        out(p, "UNMEASURED", "no Claude Code session transcripts on this machine")
    sys.exit(0)
esc = glob.escape(root)
expected = glob.glob(os.path.join(esc, "*", "*", "subagents", "agent-*.jsonl")) + \
           glob.glob(os.path.join(esc, "*", "*", "subagents", "*", "agent-*.jsonl"))
anywhere = glob.glob(os.path.join(esc, "**", "agent-*.jsonl"), recursive=True) + \
           glob.glob(os.path.join(esc, "**", "agent-*.meta.json"), recursive=True)
if not expected:
    if anywhere:
        out("layout", "DRIFT", "agent records exist but none at <session>/subagents/[<group>/]agent-<id>.jsonl")
    else:
        out("layout", "UNMEASURED", "no subagent has run on this machine")
    out("transcript", "UNMEASURED", "no agent transcript to read")
    out("isolation", "UNMEASURED", "no agent transcript to read")
    sys.exit(0)
expected.sort(key=lambda p: os.path.getmtime(p), reverse=True)
def parent_of(p):
    d = os.path.dirname(p)
    if os.path.basename(d) != "subagents":
        d = os.path.dirname(d)
    return os.path.dirname(d) + ".jsonl"
def aid_of(p):
    return os.path.basename(p)[len("agent-"):-len(".jsonl")]
# Layout, on the newest record: the parent transcript the gate derives the folder from, and the meta.
newest = expected[0]
problems = []
if not os.path.isfile(parent_of(newest)):
    problems.append("no parent transcript <session>.jsonl beside the subagents folder")
meta_path = newest[:-len(".jsonl")] + ".meta.json"
try:
    with open(meta_path) as fh:
        meta = json.load(fh)
    if not isinstance(meta, dict):
        problems.append("the .meta.json is not an object")
except Exception:
    problems.append("no readable agent-<id>.meta.json beside the agent transcript")
version = ""
for r in records(newest):
    if isinstance(r.get("version"), str):
        version = r["version"]
        break
out("layout", "DRIFT" if problems else "OK", "; ".join(problems) if problems else
    "newest agent record, written by Claude Code %s" % (version or "of unknown version"))
# Transcript: the newest agent that ran Bash, read for the fields the mentions and windows use.
seen = None
for p in expected[:SCAN]:
    uses, results, stamps, bad_stamps, mentions = {}, set(), 0, 0, 0
    for r in records(p):
        msg = r.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None
        if not isinstance(content, list):
            continue
        ts = r.get("timestamp")
        for c in content:
            if not isinstance(c, dict):
                continue
            if c.get("type") == "tool_use":
                uses[c.get("id")] = (c.get("name"), c.get("input"))
                inp = c.get("input")
                if isinstance(inp, dict) and any(isinstance(inp.get(k), str) for k in ("command", "file_path")):
                    mentions += 1
            elif c.get("type") == "tool_result":
                results.add(c.get("tool_use_id"))
            else:
                continue
            # Only the conversation records are timed. Claude Code also writes api-request-blob
            # records repeating the same blocks with no timestamp (measured 2026-10-22), which the
            # gate already passes over for its windows.
            if r.get("type") not in ("assistant", "user"):
                continue
            try:
                datetime.datetime.strptime((ts or "")[:19], "%Y-%m-%dT%H:%M:%S")
                stamps += 1
            except Exception:
                bad_stamps += 1
    bash = [i for i, (n, _) in uses.items() if n == "Bash"]
    if bash:
        seen = (bash, uses, results, stamps, bad_stamps, mentions)
        break
if seen is None:
    out("transcript", "UNMEASURED", "none of the newest %d agent transcripts ran Bash" % SCAN)
else:
    bash, uses, results, stamps, bad_stamps, mentions = seen
    problems = []
    if any(not isinstance(i, str) or not i for i in bash):
        problems.append("a Bash tool_use has no id")
    if not any(i in results for i in bash):
        problems.append("no tool_result carries the tool_use_id of a Bash call")
    if bad_stamps or not stamps:
        problems.append("tool call records lack an ISO timestamp")
    if not mentions:
        problems.append("no tool input carries command or file_path")
    out("transcript", "DRIFT" if problems else "OK", "; ".join(problems))
# Isolation: the newest agent whose recorded cwd is its own .claude/worktrees/agent-<id> worktree.
found = None
for p in expected[:SCAN]:
    seg = "/.claude/worktrees/agent-%s" % aid_of(p)
    for r in records(p):
        cwd = r.get("cwd")
        if isinstance(cwd, str) and (cwd.endswith(seg) or (seg + "/") in cwd):
            found = (p, cwd[:cwd.index(seg) + len(seg)])
            break
    if found:
        break
if found is None:
    out("isolation", "UNMEASURED", "none of the newest %d agents ran in a worktree it was spawned with" % SCAN)
else:
    p, wt = found
    problems = []
    try:
        with open(p[:-len(".jsonl")] + ".meta.json") as fh:
            m = json.load(fh)
    except Exception:
        m = None
    if not isinstance(m, dict):
        problems.append("no readable .meta.json beside an isolated agent")
    else:
        if m.get("spawnedWithWorktree") is not True:
            problems.append("the meta has no spawnedWithWorktree true")
        w = m.get("worktreePath")
        if not isinstance(w, str):
            problems.append("the meta has no worktreePath")
        elif os.path.realpath(w) != os.path.realpath(wt):
            problems.append("the meta worktreePath is not the worktree the agent ran in")
    out("isolation", "DRIFT" if problems else "OK", "; ".join(problems))
PY
}
# judge_drift <checker output> <label>: a DRIFT fails, an UNMEASURED is said on the runner's line.
judge_drift(){
  local line part verdict why
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    part="$(printf '%s' "$line" | cut -d' ' -f2)"
    verdict="$(printf '%s' "$line" | cut -d' ' -f3)"
    why="$(printf '%s' "$line" | cut -d' ' -f4-)"
    case "$verdict" in
      OK) check "#1523 $2: the $part of the newest agent record is what the gate reads" ok ;;
      UNMEASURED) echo "SUITE-PART-UNMEASURED #1523 the $part of a real agent record: $why" ;;
      *) check "#1523 $2: the $part of the newest agent record is what the gate reads" "$why" ;;
    esac
  done <<LINES
$1
LINES
}

# The checker's own controls, on fixtures in the real layout, each seen to fail before it is trusted
# with the real records (L1).
DR="$FIX/drift"
drift_fixture(){ # drift_fixture <root>: one session with one isolated agent that ran Bash
  local root="$1" sdir="$1/-proj/sess" wt="$1/wt/.claude/worktrees/agent-adrift000000000001"
  mkdir -p "$sdir/subagents" "$wt"
  : > "$sdir.jsonl"
  python3 -c '
import json, sys
wt = sys.argv[1]
print(json.dumps({"type": "assistant", "cwd": wt, "version": "9.9.9", "timestamp": "2026-10-22T20:00:00.000Z",
    "message": {"content": [{"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": {"command": "ls"}}]}}))
print(json.dumps({"type": "user", "cwd": wt, "timestamp": "2026-10-22T20:00:01.000Z",
    "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_1", "content": "x"}]}}))
' "$wt" > "$sdir/subagents/agent-adrift000000000001.jsonl"
  python3 -c '
import json, sys
print(json.dumps({"agentType": "general-purpose", "spawnedWithWorktree": True, "worktreePath": sys.argv[1]}))
' "$wt" > "$sdir/subagents/agent-adrift000000000001.meta.json"
}
drift_says(){ # drift_says <label> <part> <verdict> <output>
  case "$4" in *"PART $2 $3"*) check "$1" ok ;; *) check "$1" "expected PART $2 $3" ;; esac
}
rm -rf "$DR"; drift_fixture "$DR/good"
o="$(record_drift "$DR/good")"
drift_says "#1523 drift control: a record in the measured shape passes the layout" layout OK "$o"
drift_says "#1523 drift control: and its transcript" transcript OK "$o"
drift_says "#1523 drift control: and its isolation meta" isolation OK "$o"
drift_fixture "$DR/renamed"
sed -i.bak 's/spawnedWithWorktree/spawnedInWorktree/' "$DR/renamed/-proj/sess/subagents/agent-adrift000000000001.meta.json"
o="$(record_drift "$DR/renamed")"
drift_says "#1523 drift control: a renamed spawnedWithWorktree is drift" isolation DRIFT "$o"
drift_fixture "$DR/nometa"
rm -f "$DR/nometa/-proj/sess/subagents/agent-adrift000000000001.meta.json"
o="$(record_drift "$DR/nometa")"
drift_says "#1523 drift control: a missing meta file is drift" layout DRIFT "$o"
drift_fixture "$DR/wtpath"
python3 -c '
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m["worktree"] = m.pop("worktreePath"); json.dump(m, open(p, "w"))
' "$DR/wtpath/-proj/sess/subagents/agent-adrift000000000001.meta.json"
o="$(record_drift "$DR/wtpath")"
drift_says "#1523 drift control: a renamed worktreePath is drift" isolation DRIFT "$o"
drift_fixture "$DR/noparent"
rm -f "$DR/noparent/-proj/sess.jsonl"
: > "$DR/noparent/-proj/other.jsonl"
o="$(record_drift "$DR/noparent")"
drift_says "#1523 drift control: no parent transcript beside the subagents folder is drift" layout DRIFT "$o"
drift_fixture "$DR/noid"
sed -i.bak 's/"tool_use_id": "toolu_1"/"toolUseId": "toolu_1"/' "$DR/noid/-proj/sess/subagents/agent-adrift000000000001.jsonl"
o="$(record_drift "$DR/noid")"
drift_says "#1523 drift control: a renamed tool_use_id is drift" transcript DRIFT "$o"
drift_fixture "$DR/nostamp"
sed -i.bak 's/"timestamp": /"time": /' "$DR/nostamp/-proj/sess/subagents/agent-adrift000000000001.jsonl"
o="$(record_drift "$DR/nostamp")"
drift_says "#1523 drift control: a renamed timestamp on the conversation records is drift" transcript DRIFT "$o"
drift_fixture "$DR/moved"
mkdir -p "$DR/moved/-proj/agents"
mv "$DR/moved/-proj/sess/subagents/"agent-* "$DR/moved/-proj/agents/"
o="$(record_drift "$DR/moved")"
drift_says "#1523 drift control: agent records moved out of subagents/ are drift, not unmeasured" layout DRIFT "$o"
mkdir -p "$DR/empty"
o="$(record_drift "$DR/empty")"
drift_says "#1523 drift control: no transcripts at all is unmeasured" layout UNMEASURED "$o"
mkdir -p "$DR/noagents/-proj"; : > "$DR/noagents/-proj/sess.jsonl"
o="$(record_drift "$DR/noagents")"
drift_says "#1523 drift control: transcripts but no agent ever run is unmeasured" layout UNMEASURED "$o"
case "$o" in *"sess.jsonl"*|*'"type"'*) check "#1523 drift control: no transcript text is printed" "it printed a path or record" ;;
  *) check "#1523 drift control: no transcript text is printed" ok ;; esac

# Now the real records on this machine, read only.
judge_drift "$(record_drift "${CLAUDE_ADD_SCOPE_LIVE_PROJECTS:-$HOME/.claude/projects}")" "on this machine"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
