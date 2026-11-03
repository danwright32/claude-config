#!/usr/bin/env python3
"""Python files that build a GitHub owner/name slug by hand instead of asking lib/repo_slug.py
(claude-config#2096).

Three hooks each joined a repository object's owner.login and name themselves, and #2065 came from
one of those copies reading a field gh does not send there. repo_slug.slug() is now the one place
the join is written; this finds the next file that writes its own (L613), so the fix is not
converted one site at a time.

WHAT IT LOOKS FOR, in a Python file: a read of the `login` key by subscript or .get() (the field
that marks gh's owner object), on a line within four lines of a slash join: "%s/%s", a format or
f-string with }/{, a string concatenated with "/", or "/".join. The login read is the line
reported. A login read with no join near it (an author's or an actor's name) is not reported.
Comment lines, and lines inside a string that spans lines (a docstring quoting the old way), are
not code and are not judged. repo_slug.py reads the field through its own path walker, so it
holds no read of this shape and needs no exemption.

Reads the paths to judge, relative to --root, one per line on stdin, and judges only the .py files
among them. Prints `<path>:<line>: <text>` for each finding and exits 1 when there is any; exits 2,
naming it, when a listed Python file cannot be read, since a file not read is not a clean one.
"""
import argparse
import io
import os
import re
import sys
import tokenize

sys.dont_write_bytecode = True

PYTHON = re.compile(r'\.py$')
LOGIN = re.compile(r'''\[\s*['"]login['"]\s*\]|\.get\(\s*['"]login['"]''')
JOIN = re.compile(r'''%s/%s|\}/\{|\+\s*['"]/['"]|['"]/['"]\s*\+|['"]/['"]\s*\.join''')
WINDOW = 4


def non_code(text):
    """Line numbers (1 based) that are comments or inside a string spanning lines."""
    skip = set()
    # From Python 3.12 an f-string arrives as FSTRING_START ... FSTRING_END rather than one STRING.
    f_start, f_end, opened = getattr(tokenize, "FSTRING_START", -1), getattr(tokenize, "FSTRING_END", -1), []
    try:
        for tok in tokenize.generate_tokens(io.StringIO(text).readline):
            if tok.type == tokenize.COMMENT and not tok.line[:tok.start[1]].strip():
                skip.add(tok.start[0])
            elif tok.type == tokenize.STRING and tok.end[0] > tok.start[0]:
                skip.update(range(tok.start[0], tok.end[0] + 1))
            elif tok.type == f_start:
                opened.append(tok.start[0])
            elif tok.type == f_end and opened:
                first = opened.pop()
                if tok.end[0] > first:
                    skip.update(range(first, tok.end[0] + 1))
    except (tokenize.TokenError, SyntaxError, IndentationError):
        # Not parseable as Python: fall back to skipping lines that start as comments.
        for n, line in enumerate(text.split('\n'), 1):
            if line.lstrip().startswith('#'):
                skip.add(n)
    return skip


def judge(text):
    lines = text.split('\n')
    skip = non_code(text)
    code = {n: line for n, line in enumerate(lines, 1) if n not in skip}
    joins = {n for n, line in code.items() if JOIN.search(line)}
    return [(n, line.strip()) for n, line in sorted(code.items())
            if LOGIN.search(line) and any(abs(n - j) <= WINDOW for j in joins)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    args = ap.parse_args()
    any_found = False
    for rel in io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace").read().split('\n'):
        rel = rel.strip()
        if not rel or not PYTHON.search(rel):
            continue
        try:
            with open(os.path.join(args.root, rel), encoding='utf-8', errors='replace') as fh:
                text = fh.read()
        except OSError as exc:
            sys.stderr.write("hand-rolled-slug.py: %s could not be read, so it was not judged: %s\n" % (rel, exc))
            return 2
        for n, t in judge(text):
            any_found = True
            print('%s:%d: %s' % (rel, n, t))
    return 1 if any_found else 0


if __name__ == '__main__':
    sys.exit(main())
