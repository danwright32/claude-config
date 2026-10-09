#!/usr/bin/env python3
"""The lessons core's evidence, read ONE way for every tool that judges it (claude-config#563, #566).

tools/lessons-core-proposal.py chose the first core and tools/lessons-core-rerank.py re-ranks it every
month. Both read the same index, tags, ages and counts and rank by the same rate, so the reading and
the ranking live here once: two copies of a rule's code drift even while they share its constants
(L370).

  read_index(dir)        every `- Lnnn. ...` line of the LESSONS-INDEX files, and each one's section
  read_tsv(path, cols)   `Lnnn<TAB>...` rows, any other line ignored (headers, END, notes)
  line_chars(line)       a lesson's size in the core, the unit `claude-sync core-set` caps (L81)
  read_counts(path)      one Mac's counts from tools/lesson-citations.py: host, window, stamp, rows
  review_class(...)      disputed, unreviewable or diff: whether a PR review can stand in for it
  rate(...)              citations per 30 days of exposure, so a young lesson is not ranked against
                         sixty days of its elders (L478)
  rank_order(ns, rates)  most cited first, ties by number, so the order is the same on every run

As a command, for the shell job that has to know how old a counts file is:
  lessons_core.py counts-age <file> <now ISO>   prints whole days, or NONE when it carries no stamp
"""
import datetime
import glob
import html
import os
import re
import sys

LINE = re.compile(r"^- L([0-9]+)\. (.+)$")
ROW = re.compile(r"L[0-9]+")
UNREVIEWABLE = ("design", "operate")


def read_index(index_dir):
    lines, sections = {}, {}
    for path in sorted(glob.glob(os.path.join(index_dir, "LESSONS-INDEX-*.md"))):
        section = os.path.basename(path)[len("LESSONS-INDEX-"):-3]
        with open(path, encoding="utf-8") as f:
            for raw in f:
                m = LINE.match(raw.rstrip("\n"))
                if m:
                    n = int(m.group(1))
                    lines[n] = raw.rstrip("\n")
                    sections[n] = section
    return lines, sections


def read_tsv(path, cols):
    out = {}
    with open(path, encoding="utf-8") as f:
        for raw in f:
            parts = raw.rstrip("\n").split("\t")
            if len(parts) >= cols and ROW.fullmatch(parts[0]):
                out[int(parts[0][1:])] = parts[1:]
    return out


def line_chars(line):
    """What one lesson adds to the core: its index line and the newline after it, exactly what
    do_core_set in claude-sync sums (length($0) + 1)."""
    return len(line) + 1


def parse_stamp(text):
    """A UTC stamp written as 2026-10-09T15:00:00Z, or None when it is not one. Never guessed."""
    try:
        return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except (TypeError, ValueError):
        return None


def read_counts(path):
    """One Mac's counts. The header is `HOST h DAYS d ... AT stamp`; the stamp is None when the file
    has none (counts from before #566), which a reader must treat as unmeasurable, never as fresh."""
    with open(path, encoding="utf-8") as f:
        head = f.readline().split()
    host = days = at = None
    if len(head) >= 4 and head[0] == "HOST":
        host = head[1]
        try:
            days = int(head[3])
        except ValueError:
            days = None
    if "AT" in head and head.index("AT") + 1 < len(head):
        at = parse_stamp(head[head.index("AT") + 1])
    rows, bad = {}, []
    for n, v in read_tsv(path, 4).items():
        try:
            rows[n] = tuple(int(x) for x in v[:3])
        except ValueError:
            # A damaged or half written row is named for the caller to refuse on, never dropped (a
            # dropped row reads as a lesson nobody cited) and never a traceback (L11).
            bad.append(n)
    return {"host": host, "days": days, "at": at, "rows": rows, "bad": bad}


def review_class(n, tags, tags2):
    """('disputed', 'a, then b') where two tagging passes disagree about REVIEWABILITY, which Dan
    settled on 2026-09-24 as staying in the core (#563); ('unreviewable', tag) for design or operate,
    which no PR review can see; ('diff', 'diff') otherwise. Design against operate is not a dispute:
    both keep it loading, so there is nothing to settle."""
    t = tags[n]
    if tags2 and n in tags2 and (tags2[n] == "diff") != (t == "diff"):
        return "disputed", f"{t}, then {tags2[n]}"
    if t in UNREVIEWABLE:
        return "unreviewable", t
    return "diff", t


def rate(citations, age_days, window_days):
    exposure = max(1, min(age_days, window_days))
    return citations * 30.0 / exposure


def rank_order(ns, rates):
    return sorted(ns, key=lambda n: (-rates[n], n))


def html_page(title, body):
    """A whole page for Dan to read in Chrome, light or dark, phone width or wide: one shell for the
    proposal and the re-rank, so the two pages cannot drift apart in how they look."""
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<style>
:root {{ --bg:#fbfaf7; --fg:#1d1d1b; --muted:#6b6a64; --line:#e4e1d8; --accent:#8a4b12; --alert:#fff3e6; --code:#f1efe8; }}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{ --bg:#161614; --fg:#ecebe6; --muted:#a19f97; --line:#34332e; --accent:#e0a25e; --alert:#2e2416; --code:#22211e; }} }}
:root[data-theme="dark"] {{ --bg:#161614; --fg:#ecebe6; --muted:#a19f97; --line:#34332e; --accent:#e0a25e; --alert:#2e2416; --code:#22211e; }}
body {{ background:var(--bg); color:var(--fg); font:15px/1.5 -apple-system, system-ui, sans-serif; margin:0 auto; max-width:1100px; padding:24px 16px; }}
h1 {{ font-size:24px; margin:0 0 4px; }} h2 {{ font-size:17px; margin:32px 0 8px; }}
.meta, .sec {{ color:var(--muted); font-weight:400; font-size:13px; }}
.alert {{ background:var(--alert); border-left:3px solid var(--accent); padding:10px 14px; }}
pre {{ background:var(--code); padding:10px 14px; overflow-x:auto; white-space:pre-wrap; word-break:break-all; }}
table {{ border-collapse:collapse; width:100%; }} td, th {{ border-bottom:1px solid var(--line); padding:6px 8px; text-align:left; vertical-align:top; }}
th {{ font-size:13px; color:var(--muted); font-weight:600; }} .n {{ text-align:right; white-space:nowrap; font-variant-numeric:tabular-nums; }}
.wrap {{ overflow-x:auto; }}
</style></head><body>
{body}
</body></html>
"""


def main(argv):
    if len(argv) == 3 and argv[0] == "counts-age":
        now = parse_stamp(argv[2])
        if now is None:
            print(f"counts-age: '{argv[2]}' is not a UTC time like 2026-10-09T15:00:00Z", file=sys.stderr)
            return 2
        try:
            at = read_counts(argv[1])["at"]
        except OSError:
            print("NONE")
            return 0
        print("NONE" if at is None else int((now - at).total_seconds() // 86400))
        return 0
    print("usage: lessons_core.py counts-age <file> <now ISO>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
