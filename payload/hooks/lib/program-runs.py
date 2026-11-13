"""The files a runner or a compiler runs without the command naming them as a script, for the Slack
drafts gate (claude-config#2844).

Before #2844 two routes ran a file the gate never read:

  * A runner from the standard library or installed, handed a script or a module (python3 -m
    cProfile post.py, python3 -m unittest discover, pytest tests): the gate does not read a module
    from the standard library or installed, nor the files after it (py_module_run), so the script it
    runs was not read either. Each runner is now read by its own option table (py_runner): pdb,
    cProfile, profile and trace run one script or module, runpy one module, and unittest and pytest
    the test modules they collect, found as each collects them, with every local module those
    import. A runner the gate does not know stays as it was: whether json.tool or py_compile runs
    what it is handed is not something the gate can tell, and counting them all as running it
    refuses checking any file that names an endpoint.
  * A file a compiler writes and the same command then runs (tsc && node dist/x.js, esbuild
    src/x.ts --outdir=build && node build/x.js): read as it was on disk, or not at all where the build
    had not run yet. Each output is now read as the source it is built from (note_build, built_from),
    at the source's own place, so its imports resolve as the compiler resolves them. bun build is a
    compiler too: its entries were read as a script bun runs, and esbuild's --outfile= marked as a file
    it may write, so building code that names an endpoint was refused though nothing ran it, and a
    quiet --outfile= build was refused when run. Dan chose on 2026-11-12 (#2844) to read both only by
    what they build, where the same command runs it.

slack_drafts_only_gate.py loads this file and gives its Judge the class make() returns as a base, as
it does lib/program-writes.py's, so the methods use the Judge's own readers (resolve, resolve_py,
imports, every_file, script, py_module_run, tick) and state (py_cmd, made_built).
"""
import fnmatch
import json
import os
import re

# Runners from the standard library or installed that run a script or module they are handed: for
# each, the options that take the next word as their value, and those that say the word after the
# options is a module rather than a script. trace's -m is --missing; --module is its module switch.
PY_SCRIPT_RUNNERS = {
    "pdb": ({"-c", "--command"}, {"-m"}),
    "cProfile": ({"-o", "--outfile", "-s", "--sort"}, {"-m"}),
    "profile": ({"-o", "--outfile", "-s", "--sort"}, {"-m"}),
    "trace": ({"-f", "--file", "-C", "--coverdir", "--ignore-module", "--ignore-dir"}, {"--module"}),
}
PY_RUNNERS = frozenset(PY_SCRIPT_RUNNERS) | {"runpy", "unittest", "pytest"}
PYTESTS = frozenset({"pytest", "py.test"})
# pytest's options that take the next word as their value, so the value is never read as a path.
PYTEST_VALUED = frozenset({
    "-k", "-m", "-p", "-c", "-o", "-W", "-n", "-r", "--rootdir", "--ignore", "--ignore-glob", "--deselect",
    "--confcutdir", "--basetemp", "--junitxml", "--junit-xml", "--tb", "--maxfail", "--durations",
    "--durations-min", "--cov", "--cov-report", "--cov-config", "--log-level", "--log-file", "--log-cli-level",
    "--import-mode", "--capture", "--override-ini", "--config-file", "--inifile", "--color", "--code-highlight",
    "--dist", "--numprocesses", "--maxprocesses", "--timeout", "--count", "--reruns", "--randomly-seed"})
# Folders pytest does not collect from unless named (its norecursedirs default).
PYTEST_SKIP = ("*.egg", ".*", "_darcs", "build", "CVS", "dist", "node_modules", "venv", "{arch}")
UNITTEST_VALUED = frozenset({"-k", "--durations"})
UNITTEST_DISCOVER = {"-s": 0, "--start-directory": 0, "-p": 1, "--pattern": 1, "-t": 2, "--top-level-directory": 2}
# How far a collection walk goes: folders entered, and test modules read. Past either it reads what it
# found; a refusal for running out of time costs more than a module left unread here.
WALK_DIRS = 400
WALK_FILES = 300
IDENT = re.compile(r"[A-Za-z_]\w*$")
DOTTED = re.compile(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*$")

# Compilers whose outputs are read as their sources (note_build). LAUNCHERS run the word after them.
BUILDERS = frozenset({"tsc", "esbuild", "bun build"})
# bun build's options that take the next word as their value (esbuild's are all written with =).
BUN_VALUED = frozenset({"--outfile", "--outdir", "--target", "--format", "--root", "--entry-naming",
                        "--chunk-naming", "--asset-naming", "--public-path", "-e", "--external", "--define",
                        "--loader", "--env", "--conditions", "--banner", "--footer", "--packages", "--drop"})
LAUNCHERS = frozenset({"npx", "bunx", "pnpx"})
# The first word npx, bunx, pnpx, npm exec, pnpm dlx or yarn dlx is handed, where it names a package
# (package_run, #2865): `@scope/name` or `name`, with an optional `@version`, holding no path separator
# but the scope's. npm reads such a word as a package, never as a file.
PACKAGE_SPEC = re.compile(r"(@[A-Za-z0-9][\w.~-]*/)?[A-Za-z0-9][\w.~-]*(@[\w.^~<>=*|+-]+)?")
# What a package run by name can do, said as acts() says it: the gate reads no package, so it counts as
# able to send a request or run code, as a package a script imports does (#2844).
PACKAGE_ACTS = ("is a package, which the gate does not read, so it counts as able to send a request or run "
                "code, as a package a script imports does")
# The source extensions each output extension is built from, as tsc and esbuild name outputs.
BUILT_FROM = {".js": (".ts", ".tsx", ".js", ".jsx"), ".mjs": (".mts", ".mjs"), ".cjs": (".cts", ".cjs"),
              ".jsx": (".tsx", ".jsx")}
TS_SOURCES = (".ts", ".tsx", ".mts", ".cts")
# tsc's options that take the next word as their value (the ones that name files or folders, and the
# common ones that take a word), so the value is never read as an input file.
TSC_VALUED = frozenset({
    "-p", "--project", "--outDir", "--rootDir", "--outFile", "--out", "--declarationDir", "--baseUrl",
    "-t", "--target", "-m", "--module", "--lib", "--jsx", "--moduleResolution", "--tsBuildInfoFile",
    "--locale", "--types", "--typeRoots", "--rootDirs", "--sourceRoot", "--mapRoot", "--newLine",
    "--jsxFactory", "--jsxFragmentFactory", "--jsxImportSource", "--moduleDetection", "--generateTrace"})
TSC_WALK = 5000


def jsonc(text):
    """A tsconfig's JSON: comments and trailing commas taken away, outside strings."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
        else:
            out.append(c)
            i += 1
    return json.loads(re.sub(r",(\s*[}\]])", r"\1", "".join(out)))


def ts_glob(pattern):
    """A tsconfig include or exclude pattern as a regular expression over a path relative to its
    config: * and ? within a name, **/ any folders. A pattern with no wildcard in its last name is
    a folder, holding everything under it."""
    parts = pattern.replace("\\", "/").strip("/").split("/")
    if not re.search(r"[*?]", parts[-1]) and "." not in parts[-1]:
        parts += ["**", "*"]
    rx = ""
    for k, part in enumerate(parts):
        if part == "**":
            rx += "(?:[^/]+/)*"
            continue
        if part in (".", ""):
            continue
        rx += re.sub(r"\\\*", "[^/]*", re.sub(r"\\\?", "[^/]", re.escape(part)))
        if k < len(parts) - 1:
            rx += "/"
    return re.compile(rx + "$")


def make(marker, judged_by_name):
    """The base class for the gate's Judge (module docstring). marker is the gate's MARKER, the
    endpoints it refuses, and judged_by_name its judged_by_name(), whether it reads a program by its
    own name (an interpreter, a shell, a sender), which a launcher's word is then left to."""

    class ProgramRuns:
        # ---- Packages a launcher runs -----------------------------------------------------------

        @staticmethod
        def unversioned(word):
            """A launcher's first word with its @version dropped where the rest is a program the gate
            reads by its own name (npx tsx@4, bunx bash@5), so it is read as that program, its
            imports followed; the word as it is otherwise (#2865, lessons review at e11e1f8)."""
            m = PACKAGE_SPEC.fullmatch(word)
            if not m or m.group(1) or not m.group(2):
                return word
            base = word[:-len(m.group(2))]
            return base if judged_by_name(base) else word

        def package_run(self, words, d, depth, launcher):
            """The reason a package a launcher runs posts, None where it does not, or False where
            words[0] is not a package (#2865), which the caller then reads as before.

            words is what the launcher runs, its own options gone, and launcher names it (npx, npm
            exec, pnpm dlx). A package spec (PACKAGE_SPEC) is read as the package npm reads it as, never
            as a file: before #2865 `@scope/name@1` was read as a path, holding a /, so a command
            earlier in the call naming it (claude mcp add -- npx -y @scope/name@1) made it a script that
            may be written, and the call was refused. A spec naming a file on disk, or one an earlier
            command wrote (not a program that only names it), is still read as that file, as is any
            path (./x.js). So is a program the gate reads by its own name (npx tsx), and a compiler
            (npx tsc, read by what it builds).

            A package counts as able to act, as an import of one does (#2844): handed an endpoint, or
            a file naming one, it is refused. Each file it is handed is judged by its own text, as a
            data file is (every_file's actor), and a file another program only may have written by
            what is on disk: reading code files as scripts, imports followed, newly refused `npx
            prettier --write x.test.ts && npx vitest run x.test.ts` in the 14 day replay (2026-11-12),
            where what prettier rewrites cannot be read."""
            spec = words[0]
            if not PACKAGE_SPEC.fullmatch(spec):
                return False
            name = re.sub(r"(?<=.)@.*$", "", spec)
            base = name.rsplit("/", 1)[-1]
            if spec == base and judged_by_name(base):
                return False  # judged by name where the caller reaches it (npx tsx, npm exec -- bash)
            path = self.resolve(spec, d)
            if os.path.lexists(path) or any(kind != "maybe" for kind, _, _ in self.made_from(path) or ()):
                return False
            if name in BUILDERS:
                return None  # a build runs nothing it is handed; what it builds is read where run (#2844)
            label = f"the package {spec}, run by {launcher},"
            hit = marker.search(" ".join(words[1:]))
            if hit:
                return f"{label} {PACKAGE_ACTS}, and is run with {hit.group(0)} in its arguments"
            return self.every_file(words, d, depth, False, actor=(label, PACKAGE_ACTS))


        # ---- Python runners -------------------------------------------------------------------

        def py_runner(self, program, name, mod, after, d, depth, here, module=True):
            """The reason a runner from the standard library or installed posts through what it runs,
            or None where mod is not one (PY_RUNNERS). after is the words after the runner; module
            False says the runner was run by its own name (pytest), not with python -m, so the
            command's directory is not on its import path."""
            if mod not in PY_RUNNERS:
                return None
            label = f"{name} -m {mod}" if module else name
            words = self.runner_words(after)
            if mod == "runpy":
                # runpy's own main runs the module its first argument names, as python3 -m would.
                return self.py_module_run(program, f"{name} -m runpy", (words[0], words[1:]), d, depth, here) \
                    if words else None
            if mod in PY_SCRIPT_RUNNERS:
                target = self.runner_target(mod, words)
                if not target:
                    return None
                is_mod, what, rest = target
                if is_mod:
                    return self.py_module_run(program, label, (what, rest), d, depth, here)
                reason = self.script(what, d, depth, False, "py", f"the script {what}, which {label} runs,")
                return reason or self.every_file([program, what] + rest, d, depth, False, "py")
            if mod == "unittest":
                return self.py_unittest(label, words, d, here)
            return self.py_pytest(label, words, d, here, module)

        def runner_words(self, words):
            """words with the shell's redirections taken out: never the runner's."""
            out, k = [], 0
            while k < len(words):
                m = self.sw.REDIRECT_WORD.match(words[k])
                if m:
                    k += 1 if m.group(1) else 2
                    continue
                out.append(words[k])
                k += 1
            return out

        @staticmethod
        def runner_target(mod, words):
            """(whether it is a module, the script or module, the words after it) that a runner
            running one script or module runs, read by its option table, or None for none. pdb
            attaching to a process (-p) runs nothing it is handed."""
            valued, module_flags = PY_SCRIPT_RUNNERS[mod]
            is_mod, k = False, 0
            while k < len(words):
                w = words[k]
                if w == "--":
                    k += 1
                    break
                if not w.startswith("-") or w == "-":
                    break
                key = w.split("=", 1)[0]
                if mod == "pdb" and key in ("-p", "--pid"):
                    return None
                if key in module_flags:
                    is_mod = True
                    k += 1
                    continue
                glued = not key.startswith("--") and len(key) > 2
                k += 2 if key in valued and "=" not in w and not glued else 1
            if k >= len(words):
                return None
            return is_mod, words[k], words[k + 1:]

        def py_unittest(self, label, words, d, here):
            """python3 -m unittest: the test modules it is named, or those discover finds (no names, or
            discover), each read with every local module it imports, as Python finds them from the
            command's directory and, under discover, the top level folder."""
            if words and words[0] == "discover" or not [w for w in words if not w.startswith("-")]:
                start, pattern, top = self.discover_args(words[1:] if words and words[0] == "discover" else words)
                start_dir = os.path.normpath(self.resolve(start, d))
                if not os.path.isdir(start_dir):
                    return None  # a dotted start names a package: not followed here
                top_dir = os.path.normpath(self.resolve(top, d)) if top else start_dir
                mods = self.unittest_find(start_dir, pattern, top_dir)
                return self.read_modules(label, {top_dir: mods}, [here])
            names, k = [], 0
            while k < len(words):
                w = words[k]
                if w.startswith("-"):
                    k += 2 if w in UNITTEST_VALUED else 1
                    continue
                names.append(w)
                k += 1
            mods = []
            for n in names:
                if n.endswith(".py"):
                    rel = os.path.relpath(os.path.normpath(self.resolve(n, d)), here)
                    if rel.startswith(".."):
                        continue
                    n = rel[:-3].replace(os.sep, ".")
                if not DOTTED.match(n):
                    continue
                parts = n.split(".")
                for k in range(len(parts), 0, -1):
                    found = self.resolve_py(0, ".".join(parts[:k]), (), here, here)
                    if found:
                        mods.append(".".join(parts[:k]))
                        break
            return self.read_modules(label, {here: mods}, [])

        @staticmethod
        def discover_args(words):
            """unittest discover's (start, pattern, top): by option or in that order by position."""
            vals, k, pos = [".", "test*.py", None], 0, 0
            while k < len(words):
                w = words[k]
                key, eq = (w.split("=", 1) + [None])[:2] if w.startswith("--") else (w, None)
                if key in UNITTEST_DISCOVER:
                    if eq is not None:
                        vals[UNITTEST_DISCOVER[key]] = eq
                        k += 1
                    else:
                        if k + 1 < len(words):
                            vals[UNITTEST_DISCOVER[key]] = words[k + 1]
                        k += 2
                    continue
                if w.startswith("-"):
                    k += 2 if key in UNITTEST_VALUED else 1
                    continue
                if pos < 3:
                    vals[pos] = w
                pos += 1
                k += 1
            return vals[0], vals[1], vals[2]

        def unittest_find(self, start, pattern, top):
            """The module names unittest discover imports under start: each file matching pattern, in
            start and in every folder below it that is a package (holds __init__.py), named from top."""
            mods, stack, dirs = [], [start], 0
            while stack and dirs < WALK_DIRS and len(mods) < WALK_FILES:
                cur = stack.pop()
                dirs += 1
                try:
                    entries = sorted(os.listdir(cur))
                except OSError:
                    continue
                for e in entries:
                    p = os.path.join(cur, e)
                    if os.path.isdir(p):
                        if IDENT.match(e) and os.path.isfile(os.path.join(p, "__init__.py")):
                            stack.append(p)
                    elif e.endswith(".py") and IDENT.match(e[:-3]) and fnmatch.fnmatch(e, pattern):
                        rel = os.path.relpath(p, top)
                        if not rel.startswith(".."):
                            mods.append(rel[:-3].replace(os.sep, "."))
            return mods

        def py_pytest(self, label, words, d, here, module):
            """pytest: the test files it collects from the paths it is handed (its testpaths, or the
            folder it runs in, where none), and every conftest.py from each up to its rootdir, each
            imported as pytest's default import mode does: from the first folder above it that is not
            a package, which goes on the import path, with the command's directory under python -m."""
            paths, k, pyargs = [], 0, False
            while k < len(words):
                w = words[k]
                if w == "--":
                    paths += words[k + 1:]
                    break
                if w.startswith("-") and w != "-":
                    key = w.split("=", 1)[0]
                    pyargs = pyargs or key == "--pyargs"
                    glued = not key.startswith("--") and len(key) > 2
                    k += 2 if key in PYTEST_VALUED and "=" not in w and not glued else 1
                    continue
                paths.append(w)
                k += 1
            if pyargs:
                return None  # module names, found as installed packages: not followed here
            rootdir, testpaths, pythonpath = self.pytest_root(here)
            if not paths:
                paths = [os.path.join(rootdir, t) for t in testpaths] if testpaths else ["."]
            files, confs = [], []
            for p in paths:
                real = os.path.normpath(self.resolve(p.split("::", 1)[0], d))
                if os.path.isfile(real) and real.endswith(".py"):
                    files.append(real)
                    base = os.path.dirname(real)
                elif os.path.isdir(real):
                    self.pytest_walk(real, files, confs)
                    base = real
                else:
                    continue
                up = base
                while True:
                    conf = os.path.join(up, "conftest.py")
                    if os.path.isfile(conf) and conf not in confs:
                        confs.append(conf)
                    parent = os.path.dirname(up)
                    if up == rootdir or parent == up or not (up + os.sep).startswith(rootdir + os.sep):
                        break
                    up = parent
            groups = {}
            for f in confs + files:
                base, name = os.path.dirname(f), os.path.basename(f)[:-3]
                while os.path.isfile(os.path.join(base, "__init__.py")) and os.path.dirname(base) != base:
                    name = os.path.basename(base) + "." + name
                    base = os.path.dirname(base)
                if all(IDENT.match(n) for n in name.split(".")):
                    groups.setdefault(base, []).append(name)
            return self.read_modules(label, groups, pythonpath + list(groups) + ([here] if module else []))

        @staticmethod
        def pytest_root(here):
            """(pytest's rootdir, its testpaths, its pythonpath) for a run from here: the nearest folder
            at or above here holding pytest.ini, a pyproject.toml with a [tool.pytest.ini_options] table,
            a tox.ini with [pytest] or a setup.cfg with [tool:pytest]; here itself where none does. The
            pythonpath folders, relative to the rootdir, go on the import path before any test runs
            (pytest 7), so a test importing the project's own package is found as pytest finds it."""
            import configparser  # here, not at the top: only a pytest run needs it

            def listed(v):
                v = v if v is not None else []
                return v.split() if isinstance(v, str) else [t for t in v if isinstance(t, str)]
            up = here
            while True:
                for name, section in (("pytest.ini", "pytest"), ("pyproject.toml", None), ("tox.ini", "pytest"),
                                      ("setup.cfg", "tool:pytest")):
                    path = os.path.join(up, name)
                    if not os.path.isfile(path):
                        continue
                    try:
                        if section is None:
                            import tomllib
                            with open(path, "rb") as f:
                                table = tomllib.load(f).get("tool", {}).get("pytest", {}).get("ini_options")
                            if not isinstance(table, dict):
                                continue
                            found = (table.get("testpaths"), table.get("pythonpath"))
                        else:
                            cp = configparser.ConfigParser(interpolation=None)
                            cp.read(path)
                            if not cp.has_section(section):
                                if name == "pytest.ini":
                                    return up, [], []
                                continue
                            found = (cp.get(section, "testpaths", fallback=""), cp.get(section, "pythonpath", fallback=""))
                    except (OSError, ValueError, ImportError, configparser.Error):
                        return up, [], []
                    return up, listed(found[0]), [os.path.normpath(os.path.join(up, p)) for p in listed(found[1])]
                parent = os.path.dirname(up)
                if parent == up:
                    return here, [], []
                up = parent

        def pytest_walk(self, top, files, confs):
            """The test files (test_*.py, *_test.py) and conftest.py files pytest collects under top,
            past the folders it does not enter (PYTEST_SKIP, and a virtual environment)."""
            stack, dirs = [top], 0
            while stack and dirs < WALK_DIRS and len(files) < WALK_FILES:
                cur = stack.pop()
                dirs += 1
                try:
                    entries = sorted(os.listdir(cur))
                except OSError:
                    continue
                for e in entries:
                    p = os.path.join(cur, e)
                    if os.path.isdir(p):
                        if not any(fnmatch.fnmatch(e, pat) for pat in PYTEST_SKIP) \
                                and not os.path.isfile(os.path.join(p, "pyvenv.cfg")):
                            stack.append(p)
                    elif e == "conftest.py":
                        confs.append(p)
                    elif e.endswith(".py") and (e.startswith("test_") or e.endswith("_test.py")):
                        files.append(p)

        def read_modules(self, label, groups, path):
            """The reason any module in groups ({the folder it is imported from: [module names]}) posts,
            with every local module it imports, or None. path is put on the command's import path
            while they are read, as the runner puts it on Python's."""
            saved = self.py_cmd
            self.py_cmd = dict(saved, path=list(path) + [p for p in saved["path"] if p not in path])
            try:
                for root, mods in groups.items():
                    if not mods:
                        continue
                    self.tick(root)
                    code = "\n".join(f"import {m}" for m in dict.fromkeys(mods))
                    reason = self.imports(f"the tests {label} runs", None, root, code, "py")
                    if reason:
                        return reason
            finally:
                self.py_cmd = saved
            return None

        # ---- Compilers ------------------------------------------------------------------------

        def note_build(self, name, vals, d):
            """A compiler run (BUILDERS, or one a launcher runs): its outputs are read as the sources
            they are built from, when a later command of this call runs one (built_from). vals are its
            words as worked out, None for one that cannot be.

            True for an esbuild or bun build whose every word is worked out: what it writes is then
            known (its outputs, or nothing but what it prints), so note_program does not also mark the
            files it names as ones it may write (Dan, 2026-11-12, #2844). tsc keeps that mark on the
            files it is handed, as before; script() skips it only where it reads one as a source."""
            words, writer = list(vals), name  # the program the command runs, a launcher included
            if name in LAUNCHERS:
                k = 1
                while k < len(words) and words[k] is not None and words[k].startswith("-"):
                    k += 1
                words = words[k:]
                if not words or words[0] is None:
                    return False
                name = os.path.basename(words[0])
            if name == "bun" and len(words) > 1 and words[1] == "build":
                name, words = "bun build", words[1:]
            if name not in BUILDERS or any(w is None for w in words):
                return False  # a word that cannot be worked out: what it builds is not known
            if name == "tsc":
                entry = self.tsc_entry(words[1:], d)
            else:
                entry = self.esbuild_entry(words[1:], d, BUN_VALUED if name == "bun build" else frozenset())
            if entry:
                entry["label"], entry["writer"] = name, writer
                self.made_built.append(entry)
            return name != "tsc"

        def tsc_entry(self, words, d):
            """What tsc builds: the files it is handed, or the project its config names."""
            opts, files, build, k = {}, [], False, 0
            while k < len(words):
                w = words[k]
                if w.startswith("-"):
                    key, eq = (w.split("=", 1) + [None])[:2]
                    if key in ("-b", "--build"):
                        build = True
                    elif key in TSC_VALUED:
                        val = eq if eq is not None else (words[k + 1] if k + 1 < len(words) else None)
                        opts[key] = val
                        k += 1 if eq is not None else 2
                        continue
                    else:
                        opts[key] = True
                    k += 1
                    continue
                files.append(w)
                k += 1
            if opts.get("--outFile") or opts.get("--out"):
                return None  # one bundled file: not followed, so the files it names stay as before
            if any(opts.get(o) for o in ("--noEmit", "--emitDeclarationOnly", "--watch", "-w", "--help", "-h",
                                         "--version", "-v", "--init", "--showConfig", "--listFilesOnly")):
                return None
            cli = {"outDir": opts.get("--outDir"), "rootDir": opts.get("--rootDir")}
            cli = {k2: self.resolve(v, d) for k2, v in cli.items() if isinstance(v, str)}
            if files and not build and not opts.get("-p") and not opts.get("--project"):
                inputs = [self.resolve(f, d) for f in files if os.path.splitext(f)[1] in BUILT_FROM or f.endswith(TS_SOURCES)]
                return {"configs": [dict(cli, files=inputs)], "roots": None}
            projects = files if build else [opts.get("-p") or opts.get("--project") or "."]
            configs = []
            for p in projects:
                if not isinstance(p, str):
                    continue
                self.tsc_configs(self.tsc_config_path(os.path.normpath(self.resolve(p, d)), search=p == "." and not build),
                                 cli, configs, build, 0)
            return {"configs": configs, "roots": None} if configs else None

        @staticmethod
        def tsc_config_path(path, search):
            """The tsconfig a project word names: a file, a folder's tsconfig.json, or, for tsc run with
            no project, the nearest tsconfig.json at or above the folder it runs in."""
            if os.path.isfile(path):
                return path
            cur = path
            while True:
                cand = os.path.join(cur, "tsconfig.json")
                if os.path.isfile(cand):
                    return cand
                parent = os.path.dirname(cur)
                if not search or parent == cur:
                    return None
                cur = parent

        def tsc_configs(self, path, cli, out, build, depth):
            """Add to out the build each config at path describes (and, under -b, each it references):
            {configDir, outDir, rootDir, include, exclude, files, noEmit}, each option from the config
            that sets it, through its extends chain, relative to that config's folder."""
            if not path or depth > 8 or any(c.get("config") == path for c in out):
                return
            opts, top, chain, cur = {}, None, 0, path
            while cur and chain < 6:
                try:
                    with open(cur, encoding="utf-8", errors="replace") as f:
                        data = jsonc(f.read())
                except (OSError, ValueError):
                    break
                if not isinstance(data, dict):
                    break
                if top is None:
                    top = data
                base = os.path.dirname(cur)
                co = data.get("compilerOptions") if isinstance(data.get("compilerOptions"), dict) else {}
                for key in ("outDir", "rootDir"):
                    if key not in opts and isinstance(co.get(key), str):
                        opts[key] = os.path.normpath(os.path.join(base, co[key]))
                for key in ("noEmit", "emitDeclarationOnly"):
                    if key not in opts and key in co:
                        opts[key] = co[key]
                for key in ("include", "exclude", "files"):
                    if key not in opts and isinstance(data.get(key), list):
                        opts[key] = (base, [x for x in data[key] if isinstance(x, str)])
                ext = data.get("extends")
                ext = ext[0] if isinstance(ext, list) and ext else ext
                cur = os.path.normpath(os.path.join(base, ext)) if isinstance(ext, str) and ext.startswith(".") else None
                if cur and not cur.endswith(".json") and not os.path.isfile(cur):
                    cur += ".json"
                chain += 1
            if top is None:
                return
            opts.update(cli)
            if not (opts.get("noEmit") is True or opts.get("emitDeclarationOnly") is True):
                out.append(dict(opts, config=path, configDir=os.path.dirname(path)))
            if build:
                for ref in top.get("references") or []:
                    rp = ref.get("path") if isinstance(ref, dict) else None
                    if isinstance(rp, str):
                        self.tsc_configs(self.tsc_config_path(os.path.normpath(os.path.join(os.path.dirname(path), rp)),
                                                              False), {}, out, build, depth + 1)

        def tsc_roots(self, c):
            """The folder tsc builds a config's outputs relative to: its rootDir, or the common folder of
            the sources it compiles (the files it is handed, or those its config includes)."""
            if c.get("rootDir"):
                return c["rootDir"]
            if "files" in c and isinstance(c["files"], list):
                srcs = [f for f in c["files"] if not f.endswith(".d.ts")]
            else:
                srcs = self.tsc_sources(c)
            dirs = [os.path.dirname(s) for s in srcs]
            return os.path.commonpath(dirs) if dirs else c.get("configDir")

        def tsc_sources(self, c):
            """The source files a config's include, exclude and files take in, as tsc matches them,
            walking its folder past node_modules, the output folder and hidden folders."""
            top = c["configDir"]
            inc_base, inc = c.get("include") or (top, ["**/*"])
            exc_base, exc = c.get("exclude") or (top, ["node_modules", "bower_components", "jspm_packages"])
            listed = [os.path.normpath(os.path.join(c["files"][0], f)) for f in c["files"][1]] if isinstance(c.get("files"), tuple) else []
            if isinstance(c.get("files"), tuple) and not c.get("include"):
                inc = []
            incs = [(inc_base, ts_glob(p)) for p in inc]
            excs = [(exc_base, ts_glob(p)) for p in exc]
            out, seen = list(listed), 0
            outdir = c.get("outDir")
            for cur, dirs, names in os.walk(top):
                seen += len(names) + len(dirs)
                if seen > TSC_WALK:
                    break
                dirs[:] = [x for x in dirs if not x.startswith(".") and x != "node_modules"
                           and os.path.join(cur, x) != outdir]
                for n in names:
                    if not n.endswith(TS_SOURCES) or n.endswith(".d.ts"):
                        continue
                    p = os.path.join(cur, n)

                    def hits(pats, p=p):
                        return any(rx.match(os.path.relpath(p, b).replace(os.sep, "/")) for b, rx in pats)
                    if hits(incs) and not hits(excs):
                        out.append(p)
            return out

        def esbuild_entry(self, words, d, valued=frozenset()):
            """What esbuild or bun build builds: each entry point, to the file --outfile names or,
            under --outdir, to the name it is given there (bun's --root is esbuild's --outbase).
            valued holds the options whose value is the next word (bun's; esbuild's take =)."""
            entries, opts, k = [], {}, 0
            while k < len(words):
                w = words[k]
                if w.startswith("-"):
                    key, eq = (w.split("=", 1) + [None])[:2]
                    if eq is None and key in valued and k + 1 < len(words):
                        eq, k = words[k + 1], k + 1
                    opts["--outbase" if key == "--root" else key] = eq if eq is not None else True
                    k += 1
                    continue
                out, src = w.split("=", 1) if "=" in w and not valued else (None, w)
                entries.append((out, self.resolve(src, d)))
                k += 1
            if not entries or not (isinstance(opts.get("--outfile"), str) or isinstance(opts.get("--outdir"), str)):
                return None
            outdir = self.resolve(opts["--outdir"], d) if isinstance(opts.get("--outdir"), str) else None
            outbase = self.resolve(opts["--outbase"], d) if isinstance(opts.get("--outbase"), str) else None
            if outdir and not outbase:
                stems = [os.path.dirname(s) for o, s in entries if o is None]
                outbase = os.path.commonpath(stems) if len(stems) > 1 else (stems[0] if stems else outdir)
            return {"entries": entries, "outfile": self.resolve(opts["--outfile"], d) if isinstance(opts.get("--outfile"), str) else None,
                    "outdir": outdir, "outbase": outbase, "names": "--entry-names" in opts or "--entry-naming" in opts}

        def built_from(self, path):
            """[(the source, the compiler as a refusal names it, the program the command ran)] that a
            compiler run earlier in this call builds path from (note_build), each a file on disk other
            than path itself; empty where none does. The program (a launcher, npx, or the compiler) is
            the one whose naming of the source script() skips as a write."""
            real = os.path.realpath(path)
            stem, ext = os.path.splitext(real)
            out = []
            for e in self.made_built:
                if ext not in BUILT_FROM and ("configs" in e or not e["outfile"]):
                    continue  # only a named output file may be anything (bun build --compile's program)
                if "configs" in e:
                    out += [(src, e["label"], e["writer"]) for src in self.tsc_built(e, real, stem, ext)]
                    continue
                for o, src in e["entries"]:
                    if e["outfile"] and os.path.realpath(e["outfile"]) == real:
                        out.append((src, e["label"], e["writer"]))
                    elif e["outdir"]:
                        od = os.path.realpath(e["outdir"])
                        if not real.startswith(od + os.sep):
                            continue
                        want = os.path.join(od, o) if o else \
                            os.path.join(od, os.path.relpath(os.path.splitext(src)[0], e["outbase"]))
                        if e["names"] or os.path.normpath(want) == stem:
                            out.append((src, e["label"], e["writer"]))
            seen, found = set(), []
            for src, how, writer in out:
                if src not in seen and os.path.realpath(src) != real and os.path.isfile(src):  # never the output itself
                    seen.add(src)
                    found.append((src, how, writer))
            return found

        def tsc_built(self, e, real, stem, ext):
            """built_from for one tsc run: each source a config builds to real."""
            out = []
            for c in e["configs"]:
                outdir = os.path.realpath(c["outDir"]) if c.get("outDir") else None
                if outdir:
                    if not real.startswith(outdir + os.sep):
                        continue
                    if "root" not in c:
                        c["root"] = self.tsc_roots(c)
                    if not c["root"]:
                        continue
                    rel = stem[len(outdir) + 1:]
                    out += [os.path.join(c["root"], rel + x) for x in BUILT_FROM[ext]]
                else:
                    # No output folder: each output sits beside its source, which the build takes in.
                    within = c.get("configDir") or (os.path.commonpath([os.path.dirname(f) for f in c["files"]])
                                                    if c.get("files") else None)
                    if within and real.startswith(os.path.realpath(within) + os.sep):
                        out += [stem + x for x in BUILT_FROM[ext] if x != ext]
            return out

    return ProgramRuns

