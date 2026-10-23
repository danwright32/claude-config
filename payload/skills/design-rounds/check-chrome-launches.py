#!/usr/bin/env python3
"""check-chrome-launches.py <folder>...: every place under these folders that starts headless Chrome
does it through headless-dom.sh (claude-config#1537), and prints each one that does not.

Chrome copies its whole app bundle into a per user code sign clone folder each time it starts, and
removes the copy only on a quit it finishes itself. A run that is killed, timed out or crashes leaves
its copy behind: 288 of them gathered on Daniels-MacBook-Pro-2 between 2026-10-20 and 2026-10-22.
headless-dom.sh starts every one of them with the copy switched off, so a launch that goes around it
is the next leak. This finds such a launch by what the code does (L247), in three shapes:

  1. a command line passing Chrome's headless switch as an argument of its own (a shell word, or a
     string in a Python or JavaScript argument list) that does not name headless-dom.sh on the same
     command. A shell command continued over backslashed lines is read as one.
  2. a Playwright launch (launch, launchPersistentContext, launchServer) whose own arguments pick a
     real Chrome, by channel or executable path, without naming headless-dom.sh: capture-web.mjs's
     chromeLaunchOptions is the one place that does it. Playwright's own Chromium, launched with
     neither, makes no copy (measured 2026-10-22, Playwright 1.63 headless shell, killed mid run),
     so a launch of it is not one.
  3. an executable path handed to a browser anywhere in JavaScript or TypeScript that does not name
     headless-dom.sh on its line, which is how a launch's options built elsewhere are still seen.

What it cannot see: a real Chrome chosen by channel in an options object built away from the launch
call, or Chrome's path held in a variable and run under another name. The launch helpers are what
make those unneeded; this is the check that a new launch was not written by hand beside them (L613).

Comment lines are not read. Exit 0 when nothing is found, 1 when something is (each printed as
file:line, the shape, and the line), 2 when a folder cannot be read.
"""
import os
import re
import sys

HEADLESS = "--head" "less"
CODE = {".sh", ".bash", ".zsh", ".py", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts"}
JS = {".js", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts"}
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".claude", ".build", "DerivedData"}
LIMIT = 2_000_000
HELPER = re.compile(r"headless[-_]?dom", re.I)
# The switch as an argument of its own: a bare shell word, or a whole quoted string, never a word
# inside a longer string (a test's expected argument list says the switch without running anything).
SWITCH = re.compile(r"(?:^|[\s(\[,=])(?:" + re.escape(HEADLESS) + r"(?:=\S*)?(?=$|[\s;|&)\]\\])"
                    r"|\"" + re.escape(HEADLESS) + r"(?:=[^\"\s]*)?\"|'" + re.escape(HEADLESS) + r"(?:=[^'\s]*)?')")
LAUNCH = re.compile(r"\.(launch|launchPersistentContext|launchServer)\s*\(")
PICKS_CHROME_JS = re.compile(r"\b(channel|executablePath)\s*:")
PICKS_CHROME_PY = re.compile(r"\b(channel|executable_path)\s*=")
EXEC_PATH = re.compile(r"\bexecutablePath\s*:")


def is_comment(line):
    s = line.lstrip()
    return s.startswith("#") or s.startswith("//") or s.startswith("/*") or s.startswith("*")


def is_code(path):
    ext = os.path.splitext(path)[1]
    if ext in CODE:
        return True
    if ext:
        return False
    try:
        with open(path, "rb") as fh:
            return fh.read(2) == b"#!"
    except OSError:
        return False


def logical_lines(lines, shell):
    """(first line number, text) for each command, a shell one joined over its backslashed lines."""
    out, i = [], 0
    while i < len(lines):
        start, text = i + 1, lines[i]
        while shell and text.rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            text = text.rstrip()[:-1] + " " + lines[i]
        out.append((start, text))
        i += 1
    return out


def call_args(src, at):
    """The text of the call whose opening bracket is at src[at], to its matching close, strings skipped
    over whole so a bracket inside one is not counted."""
    depth, i, quote = 0, at, None
    while i < len(src):
        c = src[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'`":
            quote = c
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                return src[at:i + 1]
        i += 1
    return src[at:]


def scan_file(path, rel):
    found = []
    ext = os.path.splitext(path)[1]
    try:
        if os.path.getsize(path) > LIMIT:
            return found
        with open(path, encoding="utf-8", errors="replace") as fh:
            src = fh.read()
    except OSError:
        return found
    if HEADLESS not in src and "launch" not in src and "executablePath" not in src:
        return found
    lines = src.split("\n")
    shell = ext in {".sh", ".bash", ".zsh"} or (not ext and lines and "sh" in lines[0])
    for n, text in logical_lines(lines, shell):
        if is_comment(text):
            continue
        if SWITCH.search(text) and not HELPER.search(text):
            found.append((rel, n, "runs headless Chrome without headless-dom.sh", lines[n - 1].strip()))
    js, py = ext in JS, ext == ".py"
    flagged = set()
    if js or py:
        starts = [0]
        for line in lines:
            starts.append(starts[-1] + len(line) + 1)
        for m in LAUNCH.finditer(src):
            n = next(k for k in range(len(starts)) if starts[k + 1] > m.start()) + 1
            if is_comment(lines[n - 1]):
                continue
            args = call_args(src, m.end() - 1)
            picks = (PICKS_CHROME_JS if js else PICKS_CHROME_PY).search(args)
            if picks and not HELPER.search(args):
                flagged.update(range(n, n + args.count("\n") + 1))
                found.append((rel, n, "launches a real Chrome through Playwright without headless-dom.sh "
                              "(by %s)" % picks.group(1), lines[n - 1].strip()))
    if js:
        for n, line in enumerate(lines, 1):
            if not is_comment(line) and EXEC_PATH.search(line) and not HELPER.search(line) and n not in flagged:
                found.append((rel, n, "hands a browser an executable path that is not headless-dom.sh", line.strip()))
    return found


def scan(folders):
    found = []
    for folder in folders:
        if not os.path.isdir(folder):
            raise OSError("%s is not a folder" % folder)
        for root, dirs, files in os.walk(folder):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
            for name in sorted(files):
                path = os.path.join(root, name)
                if os.path.islink(path) or not is_code(path):
                    continue
                found += scan_file(path, os.path.relpath(path, folder))
    return found


def main(argv):
    if len(argv) < 2:
        print("usage: check-chrome-launches.py <folder>...", file=sys.stderr)
        return 2
    try:
        found = scan(argv[1:])
    except OSError as err:
        print("check-chrome-launches.py: could not scan: %s" % err, file=sys.stderr)
        return 2
    for rel, n, what, line in found:
        print("%s:%d: %s: %s" % (rel, n, what, line[:200]))
    if found:
        print("Start it through headless-dom.sh (HEADLESS_DOM_CHROME=<chrome> bash headless-dom.sh <arguments>), "
              "or for Playwright through capture-web.mjs's launchChrome, so a killed run leaves no copy of "
              "Chrome behind (claude-config#1537).")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
