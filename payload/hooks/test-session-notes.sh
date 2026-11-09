#!/usr/bin/env bash
# Tests for session-notes-folder.sh and lib/session_notes.py (claude-config#2490): each session's
# notes folder, kept where a restart of the Mac cannot clear it.
#
# On 2026-11-09 a restart of the work MacBook emptied /private/tmp, and with it a session's
# scratchpad: its handoff.md (the note it re-reads after a compaction or a crash), a guide it had
# built, and a background agent's working tree. Everything in git survived. So the handoff note and
# every dispatched agent's working folder live in ~/.claude/state/session-notes/<project>/<session>/,
# which a restart leaves alone and the sync never carries (it names only the payload's folders).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/session-notes-folder.sh"
WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
pass=0; fail=0
check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:900}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected NOT to contain: $2"; echo "  actual: ${3:0:900}"; fi; }
check_eq(){ if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '${3:0:600}')"; fi; }

export CLAUDE_HOME="$WORK/home"; mkdir -p "$CLAUDE_HOME"
export SESSION_NOTES_TMP="$WORK/tmp"
UID_NOW="$(id -u)"
KEY="-Users-x-Apps-proj"
S="0a1b2c3d-1111-2222-3333-444455556666"
TRANSCRIPT="$WORK/projects/$KEY/$S.jsonl"
NOTES="$CLAUDE_HOME/state/session-notes/$KEY/$S"
SCRATCH="$WORK/tmp/claude-$UID_NOW/$KEY/$S/scratchpad"

start_payload(){ # start_payload <session> <transcript> <cwd> [source]
  python3 -c '
import json, sys
s, t, c, src = sys.argv[1:5]
d = {"session_id": s, "cwd": c, "hook_event_name": "SessionStart", "source": src}
if t != "-": d["transcript_path"] = t
print(json.dumps(d))' "$1" "$2" "$3" "${4:-startup}"
}
fire(){ start_payload "$@" | bash "$HOOK" 2>/dev/null; }
field(){ printf '%s' "$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
k = sys.argv[1]
print(d.get("systemMessage", "") if k == "system" else d.get("hookSpecificOutput", {}).get(k, ""))
' "$2" 2>/dev/null; }

# ---- 1. A new session is told its notes folder, which now exists ----
out="$(fire "$S" "$TRANSCRIPT" /Users/x/Apps/proj)"
ctx="$(field "$out" additionalContext)"
check_eq "1 the answer is for SessionStart" "SessionStart" "$(field "$out" hookEventName)"
check "1 names the notes folder by its absolute path" "$NOTES" "$ctx"
check "1 says where the handoff note goes" "handoff.md" "$ctx"
check "1 says why: a restart clears the scratchpad" "restart" "$ctx"
check "1 gives dispatched agents a working folder there" "agent" "$ctx"
check "1 keeps worktrees out of the temp folder" "worktree" "$ctx"
check "1 names the issue" "claude-config#2490" "$ctx"
[ -d "$NOTES" ] && check "1 the folder is created" ok ok || check "1 the folder is created" ok "missing $NOTES"
check_eq "1 an ordinary start is not put in front of Dan" "" "$(field "$out" system)"
check_not "1 with no note yet, nothing claims there is one" "holds handoff.md" "$ctx"

# The folder is keyed exactly as Claude Code keys the scratchpad and the transcript: the transcript's
# own folder name, never re-derived from the cwd, which in a worktree is a different path.
out="$(fire "$S" "$TRANSCRIPT" /Users/x/Apps/proj/.claude/worktrees/agent-1)"
check "1 a session started in a worktree still gets the project's folder" "$NOTES" "$(field "$out" additionalContext)"
# With no transcript path, the cwd is folded the way Claude Code folds it.
out="$(fire "$S" - /Users/x/Apps/proj)"
check "1 with no transcript the cwd gives the same key" "$NOTES" "$(field "$out" additionalContext)"

# ---- 2. A note already there is pointed at, so a resumed or compacted session reads it ----
printf 'Decisions so far.\n' > "$NOTES/handoff.md"
out="$(fire "$S" "$TRANSCRIPT" /Users/x/Apps/proj resume)"
check "2 a note already in the folder is named for reading" "holds handoff.md" "$(field "$out" additionalContext)"

# ---- 3. The switch: a handoff note still in the scratchpad is carried over once, never lost ----
S2="0a1b2c3d-1111-2222-3333-777788889999"
T2="$WORK/projects/$KEY/$S2.jsonl"
N2="$CLAUDE_HOME/state/session-notes/$KEY/$S2"
SC2="$WORK/tmp/claude-$UID_NOW/$KEY/$S2/scratchpad"
mkdir -p "$SC2"; printf 'Written before the switch.\n' > "$SC2/handoff.md"
out="$(fire "$S2" "$T2" /Users/x/Apps/proj compact)"
ctx="$(field "$out" additionalContext)"
check_eq "3 the scratchpad note is copied into the notes folder" "Written before the switch." "$(cat "$N2/handoff.md" 2>/dev/null)"
check "3 and the session is told it was carried over" "copied" "$ctx"
check "3 naming where it came from" "$SC2/handoff.md" "$ctx"
check_eq "3 the scratchpad copy is left where it was" "Written before the switch." "$(cat "$SC2/handoff.md" 2>/dev/null)"
# Once: a later note in the notes folder is never overwritten by the stale scratchpad one.
printf 'Written after the switch.\n' > "$N2/handoff.md"
out="$(fire "$S2" "$T2" /Users/x/Apps/proj resume)"
check_eq "3 a newer note in the notes folder is never overwritten" "Written after the switch." "$(cat "$N2/handoff.md")"
check_not "3 and nothing claims a copy was made" "copied" "$(field "$out" additionalContext)"

# ---- 4. The folder cannot be made: said to the session AND to Dan, never silent ----
S3="0a1b2c3d-1111-2222-3333-aaaabbbbcccc"
mkdir -p "$WORK/ro"; chmod a-w "$WORK/ro"
out="$(start_payload "$S3" "$WORK/projects/$KEY/$S3.jsonl" /Users/x/Apps/proj | CLAUDE_HOME="$WORK/ro/home" bash "$HOOK" 2>/dev/null)"; rc=$?
check_eq "4 a folder that cannot be made never fails the session start" "0" "$rc"
check "4 the session is told it could not be made" "could not be created" "$(field "$out" additionalContext)"
check "4 and that a scratchpad note is lost on restart" "lost" "$(field "$out" additionalContext)"
check "4 Dan is told too" "could not be created" "$(field "$out" system)"
chmod u+w "$WORK/ro"

# ---- 5. A payload it cannot use says so, and never names a folder it did not make ----
out="$(printf 'not json' | bash "$HOOK" 2>/dev/null)"; rc=$?
check_eq "5 an unreadable payload never fails the session start" "0" "$rc"
check "5 and is said, not dropped" "notes folder" "$(field "$out" system)"
out="$(fire "../../etc" "$TRANSCRIPT" /Users/x/Apps/proj)"
check_not "5 a session id that is not a plain name is never made into a path" "/etc" "$(field "$out" additionalContext)"
[ -e "$CLAUDE_HOME/state/etc" ] && check "5 nothing is created outside the notes root" ok "created" || check "5 nothing is created outside the notes root" ok ok

# ---- 6. Wired, and in one place ----
reg="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(" ".join(h["command"] for g in d["hooks"].get("SessionStart", []) for h in g["hooks"]))' "$DIR/../settings.hooks.json")"
check "6 registered on SessionStart" "hooks/session-notes-folder.sh" "$reg"
# The status bar's compact tool checks a note's path in TypeScript, which cannot import this
# library, so the folder's root is spelled in both; this keeps the two spellings one.
check "6 the status bar's compact tool names the same root" ".claude/state/session-notes" "$(cat "$DIR/../mods/status-bar/hooks/register.ts")"
check "6 the context line notice uses this library" "session_notes" "$(cat "$DIR/lib/context_size.py")"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
