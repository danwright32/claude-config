"""The python3 -c programs in a shell file, read from its raw bytes (claude-config#2066).

The one reader both scans of inline programs use: test-python-c-ascii.sh, which fails on a byte
outside ASCII in any of them, and test-python-bad-bytes.sh, which judges how each handles text it
cannot decode. Before this they each had their own, and the second one took only the first program
on a line.

programs(b) finds every python3 (or python) with any flags then -c, alone or ending a cluster such
as -Ic, and reads the next shell word the way the shell joins it: single quoted runs, double quoted
runs, a backslash escape, and the \\"...\\" a program takes inside an outer double quoted string,
until an unquoted space or operator. A match on a shell comment line is not a program. A match
inside the text of a program already read still is: when a word is misread, as the text of a printf
that builds a probe can be, skipping what it covers would pass whatever real programs sit there
unread, while reading one too many only reads a string as a program.

word(b, i) is that shell word reader on its own, for a caller reading another shell string, such as
a variable holding a program.

Callers run under python3 -I, so they put this directory on sys.path themselves.
"""
import re

# python3 (or python), any flags, then -c (alone or ending a cluster such as -Ic), then a space.
START = re.compile(rb"(?<![A-Za-z0-9_./-])python3?(?:[ \t]+-[A-Za-z]+)*?[ \t]+-[A-Za-z]*c[ \t]+")
ENDS = b" \t\n;|&()<>"
# Inside double quotes a backslash escapes only these, and before a newline joins the lines.
DQ_ESCAPED = b'$`"\\'


def _dq_body(b, i, j):
    """The bytes between double quotes at i and j as the shell reads them."""
    out, k = bytearray(), i
    while k < j:
        c = b[k:k + 1]
        if c == b"\\" and k + 1 < j:
            nxt = b[k + 1:k + 2]
            if nxt == b"\n":
                k += 2
                continue
            if nxt in DQ_ESCAPED:
                out += nxt
                k += 2
                continue
        out += c
        k += 1
    return bytes(out)


def word(b, i):
    """The shell word starting at i, as the bytes between its quotes, or None when a quote never
    closes. Returns (bytes or None, the index just past it)."""
    out, n, nested = bytearray(), len(b), False
    while i < n:
        c = b[i:i + 1]
        if nested and c == b'"':
            break   # a word read as \"...\" sits inside an outer double quoted string, which ends here
        if c == b"'":
            j = b.find(b"'", i + 1)
            if j < 0:
                return None, i
            out += b[i + 1:j]
            i = j + 1
        elif b.startswith(b'\\"', i):
            j = b.find(b'\\"', i + 2)
            if j < 0:
                return None, i
            out += b[i + 2:j]
            i, nested = j + 2, True
        elif c == b'"':
            j = i + 1
            while j < n and b[j:j + 1] != b'"':
                j += 2 if b[j:j + 1] == b"\\" else 1
            if j >= n:
                return None, i
            out += _dq_body(b, i + 1, j)
            i = j + 1
        elif c == b"\\":
            out += b[i + 1:i + 2]
            i += 2
        elif c in ENDS:
            break
        else:
            out += c
            i += 1
    return bytes(out), i


def _on_comment_line(b, k):
    """Whether the byte at k sits on a line that is a shell comment: optional space, then #."""
    head = b[b.rfind(b"\n", 0, k) + 1:k]
    return head.lstrip(b" \t").startswith(b"#")


def programs(b):
    """Each python3 -c program in the bytes b, in order, as (line, start, end, program): the line the
    call starts on, the index the program's word starts at, the index just past it, and the program
    as bytes, or None when its quote never closes (end is then the start)."""
    found = []
    for m in START.finditer(b):
        if _on_comment_line(b, m.start()):
            continue
        prog, end = word(b, m.end())
        found.append((b.count(b"\n", 0, m.start()) + 1, m.end(), end, prog))
    return found
