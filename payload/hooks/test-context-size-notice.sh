#!/usr/bin/env bash
# Tests for context-size-notice.sh (claude-config#1960, #1940, #3307): the context line, read from
# the transcript a PostToolUse payload names, and the long session question, asked from a Stop.
#
# - A builder (any subagent) or an orchestrator (a main session that has dispatched an agent or set
#   a /goal) whose last request carried more than the line (CONTEXT_LINE_TOKENS, 330,000) ABOVE its
#   floor is told, once per band of the line, to write down what it has decided and then restart or
#   compact. The floor is the first request of the session, or of the stretch since its latest
#   compaction (claude-config#2283), so the fixed load every request carries is never counted as
#   work. Most fixtures below open with a small first request (`start`), so their floor is 10,000,
#   and they are sized against the default line, so the first band is 330,000 to 660,000 of work.
# - A main session compacted CONTEXT_COMPACTIONS_NUDGE (5) times has Dan asked, when its turn ends,
#   whether to hand off to a fresh session, with what it has read and what a fresh session would
#   save (claude-config#3307): once per crossing, again only once it has read half as much again,
#   never asleep, never in a subagent or a headless run.
# Every check below was seen failing before the hook existed (L1).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The one ceiling a wait on a condition gives up at (claude-config#1620), and the one settings lookup.
. "$DIR/lib/hang-wait.sh" || {
  echo "FAIL: $(basename "$0"): lib/hang-wait.sh is missing, so this suite's waits have no ceiling."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
. "$DIR/lib/settings-file.sh" || {
  echo "FAIL: $(basename "$0"): lib/settings-file.sh is missing, so the hook's registration cannot be read."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
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
unset CONTEXT_LINE_TOKENS CONTEXT_COMPACTIONS_NUDGE CONTEXT_SIZE_NOW CLAUDE_DETACHED_RUN
# Awake unless a check below writes a sleep record (lib/sleep.sh reads a missing one as awake).
export CLAUDE_SLEEP_RECORD="$WORK/no-sleep-record.json"

# ---- transcript lines, written the way Claude Code writes them (compact JSON, one line each) ----
usage(){ # usage <file> <message id> <context tokens>: one request whose input totals <context>
  printf '{"type":"assistant","isSidechain":false,"message":{"id":"%s","model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":10,"cache_read_input_tokens":%d,"cache_creation_input_tokens":100}}}\n' "$2" "$(( $3 - 110 ))" >> "$1"
}
start(){ # start <file>: a first request of 10,000, so the fixture's floor is small (#2283)
  usage "$1" msg_start 10000
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
if k in ("decision", "reason"):
    print(d.get(k, ""))
else:
    print(d.get("systemMessage", "") if k == "system" else d.get("hookSpecificOutput", {}).get(k, ""))
' "$2" 2>/dev/null; }
stop_fire(){ # stop_fire <session> <transcript> [stop_hook_active]: the main session's turn ending,
  # run as it is registered there (--stop)
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"/tmp","hook_event_name":"Stop","stop_hook_active":%s}' "$1" "$2" "${3:-false}" | bash "$HOOK" --stop 2>/dev/null
}
headless_usage(){ # headless_usage <file> <message id> <context>: a request of a claude -p run
  printf '{"type":"assistant","entrypoint":"sdk-cli","message":{"id":"%s","model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":10,"cache_read_input_tokens":%d,"cache_creation_input_tokens":100}}}\n' "$2" "$(( $3 - 110 ))" >> "$1"
}
asked_question(){ # asked_question <state file>: the long session question the hook last put
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("ask", {}).get("question", ""))' "$1" 2>/dev/null
}
answered(){ # answered <file> <question> <answer>: Dan's answer to that picker, as Claude Code writes it
  # (toolUseResult with questions and answers keyed by the question, read off a real transcript).
  python3 -c '
import json, sys
path, q, a = sys.argv[1:4]
opts = [{"label": l, "description": "d"} for l in ("Hand off (Recommended)", "Carry on", "Keep for a day")]
line = {"type": "user", "message": {"role": "user", "content": [
          {"type": "tool_result", "tool_use_id": "toolu_long", "content": "answered"}]},
        "toolUseResult": {"questions": [{"question": q, "header": "Long session", "options": opts,
                                         "multiSelect": False}], "answers": {q: a}, "annotations": {}}}
open(path, "a").write(json.dumps(line, separators=(",", ":")) + "\n")
' "$1" "$2" "$3"
}

# ---- 1. A builder: any subagent, its own transcript beside its parent's ----
P="$WORK/proj/s1.jsonl"; mkdir -p "$WORK/proj/s1/subagents"; : > "$P"
A="$WORK/proj/s1/subagents/agent-a1.jsonl"; : > "$A"
start "$A"
usage "$A" msg_1 150000
check_eq "1 a builder under the line hears nothing" "" "$(agent_fire s1 "$P" a1 "$A")"
usage "$A" msg_2 352345
out="$(agent_fire s1 "$P" a1 "$A")"
check_eq "1 the notice is a JSON hook answer" "ok" "$(json_ok "$out")"
ctx="$(field "$out" additionalContext)"
check "1 a builder past the line is told its size" "352,345" "$ctx"
check "1 and the line" "330,000" "$ctx"
check "1 and where to write down what it decided" "handoff.md" "$ctx"
# #2490: a builder's note goes in the working folder its brief names, under the session's notes
# folder now, never "your scratchpad folder", which a restart of the Mac empties.
check "1 in the working folder its brief names (#2490)" "working folder your brief names" "$ctx"
check_not "1 never in the scratchpad (#2490)" "scratchpad" "$ctx"
check "1 and what to write down: the decisions" "every decision" "$ctx"
check "1 and the state left behind" "commit" "$ctx"
check "1 and to hand back to a fresh agent" "hand back" "$ctx"
check_not "1 a builder is never offered the compact tool, which refuses it (#2025)" "queue_compact" "$ctx"
check "1 naming the issue" "claude-config#1960" "$ctx"
check_eq "1 the event it answers is PostToolUse" "PostToolUse" "$(field "$out" hookEventName)"
check_eq "1 a builder's notice is not put in front of Dan" "" "$(field "$out" system)"
check_eq "1 said once per band, not on every call" "" "$(agent_fire s1 "$P" a1 "$A")"
usage "$A" msg_3 370000
check_eq "1 still the same band, still quiet" "" "$(agent_fire s1 "$P" a1 "$A")"
usage "$A" msg_4 690000
check "1 a further band of the line is said again" "690,000" "$(field "$(agent_fire s1 "$P" a1 "$A")" additionalContext)"
# A compaction brings it under the line, which re-arms it.
compacted "$A" 690000
usage "$A" msg_5 30000
check_eq "1 back under the line after a compaction, quiet" "" "$(agent_fire s1 "$P" a1 "$A")"
usage "$A" msg_6 375000
check "1 crossing the line again after that is said again" "375,000" "$(field "$(agent_fire s1 "$P" a1 "$A")" additionalContext)"

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
start "$A3"
usage "$A3" msg_1 350000
usage "$P" msg_p 10000
check "1 without agent_transcript_path its own transcript is still read" "350,000" "$(field "$(agent_fire s1 "$P" a3)" additionalContext)"

# A line of model output Claude Code writes itself is not a request.
A4="$WORK/proj/s1/subagents/agent-a4.jsonl"; : > "$A4"
usage "$A4" msg_1 50000
printf '{"type":"assistant","message":{"id":"msg_syn","model":"<synthetic>","content":[],"usage":{"input_tokens":900000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' >> "$A4"
printf 'not json at all\n{"type":"assistant","message":{"usage":"broken"}}\n' >> "$A4"
check_eq "1 synthetic and malformed lines are not requests" "" "$(agent_fire s1 "$P" a4 "$A4")"

# ---- 2. A main session: only an orchestrator is held to the line ----
M="$WORK/proj/m1.jsonl"; : > "$M"
start "$M"
usage "$M" msg_1 360000
check_eq "2 a main session that dispatched nothing is not held to the line" "" "$(main_fire m1 "$M")"
agent_call "$M"
usage "$M" msg_2 370000
out="$(main_fire m1 "$M")"
check_eq "2 the orchestrator's notice is a JSON hook answer" "ok" "$(json_ok "$out")"
ctx="$(field "$out" additionalContext)"
check "2 an orchestrator past the line is told its size" "370,000" "$ctx"
check "2 to put decisions on their issues" "issue" "$ctx"
check "2 and offered compact" "/compact" "$ctx"
check "2 and a fresh session" "fresh session" "$ctx"
# #2025: the tool that queues the compact itself once the note is written, given the note's path.
check "2 and the tool that queues a compact once the note is written" "mcp__status-bar__queue_compact" "$ctx"
check "2 given the note's path" "absolute path of handoff.md" "$ctx"
# #2490: the note's place is the session's notes folder, named in full, where a restart cannot clear it.
check "2 the note is in the session's notes folder, named in full (#2490)" "$CLAUDE_HOME/state/session-notes/proj/m1/handoff.md" "$ctx"
check_not "2 never in the scratchpad (#2490)" "scratchpad" "$ctx"
[ -d "$CLAUDE_HOME/state/session-notes/proj/m1" ] && check "2 and that folder is there to write in (#2490)" ok ok \
  || check "2 and that folder is there to write in (#2490)" ok "missing"
check "2 Dan sees it too" "370,000" "$(field "$out" system)"
check_eq "2 once per band" "" "$(main_fire m1 "$M")"
# #2490: a notes folder that cannot be made is said, to the session and to Dan, never left for the
# compact tool to refuse with no reason given.
# Root ignores a folder's permissions, so there the folder is made and this cannot be measured.
if [ "$(id -u)" != 0 ]; then
  M9="$WORK/proj/m9.jsonl"; : > "$M9"
  start "$M9"; agent_call "$M9"; usage "$M9" msg_1 370000
  mkdir -p "$WORK/rohome/state"; chmod a-w "$WORK/rohome/state"
  out="$(printf '{"session_id":"m9","transcript_path":"%s","cwd":"/tmp","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' "$M9" | CLAUDE_HOME="$WORK/rohome" bash "$HOOK" 2>/dev/null)"
  chmod u+w "$WORK/rohome/state"
  check "2 a notes folder that cannot be made is said to the session (#2490)" "could not be created" "$(field "$out" additionalContext)"
  check "2 and to Dan (#2490)" "could not be created" "$(field "$out" system)"
else
  echo "SUITE-PART-UNMEASURED a notes folder that cannot be made (#2490): running as root, which ignores folder permissions"
fi
G="$WORK/proj/g1.jsonl"; : > "$G"
goal_set "$G"
start "$G"
usage "$G" msg_1 350000
check "2 a /goal run is an orchestrator too" "350,000" "$(field "$(main_fire g1 "$G")" additionalContext)"
# The mark inside a tool's printed output is escaped, so it is not a dispatch.
E="$WORK/proj/e1.jsonl"; : > "$E"
start "$E"
printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"{\\"type\\":\\"tool_use\\",\\"name\\":\\"Agent\\"} and \\"type\\":\\"goal_status\\""}]}}\n' >> "$E"
usage "$E" msg_1 360000
check_eq "2 a dispatch quoted in a tool result is not one" "" "$(main_fire e1 "$E")"

# ---- 3. The line is a setting ----
L="$WORK/proj/s2/subagents/agent-b1.jsonl"; mkdir -p "$WORK/proj/s2/subagents"; : > "$L"; : > "$WORK/proj/s2.jsonl"
start "$L"
usage "$L" msg_1 150000
out="$(printf '{"session_id":"s2","transcript_path":"%s","agent_id":"b1","agent_transcript_path":"%s","hook_event_name":"PostToolUse","tool_name":"Read"}' "$WORK/proj/s2.jsonl" "$L" | CONTEXT_LINE_TOKENS=100000 bash "$HOOK" 2>/dev/null)"
check "3 CONTEXT_LINE_TOKENS moves the line" "past the line of 100,000" "$(field "$out" additionalContext)"
L2="$WORK/proj/s2/subagents/agent-b2.jsonl"; : > "$L2"
start "$L2"
usage "$L2" msg_1 350000
out="$(printf '{"session_id":"s2","transcript_path":"%s","agent_id":"b2","agent_transcript_path":"%s","hook_event_name":"PostToolUse","tool_name":"Read"}' "$WORK/proj/s2.jsonl" "$L2" | CONTEXT_LINE_TOKENS=lots bash "$HOOK" 2>/dev/null)"
check "3 a setting that is not a number falls back to the default line" "past the line of 330,000" "$(field "$out" additionalContext)"

# ---- 4. The long session question (claude-config#3307): a main session past the line has Dan
# asked, with the cost, once per crossing, when its turn ends ----
long_fixture(){ # long_fixture <file> <compactions>: a session that started at 44,000 and compacted N times
  : > "$1"
  usage "$1" msg_0 44000
  local i=1; while [ "$i" -le "$2" ]; do usage "$1" "msg_a$i" 700000; compacted "$1" 780000; i=$((i + 1)); done
}
C="$WORK/proj/c1.jsonl"; long_fixture "$C" 4
usage "$C" msg_b 52000
check_eq "4 four compactions: nothing after a tool call" "" "$(main_fire c1 "$C")"
check_eq "4 four compactions: nothing when the turn ends" "" "$(stop_fire c1 "$C")"
usage "$C" msg_c 700000
compacted "$C" 790000
usage "$C" msg_d 61000
usage "$C" msg_d 61000
check_eq "4 past the line, a tool call says nothing: the question waits for the turn's end" "" "$(main_fire c1 "$C")"
out="$(stop_fire c1 "$C")"
check_eq "4 the turn's end is a JSON hook answer" "ok" "$(json_ok "$out")"
check_eq "4 the fifth compaction holds the turn's end once, to ask Dan" "block" "$(field "$out" decision)"
why="$(field "$out" reason)"
check "4 asked of Dan with a picker" "AskUserQuestion" "$why"
check "4 under the header Long session" "Long session" "$why"
check "4 the question says what the session has read so far" "has read 3.7 million tokens" "$why"
check "4 counting a request written as two lines once" "over 8 requests" "$why"
check "4 and how often it has been compacted" "compacted 5 times" "$why"
check "4 what its requests average" "average 457,000 tokens each" "$why"
check "4 what a fresh session would start near" "start near 44,000" "$why"
check "4 what that saves on each early request" "about 413,000 fewer tokens" "$why"
check "4 and that the saving is an estimate" "an estimate" "$why"
check "4 the recommended answer is first" "1. Hand off (Recommended)" "$why"
check "4 then carry on" "2. Carry on" "$why"
check "4 then keep it in one place for a stated stretch" "3. Keep for a day" "$why"
check "4 carry on states when it asks again" "read 5.5 million tokens" "$why"
check "4 keep states the stretch" "24 hours" "$why"
check "4 handing off writes the note first, so no work is lost" "handoff.md" "$why"
check "4 in this session's notes folder" "session-notes" "$why"
check "4 and says what to do with agents still running" "still running" "$why"
check "4 naming the issue" "claude-config#3307" "$why"
q="$(asked_question "$CONTEXT_SIZE_STATE_DIR/c1.main.json")"
check "4 the question it put is recorded, to read Dan's answer by" "has read 3.7 million tokens" "$q"
check "4 and fits a picker Dan can read (at most 1500 characters)" "fits" "$([ "${#q}" -le 1500 ] && [ "${#q}" -gt 0 ] && echo fits)"
check_eq "4 asked once: the next turn's end is quiet" "" "$(stop_fire c1 "$C")"
check_eq "4 and so is the next tool call" "" "$(main_fire c1 "$C")"
answered "$C" "$q" "Carry on"
usage "$C" msg_e 70000
check_eq "4 Dan said carry on: not asked again while it grows less than half again" "" "$(stop_fire c1 "$C")"
i=1; while [ "$i" -le 5 ]; do usage "$C" "msg_f$i" 700000; compacted "$C" 780000; i=$((i + 1)); done
usage "$C" msg_g 50000
again="$(field "$(stop_fire c1 "$C")" reason)"
check "4 asked again once it has read half as much again" "compacted 10 times" "$again"
check "4 with the new figure" "has read 7.3 million tokens" "$again"

# Unanswered: never asked on every turn's end, only again once the cost has grown by half.
C5="$WORK/proj/c5.jsonl"; long_fixture "$C5" 5
usage "$C5" msg_b 52000
check_eq "4 unanswered: asked at the line" "block" "$(field "$(stop_fire c5 "$C5")" decision)"
usage "$C5" msg_c 300000
check_eq "4 unanswered and grown less than half: quiet" "" "$(stop_fire c5 "$C5")"
usage "$C5" msg_d 900000; usage "$C5" msg_e 900000
check_eq "4 unanswered and grown by half: asked again" "block" "$(field "$(stop_fire c5 "$C5")" decision)"

# Keep for a day: not asked again for a day (KEEP_SECONDS, set in the code, not measured), however
# much it reads, and then only on growth.
C4="$WORK/proj/c4.jsonl"; long_fixture "$C4" 5
usage "$C4" msg_b 52000
T0=1800000000
check_eq "4 keep: asked at the line" "block" "$(field "$(CONTEXT_SIZE_NOW=$T0 stop_fire c4 "$C4")" decision)"
answered "$C4" "$(asked_question "$CONTEXT_SIZE_STATE_DIR/c4.main.json")" "Keep for a day"
usage "$C4" msg_c 60000
check_eq "4 keep: the answer is read on the next tool call" "" "$(CONTEXT_SIZE_NOW=$((T0 + 60)) main_fire c4 "$C4")"
i=1; while [ "$i" -le 6 ]; do usage "$C4" "msg_k$i" 900000; i=$((i + 1)); done
check_eq "4 keep: grown by half within the day, still not asked" "" "$(CONTEXT_SIZE_NOW=$((T0 + 23 * 3600)) stop_fire c4 "$C4")"
check_eq "4 keep: past the day and grown by half, asked again" "block" "$(field "$(CONTEXT_SIZE_NOW=$((T0 + 25 * 3600)) stop_fire c4 "$C4")" decision)"

# Hand off: the session goes on until Dan starts the fresh one, and is asked again only on growth.
C6="$WORK/proj/c6.jsonl"; long_fixture "$C6" 5
usage "$C6" msg_b 52000
stop_fire c6 "$C6" >/dev/null
answered "$C6" "$(asked_question "$CONTEXT_SIZE_STATE_DIR/c6.main.json")" "Hand off (Recommended)"
usage "$C6" msg_c 60000
check_eq "4 hand off: not asked again at the next turn's end" "" "$(stop_fire c6 "$C6")"

# Another stop hook already holding this turn's end: the question waits for the next one.
C7="$WORK/proj/c7.jsonl"; long_fixture "$C7" 5
usage "$C7" msg_b 52000
check_eq "4 a turn's end another stop hook is continuing is never held again" "" "$(stop_fire c7 "$C7" true)"
check_eq "4 the question waits for the next turn's end" "block" "$(field "$(stop_fire c7 "$C7")" decision)"

# Asleep (sleep mode): nothing is asked, and the question is held for the first turn's end after wake.
C8="$WORK/proj/c8.jsonl"; long_fixture "$C8" 5
usage "$C8" msg_b 52000
BOOT_NOW="$(sysctl -n kern.boottime 2>/dev/null | sed -n '1s/^[^0-9]*sec *= *\([0-9][0-9]*\).*/\1/p')"
printf '{"v":1,"until":%s,"bootTime":%s}\n' "$(( ($(date +%s) + 3600) * 1000 ))" "${BOOT_NOW:-1}" > "$WORK/asleep.json"
check_eq "4 asleep: the turn's end is not held" "" "$(CLAUDE_SLEEP_RECORD="$WORK/asleep.json" stop_fire c8 "$C8")"
check_eq "4 awake again: the first turn's end asks" "block" "$(field "$(stop_fire c8 "$C8")" decision)"

# Never asked: a subagent, a headless run, a detached run.
S="$WORK/proj/c3/subagents/agent-d1.jsonl"; mkdir -p "$WORK/proj/c3/subagents"; : > "$S"; : > "$WORK/proj/c3.jsonl"
usage "$S" msg_0 44000
i=1; while [ "$i" -le 5 ]; do compacted "$S" 500000; i=$((i + 1)); done
usage "$S" msg_1 30000
check_eq "4 a subagent's tool call is never asked about" "" "$(agent_fire c3 "$WORK/proj/c3.jsonl" d1 "$S")"
check_eq "4 nor its stop" "" "$(printf '{"session_id":"c3","transcript_path":"%s","agent_id":"d1","agent_transcript_path":"%s","hook_event_name":"Stop","stop_hook_active":false}' "$WORK/proj/c3.jsonl" "$S" | bash "$HOOK" --stop 2>/dev/null)"
H="$WORK/proj/h1.jsonl"; : > "$H"
headless_usage "$H" msg_0 44000
i=1; while [ "$i" -le 5 ]; do headless_usage "$H" "msg_a$i" 700000; compacted "$H" 780000; i=$((i + 1)); done
headless_usage "$H" msg_b 52000
check_eq "4 a headless run (claude -p) has nobody to ask" "" "$(stop_fire h1 "$H")"
D="$WORK/proj/d1.jsonl"; long_fixture "$D" 5
usage "$D" msg_b 52000
check_eq "4 a detached run is never asked" "" "$(CLAUDE_DETACHED_RUN=1 stop_fire d1 "$D")"

C2="$WORK/proj/c2.jsonl"; long_fixture "$C2" 2
usage "$C2" msg_1 30000
check "4 CONTEXT_COMPACTIONS_NUDGE moves the line" "compacted 2 times" "$(CONTEXT_COMPACTIONS_NUDGE=2 stop_fire c2 "$C2")"

# ---- 5. Reading only what is new, and a transcript that was rewritten ----
R="$WORK/proj/r1/subagents/agent-r1.jsonl"; mkdir -p "$WORK/proj/r1/subagents"; : > "$R"; : > "$WORK/proj/r1.jsonl"
start "$R"
usage "$R" msg_1 350000
check "5 the first read says it" "350,000" "$(field "$(agent_fire r1 "$WORK/proj/r1.jsonl" r1 "$R")" additionalContext)"
# The state file by its own name: a bare *r1* also matches the .lock beside it, and Linux lists a
# folder in no set order, so CI read the lock (2026-11-01, claude-config#2031).
off="$(python3 -c 'import json,sys,glob; print(json.load(open(glob.glob(sys.argv[1] + "/r1.r1.json")[0]))["offset"])' "$CONTEXT_SIZE_STATE_DIR" 2>/dev/null)"
check_eq "5 the state records how far it has read" "$(wc -c < "$R" | tr -d ' ')" "$off"
# A half written line at the end is left for the next run, never parsed as broken.
printf '{"type":"assistant","message":{"id":"msg_2","model":"m","usage":{"input_tokens":10,"cache_read_input_tokens":6' >> "$R"
check_eq "5 a line still being written is left for later" "" "$(agent_fire r1 "$WORK/proj/r1.jsonl" r1 "$R")"
printf '89890,"cache_creation_input_tokens":100}}}\n' >> "$R"
check "5 and read whole once it is finished" "690,000" "$(field "$(agent_fire r1 "$WORK/proj/r1.jsonl" r1 "$R")" additionalContext)"
: > "$R"
usage "$R" msg_9 20000
check_eq "5 a transcript shorter than what was read starts over, quietly" "" "$(agent_fire r1 "$WORK/proj/r1.jsonl" r1 "$R")"
usage "$R" msg_10 370000
check "5 and its next crossing is said" "370,000" "$(field "$(agent_fire r1 "$WORK/proj/r1.jsonl" r1 "$R")" additionalContext)"

# ---- 6. Failure paths: never block, and say once what could not be checked ----
out="$(main_fire x1 "$WORK/proj/missing.jsonl")"
check "6 a transcript that cannot be read is said, not taken as small" "could not read" "$(field "$out" system)"
check_eq "6 once per session" "" "$(main_fire x1 "$WORK/proj/missing.jsonl")"
# A lone surrogate escape (half an emoji) in the transcript path reaches python3 as a string it
# cannot turn into a file name: said once as unreadable, never a crash or a silent pass (#1944 shape).
out="$(printf '{"session_id":"x3","transcript_path":"/tmp/half\\ud83d.jsonl","hook_event_name":"PostToolUse"}' | bash "$HOOK" 2>/dev/null; echo "rc=$?")"
check "6 a lone surrogate in the transcript path is said as unreadable" "could not read" "$out"
check "6 and exits 0" "rc=0" "$out"
out="$(printf '{"session_id":"x4\\ud83d","transcript_path":"%s","hook_event_name":"PostToolUse"}' "$M" | bash "$HOOK" 2>/dev/null; echo "rc=$?")"
check_eq "6 a lone surrogate in the session id is not a name, so nothing is kept or said" "rc=0" "$out"
out="$(printf 'not json' | bash "$HOOK" 2>/dev/null; echo "rc=$?")"
check_eq "6 a payload that is not JSON exits 0 and says nothing" "rc=0" "$out"
out="$(printf '{"session_id":"x2","hook_event_name":"PostToolUse"}' | bash "$HOOK" 2>/dev/null; echo "rc=$?")"
check_eq "6 a payload with no transcript exits 0 and says nothing" "rc=0" "$out"
if [ "$(id -u)" != 0 ]; then
  RO="$WORK/ro"; mkdir -p "$RO"; chmod 500 "$RO"
  U="$WORK/proj/u1/subagents/agent-u1.jsonl"; mkdir -p "$WORK/proj/u1/subagents"; : > "$U"
  start "$U"
  usage "$U" msg_1 350000
  out="$(printf '{"session_id":"u1","transcript_path":"%s","agent_id":"u1","agent_transcript_path":"%s","hook_event_name":"PostToolUse"}' "$WORK/proj/u1.jsonl" "$U" | CONTEXT_SIZE_STATE_DIR="$RO/state" bash "$HOOK" 2>/dev/null; echo "rc=$?")"
  check "6 a state folder that cannot be written still exits 0" "rc=0" "$out"
  check_not "6 and says nothing it could not record, so it cannot repeat on every call" "350,000" "$out"
  chmod 700 "$RO"
fi

# ---- 7. Two runs at once speak once: the second finds the state locked and leaves it ----
K="$WORK/proj/k1/subagents/agent-k1.jsonl"; mkdir -p "$WORK/proj/k1/subagents"; : > "$K"; : > "$WORK/proj/k1.jsonl"
start "$K"
usage "$K" msg_1 360000
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
hang_wait '[ -e "$ready" ]' 0.05 || { fail=$((fail + 1)); echo "FAIL: 7 the lock holder never took the lock"; }
check_eq "7 a run that finds another holding the state says nothing" "" "$(agent_fire k1 "$WORK/proj/k1.jsonl" k1 "$K")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; holder=""
check "7 and the next run, the lock free, says it once" "360,000" "$(field "$(agent_fire k1 "$WORK/proj/k1.jsonl" k1 "$K")" additionalContext)"
check_eq "7 once" "" "$(agent_fire k1 "$WORK/proj/k1.jsonl" k1 "$K")"

# ---- 8. Registered for every tool call, after it runs ----
SETTINGS="$(hook_settings_file "$DIR/..")"
reg="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for m in d["hooks"].get("PostToolUse", []):
    for h in m.get("hooks", []):
        if h.get("command", "").endswith("/hooks/context-size-notice.sh"):
            print("matcher=" + repr(m.get("matcher")))
' "$SETTINGS" 2>/dev/null)"
check_eq "8 registered as a PostToolUse hook on every tool (no matcher)" "matcher=None" "$reg"
stop_reg="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for m in d["hooks"].get("Stop", []):
    for h in m.get("hooks", []):
        if h.get("command", "").endswith("/hooks/context-size-notice.sh --stop"):
            print("stop timeout=%s" % h.get("timeout"))
' "$SETTINGS" 2>/dev/null)"
check_eq "8 and as a Stop hook with --stop, where the long session question is asked (#3307)" "stop timeout=10" "$stop_reg"

# ---- 9. lib/context_size.py, the one sum tools/cache-usage.py also reports through ----
# lib/ is spelt from BASH_SOURCE here and in 10, never "$DIR/lib": this suite sources hang-wait.sh,
# whose waits run their condition in this shell, where it can set any name, so past that line the
# Slack drafts gate is sure of no variable. It could not find context_size through $DIR and refused
# the whole suite when a session ran it (claude-config#2668). test-slack-drafts-only-gate.sh judges
# this suite, so putting the variable back fails there.
out="$(python3 -B -c '
import sys
sys.path.insert(0, sys.argv[1])
import context_size as c
print(c.context_of({"input_tokens": 1, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 300, "output_tokens": 4000}),
      c.context_of({"input_tokens": "9", "cache_read_input_tokens": True, "cache_creation_input_tokens": None}),
      c.DEFAULT_LINE, c.DEFAULT_COMPACTIONS)
' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib" 2>&1)"
check_eq "9 context_size.py sums input, cache read and cache write, never output, and skips what is not a number" "321 0 330000 5" "$out"

# ---- 10. What must be written down before a restart is one list, said the same in the notice and
# in the orchestrate skill that explains it, so the two cannot drift apart (L83) ----
SKILL="$DIR/../skills/orchestrate/SKILL.md"
skill_text="$(cat "$SKILL" 2>/dev/null)"
notice_text="$(python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import context_size as c; print(c.WRITE_DOWN)' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib" 2>&1)"
for item in "in Dan's words" "quoted with its date" "what was ruled out" "commit shas" "with their ids" "next step" "waiting on Dan"; do
  check "10 the notice's list carries: $item" "$item" "$notice_text"
  check "10 and so does the orchestrate skill: $item" "$item" "$skill_text"
done

# ---- 11. A subagent whose agent_id is empty or not a string is still a subagent, so it never
# shares the main session's state or lock (claude-config#2035): it is kept by its own transcript,
# or, with no transcript of its own, said once to be unmeasured (L11). State files are named
# exactly, never globbed, since Linux lists a folder in no set order ----
by_path(){ # by_path <session> <transcript>: the exact state file a subagent with no usable id keeps
  python3 -c 'import hashlib, sys; print("%s/%s.bypath-%s.json" % (sys.argv[1], sys.argv[2], hashlib.sha256(sys.argv[3].encode("utf-8", "surrogatepass")).hexdigest()[:16]))' "$CONTEXT_SIZE_STATE_DIR" "$1" "$2"
}
Z="$WORK/proj/z1.jsonl"; : > "$Z"
start "$Z"
agent_call "$Z"
usage "$Z" msg_1 370000
check "11 the orchestrator is told its size first" "370,000" "$(field "$(main_fire z1 "$Z")" additionalContext)"
ZS="$CONTEXT_SIZE_STATE_DIR/z1.main.json"
main_before="$(cat "$ZS" 2>/dev/null)"
check "11 and its state is kept under its own name" '"offset"' "$main_before"
EA="$WORK/proj/z1/subagents/agent-empty.jsonl"; mkdir -p "$WORK/proj/z1/subagents"; : > "$EA"
start "$EA"
usage "$EA" msg_1 350000
out="$(printf '{"session_id":"z1","transcript_path":"%s","agent_id":"","agent_transcript_path":"%s","hook_event_name":"PostToolUse","tool_name":"Read"}' "$Z" "$EA" | bash "$HOOK" 2>/dev/null)"
check "11 a subagent with an empty agent_id is told its own size" "350,000" "$(field "$out" additionalContext)"
check "11 as an agent, not as the session" "this agent's" "$(field "$out" additionalContext)"
check_eq "11 and its notice is not put in front of Dan" "" "$(field "$out" system)"
check_eq "11 the main session's state is untouched by it" "$main_before" "$(cat "$ZS" 2>/dev/null)"
check_eq "11 it keeps its own state, named by its transcript" "yes" "$([ -f "$(by_path z1 "$EA")" ] && echo yes || echo no)"
EB="$WORK/proj/z1/subagents/agent-number.jsonl"; : > "$EB"
start "$EB"
usage "$EB" msg_1 360000
out="$(printf '{"session_id":"z1","transcript_path":"%s","agent_id":42,"agent_transcript_path":"%s","hook_event_name":"PostToolUse","tool_name":"Read"}' "$Z" "$EB" | bash "$HOOK" 2>/dev/null)"
check "11 a subagent whose agent_id is a number is told its own size" "360,000" "$(field "$out" additionalContext)"
check_eq "11 the main session's state is untouched by that one too" "$main_before" "$(cat "$ZS" 2>/dev/null)"
check_eq "11 and it keeps a state of its own, apart from the empty id's" "yes" "$([ -f "$(by_path z1 "$EB")" ] && echo yes || echo no)"
check_eq "11 each is said once per band" "" "$(printf '{"session_id":"z1","transcript_path":"%s","agent_id":"","agent_transcript_path":"%s","hook_event_name":"PostToolUse"}' "$Z" "$EA" | bash "$HOOK" 2>/dev/null)"
out="$(printf '{"session_id":"z1","transcript_path":"%s","agent_id":"","hook_event_name":"PostToolUse","tool_name":"Read"}' "$Z" | bash "$HOOK" 2>/dev/null)"
check "11 a subagent with no usable id and no transcript of its own is said to be unmeasured" "not being watched" "$(field "$out" additionalContext)"
check "11 naming the issue" "claude-config#2035" "$(field "$out" additionalContext)"
check_eq "11 to the agent only, not to Dan" "" "$(field "$out" system)"
check_eq "11 once" "" "$(printf '{"session_id":"z1","transcript_path":"%s","agent_id":null,"hook_event_name":"PostToolUse"}' "$Z" | bash "$HOOK" 2>/dev/null)"
check_eq "11 and it never read the main session's transcript as its own" "$main_before" "$(cat "$ZS" 2>/dev/null)"
out="$(printf '{"session_id":"z2","transcript_path":"%s","agent_id":"","agent_transcript_path":"/tmp/half\\ud83d.jsonl","hook_event_name":"PostToolUse"}' "$Z" | bash "$HOOK" 2>/dev/null; echo "rc=$?")"
check "11 a lone surrogate in such an agent's transcript path is said as unreadable" "could not read" "$out"
check "11 and exits 0" "rc=0" "$out"
check_eq "11 and the main session of that run keeps no state from it" "no" "$([ -f "$CONTEXT_SIZE_STATE_DIR/z2.main.json" ] && echo yes || echo no)"
# A subagent with a good id whose own transcript cannot be found (no agent_transcript_path, and a
# parent path not ending in .jsonl to find it beside) is said once per agent to be unmeasured.
out="$(agent_fire y1 "$WORK/proj/y1-no-extension" v1)"
check "11 a subagent whose own transcript cannot be found is said to be unmeasured" "not being watched" "$(field "$out" additionalContext)"
check "11 saying why: its transcript could not be found" "could not find this agent's own transcript" "$(field "$out" additionalContext)"
check "11 naming the issue there too" "claude-config#2035" "$(field "$out" additionalContext)"
check_eq "11 to that agent only, not to Dan" "" "$(field "$out" system)"
check_eq "11 once for that agent" "" "$(agent_fire y1 "$WORK/proj/y1-no-extension" v1)"
check "11 and once for each other such agent" "not being watched" "$(field "$(agent_fire y1 "$WORK/proj/y1-no-extension" v2)" additionalContext)"
# An empty session_id is no name either: every session-less payload would otherwise share one file.
out="$(printf '{"session_id":"","transcript_path":"%s","hook_event_name":"PostToolUse"}' "$Z" | bash "$HOOK" 2>/dev/null; echo "rc=$?")"
check_eq "11 an empty session_id says nothing and exits 0" "rc=0" "$out"
check_eq "11 and keeps no nameless state" "no" "$([ -f "$CONTEXT_SIZE_STATE_DIR/.main.json" ] && echo yes || echo no)"
usage "$Z" msg_2 690000
check "11 the main session's own reading goes on unchanged: its next band is said" "690,000" "$(field "$(main_fire z1 "$Z")" additionalContext)"
off="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["offset"])' "$ZS" 2>/dev/null)"
check_eq "11 having read exactly its own transcript" "$(wc -c < "$Z" | tr -d ' ')" "$off"

# ---- 12. The line measures the work above the session's own floor, never its fixed load
# (claude-config#2283). On the work MacBook a session's first request carried a median of 111,043
# tokens and its first after a compaction 134,075 (the rules, the tool list, the re-attached skills
# and the summary), so a line on the whole context fired after about 65,000 tokens of work ----
F="$WORK/proj/f1/subagents/agent-f1.jsonl"; mkdir -p "$WORK/proj/f1/subagents"; : > "$F"; : > "$WORK/proj/f1.jsonl"
usage "$F" msg_1 130000
usage "$F" msg_2 250000
check_eq "12 a builder that started at 130,000 is not told at 250,000 (120,000 of work)" "" "$(agent_fire f1 "$WORK/proj/f1.jsonl" f1 "$F")"
usage "$F" msg_3 320000
check_eq "12 nor at 320,000 (190,000 of work)" "" "$(agent_fire f1 "$WORK/proj/f1.jsonl" f1 "$F")"
# The default is 330,000 of work, Dan's decision of 2026-11-05 ("maybe 330k of work?"), so 205,000
# of work, past the 200,000 the line was before, is still quiet.
usage "$F" msg_4 335000
check_eq "12 nor at 335,000 (205,000 of work, under the default line of 330,000)" "" "$(agent_fire f1 "$WORK/proj/f1.jsonl" f1 "$F")"
usage "$F" msg_5 465000
ctx="$(field "$(agent_fire f1 "$WORK/proj/f1.jsonl" f1 "$F")" additionalContext)"
check "12 it is told once its work passes the line" "465,000" "$ctx"
check "12 saying how much of it is work" "335,000" "$ctx"
check "12 and the floor it is measured from" "130,000" "$ctx"
check "12 naming this issue" "claude-config#2283" "$ctx"

O="$WORK/proj/o1.jsonl"; : > "$O"
agent_call "$O"
usage "$O" msg_1 110000
usage "$O" msg_2 320000
check_eq "12 an orchestrator that started at 110,000 is not told at 320,000 (210,000 of work)" "" "$(main_fire o1 "$O")"
usage "$O" msg_2b 450000
out="$(main_fire o1 "$O")"
check "12 it is told at 450,000 (340,000 of work)" "450,000" "$(field "$out" additionalContext)"
check "12 Dan sees how much of it is work" "340,000" "$(field "$out" system)"
compacted "$O" 450000
check_eq "12 compacted, with no request since, it is quiet" "" "$(main_fire o1 "$O")"
# The case the issue names: a first request after a compaction already at 150,000.
usage "$O" msg_3 150000
check_eq "12 its first request after the compaction, at 150,000, is its new floor" "" "$(main_fire o1 "$O")"
usage "$O" msg_4 330000
check_eq "12 330,000 after that floor is 180,000 of work, so quiet" "" "$(main_fire o1 "$O")"
usage "$O" msg_4b 470000
check_eq "12 470,000 after that floor is 320,000 of work, still quiet" "" "$(main_fire o1 "$O")"
usage "$O" msg_5 490000
out="$(main_fire o1 "$O")"
ctx="$(field "$out" additionalContext)"
check "12 at 490,000 it is 340,000 of work, and said" "490,000" "$ctx"
check "12 measured from the floor after its last compaction" "150,000" "$ctx"
check "12 named as the floor since the compaction" "after its last compaction" "$ctx"
check "12 Dan sees that floor too" "150,000" "$(field "$out" system)"
check_eq "12 once per band" "" "$(main_fire o1 "$O")"

# ---- 13. A state kept before the floor existed is read again from the start, so the floor of a
# session already running when this ships is known rather than taken as zero (L1010: a new state
# version, never an edited one) ----
V="$WORK/proj/v1/subagents/agent-w1.jsonl"; mkdir -p "$WORK/proj/v1/subagents"; : > "$V"; : > "$WORK/proj/v1.jsonl"
usage "$V" msg_1 130000
usage "$V" msg_2 250000
python3 -c '
import json, sys
json.dump({"v": 1, "offset": int(sys.argv[2]), "last_id": "msg_2", "last_ctx": 250000, "first_ctx": 130000,
           "requests": 2, "ctx_sum": 380000, "compactions": 0, "last_pre": 0, "orchestrator": False,
           "band_told": 1, "compactions_told": 0, "unreadable_told": False}, open(sys.argv[1], "w"))
' "$CONTEXT_SIZE_STATE_DIR/v1.w1.json" "$(wc -c < "$V" | tr -d ' ')"
usage "$V" msg_3 470000
ctx="$(field "$(agent_fire v1 "$WORK/proj/v1.jsonl" w1 "$V")" additionalContext)"
check "13 a state from before #2283 is read again, so the floor is the first request" "130,000" "$ctx"
check "13 and the work above it is said" "340,000" "$ctx"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
