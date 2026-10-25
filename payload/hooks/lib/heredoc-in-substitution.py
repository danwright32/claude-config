#!/usr/bin/env python3
"""A heredoc inside a command substitution whose body holds a single quote (claude-config#1690).

macOS ships bash 3.2, and bash 3.2 finds the end of a `$( ... )` by scanning its text for quotes
BEFORE it reads any heredoc inside it, so an apostrophe in the heredoc's body (an English word in a
python program's comment or string) opens a quote that never closes: "unexpected EOF while looking
for matching quote", and the whole file is refused, naming its last line. A suite that does this dies
with exit 2 and no SUITE-RESULT line. Found in test-ai-review-on-push.sh by the #1368 builder and in
another suite by #1575. A newer bash parses the same file, so CI (bash 5 on Linux) cannot see it and
the parse check (check-shell-syntax.sh) sees it only on a Mac: hence a scan of the text, which reads
the same everywhere. A body with BALANCED quotes parses today and breaks on the next apostrophe
anybody adds, so any single quote in the body is reported, not only an unbalanced one.

The remedy is to write the body to a file first and run that file inside the substitution, or to
pipe the heredoc outside it.

WHAT IT LOOKS FOR: a heredoc operator (`<<WORD`, `<<'WORD'`, `<<-WORD`) that sits inside an unclosed
`$(` on its line, outside any quote within that substitution, and whose `$(` is not itself inside a
single quoted string (then it is text, as in a printf of a command a hook is shown). Its body, up to
the delimiter, is read for a `'`. Comments and lines inside a quoted string spanning lines are not
code and are not judged (lib/shell_code_lines.py).

Reads the paths to judge, relative to --root, one per line on stdin: shell files (*.sh, and
claude-sync). Prints `<path>:<line>: <text>` for each, and exits 1 when there is any.
"""
import argparse
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shell_code_lines import code_lines  # noqa: E402

SHELL = re.compile(r'(\.sh|(^|/)claude-sync)$')


def judge(text):
    lines = text.split('\n')
    found = []
    for n, line, ops in code_lines(text, with_heredocs=True):
        for strip, word, inside in ops:
            if not inside:
                continue
            for body in lines[n:]:
                if (body.lstrip('\t') if strip else body) == word:
                    break
                if "'" in body:
                    found.append((n, line.strip()))
                    break
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    args = ap.parse_args()
    any_found = False
    for rel in sys.stdin.read().split('\n'):
        rel = rel.strip()
        if not rel or not SHELL.search(rel):
            continue
        try:
            with open(os.path.join(args.root, rel), encoding='utf-8', errors='replace') as fh:
                text = fh.read()
        except OSError:
            continue
        for n, t in judge(text):
            any_found = True
            print('%s:%d: %s' % (rel, n, t))
    return 1 if any_found else 0


if __name__ == '__main__':
    sys.exit(main())
