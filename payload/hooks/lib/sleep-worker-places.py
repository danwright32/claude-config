#!/usr/bin/env python3
"""sleep-worker-places.py: where the sessions sleep mode has working overnight have worked
(claude-config#2943).

Asked by check-stale-worktrees.sh, and only once lib/sleep.sh's sleep_state has said the Mac is
asleep, so whether it is asleep is decided in one place (L261). The stale worktree sweep keeps any
worktree one of these places is inside, because a worker that stopped for the night leaves its
worktree idle for hours, and the sweep's six hour rule then read it as abandoned: on the night of
2026-11-13 it removed a sleeping session's worktree whose pull request was still open.

A worker's places are its session registry record's `cwd` and its `edits` (the files the collision
guard noted it editing, its agents' edits among them). The record is looked for in the registry
and then in its archive beside it, where a record goes an hour after its session ended. A worker
found in neither, a record or sleep record that cannot be read, or a record holding a place that is
not an absolute path, holds a tab or newline, or is missing (#2988), is an error: where it worked
cannot be told, and the caller keeps every worktree rather than read that as "nowhere" (L98).

  python3 sleep-worker-places.py <sleep record> <session registry folder>

Prints one line per place, "<session id><TAB><absolute path>", and exits 0 (no line at all when
the record names no worker). Exits 1 with why on stderr otherwise.
"""
import glob
import json
import os
import re
import sys

SESSION_ID = re.compile(r"^[A-Za-z0-9-]+$")


def fail(why):
    print(why, file=sys.stderr)
    sys.exit(1)


def load(path, what):
    try:
        with open(path, errors="replace") as fh:
            r = json.load(fh)
    except Exception as e:
        fail("%s could not be read (%s)" % (what, e))
    if not isinstance(r, dict):
        fail("%s is not a record" % what)
    return r


def find(registry, sid):
    """The worker's record path: the registry's own, else the newest in its archive, else None."""
    own = os.path.join(registry, sid + ".json")
    if os.path.exists(own):
        return own
    archive = registry.rstrip("/") + "-archive"
    found = sorted(glob.glob(os.path.join(glob.escape(archive), "*", glob.escape(sid) + ".json")))
    return found[-1] if found else None


def main(argv):
    if len(argv) != 3:
        fail("usage: sleep-worker-places.py <sleep record> <session registry folder>")
    record, registry = argv[1], argv[2]
    workers = load(record, "the sleep record %s" % record).get("workers")
    if not isinstance(workers, list) or not all(isinstance(w, str) and SESSION_ID.match(w) for w in workers):
        fail("the sleep record names the sessions working overnight in a shape this reader does not know")
    for sid in workers:
        path = find(registry, sid)
        if path is None:
            fail("session %s, which sleep mode has working overnight, is in neither the session registry "
                 "(%s) nor its archive, so where it worked cannot be read" % (sid, registry))
        r = load(path, "session %s's registry record" % sid)
        edits = r.get("edits", [])
        if not isinstance(edits, list):
            fail("session %s's registry record lists its edits in a shape this reader does not know" % sid)
        for place in [r.get("cwd")] + edits:
            # A place that is not an absolute path, or holds a tab or newline (which would break the
            # line it is printed on), cannot be matched against a worktree. Dropping it would leave a
            # worker whose only places are like that printing nothing, which reads as having worked
            # nowhere, so it is refused like a record that cannot be read (#2988, L98). On 2026-11-14
            # one edit of 1956 in this Mac's registry ended in a newline.
            if not (isinstance(place, str) and place.startswith("/") and "\n" not in place and "\t" not in place):
                fail("session %s's registry record holds a place this reader cannot use (%s), so where "
                     "it worked cannot be read" % (sid, json.dumps(place)[:200]))
            # As recorded, and resolved: git lists a worktree by its real path, and a record can
            # hold the same place through a symlink (/var for /private/var on macOS).
            for p in dict.fromkeys([place.rstrip("/") or "/", os.path.realpath(place)]):
                print("%s\t%s" % (sid, p))
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main(sys.argv))
