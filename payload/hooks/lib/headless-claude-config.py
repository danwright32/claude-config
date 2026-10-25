#!/usr/bin/env python3
"""Every headless `claude -p` launch must decide what config it loads (claude-config#538) and how
long its prompt is cached (claude-config#1601).

CONFIG. A headless run inherits the whole global CLAUDE.md and every lessons index file unless
something says otherwise, and nothing in the call shows it: measured 2026-09-23, the findings
harvester took 64,868 input tokens with them and 29,663 without, on every harvest. So each launch
this finds must either switch the config off on the launch itself (CLAUDE_CODE_DISABLE_CLAUDE_MDS=1
on the launch, as defined below) or carry a `# claude-mds-ok: <reason>` comment in the comment block
directly above the statement, saying why it keeps the config or how it already excludes it.

PROMPT CACHE LIFETIME. On a subscription a headless run writes its prompt to the ONE HOUR cache by
default, at twice the input price, and nothing in the call shows it either: in the week to
2026-10-23 headless runs wrote 113.4M tokens there and almost never read them back (#1573). So each
launch must also either choose on the launch itself, with DISABLE_PROMPT_CACHING=1 (no cache) or
CLAUDE_CODE_PROMPT_CACHE_TTL=<lifetime> (5m costs 1.25 times the input price to write), or carry a
`# prompt-cache-ok: <reason>` comment directly above the statement saying why the default is right.

The two are separate decisions with separate messages: a marker for one never answers the other.
"On the launch" means anywhere in the statement BEFORE the launch words, on their line or an
earlier one: in shell, the backslash continued lines before it (so an export in the subshell that
line opens counts); in Python, the statement the argv list belongs to, found by parsing the file.
Anything after the launch words, on any line, is an argument to claude and not its environment.

Launches are FOUND by scanning, never listed by hand (L96), and by what runs rather than one
spelling (L247, claude-config#1681). In shell, on a line that is not a comment: a program that is
claude, named bare or by its path, or a variable the file sets from something naming claude
(`bin="$(command -v claude)"`, `bin="$(sync_claude_bin)"`), followed in the same command, over
continued lines, by -p or --print or by an array the file fills with either (`"$bin" "${args[@]}"`
after `args=(-p ...)`). In Python, read by its parser: a list or tuple whose item is the string
claude (or a path ending /claude), or a name holding claude, with "-p" or "--print" anywhere after
it, which is how an argv is built there; a string, a docstring included, is never a launch however
it quotes the words. A Python file that will not parse falls back to the two words as adjacent
quoted items on a line. Test suites (`test-*`) are skipped: their stubs and fixtures are not
launches, and a suite must never reach the real model (L2).

Usage: headless-claude-config.py <file-or-dir>...
Exit 0 every launch decides both; 1 at least one does not (each named as path:line, once per missing
decision); 3 no launch found at all, which is refused rather than passed, because a scan that
stopped matching would otherwise report every tree clean (L98); 2 bad usage.
"""
import ast
import os
import re
import sys
import warnings

# claude as a program: bare, or the last part of a path, never a dot directory or a longer name.
SHELL_CLAUDE = re.compile(r"(?:(?<=/)|(?<![\w./-]))claude(?![\w.-])")
# A value that finds or names claude as a program: looked up (command -v, which, type -P), a path
# ending /claude, claude alone or as a default (${X:-claude}), or a function whose name says it finds
# one. Never prose that merely mentions claude ("the claude command failed").
CLAUDE_FIND = re.compile(
    r"(?:command\s+-v|which|type\s+-[pP])\s+claude(?![\w.-])|/claude(?![\w.-])"
    r"|=[\"']?claude[\"']?(?:\s|;|$)|:-claude\}|claude_bin")
FUNCTION = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\)\s*\{?")
ASSIGNMENT = re.compile(r"(?<![\w$.-])([A-Za-z_]\w*)\+?=")
ARRAY = re.compile(r"(?<![\w$.-])([A-Za-z_]\w*)\+?=\(([^)]*)\)")
PRINT_WORD = re.compile(r"(?<![\w-])(-p|--print)(?![\w-])")
# Where one command ends: a pipe, a list operator, a closing substitution or subshell, a backquote.
COMMAND_END = re.compile(r"\|\||&&|[|;&)`]")
PY_LAUNCH = re.compile(r"""['"]claude['"]\s*,\s*['"](-p|--print)['"]""")
PY_PRINT = ("-p", "--print")
SWITCH = "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1"
# Off, or a lifetime that is actually given: `=0` leaves caching on and an empty value chooses
# nothing, so neither is a decision. A value may open with a quote or be a variable.
CACHE_SWITCH = re.compile(
    r"(?<![\w])(?:DISABLE_PROMPT_CACHING=1(?![\w])|CLAUDE_CODE_PROMPT_CACHE_TTL=['\"]?[\w$])")


def marker(name):
    # The reason must begin with a WORD, or a bare dash or colon would read as reasoned (L675). A
    # flag name counts as one, since the commonest reason is the flag that already does the work.
    return re.compile(r"#\s*" + re.escape(name) + r":\s*(--?)?[A-Za-z]")


MARKER = marker("claude-mds-ok")
CACHE_MARKER = marker("prompt-cache-ok")

DECISIONS = (
    ("config", lambda text: SWITCH in text, MARKER,
     "this headless claude launch loads the whole global CLAUDE.md and every lessons index file "
     f"without saying so. Put {SWITCH} on the launch, or a '# claude-mds-ok: <reason>' comment "
     "directly above the statement saying why it keeps the config or how it already excludes it "
     "(claude-config#538)."),
    ("the prompt cache lifetime", lambda text: CACHE_SWITCH.search(text) is not None, CACHE_MARKER,
     "this headless claude launch takes the default prompt cache lifetime without saying so, which "
     "on a subscription writes its prompt to the one hour cache at twice the input price. Put "
     "DISABLE_PROMPT_CACHING=1 (no cache) or CLAUDE_CODE_PROMPT_CACHE_TTL=5m on the launch, or a "
     "'# prompt-cache-ok: <reason>' comment directly above the statement saying why the default "
     "is right (claude-config#1601)."),
)
SKIP_DIRS = {".git", "node_modules", "__pycache__"}


def kind_of(path):
    name = os.path.basename(path)
    if name.startswith("test-"):
        return None
    if name.endswith((".sh", ".bash")):
        return "shell"
    if name.endswith(".py"):
        return "python"
    if "." in name:
        return None
    try:
        with open(path, "rb") as f:
            first = f.readline(200)
    except OSError:
        # Unknown is not "not a script": it could hold a launch, so the caller refuses it (L11).
        return "unreadable"
    if first.startswith(b"#!") and (b"bash" in first or b"/sh" in first):
        return "shell"
    if first.startswith(b"#!") and b"python" in first:
        return "python"
    return None


def files_under(roots):
    for root in roots:
        if os.path.isfile(root):
            yield root
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            for name in sorted(filenames):
                yield os.path.join(dirpath, name)


def is_comment(line):
    return line.lstrip().startswith("#")


def code_part(line):
    """The line without a trailing shell comment, so `echo done  # claude -p` is not a launch."""
    return re.sub(r"\s#.*$", "", line)


def python_statements(text):
    """(first, last) zero based line spans of every statement, or None when the file does not
    parse. Unparsed, a launch is judged on its own line alone, which can only report a decision
    on a neighbouring line as missing: a loud false failure, never a silent pass."""
    try:
        with warnings.catch_warnings():
            # A scanned file's own invalid escapes are its business, not noise in this report.
            warnings.simplefilter("ignore")
            tree = ast.parse(text)
    except (SyntaxError, ValueError):
        return None
    return [(n.lineno - 1, (n.end_lineno or n.lineno) - 1)
            for n in ast.walk(tree) if isinstance(n, ast.stmt)]


def statement_start(lines, i, kind, spans):
    """Index of the first line of the statement containing line i."""
    if kind == "python":
        inside = [s for s in (spans or []) if s[0] <= i <= s[1]]
        # The innermost statement, so a launch inside a function is not judged by the whole def.
        return min(inside, key=lambda s: s[1] - s[0])[0] if inside else i
    while i > 0 and lines[i - 1].rstrip().endswith("\\"):
        i -= 1
    return i


def decides(lines, start, i, col, switched, marker_re):
    """Whether the statement starting at `start` decides, reading only what comes BEFORE the launch
    words at column `col` of line i: anything after them is an argument to claude."""
    if switched("\n".join(lines[start:i] + [lines[i][:col]])):
        return True
    j = start - 1
    while j >= 0 and is_comment(lines[j]):
        if marker_re.search(lines[j]):
            return True
        j -= 1
    return False


def shell_launches(lines):
    """(line, column) of every launch in a shell file, one per line at most: where the program runs
    that is claude, by name, by path, or through a variable the file sets from something naming
    claude, with -p or --print (or an array holding either) after it in the same command."""
    code = ["" if is_comment(line) else code_part(line) for line in lines]
    # The functions that find claude: a body, up to the closing brace at the start of a line, that
    # looks claude up. A variable set from one of them holds claude as surely as one set directly.
    finders, current, body = set(), None, []
    for line in code:
        f = FUNCTION.match(line)
        if f and current is None:
            current, body = f.group(1), [line[f.end():]]
        elif current is not None:
            body.append(line)
        if current is not None and (line.startswith("}") or (f and line.rstrip().endswith("}"))):
            if CLAUDE_FIND.search("\n".join(body)):
                finders.add(current)
            current = None
    value_re = CLAUDE_FIND
    if finders:
        value_re = re.compile(CLAUDE_FIND.pattern + r"|(?<![\w-])(?:"
                              + "|".join(sorted(map(re.escape, finders))) + r")(?![\w-])")
    names, arrays = set(), set()
    for line in code:
        # Every assignment on the line is read, each with what follows it up to the next one.
        starts = list(ASSIGNMENT.finditer(line))
        for k, n in enumerate(starts):
            value = line[n.end():starts[k + 1].start()] if k + 1 < len(starts) else line[n.end():]
            if value_re.search("=" + value):
                names.add(n.group(1))
        for m in ARRAY.finditer(line):
            if PRINT_WORD.search(m.group(2)):
                arrays.add(m.group(1))
    programs = [SHELL_CLAUDE]
    if names:
        programs.append(re.compile(r"\$\{?(?:" + "|".join(sorted(map(re.escape, names))) + r")\}?(?![\w\[])"))
    expands = re.compile(r"\$\{(?:" + "|".join(sorted(map(re.escape, arrays))) + r")\[[@*]\]\}") if arrays else None
    found = []
    for i, line in enumerate(code):
        hits = sorted((m for p in programs for m in p.finditer(line)), key=lambda m: m.start())
        for m in hits:
            rest, j = line[m.end():], i
            # The command runs on over backslash continued lines.
            while rest.rstrip().endswith("\\") and j + 1 < len(code):
                j += 1
                rest = rest.rstrip()[:-1] + " " + code[j]
            end = COMMAND_END.search(rest)
            rest = rest[:end.start()] if end else rest
            if PRINT_WORD.search(rest) or (expands and expands.search(rest)):
                found.append((i, m.start()))
                break
    return found


def _is_claude_item(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value == "claude" or node.value.endswith("/claude")
    if isinstance(node, ast.Name):
        return "claude" in node.id.lower()
    if isinstance(node, ast.Attribute):
        return "claude" in node.attr.lower()
    return False


def python_launches(text, lines):
    """(line, column) of every launch in a Python file: a list or tuple with claude as an item and
    "-p" or "--print" after it. A string is never one, whatever it quotes. A file that will not
    parse is read line by line for the two words as adjacent quoted items instead."""
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            tree = ast.parse(text)
    except (SyntaxError, ValueError):
        return [(i, m.start()) for i, line in enumerate(lines) if not is_comment(line)
                for m in [PY_LAUNCH.search(line)] if m]
    found = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.List, ast.Tuple)):
            continue
        items = node.elts
        for k, item in enumerate(items):
            if _is_claude_item(item) and any(
                    isinstance(e, ast.Constant) and e.value in PY_PRINT for e in items[k + 1:]):
                i = item.lineno - 1
                # The parser's column counts bytes; the decision reads the line as text.
                col = len(lines[i].encode("utf-8")[:item.col_offset].decode("utf-8", "ignore"))
                found.append((i, col))
                break
    return sorted(set(found))


def main(argv):
    if not argv:
        print("usage: headless-claude-config.py <file-or-dir>...", file=sys.stderr)
        return 2
    checked = 0
    bad = {name: [] for name, _, _, _ in DECISIONS}
    for path in files_under(argv):
        kind = kind_of(path)
        if kind is None:
            continue
        if kind == "unreadable":
            print(f"headless-claude-config: could not read {path}, so whether it launches claude "
                  "is unknown. Refusing rather than skipping it.", file=sys.stderr)
            return 2
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError as e:
            print(f"headless-claude-config: could not read {path}: {e}", file=sys.stderr)
            return 2
        lines = text.splitlines()
        launches = shell_launches(lines) if kind == "shell" else python_launches(text, lines)
        spans = python_statements(text) or [] if kind == "python" and launches else None
        for i, col in launches:
            checked += 1
            start = statement_start(lines, i, kind, spans)
            for name, switched, marker_re, _ in DECISIONS:
                if not decides(lines, start, i, col, switched, marker_re):
                    bad[name].append(f"{path}:{i + 1}")
    if checked == 0:
        print("headless-claude-config: found no headless claude launch at all in "
              + " ".join(argv) + ", so there was nothing to check. Refusing to call that a pass: "
              "the scan may have stopped recognising them.")
        return 3
    for name, _, _, message in DECISIONS:
        for where in bad[name]:
            print(f"{where}: {message}")
    print(f"headless-claude-config: checked {checked} headless claude launches, "
          + ", ".join(f"{len(bad[name])} without a decision about {name}"
                      for name, _, _, _ in DECISIONS) + ".")
    return 1 if any(bad.values()) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
