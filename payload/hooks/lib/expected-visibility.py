#!/usr/bin/env python3
"""What a repository says its visibility on GitHub is meant to be: the one reader of
.github/expected-visibility (claude-config#3582).

Two things act on that file, and both read it here, so they cannot come to read it differently:
  * repo-visibility-notice.sh, at a session's start, says when GitHub disagrees with it;
  * work_names_publish_gate.py judges text posted to a repository that declares itself public even
    while GitHub says the repository is private (Dan, 2026-11-25, on #3582).

THE FILE. Its first line that is not a comment (a line whose first character that is not white
space is #) and not blank, and that line's first word, in any letter case: public, private or
internal. Anything else there, an empty file and a file of comments alone are a declaration that
cannot be understood, which is not the same as no declaration, and each caller says so: the notice
says it could not tell, and the gate refuses.

    parse(text)      -> "public", "private", "internal", or None for text that states none of them
    checkout(folder) -> None outside a git checkout, else a Checkout:
        top           the checkout's root (a worktree's own root, from any folder inside it)
        state         NONE: no such file in the working tree or on origin's default branch
                      STATED: value holds what it says
                      UNREADABLE: it is there and could not be read (why says how)
                      UNKNOWN: it was read and states none of the three (why says so)
        origin_state  ORIGIN_OK (slug is owner/name), ORIGIN_NONE (no origin remote),
                      ORIGIN_UNREAD (an origin that is not a GitHub address this can read)

WHERE IT IS READ. The working tree's copy when something is at that path: a regular file is read,
and anything else there (a folder, a link to nothing) is UNREADABLE. With nothing at that path the
copy on origin's default branch as last fetched is read (refs/remotes/origin/HEAD, then main, then
master), because a checkout behind its origin may not hold the file yet: this repository's primary
checkout was 474 commits behind main the night the notice was written. That is a local read, with
no network in it. A copy found there is judged as the working tree's is, an empty one included.

Run as a command, for the notice, it prints four lines for the folder it is given: the state, the
value, the origin state and the slug, each empty when it has nothing to say, and "norepo" alone
outside a checkout. It always exits 0 once it has printed; any other exit is the reader failing.
"""
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True

PATH = ".github/expected-visibility"
VALUES = ("public", "private", "internal")
NONE, STATED, UNREADABLE, UNKNOWN = "none", "stated", "unreadable", "unknown"
ORIGIN_OK, ORIGIN_NONE, ORIGIN_UNREAD = "ok", "none", "unread"
REFS = ("refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/remotes/origin/master")
NOT_ONE_OF = "the first line of its %s that is not a comment is not public, private or internal" % PATH
# Each git read's bound, a setting, not a measurement: the reads took 0.020 to 0.023 seconds together
# over five runs on the personal MacBook on 2026-11-26, at a load average near 40. A read that
# outlasts it is never taken as no file: outside a checkout's root it reads as no checkout, which
# sends the gate to GitHub, and on origin's copy it is UNREADABLE.
GIT_SECONDS = 5

_COMMENT = re.compile(r"[ \t\r\f\v]*#")
_FIELDS = re.compile(r"[ \t]+")
_SLUG = re.compile(r"[A-Za-z0-9_./-]+\Z")
_ADDRESSES = ("https://github.com/", "ssh://git@github.com/", "git@github.com:")
_LOWER = {ord(c): ord(c.lower()) for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"}


def parse(text):
    """What the file's text states, or None when it states none of the three."""
    for line in (text or "").split("\n"):
        if _COMMENT.match(line):
            continue
        fields = [f for f in _FIELDS.split(line) if f]
        if not fields:
            continue
        word = fields[0].translate(_LOWER)
        return word if word in VALUES else None
    return None


def slug_of(address):
    """owner/name for a GitHub remote address, or None for one this cannot read as that."""
    address = (address or "").strip("\n")
    for start in _ADDRESSES:
        if address.startswith(start):
            slug = address[len(start):]
            break
    else:
        return None
    if slug.endswith("/"):
        slug = slug[:-1]
    if slug.endswith(".git"):
        slug = slug[:-4]
    if slug.count("/") != 1 or slug.startswith("/") or slug.endswith("/") or not _SLUG.match(slug):
        return None
    return slug


class Checkout:
    def __init__(self, top):
        self.top = top
        self.state, self.value, self.why = NONE, None, ""
        self.origin_state, self.slug = ORIGIN_NONE, None


def _git(top, *args):
    """-> (exit code, stdout as text), or (None, "") when git could not be run or did not answer."""
    try:
        p = subprocess.run(["git", "-C", top] + list(args), capture_output=True, timeout=GIT_SECONDS)
    except (OSError, subprocess.SubprocessError):
        return None, ""
    return p.returncode, p.stdout.decode("utf-8", "replace")


def _stated(co, text):
    value = parse(text)
    if value is None:
        co.state, co.why = UNKNOWN, NOT_ONE_OF
    else:
        co.state, co.value = STATED, value


def checkout(folder):
    """The declaration and the origin of the git checkout folder is in, or None when it is in none."""
    rc, out = _git(folder or os.getcwd(), "rev-parse", "--show-toplevel")
    top = out.strip("\n")
    if rc != 0 or not top:
        return None
    co = Checkout(top)
    path = os.path.join(top, *PATH.split("/"))
    if os.path.lexists(path):
        if not os.path.isfile(path):
            co.state, co.why = UNREADABLE, "its %s is there but is not a file that can be read" % PATH
        else:
            try:
                with open(path, "rb") as fh:
                    _stated(co, fh.read().decode("utf-8", "replace"))
            except OSError as e:
                co.state = UNREADABLE
                co.why = "its %s is there but could not be read (%s)" % (PATH, e.strerror or type(e).__name__)
    else:
        for ref in REFS:
            rc, out = _git(top, "show", "%s:%s" % (ref, PATH))
            if rc is None:
                co.state = UNREADABLE
                co.why = "git did not answer when asked for the copy of %s on origin's default branch" % PATH
                break
            if rc == 0:
                _stated(co, out)
                break
    rc, out = _git(top, "remote", "get-url", "origin")
    if rc == 0:
        co.slug = slug_of(out)
        co.origin_state = ORIGIN_OK if co.slug else ORIGIN_UNREAD
    return co


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: expected-visibility.py <folder>\n")
        return 2
    co = checkout(argv[1])
    if co is None:
        print("norepo")
        return 0
    print("\n".join((co.state, co.value or "", co.origin_state, co.slug or "")))
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main(sys.argv))
