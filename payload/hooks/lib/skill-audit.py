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

exits  A helper must not report success when it failed. Three shapes are refused (P1, P2, S1),
       and a fourth kind of line, U1, reports what could not be judged:
       P1  a subprocess's exit status is never read: `subprocess.run` without `check=True` whose
           result has no `.returncode` read after it is assigned (followed through functions that
           return the result), `subprocess.call` or `os.system` whose result is dropped, or a
           `Popen` whose status is never asked for. A `Popen` whose status is read only as it
           starts is refused too (#3650): one held on an attribute of self must have how it ended
           read in another method of its class (and in the method that ends it, when one does), or
           waited for where it starts; a local one read only by `poll()` must not be used again
           after that read, nor waited on after it (a `wait()` whose result is dropped, or
           `communicate()`) unless a `returncode` read or a `wait()` whose result is used follows.
       U1  not a finding: a process handed to something the check cannot follow, so whether its
           ending is read was not judged. Printed and counted, and it does not fail the check.
       P2  an `except` that catches everything (bare, Exception, BaseException) and then does
           nothing (`pass`, `continue`, `...`, a bare return).
       S1  a `gh issue create` in a helper with no `--milestone` or no label: the issue field gate
           only sees commands typed in a session, so a script's own call goes past it.

Prints one line per finding (and per U1), then a summary line (`LINKS ...`, `UNRUN ...`,
`EXITS ... findings=N unjudged=M`).
Exit: 0 clean, 1 findings, 2 a folder is missing or holds nothing to check.
"""

import ast
import importlib.util
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
        # The file's own top level functions, by name: a process handed to one of them is followed.
        self.functions = {n.name: n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}

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


# A long lived process's ENDING (claude-config#3650). Judging one function at a time cannot tell a
# poll() made just after a process starts from a read of how it ended. So a Popen whose handle
# outlives the function that started it, held on an attribute of self, is followed through every
# method of its class: directly, through a local taken from the attribute (`proc = self.x`, or
# `proc, self.x = self.x, None`), and into a method or a top level function of the same file it is
# handed to. In the method that starts it only a read that waits for the end counts. A local process
# whose status is read only while it runs, and which is used again after that read, or waited on
# after it by a wait() whose result is dropped or by communicate() with no returncode read after
# that, has had only its start checked. A hand off the check cannot follow is said (U1), never
# passed in silence.
ASKS = ("wait", "poll", "communicate")
IDENTITY = ("pid", "args")  # reading these asks nothing of the process, running or ended


def name_is(name):
    return lambda n: isinstance(n, ast.Name) and n.id == name


def attribute_is(owner, attr):
    return lambda n: (isinstance(n, ast.Attribute) and n.attr == attr
                      and isinstance(n.value, ast.Name) and n.value.id == owner)


def self_name(fn):
    """The first parameter of a method, by which it names its own object."""
    params = fn.args.posonlyargs + fn.args.args
    return params[0].arg if params else None


def methods_of(cls):
    return {n.name: n for n in cls.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}


def loops_around(mod, node, scope):
    out = set()
    p = mod.parent.get(node)
    while p is not None and p is not scope:
        if isinstance(p, (ast.While, ast.For, ast.AsyncFor)):
            out.add(p)
        p = mod.parent.get(p)
    return out


def ends_it(mod, attribute):
    """Whether this attribute of a process handle is the code ending the process: closing its input
    (`proc.stdin.close()`), `terminate()`, `kill()` or `send_signal()`, or its pid handed to
    os.kill or os.killpg."""
    a, up = attribute.attr, mod.parent.get(attribute)
    if a in ("terminate", "kill", "send_signal"):
        return isinstance(up, ast.Call) and up.func is attribute
    if a == "stdin":
        return (isinstance(up, ast.Attribute) and up.attr == "close"
                and isinstance(mod.parent.get(up), ast.Call) and mod.parent.get(up).func is up)
    if a == "pid" and isinstance(up, ast.Call) and attribute in up.args:
        f = up.func
        return (isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name)
                and mod.module_names.get(f.value.id) == "os" and f.attr in ("kill", "killpg")) \
            or (isinstance(f, ast.Name) and mod.aliases.get(f.id) in (("os", "kill"), ("os", "killpg")))
    return False


def handle_uses(mod, scope, is_handle, start=0, until=float("inf")):
    """Everything scope does with a process handle, as (line, what, node, detail), in line order.

    what is one of: wait or poll (a call whose result is used), asked (wait, poll or communicate
    called with its result dropped, or communicate; detail names which), returncode, ends (the code
    ending the process, see ends_it), use (any other attribute), handed (the handle passed on; detail is the Call, or None when it goes somewhere no
    call names: returned, yielded, stored in a container), alias (bound to a local; detail is its
    name) and store (assigned to an attribute or item; detail is the target)."""
    uses = []
    for node in ast.walk(scope):
        if not is_handle(node) or not (start <= node.lineno < until):
            continue
        if isinstance(getattr(node, "ctx", None), (ast.Store, ast.Del)):
            continue
        line, parent = node.lineno, mod.parent.get(node)
        if isinstance(parent, ast.Attribute) and parent.value is node:
            a = parent.attr
            if a in ("returncode", "check_returncode"):
                uses.append((line, "returncode", parent, None))
            elif a in ASKS:
                call = mod.parent.get(parent)
                called = isinstance(call, ast.Call) and call.func is parent
                if called and a in ("wait", "poll") and not isinstance(mod.parent.get(call), ast.Expr):
                    uses.append((line, a, call, None))
                else:
                    uses.append((line, "asked", parent, a))
            elif ends_it(mod, parent):
                uses.append((line, "ends", parent, None))
            elif a not in IDENTITY:
                uses.append((line, "use", parent, None))
            continue
        holder = mod.parent.get(parent) if isinstance(parent, ast.keyword) else parent
        if isinstance(holder, ast.Call) and holder.func is not node:
            uses.append((line, "handed", node, holder))
            continue
        target = None
        if isinstance(parent, (ast.Assign, ast.AnnAssign)) and parent.value is node:
            targets = parent.targets if isinstance(parent, ast.Assign) else [parent.target]
            target = targets[0] if len(targets) == 1 else None
        elif isinstance(parent, ast.Tuple) and isinstance(mod.parent.get(parent), ast.Assign):
            assign = mod.parent.get(parent)
            lhs = assign.targets[0] if len(assign.targets) == 1 else None
            if assign.value is parent and isinstance(lhs, ast.Tuple) and len(lhs.elts) == len(parent.elts):
                target = next(t for t, v in zip(lhs.elts, parent.elts) if v is node)
        if target is not None:
            if isinstance(target, ast.Name):
                uses.append((line, "alias", node, target.id))
            elif isinstance(target, (ast.Attribute, ast.Subscript)):
                uses.append((line, "store", node, target))
            else:
                uses.append((line, "handed", node, None))
            continue
        if isinstance(parent, (ast.Compare, ast.BoolOp, ast.UnaryOp, ast.If, ast.While, ast.IfExp, ast.Assert)):
            continue  # tested, as in `proc is not None`, which asks nothing of the process
        uses.append((line, "handed", node, None))
    return sorted(uses, key=lambda u: (u[0], getattr(u[2], "col_offset", 0)))


def handed_to(mod, call, node, scope, cls):
    """The function of this file, and its parameter, that a call hands the handle to, or None."""
    f, fn, skip = call.func, None, 0
    if isinstance(f, ast.Name):
        fn = mod.functions.get(f.id)
    elif (cls is not None and isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name)
          and f.value.id == self_name(scope)):
        fn = methods_of(cls).get(f.attr)
        skip = 1
    if fn is None:
        return None
    params = [a.arg for a in fn.args.posonlyargs + fn.args.args][skip:]
    for i, a in enumerate(call.args):
        if a is node:
            return (fn, params[i]) if i < len(params) else None
    for k in call.keywords:
        if k.value is node and k.arg:
            return fn, k.arg
    return None


def with_aliases(mod, scope, uses):
    """uses, plus what scope does through every local it binds the handle to."""
    out = list(uses)
    for u in uses:
        if u[1] == "alias":
            later = [ln for ln in bindings(scope, u[3]) if ln > u[0]]
            out += handle_uses(mod, scope, name_is(u[3]), u[0], later[0] if later else float("inf"))
    return sorted(out, key=lambda u: u[0])


def classify(mod, scope, uses, cls, seen=frozenset()):
    """Sort a function's uses of a handle into reads of how it ended.

    Returns (ending, reads, unfollowed): ending holds the lines that read the status once the process
    is done (a wait() whose result is used, a returncode after a wait() or communicate(), a poll() a
    loop repeats, or a hand off to a function of this file that does one of these); reads holds every
    line that reads the status at all (any of those, a poll() whose result is used, a returncode after
    anything asked for it, or a hand off to a function of this file that reads it at all); unfollowed
    holds the hand offs that could not be followed, as (line, words), including those made by a
    function of this file the handle was handed to that reads nothing itself. seen holds the
    (function, parameter) pairs already being followed, so a handle passed in a cycle ends."""
    ending, reads, unfollowed, asked, waited = [], [], [], False, False
    for line, what, node, detail in uses:
        if what == "wait":
            ending.append(line)
            reads.append(line)
            asked = waited = True
        elif what == "poll":
            reads.append(line)
            asked = True
            if loops_around(mod, node, scope):
                ending.append(line)
        elif what == "asked":
            asked = True
            waited = waited or detail in ("wait", "communicate")
        elif what == "returncode":
            if asked:
                reads.append(line)
            if waited:
                ending.append(line)
        elif what == "handed":
            target = handed_to(mod, detail, node, scope, cls) if detail is not None else None
            if target is not None and target not in seen:
                # The function handed it is judged by these same rules: only its reading of the end
                # counts as the ending, and a poll() it makes once is a read at its start (PR #3659).
                fn, param = target
                end, got, lost = classify(mod, fn, with_aliases(mod, fn, handle_uses(mod, fn, name_is(param))),
                                          class_of(mod, fn), seen | {target})
                if end:
                    ending.append(line)
                if end or got:
                    reads.append(line)
                else:
                    unfollowed += lost
            elif target is None:
                words = (f"{ast.unparse(detail.func)}(...)" if detail is not None
                         else "something outside this function")
                unfollowed.append((line, words))
    return ending, reads, unfollowed


def ending_in_class(mod, cls, attr, start_fn):
    """Whether the methods of cls other than start_fn read how the process held on attr ended.

    A method that ENDS the process (see ends_it) must read how it ended itself, or call a method of
    cls that does: a read on some other path, such as an error branch, says nothing about the end the
    code brings about. A process no method ends, which ends by itself, needs a read in any method.
    Returns (read, enders that read nothing as (line, method name), unfollowed hand offs)."""
    unfollowed, readers, enders = [], set(), {}
    per = {}
    for fn in methods_of(cls).values():
        owner = self_name(fn)
        if fn is start_fn or owner is None:
            continue
        uses = with_aliases(mod, fn, handle_uses(mod, fn, attribute_is(owner, attr)))
        _, reads, lost = classify(mod, fn, uses, cls)
        per[fn.name] = (fn, owner)
        if reads:
            readers.add(fn.name)
        unfollowed += lost
        ends = [u[0] for u in uses if u[1] == "ends"]
        if ends:
            enders[fn.name] = ends[0]
    if not enders:
        return bool(readers), [], unfollowed

    def reads_through_a_call(name):
        fn, owner = per[name]
        for node in ast.walk(fn):
            if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                    and isinstance(node.func.value, ast.Name) and node.func.value.id == owner
                    and node.func.attr in readers):
                return True
        return False

    silent = [(line, name) for name, line in sorted(enders.items(), key=lambda e: e[1])
              if name not in readers and not reads_through_a_call(name)]
    return not silent, silent, unfollowed


def class_of(mod, scope):
    """The class scope is a method of, or None."""
    if not isinstance(scope, (ast.FunctionDef, ast.AsyncFunctionDef)):
        return None
    cls = mod.parent.get(scope)
    return cls if isinstance(cls, ast.ClassDef) else None


def judge_ending(mod, call, what, scope, name, holder, uses, rel):
    """Whether the ending of the process call started is read. uses is what scope does with its
    handle: the local name it is bound to, which the rule above has already seen read at least once,
    or holder, the attribute of self it is assigned straight to.

    Returns None when the ending is read, else ("finding", text) or ("note", text)."""
    cls = class_of(mod, scope)
    owner = self_name(scope) if cls is not None else None
    ending, reads, unfollowed = classify(mod, scope, uses, cls)
    kept = [d for _, w, _, d in uses if w == "store"]
    if holder is not None:
        kept.append(holder)
    held = [t.attr for t in kept if isinstance(t, ast.Attribute) and isinstance(t.value, ast.Name)
            and owner is not None and t.value.id == owner]
    for attr in held:
        ending += classify(mod, scope, with_aliases(mod, scope, handle_uses(
            mod, scope, attribute_is(owner, attr), call.lineno)), cls)[0]
    if ending:
        return None
    if held:
        lost, silent = list(unfollowed), []
        for attr in held:
            found, quiet, more = ending_in_class(mod, cls, attr, scope)
            if found:
                return None
            lost += more
            silent += quiet
        where = ", ".join(f"{owner}.{a}" for a in held)
        if silent:
            line, method = silent[0]
            text = (f"{rel}:{call.lineno}: P1 {name} = {what}(...) is held on {where}, and {cls.name}.{method}() "
                    f"ends it at line {line} without reading how it ended (a wait() or poll() whose result is "
                    f"used, or returncode after one of them), so a failure at its end reads as success.")
        else:
            text = (f"{rel}:{call.lineno}: P1 {name} = {what}(...) is held on {where}, which outlives "
                    f"{scope.name}(), and no method of {cls.name} reads how it ended (a wait() or poll() whose "
                    f"result is used, or returncode after one of them), so a failure after it started reads as "
                    f"success.")
        if reads:
            text += f" It is checked only at its start, at line {reads[0]}."
        if lost:
            text += f" It is handed to {lost[0][1]} at line {lost[0][0]}, which this check does not follow."
        return "finding", text
    if kept or unfollowed:
        line, words = unfollowed[0] if unfollowed else next(
            (ln, ast.unparse(d)) for ln, w, _, d in uses if w == "store")
        return "note", (f"{rel}:{call.lineno}: U1 {name} = {what}(...) has its status read only while it runs "
                        f"(line {reads[0] if reads else call.lineno}) and is handed to {words} at line {line}, "
                        f"which this check does not follow, so whether its ending is read was not judged.")
    if not reads:
        return None
    # A poll() a loop repeats already counted as reading the end (classify), so every read left here
    # was made once, and a use after the last of them comes after the only look at the process.
    last = reads[-1]
    later = [(ln, n) for ln, w, n, _ in uses if ln > last and w in ("use", "ends")]
    # A wait() whose result is dropped, or a communicate(), waits for the end and reads none of it: a
    # returncode or a used wait() after it would have counted as the ending above (PR #3659 review).
    waits = [(ln, d) for ln, w, _, d in uses if ln > last and w == "asked" and d in ("wait", "communicate")]
    if waits and not later:
        return "finding", (f"{rel}:{call.lineno}: P1 {name} = {what}(...) has its status read only at line {last}, "
                           f"while it is still running, and {name}.{waits[0][1]}() at line {waits[0][0]} waits for "
                           f"its end but nothing reads how it ended, so a failure reads as success. Read "
                           f"{name}.returncode after it.")
    if later:
        return "finding", (f"{rel}:{call.lineno}: P1 {name} = {what}(...) has its status read only at line {last}, "
                           f"while it is still running, and is used again at line {later[0][0]} with nothing after "
                           f"that reading how it ended, so a failure after its start reads as success. Wait for "
                           f"it once it is done with.")
    return None


def exits_python(path: str, rel: str, notes=None):
    """The findings for one Python helper. What could not be judged is added to notes when given."""
    findings = []
    notes = [] if notes is None else notes
    try:
        tree = ast.parse(open(path, encoding="utf-8", errors="replace").read(), filename=path)
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
                elif kind == "popen":
                    uses = with_aliases(mod, scope, handle_uses(mod, scope, name_is(name), call.lineno, until))
                    said = judge_ending(mod, call, what, scope, name, None, uses, rel)
                    if said:
                        (findings if said[0] == "finding" else notes).append(said[1])
                continue
            scope = mod.scope_of(call)
            cls = class_of(mod, scope)
            target = targets[0] if len(targets) == 1 else None
            if (kind == "popen" and cls is not None and isinstance(target, ast.Attribute)
                    and isinstance(target.value, ast.Name) and target.value.id == self_name(scope)):
                uses = with_aliases(mod, scope, handle_uses(mod, scope, attribute_is(target.value.id, target.attr),
                                                            call.lineno))
                said = judge_ending(mod, call, what, scope, ast.unparse(target), target, uses, rel)
                if said:
                    (findings if said[0] == "finding" else notes).append(said[1])
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


# Whether a line of a script RUNS `gh issue create`, read by lib/shell-words.py, the one reading of a
# command every gate asks (claude-config#1188): each command the shell would run, a substitution's
# and an indented one inside a block included (the PR #936 lessons review), past reserved words,
# assignments, rtk, env, sudo, exec and command, and past gh's flags written in front of the
# subcommand. A comment or a quoted mention is no command. Loaded by its path, never by name, and
# only by the check that needs it, so a reader that cannot be loaded fails that check by name and
# leaves this file's other checks running (the lessons review of #1188).
SHELL_WORDS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "shell-words.py")
_SW = None


def shell_words():
    """The loaded reader, or raises ImportError naming the file when it cannot be loaded."""
    global _SW
    if _SW is None:
        sys.dont_write_bytecode = True
        try:
            spec = importlib.util.spec_from_file_location("shell_words", SHELL_WORDS)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
        except Exception as exc:
            raise ImportError(f"{SHELL_WORDS} could not be loaded ({type(exc).__name__}: {exc})") from exc
        _SW = module
    return _SW


def runs_gh_issue_create(cmd: str) -> bool:
    SW = shell_words()
    # Every command the line runs, a shell's -c string, eval's words and env -S's string read as
    # commands of their own (claude-config#1478), with the crude cut where the reading cannot be
    # trusted.
    for _, text, _, _, _ in SW.every_command(cmd):
        found = SW.tool_read(SW.command_words(SW.command_rest(text)[0]))
        if found and found[:3] == ("gh", "issue", "create"):
            return True
    return False


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
        # A line whose text names neither cannot run one, so it is never read: the reading is not
        # started for every line of every helper, and a reader that cannot be loaded is reported
        # only for a helper that has a call to check (the lessons review of #1188). Only the group's
        # word is looked for, never the action's: gh_path reads `gh issue new` as the create it is
        # (lib/shell-words.py GH_ACTION_ALIASES, claude-config#2411), and every other name of the
        # issue group holds the word issue (test-gh-write-aliases.sh holds that).
        if "gh" not in cmd or "issue" not in cmd:
            continue
        try:
            if not runs_gh_issue_create(cmd):
                continue
        except ImportError as exc:
            # A reader that cannot be loaded finds nothing, which is what a clean script looks like,
            # so it is a finding of its own rather than a pass (L98, L11).
            return [f"{rel}: its gh issue create calls could not be checked: {exc}"]
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
    findings, unjudged = [], []
    for skill in skills:
        for path in walk_files(os.path.join(folder, skill)):
            name = os.path.basename(path)
            if is_suite(name) or PY_TEST.match(name):
                continue  # a test, not a helper
            rel = os.path.relpath(path, folder)
            if name.endswith(".py"):
                n_py += 1
                findings += exits_python(path, rel, unjudged)
            elif name.endswith(".sh"):
                n_sh += 1
                findings += exits_shell(path, rel)
    for f in findings + unjudged:
        print(f)
    print(f"EXITS skills={len(skills)} python={n_py} shell={n_sh} findings={len(findings)} "
          f"unjudged={len(unjudged)}")
    return 0 if not findings else 1


def main(argv) -> int:
    commands = {"links": cmd_links, "unrun": cmd_unrun, "exits": cmd_exits}
    if not argv or argv[0] not in commands:
        return refuse("usage: skill-audit.py {links|unrun|exits} ...")
    return commands[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
