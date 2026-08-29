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
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SPOOL = os.environ.get("CLAUDE_ISSUE_SPOOL_DIR") or os.path.expanduser("~/.claude-issue-spool")
PROJECTS = os.environ.get("CLAUDE_PROJECTS_DIR") or os.path.expanduser("~/.claude/projects")
LIB = os.environ.get("CLAUDE_ISSUE_SPOOL_LIB") or os.path.join(HERE, "lib", "issue-spool.sh")
HOME = os.environ.get("CLAUDE_MIGRATE_HOME") or os.path.expanduser("~")
EXAMPLE_DIRS = 10   # how many distinct unplaceable directories to name


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


def project_for_cwd(cwd, projects):
    """The project directory for an agent's working directory, or None.

    Claude Code names a project's folder after the path it was started in, with
    every character that is not a letter or digit replaced by a dash. That makes
    this a CHECK rather than a guess: the encoded name either is a folder that
    exists or it is not.

    Needed because a session id only places a record while that session's
    transcript is still on disk. Measured on a second machine 2026-08-29: 117 of
    128 records named a session that was gone, and keying on the session alone
    stranded every one of them.

    The walk goes UP, because a session sits at or above where its agents work
    (a nested repo, a worktree). It STOPS BEFORE the home directory: everything
    lives under home, so a match there proves nothing and would sweep every
    unplaceable record on the machine into one heap.

    No realpath anywhere: the folder name was derived from the path string
    Claude Code held, so the comparison has to be made against that same string.
    """
    if not cwd:
        return None
    home = os.path.normpath(HOME)
    d = os.path.normpath(cwd)
    while d and d not in (home, os.sep):
        cand = os.path.join(projects, re.sub(r"[^A-Za-z0-9]", "-", d))
        if os.path.isdir(cand):
            return cand
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None


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
    unplaceable = collections.Counter()      # the directories nothing could place, by path
    unplaceable_kind = collections.Counter() # and WHAT those records are
    placed_by = collections.Counter()       # which route found each record a home
    already = [0]                           # found a home, and was already in it
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
            if home:
                placed_by["session"] += 1
            else:
                # The two ways the session can fail to place a record are
                # different problems and are counted apart (L11): one never
                # named a session, the other named one whose transcript is gone.
                stay["no session recorded" if not sid else "session not found"] += 1
                home = project_for_cwd(rec.get("cwd") if isinstance(rec, dict) else None,
                                       PROJECTS)
                if not home:
                    kept.append(line)
                    stay["directory matched no project"] += 1
                    # Keep the DIRECTORY, not just the tally. A count cannot say
                    # whether these are deleted worktrees, paths from another
                    # machine, or something nobody has thought of, and guessing
                    # that from a number is how the first two attempts at this
                    # went wrong.
                    unplaceable[(rec.get("cwd") if isinstance(rec, dict) else None)
                                or "(no directory recorded)"] += 1
                    # A stranded finding an agent deliberately wrote down is
                    # worth real effort to rescue; a stranded record of a
                    # harvest that failed is worth none, and a count of records
                    # cannot tell them apart.
                    unplaceable_kind[rec.get("status") or "(no status)"] += 1
                    continue
                placed_by["directory"] += 1
            dst = key_for_project(home)
            if dst == src_key:
                kept.append(line); already[0] += 1; continue
            moves[dst].append(line)
        keeps[path] = kept
    return moves, keeps, stay, placed_by, already[0], unplaceable, unplaceable_kind


def main():
    apply = "--apply" in sys.argv
    moves, keeps, stay, placed_by, already, unplaceable, unplaceable_kind = plan()
    total = sum(len(v) for v in moves.values())
    before = sum(len(v) for v in keeps.values()) + total

    print("MIGRATION PLAN")
    for path, kept in sorted(keeps.items()):
        src = os.path.basename(path)[:-len(".jsonl")]
        print("  %s: %d record(s) stay" % (src, len(kept)))
    for dst, lines in sorted(moves.items()):
        print("  -> %s: %d record(s) arrive" % (dst, len(lines)))
    print("  found a home by:", dict(placed_by) or "{}")
    print("  already in the right place:", already)
    print("  could not be placed:", dict(stay) or "{}")
    if unplaceable_kind:
        print("  what those unplaceable records are:", dict(unplaceable_kind))
    if unplaceable:
        # A sample, one line per distinct directory, capped: a spool with
        # hundreds of these has to stay readable or nobody reads any of it.
        shown = unplaceable.most_common(EXAMPLE_DIRS)
        print("  directories nothing could place (%d distinct, showing %d):"
              % (len(unplaceable), len(shown)))
        for d, n in shown:
            state = "still there" if os.path.isdir(d) else "gone"
            print("    %4d x  [%s]  %s" % (n, state, d))
        if len(unplaceable) > len(shown):
            print("    ...and %d more distinct director(ies)." % (len(unplaceable) - len(shown)))
    print("  moving:", total)
    # The routes must account for every record that found a home, and no record
    # may be counted on two of these lines. Printed rather than assumed, because
    # a tally nobody checks is how the first version reported 332 records twice.
    if placed_by and sum(placed_by.values()) != total + already:
        print("  COUNTS DO NOT ADD UP: %d found a home but %d are moving and %d were already "
              "in place. Do not run --apply." % (sum(placed_by.values()), total, already))
        return 1

    if not apply:
        print("\nDRY RUN. Nothing was changed. Pass --apply to move them.")
        return 0

    # A copy of the whole spool BEFORE anything moves. This runs unsupervised on
    # a second machine, it moves the only copy of records nobody has read, and
    # nothing here can be put back by hand. A dry run takes none: it changes
    # nothing, so a backup would only be litter that looks like a recovery point.
    # The stamp is only good to the second, and two runs inside one second are
    # ordinary in a test and possible by hand. A colliding name must not take the
    # run down before anything is backed up, so the name is made unique rather
    # than assumed to be.
    base = os.path.join(
        os.path.dirname(SPOOL.rstrip("/")) or ".",
        os.path.basename(SPOOL.rstrip("/")) + ".backup-" + time.strftime("%Y%m%d-%H%M%S"))
    backup, n = base, 1
    while os.path.exists(backup):
        backup = "%s-%d" % (base, n)
        n += 1
    shutil.copytree(SPOOL, backup)
    print("backup: %s" % backup)

    # DESTINATIONS FIRST, sources second. Killed between the two, a record is
    # present TWICE rather than nowhere. A duplicate is visible and can be
    # cleared up; a record that exists in neither file is gone, and it is
    # precisely a record nobody has read yet (L5).
    for dst, lines in moves.items():
        with open(os.path.join(SPOOL, dst + ".jsonl"), "a", encoding="utf-8") as fh:
            for line in lines:
                fh.write(line + "\n")

    # Test seam: the one instant that decides whether a kill loses records, so
    # it can be tested rather than raced for.
    if os.environ.get("CLAUDE_MIGRATE_ABORT_AFTER_WRITE"):
        print("aborting after the write, on purpose (test seam)")
        return 1

    for path, kept in keeps.items():
        with open(path, "w", encoding="utf-8") as fh:
            for line in kept:
                fh.write(line + "\n")

    after = 0
    for path in glob.glob(os.path.join(SPOOL, "*.jsonl")):
        if path.endswith(".filed.jsonl"):
            continue
        after += sum(1 for l in open(path, encoding="utf-8", errors="replace") if l.strip())
    print("\nAPPLIED. %d record(s) before, %d after." % (before, after))
    if before != after:
        print("MIGRATION LOST RECORDS. Restore from %s and do not re-run." % backup)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
