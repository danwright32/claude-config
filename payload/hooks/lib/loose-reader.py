#!/usr/bin/env python3
"""A copy of a hooks folder whose command reader has one of its readings undone, for a suite to run
a gate against and see each of its cases fail on the reading the case defends (L1, claude-config#2235).

A gate's suite proves a refusal real by running the same command through a copy of the gate that
reads it the old way and seeing that copy let it through. The gates find lib/shell-words.py beside
themselves, so the copy is the whole folder, and only the reader inside it is changed. Each suite
used to write its own regular expression over the reader for this; one place keeps the patterns
next to their names, so a change to the reader that moves one breaks every suite at once, loudly,
here, rather than leaving a copy that undoes nothing and passes every "fails on the copy" case.

Usage: loose-reader.py <hooks folder> <dest> <variant>
  redirects  past_redirects passes no redirection over: `2>/dev/null git push` is a command named
             2>/dev/null, as the reader read it before #2235.
  rejoin     rejoin quotes every word, an operator included: words a caller split itself
             (`2>`, `/dev/null`, `gh`) read as a command named 2>.
  glue       shell_tokens cuts a descriptor number from its operator: `2>/dev/null gh` is `2`, `>`,
             `/dev/null`, `gh`, a command named 2.
Exits 1, naming the variant and leaving no copy, when the reading to undo is not found, and 64 on a
bad call.
"""
import os
import re
import shutil
import sys

UNDO = {
    "redirects": (r"def past_redirects\(s\):.*?\n\n\n", "def past_redirects(s):\n    return s\n\n\n"),
    "rejoin": (r"    # A redirection in front of the command's name \(claude-config#2235\).*?"
               r"\n    return \" \"\.join\(pieces\)\n", "    return \" \".join(pieces)\n"),
    "glue": (r"glue = tok\.isdigit\(\) and [^\n]*", "glue = False"),
}


def main(argv):
    if len(argv) != 4 or argv[3] not in UNDO:
        sys.stderr.write("usage: loose-reader.py <hooks folder> <dest> %s\n" % "|".join(sorted(UNDO)))
        return 64
    src, dest, variant = argv[1:]
    if os.path.exists(dest):
        shutil.rmtree(dest)
    shutil.copytree(src, dest, symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
    reader = os.path.join(dest, "lib", "shell-words.py")
    with open(reader, encoding="utf-8") as f:
        text = f.read()
    pattern, replacement = UNDO[variant]
    text, n = re.subn(pattern, lambda _m: replacement, text, count=1, flags=re.S)
    if n != 1:
        # The copy is taken away, so a suite that misses this exit finds no gate to run rather than
        # one that reads exactly as the real one does and passes every "fails on the copy" case.
        shutil.rmtree(dest)
        sys.stderr.write("loose-reader.py: the %s reading was not found in %s, so nothing was undone\n"
                         % (variant, reader))
        return 1
    with open(reader, "w", encoding="utf-8") as f:
        f.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
