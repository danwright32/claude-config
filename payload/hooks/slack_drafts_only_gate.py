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
    path with the interpreter its #! names (claude-config#2400), or is code given inline (python3 -c,
    node -e), which is judged as a script is (claude-config#2439). Which word holds inline code, and so
    which word is the script, is read from each program family's own options (OPTIONS), never one
    table for all of them (claude-config#2439). A script counts as able to send a
    request, run code or write a file unless it is seen to be unable to: a Python script imports only
    modules known to be unable to (PY_INERT) and uses no builtin that runs code; a JavaScript one
    imports only node builtins known to be unable to (JS_INERT) and names no global that sends or runs
    code and no fs method that writes; a shell script hands its arguments only to programs known to
    be unable to send or run code (SH_INERT), to its own functions, or to scripts seen unable to act
    (claude-config#2434). The one script let through is /nudge, at skills/nudge/nudge.py beside this
    hooks folder, by its real path; a copy anywhere else is refused like any other script that posts.

Limits, stated so nobody reads more into a pass than it measured: a JavaScript import of a package or
through a path alias (`@/lib/x`), a Python module in the standard library or installed, a module run
with `python3 -m`, and an import of another language's files are
not followed; a program run by bare name from the PATH is not read; a shell script's data reaching a
program through a pipe, code written into the shell script itself (a heredoc, a -c string), and a
shell script's writes are not counted as acting on a data file; and deliberate obfuscation (an
endpoint assembled from pieces, an import path built at run time) is not the threat this answers.
The threat is a session that means well choosing the quickest way to post.
"""
import ast
import faulthandler
import fnmatch
import functools
import glob
import importlib.machinery
import importlib.util
import json
import os
import re
import signal
import sys
import time
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
# Options whose value is the next word, so it is never taken for the script.
VALUED = {"-m", "-W", "-X", "-r", "--require", "-I", "-i", "--import", "--loader", "-C", "--config", "-o"}
# Each program family's options (claude-config#2439), by the family of its name (family()): the words
# that hold code to run, the letters that end a short cluster holding it (perl -ne, python -Bc, bash
# -lc), and the options whose value is the next word. Inline code is in the command's own text, which
# is judged first, so finding it decides that the program runs no script file, and the word after it
# is the code whose imports are followed (claude-config#2318).
#
# One table for every program misread each one by another's options: -E holds code for perl, so
# python3 -E, ruby -E (an encoding) and bash -e (errexit) ran a script the gate never read, as did php
# -c (an ini file); and -I takes a value for ruby, so python3 -I swallowed -c and the file the code
# reads was taken for the script and refused. A code option a family lacks is the dangerous mistake
# (its script goes unread), so each family lists only its own. A valued option it lacks is not: the
# value is then taken for the script, and every word naming a file is read anyway (every_file), so
# every family but Python, whose options are fixed and few, keeps the shared VALUED.
OPTIONS = {
    "shell": ({"-c"}, "c", VALUED),
    "py": ({"-c"}, "c", {"-W", "-X", "--check-hash-based-pycs"}),
    "js": ({"-e", "--eval", "-p", "--print"}, "ep", VALUED),
    "deno": ({"eval"}, "", VALUED),
    "ruby": ({"-e"}, "e", VALUED),
    "perl": ({"-e", "-E"}, "eE", VALUED),
    "php": ({"-r", "-B", "-R", "-E"}, "", VALUED),
    "osascript": ({"-e"}, "", VALUED),
}
SHELL_EXT = (".sh", ".bash", ".zsh", ".command")
SHELL_BANG = re.compile(r"^#!\s*\S*?(?:/env\s+(?:-\S+\s+)*)?/?(?:\S*/)?(ba|z|da|k)?sh\b")
MAX_FILE = 2 * 1024 * 1024
# How long the gate judges one call before it stops and refuses, saying it ran out of time
# (claude-config#2432). Inside the 15 second timeout settings.hooks.json gives it: Claude Code kills a
# gate at its timeout and, with onFailure block, refuses the call with no reason of the gate's own,
# which read the same as a send. On 2026-11-07 the TO FILE THESE clear line was refused that way on
# every try on the work MacBook, while the gate read the session transcript as a script. The 4
# seconds left are for python3 to start and for the one file being read when the budget passes
# (MAX_FILE read as commands took 2.8 seconds under a profiler at a load average of 222,
# 2026-11-09); test-slack-drafts-only-gate.sh holds the budget to the registered timeout.
BUDGET_SECONDS = 11
# How long the reader runs at all before a watchdog ends it (claude-config#2571). The budget stops
# the walk by raising in it, which cannot happen while the reader is held inside one long call into
# C (measured on 2026-11-10 with Python 3.14: a sum over a long range is such a call, and a
# regular expression that backtracks is not), so a watchdog that needs nothing from the reader
# ends it a little later: still inside the 15 second timeout, with 2 seconds left for the wrapper
# to refuse the call as one it could not judge. test-slack-drafts-only-gate.sh holds it to that.
HARD_STOP_SECONDS = BUDGET_SECONDS + 2
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
# require('x'), and process.getBuiltinModule('x'), which loads a builtin by its name with no require or
# import (claude-config#2476). Read from the code with its comments blanked (js_code): an import written
# in a comment is an example, and following it refused every suite importing a harness that shows one
# (#2397).
IMPORT_SPEC = re.compile(r"""(?:\bfrom|\bimport\s*\(?|\brequire\s*\(|\bgetBuiltinModule\s*\()\s*(['"`])([^'"`\n]+)\1""")
# What can stand before a / that opens a regex literal rather than divides: punctuation, or a keyword.
JS_REGEX_AFTER = set("(,=:[!&|?{};+-*%<>~^")
JS_REGEX_WORDS = {"return", "typeof", "case", "do", "else", "in", "instanceof", "new", "delete", "void",
                  "throw", "yield", "await", "of"}


def js_code(text):
    """js_scan's code alone: the text with its comments blanked."""
    return js_scan(text)[0]


def js_scan(text):
    """(code, quoted): a JavaScript or TypeScript file's text with each // and /* */ comment blanked
    to spaces, its newlines kept, so an import shown in a comment is not read as one
    (claude-config#2397, the rule the alert guard got in #2368: a script is read by the code it runs,
    never a comment); and, for each index of the text, whether it lies inside a string literal or a
    template literal's text (its quotes included, the code inside each ${...} not), so an import
    written inside a string can be told from one written as code (claude-config#2484).

    Strings, template literals (with the code inside each ${...}) and regex literals are stepped
    over, so a // or /* inside one (a URL, a pattern) opens nothing. Every misreading is bounded on
    the side of reading more: a quote left open ends at its line, and a block comment that never
    closes is left as code, since node refuses that file and a /* misread from a pattern must not
    hide every import after it."""
    out = list(text)
    n = len(text)
    quoted = bytearray(n)
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
        index of a ${ (its code is read as code), or n. Each index stepped over is marked quoted."""
        start = k
        while k < n:
            c = text[k]
            if c == "\\":
                k += 2
            elif c == "`":
                k += 1
                break
            elif c == "$" and text.startswith("${", k):
                quoted[start:k + 2] = b"\x01" * (k + 2 - start)
                return k + 2, True
            else:
                k += 1
        k = min(k, n)
        quoted[start:k] = b"\x01" * (k - start)
        return k, False

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
            end = min(k + 1, n)
            quoted[i:end] = b"\x01" * (end - i)
            i = k + 1
            last = c
            continue
        if c == "`":
            quoted[i] = 1
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
    return "".join(out), quoted
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
# can hold), running code (which the file can be), or writing it somewhere that runs later.
#
# A Python script is judged by what cannot act (lessons review at 56b9d7f): a list of the ways to act
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
# A JavaScript or TypeScript script is judged the same way (claude-config#2434): a hand list of ways to
# act (fetch, axios, child_process, ...) missed the request package, worker_threads and dns. So it
# counts as unable to act only when every module it imports from outside its own files is in JS_INERT
# (node builtins that cannot send, run code or write, `node:` prefix or not), and it names none of
# JS_RUNS (the globals that send or run code, and the routes from an object to Function or a loader),
# no require, process.getBuiltinModule or import() of a computed name, and neither of the first two named
# anywhere but in a call on a string (JS_DYNAMIC), and none of JS_WRITES. fs is here for
# reading, as pathlib is for Python, and its writing methods are JS_WRITES. Any package counts as
# able to act. JS_RUNS is read from the text, comments included, which can only refuse more; the
# imports, JS_DYNAMIC and JS_WRITES from the code with comments blanked (js_code), so an import shown
# in a comment is not one (claude-config#2397).
JS_INERT = frozenset({
    "assert", "assert/strict", "buffer", "console", "crypto", "events", "fs", "fs/promises", "os", "path",
    "path/posix", "path/win32", "perf_hooks", "querystring", "readline", "readline/promises", "stream",
    "stream/promises", "string_decoder", "timers", "timers/promises", "url", "util", "zlib"})
JS_RUNS = re.compile(r"\b(fetch|XMLHttpRequest|WebSocket|EventSource|sendBeacon|eval|Function|Worker|SharedWorker|"
                     r"importScripts|Deno|Bun|WebAssembly)\b|\.\s*(constructor|binding|_linkedBinding|dlopen|"
                     r"mainModule)\b")
JS_DYNAMIC = re.compile(r"""\b(require|getBuiltinModule)\b(?!\s*\(\s*['"`])|\bimport\s*\(\s*(?!['"`])""")
# What can run a string as code, so that import text inside a string is an import after all
# (claude-config#2484, signed off by Dan on 2026-11-09: import text in an ordinary string literal is not
# followed, a string handed to something that runs it as code still is). eval, Function and the routes
# to it (.constructor), vm and Module's compiler (and the module builtin, whose hooks rewrite source),
# a Worker (eval: true), Miniflare's script or modules source, a child process (node -e, a shell),
# a data: or blob: URL handed to import() or a Worker, a page evaluating code (puppeteer, playwright,
# jsdom's runScripts), Deno and Bun, the global object reached by a computed name (which reaches eval
# unnamed), plus a require or import() of a computed name (JS_DYNAMIC), which loads a data: URL as
# readily as a file. A string reaches a sink through a variable, a function or another module the gate
# cannot trace, so when any file the walk reaches names one, every string in the walk is followed
# (Judge.modules). Read from the text, comments included, which can only follow more. setTimeout and
# setInterval are not here: node, deno and bun each refuse a string callback (measured 2026-11-09).
JS_SINK = re.compile(r"\b(eval|Function|Worker|SharedWorker|importScripts|ShadowRealm|vm|SourceTextModule|"
                     r"SyntheticModule|runInContext|runInNewContext|runInThisContext|compileFunction|_compile|"
                     r"Module|Miniflare|miniflare|child_process|execSync|execFile|execFileSync|spawn|spawnSync|"
                     r"execa|execaSync|execaNode|execaCommand|zx|shelljs|tinyexec|pty|Deno|Bun|createObjectURL|"
                     r"runScripts|Reflect)\b|['\"`](node:)?module['\"`]|"
                     r"\.\s*(constructor|binding|_linkedBinding|dlopen|mainModule|evaluate|evaluateHandle|"
                     r"evaluateOnNewDocument|addScriptTag|addInitScript|setContent)\b|"
                     r"\b(globalThis|global|self|window)\s*(\?\.\s*)?\[|\b(data|blob):(?:[A-Za-z]+/|['\"`,;])|"
                     r"\$\s*`")
SINK = object()  # what Judge.walk gives on reaching a file that names a JS_SINK
# The hand list this replaced, still read from the text as before, so nothing it refused passes now: a
# word like got or ky refuses a script however it is used, as it did (measured 2026-11-07, 13 of 268
# real scripts were refused only by one of these words).
JS_ACTS = re.compile(r"\b(fetch|axios|got|undici|XMLHttpRequest|WebSocket|ky|superagent|node-fetch|"
                     r"https?\.(request|get)|child_process|execSync|execFileSync|spawnSync|execFile|spawn|"
                     r"eval|Function|vm|Deno\.(run|Command)|Bun\.(spawn|\$))\b|"
                     r"""\b(require|import)\s*\(\s*[^'"`\s)]|['"](node:)?(https?|net|tls|http2|dgram)['"]""")
# fs's methods that write, move or remove a file, or open one to (a stream or a handle). The short
# names a script may define for itself (link, open, rename: repo-digest's format.ts has a link()) count
# where called as a method (`fsp.rm(`, fs reached through a helper too), and called bare only in a
# script that imports fs (JS_FS), where `import { rm } from "fs/promises"` binds them.
JS_WRITES = re.compile(r"\b(writeFile|writeFileSync|appendFile|appendFileSync|createWriteStream|copyFile|"
                       r"copyFileSync|cpSync|renameSync|symlink|symlinkSync|linkSync|chmod|chmodSync|lchmod|"
                       r"lchmodSync|chown|chownSync|lchown|lchownSync|fchmod|fchmodSync|fchown|fchownSync|mkdirSync|"
                       r"mkdtemp|mkdtempSync|rmSync|rmdirSync|unlinkSync|truncateSync|ftruncate|ftruncateSync|"
                       r"utimes|utimesSync|lutimes|lutimesSync|futimes|futimesSync|openSync|writeSync|writev|"
                       r"writevSync)\b")
JS_WRITES_SHORT = re.compile(r"\b(cp|rename|link|mkdir|rm|rmdir|unlink|truncate|open)\s*\(")
JS_WRITES_METHOD = re.compile(r"\.\s*(cp|rename|link|mkdir|rm|rmdir|unlink|truncate|open)\s*\(")
JS_FS = {"fs", "fs/promises"}
# And a shell script (claude-config#2434): a command handed the script's arguments acts unless it is a
# function the script defines (its body is read as the script's own commands), a script the gate
# reads and sees cannot act (acts), code written into the script itself (a heredoc, -c) that is seen
# unable to act in the same way (sh_code_acts, claude-config#2446), or one of
# SH_INERT, builtins and programs that cannot send a request or run code with the words they are
# handed. A list of senders (SENDERS) missed every program off it, gh and nc among them. Unlike a
# Python or JavaScript script, a shell script's writes are not counted: every shell script that keeps
# state writes, with a redirection or by moving a file (issue-spool.sh clear moves each spool file into
# place), so the programs that only copy, move or remove a file (cp, mv, tee, ln, rm) are here too.
SH_INERT = frozenset({
    "[", "[[", ":", "basename", "case", "cat", "cd", "chmod", "cmp", "column", "comm", "cp", "cut", "date", "declare", "diff",
    "dirname", "du", "echo", "egrep", "exit", "export", "expr", "false", "fgrep", "file", "fold", "for", "getopts",
    "grep", "head", "hexdump", "jq", "kill", "ln", "local", "ls", "md5", "md5sum", "mkdir", "mktemp", "mv", "nl", "od",
    "paste", "popd", "printf",
    "pushd", "read", "readlink", "readonly", "realpath", "return", "rev", "rg", "rm", "rmdir", "seq", "set",
    "sha1sum", "sha256sum", "shasum", "shift", "sleep", "sort", "stat", "strings", "tac", "tail", "tee", "test",
    "touch", "tr",
    "true", "typeset", "uniq", "unset", "wait", "wc"})
# git, only for the subcommands that read a repository (issue-spool.sh finds a checkout's common dir
# with rev-parse), and with no option that names a program or setting to run or a file to write.
GIT_INERT = frozenset({"rev-parse", "log", "show", "status", "diff", "ls-files", "ls-tree", "symbolic-ref",
                       "cat-file", "for-each-ref", "merge-base", "rev-list", "describe", "name-rev"})
GIT_RUNS = ("-c", "--config-env", "--exec-path", "--output", "--ext-diff", "--textconv", "-O")
# find, except with -exec and its kind, and awk, unless its program can run a command (awk_runs).
AWKS = {"awk", "gawk", "mawk", "nawk"}
# The folders a program is taken from by the name it has there; anywhere else it is a script of its own.
SYSTEM_BIN = {"/bin", "/usr/bin", "/sbin", "/usr/sbin", "/usr/local/bin", "/opt/homebrew/bin"}
# A shell expansion of the arguments a script was handed: $1 to $9, $@, $*, and their braced forms.
POSITIONAL = r"\$\{?[1-9@*]"
# The same inside code given to a shell with -c, where $0 is the first word after the code.
POSITIONAL_ZERO = r"\$\{?[0-9@*]"
# Code a shell script writes inline and hands its arguments (python3 -c, a heredoc fed to python3 -,
# bash -c) is judged for what it does with them, and what a command pipes on from the file it was
# handed is followed to the command the pipe feeds (claude-config#2446). As for the script itself,
# writing a file is not counted in that code: issue-spool.sh's own heredocs import os and write, and
# its clear line is handed a transcript every turn. So inline Python may also import PY_FILES, and os
# for the names in OS_FILES alone (its file, path and environment calls: none starts a program).
PY_FILES = frozenset({"errno", "io", "stat", "tempfile"})
OS_FILES = frozenset({
    "DirEntry", "F_OK", "O_APPEND", "O_CLOEXEC", "O_CREAT", "O_EXCL", "O_NOFOLLOW", "O_RDONLY", "O_RDWR",
    "O_TRUNC", "O_WRONLY", "PathLike", "R_OK", "W_OK", "X_OK", "access", "altsep", "chmod", "close",
    "cpu_count", "curdir", "devnull", "environ", "environb", "error", "extsep", "fdopen", "fsdecode",
    "fsencode", "fspath", "fstat", "fsync", "get_terminal_size", "getcwd", "getegid", "getenv", "geteuid",
    "getgid", "getloadavg", "getlogin", "getpid", "getppid", "getuid", "isatty", "linesep", "link",
    "listdir", "lstat", "makedirs", "mkdir", "name", "open", "pardir", "path", "pathsep", "read",
    "readlink", "remove", "rename", "replace", "rmdir", "scandir", "sep", "stat", "stat_result",
    "strerror", "symlink", "truncate", "umask", "uname", "unlink", "urandom", "utime", "walk", "write"})
# What a pipe can feed that reads it in commands of its own: a loop, a block, an if, or read.
SH_BLOCK = re.compile(r"\s*(?:while|until|for|if|select|case|time|!|\{)(?=\s|$)|\s*(?:\S+=\S*\s+)*read(?=\s|$)")
# A pipe in a script's text, `||` apart.
SH_PIPE = re.compile(r"(?<!\|)\|(?!\|)")
# What a Python import's folder can be handed through: a shell variable in an argument, PYTHONPATH or
# an exported variable (claude-config#2449). A variable's value is known only where it is certain
# (sh_walk), mostly over the script's straight run of commands at its top; these mark where that stops: a
# compound command, a group, a subshell or a function opening, and every other way a name is bound.
SH_COMPOUND = re.compile(r"^(?:(?:if|then|elif|else|fi|do|done|while|until|for|select|case|esac|function|coproc|time|!)"
                         r"(?=[\s;&|()]|$)|[{}()]|\[\[)")
SH_FUNC_DEF = re.compile(r"^[A-Za-z_][\w:.-]*\s*\(\s*\)")
SH_BINDERS = (r"\b(?:read|for|select|local|declare|typeset|export|readonly|unset|getopts|mapfile|readarray|let|printf)\b"
              r"[^\n;&|]*?(?<![\w$]){0}\b|\$\{{{0}:?=")
# export and readonly with no = keep a name's value, so sh_binds does not count them as binding it.
SH_VALUE_KEPT = re.compile(r"(?:export|readonly)\b")


# The three patterns Judge.sh_binds reads a name by, compiled once per name for the life of the run:
# NAME=, NAME+= and NAME[i]=; NAME inside (( )); and the builtins that bind a name. re keeps only 512
# compiled patterns, and one script can have thousands of names (claude-config#2569).
@functools.lru_cache(maxsize=None)
def sh_bind_patterns(name):
    n = re.escape(name)
    return (re.compile(r"(?<![\w$])" + n + r"(?:\[[^\]\n]*\])?\+?="),
            re.compile(r"\(\([^()]*(?<![\w$])" + n + r"\b"),
            re.compile(SH_BINDERS.format(n)))


# The builtins after which a NAME=value in front of them outlives the command (POSIX special builtins,
# and those that bind names), so it is an assignment like any other.
SH_SPECIAL = frozenset({":", ".", "source", "break", "continue", "eval", "exec", "exit", "export", "readonly",
                        "return", "set", "shift", "trap", "unset", "times", "local", "declare", "typeset"})
# A parameter expansion: ${...} (its whole inside) or $NAME, $1, $@ and the other one character names.
SH_PARAM = re.compile(r"\$(?:\{([^{}]*)\}|([A-Za-z_]\w*|[0-9@*#?$!-]))")
# Where a redirection starts in a command's text, its target the word after it.
SH_REDIRECT = re.compile(r"\d*(?:<<-|<<<|<<|<>|>>|>&|<&|&>>|&>|>\||<|>)")
# A directory the resolver does not know (claude-config#2465): where a command runs when that is not
# certain, as inside a function, which runs wherever it is called from, or after a cd that can fail.
# It holds a $, so nothing takes it for a real path.
SH_UNKNOWN_DIR = "${unknown directory}"
# The builtins that cannot change a shell variable, the only commands a `local` value is taken across
# (claude-config#2465): any other command can be a function, and a function can set its caller's
# local. printf is one only without -v.
SH_KEEPS = frozenset({"[", "[[", "test", ":", "true", "false", "echo", "printf", "return", "exit", "cd", "pwd"})
# A parameter expansion the resolver works out: the name (BASH_SOURCE[0] too), then nothing, a
# default (:- or -), or a pattern removed from either end (% %% # ##).
SH_EXPANSION = re.compile(r"(BASH_SOURCE(?:\[0\])?|[A-Za-z_]\w*)(?:(:?-)(.*)|(%%?|##?)(.*))?", re.S)


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


class OutOfTime(BaseException):
    """Raised by Judge.late once the budget has passed (from tick, at the points the walk looks at
    the clock, and from the budget's timer, on whatever line the walk is on, claude-config#2571),
    carrying what the walk was doing, as the phrase out_of_time() puts after "while". A
    BaseException, so the `except Exception` around a
    script read as commands (script_body) and every other one in the walk lets it through to main()
    rather than reading it as a script that could not be parsed."""

    def __init__(self, doing):
        super().__init__(doing)
        self.doing = doing


def budget_clock():
    """(clock, budget): the clock the walk is timed by and the budget it is held to. Real seconds
    (BUDGET_SECONDS on time.monotonic), except under a test run (HOOK_TESTS_RUNNING=1, the rule the
    merge helper's seams follow, claude-config#2428), where SLACK_GATE_TICK_BUDGET, a whole number,
    makes the clock count the gate's steps and the budget that many steps (L524), so a suite decides
    a case by how much the gate reads rather than by the Mac's load. Outside a test run that setting
    is ignored, so it cannot loosen or tighten the installed gate."""
    ticks = os.environ.get("SLACK_GATE_TICK_BUDGET", "")
    if os.environ.get("HOOK_TESTS_RUNNING") == "1" and ticks.isdigit() and int(ticks) > 0:
        count = [0]

        def step():
            count[0] += 1
            return count[0]
        return step, int(ticks)
    return time.monotonic, BUDGET_SECONDS


class Judge:
    def __init__(self, sw):
        self.sw = sw
        # The walk's clock and budget (budget_clock), the moment it started, and the script whose
        # commands are being judged (None for the command line itself), for the refusal late()
        # raises, from tick() and from the budget's timer (claude-config#2432, #2571).
        self.clock, self.budget = budget_clock()
        self.started = self.clock()
        self.walking = None
        self.overran = None  # the OutOfTime the budget's timer raised, if it fired (interrupt)
        nudge = os.path.join(os.path.dirname(HERE), "skills", "nudge", "nudge.py")
        self.nudge = os.path.realpath(nudge) if os.path.isfile(nudge) else None
        self.acting = set()  # the real path of each script acts() is judging, so a cycle ends
        self.unfollowed = None  # the last import modules() could not follow (unfollow)
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
        # Whether the directory the next text line() reads starts in is certain (claude-config#2465):
        # a script run or sourced from inside a function starts wherever that function was called.
        self.next_cwd_known = True
        self.known_memo = {}
        self.binds_memo = {}  # {a sourced file's text: {name: whether it binds it}}, for sh_bound_in
        self.parsed_memo = {}  # {(text, directory): (its commands, where each is)}, for parsed

    @staticmethod
    def shell_scope(text, cwd, script, cwd_known=True):
        """A fresh record of one text's variables: each NAME=value command read so far (pending, its
        text and directory), the names exported, the offset in the text of the command being read
        (at), whether the directory the text starts in is certain, and what sh_walk finds certain
        about its variables, worked out the first time one is asked for."""
        return {"text": text, "cwd": cwd, "script": script, "pending": {}, "exported": set(), "at": None,
                "cwd_known": cwd_known, "known": None}

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

    def tick(self, reading=None):
        """One step of the walk: each command judged (record, no argument) and each file about to be
        read whole (its path). Raises OutOfTime once the budget has passed, so the gate refuses with
        its own reason inside its timeout rather than being killed at it, saying which file it was
        about to read, or whose commands it was judging."""
        if self.clock() - self.started <= self.budget:
            return
        self.late(reading)

    # What tick raises once the budget has passed: OutOfTime, saying what the walk was doing.
    def late(self, reading=None):
        if reading is not None:
            raise OutOfTime(f"about to read {self.sized(reading)}")
        if self.walking is not None:
            raise OutOfTime(f"judging the commands in {self.sized(self.walking)}")
        raise OutOfTime("judging the command line itself")

    # On the real clock, have the budget interrupt the walk wherever it is (claude-config#2571).
    # tick looks at the clock only between commands and before each file, so the work inside one
    # file's walk was never timed: on 2026-11-09 one script's walk took 41 s of processor time
    # (#2569), the budget passed unseen, and Claude Code killed the hook with no reason given. A
    # timer set for the moment the budget passes raises the same OutOfTime from whatever line the
    # walk is on, in every loop there is rather than in the ones somebody remembered to time. The
    # step clock a test run counts by is left as it was: it has no moment to set a timer for.
    def watch(self):
        if self.clock is time.monotonic and hasattr(signal, "setitimer"):
            signal.signal(signal.SIGALRM, self.interrupt)
            signal.setitimer(signal.ITIMER_REAL, max(self.budget - (self.clock() - self.started), 0.001))

    # The timer's handler. It keeps what it raises (self.overran) as well as raising it, because an
    # exception raised from a timer lands on whatever line is running, and that can be code that
    # discards it (a finaliser, a library's own handler), after which the walk would carry on from
    # a step that never finished and could answer that nothing posts. main() refuses on what is
    # kept here whatever the walk went on to answer, so a walk the budget interrupted is never
    # allowed.
    def interrupt(self, signum, frame):
        try:
            self.late()
        except OutOfTime as e:
            self.overran = e
            raise

    # The walk is over: the timer is taken off, so it cannot raise in what main() does next.
    def unwatch(self):
        if self.clock is time.monotonic and hasattr(signal, "setitimer"):
            signal.setitimer(signal.ITIMER_REAL, 0)

    @staticmethod
    def sized(path):
        """A path with its size, for the refusal; the path alone when its size cannot be read."""
        try:
            return f"{path} ({os.path.getsize(path)} bytes)"
        except OSError:
            return path

    def out_of_time(self, doing):
        """The refusal for a walk that ran past its budget: it says the gate ran out of time, what it
        was doing (OutOfTime.doing), and that this is no finding that the call posts (L11)."""
        spent = (f"{BUDGET_SECONDS} seconds" if self.budget == BUDGET_SECONDS and self.clock is time.monotonic
                 else f"its budget of {self.budget} step{'' if self.budget == 1 else 's'}")
        return (f"BLOCKED: slack-drafts-only-gate.sh ran out of time judging this call: it stopped after "
                f"{spent}, inside the time limit Claude Code gives it, while {doing}. Whether this "
                f"command sends a Slack message was not checked, and this is not a finding that it does "
                f"(claude-config#2432). Run it again once the Mac is less busy. If it is refused the same "
                f"way again, the gate is reading more than it can judge in time (a large file with no "
                f"extension handed to a script is read as a script): say so to Dan. To put a message in "
                f"Slack, call slack_send_message_draft instead.")

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
        self.tick(path)
        walking, self.walking = self.walking, path
        try:
            return self.script_body(word, path, real, d, depth, shell_hint, lang)
        finally:
            self.walking = walking  # once read, back to the commands of the file that ran it

    def script_body(self, word, path, real, d, depth, shell_hint, lang):
        """script() for a file that is there and is not /nudge."""
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
            # Only a text the reader itself says it cannot read (its Unreadable) is judged by what
            # it names. Any other error is a fault in this gate's own walk, which has judged
            # nothing, so it is left to end the reader, and the wrapper refuses the call as one it
            # could not judge (claude-config#2573: with sh_binds raising AttributeError, a script
            # naming no endpoint passed here whatever it went on to source).
            try:
                self.next_script = word  # its BASH_SOURCE, as written in the command (claude-config#2449)
                self.next_cwd_known = self.sh_cwd(d) != SH_UNKNOWN_DIR
                inner = self.line(body, d, depth + 1, body)
            except self.sw.Unreadable:
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
        The one walk both imports() and acts() read, so the two cannot disagree about what is reached.

        A JavaScript walk first leaves out import text written inside a string literal, which nothing
        loads (claude-config#2484). Where any file it reaches can run a string as code (JS_SINK,
        JS_DYNAMIC), it starts again following every string, as every walk did before, and gives only
        the modules the first walk had not, so each is still given once."""
        if kind != "js":
            yield from self.walk(start, origin, root, body, kind, True)
            return
        given = set()
        for item in self.walk(start, origin, root, body, kind, False):
            if item is SINK:
                break
            if item[2]:
                given.add(item[2])
            yield item
        else:
            return
        for item in self.walk(start, origin, root, body, kind, True):
            if item[2] in given:
                continue
            yield item

    def walk(self, start, origin, root, body, kind, strings):
        """modules() with import text inside JavaScript strings followed or not (strings); not
        following them, it gives SINK, and stops, on reaching a file that can run a string as code."""
        seen = {origin} if origin else set()
        queue = [(origin, root, body, start)]
        inserts = ([], [])  # the folders a sys.path change puts in front of the rest, and behind them
        while queue:
            cur, cur_dir, text, chain = queue.pop(0)
            if kind == "py":
                self.py_inserts(text, cur, inserts)
            elif not strings and (JS_SINK.search(text) or JS_DYNAMIC.search(js_code(text))):
                yield SINK
                return
            for spec, targets in self.import_targets(text, kind, cur_dir, root, inserts, strings):
                via = f"{chain}, which imports {spec}"
                if targets is False:
                    where = ("" if kind != "py" or spec.startswith(".") else
                             " beside the script, on its PYTHONPATH or sys.path, in the standard library or installed")
                    yield self.unfollow(f"{via}, a module the gate cannot find{where}, so it cannot see what that "
                                        "runs"), None, None, None
                    return
                for target in targets:
                    target = os.path.realpath(target)
                    if target in seen:
                        continue
                    seen.add(target)
                    if len(seen) > IMPORT_MAX_FILES:
                        yield self.unfollow(f"{start} imports more than {IMPORT_MAX_FILES} modules, past what "
                                            "the gate reads, so it cannot see what they run"), None, None, None
                        return
                    self.tick(target)
                    try:
                        with open(target, "rb") as f:
                            found = f.read(MAX_FILE).decode("utf-8", "replace")
                    except OSError:
                        yield self.unfollow(f"{via} ({target}), a module the gate cannot read, so it cannot "
                                            "see what that runs"), None, None, None
                        return
                    yield None, via, target, found
                    queue.append((target, os.path.dirname(target), found, f"{via} ({os.path.basename(target)})"))

    def unfollow(self, why):
        """Record why that an import could not be followed, for main() to say the check could not be
        made, keyed on this cause rather than on the words it is put in; and give it back."""
        self.unfollowed = why
        return why

    def import_targets(self, text, kind, cur_dir, root, inserts=((), ()), strings=True):
        """(the import as written, the files it runs, or False when it names a local file not there,
        or a Python module placed nowhere), for each import in text; a package or a builtin gives an
        empty list. Without strings, a JavaScript import whose keyword sits inside a string literal
        or a template's text is left out (claude-config#2484)."""
        if kind == "js":
            code, quoted = js_scan(text)
            for m in IMPORT_SPEC.finditer(code):
                if not strings and quoted[m.start()]:
                    continue
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
    # certain what the variable holds when python starts (sh_walk), from the few forms the scripts
    # use: literals, quotes, other such variables, BASH_SOURCE, and $(pwd), $(dirname X) and
    # $(cd X && pwd). Anything else is None, and an entry built from None is placed nowhere, so the
    # import is refused as before: this only ever places more imports, each judged like any other.
    #
    # The same values work out the path a script sources, and a sourced path that cannot be worked
    # out is refused (claude-config#2465), so the resolver also reads the forms this repository's
    # scripts use: a `local` set in a function (lib/suite-deadline.sh's `local ... _sd_reader=...`),
    # ${X%/*} and ${X:-default}, and a name set more than once where the last set always runs (the
    # HOOK_DIR idiom: a case on BASH_SOURCE, then cd ... && pwd). A value is known only over the part
    # of the text where it is certain (sh_walk), so each command is looked up by where it is (at).

    def sh_note(self, text, words, assigns, d):
        """Note a command that only sets one variable (NAME=value, or export NAME=value): pending, for
        sh_source_var, and exported, for the environment py_args hands a python command."""
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
        if exported:
            self.shell["exported"].add(name)

    def sh_ctx_known(self):
        """sh_walk's result for the text being read, worked out the first time it is asked for."""
        ctx = self.shell
        if ctx["known"] is None:
            ctx["known"] = self.sh_known(ctx["text"], ctx["cwd"], ctx["script"], ctx["cwd_known"])
        return ctx["known"]

    def sh_var(self, name):
        """The value of a variable the text being read set, at the command being read, or None where
        it is not certain."""
        if self.shell["at"] is None:
            return None
        return self.sh_at(self.sh_ctx_known(), name, self.shell["at"])

    def sh_cwd(self, d):
        """d, the directory the command being read runs in, where that is certain; else
        SH_UNKNOWN_DIR. commands() follows every cd in the text, one in a branch or a function
        included, so it is certain only where sh_walk found it so (sh_cwd_at), and only where the
        text's own start was."""
        ctx = self.shell
        if not ctx["cwd_known"] or ctx["at"] is None or not self.sh_cwd_at(self.sh_ctx_known(), ctx["at"]):
            return SH_UNKNOWN_DIR
        return self.sh_dir(d)

    @staticmethod
    def sh_cwd_at(known, at):
        """Whether sh_walk found the directory certain at offset at: before where the walk ended, in no
        function body (which runs wherever it is called from), and past no cd that may have failed."""
        return at < known["top"] and not any(a <= at < b for a, b in known["lost"] + known["bodies"])

    @staticmethod
    def sh_dir(d):
        """d where it can be a directory a command is certain to run in, else SH_UNKNOWN_DIR: not one
        named by a variable or a substitution (commands() keeps cd "$X" as written), not `cd -`, and
        one that is there, since a cd into a folder that is not fails and the shell stays put."""
        if not d:
            return d  # the directory the text was started in
        if "$" in d or "`" in d or d == "-" or not os.path.isdir(d):
            return SH_UNKNOWN_DIR
        return d

    @staticmethod
    def sh_at(known, name, at):
        """The value sh_walk found certain for name at offset at in its text, or None."""
        for a, b, v in known["regions"].get(name, ()):
            if a <= at < b:
                return v
        return None

    def sh_source_var(self, name):
        """sh_var for a sourced file's path, HOME taken from the session where the text never binds it."""
        return self.sh_home(name, self.shell["text"], self.sh_var(name))

    def sh_home(self, name, text, v):
        """v, or for HOME unknown in a text that never binds it, the session's HOME: the command runs
        with the session's HOME, and `. "$HOME/.cargo/env"` is common."""
        if v is None and name == "HOME" and not self.sh_binds("HOME", text):
            return os.environ.get("HOME") or None
        return v

    def sh_source_word(self, text, wd, var, script):
        """The path a source or . command reads, as its BASH_SOURCE will be: (word, False); (None, True)
        where it cannot be worked out; (None, False) for a command that is not one, or names nothing.
        wd is the directory it runs in, SH_UNKNOWN_DIR where that is not certain, and a relative path
        there cannot be worked out. A literal path is the word as written, ~ expanded where it is
        read; one built from a variable or a substitution is worked out with var (claude-config#2465)."""
        raw = self.sh_source_target(text)
        if raw is None:
            return None, False
        if re.search(r"[$`]", raw):
            v, splits = self.sh_word(raw, wd, var, script, False)
            if v is None or splits:
                return None, True
        else:
            words = self.sw.command_words(self.sw.command_rest(text)[0])
            if len(words) < 2:
                return None, False
            v = words[1]
        if not os.path.isabs(os.path.expanduser(v)) and wd == SH_UNKNOWN_DIR:
            return None, True
        return v, False

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

    # The commands of s read from cwd, and where each is in s: (commands, parts), as the reader's
    # commands() gives them. Read once for each text in a run: what it gives depends on the text and
    # the directory alone, and the line being judged, the walk of its variables and the names a
    # sourced file binds each asked for it again, 40 readings for the 11 files of the merge helper
    # (claude-config#2576). Each caller gets lists of its own. A text the reader cannot read raises
    # as it did, every time it is asked for.
    def parsed(self, s, cwd):
        key = (s, cwd)
        if key not in self.parsed_memo:
            parts = []
            self.parsed_memo[key] = (self.sw.commands(s, cwd, parts=parts), parts)
        cmds, parts = self.parsed_memo[key]
        return list(cmds), [dict(p) for p in parts]

    def sh_known(self, s, cwd, script, cwd_known=True, depth=0):
        """sh_walk(), worked out once for each text, which is asked about from several places. A text
        that sources itself finds nothing certain on the way back in."""
        key = (s, cwd, script, cwd_known)
        if key not in self.known_memo:
            self.known_memo[key] = {"regions": {}, "top": 0, "lost": [], "bodies": []}
            self.known_memo[key] = self.sh_walk(s, cwd, script, cwd_known, depth)
        return self.known_memo[key]

    def sh_walk(self, s, cwd, script, cwd_known, depth):
        """What is certain about the variables in s: {"regions": {name: [(start, end, value)]}, "top",
        "lost", "bodies"}, each value certain for every command starting from start to before end.
        The directory a command runs in is certain before top, outside every span in lost, and
        outside every function body (bodies), which runs wherever its function is called from.

        The walk follows s in order, to top: the end of s, or the first command whose effect it
        cannot follow. A command at the top level is followed as it happens:
          - NAME=value (export NAME=value) sets NAME, worked out from what is known at that point;
          - `test || NAME=value` and `test && NAME=value` set it where the test ([ or test comparing
            known values) says it runs, and leave it unknown where nothing says (lib/suite-deadline.sh:
            `[ "$D" != "${BASH_SOURCE[0]}" ] || D=.`); any other command chained after && or ||
            leaves what it binds unknown;
          - a case on a known word whose branches only set names runs the branch its patterns pick
            (sh_case: the HOOK_DIR idiom);
          - any other compound command (if, a loop, a case, a { } group) is stepped over: every name
            bound inside it is unknown from where it starts, and what it sources or calls is followed
            as below;
          - a function definition runs nothing, so it is stepped over; a call to a function of s
            leaves every name its body binds unknown, and ends the walk where the body sources a
            file, binds a name through a variable, or calls a function of s that does;
          - a pipeline's commands and a backgrounded one run in shells of their own, as a subshell's
            do, and set nothing here (unless the script turns on lastpipe);
          - a sourced file whose path is worked out leaves every name it binds (it, or a file it
            sources, sh_bound_in) unknown from then on, since it can define a function that sets the
            name later; one whose path is not, eval, or a name bound through a variable (read "$n",
            printf -v "$n", declare -n...) ends the walk, and nothing known before lasts past it;
          - any other command that binds a name (read, for, unset, local...) leaves it unknown;
          - a cd that may not have run (chained, piped, or in a compound) leaves the directory unknown
            from then on, except that the commands joined to `cd X` by && run only where it worked,
            and `cd X || exit` and `cd X || { ...; exit; }` end the script where it did not.
        Inside a function body only a value that lasts to the end of s holds, as the body runs when
        the function is called. A value lasts to the end of s where nothing else in s binds the name
        (a NAME=value in front of a command that is not a special builtin or a function of s sets it
        for that command alone, so it does not count), nothing the walk did not follow binds a name
        through a variable, and no file sourced where the walk did not follow it (in a function body,
        or past top) binds it, those paths worked out from these same values. A `local` set in a
        function adds a value of its own (sh_locals)."""
        try:
            cmds, parts = self.parsed(s, cwd)
        except self.sw.Unreadable:  # a text the reader cannot read; any other error is a fault (#2573)
            return {"regions": {}, "top": 0, "lost": [], "bodies": []}
        items = list(zip(cmds, parts))
        struct = self.sh_struct(items)
        rows, blocks = struct if struct else (None, None)
        allnames = set(re.findall(r"(?<![\w$])([A-Za-z_]\w*)(?:\[[^\]\n]*\])?\+?=", s))
        funcs = self.sh_funcs(s)
        shopt = bool(re.search(r"\bshopt\b", s))
        env, since, regions, spans, tainted, handled = {}, {}, {}, {}, set(), set()
        lost = [] if cwd_known else [(0, len(s))]
        bodies, fbody = [], {}
        for blk in blocks or ():
            if blk["kind"] == "func":
                o, c = blk["open"], blk["close"]
                bodies.append((items[o][1]["start"], items[c][1]["end"]))
                m = re.match(r"\s*(?:function\s+)?([A-Za-z_][\w:.-]*)", items[o][0][1])
                if m:
                    fbody.setdefault(m.group(1), []).append((o, c))

        def head_of(k):
            return rows[k][1] if rows else items[k][0][1].strip()

        def where(d, at):
            if at >= top or any(a <= at < b for a, b in lost + bodies):
                return SH_UNKNOWN_DIR
            return self.sh_dir(d)

        def look(n):
            return self.sh_home(n, s, env.get(n))

        def setv(n, v, at):
            if env.get(n) is not None:
                regions.setdefault(n, []).append((since[n], at, env[n]))
            env[n], since[n] = (None if n in tainted else v), at

        own, reached = {}, {}

        # What the body of the function of s named name does by itself: (the names it can bind,
        # whether it sources a file or binds a name through a variable, the functions of s it
        # calls). Worked out once for each function.
        def body_of(name):
            if name not in own:
                bound, more, callees = set(), False, []
                for o, c in fbody.get(name, ()):
                    body = s[items[o][1]["start"]:items[c][1]["end"]]
                    bound |= {n for n in allnames if self.sh_binds(n, body)}
                    for k in range(o, c + 1):
                        if len(items[k][1]["scope"]) > 1:
                            continue
                        h = head_of(k)
                        words = self.sw.command_words(self.sw.command_rest(h)[0])
                        if self.sh_source_target(h) is not None or self.sh_indirect(h):
                            more = True
                        elif words and words[0] in fbody:
                            callees.append(words[0])
                own[name] = (bound, more, callees)
            return own[name]

        def calls(name):
            """(the names a call to the function of s named name can bind, whether it can do more than
            that: source a file, bind a name through a variable, or call a function of s that does)."""
            # A call takes in every function it reaches, each once. Followed again down every path
            # of calls to it, a chain of functions that each call the next twice cost two to the
            # power of its length, and the merge helper's own functions were walked 2,430 times for
            # one judgement (claude-config#2576). What is reached is the same either way.
            if name not in reached:
                bound, more, todo, seen = set(), False, [name], set()
                while todo:
                    f = todo.pop()
                    if f in seen:
                        continue
                    seen.add(f)
                    b, m, callees = body_of(f)
                    bound, more = bound | b, more or m
                    todo += callees
                reached[name] = (bound, more)
            return reached[name]

        def effects(d, head, p, run, when=None):
            """Follow one command: None, or "stop" or "dead" where the walk ends at it ("dead": and
            nothing known lasts past it). run is True where it certainly runs, None where it may not;
            when is where what it changes is changed from (the end of the command, or the start of
            the compound holding it, which can run it more than once)."""
            w = p["end"] if when is None else when
            a = self.sh_assignment(head)
            if a:
                spans.setdefault(a[0], []).append((p["start"], p["end"]))
                setv(a[0], self.sh_word(a[1], where(d, p["start"]), look, script, True)[0] if run else None, w)
                return None
            rest, _ = self.sw.command_rest(head)
            words = self.sw.command_words(rest)
            if self.sh_indirect(head):
                return "dead"
            wd = where(d, p["start"])
            v, bad = self.sh_source_word(head, wd, look, script)
            if bad:
                return "dead"
            if v is not None:
                path = self.resolve(v, d)
                if not os.path.isfile(path):
                    return "dead"
                for n in self.sh_bound_in(path, allnames, d, wd != SH_UNKNOWN_DIR, v, depth + 1, set()):
                    tainted.add(n)
                    setv(n, None, w)
                return None
            named = [x for x in words if x in fbody] if words[:1] == ["trap"] else \
                words[:1] if words and words[0] in fbody else []
            for f in named:
                b, more = calls(f)
                if more:
                    return "stop"
                for n in b:
                    setv(n, None, w)
            judged = rest if words and words[0] not in SH_SPECIAL and words[0] not in funcs else head
            for n in [n for n in env if self.sh_binds(n, judged)]:
                setv(n, None, w)
            return None

        def compound(i, j):
            """Step over the compound command from items[i] to items[j]: None, "stop" or "dead"."""
            start = items[i][1]["start"]
            inner = [k for k in range(i, j + 1) if len(items[k][1]["scope"]) == 1
                     and not any(a <= items[k][1]["start"] < b for a, b in bodies)]
            if any(self.sw.cd_target(head_of(k)) is not None for k in inner if head_of(k)):
                lost.append((start, len(s)))
            for n in {n for n in allnames | set(env) if self.sh_binds(n, s[start:items[j][1]["end"]])}:
                setv(n, None, start)
            for k in inner:
                if head_of(k):
                    handled.add(k)
                    res = effects(items[k][0][0], head_of(k), items[k][1], None, start)
                    if res:
                        return res
            return None

        top, whole, prev, test, chain, i = len(s), True, ";", None, None, 0
        while i < len(items):
            (d, t), p = items[i]
            if len(p["scope"]) > 1:
                i += 1
                continue  # a subshell's or a substitution's: it sets nothing here
            head = head_of(i)
            if rows is None and (SH_COMPOUND.match(head) or SH_FUNC_DEF.match(head)):
                top = p["start"]
                break  # the keywords did not pair up, so where a compound ends is not known
            if rows and rows[i][0]:
                blk = blocks[rows[i][0][0]]
                j, res = blk["close"], None
                end = items[j][1]["end"]
                if chain and prev in ("&&", "||") and not (chain == "and" and prev == "&&"):
                    # Reached where the cd may have failed: unknown inside, and after it too unless
                    # it is `cd X || { ...; exit; }`.
                    guard = chain == "or" and prev == "||" and blk["kind"] == "group" and \
                        re.match(r"exit\b", head_of(j - 1) or "")
                    lost.append((p["start"], end if guard else len(s)))
                    chain = "done" if guard else None
                if blk["kind"] == "func":
                    pass  # it runs nothing until it is called
                elif blk["kind"] == "case" and prev not in ("&&", "||", "|", "&") and \
                        self.sh_case(s, items, i, look, setv, spans, lambda d2, at=p["start"]: where(d2, at),
                                     script, shopt, j + 1):
                    handled.update(range(i, j + 1))
                else:
                    res = compound(i, j)
                if res:
                    top, whole = p["start"], whole and res == "stop"
                    break
                if items[j][1]["how"] not in ("&&", "||"):
                    if chain == "and":
                        lost.append((end, len(s)))
                    chain = None
                i, prev, test = j + 1, items[j][1]["how"], None
                continue
            i += 1
            handled.add(i - 1)
            how, is_cd = p["how"], self.sw.cd_target(head) is not None
            if prev in ("|", "&") or how in ("|", "&"):
                if "lastpipe" in s:
                    top = p["start"]
                    break  # the last command of a pipeline may run in this shell
                if is_cd and how not in ("|", "&"):
                    lost.append((p["end"], len(s)))  # commands() moves to it, the shell does not
                prev, test, chain = how, None, None
                continue
            if prev in ("&&", "||"):
                if chain and not (chain == "and" and prev == "&&"):
                    if chain == "or" and prev == "||" and re.match(r"exit\b", head):
                        chain = "done"  # `cd X || exit 1`: past it, the cd worked
                    else:
                        lost.append((p["start"], len(s)))
                        chain = None
                a = self.sh_assignment(head)
                res = None
                if a:
                    runs = None if test is None else test == (prev == "&&")
                    if runs is False:
                        spans.setdefault(a[0], []).append((p["start"], p["end"]))  # written, never run
                    else:
                        res = effects(d, head, p, runs)
                else:
                    if is_cd:
                        lost.append((p["end"], len(s)))  # a cd that may not run
                    res = effects(d, head, p, None)
                test = None
            else:
                chain = ("and" if how == "&&" else "or") if is_cd and how in ("&&", "||") else None
                test = self.sh_test(head, where(d, p["start"]), look, script) if how in ("&&", "||") else None
                res = effects(d, head, p, True)
            if res:
                top, whole = p["end"], whole and res == "stop"
                break
            if how not in ("&&", "||"):
                if chain == "and":
                    lost.append((p["end"], len(s)))  # `cd X && a; b`: b runs whether or not the cd worked
                chain = None
            prev = how
        # NAME=value in front of a command (not a special builtin, nor a function of s, which runs
        # with it set) sets it for that command alone, so it is no second assignment:
        # `LIBDIR="$DIR/lib" python3 ...` beside `export LIBDIR=...`.
        temp = {}
        for (d, t), p in items:
            rest_t, assigns = self.sw.command_rest(t)
            words = self.sw.command_words(rest_t)
            if words and words[0] not in SH_SPECIAL and words[0] not in funcs:
                for a in assigns.split("\n"):
                    n = a.split("=", 1)[0]
                    if a.strip() and re.fullmatch(r"[A-Za-z_]\w*", n):
                        temp[n] = temp.get(n, 0) + 1
        final = {n: (since[n], v) for n, v in env.items() if v is not None}
        # What the walk did not follow: function bodies, and everything past top. A subshell's
        # commands set nothing here.
        unfollowed = [k for k in range(len(items)) if k not in handled and len(items[k][1]["scope"]) == 1]
        cand = set()
        if whole and not any(self.sh_indirect(head_of(k)) for k in unfollowed):
            for n in final:
                rest = s
                for a, b in sorted(spans.get(n, ()), reverse=True):
                    rest = rest[:a] + rest[b:]
                if n not in tainted and not self.sh_binds(n, rest, temp.get(n, 0)):
                    cand.add(n)

        def carve(a, b):
            """[a, b) less every function body: a value the walk saw at one point, not to the end."""
            out = []
            for x, y in sorted(bodies):
                if y <= a or x >= b:
                    continue
                if x > a:
                    out.append((a, x))
                a = max(a, y)
            return out + [(a, b)] if a < b else out

        # The files sourced where the walk did not follow, whose paths these values work out, must
        # bind none of the names that last; dropping one can change those paths, so this goes round
        # until it settles.
        while True:
            known = {"regions": {}, "top": top, "lost": lost, "bodies": bodies}
            for n, r in regions.items():
                for a, b, v in r:
                    known["regions"].setdefault(n, []).extend((x, y, v) for x, y in carve(a, b))
            for n, (a, v) in final.items():
                kept = [(a, len(s))] if n in cand else carve(a, top)
                known["regions"].setdefault(n, []).extend((x, y, v) for x, y in kept)
            for n, r in self.sh_locals(s, items, struct, known, script).items():
                known["regions"].setdefault(n, []).extend(r)
            if not cand:
                return known
            bound = set()
            for k in unfollowed:
                (d, t), p = items[k]
                v, bad = self.sh_source_word(head_of(k), SH_UNKNOWN_DIR, lambda n, at=p["start"]: self.sh_home(
                    n, s, self.sh_at(known, n, at)), script)
                if v is None and not bad:
                    continue
                if bad or not os.path.isfile(self.resolve(v, d)):
                    bound = set(cand)
                    break
                bound |= self.sh_bound_in(self.resolve(v, d), cand, d, False, v, depth + 1, set())
            if not bound & cand:
                return known
            cand -= bound

    def sh_assignment(self, head):
        """(name, raw value) for a command that only sets one name (NAME=value, export NAME=value)."""
        m = re.match(r"(?:export\s+)?([A-Za-z_]\w*)=", head)
        if not m:
            return None
        end = self.sh_word_end(head, m.end())
        return None if head[end:].strip() else (m.group(1), head[m.end():end])

    @staticmethod
    def sh_funcs(s):
        """The names of the functions s defines."""
        return set(re.findall(r"(?m)^\s*(?:function\s+)?([A-Za-z_][\w:.-]*)\s*\(\s*\)", s)) | \
            set(re.findall(r"\bfunction\s+([A-Za-z_][\w:.-]*)", s))

    @staticmethod
    def sh_binds(name, text, allowed=0):
        """Whether text can bind name, beyond `allowed` NAME= forms that set it for one command alone:
        NAME=, NAME+=, NAME[i]=, ${NAME:=}, read, for, local, unset... NAME, or NAME inside (( )).
        export and readonly with no = keep the value, so they do not count."""
        # Every form below spells the name out, so text without it binds nothing. That, and patterns
        # compiled once per name (sh_bind_patterns), are what keep a script with thousands of names
        # inside the gate's time: asked per name per compound command, this ran 344,464 times
        # judging the merge helper and compiled a pattern 1,002,444 times (claude-config#2569).
        if name not in text:
            return False
        assigns, arithmetic, binders = sh_bind_patterns(name)
        if len(assigns.findall(text)) > allowed:
            return True
        if arithmetic.search(text):
            return True
        return any(not SH_VALUE_KEPT.match(m.group(0)) for m in binders.finditer(text))

    def sh_indirect(self, text):
        """Whether a command can bind a name it does not spell out, so no name is certain past it: eval,
        a nameref (declare -n), a name handed through a variable to read, mapfile, getopts, unset,
        printf -v, let or declare, or $NAME = in (( )). Its words are read as written (sh_tokens), so
        a value such as $(( ... )) stays one word, and a name is one only with no $ or ` in it."""
        if re.search(r"\(\([^()]*\$\{?\w+\}?\s*(?:[-+*/%&|^]|<<|>>)?=(?!=)", text):
            return True
        toks = self.sh_tokens(self.sw.command_rest(text)[0])
        words, k = [], 0
        while k < len(toks):
            kind, raw = toks[k]
            if kind == "op":
                k += 2 if SH_REDIRECT.fullmatch(raw) else 1  # a redirection and its target
                continue
            words.append(raw if re.search(r"[$`]", raw) else re.sub(r"""['"]""", "", raw))
            k += 1
            if raw.endswith("=") and k < len(toks) and toks[k] == ("op", "("):
                # NAME=( ... ): the words inside are the array's values, not names (local -a q=("" x)
                # read "" as a name nobody could spell, claude-config#2465). With no ) it closes on
                # (sh_tokens can keep it inside a $(( )) word), the words are read as before, each
                # one judged as a name where the command binds names.
                close = next((i for i in range(k + 1, len(toks)) if toks[i] == ("op", ")")), None)
                if close is not None:
                    k = close + 1
        if not words:
            return False
        w0, args = words[0], words[1:]
        name = r"[A-Za-z_]\w*(?:\[[^\]$`]*\])?"
        if w0 == "eval":
            return True
        if w0 == "let":
            return any(re.search(r"[$`]", a) for a in args)
        if w0 in ("declare", "typeset", "local", "export", "readonly"):
            for a in args:
                if a[:1] in ("-", "+"):
                    if a[0] == "-" and "n" in a[1:]:
                        return True
                    continue
                if not re.fullmatch(name, a.split("=", 1)[0]):
                    return True
            return False
        names = []
        if w0 in ("read", "mapfile", "readarray"):
            valued = "dinNptu" if w0 == "read" else "dnOsuCc"
            k = 0
            while k < len(args) and args[k].startswith("-") and args[k] != "-":
                letters, k = args[k][1:], k + 1
                for ci, ch in enumerate(letters):
                    if ch in valued or (ch == "a" and w0 == "read"):
                        value = letters[ci + 1:]
                        if not value:
                            value, k = (args[k] if k < len(args) else ""), k + 1
                        if ch == "a":
                            names.append(value)
                        break
            names += args[k:]
        elif w0 == "getopts":
            names = args[1:2]
        elif w0 == "unset":
            names = [a for a in args if not a.startswith("-")]
        elif w0 == "printf":
            for k, a in enumerate(args):
                if a == "-v":
                    names = args[k + 1:k + 2]
                    break
                if a.startswith("-v"):
                    names = [a[2:]]
                    break
                if not a.startswith("-"):
                    break
        return any(not re.fullmatch(name, a) for a in names)

    def sh_test(self, head, d, var, script):
        """True or False for a test whose outcome is certain ([ or test comparing known words with =,
        ==, != , -n, -z, or one word on its own), else None."""
        toks = self.sh_tokens(head)
        if not toks or any(k == "op" for k, _ in toks):
            return None
        w = [r for _, r in toks]
        if w[0] == "[":
            if w[-1] != "]":
                return None
            w = w[1:-1]
        elif w[0] == "test":
            w = w[1:]
        else:
            return None
        vals = []
        for r in w:
            v, splits = self.sh_word(r, d, var, script, False)
            if v is None or splits:
                return None
            vals.append(v)
        if len(vals) == 3 and vals[1] in ("=", "==", "!="):
            return (vals[0] == vals[2]) != (vals[1] == "!=")
        if len(vals) == 2 and vals[0] in ("-n", "-z"):
            return (vals[1] == "") == (vals[0] == "-z")
        if len(vals) == 1:
            return vals[0] != ""
        return None

    def sh_case(self, s, items, k, var, setv, spans, where, script, shopt, expect):
        """Follow the case at items[k] for sh_walk: True where it was followed, its esac the command
        before items[expect]; otherwise False, having changed nothing, for the walk to step over it
        as any other compound command. Each branch may only set names (NAME=value) and end in ;;. With the word known,
        the first branch with a pattern matching it runs, its names set in turn; with it unknown, every
        name any branch sets is unknown after it. A pattern is followed only in a plain form (letters,
        digits, / . _ - * ?), and holding a letter only where the script never runs shopt, which can
        change how a pattern matches (nocasematch, extglob)."""
        (d, t), p = items[k]
        head = t.strip()
        m = re.match(r"case\s+", head)
        if not m:
            return None
        wend = self.sh_word_end(head, m.end())
        if head[wend:].strip() != "in":
            return None
        word = self.sh_word(head[m.end():wend], where(d), var, script, True)[0]
        branches, opened, pos, j = [], False, p["end"], k + 1
        while j < len(items):
            (dj, tj), pj = items[j]
            if len(pj["scope"]) > 1:
                return None
            gap = s[pos:pj["start"]]
            while gap.strip():
                gap = gap.lstrip()
                if gap.startswith((";;&", ";&")):
                    return None  # a branch that runs on into the next
                if gap.startswith(";;"):
                    gap, opened = gap[2:], False
                    continue
                gm = re.match(r"\(?([^()]*)\)", gap)
                if not gm:
                    return None
                pats = [x.strip() for x in gm.group(1).split("|")]
                if any(not re.fullmatch(r"[A-Za-z0-9_./*?-]+", x) or (shopt and re.search(r"[A-Za-z]", x))
                       for x in pats):
                    return None
                branches.append((pats, []))
                gap, opened = gap[gm.end():], True
            hj = tj.strip()
            if hj == "esac":
                if pj["how"] in ("|", "&", "case"):
                    return None
                break
            a = self.sh_assignment(hj)
            if not a or not opened or pj["how"] not in (";", "#"):
                return None
            branches[-1][1].append((a, dj, pj))
            pos, j = pj["end"], j + 1
        else:
            return None
        if j + 1 != expect:
            return None
        chosen = ()
        if word is not None:
            chosen = next((b for pats, b in branches if any(fnmatch.fnmatchcase(word, x) for x in pats)), ())
        for _, b in branches:
            for (n, raw), dj, pj in b:
                spans.setdefault(n, []).append((pj["start"], pj["end"]))
                if word is None:
                    setv(n, None, pj["end"])
        for (n, raw), dj, pj in chosen:
            setv(n, self.sh_word(raw, where(dj), var, script, True)[0], pj["end"])
        return True

    @staticmethod
    def sh_struct(items):
        """The compound commands around each command, for sh_locals: (rows, blocks), a row for each of
        items, None for a subshell's or a substitution's command, else (the ids of the blocks it is
        inside, outermost first; its text with the keywords that open or carry on a block taken off),
        and each block {"kind": "func", "if", "loop", "case" or "group", "open" and "close": the indexes
        of the commands opening and closing it}. None where the keywords do not pair up, or a function
        body is not a group."""
        rows, blocks, stack, brace, idx = [], [], [], False, 0

        def push(kind):
            blocks.append({"kind": kind, "open": idx, "close": None})
            stack.append(len(blocks) - 1)

        for idx, ((d, t), p) in enumerate(items):
            if len(p["scope"]) > 1:
                rows.append(None)
                continue
            head, pending = t.strip(), brace
            while head:
                m = re.match(r"(?:then|else|do|elif|!|time)(?=[\s;&|()]|$)\s*", head)
                if m:
                    head = head[m.end():]
                    continue
                m = re.match(r"(if|while|until)(?=[\s;&|()]|$)\s*", head)
                if m:
                    push("if" if m.group(1) == "if" else "loop")
                    head = head[m.end():]
                    continue
                if re.match(r"(?:for|select|case)(?=\s|$)", head):
                    push("case" if head.startswith("case") else "loop")
                    head = ""  # its words are no command
                    break
                if re.match(r"\{(?=\s|$)", head):
                    if brace:
                        brace = False  # the body of the function opened on the command before
                    else:
                        push("group")
                    head = head[1:].lstrip()
                    continue
                m = re.match(r"function\s+[^\s(){}]+(?:\s*\(\s*\))?\s*", head) or \
                    re.match(r"[A-Za-z_][\w:.-]*\s*\(\s*\)\s*", head)
                if m:
                    if brace:
                        return None
                    push("func")
                    head = head[m.end():]
                    if not head:
                        brace = True
                        break
                    if not re.match(r"\{(?=\s|$)", head):
                        return None  # f() ( ... ) or another body form: not followed
                    head = head[1:].lstrip()
                    continue
                break
            if pending and brace:
                return None
            m = re.match(r"(fi|done|esac|\})(?=[\s;&|<>)]|$)", head)
            if m:
                want = {"fi": ("if",), "done": ("loop",), "esac": ("case",), "}": ("group", "func")}[m.group(1)]
                if not stack or blocks[stack[-1]]["kind"] not in want:
                    return None
                blocks[stack.pop()]["close"] = idx
                head = ""
            rows.append((tuple(stack), head))
        return None if stack or brace else (rows, blocks)

    def sh_locals(self, s, items, struct, known, script):
        """The values `local NAME=value` gives in the function it is in, as sh_walk regions
        (claude-config#2465: lib/suite-deadline.sh sources "$_sd_reader", a local). The local must be a
        command of the function body itself (in no if, loop, case, group or chain, so it runs whenever
        the function does), NAME=value must appear once in it, and nothing else in s may bind NAME.
        Its value is worked out from what is known there, the directory unknown, since a function
        runs wherever it is called. It lasts until the function ends, a loop or a function opens
        inside it, or a command that is not one of SH_KEEPS, a plain NAME=value, or a local of other
        names runs, since that can be a function setting it; that command's own words are still read
        with it, being worked out before it runs."""
        out = {}
        if struct is None:
            return out
        rows, blocks = struct
        for idx, ((d, t), p) in enumerate(items):
            if rows[idx] is None:
                continue
            stack, head = rows[idx]
            if not stack or blocks[stack[-1]]["kind"] != "func" or p["how"] in ("|", "&"):
                continue
            before = next((items[j][1]["how"] for j in range(idx - 1, -1, -1) if rows[j] is not None), ";")
            toks = self.sh_tokens(head)
            if before in ("&&", "||", "|", "&") or toks[:1] != [("word", "local")] or any(k == "op" for k, _ in toks):
                continue
            words = [r for _, r in toks[1:]]
            while words[:1] == ["-r"]:
                words = words[1:]
            if any(w[:1] in ("-", "+") for w in words):
                continue  # -a, -i, -n and the rest change what the value is
            here, rest, end = {}, s[:p["start"]] + s[p["end"]:], blocks[stack[-1]]["close"]
            for w in words:
                m = re.match(r"([A-Za-z_]\w*)=", w)
                if not m:
                    here[w] = None
                    continue
                n = m.group(1)
                v = self.sh_word(w[m.end():], SH_UNKNOWN_DIR, lambda x: here[x] if x in here else self.sh_home(
                    x, s, self.sh_at(known, x, p["start"])), script, True)[0]
                here[n] = v
                if v is None or self.sh_binds(n, rest) or \
                        sum(1 for x in words if re.match(re.escape(n) + r"(?:=|$)", x)) > 1:
                    continue
                b = items[end][1]["start"]
                for j in range(idx + 1, end):
                    if rows[j] is None:
                        continue  # a subshell's or a substitution's, which cannot set it
                    stack_j, head_j = rows[j]
                    if stack_j[:len(stack)] != stack or \
                            any(blocks[x]["kind"] in ("loop", "func") for x in stack_j[len(stack):]):
                        b = items[j][1]["start"]
                        break
                    if not self.sh_keeps(head_j):
                        b = items[j][1]["start"] + 1
                        break
                out.setdefault(n, []).append((p["end"], b, v))
        return out

    def sh_keeps(self, head):
        """Whether a command certainly sets no shell variable but those it spells out: nothing, a
        plain NAME=value, a local or declare naming its names outright, or one of SH_KEEPS."""
        if not head:
            return True
        rest, _ = self.sw.command_rest(head)
        words = self.sw.command_words(rest)
        if not words:
            return True
        if words[0] in ("local", "declare", "typeset", "readonly", "export"):
            return not self.sh_indirect(head)
        if words[0] == "printf":
            return not any(w.startswith("-v") for w in words[1:])
        return words[0] in SH_KEEPS

    def sh_source_target(self, t):
        """The raw word a source or . command names, or None for any other command."""
        rest, _ = self.sw.command_rest(t)
        rest = rest.lstrip()
        end = self.sh_word_end(rest, 0)
        if rest[:end] not in ("source", "."):
            return None
        start = len(rest) - len(rest[end:].lstrip())
        return rest[start:self.sh_word_end(rest, start)] or None

    @staticmethod
    def sh_strip_openers(t):
        """t with what opens or carries on a compound command taken off its front (a function's
        `name() {`, `function name {`, if, then, do, while, until, else, !, a brace), so the command
        it runs is the one judged: `f() { eval "$1=1"; }` on one line read as a call to f() and its
        eval went unseen (claude-config#2465)."""
        t = t.strip()
        while True:
            m = SH_FUNC_DEF.match(t) or re.match(r"function\s+[A-Za-z_][\w:.-]*(?:\s*\(\s*\))?", t) or \
                re.match(r"(?:if|then|elif|else|do|while|until|time|!|\{)(?=[\s;&|]|$)", t)
            if not m or m.end() == 0:
                return t
            t = t[m.end():].lstrip()

    def sh_bound_in(self, path, names, cwd, cwd_known, word, depth, seen):
        """The names among names that a sourced file binds, anywhere in it (a function's body too, as
        it can be called later), or in a file it sources, whose path is worked out from the file's
        own variables (sh_known; word is its BASH_SOURCE, cwd the directory it runs in). All of them
        where it cannot be read, is past MAX_DEPTH, or binds a name through a variable (eval,
        read "$n"...). A file it sources whose path cannot be worked out is not followed: the gate
        refuses that file when it reads it (claude-config#2465), so what it binds is never relied on."""
        if not names:
            return set()
        real = os.path.realpath(path)
        if real in seen:
            return set()
        if depth > MAX_DEPTH:
            return set(names)
        seen.add(real)
        self.tick(path)
        try:
            with open(real, "rb") as f:
                text = f.read(MAX_FILE).decode("utf-8", "replace")
        except OSError:
            return set(names)
        # One file is asked about by every script that sources it, and by each file between them,
        # with mostly the same names: lib/ai-review-common.sh was read whole 8 times judging the
        # merge helper. Whether a text binds a name depends on nothing else, so each answer is kept
        # for the run, by the text itself (claude-config#2576).
        told = self.binds_memo.setdefault(text, {})
        for n in names:
            if n not in told:
                told[n] = self.sh_binds(n, text)
        bound = {n for n in names if told[n]}
        try:
            cmds, parts = self.parsed(text, cwd)
        except self.sw.Unreadable:  # a text the reader cannot read; any other error is a fault (#2573)
            return set(names)
        known = None
        for (d, t), p in zip(cmds, parts):
            if len(p["scope"]) > 1:
                continue  # a subshell's or a substitution's (h="$(eval ...)"): it binds nothing here
            if self.sh_indirect(self.sh_strip_openers(t)):
                return set(names)
            if self.sh_source_target(t) is None:
                continue
            if known is None:
                known = self.sh_known(text, cwd, word, cwd_known, depth)
            wd = self.sh_dir(d) if cwd_known and self.sh_cwd_at(known, p["start"]) else SH_UNKNOWN_DIR
            v, bad = self.sh_source_word(t, wd, lambda n, at=p["start"]: self.sh_home(
                n, text, self.sh_at(known, n, at)), word)
            if v is not None and os.path.isfile(self.resolve(v, d)):
                bound |= self.sh_bound_in(self.resolve(v, d), names, d, wd != SH_UNKNOWN_DIR, v, depth + 1, seen)
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
                    v = self.sh_param(p, d, var, script, dq)
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

    def sh_param(self, p, d, var, script, dq):
        """The value of the parameter expansion ${p} or $p, or None where it is not certain: a name,
        BASH_SOURCE[0], and (claude-config#2465) ${X:-default} and ${X-default}, and ${X%pat},
        ${X%%pat}, ${X#pat} and ${X##pat} with a plain pattern (letters, digits, / . _ - * ?), such as
        ${BASH_SOURCE[0]%/*}. Only a name whose value is known has a known expansion: one the text never
        set can come from the environment, set or not, so its default is never taken on trust."""
        m = SH_EXPANSION.fullmatch(p)
        if not m:
            return None
        base = script if m.group(1) in ("BASH_SOURCE", "BASH_SOURCE[0]") else var(m.group(1))
        if base is None:
            return None
        if m.group(2):
            if base or m.group(2) == "-":
                return base
            if dq and "'" in m.group(3):
                return None  # inside double quotes a single quote is only text, which sh_word would drop
            return self.sh_word(m.group(3), d, var, script, True)[0]
        if m.group(4):
            pat, n, op = m.group(5), len(base), m.group(4)
            if not re.fullmatch(r"[A-Za-z0-9_./*?-]+", pat):
                return None
            # Shortest or longest, from the end (%) or the start (#): the first cut that matches.
            cuts = range(n, -1, -1) if op in ("%", "##") else range(n + 1)
            for k in cuts:
                if fnmatch.fnmatchcase(base[k:] if op[0] == "%" else base[:k], pat):
                    return base[:k] if op[0] == "%" else base[k:]
        return base

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
        # Where the directory it runs in is not certain (claude-config#2465), what pwd prints, and
        # where a relative cd goes, are not either.
        here = None if self.sh_dir(d) == SH_UNKNOWN_DIR else os.path.abspath(d or os.getcwd())
        if vals in (["pwd"], ["pwd", "-P"]):
            return None if here is None else here if len(vals) == 1 else os.path.realpath(here)
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
            target = os.path.expanduser(target) if target.startswith("~") else target
            if here is None and not os.path.isabs(target):
                return None
            p = os.path.normpath(os.path.join(here or "/", target))
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
        saved, self.shell = self.shell, self.shell_scope(s, cwd, self.next_script, self.next_cwd_known)
        self.next_script, self.next_cwd_known = None, True
        try:
            # Where in s each command is, for sh_var (claude-config#2465): a variable's value is known
            # only over part of the text. every_command gives s's own commands in commands() order,
            # with a wrapper's commands after it at a depth of one or more; those take its place.
            try:
                starts = [p["start"] for p in self.parsed(s, cwd)[1]]
            except self.sw.Unreadable:
                starts = []  # read by the crude cut, so no command's place is known
            k = 0
            for d, text, wrapper, why, wdepth in self.sw.every_command(s, cwd):
                if not wdepth:
                    self.shell["at"] = starts[k] if k < len(starts) else None
                    k += 1
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
        does not change what the rest of this command is judged with. Each command is one step of
        the walk's budget (tick)."""
        self.tick()
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
                except self.sw.Unreadable:  # as in script_body: any other error is a fault (#2573)
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
                before, code, after = inline
                label = f"the code given to {name}"
                # A file named before the code is one the program loads first (node -r ./x.js,
                # ruby -r), so it is read as code (claude-config#2439).
                for w in before:
                    if not (w.startswith("-") or w.startswith("+")):
                        reason = self.script(w, d, depth, False, lang)
                        if reason:
                            return reason
                # The code imports from the directory it runs in (claude-config#2318).
                reason = self.imports(label, None, here, code, lang) if lang else None
                if reason:
                    return reason
                # The files after it are the code's arguments, judged as a script's are: a data file
                # is read when the code can act on it, and any other file is read as code (#2439).
                return self.every_file([words[0]] + after, d, depth, False, lang, inline=(label, code, here))
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
            if len(words) < 2:
                return None
            # A path built from a variable or a substitution is worked out with the resolver (#2449)
            # and the file it names read (claude-config#2465): `. "$ROOT/lib/x.sh"` was never read, so a
            # sourced helper that posts passed. A literal path is read as it always was, ~ included. One
            # that still cannot be worked out is not read, as before. Refusing it is the half of #2465
            # kept off: on 2026-11-09 it still newly refused 80 of this repository's scripts, whose
            # causes are the follow up issue's to explain before it is turned on (Dan, 2026-11-09).
            v, bad = self.sh_source_word(text, self.sh_cwd(d), self.sh_source_var, self.shell["script"])
            if bad:
                raw = self.sh_source_target(text)
                # A literal path whose directory is not certain is read where the command runs, as on main.
                return self.script(words[1], d, depth, True) if raw and not re.search(r"[$`]", raw) else None
            return self.script(v, d, depth, True) if v is not None else None
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

    def every_file(self, words, d, depth, shell_hint, lang=None, inline=None):
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
        can hold, or running code, which the file can be.

        inline, (its label, its text, the directory it runs in), is code the program was given by an
        option (python3 -c), whose arguments the words are (claude-config#2439). It is judged as the
        first file read as code is, so a data file it is handed is read when it can act on it."""
        code, data = [], []
        if inline:
            label, text, here = inline
            code.append((label, lambda: self.acts_inline(text, here, lang)))
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
            code.append((f"the script {w}", lambda path=path: self.acts(path, d, shell_hint, lang)))
        for w, path in data:
            self.tick(path)
            try:
                with open(path, "rb") as f:
                    hit = MARKER.search(f.read(MAX_FILE).decode("utf-8", "replace"))
            except OSError:
                continue  # unreadable to us is unreadable to the script that would read it
            if not hit:
                continue
            for script_label, script_acts in code:
                acts = script_acts()
                if acts:
                    return f"{script_label} {acts}, and is handed {w}, which names {hit.group(0)}"
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

        Each language is judged by what cannot act, so anything not seen to be unable to counts as
        acting (claude-config#2434). A shell script acts when one of its commands sends a request,
        runs, sources or evals a file or command named by the arguments it was handed (or a variable
        set from them), or hands them to a program not seen to be unable to act (shell_acts). A
        JavaScript script acts unless it, and every local module it imports, is seen to be unable to
        (js_acts), and a Python script likewise (py_acts). A script of any other kind, one that
        cannot be read, and one whose imports cannot all be followed are taken to act: only a script
        seen to do none of it has its data files left unread. A script a shell script hands its
        arguments to is judged here the same way; one already being judged further up counts as
        judged there."""
        real = os.path.realpath(path)
        if real in self.acting:
            return None  # a script handing its arguments back to itself is judged where it began
        self.acting.add(real)
        try:
            return self.acts_on(real, d, shell_hint, lang)
        finally:
            self.acting.discard(real)

    def acts_on(self, real, d, shell_hint, lang):
        """acts() for a script at its real path, once the walk is known not to have come back to it."""
        self.tick(real)
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
        return self.acts_body(body, real, os.path.dirname(real), kind)

    def acts_inline(self, text, here, lang, writes=True, env=None):
        """acts() for code given inline (python3 -c), run from here (claude-config#2439). Code in a
        language whose imports the gate does not follow (perl -e, ruby -e) is taken to act, as a script
        file of that kind is. writes and env are acts_body's, for code a shell script writes."""
        if lang not in ("py", "js"):
            return "is code in a language the gate does not read for what it does with its arguments"
        return self.acts_body(text, None, here, lang, writes, env)

    def acts_body(self, body, real, root, kind, writes=True, env=None):
        """How a Python or JavaScript script's text (real its file, None for inline code; root where it
        runs from) can act on what it is handed, its local imports included, or None.

        writes is False for code a shell script writes inline (claude-config#2446), where writing a
        file is not counted, as it is not for the shell script itself. env, there, is the Python the
        script put in that command's environment ({NAME: its text}, sh_env_code): code the inline
        code runs with exec(os.environ["NAME"]) is read with it, as one text (py_env_code)."""
        ran = frozenset()
        if kind == "py" and env:
            body, ran = self.py_env_code(body, env)
        why = self.py_acts(body, real, root, writes, ran) if kind == "py" else self.js_acts(body, writes)
        if why:
            return why
        for why, _, target, found in self.modules("it", real, root, body, kind):
            if why:
                return f"imports a module the gate cannot follow ({why})"
            inner = self.py_acts(found, target, root) if kind == "py" else self.js_acts(found)
            if inner:
                return f"imports {os.path.basename(target)}, which {inner}"
        return None

    @staticmethod
    def py_env_exec(node, os_names):
        """NAME where node is the call exec(os.environ["NAME"]), os under any name it was imported
        by (os_names), with nothing else handed to exec; else None."""
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "exec"
                and len(node.args) == 1 and not node.keywords and isinstance(node.args[0], ast.Subscript)):
            return None
        sub = node.args[0]
        held = sub.value
        if not (isinstance(held, ast.Attribute) and held.attr == "environ" and isinstance(held.value, ast.Name)
                and held.value.id in os_names):
            return None
        key = sub.slice
        return key.value if isinstance(key, ast.Constant) and isinstance(key.value, str) else None

    @staticmethod
    def py_os_names(tree):
        """The names a Python text imports os by (`import os`, `import os as _os`)."""
        return {a.asname or "os" for node in ast.walk(tree) if isinstance(node, ast.Import)
                for a in node.names if a.name == "os"}

    def py_env_code(self, text, env):
        """(text with the code it runs from its environment in front of it, the NAMEs taken).

        Inline Python that runs exec(os.environ["NAME"]) runs, in its own namespace, whatever the
        shell script put in NAME. Where env holds that text (sh_env_code: a literal the script wrote),
        it is put in front, so the two are read as the one program they are: a name either imports
        is held to the same rules in both. It goes round, since the code taken can run more. A NAME
        env does not hold is left, and py_acts counts that exec as running code."""
        ran = set()
        for _ in range(len(env) + 1):
            try:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore")
                    tree = ast.parse(text)
            except (SyntaxError, ValueError):
                break  # py_acts says it could not be parsed
            os_names = self.py_os_names(tree)
            found = {self.py_env_exec(node, os_names) for node in ast.walk(tree)}
            new = sorted(n for n in found - ran if n is not None and env.get(n) is not None)
            if not new:
                break
            text = "\n".join(env[n] for n in new) + "\n" + text
            ran.update(new)
        return text, frozenset(ran)

    @staticmethod
    def js_acts(text, writes=True):
        """acts() for one JavaScript or TypeScript file's text: how it can act on what it is handed, as
        a phrase, or None when it is seen unable to. It is unable to only when every module it imports
        that is not one of its own files is in JS_INERT, and it names none of JS_RUNS, JS_DYNAMIC,
        JS_ACTS (the old hand list, so nothing it refused passes) or JS_WRITES. A local module it imports is not judged here: modules() reaches it and acts()
        judges it with this same reading, and one that is not there is refused there. writes is False
        for code a shell script writes inline, where JS_WRITES is not counted (claude-config#2446)."""
        code = js_code(text)
        uses_fs = False
        for m in IMPORT_SPEC.finditer(code):
            spec = m.group(2)
            bare = spec.split("?", 1)[0]
            if "${" not in spec and (bare.startswith(("./", "../", "/", "file://")) or bare in (".", "..")):
                continue
            name = spec[5:] if spec.startswith("node:") else spec
            if "${" in spec or name not in JS_INERT:
                return f"imports a module the gate does not know to be unable to send a request, run code or write a file ({spec})"
            uses_fs = uses_fs or name in JS_FS
        hit = JS_RUNS.search(text) or JS_DYNAMIC.search(code) or JS_ACTS.search(text)
        if hit:
            return f"can send a request or run code ({hit.group(0).strip()})"
        hit = writes and (JS_WRITES.search(code) or JS_WRITES_METHOD.search(code) or
                          (JS_WRITES_SHORT.search(code) if uses_fs else None))
        if hit:
            return f"can write a file ({hit.group(0).strip(' (.')})"
        return None

    def py_acts(self, text, cur, root, writes=True, ran=frozenset()):
        """acts() for one Python file's text (cur its file, root the script's folder): how it can act
        on what it is handed, as a phrase, or None when it is seen unable to.

        writes is False for code a shell script writes inline (claude-config#2446): writing a file is
        not counted there, so PY_WRITES and open()'s mode are not read, PY_FILES may be imported, and
        so may os, held to OS_FILES: each use of the name it is imported by must be os.<one of them>,
        and any other use (os.system, os passed on or given another name) counts as acting. ran is
        the NAMEs whose code py_env_code put in front of text, so exec(os.environ[NAME]) for one of
        them is that code running, which is read here; any other exec counts as it always did.

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
        cur_dir = os.path.dirname(cur) if cur else root  # inline code has no file, and runs from root
        # Only this file's own sys.path changes: fewer folders in front can only leave an import to be
        # placed in the standard library, where it must then be inert, never the other way.
        inserts = ([], [])
        self.py_inserts(text, cur, inserts)

        nodes = list(ast.walk(tree))
        unknown = "a module the gate does not know to be unable to send a request or run code"
        bound = set()  # each name an import binds, whose attributes are another module's namespace
        restricted = set()  # (a, b) for `import a.b` where only a.b is inert, so a.<other> acts
        os_names = set()  # the names os is imported by, where writes are not counted
        for node in nodes:
            if isinstance(node, ast.Import):
                for a in node.names:
                    top = a.name.split(".")[0]
                    bound.add(a.asname or top)
                    if self.resolve_py(0, a.name, (), cur_dir, root, inserts) != []:
                        continue  # local (followed by modules()) or placed nowhere (refused there)
                    if not writes and a.name == "os":
                        os_names.add(a.asname or "os")
                        continue
                    if not writes and a.name in PY_FILES:
                        continue
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
                if not writes and (module in PY_FILES or (module == "os" and all(n in OS_FILES for n in names))):
                    continue
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
        # Each use of os as os.<one of OS_FILES>, and each exec that runs code already in this text.
        os_ok = {id(n.value) for n in nodes if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Name)
                 and n.value.id in os_names and n.attr in OS_FILES}
        ran_here = {id(n.func) for n in nodes if ran and self.py_env_exec(n, os_names) in ran}
        for node in nodes:
            if isinstance(node, ast.Name):
                if node.id in PY_RUNS and id(node) not in ran_here:
                    return f"can run code or reach past what the gate reads ({node.id})"
                if node.id in os_names and id(node) not in os_ok:
                    return f"uses {node.id} for more than its file, path and environment calls"
                if node.id in PY_REACH - {"modules"}:
                    return f"can evaluate a string as code ({node.id})"
                if node.id in restricted_names and id(node) not in cleared:
                    return f"uses {node.id} for more than {', '.join(sorted(f'{t}.{s}' for t, s in restricted))}"
                if writes and node.id == "open" and id(node) not in called:
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
                # os.stat is os's own call, not the stat module: one of OS_FILES straight off os.
                if isinstance(base, ast.Name) and base.id in bound and base.id != "sys" and a in stdlib \
                        and a not in PY_INERT and (base.id, a) not in restricted \
                        and not (base.id in os_names and node.value is base and a in OS_FILES):
                    return f"reaches the {a} module through {base.id}"
            elif isinstance(node, ast.Call) and writes:
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

    def shell_acts(self, body, d, zero=False, depth=0):
        """acts() for a shell script's body: the first of its commands that sends a request, runs what
        the script was handed, or hands it to a program not seen to be unable to act, as a phrase, or
        None.

        Handed means a word after the program's name holds an expansion of the script's arguments or
        of a variable set from them, a redirection's included (`nc host 443 < "$1"`), or the command
        opens a heredoc the shell expands them into. Two more routes are followed (claude-config#2446):
          - code the script writes and hands its arguments, with -c, a heredoc or a here string, is
            judged for what it does with them (sh_code_acts): shell code by this same reading (zero is
            True for a -c string, where $0 is an argument too), Python and JavaScript by acts_inline
            with writing not counted;
          - what a command that passes sends down a pipe goes to the command the pipe feeds, which is
            then judged as fed it (sh_command_acts), on through each program that only filters it.
        Both need each command's place in the script (sh_flow). Where there is none (the reader could
        only cut the script crudely), a script that pipes what it was handed, or that uses it and
        opens a heredoc the shell may expand it into (sh_doc_expands), is refused as a place the gate cannot
        follow (claude-config#2641). What it still does not follow, so a
        pass is not read as more than it measured: what the script writes with a redirection or by
        moving a file (SH_INERT says why), a variable set by read from a pipe or a file, a pipe or a
        heredoc inside a string a wrapper runs (eval, bash -c with no arguments handed), and a file
        the script sources that sets again a variable holding Python it runs (sh_env_code)."""
        if depth > MAX_DEPTH:
            return "nests code deeper than the gate reads"
        defined = set(re.findall(r"(?:^|[\s;&|(){}])(?:function\s+)?([A-Za-z_][\w:.-]*)\s*\(\s*\)", body))
        defined |= set(re.findall(r"\bfunction\s+([A-Za-z_][\w:.-]*)", body))
        names = {"OPTARG"} if "getopts" in body else set()
        while True:
            given = (POSITIONAL_ZERO if zero else POSITIONAL) + \
                (r"|\$\{?(?:" + "|".join(sorted(names)) + r")\b" if names else "")
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
        except self.sw.Unreadable:  # as in script_body: any other error is a fault (#2573, #2593)
            return "could not be read as commands to see what it does with its arguments"
        flow = self.sh_flow(body, d, records)
        piped = set()  # the commands a pipe feeds what the script was handed (their index in records)
        for idx, (_, text, _, _, _) in enumerate(records):
            rest, assigns = self.sw.command_rest(text)
            words = self.sw.command_words(rest)
            if words and not words[0].strip():
                # A line continued with a backslash inside $(...) comes back with the newline as its
                # first word and its assignments still in front (issue-spool.sh's append), so it is
                # read again from its first real word.
                rest, more = self.sw.command_rest(self.sw.rejoin([w for w in words if w.strip()]))
                words, assigns = self.sw.command_words(rest), assigns + "\n" + more
            if not words:
                continue
            if re.match(r"[A-Za-z_]\w*(\[[^]]*\])?\+?=", words[0]):
                continue  # an assignment (list+=("$1") too), which runs nothing
            # The heredocs this command opens, and whether the shell expands what was handed into one.
            docs = self.sh_heredocs(flow, idx, body)
            fed = idx in piped
            takes = fed or any(handed.search(w) for w in words[1:])
            expands = any(not quoted and handed.search(code) for quoted, code in docs or ())
            cmd = {"words": words, "docs": docs, "fed": fed, "takes": takes, "expands": expands,
                   "known": flow is not None,
                   "block": bool(flow and idx in flow["part"] and SH_BLOCK.match(
                       body[flow["part"][idx]["start"]:flow["part"][idx]["end"]])),
                   "env": lambda assigns=assigns: self.sh_env_code(assigns, body, names)}
            why = self.sh_command_acts(cmd, handed, defined, d, depth)
            if why:
                return why
            if not (takes or expands):
                continue
            # It passed, holding what was handed: whatever it pipes on goes to the next command.
            if flow is None:
                if SH_PIPE.search(body):
                    return "could not be read as commands to see where it pipes what it is handed"
                continue
            into = self.sh_piped_into(flow, idx)
            if into is not None:
                piped.add(into)
        if flow is None and handed.search(body) and self.sh_doc_expands(body):
            # No command has a place, so nothing says which heredoc feeds which command, and expands
            # was False for every one of them. The crude cut hands a heredoc's own lines back as
            # commands of the script, so `bash <<EOF` over `echo "$1"` read as a bash handed nothing
            # and an echo, and passed (claude-config#2641). Where the script uses what it was handed
            # and opens a heredoc the shell may expand it into, that is a place the gate cannot
            # follow, whatever the heredoc feeds: a shell, an interpreter, or a pipe on to one.
            return "could not be read as commands to see what a heredoc expands its arguments into"
        return None

    def sh_doc_expands(self, body):
        """Whether a script's text opens a heredoc the shell expands, which is one with no part of
        its marker quoted. Each opener is read by the shared reader (heredoc_openers), wherever a <<
        with a word after it is, a here string apart: in a text whose commands have no places
        nothing says which << sits in a string or in arithmetic, so one read as an opener by mistake
        errs toward refusing, and a marker starting with a digit is not missed."""
        return any(not quoted for _, _, _, quoted, _ in self.sw.heredoc_openers(body, marker_start=False))

    def sh_flow(self, body, d, records):
        """Where each command of a shell script's body is in it, for shell_acts: {"part": {its index
        in records: its part, as the reader's commands() gives it}, "heredocs": [(quoted, the text
        of the command up to the opener, body)]}. None where the reader could only cut the body
        crudely, so nothing says what a command pipes into or which heredoc feeds it. Only the
        script's own commands have a place: one inside a string a wrapper runs (deeper than 0 in
        records) has none."""
        heredocs, parts = [], []
        try:
            self.sw.commands(body, d, heredocs=heredocs, parts=parts)
        except self.sw.Unreadable:
            return None
        top = [i for i, r in enumerate(records) if r[4] == 0]
        if len(top) != len(parts):
            return None
        return {"part": dict(zip(top, parts)), "heredocs": heredocs}

    @staticmethod
    def sh_heredocs(flow, idx, body):
        """[(quoted, text)] for each heredoc the command at idx in records opens, [] for none, and
        None where its place is not known (sh_flow). A command written twice gets both bodies."""
        part = flow["part"].get(idx) if flow else None
        if part is None:
            return None
        out = []
        for start, _ in part["openers"]:
            before = body[part["start"]:start]
            out += [(quoted, text) for quoted, b, text in flow["heredocs"] if b == before]
        return out

    @staticmethod
    def sh_piped_into(flow, idx):
        """The index in records of the command the one at idx pipes into, or None: the command that
        starts soonest after it ends, a subshell's first command for `x | ( ... )`."""
        part = flow["part"].get(idx)
        if part is None or part["how"] != "|":
            return None
        after = [(q["start"], j) for j, q in flow["part"].items() if q["start"] >= part["end"]]
        return min(after)[1] if after else None

    def sh_env_code(self, assigns, body, names):
        """{NAME: text} for each NAME="$VAR" in front of a command where VAR holds Python the script
        wrote: set once in the script, to a single quoted literal (issue-spool.sh's
        ISSUE_SPOOL_SEEN_PY), bound no other way (sh_binds), and not set from what the script was
        handed (names). Inline code that runs exec(os.environ["NAME"]) is then read with that text
        (py_env_code); a NAME not here is code the gate cannot read."""
        out = {}
        for a in assigns.split("\n"):
            m = re.fullmatch(r"([A-Za-z_]\w*)=\$\{?([A-Za-z_]\w*)\}?", a.strip())
            if not m or m.group(2) in names:
                continue
            var = m.group(2)
            literal = re.findall(r"(?m)^[ \t]*" + re.escape(var) + r"='([^']*)'[ \t]*$", body)
            if len(literal) == 1 and not self.sh_binds(var, body, 1):
                out[m.group(1)] = literal[0]
        return out

    def sh_code_acts(self, code, name, d, zero, env, depth):
        """How code a shell script writes for the program name (with -c, a heredoc or a here string)
        acts on the arguments it is handed, as a phrase, or None: shell code by shell_acts, Python
        and JavaScript by acts_inline with writing not counted, any other language as acting."""
        if name in SHELLS:
            return self.shell_acts(code, d, zero, depth + 1)
        kind = "js" if JS_RUNTIME.match(name) else "py" if PY_RUNTIME.match(name) else None
        return self.acts_inline(code, d, kind, False, env())

    def sh_command_acts(self, cmd, handed, defined, d, depth):
        """How one command of a shell script acts on what the script was handed, as a phrase, or None.

        cmd is the command as shell_acts read it: its words, the heredocs it opens (docs, None where
        its place in the script is not known), whether a pipe feeds it what was handed (fed),
        whether it takes what was handed (takes: fed, or in a word), whether the shell expands what
        was handed into a heredoc it opens (expands: code, to a shell or an interpreter reading its
        input, and only text to any other program, as `done <<EOF` over a list of names is), whether
        the script's commands have places (known), whether it is the head of a loop or block
        (block), and env, which gives the Python its environment holds (sh_env_code)."""
        words, docs, fed = cmd["words"], cmd["docs"], cmd["fed"]
        lead = "pipes what it is handed into" if fed else "hands its arguments to"
        name = os.path.basename(words[0])
        if handed.search(words[0]):
            return f"runs a command named by its arguments ({words[0]})"
        if name in SENDERS:
            return f"sends a request ({name})"
        if name in ("source", ".", "eval"):
            if any(handed.search(w) for w in words[1:]):
                return f"runs the file it is handed ({name})"
            if fed and name != "eval":
                return f"runs what it is handed, through a pipe ({name})"
            return None
        if not cmd["takes"] and not (cmd["expands"] and (name in SHELLS or INTERPRETER.match(name))):
            return None
        if fed and cmd["block"]:
            # `cat "$1" | while read -r line; do eval "$line"; done`: the reads are commands of its own.
            return f"pipes what it is handed into a loop or block whose reads the gate does not follow ({name})"
        if "/" not in words[0] and (name[:-2] if name.endswith("()") else name) in defined:
            if fed:
                return f"pipes what it is handed into {name}, a function whose reads the gate does not follow"
            return None  # a definition, `show() { cat "$1"; }`, reads as a command named show()
        # A program is the tool its name says only by bare name or from a system folder: a local
        # ./grep or bin/cat is a script of its own, judged below by what it does.
        system = "/" not in words[0] or os.path.dirname(words[0]) in SYSTEM_BIN
        if system and name in SH_INERT:
            return None
        git = self.sw.git_read(words) if system and name == "git" else None
        if git and git[0] in GIT_INERT and not any(
                w in GIT_RUNS or w.startswith(GIT_RUNS) for w in git[1] + git[2]):
            return None
        if system and name == "find" and not set(words) & {"-exec", "-execdir", "-ok", "-okdir"}:
            return None  # find runs a program only through -exec and its kind
        if system and name in AWKS and not self.awk_runs(words):
            return None
        if name in SHELLS or INTERPRETER.match(name):
            operand, inline, stdin = self.operands(words)
            if inline:
                if any(handed.search(w) for w in inline[0]):
                    return f"loads a file it is handed before the code given to {name}"
                code = inline[1]
                if handed.search(code):
                    return f"runs code it is handed ({name})"
                if fed and name in SHELLS:
                    return f"pipes what it is handed into code given to {name}, whose reads the gate does not follow"
                # Code written into the script: judged for what it does with the arguments after it.
                inner = self.sh_code_acts(code, name, d, True, cmd["env"], depth)
                return f"{lead} code given to {name}, which {inner}" if inner else None
            if operand and handed.search(operand):
                return f"runs the file it is handed ({name})"
            if stdin and operand in (None, "-"):
                return self.sh_stdin_acts(cmd, name, handed, d, depth)
            if not operand or re.search(r"[$`]", operand):
                return (f"hands its arguments to {name} running a script or module the gate cannot "
                        f"read ({operand or ' '.join(words[1:3])})")
            path = self.resolve(operand, d)
            if not os.path.isfile(path):
                return f"hands its arguments to {name} running a script the gate cannot find ({operand})"
            kind = "js" if JS_RUNTIME.match(name) else "py" if re.match(r"(python|pypy)", name) else None
            inner = self.acts(path, d, name in SHELLS, kind)
            if inner:
                return f"hands its arguments to {os.path.basename(operand)}, which {inner}"
            if fed:
                return (f"pipes what it is handed into {os.path.basename(operand)}, whose reading of its "
                        f"input the gate does not follow")
            return None
        if name in ("done", "}", ")", "fi", "esac"):
            return (f"feeds what it is handed to a loop or block whose reads the gate does not follow "
                    f"({name} {' '.join(words[1:3])})")
        if not system and not re.search(r"[$`]", words[0]):
            path = self.resolve(words[0], d)
            if os.path.isfile(path):
                inner = self.acts(path, d, False, None)
                if inner:
                    return f"hands its arguments to {words[0]}, which {inner}"
                if fed:
                    return f"pipes what it is handed into {words[0]}, whose reading of its input the gate does not follow"
                return None
        return (f"hands its arguments to a program the gate does not know to be unable to send a "
                f"request or run code ({name})")

    def sh_stdin_acts(self, cmd, name, handed, d, depth):
        """sh_command_acts for a shell or interpreter that runs the code on its input, as a phrase,
        or None: a here string or a heredoc the script wrote is judged as code handed the command's
        arguments (sh_code_acts); what a pipe feeds it, or a here string or heredoc the shell
        expands what was handed into, is code the script was handed; and with none of them the code
        comes from wherever the script's own input does, which nothing here can read."""
        words, docs = cmd["words"], cmd["docs"]
        strings = [words[k + 1] if w == "<<<" and k + 1 < len(words) else w[3:]
                   for k, w in enumerate(words) if w.startswith("<<<")]
        if any(handed.search(s) for s in strings):
            return f"runs code it is handed ({name}, a here string)"
        if docs is None:
            if not cmd["known"]:
                return f"could not be read as commands to see what code it feeds {name}"
            return None  # inside a string a wrapper runs: its heredoc is not followed, as before
        if any(not quoted and handed.search(code) for quoted, code in docs):
            return f"runs code it is handed ({name}, a heredoc that expands it)"
        if not docs and not strings:
            if cmd["fed"]:
                return f"runs what it is handed, through a pipe ({name})"
            return f"hands its arguments to {name} running code from its input, which the gate cannot read"
        for code in [code for _, code in docs] + strings:
            inner = self.sh_code_acts(code, name, d, False, cmd["env"], depth)
            if inner:
                return f"hands its arguments to code it feeds {name}, which {inner}"
        return None

    @staticmethod
    def awk_runs(words):
        """Whether an awk command can run a program: its program comes from a file (-f), or names
        system(), a pipe to or from a command (`print | "sh"`, `"cmd" | getline`, `|&`) or a gawk
        extension (@load, @include). A program written in the command is read; `||` is not a pipe."""
        k = 1
        while k < len(words):
            w = words[k]
            if w in ("-F", "-v"):
                k += 2
            elif w.startswith(("-f", "--file", "--exec", "-E", "-i", "--include", "-l", "--load")):
                return True
            elif w.startswith("-") and w != "-":
                k += 1
            else:
                break
        program = words[k] if k < len(words) else ""
        return bool(re.search(r"\bsystem\s*\(|(?<!\|)\|(?!\|)|@load|@include", program)) or not program

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
            except self.sw.Unreadable:  # as in script_body: any other error is a fault (#2573)
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

    @staticmethod
    def family(name):
        """The OPTIONS family of a shell or interpreter, by its name; None for any other program,
        which then has no option holding code, so every file it is handed is read."""
        if name in SHELLS:
            return "shell"
        if PY_RUNTIME.match(name):
            return "py"
        if name in ("deno", "ruby", "perl", "php", "osascript"):
            return name
        return "js" if JS_RUNTIME.match(name) else None

    def operands(self, words):
        """(the script operand or None, the inline code or None, whether it reads its input).

        The inline code, where the program is given code by one of its own options (OPTIONS), is
        (the words before that option, the code, the words after the code): the words before can
        name files the program loads first (node -r), and those after are the code's arguments.

        A redirection is the shell's, never the program's operand (`bash <<'EOF'` reads its input,
        it runs no file named <<EOF), except that a file fed on stdin with < is the script it reads.
        """
        inline_words, letters, valued = OPTIONS.get(self.family(os.path.basename(words[0])), (set(), "", VALUED))
        cluster = re.compile(rf"^-[A-Za-z]{{1,4}}[{letters}]$") if letters else None
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
            return from_file, None, False
        k = 1
        inline = None
        while k < len(words):
            w = words[k]
            if w == "--":
                k += 1
                break
            if w == "-":
                return "-", None, True
            if w in inline_words or (cluster and cluster.match(w)):
                inline = (words[1:k], words[k + 1] if k + 1 < len(words) else "", words[k + 2:])
                break
            if w == "-m":
                return None, None, False  # a module: nothing on disk named here to read
            if w in valued:
                k += 2
                continue
            if w.startswith("-") or w.startswith("+"):
                k += 1
                continue
            break
        if inline:
            return None, inline, False
        if k < len(words):
            return words[k], None, False
        return None, None, True


def main():
    # A lone surrogate from the payload, echoed in a reason, must not raise on the way out (#1944).
    sys.stdout.reconfigure(errors="replace")
    # The watchdog (HARD_STOP_SECONDS), on the real clock only: it prints where the reader was and
    # ends it with a failure, which the wrapper refuses as a call it could not judge.
    if budget_clock()[0] is time.monotonic:
        faulthandler.dump_traceback_later(HARD_STOP_SECONDS, exit=True)
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
    judge = Judge(load_reader())
    try:
        judge.watch()
        try:
            reason = judge.line(cmd, cwd, 0, cmd)
        finally:
            judge.unwatch()
        if judge.overran:
            raise judge.overran  # interrupted, and the walk answered all the same (Judge.interrupt)
    except OutOfTime as e:
        # A verdict of its own, refused like any other, so the wrapper can say what to do instead
        # for a merge (claude-config#2576).
        print("outoftime\n" + judge.out_of_time(e.doing))
        return
    if reason:
        # A reason carrying an import the gate could not follow (recorded by modules() where it gives
        # up, never matched by its wording) is not a post it found, so it says the check could not be
        # made rather than claiming a post.
        lead = ("REFUSED: the gate could not check whether this command posts to Slack: "
                if judge.unfollowed and judge.unfollowed in reason else "REFUSED: this command posts to Slack: ")
        print("refuse\n" + lead + reason + ". " + draft_advice("with the same channel and thread"))
    else:
        print("allow")


if __name__ == "__main__":
    main()
