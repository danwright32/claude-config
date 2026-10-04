#!/usr/bin/env python3
"""The Writing Style character rule, in one place (claude-config#609).

check-style-guide.sh runs it over the diff a push carries, and the style-check mod runs it over the
text a tool call is about to write, so the two can never give different verdicts (L370, L613). The
characters are written as escapes, so this file holds none of the ones it forbids and needs no
exclusion of its own.

Modes:
  (default)        read a unified diff on stdin; print one "<file>: <line>" per ADDED line that
                   breaks the rule, at most 25 and then a count. Exit 0 either way: the push hook
                   reads the printed findings.
  --plain          read text as written on stdin; print "line <n>: <text>" per offending line.
                   Exit 1 on a finding, 0 when clean.
  --path <p>       with --plain: the file the text is for. A path the push would not scan (a lock
                   file, an image, the top level CLAUDE.md) is clean, judged relative to its git
                   repository the way the push's pathspecs judge it.
  --excludes       print the excluded patterns, one per line, for the push hook's pathspecs.
  --excluded <p>   exit 0 when the path (relative to its repository) is excluded, 1 when not.

Any other argument exits 2, which is never read as clean (L11).
"""
import fnmatch
import io
import os
import re
import subprocess
import sys

EMOJI = re.compile(
    "[\U0001F300-\U0001FAFF\U00002600-\U000027BF\U0001F1E6-\U0001F1FF"
    "\u2934\u2935\u2b05-\u2b07\u2b1b\u2b1c\u2b50\u2b55\ufe0f]"
)
DASH = re.compile("[\u2014\u2013]")

# What a push never scans, as git pathspec globs (a * crosses directories, as git's does). A plain
# name with no wildcard, like CLAUDE.md, means that path at the top of the repository only.
EXCLUDES = [
    "*.lock", "*-lock.json", "*.snap", "*.min.js", "*.min.css", "*.svg",
    "*.png", "*.jpg", "*.jpeg", "*.gif", "*.pdf", "CLAUDE.md",
    ".claude/hooks/check-style-guide.sh",
]


def breaks_rule(text):
    return bool(DASH.search(text) or EMOJI.search(text))


def is_excluded(rel):
    return any(fnmatch.fnmatchcase(rel, pat) for pat in EXCLUDES)


def relative_to_repo(path):
    """A path as the push's pathspecs see it: relative to the top of its repository."""
    if not os.path.isabs(path):
        return path
    d = os.path.dirname(path)
    while d and not os.path.isdir(d):
        d = os.path.dirname(d)
    try:
        top = subprocess.run(
            ["git", "-C", d or "/", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        top = ""
    # Outside any repository there is no top to be relative to: judged as written, so a bare
    # CLAUDE.md pattern cannot excuse a CLAUDE.md anywhere on disk (lessons review of #609).
    if not top:
        return path
    # Both sides resolved: git reports the real path (/private/var on macOS) while the path given
    # may go through a symbolic link (/var), and the two would never line up.
    return os.path.relpath(os.path.realpath(path), os.path.realpath(top))


def scan_diff(stream):
    current_file = "(unknown file)"
    out = []
    for line in stream:
        line = line.rstrip("\n")
        if line.startswith("+++ "):
            f = line[4:]
            current_file = f[2:] if f.startswith("b/") else f
            continue
        if line.startswith("--- NEW FILE: ") and line.endswith(" ---"):
            current_file = line[len("--- NEW FILE: "):-4]
            continue
        if not line.startswith("+") or line.startswith("+++"):
            continue
        content = line[1:]
        if breaks_rule(content):
            out.append(f"{current_file}: {content.strip()[:160]}")
    for o in out[:25]:
        print(o)
    if len(out) > 25:
        print(f"... and {len(out) - 25} more")
    return 0


def scan_plain(stream, path):
    if path is not None and is_excluded(relative_to_repo(path)):
        return 0
    hits = 0
    for n, line in enumerate(stream.read().split("\n"), 1):
        if breaks_rule(line):
            hits += 1
            if hits <= 25:
                print(f"line {n}: {line.strip()[:160]}")
    if hits > 25:
        print(f"... and {hits - 25} more")
    return 1 if hits else 0


def text_stdin():
    """Standard input as text, never raising: a byte that is not UTF-8 (a file cut part way through
    a character by head -c, or binary) becomes a replacement character. A crash here would exit 1,
    which --plain uses for found a dash (lessons review of #609)."""
    return io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace")


def main(argv):
    if not argv:
        return scan_diff(text_stdin())
    if argv == ["--excludes"]:
        print("\n".join(EXCLUDES))
        return 0
    if len(argv) == 2 and argv[0] == "--excluded":
        return 0 if is_excluded(relative_to_repo(argv[1])) else 1
    if argv[0] == "--plain":
        rest = argv[1:]
        if not rest:
            return scan_plain(text_stdin(), None)
        if len(rest) == 2 and rest[0] == "--path":
            return scan_plain(text_stdin(), rest[1])
    print(f"style-scan: unknown arguments {argv!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    # Any other failure exits 2, never 1, so it can only ever read as could not check.
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as err:  # noqa: BLE001
        print(f"style-scan: {err!r}", file=sys.stderr)
        sys.exit(2)
