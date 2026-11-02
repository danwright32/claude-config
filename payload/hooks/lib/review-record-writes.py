#!/usr/bin/env python3
"""review-record-writes.py: can this Bash command write the lessons review's read records?

pr-review-gate.sh refuses a shell command that could forge the records of whose merge or push was
shown the review's findings: the typed helper key's folder, the secret those records are kept under,
a review's read keys file, and the functions that write or reach them (claude-config#1700, #1719).
It used to refuse every command whose text merely NAMED one of them, so an edit to its own suite
that wrote the name into a test, and a read only `gh pr diff | grep`, were refused like a forgery
(claude-config#2050). This is the judgement between the two, asked only once the gate has seen a
name in the command.

  stdin: the command, as typed (newlines kept)
  exit 0: it cannot write those records, as far as this reading can tell
  exit 2: it can, or this reading cannot tell; stdout holds a clause saying which, to follow
          "this command" in the refusal
  any other exit: it could not be judged, which the gate refuses too (L490)

The command is read by lib/shell-words.py, the one reader every gate shares, so a name counts where
the shell would see it: in a command's own words, in an assignment, in a string a shell or eval is
handed, in a heredoc body. A name in a comment is nobody's. Every name found is judged by where it
stands, and anything this file has no rule for is refused, never passed:

  - Anywhere in a command that also names the records' own home (.claude/state, AI_REVIEW_STATE_DIR):
    refused, whatever it does there.
  - In a command that hands text to something no gate can read (a shell reading its input, a script
    run by its path, a sourced file, a variable as a shell's -c string) or holds a process
    substitution: refused, since what runs there cannot be seen.
  - As the command's own name or in an assignment: refused. That is calling a function, or keeping
    its name to call it by. A wrapper (bash -c, eval, env -S, find -exec) is no program that only
    reads, so the next rule refuses a name handed to one, and what it runs is judged as commands.
  - A function's name (ar_..., the only spelling the library defines) as an argument: allowed only to
    a program that does no more than read or print its arguments (grep, echo, cat, ...; READERS).
  - Any other spelling (the folder, the secret, a read keys file): allowed only as the one pattern of
    a grep that reads nothing but its input, so no file of the records can be named to it.
  - In a heredoc body: allowed only in a quoted body fed to cat or tee, or to python with nothing in
    the body that can start a process; and only a function's name, never a path, which python could
    open.
  - Beside a shell startup file or the installed hooks folder (where text runs later): refused unless
    every command only reads.

This is a tripwire against a session writing such a command, not a sandbox: text built to evade it
can, as a command built to evade the name match always could (helper"-"keys). And it judges one
command: a file written now and run by a later command that names nothing is the route the Edit and
Write tools have always offered, and no Bash hook sees either.
"""
import importlib.util
import os
import re
import shlex
import sys

# Loaded by path, which would leave a bytecode cache in the hooks' lib/, installed and synced (#1017).
sys.dont_write_bytecode = True
_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("shell_words", os.path.join(_here, "shell-words.py"))
sw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sw)

# The names, as the gate's own fast match spells them, in any case.
RECORD = re.compile(r"helper[-_]key|helper[-_]secret|readkeys", re.I)
# A function or variable of the library: an identifier starting ar_ (ar_readkeys_issue,
# ar__helper_secret_file, AR_HELPER_SECRET_PAUSE). A name inside one is a function's name.
IDENT = re.compile(r"(?<![A-Za-z0-9_])ar_[A-Za-z0-9_]*", re.I)
# Where the records live: naming it beside a record name is never allowed.
HOME = re.compile(r"\.claude/state|ai_review_state_dir", re.I)
# Where text written now runs later: a shell's startup files and the installed hooks.
LATER = re.compile(r"\.claude/hooks|(?<![A-Za-z0-9_])\.(?:zshrc|zshenv|zprofile|zlogin|bashrc|bash_profile|bash_login|profile)\b",
                   re.I)
# Programs that do no more with their arguments than read or print them. Left out on purpose, for an
# option that runs a command: git (-c core.pager=, grep -O), rg (--pre), sort (--compress-program),
# less and more (+! and LESSOPEN), and gh, which runs git and aliases.
READERS = {"grep", "egrep", "fgrep", "echo", "printf", "cat", "head", "tail", "wc", "uniq", "cut", "ls",
           ":", "true"}
GREPS = {"grep", "egrep", "fgrep"}
# grep options that neither take a value nor name a file or a directory to search.
GREP_SAFE_SHORT = set("nicvwxohHEFGqslL")
GREP_SAFE_LONG = {"--line-number", "--ignore-case", "--count", "--invert-match", "--word-regexp",
                  "--line-regexp", "--only-matching", "--no-filename", "--with-filename",
                  "--extended-regexp", "--fixed-strings", "--basic-regexp", "--quiet", "--silent",
                  "--files-with-matches", "--files-without-match", "--color", "--colour"}
# What a python body may not hold to count as only editing text: anything that starts a process or
# reaches a module that can.
PY_SPAWN = re.compile(
    r"__|\._|(?<![A-Za-z0-9_])(?:subprocess|os|sys|pty|ctypes|multiprocessing|importlib|runpy|asyncio|"
    r"signal|socket|builtins|enum|functools|reprlib|exec|eval|compile|getattr|setattr|globals|locals|"
    r"vars|breakpoint|system|popen|spawn|fork|modules)(?![A-Za-z0-9_])")
PY_IMPORT = re.compile(r"^\s*(?:import\s+([A-Za-z0-9_.,\s]+)|from\s+([A-Za-z0-9_.]+)\s+import\b)", re.M)
PY_SAFE_MODULES = {"re", "json", "textwrap", "difflib"}
PYTHONS = re.compile(r"python(?:3(?:\.\d+)?)?\Z")


class Refuse(Exception):
    pass


def names(text):
    return bool(text) and RECORD.search(text) is not None


def only_functions(text):
    """Every record name in text sits inside an ar_ identifier."""
    return not names(IDENT.sub(" ", text))


def program(word):
    return word.split("/")[-1]


def words_of(rest):
    try:
        return shlex.split(rest, posix=True)
    except ValueError:
        raise Refuse("holds a name of those records in text that cannot be read")


def grep_reads_only_input(words):
    """A grep whose one operand is its pattern, so it reads nothing but its input."""
    operands = []
    for w in words[1:]:
        if w.startswith("--"):
            if w.split("=", 1)[0] not in GREP_SAFE_LONG:
                return False
        elif w.startswith("-") and len(w) > 1:
            if not set(w[1:]) <= GREP_SAFE_SHORT:
                return False
        else:
            operands.append(w)
    return len(operands) == 1 and not any(c in operands[0] for c in "<>")


def judge_record(text, rest, assigns):
    if names(assigns):
        raise Refuse("sets a variable named for those records")
    # A wrapper (bash -c, eval, env -S, find -exec, parallel) needs no rule of its own: its program is
    # never one that only reads, so a name in its words is refused below, and the commands it runs are
    # records of their own, judged in turn.
    words = words_of(rest)
    if not words:
        if names(text):
            raise Refuse("holds a name of those records where this reading cannot tell what runs it")
        return
    if names(words[0]):
        raise Refuse("runs %s, one of the functions that write or reach those records" % words[0])
    prog = program(words[0])
    seen = False
    for w in words[1:]:
        if not names(w):
            continue
        seen = True
        if "(" in w or "`" in w:
            raise Refuse("holds a name of those records inside something that runs it")
        if only_functions(w):
            if prog in READERS:
                continue
            raise Refuse("hands %s, a function that writes or reaches those records, to %s, which can do "
                         "more than read it" % (IDENT.search(w).group(0), prog))
        if prog in GREPS and grep_reads_only_input(words):
            continue
        raise Refuse("names the folder, secret or read keys file those records are kept in, as an "
                     "argument to %s" % prog)
    if names(text) and not seen:
        raise Refuse("holds a name of those records where this reading cannot tell what runs it")


def judge_body(quoted, before, body):
    if not names(body):
        return
    if not quoted:
        raise Refuse("names those records in a heredoc the shell expands, so whatever it holds runs")
    if not only_functions(body):
        raise Refuse("names the folder, secret or read keys file those records are kept in, in a heredoc")
    rest, _, _ = sw.program_field(before)
    words = words_of(rest)
    prog = program(words[0]) if words else ""
    if prog in ("cat", "tee"):
        return
    if PYTHONS.match(prog):
        modules = set()
        for a, b in PY_IMPORT.findall(body):
            for m in re.split(r"[\s,]+", (a or b).strip()):
                if m:
                    modules.add(m.split(".")[0])
        if modules <= PY_SAFE_MODULES and not PY_SPAWN.search(body):
            return
        raise Refuse("feeds a heredoc naming those records to python code that can start a process")
    raise Refuse("feeds a heredoc naming those records to %s, which can run it" % (prog or "a command"))


def judge(cmd):
    if not names(cmd):
        return
    if HOME.search(cmd):
        raise Refuse("names those records and the folder they are kept in")
    if "<(" in cmd or ">(" in cmd:
        raise Refuse("names those records beside a process substitution, whose commands no gate reads")
    records, crude = sw._records(cmd, "", 0)
    if crude:
        raise Refuse("names those records in a command holding a quote or substitution that never closes")
    heredocs = []
    sw.commands(cmd, "", heredocs)
    for _, text, wrap, rest, assigns, _, _ in records:
        if "\x1d" in wrap:
            raise Refuse("names those records beside %s, which runs commands no gate can read (%s)"
                         % tuple(wrap.split("\x1d", 1)))
    readers_only = not heredocs
    for _, text, wrap, rest, assigns, _, _ in records:
        judge_record(text, rest, assigns)
        words = words_of(rest)
        if wrap or not words or program(words[0]) not in READERS or any(
                w.lstrip("0123456789&").startswith(">") for w in words):
            readers_only = False
    for quoted, before, body in heredocs:
        judge_body(quoted, before, body)
    if LATER.search(cmd) and not readers_only:
        raise Refuse("names those records and a file whose text runs later (a shell startup file or the "
                     "installed hooks)")


def main():
    cmd = sys.stdin.buffer.read().decode("utf-8", "replace")
    try:
        judge(cmd)
    except Refuse as e:
        sys.stdout.write(str(e))
        return 2
    except sw.Unreadable:
        sys.stdout.write("names those records in a command that cannot be read")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
