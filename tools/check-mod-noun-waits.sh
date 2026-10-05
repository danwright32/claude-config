#!/bin/bash
# check-mod-noun-waits.sh <mods dir>: no mod's own $ noun waits on a person, or on anything else with
# no bound under 10 seconds (#744). Claude Code cuts a call to a plugin's noun off at 10 s: measured
# live on 2.1.289, `$.probe.wait` was rejected at 10,003 ms with "did not answer within 10000ms".
# `claude plugin test` does not apply that limit, so such a noun passes every test of its own and
# fails only in a session. Picker manners' `$.pickers.wait` did exactly that: its tool.call hook
# waited through it for a press in the band, the wait was rejected at 10 s, and Claude Code's own
# dialog then asked every question a second time.
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
# A noun's code is each `engine.create` hook's (where the nouns' methods are written), each hook on
# a noun's own event (`on('modkit.screen', ...)`, any noun any mod's contract declares on $), and
# every function of the mod those call, followed by name through every source file of the mod.
#
# What it does not read: a promise made outside a noun's code and handed to it later, a race against
# a timer made in another executor, and how long an engine `$` call other than `$.ui.ask` takes.
# A hook has its own 10 s budget, which `$` calls do not spend; that is not this check's to judge.
#
# Source is read through tools/lib/ts_source.py, the one reader every mod scan shares, so a comment
# or a string naming the shape is never taken for code.
#
# Exit codes, each distinct (L11): 0 none found (the count of mods is printed, L98), 1 a wait found
# or a noun's code that cannot be read, each named with its file and line, 2 the mods folder does
# not exist, 3 no python3 to read the source with (L490: never a pass over nothing read).
dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  echo "check-mod-noun-waits: '${dir:-<none given>}' is not a folder, so nothing was checked." >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "check-mod-noun-waits: python3 is not installed, so no mod's source was read." >&2
  exit 3
fi
python3 - "${dir%/}" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib" <<'PY'
import ast, json, os, re, sys

root = sys.argv[1]
sys.path.insert(0, sys.argv[2])
from ts_source import CODE, _definition, block_after, closing, code_only, is_jsx, kinds, top_members

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
    pattern = r"\b(?:const|let|var)\s+" + re.escape(name) + r"\b[^=]*=(?!=)|\bfunction\s+" + re.escape(name) + r"\b"
    for f in files:
        found = _definition(f.code, name, f.kinds)
        if found:
            start = re.search(pattern, f.code).start()
            return f, start, start + len(found)
    return None


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
        found = definition(files, executor)
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
            todo.append((f, start, end))
            handler = re.search(r",\s*(" + IDENT + r")\s*\)$", f.code[start:end])
            if handler:
                found = definition(files, handler.group(1))
                if found:
                    todo.append(found)
    regions = []
    while todo:
        f, start, end = todo.pop()
        if (f.rel, start, end) in seen:
            continue
        seen.add((f.rel, start, end))
        regions.append((f, start, end))
        for m in re.finditer(r"(?<![\w$.])(" + IDENT + r")\s*(?:<[^<>()]*>)?\s*\(", f.code[start:end]):
            if m.group(1) not in KEYWORDS:
                found = definition(files, m.group(1))
                if found:
                    todo.append(found)
    judged = set()
    for f, start, end in regions:
        for m in re.finditer(r"(?<![\w$.])new\s+Promise\b", f.code[start:end]):
            at = start + m.start()
            if (f.rel, at) in judged:
                continue
            judged.add((f.rel, at))
            finding = judge(f, at, files, consts)
            if finding:
                report(finding)
        for m in re.finditer(r"\.\s*ui\s*\.\s*ask\s*\(", f.code[start:end]):
            at = start + m.start()
            if (f.rel, at) in judged:
                continue
            judged.add((f.rel, at))
            report(
                f"check-mod-noun-waits: {f.where(at)}: {entry}'s noun code waits on a person through $.ui.ask, whose answer has "
                f"no bound under 10 s. {CUT}: ask from a hook, whose $ calls do not spend its budget, never from a noun."
            )

for line in sorted(set(reports)):
    print(line)
print(f"check-mod-noun-waits: {len(mods)} mods checked in {root}")
sys.exit(failed)
PY
