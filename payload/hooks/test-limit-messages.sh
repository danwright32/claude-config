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
TYPED="SENTINEL-TYPED-BY-A-PERSON-91"
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
{"type":"user","isSidechain":false,"sessionId":"sess-a","uuid":"u-1","timestamp":"2026-11-10T19:00:00.000Z","message":{"role":"user","content":"$TYPED"}}
{"type":"assistant","isSidechain":false,"sessionId":"sess-a","uuid":"u-2","timestamp":"2026-11-10T19:00:05.000Z","entrypoint":"cli","message":{"model":"claude-fable","content":[{"type":"text","text":"$TYPED reply"}]}}
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
absent "1 no conversation text" "$TYPED" "$(records)"
absent "1 no email" "invented@example.com" "$(records)"
absent "1 no session id" "sess-a" "$(records)"

# 2. The same failure delivered twice (a retry, a second hook) is still one record.
printf '%s' "$STOP_PAYLOAD" | python3 "$TOOL" record >/dev/null 2>&1
same "2 run twice, one record" "1" "$(count)"

# 3. A subagent's SubagentStop: its own transcript holds a model limit (the Fable wording, whose
#    structured type is the ambiguous seven_day_overage_included), so the wording decides the kind.
AG="$HOME/.claude/projects/-proj/sess-a/subagents/agent-x1.jsonl"
cat > "$AG" <<EOF
{"type":"user","isSidechain":true,"agentId":"x1","sessionId":"sess-a","uuid":"a-1","timestamp":"2026-11-14T02:49:00.000Z","message":{"role":"user","content":"$TYPED"}}
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
printf '{"type":"user","sessionId":"sess-a","uuid":"c-1","timestamp":"2026-11-18T18:14:00.000Z","message":{"content":"%s"}}\n' "$TYPED" > "$EMPTY"
printf '{"session_id":"sess-a","transcript_path":"%s","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"You'"'"'ve hit your weekly limit \\u00b7 resets Nov 23 at 3am (America/New_York)"}' "$EMPTY" | python3 "$TOOL" record >/dev/null 2>&1
same "5 recorded from the message" "7" "$(count)"
same "5 source" "hook message" "$(field 6 source)"
same "5 kind" "weekly" "$(field 6 kind)"
same "5 account" "$KEY" "$(field 6 account)"

# 6. A StopFailure that is not a limit (an overloaded server) records nothing.
printf '{"session_id":"sess-a","transcript_path":"%s","hook_event_name":"StopFailure","error":"overloaded","last_assistant_message":"API Error: 529 Overloaded"}' "$EMPTY" | python3 "$TOOL" record >/dev/null 2>&1
same "6 overloaded records nothing" "7" "$(count)"
absent "6 still no conversation text anywhere" "$TYPED" "$(records)"

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
absent "7 no conversation text" "$TYPED" "$out"

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
# A backfill with no transcript folder at all found nothing to read, which is not a clean scan.
out="$(HOME="$H2" python3 "$TOOL" scan 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: 9 scan with no transcript folder exits non zero"; fi
check "9 no folder said" "there is no transcript folder" "$out"

# Cases 10 and 11 take a permission away, which root ignores, so under root they are reported as
# not measured rather than failing for a reason that is not the code's (L411).
if [ "$(id -u)" = 0 ]; then
  echo "SUITE-PART-UNMEASURED cases 10 and 11, since they take away a permission root ignores"
else
  # 10. A record that cannot be written fails loud: a non zero exit and the cause on stderr.
  H3="$WORK/home3"; mkdir -p "$H3/.claude/state"; chmod 500 "$H3/.claude/state"
  out="$(printf '%s' "$STOP_PAYLOAD" | HOME="$H3" python3 "$TOOL" record 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: 10 unwritable record exits non zero"; fi
  check "10 cause said" "could not record" "$out"
  chmod 700 "$H3/.claude/state"

  # 11. A transcript the backfill cannot read is said and fails the run, never counted as scanned.
  LOCKED="$HOME/.claude/projects/-proj/sess-locked.jsonl"
  cp "$OLD" "$LOCKED"; chmod 000 "$LOCKED"
  out="$(python3 "$TOOL" scan 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: 11 scan with an unreadable transcript exits non zero"; fi
  check "11 unreadable count said" "1 transcript could not be read" "$out"
  chmod 600 "$LOCKED"; rm -f "$LOCKED"
fi

# 12. A torn line in the record is skipped and said; the reader still prints every other day.
printf '{"v":1,"id":"torn' >> "$REC"; printf '\n' >> "$REC"
out="$(python3 "$TOOL" days 2>&1)"; rc=$?
same "12 torn line still exits 0" "0" "$rc"
check "12 other days still printed" "Five hour limit: 2 days" "$out"
check "12 torn line said" "1 line of the record could not be read" "$out"

# 13. A recorder failure is said with its date as well as its time, in ET.
printf '{"at":"2026-11-20T15:10:00Z","why":"invented failure"}\n' > "$HOME/.claude/state/limit-messages/failures.jsonl"
out="$(python3 "$TOOL" days 2>&1)"
check "13 failure dated" "last at Fri Nov 20 10:10 AM ET: invented failure" "$out"

# 14. A byte that is not UTF-8, in the hook's payload, on the transcript's limit line and on a line
# already in the record, loses nothing: the message is still recorded from its transcript line, with
# its structured reset, and the reader still prints it.
H4="$WORK/home4"; mkdir -p "$H4/.claude/projects/-proj" "$H4/.claude/state/limit-messages"
BADT="$H4/.claude/projects/-proj/sess-bad.jsonl"
printf '{"type":"assistant","isSidechain":false,"sessionId":"sess-bad","uuid":"bad-1","timestamp":"2026-11-12T19:02:00.000Z","entrypoint":"cli","gitBranch":"br\xff","isApiErrorMessage":true,"error":"rate_limit","quotaLimits":{"status":"rejected","resetsAt":1794341400,"rateLimitType":"five_hour"},"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your 5-hour limit, resets 3:10pm (America/New_York)"}]}}\n' > "$BADT"
printf '{"v":1,"id":"old\xff","at":"2026-11-01T10:00:00Z","kind":"other"}\n' > "$H4/.claude/state/limit-messages/records.jsonl"
out="$(printf '{"session_id":"sess-bad","transcript_path":"%s","cwd":"/x\xff","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"You have hit your 5-hour limit, resets 3:10pm (America/New_York)"}' "$BADT" | HOME="$H4" python3 "$TOOL" record 2>&1)"; rc=$?
same "14 a payload holding a byte that is not UTF-8 exits 0" "0" "$rc"
recs4="$(cat "$H4/.claude/state/limit-messages/records.jsonl" 2>/dev/null)"
check "14 recorded from the transcript line holding such a byte" '"source": "transcript"' "$recs4"
check "14 its structured reset kept" '"resets_from": "structured"' "$recs4"
out="$(HOME="$H4" python3 "$TOOL" days 2>&1)"; rc=$?
same "14 the reader exits 0 on a record line holding such a byte" "0" "$rc"
check "14 the reader prints the day" "Five hour limit: 1 day" "$out"

# 15. A failure while Dan is awake is one plain line on stderr and a non zero exit, never a
# traceback; while the Mac is asleep it prints nothing at all and leaves a note for the morning
# report (lib/sleep.sh's sleep_note), Dan's choice on 2026-11-24. Asleep and awake are each a real
# sleep record in a home of its own, judged by lib/sleep.sh's sleep_active, never a stand in flag.
BOOT="$(bash -c '. "$1" && sleep_boot_of "$(sysctl -n kern.boottime 2>/dev/null)"' _ "$DIR/lib/sleep.sh")"
[ -n "$BOOT" ] || BOOT=1   # no sysctl: sleep.sh skips the boot check, so any boot will do
NOW_MS="$(( $(date +%s) * 1000 ))"
failure_world() {   # failure_world <name> <asleep|awake> -> sets FH (its home) and FREC (its sleep record)
  FH="$WORK/fail-$1-$2"; FREC="$FH/.claude/state/sleep/current.json"
  mkdir -p "$FH/.claude/state/sleep"
  if [ "$2" = asleep ]; then
    printf '{"v":1,"generation":"g-test","since":%s,"until":%s,"night":"2026-11-24","bootTime":%s,"report":"%s/r.md","startedBy":{"sessionId":"s0","cwd":"/"},"workers":[],"placeBefore":"home"}\n' \
      "$((NOW_MS - 60000))" "$((NOW_MS + 3600000))" "$BOOT" "$FH" > "$FREC"
  fi
}
run_failure() {   # run_failure <payload> [tool] -> FOUT, FERR, FRC, in the current world
  printf '%s' "$1" | HOME="$FH" CLAUDE_SLEEP_RECORD="$FREC" python3 "${2:-$TOOL}" record >"$WORK/f.out" 2>"$WORK/f.err"; FRC=$?
  FOUT="$(cat "$WORK/f.out")"; FERR="$(cat "$WORK/f.err")"
}
notes_of() { cat "$FH/.claude/state/sleep/notes/g-test.jsonl" 2>/dev/null; }
failures_of() { cat "$FH/.claude/state/limit-messages/failures.jsonl" 2>/dev/null; }
NOT_OBJECT='[]'
# A StopFailure on a limit whose wording is a number: a payload no handler foresaw, which once
# ended in a traceback.
UNFORESEEN='{"session_id":"s","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":5}'
for path in not-json unwritable not-object unforeseen; do
  for state in awake asleep; do
    failure_world "$path" "$state"
    case "$path" in
      not-json) payload='not json'; said="was not JSON" ;;
      unwritable) payload="$STOP_PAYLOAD"; said="could not record a usage limit message"
        mkdir -p "$FH/.claude/state"; printf 'a file where the folder goes\n' > "$FH/.claude/state/limit-messages" ;;
      not-object) payload="$NOT_OBJECT"; said="was not a JSON object" ;;
      unforeseen) payload="$UNFORESEEN"; said="failed unexpectedly" ;;
    esac
    run_failure "$payload"
    same "15 $path $state: nothing on stdout" "" "$FOUT"
    absent "15 $path $state: never a traceback" "Traceback" "$FERR"
    if [ "$state" = awake ]; then
      if [ "$FRC" -ne 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: 15 $path awake exits non zero (exit $FRC)"; fi
      same "15 $path awake: exactly one line on stderr" "1" "$(printf '%s\n' "$FERR" | grep -c .)"
      check "15 $path awake: the line names the failure" "$said" "$FERR"
      same "15 $path awake: no note is written while awake" "" "$(notes_of)"
    else
      same "15 $path asleep: nothing on stderr" "" "$FERR"
      check "15 $path asleep: the failure is a note for the morning report" "$said" "$(notes_of)"
    fi
    # Every failure is also kept in the recorder's own failure log, except the one where that log's
    # folder is the thing that cannot be written.
    if [ "$path" != unwritable ]; then check "15 $path $state: kept in failures.jsonl" "$said" "$(failures_of)"; fi
  done
done

# 16. A normal run while asleep is what it is awake: silent, exit 0, and the message recorded.
failure_world normal asleep
run_failure "$STOP_PAYLOAD"
same "16 asleep normal run exits 0" "0" "$FRC"
same "16 asleep normal run prints nothing" "" "$FOUT$FERR"
same "16 asleep normal run records the message" "1" "$(grep -c . "$FH/.claude/state/limit-messages/records.jsonl" 2>/dev/null || true)"
same "16 asleep normal run writes no note" "" "$(notes_of)"

# 17. A sleep predicate that cannot be asked (lib/sleep.sh not beside the hook) reads as awake, so
# the failure is printed rather than lost, even under a record that says asleep.
BARE="$WORK/bare"; mkdir -p "$BARE"; cp "$TOOL" "$BARE/limit-messages.py"
failure_world no-predicate asleep
run_failure 'not json' "$BARE/limit-messages.py"
check "17 no predicate: the failure is printed" "was not JSON" "$FERR"
if [ "$FRC" -ne 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: 17 no predicate exits non zero (exit $FRC)"; fi

# 18 to 21. Each failure is named by the step that had it (claude-config#3567): a transcript that
# cannot be read is said as the transcript, never as the record folder, and a record folder that
# cannot be written is still said as the folder. All awake, so the line is on stderr.
nonzero() { if [ "$2" -ne 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (exit $2)"; fi; }
limit_payload() {   # limit_payload <event> <transcript>: a limit stop naming that transcript
  if [ "$1" = SubagentStop ]; then
    printf '{"session_id":"sess-a","transcript_path":"%s","agent_id":"x9","agent_transcript_path":"%s","hook_event_name":"SubagentStop","stop_hook_active":false}' "$MAIN" "$2"
  else
    printf '{"session_id":"sess-a","transcript_path":"%s","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"You have hit your weekly limit, resets Nov 23 at 3am (America/New_York)"}' "$2"
  fi
}
RECDIR_SAID="could not record a usage limit message in"
if [ "$(id -u)" = 0 ]; then
  echo "SUITE-PART-UNMEASURED cases 18 and 20, since they take away a permission root ignores"
else
  # 18. A transcript unreadable by permission, from a main session's stop and from an agent's.
  for event in StopFailure SubagentStop; do
    failure_world "unreadable-$event" awake
    mkdir -p "$FH/.claude/projects/-proj"
    LT="$FH/.claude/projects/-proj/sess-locked.jsonl"
    cp "$MAIN" "$LT"; chmod 000 "$LT"
    run_failure "$(limit_payload "$event" "$LT")"
    nonzero "18 $event unreadable transcript exits non zero" "$FRC"
    same "18 $event: exactly one line on stderr" "1" "$(printf '%s\n' "$FERR" | grep -c .)"
    check "18 $event: the line names the transcript" "could not read the transcript $LT" "$FERR"
    absent "18 $event: the line does not blame the record folder" "$RECDIR_SAID" "$FERR"
    check "18 $event: failures.jsonl names the transcript" "could not read the transcript $LT" "$(failures_of)"
    absent "18 $event: failures.jsonl does not blame the record folder" "$RECDIR_SAID" "$(failures_of)"
    chmod 600 "$LT"
  done

  # 20. Both at once: the transcript cannot be read AND the record folder cannot be written. The
  # transcript is read first and its failure ends the run, so that is the one failure the code can
  # honestly know; the folder is never named, since it was never tried.
  failure_world both awake
  mkdir -p "$FH/.claude/projects/-proj" "$FH/.claude/state"
  LT="$FH/.claude/projects/-proj/sess-locked.jsonl"
  cp "$MAIN" "$LT"; chmod 000 "$LT"
  printf 'a file where the folder goes\n' > "$FH/.claude/state/limit-messages"
  run_failure "$(limit_payload StopFailure "$LT")"
  nonzero "20 both exits non zero" "$FRC"
  same "20 both: exactly one line on stderr" "1" "$(printf '%s\n' "$FERR" | grep -c .)"
  check "20 both: the line names the transcript, the first failure met" "could not read the transcript $LT" "$FERR"
  absent "20 both: the line does not name the folder it never tried" "$RECDIR_SAID" "$FERR"
  chmod 600 "$LT"
fi

# 19. A record folder that cannot be written, under a transcript that reads fine, still names the
# folder and never the transcript.
failure_world folder-only awake
mkdir -p "$FH/.claude/state"
printf 'a file where the folder goes\n' > "$FH/.claude/state/limit-messages"
run_failure "$(limit_payload StopFailure "$MAIN")"
nonzero "19 unwritable folder exits non zero" "$FRC"
check "19 the line names the record folder" "$RECDIR_SAID $FH/.claude/state/limit-messages" "$FERR"
absent "19 the line does not name the transcript" "could not read the transcript" "$FERR"

# 21. A transcript removed between the check that it is there and its read, as an agent's
# transcript can be at its stop. The removal is stood in for by a check that answers "there" for a
# path that is gone, so the open meets a missing file; the failure names the transcript.
GONE_RUN="$WORK/gone-run.py"
cat > "$GONE_RUN" <<'EOF'
import importlib.util, os, sys
tool, gone = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("limit_messages", tool)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
real = os.path.isfile
os.path.isfile = lambda p: True if p == gone else real(p)
sys.exit(m.main(["limit-messages.py", "record"]))
EOF
failure_world gone awake
GONE="$FH/.claude/projects/-proj/sess-gone.jsonl"
limit_payload SubagentStop "$GONE" | HOME="$FH" CLAUDE_SLEEP_RECORD="$FREC" python3 "$GONE_RUN" "$TOOL" "$GONE" >"$WORK/f.out" 2>"$WORK/f.err"; FRC=$?
FERR="$(cat "$WORK/f.err")"
nonzero "21 removed mid read exits non zero" "$FRC"
check "21 the line names the transcript" "could not read the transcript $GONE" "$FERR"
absent "21 the line does not blame the record folder" "$RECDIR_SAID" "$FERR"
check "21 failures.jsonl names the transcript" "could not read the transcript $GONE" "$(failures_of)"

# 22. A transcript that is not there at all when the hook looks is, as before #3567, not a failure:
# the hook's own wording is recorded in its place. Whether an unreadable transcript should count as a
# failure is an open question on #3567, so this pins today's behaviour until it is decided.
failure_world absent awake
run_failure "$(limit_payload StopFailure "$FH/.claude/projects/-proj/never-written.jsonl")"
same "22 absent transcript exits 0" "0" "$FRC"
same "22 absent transcript prints nothing" "" "$FERR"
check "22 the hook's message is recorded in its place" '"source": "hook message"' "$(cat "$FH/.claude/state/limit-messages/records.jsonl" 2>/dev/null)"

printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
