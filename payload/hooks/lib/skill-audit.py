#!/usr/bin/env python3
"""Whole tree checks over the skills folder (claude-config#676, #677).

    skill-audit.py links <skills folder>
    skill-audit.py unrun <skills folder> <repository root>
    skill-audit.py exits <skills folder>

Every skill is found by walking the folder on disk, never from what git tracks: a check reading
the index cannot see the file being written, which is the one it exists to judge (L456). Nothing
is exempted by name.

links  Every relative link in every markdown file of every skill reaches a file that exists.
       Links inside fenced code blocks and inline code are examples, not links, and are skipped,
       as are web addresses, in page anchors, and absolute or home relative paths (which name the
       installed tree, not this one).

unrun  Every file shaped like a test is run by something. A `test-*.sh` is found by
       run-all-tests.sh. A `test_*.py` or `*_test.py` is run by hooks/lib/skill-python-tests.py,
       but only while a suite declares `# runs: hooks/lib/skill-python-tests.py over payload/skills`
       on a line of its own and names the runner outside a comment. Anything else shaped like a test
       (`*.test.js`, `*.spec.ts`, `test_*.sh`, `healthcheck*.sh` and the like) counts as run only
       when a `test-*.sh` suite names it: by its path under the skills folder from anywhere in the
       repository, or by its path inside the skill from a suite that lives in that skill. Suites in
       a checkout nested inside this one (a worktree) are not this repository's and are skipped.

exits  A helper must not report success when it failed. Three shapes are refused:
       P1  a subprocess's exit status is never read: `subprocess.run` without `check=True` whose
           result has no `.returncode` read after it is assigned (followed through functions that
           return the result), `subprocess.call` or `os.system` whose result is dropped, or a
           `Popen` whose status is never asked for.
       P2  an `except` that catches everything (bare, Exception, BaseException) and then does
           nothing (`pass`, `continue`, `...`, a bare return).
       S1  a `gh issue create` in a helper with no `--milestone` or no label: the issue field gate
           only sees commands typed in a session, so a script's own call goes past it.

Prints one line per finding, then a summary line (`LINKS ...`, `UNRUN ...`, `EXITS ...`).
Exit: 0 clean, 1 findings, 2 a folder is missing or holds nothing to check.
"""

import ast
import os
import re
import sys
import urllib.parse

SKIP_DIRS = {"__pycache__", "node_modules", ".git"}


def refuse(msg: str) -> int:
    print(f"skill-audit: {msg}")
    return 2


def skills_in(folder: str):
    if not os.path.isdir(folder):
        return None
    return sorted(
        d for d in os.listdir(folder)
        if os.path.isdir(os.path.join(folder, d)) and d not in SKIP_DIRS and not d.startswith(".")
    )


def walk_files(top: str):
    for root, dirs, files in os.walk(top):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for f in sorted(files):
            yield os.path.join(root, f)


# ------------------------------------------------------------------------------------------------
# links
# ------------------------------------------------------------------------------------------------
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
INLINE_CODE = re.compile(r"(`+)(.+?)\1")
INLINE_LINK = re.compile(
    r"!?\[(?:[^\[\]]|\[[^\]]*\])*\]"            # [text], allowing one level of brackets inside
    r"\(\s*(<[^>]*>|[^)\s]+)"                   # (target or <target>
    r"(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^)]*\)))?"  # optional title
    r"\s*\)"
)
REF_DEF = re.compile(r"^ {0,3}\[[^\]]+\]:\s*(<[^>]*>|\S+)")
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


def link_targets(text: str):
    """Yield (line number, target) for every link outside code."""
    fence = None
    for n, line in enumerate(text.splitlines(), 1):
        m = FENCE.match(line)
        if fence:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence):
                fence = None
            continue
        if m:
            fence = m.group(1)
            continue
        bare = INLINE_CODE.sub(lambda c: " " * len(c.group(0)), line)
        for t in INLINE_LINK.finditer(bare):
            yield n, t.group(1)
        d = REF_DEF.match(bare)
        if d:
            yield n, d.group(1)


def relative_path(target: str):
    """The file a link points at, relative to its page, or None when it is not a relative link."""
    t = target[1:-1] if target.startswith("<") and target.endswith(">") else target
    if not t or t.startswith(("#", "/", "~", "$")) or SCHEME.match(t):
        return None
    t = t.split("#", 1)[0].split("?", 1)[0]
    return urllib.parse.unquote(t) if t else None


def cmd_links(argv) -> int:
    if len(argv) != 1:
        return refuse("usage: skill-audit.py links <skills folder>")
    folder = argv[0]
    skills = skills_in(folder)
    if skills is None:
        return refuse(f"no such folder: {folder}")
    if not skills:
        return refuse(f"{folder} holds no skills, so there was nothing to check. Refusing to pass it.")
    checked = broken = 0
    for skill in skills:
        for path in walk_files(os.path.join(folder, skill)):
            if not path.lower().endswith(".md"):
                continue
            try:
                text = open(path, encoding="utf-8", errors="replace").read()
            except OSError as exc:
                print(f"{os.path.relpath(path, folder)}: could not be read: {exc}")
                broken += 1
                continue
            for n, target in link_targets(text):
                rel = relative_path(target)
                if rel is None:
                    continue
                checked += 1
                dest = os.path.normpath(os.path.join(os.path.dirname(path), rel))
                if not os.path.exists(dest):
                    broken += 1
                    print(f"{os.path.relpath(path, folder)}:{n}: ({target}) does not resolve: "
                          f"no file at {os.path.relpath(dest, folder)}")
    print(f"LINKS skills={len(skills)} checked={checked} broken={broken}")
    return 0 if broken == 0 else 1


# ------------------------------------------------------------------------------------------------
# unrun
# ------------------------------------------------------------------------------------------------
CODE_EXT = r"(?:py|sh|bash|js|mjs|cjs|ts|tsx|jsx|rb|swift)"
PY_TEST = re.compile(r"^(test_.+|.+_test)\.py$")
SHAPED = re.compile(
    r"^(?:test[_-].+\." + CODE_EXT + r"|.+[._-](?:test|spec)\." + CODE_EXT + r"|healthcheck.*\.sh)$"
)
RUNNER_NAME = "skill-python-tests.py"
# The suite that runs the runner over the skills says so on a line of its own. A mention anywhere
# was not enough: a comment or a fixture naming the runner would answer for it, so deleting the real
# suite left every Python test reported as run (the PR #936 lessons review). The declaration must
# stand alone AND the same suite must name the runner on a line that is not a comment.
RUNNER_DECLARATION = re.compile(r"^# runs: hooks/lib/skill-python-tests\.py over payload/skills$", re.M)


def runs_the_runner(text: str) -> bool:
    if not RUNNER_DECLARATION.search(text):
        return False
    return any(RUNNER_NAME in line and not line.lstrip().startswith("#") for line in text.splitlines())


def is_suite(name: str) -> bool:
    return name.startswith("test-") and name.endswith(".sh")


def repo_suites(root: str):
    """Every test-*.sh in this checkout, never one in a checkout nested inside it."""
    root = os.path.abspath(root)
    for here, dirs, files in os.walk(root):
        keep = []
        for d in sorted(dirs):
            if d in SKIP_DIRS:
                continue
            if os.path.exists(os.path.join(here, d, ".git")):
                continue  # another checkout (a worktree or a clone) inside this one
            keep.append(d)
        dirs[:] = keep
        for f in sorted(files):
            if is_suite(f):
                p = os.path.join(here, f)
                try:
                    yield p, open(p, encoding="utf-8", errors="replace").read()
                except OSError:
                    yield p, ""


def cmd_unrun(argv) -> int:
    if len(argv) != 2:
        return refuse("usage: skill-audit.py unrun <skills folder> <repository root>")
    folder, root = argv
    skills = skills_in(folder)
    if skills is None:
        return refuse(f"no such folder: {folder}")
    if not os.path.isdir(root):
        return refuse(f"no such repository root: {root}")
    if not skills:
        return refuse(f"{folder} holds no skills, so there was nothing to check. Refusing to pass it.")
    suites = list(repo_suites(root))
    suite_code = [
        (p, "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#")))
        for p, text in suites
    ]
    runner_invoked = any(runs_the_runner(text) for _, text in suites)
    checked = unrun = 0
    for skill in skills:
        skill_dir = os.path.abspath(os.path.join(folder, skill))
        for path in walk_files(skill_dir):
            name = os.path.basename(path)
            if is_suite(name):
                continue  # found by run-all-tests.sh itself
            py = bool(PY_TEST.match(name))
            if not py and not SHAPED.match(name):
                continue
            checked += 1
            inside = os.path.relpath(path, skill_dir)
            under = f"{skill}/{inside}"
            if py and runner_invoked:
                continue
            # Named on a line of code, never only in a comment: a comment talks about a file and
            # runs nothing (the PR #936 lessons review). A static read cannot prove the named line
            # executes, so a name in an echo still counts; what it can refuse, it does.
            named = any(
                under in code or (os.path.abspath(p).startswith(skill_dir + os.sep) and inside in code)
                for p, code in suite_code
            )
            if named:
                continue
            unrun += 1
            why = ("no suite invokes hooks/lib/" + RUNNER_NAME) if py else "no test-*.sh suite names it"
            print(f"{under}: looks like a test and nothing runs it ({why}). Name it from a suite, "
                  f"or rename it so a runner finds it.")
    print(f"UNRUN skills={len(skills)} checked={checked} unrun={unrun} suites={len(suites)}")
    return 0 if unrun == 0 else 1


# ------------------------------------------------------------------------------------------------
# exits
# ------------------------------------------------------------------------------------------------
RUN_LIKE = {"run"}            # return a CompletedProcess: its .returncode must be read
POPEN = {"Popen"}
BROAD = {"Exception", "BaseException"}


class Module:
    def __init__(self, tree):
        self.tree = tree
        self.parent = {}
        for node in ast.walk(tree):
            for child in ast.iter_child_nodes(node):
                self.parent[child] = node
        # Names bound to subprocess's process functions by import: from subprocess import run as r
        self.aliases = {}
        self.module_names = {"subprocess": "subprocess", "os": "os"}
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.module in ("subprocess", "os"):
                for a in node.names:
                    self.aliases[a.asname or a.name] = (node.module, a.name)
            elif isinstance(node, ast.Import):
                for a in node.names:
                    if a.name in ("subprocess", "os"):
                        self.module_names[a.asname or a.name] = a.name

    def process_kind(self, call):
        """'run', 'int' or 'popen' when this call starts a process, else None."""
        f = call.func
        mod = fn = None
        if isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name):
            mod, fn = self.module_names.get(f.value.id), f.attr
        elif isinstance(f, ast.Name) and f.id in self.aliases:
            mod, fn = self.aliases[f.id]
        if mod == "subprocess" and fn in RUN_LIKE:
            checked = any(k.arg == "check" and isinstance(k.value, ast.Constant) and k.value.value is True
                          for k in call.keywords)
            return None if checked else "run"
        if (mod == "subprocess" and fn == "call") or (mod == "os" and fn == "system"):
            return "int"
        if mod == "subprocess" and fn in POPEN:
            return "popen"
        return None

    def scope_of(self, node):
        p = self.parent.get(node)
        while p is not None and not isinstance(p, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Module)):
            p = self.parent.get(p)
        return p


def wrapper_functions(mod: Module) -> dict:
    """Functions that hand a process result back to their caller, by name -> kind."""
    funcs = [n for n in ast.walk(mod.tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]
    wrappers = {}
    changed = True
    while changed:
        changed = False
        for fn in funcs:
            if fn.name in wrappers:
                continue
            for node in ast.walk(fn):
                if isinstance(node, ast.Return) and isinstance(node.value, ast.Call) and mod.scope_of(node) is fn:
                    kind = call_kind(mod, node.value, wrappers)
                    if kind:
                        wrappers[fn.name] = kind
                        changed = True
                        break
    return wrappers


def call_kind(mod: Module, call, wrappers):
    kind = mod.process_kind(call)
    if kind:
        return kind
    f = call.func
    name = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) and f.value.id == "self" else None)
    return wrappers.get(name) if name else None


def bindings(scope, name):
    """Line numbers where `name` is (re)bound inside scope."""
    lines = []
    for node in ast.walk(scope):
        targets = []
        if isinstance(node, ast.Assign):
            targets = node.targets
        elif isinstance(node, (ast.AnnAssign, ast.AugAssign, ast.For, ast.AsyncFor)):
            targets = [node.target]
        elif isinstance(node, ast.withitem) and node.optional_vars is not None:
            targets = [node.optional_vars]
        for t in targets:
            for sub in ast.walk(t):
                if isinstance(sub, ast.Name) and sub.id == name:
                    lines.append(sub.lineno)
    return sorted(set(lines))


def status_reads(mod, scope, name, kind):
    """Line numbers where scope reads the exit status held in `name`."""
    lines = []
    for node in ast.walk(scope):
        if kind == "int":
            if isinstance(node, ast.Name) and node.id == name and isinstance(node.ctx, ast.Load):
                lines.append(node.lineno)
            continue
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == name:
            if node.attr in ("returncode", "check_returncode"):
                lines.append(node.lineno)
            # wait() and poll() return the status; communicate() returns output, and only sets a
            # returncode somebody still has to read (the PR #936 lessons review).
            elif kind == "popen" and node.attr in ("wait", "poll"):
                call = mod.parent.get(node)
                if isinstance(call, ast.Call) and not isinstance(mod.parent.get(call), ast.Expr):
                    lines.append(node.lineno)
    return sorted(lines)


def exits_python(path: str, rel: str):
    findings = []
    try:
        tree = ast.parse(open(path, encoding="utf-8").read(), filename=path)
    except (OSError, SyntaxError, ValueError) as exc:
        return [f"{rel}: could not be parsed, so it could not be checked: {exc}"]
    mod = Module(tree)
    wrappers = wrapper_functions(mod)
    for call in [n for n in ast.walk(tree) if isinstance(n, ast.Call)]:
        kind = call_kind(mod, call, wrappers)
        if not kind:
            continue
        parent = mod.parent.get(call)
        what = ast.unparse(call.func)
        if isinstance(parent, ast.Return):
            continue  # handed to the caller, which is judged where it calls this function
        if isinstance(parent, ast.Expr):
            findings.append(f"{rel}:{call.lineno}: P1 the exit status of {what}(...) is dropped, so a failure "
                            f"reads as success. Check it, or pass check=True.")
            continue
        bound = None  # the names this call's result is bound to, by `x = ...` or `with ... as x`
        if isinstance(parent, (ast.Assign, ast.AnnAssign)) and getattr(parent, "value", None) is call:
            bound = parent.targets if isinstance(parent, ast.Assign) else [parent.target]
        elif isinstance(parent, ast.withitem) and parent.context_expr is call and parent.optional_vars is not None:
            bound = [parent.optional_vars]
        if bound is not None:
            targets = bound
            if len(targets) == 1 and isinstance(targets[0], ast.Name):
                name = targets[0].id
                scope = mod.scope_of(call)
                later = [ln for ln in bindings(scope, name) if ln > call.lineno]
                until = later[0] if later else float("inf")
                if not any(call.lineno <= ln < until for ln in status_reads(mod, scope, name, kind)):
                    findings.append(f"{rel}:{call.lineno}: P1 {name} = {what}(...) never has its exit status read "
                                    f"before it is replaced or forgotten, so a failure reads as success.")
                continue
        if kind == "int":
            continue  # the status itself, used in an expression
        if isinstance(parent, ast.Attribute) and parent.attr in ("returncode", "check_returncode"):
            continue
        findings.append(f"{rel}:{call.lineno}: P1 the result of {what}(...) is used without its exit status "
                        f"being read, so a failure reads as success.")

    for node in ast.walk(tree):
        if not isinstance(node, ast.ExceptHandler):
            continue
        t = node.type
        names = [] if t is None else ([t] if not isinstance(t, ast.Tuple) else list(t.elts))
        broad = t is None or any(isinstance(n, ast.Name) and n.id in BROAD for n in names)
        if not broad:
            continue
        def inert(s):
            return (isinstance(s, (ast.Pass, ast.Continue))
                    or (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant))
                    or (isinstance(s, ast.Return) and (s.value is None or (isinstance(s.value, ast.Constant) and s.value.value is None))))
        if all(inert(s) for s in node.body):
            caught = "everything" if t is None else ast.unparse(t)
            findings.append(f"{rel}:{node.lineno}: P2 except {caught} that does nothing swallows every failure. "
                            f"Catch the one error you expect, or say what went wrong.")
    return findings


# In command position: the start of a line however indented, after an operator (`;`, `&&`, `||`,
# `|`, `(`, `$(`, `!`), or after a keyword that starts a command. A command position anchored to
# column 0 alone missed every indented call inside a block (the PR #936 lessons review).
GH_CREATE = re.compile(
    r"(?:^|[;&|(!]|\$\(|\b(?:then|do|else|if|elif|while|until|time|exec|command)\b)\s*gh\s+issue\s+create\b"
)


def shell_commands(text: str):
    """(line number, command text) with backslash continuations joined and comments dropped."""
    buf, start = "", None
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        if start is None:
            if line.lstrip().startswith("#"):
                continue
            start = n
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        yield start, buf + line
        buf, start = "", None
    if start is not None:
        yield start, buf


def exits_shell(path: str, rel: str):
    findings = []
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError as exc:
        return [f"{rel}: could not be read, so it could not be checked: {exc}"]
    for n, cmd in shell_commands(text):
        if not GH_CREATE.search(cmd):
            continue
        missing = []
        if "--milestone" not in cmd and not re.search(r"(?:^|\s)-m\s", cmd):
            missing.append("a milestone")
        if not re.search(r"--label\b|(?:^|\s)-l\s|\$\{[A-Za-z_]*label[A-Za-z_]*\[@\]\}", cmd):
            missing.append("a priority and category label")
        if missing:
            findings.append(f"{rel}:{n}: S1 gh issue create without {' or '.join(missing)}. The issue field gate "
                            f"never sees a script's own call, so the script has to carry them.")
    return findings


def cmd_exits(argv) -> int:
    if len(argv) != 1:
        return refuse("usage: skill-audit.py exits <skills folder>")
    folder = argv[0]
    skills = skills_in(folder)
    if skills is None:
        return refuse(f"no such folder: {folder}")
    if not skills:
        return refuse(f"{folder} holds no skills, so there was nothing to check. Refusing to pass it.")
    n_py = n_sh = 0
    findings = []
    for skill in skills:
        for path in walk_files(os.path.join(folder, skill)):
            name = os.path.basename(path)
            if is_suite(name) or PY_TEST.match(name):
                continue  # a test, not a helper
            rel = os.path.relpath(path, folder)
            if name.endswith(".py"):
                n_py += 1
                findings += exits_python(path, rel)
            elif name.endswith(".sh"):
                n_sh += 1
                findings += exits_shell(path, rel)
    for f in findings:
        print(f)
    print(f"EXITS skills={len(skills)} python={n_py} shell={n_sh} findings={len(findings)}")
    return 0 if not findings else 1


def main(argv) -> int:
    commands = {"links": cmd_links, "unrun": cmd_unrun, "exits": cmd_exits}
    if not argv or argv[0] not in commands:
        return refuse("usage: skill-audit.py {links|unrun|exits} ...")
    return commands[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
