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
  shell-words.py flatten    stdin: a hook payload, the JSON Claude Code sends
      its command as lib/push-scope.sh's segmented mode hands it to a hook: each backslash and line
      break the shell removes taken out (claude-config#3470), each heredoc's body moved up to
      follow the command that opens it where a command stands after the opener on its line
      and a single quoted string and backquotes written as the shell that reads them reads them
      (claude-config#3739), then each line break left written as "; ", then 0x1f and the
      payload's cwd. Exit 4, printing nothing, when that is the command with its line breaks
      written as "; " and nothing else done, or the payload is not one this reads; see flattened().
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
  shell-words.py data-set-aside '<path>[ <subcommand>]'...   stdin: a whole command
      the command with each declared call in it replaced by `:`, exit 0, or nothing, exit 1, when
      none stands in it. A declared call is a pipeline of the command itself that is exactly `bash
      <path> [<subcommand>] <words>`, or `<path> [<subcommand>] <words>` with the script run by its
      path (claude-config#1623), for one of the declared entries (path under ~/), with nothing in
      front but GH_TOKEN=$(gh auth token -u <login>) and nothing behind but 2>&1 and pipes into
      grep, head, tail or cut, git, gh and rtk only inside arguments quoted whole (claude-config
      #1574, #1610), standing beside the command's other pipelines (#1492). The reader
      check-wrapped-commands.sh asks before refusing a script file; see data_set_aside().

The context stack: " ' ` quotes, $( and ${ substitutions, and plain ( inside a substitution.
Inside a substitution quotes open afresh, so X="$(a "b c")" is one word.
"""
import functools
import os
import re
import shlex
import io
import json
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
    return _joined(s)


@functools.lru_cache(maxsize=4096)
def _joined(s):
    """join_continuations for a text holding a backslash newline, worked out once for each text: the
    Slack drafts gate asked for 165,000 joins of 35,000 texts judging the claude-sync suite, most of
    them commands continued over several lines, read a character at a time (claude-config#2918)."""
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


# What shlex.split(text, posix=True) makes of a text holding no quote and no backslash: shlex then
# only ends a word at its whitespace, which is these four characters and no others.
SHLEX_PLAIN_WORD = re.compile(r"[^ \t\r\n]+")


def shell_split(text):
    """shlex.split(text, posix=True), raising as it does. Most commands hold no quote and no
    backslash, the only characters shlex reads as other than a word's own, and their words are the
    runs between its whitespace: found by one regular expression, where shlex reads one character
    at a time, and judging the claude-sync suite asked for 48,000 splits (claude-config#2918)."""
    if "'" in text or '"' in text or "\\" in text:
        return shlex_quoted_split(text)
    return SHLEX_PLAIN_WORD.findall(text)


# One piece of a word as shlex.split(posix=True) reads it: a run of plain characters, a single quoted
# string (all of it literal), a double quoted one (a backslash in it escapes only " and itself) or a
# backslash and the character after it; or the whitespace between words.
SHLEX_PIECE = re.compile(r"""([^ \t\r\n'"\\]+)|'([^']*)'|"((?:[^"\\]|\\[\s\S])*)"|\\([\s\S])|([ \t\r\n]+)""")
SHLEX_DQ_ESCAPE = re.compile(r'\\([\\"])')


def shlex_quoted_split(text):
    """shlex.split(text, posix=True), answering and raising as it does, for a text holding a quote or a
    backslash: read a piece at a time by SHLEX_PIECE, where shlex reads a character at a time through
    four method calls, the third of a judgement of the claude-sync suite in shell_split's 28,000 splits
    (claude-config#2918). A quote never closed or a backslash ending the text is left to shlex, so it
    raises what shlex raises."""
    words, word, quoted, at, n = [], [], False, 0, len(text)
    match = SHLEX_PIECE.match
    while at < n:
        m = match(text, at)
        if m is None:
            return shlex.split(text, posix=True)
        at = m.end()
        plain, single, double, escaped, space = m.groups()
        if space is not None:
            if word or quoted:
                words.append("".join(word))
            word, quoted = [], False
        elif plain is not None:
            word.append(plain)
        elif escaped is not None:
            word.append(escaped)
        elif single is not None:
            word.append(single)
            quoted = True
        else:
            word.append(SHLEX_DQ_ESCAPE.sub(r"\1", double) if "\\" in double else double)
            quoted = True
    if word or quoted:
        words.append("".join(word))
    return words


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
#
# A process substitution, <( ), >( ) or zsh's =( ), holds commands too (claude-config#3213): the
# shell runs them, in a shell of their own, wherever it expands the word they are written in. Until
# then it was read as a plain ( ), so `cat <(bash post.sh)` gave no command for the bash and nothing
# that reads commands through here judged it. Measured 2026-11-18 (bash 3.2.57, zsh 5.9): <( and >(
# run anywhere outside quotes in a command's words, mid word and after an escaped backslash too, in
# an array's words, and in bash in the word of an unquoted ${NAME:-word}; =( runs only at the start
# of a word; inside quotes each is text. One read where the shell runs none (an escaped <, a test's
# comparison) only gives a command more than are there, the direction a gate needs.
RESERVED = {"!", "{", "if", "then", "else", "elif", "do", "while", "until", "time"}
COMMAND_FRAMES = {"top", "sub", "subst", "tick", "proc"}
# What may stand before the = of zsh's =( ), which is one only at the start of a word.
PROC_WORD_START = " \t\n;&|("
# For each frame commands() reads as quoted text: (whether a character changes the reading there, a
# search for the next one that does). Single quotes end only at a quote. Double quotes end at a quote
# and hold a backslash, a $ (a substitution, an arithmetic or a parameter) and a backquote. An
# unquoted heredoc body holds the same but its quotes are only text (claude-config#2053, #2918).
QUOTED_STOPS = {
    "'": ("'".__eq__, re.compile(r"'").search),
    '"': (frozenset('"\\$`').__contains__, re.compile(r'["\\$`]').search),
    "hd": (frozenset("\\$`").__contains__, re.compile(r"[\\$`]").search),
}


def _stops(chars):
    """(whether a character is one of chars, a search for the next one), as a QUOTED_STOPS entry."""
    return frozenset(chars).__contains__, re.compile("[" + re.escape(chars) + "]").search


# Every other frame reads most of its characters the same way, as one more character of its text, and
# changes the reading only at these (commands()'s loop, branch by branch): in a frame holding commands,
# a backslash, a quote ($' and $" too, at the $), a $ form, a backquote, a # that may start a comment,
# a << or <<<, a separator (; & | and the line break, whose first character is the ; of the flattened
# form's "; ") and a parenthesis; in ${ } its } and a ( that may open a process substitution
# (claude-config#3213) as well as those it shares with quoted text; in $(( ))
# and a plain ( ) the parentheses, and a # in an array's. $'...' ends at its quote and holds backslash
# escapes. The reader goes straight to the next of them, as it does in quoted text: stepping one
# character at a time through commands was most of the reader's time judging the claude-sync suite,
# 2.8 million characters with claude-sync (claude-config#2918).
_HOLDS_TEXT = "\\'\"$`"
FRAME_STOPS = dict(QUOTED_STOPS, ansi=_stops("'\\"), param=_stops("}(" + _HOLDS_TEXT),
                   arith=_stops("()" + _HOLDS_TEXT), paren=_stops("#()" + _HOLDS_TEXT),
                   **{k: _stops("#<|&;()\n" + _HOLDS_TEXT) for k in COMMAND_FRAMES})
# A heredoc's opener up to its end marker word: <<, or <<- which strips leading tabs, and blanks.
HEREDOC_START = re.compile(r"<<(-?)[ \t]*")
# What ends the end marker word, as the shell reads a word.
HEREDOC_WORD_END = set(" \t\n;&|<>()")
# How an end marker word starts for a reader that follows no arithmetic: a letter or underscore,
# either one after a backslash, or a quote, $' and $" included. The limit mod-kit's hooks/commands.ts
# keeps for the same reason (claude-config#2073), so `$((1<<2))` opens no heredoc there or here.
MARKER_START = re.compile(r"""\\?[A-Za-z_]|\$?['"]""")
# What a backslash and the character after it stand for in a dollar quote ($'...') that is an end
# marker, where bash 3.2 and zsh 5.9, the shells a Bash call runs in, read it alike
# (claude-config#3566): the escapes named here, and a character from 2 to 126 written as one or two
# hex digits after an x or as one to three octal digits. Measured 2026-11-24 with texts that only
# print, each as a -c text, a file and an eval: every escape named here, and all 250 markers that
# spell a character from 2 to 126 as two hex digits or three octal ones. ksh 93u+ read the named
# escapes and the octal ones the same way but for the line break (it ends the body at the two lines
# the marker spells, the others at no line), and reads a third hex digit where the other two stop
# at two. Any other backslash stays as written, because the two do not agree on it: a letter that
# is no escape (bash keeps the backslash, zsh drops it), a u or a c, a $, an x with no digit, and
# the characters 0, 1 and 127 and those past it. lib/heredoc-markers.json holds one marker of each
# kind with the line every shell ends the body at.
ANSI_ESCAPES = {"\\": "\\", "'": "'", '"': '"', "?": "?", "a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b",
                "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v"}
ANSI_ESCAPE = re.compile(r"\\(?:x([0-9A-Fa-f]{1,2})|([0-7]{1,3})|(.))", re.S)
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
# A case command's head up to its `in`, past any reserved words before it, and an esac ending one
# (claude-config#2074): a pattern after the `in`, or after a `;;` or `;&`, ends at a `)` that closes
# no subshell, and its `|` joins two patterns rather than piping.
_PREFIX = r"\s*(?:(?:" + "|".join(re.escape(w) for w in sorted(RESERVED)) + r")\s+)*"
CASE_HEAD = re.compile(_PREFIX + r"case\s+\S.*?\s+in(?=[\s(]|$)", re.S)
CASE_END = re.compile(_PREFIX + r"esac(?=[\s;&|()<>]|$)")
# A function's header, `name()` or `function name`, before the { of its body: a ( after that brace
# opens a subshell, the body of `f(){ (` ... `) }` (claude-config#2538).
FUNC_HEADER = re.compile(r"\s*(?:function\s+[^\s(){}]+(?:\s*\(\s*\))?|[A-Za-z_][\w:.-]*\s*\(\s*\))(?=\s*\{)")
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


def _ansi_escape(m):
    """What one backslash escape in a dollar quote stands for (ANSI_ESCAPES), or the escape as written."""
    if m.group(3) is not None:
        return ANSI_ESCAPES.get(m.group(3), m.group())
    value = int(m.group(1), 16) if m.group(1) else int(m.group(2), 8)
    return chr(value) if 2 <= value <= 126 else m.group()


def heredoc_opener(s, i, marker_start=False, joins=None, doubts=None, one_line=False):
    """The heredoc opened at s[i] ("<<"), as (marker, strip_tabs, quoted, end), or None.

    The marker is the word after the opener with its quotes removed, as the shell compares it with
    each body line; quoted says whether ANY part of it was quoted, by quotes or a backslash, whole
    (`'EOF'`, `"EOF"`, `\\EOF`) or in part (`E"OF"`, `E\\OF`, `$'EOF'`), because then the shell
    expands nothing in the body, and otherwise it expands it and runs every substitution in it
    (claude-config#2053). Measured on this Mac's bash and zsh, 2026-11-01. None when there is no word,
    or a quote in it never closes.

    A dollar quote in the word (`$'...'`) ends at the first quote no backslash escapes, and its
    escapes are read where bash and zsh read them alike (ANSI_ESCAPES, claude-config#3566): after
    `<<$'E\\\\F'`, two backslashes, the marker is E, one backslash and F, the line both end the
    body at, and after `<<$'p\\'6'` it is p'6. The text between the quotes was taken as written
    and the next quote for its end, so the first ended the body at the line with two backslashes,
    every command between those two lines read as body text while both shells ran it, and the
    second was no heredoc at all. That is one reading, for every caller, and it is not every
    shell's. dash knows no dollar quote: the $ is a character of its marker and the quote a plain
    one, so no marker that holds a dollar quote ends the body at the same line in all of bash 3.2,
    bash --posix, sh, dash, zsh, zsh emulating sh and ksh (measured 2026-11-24, each as a -c text,
    a file and an eval; lib/heredoc-markers.json holds the lines, and test-shell-words-heredoc.sh
    runs them against the shells of the machine it is on). bash and zsh differ too on an escape
    that is not in ANSI_ESCAPES, on a dollar double quote (`$"EOF"` is EOF to bash, the reading
    given here as it always was, and $EOF to zsh and dash) and on `$$'EOF'`. So doubts, a list, is
    given where the $ of each dollar quote in the word stands, single or double, and a caller that
    must not take one shell's reading for another's refuses on it: commands() names such a
    heredoc in `unsure` for the caller that asks.

    With marker_start, also None when the word does not start as a marker is written (MARKER_START),
    for a reader that follows neither arithmetic nor, in some, quotes (claude-config#2080).

    joins, a list, is given where each backslash that ends a line stands between the << and the
    end of the word, and the opener is then read as every shell reads it (claude-config#3492,
    review of #3495): such a backslash and its line break join the two lines, before the word, in
    it or inside its double quotes, so they are no part of the marker and quote nothing. After
    `<<E`, a backslash, a line break and `x` the marker is Ex, unquoted, where the reading
    without joins takes the backslash for one quoting the line break and the marker for a quoted
    one that holds it. Measured 2026-11-23 in bash 3.2, bash --posix, sh, dash, zsh and ksh, which
    agree but for a `-` on the line after `<<` and a backslash: bash, sh and dash read <<-
    there, zsh and ksh a marker that starts with the dash, as this does. Without joins the
    reading is the one it always was, for every caller that did not ask.

    With joins and one_line, s is one line of a longer file, and a backslash that is its LAST
    character, between the << and the end of the word, is a join too, to a line the caller was
    not handed (claude-config#3504): a reader given one line of a file at a time is given
    `cat <<E` and a backslash, and every shell joins that line to the next, so the marker is not
    the word this line shows. It is given to joins like any other, also where None is returned
    because no word was read before it (`cat <<` and a backslash). Read as a character of the
    marker, E and a backslash, unquoted, it made a marker no line of a body can be, so a reader
    waiting for that line took the rest of the file for the body. line_opener is this reading
    for such a caller. With joins, marker_start is asked of the word itself, past the joins
    before it.

    Without one_line the last character of s is the end of the text, and a backslash there joins
    nothing, with joins or without: it is a character of the marker, as it always was, and bash
    and zsh run the commands in front of it. commands() reads a whole text, so it does not say
    one_line. When it did take that backslash for a join, a text that ended in `<<E` and a
    backslash was a heredoc named in `unsure`, flattened() gave its plain form for it, and the
    push in front of the heredoc was no push to the push hooks (review of pull request 3797,
    where both shells were run). Double quotes that never close in s are None either way, as
    they always were, whatever s ends in.
    """
    m = HEREDOC_START.match(s, i)
    if not m or s.startswith("<<<", i):
        return None
    if marker_start and joins is None and not MARKER_START.match(s, m.end()):
        return None
    j, n = m.end(), len(s)
    found, dollars = [], []
    if joins is not None:
        # The joins and blanks between the << and its word.
        while j < n:
            if s.startswith("\\\n", j):
                found.append(j)
                j += 2
            elif s[j] in " \t":
                j += 1
            elif s[j] == "\\" and j == n - 1 and one_line:
                found.append(j)
                j += 1
            else:
                break
        if j == n and found and found[-1] == n - 1:
            joins.extend(found)
            return None
        if marker_start and not MARKER_START.match(s, j):
            return None
    start = j
    word, quoted = [], False
    while j < n and s[j] not in HEREDOC_WORD_END:
        c = s[j]
        if c == "\\" and joins is not None and s.startswith("\n", j + 1):
            found.append(j)
            j += 2
        elif c == "\\" and joins is not None and one_line and j == n - 1:
            found.append(j)
            j += 1
        elif c == "\\" and j + 1 < n:
            word.append(s[j + 1])
            quoted = True
            j += 2
        elif c == "$" and s.startswith("$'", j):
            dollars.append(j)
            j += 2
            k = j
            while k < n and s[k] != "'":
                k += 2 if s[k] == "\\" else 1
            if k >= n:
                return None
            word.append(ANSI_ESCAPE.sub(_ansi_escape, s[j:k]))
            quoted = True
            j = k + 1
        elif c == "'":
            j += 1
            k = s.find("'", j)
            if k < 0:
                return None
            word.append(s[j:k])
            quoted = True
            j = k + 1
        elif c == '"' or (c == "$" and s.startswith('$"', j)):
            if c == "$":
                dollars.append(j)
            j += 2 if c == "$" else 1
            k = j
            while k < n and s[k] != '"':
                k += 2 if s[k] == "\\" else 1
            if k >= n:
                return None
            if joins is None:
                word.append(re.sub(r'\\([\\"$`])', r"\1", s[j:k]))
            else:
                # Read a pair at a time, so a backslash that another one quotes joins nothing.
                for q in re.finditer(r'\\([\\"$`\n])|[^\\]+|\\', s[j:k]):
                    if q.group(1) == "\n":
                        found.append(j + q.start())
                    else:
                        word.append(q.group(1) or q.group())
            quoted = True
            j = k + 1
        else:
            word.append(c)
            j += 1
    if j == start:
        return None
    if joins is not None:
        joins.extend(found)
    if doubts is not None:
        doubts.extend(dollars)
    return "".join(word), m.group(1) == "-", quoted, j


def line_opener(line, i, marker_start=False, cut=None):
    """heredoc_opener(line, i) for a reader handed a file one line at a time, or None where the
    opener's line ends in a backslash before the end of its marker word (claude-config#3504).

    Every shell joins such a line to the next (bash 3.2, sh, dash, zsh and ksh, measured
    2026-11-23 and again 2026-11-26), so the marker is the joined word, most of which is on a line
    this caller was not handed: after `cat <<E`, a backslash, and a next line `x`, the body ends
    at the line Ex. Read from the one line the marker was E and a backslash, which no line is, so
    a reader waiting for it took everything after for the body and read no code there. No
    heredoc is given for it, so the lines after are read as code, as lib/shell_code_lines.py
    reads them (its unsure_heredocs names the heredoc): a scan that looks at a line no shell runs
    costs a second look, and one that skips a line a shell runs has missed what it was written
    to find. cut, a list, is given (i, len(line)) for it. A << with nothing but a backslash
    after it on its line is cut as well, whether the next line holds a marker or the rest of an
    arithmetic shift, since the line cannot say which.

    Handed a text that holds the next line, the opener is read as the shells read it, the two
    lines joined (heredoc_opener's joins), and nothing is cut unless the text itself ends at such
    a backslash.
    """
    joins = []
    op = heredoc_opener(line, i, marker_start=marker_start, joins=joins, one_line=True)
    if joins and joins[-1] == len(line) - 1:
        if cut is not None:
            cut.append((i, len(line)))
        return None
    return op


def heredoc_openers(line, marker_start=True, cut=None):
    """Each heredoc a line opens, read on its own without following its quotes, as (start, marker,
    strip_tabs, quoted, end), start at its << and the rest as heredoc_opener gives them.

    An opener whose line ends in a backslash before the end of its marker word is not given: its
    marker is not the word the line shows (line_opener, claude-config#3504). cut, a list, is
    given its (start, end of the line), for a caller that says so. Its word runs to the end of
    the line, so nothing follows it there. A << before double quotes that never close on the line
    is no opener and no cut, as it never was, whatever the line ends in, and the scan goes on
    past it: the scan follows no quotes, so that << is as often inside a string, and the opener
    after it is real (review of pull request 3797).

    For the whole tree scans that read a file a line at a time and need only where a heredoc's body
    begins and what ends it (claude-config#2080). Such a scan cannot tell a << in a string or in
    arithmetic from one opening a heredoc, so a word is taken only where it starts as a marker is
    written (marker_start): `$((1<<2))` and `grep -c '1<<2'` open nothing, and neither does the
    << of a here string. The cost is a heredoc whose marker starts with a digit, which bash accepts
    and no file here uses.

    With marker_start False every << with a word after it is taken, a here string still apart, for
    a reader that must not miss a heredoc and can afford to count one that is not there: a gate
    refusing a text it cannot follow (claude-config#2641). The text can then be a whole script,
    and is read as one: an opener is given as the shells read it, a backslash and line break in
    it joined (heredoc_opener's joins), the last character of the text is its end, where a
    backslash joins nothing, and nothing is cut. Beside those, every opener the reading without
    joins takes at a << the joined reading did not, which is what this gave before it joined
    anything: after `<<`, a backslash and a line break, the quoted words `'a <<E b'` are one
    marker read joined, and read unjoined the << inside them opens an unquoted heredoc. So a
    caller asking whether any heredoc of the text is unquoted is never told less than it was
    (review of pull request 3797).
    """
    def scan(read):
        out, i = [], 0
        while True:
            i = line.find("<<", i)
            if i < 0:
                return out
            if line.startswith("<<<", i):
                i += 3
                continue
            cuts = []
            op = read(i, cuts)
            if cuts:
                if cut is not None:
                    cut.extend(cuts)
                return out
            if op is None:
                i += 2
                continue
            out.append((i,) + op)
            i = op[3]

    if marker_start:
        return scan(lambda i, cuts: line_opener(line, i, marker_start=True, cut=cuts))
    joined = scan(lambda i, cuts: heredoc_opener(line, i, joins=[]))
    taken = {op[0] for op in joined}
    return sorted(joined + [op for op in scan(lambda i, cuts: heredoc_opener(line, i)) if op[0] not in taken])


# The second characters that make one operator with a first when a backslash and a line break
# stand between the two (split_operator, claude-config#3504): $( ${ and $', the )) that closes
# arithmetic, and what commands() reads as an operator between commands, which are the
# separators (&& || ;; ;& |&), the redirections (<< <& <> >> >& >| &>), a process substitution's
# <( >( and =(, and the (( of an arithmetic command or a $(( )).
SPLIT_SECOND_CHARS = {"$": "({'", ")": ")", "&": "&>", "|": "|&", ";": ";&", "<": "<(&>", ">": ">(&|",
                      "=": "(", "(": "("}


def _split(s, at):
    """(the two characters, where the second is) of the operator split at s[at], or None."""
    k = at + 1
    while s.startswith("\\", k):
        k += 1
    if k == at + 1 or not s.startswith("\n", k):
        return None
    k += 1
    while s.startswith("\\\n", k):
        k += 2
    first, second = s[at:at + 1], s[k:k + 1]
    if not first or not second or second not in SPLIT_SECOND_CHARS.get(first, ""):
        return None
    return first + second, k


def split_operator(s, at):
    """The operator that a backslash and a line break split at s[at], as its two characters, or
    "" where s[at] starts none (claude-config#3504).

    The shell takes a backslash and the line break after it out of a text before it reads words,
    so `$`, the pair and `(` is the `$(` of a command substitution: bash 3.2, sh and dash run its
    command wherever it stands, and zsh and ksh in some places and not in others (zsh outside
    double quotes, both in backquotes). A `<`, the pair and `<E` opens a heredoc in bash, sh and dash, where
    zsh and ksh give a syntax error; a `;`, the pair and `;` ends a case branch in those three.
    Measured 2026-11-26 with texts that only touch a file in a throwaway folder;
    test-shell-words-split-operators.sh runs each against the shells of the machine it is on. The
    shells do not agree, so no one reading of such a text is every shell's, and commands() names
    the operator in `unsure` for a caller that asks, where it stands live: this says only that
    the TEXT at s[at] has the shape, which is what tells such a name from a comment's or a
    heredoc's. More than one pair may stand between the two characters, and so may a line break
    after several backslashes, the form the pair takes inside backquotes, which read a
    backslash first themselves.
    """
    found = _split(s, at)
    return found[0] if found else ""


def cd_target(text):
    """The directory a simple command moves to when it is a cd, as the shell reads the word, or None.

    A bare cd goes home. Only a leading tilde is expanded later; a variable stays as written, so
    the caller refuses it rather than guessing what it holds. `cd>/dev/null <dir>` is a cd too
    (spaced, claude-config#3252).
    """
    text = spaced(join_continuations(text))
    try:
        words = shell_split(text)
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


# ---- where a comment starts: the one rule every reader here asks (claude-config#3464) ----
#
# The shell starts a comment at a # only where a WORD starts. commands() took any # after white
# space, a separator or a parenthesis for one, so it left out the rest of the line where the shell
# read the # inside a word and ran what followed: after a space, a ; or a parenthesis that a
# backslash escapes (`echo a\ #b; cmd`), right after the ) closing a $( ), a <( ) or a $(( )), which
# is still inside its word, and at the start of a line a backslash joined to a word. Measured
# 2026-11-22 against bash 3.2.57 and zsh 5.9 (test-shell-words-comment-start.sh runs the table
# against the shells of the machine it is on): 18 of 120 shapes ran a command the reader left out.
#
# The other mistake hides a command as well: a real comment read as text can open a quote at an
# apostrophe in it, and the string then holds the commands of the lines after. So a reader that
# cannot tell says so and never guesses either way: None from word_starts, and from commands() the
# line named in `unsure`, for a caller that asks. commands() does not change what it reads for a
# caller that does not ask: other gates read through it, and each must decide for itself what such
# a line means. A caller that asks for `unsure` is given the shell's own reading wherever
# word_starts answers False outside backquotes, the # as text and the rest of its line as the
# commands they are (claude-config#3481): there bash, bash --posix, sh, dash, zsh, zsh emulating sh
# and ksh all keep the # in its word, run as a -c text, a file and an eval, measured 2026-11-23
# with the lines the same shells do take for comments beside them. One rule, asked by every reader
# of comments here and by lib/script-params.py.
WORD_BREAKS = " \t\n;&|()"


def word_starts(s, i, breaks=WORD_BREAKS, closed=None, layered=False, ended=None):
    """Whether a word starts at s[i], so that a # there starts a comment: True, False where s[i] is
    inside a word, and None where that cannot be told. i is where a reader that follows the quoting
    is outside every quote, and s[i] is not itself escaped.

    A word starts at the start of s and after one of breaks that no backslash escapes. A backslash
    newline is gone before the shell reads words, so what stands before it decides. closed is
    (the index just past the last `)` the reader went by, what a word starting there would mean:
    True after one that ends a command (a subshell's, a case pattern's), False after one still
    inside its word (a substitution's), None where the shells differ or the reader does not know
    what it closed); with no closed, a `)` before s[i] cannot be told. layered says the text is
    inside backquotes, whose own reading of backslashes comes before the shell's, so a backslash
    before the break cannot be counted here.

    Everything this looks back at is either next to s[i] on its line, and so read in the state the
    caller vouches for at i, or on an earlier line it reaches over a backslash newline, and that
    backslash joins the lines only where it is live. One that ends a COMMENT, or the closing line
    of a heredoc, joins nothing, and the # that starts the next line starts a comment in every
    shell: walking back over it took that # for text, and an apostrophe in it then opened a string
    over the commands of the lines after (claude-config#3481; bash, bash --posix, sh, dash, zsh, zsh
    emulating sh and ksh, measured 2026-11-23). ended is what the reader knows of that:
    {the index of a line break: True where the line it ends is a comment the shell reads too or a
    heredoc's closing line, so a word starts after it whatever stands before it; None where the
    reader took a comment there and cannot tell whether the shell did}. A line break it does not
    hold ends a line of live text. With no ended the caller has no reading of the earlier lines, so
    an answer that rests on a joined line being live, "inside a word", is None: only True, which
    holds whether that backslash joined anything or not, is given past one."""
    walked = False
    while True:
        if i <= 0:
            return True
        p = s[i - 1]
        inside = None if walked and ended is None else False
        if p not in breaks:
            return inside
        k = i - 2
        while k >= 0 and s[k] == "\\":
            k -= 1
        slashes = i - 2 - k
        if slashes and layered:
            return None
        if slashes % 2:
            if p != "\n":
                return inside
            if ended is not None and i - 1 in ended:
                return ended[i - 1]
            i -= 2
            walked = True
            continue
        if p == ")":
            return closed[1] if closed and closed[0] == i else None
        return True


def uncommented(s, spaced=False):
    """s with every comment commands() reads blanked to spaces, each offset kept, for a caller that
    searches a text's code for a word (claude-config#3464): a # in a quoted string, an escaped one
    and one inside a word stay, with whatever follows them on the line. Raises Unreadable where
    commands() does.

    spaced=True blanks only a comment that starts s or follows white space, for a caller that used
    to take every such # for a comment and no other: what it kept then (a comment right after a ;
    or a parenthesis) it keeps now, so it only ever reads more than it did."""
    found = []
    commands(s, comments=found)
    out, at = [], 0
    for start, end in sorted(found):
        if spaced and start and not s[start - 1].isspace():
            continue
        if start >= at:
            out += [s[at:start], " " * (end - start)]
            at = end
    out.append(s[at:])
    return "".join(out)


def heredoc_close(s, j, word, strip_tabs, quoted, line_break="\n"):
    """Where the heredoc whose body starts at the line break at j closes, as (plain, shells, sure,
    bash, doubt, stray): the one reading of it, for the command reader (commands) and for the reader the
    tree scans read shell files through (lib/shell_code_lines.py), which kept a close rule of its
    own until claude-config#3592. plain, shells and bash are each the match of a closing line, from
    the line break before it to its end, or None for a heredoc that never closes (claude-config#3492).

    plain is the reading commands always gave: the first line that is the marker (after its tabs,
    for <<-), whatever stands before it. That is how every shell reads a QUOTED marker's body,
    which is text as written. An UNQUOTED marker's body the shell reads a line at a time with a
    line that ends in an odd count of backslashes joined to the next, so a marker on that next
    line is the tail of a longer line and closes nothing. Measured 2026-11-23 in bash 3.2, bash
    --posix, sh, dash, zsh, zsh emulating sh and ksh, as a -c text, a file and an eval
    (test-shell-words-heredoc.sh runs the table against the shells of the machine it is on):
    after one or three backslashes all seven keep the heredoc open, after two or four all seven
    close it, and with the marker on a line of its own later all seven close it there. Closed at
    the joined marker, the rest was read as commands, where a $( ) in single quotes is a word
    that runs nothing, while every shell ran it as part of the body.

    shells is where the shells close it, for a caller that asks which lines the reading is
    unsure of, and sure is whether plain is a reading to vouch for. It is not, and the caller
    that asks is told so and never left with a reading that lost a command silently, where:
      * the shells close it at a later line than plain (a joined marker, then the marker on a
        line of its own): shells is that line. All seven agree, but the lines between were
        commands to commands until then, so the heredoc is named all the same;
      * the shells differ, and shells is plain: a joined line that IS the marker once joined,
        with tabs let go wherever a <<- strips them in any shell (a line that is only a
        backslash and then the marker, a marker split over two lines, a marker line ending in a
        backslash before an empty line), which bash and zsh compare whole and close at where
        dash and ksh do not, each in its own cases; and a marker right after a line that starts
        as the marker does and ends in backslashes, where ksh keeps the first of those
        backslashes as text and so joins where the others do not and the reverse. Which shell
        does what, shape by shape, is lib/heredoc-closes.json, which test-shell-code-lines.sh
        runs against the shells of the machine it is on;
      * it never closes in the shells and plain closes it, at a joined marker: shells is
        None, whatever follows. Every shell reads the rest as the body and feeds it to the
        heredoc's command, where plain gave that rest as commands of its own and the body as
        the lines before the marker: python3 fed `# note`, a backslash, the marker and then
        an import was given the import, and ran it, in bash 3.2, bash --posix, sh, dash, zsh
        and ksh (measured 2026-11-23, review of #3495);
      * it never closes in the shells or in plain, and a $ or a backquote stands in the rest
        of the text: shells is None. Every shell reads that rest as the body and runs the
        substitutions in it, where commands takes the rest for commands, so that nothing
        after an unclosed heredoc is hidden. With neither character in the rest no shell
        runs anything from it, the commands plain reads there are only more than the shell
        runs, and a caller that reads what the command is fed takes the whole rest for it;
      * the marker holds a line break (a quoted one, `<<'E` and a backslash, then `x'` on
        the next line) and plain closes it at the lines that spell it: shells is plain. No
        line is that marker, so bash, sh and zsh never close the heredoc, while dash and ksh
        close it where plain does (measured the same day).
    A caller of commands that does not ask is given plain, the reading it always was (as for a #
    since claude-config#3481): other gates read through this, and one that must not miss a command
    asks. With a line_break of "; ", for a text with no line break at all, the "; " is read as
    one, for the flattened form the push hooks make, and that reading is kept. But as typed no
    shell gives a heredoc on one line a body: it runs every command after the << on the line
    (bash 3.2 and zsh, measured 2026-11-23: `cat <<E; echo RAN; E` printed RAN and then ran E),
    which that reading took for the body. So a heredoc it closes there, quoted or not, is not
    sure; one it never closes is read on as commands, as the shells run them.

    bash is where bash and zsh close it, each line of an unquoted body joined to the next by an
    odd count of backslashes before anything is compared with the marker, and under <<- the tabs
    taken off the front of the joined line (bash closes at a tab and a backslash followed by a tab
    and the marker where zsh does not, and this is bash's reading there). It is the line a reader
    of a whole file ends the heredoc at, since the lines after are then read as code, and it is
    looked for past the first closing line the shells do not read alike. doubt is where the first
    such closing line ends in s, or None where there is none before bash: the two cases under
    "the shells differ" above, and the end of the lines that spell a marker holding a line break,
    which bash never closes at (bash is None there) and dash or ksh do. stray, the sixth item, is
    whether no shell closes the heredoc and plain does, at a marker joined to the line before: the
    one heredoc a reader of a whole file ends at plain, taking both safe sides."""
    n = len(s)
    line_end = r"(?=\n|$)" if line_break == "\n" else r"(?=;|$)"
    tabs = "\t*" if strip_tabs else ""
    first = re.compile(re.escape(line_break) + tabs + re.escape(word) + line_end).search(s, j)
    if line_break != "\n":
        return first, first, first is None, first, None, False
    if line_break in word:
        return first, first, first is None, None, first.end() if first else None, False
    if quoted:
        return first, first, True, first, None, False

    def never():
        if first is None and s.find("$", j) < 0 and s.find("`", j) < 0:
            return first, first, True
        return first, None, False

    if s.find("\\" + line_break, j, first.end() if first else n) < 0:
        # No line of the body is joined to the next, which is nearly every heredoc there is.
        return ((first, first, True) if first else never()) + (first, None, False)
    # Every place a shell might close it: the marker, with any count of backslash line breaks
    # (and the tabs a <<- strips) before it, between its characters and after it.
    lb = re.escape(line_break)
    joins = r"(?:\\" + lb + tabs + ")*"
    chain = re.compile(lb + tabs + joins + "".join(re.escape(c) + joins for c in word) + line_end)
    width, pos = len(line_break), j
    # read is (plain, shells, sure), settled at the first closing line that settles it; the walk
    # goes on from there only to find where bash closes the heredoc.
    read = doubt = None
    while True:
        m = chain.search(s, pos)
        if not m:
            return (read or never()) + (None, doubt, first is not None)
        k = m.start() - 1
        while k >= j + width and s[k] == "\\":
            k -= 1
        slashes = m.start() - 1 - k
        joined = m.start() > j and slashes % 2 == 1
        if "\\" in s[m.start():m.end()]:
            if not joined:
                read = read or (first, first, False)  # the joined line is the marker: some shells close here
                doubt = m.end() if doubt is None else doubt
                whole = s[m.start() + width:m.end()].replace("\\" + line_break, "")
                if (whole.lstrip("\t") if strip_tabs else whole) == word:
                    return read + (m, doubt, False)
        else:
            if slashes:
                before = s[s.rfind(line_break, j, m.start()) + width:m.start()]
                core = (before.lstrip("\t") if strip_tabs else before).rstrip("\\")
                if core and word.startswith(core):
                    read = read or (first, first, False)  # ksh reads that line's first backslash as text
                    doubt = m.end() if doubt is None else doubt
            if not joined:
                if read is None:
                    same = first is not None and first.start() == m.start()
                    read = (first, first, True) if same else (first, m, False)
                return read + (m, doubt, False)
        pos = m.end()


def commands(s, cwd="", heredocs=None, parts=None, spans=None, comments=None, unsure=None, joined=None,
             lines=None, typed=False, reread=None):
    """Every simple command in s, in the order the shell finishes reading them, as (dir, text).

    reread, when a list, is given the text another shell may read differently from this one
    (claude-config#3739), for inner_typed(): ("'", start, end) for the text between each pair of
    single quotes, which a wrapper hands a shell as it is written, and ("`", i, width) for each
    run of backslashes and the line break after it inside backquotes that joins the next line
    for the shell reading the backquotes, s[i:i + width] being what to take out so that this
    reading makes the same words of what is left.

    typed says s is the command as typed even where it holds no line break, so a "; " in it is
    never read as one (claude-config#3739): a command of one line is otherwise taken for the
    flattened form, where the ; after a heredoc's opener starts the body.

    lines, when a list, is given what the reading as typed meets on a line that opens a heredoc,
    in the order it meets them (claude-config#3739), for opener_lines(): ("after", i, n) for each
    "; " at s[i] that separates two commands while n heredocs opened before it wait for their
    bodies, which is what the flattened form cannot tell from the line break that starts them;
    then, where that line ends, ("bodies", i, [(start, end), ...]) with one span for each waiting
    heredoc, in the order they were opened, from the line break before its body to the end of its
    closing line, or ("open", i, [at, ...]) where one of them never closes, with the << of each
    heredoc waiting there; and ("end", len(s), [at, ...]) with the << of each heredoc still
    waiting when the text ends, which no shell gives a body, for a text read to its end. Nothing
    is given for a text read as the flattened form.

    joined, when a list, is given the index of each backslash this reading goes past with a line
    break right after it where the shell takes the two for a join and removes them before it reads
    words (claude-config#3470): outside single quotes and $'...', outside comments, outside the
    text of a heredoc's body, its marker word and its closing line, and outside backquotes. One
    the reading cannot vouch for is left out, so it is a list of joins that are safe to make in
    the text and never the list of every join the shell makes.

    heredocs, when a list, is given one (quoted, before, body) for each heredoc body the reading
    skipped as text (claude-config#2050): quoted says the shell expands nothing in it (its end marker
    is quoted in any form, heredoc_opener), before is the text of the command that opened it up to
    the opener, and body is the text between the opener's line and its closing line. An unquoted
    body is given too, though the substitutions in it are also read as commands (#2053). A body
    that never closes is not skipped, so it is read as commands and given to nobody here.

    spans, when a list, is given one (opener, start, end) for each body heredocs is given, in the
    same order: opener is where its << is in s, the same start parts gives the opener, and s[start:end]
    is the body, from the line break that ends the opener's line to the start of its closing line
    (claude-config#2722), so a caller can tell which command a body is given to.

    comments and unsure, when lists, are given between them one (start, end) for each # the reading
    took for a comment, s[start] the # and end the line break the reading went on from
    (claude-config#3464): comments where the shell starts a comment there too (word_starts), unsure
    where which the shell does cannot be told. Where every shell reads the # inside a word and so
    RUNS the rest of that line, a caller that asks for unsure is given that line read as the shell
    reads it, the # as text (claude-config#3481), and should that reading not reach its end the #
    is named in unsure as it raises Unreadable. A caller that does not ask for unsure is given the
    commands it was always given, with every such line left out, and one that must not miss a
    command asks, and does not trust a reading that names any line.

    unsure is also given one (start, end) for each heredoc whose end the reading cannot vouch for
    (claude-config#3492, heredoc_close): s[start] the first < of its <<, end the line break that ends
    the line it opens on. The shell reads an unquoted heredoc's body with a line ending in a
    backslash joined to the next, so a marker on that next line closes nothing, where this reading
    closed it at the first line that is the marker. Named are the unquoted ones the shells close
    anywhere else, or in different places from one shell to another, or never where this reading
    closes them (every shell feeds the rest to the heredoc's command, where this reading gave it
    as commands), or never while a $ or a backquote stands in the rest of the text: every shell
    runs the substitutions in that rest as part of the body, where this reading takes the rest for
    commands and so reads a $( ) in single quotes there as a word that runs nothing. Named too,
    quoted or not, is one this reading closes in a text with no line break at all, the "; " read as
    one: as typed no shell gives it a body and every shell runs what this reading took for its
    body; one whose marker holds a line break, where this reading closes it; and one whose opener
    a backslash joins to the next line, which is named by its << to the end of its marker word
    (heredoc_opener). A caller that asks is given the shells' closing line where they agree on
    one; a caller that does not is given the reading it always was.

    Named the same way, by its << to the end of its marker word, is a heredoc whose marker holds a
    dollar quote, `$'...'` or `$"..."` (claude-config#3566, heredoc_opener's doubts): dash reads the
    $ as a character of the marker, and bash and zsh differ on some of what the quotes hold, so no
    such heredoc ends at one line in every shell. Its marker is read as bash and zsh read it where
    those two agree, for a caller that asks and one that does not alike.

    unsure is given as well one (start, end) for each operator that a backslash and a line break
    split (claude-config#3504, split_operator): s[start] its first character and s[end - 1] its
    second, with the pair, or several, between them. Named where the first character is live, no
    backslash before it, and the two make an operator where they stand: `$(` and `${` anywhere
    outside single quotes, `$'` where a quote can open, the `))` that closes arithmetic, and
    between commands the separators, the redirections, `<(`, `>(`, `=(` and `((`. bash, sh and
    dash join the two and read the operator, zsh and ksh only in places, so the substitution
    runs, or the heredoc opens, in some shells and not in others, and this reading, which goes
    past the pair and reads the two characters apart, is no shell's for certain. The reading is
    not changed, for a caller that asks or one that does not: a caller that must not miss a
    command asks, and refuses a text that names one. Inside backquotes the name is given too
    where several backslashes end the line, since the backquotes read a backslash first. For the
    same reason a dollar sign after one backslash is live there in bash and zsh, split or whole
    (measured in the review of pull request 3797), and is read here as an escaped one and not
    named: a fault older than this naming, which does not mend it.

    The text is the command as written, quotes and all, and a command substitution's text stays
    inside the command that holds it as well as being read as commands of its own, which come first.
    A process substitution's is read the same way (claude-config#3213).
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
    or opening backquote and end just past its closing one, a process substitution among them, its
    start at its `<(`, `>(` or `=(` (claude-config#3213); and openers, a (start, end) for each
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
    line_break = "\n" if typed or "\n" in s else "; "
    out, pending = [], []
    frames = [{"k": "top", "start": 0, "cwd": cwd, "old": None, "id": 0, "inner": [], "openers": []}]
    ids = [0]
    # The unquoted heredoc bodies being read, innermost last: each is also a frame, kind "hd", that
    # holds text the way a double quoted string does (its quotes are only text), from where its body
    # starts to "end", the start of its closing line, and then the reading goes on at "next".
    bodies = []
    # Where the last ) the reading went by ended, and what a # right after it is (word_starts): True
    # where the ) ended a command, False where it is still inside a word, None where that is not known.
    closed = [-1, None]
    # The line breaks a backslash before which joins nothing, for word_starts: where a comment this
    # reading took ends (True where the shell reads that comment too, None where that cannot be
    # told) and where a heredoc's closing line ends (True). Without it a # at the start of the line
    # after a comment that ended in a backslash was read as text (claude-config#3481).
    ended = {}
    # Each (start, end) the reading went on from where it used to leave the line out, for a caller
    # that asks for unsure (comment_end). A reading that then cannot be read to its end gives them
    # to unsure before it raises (unreadable).
    read_on = []
    # For naming an operator a backslash and a line break split (claude-config#3504): where the
    # character the last backslash escaped is, since that one starts no operator, and where the
    # single ) that closed a $(( )) or an arithmetic command ended, since a ) joined to it there
    # is the second of its )).
    escaped = arith_end = -1

    def unreadable(at=None):
        """The Unreadable to raise. A reading that went on past a # it used to take for a comment and
        then cannot be read to its end is not one to vouch for, so those # are named in unsure: a
        caller that judges an unreadable text by other means still refuses it (claude-config#3481)."""
        if unsure is not None:
            unsure.extend(read_on)
        return Unreadable(at)

    def comment_end(at, breaks):
        """Where the text this reading leaves out from the # at `at` ends, or None where that # is
        text: the character before it is none of breaks, or the caller asked for unsure and every
        shell reads the # inside a word (word_starts answers False, outside backquotes), where the
        reading goes on as the shell does (claude-config#3481). Otherwise the reading is the one it
        always was, the # a comment and the rest of its line nobody's text, and what it knows
        (claude-config#3464) is whether the shell agrees. Where it does (word_starts) the span is
        given to comments. Where it cannot be told (what the ) before it closed is not known or is
        read differently by bash and zsh; or the text is inside backquotes and either a backslash
        stands before the # there, which the backquotes read first, or a backquote stands after it on
        its line, where bash ends the backquotes, comment or not), it is given to unsure. A caller
        that asked for comments alone keeps the old reading everywhere, and a # the shell reads
        inside a word is then given to neither list."""
        if at and s[at - 1] not in breaks:
            return None
        j = s.find(line_break, at)
        end = n if j < 0 else j
        if comments is not None or unsure is not None:
            ticked = any(g["k"] == "tick" for g in frames)
            starts = word_starts(s, at, breaks, closed, ticked, ended)
            if starts is False and unsure is not None and not ticked:
                # Every shell keeps this # inside its word and runs the rest of the line (bash, sh,
                # dash, zsh and ksh, measured 2026-11-23), so a caller that asks which lines the
                # reading is unsure of is given the shell's reading here: the # is text
                # (claude-config#3481).
                read_on.append((at, end))
                return None
            sure = starts is True and not (ticked and "`" in s[at:end])
            given = comments if sure else unsure
            if given is not None:
                given.append((at, end))
            # A backslash at the end of this line is inside the comment and joins nothing, where
            # the shell reads the comment too. Where it may not (a # this reading is unsure of, or
            # one it leaves out for a caller that did not ask where the shell reads on), whether
            # the next line is joined cannot be told.
            ended[end] = True if sure else None
        return end

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
        if not head:
            # A function whose body opens on the case, `num(){ case "$1" in ''|*[!0-9]*) ...`
            # (tools/load-window.sh): read past its header, or the pattern's | was read as a pipe
            # (claude-config#2538).
            fh = FUNC_HEADER.match(text)
            head = CASE_HEAD.match(text, fh.end()) if fh else None
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
                 # Where it opened, at its $( or backquote, or a process substitution's <(, >( or
                 # =(, and whether that is inside double quotes in the text of the command holding it.
                 "open": start - (1 if kind == "tick" else 2),
                 "dq": any(f["k"] == '"' for f in frames[at + 1:])}
        frames.append(frame)

    def proc_opens(at):
        """Whether the ( at `at` opens a process substitution where the reading is outside quotes:
        after a < or a >, or after an = that starts a word (zsh's =( ), claude-config#3213)."""
        before = s[at - 1:at]
        return before in ("<", ">") or (before == "=" and (at == 1 or s[at - 2] in PROC_WORD_START))

    def close_commands(end):
        f = frames.pop()
        cut(f, end, ")")
        closed[:] = end + 1, f["k"] == "sub"
        if f["k"] in ("subst", "tick", "proc"):
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
                raise unreadable()
            frames.pop()
            i = bodies.pop()["next"]
            continue
        c = s[i]
        f = frames[-1]
        k = f["k"]
        # Inside single quotes only the closing quote changes the reading, and inside double quotes
        # or an unquoted heredoc body only the characters QUOTED_STOPS names: the reader goes
        # straight to the next of them, or to where the heredoc body it is in ends, which the top of
        # this loop reads first, as it did stepping one character at a time (claude-config#2918). Every
        # other frame goes straight to the next character it reads as more than text (FRAME_STOPS).
        stops = FRAME_STOPS[k]
        if not stops[0](c):
            m = stops[1](s, i + 1)
            j = m.start() if m else n
            stop_at = bodies[-1]["end"] if bodies else n
            i = j if j < stop_at else stop_at
            continue
        nx = s[i + 1] if i + 1 < n else ""
        if k == "'":
            frames.pop()  # c is the closing quote: anything else was gone past above
            if reread is not None:
                reread.append(("'", f["at"] + 1, i))
            i += 1
            continue
        if k == "ansi":
            if c == "'":
                frames.pop()
            i += 2 if c == "\\" else 1
            continue
        if c == "\\":
            if joined is not None and nx == "\n":
                # A join the shell makes too, for flattened(): not one in the text of a heredoc's
                # body, which is nobody's command, nor inside backquotes, which read a backslash
                # first themselves.
                held = next(g["k"] for g in reversed(frames) if g["k"] == "hd" or g["k"] in COMMAND_FRAMES)
                if held != "hd" and not any(g["k"] == "tick" for g in frames):
                    joined.append(i)
            if reread is not None and any(g["k"] == "tick" for g in frames):
                # The shell around backquotes takes a backslash and the line break after it out
                # of their text, and the backquotes halve what is left of the run before the
                # shell inside reads it. So the next line joins this one after every run of
                # backslashes but a multiple of four, which leaves that shell whole backslashes
                # and a line break (bash 3.2.57 and zsh 5.9). Counted in fours, with one over
                # the pair goes; with two over the shell inside is left the pair and removes it,
                # so both backslashes go; with three over it is left one backslash, which
                # escapes the next line's first character, so the pair goes and one backslash
                # more, leaving this reading one to escape that character with.
                width = 2 if nx == "\n" else 3 if s.startswith("\\\n", i + 1) else 0
                if width:
                    over = (i + width - 1 - len(s[:i + width - 1].rstrip("\\"))) % 4
                    if width == 3 and over == 2:
                        reread.append(("`", i, 3))
                    elif width == 2 and over == 1:
                        reread.append(("`", i, 2))
                    elif width == 2 and over == 3:
                        reread.append(("`", i - 1, 3))
            if unsure is not None and i and escaped != i - 1 and nx in ("\n", "\\"):
                # An operator this backslash and the line break after it split: the shells do not
                # agree on whether the two characters either side are joined, so it is named
                # (split_operator, claude-config#3504). Backquotes read a backslash first, so
                # there the pair may be written with two backslashes, or more.
                split = _split(s, i - 1)
                if split and (nx == "\n" or any(g["k"] == "tick" for g in frames)):
                    first, second = split[0]
                    if first == "$":
                        live = second != "'" or k not in ('"', "hd")
                    elif first == ")":
                        live = arith_end == i
                    elif k in COMMAND_FRAMES:
                        live = True
                    else:
                        live = k in ("param", "paren") and first in "<>=" and second == "("
                    if live:
                        unsure.append((i - 1, split[1] + 1))
            if nx != "\n":
                escaped = i + 1
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
                    arith_end = -1 if nx == ")" else i
                    # $(( )) is inside its word; an arithmetic command's )) ends it.
                    closed[:] = i, bool(f.get("command"))
                continue
        elif k == "param":
            if c == "}":
                frames.pop()
                i += 1
                continue
            if c == "(":
                # bash runs a <( ) or >( ) in the word of ${NAME:-word} unless the expansion is
                # inside double quotes or a heredoc body, where it is text (claude-config#3213).
                held = next(j for j in range(len(frames) - 1, -1, -1) if frames[j]["k"] in COMMAND_FRAMES)
                if s[i - 1] in "<>" and not any(g["k"] in ('"', "hd") for g in frames[held + 1:]):
                    open_commands("proc", i + 1)
                i += 1
                continue
        elif k == "paren":
            if c == "#" and f.get("array"):
                # A comment inside an array's ( ), as the shell reads one there too: an apostrophe in
                # it opened a quote that ran on past the array (tools/check-mod-shared-parts.sh's
                # PARTS, so no compound after it paired; claude-config#2683). It ends at the line
                # break, "; " in the flattened form, as a comment between commands does. Whether
                # the shell reads one there too is comment_end's to say (claude-config#3464).
                end = comment_end(i, " \t\n(")
                if end is not None:
                    i = end
                    continue
            if c == "(":
                if proc_opens(i):
                    open_commands("proc", i + 1)  # in an array's words (claude-config#3213)
                else:
                    frames.append({"k": "paren"})
                i += 1
                continue
            if c == ")":
                if frames.pop().get("pattern"):
                    end_pattern(frames[-1], i)
                    closed[:] = i + 1, True
                else:
                    # An array's, a function header's or any other plain ( ): bash reads a # right
                    # after an array's ) inside the word and zsh as a comment, so it is not known.
                    closed[:] = i + 1, None
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
        if c == "#":
            # A comment, as this reading always took one. Where the shell reads the # inside a word
            # (after an escaped space, right after the ) of a substitution) it runs the rest of the
            # line, which comment_end has a caller that asks read too (claude-config#3464, #3481).
            end = comment_end(i, WORD_BREAKS)
            if end is not None:
                cut(f, i, "#")
                i = end
                f["start"] = i
                continue
        if s.startswith("<<<", i):
            i += 3
            continue
        if s.startswith("<<", i):
            # A caller that asks which lines the reading is unsure of is given the opener as the
            # shells read it where its line ends in a backslash, the two lines joined and the
            # marker the word they make, and the heredoc's name at once, by its << to the end of
            # that word: what follows was read as commands until now, and nothing read so is
            # dropped on the strength of the join (heredoc_opener, claude-config#3492). A caller
            # that does not ask is given the reading it always was.
            # The same caller is given the heredoc's name where its marker holds a dollar quote,
            # after which the seven shells never all end the body at one line (heredoc_opener's
            # doubts, claude-config#3566): the marker read here is bash's and zsh's wherever those
            # two agree, for every caller, and dash's nowhere.
            joins = None if unsure is None else []
            doubts = None if unsure is None else []
            opener = heredoc_opener(s, i, joins=joins, doubts=doubts)
            if opener:
                before = s[f["start"]:i]
                f["openers"].append((i, opener[3]))
                at = i
                word, strip_tabs, quoted, i = opener
                if joins or doubts:
                    unsure.append((at, i))
                pending.append((word, strip_tabs, quoted, before, at, bool(joins or doubts)))
            else:
                i += 2
            continue
        if lines is not None and pending and line_break == "\n" and s.startswith(FLAT_BREAK, i):
            # A separator the flattened form reads as the line break that starts the waiting
            # bodies (claude-config#3739). It is read here as the separator it is, just below.
            lines.append(("after", i, len(pending)))
        if pending and s.startswith(line_break, i):
            # The bodies start on the next line: find the closing line of each in turn. One that never
            # closes is not skipped, so nothing after it is hidden. Where the shells do not close an
            # unquoted one at the first line that is its marker, a caller that asks is given the
            # shells' closing line and the heredoc's name; one that does not is given the reading it
            # always was (heredoc_close, claude-config#3492).
            j, unquoted, skipped, where, closes = i, [], [], [], []
            for word, strip_tabs, quoted, before, at, named in pending:
                plain, shells, sure = heredoc_close(s, j, word, strip_tabs, quoted, line_break)[:3]
                m = plain if unsure is None else shells
                # One whose opener a backslash joined to the next line is named already.
                if not sure and unsure is not None and not named:
                    unsure.append((at, i))
                if not m:
                    j = None
                    break
                if not quoted:
                    unquoted.append((j, m.start()))
                body = s[j:m.start()]
                skipped.append((quoted, before, body[len(line_break):] if body.startswith(line_break) else body))
                where.append((at, j, m.start()))
                j = m.end()
                closes.append(j)  # the line break that ends this closing line
            if j is not None and heredocs is not None:
                heredocs.extend(skipped)
            if j is not None and spans is not None:
                spans.extend(where)
            if lines is not None and line_break == "\n":
                lines.append(("open", i, [at for _, _, _, _, at, _ in pending]) if j is None else
                             ("bodies", i, [(start, end) for (_, start, _), end in zip(where, closes)]))
            pending.clear()
            if j is not None:
                # A closing line is read as it is written, so a backslash that ends one (an end
                # marker written 'E\') joins nothing and a word starts on the next line.
                for close in closes:
                    ended[close] = True
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
        if c == "(" and proc_opens(i):
            # A process substitution: its commands are commands of their own, and its text stays in
            # the command holding it, as a command substitution's does (claude-config#3213). Read
            # before a case pattern's ( is, since the shell expands one in a pattern too.
            open_commands("proc", i + 1)
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
            closed[:] = i + 1, True
            i += 1
            continue
        if c == "(":
            before = s[f["start"]:i]
            header = FUNC_HEADER.match(before)
            if header:
                before = before[header.end():]
            # A function whose body is a subshell, `f() ( git push )`: the ( after the header opens
            # the body, whose commands the shell runs on each call (claude-config#3252). The ( of
            # `function f ()` is the header's own.
            body = (not header and FUNC_BODY_OPENS.fullmatch(before)
                    and not (before.rstrip()[-1:] != ")" and EMPTY_PARENS.match(s, i)))
            if body or (all(w in RESERVED for w in before.split()) and (not header or before.split())):
                if nx == "(":
                    frames.append({"k": "arith", "depth": 0, "command": True})
                    i += 2
                else:
                    open_commands("sub", i + 1)
                    i += 1
            else:
                # NAME=( or NAME+=( opens an array, whose words may carry comments.
                frames.append({"k": "paren", "array": s[i - 1:i] == "="})
                i += 1
            continue
        if c == ")":
            if k in ("sub", "subst", "proc"):
                close_commands(i)
            else:
                closed[:] = i + 1, None  # one that closes nothing the reading opened
        i += 1
    if len(frames) > 1:
        raise unreadable(next((f["at"] for f in frames if "at" in f), None))
    if lines is not None and pending and line_break == "\n":
        lines.append(("end", n, [at for _, _, _, _, at, _ in pending]))
    cut(frames[0], n, "end")
    return out


def command_words(text):
    """One command's words as the shell reads them, quotes removed, past any leading reserved word.

    `then git push` is git's command: the reserved words only open or continue a compound command,
    and a walker that took `then` or `do` for the command name saw no push in `if x; then git push;
    fi` (#1017). Looked past from RESERVED, the same list cd_target uses, so the two readings cannot
    disagree about which word is the command. A command shlex cannot read (an unbalanced quote) is
    split on whitespace instead, the reading that still lets a push be seen. A redirection glued to
    a word is a word of its own, as the shell reads it (spaced, claude-config#3252).
    """
    text = spaced(join_continuations(text))
    try:
        words = shell_split(text)
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


# Where a command written inside another starts or ends, for the crude cut (claude-config#3473): the
# opener of a command or process substitution or of a subshell, a closing parenthesis, and a
# backquote, which is both. Quotes and backslashes are not weighed: the cut is asked only where the
# text could not be read, so which of them is live is exactly what is not known.
CRUDE_EDGE = re.compile(r"\$\(|[<>=]\(|\(|\)|`")


def after_a_name(text, at):
    """Whether the `(` at text[at] is written straight after a name that is no reserved word.

    Such a parenthesis starts no command in any shell. Measured 2026-11-26, each text run by bash,
    zsh, dash and sh in an empty folder: `open(touch x)`, `f(touch x)`, `x=1(touch x)`,
    `$x(touch x)` and `cat = open(touch x).read()` made no file in any of them. After a word that
    only opens or continues a compound command it does: bash, dash and sh ran
    `if(touch x); then :; fi`, and the same glued to then, else, elif, do, while and until, and bash
    and sh after time. Those are RESERVED's words, the list the reader already looks past to reach a
    command, so that one list answers here too. A name is letters, digits and underscores, the only
    shapes measured: after a quote, a brace or a bracket the parenthesis is still taken to open.
    """
    i = at
    while i > 0 and text[i - 1].isascii() and (text[i - 1].isalnum() or text[i - 1] == "_"):
        i -= 1
    return i < at and text[i:at] not in RESERVED


def crude_inner(text):
    """The stretches of one piece of the crude cut that may be commands of their own
    (claude-config#3473): what follows each opener, closer or backquote, and what stands before a
    closer or a backquote. The cut left a `$( )`, a pair of backquotes, a `<( )` and a subshell
    whole, so `x=$(git push)` named no git command, and `(git push)` named the subcommand `push)`.

    What follows a `)` is listed too, because the `)` of a case pattern has its arm's command after
    it. The one stretch left out is the piece's start up to an opener: that is the head of the
    command the piece itself is, which its own record already hands on, and listing it would give a
    caller that counts commands the same one twice. Nothing blank is listed.

    A backquote is not told as opening or closing: the cut splits `` `cd x; git push` `` in two, so
    in a piece the first backquote may close what an earlier piece opened, and what stands before
    it is then a command. So the start of a piece up to a backquote is listed even where that
    backquote opens, `git push origin main `date``, and that command is given twice, once whole
    and once without the words from the backquote on. Twice is the safe side of not at all.

    A `(` written straight after a name is no edge (after_a_name): no shell starts a command there,
    and listing what follows it handed a gate `"$1"` out of a heredoc's `open("$1")` as a command
    the script runs, which it does not (L11). Only that `(` is passed over. Every `)` stays an
    edge, the one that closes it too, because the parenthesis may be glued to a name inside a quoted
    word, `x=$(git push origin "a(b")`, and the `)` after it then closes the substitution.
    """
    out, at, first = [], 0, True
    for m in CRUDE_EDGE.finditer(text):
        if m.group() == "(" and after_a_name(text, m.start()):
            continue
        part = text[at:m.start()]
        if part.strip() and (not first or m.group() in (")", "`")):
            out.append(part)
        at, first = m.end(), False
    if not first and text[at:].strip():
        out.append(text[at:])
    return out


# Where the crude cut cuts: every separator, quotes and all.
CRUDE_CUT = re.compile(r"&&|\|\||;|\||\n")


def crude_commands(s, cwd=""):
    """The reading used when commands() cannot be trusted: a cut at every separator, quotes and all,
    and after the pieces of that cut the commands that may be written inside one (crude_inner).

    It can only see MORE commands than are there, which is the direction a gate that must not miss a
    push needs (L42), and it keeps the cds in order, so the last one before a push still governs it.
    The pieces are the ones it always gave, each with the text and the directory it always had, and
    they come first, in the order they always had: a caller that reads the records in order and
    stops at the first one that settles its question reaches every piece it reached before, and
    reaches a command found inside one only where the pieces settled nothing. Put before the piece
    that holds them, as commands() gives a substitution's, they would be the first command of a
    text for a caller that asks how a text begins (lib/unknown-program.py's holds_command), and
    could turn its answer either way. Each is given in its piece's directory, and a cd among them
    moves nothing, so no caller is handed less, or anything in another place, than before
    (claude-config#3473).
    """
    out, found, old = [], [], None
    for text in CRUDE_CUT.split(s):
        if text.strip():
            found.extend((cwd, inner) for inner in crude_inner(text))
            out.append((cwd, text))
            target = cd_target(text)
            if target is not None:
                cwd, old = moved(cwd, old, target)
    return out + found


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
    caller reads its arguments the way it always has, but for the space written before a
    redirection glued to a word (spaced, claude-config#3252).
    """
    return _command_rest(text, passed, True)


def _command_rest(text, passed, glue_read, headers=True):
    """command_rest, or with glue_read False the same reading without the space spaced() writes,
    for glued_script alone, which asks how a command read before claude-config#3252, or with
    headers False the same reading with no function's header passed over, for headed_string
    alone, which asks the same of a header. Kept apart from command_rest, whose two arguments are
    what a caller wrapping it passes on: the Slack drafts gate puts a wrapper of exactly that shape
    in its place to read each text once."""
    s = text.lstrip()
    # A subshell or group opening a command the crude cut left whole, `( cd x && git push )` or
    # `(git push)`, is not part of it (claude-config#439): an opener glued to the name is peeled off,
    # one standing alone is passed over. The commands reading never leaves one.
    while s.startswith("(") and not s.startswith("(("):
        s = s[1:].lstrip()
    while True:
        m = re.match(r"(\S+)(\s+|$)", s)
        if not m or m.group(1) not in RESERVED:
            # A function's header stands before its body's first command as a reserved word stands
            # before a command, and the { after it is one (claude-config#3252).
            header = FUNC_HEAD.match(s) if headers else None
            if header:
                s = s[header.end():]
                continue
            break
        s = s[m.end():]
        # The shell's own time takes -p, and -- to end it, before the command it times
        # (claude-config#1478); /usr/bin/time by its path is a runner (RUNNERS).
        while m.group(1) == "time":
            m2 = re.match(r"(-p|--)(\s+|$)", s)
            if not m2:
                break
            s = s[m2.end():]
    # A redirection glued to the name, to a runner or to a word after either is a word of its own
    # from here on (claude-config#3252).
    assigns, rest = past_head(spaced(s) if glue_read else s)
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


# ---- a redirection glued to the word before it (claude-config#3252) ------------------------------
# The shell ends a word at a redirection's operator, so `git>/dev/null push` runs git push with its
# output redirected, `git push>/dev/null` the same, and `env>/dev/null git push` runs env. Read by
# its whitespace, the first was a program named git>/dev/null, the second a subcommand named
# push>/dev/null and the third no runner, so no gate asking for a git push saw one in any of them.
# spaced() writes the space the shell reads there and changes nothing else: the words, the
# redirections and their order stay as written, so every reading after it (the name, a runner's
# options, the subcommand, a shell's -c string, a cd's directory) meets a spelling it always read.
# Quotes, an escaped operator, substitutions, ${ }, arithmetic and anything in parentheses are text.
# A descriptor number is the redirection's only as a word of its own (`2>x`; in `v2>x` the word is
# v2), and bash's {name}> stays whole. <( ) and >( ) are words, and so is zsh's numeric range
# <1-10>. A test's [[ a<b ]] and an arithmetic (( a<b )) compare and redirect nothing, so a command
# that opens on either is left as written.
GLUED_STOP = re.compile(r"""[\\'"$`<>(&]""")
# What may stand right before a redirection that is glued to nothing: a blank, or what ends a command.
OPERATOR_START = " \t\n;|&("
NUMERIC_RANGE = re.compile(r"<\d*-\d*>")
NAMED_DESCRIPTOR = re.compile(r"\{[A-Za-z_][A-Za-z0-9_]*\}")
DESCRIPTOR_TARGET = re.compile(r"[ \t]*(?:\d+|-)")
TEST_OPENS = re.compile(_PREFIX + r"(?:\[\[|\(\()")


def _past(s, i):
    """The index just past the quoted or bracketed piece that opens at s[i] (a quote, $' ', ${ }, a
    backquote or a parenthesis, a substitution's or any other), or len(s) when it never closes."""
    n, stack = len(s), []
    while i < n:
        c = s[i]
        top = stack[-1] if stack else ""
        if top == "'":
            j = s.find("'", i)
            if j < 0:
                return n
            stack.pop()
            i = j + 1
        elif top == "$'":
            if c == "\\":
                i += 2
                continue
            if c == "'":
                stack.pop()
            i += 1
        elif c == "\\":
            i += 2
            continue
        elif top == '"':
            if c == '"':
                stack.pop()
            elif c == "`":
                stack.append("`")
            elif c == "$" and s[i + 1:i + 2] in ("(", "{"):
                stack.append(s[i + 1])
                i += 1
            i += 1
        else:
            if c == "'":
                stack.append("'")
            elif c == '"':
                stack.append('"')
            elif c == "`":
                if top == "`":
                    stack.pop()
                else:
                    stack.append("`")
            elif c == "$" and s[i + 1:i + 2] == "'":
                stack.append("$'")
                i += 1
            elif c == "$" and s[i + 1:i + 2] == "{":
                stack.append("{")
                i += 1
            elif c == "(":
                stack.append("(")
            elif c == ")" and top == "(":
                stack.pop()
            elif c == "}" and top == "{":
                stack.pop()
            i += 1
        if not stack:
            return i
    return n


def spaced(text):
    """text with a space written before each redirection glued to the word before it, and text itself
    when it holds none (claude-config#3252). Most commands hold no < and no >, and are answered by
    looking for those two characters alone."""
    if "<" not in text and ">" not in text:
        return text
    return _spaced(text)


@functools.lru_cache(maxsize=4096)
def _spaced(s):
    cuts = [p for p, _, _ in _redirections(s) if p > 0 and s[p - 1] not in OPERATOR_START]
    if not cuts:
        return s
    out, at = [], 0
    for p in cuts:
        out.append(s[at:p])
        at = p
    out.append(s[at:])
    return " ".join(out)


@functools.lru_cache(maxsize=4096)
def _redirections(s):
    """Every redirection one command's text s holds outside quotes, in order, each as (where it
    starts, its descriptor included; where its operator ends, past the descriptor it copies when it
    names one, `2>&1`; whether that descriptor was its whole target). The one reading of where a
    redirection stands, for spaced(), which writes a space before one, and unredirected(), which
    takes each out with its target. An empty tuple for a command that opens on a test or an
    arithmetic."""
    if TEST_OPENS.match(s):
        return ()
    n, i, floor, found = len(s), 0, 0, []
    while i < n:
        m = GLUED_STOP.search(s, i)
        if not m:
            break
        i = m.start()
        c = s[i]
        nx = s[i + 1:i + 2]
        if c == "\\":
            i += 2
            continue
        if c in "'\"`(" or (c == "$" and nx in ("'", "{")):
            i = _past(s, i)
            continue
        if c == "$" or (c == "&" and nx != ">"):
            i += 1
            continue
        if c != "&" and nx == "(":
            i = _past(s, i + 1)  # <( ) or >( ): a word, whose text is its own
            continue
        if c == "<":
            r = NUMERIC_RANGE.match(s, i)
            if r:
                i = r.end()
                continue
        # The redirection starts at its descriptor when one is written as a word of its own.
        p = i
        if c != "&":
            j = i
            while j > floor and s[j - 1].isdigit():
                j -= 1
            if j < i and (j == 0 or s[j - 1] in OPERATOR_START):
                p = j
            elif s[i - 1:i] == "}":
                k = s.rfind("{", floor, i)
                if k >= 0 and NAMED_DESCRIPTOR.fullmatch(s, k, i) and (k == 0 or s[k - 1] in OPERATOR_START):
                    p = k
        op = LEADING_REDIRECT.match(s, i)
        i = op.end()
        whole = False
        if s[i - 1] == "&":
            # A descriptor it is copied from or to, `2>&1`, is its target and no word before the next.
            t = DESCRIPTOR_TARGET.match(s, i)
            if t:
                i, whole = t.end(), True
        found.append((p, i, whole))
        floor = i
    return tuple(found)


# ---- a redirection among a command's words (claude-config#3322) ----------------------------------
# The shell takes every redirection out of a command before the program sees its words, wherever it
# stands: `gh api >/dev/null -X DELETE <ref>` deletes the ref and `gh pr merge 2>/dev/null 7` merges
# pull request 7. The words were handed to each gate with the redirection among them, so a gate that
# took the first word that is no option for the endpoint read an endpoint named >/dev/null (the
# stacked branch delete gate let that delete run unasked), and one that took the first number for
# the pull request read pull request 2. Each reader stepped over a redirection itself or did not.
# unredirected() takes them out once, from the text, where a quoted `'>'` is still told from the
# operator, and tool_words() is the one place the words a gate reads of a gh or git command are made.
# A reader that judges where a command's output goes, or what its input is, reads the command's own
# words or text, which keep every redirection (lib/push-scope.sh ps__writes_out reads PS__R_WORDS;
# gh_issue_scan.py's pipelines() keeps each stage's redirections beside its words).
def unredirected(text):
    """(one command's text with every redirection taken out, those redirections as written).

    A redirection is its operator, the descriptor written against it, and its target: the descriptor
    it copies (`2>&1`, `<&-`), or else the next word, glued on or after blanks, read to its end as an
    assignment's value is, so `2>"a b"` and `>$(mktemp)/x` are each one. A heredoc's opener and a
    here string go with their word. Quotes, an escaped operator, a substitution, <( ) and >( ) are
    text and stay (_redirections). Most commands hold no < and no >, and are answered by looking for
    those two characters alone."""
    if "<" not in text and ">" not in text:
        return text, []
    s = join_continuations(text)
    spans = _redirections(s)
    if not spans:
        return text, []
    out, taken, at = [], [], 0
    for p, end, whole in spans:
        if p < at:
            continue  # written inside the target of the one before it, `>a<b`, and taken with it
        if not whole:
            tail = s[end:].lstrip(" \t")
            rest = split("_=" + tail, 1)[1] if tail else ""
            if not s.endswith(rest):
                return text, []  # not read to a place in the text: left as written, as it always was
            end = len(s) - len(rest)
        out.append(s[at:p])
        taken.append(s[p:end].strip())
        at = end
    out.append(s[at:])
    return " ".join(out), taken


def tool_words(rest):
    """The words of one command, from its text from its own name on (command_rest), as the program
    gets them: its redirections taken out (unredirected). What tool_read is given wherever the text
    is known, so the words a gate reads of a gh or git command hold no redirection
    (claude-config#3322)."""
    return command_words(unredirected(rest)[0])


# ---- a function's header in front of its body's first command (claude-config#3252) ---------------
# `f() { git push; }` is cut at the ; so its first command's text is `f() { git push`, and read from
# its first word that was a program named f(), so the first command of every function body was no
# git and no gh to any gate, while the second was read. zsh also takes any one command as a body,
# `f() git push`. command_rest passes the header over as it passes a reserved word over.
FUNC_HEAD = re.compile(r"(?:function\s+[^\s(){}]+(?:\s*\(\s*\))?|[A-Za-z_][\w:.-]*\s*\(\s*\))\s*")
# A function's header and nothing after it, which is what stands before the ( of a body written as
# a subshell, `f() ( git push )`: the shell runs that body's commands on each call, and read as a
# plain ( ) they were one command named f() that no gate read (claude-config#3252).
FUNC_BODY_OPENS = re.compile(_PREFIX + FUNC_HEAD.pattern)
EMPTY_PARENS = re.compile(r"\(\s*\)")


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
            # A redirection among the runner's own options is the shell's, as one before its
            # command is: `env 2>/dev/null -u X gh pr merge 7` was a command named -u, and `timeout
            # 2>/dev/null 30 git push` took the redirection for the duration (claude-config#3252).
            s = past_redirects(s)
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
            _, s = first_word(past_redirects(s))
        if name == "rtk":
            sub_word, after_sub = first_word(past_redirects(s))
            if sub_word == "proxy":
                # rtk proxy runs the words after its own options as they stand. rtk is then not the
                # command's last runner, so `rtk proxy init` is a program named init, not rtk's.
                s = after_sub
                while True:
                    s = past_redirects(s)
                    opt, after_opt = first_word(s)
                    if opt is None or not opt.startswith("-") or opt == "-":
                        break
                    s = after_opt
                    if opt == "--":
                        break
                rest = s
                continue
        if passed is not None:
            passed.append((name, past_redirects(s)))
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
    path, front, redirections = [], [], []
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
        k = redirection_words(words, j)
        if k:
            redirections.extend(words[j:j + k])
            j += k
            continue
        w, glued = glued_cut(w)
        path.append(w)
        j += 1
        if glued:
            k = 0 if REDIRECT_WORD.match(glued).group(1) or j >= n else 1
            redirections.extend([glued] + words[j:j + k])
            j += k
        if len(path) == 2 or path[0] == "api":
            break
    sub, act = gh_long_form(path[0] if path else "", path[1] if len(path) > 1 else "")
    return sub, act, front, words[j:] + redirections


# Where a redirection glued to a word starts in it: its < or >, or the & of an &>.
GLUED_AT = re.compile(r"&(?=>)|[<>]")


def redirection_words(words, j):
    """How many of words from j on are one redirection, as shlex.split or shell_tokens leaves one:
    1 for an operator with its target (`2>/dev/null`), 2 for an operator whose target is the next
    word (`>` then `/dev/null`), 0 when words[j] is none (claude-config#3252)."""
    m = REDIRECT_WORD.match(words[j])
    if not m:
        return 0
    return 1 if m.group(1) or j + 1 >= len(words) else 2


def glued_cut(word):
    """(word, "") for a word holding no redirection, else (the word before the redirection glued to
    it, that redirection): `push>/dev/null` is push and >/dev/null (claude-config#3252). For the
    words a caller split itself, where the quotes are gone: no program, subcommand or action is
    named with a < or a > in it, so one read there is the shell's."""
    m = GLUED_AT.search(word, 1)
    return (word[:m.start()], word[m.start():]) if m else (word, "")


def git_path(words):
    """The words after `git` as git reads them: (sub, front, after). sub is the subcommand (empty
    when there is none), front git's own options before it, after every word after it.

    A redirection written before the subcommand is the shell's and no subcommand (claude-config
    #3252): `git 2>/dev/null push` and `git > /dev/null push` were subcommands named 2>/dev/null and
    >, so no push to any gate. Passed over, it is given with the words after the subcommand, where a
    redirection written last has always stood, and so is one glued to the subcommand."""
    j, n = 0, len(words)
    front, redirections = [], []
    while j < n:
        k = redirection_words(words, j)
        if k:
            redirections.extend(words[j:j + k])
            j += k
        elif words[j].startswith("-") and words[j] != "-":
            k = 2 if words[j] in GIT_VALUED else 1
            front.extend(words[j:j + k])
            j += k
        else:
            break
    if j >= n:
        return "", words[:n], []
    sub, glued = glued_cut(words[j])
    j += 1
    if glued:
        k = 0 if REDIRECT_WORD.match(glued).group(1) or j >= n else 1
        redirections = [glued] + words[j:j + k] + redirections
        j += k
    return sub, front, words[j:] + redirections


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
    `rtk gh issue create` and `env GH_TOKEN=x gh pr merge` exactly as the bash gates do. A
    redirection shell_tokens marked (Redirection) is written back as one, so it is taken out with
    its target as the bash gates' is (tool_words, claude-config#3322); any other word that only
    looks like one is a word, as it always was."""
    text = rejoin(words)
    if not text:
        return None
    rest, _ = command_rest(text)
    return tool_read(tool_words(rest))


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
    # A redirection's operator shell_tokens read outside quotes (Redirection) is written bare
    # wherever it stands, so the reading takes it out with its target (claude-config#3322). Any
    # other word is quoted, a `>` a caller's own split left among them included, since nothing says
    # whether that one was quoted as written.
    pieces = [str(w) if isinstance(w, Redirection) else
              w[:m.end()] + shlex.quote(w[m.end():]) if m else shlex.quote(w)
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
        if bare is None and k is not None:
            # A redirection glued to the name, `git>/dev/null` as shlex.split leaves it, is written
            # as the name and then the redirection, so command_rest reads the name (claude-config
            # #3252): quoted whole, it was a program of that name and no gate saw what it ran.
            name, glued = glued_cut(words[k])
            if name and glued:
                bare = shlex.quote(name) + " " + _redirect_bare(glued)
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


def shell_tokens(text, commenters="", partial=False):
    """text's words and operators as shlex's punctuation lexer cuts them, quotes removed, except that
    a descriptor number written against its redirection stays one token with it: `2>/dev/null` is
    `2>` and `/dev/null`, where `2 >/dev/null` is `2`, `>` and `/dev/null` (claude-config#2235).

    The lexer cuts both into the same three tokens, so a reader of them could not tell `2>/dev/null gh
    issue create`, a create, from `2 >/dev/null gh`, a command named 2. Whether the number ended at
    the operator or at a space is what the lexer holds back after it: the operator it read and pushed
    back, or nothing. A lexer keeping no such record reads every number before an operator as its
    descriptor, the reading that sees the command after it. Raises ValueError as shlex does.

    A redirection's operator written outside quotes is given as a Redirection (claude-config#3322),
    which is the same text and compares as it always did: the lexer cuts `>` and `'>'` into the same
    token, so a reader of the tokens could not tell the shell's redirection from a word, and
    tool_command could not take one out without taking a quoted message with it. Told apart by the
    text the lexer read for the token, which is the token itself only when nothing in it was quoted
    or escaped. A lexer that does not say how far it has read marks none, and every token is then
    the word it always was.

    commenters and partial are lib/merge-selector.py's, which read its tokens with a lexer of its own
    until #3322: a # starts a comment for it, and its walk stops at the first token the lexer cannot
    read and keeps the ones before it, where every other caller is given the ValueError."""
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = commenters
    out, glue, at, bare_before = [], False, 0, False
    while True:
        try:
            tok = lexer.get_token()
        except ValueError:
            if partial:
                return out
            raise
        if tok is None:
            return out
        held = getattr(lexer, "_pushback_chars", None)
        bare = False
        if held is not None:
            try:
                end = lexer.instream.tell() - len(held)
            except (AttributeError, OSError, ValueError):
                end = None
            if end is not None:
                bare = text[at:end].strip() == tok
                at = end
        if glue and tok[:1] in ("<", ">"):
            joined = out[-1] + tok
            out[-1] = Redirection(joined) if bare and bare_before and LEADING_REDIRECT.fullmatch(joined) else joined
        else:
            out.append(Redirection(tok) if bare and LEADING_REDIRECT.fullmatch(tok) else tok)
        bare_before = bare
        glue = tok.isdigit() and (held is None or any(c in "<>" for c in held))


class Redirection(str):
    """A redirection's operator as shell_tokens read it outside quotes, the descriptor number
    written against it included (`>`, `2>`, `&>`, `<<<`). Its target is the token after it. The same
    text as the plain token, so a caller comparing or matching tokens reads what it always did; only
    rejoin asks which kind it is (claude-config#3322)."""
    __slots__ = ()


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
    being read by git_dir. No word is a redirection, wherever one was written (tool_words,
    claude-config#3322)."""
    found = tool_read(tool_words(rest))
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
    after = join_continuations(passed[-1][1])
    try:
        words = shell_split(after)
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
    rest = join_continuations(rest)
    if word in ("source", "."):
        try:
            operands = shell_split(rest)[1:]
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
    rest = join_continuations(rest)
    name, _ = first_word(rest)
    if name is None:
        raw = rest.split(None, 1)
        name = raw[0].strip("'\"") if raw else ""
    word, name = name, name.split("/")[-1]
    if name not in SHELLS and name not in ("eval", "env") and name not in ARGUMENT_RUNNERS:
        return _script_run(word, rest)
    try:
        words = shell_split(rest)
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
#
# A compiled program is left unread too (claude-config#3299). One run by its path was decoded as text
# and cut into commands: 616 of them for /Applications/BBEdit.app/Contents/Helpers/bbedit_tool, a
# Mach-O file, measured 2026-11-19, so a guard's verdict could turn on bytes that happened to spell
# a command. No shell reads such a file as commands: the kernel runs it, or the shell refuses it. A
# file is called compiled (compiled) only where that was measured, on 2026-11-21 with zsh 5.9, bash
# 3.2, dash and ksh on macOS: its first four bytes are a Mach-O or ELF magic number, and a NUL byte
# follows among its first COMPILED_HEAD bytes with nothing a shell ends a word at before it, as every
# real header has (the CPU type, or the ELF class, byte order and version, then a zero). And only
# for a file run by its path or handed to bash (COMPILED_RUNNERS), which refuse it: zsh, dash and a
# sourcing shell run its lines as commands, and sh and ksh are another shell on another machine, so
# for those it is read as before. Every narrower look alike is still read, because a shell does run
# it, each one measured the same day: a NUL only after the first line, bytes that are not UTF-8, the
# magic number with no NUL (`\x7fELF;cmd` runs cmd under all four shells), and a NUL after a word
# has ended (`\x7fELF;cmd;\0`, which ksh runs by its path). Reading those can only add commands, so
# no guard passes anything for this that it refused before. compiled_program is the reader's answer:
# script_text asks it before reading any file as a script, and a guard that wants to judge a compiled
# program at a path its own way can ask it too; left alone, it is a program whose commands nobody
# reads, as a python script is.
SCRIPT_MAX_BYTES = 256 * 1024
COMPILED_MAGIC = (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
                  b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf", b"\x7fELF")
COMPILED_HEAD = 16
COMPILED_RUNNERS = ("direct", "bash")
_WORD_ENDS = frozenset(b" \t\r\n;&|()<>")
_WHY_FILE_HEAD, _, _WHY_FILE_TAIL = WHY_FILE.partition("%s")


def compiled(head):
    """Whether a file's first bytes are a compiled program's header, one no shell reads as commands
    when the file is run by its path or handed to bash (claude-config#3299)."""
    head = bytes(head[:COMPILED_HEAD])
    if head[:4] not in COMPILED_MAGIC:
        return False
    nul = head.find(b"\0", 4)
    return nul != -1 and not any(b in _WORD_ENDS for b in head[4:nul])


def _script_path(path, d):
    """The full path a script file's name stands for, run in directory d, or None when it cannot be
    told: a variable in its name, or a relative name with no absolute directory to resolve it against."""
    if "$" in path or "`" in path:
        return None
    path = os.path.expanduser(path)
    if not os.path.isabs(path):
        if not os.path.isabs(d or ""):
            return None
        path = os.path.join(d, path)
    return os.path.normpath(path)


def compiled_program(path, d, wrapper):
    """The full path of the file path names, run by wrapper in directory d, when it is a compiled
    program that wrapper never reads as commands (compiled, COMPILED_RUNNERS), else None: no such
    file, one that cannot be read, a script, or a file handed to a shell that runs its lines. It
    reads only the file's first bytes, so a program too large to read as a script is still named.
    script_text asks this before it reads any file as a script, so it is the one place the answer
    is made; a guard that wants to judge a compiled program its own way asks it the same way."""
    full = _script_path(path, d)
    if full is None or wrapper not in COMPILED_RUNNERS:
        return None
    try:
        if not os.path.isfile(full):
            return None
        with open(full, "rb") as f:
            head = f.read(COMPILED_HEAD)
    except OSError:
        return None
    return full if compiled(head) else None


def script_file(why):
    """The script file a WHY_FILE reason names, as written, or None for any other reason."""
    if why.startswith(_WHY_FILE_HEAD) and why.endswith(_WHY_FILE_TAIL) \
            and len(why) > len(_WHY_FILE_HEAD) + len(_WHY_FILE_TAIL):
        return why[len(_WHY_FILE_HEAD):len(why) - len(_WHY_FILE_TAIL)]
    return None


def script_text(path, d, wrapper):
    """(full path, text) of the script file path names, run by wrapper in directory d, or None when it
    cannot be read: not there, unreadable, too large, a variable in its name, a relative name with no
    absolute directory to resolve it against, a file run by its path whose #! names no shell, or a
    compiled program its wrapper never reads as commands (compiled_program, claude-config#3299)."""
    if compiled_program(path, d, wrapper):
        return None
    path = _script_path(path, d)
    if path is None:
        return None
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


def glued_script(text):
    """The reason one command was reported as a script file run by its path before claude-config
    #3252, when that came only of a redirection holding a slash glued to its name (`git>/dev/null
    status`, read as a file named git>/dev/null); "" for any other command.

    The shell runs the program, and every other reading here now says so. But check-wrapped-commands.sh
    refuses a script file beside git, gh or rtk, so it refused these, and a refusal is not dropped as
    a side effect of a fix to the reader: that is a decision of its own, left to Dan in #3252's pull
    request. Until it is made the command keeps the report it had, word for word, beside its true
    reading. Delete this function and its one call to stop reporting it.

    This answers for the first word alone: whether a redirection is glued to it and the old reading
    took the whole word for a script file. It does not ask whether the command is a script file by
    its true reading, and for one that is (`./build.sh>log`) it returns the old words, which name
    ./build.sh>log. Its one caller, _records, asks only when the true reading is no script file, so
    those words reach no guard; a second caller must ask the same way."""
    if "<" not in text and ">" not in text:
        return ""
    rest = _command_rest(text, None, False)[0]
    word, _ = first_word(rest)
    if not word or not glued_cut(word)[1]:
        return ""
    old = _script_run(word, rest)
    return old[2] if old and old[0] == "direct" else ""


def headed_string(text):
    """(the wrapper, its string) for one command that hands a shell or eval a string and is read
    as that only because a function's header is passed over (claude-config#3252), else None.

    `f() { bash -c "..."` is the first command of f's body. Before #3252 it was a program named
    f(), so its string's commands were given to no caller, and they are records of their own now.
    A caller that reads such a string another way than as written (the Slack drafts gate, which
    fills in what the outer shell fills in) asks here which commands those are, so that what it
    sets aside is only ever a reading nobody had before. None for a command with no header in
    front, for one whose string cannot be read, and for one that was a wrapper with the header
    left where it is (a function named as a wrapper is, `eval () { ...`, read before as eval's
    string): what was read before stays every caller's to read as it did."""
    if wrapped(_command_rest(text, None, True, False)[0]) is not None:
        return None
    found = wrapped(command_rest(text)[0])
    if found is None or found[1] is None or found[2]:
        return None
    return found[0], found[1]


def _records(s, cwd, depth, scripts=None, fields=True):
    """(records, crude) for a command line: each record (dir, text, wrap, rest, assigns, field, depth), a
    wrapper's commands right after it (claude-config#1478). wrap is "" for a command that is no
    wrapper, the wrapper's name (`bash -c`, `eval`, ...) for one whose string was read, and that name
    0x1d the reason for one whose string cannot be read; depth is how many wrappers it is inside; crude
    says s itself could only be read by the crude cut. scripts, a list, asks for the commands of each
    script file a command runs as well, right after its record, and is given (path, text) for each
    one read (claude-config#2301). fields=False leaves each field "" for a caller that reads none: it
    is a reading of each command's words, and every_command, which drops it, asked for all 14,000 of
    claude-sync's on every claude-sync line the Slack drafts gate judged (claude-config#2918)."""
    try:
        cut, crude = commands(s, cwd), False
    except Unreadable:
        cut, crude = crude_commands(s, cwd), True
    out = []
    for d, t in cut:
        if fields:
            rest, assigns, field = program_field(t)
        else:
            (rest, assigns), field = command_rest(t), ""
        found = wrapped(rest)
        if found is None or (found[1] is not None and not found[2]):
            kept = glued_script(t)
            if kept:
                # Refused before claude-config#3252 as a script file, and so still reported as one
                # (glued_script), with the commands of a string it hands a shell read after it.
                inner = []
                if found is not None and depth < MAX_DEPTH:
                    inner = _records(found[1], d, depth + 1, scripts, fields)[0]
                out.append((d, t, "direct\x1d" + kept, rest, assigns, field, depth))
                out.extend(inner)
                continue
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
                inner, _ = _records(found_script[1], d, depth + 1, scripts, fields)
                if not inner:
                    del scripts[at]
        if string is not None:
            if depth >= MAX_DEPTH:
                why = why or WHY_DEEP
            else:
                inner, inner_crude = _records(string, d, depth + 1, scripts, fields)
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
    for d, t, wrap, _, _, _, depth in _records(s, cwd, 0, scripts, fields=False)[0]:
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


# ---- the flattened form the push hooks read (claude-config#3470) --------------------------------
# lib/push-scope.sh's segmented mode hands a hook the command with each line break written as "; ".
# It did that to a line break a backslash joins to the next line as well, so the backslash escaped
# the ; and the two lines were read as one command with a ; among its words: `echo ok &&`, a
# backslash, a line break and `git push` ran the push in bash and zsh and was no push to any hook
# reading that form, and neither was `git`, the same two characters and `push`. Measured
# 2026-11-25 against bash 3.2.57 through check-style-guide.sh and check-add-scope.sh.
FLAT_BREAK = "; "


def _named(text):
    """What a reading of a flattened text names, for flattened(): a count of (directory, program)
    for each command and of (directory, tool, subcommand) and (directory, tool, subcommand, action)
    for each git, gh or rtk command, or None where the text can only be read by the crude cut. A
    word that ends in a ; is what an unjoined backslash left behind, never a program's or a
    subcommand's name, so it names nothing."""
    records, crude = _records(text, "", 0)
    if crude:
        return None
    named = {}
    for d, _, _, rest, _, field, _ in records:
        word = first_word(rest)[0]
        keys = [(d, word)] if word and not word.endswith(";") else []
        tool, sub, act = (field.split("\x1d") + ["", ""])[:3] if field else ("", "", "")
        if sub and not sub.endswith(";"):
            keys.append((d, tool, sub))
            if act and not act.endswith(";"):
                keys.append((d, tool, sub, act))
        for key in keys:
            named[key] = named.get(key, 0) + 1
    return named


def _named_more(a, b):
    """The names counted more times in a than in b (_named), each with how many more. A plain
    dict and not collections.Counter: this file is loaded by the gate whose judgements
    lib/judgement-cache.py keeps, which lists every module the gate's libraries import, and a
    count of names is no reason to add one to that list."""
    return {k: n - b.get(k, 0) for k, n in a.items() if n > b.get(k, 0)}


def flattened(s):
    """s as the push hooks read it: each backslash and line break the shell removes taken out
    first, as the shell does before it reads words, then each line break left written as "; ".

    Which pairs the shell removes is commands()'s reading of the text as typed (its `joined`): one
    inside single quotes, in a comment or in the text of a heredoc's body stays, written as it
    always was (one inside single quotes or backquotes is read again below, as the shell that
    reads them does). Where that reading cannot be vouched for (it cannot read the text to its end, or
    names a line it is unsure of) nothing is joined and the text is flattened as it always was.
    An operator a backslash and a line break split is named in `unsure` too and is no such doubt:
    the joined text holds it whole, so the text is joined as it was before those were named
    (split_operator, claude-config#3504).

    No hook may be handed fewer commands than before, so the joined text is given only where it
    names every command the plain flattening names, in the same directory (_named). The plain
    flattening names some the shell never runs: `sudo -u`, the two characters and `git push` gives
    the push to sudo as the user's name, and read unjoined it was a push. Where the joined text
    would lose one of those and name nothing new, the plain flattening is given, and where it
    would lose one and name another, both are given, the joined text first, so a hook reads every
    command either holds.

    WHAT THAT TEXT STILL HID IS ADDED AFTER IT, AND NOTHING IS TAKEN AWAY (claude-config#3739).
    The text so far is every command a hook was handed before, and it is handed over whole,
    whatever else is found. Two more readings of the command as typed may stand beside it
    (before it, so that nothing follows the old text for its end to take as its own, _added):
      * after a heredoc's opener, on its line. Written as "; " the line break that starts a
        body cannot be told from a ; after the opener: `cat <<EOF; git push`, the body and its
        closing line ran the push in bash and zsh, and the push was the body's first line to
        every hook reading this form. So each body is moved up to follow the command that opens
        it (opener_lines);
      * in a string a wrapper hands a shell, and inside backquotes, which are read by a shell
        of their own: `bash -c 'git`, the pair and `push'` ran the push, and so did the same
        inside backquotes. So those are written as that shell reads them (inner_typed).
    The rewritten text is never given in place of the text so far, only beside it (_added), and
    only where the two together are read as exactly the commands of each. A count of names
    cannot decide that the rewritten text may stand alone: a second command of the same name
    keeps the count level while the rewrite hides the first.
    """
    plain = s.replace("\n", FLAT_BREAK)
    typed, flat = _pairs_joined(s, plain) if "\\\n" in s else (s, plain)
    for other in _reread(typed):
        both = _added(flat, other.replace("\n", FLAT_BREAK))
        if both is not None:
            return both
    return flat


def _reread(typed):
    """The command as typed written as the shells that read it read it (claude-config#3739), for
    flattened() to add after the text a hook always had: with its opener lines rewritten and its
    wrappers' strings and backquotes read as their shell reads them, and then with the opener
    lines alone, for where the first cannot be added. Nothing where neither changes the text."""
    out = []
    moved = opener_lines(typed) if "<<" in typed else None
    base = typed if moved is None else moved
    if ("\\\n" in base or "<<" in base) and ("'" in base or "`" in base):
        inner = inner_typed(base)
        if inner is not None:
            out.append(inner)
    if moved is not None:
        out.append(moved)
    return out


def _held(text):
    """(records, crude) for a flattened text: a count of every command its reading gives a hook,
    a wrapper's commands with it, each as (directory, text, wrapper, depth), and whether the text
    could only be read by the crude cut. Every field read mode prints is made from those four.
    The blanks in front of a command's text say where it stood, not what it is."""
    records, crude = _records(text, "", 0, fields=False)
    held = {}
    for d, t, wrap, _, _, _, depth in records:
        key = (d, t.lstrip(), wrap, depth)
        held[key] = held.get(key, 0) + 1
    return held, crude


# ps_has_override's pattern (lib/push-scope.sh) for any name: a NAME=1 word that stands a gate
# down wherever it is in the text a hook is handed. grep reads [[:space:]] by the hook's locale,
# so it is asked both as the six ASCII characters and as every space Unicode has.
OVERRIDE_WORDS = (re.compile(r"(?:^|(?<=[ \t\n\r\f\v;&|]))([A-Za-z_][A-Za-z0-9_]*)=1(?=[ \t\n\r\f\v]|\Z)"),
                  re.compile(r"(?:^|(?<=[\s;&|]))([A-Za-z_][A-Za-z0-9_]*)=1(?=\s|\Z)"))


def _added(flat, other):
    """flat, the text a hook was always handed, with other, a rewriting of the same command,
    added to it (claude-config#3739); or None where there is nothing to add or no way to add it.

    The hook gets flat whole or flat and other together, never other in flat's place, so
    whatever a hook refused on in flat it is still handed. The two are given together only
    where the reading of the whole is exactly the commands of each, in the folder each one
    runs in, and the first of these that is so:
      * other, a blank, and flat after it. Nothing is ever written after the old text where
        that can be helped: what ends it can take what follows for its own, a backslash the
        separator and a heredoc still waiting for its body the lines, and the old text then
        reads as it never did. The blank is for other's own last character, which may be
        that backslash;
      * the same with other inside a subshell, which puts back a folder a relative cd in it
        leaves (`cd a; cat <<EOF; cd b; git push`, a body and `ls`: the second copy's `cd a`
        starts from where the first ended);
      * each of those two without the blank, for an other that ends in a NAME=1 word: the
        blank would make a skip word of one a ; follows;
      * flat first, for an other whose end takes the old text for its own.
    And only where the whole holds no NAME=1 word flat lacks: one stands a gate down by being
    anywhere in the text, and a body moved up can leave one that was followed by a ;
    standing where the text ends.

    Nothing is added to a text only the crude cut reads, as nothing was before, nor where
    other holds no command flat lacks."""
    was, crude = _held(flat)
    if crude:
        return None
    if not _named_more(_held(other)[0], was):
        return None
    allowed = [set(p.findall(flat)) for p in OVERRIDE_WORDS]
    spaced = other + " "
    for part, both in ((spaced, spaced + FLAT_BREAK + flat),
                       (spaced, "( " + spaced + FLAT_BREAK + ")" + FLAT_BREAK + flat),
                       (other, other + FLAT_BREAK + flat),
                       (other, "( " + other + FLAT_BREAK + ")" + FLAT_BREAK + flat),
                       (other, flat + FLAT_BREAK + other)):
        if any(set(p.findall(both)) - names for p, names in zip(OVERRIDE_WORDS, allowed)):
            continue
        # What is asked of the whole: flat's commands and the commands of other as it is
        # written here, the blank after its last word and all.
        now = _held(part)[0]
        want = {k: was.get(k, 0) + now.get(k, 0) for k in set(was) | set(now)}
        if _held(both) == (want, False):
            return both
    return None


# What ends a word either side of a join, for _joined_at(), besides a blank: an operator or a
# quote. And a word ps_has_override reads as a skip word, where it stands as that pattern asks.
WORD_END = ";&|()<>'\"`"
SKIP_WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=1")


def _joined_at(text, at, end):
    """text with text[at:end] taken out, a backslash and line break (or, inside backquotes, the
    run commands() names) that the shell reading this part of the command removes.

    Except where that would put a skip word together (claude-config#3739). A hook honours
    NAME=1 wherever it stands in the text it is handed, after a blank or a separator and before
    a blank or the end, and a join made here could assemble one the command as typed never
    held: `bash -c 'true; SKIP_STYLE_`, the pair and `CHECK=1 true'`, beside a push the old text
    names, stood the style gate down. There the pair is not dropped but written after the word,
    which is then followed by a backslash and is no skip word to any hook, while the command
    behind it is still read with an assignment in front."""
    a = at
    while a and not text[a - 1].isspace() and text[a - 1] not in WORD_END:
        a -= 1
    b = end
    while b < len(text) and not text[b].isspace() and text[b] not in WORD_END:
        b += 1
    stands = (a == 0 or text[a - 1].isspace() or text[a - 1] in ";&|") and (b == len(text) or text[b].isspace())
    if stands and SKIP_WORD.fullmatch(text[a:at] + text[end:b]):
        return text[:at] + text[end:b] + text[at:end] + text[b:]
    return text[:at] + text[end:]


def _wrapper_strings(cut, depth=0, out=None):
    """The strings the wrappers among cut, a reading of a command as typed, hand on to be read as
    commands (wrapped), and the strings the wrappers in those hand on in turn."""
    out = set() if out is None else out
    for _, t in cut:
        found = wrapped(command_rest(t)[0])
        if found is None or found[1] is None or found[1] in out or depth >= MAX_DEPTH:
            continue
        out.add(found[1])
        try:
            inner = commands(found[1], typed=True)
        except Unreadable:
            inner = crude_commands(found[1])
        _wrapper_strings(inner, depth + 1, out)
    return out


def inner_typed(s, depth=0):
    """s, the command as typed, with the text another shell reads written as that shell reads it
    (claude-config#3739), or None where that changes nothing:
      * a single quoted string that is the whole of what a wrapper hands on to be read as
        commands (`bash -c`, `eval`, `watch` and the rest of wrapped()), and stands in that
        wrapper's own command (_wrapper_spans), is written as _string_read() writes it. Any
        other single quoted string (an argument of `echo`, a commit message, though it hold
        the very text a wrapper beside it is handed) is read by no shell and is left as typed;
      * inside backquotes, each run of backslashes and line break that joins the next line for
        their shell is taken out (commands()'s `reread`).
    No join puts a skip word together (_joined_at). A text that cannot be read to its end has
    its backquotes rewritten as far as it was read, and the strings of the wrappers the crude
    cut finds."""
    found, parts = [], []
    try:
        cut = commands(s, parts=parts, reread=found, typed=True)
        held = [(p["start"], p["end"], [(x[0], x[1]) for x in p["inner"]], [c]) for c, p in zip(cut, parts)]
    except Unreadable:
        held = _crude_pieces(s)
    spans = _wrapper_spans(held) if any(kind == "'" for kind, _, _ in found) else ()
    text = s
    for kind, at, end in sorted(found, key=lambda e: e[1], reverse=True):
        if kind == "`":
            text = _joined_at(text, at, at + end)
        elif any(start <= at and end <= stop and text[at:end] in strings
                 and not any(a <= at and end <= b for a, b in inner) for start, stop, inner, strings in spans):
            text = text[:at] + _string_read(text[at:end], depth) + text[end:]
    return text if text != s else None


def _crude_pieces(s):
    """The pieces crude_commands() cuts s into, each as (start, end, [], commands): s[start:end]
    is the piece, and commands the piece and the commands that may be written inside it
    (crude_inner). For inner_typed(), which must know where in the text a command stands."""
    held, at = [], 0
    for m in list(CRUDE_CUT.finditer(s)) + [None]:
        end = len(s) if m is None else m.start()
        if s[at:end].strip():
            held.append((at, end, [], [("", s[at:end])] + [("", t) for t in crude_inner(s[at:end])]))
        at = end if m is None else m.end()
    return held


def _wrapper_spans(held):
    """(start, end, inner, strings) for each of held, the commands of a text as typed with where
    each stands, that hands a string on to be read as commands: strings is what it and the
    wrappers inside that string hand on (_wrapper_strings), and inner the stretches of
    s[start:end] that are substitutions, whose commands are among held themselves. A single
    quoted string is a wrapper's only where it stands in that wrapper's own command: the same
    text as an argument of `echo` beside it is read by no shell."""
    spans = []
    for start, end, inner, cut in held:
        strings = _wrapper_strings(cut)
        if strings:
            spans.append((start, end, inner, strings))
    return spans


def _string_read(s, depth):
    """s, a string a wrapper hands on to be read as commands, written so that its flattened form
    is read as the shell reading s reads it (claude-config#3739). Each backslash and line break
    that shell removes is taken out, and only those: which they are is that string's own reading
    (_joins), as it is for the text around it, so one that ends a comment or stands in a quoted
    heredoc's body stays. Taken out of there it made the next line part of the comment or of
    the body, and hid a command both shells run. Then the string's opener lines are rewritten
    (opener_lines), and its own backquotes and wrappers' strings (inner_typed)."""
    text = s
    if "\\\n" in text:
        for i in reversed(_joins(text)):
            text = _joined_at(text, i, i + 2)
    if "<<" in text:
        text = opener_lines(text) or text
    if depth < MAX_DEPTH and ("\\\n" in text or "<<" in text) and ("'" in text or "`" in text):
        text = inner_typed(text, depth + 1) or text
    return text


def _joins(s):
    """Where s, a command as typed, holds a backslash and line break the shell reading it removes
    (commands()'s `joined`), in order; nothing where that reading cannot be vouched for: it
    cannot read the text to its end, or names a line it is unsure of."""
    joined, unsure = [], []
    try:
        commands(s, unsure=unsure, joined=joined)
    except Unreadable:
        return []
    # An operator a backslash and a line break split is named in unsure, and is no doubt here: the
    # joined text holds it whole, as bash reads it, and _pairs_joined's checks keep every command
    # the plain flattening names beside it. Flattened plain, a `$`, the pair and `(git push)` is a
    # `$`, an escaped `;` and a parenthesis, which names no push (claude-config#3504).
    if [m for m in unsure if not split_operator(s, m[0])]:
        return []
    return sorted(set(joined))


def _pairs_joined(s, plain):
    """(typed, flat) for a text holding a backslash and a line break (claude-config#3470): flat is
    what flattened() gave before it read a heredoc's opener line, and typed is the text as typed
    that flat is the flattening of, s itself or s with each pair the shell removes taken out."""
    joined = _joins(s)
    if not joined:
        return s, plain
    kept, at = [], 0
    for i in joined:
        kept.append(s[at:i])
        at = i + 2
    kept.append(s[at:])
    typed = "".join(kept)
    joint = typed.replace("\n", FLAT_BREAK)
    was, now = _named(plain), _named(joint)
    if was is None or now is None:
        return s, plain
    if not _named_more(was, now):
        return typed, joint
    if not _named_more(now, was):
        return s, plain
    both = joint + FLAT_BREAK + plain
    held = _named(both)
    either = {k: max(was.get(k, 0), now.get(k, 0)) for k in set(was) | set(now)}
    return (typed, both) if held is not None and not _named_more(either, held) else (s, plain)


# How many times opener_lines() reads one text again before it stops with what it has rewritten.
# One reading settles the first separator after an opener on every line that has one, so the
# count that matters is how many such separators one line holds, or how deep one such line sits
# inside another's body, never how many such lines there are.
OPENER_LINE_LIMIT = 64


def opener_lines(s):
    """s, the command as typed, written so that its flattened form is read as the shell reads s
    (claude-config#3739), or None where there is nothing to rewrite.

    The shell runs every command on the line that opens a heredoc and reads the body from the next
    line. These rewrites, the first on each such line at every reading until none is left:
      * a "; " between two commands after an opener, on a line whose heredocs all close: the
        bodies of the heredocs opened before it, closing lines and all, are moved up to follow the
        command that opens them, and what stood after the "; " follows on a line of its own. A
        ; and a line break separate two commands alike, so `cat <<EOF; git push`, the body and
        EOF is `cat <<EOF`, the body, EOF and then `git push`: the shape the flattened form has
        always been read right in;
      * a heredoc still waiting for its body where the text ends (a command of one line, or an
        opener on the last line): no shell gives it one, and every command after it on the line
        runs (bash 3.2 and zsh, measured 2026-11-23 and 2026-11-26), where the flattened form
        took those commands for the body up to a word that is the marker. Its << or <<- is
        written <<<, a here string of the marker word, which opens nothing;
      * a line one of whose heredocs never closes on a line of its own: the shell feeds it the
        rest of the text and runs every command on the line, where the flattened form closed it
        at a marker word standing on that same line (`cat <<EOF; git push; EOF` and a line
        break, which is that command with nothing after it), and hid the commands between.
        Each << on the line is written <<< as above, so the rest of the text is read as
        commands, which is only more than the shell runs.
    A text that cannot be read to its end has its bodies moved as far as
    it was read, since the shell runs each line as it reads it, and no here string written, since
    the line the text ends on is one the shell never finishes reading; flattened() gives the
    result to a hook only beside the text it always had. A text still not settled after
    OPENER_LINE_LIMIT readings is given as far as it was rewritten.
    """
    text = s
    for _ in range(OPENER_LINE_LIMIT):
        met = []
        try:
            commands(text, lines=met, typed=True)
        except Unreadable:
            pass
        # One rewrite for each line: its first "after" and what the line ends in. Each is a
        # stretch of the text of its own, so all are made from one reading, last first; one that
        # starts inside a stretch already taken (a line read out of a body) waits for the next.
        edits, floor, k = [], 0, 0
        while k < len(met):
            kind, i, n = met[k]
            k += 1
            if kind != "after":
                continue
            while k < len(met) and met[k][0] == "after":
                k += 1
            if k == len(met):
                break
            ends = met[k]
            k += 1
            if ends[0] in ("end", "open"):
                group = [(at, at + (3 if text.startswith("<<-", at) else 2), "<<<") for at in sorted(ends[2])]
            else:
                start, end = ends[2][0][0], ends[2][n - 1][1]
                group = [(i, end, text[start:end] + "\n" + text[i + len(FLAT_BREAK):start])]
            if group and group[0][0] >= floor:
                edits.extend(group)
                floor = group[-1][1]
        if not edits:
            break
        for at, end, new in reversed(edits):
            text = text[:at] + new + text[end:]
    return text if text != s else None


def flattened_payload(text):
    """The command of a hook payload (the JSON Claude Code sends) as flattened() gives it, then
    0x1f and the payload's cwd, the shape lib/push-scope.sh's ps_parse_payload prints; or None
    where flattened() gives the command with each line break written as "; " and nothing else
    done, or the payload is not one this reads, so the caller flattens it as it always has, byte
    for byte. A 0x1f in the command is written as U+FFFD, as there (claude-config#2055)."""
    try:
        d = json.loads(text)
    except ValueError:
        return None
    if not isinstance(d, dict):
        return None
    ti, cwd = d.get("tool_input"), d.get("cwd")
    cmd = ti.get("command") if isinstance(ti, dict) else None
    if not isinstance(cmd, str) or not (cwd is None or cwd is False or isinstance(cwd, str)):
        return None
    if "\\\n" not in cmd and "<<" not in cmd:
        return None
    flat = flattened(cmd)
    if flat == cmd.replace("\n", FLAT_BREAK):
        return None
    return flat.replace("\x1f", "\ufffd") + "\x1f" + (cwd or "")


# A script whose arguments are data (claude-config#1574). `bash ./x.sh` cannot be read, since its
# commands are in the file, so check-wrapped-commands.sh refuses it beside any word git, gh or rtk,
# quoted argument text included. A few scripts, or subcommands of them, are known to run none of
# their arguments (issue-spool.sh's note hands each to python as a string; milestone-candidates.sh,
# #1610, only reads from GitHub), and the guard declares them; for one of them the words inside its
# arguments are data. data_blanked() reads that one shape and nothing else: the call, with only
# DATA_TOKEN_PREFIX in front and only 2>&1 and pipes into DATA_FILTERS behind, printed with every
# argument after the path (or subcommand) that is quoted whole replaced by '', so data_set_aside can
# look for git, gh and rtk in what is left of each pipeline of a command; None for any other shape,
# a pipeline that is then not set aside (claude-config#1492). Anything a shell would do more than split words and remove quotes ends the reading with
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


def data_set_aside(s, declared, home, guarded):
    """s with every declared data call in it set aside (claude-config#1492), or None when it holds
    none. A declared call is a pipeline of the command itself, never inside a subshell, a
    substitution or a wrapper's string, that data_blanked reads in full (the call, only
    DATA_TOKEN_PREFIX in front, only 2>&1 and pipes into DATA_FILTERS behind) and whose blanked
    text names none of git, gh and rtk, by guarded, the guard's own test of that (its GUARDED_TEXT,
    handed in so the two can never disagree). Each is replaced by `:`, which runs nothing, so the guard can
    judge the rest of the command exactly as if the call were not there: a push, merge or issue
    command beside it is read by the gates as usual, and an unread wrapper beside it is refused as
    before. Pipelines are cut where the shell cuts them, at ;, &&, ||, & and a line break, so a
    declared call piped into anything but a filter is never one. None too when s cannot be read, or
    names BASH_ENV anywhere, since bash runs the file that names before any script it is given."""
    if "BASH_ENV" in s:
        return None
    parts = []
    try:
        commands(s, "", parts=parts)
    except Unreadable:
        return None
    top = [p for p in parts if p["scope"] == (0,)]
    spans, k = [], 0
    while k < len(top):
        j = k
        while top[j]["how"] == "|" and j + 1 < len(top):
            j += 1
        spans.append((top[k]["start"], top[j]["end"], top[j]["how"]))
        k = j + 1
    out, at, found = [], 0, False
    for start, end, how in spans:
        # A pipeline that ends in a pipe has nothing after it to read, so it is no declared call.
        if how == "|":
            continue
        shown = data_blanked(s[start:end], declared, home)
        if shown is None or guarded.search(shown):
            continue
        out.append(s[at:start])
        out.append(" : ")
        at, found = end, True
    if not found:
        return None
    out.append(s[at:])
    return "".join(out)


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
    elif mode == "data-set-aside":
        # stdin is the command; each argument after the mode is one declared "<path>" or "<path>
        # <subcommand>" entry. Exit 1, printing nothing, when no declared call stands in it in its
        # declared shape (claude-config#1574, #1610, #1492). The test that text names git, gh or rtk
        # is the guard's, in DATA_GUARDED_RE; without one that compiles nothing is set aside.
        try:
            guarded = re.compile(os.environ["DATA_GUARDED_RE"])
        except (KeyError, re.error):
            return 1
        rest = data_set_aside(data, argv[2:], os.environ.get("HOME", ""), guarded)
        if rest is None:
            return 1
        sys.stdout.write(rest)
    elif mode == "read":
        text, rc = read(data)
        sys.stdout.write(text)
        return rc
    elif mode == "flatten":
        # Exit 4, printing nothing, where there is nothing to join or move, so ps_parse_payload
        # goes on to the readers it always had. Written once, whole, as UTF-8 whatever the locale, as they write.
        flat = flattened_payload(data)
        if flat is None:
            return 4
        # This is the one mode that decodes JSON, and an escape in a payload can make a character
        # no encoding writes. Its bytes are made with "replace" just below, and stdout is told the
        # same, so nothing a later edit prints here by its text can raise on one
        # (test-python-bad-bytes.sh). No other mode's stdout is touched: this runs only here.
        sys.stdout.reconfigure(errors="replace")
        sys.stdout.flush()
        sys.stdout.buffer.write(flat.encode("utf-8", "replace"))
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
        # (claude-config#2080). The marker is everything after the first tab, so one that holds a
        # tab (`$'E\tF'`) is whole. One that holds a line break (`$'E\nF'`) is given no row: no
        # line of a body can be it, a row for it would be cut in two, and with no row such a scan
        # reads the lines after it as code, never as a body with no end (claude-config#3566).
        # Nor is one whose line ends in a backslash before the end of its marker, which
        # heredoc_openers leaves out: the marker is the word the two lines make, and the row was
        # the word on the first with a backslash after it, a line no body holds (#3504).
        for n, line in enumerate(data.split("\n"), 1):
            for op in heredoc_openers(line):
                if "\n" not in op[1]:
                    sys.stdout.write("%d\t%s\n" % (n, op[1]))
    elif mode == "split":
        if data.endswith("\n"):
            data = data[:-1]
        assigns, rest = split(data)
        sys.stdout.write("".join(a + "\n" for a in assigns) + "\x1f\n" + rest)
    else:
        sys.stderr.write("usage: shell-words.py read|commands|split|words|gitdir|bare|tool|heredoc-markers < text, flatten < payload, or data-set-aside '<path>[ <subcommand>]'... < text\n")
        return 64
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
