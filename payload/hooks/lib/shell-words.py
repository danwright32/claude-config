#!/usr/bin/env python3
"""shell-words.py: a command read the way the shell nests quotes and substitutions, the one reader
behind lib/push-scope.sh and lib/merge-target.sh (claude-config#788, #1017, #1040).

Written in python because the same scan in bash, a character at a time, took 55 seconds on a 26 KB
command (an issue body mentioning a merge), measured 2026-10-05; every merge gate runs it, and a
hook that slow is killed and the command goes unscreened.

  shell-words.py split      stdin: one segment
      prints its leading NAME=value assignments, one per line, value with one layer of outermost
      quotes removed, then a line holding only the 0x1f separator, then the command that follows.
  shell-words.py commands   stdin: a whole command, as typed or with each newline flattened to "; "
      every simple command the shell would run, each as "<dir>" 0x1f "<text>" 0x1e, where <dir>
      is the directory the cd commands before it have moved its shell to (empty for none). The
      reader behind lib/push-scope.sh's questions about a push (claude-config#1017); see commands().
  shell-words.py read       stdin: a whole command
      the commands reading with everything the hooks ask of each command beside it, so one python
      start answers them all (claude-config#1040). Each record is "<dir>" 0x1c "<text>" 0x1c
      "<its words, 0x1f between them>" 0x1c "<its git -C directory>" 0x1c "<1 when the text read
      on its own is exactly this one command, else 0>" 0x1c "<the command from its name on, past
      leading reserved words and assignments>" 0x1c "<those assignments, one per line>" 0x1c "<the
      gh or git subcommand it runs, tool_field: tool 0x1d sub 0x1d act 0x1d words, else rtk's own
      subcommand, rtk_field, in the same shape, or empty>" 0x1c "<the wrapper, `bash -c`, `eval` or
      `env -S`, when it hands a string to a shell or eval, with 0x1d and why after it when that string
      cannot be read, else empty>" 0x1e, the commands a wrapper runs being records of their own right
      after it (claude-config#1478). Exit 3 as commands; see read(), command_rest(), gh_path(),
      git_path(), rtk_field() and wrapped().
  shell-words.py tool       stdin: one command
      the gh or git subcommand it runs, as gh and git themselves find it past the options written in
      front (tool_field), else rtk's own subcommand (rtk_field, claude-config#1468), or nothing when
      it runs none of them, exit 0 either way (claude-config#1188).
  shell-words.py words      stdin: one command
      its words as the shell reads them, quotes removed, joined by 0x1f, past any leading reserved
      word (then, do, else, ...), so the first word is the command's own; see command_words().
  shell-words.py gitdir     stdin: one command
      the directory its `git -C` options name, several composed as git composes them, or nothing
      when it is not git or names no -C, past reserved words, assignments, rtk, env and sudo; see
      git_dir().
  shell-words.py bare       stdin: one command
      the command with the contents of every $( ) and backquote substitution taken out, so a caller
      can ask what it runs itself rather than inside them (claude-config#1062); see bare().

The context stack: " ' ` quotes, $( and ${ substitutions, and plain ( inside a substitution.
Inside a substitution quotes open afresh, so X="$(a "b c")" is one word.
"""
import os
import re
import shlex
import sys


def is_name(word):
    return bool(word) and (word[0].isalpha() or word[0] == "_") and all(ch.isalnum() or ch == "_" for ch in word)


def split(s):
    assigns = []
    s = s.lstrip()
    while True:
        eq = s.find("=")
        if eq <= 0 or not is_name(s[:eq]):
            break
        name, i, n, val, stack = s[:eq], eq + 1, len(s), [], []
        while i < n:
            c = s[i]
            nx = s[i + 1] if i + 1 < n else ""
            top = stack[-1] if stack else ""
            if top == "'":
                if c == "'":
                    stack.pop()
                    if stack:
                        val.append(c)
                else:
                    val.append(c)
                i += 1
                continue
            if c == "\\" and i + 1 < n:
                # Escaped: never opens, closes or ends anything. At the top level, or directly
                # inside the outermost double quote, the shell drops the backslash itself.
                val.append(nx if (not stack or stack == ['"']) else c + nx)
                i += 2
                continue
            if c == '"':
                if top == '"':
                    stack.pop()
                    if stack:
                        val.append(c)
                else:
                    if stack:
                        val.append(c)
                    stack.append(c)
            elif c == "'":
                if top == '"':
                    val.append(c)
                else:
                    if stack:
                        val.append(c)
                    stack.append(c)
            elif c == "`":
                if top == "`":
                    stack.pop()
                else:
                    stack.append(c)
                val.append(c)
            elif c == "$" and nx in ("(", "{"):
                stack.append(nx)
                val.append(c + nx)
                i += 2
                continue
            elif c == "(":
                if top != '"':
                    stack.append(c)
                val.append(c)
            elif c == ")":
                if top == "(":
                    stack.pop()
                val.append(c)
            elif c == "}":
                if top == "{":
                    stack.pop()
                val.append(c)
            elif c in " \t":
                if not stack:
                    break
                val.append(c)
            else:
                val.append(c)
            i += 1
        assigns.append(name + "=" + "".join(val))
        s = s[i:].lstrip()
    return assigns, s


# ---- commands: every simple command a whole command runs, and the directory it runs in ----
#
# Written for claude-config#1017. lib/push-scope.sh asked two questions of a command with two
# readers: which segments are commands (an inline scanner that knew quotes and heredocs but not
# comments, $'...' strings, or that quotes open afresh inside "$( )"), and where a cd moves to (a
# tokenizer that stopped at the first token it could not read and took the FIRST cd it met). So a cd
# after a heredoc holding an apostrophe was never seen, a cd in a heredoc body was, a first cd beat a
# later one, a cd in a subshell that had closed still counted, and a push verb sitting in a comment
# or a $'...' string read as a push. One reading answers both now.
#
# The frames: the top level, a subshell ( ), a command substitution $( ) and a backtick hold
# COMMANDS, and only in those does a separator end one, a heredoc open, or a # start a comment.
# Quotes, $'...', ${ }, $(( )) and a plain ( ) that is not a subshell (a function's, an array's) hold
# text. Each command frame keeps the directory its shell is in, copied from the shell that opened it,
# and dropped when it closes, which is the shell's own rule: a cd inside ( ) or $( ) ends with it.
RESERVED = {"!", "{", "if", "then", "else", "elif", "do", "while", "until", "time"}
COMMAND_FRAMES = {"top", "sub", "subst", "tick"}
HEREDOC_OPENER = re.compile(r"<<(-?)[ \t]*(?:'([^']*)'|\"([^\"]*)\"|\\?([A-Za-z0-9_]+))")
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
# What ends a command, as (how it ended, its width). Two characters are looked up before one, so
# && is never read as a backgrounding & and || never as a pipe.
SEPARATORS = {"&&": ("&&", 2), "||": ("||", 2), "|&": ("|", 2), ";;": (";", 2),
              "|": ("|", 1), ";": (";", 1), "\n": (";", 1)}


class Unreadable(Exception):
    """Something opened and never closed, so this reading cannot be trusted."""


def cd_target(text):
    """The directory a simple command moves to when it is a cd, as the shell reads the word, or None.

    A bare cd goes home. Only a leading tilde is expanded later; a variable stays as written, so
    the caller refuses it rather than guessing what it holds.
    """
    try:
        words = shlex.split(text, posix=True)
    except ValueError:
        words = text.split()
    i, n = 0, len(words)
    while i < n and (words[i] in RESERVED or ASSIGNMENT.match(words[i])):
        i += 1
    if i >= n or words[i] != "cd":
        return None
    i += 1
    while i < n and words[i].startswith("-") and words[i] != "-":
        i += 1
        if words[i - 1] == "--":
            break
    # A redirect written before the directory is not the directory.
    while i < n and re.match(r"\d*[<>]", words[i]):
        i += 2 if re.fullmatch(r"\d*[<>]+&?", words[i]) else 1
    return words[i] if i < n else "~"


def moved(cwd, old, target):
    """The (directory, OLDPWD) after `cd target` from cwd. An empty cwd is the session's directory.

    `cd -` with no earlier cd in the command goes to an OLDPWD this cannot know, so it stays "-" and
    the caller refuses it rather than judge somewhere else (L75).
    """
    if target == "-":
        return ("-" if old is None else old), cwd
    if target.startswith("~"):
        target = os.path.expanduser(target)
    if target.startswith("/") or not cwd:
        return target, cwd
    return os.path.join(cwd, target), cwd


def commands(s, cwd=""):
    """Every simple command in s, in the order the shell finishes reading them, as (dir, text).

    The text is the command as written, quotes and all, and a command substitution's text stays
    inside the command that holds it as well as being read as commands of its own, which come first.
    A subshell group is not part of the command around it. Heredoc bodies and comments are nobody's
    text. s may be the command as typed or with every newline flattened to "; " (how the push hooks
    read it). Which one is decided by whether s holds a newline at all: with one, only a newline is
    a line break, so in `cat <<EOF; git push` the "; " is the separator it is and the push is read
    (lessons review of #1017); with none, "; " is the line break that starts a heredoc body and ends
    a comment, because the flattened text cannot tell a newline from a separator there (main read
    it the same way). Raises Unreadable when anything is still open at the end.

    cwd is the directory s starts in, "" for the session's: a string a wrapper runs (wrapped) starts
    where the wrapper runs (claude-config#1478).
    """
    n = len(s)
    line_break = "\n" if "\n" in s else "; "
    closing_line = re.escape(line_break) + "%s%s" + (r"(?=\n|$)" if line_break == "\n" else r"(?=;|$)")
    out, pending = [], []
    frames = [{"k": "top", "start": 0, "cwd": cwd, "old": None}]

    def cut(f, end, how):
        text = s[f["start"]:end]
        if not text.strip():
            return
        out.append((f["cwd"], text))
        target = cd_target(text)
        # A cd in a pipeline or sent to the background runs in a shell of its own.
        if target is not None and how not in ("|", "&"):
            f["cwd"], f["old"] = moved(f["cwd"], f["old"], target)

    def open_commands(kind, start):
        parent = next(f for f in reversed(frames) if f["k"] in COMMAND_FRAMES)
        frames.append({"k": kind, "start": start, "cwd": parent["cwd"], "old": parent["old"]})

    def close_commands(end):
        f = frames.pop()
        cut(f, end, ")")
        if f["k"] == "sub":
            frames[-1]["start"] = end + 1

    i = 0
    while i < n:
        c = s[i]
        nx = s[i + 1] if i + 1 < n else ""
        f = frames[-1]
        k = f["k"]
        if k == "'":
            if c == "'":
                frames.pop()
            i += 1
            continue
        if k == "ansi":
            if c == "'":
                frames.pop()
            i += 2 if c == "\\" else 1
            continue
        if c == "\\":
            i += 2
            continue
        if k == '"':
            if c == '"':
                frames.pop()
                i += 1
                continue
        elif k == "arith":
            if c == "(":
                f["depth"] += 1
                i += 1
                continue
            if c == ")":
                if f["depth"]:
                    f["depth"] -= 1
                    i += 1
                else:
                    frames.pop()
                    i += 2 if nx == ")" else 1
                continue
        elif k == "param":
            if c == "}":
                frames.pop()
                i += 1
                continue
        elif k == "paren":
            if c == "(":
                frames.append({"k": "paren"})
                i += 1
                continue
            if c == ")":
                frames.pop()
                i += 1
                continue
        if k != '"':
            if c == "'":
                frames.append({"k": "'"})
                i += 1
                continue
            if c == "$" and nx == "'":
                frames.append({"k": "ansi"})
                i += 2
                continue
            if c == '"':
                frames.append({"k": '"'})
                i += 1
                continue
        if s.startswith("$((", i):
            frames.append({"k": "arith", "depth": 0})
            i += 3
            continue
        if s.startswith("$(", i):
            open_commands("subst", i + 2)
            i += 2
            continue
        if s.startswith("${", i):
            frames.append({"k": "param"})
            i += 2
            continue
        if c == "`":
            if k == "tick":
                close_commands(i)
            else:
                open_commands("tick", i + 1)
            i += 1
            continue
        if k not in COMMAND_FRAMES:
            i += 1
            continue
        # Where commands begin and end: only here, in a frame that holds commands.
        if c == "#" and (i == 0 or s[i - 1] in " \t\n;&|()"):
            cut(f, i, "#")
            j = s.find(line_break, i)
            i = n if j < 0 else j
            f["start"] = i
            continue
        if s.startswith("<<<", i):
            i += 3
            continue
        if s.startswith("<<", i):
            m = HEREDOC_OPENER.match(s, i)
            if m:
                word = next(g for g in m.groups()[1:] if g is not None)
                pending.append((word, m.group(1) == "-"))
                i = m.end()
            else:
                i += 2
            continue
        if pending and s.startswith(line_break, i):
            # The bodies start on the next line: find the closing line of each in turn. One that never
            # closes is not skipped, so nothing after it is hidden.
            j = i
            for word, strip_tabs in pending:
                m = re.compile(closing_line % ("\t*" if strip_tabs else "", re.escape(word))).search(s, j)
                if not m:
                    j = None
                    break
                j = m.end()
            pending.clear()
            if j is not None:
                cut(f, i, "\n")
                f["start"] = i = j
                continue
        two = s[i:i + 2]
        separator = SEPARATORS.get(two) or SEPARATORS.get(c)
        if separator:
            how, width = separator
            cut(f, i, how)
            i += width
            f["start"] = i
            continue
        if c == "&":
            # &> and >& are redirects; a lone & sends the command before it to the background.
            if nx != ">" and not (i and s[i - 1] in "<>"):
                cut(f, i, "&")
                f["start"] = i + 1
            i += 1
            continue
        if c == "(":
            if all(w in RESERVED for w in s[f["start"]:i].split()):
                if nx == "(":
                    frames.append({"k": "arith", "depth": 0})
                    i += 2
                else:
                    open_commands("sub", i + 1)
                    i += 1
            else:
                frames.append({"k": "paren"})
                i += 1
            continue
        if c == ")" and k in ("sub", "subst"):
            close_commands(i)
        i += 1
    if len(frames) > 1:
        raise Unreadable()
    cut(frames[0], n, "end")
    return out


def command_words(text):
    """One command's words as the shell reads them, quotes removed, past any leading reserved word.

    `then git push` is git's command: the reserved words only open or continue a compound command,
    and a walker that took `then` or `do` for the command name saw no push in `if x; then git push;
    fi` (#1017). Looked past from RESERVED, the same list cd_target uses, so the two readings cannot
    disagree about which word is the command. A command shlex cannot read (an unbalanced quote) is
    split on whitespace instead, the reading that still lets a push be seen.
    """
    try:
        words = shlex.split(text, posix=True)
    except ValueError:
        words = text.split()
    i = 0
    while i < len(words) and words[i] in RESERVED:
        i += 1
    return words[i:]


def git_dir(rest):
    """The directory ONE command's `git -C` options move git to, or "" when it names none, from its
    text from its own name on (command_rest), read by git_path, the one reading of git: so `do git -C
    <wt> push` (#1017) and `env GIT_DIR=x git -C <wt> push` (#1188) both name <wt>.

    Several -C compose the way git composes them: each relative one is taken from the one before
    (claude-config#589). Only a leading tilde is expanded; a variable stays as written, so the caller
    refuses it.
    """
    found = git_read(command_words(rest))
    if not found:
        return ""
    front = found[1]
    where = ""
    k = 0
    while k < len(front):
        w = front[k]
        if w == "-C" and k + 1 < len(front):
            p = front[k + 1]
            p = os.path.expanduser(p) if p.startswith("~") else p
            where = p if (not where or p.startswith("/")) else os.path.join(where, p)
        k += 2 if w in GIT_VALUED else 1
    return where


def bare(s):
    """One command with the contents of every $( ) and backquote substitution taken out.

    What the command runs ITSELF, as against what it runs inside its substitutions (#1062).
    commands() lists `out=$(cd A && git push)` beside the push inside it, and a push recogniser
    that reads substitutions afresh says yes to both; the outer one is a container, and judging it
    puts the push in the outer shell's directory. `git push origin "$(git branch)"` is still a push
    with its substitution emptied, and stays one. Quotes and parentheses are read the way the
    shell nests them, quotes opening afresh inside a substitution. A substitution left open at the end
    cannot be read, so the command is returned whole, which keeps it counted (L42).
    """
    out, stack, i, n = [], [], 0, len(s)

    def inside():
        return any(k in ("$(", "`") for k in stack)

    while i < n:
        c = s[i]
        nx = s[i + 1] if i + 1 < n else ""
        top = stack[-1] if stack else ""
        if top == "'":
            if c == "'":
                stack.pop()
            if not inside():
                out.append(c)
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            if not inside():
                out.append(c + nx)
            i += 2
            continue
        if c == "$" and nx == "(":
            if not inside():
                out.append("$(")
            stack.append("$(")
            i += 2
            continue
        if c == "`":
            if top == "`":
                stack.pop()
                if not inside():
                    out.append(c)
            else:
                if not inside():
                    out.append(c)
                stack.append("`")
            i += 1
            continue
        if c == ")" and top == "$(":
            stack.pop()
            if not inside():
                out.append(c)
            i += 1
            continue
        if c == '"':
            if top == '"':
                stack.pop()
            else:
                stack.append(c)
        elif c == "'":
            if top != '"':
                stack.append(c)
        elif c == "(":
            if inside() and top != '"':
                stack.append(c)
        elif c == ")":
            if top == "(":
                stack.pop()
        if not inside():
            out.append(c)
        i += 1
    if stack:
        return s
    return "".join(out)


def crude_commands(s, cwd=""):
    """The reading used when commands() cannot be trusted: a cut at every separator, quotes and all.

    It can only see MORE commands than are there, which is the direction a gate that must not miss a
    push needs (L42), and it keeps the cds in order, so the last one before a push still governs it.
    """
    out, old = [], None
    for text in re.split(r"&&|\|\||;|\||\n", s):
        if text.strip():
            out.append((cwd, text))
            target = cd_target(text)
            if target is not None:
                cwd, old = moved(cwd, old, target)
    return out


def alone(text):
    """Whether `text`, read as a command of its own, is exactly the one command `text`.

    A caller that has read a whole command asks each of its commands questions of its own (is this
    one a push?), and every such question would read that text afresh. When the answer is this, the
    caller can answer from the reading it already holds, with no second python start. A text holding
    a substitution reads as more than one command, so it is never alone.
    """
    try:
        return commands(text) == [("", text)]
    except Unreadable:
        return False


def command_rest(text, passed=None):
    """(the command from its own name on, its leading assignments) for one command's text.

    Past the reserved words that only open or continue a compound command (RESERVED: then, do, {,
    !, time, ...) and then past leading NAME=value assignments, read by split(), which knows a value
    holding quotes, a substitution or spaces. A merge gate reading the first words of `then gh pr
    merge 7` saw `then` where gh should be, so a merge inside an if, a loop or a brace group was no
    merge to any of them (claude-config#1040). The text is kept as written, quotes and all, so a
    caller reads its arguments the way it always has.
    """
    s = text.lstrip()
    # A subshell or group opening a command the crude cut left whole, `( cd x && git push )` or
    # `(git push)`, is not part of it (claude-config#439): an opener glued to the name is peeled off,
    # one standing alone is passed over. The commands reading never leaves one.
    while s.startswith("(") and not s.startswith("(("):
        s = s[1:].lstrip()
    while True:
        m = re.match(r"(\S+)(\s+|$)", s)
        if not m or m.group(1) not in RESERVED:
            break
        s = s[m.end():]
        # The shell's own time takes -p, and -- to end it, before the command it times
        # (claude-config#1478); /usr/bin/time by its path is a runner (RUNNERS).
        while m.group(1) == "time":
            m2 = re.match(r"(-p|--)(\s+|$)", s)
            if not m2:
                break
            s = s[m2.end():]
    assigns, rest = split(s)
    rest, more = past_runners(rest, passed)
    return rest, "\n".join(assigns + more)


# The words that only run the command after them, each with the short options that take a value and
# the long ones that take the next word (claude-config#1181). `env GH_TOKEN=x gh pr merge 7` and
# `sudo gh pr merge 7` were commands named env and sudo to every merge gate, so they merged unjudged,
# while the mods' one reader (mod-kit hooks/commands.ts, RUNNERS, whose option letters these are)
# read them as the merge; and that reader did not know rtk, which this one did. Both now read all
# three, and payload/mods/scope-modes/tests/api-merge-cases.ts holds them to it, route by route.
#
# The shell's own exec and command run the word after them too (`exec git push`, `command gh issue
# create`), and skill-audit.py's script scan read both before it moved onto this reading (#1188).
# `command -v gh` then reads as a gh command with no subcommand, which no gate asks about. The mods'
# reader does not list these two, so for them the gates see more than the overnight judge does.
RUNNERS = {
    "rtk": ("", set()),
    "exec": ("a", set()),
    "command": ("", set()),
    "env": ("CPSu", {"--chdir", "--split-string", "--unset"}),
    "sudo": ("CDghpRrTtUu", {"--chdir", "--chroot", "--close-from", "--command-timeout", "--group", "--host",
                             "--other-user", "--prompt", "--role", "--type", "--user"}),
    "nohup": ("", set()),
    "nice": ("n", {"--adjustment"}),
    "time": ("fo", {"--format", "--output"}),
    "timeout": ("sk", {"--signal", "--kill-after"}),
    "gtimeout": ("sk", {"--signal", "--kill-after"}),
    "caffeinate": ("tw", set()),
    "stdbuf": ("eio", {"--error", "--input", "--output"}),
    "doas": ("Cu", set()),
    "xargs": ("EIJLnPRSsad", {"--arg-file", "--delimiter", "--max-args", "--max-procs", "--max-chars",
                              "--process-slot-var"}),
}
# The launchers that run their arguments as a command were none of these, so `nohup git push`, `xargs
# git push` and `timeout 30 git push` were commands named nohup, xargs and timeout to every gate
# (claude-config#1478). Their option letters are the macOS and GNU versions' together: xargs -I, -J,
# -L, -n, -P, -E, -R, -S, -s (BSD) and -a, -d (GNU) take a value; nice -n; GNU time -f and -o;
# timeout -s and -k, then a duration (POSITIONALS); caffeinate -t and -w. rtk's `proxy` subcommand
# runs the words after it as they stand (rtk 0.31.0 `rtk proxy --help`: its options -v, -u,
# --skip-env and -h take no value), so past_runners reads through it.
#
# The words a runner takes after its options and before the command: timeout's duration.
POSITIONALS = {"timeout": 1, "gtimeout": 1}


def first_word(s):
    """(the first word of s with its quotes removed, the text after it as written), or (None, s)."""
    s = s.lstrip()
    if not s:
        return None, s
    lex = shlex.shlex(s, posix=True)
    lex.whitespace_split = True
    lex.commenters = ""
    try:
        w = lex.get_token()
    except ValueError:
        return None, s
    if w is None:
        return None, s
    return w, s[lex.instream.tell():]


def past_runners(rest, passed=None):
    """The command past any runner in front of it (RUNNERS: rtk, env, sudo, nohup, xargs, timeout and
    the rest, rtk proxy included), each with its options, and the NAME=value
    settings env or sudo gives it, which are the command's own assignments as much as a leading one.
    A runner whose command cannot be read from its words (env -S, which splits a string into one) is
    left as it stands, the command then being that runner's. When passed is a list, each runner
    passed over is appended to it as (its name, the text after its own options), for rtk_field."""
    assigns = []
    for _ in range(8):
        w, after = first_word(rest)
        if w is None or w.split("/")[-1] not in RUNNERS:
            break
        values, longs = RUNNERS[w.split("/")[-1]]
        s = after
        while True:
            opt, after_opt = first_word(s)
            if opt is None:
                return rest, assigns
            if opt == "--":
                s = after_opt
                break
            if opt == "-":
                s = after_opt
                continue
            if opt.startswith("--"):
                if opt.split("=", 1)[0] == "--split-string":
                    return rest, assigns
                if "=" not in opt and opt in longs:
                    _, after_opt = first_word(after_opt)
                s = after_opt
                continue
            if opt.startswith("-") and len(opt) > 1:
                letters = opt[1:]
                if w.split("/")[-1] == "env" and "S" in letters:
                    return rest, assigns
                at = next((k for k, ch in enumerate(letters) if ch in values), None)
                # A value flag takes the rest of its word, or the next word when it ends the word.
                if at is not None and at == len(letters) - 1:
                    _, after_opt = first_word(after_opt)
                s = after_opt
                continue
            break
        name = w.split("/")[-1]
        for _ in range(POSITIONALS.get(name, 0)):
            _, s = first_word(s)
        if name == "rtk":
            sub_word, after_sub = first_word(s)
            if sub_word == "proxy":
                # rtk proxy runs the words after its own options as they stand. rtk is then not the
                # command's last runner, so `rtk proxy init` is a program named init, not rtk's.
                s = after_sub
                while True:
                    opt, after_opt = first_word(s)
                    if opt is None or not opt.startswith("-") or opt == "-":
                        break
                    s = after_opt
                    if opt == "--":
                        break
                rest = s
                continue
        if passed is not None:
            passed.append((name, s))
        more, s = split(s)
        assigns.extend(more)
        rest = s
    return rest, assigns


# ---- gh and git: which subcommand a command runs -----------------------------------------------
# The ONE reading of which gh or git subcommand a command runs (claude-config#1188). Every gate asks
# it: the merge gates through lib/merge-selector.py, the bash gates through lib/push-scope.sh
# (ps_runs_gh, ps_runs_git, and the push, commit and add questions built on them), the issue gates
# through gh_issue_scan.py, so a spelling one gate sees is seen by all. Each gate used to read the
# command by WORD POSITION, gh then pr then create as its first three words, git then a few options
# then push, each with its own idea of what may stand in front, and the copies disagreed: the merge
# gates read gh's flags in front of the subcommand (#1186) while the closing keyword check did not,
# and the push gates read rtk in front of git while nothing read env or sudo. test-gh-reader.sh fails
# on a hook that matches a gh or git subcommand by word position again.
#
# Both are read from the command's own name on: past reserved words (then, do, !), leading
# assignments and any rtk, env or sudo in front, by command_rest, the one reading of those. A
# subshell or group opener glued to the name, `(git push`, is the crude cut's and is not part of it.
#
# gh takes a subcommand's flags written IN FRONT of it: `gh -R o/x pr create`, `gh pr -R o/x create`,
# `gh -X PUT api repos/o/x/pulls/7/merge` (measured on gh 2.89.0, 2026-10-14). Its command library
# (cobra) finds the subcommand by passing over the flags first, then hands every flag, wherever it
# stood, to that subcommand. Cobra passes over a flag with no `=` in it as one that TAKES the next
# word, unless it is a flag it knows takes none, and at the head of a gh command those are only gh's
# own --help (-h) and --version (`gh help` lists no other flag of its own). A word of more than two
# characters after a single dash (`-Rowner/x`, `-XPUT`) carries its value. So `gh --squash pr merge 7`
# is a command named merge to gh, which it has none of, and it runs nothing (measured: `gh --web pr
# view 1` answers `unknown command "view"`).
GH_NO_VALUE = {"--help", "-h", "--version"}
# git's own options in front of its subcommand that take the next word as their value (`git -C <dir>
# push`, `git -c k=v commit`); every other option there stands alone. The subcommand is the first
# word that is not an option (git.c handle_options).
GIT_VALUED = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}


def gh_path(words):
    """The words after `gh` as gh reads them: (sub, act, front, after). sub and act are the
    subcommand and its action as cobra finds them (empty when absent; `api` takes no action), front
    is the words written in front of the action, in order, for the subcommand to read as its own,
    and after is every word after the action (after `api` for gh api)."""
    path, front = [], []
    j, n = 0, len(words)
    while j < n:
        w = words[j]
        if w == "--":
            break
        if w.startswith("-") and len(w) > 1:
            front.append(w)
            takes = "=" not in w and w not in GH_NO_VALUE and (w.startswith("--") or len(w) == 2)
            if takes and j + 1 < n:
                front.append(words[j + 1])
                j += 1
            j += 1
            continue
        path.append(w)
        j += 1
        if len(path) == 2 or path[0] == "api":
            break
    sub = path[0] if path else ""
    act = path[1] if len(path) > 1 else ""
    return sub, act, front, words[j:]


def git_path(words):
    """The words after `git` as git reads them: (sub, front, after). sub is the subcommand (empty
    when there is none), front git's own options before it, after every word after it."""
    j, n = 0, len(words)
    while j < n and words[j].startswith("-") and words[j] != "-":
        j += 2 if words[j] in GIT_VALUED else 1
    j = min(j, n)
    if j >= n:
        return "", words[:n], []
    return words[j], words[:j], words[j + 1:]


def tool_read(words):
    """For one command's words from its own name on (past reserved words, assignments and runners):
    ("gh", sub, act, front, after) for gh, ("git", sub, "", front, after) for git, by name or by
    path; None for any other command."""
    if not words:
        return None
    name = words[0].lstrip("({").split("/")[-1]
    if name == "gh":  # gh-reader: the one reading of which program a command runs
        return ("gh",) + gh_path(list(words[1:]))
    if name == "git":  # gh-reader: the one reading of which program a command runs
        sub, front, after = git_path(list(words[1:]))
        return ("git", sub, "", front, after)
    return None


def git_read(words):
    """tool_read's (sub, front, after) when the command is git; None otherwise."""
    found = tool_read(words)
    return found[1:2] + found[3:] if found and found[0] == "git" else None  # gh-reader: the one reading


def git_command(words):
    """tool_command's (sub, front, after) when the command is git; None otherwise."""
    found = tool_command(words)
    return found[1:2] + found[3:] if found and found[0] == "git" else None  # gh-reader: the one reading


def tool_command(words):
    """tool_read for one command's words as a caller split them, from its first word: past reserved
    words, leading assignments and any rtk, env or sudo in front, read by command_rest, so a caller
    with words of its own (gh_issue_scan.py, merge-selector.py, push-scope.sh's add reader) sees
    `rtk gh issue create` and `env GH_TOKEN=x gh pr merge` exactly as the bash gates do."""
    text = rejoin(words)
    if not text:
        return None
    rest, _ = command_rest(text)
    return tool_read(command_words(rest))


def rejoin(words):
    """One command's words as a caller split them, written back as the shell would read the same
    words, or "" for none. A subshell or group opener glued to the first is the crude cut's and is
    dropped. An assignment keeps its name outside the quotes, `NAME='a b'`, so command_rest still
    reads it as one: quoted whole, as shlex.join quotes it, `env GH_TOKEN="a b" gh issue create` read
    as a command named GH_TOKEN=a b (the lessons review of #1188)."""
    if not words:
        return ""
    first = words[0].lstrip("({")
    words = ([first] if first else []) + list(words[1:])
    return " ".join(w[:m.end()] + shlex.quote(w[m.end():]) if m else shlex.quote(w)
                    for w, m in ((w, ASSIGNMENT.match(w)) for w in words))


def wrapped_words(words):
    """wrapped() for one command's words as a caller split them (gh_issue_scan.py): past reserved
    words, assignments and runners, (wrapper, string, why) when it hands a string to a shell, eval or
    env -S, else None (claude-config#1478)."""
    text = rejoin(words)
    return wrapped(command_rest(text)[0]) if text else None


def gh_command(words):
    """tool_command's (sub, act, front, after) when the command is gh; None otherwise."""
    found = tool_command(words)
    return found[1:] if found and found[0] == "gh" else None  # gh-reader: the one reading


def tool_field(rest):
    """One command's reading for lib/push-scope.sh, from its text from its own name on (command_rest):
    tool 0x1d sub 0x1d act 0x1d its words joined by 0x1f, or "" when it runs neither gh nor git. A gh
    command's words are the flags written in front then the words after the action, all the
    subcommand's own; a git command's are the words after its subcommand, git's own options in front
    being read by git_dir."""
    found = tool_read(command_words(rest))
    if found is None:
        return ""
    tool, sub, act, front, after = found
    words = front + after if tool == "gh" else after
    return tool + "\x1d" + sub + "\x1d" + act + "\x1d" + "\x1f".join(words)


def rtk_field(passed):
    """The reading of a command whose LAST runner is rtk, from the runners command_rest passed over:
    "rtk" 0x1d its subcommand 0x1d 0x1d the words after it joined by 0x1f, or "" (claude-config#1468).

    rtk is read as a runner because `rtk git push` runs git push, but `rtk init` runs a subcommand of
    rtk's own, and read as a runner it was a command named init, which nothing could tell from a bare
    init. It is asked only where tool_field found neither gh nor git, so a gate asking about those
    reads them exactly as before. rtk's own options in front of its subcommand (`rtk -v init`) were
    passed over with it, as rtk itself passes over them."""
    if not passed or passed[-1][0] != "rtk":
        return ""
    after = passed[-1][1]
    try:
        words = shlex.split(after, posix=True)
    except ValueError:
        words = after.split()
    if not words:
        return ""
    return "rtk\x1d" + words[0] + "\x1d\x1d" + "\x1f".join(words[1:])


def program_field(text):
    """(the command from its own name on, its assignments, its reading) for one command's text: the
    gh or git reading (tool_field), else rtk's own subcommand (rtk_field), else ""."""
    passed = []
    rest, assigns = command_rest(text, passed)
    return rest, assigns, tool_field(rest) or rtk_field(passed)


# ---- commands a wrapper runs: a shell's -c string, eval, env -S (claude-config#1478) ------------
# Every gate read only the commands in command position, so a command another program runs from a
# string was text to all of them: `bash -c 'git push --force'`, `eval "git push"`, `env -S 'git
# push'`. The string is a command line in its own right, so it is read as one, by commands(), in the
# directory the wrapper runs in, and its commands are records of the reading after the wrapper's own,
# recursively up to MAX_DEPTH. A wrapper whose string cannot be read is reported, naming it, so a
# gate refuses rather than passes what it cannot see (check-wrapped-commands.sh): a variable or a
# substitution where the string's command should be (`bash -c "$CMD"`), a quote that never closes, a
# shell reading its commands from its input (a pipe, a here string, a heredoc), wrapping past
# MAX_DEPTH, or an eval that changes directory, since eval runs in the shell around it and every
# directory read after it would be wrong. A mention (echo, a grep pattern, a commit message, a
# heredoc body) is no command, so it is never a wrapper.
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
# A shell's long options that take the next word as their value.
SHELL_VALUED = {"--rcfile", "--init-file"}
# A word that is a redirection, with its target attached (group 1) or in the next word.
REDIRECT_WORD = re.compile(r"\d*(?:<<<|<<-?|<>|<&|>&|>>|&>>?|<|>)(.*)\Z", re.S)
MAX_DEPTH = 5
WHY_VARIABLE = "its command is a variable or a substitution, known only as it runs"
WHY_QUOTE = "it holds a quote that never closes"
WHY_INPUT = "it reads its commands from its input (a pipe, a here string, a heredoc or a file)"
WHY_DEEP = "it is wrapped more than %d deep" % MAX_DEPTH
WHY_EVAL_CD = "it changes directory in the shell around it, so where the commands after it run cannot be told"
WHY_FILE = "it runs the script file %s, whose commands are in the file, not the command"
WHY_EXECDIR = "it runs its command in the directory of each file it finds, which cannot be told"
WHY_UNENDED = "its %s command never ends with ; or {} +"


def wrapped(rest):
    """(wrapper, string, why) for one command, from its own name on (command_rest), that runs a string
    as a command line, else None. wrapper names it (`bash -c`, `eval`, `env -S`, or the shell's name
    when it reads its input); string is the command line it runs, None when there is none to read;
    why is "" when the string can be read, else the reason it cannot."""
    name, _ = first_word(rest)
    if name is None:
        raw = rest.split(None, 1)
        name = raw[0].strip("'\"") if raw else ""
    name = name.split("/")[-1]
    if name not in SHELLS and name not in ("eval", "env") and name not in ARGUMENT_RUNNERS:
        return None
    try:
        words = shlex.split(rest, posix=True)
    except ValueError:
        if name == "env" and "-S" not in rest and "--split-string" not in rest:
            return None
        return (name, None, WHY_QUOTE)
    if name == "eval":
        args = words[1:]
        if args and args[0] == "--":
            args = args[1:]
        return ("eval", " ".join(args), "") if args else None
    if name == "env":
        return _env_split_string(words)
    if name in ARGUMENT_RUNNERS:
        # A redirection is the shell's, never the program's argument.
        kept, k = [], 0
        while k < len(words):
            m = REDIRECT_WORD.match(words[k]) if k else None
            if m:
                k += 1 if m.group(1) else 2
                continue
            kept.append(words[k])
            k += 1
        return ARGUMENT_RUNNERS[name](kept)
    has_c, reads_input, operands, options = False, False, [], True
    k = 1
    while k < len(words):
        w = words[k]
        m = REDIRECT_WORD.match(w)
        if m:
            if w.lstrip("0123456789").startswith("<"):
                reads_input = True
            k += 1 if m.group(1) else 2
            continue
        if options and w in ("--", "-"):
            options = False
        elif options and w in ("--version", "--help"):
            return None
        elif options and w.startswith("--"):
            k += 1 if w not in SHELL_VALUED else 2
            continue
        elif options and w[:1] in ("-", "+") and len(w) > 1:
            letters = w[1:]
            if w[0] == "-" and "c" in letters:
                has_c = True
            if w[0] == "-" and "s" in letters:
                reads_input = True
            k += 1 + letters.count("o") + letters.count("O")
            continue
        else:
            options = False
            operands.append(w)
        k += 1
    if has_c:
        return (name + " -c", operands[0], "") if operands else None
    if operands and not reads_input:
        # A script file: its commands are in the file, not the command, and no gate reads files.
        return (name, None, WHY_FILE % operands[0])
    return (name, None, WHY_INPUT)


def _options(words, values, longs, k=1):
    """The index of the first word past a program's own options from k: a short option taking a value
    (a letter in values) takes the rest of its word or the next word, a long one in longs the next
    word unless written with =, and -- ends them."""
    while k < len(words):
        w = words[k]
        if w == "--":
            return k + 1
        if w.startswith("--"):
            k += 2 if ("=" not in w and w in longs) else 1
            continue
        if w.startswith("-") and len(w) > 1:
            letters = w[1:]
            at = next((j for j, ch in enumerate(letters) if ch in values), None)
            k += 2 if at is not None and at == len(letters) - 1 else 1
            continue
        return k
    return k


def _find_exec(words):
    """wrapped() for find: the commands its -exec, -execdir, -ok and -okdir run, each ending at ; or
    at {} +, as one command line; None when it runs none."""
    out, label, why, k = [], "find -exec", "", 1
    while k < len(words):
        w = words[k]
        if w in ("-exec", "-execdir", "-ok", "-okdir"):
            end = k + 1
            while end < len(words) and not (words[end] == ";" or (words[end] == "+" and words[end - 1] == "{}")):
                end += 1
            if w.endswith("dir"):
                label, why = "find " + w, WHY_EXECDIR
            if end >= len(words):
                return (label if why else "find " + w, None, why or WHY_UNENDED % w)
            out.append(rejoin(words[k + 1:end]))
            k = end + 1
            continue
        k += 1
    return (label, "; ".join(out), why) if out else None


def _watch(words):
    """wrapped() for watch: its words, run by sh -c joined by spaces, or as they stand under -x."""
    k = _options(words, "nq", {"--interval", "--equexit"})
    if k >= len(words):
        return None
    as_words = any(w in ("-x", "--exec") or (w.startswith("-") and not w.startswith("--") and "x" in w[1:])
                   for w in words[1:k])
    return ("watch", rejoin(words[k:]) if as_words else " ".join(words[k:]), "")


SCRIPT_VALUED_LONGS = {"--echo", "--log-in", "--log-out", "--log-io", "--log-timing", "--logging-format",
                       "--output-limit"}


def _script(words):
    """wrapped() for script: util-linux's -c string, or macOS's command after the file it writes."""
    k = 1
    while k < len(words):
        w = words[k]
        if w in ("-c", "--command"):
            return ("script", words[k + 1], "") if k + 1 < len(words) else None
        if w.startswith("--command="):
            return ("script", w.split("=", 1)[1], "")
        if w.startswith("-") and not w.startswith("--") and "c" in w[1:]:
            rest = w[w.index("c") + 1:]
            if rest:
                return ("script", rest, "")
            return ("script", words[k + 1], "") if k + 1 < len(words) else None
        if w == "--":
            k += 1
            break
        if w.startswith("--"):
            k += 2 if ("=" not in w and w in SCRIPT_VALUED_LONGS) else 1
            continue
        if w.startswith("-") and len(w) > 1:
            letters = w[1:]
            at = next((j for j, ch in enumerate(letters) if ch in "tEIOBTmo"), None)
            k += 2 if at is not None and at == len(letters) - 1 else 1
            continue
        break
    operands = words[k:]
    return ("script", rejoin(operands[1:]), "") if len(operands) > 1 else None


PARALLEL_VALUED_LONGS = {"--jobs", "--arg-file", "--sshlogin", "--delimiter", "--max-args", "--max-replace-args",
                         "--max-lines", "--max-chars", "--joblog", "--results", "--tmpdir", "--workdir", "--wd",
                         "--timeout", "--retries", "--halt", "--delay", "--memfree", "--load", "--env",
                         "--tagstring", "--colsep", "--basefile", "--return", "--sshloginfile", "--sqlandworker"}


def _parallel(words):
    """wrapped() for GNU parallel: its command before :::, run by a shell; with none, each argument
    after ::: is a command line of its own; with neither, it reads its commands from its input."""
    k = _options(words, "jaSIdEnNPLs", PARALLEL_VALUED_LONGS)
    seps = (":::", "::::", ":::+", "::::+")
    end = next((j for j in range(k, len(words)) if words[j] in seps), len(words))
    if end > k:
        return ("parallel", " ".join(words[k:end]), "")
    if end < len(words) and words[end] == ":::":
        args = [a for a in words[end + 1:] if a not in seps]
        return ("parallel", "; ".join(args), "") if args else None
    return ("parallel", None, WHY_INPUT)


# The programs that run a command line made of their own arguments (claude-config#1478), as the mods'
# reader (mod-kit hooks/commands.ts) reads find -exec.
ARGUMENT_RUNNERS = {"find": _find_exec, "watch": _watch, "script": _script, "parallel": _parallel}


def _env_split_string(words):
    """wrapped() for env: the string its -S (--split-string) splits into the command, else None."""
    values, longs = RUNNERS["env"]
    k = 1
    while k < len(words):
        w = words[k]
        if w in ("-S", "--split-string") or w.startswith("--split-string="):
            if "=" in w:
                value, after = w.split("=", 1)[1], words[k + 1:]
            else:
                value, after = (words[k + 1] if k + 1 < len(words) else ""), words[k + 2:]
            break
        if w.startswith("-") and not w.startswith("--") and len(w) > 1:
            letters = w[1:]
            at = next((j for j, ch in enumerate(letters) if ch in values), None)
            if at is not None and letters[at] == "S":
                value = letters[at + 1:] or (words[k + 1] if k + 1 < len(words) else "")
                after = words[k + 1 + (0 if letters[at + 1:] else 1):]
                break
            k += 2 if at is not None and at == len(letters) - 1 else 1
            continue
        if w.startswith("--"):
            k += 2 if ("=" not in w and w in longs) else 1
            continue
        if ASSIGNMENT.match(w):
            k += 1
            continue
        return None
    else:
        return None
    return ("env -S", " ".join([value] + [shlex.quote(a) for a in after]), "")


def _records(s, cwd, depth):
    """(records, crude) for a command line: each record (dir, text, wrap, rest, assigns, field, depth), a
    wrapper's commands right after it (claude-config#1478). wrap is "" for a command that is no
    wrapper, the wrapper's name (`bash -c`, `eval`, ...) for one whose string was read, and that name
    0x1d the reason for one whose string cannot be read; depth is how many wrappers it is inside; crude
    says s itself could only be read by the crude cut."""
    try:
        cut, crude = commands(s, cwd), False
    except Unreadable:
        cut, crude = crude_commands(s, cwd), True
    out = []
    for d, t in cut:
        rest, assigns, field = program_field(t)
        found = wrapped(rest)
        if found is None:
            out.append((d, t, "", rest, assigns, field, depth))
            continue
        wrapper, string, why = found
        inner = []
        if string is not None:
            if depth >= MAX_DEPTH:
                why = why or WHY_DEEP
            else:
                inner, inner_crude = _records(string, d, depth + 1)
                if inner_crude:
                    why = why or WHY_QUOTE
                for _, t2, _, rest2, _, _, _ in inner:
                    if why:
                        break
                    head, _ = first_word(rest2)
                    if head and head[0] in "$`":
                        why = WHY_VARIABLE
                    elif wrapper == "eval" and cd_target(t2) is not None:
                        why = WHY_EVAL_CD
        out.append((d, t, wrapper + ("\x1d" + why if why else ""), rest, assigns, field, depth))
        out.extend(inner)
    return out, crude


def every_command(s, cwd=""):
    """Every command s runs, as (dir, text, wrapper, why, depth): the commands reading (commands(), or the
    crude cut when it cannot be trusted) with the commands each wrapper runs right after it (wrapped,
    claude-config#1478). wrapper is "" for a command that is none; why is "" unless the wrapper's
    string cannot be read, and then says why; depth is how many wrappers the command is inside."""
    out = []
    for d, t, wrap, _, _, _, depth in _records(s, cwd, 0)[0]:
        wrapper, _, why = wrap.partition("\x1d")
        out.append((d, t, wrapper, why, depth))
    return out


def read(s):
    """The commands reading, each record with its words, its git -C directory and whether it is alone.

    Everything lib/push-scope.sh and lib/merge-target.sh ask of one command, answered by one python
    start rather than one per command (claude-config#1040): ps_is_git_push asked python for the words
    of every command in the line, so a heredoc commit, forty short commands and a push started 44
    pythons in every push hook (measured 2026-10-12). The commands a wrapper runs are records of their
    own after it (claude-config#1478), and a wrapper is never alone, since read on its own it is more
    than one command.
    """
    records, crude = _records(s, "", 0)
    out = []
    for d, t, wrap, rest, assigns, field, _ in records:
        fields = (d, t, "\x1f".join(command_words(t)), git_dir(rest), "1" if not wrap and alone(t) else "0",
                  rest, assigns, field, wrap)
        out.append("\x1c".join(fields) + "\x1e")
    return "".join(out), 3 if crude else 0


# A script whose arguments are data (claude-config#1574). `bash ./x.sh` cannot be read, since its
# commands are in the file, so check-wrapped-commands.sh refuses it beside any word git, gh or rtk,
# quoted argument text included. A few script subcommands are known to run none of their arguments
# (issue-spool.sh's note hands each to python as a string), and the guard declares them; for one of
# them, called alone, the words inside its arguments are data. data_blanked() reads that one shape and
# nothing else: the command as written with every argument after the subcommand that is quoted whole
# replaced by '', so the guard can look for git, gh and rtk in what is left; None for any other
# shape, which the guard refuses exactly as before. Anything a shell would do more than split words
# and remove quotes ends the reading with None: an operator, a redirection, a substitution or
# variable (a $ or a backtick, quoted or not), a backslash, a glob or brace outside quotes, a comment,
# an assignment or option before the script, a newline outside quotes, a quote that never closes.
DATA_UNQUOTED_REFUSED = set(";&|<>()$`\\*?[]{}!#\n")


def _data_words(s):
    """(raw, value, quoted_whole) for each word of s, or None when s holds anything past plain words
    and quotes (DATA_UNQUOTED_REFUSED, a $ or backtick inside double quotes, a quote never closed)."""
    words, raw, value, quoted, unquoted, k = [], "", "", False, False, 0
    s = s.strip(" \t\n")
    while k < len(s):
        ch = s[k]
        if ch in " \t":
            if raw:
                words.append((raw, value, quoted and not unquoted))
                raw, value, quoted, unquoted = "", "", False, False
            k += 1
            continue
        if ch == "'":
            end = s.find("'", k + 1)
            if end < 0:
                return None
            raw += s[k:end + 1]; value += s[k + 1:end]; quoted = True
            k = end + 1
            continue
        if ch == '"':
            j, piece = k + 1, ""
            while j < len(s) and s[j] != '"':
                if s[j] in "$`":
                    return None
                if s[j] == "\\" and j + 1 < len(s) and s[j + 1] in '"\\\n':
                    piece += s[j + 1]; j += 2
                    continue
                piece += s[j]; j += 1
            if j >= len(s):
                return None
            raw += s[k:j + 1]; value += piece; quoted = True
            k = j + 1
            continue
        if ch in DATA_UNQUOTED_REFUSED:
            return None
        raw += ch; value += ch; unquoted = True
        k += 1
    if raw:
        words.append((raw, value, quoted and not unquoted))
    return words


def data_blanked(s, declared, home):
    """s with every argument quoted whole after a declared script subcommand replaced by '', when s is
    exactly `bash <script> <subcommand> <arguments>` for one of declared ("<path> <subcommand>", the
    path under ~/), else None. The script is matched on its whole path, written ~/ or from home, so a
    script of the same name elsewhere is no match."""
    words = _data_words(s)
    if not words or len(words) < 3 or words[0][0] != "bash" or not home.startswith("/"):
        return None
    raw_path, path, _ = words[1]
    if raw_path.startswith("~/"):
        path = home.rstrip("/") + raw_path[1:]
    for entry in declared:
        script, _, sub = entry.rpartition(" ")
        if not script.startswith("~/") or not sub:
            continue
        if path == home.rstrip("/") + script[1:] and words[2][1] == sub:
            kept = [w[0] for w in words[:3]] + ["''" if whole else r for r, _, whole in words[3:]]
            return " ".join(kept)
    return None


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    data = sys.stdin.read()
    if mode == "words":
        sys.stdout.write("\x1f".join(command_words(data)))
    elif mode == "gitdir":
        sys.stdout.write(git_dir(command_rest(data)[0]))
    elif mode == "tool":
        # One command's gh, git or rtk reading (program_field), for a command lib/push-scope.sh holds
        # no reading of. Exit 0 with nothing printed for a command that runs none of them, so any
        # other exit is a reader that failed, which the caller must not take for "runs none" (L42).
        sys.stdout.write(program_field(data)[2])
    elif mode == "bare":
        sys.stdout.write(bare(data))
    elif mode == "data-blanked":
        # The declared script subcommands are the arguments; exit 1, printing nothing, for any other
        # shape (claude-config#1574).
        shown = data_blanked(data, argv[2:], os.environ.get("HOME", ""))
        if shown is None:
            return 1
        sys.stdout.write(shown)
    elif mode == "read":
        text, rc = read(data)
        sys.stdout.write(text)
        return rc
    elif mode == "commands":
        # Exit 3 says only the crude reading was possible; its records are printed all the same.
        try:
            records, rc = commands(data), 0
        except Unreadable:
            records, rc = crude_commands(data), 3
        sys.stdout.write("".join(d + "\x1f" + t + "\x1e" for d, t in records))
        return rc
    elif mode == "split":
        if data.endswith("\n"):
            data = data[:-1]
        assigns, rest = split(data)
        sys.stdout.write("".join(a + "\n" for a in assigns) + "\x1f\n" + rest)
    else:
        sys.stderr.write("usage: shell-words.py read|commands|split|words|gitdir|bare|tool < text, or data-blanked '<path> <subcommand>'... < text\n")
        return 64
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
