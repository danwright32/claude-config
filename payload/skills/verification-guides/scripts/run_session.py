#!/usr/bin/env python3
"""The RUN harness of the verification-guides skill (claude-config#1528).

    run_session.py start --repo <checkout> --sha <40 hex head> --areas <a,b>
    run_session.py drive <receipt id> --area <name> -- <drive helper arguments>
    run_session.py stop <receipt id>
    run_session.py status <receipt id>

`start` checks out the PR head in a DETACHED worktree under the run's receipt folder, starts the
project's serve command under a supervisor, waits for the project's ready command, and prints the
receipt id. `drive` runs the project's drive helper (never the Playwright tools, which a subagent
may not use) and logs every call against the area it was for. `stop` ends the run. A record of the
run can only be rendered once the receipt shows serve stopped.

A project whose areas are all native may give no serve, ready or url (claude-config#2951). Its run
starts no serve and waits for no ready command: the supervisor still holds the run's locks and its
egress monitor around every drive call, and still ends it on `stop` or the deadline, running the
project's stop command and removing the worktree. Its receipt records `url`, `serve_pid` and
`serve_pgid` as null, and the drive helper gets no VERIFICATION_URL.

Serve is stopped on EVERY path, which is why a supervisor and not the caller owns it. The
supervisor is a detached process that started serve in a process group of its own, holds a lock
for exactly as long as it lives, and stops serve, runs the project's stop command and removes the
worktree when any of these happens first: `stop` asks it to, the ready command never succeeds,
serve exits by itself, the run's deadline (timeouts.max_run_s) passes, the caller's lifeline ends
(for a run started with one, below), or the supervisor itself fails. If the supervisor is killed outright, `stop` sees its lock free with no stop recorded and
does the same work itself, by the process group it recorded (L1011). Waiting for the end of a run
is waiting for that lock, never a poll of a fixed length (L290).

The supervisor starts in a session of its own because the run must outlive `start`: `start`
returns once serve is ready, and `drive` and `stop` come later from other processes, so in real use
the supervisor's parent is always gone and a signal to the caller's process group must not reach
it. A caller that wants the run to end with it instead, a test suite above all (claude-config#3682),
passes a LIFELINE: the read end of a pipe whose write end only it holds, named by
VERIFICATION_LIFELINE_FD. The supervisor reads it, and when every holder of the write end is gone,
killed outright or as a group included, the kernel ends the pipe and the supervisor stops the run,
recorded as `caller_gone`. No pid is watched, so none can be recycled (L1011, L409). A run started
without one, every run a session starts by the skill, has no lifeline and outlives its caller.

A stop is never acted on while the supervisor is still starting its children. A stop signal that
arrives before serve's pid and group and the report stream's group are in the receipt is held and
acted on once they are, because a stop that interrupted the start of a child would leave that child
running in a session of its own with nothing recorded to stop it by. The signals are held by the
handler and never by blocking them: a blocked signal is inherited by every child started meanwhile,
and serve would then never see the SIGTERM that stops it (measured, claude-config#3807).

A stop that cannot finish is CUT OFF, in two places. Serve that is killed and still cannot be
collected within KILLED_WAIT_S ends the stop there. And a supervisor whose caller is gone gives the
stop stop_longest_s to finish (every wait in a stop at its limit, so a slow stop is not taken for a
hung one), counted from when the lifeline ended and whether or not an earlier `stop` already
stands, then ends the run itself from the lifeline's thread. Cutting off kills serve's
group and the report stream's group by the ids the supervisor recorded, collects serve, runs the
project's stop command if the stop had not, removes the worktree, and writes the receipt with the
reason, a `stop_detail` saying the stop did not finish, and egress `unmeasured`: the monitor is never
asked for a verdict on a run that was cut off. A run with no lifeline whose stop hangs anywhere else
is still not ended by anything; `stop` reports it as supervisor-hung.

One run per project at a time: the supervisor also holds a lock keyed by the checkout's path, so a
second `start` is refused with the live run's receipt id rather than fighting it for the port.

The receipt (verification-receipt/1, read through verification.py) records what the harness
measured: the machine, the head and the commit actually checked out, when serve started, became
ready and stopped and why, the build stamp the project's optional stamp command printed, and every
drive call. It also records `egress`, the verdict of the egress monitor in egress.py (#1571): serve and
the drive helper run under a sandbox profile that reports every connection to a host outside this
machine, and the receipt lists each destination seen with its count, judged against areas.json's
egress.allow. The verdict is `clean` only when the monitor was proved live from before serve
started until after it stopped, every report the monitor asked for itself arrived (its canaries and
its test connections, #3576) and nothing outside the allowed hosts was reached; `not-clean`
names what was; `unmeasured` says why the monitor could not see, a Mac that did not report every
connection it was asked to among the reasons, and never passes for clean.

Env: VERIFICATION_HOME (see verification.py). VERIFICATION_LIFELINE_FD, read by `start` alone: the
number of a descriptor that is the read end of a pipe (the lifeline above), or unset for a run with
none; anything else is refused as `lifeline-bad` before a run starts.

Three injectable clocks (L524), each a number of at
least 0 that multiplies seconds, default 1: VERIFICATION_TIME_SCALE scales every poll delay (the
ready interval, the wait for a stopped process group to empty), VERIFICATION_DEADLINE_SCALE scales
the run's deadline, and VERIFICATION_STOP_LIMIT_SCALE scales how long a supervisor whose caller is
gone gives the stop before it cuts the run off. They are separate so a test can make the ready
polls immediate without also firing the deadline, or cut off a stop it has hung without cutting
off every other. The last cannot make a receipt read better: it only cuts a run off sooner, and a
run that is cut off reads unmeasured.

Exit codes are verification.py's: 0 ok, 2 usage, 3 not found, 4 refused, 5 busy, 8 the run failed.
"""

import argparse
import contextlib
import errno
import fcntl
import hashlib
import json
import math
import os
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import threading
import time
import traceback

sys.dont_write_bytecode = True  # a module beside this one is carried by the sync: leave no cache (#2919)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import egress  # noqa: E402
import verification as v  # noqa: E402

EGRESS_WHY = "the run has not stopped yet, and its egress verdict is written when it does"
EGRESS_RECOVERED = ("the supervisor was gone without stopping serve, and the egress monitor it ran went with"
                    " it, so this run's connections were not all seen")
EGRESS_CUT_OFF = ("the run was cut off before its stop had finished (%s), and the egress monitor is never asked"
                  " for a verdict on a run that was cut off, so this run's connections were not all seen")
STOP_REASONS = ("stop", "ready_failed", "caller_gone")
READY_ATTEMPT_MAX_S = 30
GONE_POLL_S = 0.05
KILLED_WAIT_S = 30  # how long serve is waited for once it has been killed, before the stop is cut off
CUT_OFF_ROOM_S = 60  # how long cutting a run off may take, besides the project's stop command
# One thread at a time decides how a run ended, and the first ending recorded is the one kept: a stop
# that finishes after its run was cut off must not rewrite the receipt with a verdict.
ENDING = threading.Lock()
# What the project's stop command exited with, by receipt folder, once a stop in this process has
# run it ("running" while it is), so that cutting the run off neither runs it twice nor skips it.
STOP_COMMAND = {}


class StopRequested(BaseException):
    """A stop signal. A BaseException, so no `except Exception` on the way (the egress monitor's
    start among them) can swallow it and carry on starting serve."""


def time_scale(name="VERIFICATION_TIME_SCALE"):
    raw = os.environ.get(name, "1")
    try:
        scale = float(raw)
    except ValueError:
        scale = -1.0
    if scale < 0 or math.isnan(scale):
        v.fail("bad-time-scale", "%s=%r must be a number of at least 0" % (name, raw))
    return scale


def nap(seconds):
    time.sleep(seconds * time_scale())


def deadline_s(doc):
    return doc["timeouts"]["max_run_s"] * time_scale("VERIFICATION_DEADLINE_SCALE")


def git(repo, *args, check=True):
    r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True, errors="replace")
    if check and r.returncode != 0:
        v.fail("git-failed", "git %s failed in %s: %s" % (" ".join(args), repo, r.stderr.strip()[:300]))
    return r


def tail(path, n=12):
    try:
        with open(path, errors="replace") as f:
            return "".join(f.readlines()[-n:]).strip()
    except FileNotFoundError:
        return "(no %s)" % os.path.basename(path)


# ---------------------------------------------------------------------------------------------
# the receipt, written only here


def receipt_path(rdir):
    return os.path.join(rdir, "receipt.json")


def read_receipt(rdir):
    with open(receipt_path(rdir), errors="replace") as f:
        return json.load(f)


def update_receipt(rdir, **fields):
    """Merge fields into the receipt under its own lock, written whole and renamed into place."""
    with open(os.path.join(rdir, "receipt.lock"), "a", errors="replace") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            rec = read_receipt(rdir)
        except FileNotFoundError:
            rec = {}
        rec.update(fields)
        tmp = receipt_path(rdir) + ".tmp"
        with open(tmp, "w", errors="replace") as f:
            json.dump(rec, f, indent=2)
            f.write("\n")
        os.replace(tmp, receipt_path(rdir))
    return rec


# ---------------------------------------------------------------------------------------------
# the supervisor's lock: held for exactly the supervisor's life


def supervisor_alive(rdir):
    path = os.path.join(rdir, "supervisor.lock")
    if not os.path.exists(path):
        return False
    with open(path, "a", errors="replace") as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(f, fcntl.LOCK_UN)
        return False


def wait_for_supervisor(rdir, timeout_s):
    """Block until the supervisor has exited, however it exited. Returns nothing; raises when hung."""
    f = open(os.path.join(rdir, "supervisor.lock"), "a", errors="replace")

    def hung(signum, frame):
        raise TimeoutError()

    old = signal.signal(signal.SIGALRM, hung)
    signal.alarm(max(1, int(math.ceil(timeout_s))))
    try:
        fcntl.flock(f, fcntl.LOCK_EX)
    except TimeoutError:
        v.fail("supervisor-hung", "the supervisor of %s did not finish stopping within %ss; serve.log: %s"
               % (os.path.basename(rdir), timeout_s, tail(os.path.join(rdir, "serve.log"))))
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)
        f.close()


def stop_wait_s(timeouts):
    """How long a supervisor's stop may take: the project's stop command and serve's group, each up
    to stop_s, plus settling egress (the end canary and the report stream), with room besides."""
    return (timeouts["stop_s"] * 2 + 30
            + egress.finish_budget_s(timeouts.get("egress_s", v.TIMEOUT_DEFAULTS["egress_s"])))


def stop_longest_s(timeouts):
    """The longest a stop that is still getting somewhere can take, every wait in it at its limit:
    stop_wait_s, and the two things that leaves out, a serve that has to be killed and then waited
    for (KILLED_WAIT_S), and its group, asked and then killed (stop_s each). A stop still going
    after this is hung, not slow, which is what cutting a run off is for."""
    return stop_wait_s(timeouts) + timeouts["stop_s"] * 2 + KILLED_WAIT_S


def record_stop_reason(rdir, reason):
    """Record why the run is being stopped. False when an earlier request stands, whose reason is the one kept."""
    path = os.path.join(rdir, "stop-reason")
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
    except FileExistsError:
        return False
    try:
        os.write(fd, reason.encode("utf-8", "replace"))
    except OSError:
        # A reason that could not be written (a full disk) must not be left as an empty file: that
        # would stand as an earlier request for ever, and read as `stop`.
        with contextlib.suppress(OSError):
            os.unlink(path)
        raise
    finally:
        os.close(fd)
    return True


def request_stop(rdir, reason):
    record_stop_reason(rdir, reason)
    rec = read_receipt(rdir)
    pid = rec.get("supervisor_pid")
    # Signal only a supervisor whose lock is held, so a recycled pid is never signalled (L1011).
    if pid and supervisor_alive(rdir):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            return  # it exited between the lock check and the signal; the wait that follows sees it


def requested_reason(rdir, unrecorded="stop"):
    """Why the stop was asked for, as recorded; `unrecorded` when no reason could be recorded."""
    try:
        with open(os.path.join(rdir, "stop-reason"), errors="replace") as f:
            reason = f.read().strip()
    except FileNotFoundError:
        return unrecorded
    return reason if reason in STOP_REASONS else "stop"


# ---------------------------------------------------------------------------------------------
# stopping


def live_members(pgid):
    if not pgid:
        return []
    out = subprocess.run(["ps", "-A", "-o", "pid=,pgid=,stat="], capture_output=True, text=True, errors="replace")
    if out.returncode != 0:
        v.fail("ps-failed", "ps could not list processes: %s" % out.stderr.strip())
    live = []
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] == str(pgid) and not parts[2].startswith("Z"):
            live.append(int(parts[0]))
    return live


def signal_group(pgid, sig):
    try:
        os.killpg(pgid, sig)
    except ProcessLookupError:
        return False  # the group is already empty
    except PermissionError:
        return False  # the pgid now belongs to someone else's processes: never ours to signal
    return True


def wait_gone(pgid, timeout_s):
    attempts = max(1, int(timeout_s / GONE_POLL_S))
    for _ in range(attempts):
        if not live_members(pgid):
            return True
        nap(GONE_POLL_S)
    return not live_members(pgid)


def run_project_command(cmd, cwd, timeout_s, env=None):
    """Run one of the project's commands; returns (exit code or a word, output tail)."""
    try:
        r = subprocess.run(["/bin/sh", "-c", cmd], cwd=cwd, capture_output=True, text=True,
                           timeout=timeout_s, env=env, errors="replace")
    except subprocess.TimeoutExpired:
        return "timeout", "did not finish within %ss" % timeout_s
    except OSError as e:
        return "not-run", str(e)
    return r.returncode, (r.stdout + r.stderr).strip()[-400:]


def remove_worktree(repo, wt):
    if os.path.exists(wt):
        git(repo, "worktree", "remove", "--force", wt, check=False)
    if os.path.exists(wt):
        shutil.rmtree(wt, ignore_errors=True)
    git(repo, "worktree", "prune", check=False)
    listed = git(repo, "worktree", "list", "--porcelain", check=False).stdout
    return not os.path.exists(wt) and ("worktree " + wt + "\n") not in listed + "\n"


def finish_egress(rdir, rec, monitor, egress_why):
    """The receipt's egress field, and the report stream stopped, whatever state the monitor is in.

    With a monitor (the supervisor's own path) its end canary is fired now, after serve's whole
    group is gone. Without one, nothing measured the run: the reason is recorded as unmeasured,
    and a stream a killed supervisor left running is stopped by the process group it recorded
    (L1011). The monitor's beat program ended by itself when the supervisor's death closed its
    input; the copy of it left in the receipt folder is removed here (claude-config#3576).
    """
    if monitor is not None:
        return monitor.finish()
    left = egress.remove_beat_program(rdir)
    if left:
        egress_why += "; " + left
    pgid = rec.get("egress_monitor_pgid")
    if pgid:
        try:
            signal_group(pgid, signal.SIGTERM)
            if not wait_gone(pgid, egress.STREAM_STOP_S):
                signal_group(pgid, signal.SIGKILL)
        except v.VerificationError as e:  # ps failed: said beside the reason, and the stop still recorded
            egress_why += "; the report stream (process group %s) may still be running: %s" % (pgid, e)
    return {"verdict": "unmeasured", "why": egress_why, "monitor": egress.MONITOR}


def project_stop(rdir, rec, detail):
    """Run the project's stop command in the run's worktree, unless a stop in this process already
    has. Returns what it exited with (None when it was not run), the detail with anything that went
    wrong added, and the project's stop_s."""
    doc = None
    try:
        with open(os.path.join(rdir, "areas.json"), errors="replace") as f:
            doc = json.load(f)
    except (OSError, ValueError) as e:
        detail = (detail + "; " if detail else "") + "areas.json copy unreadable, project stop not run: %s" % e
    stop_s = (doc or {}).get("timeouts", {}).get("stop_s", v.TIMEOUT_DEFAULTS["stop_s"])
    if rdir in STOP_COMMAND:
        if STOP_COMMAND[rdir] == "running":
            return None, (detail + "; " if detail else "") + "the project's stop command had not finished", stop_s
        return STOP_COMMAND[rdir], detail, stop_s
    wt = rec.get("worktree") or os.path.join(rdir, "worktree")
    stop_exit = None
    if doc and os.path.isdir(wt):
        STOP_COMMAND[rdir] = "running"
        stop_exit, out = run_project_command(doc["commands"]["stop"], wt, stop_s)
        STOP_COMMAND[rdir] = stop_exit
        if stop_exit != 0:
            detail = (detail + "; " if detail else "") + "project stop exited %s: %s" % (stop_exit, out[-200:])
    return stop_exit, detail, stop_s


def record_ending(rdir, **fields):
    """Write how a run ended, once. The first ending recorded is the one kept: a stop that finishes
    after its run was cut off changes nothing, and gets the receipt as it stands."""
    with ENDING:
        rec = read_receipt(rdir)
        if rec.get("stopped_at"):
            return rec
        return update_receipt(rdir, stopped_at=v.utc_now(), **fields)


def do_stop(rdir, reason, proc=None, detail=None, monitor=None, egress_why=None, killed_wait_s=None):
    """Stop serve, run the project's stop command, settle egress, remove the worktree, record it all.

    Serve gets stop_s to end once it is asked to, and killed_wait_s (KILLED_WAIT_S when not given)
    to be collected once it is killed. A serve that still cannot be collected ends the stop there
    and the run is cut off (see cut_off): a wait with no limit at that point is a stop that never
    returns, which is the state a supervisor was found in on 2026-11-26 (claude-config#3820)."""
    rec = read_receipt(rdir)
    stop_exit, detail, stop_s = project_stop(rdir, rec, detail)
    wt = rec.get("worktree") or os.path.join(rdir, "worktree")
    pgid = rec.get("serve_pgid")
    serve_exit = None
    if proc is not None:
        signal_group(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=stop_s)
        except subprocess.TimeoutExpired:
            signal_group(proc.pid, signal.SIGKILL)
            limit = KILLED_WAIT_S if killed_wait_s is None else killed_wait_s
            try:
                proc.wait(timeout=limit)
            except subprocess.TimeoutExpired:
                return cut_off(rdir, reason, "serve (process %s) was killed and still could not be collected"
                               " %ss later" % (proc.pid, limit), detail=detail, proc=proc, monitor=monitor)
        serve_exit = proc.returncode
    if pgid:
        signal_group(pgid, signal.SIGTERM)
        if not wait_gone(pgid, stop_s):
            signal_group(pgid, signal.SIGKILL)
            wait_gone(pgid, stop_s)
    survivors = live_members(pgid)
    egress_field = finish_egress(rdir, rec, monitor, egress_why or EGRESS_RECOVERED)
    removed = remove_worktree(rec["repo"], wt)
    return record_ending(rdir, stopped_by=reason, stop_detail=detail,
                         serve_exit=serve_exit, stop_command_exit=stop_exit, worktree_removed=removed,
                         serve_survivors=survivors, egress=egress_field)


def collect(pid, limit_s):
    """Collect a killed child of this process straight from the system, without its Popen. Returns
    its exit as a Popen gives one (minus the signal that ended it), or None when it had been
    collected already or was still not gone at the limit. A poll on the condition, with a limit."""
    deadline = time.monotonic() + limit_s
    while True:
        try:
            got, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return None
        if got == pid:
            return os.waitstatus_to_exitcode(status)
        if time.monotonic() >= deadline:
            return None
        time.sleep(GONE_POLL_S)


def cut_off(rdir, reason, why, detail=None, proc=None, monitor=None, collect_s=None):
    """End a run whose stop cannot finish, and record that it was cut off (claude-config#3682, #3807).

    Only a supervisor calls this: from the stop itself when a killed serve cannot be collected, or
    from the lifeline's thread when its caller is gone and the stop has not finished. It ends
    serve's group and the report stream's group by the ids the supervisor recorded, in the receipt
    or in the Popen it still holds, and never by matching a command (L1011). It collects serve
    straight from the system, since the lock inside serve's Popen may be the very thing the stop is
    stuck on. It runs the project's stop command if the stop had not, and removes the worktree.

    The receipt then says the run was cut off and why, and its egress is unmeasured. The monitor is
    never asked for a verdict here: a run that was cut off was not watched to its end, so no reading
    of it may pass for a measurement. A run whose ending is already recorded is left exactly as it
    is, and nothing is signalled."""
    with ENDING:
        rec = read_receipt(rdir)
        if rec.get("stopped_at"):
            return rec
        print("verification: cutting the run off: %s" % why, file=sys.stderr, flush=True)
        stream = getattr(monitor, "proc", None)
        serve_pgid = rec.get("serve_pgid") or (proc.pid if proc is not None else None)
        for pgid in dict.fromkeys((serve_pgid, rec.get("egress_monitor_pgid"),
                                   stream.pid if stream is not None else None)):
            if pgid:
                signal_group(pgid, signal.SIGKILL)
        serve_exit = None
        if proc is not None:
            serve_exit = proc.returncode
            if serve_exit is None:
                serve_exit = collect(proc.pid, KILLED_WAIT_S if collect_s is None else collect_s)
        detail = (detail + "; " if detail else "") + "the stop did not finish and the run was cut off: %s" % why
        stop_exit, detail, _ = project_stop(rdir, rec, detail)
        try:
            survivors = live_members(serve_pgid)
        except v.VerificationError as e:  # ps failed: said, and the ending still recorded
            survivors, detail = None, detail + "; whether serve's group is empty could not be read: %s" % e
        egress_why = EGRESS_CUT_OFF % why
        left = egress.remove_beat_program(rdir)
        if left:
            egress_why += "; " + left
        removed = remove_worktree(rec["repo"], rec.get("worktree") or os.path.join(rdir, "worktree"))
        return update_receipt(rdir, stopped_at=v.utc_now(), stopped_by=reason, stop_detail=detail,
                              serve_exit=serve_exit, stop_command_exit=stop_exit, worktree_removed=removed,
                              serve_survivors=survivors,
                              egress={"verdict": "unmeasured", "why": egress_why, "monitor": egress.MONITOR})


def leave_now():
    """End this supervisor at once, and with it whatever it was itself still waiting on (a ps, a git,
    the project's stop command): those run in the supervisor's own process group, which it leads."""
    try:
        sys.stderr.flush()
    except (OSError, ValueError):
        pass
    if os.getpgrp() == os.getpid():
        os.killpg(os.getpid(), signal.SIGKILL)
    os._exit(1)


def cut_off_and_leave(rdir, reason, why, proc=None, monitor=None, limit_s=None, leave=leave_now):
    """cut_off from a thread other than the supervisor's main one, and then the end of the process:
    the main thread is stuck in the stop, so nothing else would ever end it.

    The cut off has a limit of its own, limit_s (the project's stop_s and CUT_OFF_ROOM_S when not
    given), because it writes the receipt and runs ps and git, any of which can block. At the limit
    the process leaves anyway with no ending recorded, and a later `stop` finds the supervisor gone
    and records the run as recovered, which is unmeasured too."""
    if limit_s is None:
        limit_s = run_timeouts(rdir)["stop_s"] + CUT_OFF_ROOM_S
    timer = threading.Timer(limit_s, leave)
    timer.daemon = True
    timer.start()
    try:
        cut_off(rdir, reason, why, proc=proc, monitor=monitor)
    except Exception:
        traceback.print_exc()
    finally:
        timer.cancel()
        leave()


def run_timeouts(rdir):
    """The run's timeouts from its copy of areas.json, or the defaults where that cannot be read."""
    try:
        with open(os.path.join(rdir, "areas.json"), errors="replace") as f:
            return dict(v.TIMEOUT_DEFAULTS, **json.load(f)["timeouts"])
    except (OSError, ValueError, KeyError, TypeError):
        return dict(v.TIMEOUT_DEFAULTS)


# ---------------------------------------------------------------------------------------------
# supervise (the detached process start launches)


STOP_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)


def wake_main():
    signal.pthread_kill(threading.main_thread().ident, signal.SIGTERM)


def watch_lifeline(rdir, fd, gone, finished, limit_s, held, wake=wake_main, leave=leave_now):
    """End this supervisor's run once every holder of its caller's lifeline is gone (claude-config#3682).

    The read ends only when the kernel ends the pipe, which it does when the last holder of the
    write end dies, however it died. Anything written down the pipe is not a goodbye and is read
    past. Then `gone` is set and the stop is asked for as `stop` asks: a recorded reason and then a
    signal, aimed at the main thread, where the wait it must interrupt is. The signal is not sent
    when an earlier stop request already stands. A reason that cannot be written (a full disk) does
    not save the run: the signal is sent all the same, and `gone` is what says why. The thread is
    born with the stop signals blocked, so one sent from outside always lands on the main thread.

    Asking is not the end of it. The main thread sets `finished` when its stop is done, and this
    waits limit_s for that, whoever asked for the stop and whenever. A stop still not finished then
    is one that hung, as one asked for at 8:13 PM ET on 2026-11-26 did for good (claude-config#3820),
    and the run is cut off from here (see cut_off) with whatever `held` says the supervisor holds,
    its serve and its monitor, and this process ends."""
    try:
        while os.read(fd, 4096):
            pass
        why = "every holder of the lifeline it was started with is gone"
    except OSError as e:
        why = "its lifeline could not be read (%s: %s)" % (type(e).__name__, e)
    gone.set()
    print("verification: supervisor stopping the run: %s" % why, file=sys.stderr, flush=True)
    try:
        first = record_stop_reason(rdir, "caller_gone")
    except OSError as e:
        first = True
        print("verification: the reason for the stop could not be recorded (%s: %s); stopping all the same"
              % (type(e).__name__, e), file=sys.stderr, flush=True)
    if first:
        wake()
    if finished.wait(limit_s):
        return
    asked = requested_reason(rdir, "caller_gone")
    what = "the stop that followed" if asked == "caller_gone" else "a stop asked for earlier (%s)" % asked
    proc, monitor = held()
    cut_off_and_leave(rdir, "caller_gone", "its caller was gone and %s had not finished %ss later"
                      % (what, round(limit_s, 1)), proc=proc, monitor=monitor, leave=leave)


def supervise(rdir, repo_lock_fd, pipe_w, lifeline_fd=None):
    # repo_lock_fd stays open, unread, for this process's whole life: holding it is the point.
    sup = open(os.path.join(rdir, "supervisor.lock"), "a", errors="replace")
    fcntl.flock(sup, fcntl.LOCK_EX)

    # A stop signal is acted on once, and never while children are being started (the #3807 review).
    # Until every child's pid and group is in the receipt it is only noted, and acted on when they
    # are: a stop that broke into the start of a child would leave that child running in a session
    # of its own with nothing recorded to stop it by. It is held HERE, in the handler, and not by
    # blocking the signals, because a blocked signal is inherited by every child started meanwhile
    # and serve would then never see the SIGTERM that stops it. And the first stop to be acted on
    # has every later one ignored before it raises, so none can break into the stop under way.
    gate = {"recorded": False, "asked": False}

    def on_signal(signum, frame):
        if not gate["recorded"]:
            gate["asked"] = True
            return
        for s in STOP_SIGNALS:
            signal.signal(s, signal.SIG_IGN)
        raise StopRequested()

    for s in STOP_SIGNALS:
        signal.signal(s, on_signal)
    proc, monitor = None, None
    outcome = None  # (why the run ended, the detail), bound once and whole so a signal cannot split it
    gone, finished = threading.Event(), threading.Event()
    try:
        try:
            with open(os.path.join(rdir, "areas.json"), errors="replace") as f:
                doc = json.load(f)
            rec = read_receipt(rdir)
            if lifeline_fd is not None:
                # Long enough that only a stop that hung is cut off, never one that is merely slow.
                limit = stop_longest_s(doc["timeouts"]) * time_scale("VERIFICATION_STOP_LIMIT_SCALE")
                signal.pthread_sigmask(signal.SIG_BLOCK, STOP_SIGNALS)  # inherited by the thread made next
                try:
                    threading.Thread(target=watch_lifeline, daemon=True,
                                     args=(rdir, lifeline_fd, gone, finished, limit, lambda: (proc, monitor))).start()
                finally:
                    signal.pthread_sigmask(signal.SIG_UNBLOCK, STOP_SIGNALS)  # before any child is started
            # The egress monitor starts BEFORE serve, so it covers serve's whole life, and is proved live
            # by its canary first. One that cannot start leaves serve running unwrapped and the verdict
            # unmeasured with its reason: a run is never refused for it, and never called clean.
            monitor = egress.Monitor(rdir, rec["receipt_id"], doc["egress"]["allow"], doc["timeouts"]["egress_s"])
            unavailable = monitor.start()
            wrap = None if unavailable else [monitor.sandbox, "-f", monitor.profile]
            update_receipt(rdir, egress_sandbox=wrap,
                           egress_monitor_pgid=None if unavailable else monitor.proc.pid)
            if v.serves(doc):
                log = open(os.path.join(rdir, "serve.log"), "ab")
                proc = subprocess.Popen((wrap or []) + ["/bin/sh", "-c", doc["commands"]["serve"]],
                                        cwd=rec["worktree"], start_new_session=True, stdin=subprocess.DEVNULL,
                                        stdout=log, stderr=subprocess.STDOUT)
                update_receipt(rdir, supervisor_pid=os.getpid(), serve_pid=proc.pid, serve_pgid=proc.pid)
            else:
                # Every area is native and nothing is served (claude-config#2951): the supervisor still
                # holds the run, its lock and its egress monitor, until a stop or the deadline.
                update_receipt(rdir, supervisor_pid=os.getpid())
            gate["recorded"] = True  # every child is recorded: a stop may be acted on from here
            if gate["asked"]:
                on_signal(None, None)
            os.write(pipe_w, b"ok\n")
            os.close(pipe_w)
            pipe_w = None
            if proc is None:
                time.sleep(deadline_s(doc))  # a stop signal raises StopRequested out of the sleep
                outcome = ("deadline", None)
            else:
                try:
                    exited = proc.wait(timeout=deadline_s(doc))
                    outcome = ("serve_exited", "serve exited by itself with %s" % exited)
                except subprocess.TimeoutExpired:
                    outcome = ("deadline", None)
        except StopRequested:
            if outcome is None:  # else the run had already ended another way, and that stands
                outcome = (requested_reason(rdir, "caller_gone" if gone.is_set() else "stop"), None)
        except Exception as e:
            outcome = ("supervisor_error", "%s: %s" % (type(e).__name__, e))
            traceback.print_exc()
        finally:
            for s in STOP_SIGNALS:
                signal.signal(s, signal.SIG_IGN)
    except StopRequested:
        pass  # the one stop that is ever acted on, landing after the wait was over: `outcome` stands
    finally:
        if pipe_w is not None:
            os.close(pipe_w)  # start reads end of file with no "ok": the supervisor failed
        reason, detail = outcome or ("supervisor_error", None)
        do_stop(rdir, reason, proc=proc, detail=detail, monitor=monitor,
                egress_why="the supervisor stopped (%s) before the egress monitor existed" % reason)
        finished.set()
    return 0


# ---------------------------------------------------------------------------------------------
# start


def repo_lock(home, repo):
    os.makedirs(os.path.join(home, "locks"), exist_ok=True)
    key = hashlib.sha256(repo.encode("utf-8", "surrogatepass")).hexdigest()[:16]
    return os.path.join(home, "locks", key + ".lock")


def abandon_start(err, repo, rdir, wt, lock_fd, opened=()):
    """Undo a start whose setup failed, record why, and raise the failure. Never returns.

    Runs for every failure, a named refusal or not (claude-config#1570). The original error is never
    replaced (L11): a VerificationError keeps its own problems, any other Exception becomes a named
    refusal carrying its own type and message, and an interrupt is raised again as itself. A cleanup
    step that fails is reported beside the original rather than hiding it, the steps after it still
    run, and the project's lock is released whatever happens.
    """
    if isinstance(err, v.VerificationError):
        stopped_by, detail = "start_failed", str(err)
    else:
        stopped_by = "start_error" if isinstance(err, Exception) else "start_interrupted"
        detail = "%s: %s" % (type(err).__name__, err) if str(err) else type(err).__name__
    detail = detail[:500]
    cleanup = []
    removed = False
    try:
        try:
            removed = remove_worktree(repo, wt)
            if not removed:
                cleanup.append("the worktree %s is still there or still listed by git; remove it with:"
                               " git -C %s worktree remove --force %s" % (wt, repo, wt))
        except Exception as e:
            cleanup.append("removing the worktree %s failed: %s: %s" % (wt, type(e).__name__, e))
        try:
            update_receipt(rdir, stopped_at=v.utc_now(), stopped_by=stopped_by, worktree_removed=removed,
                           stop_detail="; ".join([detail] + cleanup),
                           egress={"verdict": "unmeasured", "monitor": egress.MONITOR,
                                   "why": "setup failed before serve started, so nothing was measured"})
        except Exception as e:
            cleanup.append("the stop could not be recorded in %s: %s: %s"
                           % (receipt_path(rdir), type(e).__name__, e))
    finally:
        for f in opened:
            # A descriptor this process opened a moment ago; closing it cannot lose anything, and
            # the cleanup's outcome is already decided above.
            with contextlib.suppress(OSError):
                if isinstance(f, int):
                    os.close(f)
                else:
                    f.close()
        os.close(lock_fd)
    problems = [("start-cleanup-failed", m) for m in cleanup]
    if isinstance(err, v.VerificationError):
        if not problems:
            raise err
        raise v.VerificationError(err.problems + problems) from err
    if isinstance(err, Exception):
        kind = "disk-full" if isinstance(err, OSError) and err.errno == errno.ENOSPC else "start-error"
        raise v.VerificationError([(kind, "setting up run %s failed before serve started: %s"
                                    % (os.path.basename(rdir), detail))] + problems) from err
    for kind, message in problems:
        print("verification: %s: %s" % (kind, message), file=sys.stderr)
    raise err


def caller_lifeline():
    """The descriptor VERIFICATION_LIFELINE_FD names, or None when it is unset (claude-config#3682).

    Refused unless it is the READ end of a pipe: a write end held by the supervisor itself would keep
    the pipe open for ever, and anything else never ends when its caller does, so either would read
    as a lifeline that simply had not fired."""
    raw = os.environ.get("VERIFICATION_LIFELINE_FD", "")
    if raw == "":
        return None
    try:
        fd = int(raw)
        mode, flags = os.fstat(fd).st_mode, fcntl.fcntl(fd, fcntl.F_GETFL)
    except (ValueError, OSError) as e:
        v.fail("lifeline-bad", "VERIFICATION_LIFELINE_FD=%r names no open descriptor (%s)" % (raw, e))
    if not stat.S_ISFIFO(mode) or flags & os.O_ACCMODE != os.O_RDONLY:
        v.fail("lifeline-bad", "VERIFICATION_LIFELINE_FD=%r is not the read end of a pipe, so the run could"
               " never see its caller go" % raw)
    return fd


def start(repo, sha, areas_csv):
    if not v.SHA_RE.match(sha or ""):
        v.fail("bad-sha", "%r is not a full 40 character commit SHA (use the PR's headRefOid)" % sha)
    repo = os.path.realpath(repo)
    top = git(repo, "rev-parse", "--show-toplevel", check=False)
    if top.returncode != 0:
        v.fail("repo-not-git", "%s is not a git checkout" % repo)
    repo = os.path.realpath(top.stdout.strip())
    if git(repo, "cat-file", "-e", sha + "^{commit}", check=False).returncode != 0:
        v.fail("commit-missing", "commit %s is not in %s; fetch it first: git -C %s fetch origin pull/<number>/head"
               % (sha, repo, repo))
    shown = git(repo, "show", "%s:%s" % (sha, v.AREAS_PATH), check=False)
    if shown.returncode != 0:
        v.fail("areas-missing", "%s has no %s: this project has not opted in to verification guides"
               % (sha[:7], v.AREAS_PATH))
    doc = v.parse_areas(shown.stdout)
    wanted = [a.strip() for a in (areas_csv or "").split(",") if a.strip()]
    if not wanted:
        v.fail("bad-areas", "--areas needs at least one area name")
    unknown = [a for a in wanted if a not in v.area_names(doc)]
    if unknown:
        v.fail("area-unknown", "%s %s not defined in areas.json at %s (it defines %s)"
               % (", ".join(unknown), "is" if len(unknown) == 1 else "are", sha[:7], ", ".join(v.area_names(doc))))
    lifeline = caller_lifeline()

    home = v.verification_home()
    lock_fd = os.open(repo_lock(home, repo), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        holder = os.read(lock_fd, 200).decode(errors="replace").strip()
        os.close(lock_fd)
        v.fail("run-busy", "a verification run of %s is live (receipt %s): stop it with run_session.py stop %s"
               % (repo, holder or "unknown", holder or "<id>"))

    rid = "%s-%s-%s" % (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()), sha[:7], secrets.token_hex(3))
    rdir = v.receipt_dir(rid, home)
    wt = os.path.join(rdir, "worktree")
    # Everything from here until the supervisor exists is setup, and ANY failure in it (a named
    # refusal, a full disk, an interrupt) gets the same cleanup: nothing else would remove the
    # worktree or record why the run never started (claude-config#1570).
    opened = []  # descriptors and files setup opened, closed again if it fails
    try:
        os.makedirs(os.path.join(rdir, "guides"))
        os.ftruncate(lock_fd, 0)
        os.lseek(lock_fd, 0, os.SEEK_SET)
        os.write(lock_fd, rid.encode("utf-8", "replace"))
        update_receipt(rdir, schema=v.RECEIPT_SCHEMA, receipt_id=rid, machine=v.machine_name(), repo=repo,
                       head_sha=sha, checkout_sha=None, areas=wanted, url=doc.get("url"), started_at=v.utc_now(),
                       ready_at=None, stopped_at=None, stopped_by=None, stop_detail=None, serve_exit=None,
                       stop_command_exit=None, worktree=wt, worktree_removed=False, supervisor_pid=None,
                       serve_pid=None, serve_pgid=None, build_stamp=None, build_stamp_source="none",
                       egress={"verdict": "unmeasured", "why": EGRESS_WHY}, egress_sandbox=None,
                       egress_monitor_pgid=None, drives="drives.jsonl")
        git(repo, "worktree", "add", "--detach", wt, sha)
        checkout = git(wt, "rev-parse", "HEAD").stdout.strip()
        update_receipt(rdir, checkout_sha=checkout)
        if checkout != sha:
            v.fail("checkout-mismatch", "the worktree is at %s, not %s" % (checkout, sha))
        doc = v.load_areas(os.path.join(wt, v.AREAS_PATH), root=wt)
        with open(os.path.join(rdir, "areas.json"), "w", errors="replace") as f:
            json.dump(doc, f, indent=2)  # with timeouts filled, so the supervisor reads one shape
        for area in doc["areas"]:
            if area["name"] in wanted:
                v.load_guide(os.path.join(wt, area["guide"]))
                shutil.copyfile(os.path.join(wt, area["guide"]), os.path.join(rdir, "guides", area["name"] + ".md"))
        r_fd, w_fd = os.pipe()
        opened.extend((r_fd, w_fd))
        log = open(os.path.join(rdir, "supervisor.log"), "ab")
        opened.append(log)
        # A lifeline goes to the supervisor alone, as an argument: serve and the commands it runs
        # neither hold it nor see the variable naming it.
        tie = [] if lifeline is None else [lifeline]
        sup_env = {k: val for k, val in os.environ.items() if k != "VERIFICATION_LIFELINE_FD"}
        sup = subprocess.Popen([sys.executable, os.path.abspath(__file__), "_supervise", rdir, str(lock_fd),
                                str(w_fd)] + [str(fd) for fd in tie], pass_fds=(lock_fd, w_fd, *tie),
                               start_new_session=True, env=sup_env,
                               stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, cwd=rdir)
    except BaseException as e:
        abandon_start(e, repo, rdir, wt, lock_fd, opened)
    os.close(w_fd)
    os.close(lock_fd)  # the supervisor holds the project's lock from here on
    said = b""
    while True:
        chunk = os.read(r_fd, 64)
        if not chunk:
            break
        said += chunk
    os.close(r_fd)
    if not said.startswith(b"ok"):
        exited = sup.poll()
        wait_for_supervisor(rdir, timeout_s=stop_wait_s(doc["timeouts"]))
        v.fail("supervisor-failed", "the supervisor did not start serve (exit %s): %s"
               % (exited, tail(os.path.join(rdir, "supervisor.log"))))

    t = doc["timeouts"]
    attempts = max(1, int(math.ceil(t["ready_s"] / t["ready_interval_s"])))
    # With nothing served there is nothing to wait for: the run is ready once the supervisor is up.
    ready, last = not v.serves(doc), ""
    for i in range(attempts if v.serves(doc) else 0):
        rec = read_receipt(rdir)
        if rec.get("stopped_at"):
            v.fail("serve-stopped", "serve stopped before it was ready (%s); serve.log: %s"
                   % (rec.get("stopped_by"), tail(os.path.join(rdir, "serve.log"))))
        code, last = run_project_command(doc["commands"]["ready"], wt, min(READY_ATTEMPT_MAX_S, t["ready_s"]))
        if code == 0:
            ready = True
            break
        if i < attempts - 1:
            nap(t["ready_interval_s"])
    if not ready:
        request_stop(rdir, "ready_failed")
        wait_for_supervisor(rdir, timeout_s=stop_wait_s(t))
        v.fail("ready-timeout", "the ready command never succeeded in %d attempts over %ss; last output: %s;"
               " serve.log: %s" % (attempts, t["ready_s"], last[-200:] or "(none)", tail(os.path.join(rdir, "serve.log"))))

    stamp, source = None, "none"
    if doc["commands"].get("stamp"):
        code, out = run_project_command(doc["commands"]["stamp"], wt, READY_ATTEMPT_MAX_S)
        line = out.strip().splitlines()[-1].strip() if out.strip() else ""
        stamp, source = (line, "stamp-command") if code == 0 and line else (None, "stamp-failed")
    rec = update_receipt(rdir, ready_at=v.utc_now(), build_stamp=stamp, build_stamp_source=source)
    if rec.get("stopped_at"):
        v.fail("serve-stopped", "serve stopped as it became ready (%s)" % rec.get("stopped_by"))
    print(json.dumps({"receipt_id": rid, "receipt_dir": rdir, "url": doc.get("url"), "worktree": wt,
                      "build_stamp": stamp, "build_stamp_source": source}))
    return 0


# ---------------------------------------------------------------------------------------------
# drive, stop, status


def drive(rid, area, args):
    rdir = v.receipt_dir(rid)
    rec = v.load_receipt(rid)
    if rec.get("stopped_at"):
        v.fail("run-stopped", "run %s has stopped (%s); start a new run" % (rid, rec.get("stopped_by")))
    if area not in rec.get("areas", []):
        v.fail("area-not-in-run", "area %r is not one this run serves (%s)" % (area, ", ".join(rec.get("areas", []))))
    if not supervisor_alive(rdir):
        v.fail("run-stopped", "the supervisor of run %s is gone; run run_session.py stop %s" % (rid, rid))
    with open(os.path.join(rdir, "areas.json"), errors="replace") as f:
        doc = json.load(f)
    env = dict(os.environ, VERIFICATION_RECEIPT_DIR=rdir, VERIFICATION_WORKTREE=rec["worktree"],
               VERIFICATION_AREA=area)
    env.pop("VERIFICATION_URL", None)  # set only when this run serves, never inherited (claude-config#2951)
    if rec.get("url"):
        env["VERIFICATION_URL"] = rec["url"]
    # Under the same reporting sandbox as serve, so the run's egress verdict covers the drive helper
    # too. None when the monitor could not start, and then the verdict is already unmeasured.
    wrap = rec.get("egress_sandbox") or []
    r = subprocess.run(list(wrap) + ["/bin/sh", "-c", doc["commands"]["drive"] + ' "$@"', "sh"] + list(args),
                       cwd=rec["worktree"], env=env)
    line = json.dumps({"at": v.utc_now(), "area": area, "args": list(args), "exit": r.returncode}) + "\n"
    fd = os.open(os.path.join(rdir, "drives.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.write(fd, line.encode("ascii", "strict"))
    os.close(fd)
    if r.returncode != 0:
        v.fail("drive-failed", "the drive helper exited %d" % r.returncode)
    return 0


def summary(rec):
    keys = ("receipt_id", "head_sha", "stopped_at", "stopped_by", "stop_detail", "serve_exit",
            "stop_command_exit", "worktree_removed", "serve_survivors")
    return json.dumps({k: rec.get(k) for k in keys})


def stop(rid):
    rdir = v.receipt_dir(rid)
    rec = v.load_receipt(rid)
    if not rec.get("stopped_at"):
        request_stop(rdir, "stop")
        with open(os.path.join(rdir, "areas.json"), errors="replace") as f:
            timeouts = json.load(f)["timeouts"]
        wait_for_supervisor(rdir, timeout_s=stop_wait_s(timeouts))
        rec = read_receipt(rdir)
        if not rec.get("stopped_at"):
            # The supervisor is gone and stopped nothing: killed outright. Do its work here, holding
            # its lock so two recoveries cannot overlap.
            with open(os.path.join(rdir, "supervisor.lock"), "a", errors="replace") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                rec = read_receipt(rdir)
                if not rec.get("stopped_at"):
                    rec = do_stop(rdir, "recovered", detail="the supervisor was gone without stopping serve")
    print(summary(rec))
    if rec.get("serve_survivors"):
        v.fail("serve-survived", "serve processes %s outlived the stop" % rec["serve_survivors"])
    return 0


def status(rid):
    print(json.dumps(v.load_receipt(rid), indent=2))
    return 0


def main(argv):
    if argv[:1] == ["_supervise"] and len(argv) in (4, 5):
        return supervise(argv[1], int(argv[2]), int(argv[3]), int(argv[4]) if len(argv) == 5 else None)
    if argv[:1] == ["drive"]:
        # Written out rather than argparse, whose remainder would swallow --area: exactly
        # `drive <receipt id> --area <name> -- <helper arguments>`.
        if len(argv) < 5 or argv[2] != "--area" or argv[4] != "--":
            print("verification: usage: run_session.py drive <receipt id> --area <name> -- <helper arguments>",
                  file=sys.stderr)
            return 2
        argv_drive = argv
    else:
        argv_drive = None
    ap = argparse.ArgumentParser(prog="run_session.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("start")
    s.add_argument("--repo", required=True)
    s.add_argument("--sha", required=True)
    s.add_argument("--areas", required=True)
    for name in ("stop", "status"):
        sub.add_parser(name).add_argument("receipt_id")
    a = ap.parse_args(argv) if argv_drive is None else None
    try:
        if argv_drive is not None:
            return drive(argv_drive[1], argv_drive[3], argv_drive[5:])
        if a.cmd == "start":
            return start(a.repo, a.sha, a.areas)
        if a.cmd == "stop":
            return stop(a.receipt_id)
        return status(a.receipt_id)
    except v.VerificationError as e:
        for kind, msg in e.problems:
            print("verification: %s: %s" % (kind, msg), file=sys.stderr)
        return e.code
    except OSError as e:
        if e.errno == errno.ENOSPC:
            print("verification: disk-full: %s" % e, file=sys.stderr)
            return 8
        raise


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main(sys.argv[1:]))
