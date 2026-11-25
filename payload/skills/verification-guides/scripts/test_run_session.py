"""Tests for run_session.py, the RUN harness (claude-config#1528).

Each test builds a throwaway git repository whose areas.json serves a fake app: a Python process
that writes its pid, then blocks writing to a FIFO until the ready command reads it, then waits for
a signal. Nothing here sleeps or waits a fixed time (L290, L524): readiness is the FIFO, the end of
a run is the supervisor's own lock, and VERIFICATION_TIME_SCALE=0 (the poll delays) and
VERIFICATION_DEADLINE_SCALE=0 (the run deadline) make those immediate where a test needs them.

Serve must stop on every path, so every way a run can end is driven here: a normal stop, a ready
command that never succeeds, serve dying by itself, the deadline, and the supervisor killed outright.
"""

import contextlib
import errno
import fcntl
import glob
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
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

    def tearDown(self):
        for rid in self.started:
            subprocess.run(self.cli("stop", rid), capture_output=True, text=True, env=self.env())
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
            "scripts/drive_browser.py": DRIVE_BROWSER,
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
        return dict(os.environ, VERIFICATION_HOME=self.home, FAKE_DIR=self.fake,
                    VERIFICATION_TIME_SCALE=scale, VERIFICATION_DEADLINE_SCALE=deadline, **self.extra_env)

    def cli(self, *args):
        return [sys.executable, os.path.join(HERE, "run_session.py")] + list(args)

    def run_cli(self, *args, scale="1", deadline="1"):
        return subprocess.run(self.cli(*args), capture_output=True, text=True, env=self.env(scale, deadline))

    def start(self, sha, scale="1", areas="invoices", deadline="1"):
        r = self.run_cli("start", "--repo", self.repo, "--sha", sha, "--areas", areas, scale=scale,
                         deadline=deadline)
        if r.returncode == 0:
            self.started.append(json.loads(r.stdout)["receipt_id"])
        return r

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
        run_session.wait_for_supervisor(os.path.join(self.home, "receipts", rid), timeout_s=30)
        rec = self.receipt(rid)
        self.assert_fully_stopped(rec, "serve_exited")
        self.assertEqual(rec["serve_exit"], -signal.SIGKILL)

    def test_the_deadline_stops_serve(self):
        r = self.start(self.commit(ready="true"), scale="0", deadline="0")
        rid = self.only_receipt_id()
        run_session.wait_for_supervisor(os.path.join(self.home, "receipts", rid), timeout_s=30)
        self.assert_fully_stopped(self.receipt(rid), "deadline")
        if r.returncode != 0:
            self.assertIn("serve-stopped", r.stderr)

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


# The helper browser's executable file name, written out here and never read from egress.py: the
# cases below must fail if the rule is ever aimed at another name (L721).
BROWSER = "chrome-headless-shell"

# One connect per "<address>,<port>" argument (UDP) or "<address>,<port>,tcp", saying whether the
# kernel let it happen. A UDP connect sends no packet, so it reaches no host whatever address it
# names. A TCP one is started without waiting and closed at once, and is only ever aimed at 192.0.2.1,
# the reserved address the serve fixture above already connects to. A drive call appends its own
# arguments (open /invoices), which hold no comma and are passed over.
CONNECT_PL = r'''
use Socket qw(:all);
use Fcntl;
$| = 1;
for my $spec (grep { /,/ } @ARGV) {
  my ($host, $port, $tcp) = split /,/, $spec;
  my $v6 = $host =~ /:/;
  socket(my $s, $v6 ? PF_INET6 : PF_INET, $tcp ? SOCK_STREAM : SOCK_DGRAM, 0) or die "socket: $!";
  fcntl($s, F_SETFL, fcntl($s, F_GETFL, 0) | O_NONBLOCK) if $tcp;
  my $addr = $v6 ? pack_sockaddr_in6($port, inet_pton(AF_INET6, $host)) : pack_sockaddr_in($port, inet_aton($host));
  if (connect($s, $addr)) { print "$spec connected\n"; }
  elsif ($!{EINPROGRESS}) { print "$spec started\n"; }
  else { print "$spec failed: $!\n"; }
  close($s);
}
'''


def stand_in_unavailable():
    """Why this machine cannot run a program whose executable FILE has a name of our choosing, or
    None when it can. The rule under test names the helper browser by its executable's file name, so
    the cases need a real executable called that (a copy of perl, which ships with macOS), not a
    script or a link: a script's process is its interpreter, and a link resolves to its target."""
    if NO_SANDBOX:
        return NO_SANDBOX
    if not os.access("/usr/bin/perl", os.X_OK):
        return "/usr/bin/perl is not on this Mac, so no stand in for the helper browser can be made"
    r = subprocess.run(["/usr/bin/perl", "-MSocket", "-e", "1"], capture_output=True, text=True)
    if r.returncode != 0:
        return "/usr/bin/perl cannot load Socket here (exit %d: %s)" % (r.returncode, r.stderr.strip()[:200])
    return None


NO_STAND_IN = stand_in_unavailable()
STAND_IN = unittest.skipIf(NO_STAND_IN, "UNMEASURED, not passed: %s" % NO_STAND_IN)

BROWSER_FLAGS = ["--headless", "--no-sandbox", "--disable-gpu", "--no-first-run", "--disable-background-networking",
                 "--disable-component-update", "--disable-sync", "--proxy-server=http://127.0.0.1:9"]
_REAL_BROWSER = []


def real_browser():
    """(path, None) for a real helper browser this suite can start, else (None, why not). Found where
    Playwright keeps it, then started once on about:blank, outside any sandbox and with a time
    limit: a blank page looks up no address, so that launch connects to nothing (L411)."""
    if _REAL_BROWSER:
        return _REAL_BROWSER[0]
    cache = os.environ.get("PLAYWRIGHT_BROWSERS_PATH") or os.path.expanduser("~/Library/Caches/ms-playwright")
    found = sorted(glob.glob(os.path.join(cache, "chromium_headless_shell-*", "chrome-headless-shell-*", BROWSER)))
    if NO_SANDBOX:
        answer = (None, NO_SANDBOX)
    elif not found:
        answer = (None, "no %s under %s, so there is no real helper browser to start" % (BROWSER, cache))
    else:
        profile = tempfile.mkdtemp(prefix="vg-browser-check-")
        p = subprocess.Popen([found[-1]] + BROWSER_FLAGS + ["--user-data-dir=" + profile, "--dump-dom", "about:blank"],
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                             start_new_session=True)
        try:
            out, err = p.communicate(timeout=60)
            ok = p.returncode == 0 and "<html" in out
            why = None if ok else "exit %s: %s" % (p.returncode, err.strip()[-200:])
        except subprocess.TimeoutExpired:
            why = "still running after 60s"
        finally:
            if p.poll() is None:  # only a browser still running: an exited one's group id may be reused
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                p.wait()
            shutil.rmtree(profile, ignore_errors=True)
        answer = (found[-1], None) if why is None else (None, "%s could not be started here (%s)" % (found[-1], why))
    _REAL_BROWSER.append(answer)
    return answer


# The drive helper of the real browser cases. It serves one page on 127.0.0.1 and opens it in the
# browser named by FAKE_BROWSER, or, when FAKE_BROWSER_GOES is "outside", sends the browser to
# 192.0.2.1 (TEST-NET-1, reserved for documentation, the same stand in for an outside host the serve
# fixture above uses) and waits for the monitor to name it. The browser sends every other address
# to a dead proxy on this machine, has a time limit, and is stopped by its process group.
DRIVE_BROWSER = r'''
import http.server, json, os, shutil, signal, subprocess, sys, tempfile, threading, time

d = os.environ["FAKE_DIR"]
flags = json.loads(os.environ["FAKE_BROWSER_FLAGS"])


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>t</title><p>served on this machine</p>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=srv.serve_forever, daemon=True).start()
outside = os.environ.get("FAKE_BROWSER_GOES") == "outside"
url = "http://192.0.2.1:8080/" if outside else "http://127.0.0.1:%d/" % srv.server_address[1]
profile = tempfile.mkdtemp(dir=d)
out_path = os.path.join(profile, "dom")
cmd = [os.environ["FAKE_BROWSER"]] + flags + ["--user-data-dir=" + profile]
if outside:
    cmd.append("--proxy-bypass-list=192.0.2.1")
said = "the browser was still running after 60s"
with open(out_path, "w") as dom:
    p = subprocess.Popen(cmd + ["--dump-dom", url], stdin=subprocess.DEVNULL, stdout=dom,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        deadline = time.monotonic() + 60
        events = os.path.join(os.environ["VERIFICATION_RECEIPT_DIR"], "egress.jsonl")
        while time.monotonic() < deadline:
            if outside:
                with open(events) as f:
                    if "192.0.2.1" in f.read():
                        said = "192.0.2.1 named"
                        break
                if p.poll() is not None:
                    said = "the browser exited %s before the monitor named 192.0.2.1" % p.returncode
                    break
            elif p.poll() is not None:
                with open(out_path) as f:
                    said = "page loaded" if "served on this machine" in f.read() else "exit %s, no page" % p.returncode
                break
            time.sleep(0.05)
    finally:
        if p.poll() is None:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            p.wait()
shutil.rmtree(profile, ignore_errors=True)
with open(os.path.join(d, "drive-out"), "w") as f:
    f.write(said + "\n")
'''


class EgressTests(RunFixture):
    """The egress monitor (claude-config#1571): a run's receipt says what serve and the drive helper
    reached outside this machine, judged against areas.json's egress.allow, and the merge check in
    block mode passes only a clean verdict. The fixtures reach 127.0.0.1 and ::1, or 192.0.2.1,
    which is TEST-NET-1: reserved for documentation, so no real host is ever contacted."""

    def run_to_receipt(self, connect, drive_connect=None, wait_for=None, commands=None):
        self.extra_env = dict(self.extra_env, FAKE_CONNECT=connect)
        drive = None
        if drive_connect:
            drive = ('python3 -c "import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM);'
                     ' s.connect((\'%s\', 9))"' % drive_connect)
        sha = self.commit(**dict({"drive": drive} if drive else {}, **(commands or {})))
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
        # A canary is a round of three connections (claude-config#3319), and the receipt counts them
        # by connection: a whole number of rounds was fired, and no more were seen than fired.
        self.assertEqual(canaries["fired"], 3 * canaries["rounds"], egress)
        self.assertGreaterEqual(canaries["rounds"], 2, egress)  # the start canary and the end canary
        self.assertLessEqual(canaries["seen"], canaries["fired"], egress)
        self.assertEqual(sum(canaries["unseen"].values()), canaries["fired"] - canaries["seen"], egress)
        if beats["reported"] < beats["fired"] or canaries["seen"] < canaries["fired"]:
            # Said in the test's own output, so a run of the suite shows which arm each test took.
            sys.stderr.write("[this Mac withheld %d of %d test connections and %d of %d canary connections %s;"
                             " the run read %s] "
                             % (beats["fired"] - beats["reported"], beats["fired"],
                                canaries["fired"] - canaries["seen"], canaries["fired"],
                                json.dumps(canaries["unseen"], sort_keys=True), egress["verdict"]))
            return True
        return False

    def assert_only_what_was_seen_on_a_mac_that_withheld(self, rid, sha, egress, made, refusable=()):
        """The withheld arm of a run whose fixture made connections off this machine: `made` is every
        (process, port) it made that leaves, `refusable` the refused entries its drive call can
        produce. Some of their reports may never have been written, so the run shows a part of them
        and never anything else. Seeing any of them it reads not-clean, with the gap said beside
        it; seeing none it reads unmeasured. Either way the merge is refused, and it is never clean."""
        seen = set(self.left(egress))
        self.assertLessEqual(seen, set(made), egress)
        self.assertLessEqual(set(self.refused(egress)), set(refusable), egress)
        if not seen:
            return self.assert_unmeasured_because_reports_were_withheld(rid, sha, egress)
        self.assertEqual(egress["verdict"], "not-clean", egress)
        self.assertIn(WITHHELD, egress["why"])
        out = self.merge_verdict(rid, sha)
        self.assertEqual(out["decision"], "refuse")
        self.assertEqual(sorted({p["kind"] for p in out["problems"]}), ["egress-not-clean"])

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
        if self.withheld(egress):  # what was seen is never downgraded, and the gap is said beside it
            self.assertIn(WITHHELD, egress["why"])

    # The one refusal (claude-config#3319).
    # The helper browser a drive call starts asks, before its first address lookup, whether a fixed
    # public IPv6 address could be reached: a UDP connect to port 443 that sends nothing and that the
    # monitor could never name, so every run with a browser was not clean. The drive profile refuses
    # that one kind of connection for that one executable, and each refusal is written into the record.
    # 198.51.100.1 is TEST-NET-2 and 192.0.2.1 TEST-NET-1: reserved, so no real host is contacted.
    #
    # These runs go through the real sandbox too, so they read by the same rule as the four above
    # (claude-config#3576): what the kernel DID to a connection (the program's own words, in
    # drive-out) is asserted on every Mac, since no report is needed for it. What the run READ is
    # asserted in full where every report the monitor asked for arrived, and on a Mac whose receipt
    # shows one withheld it is unmeasured, or not-clean for whatever was seen, and never clean.

    def stand_in(self, name):
        """A real executable whose file is called `name` (a copy of perl), and the script it runs."""
        bindir = os.path.join(self.fake, "bin")
        os.makedirs(bindir, exist_ok=True)
        path = os.path.join(bindir, name)
        shutil.copy("/usr/bin/perl", path)
        r = subprocess.run([path, "-MSocket", "-e", "1"], capture_output=True, text=True)
        if r.returncode != 0:
            self.skipTest("UNMEASURED, not passed: a copy of perl named %s does not run here (exit %d: %s)"
                          % (name, r.returncode, r.stderr.strip()[:200]))
        with open(os.path.join(self.fake, "connect.pl"), "w") as f:
            f.write(CONNECT_PL)

    def udp(self, program, *specs, out="drive-out"):
        """The shell words that have `program` try one UDP connect per "<address>,<port>"."""
        return '"$FAKE_DIR/bin/%s" "$FAKE_DIR/connect.pl" %s > "$FAKE_DIR/%s"' % (program, " ".join(specs), out)

    def said(self, name="drive-out"):
        with open(os.path.join(self.fake, name)) as f:
            return f.read().splitlines()

    def events(self, rid, *kinds):
        with open(os.path.join(self.home, "receipts", rid, "egress.jsonl")) as f:
            return [e for e in map(json.loads, f) if e.get("event") in kinds]

    def left(self, egress):
        """(process, port) of every connection the receipt says left this machine, named or not."""
        return sorted([(u["process"], u["port"]) for u in egress["unnamed"]]
                      + [(p, d["port"]) for d in egress["destinations"] for p in d["processes"]])

    def refused(self, egress):
        return [(r["process"], r["port"], r["by_the_rule"]) for r in egress["refused"]]

    @STAND_IN
    def test_the_helper_browsers_udp_443_is_refused_and_recorded_and_the_run_is_clean(self):
        self.stand_in(BROWSER)
        rid, sha, rec = self.run_to_receipt("local", commands={"drive": self.udp(BROWSER, "198.51.100.1,443")})
        self.assertEqual(self.said(), ["198.51.100.1,443 failed: Operation not permitted"])
        egress = rec["egress"]
        self.assertEqual((egress["destinations"], egress["unnamed"]), ([], []), egress)
        if self.withheld(egress):
            self.assertIn(self.refused(egress), ([], [(BROWSER, 443, True)]), egress)
            return self.assert_unmeasured_because_reports_were_withheld(rid, sha, egress)
        self.assertEqual(egress["verdict"], "clean", egress)
        self.assertEqual(self.refused(egress), [(BROWSER, 443, True)])
        self.assertGreaterEqual(egress["refused"][0]["reports"], 1)
        self.assertIn("refused", egress["why"])
        written = self.events(rid, "refused", "report")
        self.assertEqual([(e["event"], e["process"], e["port"]) for e in written], [("refused", BROWSER, 443)])
        out = self.merge_verdict(rid, sha)
        self.assertEqual((out["problems"], out["decision"]), ([], "allow"))

    def reported(self, rid):
        """(process, port) of every connection the record says left this machine. Never a count: the
        kernel collapses repeats of one line, so a count is a lower bound."""
        return sorted({(e["process"], e["port"]) for e in self.events(rid, "report")})

    @STAND_IN
    def test_the_helper_browser_on_every_other_route_is_still_reported_and_not_clean(self):
        # The control: the same executable, off this machine, on every route but the refused one.
        # UDP one port over, UDP on another port, and TCP to port 443 itself, which is where a page
        # lands when HTTP/3 is refused. Each is let through and reported, the run is not clean, and
        # the refusal beside them is counted apart.
        self.stand_in(BROWSER)
        rid, sha, rec = self.run_to_receipt("local", commands={"drive": self.udp(
            BROWSER, "198.51.100.1,443", "198.51.100.1,9", "198.51.100.1,8443", "192.0.2.1,443,tcp")})
        self.assertEqual(self.said(), ["198.51.100.1,443 failed: Operation not permitted", "198.51.100.1,9 connected",
                                       "198.51.100.1,8443 connected", "192.0.2.1,443,tcp started"])
        egress = rec["egress"]
        if self.withheld(egress):
            return self.assert_only_what_was_seen_on_a_mac_that_withheld(
                rid, sha, egress, [(BROWSER, 9), (BROWSER, 443), (BROWSER, 8443)], [(BROWSER, 443, True)])
        self.assertEqual(egress["verdict"], "not-clean", egress)
        self.assertEqual(sorted(set(self.left(egress))), [(BROWSER, 9), (BROWSER, 443), (BROWSER, 8443)])
        self.assertEqual(self.refused(egress), [(BROWSER, 443, True)])
        self.assertEqual(self.reported(rid), [(BROWSER, 9), (BROWSER, 443), (BROWSER, 8443)])
        self.assertEqual([(e["process"], e["port"]) for e in self.events(rid, "refused")], [(BROWSER, 443)])
        out = self.merge_verdict(rid, sha)
        self.assertEqual(out["decision"], "refuse")
        self.assertEqual(sorted({p["kind"] for p in out["problems"]}), ["egress-not-clean"])

    @STAND_IN
    def test_another_program_in_a_drive_call_is_not_refused_and_is_reported_as_before(self):
        # Every route, the refused one included: under the profile of drive calls a program that is
        # not the helper browser is refused nothing, and nothing it does goes unreported. With one
        # line fewer in that profile its UDP connect to port 443 passed in silence (macOS 26.6.2).
        # Two programs, so the two connections to port 443 are two lines no count could merge.
        self.stand_in("other-program")
        self.stand_in("other-by-tcp")
        rid, sha, rec = self.run_to_receipt("local", commands={"drive": "%s; %s" % (
            self.udp("other-program", "198.51.100.1,443", "198.51.100.1,9"),
            self.udp("other-by-tcp", "192.0.2.1,443,tcp", out="drive-out-tcp"))})
        self.assertEqual(self.said(), ["198.51.100.1,443 connected", "198.51.100.1,9 connected"])
        self.assertEqual(self.said("drive-out-tcp"), ["192.0.2.1,443,tcp started"])
        egress = rec["egress"]
        everything = [("other-by-tcp", 443), ("other-program", 9), ("other-program", 443)]
        self.assertEqual(self.events(rid, "refused"), [])
        if self.withheld(egress):
            return self.assert_only_what_was_seen_on_a_mac_that_withheld(rid, sha, egress, everything)
        self.assertEqual(egress["verdict"], "not-clean", egress)
        self.assertEqual(sorted(set(self.left(egress))), everything)
        self.assertEqual(self.reported(rid), everything)
        self.assertEqual(egress["refused"], [])
        self.assertEqual(self.events(rid, "refused"), [])

    @STAND_IN
    def test_the_served_app_running_the_same_executable_is_not_refused(self):
        # The rule is in the drive profile only. Serve's tree runs an executable with the browser's
        # name, makes the same connection, and it is allowed and reported as it always was.
        self.stand_in(BROWSER)
        serve = self.udp(BROWSER, "198.51.100.1,443", out="serve-out") + "; exec python3 scripts/fake_serve.py"
        rid, sha, rec = self.run_to_receipt("local", commands={"serve": serve})
        self.assertEqual(self.said("serve-out"), ["198.51.100.1,443 connected"])
        egress = rec["egress"]
        self.assertEqual(egress["refused"], [])
        if self.withheld(egress):
            return self.assert_only_what_was_seen_on_a_mac_that_withheld(rid, sha, egress, [(BROWSER, 443)])
        self.assertEqual(egress["verdict"], "not-clean", egress)
        self.assertEqual(self.left(egress), [(BROWSER, 443)])

    @STAND_IN
    def test_udp_to_port_443_on_this_machine_is_not_refused(self):
        self.stand_in(BROWSER)
        rid, sha, rec = self.run_to_receipt(
            "local", commands={"drive": self.udp(BROWSER, "127.0.0.1,443", "::1,443")})
        self.assertEqual(self.said(), ["127.0.0.1,443 connected", "::1,443 connected"])
        egress = rec["egress"]
        self.assertEqual((egress["refused"], egress["destinations"], egress["unnamed"]), ([], [], []))
        if self.withheld(egress):
            return self.assert_unmeasured_because_reports_were_withheld(rid, sha, egress)
        self.assertEqual(egress["verdict"], "clean", egress)

    def with_a_real_browser(self, goes=None):
        path, why = real_browser()
        if not path:
            self.skipTest("UNMEASURED, not passed: %s" % why)
        self.extra_env = dict(self.extra_env, FAKE_BROWSER=path, FAKE_BROWSER_FLAGS=json.dumps(BROWSER_FLAGS),
                              **({"FAKE_BROWSER_GOES": goes} if goes else {}))

    def test_a_real_helper_browser_launch_ends_clean_with_its_probe_refused_and_recorded(self):
        self.with_a_real_browser()
        rid, sha, rec = self.run_to_receipt("local", commands={"drive": "python3 scripts/drive_browser.py"})
        self.assertEqual(self.said(), ["page loaded"])
        egress = rec["egress"]
        self.assertEqual((egress["destinations"], egress["unnamed"]), ([], []), egress)
        self.assertEqual(self.events(rid, "report"), [])
        if self.withheld(egress):
            # The record of the refusal is a line this Mac may not have written either.
            self.assertIn(self.refused(egress), ([], [(BROWSER, 443, True)]), egress)
            return self.assert_unmeasured_because_reports_were_withheld(rid, sha, egress)
        self.assertEqual(egress["verdict"], "clean", egress)
        self.assertEqual(self.refused(egress), [(BROWSER, 443, True)])
        self.assertGreaterEqual(len(self.events(rid, "refused")), 1)
        out = self.merge_verdict(rid, sha)
        self.assertEqual((out["problems"], out["decision"]), ([], "allow"))

    def test_a_real_helper_browser_reaching_outside_by_tcp_is_still_not_clean(self):
        # The control with the real browser: a TCP connection to an address off this machine is
        # reported, named and not clean, whatever the refusal rule did to its probe.
        self.with_a_real_browser(goes="outside")
        rid, sha, rec = self.run_to_receipt("local", commands={"drive": "python3 scripts/drive_browser.py"})
        egress = rec["egress"]
        named = [d for d in egress["destinations"] if d["address"] == "192.0.2.1"]
        if not named:
            # Only a Mac that withheld reports may fail to name it, and then the run is never clean.
            self.assertTrue(self.withheld(egress), (self.said(), egress))
            return self.assert_only_what_was_seen_on_a_mac_that_withheld(
                rid, sha, egress, [(BROWSER, 8080)], [(BROWSER, 443, True)])
        self.assertEqual(self.said(), ["192.0.2.1 named"])
        self.assertEqual(egress["verdict"], "not-clean", egress)
        self.assertEqual([(d["port"], d["processes"], d["allowed"]) for d in named], [(8080, [BROWSER], False)])
        if self.withheld(egress):  # what was seen is never downgraded, and the gap is said beside it
            self.assertIn(WITHHELD, egress["why"])
        out = self.merge_verdict(rid, sha)
        self.assertEqual(out["decision"], "refuse")
        self.assertIn("192.0.2.1", out["text"])

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
        self.assertIsNone(rec.get("egress_drive_sandbox"), "nor a drive call under one that refuses unseen")
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
        run_session.wait_for_supervisor(os.path.join(self.home, "receipts", rid), timeout_s=30)
        rec = self.receipt(rid)
        self.assertEqual(rec["stopped_by"], "deadline", rec)
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


if __name__ == "__main__":
    unittest.main()
