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
binds (the walk gives no value in a body for one), and a function called after a cd, whose
relative path is then read against the directory the reader follows, as one written out is.

Each function takes the gate's Judge as its first argument: these are its readings, kept out of
slack_drafts_only_gate.py only so that file does not grow.
"""
import bisect
import re


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
            if "=" not in t or not k.inside(p["start"]):
                continue
            set_here = judge.sh_assignment(re.sub(r"^local\s+", "", judge.sh_strip_openers(t).strip()))
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
        for start, _, written in found:
            values.add(judge.sh_word(written, UNKNOWN_DIR, lambda x, at=start: judge.sh_home(
                x, ctx["text"], judge.sh_at(known, x, at)) or body_value(judge, x, depth + 1),
                ctx["script"], True)[0])
            if None in values or len(values) > 1:
                return None  # one value not worked out, or two that differ: no one value
        # Only then the dearer question, asked of the whole text less those commands: nothing else
        # in it may bind the name (a read, a for, an assignment outside a body). Asked as well for
        # every name whose one value was not worked out, it was 0.45 of the 3.06 seconds of
        # processor time one claude-sync lesson took, against 2.58 on main (measured 2026-11-26).
        if values:
            rest, upto = [], 0
            for start, end, _ in found:
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


def wider_reason(judge, text, d, placed, judge_again):
    """The reason the command text posts when read with a function's values written out, or None.
    placed is the second reading's text, which this one is not made again for; judge_again(text)
    judges a command as written."""
    taken = []
    wider = judge.sh_placed(text, d, taken)
    if not wider or wider == placed:
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
