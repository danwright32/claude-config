#!/usr/bin/env bash
# claude-config#3059: test-sleep-real-engine.sh ends by saying the real ~/.claude/state/sleep and
# ~/Downloads gained nothing, and it went red on 2026-11-16 because ANOTHER session wrote to the real
# sleep folder while the suite ran, a write the suite never made. This suite holds that a write by
# somebody else into the real folder during a run does not change the result, and that a write the
# run itself made there (a leak through a hardcoded path) still does (L1: a guard seen to fail).
#
# Two parts. The helper tests/sleep-real-engine-leaks.py is held to fixture folders, which needs only
# python3 and so runs everywhere. Then the whole engine suite runs once with the "real" HOME pointed at
# a folder this test controls (the suite takes its real home from HOME, and moves HOME to a scratch
# folder of its own for everything else), and this test writes a foreign file into that folder after the
# suite has started: the suite must still pass, and its own check must still say nothing was gained.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); echo "ok: $1"; else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
LEAKS="$DIR/sleep-real-engine-leaks.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-sleep-real-engine-foreign.XXXXXX")"
RUN_PID=""
cleanup() {
  [ -n "$RUN_PID" ] && kill "$RUN_PID" 2>/dev/null
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
touch "$WORK/started"
sleep 1.1

leaks() { python3 -I "$LEAKS" "$REAL" "$SCRATCH" "$WORK/started" "$WORK/scratch-work"; }

printf '{"night":"1794000000000"}\n' > "$REAL/.claude/state/sleep/current.json"
printf '{"session":"%s"}\n' "$SID_OTHER" > "$REAL/.claude/state/sleep/notes/1794000000000-$SID_OTHER.jsonl"
: > "$REAL/Downloads/2026-11-16 other sleep report.md"
[ -z "$(leaks)" ] \
  && check "another session's writes to the real sleep folder and Downloads are not this run's" ok \
  || check "another session's writes to the real sleep folder and Downloads are not this run's" "reported: $(leaks)"

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

python3 -I "$LEAKS" >/dev/null 2>&1
[ $? -eq 2 ] && check "the helper refuses to run with no arguments rather than reporting nothing" ok \
  || check "the helper refuses to run with no arguments rather than reporting nothing" "exit $?"

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
STARTED_FILE=""
for _ in $(seq 1 600); do
  STARTED_FILE="$(find "$SCRATCH_TMP" -maxdepth 2 -name started -print -quit 2>/dev/null)"
  [ -n "$STARTED_FILE" ] && break
  kill -0 "$RUN_PID" 2>/dev/null || break
  sleep 0.2
done
if [ -z "$STARTED_FILE" ]; then
  check "the engine suite got as far as its start marker" "never wrote one: $(tail -5 "$WORK/engine.out" 2>/dev/null | tr '\n' ' ')"
  wait "$RUN_PID" 2>/dev/null; RUN_PID=""
  printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
  exit 1
fi
sleep 1.1
# Another session's night: a note, an ended record, and a report, none naming anything this run made.
OTHER=22222222-bbbb-4bbb-8bbb-222222222222
printf '{"session":"%s","note":"another night"}\n' "$OTHER" > "$FAKE/.claude/state/sleep/notes/1794000000001-$OTHER.jsonl"
printf '{"state":"on"}\n' > "$FAKE/.claude/state/sleep/current.json"
: > "$FAKE/Downloads/2026-11-16 $OTHER sleep report.md"
wait "$RUN_PID"
ENGINE_EXIT=$?
RUN_PID=""
[ "$ENGINE_EXIT" -eq 0 ] \
  && check "the engine suite passes while another session writes to the real sleep folder" ok \
  || check "the engine suite passes while another session writes to the real sleep folder" "exit $ENGINE_EXIT: $(grep -a '^FAIL' "$WORK/engine.out" | head -3 | tr '\n' ' ')"
grep -aq '^ok: the real ~/.claude/state/sleep and ~/Downloads gained nothing' "$WORK/engine.out" \
  && check "and its own check that the real folders gained nothing still ran and passed" ok \
  || check "and its own check that the real folders gained nothing still ran and passed" "$(grep -a 'gained nothing' "$WORK/engine.out" | head -2 | tr '\n' ' ')"
[ -f "$FAKE/.claude/state/sleep/notes/1794000000001-$OTHER.jsonl" ] && [ -f "$FAKE/.claude/state/sleep/current.json" ] \
  && check "the other session's files were left as they were" ok \
  || check "the other session's files were left as they were" "a foreign file is gone"

printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
