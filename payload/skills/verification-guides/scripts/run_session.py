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

Serve is stopped on EVERY path, which is why a supervisor and not the caller owns it. The
supervisor is a detached process that started serve in a process group of its own, holds a lock
for exactly as long as it lives, and stops serve, runs the project's stop command and removes the
worktree when any of these happens first: `stop` asks it to, the ready command never succeeds,
serve exits by itself, the run's deadline (timeouts.max_run_s) passes, or the supervisor itself
fails. If the supervisor is killed outright, `stop` sees its lock free with no stop recorded and
does the same work itself, by the process group it recorded (L1011). Waiting for the end of a run
is waiting for that lock, never a poll of a fixed length (L290).

One run per project at a time: the supervisor also holds a lock keyed by the checkout's path, so a
second `start` is refused with the live run's receipt id rather than fighting it for the port.

The receipt (verification-receipt/1, read through verification.py) records what the harness
measured: the machine, the head and the commit actually checked out, when serve started, became
ready and stopped and why, the build stamp the project's optional stamp command printed, and every
drive call. It also records `egress: unmeasured`, because nothing in this repository can yet show
that the served app reached nothing outside this machine; that is stated, never faked.

Env: VERIFICATION_HOME (see verification.py). Two injectable clocks (L524), each a number of at
least 0 that multiplies seconds, default 1: VERIFICATION_TIME_SCALE scales every poll delay (the
ready interval, the wait for a stopped process group to empty), VERIFICATION_DEADLINE_SCALE scales
the run's deadline. They are separate so a test can make the ready polls immediate without also
firing the deadline.

Exit codes are verification.py's: 0 ok, 2 usage, 3 not found, 4 refused, 5 busy, 8 the run failed.
"""

import argparse
import errno
import fcntl
import hashlib
import json
import math
import os
import secrets
import shutil
import signal
import subprocess
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verification as v  # noqa: E402

EGRESS_WHY = ("no egress monitor exists for verification runs yet, so this run cannot show that the"
              " served app reached nothing outside this machine")
STOP_REASONS = ("stop", "ready_failed")
READY_ATTEMPT_MAX_S = 30
GONE_POLL_S = 0.05


class StopRequested(Exception):
    pass


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
    r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True)
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
    with open(receipt_path(rdir)) as f:
        return json.load(f)


def update_receipt(rdir, **fields):
    """Merge fields into the receipt under its own lock, written whole and renamed into place."""
    with open(os.path.join(rdir, "receipt.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            rec = read_receipt(rdir)
        except FileNotFoundError:
            rec = {}
        rec.update(fields)
        tmp = receipt_path(rdir) + ".tmp"
        with open(tmp, "w") as f:
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
    with open(path, "a") as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(f, fcntl.LOCK_UN)
        return False


def wait_for_supervisor(rdir, timeout_s):
    """Block until the supervisor has exited, however it exited. Returns nothing; raises when hung."""
    f = open(os.path.join(rdir, "supervisor.lock"), "a")

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


def request_stop(rdir, reason):
    try:
        fd = os.open(os.path.join(rdir, "stop-reason"), os.O_WRONLY | os.O_CREAT | os.O_EXCL)
    except FileExistsError:
        fd = None  # an earlier request stands, and its reason is the one recorded
    if fd is not None:
        os.write(fd, reason.encode())
        os.close(fd)
    rec = read_receipt(rdir)
    pid = rec.get("supervisor_pid")
    # Signal only a supervisor whose lock is held, so a recycled pid is never signalled (L1011).
    if pid and supervisor_alive(rdir):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            return  # it exited between the lock check and the signal; the wait that follows sees it


def requested_reason(rdir):
    try:
        with open(os.path.join(rdir, "stop-reason")) as f:
            reason = f.read().strip()
    except FileNotFoundError:
        return "stop"
    return reason if reason in STOP_REASONS else "stop"


# ---------------------------------------------------------------------------------------------
# stopping


def live_members(pgid):
    if not pgid:
        return []
    out = subprocess.run(["ps", "-A", "-o", "pid=,pgid=,stat="], capture_output=True, text=True)
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
                           timeout=timeout_s, env=env)
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


def do_stop(rdir, reason, proc=None, detail=None):
    """Stop serve, run the project's stop command, remove the worktree, record it all."""
    rec = read_receipt(rdir)
    doc = None
    try:
        with open(os.path.join(rdir, "areas.json")) as f:
            doc = json.load(f)
    except (OSError, ValueError) as e:
        detail = (detail + "; " if detail else "") + "areas.json copy unreadable, project stop not run: %s" % e
    stop_s = (doc or {}).get("timeouts", {}).get("stop_s", v.TIMEOUT_DEFAULTS["stop_s"])
    wt = rec.get("worktree") or os.path.join(rdir, "worktree")
    stop_exit = None
    if doc and os.path.isdir(wt):
        stop_exit, out = run_project_command(doc["commands"]["stop"], wt, stop_s)
        if stop_exit != 0:
            detail = (detail + "; " if detail else "") + "project stop exited %s: %s" % (stop_exit, out[-200:])
    pgid = rec.get("serve_pgid")
    serve_exit = None
    if proc is not None:
        signal_group(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=stop_s)
        except subprocess.TimeoutExpired:
            signal_group(proc.pid, signal.SIGKILL)
            proc.wait()
        serve_exit = proc.returncode
    if pgid:
        signal_group(pgid, signal.SIGTERM)
        if not wait_gone(pgid, stop_s):
            signal_group(pgid, signal.SIGKILL)
            wait_gone(pgid, stop_s)
    survivors = live_members(pgid)
    removed = remove_worktree(rec["repo"], wt)
    return update_receipt(rdir, stopped_at=v.utc_now(), stopped_by=reason, stop_detail=detail,
                          serve_exit=serve_exit, stop_command_exit=stop_exit, worktree_removed=removed,
                          serve_survivors=survivors)


# ---------------------------------------------------------------------------------------------
# supervise (the detached process start launches)


def supervise(rdir, repo_lock_fd, pipe_w):
    # repo_lock_fd stays open, unread, for this process's whole life: holding it is the point.
    sup = open(os.path.join(rdir, "supervisor.lock"), "a")
    fcntl.flock(sup, fcntl.LOCK_EX)

    def on_signal(signum, frame):
        raise StopRequested()

    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(s, on_signal)
    proc, reason, detail = None, "supervisor_error", None
    try:
        with open(os.path.join(rdir, "areas.json")) as f:
            doc = json.load(f)
        rec = read_receipt(rdir)
        log = open(os.path.join(rdir, "serve.log"), "ab")
        proc = subprocess.Popen(["/bin/sh", "-c", doc["commands"]["serve"]], cwd=rec["worktree"],
                                start_new_session=True, stdin=subprocess.DEVNULL, stdout=log,
                                stderr=subprocess.STDOUT)
        update_receipt(rdir, supervisor_pid=os.getpid(), serve_pid=proc.pid, serve_pgid=proc.pid)
        os.write(pipe_w, b"ok\n")
        os.close(pipe_w)
        pipe_w = None
        try:
            exited = proc.wait(timeout=deadline_s(doc))
            reason, detail = "serve_exited", "serve exited by itself with %s" % exited
        except subprocess.TimeoutExpired:
            reason = "deadline"
    except StopRequested:
        reason = requested_reason(rdir)
    except Exception as e:
        reason, detail = "supervisor_error", "%s: %s" % (type(e).__name__, e)
        traceback.print_exc()
    finally:
        for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(s, signal.SIG_IGN)
        if pipe_w is not None:
            os.close(pipe_w)  # start reads end of file with no "ok": the supervisor failed
        do_stop(rdir, reason, proc=proc, detail=detail)
    return 0


# ---------------------------------------------------------------------------------------------
# start


def repo_lock(home, repo):
    os.makedirs(os.path.join(home, "locks"), exist_ok=True)
    key = hashlib.sha256(repo.encode()).hexdigest()[:16]
    return os.path.join(home, "locks", key + ".lock")


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
    os.makedirs(os.path.join(rdir, "guides"))
    os.ftruncate(lock_fd, 0)
    os.lseek(lock_fd, 0, os.SEEK_SET)
    os.write(lock_fd, rid.encode())
    wt = os.path.join(rdir, "worktree")
    update_receipt(rdir, schema=v.RECEIPT_SCHEMA, receipt_id=rid, machine=v.machine_name(), repo=repo,
                   head_sha=sha, checkout_sha=None, areas=wanted, url=doc["url"], started_at=v.utc_now(),
                   ready_at=None, stopped_at=None, stopped_by=None, stop_detail=None, serve_exit=None,
                   stop_command_exit=None, worktree=wt, worktree_removed=False, supervisor_pid=None,
                   serve_pid=None, serve_pgid=None, build_stamp=None, build_stamp_source="none",
                   egress={"verdict": "unmeasured", "why": EGRESS_WHY}, drives="drives.jsonl")

    def abandon(err):
        removed = remove_worktree(repo, wt)
        update_receipt(rdir, stopped_at=v.utc_now(), stopped_by="start_failed",
                       stop_detail=str(err)[:500], worktree_removed=removed)
        os.close(lock_fd)
        raise err

    try:
        git(repo, "worktree", "add", "--detach", wt, sha)
        checkout = git(wt, "rev-parse", "HEAD").stdout.strip()
        update_receipt(rdir, checkout_sha=checkout)
        if checkout != sha:
            v.fail("checkout-mismatch", "the worktree is at %s, not %s" % (checkout, sha))
        doc = v.load_areas(os.path.join(wt, v.AREAS_PATH), root=wt)
        with open(os.path.join(rdir, "areas.json"), "w") as f:
            json.dump(doc, f, indent=2)  # with timeouts filled, so the supervisor reads one shape
        for area in doc["areas"]:
            if area["name"] in wanted:
                v.load_guide(os.path.join(wt, area["guide"]))
                shutil.copyfile(os.path.join(wt, area["guide"]), os.path.join(rdir, "guides", area["name"] + ".md"))
    except v.VerificationError as e:
        abandon(e)

    r_fd, w_fd = os.pipe()
    log = open(os.path.join(rdir, "supervisor.log"), "ab")
    sup = subprocess.Popen([sys.executable, os.path.abspath(__file__), "_supervise", rdir, str(lock_fd), str(w_fd)],
                           pass_fds=(lock_fd, w_fd), start_new_session=True, stdin=subprocess.DEVNULL,
                           stdout=log, stderr=subprocess.STDOUT, cwd=rdir)
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
        wait_for_supervisor(rdir, timeout_s=120)
        v.fail("supervisor-failed", "the supervisor did not start serve (exit %s): %s"
               % (exited, tail(os.path.join(rdir, "supervisor.log"))))

    t = doc["timeouts"]
    attempts = max(1, int(math.ceil(t["ready_s"] / t["ready_interval_s"])))
    ready, last = False, ""
    for i in range(attempts):
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
        wait_for_supervisor(rdir, timeout_s=t["stop_s"] * 2 + 30)
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
    print(json.dumps({"receipt_id": rid, "receipt_dir": rdir, "url": doc["url"], "worktree": wt,
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
    with open(os.path.join(rdir, "areas.json")) as f:
        doc = json.load(f)
    env = dict(os.environ, VERIFICATION_URL=rec["url"], VERIFICATION_RECEIPT_DIR=rdir,
               VERIFICATION_WORKTREE=rec["worktree"], VERIFICATION_AREA=area)
    r = subprocess.run(["/bin/sh", "-c", doc["commands"]["drive"] + ' "$@"', "sh"] + list(args),
                       cwd=rec["worktree"], env=env)
    line = json.dumps({"at": v.utc_now(), "area": area, "args": list(args), "exit": r.returncode}) + "\n"
    fd = os.open(os.path.join(rdir, "drives.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.write(fd, line.encode())
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
        with open(os.path.join(rdir, "areas.json")) as f:
            stop_s = json.load(f)["timeouts"]["stop_s"]
        wait_for_supervisor(rdir, timeout_s=stop_s * 2 + 30)
        rec = read_receipt(rdir)
        if not rec.get("stopped_at"):
            # The supervisor is gone and stopped nothing: killed outright. Do its work here, holding
            # its lock so two recoveries cannot overlap.
            with open(os.path.join(rdir, "supervisor.lock"), "a") as lock:
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
    if argv[:1] == ["_supervise"] and len(argv) == 4:
        return supervise(argv[1], int(argv[2]), int(argv[3]))
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
    sys.exit(main(sys.argv[1:]))
