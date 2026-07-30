"""The `gh issue create` completeness gate: one rule table, one process.

Every issue Dan tracks carries three things, so the backlog can be read three ways:
a milestone (which feature it ships with), a priority (how urgent), and at least one
category label (what it is about). The full model is in
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
2. It fails OPEN. Anything unparseable exits quietly rather than blocking work. This
   is a completeness gate, not a safety gate, and a false block on a command it merely
   could not read would teach the override habit.

What changed for the better: a create missing two things now says so once, instead of
whichever of three gates happened to be reported first.
"""

import importlib.util
import json
import os
import re
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

# The table. A new rule is one entry: what it is called, how to detect it, what to say,
# and its own override. Order is the order the fixes are listed in.
RULES = [
    {"name": "a milestone", "check": has_milestone, "fix": MILESTONE_FIX, "override": "SKIP_MILESTONE_CHECK=1"},
    {"name": "a priority label", "check": has_priority, "fix": PRIORITY_FIX, "override": "SKIP_PRIORITY_CHECK=1"},
    {"name": "a category label", "check": has_category, "fix": CATEGORY_FIX, "override": "SKIP_CATEGORY_CHECK=1"},
]


def evaluate(command):
    """Which rules fail, across every create in the command.

    Returns (issue_count, [failing rule dicts]). The count is of offending creates, so
    the message can say "1 issue" or "3 issues" correctly.
    """
    creates = scan.scan_creates(command)
    offenders = 0
    failing = []
    for args, envs in creates:
        missing = [r for r in RULES if r["override"] not in envs and not r["check"](args)]
        if not missing:
            continue
        offenders += 1
        for r in missing:
            if r not in failing:
                failing.append(r)
    return offenders, failing


def build_reason(offenders, failing):
    names = ", ".join(r["name"] for r in failing)
    lines = [
        "This command would file %s missing %s. Every issue carries a milestone, a priority and at least "
        "one category, so the backlog can be read by feature, by urgency and by area.\n"
        % (scan.plural_issues(offenders), names),
        "Fix each one, then re-run the command:\n",
    ]
    for n, rule in enumerate(failing, 1):
        lines.append("%d. %s\n" % (n, rule["fix"]))
    lines.append(
        "The full rule for all of this is in ~/.claude/skills/milestone/NAMING.md.\n\n"
        "If one of these genuinely does not apply (a repo you do not own, a throwaway repo), say so and "
        "re-run with the visible override for JUST that one, so waiving it cannot waive the others: %s "
        "<the same command>. An override is good for the one command it prefixes, never standing permission."
        % " / ".join(r["override"] for r in failing)
    )
    return "\n".join(lines)


def main():
    try:
        data = json.loads(sys.stdin.read())
        command = (data.get("tool_input") or {}).get("command") or ""
    except Exception:
        return 0

    try:
        offenders, failing = evaluate(command)
    except scan.Unreadable:
        return 0  # not ours to judge

    if not offenders:
        return 0

    json.dump(scan.deny_payload(build_reason(offenders, failing)), sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
