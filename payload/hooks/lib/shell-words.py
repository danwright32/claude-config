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
      gh or git subcommand it runs, tool_field: tool 0x1d sub 0x1d act 0x1d words, or empty>"
      0x1e. Exit 3 as commands; see read(), command_rest(), gh_path() and git_path().
  shell-words.py tool       stdin: one command
      the gh or git subcommand it runs, as gh and git themselves find it past the options written in
      front (tool_field), or nothing when it runs neither, exit 0 either way (claude-config#1188).
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


def commands(s):
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
    """
    n = len(s)
    line_break = "\n" if "\n" in s else "; "
    closing_line = re.escape(line_break) + "%s%s" + (r"(?=\n|$)" if line_break == "\n" else r"(?=;|$)")
    out, pending = [], []
    frames = [{"k": "top", "start": 0, "cwd": "", "old": None}]

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


def crude_commands(s):
    """The reading used when commands() cannot be trusted: a cut at every separator, quotes and all.

    It can only see MORE commands than are there, which is the direction a gate that must not miss a
    push needs (L42), and it keeps the cds in order, so the last one before a push still governs it.
    """
    out, cwd, old = [], "", None
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


def command_rest(text):
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
    assigns, rest = split(s)
    rest, more = past_runners(rest)
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
}


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


def past_runners(rest):
    """The command past any rtk, env or sudo in front of it, each with its options, and the NAME=value
    settings env or sudo gives it, which are the command's own assignments as much as a leading one.
    A runner whose command cannot be read from its words (env -S, which splits a string into one) is
    left as it stands, the command then being that runner's."""
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
    if not words:
        return None
    first = words[0].lstrip("({")
    words = ([first] if first else []) + list(words[1:])
    if not words:
        return None
    # Written back as the shell would read the same words. An assignment keeps its name outside the
    # quotes, `NAME='a b'`, so command_rest still reads it as one: quoted whole, as shlex.join quotes
    # it, `env GH_TOKEN="a b" gh issue create` read as a command named GH_TOKEN=a b (the lessons
    # review of #1188).
    text = " ".join(w[:m.end()] + shlex.quote(w[m.end():]) if m else shlex.quote(w)
                    for w, m in ((w, ASSIGNMENT.match(w)) for w in words))
    rest, _ = command_rest(text)
    return tool_read(command_words(rest))


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


def read(s):
    """The commands reading, each record with its words, its git -C directory and whether it is alone.

    Everything lib/push-scope.sh and lib/merge-target.sh ask of one command, answered by one python
    start rather than one per command (claude-config#1040): ps_is_git_push asked python for the words
    of every command in the line, so a heredoc commit, forty short commands and a push started 44
    pythons in every push hook (measured 2026-10-12).
    """
    try:
        records, rc = commands(s), 0
    except Unreadable:
        records, rc = crude_commands(s), 3
    out = []
    for d, t in records:
        rest, assigns = command_rest(t)
        fields = (d, t, "\x1f".join(command_words(t)), git_dir(rest), "1" if alone(t) else "0", rest, assigns,
                  tool_field(rest))
        out.append("\x1c".join(fields) + "\x1e")
    return "".join(out), rc


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    data = sys.stdin.read()
    if mode == "words":
        sys.stdout.write("\x1f".join(command_words(data)))
    elif mode == "gitdir":
        sys.stdout.write(git_dir(command_rest(data)[0]))
    elif mode == "tool":
        # One command's gh or git reading (tool_field), for a command lib/push-scope.sh holds no
        # reading of. Exit 0 with nothing printed for a command that runs neither, so any other exit
        # is a reader that failed, which the caller must not take for "runs neither" (L42).
        sys.stdout.write(tool_field(command_rest(data)[0]))
    elif mode == "bare":
        sys.stdout.write(bare(data))
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
        sys.stderr.write("usage: shell-words.py read|commands|split|words|gitdir|bare|tool < text\n")
        return 64
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
