#!/usr/bin/env python3
"""Install hook helpers into a suite's scratch home, and refuse one that cannot find what it needs.

    python3 lib/install-hook-libs.py SRC_LIB DEST_LIB NAME...

Copies each NAME from SRC_LIB (payload/hooks/lib) into DEST_LIB (the scratch home's
~/.claude/hooks/lib, or any folder standing in for it), with every helper in SRC_LIB the Python
ones import, the shell ones source and the JavaScript ones require, and so on through what those
import, source and require. Then every
Python file in DEST_LIB must find each module it imports, either beside it or installed with
Python; any that cannot is named and the exit is 1, so a suite stops with the cause rather than
failing everywhere downstream (claude-config#2138: #2118 made sleep-report.py import repo_slug, and
tests/test-sleep-real-engine.sh's hand written list went on installing sleep-report.py alone, so
every night note failed with ModuleNotFoundError).

A shell helper's `.` and `source` lines are followed when the path is one this can resolve to a file
beside the helper (claude-config#2204): `"${BASH_SOURCE[0]%/*}/x.sh"`, `"$(dirname
"${BASH_SOURCE[0]}")/x.sh"`, or `"$LIB/x.sh"` where the helper sets LIB from BASH_SOURCE (with the
`LIB=.` fallback and the `LIB="$(cd "${LIB:-/}" && pwd)"` that the helpers use), or a variable the
helper sets to one of those. Any other source line, and one naming a file SRC_LIB does not have, is
named with its line and the exit is 1, never skipped: a helper this cannot follow is one whose
suites would go on breaking the way the Python ones did before #2147. Lines in a comment, a
heredoc's body or a quoted string are not the helper's own and are not read (lib/shell_code_lines.py).

A JavaScript helper's `require` calls are followed the same way (claude-config#2298): a relative
path beside it (`'./x'`, `"./x.js"`), `path.join(__dirname, 'x.js')`, `__dirname + '/x.js'` or
`` `${__dirname}/x.js` ``, tried as written and then with .js and .json, as Node does. A built in or
package name (`fs`, `node:path`) is no helper and is left alone. Any other require, one reaching
outside the folder, and one naming a file SRC_LIB does not have, is named with its line and the
exit is 1. A require in a comment or a string is not read.

A helper loaded another way, by its path (shell_code_lines.py loads shell-words.py that way, and a
shell helper may run `python3 "$LIB/x.py"`), is installed only when it is named, so a suite can
still build a folder missing one on purpose. A suite that needs a folder missing a helper that IS
imported, sourced or required installs it and then removes that one file, so the absence is written in the
suite where it can be read.

It sits in lib/ rather than tests/ because the suites in payload/hooks also run from the installed
~/.claude/hooks, which carries no tests/ (#2147). Every suite installing a Python, shell or
JavaScript helper goes through it, and lib/hand-written-lib-list.py fails one that copies a helper by hand instead.
"""
import ast
import importlib.util
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# A shell word as written: quoted runs, a $( ... ) with one level of nesting, and plain characters.
WORD = r'''(?:"(?:[^"\\]|\\.)*"|'[^']*'|\$\((?:[^()]|\([^()]*\))*\)|[^\s;&|()<>"'])+'''
# `.` or `source` where a command starts. The bare form is the line with its quoted text removed,
# so jq's `then . else` inside quotes is never counted; the raw form carries the operand.
# A `.` straight after `=` is a value (`DIR=.`); one after `= ` begins a command, as in
# `st="$( . "$LIB/x.sh" ...)"`, whose `$(` the bare form leaves out.
SOURCE_BARE = re.compile(r'(?:^|[;&|{(!]|=\s|\b(?:if|while|until|then|do|else|elif)\b)\s*(?:\.|source)(?=\s)')
SOURCE_RAW = re.compile(r'(?:^|[;&|{(!]|=\s|\$\(|\b(?:if|while|until|then|do|else|elif)\b)\s*(?:\.|source)\s+(' + WORD + ')')
ASSIGN = re.compile(r'(?:^|[\s;&|{(])([A-Za-z_]\w*)=(' + WORD + ')?')
NAME = r'([A-Za-z0-9._+-]+)'
SELF_DIR = (r'\$\{BASH_SOURCE(?:\[0\])?%/\*\}', r'\$\(dirname \$\{?BASH_SOURCE(?:\[0\])?\}?\)',
            r'\$\(cd \$\(dirname \$\{?BASH_SOURCE(?:\[0\])?\}?\) && pwd\)')
SELF_PATH = re.compile(r'^(?:' + '|'.join(SELF_DIR) + r')/' + NAME + r'$')
VAR_PATH = re.compile(r'^\$\{?([A-Za-z_]\w*)\}?/' + NAME + r'$')
VAR_ONLY = re.compile(r'^\$\{?([A-Za-z_]\w*)\}?$')

_reader = None


def shell_reader():
    """lib/shell_code_lines.py beside this file, loaded by its path under a private name, so a
    Python helper importing shell_code_lines is never answered by this file's own copy."""
    global _reader
    if _reader is None:
        dont = sys.dont_write_bytecode
        sys.dont_write_bytecode = True
        try:
            spec = importlib.util.spec_from_file_location(
                '_install_hook_libs_shell_code_lines', os.path.join(HERE, 'shell_code_lines.py'))
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
        except Exception as e:  # noqa: BLE001  missing or broken: either way nothing can be read
            raise SystemExit(f'install-hook-libs: lib/shell_code_lines.py could not be loaded ({e}), '
                             'so no shell helper\'s source lines could be read')
        finally:
            sys.dont_write_bytecode = dont
        if mod.READER_ERROR is not None:
            raise SystemExit(f'install-hook-libs: lib/shell-words.py could not be loaded ({mod.READER_ERROR}), '
                             'so no shell helper\'s source lines could be read')
        _reader = mod
    return _reader


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


def plain(word):
    """A word with its quote characters removed, its $ expansions left as written."""
    return word.replace('"', '').replace("'", '')


def sourced(path):
    """What a shell file sources: (line, operand as written, the file name beside it or None)."""
    reader = shell_reader()
    try:
        text = open(path, encoding='utf-8', errors='strict').read()
    except (OSError, ValueError) as e:
        raise SystemExit(f'install-hook-libs: {path} could not be read as text ({e})')
    body = reader.heredoc_body_lines(text)
    code = [(n, line, bare) for n, line, kind, bare, _ in reader.read_lines(text)
            if kind == 'code' and n not in body]
    values = {}
    for _, line, _ in code:
        for m in ASSIGN.finditer(line):
            values.setdefault(m.group(1), []).append(plain(m.group(2) or ''))

    def self_dir(var):
        vals = values.get(var, [])
        own = re.compile(r'\$\{?' + re.escape(var) + r'(?:\}|:-|\b)')
        return (any('BASH_SOURCE' in v for v in vals)
                and all('BASH_SOURCE' in v or v == '.' or own.search(v) for v in vals))

    def resolve(op, depth=0):
        m = SELF_PATH.match(op)
        if m:
            return m.group(1)
        m = VAR_PATH.match(op)
        if m and self_dir(m.group(1)):
            return m.group(2)
        m = VAR_ONLY.match(op)
        if m and depth == 0 and values.get(m.group(1)):
            got = {resolve(v, 1) for v in values[m.group(1)]}
            if len(got) == 1 and None not in got:
                return got.pop()
        return None

    found = []
    for n, line, bare in code:
        want = len(SOURCE_BARE.findall(bare))
        if not want:
            continue
        ops = [m.group(1) for m in SOURCE_RAW.finditer(line)]
        if len(ops) != want:
            found.append((n, line.strip(), None, False))
            continue
        found.extend((n, op, resolve(plain(op)), True) for op in ops)
    return found


REQUIRE = re.compile(r'(?<![\w$.])require\s*\(')
JS_STRING = re.compile(r'''^(['"])([^'"\\]*)\1$''')
JS_BESIDE = (re.compile(r'''^path\.join\(\s*__dirname\s*,\s*(['"])([^'"\\]+)\1\s*\)$'''),
             re.compile(r'''^__dirname\s*\+\s*(['"])/([^'"\\]+)\1$'''),
             re.compile(r'''^()`\$\{__dirname\}/([^`$\\]+)`$'''))
# A `/` after one of these, or at the start, opens a regular expression rather than dividing.
JS_REGEX_BEFORE = set('(,=:[!&|?{};+-*%<>~^')


def js_code(text):
    """The text with every comment blanked and every string, template and regular expression's
    contents replaced by x, newlines kept, so a position in it is a position in the text and only
    the file's own code can match. A require inside a template's ${...} is not seen."""
    out, i, n = list(text), 0, len(text)

    def blank(a, b, keep):
        for k in range(a, b):
            if out[k] != '\n':
                out[k] = keep
    last = ''  # the last character of code before i that is not white space
    while i < n:
        c = text[i]
        if text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            blank(i, j, ' ')
            i = j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            blank(i, j, ' ')
            i = j
        elif c in '\'"`' or (c == '/' and (last == '' or last in JS_REGEX_BEFORE
                                           or re.search(r'\b(?:return|typeof|case)\s*$', text[max(0, i - 20):i]))):
            j, in_class = i + 1, False
            while j < n:
                if text[j] == '\\':
                    j += 2
                    continue
                if c == '/' and text[j] == '[':
                    in_class = True
                elif c == '/' and text[j] == ']':
                    in_class = False
                elif text[j] == c and not in_class:
                    break
                elif text[j] == '\n' and c != '`':
                    break
                j += 1
            blank(i + 1, min(j, n), 'x')
            i = j + 1
            last = c
        else:
            if not c.isspace():
                last = c
            i += 1
    return ''.join(out)


def required(path):
    """What a JavaScript file requires: (line, argument as written, the file name beside it or
    None). A built in or package name (`fs`, `node:path`) is no file beside it and is left out."""
    try:
        text = open(path, encoding='utf-8', errors='strict').read()
    except (OSError, ValueError) as e:
        raise SystemExit(f'install-hook-libs: {path} could not be read as text ({e})')
    code = js_code(text)
    found = []
    for m in REQUIRE.finditer(code):
        depth, j = 1, m.end()
        while j < len(code) and depth:
            depth += {'(': 1, ')': -1}.get(code[j], 0)
            j += 1
        arg = text[m.end():j - 1].strip()
        line = code.count('\n', 0, m.start()) + 1
        lit = JS_STRING.match(arg)
        if lit:
            value = lit.group(2)
            if not value.startswith(('.', '/')):
                continue
            name = value[2:] if value.startswith('./') else None
        else:
            name = next((p.match(arg).group(2) for p in JS_BESIDE if p.match(arg)), None)
        if name is not None and '/' in name:
            name = None
        found.append((line, plain(arg), name))
    return found


def js_beside(src, name):
    """The file in src a require of name loads, trying it as written and then with .js and .json."""
    return next((f for f in (name, name + '.js', name + '.json') if os.path.isfile(os.path.join(src, f))), None)


def main(argv):
    # Only Python's own path answers "installed with Python": this file's folder is not on it.
    sys.path[:] = [p for p in sys.path if os.path.abspath(p or '.') != HERE]
    if len(argv) < 3:
        raise SystemExit('usage: install-hook-libs.py SRC_LIB DEST_LIB NAME...')
    src, dest, names = argv[0], argv[1], argv[2:]
    os.makedirs(dest, exist_ok=True)
    # The named files, then every helper beside them in SRC_LIB that an installed Python file
    # imports, an installed shell file sources or an installed JavaScript file requires, and so on,
    # so a helper gaining an import, a require or a
    # source line needs no edit to any suite's list.
    todo, done, missing = list(names), set(), []
    while todo:
        name = todo.pop()
        if name in done:
            continue
        done.add(name)
        shutil.copy(os.path.join(src, name), os.path.join(dest, name))
        if name.endswith('.py'):
            todo.extend(m + '.py' for m in imported(os.path.join(dest, name))
                        if os.path.isfile(os.path.join(src, m + '.py')))
        elif name.endswith('.sh'):
            for n, op, beside, readable in sourced(os.path.join(dest, name)):
                if not readable:
                    missing.append(f'{name} line {n} has a source command whose path could not be read: {op}')
                elif beside is None:
                    missing.append(f'{name} line {n} sources {op}, which could not be resolved to a file beside it')
                elif os.path.isfile(os.path.join(src, beside)):
                    todo.append(beside)
                else:
                    missing.append(f'{name} line {n} sources {beside}, which {src} does not have')
        elif name.endswith('.js'):
            for n, op, beside in required(os.path.join(dest, name)):
                if beside is None:
                    missing.append(f'{name} line {n} requires {op}, which could not be resolved to a file beside it')
                elif js_beside(src, beside):
                    todo.append(js_beside(src, beside))
                else:
                    missing.append(f'{name} line {n} requires {op}, which {src} does not have')
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
