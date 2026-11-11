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
      cannot be read; `direct` or `source` with 0x1d and why, for a script file run by its path or
      sourced, which hands no string (claude-config#1623); else empty>" 0x1e, the commands a wrapper runs being records of their own right
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
  shell-words.py heredoc-markers   stdin: a whole file
      each heredoc it opens, read a line at a time as heredoc_openers reads one, printed as
      "<line number>" TAB "<end marker>", one per line, so a scan written in awk reads markers as
      this file does (claude-config#2080); see heredoc_openers().
  shell-words.py bare       stdin: one command
      the command with the contents of every $( ) and backquote substitution taken out, so a caller
      can ask what it runs itself rather than inside them (claude-config#1062); see bare().
  shell-words.py data-blanked '<path>[ <subcommand>]'...   stdin: a whole command
      when the command is exactly `bash <path> [<subcommand>] <words>`, or `<path> [<subcommand>]
      <words>` with the script run by its path (claude-config#1623), for one of the declared
      entries (path under ~/), with nothing in front but GH_TOKEN=$(gh auth token -u <login>), it
      printed from `bash` (or the path) on with every argument after the path (or the subcommand) that is quoted
      whole replaced by '', exit 0; for any other shape nothing, exit 1 (claude-config#1574, #1610).
      The reader check-wrapped-commands.sh asks before refusing a script file; see data_blanked().

The context stack: " ' ` quotes, $( and ${ substitutions, and plain ( inside a substitution.
Inside a substitution quotes open afresh, so X="$(a "b c")" is one word.
"""
import os
import re
import shlex
import io
import sys


def is_name(word):
    return bool(word) and (word[0].isalpha() or word[0] == "_") and all(ch.isalnum() or ch == "_" for ch in word)


def join_continuations(s):
    """s with every backslash newline the shell removes taken out: one outside single quotes is a line
    continuation, gone before the words are read, and inside single quotes it is two characters the
    shell keeps. shlex reads it as an escaped newline, a word of its own, so a command continued that
    way had a newline for its first word and its assignments left in front (claude-config#2447)."""
    if "\\\n" not in s:
        return s
    out, i, n, quote = [], 0, len(s), ""
    while i < n:
        c = s[i]
        if quote == "'":
            if c == "'":
                quote = ""
            out.append(c)
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            if s[i + 1] == "\n":
                i += 2
                continue
            out.append(s[i:i + 2])
            i += 2
            continue
        if c == "'" and quote != '"':
            quote = "'"
        elif c == '"':
            quote = "" if quote == '"' else '"'
        out.append(c)
        i += 1
    return "".join(out)


def split(s, limit=None):
    """(the leading NAME=value assignments of s, the text after them); at most limit of them when
    limit is given, so past_redirects can read one redirection's target as one value."""
    assigns = []
    s = join_continuations(s).lstrip()
    while limit is None or len(assigns) < limit:
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
# A heredoc's opener up to its end marker word: <<, or <<- which strips leading tabs, and blanks.
HEREDOC_START = re.compile(r"<<(-?)[ \t]*")
# What ends the end marker word, as the shell reads a word.
HEREDOC_WORD_END = set(" \t\n;&|<>()")
# How an end marker word starts for a reader that follows no arithmetic: a letter or underscore,
# either one after a backslash, or a quote, $' and $" included. The limit mod-kit's hooks/commands.ts
# keeps for the same reason (claude-config#2073), so `$((1<<2))` opens no heredoc there or here.
MARKER_START = re.compile(r"""\\?[A-Za-z_]|\$?['"]""")
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
# A case command's head up to its `in`, past any reserved words before it, and an esac ending one
# (claude-config#2074): a pattern after the `in`, or after a `;;` or `;&`, ends at a `)` that closes
# no subshell, and its `|` joins two patterns rather than piping.
_PREFIX = r"\s*(?:(?:" + "|".join(re.escape(w) for w in sorted(RESERVED)) + r")\s+)*"
CASE_HEAD = re.compile(_PREFIX + r"case\s+\S.*?\s+in(?=[\s(]|$)", re.S)
CASE_END = re.compile(_PREFIX + r"esac(?=[\s;&|()<>]|$)")
# What ends a command, as (how it ended, its width). Two characters are looked up before one, so
# && is never read as a backgrounding & and || never as a pipe.
SEPARATORS = {"&&": ("&&", 2), "||": ("||", 2), "|&": ("|", 2), ";;": (";", 2),
              "|": ("|", 1), ";": (";", 1), "\n": (";", 1)}


class Unreadable(Exception):
    """Something opened and never closed, so this reading cannot be trusted.

    at is where in the command the outermost quote still open at the end was opened, None when what
    is open is not a quote (a substitution, a group), so a caller can say which quote and where.
    """

    def __init__(self, at=None):
        super().__init__()
        self.at = at


def heredoc_opener(s, i, marker_start=False):
    """The heredoc opened at s[i] ("<<"), as (marker, strip_tabs, quoted, end), or None.

    The marker is the word after the opener with its quotes removed, as the shell compares it with
    each body line; quoted says whether ANY part of it was quoted, by quotes or a backslash, whole
    (`'EOF'`, `"EOF"`, `\\EOF`) or in part (`E"OF"`, `E\\OF`, `$'EOF'`), because then the shell
    expands nothing in the body, and otherwise it expands it and runs every substitution in it
    (claude-config#2053). Measured on this Mac's bash and zsh, 2026-11-01. None when there is no word,
    or a quote in it never closes.

    With marker_start, also None when the word does not start as a marker is written (MARKER_START),
    for a reader that follows neither arithmetic nor, in some, quotes (claude-config#2080).
    """
    m = HEREDOC_START.match(s, i)
    if not m or s.startswith("<<<", i):
        return None
    if marker_start and not MARKER_START.match(s, m.end()):
        return None
    j, n = m.end(), len(s)
    word, quoted = [], False
    while j < n and s[j] not in HEREDOC_WORD_END:
        c = s[j]
        if c == "\\" and j + 1 < n:
            word.append(s[j + 1])
            quoted = True
            j += 2
        elif c == "'" or (c == "$" and s.startswith("$'", j)):
            j += 2 if c == "$" else 1
            k = s.find("'", j)
            if k < 0:
                return None
            word.append(s[j:k])
            quoted = True
            j = k + 1
        elif c == '"' or (c == "$" and s.startswith('$"', j)):
            j += 2 if c == "$" else 1
            k = j
            while k < n and s[k] != '"':
                k += 2 if s[k] == "\\" else 1
            if k >= n:
                return None
            word.append(re.sub(r'\\([\\"$`])', r"\1", s[j:k]))
            quoted = True
            j = k + 1
        else:
            word.append(c)
            j += 1
    if j == m.end():
        return None
    return "".join(word), m.group(1) == "-", quoted, j


def heredoc_openers(line, marker_start=True):
    """Each heredoc a line opens, read on its own without following its quotes, as (start, marker,
    strip_tabs, quoted, end), start at its << and the rest as heredoc_opener gives them.

    For the whole tree scans that read a file a line at a time and need only where a heredoc's body
    begins and what ends it (claude-config#2080). Such a scan cannot tell a << in a string or in
    arithmetic from one opening a heredoc, so a word is taken only where it starts as a marker is
    written (marker_start): `$((1<<2))` and `grep -c '1<<2'` open nothing, and neither does the
    << of a here string. The cost is a heredoc whose marker starts with a digit, which bash accepts
    and no file here uses.

    With marker_start False every << with a word after it is taken, a here string still apart, for
    a reader that must not miss a heredoc and can afford to count one that is not there: a gate
    refusing a text it cannot follow (claude-config#2641). The text can then be a whole script.
    """
    out, i = [], 0
    while True:
        i = line.find("<<", i)
        if i < 0:
            return out
        if line.startswith("<<<", i):
            i += 3
            continue
        op = heredoc_opener(line, i, marker_start=marker_start)
        if op is None:
            i += 2
            continue
        out.append((i,) + op)
        i = op[3]


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


def commands(s, cwd="", heredocs=None, parts=None):
    """Every simple command in s, in the order the shell finishes reading them, as (dir, text).

    heredocs, when a list, is given one (quoted, before, body) for each heredoc body the reading
    skipped as text (claude-config#2050): quoted says the shell expands nothing in it (its end marker
    is quoted in any form, heredoc_opener), before is the text of the command that opened it up to
    the opener, and body is the text between the opener's line and its closing line. An unquoted
    body is given too, though the substitutions in it are also read as commands (#2053). A body
    that never closes is not skipped, so it is read as commands and given to nobody here.

    The text is the command as written, quotes and all, and a command substitution's text stays
    inside the command that holds it as well as being read as commands of its own, which come first.
    A subshell group is not part of the command around it. Heredoc bodies and comments are nobody's
    text, but the substitutions in the body of a heredoc whose end marker is unquoted are commands,
    since the shell expands that body and runs them (claude-config#2053); a quoted marker, in any
    form, keeps the whole body text (heredoc_opener). s may be the command as typed or with every
    newline flattened to "; " (how the push hooks read it). Which one is decided by whether s holds a newline at all: with one, only a newline is
    a line break, so in `cat <<EOF; git push` the "; " is the separator it is and the push is read
    (lessons review of #1017); with none, "; " is the line break that starts a heredoc body and ends
    a comment, because the flattened text cannot tell a newline from a separator there (main read
    it the same way). Raises Unreadable when anything is still open at the end.

    cwd is the directory s starts in, "" for the session's: a string a wrapper runs (wrapped) starts
    where the wrapper runs (claude-config#1478).

    parts, a list, is given one dict for each entry of the result, in the same order, saying where
    in s that command is and what is written directly in it (claude-config#2059): start and end, its
    text being s[start:end]; scope, the ids of the command frames enclosing it, outermost first and
    its own last (0 is s itself, and each subshell and substitution has an id of its own); inner, a
    (start, end, in_double_quotes) for each substitution written directly in it, start at its `$(`
    or opening backquote and end just past its closing one; and openers, a (start, end) for each
    heredoc opener written directly in it, from its << to the end of its end marker word; and how,
    what ended it: ";" (a `;` or a line break), "&&", "||", "|" (a pipe, `|&` too), "&" (sent to
    the background), "#" (a comment), ")" (its subshell or substitution closing), "\\n" (the line
    a heredoc opens on), "case" (the text before a case pattern, its head, ended where the pattern starts) or "end".
    So a caller can read a command's text as one word for each substitution in it, whose own
    commands it is given separately, and know which shell each command
    runs in, a pipeline's members and a backgrounded command each running in one of their own
    (claude-config#2076).
    """
    n = len(s)
    line_break = "\n" if "\n" in s else "; "
    closing_line = re.escape(line_break) + "%s%s" + (r"(?=\n|$)" if line_break == "\n" else r"(?=;|$)")
    out, pending = [], []
    frames = [{"k": "top", "start": 0, "cwd": cwd, "old": None, "id": 0, "inner": [], "openers": []}]
    ids = [0]
    # The unquoted heredoc bodies being read, innermost last: each is also a frame, kind "hd", that
    # holds text the way a double quoted string does (its quotes are only text), from where its body
    # starts to "end", the start of its closing line, and then the reading goes on at "next".
    bodies = []

    def note_case(f, end):
        """Read the command so far, from f's start to end, for a case head or an esac (#2074).

        f["cases"] holds the case commands open in f, innermost last, each "pattern" while a pattern
        is being read and "body" after it; f["pat"] is where the pattern being read starts. A
        command is noted once, when it first shows either, so a later call on it changes nothing.
        """
        if f.get("noted") == f["start"]:
            return
        text = s[f["start"]:end]
        head = CASE_HEAD.match(text)
        if head:
            f.setdefault("cases", []).append("pattern")
            f["pat"] = f["start"] + head.end()
            f["noted"] = f["start"]
        elif CASE_END.match(text):
            if f.get("cases"):
                f["cases"].pop()
            f["noted"] = f["start"]

    def in_pattern(f, at):
        """Whether `at` is inside a case pattern in f, the command before it noted first."""
        note_case(f, at)
        return bool(f.get("cases")) and f["cases"][-1] == "pattern"

    def end_pattern(f, at):
        """A pattern ends at `at`: the case head before it is a command, and its branch starts after."""
        cut(f, max(f["start"], f.get("pat", f["start"])), "case")
        f["cases"][-1] = "body"
        f["start"] = at + 1

    def cut(f, end, how):
        note_case(f, end)
        text = s[f["start"]:end]
        if not text.strip():
            return
        out.append((f["cwd"], text))
        if parts is not None:
            # The shells it runs in: every command frame open around it, or, once its own has closed
            # (close_commands), every one still open and then its own.
            chain = []
            for g in frames:
                if g is f:
                    break
                if g["k"] in COMMAND_FRAMES:
                    chain.append(g["id"])
            start = f["start"]
            parts.append({"start": start, "end": end, "scope": tuple(chain) + (f["id"],),
                          "inner": [x for x in f["inner"] if start <= x[0] and x[1] <= end],
                          "openers": [x for x in f["openers"] if start <= x[0] and x[1] <= end],
                          "how": how})
        target = cd_target(text)
        # A cd in a pipeline or sent to the background runs in a shell of its own.
        if target is not None and how not in ("|", "&"):
            f["cwd"], f["old"] = moved(f["cwd"], f["old"], target)

    def open_commands(kind, start):
        at = next(j for j in range(len(frames) - 1, -1, -1) if frames[j]["k"] in COMMAND_FRAMES)
        parent = frames[at]
        ids[0] += 1
        frame = {"k": kind, "start": start, "cwd": parent["cwd"], "old": parent["old"], "id": ids[0],
                 "inner": [], "openers": [],
                 # Where it opened, at its $( or backquote, and whether that is inside double quotes
                 # in the text of the command holding it.
                 "open": start - (1 if kind == "tick" else 2),
                 "dq": any(f["k"] == '"' for f in frames[at + 1:])}
        frames.append(frame)

    def close_commands(end):
        f = frames.pop()
        cut(f, end, ")")
        if f["k"] in ("subst", "tick"):
            parent = next(g for g in reversed(frames) if g["k"] in COMMAND_FRAMES)
            parent["inner"].append((f["open"], end + 1, f["dq"]))
        if f["k"] == "sub":
            frames[-1]["start"] = end + 1

    i = 0
    while i < n:
        if bodies and i >= bodies[-1]["end"]:
            # A body ends at its closing line whatever is open in it, as the shell finds the line
            # before it expands anything; a substitution or quote still open there runs nothing in
            # the shell, and is a reading this cannot trust.
            if frames[-1] is not bodies[-1]:
                raise Unreadable()
            frames.pop()
            i = bodies.pop()["next"]
            continue
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
                if frames.pop().get("pattern"):
                    end_pattern(frames[-1], i)
                i += 1
                continue
        if k not in ('"', "hd"):
            if c == "'":
                frames.append({"k": "'", "at": i})
                i += 1
                continue
            if c == "$" and nx == "'":
                frames.append({"k": "ansi", "at": i})
                i += 2
                continue
            if c == '"':
                frames.append({"k": '"', "at": i})
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
            opener = heredoc_opener(s, i)
            if opener:
                before = s[f["start"]:i]
                f["openers"].append((i, opener[3]))
                word, strip_tabs, quoted, i = opener
                pending.append((word, strip_tabs, quoted, before))
            else:
                i += 2
            continue
        if pending and s.startswith(line_break, i):
            # The bodies start on the next line: find the closing line of each in turn. One that never
            # closes is not skipped, so nothing after it is hidden.
            j, unquoted, skipped = i, [], []
            for word, strip_tabs, quoted, before in pending:
                m = re.compile(closing_line % ("\t*" if strip_tabs else "", re.escape(word))).search(s, j)
                if not m:
                    j = None
                    break
                if not quoted:
                    unquoted.append((j, m.start()))
                body = s[j:m.start()]
                skipped.append((quoted, before, body[len(line_break):] if body.startswith(line_break) else body))
                j = m.end()
            if j is not None and heredocs is not None:
                heredocs.extend(skipped)
            pending.clear()
            if j is not None:
                cut(f, i, "\n")
                f["start"] = i = j
                # Each unquoted body is read for its substitutions, the first first, and the reading
                # goes on after the last closing line.
                for start, end in reversed(unquoted):
                    body = {"k": "hd", "end": end, "next": i}
                    frames.append(body)
                    bodies.append(body)
                    i = start
                continue
        two = s[i:i + 2]
        if c == "|" and nx != "|" and in_pattern(f, i):
            i += 1  # a | between two case patterns is part of the pattern, never a pipe
            continue
        separator = SEPARATORS.get(two) or SEPARATORS.get(c)
        if separator:
            how, width = separator
            cut(f, i, how)
            if two in (";;", ";&") and f.get("cases") and f["cases"][-1] == "body":
                f["cases"][-1] = "pattern"  # the branch ends, and the next pattern begins
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
        if c == "(" and in_pattern(f, i):
            # A pattern written (y) opens no subshell, and the ) closing that leading ( ends the
            # pattern. Any other ( in a pattern, an extglob's +( or @(, closes inside it, and the
            # pattern ends at the ) after.
            leading = not s[max(f["start"], f.get("pat", f["start"])):i].strip()
            frames.append({"k": "paren", "pattern": leading})
            i += 1
            continue
        if c == ")" and in_pattern(f, i):
            end_pattern(f, i)
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
        raise Unreadable(next((f["at"] for f in frames if "at" in f), None))
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
    text = join_continuations(text)
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
    assigns, rest = past_head(s)
    rest, more = past_runners(rest, passed)
    return rest, "\n".join(assigns + more)


# A redirection written in front of a command's name (claude-config#2235): its operator, with or
# without a descriptor number in front, at the start of the text as written, so a quoted `'>'` is a
# word and never one. Its target follows, glued to the operator or as the next word.
LEADING_REDIRECT = re.compile(r"\d*(?:<<<|<<-?|<>|<&|>&|>>|>\||&>>?|<|>)")


def past_redirects(s):
    """s past the redirections written in front of its command's name (claude-config#2235).

    The shell takes every redirection out of a command before it finds the name, so `2>/dev/null log
    show` runs log. Read as the name, a target holding a slash was a script run by its path (`direct`)
    that check-wrapped-commands.sh refused beside git, gh or rtk, and `>/tmp/out git push` was a
    command named >/tmp/out, a push no gate saw. The target, glued or the next word, is read as one
    word by split(), which reads a value holding quotes and substitutions to its end, so `2>"a b"` and
    `>$(mktemp -d)/x` are each one target, read exactly as an assignment's value is."""
    while True:
        s = s.lstrip()
        m = LEADING_REDIRECT.match(s)
        if not m:
            return s
        _, s = split("_=" + s[m.end():].lstrip(), 1)


def past_head(s):
    """(the leading NAME=value assignments, the text after them) for s, past the redirections that
    may stand before, between and after them (`2>/dev/null A=1 gh`, `A=1 2>/dev/null gh`), as the
    shell reads both before the command's name (claude-config#2235)."""
    assigns = []
    while True:
        more, s = split(past_redirects(s))
        if not more:
            return assigns, s
        assigns.extend(more)


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
    s = join_continuations(s).lstrip()
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
        more, s = past_head(s)
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
# gh's other names for its commands (claude-config#2398), each read from the ALIASES section of the
# command's own help on gh 2.89.0 (`gh <group> --help`, `gh <group> <action> --help`, for every group
# and action `gh help` lists), and read here as the long form, so every gate asking gh_command or
# tool_field about `gh issue create` is asking about `gh issue new` too. `gh pr new` and `gh issue
# new` were read as (pr, new) and (issue, new), which no gate judged as a create, so text posted
# through them skipped the work names check and an issue filed through them skipped the milestone,
# priority and category check.
#
# GH_GROUP_ALIASES is every other name of a command group. GH_ACTION_ALIASES is every alias of an
# action that writes (create, delete, checkout), keyed by the group's long name. The aliases of list
# (`ls` in 17 groups) are left as written on purpose: list writes nothing, and a gate that reads list
# as a harmless read would pass `gh pr ls` where it now asks, which this change must never do. An alias
# a level further down (`gh repo autolink new`) is past the two words this reading names.
GH_GROUP_ALIASES = {
    "a11y": "accessibility", "cs": "codespace", "at": "attestation", "rs": "ruleset", "ext": "extension",
    "extensions": "extension", "agent": "agent-task", "agents": "agent-task", "agent-tasks": "agent-task",
}
GH_ACTION_ALIASES = {
    ("pr", "new"): "create", ("issue", "new"): "create", ("release", "new"): "create",
    ("gist", "new"): "create", ("repo", "new"): "create", ("secret", "remove"): "delete",
    ("variable", "remove"): "delete", ("pr", "co"): "checkout",
}


def gh_long_form(sub, act):
    """(sub, act) as gh's long names: a group alias and a write action's alias read as what gh runs
    for them (GH_GROUP_ALIASES, GH_ACTION_ALIASES); anything else unchanged."""
    sub = GH_GROUP_ALIASES.get(sub, sub)
    return sub, GH_ACTION_ALIASES.get((sub, act), act)


# git's own options in front of its subcommand that take the next word as their value (`git -C <dir>
# push`, `git -c k=v commit`); every other option there stands alone. The subcommand is the first
# word that is not an option (git.c handle_options).
GIT_VALUED = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}


def gh_path(words):
    """The words after `gh` as gh reads them: (sub, act, front, after). sub and act are the
    subcommand and its action as cobra finds them, by their long names (gh_long_form), empty when
    absent (`api` takes no action), front
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
    sub, act = gh_long_form(path[0] if path else "", path[1] if len(path) > 1 else "")
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
    pieces = [w[:m.end()] + shlex.quote(w[m.end():]) if m else shlex.quote(w)
              for w, m in ((w, ASSIGNMENT.match(w)) for w in words)]
    # A redirection in front of the command's name (claude-config#2235) is written as one, its
    # operator bare, so command_rest passes over it: quoted, `2>/dev/null gh issue create` read as a
    # command named 2>/dev/null and no gate built on these words saw the create. A word is written
    # bare only while it is the word read as the command's name, so the words after the name, and a
    # `>` that is a runner's option value (`sudo -p '>' gh`), read exactly as they always did.
    starts, at = [], 0
    for p in pieces:
        starts.append(at)
        at += len(p) + 1
    for _ in words:
        text = " ".join(pieces)
        rest = command_rest(text)[0]
        k = starts.index(len(text) - len(rest)) if rest and len(text) - len(rest) in starts else None
        bare = _redirect_bare(words[k]) if k is not None else None
        if bare is None or bare == pieces[k]:
            return text
        grew = len(bare) - len(pieces[k])
        pieces[k] = bare
        starts[k + 1:] = [s + grew for s in starts[k + 1:]]
    return " ".join(pieces)


def _redirect_bare(word):
    """word written as the redirection it is, its operator bare and its target quoted (a word as
    shlex.split leaves `2>/dev/null`, or the operator alone, as shell_tokens gives `2>`), or None when
    it is no redirection (claude-config#2235)."""
    m = LEADING_REDIRECT.match(word)
    if not m:
        return None
    return word[:m.end()] + (shlex.quote(word[m.end():]) if m.end() < len(word) else "")


def shell_tokens(text):
    """text's words and operators as shlex's punctuation lexer cuts them, quotes removed, except that
    a descriptor number written against its redirection stays one token with it: `2>/dev/null` is
    `2>` and `/dev/null`, where `2 >/dev/null` is `2`, `>` and `/dev/null` (claude-config#2235).

    The lexer cuts both into the same three tokens, so a reader of them could not tell `2>/dev/null gh
    issue create`, a create, from `2 >/dev/null gh`, a command named 2. Whether the number ended at
    the operator or at a space is what the lexer holds back after it: the operator it read and pushed
    back, or nothing. A lexer keeping no such record reads every number before an operator as its
    descriptor, the reading that sees the command after it. Raises ValueError as shlex does."""
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""
    out, glue = [], False
    while True:
        tok = lexer.get_token()
        if tok is None:
            return out
        if glue and tok[:1] in ("<", ">"):
            out[-1] += tok
        else:
            out.append(tok)
        held = getattr(lexer, "_pushback_chars", None)
        glue = tok.isdigit() and (held is None or any(c in "<>" for c in held))


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

# A script run by its path, or sourced, is a script file run by a shell (claude-config#1623):
# `./build.sh && git push` runs the file's commands as `bash ./build.sh && git push` does, and no gate
# reads the file either way. A command word holding a slash is run as that file, never looked up on
# PATH, so it is a path; the word alone says so, and no file is opened or even looked for, which keeps
# the reading the same for a file the command itself writes first, and costs nothing per command.
# Three kinds of path are no script file of their own. One named git, gh or rtk, which every gate
# reads by that name wherever it lives (`/opt/homebrew/bin/gh pr merge 7` is a merge to all of them).
# A shell, eval, env or an argument runner by its path, read as that program above. And a program in
# one of PROGRAM_DIRS, the directories the system and Homebrew install programs in, which run what the
# same name run bare runs, and a bare name was never read as a script. The path is normalised first,
# so `/usr/bin/../../tmp/x.sh` is in /tmp. `source` and `.` run a file's commands in the shell itself.
# The wrapper is named `direct` for a path and `source` for either spelling of the builtin; the reason
# is WHY_FILE, the one a shell running a script file gives, so the refusal, its record and the
# declared scripts (data_blanked) treat the two alike.
PROGRAM_DIRS = ("/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/System/",
                "/Library/Developer/CommandLineTools/", "/usr/local/bin/", "/usr/local/sbin/",
                "/opt/homebrew/bin/", "/opt/homebrew/sbin/")
READ_BY_NAME = {"git", "gh", "rtk"}
ARRAY_ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\+?=")


def _script_run(word, rest):
    """(wrapper, None, why) for a command whose own word runs a script file, by its path or by
    source or `.`, else None (claude-config#1623)."""
    if word in ("source", "."):
        try:
            operands = shlex.split(rest, posix=True)[1:]
        except ValueError:
            return ("source", None, WHY_QUOTE)
        if operands and operands[0] == "--":
            operands = operands[1:]
        return ("source", None, WHY_FILE % operands[0]) if operands else None
    if "/" not in word or word.split("/")[-1] in READ_BY_NAME:
        return None
    # An array assignment or append (`args+=(x/y)`, `a=(x/y)`) is no command, though split() leaves it,
    # and neither is a word whose name before its first slash holds = or : (a URL, `k=v/x`): the
    # guard's fast path (check-wrapped-commands.sh RUNS_FILE_WORD) passes those over too, so the two
    # agree on what a path is.
    if ARRAY_ASSIGNMENT.match(word) or any(ch in word.split("/")[0] for ch in "=:"):
        return None
    if word.startswith("/") and (os.path.normpath(word) + "/").startswith(PROGRAM_DIRS):
        return None
    return ("direct", None, WHY_FILE % word)


def wrapped(rest):
    """(wrapper, string, why) for one command, from its own name on (command_rest), that runs a string
    as a command line, else None. wrapper names it (`bash -c`, `eval`, `env -S`, or the shell's name
    when it reads its input, `direct` or `source` for a script file run by its path or sourced);
    string is the command line it runs, None when there is none to read; why is "" when the string
    can be read, else the reason it cannot."""
    name, _ = first_word(rest)
    if name is None:
        raw = rest.split(None, 1)
        name = raw[0].strip("'\"") if raw else ""
    word, name = name, name.split("/")[-1]
    if name not in SHELLS and name not in ("eval", "env") and name not in ARGUMENT_RUNNERS:
        return _script_run(word, rest)
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


# ---- the commands in a script file a command runs (claude-config#2301) ---------------------------
# A script file's commands are in the file, so no gate could read them, and `bash ./wrapper.sh`
# holding `git add -A` passed the add scope guard with no git word in the command at all. A caller
# that asks for it (every_command's scripts list) has each script file a command runs read off disk,
# its commands records of their own right after the script's record, in the directory the script runs
# in, recursively up to MAX_DEPTH. The script's own record keeps its reason (WHY_FILE), so whatever a
# gate refused for an unreadable script it still refuses: reading only ever adds commands. A file that
# is not there, cannot be read, is larger than SCRIPT_MAX_BYTES, is named through a variable, or is
# run by its path with a #! line naming no shell (a python script) is left unread, as before.
SCRIPT_MAX_BYTES = 256 * 1024
_WHY_FILE_HEAD, _, _WHY_FILE_TAIL = WHY_FILE.partition("%s")


def script_file(why):
    """The script file a WHY_FILE reason names, as written, or None for any other reason."""
    if why.startswith(_WHY_FILE_HEAD) and why.endswith(_WHY_FILE_TAIL) \
            and len(why) > len(_WHY_FILE_HEAD) + len(_WHY_FILE_TAIL):
        return why[len(_WHY_FILE_HEAD):len(why) - len(_WHY_FILE_TAIL)]
    return None


def script_text(path, d, wrapper):
    """(full path, text) of the script file path names, run by wrapper in directory d, or None when it
    cannot be read: not there, unreadable, too large, a variable in its name, a relative name with no
    absolute directory to resolve it against, or a file run by its path whose #! names no shell."""
    if "$" in path or "`" in path:
        return None
    path = os.path.expanduser(path)
    if not os.path.isabs(path):
        if not os.path.isabs(d or ""):
            return None
        path = os.path.join(d, path)
    path = os.path.normpath(path)
    try:
        if not os.path.isfile(path):
            return None
        with open(path, "rb") as f:
            data = f.read(SCRIPT_MAX_BYTES + 1)
    except OSError:
        return None
    if len(data) > SCRIPT_MAX_BYTES:
        return None
    text = data.decode("utf-8", "replace")
    if wrapper == "direct" and text.startswith("#!"):
        line = text.split("\n", 1)[0][2:].split()
        names = [w.split("/")[-1] for w in line[:2]]
        if not any(n in SHELLS for n in names):
            return None
    return path, text


def _records(s, cwd, depth, scripts=None):
    """(records, crude) for a command line: each record (dir, text, wrap, rest, assigns, field, depth), a
    wrapper's commands right after it (claude-config#1478). wrap is "" for a command that is no
    wrapper, the wrapper's name (`bash -c`, `eval`, ...) for one whose string was read, and that name
    0x1d the reason for one whose string cannot be read; depth is how many wrappers it is inside; crude
    says s itself could only be read by the crude cut. scripts, a list, asks for the commands of each
    script file a command runs as well, right after its record, and is given (path, text) for each
    one read (claude-config#2301)."""
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
        if string is None and scripts is not None and depth < MAX_DEPTH and script_file(why):
            found_script = script_text(script_file(why), d, wrapper)
            if found_script is not None:
                # Given in the order the records are, so the nth script whose commands follow its
                # record is the nth entry; one holding no command is taken back out.
                scripts.append(found_script)
                at = len(scripts) - 1
                # Its commands, never its reason: the script's record keeps WHY_FILE below.
                inner, _ = _records(found_script[1], d, depth + 1, scripts)
                if not inner:
                    del scripts[at]
        if string is not None:
            if depth >= MAX_DEPTH:
                why = why or WHY_DEEP
            else:
                inner, inner_crude = _records(string, d, depth + 1, scripts)
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


def every_command(s, cwd="", scripts=None):
    """Every command s runs, as (dir, text, wrapper, why, depth): the commands reading (commands(), or the
    crude cut when it cannot be trusted) with the commands each wrapper runs right after it (wrapped,
    claude-config#1478). wrapper is "" for a command that is none; why is "" unless the wrapper's
    string cannot be read, and then says why; depth is how many wrappers the command is inside.
    scripts, a list, reads each script file a command runs too, its commands right after the script's
    record one wrapper deeper, and is given (path, text) for each file read (claude-config#2301); a
    relative script name is resolved only against an absolute cwd, so pass the session's directory."""
    out = []
    for d, t, wrap, _, _, _, depth in _records(s, cwd, 0, scripts)[0]:
        wrapper, _, why = wrap.partition("\x1d")
        out.append((d, t, wrapper, why, depth))
    return out


def read(s):
    """The commands reading, each record with its words, its git -C directory and whether it is alone.

    Everything lib/push-scope.sh and lib/merge-target.sh ask of one command, answered by one python
    start rather than one per command (claude-config#1040): ps_is_git_push asked python for the words
    of every command in the line, so a heredoc commit, forty short commands and a push started 44
    pythons in every push hook (measured 2026-10-12). The commands a wrapper runs are records of their
    own after it (claude-config#1478), and a wrapper that holds a string is never alone, since read on
    its own it is more than one command; a script run by its path or sourced (`direct`, `source`,
    claude-config#1623) holds none, so it can be alone as any plain command can.
    """
    records, crude = _records(s, "", 0)
    out = []
    for d, t, wrap, rest, assigns, field, _ in records:
        # A script run by its path or sourced holds no records of its own (claude-config#1623), so
        # it can be alone as any plain command can.
        container = wrap and wrap.partition("\x1d")[0] not in ("direct", "source")
        fields = (d, t, "\x1f".join(command_words(t)), git_dir(rest), "1" if not container and alone(t) else "0",
                  rest, assigns, field, wrap)
        out.append("\x1c".join(fields) + "\x1e")
    return "".join(out), 3 if crude else 0


# A script whose arguments are data (claude-config#1574). `bash ./x.sh` cannot be read, since its
# commands are in the file, so check-wrapped-commands.sh refuses it beside any word git, gh or rtk,
# quoted argument text included. A few scripts, or subcommands of them, are known to run none of
# their arguments (issue-spool.sh's note hands each to python as a string; milestone-candidates.sh,
# #1610, only reads from GitHub), and the guard declares them; for one of them the words inside its
# arguments are data. data_blanked() reads that one shape and nothing else: the call, with only
# DATA_TOKEN_PREFIX in front and only 2>&1 and pipes into DATA_FILTERS behind, printed with every
# argument after the path (or subcommand) that is quoted whole replaced by '', so the guard can look
# for git, gh and rtk in what is left; None for any other shape, which the guard refuses exactly as
# before. Anything a shell would do more than split words and remove quotes ends the reading with
# None: another operator or redirection, a substitution or variable (a $ or a backtick, quoted or
# not), a backslash, a glob or brace outside quotes, a comment, any other assignment or an option
# before the script, a newline outside quotes, a quote that never closes.
DATA_UNQUOTED_REFUSED = set(";&|<>()$`\\*?[]{}!#\n")

# The one thing that may stand in front of a declared call (claude-config#1610): the account rule's
# GH_TOKEN=$(gh auth token -u <login>), which reads another account's repository without switching
# the shared one. The login is plain, as GitHub allows it (letters, digits, single hyphens inside, at
# most 39), so nothing else can ride in the substitution; any other assignment, a second one, the
# value quoted or the login written any other way is no match, and the reading ends with None.
DATA_TOKEN_PREFIX = re.compile(
    r"GH_TOKEN=\$\(gh auth token -u (?=[A-Za-z0-9-]{1,39}\))[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*\)[ \t]+")

# What may stand behind a declared call (claude-config#1610): its output piped into one of these,
# named as written, each of which only reads what it is given and prints it, and `2>&1` before the
# first pipe. sed is not among them, since its w writes a file and GNU sed's e runs a command, nor is
# awk (system()), tee (writes) or anything that runs its arguments (xargs, a shell).
DATA_FILTERS = ("grep", "head", "tail", "cut")


def _data_pipes(s):
    """s split at each | outside quotes, or None for || or |& or a quote never closed, so each piece
    can be read by _data_words on its own."""
    pieces, start, k, quote = [], 0, 0, ""
    while k < len(s):
        ch = s[k]
        if quote == "'":
            if ch == "'":
                quote = ""
        elif quote == '"':
            if ch == "\\":
                k += 1
            elif ch == '"':
                quote = ""
        elif ch in "'\"":
            quote = ch
        elif ch == "|":
            if s[k + 1:k + 2] in ("|", "&"):
                return None
            pieces.append(s[start:k])
            start = k + 1
        k += 1
    if quote:
        return None
    pieces.append(s[start:])
    return pieces


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
    """s with every argument quoted whole after a declared script (and its subcommand, when the entry
    names one) replaced by '', when s is exactly `bash <script> [<subcommand>] <arguments>`, or the same
    with the script run by its path and no bash (claude-config#1623), for one of declared ("<path>"
    or "<path> <subcommand>", the path under ~/), else None. The script is matched
    on its whole path, written ~/ or from home, so a script of the same name elsewhere is no match.
    Only DATA_TOKEN_PREFIX may stand in front, and it is left out of what is returned: it names gh
    itself, and what it runs, one plain `gh auth token`, is read as its own command by every gate.
    Behind the call only `2>&1` and pipes into DATA_FILTERS may stand, each filter's arguments read
    the same way, its quoted ones set aside as data."""
    s = s.strip(" \t\n")
    token = DATA_TOKEN_PREFIX.match(s)
    if token:
        s = s[token.end():]
    pieces = _data_pipes(s)
    if not pieces:
        return None
    s, filtered = re.sub(r"[ \t]2>&1[ \t]*$", "", pieces[0]), []
    for piece in pieces[1:]:
        fw = _data_words(piece)
        if not fw or fw[0][0] not in DATA_FILTERS:
            return None
        filtered.append(" ".join(["|", fw[0][0]] + ["''" if whole else r for r, _, whole in fw[1:]]))
    words = _data_words(s)
    if not words or not home.startswith("/"):
        return None
    # `bash <script>`, or the script run by its path (claude-config#1623): each declared script is a
    # bash script with its own bash shebang, so the two run it alike.
    at = 1 if words[0][0] == "bash" else 0
    if len(words) < at + 1:
        return None
    raw_path, path, _ = words[at]
    if raw_path.startswith("~/"):
        path = home.rstrip("/") + raw_path[1:]
    for entry in declared:
        script, _, sub = entry.partition(" ")
        if not script.startswith("~/") or " " in sub or path != home.rstrip("/") + script[1:]:
            continue
        fixed = at + (2 if sub else 1)
        if sub and (len(words) < at + 2 or words[at + 1][1] != sub):
            continue
        kept = [w[0] for w in words[:fixed]] + ["''" if whole else r for r, _, whole in words[fixed:]]
        return " ".join(kept + filtered)
    return None


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    data = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace").read()
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
        # stdin is the command; each argument after the mode is one declared "<path>" or "<path>
        # <subcommand>" entry. Exit 1, printing nothing, for any other shape (claude-config#1574,
        # #1610).
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
    elif mode == "heredoc-markers":
        # Each heredoc the text opens, read a line at a time as heredoc_openers reads one, printed as
        # <line number>TAB<marker>, so a scan written in awk reads markers as this file does
        # (claude-config#2080).
        for n, line in enumerate(data.split("\n"), 1):
            for op in heredoc_openers(line):
                sys.stdout.write("%d\t%s\n" % (n, op[1]))
    elif mode == "split":
        if data.endswith("\n"):
            data = data[:-1]
        assigns, rest = split(data)
        sys.stdout.write("".join(a + "\n" for a in assigns) + "\x1f\n" + rest)
    else:
        sys.stderr.write("usage: shell-words.py read|commands|split|words|gitdir|bare|tool|heredoc-markers < text, or data-blanked '<path>[ <subcommand>]'... < text\n")
        return 64
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
