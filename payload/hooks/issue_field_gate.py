"""The `gh issue create` completeness gate: one rule table, one process.

Every issue Dan tracks carries four things, so the backlog can be read three ways and
/sleep can ask what only Dan can decide: a milestone (which feature it ships with), a
priority (how urgent), at least one category label (what it is about), and an Open
questions section in its body (claude-config#1279). The full model is in
~/.claude/skills/milestone/NAMING.md, which is the source of truth; this file only
enforces presence.

This replaced three near-identical hooks (require-milestone-on-issue.sh,
require-priority-on-issue.sh, require-category-on-issue.sh). They shared the hard part
already, the shell command parsing in gh_issue_scan.py, so what differed was only the
rule, the message and the override name. Three copies of the wrapper meant three
places to fix any bug in the wrapper, and three Python processes spawned on EVERY Bash
command Claude ran, not only the ones filing issues. Now a new rule is one entry in
RULES below.

Two properties kept deliberately from the old design:

1. Each rule has its OWN override, so waiving one never waives another. They answer
   different questions about the issue.
2. A COMMAND it cannot read is refused only when its text names a command the gate judges
   (claude-config#1485), saying which quote never closes and where, and passes untouched
   otherwise. It used to pass every one whole, so an incomplete create beside a lone apostrophe
   the reader could not close was never judged. The reader now reads a body in "$(...)", which
   was 19 of the 23 such past commands naming gh on this Mac (of about 103,000 measured
   2026-10-22); the refusal fired on 1, which bash could not have run as written either. Passing
   one takes the override of every rule it could not judge, so waiving one still waives no other.
   A --body-file it cannot read is refused too (claude-config#1416): the command parsed, and it
   points gh at a description that is not there, so that is refused, naming the path and why.

What changed for the better: a create missing two things now says so once, instead of
whichever of three gates happened to be reported first.

The body file rule alone also judges the other gh commands that post a body from a file (gh issue
edit and comment, gh pr create, edit and comment, claude-config#1435), whose refusal speaks only of
the body file, since the issue rules are about filing an issue.
"""

import glob
import importlib.util
import json
import os
import re
import subprocess
import sys

# The scanner is a sibling file, loaded by its explicit path rather than by name.
# `python3` puts the script's own directory on the import path, but running via `-c` or
# from another directory would not, and a gh_issue_scan.py sitting in whatever project
# the command runs from must never be able to shadow the real one.
_HERE = os.environ.get("GATE_DIR") or os.path.dirname(os.path.abspath(__file__))
_path = os.path.join(_HERE, "gh_issue_scan.py")
_spec = importlib.util.spec_from_file_location("gh_issue_scan", _path)
if _spec is None or _spec.loader is None:
    raise ImportError("cannot load the shared scanner at %s" % _path)
scan = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(scan)


# Anchored: `priority-p10` is not level 1, `priority` alone is not a level, and
# `priority-review` is an ordinary label.
LEVEL = re.compile(r"^priority-p[0-4]$", re.IGNORECASE)


def _labels(args):
    """Every label named on this create, comma lists split out.

    gh accepts both `--label "bug,priority-p2"` and repeated `--label` flags; its own
    documented example is `--label "bug,help wanted"`, so a label may contain spaces
    but never a comma.
    """
    out = []
    for value in scan.flag_values(args, "--label", "-l"):
        for name in value.split(","):
            name = name.strip()
            if name:
                out.append(name)
    return out


def has_milestone(args):
    return any(v.strip() for v in scan.flag_values(args, "--milestone", "-m"))


def has_priority(args):
    return any(LEVEL.match(n) for n in _labels(args))


def has_category(args):
    """Any label that is not a priority level counts.

    Presence, not membership: Dan restricted the levels deliberately and left the
    categories open, so a label invented for this one issue is a valid category and a
    closed vocabulary would go stale and start forcing bad fits.
    """
    return any(not LEVEL.match(n) for n in _labels(args))


SESSION_MARK = "Claude-Session:"


def session_line():
    """The line naming this session, from the one shared maker, or None outside a session."""
    try:
        r = subprocess.run(["bash", os.path.join(_HERE, "lib", "claude-session-line.sh")],
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    line = r.stdout.strip()
    return line if r.returncode == 0 and line.startswith(SESSION_MARK) else None


def _same_path(a, b):
    return os.path.normpath(os.path.expanduser(a)) == os.path.normpath(os.path.expanduser(b))


def has_session_line(args, command, place=None):
    """The body names the session that filed it (claude-config#536). See body_carries."""
    return body_carries(args, command, lambda text: SESSION_MARK in text, place=place)


# The body's Open questions section (claude-config#1279, Dan 2026-10-17): a heading, at any level,
# at a line's start or right after the quote that opens the body. The words in a sentence ("no open
# questions") are not a section.
# The whole heading, at a line's start, a quote's or an escaped newline's in a $'...' body, and
# ending there too, so "## Open questions about the API" is another section (lessons review). The
# quote and written newline are a command's spelling, so this reads only the command text and its
# arguments (holds_open_questions with spelled=True); a markdown body, a --body-file or the plan body
# create-milestone.sh asks about through --holds-open-questions, is read by HEADING_LINE below, as
# mods/mod-kit/hooks/openquestions.ts reads one (claude-config#1320).
OPEN_QUESTIONS = re.compile(r"(?im)(?:^|[\"']|\\n)[ \t]*#{1,6}[ \t]*Open questions[ \t]*(?=\r?$|[\"']|\\[nr])")
# The same heading in a body that is markdown (a --body-file, a plan body): a whole line, after any
# indentation, as mod-kit's reader takes it; a quote before or after it is the command's spelling,
# so in markdown it makes the line a sentence (claude-config#1320, lessons review).
HEADING_LINE = re.compile(r"(?im)^[ \t]*#{1,6}[ \t]*Open questions[ \t]*\r?$")


# A fenced code block (claude-config#1320), by the rule mod-kit's reader follows
# (mods/mod-kit/hooks/openquestions.ts), both held to one set of cases
# (mods/mod-kit/tests/openquestions-fixtures.ts): a line of three or more backticks or tildes, after
# any indentation, opens one, unless a backtick line has another backtick after its fence (inline
# code); a line of the same character, at least as long, with nothing but spaces after it, closes
# it; one never closed runs to the end. A line inside, the fences included, is code, so a fenced
# example of the heading is not the section.
FENCE = re.compile(r"^[ \t]*(`{3,}|~{3,})(.*)$")
# A body in the command text, or in an argument parsed from it, is read as the command spells it: a
# line may end in a written \n (an ANSI quoted $'...' body, as OPEN_QUESTIONS reads one), and a
# backtick may be written \` (a double quoted body, where a bare one would run a command). A body
# that is markdown (a --body-file, or create-milestone.sh's plan body) is read as markdown, where
# those are text, exactly as mod-kit reads one (lessons review).
LINE_BREAK = re.compile(r"\r?\n")
SPELLED_LINE_BREAK = re.compile(r"\r?\n|\\r\\n|\\n")


def fenced_lines(lines, spelled=False):
    """For each line, whether it sits in a fenced code block, its fences included.

    `spelled`: the lines are a shell command's spelling of a body, where \\` is a backtick.
    """
    out = []
    fence_open = None
    for line in lines:
        m = FENCE.match(line.replace("\\`", "`") if spelled else line)
        fence, rest = (m.group(1), m.group(2)) if m else ("", "")
        if fence_open is None:
            opens = m is not None and not (fence[0] == "`" and "`" in rest)
            if opens:
                fence_open = fence
            out.append(opens)
            continue
        out.append(True)
        if m and fence[0] == fence_open[0] and len(fence) >= len(fence_open) and not rest.strip():
            fence_open = None
    return out


def holds_open_questions(text, spelled=False):
    """Whether a text holds the section's heading outside every fenced code block.

    `spelled`: the text is a shell command, or an argument parsed from one, read as it spells a body.
    """
    lines = (SPELLED_LINE_BREAK if spelled else LINE_BREAK).split(text)
    code = fenced_lines(lines, spelled)
    return (OPEN_QUESTIONS if spelled else HEADING_LINE).search("\n".join("" if c else l for l, c in zip(lines, code))) is not None


def has_open_questions(args, command, place=None):
    """The body holds an Open questions section, listing what only Dan can decide, or None."""
    return body_carries(args, command, holds_open_questions, lambda text: holds_open_questions(text, spelled=True),
                        place=place)


def _here():
    """Where a create runs when nothing more is known: this process's directory and environment."""
    return scan.Place(os.getcwd(), dict(os.environ))


def body_files(args, command, place=None):
    """What the gate can tell about each --body-file one create names, as (word, state, detail).

    word is the path as the command spells it, after the shell's quoting. state is one of:
      "stdin"       `-F -`, `-F-`, `--body-file=-`: standard input, judged from the command text
      "hidden"      written by this command from something it does not show (a script, an expansion),
                    or named through a variable only running the command fills in (a loop's, a
                    function's $1) where some non-empty file matches: either way, not judged here
      "shown"       written by this command from text it shows, so judged from the command (#1246)
      "text"        read from disk; detail is the text
      "missing"     none of those, and no file is there (or no file at all matches a pattern the
                    command fills in as it runs); detail says where it looked (#1416)
      "unreadable"  none of those, and not a file the gate can read for another reason (an empty
                    file, a variable never set, a path it cannot work out); detail says why (#1416)

    A path is read the way the shell will read it where the create runs (scan.resolve_path): a
    variable the command does not set and its environment does not hold is empty there, and a
    relative path is read against the command's directory and any cd before the create. A file the
    command itself writes is matched by its spelling or by where it resolves to, and is never
    unreadable, since the command makes it. A file present but empty, or only blank lines, files a
    blank description, so it counts as unreadable too.
    """
    place = place or _here()
    words = scan.flag_values(args, "--body-file", "-F")
    if not words:
        return []
    try:
        writes = scan.file_writes_in_context(command, place.start, place.environ)
        writes_known = True
    except scan.Unreadable:
        writes, writes_known = [], False
    out = []
    for word in words:
        if word == "-":
            out.append((word, "stdin", None))
            continue
        path, why = scan.resolve_path(word, place)
        # A write is this file when both land in one place, read where each happens, so a file written
        # before a later cd is found where it was written (claude-config#1436). Only where either
        # cannot be placed (a substitution, a cd the gate cannot follow) is the spelling matched.
        written = [w for w in writes
                   if (w[3] == path if w[3] and path else _same_path(w[0], word))]
        if any(not shown for _, _, shown, _ in written):
            out.append((word, "hidden", None))
            continue
        if any(not appends for _, appends, _, _ in written):
            out.append((word, "shown", None))
            continue
        if why:
            # Appended to here, from shown text, at a place the gate cannot find: judged from the text.
            out.append((word, "shown", None) if written else (word, "unreadable", why))
            continue
        if scan.RUNTIME in path:
            # Part of the path is filled in only as the command runs (a loop's variable, a function's
            # $1), so which file is unknown: some non-empty file must be one it could name.
            # The value may hold a / (a loop over a/x b/y), so a match a few directories down counts too
            # (claude-config#1436). Shallowest first, lazily, so the first good file ends the search.
            matched = good = False
            for pattern in ([] if written else scan.runtime_patterns(path)):
                for m in glob.iglob(pattern):
                    if os.path.isfile(m):
                        matched = True
                        good = os.path.getsize(m) > 0
                        if good:
                            break
                if good:
                    break
            if written or good:
                out.append((word, "hidden", None))
            else:
                out.append((word, "unreadable" if matched else "missing",
                            "no file matches %s that is not empty, nor any up to %d directories further down "
                            "(each * is filled in only as the command runs)"
                            % (scan.runtime_pattern(path), scan.RUNTIME_DEPTH)))
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError as e:
            if written:
                out.append((word, "shown", None))
            elif isinstance(e, FileNotFoundError):
                out.append((word, "missing", "%s does not exist" % path))
            elif isinstance(e, IsADirectoryError):
                out.append((word, "unreadable", "%s is a directory" % path))
            else:
                out.append((word, "unreadable", "%s cannot be read (%s)" % (path, e.strerror or e)))
            continue
        if not written and not text.strip():
            out.append((word, "unreadable", "%s is empty" % path))
            continue
        out.append((word, "text", text))
    if not writes_known:
        # Which files the command writes could not be read, so a file on disk may be one it is about
        # to replace (judged as before #1416: not at all), and a file not there yet one it makes.
        out = [(w, "hidden", None) if s == "text" else
               (w, s, d + "; the gate also could not read which files this command writes"
                if s in ("unreadable", "missing") else d)
               for w, s, d in out]
    return out


def unreadable_body_files(args, command, place=None, missing=True):
    """Each --body-file of one command the gate cannot read, as a line naming it and saying why.

    missing: whether a file that is not there counts. It does for gh issue create (#1416). The other
    commands leave it to gh, which stops on a missing body file before any request (claude-config#1435).
    """
    return ["--body-file %s: %s" % (word, why) for word, state, why in body_files(args, command, place)
            if state == "unreadable" or (missing and state == "missing")]


def body_carries(args, command, found, found_in_command=None, place=None):
    """Whether the body of a create holds what `found` looks for in a text.

    Looked for in the whole command text as well as the parsed arguments, because a body written
    as a heredoc inside a command substitution is only ever present as text, and in a --body-file
    when one is named. A body on standard input (`-F -`, `-F-`, `--body-file=-`) is judged by the
    command text alone, since what feeds it is part of the command.

    A body file the same command writes is judged from the command, not the disk (claude-config#1246):
    this gate runs before the command, so the file is missing or holds an older body. When what is
    written is text the command shows, and the line is nowhere in the command, the line is not in
    the file either. Written by anything else (a script, an expansion), it is not held against the
    create. A body file the gate cannot read is not judged here either: the body file rule refuses
    it, naming the path and why (claude-config#1416), so this rule does not also claim a section or
    line is missing from a file nobody could look in.

    `found_in_command`, when given, reads the command text and its arguments, as the command spells
    a body; `found` alone reads a body file, which is the body itself.
    """
    spelled = found_in_command or found
    if spelled(command) or any(spelled(a) for a in args):
        return True
    for _, state, detail in body_files(args, command, place):
        if state in ("hidden", "unreadable", "missing"):
            return True
        if state == "text" and found(detail):
            return True
    return False


MILESTONE_FIX = (
    "MILESTONE. Every issue belongs to one, so the backlog stays grouped by the work it serves.\n"
    "   Read the repo's open milestones: gh api \"repos/<owner>/<name>/milestones?state=open&per_page=100\" "
    "--jq '.[] | \"#\\(.number) \\(.title)\"'\n"
    "   If one fits, add --milestone \"<its exact title>\" and re-run. gh matches by name, so a case variant "
    "is not found.\n"
    "   If none fits, do NOT invent one. A milestone is the overarching FEATURE, and its issues are what has "
    "to ship for that feature to be done, so opening one for a single issue never makes sense. Creating a "
    "milestone is a planning decision that belongs to /plan-council, /plan-lite or /milestone. Here, put it in "
    "the repo's catch-all, which needs no approval and is a REAL milestone holding the standalone issues:\n"
    "   bash ~/.claude/skills/milestone/ensure-milestone.sh \"<owner>/<name>\" \"Ungrouped\"\n"
    "   A category like accessibility or tech debt is a LABEL, never a milestone, because an issue is "
    "routinely two categories at once and can hold only one milestone."
)

PRIORITY_FIX = (
    "PRIORITY. Exactly one level, the only urgency scale:\n"
    "     priority-p0   broken now, drop everything\n"
    "     priority-p1   important, do next\n"
    "     priority-p2   normal, the default for real work\n"
    "     priority-p3   nice to have\n"
    "     priority-p4   someday, maybe never\n"
    "   WHO PICKS depends on who noticed. If Dan reported this himself, ASK him with an AskUserQuestion "
    "picker carrying each level's meaning in its option descriptions, so the scale is in front of him as he "
    "chooses. If you found it (an audit, a sweep, the end of turn review), choose it yourself and say which "
    "in one line.\n"
    "   If the five labels do not exist in the repo yet: bash ~/.claude/skills/milestone/ensure-priority-labels.sh "
    "\"<owner>/<name>\"\n"
    "   Never apply a sev-* or severity:* label: they are retired."
)

CATEGORY_FIX = (
    "CATEGORY. At least one label saying what the issue is ABOUT, and as many as genuinely apply: an "
    "accessibility fix that is also tech debt gets both.\n"
    "   A starting point, one for the kind of work: bug, enhancement, tech-debt, documentation.\n"
    "   And any that fit for what it touches: accessibility, ui-ux, performance, security, data-integrity, "
    "error-handling, monitoring, analytics, ci-hygiene, test-coverage, onboarding, deployment.\n"
    "   Those are a starting point and not a fixed list, and this gate never checks WHICH label you used, "
    "only that a category is there. Read the repo's own labels first and prefer one that already exists over "
    "a near synonym (if the repo says `ux`, use `ux`, not `ui-ux`):\n"
    "   gh label list --limit 100\n"
    "   If nothing covers it, create a label rather than forcing a bad fit or leaving the issue bare. Keep it "
    "short, kebab-case and reusable:\n"
    "   gh label create <name> --color <hex> --description \"<what it means>\"\n"
    "   Never apply claude-suggested or any label attributing the issue to Claude or AI."
)

# Judged on the body, so it reads the command as the session line does (claude-config#1279).
OPEN_QUESTIONS_RULE = {
    "name": "an Open questions section",
    "check": lambda args, command, place: has_open_questions(args, command, place),
    "fix": ("OPEN QUESTIONS. The body ends its prose with a section listing what only Dan can decide about "
            "this issue, so /sleep asks each before the night begins instead of a worker finding it "
            "overnight. One unchecked item a question; if there are none, write None under it:\n"
            "   ## Open questions\n"
            "   - [ ] <a decision only Dan can make>\n"
            "   (or: None)\n"
            "   It goes in --body or the --body-file, before the session line."),
    "override": "SKIP_OPEN_QUESTIONS_CHECK=1",
}

# A --body-file the gate cannot read (claude-config#1416). Before it, the gate passed one, so
# Try-Pennie/slate#3924 and #3925 were filed with a body holding only the session line from a path
# through a variable an earlier Bash call had set. `details` names each path and why, and evaluate
# fills them into {details}.
BODY_FILE_RULE = {
    "name": "a body file it can read",
    "check": lambda args, command, place: not unreadable_body_files(args, command, place),
    "details": lambda args, command, place: unreadable_body_files(args, command, place),
    "fix": ("BODY FILE. The command points gh at a description the gate cannot find. Each --body-file "
            "below, read as the shell will read it when the command runs:\n"
            "{details}\n"
            "   Write the path out in full, or set any variable it uses in this same command, make sure "
            "the file holds the description, then re-run."),
    "override": "SKIP_BODY_FILE_CHECK=1",
}

# The same rule for the other gh commands that post a body from a file (scan.BODY_FILE_COMMANDS,
# claude-config#1435), the only rule they get. A missing file is left to gh, which stops on one before
# any request (each of the six measured 2026-10-20, gh 2.89.0); refusing it here as well refused only
# commands that write the file through a script the gate cannot read, 10 of about 1550 past ones. What
# gh lets through is what it refuses: an empty file, a variable never set, a path it cannot work out.
OTHER_BODY_FILE_RULE = dict(
    BODY_FILE_RULE,
    check=lambda args, command, place: not unreadable_body_files(args, command, place, missing=False),
    details=lambda args, command, place: unreadable_body_files(args, command, place, missing=False),
)


# The table. A new rule is one entry: what it is called, how to detect it from the create's
# arguments, the whole command and the place it runs (scan.Place), what to say, and its own
# override. Order is the order the fixes are listed in.
RULES = [
    {"name": "a milestone", "check": lambda args, command, place: has_milestone(args), "fix": MILESTONE_FIX, "override": "SKIP_MILESTONE_CHECK=1"},
    {"name": "a priority label", "check": lambda args, command, place: has_priority(args), "fix": PRIORITY_FIX, "override": "SKIP_PRIORITY_CHECK=1"},
    {"name": "a category label", "check": lambda args, command, place: has_category(args), "fix": CATEGORY_FIX, "override": "SKIP_CATEGORY_CHECK=1"},
    OPEN_QUESTIONS_RULE,
    BODY_FILE_RULE,
]


def session_rule(line):
    """The session line rule, which exists only inside a session: its fix names the exact line."""
    return {
        "name": "the session that filed it",
        "check": lambda args, command, place: has_session_line(args, command, place),
        "fix": ("SESSION. End the body with the line naming this session, the same line commits and pull "
                "requests carry, so a session reading the issue list can tell which session filed what:\n"
                "   " + line + "\n"
                "   Put it on its own line, after a blank line, at the end of --body or the --body-file."),
        "override": "SKIP_SESSION_LINE_CHECK=1",
    }


def evaluate(command, cwd=None):
    """Which rules fail, across every create in the command, and every other gh command that posts a
    body from a file (scan.BODY_FILE_COMMANDS, claude-config#1435), which only the body file rule judges.

    cwd is the directory the command starts in (the payload's), this process's when not given.
    Returns (issue_count, [failing rule dicts], [other commands refused]). The count is of offending
    creates, so the message can say "1 issue" or "3 issues" correctly; the other commands are named
    once each, as `gh pr create`. A rule with `details` comes back with its fix filled in from every
    command's details, each named once.
    """
    found = scan.scan_gh_in_context(command, cwd or os.getcwd(), dict(os.environ), scan.BODY_FILE_COMMANDS)
    rules = list(RULES)
    line = session_line() if any(kind == scan.CREATE for kind, _, _, _ in found) else None
    if line:
        rules.append(session_rule(line))
    offenders = 0
    others = []
    by_creates = set()
    failing = []
    details = {}
    for kind, args, envs, place in found:
        judged = rules if kind == scan.CREATE else [OTHER_BODY_FILE_RULE]
        missing = [r for r in judged if r["override"] not in envs and not r["check"](args, command, place)]
        if not missing:
            continue
        if kind == scan.CREATE:
            offenders += 1
        elif "gh %s %s" % kind not in others:
            others.append("gh %s %s" % kind)
        for r in missing:
            if r["name"] not in [f["name"] for f in failing]:
                failing.append(r)
            if kind == scan.CREATE:
                by_creates.add(r["name"])
            if "details" in r:
                seen = details.setdefault(r["name"], [])
                seen += [d for d in r["details"](args, command, place) if d not in seen]
    # Which rules a create failed, so the header names only what an issue misses, never a rule only
    # another command failed.
    failing = [dict(r, fix=r["fix"].format(details="\n".join("     " + d for d in details[r["name"]])))
               if "details" in r else dict(r) for r in failing]
    for r in failing:
        r["by_create"] = r["name"] in by_creates
    return offenders, failing, others


def build_reason(offenders, failing, others=()):
    """The refusal: the issue rules' framing when a create fails, the body file's alone otherwise."""
    handed = ("%s a --body-file the gate cannot read, which would post a blank or wrong body%s"
              % (" and ".join(others),
                 ", and an edit would blank the description already there" if any(o.endswith(" edit") for o in others) else ""))
    if not offenders:
        lines = ["This command would hand %s.\n" % handed, "Fix it, then re-run the command:\n"]
    else:
        names = ", ".join(r["name"] for r in failing if r.get("by_create", True))
        lines = [
            "This command would file %s missing %s. Every issue carries a milestone, a priority, at least one "
            "category and an Open questions section, so the backlog can be read by feature, by urgency and by "
            "area, and /sleep can ask what only Dan can decide; one filed from a Claude session names that session.\n"
            % (scan.plural_issues(offenders), names),
            "Fix each one, then re-run the command:\n",
        ]
        if others:
            lines.insert(1, "It would also hand %s.\n" % handed)
    for n, rule in enumerate(failing, 1):
        lines.append("%d. %s\n" % (n, rule["fix"]))
    if offenders:
        lines.append("The full rule for all of this is in ~/.claude/skills/milestone/NAMING.md.\n")
    lines.append(
        "If one of these genuinely does not apply (a repo you do not own, a throwaway repo, a path the gate "
        "cannot see is there), say so and re-run with the visible override for JUST that one, so waiving it "
        "cannot waive the others: %s <the same command>. An override is good for the one command it "
        "prefixes, never standing permission."
        % " / ".join(r["override"] for r in failing)
    )
    return "\n".join(lines)


def _has_override(command, override):
    """Whether the text of a command it could not read sets an override anywhere as a word of its own."""
    return re.search(r"(?:^|[\s;&|(])%s(?=\s)" % re.escape(override), command) is not None


def unreadable_reason(command, error):
    """The refusal for a command the gate could not read (claude-config#1485), or None to pass it.

    Refused when its text names a command the gate judges: a gh issue create that files an issue, or a
    body file command (scan.BODY_FILE_COMMANDS) naming a --body-file, the only thing it judges there.
    Which command an override prefixes cannot be read either, so one anywhere counts, and passing the
    command takes the override of every rule the gate could not judge.
    """
    named, overrides = [], []
    for kind, args in scan.gated_in_text(command):
        if kind == scan.CREATE:
            if any(a in scan.NON_FILING_FLAGS for a in args):
                continue
            judged = list(RULES)
            line = session_line()
            if line:
                judged.append(session_rule(line))
        elif scan.flag_values(args, "--body-file", "-F"):
            judged = [OTHER_BODY_FILE_RULE]
        else:
            continue
        if "gh %s %s" % kind not in named:
            named.append("gh %s %s" % kind)
        overrides += [r["override"] for r in judged if r["override"] not in overrides]
    if not named or all(_has_override(command, o) for o in overrides):
        return None
    return ("The issue field gate could not read this command, so it cannot judge the %s in it: %s. Close that "
            "quote, or reword so the line holds no lone quote, then re-run; if the command is right as written, "
            "say so and put %s in front of it, which waives every rule the gate could not judge, for that one "
            "command only." % (" or the ".join(named), error, " ".join(overrides)))


def main():
    # Asked by create-milestone.sh, whose creates this gate never sees, whether a body already has
    # the section, so the two read it by one rule (claude-config#1320). The answer is printed, yes
    # or no, never an exit code, since a crash exits 1 too and would read as no (lessons review).
    if sys.argv[1:] == ["--holds-open-questions"]:
        print("yes" if holds_open_questions(sys.stdin.read()) else "no")
        return 0
    try:
        data = json.loads(sys.stdin.read())
        command = (data.get("tool_input") or {}).get("command") or ""
        cwd = data.get("cwd") if isinstance(data.get("cwd"), str) else None
    except Exception:
        return 0

    try:
        offenders, failing, others = evaluate(command, cwd)
    except scan.Unreadable as e:
        reason = unreadable_reason(command, e)
        if reason:
            json.dump(scan.deny_payload(reason), sys.stdout)
        return 0

    if not offenders and not others:
        return 0

    json.dump(scan.deny_payload(build_reason(offenders, failing, others)), sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
