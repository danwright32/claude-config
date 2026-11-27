#!/usr/bin/env bash
# send-gate: scans settings.hooks.json
# Tests for the hook that asks Dan before a connector tool deletes something or changes a live
# setting in Regal, Better Stack or Cal (claude-config#3618).
#
# In the 30 days to 2026-11-25 auto mode's check alone let 7 writes to Regal and Better Stack
# through with nobody asked, by the issue's count. Dan chose that day "Ask before live deletes and
# changes" and, for the rest of those connectors' writes, "Keep it to deletes (Recommended)".
#
# THREE THINGS ARE HELD HERE.
#
#   1. What the hook decides, on payloads built by hand in the shape Claude Code sends a PreToolUse
#      hook (session_id, hook_event_name, tool_name, tool_input). No connector is ever called: the
#      hook reads a name and prints a decision. Awake it asks; while Dan is asleep it refuses, since
#      sleep mode answers a session's own permission prompts yes for any server that is not a
#      claude.ai connector (measured in the code on 2026-11-26), so an ask alone would be approved
#      with nobody there. What it cannot read it asks about.
#
#   2. That it is wired: registered under PreToolUse for every MCP tool, to block when it fails.
#
#   3. THE COMPARISON (L96, L48). connector-change-ask-fixtures/ holds each connector's real tool
#      names, measured from the personal MacBook's session records (each file says when and how).
#      Every name is run through the hook, and the suite fails when
#        - a tool whose name reads as a delete is not asked about. "Reads as a delete" is this
#          suite's own reading, wider than the hook's and written apart from it (L721): the five
#          the hook asks about (delet, remov, cancel, reset, paus) and the other words a vendor
#          could name the same act by (purge, destroy, erase, wipe, drop, truncate, clear, revoke,
#          terminate, archive, disable, deactivate, unpublish, uninstall, expire). A tool caught
#          only by the wider list is a delete under another name: make the hook ask about it.
#        - one of Regal's four live tools the issue names is not asked about.
#        - a tool is asked about that is none of those, which would be the hook asking wider
#          than Dan chose.
#      The comparison is seen to fail first, on a scratch copy of the fixtures holding a made up
#      delete tool and on a scratch copy of the hook with one of its verbs taken out (L1).
#      CONNECTOR_CHANGE_ASK_FIXTURES names another fixtures folder, for checking a newly measured
#      list before it replaces the one here.
#
# WHAT IT DOES NOT HOLD. Nothing refreshes the fixtures, so a tool a vendor adds is compared only
# when somebody records the new list; the hook itself reads the verb, so such a tool is still asked
# about when its name holds one of the five. Better Stack has no fixture: its tools are on the work
# MacBook only, and the names used for it below are invented.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/connector-change-ask.sh"
FIXTURES="${CONNECTOR_CHANGE_ASK_FIXTURES:-$DIR/connector-change-ask-fixtures}"
. "$DIR/lib/settings-file.sh" 2>/dev/null || { echo "FAIL: lib/settings-file.sh is missing beside this suite"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
SETTINGS="$(hook_settings_file "$DIR/..")" || SETTINGS=""

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "FAIL: there is no connector-change-ask.sh beside this suite at $DIR, so nothing asks before a connector tool deletes or changes something live"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
[ -x "$HOOK" ] && check "the hook is executable, as the settings run it by its path" ok || check "the hook is executable, as the settings run it by its path" "mode lacks x"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
EMPTY_HOME="$WORK/empty-home"
mkdir -p "$EMPTY_HOME"
# Awake is a sleep record that is not there, asleep a real one judged by lib/sleep.sh, never a
# stand in flag. Named on every run, so the Mac really being asleep cannot decide a case.
AWAKE="$WORK/no-sleep-record.json"
NOW_MS="$(date +%s)000"
BOOT="$(bash -c '. "$1" && sleep_boot_of "$(sysctl -n kern.boottime 2>/dev/null)"' _ "$DIR/lib/sleep.sh")"
[ -n "$BOOT" ] || BOOT=1   # no sysctl (Linux CI): sleep.sh skips the boot check, so any boot will do
ASLEEP="$WORK/asleep-record.json"
printf '{"v":1,"generation":"g-test","since":%s,"until":%s,"night":"2026-11-25","bootTime":%s,"report":"%s/r.md","startedBy":{"sessionId":"s0","cwd":"/"},"workers":[],"placeBefore":"home"}\n' \
  "$((NOW_MS - 60000))" "$((NOW_MS + 3600000))" "$BOOT" "$WORK" > "$ASLEEP"

REGAL="mcp__claude_ai_Regal_MCP__"
CAL="mcp__claude_ai_Cal__"

# run <hook> <payload> [<sleep record>]: the hook's stdout, its exit code on the last line.
run() {
  local out rc
  out="$(cd "$WORK" && printf '%s' "$2" | env -u CLAUDE_HOME HOME="$EMPTY_HOME" CLAUDE_SLEEP_RECORD="${3:-$AWAKE}" bash "$1" 2>/dev/null)"; rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
# decision <run output>: ask, deny, allow, none or badjson, then " rc=N".
decision() {
  local rc="${1##*rc=}" body="${1%$'\n'rc=*}"
  printf '%s' "$body" | python3 -c '
import json, sys
t = sys.stdin.read().strip()
if not t:
    print("none", end=""); sys.exit()
try:
    d = json.loads(t)
except Exception:
    print("badjson", end=""); sys.exit()
h = d.get("hookSpecificOutput") if isinstance(d, dict) else None
print((h or {}).get("permissionDecision", "none"), end="")'
  printf ' rc=%s' "$rc"
}
reason() {  # reason <run output>
  local body="${1%$'\n'rc=*}"
  printf '%s' "$body" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit()
print((d.get("hookSpecificOutput") or {}).get("permissionDecisionReason", ""))'
}
payload() {  # payload <tool> [<input as JSON>]
  local input="${2:-}"
  [ -n "$input" ] || input='{}'
  python3 -c 'import json, sys; print(json.dumps({"session_id": "s1", "transcript_path": "/nonexistent/t.jsonl", "cwd": "/nonexistent", "permission_mode": "auto", "hook_event_name": "PreToolUse", "tool_name": sys.argv[1], "tool_input": json.loads(sys.argv[2])}))' "$1" "$input"
}
expect() {  # expect <label> <want decision> <payload> [<sleep record>] [<hook>]
  local got; got="$(decision "$(run "${5:-$HOOK}" "$3" "${4:-$AWAKE}")")"
  [ "$got" = "$2 rc=0" ] && check "$1" ok || check "$1" "wanted $2 rc=0, got $got"
}
says() {  # says <label> <run output> <ERE the reason must match>
  local r; r="$(reason "$2")"
  [[ $r =~ $3 ]] && check "$1" ok || check "$1" "the reason does not say /$3/: ${r:0:300}"
}

# --- 1. what it decides -------------------------------------------------------------------------
echo "a Regal delete, and Regal's four live tools, are asked about under any server name holding regal"
r="$(run "$HOOK" "$(payload "${REGAL}delete-team" '{"teamId": "team-123"}')")"
[ "$(decision "$r")" = "ask rc=0" ] && check "Regal's delete-team is asked about" ok || check "Regal's delete-team is asked about" "$(decision "$r")"
says "the question names the tool" "$r" 'delete-team'
says "the question says what it does in plain words" "$r" 'deletes something live \(team\)'
says "the question shows what it was called with" "$r" 'teamId=team-123'
says "the question names the connector and the issue that decided it" "$r" 'Regal call.*claude-config#3618'
for t in update-journey update-campaign save-agent-live update-routing-rule-set update_journey updateJourney updatejourney updatecampaign saveagentlive UPDATEROUTINGRULESET; do
  expect "Regal's $t is asked about" ask "$(payload "$REGAL$t" '{"id": "j1"}')"
done
says "update-journey's question says what it does" "$(run "$HOOK" "$(payload "${REGAL}update-journey" '{"id": "j1"}')")" 'changes a journey that may be live'
says "save-agent-live's question says what it does" "$(run "$HOOK" "$(payload "${REGAL}save-agent-live" '{"id": "a1"}')")" 'saves an agent as its live version'
# The second name Regal is reached under was not measured, so these server names are invented:
# what is held is that the server is matched by a part of its name.
for t in mcp__regal__delete-team mcp__plugin_regal_regal-mcp__delete_business_hours mcp__REGAL_prod__update-campaign; do
  expect "$t, an invented second server name, is asked about" ask "$(payload "$t")"
done
for t in fetch-journey list-teams create-team update-team edit-agent restore-routing-rule-set create-journey; do
  expect "Regal's $t passes untouched" none "$(payload "$REGAL$t" '{"id": "x"}')"
done

echo "Cal's cancel, delete and remove tools are asked about, and no other calendar's"
for t in cancel_booking delete_event_type delete_schedule remove_contact; do
  expect "Cal's $t is asked about" ask "$(payload "$CAL$t" '{"uid": "b1"}')"
done
says "cancel_booking's question says what it does" "$(run "$HOOK" "$(payload "${CAL}cancel_booking" '{"uid": "b1"}')")" 'cancels something live \(booking\)'
for t in get_bookings create_booking reschedule_booking update_schedule decline_booking_seats; do
  expect "Cal's $t passes untouched" none "$(payload "$CAL$t" '{"uid": "b1"}')"
done
expect "a server named cal_com is Cal" ask "$(payload mcp__cal_com__cancel_booking)"
for t in mcp__claude_ai_Google_Calendar__delete_event mcp__claude_ai_Supabase__delete_branch mcp__lightroom__delete_collection mcp__local__delete_file mcp__calendly__cancel_event; do
  expect "$t is on none of the three connectors and passes" none "$(payload "$t" '{"id": "x"}')"
done

echo "Better Stack's remove, delete and pause tools are asked about (invented names: it was not measured)"
for t in mcp__plugin_betterstack_betterstack__delete_monitor mcp__claude_ai_Better_Stack__pause_monitor mcp__better-stack__remove_heartbeat mcp__betterstack__reset_incident; do
  expect "$t is asked about" ask "$(payload "$t" '{"id": "m1"}')"
done
says "a pause's question says what it does" "$(run "$HOOK" "$(payload mcp__betterstack__pause_monitor '{"id": "m1"}')")" 'Better Stack call.*pauses something live \(monitor\)'
for t in mcp__plugin_betterstack_betterstack__list_monitors mcp__betterstack__query mcp__betterstack__incidents mcp__betterstack__create_monitor; do
  expect "$t passes untouched" none "$(payload "$t" '{"id": "m1"}')"
done

echo "what it cannot read is asked about, and a call that is none of its own is passed"
expect "a Regal name with no tool after the server is asked about" ask "$(payload mcp__claude_ai_Regal_MCP__)"
expect "a bare server name on Regal is asked about" ask "$(payload mcp__regal)"
says "and the question says the tool could not be read" "$(run "$HOOK" "$(payload mcp__regal)")" 'holds no tool this hook could read'
whole="$(payload "${REGAL}delete-team" '{"teamId": "team-123"}')"
r="$(run "$HOOK" "${whole%?}")"
[ "$(decision "$r")" = "ask rc=0" ] && check "a delete whose payload is cut short is asked about" ok || check "a delete whose payload is cut short is asked about" "$(decision "$r")"
says "naming the payload as what could not be read" "$r" 'payload could not be read'
expect "a delete whose payload came inside a list is asked about" ask "[$whole]"
read_cut="$(payload "${REGAL}fetch-journey" '{"id": "j1"}')"
expect "a read whose payload is cut short is passed" none "${read_cut%?}"
# The call's own name is the top level one. An input holding a tool_name key of its own, written
# ahead of the call's, must not be taken for the call's tool by the screen that runs before python3.
nested_first() {  # nested_first <the call's tool> <the tool its input names>
  python3 -c 'import json, sys; print(json.dumps({"session_id": "s1", "hook_event_name": "PreToolUse", "tool_input": {"tool_name": sys.argv[2]}, "tool_name": sys.argv[1]}))' "$1" "$2"
}
expect "a delete whose input, written ahead of its name, holds a tool_name key naming another server's tool is asked about" ask "$(nested_first "${REGAL}delete-team" mcp__lightroom__list_folders)"
expect "a call on another server whose input names a Regal delete under a tool_name key is passed" none "$(nested_first mcp__lightroom__list_folders "${REGAL}delete-team")"
# The same when the payload does not parse: every whole name its text holds is judged, never the
# first alone.
nested_cut="$(nested_first "${REGAL}delete-team" mcp__lightroom__list_folders)"
expect "the same delete, its payload cut short, is asked about" ask "${nested_cut%?}"
# A name the text holds only a part of cannot be judged by its verb: "del" reads as no delete.
r="$(run "$HOOK" '{"session_id": "s1", "hook_event_name": "PreToolUse", "tool_name": "mcp__claude_ai_Regal_MCP__del')"
[ "$(decision "$r")" = "ask rc=0" ] && check "a payload cut short inside a Regal tool's name is asked about" ok || check "a payload cut short inside a Regal tool's name is asked about" "$(decision "$r")"
says "saying the name could not be read whole" "$r" 'could not be read whole'
expect "a payload cut short inside a Cal tool's name is asked about" ask '{"session_id": "s1", "hook_event_name": "PreToolUse", "tool_name": "mcp__claude_ai_Cal__can'
expect "a payload cut short inside another server's tool name is passed" none '{"session_id": "s1", "hook_event_name": "PreToolUse", "tool_name": "mcp__lightroom__del'
# A whole name that asks nothing does not vouch for the rest of a text that cannot be read: the
# call's own name may be the one cut short after it (an input can hold a tool_name key of its own,
# written first).
r="$(run "$HOOK" '{"session_id": "s1", "hook_event_name": "PreToolUse", "tool_input": {"tool_name": "mcp__lightroom__list_folders"}, "tool_name": "mcp__claude_ai_Regal_MCP__del')"
[ "$(decision "$r")" = "ask rc=0" ] && check "a payload holding another server's name whole, then cut short inside a Regal tool's name, is asked about" ok || check "a payload holding another server's name whole, then cut short inside a Regal tool's name, is asked about" "$(decision "$r")"
says "saying the Regal name could not be read whole" "$r" 'mcp__claude_ai_Regal_MCP__del, a name that could not be read whole'
expect "a payload holding Bash as a whole name, then cut short inside a Cal tool's name, is asked about" ask '{"session_id": "s1", "hook_event_name": "PreToolUse", "tool_input": {"tool_name": "Bash"}, "tool_name": "mcp__claude_ai_Cal__can'
expect "a payload holding a Regal read whole, then cut short inside a Regal tool's name, is asked about" ask '{"session_id": "s1", "hook_event_name": "PreToolUse", "tool_input": {"tool_name": "mcp__claude_ai_Regal_MCP__fetch-journey"}, "tool_name": "mcp__claude_ai_Regal_MCP__del'
expect "a payload holding a Regal read whole, then cut short inside another server's tool name, is passed" none '{"session_id": "s1", "hook_event_name": "PreToolUse", "tool_input": {"tool_name": "mcp__claude_ai_Regal_MCP__fetch-journey"}, "tool_name": "mcp__lightroom__del'
expect "an empty payload is passed" none ""
expect "a Bash call naming a Regal delete in its text is not this hook's" none "$(python3 -c 'import json; print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "echo mcp__claude_ai_Regal_MCP__delete-team"}}))')"
tricky="$(python3 -c 'import json; print(json.dumps({"note": "he said \"no\" \\ then\nline two\tand a tab", "ids": [1, 2], "deep": {"a": None}}))')"
r="$(run "$HOOK" "$(payload "${REGAL}delete-team" "$tricky")")"
[ "$(decision "$r")" = "ask rc=0" ] && check "an input holding quotes, a backslash, a newline and a tab still gives one valid question" ok || check "an input holding quotes, a backslash, a newline and a tab still gives one valid question" "$(decision "$r")"
long="$(python3 -c 'import json; print(json.dumps({"note": "x" * 5000}))')"
r="$(run "$HOOK" "$(payload "${REGAL}delete-team" "$long")")"
says "a long input is cut short in the question, saying so" "$r" 'cut short'

echo "while Dan is asleep the same call is refused, with the reason, and a read still passes"
CLAUDE_SLEEP_RECORD="$ASLEEP" bash -c '. "$1" && sleep_active' _ "$DIR/lib/sleep.sh" >/dev/null 2>&1 \
  && check "the asleep record reads as asleep to lib/sleep.sh (the control)" ok \
  || check "the asleep record reads as asleep to lib/sleep.sh (the control)" "sleep_active says awake, so the asleep cases below prove nothing"
for t in mcp__plugin_betterstack_betterstack__delete_monitor mcp__regal__delete-team "${CAL}cancel_booking" "${REGAL}update-journey"; do
  expect "asleep, $t is refused" deny "$(payload "$t" '{"id": "m1"}')" "$ASLEEP"
  expect "awake, the same call is asked about (the control)" ask "$(payload "$t" '{"id": "m1"}')" "$AWAKE"
done
r="$(run "$HOOK" "$(payload mcp__plugin_betterstack_betterstack__delete_monitor '{"id": "m1"}')" "$ASLEEP")"
says "the refusal says Dan is asleep" "$r" 'Dan is asleep'
says "the refusal names the tool and what it does" "$r" 'delete_monitor.*deletes something live'
says "the refusal says not to reach the same end another way" "$r" 'another way'
expect "asleep, a read passes untouched" none "$(payload mcp__plugin_betterstack_betterstack__list_monitors)" "$ASLEEP"
expect "asleep, a name it cannot read on Regal is refused" deny "$(payload mcp__regal)" "$ASLEEP"

echo "with a library or python3 gone it still stops the call, saying what is missing"
# The hook and the four files it loads, in a folder of their own with one taken away.
copy_without() {  # copy_without <name> <file under lib to leave out, or -> -> the copied hook's path
  local to="$WORK/$1"
  mkdir -p "$to/lib"
  cp "$HOOK" "$to/connector-change-ask.sh"
  local f
  for f in hook-notice.sh push-scope.sh sleep.sh connector-changes.py; do
    [ "$f" = "$2" ] || cp "$DIR/lib/$f" "$to/lib/$f"
  done
  printf '%s' "$to/connector-change-ask.sh"
}
WHOLE_COPY="$(copy_without whole -)"
expect "the copied hook, with every file in place, asks about a delete (the control)" ask "$(payload "${REGAL}delete-team")" "$AWAKE" "$WHOLE_COPY"
expect "and passes a read (the control)" none "$(payload "${REGAL}fetch-journey")" "$AWAKE" "$WHOLE_COPY"
for lib in hook-notice.sh push-scope.sh sleep.sh connector-changes.py; do
  H="$(copy_without "no-$lib" "$lib")"
  r="$(run "$H" "$(payload "${REGAL}delete-team" '{"teamId": "t1"}')")"
  # With lib/sleep.sh gone nothing says whether Dan is asleep, and at night sleep mode answers a
  # question yes for a server that is not a claude.ai connector: so that one is refused, not asked.
  case "$lib" in sleep.sh) want=deny ;; *) want=ask ;; esac
  [ "$(decision "$r")" = "$want rc=0" ] && check "with lib/$lib gone, a Regal delete is still stopped ($want)" ok || check "with lib/$lib gone, a Regal delete is still stopped ($want)" "$(decision "$r"): ${r:0:200}"
  case "$lib" in
    push-scope.sh) ;;   # the payload is read as it came, which takes nothing away from the question
    *) says "and the question names lib/$lib" "$r" "lib/${lib//./\\.}" ;;
  esac
  expect "with lib/$lib gone, a call on another server is still passed" none "$(payload mcp__lightroom__delete_collection)" "$AWAKE" "$H"
done
NO_SLEEP_LIB="$(copy_without no-sleep-asleep sleep.sh)"
expect "with lib/sleep.sh gone, a delete is refused while the record says asleep" deny "$(payload mcp__plugin_betterstack_betterstack__delete_monitor)" "$ASLEEP" "$NO_SLEEP_LIB"
r="$(run "$NO_SLEEP_LIB" "$(payload "${REGAL}delete-team")" "$AWAKE")"
[ "$(decision "$r")" = "deny rc=0" ] && check "with lib/sleep.sh gone, a delete is refused with no sleep record too, since nothing could tell" ok || check "with lib/sleep.sh gone, a delete is refused with no sleep record too, since nothing could tell" "$(decision "$r")"
says "and the refusal says that whether Dan is asleep could not be told" "$r" 'whether Dan is asleep could not be told'
says "and how to get past it" "$r" 'pull of the shared config'
expect "with lib/sleep.sh gone, a read still passes" none "$(payload "${REGAL}fetch-journey")" "$ASLEEP" "$NO_SLEEP_LIB"
expect "with lib/hook-notice.sh gone, a delete is still refused while Dan is asleep" deny "$(payload "${REGAL}delete-team")" "$ASLEEP" "$(copy_without no-notice-asleep hook-notice.sh)"
. "$DIR/lib/no-python-path.sh"
NOPY="$WORK/nopy/bin"
npp_build_bin "$NOPY"
if npp_reaches_python3 "$NOPY"; then
  check "the bare directory reaches no python3" "it found one, so nothing below measures its absence"
else
  run_nopy() { local out rc; out="$(cd "$WORK" && printf '%s' "$1" | env -u CLAUDE_HOME HOME="$EMPTY_HOME" CLAUDE_SLEEP_RECORD="$AWAKE" PATH="$NOPY" "$NOPY/bash" "$HOOK" 2>/dev/null)"; rc=$?; printf '%s\nrc=%s\n' "$out" "$rc"; }
  r="$(run_nopy "$(payload "${REGAL}delete-team")")"
  case "$(decision "$r")|$(reason "$r")" in
    # Refused, not asked: lib/sleep.sh reads the sleep record with python3, so nothing could tell
    # whether Dan is asleep either.
    "deny rc=0|"*"python3 is not on PATH"*) check "with no python3, a Regal delete is refused, naming python3" ok ;;
    *) check "with no python3, a Regal delete is refused, naming python3" "$(decision "$r") $(reason "$r")" ;;
  esac
  r="$(run_nopy "$(payload mcp__lightroom__delete_collection)")"
  [ "$(decision "$r")" = "none rc=0" ] && check "with no python3, a call on another server is passed" ok || check "with no python3, a call on another server is passed" "$(decision "$r")"
fi

# --- 2. it is wired -----------------------------------------------------------------------------
echo "the hook is registered for every MCP tool, to block when it fails"
if [ -z "$SETTINGS" ]; then
  check "a settings file registers the hooks" "no settings.hooks.json or settings.json beside $DIR"
else
  wired="$(python3 - "$SETTINGS" "$FIXTURES" <<'PY'
import glob, json, os, re, sys
d = json.load(open(sys.argv[1]))
rows = [(g.get("matcher", ""), h) for g in d.get("hooks", {}).get("PreToolUse", []) for h in g.get("hooks", [])
        if h.get("command", "").split()[:1] and os.path.basename(h["command"].split()[0]) == "connector-change-ask.sh"]
if not rows:
    print("no PreToolUse entry runs connector-change-ask.sh"); sys.exit()
names = ["mcp__regal__delete-team", "mcp__plugin_betterstack_betterstack__delete_monitor", "mcp__better-stack__pause_monitor", "mcp__cal_com__cancel_booking"]
for f in sorted(glob.glob(os.path.join(sys.argv[2], "*.tools.txt"))):
    names += [l.strip() for l in open(f) if l.strip() and not l.startswith("#")]
for matcher, h in rows:
    if h.get("onFailure") != "block":
        print("its registration (matcher %s) has no onFailure block, so a crash or a timeout lets the call through unasked" % matcher)
missed = [n for n in names if not any(re.fullmatch(m, n) for m, _ in rows)]
if missed:
    print("%d of %d tool names are matched by no registration of it, the first: %s" % (len(missed), len(names), missed[0]))
PY
)"
  [ -z "$wired" ] && check "settings register it for every tool name it must judge, with onFailure block" ok || check "settings register it for every tool name it must judge, with onFailure block" "$wired"
fi

# --- 3. the comparison with each connector's recorded tool list -----------------------------------
echo "every recorded Regal and Cal tool is run through the hook"
# This suite's own reading of a name, written apart from the hook's (L721).
FIVE="delet remov cancel reset paus"
OTHER_WORDS="purg destroy eras wipe drop truncat clear revok terminat archiv disabl deactivat unpublish uninstall expir"
REGAL_NAMED="update-journey update-campaign save-agent-live update-routing-rule-set"
holds_one_of() {  # holds_one_of <lower case name> <stems> -> the first stem it holds, or nothing
  local s
  for s in $2; do case "$1" in *"$s"*) printf '%s' "$s"; return 0 ;; esac; done
  return 1
}
# compare <hook> <fixtures folder> <counts file>: one fault a line; the counts file gets
# "<fixture> <tools> <asked>" for each fixture it read.
compare() {
  local hook="$1" dir="$2" counts="$3" f name own low out five other named tools asked key
  : > "$counts"
  for f in "$dir"/*.tools.txt; do
    [ -f "$f" ] || { echo "no fixture was found in $dir"; return 0; }
    key="${f##*/}"; key="${key%.tools.txt}"
    grep -q -E '^# MEASURED on 20[0-9]{2}-[0-9]{2}-[0-9]{2}' "$f" || echo "$key: the fixture does not say when it was measured"
    tools=0; asked=0
    while IFS= read -r name; do
      case "$name" in ''|'#'*) continue ;; esac
      tools=$((tools + 1))
      own="${name##*__}"
      low="$(printf '%s' "$own" | tr '[:upper:]_' '[:lower:]-')"
      five="$(holds_one_of "$low" "$FIVE")"
      other="$(holds_one_of "$low" "$OTHER_WORDS")"
      named=""
      [ "$key" = regal ] && case " $REGAL_NAMED " in *" $low "*) named=1 ;; esac
      out="$(cd "$WORK" && printf '{"session_id": "s1", "hook_event_name": "PreToolUse", "tool_name": "%s", "tool_input": {}}' "$name" \
        | env -u CLAUDE_HOME HOME="$EMPTY_HOME" CLAUDE_SLEEP_RECORD="$AWAKE" bash "$hook" 2>/dev/null)"
      case "$out" in
        *'"permissionDecision": "ask"'*)
          asked=$((asked + 1))
          [ -n "$five$named" ] || echo "$key: $own is asked about, though its name reads as no delete, remove, cancel, reset or pause and the issue does not name it: the hook asks wider than Dan chose" ;;
        '')
          [ -z "$five" ] || echo "$key: $own reads as a delete (its name holds $five) and is not asked about"
          [ -z "$other" ] || [ -n "$five" ] || echo "$key: $own reads as a delete under another word (its name holds $other) and is not asked about: make connector-change-ask.sh ask about it"
          [ -z "$named" ] || echo "$key: $own is one of the four live tools the issue names and is not asked about" ;;
        *) echo "$key: the hook answered $own with neither a question nor silence: ${out:0:160}" ;;
      esac
    done < "$f"
    printf '%s %s %s\n' "$key" "$tools" "$asked" >> "$counts"
  done
}
faults="$(compare "$HOOK" "$FIXTURES" "$WORK/counts")"
[ -z "$faults" ] && check "every recorded tool that reads as a delete is asked about, and nothing else is" ok || check "every recorded tool that reads as a delete is asked about, and nothing else is" "$faults"
# Judged by the count it ran (L288): a fixture that lost its names would pass every line above.
total=0
while read -r key tools asked; do
  total=$((total + tools))
  echo "  $key: $asked of $tools recorded tools are asked about"
  [ "$tools" -ge 40 ] && check "the $key fixture holds a whole tool list" ok || check "the $key fixture holds a whole tool list" "only $tools names"
  [ "$asked" -ge 1 ] && check "at least one $key tool is asked about" ok || check "at least one $key tool is asked about" "none of $tools was"
done < "$WORK/counts"
[ "$total" -ge 150 ] && check "the comparison ran every recorded name" ok || check "the comparison ran every recorded name" "only $total names were run"
for want in regal cal; do
  grep -q "^$want " "$WORK/counts" && check "there is a $want fixture" ok || check "there is a $want fixture" "no $want.tools.txt in $FIXTURES"
done

echo "the comparison is seen to fail: on a made up delete tool, and on a hook with a verb taken out"
SCRATCH="$WORK/scratch-fixtures"
mkdir -p "$SCRATCH"
cp "$DIR/connector-change-ask-fixtures/"*.tools.txt "$SCRATCH/"
printf '%s\n' "${REGAL}purge-team" >> "$SCRATCH/regal.tools.txt"
faults="$(compare "$HOOK" "$SCRATCH" "$WORK/counts-scratch")"
case "$faults" in
  *"purge-team reads as a delete under another word"*) check "a made up purge-team in a scratch copy of Regal's list fails the comparison" ok ;;
  *) check "a made up purge-team in a scratch copy of Regal's list fails the comparison" "it reported: ${faults:-nothing}" ;;
esac
MUTANT="$(copy_without mutant -)"
sed 's/("delet", "deletes"), //' "$DIR/lib/connector-changes.py" > "$WORK/mutant/lib/connector-changes.py"
if grep -q '"delet"' "$WORK/mutant/lib/connector-changes.py"; then
  check "the scratch hook has its delete verb taken out" "the edit matched nothing, so the case below proves nothing"
else
  faults="$(compare "$MUTANT" "$DIR/connector-change-ask-fixtures" "$WORK/counts-mutant")"
  case "$faults" in
    *"delete-team reads as a delete (its name holds delet) and is not asked about"*) check "a hook with its delete verb taken out fails the comparison, naming the tool" ok ;;
    *) check "a hook with its delete verb taken out fails the comparison, naming the tool" "it reported: ${faults:0:300}" ;;
  esac
fi
WIDE="$(copy_without wide -)"
sed 's/("paus", "pauses"))/("paus", "pauses"), ("creat", "creates"))/' "$DIR/lib/connector-changes.py" > "$WORK/wide/lib/connector-changes.py"
if grep -q '"creat"' "$WORK/wide/lib/connector-changes.py"; then
  faults="$(compare "$WIDE" "$DIR/connector-change-ask-fixtures" "$WORK/counts-wide")"
  case "$faults" in
    *"create-team is asked about, though"*) check "a hook that also asks about creates fails the comparison as wider than Dan chose" ok ;;
    *) check "a hook that also asks about creates fails the comparison as wider than Dan chose" "it reported: ${faults:0:300}" ;;
  esac
else
  check "the scratch hook has a create verb added" "the edit matched nothing, so the case proves nothing"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
