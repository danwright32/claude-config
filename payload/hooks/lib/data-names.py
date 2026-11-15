"""Two readings for the Slack drafts gate (claude-config#2913): an endpoint a program only compares
against or lists, told from one it sends to; and the directory a script's cd moves to when the
target is built from $0 or BASH_SOURCE.

Names held only as data. Dan decided on 2026-11-14 (#2913, "Teach the gate", no exemption list) that
the gate should tell a Slack posting address that is only compared or listed, such as a refusal list
of hosts in a guard's own code, from one that is sent to, and keep refusing anything it cannot
classify. Before this, any file in a script's reach naming an endpoint refused the script, so every
script, probe and single test reaching a guard that names the host in order to refuse it was refused.

A name is held only as data where it sits in a string that is an element of a list (a JavaScript
array literal, a Python list, tuple or set), an operand of a comparison (===, ==, !=, a switch or
match case, Python's in), or the argument of a test that only compares (includes, startsWith,
startswith, has and the like); in a regular expression's pattern; or, in JavaScript, in a comment.
Anything else (a call handed it, a value assigned, returned or kept in an object, a template or an
f-string building a URL) cannot be classified, and refuses as before.

A list or a comparison can still feed a send (`fetch("https://" + HOSTS[0])`, or
`if (url.includes(HOST)) fetch(url)`), and so can what a program prints or writes, so a name held
only as data clears nothing by itself. It is let through only where nothing in the program that holds
it can send a request, run code or write a file, by the gate's own reading of what a script can do
(acts_body, writing counted); in JavaScript, where no member is reached by a computed name (other
than a number or one string written out) and nothing names the global object that way (JS_SINK); and
where what the program prints reaches only the terminal or a filter (output_stays). The program is the
script, every module it reaches, and every other piece of code run in the same process (a loader, a
test runner, a module NODE_OPTIONS preloads, which is refused outright since that code is judged
apart from it). A package the gate does not read counts as able to send, as everywhere else in the
gate.

The directory after cd. A suite run by a relative path that moves with `cd "$(dirname "$0")/.."` and
then sources `"$(dirname "${BASH_SOURCE[0]}")/lib/..."` was refused as a path the gate could not work
out, because the shared reader keeps a cd target holding $ as written. Such a target is now worked out
where it is built only from $0, BASH_SOURCE and $(dirname ...), with at most one $(cd ... && pwd) or
$(pwd) at its start, read from the directory the cd ran in, as bash reads it.

slack_drafts_only_gate.py loads this file and gives its Judge the class make() returns as a base, as it
does lib/code-loaders.py's, so the methods use the Judge's own readers (acts_body, sh_word, sh_close,
sh_source_var, shell).
"""
import ast
import os
import re

# The methods that test a string or a collection against what they are handed, and send it nowhere.
PY_TESTS = frozenset({"startswith", "endswith", "find", "rfind", "index", "rindex", "count", "__contains__"})
# A JavaScript test of the same kind, ending just before the string it is handed (`?.` too).
JS_TESTS = re.compile(r"(?:\?\s*)?\.\s*(?:includes|startsWith|endsWith|indexOf|lastIndexOf|has)\s*\(\Z")
JS_COMPARE = ("===", "!==", "==", "!=")
# What can stand before a [ that opens an array literal rather than indexes: punctuation, or a keyword.
JS_ARRAY_AFTER = set("([{,=:;!&|?+-*/%<>~^")
JS_ARRAY_WORDS = frozenset({"return", "in", "of", "case", "typeof", "void", "yield", "await", "throw", "else",
                            "do", "delete", "instanceof"})
# A substitution in a cd target whose value depends on the directory it runs in.
CWD_BOUND = re.compile(r"(?<![\w$])(?:pwd|cd)(?![\w-])")
# A member reached by a computed name (`fsp["write" + "File"]`, `process[k]`, `H[i]`): whatever the
# index, a number or one string written out aside, it can name a method that writes, sends or runs,
# which the gate's reading of what a script does looks for by name only. Read with strings blanked
# to their quotes, so `t["x"]` is the string case; the global object reached that way is JS_SINK.
JS_COMPUTED = re.compile(r"([\w$]+|[)\]])\s*(?:\?\.\s*)?\[(?!\s*(?:\d+|(['\"`])\s*\2)?\s*\])")
# What carries a program's output past the terminal in a shell text: a command or process
# substitution, and a redirection to anything but /dev/null or another descriptor.
SH_CAPTURES = re.compile(r"\$\(|`|[<>]\(")
SH_OUT_FILE = re.compile(r"(?<!>)>>?\|?(?![>|])(?![ \t]*(?:&[\d-]|/dev/null(?![\w/.-])))")
# The programs a pipe may hand a program's output to and still leave it only on the terminal: each
# prints a part of what it reads and runs, writes and sends nothing.
PIPE_SAFE = frozenset({"head", "tail", "grep", "egrep", "fgrep", "wc", "cut", "tr", "cat", "nl", "column"})


def py_held_spans(tree, span_of):
    """The (start, end) of each Python string constant held only as data (module docstring), its
    quotes included, as span_of gives a node's."""
    out = []
    for node in ast.walk(tree):
        if isinstance(node, (ast.List, ast.Tuple, ast.Set)):
            found = node.elts
        elif isinstance(node, ast.Compare):
            found = [node.left] + node.comparators
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr in PY_TESTS:
            found = node.args
        elif isinstance(node, ast.MatchValue):
            found = [node.value]
        else:
            continue
        for c in found:
            if isinstance(c, ast.Constant) and isinstance(c.value, (str, bytes)) and c.end_lineno:
                out.append(span_of(c))
    return out


def js_opener(code, quoted, k):
    """The index of the bracket that encloses index k of JavaScript code, stepping back over every
    bracket pair closed before it and over string and regex text; None at the top level."""
    depth = 0
    while k >= 0:
        if not quoted[k]:
            c = code[k]
            if c in ")]}":
                depth += 1
            elif c in "([{":
                if not depth:
                    return k
                depth -= 1
        k -= 1
    return None


def js_held(text, code, quoted, a, b):
    """Whether the endpoint at text[a:b] is held only as data (module docstring). code and quoted are
    js_scan's: the text with comments blanked, and 1 for string text and 2 for regex text."""
    if not code[a:b].strip():
        return True  # in a comment, which js_scan blanked
    kinds = set(quoted[a:b])
    if kinds == {2}:
        return True  # a regex literal's pattern looks for it
    if kinds != {1}:
        return False
    s, e = a, b
    while s and quoted[s - 1] == 1:
        s -= 1
    while e < len(quoted) and quoted[e] == 1:
        e += 1
    lit = text[s:e]
    # One whole string: a quote at each end, and no ${...} in a template, which builds a value.
    if len(lit) < 2 or lit[0] not in "'\"`" or lit[-1] != lit[0] or (lit[0] == "`" and "${" in lit):
        return False
    before, after = code[:s].rstrip(), code[e:].lstrip()
    if before.endswith(JS_COMPARE) or after.startswith(JS_COMPARE):
        return True
    if JS_TESTS.search(before) and after[:1] in (")", ","):
        return True
    if re.search(r"(?<![\w$.])case\Z", before) and after[:1] == ":":
        return True
    if before[-1:] in ("[", ",") and after[:1] in (",", "]"):
        k = js_opener(code, quoted, s - 1)
        if k is not None and code[k] == "[":
            lead = code[:k].rstrip()
            word = re.search(r"(?<![\w$.])[A-Za-z_$][\w$]*\Z", lead)
            # An array literal, not an index into something (`t["x"]`, `f()["x"]`).
            return not lead or lead[-1] in JS_ARRAY_AFTER or (word is not None and word.group(0) in JS_ARRAY_WORDS)
    return False


def js_computed(text, js_scan):
    """JS_COMPUTED's first hit in a JavaScript text's code, its strings blanked to their quotes and its
    regex literals to spaces, that is not an array literal after a keyword (`return [a, b]`)."""
    code, quoted = js_scan(text)
    out = list(code)
    for k, q in enumerate(quoted):
        if q == 2 or (q == 1 and code[k] not in "'\"`"):
            out[k] = " "
    code = "".join(out)
    for m in JS_COMPUTED.finditer(code):
        if m.group(1) not in JS_ARRAY_WORDS:
            return m
    return None


def make(marker, js_scan, py_marker, js_sink):
    """The base class for the gate's Judge (module docstring). marker is its MARKER, js_scan its
    reading of a JavaScript file's comments and strings, py_marker its reading of a Python file,
    which fills a list it is handed with the first name held only as data, and js_sink its JS_SINK."""

    def js_marks(text):
        """(the first endpoint in JavaScript text not held only as data, or None; where there is none,
        the first one held only as data, or None)."""
        hits = list(marker.finditer(text))
        if not hits:
            return None, None
        code, quoted = js_scan(text)
        held = None
        for m in hits:
            if not js_held(text, code, quoted, m.start(), m.end()):
                return m, None
            held = held or m
        return None, held

    class DataNames:
        def marks(self, text, kind, docs_read=False):
            """(the first endpoint the text uses some way other than as data, or None; where there is
            none, the first one it holds only as data, or None), for a script of kind "js" or "py".
            Any other text is read whole, as before."""
            if kind == "py":
                held = []
                return py_marker(text, docs_read, held), (held[0] if held else None)
            if kind == "js":
                return js_marks(text)
            return marker.search(text), None

        def held_names(self):
            """The names this call let through as held only as data, as (where, name), in order."""
            return self.__dict__.setdefault("_held_names", [])

        def held_reach(self, start, origin, root, body, kind, held):
            """The reason a name held only as data (held, as (where, name)) may still be sent, or None
            once it cannot be, and the name is noted as let through (held_names). It cannot be where
            nothing in the program (start, its file origin, None for inline code, run from root) can
            send a request, run code or write a file (acts_body, and in JavaScript no member reached by a
            computed name, reach_sinks), and what the program prints reaches
            only the terminal (output_stays)."""
            where, name = held
            acts = self.acts_body(body, origin, root, kind) or self.reach_sinks(start, origin, root, body, kind)
            if not acts and not self.output_stays():
                acts = ("prints into a pipe, a substitution or a file, which can hand what it prints to "
                        "another command")
            if acts:
                return (f"{where.rstrip(',')}, which posts to Slack (it names {name}, held there only as data, "
                        f"compared or listed, but {start.rstrip(',')} {acts}, so it can send it)")
            self.held_names().append(held)
            return None

        def reach_sinks(self, start, origin, root, body, kind):
            """How a JavaScript program reaches what can send, run code or write by a computed name, as
            a phrase, or None: the global object (js_sink, read with comments, which can only refuse
            more) or any member by a computed index (js_computed), in its text or any module it reaches."""
            if kind != "js":
                return None
            texts = [(start, body)] + [(via, found) for why, via, _, found in self.modules(start, origin, root, body, kind)
                                       if not why]
            for label, text in texts:
                hit = js_sink.search(text) or js_computed(text, js_scan)
                if hit:
                    return (f"can reach what sends a request, runs code or writes a file by a computed name ({label}: "
                            f"{hit.group(0).strip()})")
            return None

        def output_stays(self):
            """Whether what the command being read prints reaches only the terminal: its text, and
            each text that ran it, holds no command or process substitution, no redirection to a
            file, and no pipe into anything but PIPE_SAFE. Judged over the whole text, whichever
            command printed, which can only refuse more."""
            scope = self.shell
            while scope:
                text, cwd = scope["text"], scope["cwd"]
                if text and (SH_CAPTURES.search(text) or SH_OUT_FILE.search(text)):
                    return False
                if "|" in text:
                    try:
                        cmds, parts = self.parsed(text, cwd)
                    except self.sw.Unreadable:
                        return False
                    for k, part in enumerate(parts):
                        if part["how"] == "|":
                            words = self.words_of(self.rest_of(cmds[k + 1][1])[0]) if k + 1 < len(cmds) else []
                            if not words or os.path.basename(words[0]) not in PIPE_SAFE:
                                return False
                scope = scope.get("parent")
            return True

        def held_together(self, before, code, sources):
            """The reason code run in the same process as a name let through as data since before (the
            length of held_names then) may send it, or None (every_file). code is every_file's list of
            (label, how it can act); sources gives each piece of that code read from text, as (label,
            its file or None, the folder it runs from, its text, its kind), for reach_sinks."""
            names = self.held_names()
            if len(names) <= before:
                return None
            where, name = names[before]
            found = [(label, acts_of()) for label, acts_of in code]
            found += [(label, self.reach_sinks(label, origin, root, text, kind))
                      for label, origin, root, text, kind in sources()]
            for label, acts in found:
                if acts:
                    return (f"{where.rstrip(',')}, which posts to Slack (it names {name}, held there only as data, "
                            f"compared or listed, but {label.rstrip(',')}, run in the same program, {acts}, so it "
                            "can send it)")
            return None

        def settled_dir(self, d):
            """d, the directory a command runs in, with a cd target the shared reader kept as written
            (it holds $) worked out where that is certain (module docstring), else d as it is.

            The reader joins each relative target to the directory before it, quotes dropped, so d is
            that directory (absolute, holding no $) and then the targets. Each is read as one unquoted
            word, so a value holding white space or a pattern is not worked out. $0 is the script that
            runs (sh_source_var), and no other variable is taken, since one may change after the cd. A
            $(pwd) or $(cd ... && pwd) is read from the directory the first such cd ran in, so only one,
            at the start, is taken. CDPATH, where set, may send a relative target elsewhere."""
            k = d.find("$")
            if k < 0 or "`" in d:
                return d
            prefix, word = d[:k], d[k:]
            if not prefix.startswith("/") or not prefix.endswith("/"):
                return d
            rest = word
            if word.startswith("$(") and not word.startswith("$(dirname"):
                j = self.sh_close(word, 2)
                if j is None:
                    return d
                rest = word[j + 1:]
            if CWD_BOUND.search(rest):
                return d
            here = prefix.rstrip("/") or "/"
            value, splits = self.sh_word(word, here, lambda n: self.sh_source_var(n) if n == "0" else None,
                                         self.shell["script"], False)
            if value is None or splits:
                return d
            if os.environ.get("CDPATH") and not value.startswith(("/", ".")):
                return d
            return os.path.normpath(os.path.join(here, value))

    return DataNames
