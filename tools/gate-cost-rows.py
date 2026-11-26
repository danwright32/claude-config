#!/usr/bin/env python3
"""One row per drafts gate cost case per run, from saved log text (claude-config#3170).

    python3 tools/gate-cost-rows.py rows <log file>...
    python3 tools/gate-cost-rows.py check <cost log>

Since 2026-11-21 (Dan's decision that day, "Measure more first") every run of
payload/hooks/test-slack-drafts-only-gate.sh prints, for each cost case, the gate's processor
seconds for each reading, the yardstick each reading was divided by, and every yardstick sample the
case took, so that whether the yardstick should be timed the way the gate is timed can be judged
from a few days of CI runs. Nothing is judged by those figures: each case is still judged by its
least reading against its limit, as before. The "yardstick per reading" column marks a median
yardstick "median" (#3406); a bare figure there is the least sample.

They are printed in three shapes, and rows reads all three:

- `cost measured (#2918): <case> <command>: <least> (<body>)`, one line per case, which the suite
  prints on every run but run-all-tests shows only from a failing suite or a kept flaky output.
- `drafts gate on <OS>, bash tests/test-claude-sync.sh from an empty cache: at <least> (<body>)
  (#3167)`, the suite-cold case, a note run-all-tests shows on a passing run too.
- `drafts gate costs on <OS>, ...: <case> <least> (<body>) | <case> <least> (<body>) (#3170)`, every
  other case in one note, shown on a passing run too. Before 2026-11-21 its entries were
  `<case> <least> (<readings>)` separated by "; ", which is read as well.

Each file is one run, named by its file name. A file holding cost lines gives its rows from them
alone, so a run printed in two shapes is not counted twice. A figure a line does not carry (an older
line) is "-". A file with no cost line is an error, never an empty table.

The last column, "cache never filled", is yes for a cached case (suite-warm, own-suite-warm) whose
record says the judgement that fills its cache ran out of the gate's seconds: the suite reports
that case as unmeasured there, never as a pass or a failure (Dan's decision of 2026-11-21, "Build
it"), and this column is how often that happened, counted from saved logs.

check reads a cost log the suite wrote (the lines without the "cost measured" prefix, or with it)
and fails unless every record's verdict figures follow from its printed ones: each reading is its
seconds over the yardstick it names, that yardstick is the least of the samples taken by then (5
before the first judgement and 2 after each, 2 more where the seconds ran out), or their median
where the record says "median of" (the cold case off macOS since 2026-11-26, #3406), and the judged
reading is the least reading. So a verdict taken from any figure printed beside it fails here, and
a record mixing the two, or naming one and dividing by the other, fails too. Which cases may name
the median is held by the drafts gate suite, from its cost_unit.

Reads only the files named; opens no connection.
"""
import os
import re
import statistics
import sys

NUM = r"[0-9][0-9.]*"
LIST = r"[0-9][0-9., ]*[0-9]"
COST_LINE = re.compile(r"^([a-z][a-z-]*) .*: (" + NUM + r") \((.*)\)$")
COLD_NOTE = re.compile(r"drafts gate on \S+, bash tests/test-claude-sync\.sh from an empty cache: at (" + NUM + r") \((.*)\) \(#3167\)$")
COSTS_NOTE = re.compile(r"drafts gate costs on \S+[^:]*: (.*) \(#3170\)$")
ENTRY = re.compile(r"^([a-z][a-z-]*) (" + NUM + r") \((.*)\)$")
MARK = "cost measured (#2918): "

COLUMNS = ("run", "case", "limit", "least", "readings in units", "readings in seconds", "yardstick used",
           "yardstick per reading", "yardstick samples", "yardstick least", "yardstick median",
           "yardstick greatest", "step clock", "cache never filled")


def nums(text):
    return [t.strip() for t in text.split(",") if t.strip()]


def body_fields(case, least, body):
    """The figures a record's parenthesised body holds, by the words that label each one."""
    rec = {"case": case, "least": least, "body": body}
    def one(pattern):
        m = re.search(pattern, body)
        return m.group(1) if m else None
    rec["spent"] = one(r"^(" + NUM + r") s of processor time")
    rec["unit"] = one(r"unit (" + NUM + r") s,")
    rec["ceiling"] = one(r"ceiling (" + NUM + r")")
    readings = one(r", samples (" + LIST + r"|[0-9][0-9.]*)")
    if readings is None and re.fullmatch(r"(" + LIST + r"|" + NUM + r")(, on the step clock)?", body):
        readings = body.split(", on the step clock")[0]  # the older note's entry: its readings alone
    rec["readings"] = nums(readings) if readings else None
    rec["step"] = "step clock" in body
    # A cached case whose cache the earlier judgement never filled, which the suite reports as
    # unmeasured (#3170): the words cost.py writes into such a record.
    rec["unfilled"] = "the cache was never filled" in body
    secs = one(r"; seconds per reading (" + LIST + r"|" + NUM + r")")
    rec["seconds"] = nums(secs) if secs else None
    # "<unit> from <n>": the least of the first n samples; "<unit> median of <n>": their median, the
    # cold case's unit off macOS since 2026-11-26 (#3406).
    per = one(r"; yardstick per reading ((?:" + NUM + r" (?:from|median of) [0-9]+(?:, )?)+)")
    rec["per"] = re.findall(r"(" + NUM + r") (from|median of) ([0-9]+)", per) if per else None
    m = re.search(r"; yardstick ([0-9]+) samples (" + LIST + r"|" + NUM + r")", body)
    rec["samples"] = (int(m.group(1)), nums(m.group(2))) if m else None
    m = re.search(r"; yardstick least (" + NUM + r"), median (" + NUM + r"), greatest (" + NUM + r")", body)
    rec["spread"] = m.groups() if m else None
    return rec


def records(text):
    """(from cost lines, from notes): the records of one run's text, in the order printed."""
    lines, notes = [], []
    for raw in text.splitlines():
        if MARK in raw:
            m = COST_LINE.match(raw.split(MARK, 1)[1].strip())
            if m:
                lines.append(body_fields(*m.groups()))
            continue
        m = COLD_NOTE.search(raw.rstrip())
        if m:
            notes.append(body_fields("suite-cold", m.group(1), m.group(2)))
            continue
        m = COSTS_NOTE.search(raw.rstrip())
        if m:
            entries = m.group(1)
            # Entries are separated by " | " since 2026-11-21, and a note of one case has none; only a
            # note without the new figures is the older kind, whose entries were separated by "; ".
            if " | " in entries or "; seconds per reading " in entries:
                parts = entries.split(" | ")
            else:
                parts = re.split(r"; (?=[a-z][a-z-]* [0-9])", entries)
            for part in parts:
                e = ENTRY.match(part.strip())
                if e:
                    notes.append(body_fields(*e.groups()))
    return lines, notes


def row(run, r):
    dash = lambda v: v if v else "-"
    per, samples, spread = r["per"], r["samples"], r["spread"]
    return "\t".join((
        run, r["case"], dash(r["ceiling"]), r["least"],
        ", ".join(r["readings"]) if r["readings"] else "-",
        ", ".join(r["seconds"]) if r["seconds"] else "-",
        dash(r["unit"]),
        ", ".join(u + (" median" if kind == "median of" else "") for u, kind, _ in per) if per else "-",
        str(samples[0]) if samples else "-",
        spread[0] if spread else "-", spread[1] if spread else "-", spread[2] if spread else "-",
        "yes" if r["step"] else "no", "yes" if r["unfilled"] else "no"))


def rows(paths):
    print("\t".join(COLUMNS))
    status = 0
    for path in paths:
        try:
            with open(path, errors="replace") as f:
                text = f.read()
        except OSError as e:
            print("%s could not be read: %s" % (path, e), file=sys.stderr)
            status = 1
            continue
        lines, notes = records(text)
        found = lines or notes
        if not found:
            print("%s holds no drafts gate cost line" % os.path.basename(path), file=sys.stderr)
            status = 1
        for r in found:
            print(row(os.path.basename(path), r))
    return status


def faults(r):
    """Why a record's verdict does not follow from its printed figures; empty when it does."""
    name = r["case"]
    missing = [w for w, k in (("seconds per reading", "seconds"), ("yardstick per reading", "per"),
                              ("yardstick samples", "samples"), ("yardstick spread", "spread"),
                              ("readings", "readings"), ("unit", "unit"), ("seconds", "spent"))
               if not r[k]]
    if missing:
        return ["%s: no %s" % (name, ", no ".join(missing))]
    out = []
    readings = [float(x) for x in r["readings"]]
    secs = [float(x) for x in r["seconds"]]
    per = [(float(u), int(n)) for u, _, n in r["per"]]
    kinds = {kind for _, kind, _ in r["per"]}
    count, ys = r["samples"]
    ys_f = [float(y) for y in ys]
    if not (len(readings) == len(secs) == len(per)):
        return ["%s: %d readings, %d seconds and %d yardsticks per reading" % (name, len(readings), len(secs), len(per))]
    if len(kinds) > 1:
        return ["%s: its readings are divided by the least sample and by the median both" % name]
    median = kinds == {"median of"}
    which = "median" if median else "least"
    pick = statistics.median if median else min
    if count != len(ys):
        out.append("%s: says %d yardstick samples and lists %d" % (name, count, len(ys)))
    # The schedule cost.py keeps: 5 samples, then 2 after each judgement, and 2 more where the
    # seconds ran out and the line was judged again on the step clock.
    if per[0][1] not in (7, 9):
        out.append("%s: the first reading was divided by the %s of %d samples, not of 7 (or 9 where the seconds ran out)" % (name, which, per[0][1]))
    for i in range(1, len(per)):
        if per[i][1] - per[i - 1][1] not in (2, 4):
            out.append("%s: reading %d was divided by the %s of %d samples, %d after reading %d, not 2 (or 4)" % (name, i + 1, which, per[i][1], per[i][1] - per[i - 1][1], i))
    if per[-1][1] != len(ys):
        out.append("%s: the last reading used %d samples, and %d were taken" % (name, per[-1][1], len(ys)))
    for i, ((u, n), s, got) in enumerate(zip(per, secs, readings)):
        want = "%.4f" % pick(ys_f[:n]) if 0 < n <= len(ys_f) else "none"
        if "%.4f" % u != want:
            out.append("%s: reading %d was divided by %.4f, but the %s of the first %d yardstick samples is %s" % (name, i + 1, u, which, n, want))
        if u > 0 and abs(got - s / u) > 0.06 + 0.002 * got:
            out.append("%s: reading %d is %.1f units, but %.3f s over %.4f s is %.1f" % (name, i + 1, got, s, u, s / u))
    judged = float(r["least"])
    if abs(judged - min(readings)) > 0.05:
        out.append("%s: judged at %s, but the least reading is %.1f" % (name, r["least"], min(readings)))
    else:
        # Readings print to one decimal, so two can print alike; the judged figures are either one's.
        tied = [j for j in range(len(readings)) if readings[j] == min(readings)]
        if not any(abs(float(r["unit"]) - per[j][0]) <= 0.0006 and abs(float(r["spent"]) - secs[j]) <= 0.006 for j in tied):
            k = tied[0]
            out.append("%s: judged with %s s over a unit of %s s, which is not its least reading's %.3f s over %.4f s" % (name, r["spent"], r["unit"], secs[k], per[k][0]))
    want = ("%.4f" % min(ys_f), "%.4f" % statistics.median(ys_f), "%.4f" % max(ys_f))
    if tuple(r["spread"]) != want:
        out.append("%s: says the yardstick's least, median and greatest are %s, and its samples give %s" % (name, ", ".join(r["spread"]), ", ".join(want)))
    return out


def check(path):
    try:
        with open(path, errors="replace") as f:
            text = f.read()
    except OSError as e:
        print("%s could not be read: %s" % (path, e))
        return 1
    found, unread = [], []
    for n, raw in enumerate(text.splitlines(), 1):
        m = COST_LINE.match(raw.split(MARK, 1)[-1].strip())
        if m:
            found.append(body_fields(*m.groups()))
        elif raw.strip():
            # A cost log holds records only, so this is one whose shape is no longer read, and its
            # case would go unchecked if it were skipped.
            unread.append("line %d is not a cost record this check reads: %s" % (n, raw.strip()[:120]))
    if not found:
        print("%s holds no cost record, so nothing was checked" % path)
        return 1
    wrong = unread + [f for r in found for f in faults(r)]
    print("\n".join(wrong) if wrong else "ok")
    return 1 if wrong else 0


def main(argv):
    if len(argv) >= 2 and argv[0] == "rows":
        return rows(argv[1:])
    if len(argv) == 2 and argv[0] == "check":
        return check(argv[1])
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
