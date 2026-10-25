"""The lines of a shell file that are its code, for the whole tree scans of suites (claude-config#1663).

Three scans read shell files for a hand rolled or fragile shape: hand-rolled-wait.py (#1679),
hand-rolled-checkout.py (#1663) and heredoc-in-substitution.py (#1690). Each has to tell the file's
own code from the text it carries as data: a multi line quoted string is another hook's input written
as a fixture, and a comment is prose about the shape, often the very prose explaining why it is
banned. One reader, so the three cannot come to disagree about which lines are code (L613).

Enough of the shell's quoting is followed to do that: single, double and $'...' quotes, a `$( ... )`
opening a fresh quoting context even inside double quotes, a comment, and a heredoc. Not a parser:
a `case` pattern's `)` inside a substitution, for one, is read as closing it.

code_lines(text) yields (line_number, line) for every line that is neither a comment nor begins
inside a quoted string. A line inside a multi line `$( ... )` is code and is yielded. A heredoc's
body is yielded too, since a stand in a suite writes through one is shell, but its quotes are not
followed, so an apostrophe in a heredoc's prose cannot carry a quote past the heredoc's end.

code_lines(text, with_heredocs=True) adds a third item: the heredoc operators the line opens as
code, each (strip_tabs, word, inside_substitution), so heredoc-in-substitution.py reads the same
quoting as the rest.
"""
import re

OP = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_]\w*)\2")


def scan(line, frames):
    """Follows the quoting of one line. `frames` is the stack of quoting contexts the line starts in
    (the outermost first; each a quote state: None, "'", "$'" or '"'), and is updated in place.
    Returns the heredoc operators the line opens as code: (strip_tabs, word, inside_substitution)."""
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
                i += 2
                continue
            if c == ')' and len(frames) > 1:
                frames.pop()
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
                i += 2
                continue
            if (st == "$'" and c == "'") or (st == '"' and c == '"'):
                frames[-1] = None
        i += 1
    return ops


def code_lines(text, with_heredocs=False):
    frames = [None]
    pending = []  # heredocs opened and not yet read: (strip_tabs, word)
    for i, line in enumerate(text.split('\n')):
        if pending:
            strip, word = pending[0]
            if (line.lstrip('\t') if strip else line) == word:
                pending.pop(0)
                continue
            if line.lstrip().startswith('#'):
                continue
            yield (i + 1, line, []) if with_heredocs else (i + 1, line)
            continue
        starts_quoted = frames[-1] is not None
        ops = scan(line, frames)
        pending.extend((s, w) for s, w, _ in ops)
        if starts_quoted or line.lstrip().startswith('#'):
            continue
        yield (i + 1, line, ops) if with_heredocs else (i + 1, line)
