#!/usr/bin/env python3
"""How often this Mac's lessons reviews leave a finding unplaced, and why (claude-config#1368).

    python3 ~/.claude/hooks/lib/ai-review-placement.py [--since WHEN] [--state-dir DIR] [--misses]

The review runner (ai-review-run.py) places each finding at the line its `Quote:` names, and one it
cannot place keeps the number it cited and carries `[review harness: not placed, <why>, ...]`. This
counts, over the finished reviews in the state folder (AI_REVIEW_STATE_DIR, else
~/.claude/state/ai-review), the reviews by kind, their findings, the placed share, the not placed
ones by reason, and how the placed ones were placed from the `placement=` value reviews record since
#1368. The reason is read back by the runner's own classifier (unplaced_kind), so every reason the
runner writes is a kind here; one it does not know is counted as other, never dropped.

It also gives the lengths of the quotes placed by part of a line (from the `part_quote_lengths=`
reviews record since #1701) and of the quotes that matched no line (from their marks), in bands
around the runner's 20 character floor for part of a line, so that floor can be set from them
(claude-config#1701). A mark from before #1701 kept only the first 60 characters of a longer
quote, so such a quote is counted on its own, its length unknown. --misses lists every quote that
matched no line, one per line, as its mark keeps it (a line break written as an escape).

WHEN is a time in epoch seconds, or a date (`2026-10-20`) or date and time (`2026-10-20 02:56`) on
this Mac's clock. A review counts when its status is ok and it STARTED at or after WHEN, so a change
to the runner installed at WHEN is in every review counted. Run it on each Mac: each keeps its own.

The review files are swept after 14 days, so the window reaches back at most that far. Exit 0 when
at least one review was counted, 2 when none was (UNMEASURED, never a rate of zero, L90), 64 on a
WHEN it cannot read.
"""
import argparse
import glob
import importlib.util
import os
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def runner():
    spec = importlib.util.spec_from_file_location("ai_review_run", os.path.join(HERE, "ai-review-run.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def read_since(text):
    if text is None:
        return None
    if text.isdigit():
        return int(text)
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%dT%H:%M", "%Y-%m-%d"):
        try:
            return int(time.mktime(time.strptime(text, fmt)))
        except ValueError:
            pass
    return "bad"


def when(epoch):
    return time.strftime("%Y-%m-%d %H:%M %Z", time.localtime(epoch))


def share(n, total):
    return f"{n} ({100.0 * n / total:.1f}%)"


# Length bands for the quote length lines, finest around the runner's 20 character floor for part
# of a line (PART_MIN), which is what the lines exist to judge (claude-config#1701).
BANDS = ((0, 9, "under 10"), (10, 19, "10 to 19"), (20, 29, "20 to 29"), (30, 39, "30 to 39"),
         (40, 59, "40 to 59"), (60, 99, "60 to 99"), (100, None, "100 or more"))


def bands(lengths):
    counts = [0] * len(BANDS)
    for n in lengths:
        for i, (lo, hi, _) in enumerate(BANDS):
            if n >= lo and (hi is None or n <= hi):
                counts[i] += 1
                break
    return ", ".join(f"{label}: {c}" for (_, _, label), c in zip(BANDS, counts))


def main(argv):
    ap = argparse.ArgumentParser(description="How often lessons review findings go unplaced, and why.")
    ap.add_argument("--since", help="epoch seconds, or a local date or date and time")
    ap.add_argument("--state-dir", default=os.environ.get("AI_REVIEW_STATE_DIR")
                    or os.path.expanduser("~/.claude/state/ai-review"))
    ap.add_argument("--misses", action="store_true",
                    help="also list every quote that matched no line, one per line, as its mark keeps it")
    a = ap.parse_args(argv)
    since = read_since(a.since)
    if since == "bad":
        print(f"ai-review-placement: cannot read --since {a.since!r}: give epoch seconds, "
              "YYYY-MM-DD or 'YYYY-MM-DD HH:MM'.", file=sys.stderr)
        return 64
    if not os.path.isdir(a.state_dir):
        print(f"UNMEASURED: there is no review state folder at {a.state_dir}.")
        return 2
    m = runner()

    reviews, kinds, findings, recorded, unreadable, unopened = 0, {}, 0, 0, [], []
    first = last = None
    how = {"whole": 0, "marker": 0, "part": 0, "path": 0}
    why = {k: 0 for k, _ in m.UNPLACED_KINDS}
    why["other"] = 0
    tried = {"marker": 0, "part": 0, "short": 0}
    part_lengths, part_recorded, miss_lengths, miss_cut, miss_lines = [], 0, [], 0, []
    for path in sorted(glob.glob(os.path.join(a.state_dir, "*.txt"))):
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                head, _, body = f.read().partition("\n\n")
        except OSError:
            # Its status cannot be known, so it is named rather than silently left out (L11).
            unopened.append(os.path.basename(path))
            continue
        meta = dict(line.split("=", 1) for line in head.splitlines() if "=" in line)
        if meta.get("status") != "ok":
            continue
        try:
            started, finished = int(meta["started"]), int(meta["finished"])
        except (KeyError, ValueError):
            unreadable.append(os.path.basename(path))
            continue
        if since is not None and started < since:
            continue
        reviews += 1
        kind = meta.get("kind") or "push"
        kinds[kind] = kinds.get(kind, 0) + 1
        first = finished if first is None else min(first, finished)
        last = finished if last is None else max(last, finished)
        if meta.get("placement"):
            recorded += 1
            for part in meta["placement"].split(","):
                k, _, n = part.partition(":")
                if k in how and n.isdigit():
                    how[k] += int(n)
        # Recorded by reviews since #1701, empty when none was placed by part of a line.
        if "part_quote_lengths" in meta:
            part_recorded += 1
            part_lengths += [int(n) for n in meta["part_quote_lengths"].split(",") if n.isdigit()]
        for line in body.splitlines():
            if not m.FINDING.match(line):
                continue
            findings += 1
            mark = m.MARK.search(line)
            if not mark:
                continue
            reason = mark.group(1)
            k = m.unplaced_kind(reason)
            why[k] += 1
            if k == "no_match":
                words = m.reason_words(reason)
                tried["marker"] += "without its leading" in words
                tried["part"] += "whole or in part" in words
                tried["short"] += "too short to be placed by part of a line" in words
                quote, length = m.mark_quote(reason)
                if length is None:
                    miss_cut += 1
                    said = f"longer than {m.OLD_QUOTE_SHOWN}, only its first {m.OLD_QUOTE_SHOWN} kept"
                else:
                    miss_lengths.append(length)
                    said = f"{length} characters"
                where = m.FINDING.match(line).group(0)
                miss_lines.append(f"{os.path.basename(path)} {where}{said}: {m._one_line(quote or '')}")

    if unopened:
        print(f"not counted, the file could not be opened: {', '.join(unopened)}")
    if unreadable:
        print(f"not counted, its start or finish time unreadable: {', '.join(unreadable)}")
    if not reviews:
        print(f"UNMEASURED: no finished review in {a.state_dir}"
              + (f" started at or after {when(since)}." if since is not None else "."))
        return 2
    by_kind = ", ".join(f"{k} {kinds.get(k, 0)}" for k in sorted(set(kinds) | {"pr", "push"}))
    print(f"Lessons review placement on {socket.gethostname().split('.')[0]}, from {a.state_dir}"
          + (f", reviews started at or after {when(since)}" if since is not None else "")
          + f", finished {when(first)} to {when(last)}.")
    print(f"reviews: {reviews} ({by_kind})")
    print(f"findings: {findings}")
    unplaced = sum(why.values())
    if not findings:
        print("no findings, so no rate of placement to give.")
        return 0
    print(f"placed: {share(findings - unplaced, findings)}")
    print(f"not placed: {share(unplaced, findings)}")
    print(f"  the cited path is not a file at the reviewed head: {why['no_file']}")
    print(f"  its quote matches no line: {why['no_match']} (retried without a leading + or -: "
          f"{tried['marker']}, tried as part of a line: {tried['part']}, too short for part of a "
          f"line: {tried['short']})")
    print(f"  it quoted no line: {why['no_quote']}")
    print(f"  its Quote line was empty: {why['empty_quote']}")
    print(f"  the reviewed head could not be read: {why['head_unreadable']}")
    print(f"  other: {why['other']}")
    print(f"how placed, from the {recorded} of {reviews} reviews that record it: whole line {how['whole']}, "
          f"without the diff's marker {how['marker']}, part of a line {how['part']}, "
          f"path corrected {how['path']}")
    print(f"quote lengths placed by part of a line, from the {part_recorded} of {reviews} reviews that "
          f"record them: {bands(part_lengths)}")
    print(f"quote lengths matching no line: {bands(miss_lengths)}, and longer than {m.OLD_QUOTE_SHOWN} "
          f"but cut to {m.OLD_QUOTE_SHOWN} by a mark from before #1701: {miss_cut}")
    if a.misses:
        print("quotes that matched no line:" if miss_lines else "no quote matched no line.")
        for row in miss_lines:
            print(row)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
