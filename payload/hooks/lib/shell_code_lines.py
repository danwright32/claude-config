"""The lines of a shell file that are its code, for the whole tree scans of suites (claude-config#1663).

Four scans read shell files: hand-rolled-wait.py (#1679), hand-rolled-checkout.py (#1663) and
heredoc-in-substitution.py (#1690) for a hand rolled or fragile shape, and scan-subshell-globals.py
for where each function begins and ends (#2063). Each has to tell the file's own code from the text
it carries as data: a multi line quoted string is another hook's input written as a fixture, and a
comment is prose about the shape, often the very prose explaining why it is banned. One reader, so
the four cannot come to disagree about which lines are code (L613).

Enough of the shell's quoting is followed to do that: single, double and $'...' quotes, a `$( ... )`
opening a fresh quoting context even inside double quotes, a plain `( ... )` inside one, a comment,
and a heredoc. Not a parser: a `case` pattern's `)` inside a substitution, for one, is read as
closing it.

code_lines(text) yields (line_number, line) for every line that is neither a comment nor begins
inside a quoted string. A line inside a multi line `$( ... )` is code and is yielded. A heredoc's
body is yielded too, since a stand in a suite writes through one is shell, but its quotes are not
followed, so an apostrophe in a heredoc's prose cannot carry a quote past the heredoc's end.

code_lines(text, with_heredocs=True) adds a third item: the heredoc operators the line opens as
code, each (strip_tabs, word, inside_substitution), so heredoc-in-substitution.py reads the same
quoting as the rest. heredoc_body_lines(text) names the lines that are a heredoc's body, from the
same walk, so hand-rolled-wait.py can tell a stand in's own commands from the suite's (#1743).

read_lines(text) is the walk both of those are built on, and yields every line rather than only the
code ones: its kind (code, quoted, heredoc body or heredoc end) and its bare code characters, with
quoted text, comments and escapes left out. scan-subshell-globals.py counts a function's braces on
those bare characters, so a brace inside a string or a heredoc never ends a function (#2063).
"""
import re

OP = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_]\w*)\2")


def scan(line, frames, keep=None, parens=None):
    """Follows the quoting of one line. `frames` is the stack of quoting contexts the line starts in
    (the outermost first; each a quote state: None, "'", "$'" or '"'), and is updated in place.
    Returns the heredoc operators the line opens as code: (strip_tabs, word, inside_substitution).
    Given a list as `keep`, appends to it every character of the line read as code, so quoted text,
    a comment and an escaped character are left out (claude-config#2063).

    `parens`, one count per frame, is how many plain `(` are open in each, a subshell, an array or
    an arithmetic group, so its `)` closes it rather than the `$(` around it. Without it the `)` of
    a `(set -f; ...)` inside a multi line `$( { ... } )` closed the substitution, and everything
    after was read as inside the double quotes around it (claude-config#2063). Kept across lines by
    the caller that passes it; without one it is counted within the line alone."""
    if parens is None:
        parens = [0] * len(frames)
    ops = []
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        st = frames[-1]
        if st is None:
            if c == '#' and (i == 0 or line[i - 1] in ' \t;('):
                break
            if c == '\\':
                i += 2
                continue
            if c == '<' and line.startswith('<<', i) and not line.startswith('<<<', i) and (i == 0 or line[i - 1] != '<'):
                m = OP.match(line, i)
                if m:
                    ops.append((m.group(1) == '-', m.group(3), len(frames) > 1))
                    i = m.end()
                    continue
            if c == '$' and line.startswith('$(', i) and not line.startswith('$((', i):
                frames.append(None)
                parens.append(0)
                i += 2
                continue
            if keep is not None and c not in "'\"":
                keep.append(c)
            if c == '(':
                parens[-1] += 1
            elif c == ')' and parens[-1] > 0:
                parens[-1] -= 1
            elif c == ')' and len(frames) > 1:
                frames.pop()
                parens.pop()
            elif c == "'":
                frames[-1] = "$'" if i > 0 and line[i - 1] == '$' else "'"
            elif c == '"':
                frames[-1] = '"'
        elif st == "'":
            if c == "'":
                frames[-1] = None
        else:
            if c == '\\':
                i += 2
                continue
            if st == '"' and line.startswith('$(', i) and not line.startswith('$((', i):
                frames.append(None)
                parens.append(0)
                i += 2
                continue
            if (st == "$'" and c == "'") or (st == '"' and c == '"'):
                frames[-1] = None
        i += 1
    return ops


def read_lines(text):
    """Every line of the file, in one walk, as (line_number, line, kind, bare, heredoc operators it
    opens). kind is "heredoc" for a heredoc's body, "end" for the word closing one, "quoted" for a
    line that begins inside a quoted string, and "code" for any other. bare is the line's code alone:
    its quoted text, comment and escaped characters left out, and nothing at all of a heredoc's body
    or end. So a brace in bare is the shell's own, never one in a string the file carries as data
    (claude-config#2063, where one inside a python3 -c string ended a function at the end of the file)."""
    frames = [None]
    parens = [0]
    pending = []  # heredocs opened and not yet read: (strip_tabs, word)
    for i, line in enumerate(text.split('\n')):
        if pending:
            strip, word = pending[0]
            if (line.lstrip('\t') if strip else line) == word:
                pending.pop(0)
                yield (i + 1, line, "end", "", [])
            else:
                yield (i + 1, line, "heredoc", "", [])
            continue
        starts_quoted = frames[-1] is not None
        keep = []
        ops = scan(line, frames, keep, parens)
        pending.extend((s, w) for s, w, _ in ops)
        yield (i + 1, line, "quoted" if starts_quoted else "code", "".join(keep), ops)


def _walk(text):
    """Every code line as (line_number, line, heredoc operators it opens, whether it is a heredoc's
    body): the one walk code_lines and heredoc_body_lines both read."""
    for n, line, kind, _, ops in read_lines(text):
        if kind in ("end", "quoted") or line.lstrip().startswith('#'):
            continue
        yield (n, line, ops, kind == "heredoc")


def code_lines(text, with_heredocs=False):
    for n, line, ops, _ in _walk(text):
        yield (n, line, ops) if with_heredocs else (n, line)


def heredoc_body_lines(text):
    """The numbers of the code lines that are a heredoc's body: a stand in the file writes, whose
    commands are the stand in's own rather than the file's (claude-config#1743)."""
    return {n for n, _, _, body in _walk(text) if body}
