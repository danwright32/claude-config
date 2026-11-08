#!/usr/bin/env python3
"""The rule behind slack-drafts-only-gate.sh: no session sends or schedules a Slack message, it only
saves drafts (claude-config#2302).

Reads one PreToolUse payload on stdin and prints its verdict on stdout, first line one of:
  allow          the call goes through
  refuse         the lines after it are the reason, for the wrapper to put on stderr with exit 2
  unreadable     the payload is not a call this can read; the line after it says why, and the
                 wrapper decides from the raw text (fails closed on one naming a send route)

Two routes are judged:
  * A Slack MCP tool (any tool whose name holds "slack") whose own name, its last `__` segment, is a
    send or schedule tool. slack_send_message_draft is a different name and passes, as does every
    tool that reads Slack.
  * A Bash command that makes the request: curl or wget (and friends) aimed at a Slack posting
    endpoint, an inline script holding one, a script fed on stdin holding one, or a script file run
    by the command that holds one. A command that only MENTIONS an endpoint (a grep, an echo, a
    test) runs nothing that posts and passes. A shell script is read as commands, so one that only
    greps passes and one that curls is refused. A package script (`npm run digest`, pnpm, yarn,
    npm test) is followed through the nearest package.json, pre and post scripts included, and
    judged as the command line it runs. The local modules a JavaScript, TypeScript or Python script
    imports, from a file, inline code (`node -e`, `python3 -c`) or its input, are followed, each
    judged the same way (claude-config#2318); an import written in a JavaScript or TypeScript comment
    is an example, not one (claude-config#2397). A file a script is handed as data (shaped like data,
    after the script) is not read for an endpoint unless the script can send a request or run what it
    is handed (claude-config#2362), whether the script runs through its interpreter or by its own
    path with the interpreter its #! names (claude-config#2400); a Python script counts as able to
    unless it imports only modules known to be unable to (PY_INERT). The one script let through is
    /nudge, at
    skills/nudge/nudge.py beside this hooks folder, by its real path; a copy anywhere else is refused
    like any other script that posts.

Limits, stated so nobody reads more into a pass than it measured: a JavaScript import of a package or
through a path alias (`@/lib/x`), a Python module in the standard library or installed, a module run
with `python3 -m`, and an import of another language's files are
not followed; a program run by bare name from the PATH is not read; and deliberate obfuscation (an
endpoint assembled from pieces, an import path built at run time) is not the threat this answers.
The threat is a session that means well choosing the quickest way to post.
"""
import ast
import glob
import importlib.machinery
import importlib.util
import json
import os
import re
import sys
import warnings

# Loading lib/shell-words.py by path must leave no bytecode beside it in the installed lib/ (#2080).
sys.dont_write_bytecode = True
HERE = os.environ.get("GATE_DIR") or os.path.dirname(os.path.abspath(__file__))
ISSUE = "claude-config#2302"

# The endpoints and names that post: Slack's Web API methods that put a message in front of people,
# an incoming webhook's host, and the variable name projects keep a webhook in.
MARKER = re.compile(r"chat[._](postMessage|scheduleMessage|postEphemeral|meMessage)|hooks\.slack\.com|slack_webhook",
                    re.I)
SEND_TOOLS = {"slack_send_message", "slack_schedule_message", "slack_post_message", "slack_reply_to_thread"}

SENDERS = {"curl", "wget", "http", "https", "xh", "httpie", "curlie"}
INTERPRETER = re.compile(r"^(python[0-9.]*|pypy[0-9.]*|node|nodejs|ruby|perl|php|deno|bun|tsx|ts-node|osascript)$")
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
LAUNCHERS = {"npx", "bunx", "pnpx"}
# Options that hold code to run, per interpreter family (python -c, node -e or -p, perl -e or -E,
# ruby -e, osascript -e, deno eval), and a short cluster ending in one (perl -ne, python -Bc). Inline
# code is in the command's own text, which is judged first, so this decides that there is no script
# file to read, and the word after it is the code whose imports are followed (claude-config#2318).
INLINE = {"-c", "-e", "-E", "-p", "--eval", "--print", "eval"}
INLINE_CLUSTER = re.compile(r"^-[A-Za-z]{1,4}[ceE]$")
# Options whose value is the next word, so it is never taken for the script.
VALUED = {"-m", "-W", "-X", "-r", "--require", "-I", "-i", "--import", "--loader", "-C", "--config", "-o"}
SHELL_EXT = (".sh", ".bash", ".zsh", ".command")
SHELL_BANG = re.compile(r"^#!\s*\S*?(?:/env\s+(?:-\S+\s+)*)?/?(?:\S*/)?(ba|z|da|k)?sh\b")
MAX_FILE = 2 * 1024 * 1024
PACKAGERS = {"npm", "pnpm", "yarn"}
NPM_RUN = {"run", "run-script", "rum", "urn"}
NPM_LIFECYCLE = {"test": "test", "t": "test", "tst": "test", "start": "start", "stop": "stop", "restart": "restart"}
PKG_DIR_OPTS = {"--prefix", "-C", "--dir", "--cwd"}
PKG_EXEC = {"exec", "x", "dlx"}
MAX_DEPTH = 3
# A JavaScript or TypeScript script's relative imports are followed (claude-config#2318): repo-digest's
# `npm run digest` runs src/digest.ts, which names no endpoint and imports src/slack.ts, which does.
JS_EXT = (".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs")
JS_RUNTIME = re.compile(r"^(node|nodejs|deno|bun|tsx|ts-node)$")
JS_BANG = re.compile(r"^#!.*\b(node|nodejs|deno|bun|tsx|ts-node)\b")
# The .js a TypeScript ESM file writes for its own sibling, which is a .ts on disk.
JS_TO_TS = {".js": (".ts", ".tsx"), ".mjs": (".mts",), ".cjs": (".cts",), ".jsx": (".tsx",)}
# Every way a module names another: import ... from 'x', export ... from 'x', import 'x', import('x'),
# require('x'). Read from the code with its comments blanked (js_code): an import written in a comment
# is an example, and following it refused every suite importing a harness that shows one (#2397).
IMPORT_SPEC = re.compile(r"""(?:\bfrom|\bimport\s*\(?|\brequire\s*\()\s*(['"`])([^'"`\n]+)\1""")
# What can stand before a / that opens a regex literal rather than divides: punctuation, or a keyword.
JS_REGEX_AFTER = set("(,=:[!&|?{};+-*%<>~^")
JS_REGEX_WORDS = {"return", "typeof", "case", "do", "else", "in", "instanceof", "new", "delete", "void",
                  "throw", "yield", "await", "of"}


def js_code(text):
    """A JavaScript or TypeScript file's text with each // and /* */ comment blanked to spaces, its
    newlines kept, so an import shown in a comment is not read as one (claude-config#2397, the rule
    the alert guard got in #2368: a script is read by the code it runs, never a comment).

    Strings, template literals (with the code inside each ${...}) and regex literals are stepped
    over, so a // or /* inside one (a URL, a pattern) opens nothing. Every misreading is bounded on
    the side of reading more: a quote left open ends at its line, and a block comment that never
    closes is left as code, since node refuses that file and a /* misread from a pattern must not
    hide every import after it."""
    out = list(text)
    n = len(text)
    i = 0
    if text.startswith("#!"):
        i = text.find("\n") if "\n" in text else n
    braces = []  # for each ${ entered, the { depth of its code, so its } returns to the template
    depth = 0
    last = ""  # the last code character that was not blank, or the word it ends, for regex or divide

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    def template(k):
        """Step through a template literal's text from k; the index after its closing backtick, or the
        index of a ${ (its code is read as code), or n."""
        while k < n:
            c = text[k]
            if c == "\\":
                k += 2
            elif c == "`":
                return k + 1, False
            elif c == "$" and text.startswith("${", k):
                return k + 2, True
            else:
                k += 1
        return n, False

    while i < n:
        c = text[i]
        if c in " \t\r\n":
            i += 1
            continue
        if c == "/" and text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            blank(i, end)
            i = end
            continue
        if c == "/" and text.startswith("/*", i):
            end = text.find("*/", i + 2)
            if end < 0:
                break  # never closed: left as code
            blank(i, end + 2)
            i = end + 2
            continue
        if c in "'\"":
            k = i + 1
            while k < n and text[k] not in (c, "\n"):
                k += 2 if text[k] == "\\" else 1
            i = k + 1
            last = c
            continue
        if c == "`":
            i, entered = template(i + 1)
            if entered:
                braces.append(depth)
                depth += 1
                last = "{"
            else:
                last = "`"
            continue
        if c == "/" and (last == "" or last in JS_REGEX_AFTER or last in JS_REGEX_WORDS):
            k, klass = i + 1, False
            while k < n and text[k] != "\n":
                ch = text[k]
                if ch == "\\":
                    k += 2
                    continue
                if ch == "[":
                    klass = True
                elif ch == "]":
                    klass = False
                elif ch == "/" and not klass:
                    break
                k += 1
            if k < n and text[k] == "/":
                i = k + 1
                last = "/regex"
                continue
            # No closing / on the line: a divide after all.
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if braces and depth == braces[-1]:
                braces.pop()
                i, entered = template(i + 1)
                if entered:
                    braces.append(depth)
                    depth += 1
                    last = "{"
                else:
                    last = "`"
                continue
        if c.isalnum() or c in "_$":
            k = i
            while k < n and (text[k].isalnum() or text[k] in "_$"):
                k += 1
            last = text[i:k]
            i = k
            continue
        last = c
        i += 1
    return "".join(out)
# A Python script's imports are followed the same way: a script is Python by its .py, its #!, or a
# python interpreter running a file with no extension.
PY_RUNTIME = re.compile(r"^(python[0-9.]*|pypy[0-9.]*)$")
PY_BANG = re.compile(r"^#!.*\b(python[0-9.]*|pypy[0-9.]*)\b")
# Read when a file cannot be parsed as Python by this python3: each import statement's first line.
PY_IMPORT_LINE = re.compile(r"^[ \t]*(?:from[ \t]+(\.*[\w.]*)[ \t]+import[ \t]+\(?([^#\n)]*)|import[ \t]+([^#\n]+))",
                            re.M)
# The most modules one script's imports are read through, itself included. Measured 2026-11-06 over
# the 139 scripts in repo-digest's src/ and NurseDex's scripts/ and the 110 Python files in this
# payload: the largest reaches 11 (repo-digest's src/manage-repos.ts; src/digest.ts reaches 8,
# NurseDex's largest 5), and none imports a local file that could not be found.
IMPORT_MAX_FILES = 300
# A file handed to a script is DATA, not code it runs, when it is shaped like data: an extension none
# of these interpreters runs, and no #! (claude-config#2362). A file with no extension is read as
# code, since a script is often written without one. The two refusals that asked for this were a
# session transcript (.jsonl) handed to issue-spool.sh clear and a saved gh listing (.json) handed to
# a node script; each named chat.postMessage in text nobody runs.
CODE_EXT = SHELL_EXT + JS_EXT + (".ksh", ".py", ".pyw", ".rb", ".pl", ".pm", ".php", ".applescript", ".scpt",
                                 ".lua", ".tcl", ".r", ".jl", ".ps1")
# What lets a script act on a data file as more than data: sending a request (whose address the file
# can hold), running code (which the file can be), or writing it somewhere that runs later. A
# JavaScript script, or a module it imports, naming any of JS_ACTS still has the data files it is
# handed read. Read from the text, comments included, which can only refuse more.
#
# A Python script is judged the other way round (lessons review at 56b9d7f): a list of the ways to act
# missed urllib3, httplib2, smtplib, ftplib, asyncio streams and importlib's exec_module, and a list
# like that always misses the next one (L96). So a Python script counts as unable to act only when
# every module it imports from outside the script's own files is in PY_INERT, modules that cannot
# send, run code or write a file, and it uses none of PY_RUNS, PY_REACH or PY_WRITES (py_acts).
# Anything else counts as able to act. A dotted entry allows only that submodule: `import os.path`
# binds os, so os used for anything but os.path counts as acting.
PY_INERT = frozenset({
    "__future__", "abc", "argparse", "array", "base64", "binascii", "bisect", "calendar", "cmath",
    "collections", "copy", "csv", "dataclasses", "datetime", "decimal", "difflib", "enum", "fnmatch",
    "fractions", "functools", "glob", "hashlib", "heapq", "html", "itertools", "json", "math", "numbers",
    "os.path", "pathlib", "pprint", "random", "re", "shlex", "statistics", "string", "struct", "sys",
    "textwrap", "time", "typing", "unicodedata", "warnings", "zoneinfo"})
# Builtins that run code, start a program (help's pager) or reach a namespace the script never
# imported. Used at all, not only called, so `f = exec` counts too; re.compile, an attribute, does not.
PY_RUNS = frozenset({"exec", "eval", "compile", "execfile", "__import__", "breakpoint", "help", "getattr",
                     "setattr", "delattr", "vars", "globals", "locals", "__builtins__", "__loader__",
                     "__spec__"})
# Attributes (and imported names) that reach another module or a frame's namespace, change where
# Python finds modules, or evaluate a string as code: sys.modules, sys.path, a frame's f_globals,
# typing's forward references. Any _private attribute and any dunder one counts too (py_acts).
PY_REACH = frozenset({"modules", "path_hooks", "meta_path", "path_importer_cache", "f_globals",
                      "f_builtins", "f_locals", "f_back", "gi_frame", "cr_frame", "ag_frame", "tb_frame",
                      "get_type_hints", "ForwardRef", "evaluate_forward_ref"})
PY_DUNDER_OK = frozenset({"__init__", "__name__", "__doc__", "__qualname__"})
# Methods that write or move a file (pathlib's), beside open() and argparse.FileType with a mode
# that writes.
PY_WRITES = frozenset({"write_text", "write_bytes", "touch", "unlink", "rmdir", "rename", "symlink_to",
                       "hardlink_to", "link_to", "chmod", "mkdir"})
JS_ACTS = re.compile(r"\b(fetch|axios|got|undici|XMLHttpRequest|WebSocket|ky|superagent|node-fetch|"
                     r"https?\.(request|get)|child_process|execSync|execFileSync|spawnSync|execFile|spawn|"
                     r"eval|Function|vm|Deno\.(run|Command)|Bun\.(spawn|\$))\b|"
                     r"""\b(require|import)\s*\(\s*[^'"`\s)]|['"](node:)?(https?|net|tls|http2|dgram)['"]""")
# A shell expansion of the arguments a script was handed: $1 to $9, $@, $*, and their braced forms.
POSITIONAL = r"\$\{?[1-9@*]"
# What a Python import's folder can be handed through: a shell variable in an argument, PYTHONPATH or
# an exported variable (claude-config#2449). A variable's value is known only where the script sets
# it once, unconditionally, at its top (sh_trusted); these mark where that stops being certain: a
# compound command, a group, a subshell or a function opening, and every other way a name is bound.
SH_COMPOUND = re.compile(r"^(?:(?:if|then|elif|else|fi|do|done|while|until|for|select|case|esac|function|coproc|time|!)"
                         r"(?=[\s;&|()]|$)|[{}()]|\[\[)")
SH_FUNC_DEF = re.compile(r"^[A-Za-z_][\w:.-]*\s*\(\s*\)")
SH_BINDERS = (r"\b(?:read|for|select|local|declare|typeset|export|readonly|unset|getopts|mapfile|readarray|let|printf)\b"
              r"[^\n;&|]*?(?<![\w$]){0}\b|\$\{{{0}:?=")
# The builtins after which a NAME=value in front of them outlives the command (POSIX special builtins,
# and those that bind names), so it is an assignment like any other.
SH_SPECIAL = frozenset({":", ".", "source", "break", "continue", "eval", "exec", "exit", "export", "readonly",
                        "return", "set", "shift", "trap", "unset", "times", "local", "declare", "typeset"})
# A parameter expansion: ${...} (its whole inside) or $NAME, $1, $@ and the other one character names.
SH_PARAM = re.compile(r"\$(?:\{([^{}]*)\}|([A-Za-z_]\w*|[0-9@*#?$!-]))")
# Where a redirection starts in a command's text, its target the word after it.
SH_REDIRECT = re.compile(r"\d*(?:<<-|<<<|<<|<>|>>|>&|<&|&>>|&>|>\||<|>)")


def load_reader():
    spec = importlib.util.spec_from_file_location("shell_words", os.path.join(HERE, "lib", "shell-words.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def draft_advice(where):
    return (f"Save it as a draft instead: call slack_send_message_draft {where}, then tell Dan where the draft is "
            "(the channel, or the person for a direct message, and the thread) and that nothing was sent. "
            f"Sessions never send or schedule a Slack message (Dan, 2026-11-05: \"it should only ever save as "
            f"draft in slack, never send directly\"; {ISSUE}). If he asked you to post it, still save the draft "
            "and tell him it is waiting in Slack's Drafts.")


def judge_tool(tool, tool_input):
    last = tool.rsplit("__", 1)[-1].lower()
    if last not in SEND_TOOLS:
        return None
    inp = tool_input if isinstance(tool_input, dict) else {}
    channel = inp.get("channel_id") or inp.get("channel")
    thread = inp.get("thread_ts")
    where = "with the same channel"
    if isinstance(channel, str) and channel:
        where += f" (channel_id {channel})"
    if isinstance(thread, str) and thread:
        where += f" and the same thread (thread_ts {thread})"
    return f"REFUSED: {tool} sends a Slack message. " + draft_advice(where)


class Judge:
    def __init__(self, sw):
        self.sw = sw
        nudge = os.path.join(os.path.dirname(HERE), "skills", "nudge", "nudge.py")
        self.nudge = os.path.realpath(nudge) if os.path.isfile(nudge) else None
        # Where the Python a command starts looks for an absolute import beyond the script's folder
        # (claude-config#2358): the command's PYTHONPATH (its own assignment, one exported earlier in
        # the line, or the session's), its directory, and the interpreter it names. record() sets it
        # for each command and puts the previous one back after.
        self.exported = None
        self.py_cmd = {"path": self.py_path(os.environ.get("PYTHONPATH", ""), os.getcwd()),
                       "cwd": os.getcwd(), "interp": None}
        # The shell variables of the text line() is reading (claude-config#2449), and the script file
        # it is, as its BASH_SOURCE names it, which script() hands to the line() it calls.
        self.shell = self.shell_scope("", "", None)
        self.next_script = None

    @staticmethod
    def shell_scope(text, cwd, script):
        """A fresh record of one text's variables: each NAME=value command read so far (pending, its
        text and directory), the values worked out from them, the names exported, and the names
        sh_trusted finds safe to take a value for, worked out the first time one is asked for."""
        return {"text": text, "cwd": cwd, "script": script, "pending": {}, "values": {}, "exported": set(),
                "trusted": None}

    @staticmethod
    def py_path(value, d):
        """The directories a PYTHONPATH value names, made absolute against d. An entry that is
        expanded at run time ($PYTHONPATH) is the session's own, added once at the end."""
        out = []
        for p in value.split(os.pathsep):
            if not p or "$" in p:
                continue
            p = os.path.expanduser(p)
            out.append(os.path.normpath(p if os.path.isabs(p) else os.path.join(d or os.getcwd(), p)))
        if "$" in value:
            out += Judge.py_path(os.environ.get("PYTHONPATH", "").replace("$", ""), d)
        return out

    def resolve(self, word, d):
        p = os.path.expanduser(word)
        if not os.path.isabs(p):
            p = os.path.join(d or os.getcwd(), p)
        return p

    def script(self, word, d, depth, shell_hint, lang=None):
        """The reason a script file posts, or None. lang ("js" or "py") is the language of the
        program running it, taken for a file with no extension of its own."""
        path = self.resolve(word, d)
        if not os.path.isfile(path):
            return None  # nothing there to run
        real = os.path.realpath(path)
        if self.nudge and real == self.nudge:
            return None  # /nudge, the one exemption (Dan, 2026-11-05)
        try:
            with open(real, "rb") as f:
                body = f.read(MAX_FILE).decode("utf-8", "replace")
        except OSError:
            return None  # unreadable to us is unreadable to the shell that would run it
        hit = MARKER.search(body)
        first = body.split("\n", 1)[0]
        is_shell = shell_hint or real.endswith(SHELL_EXT) or bool(SHELL_BANG.match(first))
        if is_shell and depth < MAX_DEPTH:
            # Read as commands even with no endpoint in it: it can run another script that posts.
            try:
                self.next_script = word  # its BASH_SOURCE, as written in the command (claude-config#2449)
                inner = self.line(body, d, depth + 1, body)
            except Exception:
                inner = f"it names {hit.group(0)} and could not be read as commands" if hit else None
            return f"the script {word} runs a command that posts: {inner}" if inner else None
        if hit:
            return f"the script {word} posts to Slack (it names {hit.group(0)})"
        kind = self.language(real, first, lang)
        if kind:
            return self.imports(f"the script {word}", real, os.path.dirname(real), body, kind)
        return None

    @staticmethod
    def language(path, first, lang):
        """"js" or "py" for a script whose imports are followed, by its extension, its #!, or, for a
        file with no extension, the program running it; None for anything else (a data file)."""
        ext = os.path.splitext(path)[1]
        if ext in JS_EXT or JS_BANG.match(first):
            return "js"
        if ext == ".py" or PY_BANG.match(first):
            return "py"
        return lang if not ext else None

    def imports(self, start, origin, root, body, kind):
        """The reason a script posts through a module it imports, or None (claude-config#2318).

        start names the script ("the script x.ts", "the code given to node -e"), origin is its file
        (None for inline code), root the directory it runs from, where Python finds its absolute
        imports. Each import is resolved as node and TypeScript, or Python, would, and each module
        found is judged as the script is, by the endpoint it names, then its own imports followed,
        each module read once however many import it, so a cycle ends. A package, a node builtin and
        a Python module in the standard library or installed are not ours to read. An import that
        names a local file the gate cannot find or read is refused, and so is a Python import placed
        nowhere (resolve_py, claude-config#2358),
        because node or Python may still find it (package.json exports, a path alias, a loader) and
        run what the gate never saw; so is a script reaching more than IMPORT_MAX_FILES modules. An
        import whose path is assembled at run time (a template holding ${...}, importlib) is not
        followed: no file is named to read."""
        for why, via, target, found in self.modules(start, origin, root, body, kind):
            if why:
                return why
            hit = MARKER.search(found)
            if hit:
                return f"{via} ({target}), which posts to Slack (it names {hit.group(0)})"
        return None

    def modules(self, start, origin, root, body, kind):
        """Each local module a script's imports reach, as (None, how it is reached, its file, its text),
        each once; or, where an import cannot be followed, (the reason, None, None, None) and no more.
        The one walk both imports() and acts() read, so the two cannot disagree about what is reached."""
        seen = {origin} if origin else set()
        queue = [(origin, root, body, start)]
        inserts = ([], [])  # the folders a sys.path change puts in front of the rest, and behind them
        while queue:
            cur, cur_dir, text, chain = queue.pop(0)
            if kind == "py":
                self.py_inserts(text, cur, inserts)
            for spec, targets in self.import_targets(text, kind, cur_dir, root, inserts):
                via = f"{chain}, which imports {spec}"
                if targets is False:
                    where = ("" if kind != "py" or spec.startswith(".") else
                             " beside the script, on its PYTHONPATH or sys.path, in the standard library or installed")
                    yield (f"{via}, a module the gate cannot find{where}, so it cannot see what that runs"), None, None, None
                    return
                for target in targets:
                    target = os.path.realpath(target)
                    if target in seen:
                        continue
                    seen.add(target)
                    if len(seen) > IMPORT_MAX_FILES:
                        yield (f"{start} imports more than {IMPORT_MAX_FILES} modules, past what the gate "
                               "reads, so it cannot see what they run"), None, None, None
                        return
                    try:
                        with open(target, "rb") as f:
                            found = f.read(MAX_FILE).decode("utf-8", "replace")
                    except OSError:
                        yield (f"{via} ({target}), a module the gate cannot read, so it cannot see what that "
                               "runs"), None, None, None
                        return
                    yield None, via, target, found
                    queue.append((target, os.path.dirname(target), found, f"{via} ({os.path.basename(target)})"))

    def import_targets(self, text, kind, cur_dir, root, inserts=((), ())):
        """(the import as written, the files it runs, or False when it names a local file not there,
        or a Python module placed nowhere), for each import in text; a package or a builtin gives an
        empty list."""
        if kind == "js":
            for m in IMPORT_SPEC.finditer(js_code(text)):
                spec = m.group(2)
                if "${" in spec:
                    continue
                target = self.resolve_import(spec, cur_dir)
                if target is not None:
                    yield spec, ([target] if target else False)
            return
        for level, module, names in self.py_imports(text):
            spec = "." * level + module + (f" import {', '.join(names)}" if level and not module else "")
            yield spec, self.resolve_py(level, module, names, cur_dir, root, inserts)

    @staticmethod
    def py_imports(text):
        """(level, module, names) for each import statement in Python source, by its syntax tree, or
        by each statement's first line when this python3 cannot parse it."""
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                tree = ast.parse(text)
        except (SyntaxError, ValueError):
            out = []
            for m in PY_IMPORT_LINE.finditer(text):
                if m.group(3) is not None:
                    out += [(0, a.split()[0], ()) for a in m.group(3).split(",") if a.split()]
                else:
                    dots = len(m.group(1)) - len(m.group(1).lstrip("."))
                    names = tuple(a.split()[0] for a in m.group(2).split(",") if a.split())
                    out.append((dots, m.group(1)[dots:], names))
            return out
        out = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                out += [(0, a.name, ()) for a in node.names]
            elif isinstance(node, ast.ImportFrom):
                out.append((node.level, node.module or "", tuple(a.name for a in node.names)))
        return out

    def resolve_py(self, level, module, names, cur_dir, root, inserts=((), ())):
        """The local files a Python import runs (each package's __init__.py, the module, and any
        submodule it names), an empty list for the standard library or an installed package, or False
        for a relative import, or a local package's missing part, that names nothing there, and for an
        absolute import placed nowhere (claude-config#2358).

        An absolute import is looked for where Python looks, in its order: a folder a sys.path change
        puts in front, the script's own folder (root), the command's PYTHONPATH, then the standard
        library and installed packages (placed()), then a folder a sys.path change appends. Placed
        nowhere, it is refused, since Python may still find it (a path the gate cannot evaluate, a .pth
        file, a loader) and run what the gate never saw."""
        if level:
            base = cur_dir
            for _ in range(level - 1):
                base = os.path.dirname(base)
            found = self.resolve_in(base, level, module, names)
            return False if found is None else found
        if not module:
            return []
        for base in list(inserts[0]) + [root] + self.py_cmd["path"]:
            found = self.resolve_in(base, 0, module, names)
            if found is not None:
                return found
        if self.placed(module.split(".")[0], root):
            return []
        for base in inserts[1]:
            found = self.resolve_in(base, 0, module, names)
            if found is not None:
                return found
        return False

    def placed(self, top, root):
        """Whether a top level Python module is the standard library or an installed package: built
        in, named in this python's standard library list, or found (not imported) on its own sys.path
        past this hooks folder, in the site-packages of a virtual environment the command's
        interpreter belongs to, the session's VIRTUAL_ENV, or the nearest .venv or venv folder above
        the script or the command's directory."""
        if top in sys.builtin_module_names or top in getattr(sys, "stdlib_module_names", ()):
            return True
        here = os.path.realpath(os.path.dirname(os.path.abspath(__file__)))
        dirs = [p for p in sys.path[1:] if p and os.path.realpath(p) != here]
        envs = []
        interp = self.py_cmd.get("interp")
        if interp and "/" in interp:
            envs.append(os.path.dirname(os.path.dirname(self.resolve(interp, self.py_cmd["cwd"]))))
        if os.environ.get("VIRTUAL_ENV"):
            envs.append(os.environ["VIRTUAL_ENV"])
        for start in (root, self.py_cmd["cwd"]):
            d = os.path.abspath(start) if start else None
            while d:
                for name in (".venv", "venv"):
                    if os.path.isfile(os.path.join(d, name, "pyvenv.cfg")):
                        envs.append(os.path.join(d, name))
                up = os.path.dirname(d)
                d = None if up == d else up
        for env in envs:
            dirs += sorted(glob.glob(os.path.join(env, "lib", "python*", "site-packages")))
        try:
            return importlib.machinery.PathFinder.find_spec(top, dirs) is not None
        except (ImportError, ValueError):
            return False

    def py_inserts(self, text, cur, inserts):
        """Add to inserts the folders text's sys.path changes name: sys.path.insert(n, x) in front,
        sys.path.append(x), sys.path.extend([...]) and site.addsitedir(x) behind. x is evaluated
        when it is a literal or built from __file__ (os.path.dirname, os.path.join, abspath, Path(...)
        .parent, / and the like), or from sys.argv[n] or os.environ where the command hands python a
        value py_args can work out (claude-config#2449); a relative result is relative to the command's
        directory, as Python takes it. A change the gate cannot evaluate adds nothing, and an import
        only it would place is then placed nowhere and refused."""
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                tree = ast.parse(text)
        except (SyntaxError, ValueError):
            return
        cwd = self.py_cmd["cwd"]
        known = {}  # NAME = <path expression> assignments, as far as each has been read
        nodes = [n for n in ast.walk(tree) if isinstance(n, (ast.Assign, ast.Call))]
        for node in sorted(nodes, key=lambda n: (n.lineno, n.col_offset)):
            if isinstance(node, ast.Assign):
                for t in node.targets:
                    if isinstance(t, ast.Name):
                        v = self.py_path_expr(node.value, cur, cwd, known)
                        if v is None:
                            known.pop(t.id, None)
                        else:
                            known[t.id] = v
                continue
            f, args = node.func, node.args
            name = self.dotted(f)
            if isinstance(f, ast.Attribute) and self.dotted(f.value) == "sys.path":
                if f.attr == "insert" and len(args) == 2:
                    where, exprs = inserts[0], [args[1]]
                elif f.attr == "append" and args:
                    where, exprs = inserts[1], [args[0]]
                elif f.attr == "extend" and args and isinstance(args[0], (ast.List, ast.Tuple)):
                    where, exprs = inserts[1], list(args[0].elts)
                else:
                    continue
            elif name in ("site.addsitedir", "addsitedir") and args:
                where, exprs = inserts[1], [args[0]]
            else:
                continue
            for e in exprs:
                p = self.py_path_expr(e, cur, cwd, known)
                if p:
                    p = os.path.normpath(p if os.path.isabs(p) else os.path.join(cwd, p))
                    if p not in where:
                        where.append(p)

    @staticmethod
    def dotted(node):
        """a.b.c for a Name or an Attribute chain, else None."""
        out = []
        while isinstance(node, ast.Attribute):
            out.append(node.attr)
            node = node.value
        if isinstance(node, ast.Name):
            return ".".join([node.id] + out[::-1])
        return None

    def py_path_expr(self, e, cur, cwd, known=None):
        """The path a sys.path expression names, or None when it is not one this can evaluate. known
        holds the module's NAME = <path> assignments read so far (HERE = os.path.dirname(__file__))."""
        known = known if known is not None else {}
        ev = lambda n: self.py_path_expr(n, cur, cwd, known)  # noqa: E731
        whole = lambda p: os.path.normpath(os.path.join(cwd, os.path.expanduser(p)))  # noqa: E731
        if isinstance(e, ast.Constant) and isinstance(e.value, str):
            return e.value
        if isinstance(e, ast.Name):
            return cur if e.id == "__file__" else known.get(e.id)  # __file__ is None for inline code
        if isinstance(e, ast.BinOp) and isinstance(e.op, ast.Add):
            a, b = ev(e.left), ev(e.right)
            return a + b if a is not None and b is not None else None
        if isinstance(e, ast.Attribute) and e.attr == "parent":
            v = ev(e.value)
            return os.path.dirname(whole(v)) if v else None
        if (isinstance(e, ast.Subscript) and isinstance(e.value, ast.Attribute) and e.value.attr == "parents"
                and isinstance(e.slice, ast.Constant) and isinstance(e.slice.value, int) and e.slice.value >= 0):
            v = ev(e.value.value)  # Path(__file__).resolve().parents[1]
            if not v:
                return None
            v = whole(v)
            for _ in range(e.slice.value + 1):
                v = os.path.dirname(v)
            return v
        if isinstance(e, ast.Subscript) and isinstance(e.slice, ast.Constant):
            # sys.argv[n] and os.environ["X"]: what the command hands this python, where py_args could
            # work it out (claude-config#2449); None, so placed nowhere, where it could not.
            base, key = self.dotted(e.value), e.slice.value
            if base == "sys.argv" and isinstance(key, int) and not isinstance(key, bool) and key >= 0:
                argv = self.py_cmd.get("argv") or ()
                return argv[key] if key < len(argv) else None
            if base == "os.environ" and isinstance(key, str):
                return (self.py_cmd.get("env") or {}).get(key)
            return None
        if isinstance(e, ast.BinOp) and isinstance(e.op, ast.Div):
            a, b = ev(e.left), ev(e.right)
            return os.path.join(a, b) if a and b else None
        if not isinstance(e, ast.Call):
            return None
        method = e.func.attr if isinstance(e.func, ast.Attribute) else None
        last = (self.dotted(e.func) or "").rsplit(".", 1)[-1]
        vals = [ev(a) for a in e.args]
        if any(v is None for v in vals):
            return None
        if self.dotted(e.func) in ("os.environ.get", "os.getenv") and len(vals) == 1:
            return (self.py_cmd.get("env") or {}).get(vals[0])
        if method in ("resolve", "absolute", "expanduser") and not vals:
            v = ev(e.func.value)  # Path(...).resolve()
            return whole(v) if v else None
        if method == "joinpath":
            v = ev(e.func.value)
            return os.path.join(v, *vals) if v else None
        if last == "getcwd" and not vals:
            return cwd
        if not vals:
            return None
        if last == "join":
            return os.path.join(*vals)
        if last == "dirname":
            return os.path.dirname(vals[0])
        if last in ("abspath", "realpath", "normpath", "expanduser"):
            return whole(vals[0])
        if last in ("Path", "PurePath", "str", "fspath"):
            return vals[0]
        return None

    # A shell variable's value, for the folder a Python import is placed in (claude-config#2449).
    #
    # tests/test-mods.sh sets ROOT="$(cd "$DIR/.." && pwd)" at its top and runs
    # `python3 - "$ROOT/tools/lib" <<'PY'`, whose code does sys.path.insert(0, sys.argv[1]) and imports
    # ts_source. The gate refuses an import it cannot place (#2358), so it refused the whole suite
    # until it could work out what "$ROOT/tools/lib" holds. A value is worked out only where it is
    # certain what the variable holds when python starts (sh_trusted), from the few forms the scripts
    # use: literals, quotes, other such variables, BASH_SOURCE, and $(pwd), $(dirname X) and
    # $(cd X && pwd). Anything else is None, and an entry built from None is placed nowhere, so the
    # import is refused as before: this only ever places more imports, each judged like any other.

    def sh_note(self, text, words, assigns, d):
        """Note a command that only sets one variable (NAME=value, or export NAME=value), for sh_var."""
        lines = [a for a in assigns.split("\n") if a.strip()]
        if not words and len(lines) == 1:
            name, exported = lines[0].split("=", 1)[0], False
        elif words[:1] == ["export"] and len(words) == 2 and "=" in words[1] and not lines:
            name, exported = words[1].split("=", 1)[0], True
        else:
            return
        if not re.fullmatch(r"[A-Za-z_]\w*", name):
            return
        self.shell["pending"][name] = (text, d)
        self.shell["values"].pop(name, None)
        if exported:
            self.shell["exported"].add(name)

    def sh_var(self, name, seen=()):
        """The value of a variable the text being read set, or None where it is not certain."""
        ctx = self.shell
        if name in ctx["values"]:
            return ctx["values"][name]
        if name not in ctx["pending"] or name in seen:
            return None
        if ctx["trusted"] is None:
            ctx["trusted"] = self.sh_trusted(ctx["text"], ctx["cwd"], ctx["script"])
        if name not in ctx["trusted"]:
            return None
        text, d = ctx["pending"][name]
        m = re.match(r"\s*(?:export\s+)?" + name + "=", text)
        v = None
        if m:
            end = self.sh_word_end(text, m.end())
            v = self.sh_word(text[m.end():end], d, lambda n: self.sh_var(n, seen + (name,)), ctx["script"], True)[0]
        ctx["values"][name] = v
        return v

    def sh_pythonpath(self, value, text, d):
        """A PYTHONPATH value with its variables worked out from the command's own text, where they can
        be; otherwise the value as it was, whose $ entries py_path leaves out."""
        if "$" not in value:
            return value
        m = re.search(r"(?<![\w$])PYTHONPATH=", text)
        if not m:
            return value
        end = self.sh_word_end(text, m.end())
        v = self.sh_word(text[m.end():end], d, self.sh_var, self.shell["script"], True)[0]
        return value if v is None else v

    def sh_trusted(self, s, cwd, script):
        """The names whose value is certain wherever s uses them after setting them: each set exactly
        once in s, by a command of its own at the top of s, before the first compound command, group,
        subshell, function, pipeline or && / || chain (so it has run, and run only once, by the time
        anything after it does), bound no other way in s (read, for, local, export NAME, ${NAME:=}...),
        and set by no file s sources. A file s sources whose path cannot be worked out, or which is not
        there, leaves no name certain. One those files source in turn is read where its path can be
        worked out; where it cannot, it is not read (as the gate reads no sourced file it cannot find)."""
        parts = []
        try:
            cmds = self.sw.commands(s, cwd, parts=parts)
        except Exception:
            return set()
        subst = [(a, b) for p in parts if len(p["scope"]) == 1 for a, b, _ in p["inner"]]
        # A guard is no end to the top: `x || exit 1`, `x || { ...; exit 1; }` and
        # `if x; then ...; exit 1; fi` either do not run their exit, so everything after them runs
        # unconditionally, or end the script, so nothing after them runs. Its body is simple commands
        # ending in an exit nothing chains into; anything else in it ends the top.
        cands, prev, block = {}, ";", None
        for (d, t), p in zip(cmds, parts):
            if len(p["scope"]) > 1:
                if any(a <= p["start"] < b for a, b in subst):
                    continue  # a command substitution's, read as part of the command holding it
                break  # a subshell
            head = t.strip()
            if block is not None:
                if SH_FUNC_DEF.match(head) or p["how"] in ("&", "case"):
                    break
                if block["cond"]:
                    if not re.match(r"then(\s|$)", head):
                        if SH_COMPOUND.match(head):
                            break
                        continue  # one of the if's condition commands
                    block["cond"], head = False, head[4:].strip()
                    if not head:
                        continue
                if head == block["end"]:
                    if not (re.match(r"exit\b", block["last"]) and block["before"] not in ("&&", "||", "|")
                            and block["how"] in (";", "#", "\\n")):
                        break
                    block, prev = None, p["how"]
                    continue
                if SH_COMPOUND.match(head):
                    break  # elif, else, or a compound command inside
                block.update(before=block["how"], last=head, how=p["how"])
                continue
            if prev in ("&&", "||") and p["how"] not in ("|", "&", "&&", "||", "case"):
                if re.match(r"exit\b", head):
                    prev = p["how"]
                    continue
                if re.match(r"\{(\s|$)", head):
                    inner = head[1:].strip()
                    if inner and (SH_COMPOUND.match(inner) or SH_FUNC_DEF.match(inner)):
                        break
                    block = {"end": "}", "cond": False, "last": inner, "before": ";", "how": p["how"] if inner else ";"}
                    continue
            if re.match(r"if(\s|$)", head) and prev not in ("&&", "||", "|", "&") and p["how"] not in ("&", "case"):
                block = {"end": "fi", "cond": True, "last": "", "before": ";", "how": ";"}
                continue
            if prev in ("&&", "||", "|", "&") or p["how"] in ("|", "&", "case"):
                break
            if SH_COMPOUND.match(head) or SH_FUNC_DEF.match(head):
                break
            prev = p["how"]
            m = re.match(r"(?:export\s+)?([A-Za-z_]\w*)=", head)
            if not m or head[self.sh_word_end(head, m.end()):].strip():
                continue
            name = m.group(1)
            cands[name] = None if name in cands else (head[m.end():self.sh_word_end(head, m.end())], d, p["start"],
                                                       p["end"])
        # NAME=value in front of a command (not a special builtin) sets it for that command alone,
        # so it is no second assignment: `LIBDIR="$DIR/lib" python3 ...` beside `export LIBDIR=...`.
        temp = {}
        for (d, t), p in zip(cmds, parts):
            rest_t, assigns = self.sw.command_rest(t)
            words = self.sw.command_words(rest_t)
            if words and words[0] not in SH_SPECIAL:
                for a in assigns.split("\n"):
                    n = a.split("=", 1)[0]
                    if a.strip() and re.fullmatch(r"[A-Za-z_]\w*", n):
                        temp[n] = temp.get(n, 0) + 1
        names = set()
        for name, c in cands.items():
            if c is None:
                continue
            rest = s[:c[2]] + s[c[3]:]
            sets = len(re.findall(r"(?<![\w$])" + name + r"(?:\[[^\]\n]*\])?\+?=", rest))
            if sets <= temp.get(name, 0) and not re.search(SH_BINDERS.format(name), rest):
                names.add(name)
        memo = {}

        def var(n, before, seen=()):
            c = cands.get(n)
            if n not in names or n in seen or c[2] >= before:
                return None
            if n not in memo:
                memo[n] = self.sh_word(c[0], c[1], lambda x: var(x, before, seen + (n,)), script, True)[0]
            return memo[n]

        for (d, t), p in zip(cmds, parts):
            target = self.sh_source_target(t)
            if target is None:
                continue
            v = self.sh_word(target, d, lambda n, at=p["start"]: var(n, at), script, False)
            path = v[0] and not v[1] and os.path.join(os.path.abspath(d or os.getcwd()), v[0])
            if not path or not os.path.isfile(path):
                return set()
            names -= self.sh_bound_in(path, names, var, 0, set())
        return names

    def sh_source_target(self, t):
        """The raw word a source or . command names, or None for any other command."""
        rest, _ = self.sw.command_rest(t)
        rest = rest.lstrip()
        end = self.sh_word_end(rest, 0)
        if rest[:end] not in ("source", "."):
            return None
        start = len(rest) - len(rest[end:].lstrip())
        return rest[start:self.sh_word_end(rest, start)] or None

    def sh_bound_in(self, path, names, var, depth, seen):
        """The names a sourced file binds, it or a file it sources whose path can be worked out."""
        real = os.path.realpath(path)
        if real in seen or depth > MAX_DEPTH:
            return set()
        seen.add(real)
        try:
            with open(real, "rb") as f:
                text = f.read(MAX_FILE).decode("utf-8", "replace")
        except OSError:
            return set(names)
        bound = {n for n in names if re.search(r"(?<![\w$])" + n + r"(?:\[[^\]\n]*\])?\+?=", text)
                 or re.search(SH_BINDERS.format(n), text)}
        try:
            cmds = self.sw.commands(text, os.path.dirname(real))
        except Exception:
            return bound
        for d, t in cmds:
            target = self.sh_source_target(t)
            if target is None:
                continue
            v = self.sh_word(target, d, lambda n: var(n, float("inf")), path, False)
            if v[0] and not v[1]:
                nested = os.path.join(os.path.abspath(d or os.getcwd()), v[0])
                if os.path.isfile(nested):
                    bound |= self.sh_bound_in(nested, names, var, depth + 1, seen)
        return bound

    def py_args(self, text, name, d):
        """(sys.argv, the variables in os.environ) for the python command text runs, as far as they are
        certain: an argv entry is None where it is not, and every entry after one that can become
        other than one word; argv itself is None where which word is the script is not certain."""
        words, k, toks = [], 0, self.sh_tokens(text)
        while k < len(toks):
            kind, raw = toks[k]
            if kind == "op":
                if not SH_REDIRECT.fullmatch(raw):
                    break
                k += 2
                continue
            words.append(raw)
            k += 1
        script = self.shell["script"]
        vals = [self.sh_word(w, d, self.sh_var, script, False) for w in words]
        at = next((i for i, (v, sp) in enumerate(vals) if v is not None and not sp and os.path.basename(v) == name), None)
        if at is None:
            return None, {}
        env = {n: self.sh_var(n) for n in self.shell["exported"]}
        for (v, sp), w in zip(vals[:at], words[:at]):
            m = re.match(r"([A-Za-z_]\w*)=", w)
            if m:
                env[m.group(1)] = self.sh_word(w[m.end():], d, self.sh_var, script, True)[0]
            elif v is None or v.startswith("-"):
                env = {}  # env -i, env -u and the like: what it leaves is not worked out here
        j, argv = at + 1, None
        while j < len(vals):
            v, sp = vals[j]
            if v is None or sp:
                return None, env
            if v == "--":
                j += 1
                if j >= len(vals) or vals[j][0] is None or vals[j][1]:
                    return None, env
                argv, j = [vals[j][0]], j + 1
                break
            if v == "-" or not v.startswith("-"):
                argv, j = [v], j + 1
                break
            if v.startswith("--"):
                j += 2 if v == "--check-hash-based-pycs" else 1
                continue
            letters, step = v[1:], 1
            for i, ch in enumerate(letters):
                if ch == "m":
                    return None, env
                if ch == "c":
                    argv, step = ["-c"], 1 if letters[i + 1:] else 2
                    break
                if ch in "WX":
                    step = 1 if letters[i + 1:] else 2
                    break
            j += step
            if argv:
                break
        if argv is None:
            return ([""] if j >= len(vals) else None), env
        for v, sp in vals[j:]:
            if sp:
                break
            argv.append(v)
        return argv, env

    def sh_tokens(self, s):
        """s's words and operators, as (kind, raw text), up to the first unquoted line break."""
        out, i, n = [], 0, len(s)
        while i < n:
            c = s[i]
            if c == "\n":
                break
            if c.isspace():
                i += 1
                continue
            m = SH_REDIRECT.match(s, i)
            if m:
                out.append(("op", m.group(0)))
                i = m.end()
                continue
            m = re.match(r"&&|\|\||;;|[;&|()]", s[i:])
            if m:
                out.append(("op", m.group(0)))
                i += len(m.group(0))
                continue
            end = self.sh_word_end(s, i)
            out.append(("word", s[i:end]))
            i = max(end, i + 1)
        return out

    @staticmethod
    def sh_close(s, i):
        """The index of the ) closing the $( that ends just before i, or None."""
        dq, n = False, len(s)
        while i < n:
            c = s[i]
            if c == "\\":
                i += 2
                continue
            if c == "'" and not dq:
                j = s.find("'", i + 1)
                if j < 0:
                    return None
                i = j + 1
                continue
            if c == '"':
                dq = not dq
            elif s.startswith("$(", i):
                j = Judge.sh_close(s, i + 2)
                if j is None:
                    return None
                i = j
            elif c == ")" and not dq:
                return i
            elif c == "(" and not dq:
                return None  # a subshell or a case pattern inside: not a form worked out here
            i += 1
        return None

    def sh_word_end(self, s, i):
        """Where the shell word starting at i ends: at unquoted space or an operator."""
        dq, n = False, len(s)
        while i < n:
            c = s[i]
            if c == "\\":
                i += 2
                continue
            if c == "'" and not dq:
                j = s.find("'", i + 1)
                if j < 0:
                    return n
                i = j + 1
                continue
            if c == '"':
                dq = not dq
            elif s.startswith("$(", i):
                j = self.sh_close(s, i + 2)
                if j is None:
                    return n
                i = j
            elif s.startswith("${", i):
                j = s.find("}", i)
                if j < 0:
                    return n
                i = j
            elif not dq and (c.isspace() or c in ";&|<>()"):
                return i
            i += 1
        return n

    def sh_word(self, raw, d, var, script, assign):
        """(the value of one raw shell word, or None where it is not certain; whether it can become
        other than one word). assign is True for a NAME=value's value, which is not split or globbed."""
        out, i, n, dq = [], 0, len(raw), False
        unknown = splits = False
        while i < n:
            c = raw[i]
            if c == '"':
                dq = not dq
                i += 1
                continue
            if c == "'" and not dq:
                j = raw.find("'", i + 1)
                if j < 0:
                    return None, True
                out.append(raw[i + 1:j])
                i = j + 1
                continue
            if c in "\\`":
                return None, True
            if c == "$":
                if raw.startswith("$(", i) and not raw.startswith("$((", i):
                    j = self.sh_close(raw, i + 2)
                    if j is None:
                        return None, True
                    v, i = self.sh_subst(raw[i + 2:j], d, var, script), j + 1
                else:
                    m = SH_PARAM.match(raw, i)
                    if not m:
                        return None, True
                    p, i = m.group(1) if m.group(1) is not None else m.group(2), m.end()
                    if p in ("@", "*") or "[@]" in p or "[*]" in p or p.startswith(("!", "#")):
                        return None, True  # as many words as there are values
                    v = script if p in ("BASH_SOURCE", "BASH_SOURCE[0]") else (
                        var(p) if re.fullmatch(r"[A-Za-z_]\w*", p) else None)
                if v is None:
                    unknown = True
                    splits = splits or not (dq or assign)
                elif not (dq or assign) and (not v or re.search(r"[\s*?\[]", v)):
                    return None, True
                else:
                    out.append(v)
                continue
            if not dq and (c.isspace() or c in ";&|<>(){}*?[~"):
                return None, True
            out.append(c)
            i += 1
        if dq:
            return None, True
        return (None if unknown else "".join(out)), splits

    def sh_subst(self, body, d, var, script):
        """What $(body) prints, for $(pwd), $(dirname X) and $(cd X && pwd); None for anything else,
        and where cd would fail."""
        if "\n" in body.strip():
            return None  # more than one line of commands: sh_tokens would read only the first
        toks = self.sh_tokens(body.strip())
        if any(k == "op" and t != "&&" for k, t in toks):
            return None
        vals = []
        for k, t in toks:
            if k == "op":
                vals.append(t)
                continue
            v, sp = self.sh_word(t, d, var, script, False)
            if v is None or sp:
                return None
            vals.append(v)
        here = os.path.abspath(d or os.getcwd())
        if vals in (["pwd"], ["pwd", "-P"]):
            return here if len(vals) == 1 else os.path.realpath(here)
        if len(vals) == 2 and vals[0] == "dirname":
            p = vals[1].rstrip("/")
            if not vals[1]:
                return "."
            if not p:
                return "/"
            return (p[:p.rfind("/")].rstrip("/") or "/") if "/" in p else "."
        if len(vals) in (4, 5) and vals[0] == "cd" and vals[2:4] == ["&&", "pwd"] and vals[4:] in ([], ["-P"]):
            target = vals[1]
            if not target or target.startswith("-") or (os.environ.get("CDPATH") and not os.path.isabs(target)
                                                         and not target.startswith((".", "/"))):
                return None
            p = os.path.normpath(os.path.join(here, os.path.expanduser(target) if target.startswith("~") else target))
            if not os.path.isdir(p):
                return None
            return os.path.realpath(p) if vals[4:] else p
        return None

    @staticmethod
    def resolve_in(base, level, module, names):
        """resolve_py() under one folder: the files, or None when the import's first part is not
        there, or False for a part after it that is missing."""
        parts = [p for p in module.split(".") if p]
        found, d = [], base
        for i, part in enumerate(parts):
            p = os.path.join(d, part)
            if os.path.isfile(p + ".py"):
                found.append(p + ".py")
                return found  # a module: what follows its name is an attribute, not a file
            if os.path.isdir(p):
                if os.path.isfile(os.path.join(p, "__init__.py")):
                    found.append(os.path.join(p, "__init__.py"))
                d = p
                continue
            return False if (level or i) else None
        if level and not parts and os.path.isfile(os.path.join(d, "__init__.py")):
            found.append(os.path.join(d, "__init__.py"))
        for n in names:
            if n == "*":
                continue
            p = os.path.join(d, n)
            if os.path.isfile(p + ".py"):
                found.append(p + ".py")
            elif os.path.isfile(os.path.join(p, "__init__.py")):
                found.append(os.path.join(p, "__init__.py"))
            elif level and not parts and not os.path.isfile(os.path.join(d, "__init__.py")):
                return False  # `from . import n` with no module n and no package to hold it
        return found

    @staticmethod
    def resolve_import(spec, base):
        """The file a relative or absolute import names, False when none is there, or None for a
        package or a node builtin. Tried as node and TypeScript do: the path itself, with each
        extension, the .ts a .js names, a folder's package.json main, and a folder's index."""
        spec = spec.split("?", 1)[0]
        if spec.startswith("file://"):
            spec = spec[len("file://"):]
        if not (spec.startswith("./") or spec.startswith("../") or spec in (".", "..") or spec.startswith("/")):
            return None
        p = os.path.normpath(os.path.join(base, spec))
        stem, ext = os.path.splitext(p)
        tries = [p] + [p + e for e in JS_EXT + (".json",)] + [stem + e for e in JS_TO_TS.get(ext, ())]
        if os.path.isdir(p):
            try:
                with open(os.path.join(p, "package.json"), "rb") as f:
                    main = json.loads(f.read(MAX_FILE).decode("utf-8", "replace")).get("main")
                if isinstance(main, str) and main:
                    m = os.path.normpath(os.path.join(p, main))
                    tries += [m] + [m + e for e in JS_EXT] + [os.path.join(m, "index" + e) for e in JS_EXT]
            except (OSError, ValueError, AttributeError):
                pass
            tries += [os.path.join(p, "index" + e) for e in JS_EXT + (".json",)]
        for t in tries:
            if os.path.isfile(t):
                return t
        return False

    def line(self, s, cwd, depth, whole):
        """The reason a command line posts, or None. Its shell variables are its own: a script read
        here starts with none, and the caller's are back once it is read."""
        saved, self.shell = self.shell, self.shell_scope(s, cwd, self.next_script)
        self.next_script = None
        try:
            for d, text, wrapper, why, _ in self.sw.every_command(s, cwd):
                reason = self.record(d, text, wrapper, why, depth, whole)
                if reason:
                    return reason
            return None
        finally:
            self.shell = saved

    def record(self, d, text, wrapper, why, depth, whole):
        """judge() for one command, with py_cmd set to where the Python it starts looks for imports:
        its own PYTHONPATH assignment (env's too), else one exported earlier in the line, else the
        session's (claude-config#2358). Put back afterwards, so a script read as commands inside it
        does not change what the rest of this command is judged with."""
        rest, assigns = self.sw.command_rest(text)
        words = self.sw.command_words(rest)
        self.sh_note(text, words, assigns, d)
        value = None
        for a in assigns.split("\n"):
            for w in self.sw.command_words(a) if a.strip() else ():
                if w.startswith("PYTHONPATH="):
                    value = self.sh_pythonpath(w[len("PYTHONPATH="):], text, d)
        if words and words[0] == "export":
            for w in words[1:]:
                if w.startswith("PYTHONPATH="):
                    self.exported = self.py_path(self.sh_pythonpath(w[len("PYTHONPATH="):], text, d), d)
        elif not words and value is not None:
            self.exported = self.py_path(value, d)
        here = os.path.abspath(d or os.getcwd())
        if value is not None:
            path = self.py_path(value, d)
        elif self.exported is not None:
            path = self.exported
        else:
            path = self.py_path(os.environ.get("PYTHONPATH", ""), d)
        interp = next((w for w in words[:3] if PY_RUNTIME.match(os.path.basename(w))), None)
        saved, self.py_cmd = self.py_cmd, {"path": path, "cwd": here, "interp": interp}
        # An export read inside a script this command runs in its own shell ends with that shell; one
        # read inside a sourced script (`source`, `.`) really exports into the caller, so it is kept
        # (claude-config#2409).
        sourced = bool(words) and words[0] in ("source", ".")
        saved_exported = self.exported
        try:
            return self.judge(d, text, wrapper, why, depth, whole)
        finally:
            self.py_cmd = saved
            if not sourced:
                self.exported = saved_exported

    def judge(self, d, text, wrapper, why, depth, whole):
        sw = self.sw
        rest, _ = sw.command_rest(text)
        words = sw.command_words(rest)
        if not words:
            return None
        name = os.path.basename(words[0])
        if name in LAUNCHERS or (name == "uv" and len(words) > 1 and words[1] == "run"):
            k = 2 if name == "uv" else 1
            while k < len(words) and words[k].startswith("-"):
                k += 1
            words = words[k:]
            if not words:
                return None
            name = os.path.basename(words[0])
        if name in PACKAGERS:
            return self.package(name, words, d, depth)
        hit = MARKER.search(text)
        if name in SENDERS:
            if hit:
                return f"{name} sends a request to {hit.group(0)}"
            if "$" in rest:
                hit = MARKER.search(whole)
                if hit:
                    return f"{name} sends a request whose address comes from a variable, and the command names {hit.group(0)}"
            return None
        if name in SHELLS:
            if wrapper.endswith(" -c") and not why:
                return None  # its string's commands are the records after this one
            operand, inline, stdin = self.operands(words)
            if inline or (wrapper.endswith(" -c") and why):
                return f"{name} -c runs a string naming {hit.group(0)}" if hit else None
            reason = self.every_file(words, d, depth, True)
            if reason:
                return reason
            if operand and operand != "-":
                return None  # read above with every other word naming a file
            fed, is_body = self.fed(text, whole)
            if is_body and depth < MAX_DEPTH:
                try:
                    inner = self.line(fed, d, depth + 1, fed)
                    return f"{name} runs commands from its input, one of which posts: {inner}" if inner else None
                except Exception:
                    pass
            hit = MARKER.search(fed)
            return f"{name} reads commands from its input, which names {hit.group(0)}" if hit else None
        if INTERPRETER.match(name):
            if hit:
                return f"{name} runs code naming {hit.group(0)}"
            operand, inline, stdin = self.operands(words)
            lang = "js" if JS_RUNTIME.match(name) else "py" if PY_RUNTIME.match(name) else None
            here = os.path.abspath(d or os.getcwd())
            if lang == "py":
                # What sys.argv and os.environ hold, for a sys.path change built from them (#2449).
                self.py_cmd["argv"], self.py_cmd["env"] = self.py_args(text, name, d)
            if inline:
                # The code imports from the directory it runs in (claude-config#2318).
                code = next((words[k + 1] for k in range(1, len(words) - 1)
                             if words[k] in INLINE or INLINE_CLUSTER.match(words[k])), text)
                return self.imports(f"the code given to {name}", None, here, code, lang) if lang else None
            if "-m" not in words[1:]:
                reason = self.every_file(words, d, depth, False, lang)
                if reason:
                    return reason
            if operand and operand != "-":
                return None  # read above with every other word naming a file
            if stdin:
                fed = self.fed(text, whole)[0]
                hit = MARKER.search(fed)
                if hit:
                    return f"{name} runs a script from its input that names {hit.group(0)}"
                return self.imports(f"the script {name} reads from its input", None, here, fed, lang) if lang else None
            return None
        if name in ("source", "."):
            return self.script(words[1], d, depth, True) if len(words) > 1 else None
        if "/" in words[0]:
            if hit:
                return f"{words[0]} is run with {hit.group(0)} in its arguments"
            # Its arguments are read as they are for the interpreter its #! names, so `./post.mjs
            # msg.json` is judged as `node post.mjs msg.json` is (claude-config#2400): the script
            # first, then each file it is handed, the data files by what the script does with them.
            # A program with no #! (compiled, like a copy of cat or jq) is not a script the gate reads,
            # so the files it is handed stay unread, as for one run by bare name (lessons review at
            # b3c887d): reading them would refuse it over any file naming an endpoint.
            path = self.resolve(words[0], d)
            try:
                with open(path, "rb") as f:
                    first = f.readline(512).decode("utf-8", "replace")
            except OSError:
                first = ""
            shell = path.endswith(SHELL_EXT) or bool(SHELL_BANG.match(first))
            if not (shell or first.startswith("#!")):
                return self.script(words[0], d, depth, False)
            lang = "js" if JS_BANG.match(first) else "py" if PY_BANG.match(first) else None
            return self.every_file([words[0]] + words, d, depth, shell, lang)
        return None

    def every_file(self, words, d, depth, shell_hint, lang=None):
        """The reason any word after the program that names a file posts, or None.

        Which word is the script depends on each program's own option table (python3 -I takes no
        value, ruby -I does), and a table that is wrong for one program hides the script behind an
        option. So every word naming a file is read, which can only refuse more (lessons review,
        2026-11-05, round 3).

        Except a file a script is handed as DATA (claude-config#2362): one after the first word naming
        a file (always read as code), shaped like data (data_shaped), is an argument a script reads,
        not code the program runs, so text in it naming an endpoint is not a send. Which of the files
        read as code is the script is the same option table question, so a data file is judged
        against EVERY one of them, wherever each stands (in `node --require ./a.js post.mjs msg.json`
        the script is post.mjs, not the first file; lessons review, 2026-11-07), and is still read when
        any of them can act on it as more than data (acts): sending a request, whose address the file
        can hold, or running code, which the file can be."""
        code, data = [], []
        for w in words[1:]:
            if w.startswith("-") or w.startswith("+") or self.sw.REDIRECT_WORD.match(w):
                continue
            path = self.resolve(w, d)
            if not os.path.isfile(path):
                continue
            if code and self.data_shaped(path):
                data.append((w, path))
                continue
            reason = self.script(w, d, depth, shell_hint, lang)
            if reason:
                return reason
            code.append((w, path))
        for w, path in data:
            try:
                with open(path, "rb") as f:
                    hit = MARKER.search(f.read(MAX_FILE).decode("utf-8", "replace"))
            except OSError:
                continue  # unreadable to us is unreadable to the script that would read it
            if not hit:
                continue
            for script_word, script_path in code:
                acts = self.acts(script_path, d, shell_hint, lang)
                if acts:
                    return f"the script {script_word} {acts}, and is handed {w}, which names {hit.group(0)}"
            # Data every script beside it only reads; none sends or runs what it is handed.
        return None

    @staticmethod
    def data_shaped(path):
        """Whether a file is shaped like data rather than a script: an extension none of the programs
        this gate reads runs (CODE_EXT), and no #! line."""
        ext = os.path.splitext(path)[1].lower()
        if not ext or ext in CODE_EXT:
            return False
        try:
            with open(path, "rb") as f:
                return not f.read(2).startswith(b"#!")
        except OSError:
            return True

    def acts(self, path, d, shell_hint, lang):
        """How a script can act on a file it is handed as more than data, as a phrase ("sends a request
        (curl)", "runs the file it is handed (source)"), or None when it only reads what it is handed.

        A shell script acts when one of its commands sends a request, or runs, sources or evals a
        file or command named by the arguments it was handed (or a variable set from them). A
        JavaScript script acts when it, or a local module it imports, names a way to send a request or
        to run code (JS_ACTS). A Python script acts unless it, and every local module it imports, is
        seen to be unable to (py_acts). A script of any other kind, one that cannot be read, and
        one whose imports cannot all be followed are taken to act: only a script seen to do neither
        has its data files left unread. Arguments a script passes on to ANOTHER program are not
        followed there: that program is judged for what it names, not for what it does with them."""
        real = os.path.realpath(path)
        try:
            with open(real, "rb") as f:
                body = f.read(MAX_FILE).decode("utf-8", "replace")
        except OSError:
            return "could not be read to see what it does with its arguments"
        first = body.split("\n", 1)[0]
        if shell_hint or real.endswith(SHELL_EXT) or SHELL_BANG.match(first):
            return self.shell_acts(body, d)
        kind = self.language(real, first, lang)
        if not kind:
            return "is a kind of script the gate does not read for what it does with its arguments"
        root = os.path.dirname(real)
        if kind == "py":
            why = self.py_acts(body, real, root)
            if why:
                return why
        else:
            hit = JS_ACTS.search(body)
            if hit:
                return f"can send a request or run code ({hit.group(0).strip()})"
        for why, _, target, found in self.modules("it", real, root, body, kind):
            if why:
                return f"imports a module the gate cannot follow ({why})"
            if kind == "py":
                inner = self.py_acts(found, target, root)
                if inner:
                    return f"imports {os.path.basename(target)}, which {inner}"
                continue
            hit = JS_ACTS.search(found)
            if hit:
                return f"can send a request or run code through {os.path.basename(target)} ({hit.group(0).strip()})"
        return None

    def py_acts(self, text, cur, root):
        """acts() for one Python file's text (cur its file, root the script's folder): how it can act
        on what it is handed, as a phrase, or None when it is seen unable to.

        It is unable to only when every module it imports from outside the script's own files is in
        PY_INERT, and it uses no builtin in PY_RUNS, no attribute in PY_REACH (or any _private or
        dunder one bar PY_DUNDER_OK), no sys.path, no PY_WRITES method, and no open() or FileType
        whose mode writes. A local module it imports is not judged here: modules() reaches it and
        acts() judges it with this same reading, and an import placed nowhere is refused there. Text
        this python3 cannot parse counts as acting."""
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                tree = ast.parse(text)
        except (SyntaxError, ValueError):
            return "could not be parsed to see what it imports"
        cur_dir = os.path.dirname(cur)
        # Only this file's own sys.path changes: fewer folders in front can only leave an import to be
        # placed in the standard library, where it must then be inert, never the other way.
        inserts = ([], [])
        self.py_inserts(text, cur, inserts)

        nodes = list(ast.walk(tree))
        unknown = "a module the gate does not know to be unable to send a request or run code"
        bound = set()  # each name an import binds, whose attributes are another module's namespace
        restricted = set()  # (a, b) for `import a.b` where only a.b is inert, so a.<other> acts
        for node in nodes:
            if isinstance(node, ast.Import):
                for a in node.names:
                    top = a.name.split(".")[0]
                    bound.add(a.asname or top)
                    if self.resolve_py(0, a.name, (), cur_dir, root, inserts) != []:
                        continue  # local (followed by modules()) or placed nowhere (refused there)
                    if a.name not in PY_INERT and top not in PY_INERT:
                        return f"imports {a.name}, {unknown}"
                    if not a.asname and top not in PY_INERT:
                        restricted.add((top, a.name.split(".")[1]))
            elif isinstance(node, ast.ImportFrom):
                names = tuple(a.name for a in node.names)
                bound.update(a.asname or a.name for a in node.names)
                for n in names:
                    if n in PY_RUNS or n in PY_REACH or n.startswith("_") or n == "*":
                        return f"imports {n} from {node.module or '.'}, which reaches past what the gate reads"
                module = node.module or ""
                if node.level or self.resolve_py(0, module, names, cur_dir, root, inserts) != []:
                    continue
                if module == "sys" and "path" in names:
                    return "changes where Python finds modules (sys.path)"
                if module not in PY_INERT and module.split(".")[0] not in PY_INERT and \
                        not all(f"{module}.{n}" in PY_INERT for n in names):
                    return f"imports {module}, {unknown}"
        # A module's namespace holds the modules it imported (pathlib.os, os.path.os, json.codecs), so
        # an attribute chain from an imported name may not name a standard library module off the list.
        stdlib = set(getattr(sys, "stdlib_module_names", ())) | set(sys.builtin_module_names)
        called = {id(n.func) for n in nodes if isinstance(n, ast.Call)}
        cleared = set()  # id() of each restricted name used as a.<its inert submodule>
        for node in nodes:
            if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and \
                    (node.value.id, node.attr) in restricted:
                cleared.add(id(node.value))
        restricted_names = {top for top, _ in restricted}
        for node in nodes:
            if isinstance(node, ast.Name):
                if node.id in PY_RUNS:
                    return f"can run code or reach past what the gate reads ({node.id})"
                if node.id in PY_REACH - {"modules"}:
                    return f"can evaluate a string as code ({node.id})"
                if node.id in restricted_names and id(node) not in cleared:
                    return f"uses {node.id} for more than {', '.join(sorted(f'{t}.{s}' for t, s in restricted))}"
                if node.id == "open" and id(node) not in called:
                    return "can write a file (open, passed on rather than called)"
            elif isinstance(node, ast.Attribute):
                a = node.attr
                if isinstance(node.value, ast.Name) and node.value.id == "sys" and a == "path":
                    return "changes where Python finds modules (sys.path)"
                if a in PY_REACH or (a.startswith("_") and a not in PY_DUNDER_OK):
                    return f"reaches past what the gate reads ({a})"
                base = node.value
                while isinstance(base, ast.Attribute):
                    base = base.value
                # sys holds no module but sys.modules (refused above), and sys.platform is a string.
                if isinstance(base, ast.Name) and base.id in bound and base.id != "sys" and a in stdlib \
                        and a not in PY_INERT and (base.id, a) not in restricted:
                    return f"reaches the {a} module through {base.id}"
            elif isinstance(node, ast.Call):
                f = node.func
                name = f.id if isinstance(f, ast.Name) else f.attr if isinstance(f, ast.Attribute) else None
                if isinstance(f, ast.Attribute) and name in PY_WRITES:
                    return f"can write a file ({name})"
                if name in ("open", "FileType"):
                    if any(k.arg is None for k in node.keywords) or any(isinstance(x, ast.Starred) for x in node.args):
                        return f"can write a file ({name} given its arguments unpacked)"
                    at = 1 if isinstance(f, ast.Name) and name == "open" else 0
                    mode = next((k.value for k in node.keywords if k.arg == "mode"),
                                node.args[at] if len(node.args) > at else None)
                    if mode is not None and not (isinstance(mode, ast.Constant) and isinstance(mode.value, str)
                                                 and not set(mode.value) & set("wax+")):
                        return f"can write a file ({name} with a mode that writes, or one the gate cannot read)"
        return None

    def shell_acts(self, body, d):
        """acts() for a shell script's body: the first of its commands that sends a request, or runs
        what the script was handed, as a phrase, or None."""
        names = {"OPTARG"} if "getopts" in body else set()
        while True:
            given = POSITIONAL + (r"|\$\{?(?:" + "|".join(sorted(names)) + r")\b" if names else "")
            found = {m.group(1) for m in re.finditer(
                r"(?:^|[\s;&|(])(?:(?:local|readonly|export|declare|typeset)\s+(?:-\w+\s+)*)?([A-Za-z_]\w*)="
                r"[^\n;]*?(?:" + given + ")", body)}
            found |= {m.group(1) for m in re.finditer(
                r"\bfor\s+([A-Za-z_]\w*)\s*(?:;|\n|\s+do\b|\s+in\b[^\n;]*?(?:" + given + "))", body)}
            if found <= names:
                break
            names |= found
        handed = re.compile(given)
        try:
            records = self.sw.every_command(body, d)
        except Exception:
            return "could not be read as commands to see what it does with its arguments"
        for _, text, _, _, _ in records:
            rest, _ = self.sw.command_rest(text)
            words = self.sw.command_words(rest)
            if not words:
                continue
            if re.match(r"[A-Za-z_]\w*(\[[^]]*\])?\+?=", words[0]):
                continue  # an assignment (list+=("$1") too), which runs nothing
            name = os.path.basename(words[0])
            if handed.search(words[0]):
                return f"runs a command named by its arguments ({words[0]})"
            if name in SENDERS:
                return f"sends a request ({name})"
            if name in ("source", ".", "eval"):
                if any(handed.search(w) for w in words[1:]):
                    return f"runs the file it is handed ({name})"
                continue
            if name in SHELLS or INTERPRETER.match(name):
                operand, inline, _ = self.operands(words)
                if inline:
                    code = next((words[k + 1] for k in range(1, len(words) - 1)
                                 if words[k] in INLINE or INLINE_CLUSTER.match(words[k])), "")
                    if handed.search(code):
                        return f"runs code it is handed ({name})"
                elif operand and handed.search(operand):
                    return f"runs the file it is handed ({name})"
        return None

    def package(self, name, words, d, depth):
        """The reason `npm run <script>` (pnpm, yarn) posts, or None.

        A package script is followed the way a shell script is: the nearest package.json at or above
        the directory it runs in (or the one --prefix, -C, --dir or --cwd names) gives the script's
        command, and that command, with its pre and post scripts, is judged as a command line run
        from the package's folder. repo-digest's CLAUDE.md documents `npm run digest` as a local
        command that posts to Slack. `npm exec`, `npm x` and `pnpm dlx` run their words as npx does.
        """
        k, where = 1, d
        while k < len(words) and words[k].startswith("-"):
            opt, eq, val = words[k].partition("=")
            if opt in PKG_DIR_OPTS:
                target = val if eq else (words[k + 1] if k + 1 < len(words) else "")
                where = self.resolve(target, d) if target else where
                k += 1 if eq else 2
                continue
            k += 1
        if k >= len(words):
            return None
        sub = words[k]
        if sub in PKG_EXEC:
            rest = [w for w in words[k + 1:] if w != "--"]
            while rest and rest[0].startswith("-"):
                rest = rest[1:]
            if not rest or depth >= MAX_DEPTH:
                return None
            return self.record(where, " ".join(rest), "", "", depth + 1, " ".join(rest))
        if name == "npm" and sub not in NPM_RUN:
            script = NPM_LIFECYCLE.get(sub)
        else:
            if sub in NPM_RUN:
                k += 1
                while k < len(words) and words[k].startswith("-"):
                    k += 1
                if k >= len(words):
                    return None
            script = words[k]
        if not script:
            return None
        found = self.package_json(where)
        if not found:
            return None
        pkg_dir, body = found
        try:
            scripts = json.loads(body).get("scripts") or {}
            if not isinstance(scripts, dict):
                raise ValueError("scripts is not an object")
        except Exception:
            hit = MARKER.search(body)
            return f"{name} runs a script from a package.json it cannot read, which names {hit.group(0)}" if hit else None
        for key in ("pre" + script, script, "post" + script):
            cmd = scripts.get(key)
            if not isinstance(cmd, str) or depth >= MAX_DEPTH:
                continue
            try:
                inner = self.line(cmd, pkg_dir, depth + 1, cmd)
            except Exception:
                hit = MARKER.search(cmd)
                inner = f"it names {hit.group(0)} and could not be read as commands" if hit else None
            if inner:
                return f"the package script {key} runs a command that posts: {inner}"
        return None

    @staticmethod
    def package_json(where):
        """(the folder, the text) of the nearest package.json at or above where, or None."""
        cur = os.path.abspath(where or os.getcwd())
        while True:
            path = os.path.join(cur, "package.json")
            if os.path.isfile(path):
                try:
                    with open(path, "rb") as f:
                        return cur, f.read(MAX_FILE).decode("utf-8", "replace")
                except OSError:
                    return None  # unreadable to us is unreadable to the package manager
            parent = os.path.dirname(cur)
            if parent == cur:
                return None
            cur = parent

    @staticmethod
    def fed(text, whole):
        """(what a command reading its input is fed, whether that is a heredoc body) for one record.

        A heredoc's body is not in the record's text, so it is cut from the whole line: the lines
        after the one holding this command, up to the delimiter. Otherwise the input comes from the
        pipeline the command sits in, so the line holding it is what feeds it. Where neither can be
        found, the whole line is, which can only refuse more, never less. The same command written
        twice in a script reads the same here, so every place it is written counts.
        """
        lines = whole.split("\n")
        key = text.strip()
        ats = [i for i, ln in enumerate(lines) if key and key in ln]
        if not ats:
            return whole, False
        m = re.search(r"<<-?\s*(['\"]?)([A-Za-z0-9_]+)\1", text)
        if not m:
            return "\n".join(lines[i] for i in ats), False
        bodies = []
        for at in ats:
            body = []
            for ln in lines[at + 1:]:
                if ln.strip() == m.group(2):
                    break
                body.append(ln)
            else:
                return whole, False  # a body never closed: read it all
            bodies.append("\n".join(body))
        return "\n".join(bodies), True

    def operands(self, words):
        """(the script operand or None, whether code is given inline, whether it reads its input).

        A redirection is the shell's, never the program's operand (`bash <<'EOF'` reads its input,
        it runs no file named <<EOF), except that a file fed on stdin with < is the script it reads.
        """
        kept, from_file, k = words[:1], None, 1
        while k < len(words):
            m = self.sw.REDIRECT_WORD.match(words[k])  # the shared reader's, target glued or next
            if not m:
                kept.append(words[k])
                k += 1
                continue
            target = m.group(1) or (words[k + 1] if k + 1 < len(words) else "")
            if re.match(r"\d*<(?![<>&])", words[k]) and target:
                from_file = target
            k += 1 if m.group(1) else 2
        words = kept
        if from_file and len(words) == 1:
            return from_file, False, False
        k = 1
        inline = False
        while k < len(words):
            w = words[k]
            if w == "--":
                k += 1
                break
            if w == "-":
                return "-", False, True
            if w in INLINE or INLINE_CLUSTER.match(w):
                inline = True
                break
            if w == "-m":
                return None, False, False  # a module: nothing on disk named here to read
            if w in VALUED:
                k += 2
                continue
            if w.startswith("-") or w.startswith("+"):
                k += 1
                continue
            break
        if inline:
            return None, True, False
        if k < len(words):
            return words[k], False, False
        return None, False, True


def main():
    # A lone surrogate from the payload, echoed in a reason, must not raise on the way out (#1944).
    sys.stdout.reconfigure(errors="replace")
    raw = sys.stdin.buffer.read().decode("utf-8", "replace")
    try:
        d = json.loads(raw)
    except Exception as e:
        print("unreadable\n" + type(e).__name__)
        return
    if not isinstance(d, dict):
        print("unreadable\nthe payload is not a JSON object")
        return
    tool = d.get("tool_name")
    if not isinstance(tool, str):
        print("unreadable\nthe payload has no tool name")
        return
    if tool.startswith("mcp__") and "slack" in tool.lower():
        reason = judge_tool(tool, d.get("tool_input"))
        print("refuse\n" + reason if reason else "allow")
        return
    if tool != "Bash":
        print("allow")
        return
    ti = d.get("tool_input")
    if not isinstance(ti, dict) or not isinstance(ti.get("command"), str):
        print("unreadable\nthe Bash call's command is not text")
        return
    cmd = ti["command"]
    cwd = d.get("cwd") if isinstance(d.get("cwd"), str) else ""
    reason = Judge(load_reader()).line(cmd, cwd, 0, cmd)
    if reason:
        # A reason ending "so it cannot see what ... run(s)" is an import the gate could not follow, not
        # a post it found, so it says the check could not be made rather than claiming a post.
        lead = ("REFUSED: the gate could not check whether this command posts to Slack: "
                if "so it cannot see what" in reason else "REFUSED: this command posts to Slack: ")
        print("refuse\n" + lead + reason + ". " + draft_advice("with the same channel and thread"))
    else:
        print("allow")


if __name__ == "__main__":
    main()
