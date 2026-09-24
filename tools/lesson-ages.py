#!/usr/bin/env python3
"""The age of every current lesson, from the first appearance of its rule text (claude-config#563).

    python3 tools/lesson-ages.py [--repo DIR] [--today YYYY-MM-DD]

Reads the whole history of payload/LESSONS.md in ONE `git log -p` pass (not one `git log -S` per
lesson, which rescans history 700 times) and dates each lesson by the earliest commit that added its
rule text, under ANY number. A lesson's identity is its rule sentence, not its number (claude-sync,
#199): two Macs minting the same number get one renumbered, and dating by number would make an old
lesson look new and give it a per day rate it never earned (L576). Every lesson whose rule text is
older than its number is printed as RENUMBERED for a person to spot check.

Output, tab separated: lesson, first seen (date), age in days. Then RENUMBERED lines, then END.
Exits 1 with NO HISTORY when the repository has no history of the lessons file.
"""
import argparse
import datetime
import os
import re
import subprocess
import sys

ENTRY = re.compile(r"^- \*\*L([0-9]+)\.\s*(.*)$")


def rule_key(text):
    """The rule sentence normalised: whitespace collapsed, cut at the closing **."""
    text = text.split("**", 1)[0]
    return re.sub(r"\s+", " ", text).strip().lower()[:160]


def entries(lines):
    """(number, rule key) for every entry in a sequence of lines, joining wrapped rules."""
    out, cur_n, buf = [], None, ""
    for line in lines:
        m = ENTRY.match(line)
        if m:
            if cur_n is not None:
                out.append((cur_n, rule_key(buf)))
            cur_n, buf = int(m.group(1)), m.group(2)
            if "**" in buf:
                out.append((cur_n, rule_key(buf)))
                cur_n, buf = None, ""
            continue
        if cur_n is not None:
            buf += " " + line.strip()
            if "**" in line:
                out.append((cur_n, rule_key(buf)))
                cur_n, buf = None, ""
    return out


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=".")
    ap.add_argument("--today", default=datetime.date.today().isoformat())
    a = ap.parse_args(argv)
    path = "payload/LESSONS.md"
    try:
        log = subprocess.run(
            # --diff-merges=first-parent: a sync's conflict resolution adds entries IN the merge
            # commit, which a plain `log -p` shows no diff for. Measured 2026-09-24: L187 came in
            # that way and went undated without it.
            ["git", "-C", a.repo, "log", "--reverse", "--date=short", "--format=@@@%ad", "-p",
             "--unified=0", "--diff-merges=first-parent", "--", path],
            capture_output=True, text=True, check=True).stdout
        current = subprocess.run(["git", "-C", a.repo, "show", f"HEAD:{path}"],
                                 capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        log, current = "", ""
    if not log.strip() or not current.strip():
        print(f"NO HISTORY: {os.path.abspath(a.repo)} holds no history of {path}, so no lesson can be dated")
        return 1

    first_by_key, first_by_num = {}, {}
    date, added = None, []

    def flush():
        for n, key in entries(added):
            first_by_key.setdefault(key, (date, n))
            first_by_num.setdefault(n, date)

    for line in log.splitlines():
        if line.startswith("@@@"):
            flush()
            date, added = line[3:], []
        elif line.startswith("+") and not line.startswith("+++"):
            added.append(line[1:])
    flush()

    today = datetime.date.fromisoformat(a.today)
    renumbered = []
    for n, key in entries(current.splitlines()):
        seen, first_n = first_by_key.get(key, (first_by_num.get(n), n))
        seen = seen or first_by_num.get(n)
        if not seen:
            continue
        age = (today - datetime.date.fromisoformat(seen)).days
        print(f"L{n}\t{seen}\t{age}")
        if first_n != n:
            renumbered.append(f"RENUMBERED L{n} first seen as L{first_n} on {seen}")
    for r in renumbered:
        print(r)
    print("END")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
