#!/usr/bin/env python3
"""Hooks that work out which Mac they are on by reading the host name themselves, instead of asking
lib/this-mac.sh (claude-config#2561).

Four hooks used to read `hostname` by hand and did not agree: two cut the name at the first dot and
two only a trailing .local, so a name with several dots was the work MacBook to one hook and an
unknown Mac to the next. lib/this-mac.sh is the one reading now, and this finds the next hook that
rolls its own (L613), so the fix is not converted one site at a time.

WHAT IT LOOKS FOR, in a shell file under payload/hooks/ (a .sh, or a file with no extension whose
first line runs a shell): `hostname` run as a command (at the start of a command, after `$(`, a
backtick, `;`, `&&`, `||` or `|`), the shell's own $HOSTNAME, `scutil --get` of a host or computer
name, and `uname -n`. Comments, and a line inside a quoted string spanning lines, are not code and
are not judged (lib/shell_code_lines.py); a sentence that only names hostname, gh's --hostname and
Python's socket.gethostname() are not readings of it.

NOT READ: the suites (a test-*.sh), which stand a fake hostname up to judge as another Mac;
lib/this-mac.sh itself; and anything outside payload/hooks/ (claude-sync, tools, mods, skills, and
Python, which cannot source a shell helper).

stdin is the files to judge, one per line relative to --root, as lib/repo-files.sh lists them. Each
finding is printed as <file>:<line>: <text>. Exit 1 with findings, 0 with none, and 2 when no file
named could be judged, which would otherwise read as a clean tree (L98).
"""
import argparse
import io
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shell_code_lines import code_lines  # noqa: E402

HOOKS = 'payload/hooks/'
HELPER = 'payload/hooks/lib/this-mac.sh'
SUITE = re.compile(r'(^|/)test-[^/]*$')
SHEBANG = re.compile(r'^#!.*\b(ba|z|k|da)?sh\b')

READINGS = re.compile(
    r'(?:^|\$\(|`|;|&&|\|\||\||\bthen\b|\bdo\b|\{)\s*(?:command\s+)?hostname(?![\w.-])'
    r'|\$\{?HOSTNAME\b'
    r'|\bscutil\s+--get\s+(?:LocalHostName|HostName|ComputerName)\b'
    r'|\buname\s+-n\b'
)


def is_shell(rel, text):
    if rel.endswith('.sh'):
        return True
    base = rel.rsplit('/', 1)[-1]
    return '.' not in base and bool(SHEBANG.match(text.split('\n', 1)[0]))


def judge(text):
    return [(n, line.strip()) for n, line in code_lines(text) if READINGS.search(line)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    args = ap.parse_args()
    read = 0
    found = []
    for rel in io.TextIOWrapper(sys.stdin.buffer, encoding='utf-8', errors='replace').read().split('\n'):
        rel = rel.strip()
        if not rel.startswith(HOOKS) or rel == HELPER or SUITE.search(rel):
            continue
        try:
            with open(os.path.join(args.root, rel), encoding='utf-8', errors='replace') as fh:
                text = fh.read()
        except OSError:
            continue
        if not is_shell(rel, text):
            continue
        read += 1
        found.extend('%s:%d: %s' % (rel, n, t) for n, t in judge(text))
    if read == 0:
        sys.stderr.write('hand-rolled-hostname: none of the files named is a shell file under %s, so '
                         'nothing was judged.\n' % HOOKS)
        return 2
    if found:
        print('\n'.join(found))
        sys.stderr.write('hand-rolled-hostname: %d line(s) work out which Mac this is by hand. Ask '
                         'lib/this-mac.sh (this_mac_name) instead, so every hook reads one name '
                         '(claude-config#2561).\n' % len(found))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
