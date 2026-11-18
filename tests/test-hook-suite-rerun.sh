#!/usr/bin/env bash
# A pull whose hook suite could not finish leaves it owed, and a later receive runs it again
# (claude-config#3195).
#
# On 2026-11-17 a pull on the work MacBook landed a hook at 19:13 ET and ran the hook suite, which
# was stopped at SYNC_HOOK_TESTS_TIMEOUT (1800s) at a load average of 36 to 86 on 18 cores. The
# pull exited 0 saying nothing that landed had been verified, the hooks were live from 19:13 either
# way, and nothing ran the suite again once the Mac was quiet.
#
# This suite holds:
#   1. A run stopped at its deadline is recorded as owed (when it became owed, how many runs were
#      stopped), nobody is notified for it, the pull still exits 0, and status says it is waiting.
#   2. A later receive on a busy Mac runs nothing, says the load it read, and keeps the record.
#   3. The change watcher never runs it.
#   4. A receive while another run holds the rerun leaves it alone and names that run; a claim
#      left by a run that has died is taken over.
#   5. A rerun stopped again notifies ONCE, and nothing runs it again by itself after that.
#   6. A rerun that passes clears the record; one that fails is recorded and notified like any
#      failed run (the failure path).
#   7. A record owed for longer than a rerun is given ends in one notification even when the load
#      never allowed a rerun, and  claude-sync recheck, the remedy it names, clears it.
#
# Everything runs as a fixture home: CLAUDE_HOME and SYNC_REPO are throwaways in WORK, so
# claude-sync touches nothing that belongs to the Mac (README "A fixture home touches nothing that
# belongs to the Mac"). A stand in runner is told what to do by a file outside the payload, so
# changing what it does lands no hook. The deadline is judged on a clock that moves 1000 seconds a
# read, so a runner that never ends is stopped on the second look rather than after a real wait,
# and the load is SET through lib/load-average.sh's own seams rather than read off this Mac (L290,
# L524).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-sync"
. "$HERE/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0; fail=0
check(){   # $1 = name  $2 = a command string that succeeds when the check holds  [$3 = output to show]
  if eval "$2"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1"
    [ -n "${3:-}" ] && printf '%s\n' "$3" | sed -n '1,20p' | sed 's/^/    /'
  fi
  return 0
}
# Every pattern on ONE line of the output, so two halves of different sentences cannot pass it.
line_has(){   # $1 = output  $2.. = fixed strings
  local cur="$1" p
  [ -n "$cur" ] || return 1
  shift
  for p in "$@"; do cur="$(printf '%s\n' "$cur" | grep -F -- "$p")" || return 1; done
  [ -n "$cur" ]
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hook-suite-rerun.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
STANDIN_PID=""
trap '[ -n "$STANDIN_PID" ] && kill "$STANDIN_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

export SYNC_SCRATCH_ROOT="$WORK/scratch-root"; mkdir -p "$SYNC_SCRATCH_ROOT"
export SYNC_MANAGED_SETTINGS="$WORK/managed-settings.json"
printf '{"prependPlugins": []}\n' > "$SYNC_MANAGED_SETTINGS"
export SYNC_CLAUDE_BIN="$WORK/no-such-claude" SYNC_GH="$WORK/no-such-gh" SYNC_RTK_BIN="$WORK/no-such-rtk"
export SYNC_TEMP_ROOTS="/no-such-temp-root-exists-here"
export SYNC_LOG_FILE="$WORK/sync.log"

RRH="$WORK/home"; mkdir -p "$RRH/hooks"; echo '{"hooks":{}}' > "$RRH/settings.json"
RRR="$WORK/repo"; mkdir -p "$RRR/payload/hooks"
RRT="$WORK/t"; mkdir -p "$RRT"
cat > "$RRR/payload/hooks/run-all-tests.sh" <<RRRUN
#!/usr/bin/env bash
echo run >> "$RRT/runs"
case "\$(cat "$RRT/mode" 2>/dev/null)" in
  hang) while :; do sleep 3600 & wait "\$!" || true; done ;;
  fail) echo "1 suite failed"; exit 1 ;;
  *) echo "ALL 1 SUITES PASSED"; exit 0 ;;
esac
RRRUN
chmod +x "$RRR/payload/hooks/run-all-tests.sh"
# The clock: each read answers the time and moves it on a step this suite sets (not measured),
# written beside and renamed over, so a reader sees the whole number or the old one
# (claude-config#2765).
cat > "$RRT/clock" <<RRCLK
#!/usr/bin/env bash
n="\$(cat "$RRT/now" 2>/dev/null || echo 5000000)"
printf '%s\n' "\$(( n + 1000 ))" > "$RRT/now.\$\$" && mv -f "$RRT/now.\$\$" "$RRT/now"
printf '%s\n' "\$n"
RRCLK
# The notifier: one line per notification, its message.
cat > "$RRT/notifier" <<RRNOT
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = -message ]; then printf '%s\n' "\$2" >> "$RRT/told"; shift; fi
  shift
done
RRNOT
chmod +x "$RRT/clock" "$RRT/notifier"
rr_runs(){ if [ -f "$RRT/runs" ]; then wc -l < "$RRT/runs" | tr -d ' '; else echo 0; fi; }
rr_told(){ if [ -f "$RRT/told" ]; then wc -l < "$RRT/told" | tr -d ' '; else echo 0; fi; }
rr_field(){ head -1 "$RRR/.hook-tests" 2>/dev/null | tr '\t' '\n' | sed -n "s/^$1=//p"; }
rr_arrive(){ printf '# marker %s\n' "$1" > "$RRR/payload/hooks/rr-marker.sh"; }
# A pull as the receive timer or a person runs one, with the load set per call.
rr_pull(){ # rr_pull <load> [env assignments...] -> the pull's output; its exit code in $RRT/rc
  local load="$1" rc=0; shift
  env CLAUDE_HOME="$RRH" SYNC_REPO="$RRR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=0 SYNC_NOTIFIER="$RRT/notifier" \
    SYNC_POLL_INTERVAL=0.05 SYNC_HOOK_TESTS_TIMEOUT=1800 SYNC_SUITE_STOP_GRACE=1 \
    SYNC_TEST_SUITE_CLOCK="$RRT/clock" LOAD_AVERAGE_CMD="echo $load" LOAD_AVERAGE_CORES=12 \
    "$@" bash "$SCRIPT" pull 2>&1 || rc=$?
  echo "$rc" > "$RRT/rc"
}
rr_status(){ CLAUDE_HOME="$RRH" SYNC_REPO="$RRR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1; }
# A record as a stopped run writes one, owed since the time given.
rr_forge(){ # rr_forge <owed since> [stopped]
  printf 'outcome=incomplete\tat=%s\texit=0\tran=?\tnotrun=?\tseconds=1800\tnotrun_names=?\towed_since=%s\tstopped=%s\n' \
    "$(date +%s)" "$1" "${2:-1}" > "$RRR/.hook-tests"
}

# ---- 1. the first run is stopped at its deadline: owed, recorded, and nobody is notified yet ----
echo hang > "$RRT/mode"; rr_arrive one
out1="$(rr_pull 50)"
check "(fixture) the first pull landed a hook and ran the stand in runner once" "[ \"\$(rr_runs)\" = 1 ]" "$out1"
check "a pull whose suite was stopped at its deadline says nothing that landed is verified" \
  "line_has \"\$out1\" 'could NOT be completed here' 'still running after 1800s'" "$out1"
check "and says it is owed a second run once the load allows" \
  "line_has \"\$out1\" 'could NOT be completed here' 'runs it again' 'load average'" "$out1"
check "the record says incomplete, owed since that run, with one stopped run" \
  "grep -q '^outcome=incomplete' '$RRR/.hook-tests' && [ -n \"\$(rr_field owed_since)\" ] && [ \"\$(rr_field stopped)\" = 1 ]" \
  "$(head -1 "$RRR/.hook-tests" 2>/dev/null)"
check "nobody is notified for the first stopped run, which a later run may clear by itself" \
  "[ \"\$(rr_told)\" = 0 ]" "$(cat "$RRT/told" 2>/dev/null)"
check "an unverified pull still exits 0" "[ \"\$(cat '$RRT/rc')\" = 0 ]"
st1="$(rr_status)"
check "status says an unverified pull is waiting to be run again" \
  "line_has \"\$st1\" 'hook suite: could NOT be completed' 'owed a second run' 'load average'" "$st1"

# ---- 2. a busy Mac: the next receive runs nothing, says why, and keeps the record ----
out2="$(rr_pull 50)"
check "a receive with the load above the core count does not run the suite again" "[ \"\$(rr_runs)\" = 1 ]" "$out2"
check "and says it was not run again, with the load it read" \
  "line_has \"\$out2\" 'was not run again yet' 'load average 50 on 12 cores'" "$out2"
check "and the record is still owed, with when it last tried" \
  "grep -q '^outcome=incomplete' '$RRR/.hook-tests' && [ -n \"\$(rr_field deferred_at)\" ] && [ \"\$(rr_field stopped)\" = 1 ]" \
  "$(head -1 "$RRR/.hook-tests" 2>/dev/null)"
check "and nobody is notified for a deferral" "[ \"\$(rr_told)\" = 0 ]"
st2="$(rr_status)"
check "status names the load the last try found" "line_has \"\$st2\" 'owed a second run' 'load average 50 on 12 cores'" "$st2"

# ---- 3. the change watcher never runs it: every tick would sit out a whole suite ----
out3w="$(rr_pull 1 SYNC_IN_WATCH=1)"
check "a receive in the change watcher leaves the owed run for a pull or the timer" \
  "[ \"\$(rr_runs)\" = 1 ] && grep -q '^outcome=incomplete' '$RRR/.hook-tests'" "$out3w"

# ---- 4. a run already acting on the record: a second receive leaves it alone ----
printf 'sleep 60\n' > "$RRT/claude-sync-standin"
# Its output goes nowhere, so the sleep it leaves behind cannot hold this suite's own output open.
bash "$RRT/claude-sync-standin" >/dev/null 2>&1 < /dev/null & STANDIN_PID=$!
printf '%s\n' "$STANDIN_PID" > "$RRR/.hook-tests-rerun"
out3="$(rr_pull 1)"
check "a receive while another run holds the rerun does not run the suite a second time" "[ \"\$(rr_runs)\" = 1 ]" "$out3"
check "and names the run that holds it" "line_has \"\$out3\" 'not run again here' \"another run (pid $STANDIN_PID)\"" "$out3"
check "and leaves that run's claim alone" "[ \"\$(cat '$RRR/.hook-tests-rerun' 2>/dev/null)\" = '$STANDIN_PID' ]"
st3="$(rr_status)"
check "status says it is being run again now" "line_has \"\$st3\" 'being run again now' \"pid $STANDIN_PID\"" "$st3"
# The holder goes, so its claim is stale and is taken over below rather than waited on for ever.
kill "$STANDIN_PID" 2>/dev/null; wait "$STANDIN_PID" 2>/dev/null; STANDIN_PID=""

# ---- 5. the quiet moment: run again, stopped again, told ONCE, and not run again by itself ----
out4="$(rr_pull 1)"
check "a receive on a quiet Mac runs the owed suite again, taking over a dead run's claim" "[ \"\$(rr_runs)\" = 2 ]" "$out4"
check "and says the suite left unverified was run again" "line_has \"\$out4\" 'left unverified' 'was run again'" "$out4"
check "a second run that cannot finish either says it will not be run again by itself" \
  "line_has \"\$out4\" 'could NOT be completed here' 'will not be run again by itself' 'claude-sync recheck'" "$out4"
check "and that is the one notification" "[ \"\$(rr_told)\" = 1 ] && grep -q 'claude-sync recheck' '$RRT/told'" \
  "$(cat "$RRT/told" 2>/dev/null)"
check "the record counts two stopped runs and says it gave up" \
  "[ \"\$(rr_field stopped)\" = 2 ] && [ -n \"\$(rr_field gave_up)\" ]" "$(head -1 "$RRR/.hook-tests" 2>/dev/null)"
check "the claim is released once the run ends" "[ ! -e '$RRR/.hook-tests-rerun' ]"
out5="$(rr_pull 1)"
check "a record that cannot be cleared here is not run again every cycle" "[ \"\$(rr_runs)\" = 2 ]" "$out5"
check "and nobody is notified a second time" "[ \"\$(rr_told)\" = 1 ]"
st5="$(rr_status)"
check "status says it will not be run again by itself, and what to run" \
  "line_has \"\$st5\" 'could NOT be completed' 'will not be run again by itself' 'claude-sync recheck'" "$st5"

# ---- 6. a rerun that passes clears the record, and one that fails is the failed run it is ----
rr_forge "$(date +%s)"; echo pass > "$RRT/mode"
out6="$(rr_pull 1)"
check "a rerun that passes replaces the owed record with a pass" \
  "[ \"\$(rr_runs)\" = 3 ] && grep -q '^outcome=passed' '$RRR/.hook-tests' && [ -z \"\$(rr_field owed_since)\" ]" "$out6"
check "and says so on its closing line" "line_has \"\$out6\" 'was run again' 'hook suite passed here'" "$out6"
check "and notifies nobody" "[ \"\$(rr_told)\" = 1 ]"
out7="$(rr_pull 1)"
check "(control) once passed, a receive landing no hook runs nothing" "[ \"\$(rr_runs)\" = 3 ]" "$out7"

rr_forge "$(date +%s)"; echo fail > "$RRT/mode"
out8="$(rr_pull 1)"
check "a rerun that fails is recorded as failed and said" \
  "[ \"\$(rr_runs)\" = 4 ] && grep -q '^outcome=failed' '$RRR/.hook-tests' && line_has \"\$out8\" 'hook suite FAILED here' 'exited 1'" "$out8"
rr_last_told="$(tail -1 "$RRT/told" 2>/dev/null)"
check "and notifies once" "[ \"\$(rr_told)\" = 2 ] && [ \"\${rr_last_told#*FAILED}\" != \"\$rr_last_told\" ]" "$(cat "$RRT/told" 2>/dev/null)"
out9="$(rr_pull 1)"
check "a failed record is not run again by itself, and not notified again" \
  "[ \"\$(rr_runs)\" = 4 ] && [ \"\$(rr_told)\" = 2 ]" "$out9"

# ---- 7. owed for longer than a rerun is given, the load never allowing: told once, then left ----
rr_forge 1000; echo pass > "$RRT/mode"
out10="$(rr_pull 50)"
check "a record owed past the bound runs nothing and says it will not be run again by itself" \
  "[ \"\$(rr_runs)\" = 4 ] && line_has \"\$out10\" 'unverified since' 'will not be run again by itself' 'claude-sync recheck'" "$out10"
check "and that is one notification" "[ \"\$(rr_told)\" = 3 ] && [ -n \"\$(rr_field gave_up)\" ]" "$(cat "$RRT/told" 2>/dev/null)"
out11="$(rr_pull 1)"
check "and no later receive runs it or notifies again" "[ \"\$(rr_runs)\" = 4 ] && [ \"\$(rr_told)\" = 3 ]" "$out11"
outr="$(CLAUDE_HOME="$RRH" SYNC_REPO="$RRR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" recheck 2>&1)"
check "claude-sync recheck, the remedy it names, runs the suite and clears the record" \
  "[ \"\$(rr_runs)\" = 5 ] && grep -q '^outcome=passed' '$RRR/.hook-tests'" "$outr"

# ---- a hook landing after a give up starts a chain of its own, owed again and not notified ----
printf 'outcome=incomplete\tat=%s\texit=0\tran=?\tnotrun=?\tseconds=1800\tnotrun_names=?\towed_since=1000\tstopped=2\tgave_up=%s\tgave_up_why=twice\n' \
  "$(date +%s)" "$(date +%s)" > "$RRR/.hook-tests"
echo hang > "$RRT/mode"; rr_arrive two
out12="$(rr_pull 50)"
check "a hook landing after a give up is checked, and its stopped run starts a new chain" \
  "[ \"\$(rr_runs)\" = 6 ] && [ \"\$(rr_field stopped)\" = 1 ] && [ -z \"\$(rr_field gave_up)\" ] && [ \"\$(rr_field owed_since)\" != 1000 ]" \
  "$(head -1 "$RRR/.hook-tests" 2>/dev/null)"
check "and it is owed a rerun again, with nobody notified" \
  "line_has \"\$out12\" 'could NOT be completed here' 'runs it again' && [ \"\$(rr_told)\" = 3 ]" "$out12"

# ---- where the writes landed (L322): the fixture, and nothing of this Mac's ----
check "every record and claim this suite caused is inside the fixture clone" \
  "[ -f '$RRR/.hook-tests' ] && [ ! -e '$HERE/../.hook-tests-rerun' ]"

echo ""
echo "PASS=$pass FAIL=$fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
