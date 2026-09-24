#!/usr/bin/env python3
"""The proposed lessons core, with its evidence, for Dan to approve (claude-config#563).

    python3 tools/lessons-core-proposal.py --counts C [--counts C2] --ages A --tags T
        [--index-dir payload] [--budget 20000] [--band 20] [--probation-days 30]
        [--expect-hosts Daniels-MacBook-Pro-2,Dans-MacBook-Pro] --out-tsv P --out-html P

Inputs are the outputs of tools/lesson-citations.py (one per Mac), tools/lesson-ages.py and
tools/tag-lessons.py. Decisions, in order, each its own name:
  core-disputed      two tagging passes disagree (--second-tags): kept loading, the safe side, and
                     listed with both tags for Dan to settle;
  core-unreviewable  tagged design or operate: no PR review can see it, so it stays whatever its rank;
  core-probation     younger than --probation-days (0 by default: Dan dropped probation on
                     2026-09-24, #563);
  core-ranked        a diff lesson ranked high enough to fit what the budget has left;
  undecided          a diff lesson within --band places of the cut, where the counts are noise (the
                     2026-09-24 ranking had 41 lessons in the noise band at ranks 130 to 170);
  library            the rest: loaded on demand, and the PR lessons review still reads them all.
The rank is citations per 30 days of EXPOSURE, where exposure is the lesson's age capped at the
counting window, so a lesson ten days old is not ranked against sixty days of its elders (L478).
Size is the characters of the index lines the core files would carry, the unit the always loaded
limit is measured in (L81). When the mandatory decisions alone pass the budget it says OVER BUDGET:
the budget is Dan's to raise or the core's to shrink, and the tool does neither.
A lesson missing a tag or an age refuses the whole proposal (exit 1), since either decides whether a
lesson loads, and a default would decide it silently (L113).
"""
import argparse
import glob
import html
import os
import re
import sys

LINE = re.compile(r"^- L([0-9]+)\. (.+)$")


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
            if len(parts) >= cols and re.fullmatch(r"L[0-9]+", parts[0]):
                out[int(parts[0][1:])] = parts[1:]
    return out


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--counts", action="append", required=True)
    ap.add_argument("--ages", required=True)
    ap.add_argument("--tags", required=True)
    ap.add_argument("--second-tags", default="")
    ap.add_argument("--index-dir", default="payload")
    ap.add_argument("--budget", type=int, default=20000)
    ap.add_argument("--band", type=int, default=20)
    # 0 by default since Dan's decision of 2026-09-24 (#563): probation held about a month of intake,
    # 263 lessons and 39k chars on the first proposal, and grew with the pace of new lessons, while
    # the PR lessons review already enforces a new lesson a diff can show.
    ap.add_argument("--probation-days", type=int, default=0)
    ap.add_argument("--expect-hosts", default="Daniels-MacBook-Pro-2,Dans-MacBook-Pro")
    ap.add_argument("--out-tsv", required=True)
    ap.add_argument("--out-html", required=True)
    a = ap.parse_args(argv)

    lines, sections = read_index(a.index_dir)
    if not lines:
        print(f"NO LESSONS in {a.index_dir}")
        return 1
    tags = {n: v[0] for n, v in read_tsv(a.tags, 2).items()}
    tags2 = {n: v[0] for n, v in read_tsv(a.second_tags, 2).items()} if a.second_tags else {}
    ages = {n: int(v[1]) for n, v in read_tsv(a.ages, 3).items()}
    cites, hosts, window = {}, [], 60
    for path in a.counts:
        with open(path, encoding="utf-8") as f:
            head = f.readline().split()
        if len(head) >= 4 and head[0] == "HOST":
            hosts.append(head[1])
            window = int(head[3])
        for n, v in read_tsv(path, 4).items():
            s, _m, r = (int(x) for x in v[:3])
            c = cites.setdefault(n, [0, 0])
            c[0] += s
            c[1] += r

    problems = [f"UNTAGGED L{n}" for n in sorted(lines) if n not in tags]
    problems += [f"UNDATED L{n}" for n in sorted(lines) if n not in ages]
    if problems:
        print("\n".join(problems))
        print("REFUSED: every lesson needs a tag and an age before a proposal can decide it.")
        return 1

    size = {n: len(lines[n]) + 1 for n in lines}
    rows, ranked = {}, []
    for n in sorted(lines):
        s, r = cites.get(n, [0, 0])
        exposure = max(1, min(ages[n], window))
        rate = (s + r) * 30.0 / exposure
        rows[n] = {"tag": tags[n], "age": ages[n], "sessions": s, "reviews": r, "rate": rate}
        # A dispute only where the passes disagree about REVIEWABILITY: design against operate keeps
        # the lesson loading either way, so there is nothing for Dan to settle.
        if tags2 and n in tags2 and (tags2[n] == "diff") != (tags[n] == "diff"):
            rows[n]["tag"] = f"{tags[n]}, then {tags2[n]}"
            rows[n]["decision"] = "core-disputed"
        elif tags[n] in ("design", "operate"):
            rows[n]["decision"] = "core-unreviewable"
        elif ages[n] < a.probation_days:
            rows[n]["decision"] = "core-probation"
        else:
            ranked.append(n)
    mandatory = sum(size[n] for n in rows if rows[n].get("decision"))
    ranked.sort(key=lambda n: (-rows[n]["rate"], n))
    left, cut = a.budget - mandatory, 0
    for n in ranked:
        if size[n] <= left:
            left -= size[n]
            cut += 1
        else:
            break
    over = mandatory > a.budget
    for i, n in enumerate(ranked):
        rows[n]["rank"] = i + 1
        if cut - a.band <= i < cut + a.band:
            rows[n]["decision"] = "undecided"
        elif i < cut:
            rows[n]["decision"] = "core-ranked"
        else:
            rows[n]["decision"] = "library"

    def total(*names):
        return sum(size[n] for n in rows if rows[n]["decision"] in names)
    core_size = total("core-disputed", "core-unreviewable", "core-probation", "core-ranked")
    und_size = total("undecided")
    counts = {}
    for n in rows:
        counts[rows[n]["decision"]] = counts.get(rows[n]["decision"], 0) + 1
    expected = [h for h in a.expect_hosts.split(",") if h]
    missing = [h for h in expected if h not in hosts]

    with open(a.out_tsv, "w", encoding="utf-8") as f:
        f.write("lesson\ttag\tage\tsessions\treviews\trate\tdecision\tchars\n")
        for n in sorted(rows, key=lambda n: (rows[n]["decision"], -rows[n]["rate"], n)):
            r = rows[n]
            f.write(f"L{n}\t{r['tag']}\t{r['age']}\t{r['sessions']}\t{r['reviews']}\t{r['rate']:.1f}\t{r['decision']}\t{size[n]}\n")

    summary = (f"core size {core_size} chars ({counts.get('core-disputed', 0)} disputed, "
               f"{counts.get('core-unreviewable', 0)} unreviewable, "
               f"{counts.get('core-probation', 0)} on probation, {counts.get('core-ranked', 0)} ranked), "
               f"undecided {counts.get('undecided', 0)} lessons ({und_size} chars), "
               f"library {counts.get('library', 0)} lessons; budget {a.budget}")
    print(summary)
    if over:
        print(f"OVER BUDGET: the lessons no review can see, plus probation, come to {mandatory} chars "
              f"before any ranking, over the {a.budget} budget. The decision is Dan's.")
    for h in missing:
        print(f"UNMEASURED: no counts from {h}")

    write_html(a.out_html, rows, lines, sections, size, summary, over, mandatory, a, hosts, missing, window)
    return 0


def write_html(path, rows, lines, sections, size, summary, over, mandatory, a, hosts, missing, window):
    order = ["core-disputed", "core-unreviewable", "core-probation", "core-ranked", "undecided", "library"]
    names = {
        "core-disputed": "Settle these: the two tagging passes disagree, so they stay in the core until you do",
        "core-unreviewable": "Core: no PR review can see these",
        "core-probation": f"Core on probation: younger than {a.probation_days} days",
        "core-ranked": "Core by rank",
        "undecided": "Undecided: at the cut, where the counts are noise",
        "library": "Library: loaded on demand, still read by every PR review",
    }
    e = html.escape
    parts = []
    for d in order:
        members = sorted((n for n in rows if rows[n]["decision"] == d), key=lambda n: (-rows[n]["rate"], n))
        if not members:
            continue
        chars = sum(size[n] for n in members)
        parts.append(f'<section><h2>{e(names[d])} <span class="meta">{len(members)} lessons, {chars:,} chars</span></h2>'
                     '<table><thead><tr><th>Lesson</th><th>When it acts</th><th class="n">Age</th>'
                     '<th class="n">Sessions</th><th class="n">Reviews</th><th class="n">Per 30 days</th></tr></thead><tbody>')
        for n in members:
            r = rows[n]
            text = lines[n].split(". ", 1)[1] if ". " in lines[n] else lines[n]
            parts.append(f'<tr><td><b>L{n}</b> {e(text)} <span class="sec">{e(sections[n])}</span></td>'
                         f'<td>{e(r["tag"])}</td><td class="n">{r["age"]}d</td><td class="n">{r["sessions"]}</td>'
                         f'<td class="n">{r["reviews"]}</td><td class="n">{r["rate"]:.1f}</td></tr>')
        parts.append("</tbody></table></section>")
    warn = ""
    if over:
        warn += (f'<p class="alert"><b>OVER BUDGET.</b> The lessons no review can see, plus those on probation, '
                 f'come to {mandatory:,} characters before any ranking, over the {a.budget:,} budget. '
                 'Raising the budget or shrinking the core is your decision.</p>')
    for h in missing:
        warn += (f'<p class="alert"><b>UNMEASURED: {e(h)}.</b> No counts from that Mac yet, so these ranks '
                 'come from one Mac only. Run tools/lesson-citations.py there before approving.</p>')
    doc = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Lessons core proposal</title>
<style>
:root {{ --bg:#fbfaf7; --fg:#1d1d1b; --muted:#6b6a64; --line:#e4e1d8; --accent:#8a4b12; --alert:#fff3e6; }}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{ --bg:#161614; --fg:#ecebe6; --muted:#a19f97; --line:#34332e; --accent:#e0a25e; --alert:#2e2416; }} }}
:root[data-theme="dark"] {{ --bg:#161614; --fg:#ecebe6; --muted:#a19f97; --line:#34332e; --accent:#e0a25e; --alert:#2e2416; }}
body {{ background:var(--bg); color:var(--fg); font:15px/1.5 -apple-system, system-ui, sans-serif; margin:0 auto; max-width:1100px; padding:24px 16px; }}
h1 {{ font-size:24px; margin:0 0 4px; }} h2 {{ font-size:17px; margin:32px 0 8px; }}
.meta, .sec {{ color:var(--muted); font-weight:400; font-size:13px; }}
.alert {{ background:var(--alert); border-left:3px solid var(--accent); padding:10px 14px; }}
table {{ border-collapse:collapse; width:100%; }} td, th {{ border-bottom:1px solid var(--line); padding:6px 8px; text-align:left; vertical-align:top; }}
th {{ font-size:13px; color:var(--muted); font-weight:600; }} .n {{ text-align:right; white-space:nowrap; font-variant-numeric:tabular-nums; }}
.wrap {{ overflow-x:auto; }}
</style></head><body>
<h1>Lessons core proposal</h1>
<p class="meta">Counted from {e(", ".join(hosts) or "no Mac")} over {window} days, prose only (issue 563). {e(summary)}.</p>
{warn}
<p>Approve, move or strike lessons by telling Claude which. Nothing here changes what loads until the core generator (issue 564) is switched on, and the PR lessons review measurement (issue 562) says it is safe.</p>
<div class="wrap">{"".join(parts)}</div>
</body></html>
"""
    with open(path, "w", encoding="utf-8") as f:
        f.write(doc)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
