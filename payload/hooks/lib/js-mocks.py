"""The modules a JavaScript or TypeScript test file replaces with a mock, for the Slack drafts gate
(claude-config#2359).

A test runner (vitest, jest) never loads a module a test file replaces with vi.mock or jest.mock and a
factory: every import of it in that file gets the object the factory returns. On 2026-11-06, 7 test
files in two personal repositories that imported a posting helper only to replace it were refused
when run directly. The decision recorded on #2359 on 2026-11-15 reads: "Decided by Dan, 2026-11-15:
pass an import the same test file mocks out (vi.mock or jest.mock of that path), with a test; a real
unmocked import stays refused. Note that this is a loosening of the Slack drafts gate that Dan has now
signed off."

The rule is written the narrow way round. Three lessons review rounds each found another way a file
can still reach the original module beside its mock (a type argument, a bracket, a destructuring, an
alias), so the reading does not list the ways in; it lets a mock count only in a file plain enough
that none can be present, and refuses the rest. A module counts as replaced only where all of these
hold, each read from the file's code with its comments blanked and its strings told apart (the
gate's own js_scan):

- the file is handed to vitest or jest as installed (runner(): the package vitest or jest run by a
  launcher, or a script under node_modules/.bin/, node_modules/vitest/, node_modules/jest/ or
  node_modules/jest-cli/). Run by node, tsx or bun itself, vi.mock and jest.mock replace nothing, and
  an import runs before any line of the file does;
- the file is a test file by the runners' own default naming: a name ending .test or .spec before a
  JavaScript or TypeScript extension, or a file inside a __tests__ folder;
- a call vi.mock or jest.mock (a TypeScript type argument allowed), written as code at the file's top
  level (inside no block, call or brackets) as a statement of its own (statement_start), names the
  module's path as a string written out (quotes, or a template with no ${...}) that resolves to the
  same file the import does. vitest and babel-jest lift only such a statement, and babel-jest only to
  the top of its own block, so one inside a describe, an arrow's body, an if or an && runs after the
  file's imports have loaded the real module, if at all;
- its second argument is a factory taking no parameters: `() =>`, `async () =>`, or `function ()`.
  A mock with no factory automocks, which loads the module to see its shape; vitest hands a factory
  that takes a parameter the original module (importOriginal); an object there is options
  ({ spy: true } loads the original); a name there cannot be read. A mock of the module with no
  factory, or inside an expression, leaves it followed whatever other mock of it there is;
- the file is plain (plain()): it names none of the runners' ways to the original or to taking a mock
  back (ORIGINAL), in code or in a string, so no alias, bracket or destructuring can reach one;
  it holds no string that is exactly vi or jest; every vi and jest written as code is a member
  access (vi.fn), or a name in `import { ... } from "vitest"` or "@jest/globals" not renamed; every
  vi.mock and jest.mock is called where it is named, with a path the gate can read; and it reaches no
  member by a computed name and names nothing that runs a string as code (the opaque check the gate
  hands in: JS_SINK, JS_DYNAMIC and lib/data-names.py's js_computed, as the #2913 reading uses).

A top level vi.mock or jest.mock may be written before or after the import it replaces. Only the
file's own imports are affected: a module reached through another file is followed as before, though
the runner would mock it there too, so the gate can only refuse more than the runner sends, never
less. What it cannot see is what the runner is: a program installed as vitest or jest is trusted to
be one, as any name the gate reads by is.

slack_drafts_only_gate.py loads this file, asks runner() of the program a file is handed to
(handed_code), and calls replaced() from import_targets only while that says vitest or jest.
"""
import os
import re

# A runner's default test file: vitest's **/*.{test,spec}.?(c|m)[jt]s?(x) and jest's
# **/?(*.)+(spec|test).[jt]s?(x) and **/__tests__/**/*.[jt]s?(x).
TEST_NAME = re.compile(r"\.(?:test|spec)\.[cm]?[jt]sx?\Z")
TEST_DIR = "__tests__"
TEST_EXT = re.compile(r"\.[cm]?[jt]sx?\Z")
# The label of a program a file is handed to, when it is vitest or jest as installed: "the package
# vitest, run by npx," (lib/program-runs.py), or a script under node_modules ("the script
# ./node_modules/.bin/vitest", "the script node_modules/vitest/vitest.mjs"). A script of the
# repository's own named jest.js or vitest/run.js is not one.
RUNNER = re.compile(r"\Athe package (?:vitest|jest)(?:@[^\s,]*)?, run by |"
                    r"(?:\A|[\s/])node_modules/(?:\.bin/(?:vitest|jest)(?![\w.-])|(?:vitest|jest|jest-cli)/)")
# Every way the runners give to the original module or take a mock back, by name, matched in code and
# strings alike so that vi["importActual"] and const { requireActual } = jest are found too.
ORIGINAL = re.compile(r"(?<![\w$])(?:importActual|requireActual|importMock|requireMock|createMockFromModule|"
                      r"genMockFromModule|importOriginal|requireOriginal|doMock|unmock|doUnmock|dontMock|"
                      r"deepUnmock|enableAutomock|setMock|isolateModules|isolateModulesAsync)(?![\w$])")
# vi or jest written as a whole name, and a string that is exactly one.
RUNTIME = re.compile(r"(?<![\w$])(vi|jest)(?![\w$])")
RUNTIME_STRING = re.compile(r"""(['"`])(?:vi|jest)\1""")
# What may follow vi or jest written as code: a member's name.
MEMBER = re.compile(r"\s*(?:\?\.|\.)\s*[A-Za-z_$]")
# The names an import of the runner's own module lists, for vi and jest written there.
RUNTIME_IMPORT = re.compile(r"""\bimport\s*\{([^}]*)\}\s*from\s*(['"])(?:vitest|@jest/globals)\2""")
# vi.mock or jest.mock written as code (not a property of something else).
MOCK = re.compile(r"(?<![\w$.])(?:vi|jest)\s*\.\s*mock(?![\w$])")
# A path written out: quoted, or a template with no ${...}.
LITERAL = re.compile(r"""(['"])([^'"\n\\]*)\1|`([^`$\\]*)`""")
# A factory taking no parameters, from the comma after the path.
FACTORY = re.compile(r",\s*(?:async\s*)?(?:\(\s*\)\s*=>|function\s*\*?\s*(?:[A-Za-z_$][\w$]*)?\s*\(\s*\))")
# What a ) closes that makes the next line its body rather than a statement of its own.
STATEMENT_HEADS = frozenset({"if", "while", "for", "with", "await"})
# Words after which a line break does not end the statement: the next line is their operand.
OPERAND_WORDS = frozenset({"else", "do", "return", "throw", "typeof", "void", "delete", "await", "yield",
                           "new", "in", "of", "instanceof", "case", "default", "extends", "export"})


def runner(label):
    """Whether label, how the gate names a program a file is handed to, is vitest or jest as installed."""
    return bool(label) and RUNNER.search(label) is not None


def is_test_file(path):
    """Whether path is a test file by a runner's default naming."""
    if not path:
        return False
    if TEST_NAME.search(os.path.basename(path)):
        return True
    return TEST_EXT.search(path) is not None and TEST_DIR in path.replace(os.sep, "/").split("/")[:-1]


def replaced(path, code, quoted, resolve, opaque):
    """The files a test file at path replaces with a mock, as resolve(spec) gives them, read from code
    and quoted (js_scan's reading of its text); an empty set wherever the module docstring's rule does
    not hold. opaque() says whether the file reaches a member by a computed name or names something
    that runs a string as code. The caller asks only for a file handed to vitest or jest (runner)."""
    if not is_test_file(path) or ".mock" not in code or not plain(code, quoted) or opaque():
        return set()
    mocked, kept = set(), set()
    top = None
    for m in MOCK.finditer(code):
        if quoted[m.start()]:
            continue  # inside a string, where plain() has already read it
        at = call_open(code, quoted, m.end())
        lit = LITERAL.match(code, at) if at is not None else None
        if lit is None or not quoted[lit.start()]:
            return set()  # named without a call, or a path the gate cannot read: any module
        target = resolve(lit.group(2) if lit.group(1) else lit.group(3))
        if not target:
            continue  # a package or a file not there: no local module is named
        top = top if top is not None else top_level(code, quoted)
        if FACTORY.match(code, lit.end()) and top[m.start()] and statement_start(code, quoted, m.start()):
            mocked.add(target)
        else:
            kept.add(target)  # automocked (loads it), or not lifted above the imports
    return mocked - kept


def plain(code, quoted):
    """Whether a test file names no way to the original module and uses vi and jest only as members
    (module docstring)."""
    if ORIGINAL.search(code) or RUNTIME_STRING.search(code):
        return False
    listed = [(r.start(1), r.end(1)) for r in RUNTIME_IMPORT.finditer(code)]
    for m in RUNTIME.finditer(code):
        if quoted[m.start()]:
            continue  # inside a longer string ("mocks the jest way"), which names nothing
        if MEMBER.match(code, m.end()):
            continue
        end = next((b for a, b in listed if a <= m.start() < b), None)
        if end is None or not re.match(r"\s*(?:,|\Z)", code[m.end():end]):
            return False  # passed as a value, destructured, renamed: anything can be reached from it
    return True


def call_open(code, quoted, at):
    """Where a call's first argument starts, for a method name ending at at: past any TypeScript type
    argument (<typeof import("./x")>) and the (, or None where no call follows or the type argument
    does not close."""
    n = len(code)
    while at < n and code[at].isspace():
        at += 1
    if at < n and code[at] == "<":
        depth = 0
        while at < n:
            if not quoted[at]:
                if code[at] == "<":
                    depth += 1
                elif code[at] == ">":
                    depth -= 1
                    if depth == 0:
                        break
                elif code[at] in ";{}":
                    return None
            at += 1
        else:
            return None
        at += 1
        while at < n and code[at].isspace():
            at += 1
    if at >= n or code[at] != "(":
        return None
    at += 1
    while at < n and code[at].isspace():
        at += 1
    return at


def top_level(code, quoted):
    """For each index of code, whether it lies inside no (), [] or {}: strings and regex literals
    (quoted) are stepped over. A count that goes below zero reads as nested from there on."""
    out = bytearray(len(code))
    depth = 0
    for i, c in enumerate(code):
        out[i] = depth == 0
        if quoted[i] or depth < 0:
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
    return out


def statement_start(code, quoted, at):
    """Whether the code at at starts a statement of its own, which is what vitest and babel-jest lift:
    the file's start, or after a ; or a }, or after a line break that ends the statement before (a
    name that is not a keyword, a string, a ] or a ) that closes no if, while, for or with). After
    anything else (=>, &&, =, a keyword such as void, an if's condition) it is part of an expression
    or a condition, and runs only when that does."""
    j = at - 1
    broke = False
    while j >= 0 and code[j].isspace():
        broke = broke or code[j] in "\n\r  "
        j -= 1
    if j < 0:
        return True
    c = code[j]
    if not quoted[j] and c in ";}":
        return True
    if not broke:
        return False
    if quoted[j] or c == "]":
        return True
    if c == ")":
        depth = 0
        while j >= 0:
            if not quoted[j]:
                if code[j] == ")":
                    depth += 1
                elif code[j] == "(":
                    depth -= 1
                    if depth == 0:
                        break
            j -= 1
        word = re.search(r"[\w$]*\s*\Z", code[max(0, j - 40):max(0, j)]).group(0).strip()
        return j >= 0 and word not in STATEMENT_HEADS
    if c.isalnum() or c in "_$":
        word = re.search(r"[\w$]+\Z", code[max(0, j - 40):j + 1]).group(0)
        return word not in OPERAND_WORDS
    return False
