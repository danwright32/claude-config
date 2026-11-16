#!/usr/bin/env python3
"""Which changes in the REAL sleep folder and ~/Downloads were made by test-sleep-real-engine.sh.

The suite runs against a scratch HOME, and its last check says the real ~/.claude/state/sleep and
~/Downloads gained nothing (L322). "Gained nothing" read as "no file there is newer than the start of
the run" also accused every OTHER session that wrote there meanwhile (a night in progress, a worker's
note), so a full run went red for a write the suite never made (claude-config#3059).

A change counts here only when it is attributable to THIS run: its path or its contents name
something this run invented and nobody else could have, read from what the run wrote into the scratch
home (the session ids and night stamps it generated, the demo repository, the scratch folder itself).
A leak through a hardcoded real path carries those; another session's write never does.

usage: sleep-real-engine-leaks.py REAL_HOME SCRATCH_HOME STARTED_FILE WORK
prints one leaked path per line, nothing when none. Read only.
"""
import os
import re
import sys

# A session id, and a night stamp (milliseconds since the epoch, as /sleep names its folders).
ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
STAMP = re.compile(r"(?<![0-9])[0-9]{13}(?![0-9])")
READ_LIMIT = 1 << 20


def walk(root):
    for base, _dirs, files in os.walk(root):
        for name in files:
            yield os.path.join(base, name)


def markers_of(scratch_home, work):
    """What this run invented, from the paths and the small files it wrote into the scratch home."""
    found = {"sleepdemo", work}
    roots = [
        os.path.join(scratch_home, ".claude", "state", "sleep"),
        os.path.join(scratch_home, ".claude", "projects"),
        os.path.join(scratch_home, "Downloads"),
    ]
    for root in roots:
        for path in walk(root):
            rel = os.path.relpath(path, scratch_home)
            found.update(ID.findall(rel))
            found.update(STAMP.findall(rel))
            try:
                with open(path, "rb") as fh:
                    text = fh.read(READ_LIMIT).decode("utf-8", "replace")
            except OSError:
                continue
            found.update(ID.findall(text))
    return {m for m in found if m}


def main(argv):
    if len(argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    real_home, scratch_home, started_file, work = argv[1:]
    started = os.stat(started_file).st_mtime_ns
    markers = markers_of(scratch_home, work)
    candidates = list(walk(os.path.join(real_home, ".claude", "state", "sleep")))
    downloads = os.path.join(real_home, "Downloads")
    if os.path.isdir(downloads):
        for name in os.listdir(downloads):
            path = os.path.join(downloads, name)
            if os.path.isfile(path) and "sleep report" in name.lower():
                candidates.append(path)
    leaked = []
    for path in sorted(candidates):
        try:
            if os.stat(path).st_mtime_ns <= started:
                continue
            with open(path, "rb") as fh:
                text = fh.read(READ_LIMIT).decode("utf-8", "replace")
        except OSError:
            continue
        haystack = path + "\n" + text
        if any(m in haystack for m in markers):
            leaked.append(path)
    for path in leaked:
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
