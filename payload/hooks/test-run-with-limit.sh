#!/usr/bin/env bash
# Tests for lib/run-with-limit.sh and the lib/run-with-limit.py behind it: the one time limit an
# agent or a script can RUN, which ends the command's whole process group (claude-config#3578).
#
# What has to hold:
#   - a command inside its limit keeps its exit code and its output, and the runner says nothing;
#   - one past its limit is stopped with everything in its group (TERM, then KILL for what ignores
#     TERM), the run comes back as 124, and one line says what was stopped;
#   - one that ends in time and LEAVES a process running in its group has that process stopped, and
#     the run fails with a code of the runner's own (123), whatever the command's code was;
#   - the runner never signals a number nothing pins: every signal goes to its own child, or to the
#     group that child leads, while the child is still uncollected, and none after the collect.
#     Shown with stand ins for the calls that signal, start and collect. The stand ins send a
#     signal only to a child they saw this process start and have not seen collected, and only
#     while the system itself still shows that child as this process's own; anything else is
#     recorded and never sent;
#   - a caller that ignores SIGCHLD changes none of that: the runner keeps its own children until
#     it collects them, and refuses to start a command on a system that collects them by itself;
#   - a limit that is not a whole number of seconds above zero, or no command, runs nothing;
#   - with python3 missing, a python3 that is not Python, or the program behind the launcher
#     missing, nothing runs and 125 comes back: a command is never run with no limit, and a run
#     with nothing run never reads as a pass;
#   - a runner told to stop by any signal it can catch ends its command's group first, and then
#     ends by that signal itself;
#   - the group it starts is recorded in the session's marker folder before the command starts,
#     and the record is taken away again once the group is known to hold nothing.
#
# NOTHING HERE RUNS A CHANGED COPY OF THE RUNNER. A case stands in for what is AROUND the program
# (the system's answers, the clock, the record step) and never takes a protection out of it.
#
# Judged by state (what came back, what is still running), never by how long a run took (L290).
# Every case ends by checking that nothing it started is still running. A limit is a real clock, so
# a case that needs the fixture to be up before the limit says SUITE-PART-UNMEASURED when a loaded
# machine did not get it there (L411), and the same rule is held with no clock at all by the stand
# in run, whose limit arrives when the fixture says it is ready.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/hang-wait.sh" || { echo "FAIL: lib/hang-wait.sh is missing"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
RUNNER="$DIR/lib/run-with-limit.sh"
PY="$DIR/lib/run-with-limit.py"
READER="$DIR/lib/agent-leftovers.py"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/run-with-limit.XXXXXXXX")" || TMP=""
case "${TMP%/}" in
  ''|/|"${HOME%/}") echo "test-run-with-limit: refusing to run: throwaway directory came back as '$TMP'." >&2; exit 2 ;;
esac
# Every fixture holds only while its case's `hold` file is there, so removing the folder lets go of
# anything a failed case left.
trap 'rm -rf "$TMP"' EXIT

# No case writes into this Mac's real record of a session's shells: the marker folder is the
# suite's own, and a case names a session only where the record is what it measures.
unset CLAUDE_CODE_SESSION_ID
export AGENT_LEFTOVERS_ROOT="$TMP/marks"
mkdir -p "$TMP/marks"

# A fixture's hold has a ceiling, so a process a broken runner left does end. It is three times the
# hang ceiling the suite's own waits take: with the two equal, a fixture, which starts first, ended
# by itself just before the wait for it gave up, and a process the runner had left read as gone
# (seen on 2026-11-27 with the runner's KILL taken out: the check that nothing is left passed).
HANG_TICKS=$((HANG_S * 30))
# A fixture also lets go once this suite's own process has gone, so a suite that is killed before
# its trap runs leaves nothing holding for the length of that ceiling.
export RWL_SUITE_PID=$$

# tree.sh <dir> <ticks> <plain|stubborn|passing> <hold|leave> [code]
# Starts a child, waits until the child has written its process id, writes its own, and then
# either holds beside the child (hold) or prints a line and ends, leaving the child (leave).
#   plain     the child ends at TERM
#   stubborn  the child ignores TERM, set BEFORE it writes its process id, so a child whose id is
#             on disk has outlived every TERM sent since
#   passing   the child ends by itself once the command has written <dir>/leader-done
# The child's output goes nowhere, so it never holds a capture open.
FX="$TMP/tree.sh"
cat > "$FX" <<'SH'
#!/bin/sh
d="$1"; HANG_TICKS="$2"; kind="$3"; then_what="$4"; code="${5:-0}"
sh -c '
  HANG_TICKS="$2"
  [ "$3" = stubborn ] && trap "" TERM
  echo "$$" > "$1/child.tmp" && mv "$1/child.tmp" "$1/child.pid"
  n=0
  while [ -e "$1/hold" ] && kill -0 "$RWL_SUITE_PID" 2>/dev/null && { [ "$3" != passing ] || [ ! -e "$1/leader-done" ]; } && [ "$n" -lt "$HANG_TICKS" ]; do
    sleep 0.1; n=$((n + 1))
  done
' sh "$d" "$HANG_TICKS" "$kind" > /dev/null 2>&1 &
n=0
while [ ! -e "$d/child.pid" ] && [ -e "$d/hold" ] && [ "$n" -lt "$HANG_TICKS" ]; do sleep 0.1; n=$((n + 1)); done
echo "$$" > "$d/leader.tmp" && mv "$d/leader.tmp" "$d/leader.pid"
if [ "$then_what" = leave ]; then
  echo "the command's own output"
  : > "$d/leader-done"
  exit "$code"
fi
n=0
while [ -e "$d/hold" ] && kill -0 "$RWL_SUITE_PID" 2>/dev/null && [ "$n" -lt "$HANG_TICKS" ]; do sleep 0.1; n=$((n + 1)); done
echo "should never be printed"
SH

CASE=""
new_case() { CASE="$TMP/$1"; mkdir -p "$CASE"; : > "$CASE/hold"; }
# left_running <dir>: the process ids the case recorded that never went. Each is waited for, since
# a killed process is a moment in going; one that the runner left holds well past that wait.
left_running() {
  local f p pids="" left=""
  for f in "$1"/*.pid; do
    [ -f "$f" ] || continue
    p="$(cat "$f" 2>/dev/null || true)"
    case "$p" in ''|*[!0-9]*) continue ;; esac
    pids="$pids $p"
  done
  # One wait for all of a case's processes, so a case that left several costs one ceiling.
  hang_wait 'none_alive $pids' 0.05 || for p in $pids; do kill -0 "$p" 2>/dev/null && left="$left $p"; done
  printf '%s' "$left"
}
none_alive() { local q; for q in "$@"; do kill -0 "$q" 2>/dev/null && return 1; done; return 0; }
# end_case <what the case was>: fails when anything the case started is still running, and only
# then lets go of the fixture, so a process the runner left cannot pass by ending late.
end_case() {
  local left
  left="$(left_running "$CASE")"
  rm -f "$CASE/hold"
  check "$1: nothing the case started is still running" "$([ -z "$left" ] && echo ok || echo "still running:$left")"
}
# runner_lines <file>: how many lines of the file are the runner's own. The command's standard
# error is the runner's too, so the file can also hold what the command or its shell said: bash
# reports "Terminated: 15" for a `sleep` that TERM reached a moment before the shell itself. With
# every line counted, the HUP case failed on that line in one run on 2026-11-27 (load 91, the
# second review of claude-config#3833). Only a line that starts with the runner's name is its own.
runner_lines() { grep -c '^run-with-limit: ' "$1" 2> /dev/null || true; }
one_line() { [ "$(runner_lines "$1")" = 1 ]; }
started() { [ -s "$CASE/leader.pid" ] && [ -s "$CASE/child.pid" ]; }

# The count itself, seen to fail before it is trusted to pass (L1), on recorded lines: what that
# run's file held (the shell's line, then the runner's), two lines of the runner's, and none.
mkdir -p "$TMP/count"
printf '%s\n' "$TMP/tree.sh: line 21: 63194 Terminated: 15          sleep 0.1" \
  "run-with-limit: was sent SIGHUP, so its command was stopped: its whole process group (id 63094) ended at TERM: sh $TMP/tree.sh $TMP/told/told-SIGHUP 9000 plain hold" > "$TMP/count/one-beside-a-shell"
printf '%s\n' "run-with-limit: was sent SIGHUP, so its command was stopped: its whole process group (id 63094) ended at TERM: sh $TMP/tree.sh" \
  "run-with-limit: failed inside itself as it finished (RuntimeError: recorded): 300 sh $TMP/tree.sh" > "$TMP/count/two"
printf '%s\n' "$TMP/tree.sh: line 21: 63194 Terminated: 15          sleep 0.1" \
  "sh: a line that only names run-with-limit: further in is not the runner's" > "$TMP/count/none"
check "the count of the runner's lines reads one line of the runner's beside a line of the command's shell as one line" \
  "$(one_line "$TMP/count/one-beside-a-shell" && echo ok || echo "it counted $(runner_lines "$TMP/count/one-beside-a-shell")")"
check "and it fails two lines of the runner's, a file with no line of the runner's, and a file that is not there" \
  "$(! one_line "$TMP/count/two" && ! one_line "$TMP/count/none" && ! one_line "$TMP/count/not-there" && echo ok \
     || echo "two: $(runner_lines "$TMP/count/two"), none: $(runner_lines "$TMP/count/none"), not there: [$(runner_lines "$TMP/count/not-there")]")"

# ---------------------------------------------------------------------------
# Inside the limit: the exit code and both streams as they were, and not a word from the runner.
# ---------------------------------------------------------------------------
new_case intime
bash "$RUNNER" 30 sh -c 'echo out; echo err >&2; exit 3' > "$CASE/out" 2> "$CASE/err"; rc=$?
check "a command inside its limit keeps its own exit code" "$([ "$rc" -eq 3 ] && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
check "and what it printed arrives on the stream it was printed to, with nothing added by the runner" \
  "$([ "$(cat "$CASE/out")" = out ] && [ "$(cat "$CASE/err")" = err ] && echo ok || echo "out [$(cat "$CASE/out")] err [$(cat "$CASE/err")]")"
check "the launcher can be run as a program" "$([ -x "$RUNNER" ] && echo ok || echo "$RUNNER is not executable")"
bash "$RUNNER" 30 sh -c 'kill -KILL $$' > /dev/null 2> "$CASE/err"; rc=$?
check "a command a signal ended inside its limit comes back as 128 plus the signal" "$([ "$rc" -eq 137 ] && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
bash "$RUNNER" 30 "$TMP/no-such-program" > /dev/null 2> "$CASE/err"; rc=$?
check "a command that cannot be started comes back as 127 and says which" \
  "$([ "$rc" -eq 127 ] && grep -q 'no-such-program' "$CASE/err" && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
printf 'exit 5\n' > "$CASE/not-allowed"; chmod 644 "$CASE/not-allowed"
bash "$RUNNER" 30 "$CASE/not-allowed" > /dev/null 2> "$CASE/err"; rc=$?
check "a file that may not be executed comes back as 126 and says which" \
  "$([ "$rc" -eq 126 ] && grep -q 'not-allowed' "$CASE/err" && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
# A file that may be executed and has no interpreter line is a shell script by long custom: a
# shell, env and timeout hand it to sh, so the runner does too (run plainly it comes back as 5).
printf 'exit 5\n' > "$CASE/no-first-line"; chmod 755 "$CASE/no-first-line"
bash "$RUNNER" 30 "$CASE/no-first-line" > /dev/null 2> "$CASE/err"; rc=$?
check "an executable script with no interpreter line is run by sh, as a shell runs it, and keeps its own code" \
  "$([ "$rc" -eq 5 ] && [ ! -s "$CASE/err" ] && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
bash "$RUNNER" > /dev/null 2> "$CASE/err"
check "the usage says the runner is for commands that do not read a terminal" \
  "$(grep -q 'terminal' "$CASE/err" && echo ok || echo "said: $(cat "$CASE/err")")"

# A caller that ignores SIGCHLD (claude-config#3833, M1). The setting is inherited through bash
# into the runner, and on Linux a process with it has its children collected by the system the
# moment they end: the number the runner signals would then be pinned by nothing. The runner puts
# the signal back to its default for itself, so the command's code comes back and a process it
# leaves is still seen and stopped. The command starts with the signal ignored, as its caller had it.
IGNORES_CHLD='import os, signal, sys; signal.signal(signal.SIGCHLD, signal.SIG_IGN); os.execvp(sys.argv[1], sys.argv[1:])'
SEES_CHLD='import signal, sys; sys.exit(3 if signal.getsignal(signal.SIGCHLD) == signal.SIG_IGN else 4)'
python3 -c "$IGNORES_CHLD" "$BASH" "$RUNNER" 30 python3 -c "$SEES_CHLD" > /dev/null 2> "$CASE/err"; rc=$?
check "under a caller that ignores SIGCHLD the command's own code comes back, nothing is said, and the command starts with it ignored" \
  "$([ "$rc" -eq 3 ] && [ ! -s "$CASE/err" ] && echo ok || echo "rc $rc (4: the command saw it at its default), said: $(cat "$CASE/err")")"
rm -f "$CASE/hold"
new_case chld-left
python3 -c "$IGNORES_CHLD" "$BASH" "$RUNNER" 300 sh "$FX" "$CASE" "$HANG_TICKS" plain leave 0 > "$CASE/out" 2> "$CASE/err"; rc=$?
check "under a caller that ignores SIGCHLD a child left running is still seen and stopped, and the run fails with 123" \
  "$([ "$rc" -eq 123 ] && one_line "$CASE/err" && grep -q 'left a process running' "$CASE/err" && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
end_case "a child left running under a caller that ignores SIGCHLD"

# ---------------------------------------------------------------------------
# Past the limit: the command and the child it started are both gone when the runner returns.
# ---------------------------------------------------------------------------
new_case overlimit
bash "$RUNNER" 2 sh "$FX" "$CASE" "$HANG_TICKS" plain hold > "$CASE/out" 2> "$CASE/err"; rc=$?
check "a command past its limit comes back as 124" "$([ "$rc" -eq 124 ] && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
check "and the runner says in one line what it stopped and why" \
  "$(one_line "$CASE/err" && grep -q '2 second limit' "$CASE/err" && grep -q 'tree.sh' "$CASE/err" && echo ok || echo "said: $(cat "$CASE/err")")"
check "and nothing the command would have printed after the limit arrives" \
  "$(! grep -qF 'should never be printed' "$CASE/out" && echo ok || echo "out: $(cat "$CASE/out")")"
if started; then
  end_case "past the limit"
else
  rm -f "$CASE/hold"
  echo "SUITE-PART-UNMEASURED the command's child being gone after the limit: the 2 second limit ran out before the fixture had started its child, which is this machine's load and not the runner"
fi

# A child that ignores TERM is ended by the KILL that follows. Its process id is on disk only if it
# outlived the TERM, so with the id there the runner's line must say KILL was what ended the group.
new_case stubborn
bash "$RUNNER" 2 sh "$FX" "$CASE" "$HANG_TICKS" stubborn hold > "$CASE/out" 2> "$CASE/err"; rc=$?
check "a command past its limit whose child ignores TERM still comes back as 124" "$([ "$rc" -eq 124 ] && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
if started; then
  check "and the runner says the group ended at KILL" "$(one_line "$CASE/err" && grep -q 'ended at KILL' "$CASE/err" && echo ok || echo "said: $(cat "$CASE/err")")"
  end_case "past the limit, a child ignoring TERM"
else
  rm -f "$CASE/hold"
  echo "SUITE-PART-UNMEASURED a child that ignores TERM being gone after the limit: the 2 second limit ran out before the fixture had started its child, which is this machine's load and not the runner"
fi

# ---------------------------------------------------------------------------
# In time, and a process left running in the group: stopped, said, and the run fails with 123.
# Nothing here races a clock: the command ends only after its child has written its process id.
# ---------------------------------------------------------------------------
new_case left
bash "$RUNNER" 300 sh "$FX" "$CASE" "$HANG_TICKS" plain leave 0 > "$CASE/out" 2> "$CASE/err"; rc=$?
check "a command that ends in time with 0 and leaves a child running fails with the runner's own code, 123" \
  "$([ "$rc" -eq 123 ] && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
check "and the runner says in one line that a process was left and stopped" \
  "$(one_line "$CASE/err" && grep -q 'left a process running' "$CASE/err" && grep -q 'exit code 0' "$CASE/err" && echo ok || echo "said: $(cat "$CASE/err")")"
check "and what the command printed before it ended still arrives" \
  "$([ "$(cat "$CASE/out")" = "the command's own output" ] && echo ok || echo "out: $(cat "$CASE/out")")"
check "and the fixture did start its child" "$(started && echo ok || echo "no process id was written")"
end_case "a child left running"

new_case left-stubborn
bash "$RUNNER" 300 sh "$FX" "$CASE" "$HANG_TICKS" stubborn leave 7 > "$CASE/out" 2> "$CASE/err"; rc=$?
check "a command that fails with 7 and leaves a child that ignores TERM comes back as 123, never 7" \
  "$([ "$rc" -eq 123 ] && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
check "and the runner's line names the command's own code and that KILL ended the group" \
  "$(one_line "$CASE/err" && grep -q 'exit code 7' "$CASE/err" && grep -q 'ended at KILL' "$CASE/err" && echo ok || echo "said: $(cat "$CASE/err")")"
check "and that fixture did start its child" "$(started && echo ok || echo "no process id was written")"
end_case "a child left running that ignores TERM"

# ---------------------------------------------------------------------------
# The runner itself told to stop: the group goes with it. A command in a group of its own is out
# of reach of whatever stops the runner's group, so the runner has to carry the stop across.
# ---------------------------------------------------------------------------
new_case told
bash "$RUNNER" 300 sh "$FX" "$CASE" "$HANG_TICKS" plain hold > "$CASE/out" 2> "$CASE/err" &
told_pid=$!
# The wait ends early when the runner has already gone, and the TERM is sent only to a runner this
# shell still lists as its own running job, never to a number read off a variable alone.
told_running() { jobs -pr > "$CASE/jobs" 2> /dev/null; grep -qx "$told_pid" "$CASE/jobs"; }
hang_wait 'started || ! told_running' 0.05
if started && told_running; then
  kill -TERM "$told_pid"
  wait "$told_pid"; rc=$?
  check "a runner sent TERM comes back as 143" "$([ "$rc" -eq 143 ] && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
  check "and says in one line that it was told to stop and what it stopped" \
    "$(one_line "$CASE/err" && grep -q 'SIGTERM' "$CASE/err" && echo ok || echo "said: $(cat "$CASE/err")")"
  end_case "the runner sent TERM"
else
  rm -f "$CASE/hold"
  wait "$told_pid"; rc=$?
  check "a runner in the background was still running its fixture when the suite came to stop it" "the runner came back $rc first, said: $(cat "$CASE/err")"
fi

# ---------------------------------------------------------------------------
# A limit that is not a whole number of seconds above zero, or no command: usage, 125, nothing run.
# ---------------------------------------------------------------------------
new_case refused
for bad in 0 00 abc 1.5 -1 5s '' 86401 99999999999999999999999999; do
  rm -f "$CASE/ran"
  bash "$RUNNER" "$bad" sh -c ': > "$1"' sh "$CASE/ran" > /dev/null 2> "$CASE/err"; rc=$?
  check "a limit of '$bad' is refused with the usage and 125, and nothing runs" \
    "$([ "$rc" -eq 125 ] && [ ! -e "$CASE/ran" ] && grep -q '^usage: ' "$CASE/err" && echo ok || echo "rc $rc, ran: $([ -e "$CASE/ran" ] && echo yes || echo no), said: $(cat "$CASE/err")")"
done
bash "$RUNNER" > /dev/null 2> "$CASE/err"; rc=$?
check "no words at all is refused with the usage and 125" "$([ "$rc" -eq 125 ] && grep -q '^usage: ' "$CASE/err" && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
bash "$RUNNER" 5 > /dev/null 2> "$CASE/err"; rc=$?
check "a limit and no command is refused with the usage and 125" "$([ "$rc" -eq 125 ] && grep -q '^usage: ' "$CASE/err" && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
# The control on all of the above: the same command with a real limit does run (L1), and a leading
# zero that is not zero is that many seconds.
bash "$RUNNER" 05 sh -c ': > "$1"' sh "$CASE/ran" > /dev/null 2> "$CASE/err"; rc=$?
check "and the same command with a limit of 05 does run" "$([ "$rc" -eq 0 ] && [ -e "$CASE/ran" ] && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"

# ---------------------------------------------------------------------------
# What the runner needs is missing: it says so and runs nothing. Never the command with no limit.
# ---------------------------------------------------------------------------
rm -f "$CASE/ran"
mkdir -p "$TMP/no-python"
PATH="$TMP/no-python" "$BASH" "$RUNNER" 30 /bin/sh -c ': > "$1"' sh "$CASE/ran" > /dev/null 2> "$CASE/err"; rc=$?
check "with no python3 on the PATH nothing runs, it comes back as 125 and says python3 is missing" \
  "$([ "$rc" -eq 125 ] && [ ! -e "$CASE/ran" ] && grep -q 'python3' "$CASE/err" && echo ok || echo "rc $rc, ran: $([ -e "$CASE/ran" ] && echo yes || echo no), said: $(cat "$CASE/err")")"
# A python3 that starts and is not Python (a version manager's shim with no python chosen): its
# exit code must never read as the command's. The launcher asks the program one question first and
# hands over only on the program's own answer, so both of these are 125 with nothing run.
REAL_PY="$(command -v python3)"
for code in 0 7; do
  rm -f "$CASE/ran"
  mkdir -p "$TMP/shim-$code"
  printf '#!/bin/sh\nexit %s\n' "$code" > "$TMP/shim-$code/python3"; chmod 755 "$TMP/shim-$code/python3"
  PATH="$TMP/shim-$code:$PATH" "$BASH" "$RUNNER" 30 /bin/sh -c ': > "$1"' sh "$CASE/ran" > /dev/null 2> "$CASE/err"; rc=$?
  check "a python3 that is not Python and exits $code is refused with 125, nothing runs, and one line says it did not answer" \
    "$([ "$rc" -eq 125 ] && [ ! -e "$CASE/ran" ] && one_line "$CASE/err" && grep -q 'did not answer' "$CASE/err" && echo ok || echo "rc $rc, ran: $([ -e "$CASE/ran" ] && echo yes || echo no), said: $(cat "$CASE/err")")"
done
# A python3 that cannot be started at all. Without `shopt -s execfail` and the two lines after the
# launcher's exec, bash would end with 126 or 127 here, which reads as the command's own code.
rm -f "$CASE/ran"
mkdir -p "$TMP/shut-python"
printf '#!/bin/sh\nexit 0\n' > "$TMP/shut-python/python3"; chmod 644 "$TMP/shut-python/python3"
PATH="$TMP/shut-python" "$BASH" "$RUNNER" 30 /bin/sh -c ': > "$1"' sh "$CASE/ran" > /dev/null 2> "$CASE/err"; rc=$?
check "a python3 that may not be executed is refused with 125, never 126, and nothing runs" \
  "$([ "$rc" -eq 125 ] && [ ! -e "$CASE/ran" ] && grep -q 'nothing was run' "$CASE/err" && echo ok || echo "rc $rc, ran: $([ -e "$CASE/ran" ] && echo yes || echo no), said: $(cat "$CASE/err")")"
# The lines after the exec are reached only by a python3 that answered the question and then could
# not be started: this stand in is the real python3 for one start, and takes away its own
# permission to be executed as it ends.
rm -f "$CASE/ran"
mkdir -p "$TMP/once-python"
printf '#!/bin/sh\n"%s" "$@"\nrc=$?\nchmod 644 "$0"\nexit "$rc"\n' "$REAL_PY" > "$TMP/once-python/python3"; chmod 755 "$TMP/once-python/python3"
PATH="$TMP/once-python:$PATH" "$BASH" "$RUNNER" 30 /bin/sh -c ': > "$1"' sh "$CASE/ran" > /dev/null 2> "$CASE/err"; rc=$?
check "a python3 that answers and then cannot be started is 125 with the launcher's own line, never 126, and nothing runs" \
  "$([ "$rc" -eq 125 ] && [ ! -e "$CASE/ran" ] && grep -q 'could not be started' "$CASE/err" && echo ok || echo "rc $rc, ran: $([ -e "$CASE/ran" ] && echo yes || echo no), said: $(cat "$CASE/err")")"
# The control on the three above (L1): through a stand in that IS the real python3 the command runs.
rm -f "$CASE/ran"
mkdir -p "$TMP/real-python"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_PY" > "$TMP/real-python/python3"; chmod 755 "$TMP/real-python/python3"
PATH="$TMP/real-python:$PATH" "$BASH" "$RUNNER" 30 /bin/sh -c ': > "$1"; exit 3' sh "$CASE/ran" > /dev/null 2> "$CASE/err"; rc=$?
check "and through a stand in that is the real python3 the command runs and keeps its code" \
  "$([ "$rc" -eq 3 ] && [ -e "$CASE/ran" ] && [ ! -s "$CASE/err" ] && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
# The words a caller might type that look like the launcher's question run nothing and are no pass.
"$BASH" "$RUNNER" --prove anything > "$CASE/out" 2> "$CASE/err"; rc=$?
check "the launcher's own question, typed as the words of a run, comes back as 125" "$([ "$rc" -eq 125 ] && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
# Installed as every suite installs a helper (#2147). The launcher starts its program by path, which
# the installer follows only for a helper that is named, so this folder lacks the program on purpose.
python3 "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$TMP/lone" run-with-limit.sh > /dev/null \
  || check "the launcher could be installed by itself, without the program behind it" "the install refused"
rm -f "$CASE/ran"
bash "$TMP/lone/run-with-limit.sh" 30 sh -c ': > "$1"' sh "$CASE/ran" > /dev/null 2> "$CASE/err"; rc=$?
check "with the program behind the launcher missing nothing runs, it comes back as 125 and names the file" \
  "$([ "$rc" -eq 125 ] && [ ! -e "$CASE/ran" ] && grep -q 'run-with-limit.py' "$CASE/err" && echo ok || echo "rc $rc, ran: $([ -e "$CASE/ran" ] && echo yes || echo no), said: $(cat "$CASE/err")")"
rm -f "$CASE/hold"

# ---------------------------------------------------------------------------
# The group record (claude-config#3561's seam, bash-shell-mark.sh): an empty file named for the
# group's id in the folder the reader itself names, there before the command's first statement.
# ---------------------------------------------------------------------------
new_case record
MARKS="$(python3 "$READER" dir sess-one 2> /dev/null)"
check "the reader names the marker folder under the suite's own root" "$([ "$MARKS" = "$TMP/marks/sess-one" ] && echo ok || echo "it said [$MARKS]")"
mkdir -p "$TMP/marks/sess-one"
# A file that is not the runner's, as a recorded shell leaves one: it must still be there afterwards.
: > "$TMP/marks/sess-one/1"
# The command is its group's leader, so its own process id is the group's id. It looks for the
# record itself, since the runner takes the record away again once the group holds nothing.
CLAUDE_CODE_SESSION_ID=sess-one bash "$RUNNER" 30 sh -c 'echo "$$" > "$1/leader.pid"; [ -f "$2/$$" ] && [ ! -s "$2/$$" ] && : > "$1/there-first"; exit 0' sh "$CASE" "$TMP/marks/sess-one" > /dev/null 2> "$CASE/err"; rc=$?
gid="$(cat "$CASE/leader.pid" 2> /dev/null || true)"
check "a run inside a recorded session has an empty file named for its group's id in that session's marker folder, there before the command's first statement runs" \
  "$([ "$rc" -eq 0 ] && [ -n "$gid" ] && [ -e "$CASE/there-first" ] && echo ok || echo "rc $rc, group [$gid], the command did not find it, folder holds: $(ls "$TMP/marks/sess-one" 2>&1 | tr '\n' ' '), said: $(cat "$CASE/err")")"
check "and once the command has ended and its group holds nothing, the runner has taken its own file away and left the other" \
  "$([ -n "$gid" ] && [ ! -e "$TMP/marks/sess-one/$gid" ] && [ -e "$TMP/marks/sess-one/1" ] && echo ok || echo "group [$gid], folder holds: $(ls "$TMP/marks/sess-one" 2>&1 | tr '\n' ' ')")"
check "and the runner says nothing about it" "$([ ! -s "$CASE/err" ] && echo ok || echo "said: $(cat "$CASE/err")")"
rm -f "$CASE/hold"
new_case record-left
CLAUDE_CODE_SESSION_ID=sess-one bash "$RUNNER" 300 sh "$FX" "$CASE" "$HANG_TICKS" plain leave 0 > "$CASE/out" 2> "$CASE/err"; rc=$?
gid="$(cat "$CASE/leader.pid" 2> /dev/null || true)"
check "a run that had to stop what its command left takes its file away too, once the group has ended" \
  "$([ "$rc" -eq 123 ] && [ -n "$gid" ] && [ ! -e "$TMP/marks/sess-one/$gid" ] && [ -e "$TMP/marks/sess-one/1" ] && echo ok || echo "rc $rc, group [$gid], folder holds: $(ls "$TMP/marks/sess-one" 2>&1 | tr '\n' ' '), said: $(cat "$CASE/err")")"
end_case "a recorded run that left a child"
new_case record
# A session whose shells are not recorded has no folder (it began before bash-shell-mark.sh was
# installed). The reader says so itself, once a session, and the runner must not make the folder:
# its being there is what tells the reader the session's shells are recorded.
rm -f "$CASE/ran"
CLAUDE_CODE_SESSION_ID=sess-two bash "$RUNNER" 30 sh -c ': > "$1"' sh "$CASE/ran" > /dev/null 2> "$CASE/err"; rc=$?
check "a run in a session with no marker folder runs the command, makes no folder and says nothing" \
  "$([ "$rc" -eq 0 ] && [ -e "$CASE/ran" ] && [ ! -e "$TMP/marks/sess-two" ] && [ ! -s "$CASE/err" ] && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
# A record that should have been made and could not be is said, in one line, and the limit is kept.
rm -f "$CASE/ran"
CLAUDE_CODE_SESSION_ID='not/a name' bash "$RUNNER" 30 sh -c ': > "$1"; exit 3' sh "$CASE/ran" > /dev/null 2> "$CASE/err"; rc=$?
check "a session id the reader will not name a folder for is said in one line, and the command still runs under its limit" \
  "$([ "$rc" -eq 3 ] && [ -e "$CASE/ran" ] && one_line "$CASE/err" && grep -q 'not recorded' "$CASE/err" && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
if [ "$(id -u)" -eq 0 ]; then
  echo "SUITE-PART-UNMEASURED a marker folder the runner cannot write: the suite is running as root, which can write any folder"
else
  mkdir -p "$TMP/marks/sess-shut"; chmod 500 "$TMP/marks/sess-shut"
  rm -f "$CASE/ran"
  CLAUDE_CODE_SESSION_ID=sess-shut bash "$RUNNER" 30 sh -c ': > "$1"; exit 3' sh "$CASE/ran" > /dev/null 2> "$CASE/err"; rc=$?
  check "a marker folder that cannot be written is said in one line, and the command still runs under its limit" \
    "$([ "$rc" -eq 3 ] && [ -e "$CASE/ran" ] && one_line "$CASE/err" && grep -q 'not recorded' "$CASE/err" && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
  chmod 700 "$TMP/marks/sess-shut"
fi
rm -f "$CASE/hold"

# ---------------------------------------------------------------------------
# THE SIGNAL RULE, with stand ins for the calls that signal and collect. The program is loaded and
# run in this process with os.fork, os.killpg, os.kill and every collecting call replaced by
# recorders. A recorder sends a signal only to a child it saw this process start and has not seen
# collected, while SIGCHLD is not ignored and (where python can look without collecting) the
# system still shows the child as this process's own. Anything else is recorded and NOT sent, so a
# broken runner is caught without a signal ever going to a number nothing pins. The limit here is
# no real clock: it arrives when the fixture has written its process ids, so the order is the same
# on any machine.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/drive"
# Its lines go to a file, never through a command substitution, which bash 3.2 cannot parse around
# a heredoc that holds a quote (claude-config#1690).
python3 - "$PY" "$FX" "$TMP/drive" "$HANG_TICKS" > "$TMP/drive.out" 2> "$TMP/drive.err" <<'EOF'
import importlib.util, os, signal, sys, time
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("run_with_limit", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
fx, work, ticks = sys.argv[2], sys.argv[3], sys.argv[4]
ceiling = float(ticks) / 30         # the hang ceiling the suite's own waits take, in seconds

def result(name, cond, detail=""):
    print(("PASS\t" + name) if cond else "FAIL\t%s\t%s" % (name, " ".join(str(detail).split())))
    sys.stdout.flush()

log, said = [], []
real = dict(killpg=os.killpg, kill=os.kill, waitpid=os.waitpid, fork=os.fork, pipe=os.pipe,
            setpgid=os.setpgid, waitid=getattr(os, "waitid", None), platform=sys.platform)
own = os.getpgrp()
# Stand ins for a system that answers differently, each set by the one case that needs it.
refuse, swallow = {}, set()

def mine(n):
    """Whether n is this process's own child, started here and not collected: the only number a
    signal may really go to. The record must say so, SIGCHLD must not be ignored (a system may
    then collect a child by itself), and where this python can look without collecting, the
    system must still show the child as this process's own."""
    if ("fork", n) not in log or ("collect", n) in log:
        return False
    if signal.getsignal(signal.SIGCHLD) == signal.SIG_IGN:
        return False
    if real["waitid"]:
        try:
            real["waitid"](os.P_PID, n, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        except OSError:
            return False
    return True

def fork():
    pid = real["fork"]()
    if pid:
        log.append(("fork", pid))
    return pid

def killpg(pgid, sig):
    sig = int(sig)
    if pgid == own and sig == 0:
        # The runner's look at its own group, which this process is in: nothing is sent.
        log.append(("own", pgid, 0))
        if "own" in refuse:
            raise PermissionError(1, "Operation not permitted")
        return real["killpg"](pgid, 0)
    if not mine(pgid):
        log.append(("withheld", pgid, sig))       # recorded, never sent
        raise ProcessLookupError(3, "No such process")
    log.append(("signal", pgid, sig))
    if "signals" in refuse:
        raise PermissionError(1, "Operation not permitted")
    if sig in swallow:
        return None
    return real["killpg"](pgid, sig)

def kill(pid, sig):
    sig = int(sig)
    if not mine(pid):
        log.append(("withheld", pid, sig))        # recorded, never sent
        raise ProcessLookupError(3, "No such process")
    log.append(("kill", pid, sig))
    if "signals" in refuse:
        raise PermissionError(1, "Operation not permitted")
    return real["kill"](pid, sig)

def waitpid(pid, options):
    log.append(("collect", pid))
    got = real["waitpid"](pid, options)
    if refuse.pop("collect", None):
        # A system that had collected the child by itself: the caller is told there is no child.
        raise ChildProcessError(10, "No child processes")
    return got

os.fork, os.killpg, os.kill, os.waitpid = fork, killpg, kill, waitpid
for name in ("wait", "wait3", "wait4"):
    if hasattr(os, name):
        def other(*args, _name=name, _real=getattr(os, name)):
            log.append(("collect", _name))
            return _real(*args)
        setattr(os, name, other)
if real["waitid"]:
    def waitid(idtype, ident, options):
        if not options & os.WNOWAIT:
            log.append(("collect", ident))
        if "waitid" in refuse and ("fork", ident) in log:
            raise ChildProcessError(10, "No child processes")
        return real["waitid"](idtype, ident, options)
    os.waitid = waitid
driver = os.getpid()
def note(text):
    """What the runner says. In this process it is kept for the case to read. In a child the
    runner started (the process that waits to become the command) it goes to this run's standard
    error, which the suite shows beside a failure: a child that failed before it became the
    command would otherwise say so only into its own copy of the list, and nobody would read it."""
    if os.getpid() == driver:
        said.append(text)
    else:
        try:
            real_write(2, ("the runner's child %d said: %s\n" % (os.getpid(), text)).encode("utf-8", "replace"))
        except OSError:
            pass
real_write = os.write
m.say = note
kept = dict(record=m.record, pick=m.pick, now=m.now, GRACE=m.GRACE, SETTLE=m.SETTLE, GONE=m.GONE)

def restore():
    """Every stand in a case set is taken out again, whatever the case did."""
    refuse.clear()
    swallow.clear()
    os.pipe, os.setpgid, sys.platform = real["pipe"], real["setpgid"], real["platform"]
    for name, value in kept.items():
        setattr(m, name, value)

def reap():
    """Really collect what a case left uncollected on purpose, so an ended process waiting to be
    collected is not read as one still running. Looks until the hang ceiling, never for ever."""
    for e in list(log):
        if e[0] != "fork" or ("collect", e[1]) in log:
            continue
        end = time.monotonic() + ceiling
        while time.monotonic() < end:
            try:
                if real["waitpid"](e[1], os.WNOHANG)[0]:
                    break
            except OSError:
                break
            time.sleep(0.05)
        log.append(("collect", e[1]))

def attempt(name, case):
    """Run one case. A case the program cannot even run (a call it does not have) is a failure
    named for the case, and the run goes on to the next."""
    try:
        case()
    except BaseException as e:
        result(name, False, "the case stopped: %s: %s" % (type(e).__name__, e))
    finally:
        restore()
        reap()

def faults(entries, uncollected=0):
    """What a record shows the runner did against the rule. Empty when it was kept. A signal is
    within the rule only when it went to a child this process had started and not yet collected
    (to the child itself, or to the group of that number)."""
    out = []
    forks = [e[1] for e in entries if e[0] == "fork"]
    held, collects = set(), {}
    for e in entries:
        if e[0] == "fork":
            held.add(e[1])
        elif e[0] == "collect":
            if e[1] not in forks:
                out.append("it collected %s, which it was not seen to start" % (e[1],))
                continue
            collects[e[1]] = collects.get(e[1], 0) + 1
            held.discard(e[1])
        elif e[0] in ("signal", "kill") and e[1] not in held:
            out.append("signal %d to %d, which was not its own uncollected child then" % (e[2], e[1]))
        elif e[0] == "withheld":
            out.append("signal %d asked for %d, which was not its own uncollected child (never sent)" % (e[2], e[1]))
    out += ["it collected %d %d times" % (p, n) for p, n in sorted(collects.items()) if n > 1]
    left = [p for p in forks if p not in collects]
    if len(left) != uncollected:
        out.append("it left %d of the %d it started uncollected, and %d was expected" % (len(left), len(forks), uncollected))
    return out

def sent(sig):
    return any(e[0] == "signal" and e[2] == sig for e in log)

def signalled():
    return [e for e in log if e[0] in ("signal", "kill", "withheld")]

# The judge itself, seen to find each fault before it is trusted to find none (L1).
result("the judge of a record finds a signal asked for after the collect", faults([("fork", 5), ("signal", 5, 15), ("collect", 5), ("withheld", 5, 9)]))
result("the judge finds a signal that was sent after the collect", faults([("fork", 5), ("collect", 5), ("signal", 5, 9)]))
result("the judge finds a signal to a group that is not the child's", faults([("fork", 5), ("signal", 7, 15), ("collect", 5)]))
result("the judge finds a second collect, and none", faults([("fork", 5), ("collect", 5), ("collect", 5)]) and faults([("fork", 5), ("signal", 5, 0)]))
result("the judge finds a signal to a process that is not its own child", faults([("fork", 5), ("kill", 7, 15), ("collect", 5)]))
result("the judge finds a collect of a process it was not seen to start", faults([("fork", 5), ("collect", 5), ("collect", "wait")]))
result("the judge passes a record that keeps the rule",
       not faults([("own", own, 0), ("fork", 4), ("collect", 4), ("fork", 5), ("signal", 5, 0), ("signal", 5, 15), ("kill", 5, 15), ("collect", 5)]))

# The recorder itself: a number this process never started is sent nothing, whatever is asked.
del log[:]
try:
    os.killpg(1, 0)
    reached = True
except ProcessLookupError:
    reached = False
try:
    os.kill(1, 0)
    reached = True
except ProcessLookupError:
    pass
result("the stand ins send nothing to a number this process did not start, and record that it was asked",
       not reached and log == [("withheld", 1, 0), ("withheld", 1, 0)], log)

def case_dir(name):
    d = os.path.join(work, name)
    os.makedirs(d)
    open(os.path.join(d, "hold"), "w").close()
    return d

def let_go(d):
    """Take a case's hold away: the fixture ends by itself, where a case left it running on purpose."""
    os.remove(os.path.join(d, "hold"))

def run(args):
    del log[:]
    del said[:]
    return m.main(args)

def limit_when_ready(d):
    """A clock that stands still until the fixture has written its process ids, and then is far
    past any limit and moving at the real rate."""
    ready, base = os.path.join(d, "leader.pid"), time.monotonic()
    return lambda: time.monotonic() + 1e6 if os.path.exists(ready) else base

def touches(path):
    return ["sh", "-c", ': > "$1"', "sh", path]

def scenarios(tag):
    rc = run(["30", "sh", "-c", "exit 3"])
    result(tag + "in time and nothing left: the command's own code", rc == 3, rc)
    result(tag + "in time and nothing left: every child collected once, and no signal after its collect", not faults(log), faults(log))
    result(tag + "in time and nothing left: no TERM, no KILL and not a word", not sent(15) and not sent(9) and not said, (log, said))

    d = case_dir(tag.strip(": ").replace(" ", "-").replace(",", "") + "-limit")
    m.now = limit_when_ready(d)
    rc = run(["1", "sh", fx, d, ticks, "plain", "hold"])
    m.now = time.monotonic
    result(tag + "past the limit: 124", rc == 124, rc)
    result(tag + "past the limit: TERM went to the group before its collect, and no signal after it", sent(15) and not faults(log), (faults(log), log))
    result(tag + "past the limit: one line names the limit", len(said) == 1 and "1 second limit" in said[0], said)
    # A command still in its own group is ended with that group. Nothing goes to it by its own
    # process id, which is kept for a command that has left the group (the case further down).
    result(tag + "past the limit: nothing was sent to the command by its own process id, and the line says its whole group ended",
           not [e for e in log if e[0] == "kill"] and len(said) == 1 and "its whole process group" in said[0], (log, said))

own_pick = m.pick
scenarios("stand in: ")

d = case_dir("left")
rc = run(["300", "sh", fx, d, ticks, "plain", "leave", "0"])
result("stand in: a child left running: 123", rc == 123, rc)
result("stand in: a child left running: TERM went to the group before its collect, and no signal after it", sent(15) and not faults(log), (faults(log), log))

d = case_dir("left-stubborn")
m.GRACE = 0.3
rc = run(["300", "sh", fx, d, ticks, "stubborn", "leave", "7"])
restore()
result("stand in: a child left running that ignores TERM: 123", rc == 123, rc)
result("stand in: a child left running that ignores TERM: TERM, then KILL, then its collect, and no signal after it",
       sent(15) and sent(9) and not faults(log), (faults(log), log))
result("stand in: a child left running that ignores TERM: the line says the group ended at KILL", len(said) == 1 and "ended at KILL" in said[0], said)

# What a command leaves is given a moment to end by itself (a writer finishing what it was piped)
# before it counts as left running. Here the moment is made as long as the hang ceiling, so the
# case asserts the rule and not this machine's speed.
d = case_dir("passing")
result("the moment a command's leftovers are given to end by themselves is at least a second as shipped", m.SETTLE >= 1.0, m.SETTLE)
m.SETTLE = ceiling
rc = run(["300", "sh", fx, d, ticks, "passing", "leave", "4"])
restore()
result("stand in: a child that ends by itself just after the command: the command's own code, 4", rc == 4, (rc, said))
result("stand in: a child that ends by itself just after the command: no TERM, no KILL, not a word, every child collected once",
       not sent(15) and not sent(9) and not said and not faults(log), (faults(log), log, said))

# A fault inside the runner BEFORE it has let the command go (here in the record step) must not
# start the command: the group is sent KILL while the child still pins it, and the run is 125.
def fault_before():
    d = case_dir("fault")
    def broken(*args):
        raise RuntimeError("the stand in fault")
    m.record = broken
    rc = run(["300"] + touches(os.path.join(d, "ran")))
    result("stand in: a fault inside the runner before the command is let go: 125, and the command never ran", rc == 125 and not os.path.exists(os.path.join(d, "ran")), rc)
    # The child is left uncollected there (a collect could wait on it for ever), so it pins its
    # number until the runner has gone.
    result("stand in: a fault inside the runner before the command is let go: KILL went to the group while the child pinned it, and the child was not collected",
           sent(9) and not faults(log, 1), (faults(log, 1), log))
    result("stand in: a fault inside the runner before the command is let go: one line says so", len(said) == 1 and "stand in fault" in said[0], said)
attempt("stand in: a fault inside the runner before the command is let go", fault_before)

# A fault AFTER the command has started (here the watch fails once the fixture is up): the command
# and what it started must not run on with no limit. The suite then checks nothing is left.
def fault_after():
    d = case_dir("fault-late")
    ready = os.path.join(d, "child.pid")
    picked = own_pick()
    class Faulty(picked[0]):
        def wait(self, seconds, heed=True):
            end = time.monotonic() + ceiling
            while not os.path.exists(ready) and time.monotonic() < end:
                time.sleep(0.05)
            raise RuntimeError("the stand in fault, after the start")
    m.pick = lambda: (Faulty, picked[1])
    rc = run(["300", "sh", fx, d, ticks, "plain", "hold"])
    result("stand in: a fault inside the runner after the command has started: 125, and KILL went to the group while the child pinned it",
           rc == 125 and os.path.exists(ready) and sent(9) and not faults(log, 1), (rc, faults(log, 1), log))
    result("stand in: a fault inside the runner after the command has started: one line says the group was sent KILL",
           len(said) == 1 and "after the start" in said[0] and "was sent KILL" in said[0], said)
attempt("stand in: a fault inside the runner after the command has started", fault_after)

# A fault before anything was started (here the pipe the child waits on cannot be made) is 125 in
# words, never python's own exit code 1, which would read as the command's.
def fault_first():
    d = case_dir("fault-first")
    def no_pipe():
        raise OSError(24, "Too many open files")
    os.pipe = no_pipe
    rc = run(["300"] + touches(os.path.join(d, "ran")))
    result("stand in: a fault before anything is started: 125 in one line that says nothing was run, no signal, and the command never ran",
           rc == 125 and not os.path.exists(os.path.join(d, "ran")) and len(said) == 1 and "nothing was run" in said[0] and not signalled() and not faults(log),
           (rc, said, log))
    let_go(d)
attempt("stand in: a fault before anything is started", fault_first)

# THE GUARD ITSELF (R4). A child of this process, collected through the runner's own class: a
# signal asked for afterwards is refused in the class, and the system is never asked.
def guard():
    del log[:]
    pid = os.fork()
    if pid == 0:
        os._exit(0)
    g = m.Group(pid)
    g.collect()
    refused = []
    for ask in (lambda: g.send(0), lambda: g.send(15), lambda: g.send_command(15)):
        try:
            ask()
            refused.append(False)
        except RuntimeError:
            refused.append(True)
    result("the runner's class refuses a signal to the group and to the command once the command is collected, and asks the system for none",
           refused == [True, True, True] and not signalled(), (refused, log))
    result("and says the child is no longer pinned", g.pinned() is False, g.pinned())
attempt("the runner's class refuses a signal after the collect", guard)

# THE GUARD AGAIN (S4 of the second review of #3833). The look that words the line for a suspended
# command is told "no such child" as any other look is. From that answer on nothing pins the
# number, so the class must refuse a signal: the look may not throw the answer away. Only signal
# 0 is asked for here, so a class that did not refuse sends nothing that ends anything.
def lost_at_a_look():
    if not real["waitid"] or not hasattr(os, "WSTOPPED"):
        print("SUITE-PART-UNMEASURED the class refusing a signal after its look for a suspended command was told there is no such child: this python3 (%s) has no os.waitid, so the runner makes no such look" % sys.version.split()[0])
        return
    del log[:]
    pid = os.fork()
    if pid == 0:
        os._exit(0)
    g = m.Group(pid)
    refuse["waitid"] = True
    look = g.suspended()
    refused = []
    for ask in (lambda: g.send(0), lambda: g.send_command(0)):
        try:
            ask()
            refused.append(False)
        except RuntimeError:
            refused.append(True)
    result("the runner's class refuses a signal once its look for a suspended command was told the command is no longer its child, and asks the system for none",
           look is None and refused == [True, True] and not signalled() and g.pinned() is False, (look, refused, log))
attempt("the runner's class refuses a signal after a look that was told there is no such child", lost_at_a_look)

# The same answer met in a run, at the limit: from the moment the limit arrives every look at the
# command is told there is no such child, and the first look the runner makes then is the one for
# a suspended command. Nothing may be signalled after it: 125, and the line says so. The fixture
# is left running on purpose and let go here.
def lost_at_the_limit():
    if not real["waitid"] or not hasattr(os, "WSTOPPED"):
        print("SUITE-PART-UNMEASURED a command the system collected from under the runner as its limit arrived: this python3 (%s) has no os.waitid, so the runner makes no such look" % sys.version.split()[0])
        return
    d = case_dir("lost-at-limit")
    ready, base = os.path.join(d, "leader.pid"), time.monotonic()
    def clock():
        if not os.path.exists(ready):
            return base
        refuse["waitid"] = True
        return time.monotonic() + 1e6
    m.now = clock
    m.GRACE = 0.3
    m.GONE = 0.5
    try:
        rc = run(["1", "sh", fx, d, ticks, "plain", "hold"])
        result("stand in: a command the system collected from under the runner as its limit arrived: 125, no signal of any kind asked for, and one line says nothing was signalled",
               rc == 125 and not signalled() and len(said) == 1 and "nothing was signalled" in said[0] and not faults(log, 1), (rc, said, faults(log, 1), log))
    finally:
        refuse.clear()
        let_go(d)
attempt("stand in: a command the system collected from under the runner as its limit arrived", lost_at_the_limit)

# A CALLER THAT IGNORES SIGCHLD (M1). This process ignores it, as the runner would inherit it. The
# stand ins send nothing while it is ignored, so a runner that left it so is caught with no signal
# sent. The runner must have it at its default from before it starts anything.
def ignored_chld():
    old = signal.signal(signal.SIGCHLD, signal.SIG_IGN)
    seen = {}
    def looks(folder, pgid):
        seen["at the record"] = signal.getsignal(signal.SIGCHLD)
    m.record = looks
    try:
        rc = run(["30", sys.executable, "-c", "import signal, sys; sys.exit(3 if signal.getsignal(signal.SIGCHLD) == signal.SIG_IGN else 4)"])
    finally:
        signal.signal(signal.SIGCHLD, old if old is not None else signal.SIG_DFL)
    result("stand in: with SIGCHLD ignored by its caller the runner has it at its default before the command is let go",
           seen.get("at the record") == signal.SIG_DFL, seen)
    result("stand in: with SIGCHLD ignored by its caller: the command's own code, every child collected once, no signal withheld, not a word, and the command starts with it ignored",
           rc == 3 and not faults(log) and not said, (rc, faults(log), said))
attempt("stand in: with SIGCHLD ignored by its caller", ignored_chld)

# A system that collects the runner's children by itself (the stand in tells the runner's first
# collect that there is no child): nothing there pins a number, so the runner refuses BEFORE it
# starts the command.
def collects_by_itself():
    d = case_dir("self-collecting")
    refuse["collect"] = True
    rc = run(["300"] + touches(os.path.join(d, "ran")))
    result("stand in: a system that collects the runner's children by itself: 125 before the command is started, one line, and no signal",
           rc == 125 and not os.path.exists(os.path.join(d, "ran")) and len(said) == 1 and "nothing was run" in said[0] and not signalled(),
           (rc, os.path.exists(os.path.join(d, "ran")), said, log))
    let_go(d)
attempt("stand in: a system that collects the runner's children by itself", collects_by_itself)

# The command collected from under the runner while it runs (the stand in answers every look at
# the child as Linux does once the system has collected it). The runner must signal NOTHING from
# then on: the number is no longer pinned.
def collected_under():
    picked = own_pick()
    if isinstance(picked, str) or not real["waitid"]:
        print("SUITE-PART-UNMEASURED a command the system collected from under the runner: this python3 (%s) has no os.waitid to stand in for" % sys.version.split()[0])
        return
    m.pick = lambda: (m.WaitidWatch, picked[1])
    refuse["waitid"] = True
    rc = run(["300", "sh", "-c", "exit 0"])
    result("stand in: a command the system collected from under the runner: 125 and no signal of any kind asked for",
           rc == 125 and not signalled(), (rc, log))
    result("stand in: a command the system collected from under the runner: one line says nothing was signalled",
           len(said) == 1 and "nothing was signalled" in said[0], said)
attempt("stand in: a command the system collected from under the runner", collected_under)

# TWO CALLS THAT MEET. The runner and the process that waits to become the command both ask the
# system to make that process the leader of a new group, at the same moment, and macOS now and
# then refuses one of the two (EPERM). Measured on 2026-11-27 on the personal MacBook (macOS
# 26.6.2, python 3.14.4) at loads of 20 to 83, 13000 children in two runs of a probe that makes
# only those two calls: the child's own call was refused 10 times and the parent's 10 times, never
# both, and every child led its own group by the time its parent let it go (one of the ten did not
# yet when its own call came back). Why macOS refuses was not found. A runner that took the
# child's refusal as the end ran nothing and came back 125: 1 of 100 runs through the launcher
# that day, whose line named the refusal. One stand in run of this suite the same day came back
# 125 with nothing said by the runner, and its child's words were not kept, so that one is read
# as the same fault and was not seen to be. The stand ins refuse what the system refused. The
# command writes down whether it leads its group.
LEADS = "import os, sys; open(sys.argv[1], 'w').write('leads' if os.getpgrp() == os.getpid() else 'does not lead'); sys.exit(5)"
def wrote(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return "nothing written"

def child_said():
    """The lines the last process the runner started said on this run's standard error (note,
    above, sends a child's words there, and the file is the one beside the work folder)."""
    started = [e[1] for e in log if e[0] == "fork"]
    return [line for line in wrote(work + ".err").split("\n") if started and line.startswith("the runner's child %d said: " % started[-1])]

def calls_meet():
    d = case_dir("calls-meet")
    def child_refused(pid, pgid):
        if os.getpid() != driver:
            raise PermissionError(1, "Operation not permitted")
        return real["setpgid"](pid, pgid)
    os.setpgid = child_refused
    rc = run(["30", sys.executable, "-c", LEADS, os.path.join(d, "group")])
    result("stand in: the system refuses the waiting process's own call for a new group while the runner's goes through: the command runs, as the leader of its group, and keeps its code",
           rc == 5 and wrote(os.path.join(d, "group")) == "leads" and not said and not faults(log), (rc, wrote(os.path.join(d, "group")), said, faults(log)))
    let_go(d)
attempt("stand in: the system refuses the waiting process's own call for a new group", calls_meet)

# BOTH REFUSED WHEN THEY MET (0 of the 13000). Let go, the waiting process does not lead a group
# of its own, and it does NOT ask again: a group made after the runner let go is one the runner
# never looked at, and a stop, a limit or a fault in that span would find no group to end. So
# nothing is run: 125, and the waiting process says why. The stand in would grant a second call
# and writes every call down, so a runner that asked again shows twice: the command runs, and the
# file holds two calls.
def calls_both_refused():
    d = case_dir("calls-both-refused")
    asks = os.path.join(d, "asks")
    def refused_once(pid, pgid):
        if os.getpid() == driver:
            raise PermissionError(1, "Operation not permitted")
        with open(asks, "a") as f:
            f.write("asked\n")
        if wrote(asks) == "asked\n":
            raise PermissionError(1, "Operation not permitted")
        return real["setpgid"](pid, pgid)
    os.setpgid = refused_once
    ran = os.path.join(d, "ran")
    rc = run(["30"] + touches(ran))
    words = child_said()
    result("stand in: the system refuses both calls for a new group when they meet: 125, the command never ran, the waiting process asked once and never again, and its one line says it does not lead a group of its own",
           rc == 125 and not os.path.exists(ran) and wrote(asks) == "asked\n" and not faults(log) and not said
           and len(words) == 1 and "nothing was run" in words[0] and "does not lead a process group of its own" in words[0],
           (rc, os.path.exists(ran), wrote(asks), faults(log), said, words))
    let_go(d)
attempt("stand in: the system refuses both calls for a new group when they meet", calls_both_refused)

# ONLY THAT REFUSAL IS PASSED OVER. Any other error from the waiting process's own call is one
# nothing here has measured: 125 with its line, even where the runner's call went through and
# the process does lead its group. The stand in answers EACCES (13 on macOS and on Linux), which
# python raises as the same PermissionError as EPERM, so a runner that passed over the kind of
# error and not the number would start the command.
def call_other_error():
    d = case_dir("call-other-error")
    def child_fails(pid, pgid):
        if os.getpid() != driver:
            raise PermissionError(13, "Permission denied")
        return real["setpgid"](pid, pgid)
    os.setpgid = child_fails
    ran = os.path.join(d, "ran")
    rc = run(["30"] + touches(ran))
    words = child_said()
    result("stand in: the waiting process's call for a new group answers an error that is not EPERM: 125, the command never ran, and its one line names the error",
           rc == 125 and not os.path.exists(ran) and not faults(log) and not said
           and len(words) == 1 and "nothing was run" in words[0] and "Errno 13" in words[0],
           (rc, os.path.exists(ran), faults(log), said, words))
    let_go(d)
attempt("stand in: the waiting process's call for a new group answers an error that is not EPERM", call_other_error)

# A SYSTEM THAT REFUSES EVERY SUCH CALL. The command must never run outside a group of its own,
# where nothing could end what it starts: 125, the command never ran, and the waiting process says
# why (its words are on this run's standard error, the file beside the work folder). With no
# second call made, this walks the same steps as the both refused case above, which is the one of
# the two that was seen to fail.
def calls_all_refused():
    d = case_dir("calls-refused")
    def refused(pid, pgid):
        raise PermissionError(1, "Operation not permitted")
    os.setpgid = refused
    ran = os.path.join(d, "ran")
    rc = run(["30"] + touches(ran))
    words = child_said()
    result("stand in: a system that refuses every call for a new group: 125, the command never ran, nothing was signalled against the rule, and the one line is the waiting process saying nothing was run",
           rc == 125 and not os.path.exists(ran) and not faults(log) and not said and len(words) == 1 and "nothing was run" in words[0],
           (rc, os.path.exists(ran), faults(log), said, words))
    let_go(d)
attempt("stand in: a system that refuses every call for a new group", calls_all_refused)

# A system the runner cannot see a group on is refused before anything starts (pick's refusal).
def unseeing():
    d = case_dir("unseeing")
    sys.platform = "sunos5"
    rc = run(["300"] + touches(os.path.join(d, "ran")))
    sys.platform = real["platform"]
    first = (rc, list(said), [e for e in log if e[0] == "fork"])
    if real["platform"] == "darwin":
        refuse["own"] = True
    else:
        m.proc_members = lambda *args: 0
    try:
        rc = run(["300"] + touches(os.path.join(d, "ran")))
    finally:
        m.proc_members = real_proc_members
    second = (rc, list(said), [e for e in log if e[0] == "fork"])
    result("stand in: a system that is neither macOS nor Linux: 125, one line that says nothing was run, and nothing started",
           first[0] == 125 and len(first[1]) == 1 and "nothing was run" in first[1][0] and not first[2], first)
    result("stand in: a system where the runner cannot see its own group: 125, one line that says nothing was run, and nothing started",
           second[0] == 125 and len(second[1]) == 1 and "nothing was run" in second[1][0] and not second[2] and not os.path.exists(os.path.join(d, "ran")), second)
    let_go(d)
real_proc_members = m.proc_members
attempt("stand in: a system the runner cannot see a group on", unseeing)

# THE SIGNALS THE RUNNER CARRIES OVER (S2), read at the record step, when they are all in. One the
# caller had ignored stays ignored. TSTP is caught so that the runner is not stopped by it: a
# stopped runner keeps no limit.
def carried():
    names = ("SIGTERM", "SIGINT", "SIGHUP", "SIGQUIT", "SIGUSR2", "SIGALRM", "SIGVTALRM", "SIGPROF", "SIGXCPU", "SIGTSTP", "SIGUSR1")
    def now_set():
        return dict((n, signal.getsignal(getattr(signal, n))) for n in names)
    came = now_set()
    # Whatever started this suite may have ignored some of them (a shell ignores INT and QUIT for
    # what it starts in the background), so each is set here: default, and USR1 ignored.
    for n in names:
        signal.signal(getattr(signal, n), signal.SIG_IGN if n == "SIGUSR1" else signal.SIG_DFL)
    before, seen, after, rc = now_set(), {}, {}, None
    def looks(folder, pgid):
        seen.update(now_set())
    m.record = looks
    try:
        rc = run(["30", "sh", "-c", "exit 3"])
        after = now_set()
    finally:
        for n in names:
            signal.signal(getattr(signal, n), came[n] if came[n] is not None else signal.SIG_DFL)
    def notes(n):
        return type(getattr(seen.get(n), "__self__", None)).__name__ == "Asked"
    missing = [n for n in names[:9] if not notes(n)]
    result("stand in: TERM, INT, HUP, QUIT, USR2, ALRM, VTALRM, PROF and XCPU are all caught to be carried over while a command runs", rc == 3 and not missing, (rc, missing))
    result("stand in: TSTP is caught while a command runs, so the runner is not stopped by it", callable(seen.get("SIGTSTP")), seen.get("SIGTSTP"))
    result("stand in: a signal the caller had ignored stays ignored", seen.get("SIGUSR1") == signal.SIG_IGN, seen.get("SIGUSR1"))
    result("stand in: every one of them is put back as it was when the run ends", after == before, [n for n in names if after.get(n) != before[n]])
attempt("stand in: the signals the runner carries over", carried)

# TTIN AND TTOU (S2 of the second review of #3833). Either one STOPS a process that has it at its
# default, and a stopped runner keeps no limit, which is what TSTP was closed for. The runner has
# both ignored while a command runs. Ignored, never caught: a caught TTOU makes the write that
# raised it fail and be tried again for ever. They are set once the command's process exists, so
# the command does not inherit them: it starts with both as its caller had them, which it reports
# here as its exit code (10, plus 1 for an ignored TTIN, plus 2 for an ignored TTOU).
TELLS = ("import signal, sys; "
         "sys.exit(10 + sum(n for n, name in ((1, 'SIGTTIN'), (2, 'SIGTTOU')) if signal.getsignal(getattr(signal, name)) == signal.SIG_IGN))")
def terminal_stops():
    names = ("SIGTTIN", "SIGTTOU")
    def now_set():
        return dict((n, signal.getsignal(getattr(signal, n))) for n in names)
    def under(caller):
        """One run with the caller's two settings as given: (the run's code, the two as the
        runner had them at the record step, the two after the run)."""
        for n in names:
            signal.signal(getattr(signal, n), caller[n])
        seen = {}
        def looks(folder, pgid):
            seen.update(now_set())
        m.record = looks
        rc = run(["30", sys.executable, "-c", TELLS])
        return rc, seen, now_set()
    came = now_set()
    both = dict((n, signal.SIG_IGN) for n in names)
    try:
        plain = dict((n, signal.SIG_DFL) for n in names)
        rc, seen, after = under(plain)
        result("stand in: TTIN and TTOU are ignored in the runner while a command runs, so neither stops it", seen == both and not said, (seen, said))
        result("stand in: the command starts with TTIN and TTOU at their default, as its caller had them, and the runner puts both back when the run ends",
               rc == 10 and after == plain, (rc, after))
        mixed = {"SIGTTIN": signal.SIG_IGN, "SIGTTOU": signal.SIG_DFL}
        rc, seen, after = under(mixed)
        result("stand in: a TTIN the caller had ignored is still ignored for the command and its TTOU is still at its default, and the runner leaves both as they were",
               rc == 11 and seen == both and after == mixed, (rc, seen, after))
    finally:
        for n in names:
            signal.signal(getattr(signal, n), came[n] if came[n] is not None else signal.SIG_DFL)
attempt("stand in: TTIN and TTOU while a command runs", terminal_stops)

# A stop asked for after the handlers are in and before the command is let go (S9): the command is
# never started. The stand in for the record step asks, with a signal to this process itself.
def asked_early():
    d = case_dir("asked-early")
    def asks(folder, pgid):
        signal.raise_signal(signal.SIGTERM)
    m.record = asks
    came = signal.signal(signal.SIGTERM, signal.SIG_DFL)     # not ignored, whatever started the suite
    try:
        rc = run(["300"] + touches(os.path.join(d, "ran")))
    finally:
        signal.signal(signal.SIGTERM, came if came is not None else signal.SIG_DFL)
    result("stand in: a stop asked for before the command is let go: 143, the command never ran, and the one line says nothing was run",
           rc == 143 and not os.path.exists(os.path.join(d, "ran")) and len(said) == 1 and "nothing was run" in said[0], (rc, said))
    result("stand in: a stop asked for before the command is let go: every child collected once, and no signal after its collect", not faults(log), (faults(log), log))
    let_go(d)
attempt("stand in: a stop asked for before the command is let go", asked_early)

# R6's "before the command starts", held without racing the command: the stand in for the record
# step waits before it makes the file, and the command looks for the file in its first statement.
# A runner that let the command go before the record was made would have it look and find nothing.
def record_first():
    root = os.environ.get("AGENT_LEFTOVERS_ROOT") or ""
    marks = os.path.join(root, "sess-slow")
    d = case_dir("record-first")
    os.makedirs(marks)
    os.environ["CLAUDE_CODE_SESSION_ID"] = "sess-slow"
    def slow(folder, pgid):
        time.sleep(0.5)
        return kept["record"](folder, pgid)
    m.record = slow
    try:
        rc = run(["30", "sh", "-c", '[ -f "$1/$$" ] && : > "$2"', "sh", marks, os.path.join(d, "found")])
    finally:
        del os.environ["CLAUDE_CODE_SESSION_ID"]
    result("stand in: a record that is slow to make is still there when the command's first statement runs",
           rc == 0 and os.path.exists(os.path.join(d, "found")) and not said, (rc, said))
    let_go(d)
attempt("stand in: a record that is slow to make", record_first)

# A command that is SUSPENDED when its limit arrives (S1): at a terminal that is a command which
# read the terminal from the background group the runner puts it in. Here the command suspends
# itself, and the limit arrives only once the system shows it suspended, so nothing races. The
# line must say it was not running.
SUSPENDS = 'echo "$$" > "$1/leader.tmp" && mv "$1/leader.tmp" "$1/leader.pid"; kill -STOP "$$"; echo "should never be printed"'
def suspended():
    if not real["waitid"]:
        print("SUITE-PART-UNMEASURED the line for a command that was suspended at its limit: this python3 (%s) has no os.waitid, the one look that tells" % sys.version.split()[0])
        return
    d = case_dir("suspended")
    base, late = time.monotonic(), []
    def clock():
        # Once past the limit it stays past it: the command stops being suspended when it is ended.
        if not late:
            try:
                with open(os.path.join(d, "leader.pid")) as f:
                    pid = int(f.read())
                got = real["waitid"](os.P_PID, pid, os.WSTOPPED | os.WNOHANG | os.WNOWAIT)
            except (OSError, ValueError):
                return base
            if got is None or got.si_code != os.CLD_STOPPED:
                return base
            late.append(True)
        return time.monotonic() + 1e6
    m.now = clock
    m.GRACE = 0.3
    rc = run(["1", "sh", "-c", SUSPENDS, "sh", d])
    result("stand in: a command suspended when its limit arrives: 124, and the one line says it was suspended and not running",
           rc == 124 and len(said) == 1 and "suspended, not running" in said[0], (rc, said))
    # This command suspended itself and read no terminal. The runner sees only THAT it was
    # suspended, never why, so the line may name the terminal as the likely cause and no more.
    result("stand in: a command suspended when its limit arrives: the line names the terminal as the likely cause only, since the runner did not see why",
           len(said) == 1 and "likely" in said[0] and "terminal" in said[0], said)
    result("stand in: a command suspended when its limit arrives: its group is ended all the same, every child collected once, and no signal after its collect",
           sent(15) and not faults(log), (faults(log), log))
attempt("stand in: a command suspended when its limit arrives", suspended)

# A command that has LEFT its group when the limit arrives (S10): the group holds nothing, and the
# command is still the runner's own uncollected child, so its own process id is still pinned. It is
# ended by that id, through the same class.
MOVES = """
import os, signal, sys, time
d, ticks = sys.argv[1], int(sys.argv[2])
os.setpgid(0, os.getpgid(os.getppid()))
if sys.argv[3:] == ["stubborn"]:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(d + "/leader.tmp", "w") as f:
    f.write("%d\\n" % os.getpid())
os.rename(d + "/leader.tmp", d + "/leader.pid")
n = 0
while os.path.exists(d + "/hold") and n < ticks:
    time.sleep(0.1)
    n += 1
"""
def moved_run(name, words):
    """One run of a command that leaves its group. Returns (the code, the signals asked for by
    the command's own process id). The runner watches for GONE seconds before it sends the first
    of those: a leader that is ending reads, for a moment, exactly as one that left its group, so
    the wait cannot be cut short on that reading (the comment at the wait in the program says
    what was read). GONE is short here, and nothing is asserted about how long it took."""
    d = case_dir(name)
    m.now = limit_when_ready(d)
    m.GRACE = 0.3
    m.GONE = 1.0
    try:
        rc = run(["1", sys.executable, "-c", MOVES, d, ticks] + words)
    finally:
        let_go(d)
    return rc, [e for e in log if e[0] == "kill"]

def moved():
    rc, by_id = moved_run("moved", [])
    result("stand in: a command that left its group: 124, and it was ended by its own process id while it was still uncollected",
           rc == 124 and by_id and by_id[0][2] == 15 and not faults(log), (rc, faults(log), log))
    result("stand in: a command that left its group: the one line says it had left its group", len(said) == 1 and "its own process id" in said[0], said)
attempt("stand in: a command that left its group", moved)

# The same command ignoring TERM: KILL follows by the same process id, as it follows for a group.
def moved_stubborn():
    rc, by_id = moved_run("moved-stubborn", ["stubborn"])
    result("stand in: a command that left its group and ignores TERM: 124, TERM and then KILL by its own process id while it was still uncollected, and the line says KILL ended it",
           rc == 124 and [e[2] for e in by_id] == [15, 9] and not faults(log) and len(said) == 1 and "its own process id, at KILL" in said[0], (rc, faults(log), said, log))
attempt("stand in: a command that left its group and ignores TERM", moved_stubborn)

# The two endings where something is LEFT RUNNING, each said, with the system stood in for.
# First: the group will not be signalled by this user and neither will the command (a setuid
# program). The runner must say so, must not wait on a collect that would never return, and must
# signal nothing it was refused.
def unsignalable():
    d = case_dir("unsignalable")
    m.now = limit_when_ready(d)
    m.GRACE = 0.3
    m.GONE = 0.5
    refuse["signals"] = True
    try:
        rc = run(["1", "sh", fx, d, ticks, "plain", "hold"])
        result("stand in: a command this user may not signal: 124, one line says it is left running, and the runner does not wait to collect it",
               rc == 124 and len(said) == 1 and "left running" in said[0] and not faults(log, 1), (rc, said, faults(log, 1)))
    finally:
        refuse.clear()
        let_go(d)
attempt("stand in: a command this user may not signal", unsignalable)

# Second: something in the group is still there after KILL (the stand in takes the KILL and sends
# nothing, as for a member KILL cannot end). Said, and the run still fails.
def unkillable():
    d = case_dir("unkillable")
    m.GRACE = 0.3
    m.GONE = 0.5
    swallow.add(9)
    try:
        rc = run(["300", "sh", fx, d, ticks, "stubborn", "leave", "7"])
        result("stand in: a member still there after KILL: 123, TERM and KILL were both asked for, and one line says it is left running",
               rc == 123 and sent(15) and sent(9) and len(said) == 1 and "still there" in said[0] and "left running" in said[0] and not faults(log), (rc, said, faults(log)))
    finally:
        swallow.clear()
        let_go(d)
attempt("stand in: a member still there after KILL", unkillable)

# macOS: a watch made on a child that has ALREADY ended and is not collected. The kernel refuses
# the registration (the process is gone, its number is not), and the watch reads that as ended.
def ended_first():
    if not hasattr(m.select, "kqueue"):
        print("SUITE-PART-UNMEASURED a watch made on a child that had already ended: this system has no kqueue, and its other watch has no such step")
        return
    del log[:]
    pid = os.fork()
    if pid == 0:
        os._exit(0)
    first = m.KqueueWatch(pid, m.Asked(), [])
    first.wait(ceiling)
    second = m.KqueueWatch(pid, m.Asked(), [])
    result("a watch made on a child that has already ended and is not collected says ended at once", first.ended and second.ended, (first.ended, second.ended))
    first.close()
    second.close()
    m.Group(pid).collect()
attempt("a watch made on a child that has already ended", ended_first)

# The other way of watching for the command's end without collecting it, which is the one Linux
# has: waitid with WNOWAIT. Forced here wherever this python has it, so it is measured on a Mac too.
# A part that could not be measured is printed in the shape run-all-tests.sh reads, and the loop
# below passes that line on as it is (#1444).
picked = own_pick()
if isinstance(picked, str):
    print("SUITE-PART-UNMEASURED the waitid way of watching: the runner refuses this system (%s)" % picked)
elif not hasattr(os, "waitid"):
    print("SUITE-PART-UNMEASURED the waitid way of watching for the command's end: this python3 (%s) has no os.waitid" % sys.version.split()[0])
else:
    m.pick = lambda: (m.WaitidWatch, picked[1])
    scenarios("stand in, watching by waitid: ")
    m.pick = own_pick

# How Linux sees what is left in a group: /proc, read here from a stand in tree. A member whose
# state is Z has ended and is waiting to be collected, so it is not left running.
proc = os.path.join(work, "proc")
def stat(pid, comm, state, pgrp):
    os.makedirs(os.path.join(proc, str(pid)))
    with open(os.path.join(proc, str(pid), "stat"), "w") as f:
        f.write("%d (%s) %s 1 %d %d 0 -1 4194560 0 0\n" % (pid, comm, state, pgrp, pgrp))
stat(100, "sh", "Z", 100)
stat(101, "sleep", "S", 100)
stat(102, "a b) R 1 100 (c", "R", 100)
stat(103, "sh", "S", 555)
os.makedirs(os.path.join(proc, "self"))
os.makedirs(os.path.join(proc, "104"))      # ended between the listing and the read: no stat
result("a stand in /proc: two members of the group are running, the ended leader and another group's are not counted",
       m.proc_members(100, proc) == 2, m.proc_members(100, proc))
result("a stand in /proc: a group with only its ended leader holds nothing", m.proc_members(555, proc) == 1 and m.proc_members(777, proc) == 0,
       (m.proc_members(555, proc), m.proc_members(777, proc)))
result("a /proc that is not there is said as unreadable, never as an empty group", m.proc_members(100, os.path.join(work, "no-proc")) is None)
print("DONE\tall")
EOF
# take_results <its lines> <what it said on standard error> <what ran>: one check for each line.
take_results() {
  local verdict name detail done_word="" failed_here=""
  while IFS=$'\t' read -r verdict name detail; do
    case "$verdict" in
      PASS) check "$name" ok ;;
      FAIL) check "$name" "got: ${detail:-no detail}"; failed_here=yes ;;
      SUITE-PART-UNMEASURED\ *) echo "$verdict${name:+ $name}${detail:+ $detail}" ;;
      DONE) done_word="$name" ;;
    esac
  done < "$1"
  # Beside a failure, the last of what the run said on standard error: a child of the runner's
  # that failed before it became the command says so there and nowhere else.
  if [ -n "$failed_here" ] && [ -s "$2" ]; then
    echo "  the last of what $3 said on standard error: $(tail -n 8 "$2" | tr '\n' ' ')"
  fi
  check "$3 reached its end" "$([ -n "$done_word" ] && echo ok || echo "it stopped early: $(tail -n 5 "$2" | tr '\n' ' ')")"
}
# end_cases <folder> <what they were>: every case under the folder that still has its hold is
# checked for anything it left running.
end_cases() {
  for CASE in "$1"/*/; do
    CASE="${CASE%/}"
    [ -e "$CASE/hold" ] || continue
    end_case "$2 ${CASE##*/}"
  done
}
take_results "$TMP/drive.out" "$TMP/drive.err" "the stand in run"
end_cases "$TMP/drive" "the stand in run's"

# ---------------------------------------------------------------------------
# THE RUNNER TOLD TO STOP BY EACH KIND OF SIGNAL IT CARRIES OVER (R7), through the launcher and
# with real signals. Each runner is this python's own child, and is signalled only while python
# still holds it uncollected. The runner must end its command's group first, say so in one line,
# and then end BY THAT SIGNAL: a shell loop around it stops at Ctrl C only when its child died of
# the signal, never when it exited with 130. TSTP must not stop the runner at all, since a stopped
# runner keeps no limit: a runner it did stop would not answer the TERM that follows.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/told"
python3 - "$BASH" "$RUNNER" "$FX" "$TMP/told" "$HANG_TICKS" > "$TMP/told.out" 2> "$TMP/told.err" <<'EOF'
import os, signal, subprocess, sys, time
bash, runner, fx, work, ticks = sys.argv[1:6]
ceiling = float(ticks) / 30         # the hang ceiling the suite's own waits take, in seconds

def result(name, cond, detail=""):
    print(("PASS\t" + name) if cond else "FAIL\t%s\t%s" % (name, " ".join(str(detail).split())))
    sys.stdout.flush()

def start(name, defaults):
    """A runner on the fixture, as this process's own child, with the named signals at their
    default whatever started this suite (a shell ignores INT and QUIT for what it starts in the
    background, and the runner leaves an ignored signal ignored). Returns once the fixture is up."""
    d = os.path.join(work, name)
    os.makedirs(d)
    open(os.path.join(d, "hold"), "w").close()
    def as_default():
        for s in defaults:
            signal.signal(s, signal.SIG_DFL)
    with open(os.path.join(d, "err"), "wb") as err:
        p = subprocess.Popen([bash, runner, "300", "sh", fx, d, ticks, "plain", "hold"],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=err, preexec_fn=as_default)
    end = time.monotonic() + ceiling
    while time.monotonic() < end and p.poll() is None and not (os.path.exists(os.path.join(d, "leader.pid")) and os.path.exists(os.path.join(d, "child.pid"))):
        time.sleep(0.05)
    return d, p

def ended(p, seconds):
    try:
        return p.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        return None

def said(d):
    with open(os.path.join(d, "err"), errors="replace") as f:
        return f.read()

def runner_lines(text):
    """The runner's own lines in what a run said. The fixture's standard error is the same file,
    so its shell's lines can be there too: bash reports "Terminated: 15" for a `sleep` that TERM
    reached a moment before the shell itself (as the suite's own runner_lines says, above)."""
    return [line for line in text.splitlines() if line.startswith("run-with-limit: ")]

# That count, seen to find a wrong number of lines before it is trusted (L1), on recorded lines.
SHELLS = fx + ": line 21: 63194 Terminated: 15          sleep 0.1\n"
RUNNERS = "run-with-limit: was sent SIGHUP, so its command was stopped: its whole process group (id 63094) ended at TERM: sh " + fx + "\n"
result("the count of the runner's lines in a told run reads one line of the runner's beside a line of the fixture's shell as one, and finds two and none",
       len(runner_lines(SHELLS + RUNNERS)) == 1 and len(runner_lines(RUNNERS + SHELLS + RUNNERS)) == 2 and not runner_lines(SHELLS + "sh: " + RUNNERS),
       (runner_lines(SHELLS + RUNNERS), runner_lines(RUNNERS + SHELLS + RUNNERS), runner_lines(SHELLS + "sh: " + RUNNERS)))

for name in ("SIGINT", "SIGHUP", "SIGQUIT", "SIGUSR1"):
    sig = getattr(signal, name)
    d, p = start("told-" + name, [sig])
    what = "a runner sent %s ends its command's group, says so in one line that names the signal, and then ends by that signal itself" % name[3:]
    if p.poll() is not None:
        result(what, False, "the runner came back %s before it was told anything, said: %s" % (p.returncode, said(d)))
        continue
    p.send_signal(sig)          # to this process's own child, which Popen still holds uncollected
    rc = ended(p, ceiling)
    text = said(d)
    lines = runner_lines(text)
    result(what, rc == -sig and len(lines) == 1 and name in lines[0], (rc, text))
    if rc is None:
        p.kill()
        p.wait()

d, p = start("told-SIGTSTP", [signal.SIGTSTP, signal.SIGTERM])
what = "a runner sent TSTP is not stopped by it: the TERM that follows is carried over, and the runner ends by TERM"
if p.poll() is not None:
    result(what, False, "the runner came back %s before it was told anything, said: %s" % (p.returncode, said(d)))
else:
    p.send_signal(signal.SIGTSTP)
    p.send_signal(signal.SIGTERM)
    rc = ended(p, min(ceiling, 60.0))
    result(what, rc == -signal.SIGTERM and "SIGTERM" in said(d), (rc, said(d)))
    if rc is None:
        # It was stopped: let it go on, so that it answers the TERM and nothing is left behind.
        p.send_signal(signal.SIGCONT)
        if ended(p, ceiling) is None:
            p.kill()
            p.wait()
print("DONE\tall")
EOF
take_results "$TMP/told.out" "$TMP/told.err" "the run that tells a runner to stop"
end_cases "$TMP/told" "a runner told to stop:"

# A runner that goes before it has let its command go (ended outright between starting the child
# and watching it) must not leave the command running with nobody to keep its limit: the child
# reads the end of the pipe it waits on and ends without becoming the command. The stand in for
# the record step writes the child's process id and ends the runner with no clean up of any kind.
# The suite waits for that child to be gone before it looks, so a child that did become the
# command has finished writing its file by then.
new_case gone
python3 - "$PY" "$CASE" > /dev/null 2> "$CASE/err" <<'EOF'
import importlib.util, os, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("run_with_limit", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
d = sys.argv[2]

def goes(folder, pgid):
    with open(os.path.join(d, "child.tmp"), "w") as f:
        f.write("%d\n" % pgid)
    os.rename(os.path.join(d, "child.tmp"), os.path.join(d, "child.pid"))
    os._exit(77)

m.record = goes
m.main(["300", "sh", "-c", ': > "$1"', "sh", os.path.join(d, "ran")])
os._exit(78)
EOF
rc=$?
check "the stand in runner went at the step it was told to" "$([ "$rc" -eq 77 ] && [ -s "$CASE/child.pid" ] && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
end_case "a runner that went before it let its command go"
check "and the child it left never became the command" "$([ ! -e "$CASE/ran" ] && echo ok || echo "the command ran with no runner")"

# One call in the program signals a group, one signals a process (the command itself, by its own
# process id), and one collects, so the rule has one home to be held in: the class all three are
# reached through. The reader helper is started, and on a time out ended and collected, by python's
# subprocess module, which the program names in one place.
code_lines() { grep -v '^[[:space:]]*#' "$PY" 2> /dev/null; }
n_killpg="$(code_lines | grep -c 'os\.killpg(' || true)"
n_kill="$(code_lines | grep -c 'os\.kill(' || true)"
n_waitpid="$(code_lines | grep -c 'os\.waitpid(' || true)"
n_sub="$(code_lines | grep -c 'subprocess\.run(' || true)"
check "the program has one call that signals a group, one that signals a process, one that collects, and one start of a helper" \
  "$([ "$n_killpg" = 1 ] && [ "$n_kill" = 1 ] && [ "$n_waitpid" = 1 ] && [ "$n_sub" = 1 ] && echo ok || echo "os.killpg: $n_killpg, os.kill: $n_kill, os.waitpid: $n_waitpid, subprocess.run: $n_sub")"

# ---------------------------------------------------------------------------
# Under the no network wrapper, where ps cannot start (a setuid program is refused in a sandbox):
# the runner reads no ps, so it still sees what a command left and stops it.
# ---------------------------------------------------------------------------
WRAP="$DIR/no-network-run.sh"
if [ "$(uname -s)" != Darwin ] || [ ! -x "$WRAP" ]; then
  echo "SUITE-PART-UNMEASURED the runner under the no network wrapper: the wrapper's sandbox is macOS's, and this is $(uname -s)"
elif ! wrap_said="$("$WRAP" /usr/bin/true 2>&1)"; then
  echo "SUITE-PART-UNMEASURED the runner under the no network wrapper: the wrapper would not run a command here (${wrap_said%%$'\n'*})"
else
  new_case wrapped
  "$WRAP" "$BASH" "$RUNNER" 30 sh -c 'exit 3' > "$CASE/out" 2> "$CASE/err"; rc=$?
  check "under the no network wrapper a command inside its limit keeps its exit code" "$([ "$rc" -eq 3 ] && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
  "$WRAP" "$BASH" "$RUNNER" 300 sh "$FX" "$CASE" "$HANG_TICKS" plain leave 0 > "$CASE/out" 2> "$CASE/err"; rc=$?
  check "under the no network wrapper a child left running is seen and stopped, and the run fails with 123" \
    "$([ "$rc" -eq 123 ] && grep -q 'left a process running' "$CASE/err" && echo ok || echo "rc $rc, said: $(cat "$CASE/err")")"
  end_case "under the no network wrapper"
fi

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
