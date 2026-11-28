"""A file run through a variable in a shell function, for the Slack drafts gate (claude-config#3497).

judge() reads a command as it is written and then, where that finds nothing, with each word whose
value the walk of the text's variables holds for certain written out (sh_placed, #2678). Two
things kept a function's commands out of that second reading:

  * a function runs wherever it is called from, so the walk vouches for no directory inside a
    body, and a value that is a relative path was left as the word the script wrote, which names
    no file. `run() { kept=posts.sh; bash "$kept"; }; run` ran a script nothing had read, where
    the same two commands at the top level were refused, and so was `bash posts.sh` written out in
    that body, which is read against the directory the reader follows (measured 2026-11-22 at
    8b4e006b0f, and 2026-11-26 on main at 6c4cee7247);
  * a call of a function leaves every name its body binds unknown to the walk, so a value set in a
    body was never one the commands after the call, or another function's, could be read with:
    `run() { kept=posts.sh; }; run; bash "$kept"`.

wider_reason is a third reading, made after the second and only where that found nothing too, so
it can only refuse more. In it a value worked out inside a function body is written out whatever
the directory, and read where the same path written out in that body is; and a name the walk holds
no value for at the command is given the one value a function body of the text sets it to. That
second kind is no certain value, since the function may not have run yet, so a refusal found with
it is worded as a check the gate could not make, never as a post it found (L11).

Not read by it: a name several bodies set to different values, a name anything else in the text
binds (the walk gives no value in a body for one: an assignment at the top level, a read, a
for, a local, declare or typeset with an option; a bare `local NAME`, `declare NAME` or `typeset
NAME` in a body is not counted, nor is a value that is none, as in `local NAME=""`,
body_value_read), and a function called after a cd, whose relative path is then read against the
directory the reader follows, as one written out is.

Some names are read both ways: with the value, and with the name empty (empty_reason). They are
a name a body gives an empty value (`config=`, `local config=""`), a name a declare or typeset
declares in a body, bare or with a value, and a name declared in a declaration of several names
that gives one of them a value (both_ways). Those are the spellings this file has taken since
010c05a1b0, which read none of them. The value a body gives is not always the one the command gets: the shell hands it
the empty one wherever an empty assignment is the last to run, wherever the command stands
before the declaration, and wherever the declaring function is another one, whose name is local
to it. Read with the value alone, `$runner $config posts.sh` was a quiet script handed a file,
where the shells run posts.sh (third review of #3497, 2026-11-27). A command read through
several such names is read once for every combination of them empty, the others keeping their
values, for up to MOST_BOTH names. Past that it is read with all of them empty and no other
way, and refused whatever that reading finds, in that reading's words where it found a reason
(fifth review, same day: a1d8b23c36 refused it before that reading too). Read only with all of
them empty at once, `$runner $config posts.sh` with both names declared empty was the one word
posts.sh, which finds nothing, where the shells run it whenever the runner has its value and
config has none (fourth review, same day). Which of the two a name has at the command is not
worked out, so this refuses quiet commands too. One is a command where the file after the
name posts and the name is never empty when the command runs. The other is a typed command
where nothing stands after the unquoted name (`local script=""`, `script=quiet.sh`, `bash
$script`): read with the name empty it is a bare shell reading its input, which the gate
refuses in a typed function. That function in a script file passes, and so does the name in
double quotes. A plain assignment, a `local NAME=value` and a bare `local NAME` are read one
way, as they were at 010c05a1b0. Not covered for those three: a name used on a line before
the one that sets it, or in a function other than the one that sets it, and a name whose
assignment is not reached where the command runs (under a condition that is false, in a
subshell, a pipeline, a background job, a loop that does not run, a case arm not taken or a
substitution). Nor is `local kept=quiet.sh other=$kept`, where the shell leaves other empty
and the reading gives it kept's value.

What it reads is read with the directory unknown, as every command of a function is. So a quiet
script that finds its own folder from BASH_SOURCE and sources a file beside it, run through a
variable a function sets, is refused as a check the gate could not make, where main allows it:
`run() { local t; t=sub/tool.sh; bash "$t"; }; run`, and the same with `local t=sub/tool.sh`
(the two reviews of #3497, 2026-11-27). Each spelling this file comes to read widens that.

Nor is one command read by it: a shell handed the script being read, and nothing else
(own_again). A suite that runs itself inside a function (`sc_run(){ ... bash "${BASH_SOURCE[0]}"
2>&1; }` in test-pipefail-shortcircuit.sh) was read a second time as a file it runs, with the
directory unknown, as it is for every command of a function, so the path on the suite's own first
source line, built from `cd ... && pwd` on its BASH_SOURCE, could not be worked out there, and the
command that runs the suite was refused: 4 of this Mac's 61,284 recorded commands, none refused on
main (measured 2026-11-26 at 47094abfaa). That second reading is of the text being read, by the
same shell, from the same folder, handed nothing, with nothing written or exported since the first
began, so it holds no command the first does not judge. It is left out only here, in the reading
this file adds: the same script named by a literal path in a function is the first reading's, and
is refused as it is on main.

Each function takes the gate's Judge as its first argument: these are its readings, kept out of
slack_drafts_only_gate.py only so that file does not grow.
"""
import bisect
import os
import re
import shlex


class Kept:
    """What this file works out once for one walk's result (sh_ctx_known), kept on the gate's Judge
    for the run: where the text's function bodies are, which names its bodies set and where, and
    the value each name asked about was given. Without it every name of every command was worked
    out afresh over every command of the text, and one claude-sync lesson, judged in 2.7 seconds
    of processor time on main, ran out of the gate's 11 seconds (measured 2026-11-26, the first
    build of this change)."""

    def __init__(self, known):
        self.known = known
        spans = sorted(known["bodies"])
        self.starts, self.reach, most = [a for a, _ in spans], [], None
        for _, b in spans:
            most = b if most is None or b > most else most
            self.reach.append(most)
        self.sets = None  # {name: [(start, end, value as written)]}, False where the text is not read
        # {name: [(start, end)]} of each declaration in a body that gives the name no value (a bare
        # local, declare or typeset, or the name beside another in one), filled with sets
        self.bare = {}
        self.both = set()  # the names a declaration read both ways declares (declared), filled with sets
        self.empty = ()  # the names read as empty in the reading under way (empty_reason)
        self.values = {}

    def inside(self, at):
        """Whether offset at of the text stands in a function body, found by bisection."""
        k = bisect.bisect_right(self.starts, at)
        return bool(k) and self.reach[k - 1] > at


def kept(judge):
    """The Kept of the text being read."""
    known = judge.sh_ctx_known()
    memo = judge.__dict__.setdefault("function_values_kept", {})
    got = memo.get(id(known))
    if got is None or got.known is not known:
        got = memo[id(known)] = Kept(known)
    return got


def in_body(judge):
    """Whether the command being read stands in a function body of the text being read."""
    at = judge.shell["at"]
    return at is not None and kept(judge).inside(at)


# The gate's SH_UNKNOWN_DIR, which it sets here once it has loaded this file.
UNKNOWN_DIR = None
# A command that only declares names local to a function: `local kept`, `local a b`, and the same
# with declare or typeset, which in a function declare a name as local does. One with an option
# (`local -a kept`) or a value is not this.
DECLARES = r"(local|declare|typeset)"
BARE_LOCAL = re.compile(DECLARES + r"((?:\s+[A-Za-z_]\w*)+)")
# A declaration of more than one thing, some with values: `local other kept=`, `local a=1 b=2`.
DECLARATION = re.compile(DECLARES + r"\s+(\S.*)", re.S)
NAME = re.compile(r"[A-Za-z_]\w*")
# A value that is none: `local kept=`, `local kept=""`, `kept=''`. It names no file.
EMPTY = ("", '""', "''")
# The declarations whose names are read both ways (empty_reason), bare or with a value. Not
# local: a `local NAME=value` is the walk's to read and a bare local has been read one way since
# b7abbef4d6, and what that leaves open is in the module docstring.
BOTH = ("declare", "typeset")
# A plain $NAME or ${NAME}, which is nothing at all where the name is empty.
PLAIN = re.compile(r"\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))")
# What an empty word is written as in the reading with a name empty. The shell hands the command
# an empty word for `"$NAME"`, which names no file, so the command fails to open it and runs
# nothing through it. Written as `""` the gate reads `bash ""` as a bash with no script, reading
# its input, and refuses it in a function (as main does, typed out). A path under /dev/null can
# name no file either, and is read as one that names none.
NO_FILE = "/dev/null/empty-word"
# The most names read both ways that one command is read every way for (empty_reason). The
# readings double with each name: 3 for two names, 15 for four, 63 for six. A command through
# more of them is refused, quiet or not, since a reading left out is one that could post: it
# is read with all of them empty, the one reading made before there was a bound, and where
# that finds nothing the refusal is TOO_MANY. Six is where the time stays small beside the
# gate's one allowance of 11 seconds: a typed function of 200 shell commands, each through six
# such names, was judged in 2.2 seconds against 0.5 before this reading was made (three runs
# each, one minute load 43, measured 2026-11-27), about 0.13 ms a reading, and each name more
# doubles that.
MOST_BOTH = 6
TOO_MANY = (f"is more names than the gate reads every way (it reads at most {MOST_BOTH}, each with its value "
            "and empty), so this command was not read with only some of them empty (what clears this is at "
            f"most {MOST_BOTH} such names through each command: a name declared by a local line that gives no "
            "value, and given no empty value anywhere, is read one way and not counted, and the work can be "
            f"split into commands of at most {MOST_BOTH} such names each)")


def body_sets(judge, k):
    """{name: [(start, end, value as written)]} for each value a command in a function body of
    the text being read gives a name, in the order written, or False where the text cannot be
    read: a NAME=value, a local, declare or typeset NAME=value with no option, and each
    NAME=value of a declaration of several names. One pass over the text's commands, made the
    first time a name is asked about, which fills k.bare and k.both as well (declared)."""
    if k.sets is None:
        ctx = judge.shell
        try:
            cmds, parts = judge.parsed(ctx["text"], ctx["cwd"])
        except judge.sw.Unreadable:
            k.sets = False
            return False
        k.sets = {}
        for (_, t), p in zip(cmds, parts):
            if not k.inside(p["start"]):
                continue
            declares = "local" in t or "declare" in t or "typeset" in t
            if "=" not in t:
                # A bare `local NAME` in a body declares the name there and gives it no value, and
                # so does a bare declare or typeset.
                bare = BARE_LOCAL.fullmatch(judge.sh_strip_openers(t).strip()) if declares else None
                if bare:
                    declared(k, p, bare.group(1), bare.group(2).split(), ())
                continue
            head = judge.sh_strip_openers(t).strip()
            how = re.match(DECLARES + r"\s+", head) if declares else None
            set_here = judge.sh_assignment(head[how.end():] if how else head)
            if set_here:
                declared(k, p, how and how.group(1), (), [set_here])
                continue
            # A declaration of more than one thing: each word a NAME or a NAME=value. Read as one
            # command that sets one name it set none, so `local other kept=` counted as something
            # else that binds kept (third review of #3497). One with an option, or with a word
            # that is neither, is left as it was: not read.
            several = DECLARATION.fullmatch(head) if how else None
            names, sets = [], []
            for kind, raw in judge.sh_tokens(several.group(2)) if several else ():
                one = judge.sh_assignment(raw) if kind == "word" and "=" in raw else None
                if kind == "word" and NAME.fullmatch(raw):
                    names.append(raw)
                elif one:
                    sets.append(one)
                else:
                    several = None
                    break
            if several:
                declared(k, p, several.group(1), names, sets)
    return k.sets


def declared(k, p, word, names, sets):
    """Record one command of a body on k: the command at p, a local, declare or typeset (word; None
    for a plain assignment) that declares names with no value and gives each (name, value as
    written) pair of sets its value. Every name of a declare or typeset, and every name of a
    declaration of several names that gives one of them a value, is noted as read both ways
    (both_ways): each is a command 010c05a1b0 did not read, so a name it declares was left as
    written there, and a later file was read as what the command may run."""
    for name in names:
        k.bare.setdefault(name, []).append((p["start"], p["end"]))
    for name, value in sets:
        k.sets.setdefault(name, []).append((p["start"], p["end"], value))
    if word in BOTH or (sets and len(names) + len(sets) > 1):
        k.both.update(names)
        k.both.update(name for name, _ in sets)


def body_value(judge, name, depth=0):
    """The one value the function bodies of the text being read give name, or None: each value the
    walk found certain inside a body (sh_locals: a NAME=value or a local that nothing else in the
    text binds; and a value set at the top level that lasts into a body), where all of them agree.
    Where the walk found none, each NAME=value or local of name written in a body, worked out
    from what the walk holds where it stands and from these same values: the walk does not
    follow one value built from another inside a body (`dir=lib`, then `kept="$dir/posts.sh"`).
    Worked out once for each name of a text (Kept): nothing in it depends on where the command
    being read stands."""
    ctx = judge.shell
    if ctx["at"] is None or depth > 3 or not re.fullmatch(r"[A-Za-z_]\w*", name):
        return None
    k = kept(judge)
    if (name, depth) not in k.values:
        k.values[(name, depth)] = None  # a name whose value is built from itself finds none
        k.values[(name, depth)] = body_value_read(judge, k, name, depth)
    return k.values[(name, depth)]


def body_value_read(judge, k, name, depth):
    """body_value, worked out."""
    ctx, known = judge.shell, k.known
    values = {v for a, _, v in known["regions"].get(name, ()) if k.inside(a)}
    if not values and name + "=" in ctx["text"]:
        sets = body_sets(judge, k)
        if sets is False:
            return None
        found = sets.get(name, ())
        # A value that is none (`local kept=""`, `local kept=`) is a declaration: it names no
        # file, so it is no second value beside the one set on a line after it, the other ordinary
        # way to write a function. Counted as one, `run() { local kept=""; kept=posts.sh; bash
        # "$kept"; }; run` ran a script nothing had read (second review of #3497, 2026-11-27).
        # Where every value written is none, the answer is the one it was. The value is not the
        # whole of it: the empty one is what the command gets wherever it is the last to run, so
        # a command read through such a name is read with the name empty as well (empty_reason).
        named = [(a, w) for a, _, w in found if w not in EMPTY]
        for start, written in named or [(a, w) for a, _, w in found]:
            values.add(judge.sh_word(written, UNKNOWN_DIR, lambda x, at=start: judge.sh_home(
                x, ctx["text"], judge.sh_at(known, x, at)) or body_value(judge, x, depth + 1),
                ctx["script"], True)[0])
            if None in values or len(values) > 1:
                return None  # one value not worked out, or two that differ: no one value
        # Only then the dearer question, asked of the whole text less those commands: nothing else
        # in it may bind the name (a read, a for, an assignment outside a body). Asked as well for
        # every name whose one value was not worked out, it was 0.45 of the 3.06 seconds of
        # processor time one claude-sync lesson took, against 2.58 on main (measured 2026-11-26).
        # A bare `local NAME` in a body is no other value for it: the name is declared there and
        # set on a line after, the ordinary way to write a function, and `run() { local kept;
        # kept=posts.sh; bash "$kept"; }; run` ran a script nothing had read (review of #3497,
        # 2026-11-27). Left out of the text with the assignments, so it is not what else binds it.
        # Every bare local, declare or typeset of the name in any body of the text is left out,
        # wherever it stands: in another function, or after the assignment.
        if values:
            rest, upto = [], 0
            for start, end in sorted([(a, b) for a, b, _ in found] + k.bare.get(name, [])):
                rest.append(ctx["text"][upto:start])
                upto = max(upto, end)
            if judge.sh_binds(name, "".join(rest) + ctx["text"][upto:]):
                return None
    return values.pop() if len(values) == 1 else None


def wider_words(judge, taken):
    """(whether a relative value may be written out whatever the directory, the reading of a name)
    for sh_placed: its own, where taken is None; and with taken, a list, the wider reading, which
    adds to that list each name it gives a function body's value."""
    if taken is None:
        return False, judge.sh_source_var

    empty = kept(judge).empty

    def var(name):
        v = judge.sh_source_var(name)
        if v is None:
            v = body_value(judge, name)
            if v is not None:
                taken.append(name)
                v = "" if name in empty else v  # the reading with the name empty (empty_reason)
        return v
    return in_body(judge), var


# What a word holds where the shell works it out as it runs: a variable, a substitution of either
# kind, or a process substitution.
WORKED = re.compile(r"[$`()]")


def chain(path):
    """The names a path goes through, in order, with each "." and doubled slash left out, or None
    where one of them is "..". Two paths with one chain are one file reached one way, so the folder
    beside each is the same folder. Two paths with one real path need not be: a symlink to a script
    from another folder runs that script with another folder's lib beside its BASH_SOURCE."""
    names = [n for n in path.split("/") if n not in ("", ".")]
    return None if ".." in names else names


def own_again(judge, wider, d):
    """Whether the command wider, a command as the wider reading wrote it out, does nothing but run
    the script being read once more, as the reading under way reads it (module docstring). Every
    part of that is asked, and the command is read as before where any is not so:

      * the text being read is a script on disk that a command ran (not a sourced file, a string
        or the command line), and the shell reading it is known;
      * the command stands in the folder that script was started in, nothing has been exported
        for Python since, and no earlier command of the call wrote, built or checked out a file
        (the same list a script found clean is kept under, script()): after any of those the
        script's own commands can name other files than they did the first time;
      * its words are a shell and one file, each written out, with nothing but a redirection of
        what it prints: a word handed to the script is a file it may run, and its input is code a
        shell may read;
      * that shell is the one reading the script, by the gate's own naming of it (reading_shell);
      * the file is the script by the same chain of names (chain), not only the same real path."""
    ctx = judge.shell
    ran = ctx.get("ran")
    if not ran or ran[1] is None or not ctx.get("on_disk") or not ctx.get("program"):
        return False
    if (d or "") != (ctx["cwd"] or "") or judge.exported is not None:
        return False
    if (judge.made or judge.made_dirs or judge.made_unknown or judge.made_maybe or judge.made_code
            or judge.made_git or judge.made_built):
        return False
    words, toks, i = [], judge.sh_tokens(wider), 0
    while i < len(toks):
        kind, raw = toks[i]
        if kind == "op":
            # Only a redirection of its output, to a place no command works out as it runs.
            if ">" not in raw or "<" in raw or i + 1 >= len(toks) or re.search(r"[`()]", toks[i + 1][1]):
                return False
            i += 2
            continue
        try:
            word = [] if WORKED.search(raw) else shlex.split(raw)
        except ValueError:
            return False
        if len(word) != 1:
            return False
        words.append(word[0])
        i += 1
    if len(words) != 2 or judge.reading_shell(os.path.basename(words[0]), False, "") != ctx["program"]:
        return False
    mine, theirs = judge.resolve(ran[1], ctx["cwd"]), judge.resolve(words[1], d)
    return chain(mine) is not None and chain(mine) == chain(theirs) and os.path.realpath(theirs) == ran[0]


def wider_reason(judge, text, d, placed, judge_again):
    """The reason the command text posts when read with a function's values written out, or None.
    placed is the second reading's text, which this one is not made again for; judge_again(text)
    judges a command as written. A command that only runs the script being read once more is not
    judged again (own_again). Where that reading finds nothing and took names read both ways
    (both_ways), the command is read again with those names empty, once for every combination
    of them (empty_reason). Which of the two a name has at the command is not worked out, so a
    reason found that way is worded as a check the gate could not make too (L11), in words of
    its own, which name every such name of the command and then the ones read empty."""
    taken = []
    wider = judge.sh_placed(text, d, taken)
    if not wider or wider == placed:
        return None
    reason = None if own_again(judge, wider, d) else judge_again(wider)
    if not taken:
        return reason
    empty, emptied = (), ()
    if not reason:
        empty, emptied, reason = empty_reason(judge, text, d, (placed, wider), taken, judge_again)
        if not reason:
            return None
    ctx = judge.shell
    where = f"the script {ctx['script']}" if ctx["script"] else "this command"
    if ctx["at"] is not None and ctx["script"]:
        where += f", {judge.line_place(ctx, ctx['at'])},"
    named = " and ".join("$" + n for n in sorted(empty or set(taken)))
    # Through unfollow, so main() says the check could not be made rather than claiming a post.
    if empty:
        what = "a name" if len(empty) == 1 else "names"
        told = (f"{where} runs a command through {named}, {what} a function of the same text also declares or "
                "leaves empty, so the gate cannot tell whether the command gets the value set there")
        if reason is TOO_MANY:
            return judge.unfollow(f"{told}: {len(empty)} {reason}")
        return judge.unfollow(f"{told}: read with {' and '.join('$' + n for n in sorted(emptied))} empty, {reason}")
    return judge.unfollow(f"{where} runs a file through {named}, whose value the gate cannot follow to that "
                          "command: only a function of the same text sets it, and read with the value set "
                          f"there, {reason}")


def both_ways(judge, k, names):
    """Those of names read both ways (module docstring): one a function body of the text gives an
    empty value (`kept=`, `local kept=""`), one a declare or typeset declares there, bare or with
    a value, and one declared in a declaration of several names that gives one of them a value
    (declared). All of them where the text's commands cannot be read, since what a body does to
    a name is then not known."""
    sets = body_sets(judge, k)
    if sets is False:
        return set(names)
    return {n for n in names if n in k.both or any(w in EMPTY for _, _, w in sets.get(n, ()))}


def without(text, names):
    """text with each plain $NAME and ${NAME} of names taken out, which is how the shell reads the
    command where those names are empty: `$how $kept posts.sh` is `$how posts.sh`, and
    `${kept}posts.sh` is `posts.sh`. A $ inside single quotes or after a backslash is only text.
    Every other form (${NAME:-word}) is left for the reading, which is given the empty value."""
    out, i, n, dq = [], 0, len(text), False
    while i < n:
        c = text[i]
        if c == "\\":
            out.append(text[i:i + 2])
            i += 2
            continue
        if c == "'" and not dq:
            j = text.find("'", i + 1)
            j = n if j < 0 else j + 1
            out.append(text[i:j])
            i = j
            continue
        if c == '"':
            dq = not dq
        elif c == "$":
            m = PLAIN.match(text, i)
            if m and (m.group(1) or m.group(2)) in names:
                i = m.end()
                continue
        out.append(c)
        i += 1
    return "".join(out)


def no_empty_words(judge, text):
    """text, one command, with each word that is empty (two quotes and nothing in them) written
    as NO_FILE."""
    if '""' not in text and "''" not in text:
        return text
    return " ".join(NO_FILE if kind == "word" and not raw.replace('""', "").replace("''", "") else raw
                    for kind, raw in judge.sh_tokens(text))


def combinations(order, size):
    """Every way of taking size of order's items, each as a tuple in order's own order, the
    earliest positions first: what itertools.combinations(order, size) gives, in the same order."""
    if size == 0:
        yield ()
        return
    for i in range(len(order) - size + 1):
        for rest in combinations(order[i + 1:], size - 1):
            yield (order[i],) + rest


def empty_reason(judge, text, d, seen, taken, judge_again):
    """(the names of taken that are read both ways (both_ways), those of them the reading that
    found a reason had empty, that reason or None). Made only where the reading with the values
    found nothing, and judged as a command written out is: seen are the texts already judged.

    Which of those names the command gets empty is not worked out, and it need not be all of
    them or none: the shell hands `$how $kept posts.sh` to bash wherever how has its value and
    kept is empty. So the command is read once for every combination of them empty, the others
    keeping their values: all of them first, which was the only reading until the fourth review
    of #3497 (2026-11-27), then one at a time, then every other combination. All of them at
    once leaves the one word `posts.sh` of that command, which finds nothing, and one at a time
    misses `$how $one $two posts.sh` where one and two are empty. The first reason found is the
    answer. Past MOST_BOTH names only the first reading is made, all of them empty, so a reason
    it finds keeps its words, which name the file that posts. Where it finds none the answer
    is TOO_MANY, a reason, never None: the readings left unmade are ones that could post. From
    a1d8b23c36 until the fifth review of #3497 (the same day) the bound stood before that first
    reading as well."""
    k = kept(judge)
    names = both_ways(judge, k, set(taken))
    if not names:
        return names, names, None
    judged, order, over = {text, *seen}, sorted(names), len(names) > MOST_BOTH
    further = [] if over else [set(c) for size in range(1, len(order)) for c in combinations(order, size)]
    for some in [names] + further:
        bare = without(text, some)
        k.empty = some
        try:
            second = no_empty_words(judge, judge.sh_placed(bare, d, []) or bare)
        finally:
            k.empty = ()
        if second in judged:
            continue
        judged.add(second)
        reason = judge_again(second)
        if reason:
            return names, some, reason.replace(NO_FILE, "an empty word")
    return names, names, TOO_MANY if over else None
