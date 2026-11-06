#!/usr/bin/env python3
"""Hand the test gate's docs only reader every Python docstring line as a comment (claude-config#2247).

    git diff -U1000000 ... -- file.py | python3 lib/py-docstring-lines.py

Reads a git diff of Python files on stdin and writes the same diff back, line for line, with each
added or removed line that lies wholly inside a docstring rewritten as a '#' comment ('+#' or '-#'
followed by the line as it was). require-tests-before-push.sh pipes a Python file's diff through this
before diff_docs_only, which already reads a '#' line as documentation, so a reworded docstring
passes the way a reworded comment does and no second classifier exists.

WHAT IS A DOCSTRING. What Python itself calls one: the first statement of a module, class or
function (async ones too) when that statement is a plain string, so `ast` finds it, not a pattern.
A line counts only when it lies inside that string from end to end: the string's first line has
nothing but indentation before it, and its last line nothing after it but blanks or a '#' comment.
So a docstring on its def's own line, one followed by '; x = 1', an ordinary string literal, a
string assigned to a name, a string statement that is not the first, a bytes string and an f-string
all stay code. And a file whose own code names __doc__ (a usage message or an argparse description
cut from its docstring) runs on its docstrings, so in that file none of them counts. A read from
another file, or by a tool such as pydoc or doctest, cannot be seen from here and is not caught.

FAILS CLOSED. Each file's two images (the lines before the change and after it) are rebuilt from its
diff, which the gate reads with the whole file around it, and both are parsed. Anything this cannot
place for certain leaves that file's diff exactly as git gave it, so the reader judges it as before:
a hunk not starting at the file's first line, more than one hunk, a hunk whose line counts do not
match, a line holding a lone carriage return, text that is not UTF-8, and either image failing to
parse. Any error at all writes the whole input back unchanged, in one write at the end, so a run that
dies part way cannot hand the reader a shortened diff (the gate also compares the line counts).
"""
import ast
import re
import sys
import warnings

HUNK = re.compile(rb"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
OWNERS = (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)


def docstring_lines(lines):
    """The 1 based numbers of the lines lying wholly inside a docstring, or None if it cannot say."""
    try:
        text = [line.decode("utf-8", "strict") for line in lines]  # refusing is the decision
    except UnicodeDecodeError:
        return None
    if any("\r" in line.rstrip("\r") for line in text):
        return None  # a lone carriage return is a line break to Python and not to git
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        try:
            tree = ast.parse("\n".join(text) + "\n")
        except Exception:  # SyntaxError, ValueError (a NUL), RecursionError: none can be placed
            return None
    for node in ast.walk(tree):
        if (isinstance(node, ast.Name) and node.id == "__doc__") or \
                (isinstance(node, ast.Attribute) and node.attr == "__doc__"):
            return set()  # the file runs on its docstrings, so none of them is only documentation
    found = set()
    for node in ast.walk(tree):
        if not isinstance(node, OWNERS) or not node.body:
            continue
        first = node.body[0]
        if not (isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant)
                and isinstance(first.value.value, str)):
            continue
        s = first.value
        if s.end_lineno is None or s.end_col_offset is None:
            return None
        # ast's columns count UTF-8 bytes.
        before = text[s.lineno - 1].encode("utf-8")[:s.col_offset].decode("utf-8", "replace")
        after = text[s.end_lineno - 1].encode("utf-8")[s.end_col_offset:].decode("utf-8", "replace")
        after = after.strip(" \t\f\r")
        if before.strip(" \t\f") or (after and not after.startswith("#")):
            continue  # code shares a line with the string, so none of its lines is trusted
        found.update(range(s.lineno, s.end_lineno + 1))
    return found


def rewrite_file(section):
    """One file's diff lines (each without its newline), rewritten, or as given if not placeable."""
    hunks = [i for i, line in enumerate(section) if line.startswith(b"@@")]
    if len(hunks) != 1:
        return section
    m = HUNK.match(section[hunks[0]])
    if not m:
        return section
    old_start, old_count = int(m.group(1)), int(m.group(2) if m.group(2) is not None else 1)
    new_start, new_count = int(m.group(3)), int(m.group(4) if m.group(4) is not None else 1)
    if old_start != (1 if old_count else 0) or new_start != (1 if new_count else 0):
        return section
    old, new, where = [], [], []  # where: for each body line, (image, number) or None
    for line in section[hunks[0] + 1:]:
        tag, body = line[:1], line[1:]
        if tag == b"\\":
            where.append(None)  # "\ No newline at end of file"
        elif tag == b"-":
            old.append(body)
            where.append(("old", len(old)))
        elif tag == b"+":
            new.append(body)
            where.append(("new", len(new)))
        elif tag in (b" ", b""):
            old.append(body)
            new.append(body)
            where.append(None)
        else:
            return section
    if len(old) != old_count or len(new) != new_count:
        return section
    old_doc, new_doc = docstring_lines(old), docstring_lines(new)
    if old_doc is None or new_doc is None:
        return section
    out = section[:hunks[0] + 1]
    for line, place in zip(section[hunks[0] + 1:], where):
        if place and place[1] in (old_doc if place[0] == "old" else new_doc):
            line = line[:1] + b"#" + line[1:]
        out.append(line)
    return out


def rewrite(data):
    lines = data.split(b"\n")
    tail = lines.pop() if lines and lines[-1] == b"" else None
    out, section = [], []
    for line in lines:
        if line.startswith(b"diff --git ") and section:
            out.extend(rewrite_file(section))
            section = []
        section.append(line)
    if section:
        out.extend(rewrite_file(section))
    if len(out) != len(lines):
        return data
    return b"\n".join(out) + (b"\n" if tail is not None else b"")


def main():
    data = sys.stdin.buffer.read()
    try:
        result = rewrite(data)
    except Exception:
        result = data
    sys.stdout.buffer.write(result)
    sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
