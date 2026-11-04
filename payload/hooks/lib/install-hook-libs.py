#!/usr/bin/env python3
"""Install hook helpers into a suite's scratch home, and refuse one that cannot import.

    python3 lib/install-hook-libs.py SRC_LIB DEST_LIB NAME...

Copies each NAME from SRC_LIB (payload/hooks/lib) into DEST_LIB (the scratch home's
~/.claude/hooks/lib, or any folder standing in for it), with every module in SRC_LIB the Python
ones import. Then every Python file in DEST_LIB must find each module it imports, either beside it
or installed with Python; any that cannot is named and the exit is 1, so a suite stops with the
cause rather than failing everywhere downstream (claude-config#2138: #2118 made sleep-report.py
import repo_slug, and tests/test-sleep-real-engine.sh's hand written list went on installing
sleep-report.py alone, so every night note failed with ModuleNotFoundError).

It follows `import` statements only. A helper another loads by its path (shell_code_lines.py loads
shell-words.py that way) is installed only when it is named, so a suite can still build a folder
missing one on purpose.

It sits in lib/ rather than tests/ because the suites in payload/hooks also run from the installed
~/.claude/hooks, which carries no tests/ (#2147). Every suite installing a Python helper goes
through it, and lib/hand-written-lib-list.py fails one that copies a helper by hand instead.
"""
import ast
import importlib.util
import os
import shutil
import sys


def imported(path):
    """The top level module names a Python file imports, anywhere in it."""
    try:
        tree = ast.parse(open(path, encoding='utf-8', errors='strict').read(), path)
    except (OSError, SyntaxError, ValueError) as e:
        raise SystemExit(f'install-hook-libs: {path} could not be read as Python ({e})')
    names = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.update(a.name.split('.')[0] for a in node.names)
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            names.add(node.module.split('.')[0])
    return names


def main(argv):
    # Only Python's own path answers "installed with Python": this file's folder is not on it.
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path[:] = [p for p in sys.path if os.path.abspath(p or '.') != here]
    if len(argv) < 3:
        raise SystemExit('usage: install-hook-libs.py SRC_LIB DEST_LIB NAME...')
    src, dest, names = argv[0], argv[1], argv[2:]
    os.makedirs(dest, exist_ok=True)
    # The named files, then every module beside them in SRC_LIB that an installed Python file
    # imports, and so on, so a helper gaining an import needs no edit to any suite's list.
    todo, done = list(names), set()
    while todo:
        name = todo.pop()
        if name in done:
            continue
        done.add(name)
        shutil.copy(os.path.join(src, name), os.path.join(dest, name))
        if name.endswith('.py'):
            todo.extend(m + '.py' for m in imported(os.path.join(dest, name))
                        if os.path.isfile(os.path.join(src, m + '.py')))
    missing = []
    for f in sorted(os.listdir(dest)):
        if not f.endswith('.py'):
            continue
        for mod in sorted(imported(os.path.join(dest, f))):
            if os.path.isfile(os.path.join(dest, mod + '.py')) or importlib.util.find_spec(mod):
                continue
            missing.append(f'{f} imports {mod}, which the scratch home does not have')
    for m in missing:
        print(f'install-hook-libs: {m}')
    return 1 if missing else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
