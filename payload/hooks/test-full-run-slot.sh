#!/usr/bin/env bash
# test-full-run-slot.sh: whole runs of run-all-tests.sh take one Mac wide slot, so parallel full runs
# queue instead of competing (claude-config#2012).
#
# On 2026-11-01 five builders each ran the full suite at once: load averages of 270 to 410 on 12
# cores, one run finishing 9 of 243 suites in 30 minutes, and test-merge-when-ready.sh stopped at its
# own wall clock by load alone. Every case here runs a COPY of the runner inside a throwaway git
# repository holding one fixture suite, so a "whole run" is a whole run of that repository, and the
# slot's folder is a throwaway one (HOOK_TESTS_SLOT_DIR), never this Mac's real slot.
#
# Waits are on conditions (lib/hang-wait.sh), never fixed sleeps (L290). The cases that would
# otherwise wait out a bound read an injected clock and sleep instead (HOOK_TESTS_SLOT_NOW,
# HOOK_TESTS_SLOT_SLEEP, L524), so they cost no real time.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$DIR/run-all-tests.sh"

# The code under test is the runner and lib/full-run-slot.sh, which the runner sources. The runner
# runs on without the library (failing open), so its absence is refused here by name.
if [ ! -f "$DIR/lib/full-run-slot.sh" ] || [ ! -f "$DIR/lib/merge-turn.sh" ]; then
  echo "FAIL: test-full-run-slot: lib/full-run-slot.sh or lib/merge-turn.sh is missing beside the runner, so the slot cannot be tested."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
if [ ! -f "$DIR/lib/suite-deadline.sh" ]; then
  echo "FAIL: test-full-run-slot: no helper at $DIR/lib/suite-deadline.sh, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
. "$DIR/lib/suite-deadline.sh"
suite_deadline_arm || exit $?
. "$DIR/lib/hang-wait.sh" || {
  echo "FAIL: test-full-run-slot: lib/hang-wait.sh is missing, so this suite's waits have no ceiling."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

pass=0
fail=0
check(){ # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [ "$2" = "ok" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}
has(){ # has <description> <fixed text> <output>
  case "$3" in *"$2"*) check "$1" ok ;; *) check "$1" "no '$2' in: $3" ;; esac
}
lacks(){ # lacks <description> <fixed text> <output>
  case "$3" in *"$2"*) check "$1" "'$2' was said: $3" ;; *) check "$1" ok ;; esac
}

T="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.full-run-slot.XXXXXXXX")" || T=""
case "${T%/}" in
  ''|/|"${HOME%/}") echo "test-full-run-slot: refusing to run: throwaway directory came back as '$T'." >&2; exit 2 ;;
esac
# Every stand in holder writes its pid into one folder, and cleanup reads it there: new_holder is
# called inside $(...), so a list it kept in a variable would be lost on return.
mkdir -p "$T/holders"
cleanup(){
  local f
  for f in "$T"/holders/*; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT

# Every fixture run gets a config folder of its own, so none of them brackets the real ~/.claude.
. "$DIR/lib/fixture-runner-home.sh" && fixture_runner_home "$T/home" || {
  echo "FAIL: test-full-run-slot: could not give the fixture runs a config folder of their own. Refusing to run."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
export CLAUDE_ISSUE_SPOOL_DIR="$T/spool"; mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
export HOOK_TESTS_FLAKY_OUTPUT="$T/flaky"
unset HOOK_TESTS_DEADLINE HOOK_TESTS_DEADLINE_RESERVE HOOK_TESTS_JOB_STARTED HOOK_TESTS_NOW GITHUB_ACTIONS GITHUB_WORKFLOW_REF GITHUB_JOB
unset HOOK_TESTS_SLOT HOOK_TESTS_SLOT_WAIT HOOK_TESTS_SLOT_HOLD HOOK_TESTS_SLOT_POLL HOOK_TESTS_SLOT_SAY_EVERY HOOK_TESTS_SLOT_NOW HOOK_TESTS_SLOT_SLEEP

# The fixture repository: the runner and its libraries copied in, and one suite, all tracked, so the
# copy's own `git rev-parse` finds this repository and a bare run of it is a whole run.
FX="$T/fx"
mkdir -p "$FX/payload/hooks"
cp "$RUNNER" "$FX/payload/hooks/run-all-tests.sh"
cp -R "$DIR/lib" "$FX/payload/hooks/lib"
cat > "$FX/payload/hooks/test-a.sh" <<'SUITE'
#!/usr/bin/env bash
# Marks that it ran. In the race case it also records whether another copy of itself was inside at
# the same moment, waiting up to a bound for the other copy to arrive, so two runs that are NOT
# queued always overlap here however loaded the Mac is.
[ -n "${SLOT_MARK:-}" ] && : > "$SLOT_MARK"
if [ -n "${SLOT_RACE:-}" ]; then
  : > "$SLOT_RACE/arrived.$$"
  if mkdir "$SLOT_RACE/inside" 2>/dev/null; then
    # Queued correctly, the other copy never arrives while this one is inside, so the window runs
    # out (status 1); the other copy arriving inside it is the overlap.
    . "$(dirname "$0")/lib/hang-wait.sh"
    window_wait 3 '[ "$(ls "$SLOT_RACE" | grep -c "^arrived\.")" -ge 2 ]'; ran_out=$?
    [ "$ran_out" = 1 ] || echo OVERLAP >> "$SLOT_RACE/log"
    rm -f "$SLOT_RACE/arrived.$$"
    rmdir "$SLOT_RACE/inside"
  else
    echo OVERLAP >> "$SLOT_RACE/log"
  fi
  echo done >> "$SLOT_RACE/log"
fi
echo "SUITE-RESULT passed=1 failed=0"
SUITE
chmod +x "$FX/payload/hooks/test-a.sh"
git -C "$FX" init -q 2>/dev/null
git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" -c user.email=t@t -c user.name=t commit -q -m fixture >/dev/null 2>&1
FXR="$FX/payload/hooks/run-all-tests.sh"

SLOT="$T/slot"
# A run of the fixture copy as a person types it: a fresh shell (no HOOK_TESTS_RUNNING), not CI.
fx_run(){ # fx_run <output file> [env assignments...] [-- runner args...]
  local out="$1"; shift
  local envs=() args=()
  while [ $# -gt 0 ]; do
    if [ "$1" = "--" ]; then shift; args=("$@"); break; fi
    envs+=("$1"); shift
  done
  env -u HOOK_TESTS_RUNNING -u CI -u HOOK_TESTS_ROOT HOOK_TESTS_TIMINGS= HOOK_TESTS_BUDGET=2 \
    HOOK_TESTS_SLOT_DIR="$SLOT" ${envs[@]+"${envs[@]}"} bash "$FXR" ${args[@]+"${args[@]}"} > "$out" 2>&1
}

# A process that holds the slot, standing in for another builder's full run. Started from a subshell
# that exits at once, so it is not this shell's child: when it dies something else reaps it, and a
# dead holder is gone rather than a zombie that still answers kill -0.
new_holder(){ # new_holder <name> -> its pid, also kept in $T/holders/<name> for cleanup
  ( sleep 900 > /dev/null 2>&1 < /dev/null & printf '%s\n' "$!" > "$T/holders/$1" )
  cat "$T/holders/$1"
}
# A ticket in the slot's queue for pid $1, through the queue's own writer, marked as holding the turn
# since epoch $3 so "held for" has a known value.
hold_slot(){ # hold_slot <pid> <worktree label> <held since>
  ( . "$DIR/lib/merge-turn.sh"
    TURN_PID="$1"; TURN_PID_START=""
    MWR_TURN_DIR="$SLOT" turn_open "full-run"
    turn_join "$2" "$3" || exit 1
    turn_look "$3" 999999 )
}
tickets(){ # the live ticket files in the slot's queue, one per line
  local f
  for f in "$SLOT"/full-run/*; do case "${f##*/}" in ''|*[!0-9]*) ;; *) printf '%s\n' "${f##*/}" ;; esac; done
}
clear_slot(){ rm -rf "$SLOT"; }

# An injected clock: each call prints the epoch in the file and moves it on by 30 seconds, a step
# this suite sets (not measured).
CLOCK="$T/clock"; printf '1000000\n' > "$T/clock.now"
cat > "$CLOCK" <<CLK
#!/usr/bin/env bash
n="\$(cat "$T/clock.now")"; printf '%s\n' "\$(( n + 30 ))" > "$T/clock.now"; printf '%s\n' "\$n"
CLK
chmod +x "$CLOCK"

# ---- 1. a whole run waits for a live holder, says for whom, and refuses at its bound -------------
clear_slot
HP="$(new_holder hp1)"
hold_slot "$HP" "/work/trees/other-builder" 999700 || check "fixture: the holder's ticket was written" "turn_join failed"
# And a second run already waiting behind it, so this run is third in line.
HW="$(new_holder hw1)"
hold_slot "$HW" "/work/trees/second-builder" 999800 || check "fixture: the second waiter's ticket was written" "turn_join failed"
printf '1000000\n' > "$T/clock.now"; rm -f "$T/mark1"
fx_run "$T/out1" HOOK_TESTS_SLOT_NOW="$CLOCK" HOOK_TESTS_SLOT_SLEEP=true HOOK_TESTS_SLOT_WAIT=150 HOOK_TESTS_SLOT_SAY_EVERY=60 SLOT_MARK="$T/mark1"; rc1=$?
o1="$(cat "$T/out1")"
[ "$rc1" -eq 75 ] && check "#2012 a whole run that waited out its bound exits 75, refused rather than run" ok \
  || check "#2012 a whole run that waited out its bound exits 75, refused rather than run" "exit=$rc1 out=$o1"
[ ! -f "$T/mark1" ] && check "#2012 a refused run ran no suite" ok || check "#2012 a refused run ran no suite" "the suite ran: $o1"
has "#2012 the wait is said at once, naming the slot" "waiting for this Mac's full suite slot" "$o1"
has "#2012 the wait names the holder's pid" "pid $HP" "$o1"
has "#2012 the wait names the holder's worktree" "/work/trees/other-builder" "$o1"
has "#2012 the wait says how long the holder has held it" "has held it for 5m, and 1 other run is waiting ahead of this one." "$o1"
has "#2012 a heartbeat says it is still waiting, with the time so far" "still waiting for this Mac's full suite slot, 1m so far" "$o1"
has "#2012 the refusal is plain and names the bound" "REFUSED" "$o1"
has "#2012 the refusal names the way to a focused check that never waits" "never waits for the slot" "$o1"
[ "$(tickets | wc -l | tr -d ' ')" = 2 ] && check "#2012 a refused run leaves its place in the queue, only the two ahead of it remain" ok \
  || check "#2012 a refused run leaves its place in the queue, only the two ahead of it remain" "tickets: $(tickets | tr '\n' ' ')"

# ---- 2. a holder that died frees the slot (L409) -------------------------------------------------
clear_slot
HD="$(new_holder hp2)"
hold_slot "$HD" "/work/trees/crashed" "$(date +%s)"
kill -9 "$HD" 2>/dev/null
hang_wait '! kill -0 "$HD" 2>/dev/null' || check "fixture: the dead holder really ended" "pid $HD still answers"
rm -f "$T/mark2"
fx_run "$T/out2" HOOK_TESTS_SLOT_POLL=0.1 SLOT_MARK="$T/mark2"; rc2=$?
o2="$(cat "$T/out2")"
{ [ "$rc2" -eq 0 ] && [ -f "$T/mark2" ]; } && check "#2012 a holder that died does not hold the slot: the run goes ahead" ok \
  || check "#2012 a holder that died does not hold the slot: the run goes ahead" "exit=$rc2 out=$o2"
has "#2012 passing over a dead holder is said, with its pid" "pid $HD) is no longer running" "$o2"
[ -z "$(tickets)" ] && check "#2012 a finished run gives the slot back" ok || check "#2012 a finished run gives the slot back" "tickets: $(tickets | tr '\n' ' ')"

# ---- 3. a holder that finishes hands the slot on, and the waiter says how long it waited ---------
clear_slot
HR="$(new_holder hp3)"
hold_slot "$HR" "/work/trees/finishing" 999970
cat > "$T/release-sleep" <<REL
#!/usr/bin/env bash
# The holder finishing normally is its ticket leaving the queue, which is what turn_leave does.
for f in "$SLOT"/full-run/*; do case "\${f##*/}" in ''|*[!0-9]*) ;; *) grep -q "^pid $HR\$" "\$f" && rm -f "\$f" "\$f.head" ;; esac; done
REL
chmod +x "$T/release-sleep"
printf '1000000\n' > "$T/clock.now"; rm -f "$T/mark3"
fx_run "$T/out3" HOOK_TESTS_SLOT_NOW="$CLOCK" HOOK_TESTS_SLOT_SLEEP="$T/release-sleep" SLOT_MARK="$T/mark3"; rc3=$?
o3="$(cat "$T/out3")"
{ [ "$rc3" -eq 0 ] && [ -f "$T/mark3" ]; } && check "#2012 once the holder finishes, the waiting run takes the slot and runs" ok \
  || check "#2012 once the holder finishes, the waiting run takes the slot and runs" "exit=$rc3 out=$o3"
has "#2012 the run says it took the slot and how long it waited" "took this Mac's full suite slot after waiting" "$o3"

# ---- 4. two whole runs racing for the slot never overlap (assume it runs twice) ------------------
# The control first (L1): with the slot off, the same two runs DO overlap, so the fixture can see an
# overlap and a clean log below is the slot's doing.
clear_slot
mkdir -p "$T/race0"
fx_run "$T/out4c0" HOOK_TESTS_SLOT=0 SLOT_RACE="$T/race0" &
r0a=$!
fx_run "$T/out4c1" HOOK_TESTS_SLOT=0 SLOT_RACE="$T/race0" &
r0b=$!
wait "$r0a"; wait "$r0b"
grep -q OVERLAP "$T/race0/log" 2>/dev/null && check "#2012 (control) two whole runs with the slot off do overlap in the fixture" ok \
  || check "#2012 (control) two whole runs with the slot off do overlap in the fixture" "log: $(cat "$T/race0/log" 2>/dev/null)"
clear_slot
mkdir -p "$T/race"
fx_run "$T/out4a" HOOK_TESTS_SLOT_POLL=0.1 SLOT_RACE="$T/race" &
ra=$!
fx_run "$T/out4b" HOOK_TESTS_SLOT_POLL=0.1 SLOT_RACE="$T/race" &
rb=$!
wait "$ra"; rca=$?
wait "$rb"; rcb=$?
o4="$(cat "$T/out4a" "$T/out4b")"
{ [ "$rca" -eq 0 ] && [ "$rcb" -eq 0 ]; } && check "#2012 both racing runs finish green" ok \
  || check "#2012 both racing runs finish green" "exits $rca $rcb out=$o4"
[ "$(grep -c '^done$' "$T/race/log" 2>/dev/null)" = 2 ] && check "#2012 both racing runs ran their suite" ok \
  || check "#2012 both racing runs ran their suite" "log: $(cat "$T/race/log" 2>/dev/null)"
grep -q OVERLAP "$T/race/log" 2>/dev/null && check "#2012 two whole runs never run their suites at the same moment" "they overlapped: $o4" \
  || check "#2012 two whole runs never run their suites at the same moment" ok
[ "$(printf '%s\n' "$o4" | grep -c "waiting for this Mac's full suite slot")" -ge 1 ] && check "#2012 the run that lost the race said it was waiting" ok \
  || check "#2012 the run that lost the race said it was waiting" "out=$o4"
[ -z "$(tickets)" ] && check "#2012 both racing runs gave the slot back" ok || check "#2012 both racing runs gave the slot back" "tickets: $(tickets | tr '\n' ' ')"

# ---- 5. focused and nested runs never wait behind a full run -------------------------------------
clear_slot
HF="$(new_holder hp5)"
hold_slot "$HF" "/work/trees/full-run" "$(date +%s)"
# The control (L1): with this holder in place a WHOLE run really is held, so the runs below that go
# ahead do so because they are focused, not because the holder was passed over. A wait of 0 refuses
# on the first look that finds the slot held.
fx_run "$T/out5ctl" HOOK_TESTS_SLOT_WAIT=0; rc5ctl=$?
[ "$rc5ctl" -eq 75 ] && check "#2012 (control) a whole run with this holder in place is held" ok \
  || check "#2012 (control) a whole run with this holder in place is held" "exit=$rc5ctl out=$(cat "$T/out5ctl")"
rm -f "$T/mark5a"
fx_run "$T/out5a" HOOK_TESTS_SLOT_POLL=0.1 HOOK_TESTS_SLOT_WAIT=5 SLOT_MARK="$T/mark5a" -- "$FX/payload/hooks"; rc5a=$?
o5a="$(cat "$T/out5a")"
{ [ "$rc5a" -eq 0 ] && [ -f "$T/mark5a" ]; } && check "#2012 a run naming directories runs at once while a full run holds the slot" ok \
  || check "#2012 a run naming directories runs at once while a full run holds the slot" "exit=$rc5a out=$o5a"
lacks "#2012 a run naming directories does not wait" "waiting for this Mac's full suite slot" "$o5a"
rm -f "$T/mark5b"
fx_run "$T/out5b" HOOK_TESTS_SLOT_POLL=0.1 HOOK_TESTS_SLOT_WAIT=5 CI=true SLOT_MARK="$T/mark5b"; rc5b=$?
o5b="$(cat "$T/out5b")"
{ [ "$rc5b" -eq 0 ] && [ -f "$T/mark5b" ]; } && check "#2012 a whole run under CI, which owns its runner, does not wait" ok \
  || check "#2012 a whole run under CI, which owns its runner, does not wait" "exit=$rc5b out=$o5b"
rm -f "$T/mark5c"
fx_run "$T/out5c" HOOK_TESTS_SLOT_POLL=0.1 HOOK_TESTS_SLOT_WAIT=5 HOOK_TESTS_SLOT=0 SLOT_MARK="$T/mark5c"; rc5c=$?
{ [ "$rc5c" -eq 0 ] && [ -f "$T/mark5c" ]; } && check "#2012 HOOK_TESTS_SLOT=0 turns the slot off for one run" ok \
  || check "#2012 HOOK_TESTS_SLOT=0 turns the slot off for one run" "exit=$rc5c out=$(cat "$T/out5c")"
# A run started from inside the run holding the slot (a suite running the runner on a fixture, with
# the marker wiped) must not queue behind its own ancestor, which would wait until it refused.
clear_slot
hold_slot "$$" "/work/trees/this-suite" "$(date +%s)"
rm -f "$T/mark5d"
fx_run "$T/out5d" HOOK_TESTS_SLOT_POLL=0.1 HOOK_TESTS_SLOT_WAIT=5 SLOT_MARK="$T/mark5d"; rc5d=$?
o5d="$(cat "$T/out5d")"
{ [ "$rc5d" -eq 0 ] && [ -f "$T/mark5d" ]; } && check "#2012 a whole run started beneath the slot's holder runs at once" ok \
  || check "#2012 a whole run started beneath the slot's holder runs at once" "exit=$rc5d out=$o5d"
lacks "#2012 a run beneath the holder does not wait on its own ancestor" "waiting for this Mac's full suite slot" "$o5d"
[ "$(tickets | wc -l | tr -d ' ')" = 1 ] && check "#2012 a run beneath the holder takes no place in the queue" ok \
  || check "#2012 a run beneath the holder takes no place in the queue" "tickets: $(tickets | tr '\n' ' ')"

# ---- 6. a holder past the hold bound is passed over (L523) ---------------------------------------
clear_slot
HS="$(new_holder hp6)"
hold_slot "$HS" "/work/trees/stuck" 999000
printf '1000000\n' > "$T/clock.now"; rm -f "$T/mark6"
fx_run "$T/out6" HOOK_TESTS_SLOT_NOW="$CLOCK" HOOK_TESTS_SLOT_SLEEP=true HOOK_TESTS_SLOT_HOLD=600 SLOT_MARK="$T/mark6"; rc6=$?
o6="$(cat "$T/out6")"
{ [ "$rc6" -eq 0 ] && [ -f "$T/mark6" ]; } && check "#2012 a live holder past HOOK_TESTS_SLOT_HOLD is passed over and the run goes ahead" ok \
  || check "#2012 a live holder past HOOK_TESTS_SLOT_HOLD is passed over and the run goes ahead" "exit=$rc6 out=$o6"
has "#2012 passing over a holder past its bound is said, naming its worktree" "the full run in /work/trees/stuck" "$o6"

# ---- 7. a waiting run stopped by a signal leaves the queue --------------------------------------
clear_slot
HK="$(new_holder hp7)"
# Marked on the real clock, since this run reads the real clock: an injected epoch here reads as a
# holder decades past its bound, and is passed over.
hold_slot "$HK" "/work/trees/long" "$(date +%s)"
# Started directly rather than through fx_run, so $! is the runner itself (env execs it), which is
# what a signal has to reach.
env -u HOOK_TESTS_RUNNING -u CI -u HOOK_TESTS_ROOT HOOK_TESTS_TIMINGS= HOOK_TESTS_BUDGET=2 \
  HOOK_TESTS_SLOT_DIR="$SLOT" HOOK_TESTS_SLOT_POLL=0.1 HOOK_TESTS_SLOT_WAIT=600 bash "$FXR" > "$T/out7" 2>&1 &
rk=$!
hang_wait 'grep -q "waiting for this Mac" "$T/out7" 2>/dev/null' || check "fixture: the run reached its wait" "out=$(cat "$T/out7")"
[ "$(tickets | wc -l | tr -d ' ')" = 2 ] && check "#2012 a waiting run holds a place in the queue" ok \
  || check "#2012 a waiting run holds a place in the queue" "tickets: $(tickets | tr '\n' ' ')"
kill -TERM "$rk" 2>/dev/null; wait "$rk" 2>/dev/null
[ "$(tickets | wc -l | tr -d ' ')" = 1 ] && check "#2012 a waiting run stopped by TERM gives up its place" ok \
  || check "#2012 a waiting run stopped by TERM gives up its place" "tickets: $(tickets | tr '\n' ' ')"

# ---- 8. a slot nobody can write fails open, and says so ------------------------------------------
: > "$T/not-a-dir"; rm -f "$T/mark8"
fx_run "$T/out8" HOOK_TESTS_SLOT_DIR="$T/not-a-dir/slot" SLOT_MARK="$T/mark8"; rc8=$?
o8="$(cat "$T/out8")"
{ [ "$rc8" -eq 0 ] && [ -f "$T/mark8" ]; } && check "#2012 a slot folder that cannot be made does not stop the run" ok \
  || check "#2012 a slot folder that cannot be made does not stop the run" "exit=$rc8 out=$o8"
has "#2012 running without the slot is said" "could not take a place in this Mac's full suite slot" "$o8"

# ---- 9. settings nobody can read are refused, not guessed ----------------------------------------
clear_slot
fx_run "$T/out9" HOOK_TESTS_SLOT_WAIT=soon; rc9=$?
o9="$(cat "$T/out9")"
[ "$rc9" -eq 1 ] && check "#2012 HOOK_TESTS_SLOT_WAIT that is not a number is refused" ok \
  || check "#2012 HOOK_TESTS_SLOT_WAIT that is not a number is refused" "exit=$rc9 out=$o9"
has "#2012 the refusal names the setting" "HOOK_TESTS_SLOT_WAIT='soon'" "$o9"
fx_run "$T/out9b" HOOK_TESTS_SLOT=maybe; rc9b=$?
[ "$rc9b" -eq 1 ] && check "#2012 HOOK_TESTS_SLOT other than 0 or 1 is refused" ok \
  || check "#2012 HOOK_TESTS_SLOT other than 0 or 1 is refused" "exit=$rc9b out=$(cat "$T/out9b")"

# ---- 10. the scanners gate starts its suites itself, never through the runner --------------------
# So a push is never held behind somebody's full run in the slot, and its time budget (150 seconds,
# set in scanners-before-push.sh, not measured) is spent
# only on its own scanners (and on the suite lock, which it already waits for and names).
_sc_run_line="$(grep -E '^_SC_RUN=' "$DIR/scanners-before-push.sh")"
if [ -z "$_sc_run_line" ]; then
  check "#2012 the scanners gate's suite command was found" "no _SC_RUN= line in scanners-before-push.sh"
else
  lacks "#2012 the scanners gate runs each scanner directly, so the full run slot never holds a push" "run-all-tests" "$_sc_run_line"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
