#!/usr/bin/env python3
"""shell-words.py: a command read the way the shell nests quotes and substitutions, for the merge
matcher in merge-target.sh (claude-config#788).

Written in python because the same scan in bash, a character at a time, took 55 seconds on a 26 KB
command (an issue body mentioning a merge), measured 2026-10-05; every merge gate runs it, and a
hook that slow is killed and the command goes unscreened.

  shell-words.py segments   stdin: a command (heredoc bodies already removed)
      prints each segment on its own line, cut at && || ; and newlines only where nothing is open.
      A newline INSIDE a segment (in a quoted string) becomes a space, so line readers stay whole.
      With anything left open at the end (an unclosed quote, as in `echo don't; gh pr merge 7`),
      the reading cannot be trusted and the plain cut at every separator is printed instead: a
      separator inside quotes then over cuts, which can only show the gates MORE merges (L42).
  shell-words.py split      stdin: one segment
      prints its leading NAME=value assignments, one per line, value with one layer of outermost
      quotes removed, then a line holding only the 0x1f separator, then the command that follows.

The context stack: " ' ` quotes, $( and ${ substitutions, and plain ( inside a substitution.
Inside a substitution quotes open afresh, so X="$(a "b c")" is one word.
"""
import sys


def segments(s):
    out, cur, stack = [], [], []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        nx = s[i + 1] if i + 1 < n else ""
        top = stack[-1] if stack else ""
        if top == "'":
            if c == "'":
                stack.pop()
            cur.append(c)
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            cur.append(c + nx)
            i += 2
            continue
        if not stack:
            if c + nx in ("&&", "||"):
                out.append("".join(cur))
                cur = []
                i += 2
                continue
            if c in ";\n":
                out.append("".join(cur))
                cur = []
                i += 1
                continue
        if c == '"':
            if top == '"':
                stack.pop()
            else:
                stack.append(c)
        elif c == "'":
            if top != '"':
                stack.append(c)
        elif c == "`":
            if top == "`":
                stack.pop()
            else:
                stack.append(c)
        elif c == "$" and nx in ("(", "{"):
            stack.append(nx)
            cur.append(c + nx)
            i += 2
            continue
        elif c == "(":
            if stack and top != '"':
                stack.append(c)
        elif c == ")":
            if top == "(":
                stack.pop()
        elif c == "}":
            if top == "{":
                stack.pop()
        cur.append(c)
        i += 1
    if stack:
        plain = s.replace("&&", "\n").replace("||", "\n").replace(";", "\n")
        return plain.split("\n")
    out.append("".join(cur))
    return [seg.replace("\n", " ") for seg in out]


def is_name(word):
    return bool(word) and (word[0].isalpha() or word[0] == "_") and all(ch.isalnum() or ch == "_" for ch in word)


def split(s):
    assigns = []
    s = s.lstrip()
    while True:
        eq = s.find("=")
        if eq <= 0 or not is_name(s[:eq]):
            break
        name, i, n, val, stack = s[:eq], eq + 1, len(s), [], []
        while i < n:
            c = s[i]
            nx = s[i + 1] if i + 1 < n else ""
            top = stack[-1] if stack else ""
            if top == "'":
                if c == "'":
                    stack.pop()
                    if stack:
                        val.append(c)
                else:
                    val.append(c)
                i += 1
                continue
            if c == "\\" and i + 1 < n:
                # Escaped: never opens, closes or ends anything. At the top level, or directly
                # inside the outermost double quote, the shell drops the backslash itself.
                val.append(nx if (not stack or stack == ['"']) else c + nx)
                i += 2
                continue
            if c == '"':
                if top == '"':
                    stack.pop()
                    if stack:
                        val.append(c)
                else:
                    if stack:
                        val.append(c)
                    stack.append(c)
            elif c == "'":
                if top == '"':
                    val.append(c)
                else:
                    if stack:
                        val.append(c)
                    stack.append(c)
            elif c == "`":
                if top == "`":
                    stack.pop()
                else:
                    stack.append(c)
                val.append(c)
            elif c == "$" and nx in ("(", "{"):
                stack.append(nx)
                val.append(c + nx)
                i += 2
                continue
            elif c == "(":
                if top != '"':
                    stack.append(c)
                val.append(c)
            elif c == ")":
                if top == "(":
                    stack.pop()
                val.append(c)
            elif c == "}":
                if top == "{":
                    stack.pop()
                val.append(c)
            elif c in " \t":
                if not stack:
                    break
                val.append(c)
            else:
                val.append(c)
            i += 1
        assigns.append(name + "=" + "".join(val))
        s = s[i:].lstrip()
    return assigns, s


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    data = sys.stdin.read()
    if mode == "segments":
        sys.stdout.write("".join(seg + "\n" for seg in segments(data)))
    elif mode == "split":
        if data.endswith("\n"):
            data = data[:-1]
        assigns, rest = split(data)
        sys.stdout.write("".join(a + "\n" for a in assigns) + "\x1f\n" + rest)
    else:
        sys.stderr.write("usage: shell-words.py segments|split < text\n")
        return 64
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
