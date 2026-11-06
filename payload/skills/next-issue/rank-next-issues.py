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
the milestone just shipped, then bugs, then recently touched files, then oldest first. Oldest
first replaces the prose's value for effort (claude-config#2300 kept it): effort is recorded on no
issue, so it was a judgement the reader made freely and the place a slot could be reasoned away.

RECENTLY TOUCHED FILES (claude-config#2300). #1505 asked the slot to prefer a structural issue
"whose files recent fixes keep touching". With --touched, a file holding gh's merged pull request
list with files, each structural issue counts the distinct merged pull requests that changed a
file its body names, and more sorts first. It sits below every other rule, so it reorders only
issues tied on all of them, and it counts for structural issues only, which is what #1505 asked.
A name counts only when it is a path (it holds a slash) and fits exactly one changed file: a bare
name like SKILL.md or a partial path fitting two files could be any of them, so it counts nothing.

Usage:  gh issue list --state open --limit 1000 --json number,title,labels,milestone,body \\
          | rank-next-issues.py [--limit 1000] [--milestone "<title just shipped>"] [--count 3] \\
              [--touched <file holding: gh pr list --state merged --limit 50 --json number,files>]
        rank-next-issues.py --structural-labels

Exit 0 ranked (including an empty backlog), 2 the issue list or the --touched list could not be
read, 3 the list is as long as --limit, so it was cut off and ranking it would rank a partial
backlog.
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
    opts = {"limit": None, "milestone": None, "count": 3, "touched": None}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("--limit", "--milestone", "--count", "--touched") and i + 1 < len(argv):
            value = argv[i + 1]
            if arg in ("--milestone", "--touched"):
                opts[arg[2:]] = value
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
            # None when the listing left body out, which --touched refuses rather than reading as
            # an issue that names no file.
            "body": r["body"] if isinstance(r.get("body"), str) else None,
            "touched": 0,
        })
    return issues


# A path as an issue body writes it: path characters ending in a file extension. A sentence's
# full stop after it is left off by the extension having to end in a letter or digit.
PATH_TOKEN = re.compile(r"[\w.~/-]*[\w-]\.[A-Za-z0-9]{1,8}(?![\w/])")
# The installed and relative spellings of a repository path: ~/.claude/hooks/x.sh is payload's
# hooks/x.sh, and a suffix match takes it from there.
PATH_PREFIXES = ("~/.claude/", "~/", "./")


def read_merged(path):
    """The merged pull request list as {number: set of changed paths}, or exit 2 (L10)."""
    try:
        with open(path, "rb") as f:
            data = json.loads(f.read().decode("utf-8", errors="replace"))
    except (OSError, ValueError) as e:
        fail(2, f"UNREADABLE the --touched list {path!r} could not be read as JSON ({e}); "
                "rank nothing until gh pr list succeeds")
    ok = isinstance(data, list) and all(
        isinstance(r, dict) and isinstance(r.get("number"), int) and isinstance(r.get("files"), list)
        and all(isinstance(f, dict) and isinstance(f.get("path"), str) for f in r["files"])
        for r in data)
    if not ok:
        fail(2, "UNREADABLE the --touched list is not merged pull requests with number and files; "
                "list them with --json number,files")
    return {r["number"]: {f["path"] for f in r["files"]} for r in data}


def named_paths(body):
    """The paths a body names, normalised; a bare file name is not a path and is left out."""
    names = set()
    for token in PATH_TOKEN.findall(body):
        for prefix in PATH_PREFIXES:
            if token.startswith(prefix):
                token = token[len(prefix):]
                break
        token = token.lstrip("/")
        if "/" in token:
            names.add(token)
    return names


def touched_count(body, merged, changed):
    """How many distinct merged pull requests changed a file the body names exactly."""
    files = set()
    for name in named_paths(body):
        fits = [p for p in changed if p == name or p.endswith("/" + name)]
        if len(fits) == 1:  # two or more and the name could be any of them
            files.add(fits[0])
    return sum(1 for paths in merged.values() if paths & files)


def level_of(issue):
    return DEFAULT_LEVEL if issue["level"] is None else issue["level"]


def rank_key(issue, milestone):
    """Lower sorts first. Priority is the primary rule, with lesson sweeps after p0 and ahead of p1."""
    level = level_of(issue)
    sweep = "lesson-sweep" in issue["lower"]
    tier = 0 if level == 0 else (1 if sweep else level + 1)
    if tier == 1:
        return (tier, issue["number"])  # lesson sweeps are oldest first, whatever else they carry
    return (
        tier,
        0 if "user-facing" in issue["lower"] else 1,
        0 if milestone and issue["milestone"] == milestone else 1,
        0 if "bug" in issue["lower"] else 1,
        -issue["touched"],  # recently touched files, nonzero only on structural issues (#2300)
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
    if issue["touched"]:
        notes.append(f"touched by {issue['touched']} recent merge" + ("s" if issue["touched"] > 1 else ""))
    return notes


def apply_touched(issues, path):
    """Count recently touched files on every structural issue; return the TOUCHED line."""
    if path is None:
        return "TOUCHED off no --touched list was given, so tied structural issues stay oldest first"
    merged = read_merged(path)
    if any(i["body"] is None for i in issues):
        fail(2, "UNREADABLE the issue list has no body, so no issue can name a file; "
                "list it with --json number,title,labels,milestone,body")
    changed = set().union(*merged.values()) if merged else set()
    candidates = [i for i in issues if structural(i)]
    for issue in candidates:
        issue["touched"] = touched_count(issue["body"], merged, changed)
    hot = sorted((i for i in candidates if i["touched"]), key=lambda i: (-i["touched"], i["number"]))
    if not hot:
        return (f"TOUCHED none of {len(candidates)} structural issues names a file the last "
                f"{len(merged)} merged pull requests changed")
    return ("TOUCHED " + ", ".join(f"#{i['number']} ({i['touched']})" for i in hot)
            + f": structural issues naming a file the last {len(merged)} merged pull requests changed")


def main(argv):
    if argv == ["--structural-labels"]:
        print("\n".join(STRUCTURAL_LABELS))
        return 0
    opts = parse_args(argv)
    # Bytes, decoded with a stated policy: a title holding a byte that is not UTF-8 (which jq reads
    # as U+FFFD) is ranked with that character replaced, never a traceback in place of the picks.
    sys.stdout.reconfigure(errors="replace")
    issues = read_issues(sys.stdin.buffer.read().decode("utf-8", errors="replace"))
    if opts["limit"] is not None and len(issues) >= opts["limit"]:
        fail(3, f"TRUNCATED the list holds {len(issues)} issues, its whole --limit; raise the limit and list again")
    if not issues:
        print("NO OPEN ISSUES")
        return 0
    touched_line = apply_touched(issues, opts["touched"])
    ranked = sorted(issues, key=lambda i: rank_key(i, opts["milestone"]))
    picks = ranked[: opts["count"]]
    picks, slot_line, slot = apply_slot(ranked, picks)

    for place, issue in enumerate(picks, 1):
        notes = describe(issue) + (["structural slot"] if issue is slot else [])
        print(f"PICK {place} #{issue['number']} [{', '.join(notes)}] {issue['title']}")
    print(slot_line)
    print(touched_line)
    unlabelled = [i for i in ranked if i["level"] is None]
    if unlabelled:
        names = " ".join(f"#{i['number']}" for i in unlabelled)
        print(f"UNLABELLED {names}: give each a priority label (step 5) and rank again; ranked at p2 meanwhile")
    if all(level_of(i) >= 3 for i in picks):
        print("LOW every pick is p3 or below; say so plainly")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
