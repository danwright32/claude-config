#!/usr/bin/env python3
"""The one rule a count based ratchet applies (claude-config#377).

Three guards record how many known problems each file still has and fail when a count GROWS, so a
new one is caught on the day it lands, and fail when a count is HIGHER than the file's, so a number
nobody has to tighten cannot become a permanent allowance (L182). The rule was written three times:
once in `test-pipefail-shortcircuit.sh`, and twice more in the two scans added on 2026-09-11, which
were written by copying it. Each read as correct on its own, which is the condition L370 names.

`uncovered-hooks.txt` deliberately does NOT use this. It records a SET of names with no counts, so
"has this grown" is not the question it asks, and making one reader answer both would be sharing a
name rather than a rule (L263, L542).

There is a TWIN of this in ratchet.sh, because two of the callers are shell suites and neither
language can call the other's reader without paying a process per run. Twin implementations in two
languages consume one shared committed fixture (L26): `ratchet-cases.tsv`, which both are driven
against, so they cannot agree on the day they are written and nowhere after it.
"""

BASELINE_SHAPE = "<path>: <count>, one per line, with # comments and blank lines ignored"


def read_baseline(text):
    """The recorded counts, as {path: count}.

    A line that is not `<path>: <number>` is SKIPPED rather than guessed at, because a baseline is
    edited by hand and a half written line read as a zero would silently forgive every finding in
    that file (L50).
    """
    counts = {}
    for line in text.split("\n"):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        path, sep, count = line.rpartition(":")
        if not sep:
            continue
        path, count = path.strip(), count.strip()
        if not path or not count.isdigit():
            continue
        counts[path] = int(count)
    return counts


def verdict(recorded, measured):
    """-> (grown, stale), each a list of (path, recorded, measured), sorted by path.

    BOTH directions, always, and never as an else: a run routinely has one of each, and a reader
    reporting only the first would pass every case but that one.
    """
    grown = [(p, recorded.get(p, 0), c)
             for p, c in sorted(measured.items()) if c > recorded.get(p, 0)]
    stale = [(p, recorded[p], measured.get(p, 0))
             for p in sorted(recorded) if recorded[p] > measured.get(p, 0)]
    return grown, stale


def label(grown, stale):
    """The fixture's one word answer, so the two implementations can be compared on it."""
    if grown and stale:
        return "both"
    if grown:
        return "grown"
    if stale:
        return "stale"
    return "ok"
