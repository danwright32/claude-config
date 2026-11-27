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
#   - the runner never signals a number nothing pins: every signal goes to the group of its own
#     child while that child is still uncollected, and none after the collect. Shown with stand ins
#     for the signal and collect calls, which record a late signal and never send it;
#   - a limit that is not a whole number of seconds above zero, or no command, runs nothing;
#   - with python3 missing, or the program behind the launcher missing, nothing runs: a command is
#     never run with no limit;
#   - the group it starts is recorded in the session's marker folder before the command starts.
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
one_line() { [ "$(wc -l < "$1" | tr -d ' ')" -eq 1 ]; }
started() { [ -s "$CASE/leader.pid" ] && [ -s "$CASE/child.pid" ]; }

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
# Installed as every suite installs a helper (#2147). The launcher starts its program by path, which
# the installer follows only for a helper that is named, so this folder lacks the program on purpose.
python3 "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$TMP/lone" run-with-limit.sh > /dev/null \
  || check "the launcher could be installed by itself, without the program behind it" "the install refused"
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
# The command is its group's leader, so its own process id is the group's id.
CLAUDE_CODE_SESSION_ID=sess-one bash "$RUNNER" 30 sh -c 'echo "$$" > "$1/leader.pid"; [ -e "$2/$$" ] && : > "$1/there-first"; exit 0' sh "$CASE" "$TMP/marks/sess-one" > /dev/null 2> "$CASE/err"; rc=$?
gid="$(cat "$CASE/leader.pid" 2> /dev/null || true)"
check "a run inside a recorded session leaves an empty file named for its group's id in that session's marker folder" \
  "$([ "$rc" -eq 0 ] && [ -n "$gid" ] && [ -f "$TMP/marks/sess-one/$gid" ] && [ ! -s "$TMP/marks/sess-one/$gid" ] && echo ok || echo "rc $rc, group [$gid], folder holds: $(ls "$TMP/marks/sess-one" 2>&1 | tr '\n' ' '), said: $(cat "$CASE/err")")"
check "and the file is there before the command's first statement runs" "$([ -e "$CASE/there-first" ] && echo ok || echo "the command did not find it")"
check "and the runner says nothing about it" "$([ ! -s "$CASE/err" ] && echo ok || echo "said: $(cat "$CASE/err")")"
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
# run in this process with os.killpg, os.kill and every collecting call replaced by recorders. A
# signal asked for after the collect is recorded and NOT sent, so a broken runner is caught without
# a signal ever going to a number nothing pins. The limit here is no real clock: it arrives when
# the fixture has written its process ids, so the order is the same on any machine.
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

def result(name, cond, detail=""):
    print(("PASS\t" + name) if cond else "FAIL\t%s\t%s" % (name, " ".join(str(detail).split())))
    sys.stdout.flush()

log, said = [], []
real_killpg, real_waitpid = os.killpg, os.waitpid

def collected():
    return any(e[0] == "collect" for e in log)

def killpg(pgid, sig):
    if collected():
        log.append(("late", pgid, int(sig)))      # recorded, never sent
        return None
    log.append(("signal", pgid, int(sig)))
    return real_killpg(pgid, sig)

def kill(pid, sig):
    log.append(("kill", pid, int(sig)))           # not the runner's way to signal: recorded, never sent

def waitpid(pid, options):
    log.append(("collect", pid))
    return real_waitpid(pid, options)

os.killpg, os.kill, os.waitpid = killpg, kill, waitpid
for name in ("wait", "wait3", "wait4"):
    if hasattr(os, name):
        def other(*args, _name=name, _real=getattr(os, name)):
            log.append(("collect", _name))
            return _real(*args)
        setattr(os, name, other)
if hasattr(os, "waitid"):
    real_waitid = os.waitid
    def waitid(idtype, ident, options):
        if not options & os.WNOWAIT:
            log.append(("collect", ident))
        return real_waitid(idtype, ident, options)
    os.waitid = waitid
m.say = said.append
own = os.getpgrp()

def faults(entries, collects_wanted=1):
    """What a record shows the runner did against the rule. Empty when it was kept."""
    out = []
    collects = [i for i, e in enumerate(entries) if e[0] == "collect"]
    if len(collects) != collects_wanted:
        out.append("it collected %d times" % len(collects))
    for i, e in enumerate(entries):
        if e[0] == "late" or (e[0] == "signal" and collects and i > collects[0]):
            out.append("signal %d to group %d after the collect" % (e[2], e[1]))
        if e[0] == "kill":
            out.append("os.kill of %d with %d" % (e[1], e[2]))
    if collects:
        child = entries[collects[0]][1]
        for e in entries:
            # Signal 0 to its own group is the runner's check, before it starts anything, that it
            # can see a group at all. Every other signal must go to its child's group.
            if e[0] == "signal" and e[1] != child and not (e[1] == own and e[2] == 0):
                out.append("signal %d to group %d, which is not its child's group %d" % (e[2], e[1], child))
    return out

def sent(sig):
    return any(e[0] == "signal" and e[2] == sig for e in log)

# The judge itself, seen to find each fault before it is trusted to find none (L1).
result("the judge of a record finds a signal after the collect", faults([("signal", 5, 15), ("collect", 5), ("late", 5, 9)]))
result("the judge finds a signal that was sent after the collect", faults([("collect", 5), ("signal", 5, 9)]))
result("the judge finds a signal to a group that is not the child's", faults([("signal", 7, 15), ("collect", 5)]))
result("the judge finds a second collect, and none", faults([("collect", 5), ("collect", 5)]) and faults([("signal", 5, 0)]))
result("the judge finds a plain os.kill", faults([("kill", 5, 15), ("collect", 5)]))
result("the judge passes a record that keeps the rule", not faults([("signal", own, 0), ("signal", 5, 0), ("signal", 5, 15), ("collect", 5)]))

def case_dir(name):
    d = os.path.join(work, name)
    os.makedirs(d)
    open(os.path.join(d, "hold"), "w").close()
    return d

def run(args):
    del log[:]
    del said[:]
    return m.main(args)

def limit_when_ready(d):
    """A clock that stands still until the fixture has written its process ids, and then is far
    past any limit and moving at the real rate."""
    ready, base = os.path.join(d, "leader.pid"), time.monotonic()
    return lambda: time.monotonic() + 1e6 if os.path.exists(ready) else base

def scenarios(tag):
    rc = run(["30", "sh", "-c", "exit 3"])
    result(tag + "in time and nothing left: the command's own code", rc == 3, rc)
    result(tag + "in time and nothing left: one collect, and no signal after it", not faults(log), faults(log))
    result(tag + "in time and nothing left: no TERM, no KILL and not a word", not sent(15) and not sent(9) and not said, (log, said))

    d = case_dir(tag.strip(": ").replace(" ", "-") + "-limit")
    m.now = limit_when_ready(d)
    rc = run(["1", "sh", fx, d, ticks, "plain", "hold"])
    m.now = time.monotonic
    result(tag + "past the limit: 124", rc == 124, rc)
    result(tag + "past the limit: TERM went to the group before the one collect, and no signal after it", sent(15) and not faults(log), (faults(log), log))
    result(tag + "past the limit: one line names the limit", len(said) == 1 and "1 second limit" in said[0], said)

own_pick = m.pick
scenarios("stand in: ")

d = case_dir("left")
rc = run(["300", "sh", fx, d, ticks, "plain", "leave", "0"])
result("stand in: a child left running: 123", rc == 123, rc)
result("stand in: a child left running: TERM went to the group before the one collect, and no signal after it", sent(15) and not faults(log), (faults(log), log))

d = case_dir("left-stubborn")
grace = m.GRACE
m.GRACE = 0.3
rc = run(["300", "sh", fx, d, ticks, "stubborn", "leave", "7"])
m.GRACE = grace
result("stand in: a child left running that ignores TERM: 123", rc == 123, rc)
result("stand in: a child left running that ignores TERM: TERM, then KILL, then the one collect, and no signal after it",
       sent(15) and sent(9) and not faults(log), (faults(log), log))
result("stand in: a child left running that ignores TERM: the line says the group ended at KILL", len(said) == 1 and "ended at KILL" in said[0], said)

# What a command leaves is given a moment to end by itself (a writer finishing what it was piped)
# before it counts as left running. Here the moment is made as long as the hang ceiling, so the
# case asserts the rule and not this machine's speed.
d = case_dir("passing")
settle = m.SETTLE
result("the moment a command's leftovers are given to end by themselves is at least a second as shipped", settle >= 1.0, settle)
m.SETTLE = float(ticks) / 30
rc = run(["300", "sh", fx, d, ticks, "passing", "leave", "4"])
m.SETTLE = settle
result("stand in: a child that ends by itself just after the command: the command's own code, 4", rc == 4, (rc, said))
result("stand in: a child that ends by itself just after the command: no TERM, no KILL, not a word, one collect",
       not sent(15) and not sent(9) and not said and not faults(log), (faults(log), log, said))

# A fault inside the runner after it has started the command must not leave the command running
# with no limit: the group is ended while the child still pins it, and the run comes back as 125.
d = case_dir("fault")
real_record = m.record
def broken(*args):
    raise RuntimeError("the stand in fault")
m.record = broken
rc = run(["300", "sh", "-c", ': > "$1"', "sh", os.path.join(d, "ran")])
m.record = real_record
result("stand in: a fault inside the runner: 125, and the command never ran", rc == 125 and not os.path.exists(os.path.join(d, "ran")), rc)
# The child is left uncollected there (a collect could wait on it for ever), so it pins its number
# until the runner has gone.
result("stand in: a fault inside the runner: KILL went to the group while the child pinned it, and nothing was collected",
       sent(9) and not faults(log, 0), (faults(log, 0), log))
result("stand in: a fault inside the runner: one line says so", len(said) == 1 and "stand in fault" in said[0], said)

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
drive_done=""
while IFS=$'\t' read -r verdict name detail; do
  case "$verdict" in
    PASS) check "$name" ok ;;
    FAIL) check "$name" "got: ${detail:-no detail}" ;;
    SUITE-PART-UNMEASURED\ *) echo "$verdict${name:+ $name}${detail:+ $detail}" ;;
    DONE) drive_done="$name" ;;
  esac
done < "$TMP/drive.out"
check "the stand in run reached its end" "$([ -n "$drive_done" ] && echo ok || echo "it stopped early: $(tail -n 5 "$TMP/drive.err" | tr '\n' ' ')")"
for CASE in "$TMP/drive"/*/; do
  CASE="${CASE%/}"
  [ -e "$CASE/hold" ] || continue
  end_case "the stand in run's ${CASE##*/}"
done

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

# One place in the program signals and one collects, so the rule has one home to be held in.
code_lines() { grep -v '^[[:space:]]*#' "$PY" 2> /dev/null; }
n_killpg="$(code_lines | grep -c 'os\.killpg(' || true)"
n_kill="$(code_lines | grep -c 'os\.kill(' || true)"
n_waitpid="$(code_lines | grep -c 'os\.waitpid(' || true)"
check "the program has one call that signals a group, none that signals a process, and one that collects" \
  "$([ "$n_killpg" = 1 ] && [ "$n_kill" = 0 ] && [ "$n_waitpid" = 1 ] && echo ok || echo "os.killpg: $n_killpg, os.kill: $n_kill, os.waitpid: $n_waitpid")"

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
