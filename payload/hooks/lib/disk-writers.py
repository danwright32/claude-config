#!/usr/bin/env python3
"""Which programs are writing to the disk, by each program's own count of bytes written (claude-config#3589).

    python3 ~/.claude/hooks/lib/disk-writers.py [--seconds N] [--top N]

The disk-full skill ranks folders, but a folder ranking cannot name a WRITER. On 2026-11-24 free
space fell 21 GB in 34 minutes, in bursts with flat stretches between, every folder step came back
clean, and the writer of about half of it was never named. On 2026-11-25 free space fell 88 GB in 23
minutes and no folder step explained it either: the writer was a photo editor's export, holding its
temp files open in a per user temp folder that no `du` of the home folder reaches.

macOS keeps, for every running program, a count of the bytes it has written to disk since it started
(proc_pid_rusage, the field ri_diskio_byteswritten). This reads that count twice, N seconds apart
(10 by default), and prints:
  - free space on the data volume at both readings, so the window's writes can be set against what
    the disk actually lost;
  - how many programs it read, and how many it could NOT read, by who they run as. The count is
    readable only for programs running as the same user, so system services (root) and other system
    users are never read without a password. Those are reported as unread, never as zero (L90);
  - the programs that wrote the most in the window, which answers while something is writing;
  - the programs that have written the most since they started, with when they started, which still
    answers when the window lands in a flat stretch between bursts.

It is read only: it writes, moves and deletes nothing, and reads nothing but the process table and
the volume's free space.

Bytes written is not space held. A program that writes a temp file and deletes it, or rewrites the
same file, counts every write; a clone or a sparse file can hold less than was written. So a large
figure names a CANDIDATE, and only free space falling by about as much over the same window makes it
the cause.

Exit: 0 read, 2 could not read the process table or no program at all (never a report of nothing).
Env: DISK_WRITERS_SAMPLES  a JSON file of readings to report on instead of this Mac's, for the tests
     DISK_WRITERS_PATH     the volume whose free space is read (default /System/Volumes/Data)
"""

import argparse
import ctypes
import json
import os
import sys
import time

RUSAGE_INFO_V2 = 2
PROC_PIDTBSDINFO = 3
BSDINFO_SIZE = 136
PROC_PIDT_SHORTBSDINFO = 13
SHORTINFO_SIZE = 64
# rusage_info_v2: a 16 byte uuid, then uint64 fields; ri_proc_start_abstime is the 9th of them and
# ri_diskio_byteswritten the 18th (sys/resource.h).
RU_START = 2 + 8
RU_WRITTEN = 2 + 17


def volume_free(path):
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize


class Proc:
    """This Mac's process table, read through libproc."""

    def __init__(self):
        self.lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)

    def pids(self):
        n = self.lib.proc_listallpids(None, 0)
        if n <= 0:
            raise OSError("proc_listallpids returned %d" % n)
        buf = (ctypes.c_int * (n + 256))()
        n = self.lib.proc_listallpids(buf, ctypes.sizeof(buf))
        if n <= 0:
            raise OSError("proc_listallpids returned %d" % n)
        return [p for p in buf[:n] if p > 0]

    def written(self, pid):
        """(bytes written, start) or None when this user may not read it."""
        ri = (ctypes.c_uint64 * 64)()
        if self.lib.proc_pid_rusage(pid, RUSAGE_INFO_V2, ctypes.byref(ri)) != 0:
            return None
        return ri[RU_WRITTEN], ri[RU_START]

    def owner(self, pid):
        """The uid a program runs as, or None once it has ended. The short record is readable for
        every program, root's included, where the full one is not (measured 2026-11-25: 885 of 886)."""
        b = ctypes.create_string_buffer(SHORTINFO_SIZE)
        if self.lib.proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, b, SHORTINFO_SIZE) != SHORTINFO_SIZE:
            return None
        return int.from_bytes(b.raw[36:40], "little")

    def info(self, pid):
        """(name, start epoch seconds) of a program this user may read, None for what could not be."""
        name = ctypes.create_string_buffer(256)
        got = self.lib.proc_name(pid, name, ctypes.sizeof(name))
        name = name.value.decode("utf-8", "replace") if got > 0 else ""
        b = ctypes.create_string_buffer(BSDINFO_SIZE)
        if self.lib.proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, b, BSDINFO_SIZE) != BSDINFO_SIZE:
            return name or None, None
        if not name:
            name = b.raw[48:80].split(b"\0", 1)[0].decode("utf-8", "replace")
        return name or None, int.from_bytes(b.raw[120:128], "little")


def sample_this_mac(seconds, path):
    proc = Proc()
    me = os.getuid()
    pids = proc.pids()
    free0 = volume_free(path)
    t0 = time.monotonic()
    first = {}
    for pid in pids:
        w = proc.written(pid)
        if w is not None:
            first[pid] = w
    time.sleep(seconds)
    second = {}
    for pid in first:
        w = proc.written(pid)
        if w is not None and w[1] == first[pid][1]:  # the same program, not a reused pid
            second[pid] = w
    elapsed = time.monotonic() - t0
    free1 = volume_free(path)
    rows = []
    for pid, (w1, _) in second.items():
        name, start = proc.info(pid)
        rows.append({"pid": pid, "name": name or "(no name)", "start": start,
                     "lifetime": w1, "window": w1 - first[pid][0]})
    # Every program not reported is counted under the reason it is missing, never dropped (L540).
    unread = {"root": 0, "other": 0, "gone": len(first) - len(second)}
    for pid in pids:
        if pid in first:
            continue
        uid = proc.owner(pid)
        if uid is None:
            unread["gone"] += 1
        elif uid == 0:
            unread["root"] += 1
        elif uid != me:
            unread["other"] += 1
        else:
            unread["refused"] = unread.get("refused", 0) + 1
    return {"seconds": elapsed, "free": [free0, free1], "total": len(pids),
            "read": len(rows), "unread": unread, "rows": rows}


def _number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _count(v):
    return isinstance(v, int) and not isinstance(v, bool) and v >= 0


def shape_fault(s):
    """What makes a set of readings unusable, or None. Readings handed in through
    DISK_WRITERS_SAMPLES are checked whole before any line is printed, so a file missing a field ends
    in one line naming it, never a traceback and never a report built from the half that was there."""
    if not isinstance(s, dict):
        return "the top level is a %s, not an object" % type(s).__name__
    for key in ("seconds", "free", "total", "read", "unread", "rows"):
        if key not in s:
            return 'no "%s"' % key
    if not _number(s["seconds"]) or s["seconds"] < 0:
        return '"seconds" is not a number of seconds'
    if not (isinstance(s["free"], list) and len(s["free"]) == 2 and all(_number(v) for v in s["free"])):
        return '"free" is not two numbers of bytes'
    for key in ("total", "read"):
        if not _count(s[key]):
            return '"%s" is not a count' % key
    u = s["unread"]
    if not isinstance(u, dict):
        return '"unread" is not an object'
    for key in ("root", "other", "gone"):
        if key not in u:
            return 'no "%s" in "unread"' % key
    for key in ("root", "other", "gone", "refused"):
        if key in u and not _count(u[key]):
            return '"%s" in "unread" is not a count' % key
    if not isinstance(s["rows"], list):
        return '"rows" is not a list'
    for i, r in enumerate(s["rows"]):
        if not isinstance(r, dict):
            return "row %d is not an object" % (i + 1)
        for key in ("pid", "name", "lifetime", "window"):
            if key not in r:
                return 'no "%s" in row %d' % (key, i + 1)
        if not _count(r["pid"]):
            return '"pid" in row %d is not a process id' % (i + 1)
        if not isinstance(r["name"], str):
            return '"name" in row %d is not text' % (i + 1)
        for key in ("lifetime", "window"):
            if not _number(r[key]):
                return '"%s" in row %d is not a number of bytes' % (key, i + 1)
        if r.get("start") is not None and not _number(r["start"]):
            return '"start" in row %d is not a time' % (i + 1)
    return None


def gb(n):
    return "%.1f GB" % (n / 1e9)


def mb(n):
    return "%.0f MB" % (n / 1e6)


def report(s, top):
    out = []
    secs = round(s["seconds"])
    secs = "%d second%s" % (secs, "" if secs == 1 else "s")
    path = os.environ.get("DISK_WRITERS_PATH", "/System/Volumes/Data")
    free0, free1 = s["free"]
    fell = free0 - free1
    # Megabytes for the window: whole gigabytes cannot tell a fall of 1.5 GB from none.
    change = ("fell %s" % mb(fell)) if fell >= 5e5 else ("rose %s" % mb(-fell)) if fell <= -5e5 else "changed by under 1 MB"
    out.append("Free space on %s: %s, then %s %s later (%s)."
               % (path, gb(free0), gb(free1), secs, change))
    u = s["unread"]
    n_unread = u["root"] + u["other"]
    out.append("Read %d of %d programs. %d could not be read without a password (%d run as root, %d as other system users): their writes are unknown, not zero."
               % (s["read"], s["total"], n_unread, u["root"], u["other"]))
    if u.get("refused"):
        out.append("%d running as this user refused the read too: their writes are unknown, not zero." % u["refused"])
    if u["gone"]:
        out.append("%d ended while being read and are left out." % u["gone"])
    rows = s["rows"]
    in_window = sum(r["window"] for r in rows)
    out.append("")
    out.append("Written in those %s by the programs read, %s in all:" % (secs, mb(in_window)))
    writing = sorted((r for r in rows if r["window"] > 0), key=lambda r: -r["window"])[:top]
    if not writing:
        out.append("  none of them wrote anything in the window")
    for r in writing:
        out.append("  %10.1f MB  %8.1f MB/s  pid %-6d %s"
                   % (r["window"] / 1e6, r["window"] / 1e6 / max(s["seconds"], 0.001), r["pid"], r["name"]))
    out.append("")
    out.append("Written since each started, highest first:")
    for r in sorted(rows, key=lambda r: -r["lifetime"])[:top]:
        since = time.strftime("%Y-%m-%d %H:%M", time.localtime(r["start"])) if r.get("start") else "start unknown"
        out.append("  %10s  since %s  pid %-6d %s" % (gb(r["lifetime"]), since, r["pid"], r["name"]))
    return "\n".join(out)


def main():
    # A name holding a lone surrogate, which json.load makes of an escape such as \ud800 in the
    # readings, cannot be written to a UTF-8 stdout; it is shown replaced instead of ending the report.
    sys.stdout.reconfigure(errors="replace")
    ap = argparse.ArgumentParser(description="Which programs are writing to the disk.")
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--top", type=int, default=10)
    a = ap.parse_args()
    if not 0 < a.seconds <= 120:
        print("disk-writers: --seconds must be above 0 and at most 120", file=sys.stderr)
        return 2
    if a.top < 1:
        print("disk-writers: --top must be 1 or more", file=sys.stderr)
        return 2
    fixture = os.environ.get("DISK_WRITERS_SAMPLES")
    path = os.environ.get("DISK_WRITERS_PATH", "/System/Volumes/Data")
    if fixture:
        # A byte that is not UTF-8, in a program's name, is shown replaced rather than costing the
        # whole report.
        try:
            with open(fixture, encoding="utf-8", errors="replace") as f:
                s = json.load(f)
        except (OSError, ValueError) as e:
            print("disk-writers: could not read the readings in DISK_WRITERS_SAMPLES (%s): %s" % (fixture, e), file=sys.stderr)
            return 2
        fault = shape_fault(s)
        if fault:
            print("disk-writers: the readings in DISK_WRITERS_SAMPLES (%s) are not in the shape this reads: %s"
                  % (fixture, fault), file=sys.stderr)
            return 2
    else:
        try:
            volume_free(path)
        except OSError as e:
            print("disk-writers: could not read free space on %s: %s" % (path, e), file=sys.stderr)
            return 2
        try:
            s = sample_this_mac(a.seconds, path)
        except (OSError, AttributeError) as e:
            print("disk-writers: could not read the process table: %s" % e, file=sys.stderr)
            return 2
    if not s.get("read"):
        print("disk-writers: no program could be read, so nothing here says who is writing.", file=sys.stderr)
        return 2
    print(report(s, a.top))
    return 0


if __name__ == "__main__":
    sys.exit(main())
