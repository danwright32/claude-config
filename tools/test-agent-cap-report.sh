#!/usr/bin/env bash
# Tests for tools/agent-cap-report.py: how much of the time sessions sat at the subagent cap, how
# many agents ran at once across the Mac, where an agent's time went, and the days a usage limit
# reached an agent, read from the subagent transcripts (claude-config#2552). Every fixture line is
# invented. The arithmetic behind each expected figure is written beside the fixture it comes from.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/agent-cap-report.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:3000}"; fi; }
absent(){ if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected NOT to contain: $2"; fi; }
is(){ if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  actual: $3"; fi; }

P="$WORK/projects"
mkdir -p "$P/-proj-a/s1/subagents/workflows/w1" "$P/-proj-b/s2/subagents"

# Agent a1, session s1, working folder /work/alpha.
#   A line from the day BEFORE the window (9999 tokens) that must be ignored.
#   10:00:00 to 10:00:40  one 40 second test run. Its request is written as two lines with one
#                         message id, so it counts once and the last usage (100) wins.
#   then a pause of 9 minutes 20 seconds with no command open: NOT running. In the pause sit a
#   line that is not JSON and a line whose timestamp is a number: two bad lines, never a crash.
#   At 10:10:00 sit four more lines whose fields are the wrong shape (usage as a list, a token
#   count in words, a command as a list, and an id, model and folder as lists): four more bad
#   lines, none of them a request, a model or a label.
#   10:10:00 to 10:20:00  a second stretch of 600 seconds.
# Active 640 seconds, 300 output tokens, 2 requests, 40 seconds inside the shell.
# Set by the fixture, not measured.
cat > "$P/-proj-a/s1/subagents/agent-a1.jsonl" <<'EOF'
{"timestamp":"2026-11-09T23:00:00Z","cwd":"/work/alpha","message":{"id":"m0","model":"model-x","usage":{"output_tokens":9999},"content":[]}}
{"timestamp":"2026-11-10T10:00:00Z","cwd":"/work/alpha","message":{"id":"m1","model":"model-x","usage":{"output_tokens":60},"content":[{"type":"text","text":"x"}]}}
{"timestamp":"2026-11-10T10:00:00Z","cwd":"/work/alpha","message":{"id":"m1","model":"model-x","usage":{"output_tokens":100},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npx vitest run secretsuite"}}]}}
{"timestamp":"2026-11-10T10:00:40Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}
{"timestamp":"2026-11-10T10:05:00Z", this line is not json
{"timestamp":1794300000,"message":{"content":[]}}
{"timestamp":"2026-11-10T10:10:00Z","message":{"id":"m2","model":"model-x","usage":{"output_tokens":200},"content":[]}}
{"timestamp":"2026-11-10T10:10:00Z","message":{"id":"m7","model":"model-x","usage":[1,2],"content":[]}}
{"timestamp":"2026-11-10T10:10:00Z","message":{"id":"m8","model":"model-x","usage":{"output_tokens":"many"},"content":[]}}
{"timestamp":"2026-11-10T10:10:00Z","message":{"content":[{"type":"tool_use","id":"t9","name":"Bash","input":["npm test"]}]}}
{"timestamp":"2026-11-10T10:10:00Z","cwd":["/work/zeta"],"message":{"id":["m9"],"model":["model-z"],"usage":{"output_tokens":5},"content":[]}}
{"timestamp":"2026-11-10T10:14:00Z","message":{"content":[]}}
{"timestamp":"2026-11-10T10:18:00Z","message":{"id":"m3","content":[]}}
{"timestamp":"2026-11-10T10:20:00Z","message":{"content":[]}}
EOF

# Agent a2, session s1, in a worktree of alpha: its label is alpha, never the worktree's name.
#   10:12:00 to 10:20:00, 480 seconds, all of it beside a1: two agents in s1 for 8 minutes.
#   A 20 second test run from 10:15:10 and a 240 second wait on CI from 10:16:00.
# Active 480 seconds, 400 output tokens, 1 request, 260 seconds inside the shell.
# Set by the fixture, not measured.
cat > "$P/-proj-a/s1/subagents/agent-a2.jsonl" <<'EOF'
{"timestamp":"2026-11-10T10:12:00Z","cwd":"/work/alpha/.claude/worktrees/issue-9","message":{"id":"m1","model":"model-x","usage":{"output_tokens":400},"content":[]}}
{"timestamp":"2026-11-10T10:15:10Z","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"npm test"}}]}}
{"timestamp":"2026-11-10T10:15:30Z","message":{"content":[{"type":"tool_result","tool_use_id":"t2"}]}}
{"timestamp":"2026-11-10T10:16:00Z","message":{"content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"gh run watch 123"}}]}}
{"timestamp":"2026-11-10T10:20:00Z","message":{"content":[{"type":"tool_result","tool_use_id":"t3"}]}}
EOF

# Agent a3 ran five seconds: it never really ran and is left out, and said to be.
cat > "$P/-proj-a/s1/subagents/agent-a3.jsonl" <<'EOF'
{"timestamp":"2026-11-10T10:30:00Z","cwd":"/work/alpha","message":{"content":[]}}
{"timestamp":"2026-11-10T10:30:05Z","message":{"content":[]}}
EOF

# A workflow's agent in s1 over the same 8 minutes. Workflow agents are counted on their own line
# and left out of every other figure (the 2026-11-09 baseline never read their folder), so s1 must
# still read two at once, not three.
cat > "$P/-proj-a/s1/subagents/workflows/w1/agent-w1.jsonl" <<'EOF'
{"timestamp":"2026-11-10T10:12:00Z","cwd":"/work/alpha","message":{"content":[]}}
{"timestamp":"2026-11-10T10:16:00Z","message":{"content":[]}}
{"timestamp":"2026-11-10T10:20:00Z","message":{"content":[]}}
EOF

# Agent b1, session s2, working folder /work/beta, another model.
#   10:15:00 to 10:19:00, 240 seconds, with a 30 second typecheck from 10:15:00 and a usage limit
#   message at 10:19:00 (05:19 on Nov 10 in New York).
# Active 240 seconds, 240 output tokens, 1 request, 30 seconds inside the shell.
# Set by the fixture, not measured.
cat > "$P/-proj-b/s2/subagents/agent-b1.jsonl" <<'EOF'
{"timestamp":"2026-11-10T10:15:00Z","cwd":"/work/beta","message":{"id":"m1","model":"model-y","usage":{"output_tokens":240},"content":[{"type":"tool_use","id":"t4","name":"Bash","input":{"command":"npx tsc --noEmit"}}]}}
{"timestamp":"2026-11-10T10:15:30Z","message":{"content":[{"type":"tool_result","tool_use_id":"t4"}]}}
{"timestamp":"2026-11-10T10:19:00Z","isApiErrorMessage":true,"message":{"model":"<synthetic>","id":"e1","usage":{"output_tokens":0},"content":[{"type":"text","text":"You've hit your 5-hour limit, resets 3pm (America/New_York)"}]}}
EOF

# A second workflow agent that ran five seconds: it is counted with the workflow agents, where the
# reader looks for it, not with the ordinary agents that were too short.
# Set by the fixture, not measured.
cat > "$P/-proj-a/s1/subagents/workflows/w1/agent-w2.jsonl" <<'EOF'
{"timestamp":"2026-11-10T10:12:00Z","cwd":"/work/alpha","message":{"content":[]}}
{"timestamp":"2026-11-10T10:12:05Z","message":{"content":[]}}
EOF

run(){ python3 "$TOOL" --root "$P" --since 2026-11-10T00:00:00+00:00 --until 2026-11-11T00:00:00+00:00 --min-samples 1 "$@" 2>&1; }

out="$(run --cap 2)"; rc=$?
is "a window with agents in it exits 0" 0 "$rc"
check "the window, its length and the cap judged are stated" \
  $'WINDOW\tsince=2026-11-10T00:00:00+00:00\tuntil=2026-11-11T00:00:00+00:00\tdays=1.0\tcap=2\ttz=America/New_York' "$out"
# 640 + 480 + 240 = 1360 seconds = 0.38 hours. The pause, the day before and the 5 second agent are out.
# Set by the fixture, not measured.
check "agent hours count running time only, and what was left out is said" \
  $'AGENTS\tagents=3\tsessions=2\tagent_hours=0.38\tdropped_short=1\tworkflow_agents=2\tbad_lines=6\tunreadable=0' "$out"
absent "a wrongly shaped line names no model" "model-z" "$out"
absent "and no working folder" "zeta" "$out"
check "agent hours are given per day" $'BY_DAY\t11-10\t0.38' "$out"
check "the label is the working folder's name" $'BY_REPO\talpha\t2' "$out"
check "a second working folder is a second label" $'BY_REPO\tbeta\t1' "$out"
absent "a worktree's own name is never the label" "issue-9" "$out"
# model-x: a1 and a2, 1120 seconds, 700 tokens (2250 an hour), 3 requests (10 an hour), 300 s of shell (27%).
# Set by the fixture, not measured.
check "tokens and requests per agent hour by model, a repeated message id counted once" \
  $'BY_MODEL\tmodel-x\tagents=2\tagent_hours=0.31\tout_per_hour=2250\trequests_per_hour=10\tshell=27%' "$out"
# model-y: b1, 240 seconds, 240 tokens (3600 an hour), 1 request (15 an hour). The limit message is
# written by the client under a synthetic model and is neither a request nor b1's model.
# Set by the fixture, not measured.
check "a client written message is not a request and does not rename the agent's model" \
  $'BY_MODEL\tmodel-y\tagents=1\tagent_hours=0.07\tout_per_hour=3600\trequests_per_hour=15' "$out"
absent "no synthetic model row" "<synthetic>" "$out"
# s1: one agent for 40 + 120 seconds, two for 480. s2: one agent for 240. 880 seconds in all.
# Set by the fixture, not measured.
check "share of session time by agents at once" $'SESSION_LEVELS\thours=0.24\t1=45%\t2=55%' "$out"
check "time at exactly the cap, its stretches of 5 minutes or more, and the sessions that reached it" \
  $'AT_CAP\thours=0.13\tshare=54.5%\tstretches=1\tstretch_hours=0.13\tlongest_min=8\tsessions_reached=1/2' "$out"
check "nothing ran above the cap" $'ABOVE_CAP\thours=0.00\tstretches=0\tlongest_min=0' "$out"
# Across the Mac: 1 agent for 160 s, 2 for 240 s, 3 for 240 s.
# Set by the fixture, not measured.
check "agents at once across every session" $'MAC_LEVELS\tmedian=2\tp90=3\tp99=3\tmost=3' "$out"
# Shell 40 + 260 + 30 = 330 of 1360 (24%). Heavy commands 40 + 20 + 30 = 90 (7%). 940 tokens and 4 requests.
check "where agent time went" $'TIME\tshell=24%\theavy=7%\tout_per_agent_hour=2488\trequests_per_agent_hour=11' "$out"
# Heavy command time: 40 + 10 seconds ran alone, 20 seconds ran as a pair (40 command seconds).
# Set by the fixture, not measured.
check "heavy commands running at once" $'HEAVY_OVERLAP\t1=56%\t2=44%\t3-4=0%\t5-8=0%\t9+=0%\tmost=2' "$out"
check "a kind of command by how many agents were running when it started" \
  $'SLOWDOWN\talpha\ttests\t1-2=40s(1)\t3-4=20s(1)\t5-6=few\t7-9=few\t10+=few' "$out"
check "the limit day is counted in the reader's timezone" $'LIMIT_DAYS\tdays=1\t11-10' "$out"
absent "no command text is printed" "secretsuite" "$out"
absent "no command text is printed for a wait either" "gh run watch" "$out"

out="$(run --cap 2 --min-samples 2)"
absent "a kind with too few samples in every bucket gets no row" "SLOWDOWN" "$out"

# The same transcripts judged against a cap of one: 400 seconds at exactly one, never for 5 minutes
# together, and 480 seconds above it in one stretch.
# Set by the fixture, not measured.
out="$(run --cap 1)"
check "at a lower cap, short stretches at it are not counted as stretches" \
  $'AT_CAP\thours=0.11\tshare=45.5%\tstretches=0\tstretch_hours=0.00\tlongest_min=0\tsessions_reached=2/2' "$out"
check "time above the cap is reported, never folded into time at it" $'ABOVE_CAP\thours=0.13\tstretches=1\tlongest_min=8' "$out"

# A window is cut at both ends. Until 10:16, a1's last line is 10:14 (40 + 240 seconds), a2's is
# 10:15:30 (210 seconds) and b1's is 10:15:30 (30 seconds): 520 seconds = 0.14 hours. The limit
# message is after the cut.
# Set by the fixture, not measured.
out="$(python3 "$TOOL" --root "$P" --since 2026-11-10T00:00:00+00:00 --until 2026-11-10T10:16:00+00:00 --cap 2 2>&1)"
check "lines at or after the end of the window are ignored" "agent_hours=0.14" "$out"
check "a limit message outside the window is not a limit day" $'LIMIT_DAYS\tdays=0' "$out"

# Timezone: a limit message at 03:05 UTC on Nov 10 is 10:05 PM on Nov 9 in New York. This agent has
# no working folder on any line, so it has no label to give.
Z="$WORK/tz"; mkdir -p "$Z/-proj-z/s9/subagents"
cat > "$Z/-proj-z/s9/subagents/agent-z1.jsonl" <<'EOF'
{"timestamp":"2026-11-10T03:00:00Z","message":{"content":[]}}
{"timestamp":"2026-11-10T03:04:00Z","message":{"content":[]}}
{"timestamp":"2026-11-10T03:05:00Z","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"You're out of usage credits. Run /usage-credits"}]}}
EOF
out="$(python3 "$TOOL" --root "$Z" --since 2026-11-10T00:00:00+00:00 --until 2026-11-11T00:00:00+00:00 --cap 7 2>&1)"
check "a late evening limit belongs to that evening's day" $'LIMIT_DAYS\tdays=1\t11-09' "$out"
check "an agent with no working folder is labelled unknown" $'BY_REPO\tunknown\t1' "$out"
out="$(python3 "$TOOL" --root "$Z" --since 2026-11-10T00:00:00+00:00 --until 2026-11-11T00:00:00+00:00 --cap 7 --tz UTC 2>&1)"
check "the timezone can be named" $'LIMIT_DAYS\tdays=1\t11-10' "$out"

# Failure paths: every one is a named refusal with exit 1, never an empty report that reads as a
# quiet week (L90).
out="$(python3 "$TOOL" --root "$WORK/none" --since 2026-11-10T00:00:00+00:00 --until 2026-11-11T00:00:00+00:00 --cap 7 2>&1)"; rc=$?
is "a missing transcripts folder exits 1" 1 "$rc"
check "and says so" "NO TRANSCRIPTS ROOT" "$out"
out="$(python3 "$TOOL" --root "$P" --since 2026-12-01T00:00:00+00:00 --until 2026-12-02T00:00:00+00:00 --cap 7 2>&1)"; rc=$?
is "a window no agent ran in exits 1" 1 "$rc"
check "and says so" "NO AGENTS IN WINDOW" "$out"
absent "with no report lines" "AT_CAP" "$out"
out="$(python3 "$TOOL" --root "$P" --since 2026-11-11T00:00:00+00:00 --until 2026-11-10T00:00:00+00:00 --cap 7 2>&1)"; rc=$?
is "a window that ends before it starts exits 1" 1 "$rc"
check "and says so" "WINDOW IS EMPTY" "$out"
out="$(python3 "$TOOL" --root "$P" --since 2026-11-10T00:00:00 --until 2026-11-11T00:00:00+00:00 --cap 7 2>&1)"; rc=$?
is "a time with no offset exits 1, since it would be read in whatever zone the Mac is in" 1 "$rc"
check "and says so" "NEEDS AN OFFSET" "$out"

# A transcript that cannot be read is counted and named as unreadable, and the rest are still measured.
U="$WORK/unreadable"; mkdir -p "$U/-proj-u/s5/subagents/agent-dir.jsonl"
cp "$P/-proj-b/s2/subagents/agent-b1.jsonl" "$U/-proj-u/s5/subagents/agent-b1.jsonl"
# A link to a transcript that is gone stands for one deleted between the listing and the read.
ln -s "$U/gone.jsonl" "$U/-proj-u/s5/subagents/agent-gone.jsonl"
out="$(python3 "$TOOL" --root "$U" --since 2026-11-10T00:00:00+00:00 --until 2026-11-11T00:00:00+00:00 --cap 7 2>&1)"; rc=$?
is "an unreadable transcript does not stop the report" 0 "$rc"
check "it is counted as unreadable, not as an agent that never ran" $'agents=1\tsessions=1\tagent_hours=0.07\tdropped_short=0\tworkflow_agents=0\tbad_lines=0\tunreadable=2' "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
