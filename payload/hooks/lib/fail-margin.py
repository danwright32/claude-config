#!/usr/bin/env python3
"""Suites whose failure message goes on at the left margin, where a full run never shows it (claude-config#2916).

The runner (hooks/run-all-tests.sh) prints a failing suite's FAIL line and, under it, only the
lines indented further than that FAIL line; a line back at the margin, or a blank one, ends the
message (claude-config#253). That rule is what stops it swallowing a chatty suite's whole output.
So a suite that writes what it found at the margin under its FAIL loses exactly that from a full
run's report: the run says the suite failed, and never says what it found. #2854 found this in
test-lib-bytecode-importers.sh, whose report stopped at "these do not:", and #2916 found the same
shape in 22 more suites, 57 messages in all, on 2026-11-13. This finds the next one (L613).

WHAT IT LOOKS FOR, in a suite file (a test-*.sh): a FAIL message written over more than one line of
the source, inside one double quoted string, whose next line would print
  - at the margin (no space before it, or a tab, which the runner does not count as one),
  - blank, which ends the message as the margin does, or
  - as a value expanded on a line of its own (`  $found`, `${hits}`, `$(cat "$f")`), which indents
    the value's FIRST line only: the rest of a list of findings lands at the margin all the same.
A FAIL message is a double quoted string whose text starts with FAIL, or an argument of a function
the suite defines that prints one (its own `check`, `check_eq` or `bad`), directly or through
another such function, when that argument is one the function prints: `check deny "$1" "$payload"`
prints its first two and never the payload, so a fixture handed as the third is not judged. The
FAIL line's own indent is read from the function, and a line must be indented further than it.
What indents line by line is accepted wherever it stands:
  - a command substitution piping through `sed 's/^/  /'` (any run of spaces, any line range, so
    `sed '2,$s/^/  /'` too);
  - a function whose every definition pipes what it prints through that sed, or that prints nothing
    of its own and hands everything to functions that do, so none of its calls is judged; this is
    how the 22 suites #2916 found were mended, which also covers a value of several lines handed in
    from a variable the source cannot see into;
  - a list the suite builds already indented, every assignment to it empty or appending lines that
    each start with spaces (`offenders="$offenders  $rel<newline>"`), standing first on the line.
A continuation that is only the closing quote is not judged: what follows it is the helper's own
closing bracket.
Not looked for, because the source cannot say: a value of several lines expanded in the middle of a
line (`"found: $hits"`) or handed to a function that does not indent, and a separate echo after the
FAIL line. Comments, single quoted text and heredoc bodies (the fixtures a suite writes, never its
own report) are skipped, the heredocs as lib/shell_code_lines.py reads them, the one reading of
where a heredoc ends that the whole tree scans share. Nor is anything outside a test-*.sh: a helper
the suites source would be a different reading of where a FAIL helper lives.

Usage: `<the files to judge, one per line, relative to --root> | fail-margin.py --root <checkout>`.
Prints `<path>:<line>: <what is wrong>` for each, and exits 1 when there is any.
"""
import argparse
import io
import os
import re
import shlex
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shell_code_lines import read_lines  # noqa: E402

SUITE = re.compile(r'(^|/)test-[^/]*\.sh$')
# A sed that puts spaces before every line: s/^/  /, with any delimiter after s.
INDENT_SED = re.compile(r"""sed\b[^|;]*?s(.)\^\1 +\1""")
FUNC_DEF = re.compile(r'^(\s*)(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)\s*\{?')
WORD_START = set(' \t\n;&|()<>')
ASSIGN = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=')
DECLARE = {'local', 'export', 'declare', 'readonly', 'typeset'}
RESETS = {'then', 'do', 'else', 'elif', 'if', 'while', 'until', '!', '{', 'time'}


class Str:
    """One double quoted string at the level of a command: where it opened, which command it is an
    argument of, and the source lines on which its own text (not a nested substitution) begins."""

    def __init__(self, line, cmd, arg):
        self.line = line
        self.cmd = cmd
        self.arg = arg
        self.assign = None    # the variable this string is assigned to, when it is
        self.text = []        # the string's own characters, nested parts written as \0
        self.starts = []      # (line number, offset into self.text) for each new line of its text


def lex(text, heredoc_lines):
    """Every double quoted string the shell would see, with the command word it belongs to.

    A small shell reader: single quotes, $'...', comments, $(...), backticks and ${...} are followed
    far enough to know when a double quote is a real one. Strings nested inside a command
    substitution inside a string are read too, as strings of that inner command. A heredoc's body
    is passed over whole, by the line numbers lib/shell_code_lines.py gives it (heredoc_lines), the
    one reading of where a heredoc ends that every whole tree scan shares."""
    out = []
    i, n, line = 0, len(text), 1
    # Each frame: [kind, data]. kind is 'code' (data: dict with paren depth, the command word, the
    # word being read, the end it waits for) or 'dq' (data: Str).
    stack = [['code', {'depth': 0, 'cmd': None, 'word': '', 'end': None}]]

    def end_word(c):
        w = c['word']
        c['word'] = ''
        if not w:
            return
        if c['cmd'] is None:
            if w in RESETS or ASSIGN.match(w):
                return
            c['cmd'] = w
        else:
            c['nargs'] = c.get('nargs', 0) + 1

    while i < n:
        kind, data = stack[-1]
        ch = text[i]
        if kind == 'dq':
            s = data
            if ch == '\\' and i + 1 < n:
                if text[i + 1] == '\n':
                    line += 1
                    i += 2
                    continue
                s.text.append(text[i:i + 2])
                i += 2
                continue
            if ch == '"':
                stack.pop()
                out.append(s)
                i += 1
                if stack[-1][0] == 'code':
                    stack[-1][1]['word'] += '"'
                continue
            if ch == '$' and text.startswith('$((', i):
                stack.append(['code', {'depth': 0, 'cmd': None, 'word': '', 'end': '))', 'arith': True, 'owner': s, 'from': i}])
                s.text.append('\0')
                i += 3
                continue
            if ch == '$' and text.startswith('$(', i):
                stack.append(['code', {'depth': 0, 'cmd': None, 'word': '', 'end': ')', 'owner': s, 'from': i}])
                s.text.append('\0')
                i += 2
                continue
            if ch == '$' and text.startswith('${', i):
                stack.append(['param', {'owner': s}])
                s.text.append('${')
                i += 2
                continue
            if ch == '`':
                stack.append(['code', {'depth': 0, 'cmd': None, 'word': '', 'end': '`', 'owner': s, 'from': i}])
                s.text.append('\0')
                i += 1
                continue
            if ch == '\n':
                line += 1
                s.text.append('\n')
                s.starts.append((line, len(s.text)))
                i += 1
                continue
            s.text.append(ch)
            i += 1
            continue
        if kind == 'param':
            # ${...}. Directly inside a string its text is the string's own (the word of a
            # ${found:+...} prints), so it is kept there, new lines and all.
            owner = data.get('owner')
            if ch == '}':
                stack.pop()
                if owner is not None:
                    owner.text.append('}')
                i += 1
                continue
            if ch == '\\':
                if owner is not None:
                    owner.text.append(text[i:i + 2])
                line += text.count('\n', i, i + 2)
                i += 2
                continue
            if ch == '"':
                stack.append(['dq', Str(line, None, 0)])
                i += 1
                continue
            if ch == '$' and text.startswith('${', i):
                stack.append(['param', {}])
                i += 2
                continue
            if ch == '$' and text.startswith('$(', i):
                stack.append(['code', {'depth': 0, 'cmd': None, 'word': '', 'end': ')'}])
                i += 2
                continue
            if ch == '\n':
                line += 1
                if owner is not None:
                    owner.text.append('\n')
                    owner.starts.append((line, len(owner.text)))
                i += 1
                continue
            if owner is None and ch == "'":
                j = text.find("'", i + 1)
                j = n - 1 if j < 0 else j
                line += text.count('\n', i, j)
                i = j + 1
                continue
            if owner is not None:
                owner.text.append(ch)
            i += 1
            continue
        # code
        c = data
        if c['end'] == '`' and ch == '`':
            stack.pop()
            i += 1
            _closed(stack, c, text, i)
            continue
        if ch == '\\' and i + 1 < n:
            if text[i + 1] == '\n':
                line += 1
            else:
                c['word'] += text[i:i + 2]
            i += 2
            continue
        if ch == '#' and (i == 0 or text[i - 1] in WORD_START) and not c['word']:
            j = text.find('\n', i)
            i = n if j < 0 else j
            continue
        if ch == "'":
            dollar = c['word'].endswith('$')
            j = i + 1
            while j < n and text[j] != "'":
                if dollar and text[j] == '\\':
                    j += 1
                j += 1
            line += text.count('\n', i, j)
            c['word'] += 'Q'
            i = j + 1
            continue
        if ch == '"':
            # The command this string is an argument of, and which argument: none when the string is
            # the command word itself, or the value of an assignment.
            if c['cmd'] is None or c['cmd'] in DECLARE:
                st = Str(line, None, 0)
                m = re.fullmatch(r'([A-Za-z_][A-Za-z0-9_]*)\+?=', c['word'])
                st.assign = m.group(1) if m else None
                stack.append(['dq', st])
            else:
                stack.append(['dq', Str(line, c['cmd'], c.get('nargs', 0) + 1)])
            i += 1
            continue
        if ch == '$' and text.startswith('$((', i):
            stack.append(['code', {'depth': 0, 'cmd': None, 'word': '', 'end': '))', 'arith': True}])
            c['word'] += '$'
            i += 3
            continue
        if ch == '$' and text.startswith('$(', i):
            stack.append(['code', {'depth': 0, 'cmd': None, 'word': '', 'end': ')'}])
            c['word'] += '$'
            i += 2
            continue
        if ch == '$' and text.startswith('${', i):
            stack.append(['param', {}])
            c['word'] += '$'
            i += 2
            continue
        if ch == '`':
            stack.append(['code', {'depth': 0, 'cmd': None, 'word': '', 'end': '`'}])
            i += 1
            continue
        if c.get('arith'):
            if ch == '(':
                c['depth'] += 1
            elif ch == ')':
                if c['depth'] == 0 and text.startswith('))', i):
                    stack.pop()
                    i += 2
                    _closed(stack, c, text, i)
                    continue
                c['depth'] -= 1
            elif ch == '\n':
                line += 1
            i += 1
            continue
        if ch == '\n':
            end_word(c)
            c['cmd'] = None
            c['nargs'] = 0
            line += 1
            i += 1
            while line in heredoc_lines and i < n:
                j = text.find('\n', i)
                i = n if j < 0 else j + 1
                line += 1
            continue
        if ch in ' \t':
            end_word(c)
            i += 1
            continue
        if ch in ';&|':
            end_word(c)
            c['cmd'] = None
            c['nargs'] = 0
            i += 1
            continue
        if ch == '(':
            end_word(c)
            c['depth'] += 1
            c['cmd'] = None
            c['nargs'] = 0
            i += 1
            continue
        if ch == ')':
            if c['end'] == ')' and c['depth'] == 0:
                stack.pop()
                i += 1
                _closed(stack, c, text, i)
                continue
            end_word(c)
            c['depth'] = max(0, c['depth'] - 1)
            i += 1
            continue
        c['word'] += ch
        i += 1
    return out


def _closed(stack, frame, text, i):
    """A substitution inside a string closed: keep its source, so an indenting sed can be seen."""
    owner = frame.get('owner')
    if owner is not None:
        owner.text[-1] = '\0' + text[frame['from']:i] + '\0'


def fail_helpers(lines):
    """The functions a suite defines that print a FAIL line.

    {name: (the FAIL line's indent, the arguments it prints, whether it indents them itself)}. The
    arguments printed are the positional parameters named on any echo or printf in its body, or on a
    call to another such function, since under a FAIL those lines are part of the message too."""
    bodies = {}
    k = 0
    while k < len(lines):
        m = FUNC_DEF.match(lines[k])
        if not m or not re.search(r'\(\s*\)', lines[k]):
            k += 1
            continue
        name, ind = m.group(2), m.group(1)
        if lines[k].rstrip().endswith('}'):
            bodies.setdefault(name, []).append(lines[k][m.end():])
            k += 1
            continue
        body = [lines[k][m.end():]]
        k += 1
        while k < len(lines) and not re.match(re.escape(ind) + r'\}\s*(#.*)?$', lines[k]):
            body.append(lines[k])
            k += 1
        bodies.setdefault(name, []).append('\n'.join(body))
        k += 1
    def printed(stmt):
        if re.search(r'\$[@*]|\$\{[@*]', stmt):
            return set(range(1, 10))
        return {int(x) for x in re.findall(r'\$\{?([1-9])', stmt)}

    def words(stmt):
        try:
            return shlex.split(stmt, comments=False, posix=True)
        except ValueError:
            return stmt.split()

    def calls_of(body, names):
        return [h for h in names if re.search(r'(^|[\s;&|{(])' + re.escape(h) + r'(\s|$)', body)]

    # Which functions print a FAIL line, directly or through another that does.
    direct = {name: [len(d) for b in bs for d in re.findall(r"""(?:echo|printf)\s+(?:-[a-z]+\s+)*["']( *)FAIL""", b)]
              for name, bs in bodies.items()}
    names = {name for name in bodies if direct[name]}
    while True:
        more = {name for name, bs in bodies.items() if name not in names and calls_of('\n'.join(bs), names)}
        if not more:
            break
        names |= more
    # Which of their arguments reach the output, the FAIL line's indent, and whether all of it is
    # indented line by line: by an indenting sed in every definition, or by printing nothing of its
    # own and handing everything to functions that indent. Taken to a fixed point.
    helpers = {name: (0, set(), all(INDENT_SED.search(b) for b in bodies[name])) for name in names}
    for _ in range(len(names) + 1):
        changed = False
        for name in names:
            body = '\n'.join(bodies[name])
            calls = calls_of(body, names)
            args = set()
            own = set()
            for stmt in re.split(r'[;\n]|&&|\|\||\b(?:then|else)\b', body):
                bare = stmt.strip()
                # A line printed beside the FAIL: one carrying it, or an echo or printf of its own
                # that goes to the output (not into a pipe, a file or a substitution).
                if 'FAIL' in bare or (re.match(r'(echo|printf)\s', bare) and not re.search(r'[|>]', bare)):
                    own |= printed(bare)
                    continue
                w = words(bare)
                if w and w[0] in names:
                    for j in helpers[w[0]][1]:
                        if j < len(w):
                            args |= printed(w[j])
            args |= own
            indent = min(direct[name] + [helpers[h][0] for h in calls if h != name] or [0])
            indents = all(INDENT_SED.search(b) for b in bodies[name]) or (
                not direct[name] and not own and all(helpers[h][2] for h in calls if h != name))
            new = (indent, args, indents)
            if new != helpers[name]:
                helpers[name] = new
                changed = True
        if not changed:
            break
    return helpers


def indents(content):
    """Whether a line opens with a command substitution that puts spaces before every line it prints."""
    parts = content.split('\0')
    return content.startswith('\0') and len(parts) >= 3 and bool(INDENT_SED.search(parts[1]))


def indented_lists(text, strings):
    """The variables a suite builds as a list already indented line by line, which may stand at the
    margin of a FAIL message because every line they hold starts with spaces.

    A variable counts when every assignment to it is empty (`V=""`, `V=`) or appends to itself one or
    more lines, each starting with spaces (`V="$V  $rel<newline>"`). Any other assignment (a
    substitution, a value of its own) and it does not, since the source cannot say what it holds."""
    good, bad = set(), set()
    for st in strings:
        if not st.assign:
            continue
        v = st.assign
        body = ''.join(st.text)
        if body == '':
            good.add(v)
            continue
        m = re.match(r'\$(?:\{%s\}|%s(?![A-Za-z0-9_]))( +)' % (v, v), body)
        lines_after = body.split('\n')[1:]
        if m and all(x == '' or x.startswith(' ') or indents(x) for x in lines_after):
            good.add(v)
        else:
            bad.add(v)
    # An assignment that is no double quoted string: empty, or something the source cannot judge.
    for m in re.finditer(r'(?m)(?:^|[\s;&|(])(?:(?:local|export|declare|readonly|typeset)\s+)?([A-Za-z_][A-Za-z0-9_]*)\+?=(?!")(\S*)', text):
        v, val = m.group(1), m.group(2)
        if val in ('', "''", ';') or val.startswith(';'):
            continue
        bad.add(v)
    return good - bad


def indented_lead(content, listed):
    """Whether a line opens with lists already indented line by line, and goes on (if it does) after
    a space: each such list ends in a new line, so what follows starts a line of its own."""
    m = re.match(r'((?:\$(?:\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*))+)(.*)$', content)
    if not m:
        return False
    names = re.findall(r'[A-Za-z_][A-Za-z0-9_]*', m.group(1))
    return all(n in listed for n in names) and (m.group(2) == '' or m.group(2).startswith(' '))


def judge(text):
    heredoc_lines = {n for n, _, kind, _, _ in read_lines(text) if kind in ('heredoc', 'end')}
    strings = lex(text, heredoc_lines)
    lines = ['' if n + 1 in heredoc_lines else t for n, t in enumerate(text.split('\n'))]
    helpers = fail_helpers(lines)
    listed = indented_lists(text, strings)
    found = []
    for s in strings:
        if not s.starts:
            continue
        body = ''.join(s.text)
        own = re.match(r' *FAIL', body)
        if own:
            indent = len(own.group(0)) - 4
        elif s.cmd in helpers and s.arg in helpers[s.cmd][1] and not helpers[s.cmd][2]:
            indent = helpers[s.cmd][0]
        else:
            continue
        for ln, off in s.starts:
            rest = ''.join(s.text[off:])
            first = rest.split('\n', 1)[0]
            spaces = len(first) - len(first.lstrip(' '))
            content = first[spaces:]
            if content == '' and off == len(s.text):
                continue  # only the closing quote: the helper's own bracket follows
            if indents(content):
                continue
            if content == '':
                found.append((ln, 'a blank line inside a FAIL message ends what a full run shows of it'))
            elif spaces <= indent and not indented_lead(content, listed):
                found.append((ln, 'a FAIL message goes on at the margin here, and a full run shows nothing from this line on'))
            elif re.fullmatch(r'(\$[A-Za-z_][A-Za-z0-9_]*|\$\{[^}]*\}|\0[^\0]*\0)\}?', content):
                found.append((ln, 'a value expanded on a line of its own is indented on its first line only, and the rest of it lands at the margin'))
    return sorted(set(found))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    args = ap.parse_args()
    any_found = False
    unread = []
    for rel in io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace").read().split('\n'):
        rel = rel.strip()
        if not rel or not SUITE.search(rel):
            continue
        path = os.path.join(args.root, rel)
        try:
            with open(path, encoding='utf-8', errors='replace') as fh:
                text = fh.read()
        except OSError as e:
            unread.append('%s: %s' % (rel, e))
            continue
        for n, t in judge(text):
            any_found = True
            print('%s:%d: %s' % (rel, n, t))
    for u in unread:
        print('fail-margin: could not read %s' % u, file=sys.stderr)
    return 1 if any_found or unread else 0


if __name__ == '__main__':
    sys.exit(main())
