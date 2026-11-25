"""The lines of a shell file that are its code, for the whole tree scans of suites (claude-config#1663).

Four scans read shell files: hand-rolled-wait.py (#1679), hand-rolled-checkout.py (#1663) and
heredoc-in-substitution.py (#1690) for a hand rolled or fragile shape, and scan-subshell-globals.py
for where each function begins and ends (#2063). Each has to tell the file's own code from the text
it carries as data: a multi line quoted string is another hook's input written as a fixture, and a
comment is prose about the shape, often the very prose explaining why it is banned. One reader, so
the four cannot come to disagree about which lines are code (L613).

Enough of the shell's quoting is followed to do that: single, double and $'...' quotes, a `$( ... )`
opening a fresh quoting context even inside double quotes, a plain `( ... )` inside one, a comment,
and a heredoc. Not a parser: a `case` pattern's `)` inside a substitution, for one, is read as
closing it.

code_lines(text) yields (line_number, line) for every line that is neither a comment nor begins
inside a quoted string. A line inside a multi line `$( ... )` is code and is yielded. A heredoc's
body is yielded too, since a stand in a suite writes through one is shell, but its quotes are not
followed, so an apostrophe in a heredoc's prose cannot carry a quote past the heredoc's end.

A line is read with the line a backslash joined it to (claude-config#3475). The shell takes a
backslash newline out before it reads words, so `echo a\\` then `#b; echo RAN` is the one line
`echo a#b; echo RAN`: the # is text and the rest of its line runs. Read a line at a time, every #
that starts a line was a comment, the line was dropped, and a quote or a heredoc opened after the #
was never followed. A backslash joins only where it is live: one that ends a comment, or a
heredoc's closing line, joins nothing (#3481). An unquoted heredoc's body is joined the same way
before a line is compared with the marker (#3492); _closes and _read say what is done where a
marker joined to the line before leaves the heredoc open in every shell. Where the reader cannot
tell code from text it reads code: a scan that looks at a line no shell runs costs a second look,
and one that skips a line a shell runs has missed what it was written to find.

unsure_heredocs(text) names each heredoc whose reading the reader cannot vouch for, by the line it
opens on (#3592): an opener joined to the next line before the end of its marker, a heredoc the
shells do not end at the same line, and a marker joined to the line before with none after it. After
one, code_lines leaves out no line. The shapes, and what seven shells do with each, are
lib/heredoc-closes.json, which test-shell-code-lines.sh runs against the shells and this reader;
the same suite fails when a shell file of the repository holds a named heredoc, which is the one
refusal for every scan that reads through here.

code_lines(text, with_heredocs=True) adds a third item: the heredoc operators the line opens as
code, each (strip_tabs, word, inside_substitution), so heredoc-in-substitution.py reads the same
quoting as the rest. heredoc_body_lines(text) names the lines that are a heredoc's body, from the
same walk, so hand-rolled-wait.py can tell a stand in's own commands from the suite's (#1743).

read_lines(text) is the walk both of those are built on, and yields every line rather than only the
code ones: its kind (code, quoted, heredoc body or heredoc end) and its bare code characters, with
quoted text, comments and escapes left out. scan-subshell-globals.py counts a function's braces on
the bare characters with brace_depth, so a brace inside a string, a heredoc or a bracket expression
never ends a function (#2063, #2068). It reads the assignments in a body through lib/shell-words.py
instead, which reads the body whole (#2076), so the text of each line that is this shell's own,
which #2068 added for it, has no reader and is gone (L613).
"""
import importlib.util
import os
import re
import sys

# The end marker of a heredoc is read by lib/shell-words.py (heredoc_opener), the one reading of it,
# which takes the whole word with its quotes removed as bash does: <<'E'OF and <<E"OF" end at EOF,
# <<END-OF at END-OF (claude-config#2080). Loaded by its path beside this file, with no bytecode left
# in lib/ (#2076). READER_ERROR is None once it loads; otherwise scan() refuses, naming it, since
# this keeps no reading of its own to fall back on and one that misread a marker would read every
# line after a heredoc as its body. Importing still works, so a scan can say which reader is missing.
READER_ERROR = None
try:
    _dont_write = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        _spec = importlib.util.spec_from_file_location(
            "shell_words", os.path.join(os.path.dirname(os.path.abspath(__file__)), "shell-words.py"))
        _sw = importlib.util.module_from_spec(_spec)
        _spec.loader.exec_module(_sw)
        heredoc_opener, heredoc_openers = _sw.heredoc_opener, _sw.heredoc_openers
    finally:
        sys.dont_write_bytecode = _dont_write
except Exception as e:  # noqa: BLE001  missing, or failing to load: either way there is no reader
    READER_ERROR = "%s: %s" % (type(e).__name__, e)


class ReaderMissing(RuntimeError):
    """lib/shell-words.py could not be loaded, so no heredoc's end marker can be read."""

# A bracket expression in a pattern, a case label's `[A-Za-z_{]` or a regex's `[{]`: a `[` with no
# space after it, closed by a `]` before any space. A test command's `[ ` and `[[ ` never match.
BRACKET = re.compile(r"\[[^\]\s]+\]")


# What a # must follow, outside every quote, to start a comment (claude-config#3464).
COMMENT_AFTER = ' \t;('


# Why a heredoc is named as one the reader is not sure of (unsure_heredocs).
OPENER_JOINED = ("its opener is joined to the next line by a backslash before the end of its marker, so the "
                 "marker is not the word on that line; no heredoc is read there and the lines after are read as code")
SHELLS_DIFFER = ("the shells do not end it at the same line: a backslash ends the line before its closing line, "
                 "and bash and zsh join the two where dash or ksh do not, or the reverse")
NEVER_ENDS = ("its marker is joined by a backslash to the line before and no line after is the marker, so no shell "
              "ends it; the reader ends it there and reads the rest as code")


def _opener_joined(line, i, after):
    """Whether the << at line[i] is joined to the next line between it and the end of its marker
    word (claude-config#3592): `cat <<E`, a backslash, then `x` waits for the line Ex in every
    shell, and `cat <<`, a backslash, then `E` for the line E. Asked of lib/shell-words.py, which
    reads an opener across a join where it is handed a list for the joins; a word that does not
    start as a marker is written opens nothing, as on one line (`$((1<<`, a backslash, `2))`)."""
    text = line + "\n" + after
    j = i + 2 + (text.startswith("-", i + 2))
    while text.startswith("\\\n", j) or text[j:j + 1] in (" ", "\t"):
        j += 2 if text[j] == "\\" else 1
    if not _sw.MARKER_START.match(text, j):
        return False
    found = []
    return heredoc_opener(text, i, joins=found) is not None and bool(found)


def scan(line, frames, keep=None, parens=None, before="", told=None, after=None):
    """Follows the quoting of one line. `frames` is the stack of quoting contexts the line starts in
    (the outermost first; each a quote state: None, "'", "$'" or '"'), and is updated in place.
    Returns the heredoc operators the line opens as code: (strip_tabs, word, inside_substitution).
    Given a list as `keep`, appends to it every character of the line read as code, so quoted text,
    a comment and an escaped character are left out (claude-config#2063).

    `parens`, one count per frame, is how many plain `(` are open in each, a subshell, an array or
    an arithmetic group, so its `)` closes it rather than the `$(` around it. Without it the `)` of
    a `(set -f; ...)` inside a multi line `$( { ... } )` closed the substitution, and everything
    after was read as inside the double quotes around it (claude-config#2063). Kept across lines by
    the caller that passes it; without one it is counted within the line alone.

    `before` is the text a live backslash at the end of the line before joined this line onto, or
    "" where nothing did. The shell takes a backslash newline out before it reads words, so a #
    that starts this line starts a comment only where a word starts at the end of `before`
    (claude-config#3475). Given a dict as `told`, sets in it "joins", whether this line ends in a
    live backslash itself, "worded", whether a # at its start was read as text for that reason, and
    "quoted", for each heredoc operator returned, whether any of its marker was quoted, and
    "joined_opener", whether a heredoc's opener on this line is joined to the next between its <<
    and the end of its marker. That is only asked where `after`, the text of the next line, is
    given: no heredoc is returned for such an opener, and the rest of the line is not read."""
    if READER_ERROR is not None:
        raise ReaderMissing("lib/shell-words.py could not be loaded (%s), so no heredoc's end marker "
                            "can be read" % READER_ERROR)
    if parens is None:
        parens = [0] * len(frames)
    ops = []
    quoted = []
    joins = worded = joined_opener = False
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        st = frames[-1]
        if st is None:
            # A comment, only where a word starts: after an escaped space, ; or ( the # is inside a
            # word, and a quote opening after it on the line is open on the lines that follow. The
            # rule is lib/shell-words.py's, the one the command reader asks (claude-config#3464).
            # At the start of a joined line the word is asked of the line it was joined onto.
            if c == '#':
                if i == 0 and before:
                    worded = not _sw.word_starts(before + line, len(before), COMMENT_AFTER)
                    if not worded:
                        break
                elif _sw.word_starts(line, i, COMMENT_AFTER):
                    break
            if c == '\\':
                # Live only here and inside double quotes. The walk never reaches a backslash that
                # ends a comment, having stopped at its #, and that one joins nothing in any shell
                # (claude-config#3481).
                joins = i == n - 1
                i += 2
                continue
            if c == '<' and line.startswith('<<', i) and not line.startswith('<<<', i) and (i == 0 or line[i - 1] != '<'):
                if after is not None and line.endswith('\\') and _opener_joined(line, i, after):
                    joined_opener = joins = True
                    break
                # marker_start, since this walk follows no arithmetic: `$((1<<2))` opens nothing.
                op = heredoc_opener(line, i, marker_start=True)
                if op:
                    marker, strip, was_quoted, end = op
                    ops.append((strip, marker, len(frames) > 1))
                    quoted.append(was_quoted)
                    i = end
                    continue
            if c == '$' and line.startswith('$(', i) and not line.startswith('$((', i):
                frames.append(None)
                parens.append(0)
                i += 2
                continue
            if keep is not None and c not in "'\"":
                keep.append(c)
            if c == '(':
                parens[-1] += 1
            elif c == ')' and parens[-1] > 0:
                parens[-1] -= 1
            elif c == ')' and len(frames) > 1:
                frames.pop()
                parens.pop()
            elif c == "'":
                frames[-1] = "$'" if i > 0 and line[i - 1] == '$' else "'"
            elif c == '"':
                frames[-1] = '"'
        elif st == "'":
            if c == "'":
                frames[-1] = None
        else:
            if c == '\\':
                joins = st == '"' and i == n - 1
                i += 2
                continue
            if st == '"' and line.startswith('$(', i) and not line.startswith('$((', i):
                frames.append(None)
                parens.append(0)
                i += 2
                continue
            if (st == "$'" and c == "'") or (st == '"' and c == '"'):
                frames[-1] = None
        i += 1
    if told is not None:
        told.update(joins=joins, worded=worded, quoted=quoted, joined_opener=joined_opener)
    return ops


def _closes(joined, line, strip, word, quoted):
    """One line of a heredoc's body, read as bash and zsh read it: (whether it closes the heredoc,
    the text it carries on to the next line, whether it is joined to the next line). `joined` is
    what the lines before carried on.

    An unquoted heredoc's body line that ends in an odd count of backslashes is joined to the next
    BEFORE anything is compared with the marker (claude-config#3492; bash 3.2, zsh, sh and dash,
    measured 2026-11-23 with texts that only echo and cat). So `a\\` then the marker is the one
    line aMARKER and closes nothing, a line that is only a backslash then the marker closes, and so
    does a marker split over two joined lines. A quoted marker's body is text as written and joins
    nothing. With <<- the tabs come off the front of the joined line: bash closes at a tab and a
    backslash followed by a tab and the marker where zsh does not, and this reads it as bash does,
    since the lines after are then read as code."""
    whole = joined + line
    if (whole.lstrip('\t') if strip else whole) == word:
        return True, "", False
    if not quoted and (len(line) - len(line.rstrip('\\'))) % 2:
        return False, whole[:-1], True
    return False, "", False


def _ends_later(lines, start, strip, word):
    """Whether an unquoted heredoc still open at lines[start] is closed by any line from there on."""
    joined = ""
    for k in range(start, len(lines)):
        closes, joined, _ = _closes(joined, lines[k], strip, word, False)
        if closes:
            return True
    return False


def _read(text, marks=None):
    """read_lines, with two more items a line: whether a # that starts it is text, joined onto a
    word by the line before, and whether it stands after a heredoc the reader is not sure of.

    Given a list as `marks`, appends (line number, why) for each such heredoc, by the line it opens
    on (claude-config#3592). Three kinds, each a row of lib/heredoc-closes.json, measured
    2026-11-25 in bash 3.2, bash --posix, sh, dash, zsh, zsh emulating sh and ksh:
      * an opener joined to the next line before the end of its marker (OPENER_JOINED);
      * a heredoc the shells do not end alike (SHELLS_DIFFER): it closes at a line a backslash
        joined to the line before, which bash and zsh compare whole where dash or ksh do not (a
        line that is only a backslash and then the marker, a marker split over two lines, a marker
        and a backslash before an empty line), or its marker stands right after a line that starts
        as the marker does and ends in backslashes, where ksh keeps the first of those backslashes
        as text and so joins where the others do not and the reverse. It is read as bash reads it;
      * a marker joined to the line before with no marker after it (NEVER_ENDS, #3492).
    A heredoc the reader ends where every shell does is not named, however many of its lines a
    backslash joins. After a named one `rest` is true and code_lines leaves out nothing."""
    frames = [None]
    parens = [0]
    pending = []  # heredocs opened and not yet read: (strip_tabs, word, quoted, the line it opens on)
    joined = ""   # what a heredoc's body lines have carried on to this one
    carrying = False  # whether the body line before this one is joined to it
    last = ""     # the body line before this one, of the same heredoc
    before = ""   # the text a live backslash joined this line of code onto
    rest = False
    named = set()

    def name(opened, why):
        if marks is not None and opened not in named:
            marks.append((opened, why))
        named.add(opened)

    lines = text.split('\n')
    for i, line in enumerate(lines):
        if pending:
            strip, word, quoted, opened = pending[0]
            alone = (line.lstrip('\t') if strip else line) == word
            closes, carried, carries = _closes(joined, line, strip, word, quoted)
            if not quoted:
                core = (last.lstrip('\t') if strip else last).rstrip('\\')
                if (closes and carrying) or (alone and last.endswith('\\') and core and word.startswith(core)):
                    name(opened, SHELLS_DIFFER)
                    rest = True
            if (not closes and carrying and alone
                    and not _ends_later(lines, i + 1, strip, word)):
                # The marker, joined to the body line before it, and no line after that closes the
                # heredoc. Every shell reads the rest of the file as its body, where a substitution
                # runs wherever it stands, in a comment or a quoted string too. But whoever wrote
                # the marker there meant it to close, and bash 3.2 does end a heredoc inside a
                # `$( )` at the closing parenthesis and runs what follows as code. The reader cannot
                # tell which the rest is, so it takes both safe sides (claude-config#3492): it
                # closes here, so the rest is read as code, its functions and heredocs found; and
                # code_lines drops none of the rest, since any of it may hold a substitution that
                # runs. Read as body instead, the rest would stop being code for every scan that
                # asks for code, on the strength of one stray backslash.
                closes, carried, carries, rest = True, "", False, True
                name(opened, NEVER_ENDS)
            joined, carrying, last = carried, carries, line
            before = ""
            if closes:
                pending.pop(0)
                joined, carrying, last = "", False, ""
            yield (i + 1, line, "end" if closes else "heredoc", "", [], False, rest)
            continue
        starts_quoted = frames[-1] is not None
        keep, told = [], {}
        ops = scan(line, frames, keep, parens, before, told, lines[i + 1] if i + 1 < len(lines) else "")
        if told["joined_opener"]:
            name(i + 1, OPENER_JOINED)
            rest = True
        # What the next line is joined onto. Only the last character and the backslashes before it
        # are ever asked about, and a line gives up its joining backslash from an odd run, so the
        # nearest line that left any text is enough.
        before = (line[:-1] or before) if told["joins"] else ""
        pending.extend((s, w, q, i + 1) for (s, w, _), q in zip(ops, told["quoted"]))
        yield (i + 1, line, "quoted" if starts_quoted else "code", "".join(keep), ops,
               told["worded"], rest)


def read_lines(text):
    """Every line of the file, in one walk, as (line_number, line, kind, bare, heredoc operators it
    opens). kind is "heredoc" for a heredoc's body, "end" for the word closing one, "quoted" for
    a line that begins inside a quoted string, and "code" for any other. bare is the line's code
    alone: its quoted text, comment and escaped characters left out, and nothing at all of a
    heredoc's body or end. So a brace in bare is the shell's own, never one in a string the file
    carries as data (claude-config#2063, where one inside a python3 -c string ended a function at the
    end of the file)."""
    for row in _read(text):
        yield row[:5]


def unsure_heredocs(text):
    """Each heredoc the reader cannot vouch for its reading of, as (the line it opens on, why), in
    the order found (claude-config#3592): see _read. For a scan, or a check over every file the
    scans read, to refuse on: after such a heredoc the reader reads code and leaves out no line,
    which is more than some shell runs, and the lines of its body are read as one shell reads them."""
    marks = []
    for _ in _read(text, marks):
        pass
    return marks


def brace_depth(bare):
    """How far a line's bare code opens (positive) or closes (negative) the shell's brace groups.
    A brace inside a bracket expression is a character a pattern matches, so it is not counted: the
    `{` in mt_is_interpreter's case label `'$'[A-Za-z_{]*)` in lib/merge-target.sh left that
    function open for the rest of the file, 1890 lines, and no function below it was ever found
    (claude-config#2068). A parameter expansion's braces always pair, so they cancel."""
    bare = BRACKET.sub("", bare)
    return bare.count("{") - bare.count("}")


def _walk(text):
    """Every code line as (line_number, line, heredoc operators it opens, whether it is a heredoc's
    body): the one walk code_lines and heredoc_body_lines both read.

    A line that starts with # is a comment unless the line before joined that # onto a word
    (claude-config#3475). After a heredoc no shell closes nothing is left out but a closing word:
    see _read."""
    for n, line, kind, _, ops, worded, rest in _read(text):
        if kind == "end":
            continue
        if not rest and (kind == "quoted" or (line.lstrip().startswith('#') and not worded)):
            continue
        yield (n, line, ops, kind == "heredoc")


def code_lines(text, with_heredocs=False):
    for n, line, ops, _ in _walk(text):
        yield (n, line, ops) if with_heredocs else (n, line)


def heredoc_body_lines(text):
    """The numbers of the code lines that are a heredoc's body: a stand in the file writes, whose
    commands are the stand in's own rather than the file's (claude-config#1743)."""
    return {n for n, _, _, body in _walk(text) if body}
