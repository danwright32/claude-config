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
    judged the same way (claude-config#2318). The one script let through is /nudge, at
    skills/nudge/nudge.py beside this hooks folder, by its real path; a copy anywhere else is refused
    like any other script that posts.

Limits, stated so nobody reads more into a pass than it measured: a JavaScript import of a package or
through a path alias (`@/lib/x`), a Python module not on disk beside the script (the standard library,
an installed package), a module run with `python3 -m`, and an import of another language's files are
not followed; a program run by bare name from the PATH is not read; and deliberate obfuscation (an
endpoint assembled from pieces, an import path built at run time) is not the threat this answers.
The threat is a session that means well choosing the quickest way to post.
"""
import ast
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
# code is in the command's own text, which is judged first, so this decides only that there is no
# script file to read.
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
# require('x'). Read from the text, comments included, which can only refuse more.
IMPORT_SPEC = re.compile(r"""(?:\bfrom|\bimport\s*\(?|\brequire\s*\()\s*(['"`])([^'"`\n]+)\1""")
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
        a Python module not on disk under root (the standard library, an installed package) are not
        ours to read. An import that names a local file the gate cannot find or read is refused,
        because node or Python may still find it (package.json exports, a path alias, a loader) and
        run what the gate never saw; so is a script reaching more than IMPORT_MAX_FILES modules. An
        import whose path is assembled at run time (a template holding ${...}, importlib) is not
        followed: no file is named to read."""
        seen = {origin} if origin else set()
        queue = [(origin, root, body, start)]
        while queue:
            cur, cur_dir, text, chain = queue.pop(0)
            for spec, targets in self.import_targets(text, kind, cur_dir, root):
                via = f"{chain}, which imports {spec}"
                if targets is False:
                    return f"{via}, a module the gate cannot find, so it cannot see what that runs"
                for target in targets:
                    target = os.path.realpath(target)
                    if target in seen:
                        continue
                    seen.add(target)
                    if len(seen) > IMPORT_MAX_FILES:
                        return (f"{start} imports more than {IMPORT_MAX_FILES} modules, past what the gate "
                                "reads, so it cannot see what they run")
                    try:
                        with open(target, "rb") as f:
                            found = f.read(MAX_FILE).decode("utf-8", "replace")
                    except OSError:
                        return f"{via} ({target}), a module the gate cannot read, so it cannot see what that runs"
                    hit = MARKER.search(found)
                    if hit:
                        return f"{via} ({target}), which posts to Slack (it names {hit.group(0)})"
                    queue.append((target, os.path.dirname(target), found, f"{via} ({os.path.basename(target)})"))
        return None

    def import_targets(self, text, kind, cur_dir, root):
        """(the import as written, the files it runs, or False when it names a local file not there),
        for each import in text; a package or a builtin gives an empty list."""
        if kind == "js":
            for m in IMPORT_SPEC.finditer(text):
                spec = m.group(2)
                if "${" in spec:
                    continue
                target = self.resolve_import(spec, cur_dir)
                if target is not None:
                    yield spec, ([target] if target else False)
            return
        for level, module, names in self.py_imports(text):
            spec = "." * level + module + (f" import {', '.join(names)}" if level and not module else "")
            yield spec, self.resolve_py(level, module, names, cur_dir, root)

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

    @staticmethod
    def resolve_py(level, module, names, cur_dir, root):
        """The local files a Python import runs (each package's __init__.py, the module, and any
        submodule it names), an empty list for one not on disk under root (the standard library or an
        installed package), or False for a relative import, or a local package's missing part, that
        names nothing there."""
        base = cur_dir if level else root
        for _ in range(max(level - 1, 0)):
            base = os.path.dirname(base)
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
            return False if (level or i) else []
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
        """The reason a command line posts, or None."""
        for d, text, wrapper, why, _ in self.sw.every_command(s, cwd):
            reason = self.record(d, text, wrapper, why, depth, whole)
            if reason:
                return reason
        return None

    def record(self, d, text, wrapper, why, depth, whole):
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
            return self.script(words[0], d, depth, False)
        return None

    def every_file(self, words, d, depth, shell_hint, lang=None):
        """The reason any word after the program that names a file posts, or None.

        Which word is the script depends on each program's own option table (python3 -I takes no
        value, ruby -I does), and a table that is wrong for one program hides the script behind an
        option. So every word naming a file is read, which can only refuse more (lessons review,
        2026-11-05, round 3)."""
        for w in words[1:]:
            if w.startswith("-") or w.startswith("+") or self.sw.REDIRECT_WORD.match(w):
                continue
            reason = self.script(w, d, depth, shell_hint, lang)
            if reason:
                return reason
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
        print("refuse\nREFUSED: this command posts to Slack: " + reason + ". " +
              draft_advice("with the same channel and thread"))
    else:
        print("allow")


if __name__ == "__main__":
    main()
