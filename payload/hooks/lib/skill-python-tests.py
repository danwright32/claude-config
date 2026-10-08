#!/usr/bin/env python3
"""Run every Python test file under the folders given, found from disk (claude-config#676).

    python3 skill-python-tests.py <folder> [<folder> ...]

A test file is any `test_*.py` or `*_test.py`. Each one runs in a process of its own, with its own
folder first on the import path and as the working directory, so two skills that each ship a
`helper.py` never import each other's, and a test that exits or crashes cannot take the others with
it. Inside a file it runs both shapes the skills use: unittest `TestCase` classes, and plain
module level `test_*` functions written in the pytest style (pytest itself is not installed, here or
on CI, so a function that asks for a pytest fixture is reported as a failure by name rather than
skipped).

Every way of running nothing is a failure, never a pass (L98): a folder that is not there, a folder
holding no test files, a file holding no tests, a file that cannot import, and a file whose process
ends without reporting its count.

Prints one `FILE <path> passed=<n> failed=<n>` line per file, then `passed: <n>, failed: <n>` for a
person and `PY-TESTS-RESULT passed=<n> failed=<n>` for the suite that reads it.

Exit: 0 every test passed, 1 a test failed or nothing could be run, 2 a folder named is missing.
Env: SKILL_PY_TESTS_TIMEOUT  seconds one file may take before it is ended and failed (default 300).
"""

import importlib.util
import inspect
import os
import subprocess
import sys
import unittest

SKIP_DIRS = {"__pycache__", "node_modules", ".git"}
RESULT_MARK = "FILE-RESULT"


def is_test_file(name: str) -> bool:
    return name.endswith(".py") and (name.startswith("test_") or name.endswith("_test.py"))


def find_test_files(folder: str) -> list:
    found = []
    for root, dirs, files in os.walk(folder):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        found.extend(os.path.join(root, f) for f in sorted(files) if is_test_file(f))
    return found


def run_one(path: str) -> int:
    """Child mode: load one file, run its tests, print its count line last."""
    sys.dont_write_bytecode = True
    folder = os.path.dirname(path)
    sys.path.insert(0, folder)
    os.chdir(folder)
    failed_to_load = 0
    suite = unittest.TestSuite()
    try:
        spec = importlib.util.spec_from_file_location("skill_test_module", path)
        module = importlib.util.module_from_spec(spec)
        sys.modules["skill_test_module"] = module
        spec.loader.exec_module(module)
    except KeyboardInterrupt:
        raise
    except BaseException as exc:  # an import that fails or exits is this file's failure, by name
        print(f"ERROR: {path} could not be imported: {type(exc).__name__}: {exc}")
        import traceback
        traceback.print_exc(file=sys.stdout)
        print(f"{RESULT_MARK} passed=0 failed=1")
        return 1

    suite.addTests(unittest.defaultTestLoader.loadTestsFromModule(module))
    for name, obj in sorted(vars(module).items()):
        if not (name.startswith("test_") and inspect.isfunction(obj)):  # a helper like testdata() is not a test
            continue
        if obj.__module__ != module.__name__:
            continue  # imported from elsewhere, not a test of this file
        required = [
            p.name for p in inspect.signature(obj).parameters.values()
            if p.default is p.empty and p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD, p.KEYWORD_ONLY)
        ]
        if required:
            print(f"FAIL: {name} in {path} asks for {', '.join(required)}, which this runner cannot "
                  f"supply (pytest and its fixtures are not installed). Build the value inside the test.")
            failed_to_load += 1
            continue
        suite.addTest(unittest.FunctionTestCase(obj, description=f"{name} ({os.path.basename(path)})"))

    result = unittest.TextTestRunner(stream=sys.stdout, verbosity=2).run(suite)
    failed = len(result.failures) + len(result.errors) + len(result.unexpectedSuccesses) + failed_to_load
    passed = result.testsRun - len(result.failures) - len(result.errors) - len(result.unexpectedSuccesses) - len(result.skipped)
    if result.testsRun == 0 and failed_to_load == 0:
        print(f"FAIL: {path} holds no tests, so nothing in it ran. Refusing to report it as passing.")
        failed += 1
    sys.stdout.flush()
    print(f"{RESULT_MARK} passed={passed} failed={failed}")
    return 0 if failed == 0 else 1


def parse_result(text: str):
    for line in reversed(text.splitlines()):
        if line.startswith(RESULT_MARK + " "):
            try:
                fields = dict(part.split("=", 1) for part in line.split()[1:])
                return int(fields["passed"]), int(fields["failed"])
            except (KeyError, ValueError):
                return None
    return None


def main(argv: list) -> int:
    if len(argv) >= 2 and argv[0] == "--one":
        return run_one(os.path.abspath(argv[1]))
    if not argv:
        print("usage: skill-python-tests.py <folder> [<folder> ...]", file=sys.stderr)
        return 2
    missing = [f for f in argv if not os.path.isdir(f)]
    if missing:
        print(f"skill-python-tests: no such folder: {', '.join(missing)}. Refusing to treat it as a "
              f"folder with no tests.", file=sys.stderr)
        return 2

    raw_timeout = os.environ.get("SKILL_PY_TESTS_TIMEOUT", "300")
    try:
        timeout = float(raw_timeout)
        if timeout <= 0:
            raise ValueError
    except ValueError:
        print(f"skill-python-tests: SKILL_PY_TESTS_TIMEOUT must be a number of seconds above 0, "
              f"not {raw_timeout!r}.", file=sys.stderr)
        return 2
    files = [p for f in argv for p in find_test_files(os.path.abspath(f))]
    total_pass = total_fail = 0
    if not files:
        print(f"FAIL: found no test files (test_*.py or *_test.py) under {', '.join(argv)}. "
              f"Refusing to report an empty run as a pass.")
        total_fail = 1
    for path in files:
        try:
            proc = subprocess.run(
                [sys.executable, "-B", os.path.abspath(__file__), "--one", path],
                capture_output=True, text=True, timeout=timeout,
            )
            text = proc.stdout + proc.stderr
            counts = parse_result(proc.stdout)
            if counts is None:
                text += (f"\nFAIL: {path} ended without reporting a count (exit {proc.returncode}), "
                         f"so how many of its tests ran is unknown.")
                counts = (0, 1)
            elif proc.returncode != 0 and counts[1] == 0:
                text += f"\nFAIL: {path} reported no failures but its process exited {proc.returncode}."
                counts = (counts[0], 1)
        except subprocess.TimeoutExpired:
            text = f"FAIL: {path} was still running after {timeout:g}s (SKILL_PY_TESTS_TIMEOUT) and was ended."
            counts = (0, 1)
        p, f = counts
        total_pass += p
        total_fail += f
        print(f"FILE {path} passed={p} failed={f}")
        if f:
            print(text.rstrip())
    print(f"passed: {total_pass}, failed: {total_fail}")
    print(f"PY-TESTS-RESULT passed={total_pass} failed={total_fail}")
    return 0 if total_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
