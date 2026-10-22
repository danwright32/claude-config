#!/usr/bin/env python3
"""How often check-wrapped-commands.sh refused a command on this Mac, and on what (claude-config#1492).

    python3 ~/.claude/hooks/lib/wrapped-refusal-report.py [--days N] [--ledger PATH]

Reads the record the gate keeps, one line per refusal (default
~/.claude/state/wrapped-commands/refusals.tsv, or $WRAPPED_REFUSAL_LEDGER_DIR/refusals.tsv), and
prints, for the last N days (7 by default), how many refusals there were, how many of them were
overridden with SKIP_WRAPPED_CHECK=1, and the count for each shape, a wrapper and a reason category,
commonest first. That is what decides which shapes the refusal can be narrowed for: a common shape
that is overridden every time is the candidate, one hiding a push, merge or issue command never is.

The record holds no command text, so a shape is all it can say; and it is this Mac's alone, never
synced, so run it on each Mac.
"""
import argparse
import datetime
import os
import socket
import sys
import time

COLUMNS = 5
OUTCOMES = ("refused", "overridden")


def ledger_default():
    base = os.environ.get("WRAPPED_REFUSAL_LEDGER_DIR") or os.path.join(
        os.path.expanduser("~"), ".claude", "state", "wrapped-commands")
    return os.path.join(base, "refusals.tsv")


def day(ts):
    """A date in US Eastern time, which is how Dan reads every time; local time where the zone
    database is missing, and said so."""
    try:
        from zoneinfo import ZoneInfo
        return datetime.datetime.fromtimestamp(ts, ZoneInfo("America/New_York")).strftime("%Y-%m-%d ET")
    except Exception:
        return datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d local time")


def read(path):
    """Every readable line as (time, wrapper, reason, outcome), and how many could not be read. A line
    that does not parse is counted, never skipped into silence (L11)."""
    rows, bad = [], 0
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            c = line.split("\t")
            if len(c) != COLUMNS or c[4] not in OUTCOMES or not c[0].isdigit():
                bad += 1
                continue
            rows.append((int(c[0]), c[2], c[3], c[4]))
    return rows, bad


def main(argv):
    ap = argparse.ArgumentParser(description="How often the wrapped command gate refused, on this Mac.")
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--ledger", default=ledger_default())
    ap.add_argument("--now", type=float, default=None, help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    now = a.now if a.now is not None else time.time()
    host = socket.gethostname().split(".")[0]
    if not os.path.exists(a.ledger):
        print("No wrapped command refusal recorded on %s yet: %s does not exist. The gate writes it from "
              "the first refusal it makes after the change that records them is installed." % (host, a.ledger))
        return 0
    try:
        rows, bad = read(a.ledger)
    except OSError as e:
        print("wrapped-refusal-report: could not read %s (%s)." % (a.ledger, e), file=sys.stderr)
        return 1
    since = now - a.days * 86400
    print("Wrapped command refusals on %s, the last %d days (%s)" % (host, a.days, a.ledger))
    if rows:
        print("  the record runs from %s" % day(min(r[0] for r in rows)))
    if bad:
        print("  %d lines could not be read and are not counted." % bad)
    window = [r for r in rows if r[0] >= since]
    if not window:
        print("  No refusal in the last %d days." % a.days)
        return 0
    refused = sum(1 for r in window if r[3] == "refused")
    print("  %d refusals: %d refused, %d overridden" % (len(window), refused, len(window) - refused))
    shapes = {}
    for _, wrapper, reason, outcome in window:
        s = shapes.setdefault((wrapper, reason), {"refused": 0, "overridden": 0})
        s[outcome] += 1
    print("  by shape, commonest first:")
    for (wrapper, reason), s in sorted(shapes.items(), key=lambda kv: (-(kv[1]["refused"] + kv[1]["overridden"]), kv[0])):
        print("    %d  %s, %s: refused %d, overridden %d" % (
            s["refused"] + s["overridden"], wrapper, reason, s["refused"], s["overridden"]))
    if any(r[2] == "other" for r in window):
        print("  A reason of \"other\" is one the gate had no category for: give it one in check-wrapped-commands.sh.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
