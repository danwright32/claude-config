#!/usr/bin/env python3
"""TypeScript and TSX source read the way the mod scans need it: which characters are code, which
are a string, a regex literal, JSX text or a comment. One reader for every scan that has to tell a
comment from code (tools/check-mod-shared-parts.sh, tools/check-mod-dependencies.sh and the contract
checks in tests/test-mods.sh), rather than a stripper per script that each misreads something of
its own (L613). The one it replaces took a regex literal holding // or /* for a comment, and JSX
text's // or apostrophe for a comment or a quote (#735); the shared parts scan dropped any line
that merely started like a comment (#732).

Not a parser: it follows strings, template literals (with their ${} code), regex literals, JSX
elements, their text and attributes, and comments, which is all a comment stripper and a bracket
matcher need. Where a slash or a < could start either, it decides by what came before it, as the
language does: after an expression (a name, a number, a closing bracket) it is division or less
than, anywhere else a regex literal or a JSX element. A TSX generic arrow (<T,>, <T extends U>) is
not an element. Known to misread: a type position generic call signature in a .tsx file written as
<T>(...), which no mod writes.

As a command:
  ts_source.py strip-hooks <mods dir> <out dir>
      Copies every mod's hooks/ source into <out dir>/<mod>/hooks/ with its comments blanked, line
      for line, so a grep over the copy names the same file and line. Exit 1 when a file cannot be
      read, naming it.
  ts_source.py unscreened <hooks dir>
      Prints, one per line, each tool.call hook in that folder that answers the call with a result
      and never asks $.modkit.screen itself, as <file>:<line>; a hook whose body is a named function
      that cannot be found is printed as ?<file>:<line>.
"""
import os
import re
import sys

CODE, STRING, COMMENT, REGEX, TEXT = 0, 1, 2, 3, 4

# After these words an expression starts, so a slash there opens a regex literal and a < an element.
EXPRESSION_KEYWORDS = {"return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await"}
IDENT = re.compile(r"[A-Za-z_$][\w$]*")
NUMBER = re.compile(r"\d[\w.]*")
TAG = re.compile(r"[A-Za-z_$][\w$.:-]*")
SOURCE = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts")


def is_jsx(path):
    return path.endswith((".tsx", ".jsx"))


class _Scan:
    def __init__(self, text, jsx):
        self.t = text
        self.n = len(text)
        self.jsx = jsx
        self.kind = bytearray(self.n)

    def mark(self, a, b, k):
        b = min(b, self.n)
        if b > a:
            self.kind[a:b] = bytes([k]) * (b - a)

    def comment_at(self, i):
        """The end of a comment starting at i, or None when none starts there."""
        if self.t.startswith("//", i):
            j = self.t.find("\n", i)
            j = self.n if j < 0 else j
        elif self.t.startswith("/*", i):
            j = self.t.find("*/", i + 2)
            j = self.n if j < 0 else j + 2
        else:
            return None
        self.mark(i, j, COMMENT)
        return j

    def code(self, i, close=False):
        """Code from i: to the end, or with close, past the } that closes the ${ or { it began in."""
        t, n = self.t, self.n
        expr = True
        depth = 0
        while i < n:
            c = t[i]
            if c.isspace():
                i += 1
                continue
            j = self.comment_at(i)
            if j is not None:
                i = j
                continue
            if c in "'\"":
                i = self.string(i)
                expr = False
            elif c == "`":
                i = self.template(i)
                expr = False
            elif c == "/" and expr:
                i = self.regex(i)
                expr = False
            elif c == "<" and self.jsx and expr and self.opens_element(i):
                i = self.element(i)
                expr = False
            elif c in "{([":
                depth += c == "{"
                i += 1
                expr = True
            elif c == "}":
                if depth == 0 and close:
                    return i + 1
                depth = max(0, depth - 1)
                i += 1
                expr = True
            elif c in ")]":
                i += 1
                expr = False
            elif IDENT.match(t, i):
                m = IDENT.match(t, i)
                i = m.end()
                expr = m.group() in EXPRESSION_KEYWORDS
            elif NUMBER.match(t, i):
                i = NUMBER.match(t, i).end()
                expr = False
            elif t.startswith("++", i) or t.startswith("--", i):
                i += 2
                expr = False
            else:
                i += 1
                expr = True
        return i

    def string(self, i):
        t, n, q = self.t, self.n, self.t[i]
        j = i + 1
        while j < n and t[j] != q and t[j] != "\n":
            j += 2 if t[j] == "\\" else 1
        j = min(j + 1, n) if j < n and t[j] == q else j
        self.mark(i, j, STRING)
        return j

    def template(self, i):
        t, n = self.t, self.n
        start, j = i, i + 1
        while j < n:
            if t[j] == "\\":
                j += 2
            elif t[j] == "`":
                self.mark(start, j + 1, STRING)
                return j + 1
            elif t.startswith("${", j):
                self.mark(start, j + 2, STRING)
                j = self.code(j + 2, close=True)
                # The } that closes the ${ is the template's, as its ${ is, so brackets stay paired.
                start = j - 1
            else:
                j += 1
        self.mark(start, n, STRING)
        return n

    def regex(self, i):
        t, n = self.t, self.n
        j, in_class = i + 1, False
        while j < n and t[j] != "\n":
            c = t[j]
            if c == "\\":
                j += 2
                continue
            if in_class:
                in_class = c != "]"
            elif c == "[":
                in_class = True
            elif c == "/":
                j += 1
                while j < n and t[j].isalpha():
                    j += 1
                self.mark(i, j, REGEX)
                return j
            j += 1
        # No closing slash on its line: the division the heuristic misread, so it is code.
        return i + 1

    def opens_element(self, i):
        t = self.t
        if t.startswith("<>", i):
            return True
        m = TAG.match(t, i + 1)
        if not m:
            return False
        rest = t[m.end():].lstrip(" \t")
        # <T,> and <T extends U> open a generic arrow function in a .tsx file, never an element.
        return not (rest.startswith(",") or re.match(r"extends\b", rest))

    def element(self, i):
        """A JSX element from its <, to past its closing tag or its />."""
        t, n = self.t, self.n
        i += 1
        if i < n and t[i] == ">":
            i += 1
        else:
            i = TAG.match(t, i).end()
            while i < n:
                c = t[i]
                if c.isspace():
                    i += 1
                    continue
                if t.startswith("/>", i):
                    return i + 2
                if c == ">":
                    i += 1
                    break
                j = self.comment_at(i)
                if j is not None:
                    i = j
                elif c == "{":
                    i = self.code(i + 1, close=True)
                elif c in "'\"":
                    # An attribute's string may run over lines and has no escapes.
                    k = t.find(c, i + 1)
                    k = n if k < 0 else k + 1
                    self.mark(i, k, STRING)
                    i = k
                else:
                    i += 1
            else:
                return i
        while i < n:
            if t.startswith("</", i):
                k = t.find(">", i)
                return n if k < 0 else k + 1
            c = t[i]
            if c == "<":
                i = self.element(i)
            elif c == "{":
                i = self.code(i + 1, close=True)
            else:
                self.kind[i] = TEXT
                i += 1
        return i


def kinds(text, jsx=False):
    """For each character of text, what it is: CODE, STRING, COMMENT, REGEX or TEXT (JSX text)."""
    s = _Scan(text, jsx)
    s.code(0)
    return s.kind


def strip_comments(text, jsx=False):
    """text with every comment blanked to spaces, its line breaks kept, so a line keeps its number."""
    k = kinds(text, jsx)
    return "".join(" " if k[i] == COMMENT and c != "\n" else c for i, c in enumerate(text))


def code_only(text, jsx=False):
    """text with everything but code blanked: strings, regex literals, JSX text and comments."""
    k = kinds(text, jsx)
    return "".join(c if k[i] == CODE or c == "\n" else " " for i, c in enumerate(text))


def closing(code, i):
    """In code (as code_only gives it), the index past the bracket that closes the one at i, or None."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = []
    for j in range(i, len(code)):
        c = code[j]
        if c in pairs:
            stack.append(pairs[c])
        elif c in ")]}":
            if not stack or stack.pop() != c:
                return None
            if not stack:
                return j + 1
    return None


def block_after(text, pattern):
    """The body of the brace block that the first match of pattern opens (the match ending at its {),
    to its own closing brace, comments blanked; None when there is no match or the block never closes."""
    clean = strip_comments(text)
    code = code_only(text)
    # Matched against the text with comments blanked and strings kept, since a key is a string; its
    # { must be code, and the block is closed by brackets in code alone.
    m = re.search(pattern, clean)
    if not m or not code[: m.end()].endswith("{"):
        return None
    end = closing(code, m.end() - 1)
    return None if end is None else clean[m.end() : end - 1]


def object_members(type_text):
    """The top level members of an inline object type ("{ a: string; b: { c: number } }"), or None
    when the type is not one."""
    code = code_only(type_text)
    if not code.startswith("{"):
        return None
    end = closing(code, 0)
    return None if end is None else top_members(type_text[1 : end - 1])


def top_members(body):
    """The members standing at the top level of a type's body (comments already blanked), name to its
    type text with spacing collapsed; a member of a nested object type is never among them."""
    code = code_only(body)
    parts, depth, start = [], 0, 0
    for j, c in enumerate(code):
        if c in "{[(":
            depth += 1
        elif c in "}])":
            depth -= 1
        elif depth == 0 and c in ";\n":
            parts.append(body[start:j])
            start = j + 1
    parts.append(body[start:])
    members, last = {}, None
    for p in parts:
        s = " ".join(p.split())
        if not s:
            continue
        if last is not None and s[0] in "|&":
            members[last] = f"{members[last]} {s}"
            continue
        m = re.match(r"(?:readonly\s+)?([A-Za-z_$][\w$]*|'[^']*'|\"[^\"]*\")\??\s*:\s*(.*)$", s)
        if m:
            last = m.group(1).strip("'\"")
            members[last] = m.group(2)
    return members


def _sources(folder):
    for base, dirs, files in os.walk(folder):
        dirs.sort()
        for name in sorted(files):
            if name.endswith(SOURCE):
                yield os.path.join(base, name)


def tool_call_hooks(text, jsx=False):
    """Each tool.call hook a module registers: (line, the hook's code as code_only gives it), its body
    read where a named function is defined; None for the code where that definition is not found."""
    code = code_only(text, jsx)
    raw_kinds = kinds(text, jsx)
    hooks = []
    for m in re.finditer(r"\bon\s*\(", code):
        # The event name is a string, so it is read from the text, not the code view that blanks it.
        name = re.match(r"\s*(['\"`])tool\.call\1", text[m.end() :])
        if not name or raw_kinds[m.start()] != CODE:
            continue
        open_at = m.end() - 1
        end = closing(code, open_at)
        line = code.count("\n", 0, m.start()) + 1
        if end is None:
            hooks.append((line, None))
            continue
        span = code[open_at:end]
        handler = re.search(r",\s*([A-Za-z_$][\w$]*)\s*\)$", span)
        if "=>" in span or re.search(r"\bfunction\b", span) or not handler:
            hooks.append((line, span))
            continue
        hooks.append((line, _definition(code, handler.group(1))))
    return hooks


def _definition(code, name):
    """The code of the function named name, from its definition to the end of its body, or None."""
    m = re.search(r"\b(?:const|let|var)\s+" + re.escape(name) + r"\b[^=]*=(?!=)|\bfunction\s+" + re.escape(name) + r"\b", code)
    if not m:
        return None
    i, n = m.end(), len(code)
    arrow = False
    while i < n:
        c = code[i]
        if code.startswith("=>", i):
            arrow = True
            i += 2
            continue
        if c in "([":
            end = closing(code, i)
            if end is None:
                return None
            i = end
            continue
        if c == "{":
            # The body: after the arrow, or a function declaration's after its parameters.
            if arrow or code[m.start() :].startswith("function") or "function" in code[m.end() : i]:
                end = closing(code, i)
                return None if end is None else code[m.start() : end]
            end = closing(code, i)
            if end is None:
                return None
            i = end
            continue
        if arrow and not c.isspace():
            # An expression body runs to the end of its statement.
            stop = re.search(r"[;\n]", code[i:])
            return code[m.start() : i + (stop.start() if stop else n - i)]
        i += 1
    return None


ANSWERS = re.compile(r"\{\s*result\s*:|^\s*result\s*:", re.M)


def unscreened(folder):
    out = []
    for path in _sources(folder):
        if path.endswith(".d.ts") or ".test." in os.path.basename(path):
            continue
        with open(path, errors="replace") as f:
            text = f.read()
        rel = os.path.relpath(path, folder)
        for line, body in tool_call_hooks(text, is_jsx(path)):
            if body is None:
                out.append(f"?{rel}:{line}")
            elif ANSWERS.search(body) and "$.modkit.screen(" not in body:
                out.append(f"{rel}:{line}")
    return out


def strip_hooks(mods, dest):
    failed = 0
    for entry in sorted(os.listdir(mods)):
        hooks = os.path.join(mods, entry, "hooks")
        if not os.path.isfile(os.path.join(mods, entry, ".claude-plugin", "plugin.json")) or not os.path.isdir(hooks):
            continue
        for path in _sources(hooks):
            target = os.path.join(dest, entry, "hooks", os.path.relpath(path, hooks))
            try:
                with open(path) as f:
                    text = f.read()
            except (OSError, UnicodeDecodeError) as e:
                print(f"{entry}/hooks/{os.path.relpath(path, hooks)} cannot be read ({e})")
                failed = 1
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "w") as f:
                f.write(strip_comments(text, is_jsx(path)))
    return failed


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "strip-hooks":
        sys.exit(strip_hooks(sys.argv[2], sys.argv[3]))
    if len(sys.argv) == 3 and sys.argv[1] == "unscreened":
        print("\n".join(unscreened(sys.argv[2])))
        sys.exit(0)
    print("usage: ts_source.py strip-hooks <mods dir> <out dir> | unscreened <hooks dir>", file=sys.stderr)
    sys.exit(2)
