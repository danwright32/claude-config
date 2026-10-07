#!/bin/bash
# check-mod-noun-waits.sh <mods dir>: no mod's own $ noun waits on a person, or on anything else with
# no bound under 10 seconds (#744). Claude Code cuts a call to a plugin's noun off at 10 s: measured
# live on 2026-10-05 (2.1.289), `$.probe.wait` was rejected at 10,003 ms with "did not answer within
# 10000ms". `claude plugin test` does not apply that limit, so such a noun passes every test of its
# own and fails only in a session. Picker manners' `$.pickers.wait` did exactly that: its tool.call
# hook waited through it for a press in the band, the wait was rejected at 10 s, and Claude Code's
# own dialog then asked every question a second time.
#
# The reason, not one named case (L362): a noun's code makes a promise that only a later event
# settles, with nothing bounding it under 10 s. Read as:
#   - a `new Promise` whose executor does not settle it itself: its resolve or reject is kept (in a
#     map, a list, a variable), handed to something else (an event listener), or called back from a
#     function the executor makes; unless a timer under 10 s (`setTimeout`, `$.clock.after`, with a
#     delay read from a number or a constant) settles it in that same executor. A promise its
#     executor never settles at all is reported too. An executor named rather than written in place
#     is read where it is defined, and one that cannot be found is reported as unreadable.
#   - `$.ui.ask` (as `$` or `built`), Claude Code's own question dialog: a person has no bound.
#   - a promise made OUTSIDE a noun's code (in another hook, say) and kept in a variable, or in a
#     map or list through .set, .push, .unshift or .add, whose name a noun's code reads: judged as
#     above and named where it is made (#756).
# A wait is bounded too when the noun races it, `Promise.race([wait, timer])`, against a timer made
# in another executor: one written in place, a constant holding one, or a call to a mod function
# making one, its delay read through the call's own arguments (`sleep(5_000)`); likewise a helper
# whose promise a timer settles is judged at every call a noun makes of it (#756).
# A noun's code is each `engine.create` hook's (where the nouns' methods are written), each hook on
# a noun's own event (`on('modkit.screen', ...)`, any noun any mod's contract declares on $), and
# every function of the mod those call. A called name is resolved by the TypeScript compiler's own
# checker (tools/lib/ts-resolve.mjs, run on the compiler pinned in tools/typescript), so scope,
# shadowing, parameters and imports are the language's answer, never the first declaration of that
# name anywhere in the mod (#895). A name the checker finds no symbol for is followed by name, as
# before.
#
# Measured live on 2026-10-05 (2.1.289, a throwaway plugin in a headless `claude -p`, #756): a
# noun's 10 s does NOT stop while its own `$` calls are in flight, unlike a hook's budget. A noun
# whose only wait was `$.process.run(['/bin/sleep', '13'])` was rejected at 10,003 ms, exactly as
# the control (a 13 s timer) was at 10,002 ms. So the refusal of `$.ui.ask` above is never a false
# one, and any slow `$` call inside a noun is cut the same way.
#
#   - a noun's own `$.process.run` with no timeoutMs under 10 s (none given means Claude Code's
#     30 s default), and any `$.model.complete`, since the noun's 10 s keeps running through them
#     (#802).
#
# What it does not read: a promise stored any other way (inside an object, returned through a
# chain of variables), a member of a race reached through a variable rather than written in the
# race, and how long an engine `$` call other than these takes. A hook has its own 10 s budget,
# which `$` calls do not spend; that is not this check's to judge.
#
# Source is read through tools/lib/ts_source.py, the one reader every mod scan shares, so a comment
# or a string naming the shape is never taken for code.
#
# Exit codes, each distinct (L11): 0 none found (the count of mods is printed, L98), 1 a wait found
# or a noun's code that cannot be read, each named with its file and line, 2 the mods folder does
# not exist, 3 no python3 to read the source with, 4 the pinned TypeScript compiler cannot be
# loaded, so no call could be resolved (L490: never a pass over nothing read). CHECK_MODS_TS_DIR
# names another folder holding it, as check-mods.sh reads it.
dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  echo "check-mod-noun-waits: '${dir:-<none given>}' is not a folder, so nothing was checked." >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "check-mod-noun-waits: python3 is not installed, so no mod's source was read." >&2
  exit 3
fi
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "${dir%/}" "$here/lib" "${CHECK_MODS_TS_DIR:-$here/typescript}" <<'PY'
import ast, json, os, re, subprocess, sys

root = sys.argv[1]
sys.path.insert(0, sys.argv[2])
from ts_source import CODE, block_after, closing, code_only, function_span, is_jsx, kinds, top_members

LIMIT_MS = 10_000
CUT = "Claude Code cuts a noun call off at 10 s (#744)"
SOURCE = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts")
# Not the mod's code: its tests (which stand in for other mods), its own contract, and what Claude
# Code generates into its folder.
SKIP_DIRS = {"tests", "types", ".claude-plugin", "node_modules"}
KEYWORDS = {"if", "for", "while", "switch", "catch", "return", "typeof", "function", "await", "new", "void", "delete", "do", "else", "in", "of", "instanceof", "super", "import"}
IDENT = r"[A-Za-z_$][\w$]*"
failed = 0
reports = []


def report(line):
    global failed
    failed = 1
    reports.append(line)


class File:
    def __init__(self, mod, rel, text):
        self.mod, self.rel, self.text = mod, rel, text
        self.code = code_only(text, is_jsx(rel))
        self.kinds = kinds(text, is_jsx(rel))

    def line(self, at):
        return self.code.count("\n", 0, at) + 1

    def where(self, at):
        return f"{self.mod}/{self.rel}:{self.line(at)}"


mods = []
for entry in sorted(os.listdir(root)):
    folder = os.path.join(root, entry)
    manifest = os.path.join(folder, ".claude-plugin", "plugin.json")
    if not os.path.isfile(manifest):
        continue
    try:
        with open(manifest) as f:
            man = json.load(f)
    except (OSError, ValueError) as e:
        report(f"check-mod-noun-waits: {entry}'s plugin.json cannot be read ({e}), so its nouns were not checked.")
        continue
    files = []
    for base, dirs, names in os.walk(folder):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(names):
            if not name.endswith(SOURCE) or ".test." in name or name.endswith(".d.ts"):
                continue
            path = os.path.join(base, name)
            try:
                with open(path) as f:
                    files.append(File(entry, os.path.relpath(path, folder), f.read()))
            except (OSError, UnicodeDecodeError) as e:
                report(f"check-mod-noun-waits: {entry}/{os.path.relpath(path, folder)} cannot be read ({e}), so its nouns were not checked.")
    mods.append((entry, folder, man, files))

# Every noun any mod's contract declares on $: a hook on one of their events answers that noun.
nouns = set()
for entry, folder, man, files in mods:
    types = man.get("types")
    if not isinstance(types, str):
        continue
    try:
        with open(os.path.join(folder, types)) as f:
            body = block_after(f.read(), r"interface\s+EngineInterface\s*\{")
    except OSError as e:
        report(f"check-mod-noun-waits: {entry}'s contract {types} cannot be read ({e}), so hooks on its nouns' events were not found.")
        continue
    if body is not None:
        nouns.update(top_members(body))


def hooks_on(f, wanted):
    """Each hook f registers on an event wanted accepts: (where it starts, where it ends), the end
    None when its brackets never close."""
    for m in re.finditer(r"(?<![\w$.])on\s*\(", f.code):
        if f.kinds[m.start()] != CODE:
            continue
        # The event name is a string, so it is read from the text, not the code view that blanks it.
        ev = re.match(r"\s*(['\"`])([\w.:-]+)\1", f.text[m.end():])
        if not ev or not wanted(ev.group(2)):
            continue
        yield m.start(), closing(f.code, m.end() - 1)


def definition(files, name):
    """Where the function called name is defined in the mod: (file, start, end), or None."""
    for f in files:
        span = function_span(f.code, name, f.kinds)
        if span:
            return f, span[0], span[1]
    return None


def resolve_all(mods):
    """Every identifier in every mod's source, resolved by the TypeScript compiler's checker (#895):
    each File gets refs, its position (in code points) to (role, target), as ts-resolve.mjs describes
    them. Exits 4, naming why, when the pinned compiler cannot be loaded or read a mod (L490)."""
    ts_dir = sys.argv[3]
    script = os.path.join(sys.argv[2], "ts-resolve.mjs")
    why = None
    if not os.path.isdir(os.path.join(ts_dir, "node_modules", "typescript")):
        why = f"it is not installed in {ts_dir}"
    else:
        payload = json.dumps({"mods": [{"files": [os.path.abspath(os.path.join(folder, f.rel)) for f in files]} for _, folder, _, files in mods if files]})
        try:
            run = subprocess.run(["node", script, ts_dir], input=payload, capture_output=True, text=True, timeout=120)
            if run.returncode != 0:
                lines = run.stderr.strip().splitlines()
                # The error itself, not the runtime's closing version line.
                why = next((l.strip() for l in lines if re.match(r"\s*(?:\w*Error\b|ts-resolve:)", l)), lines[-1] if lines else f"ts-resolve.mjs exited {run.returncode}")
            else:
                found = json.loads(run.stdout)
                # A file the resolver answered nothing for would be followed by name throughout, a
                # pass over nothing resolved (L490).
                missing = [os.path.abspath(os.path.join(folder, f.rel)) for _, folder, _, files in mods for f in files if os.path.abspath(os.path.join(folder, f.rel)) not in found]
                if missing:
                    why = f"it answered nothing for {missing[0]}" + (f" and {len(missing) - 1} other file(s)" if len(missing) > 1 else "")
        except FileNotFoundError:
            why = "node is not installed"
        except subprocess.TimeoutExpired:
            why = "it did not answer within 120 s"
        except ValueError as e:
            why = f"its answer could not be read ({e})"
    if why:
        print(
            f"check-mod-noun-waits: the pinned TypeScript compiler cannot be loaded ({why}), so no noun's calls "
            f"could be resolved and nothing was checked. Install it with: npm ci --prefix tools/typescript",
            file=sys.stderr,
        )
        sys.exit(4)
    by_path = {}
    for _, folder, _, files in mods:
        for f in files:
            by_path[os.path.abspath(os.path.join(folder, f.rel))] = f
    for _, folder, _, files in mods:
        for f in files:
            f.refs = {at: (role, target) for at, role, target in found.get(os.path.abspath(os.path.join(folder, f.rel)), [])}
    return by_path


def resolve(files, f, at, name):
    """The function the identifier name at position at in f reaches, as the compiler's checker
    resolves it (#895): (file, start, end), or None when it names a declaration, a parameter, or
    anything else that is not a function the mod declares. One the checker finds no symbol for is
    followed by name, as before."""
    role, target = f.refs.get(at, ("ref", None))
    if role == "decl":
        return None
    if target is None:
        return definition(files, name)
    if target[0] != "fn":
        return None
    return BY_PATH[target[1]], target[2], target[3]


def declared_value(f, at):
    """Where the variable the identifier at position at in f names is declared: (file, start), or None."""
    role, target = f.refs.get(at, ("ref", None))
    if target is None or target[0] not in ("fn", "value"):
        return None
    return BY_PATH[target[1]], target[2]


def constants(files):
    """Each constant the mod defines with a value on one line, by name; the first definition wins."""
    out = {}
    for f in files:
        for m in re.finditer(r"(?<![\w$.])(?:const|let|var)\s+(" + IDENT + r")\s*(?::[^=\n]+)?=(?!=)\s*([^;\n]+)", f.code):
            out.setdefault(m.group(1), m.group(2))
    return out


def milliseconds(expr, consts, depth=0):
    """A delay read as a number of milliseconds, or None when it cannot be."""
    if depth > 5:
        return None
    expr = re.sub(r"\s+as\s+const\s*$", "", expr.strip())
    expr = re.sub(r"(?<=\d)_(?=\d)", "", expr)

    def named(m):
        v = milliseconds(consts[m.group(0)], consts, depth + 1) if m.group(0) in consts else None
        if v is None:
            raise ValueError(m.group(0))
        return repr(v)

    try:
        expr = re.sub(IDENT, named, expr)
        return _number(ast.parse(expr, mode="eval").body)
    except (ValueError, SyntaxError, ZeroDivisionError):
        return None


def _number(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)) and not isinstance(node.value, bool):
        return node.value
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.USub, ast.UAdd)):
        v = _number(node.operand)
        return -v if isinstance(node.op, ast.USub) else v
    if isinstance(node, ast.BinOp):
        a, b = _number(node.left), _number(node.right)
        ops = {ast.Add: lambda: a + b, ast.Sub: lambda: a - b, ast.Mult: lambda: a * b, ast.Div: lambda: a / b, ast.FloorDiv: lambda: a // b}
        if type(node.op) in ops:
            return ops[type(node.op)]()
    raise ValueError("not a number")


def split_top(t):
    """t split on the commas standing at its own top level."""
    parts, depth, start = [], 0, 0
    for j, c in enumerate(t):
        if c in "([{<":
            depth += 1
        elif c in ")]}" or (c == ">" and t[j - 1 : j] != "="):
            depth -= 1
        elif c == "," and depth == 0:
            parts.append(t[start:j])
            start = j + 1
    parts.append(t[start:])
    return [p for p in parts if p.strip()]


def function_of(t):
    """A function's parameter names and body from its code (an arrow or a function), or None."""
    t = re.sub(r"^(?:(?:const|let|var)\s+" + IDENT + r"[^=]*=(?!=)\s*)?(?:async\s+)?", "", t.strip())
    if t.startswith("function"):
        m = re.match(r"function\s*" + r"(?:" + IDENT + r")?\s*(?:<[^()]*>)?\s*\(", t)
        if not m:
            return None
        end = closing(t, m.end() - 1)
        if end is None:
            return None
        params, rest = t[m.end() : end - 1], t[end:]
        brace = rest.find("{")
        if brace < 0:
            return None
        close = closing(rest, brace)
        return names_of(params), rest[brace + 1 : (close or len(rest)) - 1]
    if t.startswith("("):
        end = closing(t, 0)
        if end is None:
            return None
        params, rest = t[1 : end - 1], t[end:]
    else:
        m = re.match(r"(" + IDENT + r")\s*(?==>)", t)
        if not m:
            return None
        params, rest = m.group(1), t[m.end() :]
    arrow = rest.find("=>")
    if arrow < 0:
        return None
    body = rest[arrow + 2 :].strip()
    if body.startswith("{"):
        close = closing(body, 0)
        body = body[1 : (close or len(body)) - 1]
    return names_of(params), body


def names_of(params):
    out = []
    for p in split_top(params):
        m = re.match(r"\s*(?:\.\.\.)?(" + IDENT + r")", p)
        if m:
            out.append(m.group(1))
    return out


def inner_functions(body):
    """The spans of the functions written inside body: code there runs later, not as body runs."""
    spans = []
    for m in re.finditer(r"=>", body):
        k = m.end()
        while k < len(body) and body[k].isspace():
            k += 1
        if k < len(body) and body[k] == "{":
            spans.append((k, closing(body, k) or len(body)))
            continue
        depth, j = 0, k
        while j < len(body):
            c = body[j]
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if depth == 0:
                    break
                depth -= 1
            elif c in ",;" and depth == 0:
                break
            j += 1
        spans.append((k, j))
    for m in re.finditer(r"(?<![\w$])function\b", body):
        brace = body.find("{", m.end())
        if brace >= 0:
            spans.append((m.start(), closing(body, brace) or len(body)))
    return spans


def mentions(text, name):
    return re.search(r"(?<![\w$.])" + re.escape(name) + r"(?![\w$])", text) is not None


def settled_later(body, settle):
    """Whether body hands its settle functions on rather than calling them as it runs."""
    inner = inner_functions(body)
    for name in settle:
        for m in re.finditer(r"(?<![\w$.])" + re.escape(name) + r"(?![\w$])", body):
            called = re.match(r"\s*\(", body[m.end() :]) is not None
            if not called or any(a <= m.start() < b for a, b in inner):
                return True
    return False


def bounded(body, settle, consts):
    """Whether a timer under the limit, armed in body, settles the promise."""
    for m in re.finditer(r"(?<![\w$.])setTimeout\s*\(|\.\s*clock\s*\.\s*after\s*\(", body):
        end = closing(body, m.end() - 1)
        if end is None:
            continue
        args = split_top(body[m.end() : end - 1])
        if m.group(0).startswith("setTimeout"):
            callback, delay = (args[0] if args else ""), (args[1] if len(args) > 1 else "0")
        else:
            delay, callback = (args[0] if args else ""), (args[1] if len(args) > 1 else "")
        if not any(mentions(callback, n) for n in settle):
            continue
        ms = milliseconds(delay, consts)
        if ms is not None and ms < LIMIT_MS:
            return True
    return False


def judge(f, at, files, consts):
    """The finding for the `new Promise` at `at` in f, or None when it is settled in time."""
    code = f.code
    m = re.match(r"new\s+Promise\s*", code[at:])
    k = at + m.end()
    if k < len(code) and code[k] == "<":
        depth = 0
        while k < len(code):
            if code[k] == "<":
                depth += 1
            elif code[k] == ">" and code[k - 1] != "=":
                depth -= 1
                if depth == 0:
                    k += 1
                    break
            k += 1
        while k < len(code) and code[k].isspace():
            k += 1
    if k >= len(code) or code[k] != "(":
        return f"check-mod-noun-waits: {f.where(at)}: {f.mod}'s noun code makes a promise whose executor cannot be read, so whether it waits past 10 s is not known."
    end = closing(code, k)
    executor = code[k + 1 : (end or len(code)) - 1].strip()
    named = re.fullmatch(IDENT, executor)
    if named:
        raw = code[k + 1 : (end or len(code)) - 1]
        found = resolve(files, f, k + 1 + len(raw) - len(raw.lstrip()), executor)
        if not found:
            return f"check-mod-noun-waits: {f.where(at)}: {f.mod}'s noun code makes a promise whose executor {executor} cannot be found in {f.mod}, so whether it waits past 10 s cannot be read."
        df, start, stop = found
        executor = df.code[start:stop]
    fn = function_of(executor)
    if fn is None:
        return f"check-mod-noun-waits: {f.where(at)}: {f.mod}'s noun code makes a promise whose executor cannot be read, so whether it waits past 10 s is not known."
    settle, body = fn
    if not settle:
        return f"check-mod-noun-waits: {f.where(at)}: {f.mod}'s noun code waits on a promise its executor never settles. {CUT}: settle it, or bound it with a timer under 10 s."
    if not settled_later(body, settle[:2]) or bounded(body, settle[:2], consts):
        return None
    return (
        f"check-mod-noun-waits: {f.where(at)}: {f.mod}'s noun code waits on a promise settled only by a later event "
        f"(its {settle[0]} is kept, handed on or called back) with no timer under 10 s settling it. {CUT}, which "
        f"`claude plugin test` does not: answer at once, or settle it from a timer under 10 s in the same executor."
    )


def unbounded(opts, default, consts):
    """Why a call given these options may outlast a noun's 10 s, or None when a timeoutMs under it
    bounds it. Written out (`timeoutMs: 5_000`) or as a shorthand key (`{ timeoutMs }`), which reads
    the constant of that name."""
    given = re.search(r"(?<![\w$])timeoutMs\s*(?::\s*([^,}]+)|(?=\s*[,}]))", opts)
    if given:
        expr = given.group(1) if given.group(1) is not None else "timeoutMs"
        ms = milliseconds(expr, consts)
        if ms is not None and ms < LIMIT_MS:
            return None
        return (f"a timeoutMs of {int(ms):,} ms" if ms is not None
                else f"a timeoutMs ({expr.strip()}) whose value cannot be read")
    if not opts or (opts.startswith("{") and opts.endswith("}")):
        return "no timeoutMs, so " + default
    return f"options ({opts}) whose timeoutMs cannot be read"


def spans_top(code, a, b):
    """The spans of code[a:b] split on the commas standing at its own top level, blank ones left out."""
    out, depth, start = [], 0, a
    for j in range(a, b):
        c = code[j]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            out.append((start, j))
            start = j + 1
    out.append((start, b))
    return [(x, y) for x, y in out if code[x:y].strip()]


def promises_in(code, a, b):
    return [a + m.start() for m in re.finditer(r"(?<![\w$.])new\s+Promise\b", code[a:b])]


def call_args(code, open_at):
    """The argument texts of the call whose ( is at open_at, or None when it never closes."""
    end = closing(code, open_at)
    if end is None:
        return None
    return [code[x:y].strip() for x, y in spans_top(code, open_at + 1, end - 1)]


def with_args(consts, params, args):
    """consts with each of a function's parameters bound to the argument a call passes it."""
    out = dict(consts)
    for name, arg in zip(params, args):
        out[name] = arg
    return out


def helper_timer(files, f, at, name, args, consts):
    """Whether the call of the mod's function name at position at in f, with args, makes a promise a
    timer under 10 s settles."""
    found = resolve(files, f, at, name)
    if not found:
        return False
    df, start, stop = found
    fn = function_of(df.code[start:stop])
    if fn is None:
        return False
    bound = with_args(consts, fn[0], args)
    inside = promises_in(df.code, start, stop)
    return bool(inside) and all(judge(df, at, files, bound) is None for at in inside)


def is_timer(f, a, b, files, consts):
    """Whether the race member f.code[a:b] is a promise settled under 10 s."""
    text = f.code[a:b]
    lead = len(text) - len(text.lstrip())
    expr = text.strip()
    if re.match(r"new\s+Promise\b", expr):
        return judge(f, a + lead, files, consts) is None
    m = re.fullmatch(r"(" + IDENT + r")\s*\(", expr[: expr.find("(") + 1]) if "(" in expr else None
    if m and expr.endswith(")"):
        args = call_args(f.code, a + lead + expr.find("("))
        return args is not None and m.group(1) not in KEYWORDS and helper_timer(files, f, a + lead, m.group(1), args, consts)
    if re.fullmatch(IDENT, expr):
        # The variable this member reads, as the compiler resolves it (#895).
        seen = declared_value(f, a + lead)
        if seen:
            g, d = seen
            made = re.match(r"(?:const|let|var)\s+" + re.escape(expr) + r"\s*(?::[^=\n]+)?=(?!=)\s*(?=new\s+Promise\b)", g.code[d:])
            if made:
                return judge(g, d + made.end(), files, consts) is None
    return False


def stored_in(code, at):
    """The name a promise made at at is kept under: a variable it is assigned to, or the map or list
    it is put in through .set, .push, .unshift or .add, or None."""
    line = code[code.rfind("\n", 0, at) + 1 : at]
    m = re.search(r"(?<![\w$.])(" + IDENT + r")\s*\.\s*(?:set|push|unshift|add)\s*\([^()]*$", line)
    if m:
        return m.group(1)
    m = re.search(r"(?<![\w$.])(" + IDENT + r")\s*(?::[^=;]*)?(?<![=!<>])=\s*$", line)
    return m.group(1) if m and m.group(1) not in KEYWORDS else None


BY_PATH = resolve_all(mods)
for entry, folder, man, files in mods:
    consts = constants(files)
    # The noun code: the engine.create hooks and hooks on a noun's event, then every function of the
    # mod they call, by name, until none is new.
    todo, seen = [], set()
    for f in files:
        for start, end in hooks_on(f, lambda ev: ev == "engine.create" or ev.split(".")[0] in nouns and "." in ev):
            if end is None:
                report(f"check-mod-noun-waits: {f.where(start)}: {entry}'s hook there never closes its brackets, so its noun code cannot be read.")
                continue
            todo.append((f, start, end, None))
            handler = re.search(r",\s*(" + IDENT + r")\s*\)$", f.code[start:end])
            if handler:
                found = resolve(files, f, start + handler.start(1), handler.group(1))
                if found:
                    todo.append((*found, handler.group(1)))
    regions = []
    while todo:
        f, start, end, name = todo.pop()
        if (f.rel, start, end) in seen:
            continue
        seen.add((f.rel, start, end))
        regions.append((f, start, end, name))
        for m in re.finditer(r"(?<![\w$.])(" + IDENT + r")\s*(?:<[^<>()]*>)?\s*\(", f.code[start:end]):
            if m.group(1) not in KEYWORDS:
                found = resolve(files, f, start + m.start(), m.group(1))
                if found:
                    todo.append((*found, m.group(1)))

    # Each member of a Promise.race a noun's code writes, raced against a timer under 10 s (the limit
    # measured on 2026-10-05).
    raced = []
    for f, start, end, _ in regions:
        for m in re.finditer(r"(?<![\w$.])Promise\s*\.\s*race\s*\(\s*\[", f.code[start:end]):
            open_at = start + m.end() - 1
            close = closing(f.code, open_at)
            if close is None:
                continue
            members = spans_top(f.code, open_at + 1, close - 1)
            timers = [x for x in members if is_timer(f, x[0], x[1], files, consts)]
            if timers:
                raced += [(f.rel, x[0], x[1]) for x in members if x not in timers]

    def is_raced(f, at):
        return any(rel == f.rel and a <= at < b for rel, a, b in raced)

    def mentions_in_nouns(name):
        """Each place a noun's code reads name: (file, position). A key of an object written in place
        (`{ held: ... }`, a method named like the store) reads nothing."""
        out = []
        for f, start, end, _ in regions:
            for m in re.finditer(r"(?<![\w$.])" + re.escape(name) + r"(?![\w$])", f.code[start:end]):
                before = f.code[start : start + m.start()].rstrip()
                if re.match(r"\s*\??:(?!:)", f.code[start + m.end() : end]) and (not before or before[-1] in "{,"):
                    continue
                out.append((f, start + m.start()))
        return out

    def calls_in_nouns(df, dstart, name):
        """Each call a noun's code makes of the mod's function name declared at dstart in df: (file,
        position, its arguments). A call the compiler resolves to another function of that name, and
        a declaration of one, are not calls of this one (#895)."""
        out = []
        for f, start, end, own in regions:
            if own == name and f is df and start == dstart:
                continue
            for m in re.finditer(r"(?<![\w$.])" + re.escape(name) + r"\s*(?:<[^<>()]*>)?\s*\(", f.code[start:end]):
                reached = resolve(files, f, start + m.start(), name)
                if not reached or reached[0] is not df or reached[1] != dstart:
                    continue
                args = call_args(f.code, start + m.end() - 1)
                out.append((f, start + m.start(), args or []))
        return out

    judged = set()
    for f, start, end, name in regions:
        for at in promises_in(f.code, start, end):
            if (f.rel, at) in judged:
                continue
            # A promise inside a helper written within this region is judged as that helper's, by
            # the calls reaching it, never by this outer one's (#895).
            if any(g is f and start <= a and b <= end and (a, b) != (start, end) and a <= at < b for g, a, b, _ in regions):
                continue
            judged.add((f.rel, at))
            if is_raced(f, at):
                continue
            calls = calls_in_nouns(f, start, name) if name else []
            fn = function_of(f.code[start:end]) if calls else None
            if calls and fn is not None:
                # A helper: judged at each call a noun makes, with that call's arguments, and a call
                # the noun races against a short timer is bounded by the race.
                bad = [judge(f, at, files, with_args(consts, fn[0], args)) for g, pos, args in calls if not is_raced(g, pos)]
                finding = next((x for x in bad if x), None)
            else:
                finding = judge(f, at, files, consts)
            if finding:
                report(finding)

    # A promise made outside every noun's code and kept where a noun reads it (#756).
    for f in files:
        for at in promises_in(f.code, 0, len(f.code)):
            if any(g.rel == f.rel and a <= at < b for g, a, b, _ in regions):
                continue
            kept = stored_in(f.code, at)
            if not kept:
                continue
            reads = [(g, pos) for g, pos in mentions_in_nouns(kept) if not is_raced(g, pos)]
            if not reads:
                continue
            finding = judge(f, at, files, consts)
            if finding:
                g, pos = reads[0]
                why = finding.split(": ", 2)[2]
                report(
                    f"check-mod-noun-waits: {f.where(at)}: {entry} makes a promise here, outside its nouns' code, kept in "
                    f"{kept}, which a noun returns (read at {g.where(pos)}). {why}"
                )

    for f, start, end, _ in regions:
        for m in re.finditer(r"\.\s*ui\s*\.\s*ask\s*\(", f.code[start:end]):
            at = start + m.start()
            if (f.rel, at) in judged:
                continue
            judged.add((f.rel, at))
            report(
                f"check-mod-noun-waits: {f.where(at)}: {entry}'s noun code waits on a person through $.ui.ask, whose answer has "
                f"no bound under 10 s. {CUT}: ask from a hook, whose $ calls do not spend its budget, never from a noun."
            )

    # A noun's own slow engine calls (#802). Its 10 s is not paused while its $ calls run (measured
    # live on 2026-10-05, above), so a process.run that may take longer than that is cut the same
    # way: one with no timeoutMs waits up to Claude Code's default of 30 s, and one whose timeoutMs
    # cannot be read is not known to be bounded. A model.complete is judged the same way, with no
    # bound of its own when it names none.
    # A call the noun races against a short timer is bounded by the race, as above.
    for f, start, end, _ in regions:
        for m in re.finditer(r"\.\s*process\s*\.\s*run\s*\(", f.code[start:end]):
            at = start + m.start()
            if (f.rel, at) in judged or is_raced(f, at):
                continue
            judged.add((f.rel, at))
            args = call_args(f.code, start + m.end() - 1) or []
            why = unbounded(args[1].strip() if len(args) > 1 else "", "Claude Code's default of 30 s", consts)
            if why is None:
                continue
            report(
                f"check-mod-noun-waits: {f.where(at)}: {entry}'s noun code waits on $.process.run with {why}, and "
                f"the noun's 10 s keeps running while it does. {CUT}: give it a timeoutMs under 10 s, race it "
                f"against a shorter timer, or run it from a hook."
            )
        for m in re.finditer(r"\.\s*model\s*\.\s*complete\s*\(", f.code[start:end]):
            at = start + m.start()
            if (f.rel, at) in judged or is_raced(f, at):
                continue
            judged.add((f.rel, at))
            # Judged like process.run, by the timeoutMs in its request (lessons review of #802).
            args = call_args(f.code, start + m.end() - 1) or []
            why = unbounded(args[0].strip() if args else "", "no bound of its own: a completion can take a minute", consts)
            if why is None:
                continue
            report(
                f"check-mod-noun-waits: {f.where(at)}: {entry}'s noun code waits on $.model.complete with {why}, "
                f"and the noun's 10 s keeps running while it does. {CUT}: give it a timeoutMs under 10 s, race "
                f"it against a shorter timer, or call the model from a hook."
            )

for line in sorted(set(reports)):
    print(line)
print(f"check-mod-noun-waits: {len(mods)} mods checked in {root}")
sys.exit(failed)
PY
