#!/usr/bin/env python3
"""Inline Python that runs a file it names in its own text, read as running that file
(claude-config#3397).

The Slack drafts gate read the code a command hands python3 (`-c`, a heredoc) for the endpoint it
names, for the local modules it imports, and for the files in the words after it. A file the code
names in its own text was never read: measured on main at a3ffbde735 on 2026-11-20 and again on
603a5d40c8 on 2026-11-22, `python3 posts.py` was refused while `python3 -c "import runpy;
runpy.run_path('./posts.py')"` and `python3 -c "exec(open('./posts.py').read())"` passed, with the
path written out or through the outer shell's variable.

THE RULE (Judge.py_file_runs), one more reading of that code after the ones there were, so it can
refuse a command those let through and never the reverse:

  * It is asked only of code that can run code or send a request, by the gate's own answer for a
    script handed a file (py_acts with writing left out, as handed_code asks it): code importing
    only modules known to be unable to and using no builtin that runs code only reads what it
    names, and nothing below is read for it. No list of the calls that run a file is kept for this,
    because a call missing from one would pass (L96): runpy, importlib, subprocess, os.system,
    exec, eval, compile and anything else not seen to be unable to act all count.
  * Every string the code holds that names a file on disk is a file the code is handed, as a file
    in the words after it is: it is judged as `python3 <file>` is (Judge.script), by what it is (a
    shell script as commands, a data file by the endpoint it names). A string is taken as written,
    as an f-string, a + or os.path.join of such strings, a name set once to one, a value the
    command puts in the environment or in sys.argv (py_path_expr), each from the folder the
    command runs in and from a folder the code moves to with os.chdir. So is the file the command
    feeds the code on its input (`python3 -c '...' < file`). A string naming a folder that holds
    __main__.py names that file, which runpy.run_path and python3 run when handed the folder.
  * The code is whatever the command itself carries for python3: given by -c, fed in a heredoc or a
    here string, or written out and piped in (`echo "..." | python3`).
  * Every string that is a command line starting with a program the gate reads by its name
    (holds_command, the reading lib/unknown-program.py gives a quoted word), and every list, tuple
    or call whose strings hold such a name (`['bash', 'run']`, `os.execlp('python3', 'python3',
    'x.py')`), is read as the command it spells.
  * A module run by a name written out (runpy.run_module, importlib.import_module, __import__) is
    read as an import of it is, behind the code's own sys.path changes.
  * A file run by a path the gate cannot work out is one it never read, and the command is refused
    as unread where it is typed: the path handed to runpy.run_path, to importlib's
    spec_from_file_location and file loaders, and, in code that names exec, eval or compile, to
    anything that opens a file (PATH_SINKS, OPENERS). A path is worked out where it is one of the
    strings above, and left to the reading of the command's words where it comes from sys.argv.
    One holding a $ or a backquote the shell fills in, in code given in double quotes or in a
    heredoc the shell expands, is not worked out unless the gate can fill it in itself (sh_word),
    and nor is a relative one where the folder is not certain.
  * A file run that way which is not text (an archive holding __main__.py, compiled code) is one
    the gate cannot read, and is refused as unread where it is typed.
  * Code this python3 cannot parse is read for its quoted strings alone. Where it names a way to
    run a file (SINK_WORDS), the shell filling part of it in or not, what it runs was never read,
    and it is refused as unread where it is typed. The gate's python3 can be older than the one
    the command starts, so code it cannot parse may still run.

WHERE IT CANNOT TELL, AND WHICH WAY IT FALLS. Code that can run code and also names a file it only
reads (`import subprocess, json; json.load(open('named.json'))`) is not told from code that runs
that file: the file is read as one the code may run, and a data file naming an endpoint refuses
the command. "Can run code" is the gate's own answer, so it holds every module the gate does not
know to be unable to (`import shutil`). Code that names exec and opens a file by a path that cannot
be worked out is refused whether or not the text it reads is what it runs. Code it cannot parse
that holds the word exec only in a string is refused as code that runs something unread. All fall
toward refusing.

ON DISK. In a script on disk a file is read as one the code may run only where the code hands it
to something that runs a file: a path sink, anything that opens a file in code naming exec, eval
or compile, or a command its strings spell. A file it names any other way is left as it was there.
tests/test-readme-mods-table.sh loads a module by its path and then reads README.md, which names
the endpoints where it describes this gate, and the gate's own suite holds that a session can run
that suite (claude-config#2678): with every string read there, it was refused (measured
2026-11-22). A typed command's every string is read.

WHAT IS LEFT ALONE ON PURPOSE. A file that open() is handed with a mode written out that only
writes (w, a or x, with neither r nor +) is not one the code reads, so it is not read as one it
may run (py_opens_to_write). The same path named anywhere else in the code still is.

WHAT IT DOES NOT COVER. Code the shell fills in whole, or in part outside a string, that names no
way to run a file as it is written (`python3 -c "$(cat x.py)"`, `python3 -c "$CODE"`) is not read:
measured 2026-11-22, each passes where x.py posts. Refusing all such code refused the timing line
#3278 holds must pass. A module run by a name built at run time is not followed, as an import
built at run time is not. A program started with a command built at run time (`subprocess.run(cmd)`)
is not read, as `$cmd` typed in a shell is not (#2683). Text the code reads from a pipe and runs
(a file's text piped into inline code that execs whatever its input holds) is not read where it
comes from a file, since the code names no file. A way to open a file that
OPENERS does not hold, by a path built at run time, is not seen. Code handed to a module python3
runs with -m (`python3 -m timeit "..."`) is not read as code. A Python file on disk that runs a
file it names (`python3 runner.py`, `import runner`, `python3 - < runner.py`) is read as it was:
this reading is of code the command itself carries. In a script on disk only a finding that
something posts stands, and a path or code that cannot be worked out is left as it was there, as
an unread feed is.

A FOLDER OR AN ARCHIVE IN PLACE OF A SCRIPT (py_run_words, claude-config#3441). Measured on main at
bfc43f1b53 on 2026-11-24: `python3 pkg`, where pkg/__main__.py posts, and `python3 app.zip`, where
the archive holds one, passed in every spelling tried. A word naming a folder names no file, so
nothing was read for it, and an archive was read as the text it is not. The gate's every_file now
asks py_run_words about the words of every Python command before it reads them:

  * A word naming a folder that holds a __main__.py is replaced by that file, and the words are
    read again as the gate reads any words. So a folder python3 runs is read as its script, and a
    folder handed to code is read as a file handed to it is. A pattern the shell fills in with
    such folders (`python3 pk*`) is replaced by each one's __main__.py.
  * The word python3 runs as its script is refused as unread, where typed, when py_handed says it
    is something the gate cannot read: an archive, a path under one, a folder whose __main__ is
    compiled, an extension module or a package (WHAT A PATH RUNS below).
  * An archive that is an argument, after the script or after code given by -c, is data far more
    often than code and is judged as it was.

WHAT A PATH RUNS WHEN IT IS NOT A SCRIPT'S TEXT (py_handed, claude-config#3441). A call that runs
the file at a path (PATH_SINKS) was refused as unread only for a file with a NUL in its first line.
Measured on main at bfc43f1b53 on 2026-11-24, each of these passed, handed to runpy.run_path in
code given by -c: an archive zipapp wrote with a #! line in front, an archive with a Python file's
text in front, a path under an archive, a folder whose only __main__ is compiled, and a folder
holding a package named __main__. What Python does with each was measured the same day with files
that only print (Python 3.14.4), and py_handed answers by it:

  * Handed a folder, python3 and runpy.run_path run the __main__.py in it (read as that file
    since #3397).
  * Handed a file whose last 65,557 bytes hold a zip end record, they run the __main__.py inside
    it, whatever the file is called and whatever text stands in front: py_archive, which looks
    exactly as far back as zipimport does. Handed a path under such a file (app.zip/inner), they
    run the __main__.py under that path inside it. The gate does not open an archive: what is
    inside imports from inside it, which none of the gate's readers follow, so reading one file of
    it would pass an archive whose other files post. It is refused as unread where it is typed,
    whatever it holds.
  * Handed a folder with no __main__.py and a compiled __main__.pyc, they run that. One holding an
    extension module named __main__, or a package named __main__ (which this Python refuses to run
    and another may not), is not a __main__.py the gate can read either. Each is refused as unread
    where it is typed.

  Only a path handed to a call that runs the file at it is judged this way. An archive the code
  names any other way is data far more often than code (a spreadsheet, a wheel and a document are
  all zip files), and is judged as it was. A folder holding no __main__ at all runs nothing and
  passes.

PYTHON'S OWN OPTIONS (py_own_reading, claude-config#3539). Which word of a command python3 runs
was decided by the gate's table of options (operands), and that table is not Python's reader.
Measured on main at 35f85db5cd on 2026-11-24, against what python3 3.14.4 and 3.9.6 themselves
ran for 110 shapes of command line with scripts that only print (one run of each on each, the two
agreeing on all but -P, which 3.9 does not know): each of these ran something that posts and
passed.

  * `python3 posts.py -m x` runs posts.py, -m being the script's own argument. No file of a
    command holding the word -m anywhere was read, for python3 or any other interpreter.
  * `python3 -c'import posts'` and `-Bc'import posts'` run the code glued to -c. The table took
    the word for an option with no value and the next file for the script. `python3 -bBEsuc CODE`
    runs CODE; the table knew a run of at most four letters before the c.
  * `python3 -Wc posts.py` and `-Xc posts.py` run posts.py: -W and -X take the rest of their word
    as their value. The table took the word for -c and posts.py for code.
  * `python3 -BW quiet.py posts.py` runs posts.py: -W or -X ending a word takes the next word.
    The table took quiet.py for the script and posts.py for a file it is handed.
  * `python3 -mdoc` runs the module doc. The table took `-m` and up to three letters before a c
    for -c, and the module was never read.
  * `python3 -- -post.py` runs the file named -post.py, and `python3 -- -` the code on its input.
    A script whose name starts with a dash was never read, nor that code.
  * `PYTHONPATH=onpath python3 -W error::warnmod.Loud quiet.py` imports warnmod before anything
    else runs: a -W value whose third field names a class by its module has Python import that
    module, from PYTHONPATH and the standard places (not from the folder of the script).

py_cmdline reads the words as CPython's own reader does (Python/getopt.c and the loop over it in
Python/initconfig.c): a word that is `-` or starts with no dash ends the options and is the code
on the input or the script; `--` ends them and the next word is the script whatever it starts
with, or `-`; in a run of letters, c, m, W and X take the rest of the word, or the next word where
the run ends there, and c and m end the options; `--check-hash-based-pycs` takes the next word;
every other letter or long option takes none. A letter or long option Python does not know stops
it with an error, as do -h, -V and their long forms without one, and is read on past here, so more
is read than runs and never less.

py_own_reading is one more reading, made before the table's and never in its place, so it can
refuse a command the table lets through and never the reverse:

  * The module each -W value names is read as one imported by code given to python3 is.
  * Where the table's answer (operands, py_module) is not Python's, the command is spelled again so
    the table reads it as Python does (py_respell: the script as the first word after python3, with
    ./ in front of a name starting with a dash; `-c` and the code as two words; `-m` and the module
    as two words; `-` alone), with its words as they were written, quotes and all, and that text
    is judged as the command itself is. The options left out load nothing but the -W module above.
  * A spelling is used only once the gate's own reader gives back the words it was built for. Where
    neither the words as written nor those words quoted afresh read back so, what python3 runs is
    refused as unread where the command is typed, and left as it was in a script on disk.
"""
import ast
import os
import re
import shlex

# The builtins that run text as code: code naming one may run whatever a file it opens holds.
TEXT_RUNNERS = frozenset({"exec", "eval", "compile"})
# A call that runs the file at a path, by the last part of its name: where that path stands among
# its arguments, and the keywords it goes by.
PATH_SINKS = {
    "run_path": (0, ("path_name",)),
    "spec_from_file_location": (1, ("location",)),
    "SourceFileLoader": (1, ("path",)),
    "SourcelessFileLoader": (1, ("path",)),
    "ExtensionFileLoader": (1, ("path",)),
    "load_source": (1, ("pathname",)),
    "load_compiled": (1, ("pathname",)),
    "zipimporter": (0, ("archivepath", "path")),
}
# A call that runs a module by its name, and the keyword that name goes by.
MODULE_SINKS = {"run_module": "mod_name", "import_module": "name", "__import__": "name"}
# A call that opens the file its first argument names, by the last part of its name.
OPENERS = frozenset({"open", "Path", "PurePath", "PosixPath", "WindowsPath", "FileIO", "getlines", "getline"})
PATH_CLASSES = frozenset({"Path", "PurePath", "PosixPath", "WindowsPath"})
# What reads the command's own words into a value: argparse's parsers.
ARG_PARSERS = frozenset({"parse_args", "parse_known_args", "parse_intermixed_args"})
# The calls that hand one of the command's words on as the path it is: an argument parser, a join
# or a tidying of the path, a reordering of the words. Through any other call the value is no
# longer a word the gate read.
WORD_CALLS = ARG_PARSERS | frozenset({"join", "abspath", "realpath", "normpath", "expanduser", "resolve",
                                      "Path", "PurePath", "PosixPath", "str", "fspath", "sorted", "list",
                                      "tuple", "reversed"})
MODULE_NAME = re.compile(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*")
SHELL_FILLS = re.compile(r"[$`]")
# The words that name a way to run a file, for code this python3 cannot parse.
SINK_WORDS = re.compile(r"\b(?:exec|eval|compile|run_path|run_module|import_module|__import__|"
                        r"spec_from_file_location|\w*FileLoader|load_source)\b")
# A quoted string on one line, for the same code.
CRUDE_STRING = re.compile(r"""'([^'\\\n]*)'|"([^"\\\n]*)\"""")
# The file a command feeds a program on its input.
INPUT_FROM = re.compile(r"0?<(?![<>&])(.*)\Z", re.S)
# How long a string naming a file can be, how many passes work out a name set from another, and how
# many command lines one text's strings may spell before the command is refused as unread.
MAX_PATH = 1024
MAX_PASSES = 5
MAX_LINES = 12
# The record that ends a zip archive, and how far from the end of a file zipimport looks for it:
# the record's own 22 bytes behind the longest comment it can carry (claude-config#3441).
ZIP_END = b"PK\x05\x06"
ZIP_TAIL = 22 + 65535
# A name in a folder that python3 runs as its __main__ and the gate cannot read: compiled code, or
# an extension module under any build tag.
MAIN_NOT_TEXT = re.compile(r"__main__(?:\.[^/]*)?\.(?:pyc|so|pyd)\Z")
# How many folders up from a path that names nothing an archive holding it is looked for.
MAX_UP = 64
# What makes a word a pattern the shell replaces with its matches.
FOLDER_PATTERN = re.compile(r"[*?\[{]")
# Python's short options that take a value, the rest of their word or the next word, and its one
# long option that takes the next word (PYTHON'S OWN OPTIONS above, claude-config#3539).
PY_VALUE_LETTERS = "cmWX"
PY_VALUE_LONG = "--check-hash-based-pycs"


def make(py_nodes, unknown_dir):
    """The Judge's base for the rule. py_nodes is the gate's own parse of a Python text, kept once
    for each text, and unknown_dir what it calls a folder it cannot work out."""

    class PyFileRuns:

        @staticmethod
        def py_shell_fills(raw):
            """Whether the shell fills something in inside one raw word before the program gets it:
            a $name, ${...}, $(...) or a backquote outside single quotes."""
            i, n, dq = 0, len(raw), False
            while i < n:
                c = raw[i]
                if c == "\\":
                    i += 2
                    continue
                if c == "'" and not dq:
                    j = raw.find("'", i + 1)
                    if j < 0:
                        return True
                    i = j + 1
                    continue
                if c == '"':
                    dq = not dq
                elif c == "`":
                    return True
                elif c == "$":
                    nxt = raw[i + 1:i + 2]
                    if nxt == "'" and not dq:  # $'...', whose text the shell does not fill in
                        j = i + 2
                        while j < n and raw[j] != "'":
                            j += 2 if raw[j] == "\\" else 1
                        i = j + 1
                        continue
                    if nxt and (nxt.isalnum() or nxt in "_{(@*#?$!-"):
                        return True
                i += 1
            return False

        def py_inline_runs(self, label, code, here, d, depth, text, words):
            """py_file_runs for the code a command gives python3 by -c: the code as Python gets it
            where the shell fills something in and the gate can work that out, and the file the
            command feeds it on its input. text is the command, words its words."""
            raw = None
            try:
                given = self.operands(self.raw_words(text) or words)[1]
                raw = given[1] if given else None
            except (IndexError, ValueError):
                raw = None
            filled = False
            if raw is None:
                filled = bool(SHELL_FILLS.search(code))
            elif self.py_shell_fills(raw):
                value, splits = self.sh_word(raw, self.sh_cwd(d), self.sh_source_var, self.shell["script"], False)
                if value is not None and not splits:
                    code = value
                else:
                    filled = True
            fed = None
            for k, w in enumerate(words[1:], 1):
                m = INPUT_FROM.match(w)
                if m:
                    fed = m.group(1) or (words[k + 1] if k + 1 < len(words) else None)
            return self.py_file_runs(label, code, here, d, depth, filled, fed)

        def py_fed_runs(self, label, code, here, d, depth, text):
            """py_file_runs for the code a command feeds python3 in a heredoc, whose body the shell
            fills in unless its delimiter is quoted. text is the command as the script wrote it."""
            m = re.search(r"<<-?\s*(\\?)(['\"]?)[A-Za-z0-9_]+\2", text)
            quoted = bool(m and (m.group(1) or m.group(2)))
            return self.py_file_runs(label, code, here, d, depth, not quoted and bool(SHELL_FILLS.search(code)))

        def py_text_value(self, node, here, known):
            """The string a Python expression certainly gives, or None: one written out, an
            f-string of such strings, a name set once to one (known), and what the gate's reading
            of a sys.path entry works out (py_path_expr: +, os.path.join, Path, sys.argv[n],
            os.environ)."""
            if isinstance(node, ast.Constant):
                return node.value if isinstance(node.value, str) else None
            if isinstance(node, ast.Name):
                return known.get(node.id)
            if isinstance(node, ast.JoinedStr):
                out = []
                for part in node.values:
                    if isinstance(part, ast.FormattedValue) and part.format_spec is None:
                        part = self.py_text_value(part.value, here, known)
                        if part is None:
                            return None
                        out.append(part)
                    elif isinstance(part, ast.Constant) and isinstance(part.value, str):
                        out.append(part.value)
                    else:
                        return None
                return "".join(out)
            if isinstance(node, ast.Call) and len(node.args) > 1 and not node.keywords \
                    and self.py_call_name(node) in PATH_CLASSES:
                parts = [self.py_text_value(a, here, known) for a in node.args]
                return os.path.join(*parts) if all(p is not None for p in parts) else None
            if isinstance(node, (ast.BinOp, ast.Call, ast.Subscript, ast.Attribute)):
                try:
                    got = self.py_path_expr(node, None, here, known)
                except (TypeError, ValueError):
                    return None
                return got if isinstance(got, str) else None
            return None

        @staticmethod
        def py_call_name(node):
            """The last part of the name a call is made by (`open`, `run_path`), or ""."""
            f = node.func
            return f.id if isinstance(f, ast.Name) else f.attr if isinstance(f, ast.Attribute) else ""

        @staticmethod
        def py_target_names(target):
            """The names an assignment's target binds."""
            return [n.id for n in ast.walk(target) if isinstance(n, ast.Name)]

        def py_bindings(self, nodes):
            """(for each name the code binds, the expressions it is set to, or None where it is
            bound some other way; (the names bound, the expression they are bound from) for every
            binding). A function's parameter is set to what the one call of that function hands
            it; with no call or more than one it is bound some other way."""
            binds, pairs = {}, []

            def bind(name, value):
                if value is None or binds.get(name, ()) is None:
                    binds[name] = None
                else:
                    binds.setdefault(name, []).append(value)

            calls = {}
            for node in nodes:
                if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                    calls.setdefault(node.func.id, []).append(node)
            for node in nodes:
                if isinstance(node, ast.Assign):
                    for t in node.targets:
                        pairs.append((self.py_target_names(t), node.value))
                        if isinstance(t, ast.Name):
                            bind(t.id, node.value)
                        else:
                            for name in self.py_target_names(t):
                                bind(name, None)
                elif isinstance(node, (ast.AnnAssign, ast.NamedExpr)) and isinstance(node.target, ast.Name):
                    if node.value is not None:
                        pairs.append(([node.target.id], node.value))
                    bind(node.target.id, node.value)
                elif isinstance(node, ast.AugAssign):
                    for name in self.py_target_names(node.target):
                        bind(name, None)
                elif isinstance(node, (ast.For, ast.AsyncFor, ast.comprehension)):
                    pairs.append((self.py_target_names(node.target), node.iter))
                    for name in self.py_target_names(node.target):
                        bind(name, None)
                elif isinstance(node, ast.withitem) and node.optional_vars is not None:
                    pairs.append((self.py_target_names(node.optional_vars), node.context_expr))
                    for name in self.py_target_names(node.optional_vars):
                        bind(name, None)
                elif isinstance(node, ast.ExceptHandler) and node.name:
                    bind(node.name, None)
                elif isinstance(node, (ast.Import, ast.ImportFrom)):
                    for a in node.names:
                        bind((a.asname or a.name).split(".")[0], None)
                elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                    args = node.args
                    params = [a.arg for a in args.posonlyargs + args.args]
                    every = params + [a.arg for a in args.kwonlyargs] + \
                        [a.arg for a in (args.vararg, args.kwarg) if a is not None]
                    made = calls.get(getattr(node, "name", None)) or []
                    for call in made:
                        for k, value in enumerate(call.args):
                            if k < len(params) and not isinstance(value, ast.Starred):
                                pairs.append(([params[k]], value))
                        for kw in call.keywords:
                            if kw.arg in every:
                                pairs.append(([kw.arg], kw.value))
                    one = made[0] if len(made) == 1 else None
                    plain = one is not None and not any(isinstance(a, ast.Starred) for a in one.args) \
                        and all(kw.arg for kw in one.keywords)
                    handed = {}
                    if plain:
                        handed = {params[k]: v for k, v in enumerate(one.args) if k < len(params)}
                        handed.update({kw.arg: kw.value for kw in one.keywords})
                    for name in every:
                        bind(name, handed.get(name))
                    if not isinstance(node, ast.Lambda):
                        bind(node.name, None)
                elif isinstance(node, ast.ClassDef):
                    bind(node.name, None)
                elif isinstance(node, ast.Delete):
                    for t in node.targets:
                        for name in self.py_target_names(t):
                            bind(name, None)
            return binds, pairs

        def py_set_once(self, binds, here):
            """{name: its string} for each name the code sets exactly once, to a string the gate
            can work out, one name through another (MAX_PASSES deep)."""
            known = {}
            for _ in range(MAX_PASSES):
                grew = False
                for name, values in binds.items():
                    if name in known or not values or len(values) != 1:
                        continue
                    value = self.py_text_value(values[0], here, known)
                    if value is not None:
                        known[name] = value
                        grew = True
                if not grew:
                    break
            return known

        @staticmethod
        def py_from_words(nodes, pairs):
            """A test of whether an expression holds what the command's own words hand the code:
            sys.argv, what argparse reads from it, or a name bound from either. The file such a
            path names is read by the gate's reading of the words after the code, as before."""
            names = {a.asname or "argv" for n in nodes if isinstance(n, ast.ImportFrom) and n.module == "sys"
                     for a in n.names if a.name == "argv"}

            def mentions(node):
                found = False
                for sub in ast.walk(node):
                    if isinstance(sub, ast.Call):
                        f = sub.func
                        called = f.id if isinstance(f, ast.Name) else f.attr if isinstance(f, ast.Attribute) else ""
                        if called not in WORD_CALLS:
                            # What a call makes of a word is not that word: the text of a file
                            # the word names (open(sys.argv[1]).read()) is a path nobody read.
                            return False
                        found = found or called in ARG_PARSERS
                    elif isinstance(sub, ast.Attribute) and sub.attr == "argv":
                        found = True
                    elif isinstance(sub, ast.Name) and sub.id in names:
                        found = True
                return found

            for _ in range(MAX_PASSES):
                grew = False
                for targets, value in pairs:
                    if not set(targets) <= names and mentions(value):
                        names.update(targets)
                        grew = True
                if not grew:
                    break
            return mentions

        @staticmethod
        def py_opens_to_write(node):
            """Whether a call of open() only writes the file it names: a mode written out that
            holds w, a or x and neither r nor +. That file is not one the code reads."""
            mode = next((k.value for k in node.keywords if k.arg == "mode"), node.args[1] if len(node.args) > 1 else None)
            return isinstance(mode, ast.Constant) and isinstance(mode.value, str) \
                and bool(set(mode.value) & set("wax")) and not set(mode.value) & set("r+")

        def py_names(self, nodes, here, filled, cwd_known):
            """What a Python text names that it may run, in the order written: (each string that
            may name a file, each folder the code moves to, each command line its strings spell,
            each (call, module) run by name, each file run by a path that cannot be worked out, as
            the call is written)."""
            binds, pairs = self.py_bindings(nodes)
            known = self.py_set_once(binds, here)
            from_words = self.py_from_words(nodes, pairs)
            value = lambda n: self.py_text_value(n, here, known)  # noqa: E731
            runs_text = any(isinstance(n, ast.Name) and n.id in TEXT_RUNNERS for n in nodes)
            texts, folders, rows, mods, unworked, ran = [], [], [], [], [], []
            written = set()  # id() of each path a call of open() only writes
            moved_unknown = False
            sinks = []  # (the call's name, the expression holding its path)
            for node in nodes:
                if not isinstance(node, ast.Call):
                    continue
                name = self.py_call_name(node)
                unpacked = any(isinstance(a, ast.Starred) for a in node.args) or any(k.arg is None for k in node.keywords)
                if name == "open" and node.args and self.py_opens_to_write(node):
                    written.add(id(node.args[0]))
                    continue
                if name == "chdir" and node.args:
                    folder = value(node.args[0])
                    if folder is None:
                        moved_unknown = True
                    else:
                        folders.append(os.path.normpath(self.resolve(folder, here)))
                if name in PATH_SINKS:
                    at, keywords = PATH_SINKS[name]
                    arg = next((k.value for k in node.keywords if k.arg in keywords),
                               node.args[at] if len(node.args) > at else None)
                    if unpacked:
                        unworked.append(f"{name} given its arguments unpacked")
                    elif arg is not None:
                        sinks.append((name, arg))
                elif runs_text and name in OPENERS:
                    arg = next((k.value for k in node.keywords if k.arg == "file"), node.args[0] if node.args else None)
                    if unpacked:
                        unworked.append(f"{name} given its arguments unpacked")
                    elif arg is not None and not (isinstance(arg, ast.Constant) and not isinstance(arg.value, str)):
                        sinks.append((name, arg))
                if name in MODULE_SINKS and (name != "__import__" or isinstance(node.func, ast.Name)):
                    arg = next((k.value for k in node.keywords if k.arg == MODULE_SINKS[name]),
                               node.args[0] if node.args else None)
                    module = value(arg) if arg is not None else None
                    if module and MODULE_NAME.fullmatch(module) and (name, module) not in mods:
                        mods.append((name, module))
                strings = [a.value for a in node.args if isinstance(a, ast.Constant) and isinstance(a.value, str)]
                if len(strings) > 1 and len(strings) == len(node.args):
                    rows.append(strings)
            for name, arg in sinks:
                got = value(arg)
                if got is None:
                    if not from_words(arg):
                        unworked.append(f"{name}({ast.unparse(arg)[:80]})")
                    continue
                texts.append(got)
                ran.append((name, got))
                relative = not os.path.isabs(os.path.expanduser(got))
                if filled and SHELL_FILLS.search(got):
                    unworked.append(f"{name}({ast.unparse(arg)[:80]}), which the shell fills in before Python reads it")
                elif relative and (moved_unknown or not cwd_known):
                    unworked.append(f"{name}({ast.unparse(arg)[:80]}), from a folder the gate cannot work out")
            for node in nodes:
                if id(node) in written:
                    continue
                if isinstance(node, (ast.List, ast.Tuple)):
                    strings = [e.value for e in node.elts if isinstance(e, ast.Constant) and isinstance(e.value, str)]
                    if len(strings) > 1 and len(strings) == len(node.elts):
                        rows.append(strings)
                elif isinstance(node, (ast.Constant, ast.JoinedStr, ast.BinOp, ast.Call)) or (
                        isinstance(node, ast.Subscript) and self.dotted(node.value) == "os.environ"):
                    got = value(node)
                    if got is not None:
                        texts.append(got)
            return texts, folders, rows, mods, unworked, ran

        def py_archive(self, path):
            """Whether python3 would run the file at path as an archive, by the __main__.py inside
            it: a zip end record within the last ZIP_TAIL bytes, which is where zipimport looks for
            one, whatever the file is called and whatever stands in front of the archive. A file an
            earlier command of this call made is read by what it was made from as well. A file
            that cannot be opened is one Python cannot open either."""
            sources = [path]
            for kind, value, _ in self.made_from(path) or ():
                if kind == "file":
                    sources.append(value)
                elif kind == "text" and ZIP_END.decode("latin-1", "strict") in value:
                    return True
            for source in sources:
                try:
                    # Through the gate's own open, so the judgement cache records the read
                    # (lib/judgement-cache.py); 2 is io.SEEK_END, written out because the cache's
                    # stand in for os knows only the names it lists.
                    with open(source, "rb") as f:
                        f.seek(0, 2)
                        f.seek(max(f.tell() - ZIP_TAIL, 0))
                        if ZIP_END in f.read(ZIP_TAIL):
                            return True
                except OSError:
                    continue
            return False

        def py_handed(self, path):
            """What python3, or a call that runs the file at a path, runs when handed path, where
            that is something the gate cannot read, as words for a refusal: an archive, a path
            under one, or a folder whose __main__ is compiled, an extension module or a package.
            None for a file of text, for a folder whose __main__.py is one (read as that file
            where it is named), and for a path that runs nothing (WHAT A PATH RUNS above). A folder
            an earlier command of this call copies is read by the folder it was copied from as
            well."""
            if self.is_file(path):
                if self.py_archive(path):
                    return "an archive, which Python runs by the __main__.py inside it"
                return None
            has_main = self.is_file(os.path.join(path, "__main__.py"))
            for folder in (path, (self.made_dirs.get(os.path.realpath(path)) or (None,))[0]):
                try:
                    names = sorted(os.listdir(folder)) if folder else []
                except OSError:
                    names = []  # no folder there, or one Python cannot list either
                for name in names:
                    if name == "__main__" and os.path.isdir(os.path.join(folder, name)):
                        return "a folder holding a package named __main__, which is not a __main__.py"
                    if MAIN_NOT_TEXT.match(name) and not (has_main and name.endswith(".pyc")):
                        return f"a folder Python runs by its {name}, which is not text"
            if has_main:
                return None
            # A path that names nothing on disk can lie inside an archive: the nearest thing above
            # it that is there says which.
            head = path.rstrip("/") or path
            for _ in range(MAX_UP):
                if os.path.lexists(head) or self.is_file(head):
                    if self.is_file(head) and self.py_archive(head):
                        return (f"a path under the archive {os.path.basename(head)}, which Python "
                                "runs by the __main__.py inside it")
                    break
                parent = os.path.dirname(head)
                if parent == head:
                    break
                head = parent
            return None

        def py_run_words(self, words, d, runs_slot):
            """(the words with each folder Python runs replaced by the __main__.py in it, the
            reason what python3 runs cannot be read or None) (A FOLDER OR AN ARCHIVE above). The
            caller reads the first as it reads any words, and the words as they were written as
            well, so this can only refuse more.

            runs_slot says python3 runs one of these words as its script (it was given no code by
            -c, no module by -m and none on its input). That word is the one in the script's place
            by the gate's table of options (operands) and, where that table is wrong, the first
            word that is no option and names something on disk; a command the table places
            otherwise than Python does is also read spelled as Python reads it (py_own_reading,
            claude-config#3539), where the table's word is Python's. Either is refused as unread,
            where it is typed, when it is an archive, a path under one, or a folder whose __main__ is not
            text (py_handed). Every word naming a folder that holds a __main__.py is replaced by
            that file, wherever it stands: its place decides how it is read (the script, or a file
            handed to code that may run it), and that is the caller's to say, as it is for a file.
            So is a pattern the shell fills in with such folders. A word a redirection names is the
            shell's and is left as it is."""
            slot = self.operands(words)[0] if runs_slot else None
            out, first, target = list(words[:1]), runs_slot, False
            for w in words[1:]:
                redirect = self.sw.REDIRECT_WORD.match(w)
                if target or redirect or not w or w[:1] in "-+" or len(w) > MAX_PATH or "\0" in w or "\n" in w:
                    target = bool(redirect) and not redirect.group(1)
                    out.append(w)
                    continue
                path = self.resolve(w, d)
                in_slot = runs_slot and w == slot
                if first and (in_slot or self.is_file(path) or os.path.lexists(path)):
                    in_slot, first = True, False
                what = self.py_handed(path) if in_slot else None
                if what:
                    why = self.unread_typed(
                        f"Python is handed {w}, {what}, so what it runs is not read and whether it posts "
                        "cannot be checked (claude-config#3441). Run the script itself by its path")
                    if why:
                        return words, why
                if not self.is_file(path) and self.is_file(os.path.join(path, "__main__.py")):
                    out.append(os.path.join(w, "__main__.py"))
                    continue
                if FOLDER_PATTERN.search(w) and not re.search(r"[$`<>\s()]", w) and not self.is_file(path) \
                        and not os.path.lexists(path) and self.pattern_bare(w):
                    # A pattern the shell fills in with folders before Python starts (`python3 pk*`):
                    # the __main__.py of each folder it matches, found as the gate finds the files a
                    # pattern matches (pattern_matches in lib/program-runs.py, with its limits).
                    mains = self.pattern_matches(os.path.join(w, "__main__.py"), d)
                    if mains is None:
                        why = self.unread_typed(
                            f"the pattern {w} may hand Python a folder to run, and it matches more than the "
                            "gate reads, so the __main__.py of each folder was not read and whether one posts "
                            "cannot be checked (claude-config#3441). Name the folder")
                        if why:
                            return words, why
                    elif mains:
                        out.extend(mains)
                        continue
                out.append(w)
            return out, None

        def py_cmdline(self, words):
            """What python3 itself runs for a command's words, read as its own option reader reads
            them (PYTHON'S OWN OPTIONS above): (kind, at, cut, end, warns, theirs).

            kind is "script" (the word at index at), "code" or "module" (given by -c or -m: the
            word at index at from its character cut on, which is the option's own word where the
            value is glued to it and the next word, with cut 0, where it is not), "input" (the
            code on its input: the word `-` at index at, or at None where no word is left), or
            None where Python stops with an error for want of a value. end is the index of the
            first word after the one that names what runs, warns the value of each -W, and
            theirs the indexes of the words that are the shell's (a redirection, its target
            glued or the next word), never Python's."""
            mine, theirs, k = [], [], 1
            while k < len(words):
                m = self.sw.REDIRECT_WORD.match(words[k])
                if m:
                    theirs.extend(range(k, min(len(words), k + (1 if m.group(1) else 2))))
                    k += 1 if m.group(1) else 2
                    continue
                mine.append(k)
                k += 1
            warns, p = [], 0
            while p < len(mine):
                at = mine[p]
                w = words[at]
                p += 1
                if w == "--":
                    if p == len(mine):
                        return "input", None, 0, at + 1, warns, theirs
                    at = mine[p]
                    w = words[at]
                    return ("input" if w == "-" else "script"), at, 0, at + 1, warns, theirs
                if w == "-" or not w.startswith("-"):
                    return ("input" if w == "-" else "script"), at, 0, at + 1, warns, theirs
                if w.startswith("--"):
                    p += w == PY_VALUE_LONG
                    continue
                for cut, ch in enumerate(w[1:], 2):
                    if ch not in PY_VALUE_LETTERS:
                        continue
                    if not w[cut:]:
                        if p == len(mine):
                            return None, None, 0, len(words), warns, theirs
                        at, cut = mine[p], 0
                        p += 1
                    if ch == "W":
                        warns.append(words[at][cut:])
                    if ch in "cm":
                        return ("code" if ch == "c" else "module"), at, cut, at + 1, warns, theirs
                    break
            return "input", None, 0, len(words), warns, theirs

        @staticmethod
        def py_respell(words, read):
            """words spelled so the gate's option table reads them as Python does (read, from
            py_cmdline of the same words), or None where Python runs nothing: python3, the
            redirections written before what it runs, then the script (with ./ in front of a
            name starting with a dash), or -c and the code, or -m and the module, or - for the
            code on its input, then every word after as it was. The options left out load
            nothing the gate reads but a -W value's module, which py_own_reading reads."""
            kind, at, cut, end, _, theirs = read
            if kind == "script":
                core = [("./" if words[at].startswith("-") else "") + words[at]]
            elif kind in ("code", "module"):
                core = ["-c" if kind == "code" else "-m", words[at][cut:]]
            elif kind == "input":
                core = [] if at is None else ["-"]
            else:
                return None
            return words[:1] + [words[j] for j in theirs if j < end] + core + words[end:]

        def py_respelled(self, text, want):
            """One command's text spelled so its words read as want (py_respell of its words), or
            None where no spelling the gate can build reads back so. Tried first with the words
            as the command wrote them, quotes and expansions kept, so a path or code the shell
            fills in is still worked out, or refused, as it would be; then with each word of
            want quoted afresh, which is not tried where a word holds something the shell would
            fill in, since quoting it would make it text. What stands before the program
            (assignments, a runner) is kept as written."""
            split = self.py_redirects_split
            rest, assigns = self.rest_of(text)
            if rest and text.endswith(rest):
                head = text[:len(text) - len(rest)]
            else:
                head = "".join(a + " " for a in assigns.split("\n") if a)
            raw = self.raw_words(text)
            tries = [self.py_respell(raw, self.py_cmdline(raw))] if raw else []
            if not any(SHELL_FILLS.search(w) for w in want):
                quoted = []
                for w in want:
                    m = self.sw.REDIRECT_WORD.match(w)
                    if not m:
                        quoted.append(shlex.quote(w))
                    elif m.group(1):
                        quoted.append(w[:m.start(1)] + shlex.quote(m.group(1)))
                    else:
                        quoted.append(w)
                tries.append(quoted)
            for spelled in tries:
                if not spelled:
                    continue
                again = head + " ".join(spelled)
                if split(self.words_of(self.rest_of(again)[0])) == split(want):
                    return again
            return None

        def py_redirects_split(self, words):
            """words with each redirection glued to its target as two words, so the same command
            written both ways compares equal."""
            out = []
            for w in words:
                m = self.sw.REDIRECT_WORD.match(w)
                if m and m.group(1):
                    out.extend([w[:m.start(1)], m.group(1)])
                else:
                    out.append(w)
            return out

        def py_own_reading(self, name, words, text, here, judge):
            """The reason a Python command posts when it is read as python3 itself reads its
            options, or None (PYTHON'S OWN OPTIONS above, claude-config#3539). words are the
            command's words and text the command, name the program, here the folder it runs in,
            and judge the gate's judging of one command's text.

            The module a -W value has Python import is read as an import. And where the gate's
            option table places what runs otherwise than Python does, the command is spelled
            again so the table reads it as Python does, and judged so. The caller goes on to
            judge the command as the table reads it, as before, so this can only refuse more."""
            read = self.py_cmdline(words)
            kind, at, cut, end, warns, theirs = read
            for warn in warns:
                # action:message:category:module:lineno, and a category with a dot in it is a
                # class Python imports the module of (warnings._getcategory).
                fields = warn.split(":")
                mod = fields[2].strip().rpartition(".")[0] if len(fields) > 2 else ""
                if MODULE_NAME.fullmatch(mod):
                    reason = self.imports(f"the -W option given to {name}", None, here, f"import {mod}", "py")
                    if reason:
                        return reason
            if kind is None:
                return None
            value = words[at][cut:] if at is not None else None
            operand, inline, stdin = self.operands(words)
            module = None if inline else self.py_module(words)
            if kind == "script":
                same = not inline and not module and operand == value and not value.startswith("-")
            elif kind == "code":
                after = [words[j] for j in range(end, len(words)) if j not in theirs]
                same = bool(inline) and inline[1] == value and inline[2] == after
            elif kind == "module":
                same = bool(module) and module[0] == value and len(module[1]) == len(words) - end
            else:
                same = not inline and not module and stdin
            want = None if same else self.py_respell(words, read)
            if not want or want == words:
                return None
            again = self.py_respelled(text, want)
            if again is None:
                return self.unread_typed(
                    f"{name} reads the options of this command another way than the gate can spell out, so "
                    "what it runs is not read and whether it posts cannot be checked (claude-config#3539). "
                    "Write the script, -c and its code, or -m and its module as words of their own, right "
                    f"after {name}")
            # The judging sets what the command's sys.argv holds for itself; the caller's is put back.
            keep = dict(self.py_cmd)
            try:
                return judge(again)
            finally:
                self.py_cmd.clear()
                self.py_cmd.update(keep)

        def py_file_runs(self, label, code, here, d, depth, filled=False, fed=None):
            """The reason code given to python3 posts through a file, a module or a command it names
            in its own text, or that it runs a file the gate cannot read, or None (THE RULE above).
            label names the code, here is the folder it runs in and d that folder as the command
            gives it. filled says the shell fills something in inside the code that the gate has
            not worked out, and fed is the file the command feeds the code on its input."""
            cwd_known = self.sh_cwd(d) != unknown_dir
            try:
                nodes = py_nodes(code)
            except (SyntaxError, ValueError):
                nodes = None
            unparsed = None
            if nodes is None:
                # Code this python3 cannot parse counts as able to act (py_acts). Its quoted strings
                # are still read for a file; where the shell fills part of it in and it names a way
                # to run one, what it runs cannot be read at all.
                texts = [m.group(1) if m.group(1) is not None else m.group(2) for m in CRUDE_STRING.finditer(code)]
                folders, rows, mods, unworked = [], [], [], []
                # Where it names a way to run a file, any of its strings may be the file it runs.
                ran = [("the code", text) for text in texts] if SINK_WORDS.search(code) else []
                # Its strings are all that is read of it, so a path it builds is never seen: where
                # it names a way to run a file, the file it runs cannot be read. The gate's python3
                # can be older than the one the command starts, so code it cannot parse may still
                # run. Code naming no such way is left as it was, the shell filling it in or not:
                # test-slack-drafts-python-imports.sh holds that a timing line whose one value the
                # shell fills in passes (claude-config#3278).
                if SINK_WORDS.search(code):
                    unparsed = ("which the shell fills in before Python reads it, and which this python3 cannot "
                                "parse as it is written" if filled else
                                "which this python3 cannot parse, and which names a way to run a file")
            else:
                texts, folders, rows, mods, unworked, ran = self.py_names(nodes, here, filled, cwd_known)
            # Each file a string names, once, as the code would find it: from the folder it runs in,
            # and from each folder it moves to. A folder holding __main__.py is that file, which
            # runpy.run_path and python3 run when handed the folder.
            # In a script on disk only a file the code hands to something that runs a file is read
            # this way (ON DISK above); a typed command's every string is.
            in_script = self.sh_in_script()
            named, seen = [], set()
            for text in ([got for _, got in ran] if in_script else texts) + ([fed] if fed else []):
                if not text or len(text) > MAX_PATH or "\0" in text or "\n" in text:
                    continue
                for k, base in enumerate([d] + folders):
                    path = self.resolve(text, base)
                    if path in seen:
                        continue
                    seen.add(path)
                    if self.is_file(path):
                        named.append((text if k == 0 else path, path))
                    elif self.is_file(os.path.join(path, "__main__.py")):
                        named.append((os.path.join(text if k == 0 else path, "__main__.py"),
                                      os.path.join(path, "__main__.py")))
            # A file the code runs by its path that is not text (an archive holding __main__.py,
            # compiled code) is one the gate cannot read. So is an archive with text in front of it,
            # a path under an archive, and a folder whose __main__ is compiled or a package
            # (py_handed, claude-config#3441): each passed on main at bfc43f1b53, 2026-11-24.
            opaque, handed = [], []
            for name, text in ran:
                if not text or len(text) > MAX_PATH or "\0" in text or "\n" in text:
                    continue
                for base in [d] + folders:
                    path = self.resolve(text, base)
                    try:
                        binary = self.is_file(path) and bool(self.content(path, part="binary"))
                    except OSError:
                        binary = False  # unreadable to us is unreadable to Python
                    if binary:
                        opaque.append(f"{name}({text[:80]!r})")
                        break
                    what = self.py_handed(path)
                    if what:
                        handed.append(f"{name}({text[:80]!r}), {what}")
                        break
            lines, spelled = [], set()
            for text in texts:
                if text not in spelled and len(text) <= MAX_PATH * 4 and "\0" not in text and \
                        re.search(r"\s", text) and self.holds_command(text, d, depth):
                    spelled.add(text)
                    lines.append(text)
            for strings in rows:
                if any("\0" in s for s in strings) or not any(self.starts_command(s) for s in strings):
                    continue
                line = " ".join(shlex.quote(s) for s in strings)
                if line not in spelled:
                    spelled.add(line)
                    lines.append(line)
            if not (named or lines or mods or unworked or unparsed or opaque or handed):
                return None
            runs = self.acts_inline(code, here, "py", runs_only=True)
            if not runs:
                return None  # code that only reads what it names
            noted = len(self.unfollowed)

            def stands(reason):
                """Whether a reason stands: in a script on disk only a finding that something
                posts does, as for the words behind a program the gate does not know."""
                if reason and in_script and any(u in reason for u in self.unfollowed[noted:]):
                    del self.unfollowed[noted:]
                    return False
                return bool(reason)

            for word, _ in named:
                why = self.script(word, d, depth, False, "py", f"the file {word}")
                if stands(why):
                    return (f"{label} {runs}, and names {word} in its own text, which is read as a file that "
                            f"code may run: {why}")
            if len(lines) > MAX_LINES:
                why = self.unread_typed(
                    f"{label} {runs}, and {len(lines)} of the strings it holds could each be a command it runs, "
                    f"more than the {MAX_LINES} the gate reads, so whether the command posts cannot be checked")
                if why:
                    return why
                lines = lines[:MAX_LINES]
            for line in lines:
                why = self.inner_line(line, d, depth)
                if stands(why):
                    return (f"{label} {runs}, and holds the command {line[:120]} in its own text, which is read "
                            f"as one that code may run: {why}")
            if mods and nodes is not None:
                inserts = ([], [])
                self.py_inserts(code, None, inserts)
                added = []
                for _, module in mods:
                    found = self.resolve_py(0, module, ("__main__",), here, here, inserts)
                    main = bool(found) and os.path.basename(found[-1]) == "__main__.py"
                    added.append(f"import {module}.__main__" if main else f"import {module}")
                shown = ", ".join(sorted({name for name, _ in mods}))
                why = self.imports(f"{label}, which runs a module by its name ({shown}) as an import of it does",
                                   None, here, code + "\n" + "\n".join(added) + "\n", "py")
                if stands(why):
                    return why
            if unparsed:
                return self.unread_typed(
                    f"{label} is code {unparsed}, so what it runs is not read and whether it posts cannot be "
                    "checked (claude-config#3397). Write the code out in full, and hand it any value the shell "
                    "holds as an argument, read from sys.argv")
            if opaque:
                return self.unread_typed(
                    f"{label} runs a file that is not text, {opaque[0]}, an archive or compiled code the gate "
                    "cannot read, so whether it posts cannot be checked (claude-config#3397)")
            if handed:
                why = self.unread_typed(
                    f"{label} runs {handed[0]}, so what it runs is not read and whether it posts cannot be "
                    "checked (claude-config#3441)")
                if why:
                    return why
            if unworked:
                return self.unread_typed(
                    f"{label} runs a file by a path the gate cannot work out, {unworked[0]}, so that file is "
                    "not read and whether it posts cannot be checked (claude-config#3397). Write the path out "
                    "in the code, or hand the file to python3 as an argument and read it from sys.argv")
            return None

    return PyFileRuns
