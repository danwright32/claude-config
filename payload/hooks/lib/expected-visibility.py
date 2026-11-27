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
                      SILENT: git did not answer, so none of the above is known (why says when);
                      top is None when it was the first question, which checkout this is
        origin_state  ORIGIN_OK (slug is owner/name), ORIGIN_NONE (no origin remote),
                      ORIGIN_UNREAD (an origin that is not a GitHub address this can read),
                      ORIGIN_SILENT (git did not answer when asked for it)

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
import time

sys.dont_write_bytecode = True

PATH = ".github/expected-visibility"
VALUES = ("public", "private", "internal")
NONE, STATED, UNREADABLE, UNKNOWN, SILENT = "none", "stated", "unreadable", "unknown", "silent"
ORIGIN_OK, ORIGIN_NONE, ORIGIN_UNREAD, ORIGIN_SILENT = "ok", "none", "unread", "silent"
REFS = ("refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/remotes/origin/master")
NOT_ONE_OF = "the first line of its %s that is not a comment is not public, private or internal" % PATH
# One bound for every git read of one checkout() call together, a setting, not a measurement: the
# reads took 0.020 to 0.023 seconds together over five runs on the personal MacBook on 2026-11-26,
# at a load average near 40. It is one bound and not one per read so that the notice, whose hook
# has a 10 second timeout and then asks GitHub for up to 4, still gets to say it could not tell: cut
# off by that timeout it would say nothing, which reads as checked and as expected (the lessons
# review of cce2f6f). test-repo-visibility-notice.sh holds that timeout above this bound, gh's and
# 3 seconds more, so raising this fails there until the timeout follows (the review of e1fc74a). A read that outlasts it, one not made because the time had passed, and a git
# that cannot be run are SILENT, never no checkout, no origin or no file: each of those would send
# the publish gate to GitHub's copy in the place of this checkout's own, which can say what
# GitHub's does not (the lessons review of 3a7131c). EXPECTED_VISIBILITY_GIT_SECONDS replaces the
# bound for the suites, and is read only under HOOK_TESTS_RUNNING=1.
GIT_SECONDS = 3

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


def _bound():
    if os.environ.get("HOOK_TESTS_RUNNING") == "1":
        try:
            return float(os.environ["EXPECTED_VISIBILITY_GIT_SECONDS"])
        except (KeyError, ValueError):
            pass
    return GIT_SECONDS


def _git(top, ends, *args):
    """-> (exit code, stdout as text), or (None, "") when git could not be run, did not answer
    before ends (a time.monotonic() reading), or was not asked because that time had passed."""
    left = ends - time.monotonic()
    if left <= 0:
        return None, ""
    try:
        p = subprocess.run(["git", "-C", top] + list(args), capture_output=True, timeout=left)
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
    """The declaration and the origin of the git checkout folder is in, or None when git says it is
    in none. When git does not answer that first question the Checkout has no top and is SILENT."""
    ends = time.monotonic() + _bound()
    rc, out = _git(folder or os.getcwd(), ends, "rev-parse", "--show-toplevel")
    if rc is None:
        co = Checkout(None)
        co.state, co.origin_state = SILENT, ORIGIN_SILENT
        co.why = "git did not answer when asked which checkout this is"
        return co
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
            rc, out = _git(top, ends, "show", "%s:%s" % (ref, PATH))
            if rc is None:
                co.state = SILENT
                co.why = "git did not answer when asked for the copy of %s on origin's default branch" % PATH
                break
            if rc == 0:
                _stated(co, out)
                break
    rc, out = _git(top, ends, "remote", "get-url", "origin")
    if rc is None:
        co.origin_state = ORIGIN_SILENT
    elif rc == 0:
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
