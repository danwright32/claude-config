#!/usr/bin/env python3
"""Move spooled subagent records to the key their own SESSION reads.

WHY THIS EXISTS. Records used to be keyed on the AGENT's working directory.
The review keys on the session. Those differ whenever an agent works in a git
repo nested inside the folder its session was started in, and everything the
agent found then sits in a spool no review ever opens. Measured 2026-08-29 on
one project: all 318 of its records were split off this way, 47 of them real
findings unread for a week.

The keying is fixed going forward. This moves what was already written.

ONE-TIME. Once every machine sharing this config has run it, it can be deleted
along with this note. It is kept in the payload rather than run from a scratch
directory precisely so the other machine can run the same code rather than a
retyped copy of it.

THE KEY IS NOT RECOMPUTED HERE. It is asked of lib/issue-spool.sh, because a
second implementation of the key is exactly the defect being repaired: two
sides computing it independently agree only by luck (L70).

A record whose session cannot be located is LEFT WHERE IT IS. Guessing would
move it somewhere nobody looks, which is the fault this repairs.

Dry run unless --apply is passed. Prints the plan either way.
"""
import collections
import glob
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SPOOL = os.environ.get("CLAUDE_ISSUE_SPOOL_DIR") or os.path.expanduser("~/.claude-issue-spool")
PROJECTS = os.environ.get("CLAUDE_PROJECTS_DIR") or os.path.expanduser("~/.claude/projects")
LIB = os.environ.get("CLAUDE_ISSUE_SPOOL_LIB") or os.path.join(HERE, "lib", "issue-spool.sh")


def key_for_project(project_dir, cache={}):
    """The key the library gives a session living in this project directory.

    A session's transcript sits directly in its project directory, and the
    library keys on that transcript's parent, so a synthetic name inside the
    directory asks the library the exact question a real session asks it.
    """
    if project_dir in cache:
        return cache[project_dir]
    out = subprocess.run(
        ["bash", LIB, "key", project_dir, os.path.join(project_dir, "any-session.jsonl")],
        capture_output=True, text=True,
    )
    key = out.stdout.strip()
    if not key:
        raise SystemExit("migrate-issue-spool: the spool library gave no key for %s (%s)"
                         % (project_dir, out.stderr.strip()[:200]))
    cache[project_dir] = key
    return key


def session_homes():
    """session id -> the project directory that session belongs to."""
    homes = {}
    for pd in sorted(glob.glob(os.path.join(PROJECTS, "*"))):
        if not os.path.isdir(pd):
            continue
        for entry in os.listdir(pd):
            if entry.endswith(".jsonl"):
                homes[entry[:-6]] = pd
            elif os.path.isdir(os.path.join(pd, entry)):
                homes.setdefault(entry, pd)
    return homes


def plan():
    homes = session_homes()
    moves = collections.defaultdict(list)   # destination key -> record lines
    keeps = {}                              # source file -> lines that stay
    stay = collections.Counter()
    for path in sorted(glob.glob(os.path.join(SPOOL, "*.jsonl"))):
        if path.endswith(".filed.jsonl"):
            continue
        src_key = os.path.basename(path)[:-len(".jsonl")]
        kept = []
        for line in open(path, encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                kept.append(line); stay["unreadable record"] += 1; continue
            sid = rec.get("session") if isinstance(rec, dict) else None
            home = homes.get(sid) if sid else None
            if not home:
                kept.append(line); stay["session not found"] += 1; continue
            dst = key_for_project(home)
            if dst == src_key:
                kept.append(line); stay["already correct"] += 1; continue
            moves[dst].append(line)
        keeps[path] = kept
    return moves, keeps, stay


def main():
    apply = "--apply" in sys.argv
    moves, keeps, stay = plan()
    total = sum(len(v) for v in moves.values())
    before = sum(len(v) for v in keeps.values()) + total

    print("MIGRATION PLAN")
    for path, kept in sorted(keeps.items()):
        src = os.path.basename(path)[:-len(".jsonl")]
        print("  %s: %d record(s) stay" % (src, len(kept)))
    for dst, lines in sorted(moves.items()):
        print("  -> %s: %d record(s) arrive" % (dst, len(lines)))
    print("  left in place:", dict(stay) or "{}")
    print("  moving:", total)

    if not apply:
        print("\nDRY RUN. Nothing was changed. Pass --apply to move them.")
        return 0

    # Rewrite the sources FIRST, then append to the destinations. A record is
    # briefly absent from both rather than briefly present in both: a duplicate
    # would be shown twice and filed once, which strands the copy.
    for path, kept in keeps.items():
        with open(path, "w", encoding="utf-8") as fh:
            for line in kept:
                fh.write(line + "\n")
    for dst, lines in moves.items():
        with open(os.path.join(SPOOL, dst + ".jsonl"), "a", encoding="utf-8") as fh:
            for line in lines:
                fh.write(line + "\n")

    after = 0
    for path in glob.glob(os.path.join(SPOOL, "*.jsonl")):
        if path.endswith(".filed.jsonl"):
            continue
        after += sum(1 for l in open(path, encoding="utf-8", errors="replace") if l.strip())
    print("\nAPPLIED. %d record(s) before, %d after." % (before, after))
    if before != after:
        print("MIGRATION LOST RECORDS. Restore from your backup and do not re-run.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
