#!/usr/bin/env python3
"""Absence assertions whose needle appears nowhere else in the same suite (claude-config#371).

On 2026-09-11 a fixture's sample text was reworded and two assertions were left matching the old
wording. The positive one ("this publishes") failed honestly. The negative one ("this is NOT
published") PASSED while searching for a string that existed nowhere in the run, so it asserted
nothing at all, and only its positive twin revealed it. A negative assertion is satisfied by
absence, so a needle that can never match is indistinguishable from the behaviour being correct
(L159, L100).

WHAT IT LOOKS FOR: a `! grep -q 'NEEDLE'` assertion whose needle has no literal fragment appearing
anywhere else in the same file. A needle built at run time (one holding $ or a backtick) is not
judged at all: it is a different question and answering it here would be a guess.

WHAT A FINDING MEANS, and this is the important part: MOST findings are legitimate. A needle
naming something the TOOL would print if the defect were present correctly appears nowhere in the
test. Measured over this repo on 2026-09-11: 164 assertions scanned, 6 flagged, and every one of
the six was judged sound on reading. So this is a prompt to go and look, never an accusation, and
the baseline records the reason each surviving finding was accepted (L233).

It is a RATCHET rather than a gate on the whole backlog: the count may not grow, so the next one
gets read, and a finding that is removed has to be removed from the baseline too, or a number
nobody has to tighten becomes a permanent allowance (L182).
"""
import argparse
import os
import re
import sys

NEEDLE = re.compile(r"!\s*grep\s+-[A-Za-z]*q[A-Za-z]*\s+(?:-[A-Za-z-]+\s+)*(['\"])(.+?)\1")
# The characters that make a needle a pattern rather than a string. Splitting on them leaves the
# literal runs, and one of those appearing elsewhere is enough: an anchored needle like `^Synced`
# can never appear mid line in the file that writes it, and judging it on the whole pattern would
# report every anchored assertion in the repo.
META = r"[.*^$|\[\]()+?{}]+"
MIN_FRAGMENT = 6


def fragments(needle):
    plain = re.sub(r"\\(.)", r"\1", needle)
    return [p for p in re.split(META, plain) if len(p) >= MIN_FRAGMENT]


HEREDOC = re.compile(r"<<-?\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?")


def scan_file(path):
    """-> (assertions judged, findings) for one file.

    A heredoc body is FIXTURE TEXT, not an assertion this file runs: a suite that tests this very
    scan has to write example assertions somewhere, and reading them as its own is the shape where
    a script matches itself because it has to name the thing it looks for (L245). The needle in a
    fixture is judged when the fixture is scanned as a file of its own, which is the right place.
    """
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    except OSError:
        return 0, []
    judged = 0
    found = []
    heredoc_end = None
    for n, line in enumerate(lines, 1):
        if heredoc_end is not None:
            if line.strip() == heredoc_end:
                heredoc_end = None
            continue
        # A COMMENT quoting an assertion is prose about one, not one. A file explaining what this
        # scan looks for has to write the shape down, and reading that as an assertion is the same
        # self match a heredoc body is (L245).
        if line.lstrip().startswith("#"):
            continue
        hm = HEREDOC.search(line)
        if hm:
            heredoc_end = hm.group(1)
            continue
        for m in NEEDLE.finditer(line):
            needle = m.group(2)
            # Built at run time: what it will hold is not decidable here.
            if "$" in needle or "`" in needle:
                continue
            frs = fragments(needle)
            # Nothing long enough to look for. Saying "no fragment matched" about a needle with no
            # fragment would be a finding about this scanner rather than about the assertion.
            if not frs:
                continue
            judged += 1
            if not any(any(fr in l for fr in frs) for k, l in enumerate(lines, 1) if k != n):
                found.append((n, needle))
    return judged, found


def read_baseline(path):
    """-> {relative path: count}. Blank lines and comments are not entries."""
    counts = {}
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return None
    for line in text.split("\n"):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.rsplit(":", 1)
        if len(parts) != 2 or not parts[1].strip().isdigit():
            continue
        counts[parts[0].strip()] = int(parts[1])
    return counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--baseline", default=None)
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    baseline_path = args.baseline or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "absence-needles.txt")

    files = []
    for base, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git", "node_modules", "__pycache__")]
        for nm in names:
            if nm.startswith("test-") and nm.endswith(".sh"):
                files.append(os.path.join(base, nm))
    files.sort()

    # A walk that found nothing passes every comparison below at once and reads exactly like a
    # tree where no assertion is suspect (L98).
    if not files:
        print("scan-absence-needles: found no test-*.sh under %s, so nothing was scanned." % root,
              file=sys.stderr)
        return 2

    judged = 0
    now = {}
    detail = {}
    for f in files:
        j, found = scan_file(f)
        judged += j
        if found:
            rel = os.path.relpath(f, root)
            now[rel] = len(found)
            detail[rel] = found

    base = read_baseline(baseline_path)
    if base is None:
        print("scan-absence-needles: no baseline at %s, so there is nothing to compare against "
              "and nothing was verified." % baseline_path, file=sys.stderr)
        return 2

    print("scan-absence-needles: %d absence assertion(s) judged across %d file(s); "
          "%d finding(s) in %d file(s)." % (judged, len(files), sum(now.values()), len(now)))
    for rel in sorted(detail):
        for n, needle in detail[rel]:
            print("  %s:%d  ! grep -q '%s'" % (rel, n, needle))

    grew = [(r, base.get(r, 0), c) for r, c in sorted(now.items()) if c > base.get(r, 0)]
    shrank = [(r, base[r], now.get(r, 0)) for r in sorted(base) if base[r] > now.get(r, 0)]

    rc = 0
    if grew:
        print("\nFAIL: a suite has gained an absence assertion whose needle appears nowhere else "
              "in it. Go and read each one: most are sound, and the one that is not asserts "
              "nothing at all while passing.")
        for r, b, c in grew:
            print("  %s: %d, was %d" % (r, c, b))
        rc = 1
    if shrank:
        print("\nFAIL: the baseline claims findings a suite no longer has, so a number here is "
              "stale. Lower it in the same change, or a count nobody has to tighten becomes a "
              "permanent allowance.")
        for r, b, c in shrank:
            print("  %s: %d, baseline says %d" % (r, c, b))
        rc = 1
    if rc == 0:
        print("scan-absence-needles: every finding is one the baseline already records.")
    return rc


if __name__ == "__main__":
    sys.exit(main())
