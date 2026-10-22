"""Shared command scanner for the `gh issue create` completeness gates.

Two PreToolUse gates need the same hard part: given the raw Bash command about to
run, find the real `gh issue create` invocations in it and read their flags. That
parsing is fiddly (quotes, heredocs, line continuations, shell operators, env
assignment prefixes) and was written once for the milestone gate. The priority
gate needs it identically, so it lives here rather than as a second copy that
drifts: a fix to the splitting logic must reach both gates at once.

Every gate keeps its own rule and its own message. This module only answers "which
creates are in this command, what flags do they carry, and was each one waived", the same for
the other gh commands that post a body from a file (scan_gh_in_context, claude-config#1435), and
"which files does the command write, from text it shows, and where" (file_writes, claude-config#1246,
file_writes_in_context, claude-config#1436).

Both gates fail OPEN: anything unparseable is not ours to judge. These are
completeness gates, not safety gates, and a false block on a command we merely
could not read would teach the override habit.
"""

import glob
import importlib.util
import itertools
import os
import re
import shlex
import sys

# Which gh subcommand a command runs is read by lib/shell-words.py (gh_command), the one reading of gh
# every gate asks (claude-config#1188): past assignments, rtk, env and sudo, and past gh's flags
# written in front of the subcommand (`gh -R o/x issue create`, `gh issue -R o/x create`), which a
# read of the first three words missed. Loaded by its path, beside this file, never by name.
sys.dont_write_bytecode = True

# The gh commands that post a description or a comment read from --body-file, each as (sub, act),
# whose body file the gate reads (claude-config#1435). gh refuses a missing file itself, but posts an
# empty one, which on an edit blanks the description already there. Left out on purpose: gh pr merge
# (its body file is a commit message, which may be empty), gh pr review (gh refuses a blank comment
# itself, and an approval may have none) and gh release (its notes file, which may be empty).
CREATE = ("issue", "create")
BODY_FILE_COMMANDS = {CREATE, ("issue", "edit"), ("issue", "comment"),
                      ("pr", "create"), ("pr", "edit"), ("pr", "comment")}

try:
    _spec = importlib.util.spec_from_file_location(
        "shell_words", os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "shell-words.py"))
    _sw = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_sw)
    gh_command = _sw.gh_command
    # A command run from a string by a shell, eval or env -S (claude-config#1478): (wrapper, string,
    # why), or None. Its string is scanned as a command line of its own.
    wrapped_words, MAX_DEPTH = _sw.wrapped_words, _sw.MAX_DEPTH
except Exception:
    def wrapped_words(words):
        return None  # with no reader, the crude reading below finds a create wherever gh stands
    MAX_DEPTH = 0
    # With no reader, any command naming gh runs it, and a gated subcommand and action anywhere after
    # gh are the ones it runs: the reading that sees more commands, never fewer, so a gate asks rather
    # than misses. It stands down only on a word gh would take as a different subcommand or action, one
    # outside the gated pairs that no flag in front of it can be taking as a value. The flags written in
    # front of the action are the action's own, as gh reads them (claude-config#1449: dropping them let
    # `gh issue --body-file empty.md edit 5` past the body file rule, and refused `gh issue -m M create`).
    def gh_command(words):
        names = [w.split("/")[-1] for w in words]
        if "gh" not in names:  # gh-reader: the crude reading, when there is no other
            return None
        subs = {s for s, _ in BODY_FILE_COMMANDS}
        front, sub, prev = [], None, ""
        for k in range(names.index("gh") + 1, len(words)):  # gh-reader: the crude reading, when there is no other
            w = words[k]
            if (sub, w) in BODY_FILE_COMMANDS:
                return (sub, w, front, list(words[k + 1:]))
            if sub is None and w in subs:
                sub = w
            elif w.startswith("-") and len(w) > 1:
                front.append(w)
            elif prev.startswith("-") and len(prev) > 1 and "=" not in prev and (prev.startswith("--") or len(prev) == 2):
                front.append(w)  # the value of the flag before it
            else:
                return None  # a subcommand or action of gh's that no gate here reads
            prev = w
        return None

OPERATORS = {"&&", "||", ";", "|", "&", "(", ")", "{", "}", "\n"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# Flags that make `gh issue create` file nothing, so it is not a create to gate.
#
# `--help` prints the help text. `--web` hands off to the browser form, where the
# milestone and label pickers are on screen and a person completes the issue, so
# nothing can land incomplete without someone looking at it.
#
# The rest of the flags all end in a filed issue: `--editor` and `--recover` open an
# editor or resume a failed run, then file. Swept 2026-07-30 against `gh issue create
# --help` rather than guessed, because a gate that refuses harmless commands is how
# the habit of reaching for an override gets learned.
NON_FILING_FLAGS = {"--help", "-h", "--web", "-w"}


def normalize(cmd):
    """Make command boundaries visible to the lexer, quote awarely.

    A plain newline starts a new command, so it becomes ';'. A backslash before a
    newline continues one command, so it becomes a space. A heredoc body is data,
    not commands, so it is dropped whole. Text inside quotes is copied untouched.

    Without this the gate saw only the first line of a multi-line command: a
    newline is plain whitespace to shlex, so a create on line 3 was invisible.
    """
    out = []
    i, n = 0, len(cmd)
    quote = None
    while i < n:
        c = cmd[i]

        if quote:
            if c == "\\" and quote == '"' and i + 1 < n:
                out.append(c)
                out.append(cmd[i + 1])
                i += 2
                continue
            out.append(c)
            if c == quote:
                quote = None
            i += 1
            continue

        if c == "\\" and i + 1 < n:
            if cmd[i + 1] == "\n":
                out.append(" ")  # line continuation: one logical command
            else:
                out.append(c)
                out.append(cmd[i + 1])
            i += 2
            continue

        if c in ("'", '"'):
            quote = c
            out.append(c)
            i += 1
            continue

        if c == "\n":
            out.append(" ; ")
            i += 1
            continue

        if cmd.startswith("<<", i) and not cmd.startswith("<<<", i):
            j = i + 2
            if j < n and cmd[j] == "-":
                j += 1
            while j < n and cmd[j] in " \t":
                j += 1
            q = None
            if j < n and cmd[j] in ("'", '"'):
                q = cmd[j]
                j += 1
            start = j
            while j < n and (cmd[j] != q if q else cmd[j] not in " \t\n;&|)"):
                j += 1
            delim = cmd[start:j]
            if q and j < n:
                j += 1
            if not delim:
                out.append(c)
                i += 1
                continue
            # Skip the body, up to and including the line that closes it.
            k = cmd.find("\n", j)
            if k == -1:
                i = n
            else:
                k += 1
                while k < n:
                    e = cmd.find("\n", k)
                    line = cmd[k : (e if e != -1 else n)]
                    if line.strip() == delim:
                        k = (e + 1) if e != -1 else n
                        break
                    if e == -1:
                        k = n
                        break
                    k = e + 1
                i = k
            out.append(" ; ")
            continue

        out.append(c)
        i += 1
    return "".join(out)


def _is_operator(tok):
    return tok in OPERATORS or set(tok) <= set("&|;()")


class Unreadable(Exception):
    """The command could not be tokenized, so no gate may judge it."""


# ---- where each create runs: what the command sets before it (claude-config#1416) ----
#
# A --body-file is read the way the shell will read it, so a path through a variable or a relative
# path needs what the command did before the create: the variables it set and the directory it cd'd
# to. Shell variables do not carry from one Bash call to the next, so a variable the command does not
# set itself, and the environment it starts with does not hold, is empty when the create runs.
SET_WORDS = {"export", "declare", "typeset", "local", "readonly"}
CD_WORDS = {"cd", "pushd"}
VARIABLE = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*])\}|([A-Za-z_][A-Za-z0-9_]*|[0-9@*]))")
POSITIONAL = re.compile(r"^(?:[0-9]+|[@*])$")
# Options of `read` that take a value, so the word after one is not a variable it sets.
READ_VALUE_OPTIONS = {"-a", "-d", "-i", "-n", "-N", "-p", "-t", "-u"}
# What a variable expands to when the command gives it a value only as it runs: a for or read loop's
# variable, a function's positional parameter. A path holding it is a pattern (RUNTIME stands for
# any run of characters within one path segment), never a path, and never a character in a real one.
RUNTIME = "\x00"


def runtime_pattern(path):
    """The glob a path holding RUNTIME stands for, everything else in it matched literally."""
    return "*".join(glob.escape(piece) for piece in path.split(RUNTIME))


# How many directories down a value filled in as the command runs may reach (claude-config#1436): a
# loop over `a/x b/y` fills one path segment with two. Bounded, because each level is another listing
# and a value at the start of a path under home would otherwise walk the whole tree.
RUNTIME_DEPTH = 3


def runtime_patterns(path):
    """The globs a path holding RUNTIME stands for, shallowest first: each RUNTIME as any run of
    characters, then as runs spanning up to RUNTIME_DEPTH more directories between them all."""
    pieces = [glob.escape(piece) for piece in path.split(RUNTIME)]
    holes = len(pieces) - 1
    for total in range(RUNTIME_DEPTH + 1):
        for extra in itertools.product(range(total + 1), repeat=holes):
            if sum(extra) == total:
                out = pieces[0]
                for k, piece in enumerate(pieces[1:]):
                    out += "*" + "/*" * extra[k] + piece
                yield out


class Place:
    """Where a create runs: the variables the command set before it, and its working directory.

    vars maps a name to its value, or to None when it was set from something only running the
    command can tell (a substitution). cwd is None once a cd the gate cannot follow has run, or
    when the directory the command starts in was never given. environ is what the command starts with.
    start is the directory the command starts in, so a reader can walk the command again from there
    (file_writes_in_context). previous is where `cd -` goes back to and stack is pushd's, each None or
    holding None where the command does not show it (claude-config#1436).
    """

    def __init__(self, cwd, environ, variables=None, start=None, previous=None, stack=None):
        self.cwd = cwd
        self.environ = environ
        self.vars = dict(variables or {})
        self.start = cwd if start is None else start
        self.previous = previous
        self.stack = list(stack or [])

    def copy(self):
        return Place(self.cwd, self.environ, self.vars, self.start, self.previous, self.stack)

    def move(self, to):
        """A cd: where it leaves the command, remembering where `cd -` goes back to."""
        self.previous, self.cwd = self.cwd, to


# Why a variable the command does not set is empty where it runs. The environment the hook is given is
# the one every Bash call starts from: Claude Code's shell snapshot, sourced before each call, sets
# PATH and no other variable (measured 2026-10-20), and a profile's exports reach Claude Code itself,
# so the hook and the call both hold them. What neither holds is a variable a profile sets without
# export, or one set in an earlier call, so the gate cannot learn it and refuses (claude-config#1436).
UNSET = ("$%s is not set in this command, nor in the environment every Bash call starts from (a "
         "variable set in an earlier Bash call, or in a shell profile without export, is gone by this "
         "one); if it is set where the command runs, re-run with SKIP_BODY_FILE_CHECK=1")


def _lookup(name, place):
    if POSITIONAL.match(name):
        return RUNTIME, None  # a function's or script's arguments, given as it is called
    if name in place.vars:
        if place.vars[name] is None:
            return None, "$%s is set in this command from something the gate cannot read" % name
        return place.vars[name], None
    if name in place.environ:
        return place.environ[name], None
    return None, UNSET % name


def expand(word, place):
    """A word as the shell would expand it: (value, None), or (None, why it cannot be told).

    Only what needs nothing run: a leading ~, and $NAME or ${NAME} from what the command set before
    this point or the environment it starts with. Anything else the shell expands (a substitution,
    ${NAME:-x}, $1, a backtick) is something the gate cannot work out, and says so.
    """
    text = word
    if text.startswith("~"):
        head, sep, rest = text.partition("/")
        if head == "~":
            home, why = _lookup("HOME", place)
            if why:
                return None, why
        else:
            home = os.path.expanduser(head)
            if home == head:
                return None, "%s names a home directory the gate cannot find" % head
        text = home + sep + rest
    leftover = VARIABLE.sub("", text)
    if "$" in leftover or "`" in leftover:
        return None, "it holds an expansion the gate cannot work out without running the command"
    out, last = [], 0
    for m in VARIABLE.finditer(text):
        value, why = _lookup(m.group(1) or m.group(2), place)
        if why:
            return None, why
        out += [text[last:m.start()], value]
        last = m.end()
    out.append(text[last:])
    return "".join(out), None


def resolve_path(word, place):
    """The absolute path a word names where the create runs: (path, None), or (None, why not)."""
    value, why = expand(word, place)
    if why:
        return None, why
    if not os.path.isabs(value):
        if place.cwd is None:
            return None, "it is relative, and the gate cannot tell which directory the command is in"
        value = os.path.join(place.cwd, value)
    return os.path.normpath(value), None


def _assign(place, word):
    """Record NAME=value as the shell would leave it for later commands."""
    name, value = word.split("=", 1)
    place.vars[name], _ = expand(value, place)


def _follow(place, words):
    """Record what a command that is not a create leaves behind: an assignment, or a cd."""
    k = 0
    while k < len(words) and (words[k] in HEAD_WORDS or ASSIGNMENT.match(words[k])):
        k += 1
    if k >= len(words):
        return
    name, rest = words[k], words[k + 1:]
    if name in ("for", "select") and rest and re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", rest[0]):
        place.vars[rest[0]] = RUNTIME
    elif name == "read":
        skip = False
        for w in rest:
            if skip:
                skip = False
            elif w in READ_VALUE_OPTIONS:
                skip = True
            elif not w.startswith("-"):
                place.vars[w] = RUNTIME
    elif name in SET_WORDS:
        for w in rest:
            if ASSIGNMENT.match(w):
                _assign(place, w)
    elif name in CD_WORDS:
        # cd - goes back to where the last cd in this command left; popd to where the last pushd did.
        # Where the command shows neither (a first cd -, a popd with no pushd before it), cwd becomes
        # None, so a later relative path is refused as unresolvable (claude-config#1436).
        targets = [w for w in rest if w == "-" or not w.startswith("-")]
        if name == "pushd" and (not targets or targets[0].startswith(("+", "-"))):
            # Bare pushd swaps the top two, +N and -N rotate: none is worth following.
            place.stack.append(place.cwd)
            place.move(None)
        elif name == "pushd":
            place.stack.append(place.cwd)
            place.move(resolve_path(targets[0], place)[0])
        elif not targets:
            place.move(expand("~", place)[0])
        elif targets[0] == "-":
            place.move(place.previous)
        else:
            place.move(resolve_path(targets[0], place)[0])
    elif name == "popd":
        place.move(place.stack.pop() if place.stack and not rest else None)


def scan_creates(command):
    """Find every real `gh issue create` in a command string.

    Returns a list of (args, env_assignments) pairs, one per create, where args are
    the tokens belonging to that create and env_assignments are the `NAME=value`
    tokens prefixing that specific command. Returning all of them, rather than
    testing one override here, is what lets a single gate carry several independent
    rules with an override each.

    A create only counts when `gh issue create` sits at the head of a segment
    (start of the command, or just after a shell operator, with leading env
    assignments skipped). That keeps quoted mentions and heredoc bodies from
    tripping a gate.

    Raises Unreadable when the command cannot be tokenized.
    """
    return [(args, envs) for args, envs, _ in scan_creates_in_context(command)]


def scan_creates_in_context(command, cwd=None, environ=None):
    """scan_creates, with the Place each create runs in as a third field (claude-config#1416)."""
    return [(args, envs, place) for _, args, envs, place in scan_gh_in_context(command, cwd, environ, {CREATE})]


def scan_gh_in_context(command, cwd=None, environ=None, kinds=frozenset({CREATE}), start=None, depth=0):
    """Every gh command of the given kinds, as (kind, args, envs, place), kind its (sub, act).

    The walk scan_creates_in_context makes, for any gh command that names a body file
    (BODY_FILE_COMMANDS, claude-config#1435), not only `gh issue create`.

    cwd is the directory the command starts in, None when unknown; environ the environment it starts
    with, empty when not given. Variables set by a segment of bare assignments or by export and its
    kin carry to later segments; an assignment in front of a command applies to that command only,
    after the shell has expanded its arguments, so it does not reach them. A cd, pushd or popd moves
    the directory. Each lasts to the end of the subshell it was made in.

    A command a shell runs from its -c string, eval runs from its words or env -S splits from its
    string is scanned as a command line of its own (claude-config#1478), from start, the Place where
    the wrapper runs, depth being how many wrappers deep it is. One whose string cannot be read is
    passed over here, never a reason to pass the rest: check-wrapped-commands.sh refuses it.
    """
    if not command or not command.strip():
        return []

    command = normalize(command)

    try:
        # punctuation_chars is a lexer option, not a split() argument: it makes the
        # shell operators separate tokens so a segment head can be recognised.
        # commenters is cleared so a '#' inside an issue title is not treated as a
        # comment and does not swallow the rest of the command.
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        lexer.commenters = ""
        tokens = list(lexer)
    except ValueError:
        raise Unreadable("unbalanced quotes")

    creates = []
    i = 0
    at_head = True
    place = start.copy() if start is not None else Place(cwd, environ if environ is not None else {})
    subshells = []
    # An override belongs to the ONE command it prefixes. Reading it across the whole
    # call is how an unmilestoned create slipped through on 2026-07-29: an override on
    # line 1 silently exempted a second create three lines later.
    seg_env = []
    while i < len(tokens):
        tok = tokens[i]
        if _is_operator(tok):
            # Assignments with no command after them set variables for the rest of the command.
            for w in seg_env:
                _assign(place, w)
            for ch in tok:
                if ch == "(":
                    subshells.append(place.copy())
                elif ch == ")" and subshells:
                    place = subshells.pop()
            at_head = True
            seg_env = []
            i += 1
            continue

        if at_head and ASSIGNMENT.match(tok):
            seg_env.append(tok)
            i += 1  # env assignment prefix: still at the head
            continue

        if at_head:
            j = i
            while j < len(tokens) and not _is_operator(tokens[j]):
                j += 1
            found = gh_command(tokens[i:j])
            if not found or tuple(found[:2]) not in kinds:
                inner = wrapped_words(tokens[i:j]) if depth < MAX_DEPTH else None
                if inner is not None and inner[1] is None and inner[0].startswith("find") and j < len(tokens) \
                        and tokens[j] == ";":
                    # The lexer cuts the `\;` ending find's -exec off as an operator, so it is put back.
                    inner = wrapped_words(tokens[i:j] + [";"])
                if inner is not None and inner[1] is not None and not inner[2]:
                    # A shell's string runs in a shell of its own, which sees only what was exported,
                    # so the variables this command set are not its to read; eval runs in this one.
                    child = place.copy()
                    if inner[0] != "eval":
                        child.vars = {}
                    creates.extend(scan_gh_in_context(inner[1], kinds=kinds, start=child, depth=depth + 1))
                _follow(place, tokens[i:j])
                seg_env = []  # they applied to that command alone
                i = j
                at_head = False
                continue
            args = list(found[2]) + list(found[3])
            # A command that files nothing is not a create. A live false positive on
            # 2026-07-30: `gh issue create --help` was blocked for having no category,
            # which is absurd and teaches exactly the override habit this exists to
            # avoid. A gate that cries wolf gets ignored. --web hands any of them to a
            # browser form a person completes.
            if not any(a in NON_FILING_FLAGS for a in args):
                creates.append((tuple(found[:2]), args, list(seg_env), place.copy()))
            i = j
            at_head = True
            seg_env = []
            continue

        at_head = False
        i += 1

    return creates


# ---- file_writes: which files the command itself writes, and whether it shows what goes in them ----
#
# Written for claude-config#1246. A gate runs BEFORE the command, so a body file the same command
# writes (`cat > body.md <<'EOF' ... EOF` then `gh issue create --body-file body.md`) is not on disk
# yet, or holds an older body the command is about to replace. Reading the disk judged nothing (the
# file was missing, so the gate failed open) or judged the wrong text. What the command writes is
# readable from the command whenever it comes from text the command shows: a heredoc whose body
# expands nothing, a here-string, or echo and printf of plain words.
HEREDOC_OPENER = re.compile(r"<<(-?)[ \t]*(?:'([^']*)'|\"([^\"]*)\"|\\?([A-Za-z0-9_]+))")
HEREDOC_MARK = "\x1fheredoc%d\x1f"
HEREDOC_TOKEN = re.compile(r"^\x1fheredoc(\d+)\x1f$")
# Commands whose output is only what the command text shows them: echo and printf print their own
# words, `:` and true print nothing, and cat and tee pass through what they are fed.
SHOWS_ITS_WORDS = {"echo", "printf", ":", "true"}
PASSES_ITS_INPUT = {"cat", "tee"}
HEAD_WORDS = {"!", "{", "if", "then", "else", "elif", "do", "while", "until", "time"}
EXPANDS = re.compile(r"[$`]")


def _cut_heredocs(command):
    """The command with every heredoc body taken out, and the bodies.

    Each opener is replaced by a token of its own, so a reader can tell which command a body feeds.
    Returns (text, [shown]), one entry per body: True when the body is text the command shows
    verbatim, which a quoted delimiter guarantees and an unquoted one gives only when the body holds
    nothing the shell would expand. A body that never closes ends the text, as the shell reads it.
    """
    out, bodies, pending = [], [], []
    i, n, quote, openers = 0, len(command), None, 0
    while i < n:
        c = command[i]
        if quote:
            if c == "\\" and quote == '"' and i + 1 < n:
                out.append(command[i:i + 2])
                i += 2
                continue
            out.append(c)
            if c == quote:
                quote = None
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            out.append(" " if command[i + 1] == "\n" else command[i:i + 2])
            i += 2
            continue
        if c in ("'", '"'):
            quote = c
            out.append(c)
            i += 1
            continue
        if command.startswith("<<<", i):
            out.append(" <<< ")
            i += 3
            continue
        if command.startswith("<<", i):
            m = HEREDOC_OPENER.match(command, i)
            if m:
                word = next(g for g in m.groups()[1:] if g is not None)
                # 'EOF', "EOF" and \EOF all stop the body expanding; a bare EOF does not.
                quoted = m.group(4) is None or command[m.start(4) - 1] == "\\"
                pending.append((word, m.group(1) == "-", quoted))
                out.append(" " + HEREDOC_MARK % openers + " ")
                openers += 1
                i = m.end()
                continue
        if c == "\n":
            # A line ending in a pipe or && carries the command on to the next line.
            last = next((piece.rstrip()[-1] for piece in reversed(out) if piece.strip()), "")
            out.append(" " if last in ("|", "&") else " ; ")
            i += 1
            for word, strip_tabs, quoted in pending:
                lines = []
                while i < n:
                    e = command.find("\n", i)
                    line = command[i:(e if e != -1 else n)]
                    i = (e + 1) if e != -1 else n
                    if (line.lstrip("\t") if strip_tabs else line) == word:
                        break
                    lines.append(line)
                body = "\n".join(lines)
                bodies.append(quoted or not EXPANDS.search(body))
            pending = []
            continue
        out.append(c)
        i += 1
    bodies += [False] * len(pending)  # opened on the last line, so no body the command shows
    return "".join(out), bodies


def _stages(command):
    """Every pipeline in the command, as a list of stages, each a (words, redirects, heredocs) triple.

    redirects are (operator, target) pairs; heredocs the indexes of the bodies feeding that stage.
    A subshell's opening and closing parenthesis are entries of their own, the strings "(" and ")",
    in order among the pipelines, so a reader can tell where a cd inside one ends.
    Raises Unreadable when the command cannot be tokenized.
    """
    text, bodies = _cut_heredocs(command)
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        lexer.commenters = ""
        tokens = list(lexer)
    except ValueError:
        raise Unreadable("unbalanced quotes")
    pipelines, stages, stage = [], [], ([], [], [])
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        h = HEREDOC_TOKEN.match(tok)
        if h:
            stage[2].append(int(h.group(1)))
        elif set(tok) <= set("&|;()") and tok not in ("|", "|&"):
            if stage[0] or stage[1] or stage[2]:
                stages.append(stage)
            if stages:
                pipelines.append(stages)
            stages, stage = [], ([], [], [])
            pipelines += [ch for ch in tok if ch in "()"]
        elif tok in ("|", "|&"):
            stages.append(stage)
            stage = ([], [], [])
        elif set(tok) <= set("<>&|") and ("<" in tok or ">" in tok):
            target = tokens[i + 1] if i + 1 < len(tokens) else ""
            stage[1].append((tok, target))
            i += 1
        else:
            stage[0].append(tok)
        i += 1
    if stage[0] or stage[1] or stage[2]:
        stages.append(stage)
    if stages:
        pipelines.append(stages)
    return pipelines, bodies


def _name(words):
    """The command a stage runs, past reserved words and assignments, and the words after it."""
    i = 0
    while i < len(words) and (words[i] in HEAD_WORDS or ASSIGNMENT.match(words[i])):
        i += 1
    return (words[i], words[i + 1:]) if i < len(words) else (None, [])


def _shown(stage, fed, bodies):
    """Whether everything the stage writes out is text the command shows."""
    words, redirects, heredocs = stage
    name, rest = _name(words)
    if name is None:
        return True  # a bare redirect writes nothing
    if name in SHOWS_ITS_WORDS:
        return not any(EXPANDS.search(w) for w in rest)
    if name in PASSES_ITS_INPUT:
        if name == "cat" and any(w != "-" and not w.startswith("-") for w in rest):
            return False  # it copies a file the command does not show
        if heredocs:
            return all(bodies[h] for h in heredocs)
        strings = [t for op, t in redirects if op == "<<<"]
        if strings:
            return not any(EXPANDS.search(t) for t in strings)
        if any(op.startswith("<") for op, _ in redirects):
            return False  # fed from a file
        return fed
    return False


def file_writes(command):
    """Every file the command writes, as (path, appends, shown) in the order written.

    appends is True for >> and tee -a. shown is True when what is written is text the command
    itself shows, so a reader may judge the file's new content from the command; False when it
    comes from anything else (a script, a file, an expansion), which nothing here can read.
    Raises Unreadable when the command cannot be tokenized.
    """
    return [(path, appends, shown) for path, appends, shown, _ in file_writes_in_context(command)]


def file_writes_in_context(command, cwd=None, environ=None):
    """file_writes, with where each write lands as a fourth field (claude-config#1436).

    The landing is the absolute path the target names in the directory and with the variables the
    command has at that write, read as scan_gh_in_context reads them, or None where the gate cannot
    tell (a substitution, a cd it cannot follow). A file written before a later cd is the file where
    it was written, not the one its spelling names after the cd. A cd in a pipeline of several stages
    runs in a subshell of its own, so only a lone command's is followed.
    """
    pipelines, bodies = _stages(command)
    place = Place(cwd, environ if environ is not None else {})
    subshells = []
    writes = []
    for stages in pipelines:
        if stages == "(":
            subshells.append(place.copy())
            continue
        if stages == ")":
            place = subshells.pop() if subshells else place
            continue
        fed = False  # the first stage reads whatever the command was started with
        for stage in stages:
            shown = _shown(stage, fed, bodies)
            name, rest = _name(stage[0])
            targets = []
            if name == "tee":
                appends = any(w in ("-a", "--append") for w in rest)
                targets += [(w, appends) for w in rest if not w.startswith("-")]
            targets += [(t, op.endswith(">>")) for op, t in stage[1] if ">" in op and not op.endswith("&")]
            writes += [(t, appends, shown, resolve_path(t, place)[0]) for t, appends in targets]
            fed = shown
        if len(stages) == 1:
            words = stages[0][0]
            if words and all(ASSIGNMENT.match(w) for w in words):
                for w in words:
                    _assign(place, w)  # assignments with no command after them last
            else:
                _follow(place, words)
    return writes


def flag_values(args, long_flag, short_flag=None):
    """Every value given to a flag in one create's argument list.

    Understands the four forms gh accepts: `--flag value`, `--flag=value`,
    `-f value` and `-fvalue`. A flag with no value, or one followed by another
    flag, contributes nothing, so an empty value can never satisfy a gate.
    """
    values = []
    i = 0
    n = len(args)
    while i < n:
        tok = args[i]

        if tok == long_flag:
            if i + 1 < n and args[i + 1].strip() and not args[i + 1].startswith("-"):
                values.append(args[i + 1])
                i += 2
                continue
            i += 1
            continue

        if tok.startswith(long_flag + "="):
            values.append(tok.split("=", 1)[1])
            i += 1
            continue

        if short_flag and tok == short_flag:
            if i + 1 < n and args[i + 1].strip() and not args[i + 1].startswith("-"):
                values.append(args[i + 1])
                i += 2
                continue
            i += 1
            continue

        # `-lbug`: an attached value. Guarded against swallowing a long flag that
        # happens to share the short flag's first letter (`--label` vs `-l`).
        if short_flag and not tok.startswith("--") and tok.startswith(short_flag) and len(tok) > len(short_flag):
            values.append(tok[len(short_flag) :])
            i += 1
            continue

        i += 1
    return values


def deny_payload(reason):
    """The PreToolUse response that blocks the tool call."""
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }


def plural_issues(count):
    """"1 issue" / "3 issues", for a message that reads correctly either way."""
    return "1 issue" if count == 1 else "{n} issues".format(n=count)
