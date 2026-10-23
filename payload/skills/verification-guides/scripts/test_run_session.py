"""Tests for run_session.py, the RUN harness (claude-config#1528).

Each test builds a throwaway git repository whose areas.json serves a fake app: a Python process
that writes its pid, then blocks writing to a FIFO until the ready command reads it, then waits for
a signal. Nothing here sleeps or waits a fixed time (L290, L524): readiness is the FIFO, the end of
a run is the supervisor's own lock, and VERIFICATION_TIME_SCALE=0 (the poll delays) and
VERIFICATION_DEADLINE_SCALE=0 (the run deadline) make those immediate where a test needs them.

Serve must stop on every path, so every way a run can end is driven here: a normal stop, a ready
command that never succeeds, serve dying by itself, the deadline, and the supervisor killed outright.
"""

import json
import os
import signal
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
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
import os, signal, sys
d = os.environ["FAKE_DIR"]
with open(os.path.join(d, "serve.pid"), "w") as f:
    f.write(str(os.getpid()))
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
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


class RunSessionTests(unittest.TestCase):
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

    def env(self, scale="1", deadline="1"):
        return dict(os.environ, VERIFICATION_HOME=self.home, FAKE_DIR=self.fake,
                    VERIFICATION_TIME_SCALE=scale, VERIFICATION_DEADLINE_SCALE=deadline)

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
        os.kill(rec["supervisor_pid"], signal.SIGKILL)
        self.assertTrue(live_members(rec["serve_pgid"]), "serve should outlive its supervisor")
        s = self.run_cli("stop", rid)
        self.assertEqual(s.returncode, 0, s.stderr)
        self.assert_fully_stopped(self.receipt(rid), "recovered")

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


if __name__ == "__main__":
    unittest.main()
