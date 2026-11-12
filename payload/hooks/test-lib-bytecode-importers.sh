#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans hooks/ skills/ mods/ commands/ agents/
# Every program that imports a module from payload/hooks/lib turns bytecode off first (#2600).
#
# THE FAULT. Python caches what it imports in a __pycache__ folder beside the module, unless told not
# to. A program that imports from lib/ with bytecode on leaves lib/__pycache__/<module>.pyc behind,
# and test-work-names.sh's #2444 check fails on any lib bytecode that appears while it runs. CI runs
# a part's suites in parallel, so the suite that fails is whichever runs beside the program, on a
# pull request that touched neither (#2600: lib/bundle-budget.py and scan-absence-needles.py, both
# importing ratchet). The class was fixed one importer at a time before: #2076, #2345, #2353, #2444.
#
# THE RULE. A program that imports from lib/ sets `sys.dont_write_bytecode = True` before the import:
#   a .py file, always in its own text. Its callers are not counted, even where every caller today
#     passes -B: a new caller would not, and check-bundle-budget.sh runs bundle-budget.py as plain
#     python3, which is how #2600 happened.
#   a python3 -c program or a heredoc fed to python3 in a shell file, in its text, or on the
#     invocation itself: `python3 -B`, or PYTHONDONTWRITEBYTECODE set on the same command. The
#     flag is part of that one run and cannot come apart from it.
#
# THE SHAPES an import from lib/ takes, each read here (the list measured on 2026-11-10 is in the PR):
#   1. by name: `import ratchet`, `from shell_code_lines import ...`, for any module lib/ holds whose
#      file name is a Python name, reached by a sys.path insert, PYTHONPATH, or being run from lib/
#      itself (python3 puts the script's own folder first). A module of the same name beside a
#      program outside lib/ is that program's own, not lib's.
#   2. by path: spec_from_file_location, SourceFileLoader, run_path or import_module, in a program
#      whose string literals (or, for a shell program, its command line) name a file in lib/ or a lib
#      folder. A variable on a shell command line is read through the file's own assignments to it
#      (#2751: tests/test-work-names-tree.sh loaded lib/work-names.py as "$SCAN" with -I and no -B).
#   The runner and arming hand every suite PYTHONDONTWRITEBYTECODE=1 as well (#2751), but -I and -E
#   drop it, so this rule still asks for the setting on the command or in the program itself.
# A setting counts for a load only when it comes first in that load's own function or a scope around
# it, and every load is judged, not only the first (#2840: tools/review-score.py set it inside one
# function and loaded review-answered.py in another, run as the file is imported).
# A python3 -c whose program is a shell variable alone (`python3 -I -c "$agree_prog"`) is read
# through what the file sets it to: a heredoc read into it, or a quoted assignment (#2840:
# tools/test-review-score.sh ran such a program with -I and no -B, and it loaded review-answered.py).
# NOT READ: a variable set any other way (from a file, a command's output, or another variable); a
# heredoc piped into python3 from another command (`cat <<EOF | python3`) and a here string, neither
# used anywhere on 2026-11-10; programs in files that are not Python or shell (a Markdown example, a
# TypeScript test's strings), which never run as written.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The checkout this copy is the payload of, found by the one shared test (lib/checkout-root.sh).
ROOT="${LIB_BYTECODE_ROOT:-$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  printf 'SUITE-NOT-RUN %s\n' "needs the repository to read its files, and $DIR/.. is not the payload of a claude-config checkout"
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'SUITE-NOT-RUN %s\n' "the scan is a python3 program, and python3 is not on PATH"
  exit 2
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/lib-bytecode.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-lib-bytecode-importers: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# scan.py <root> <list file> [--list]: for each path in the list, relative to root, prints
#   HIT <path>:<line>: ...         for each program importing from lib/ with bytecode on
#   IMPORTER <path>:<line> ...     with --list, for every program importing from lib/, and how it
#                                  turns bytecode off
# and last, always, READ files=<n> programs=<n> importers=<n>. The lib/ judged is <root>'s own.
cat > "$TMPROOT/scan.py" <<'PY'
import io
import os
import re
import sys
import tokenize

root, listing = sys.argv[1], sys.argv[2]
show = "--list" in sys.argv[3:]
# The one reader of python3 -c programs (#2066) and the one reader of shell quoting and heredocs
# (#1663), both from the lib/ of the checkout this suite belongs to.
sys.path.insert(0, os.environ["LIB_BYTECODE_READERS"])
from python_c_programs import programs as c_programs, word as shell_word
from shell_code_lines import read_lines

LIB_REL = os.path.join("payload", "hooks", "lib")
LIB = os.path.join(root, LIB_REL)
LIB_FILES = sorted(f for f in os.listdir(LIB) if f.endswith(".py"))
LIB_NAMES = {f[:-3] for f in LIB_FILES if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*\.py", f)}
IMPORT = re.compile(r"^\s*(?:import\s+([A-Za-z_][\w.]*(?:\s+as\s+\w+)?(?:\s*,\s*[A-Za-z_][\w.]*(?:\s+as\s+\w+)?)*)|from\s+([A-Za-z_]\w*)\s+import\b)")
LOAD = re.compile(r"\b(spec_from_file_location|SourceFileLoader|run_path|import_module)\s*\(")
OFF = re.compile(r"\bsys\.dont_write_bytecode\s*=\s*True\b")
# A lib folder or a file in it, named in a string or on a command line.
LIB_WORD = re.compile(r"(?<![\w.-])lib(?![\w-])")
SKIP = (tokenize.COMMENT, tokenize.NL, tokenize.NEWLINE, tokenize.INDENT, tokenize.DEDENT, tokenize.ENCODING)
STRINGS = {tokenize.STRING} | {getattr(tokenize, n) for n in ("FSTRING_MIDDLE",) if hasattr(tokenize, n)}


# The name a load gives a lib file's module, quoted whole: "shell_words" for lib/shell-words.py. A
# loader handed the path in a variable (PS_SHELL_WORDS in lib/push-scope.sh) still names the module.
LIB_STEMS = {f[:-3] for f in LIB_FILES} | {f[:-3].replace("-", "_") for f in LIB_FILES}
QUOTED_STEM = re.compile(r"""^[rbuRBU]?(['"])(%s)\1$""" % "|".join(re.escape(s) for s in sorted(LIB_STEMS)))


def names_lib(text):
    return any(f in text for f in LIB_FILES) or bool(LIB_WORD.search(text)) or bool(QUOTED_STEM.match(text))


def code_of(src):
    """The program's lines with comments and string contents blanked, and its string literals other
    than docstrings, so an import or a load named in prose is never read as one."""
    lines = src.split("\n")
    out = [list(l) for l in lines]
    literals = []
    try:
        toks = list(tokenize.generate_tokens(io.StringIO(src).readline))
    except (tokenize.TokenError, SyntaxError, IndentationError):
        return lines, [src]   # unreadable: judged on its raw text, which can only find more
    prev = None
    for i, t in enumerate(toks):
        if t.type == tokenize.COMMENT or t.type in STRINGS:
            if t.type in STRINGS:
                nxt = next((u for u in toks[i + 1:] if u.type not in (tokenize.COMMENT, tokenize.NL)), None)
                doc = t.type == tokenize.STRING and (prev is None or prev.type in SKIP) \
                    and (nxt is None or nxt.type in (tokenize.NEWLINE, tokenize.ENDMARKER))
                if not doc:
                    literals.append(t.string)
            (sr, sc), (er, ec) = t.start, t.end
            for r in range(sr, er + 1):
                row = out[r - 1] if r - 1 < len(out) else []
                a = sc if r == sr else 0
                b = ec if r == er else len(row)
                for k in range(a, min(b, len(row))):
                    row[k] = " "
        if t.type not in SKIP:
            prev = t
    return ["".join(r) for r in out], literals


DEF = re.compile(r"^([ \t]*)(?:async[ \t]+)?def\b")


def scopes(code):
    """For each line of the program (comments and strings blanked), the functions it sits in, as
    the tuple of their def lines, outermost first. A line inside brackets opened on an earlier line
    is read in the scope that statement started in."""
    out, stack, depth, here = [], [], 0, ()
    for n, line in enumerate(code, 1):
        if depth == 0 and line.strip():
            indent = len(line) - len(line.lstrip())
            while stack and stack[-1][0] >= indent:
                stack.pop()
            here = tuple(d for _, d in stack)
            m = DEF.match(line)
            if m:
                stack.append((len(m.group(1)), n))
        out.append(here)
        depth = max(0, depth + sum(line.count(c) for c in "([{") - sum(line.count(c) for c in ")]}"))
    return out


def judge(src, own_dir, extra=""):
    """(where it first loads from lib, what it loads, where it first turns bytecode off, the first
    load no setting covers, every setting) for one program, each place a (line, column), or None
    when it loads nothing from lib. `extra` is its command line, for a shell one.

    A setting covers a load only when it comes first in the load's own function or in a scope
    around it (#2840): tools/review-score.py set it inside the function loading the runner, and
    loaded review-answered.py further down, in another function called as the file is imported.
    Read as "a setting's line comes first", that passed, and the load wrote bytecode."""
    code, literals = code_of(src)
    scope = scopes(code)
    loads, what = [], []
    for n, line in enumerate(code, 1):
        # A one line program puts several statements on a line, so each is read on its own.
        col = 0
        for stmt in line.split(";"):
            m = IMPORT.match(stmt)
            if m:
                mods = [p.split()[0].split(".")[0] for p in m.group(1).split(",")] if m.group(1) else [m.group(2)]
                for mod in mods:
                    own = own_dir and os.path.normcase(own_dir) != os.path.normcase(LIB) \
                        and os.path.exists(os.path.join(own_dir, mod + ".py"))
                    if mod in LIB_NAMES and not own:
                        loads.append((n, col))
                        what.append(mod)
            col += len(stmt) + 1
    # By path: which file a load reaches is often a variable or an argument, so a load counts in any
    # program that names lib/ or a file in it, and the finding says only that (L11). Every load is
    # judged, not only the first: a setting covering one can sit where it misses the next.
    if any(names_lib(s) for s in literals) or names_lib(extra):
        for n, line in enumerate(code, 1):
            for m in LOAD.finditer(line):
                loads.append((n, m.start()))
                what.append("code by path (%s) in a program naming lib/" % m.group(1))
    if not loads:
        return None
    loads.sort()
    offs = [(n, m.start()) for n, line in enumerate(code, 1) for m in OFF.finditer(line)]

    def covers(off, at):
        outer = scope[off[0] - 1]
        return off < at and scope[at[0] - 1][:len(outer)] == outer

    bare = next((at for at in loads if not any(covers(o, at) for o in offs)), None)
    return loads[0], sorted(set(what)), (offs[0] if offs else None), bare, offs


C_HEAD = re.compile(r"python3?((?:[ \t]+-[A-Za-z]+)*?)[ \t]+(-[A-Za-z]*c)[ \t]+$")
ENV_OFF = re.compile(r"(?<![\w-])PYTHONDONTWRITEBYTECODE=(?:[^\s;|&'\"]|'[^']+'|\"[^\"]+\")")
H_CALL = re.compile(r"(?<![A-Za-z0-9_./-])python3?((?:[ \t]+-[A-Za-z]+)*)(?=[ \t]|$)([^<]*)<<")
# A shell variable on the command line is read through the file's own assignments to it (#2751):
# tests/test-work-names-tree.sh loaded lib/work-names.py as "$SCAN", assigned at its top, so its
# command line alone named no lib file and the load was never judged. Every value the file ever
# gives the name counts, and a value naming another variable is followed a few levels.
ASSIGN = re.compile(r"^[ \t]*(?:(?:export|local|readonly|declare(?:[ \t]+-\w+)*)[ \t]+)?([A-Za-z_]\w*)=(.*)$", re.M)
VAR_REF = re.compile(r"\$\{?([A-Za-z_]\w*)")


def assignments(text):
    out = {}
    for m in ASSIGN.finditer(text):
        out.setdefault(m.group(1), []).append(m.group(2))
    return out


def expand(words, assigned):
    """The command line, followed by every value assigned to each variable it names."""
    out, todo, seen = [words], set(VAR_REF.findall(words)), set()
    for _ in range(3):
        nxt = set()
        for name in todo - seen:
            seen.add(name)
            for value in assigned.get(name, ()):
                out.append(value)
                nxt |= set(VAR_REF.findall(value))
        todo = nxt
    return " ".join(out)


# A python3 -c whose program is a variable alone: `python3 -I -c "$agree_prog"`.
HELD_REF = re.compile(rb"^\$\{?([A-Za-z_]\w*)\}?$")
# A heredoc read into a variable: `IFS= read -r -d '' agree_prog <<'PY'`.
READ_INTO = re.compile(r"\bread\b[^<|;&]*?\b([A-Za-z_]\w*)[ \t]*<<")
ASSIGN_B = re.compile(rb"^[ \t]*(?:(?:export|local|readonly|declare(?:[ \t]+-\w+)*)[ \t]+)?([A-Za-z_]\w*)=", re.M)


def held_programs(b, rows):
    """Every value the shell file gives each variable, as {name: [(program, line it is set on, line
    the program's first line is on)]}: a heredoc read into it, and a quoted assignment (BUDGET_PY='...'
    in test-work-names.sh)."""
    out = {}
    for i, (n, line, kind, _, ops) in enumerate(rows):
        if kind != "code" or not ops:
            continue
        m = READ_INTO.search(line)
        if not m:
            continue
        body = []
        for _, bl, bk, _, _ in rows[i + 1:]:
            if bk != "heredoc":
                break
            body.append(bl)
        out.setdefault(m.group(1), []).append(("\n".join(body), n, n + 1))
    for m in ASSIGN_B.finditer(b):
        if b[m.end():m.end() + 1] not in (b"'", b'"'):
            continue
        value, _ = shell_word(b, m.end())
        if value is not None and not value.startswith(b"$"):
            n = b.count(b"\n", 0, m.start()) + 1
            out.setdefault(m.group(1).decode(), []).append((value.decode("utf-8", "replace"), n, n))
    return out


def is_shell(rel, b):
    if rel.endswith((".sh", ".bash")):
        return True
    if "." in os.path.basename(rel):
        return False
    first = b.split(b"\n", 1)[0]
    return first.startswith(b"#!") and re.search(rb"\b(ba|z)?sh\b", first) is not None


files = progs = importers = 0
with open(listing, "rb") as f:
    paths = [p.decode("utf-8", "replace") for p in f.read().split(b"\n") if p]


def report(rel, line, shape, res, how, at=None):
    """`at`, when given, is the line the finding names: where a program held in a variable runs,
    rather than where in the variable it loads."""
    global importers
    first, what, off_at, bare, offs = res
    importers += 1
    ok = how or bare is None
    where = at if at is not None else line + (bare or first)[0] - 1
    if show:
        print("IMPORTER %s:%d %s loads %s, bytecode off by %s" % (
            rel, where, shape, ", ".join(what),
            how or ("sys.dont_write_bytecode on line %d" % (line + off_at[0] - 1) if ok else "nothing before the import")))
    if not ok:
        fix = "set sys.dont_write_bytecode = True before it" if shape == "the file" \
            else "pass -B to python3, or set sys.dont_write_bytecode = True before it"
        earlier = [o for o in offs if o < bare]
        late = " (it is set on line %d, inside a function this load is not in)" % (line + earlier[0][0] - 1) if earlier \
            else " (it is set on line %d, after the import)" % (line + off_at[0] - 1) if off_at else ""
        print("HIT %s:%d: %s loads %s with bytecode on, which can leave payload/hooks/lib/__pycache__ "
              "behind%s; %s" % (rel, where, shape, ", ".join(what), late, fix))


for rel in paths:
    p = os.path.join(root, rel)
    try:
        with open(p, "rb") as f:
            b = f.read()
    except OSError:
        continue
    if b"\0" in b:
        continue
    files += 1
    if rel.endswith(".py"):
        progs += 1
        res = judge(b.decode("utf-8", "replace"), os.path.dirname(p))
        if res:
            report(rel, 1, "the file", res, None)
        continue
    if b"python" not in b or not is_shell(rel, b):
        continue
    text = b.decode("utf-8", "replace")
    assigned = assignments(text)
    rows = list(read_lines(text))
    held = None
    for line, start, end, prog in c_programs(b):
        if prog is None:
            continue
        ref = HELD_REF.match(prog)
        if ref:
            # A program held in a variable is read where the file sets it (#2840).
            held = held_programs(b, rows) if held is None else held
            bodies = held.get(ref.group(1).decode(), [])
        else:
            bodies = [(prog.decode("utf-8", "replace"), None, line)]
        ls = b.rfind(b"\n", 0, start) + 1
        head = b[ls:start].decode("utf-8", "replace")
        le = end
        while True:
            nl = b.find(b"\n", le)
            if nl < 0:
                le = len(b)
                break
            le = nl + 1
            if not b[:nl].rstrip(b" \t").endswith(b"\\"):
                break
        tail = b[end:le].decode("utf-8", "replace")
        m = C_HEAD.search(head)
        flags = (m.group(1) + " " + m.group(2)) if m else ""
        how = "python3 -B" if re.search(r"-[A-Za-z]*B", flags) else \
            ("PYTHONDONTWRITEBYTECODE" if ENV_OFF.search(head) else None)
        for body, set_on, starts in bodies:
            progs += 1
            res = judge(body, None, expand(tail, assigned))
            if not res:
                continue
            if set_on is None:
                report(rel, line, "the python3 -c program", res, how)
            else:
                # Lines inside the program count from where it starts; the finding names the run.
                report(rel, starts, "the python3 -c program held in $%s (set on line %d)" % (ref.group(1).decode(), set_on),
                       res, how, at=line)
    for i, (n, line, kind, bare, ops) in enumerate(rows):
        if kind != "code" or not ops:
            continue
        m = H_CALL.search(line)
        if not m:
            continue
        body = []
        for _, bl, bk, _, _ in rows[i + 1:]:
            if bk != "heredoc":
                break
            body.append(bl)
        progs += 1
        res = judge("\n".join(body), None, expand(m.group(2), assigned))
        if not res:
            continue
        how = "python3 -B" if re.search(r"-[A-Za-z]*B", m.group(1)) else \
            ("PYTHONDONTWRITEBYTECODE" if ENV_OFF.search(line[:m.start()]) else None)
        report(rel, n + 1, "the heredoc fed to python3", res, how)
print("READ files=%d programs=%d importers=%d" % (files, progs, importers))
PY

scan() { LIB_BYTECODE_READERS="$DIR/lib" python3 -I -B "$TMPROOT/scan.py" "$@" 2>&1; }

# ---------------------------------------------------------------------------
# The scan has to find each shape an import from lib/ takes, and pass each way of turning bytecode
# off, before the tree is asked (L1). The probe tree has its own payload/hooks/lib, so what counts
# as a lib module is read from the probe, as it is from the checkout. The interpreter's name is
# held in a variable so this file's own text is not a program the tree scan below reads.
# ---------------------------------------------------------------------------
PROBE="$TMPROOT/probe"
mkdir -p "$PROBE/payload/hooks/lib" "$PROBE/payload/skills/own"
: > "$PROBE/payload/hooks/lib/ratchet.py"
: > "$PROBE/payload/hooks/lib/shell-words.py"
: > "$PROBE/payload/skills/own/ratchet.py"
P=python3
# Python files.
printf 'import os, sys\nsys.path.insert(0, os.path.dirname(__file__) + "/lib")\nimport ratchet\n' > "$PROBE/payload/hooks/by-name.py"
printf 'import sys\nimport ratchet\nsys.dont_write_bytecode = True\n' > "$PROBE/payload/hooks/late.py"
printf 'import sys\nsys.dont_write_bytecode = True\nfrom ratchet import read\n' > "$PROBE/payload/hooks/early.py"
printf 'import importlib.util, os\ns = importlib.util.spec_from_file_location("w", os.path.join(os.path.dirname(__file__), "lib", "shell-words.py"))\n' > "$PROBE/payload/hooks/by-path.py"
printf '"""Says import ratchet in prose,\nimport ratchet\nand spec_from_file_location("x", "lib/shell-words.py")."""\n# import ratchet\nx = 1\n' > "$PROBE/payload/hooks/prose.py"
printf 'import json\nimport ratchet\n' > "$PROBE/payload/skills/own/local.py"
printf 'def f():\n    import ratchet\n' > "$PROBE/payload/hooks/lib/sibling.py"
printf 'import importlib.util\ns = importlib.util.spec_from_file_location("g", "gh_issue_scan.py")\n' > "$PROBE/payload/hooks/not-lib.py"
# #2840: tools/review-score.py set the setting inside the function that loads the runner, and
# loaded review-answered.py further down, inside another function called as the file is imported.
# Read as "the setting's line comes first" it passed, and the second load wrote bytecode.
# A setting covers a load only when it comes first in the load's own function or a scope around it.
{
  printf 'import importlib.util, os, sys\n'
  printf 'def runner():\n'
  printf '    sys.dont_write_bytecode = True\n'
  printf '    return importlib.util.spec_from_file_location("r", os.path.join(os.path.dirname(__file__), "lib", "shell-words.py"))\n'
  printf 'def answered():\n'
  printf '    return importlib.util.spec_from_file_location("a", os.path.join(os.path.dirname(__file__), "lib", "shell-words.py"))\n'
  printf 'A = answered()\n'
} > "$PROBE/payload/hooks/scoped.py"
{
  printf 'import importlib.util, os, sys\n'
  printf 'sys.dont_write_bytecode = True\n'
  printf 'def answered():\n'
  printf '    return importlib.util.spec_from_file_location("a", os.path.join(os.path.dirname(__file__), "lib", "shell-words.py"))\n'
  printf 'A = answered()\n'
} > "$PROBE/payload/hooks/scoped-ok.py"
# Shell programs.
{
  printf '#!/usr/bin/env bash\n'
  printf "$P -c 'import sys; sys.path.insert(0, sys.argv[1]); import ratchet' \"\$D/lib\"\n"                         # 2: by name
  printf "$P -B -c 'import ratchet'\n"                                                                              # 3: -B
  printf "PYTHONDONTWRITEBYTECODE=1 $P -c 'import ratchet'\n"                                                     # 4: env
  printf "$P -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location(\"w\", sys.argv[1])' \"\$D/lib/shell-words.py\"\n"  # 5: by path
  printf "$P -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location(\"f\", sys.argv[1])' \"\$D/filed_issue_session.py\"\n"  # 6: not lib
  printf "$P - \"\$D/lib\" <<'EOF'\nimport sys\nsys.path.insert(0, sys.argv[1])\nimport ratchet\nEOF\n"              # 7 to 11: heredoc
  printf "$P -B - <<'EOF'\nimport ratchet\nEOF\n"                                                                 # 12 to 14: heredoc, -B
  printf "x=\"\$($P -IBc 'import ratchet')\"\n"                                                                   # 15: a cluster
  printf "$P -c 'import sys; sys.dont_write_bytecode = True; import ratchet'\n"                                   # 16: in the text
  printf "env -u PYTHONDONTWRITEBYTECODE $P -c 'import ratchet'\n"                                                # 17: cleared
  printf "W=\"\$SW\" $P -c 'import importlib.util,os; s=importlib.util.spec_from_file_location(\"shell_words\", os.environ[\"W\"])'\n"     # 18: path in a variable
  printf "W=\"\$SW\" $P -B -c 'import importlib.util,os; s=importlib.util.spec_from_file_location(\"shell_words\", os.environ[\"W\"])'\n"  # 19: the same, -B
  # #2751: the file to load named by a shell variable assigned elsewhere in the file, the shape of
  # tests/test-work-names-tree.sh's SCAN, and run with -I, which drops any PYTHONDONTWRITEBYTECODE
  # the runner or arming hands down, so only -B on the command itself turns bytecode off there.
  printf "SCANV=\"\$D/lib/shell-words.py\"\n"                                                                      # 20: the assignment
  printf "out=\"\$($P -I -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location(\"w\", sys.argv[1])' \"\$SCANV\" 2>&1)\"\n"     # 21: by path, in a variable
  printf "out=\"\$($P -I -B -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location(\"w\", sys.argv[1])' \"\${SCANV}\" 2>&1)\"\n"  # 22: the same, -B
  printf "OTHERV=\"\$D/filed_issue_session.py\"\n"                                                                  # 23: not lib
  printf "$P -I -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location(\"f\", sys.argv[1])' \"\$OTHERV\"\n"   # 24: not lib, in a variable
  # #2840: the program itself held in a variable, the shape of tools/test-review-score.sh's
  # agree_prog, run with -I and no -B: read through a heredoc, and through a quoted assignment.
  printf "IFS= read -r -d '' HELDV <<'EOF' || true\nimport importlib.util, sys\ns = importlib.util.spec_from_file_location(\"w\", sys.argv[1])\nEOF\n"  # 25 to 28: the heredoc
  printf "out=\"\$($P -I -c \"\$HELDV\" \"\$D/lib/shell-words.py\")\"\n"                                          # 29: held, no -B
  printf "out=\"\$($P -I -B -c \"\$HELDV\" \"\$D/lib/shell-words.py\")\"\n"                                       # 30: held, -B
  printf "ASSIGNV='import sys\nsys.path.insert(0, sys.argv[1])\nimport ratchet'\n"                                 # 31 to 33: the assignment
  printf "$P -c \"\$ASSIGNV\" \"\$D/lib\"\n"                                                                        # 34: held, no -B
  printf "IFS= read -r -d '' LATEV <<'EOF' || true\nimport ratchet\nimport sys; sys.dont_write_bytecode = True\nEOF\n"   # 35 to 38: set too late
  printf "$P -c \"\$LATEV\"\n"                                                                                      # 39: held, the setting after
} > "$PROBE/payload/hooks/probe.sh"
( cd "$PROBE" && find payload -type f ! -path '*/lib/*' | sort; echo payload/hooks/lib/sibling.py ) > "$TMPROOT/probe.list"
probe="$(scan "$PROBE" "$TMPROOT/probe.list" --list)"
hits="$(printf '%s\n' "$probe" | sed -n 's/^HIT \([^:]*:[0-9]*\):.*/\1/p' | sort | tr '\n' ' ')"
want="payload/hooks/by-name.py:3 payload/hooks/by-path.py:2 payload/hooks/late.py:2 payload/hooks/lib/sibling.py:2 payload/hooks/probe.sh:10 payload/hooks/probe.sh:17 payload/hooks/probe.sh:18 payload/hooks/probe.sh:2 payload/hooks/probe.sh:21 payload/hooks/probe.sh:29 payload/hooks/probe.sh:34 payload/hooks/probe.sh:39 payload/hooks/probe.sh:5 payload/hooks/scoped.py:6 "
# Twenty four importers: seven Python files (by-name, late, early, by-path, sibling, scoped,
# scoped-ok) and seventeen shell programs (lines 2, 3, 4, 5, 10, 13, 15 to 19, 21, 22, 29, 30, 34, 39).
# prose.py, local.py, not-lib.py and lines 6 and 24 load nothing from lib.
[ "$hits" = "$want" ] \
  && check "the scan finds an import from lib in each shape, and passes -B, the variable, the setting first, prose and a file not in lib" ok \
  || check "the scan finds an import from lib in each shape, and passes -B, the variable, the setting first, prose and a file not in lib" "it found [$hits], wanted [$want]: $probe"
nimp="$(printf '%s\n' "$probe" | grep -c '^IMPORTER ' || true)"
[ "$nimp" = 24 ] \
  && check "the scan lists every importer in the probe, the ones that turn bytecode off too" ok \
  || check "the scan lists every importer in the probe, the ones that turn bytecode off too" "it listed $nimp, wanted 24: $probe"
case "$probe" in
  *"HIT payload/hooks/scoped.py:6: the file loads code by path"*"(it is set on line 3, inside a function this load is not in)"*)
    check "#2840 a setting inside another function does not count for a load outside it, and the finding says so" ok ;;
  *) check "#2840 a setting inside another function does not count for a load outside it, and the finding says so" "it said: $probe" ;;
esac
case "$probe" in
  *"HIT payload/hooks/probe.sh:29: the python3 -c program held in \$HELDV (set on line 25) loads"*)
    check "#2840 a program held in a variable is read where the variable is set, and found where it runs" ok ;;
  *) check "#2840 a program held in a variable is read where the variable is set, and found where it runs" "it said: $probe" ;;
esac
case "$probe" in
  *"HIT payload/hooks/probe.sh:39: the python3 -c program held in \$LATEV (set on line 35)"*"(it is set on line 37, after the import)"*)
    check "#2840 a late setting inside a held program is named by its own line in the file" ok ;;
  *) check "#2840 a late setting inside a held program is named by its own line in the file" "it said: $probe" ;;
esac
case "$probe" in
  *"HIT payload/hooks/late.py:2: the file loads ratchet with bytecode on, which can leave payload/hooks/lib/__pycache__ behind (it is set on line 3, after the import); set sys.dont_write_bytecode = True before it"*)
    check "a finding names the file, the line, the module and the fix" ok ;;
  *) check "a finding names the file, the line, the module and the fix" "it said: $probe" ;;
esac

# And the fault itself, measured on this machine, so the rule rests on it (L82): importing a module
# from a lib folder with bytecode on leaves a .pyc there, and with the setting first it does not.
mkdir -p "$TMPROOT/fault/lib"
printf 'X = 1\n' > "$TMPROOT/fault/lib/fault_probe.py"
env -u PYTHONDONTWRITEBYTECODE -u PYTHONPYCACHEPREFIX "$P" -c 'import sys; sys.path.insert(0, sys.argv[1]); import fault_probe' "$TMPROOT/fault/lib"
on="$(find "$TMPROOT/fault/lib" -name '*.pyc' | wc -l | tr -d ' ')"
rm -rf "$TMPROOT/fault/lib/__pycache__"
env -u PYTHONDONTWRITEBYTECODE -u PYTHONPYCACHEPREFIX "$P" -c 'import sys; sys.dont_write_bytecode = True; sys.path.insert(0, sys.argv[1]); import fault_probe' "$TMPROOT/fault/lib"
off="$(find "$TMPROOT/fault/lib" -name '*.pyc' | wc -l | tr -d ' ')"
[ "$on" -ge 1 ] && [ "$off" = 0 ] \
  && check "an import with bytecode on leaves a .pyc in lib, and with the setting first it leaves none" ok \
  || check "an import with bytecode on leaves a .pyc in lib, and with the setting first it leaves none" "on left $on, off left $off"

# ---------------------------------------------------------------------------
# The real tree: every program importing from lib/ turns bytecode off first.
# ---------------------------------------------------------------------------
bash "$DIR/lib/repo-files.sh" "$ROOT" > "$TMPROOT/files.list" 2>/dev/null
[ -s "$TMPROOT/files.list" ] \
  && check "the files to judge were listed" ok \
  || check "the files to judge were listed" "lib/repo-files.sh gave nothing for $ROOT, so nothing below was read"
tree="$(scan "$ROOT" "$TMPROOT/files.list" --list)"
tree_hits="$(printf '%s\n' "$tree" | grep '^HIT ' || true)"
[ -z "$tree_hits" ] \
  && check "#2600 every program importing from payload/hooks/lib turns bytecode off before it" ok \
  || check "#2600 every program importing from payload/hooks/lib turns bytecode off before it" "these do not:
$tree_hits"
# A scan that found a handful of importers is reading the wrong tree (L98): 63 on 2026-11-10,
# counted by this scan.
nimp="$(printf '%s\n' "$tree" | sed -n 's/^READ files=[0-9]* programs=[0-9]* importers=\([0-9]*\)$/\1/p')"
[ "${nimp:-0}" -ge 40 ] \
  && check "the scan found the repository's importers" ok \
  || check "the scan found the repository's importers" "it found ${nimp:-no} importers in $ROOT, where 63 were found on 2026-11-10"
# The two #2600 named, the one whose shape they copy, the #2751 writer, whose file to load is
# named by a variable, and the two #2840 writers (a load in a function the setting was not in, and a
# program held in a variable) are among those read.
for known in payload/hooks/lib/bundle-budget.py payload/hooks/scan-absence-needles.py payload/hooks/scan-subshell-globals.py tests/test-work-names-tree.sh tools/review-score.py tools/test-review-score.sh payload/hooks/test-pr-review.sh; do
  case "$tree" in
    *"IMPORTER $known:"*) check "#2600 $known is an importer the scan reads" ok ;;
    *) check "#2600 $known is an importer the scan reads" "it is not listed: $(printf '%s\n' "$tree" | tail -1)" ;;
  esac
done

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
