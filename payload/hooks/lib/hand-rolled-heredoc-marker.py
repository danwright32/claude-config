#!/usr/bin/env python3
"""A heredoc end marker read by a pattern of its own rather than by lib/shell-words.py (claude-config#2080).

Bash ends a heredoc at the whole word after its <<, quotes taken out: <<'E'OF and <<E"OF" end at a
line EOF, and <<END-OF at END-OF. A pattern written for the usual shapes, a quote, then letters,
then the same quote, reads those three as ending at E, E and END, so a scan using one either
treats everything after the body as text, missing what it exists to catch, or ends the body early
and reads its text as commands (claude-config#2073). Nine places had a pattern of that kind; #2073
moved two and #2080 the other seven, and they all read the marker through heredoc_opener, or heredoc_openers for a line read on its own, in
lib/shell-words.py now, and this scan fails on the next one written (L613).

WHAT IT LOOKS FOR: a line, in a shell, Python or awk file, holding the two angle brackets that open a
heredoc and, within forty characters after them, a character class or escape matching the first
letter of a word, which is how every one of the nine read the marker. A here string's three
brackets are not an opener and are not looked at. lib/shell-words.py itself reads the word one
character at a time, so it holds no such pattern and needs no exemption. Nor does this file: the
pattern below is built from pieces, so no line of it holds the shape it looks for.

NOT READ: TypeScript and JavaScript. A mod cannot load a Python file, so it reads commands through
mod-kit's hooks/commands.ts, which reads the marker as shell-words.py does, and
tools/check-mod-shared-parts.sh fails on a mod with a heredoc reader of its own.

stdin is the files to judge, one per line relative to --root, as lib/repo-files.sh lists them. Each
finding is printed as <file>:<line>: <text>. Exit 1 with findings, 0 with none, and 2 when no file
named could be judged, which would otherwise read as a clean tree (L98).
"""
import argparse
import io
import os
import re
import sys

OPENER = "<" + "<"
# The first letter of a word, as the nine patterns spelt it, and the other spellings of one. A class
# of lower case letters alone is left out: lib/failure-handling.sh's `1 << [a-z_$(]` finds a left
# shift by a variable, which is arithmetic, and no marker reader was ever written that way.
WORD_START = r"(?:\[A-Za-z_|\[a-zA-Z_|\[_A-Za-z|\[_a-zA-Z|\[A-Z_|\[\[:alpha:\]|\[\[:alnum:\]|\\w)"
READER = re.compile("(?<!<)" + OPENER + "(?!<).{0,40}?" + WORD_START)
CODE = re.compile(r"(\.sh|\.bash|\.py|\.awk|(^|/)claude-sync)$")
SHEBANG = re.compile(r"^#!.*\b(bash|sh|zsh|python3?|awk)\b")


def judged(root, rel):
    """True when rel is a file this scan reads: named as one, or carrying a shell, Python or awk
    shebang (a hook installed without its extension)."""
    if CODE.search(rel):
        return True
    if os.path.splitext(rel)[1]:
        return False
    try:
        with open(os.path.join(root, rel), "rb") as fh:
            first = fh.readline(200).decode("utf-8", "replace")
    except OSError:
        return False
    return bool(SHEBANG.match(first))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    args = ap.parse_args()
    read, found = 0, 0
    for rel in io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace").read().split("\n"):
        rel = rel.strip()
        if not rel or not judged(args.root, rel):
            continue
        try:
            with open(os.path.join(args.root, rel), encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError as e:
            print("%s:0: could not be read (%s), so it was not judged" % (rel, e))
            found += 1
            continue
        read += 1
        for n, line in enumerate(text.split("\n"), 1):
            if READER.search(line):
                found += 1
                print("%s:%d: %s" % (rel, n, line.strip()[:160]))
    if not read:
        sys.stderr.write("hand-rolled-heredoc-marker: none of the files named is a shell, Python or awk "
                         "file, so nothing was judged\n")
        return 2
    if found:
        sys.stderr.write("hand-rolled-heredoc-marker: %d line(s) read a heredoc's end marker with a pattern "
                         "of their own. Read it with heredoc_opener (or heredoc_openers, for a line read "
                         "on its own) in lib/shell-words.py, which takes the whole word with its quotes "
                         "removed, as bash does (claude-config#2080)\n" % found)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
