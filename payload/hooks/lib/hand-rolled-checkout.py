#!/usr/bin/env python3
"""Suites that find the repository by counting folders upwards instead of asking lib/checkout-root.sh
(claude-config#1663).

`"$DIR/../.."` is the repository root when a suite runs from payload/hooks and the HOME DIRECTORY
when the same suite runs from the installed copy, and somewhere else again when it is copied into an
unrelated repository. lib/checkout-root.sh is the one test of whether a folder is the payload of a
claude-config checkout (#1567), and every suite that needs the checkout asks it. This finds the next
suite that hand rolls the lookup instead (L613), so the fix is not converted one site at a time.

WHAT IT LOOKS FOR, in a suite file (a test-*.sh), two shapes:

- An upward derivation, a command substitution that changes into a variable's folder (or a
  `dirname`) followed only by two or more `..` and prints where it landed (`$(cd "$DIR/../.." &&
  pwd)`), wherever the suite sits.
- Any path written from a variable (or a `dirname`) that climbs two or more `..` OUT OF THE PAYLOAD,
  with or without a file named after it (`"$DIR/../../README.md"`, `"$d"/../../tests/test-*.sh`,
  `"$1/../.."`), claude-config#2623. The variable is taken to be the suite's own folder, and the
  path is resolved from where the suite sits in the tree: from payload/hooks two `..` leave the
  payload, from payload/skills/<name> three do, and for a suite outside the payload (tests/) the
  boundary is the repository itself. A path that climbs only to a sibling inside the payload
  (`$DIR/../../hooks` from a skill) is there in the installed copy too and is not reported. That is
  how #2620 shipped: two suites read the README two folders up, which is the checkout's from
  payload/hooks and ~/README.md from the installed copy.

Comments, and a line inside a quoted string spanning lines (a fixture of some other check's input),
are not code and are not judged (lib/shell_code_lines.py).

Reads the paths to judge, relative to --root, one per line on stdin, and judges only the suite files
among them. Prints `<path>:<line>: <text>` for each, and exits 1 when there is any.
"""
import argparse
import os
import re
import io
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shell_code_lines import code_lines  # noqa: E402

SUITE = re.compile(r'(^|/)test-[^/]*\.sh$')
UPWARD = re.compile(r'\$\(\s*cd\s+"?(?:\$\{?\w+\}?|\$\(dirname[^)]*\))(?:/\.\.){2,}/?"?\s*(?:&&|;)\s*pwd')
# A variable (or a dirname) and the run of `..` straight after it, a closing quote allowed between
# the two (`"$d"/../..`). The run must end at a path separator or the end of the word, so `/...x` is
# not counted as a climb.
CLIMB = re.compile(r'\$(?:\{\w+\}|\w+|\(dirname[^)]*\))"?((?:/\.\.)+)(?=/|"|\'|\s|\)|;|$)')


def climbs_out(rel, line):
    """True when a path in the line climbs two or more folders and out of the payload (out of the
    repository, for a suite outside it) from the suite at rel."""
    folders = rel.split('/')[:-1]
    room = len(folders) - (1 if folders and folders[0] == 'payload' else 0)
    for m in CLIMB.finditer(line):
        ups = m.group(1).count('..')
        if ups >= 2 and ups > room:
            return True
    return False


def judge(text, rel=''):
    return [(n, line.strip()) for n, line in code_lines(text)
            if UPWARD.search(line) or climbs_out(rel, line)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    args = ap.parse_args()
    any_found = False
    for rel in io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace").read().split('\n'):
        rel = rel.strip()
        if not rel or not SUITE.search(rel):
            continue
        try:
            with open(os.path.join(args.root, rel), encoding='utf-8', errors='replace') as fh:
                text = fh.read()
        except OSError:
            continue
        for n, t in judge(text, rel):
            any_found = True
            print('%s:%d: %s' % (rel, n, t))
    return 1 if any_found else 0


if __name__ == '__main__':
    sys.exit(main())
