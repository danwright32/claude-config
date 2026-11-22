"""What a sed filter or a git show of one file prints, for the Slack drafts gate (claude-config#3395).

A script written earlier in the same command is judged by what was written (#2525, #2721), and one
whose text the gate cannot work out is refused unread. Counted on one Mac's records for #3218
(2026-11-08 to 11-21), that refusal fired 49 times, and none of the 49 posted. Read by shape, most
were not an edit in place (`sed -i` with a literal program has been read since #2772) but a FILTER
whose output is sent into a new file that is then run: a copy of a suite with one line changed
(`sed 's/old/new/' suite.sh > mutant.sh; bash mutant.sh`), part of a file cut out (`sed -n
'/^cat/,/^PY$/p' suite.sh | sed '1d;$d' > part.py`), or a file as a commit holds it (`git show
REV:PATH > old.py`). The gate knew what printf, echo and cat print and nothing else.

exact_output is asked only where the readings before it gave no answer, and gives one only where
the text is known EXACTLY. Anything else returns None, which is the refusal there was.

sed. The program is run here, on the input, by an emulation of the part of sed that POSIX fixes
and that BSD and GNU sed read alike:

  * options -n and -E, and -e any number of times; nothing else (-i, -f, -s, -r, -z, a long option);
  * commands p, d and s, each on a line of its own or after a `;`, each with no address, one, or a
    range, and `!`; addresses are a line number, `$`, or /regex/; s takes the flags g and p and a
    delimiter that is special nowhere (/ # , : @ % ! ~ = and, never escaped, |);
  * a regular expression of literal characters, `.`, a bracket expression of characters and of
    ranges inside the digits or one case of the letters, `*`, groups and intervals, `^` first and
    `$` last, and with -E also + ? and |. A backslash is taken only before a character that is
    special there. Everything the two seds read differently is outside this and is not read: a
    backslash before a letter or a digit (\\n, \\t, \\w, \\1, \\+, \\|), a class name, a backslash
    inside brackets, `^` or `$` anywhere else, a quantifier on a group that holds one;
  * a replacement of literal text, `&`, and a backslash before &, a backslash or the delimiter;
  * a match is the leftmost and then the LONGEST, as POSIX says, found by trying every end rather
    than by Python's own order; a match of no characters ends the reading;
  * a range ending at a line number, in a program with a d before it, is not read (the two differ
    when the end line is one the d removed).

The input must be known exactly too: files no earlier command of this call wrote, or the text the
gate already worked out for its input, all ASCII, no NUL, each ending in a newline (the two seds
differ on a last line without one), and under MAX_INPUT. The command must be plainly sed: no
NAME=value in front of it, no function or alias of that name in the text.

git. `git [--no-pager] [-C dir] show REV:PATH`, `cat-file -p REV:PATH` and `cat-file blob REV:PATH`
print the file as the commit holds it, and the gate reads it with the same `git cat-file blob` it
already uses for a checkout (git_out). Only where REV is an object name in hex that is no ref: a
branch or HEAD can be moved by an earlier command of the same call, and the gate would have read
the file as it was before. No GIT_ variable may be set in front of it or exported in the text.

slack_drafts_only_gate.py loads this file and gives its Judge the class make() returns as a base, so
the methods use the Judge's own state (shell) and readers (made_from, resolve, sh_cwd, sh_funcs,
git_out, sw).
"""
import os
import re

SEDS = frozenset({"sed", "gsed"})
MAX_INPUT = 512 * 1024
MAX_LINE = 4000
S_DELIMS = frozenset("/#,:@%!~=|")
ESCAPED_DELIMS = S_DELIMS - {"|"}
BRE_LITERAL = frozenset(".*[]^$\\/")
ERE_LITERAL = BRE_LITERAL | frozenset("(){}+?|")
INTERVAL = re.compile(r"(\d{1,3})(?:(,)(\d{1,3})?)?")
AMP = object()  # the whole match, in a replacement
GIT_SPEC = re.compile(r"([0-9a-f]{7,40}):([^:\0\n]+)")
# The session's variables that say which repository or objects git reads.
GIT_PLACES = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_NAMESPACE",
              "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CEILING_DIRECTORIES", "GIT_CONFIG_GLOBAL",
              "GIT_CONFIG_SYSTEM", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS")
ALIAS = r"(?m)(?<![\w.-])alias\s[^\n]*(?<![\w.-])%s="


class Outside(Exception):
    """The program or its input is outside what is emulated exactly."""


def bracket(raw, i):
    """(the Python class for the bracket expression opening at raw[i], the offset past it)."""
    j, n, items, first = i + 1, len(raw), [], True
    neg = j < n and raw[j] == "^"
    if neg:
        j += 1
    while True:
        if j >= n:
            raise Outside("a bracket that is not closed")
        c = raw[j]
        if c == "]" and not first:
            break
        if c == "\\" or (c == "[" and raw[j + 1:j + 2] in (":", ".", "=")):
            raise Outside("a backslash or a class name inside brackets")
        if raw[j + 1:j + 2] == "-" and raw[j + 2:j + 3] not in ("]", ""):
            hi = raw[j + 2]
            same = (c.isdigit() and hi.isdigit()) or (c.islower() and hi.islower()) or (c.isupper() and hi.isupper())
            if not (same and c.isalnum() and hi.isalnum() and c <= hi):
                raise Outside("a range that is not inside the digits or one case of the letters")
            items.append(re.escape(c) + "-" + re.escape(hi))
            j += 3
        else:
            items.append(re.escape(c))
            j += 1
        first = False
    return "[" + ("^" if neg else "") + "".join(items) + "]", j + 1


def regex(raw, ere, delim):
    """(whether it is anchored at the start, the compiled pattern between the anchors, whether it
    is anchored at the end) for one regular expression as sed is given it."""
    if not raw or not raw.isascii() or "\n" in raw:
        raise Outside("an empty or multi line expression")
    i, n, out = 0, len(raw), []
    astart = raw[0] == "^"
    i = 1 if astart else 0
    aend = False
    atom = False        # whether what was just read can take a quantifier
    stack = []          # for each open group, whether it holds a quantifier
    quantified = False  # whether the group just closed holds one
    opened = branch = False  # whether the last thing read opened a group, or was a |
    top_alt = False

    def quantifier(text):
        nonlocal atom, quantified
        if not atom or quantified:
            raise Outside("a quantifier with nothing to repeat, or on a group that holds one")
        out.append(text)
        atom = False
        if stack:
            stack[-1] = True

    def interval(k, closer):
        m = INTERVAL.match(raw, k)
        if not m or raw[m.end():m.end() + len(closer)] != closer:
            raise Outside("an interval that is not one")
        lo, hi = int(m.group(1)), m.group(3)
        if hi is not None and int(hi) < lo:
            raise Outside("an interval that is not one")
        quantifier("{" + m.group(1) + (m.group(2) or "") + (hi or "") + "}")
        return m.end() + len(closer)

    while i < n:
        c = raw[i]
        was_open, was_branch = opened, branch
        opened = branch = False
        if c == "$" and i == n - 1:
            aend = True
            i += 1
            break
        if c == "\\":
            e = raw[i + 1:i + 2]
            if not e:
                raise Outside("a backslash at the end")
            if not ere and e in "()":
                if e == "(":
                    out.append("(")
                    stack.append(False)
                    atom, opened = False, True
                else:
                    if not stack or was_open:
                        raise Outside("a group that is empty or not opened")
                    quantified = stack.pop()
                    if quantified and stack:
                        stack[-1] = True
                    out.append(")")
                    atom = True
                    i += 2
                    continue
            elif not ere and e == "{":
                i = interval(i + 2, "\\}")
                quantified = False
                continue
            elif e in (ERE_LITERAL if ere else BRE_LITERAL) or (e == delim and e in ESCAPED_DELIMS):
                out.append(re.escape(e))
                atom = True
            else:
                raise Outside("a backslash before a character the two seds read differently")
            i += 2
        elif c == "[":
            cls, i = bracket(raw, i)
            out.append(cls)
            atom = True
        elif c == ".":
            out.append(".")
            atom = True
            i += 1
        elif c == "*":
            quantifier("*")
            i += 1
        elif c in "^$":
            raise Outside("an anchor that is not first or last")
        elif ere and c == "(":
            out.append("(")
            stack.append(False)
            atom, opened = False, True
            i += 1
        elif ere and c == ")":
            if not stack or was_open or was_branch:
                raise Outside("a group that is empty or not opened")
            quantified = stack.pop()
            if quantified and stack:
                stack[-1] = True
            out.append(")")
            atom = True
            i += 1
            continue
        elif ere and c == "|":
            if not out or was_open or was_branch:
                raise Outside("an empty alternative")
            top_alt = top_alt or not stack
            out.append("|")
            atom, branch = False, True
            i += 1
        elif ere and c in "+?":
            quantifier(c)
            i += 1
        elif ere and c == "{":
            i = interval(i + 1, "}")
        elif ere and c == "}":
            raise Outside("a brace that closes nothing")
        else:
            out.append(re.escape(c))
            atom = True
            i += 1
        quantified = False
    if stack or branch or opened or (top_alt and (astart or aend)) or not out:
        raise Outside("an expression that is not whole, or anchors beside alternatives")
    return astart, re.compile("".join(out)), aend


def replacement(raw, delim):
    """The parts of an s command's replacement: text, and AMP for the whole match."""
    out, i, n = [], 0, len(raw)
    while i < n:
        c = raw[i]
        if c == "\\":
            e = raw[i + 1:i + 2]
            if e and (e in "&\\" or (e == delim and e in ESCAPED_DELIMS)):
                out.append(e)
                i += 2
                continue
            raise Outside("a backslash in the replacement the two seds read differently")
        if c == "\n" or not c.isascii():
            raise Outside("a newline or a character outside ASCII in the replacement")
        out.append(AMP if c == "&" else c)
        i += 1
    return out


def until(text, i, delim):
    """(the text from i to the next delim no backslash stands before, the offset past that delim)."""
    j, n = i, len(text)
    while j < n:
        if text[j] == "\\":
            j += 2
            continue
        if text[j] == delim:
            return text[i:j], j + 1
        if text[j] == "\n":
            break
        j += 1
    raise Outside("an expression that is not closed")


def address(text, i, ere):
    """(the address at text[i] or None where there is none, the offset past it)."""
    m = re.compile(r"\d+").match(text, i)
    if m:
        if int(m.group(0)) < 1 or len(m.group(0)) > 9:
            raise Outside("line 0, or a line number too long to be one")
        return ("n", int(m.group(0))), m.end()
    if text[i:i + 1] == "$":
        return ("last",), i + 1
    if text[i:i + 1] == "/":
        raw, j = until(text, i + 1, "/")
        astart, core, aend = regex(raw, ere, "/")
        whole = re.compile(("^" if astart else "") + "(?:" + core.pattern + ")" + ("$" if aend else ""))
        return ("re", whole), j
    return None, i


def program(text, ere):
    """The commands of a sed program as [(first address, second, negated, command)], command being
    ("p",), ("d",) or ("s", regex(), replacement(), flags)."""
    cmds, i, n = [], 0, len(text)
    while True:
        while i < n and text[i] in " \t\n":
            i += 1
        if i >= n:
            break
        a1, i = address(text, i, ere)
        a2 = None
        if a1 is not None and text[i:i + 1] == ",":
            a2, i = address(text, i + 1, ere)
            if a2 is None:
                raise Outside("a range with no end")
        while i < n and text[i] in " \t":
            i += 1
        neg = text[i:i + 1] == "!"
        if neg:
            i += 1
        c = text[i:i + 1]
        if c in ("p", "d"):
            cmd, i = (c,), i + 1
        elif c == "s":
            delim = text[i + 1:i + 2]
            if delim not in S_DELIMS:
                raise Outside("a delimiter that can be special")
            pat, j = until(text, i + 2, delim)
            rep, j = until(text, j, delim)
            flags = ""
            while j < n and text[j] in "gp":
                if text[j] in flags:
                    raise Outside("a flag given twice")
                flags += text[j]
                j += 1
            cmd, i = ("s", regex(pat, ere, delim), replacement(rep, delim), flags), j
        else:
            raise Outside("a command other than p, d and s")
        while i < n and text[i] in " \t":
            i += 1
        if i < n:
            if text[i] not in ";\n":
                raise Outside("text after a command")
            i += 1
        if a2 is not None and a2[0] == "n" and any(k[3][0] == "d" for k in cmds):
            raise Outside("a range ending at a line number after a d")
        cmds.append((a1, a2, neg, cmd))
    if not cmds:
        raise Outside("no command")
    return cmds


def substitute(cmd, line):
    """(line after the s command, whether it changed)."""
    (astart, core, aend), rep, flags = cmd[1], cmd[2], cmd[3]
    n, pos, out, changed = len(line), 0, [], False
    while pos <= n:
        found = None
        if astart:
            starts = [0] if pos == 0 else []
        else:
            first = core.search(line, pos)
            starts = range(first.start(), n + 1) if first else []
        for i in starts:
            if core.match(line, i) is None:
                continue
            for j in ([n] if aend else range(n, i - 1, -1)):
                if core.fullmatch(line, i, j):
                    found = (i, j)
                    break
            if found:
                break
        if not found:
            break
        i, j = found
        if i == j:
            raise Outside("a match of no characters")
        out.append(line[pos:i])
        out.append("".join(line[i:j] if p is AMP else p for p in rep))
        pos, changed = j, True
        if "g" not in flags:
            break
    out.append(line[pos:])
    return "".join(out), changed


def sed_plan(words):
    """(the program, whether -n was given, the input files) for the words after sed, each worked
    out; None where an option or the program is outside what is emulated."""
    quiet = ere = False
    scripts, k, n = [], 0, len(words)
    while k < n:
        w = words[k]
        if w == "-e":
            if k + 1 >= n:
                return None
            scripts.append(words[k + 1])
            k += 2
        elif w in ("-n", "-E", "-nE", "-En"):
            quiet = quiet or "n" in w
            ere = ere or "E" in w
            k += 1
        else:
            break
    files = words[k:]
    if not scripts:
        if not files or files[0].startswith("-"):
            return None
        scripts, files = [files[0]], files[1:]
    if any(not f or f.startswith("-") for f in files):
        return None  # an option after the program, or `-` for the input
    try:
        return program("\n".join(scripts), ere), quiet, files
    except Outside:
        return None


def sed_apply(prog, quiet, text):
    """What sed prints for text under prog, or None where the text or a match is outside what is
    emulated exactly."""
    if not text:
        return ""
    if not text.isascii() or "\0" in text or not text.endswith("\n"):
        return None
    lines = text[:-1].split("\n")
    if any(len(line) > MAX_LINE for line in lines):
        return None
    out, active, last = [], [False] * len(prog), len(lines)

    def at(a, no, line):
        return no == a[1] if a[0] == "n" else no == last if a[0] == "last" else bool(a[1].search(line))

    try:
        for no, line in enumerate(lines, 1):
            deleted = False
            for k, (a1, a2, neg, cmd) in enumerate(prog):
                if a1 is None:
                    hit = True
                elif a2 is None:
                    hit = at(a1, no, line)
                elif active[k]:
                    hit = True
                    if (a2[0] == "n" and no >= a2[1]) or (a2[0] != "n" and at(a2, no, line)):
                        active[k] = False
                elif at(a1, no, line):
                    hit = True
                    active[k] = not (a2[0] == "n" and a2[1] <= no) and no != last
                else:
                    hit = False
                if hit == neg:
                    continue
                if cmd[0] == "d":
                    deleted = True
                    break
                if cmd[0] == "p":
                    out.append(line)
                else:
                    line, changed = substitute(cmd, line)
                    if changed and "p" in cmd[3]:
                        out.append(line)
            if not deleted and not quiet:
                out.append(line)
    except Outside:
        return None
    return "".join(line + "\n" for line in out)


def make(unknown_dir):
    """The Judge's base for the rule. unknown_dir is the gate's word for a directory that is not
    certain."""

    class ExactOutput:

        def exact_output(self, name, vals, d, stdin, text):
            """For note_writes, where no reading before gave what the command prints: the pieces of
            what it prints where that is known exactly (module docstring), else None. vals are the
            command's words, each worked out or None, stdin the pieces of its input or None, and
            text the command as written."""
            if (name not in SEDS and name != "git") or any(v is None for v in vals):
                return None
            if self.sw.command_rest(text)[1].strip() or self.sh_cwd(d) == unknown_dir:
                return None
            ctx = self.shell
            while ctx is not None:
                if self.exact_shadowed(ctx["text"], name):
                    return None  # a function or an alias of that name is not the program
                if name == "git" and any(n.startswith("GIT_") for n in list(ctx["exported"]) + list(ctx["pending"])):
                    return None
                ctx = ctx.get("parent")
            if name == "git":
                if any(n in os.environ for n in GIT_PLACES):
                    return None  # git_out leaves these out, and the command itself would not
                return self.git_file_printed(vals[1:], d)
            plan = sed_plan(vals[1:])
            if plan is None:
                return None
            prog, quiet, files = plan
            data = self.exact_bytes([("file", os.path.realpath(self.resolve(f, d)), f) for f in files]
                                    if files else stdin)
            if data is None:
                return None
            out = sed_apply(prog, quiet, data.decode("utf-8", "replace"))
            return None if out is None else [("text", out, "what sed prints")]

        def exact_shadowed(self, text, name):
            """Whether text defines a function or an alias called name, so that the word in a command
            of it is not the program. Worked out once for each text and name, which is all it
            depends on: each asking searches the whole text, and made again for every sed and git
            command of a long script that was about 0.4 s of judging `bash tests/test-claude-sync.sh`
            (5.94 to 6.00 s of processor time with the search made each time, 5.51 to 5.60 s
            without it, three readings each way taken in turn on 2026-11-22).

            The name is this library's own on purpose. Every library's class is a base of the one
            Judge, so a method here that shares a name with another's is never the one called:
            written first as named_in, which lib/data-names.py already has, the call above reached
            that one, which said no for every text, and a command whose sed was a function was
            allowed (four cases of test-slack-drafts-reads-more.sh, 2026-11-22, before any commit)."""
            memo = self.__dict__.get("_exact_shadowed")
            if memo is None:
                memo = self.__dict__["_exact_shadowed"] = {}
            key = (text, name)
            if key not in memo:
                memo[key] = name in self.sh_funcs(text) or bool(re.search(ALIAS % re.escape(name), text))
            return memo[key]

        def exact_bytes(self, pieces):
            """The bytes that pieces certainly are, or None: text the gate worked out, and files no
            earlier command of this call wrote, each ending in a newline, under MAX_INPUT in all."""
            if pieces is None:
                return None
            out = b""
            for kind, value, _ in pieces:
                if kind == "text":
                    data = value.encode("utf-8", "replace")
                elif kind == "file" and self.made_from(value) is None and os.path.isfile(value):
                    try:
                        with open(value, "rb") as f:
                            data = f.read(MAX_INPUT + 1)
                    except OSError:
                        return None
                else:
                    return None
                if data and not data.endswith(b"\n"):
                    return None
                out += data
                if len(out) > MAX_INPUT:
                    return None
            return out

        def git_file_printed(self, words, d):
            """What `git show REV:PATH` and the two cat-file forms print, as one text piece, where
            REV is a hex object name that is no ref (module docstring); else None."""
            k = 1 if words[:1] == ["--no-pager"] else 0
            where = self.resolve(".", d)
            if words[k:k + 1] == ["-C"] and len(words) > k + 1:
                where = self.resolve(words[k + 1], d)
                k += 2
            rest = words[k:]
            if len(rest) == 2 and rest[0] == "show":
                spec = rest[1]
            elif len(rest) == 3 and rest[0] == "cat-file" and rest[1] in ("-p", "blob"):
                spec = rest[2]
            else:
                return None
            m = GIT_SPEC.fullmatch(spec)
            if not m:
                return None
            rev = m.group(1)
            full = self.git_out(where, ["rev-parse", "--verify", "--quiet", rev + "^{commit}"])
            named = self.git_out(where, ["rev-parse", "--symbolic-full-name", rev])
            if not full or not full.decode("ascii", "replace").strip().startswith(rev) or named is None or named.strip():
                return None
            blob = self.git_out(where, ["cat-file", "blob", spec])
            if blob is None or len(blob) > MAX_INPUT:
                return None
            return [("text", blob.decode("utf-8", "replace"), f"{spec} as git holds it")]

    return ExactOutput
