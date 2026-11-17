#!/usr/bin/env bash
# claude-config#3059: test-sleep-real-engine.sh ends by checking the real ~/.claude/state/sleep and
# ~/Downloads for leaks, and it went red on 2026-11-16 because ANOTHER session wrote to the real
# sleep folder while the suite ran, a write the suite never made. This suite holds that a write by
# somebody else into the real folder during a run does not fail it, that a write the run itself made
# there (a leak through a hardcoded path) still does (L1: a guard seen to fail), and that a new file
# carrying nothing of the run's is named as unmeasured rather than passed over in silence (#3080).
#
# Two parts. The helper tests/sleep-real-engine-leaks.py is held to fixture folders, which needs only
# python3 and so runs everywhere. Then the whole engine suite runs once with the "real" HOME pointed at
# a folder this test controls (the suite takes its real home from HOME, and moves HOME to a scratch
# folder of its own for everything else), and this test writes foreign files into that folder after
# the suite has started: the suite must still pass, its own leak check must still pass, and it must
# name each foreign file as unmeasured.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
. "$ROOT/payload/hooks/lib/hang-wait.sh" || {
  echo "FAIL: $(basename "$0"): lib/hang-wait.sh is missing, so this suite's waits have no ceiling."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); echo "ok: $1"; else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
LEAKS="$DIR/sleep-real-engine-leaks.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-sleep-real-engine-foreign.XXXXXX")"
RUN_PID=""
# The engine suite run in part 2 has ended when its process is gone or only waiting to be reaped.
run_ended() { case "$(ps -o stat= -p "$RUN_PID" 2>/dev/null)" in ''|Z*) return 0 ;; esac; return 1; }
# Stops the engine suite and everything it started, then reaps it, inside the hang ceiling. A bare
# `wait` on a run that has hung blocks for as long as it hangs, and a signal to a shell sitting in a
# foreground command is held until that command returns (claude-config#3080). So the run is frozen
# while its tree is killed (lib/kill-tree.sh), then told to end, which lets its own cleanup let go of
# the caffeinate hold it may have started, and killed outright only if even that does not end it.
stop_run() {
  [ -n "$RUN_PID" ] || return 0
  if ! run_ended; then
    kill -STOP "$RUN_PID" 2>/dev/null
    bash "$ROOT/payload/hooks/lib/kill-tree.sh" "$RUN_PID"
    kill -TERM "$RUN_PID" 2>/dev/null
    kill -CONT "$RUN_PID" 2>/dev/null
    hang_wait run_ended 0.2 || kill -KILL "$RUN_PID" 2>/dev/null
  fi
  wait "$RUN_PID" 2>/dev/null
  RUN_PID=""
}
cleanup() {
  stop_run
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---- part 1: the attribution helper, on fixtures ----
SID_RUN=11111111-aaaa-4aaa-8aaa-111111111111
SID_OTHER=99999999-eeee-4eee-8eee-999999999999
SCRATCH="$WORK/scratch"
REAL="$WORK/real"
mkdir -p "$SCRATCH/.claude/state/sleep/notes" "$SCRATCH/Downloads" "$REAL/.claude/state/sleep/notes" "$REAL/.claude/state/sleep/driver" "$REAL/Downloads"
printf '{"session":"%s"}\n' "$SID_RUN" > "$SCRATCH/.claude/state/sleep/notes/1794849057498-$SID_RUN.jsonl"
# The start marker is dated in the past, so every file made below is newer than it with no wait.
touch -t 202001010000 "$WORK/started"

# The helper says each new file once, as "leak<TAB>path" (it carries something this run made) or
# "unattributed<TAB>path" (it carries nothing of this run's, so whose it is was not measured).
said() { python3 -I "$LEAKS" "$REAL" "$SCRATCH" "$WORK/started" "$WORK/scratch-work"; }
leaks() { said | sed -n 's/^leak	//p'; }
unattributed() { said | sed -n 's/^unattributed	//p'; }

printf '{"night":"1794000000000"}\n' > "$REAL/.claude/state/sleep/current.json"
printf '{"session":"%s"}\n' "$SID_OTHER" > "$REAL/.claude/state/sleep/notes/1794000000000-$SID_OTHER.jsonl"
: > "$REAL/Downloads/2026-11-16 other sleep report.md"
[ -z "$(leaks)" ] \
  && check "another session's writes to the real sleep folder and Downloads are not this run's" ok \
  || check "another session's writes to the real sleep folder and Downloads are not this run's" "reported: $(leaks)"
# claude-config#3080: a file carrying nothing of this run's was counted as nobody's and said nothing,
# so a leak with no marker in it (a bare pid file) passed as clean. Each is now named as unmeasured.
printf '4242 36000' > "$REAL/.claude/state/sleep/caffeinate.pid"
EXPECT_UNATTRIBUTED="$(printf '%s\n' "$REAL/.claude/state/sleep/caffeinate.pid" "$REAL/.claude/state/sleep/current.json" "$REAL/.claude/state/sleep/notes/1794000000000-$SID_OTHER.jsonl" "$REAL/Downloads/2026-11-16 other sleep report.md" | sort)"
[ "$(unattributed | sort)" = "$EXPECT_UNATTRIBUTED" ] \
  && check "a new real file carrying nothing of this run's, a bare caffeinate.pid among them, is named as unattributed" ok \
  || check "a new real file carrying nothing of this run's, a bare caffeinate.pid among them, is named as unattributed" "said: $(said | tr '\n' '|')"
[ -z "$(said | grep -v -e '^leak	' -e '^unattributed	')" ] \
  && check "the helper says nothing but leak and unattributed lines" ok \
  || check "the helper says nothing but leak and unattributed lines" "said: $(said | tr '\n' '|')"
rm "$REAL/.claude/state/sleep/caffeinate.pid" "$REAL/.claude/state/sleep/notes/1794000000000-$SID_OTHER.jsonl" "$REAL/Downloads/2026-11-16 other sleep report.md"

printf '{"session":"%s"}\n' "$SID_RUN" > "$REAL/.claude/state/sleep/current.json"
[ "$(leaks)" = "$REAL/.claude/state/sleep/current.json" ] \
  && check "a real file carrying this run's session id is reported as a leak" ok \
  || check "a real file carrying this run's session id is reported as a leak" "reported: $(leaks)"

rm "$REAL/.claude/state/sleep/current.json"
mkdir -p "$REAL/.claude/state/sleep/driver/1794849057498-$SID_RUN"
: > "$REAL/.claude/state/sleep/driver/1794849057498-$SID_RUN/x.json"
[ "$(leaks)" = "$REAL/.claude/state/sleep/driver/1794849057498-$SID_RUN/x.json" ] \
  && check "a real path carrying this run's night and session id is reported as a leak" ok \
  || check "a real path carrying this run's night and session id is reported as a leak" "reported: $(leaks)"

rm -r "$REAL/.claude/state/sleep/driver/1794849057498-$SID_RUN"
printf 'x\n' > "$REAL/.claude/state/sleep/notes/x.txt"
printf 'see %s\n' "$WORK/scratch-work/home" >> "$REAL/.claude/state/sleep/notes/x.txt"
[ "$(leaks)" = "$REAL/.claude/state/sleep/notes/x.txt" ] \
  && check "a real file naming the run's scratch folder is reported as a leak" ok \
  || check "a real file naming the run's scratch folder is reported as a leak" "reported: $(leaks)"

rm "$REAL/.claude/state/sleep/notes/x.txt"
printf 'x\n' > "$REAL/Downloads/2026-11-16 sleepdemo sleep report.md"
[ "$(leaks)" = "$REAL/Downloads/2026-11-16 sleepdemo sleep report.md" ] \
  && check "a sleep report in the real Downloads naming the demo repository is reported as a leak" ok \
  || check "a sleep report in the real Downloads naming the demo repository is reported as a leak" "reported: $(leaks)"

# stop_run, which part 2 uses whenever it gives up on the engine suite, ends a run that has hung in a
# foreground command, and everything under it, rather than waiting as long as the hang lasts (#3080).
# The stand-in hangs for ten minutes in a foreground command behind an EXIT trap, as the engine
# suite would.
cat > "$WORK/stand-in.sh" <<'SH'
trap 'echo cleaned > "$1"' EXIT
sleep 600
true
SH
bash "$WORK/stand-in.sh" "$WORK/stand-in-cleaned" &
RUN_PID=$!
STAND_IN=$RUN_PID
hang_wait '[ -n "$(pgrep -P "$STAND_IN" 2>/dev/null)" ]'
STAND_IN_CHILD="$(pgrep -P "$STAND_IN" 2>/dev/null)"
STAND_IN_CHILD="${STAND_IN_CHILD%%$'\n'*}"
STOP_T0=$SECONDS
stop_run
STOP_TOOK=$((SECONDS - STOP_T0))
CHILD_LEFT=no
kill -0 "$STAND_IN_CHILD" 2>/dev/null && CHILD_LEFT="yes, $STAND_IN_CHILD" && kill "$STAND_IN_CHILD"
[ "$STOP_TOOK" -lt 60 ] && [ -z "$RUN_PID" ] && [ "$CHILD_LEFT" = no ] && [ -s "$WORK/stand-in-cleaned" ] \
  && check "giving up on a hung run stops it and its children, lets its own cleanup run, and reaps it" ok \
  || check "giving up on a hung run stops it and its children, lets its own cleanup run, and reaps it" "took ${STOP_TOOK}s; its child left running: $CHILD_LEFT; its cleanup ran: $([ -s "$WORK/stand-in-cleaned" ] && echo yes || echo no)"

python3 -I "$LEAKS" >/dev/null 2>&1
NOARGS_EXIT=$?
[ "$NOARGS_EXIT" -eq 2 ] && check "the helper refuses to run with no arguments rather than reporting nothing" ok \
  || check "the helper refuses to run with no arguments rather than reporting nothing" "exit $NOARGS_EXIT"

# ---- part 2: the whole engine suite, with another session writing to the "real" folder mid run ----
engine_unmeasured() {
  echo "SUITE-PART-UNMEASURED the engine suite under a foreign write: $1"
  printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit $?
}
[ "${SLEEP_REAL_ENGINE:-}" = 0 ] && engine_unmeasured "SLEEP_REAL_ENGINE=0 skips the engine suite"
[ "$(uname)" = Darwin ] || engine_unmeasured "the engine suite reads macOS's sysctl and caffeinate, which this machine lacks"
command -v claude >/dev/null 2>&1 || engine_unmeasured "there is no claude command on PATH to run the engine with"

FAKE="$WORK/fake-real-home"
SCRATCH_TMP="$WORK/tmp"
mkdir -p "$FAKE/.claude/state/sleep/notes" "$FAKE/Downloads" "$SCRATCH_TMP"
HOME="$FAKE" TMPDIR="$SCRATCH_TMP" bash "$ROOT/tests/test-sleep-real-engine.sh" > "$WORK/engine.out" 2>&1 &
RUN_PID=$!
hang_wait '[ -n "$(find "$SCRATCH_TMP" -maxdepth 2 -name started -print -quit 2>/dev/null)" ] || ! kill -0 "$RUN_PID" 2>/dev/null' 0.2
STARTED_FILE="$(find "$SCRATCH_TMP" -maxdepth 2 -name started -print -quit 2>/dev/null)"
if [ -z "$STARTED_FILE" ]; then
  ENGINE_TAIL="$(tail -n 5 "$WORK/engine.out" 2>/dev/null)"
  check "the engine suite got as far as its start marker" "never wrote one: ${ENGINE_TAIL//$'\n'/ }"
  stop_run
  printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
  exit 1
fi
# Another session's night: a note, an ended record, a bare caffeinate hold and a report, none naming
# anything this run made. Their times are set a day ahead, so each is newer than the suite's start
# marker however fast this runs, with no wait for the clock to move.
OTHER=22222222-bbbb-4bbb-8bbb-222222222222
FUTURE="$(date -v+1d +%Y%m%d%H%M)"
FOREIGN=("$FAKE/.claude/state/sleep/notes/1794000000001-$OTHER.jsonl" "$FAKE/.claude/state/sleep/current.json" "$FAKE/.claude/state/sleep/caffeinate.pid" "$FAKE/Downloads/2026-11-16 $OTHER sleep report.md")
printf '{"session":"%s","note":"another night"}\n' "$OTHER" > "${FOREIGN[0]}"
printf '{"state":"on"}\n' > "${FOREIGN[1]}"
printf '4242 36000' > "${FOREIGN[2]}"
: > "${FOREIGN[3]}"
touch -t "$FUTURE" "${FOREIGN[@]}"
if hang_wait run_ended 0.5; then
  wait "$RUN_PID"
  ENGINE_EXIT=$?
  RUN_PID=""
else
  ENGINE_EXIT="none, it was still running at the hang ceiling (${HANG_S}s) and was stopped"
  stop_run
fi
[ "$ENGINE_EXIT" = 0 ] \
  && check "the engine suite passes while another session writes to the real sleep folder" ok \
  || check "the engine suite passes while another session writes to the real sleep folder" "exit $ENGINE_EXIT: $(grep -a '^FAIL' "$WORK/engine.out")"
ENGINE_OUT="$(cat "$WORK/engine.out")"
case "$ENGINE_OUT" in
  *$'\nok: no new file in the real ~/.claude/state/sleep or ~/Downloads carries anything this run made'*) check "and its own leak check still ran and passed" ok ;;
  *) check "and its own leak check still ran and passed" "no such ok line in the engine suite's output" ;;
esac
# And it names each foreign file as unmeasured rather than passing over it in silence (#3080).
UNMEASURED_LINE="$(grep -a '^SUITE-PART-UNMEASURED whether' "$WORK/engine.out")"
MISSING=""
for f in "${FOREIGN[@]}"; do
  case "$UNMEASURED_LINE" in *"$f"*) ;; *) MISSING="$MISSING $f" ;; esac
done
[ -n "$UNMEASURED_LINE" ] && [ -z "$MISSING" ] \
  && check "and it names every new real file it could not attribute as unmeasured" ok \
  || check "and it names every new real file it could not attribute as unmeasured" "unnamed:${MISSING:- all, no such line}"
[ -f "$FAKE/.claude/state/sleep/notes/1794000000001-$OTHER.jsonl" ] && [ -f "$FAKE/.claude/state/sleep/current.json" ] \
  && check "the other session's files were left as they were" ok \
  || check "the other session's files were left as they were" "a foreign file is gone"

printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
