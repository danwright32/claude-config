"""The modules a JavaScript or TypeScript test file replaces with a mock, for the Slack drafts gate
(claude-config#2359).

A test runner (vitest, jest) never loads a module a test file replaces with vi.mock or jest.mock and a
factory: every import of it in that file gets the object the factory returns. On 2026-11-06, 7 test
files in two personal repositories that imported a posting helper only to replace it were refused
when run directly. Dan decided on 2026-11-15 that such an import is not a send, and that a real
unmocked import stays refused. This is a loosening of the gate he signed off.

A module counts as replaced in a file only where all of these hold, each read from the file's code
with its comments blanked and its strings told apart (the gate's own js_scan):
- the file is a test file by the runners' own default naming: a name ending .test or .spec before a
  JavaScript or TypeScript extension, or a file inside a __tests__ folder. A name is not enough by
  itself; it only stops a script mocking a global of its own from passing;
- a call vi.mock or jest.mock, written as code, names the module's path as a string written out
  (quotes, or a template with no ${...}) that resolves to the same file the import does;
- its second argument is a factory taking no parameters: `() =>`, `async () =>`, or `function ()`.
  A mock with no factory automocks, which loads the module to see its shape; vitest hands a factory
  that takes a parameter the original module (importOriginal); an object there is options
  ({ spy: true } loads the original); a name there cannot be read;
- nothing else in the file names the module to load or restore it: importActual, requireActual,
  importMock, requireMock, createMockFromModule, genMockFromModule, doMock (not hoisted, so imports
  above it get the real module), unmock, doUnmock or dontMock, on vi or jest; and every mock with no
  factory is of another file. Any such call, or a vi.mock or jest.mock, whose path is not a string
  written out could name the module, so where there is one, nothing in the file counts as replaced.

Hoisting is not read: vitest and babel-jest move a vi.mock or jest.mock to the top of its file, so
where it is written does not change what an import gets. Only the file's own imports are affected:
a module reached through another file is followed as before, though the runner would mock it there
too, so the gate can only refuse more than the runner sends, never less.

slack_drafts_only_gate.py loads this file and calls replaced() from import_targets.
"""
import os
import re

# A runner's default test file: vitest's **/*.{test,spec}.?(c|m)[jt]s?(x) and jest's
# **/?(*.)+(spec|test).[jt]s?(x) and **/__tests__/**/*.[jt]s?(x).
TEST_NAME = re.compile(r"\.(?:test|spec)\.[cm]?[jt]sx?\Z")
TEST_DIR = "__tests__"
TEST_EXT = re.compile(r"\.[cm]?[jt]sx?\Z")
# A call on vi or jest, written as code (not a property of something else), with its method's name.
CALL = re.compile(r"(?<![\w$.])(vi|jest)\s*\.\s*([A-Za-z_$][\w$]*)\s*\(\s*")
# A path written out: quoted, or a template with no ${...}.
LITERAL = re.compile(r"""(['"])([^'"\n\\]*)\1|`([^`$\\]*)`""")
# A factory taking no parameters, from the comma after the path.
FACTORY = re.compile(r",\s*(?:async\s*)?(?:\(\s*\)\s*=>|function\s*\*?\s*(?:[A-Za-z_$][\w$]*)?\s*\(\s*\))")
# Methods that load the module or take a mock back, so a file naming one keeps its import followed.
REOPEN = frozenset({"importActual", "requireActual", "importMock", "requireMock", "createMockFromModule",
                    "genMockFromModule", "doMock", "unmock", "doUnmock", "dontMock"})


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
    names no mock, or names a path the gate cannot read beside one (see the module docstring)."""
    if not is_test_file(path) or ".mock" not in code:
        return set()
    mocked, spoiled = set(), set()
    for m in CALL.finditer(code):
        if quoted[m.start()]:
            continue  # written inside a string: nothing calls it
        method = m.group(2)
        if method != "mock" and method not in REOPEN:
            continue
        lit = LITERAL.match(code, m.end())
        if lit is None or not quoted[lit.start()]:
            return set()  # a path the gate cannot read could be any module
        spec = lit.group(2) if lit.group(1) else lit.group(3)
        target = resolve(spec)
        if not target:
            continue  # a package or a file not there: no local module is named
        if method == "mock" and FACTORY.match(code, lit.end()):
            mocked.add(target)
        else:
            spoiled.add(target)
    return mocked - spoiled
