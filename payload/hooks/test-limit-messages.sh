#!/usr/bin/env bash
# Tests for limit-messages.py: the record of every usage limit message on this Mac, with its kind and
# the reset time it names, and the reader that prints limit days by kind (claude-config#3308).
#
# Every fixture line copies the SHAPE of a real limit message found in this Mac's transcripts on
# 2026-11-23 (the fields Claude Code writes on an API error line, the wording of each kind, the
# structured quotaLimits block), with invented ids, times and reset times. A sentinel stands in for
# what a person typed, so the suite can prove none of it reaches the record.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/limit-messages.py"
WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
pass=0; fail=0
check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:600}"; fi; }
absent(){ if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected NOT to contain: $2"; echo "  actual: ${3:0:600}"; fi; }
same(){ if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  actual: ${3:0:600}"; fi; }

export HOME="$WORK/home"
export TZ=UTC
# The recorder waits for an error line not yet written; the suite never waits for real (L524).
export LIMIT_MESSAGES_RETRY_DELAYS="0"
mkdir -p "$HOME/.claude/state/status-bar" "$HOME/.claude/projects/-proj/sess-a/subagents"
REC="$HOME/.claude/state/limit-messages/records.jsonl"
SECRET="SENTINEL-TYPED-BY-A-PERSON-91"
records(){ cat "$REC" 2>/dev/null; }
count(){ if [ -f "$REC" ]; then grep -c . "$REC"; else echo 0; fi; }
field(){ python3 -c 'import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(rows[int(sys.argv[2])].get(sys.argv[3]))' "$REC" "$1" "$2"; }

# The session's account as the status bar mod records it at session start. Key is the first 16 hex
# digits of SHA-256 over "<account id>:<org id>", as the account room keys it.
cat > "$HOME/.claude/state/status-bar/sess-a.json" <<'EOF'
{"v":1,"sessionId":"sess-a","cacheExpiresAt":0,"account":{"accountUuid":"acct-1","organizationUuid":"org-1","displayName":"Invented Name","emailAddress":"invented@example.com","organizationName":"Invented Org","organizationType":"claude_max"}}
EOF
KEY="$(printf 'acct-1:org-1' | shasum -a 256 | cut -c1-16)"

MAIN="$HOME/.claude/projects/-proj/sess-a.jsonl"
cat > "$MAIN" <<EOF
{"type":"user","isSidechain":false,"sessionId":"sess-a","uuid":"u-1","timestamp":"2026-11-10T19:00:00.000Z","message":{"role":"user","content":"$SECRET"}}
{"type":"assistant","isSidechain":false,"sessionId":"sess-a","uuid":"u-2","timestamp":"2026-11-10T19:00:05.000Z","entrypoint":"cli","message":{"model":"claude-fable","content":[{"type":"text","text":"$SECRET reply"}]}}
{"type":"assistant","isSidechain":false,"sessionId":"sess-a","uuid":"u-3","timestamp":"2026-11-10T19:01:00.000Z","entrypoint":"cli","isApiErrorMessage":true,"error":"server_error","message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: 529 Overloaded. This is a server-side issue, usually temporary"}]}}
{"type":"assistant","isSidechain":false,"sessionId":"sess-a","uuid":"u-4","timestamp":"2026-11-10T19:02:00.000Z","entrypoint":"cli","isApiErrorMessage":true,"error":"rate_limit","apiError":"usage_limit_reached","apiErrorStatus":429,"apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":1794341400,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"out_of_credits","isUsingOverage":false}},"quotaLimits":{"status":"rejected","resetsAt":1794341400,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"out_of_credits","isUsingOverage":false},"message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your 5-hour limit · resets 3:10pm (America/New_York)"}]}}
EOF
STOP_PAYLOAD="{\"session_id\":\"sess-a\",\"transcript_path\":\"$MAIN\",\"cwd\":\"/x\",\"hook_event_name\":\"StopFailure\",\"error\":\"rate_limit\",\"last_assistant_message\":\"You've hit your 5-hour limit · resets 3:10pm (America/New_York)\"}"

# 1. A main session's StopFailure on a five hour limit writes one record from the transcript line.
out="$(printf '%s' "$STOP_PAYLOAD" | python3 "$TOOL" record 2>&1)"; rc=$?
same "1 record exits 0" "0" "$rc"
same "1 one record written" "1" "$(count)"
same "1 kind" "five_hour" "$(field 0 kind)"
same "1 reset time from the structured field" "2026-11-10T20:10:00Z" "$(field 0 resets_at)"
same "1 reset read from" "structured" "$(field 0 resets_from)"
same "1 who" "main" "$(field 0 who)"
same "1 account key" "$KEY" "$(field 0 account)"
same "1 overage reason" "out_of_credits" "$(field 0 overage_reason)"
same "1 cycle names kind and reset" "five_hour@2026-11-10T20:10:00Z" "$(field 0 cycle)"
absent "1 no conversation text" "$SECRET" "$(records)"
absent "1 no email" "invented@example.com" "$(records)"
absent "1 no session id" "sess-a" "$(records)"

# 2. The same failure delivered twice (a retry, a second hook) is still one record.
printf '%s' "$STOP_PAYLOAD" | python3 "$TOOL" record >/dev/null 2>&1
same "2 run twice, one record" "1" "$(count)"

# 3. A subagent's SubagentStop: its own transcript holds a model limit (the Fable wording, whose
#    structured type is the ambiguous seven_day_overage_included), so the wording decides the kind.
AG="$HOME/.claude/projects/-proj/sess-a/subagents/agent-x1.jsonl"
cat > "$AG" <<EOF
{"type":"user","isSidechain":true,"agentId":"x1","sessionId":"sess-a","uuid":"a-1","timestamp":"2026-11-14T02:49:00.000Z","message":{"role":"user","content":"$SECRET"}}
{"type":"assistant","isSidechain":true,"agentId":"x1","sessionId":"sess-a","uuid":"a-2","timestamp":"2026-11-14T02:49:54.000Z","entrypoint":"cli","isApiErrorMessage":true,"error":"rate_limit","apiError":"usage_limit_reached","apiErrorStatus":429,"apiErrorType":"rate_limit_error","quotaLimits":{"status":"rejected","resetsAt":1795064400,"rateLimitType":"seven_day_overage_included","overageStatus":"rejected","overageDisabledReason":"out_of_credits","isUsingOverage":false},"message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your Fable limit · resets Nov 19 at 12am (America/New_York). /model to switch models."}]}}
EOF
printf '{"session_id":"sess-a","transcript_path":"%s","agent_id":"x1","agent_transcript_path":"%s","hook_event_name":"SubagentStop","stop_hook_active":false}' "$MAIN" "$AG" | python3 "$TOOL" record >/dev/null 2>&1
same "3 subagent adds one record" "2" "$(count)"
same "3 kind" "model" "$(field 1 kind)"
same "3 model named" "Fable" "$(field 1 model)"
same "3 who" "agent" "$(field 1 who)"
same "3 structured type kept" "seven_day_overage_included" "$(field 1 limit_type)"
same "3 account read through the parent session" "$KEY" "$(field 1 account)"

# 4. Older lines carry no structured block: the reset time is read from the wording, against the
#    message's own time, in the zone it names. "session limit" is the older name of the five hour one.
#    A headless run (entrypoint sdk-cli) in a session with no status bar record: account unread.
OLD="$HOME/.claude/projects/-proj/sess-b.jsonl"
cat > "$OLD" <<'EOF'
{"type":"assistant","isSidechain":false,"sessionId":"sess-b","uuid":"b-1","timestamp":"2026-10-29T17:49:34.000Z","entrypoint":"sdk-cli","isApiErrorMessage":true,"error":"rate_limit","message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit · resets 2:30pm (America/New_York)"}]}}
{"type":"assistant","isSidechain":false,"sessionId":"sess-b","uuid":"b-2","timestamp":"2026-10-28T00:23:51.000Z","entrypoint":"sdk-cli","isApiErrorMessage":true,"error":"rate_limit","message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your weekly limit · resets Oct 30 at 6am (America/New_York)"}]}}
{"type":"assistant","isSidechain":false,"sessionId":"sess-b","uuid":"b-3","timestamp":"2026-10-27T05:00:00.000Z","entrypoint":"sdk-cli","isApiErrorMessage":true,"error":"rate_limit","message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your org's monthly spend limit · run /usage-credits to ask your admin for a higher limit · your session limit resets 1:20am (America/New_York)"}]}}
{"type":"assistant","isSidechain":true,"agentId":"y","sessionId":"sess-b","uuid":"b-4","timestamp":"2026-11-17T01:44:23.000Z","entrypoint":"cli","isApiErrorMessage":true,"error":"unknown","apiErrorStatus":429,"apiErrorType":"rate_limit_error","message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: This request would exceed your account's rate limit. Please try again later."}]}}
{"type":"assistant","isSidechain":false,"sessionId":"sess-b","uuid":"b-5","timestamp":"2026-10-25T19:32:57.000Z","entrypoint":"cli","isApiErrorMessage":true,"error":"server_error","message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: Can't reach the API server"}]}}
EOF
printf '{"session_id":"sess-b","transcript_path":"%s","hook_event_name":"StopFailure","error":"rate_limit"}' "$OLD" | python3 "$TOOL" record >/dev/null 2>&1
same "4 four limit lines, the server error left out" "6" "$(count)"
same "4 session limit is the five hour kind" "five_hour" "$(field 2 kind)"
same "4 time only reset read from wording" "2026-10-29T18:30:00Z" "$(field 2 resets_at)"
same "4 read from wording" "wording" "$(field 2 resets_from)"
same "4 headless" "headless" "$(field 2 who)"
same "4 account unread" "None" "$(field 2 account)"
same "4 weekly kind" "weekly" "$(field 3 kind)"
same "4 dated reset read from wording" "2026-10-30T10:00:00Z" "$(field 3 resets_at)"
same "4 spend kind" "spend" "$(field 4 kind)"
same "4 spend names the session reset" "2026-10-27T05:20:00Z" "$(field 4 resets_at)"
same "4 account rate limit kind" "rate" "$(field 5 kind)"
same "4 rate limit names no reset" "None" "$(field 5 resets_at)"

# 5. The error line is not in the transcript yet: the record is made from the hook's own message,
#    marked as such, with the account still read from the session.
EMPTY="$HOME/.claude/projects/-proj/sess-a-late.jsonl"
printf '{"type":"user","sessionId":"sess-a","uuid":"c-1","timestamp":"2026-11-18T18:14:00.000Z","message":{"content":"%s"}}\n' "$SECRET" > "$EMPTY"
printf '{"session_id":"sess-a","transcript_path":"%s","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"You'"'"'ve hit your weekly limit \\u00b7 resets Nov 23 at 3am (America/New_York)"}' "$EMPTY" | python3 "$TOOL" record >/dev/null 2>&1
same "5 recorded from the message" "7" "$(count)"
same "5 source" "hook message" "$(field 6 source)"
same "5 kind" "weekly" "$(field 6 kind)"
same "5 account" "$KEY" "$(field 6 account)"

# 6. A StopFailure that is not a limit (an overloaded server) records nothing.
printf '{"session_id":"sess-a","transcript_path":"%s","hook_event_name":"StopFailure","error":"overloaded","last_assistant_message":"API Error: 529 Overloaded"}' "$EMPTY" | python3 "$TOOL" record >/dev/null 2>&1
same "6 overloaded records nothing" "7" "$(count)"
absent "6 still no conversation text anywhere" "$SECRET" "$(records)"

# 7. The reader: limit days by kind in ET, a five hour day never counted with a model limit day.
out="$(python3 "$TOOL" days 2>&1)"; rc=$?
same "7 reader exits 0" "0" "$rc"
check "7 five hour heading" "Five hour limit: 2 days" "$out"
check "7 weekly heading" "Weekly limit: 2 days" "$out"
check "7 model heading" "Model limit: 1 day" "$out"
check "7 model day in ET with the model" "Fri Nov 13 (Fable)" "$out"
check "7 reset shown in ET" "resets Thu Nov 19 12:00 AM ET" "$out"
check "7 spend heading" "Monthly spend limit: 1 day" "$out"
check "7 rate heading" "Account rate limit: 1 day" "$out"
check "7 account coverage said" "Account read for 3 of 7 messages" "$out"
check "7 who" "main 1" "$out"
absent "7 no conversation text" "$SECRET" "$out"

# 8. The backfill scans every transcript, subagents included, and adds nothing already recorded.
out="$(python3 "$TOOL" scan 2>&1)"; rc=$?
same "8 scan exits 0" "0" "$rc"
same "8 nothing doubled" "7" "$(count)"
check "8 scan says what it found" "0 new" "$out"

# 9. No record yet is said as such, never as a day count of zero.
H2="$WORK/home2"; mkdir -p "$H2"
out="$(HOME="$H2" python3 "$TOOL" days 2>&1)"; rc=$?
same "9 empty exits 0" "0" "$rc"
check "9 empty said" "No usage limit message has been recorded on this Mac" "$out"

# 10. A record that cannot be written fails loud: a non zero exit and the cause on stderr.
H3="$WORK/home3"; mkdir -p "$H3/.claude/state"; chmod 500 "$H3/.claude/state"
out="$(printf '%s' "$STOP_PAYLOAD" | HOME="$H3" python3 "$TOOL" record 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: 10 unwritable record exits non zero"; fi
check "10 cause said" "could not record" "$out"
chmod 700 "$H3/.claude/state"

printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
