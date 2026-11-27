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
        self.bare = {}  # {name: [(start, end)]} of each bare `local NAME` in a body, filled with sets
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
DECLARES = r"(?:local|declare|typeset)"
BARE_LOCAL = re.compile(DECLARES + r"((?:\s+[A-Za-z_]\w*)+)")
# A value that is none: `local kept=`, `local kept=""`, `kept=''`. It names no file.
EMPTY = ("", '""', "''")


def body_sets(judge, k):
    """{name: [(start, end, value as written)]} for each NAME=value or local NAME=value command in
    a function body of the text being read, in the order written, or False where the text cannot
    be read. One pass over the text's commands, made the first time a name is asked about."""
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
            if "=" not in t:
                # A bare `local NAME` in a body declares the name there and gives it no value, and
                # so does a bare declare or typeset.
                declares = "local" in t or "declare" in t or "typeset" in t
                bare = BARE_LOCAL.fullmatch(judge.sh_strip_openers(t).strip()) if declares else None
                for name in bare.group(1).split() if bare else ():
                    k.bare.setdefault(name, []).append((p["start"], p["end"]))
                continue
            set_here = judge.sh_assignment(re.sub(r"^" + DECLARES + r"\s+", "", judge.sh_strip_openers(t).strip()))
            if set_here:
                k.sets.setdefault(set_here[0], []).append((p["start"], p["end"], set_here[1]))
    return k.sets


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
        # Where every value written is none, the answer is the one it was.
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

    def var(name):
        v = judge.sh_source_var(name)
        if v is None:
            v = body_value(judge, name)
            if v is not None:
                taken.append(name)
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
    judged again (own_again)."""
    taken = []
    wider = judge.sh_placed(text, d, taken)
    if not wider or wider == placed or own_again(judge, wider, d):
        return None
    reason = judge_again(wider)
    if not reason or not taken:
        return reason
    ctx = judge.shell
    where = f"the script {ctx['script']}" if ctx["script"] else "this command"
    if ctx["at"] is not None and ctx["script"]:
        where += f", {judge.line_place(ctx, ctx['at'])},"
    named = " and ".join("$" + n for n in sorted(set(taken)))
    # Through unfollow, so main() says the check could not be made rather than claiming a post.
    return judge.unfollow(f"{where} runs a file through {named}, whose value the gate cannot follow to that "
                          "command: only a function of the same text sets it, and read with the value set "
                          f"there, {reason}")
