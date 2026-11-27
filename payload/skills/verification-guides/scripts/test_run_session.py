"""Tests for run_session.py, the RUN harness (claude-config#1528).

Each test builds a throwaway git repository whose areas.json serves a fake app: a Python process
that writes its pid, then blocks writing to a FIFO until the ready command reads it, then waits for
a signal. Nothing here sleeps or waits a fixed time (L290, L524): readiness is the FIFO, the end of
a run is the supervisor's own lock, and VERIFICATION_TIME_SCALE=0 (the poll delays) and
VERIFICATION_DEADLINE_SCALE=0 (the run deadline) make those immediate where a test needs them.

Serve must stop on every path, so every way a run can end is driven here: a normal stop, a ready
command that never succeeds, serve dying by itself, the deadline, the supervisor killed outright, the
caller going away while the run is starting or once it is up, and a stop that hangs.

No test may leave a process behind (the #3807 review). Every run a test starts is tied to the test
process by a lifeline, every stand in that holds a supervisor waits on a lock the test process
alone holds, and the stand ins for serve and the suite the last class starts read a pipe only the
test writes, so each ends when the test process does, however that went. The one exception is on
purpose: the run the last class starts with NO lifeline can be tied to nothing, and its bound is a
shortened deadline. Where a fault cannot be had without a race, a stand in blocks the thing waited
on; no test sleeps to give a fault time to happen.
"""

import contextlib
import errno
import fcntl
import io
import json
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True  # a module beside this one is carried by the sync: leave no cache (#2919)
sys.path.insert(0, HERE)

import run_session  # noqa: E402
import verification as v  # noqa: E402

GUIDE = """# Invoices verification guide

## Roles
An owner.

## Reach
Open /invoices.

## State setup
Seed data.

## Checks
- [C1] The list loads.
- [C2] An invoice opens.
- [C3] A draft sends.

## Known traps
None yet.
"""

FAKE_SERVE = r'''
import os, signal, socket, sys
d = os.environ["FAKE_DIR"]
with open(os.path.join(d, "serve.pid"), "w") as f:
    f.write(str(os.getpid()))
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
held = []
# FAKE_CONNECT: "local" reaches this machine only, by TCP over 127.0.0.1 and UDP over ::1;
# "outside" opens a TCP connection to 192.0.2.1 (TEST-NET-1, reserved for documentation, so no
# real host ever answers) and holds it open while serve runs.
if os.environ.get("FAKE_CONNECT") == "local":
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    c = socket.create_connection(srv.getsockname())
    u = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    u.connect(("::1", 9))
    held += [srv, c, u]
elif os.environ.get("FAKE_CONNECT") == "outside":
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setblocking(False)
    try:
        s.connect(("192.0.2.1", 9))
    except BlockingIOError:
        pass
    held.append(s)
with open(os.path.join(d, "ready.fifo"), "w") as f:
    f.write("ready")
while True:
    signal.pause()
'''

DRIVE = r'''printf '%s\n' "$@" > "$FAKE_DIR/drive-args"
printf '%s' "$VERIFICATION_URL" > "$FAKE_DIR/drive-url"
: > "$VERIFICATION_RECEIPT_DIR/shot.png"
'''


def git(repo, *args):
    r = subprocess.run(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com",
                        "-c", "commit.gpgsign=false"] + list(args), capture_output=True, text=True)
    if r.returncode != 0:
        raise AssertionError("git %s failed: %s" % (args, r.stderr))
    return r.stdout.strip()


def live_members(pgid):
    """Pids in the process group that are not zombies, read straight from ps."""
    out = subprocess.run(["ps", "-A", "-o", "pid=,pgid=,stat="], capture_output=True, text=True)
    if out.returncode != 0:
        raise AssertionError("ps failed: " + out.stderr)
    live = []
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] == str(pgid) and not parts[2].startswith("Z"):
            live.append(int(parts[0]))
    return live


def running_from(program):
    """Pids of the processes whose command starts with `program`, read straight from ps."""
    out = subprocess.run(["ps", "-A", "-o", "pid=,command="], capture_output=True, text=True)
    if out.returncode != 0:
        raise AssertionError("ps failed: " + out.stderr)
    found = []
    for line in out.stdout.splitlines():
        pid, _, command = line.strip().partition(" ")
        if command.strip().startswith(program):
            found.append(int(pid))
    return found


def wait_not_running(program, limit_s=20):
    """Wait on the condition, no process running from `program`, and return those still there at the limit."""
    deadline = time.monotonic() + limit_s
    while True:
        found = running_from(program)
        if not found or time.monotonic() >= deadline:
            return found
        time.sleep(0.05)


def stop_limit(rdir):
    """How long the product itself allows the stop of the run in `rdir`, which is what a test waits
    for one: a shorter guess reads a correct stop on a loaded Mac as a hung one (the #3807 review)."""
    with open(os.path.join(rdir, "areas.json")) as f:
        return run_session.stop_wait_s(json.load(f)["timeouts"])


def wait_for_file(path, limit_s):
    """Wait on the condition, the file being there, and return what it holds, or None at the limit."""
    deadline = time.monotonic() + limit_s
    while True:
        try:
            with open(path) as f:
                return f.read()
        except FileNotFoundError:
            if time.monotonic() >= deadline:
                return None
            time.sleep(0.05)


def wait_group_empty(pgid, limit_s=30):
    """Wait on the condition, no live member in the process group, and return those left at the limit."""
    deadline = time.monotonic() + limit_s
    while True:
        left = live_members(pgid)
        if not left or time.monotonic() >= deadline:
            return left
        time.sleep(0.05)


# A stand in for a program the supervisor runs, written into a folder put first on its PATH. The
# first call of it is HELD: it says which process it is, then waits for a lock the test holds, and
# only then does the real program's work. The lock is released when the test lets go of it and also
# when the test process is gone, however it went, so a held stand in can never outlive its test.
HELD_FIRST = r'''#!%(python)s
import fcntl, os, sys
fake = os.environ["FAKE_DIR"]
try:
    os.mkdir(os.path.join(fake, "%(name)s-held"))
except FileExistsError:
    pass  # only the first call is held
else:
    said = os.path.join(fake, "%(name)s-held", "pid")
    with open(said + ".tmp", "w") as f:
        f.write(str(os.getpid()))
    os.rename(said + ".tmp", said)
    %(before)s
    with open(os.path.join(fake, "hold.lock")) as lock:
        fcntl.flock(lock, fcntl.LOCK_SH)
%(then)s
'''
# The sandbox the monitor would run its canaries and serve under, standing in where a test must not
# depend on what this Mac's real one reports: it drops `-f <profile>` and runs the command as it is.
FAKE_SANDBOX = '#!/bin/sh\nshift 2\nexec "$@"\n'


class RunFixture(unittest.TestCase):
    """The throwaway repository and the helpers both test classes use; it holds no tests."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = os.path.realpath(self.tmp.name)
        self.repo = os.path.join(base, "app")
        self.home = os.path.join(base, "home")
        self.fake = os.path.join(base, "fake")
        os.makedirs(self.repo)
        os.makedirs(self.fake)
        os.mkfifo(os.path.join(self.fake, "ready.fifo"))
        git(self.repo, "init", "-q")
        self.started = []
        self.held = None
        # Every run a test starts is tied to this process (claude-config#3682): it holds the write
        # end, and when it dies, killed with its whole suite included, each run's supervisor sees the
        # pipe end and stops its run. tearDown's stop never runs in a suite killed outright.
        self.tie = os.pipe() if self.lifeline else None

    lifeline = True

    def hold(self):
        """Take the lock every held stand in waits for. It is this process's alone, so it is let go
        by let_go(), by tearDown, and by the system when this process is gone."""
        self.held = os.open(os.path.join(self.fake, "hold.lock"), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(self.held, fcntl.LOCK_EX)

    def let_go(self):
        if self.held is not None:
            os.close(self.held)
            self.held = None

    def stand_in(self, name, text):
        """Write an executable stand in named `name` into the folder path_first() puts on the PATH."""
        folder = os.path.join(self.fake, "bin")
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, name)
        with open(path, "w") as f:
            f.write(text)
        os.chmod(path, 0o755)
        return path

    def path_first(self):
        return os.path.join(self.fake, "bin") + os.pathsep + os.environ.get("PATH", "")

    def tearDown(self):
        self.let_go()  # before the stops below: a supervisor a stand in holds cannot finish one
        for rid in self.started:
            subprocess.run(self.cli("stop", rid), capture_output=True, text=True, env=self.env())
        if self.tie:
            for fd in self.tie:
                os.close(fd)
        self.tmp.cleanup()

    def commit(self, **commands):
        cmds = {
            "serve": "exec python3 scripts/fake_serve.py",
            "ready": 'cat "$FAKE_DIR/ready.fifo" >/dev/null',
            "stop": ': > "$FAKE_DIR/stop-ran"',
            "drive": "sh scripts/drive.sh",
            "stamp": "git rev-parse HEAD",
        }
        cmds.update(commands)
        cmds = {k: c for k, c in cmds.items() if c is not None}
        doc = {
            "schema": "verification-areas/1",
            "mode": "warn",
            "url": "http://127.0.0.1:4173",
            "commands": cmds,
            "timeouts": {"ready_s": 20, "ready_interval_s": 1, "max_run_s": 3600, "stop_s": 10},
            "areas": [{"name": "invoices", "guide": ".claude/verification/guides/invoices.md",
                       "owns": ["src/**"]}],
        }
        doc.update(self.doc_over)
        doc = {k: val for k, val in doc.items() if val is not None}  # None in doc_over removes a key
        files = {
            ".claude/verification/areas.json": json.dumps(doc, indent=2),
            ".claude/verification/guides/invoices.md": GUIDE,
            "scripts/fake_serve.py": FAKE_SERVE,
            "scripts/drive.sh": DRIVE,
        }
        for rel, text in files.items():
            p = os.path.join(self.repo, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as f:
                f.write(text)
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "fixture")
        return git(self.repo, "rev-parse", "HEAD")

    extra_env = {}
    doc_over = {}

    def env(self, scale="1", deadline="1"):
        env = dict(os.environ, VERIFICATION_HOME=self.home, FAKE_DIR=self.fake,
                   VERIFICATION_TIME_SCALE=scale, VERIFICATION_DEADLINE_SCALE=deadline, **self.extra_env)
        env.pop("VERIFICATION_LIFELINE_FD", None)
        if self.tie:
            env["VERIFICATION_LIFELINE_FD"] = str(self.tie[0])
        return env

    def cli(self, *args):
        return [sys.executable, os.path.join(HERE, "run_session.py")] + list(args)

    def run_cli(self, *args, scale="1", deadline="1"):
        return subprocess.run(self.cli(*args), capture_output=True, text=True, env=self.env(scale, deadline),
                              pass_fds=self.tie[:1] if self.tie else ())

    def start(self, sha, scale="1", areas="invoices", deadline="1"):
        r = self.run_cli("start", "--repo", self.repo, "--sha", sha, "--areas", areas, scale=scale,
                         deadline=deadline)
        if r.returncode == 0:
            self.started.append(json.loads(r.stdout)["receipt_id"])
        return r

    def cut_lifeline(self):
        """Close this process's write end of the lifeline, as its death would."""
        os.close(self.tie[1])
        self.tie = self.tie[:1]

    def receipt(self, rid):
        with open(os.path.join(self.home, "receipts", rid, "receipt.json")) as f:
            return json.load(f)

    def only_receipt_id(self):
        ids = os.listdir(os.path.join(self.home, "receipts"))
        self.assertEqual(len(ids), 1, ids)
        return ids[0]

    def assert_fully_stopped(self, rec, stopped_by):
        self.assertEqual(rec["stopped_by"], stopped_by, rec)
        self.assertTrue(rec["stopped_at"])
        self.assertEqual(live_members(rec["serve_pgid"]), [], "serve survived")
        self.assertFalse(os.path.exists(rec["worktree"]), "worktree left behind")
        self.assertTrue(rec["worktree_removed"])
        self.assertTrue(os.path.exists(os.path.join(self.fake, "stop-ran")), "project stop never ran")
        listed = git(self.repo, "worktree", "list", "--porcelain")
        self.assertNotIn(rec["worktree"], listed)


class RunSessionTests(RunFixture):
    def test_start_drive_stop(self):
        sha = self.commit()
        r = self.start(sha)
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        rid = out["receipt_id"]
        rec = self.receipt(rid)
        self.assertEqual(rec["schema"], "verification-receipt/1")
        self.assertEqual(rec["head_sha"], sha)
        self.assertEqual(rec["checkout_sha"], sha)
        self.assertEqual(rec["build_stamp"], sha)
        self.assertEqual(rec["build_stamp_source"], "stamp-command")
        self.assertEqual(rec["machine"], v.machine_name())
        self.assertEqual(rec["egress"]["verdict"], "unmeasured")
        self.assertTrue(rec["ready_at"])
        self.assertIsNone(rec["stopped_at"])
        self.assertTrue(os.path.isdir(rec["worktree"]))
        self.assertTrue(live_members(rec["serve_pgid"]))
        rdir = os.path.join(self.home, "receipts", rid)
        self.assertTrue(os.path.exists(os.path.join(rdir, "guides", "invoices.md")))
        self.assertTrue(os.path.exists(os.path.join(rdir, "areas.json")))

        d = self.run_cli("drive", rid, "--area", "invoices", "--", "open", "/invoices")
        self.assertEqual(d.returncode, 0, d.stderr)
        with open(os.path.join(self.fake, "drive-args")) as f:
            self.assertEqual(f.read().split("\n")[:2], ["open", "/invoices"])
        with open(os.path.join(self.fake, "drive-url")) as f:
            self.assertEqual(f.read(), "http://127.0.0.1:4173")
        self.assertTrue(os.path.exists(os.path.join(rdir, "shot.png")))
        with open(os.path.join(rdir, "drives.jsonl")) as f:
            line = json.loads(f.readline())
        self.assertEqual((line["area"], line["args"], line["exit"]), ("invoices", ["open", "/invoices"], 0))

        s = self.run_cli("stop", rid)
        self.assertEqual(s.returncode, 0, s.stderr)
        self.assert_fully_stopped(self.receipt(rid), "stop")
        # Serve left by itself on the SIGTERM the stop sent it. A supervisor that started serve with
        # the stop signals blocked hands serve that block, and then has to kill it (the #3807 review).
        self.assertEqual(self.receipt(rid)["serve_exit"], 0, "serve did not end on the SIGTERM it was sent")

        again = self.run_cli("drive", rid, "--area", "invoices", "--", "open", "/")
        self.assertNotEqual(again.returncode, 0)
        self.assertIn("run-stopped", again.stderr)
        self.assertEqual(self.run_cli("stop", rid).returncode, 0, "a second stop is not an error")

    def test_drive_refuses_an_area_outside_the_run(self):
        r = self.start(self.commit())
        rid = json.loads(r.stdout)["receipt_id"]
        d = self.run_cli("drive", rid, "--area", "clients", "--", "open", "/")
        self.assertNotEqual(d.returncode, 0)
        self.assertIn("area-not-in-run", d.stderr)
        d = self.run_cli("drive", rid, "open", "/")
        self.assertEqual(d.returncode, 2, d.stderr)

    def test_a_failing_drive_helper_is_logged_and_named(self):
        r = self.start(self.commit(drive="sh -c 'exit 3'"))
        rid = json.loads(r.stdout)["receipt_id"]
        d = self.run_cli("drive", rid, "--area", "invoices", "--", "open", "/")
        self.assertEqual(d.returncode, 8, d.stderr)
        self.assertIn("drive-failed", d.stderr)
        with open(os.path.join(self.home, "receipts", rid, "drives.jsonl")) as f:
            self.assertEqual(json.loads(f.readline())["exit"], 3)

    def test_a_ready_command_that_never_succeeds_still_stops_serve(self):
        sha = self.commit(ready="false")
        r = self.start(sha, scale="0")
        self.assertEqual(r.returncode, 8, r.stderr)
        self.assertIn("ready-timeout", r.stderr)
        self.assert_fully_stopped(self.receipt(self.only_receipt_id()), "ready_failed")

    def test_serve_dying_by_itself_stops_the_run(self):
        r = self.start(self.commit())
        self.assertEqual(r.returncode, 0, r.stderr)
        rid = json.loads(r.stdout)["receipt_id"]
        with open(os.path.join(self.fake, "serve.pid")) as f:
            os.kill(int(f.read()), signal.SIGKILL)
        rdir = os.path.join(self.home, "receipts", rid)
        run_session.wait_for_supervisor(rdir, timeout_s=stop_limit(rdir))
        rec = self.receipt(rid)
        self.assert_fully_stopped(rec, "serve_exited")
        self.assertEqual(rec["serve_exit"], -signal.SIGKILL)
        # Serve is watched for, not collected, until its group is dealt with; the receipt reads as it always did.
        self.assertEqual(rec["stop_detail"], "serve exited by itself with %s" % -signal.SIGKILL)

    def test_the_deadline_stops_serve(self):
        r = self.start(self.commit(ready="true"), scale="0", deadline="0")
        rid = self.only_receipt_id()
        rdir = os.path.join(self.home, "receipts", rid)
        run_session.wait_for_supervisor(rdir, timeout_s=stop_limit(rdir))
        self.assert_fully_stopped(self.receipt(rid), "deadline")
        if r.returncode != 0:
            self.assertIn("serve-stopped", r.stderr)

    def test_a_lifeline_that_is_not_a_pipes_read_end_is_refused_before_anything_starts(self):
        sha = self.commit()
        cases = [(self.tie[1], "not the read end of a pipe"), ("x", "names no open descriptor"),
                 (999, "names no open descriptor")]
        with open(os.path.join(self.fake, "plain-file"), "w") as plain:
            cases.append((plain.fileno(), "not the read end of a pipe"))
            for fd, said in cases:
                env = dict(self.env(), VERIFICATION_LIFELINE_FD=str(fd))
                r = subprocess.run(self.cli("start", "--repo", self.repo, "--sha", sha, "--areas", "invoices"),
                                   capture_output=True, text=True, env=env,
                                   pass_fds=(fd,) if isinstance(fd, int) and fd != 999 else ())
                self.assertEqual(r.returncode, 4, (fd, r.stderr))
                self.assertIn("lifeline-bad", r.stderr)
                self.assertIn(said, r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.home, "receipts")), "a refused start made a receipt")

    def test_something_written_down_the_lifeline_does_not_stop_the_run(self):
        r = self.start(self.commit())
        self.assertEqual(r.returncode, 0, r.stderr)
        rid = json.loads(r.stdout)["receipt_id"]
        os.write(self.tie[1], b"still here\n")
        # Wait on the condition, the supervisor having read it all, never a fixed time (L290).
        deadline = time.monotonic() + 30
        while pipe_pending(self.tie[0]) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual(pipe_pending(self.tie[0]), 0, "the supervisor never read its lifeline")
        self.assertTrue(run_session.supervisor_alive(os.path.join(self.home, "receipts", rid)))
        self.assertIsNone(self.receipt(rid)["stopped_at"])
        s = self.run_cli("stop", rid)
        self.assertEqual(s.returncode, 0, s.stderr)
        self.assert_fully_stopped(self.receipt(rid), "stop")

    @unittest.skipIf(sys.platform != "darwin", "UNMEASURED, not passed: the monitor whose start holds the"
                     " supervisor here only starts on macOS")
    def test_a_caller_that_goes_while_the_run_is_starting_is_acted_on_once_serve_is_recorded(self):
        # The supervisor is held inside the egress monitor's start, before serve exists, by a report
        # stream that says nothing until the test lets it go. A stop acted on there would interrupt
        # the start of a child, which leaves that child running with nothing recorded to stop it by
        # (the #3807 review). So the stop must wait until serve's pid and group are in the receipt.
        self.stand_in("log", HELD_FIRST % {
            "python": sys.executable, "name": "log", "then": "",
            "before": 'print("Filtering the log data using the fake predicate", flush=True)'})
        self.hold()
        self.extra_env = {"VERIFICATION_EGRESS_LOG": os.path.join(self.fake, "bin", "log"),
                          "VERIFICATION_EGRESS_SANDBOX": self.stand_in("sandbox-exec", FAKE_SANDBOX)}
        # egress_s is how long the monitor waits on that stream by itself: long, so only the test ends the hold.
        self.doc_over = {"timeouts": {"ready_s": 20, "ready_interval_s": 1, "max_run_s": 3600, "stop_s": 10,
                                      "egress_s": 120}}
        sha = self.commit()
        starting = subprocess.Popen(self.cli("start", "--repo", self.repo, "--sha", sha, "--areas", "invoices"),
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.env(),
                                    pass_fds=self.tie[:1])
        self.addCleanup(starting.communicate)
        self.assertTrue(wait_for_file(os.path.join(self.fake, "log-held", "pid"), 120),
                        "the supervisor never started its report stream")
        rid = self.only_receipt_id()
        self.started.append(rid)
        rdir = os.path.join(self.home, "receipts", rid)
        self.assertIsNone(self.receipt(rid)["serve_pid"], "serve was started before the monitor was")
        self.cut_lifeline()
        self.assertEqual(wait_for_file(os.path.join(rdir, "stop-reason"), 120), "caller_gone",
                         "the supervisor never saw its caller go")
        self.let_go()  # the stream ends, the monitor gives up, and the supervisor goes on to start serve
        try:
            run_session.wait_for_supervisor(rdir, timeout_s=stop_limit(rdir))
        except v.VerificationError as e:
            self.fail("a stop asked for during the start was never acted on: %s" % e)
        rec = self.receipt(rid)
        self.assertIsNotNone(rec["serve_pid"], "the stop was acted on before serve's pid and group were"
                             " recorded, so it interrupted the supervisor while it was starting: %s" % rec)
        self.assertEqual(rec["serve_pgid"], rec["serve_pid"])
        self.assertEqual(rec["stopped_by"], "caller_gone", rec)
        self.assertEqual(wait_group_empty(rec["serve_pgid"]), [], "serve outlived the stop")
        self.assertTrue(rec["worktree_removed"], rec)
        self.assertEqual(rec["egress"]["verdict"], "unmeasured", rec["egress"])

    def test_a_second_stop_signal_does_not_interrupt_the_stop_already_under_way(self):
        # The supervisor is held at the first thing a stop signal makes it do, reading why it was
        # asked to stop: the reason file is a FIFO here, so that read waits for this test to write
        # it. A second signal landing there used to end the read with the reason never taken, and
        # the run was recorded as a supervisor error (the #3807 review).
        r = self.start(self.commit())
        self.assertEqual(r.returncode, 0, r.stderr)
        rid = json.loads(r.stdout)["receipt_id"]
        rdir = os.path.join(self.home, "receipts", rid)
        rec = self.receipt(rid)
        fifo = os.path.join(rdir, "stop-reason")
        os.mkfifo(fifo)
        try:
            run_session.request_stop(rdir, "stop")
            # Wait on the condition, the supervisor having the reason open to read: only then can
            # this end be opened without blocking (ENXIO until a reader is there).
            deadline, w = time.monotonic() + stop_limit(rdir), None
            while w is None and time.monotonic() < deadline:
                try:
                    w = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
                except OSError as e:
                    if e.errno != errno.ENXIO:
                        raise
                    time.sleep(0.05)
            self.assertIsNotNone(w, "the supervisor never came to read why it was asked to stop")
            try:
                self.assertTrue(run_session.supervisor_alive(rdir))
                # The second stop signal, to the pid the supervisor's held lock vouches for. It is
                # sent BEFORE the reason is written, so it reaches a supervisor still in that read.
                os.kill(rec["supervisor_pid"], signal.SIGTERM)
                os.write(w, b"stop")
            finally:
                os.close(w)
        finally:
            # Whatever went wrong above, no supervisor is left waiting for a reason nobody will
            # write: this opens the FIFO as a writer whether or not a reader is there yet.
            rw = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
            os.write(rw, b"stop")
            os.close(rw)
        try:
            run_session.wait_for_supervisor(rdir, timeout_s=stop_limit(rdir))
        except v.VerificationError as e:
            self.fail("the supervisor did not finish its stop: %s" % e)
        self.assert_fully_stopped(self.receipt(rid), "stop")
        with open(os.path.join(rdir, "supervisor.log")) as f:
            self.assertNotIn("Traceback", f.read(), "the second signal broke out of the stop")

    def test_a_stop_that_hung_is_cut_off_once_the_caller_is_gone(self):
        # The state process 77733 was left in on 2026-11-26 (claude-config#3820): a stop was asked
        # for, the supervisor began it and never finished. Here the stop hangs because the first ps
        # the supervisor runs, to see whether serve's group is empty, is held by this test.
        self.stand_in("ps", HELD_FIRST % {"python": sys.executable, "name": "ps", "before": "pass",
                                          "then": 'os.execv("/bin/ps", ["ps"] + sys.argv[1:])'})
        self.hold()
        # The scale makes a supervisor whose caller is gone give the stop no time at all before it
        # cuts the run off: this stop can never finish, so nothing is lost by not waiting for it.
        self.extra_env = {"PATH": self.path_first(), "VERIFICATION_STOP_LIMIT_SCALE": "0"}
        r = self.start(self.commit())
        self.assertEqual(r.returncode, 0, r.stderr)
        rid = json.loads(r.stdout)["receipt_id"]
        rdir = os.path.join(self.home, "receipts", rid)
        rec = self.receipt(rid)
        run_session.request_stop(rdir, "stop")
        held = wait_for_file(os.path.join(self.fake, "ps-held", "pid"), stop_limit(rdir))
        self.assertTrue(held, "the supervisor's stop never reached the ps this test holds")
        self.assertTrue(run_session.supervisor_alive(rdir))
        self.assertIsNone(self.receipt(rid)["stopped_at"])
        self.cut_lifeline()
        try:
            run_session.wait_for_supervisor(rdir, timeout_s=stop_limit(rdir))
        except v.VerificationError as e:
            self.fail("a stop that hung was not ended once the caller of its run was gone: %s" % e)
        done = self.receipt(rid)
        self.assertEqual(done["stopped_by"], "caller_gone", done)
        self.assertIn("cut off", done["stop_detail"])
        self.assertIn("a stop asked for earlier (stop)", done["stop_detail"])
        # A run that was cut off is never given a measured verdict, clean least of all.
        self.assertEqual(done["egress"]["verdict"], "unmeasured", done["egress"])
        self.assertIn("cut off", done["egress"]["why"])
        self.assertIsNone(done["egress"].get("measured_to"))
        self.assertEqual(done["stop_command_exit"], 0, "the project's stop command, which the hung stop had run")
        self.assertTrue(done["worktree_removed"], done)
        self.assertFalse(os.path.exists(rec["worktree"]), "worktree left behind")
        self.assertEqual(wait_group_empty(rec["serve_pgid"]), [], "serve's group outlived the cut off")
        if rec.get("egress_monitor_pgid"):
            self.assertEqual(wait_group_empty(rec["egress_monitor_pgid"]), [], "the report stream outlived the cut off")
        # The supervisor is gone, and so is the ps it was waiting on, which was in no recorded group
        # but in the supervisor's own.
        self.assertEqual(wait_gone([rec["supervisor_pid"], int(held)]), [], "left behind by the cut off")
        self.assertFalse(os.path.exists(os.path.join(rdir, "egress-beat")), "the beat program's copy was left")

    def test_stop_recovers_when_the_supervisor_was_killed_outright(self):
        r = self.start(self.commit())
        self.assertEqual(r.returncode, 0, r.stderr)
        rid = json.loads(r.stdout)["receipt_id"]
        rec = self.receipt(rid)
        beat_program = os.path.join(self.home, "receipts", rid, "egress-beat")
        if rec.get("egress_sandbox"):  # the monitor started, so its beat program is running from its copy
            self.assertTrue(os.path.exists(beat_program), "the monitor made no beat program")
            self.assertTrue(running_from(beat_program), "the beat program is not running")
        os.kill(rec["supervisor_pid"], signal.SIGKILL)
        self.assertTrue(live_members(rec["serve_pgid"]), "serve should outlive its supervisor")
        s = self.run_cli("stop", rid)
        self.assertEqual(s.returncode, 0, s.stderr)
        rec = self.receipt(rid)
        self.assert_fully_stopped(rec, "recovered")
        # The beat program ends by itself when its supervisor's death closes its input, and the
        # stop removes the copy it ran from (claude-config#3576).
        self.assertFalse(os.path.exists(beat_program), "the beat program's copy was left in the receipt folder")
        self.assertEqual(wait_not_running(beat_program), [], "the beat program outlived its supervisor")
        # The monitor died with its supervisor, so the run cannot show what it reached, and the
        # report stream it left behind is stopped by the process group it recorded.
        self.assertEqual(rec["egress"]["verdict"], "unmeasured", rec["egress"])
        self.assertIn("supervisor", rec["egress"]["why"])
        if rec.get("egress_monitor_pgid"):
            self.assertEqual(live_members(rec["egress_monitor_pgid"]), [], "the report stream survived")

    def test_a_second_run_of_the_same_project_is_refused_while_one_is_live(self):
        sha = self.commit()
        first = self.start(sha)
        self.assertEqual(first.returncode, 0, first.stderr)
        second = self.start(sha)
        self.assertEqual(second.returncode, 5, second.stderr)
        self.assertIn("run-busy", second.stderr)
        self.assertIn(json.loads(first.stdout)["receipt_id"], second.stderr)

    def test_a_commit_that_is_not_here_starts_nothing(self):
        self.commit()
        r = self.start("f" * 40)
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertIn("commit-missing", r.stderr)
        self.assertIn("fetch", r.stderr)
        self.assertFalse(os.path.isdir(os.path.join(self.home, "receipts")) and
                         os.listdir(os.path.join(self.home, "receipts")))

    def test_a_malformed_sha_or_unknown_area_starts_nothing(self):
        sha = self.commit()
        r = self.start("HEAD")
        self.assertEqual(r.returncode, 4)
        self.assertIn("bad-sha", r.stderr)
        r = self.start(sha, areas="clients")
        self.assertEqual(r.returncode, 4)
        self.assertIn("area-unknown", r.stderr)

    def test_a_malformed_areas_file_at_the_commit_starts_nothing(self):
        self.commit()
        with open(os.path.join(self.repo, ".claude/verification/areas.json"), "w") as f:
            f.write("{")
        git(self.repo, "commit", "-q", "-am", "break it")
        r = self.start(git(self.repo, "rev-parse", "HEAD"))
        self.assertEqual(r.returncode, 4)
        self.assertIn("areas-not-json", r.stderr)

    def test_a_repo_that_has_not_opted_in(self):
        with open(os.path.join(self.repo, "README"), "w") as f:
            f.write("x")
        git(self.repo, "add", "README")
        git(self.repo, "commit", "-q", "-m", "plain")
        r = self.start(git(self.repo, "rev-parse", "HEAD"))
        self.assertEqual(r.returncode, 3)
        self.assertIn("areas-missing", r.stderr)


def sandbox_unavailable():
    """Why this machine cannot measure egress, or None when it can (L411: detect, never assume)."""
    if sys.platform != "darwin":
        return "this is %s, and the monitor is macOS's sandbox-exec" % sys.platform
    if not os.path.exists("/usr/bin/sandbox-exec"):
        return "/usr/bin/sandbox-exec is not on this Mac"
    r = subprocess.run(["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/usr/bin/true"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return "sandbox-exec cannot apply a profile here (exit %d: %s)" % (r.returncode, r.stderr.strip()[:200])
    return None


NO_SANDBOX = sandbox_unavailable()
MEASURED = unittest.skipIf(NO_SANDBOX, "UNMEASURED, not passed: %s" % NO_SANDBOX)
# The monitor's words for a Mac that did not write every sandbox report it asked for (claude-config#3576).
WITHHELD = "this Mac did not report every connection it was asked to report"
WITHHELD_AFTER_S = 3  # a report arrived within 5 ms when it arrived at all (420 rounds, 2026-11-24)

FAKE_LOG_SILENT = r'''#!/bin/sh
# A report stream that starts and then never reports anything: the canary is never seen.
echo "Filtering the log data using the fake predicate"
exec sleep 3600
'''


class EgressTests(RunFixture):
    """The egress monitor (claude-config#1571): a run's receipt says what serve and the drive helper
    reached outside this machine, judged against areas.json's egress.allow, and the merge check in
    block mode passes only a clean verdict. The fixtures reach 127.0.0.1 and ::1, or 192.0.2.1,
    which is TEST-NET-1: reserved for documentation, so no real host is ever contacted."""

    def run_to_receipt(self, connect, drive_connect=None, wait_for=None):
        self.extra_env = dict(self.extra_env, FAKE_CONNECT=connect)
        drive = None
        if drive_connect:
            drive = ('python3 -c "import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM);'
                     ' s.connect((\'%s\', 9))"' % drive_connect)
        sha = self.commit(**({"drive": drive} if drive else {}))
        r = self.start(sha)
        self.assertEqual(r.returncode, 0, r.stderr)
        rid = json.loads(r.stdout)["receipt_id"]
        d = self.run_cli("drive", rid, "--area", "invoices", "--", "open", "/invoices")
        self.assertEqual(d.returncode, 0, d.stderr)
        if wait_for:
            self.wait_for_named(rid, wait_for)
        s = self.run_cli("stop", rid)
        self.assertEqual(s.returncode, 0, s.stderr)
        return rid, sha, self.receipt(rid)

    def wait_for_named(self, rid, address):
        """Wait on the condition, the monitor naming the address, never a fixed time (L290).

        On a Mac that withholds sandbox reports (claude-config#3576) the address may never be named.
        There the wait ends on another condition the monitor's own log shows: a test connection it
        made has gone WITHHELD_AFTER_S with no report. The receipt then decides what the run read;
        nothing here waits for a reporting window to come round."""
        path = os.path.join(self.home, "receipts", rid, "egress.jsonl")
        deadline = time.monotonic() + 60
        unreported_since = {}
        while time.monotonic() < deadline:
            try:
                with open(path) as f:
                    text = f.read()
            except FileNotFoundError:
                text = ""
            if address in text:
                return
            made, reported = set(), set()
            for line in text.splitlines():
                try:
                    ev = json.loads(line)
                except ValueError:  # a line still being written
                    continue
                if ev.get("event") == "beat-fired":
                    made.add(ev["beat"])
                elif ev.get("event") == "beat":
                    reported.add(ev["beat"])
            now = time.monotonic()
            for beat in made - reported:
                unreported_since.setdefault(beat, now)
            if any(now - since >= WITHHELD_AFTER_S for beat, since in unreported_since.items() if beat not in reported):
                return
            time.sleep(0.05)
        self.fail("the monitor never named %s in %s, and its log shows no test connection unreported" % (address, path))

    def withheld(self, egress):
        """Whether this run's own receipt shows a report the monitor asked for that never arrived.
        That is the kind of Mac the run was on, read from the run itself and never assumed (L411)."""
        beats, canaries = egress["beats"], egress["canaries"]
        self.assertIsNone(beats["failure"], egress)
        # One before the first canary and one after serve was gone, at the least.
        self.assertGreaterEqual(beats["fired"], 2, egress)
        self.assertGreaterEqual(egress["attach"]["seen"], 1, egress)
        if beats["reported"] < beats["fired"] or canaries["seen"] < canaries["fired"]:
            # Said in the test's own output, so a run of the suite shows which arm each test took.
            sys.stderr.write("[this Mac withheld %d of %d test connections and %d of %d canaries; the run read %s] "
                             % (beats["fired"] - beats["reported"], beats["fired"],
                                canaries["fired"] - canaries["seen"], canaries["fired"], egress["verdict"]))
            return True
        return False

    def assert_unmeasured_because_reports_were_withheld(self, rid, sha, egress):
        """What a run reads on a Mac that withheld a report: unmeasured, saying so, and no merge."""
        self.assertEqual(egress["verdict"], "unmeasured", egress)
        self.assertIn(WITHHELD, egress["why"])
        self.assertIn("cannot be trusted", egress["why"])
        self.assertIsNone(egress["measured_to"])
        out = self.merge_verdict(rid, sha)
        self.assertEqual(out["decision"], "refuse")
        self.assertEqual(sorted({p["kind"] for p in out["problems"]}), ["egress-unmeasured"])
        self.assertIn(WITHHELD, out["text"])

    def assert_no_beat_program_left(self, rid):
        beat_program = os.path.join(self.home, "receipts", rid, "egress-beat")
        self.assertFalse(os.path.exists(beat_program), "the beat program's copy was left in the receipt folder")
        self.assertEqual(wait_not_running(beat_program), [], "the beat program outlived the run")

    def assert_the_real_beat_program_ended_well(self, rid):
        """The real ad hoc signed copy of bash, under the real sandbox, ran until its input closed
        and exited 0, and the monitor read that. A bad ending makes a run unmeasured, so this is what
        shows the rule does not fire on the program as it really is (L147)."""
        with open(os.path.join(self.home, "receipts", rid, "egress.jsonl")) as f:
            events = [json.loads(line) for line in f]
        ended = [(e["exit"], e["early"], e["killed"]) for e in events if e["event"] == "beat-ended"]
        self.assertEqual(ended, [(0, False, False)], events)

    def merge_verdict(self, rid, sha):
        """The merge check's judgment in block mode, over this run's real receipt, through the same
        readers the hook uses (verification.py)."""
        import merge_check as mc
        import test_merge_check as tmc
        f = tmc.Fixture(tempfile.mkdtemp(dir=self.tmp.name))
        f.home = self.home
        f.view["headRefOid"] = sha
        f.pin = "required " + sha
        f.comments = [tmc.comment(tmc.record(sha=sha, rid=rid))]
        f.save()
        out = mc.verdict(f.dir, home=self.home)
        self.assertEqual(out["mode"], "block")
        return out

    # The four runs below go through the real sandbox, and what each must read depends on the Mac
    # (claude-config#3576). Where every report the monitor asked for arrived, the run reads as it
    # always did. Where one did not, a run in which nothing outside was SEEN reads unmeasured,
    # never clean, and a run in which something outside was seen still reads not-clean. Which Mac
    # this is comes from the run's own receipt, and each arm asserts in full: nothing is retried
    # until a reporting window has gone.

    @MEASURED
    def test_a_serve_that_reaches_only_this_machine_is_clean(self):
        rid, sha, rec = self.run_to_receipt("local")
        egress = rec["egress"]
        self.assertEqual(egress["destinations"], [], egress)
        self.assertEqual(egress["allowed_hosts"], ["127.0.0.1", "localhost", "::1"])
        self.assert_no_beat_program_left(rid)
        self.assert_the_real_beat_program_ended_well(rid)
        if self.withheld(egress):
            return self.assert_unmeasured_because_reports_were_withheld(rid, sha, egress)
        self.assertEqual(egress["verdict"], "clean", egress)
        self.assertIn("no connection", egress["why"])
        self.assertEqual(egress["beats"]["unreported"], [], egress)
        out = self.merge_verdict(rid, sha)
        self.assertEqual((out["problems"], out["decision"]), ([], "allow"))

    @MEASURED
    def test_a_serve_that_reaches_an_outside_host_is_not_clean_and_names_it(self):
        rid, sha, rec = self.run_to_receipt("outside", wait_for="192.0.2.1")
        egress = rec["egress"]
        named = [d for d in egress["destinations"] if d["address"] == "192.0.2.1"]
        if not named:
            # Only a Mac that withheld reports may fail to name it, and then the run is never clean.
            self.assertTrue(self.withheld(egress), egress)
            return self.assert_unmeasured_because_reports_were_withheld(rid, sha, egress)
        self.assertEqual(egress["verdict"], "not-clean", egress)
        self.assertIn("192.0.2.1", egress["why"])
        self.assertEqual(len(named), 1, egress)
        self.assertEqual((named[0]["port"], named[0]["allowed"]), (9, False))
        self.assertGreaterEqual(named[0]["reports"], 1)
        if self.withheld(egress):  # what was seen is never downgraded, and the gap is said beside it
            self.assertIn(WITHHELD, egress["why"])
        out = self.merge_verdict(rid, sha)
        self.assertEqual(out["decision"], "refuse")
        self.assertEqual(sorted({p["kind"] for p in out["problems"]}), ["egress-not-clean"])
        self.assertIn("192.0.2.1", out["text"])

    @MEASURED
    def test_an_allowed_outside_host_is_clean(self):
        self.doc_over = {"egress": {"allow": ["192.0.2.1"]}}
        rid, sha, rec = self.run_to_receipt("outside", wait_for="192.0.2.1")
        egress = rec["egress"]
        if self.withheld(egress):
            self.assertEqual([d for d in egress["destinations"] if not d["allowed"]], [], egress)
            return self.assert_unmeasured_because_reports_were_withheld(rid, sha, egress)
        self.assertEqual(egress["verdict"], "clean", egress)
        self.assertEqual([(d["address"], d["allowed"]) for d in egress["destinations"]], [("192.0.2.1", True)])

    @MEASURED
    def test_the_drive_helper_is_measured_too(self):
        rid, sha, rec = self.run_to_receipt("local", drive_connect="192.0.2.2")
        egress = rec["egress"]
        if not egress["unnamed"] and not egress["destinations"]:
            # The drive helper's connection was never reported. Main read this run clean (the
            # failure #3576 was filed for); it is unmeasured, and only on a Mac that withheld.
            self.assertTrue(self.withheld(egress), egress)
            return self.assert_unmeasured_because_reports_were_withheld(rid, sha, egress)
        self.assertEqual(egress["verdict"], "not-clean", egress)
        self.assertIn("port 9", egress["why"])

    @MEASURED
    def test_a_beat_program_that_cannot_be_signed_leaves_unmeasured(self):
        # Nothing then shows whether this Mac reports every connection, so nothing may read clean;
        # serve still runs under the reporting sandbox, so a connection that is seen still counts.
        self.extra_env = {"VERIFICATION_EGRESS_CODESIGN": "/usr/bin/false"}
        rid, sha, rec = self.run_to_receipt("local")
        egress = rec["egress"]
        self.assertEqual(egress["verdict"], "unmeasured", egress)
        self.assertIn("could not check that this Mac reports every connection", egress["why"])
        self.assertIn("could not be signed ad hoc (/usr/bin/false exit 1", egress["why"])
        self.assertEqual((egress["beats"]["fired"], egress["beats"]["reported"]), (0, 0), egress)
        self.assertTrue(rec.get("egress_sandbox"), "serve must still run under the reporting sandbox")
        self.assert_no_beat_program_left(rid)
        out = self.merge_verdict(rid, sha)
        self.assertEqual(out["decision"], "refuse")
        self.assertEqual(sorted({p["kind"] for p in out["problems"]}), ["egress-unmeasured"])

    def test_a_monitor_that_cannot_start_leaves_unmeasured(self):
        self.extra_env = {"VERIFICATION_EGRESS_LOG": "/nonexistent/log"}
        rid, sha, rec = self.run_to_receipt("local")
        egress = rec["egress"]
        self.assertEqual(egress["verdict"], "unmeasured", egress)
        self.assertTrue(egress["why"])
        if not NO_SANDBOX:
            self.assertIn("/nonexistent/log", egress["why"])
        self.assertEqual(rec["stopped_by"], "stop", "a monitor that cannot start must not stop the run")
        out = self.merge_verdict(rid, sha)
        self.assertEqual(out["decision"], "refuse")
        self.assertEqual(sorted({p["kind"] for p in out["problems"]}), ["egress-unmeasured"])

    @MEASURED
    def test_a_report_stream_that_never_shows_the_canary_leaves_unmeasured(self):
        fake_log = os.path.join(self.fake, "log")
        with open(fake_log, "w") as f:
            f.write(FAKE_LOG_SILENT)
        os.chmod(fake_log, 0o755)
        self.extra_env = {"VERIFICATION_EGRESS_LOG": fake_log}
        self.doc_over = {"timeouts": {"ready_s": 20, "ready_interval_s": 1, "max_run_s": 3600, "stop_s": 10,
                                      "egress_s": 2}}
        rid, sha, rec = self.run_to_receipt("local")
        egress = rec["egress"]
        self.assertEqual(egress["verdict"], "unmeasured", egress)
        self.assertIn("canary", egress["why"])
        self.assertIsNone(rec.get("egress_sandbox"), "serve must not run under a profile nothing reads")
        if rec.get("egress_monitor_pgid"):
            self.assertEqual(live_members(rec["egress_monitor_pgid"]), [])


# The real functions, taken before any test patches them, so an injected failure can let every
# other call through untouched.
REAL_GIT = run_session.git
REAL_UPDATE_RECEIPT = run_session.update_receipt
REAL_DUMP = json.dump
REAL_POPEN = subprocess.Popen
REAL_MAKEDIRS = os.makedirs

DISK_FULL = OSError(errno.ENOSPC, "No space left on device")


def fail_initial_receipt(rdir, **fields):
    if "schema" in fields:
        raise OSError(errno.ENOSPC, "No space left on device")
    return REAL_UPDATE_RECEIPT(rdir, **fields)


def fail_after_worktree_add(repo, *args, check=True):
    r = REAL_GIT(repo, *args, check=check)
    if args[:2] == ("worktree", "add"):
        raise OSError(errno.EIO, "Input/output error")
    return r


def fail_areas_copy(obj, f, *args, **kwargs):
    if getattr(f, "name", "").endswith(os.sep + "areas.json"):
        raise OSError(errno.ENOSPC, "No space left on device")
    return REAL_DUMP(obj, f, *args, **kwargs)


def fail_supervisor_launch(argv, *args, **kwargs):
    if "_supervise" in argv:
        raise OSError(errno.EAGAIN, "Resource temporarily unavailable")
    return REAL_POPEN(argv, *args, **kwargs)


def fail_guides_dir(path, *args, **kwargs):
    if path.endswith(os.sep + "guides"):
        raise OSError(errno.ENOSPC, "No space left on device")
    return REAL_MAKEDIRS(path, *args, **kwargs)


NATIVE_AREAS = [{"name": "invoices", "guide": ".claude/verification/guides/invoices.md", "owns": ["src/**"],
                 "screens": [{"name": "list", "test": "AppHostedTests/VerificationScreens",
                              "frame": "invoice-list", "seed": "demo"}]}]


class NativeRunTests(RunFixture):
    """A project whose areas are all native runs with no url, serve or ready (claude-config#2951).

    The supervisor still owns the run: it holds the project's lock, runs the egress monitor around
    every drive call, and stops on `stop` or the deadline, running the project's stop command and
    removing the worktree. There is simply no serve process for it to start or stop.
    """

    doc_over = {"url": None, "seeds": {"demo": {"synthetic": True, "why": "made up for the fixture"}},
                "areas": NATIVE_AREAS}
    native = dict(serve=None, ready=None, native_shot="true")

    def test_start_drive_stop_with_nothing_served(self):
        sha = self.commit(**self.native)
        r = self.start(sha)
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertIsNone(out["url"])
        rid = out["receipt_id"]
        rec = self.receipt(rid)
        self.assertIsNone(rec["url"])
        self.assertIsNone(rec["serve_pid"])
        self.assertIsNone(rec["serve_pgid"])
        self.assertTrue(rec["supervisor_pid"])
        self.assertTrue(rec["ready_at"])
        self.assertEqual(rec["build_stamp"], sha)
        self.assertIsNone(rec["stopped_at"])
        self.assertTrue(os.path.isdir(rec["worktree"]))
        self.assertFalse(os.path.exists(os.path.join(self.home, "receipts", rid, "serve.log")))

        # A VERIFICATION_URL inherited from the caller must not reach the helper as if it were served.
        self.extra_env = {"VERIFICATION_URL": "http://127.0.0.1:9"}
        d = self.run_cli("drive", rid, "--area", "invoices", "--", "screenshot-native", "x")
        self.assertEqual(d.returncode, 0, d.stderr)
        with open(os.path.join(self.fake, "drive-url")) as f:
            self.assertEqual(f.read(), "")

        s = self.run_cli("stop", rid)
        self.assertEqual(s.returncode, 0, s.stderr)
        rec = self.receipt(rid)
        self.assertEqual(rec["stopped_by"], "stop", rec)
        self.assertIsNone(rec["serve_exit"])
        self.assertTrue(rec["worktree_removed"])
        self.assertFalse(os.path.exists(rec["worktree"]))
        self.assertTrue(os.path.exists(os.path.join(self.fake, "stop-ran")), "project stop never ran")

    def test_a_second_start_is_still_refused_while_a_native_run_is_live(self):
        sha = self.commit(**self.native)
        self.assertEqual(self.start(sha).returncode, 0)
        again = self.start(sha)
        self.assertNotEqual(again.returncode, 0)
        self.assertIn("run-busy", again.stderr)

    def test_the_deadline_still_ends_a_native_run(self):
        self.start(self.commit(**self.native), deadline="0")
        rid = self.only_receipt_id()
        rdir = os.path.join(self.home, "receipts", rid)
        run_session.wait_for_supervisor(rdir, timeout_s=stop_limit(rdir))
        rec = self.receipt(rid)
        self.assertEqual(rec["stopped_by"], "deadline", rec)
        self.assertTrue(rec["worktree_removed"])
        self.assertTrue(os.path.exists(os.path.join(self.fake, "stop-ran")))

    def test_a_native_run_ends_when_its_lifeline_is_cut(self):
        # With nothing served the supervisor sleeps out its deadline, and the stop must still wake it.
        r = self.start(self.commit(**self.native))
        self.assertEqual(r.returncode, 0, r.stderr)
        rid = json.loads(r.stdout)["receipt_id"]
        self.cut_lifeline()
        rdir = os.path.join(self.home, "receipts", rid)
        run_session.wait_for_supervisor(rdir, timeout_s=stop_limit(rdir))
        rec = self.receipt(rid)
        self.assertEqual(rec["stopped_by"], "caller_gone", rec)
        self.assertTrue(rec["worktree_removed"])
        self.assertTrue(os.path.exists(os.path.join(self.fake, "stop-ran")))

    def test_a_mixed_project_without_serve_is_refused_before_anything_starts(self):
        areas = NATIVE_AREAS + [{"name": "clients", "guide": ".claude/verification/guides/invoices.md",
                                 "owns": ["web/**"], "screens": [{"name": "list", "path": "/clients", "seed": "demo"}]}]
        self.doc_over = dict(self.doc_over, areas=areas)
        r = self.start(self.commit(**self.native))
        self.assertEqual(r.returncode, 4, r.stderr)
        self.assertIn("areas-web-needs-serve", r.stderr)
        self.assertIn("url, commands.serve, commands.ready", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.home, "receipts")), "a refused start made a receipt")


class StartSetupFailureTests(RunFixture):
    """Any failure while start sets a run up runs the same cleanup as a named refusal (#1570).

    start is called in process so a failure can be injected at each setup step; an injection after
    a step lets that step's real work happen first, so the worktree is really there to be left
    behind. Nothing here starts serve: each failure lands before the supervisor exists.
    """

    def start_in_process(self, sha, *patches):
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.dict(os.environ, self.env()))
            for p in patches:
                stack.enter_context(p)
            return run_session.start(self.repo, sha, "invoices")

    def worktree_of(self, rid):
        return os.path.join(self.home, "receipts", rid, "worktree")

    def assert_lock_released(self):
        fd = os.open(run_session.repo_lock(self.home, self.repo), os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)  # BlockingIOError while still held
        finally:
            os.close(fd)

    def assert_abandoned(self, stopped_by, detail_has):
        rid = self.only_receipt_id()
        rec = self.receipt(rid)
        self.assertEqual(rec["stopped_by"], stopped_by, rec)
        self.assertTrue(rec["stopped_at"], rec)
        self.assertIn(detail_has, rec["stop_detail"])
        wt = self.worktree_of(rid)
        self.assertFalse(os.path.exists(wt), "worktree left behind")
        self.assertTrue(rec["worktree_removed"], rec)
        self.assertNotIn(wt, git(self.repo, "worktree", "list", "--porcelain"))
        self.assert_lock_released()
        return rec

    def assert_refused(self, ctx, kind, message_has):
        problems = ctx.exception.problems
        self.assertEqual(problems[0][0], kind, problems)
        self.assertIn(message_has, problems[0][1])
        return problems

    def test_a_disk_full_writing_the_first_receipt(self):
        sha = self.commit()
        with self.assertRaises(v.VerificationError) as ctx:
            self.start_in_process(sha, mock.patch.object(run_session, "update_receipt",
                                                         side_effect=fail_initial_receipt))
        self.assert_refused(ctx, "disk-full", "No space left on device")
        self.assert_abandoned("start_error", "OSError")

    def test_an_error_after_the_worktree_was_added(self):
        sha = self.commit()
        with self.assertRaises(v.VerificationError) as ctx:
            self.start_in_process(sha, mock.patch.object(run_session, "git", side_effect=fail_after_worktree_add))
        self.assert_refused(ctx, "start-error", "Input/output error")
        self.assert_abandoned("start_error", "Input/output error")

    def test_a_disk_full_copying_areas_json(self):
        sha = self.commit()
        with self.assertRaises(v.VerificationError) as ctx:
            self.start_in_process(sha, mock.patch.object(run_session.json, "dump", side_effect=fail_areas_copy))
        self.assert_refused(ctx, "disk-full", "No space left on device")
        self.assert_abandoned("start_error", "No space left on device")

    def test_a_disk_full_copying_a_guide(self):
        sha = self.commit()
        with self.assertRaises(v.VerificationError) as ctx:
            self.start_in_process(sha, mock.patch.object(run_session.shutil, "copyfile", side_effect=DISK_FULL))
        self.assert_refused(ctx, "disk-full", "No space left on device")
        self.assert_abandoned("start_error", "No space left on device")

    def test_the_supervisor_failing_to_launch(self):
        sha = self.commit()
        with self.assertRaises(v.VerificationError) as ctx:
            self.start_in_process(sha, mock.patch.object(run_session.subprocess, "Popen",
                                                         side_effect=fail_supervisor_launch))
        self.assert_refused(ctx, "start-error", "Resource temporarily unavailable")
        self.assert_abandoned("start_error", "Resource temporarily unavailable")

    def test_an_interrupt_during_setup_is_cleaned_up_and_raised_again(self):
        sha = self.commit()
        with self.assertRaises(KeyboardInterrupt):
            self.start_in_process(sha, mock.patch.object(run_session.shutil, "copyfile",
                                                         side_effect=KeyboardInterrupt()))
        self.assert_abandoned("start_interrupted", "KeyboardInterrupt")

    def test_a_named_refusal_during_setup_keeps_its_own_name(self):
        sha = self.commit()
        refusal = v.VerificationError(("guide-unreadable", "the guide could not be read"))
        with self.assertRaises(v.VerificationError) as ctx:
            self.start_in_process(sha, mock.patch.object(run_session.v, "load_guide", side_effect=refusal))
        self.assert_refused(ctx, "guide-unreadable", "the guide could not be read")
        self.assert_abandoned("start_failed", "the guide could not be read")

    def test_a_cleanup_that_fails_is_reported_beside_the_original_error(self):
        sha = self.commit()
        with self.assertRaises(v.VerificationError) as ctx:
            self.start_in_process(sha,
                                  mock.patch.object(run_session.shutil, "copyfile", side_effect=DISK_FULL),
                                  mock.patch.object(run_session, "remove_worktree",
                                                    side_effect=OSError(errno.EACCES, "Permission denied")))
        problems = self.assert_refused(ctx, "disk-full", "No space left on device")
        cleanup = [m for k, m in problems if k == "start-cleanup-failed"]
        self.assertEqual(len(cleanup), 1, problems)
        self.assertIn("Permission denied", cleanup[0])
        rec = self.receipt(self.only_receipt_id())
        self.assertEqual(rec["stopped_by"], "start_error", rec)
        self.assertFalse(rec["worktree_removed"], rec)
        self.assertIn("Permission denied", rec["stop_detail"])
        self.assert_lock_released()
        shutil.rmtree(self.worktree_of(self.only_receipt_id()), ignore_errors=True)

    def test_a_worktree_that_will_not_go_is_reported(self):
        sha = self.commit()
        with self.assertRaises(v.VerificationError) as ctx:
            self.start_in_process(sha,
                                  mock.patch.object(run_session.shutil, "copyfile", side_effect=DISK_FULL),
                                  mock.patch.object(run_session, "remove_worktree", return_value=False))
        problems = self.assert_refused(ctx, "disk-full", "No space left on device")
        cleanup = [m for k, m in problems if k == "start-cleanup-failed"]
        self.assertEqual(len(cleanup), 1, problems)
        self.assertIn(self.worktree_of(self.only_receipt_id()), cleanup[0])
        self.assert_lock_released()

    def test_a_stop_that_cannot_be_recorded_is_reported(self):
        # The receipt folder itself could not be made, so there is nowhere to record the stop: the
        # refusal says so rather than implying the receipt holds one.
        sha = self.commit()
        with self.assertRaises(v.VerificationError) as ctx:
            self.start_in_process(sha, mock.patch.object(run_session.os, "makedirs", side_effect=fail_guides_dir))
        problems = self.assert_refused(ctx, "disk-full", "No space left on device")
        cleanup = [m for k, m in problems if k == "start-cleanup-failed"]
        self.assertEqual(len(cleanup), 1, problems)
        self.assertIn("stop could not be recorded", cleanup[0])
        self.assert_lock_released()

    def test_the_cli_names_the_original_error(self):
        sha = self.commit()
        err = io.StringIO()
        with contextlib.redirect_stderr(err), \
                mock.patch.object(run_session.shutil, "copyfile", side_effect=DISK_FULL), \
                mock.patch.dict(os.environ, self.env()):
            code = run_session.main(["start", "--repo", self.repo, "--sha", sha, "--areas", "invoices"])
        self.assertEqual(code, 8, err.getvalue())
        self.assertIn("disk-full", err.getvalue())
        self.assertIn("No space left on device", err.getvalue())
        self.assert_abandoned("start_error", "No space left on device")


TIED_CHILD = ("import signal, sys\n"
              "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
              "print('up', flush=True)\n"
              "sys.stdin.read()\n")
IN_PROCESS_LIMIT_S = 120  # how long a stop or a cut off run inside this process is waited for: a limit, never a wait


# Serve as a project's serve command often is: a leader that ends when it is asked to, and a process
# it started, in its group, that does not. Both read the one pipe the test writes, so both end with it.
LEADER_WITH_STRAGGLER = ("import subprocess, sys\n"
                         "s = subprocess.Popen([sys.executable, '-c', %r], stdin=sys.stdin, stdout=subprocess.PIPE)\n"
                         "s.stdout.readline()\n"
                         "print('up', flush=True)\n"
                         "sys.stdin.read()\n" % TIED_CHILD)
# What a command started during a cut off says of itself: which of the stop signals it was born with blocked.
SAYS_BLOCKED = ("import signal\n"
                "held = signal.pthread_sigmask(signal.SIG_BLOCK, [])\n"
                "print(sorted(s.name for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP) if s in held))\n")


class Uncollectable:
    """Stands in for serve's Popen where serve is killed and still does not go, the state the stop
    of process 77733 was left in (claude-config#3820). It holds what the stop reads of a Popen: the
    pid, and a returncode that stays None until something collects the process."""

    def __init__(self, real):
        self.pid = real.pid
        self.returncode = None


class FullDisk:
    """Stands in for the supervisor's log on a disk with no room left: every write to it fails."""

    def write(self, text):
        raise OSError(errno.ENOSPC, "No space left on device")

    def flush(self):
        pass


class MonitorThatSaysClean:
    """Stands in for the egress monitor: asked for its verdict, it would call the run clean."""

    proc = None

    def __init__(self):
        self.asked = 0

    def finish(self):
        self.asked += 1
        return {"verdict": "clean", "why": "nothing outside the allowed hosts was reached", "monitor": "a stand in"}


class MonitorHoldingAStream(run_session.egress.Monitor):
    """The real egress monitor, holding as its report stream a process the test started. Asked for
    its verdict, it would call the run clean."""

    def __init__(self, rdir, stream):
        super().__init__(rdir, os.path.basename(rdir), [], 1)
        self.proc, self.asked = stream, 0

    def finish(self):
        self.asked += 1
        return {"verdict": "clean", "why": "nothing outside the allowed hosts was reached", "monitor": "a stand in"}


class MonitorThatCannotStart(MonitorThatSaysClean):
    """Stands in for the egress monitor on a Mac where it cannot start, as a supervisor makes one."""

    def __init__(self, *args):
        super().__init__()

    def start(self):
        return "a stand in that measures nothing"

    def finish(self):
        return {"verdict": "unmeasured", "why": "a stand in that measures nothing", "monitor": "a stand in"}


class CutOffTests(RunFixture):
    """A stop that cannot finish is cut off, and the receipt says so (the #3807 review).

    These call the stop inside this process, on a receipt folder written here, so that the thing a
    stop waits on can be a stand in that never comes. The processes standing in for serve and the
    report stream each read a pipe only this process writes, so they end when it does; each is in a
    session of its own, as the real ones are, and ignores SIGTERM. Nothing waits a fixed time.
    """

    lifeline = False

    def setUp(self):
        super().setUp()
        quiet = contextlib.redirect_stderr(io.StringIO())  # a cut off says so on stderr, the supervisor's log
        self.said = quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)

    def child(self, program=TIED_CHILD):
        p = subprocess.Popen([sys.executable, "-c", program], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             start_new_session=True)
        self.addCleanup(self.end_child, p)
        self.assertEqual(p.stdout.readline(), b"up\n", "the stand in process did not start")
        return p

    def end_child(self, p):
        if p.poll() is None:  # still this process's own child, so the pid is its and nobody else's
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
        p.stdin.close()
        p.stdout.close()

    def a_run_on_disk(self, stop_command=None, **over):
        """A receipt folder as a supervisor leaves it in the middle of a run. Returns its path."""
        rdir = os.path.join(self.home, "receipts", "20260101T000000Z-0000000-abcdef")
        wt = os.path.join(rdir, "worktree")
        os.makedirs(wt)
        with open(os.path.join(rdir, "areas.json"), "w") as f:
            json.dump({"commands": {"stop": stop_command or 'echo ran >> "%s"' % os.path.join(self.fake, "stop-ran")},
                       "egress": {"allow": []},
                       "timeouts": {"stop_s": 1, "egress_s": 1, "max_run_s": 3600}}, f)
        rec = dict(receipt_id=os.path.basename(rdir), repo=self.repo, worktree=wt, stopped_at=None,
                   stopped_by=None, stop_detail=None, serve_pid=None, serve_pgid=None, egress_monitor_pgid=None,
                   egress={"verdict": "unmeasured", "why": run_session.EGRESS_WHY})
        rec.update(over)
        run_session.update_receipt(rdir, **rec)
        return rdir

    def on_disk(self, rdir):
        with open(os.path.join(rdir, "receipt.json")) as f:
            return json.load(f)

    def stops_ran(self):
        try:
            with open(os.path.join(self.fake, "stop-ran")) as f:
                return len(f.readlines())
        except FileNotFoundError:
            return 0

    def test_a_killed_serve_that_cannot_be_collected_ends_the_stop_as_cut_off(self):
        serve, stream = self.child(), self.child()
        rdir = self.a_run_on_disk(serve_pid=serve.pid, serve_pgid=serve.pid, egress_monitor_pgid=stream.pid)
        stuck = Uncollectable(serve)
        monitor = MonitorHoldingAStream(rdir, stream)
        returned, waits, really = [], [], run_session.exited

        def never_goes(child, limit_s):
            # The stop's own two waits for serve to go run out at once, without sleeping, as they
            # would in full for a serve that will not go. The cut off's wait after them is the real one.
            waits.append(limit_s)
            return really(child, limit_s) if len(waits) > 2 else False

        # KILLED_WAIT_S is how long a killed serve is waited for. The stand in's wait runs out at
        # once whatever the limit, so the value only has to be one the stop passes on.
        with mock.patch.object(run_session, "KILLED_WAIT_S", 7), \
                mock.patch.object(run_session, "exited", never_goes):
            stop = threading.Thread(target=lambda: returned.append(
                run_session.do_stop(rdir, "stop", proc=stuck, monitor=monitor)), daemon=True)
            stop.start()
            stop.join(IN_PROCESS_LIMIT_S)
            self.assertFalse(stop.is_alive(), "the stop was still waiting, with no limit, for a killed serve it"
                             " could not collect (it waited with limits %s)" % waits)
        self.assertEqual(waits[:2], [1, 7], "serve gets stop_s to end, then KILLED_WAIT_S once it is killed")
        self.assertEqual(len(returned), 1, "the stop raised instead of ending the run")
        rec = returned[0]
        self.assertEqual(rec, self.on_disk(rdir))
        self.assertTrue(rec["stopped_at"])
        self.assertEqual(rec["stopped_by"], "stop", rec)
        self.assertIn("cut off", rec["stop_detail"])
        self.assertIn("could not be collected", rec["stop_detail"])
        # Never a measured verdict for a run that was cut off: the monitor is not even asked.
        self.assertEqual(rec["egress"]["verdict"], "unmeasured", rec["egress"])
        self.assertIn("cut off", rec["egress"]["why"])
        self.assertEqual(monitor.asked, 0, "the monitor was asked for a verdict on a run that was cut off")
        # Serve and the report stream are ended as the groups of two children this process still
        # holds uncollected, and serve is collected last, so the receipt says truthfully how it ended.
        self.assertEqual(rec["serve_exit"], -signal.SIGKILL, rec)
        self.assertEqual(wait_group_empty(serve.pid), [], "serve's group outlived the cut off")
        self.assertEqual(wait_group_empty(stream.pid), [], "the report stream's group outlived the cut off")
        self.assertEqual(rec["serve_survivors"], [])
        self.assertEqual((rec["stop_command_exit"], self.stops_ran()), (0, 1), "the project's stop command runs once")
        self.assertTrue(rec["worktree_removed"], rec)
        self.assertFalse(os.path.exists(rec["worktree"]))

    def test_a_cut_off_runs_the_projects_stop_command_when_the_stop_never_got_to_it(self):
        serve = self.child()
        rdir = self.a_run_on_disk(serve_pid=serve.pid, serve_pgid=serve.pid)
        rec = run_session.cut_off(rdir, "caller_gone", "its caller was gone and the stop had not finished", proc=serve)
        self.assertEqual((rec["stop_command_exit"], self.stops_ran()), (0, 1))
        self.assertEqual(rec["stopped_by"], "caller_gone", rec)
        self.assertEqual(rec["egress"]["verdict"], "unmeasured", rec["egress"])
        self.assertEqual(rec["serve_exit"], -signal.SIGKILL, rec)
        self.assertEqual(wait_group_empty(serve.pid), [])
        self.assertTrue(rec["worktree_removed"], rec)

    def test_a_stop_that_finishes_after_the_run_was_cut_off_does_not_rewrite_the_receipt(self):
        cut = {"verdict": "unmeasured", "why": "the run was cut off"}
        rdir = self.a_run_on_disk(stopped_at="2026-01-01T00:00:00Z", stopped_by="caller_gone",
                                  stop_detail="the stop did not finish and the run was cut off", egress=cut)
        rec = run_session.do_stop(rdir, "stop", monitor=MonitorThatSaysClean())
        for got in (rec, self.on_disk(rdir)):
            self.assertEqual(got["egress"], cut, "a run that was cut off was given a verdict afterwards")
            self.assertEqual((got["stopped_by"], got["stopped_at"]), ("caller_gone", "2026-01-01T00:00:00Z"))

    def test_a_cut_off_after_the_run_ended_changes_nothing_and_signals_nothing(self):
        serve = self.child()
        clean = {"verdict": "clean", "why": "nothing outside the allowed hosts was reached"}
        rdir = self.a_run_on_disk(stopped_at="2026-01-01T00:00:00Z", stopped_by="stop", egress=clean,
                                  serve_pid=serve.pid, serve_pgid=serve.pid)
        before = self.on_disk(rdir)
        rec = run_session.cut_off(rdir, "caller_gone", "its caller was gone", proc=serve)
        self.assertEqual(rec, before)
        self.assertEqual(self.on_disk(rdir), before)
        self.assertIsNone(serve.poll(), "a run that had already ended was signalled again")
        self.assertEqual(self.stops_ran(), 0)

    def test_cutting_off_leaves_within_its_limit_even_when_the_receipt_cannot_be_written(self):
        rdir = self.a_run_on_disk()
        lock = open(os.path.join(rdir, "receipt.lock"), "a")
        self.addCleanup(lock.close)
        fcntl.flock(lock, fcntl.LOCK_EX)  # the receipt's own lock, held: the cut off cannot write its ending
        left = threading.Event()
        cut = threading.Thread(target=run_session.cut_off_and_leave, daemon=True,
                               args=(rdir, "caller_gone", "its caller was gone"),
                               kwargs={"limit_s": 0.05, "leave": left.set})
        cut.start()
        self.assertTrue(left.wait(IN_PROCESS_LIMIT_S), "the cut off never left though its limit had passed")
        self.assertIsNone(self.on_disk(rdir)["stopped_at"])
        lock.close()
        cut.join(IN_PROCESS_LIMIT_S)
        self.assertFalse(cut.is_alive())

    def test_a_stop_reason_that_cannot_be_written_still_stops_the_run(self):
        # A full disk when the lifeline ends: the watcher used to die there, and the run lived on to
        # its deadline (the #3807 review). The stop must still be asked for, and still read as
        # caller_gone though no reason file says so.
        rdir = self.a_run_on_disk()
        r, w = os.pipe()
        os.close(w)
        self.addCleanup(os.close, r)
        gone, finished, woken = threading.Event(), threading.Event(), []
        finished.set()  # the stop that follows finishes at once: this test is about the asking
        with mock.patch.object(run_session, "record_stop_reason", side_effect=DISK_FULL):
            run_session.watch_lifeline(rdir, r, gone, finished, 60, lambda: (None, None),
                                       wake=lambda: woken.append(True))
        self.assertEqual(woken, [True], "the supervisor was never told to stop")
        self.assertTrue(gone.is_set())
        self.assertIn("No space left on device", self.said.getvalue())
        self.assertEqual(run_session.requested_reason(rdir, "caller_gone" if gone.is_set() else "stop"), "caller_gone")

    def test_a_reason_that_cannot_be_written_leaves_no_empty_reason_behind(self):
        # An empty reason file would stand as an earlier request for ever, and read as `stop`.
        rdir = self.a_run_on_disk()
        with mock.patch.object(run_session.os, "write", side_effect=DISK_FULL):
            with self.assertRaises(OSError):
                run_session.record_stop_reason(rdir, "caller_gone")
        self.assertFalse(os.path.exists(os.path.join(rdir, "stop-reason")), "an empty reason file was left behind")
        self.assertEqual(run_session.requested_reason(rdir, "caller_gone"), "caller_gone")
        self.assertTrue(run_session.record_stop_reason(rdir, "caller_gone"), "a later reason could not be recorded")

    def test_a_caller_that_is_gone_waits_as_long_as_a_stop_still_getting_somewhere_can_take(self):
        # Every wait a stop makes, each at its limit: a stop that slow is slow, not hung, and a
        # supervisor whose caller is gone must not cut it off (the lessons review of #3807).
        timeouts = {"stop_s": 10, "egress_s": 30}
        longest = (10  # the project's stop command
                   + 10 + run_session.KILLED_WAIT_S  # serve, asked to end and then killed
                   + 10 + 10  # serve's group, asked and then killed
                   + run_session.COLLECT_S  # serve, collected last
                   + run_session.egress.finish_budget_s(30))  # the monitor settling
        self.assertGreaterEqual(run_session.stop_longest_s(timeouts), longest)
        self.assertGreater(run_session.stop_longest_s(timeouts), run_session.stop_wait_s(timeouts))

    def test_a_supervisor_whose_stop_finishes_in_time_is_not_cut_off(self):
        rdir = self.a_run_on_disk()
        r, w = os.pipe()
        os.close(w)
        self.addCleanup(os.close, r)
        gone, finished, woken, left = threading.Event(), threading.Event(), [], []
        finished.set()
        run_session.watch_lifeline(rdir, r, gone, finished, 0, lambda: (None, None),
                                   wake=lambda: woken.append(True), leave=lambda: left.append(True))
        self.assertEqual((woken, left), ([True], []))
        self.assertIsNone(self.on_disk(rdir)["stopped_at"], "a run whose stop had finished was cut off")
        with open(os.path.join(rdir, "stop-reason")) as f:
            self.assertEqual(f.read(), "caller_gone")

    # -- a number is signalled only while a child this process holds pins it (the second #3807 review) --
    #
    # A process group's number is its leader's pid. It stays that group's for as long as the leader
    # is this process's child and has not been collected. Once the leader is collected and the group
    # is empty the system may give the number to any new process, so a signal sent to it then can
    # land on a stranger. No test below really sends such a signal: where the code under test would
    # have, os.killpg is a stand in that records the call.

    def recorded_signals(self):
        """os.killpg as a stand in that sends nothing and records what it was asked to send."""
        asked = []
        patch = mock.patch.object(os, "killpg", lambda pgid, sig: asked.append((pgid, signal.Signals(sig).name)))
        patch.start()
        self.addCleanup(patch.stop)
        return asked

    def test_a_cut_off_signals_no_number_whose_child_was_already_collected(self):
        # The state a hung stop leaves: serve collected by the stop, the report stream collected by a
        # monitor that could not start, both numbers in the receipt, and minutes gone by.
        serve, stream = self.child(), self.child()
        for p in (serve, stream):
            os.killpg(p.pid, signal.SIGKILL)  # still this process's own uncollected child
            p.wait()
        rdir = self.a_run_on_disk(serve_pid=serve.pid, serve_pgid=serve.pid, egress_monitor_pgid=stream.pid)
        asked = self.recorded_signals()
        rec = run_session.cut_off(rdir, "caller_gone", "its caller was gone and the stop had not finished",
                                  proc=serve, monitor=MonitorHoldingAStream(rdir, stream))
        self.assertEqual(asked, [], "the cut off signalled a number nothing held any longer: by then it can be"
                         " the process group of something that has nothing to do with this run")
        self.assertEqual(rec, self.on_disk(rdir))
        self.assertEqual(rec["egress"]["verdict"], "unmeasured", rec["egress"])
        self.assertEqual(rec["serve_exit"], -signal.SIGKILL, rec)
        # What it did not signal, and why, is in the receipt: nothing is left without a word.
        self.assertIn("not signalled", rec["stop_detail"])
        self.assertIsNone(rec["serve_survivors"], "the members of a number nothing held were read as serve's")

    def test_a_cut_off_signals_no_number_it_only_read_from_the_receipt(self):
        serve, stream = self.child(), self.child()
        rdir = self.a_run_on_disk(serve_pid=serve.pid, serve_pgid=serve.pid, egress_monitor_pgid=stream.pid)
        asked = self.recorded_signals()
        rec = run_session.cut_off(rdir, "caller_gone", "its caller was gone and the stop had not finished")
        self.assertEqual(asked, [], "the cut off signalled numbers it was handed no child for")
        self.assertIn("not signalled", rec["stop_detail"])
        self.assertIn(str(serve.pid), rec["stop_detail"])
        self.assertIn(str(stream.pid), rec["stop_detail"])

    def test_a_cut_off_ends_the_stream_a_monitor_still_holds(self):
        serve, stream = self.child(), self.child()
        rdir = self.a_run_on_disk(serve_pid=serve.pid, serve_pgid=serve.pid, egress_monitor_pgid=stream.pid)
        monitor = MonitorHoldingAStream(rdir, stream)
        rec = run_session.cut_off(rdir, "caller_gone", "its caller was gone and the stop had not finished",
                                  proc=serve, monitor=monitor)
        self.assertEqual(wait_group_empty(serve.pid), [], "serve's group outlived the cut off")
        self.assertEqual(wait_group_empty(stream.pid), [], "the report stream's group outlived the cut off")
        self.assertEqual(rec["serve_exit"], -signal.SIGKILL, rec)
        self.assertEqual(rec["serve_survivors"], [])
        self.assertNotIn("not signalled", rec["stop_detail"])
        self.assertEqual((rec["egress"]["verdict"], monitor.asked), ("unmeasured", 0))

    def test_a_stop_signals_serves_group_only_while_serve_is_still_uncollected(self):
        # Serve's leader ends when asked and a process in its group does not. The stop must end that
        # one too, and every signal it sends must go while the leader is still uncollected.
        serve = self.child(LEADER_WITH_STRAGGLER)
        rdir = self.a_run_on_disk(serve_pid=serve.pid, serve_pgid=serve.pid)
        really, sent = os.killpg, []

        def killpg(pgid, sig):
            held = serve.returncode is None
            sent.append((pgid, signal.Signals(sig).name, "serve uncollected" if held else "serve COLLECTED"))
            if held:  # a number nothing holds is never really signalled from a test: the call is only recorded
                really(pgid, sig)

        try:
            with mock.patch.object(os, "killpg", killpg):
                rec = run_session.do_stop(rdir, "stop", proc=serve, monitor=MonitorThatSaysClean())
            self.assertEqual([s for s in sent if s[2] != "serve uncollected"], [],
                             "serve's group was signalled by a number serve no longer held")
            self.assertEqual({s[0] for s in sent}, {serve.pid})
            self.assertIn("SIGKILL", [s[1] for s in sent], "the process that ignores SIGTERM was never killed")
            self.assertEqual(rec["serve_survivors"], [])
            self.assertEqual(rec["serve_exit"], -signal.SIGTERM, rec)
            self.assertEqual(serve.returncode, -signal.SIGTERM, "serve was not collected once its group was dealt with")
            self.assertEqual(rec["egress"]["verdict"], "clean", "a stop that finished still asks the monitor")
            self.assertEqual(rec["stop_detail"], None)
        finally:
            serve.stdin.close()  # ends whatever of the group is left, so nothing outlives this test
            self.assertEqual(wait_group_empty(serve.pid), [], "a process of serve's group outlived the stop")

    def test_seeing_that_a_child_has_gone_does_not_collect_it(self):
        ways = [run_session.exited]
        ways += [lambda c, s, way=way: way(c.pid, s) for way in run_session.EXIT_WATCHES if way is not None]
        self.assertGreater(len(ways), 1, "no way of seeing a child go without collecting it was found on this machine")
        for way in ways:
            p = self.child()
            self.assertFalse(way(p, 0.05), "a child that is running was seen as gone")
            self.assertIsNone(p.returncode)
            os.killpg(p.pid, signal.SIGKILL)  # still this process's own uncollected child
            self.assertTrue(way(p, IN_PROCESS_LIMIT_S), "a killed child was never seen to go")
            self.assertIsNone(p.returncode, "seeing it go collected it, and its number is then nobody's")
            self.assertTrue(way(p, 0), "a child that had gone and was not collected was seen as running")
            self.assertEqual(run_session.collect(p, IN_PROCESS_LIMIT_S), -signal.SIGKILL)
            self.assertEqual(p.returncode, -signal.SIGKILL)
            self.assertIsNone(run_session.signal_own(p, signal.SIGKILL), "a collected child's number was signalled")

    def test_nothing_is_signalled_while_something_else_is_collecting_the_child(self):
        # The egress monitor collects its own stream, through the stream's Popen, on the main thread.
        # A Popen collects under a lock of its own, and a signal takes that lock too, so the stream
        # cannot be collected between the check that it is still held and the signal. This test
        # fails on a Python whose Popen no longer has that lock: the signal would then be unguarded.
        p = self.child()
        lock = getattr(p, "_waitpid_lock", None)
        self.assertIsNotNone(lock, "a Popen no longer has the lock it collects under")
        asked = self.recorded_signals()
        with mock.patch.object(run_session, "COLLECTING_WAIT_S", 0.01):
            with lock:  # as a wait with no limit holds it, which may collect the child at any moment
                self.assertIsNone(run_session.signal_own(p, signal.SIGKILL))
        self.assertEqual(asked, [], "a child that was being collected at that moment was signalled")
        self.assertIs(run_session.signal_own(p, signal.SIGKILL), True)
        self.assertEqual(asked, [(p.pid, "SIGKILL")])

    def test_the_system_never_collects_a_child_behind_the_harness(self):
        # A caller that ignores SIGCHLD hands that on, and the system then collects every child the
        # moment it exits: nothing would hold a number, and every exit would read as 0.
        self.addCleanup(signal.signal, signal.SIGCHLD, signal.getsignal(signal.SIGCHLD))
        signal.signal(signal.SIGCHLD, signal.SIG_IGN)
        with mock.patch.dict(os.environ, self.env()):
            run_session.main(["status", "20260101T000000Z-0000000-nosuch"])
        self.assertEqual(signal.getsignal(signal.SIGCHLD), signal.SIG_DFL)

    # -- the rest of what the second #3807 review found --

    def gone_caller(self):
        r, w = os.pipe()
        os.close(w)
        self.addCleanup(os.close, r)
        return r

    def test_a_log_that_cannot_be_written_does_not_stop_the_stop_being_asked_for(self):
        # The supervisor's log is on the same disk as the receipt. With that disk full the line
        # saying why the run is stopping used to raise, before the stop was asked for.
        rdir = self.a_run_on_disk()
        gone, finished, woken = threading.Event(), threading.Event(), []
        finished.set()
        with contextlib.redirect_stderr(FullDisk()):
            run_session.watch_lifeline(rdir, self.gone_caller(), gone, finished, 60, lambda: (None, None),
                                       wake=lambda: woken.append(True))
        self.assertEqual(woken, [True], "the supervisor was never told to stop")

    def test_a_log_that_cannot_be_written_does_not_stop_a_cut_off(self):
        serve, stream = self.child(), self.child()
        rdir = self.a_run_on_disk(serve_pid=serve.pid, serve_pgid=serve.pid, egress_monitor_pgid=stream.pid)
        left = []
        with contextlib.redirect_stderr(FullDisk()):
            run_session.cut_off_and_leave(rdir, "caller_gone", "its caller was gone", proc=serve,
                                          monitor=MonitorHoldingAStream(rdir, stream),
                                          limit_s=IN_PROCESS_LIMIT_S, leave=lambda: left.append(True))
        self.assertEqual(left, [True])
        self.assertEqual(wait_group_empty(serve.pid), [], "the supervisor left and serve was never ended")
        self.assertEqual(wait_group_empty(stream.pid), [], "the supervisor left and the stream was never ended")
        self.assertEqual(self.on_disk(rdir)["egress"]["verdict"], "unmeasured")
        self.assertIn("cut off", self.on_disk(rdir)["stop_detail"])

    def test_a_cut_off_that_cannot_write_its_ending_still_ends_serve_before_it_leaves(self):
        serve, stream = self.child(), self.child()
        rdir = self.a_run_on_disk(serve_pid=serve.pid, serve_pgid=serve.pid, egress_monitor_pgid=stream.pid)
        lock = open(os.path.join(rdir, "receipt.lock"), "a")
        self.addCleanup(lock.close)
        fcntl.flock(lock, fcntl.LOCK_EX)  # the receipt's own lock, held: the cut off cannot write its ending
        left = threading.Event()
        cut = threading.Thread(target=run_session.cut_off_and_leave, daemon=True,
                               args=(rdir, "caller_gone", "its caller was gone"),
                               kwargs={"proc": serve, "monitor": MonitorHoldingAStream(rdir, stream),
                                       "limit_s": 0.05, "leave": left.set})
        cut.start()
        self.assertTrue(left.wait(IN_PROCESS_LIMIT_S), "the cut off never left though its limit had passed")
        self.assertEqual(wait_group_empty(serve.pid, 5), [], "the supervisor left and serve was never ended")
        self.assertEqual(wait_group_empty(stream.pid, 5), [], "the supervisor left and the stream was never ended")
        lock.close()
        cut.join(IN_PROCESS_LIMIT_S)
        self.assertFalse(cut.is_alive())

    def test_what_a_cut_off_starts_from_the_lifelines_thread_is_not_born_deaf_to_a_stop(self):
        said = os.path.join(self.fake, "blocked")
        rdir = self.a_run_on_disk(stop_command='"%s" -c "%s" > "%s"' % (sys.executable, SAYS_BLOCKED, said))
        gone, finished, left = threading.Event(), threading.Event(), threading.Event()
        watch = threading.Thread(target=run_session.watch_lifeline, daemon=True,
                                 args=(rdir, self.gone_caller(), gone, finished, 0, lambda: (None, None)),
                                 kwargs={"wake": lambda: None, "leave": left.set})
        # The thread is born as the supervisor makes it: with the stop signals blocked.
        before = signal.pthread_sigmask(signal.SIG_BLOCK, run_session.STOP_SIGNALS)
        try:
            watch.start()
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, before)
        self.assertTrue(left.wait(IN_PROCESS_LIMIT_S), "the run was never cut off")
        watch.join(IN_PROCESS_LIMIT_S)
        with open(said) as f:
            self.assertEqual(f.read().strip(), "[]", "the project's stop command was started with stop signals"
                             " blocked, so nothing could have asked it to end")

    def test_a_caller_that_goes_wakes_the_supervisor_even_when_an_earlier_stop_stands(self):
        # A `stop` typed before the supervisor had recorded its pid writes the reason and can send
        # no signal. Nothing else would ever wake that supervisor before its run was cut off.
        rdir = self.a_run_on_disk()
        self.assertTrue(run_session.record_stop_reason(rdir, "stop"))
        gone, finished, woken = threading.Event(), threading.Event(), []
        finished.set()
        run_session.watch_lifeline(rdir, self.gone_caller(), gone, finished, 60, lambda: (None, None),
                                   wake=lambda: woken.append(True))
        self.assertEqual(woken, [True], "a supervisor with an earlier stop request standing was never woken")
        self.assertEqual(run_session.requested_reason(rdir), "stop", "the earlier reason was rewritten")

    def test_a_stop_landing_as_the_ok_pipe_closes_still_stops_the_run(self):
        # The supervisor closes the pipe it says "ok" down. A stop acted on right as that close
        # returned used to find the pipe still named, close it a second time, and die of that before
        # it had stopped anything.
        rdir = self.a_run_on_disk()
        r, w = os.pipe()
        self.addCleanup(os.close, r)
        for s in run_session.STOP_SIGNALS:
            self.addCleanup(signal.signal, s, signal.getsignal(s))
        really, closes, null = os.close, [], os.open(os.devnull, os.O_RDONLY)
        self.addCleanup(really, null)

        def close(fd):
            if fd != w:
                return really(fd)
            closes.append(fd)
            if len(closes) > 1:  # a second close of the same number: said here, never done
                raise OSError(errno.EBADF, "Bad file descriptor")
            os.dup2(null, w)  # the pipe's end is closed, and the number is kept so nothing else can take it
            self.addCleanup(really, w)
            raise run_session.StopRequested()  # a stop signal, acted on as the close returns

        with mock.patch.object(os, "close", close), \
                mock.patch.object(run_session.egress, "Monitor", MonitorThatCannotStart):
            code = run_session.supervise(rdir, -1, w)
        self.assertEqual(closes, [w], "the ok pipe was closed twice")
        self.assertEqual(code, 0)
        rec = self.on_disk(rdir)
        self.assertEqual((rec["stopped_by"], rec["worktree_removed"]), ("stop", True), rec)
        self.assertEqual(os.read(r, 16), b"ok\n")
        self.assertEqual(os.read(r, 16), b"", "the ok pipe was left open")


# A test suite, as payload/hooks/test-skill-python-tests.sh runs one: this process builds the
# fixture the tests above use, starts runs through it exactly as they do, says what it started, and
# then waits to be killed. argv: the scripts folder, then one word for each run it is to hold, "tied"
# (the fixture's lifeline in place, as every test above has it) or "untied" (no lifeline, as every
# real run Dan's sessions start has it).
#
# It is itself tied to the test that started it (the #3807 review): it waits by reading its input,
# a pipe only that test writes, so when that test is gone, however it went, the read ends and this
# suite stops what it started and leaves. Killed, as the tests below kill it, it does none of that.
# An untied run can be tied to nothing, which is what it is: its one bound is a shortened deadline.
UNTIED_DEADLINE_SCALE = "0.25"  # of the fixture's 3600 seconds: 15 minutes, many times a slow test
SUITE = r'''
import json, os, subprocess, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import test_run_session as t
held, said = [], []
for word in sys.argv[2:]:
    f = t.RunFixture()
    f.lifeline = word == "tied"
    f.setUp()
    held.append(f)
    r = f.start(f.commit(), deadline="1" if f.lifeline else t.UNTIED_DEADLINE_SCALE)
    said.append({"base": os.path.dirname(f.repo), "home": f.home, "code": r.returncode,
                 "out": r.stdout, "err": r.stderr})
print(json.dumps(said), flush=True)
sys.stdin.read()
ended = []
for f in held:
    for rid in f.started:
        subprocess.run(f.cli("stop", rid), capture_output=True, text=True, env=f.env())
        ended.append(f.receipt(rid))
print(json.dumps(ended), flush=True)  # its folders go when it leaves, so it says how each run ended
'''
SUITE_START_LIMIT_S = 600  # how long a suite may take to bring its runs up: a limit, never a wait


def read_line(pipe, limit_s):
    """One line from a pipe, waited for no longer than limit_s. Returns the line and None, or what
    there was of one and why there is no more: the writer ended, or the limit passed."""
    got, deadline = b"", time.monotonic() + limit_s
    while not got.endswith(b"\n"):
        left = deadline - time.monotonic()
        if left <= 0 or not select.select([pipe], [], [], left)[0]:
            return got, "it said nothing more within %ss" % limit_s
        chunk = os.read(pipe.fileno(), 65536)
        if not chunk:
            return got, "it ended"
        got += chunk
    return got, None


def alive(pid):
    """Whether the pid names a process that is not a zombie, read straight from ps."""
    out = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
    stat = out.stdout.strip()
    return bool(stat) and not stat.startswith("Z")


def pipe_pending(fd):
    """How many bytes sit unread in the pipe whose read end is `fd`."""
    import struct
    import termios
    return struct.unpack("i", fcntl.ioctl(fd, termios.FIONREAD, b"\0\0\0\0"))[0]


def wait_gone(pids, limit_s=30):
    """Wait on the condition, none of `pids` alive, and return those still alive at the limit."""
    deadline = time.monotonic() + limit_s
    while True:
        left = [p for p in pids if p and alive(p)]
        if not left or time.monotonic() >= deadline:
            return left
        time.sleep(0.05)


class SuiteStoppedAsAGroupTests(unittest.TestCase):
    """A suite killed as a process group must not leave a run of its own behind (claude-config#3682).

    The supervisor starts in a session of its own, so a signal to the suite's group never reaches
    it. Every process here is stopped by a pid or receipt this test recorded, never by matching a
    command line (L1011), and nothing waits a fixed time (L290).
    """

    def start_suite(self, *ties):
        """Start a suite that holds one run for each word in `ties`. Returns the suite and, for each
        run in that order, its receipt folder and its receipt as it stood once the run was up."""
        suite = subprocess.Popen([sys.executable, "-B", "-c", SUITE, HERE] + list(ties), stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        self.addCleanup(self.end_suite, suite)
        # The suite prints once its runs are up, or dies saying why. The wait for that has a limit,
        # so a start that hangs fails this test and can never hang it (the #3807 review).
        line, why = read_line(suite.stdout, SUITE_START_LIMIT_S)
        if why:
            self.kill_suite(suite)
            self.fail("the suite did not say what it started (%s); it said: %r %s"
                      % (why, line, suite.stderr.read().decode(errors="replace")[-2000:]))
        runs = []
        for said in json.loads(line):
            self.addCleanup(shutil.rmtree, said["base"], True)
            self.assertEqual(said["code"], 0, said["err"])
            rid = json.loads(said["out"])["receipt_id"]
            rdir = os.path.join(said["home"], "receipts", rid)
            with open(os.path.join(rdir, "receipt.json")) as f:
                rec = json.load(f)
            self.addCleanup(self.stop_run, said["home"], rid, rec)
            self.assertTrue(run_session.supervisor_alive(rdir), "the run was not up when the suite said it was")
            runs.append((rdir, rec))
        return suite, runs

    def kill_suite(self, suite):
        """Stop the suite as a group, the way a cut short push gate does."""
        if suite.poll() is None:
            os.killpg(suite.pid, signal.SIGKILL)
        suite.wait()

    def end_suite(self, suite):
        self.kill_suite(suite)
        for pipe in (suite.stdin, suite.stdout, suite.stderr):
            try:
                pipe.close()
            except OSError:
                pass  # its reader is gone: there is nothing left to flush to

    def stop_run(self, home, rid, rec):
        """Stop the run by its receipt (which signals only the supervisor whose lock is held), then
        confirm by the pids it recorded that nothing it started is left."""
        env = dict(os.environ, VERIFICATION_HOME=home, VERIFICATION_TIME_SCALE="1", VERIFICATION_DEADLINE_SCALE="1")
        env.pop("VERIFICATION_LIFELINE_FD", None)
        subprocess.run([sys.executable, os.path.join(HERE, "run_session.py"), "stop", rid],
                       capture_output=True, text=True, env=env)
        self.assertEqual(wait_gone([rec["supervisor_pid"], rec["serve_pid"]]), [], "the run's processes outlived its stop")
        for pgid in (rec["serve_pgid"], rec.get("egress_monitor_pgid")):
            if pgid:
                self.assertEqual(live_members(pgid), [], "process group %s outlived the stop" % pgid)

    def on_disk(self, rdir):
        with open(os.path.join(rdir, "receipt.json")) as f:
            return json.load(f)

    def assert_ended_by_its_lifeline(self, rdir, rec):
        try:
            run_session.wait_for_supervisor(rdir, timeout_s=stop_limit(rdir))
        except v.VerificationError as e:
            self.fail("the supervisor outlived the suite that started it: %s" % e)
        done = self.on_disk(rdir)
        self.assertEqual(done["stopped_by"], "caller_gone", done)
        self.assertEqual(wait_gone([rec["serve_pid"]]), [], "serve outlived the supervisor that stopped it")
        self.assertEqual(live_members(rec["serve_pgid"]), [], "serve's group outlived the stop")
        self.assertTrue(done["worktree_removed"], done)

    def test_a_run_ends_when_the_suite_that_started_it_is_stopped_as_a_group(self):
        suite, (run,) = self.start_suite("tied")
        self.kill_suite(suite)
        self.assert_ended_by_its_lifeline(*run)

    def test_a_run_with_no_lifeline_outlives_the_suite_that_started_it(self):
        # Every real run: start returns, and the run must keep serving for the drive and stop calls
        # that come in later processes, until stop, serve exiting or its deadline.
        #
        # Looking the moment the suite is dead proves nothing: a run wrongly tied to its caller would
        # still be in the middle of stopping, with every sign of life (the #3807 review). So the suite
        # holds a second run that IS tied, and this waits on the condition that one has ended by its
        # lifeline, receipt written. Both runs lost the suite in the same instant, and by the time
        # the tied one has finished a whole stop, an untied one that was going to react has: the
        # first thing a lifeline that ends does is record why.
        suite, (untied, tied) = self.start_suite("untied", "tied")
        self.kill_suite(suite)
        self.assert_ended_by_its_lifeline(*tied)
        rdir, rec = untied
        self.assertFalse(os.path.exists(os.path.join(rdir, "stop-reason")),
                         "a run with no lifeline was asked to stop when its caller went")
        self.assertTrue(run_session.supervisor_alive(rdir), "a run with no lifeline ended with its caller")
        self.assertTrue(alive(rec["supervisor_pid"]))
        self.assertTrue(live_members(rec["serve_pgid"]), "serve ended with the caller of a run that has no lifeline")
        self.assertIsNone(self.on_disk(rdir)["stopped_at"])
        # And it is still a run in every way: a later process stops it, and the receipt says `stop` did.
        self.stop_run(os.path.dirname(os.path.dirname(rdir)), os.path.basename(rdir), rec)
        self.assertEqual(self.on_disk(rdir)["stopped_by"], "stop")

    def test_a_suite_whose_starter_is_gone_stops_the_run_it_held_and_leaves(self):
        # The suite is not killed here. Its starter going away, which is all the death of this test
        # would do to it, is its input ending: the untied run it holds would otherwise be left with
        # nothing but its deadline (the #3807 review).
        suite, ((rdir, rec),) = self.start_suite("untied")
        limit = stop_limit(rdir) + 60  # read now: the suite's folders go with it
        suite.stdin.close()
        line, why = read_line(suite.stdout, limit)
        self.assertIsNone(why, "the suite did not stop its run once the test that started it let go of it"
                          " (%s); it said: %r" % (why, line))
        (done,) = json.loads(line)
        self.assertEqual((done["receipt_id"], done["stopped_by"]), (rec["receipt_id"], "stop"), done)
        self.assertTrue(done["worktree_removed"], done)
        try:
            suite.wait(timeout=limit)
        except subprocess.TimeoutExpired:
            self.fail("the suite was still running after the test that started it let go of it")
        self.assertEqual(wait_gone([rec["supervisor_pid"], rec["serve_pid"]]), [], "left behind by the suite")
        self.assertEqual(live_members(rec["serve_pgid"]), [], "serve's group outlived the suite's stop")


if __name__ == "__main__":
    unittest.main()
