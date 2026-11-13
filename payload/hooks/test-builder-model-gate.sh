#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans settings.hooks.json
# Tests for the gate that refuses a builder dispatch naming no model, in a session that is
# orchestrating builders (claude-config#2027).
#
# Measured on 2026-11-13 over this Mac's transcripts since the tiers changed on 2026-11-09: 8 of 216
# builder dispatches named no model, so the written rule was being skipped (L27). Dan chose on
# 2026-11-13 to narrow the refusal to sessions orchestrating builders, as #2027 scoped it, so an
# ordinary session sees no new stop. The payload shape is the one the transcripts record for an
# Agent call: tool_name Agent, with subagent_type, prompt, isolation and model inside tool_input,
# and transcript_path naming the session's transcript (the parent's, for a call made inside a
# subagent). The fixture transcripts carry Agent tool_use lines in the shape Claude Code writes.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/builder-model-gate.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "test-builder-model-gate: there is no builder-model-gate.sh beside this suite at $DIR." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs builder-model-gate.sh beside it"
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bm-gate.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# transcript <file> <kind>...: a session transcript holding one Agent dispatch per kind, in the
# shape Claude Code writes them (compact JSON, one content block per assistant line). A kind is
# "builder" (a worktree dispatch), "explore" (read only), "session" (a brief carrying the commit
# session line, no worktree), "self" (a builder whose id is this call's own, toolu_x) or "junk" (a
# line that is not JSON). A line of ordinary chat comes first.
transcript() {
  python3 - "$@" <<'PY'
import json, sys
path, kinds = sys.argv[1], sys.argv[2:]
lines = [json.dumps({"type": "user", "message": {"role": "user", "content": "work the list"}},
                    separators=(",", ":"))]
for n, k in enumerate(kinds):
    if k == "junk":
        lines.append('{"type":"assistant","name":"Agent" this is not json')
        continue
    inp = {"description": "item %d" % n, "prompt": "build item %d" % n, "model": "opus"}
    if k in ("builder", "self"):
        inp["isolation"] = "worktree"
    elif k == "explore":
        inp = {"description": "look", "prompt": "find it", "subagent_type": "Explore"}
    elif k == "session":
        inp["prompt"] += " Claude-Session: https://claude.ai/code/session_x"
    tid = "toolu_x" if k == "self" else "toolu_%d" % n
    lines.append(json.dumps({"type": "assistant", "timestamp": "2026-11-13T10:00:00Z",
                             "message": {"role": "assistant", "content": [
                                 {"type": "tool_use", "id": tid, "name": "Agent", "input": inp}]}},
                            separators=(",", ":")))
open(path, "w").write("\n".join(lines) + "\n")
PY
}
ORCH="$WORK/orchestrating.jsonl"; transcript "$ORCH" builder builder
ORDINARY="$WORK/ordinary.jsonl"; transcript "$ORDINARY"
ONE="$WORK/one-builder.jsonl"; transcript "$ONE" builder
READONLY="$WORK/readonly.jsonl"; transcript "$READONLY" explore explore explore builder
OWN="$WORK/own-call.jsonl"; transcript "$OWN" builder self
SESSIONLINE="$WORK/session-line.jsonl"; transcript "$SESSIONLINE" session builder
JUNK="$WORK/junk.jsonl"; transcript "$JUNK" junk builder junk builder

# The session transcript every payload names, set before a run; NONE leaves the field out. AGENT_ID
# set marks the call as made inside a subagent.
TRANSCRIPT="$ORCH"
AGENT_ID=""

# payload <tool> <subagent_type> <isolation> <model> <prompt>: an empty argument is a field left OUT.
payload() {
  python3 -c '
import json, sys
tool, st, iso, model, prompt, transcript, agent = sys.argv[1:8]
ti = {"description": "do the work", "prompt": prompt}
if st:
    ti["subagent_type"] = st
if iso:
    ti["isolation"] = iso
if model == "EMPTY":
    ti["model"] = ""
elif model:
    ti["model"] = model
d = {"session_id": "s", "cwd": "/tmp", "hook_event_name": "PreToolUse",
     "tool_name": tool, "tool_input": ti, "tool_use_id": "toolu_x"}
if transcript != "NONE":
    d["transcript_path"] = transcript
if agent:
    d["agent_id"] = agent
print(json.dumps(d))
' "$1" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "$TRANSCRIPT" "$AGENT_ID"
}

RC=0; OUT=""; ERR=""
run_raw() {
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/bm-gate-err.XXXXXXXX")"
  OUT="$(printf '%s' "$1" | bash "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
run() { run_raw "$(payload "$@")"; }
refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:200}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:200}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:300}" ;; esac; }
. "$DIR/lib/hook-notice.sh"
notices() { local why; why="$(hook_notice_verdict "$OUT" "$2")"; if [ -z "$why" ]; then check "$1" ok; else check "$1" "$why"; fi; }

SESSION_LINE="Claude-Session: https://claude.ai/code/session_x"

echo "builder model gate: a builder with a model goes through"
run Agent general-purpose worktree opus "build the thing"
allowed "a worktree builder naming opus"
run Agent general-purpose worktree sonnet "build the thing"
allowed "a worktree builder naming sonnet"
run Agent "" "" fable "build it. $SESSION_LINE"
allowed "a builder with no type naming fable"

echo "builder model gate: a builder with no model is refused in an orchestrating session"
run Agent general-purpose worktree "" "build the thing"
refused "a worktree builder with no model"
says "and it names the tiers" "sonnet"
says "and names opus" "opus"
says "and names fable" "fable"
says "and points at the rule's home" "Which model a builder runs on"
run Agent "" worktree "" "build the thing"
refused "a worktree builder with no type and no model"
run Agent general-purpose "" "" "fix it. $SESSION_LINE"
refused "a brief carrying the commit session line is a builder"
run Agent general-purpose worktree EMPTY "build the thing"
refused "an empty model is no model"

echo "builder model gate: what is not a builder is left alone, even while orchestrating"
run Agent Explore "" "" "find where it lives"
allowed "a read only Explore agent"
run Agent Plan "" "" "plan it"
allowed "a Plan agent"
run Agent plan-security "" "" "review the plan"
allowed "a plan panelist"
run Agent claude-code-guide "" "" "how do hooks work"
allowed "the guide agent"
run Agent general-purpose "" "" "read these files and report"
allowed "a research agent with no worktree and no session line"
run Agent fork worktree "" "carry on"
allowed "a fork ignores model, so it cannot be asked for one"
run Bash "" "" "" "ls"
allowed "a call to another tool"

echo "builder model gate: a session that is not orchestrating builders is never stopped"
TRANSCRIPT="$ORDINARY"
run Agent general-purpose worktree "" "build the thing"
allowed "a builder with no model, in a session that has dispatched nothing"
run Agent "" "" "" "fix it. $SESSION_LINE"
allowed "a session line brief with no model, in that session"
TRANSCRIPT="$ONE"
run Agent general-purpose worktree "" "build the thing"
allowed "a session's second builder with no model"
TRANSCRIPT="$READONLY"
run Agent general-purpose worktree "" "build the thing"
allowed "read only agents dispatched before do not make a session orchestrating"
TRANSCRIPT="$OWN"
run Agent general-purpose worktree "" "build the thing"
allowed "this call's own line in the transcript is not counted as an earlier builder"

echo "builder model gate: an orchestrating session is recognised however its builders went out"
TRANSCRIPT="$SESSIONLINE"
run Agent general-purpose worktree "" "build the thing"
refused "earlier builders sent with the commit session line and no worktree count"
TRANSCRIPT="$JUNK"
run Agent general-purpose worktree "" "build the thing"
refused "lines that are not JSON are skipped, not taken as a reason to stop counting"
TRANSCRIPT="$ORCH"; AGENT_ID="agent_123"
run Agent general-purpose worktree "" "build the thing"
refused "a call made inside a subagent of an orchestrating session (transcript_path is the parent's)"
AGENT_ID=""

echo "builder model gate: when it cannot tell whether the session is orchestrating"
TRANSCRIPT="NONE"
run Agent general-purpose worktree "" "build the thing"
if [ "$RC" -eq 0 ]; then check "a payload naming no transcript is let through" ok; else check "a payload naming no transcript is let through" "exit $RC"; fi
notices "and says the gate did not run" "BUILDER MODEL GATE DID NOT RUN"
TRANSCRIPT="$WORK/not-there.jsonl"
run Agent general-purpose worktree "" "build the thing"
if [ "$RC" -eq 0 ]; then check "a transcript that is not there is let through" ok; else check "a transcript that is not there is let through" "exit $RC"; fi
notices "and says so" "BUILDER MODEL GATE DID NOT RUN"
run Agent general-purpose worktree opus "build the thing"
allowed "a builder naming a model never needs the transcript"
run Agent Explore "" "" "find where it lives"
allowed "nor does a read only agent"
TRANSCRIPT="$ORCH"

echo "builder model gate: a payload it cannot read"
run_raw 'this is not json'
if [ "$RC" -eq 0 ]; then check "unreadable input is let through" ok; else check "unreadable input is let through" "exit $RC"; fi
notices "and says the gate did not run" "BUILDER MODEL GATE DID NOT RUN"
run_raw ''
if [ "$RC" -eq 0 ]; then check "an empty payload is let through" ok; else check "an empty payload is let through" "exit $RC"; fi
notices "and says so too" "BUILDER MODEL GATE DID NOT RUN"
run_raw '["a", "list"]'
if [ "$RC" -eq 0 ]; then check "valid JSON that is not an object is let through" ok; else check "valid JSON that is not an object is let through" "exit $RC"; fi
notices "and says so" "BUILDER MODEL GATE DID NOT RUN"

echo "builder model gate: it is wired"
SETTINGS_DIR="${BUILDER_MODEL_GATE_SETTINGS_DIR:-$DIR/..}"
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$SETTINGS_DIR")"
if [ -z "$SETTINGS" ]; then
  printf 'SUITE-NOT-RUN %s\n' "needs the settings file that registers the hook, and $SETTINGS_DIR holds neither"
else
  wiring="$(python3 - "$SETTINGS" <<'PY'
import json, re, sys
hooks = json.load(open(sys.argv[1])).get("hooks", {})
groups = [g for g in hooks.get("PreToolUse", [])
          if any("builder-model-gate.sh" in h.get("command", "") for h in g.get("hooks", []))]
if not groups:
    print("no PreToolUse group runs builder-model-gate.sh"); sys.exit()
m = groups[0].get("matcher", "")
if not re.fullmatch(m, "Agent"):
    print("the matcher does not route Agent"); sys.exit()
for name in ["Bash", "Edit", "mcp__playwright__browser_click"]:
    if m == "" or re.fullmatch(m, name):
        print("the matcher also routes " + name); sys.exit()
if not any(h.get("onFailure") == "block" for h in groups[0]["hooks"]):
    print("the registration does not carry onFailure block"); sys.exit()
print("ok")
PY
)"
  check "the hook is registered under PreToolUse for Agent calls only, failing closed" "$wiring"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
