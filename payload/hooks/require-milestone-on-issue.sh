#!/usr/bin/env bash
# Block `gh issue create` unless the issue is assigned to a milestone.
#
# Why this exists: on 2026-07-29 Dan went through every project by hand attaching
# orphaned issues to milestones. The rule "always give an issue a milestone" was
# written in the issue review prompt and in CLAUDE.md, but a rule that lives only
# in a prompt is a hope: the ad hoc creates (the ones typed on request, mid flow)
# had no milestone at all. So the check moves out of the model's memory and into a
# gate that sees the actual command.
#
# Fails OPEN by design: anything it cannot parse exits quietly rather than
# blocking work. It is a completeness gate, not a safety gate, and a false block
# on an unparseable command would teach the override habit.
#
# The milestone must belong to the create command itself, in the same shell
# segment. Reading the whole command string would let a `--milestone` sitting on a
# neighbouring command satisfy the check.
#
# Deliberate override: SKIP_MILESTONE_CHECK=1 gh issue create ... (visible in the
# command, so it cannot happen by accident or go unnoticed in the transcript).

set -uo pipefail

payload="$(cat)"

read -r -d '' PROG <<'PY'
import json
import re
import shlex
import sys

RAW = sys.stdin.read()

try:
    data = json.loads(RAW)
    command = (data.get("tool_input") or {}).get("command") or ""
except Exception:
    sys.exit(0)

if not command.strip():
    sys.exit(0)


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
    sys.exit(0)  # unbalanced quotes: not ours to judge

OPERATORS = {"&&", "||", ";", "|", "&", "(", ")", "{", "}", "\n"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def is_operator(tok):
    return tok in OPERATORS or set(tok) <= set("&|;()")


def is_gh(tok):
    return tok == "gh" or tok.endswith("/gh")


def has_milestone(args):
    """Does this argument list name a non-empty milestone?"""
    i = 0
    while i < len(args):
        tok = args[i]
        if tok.startswith("--milestone="):
            return bool(tok.split("=", 1)[1].strip())
        if tok in ("--milestone", "-m"):
            if i + 1 >= len(args):
                return False
            nxt = args[i + 1]
            # An empty value, or the next flag, means no milestone was given.
            return bool(nxt.strip()) and not nxt.startswith("-")
        i += 1
    return False


# Walk the token stream. A create only counts when `gh issue create` sits at the
# head of a segment (start of the command, or just after a shell operator, with
# leading env assignments skipped). That keeps quoted mentions and heredoc bodies
# from tripping the gate.
offenders = 0
i = 0
at_head = True
# The override belongs to the ONE command it prefixes. Reading it across the whole
# call is how an unmilestoned create slipped through on 2026-07-29: an override on
# line 1 silently exempted a second create three lines later.
seg_override = False
while i < len(tokens):
    tok = tokens[i]
    if is_operator(tok):
        at_head = True
        seg_override = False
        i += 1
        continue

    if at_head and ASSIGNMENT.match(tok):
        if tok == "SKIP_MILESTONE_CHECK=1":
            seg_override = True
        i += 1  # env assignment prefix: still at the head
        continue

    if at_head and is_gh(tok) and tokens[i + 1 : i + 3] == ["issue", "create"]:
        j = i + 3
        args = []
        while j < len(tokens) and not is_operator(tokens[j]):
            args.append(tokens[j])
            j += 1
        if not seg_override and not has_milestone(args):
            offenders += 1
        i = j
        at_head = True
        seg_override = False
        continue

    at_head = False
    i += 1

if not offenders:
    sys.exit(0)

count = "1 issue" if offenders == 1 else "{n} issues".format(n=offenders)
reason = (
    "This command would file {c} with no milestone. Every issue belongs to a "
    "milestone, so the backlog stays grouped by the work it serves.\n\n"
    "Do this instead:\n"
    "1. Read the repo's open milestones: gh api \"repos/<owner>/<name>/milestones?state=open&per_page=100\" "
    "--jq '.[] | \"#\\(.number) \\(.title)\"'\n"
    "2. If one fits, add --milestone \"<title>\" to the create command and re-run it.\n"
    "3. If none fits, do NOT invent one silently. Resolve it through the shared helper, which reuses a "
    "match, refuses to create a near duplicate, and only creates with explicit approval:\n"
    "   bash ~/.claude/skills/milestone/ensure-milestone.sh \"<owner>/<name>\" \"<milestone title>\"\n"
    "   Then ask the user via an AskUserQuestion picker before creating anything new, offering the closest "
    "existing milestones alongside the proposed new one, and re-run the helper with --create-approved once "
    "they choose.\n\n"
    "If this issue genuinely should not have a milestone (a repo you do not own, a throwaway repo), say so "
    "and re-run with the visible override: SKIP_MILESTONE_CHECK=1 <the same command>."
).format(c=count)

json.dump(
    {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    },
    sys.stdout,
)
PY

# A crash here must not block work, but it must not be invisible either: a silent
# failure would leave the gate switched off with everything looking normal.
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
out="$(printf '%s' "$payload" | python3 -c "$PROG" 2>"$err")"
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "MILESTONE GATE DID NOT RUN: require-milestone-on-issue.sh failed (rc=$rc). This issue may be filed without a milestone. $(tr '\n' ' ' <"$err")" >&2
  exit 0
fi

printf '%s' "$out"
exit 0
