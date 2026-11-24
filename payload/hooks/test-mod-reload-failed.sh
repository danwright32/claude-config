#!/usr/bin/env bash
# Tests for mod-reload-failed.sh, the notice that a mod's reload failed and this session is still
# running the older copy of it (claude-config#3309).
#
# Built on the two messages the issue quotes. Claude Code's own row, "<mod>: reload failed, the
# previous version stays loaded: <why>", is copied from a real transcript (session 793f2639 on the
# personal MacBook, 2026-11-05, where picker-manners stayed frozen for three days); only the keys the
# hook reads are kept. The mods' "out of step in this session" sentence has no real row on this Mac
# (the incident was on the work MacBook), so it is built from mod-kit's skewSentence as a refused tool
# result, and is here to prove it does not answer for the failure row.
#
# Every scenario asserts the quiet state as well as the loud one, in the same fixture (L36, L159).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/mod-reload-failed.sh"
. "$DIR/lib/hook-notice.sh"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-mod-reload-failed.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT
export CLAUDE_MOD_RELOAD_STATE_DIR="$TMPROOT/state"

# The process the session runs in: its identity and when it started, in seconds since the epoch.
# 2026-11-05T00:00:00Z, before every row below, unless a scenario moves it.
export CLAUDE_MOD_RELOAD_PROCESS=4242
export CLAUDE_MOD_RELOAD_PROCESS_START=1793836800
# The clock the hook reads: 2026-11-05T22:00:00Z.
NOW0=1793916000
export CLAUDE_MOD_RELOAD_NOW=$NOW0

# row <file> <kind> <mod> <iso time>: append one transcript row.
#   fail     Claude Code's reload failure row, as measured
#   reloaded Claude Code's plain reload row
#   changed  Claude Code's "plugin.json changed <dash> reloaded" row
#   askagain mod-kit's note that it could not ask a mod to load again (names "reloaded (")
#   skew     a refused tool result carrying the mods' out of step sentence
#   quote    a user row quoting the failure text, as a brief or an issue does
#   partial  the start of a failure row with no line end yet
#   rest     the rest of that row, with its line end
#   fat      a tool result row of 100,000 bytes, as a big command output makes
row() {
  python3 - "$@" <<'PY'
import json, sys
path, kind, mod, ts = sys.argv[1:5]
dash = chr(0x2014)
why = ("engine.create failed on reload (picker-manners: engine.create replaced $.designRound, added by "
       "design-round-guard; to change what a method does, hook the method)")
def system(content):
    return {"type": "system", "subtype": "informational", "level": "notice", "isMeta": False,
            "timestamp": ts, "content": content}
if kind == "fail":
    d = system(f"{mod}: reload failed, the previous version stays loaded: {why}")
elif kind == "reloaded":
    d = system(f"{mod}: reloaded (5 hooks: session.start, tool.call, prompt.submit, prompt.section, command.run)")
elif kind == "changed":
    d = system(f"{mod}: plugin.json changed {dash} reloaded (modules: hooks/register.ts unchanged; 5 hooks: session.start)")
elif kind == "askagain":
    d = system(f"mod-kit: {mod} could not be asked to load again after mod-kit reloaded (it was busy). If its tools are missing, a new session brings them back.")
elif kind == "skew":
    text = (f"<tool_use_error>{mod} and mod-kit are out of step in this session: the mod-kit loaded here has no "
            f"mergeHelper, which {mod} needs, so a mod was updated after this session loaded it. A new session "
            f"loads them together.</tool_use_error>")
    d = {"type": "user", "timestamp": ts, "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "toolu_x", "is_error": True, "content": text}]}}
elif kind == "fat":
    d = {"type": "user", "timestamp": ts, "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "toolu_y", "content": "x" * 100000}]}}
elif kind == "quote":
    d = {"type": "user", "timestamp": ts, "message": {"role": "user", "content":
         f'every reload was refused with "{mod}: reload failed, the previous version stays loaded"'}}
elif kind == "partial":
    line = json.dumps(system(f"{mod}: reload failed, the previous version stays loaded: {why}"))
    with open(path, "a") as f:
        f.write(line[:60])
    sys.exit()
elif kind == "rest":
    line = json.dumps(system(f"{mod}: reload failed, the previous version stays loaded: {why}"))
    with open(path, "a") as f:
        f.write(line[60:] + "\n")
    sys.exit()
with open(path, "a") as f:
    f.write(json.dumps(d) + "\n")
PY
}

prompt() { # prompt <session-id> <transcript path>  -> runs the hook as a UserPromptSubmit would
  python3 - "$1" "$2" <<'PY' | bash "$HOOK" 2>/dev/null
import json, sys
print(json.dumps({"session_id": sys.argv[1], "transcript_path": sys.argv[2],
                  "hook_event_name": "UserPromptSubmit", "cwd": ".", "prompt": "carry on"}))
PY
}

field() { # field <json> <systemMessage|context>
  python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit()
if sys.argv[2] == "context":
    print((d.get("hookSpecificOutput") or {}).get("additionalContext", ""))
else:
    print(d.get("systemMessage", ""))' "$1" "$2"
}

# ---------------------------------------------------------------------------
# A session whose mods reload cleanly, with people quoting the failure text and mods saying they are
# out of step, says nothing: only Claude Code's own failure row is a failure.
# ---------------------------------------------------------------------------
T1="$TMPROOT/one.jsonl"
row "$T1" reloaded picker-manners 2026-11-05T04:43:10.948Z
row "$T1" changed picker-manners 2026-11-05T07:32:51.586Z
row "$T1" quote picker-manners 2026-11-05T08:00:00.000Z
row "$T1" skew scope-modes 2026-11-05T08:01:00.000Z
row "$T1" askagain picker-manners 2026-11-05T08:02:00.000Z
out="$(prompt s1 "$T1")"
[ -z "$out" ] && check "clean reloads, quotes and out of step lines say nothing" ok \
  || check "clean reloads, quotes and out of step lines say nothing" "said: $out"

# ---------------------------------------------------------------------------
# The real failure row: Dan is told, in the channel shown to him, what happened and what to do.
# ---------------------------------------------------------------------------
row "$T1" fail picker-manners 2026-11-05T21:41:31.651Z
out="$(prompt s1 "$T1")"
v="$(hook_notice_verdict "$out" '^picker-manners failed to reload at 4:41 PM ET on 5 November, so this session is still running the copy of it loaded at 2:32 AM ET on 5 November\.')"
[ -z "$v" ] && check "a failed reload is told to Dan, with the copy still running" ok \
  || check "a failed reload is told to Dan, with the copy still running" "$v"
msg="$(field "$out" systemMessage)"
grep -q "Start a new session to run the current picker-manners\." <<< "$msg" \
  && check "the notice says what to do" ok || check "the notice says what to do" "said: $msg"
grep -q "a refusal from it may be wrong" <<< "$msg" \
  && check "the notice says a refusal from it may be wrong" ok || check "the notice says a refusal from it may be wrong" "said: $msg"
ctx="$(field "$out" context)"
grep -q "engine.create replaced \$.designRound" <<< "$ctx" \
  && check "the session is handed Claude Code's reason" ok || check "the session is handed Claude Code's reason" "context: $ctx"
grep -q "came from an out of date copy" <<< "$ctx" \
  && check "the session is told how to report a refusal from that mod" ok \
  || check "the session is told how to report a refusal from that mod" "context: $ctx"
if printf '%s' "$msg$ctx" | python3 -c 'import sys; t = sys.stdin.read(); sys.exit(0 if any(c in t for c in (chr(0x2014), chr(0x2013))) else 1)'; then
  check "the words carry no dash as punctuation" "found one: $msg"
else
  check "the words carry no dash as punctuation" ok
fi

# ---------------------------------------------------------------------------
# Said once per failure: the next failed reloads and every out of step line say nothing more.
# ---------------------------------------------------------------------------
row "$T1" fail picker-manners 2026-11-05T21:42:00.179Z
row "$T1" skew picker-manners 2026-11-05T21:43:00.000Z
row "$T1" fail picker-manners 2026-11-05T21:54:45.024Z
out="$(prompt s1 "$T1")"
[ -z "$out" ] && check "later failures of the same mod are not told again" ok \
  || check "later failures of the same mod are not told again" "said: $out"

# ---------------------------------------------------------------------------
# Told again only once the stated time has passed with the old copy still running.
# ---------------------------------------------------------------------------
out="$(CLAUDE_MOD_RELOAD_NOW=$((NOW0 + 86399)) prompt s1 "$T1")"
[ -z "$out" ] && check "not told again before a day has passed" ok \
  || check "not told again before a day has passed" "said: $out"
out="$(CLAUDE_MOD_RELOAD_NOW=$((NOW0 + 86400)) prompt s1 "$T1")"
v="$(hook_notice_verdict "$out" '^picker-manners has failed to reload 3 times since 4:41 PM ET on 5 November, so this session is still running the copy of it loaded at 2:32 AM ET on 5 November\.')"
[ -z "$v" ] && check "told again after a day, with the count" ok || check "told again after a day, with the count" "$v"
out="$(CLAUDE_MOD_RELOAD_NOW=$((NOW0 + 86400 + 60)) prompt s1 "$T1")"
[ -z "$out" ] && check "and then quiet again" ok || check "and then quiet again" "said: $out"

# ---------------------------------------------------------------------------
# A reload that succeeds ends it, and a later failure is a new one, told at once.
# ---------------------------------------------------------------------------
row "$T1" changed picker-manners 2026-11-07T01:00:00.000Z
out="$(CLAUDE_MOD_RELOAD_NOW=$((NOW0 + 200000)) prompt s1 "$T1")"
[ -z "$out" ] && check "a successful reload ends the failure quietly" ok \
  || check "a successful reload ends the failure quietly" "said: $out"
row "$T1" fail picker-manners 2026-11-07T13:02:58.516Z
out="$(CLAUDE_MOD_RELOAD_NOW=$((NOW0 + 200060)) prompt s1 "$T1")"
v="$(hook_notice_verdict "$out" '^picker-manners failed to reload at 8:02 AM ET on 7 November, so this session is still running the copy of it loaded at 8:00 PM ET on 6 November\.')"
[ -z "$v" ] && check "a new failure after a good reload is told" ok || check "a new failure after a good reload is told" "$v"

# ---------------------------------------------------------------------------
# The incident's shape: mod-kit frozen since the session started, many failures, out of step lines
# from the mods that depend on it. Told once, as mod-kit, from the session's start.
# ---------------------------------------------------------------------------
T2="$TMPROOT/two.jsonl"
row "$T2" reloaded scope-modes 2026-11-05T03:00:00.000Z
for i in 01 02 03 04 05 06 07 08 09 10; do
  row "$T2" fail mod-kit "2026-11-05T05:${i}:00.000Z"
  row "$T2" skew scope-modes "2026-11-05T05:${i}:30.000Z"
done
out="$(prompt s2 "$T2")"
v="$(hook_notice_verdict "$out" '^mod-kit has failed to reload 10 times since 12:01 AM ET on 5 November, so this session is still running the copy of it this session loaded when it started\.')"
[ -z "$v" ] && check "a mod frozen from the start is told once, with the count" ok || check "a mod frozen from the start is told once, with the count" "$v"
grep -q "scope-modes" <<< "$(field "$out" systemMessage)" \
  && check "a mod only saying it is out of step is not named as frozen" "named scope-modes: $out" \
  || check "a mod only saying it is out of step is not named as frozen" ok

# ---------------------------------------------------------------------------
# Two mods failing at once: one notice naming both.
# ---------------------------------------------------------------------------
T3="$TMPROOT/three.jsonl"
row "$T3" fail picker-manners 2026-11-05T21:41:31.651Z
row "$T3" fail mod-kit 2026-11-05T21:41:32.000Z
out="$(prompt s3 "$T3")"
msg="$(field "$out" systemMessage)"
{ grep -q "^picker-manners failed to reload" <<< "$msg" && grep -q "mod-kit failed to reload" <<< "$msg" \
  && grep -q "Start a new session to run the current picker-manners and mod-kit\." <<< "$msg"; } \
  && check "two frozen mods are told in one notice" ok || check "two frozen mods are told in one notice" "said: $out"

# ---------------------------------------------------------------------------
# A failure from before this process started belongs to an earlier process (a resume started
# afresh), whose mods this one loaded anew: nothing to say.
# ---------------------------------------------------------------------------
T4="$TMPROOT/four.jsonl"
row "$T4" fail picker-manners 2026-11-04T21:41:31.651Z
out="$(prompt s4 "$T4")"
[ -z "$out" ] && check "a failure from before this process started says nothing" ok \
  || check "a failure from before this process started says nothing" "said: $out"

# And a failure seen, then a new process: the new process loaded every mod afresh, so a failure
# already told is not told again and later rows count from there.
T5="$TMPROOT/five.jsonl"
row "$T5" fail picker-manners 2026-11-05T21:41:31.651Z
out="$(prompt s5 "$T5")"
[ -n "$out" ] && check "the old process's failure is told" ok || check "the old process's failure is told" "said nothing"
out="$(CLAUDE_MOD_RELOAD_PROCESS=5151 CLAUDE_MOD_RELOAD_PROCESS_START=1793926000 CLAUDE_MOD_RELOAD_NOW=$((NOW0 + 90000)) prompt s5 "$T5")"
[ -z "$out" ] && check "a new process forgets the old process's failures" ok \
  || check "a new process forgets the old process's failures" "said: $out"

# ---------------------------------------------------------------------------
# A row still being written is not read until its line ends, and then it is.
# ---------------------------------------------------------------------------
T6="$TMPROOT/six.jsonl"
row "$T6" reloaded scope-modes 2026-11-05T03:00:00.000Z
row "$T6" partial picker-manners 2026-11-05T21:41:31.651Z
out="$(prompt s6 "$T6")"
[ -z "$out" ] && check "half a row says nothing" ok || check "half a row says nothing" "said: $out"
row "$T6" rest picker-manners 2026-11-05T21:41:31.651Z
out="$(prompt s6 "$T6")"
[ -n "$(field "$out" systemMessage)" ] && check "the row is read once its line ends" ok \
  || check "the row is read once its line ends" "said: $out"

# ---------------------------------------------------------------------------
# A later process given the same pid is still a new process: told of its own failure at once, never
# taken for the old one's failure going on.
# ---------------------------------------------------------------------------
T7="$TMPROOT/seven.jsonl"
row "$T7" fail picker-manners 2026-11-05T21:41:31.651Z
out="$(prompt s7r "$T7")"
[ -n "$out" ] && check "the first process's failure is told" ok || check "the first process's failure is told" "said nothing"
row "$T7" fail picker-manners 2026-11-06T02:00:00.000Z
out="$(CLAUDE_MOD_RELOAD_PROCESS_START=1793926000 CLAUDE_MOD_RELOAD_NOW=$((NOW0 + 20000)) prompt s7r "$T7")"
v="$(hook_notice_verdict "$out" '^picker-manners failed to reload at 9:00 PM ET on 5 November, so this session is still running the copy of it this session loaded when it started\.')"
[ -z "$v" ] && check "a reused pid with a later start is a new process" ok || check "a reused pid with a later start is a new process" "$v"

# ---------------------------------------------------------------------------
# Read in pieces: a row longer than a piece is stepped over, and a failure row beside it still counts.
# ---------------------------------------------------------------------------
T8="$TMPROOT/eight.jsonl"
row "$T8" fat x 2026-11-05T21:00:00.000Z
row "$T8" fail picker-manners 2026-11-05T21:41:31.651Z
row "$T8" fat x 2026-11-05T21:50:00.000Z
row "$T8" fail mod-kit 2026-11-05T21:51:00.000Z
out="$(CLAUDE_MOD_RELOAD_CHUNK=4096 prompt s8 "$T8")"
msg="$(field "$out" systemMessage)"
{ grep -q "^picker-manners failed to reload" <<< "$msg" && grep -q "mod-kit failed to reload" <<< "$msg"; } \
  && check "rows longer than a piece are stepped over, and the failures beside them read" ok \
  || check "rows longer than a piece are stepped over, and the failures beside them read" "said: $out"

# ---------------------------------------------------------------------------
# A transcript that cannot be read is said once, never on every prompt, and never as all clear.
# ---------------------------------------------------------------------------
out="$(prompt s7 "$TMPROOT/missing.jsonl")"
v="$(hook_notice_verdict "$out" 'could not read the transcript of this session')"
[ -z "$v" ] && check "an unreadable transcript is said" ok || check "an unreadable transcript is said" "$v"
out="$(prompt s7 "$TMPROOT/missing.jsonl")"
[ -z "$out" ] && check "and said once" ok || check "and said once" "said: $out"

printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
