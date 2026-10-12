#!/usr/bin/env python3
"""shell-words.py: a command read the way the shell nests quotes and substitutions, for the merge
matcher in merge-target.sh (claude-config#788).

Written in python because the same scan in bash, a character at a time, took 55 seconds on a 26 KB
command (an issue body mentioning a merge), measured 2026-10-05; every merge gate runs it, and a
hook that slow is killed and the command goes unscreened.

  shell-words.py segments   stdin: a command (heredoc bodies already removed)
      prints each segment on its own line, cut at && || ; and newlines only where nothing is open.
      A newline INSIDE a segment (in a quoted string) becomes a space, so line readers stay whole.
      With anything left open at the end (an unclosed quote, as in `echo don't; gh pr merge 7`),
      the reading cannot be trusted and the plain cut at every separator is printed instead: a
      separator inside quotes then over cuts, which can only show the gates MORE merges (L42).
  shell-words.py split      stdin: one segment
      prints its leading NAME=value assignments, one per line, value with one layer of outermost
      quotes removed, then a line holding only the 0x1f separator, then the command that follows.
  shell-words.py commands   stdin: a whole command, as typed or with each newline flattened to "; "
      every simple command the shell would run, each as "<dir>" 0x1f "<text>" 0x1e, where <dir>
      is the directory the cd commands before it have moved its shell to (empty for none). The
      reader behind lib/push-scope.sh's questions about a push (claude-config#1017); see commands().
  shell-words.py words      stdin: one command
      its words as the shell reads them, quotes removed, joined by 0x1f, past any leading reserved
      word (then, do, else, ...), so the first word is the command's own; see command_words().
  shell-words.py gitdir     stdin: one command
      the directory its `git -C` options name, several composed as git composes them, or nothing
      when it is not git or names no -C; see git_dir().
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


def segments(s):
    out, cur, stack = [], [], []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        nx = s[i + 1] if i + 1 < n else ""
        top = stack[-1] if stack else ""
        if top == "'":
            if c == "'":
                stack.pop()
            cur.append(c)
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            cur.append(c + nx)
            i += 2
            continue
        if not stack:
            if c + nx in ("&&", "||"):
                out.append("".join(cur))
                cur = []
                i += 2
                continue
            if c in ";\n":
                out.append("".join(cur))
                cur = []
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
        elif c == "`":
            if top == "`":
                stack.pop()
            else:
                stack.append(c)
        elif c == "$" and nx in ("(", "{"):
            stack.append(nx)
            cur.append(c + nx)
            i += 2
            continue
        elif c == "(":
            if stack and top != '"':
                stack.append(c)
        elif c == ")":
            if top == "(":
                stack.pop()
        elif c == "}":
            if top == "{":
                stack.pop()
        cur.append(c)
        i += 1
    if stack:
        plain = s.replace("&&", "\n").replace("||", "\n").replace(";", "\n")
        return plain.split("\n")
    out.append("".join(cur))
    return [seg.replace("\n", " ") for seg in out]


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


GIT_VALUED = {"-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}


def git_dir(text):
    """The directory ONE command's `git -C` options move git to, or "" when it names none.

    Several -C compose the way git composes them: each relative one is taken from the one before
    (claude-config#589). Read past leading reserved words and assignments (command_words), so
    `do git -C <wt> push` names <wt> (#1017). Only a leading tilde is expanded; a variable stays as
    written, so the caller refuses it.
    """
    words = command_words(text)
    i, n = 0, len(words)
    while i < n and ASSIGNMENT.match(words[i]):
        i += 1
    if i < n and words[i].split("/")[-1] == "rtk":
        i += 1
    if i >= n or words[i].split("/")[-1] != "git":
        return ""
    i += 1
    where = ""
    while i < n and words[i].startswith("-"):
        if words[i] == "-C" and i + 1 < n:
            p = words[i + 1]
            p = os.path.expanduser(p) if p.startswith("~") else p
            where = p if (not where or p.startswith("/")) else os.path.join(where, p)
            i += 2
        else:
            i += 2 if words[i] in GIT_VALUED else 1
    return where


def bare(s):
    """One command with the contents of every $( ) and backquote substitution taken out.

    What the command runs ITSELF, as against what it runs inside its substitutions (#1062).
    commands() lists `out=$(cd A && git push)` beside the push inside it, and a push recogniser
    that reads substitutions afresh says yes to both; the outer one is a container, and judging it
    puts the push in the outer shell's directory. `git push origin "$(git branch)"` is still a push
    with its substitution emptied, and stays one. Quotes and parentheses are read as segments()
    reads them, quotes opening afresh inside a substitution. A substitution left open at the end
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


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    data = sys.stdin.read()
    if mode == "segments":
        sys.stdout.write("".join(seg + "\n" for seg in segments(data)))
    elif mode == "words":
        sys.stdout.write("\x1f".join(command_words(data)))
    elif mode == "gitdir":
        sys.stdout.write(git_dir(data))
    elif mode == "bare":
        sys.stdout.write(bare(data))
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
        sys.stderr.write("usage: shell-words.py segments|split|commands|words|gitdir|bare < text\n")
        return 64
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
