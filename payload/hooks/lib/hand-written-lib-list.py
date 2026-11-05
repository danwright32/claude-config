#!/usr/bin/env python3
"""Suites that copy a Python or shell hook helper by hand instead of through
lib/install-hook-libs.py (claude-config#2147, shell helpers since #2204).

A suite building a scratch home, or any folder standing in for hooks/lib, used to name each helper
it copied. When a helper gained an import the list did not, and the copy failed only where the
real install was not there to hide the gap: #2118 made sleep-report.py import repo_slug, and the
hand written lists in tests/test-sleep-real-engine.sh and payload/hooks/test-sleep-report.sh each
had to learn repo_slug.py by hand (#2138). lib/install-hook-libs.py installs a helper with every
module beside it that it imports, and every shell helper with what it sources (#2204), so no list
has to know a helper's imports or source lines. Shell helpers were copied the same way, from lists
that would break the first time one helper started sourcing another. This finds the next suite that
copies one by hand instead (L613).

WHAT IT LOOKS FOR, in a suite file (a test-*.sh): a `cp` whose source is a Python or shell file in
payload/hooks/lib, the folder this file sits in. The source is read as written (`"$DIR/lib/x.py"`,
`"$(dirname "$SCRIPT")/payload/hooks/lib/x.sh"`), through a variable the file assigns such a path
to (`PY="$DIR/lib/x.py"` then `cp "$PY" ...`), or as `"$(dirname "$V")/x.py"` where V is such a
variable. Only helpers count: a copy of a hook in payload/hooks, of a JavaScript helper, or of a
whole lib folder (`cp -R "$DIR/lib"`), is not a list of helpers and is not reported.
A `cp` inside a quoted string (a fixture written with printf), a comment, or a heredoc's body (a
stand in the suite writes) is not the suite's own command and is not judged
(lib/shell_code_lines.py).

A suite that means to leave a helper out (to see a scan refuse without lib/shell-words.py) still
goes through install-hook-libs.py: it follows `import` and `source` lines only, so a helper loaded
by its path stays out unless it is named, and one that is imported or sourced is installed and then
removed by the suite, in a line that says so.

Reads the paths to judge, relative to --root, one per line on stdin, and judges only the suite files
among them. Prints `<path>:<line>: <helpers>: <text>` for each, and exits 1 when there is any, or 2
when lib/shell-words.py cannot be loaded and so no line can be told from a heredoc's body.
"""
import argparse
import io
import os
import re
import shlex
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import shell_code_lines  # noqa: E402

SUITE = re.compile(r'(^|/)test-[^/]*\.sh$')
# `cp` as a command word in the line's own code, never inside a string it quotes.
CP_WORD = re.compile(r'(?<![\w./$-])cp(?=\s)')
# The same in the raw line, where the operands are read from.
CP_RAW = re.compile(r'(?<![\w./$\'"-])cp\s+')
# The value ends where the command does, so `SD="$DIR/lib/x.sh"; cp "$SD" ...` reads as the path.
ASSIGN = re.compile(r'''^\s*(?:(?:local|export|readonly|declare)\s+(?:-\w+\s+)?)?([A-Za-z_]\w*)=((?:"[^"]*"|'[^']*'|[^\s;&|"'])+)''')
VAR = re.compile(r'^\$\{?([A-Za-z_]\w*)\}?$')
DIRNAME = re.compile(r'^\$\(dirname\s+\$\{?([A-Za-z_]\w*)\}?\s*\)/([^/]+)$')
LIB_FILE = re.compile(r'(?:^|/)lib/([^/]+)$')


def helpers():
    """The Python and shell helpers: every .py and .sh in the folder this scan sits in."""
    return {f for f in os.listdir(HERE) if f.endswith(('.py', '.sh'))}


def unquote(word):
    try:
        parts = shlex.split(word)
    except ValueError:
        return word.replace('"', '').replace("'", '')
    return ''.join(parts)


def assignments(text):
    """Each variable the file assigns, with every value it is given, quotes removed."""
    found = {}
    for _, line in shell_code_lines.code_lines(text):
        m = ASSIGN.match(line)
        if m:
            found.setdefault(m.group(1), set()).add(unquote(m.group(2)))
    return found


def operands(rest):
    """The words of one cp command, up to the end of the command."""
    lex = shlex.shlex(rest, posix=True, punctuation_chars=';&|')
    lex.whitespace_split = True
    words = []
    try:
        for tok in lex:
            if tok and set(tok) <= set(';&|'):
                break
            words.append(tok)
    except ValueError:
        words = [unquote(w) for w in re.split(r'[;&|]', rest)[0].split()]
    return words


def helper_of(source, assigned, names):
    """The helper a cp source names, or None."""
    m = LIB_FILE.search(source)
    if m and m.group(1) in names:
        return m.group(1)
    m = VAR.match(source)
    if m:
        for value in assigned.get(m.group(1), ()):
            got = LIB_FILE.search(value)
            if got and got.group(1) in names:
                return got.group(1)
    m = DIRNAME.match(source)
    if m and m.group(2) in names:
        for value in assigned.get(m.group(1), ()):
            if re.search(r'(?:^|/)lib/[^/]+$', value):
                return m.group(2)
    return None


def judge(text, names):
    assigned = assignments(text)
    body = shell_code_lines.heredoc_body_lines(text)
    found = []
    for n, line, kind, bare, _ in shell_code_lines.read_lines(text):
        if kind != 'code' or n in body or not CP_WORD.search(bare):
            continue
        hit = []
        for m in CP_RAW.finditer(line):
            words = [w for w in operands(line[m.end():]) if not w.startswith('-')]
            for source in words[:-1]:
                h = helper_of(source, assigned, names)
                if h and h not in hit:
                    hit.append(h)
        if hit:
            found.append((n, ' '.join(hit), line.strip()))
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    args = ap.parse_args()
    if shell_code_lines.READER_ERROR is not None:
        print('hand-written-lib-list: lib/shell-words.py could not be loaded (%s), so no suite was judged'
              % shell_code_lines.READER_ERROR)
        return 2
    names = helpers()
    any_found = False
    unreadable = False
    for rel in io.TextIOWrapper(sys.stdin.buffer, encoding='utf-8', errors='replace').read().split('\n'):
        rel = rel.strip()
        if not rel or not SUITE.search(rel):
            continue
        try:
            with open(os.path.join(args.root, rel), encoding='utf-8', errors='replace') as fh:
                text = fh.read()
        except OSError as e:
            print('hand-written-lib-list: %s could not be read (%s), so it was not judged' % (rel, e.strerror or e))
            unreadable = True
            continue
        for n, hit, t in judge(text, names):
            any_found = True
            print('%s:%d: %s: %s' % (rel, n, hit, t))
    if unreadable:
        return 2
    return 1 if any_found else 0


if __name__ == '__main__':
    sys.exit(main())
