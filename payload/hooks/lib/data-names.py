"""Three readings for the Slack drafts gate: an endpoint a program only compares against or lists,
told from one it sends to (claude-config#2913); the webhook's name where a file only declares it,
told from where it is read (claude-config#3050); and the directory a script's cd moves to when the
target is built from $0 or BASH_SOURCE (#2913).

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

The webhook's name only declared (claude-config#3050). The last thing the gate's MARKER looks for,
its group called name, is the variable name projects keep a webhook in, never an address: a file
posts through it only by reading what is kept under it and sending that. (It is not written out in
this file, nor as a string of its own in the gate's: a file doing so is one the gate refuses to
run.) On 2026-11-15 three runs of test files by name were refused in a work repository whose
worker has a Slack module, two of them for files that name the variable and read nothing: a fixture
holding it as a key, and a module naming it in a type. In JavaScript and TypeScript two uses read
nothing, and the name is left out of the file's judgement there, as code and as text a program is
handed (named_in):

- the key of an object literal, written as a name or as one quoted word, straight after the { or a
  comma inside it, set to null, to undefined, or to one string written out that is no address anyone
  receives at: plain words (letters, digits, spaces, _ and -), or a URL whose host is reserved for
  tests (.test, .example, .invalid, .localhost, example.com, example.net, example.org, localhost,
  127.0.0.1), and followed by a comma or the closing }, with no spread (...) after it in the same
  literal, which would set the key again. What a program finds under that key is what is written
  there. A flag (true, 1) is not one: in a query's selection it asks for what is stored;
- a member of an interface or a type alias whose body opens on the header's own line, the member
  starting its line or following { ; or a comma, typed only string, null, undefined, unknown or
  never. A type is erased before anything runs.

Every other use is judged as before and refuses: a member read (env.NAME), a
destructuring, a shorthand, a key set to a variable, a call, a template, a concatenation or any other
address, the name in a string or assigned to, and a type written anywhere else. The reading does not
ask what the program can do, as a name held as data does, because nothing is held: a file that only
declares the name gives a program nothing to send to but what the gate has read. A comment is still
held as data, not left out, since a line the gate misreads as a comment could hold a read. The other
names the gate looks for are addresses and are never read this way, and a module that reads the name
is refused wherever it is reached from.

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
# The webhook's name only declared (module docstring, #3050). A quoted key holds one plain word.
KEY_WORD = re.compile(r"[\w$-]+")
KEY_COLON = re.compile(r"\s*:\s*")
# What a key may be set to and still give a program nothing to send to: null or undefined, plain
# words, or a URL whose host is reserved for tests and documentation (RFC 2606, RFC 6761) or is
# this machine. A URL's host ends at the first / ? or #, so nothing after an @ can be one.
INERT_WORD = re.compile(r"(?:null|undefined)(?![\w$])")
INERT_TEXT = re.compile(r"[\w -]*")
TEST_HOST = (r"(?:[a-z0-9-]+\.)*(?:test|example|invalid|localhost)|(?:[a-z0-9-]+\.)*example\.(?:com|net|org)|"
             r"localhost|127\.0\.0\.1")
INERT_URL = re.compile(r"[a-z][a-z0-9+.-]*://(?:" + TEST_HOST + r")(?::\d+)?(?:[/?#]\S*)?", re.I)
# The line that opens an interface's or a type alias's body, up to its {, and a member's type that
# holds no name a value could have.
TYPE_HEAD = re.compile(r"[ \t]*(?:export[ \t]+)?(?:declare[ \t]+)?(?:interface[ \t]+[A-Za-z_$][\w$]*(?:<[^{}()=]*>)?"
                       r"(?:[ \t]+extends[ \t]+[\w$.,<> \t]+?)?|type[ \t]+[A-Za-z_$][\w$]*(?:<[^{}()=]*>)?[ \t]*=)[ \t]*")
TYPE_VALUE = r"(?:string|null|undefined|unknown|never)"
TYPE_MEMBER = re.compile(r"\s*\??\s*:\s*" + TYPE_VALUE + r"(?:\s*\|\s*" + TYPE_VALUE + r")*[ \t]*(?:[;,}]|\r?\n|\Z)")
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


# Import text a test only compares (claude-config#3146). Where a file a script's imports reach can run a
# string as code, the gate follows import text in every string (#2484), since a string reaches that
# code through names it cannot trace. One it can trace is the whole argument of a matcher on expect():
# the matcher compares it with what expect() was handed and hands it nowhere. The matchers read are
# those that only compare (Object.is, a substring or an element, a substring or a pattern), never
# toEqual and its kin, which hand both values to any equality tester the run adds.
JS_MATCHERS = re.compile(r"\.\s*(?:toBe|toContain|toMatch)\s*\(\Z")
JS_MATCHER_MODIFIERS = re.compile(r"\.\s*(?:not|resolves|rejects)\s*\Z")
# What can change what a matcher does with the value it is handed: expect.extend and equality testers,
# chai's plugins and its Assertion's methods, a spy, Reflect, and a prototype or a property defined
# (a String method a matcher calls). Read from a file's whole text, strings and comments included,
# which can only follow more.
JS_MATCHER_CHANGED = re.compile(r"\b(?:extend|addEqualityTesters|chai|Assertion|addMethod|overwriteMethod|"
                                r"addProperty|overwriteProperty|addChainableMethod|overwriteChainableMethod|"
                                r"defineProperty|defineProperties|spyOn|Reflect)\b|[Pp]rototype|__proto__")
# Where expect is the test runner's when a file imports it by name.
EXPECT_SOURCES = ("vitest", "@jest/globals", "bun:test")


def js_expect_own(code, quoted):
    """Whether expect, in a JavaScript file's code (js_scan's, comments blanked; quoted its marks), is
    the test runner's wherever it is called: every use is a call or a member read, or its name alone
    in an import list from EXPECT_SOURCES (claude-config#3146). Any other use (a declaration, a
    parameter, a destructuring, an assignment, an import under another name or from anywhere else, a
    member of something else) can bind it to anything, and gives False."""
    lists = [(m.start(1), m.end(1)) for m in
             re.finditer(r"\bimport\s*\{([^{}]*)\}\s*from\s*(['\"])([^'\"\n]+)\2", code)
             if not quoted[m.start()] and m.group(3) in EXPECT_SOURCES]
    for m in re.finditer(r"(?<![\w$])expect(?![\w$])", code):
        p = m.start()
        if quoted[p]:
            continue
        inside = next(((a, b) for a, b in lists if a <= p < b), None)
        if inside:
            if re.search(r"\bas\s*\Z", code[inside[0]:p]) or re.match(r"\s*as\b", code[m.end():inside[1]]):
                return False
            continue
        before = code[:p].rstrip()
        if before.endswith(".") or re.search(r"(?<![\w$])(?:function|class|const|let|var|import|export|as)\Z", before):
            return False
        if not re.match(r"\s*[(.]", code[m.end():]):
            return False
    return True


def js_compared(text, code, quoted, at):
    """Whether index at of a JavaScript file's text lies in a string that is the whole argument of a
    matcher that only compares (JS_MATCHERS) on expect(...), with not, resolves or rejects between
    (claude-config#3146): one string written out, quoted or a template with no ${...}, alone in the
    call's parentheses. code and quoted are js_scan's. Whether expect is the runner's
    (js_expect_own) and whether anything the walk reads changes what a matcher does
    (JS_MATCHER_CHANGED) are the caller's to ask."""
    if quoted[at] != 1:
        return False
    s, e = at, at
    while s and quoted[s - 1] == 1:
        s -= 1
    while e < len(quoted) and quoted[e] == 1:
        e += 1
    lit = text[s:e]
    if len(lit) < 2 or lit[0] not in "'\"`" or lit[-1] != lit[0] or (lit[0] == "`" and "${" in lit):
        return False
    if not code[e:].lstrip().startswith(")"):
        return False
    before = code[:s].rstrip()
    m = JS_MATCHERS.search(before)
    if not m:
        return False
    rest = before[:m.start()].rstrip()
    mod = JS_MATCHER_MODIFIERS.search(rest)
    while mod:
        rest = rest[:mod.start()].rstrip()
        mod = JS_MATCHER_MODIFIERS.search(rest)
    j = len(rest) - 1
    if j < 1 or rest[j] != ")" or quoted[j]:
        return False
    k = js_opener(code, quoted, j - 1)
    return k is not None and code[k] == "(" and re.search(r"(?<![\w$.])expect\s*\Z", code[:k]) is not None


def js_literal(text, quoted, at):
    """The index after the string literal that starts at text[at], and what it holds, where it is one
    whole string written out: quoted (never a template), on one line, with no backslash, so what it
    holds is exactly what is written. (None, None) for anything else."""
    if at >= len(text) or text[at] not in "'\"" or not quoted[at]:
        return None, None
    end = text.find(text[at], at + 1)
    if end < 0 or not all(quoted[at:end + 1]) or (end + 1 < len(quoted) and quoted[end + 1] == 1):
        return None, None
    held = text[at + 1:end]
    if "\\" in held or "\n" in held:
        return None, None
    return end + 1, held


def js_declared(text, code, quoted, a, b):
    """Whether the webhook's name at text[a:b] is only declared there (module docstring): the key of
    an object literal set to null, undefined or a string that is no address anyone receives at, or a
    member of an interface or a type alias given a type with no value in it. code and quoted are
    js_scan's. Anything this cannot place is not declared, and is judged as every name is."""
    n = len(code)
    if not code[a:b].strip():
        return False  # in a comment: held only as data there (js_held), as before
    kinds = set(quoted[a:b])
    if kinds == {0}:
        s, e = a, b
        while s and re.match(r"[\w$]", code[s - 1]) and not quoted[s - 1]:
            s -= 1
        while e < n and re.match(r"[\w$]", code[e]) and not quoted[e]:
            e += 1
    elif kinds == {1}:
        s = a
        while s and quoted[s - 1] == 1:
            s -= 1
        e, held = js_literal(text, quoted, s)
        if e is None or e < b or not KEY_WORD.fullmatch(held):
            return False
    else:
        return False
    # The last character before the name that is not blank, found by stepping back: a fixture file
    # can hold the name thousands of times, and a copy of the text for each is what would cost.
    j = s - 1
    while j >= 0 and code[j].isspace():
        j -= 1
    before = code[j] if j >= 0 else ""
    k = js_opener(code, quoted, s - 1)
    if k is None or code[k] != "{":
        return False
    # A member of an interface or a type alias, whose body opens on the header's own line: erased
    # before anything runs, so it reads nothing. Only where the type holds no name that could be a
    # value's, so a brace misread as a type's body still declares nothing that is read.
    # The header is matched before its line is checked for string text, so a long line that is no
    # header costs nothing per name.
    line = code.rfind("\n", 0, k) + 1
    if kinds == {0} and TYPE_MEMBER.match(code, e) and TYPE_HEAD.fullmatch(code, line, k) \
            and not any(quoted[line:k]) \
            and (before in ("{", ";", ",") or not code[code.rfind("\n", 0, s) + 1:s].strip()):
        return True
    # An object literal's key: straight after the { or a comma inside it, and before a colon.
    if before not in ("{", ","):
        return False
    m = KEY_COLON.match(code, e)
    if m is None:
        return False
    v = m.end()
    word = INERT_WORD.match(code, v)
    if word is not None and not any(quoted[v:word.end()]):
        v = word.end()
    else:
        v, held = js_literal(text, quoted, v)
        if v is None or not (INERT_URL.fullmatch(held) or INERT_TEXT.fullmatch(held)):
            return False
    while v < n and code[v].isspace():
        v += 1
    return code[v:v + 1] in (",", "}") and not js_spread_after(code, quoted, v)


def js_spread_after(code, quoted, at):
    """Whether a spread (...) stands between index at of JavaScript code and the bracket closing the
    level at is in, at that level: in an object literal it sets every key it carries over the ones
    written before it. True too where the level never closes, which cannot be placed."""
    depth = 0
    for k in range(at, len(code)):
        if quoted[k]:
            continue
        c = code[k]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if not depth:
                return False
            depth -= 1
        elif c == "." and not depth and code.startswith("...", k):
            return True
    return True


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
    """The base class for the gate's Judge (module docstring). marker is its MARKER, whose group
    called name, where it has one, is the one thing it finds that is a variable's name and no
    address; js_scan its reading of a JavaScript file's comments and strings, py_marker its reading
    of a Python file, which fills a list it is handed with the first name held only as data, and
    js_sink its JS_SINK."""

    def js_named(text):
        """(each endpoint in JavaScript text, the webhook's name left out wherever it is only declared
        (js_declared, #3050); js_scan's reading of the text, or None where nothing is named)."""
        hits = list(marker.finditer(text))
        if not hits:
            return hits, None
        code, quoted = js_scan(text)
        return [m for m in hits if not (m.groupdict().get("name")
                                        and js_declared(text, code, quoted, m.start(), m.end()))], (code, quoted)

    def js_marks(text):
        """(the first endpoint in JavaScript text not held only as data, or None; where there is none,
        the first one held only as data, or None)."""
        hits, scan = js_named(text)
        held = None
        for m in hits:
            if not js_held(text, *scan, m.start(), m.end()):
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

        def named_in(self, text, kind):
            """The first endpoint in a file's whole text, read as what a program handed the file can
            find in it: comments and strings count, since the program reads them as text. In a
            JavaScript or TypeScript file (kind "js") the webhook's name is left out wherever it is
            only declared, where the text gives nothing to send to (js_declared, #3050)."""
            if kind == "js":
                return next(iter(js_named(text)[0]), None)
            return marker.search(text)

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
