"""Shared command scanner for the `gh issue create` completeness gates.

Two PreToolUse gates need the same hard part: given the raw Bash command about to
run, find the real `gh issue create` invocations in it and read their flags. That
parsing is fiddly (quotes, heredocs, line continuations, shell operators, env
assignment prefixes) and was written once for the milestone gate. The priority
gate needs it identically, so it lives here rather than as a second copy that
drifts: a fix to the splitting logic must reach both gates at once.

Every gate keeps its own rule and its own message. This module only answers "which
creates are in this command, what flags do they carry, and was each one waived".

Both gates fail OPEN: anything unparseable is not ours to judge. These are
completeness gates, not safety gates, and a false block on a command we merely
could not read would teach the override habit.
"""

import re
import shlex

OPERATORS = {"&&", "||", ";", "|", "&", "(", ")", "{", "}", "\n"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def normalize(cmd):
    """Make command boundaries visible to the lexer, quote awarely.

    A plain newline starts a new command, so it becomes ';'. A backslash before a
    newline continues one command, so it becomes a space. A heredoc body is data,
    not commands, so it is dropped whole. Text inside quotes is copied untouched.

    Without this the gate saw only the first line of a multi-line command: a
    newline is plain whitespace to shlex, so a create on line 3 was invisible.
    """
    out = []
    i, n = 0, len(cmd)
    quote = None
    while i < n:
        c = cmd[i]

        if quote:
            if c == "\\" and quote == '"' and i + 1 < n:
                out.append(c)
                out.append(cmd[i + 1])
                i += 2
                continue
            out.append(c)
            if c == quote:
                quote = None
            i += 1
            continue

        if c == "\\" and i + 1 < n:
            if cmd[i + 1] == "\n":
                out.append(" ")  # line continuation: one logical command
            else:
                out.append(c)
                out.append(cmd[i + 1])
            i += 2
            continue

        if c in ("'", '"'):
            quote = c
            out.append(c)
            i += 1
            continue

        if c == "\n":
            out.append(" ; ")
            i += 1
            continue

        if cmd.startswith("<<", i) and not cmd.startswith("<<<", i):
            j = i + 2
            if j < n and cmd[j] == "-":
                j += 1
            while j < n and cmd[j] in " \t":
                j += 1
            q = None
            if j < n and cmd[j] in ("'", '"'):
                q = cmd[j]
                j += 1
            start = j
            while j < n and (cmd[j] != q if q else cmd[j] not in " \t\n;&|)"):
                j += 1
            delim = cmd[start:j]
            if q and j < n:
                j += 1
            if not delim:
                out.append(c)
                i += 1
                continue
            # Skip the body, up to and including the line that closes it.
            k = cmd.find("\n", j)
            if k == -1:
                i = n
            else:
                k += 1
                while k < n:
                    e = cmd.find("\n", k)
                    line = cmd[k : (e if e != -1 else n)]
                    if line.strip() == delim:
                        k = (e + 1) if e != -1 else n
                        break
                    if e == -1:
                        k = n
                        break
                    k = e + 1
                i = k
            out.append(" ; ")
            continue

        out.append(c)
        i += 1
    return "".join(out)


def _is_operator(tok):
    return tok in OPERATORS or set(tok) <= set("&|;()")


def _is_gh(tok):
    return tok == "gh" or tok.endswith("/gh")


class Unreadable(Exception):
    """The command could not be tokenized, so no gate may judge it."""


def scan_creates(command, override=None):
    """Find every real `gh issue create` in a command string.

    Returns a list of (args, waived) pairs, one per create, where args are the
    tokens belonging to that create and waived says whether the override env
    assignment prefixed that specific command.

    A create only counts when `gh issue create` sits at the head of a segment
    (start of the command, or just after a shell operator, with leading env
    assignments skipped). That keeps quoted mentions and heredoc bodies from
    tripping a gate.

    Raises Unreadable when the command cannot be tokenized.
    """
    if not command or not command.strip():
        return []

    command = normalize(command)

    try:
        # punctuation_chars is a lexer option, not a split() argument: it makes the
        # shell operators separate tokens so a segment head can be recognised.
        # commenters is cleared so a '#' inside an issue title is not treated as a
        # comment and does not swallow the rest of the command.
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        lexer.commenters = ""
        tokens = list(lexer)
    except ValueError:
        raise Unreadable("unbalanced quotes")

    creates = []
    i = 0
    at_head = True
    # The override belongs to the ONE command it prefixes. Reading it across the
    # whole call is how an unmilestoned create slipped through on 2026-07-29: an
    # override on line 1 silently exempted a second create three lines later.
    seg_waived = False
    while i < len(tokens):
        tok = tokens[i]
        if _is_operator(tok):
            at_head = True
            seg_waived = False
            i += 1
            continue

        if at_head and ASSIGNMENT.match(tok):
            if override and tok == override:
                seg_waived = True
            i += 1  # env assignment prefix: still at the head
            continue

        if at_head and _is_gh(tok) and tokens[i + 1 : i + 3] == ["issue", "create"]:
            j = i + 3
            args = []
            while j < len(tokens) and not _is_operator(tokens[j]):
                args.append(tokens[j])
                j += 1
            creates.append((args, seg_waived))
            i = j
            at_head = True
            seg_waived = False
            continue

        at_head = False
        i += 1

    return creates


def flag_values(args, long_flag, short_flag=None):
    """Every value given to a flag in one create's argument list.

    Understands the four forms gh accepts: `--flag value`, `--flag=value`,
    `-f value` and `-fvalue`. A flag with no value, or one followed by another
    flag, contributes nothing, so an empty value can never satisfy a gate.
    """
    values = []
    i = 0
    n = len(args)
    while i < n:
        tok = args[i]

        if tok == long_flag:
            if i + 1 < n and args[i + 1].strip() and not args[i + 1].startswith("-"):
                values.append(args[i + 1])
                i += 2
                continue
            i += 1
            continue

        if tok.startswith(long_flag + "="):
            values.append(tok.split("=", 1)[1])
            i += 1
            continue

        if short_flag and tok == short_flag:
            if i + 1 < n and args[i + 1].strip() and not args[i + 1].startswith("-"):
                values.append(args[i + 1])
                i += 2
                continue
            i += 1
            continue

        # `-lbug`: an attached value. Guarded against swallowing a long flag that
        # happens to share the short flag's first letter (`--label` vs `-l`).
        if short_flag and not tok.startswith("--") and tok.startswith(short_flag) and len(tok) > len(short_flag):
            values.append(tok[len(short_flag) :])
            i += 1
            continue

        i += 1
    return values


def deny_payload(reason):
    """The PreToolUse response that blocks the tool call."""
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }


def plural_issues(count):
    """"1 issue" / "3 issues", for a message that reads correctly either way."""
    return "1 issue" if count == 1 else "{n} issues".format(n=count)
