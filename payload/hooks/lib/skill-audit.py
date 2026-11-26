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
           read in another method of its class (and in the method that ends it, after the end on
           every path out of that method, when one does), or waited for on every path out of the
           method that starts it; a local one read only by `poll()` must not be used again
           after that read, nor waited on after it (a `wait()` whose result is dropped, or
           `communicate()`) unless a `returncode` read or a `wait()` whose result is used follows.
           Its uses are compared in the order the code runs them, never by line, a helper's spliced
           in at its hand off; a use whose only reads are on other arms of an if is unread.
           A `poll()` whose result is only compared with None (`while p.poll() is None`) asks
           whether the process still runs and is no read of how it ended (#3663).
       U1  not a finding: a local process whose status was read while it ran, then handed to
           something the check cannot follow (or round a cycle), or whose only read after a use
           runs on some of its paths, so whether its ending is read was not judged.
           Printed and counted, and it does not fail the check. A process held on an attribute
           whose ending no method reads is a P1 even when it is handed to something the check
           cannot follow, and the finding names that hand off.
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


def none_test(mod, node):
    """Whether node is only compared with None, as in `node is None` or `None is not node`."""
    up = mod.parent.get(node)
    if not isinstance(up, ast.Compare) or len(up.ops) != 1:
        return False
    other = up.comparators[0] if up.left is node else up.left
    return (isinstance(up.ops[0], (ast.Is, ast.IsNot, ast.Eq, ast.NotEq))
            and isinstance(other, ast.Constant) and other.value is None)


def only_asks_if_running(mod, call):
    """Whether a poll() call's result is only ever compared with None, directly or through the one
    name it is bound to (claude-config#3663). That asks whether the process is still running and
    says nothing of how it ended: `while p.poll() is None` leaves the loop whatever the status is."""
    if none_test(mod, call):
        return True
    up = mod.parent.get(call)
    if not (isinstance(up, ast.Assign) and up.value is call and len(up.targets) == 1
            and isinstance(up.targets[0], ast.Name)):
        return False
    name, scope = up.targets[0].id, mod.scope_of(call)
    later = [ln for ln in bindings(scope, name) if ln > call.lineno]
    until = later[0] if later else float("inf")
    loads = [n for n in ast.walk(scope) if isinstance(n, ast.Name) and n.id == name
             and isinstance(n.ctx, ast.Load) and call.lineno <= n.lineno < until]
    return bool(loads) and all(none_test(mod, n) for n in loads)


def status_reads(mod, scope, name, kind, asks=False):
    """Line numbers where scope reads the exit status held in `name`. A poll() only compared with
    None is no read (see only_asks_if_running) unless asks is true, which the first look at a local
    process sets so that what such a poll() leaves unread is judged, and said, by judge_ending."""
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
                if (isinstance(call, ast.Call) and not isinstance(mod.parent.get(call), ast.Expr)
                        and (asks or node.attr == "wait" or not only_asks_if_running(mod, call))):
                    lines.append(node.lineno)
    return sorted(lines)


# A long lived process's ENDING (claude-config#3650). Judging one function at a time cannot tell a
# poll() made just after a process starts from a read of how it ended. So a Popen whose handle
# outlives the function that started it, held on an attribute of self, is followed through every
# method of its class: directly, through a local taken from the attribute (`proc = self.x`, or
# `proc, self.x = self.x, None`), and into a method or a top level function of the same file it is
# handed to. In the method that starts it only a read that waits for the end counts, and it settles the
# process alone only when every path out of that method waits (#3663). A local process
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


# Where a use runs, in the order the code runs it (PR #3659 review at 1a6083d): never its line, which
# two uses can share and which a helper's uses do not have in the caller. A place is (order, guards).
# order is the path from the function down to the node, one (field, index) pair per step, so two
# places compare as the code runs them: statements in order, the test of an if before its body, a
# second statement on a line after the first. A helper's uses are spliced in after everything its
# hand off evaluates (AFTER_CALL). guards names each branch or loop the node sits inside, as
# (construct, arm), so a read on the other arm of an if from a use is never on its path, and a read
# inside a branch the use is not inside runs only on some of its paths.
AFTER_CALL = (99, 0)


def arm_of(parent, field, index):
    """The (construct, arm) that running a child in this field of parent depends on, or None when the
    child runs whenever parent does."""
    if isinstance(parent, (ast.If, ast.IfExp)) and field in ("body", "orelse"):
        return (id(parent), field)
    if isinstance(parent, (ast.For, ast.AsyncFor, ast.While)) and field in ("body", "orelse"):
        return ((id(parent), field), "runs")  # a loop's body and its else are not alternatives
    if (isinstance(parent, ast.Try) or type(parent).__name__ == "TryStar") and field in ("handlers", "orelse"):
        return (id(parent), (field, index))
    if type(parent).__name__ == "Match" and field == "cases":
        return (id(parent), index)
    if isinstance(parent, ast.BoolOp) and index:
        return ((id(parent), index), "runs")
    if isinstance(parent, (ast.ListComp, ast.SetComp, ast.GeneratorExp, ast.DictComp, ast.Lambda,
                           ast.FunctionDef, ast.AsyncFunctionDef)):
        return ((id(parent), "later"), "runs")
    return None


def place(mod, node, scope):
    order, guards, child, parent = [], [], node, mod.parent.get(node)
    while parent is not None and child is not scope:
        for f, (field, value) in enumerate(ast.iter_fields(parent)):
            index = next((i for i, v in enumerate(value) if v is child), None) if isinstance(value, list) else (
                0 if value is child else None)
            if index is not None:
                order.append((f, index))
                # The function judged runs its own body whenever it runs: only a def, lambda or
                # comprehension inside it is run later, if at all (the review at fdcf350).
                guard = arm_of(parent, field, index) if parent is not scope else None
                if guard is not None:
                    guards.append(guard)
                break
        child, parent = parent, mod.parent.get(parent)
    return tuple(reversed(order)), tuple(reversed(guards))


def exclusive(a, b):
    """Whether the places a and b are on different arms of one if, try or match, so no run reaches
    both."""
    for x, y in zip(a[1], b[1]):
        if x != y:
            return x[0] == y[0]
    return False


def on_every_path_after(read, use):
    """Whether every run that reaches use goes on to reach read, as far as branches tell: read sits
    inside no branch or loop that use is not inside too."""
    return read[0] > use[0] and use[1][:len(read[1])] == read[1]


def handle_uses(mod, scope, is_handle, start=0, until=float("inf")):
    """Everything scope does with a process handle, as (line, what, node, detail, place), in the order
    the code runs it (see place; a hand off's place is that of its call).

    what is one of: wait or poll (a call whose result is used), asked (wait, poll or communicate
    called with its result dropped, or communicate; detail names which, and is running for a poll()
    whose result is only compared with None), returncode, ends (the code
    ending the process, see ends_it), use (any other attribute), handed (the handle passed on; detail is the Call, or None when it goes somewhere no
    call names: returned, yielded, stored in a container), alias (bound to a local; detail is its
    name) and store (assigned to an attribute or item; detail is the target). with_aliases adds
    enters (a hand off it follows; node is the Call and detail the function) and again."""
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
                if called and a == "poll" and only_asks_if_running(mod, call):
                    uses.append((line, "asked", parent, "running"))
                elif called and a in ("wait", "poll") and not isinstance(mod.parent.get(call), ast.Expr):
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
    placed = [u + (place(mod, u[3] if u[1] == "handed" and u[3] is not None else u[2], scope),) for u in uses]
    return sorted(placed, key=lambda u: u[4][0])


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


def with_aliases(mod, scope, uses, seen=frozenset()):
    """uses, plus what scope does through every local it binds the handle to, with each hand off to a
    function of this file replaced by everything that function does with it, at the line of the hand
    off and in the helper's own order after everything the hand off evaluates (see place). So every
    rule judges a helper's wait, poll, write or kill exactly as if the caller had made it there (the
    lessons reviews of PR #3659). seen holds the (function, parameter) pairs already being followed: a
    handle passed round a cycle comes back as "again", a hand off the check does not follow. Each hand
    off followed also leaves an "enters" use at its place, node the call and detail the function, so
    the path rule (exit_states) can run that function's own paths from the state at the hand off; no
    other rule reads it."""
    out = list(uses)
    for u in uses:
        if u[1] == "alias":
            later = [ln for ln in bindings(scope, u[3]) if ln > u[0]]
            out += handle_uses(mod, scope, name_is(u[3]), u[0], later[0] if later else float("inf"))
    cls, followed = class_of(mod, scope), []
    for u in sorted(out, key=lambda u: u[4][0]):
        target = handed_to(mod, u[3], u[2], scope, cls) if u[1] == "handed" and u[3] is not None else None
        if target is None:
            followed.append(u)
        elif target in seen:
            followed.append((u[0], "again") + u[2:])
        else:
            fn, param = target
            inner = with_aliases(mod, fn, handle_uses(mod, fn, name_is(param)), seen | {target})
            # The helper's branches are keyed by this hand off, so the same if in a helper reached
            # from two hand offs is two ifs, never one whose arms exclude each other.
            (order, guards), call = u[4], id(u[3])
            followed.append((u[0], "enters", u[3], fn, u[4]))
            followed += [(u[0], w, n, d, (order + (AFTER_CALL,) + at[0],
                                          guards + tuple(((call, g[0]), g[1]) for g in at[1])))
                         for _, w, n, d, at in inner]
    return followed


def classify(mod, scope, uses, cls):
    """Sort a function's uses of a handle into reads of how it ended. A hand off to a function of this
    file has already been replaced by what that function does (with_aliases).

    Returns (ending, reads, unfollowed): ending holds the uses that read the status once the process
    is done (a wait() whose result is used, a returncode after a wait() or communicate(), or a poll()
    a loop repeats, never one only compared with None); reads holds every use that reads the status
    at all (any of those, a poll() whose result is used, or a returncode after anything asked for
    it), both as the uses themselves, so their places can be compared and the path rule can tell
    which node did what; unfollowed holds the hand offs that could not be followed, as
    (line, words)."""
    ending, reads, unfollowed, asked, waited = [], [], [], False, False
    for u in uses:
        line, what, node, detail, _ = u
        if what == "wait":
            ending.append(u)
            reads.append(u)
            asked = waited = True
        elif what == "poll":
            reads.append(u)
            asked = True
            if loops_around(mod, node, scope):
                ending.append(u)
        elif what == "asked":
            asked = True
            waited = waited or detail in ("wait", "communicate")
        elif what == "returncode":
            if asked:
                reads.append(u)
            if waited:
                ending.append(u)
        elif what == "handed":
            target = handed_to(mod, detail, node, scope, cls) if detail is not None else None
            if target is None:
                words = (f"{ast.unparse(detail.func)}(...)" if detail is not None
                         else "something outside this function")
                unfollowed.append((line, words))
    return ending, reads, unfollowed


# The paths through one method (claude-config#3663). A read of how a held process ended counts for a
# method that ends it only when it comes after the end on every path out of the method, and the
# method that starts it settles it alone only when every path out of it has waited for the end.
NONE, RUNNING, UNREAD, READ = "not started", "running", "ended unread", "read"


def step(state, event):
    if event == "starts":
        return RUNNING
    if event == "ends":
        return UNREAD if state == RUNNING else state
    if event == "waits":  # waits for the end and reads it, whatever came before
        return READ if state != NONE else state
    if event == "looks":  # reads the status, which tells how it ended only once something ended it
        return READ if state == UNREAD else state
    return state


def exit_states(fn, events, start, entered=frozenset()):
    """The states the process can be in wherever fn returns, raises or runs off its end, following
    both branches of every if, every handler of a try, and a loop run any number of times. events maps
    a node to what it does (see step), or, for a hand off with_aliases followed, to ("enters", the
    function), whose own paths are run from the state at the hand off. Exceptions are followed only
    into the handlers of a try that holds them, and a return, raise, break or continue inside a try
    runs its finally before it leaves. entered holds the functions already being run, so a hand off
    round a cycle leaves the state as it was."""
    sinks = [set()]  # where a return or raise lands: the innermost try's finally, else out of fn

    def at(node, states):
        if node is None:
            return states
        hits = sorted((n for n in ast.walk(node) if n in events), key=lambda n: (n.lineno, n.col_offset))
        for n in hits:
            event = events[n]
            if isinstance(event, tuple):
                helper = event[1]
                if helper is not fn and helper not in entered:
                    states = set().union(*(exit_states(helper, events, s, entered | {fn}) for s in states))
            else:
                states = {step(s, event) for s in states}
        return states

    def block(stmts, states, loop):
        for s in stmts:
            if not states:
                break
            states = statement(s, states, loop)
        return states

    def statement(s, states, loop):
        if isinstance(s, ast.If):
            states = at(s.test, states)
            return block(s.body, states, loop) | block(s.orelse, states, loop)
        if isinstance(s, (ast.For, ast.AsyncFor, ast.While)):
            is_while = isinstance(s, ast.While)
            forever = is_while and isinstance(s.test, ast.Constant) and bool(s.test.value)
            inner = {"break": set(), "continue": set()}
            head = set(states if is_while else at(s.iter, states))
            while True:
                entered_loop = at(s.test, head) if is_while else head
                grown = head | block(s.body, entered_loop, inner) | inner["continue"]
                if grown == head:
                    break
                head = grown
            left = set() if forever else (at(s.test, head) if is_while else head)
            return block(s.orelse, left, loop) | inner["break"]
        if isinstance(s, (ast.With, ast.AsyncWith)):
            for item in s.items:
                states = at(item.context_expr, states)
            return block(s.body, states, loop)
        if isinstance(s, ast.Try) or type(s).__name__ == "TryStar":
            outer = loop
            if s.finalbody:
                sinks.append(set())
                if loop is not None:  # a break or continue runs the finally before it leaves too
                    loop = {"break": set(), "continue": set()}
            raised, current = set(states), states
            for b in s.body:
                if not current:
                    break
                current = statement(b, current, loop)
                raised |= current
            out = block(s.orelse, current, loop)
            for h in s.handlers:
                out |= block(h.body, raised, loop)
            if not s.finalbody:
                return out
            leaving = sinks.pop()
            sinks[-1].update(block(s.finalbody, leaving, outer))
            if loop is not outer:
                for way in ("break", "continue"):
                    outer[way].update(block(s.finalbody, loop[way], outer))
            return block(s.finalbody, out, outer)
        if type(s).__name__ == "Match":
            states = at(s.subject, states)
            out = set(states)
            for case in s.cases:
                out |= block(case.body, states, loop)
            return out
        if isinstance(s, (ast.Return, ast.Raise)):
            sinks[-1].update(at(s, states))
            return set()
        if isinstance(s, (ast.Break, ast.Continue)) and loop is not None:
            loop["break" if isinstance(s, ast.Break) else "continue"].update(states)
            return set()
        return at(s, states)

    sinks[0].update(block(fn.body, {start}, None))
    return sinks[0]


def events_of(uses, ending, reads):
    """What each use of a handle does to it, for exit_states. uses come from with_aliases, so a
    helper's uses sit at their own nodes in the helper and its hand off is an "enters"."""
    ended, looked, events = {id(u) for u in ending}, {id(u) for u in reads}, {}
    for u in uses:
        if u[1] == "ends":
            events[u[2]] = "ends"
        elif u[1] == "enters":
            events[u[2]] = ("enters", u[3])
        elif id(u) in ended:
            events[u[2]] = "waits"
        elif id(u) in looked:
            events[u[2]] = "looks"
    return events


def ending_in_class(mod, cls, attr, start_fn):
    """Whether the methods of cls other than start_fn read how the process held on attr ended.

    A method that ENDS the process (see ends_it) must read how it ended itself, or call a method of
    cls that does: a read on some other path, such as an error branch, says nothing about the end the
    code brings about. That read, or the call, must come after the end on every path out of the
    method (claude-config#3663): a read on one branch, or before the end, leaves the other path
    unread. A process no method ends, which ends by itself, needs a read in any method.
    Returns (read, enders that leave it unread as (line, method name), unfollowed hand offs)."""
    unfollowed, readers, enders = [], set(), {}
    per = {}
    for fn in methods_of(cls).values():
        owner = self_name(fn)
        if fn is start_fn or owner is None:
            continue
        uses = with_aliases(mod, fn, handle_uses(mod, fn, attribute_is(owner, attr)))
        ending, reads, lost = classify(mod, fn, uses, cls)
        per[fn.name] = (fn, owner, uses, ending, reads)
        if reads:
            readers.add(fn.name)
        unfollowed += lost
        ends = [u[0] for u in uses if u[1] == "ends"]
        if ends:
            enders[fn.name] = ends[0]
    if not enders:
        return bool(readers), [], unfollowed

    def leaves_it_unread(name):
        fn, owner, uses, ending, reads = per[name]
        events = events_of(uses, ending, reads)
        for node in ast.walk(fn):
            if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                    and isinstance(node.func.value, ast.Name) and node.func.value.id == owner
                    and node.func.attr in readers and node not in events):
                events[node] = "looks"
        return UNREAD in exit_states(fn, events, RUNNING)

    silent = [(line, name) for name, line in sorted(enders.items(), key=lambda e: e[1])
              if leaves_it_unread(name)]
    return not silent, silent, unfollowed


def class_of(mod, scope):
    """The class scope is a method of, or None."""
    if not isinstance(scope, (ast.FunctionDef, ast.AsyncFunctionDef)):
        return None
    cls = mod.parent.get(scope)
    return cls if isinstance(cls, ast.ClassDef) else None


def judge_ending(mod, call, what, scope, name, holder, uses, rel):
    """Whether the ending of the process call started is read. uses is what scope does with its
    handle: the local name it is bound to, which the rule above has already seen read or asked at
    least once (a poll() only compared with None, which is judged here), or holder, the attribute of
    self it is assigned straight to.

    Returns None when the ending is read, else ("finding", text) or ("note", text)."""
    cls = class_of(mod, scope)
    owner = self_name(scope) if cls is not None else None
    ending, reads, unfollowed = classify(mod, scope, uses, cls)
    running = [u[0] for u in uses if u[1] == "asked" and u[3] == "running"]
    kept = [d for _, w, _, d, _ in uses if w == "store"]
    if holder is not None:
        kept.append(holder)
    held = [t.attr for t in kept if isinstance(t, ast.Attribute) and isinstance(t.value, ast.Name)
            and owner is not None and t.value.id == owner]
    events = events_of(uses, ending, reads)
    for attr in held:
        on = with_aliases(mod, scope, handle_uses(mod, scope, attribute_is(owner, attr), call.lineno))
        more, seen, _ = classify(mod, scope, on, cls)
        ending += more
        events.update(events_of(on, more, seen))
        running += [u[0] for u in on if u[1] == "asked" and u[3] == "running"]
    if ending and held:
        # Held past this method, it is settled here only when every path out of it waited (#3663).
        events[call] = "starts"
        if exit_states(scope, events, NONE) <= {NONE, READ}:
            return None
    elif ending:
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
                    f"ends it at line {line} without reading how it ended on every path after that (a wait() or "
                    f"poll() whose result is used, or returncode after one of them), so a failure at its end reads "
                    f"as success.")
        else:
            text = (f"{rel}:{call.lineno}: P1 {name} = {what}(...) is held on {where}, which outlives "
                    f"{scope.name}(), and no method of {cls.name} reads how it ended on every path (a wait() or "
                    f"poll() whose result is used, or returncode after one of them), so a failure after it started "
                    f"reads as success.")
        if reads:
            text += f" It is checked only at its start, at line {reads[0][0]}."
        elif running:
            text += (f" It is only asked whether it is still running, at line {running[0]}, which is no read of "
                     f"how it ended.")
        if lost:
            text += f" It is handed to {lost[0][1]} at line {lost[0][0]}, which this check does not follow."
        return "finding", text
    if kept or unfollowed:
        line, words = unfollowed[0] if unfollowed else next(
            (ln, ast.unparse(d)) for ln, w, _, d, _ in uses if w == "store")
        return "note", (f"{rel}:{call.lineno}: U1 {name} = {what}(...) has its status read only while it runs "
                        f"(line {reads[0][0] if reads else (running or [call.lineno])[0]}) and is handed to {words} "
                        f"at line {line}, which this check does not follow, so whether its ending is read was not "
                        f"judged.")
    if not reads:
        if running:
            return "finding", (f"{rel}:{call.lineno}: P1 {name} = {what}(...) is only asked whether it is still "
                               f"running, at line {running[0]} (a poll() compared with None), and how it ended is "
                               f"never read, so a failure reads as success. Read returncode once it has ended, or "
                               f"wait for it.")
        return None
    # A poll() a loop repeats already counted as reading the end (classify), so every read left here
    # was made once. Each use made after a read on its path must have a read after it on that path,
    # compared by place, never by line (PR #3659 review at 1a6083d). A wait() whose result is dropped,
    # or a communicate(), waits for the end and reads none of it: a returncode or a used wait() after
    # it would have counted as the ending above (PR #3659 review).
    unread, unmeasured = [], []
    for u in uses:
        if not (u[1] in ("use", "ends") or (u[1] == "asked" and u[3] in ("wait", "communicate"))):
            continue
        before = [r for r in reads if r[4][0] < u[4][0] and not exclusive(r[4], u[4])]
        after = [r for r in reads if r[4][0] > u[4][0] and not exclusive(r[4], u[4])]
        # A use with no read on its path at all, the reads all on other arms, is unread too.
        last = before[-1] if before else None
        if not after:
            unread.append((u, last))
        elif not any(on_every_path_after(r[4], u[4]) for r in after):
            unmeasured.append((u, last, after[0]))
    later = [(u, r) for u, r in unread if u[1] in ("use", "ends")]
    waits = [(u, r) for u, r in unread if u[1] == "asked"]
    if waits and not later:
        (ln, _, _, d, _), last = waits[0]
        return "finding", (f"{rel}:{call.lineno}: P1 {name} = {what}(...) has its status read only at line "
                           f"{(last or reads[0])[0]}, while it is still running, and {name}.{d}() at line {ln} waits for "
                           f"its end but nothing reads how it ended, so a failure reads as success. Read "
                           f"{name}.returncode after it.")
    if later:
        u, last = later[0]
        if last is None:
            return "finding", (f"{rel}:{call.lineno}: P1 {name} = {what}(...) has its status read only on another "
                               f"branch (line {reads[0][0]}) from its use at line {u[0]}, so on that path nothing "
                               f"reads how it ended and a failure reads as success. Wait for it once it is done with.")
        return "finding", (f"{rel}:{call.lineno}: P1 {name} = {what}(...) has its status read only at line "
                           f"{last[0]}, while it is still running, and is used again at line {u[0]} with nothing "
                           f"after that reading how it ended, so a failure after its start reads as success. Wait "
                           f"for it once it is done with.")
    if unmeasured:
        u, last, then = unmeasured[0]
        return "note", (f"{rel}:{call.lineno}: U1 {name} = {what}(...) is used at line {u[0]}"
                        + (f", after its status is read at line {last[0]}," if last else "")
                        + f" and the read after that, at line {then[0]}, runs only on some of the paths from it, "
                        f"so whether its ending is read was not judged.")
    cycles = [u for u in uses if u[1] == "again"]
    if cycles:
        return "note", (f"{rel}:{call.lineno}: U1 {name} = {what}(...) has its status read only while it runs "
                        f"(line {reads[0][0]}) and is handed to {ast.unparse(cycles[0][3].func)}(...) at line "
                        f"{cycles[0][0]} a second time, round a cycle this check does not follow, so whether its "
                        f"ending is read was not judged.")
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
                if not any(call.lineno <= ln < until for ln in status_reads(mod, scope, name, kind, asks=True)):
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
