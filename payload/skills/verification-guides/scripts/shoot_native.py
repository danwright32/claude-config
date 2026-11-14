#!/usr/bin/env python3
"""shoot_native.py: a drive helper that photographs one screen of a native app (claude-config#2696).

    python3 shoot_native.py screenshot-native <test> <frame> <width> <light|dark> <file.png> <min rows>

The contract screenshots.py shoot calls a project's drive helper with for a NATIVE screen, through
run_session.py drive, so the call is logged and runs under the run's egress sandbox like every
other. It is shoot_web.mjs's counterpart: a web screen is a route opened in a headless browser, a
native screen is an offscreen test in the project's own test build, and the frame that test draws.
A project whose drive helper also drives its checks dispatches `screenshot-native` here and handles
the rest itself; any other first argument exits 2.

It runs the run's `commands.native_shot` (from areas.json in VERIFICATION_RECEIPT_DIR, the copy the
run uses for every other command) with /bin/sh in VERIFICATION_WORKTREE, handing the test what to
draw in the environment, each name both bare (swift test passes it through) and with the
TEST_RUNNER_ prefix (xcodebuild passes a test only those, and strips the prefix):

  VERIFICATION_SHOT_TEST       the screen's test, for the command's own filter (-only-testing:...)
  VERIFICATION_SHOT_FRAME      the frame to draw; a test that does not know it must FAIL
  VERIFICATION_SHOT_WIDTH      points wide, and VERIFICATION_SHOT_HEIGHT points high (HEIGHT,
  VERIFICATION_SHOT_HEIGHT     the web shot's window height); a frame may draw taller to show its
                               whole population, as the web shot captures the full page
  VERIFICATION_SHOT_THEME      light or dark, set on the WINDOW's appearance, not only SwiftUI's
  VERIFICATION_SHOT_FILE       where to write the PNG, inside the receipt folder
  VERIFICATION_SHOT_ROWS_FILE  where to write how many rows the frame drew, as a whole number
  VERIFICATION_SHOT_MIN_ROWS   the count the screen is shot at (L606), 0 when none is asked

The picture is kept only when the test exited 0, wrote a PNG whose width is the asked width at a
backing scale of 1, 2 or 3, and, when a minimum is asked, reported at least that many rows.
Anything else removes the file, so screenshots.py sees the shot missing; a picture left by an
earlier shot is removed before the test starts, so it can never stand for this one. A test filter
that matches nothing runs zero tests and passes (L98), which is why the picture, not the exit
code, is the proof. The test's own output is kept as native-shot/<file>.log beside the receipt.

The test must render offscreen and never order a window front or activate an app. Ovation's
OffscreenShot.swift is the camera that does that: a window ordered BACK outside every display, its
appearance set to the theme, not released on close.

Env: SHOOT_NATIVE_TIMEOUT_S, how long one test run may take (default 1800: the first shot of a
run builds the test target in a fresh worktree), after which its process group is stopped.
Exit codes: 0 saved, 1 not shot, 2 usage.
"""

import json
import math
import os
import re
import signal
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verification as v  # noqa: E402

VERB = "screenshot-native"
HEIGHT = 900  # the window height shoot_web.mjs shoots a web screen at
SCALES = (1, 2, 3)
TIMEOUT_S = 1800
STOP_GRACE_S = 5  # how long each signal is given to empty the group
POLL_S = 0.05
LOG_TAIL = 15
FILE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.png$")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
# ASCII digits only: str.isdigit() is also true for a superscript, which int() then refuses.
WHOLE_RE = re.compile(r"[0-9]{1,9}")


class Usage(Exception):
    pass


def parse_shot(argv, env):
    """The one shot screenshots.py asked for, or Usage naming what is wrong."""
    if not argv or argv[0] != VERB:
        raise Usage("shoot_native.py only takes native screenshots; %s is for the project's own drive helper"
                    % (argv[0] if argv else "nothing"))
    if len(argv) != 7:
        raise Usage("usage: shoot_native.py %s <test> <frame> <width> <light|dark> <file.png> <min rows>" % VERB)
    _, test, frame, width, theme, name, min_rows = argv
    if not v.NATIVE_TEST_RE.fullmatch(test):
        raise Usage("the test %r is not a test identifier (Target, Target/Suite or Target/Suite/function())" % test)
    if not v.AREA_NAME.fullmatch(frame) or "__" in frame:
        raise Usage("the frame %r is not a frame name (lower case letters, digits and single hyphens)" % frame)
    if not WHOLE_RE.fullmatch(width) or int(width) < 320:
        raise Usage("the width %r is not a whole number of points, 320 or more" % width)
    if theme not in ("light", "dark"):
        raise Usage("the theme is light or dark, not %r" % theme)
    if not FILE_RE.fullmatch(name):
        raise Usage("%r is not a picture name this run can keep" % name)
    if not WHOLE_RE.fullmatch(min_rows):
        raise Usage("the minimum row count %r is not a whole number" % min_rows)
    rdir, wt = env.get("VERIFICATION_RECEIPT_DIR"), env.get("VERIFICATION_WORKTREE")
    if not rdir or not wt:
        raise Usage("VERIFICATION_RECEIPT_DIR and VERIFICATION_WORKTREE are unset: run this through run_session.py drive")
    return {"test": test, "frame": frame, "width": int(width), "theme": theme, "min_rows": int(min_rows),
            "name": name, "rdir": rdir, "worktree": wt, "out": os.path.join(rdir, name)}


def shot_command(rdir):
    """commands.native_shot from the areas.json this run uses, or Usage."""
    try:
        with open(os.path.join(rdir, "areas.json"), errors="strict") as f:
            doc = v.parse_areas(f.read())
    except (OSError, UnicodeDecodeError) as e:
        raise Usage("the run's areas.json in %s could not be read: %s" % (rdir, e))
    except v.VerificationError as e:
        raise Usage("the run's areas.json is not valid: %s" % "; ".join(m for _, m in e.problems))
    cmd = doc["commands"].get("native_shot")
    if not cmd:
        raise Usage("the run's areas.json has no commands.native_shot, the command that runs the offscreen test")
    return cmd


def timeout_s(env):
    raw = env.get("SHOOT_NATIVE_TIMEOUT_S", "")
    if raw == "":
        return TIMEOUT_S
    try:
        value = float(raw)
    except ValueError:
        value = -1
    if not math.isfinite(value) or value <= 0:
        raise Usage("SHOOT_NATIVE_TIMEOUT_S %r is not a number of seconds above 0" % raw)
    return value


def png_size(path):
    """(width, height) in pixels from a PNG's header, or None when the file is not a PNG."""
    try:
        with open(path, "rb") as f:
            head = f.read(24)
    except OSError:
        return None
    if len(head) < 24 or head[:8] != PNG_SIGNATURE or head[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", head[16:24])


def _remove(path):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def _tail(path):
    try:
        with open(path, errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return "(no output was kept)"
    return "\n".join(lines[-LOG_TAIL:]) or "(it printed nothing)"


def _group_alive(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _stop_group(proc):
    """Stop the test's whole process group, SIGTERM then SIGKILL, judged by the GROUP emptying.

    The shell wrapper exits on SIGTERM at once, so waiting on it alone would skip the SIGKILL a
    child ignoring SIGTERM needs (L321). The wrapper is reaped on every poll, so its own exit never
    keeps the group looking alive.
    """
    pgid = proc.pid
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pgid, sig)
        except ProcessLookupError:
            break
        deadline = time.monotonic() + STOP_GRACE_S
        while True:
            proc.poll()
            if not _group_alive(pgid):
                proc.wait()
                return
            if time.monotonic() >= deadline:
                break
            time.sleep(POLL_S)
    proc.poll()


def shoot(o, cmd, deadline_s, env):
    """Run the test for one shot. Returns None when the picture was kept, else why it was not."""
    folder = os.path.join(o["rdir"], "native-shot")
    os.makedirs(folder, exist_ok=True)
    rows_file = os.path.join(folder, o["name"] + ".rows")
    log = os.path.join(folder, o["name"] + ".log")
    for stale in (o["out"], rows_file):
        _remove(stale)
    shot = {"TEST": o["test"], "FRAME": o["frame"], "WIDTH": str(o["width"]), "HEIGHT": str(HEIGHT),
            "THEME": o["theme"], "FILE": o["out"], "ROWS_FILE": rows_file, "MIN_ROWS": str(o["min_rows"])}
    child_env = dict(env)
    for key, value in shot.items():
        child_env["VERIFICATION_SHOT_" + key] = value
        child_env["TEST_RUNNER_VERIFICATION_SHOT_" + key] = value
    with open(log, "wb") as out:
        proc = subprocess.Popen(["/bin/sh", "-c", cmd], cwd=o["worktree"], env=child_env, stdin=subprocess.DEVNULL,
                                stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            rc = proc.wait(timeout=deadline_s)
        except subprocess.TimeoutExpired:
            _stop_group(proc)
            _remove(o["out"])
            return "the offscreen test did not finish within %g seconds and was stopped. Its last output:\n%s" % (
                deadline_s, _tail(log))
    why = _judge(o, rc, rows_file, log)
    if why:
        _remove(o["out"])
    return why


def _judge(o, rc, rows_file, log):
    if rc != 0:
        return "the offscreen test exited %d. Its last output:\n%s" % (rc, _tail(log))
    if not os.path.exists(o["out"]):
        return ("the offscreen test exited 0 and wrote no picture at %s: a filter matching no test runs zero"
                " tests and passes, so check that %s exists and draws frame %s. Its last output:\n%s"
                % (o["out"], o["test"], o["frame"], _tail(log)))
    size = png_size(o["out"])
    if size is None:
        return "the offscreen test wrote %s, which is not a PNG" % o["name"]
    if size[0] not in [o["width"] * k for k in SCALES]:
        return ("the picture is %d pixels wide, which is not %d points at a scale of %s: the frame was not drawn"
                " at the width asked" % (size[0], o["width"], ", ".join(str(k) for k in SCALES)))
    if o["min_rows"]:
        try:
            with open(rows_file, errors="strict") as f:
                text = f.read().strip()
        except (OSError, UnicodeDecodeError):
            return ("frame %s reported no row count, and the screen is shot at %d rows or more: the test must"
                    " write the rows it drew to VERIFICATION_SHOT_ROWS_FILE" % (o["frame"], o["min_rows"]))
        if not WHOLE_RE.fullmatch(text):
            return "frame %s reported %r as its row count, which is not a whole number" % (o["frame"], text[:40])
        if int(text) < o["min_rows"]:
            return "frame %s drew %s rows, and the screen is shot at %d or more (L606)" % (
                o["frame"], text, o["min_rows"])
    return None


def main(argv, env=None):
    env = dict(os.environ if env is None else env)
    try:
        o = parse_shot(argv, env)
        cmd = shot_command(o["rdir"])
        deadline = timeout_s(env)
    except Usage as e:
        print("shoot_native: %s" % e, file=sys.stderr)
        return 2
    why = shoot(o, cmd, deadline, env)
    if why:
        print("shoot_native: not shot: %s" % why, file=sys.stderr)
        return 1
    print("shoot_native: saved %s" % o["out"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
