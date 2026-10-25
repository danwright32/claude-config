#!/usr/bin/env python3
"""Suites that find the repository by counting folders upwards instead of asking lib/checkout-root.sh
(claude-config#1663).

`"$DIR/../.."` is the repository root when a suite runs from payload/hooks and the HOME DIRECTORY
when the same suite runs from the installed copy, and somewhere else again when it is copied into an
unrelated repository. lib/checkout-root.sh is the one test of whether a folder is the payload of a
claude-config checkout (#1567), and every suite that needs the checkout asks it. This finds the next
suite that hand rolls the lookup instead (L613), so the fix is not converted one site at a time.

WHAT IT LOOKS FOR, in a suite file (a test-*.sh): an upward derivation, a command substitution that
changes into a variable's folder (or a `dirname`) followed only by two or more `..` and prints where
it landed (`$(cd "$DIR/../.." && pwd)`). A path that goes up and then down again into something
named (`$DIR/../../hooks`) is not a lookup of the repository and is not reported. Comments, and a
line inside a quoted string spanning lines (a fixture of some other check's input), are not code and
are not judged (lib/shell_code_lines.py).

Reads the paths to judge, relative to --root, one per line on stdin, and judges only the suite files
among them. Prints `<path>:<line>: <text>` for each, and exits 1 when there is any.
"""
import argparse
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shell_code_lines import code_lines  # noqa: E402

SUITE = re.compile(r'(^|/)test-[^/]*\.sh$')
UPWARD = re.compile(r'\$\(\s*cd\s+"?(?:\$\{?\w+\}?|\$\(dirname[^)]*\))(?:/\.\.){2,}/?"?\s*(?:&&|;)\s*pwd')


def judge(text):
    return [(n, line.strip()) for n, line in code_lines(text) if UPWARD.search(line)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    args = ap.parse_args()
    any_found = False
    for rel in sys.stdin.read().split('\n'):
        rel = rel.strip()
        if not rel or not SUITE.search(rel):
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
