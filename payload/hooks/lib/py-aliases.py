"""A module given another name, for the Slack drafts gate's reading of a Python script
(claude-config#3102).

The gate counts a Python script as unable to act only when every module it reaches is one that
cannot send, run code or write (py_acts, PY_INERT). A module's namespace holds the modules it
imported (glob.os, os.path.os), so py_acts refuses an attribute chain that names one off the list,
but it read chains only from a name an import binds. `q = pathlib` and then q.os.system(...) was
read as unable to act, so the data file such a script was handed went unchecked for a Slack posting
address. Measured through the gate on 2026-11-16: every renamed form in
test-slack-drafts-code-loaders.sh passed.

follow() reads two things from a script's syntax tree:

- The names a module, or anything reached from one by attributes, is bound to where the binding can
  be read: an assignment to a name (annotated or not, chained, or a tuple against a tuple of the
  same shape), a walrus, a for loop or comprehension over a tuple, list or set written out, and a
  parameter's default. py_acts then reads an attribute chain from such a name as it reads one from
  the imported name. Names are followed whatever scope they are in, which can only refuse more.
- A module put where its next use cannot be read: an argument, a list or dictionary, an attribute
  or a subscript, a class body, a return, a lambda's body, an arm of a choice, a comparison another
  object answers. The script is then one the gate has not read end to end, and counts as able to
  act. A module that is only called on (it cannot be), tested (`if json:`, `json is None`), written
  as an annotation, or left as a statement goes nowhere and passes.

Whether a chain is a module is not guessed from its name: datetime.time is a class, os.path a
module, and a sort key such as os.path.getsize a function, which every other script hands on. So
the standard library module is asked. Only a module py_acts already holds to be inert is imported
here (importing one does nothing, which is what the list means), from the standard library's own
folder, and it is read through vars() and a class's own dictionaries, so no property or descriptor
of it runs. What the answer cannot say counts as follows: a module of the script's own is a module
with attributes that are not read (UNREAD), and an attribute of one, or one this Python does not
have, is not known to be a module, so it is followed through a binding and passes when handed on.
That last part is what is not covered: a module held by one of the script's own modules, handed on
rather than renamed.
"""
import ast
import importlib
import os
import sys
import types

UNREAD = object()   # a module whose attributes are not read here: one of the script's own
UNKNOWN = object()  # reached from a module, and not known to be one or not
PLAIN = object()    # an attribute of a function or an instance: nothing a module's namespace holds
NOTHING = object()  # reached from no module at all

SCOPES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)
FOLLOWED_LISTS = (ast.Tuple, ast.List, ast.Set)
STDLIB_DIR = os.path.dirname(os.path.realpath(os.__file__))
_modules = {}


def stdlib(name):
    """The standard library module name, imported once in this run, or UNREAD where it cannot be
    had from the standard library's own folder: it is still a module."""
    if name not in _modules:
        try:
            mod = importlib.import_module(name)
            file = getattr(mod, "__file__", None)
            if file and not os.path.realpath(file).startswith(STDLIB_DIR + os.sep):
                mod = UNREAD
        except Exception:
            mod = UNREAD
        _modules[name] = mod
    return _modules[name]


def is_module(value):
    return value is UNREAD or isinstance(value, types.ModuleType)


def step(value, attr):
    """What value.attr holds, read without running anything of value's."""
    if value is UNREAD or value is UNKNOWN:
        return UNKNOWN
    if isinstance(value, types.ModuleType):
        return vars(value).get(attr, UNKNOWN)
    if isinstance(value, type):
        for cls in type.mro(value):
            if attr in vars(cls):
                return vars(cls)[attr]
        return UNKNOWN
    return PLAIN


def reaches(value):
    """Whether a name bound to value may lead to a module: it is one, may be one, or is a class,
    whose attributes can hold one (pathlib.PurePath.parser). A function, an instance (sys.stdin,
    os.environ) or a constant does not, so `inp = sys.stdin` leaves inp.readline() alone."""
    return value is not sys and (is_module(value) or value is UNKNOWN or isinstance(value, type))


def join(a, b):
    """What a name bound to a in one place and b in another may hold."""
    if a is b:
        return a
    return UNREAD if is_module(a) or is_module(b) else UNKNOWN


def dotted(expr):
    parts = []
    while isinstance(expr, ast.Attribute):
        parts.append(expr.attr)
        expr = expr.value
    return ".".join([expr.id] + parts[::-1])


def make(inert):
    """follow(), given the names of the modules py_acts holds to be inert (PY_INERT)."""
    tops = frozenset(n.split(".")[0] for n in inert) | {"os"}

    def from_module(module, name):
        """What `from module import name` binds, for a standard library module."""
        source = stdlib(module)
        value = step(source, name)
        if value is UNKNOWN and hasattr(source, "__path__"):
            sub = stdlib(f"{module}.{name}")
            value = UNKNOWN if sub is UNREAD else sub
        return value

    def imported(nodes, local):
        """For each name an import binds, the ways to work out what it holds, one per import of it.
        Each is asked only when the name is read (held, in follow), so a script pays for importing
        a module here only where it renames one or hands something of it on: importing argparse,
        dataclasses and statistics for a script that only calls them would cost every such call
        tens of milliseconds. local is the names bound by an import of one of the script's own
        modules, or of one placed nowhere."""
        ways = {}
        for node in nodes:
            if isinstance(node, ast.Import):
                for a in node.names:
                    top = a.name.split(".")[0]
                    name = a.asname or top
                    if name in local or top not in tops:
                        way = lambda: UNREAD
                    elif a.asname:
                        way = lambda n=a.name: stdlib(n)
                    else:  # a.b imported first, so b is there to be found on a, as it is in the script
                        way = lambda n=a.name, t=top: (stdlib(n), stdlib(t))[1]
                    ways.setdefault(name, []).append(way)
            elif isinstance(node, ast.ImportFrom):
                module = node.module or ""
                for a in node.names:
                    name = a.asname or a.name
                    if node.level or name in local or module.split(".")[0] not in tops:
                        way = lambda: UNKNOWN
                    else:
                        way = lambda m=module, n=a.name: from_module(m, n)
                    ways.setdefault(name, []).append(way)
        return ways

    def follow(nodes, local):
        """(names, phrase): the names a module, or something reached from one, is bound to beyond
        the ones an import binds, and how the script puts a module where the gate does not follow
        it, as a phrase, or None."""
        ways = imported(nodes, local)
        holds = {}

        def held(name):
            """What name holds, NOTHING for one no module has reached."""
            for way in ways.pop(name, ()):
                v = way()
                holds[name] = join(holds[name], v) if name in holds else v
            return holds.get(name, NOTHING)

        def value(expr):
            if isinstance(expr, ast.Name):
                return held(expr.id)
            if isinstance(expr, ast.Attribute):
                base = value(expr.value)
                return NOTHING if base is NOTHING else step(base, expr.attr)
            return NOTHING

        # A class body binds attributes of the class, which are read through the class or an
        # instance and not by name, so a binding there is not one the gate follows.
        in_class = set()
        for node in nodes:
            if isinstance(node, ast.ClassDef):
                stack = list(node.body)
                while stack:
                    n = stack.pop()
                    in_class.add(id(n))
                    if not isinstance(n, SCOPES):
                        stack.extend(ast.iter_child_nodes(n))

        followed = set()  # id() of each expression whose value went to a name the gate reads on from
        renamed = set()  # each name bound to something that may lead to a module (reaches)
        changed = [True]

        def bind_name(name, expr, whole=True):
            v = value(expr)
            if v is NOTHING:
                return
            if whole:  # a walrus also gives its value to wherever it stands, which is read below
                followed.add(id(expr))
            if reaches(v):
                renamed.add(name)
            old = held(name)
            new = v if old is NOTHING else join(old, v)
            if new is not old:
                holds[name] = new
                changed[0] = True

        def bind(target, expr):
            if isinstance(target, ast.Name):
                bind_name(target.id, expr)
            elif isinstance(target, (ast.Tuple, ast.List)) and isinstance(expr, (ast.Tuple, ast.List)) \
                    and len(target.elts) == len(expr.elts) \
                    and not any(isinstance(e, ast.Starred) for e in target.elts + expr.elts):
                for t, e in zip(target.elts, expr.elts):
                    bind(t, e)

        while changed[0]:
            changed[0] = False
            for node in nodes:
                if id(node) in in_class:
                    continue
                if isinstance(node, ast.Assign):
                    for target in node.targets:
                        bind(target, node.value)
                elif isinstance(node, ast.AnnAssign) and node.value is not None:
                    bind(node.target, node.value)
                elif isinstance(node, ast.NamedExpr):
                    bind_name(node.target.id, node.value, whole=False)
                elif isinstance(node, (ast.For, ast.AsyncFor, ast.comprehension)):
                    if isinstance(node.target, ast.Name) and isinstance(node.iter, FOLLOWED_LISTS):
                        for e in node.iter.elts:
                            bind_name(node.target.id, e)
                elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                    params = node.args.posonlyargs + node.args.args
                    for p, d in zip(params[len(params) - len(node.args.defaults):], node.args.defaults):
                        bind_name(p.arg, d)
                    for p, d in zip(node.args.kwonlyargs, node.args.kw_defaults):
                        if d is not None:
                            bind_name(p.arg, d)

        parent = {id(c): n for n in nodes for c in ast.iter_child_nodes(n)}

        def goes_nowhere(expr, p):
            """Whether expr, a child of p, is used where its value is handed to nothing."""
            if isinstance(p, ast.Call):
                return p.func is expr
            if isinstance(p, ast.Compare):
                return all(isinstance(op, (ast.Is, ast.IsNot)) for op in p.ops)
            if isinstance(p, (ast.If, ast.While, ast.IfExp, ast.Assert)):
                return p.test is expr
            if isinstance(p, ast.UnaryOp):
                return isinstance(p.op, ast.Not)
            if isinstance(p, (ast.arg, ast.AnnAssign)):
                return p.annotation is expr
            if isinstance(p, (ast.FunctionDef, ast.AsyncFunctionDef)):
                return p.returns is expr
            return isinstance(p, ast.Expr)

        phrase = None
        for node in nodes:
            if not isinstance(node, (ast.Name, ast.Attribute)) or not isinstance(node.ctx, ast.Load):
                continue
            p = parent.get(id(node))
            if isinstance(p, ast.Attribute) or id(node) in followed:
                continue
            # `a and b` and `a or b` give one of the two, and a walrus gives what it binds, so each
            # goes wherever the whole expression goes.
            at = node
            while isinstance(p, (ast.BoolOp, ast.NamedExpr)):
                at, p = p, parent.get(id(p))
            if goes_nowhere(at, p):
                continue
            if is_module(value(node)):
                phrase = f"puts the module {dotted(node)} where the gate does not follow it"
                break
        return renamed, phrase

    return follow
