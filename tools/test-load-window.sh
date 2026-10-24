#!/usr/bin/env bash
#
# test-load-window.sh: tools/load-window.sh, the one helper a deliberate load reproduction runs in,
# and lib/load-window.sh, the record of its windows the merge helper and the suite pile notice name
# (claude-config#1618).
#
# The clock and the sleep are injected (L524): the clock is a file, and the sleep advances it and
# runs whatever the case has queued for that moment (clearing a process table, starting a merge), so
# nothing here waits on time passing. The process table is a fixture (SYNC_PS_FIXTURE) except in the
# one case that proves the real one is read. What the helper STARTS is real (busy loops, a command),
# because whether those are stopped is the point, and every check of that is on a condition: a
# process gone, a file present, never a duration (L290). The waits on a background helper have a
# ceiling only a hang reaches.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/load-window.sh"
LIB="$DIR/../payload/hooks/lib/load-window.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.loadwindow.XXXXXXXX")" || W=""
case "${W%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$W'" >&2; exit 2 ;; esac
BG=""
cleanup(){ [ -z "$BG" ] || { pkill -9 -P "$BG" 2>/dev/null; kill -9 "$BG" 2>/dev/null; }; rm -rf "$W"; }
trap cleanup EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
says(){ case "$3" in *"$2"*) ok ;; *) bad "$1 (wanted [$2] in: ${3:0:600})" ;; esac; }
lacks(){ case "$3" in *"$2"*) bad "$1 (did not want [$2] in: ${3:0:600})" ;; *) ok ;; esac; }
eq(){ if [ "$2" = "$3" ]; then ok; else bad "$1 (wanted '$2', got '$3')"; fi; }

# A wait on a condition, with the one ceiling only a hang reaches (lib/hang-wait.sh, #1620).
. "$DIR/../payload/hooks/lib/hang-wait.sh" || { echo "FAIL: lib/hang-wait.sh is missing"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
wait_for(){ hang_wait "$1"; }   # wait_for <shell condition> -> 0 once true, 1 at the ceiling
# Gone means not running: a killed process waiting to be reaped (state Z) is gone, since it runs
# nothing and holds nothing, and whether the system has reaped it yet is not the helper's to decide.
gone(){ ! kill -0 "$1" 2>/dev/null || case "$(ps -o stat= -p "$1" 2>/dev/null)" in *Z*) true ;; *) false ;; esac; }
group_empty(){ local p; for p in $(pgrep -g "$1" 2>/dev/null); do gone "$p" || return 1; done; return 0; }

mkdir -p "$W/bin"
# The fake sleep: advances the clock by its argument, then runs the case's queued hook, if any.
cat > "$W/bin/fake-sleep" <<'SH'
#!/usr/bin/env bash
c="$(cat "$LW_CLOCK")"; echo $(( c + ${1%.*} )) > "$LW_CLOCK"
n="$(cat "$LW_CLOCK.sleeps" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$LW_CLOCK.sleeps"
[ ! -f "$LW_HOOK.$n" ] || HELPER_PID="$PPID" bash "$LW_HOOK.$n"
exit 0
SH
chmod +x "$W/bin/fake-sleep"

T0=1792800000   # 2026-10-23 03:20:00 UTC, 20:00:00 ET the day before
case_dir=""
fresh(){   # a world of its own for each case
  case_dir="$W/case.$1"; mkdir -p "$case_dir/turns" "$case_dir/merge-turns"
  : > "$case_dir/ps"
  echo "$T0" > "$case_dir/clock"
  export LW_CLOCK="$case_dir/clock" LW_HOOK="$case_dir/hook"
  export LOAD_WINDOW_NOW="cat $case_dir/clock" LOAD_WINDOW_SLEEP="$W/bin/fake-sleep"
  export SYNC_PS_FIXTURE="$case_dir/ps" LOAD_WINDOW_MERGE_TURNS="$case_dir/merge-turns"
  export LOAD_WINDOW_DIR="$case_dir/lw" LOAD_WINDOW_WAIT_POLL=5 LOAD_WINDOW_POLL=1
  unset LOAD_WINDOW_WAIT_SECONDS LOAD_WINDOW_HOLD_SECONDS
}
record(){ cat "$LOAD_WINDOW_DIR/windows.tsv" 2>/dev/null; }
run(){ OUT="$(bash "$TOOL" "$@" 2>&1)"; RC=$?; }

# A command that says where it is: its own pid, the workers' group, and how many are in that group.
cat > "$W/report.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" > "$1.pid"
echo "$LOAD_WINDOW_WORKERS_PGID" > "$1.wgroup"
pgrep -g "$LOAD_WINDOW_WORKERS_PGID" | wc -l | tr -d ' ' > "$1.wcount"
echo "the command ran"
exit "${2:-0}"
SH
# A command that never ends on its own.
cat > "$W/forever.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" > "$1.pid"
echo "$LOAD_WINDOW_WORKERS_PGID" > "$1.wgroup"
exec sleep 617
SH

# =================================================================================================
# 1. Usage: a window is bounded at three minutes, and needs something to run.
# =================================================================================================
fresh usage
run --seconds 181 --workers 1
eq "#1618 a window past 180 seconds is refused as a usage fault" 2 "$RC"
says "#1618 and the refusal names the cap" "outside 1 to 180" "$OUT"
run --workers 1
eq "#1618 a window with no --seconds is refused" 2 "$RC"
run --seconds 5 --workers 0 --spawners 0
eq "#1618 a window with no workers is refused" 2 "$RC"
eq "#1618 and none of these recorded a window" "" "$(record)"
# A leading zero is a number, never an octal error that kills the run (lessons review, #1640).
fresh zeros
run --seconds 09 --workers 08 --spawners 09 -- bash "$W/report.sh" "$case_dir/r"
eq "#1618 numbers with a leading zero are read as base ten" 0 "$RC"
says "#1618 and said as such" "8 busy and 9 process launching workers" "$OUT"

# =================================================================================================
# 2. A quiet Mac: the window runs the command with its workers, records its start and end in ET,
#    passes the command's exit back, and leaves nothing running.
# =================================================================================================
fresh quiet
run --seconds 30 --workers 2 --spawners 1 --label "quiet case" -- bash "$W/report.sh" "$case_dir/r" 3
eq "#1618 the command's own exit comes back" 3 "$RC"
says "#1618 the command's output is passed through" "the command ran" "$OUT"
says "#1618 the start is said in ET" "Window started at 20:00:00 ET, until 20:00:30 ET at the latest: 2 busy and 1 process launching workers, \"quiet case\"" "$OUT"
says "#1618 and the end, with how it ended" "the command finished (exit 3)" "$OUT"
# 3 workers, their watchdog's subshell and its sleep, and the group's own shell: the workers ran
# while the command did.
wc_="$(cat "$case_dir/r.wcount" 2>/dev/null)"
if [ "${wc_:-0}" -ge 4 ]; then ok; else bad "#1618 the workers were running while the command ran (group had ${wc_:-nothing})"; fi
wg="$(cat "$case_dir/r.wgroup" 2>/dev/null)"
if [ -n "$wg" ] && group_empty "$wg"; then ok; else bad "#1618 the workers' group is empty once the window ends (group '$wg')"; fi
rec="$(record)"
says "#1618 the record holds the start" "$(printf 'start\t%s.' "$T0")" "$rec"
says "#1618 with its deadline, workers and label" "$(printf '\t%s\t' $((T0 + 30)))" "$rec"
says "#1618 and the end" "the command finished (exit 3)" "$rec"
eq "#1618 the window's turn is given up" "" "$(ls "$LOAD_WINDOW_DIR/queue/turn" 2>/dev/null | grep -E '^[0-9]+$')"

# =================================================================================================
# 3. Waits for a merge-when-ready.sh run, without starting anything, and runs once it has gone.
# =================================================================================================
fresh waitmerge
printf '%s\n' "4242 1 00:05 /bin/bash /Users/x/.claude/hooks/lib/merge-when-ready.sh 7 --squash" > "$case_dir/ps"
printf '%s\n' "cp \"$LOAD_WINDOW_DIR/windows.tsv\" \"$case_dir/record-while-waiting\" 2>/dev/null; : > \"$case_dir/ps\"" > "$case_dir/hook.1"
run --seconds 10 --workers 1 -- bash "$W/report.sh" "$case_dir/r"
eq "#1618 once the merge has gone the window runs" 0 "$RC"
says "#1618 it said what it waited for" "Waiting for a merge-when-ready.sh run (/bin/bash /Users/x/.claude/hooks/lib/merge-when-ready.sh 7 --squash)" "$OUT"
eq "#1618 and nothing was recorded while it waited" "" "$(cat "$case_dir/record-while-waiting" 2>/dev/null)"
says "#1618 and the window started after the wait, on the injected clock" "Window started at 20:00:05 ET" "$OUT"

# =================================================================================================
# 4. A full suite run is waited for too; a command line merely NAMING the scripts is not a run.
# =================================================================================================
fresh suite
printf '%s\n' "5151 1 01:05 bash payload/hooks/run-all-tests.sh" > "$case_dir/ps"
printf '%s\n' ": > \"$case_dir/ps\"" > "$case_dir/hook.1"
run --seconds 10 --workers 1 -- bash "$W/report.sh" "$case_dir/r"
says "#1618 a full suite run is waited for" "Waiting for a full suite run (bash payload/hooks/run-all-tests.sh)" "$OUT"
fresh namers
printf '%s\n' "6161 1 00:01 grep -n merge-when-ready.sh notes.txt" "6162 1 00:01 vim payload/hooks/run-all-tests.sh" "6163 1 00:01 bash payload/hooks/test-run-all-tests.sh" > "$case_dir/ps"
run --seconds 10 --workers 1 -- bash "$W/report.sh" "$case_dir/r"
lacks "#1618 a grep, an editor and a single suite are not runs to wait for" "Waiting for" "$OUT"
eq "#1618 so the window ran at once" 0 "$RC"

# =================================================================================================
# 5. The merge helper's own turn folders: a live ticket is a run whatever its command line says
#    (L1011); a dead one is not.
# =================================================================================================
fresh ticket
mkdir -p "$LOAD_WINDOW_MERGE_TURNS/acme/widget"
printf 'pr 9\npid %s\nstart %s\njoined 1\n' "$$" "$(ps -o lstart= -p $$ | sed -e 's/^ *//' -e 's/ *$//')" > "$LOAD_WINDOW_MERGE_TURNS/acme/widget/1"
printf '%s\n' "rm -f \"$LOAD_WINDOW_MERGE_TURNS/acme/widget/1\"" > "$case_dir/hook.1"
run --seconds 10 --workers 1 -- bash "$W/report.sh" "$case_dir/r"
says "#1618 a live merge turn ticket is waited for" "Waiting for a merge-when-ready.sh run holding a place to merge acme/widget#9" "$OUT"
eq "#1618 and the window ran once it was gone" 0 "$RC"
fresh deadticket
mkdir -p "$LOAD_WINDOW_MERGE_TURNS/acme/widget"
printf 'pr 9\npid 99999999\nstart x\njoined 1\n' > "$LOAD_WINDOW_MERGE_TURNS/acme/widget/1"
run --seconds 10 --workers 1 -- bash "$W/report.sh" "$case_dir/r"
lacks "#1618 a dead merge ticket is not waited for" "Waiting for" "$OUT"

# =================================================================================================
# 6. Still busy at the wait's ceiling: refused, nothing started, nothing recorded.
# =================================================================================================
fresh refuse
printf '%s\n' "4242 1 00:05 bash /x/merge-when-ready.sh 7" > "$case_dir/ps"
LOAD_WINDOW_WAIT_SECONDS=30 run --seconds 10 --workers 1 -- bash "$W/report.sh" "$case_dir/r"
eq "#1618 refused at the wait's ceiling with exit 75" 75 "$RC"
says "#1618 naming what it was still waiting for" "Refused: after 30s this is still waiting for a merge-when-ready.sh run" "$OUT"
eq "#1618 the command never ran" "" "$(cat "$case_dir/r.pid" 2>/dev/null)"
eq "#1618 and no window was recorded" "" "$(record)"
eq "#1618 and the turn was given up" "" "$(ls "$LOAD_WINDOW_DIR/queue/turn" 2>/dev/null | grep -E '^[0-9]+$')"

# =================================================================================================
# 7. The ceiling: a command still running at the deadline is cut off, with everything it started.
# =================================================================================================
fresh ceiling
run --seconds 3 --workers 1 -- bash "$W/forever.sh" "$case_dir/f"
eq "#1618 a command running past the ceiling ends the window with 124" 124 "$RC"
says "#1618 and says it was cut off" "cut off at its 3s ceiling, the command still running" "$OUT"
fp="$(cat "$case_dir/f.pid" 2>/dev/null)"
if [ -n "$fp" ] && gone "$fp"; then ok; else bad "#1618 the command cut off at the ceiling is gone the moment the helper returns (pid '$fp')"; fi
wg="$(cat "$case_dir/f.wgroup" 2>/dev/null)"
if [ -n "$wg" ] && group_empty "$wg"; then ok; else bad "#1618 and so are its workers (group '$wg')"; fi
says "#1618 the record's end says so" "cut off at its 3s ceiling" "$(record)"

# =================================================================================================
# 8. A merge or full suite starting DURING the window: the window yields. One its own command starts
#    is not counted: the table is written with the helper as that process's ancestor.
# =================================================================================================
fresh yield
cat > "$case_dir/hook.2" <<SH
printf '%s\n' "\$HELPER_PID 1 00:01 bash tools/load-window.sh" "50001 \$HELPER_PID 00:01 bash /x/run-all-tests.sh" > "$case_dir/ps"
SH
cat > "$case_dir/hook.4" <<SH
printf '%s\n' "50002 1 00:01 bash /Users/x/.claude/hooks/lib/merge-when-ready.sh 12 --squash" >> "$case_dir/ps"
SH
run --seconds 60 --workers 1 -- bash "$W/forever.sh" "$case_dir/f"
eq "#1618 a merge starting during the window makes it yield with 75" 75 "$RC"
says "#1618 and says why" "Stopping early: a merge-when-ready.sh run (bash /Users/x/.claude/hooks/lib/merge-when-ready.sh 12 --squash) started" "$OUT"
lacks "#1618 a full suite its own command started did not end it" "a full suite run" "$OUT"
says "#1618 the end recorded is the yield, on the injected clock" "yielded after 4s to a merge-when-ready.sh run" "$(record)"
fp="$(cat "$case_dir/f.pid" 2>/dev/null)"
if [ -n "$fp" ] && gone "$fp"; then ok; else bad "#1618 the yielded window's command is gone (pid '$fp')"; fi

# =================================================================================================
# 9. One window at a time: another window's live ticket is waited for; a dead holder is passed over
#    at once (L409); a live holder past the bound is passed over by the one waiting (L523).
# =================================================================================================
fresh turnlive
sleep 600 & holder=$!; BG="$holder"
hstart="$(ps -o lstart= -p "$holder" | sed -e 's/^ *//' -e 's/ *$//')"
mkdir -p "$LOAD_WINDOW_DIR/queue/turn"
printf 'pr %s\npid %s\nstart %s\njoined %s\n' "$holder" "$holder" "$hstart" "$T0" > "$LOAD_WINDOW_DIR/queue/turn/1"
printf '%s\n' "rm -f \"$LOAD_WINDOW_DIR/queue/turn/1\" \"$LOAD_WINDOW_DIR/queue/turn/1.head\"" > "$case_dir/hook.1"
run --seconds 10 --workers 1 -- bash "$W/report.sh" "$case_dir/r"
says "#1618 another window holding the turn is waited for" "Waiting for another load window, run by pid $holder (1 ahead of this one)" "$OUT"
eq "#1618 and this one runs once it has left" 0 "$RC"
fresh turnstuck
mkdir -p "$LOAD_WINDOW_DIR/queue/turn"
printf 'pr %s\npid %s\nstart %s\njoined %s\n' "$holder" "$holder" "$hstart" "$T0" > "$LOAD_WINDOW_DIR/queue/turn/1"
LOAD_WINDOW_HOLD_SECONDS=20 run --seconds 10 --workers 1 -- bash "$W/report.sh" "$case_dir/r"
says "#1618 a live holder past the bound is passed over" "the window run by pid $holder ran out after 20s, past the 20s any one window may hold it" "$OUT"
eq "#1618 and the window runs" 0 "$RC"
kill -9 "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; BG=""
fresh turndead
mkdir -p "$LOAD_WINDOW_DIR/queue/turn"
printf 'pr 99999999\npid 99999999\nstart x\njoined %s\n' "$T0" > "$LOAD_WINDOW_DIR/queue/turn/1"
run --seconds 10 --workers 1 -- bash "$W/report.sh" "$case_dir/r"
says "#1618 a dead holder is passed over at once" "the window run by pid 99999999 was passed over: its run (pid 99999999) is no longer running" "$OUT"
lacks "#1618 without waiting for it" "Waiting for" "$OUT"

# =================================================================================================
# 10. Every way out stops everything: TERM to the helper mid window, and a SIGKILL that leaves it no
#     chance at all, which the groups' own watchdogs answer.
# =================================================================================================
fresh term
LOAD_WINDOW_SLEEP=sleep LOAD_WINDOW_NOW="" bash "$TOOL" --seconds 120 --workers 1 -- bash "$W/forever.sh" "$case_dir/f" > "$case_dir/out" 2>&1 &
hp=$!; BG="$hp"
if wait_for "[ -s '$case_dir/f.pid' ] && [ -s '$case_dir/f.wgroup' ]"; then ok; else bad "#1618 the TERM case's command started"; fi
kill -TERM "$hp"; wait "$hp"; rc=$?; BG=""
eq "#1618 TERM ends the window with 143" 143 "$rc"
fp="$(cat "$case_dir/f.pid" 2>/dev/null)"; wg="$(cat "$case_dir/f.wgroup" 2>/dev/null)"
if [ -n "$fp" ] && gone "$fp"; then ok; else bad "#1618 after TERM the command is gone (pid '$fp')"; fi
if [ -n "$wg" ] && group_empty "$wg"; then ok; else bad "#1618 after TERM the workers are gone (group '$wg')"; fi
says "#1618 and the end recorded says how" "stopped by signal TERM" "$(record)"
eq "#1618 and the turn was given up" "" "$(ls "$LOAD_WINDOW_DIR/queue/turn" 2>/dev/null | grep -E '^[0-9]+$')"

fresh sigkill
LOAD_WINDOW_SLEEP=sleep LOAD_WINDOW_NOW="" bash "$TOOL" --seconds 1 --workers 1 -- bash "$W/forever.sh" "$case_dir/f" > "$case_dir/out" 2>&1 &
hp=$!; BG="$hp"
if wait_for "[ -s '$case_dir/f.pid' ] && [ -s '$case_dir/f.wgroup' ]"; then ok; else bad "#1618 the SIGKILL case's command started"; fi
kill -9 "$hp"; wait "$hp" 2>/dev/null; BG=""
fp="$(cat "$case_dir/f.pid" 2>/dev/null)"; wg="$(cat "$case_dir/f.wgroup" 2>/dev/null)"
if [ -n "$fp" ] && wait_for "gone $fp"; then ok; else bad "#1618 a helper killed outright still leaves no command behind: its group's watchdog ends it (pid '$fp')"; fi
if [ -n "$wg" ] && wait_for "group_empty $wg"; then ok; else bad "#1618 nor any worker (group '$wg')"; fi

# =================================================================================================
# 11. The sentence the merge helper and the suite pile notice append (lib/load-window.sh).
# =================================================================================================
fresh note
note(){ ( . "$LIB" && load_window_note "$1" ); }
eq "#1618 no record: no sentence" "" "$(note $T0)"
( . "$LIB" && load_window_begin "a" "$T0" $((T0 + 180)) 4242 24 6 "repro of #1620, many words" )
n="$(note $((T0 + 60)))"
says "#1618 a running window is named with its ET times" "A deliberate load window is running on this Mac (tools/load-window.sh, pid 4242, 24 busy and 6 process launching workers, \"repro of #1620, many words\"), from 20:00:00 ET until 20:03:00 ET at the latest" "$n"
( . "$LIB" && load_window_finish "a" $((T0 + 120)) "the command finished (exit 0)" )
n="$(note $((T0 + 300)))"
says "#1618 an ended one is named with its end" "A deliberate load window ran on this Mac from 20:00:00 ET to 20:02:00 ET" "$n"
says "#1618 and how long ago" "ended 3m 00s ago" "$n"
eq "#1618 past the recent span it is not named" "" "$(note $((T0 + 120 + 901)))"
( . "$LIB" && load_window_begin "b" $((T0 + 1000)) $((T0 + 1100)) 4343 1 0 "no end" )
n="$(note $((T0 + 1200)))"
says "#1618 a window whose run recorded no end is taken to have ended at its deadline" "from 20:16:40 ET until 20:18:20 ET (tools/load-window.sh, pid 4343" "$n"
says "#1618 and says why that time" "its run recorded no end" "$n"

# =================================================================================================
# 12. The real process table (positive control): --status, which changes nothing, names a real
#     process running a script called merge-when-ready.sh by its pid.
# =================================================================================================
fresh real
unset SYNC_PS_FIXTURE
mkdir -p "$W/real"; printf 'sleep 600\n' > "$W/real/merge-when-ready.sh"
bash "$W/real/merge-when-ready.sh" & dummy=$!; BG="$dummy"
wait_for "case \"\$(ps -o command= -p $dummy)\" in *merge-when-ready.sh*) true ;; *) false ;; esac" || true
run --status
says "#1618 --status reads the real process table" "a merge-when-ready.sh run (bash $W/real/merge-when-ready.sh)" "$OUT"
child="$(pgrep -P "$dummy")"; kill -9 "$dummy" 2>/dev/null; wait "$dummy" 2>/dev/null; [ -z "$child" ] || kill -9 $child 2>/dev/null; BG=""

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
