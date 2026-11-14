"""Tests for shoot_native.py, the drive helper that photographs a native screen (claude-config#2696).

The offscreen test it runs is a stub here, a Python script standing in for `xcodebuild test` or
`swift test`, so the contract is exercised without Xcode: what the helper hands the test, and every
way a test can fail to leave a picture worth publishing. No Swift camera runs here: the native
app's own test does the drawing, and this suite proves only the hand over and the judging.
"""

import json
import os
import struct
import sys
import tempfile
import time
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import shoot_native as n  # noqa: E402

ARGS = ["screenshot-native", "AppHostedTests/VerificationScreens", "invoice-list", "1440", "dark",
        "invoices__list__head__1440__dark.png", "13"]

# The stand in for the project's offscreen test. MODE picks what it does; it always records the
# environment and working folder it was given, so the hand over itself is asserted.
STUB = r'''
import json, os, struct, sys, time, zlib
mode = sys.argv[1]
env = {k: v for k, v in os.environ.items() if "VERIFICATION_SHOT" in k}
with open(os.path.join(os.environ["STUB_SPY"], "seen.json"), "w") as f:
    json.dump({"env": env, "cwd": os.getcwd()}, f)

def png(width, height):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    raw = b"".join(b"\x00" + b"\x7f" * (width * 3) for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))

out = os.environ["VERIFICATION_SHOT_FILE"]
width = int(os.environ["VERIFICATION_SHOT_WIDTH"])
if mode == "fail":
    print("Testing failed: frame invoice-list drew nothing"); sys.exit(65)
if mode == "nothing":
    print("Executed 0 tests, with 0 failures"); sys.exit(0)
if mode == "sleep":
    time.sleep(60); sys.exit(0)
if mode == "stubborn":
    # A child that ignores SIGTERM, as a test runner mid build can, left behind its parent.
    import subprocess
    child = subprocess.Popen([sys.executable, "-c",
                              "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"])
    open(os.path.join(os.environ["STUB_SPY"], "child.pid"), "w").write(str(child.pid))
    time.sleep(60); sys.exit(0)
if mode == "notpng":
    open(out, "wb").write(b"GIF89a not a png")
elif mode == "narrow":
    open(out, "wb").write(png(1280, 4))
else:
    open(out, "wb").write(png(width * 2, 4))
if mode == "rows":
    open(os.environ["VERIFICATION_SHOT_ROWS_FILE"], "w").write(sys.argv[2])
if mode == "ok":
    open(os.environ["VERIFICATION_SHOT_ROWS_FILE"], "w").write("13\n")
'''


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.rdir = os.path.join(self.tmp.name, "receipt")
        self.wt = os.path.join(self.rdir, "worktree")
        self.spy = os.path.join(self.tmp.name, "spy")
        for d in (self.wt, self.spy):
            os.makedirs(d)
        self.stub = os.path.join(self.tmp.name, "stub.py")
        with open(self.stub, "w") as f:
            f.write(STUB)
        self.env = {"VERIFICATION_RECEIPT_DIR": self.rdir, "VERIFICATION_WORKTREE": self.wt,
                    "VERIFICATION_URL": "http://127.0.0.1:1", "VERIFICATION_AREA": "invoices",
                    "PATH": os.environ.get("PATH", ""), "STUB_SPY": self.spy}

    def tearDown(self):
        self.tmp.cleanup()

    def areas(self, command):
        doc = {"schema": "verification-areas/1", "mode": "warn", "url": "http://127.0.0.1:1",
               "commands": {"serve": "x", "ready": "true", "stop": "true", "drive": "x"},
               "seeds": {"demo": {"synthetic": True, "why": "thirteen made up invoices"}},
               "areas": [{"name": "invoices", "guide": "g/invoices.md", "owns": ["**"],
                          "screens": [{"name": "list", "test": "AppHostedTests/VerificationScreens",
                                       "frame": "invoice-list", "seed": "demo", "min_rows": 13}]}]}
        if command is not None:
            doc["commands"]["native_shot"] = command
        with open(os.path.join(self.rdir, "areas.json"), "w") as f:
            json.dump(doc, f)

    def run_mode(self, *mode, args=ARGS, env=None):
        self.areas("%s %s %s" % (sys.executable, self.stub, " ".join(mode)))
        return n.main(args, dict(self.env, **(env or {})))

    def out(self):
        return os.path.join(self.rdir, ARGS[5])

    def seen(self):
        with open(os.path.join(self.spy, "seen.json")) as f:
            return json.load(f)


class Contract(Base):
    def test_the_screenshots_py_contract_reads_into_one_shot(self):
        o = n.parse_shot(ARGS, self.env)
        self.assertEqual((o["test"], o["frame"], o["width"], o["theme"], o["min_rows"]),
                         ("AppHostedTests/VerificationScreens", "invoice-list", 1440, "dark", 13))
        self.assertEqual(o["out"], self.out())

    def test_anything_but_a_native_screenshot_belongs_to_the_project_helper(self):
        for argv in (["screenshot", "/invoices", "1440", "dark", "x.png", "-", "0"], ["check", "C1"], []):
            with self.assertRaises(n.Usage):
                n.parse_shot(argv, self.env)

    def test_a_bad_argument_is_a_usage_fault_naming_it(self):
        cases = [(5, "../escape.png", "picture name"), (4, "sepia", "light or dark"), (3, "wide", "width"),
                 (3, "100", "width"), (6, "-1", "row count"), (6, "many", "row count"),
                 (1, "Target/$(id)", "test"), (2, "Invoice List", "frame"),
                 # isdigit() is true for a superscript that int() refuses: a usage fault, not a traceback.
                 (3, "1440²", "width"), (6, "1²", "row count"),
                 # $ also matches before a trailing newline: none may ride into the test's environment.
                 (1, "Target/Suite\n", "test"), (2, "invoice-list\n", "frame"), (3, "1440\n", "width"),
                 (5, "x.png\n", "picture name")]
        for i, value, word in cases:
            argv = list(ARGS)
            argv[i] = value
            with self.assertRaises(n.Usage) as e:
                n.parse_shot(argv, self.env)
            self.assertIn(word, str(e.exception), value)

    def test_outside_run_session_drive_there_is_no_receipt_to_write_into(self):
        with self.assertRaises(n.Usage) as e:
            n.parse_shot(ARGS, {})
        self.assertIn("run_session.py drive", str(e.exception))

    def test_a_run_whose_areas_json_names_no_shot_command_is_a_usage_fault(self):
        self.areas(None)
        self.assertEqual(n.main(ARGS, self.env), 2)

    def test_the_png_reader_gives_the_size_and_refuses_what_is_not_one(self):
        path = os.path.join(self.tmp.name, "a.png")
        with open(path, "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", 2880, 1800) + b"\x08\x02")
        self.assertEqual(n.png_size(path), (2880, 1800))
        with open(path, "wb") as f:
            f.write(b"GIF89a")
        self.assertIsNone(n.png_size(path))
        self.assertIsNone(n.png_size(os.path.join(self.tmp.name, "absent.png")))


class Shooting(Base):
    def test_a_test_that_draws_the_frame_at_its_count_is_saved(self):
        self.assertEqual(self.run_mode("ok"), 0)
        self.assertEqual(n.png_size(self.out())[0], 2880)

    def test_the_test_is_handed_its_frame_in_both_spellings_and_runs_in_the_worktree(self):
        self.run_mode("ok")
        seen = self.seen()
        self.assertEqual(os.path.realpath(seen["cwd"]), os.path.realpath(self.wt))
        env = seen["env"]
        want = {"TEST": "AppHostedTests/VerificationScreens", "FRAME": "invoice-list", "WIDTH": "1440",
                "HEIGHT": str(n.HEIGHT), "THEME": "dark", "MIN_ROWS": "13", "FILE": self.out()}
        for key, value in want.items():
            self.assertEqual(env["VERIFICATION_SHOT_" + key], value, key)
            self.assertEqual(env["TEST_RUNNER_VERIFICATION_SHOT_" + key], value,
                             "xcodebuild hands a test only what carries the TEST_RUNNER_ prefix")
        self.assertIn("VERIFICATION_SHOT_ROWS_FILE", env)

    def test_a_test_that_fails_is_not_shot_and_its_output_is_named(self):
        self.assertEqual(self.run_mode("fail"), 1)
        self.assertFalse(os.path.exists(self.out()))
        with open(os.path.join(self.rdir, "native-shot", ARGS[5] + ".log")) as f:
            self.assertIn("drew nothing", f.read())

    def test_a_test_run_that_exits_0_and_saves_nothing_is_not_shot(self):
        # A filter matching no test runs zero tests and passes (L98): the picture is the only proof.
        self.assertEqual(self.run_mode("nothing"), 1)
        self.assertFalse(os.path.exists(self.out()))

    def test_a_picture_left_by_an_earlier_shot_never_stands_for_this_one(self):
        with open(self.out(), "wb") as f:
            f.write(b"\x89PNG stale")
        self.assertEqual(self.run_mode("nothing"), 1)
        self.assertFalse(os.path.exists(self.out()))

    def test_a_picture_at_the_wrong_width_is_removed_and_not_shot(self):
        self.assertEqual(self.run_mode("narrow"), 1)
        self.assertFalse(os.path.exists(self.out()))

    def test_a_file_that_is_not_a_png_is_removed_and_not_shot(self):
        self.assertEqual(self.run_mode("notpng"), 1)
        self.assertFalse(os.path.exists(self.out()))

    def test_a_frame_short_of_its_row_count_is_not_shot(self):
        self.assertEqual(self.run_mode("rows", "12"), 1)
        self.assertFalse(os.path.exists(self.out()))

    def test_a_frame_that_reports_no_row_count_when_one_is_asked_is_not_shot(self):
        self.assertEqual(self.run_mode("wide"), 1)
        self.assertFalse(os.path.exists(self.out()))

    def test_a_row_count_that_is_not_a_number_is_not_shot(self):
        self.assertEqual(self.run_mode("rows", "lots"), 1)
        self.assertEqual(self.run_mode("rows", "13²"), 1)
        self.assertFalse(os.path.exists(self.out()))

    def test_no_row_count_is_needed_when_none_is_asked(self):
        argv = list(ARGS)
        argv[6] = "0"
        self.assertEqual(self.run_mode("wide", args=argv), 0)

    def test_a_test_that_runs_past_its_deadline_is_stopped_and_not_shot(self):
        started = time.monotonic()
        self.assertEqual(self.run_mode("sleep", env={"SHOOT_NATIVE_TIMEOUT_S": "0.5"}), 1)
        self.assertLess(time.monotonic() - started, 20, "the stub sleeps 60 s; the deadline stopped it")
        self.assertFalse(os.path.exists(self.out()))

    def test_a_deadline_that_is_not_a_number_is_a_usage_fault(self):
        for bad in ("soon", "0", "-5", "inf", "nan", "infinity"):
            self.assertEqual(self.run_mode("ok", env={"SHOOT_NATIVE_TIMEOUT_S": bad}), 2, bad)

    def test_a_child_that_ignores_the_stop_is_killed_with_the_rest_of_its_group(self):
        grace = n.STOP_GRACE_S
        n.STOP_GRACE_S = 0.5
        try:
            self.assertEqual(self.run_mode("stubborn", env={"SHOOT_NATIVE_TIMEOUT_S": "1"}), 1)
        finally:
            n.STOP_GRACE_S = grace
        with open(os.path.join(self.spy, "child.pid")) as f:
            pid = int(f.read())
        deadline = time.monotonic() + 10
        alive = True
        while alive and time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
                time.sleep(0.05)
            except ProcessLookupError:
                alive = False
        if alive:
            os.kill(pid, 9)
        self.assertFalse(alive, "the child ignoring SIGTERM outlived the stop")


class BothEnds(Base):
    """screenshots.py shoot's arguments, handed to this helper as run_session.py drive would."""

    def test_every_native_shot_screenshots_py_asks_for_is_taken_and_found(self):
        import screenshots as s
        import verification as v
        home = os.path.join(self.tmp.name, "home")
        rid = "20261114T010000Z-1111111-a1b2c3"
        rdir = v.receipt_dir(rid, home)
        os.makedirs(os.path.join(rdir, "worktree"))
        self.rdir, self.wt = rdir, os.path.join(rdir, "worktree")
        self.areas("%s %s ok" % (sys.executable, self.stub))
        with open(os.path.join(rdir, "areas.json")) as f:
            areas = v.parse_areas(f.read())
        with open(os.path.join(rdir, "receipt.json"), "w") as f:
            json.dump({"schema": "verification-receipt/1", "receipt_id": rid, "machine": v.machine_name(),
                       "head_sha": "1" * 40, "areas": ["invoices"]}, f)
        env = dict(self.env, VERIFICATION_RECEIPT_DIR=rdir, VERIFICATION_WORKTREE=self.wt)

        class Exit:
            def __init__(self, code):
                self.returncode = code

        def drive(argv):
            return Exit(n.main(argv[argv.index("--") + 1:], env))
        self.assertEqual(s.shoot(rid, "head", areas, run=drive, home=home), [])
        names = sorted(f for f in os.listdir(rdir) if f.endswith(".png"))
        self.assertEqual(names, sorted(r["name"] for r in s.required_shots(areas, ["invoices"]) if r["side"] == "head"))


if __name__ == "__main__":
    unittest.main()
