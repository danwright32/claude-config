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
import re


def in_body(judge):
    """Whether the command being read stands in a function body of the text being read."""
    at = judge.shell["at"]
    return at is not None and any(a <= at < b for a, b in judge.sh_ctx_known()["bodies"])


# The gate's SH_UNKNOWN_DIR, which it sets here once it has loaded this file.
UNKNOWN_DIR = None


def body_value(judge, name, depth=0):
    """The one value the function bodies of the text being read give name, or None: each value the
    walk found certain inside a body (sh_locals: a NAME=value or a local that nothing else in the
    text binds; and a value set at the top level that lasts into a body), where all of them agree.
    Where the walk found none, each NAME=value or local of name written in a body, worked out
    from what the walk holds where it stands and from these same values: the walk does not
    follow one value built from another inside a body (`dir=lib`, then `kept="$dir/posts.sh"`)."""
    ctx = judge.shell
    if ctx["at"] is None or depth > 3 or not re.fullmatch(r"[A-Za-z_]\w*", name):
        return None
    known = judge.sh_ctx_known()
    bodies = known["bodies"]
    values = {v for a, _, v in known["regions"].get(name, ()) if any(x <= a < y for x, y in bodies)}
    if not values and re.search(r"(?<![\w$])" + name + "=", ctx["text"]):
        try:
            cmds, parts = judge.parsed(ctx["text"], ctx["cwd"])
        except judge.sw.Unreadable:
            return None
        rest, upto = [], 0
        for (_, t), p in zip(cmds, parts):
            if not any(x <= p["start"] < y for x, y in bodies):
                continue
            set_here = judge.sh_assignment(re.sub(r"^local\s+", "", judge.sh_strip_openers(t).strip()))
            if set_here and set_here[0] == name:
                values.add(judge.sh_word(set_here[1], UNKNOWN_DIR, lambda x, at=p["start"]: judge.sh_home(
                    x, ctx["text"], judge.sh_at(known, x, at)) or body_value(judge, x, depth + 1),
                    ctx["script"], True)[0])
                rest.append(ctx["text"][upto:p["start"]])
                upto = max(upto, p["end"])
        # Nothing else in the text may bind the name (a read, a for, an assignment outside a body).
        if values and judge.sh_binds(name, "".join(rest) + ctx["text"][upto:]):
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
