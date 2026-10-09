#!/usr/bin/env python3
"""The monthly re-rank of the lessons core: which lessons should move in and out (claude-config#566).

    python3 tools/lessons-core-rerank.py --index-dir payload --core payload/LESSONS-CORE.txt
        --counts-dir lesson-counts (--bands-dir lesson-bands | --expect-hosts A,B)
        --ages AGES --tags lesson-tags.tsv [--second-tags lesson-tags-second.tsv]
        [--now 2026-10-09T15:00:00Z] [--stale-days 14] [--max-moves 10] [--band 5] [--cap N]
        --out-tsv P --out-html P --out-list P

It only PROPOSES. Nothing here runs `claude-sync core-set`: the page names the command, and Dan
approves. The rules are his decisions of 2026-09-24 (#563):

  - a lesson no PR review can see (tagged design or operate, or one the two tagging passes disputed)
    STAYS in the core whatever its rank, so it is never proposed out;
  - the rest of the core is the most cited reviewable lessons. Their number is the core's SEATS, read
    from the list as it stands (20 when Dan approved it), so a re-rank swaps lessons through the
    seats and never grows them;
  - new lessons start in the library and earn their way in by citations: a reviewable one by ranking
    inside the seats, one no review can see by being cited at least as often as the last seat (and
    at all), after which it stays like the rest of its kind.

The rank is the proposal tool's, from tools/lib/lessons_core.py (L370): prose citations plus review
citations, both Macs added together, per 30 days of exposure.

Bounded so the core cannot churn wholesale: at most --max-moves moves a month (10 by default, one
in or out each; a swap is two). With 20 seats that is at most 5 swaps, a quarter of the seats, so the
reviewable part cannot turn over in under four months, and the page stays short enough to judge in
one sitting. Whatever the cap holds back is listed as held, never dropped. And a seat holder leaves
only when it ranks more than --band places (5) below the seats, so two lessons with nearly the same
counts do not trade places every month.

Refuses rather than guessing, each with its own exit code so the job can tell them apart (L11):
  1  REFUSED: a lesson with no tag (or no tags file), no age, a tag outside diff, design and operate,
     a core list naming no lesson, or two Macs that counted over different windows (L711);
  2  UNMEASURED: a Mac whose counts are missing, carry no time stamp, name another Mac, are dated in
     the future, or are older than --stale-days. Never read as zero (L90, L530);
  3  INACTIVE: there is no core list, so the core is not in use and there is nothing to re-rank.
The Macs expected are those holding a lesson band (lesson-bands/), the Macs that write lessons,
derived rather than listed by hand (L41).

The size is in the unit `claude-sync core-set` caps (index line characters, L81), measured against
the same cap, SYNC_CORE_CAP or core-set's default.
"""
import argparse
import datetime
import html
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from lessons_core import (UNREVIEWABLE, html_page, line_chars, parse_stamp, rank_order, rate,  # noqa: E402
                          read_counts, read_index, read_tsv, review_class)

DEFAULT_MAX_MOVES = 10
DEFAULT_BAND = 5
# Derived from the two schedules (L614): a Mac recounts once its counts are RECOUNT_DAYS (7) old and
# the job runs daily, so while both Macs are in use the other Mac's counts are at worst 8 days old
# when the re-rank reads them. 14 leaves a Mac about six more days asleep or switched off before the
# re-rank refuses on its account. tools/run-lessons-core-rerank.sh holds the 7.
DEFAULT_STALE_DAYS = 14
# claude-sync's do_core_set default, read from SYNC_CORE_CAP exactly as it reads it, so the size this
# page reports is judged against the cap the apply command will meet.
CORE_SET_DEFAULT_CAP = 20000
EXIT_REFUSED, EXIT_UNMEASURED, EXIT_INACTIVE = 1, 2, 3
TAG_VALUES = ("diff",) + UNREVIEWABLE


def core_ids(path):
    """Each Lnnn in the list once, comments and blank lines ignored: lesson_core_list_ids in claude-sync."""
    out, seen = [], set()
    with open(path, encoding="utf-8") as f:
        for raw in f:
            for tok in raw.split("#", 1)[0].split():
                if re.fullmatch(r"L[0-9]+", tok) and tok not in seen:
                    seen.add(tok)
                    out.append(int(tok[1:]))
    return out


def the_cap(given):
    if given is not None:
        return given
    env = os.environ.get("SYNC_CORE_CAP", "")
    return int(env) if env.isdigit() else CORE_SET_DEFAULT_CAP


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--index-dir", required=True)
    ap.add_argument("--core", required=True)
    ap.add_argument("--counts-dir", required=True)
    ap.add_argument("--bands-dir", default="")
    ap.add_argument("--expect-hosts", default="")
    ap.add_argument("--ages", required=True)
    ap.add_argument("--tags", required=True)
    ap.add_argument("--second-tags", default="")
    ap.add_argument("--now", default="")
    ap.add_argument("--stale-days", type=int, default=DEFAULT_STALE_DAYS)
    ap.add_argument("--max-moves", type=int, default=DEFAULT_MAX_MOVES)
    ap.add_argument("--band", type=int, default=DEFAULT_BAND)
    ap.add_argument("--cap", type=int, default=None)
    ap.add_argument("--out-tsv", required=True)
    ap.add_argument("--out-html", required=True)
    ap.add_argument("--out-list", required=True)
    a = ap.parse_args(argv)

    if a.now:
        now = parse_stamp(a.now)
        if now is None:
            print(f"--now '{a.now}' is not a UTC time like 2026-10-09T15:00:00Z, so nothing was judged")
            return EXIT_REFUSED
    else:
        now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    cap = the_cap(a.cap)
    when = now.strftime("%Y-%m-%d")

    def refuse(code, title, lines_out, remedies, extra=""):
        for line in lines_out:
            print(line)
        for r in remedies:
            print(r)
        with open(a.out_tsv, "w", encoding="utf-8") as f:
            f.write("move\tlesson\ttag\tsessions\treviews\trate\trank\tchars\treason\n")
        if os.path.exists(a.out_list):
            os.remove(a.out_list)
        e = html.escape
        body = (f'<h1>{e(title)}</h1><p class="meta">Re-rank of {e(when)}. Nothing is proposed this time, '
                'and nothing has changed: the core loads exactly as before.</p>'
                + "".join(f'<p class="alert">{e(line)}</p>' for line in lines_out)
                + "".join(f"<p>{e(r)}</p>" for r in remedies) + extra)
        with open(a.out_html, "w", encoding="utf-8") as f:
            f.write(html_page("Lessons core re-rank", body))
        return code

    if not os.path.exists(a.core):
        return refuse(EXIT_INACTIVE, "The lessons core is not in use",
                      [f"INACTIVE: there is no core list at {a.core}, so every lesson loads and there is nothing to re-rank."], [])

    lines, sections = read_index(a.index_dir)
    if not lines:
        return refuse(EXIT_REFUSED, "Re-rank refused", [f"REFUSED: no lesson line in {a.index_dir}/LESSONS-INDEX-*.md"], [])
    problems, remedies = [], []
    core = core_ids(a.core)
    unknown = [n for n in core if n not in lines]
    if unknown:
        problems.append("NOT A LESSON: the core list names " + ", ".join(f"L{n}" for n in unknown)
                        + ", which the index does not hold, so claude-sync is already loading the whole library instead.")
        remedies.append("Set the list again with claude-sync core-set, without those numbers.")

    tags, tags2 = {}, {}
    for path, into in ((a.tags, tags), (a.second_tags, tags2)):
        if not path:
            continue
        if not os.path.exists(path):
            problems.append(f"NO TAGS: there is no tags file at {path}, so no lesson can be judged reviewable or not.")
            continue
        into.update({n: v[0] for n, v in read_tsv(path, 2).items()})
    bad = sorted(n for d in (tags, tags2) for n in d if d[n] not in TAG_VALUES)
    if bad:
        problems.append("BADTAG " + ", ".join(f"L{n}" for n in bad) + ": a tag must be diff, design or operate.")
    if os.path.exists(a.tags):
        untagged = [n for n in sorted(lines) if n not in tags]
        problems += [f"UNTAGGED L{n}" for n in untagged]
        if untagged:
            remedies.append(f"Tag them, in ~/claude-config-sync: python3 tools/tag-lessons.py --skip-tagged {a.tags} "
                            f"> new-tags.txt, then add its lines to {os.path.basename(a.tags)} and commit it. "
                            "The tag decides whether a lesson can ever leave the core, so it is never defaulted (L113).")
    ages = {n: int(v[1]) for n, v in read_tsv(a.ages, 3).items()} if os.path.exists(a.ages) else {}
    problems += [f"UNDATED L{n}" for n in sorted(lines) if n not in ages]

    if a.expect_hosts:
        hosts = [h for h in a.expect_hosts.split(",") if h]
    elif a.bands_dir and os.path.isdir(a.bands_dir):
        hosts = sorted(h for h in os.listdir(a.bands_dir) if os.path.isfile(os.path.join(a.bands_dir, h)))
    else:
        hosts = []
    if not hosts:
        problems.append("NO MACS: neither --expect-hosts nor a lesson-bands folder names a Mac, so whose counts are missing cannot be told.")
    unmeasured, used, notes = [], [], []
    for h in hosts:
        path = os.path.join(a.counts_dir, f"{h}.tsv")
        if not os.path.exists(path):
            unmeasured.append(f"UNMEASURED: {h}: no counts at {path}, so its citations are unknown, not zero.")
            continue
        got = read_counts(path)
        if got["host"] != h:
            unmeasured.append(f"UNMEASURED: {h}: the counts filed under {h} were taken on {got['host'] or 'no Mac it names'}.")
        elif got["at"] is None:
            unmeasured.append(f"UNMEASURED: {h}: its counts carry no time stamp, so how old they are cannot be told.")
        elif got["at"] > now:
            unmeasured.append(f"UNMEASURED: {h}: its counts are dated {got['at']:%Y-%m-%d %H:%M} UTC, in the future, so one Mac's clock is wrong.")
        else:
            age_days = int((now - got["at"]).total_seconds() // 86400)
            if (now - got["at"]).total_seconds() > a.stale_days * 86400:
                unmeasured.append(f"UNMEASURED: {h}: its counts are {age_days} days old, over the {a.stale_days} day limit.")
            else:
                got["age_days"] = age_days
                used.append(got)
    if os.path.isdir(a.counts_dir):
        for f in sorted(os.listdir(a.counts_dir)):
            if f.endswith(".tsv") and f[:-4] not in hosts:
                notes.append(f"NOTE: counts from {f[:-4]} are left out: that Mac holds no lesson band, so it is not one of the Macs expected.")
    windows = sorted({g["days"] for g in used})
    if len(windows) > 1 or None in windows:
        problems.append("WINDOWS DIFFER: " + ", ".join(f"{g['host']} counted {g['days']} days" for g in used)
                        + "; citations over different windows cannot be added into one rate.")
    if unmeasured:
        remedies.append("Counts reach this Mac when the Mac named above runs the re-rank job (it recounts weekly) and syncs. "
                        "To recount by hand there: python3 tools/lesson-citations.py > c.tsv, then claude-sync record-lesson-counts c.tsv.")
    for n in notes:
        print(n)
    if problems or unmeasured:
        title = "Re-rank refused" if problems else "Re-rank not measured"
        return refuse(EXIT_REFUSED if problems else EXIT_UNMEASURED, title, problems + unmeasured, remedies)

    window = windows[0]
    cites = {}
    for g in used:
        for n, (s, _m, r) in g["rows"].items():
            c = cites.setdefault(n, [0, 0])
            c[0] += s
            c[1] += r
    rates, kind, shown = {}, {}, {}
    for n in lines:
        s, r = cites.get(n, [0, 0])
        rates[n] = rate(s + r, ages[n], window)
        kind[n], shown[n] = review_class(n, tags, tags2)
    size = {n: line_chars(lines[n]) for n in lines}
    in_core = set(core)
    protected = [n for n in core if kind[n] != "diff"]
    seat_holders = [n for n in core if kind[n] == "diff"]
    seats = len(seat_holders)
    ranked = rank_order([n for n in lines if kind[n] == "diff"], rates)
    rank_of = {n: i + 1 for i, n in enumerate(ranked)}
    cut = rates[ranked[seats - 1]] if 0 < seats <= len(ranked) else None
    entrants = [n for n in ranked[:seats] if n not in in_core]
    leavers = sorted((n for n in seat_holders if rank_of[n] > seats + a.band), key=lambda n: (-rank_of[n], n))
    pairs = list(zip(entrants, leavers))
    waiting = entrants[len(pairs):]
    additions = rank_order([n for n in lines if kind[n] != "diff" and n not in in_core and cut is not None
                            and rates[n] > 0 and rates[n] >= cut], rates)
    candidates = sorted([(rates[e], e, l) for e, l in pairs] + [(rates[n], n, None) for n in additions],
                        key=lambda c: (-c[0], c[1]))
    moves, held, spent = [], [], 0
    for _r, e, l in candidates:
        cost = 2 if l is not None else 1
        (moves if spent + cost <= a.max_moves else held).append((e, l))
        if spent + cost <= a.max_moves:
            spent += cost
    ins = [e for e, _ in moves]
    outs = [l for _, l in moves if l is not None]
    new_core = sorted((in_core - set(outs)) | set(ins))
    before, after = sum(size[n] for n in core), sum(size[n] for n in new_core)
    over = after > cap

    def row(move, n, reason):
        s, r = cites.get(n, [0, 0])
        rk = rank_of.get(n, "")
        return {"move": move, "n": n, "tag": shown[n], "s": s, "r": r, "rate": rates[n], "rank": rk, "reason": reason}

    rows = []
    for e, l in moves:
        if l is None:
            rows.append(row("in", e, f"no PR review can see it, and at {rates[e]:.1f} citations per 30 days it is cited "
                                     f"at least as often as the last seat ({cut:.1f}); once in, it stays"))
        else:
            rows.append(row("in", e, f"ranked {rank_of[e]} of {len(ranked)} reviewable lessons, inside the {seats} seats; takes L{l}'s seat"))
            rows.append(row("out", l, f"ranked {rank_of[l]} of {len(ranked)}, more than {a.band} places below the {seats} seats; gives its seat to L{e}"))
    for e, l in held:
        rows.append(row("held-in", e, f"held back by the move cap of {a.max_moves}; next month, if it still ranks here"))
        if l is not None:
            rows.append(row("held-out", l, f"held back by the move cap of {a.max_moves}, with L{e}"))
    for n in waiting:
        rows.append(row("waiting", n, f"ranked {rank_of[n]}, inside the {seats} seats, but no seat holder ranks more than "
                                      f"{a.band} places below them, so no seat is free"))

    with open(a.out_tsv, "w", encoding="utf-8") as f:
        f.write("move\tlesson\ttag\tsessions\treviews\trate\trank\tchars\treason\n")
        for x in rows:
            f.write(f"{x['move']}\tL{x['n']}\t{x['tag']}\t{x['s']}\t{x['r']}\t{x['rate']:.1f}\t{x['rank']}\t{size[x['n']]}\t{x['reason']}\n")
    with open(a.out_list, "w", encoding="utf-8") as f:
        f.write(f"# The lessons core as the re-rank of {when} proposes it (claude-config#566). Apply it with\n")
        f.write("# `claude-sync core-set` on this file, which checks the cap; the re-rank never applies it.\n")
        f.write(f"# count {len(new_core)}\n")
        f.write("".join(f"L{n}\n" for n in new_core))

    for x in rows:
        print(f"{x['move'].upper()} L{x['n']}: {x['reason']}")
    summary = (f"{len(ins) + len(outs)} moves ({len(ins)} in, {len(outs)} out, {len(held)} held back), move cap {a.max_moves}; "
               f"core now {len(core)} lessons, {before} chars ({len(protected)} no review can see, {seats} seats); "
               f"after the moves {len(new_core)} lessons, {after} chars; cap {cap}")
    print(summary)
    for g in used:
        print(f"COUNTS {g['host']}: taken {g['age_days']} days ago, covering {window} days")
    if over:
        print(f"OVER CAP: after the moves the core is {after} chars, {after - cap} over the {cap} cap core-set "
              "enforces, so applying it needs SYNC_CORE_OVER_CAP=1, which is Dan's decision.")
    command = f"{'SYNC_CORE_OVER_CAP=1 ' if over else ''}~/claude-config-sync/claude-sync core-set {os.path.abspath(a.out_list)}"
    print(f"APPLY: {command}")
    write_page(a, rows, lines, sections, size, summary, over, after, cap, command, used, window, when, notes, len(ins) + len(outs))
    return 0


def write_page(a, rows, lines, sections, size, summary, over, after, cap, command, used, window, when, notes, n_moves):
    e = html.escape
    groups = [
        ("in", "Coming in"),
        ("out", "Going out"),
        ("held-in", "Held back by the move cap"),
        ("held-out", "Held back by the move cap, staying for now"),
        ("waiting", "Waiting for a seat"),
    ]
    parts = []
    for move, title in groups:
        members = [x for x in rows if x["move"] == move]
        if not members:
            continue
        chars = sum(size[x["n"]] for x in members)
        parts.append(f'<section><h2>{e(title)} <span class="meta">{len(members)} lessons, {chars:,} chars</span></h2>'
                     '<table><thead><tr><th>Lesson</th><th>When it acts</th><th class="n">Sessions</th>'
                     '<th class="n">Reviews</th><th class="n">Per 30 days</th><th>Why</th></tr></thead><tbody>')
        for x in members:
            n = x["n"]
            text = lines[n].split(". ", 1)[1] if ". " in lines[n] else lines[n]
            parts.append(f'<tr><td><b>L{n}</b> {e(text)} <span class="sec">{e(sections[n])}</span></td>'
                         f'<td>{e(x["tag"])}</td><td class="n">{x["s"]}</td><td class="n">{x["r"]}</td>'
                         f'<td class="n">{x["rate"]:.1f}</td><td>{e(x["reason"])}</td></tr>')
        parts.append("</tbody></table></section>")
    if n_moves == 0:
        parts.insert(0, "<p><b>No moves this month.</b> The core already holds the most cited reviewable lessons "
                        "for its seats, and no new lesson no review can see has been cited enough to come in.</p>")
    counted = "; ".join(f"{e(g['host'])}, {g['age_days']} days ago" for g in used)
    warn = ""
    if over:
        warn = (f'<p class="alert"><b>OVER CAP.</b> After these moves the core is {after:,} characters, '
                f'{after - cap:,} over the {cap:,} cap that core-set enforces. Applying it needs '
                'SYNC_CORE_OVER_CAP=1, which is your decision, as it was for the list you approved.</p>')
    body = (f"<h1>Lessons core re-rank, {e(when)}</h1>"
            f'<p class="meta">Counted on {counted}, prose and review citations over {window} days. {e(summary)}.</p>'
            f"{warn}"
            + "".join(f'<p class="meta">{e(n)}</p>' for n in notes)
            + "<p>Nothing changes until you approve. To apply exactly this, tell Claude, or run:</p>"
            f"<pre>{e(command)}</pre>"
            f'<div class="wrap">{"".join(parts)}</div>')
    with open(a.out_html, "w", encoding="utf-8") as f:
        f.write(html_page("Lessons core re-rank", body))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
