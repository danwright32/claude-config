#!/usr/bin/env python3
"""Find the work GitHub organisations named in files this public repository publishes.

claude-config#1568. The work's private repositories live under two GitHub organisations, and this
repository is public. A name like that, written as an owner, a URL, a fixture or a lesson's
provenance, tells a stranger exactly where to look. This is the one scanner for it. Its fixtures are
held by tests/test-work-names.sh. Once sleep mode's repository lists, the last tracked list naming
an organisation, have left the payload (claude-config#1568), the same suite runs it over the whole
tree (before every push and in CI) and claude-sync runs it over what a send is about to publish, so
a name written on a Mac is refused before it is published, not found afterwards (L280).

WHAT COUNTS AS A NAME. An organisation login, in any letter case, wherever it stands as a whole
hyphenated run inside a token: an owner (`<org>/repo`), a URL, a fixture file name before an
underscore, or the tail of a longer login that contains it. Two sources:

  built in   the two work organisations, held ONLY as sha256 hashes of their lower case logins, so
             this file does not itself publish what it guards (and a grep for them finds nothing
             here). This is all CI can check, because CI has no registry.
  registry   the owner of every repository in this Mac's dev update registry, read through its one
             reader (dev-update-registry.js repos), so an organisation added there is guarded on
             that Mac from the next scan. A Mac with no registry is said, never read as empty; an
             unreadable one is refused.

WHAT DOES NOT. A product or repository name on its own (a lesson's `name#123`, a checkout folder, a
product named in prose): without the organisation it locates nothing, it is the vocabulary hundreds
of lessons are written in, and `name#N` is what lesson-fanout.sh parses to skip the repository a
lesson came from. The same login without its hyphen is a different GitHub account, and the
company's public web domain, so it is not one either. These are decisions recorded on #1568's pull
request, not omissions.

NOTHING PRINTED REPEATS A NAME FOUND. A hit is reported as path:line and which source matched. CI
logs of a public repository are public, and a refusal message is read in transcripts.

Usage:
  work-names.py [--root DIR] [--files0-from FILE|-] [PATH ...]
  work-names.py --uncovered-owners     registry owners the built in hashes do not cover
Exit: 0 clean; 1 at least one name found (each listed); 2 could not judge (a listed file could not
be read, the registry could not be read, or node is missing to read it).

Seams (tests): WORK_NAMES_EXTRA_HASHES, comma separated sha256 hex of more lower case logins.
WORK_NAMES_REGISTRY_READER, the reader to ask (default: dev-update-registry.js beside this file).
"""
import hashlib
import json
import os
import re
import subprocess
import sys

BUILT_IN = {
    "91bb8dd6329de4f774a80b5431e2eaa984575662c24063fd0e6672a0c8d6fc2b",  # the work organisation
    "1c166f0036586d4969300ad3475ac491b1f7f09459cb89882da389836bd820af",  # the agency organisation that holds the website
}
TOKEN = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
HERE = os.path.dirname(os.path.abspath(__file__))


def sha(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def extra_hashes():
    raw = os.environ.get("WORK_NAMES_EXTRA_HASHES", "")
    return {h.strip().lower() for h in raw.split(",") if h.strip()}


def read_registry():
    """-> (owners, sentence) or raises SystemExit(2) with the reason said."""
    reader = os.environ.get("WORK_NAMES_REGISTRY_READER") or os.path.join(HERE, "dev-update-registry.js")
    try:
        p = subprocess.run(["node", reader, "repos"], capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        die("node is not on PATH, so this Mac's dev update registry could not be read, and its "
            "owners could not be checked.")
    except subprocess.TimeoutExpired:
        die("reading the dev update registry took over 60 seconds, so its owners could not be checked.")
    try:
        got = json.loads(p.stdout)
    except ValueError:
        die("the dev update registry reader (%s) answered with something that is not JSON: %s"
            % (reader, (p.stdout + p.stderr).strip()[:300]))
    state = got.get("state")
    if state == "missing":
        return set(), ("there is no dev update registry on this Mac (%s), so only the two built in "
                       "work organisation names were checked" % got.get("file"))
    if state != "ok":
        die("the dev update registry could not be read, so its owners could not be checked: %s"
            % got.get("why", ""))
    owners = set()
    for full in got.get("repos") or []:
        owner = full.split("/", 1)[0].strip().lower()
        if owner:
            owners.add(owner)
    return owners, ("the two built in work organisation names and %d owner%s from %s"
                    % (len(owners), "" if len(owners) == 1 else "s", got.get("file")))


def die(msg):
    sys.stderr.write("work-names: " + msg + "\n")
    sys.exit(2)


class Matcher:
    def __init__(self, hashes, owners):
        self.hashes = hashes
        self.owners = owners
        self.cache = {}

    def kind(self, token):
        """None, or which source a token's runs match: every contiguous run of its hyphen parts."""
        if token in self.cache:
            return self.cache[token]
        found = None
        parts = token.split("-")
        n = len(parts)
        for i in range(n):
            for j in range(i + 1, n + 1):
                run = "-".join(parts[i:j])
                if sha(run) in self.hashes:
                    found = "a work organisation name"
                    break
                if run in self.owners:
                    found = "a name from this Mac's dev update registry"
                    break
            if found:
                break
        self.cache[token] = found
        return found


def scan_file(path, shown, matcher, hits):
    with open(path, "rb") as fh:
        data = fh.read()
    if b"\0" in data[:8192]:
        return
    text = data.decode("utf-8", errors="replace").lower()
    tokens = set(TOKEN.findall(text))
    if not any(matcher.kind(t) for t in tokens):
        return
    for no, line in enumerate(text.splitlines(), 1):
        for t in TOKEN.findall(line):
            k = matcher.kind(t)
            if k:
                hits.append("%s:%d: %s" % (shown, no, k))
                break


def main(argv):
    root = None
    files = []
    i = 0
    uncovered = False
    while i < len(argv):
        a = argv[i]
        if a == "--root":
            root = argv[i + 1]; i += 2; continue
        if a == "--files0-from":
            src = argv[i + 1]
            raw = sys.stdin.buffer.read() if src == "-" else open(src, "rb").read()
            files.extend(p.decode("utf-8", errors="surrogateescape") for p in raw.split(b"\0") if p)
            i += 2; continue
        if a == "--uncovered-owners":
            uncovered = True; i += 1; continue
        files.append(a); i += 1

    owners, sentence = read_registry()
    if uncovered:
        missing = sorted(o for o in owners if sha(o) not in BUILT_IN)
        if "no dev update registry" in sentence:
            print(sentence)
            return 0
        if missing:
            print("%d owner%s in this Mac's dev update registry %s not covered by the built in names, "
                  "so CI, which has no registry, cannot see %s. Add the sha256 of each lower case "
                  "login to BUILT_IN in %s." % (len(missing), "" if len(missing) == 1 else "s",
                                                 "is" if len(missing) == 1 else "are",
                                                 "it" if len(missing) == 1 else "them", __file__))
            return 1
        print("every owner in this Mac's dev update registry is covered by the built in names")
        return 0

    matcher = Matcher(BUILT_IN | extra_hashes(), owners)
    hits = []
    unreadable = []
    for f in files:
        path = os.path.join(root, f) if root and not os.path.isabs(f) else f
        if os.path.isdir(path):
            continue
        try:
            scan_file(path, f, matcher, hits)
        except OSError as e:
            unreadable.append("%s (%s)" % (f, e.strerror or e))
    for h in hits:
        print(h)
    summary = "work-names: checked %d file%s for %s" % (len(files), "" if len(files) == 1 else "s", sentence)
    if unreadable:
        sys.stderr.write(summary + ". Could not read: " + "; ".join(unreadable)
                         + ". A listed file that cannot be read is not a clean one.\n")
        return 2
    if hits:
        sys.stderr.write(summary + ". %d line%s name%s one. Replace the organisation with an invented "
                         "one in a fixture, or drop it from prose and provenance (write name#123, "
                         "never owner/name#123).\n" % (len(hits), "" if len(hits) == 1 else "s",
                                                        "s" if len(hits) == 1 else ""))
        return 1
    sys.stderr.write(summary + ": none found.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
