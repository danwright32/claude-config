#!/usr/bin/env python3
"""Rank a repository's open issues into the picks /next-issue offers (claude-config#1505).

WHY. The ranking lived only in the skill's prose: priority, then user-facing, then the milestone just
shipped, then bugs, then value for effort, with lesson sweeps after p0. Nothing in it ever brought
structural work forward. Measured 2026-10-22 in one work repository, tech-debt issues were filed
faster than they were closed in every month since June (327 filed, 196 closed, 131 open, 124 of
them at p2 or p3), and consolidation issues from June and July were still open. A rule asking the
reader to remember structural work is a hope (L27), so the slot is something this ranking DOES.

THE SLOT. One fixed place in every picker: when none of the picks carries a structural label, the
last pick goes to the highest ranked open structural issue. Priority stays the primary rule: the
slot never displaces a p0, a p1 or a lesson sweep, so when the last pick is one of those the slot
is held back and says so. It never adds a second structural pick, and with no structural issue
open the plain ranking stands. Every SLOT line names which of those happened.

THE ORDER. p0, then lesson sweeps (oldest first), then p1 to p4; within a level user-facing, then
the milestone just shipped, then bugs, then oldest first. Oldest first replaces the prose's value
for effort, a judgement the reader made freely and the place a slot could be reasoned away.

Usage:  gh issue list --state open --limit 1000 --json number,title,labels,milestone \\
          | rank-next-issues.py [--limit 1000] [--milestone "<title just shipped>"] [--count 3]
        rank-next-issues.py --structural-labels

Exit 0 ranked (including an empty backlog), 2 the list could not be read, 3 the list is as long
as --limit, so it was cut off and ranking it would rank a partial backlog.
"""
import json
import re
import sys

PRIORITY = re.compile(r"^priority-(p[0-4])$", re.IGNORECASE)
DEFAULT_LEVEL = 2

# The structural spellings, matched whole and in any case: the area check's own list
# (mods/area-check/hooks/rules.ts, STRUCTURAL_LABELS), so the structural issue a session is told
# to fold in is the one this slot brings forward. test-rank-next-issues.sh holds the two equal.
STRUCTURAL_LABELS = ("tech-debt", "refactor", "test-refactor")


def fail(code, message):
    print(message, file=sys.stderr)
    sys.exit(code)


def parse_args(argv):
    opts = {"limit": None, "milestone": None, "count": 3}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("--limit", "--milestone", "--count") and i + 1 < len(argv):
            value = argv[i + 1]
            if arg == "--milestone":
                opts["milestone"] = value
            else:
                try:
                    opts[arg[2:]] = int(value)
                except ValueError:
                    fail(2, f"{arg} takes a number, got {value!r}")
            i += 2
            continue
        fail(2, f"unknown argument {arg!r}")
    if opts["count"] < 1:
        fail(2, "--count must be at least 1")
    return opts


def read_issues(text):
    try:
        data = json.loads(text)
    except ValueError:
        fail(2, "UNREADABLE the issue list is not JSON; rank nothing until gh issue list succeeds")
    if not isinstance(data, list) or not all(isinstance(r, dict) and isinstance(r.get("number"), int) for r in data):
        fail(2, "UNREADABLE the issue list is not a list of issues with numbers")
    issues = []
    for r in data:
        labels = [str(l.get("name", "")) for l in (r.get("labels") or []) if isinstance(l, dict)]
        lower = [l.lower() for l in labels]
        levels = [int(m.group(1)[1]) for m in (PRIORITY.match(l) for l in lower) if m]
        milestone = r.get("milestone")
        issues.append({
            "number": r["number"],
            "title": str(r.get("title") or ""),
            "lower": lower,
            # The most urgent label wins when an issue carries two, so a stray label never demotes.
            "level": min(levels) if levels else None,
            "milestone": milestone.get("title") if isinstance(milestone, dict) else None,
        })
    return issues


def level_of(issue):
    return DEFAULT_LEVEL if issue["level"] is None else issue["level"]


def rank_key(issue, milestone):
    """Lower sorts first. Priority is the primary rule, with lesson sweeps after p0 and ahead of p1."""
    level = level_of(issue)
    sweep = "lesson-sweep" in issue["lower"]
    tier = 0 if level == 0 else (1 if sweep else level + 1)
    return (
        tier,
        0 if "user-facing" in issue["lower"] else 1,
        0 if milestone and issue["milestone"] == milestone else 1,
        0 if "bug" in issue["lower"] else 1,
        issue["number"],  # oldest first
    )


def structural(issue):
    return [l for l in STRUCTURAL_LABELS if l in issue["lower"]]


def protected(issue):
    """A pick the slot may never displace: broken now, do next, or a lesson sweep."""
    return level_of(issue) <= 1 or "lesson-sweep" in issue["lower"]


def apply_slot(ranked, picks):
    """Return (picks, slot line, the issue brought forward or None)."""
    covering = [i for i in picks if structural(i)]
    if covering:
        return picks, f"SLOT already #{covering[0]['number']} is a structural pick; no second one is added", None
    waiting = [i for i in ranked if structural(i) and i not in picks]
    if not waiting:
        return picks, "SLOT none no open issue carries " + ", ".join(STRUCTURAL_LABELS) + "; the plain ranking stands", None
    if protected(picks[-1]):
        return picks, (f"SLOT held #{waiting[0]['number']} waits: every pick is p0, p1 or a lesson sweep, "
                       "and the slot never displaces those"), None
    slot = waiting[0]
    return picks[:-1] + [slot], (f"SLOT filled #{slot['number']} takes the last pick in place of "
                                 f"#{picks[-1]['number']}, as the highest ranked structural issue"), slot


def describe(issue):
    notes = [f"p{level_of(issue)}" + ("" if issue["level"] is not None else " (unlabelled)")]
    for label in ("lesson-sweep", "user-facing", "bug") + STRUCTURAL_LABELS:
        if label in issue["lower"]:
            notes.append(label)
    return notes


def main(argv):
    if argv == ["--structural-labels"]:
        print("\n".join(STRUCTURAL_LABELS))
        return 0
    opts = parse_args(argv)
    issues = read_issues(sys.stdin.read())
    if opts["limit"] is not None and len(issues) >= opts["limit"]:
        fail(3, f"TRUNCATED the list holds {len(issues)} issues, its whole --limit; raise the limit and list again")
    if not issues:
        print("NO OPEN ISSUES")
        return 0
    ranked = sorted(issues, key=lambda i: rank_key(i, opts["milestone"]))
    picks = ranked[: opts["count"]]
    picks, slot_line, slot = apply_slot(ranked, picks)

    for place, issue in enumerate(picks, 1):
        notes = describe(issue) + (["structural slot"] if issue is slot else [])
        print(f"PICK {place} #{issue['number']} [{', '.join(notes)}] {issue['title']}")
    print(slot_line)
    unlabelled = [i for i in ranked if i["level"] is None]
    if unlabelled:
        names = " ".join(f"#{i['number']}" for i in unlabelled)
        print(f"UNLABELLED {names}: give each a priority label (step 5) and rank again; ranked at p2 meanwhile")
    if all(level_of(i) >= 3 for i in picks):
        print("LOW every pick is p3 or below; say so plainly")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
