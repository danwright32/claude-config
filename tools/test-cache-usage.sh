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

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
