#!/usr/bin/env bash
# Tests for take-section-time-reading.sh and install-section-time-schedule.sh, the monthly reading
# that keeps the recorded margin re-measuring itself rather than being trusted (claude-config#520).
#
# The margin above SUITE_WORK_BUDGET_PCT is a paragraph, and this repo has watched a dated sentence
# go 2.3x stale in nine days with nothing able to tell (#41, L316). The suite already holds the
# prose to the readings file; what was missing is anything that takes a fresh reading.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAKE="$DIR/take-section-time-reading.sh"
INSTALL="$DIR/install-section-time-schedule.sh"
pass=0; fail=0
check(){ if [[ "$2" == "ok" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-config-section-schedule.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-section-time-schedule: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# A stand in for the measurer: it records what it was asked to do and appends a row, so this suite
# pays no suite run at all (L143, L291).
FAKE="$TMPROOT/fake-measure.sh"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
env | grep '^MEASURE_' | sort > "$FAKE_ENV_LOG"
[ "${1:-}" = "--columns" ] && { printf 'taken_utc\tarm\n'; exit 0; }
printf 'ran\n'
[ -n "${MEASURE_RECORD:-}" ] && printf '2026-01-01T00:00:00Z\tquiet\n' >> "$MEASURE_RECORD"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$FAKE"

REC="$TMPROOT/readings.tsv"
printf 'taken_utc\tarm\n' > "$REC"
LOG="$TMPROOT/reading.log"
export FAKE_ENV_LOG="$TMPROOT/env.log"

out="$(SECTION_TIME_MEASURER="$FAKE" SECTION_TIME_RECORD="$REC" SECTION_TIME_LOG="$LOG" bash "$TAKE" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && check "a reading runs and reports success" ok || check "a reading runs and reports success" "rc=$rc out=$out"
[ "$(grep -c . "$REC")" = "2" ] && check "and the reading is appended to the record" ok \
  || check "and the reading is appended to the record" "record: $(cat "$REC")"
grep -q . "$LOG" && check "and what happened is written to the log the job points at" ok \
  || check "and what happened is written to the log the job points at" "empty log"

# The wait is what makes it a QUIET reading, and a wait bounded only by the clock does unbounded
# work when sampling is cheap, so both bounds have to be set together (L704).
_wait="$(sed -n 's/^MEASURE_WAIT_SECONDS=//p' "$FAKE_ENV_LOG")"
_samples="$(sed -n 's/^MEASURE_WAIT_MAX_SAMPLES=//p' "$FAKE_ENV_LOG")"
[ "${_wait:-0}" -ge 3600 ] && check "it waits at least an hour for a quiet window" ok \
  || check "it waits at least an hour for a quiet window" "MEASURE_WAIT_SECONDS=$_wait"
[ "${_samples:-0}" -ge "$(( ${_wait:-0} / 10 ))" ] && check "and the sample bound covers that whole wait" ok \
  || check "and the sample bound covers that whole wait" "wait=$_wait samples=$_samples"
[ -n "$(sed -n 's/^MEASURE_RECORD=//p' "$FAKE_ENV_LOG")" ] && check "and it points the measurer at the committed record" ok \
  || check "and it points the measurer at the committed record" "no MEASURE_RECORD"

# A machine that never settles is a refusal from the measurer, and the job has to REPORT that
# rather than pass: an unmeasured month must not read like a measured one (L98).
out2="$(FAKE_RC=1 SECTION_TIME_MEASURER="$FAKE" SECTION_TIME_RECORD="$REC" SECTION_TIME_LOG="$LOG" bash "$TAKE" 2>&1)"; rc2=$?
[ "$rc2" -ne 0 ] && case "$out2$(cat "$LOG")" in *"no reading"*) true ;; *) false ;; esac \
  && check "a refused reading is reported as no reading taken" ok \
  || check "a refused reading is reported as no reading taken" "rc=$rc2 out=$out2"

# Two readings must not overlap: each is a whole suite run, and two at once measure each other.
BUSY="$TMPROOT/busy.sh"
printf '#!/usr/bin/env bash\nsleep 5\n' > "$BUSY"; chmod +x "$BUSY"
SECTION_TIME_MEASURER="$BUSY" SECTION_TIME_RECORD="$REC" SECTION_TIME_LOG="$LOG" SECTION_TIME_LOCK="$TMPROOT/lock" bash "$TAKE" >/dev/null 2>&1 &
first=$!
# Wait on the lock appearing rather than on the clock (L290).
n=0; while [ ! -e "$TMPROOT/lock" ] && [ "$n" -lt 200 ]; do n=$((n+1)); sleep 0.05; done
out3="$(SECTION_TIME_MEASURER="$FAKE" SECTION_TIME_RECORD="$REC" SECTION_TIME_LOG="$LOG" SECTION_TIME_LOCK="$TMPROOT/lock" bash "$TAKE" 2>&1)"; rc3=$?
case "$out3" in *"already"*) check "a second reading refuses while one is running" ok ;;
  *) check "a second reading refuses while one is running" "rc=$rc3 out=$out3" ;; esac
kill "$first" 2>/dev/null; wait "$first" 2>/dev/null

# --- the installer writes a MONTHLY job that runs the wrapper, and says where it wrote it.
AGENTS="$TMPROOT/LaunchAgents"
out4="$(SECTION_TIME_LAUNCHAGENTS="$AGENTS" SECTION_TIME_NO_LAUNCHCTL=1 bash "$INSTALL" 2>&1)"; rc4=$?
PLIST="$AGENTS/com.claudeconfig.sectiontime.plist"
[ "$rc4" -eq 0 ] && [ -f "$PLIST" ] && check "the installer writes a launch agent" ok \
  || check "the installer writes a launch agent" "rc=$rc4 out=$out4"
grep -q "take-section-time-reading.sh" "$PLIST" 2>/dev/null && check "and the job runs the reading wrapper" ok \
  || check "and the job runs the reading wrapper" "plist: $(cat "$PLIST" 2>/dev/null)"
grep -q "<key>Day</key>" "$PLIST" 2>/dev/null && check "and it runs monthly, on a day of the month" ok \
  || check "and it runs monthly, on a day of the month" "plist: $(cat "$PLIST" 2>/dev/null)"
case "$out4" in *"$PLIST"*) check "and the installer says where it wrote it" ok ;;
  *) check "and the installer says where it wrote it" "out=$out4" ;; esac
# The path it records is this checkout's, because a launch agent is a COPY and records an absolute
# path (L423): a plist naming a script that is not there is a job that cannot run at all.
_prog="$(sed -n 's|.*<string>\(/[^<]*take-section-time-reading.sh\)</string>.*|\1|p' "$PLIST")"
[ -x "$_prog" ] && check "and that path exists and is runnable" ok \
  || check "and that path exists and is runnable" "plist names $_prog"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
