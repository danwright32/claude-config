#!/usr/bin/env bash
# Tests for tools/cache-usage.py: prompt cache hit rate per main session and per subagent, and each
# subagent's first request cache write (the startup cost of the always loaded rules) against the size
# of those rules (claude-config#1503). Every fixture line is invented and carries usage fields only.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/cache-usage.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:2000}"; fi; }
absent(){ if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected NOT to contain: $2"; fi; }

P="$WORK/projects"
mkdir -p "$P/-proj-a/sess1/subagents" "$P/-proj-b/sess3/subagents"

# Main session sess1. Request A arrives as TWO lines with one message id (the client writes one line
# per content block, each repeating the usage), so it must count once. Then a malformed line, a
# synthetic message (not a real request), an assistant line with no usage, and request B.
cat > "$P/-proj-a/sess1.jsonl" <<'EOF'
{"type":"user","isSidechain":false,"sessionId":"sess1","timestamp":"2026-10-20T10:00:00Z"}
{"type":"assistant","isSidechain":false,"sessionId":"sess1","entrypoint":"cli","timestamp":"2026-10-20T10:00:01Z","message":{"id":"msg_A","model":"m","usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000},"output_tokens":1}}}
{"type":"assistant","isSidechain":false,"sessionId":"sess1","entrypoint":"cli","timestamp":"2026-10-20T10:00:02Z","message":{"id":"msg_A","model":"m","usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000},"output_tokens":7}}}
{"type":"assistant", this line is not json
{"type":"assistant","isSidechain":false,"sessionId":"sess1","timestamp":"2026-10-20T10:00:03Z","message":{"id":"msg_S","model":"<synthetic>","usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}
{"type":"assistant","isSidechain":false,"sessionId":"sess1","timestamp":"2026-10-20T10:00:04Z","message":{"id":"msg_N","model":"m"}}
{"type":"system","subtype":"compact_boundary","isSidechain":false,"sessionId":"sess1","timestamp":"2026-10-20T10:00:30Z","compactMetadata":{"trigger":"auto","preTokens":1010,"postTokens":10}}
{"type":"assistant","isSidechain":false,"sessionId":"sess1","entrypoint":"cli","timestamp":"2026-10-20T10:01:00Z","message":{"id":"msg_B","model":"m","usage":{"input_tokens":5,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":200},"output_tokens":3}}}
EOF

# Subagent x1 of sess1: two requests, a five minute cache, first write 2000.
cat > "$P/-proj-a/sess1/subagents/agent-x1.jsonl" <<'EOF'
{"type":"user","isSidechain":true,"agentId":"x1","sessionId":"sess1","timestamp":"2026-10-20T10:02:00Z"}
{"type":"assistant","isSidechain":true,"agentId":"x1","sessionId":"sess1","timestamp":"2026-10-20T10:02:01Z","message":{"id":"msg_X1a","model":"m","usage":{"input_tokens":3,"cache_read_input_tokens":500,"cache_creation_input_tokens":2000,"cache_creation":{"ephemeral_5m_input_tokens":2000,"ephemeral_1h_input_tokens":0},"output_tokens":4}}}
{"type":"assistant","isSidechain":true,"agentId":"x1","sessionId":"sess1","timestamp":"2026-10-20T10:02:30Z","message":{"id":"msg_X1b","model":"m","usage":{"input_tokens":2,"cache_read_input_tokens":2500,"cache_creation_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0},"output_tokens":4}}}
EOF
printf '{"agentType":"general-purpose","description":"invented"}\n' > "$P/-proj-a/sess1/subagents/agent-x1.meta.json"

# Main session sess2: assistant lines but not one usage field. Unmeasured, never zero.
cat > "$P/-proj-a/sess2.jsonl" <<'EOF'
{"type":"assistant","isSidechain":false,"sessionId":"sess2","timestamp":"2026-10-21T09:00:00Z","message":{"id":"msg_Q","model":"m"}}
EOF

# Main session old: every request before the window.
cat > "$P/-proj-a/old.jsonl" <<'EOF'
{"type":"assistant","isSidechain":false,"sessionId":"old","timestamp":"2026-10-01T09:00:00Z","message":{"id":"msg_O","model":"m","usage":{"input_tokens":99999,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}}
EOF

# Subagent x2 in another project: one request, first write 4000 on the one hour cache. No meta file.
cat > "$P/-proj-b/sess3/subagents/agent-x2.jsonl" <<'EOF'
{"type":"assistant","isSidechain":true,"agentId":"x2","sessionId":"sess3","timestamp":"2026-10-22T08:00:00Z","message":{"id":"msg_X2","model":"m","usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":4000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":4000},"output_tokens":2}}}
EOF

# The always loaded rules: a CLAUDE.md importing one file that exists and one that does not.
R="$WORK/rules"; mkdir -p "$R"
printf '# r\n@A.md\n@missing.md\n' > "$R/CLAUDE.md"
python3 -c 'import sys; open(sys.argv[1],"w").write("x"*400)' "$R/A.md"

run(){ python3 "$TOOL" --root "$P" --rules "$R/CLAUDE.md" --now 2026-10-23T00:00:00Z --days 7 "$@" 2>&1; }
out="$(run)"; rc=$?
[ "$rc" -eq 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: exit $rc"; echo "${out:0:2000}"; }

check "the window is stated" $'WINDOW\tsince=2026-10-16T00:00:00Z\tuntil=2026-10-23T00:00:00Z' "$out"
check "a main session row counts a split message once and skips the synthetic one" \
  $'SESSION\tmain\tsess1\t-proj-a\tentrypoint=cli\trequests=2\tinput=15\tcache_read=1000\tcache_write=1200\thit_rate=45.1%\tfirst_write=1000\tfirst_read=0' "$out"
check "an assistant line with no usage is counted on its row" $'lines_without_usage=1' "$out"
check "a subagent row carries its parent and type, and its first write" \
  $'SESSION\tsubagent\tx1\tparent=sess1\ttype=general-purpose\trequests=2\tinput=5\tcache_read=3000\tcache_write=2100\thit_rate=58.8%\tfirst_write=2000\tfirst_read=500' "$out"
check "a subagent with no meta file says its type is unknown" $'SESSION\tsubagent\tx2\tparent=sess3\ttype=unknown\trequests=1' "$out"
check "a transcript with no usage is unmeasured" $'UNMEASURED\tmain\tsess2\t-proj-a' "$out"
absent "an unmeasured transcript has no zero row" $'SESSION\tmain\tsess2' "$out"
absent "requests before the window are left out" "99999" "$out"
check "main sessions are summarised apart from the unmeasured one" \
  $'SUMMARY\tmain\ttranscripts=1\tunmeasured=1\trequests=2\tinput=15\tcache_read=1000\tcache_write=1200\twrite_5m=0\twrite_1h=1200\thit_rate=45.1%' "$out"
check "main sessions are also split by entrypoint, interactive apart from headless" \
  $'SUMMARY\tmain\tentrypoint=cli\ttranscripts=1\trequests=2\tinput=15\tcache_read=1000\tcache_write=1200\twrite_5m=0\twrite_1h=1200\thit_rate=45.1%' "$out"
check "subagents are summarised separately" \
  $'SUMMARY\tsubagent\ttranscripts=2\tunmeasured=0\trequests=3\tinput=6\tcache_read=3000\tcache_write=6100\twrite_5m=2100\twrite_1h=4000\thit_rate=32.9%' "$out"
check "the subagent startup cost is a median and a total over the starts" \
  $'STARTUP\tsubagent\tstarts=2\tmedian_first_write=3000\ttotal_first_write=6000' "$out"
check "the rules are measured now, file by file" $'RULES\tfile\t'"$R/A.md"$'\tchars=400' "$out"
check "a missing import is named, not counted as empty" $'RULES\tmissing\t'"$R/missing.md" "$out"
check "the rules total is stated with its estimate method" $'RULES\ttotal\tfiles=2\tchars=422\tapprox_tokens=105' "$out"
check "the startup median is set against the rules" $'median_vs_rules=28.6x' "$out"
check "malformed lines are counted" $'MALFORMED\tlines=1' "$out"
check "the report ends" "END" "$out"

# The context line and the long session nudge (claude-config#1960, #1940) are re-measured here, at
# the defaults the hook uses, read from hooks/lib/context_size.py rather than written twice (L83).
check "the context line defaults to the hook's" $'CONTEXT\tmain\tline=330000\ttranscripts_over=0\trequests_over=0' "$out"
check "the compaction nudge defaults to the hook's" $'COMPACTIONS\tmain\tnudge_at=5\ttranscripts=1\tat_or_over=0' "$out"
out="$(run --context-line 50 --compactions 1)"
# The line is judged on the work above each stretch's floor, the hook's own predicate (#2283).
# Requests: main A 1,010 (its session's floor) and B 1,205 (the floor after its compaction), so no
# work at all; subagents 2,503 then 2,602 (99 above its floor of 2,503), and 4,001 (its floor).
check "requests whose work passes the line and their share of requests and tokens, main" \
  $'CONTEXT\tmain\tline=50\ttranscripts_over=0\trequests_over=0\tshare_of_requests=0.0%\tshare_of_tokens=0.0%\twhole_context_requests_over=2' "$out"
check "and subagents" \
  $'CONTEXT\tsubagent\tline=50\ttranscripts_over=1\trequests_over=1\tshare_of_requests=33.3%\tshare_of_tokens=28.6%\twhole_context_requests_over=3' "$out"
check "main sessions compacted at least the nudge count, and the tokens they read" \
  $'COMPACTIONS\tmain\tnudge_at=1\ttranscripts=1\tat_or_over=1\tshare_of_tokens=100.0%\tmax=1' "$out"

out="$(run --summary)"
absent "summary mode prints no per transcript rows" $'SESSION\t' "$out"
check "summary mode still prints the summaries" $'SUMMARY\tsubagent' "$out"

out="$(python3 "$TOOL" --root "$WORK/none" --rules "$R/CLAUDE.md" --now 2026-10-23T00:00:00Z --days 7 2>&1)"; rc=$?
check "a missing transcripts root is refused" "NO TRANSCRIPTS ROOT" "$out"
[ "$rc" -ne 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: a missing root must not exit 0"; }

out="$(python3 "$TOOL" --root "$P" --rules "$R/CLAUDE.md" --now 2026-10-01T00:00:00Z --days 1 2>&1)"; rc=$?
check "a window holding no requests is refused, not reported as zero" "NO REQUESTS IN WINDOW" "$out"
[ "$rc" -ne 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: an empty window must not exit 0"; }

# A timestamp written without an offset is read as UTC rather than crashing the comparison, and a
# request with no usable timestamp is counted as untimed rather than silently dropped.
Q="$WORK/projects-q"; mkdir -p "$Q/-proj-c"
cat > "$Q/-proj-c/sess4.jsonl" <<'EOF'
{"type":"assistant","isSidechain":false,"sessionId":"sess4","timestamp":"2026-10-20T10:00:00","message":{"id":"msg_T1","model":"m","usage":{"input_tokens":4,"cache_read_input_tokens":6,"cache_creation_input_tokens":0,"output_tokens":1}}}
{"type":"assistant","isSidechain":false,"sessionId":"sess4","message":{"id":"msg_T2","model":"m","usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}}
EOF
out="$(python3 "$TOOL" --root "$Q" --rules "$R/CLAUDE.md" --now 2026-10-23T00:00:00Z --days 7 2>&1)"; rc=$?
check "a timestamp without an offset is read as UTC" $'SESSION\tmain\tsess4\t-proj-c\tentrypoint=unknown\trequests=1\tinput=4\tcache_read=6' "$out"
check "a request with no timestamp is counted as untimed" $'untimed_requests=1' "$out"
[ "$rc" -eq 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: naive timestamp run exit $rc"; }

# The floor each stretch is measured from (claude-config#2283): a session's first request, and its
# first after each compaction, judged at the default line of 330,000 of work (Dan, 2026-11-05).
# Main fl1 starts at 100,000 and reaches 450,000 (350,000 of work), is compacted, starts again at
# 150,000, passes 400,000 (250,000 of work, under the line) and reaches 500,000 (350,000 of work)
# at its third request. Subagent fa1 starts at 130,000 and reaches 400,000, only 270,000 of work,
# so it never crosses, though its whole context does.
F="$WORK/projects-f"; mkdir -p "$F/-proj-f/fl1/subagents"
req(){ # req <kind> <id> <minute> <context>: one invented request whose input totals <context>
  local side=false; [ "$1" = sub ] && side=true
  printf '{"type":"assistant","isSidechain":%s,"sessionId":"fl1","timestamp":"2026-10-20T10:%02d:00Z","message":{"id":"%s","model":"m","usage":{"input_tokens":0,"cache_read_input_tokens":%d,"cache_creation_input_tokens":0,"output_tokens":1}}}\n' "$side" "$3" "$2" "$4"
}
{
  req main m1 1 100000; req main m2 2 300000; req main m3 3 450000
  printf '{"type":"system","subtype":"compact_boundary","isSidechain":false,"sessionId":"fl1","timestamp":"2026-10-20T10:04:00Z","compactMetadata":{"preTokens":450000,"postTokens":45000}}\n'
  req main m4 5 150000; req main m5 6 400000; req main m6 7 500000
} > "$F/-proj-f/fl1.jsonl"
{ req sub s1 1 130000; req sub s2 2 400000; } > "$F/-proj-f/fl1/subagents/agent-fa1.jsonl"
out="$(python3 "$TOOL" --root "$F" --rules "$R/CLAUDE.md" --now 2026-10-23T00:00:00Z --days 7 --summary 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: floor run exit $rc"; echo "${out:0:2000}"; }
check "the line counts only work above the floor, beside what the whole context would have counted" \
  $'CONTEXT\tmain\tline=330000\ttranscripts_over=1\trequests_over=2\tshare_of_requests=33.3%\tshare_of_tokens=50.0%\twhole_context_requests_over=3' "$out"
check "a subagent whose work stays under the line has no request over it" \
  $'CONTEXT\tsubagent\tline=330000\ttranscripts_over=0\trequests_over=0\tshare_of_requests=0.0%\tshare_of_tokens=0.0%\twhole_context_requests_over=1' "$out"
check "the floors are reported, session starts apart from after a compaction" \
  $'FLOOR\tmain\tsession_starts=1\tmedian=100000\tmin=100000\tmax=100000\tafter_compaction=1\tmedian=150000\tmin=150000\tmax=150000' "$out"
check "and for subagents, which here never compacted" \
  $'FLOOR\tsubagent\tsession_starts=1\tmedian=130000\tmin=130000\tmax=130000\tafter_compaction=0\tmedian=n/a\tmin=n/a\tmax=n/a' "$out"
check "each stretch, and how many requests into it the line was crossed" \
  $'STRETCHES\tmain\tline=330000\tstretches=2\tcrossed=2\tmedian_requests_to_cross=3' "$out"
check "a stretch that never crossed is counted, not dropped" \
  $'STRETCHES\tsubagent\tline=330000\tstretches=1\tcrossed=0\tmedian_requests_to_cross=n/a' "$out"
absent "counts only: no session id or project in the floor and stretch lines" $'FLOOR\tmain\tfl1' "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
