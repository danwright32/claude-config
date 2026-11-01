#!/usr/bin/env python3
"""A child the shell never waits for, in a shell that is writing into a pipe (claude-config#1984).

macOS ships bash 3.2. A child started by process substitution is never waited for, so its SIGCHLD
arrives whenever it happens to exit, and it can arrive while a builtin printf or echo is writing into
a pipe. Bash 3.2 does not restart a write a signal interrupts: it says "write error: Interrupted
system call" and the rest of the output is lost (L1035, claude-config#1974, where claude-sync lost
the deepest rule file it was listing). Every shell this reads writes into a pipe on some path: the
watcher runs the whole of claude-sync inside `$( watch_tick 2>&1 )`, the suites capture what it
prints, and Claude Code reads every hook's stdout and stderr through pipes. So the shape is refused
wherever it occurs, rather than in a list of functions somebody judged to be captured (L96).

WHAT IT REPORTS, one line per site, `<path>:<line>: <kind>: <text>`:

  redirect     `< <(...)` or `N< <(...)`: the loop or function reading it runs in THIS shell, so the
               child is this shell's and its exit can interrupt whatever this shell prints next.
               The remedy is #1983's: read the output into a variable with `$(...)`, which waits for
               every child before it returns, and feed the loop from a here document.

  argument     `cmd <(...)` (or `>(...)`) as a simple command of this shell: bash forks the child
               while expanding the words, BEFORE it forks cmd, so the child is this shell's too
               (measured on /bin/bash 3.2 by test-unwaited-children.sh). Not reported inside a
               `$(...)`, a `( ... )` or another process substitution, nor in a pipeline: there the
               child belongs to the subshell bash forks for that part, which prints nothing itself.

  background   (with --background only) a command put in the background with `&` in a function
               that never calls `wait`: that child exits whenever it likes. claude-sync is held to
               this; the hooks start detached workers on purpose and are not (yet).

Enough of the shell is followed to know which text is code: single, double and $'...' quotes, a
comment, a backslash, a heredoc's body, and a stack of `$(`, `<(`, `>(`, `(` and `${` so a
substitution is known to be open across lines. lib/shell_code_lines.py is the shared reader for
which LINES are code, but it keeps no stack of parentheses (a `)` closing a process substitution
reads there as closing the command substitution around it), and this question is about exactly
that, so the walk is its own. A `case` pattern's `)` is recognised by an open `case` and ignored.

Reads the paths to judge, relative to --root, one per line on stdin. Exits 1 when it reports
anything. --count prints, last, how many files and code lines it judged, so a caller can refuse a
pass that read nothing (L98).
"""
import argparse
import io
import os
import re
import sys

HEREDOC = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_]\w*)\2")
FUNC = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# Where a word is a command rather than an argument, so `case` there opens a case statement.
CMDPOS = re.compile(r"(^|[;&|({]|\bthen|\bdo|\belse)\s*$")


class Walk:
    def __init__(self):
        self.stack = []          # frames: 'cs' $( , 'ps' <( >( , 'par' ( , 'brace' ${ , 'dq' " , 'case'
        self.quote = None        # None, "'" or "$'" while inside a single quoted string
        self.heredocs = []       # (strip_tabs, word) opened and not yet read
        self.stmts = {}          # depth -> {'piped': bool, 'sites': [(line, text)], 'end': bool}
        self.found = []          # (line, kind, text)
        self.func = None
        self.func_bg = []        # background sites in the current function
        self.func_wait = False
        self.code_lines = 0

    # The frames that make an argument process substitution belong to a subshell.
    def enclosed(self):
        return any(f in ('cs', 'ps', 'par') for f in self.stack)

    def code_depth(self):
        return sum(1 for f in self.stack if f in ('cs', 'ps', 'par'))

    def stmt(self):
        d = self.code_depth()
        if d not in self.stmts:
            self.stmts[d] = {'piped': False, 'sites': [], 'end': False}
        return self.stmts[d]

    def end_stmt(self, d=None):
        d = self.code_depth() if d is None else d
        s = self.stmts.pop(d, None)
        if s and not s['piped']:
            for n, t in s['sites']:
                self.found.append((n, 'argument', t))

    def settle_pending(self, c):
        """A statement left pending at a newline ends unless the next code character is a pipe."""
        s = self.stmts.get(self.code_depth())
        if s and s['end']:
            if c == '|':
                s['end'] = False
            else:
                self.end_stmt()


def judge(text, background=False):
    w = Walk()
    lines = text.split('\n')
    for idx, line in enumerate(lines):
        n = idx + 1
        if w.heredocs:
            strip, word = w.heredocs[0]
            if (line.lstrip('\t') if strip else line) == word:
                w.heredocs.pop(0)
            continue
        in_code_at_start = w.quote is None and (not w.stack or w.stack[-1] != 'dq')
        if in_code_at_start and not w.stack:
            m = FUNC.match(line)
            if m:
                w.func, w.func_bg, w.func_wait = m.group(1), [], False
            elif line.startswith('}') and w.func is not None:
                if background and not w.func_wait:
                    for bn, bt in w.func_bg:
                        w.found.append((bn, 'background', bt))
                w.func = None
        if in_code_at_start and line.strip() and not line.lstrip().startswith('#'):
            w.code_lines += 1
        walk_line(w, line, n, background)
        # A newline ends a statement at the current depth unless it continues.
        if w.quote is None and (not w.stack or w.stack[-1] not in ('dq', 'brace')):
            stripped = re.sub(r"\s+#.*$", "", line).rstrip()
            if not (stripped.endswith('\\') or stripped.endswith('|') or stripped.endswith('&&')
                    or stripped.endswith('||')):
                s = w.stmts.get(w.code_depth())
                if s:
                    s['end'] = True
    for d in sorted(list(w.stmts.keys()), reverse=True):
        w.end_stmt(d)
    # One line per site: a command with two process substitutions is one site.
    return sorted(set(w.found)), w.code_lines


def walk_line(w, line, n, background):
    i, L = 0, len(line)
    text = line.strip()
    while i < L:
        c = line[i]
        top = w.stack[-1] if w.stack else None
        if w.quote == "'":
            if c == "'":
                w.quote = None
            i += 1
            continue
        if w.quote == "$'":
            if c == '\\':
                i += 2
                continue
            if c == "'":
                w.quote = None
            i += 1
            continue
        if top == 'dq':
            if c == '\\':
                i += 2
                continue
            if c == '"':
                w.stack.pop()
            elif line.startswith('$(', i):
                w.stack.append('cs')
                i += 2
                continue
            elif line.startswith('${', i):
                w.stack.append('brace')
                i += 2
                continue
            i += 1
            continue
        # Code (or the inside of ${ }).
        if c == '\\':
            i += 2
            continue
        if c == "'":
            w.quote = "$'" if i > 0 and line[i - 1] == '$' else "'"
            i += 1
            continue
        if c == '"':
            w.stack.append('dq')
            i += 1
            continue
        if top == 'brace':
            if c == '}':
                w.stack.pop()
            elif line.startswith('$(', i):
                w.stack.append('cs')
                i += 2
                continue
            elif line.startswith('${', i):
                w.stack.append('brace')
                i += 2
                continue
            i += 1
            continue
        if c == '#' and (i == 0 or line[i - 1] in ' \t;(|&'):
            break
        if c in ' \t':
            i += 1
            continue
        w.settle_pending(c)
        if line.startswith('<<', i) and not line.startswith('<<<', i) and (i == 0 or line[i - 1] != '<'):
            m = HEREDOC.match(line, i)
            if m:
                w.heredocs.append((m.group(1) == '-', m.group(3)))
                i = m.end()
                continue
        if line.startswith('<<<', i):
            i += 3
            continue
        if line.startswith('$(', i):
            w.stack.append('cs')
            i += 2
            continue
        if line.startswith('${', i):
            w.stack.append('brace')
            i += 2
            continue
        if (c == '<' or c == '>') and line.startswith('(', i + 1):
            before = line[:i].rstrip()
            redirect = c == '<' and re.search(r"(^|[^<])<$", before) is not None
            if redirect:
                w.found.append((n, 'redirect', text))
            elif not w.enclosed():
                w.stmt()['sites'].append((n, text))
            w.stack.append('ps')
            i += 2
            continue
        if c == '(':
            w.stack.append('par')
            i += 1
            continue
        if c == ')':
            if top in ('cs', 'ps', 'par'):
                w.end_stmt()
                w.stack.pop()
            i += 1
            continue
        if c == '|':
            if line.startswith('||', i):
                w.end_stmt()
                i += 2
                continue
            w.stmt()['piped'] = True
            i += 1
            continue
        if c == ';':
            w.end_stmt()
            i += 2 if line.startswith(';;', i) else 1
            continue
        if c == '&':
            if line.startswith('&&', i):
                w.end_stmt()
                i += 2
                continue
            prev = line[i - 1] if i > 0 else ''
            nxt = line[i + 1] if i + 1 < L else ''
            if prev not in '<>' and nxt != '>':
                if w.func is not None:
                    w.func_bg.append((n, text))
                elif background:
                    w.found.append((n, 'background', text))
                w.end_stmt()
            i += 1
            continue
        m = WORD.match(line, i)
        if m:
            word = m.group(0)
            boundary = i == 0 or not (line[i - 1].isalnum() or line[i - 1] in '_-./$')
            if boundary and word == 'case' and CMDPOS.search(line[:i]):
                w.stack.append('case')
            elif boundary and word == 'esac' and 'case' in w.stack:
                while w.stack and w.stack[-1] != 'case':
                    w.stack.pop()
                if w.stack:
                    w.stack.pop()
            elif boundary and word == 'wait':
                w.func_wait = True
            i = m.end()
            continue
        i += 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    ap.add_argument('--background', action='store_true')
    ap.add_argument('--count', action='store_true')
    args = ap.parse_args()
    any_found = False
    files = 0
    code = 0
    for rel in io.TextIOWrapper(sys.stdin.buffer, encoding='utf-8', errors='replace').read().split('\n'):
        rel = rel.strip()
        if not rel:
            continue
        try:
            with open(os.path.join(args.root, rel), encoding='utf-8', errors='replace') as fh:
                text = fh.read()
        except OSError as e:
            print('%s: could not be read (%s)' % (rel, e))
            any_found = True
            continue
        files += 1
        found, lines = judge(text, background=args.background)
        code += lines
        for n, kind, t in found:
            any_found = True
            print('%s:%d: %s: %s' % (rel, n, kind, t))
    if args.count:
        print('judged %d files, %d code lines' % (files, code))
    return 1 if any_found else 0


if __name__ == '__main__':
    sys.exit(main())
