#!/usr/bin/env python3
"""What the two model judged push gates did on this Mac (claude-config#1075, #1077).

    python3 ~/.claude/hooks/lib/push-gate-report.py [--days N] [--ledger PATH]

Reads the ledger lib/push-changes.sh writes, one line per push a gate reached (default
~/.claude/state/push-gates/push-gates.tsv, or $PUSH_GATE_LEDGER_DIR/push-gates.tsv), and prints for
each gate how often it was reached, how often its judge was called, passed, blocked or could not
judge, how often it was overridden, and how many of those overrides let through a commit the same
gate had blocked: the nearest thing the record holds to a false positive rate, which is what decides
whether the simplify gate's cheap judge should move from haiku to sonnet. It then counts the pushes
on which BOTH judges were called and whether their calls overlapped in time, which is what decides
whether one combined call would save anything (#1077).

A rate over fewer than MIN_JUDGED judged pushes is printed as UNMEASURED with its count (L716).
The ledger is this Mac's alone and is never synced, so run it on each Mac.
"""
import argparse
import os
import socket
import statistics
import sys
import time

# The outcomes lib/push-changes.sh writes (PC_OUTCOMES there); a line with any other is named as
# unreadable rather than counted under a guess.
OUTCOMES = ["override", "nosource", "empty", "docsonly", "untested", "pass", "block", "cantjudge", "failopen"]
GATES = [("simplify", "simplify-before-push.sh"), ("tests", "require-tests-before-push.sh")]
MIN_JUDGED = 5
COLUMNS = 14


def ledger_default():
    base = os.environ.get("PUSH_GATE_LEDGER_DIR") or os.path.join(os.path.expanduser("~"), ".claude", "state", "push-gates")
    return os.path.join(base, "push-gates.tsv")


def num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def read(path, since):
    rows, bad = [], 0
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            c = line.split("\t")
            if len(c) != COLUMNS or c[3] not in OUTCOMES or num(c[0]) is None:
                bad += 1
                continue
            if num(c[0]) < since:
                continue
            rows.append({
                "finished": num(c[0]), "host": c[1], "gate": c[2], "outcome": c[3], "repo": c[4],
                "head": c[5], "call": c[6], "model": c[7], "wall": num(c[8]), "ms": num(c[9]),
                "cost": num(c[10]), "bytes": num(c[11]), "started": num(c[12]), "detail": c[13],
            })
    return rows, bad


def pct(part, whole):
    if whole < MIN_JUDGED:
        return "UNMEASURED, under %d" % MIN_JUDGED
    return "%d%%" % round(100.0 * part / whole)


def gate_report(gate, script, rows):
    out = []
    mine = [r for r in rows if r["gate"] == gate]
    count = {o: sum(1 for r in mine if r["outcome"] == o) for o in OUTCOMES}
    judged = [r for r in mine if r["model"]]
    models = sorted({r["model"] for r in judged})
    out.append("%s gate (%s), judge: %s" % (gate, script, ", ".join(models) if models else "never called"))
    if not mine:
        out.append("  reached no push in this window.")
        return out
    out.append("  reached %d pushes: judge called on %d, overridden %d, no source %d, nothing to judge %d%s" % (
        len(mine), len(judged), count["override"], count["nosource"], count["empty"],
        (", comments only %d, refused with no test at all %d" % (count["docsonly"], count["untested"])) if gate == "tests" else ""))
    decided = count["pass"] + count["block"] + count["cantjudge"]
    blocks = count["block"] + count["cantjudge"]
    failed = [r for r in judged if r["outcome"] == "failopen"]
    out.append("  of the %d judged: passed %d, blocked %d (%s of those it decided), judge failed %d" % (
        len(judged), count["pass"], blocks, pct(blocks, decided), len(failed)))
    # An override of a commit this same gate blocked is a person saying the block was wrong (or not
    # worth fixing). It is evidence of a false positive, not proof, and is labelled as such.
    blocked = {(r["repo"], r["head"]) for r in mine if r["outcome"] in ("block", "cantjudge") and r["head"]}
    overridden = {(r["repo"], r["head"]) for r in mine if r["outcome"] == "override" and r["head"]}
    both = blocked & overridden
    out.append("  overridden after a block of the same commit: %d of %d blocked commits (%s), the nearest this record comes to a false positive rate" % (
        len(both), len(blocked), pct(len(both), len(blocked))))
    walls = sorted(r["wall"] for r in judged if r["wall"] is not None)
    if walls:
        out.append("  judge wall time: median %ss, slowest %ss, over %d calls" % (
            "%g" % statistics.median(walls), "%g" % walls[-1], len(walls)))
    costs = [r["cost"] for r in judged if r["cost"] is not None]
    if costs:
        out.append("  judge cost: $%.2f in all, $%.4f a call, from the %d calls that reported one" % (
            sum(costs), sum(costs) / len(costs), len(costs)))
    reasons = {}
    for r in mine:
        if r["outcome"] == "failopen":
            reasons[r["detail"] or "(no reason recorded)"] = reasons.get(r["detail"] or "(no reason recorded)", 0) + 1
    for why, n in sorted(reasons.items(), key=lambda kv: -kv[1]):
        out.append("  could not decide %d times: %s" % (n, why))
    return out


def both_report(rows):
    # The two gates' lines for one push share the tool call id Claude Code gives every hook on it.
    calls = {}
    for r in rows:
        if r["model"] and r["call"]:
            calls.setdefault(r["call"], {})[r["gate"]] = r
    either = len(calls)
    pairs = [g for g in calls.values() if "simplify" in g and "tests" in g]
    overlap = 0
    for g in pairs:
        a, b = g["simplify"], g["tests"]
        if None not in (a["started"], a["finished"], b["started"], b["finished"]) and \
                a["started"] <= b["finished"] and b["started"] <= a["finished"]:
            overlap += 1
    no_id = sum(1 for r in rows if r["model"] and not r["call"])
    out = ["both judges on one push: %d of the %d pushes either judge was called on (%s); their calls overlapped in time on %d of those %d" % (
        len(pairs), either, pct(len(pairs), either), overlap, len(pairs))]
    if no_id:
        out.append("  %d judged lines carry no tool call id (a hook run by hand, not by Claude Code) and are left out of that count" % no_id)
    return out


def main(argv):
    ap = argparse.ArgumentParser(description="What the model judged push gates did on this Mac.")
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--ledger", default=ledger_default())
    ap.add_argument("--now", type=float, default=None, help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    now = a.now if a.now is not None else time.time()
    host = socket.gethostname().split(".")[0]
    if not os.path.exists(a.ledger):
        print("No push gate record on %s yet: %s does not exist. The gates write it from the first push they reach after this change is installed." % (host, a.ledger))
        return 0
    try:
        rows, bad = read(a.ledger, now - a.days * 86400)
    except OSError as e:
        print("push-gate-report: could not read %s (%s)." % (a.ledger, e), file=sys.stderr)
        return 1
    print("Push gate record on %s, the last %d days (%s)" % (host, a.days, a.ledger))
    if bad:
        print("  %d lines could not be read and are not counted." % bad)
    for gate, script in GATES:
        print()
        print("\n".join(gate_report(gate, script, rows)))
    print()
    print("\n".join(both_report(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
