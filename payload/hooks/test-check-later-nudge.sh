#!/usr/bin/env bash
# Tests for check-later-nudge.sh, the Stop hook that starts the /check-later flow when a turn leaves
# work waiting on a later day (claude-config#2079), and for lib/check-later-signals.py, the detector
# it runs.
#
# The three signals, each with a transcript shaped like a real one (the line keys, the timestamp and
# the tool_use shape were read from real transcripts on 2026-11-02; CronCreate's input is the shape
# tools/typescript/claude-code-types declares, since no real CronCreate call was on this Mac):
#   1. a one shot CronCreate this turn that fires on a later day
#   2. a Write or Edit to a project memory file naming a date after today
#   3. the assistant's own text this turn promising to check again on a later day
# and the controls that must stay silent: a recurring cron, a one shot later today, a memory naming
# only a past date, "tomorrow" inside a tool result or a quotation, a promise in an EARLIER turn,
# and a turn that already ran the flow (Dan typed /check-later, the session started it through the
# Skill tool, or a row was written to the list).
#
# An unreadable transcript must never read as "nothing to check" (L98): it fires, saying so.
#
# Every fixture carries its own timestamp and the suite pins TZ, so no case depends on today's date
# or this Mac's zone (L713).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${CHECK_LATER_NUDGE:-$DIR/check-later-nudge.sh}"
SKILL="$(cd "$DIR/.." && pwd)/skills/check-later/SKILL.md"
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"

command -v python3 >/dev/null 2>&1 || { echo "test-check-later-nudge: python3 is not on PATH, so nothing was verified."; printf 'SUITE-NOT-RUN %s\n' "needs python3"; exit 2; }

WORK="$(mktemp -d)"
case "${WORK%/}" in
  ''|/|"${HOME%/}")
    echo "FAIL: $(basename "$0"): refusing to run: the throwaway directory came back as '$WORK'."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1 ;;
esac
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"
export CLAUDE_SLEEP_RECORD="$WORK/no-sleep-record.json"
export STOP_HOOK_NOTICE_DIR="$WORK/notice"
export TZ="America/New_York"
unset CLAUDE_DETACHED_RUN
mkdir -p "$TMPDIR" "$STOP_HOOK_NOTICE_DIR"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}

# ---- fixture lines, shaped like a real transcript's ----
MK="$WORK/mkline.py"
cat > "$MK" <<'PY'
import json, sys, uuid
kind, ts = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
base = {"parentUuid": None, "isSidechain": False, "userType": "external", "cwd": "/fixture-home/Apps/Bidspoke",
        "sessionId": "fixture-session", "version": "2.1.0", "gitBranch": "main",
        "uuid": str(uuid.uuid4()), "timestamp": ts}
if kind == "user":
    base.update(type="user", message={"role": "user", "content": args[0]})
elif kind == "assistant-text":
    base.update(type="assistant", message={"role": "assistant", "type": "message", "model": "claude",
                "content": [{"type": "text", "text": args[0]}]})
elif kind == "tool":
    base.update(type="assistant", message={"role": "assistant", "type": "message", "model": "claude",
                "content": [{"type": "tool_use", "id": args[0], "name": args[1], "input": json.loads(args[2])}]})
elif kind == "result":
    base.update(type="user", message={"role": "user",
                "content": [{"type": "tool_result", "tool_use_id": args[0], "content": args[1]}]})
else:
    raise SystemExit("unknown kind " + kind)
print(json.dumps(base))
PY
TS="2026-11-02T18:00:00.000Z"   # 1:00 PM ET on Monday Nov 2 2026, the day after the clocks went back
L() { python3 "$MK" "$1" "$TS" "${@:2}"; }
MEM="/fixture-home/.claude/projects/-fixture-home-Apps-Bidspoke/memory/eqx-repull.md"

# A transcript: an earlier turn, then this turn's user message and whatever the case adds.
start() { # start <path>
  {
    L user "look at the dashboard"
    L assistant-text "It looks fine."
    L user "now check the EQX repull"
  } > "$1"
}

run() { # run <transcript path> [extra payload json fields] -> the hook's stdout
  printf '{"transcript_path":"%s","stop_hook_active":false,"hook_event_name":"Stop"%s}' "$1" "${2:-}" | \
    CLAUDE_PROJECT_DIR="$WORK/proj" bash "$HOOK" 2>/dev/null
}
reason_of() { python3 -c 'import json,sys
try: print(json.loads(sys.stdin.read()).get("reason",""))
except Exception: print("")'; }
# reason_has <grep flags> <text>: does the reason in $out hold <text>. The reason is read into a
# variable first, so grep never leaves a producer behind it to die of SIGPIPE (L183).
reason_has() { local r; r="$(printf '%s' "$out" | reason_of)"; grep "$1" -- "$2" <<< "$r"; }

fires() { # fires <label> <transcript> <text the reason must hold>
  local out reason
  out="$(run "$2")"
  reason="$(printf '%s' "$out" | reason_of)"
  if grep -q '"decision": *"block"' <<< "$out" && grep -qiF -- "$3" <<< "$reason"; then
    check "$1" ok
  else
    check "$1" "expected a block naming '$3', got: ${out:-nothing}"
  fi
}
silent() { # silent <label> <transcript>
  local out
  out="$(run "$2")"
  check "$1" "$([ -z "$out" ] && echo ok || echo "expected silence, got: $out")"
}

check "the hook is there to run" "$([ -f "$HOOK" ] && echo ok || echo "no $HOOK")"

# ---- 1. a one shot CronCreate ----
t="$WORK/cron-oneshot.jsonl"; start "$t"
{ L tool c1 CronCreate '{"cron":"0 9 3 11 *","prompt":"Check the EQX repull for #2220","recurring":false}'
  L result c1 "Scheduled one shot job abc123"
  L assistant-text "Scheduled a one shot check." ; } >> "$t"
fires "a one shot cron for a later day fires" "$t" "Tue Nov 3"
fires "and names the time it was set for" "$t" "9:00 AM"

t="$WORK/cron-durable.jsonl"; start "$t"
{ L tool c1 CronCreate '{"cron":"30 10 5 11 *","prompt":"recheck","recurring":false,"durable":true}'
  L result c1 "ok" ; } >> "$t"
fires "a durable one shot cron for a later day fires too" "$t" "Thu Nov 5"

t="$WORK/cron-tomorrow-wildcard.jsonl"; start "$t"
{ L tool c1 CronCreate '{"cron":"0 9 * * *","prompt":"recheck","recurring":false}'
  L result c1 "ok" ; } >> "$t"
fires "a one shot whose next run is tomorrow morning fires" "$t" "Tue Nov 3"

t="$WORK/cron-recurring.jsonl"; start "$t"
{ L tool c1 CronCreate '{"cron":"0 9 3 11 *","prompt":"poll","recurring":true}'
  L result c1 "ok"
  L assistant-text "Polling each morning." ; } >> "$t"
silent "control: a recurring cron stays silent" "$t"

t="$WORK/cron-default.jsonl"; start "$t"
{ L tool c1 CronCreate '{"cron":"*/5 * * * *","prompt":"poll CI"}'
  L result c1 "ok" ; } >> "$t"
silent "control: a cron with recurring left out (it defaults to recurring) stays silent" "$t"

t="$WORK/cron-today.jsonl"; start "$t"
{ L tool c1 CronCreate '{"cron":"30 15 2 11 *","prompt":"check CI","recurring":false}'
  L result c1 "ok" ; } >> "$t"
silent "control: a one shot later today stays silent" "$t"

t="$WORK/cron-odd.jsonl"; start "$t"
{ L tool c1 CronCreate '{"cron":"0 9 L * ?","prompt":"recheck","recurring":false}'
  L result c1 "ok" ; } >> "$t"
fires "a one shot whose schedule cannot be read fires rather than being dropped" "$t" "one shot"

# ---- 2. a project memory naming a future date ----
t="$WORK/mem-future.jsonl"; start "$t"
{ L tool w1 Write "{\"file_path\":\"$MEM\",\"content\":\"---\\nname: eqx repull\\n---\\nRepull EQX for lead 4411 on 2026-11-05 and compare tradelines.\\n\"}"
  L result w1 "File created successfully" ; } >> "$t"
fires "a memory naming a future ISO date fires" "$t" "Thu Nov 5"

t="$WORK/mem-monthname.jsonl"; start "$t"
{ L tool e1 Edit "{\"file_path\":\"$MEM\",\"old_string\":\"x\",\"new_string\":\"The repull check is due Nov 3, once the bureau refreshes.\"}"
  L result e1 "The file has been updated" ; } >> "$t"
fires "a memory edit naming a month and day ahead fires" "$t" "Tue Nov 3"

t="$WORK/mem-past.jsonl"; start "$t"
{ L tool w1 Write "{\"file_path\":\"$MEM\",\"content\":\"Learned on 2026-10-27 (Oct 27): the repull needs the full SSN.\\n\"}"
  L result w1 "File created successfully" ; } >> "$t"
silent "control: a memory naming only past dates stays silent" "$t"

t="$WORK/mem-not-memory.jsonl"; start "$t"
{ L tool w1 Write '{"file_path":"/fixture-home/Apps/Bidspoke/docs/plan.md","content":"Ship on 2026-11-05."}'
  L result w1 "File created successfully" ; } >> "$t"
silent "control: a future date in a file that is not a memory stays silent" "$t"

# ---- 3. a promise in the assistant's own words ----
t="$WORK/promise-tomorrow.jsonl"; start "$t"
L assistant-text "The repull has not landed yet. I'll check again tomorrow once the bureau file refreshes." >> "$t"
fires "a promise to check again tomorrow fires" "$t" "check again tomorrow"

t="$WORK/promise-date.jsonl"; start "$t"
L assistant-text "Nothing to do until the canary week ends; re-check on Nov 5 against the baseline." >> "$t"
fires "a promise to re-check on a named date fires" "$t" "re-check on Nov 5"

# Three wordings measured on 60 days of real transcripts (scratchpad calibration, #2079), each a
# dated wait the first vocabulary missed. Paraphrased here, never copied.
t="$WORK/promise-look-at-again.jsonl"; start "$t"
L assistant-text "Look at the disk usage entry again tomorrow morning, after a day of builds." >> "$t"
fires "looking at a named thing again tomorrow fires" "$t" "again tomorrow"

t="$WORK/promise-stays-open.jsonl"; start "$t"
L assistant-text "#42 stays open for next week's reading." >> "$t"
fires "an issue left open for next week's reading fires" "$t" "stays open for next week"

t="$WORK/promise-wait-on.jsonl"; start "$t"
L assistant-text "The other four wait on next week's area data." >> "$t"
fires "work waiting on next week's data fires" "$t" "wait on next week"

# The check verbs in their other forms (#2087): a week of real sessions held a dated recheck said
# in the passive ("gets rechecked on <date>"), which the bare stem missed. Invented text, same shape.
t="$WORK/promise-rechecked-passive.jsonl"; start "$t"
L assistant-text "The supplier quote holds for now, and the price gets rechecked on 2026-12-14." >> "$t"
fires "a passive 'gets rechecked on' a later date fires" "$t" "rechecked on 2026-12-14"

t="$WORK/promise-rechecking.jsonl"; start "$t"
L assistant-text "I'm rechecking the backlog count next week, after the import settles." >> "$t"
fires "'rechecking' before next week fires" "$t" "rechecking the backlog count next week"

t="$WORK/promise-reruns.jsonl"; start "$t"
L assistant-text "The nightly job reruns the comparison on Nov 6." >> "$t"
fires "'reruns' on a named later date fires" "$t" "reruns the comparison on Nov 6"

t="$WORK/promise-rechecked-past.jsonl"; start "$t"
L assistant-text "The quote was rechecked on Oct 28 and still holds." >> "$t"
silent "control: 'rechecked' on a date already past stays silent" "$t"

t="$WORK/promise-rather-than-wait.jsonl"; start "$t"
L assistant-text "Rather than wait for tomorrow's scheduled run, I started it by hand and it passed." >> "$t"
silent "control: choosing not to wait for tomorrow's run stays silent" "$t"

t="$WORK/promise-past-weekday.jsonl"; start "$t"
L assistant-text "The alerts check that got the retry on Tuesday now uses the shared code." >> "$t"
silent "control: a check noun beside a weekday, with nothing promised, stays silent" "$t"

t="$WORK/tool-result-tomorrow.jsonl"; start "$t"
{ L tool b1 Bash '{"command":"cat notes.txt"}'
  L result b1 "TODO from Geoff: check again tomorrow, the repull is slow"
  L assistant-text "The notes file is read." ; } >> "$t"
silent "control: 'check again tomorrow' in a tool result stays silent" "$t"

t="$WORK/quoted-tomorrow.jsonl"; start "$t"
L assistant-text 'Geoff wrote "we will check again tomorrow" in the thread, and the deploy log says `recheck tomorrow`.' >> "$t"
silent "control: the words inside a quotation or code span stay silent" "$t"

t="$WORK/earlier-turn.jsonl"
{ L user "look at the dashboard"
  L tool c1 CronCreate '{"cron":"0 9 3 11 *","prompt":"recheck","recurring":false}'
  L result c1 "ok"
  L assistant-text "I'll check again tomorrow."
  L user "thanks, what does the log say"
  L tool r1 Read '{"file_path":"/x/log.txt"}'
  L result r1 "all good"
  L assistant-text "The log is clean." ; } > "$t"
silent "control: a promise and a cron in an EARLIER turn stay silent" "$t"

t="$WORK/past-date-promise.jsonl"; start "$t"
L assistant-text "We said we would re-check on Oct 30, and that check passed." >> "$t"
silent "control: a re-check on a date already past stays silent" "$t"

# ---- the flow already ran this turn, so the item is on the list ----
t="$WORK/already-listed.jsonl"; start "$t"
{ L tool c1 CronCreate '{"cron":"0 9 3 11 *","prompt":"recheck","recurring":false}'
  L result c1 "ok"
  L tool s1 mcp__claude_ai_Slack__slack_add_list_record '{"list_id":"F0CB5JMEM2P","cells":[{"column_id":"name","text":"Check the EQX repull (#2220)"}]}'
  L result s1 '{"ok":true,"record_id":"Rec0001"}'
  L assistant-text "Added the row; I'll check again tomorrow." ; } >> "$t"
silent "control: a turn that already wrote the row to the list stays silent" "$t"

t="$WORK/typed-check-later.jsonl"
{ L user "look at the dashboard"
  L assistant-text "It looks fine."
  L user "<command-message>check-later</command-message>
<command-name>/check-later</command-name>"
  L assistant-text "I'll re-check on Nov 5; the row is drafted below." ; } > "$t"
silent "control: a turn where Dan typed /check-later stays silent" "$t"

# #2532: a session may start the skill itself through the Skill tool, and a turn that did has run
# the flow just as a typed /check-later has, so the hook stands down rather than sending it again.
t="$WORK/session-started-check-later.jsonl"; start "$t"
{ L tool k1 Skill '{"skill":"check-later"}'
  L result k1 "Launching skill: check-later"
  L assistant-text "I'll re-check on Nov 5; the row is drafted below." ; } >> "$t"
silent "a turn where the session started check-later through the Skill tool stays silent" "$t"

t="$WORK/session-started-other-skill.jsonl"; start "$t"
{ L tool k1 Skill '{"skill":"no-ai-tells","args":"check-later"}'
  L result k1 "Launching skill: no-ai-tells"
  L assistant-text "I'll re-check on Nov 5." ; } >> "$t"
fires "control: a turn that started some other skill still fires" "$t" "check-later"

t="$WORK/other-list.jsonl"; start "$t"
{ L tool c1 CronCreate '{"cron":"0 9 3 11 *","prompt":"recheck","recurring":false}'
  L result c1 "ok"
  L tool s1 mcp__claude_ai_Slack__slack_add_list_record '{"list_id":"F0SOMEOTHER","cells":[]}'
  L result s1 '{"ok":true}' ; } >> "$t"
fires "a row written to a DIFFERENT list does not count as the flow having run" "$t" "Tue Nov 3"

# ---- the list id has one home, the skill's "## The list" section (L83) ----
# The detector reads the id from the same SKILL.md the reason points at, so a list that moves is
# moved once. A copy of the skill naming another id proves it is read, not remembered.
skill_id="$(grep -m 1 -o 'list id `[A-Z0-9]*`' "$SKILL" | tr -d '`' | sed 's/^list id //')"
check "the skill declares its list id" "$([ -n "$skill_id" ] && echo ok || echo "no 'list id \`...\`' in $SKILL")"
others="$(grep -oE 'F0[A-Z0-9]{8,}' "$SKILL" | sort -u | grep -vx "$skill_id")"
check "every list id the skill names is the one it declares" \
  "$([ -z "$others" ] && echo ok || echo "the skill also names: $others")"

moved="$WORK/moved-skill.md"; sed "s/$skill_id/F0MOVEDLIST1/g" "$SKILL" > "$moved"
t="$WORK/moved-old-row.jsonl"; start "$t"
{ L tool c1 CronCreate '{"cron":"0 9 3 11 *","prompt":"recheck","recurring":false}'
  L result c1 "ok"
  L tool s1 mcp__claude_ai_Slack__slack_add_list_record "{\"list_id\":\"$skill_id\",\"cells\":[]}"
  L result s1 '{"ok":true}' ; } >> "$t"
out="$(printf '{"transcript_path":"%s","stop_hook_active":false,"hook_event_name":"Stop"}' "$t" | \
  CHECK_LATER_SKILL="$moved" CLAUDE_PROJECT_DIR="$WORK/proj" bash "$HOOK" 2>/dev/null)"
check "once the skill's list moves, a row on the old list no longer counts as written" \
  "$(reason_has -qF 'Tue Nov 3' && echo ok || echo "got: ${out:-nothing}")"
t="$WORK/moved-new-row.jsonl"; start "$t"
{ L tool c1 CronCreate '{"cron":"0 9 3 11 *","prompt":"recheck","recurring":false}'
  L result c1 "ok"
  L tool s1 mcp__claude_ai_Slack__slack_add_list_record '{"list_id":"F0MOVEDLIST1","cells":[]}'
  L result s1 '{"ok":true}' ; } >> "$t"
out="$(printf '{"transcript_path":"%s","stop_hook_active":false,"hook_event_name":"Stop"}' "$t" | \
  CHECK_LATER_SKILL="$moved" CLAUDE_PROJECT_DIR="$WORK/proj" bash "$HOOK" 2>/dev/null)"
check "once the skill's list moves, a row on the new list counts as written" \
  "$([ -z "$out" ] && echo ok || echo "expected silence, got: $out")"

noid="$WORK/no-id-skill.md"; grep -v 'list id `' "$SKILL" > "$noid"
t="$WORK/no-id.jsonl"; start "$t"
{ L tool c1 CronCreate '{"cron":"0 9 3 11 *","prompt":"recheck","recurring":false}'
  L result c1 "ok"
  L tool s1 mcp__claude_ai_Slack__slack_add_list_record "{\"list_id\":\"$skill_id\",\"cells\":[]}"
  L result s1 '{"ok":true}' ; } >> "$t"
out="$(printf '{"transcript_path":"%s","stop_hook_active":false,"hook_event_name":"Stop"}' "$t" | \
  CHECK_LATER_SKILL="$noid" CLAUDE_PROJECT_DIR="$WORK/proj" bash "$HOOK" 2>/dev/null)"
reason="$(printf '%s' "$out" | reason_of)"
check "a skill naming no list id fires, saying so rather than calling the transcript unreadable" \
  "$(grep -qi 'no list id' <<< "$reason" && ! grep -qi 'transcript' <<< "$reason" && grep -qF 'Tue Nov 3' <<< "$reason" && echo ok || echo "got: ${out:-nothing}")"
# With no list write in the turn, no row was written whatever the id is, so the id is never needed.
t="$WORK/no-id-no-write.jsonl"; start "$t"
{ L tool c1 CronCreate '{"cron":"0 9 3 11 *","prompt":"recheck","recurring":false}'
  L result c1 "ok" ; } >> "$t"
out="$(printf '{"transcript_path":"%s","stop_hook_active":false,"hook_event_name":"Stop"}' "$t" | \
  CHECK_LATER_SKILL="$noid" CLAUDE_PROJECT_DIR="$WORK/proj" bash "$HOOK" 2>/dev/null)"
check "a skill naming no list id still points at the skill when the turn wrote no row" \
  "$(reason_has -qF "Read $noid" && echo ok || echo "got: ${out:-nothing}")"
t="$WORK/no-id-quiet.jsonl"; start "$t"
L assistant-text "The log is clean." >> "$t"
out="$(printf '{"transcript_path":"%s","stop_hook_active":false,"hook_event_name":"Stop"}' "$t" | \
  CHECK_LATER_SKILL="$noid" CLAUDE_PROJECT_DIR="$WORK/proj" bash "$HOOK" 2>/dev/null)"
check "a skill naming no list id stays silent on a turn that left nothing dated" \
  "$([ -z "$out" ] && echo ok || echo "expected silence, got: $out")"

# ---- an unreadable transcript is never "nothing to check" ----
out="$(run "$WORK/does-not-exist.jsonl")"
check "a transcript that does not exist fires, saying it could not be read" \
  "$(reason_has -qi 'could not read' && echo ok || echo "got: ${out:-nothing}")"

t="$WORK/garbage.jsonl"; printf 'not json at all\n{{{\n' > "$t"
out="$(run "$t")"
check "a transcript with no readable line fires, saying it could not be read" \
  "$(reason_has -qi 'could not read' && echo ok || echo "got: ${out:-nothing}")"

t="$WORK/locked.jsonl"; start "$t"; chmod 000 "$t"
if [ -r "$t" ]; then
  printf 'SUITE-PART-UNMEASURED %s\n' "a transcript the hook may not open: this runs as a user who can read mode 000 files"
else
  out="$(run "$t")"
  check "a transcript the hook may not open fires, saying it could not be read" \
    "$(reason_has -qi 'could not read' && echo ok || echo "got: ${out:-nothing}")"
fi
chmod 600 "$t"

out="$(printf '{"stop_hook_active":false,"hook_event_name":"Stop"}' | CLAUDE_PROJECT_DIR="$WORK/proj" bash "$HOOK" 2>/dev/null)"
check "a payload naming no transcript fires, saying it could not be read" \
  "$(reason_has -qi 'could not read' && echo ok || echo "got: ${out:-nothing}")"

# ---- it stands down where every Stop hook does ----
t="$WORK/cron-guard.jsonl"; cp "$WORK/cron-oneshot.jsonl" "$t"
out="$(printf '{"transcript_path":"%s","stop_hook_active":true}' "$t" | bash "$HOOK" 2>/dev/null)"
check "it stays silent on a Stop hook's own continuation" "$([ -z "$out" ] && echo ok || echo "got: $out")"
out="$(printf '{"transcript_path":"%s","stop_hook_active":false}' "$t" | CLAUDE_DETACHED_RUN=1 bash "$HOOK" 2>/dev/null)"
check "it stays silent in a detached headless run" "$([ -z "$out" ] && echo ok || echo "got: $out")"
: > "$t.skip-stop-hooks"
out="$(run "$t")"
check "it stays silent when the conversation's Stop hooks are switched off" "$([ -z "$out" ] && echo ok || echo "got: $out")"

# ---- what Dan sees ----
out="$(run "$WORK/cron-oneshot.jsonl")"
reason="$(printf '%s' "$out" | reason_of)"
check "the reason points at the check-later skill by its real path" \
  "$(grep -qF "$SKILL" <<< "$reason" && [ -f "$SKILL" ] && echo ok || echo "reason: $reason")"
check "the reason asks for this before the reflection and the issue review" \
  "$(grep -qi 'before any reflection or issue review' <<< "$reason" && echo ok || echo "reason: $reason")"
check "the reason stays short, since Dan reads it (under 400 characters)" \
  "$([ "${#reason}" -lt 400 ] && echo ok || echo "${#reason} characters")"
check "the reason holds no long dash" \
  "$(printf '%s' "$reason" | perl -CSD -ne '$f = 1 if /[\x{2013}\x{2014}]/; END { exit($f ? 1 : 0) }' && echo ok || echo "found one")"

# ---- it is registered as a Stop hook, with a timeout like its siblings ----
reg="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))["hooks"]
for entry in d.get("Stop", []):
    for h in entry.get("hooks", []):
        if h.get("command", "").endswith("/hooks/check-later-nudge.sh"):
            print("ok" if h.get("timeout") else "no timeout")
            raise SystemExit
print("not registered")
' "$SETTINGS" 2>&1)"
check "the settings file registers it under Stop with a timeout" "$reg"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
