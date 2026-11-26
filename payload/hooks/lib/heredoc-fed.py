"""Which lines a heredoc feeds a program, for the Slack drafts gate's own reading (claude-config#3497).

Judge.fed works out what a shell or an interpreter that reads its input is fed. For a heredoc it
cut the lines after the command up to the first line that, with the blanks round it taken off, was
the first plain word after the << (LOOSE below, the reading it always gave). The shells do
otherwise, and each difference fed the program lines the gate then read as shell commands, where
an import names no file:

  * a heredoc ends only at a line that IS its marker; a <<- lets that line's leading tabs go and
    nothing else, so a marker with a space beside it, or a tab after a plain <<, ends nothing;
  * the marker is the whole word after the <<, its quotes taken off: after <<E"F" it is EF, and
    after <<E-1 it is E-1;
  * a heredoc opened earlier on the same line takes its body first;
  * in the body of an unquoted marker a line ending in an odd count of backslashes is joined to
    the next, so a marker on that next line is the tail of a longer line and ends nothing.

Measured 2026-11-26 in bash 3.2.57, sh and zsh 5.9 with texts that only print, which
test-slack-drafts-heredoc-fed.sh runs again in the shells of the machine it is on; the joined lines
were measured for the shared reader on 2026-11-23 in seven shells (heredoc_close in
lib/shell-words.py, claude-config#3495). That reader refuses a joined marker, but gives up on a
text whose earlier heredoc leaves a substitution open before it reaches a later one, and the gate
then judged the text by fed() alone (the issue's comment, measured at the gate 2026-11-23).

fed() here gives every line the loose reading gave and, where bash 3.2 and zsh end the heredoc
later than it did, the lines up to there as well, so it can only hand the gate more to read. Where
it cannot tell where they end it, it raises what the caller hands it as `unsure`, which the gate
refuses as a check it could not make: a marker a backslash joins to the line before, a line that
is the marker only once joined, a marker written in a way this does not read, more than one << in
the command, or a body that never ends and holds a $ or a backquote, which the shells expand.
"""
import bisect
import re

# Every << of a text that is no part of a here string's <<<.
OPENS = re.compile(r"(?<!<)<<(?!<)")
# The opener as fed() always read it: the first plain word after a <<, in one pair of quotes or none.
LOOSE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z0-9_]+)\1")
WORD_END = " \t\n;&|<>()"
# What a marker may hold outside quotes and still be read here: bash 3.2 and zsh take each as itself.
PLAIN = re.compile(r"[A-Za-z0-9_.,:/@%+=^-]")


def odd(line):
    """Whether line ends in an odd count of backslashes, the last of which joins it to the next."""
    return (len(line) - len(line.rstrip("\\"))) % 2 == 1


def word(s, i):
    """The heredoc opened at s[i] ("<<"), as (marker, strip_tabs, quoted): the word after it with
    its quotes taken off, whether a - follows the <<, and whether any part of the word is quoted,
    when the shells read the body as written. "" where no word follows, and None where the word
    is one bash 3.2 and zsh are not known here to read alike: one holding a $, a backquote or a
    line break, a character outside PLAIN that no quote holds, a quote that never closes, or no
    character at all."""
    j, n = i + 2, len(s)
    strip = s.startswith("-", j)
    j += strip
    while j < n and s[j] in " \t":
        j += 1
    start, out, quoted = j, [], False
    while j < n and s[j] not in WORD_END:
        c = s[j]
        if c == "\\":
            if j + 1 >= n or s[j + 1] in "\n$`":
                return None
            out.append(s[j + 1])
            quoted, j = True, j + 2
        elif c in "'\"":
            k = j + 1
            while k < n and s[k] != c:
                if c == '"' and s[k] in "$`\\":
                    return None
                k += 1
            if k >= n:
                return None
            out.append(s[j + 1:k])
            quoted, j = True, k + 1
        elif PLAIN.match(c):
            out.append(c)
            j += 1
        else:
            return None
    if j == start:
        return ""
    marker = "".join(out)
    return None if not marker or "\n" in marker else (marker, strip, quoted)


def end(lines, k, marker, strip, quoted):
    """The index of the line that ends the heredoc whose body starts at lines[k], as bash 3.2 and
    zsh end it; len(lines) where no line does, when both feed the rest of the text; None where
    that cannot be told: the marker stands on a line a backslash joins to the one before, or a
    line is the marker only once its joined lines are put together, which shells end at or not
    each in its own cases."""
    i, n = k, len(lines)
    while i < n:
        line = lines[i]
        if quoted or not odd(line):
            if (line.lstrip("\t") if strip else line) == marker:
                return i
            i += 1
            continue
        # A line that a backslash joins to the next, and every line joined on after it.
        j = i
        while j < n - 1 and odd(lines[j]):
            j += 1
        pieces = [p.lstrip("\t") if strip else p for p in lines[i:j + 1]]
        cut = [p[:-1] if odd(p) else p for p in pieces]
        if "".join(cut) == marker or marker in pieces or marker in cut:
            return None
        i = j + 1
    return n


def fed(text, whole, lines_of, unsure):
    """(what the command text is fed in whole, whether that is a heredoc's body), as Judge.fed gives
    it. lines_of(whole) is whole's lines and where each starts; unsure(at, kind) makes what is
    raised for a heredoc opened at offset at of whole whose end cannot be told, kind "marker" for
    an opener this does not read and "" for a body it cannot find the end of."""
    lines, starts = lines_of(whole)
    key = text.strip()
    # The lines holding key, found by searching whole for it rather than each line in turn; one
    # holding a line break is in no line.
    ats, at = [], whole.find(key) if key and "\n" not in key else -1
    while at >= 0:
        i = bisect.bisect_right(starts, at) - 1
        ats.append((i, at))
        at = whole.find(key, starts[i + 1]) if i + 1 < len(starts) else -1
    if not ats:
        return whole, False
    m = LOOSE.search(text)
    lead = len(text) - len(text.lstrip())
    opens = [o.start() - lead for o in OPENS.finditer(text)]
    if not m:
        if opens:
            raise unsure(ats[0][1] + opens[0], "marker")
        return "\n".join(lines[i] for i, _ in ats), False
    # The shells' reading of the opener, None where the only << is the tail of a here string's <<<,
    # which the loose reading alone goes on answering for.
    strict = None
    if opens:
        strict = word(key, opens[0]) if len(opens) == 1 and m.start() - lead == opens[0] else None
        if not strict:
            raise unsure(ats[0][1] + opens[0], "marker")
    bodies = []
    for i, at in ats:
        loose = next((j for j in range(i + 1, len(lines)) if lines[j].strip() == m.group(2)), None)
        if loose is None:
            return whole, False  # a body never closed: read it all
        last = loose
        if strict:
            here = at + opens[0]
            if odd(lines[i]):
                raise unsure(here, "marker")  # the command goes on over the next line
            # A heredoc opened earlier on the line takes its body first.
            k = i + 1
            for o in OPENS.finditer(lines[i], 0, at - starts[i]):
                earlier = word(lines[i], o.start())
                k = end(lines, k, *earlier) if earlier else None
                if k is None or k >= len(lines):
                    raise unsure(here, "marker")
                k += 1
            stop = end(lines, k, *strict)
            if stop is None:
                raise unsure(here, "")
            if stop >= len(lines) and not strict[2] and re.search(r"[$`]", "\n".join(lines[k:])):
                raise unsure(here, "")  # never ended, and the shells expand what the rest holds
            last = max(loose, stop)
        bodies.append("\n".join(lines[i + 1:last]))
    return "\n".join(bodies), True
