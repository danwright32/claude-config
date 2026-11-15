"""The modules a JavaScript or TypeScript test file replaces with a mock, for the Slack drafts gate
(claude-config#2359).

A test runner (vitest, jest) never loads a module a test file replaces with vi.mock or jest.mock and a
factory: every import of it in that file gets the object the factory returns. On 2026-11-06, 7 test
files in two personal repositories that imported a posting helper only to replace it were refused
when run directly. The decision recorded on #2359 on 2026-11-15 reads: "Decided by Dan, 2026-11-15:
pass an import the same test file mocks out (vi.mock or jest.mock of that path), with a test; a real
unmocked import stays refused. Note that this is a loosening of the Slack drafts gate that Dan has now
signed off."

A module counts as replaced in a file only where all of these hold, each read from the file's code
with its comments blanked and its strings told apart (the gate's own js_scan):
- the file is handed to vitest or jest (runner(): the program it is handed to is named vitest or jest,
  a package, a node_modules/.bin launcher or the package's own script). Run by node, tsx or bun
  itself, vi.mock and jest.mock replace nothing, and an import runs before any line of the file does;
- the file is a test file by the runners' own default naming: a name ending .test or .spec before a
  JavaScript or TypeScript extension, or a file inside a __tests__ folder. A name is not enough by
  itself;
- a call vi.mock or jest.mock (a TypeScript type argument allowed), written as code at the file's
  top level (inside no block, call or brackets) as a statement of its own (statement_start), names
  the module's path as a string written out (quotes, or a template with no ${...}) that resolves to
  the same file the import does. vitest and babel-jest lift only such a statement, and babel-jest only
  to the top of its own block, so one inside a describe, an arrow's body (() => vi.mock(...)), an if
  or an && runs after the file's imports have loaded the real module, if at all;
- its second argument is a factory taking no parameters: `() =>`, `async () =>`, or `function ()`.
  A mock with no factory automocks, which loads the module to see its shape; vitest hands a factory
  that takes a parameter the original module (importOriginal); an object there is options
  ({ spy: true } loads the original); a name there cannot be read;
- nothing else in the file names the module to load or restore it: importActual, requireActual,
  importMock, requireMock, createMockFromModule, genMockFromModule, doMock (not hoisted, so imports
  above it get the real module), unmock, doUnmock or dontMock, on vi or jest; and every mock with no
  factory is of another file. Any such call, or a vi.mock or jest.mock, whose path is not a string
  written out, or that is named without being called there (const load = vi.importActual), could
  name the module, so where there is one, nothing in the file counts as replaced.

A top level vi.mock or jest.mock may be written before or after the import it replaces: vitest and
babel-jest both lift a top level one above the file's imports. Only the file's own imports are affected:
a module reached through another file is followed as before, though the runner would mock it there
too, so the gate can only refuse more than the runner sends, never less.

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
# A method of vi or jest, written as code (not a property of something else), with its name; whether
# and how it is called is call_open's.
CALL = re.compile(r"(?<![\w$.])(vi|jest)\s*\.\s*([A-Za-z_$][\w$]*)")
# What a ) closes that makes the next line its body rather than a statement of its own.
STATEMENT_HEADS = frozenset({"if", "while", "for", "with", "await"})
# Words after which a line break does not end the statement: the next line is their operand.
OPERAND_WORDS = frozenset({"else", "do", "return", "throw", "typeof", "void", "delete", "await", "yield",
                           "new", "in", "of", "instanceof", "case", "default", "extends", "export"})
# A path written out: quoted, or a template with no ${...}.
LITERAL = re.compile(r"""(['"])([^'"\n\\]*)\1|`([^`$\\]*)`""")
# A factory taking no parameters, from the comma after the path.
FACTORY = re.compile(r",\s*(?:async\s*)?(?:\(\s*\)\s*=>|function\s*\*?\s*(?:[A-Za-z_$][\w$]*)?\s*\(\s*\))")
# Methods that load the module or take a mock back, so a file naming one keeps its import followed.
REOPEN = frozenset({"importActual", "requireActual", "importMock", "requireMock", "createMockFromModule",
                    "genMockFromModule", "doMock", "unmock", "doUnmock", "dontMock"})


# The runner's own name in the label of the program a file is handed to: "the package vitest, run by
# npx,", "the script ./node_modules/.bin/jest", "the script node_modules/vitest/vitest.mjs". A name
# merely holding it (my-vitest-runner.js, vitest-wrapper) is not the runner.
RUNNER = re.compile(r"(?<![\w.@-])(?:vitest|jest)(?![\w-])")


def runner(label):
    """Whether label, how the gate names a program a file is handed to, names vitest or jest."""
    return bool(label) and RUNNER.search(label) is not None


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


def is_test_file(path):
    """Whether path is a test file by a runner's default naming."""
    if not path:
        return False
    if TEST_NAME.search(os.path.basename(path)):
        return True
    return TEST_EXT.search(path) is not None and TEST_DIR in path.replace(os.sep, "/").split("/")[:-1]


def replaced(path, code, quoted, resolve):
    """The files a test file at path replaces with a mock, as resolve(spec) gives them, each read from
    code and quoted (js_scan's reading of its text). An empty set for a file that is not a test file,
    names no mock, or names a path the gate cannot read beside one (see the module docstring). The
    caller asks only for a file handed to vitest or jest (runner)."""
    if not is_test_file(path) or ".mock" not in code:
        return set()
    mocked, spoiled = set(), set()
    top = None
    for m in CALL.finditer(code):
        if quoted[m.start()]:
            continue  # written inside a string: nothing calls it
        method = m.group(2)
        if method != "mock" and method not in REOPEN:
            continue
        at = call_open(code, quoted, m.end())
        lit = LITERAL.match(code, at) if at is not None else None
        if lit is None or not quoted[lit.start()]:
            # Not called where it is named (passed on as a value), or a path the gate cannot read:
            # either could be any module.
            return set()
        spec = lit.group(2) if lit.group(1) else lit.group(3)
        target = resolve(spec)
        if not target:
            continue  # a package or a file not there: no local module is named
        if method == "mock" and FACTORY.match(code, lit.end()):
            top = top if top is not None else top_level(code, quoted)
            if top[m.start()] and statement_start(code, quoted, m.start()):
                mocked.add(target)  # any other is not lifted above the file's imports
        else:
            spoiled.add(target)
    return mocked - spoiled


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
