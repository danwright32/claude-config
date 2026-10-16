#!/usr/bin/env python3
"""stale-worktree-run.py: one background run of check-stale-worktrees.sh --remove, started by
stale-worktree-nudge.sh and never waited for (claude-config#1247).

WHY IT IS NOT RUN INSIDE THE PROMPT. The nudge has five seconds, and with 46 worktrees the check
took 3.9 to 4.8 seconds before removing anything (measured 2026-10-16), so Claude Code killed it at
five and threw its answer away, every session, and nothing was removed for two days. Inspecting a
worktree costs what it costs; the prompt is simply the wrong place to pay it.

WHAT KEEPS A REMOVAL WHOLE (L617). A `git worktree remove` killed part way leaves a part deleted
folder that git still lists, which every later run then keeps as "uncommitted changes". So this
run is under no timeout, and it starts a session of its own (setsid), so nothing aimed at the
session the prompt came from reaches it: not the terminal closing, not Ctrl+C, not a kill of the
hook's process group. SIGHUP and SIGINT are ignored as well. What it cannot survive (a shutdown, a
SIGKILL) is caught on the next run by the check's own progress marker.

ONE RUN PER REPOSITORY AT A TIME. Two sessions starting at once must not both remove, so the run
takes an flock on a lock file kept beside its records. An flock is released by the kernel when its
holder dies, so a crashed run never leaves a lock somebody has to clear by hand (L409). The lock is
passed to the check itself too, so it is held for as long as either of them lives. A run that
finds the lock taken does nothing, and says so only when the holder has been at it longer than
STALE_WT_STUCK_MINUTES, because a run that never ends blocks every later one in silence.

WHAT IT WRITES, all beside the lock, in the nudge's state directory, as
claude-stale-worktrees-repo-<key>.*:
  .last              the run in flight or the last one: started, pid, and once it ends, finished,
                     verdict and the check's stderr. Read by the next run, which is how a run that
                     died part way is noticed (a start with no finish, and the lock free).
  .result.<t>.<pid>  something the person should be told, written whole (a temporary name, then a
                     rename) so the nudge never reads half of one. The nudge says each one once.
Exit 2 from the check (gh unreadable, not a repository) is recorded and not said: nobody can act on
it from a prompt (L36, L112). Any exit the check never returns on purpose is said, because that is
the check itself broken.

Environment: STALE_WT_STUCK_MINUTES (default 30), STALE_WT_NOW (the clock, for a fixture: L524).
"""

import argparse
import fcntl
import json
import os
import signal
import subprocess
import sys
import time


def now():
    forced = os.environ.get("STALE_WT_NOW", "")
    return int(forced) if forced.isdigit() else int(time.time())


def eastern(ts):
    # Dan reads times in US Eastern (his words, 2026-10-03), whatever zone the machine is set to.
    try:
        from datetime import datetime
        from zoneinfo import ZoneInfo
        return datetime.fromtimestamp(ts, ZoneInfo("America/New_York")).strftime("%Y-%m-%d %H:%M ET")
    except Exception:
        return time.strftime("%Y-%m-%d %H:%M %Z", time.localtime(ts))


def write_whole(path, text):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def read_record(path):
    try:
        with open(path) as f:
            record = json.load(f)
        return record if isinstance(record, dict) else None
    except (OSError, ValueError):
        return None


def tell(base, repo, when, lines):
    body = "Agent worktree cleanup in %s, run in the background at %s:\n%s\n" % (
        repo, eastern(when), "\n".join(lines))
    write_whole("%s.result.%010d.%d" % (base, when, os.getpid()), body)


def parse():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--state-dir", required=True)
    ap.add_argument("--key", required=True)
    return ap.parse_args()


def run(args):
    try:
        os.setsid()
    except OSError:
        pass  # already a session leader, which is all this asks for
    for sig in (signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, signal.SIG_IGN)

    os.makedirs(args.state_dir, exist_ok=True)
    base = os.path.join(args.state_dir, "claude-stale-worktrees-repo-%s" % args.key)
    last_path = base + ".last"
    lock_fd = os.open(base + ".lock", os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        held = read_record(last_path) or {}
        started = held.get("started")
        limit = int(os.environ.get("STALE_WT_STUCK_MINUTES", "30") or 30)
        if isinstance(started, int) and "finished" not in held and now() - started >= limit * 60:
            tell(base, args.repo, now(), [
                "  a cleanup run started at %s (process %s) is still running %d minutes later, so no "
                "later run can start until it ends. Its record is %s." % (
                    eastern(started), held.get("pid", "unknown"), (now() - started) // 60, last_path)])
        return 0

    notes = []
    previous = read_record(last_path)
    if previous and isinstance(previous.get("started"), int) and "finished" not in previous:
        notes.append(
            "  the cleanup run before this one, started at %s (process %s), never recorded finishing, "
            "so it was stopped part way." % (eastern(previous["started"]), previous.get("pid", "unknown")))

    started = now()
    record = {"repo": args.repo, "pid": os.getpid(), "started": started}
    write_whole(last_path, json.dumps(record, indent=1) + "\n")

    try:
        proc = subprocess.run(["bash", args.check, "--remove", args.repo], cwd=args.repo,
                              stdin=subprocess.DEVNULL, capture_output=True, pass_fds=(lock_fd,))
        verdict = proc.returncode
        out = proc.stdout.decode("utf-8", "replace")
        err = proc.stderr.decode("utf-8", "replace")
    except OSError as e:
        verdict, out, err = None, "", "could not start the check: %s" % e

    record.update(finished=now(), verdict=verdict, stderr=err[-4000:])
    write_whole(last_path, json.dumps(record, indent=1) + "\n")

    lines = list(notes)
    if verdict == 1:
        lines.append(out.rstrip("\n"))
    elif verdict not in (0, 2):
        tail = " ".join(err.strip().splitlines()[-3:]) or "nothing"
        lines.append("  the cleanup check ended with exit %s, which it never returns on purpose, so it "
                     "broke part way. It said on stderr: %s" % (verdict, tail))
    if lines:
        tell(base, args.repo, started, lines)
    return 0


if __name__ == "__main__":
    ARGS = parse()
    try:
        sys.exit(run(ARGS))
    except Exception as e:
        # Nobody reads this process's stderr, so a run that broke says so where the nudge looks.
        try:
            tell(os.path.join(ARGS.state_dir, "claude-stale-worktrees-repo-%s" % ARGS.key), ARGS.repo,
                 now(), ["  the background cleanup run broke before it finished: %r" % e])
        except Exception:
            pass
        sys.exit(1)
