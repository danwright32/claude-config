#!/usr/bin/env python3
"""unsure-reading.py: the door a gate uses to ask the shared reader which lines it cannot vouch for
(claude-config#3472).

lib/shell-words.py reads a command for every gate. It took a # for a comment by a rule the shell
does not follow, so a command on the rest of that line was left out of what a gate judged
(claude-config#3464). The reader now names the lines it is unsure of, and reads on where every
shell does, but only for a caller that asks: a # it cannot tell from a comment, a heredoc it cannot
find the end of (#3492, #3566) and an operator that a backslash and a line break split (#3504). A
gate that does not ask is given the reading it always was, and misses whatever such a line runs.

THE RULE HAS ONE HOME, lib/db-write-calls.py: its asked_reading() is where a reading becomes "sure,
and this is it" or "not sure, and why", and its UNSURE holds the sentence for each mark. This file
copies neither. asked() below calls that function, so every gate that asks decides by the same
code and says the same words as the database write check, the first gate that asked. That library
is loaded from beside this file and no other part of it is used.

What this file adds is the words for two marks. One that library has no sentence for: an operator
split by a backslash and a line break, which it would call "a line the shared reader is unsure
of". The reader's own split_operator() says whether a mark is one, and SPLIT is the sentence for
it. And one its sentences are untrue of: a # between backquotes that close on its line, the
commonest named line there is (backquotes written as text in a double quoted message). BETWEEN is
the sentence for it, and _between_backquotes() says how it is told. The decision is that
library's for both: only the words change.

    asked(sw, read)  -> (what read() gave, None), or (None, the fault); raises what read() raises
    second(sw, read) -> the same, and never raises: a second reading that cannot be made is a fault
    named(fault)     -> whether the fault is a line the reader named
    told(fault)      -> the fault as one clause for a refusal, with how to write the command

A gate calls its reading twice: first as it always did, and refuses what that finds in the words
it always used, then through second(). So a gate that asks never refuses less than it did: what
the asked reading drops (a command the shell does not run, inside a heredoc that a # read as text
opens) the first reading still finds.
"""
import importlib.util
import os
import sys

# Loading lib/db-write-calls.py by its path must leave no bytecode beside it (claude-config#2600).
sys.dont_write_bytecode = True
_here = os.path.dirname(os.path.abspath(__file__))
_calls = []

# What is said of an operator that a backslash and a line break split, and how to write the command
# so that the reader names nothing there. Each fact is one lib/shell-words.py measured
# (split_operator(), 2026-11-26). The first %s is the operator's two characters, the second the
# line its first character stands in.
SPLIT = ("the command holds an operator that a backslash and a line break split, the %s that starts in "
         "the line %s: bash, sh and dash take the pair out and read the two characters as that one "
         "operator, and zsh and ksh do so in some places and not in others, so the shells do not agree "
         "on what runs there, and it could not be read",
         "Write the operator's two characters together on one line")
# What is said of a # between backquotes, and how to write the command so that the reader names
# nothing there. That library's two sentences for a # say a closing parenthesis or a backslash
# stands before it, and to write it inside quotes, and neither is true of the commonest such line:
# backquotes written as text in a double quoted message, with a # after a space between them. The
# facts here are the reader's own: it reads a comment where a word starts (word_starts()), and
# bash ends backquotes at the next backquote whether or not a comment stands before it
# (test-shell-words-comment-start.sh, measured for claude-config#3464). The %s is the line.
BETWEEN = ("the command holds a # with a backquote before it and another after it on its line, in the line "
           "%s: the shared reader reads a comment from that # to the end of the line, and bash ends "
           "backquotes at the next backquote whether or not a comment stands before it, so what runs after "
           "that backquote could not be read",
           "Where those backquotes are text and run nothing, write a backslash before each of them, or put "
           "the whole text in single quotes with no double quotes around them; where they run a command, put "
           "the comment on a line of its own that holds no backquote")
# How much of the line a sentence shows, as lib/db-write-calls.py's LINE_SHOWN.
LINE_SHOWN = 120


class CannotLoad(Exception):
    """lib/db-write-calls.py, where the rule lives, could not be loaded or holds no asked_reading().
    The words say which, for a gate that then falls back on its own degraded reading."""


class Split(str):
    """The fault for an operator that a backslash and a line break split: SPLIT's sentence, with
    .kind and .fix as lib/db-write-calls.py's Unsure has them."""

    def __new__(cls, operator, line):
        what, fix = SPLIT
        self = str.__new__(cls, what % ("`" + operator + "`", "`" + line + "`"))
        self.kind, self.fix = "split operator", fix
        return self


class Between(str):
    """The fault for a # between backquotes: BETWEEN's sentence, with .kind and .fix as
    lib/db-write-calls.py's Unsure has them."""

    def __new__(cls, line):
        what, fix = BETWEEN
        self = str.__new__(cls, what % ("`" + line + "`"))
        self.kind, self.fix = "backquotes", fix
        return self


def calls():
    """lib/db-write-calls.py, loaded once from beside this file. CannotLoad when it is missing,
    will not load, or is a copy from before it could be asked (no asked_reading())."""
    if _calls:
        return _calls[0]
    path = os.path.join(_here, "db-write-calls.py")
    try:
        spec = importlib.util.spec_from_file_location("db_write_calls_for_unsure_reading", path)
        lib = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(lib)
    except Exception as e:  # noqa: BLE001  whatever stops the load, the gate is told and decides
        raise CannotLoad("%s, which holds the rule for a line the shared reader is unsure of, could not be "
                         "loaded (%s; reinstall the hooks with claude-sync pull)" % (path, type(e).__name__))
    if not callable(getattr(lib, "asked_reading", None)):
        raise CannotLoad("%s holds no asked_reading(), so the shared reader could not be asked which lines it "
                         "is unsure of (reinstall the hooks with claude-sync pull)" % path)
    _calls.append(lib)
    return lib


def _line(s, at):
    start = s.rfind("\n", 0, at) + 1
    end = s.find("\n", at)
    return s[start:len(s) if end < 0 else end].strip()[:LINE_SHOWN]


def _can_be_asked(lib, sw):
    """Whether lib/db-write-calls.py's own check (asking()) finds a reader that can be asked. The
    check is that library's and is not copied here: its block is entered and left with nothing
    read. A library with no asking() to enter is answered no, and so is a check that fails."""
    asking = getattr(lib, "asking", None)
    if not callable(asking):
        return False
    try:
        with asking(sw):
            return True
    except Exception:  # noqa: BLE001  asked_reading() then meets the same reader and gives its own answer
        return False


def _between_backquotes(sw, s, at):
    """Whether the # the reader named at s[at] is one BETWEEN's sentence is true of. Three things,
    each read from the text or asked of the reader: a backquote stands before the #; another
    stands after it on its line; and the reader's own word_starts(), asked as the reader asks it
    of text inside backquotes (layered), answers that a word starts there. So the reader reads a
    comment from it, and neither a closing parenthesis it cannot place nor a backslash stands
    before it (it answers None and False for those, and they keep that library's sentences).

    Asked without layered it answered True for a # inside backquotes after two backslashes and a
    space, and after a backslash and a line break, both of which the reader names for the
    backslash, and bash reads the first of them inside a word, so the sentence's advice about a
    comment was untrue of it. Asked this way, every # between backquotes that follows a line
    ending in a backslash keeps that library's sentence, whichever reason the reader had.

    The reader has no function that says why it named a mark. As it reads today (commands(), its
    comment_end()), a # it is asked about this way and answers True for is named only between
    backquotes that close on its line, so the three together are that mark and no other."""
    starts = getattr(sw, "word_starts", None)
    if not callable(starts) or not s.startswith("#", at):
        return False
    end = s.find("\n", at)
    if "`" not in s[:at] or "`" not in s[at:len(s) if end < 0 else end]:
        return False
    try:
        return starts(s, at, layered=True) is True
    except Exception:  # noqa: BLE001  a mark the reader's rule cannot be asked about keeps the other sentence
        return False


def asked(sw, read):
    """lib/db-write-calls.py's asked_reading(sw, read): (what read() gives, None) when read() is run
    by the reading sw gives a caller that asks and no reading named a line; (None, the fault) when
    one did, the fault being the sentence for the mark the reader named it with (.kind which
    mark, .fix how to write the command so that nothing is named); (None, words with no .kind)
    when the reader cannot be asked at all. Any other failure of read() is raised, and so is
    CannotLoad.

    Two differences, both in the words alone: a mark that library knows only as "a line" is said
    to be an operator split by a backslash and a line break (Split) when the reader's own
    split_operator() says a mark it named in these readings is one; and a # that library calls a
    comment it cannot tell, or one it could not read past, is said to stand between backquotes
    (Between) when it does (_between_backquotes()). The decision is that library's either way.

    A reader that cannot be asked is answered as that library answers it, (None, words with no
    .kind), whether or not it has a split_operator()."""
    lib = calls()
    plain = sw.commands
    splitter = getattr(sw, "split_operator", None)
    marks, split = [], []
    # The wrapper below takes `unsure` whatever the reader takes, so it is put in front of the
    # reader only where that library's own check finds a reader that can be asked. In front of one
    # that cannot, the check passed, and the reader then failed on a word it does not take where
    # the answer is that it cannot be asked.
    if _can_be_asked(lib, sw):
        # Every reading asked_reading() has the reader make comes through here, so the text each
        # mark stands in is known: the fault it hands back holds the line and not the place.
        def commands(*args, unsure=None, **more):
            if unsure is None:
                return plain(*args, **more)
            try:
                return plain(*args, unsure=unsure, **more)
            finally:
                s = args[0] if args else more.get("s", "")
                if isinstance(s, str):
                    for mark in unsure:
                        marks.append((s, mark[0]))
                        try:
                            operator = splitter(s, mark[0]) if callable(splitter) else ""
                        except Exception:  # noqa: BLE001  a mark this cannot place keeps the general sentence
                            operator = ""
                        if operator:
                            split.append((operator, _line(s, mark[0])))

        sw.commands = commands
    try:
        got, fault = lib.asked_reading(sw, read)
    finally:
        sw.commands = plain
    kind = getattr(fault, "kind", None)
    if kind == "line" and split:
        fault = Split(*split[0])
    elif kind in ("comment", "unread"):
        # The mark the fault is about: the first one given whose line the fault quotes.
        about = [(s, at) for s, at in marks if "`" + _line(s, at) + "`" in fault][:1]
        if about and _between_backquotes(sw, *about[0]):
            fault = Between(_line(*about[0]))
    return got, fault


def second(sw, read):
    """asked(sw, read) for a gate that has already judged the command by the reading it always
    made, and never raises: (what read() gave, None), or (None, the fault). A fault with a .kind is
    a line the reader named, which the gate refuses as a command it could not check (told()). A
    fault with none is why the second reading could not be made at all: the library the rule
    lives in missing, a reader that cannot be asked, or a reading that failed with no line named.
    No rewriting of the command clears one of those, so the gate hands it to whatever it does
    with a command it cannot read."""
    try:
        return asked(sw, read)
    except CannotLoad as e:
        return None, str(e)
    except Exception as e:  # noqa: BLE001  a reading that fails is a fault, never a pass
        return None, ("lib/shell-words.py could not read the command as it reads one for a caller that asks "
                      "which lines it is unsure of (%s)" % type(e).__name__)


def named(fault):
    """Whether a fault is a line the reader named (told() says how to write it), as against a second
    reading that could not be made."""
    return getattr(fault, "kind", None) is not None


def told(fault):
    """The fault as a refusal says it: the sentence, then how to write the command so that the
    reader names nothing there, where the fault holds that."""
    fix = getattr(fault, "fix", "")
    return str(fault) + (". " + fix if fix else "") + " (claude-config#3472)"
