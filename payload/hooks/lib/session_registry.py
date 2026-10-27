#!/usr/bin/env python3
"""Whether a Claude Code session on this Mac is still open, read from the session registry.

The session-registry mod keeps one record per session in ~/.claude/state/sessions (never synced),
stamps `lastSeen` every minute while the session's process runs, sets `closedAt` on a clean end, and
moves a record that ended over an hour ago to the archive. Its own rule, settled with Dan on
2026-10-03: a session is open while its record is not closed and was seen within five minutes. This
module is the one reading of that rule for the hooks, so the sleep queue (claude-config#842) and the
merge quiz's sweep of old holds (#1787) judge a session the same way (L261).

A record that cannot be read is never read as no session (L215): it answers "unknown", and every
caller keeps whatever it was about to give up.

As a command:

  ended NOW_MS SELF   reads session ids, one per line, on standard input, and prints those whose
                      session has ended (closed, silent past five minutes, or no longer in the
                      registry). It prints nothing at all when the registry cannot be read, or when
                      it does not show SELF, the session asking, as open: a registry that has lost
                      track of a session plainly running is no evidence that any other one ended.
                      The registry folder is CLAUDE_SESSION_REGISTRY_DIR when set, else
                      ~/.claude/state/sessions.
"""
import json
import os
import re
import sys

DEAD_MS = 5 * 60_000  # the session registry's own rule for a session that has gone quiet
SESSION_ID = re.compile(r"^[A-Za-z0-9-]+$")


def num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def default_path():
    return os.environ.get("CLAUDE_SESSION_REGISTRY_DIR") or os.path.expanduser("~/.claude/state/sessions")


class Registry:
    """The registry read once per call. `missing` names a directory that cannot be read at all."""

    def __init__(self, path, now):
        self.path, self.now = path, now
        self.missing = None
        try:
            self.names = set(os.listdir(path))
        except OSError as e:
            self.names = set()
            self.missing = "the session registry %s could not be read (%s)" % (path, e.strerror or e)

    def session(self, sid):
        """('open' | 'gone' | 'unknown', why) for one session id."""
        if self.missing:
            return "unknown", self.missing
        if not SESSION_ID.match(sid or ""):
            return "unknown", "the claim names no session id this reader accepts"
        name = sid + ".json"
        if name not in self.names:
            return "gone", "session %s is not in the session registry" % sid
        try:
            with open(os.path.join(self.path, name)) as fh:
                r = json.load(fh)
        except Exception:
            return "unknown", "session %s has a registry record that cannot be read" % sid
        if not isinstance(r, dict) or not num(r.get("lastSeen")) or not (r.get("closedAt") is None or num(r.get("closedAt"))):
            return "unknown", "session %s has a registry record that cannot be read" % sid
        if r.get("closedAt") is not None:
            return "gone", "session %s has ended" % sid
        if self.now - r["lastSeen"] > DEAD_MS:
            return "gone", "session %s has been silent for %d minutes" % (sid, (self.now - r["lastSeen"]) // 60_000)
        return "open", ""

    def open_records(self, self_id):
        """Every open session's record but this one's, and the names of records that may be live and cannot be read."""
        out, damaged = [], []
        if self.missing:
            return out, [self.missing]
        for name in sorted(self.names):
            if not name.endswith(".json") or name.startswith("."):
                continue
            path = os.path.join(self.path, name)
            try:
                with open(path) as fh:
                    r = json.load(fh)
                if not isinstance(r, dict) or not num(r.get("lastSeen")):
                    raise ValueError("shape")
            except Exception:
                # A damaged record changed in the last five minutes may be a live session's (the
                # registry's own prune keeps such a record for the same reason); an older one is not.
                try:
                    if self.now - os.stat(path).st_mtime * 1000 <= DEAD_MS:
                        damaged.append(name)
                except OSError:
                    pass
                continue
            if r.get("sessionId") == self_id or r.get("closedAt") is not None or self.now - r["lastSeen"] > DEAD_MS:
                continue
            out.append(r)
        return out, damaged


def ended(registry, self_id, sids):
    """The ids among `sids` whose session has ended, or none at all when the registry cannot vouch for itself."""
    if registry.missing:
        return [], registry.missing
    state, why = registry.session(self_id)
    if state != "open":
        return [], "the session registry does not show this session (%s) open%s, so it is not believed about any other" % (self_id, ": " + why if why else "")
    return [s for s in sids if registry.session(s)[0] == "gone"], ""


def main(argv):
    if len(argv) == 4 and argv[1] == "ended":
        try:
            now = int(argv[2])
        except ValueError:
            print("session_registry.py: NOW_MS must be a whole number of milliseconds, got %r" % argv[2], file=sys.stderr)
            return 2
        sids = [l.strip() for l in sys.stdin if l.strip()]
        out, why = ended(Registry(default_path(), now), argv[3], sids)
        if why:
            print("session_registry.py: %s" % why, file=sys.stderr)
        for s in out:
            print(s)
        return 0
    print("usage: session_registry.py ended NOW_MS SELF  (session ids on standard input)", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
