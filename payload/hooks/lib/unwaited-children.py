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

  background   (with --background only) a command put in the background with `&` that this shell
               never reaps: that child exits whenever it likes. claude-sync and the hooks are held
               to this (#1989), and so are the skills' and tools' own scripts (#2015); the suites are
               not judged on it. An `&` inside arithmetic, `$(( a & b ))` or `(( a & b ))`, is a
               bitwise and, never a job. A job passes when any of these holds:
                 - it is the last thing a `( ... )` subshell does, `( worker & )`: the subshell ends
                   at once, so the worker is the subshell's child, then launchd's, never this
                   shell's (measured by test-unwaited-children.sh). The remedy for a worker nobody
                   waits for;
                 - the subshell starting it sends both its stdout and its stderr to /dev/null,
                   `( worker & echo "$!" >> f ) >/dev/null 2>&1`: whatever that subshell writes after
                   the fork cannot reach a pipe;
                 - the statement straight after it keeps its pid (`p=$!`, `lane[$i]=$!`,
                   `inflight="$inflight $!"`) and the file has a `wait` naming that variable, or a
                   bare `wait`;
                 - it is in a function that calls `wait` (#1984's rule).
               What the last two cannot see is ORDER: a kept child that exits, or is killed, while
               this shell prints something before its `wait` is the hazard all the same. So every
               such job in the hooks, skills and tools carries, beside it, why nothing is written
               between its start and its reaping, and a kill is followed by the wait at once
               (pr-merge-quiz.sh, run-all-tests.sh, tools/load-window.sh,
               tools/measure-section-time.sh). A disowned job is not waited for by a bare `wait`, and `disown`
               never stops the SIGCHLD, so a disowned job passes only as a subshell's.

Enough of the shell is followed to know which text is code: single, double and $'...' quotes, a
comment, a backslash, a heredoc's body, and a stack of `$((`, `$(`, `<(`, `>(`, `(` and `${` so a
substitution is known to be open across lines. lib/shell_code_lines.py is the shared reader for
which LINES are code, but it keeps no stack of parentheses (a `)` closing a process substitution
reads there as closing the command substitution around it), and this question is about exactly
that, so the walk is its own. A `case` pattern's `)` is recognised by an open `case` and ignored.

Fixture text is told from code by that same grammar and nothing else, never by a file's name (#1989):
a suite quoting the shape for a scanner it tests, in a heredoc, a quoted string or a comment, has no
site, and the same text as code in a suite is one. A fixture that has to exist as a file is written
by its suite at run time, as every suite here does, so no shipped file holds the shape as data.

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
# Where `wait` is the command run, a test's included, so `echo wait` is no wait.
WAITPOS = re.compile(r"(^|[;&|({!]|\bthen|\bdo|\belse|\bif|\belif|\bwhile|\buntil)\s*$")
# The statement straight after a background job keeping its pid: `p=$!`, `local p=$!`,
# `lane[$i]=$!`, `inflight="$inflight $!"`.
KEEPS = re.compile(r"^(?:local\s+|declare\s+)?([A-Za-z_]\w*)(?:\[[^\]]*\])?\+?=(\"[^\"]*\"|\S*)")
REDIR = re.compile(r"(\d*)(&>>|&>|>>|>&|>)\s*(\S+)")
# Where a statement ends, for reading what follows a `)` or a `wait`.
STMT_END = re.compile(r";|\|\||&&|\||(?<![<>])&(?!>)|\)")


def stmt_rest(text):
    """The text up to the end of the statement it starts."""
    m = STMT_END.search(text)
    return text[:m.start()] if m else text


def silenced(rest):
    """True when the redirections after a subshell's `)` send both its stdout and stderr to /dev/null,
    read left to right as the shell applies them, so `2>&1 >/dev/null` leaves stderr on the pipe."""
    target = {1: 'pipe', 2: 'pipe'}
    for fd, op, word in REDIR.findall(stmt_rest(rest)):
        if op in ('&>', '&>>'):
            target[1] = target[2] = word
        elif op == '>&':
            src = int(fd) if fd else 1
            if word.isdigit() and int(word) in target:
                target[src] = target[int(word)]
            elif src in target:
                target[src] = word
        else:
            src = int(fd) if fd else 1
            if src in target:
                target[src] = word
    return target[1] == '/dev/null' and target[2] == '/dev/null'


class Walk:
    def __init__(self):
        self.stack = []          # frames: 'cs' $( , 'ps' <( >( , 'par' ( , 'brace' ${ , 'dq' " , 'case',
                                 # 'arith' $(( or ((, 'apar' a ( inside arithmetic
        self.ids = []            # an id per frame in stack, so a subshell's `)` can be matched to its `&`s
        self.next_id = 0
        self.quote = None        # None, "'" or "$'" while inside a single quoted string
        self.heredocs = []       # (strip_tabs, word) opened and not yet read
        self.stmts = {}          # depth -> {'piped': bool, 'sites': [(line, text)], 'end': bool}
        self.found = []          # (line, kind, text)
        self.func = None
        self.func_id = None
        self.func_count = 0
        self.func_wait = False
        self.func_waited = {}    # function id -> whether it calls wait anywhere
        self.bg = []             # background jobs: dicts read once the whole file has been walked
        self.silenced = set()    # ids of ( ) subshells whose stdout and stderr both go to /dev/null
        self.waits = []          # (names it waits for, whether it is a bare wait)
        self.code_mask = set()   # line numbers that start in code and hold some
        self.code_lines = 0

    def push(self, kind):
        self.stack.append(kind)
        self.next_id += 1
        self.ids.append(self.next_id)

    def pop(self):
        self.ids.pop()
        return self.stack.pop()

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
                w.func_count += 1
                w.func, w.func_id, w.func_wait = m.group(1), w.func_count, False
            elif line.startswith('}') and w.func is not None:
                w.func_waited[w.func_id] = w.func_wait
                w.func, w.func_id = None, None
        if in_code_at_start and line.strip() and not line.lstrip().startswith('#'):
            w.code_lines += 1
            w.code_mask.add(n)
        walk_line(w, line, n, background)
        # A newline ends a statement at the current depth unless it continues.
        if w.quote is None and (not w.stack or w.stack[-1] not in ('dq', 'brace', 'arith', 'apar')):
            stripped = re.sub(r"\s+#.*$", "", line).rstrip()
            if not (stripped.endswith('\\') or stripped.endswith('|') or stripped.endswith('&&')
                    or stripped.endswith('||')):
                s = w.stmts.get(w.code_depth())
                if s:
                    s['end'] = True
    for d in sorted(list(w.stmts.keys()), reverse=True):
        w.end_stmt(d)
    if w.func_id is not None:
        w.func_waited[w.func_id] = w.func_wait
    if background:
        judge_background(w, lines)
    # One line per site: a command with two process substitutions is one site.
    return sorted(set(w.found)), w.code_lines


def kept_name(w, lines, job):
    """The name the statement straight after a background job keeps its pid in, or None."""
    after = job['after'].strip()
    if not after or after.startswith('#'):
        after = ''
        for k in range(job['line'], len(lines)):   # lines[k] is line k + 1, the next one on
            if (k + 1) in w.code_mask:
                after = lines[k].strip()
                break
    m = KEEPS.match(after)
    if m and '$!' in m.group(2):
        return m.group(1)
    return None


def judge_background(w, lines):
    bare = any(b for _, b in w.waits)
    waited = set()
    for names, _ in w.waits:
        waited.update(names)
    for job in w.bg:
        # Started by a subshell that ends at once, or that can write to no pipe: never this shell's child,
        # or a child of a shell that cannot be writing into a pipe when it exits.
        if job['double'] or any(p in w.silenced for p in job['pars']):
            continue
        name = kept_name(w, lines, job)
        if name is not None and (bare or name in waited):
            continue
        if job['func'] is not None and w.func_waited.get(job['func']):
            continue
        w.found.append((job['line'], 'background', job['text']))


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
                w.pop()
            elif line.startswith('$((', i):
                w.push('arith')
                i += 3
                continue
            elif line.startswith('$(', i):
                w.push('cs')
                i += 2
                continue
            elif line.startswith('${', i):
                w.push('brace')
                i += 2
                continue
            i += 1
            continue
        # Arithmetic, `$(( ))` or `(( ))`: an `&` there is a bitwise and and a `<` a comparison, so
        # nothing in it is a job or a process substitution (#2015). Only a substitution, a `${` or a
        # double quote opens anything inside it; its own parentheses are counted until its `))`.
        if top in ('arith', 'apar'):
            if c == '\\':
                i += 2
                continue
            if c == '"':
                w.push('dq')
                i += 1
            elif line.startswith('$((', i):
                w.push('arith')
                i += 3
            elif line.startswith('$(', i):
                w.push('cs')
                i += 2
            elif line.startswith('${', i):
                w.push('brace')
                i += 2
            elif c == '(':
                w.push('apar')
                i += 1
            elif c == ')' and top == 'apar':
                w.pop()
                i += 1
            elif line.startswith('))', i):
                w.pop()
                i += 2
            else:
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
            w.push('dq')
            i += 1
            continue
        if top == 'brace':
            if c == '}':
                w.pop()
            elif line.startswith('$((', i):
                w.push('arith')
                i += 3
                continue
            elif line.startswith('$(', i):
                w.push('cs')
                i += 2
                continue
            elif line.startswith('${', i):
                w.push('brace')
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
        if line.startswith('$((', i):
            w.push('arith')
            i += 3
            continue
        if line.startswith('((', i) and CMDPOS.search(line[:i]):
            w.push('arith')
            i += 2
            continue
        if line.startswith('$(', i):
            w.push('cs')
            i += 2
            continue
        if line.startswith('${', i):
            w.push('brace')
            i += 2
            continue
        if (c == '<' or c == '>') and line.startswith('(', i + 1):
            before = line[:i].rstrip()
            redirect = c == '<' and re.search(r"(^|[^<])<$", before) is not None
            if redirect:
                w.found.append((n, 'redirect', text))
            elif not w.enclosed():
                w.stmt()['sites'].append((n, text))
            w.push('ps')
            i += 2
            continue
        if c == '(':
            w.push('par')
            i += 1
            continue
        if c == ')':
            if top in ('cs', 'ps', 'par'):
                w.end_stmt()
                if top == 'par' and silenced(line[i + 1:]):
                    w.silenced.add(w.ids[-1])
                w.pop()
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
                after = line[i + 1:]
                w.bg.append({
                    'line': n, 'text': text, 'after': after, 'func': w.func_id,
                    'pars': [fid for f, fid in zip(w.stack, w.ids) if f == 'par'],
                    # `( cmd & )`: the job is the last thing its subshell does.
                    'double': top == 'par' and after.lstrip().startswith(')'),
                })
                w.end_stmt()
            i += 1
            continue
        m = WORD.match(line, i)
        if m:
            word = m.group(0)
            boundary = i == 0 or not (line[i - 1].isalnum() or line[i - 1] in '_-./$')
            if boundary and word == 'case' and CMDPOS.search(line[:i]):
                w.push('case')
            elif boundary and word == 'esac' and 'case' in w.stack:
                while w.stack and w.stack[-1] != 'case':
                    w.pop()
                if w.stack:
                    w.pop()
            elif boundary and word == 'wait':
                w.func_wait = True
                if WAITPOS.search(line[:i]):
                    args = stmt_rest(line[m.end():])
                    names = set(re.findall(r"\$\{?#?([A-Za-z_]\w*)", args))
                    rest = REDIR.sub('', re.sub(r"\d*<\s*\S+", '', args)).strip()
                    w.waits.append((names, rest == ''))
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
