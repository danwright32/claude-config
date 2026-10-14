#!/usr/bin/env python3
"""word-position-scan.py: fail on a hook that decides which gh or git subcommand a command runs by
WORD POSITION instead of asking the one reading of it (claude-config#1188).

  word-position-scan.py <hooks folder>

Prints each offending line as `<file>:<line>: <what it does>` and exits 1 when there is any, 0 when
there is none, 2 when the folder holds no hook to scan (a scan of nothing is not a pass, L98).

Which subcommand a gh or git command runs is read in ONE place, lib/shell-words.py (gh_path,
git_path, tool_read), asked by the bash gates through lib/push-scope.sh (ps_runs_gh, ps_runs_git,
ps_runs_at) and by the python ones through tool_command and gh_command. Before #1188 each gate kept
its own reading, gh then pr then create as the first three words, git then a few options then push,
and the copies disagreed: a flag written in front of gh's subcommand (`gh -R o/x pr create`) walked
a pull request past the closing keyword and push scope checks while the merge gates read it (#1186),
and env or sudo in front of git walked a push past every push gate while rtk did not. A new hand
written copy is how the next disagreement starts (L613), so this scan refuses one.

What counts as a hand written reading, in a hook's code (comments are skipped):
  - a word compared with the name gh or git: `[ "${w[0]##*/}" = "gh" ]`, `tok == "git"`,
    `.endswith("/gh")`, `split("/")[-1] != "git"`, a case pattern `gh)` or `*/git)`;
  - a pattern naming gh or git then whitespace then a word: `gh[[:space:]]+pr`, `git\\s+push`;
  - a list of subcommand words matched against a slice: `["issue", "create"]`, `w[1] in ("pr", "api")`.

A line the scan must allow carries `gh-reader:` and a reason on the same line: the shared reader's
own lines, and the crude readings each caller keeps for when the shared reader cannot be loaded,
which see more commands than are there, never fewer (L42). The marker is accepted only in the files
named in ALLOWED, so it cannot spread to a gate as a way past the scan.
"""
import os
import re
import sys

PROGRAM = r"(?:gh|git)"
RULES = [
    (re.compile(r"""(?:==|!=|=)\s*["']?""" + PROGRAM + r"""["']?\s*(?:\]|\)|$|:|and\b|or\b|;)"""),
     "compares a word with the program's name"),
    (re.compile(r"""endswith\(\s*["']/""" + PROGRAM + r"""["']"""), "compares a word with the program's name"),
    (re.compile(r"""(?:^|[\s|(])(?:\*/)?""" + PROGRAM + r"""\)"""), "matches the program's name as a case pattern"),
    (re.compile(PROGRAM + r"""(?:\[\[:space:\]\]|\\s|\[ \\t\]| )[+*]\s*\(?[a-z]"""),
     "matches the program then a subcommand in a pattern"),
    (re.compile(r"""\[\s*["'](?:pr|issue|api|run|repo|push|commit|add)["']\s*,\s*["']"""),
     "matches a list of subcommand words"),
    (re.compile(r"""\]\s+in\s*\(\s*["'](?:pr|issue|api|run|push|commit|add)["']\s*,"""),
     "matches a list of subcommand words"),
]
MARKER = re.compile(r"gh-reader:\s*\S")
# The files a `gh-reader:` line may sit in, each for a stated reason: the one reading itself, and
# each crude reading kept for when it cannot be loaded.
ALLOWED = {
    "lib/shell-words.py",        # the one reading of gh and git
    "lib/push-scope.sh",         # its bash entry (ps__runs_tool), and the add reader's crude reading
    "gh_issue_scan.py",          # the issue gates' crude reading
    "payload-write-gate.sh",     # the payload write gate's crude reading
}
# This scan names what it looks for, so it does not read itself.
SELF = "lib/word-position-scan.py"
SKIP_DIRS = {"__pycache__", "node_modules", ".git"}


def code_of(line):
    """The line without a comment that starts it: a hook's comments name commands all the time."""
    stripped = line.lstrip()
    if stripped.startswith("#"):
        return ""
    return line


def hooks_in(folder):
    for root, dirs, files in os.walk(folder):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            if name.startswith("test-") or not (name.endswith(".sh") or name.endswith(".py")):
                continue
            yield os.path.join(root, name)


def scan(folder):
    findings, seen = [], 0
    for path in hooks_in(folder):
        rel = os.path.relpath(path, folder)
        seen += 1
        if rel == SELF:
            continue
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError as exc:
            findings.append(f"{rel}: could not be read, so it could not be checked: {exc}")
            continue
        for n, line in enumerate(text.splitlines(), 1):
            code = code_of(line)
            if not code:
                continue
            for rule, what in RULES:
                if not rule.search(code):
                    continue
                if MARKER.search(code):
                    if rel in ALLOWED:
                        break
                    findings.append(f"{rel}:{n}: carries gh-reader: outside the files allowed it: {line.strip()}")
                    break
                findings.append(f"{rel}:{n}: {what}: {line.strip()}")
                break
    return findings, seen


def main(argv):
    if len(argv) != 2:
        print("usage: word-position-scan.py <hooks folder>")
        return 2
    findings, seen = scan(argv[1])
    if not seen:
        print(f"word-position-scan: {argv[1]} holds no hook, so there was nothing to check. Refusing to pass it.")
        return 2
    for f in findings:
        print(f)
    if findings:
        print(f"WORD-POSITION hooks={seen} findings={len(findings)}: read the subcommand with ps_runs_gh, "
              "ps_runs_git or ps_runs_at (lib/push-scope.sh), or tool_command (lib/shell-words.py).")
        return 1
    print(f"WORD-POSITION hooks={seen} findings=0")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
