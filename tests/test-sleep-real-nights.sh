#!/usr/bin/env bash
# tests/sleep-real-nights.py (claude-config#1662): which parts of sleep mode the headless real engine
# suite cannot measure have been measured by a real night on this Mac, read from the durable record
# each part leaves (L239), each judged by its own predicate with a control beside it (L540). Only
# fixture folders here; test-sleep-real-engine.sh reads this Mac's own nights with it.
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
READER="$DIR/sleep-real-nights.py"
TAB=$'\t'
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-sleep-real-nights.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

DAY=86400000
SINCE=1792800000000
NOW=$((SINCE + DAY))
S1=aaaaaaaa-1111-1111-1111-111111111111
S2=bbbbbbbb-2222-2222-2222-222222222222
S3=cccccccc-3333-3333-3333-333333333333
# night STATE NAME WORKERS_JSON GOALS_JSON: an ended record started by S1 at SINCE.
night() {
  mkdir -p "$1/ended" "$1/notes"
  printf '{"v":1,"generation":"%s-%s","since":%s,"night":"%s","startedBy":{"sessionId":"%s"},"workers":%s,"goals":%s}\n' \
    "$SINCE" "$S1" "$SINCE" "$2" "$S1" "$3" "$4" > "$1/ended/$((SINCE + 9 * 3600000))-woke-$S1.json"
}
# note STATE JSON: one note line for that night.
note() { printf '%s\n' "$2" >> "$1/notes/$SINCE-$S1.jsonl"; }
read_parts() { python3 -I "$READER" "$@" 2>"$WORK/err"; }
line_of() { grep "^[a-z]*${TAB}$2${TAB}" <<<"$1"; }
KEYS="enrolment told-to-start bedtime-questions model-rules hour usage-limit"

# 1. No sleep state at all (CI, or a Mac that has never slept): every part unmeasured, and why.
OUT="$(read_parts "$WORK/none" "$NOW")"; RC=$?
[ "$RC" -eq 0 ] && [ "$(grep -c "^unmeasured${TAB}" <<<"$OUT")" -eq 6 ] && grep -q 'no real night has ended on this Mac yet' <<<"$OUT" \
  && check "with no night ever ended, all six parts are unmeasured, saying so" ok \
  || check "with no night ever ended, all six parts are unmeasured, saying so" "rc=$RC out=$OUT err=$(cat "$WORK/err")"
[ "$(cut -f2 <<<"$OUT" | tr '\n' ' ')" = "$KEYS " ] \
  && check "one line per part, in a fixed order" ok \
  || check "one line per part, in a fixed order" "$(cut -f2 <<<"$OUT" | tr '\n' ' ')"

# 2. A night that shows every part.
FULL="$WORK/full"
night "$FULL" 2026-10-23 "[\"$S1\",\"$S2\"]" "{\"$S1\":\"Close #7\",\"$S2\":\"Close #9\"}"
note "$FULL" "{\"kind\":\"question\",\"at\":$SINCE,\"by\":\"$S1\",\"repo\":\"o/r\",\"issue\":4,\"text\":\"Which?\"}"
note "$FULL" "{\"kind\":\"heartbeat\",\"at\":$((SINCE + 60000)),\"by\":\"$S2\"}"
note "$FULL" "{\"kind\":\"claim\",\"at\":$((SINCE + 120000)),\"by\":\"$S2\",\"repo\":\"o/r\",\"issue\":9}"
note "$FULL" "{\"kind\":\"wait\",\"at\":$((SINCE + 180000)),\"by\":\"$S2\",\"minutes\":30,\"error\":\"rate_limit\"}"
note "$FULL" "{\"kind\":\"heartbeat\",\"at\":$((SINCE + 61 * 60000)),\"by\":\"$S2\"}"
OUT="$(read_parts "$FULL" "$NOW")"; RC=$?
[ "$RC" -eq 0 ] && [ "$(grep -c "^measured${TAB}" <<<"$OUT")" -eq 6 ] && [ "$(grep -c 'the real night of 2026-10-23' <<<"$OUT")" -eq 6 ] \
  && check "a night showing every part measures all six, naming the night" ok \
  || check "a night showing every part measures all six, naming the night" "rc=$RC out=$OUT err=$(cat "$WORK/err")"
grep -q "ended/$((SINCE + 9 * 3600000))-woke-$S1.json" <<<"$(line_of "$OUT" hour)" \
  && check "each names the record it was read from" ok \
  || check "each names the record it was read from" "$(line_of "$OUT" hour)"
grep -q 'kept working for 60 minutes' <<<"$(line_of "$OUT" hour)" \
  && check "the hour is measured from one worker's own heartbeats" ok \
  || check "the hour is measured from one worker's own heartbeats" "$(line_of "$OUT" hour)"

# 3. Too old: the same night read 31 days on is unmeasured again, naming it (L523).
OUT="$(read_parts "$FULL" $((SINCE + 31 * DAY)))"
[ "$(grep -c "^unmeasured${TAB}" <<<"$OUT")" -eq 6 ] && grep -q '2026-10-23, is more than 30 days old' <<<"$OUT" \
  && check "a night more than 30 days old no longer counts, and is named as the last that showed it" ok \
  || check "a night more than 30 days old no longer counts, and is named as the last that showed it" "$OUT"

# 4. Controls: a night near each predicate but outside it shows nothing (L540).
NEAR="$WORK/near"
# The starter not enrolled, and a second worker with no goal that worked.
night "$NEAR" 2026-10-22 "[\"$S2\"]" "{}"
# A question asked overnight (not at bedtime), a claim by a session that is not a worker, a wait
# with no error, and heartbeats just under an hour apart (set by this fixture, not measured).
note "$NEAR" "{\"kind\":\"question\",\"at\":$((SINCE + 5000)),\"by\":\"$S2\",\"repo\":\"o/r\",\"issue\":4,\"text\":\"Which?\"}"
note "$NEAR" "{\"kind\":\"claim\",\"at\":$((SINCE + 6000)),\"by\":\"$S3\",\"repo\":\"o/r\",\"issue\":9}"
note "$NEAR" "{\"kind\":\"wait\",\"at\":$((SINCE + 7000)),\"by\":\"$S2\",\"minutes\":30}"
note "$NEAR" "{\"kind\":\"heartbeat\",\"at\":$((SINCE + 60000)),\"by\":\"$S2\"}"
note "$NEAR" "{\"kind\":\"heartbeat\",\"at\":$((SINCE + 60 * 60000 - 1)),\"by\":\"$S2\"}"
OUT="$(read_parts "$NEAR" "$NOW")"; RC=$?
[ "$RC" -eq 0 ] && [ "$(grep -c "^unmeasured${TAB}" <<<"$OUT")" -eq 6 ] && [ "$(grep -c 'no real night on this Mac has shown it yet' <<<"$OUT")" -eq 6 ] \
  && check "controls: nothing just outside each predicate counts as measured" ok \
  || check "controls: nothing just outside each predicate counts as measured" "rc=$RC out=$OUT err=$(cat "$WORK/err")"

# 5. A bedtime answer recorded within the reader's bedtime window (BEDTIME_MS, 15 minutes before
# the record is placed, a window the reader sets, not a measurement) measures the questions too:
# one at its very start counts, and one a millisecond earlier, or one after the record, does not.
WINDOW=$((15 * 60000))
answered_at_ms() {   # answered_at_ms FOLDER MS: a night with one before bed answer recorded at MS
  rm -rf "$1"
  night "$1" 2026-10-21 "[]" "{}"
  mkdir -p "$1/answered"
  printf '{"repo":"o/r","issue":4,"text":"Which?","answer":"A","at":%s}\n' "$2" > "$1/answered/k.json"
}
ANS="$WORK/answered"
answered_at_ms "$ANS" $((SINCE - WINDOW))
grep -q "^measured${TAB}bedtime-questions${TAB}.*0 left for the morning and 1 answered at bedtime" <<<"$(read_parts "$ANS" "$NOW")" \
  && check "a before bed answer at the very start of the bedtime window measures the questions" ok \
  || check "a before bed answer at the very start of the bedtime window measures the questions" "$(read_parts "$ANS" "$NOW")"
answered_at_ms "$ANS" $((SINCE - WINDOW - 1))
grep -q "^unmeasured${TAB}bedtime-questions${TAB}" <<<"$(read_parts "$ANS" "$NOW")" \
  && check "control: an answer a millisecond before the window does not" ok \
  || check "control: an answer a millisecond before the window does not" "$(read_parts "$ANS" "$NOW")"
answered_at_ms "$ANS" $((SINCE + 1))
grep -q "^unmeasured${TAB}bedtime-questions${TAB}" <<<"$(read_parts "$ANS" "$NOW")" \
  && check "control: nor does one recorded after the record was placed" ok \
  || check "control: nor does one recorded after the record was placed" "$(read_parts "$ANS" "$NOW")"

# 5a. An answer file that is not an answer (a JSON list, a string, or not JSON) is a failure with
# the reason, exit 2, never a traceback and never skipped as no answer (L10, L11).
for _shape in '["at"]' '"at"' '{"at":'; do
  answered_at_ms "$ANS" "$SINCE"
  printf '%s\n' "$_shape" > "$ANS/answered/k.json"
  OUT="$(read_parts "$ANS" "$NOW")"; RC=$?
  [ "$RC" -eq 2 ] && [ -z "$OUT" ] && grep -q 'could not be read' "$WORK/err" && ! grep -q Traceback "$WORK/err" \
    && check "an answer file holding $_shape fails with the reason" ok \
    || check "an answer file holding $_shape fails with the reason" "rc=$RC out=$OUT err=$(head -c 300 "$WORK/err")"
done

# 6. A record that cannot be read is a failure, said, never a night that showed nothing (L10).
BAD="$WORK/bad"
mkdir -p "$BAD/ended"
printf '{"v":1,' > "$BAD/ended/1-woke-x.json"
OUT="$(read_parts "$BAD" "$NOW")"; RC=$?
[ "$RC" -eq 2 ] && [ -z "$OUT" ] && grep -q 'a night could not be read' "$WORK/err" \
  && check "an unreadable record fails, saying so, and claims nothing" ok \
  || check "an unreadable record fails, saying so, and claims nothing" "rc=$RC out=$OUT err=$(cat "$WORK/err")"

# 7. A folder of nights or notes that cannot be read is a failure too, never "no nights" or a night
# with no notes (L10, L11). Root reads a mode 000 folder, so there it is said unmeasured (L411).
if [ "$(id -u)" -eq 0 ]; then
  echo "SUITE-PART-UNMEASURED an unreadable folder of nights or notes: this runs as root, which reads a mode 000 folder"
else
  LOCKED="$WORK/locked"
  cp -R "$FULL" "$LOCKED"
  chmod 000 "$LOCKED/ended"
  OUT="$(read_parts "$LOCKED" "$NOW")"; RC=$?
  chmod 755 "$LOCKED/ended"
  [ "$RC" -eq 2 ] && [ -z "$OUT" ] && grep -q 'could not be read' "$WORK/err" \
    && check "a folder of nights that cannot be read fails, saying so, never reads as no nights" ok \
    || check "a folder of nights that cannot be read fails, saying so, never reads as no nights" "rc=$RC out=$OUT err=$(cat "$WORK/err")"
  chmod 000 "$LOCKED/notes"
  OUT="$(read_parts "$LOCKED" "$NOW")"; RC=$?
  chmod 755 "$LOCKED/notes"
  [ "$RC" -eq 2 ] && [ -z "$OUT" ] && grep -q 'could not be read' "$WORK/err" \
    && check "a folder of notes that cannot be read fails, saying so, never reads as a night with no notes" ok \
    || check "a folder of notes that cannot be read fails, saying so, never reads as a night with no notes" "rc=$RC out=$OUT err=$(cat "$WORK/err")"
fi

printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
