#!/usr/bin/env bash
# Tests for context-size-notice.sh (claude-config#1960, #1940): the context line and the long
# session nudge, both read from the transcript a PostToolUse payload names.
#
# - A builder (any subagent) or an orchestrator (a main session that has dispatched an agent or set
#   a /goal) whose last request carried more than the line (CONTEXT_LINE_TOKENS, 200,000) is told,
#   once per band of the line, to write down what it has decided and then restart or compact.
# - A main session compacted CONTEXT_COMPACTIONS_NUDGE (5) times is nudged to start fresh, saying
#   what its next request costs.
# Every check below was seen failing before the hook existed (L1).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/context-size-notice.sh"
WORK="$(mktemp -d)"
holder=""
cleanup(){ [ -n "$holder" ] && kill "$holder" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
pass=0; fail=0
check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:900}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected NOT to contain: $2"; echo "  actual: ${3:0:900}"; fi; }
check_eq(){ if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '${3:0:600}')"; fi; }

export CLAUDE_HOME="$WORK/home"; mkdir -p "$CLAUDE_HOME"
export CONTEXT_SIZE_STATE_DIR="$WORK/state"
unset CONTEXT_LINE_TOKENS CONTEXT_COMPACTIONS_NUDGE

# ---- transcript lines, written the way Claude Code writes them (compact JSON, one line each) ----
usage(){ # usage <file> <message id> <context tokens>: one request whose input totals <context>
  printf '{"type":"assistant","isSidechain":false,"message":{"id":"%s","model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":10,"cache_read_input_tokens":%d,"cache_creation_input_tokens":100}}}\n' "$2" "$(( $3 - 110 ))" >> "$1"
}
agent_call(){ # agent_call <file>: the session dispatches an agent
  printf '{"type":"assistant","message":{"id":"msg_agent%s","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"toolu_%s","name":"Agent","input":{"prompt":"go"}}]}}\n' "$RANDOM" "$RANDOM" >> "$1"
}
goal_set(){ # goal_set <file>: /goal set in this session
  printf '{"type":"attachment","attachment":{"type":"goal_status","met":false,"sentinel":true,"condition":"finish the list"}}\n' >> "$1"
}
compacted(){ # compacted <file> <preTokens>
  printf '{"type":"system","subtype":"compact_boundary","isSidechain":false,"compactMetadata":{"trigger":"auto","preTokens":%d,"postTokens":17067}}\n' "$2" >> "$1"
}
main_fire(){ # main_fire <session> <transcript>
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"/tmp","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' "$1" "$2" | bash "$HOOK" 2>/dev/null
}
agent_fire(){ # agent_fire <session> <parent transcript> <agent id> [agent transcript path]
  if [ -n "${4:-}" ]; then
    printf '{"session_id":"%s","transcript_path":"%s","agent_id":"%s","agent_transcript_path":"%s","cwd":"/tmp","hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{}}' "$1" "$2" "$3" "$4" | bash "$HOOK" 2>/dev/null
  else
    printf '{"session_id":"%s","transcript_path":"%s","agent_id":"%s","cwd":"/tmp","hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{}}' "$1" "$2" "$3" | bash "$HOOK" 2>/dev/null
  fi
}
json_ok(){ printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin); print("ok")' 2>/dev/null || echo "not JSON"; }
field(){ printf '%s' "$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
k = sys.argv[1]
print(d.get("systemMessage", "") if k == "system" else d.get("hookSpecificOutput", {}).get(k, ""))
' "$2" 2>/dev/null; }

# ---- 1. A builder: any subagent, its own transcript beside its parent's ----
P="$WORK/proj/s1.jsonl"; mkdir -p "$WORK/proj/s1/subagents"; : > "$P"
A="$WORK/proj/s1/subagents/agent-a1.jsonl"; : > "$A"
usage "$A" msg_1 150000
check_eq "1 a builder under the line hears nothing" "" "$(agent_fire s1 "$P" a1 "$A")"
usage "$A" msg_2 212345
out="$(agent_fire s1 "$P" a1 "$A")"
check_eq "1 the notice is a JSON hook answer" "ok" "$(json_ok "$out")"
ctx="$(field "$out" additionalContext)"
check "1 a builder past the line is told its size" "212,345" "$ctx"
check "1 and the line" "200,000" "$ctx"
check "1 and where to write down what it decided" "handoff.md" "$ctx"
check "1 and what to write down: the decisions" "every decision" "$ctx"
check "1 and the state left behind" "commit" "$ctx"
check "1 and to hand back to a fresh agent" "hand back" "$ctx"
check "1 naming the issue" "claude-config#1960" "$ctx"
check_eq "1 the event it answers is PostToolUse" "PostToolUse" "$(field "$out" hookEventName)"
check_eq "1 a builder's notice is not put in front of Dan" "" "$(field "$out" system)"
check_eq "1 said once per band, not on every call" "" "$(agent_fire s1 "$P" a1 "$A")"
usage "$A" msg_3 230000
check_eq "1 still the same band, still quiet" "" "$(agent_fire s1 "$P" a1 "$A")"
usage "$A" msg_4 410000
check "1 a further band of the line is said again" "410,000" "$(field "$(agent_fire s1 "$P" a1 "$A")" additionalContext)"
# A compaction brings it under the line, which re-arms it.
compacted "$A" 410000
usage "$A" msg_5 30000
check_eq "1 back under the line after a compaction, quiet" "" "$(agent_fire s1 "$P" a1 "$A")"
usage "$A" msg_6 205000
check "1 crossing the line again after that is said again" "205,000" "$(field "$(agent_fire s1 "$P" a1 "$A")" additionalContext)"

# One request is written as one line per content block, all with the same id and usage; the last
# line's usage is the request's (the shape tools/cache-usage.py records, measured 2026-10-23).
A2="$WORK/proj/s1/subagents/agent-a2.jsonl"; : > "$A2"
usage "$A2" msg_same 150000
usage "$A2" msg_same 150000
usage "$A2" msg_same 150000
check_eq "1 three lines of one request under the line count as one, quiet" "" "$(agent_fire s1 "$P" a2 "$A2")"

# No agent_transcript_path: the agent's own transcript is found beside the parent's, never the
# parent's read in its place.
A3="$WORK/proj/s1/subagents/agent-a3.jsonl"; : > "$A3"
usage "$A3" msg_1 250000
usage "$P" msg_p 10000
check "1 without agent_transcript_path its own transcript is still read" "250,000" "$(field "$(agent_fire s1 "$P" a3)" additionalContext)"

# A line of model output Claude Code writes itself is not a request.
A4="$WORK/proj/s1/subagents/agent-a4.jsonl"; : > "$A4"
usage "$A4" msg_1 50000
printf '{"type":"assistant","message":{"id":"msg_syn","model":"<synthetic>","content":[],"usage":{"input_tokens":900000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$A4"
printf 'not json at all\n{"type":"assistant","message":{"usage":"broken"}}\n' >> "$A4"
check_eq "1 synthetic and malformed lines are not requests" "" "$(agent_fire s1 "$P" a4 "$A4")"

# ---- 2. A main session: only an orchestrator is held to the line ----
M="$WORK/proj/m1.jsonl"; : > "$M"
usage "$M" msg_1 300000
check_eq "2 a main session that dispatched nothing is not held to the line" "" "$(main_fire m1 "$M")"
agent_call "$M"
usage "$M" msg_2 310000
out="$(main_fire m1 "$M")"
check_eq "2 the orchestrator's notice is a JSON hook answer" "ok" "$(json_ok "$out")"
ctx="$(field "$out" additionalContext)"
check "2 an orchestrator past the line is told its size" "310,000" "$ctx"
check "2 to put decisions on their issues" "issue" "$ctx"
check "2 and offered compact" "/compact" "$ctx"
check "2 and a fresh session" "fresh session" "$ctx"
check "2 Dan sees it too" "310,000" "$(field "$out" system)"
check_eq "2 once per band" "" "$(main_fire m1 "$M")"
G="$WORK/proj/g1.jsonl"; : > "$G"
goal_set "$G"
usage "$G" msg_1 260000
check "2 a /goal run is an orchestrator too" "260,000" "$(field "$(main_fire g1 "$G")" additionalContext)"
# The mark inside a tool's printed output is escaped, so it is not a dispatch.
E="$WORK/proj/e1.jsonl"; : > "$E"
printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"{\\"type\\":\\"tool_use\\",\\"name\\":\\"Agent\\"} and \\"type\\":\\"goal_status\\""}]}}\n' >> "$E"
usage "$E" msg_1 300000
check_eq "2 a dispatch quoted in a tool result is not one" "" "$(main_fire e1 "$E")"

# ---- 3. The line is a setting ----
L="$WORK/proj/s2/subagents/agent-b1.jsonl"; mkdir -p "$WORK/proj/s2/subagents"; : > "$L"; : > "$WORK/proj/s2.jsonl"
usage "$L" msg_1 150000
out="$(printf '{"session_id":"s2","transcript_path":"%s","agent_id":"b1","agent_transcript_path":"%s","hook_event_name":"PostToolUse","tool_name":"Read"}' "$WORK/proj/s2.jsonl" "$L" | CONTEXT_LINE_TOKENS=100000 bash "$HOOK" 2>/dev/null)"
check "3 CONTEXT_LINE_TOKENS moves the line" "past the line of 100,000" "$(field "$out" additionalContext)"
L2="$WORK/proj/s2/subagents/agent-b2.jsonl"; : > "$L2"
usage "$L2" msg_1 250000
out="$(printf '{"session_id":"s2","transcript_path":"%s","agent_id":"b2","agent_transcript_path":"%s","hook_event_name":"PostToolUse","tool_name":"Read"}' "$WORK/proj/s2.jsonl" "$L2" | CONTEXT_LINE_TOKENS=lots bash "$HOOK" 2>/dev/null)"
check "3 a setting that is not a number falls back to the default line" "past the line of 200,000" "$(field "$out" additionalContext)"

# ---- 4. The long session nudge: compactions of a main session ----
C="$WORK/proj/c1.jsonl"; : > "$C"
usage "$C" msg_0 44000
i=1; while [ "$i" -le 4 ]; do usage "$C" "msg_a$i" 700000; compacted "$C" 780000; i=$((i + 1)); done
usage "$C" msg_b 52000
check_eq "4 four compactions say nothing" "" "$(main_fire c1 "$C")"
usage "$C" msg_c 700000
compacted "$C" 790000
usage "$C" msg_d 61000
usage "$C" msg_d 61000
out="$(main_fire c1 "$C")"
check_eq "4 the nudge is a JSON hook answer" "ok" "$(json_ok "$out")"
ctx="$(field "$out" additionalContext)"
sys="$(field "$out" system)"
check "4 the fifth compaction nudges a fresh start" "compacted 5 times" "$sys"
check "4 saying what its next request costs (at least its last)" "61,000" "$sys"
check "4 its size before the last compaction" "790,000" "$sys"
check "4 what it started from" "44,000" "$sys"
check "4 and its average" "averaged" "$sys"
check "4 counting a request written as two lines once" "across its 8 requests" "$sys"
check "4 naming the issue" "claude-config#1940" "$sys"
check "4 the session hears it as well" "compacted 5 times" "$ctx"
check "4 and how to start fresh" "/handoff" "$sys"
check_eq "4 once, not on every call after" "" "$(main_fire c1 "$C")"
usage "$C" msg_e 70000
check_eq "4 nor on the next request" "" "$(main_fire c1 "$C")"
i=1; while [ "$i" -le 5 ]; do usage "$C" "msg_f$i" 700000; compacted "$C" 780000; i=$((i + 1)); done
usage "$C" msg_g 50000
check "4 ten compactions say it again" "compacted 10 times" "$(field "$(main_fire c1 "$C")" system)"
C2="$WORK/proj/c2.jsonl"; : > "$C2"
usage "$C2" msg_0 44000
compacted "$C2" 500000; compacted "$C2" 500000
usage "$C2" msg_1 30000
check "4 CONTEXT_COMPACTIONS_NUDGE moves the count" "compacted 2 times" "$(printf '{"session_id":"c2","transcript_path":"%s","hook_event_name":"PostToolUse","tool_name":"Bash"}' "$C2" | CONTEXT_COMPACTIONS_NUDGE=2 bash "$HOOK" 2>/dev/null)"
S="$WORK/proj/c3/subagents/agent-d1.jsonl"; mkdir -p "$WORK/proj/c3/subagents"; : > "$S"; : > "$WORK/proj/c3.jsonl"
usage "$S" msg_0 44000
i=1; while [ "$i" -le 5 ]; do compacted "$S" 500000; i=$((i + 1)); done
usage "$S" msg_1 30000
check_eq "4 a subagent is never nudged to start a fresh session" "" "$(agent_fire c3 "$WORK/proj/c3.jsonl" d1 "$S")"

# ---- 5. Reading only what is new, and a transcript that was rewritten ----
R="$WORK/proj/r1/subagents/agent-r1.jsonl"; mkdir -p "$WORK/proj/r1/subagents"; : > "$R"; : > "$WORK/proj/r1.jsonl"
usage "$R" msg_1 250000
check "5 the first read says it" "250,000" "$(field "$(agent_fire r1 "$WORK/proj/r1.jsonl" r1 "$R")" additionalContext)"
off="$(python3 -c 'import json,sys,glob; print(json.load(open(glob.glob(sys.argv[1] + "/*r1*")[0]))["offset"])' "$CONTEXT_SIZE_STATE_DIR" 2>/dev/null)"
check_eq "5 the state records how far it has read" "$(wc -c < "$R" | tr -d ' ')" "$off"
# A half written line at the end is left for the next run, never parsed as broken.
printf '{"type":"assistant","message":{"id":"msg_2","model":"m","usage":{"input_tokens":10,"cache_read_input_tokens":4' >> "$R"
check_eq "5 a line still being written is left for later" "" "$(agent_fire r1 "$WORK/proj/r1.jsonl" r1 "$R")"
printf '09890,"cache_creation_input_tokens":100}}}\n' >> "$R"
check "5 and read whole once it is finished" "410,000" "$(field "$(agent_fire r1 "$WORK/proj/r1.jsonl" r1 "$R")" additionalContext)"
: > "$R"
usage "$R" msg_9 20000
check_eq "5 a transcript shorter than what was read starts over, quietly" "" "$(agent_fire r1 "$WORK/proj/r1.jsonl" r1 "$R")"
usage "$R" msg_10 220000
check "5 and its next crossing is said" "220,000" "$(field "$(agent_fire r1 "$WORK/proj/r1.jsonl" r1 "$R")" additionalContext)"

# ---- 6. Failure paths: never block, and say once what could not be checked ----
out="$(main_fire x1 "$WORK/proj/missing.jsonl")"
check "6 a transcript that cannot be read is said, not taken as small" "could not read" "$(field "$out" system)"
check_eq "6 once per session" "" "$(main_fire x1 "$WORK/proj/missing.jsonl")"
out="$(printf 'not json' | bash "$HOOK" 2>/dev/null; echo "rc=$?")"
check_eq "6 a payload that is not JSON exits 0 and says nothing" "rc=0" "$out"
out="$(printf '{"session_id":"x2","hook_event_name":"PostToolUse"}' | bash "$HOOK" 2>/dev/null; echo "rc=$?")"
check_eq "6 a payload with no transcript exits 0 and says nothing" "rc=0" "$out"
if [ "$(id -u)" != 0 ]; then
  RO="$WORK/ro"; mkdir -p "$RO"; chmod 500 "$RO"
  U="$WORK/proj/u1/subagents/agent-u1.jsonl"; mkdir -p "$WORK/proj/u1/subagents"; : > "$U"
  usage "$U" msg_1 250000
  out="$(printf '{"session_id":"u1","transcript_path":"%s","agent_id":"u1","agent_transcript_path":"%s","hook_event_name":"PostToolUse"}' "$WORK/proj/u1.jsonl" "$U" | CONTEXT_SIZE_STATE_DIR="$RO/state" bash "$HOOK" 2>/dev/null; echo "rc=$?")"
  check "6 a state folder that cannot be written still exits 0" "rc=0" "$out"
  check_not "6 and says nothing it could not record, so it cannot repeat on every call" "250,000" "$out"
  chmod 700 "$RO"
fi

# ---- 7. Two runs at once speak once: the second finds the state locked and leaves it ----
K="$WORK/proj/k1/subagents/agent-k1.jsonl"; mkdir -p "$WORK/proj/k1/subagents"; : > "$K"; : > "$WORK/proj/k1.jsonl"
usage "$K" msg_1 260000
mkdir -p "$CONTEXT_SIZE_STATE_DIR"
ready="$WORK/held"
python3 -c '
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(60)
' "$CONTEXT_SIZE_STATE_DIR/k1.k1.lock" "$ready" &
holder=$!
n=0; while [ ! -e "$ready" ] && [ "$n" -lt 200 ]; do sleep 0.05; n=$((n + 1)); done
check_eq "7 a run that finds another holding the state says nothing" "" "$(agent_fire k1 "$WORK/proj/k1.jsonl" k1 "$K")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; holder=""
check "7 and the next run, the lock free, says it once" "260,000" "$(field "$(agent_fire k1 "$WORK/proj/k1.jsonl" k1 "$K")" additionalContext)"
check_eq "7 once" "" "$(agent_fire k1 "$WORK/proj/k1.jsonl" k1 "$K")"

# ---- 8. Registered for every tool call, after it runs ----
SETTINGS="$DIR/../settings.hooks.json"
[ -f "$SETTINGS" ] || SETTINGS="$DIR/../settings.json"
reg="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for m in d["hooks"].get("PostToolUse", []):
    for h in m.get("hooks", []):
        if h.get("command", "").endswith("/hooks/context-size-notice.sh"):
            print("matcher=" + repr(m.get("matcher")))
' "$SETTINGS" 2>/dev/null)"
check_eq "8 registered as a PostToolUse hook on every tool (no matcher)" "matcher=None" "$reg"

# ---- 9. lib/context_size.py, the one sum tools/cache-usage.py also reports through ----
out="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import context_size as c
print(c.context_of({"input_tokens": 1, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 300, "output_tokens": 4000}),
      c.context_of({"input_tokens": "9", "cache_read_input_tokens": True, "cache_creation_input_tokens": None}),
      c.DEFAULT_LINE, c.DEFAULT_COMPACTIONS)
' "$DIR/lib" 2>&1)"
check_eq "9 context_size.py sums input, cache read and cache write, never output, and skips what is not a number" "321 0 200000 5" "$out"

# ---- 10. What must be written down before a restart is one list, said the same in the notice and
# in the orchestrate skill that explains it, so the two cannot drift apart (L83) ----
SKILL="$DIR/../skills/orchestrate/SKILL.md"
skill_text="$(cat "$SKILL" 2>/dev/null)"
notice_text="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import context_size as c; print(c.WRITE_DOWN)' "$DIR/lib" 2>&1)"
for item in "in Dan's words" "quoted with its date" "what was ruled out" "commit shas" "with their ids" "next step" "waiting on Dan"; do
  check "10 the notice's list carries: $item" "$item" "$notice_text"
  check "10 and so does the orchestrate skill: $item" "$item" "$skill_text"
done

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
