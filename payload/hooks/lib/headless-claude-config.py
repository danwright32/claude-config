#!/usr/bin/env python3
"""Every headless `claude -p` launch must decide what config it loads (claude-config#538).

A headless run inherits the whole global CLAUDE.md and every lessons index file unless something
says otherwise, and nothing in the call shows it: measured 2026-09-23, the findings harvester took
64,868 input tokens with them and 29,663 without, on every harvest. So each launch this finds must
either switch the config off on the launch itself (CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 anywhere in the
statement) or carry a `# claude-mds-ok: <reason>` comment in the comment block directly above the
statement, saying why it keeps the config or how it already excludes it.

Launches are FOUND by scanning, never listed by hand (L96): in shell, `claude -p` or
`claude --print` as a command on a line that is not a comment; in Python, the two words as adjacent
quoted list items, which is how an argv is built there. Python prose is never matched, so a
docstring naming the command is not a launch. Test suites (`test-*`) are skipped: their stubs and
fixtures are not launches, and a suite must never reach the real model (L2).

Usage: headless-claude-config.py <file-or-dir>...
Exit 0 every launch decides; 1 at least one does not (each named as path:line); 3 no launch found
at all, which is refused rather than passed, because a scan that stopped matching would otherwise
report every tree clean (L98); 2 bad usage.
"""
import os
import re
import sys

SHELL_LAUNCH = re.compile(r"(?<![\w./-])claude\s+(-p|--print)(?![\w-])")
PY_LAUNCH = re.compile(r"""['"]claude['"]\s*,\s*['"](-p|--print)['"]""")
SWITCH = "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1"
# The reason must begin with a WORD, or a bare dash or colon would read as reasoned (L675). A flag
# name counts as one, since the commonest reason is the flag that already does the excluding.
MARKER = re.compile(r"#\s*claude-mds-ok:\s*(--?)?[A-Za-z]")
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


def statement_start(lines, i, kind):
    """Index of the first line of the statement containing line i (backslash continuations)."""
    if kind != "shell":
        return i
    while i > 0 and lines[i - 1].rstrip().endswith("\\"):
        i -= 1
    return i


def decides(lines, i, kind):
    start = statement_start(lines, i, kind)
    if any(SWITCH in lines[j] for j in range(start, i + 1)):
        return True
    j = start - 1
    while j >= 0 and is_comment(lines[j]):
        if MARKER.search(lines[j]):
            return True
        j -= 1
    return False


def main(argv):
    if not argv:
        print("usage: headless-claude-config.py <file-or-dir>...", file=sys.stderr)
        return 2
    checked = 0
    bad = []
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
                lines = f.read().splitlines()
        except OSError as e:
            print(f"headless-claude-config: could not read {path}: {e}", file=sys.stderr)
            return 2
        pattern = SHELL_LAUNCH if kind == "shell" else PY_LAUNCH
        for i, line in enumerate(lines):
            if is_comment(line):
                continue
            if not pattern.search(code_part(line) if kind == "shell" else line):
                continue
            checked += 1
            if not decides(lines, i, kind):
                bad.append(f"{path}:{i + 1}")
    if checked == 0:
        print("headless-claude-config: found no headless claude launch at all in "
              + " ".join(argv) + ", so there was nothing to check. Refusing to call that a pass: "
              "the scan may have stopped recognising them.")
        return 3
    for where in bad:
        print(f"{where}: this headless claude launch loads the whole global CLAUDE.md and every "
              f"lessons index file without saying so. Put {SWITCH} on the launch, or a "
              "'# claude-mds-ok: <reason>' comment directly above the statement saying why it "
              "keeps the config or how it already excludes it (claude-config#538).")
    print(f"headless-claude-config: checked {checked} headless claude launches, "
          f"{len(bad)} without a decision about config.")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
