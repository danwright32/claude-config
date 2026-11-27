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
later than it did, the lines up to there as well, each of those once however many places the
command stands at (Given). More to read is not always a stricter reading, so the loose reading
is kept as it was (loose) and the gate judges a call by both where they differ. Where
it cannot tell where they end it, it raises what the caller hands it as `unsure`, which the gate
refuses as a check it could not make: a marker a backslash joins to the line before, a line that
is the marker only once joined, a marker the loose reading took the first letters of and word()
does not read, more than one << in the command, an opener line that ends in a backslash, an
earlier heredoc on that line that cannot be read or never ends, or a body whose marker is not
quoted that never ends and holds a $ or a backquote, which the shells expand there (one whose
marker is quoted is fed as written, and handed on).

An opener the loose reading never took (<<\\E, <<'E\\', <<"E F", <<!, <<~E) is not refused. fed() gave the
command's own line for it and no body, so `python3 <<\\E` importing a module that posts passed. It
now gives that line and then the body, where word() reads the marker and the end is certain, and
goes on saying it is no body: an interpreter's imports and a send route's name are read there,
what a pipe from such a heredoc carries stays not worked out, and a shell fed that way still has
its lines read by nobody as commands. Where the marker is not read (a $ or a backquote in it
outside single quotes, as in <<"E$", or a bare character that is none of PLAIN_WIDE, as in <<*)
nothing is added.
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
# And a ! or a ~, which both take as themselves too (`cat <<!` and `cat <<~E`, measured 2026-11-27
# in bash 3.2.57 and zsh 5.9 by the review of #3497, and held against the shells of the machine by
# test-slack-drafts-heredoc-fed.sh). Read only in an opener the loose reading never took (word).
PLAIN_WIDE = re.compile(r"[A-Za-z0-9_.,:/@%+=^!~-]")


def odd(line):
    """Whether line ends in an odd count of backslashes, the last of which joins it to the next."""
    return (len(line) - len(line.rstrip("\\"))) % 2 == 1


def word(s, i, wide=False):
    """The heredoc opened at s[i] ("<<"), as (marker, strip_tabs, quoted): the word after it with
    its quotes taken off, whether a - follows the <<, and whether any part of the word is quoted,
    when the shells read the body as written. "" where no word follows, and None where the word
    is one bash 3.2 and zsh are not known here to read alike: one holding a $ or a backquote
    outside single quotes (inside them both take the marker as written, and it is read), a line
    break, a character outside PLAIN that no quote holds, a quote that never closes, or no
    character at all. wide takes the characters of PLAIN_WIDE as well: asked only for an opener
    the loose reading never took, where a marker that is read adds lines and one that is not
    adds none, so reading more of them refuses only more."""
    plain = PLAIN_WIDE if wide else PLAIN
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
        elif plain.match(c):
            out.append(c)
            j += 1
        else:
            return None
    if j == start:
        return ""
    marker = "".join(out)
    return None if not marker or "\n" in marker else (marker, strip, quoted)


def end(lines, k, marker, strip, quoted):
    """(the index of the line that ends the heredoc whose body starts at lines[k], as bash 3.2 and
    zsh end it, the last index this looked at). The first is len(lines) where no line ends it,
    when both feed the rest of the text, and None where that cannot be told: the marker stands on
    a line a backslash joins to the one before, or a line is the marker only once its joined lines
    are put together, which shells end at or not each in its own cases. The second is then the
    first of those joined lines."""
    i, n = k, len(lines)
    while i < n:
        line = lines[i]
        if quoted or not odd(line):
            if (line.lstrip("\t") if strip else line) == marker:
                return i, i
            i += 1
            continue
        # A line that a backslash joins to the next, and every line joined on after it.
        j = i
        while j < n - 1 and odd(lines[j]):
            j += 1
        pieces = [p.lstrip("\t") if strip else p for p in lines[i:j + 1]]
        cut = [p[:-1] if odd(p) else p for p in pieces]
        if "".join(cut) == marker or marker in pieces or marker in cut:
            return None, i
        i = j + 1
    return n, n


def places(text, whole, lines_of):
    """(whole's lines, where each starts, the command text with the blanks round it taken off, each
    place that text stands in whole as (the index of its line, its offset)). The places are found
    by searching whole for the text rather than each line in turn; a text holding a line break is
    in no line."""
    lines, starts = lines_of(whole)
    key = text.strip()
    ats, at = [], whole.find(key) if key and "\n" not in key else -1
    while at >= 0:
        i = bisect.bisect_right(starts, at) - 1
        ats.append((i, at))
        at = whole.find(key, starts[i + 1]) if i + 1 < len(starts) else -1
    return lines, starts, key, ats


def loose_end(lines, i, marker):
    """The index of the line the loose reading ends the body opened on lines[i] at: the first after
    it that is marker once the blanks round it are taken off. None where no line is."""
    return next((j for j in range(i + 1, len(lines)) if lines[j].strip() == marker), None)


def loose(text, whole, lines_of):
    """What Judge.fed gave before claude-config#3497, and gives nothing else here: for each place
    the command stands, the lines after it up to the first that is the first plain word after
    the << once the blanks round it are taken off; the command's own lines where no such word
    follows a <<; and the whole text where the command is found nowhere or a body never ends.

    Kept beside fed() because a longer body is not always a stricter one. The gate's reading of a
    text is not a sum of its lines: a line fed() adds can weaken how the lines before it are read
    (a quote left open has a shell's body read by the crude cut, which follows no variable; a
    later sys.path line is applied to an import that ran before it), and five commands main
    refused passed that way (review of #3497, 2026-11-27). So the gate judges a call with what
    fed() gives and, where that differs from this anywhere, once more with this, and refuses
    where either gives a reason (main() in slack_drafts_only_gate.py). Nothing fed() adds can
    then allow a command the reading before it refused."""
    lines, starts, key, ats = places(text, whole, lines_of)
    if not ats:
        return whole, False
    m = LOOSE.search(text)
    if not m:
        return "\n".join(lines[i] for i, _ in ats), False
    bodies = []
    for i, _ in ats:
        stop = loose_end(lines, i, m.group(2))
        if stop is None:
            return whole, False  # a body never closed: read it all
        bodies.append("\n".join(lines[i + 1:stop]))
    return "\n".join(bodies), True


class Given:
    """The lines of a text fed() has handed on so far, as spans that neither meet nor overlap, in
    order. The same command written at several places can open heredocs whose bodies run into one
    another: 300 `python3 <<EOF`, each followed by an indented EOF that ends nothing, are 300
    bodies that all run to the end of the text. Joined whole they were 135,000 lines for a text of
    900, every one of which the gate then read once for each of the 300 commands, and a script
    main judged in 1.47 seconds ran out of the gate's time (review of #3497, 2026-11-27). A line
    past the place a body always ended is handed on once, by the first place that reaches it."""

    def __init__(self):
        self.firsts, self.stops = [], []

    def rest(self, a, b):
        """The parts of lines a up to b that no call before this one was handed, as (first, stop)
        in order. All of a up to b counts as handed on from here."""
        if a >= b:
            return []
        i = bisect.bisect_left(self.stops, a)
        j, at, out = i, a, []
        while j < len(self.firsts) and self.firsts[j] <= b:
            if self.firsts[j] > at:
                out.append((at, self.firsts[j]))
            at = max(at, self.stops[j])
            j += 1
        if at < b:
            out.append((at, b))
        first = min(a, self.firsts[i]) if i < j else a
        stop = max(b, self.stops[j - 1]) if i < j else b
        self.firsts[i:j], self.stops[i:j] = [first], [stop]
        return out


class Reader:
    """Where bash 3.2 and zsh end the heredocs of one text (body_at), with each search for a
    marker's end kept, so that the places one command stands at read each line of the text once
    for that marker and not once for each place."""

    def __init__(self, lines, starts):
        self.lines, self.starts = lines, starts
        self.ends = {}  # {(marker, strip, quoted): (the line a search began at, the last it looked at, what it found)}
        self.expanded = None  # the index of the last line holding a $ or a backquote, -1 for none

    def end(self, k, marker, strip, quoted):
        """end() from lines[k], taken from the search kept for this marker where that one passed
        lines[k] as a line of its own: it began at or before it, looked at least that far, and no
        backslash joins lines[k] to the line before, so both read every line from there alike."""
        key, lines = (marker, strip, quoted), self.lines
        was = self.ends.get(key)
        if was and was[0] <= k <= was[1] and (quoted or k == 0 or not odd(lines[k - 1])):
            return was[2]
        found, reached = end(lines, k, marker, strip, quoted)
        self.ends[key] = (k, reached, found)
        return found

    def expands(self, k):
        """Whether a line from lines[k] on holds a $ or a backquote, which the shells expand in a
        body whose marker is not quoted. Found in one pass over the text, kept."""
        if self.expanded is None:
            self.expanded = next((i for i in range(len(self.lines) - 1, -1, -1)
                                  if "$" in self.lines[i] or "`" in self.lines[i]), -1)
        return self.expanded >= k

    def body_at(self, i, at, strict):
        """(first, stop): lines[first:stop] is the body bash 3.2 and zsh feed the heredoc that
        word() read as strict, opened by the command at offset at of the text, on lines[i]. Where
        that cannot be told, the kind of doubt fed() names instead: "marker" for an opener line
        that goes on over the next, or an earlier heredoc on it that cannot be read or never ends,
        and "" for a body whose end cannot be found, or whose marker is not quoted and that
        never ends and holds a $ or a backquote."""
        lines = self.lines
        if odd(lines[i]):
            return "marker"  # the command goes on over the next line
        # A heredoc opened earlier on the line takes its body first.
        k = i + 1
        for o in OPENS.finditer(lines[i], 0, at - self.starts[i]):
            earlier = word(lines[i], o.start())
            k = self.end(k, *earlier) if earlier else None
            if k is None or k >= len(lines):
                return "marker"
            k += 1
        stop = self.end(k, *strict)
        if stop is None:
            return ""
        if stop >= len(lines) and not strict[2] and self.expands(k):
            return ""  # never ended, and the shells expand what the rest holds
        return k, stop


def fed(text, whole, lines_of, unsure):
    """(what the command text is fed in whole, whether that is a heredoc's body), as Judge.fed gives
    it. lines_of(whole) is whole's lines and where each starts; unsure(at, kind) makes what is
    raised for a heredoc opened at offset at of whole whose end cannot be told. kind is "marker"
    where the opener is the doubt (more than one << in the command, a marker word() does not
    read, an opener line that goes on over the next, an earlier heredoc on that line that cannot
    be read or never ends) and "" where the body is (Reader.body_at)."""
    lines, starts, key, ats = places(text, whole, lines_of)
    if not ats:
        return whole, False
    m = LOOSE.search(text)
    lead = len(text) - len(text.lstrip())
    opens = [o.start() - lead for o in OPENS.finditer(text)]
    reader, given = Reader(lines, starts), Given()
    if not m:
        # An opener the loose reading never took for one: a marker written with a backslash, in
        # quotes with a character that is no letter, digit or underscore, or bare and starting
        # with a ! or a ~ (<<\E, <<'E\', <<"E F", <<!, <<~E).
        # It always gave the lines holding the command and no body, and still says this is no
        # body, so what a pipe from such a heredoc carries stays not worked out, and refused, as
        # it was. Where the marker is read and its end is certain the body follows those lines,
        # so that a caller searching what it is handed (an interpreter's imports, a send route's
        # name) reads what the shells feed. Never a refusal here: raising for every such opener
        # refused cat <<'E\' with a quiet body, which test-slack-drafts-comment-start.sh pins.
        held = [lines[i] for i, _ in ats]
        strict = word(key, opens[0], True) if len(opens) == 1 else None
        for i, at in ats if strict else ():
            got = reader.body_at(i, at, strict)
            if not isinstance(got, str):
                held.append("\n".join(ln for a, b in given.rest(*got) for ln in lines[a:b]))
        return "\n".join(held), False
    # The shells' reading of the opener, None where the only << is the tail of a here string's <<<,
    # which the loose reading alone goes on answering for.
    strict = None
    if opens:
        strict = word(key, opens[0]) if len(opens) == 1 and m.start() - lead == opens[0] else None
        if not strict:
            raise unsure(ats[0][1] + opens[0], "marker")
    bodies = []
    for i, at in ats:
        was = loose_end(lines, i, m.group(2))
        if was is None:
            return whole, False  # a body never closed: read it all
        last = was
        if strict:
            got = reader.body_at(i, at, strict)
            if isinstance(got, str):
                raise unsure(at + opens[0], got)
            last = max(was, got[1])
        # The body it always gave, whole, and then the lines the shells go on feeding it that no
        # place before this one was handed (Given).
        given.rest(i + 1, was)
        body = list(lines[i + 1:was])
        for a, b in given.rest(was, last):
            body.extend(lines[a:b])
        bodies.append("\n".join(body))
    return "\n".join(bodies), True
