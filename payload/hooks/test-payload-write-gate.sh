#!/usr/bin/env bash
# Tests for the gate that refuses a payload write the watch daemon would revert
# (claude-config#367).
#
# payload-revert-warning.sh already said the right thing, but as a UserPromptSubmit hook it speaks
# only when Dan sends a message. On 2026-09-10 a session made roughly forty tool calls editing
# payload/LESSONS.md, adding 476 short form lines, before the warning was ever printed, and only
# then took a hold. Had the daemon fired in that window the work would have been reverted silently,
# which is what happened on 2026-09-03 to 84 files.
#
# The watcher here is a REAL process with a real command line, for the reason its sibling suite
# gives: a stub would only confirm this suite's own assumption about what `ps` returns (L52).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/payload-write-gate.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "test-payload-write-gate: there is no payload-write-gate.sh beside this suite at $DIR." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs payload-write-gate.sh beside it"
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 2
fi

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/payload-write-gate.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"; [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null; true' EXIT

# Two clones: the development checkout, and the one the daemon runs from.
mkdir -p "$FIX/dev/payload/hooks" "$FIX/src/payload/hooks" "$FIX/elsewhere"
: > "$FIX/dev/claude-sync"
: > "$FIX/src/claude-sync"
: > "$FIX/dev/payload/LESSONS.md"
mkdir -p "$FIX/dev/tests"
: > "$FIX/dev/tests/a.sh"

HOLD="$FIX/hold"
PIDF="$FIX/watch.pid"
NOPIDF="$FIX/nosuchpidfile"

bash -c 'exec -a "'"$FIX"'/src/claude-sync watch" sleep 300' &
WPID=$!
# Waited on the CONDITION rather than for a fixed time, so this is not timing the machine (L290).
for _ in $(seq 1 200); do
  case "$(ps -o command= -p "$WPID" 2>/dev/null || true)" in *claude-sync*watch*) break ;; esac
done
case "$(ps -o command= -p "$WPID" 2>/dev/null || true)" in
  *claude-sync*watch*) ;;
  *)
    echo "test-payload-write-gate: the fixture watcher never showed a claude-sync watch command line, so the hook could not be asked anything." >&2
    printf 'SUITE-NOT-RUN %s\n' "the fixture watcher process could not be started with a readable command line"
    echo "passed: $pass, failed: $fail"
    printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
    exit 2 ;;
esac
printf '%s\n' "$WPID" > "$PIDF"

# rc and stderr together, because the verdict is the exit code and the reason is the text, and a
# gate that refuses without saying why is half a gate (L184, L11).
RC=0; OUT=""
edit(){ # edit <file path> <cwd> [pid file]
  local pidf="${3:-$PIDF}"
  OUT="$(printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s"}}' "$2" "$1" \
    | env SYNC_WATCH_PID_FILE="$pidf" SYNC_HOLD_FILE="$HOLD" bash "$HOOK" 2>&1)"; RC=$?
}
runbash(){ # runbash <command> <cwd> [pid file]
  local pidf="${3:-$PIDF}"
  OUT="$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[2], "tool_input": {"command": sys.argv[1]}}))
' "$1" "$2" | env SYNC_WATCH_PID_FILE="$pidf" SYNC_HOLD_FILE="$HOLD" bash "$HOOK" 2>&1)"; RC=$?
}
refused(){ # refused <description>
  if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, said: ${OUT:0:160}"; fi
}
allowed(){ # allowed <description>
  if [ "$RC" -eq 0 ] && [ -z "$(printf '%s' "$OUT" | tr -d '[:space:]')" ]; then check "$1" ok
  else check "$1" "exit $RC, said: ${OUT:0:160}"; fi
}
says(){ case "$OUT" in *"$2"*) check "$1" ok ;; *) check "$1" "did not say '$2'" ;; esac; }

echo "payload write gate: it refuses exactly the state that loses work"

rm -f "$HOLD"
edit "$FIX/dev/payload/LESSONS.md" "$FIX/dev"
refused "a payload write in a development checkout is refused while a watcher runs elsewhere"
says "and it names the file it refused" "$FIX/dev/payload/LESSONS.md"
says "and names the checkout at risk" "$FIX/dev"
says "and gives the hold command to run" "claude-sync hold"
says "and gives the way that needs no hold at all" "Edit ~/.claude directly"

echo "payload write gate: and nothing else"

# A hold is exactly what this is for. Refusing through one would make the hold a dead control (L109).
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$HOLD"
edit "$FIX/dev/payload/LESSONS.md" "$FIX/dev"
allowed "a hold in force lets the write through"
# An UNREADABLE marker is not a hold. Treating one as a hold would silence this for as long as the
# bad file sits there, which is the direction that loses a day of work (L42, L50).
printf 'not a number at all\n' > "$HOLD"
edit "$FIX/dev/payload/LESSONS.md" "$FIX/dev"
refused "a hold marker nothing can read is not a hold"
# An EXPIRED one is not a hold either, and that is the case the prompt time warning cannot catch.
printf '%s\n' "$(( $(date +%s) - 60 ))" > "$HOLD"
edit "$FIX/dev/payload/LESSONS.md" "$FIX/dev"
refused "an expired hold is not a hold"
rm -f "$HOLD"

# No watcher means nothing can revert anything.
edit "$FIX/dev/payload/LESSONS.md" "$FIX/dev" "$NOPIDF"
allowed "with no watcher running there is nothing to refuse"
# A pid the system has handed to something else reads as a live watcher to anything that trusts the
# number alone (L237).
printf '%s\n' "999999" > "$FIX/deadpid"
edit "$FIX/dev/payload/LESSONS.md" "$FIX/dev" "$FIX/deadpid"
allowed "a stale pid is not a live watcher"

# The clone the watcher RUNS FROM is the source of the mirror, not its victim.
edit "$FIX/src/payload/hooks/x.sh" "$FIX/src"
allowed "a write in the clone the watcher runs from is the source and is allowed"

# Only payload/ is mirrored. The tool itself and the suites are this checkout's own work.
edit "$FIX/dev/tests/a.sh" "$FIX/dev"
allowed "a write outside payload in the same checkout is allowed"
edit "$FIX/dev/claude-sync" "$FIX/dev"
allowed "a write to the tool itself is allowed"
edit "$FIX/elsewhere/notes.md" "$FIX/elsewhere"
allowed "a write outside any clone is allowed"

echo "payload write gate: a Bash write counts, a Bash read does not"

# The way most of this repo's own payload edits are actually made. A gate that could only see Edit
# calls would be silent on exactly the session that prompted it (L247).
runbash "cat > $FIX/dev/payload/LESSONS.md <<'EOF'
new text
EOF" "$FIX/dev"
refused "a heredoc redirect into payload is refused"
runbash "sed -i '' 's/a/b/' $FIX/dev/payload/LESSONS.md" "$FIX/dev"
refused "an in place sed on a payload file is refused"
runbash "cp /tmp/x $FIX/dev/payload/LESSONS.md" "$FIX/dev"
refused "a copy over a payload file is refused"

# Reading is the overwhelming majority of what a session does in a checkout, and a gate that fired
# on those would be turned off within the hour (L36, L104).
runbash "cat $FIX/dev/payload/LESSONS.md" "$FIX/dev"
allowed "reading a payload file is allowed"
runbash "grep -n needle $FIX/dev/payload/LESSONS.md" "$FIX/dev"
allowed "grepping a payload file is allowed"
runbash "wc -l $FIX/dev/payload/LESSONS.md" "$FIX/dev"
allowed "counting the lines of a payload file is allowed"
# The one that would have made this gate useless. `2>/dev/null` is on a large share of the commands
# a session runs, so a rule that fired on "a redirect somewhere AND a payload path somewhere" would
# refuse every read of every payload file (L104). What counts is the payload path being the target
# of the redirect, not sharing a command line with one.
runbash "cat $FIX/dev/payload/LESSONS.md 2>/dev/null" "$FIX/dev"
allowed "reading a payload file with stderr redirected away is allowed"
runbash "grep -nE 'needle' $FIX/dev/payload/LESSONS.md 2>/dev/null | sort" "$FIX/dev"
allowed "grepping one with a redirect and a pipe is allowed"
# Reading FROM payload and writing somewhere else is a read of payload.
runbash "cat $FIX/dev/payload/LESSONS.md > $FIX/elsewhere/copy.md" "$FIX/dev"
allowed "copying a payload file OUT is allowed, because payload is not what is written"
# And the writes, in every shape one is actually written in here.
runbash "echo hi > $FIX/dev/payload/LESSONS.md" "$FIX/dev"
refused "a plain redirect into payload is refused"
runbash "echo hi >> $FIX/dev/payload/LESSONS.md" "$FIX/dev"
refused "an append into payload is refused"
runbash "echo hi >$FIX/dev/payload/LESSONS.md" "$FIX/dev"
refused "a redirect with no space before the path is refused"
runbash "printf x | tee $FIX/dev/payload/LESSONS.md" "$FIX/dev"
refused "a tee into payload is refused"
runbash "rm -f $FIX/dev/payload/LESSONS.md" "$FIX/dev"
refused "deleting a payload file is refused"
runbash "python3 - <<'PY'
open('$FIX/dev/payload/LESSONS.md','w').write('x')
PY" "$FIX/dev"
refused "an inline script opening a payload file for writing is refused"
runbash "python3 - <<'PY'
print(open('$FIX/dev/payload/LESSONS.md').read())
PY" "$FIX/dev"
allowed "and one that only reads it is allowed"
# A write that names no payload path is none of its business, however destructive.
runbash "rm -rf $FIX/elsewhere/x" "$FIX/dev"
allowed "a write outside payload is allowed even from inside the checkout"

# The documented override, good for one command, because a person who has read the message needs a
# way past it (L109).
runbash "SKIP_PAYLOAD_WRITE_CHECK=1 cp /tmp/x $FIX/dev/payload/LESSONS.md" "$FIX/dev"
allowed "the documented override lets one command through"

echo "payload write gate: the reader it sees the tool call through (claude-config#480)"

# This gate reads which TOOL is being called and which FILES it would write with python3. With none
# installed the tool name came back as a dash, the case below it matched nothing, and every write
# under payload/ was allowed with nothing said: an absent reader is the one failure indistinguishable
# from a clean run (L490, L42, L98).
NOPY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/payload-write-gate-nopy.XXXXXXXX")"
NOPY="$NOPY_ROOT/bin"; mkdir -p "$NOPY"
for tool in bash sh grep sed awk tr cat cut head sort dirname basename env uname mkdir mv rm ps date; do
  toolpath="$(command -v "$tool" 2>/dev/null)"
  [ -n "$toolpath" ] && ln -s "$toolpath" "$NOPY/$tool" 2>/dev/null
done
# The fixture's own premise, asserted rather than assumed: a bare directory that still reaches a
# python3 would make every case below pass for the wrong reason (L159).
if PATH="$NOPY" "$NOPY/bash" -c 'command -v python3 >/dev/null 2>&1'; then
  check "the bare directory really reaches no python3" "it found one, so nothing below measures its absence"
else check "the bare directory really reaches no python3" ok; fi

# RUN FROM the directory, not merely told about it in the payload: with no python3 the gate cannot
# read the payload's cwd, and the session's own working directory is what Claude Code starts a hook
# in, so that is what it has left to ask about.
edit_nopy(){ # edit_nopy <file path> <cwd>
  OUT="$(printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s"}}' "$2" "$1" \
    | ( cd "$2" && env SYNC_WATCH_PID_FILE="$PIDF" SYNC_HOLD_FILE="$HOLD" PATH="$NOPY" "$NOPY/bash" "$HOOK" 2>&1 ))"; RC=$?
}

rm -f "$HOLD"
edit_nopy "$FIX/dev/payload/LESSONS.md" "$FIX/dev"
refused "with no python3 a payload write is refused rather than allowed in silence"
says "and the refusal names the reader that is missing" "python3"

# Only the state that loses work, exactly as with a reader present. A write that names nothing
# under payload/ is not this gate's business whatever is missing from PATH (L54, L324).
edit_nopy "$FIX/dev/tests/a.sh" "$FIX/dev"
allowed "a write outside payload is not refused over a reader it never needed"

# A hold is what a hold is for, and it is read with no python3 at all, so it still clears this.
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$HOLD"
edit_nopy "$FIX/dev/payload/LESSONS.md" "$FIX/dev"
allowed "a hold in force still lets the write through with no python3"
rm -f "$HOLD"

# And the clone the watcher itself runs from is not at risk, so it is not refused either.
edit_nopy "$FIX/src/payload/LESSONS.md" "$FIX/src"
allowed "the clone the watcher runs from is not refused over the missing reader"

# The control: the same write with python3 present and no watcher to revert it is allowed, so the
# refusal above is the reader's absence rather than a fixture that refuses everything (L159).
edit "$FIX/dev/payload/LESSONS.md" "$FIX/dev" "$NOPIDF"
allowed "the control allows the same write when nothing could revert it"

rm -rf "$NOPY_ROOT"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
