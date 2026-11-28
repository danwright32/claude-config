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
    special there, and never before the delimiter where the delimiter is one of those: sed takes
    that backslash off first and reads the bare character, so `\\|` between bars is alternation
    under -E. Everything the two seds read differently is outside this and is not read: a
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
That the command is git, and which of its words are git's own options, its subcommand and the
words after, is asked of the one reading of that (lib/shell-words.py git_read, claude-config#1188),
as the gate itself asks it: lib/word-position-scan.py refuses a second reading written here.

The program. All of the above is what the SYSTEM's sed or git prints, and a command may run another
program of that name: `./git show REV:PATH > old.sh` with a script called git in the folder was
read as the commit's file and allowed (seen on af3a86bcf5, 2026-11-22). So nothing is read unless
the program the shell would run is that one for certain:

  * by a path, only in a folder the gate already takes for the system's (its SYSTEM_BIN);
  * by its bare name, only where every folder of the session's own PATH is a whole path (an empty
    or relative entry is the folder the command runs in), and no text that runs the command, the
    line itself or a script around it, names PATH in any way, set or only read;
  * with no word in front that runs it for the shell (env, exec, command, sudo, nice, xargs:
    lib/shell-words.py's runners), since one can change where the program is looked for;
  * never where an earlier command of the same call wrote, or may have written, the file the
    shell would run: the word's own path, or for a bare name a file of that name in any folder of
    the session's PATH or of SYSTEM_BIN (written_program, claude-config#3837: in `cp ./frob
    /opt/homebrew/bin/cat; /opt/homebrew/bin/cat calm.sh > run.sh; bash run.sh` the cat that
    runs is the copy, so run.sh is not calm.sh);
  * never where a function or an alias of the name is defined: in a text that runs the command,
    in a file such a text sources before it or one that file sources (sourced_shadow), or
    anywhere in such a text as a name in front of empty brackets, quoted or not, which is how
    `eval 'cat() { ... }'` and a definition after another command on its line are written
    (named_anywhere, claude-config#3837).

Not looked at, and so still believed: a bare name the session's PATH resolves outside those
folders, zsh's path array, the shell's hash table (hash -p), PATH set by a file the command
sources, and a function whose name eval or source is handed through a variable.

That judgement is system_program, and it is the gate's one judgement of it (claude-config#3440).
The gate's older readings took a program by the last part of its word in the same way: with a
script called cat in the folder, `./cat calm.sh > run.sh; bash run.sh` was read as calm.sh and
allowed, and so were a bare cat after PATH was set and a script called cp (seen on a49e2ec940,
2026-11-22). They now ask it too: what printf, echo and cat print into a file or down a pipe and
what tee writes, through believed, which keeps the pieces and adds one the gate could not read;
and what cp, mv, ln, install and link copy, through copy_believed. echo and printf by their
bare names are the shell's builtins, which PATH does not move. For these readings PATH named in
the text of a script on disk is not counted (system_program says why). Still believed by its
name alone:
what dd, tar, unzip, sed -i, awk, a git checkout and a compiler write (lib/program-writes.py
note_program), a program taken to write or do nothing (NON_WRITERS there, the gate's SH_INERT),
and $(dirname X).

slack_drafts_only_gate.py loads this file and gives its Judge the class make() returns as a base, so
the methods use the Judge's own state (shell) and readers (made_from, resolve, sh_cwd, sh_funcs,
git_out, sw).
"""
import glob
import os
import re

SEDS = frozenset({"sed", "gsed"})
MAX_INPUT = 512 * 1024
MAX_LINE = 4000
S_DELIMS = frozenset("/#,:@%!~=|")
ESCAPED_DELIMS = S_DELIMS - {"|"}
BRE_LITERAL = frozenset(".*[]^$\\/")
ERE_LITERAL = BRE_LITERAL | frozenset("(){}+?|")
# Every character that means something in an expression of either kind, bare or behind a backslash.
# One of these as the delimiter, escaped, is never read: see regex().
REGEX_SPECIAL = frozenset(".*[]^$(){}+?|")
INTERVAL = re.compile(r"(\d{1,3})(?:(,)(\d{1,3})?)?")
AMP = object()  # the whole match, in a replacement
GIT_SPEC = re.compile(r"([0-9a-f]{7,40}):([^:\0\n]+)")
# The session's variables that say which repository or objects git reads.
GIT_PLACES = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_NAMESPACE",
              "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CEILING_DIRECTORIES", "GIT_CONFIG_GLOBAL",
              "GIT_CONFIG_SYSTEM", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS")
ALIAS = r"(?m)(?<![\w.-])alias\s[^\n]*(?<![\w.-])%s="
# Each stretch of a text ALIAS can match in, from the word alias to the end of its line.
ALIAS_LINE = re.compile(r"(?m)(?<![\w.-])alias\s[^\n]*")
# PATH as a name of its own (never part of PYTHONPATH or GIT_EXEC_PATH), written any way at all.
PATH_NAMED = re.compile(r"(?<!\w)PATH(?!\w)")
# The programs among those the gate reads by name that bash, zsh and dash each run as a builtin of
# their own where the name is written bare, whatever PATH holds (system_program).
BUILTINS = frozenset({"echo", "printf"})
# Empty brackets, and the name a function would have that ends just before them (named_anywhere).
EMPTY_BRACKETS = re.compile(r"\(\s*\)")
NAME_BEFORE = re.compile(r"[A-Za-z_][\w:.-]*\Z")
# The most of a sourced file that is read for a function or an alias of a name (sourced_text).
SOURCED_MAX = 2 * 1024 * 1024


def named_anywhere(text):
    """Every name text writes in the form `name()`, in front of empty brackets, wherever that
    stands: at the start of a line or after another command, bare or inside quoted words. Only
    that form: the other one, `function name`, the gate's sh_funcs already finds anywhere in a
    text, quoted or not. It finds `name()` only at the start of a line, so `true; cat() { ./frob; }`
    and `eval 'cat() { ./frob; }'` each define a function it does not see (claude-config#3837).
    Quoted words are counted on purpose: whether a shell ever evaluates them is not something a
    reading of the text can say, and counting one that is only printed can only make a program
    doubted, never believed.

    One pass over the brackets, never one search for each name: this is asked of every text
    system_program walks, and a suite's script can be megabytes long."""
    names = set()
    for m in EMPTY_BRACKETS.finditer(text):
        found = NAME_BEFORE.search(text[max(0, m.start() - 120):m.start()].rstrip(" \t"))
        if found:
            names.add(found.group(0))
    return names


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
            if e == delim and e in REGEX_SPECIAL:
                # sed takes the backslash off an escaped delimiter BEFORE it reads the expression,
                # so what it reads is the bare character: under -E `\|` with | as the delimiter is
                # alternation, where the literal bar read here left a commented line a comment.
                raise Outside("an escaped delimiter that means something in an expression")
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


def make(unknown_dir, system_bin):
    """The Judge's base for the rule. unknown_dir is the gate's word for a directory that is not
    certain, system_bin the folders it takes a program in for the system's own (its SYSTEM_BIN,
    the one list of them)."""

    class ExactOutput:

        def exact_output(self, name, vals, d, stdin, text):
            """For note_writes, where no reading before gave what the command prints: the pieces of
            what it prints where that is known exactly (module docstring), else None. vals are the
            command's words, each worked out or None, stdin the pieces of its input or None, and
            text the command as written."""
            if any(v is None for v in vals):
                return None
            # Whether the command is git, with which options of git's own and which subcommand, is
            # the one reading's answer (lib/shell-words.py git_read, claude-config#1188): never
            # read from the words here, where a second reading could come to disagree with it.
            git = None if name in SEDS else self.sw.git_read(vals)
            if git is None and name not in SEDS:
                return None
            if git is not None and vals[0].lstrip("({") != vals[0]:
                # That reading takes a ( or a { glued in front of the program as the shell's, which
                # it is in a command as written. These words are worked out, where one is part of
                # the name: a program called `(git` is not git, and was never read as it (seen
                # allowed without this line, test-slack-drafts-reads-more.sh, 2026-11-22).
                return None
            # What is read is what the SYSTEM's sed or git prints, so the program the shell would
            # run has to be that one for certain (system_program).
            if not self.system_program(vals[0], name, text):
                return None
            if self.sw.command_rest(text)[1].strip() or self.sh_cwd(d) == unknown_dir:
                return None
            ctx = self.shell
            while ctx is not None:
                if git is not None and any(n.startswith("GIT_") for n in list(ctx["exported"]) + list(ctx["pending"])):
                    return None
                ctx = ctx.get("parent")
            if git is not None:
                if any(n in os.environ for n in GIT_PLACES):
                    return None  # git_out leaves these out, and the command itself would not
                return self.git_file_printed(*git, d)
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

        def system_program(self, word, name, text, scripts=True):
            """Whether the program the shell would run for word, the first word of the command text
            as worked out and name its last part, is for certain the system's own of that name
            (module docstring, "The program"). The one judgement of that for the whole gate
            (claude-config#3440): every reading of what a program prints, copies or writes by its
            name asks it, here (exact_output, believed, copy_believed), so the forms it takes and
            the forms it leaves have one home. By a path, only in a folder the gate takes for the
            system's. By its bare name, only where nothing says the shell may find another: the
            session's PATH, PATH named in a text that runs the command, a word in front that runs
            it for the shell. Never where a text that runs the command defines a function or an
            alias of the name.

            The shell's own builtins (BUILTINS) by their bare names are not looked for on PATH at
            all, so for those only the function and the alias are asked.

            scripts False leaves out one thing: PATH named in the text of a script on DISK. It
            is passed for the readings of printf, echo, cat, tee and the copiers, and only for
            them. 160 of this repository's 315 suites name PATH somewhere, most of them make a
            file with cat or cp and then run it, and with that text counted the gate refused the
            run of its own suite, of tests/test-mods.sh and of test-scanners-before-push.sh (8
            cases of test-slack-drafts-only-gate.sh, 2026-11-22). A script on disk is read by the
            gate before it runs, and a post built inside one is outside what the gate answers
            (the gate's note_unreadable says the same of a path it cannot work out there). PATH
            named in the command line that was typed still counts, for the line and for every
            script it runs."""
            bare = "/" not in word
            builtin = bare and name in BUILTINS
            if not bare and os.path.dirname(word) not in system_bin:
                return False
            if bare and not builtin and not self.exact_session_path():
                return False
            # A file this call wrote where the shell finds the program is not the system's (#3837).
            # A builtin by its bare name is not looked for in any folder.
            if not builtin and self.written_program(word, name, bare):
                return False
            # A text that begins with the program's own word has no word in front of it, so the
            # shared reader is asked only of the others: asked of every cat and cp of a long
            # script, it took judging `bash tests/test-claude-sync.sh` past its cost limit
            # (62.1 units against 57.0, test-slack-drafts-only-gate.sh, 2026-11-22).
            head = text.lstrip()
            begins = head.startswith(word) and head[len(word):len(word) + 1] in ("", " ", "\t", "\n")
            if not builtin and not begins and self.exact_run_for_it(text):
                return False
            ctx = self.shell
            while ctx is not None:
                if self.exact_shadowed(ctx["text"], name):
                    return False  # a function or an alias of that name is not the program
                if ctx.get("sourced") and self.sourced_shadow(ctx["sourced"], name):
                    return False  # nor is one a file this text sourced defines (#3837)
                if bare and not builtin and (scripts or not ctx.get("on_disk")) \
                        and self.exact_names_path(ctx["text"]):
                    return False
                ctx = ctx.get("parent")
            return True

        def believed(self, pieces, word, name, text):
            """pieces, what the program named name is read as printing or writing (the gate's
            sh_prints, tee's input), as far as they may be believed (claude-config#3440):
            themselves where the program the shell would run is for certain the system's own
            (system_program), and with one unreadable piece after them where it is not. The
            pieces are kept, so a post in what the system's program would have written is still
            found, and the piece after them leaves the file or the pipe one the gate could not
            read: `./cat calm.sh > run.sh; bash run.sh` with a script called cat in the folder
            was read as calm.sh and allowed (seen on a49e2ec940, 2026-11-22). None stays None,
            and is answered first, so a program the gate reads nothing of costs nothing here."""
            if pieces is None or self.system_program(word, name, text, scripts=False):
                return pieces
            return list(pieces) + [("unknown", None, self.not_the_systems(name))]

        def copy_believed(self, name, args, vals, d, text):
            """After the gate's note_writes has read a cp, mv, ln, install or link by its sources:
            where the program is not certain to be the system's (system_program), each word of
            it that can be the file it writes, and every file under one that is a folder, holds
            something the gate could not read from here on, beside what the system's program
            would have copied there, so a post in the source is still found. In a command line
            that was typed, each other file it names may have been written, as a file named to
            any program the gate does not know may (note_named in lib/program-writes.py)."""
            if self.system_program(vals[0], name, text, scripts=False):
                return
            label = self.not_the_systems(name)
            on_disk = self.shell.get("on_disk")
            for i, (a, v) in enumerate(zip(args[1:], vals[1:]), 1):
                if v is not None and v.startswith("-"):
                    continue
                if v is None or self.copy_target_may_be(name, args, vals, i):
                    self.note_unreadable(a, v, d, label, copier=True)
                    if v is not None:
                        under = glob.escape(os.path.realpath(self.resolve(v, d)).rstrip("/")) + "/*"
                        self.made_unknown.append((under, "" if on_disk else label))
                elif not on_disk:
                    self.note_named(a, v, d, label)

        @staticmethod
        def not_the_systems(name):
            """What a refusal says wrote a file, for a program not certain to be the system's."""
            return f"{name}, which is not certain to be the system's own {name}"

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
                # The functions of a text and its lines that hold an alias are found once for the
                # text, not once for each name: since claude-config#3440 this is asked of echo,
                # printf, cat, cp and the rest too, and tests/test-claude-sync.sh is 1.8 MB (its
                # cost case read 62.1 and 63.5 units against 57.0 with the search made per name).
                # With every name in front of empty brackets, which sh_funcs sees only at the start
                # of a line (named_anywhere, claude-config#3837).
                funcs = self.exact_once(("functions", text), lambda: self.sh_funcs(text) | named_anywhere(text))
                aliases = self.exact_once(("alias lines", text), lambda: "\n".join(ALIAS_LINE.findall(text)))
                memo[key] = name in funcs or bool(aliases and re.search(ALIAS % re.escape(name), aliases))
            return memo[key]

        def note_sourced(self, path):
            """Called by the gate's script() for each file a source or . command reads: the text
            being read gains the file, for sourced_shadow, since what a sourced file defines stays
            defined for the commands after it. A file sourced by a sourced file is kept against
            that file as well, so it is found again where the outer file's reading was kept from an
            earlier read and its commands are not walked a second time (the gate's clean)."""
            real = os.path.realpath(path)
            if not isinstance(self.shell, dict):
                return
            self.shell.setdefault("sourced", []).append(real)
            ran = self.shell.get("ran")
            if ran and ran[1] is None:  # the text being read is itself a sourced file's
                nested = self.__dict__.setdefault("_exact_nested", {})
                nested.setdefault(os.path.realpath(ran[0]), []).append(real)
                # How many such there are, for sourced_shadow, which keeps its answer while none is added.
                self.__dict__["_exact_nested_count"] = self.__dict__.get("_exact_nested_count", 0) + 1

        def sourced_shadow(self, paths, name):
            """Whether one of the sourced files paths, or a file one of them sources, defines a
            function or an alias called name (claude-config#3837). Each is read as the gate reads
            any file, so one an earlier command of this call wrote is read as what was written.

            The answer is kept for the files and the name while nothing it was worked out from has
            changed: the files sourced so far (paths, and how many a sourced file sources), what
            this call wrote each file read from (the gate's made, by the very list it holds), and
            how much the gate has noted of folders copied, paths not worked out, programs that may
            write and git (written_counts). This is asked once for every command of a text whose
            program the gate reads by its name, and worked out each time it reads the gate's whole
            record of what the call wrote for every sourced file, which over a long script is a
            measurable part of the gate's time budget."""
            nested = self.__dict__.get("_exact_nested", {})
            memo = self.__dict__.setdefault("_exact_sourced_shadow", {})
            key = (tuple(paths), name)
            stamp = (self.__dict__.get("_exact_nested_count", 0),) + self.written_counts()[1:]
            # Never with a folder copied: a file under one is read as the file it was copied from,
            # which is not among the files kept here.
            kept = None if self.made_dirs else memo.get(key)
            if kept and kept[1] == stamp and all(self.made.get(real) is was and (was is None or len(was) == n)
                                                 for real, (was, n) in kept[2]):
                return kept[0]
            seen, todo, answer = {}, list(paths), False
            while todo:
                real = todo.pop()
                if real in seen:
                    continue
                was = self.made.get(real)
                seen[real] = (was, None if was is None else len(was))
                text = self.sourced_text(real)
                if text is None or (text and self.exact_shadowed(text, name)):
                    answer = True  # one the gate could not read whole may define anything
                    break
                todo.extend(nested.get(real, ()))
            memo[key] = (answer, stamp, tuple(seen.items()))
            return answer

        def sourced_text(self, real):
            """The text of a sourced file, read once unless this call wrote it. "" only for one
            that is not there and that nothing in this call wrote, which a shell sources nothing
            from. None for one the gate could not read, or could not read whole: one that is there
            and cannot be opened, one past SOURCED_MAX, and one this call wrote where any part of
            what it was written from is not text the gate holds or a file it can open (a copy of a
            file it cannot open reads as nothing, which is not the same as holding nothing). A
            shell may still read such a file, so sourced_shadow takes it to define a function of
            any name, and the program is doubted, never believed."""
            made = self.made_from(real)

            def work():
                for kind, value, _ in made or ():
                    if kind == "text":
                        continue
                    if kind != "file" or not os.path.isfile(value) or not os.access(value, os.R_OK):
                        return None
                try:
                    data = self.content(real, limit=SOURCED_MAX + 1)
                except (OSError, ValueError):
                    return None if made is not None or os.path.lexists(real) else ""
                return None if len(data) > SOURCED_MAX else data.decode("utf-8", "replace")
            return work() if made is not None else self.exact_once(("sourced text", real), work)

        def written_counts(self):
            """How much the gate has noted of what this call wrote, as one value to compare: the
            files written by name, then the folders copied, the paths not worked out, the programs
            that may write, the code that names files and the git commands. Each only ever grows."""
            return (len(self.made), len(self.made_dirs), len(self.made_unknown), len(self.made_maybe),
                    len(self.made_code), len(self.made_git))

        def written_program(self, word, name, bare):
            """Whether an earlier command of this call wrote, or may have written, the file the
            shell would run for word (claude-config#3837): the path itself, or for a bare name a
            file called name in a folder of the session's PATH or of the gate's SYSTEM_BIN. Asked
            of the gate's own record of what the call wrote (made_from), which is empty for most
            calls and answers at once then. For a bare name the folders are searched once for each
            name while that record is as it was (written_counts). Where only the files written by
            name have grown, and none of them is the file a folder would hold for the name, the
            answer stands as well: a long script writes a file by name every few commands, and
            searching every folder again after each one reads the same record over and over."""
            if not (self.made or self.made_dirs or self.made_unknown or self.made_maybe or self.made_code
                    or self.made_git):
                return False
            if not bare:
                return self.made_from(word) is not None
            memo = self.__dict__.setdefault("_exact_written_program", {})
            counts = self.written_counts()
            kept = memo.get(name)
            if kept is None:
                folders = set(system_bin) | {e for e in (os.environ.get("PATH") or "").split(os.pathsep)
                                             if os.path.isabs(e)}
                places = [os.path.join(folder, name) for folder in sorted(folders)]
                # As made_from finds a file written by name: by the path with every link followed.
                kept = memo[name] = [None, None, places, {os.path.realpath(place) for place in places}]
            if kept[1] == counts:
                return kept[0]
            # With a folder copied, a file under it is read as the file it was copied from, which a
            # later write by name can be, so there the folders are searched again.
            if kept[0] is False and not self.made_dirs and kept[1][1:] == counts[1:] \
                    and not any(real in self.made for real in kept[3]):
                kept[1] = counts
                return False
            kept[0] = any(self.made_from(place) is not None for place in kept[2])
            kept[1] = counts
            return kept[0]

        def exact_once(self, key, work):
            """work()'s answer for key, worked out once: each of the three askings below depends
            only on its key, and is made again for every sed and git command of a long script."""
            memo = self.__dict__.get("_exact_once")
            if memo is None:
                memo = self.__dict__["_exact_once"] = {}
            if key not in memo:
                memo[key] = work()
            return memo[key]

        def exact_session_path(self):
            """Whether every folder of the session's own PATH, as the gate has it, is a whole path.
            An empty entry or a relative one names the folder the command runs in, or one under
            it, where a file called sed or git may be anything, an earlier command's included."""
            def work():
                path = os.environ.get("PATH")
                return bool(path) and all(os.path.isabs(entry) for entry in path.split(os.pathsep))
            return self.exact_once(("session path",), work)

        def exact_names_path(self, text):
            """Whether text names PATH at all: set, exported, added to, unset or only read. Where
            it does, which folders the shell searches when the command runs is not certain, and no
            attempt is made to tell a change that reaches the command from one that does not."""
            return self.exact_once(("names path", text), lambda: bool(PATH_NAMED.search(text)))

        def exact_run_for_it(self, text):
            """Whether a word in front of the command runs it for the shell (env, exec, sudo, nice,
            xargs and the rest of lib/shell-words.py's RUNNERS, which is the reading that says so).
            Such a word can change where the program is looked for (env -i, env PATH=, sudo's own
            PATH), so the command behind one is not read here."""
            def work():
                passed = []
                self.sw.command_rest(text, passed)
                return bool(passed)
            return self.exact_once(("run for it", text), work)

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

        def git_file_printed(self, sub, front, after, d):
            """What `git show REV:PATH` and the two cat-file forms print, as one text piece, where
            REV is a hex object name that is no ref (module docstring); else None.

            sub, front and after are the one reading's answer for the command (lib/shell-words.py
            git_read): its subcommand, git's own options in front of that, and every word after
            it. What is decided here is only this library's own: which of git's options leave the
            object it names the same (--no-pager, then -C and its folder, and nothing else), and
            which subcommands print one object whole. A word that reading passed over as a
            redirection is among the words after, so a count of them that fits is a command
            holding none."""
            k = 1 if front[:1] == ["--no-pager"] else 0
            where = self.resolve(".", d)
            if front[k:k + 1] == ["-C"] and len(front) > k + 1:
                where = self.resolve(front[k + 1], d)
                k += 2
            if len(front) != k:
                return None  # another option of git's own, or these two the other way round
            if sub == "show" and len(after) == 1:
                spec = after[0]
            elif sub == "cat-file" and len(after) == 2 and after[0] in ("-p", "blob"):
                spec = after[1]
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
