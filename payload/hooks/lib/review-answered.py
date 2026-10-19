#!/usr/bin/env python3
"""Which findings of a lessons review repeat one ALREADY ANSWERED (claude-config#1338).

Usage:
  review-answered.py --repo <dir> --head <sha> --review <review file> --earlier <rows file>
                     [--comments <json file>]

--earlier holds one earlier review of the same pull request per line, "<sha>\\t<started>\\t<file>",
nearest head first, as pr-review.sh's earlier_rows finds them. --comments holds the comments that
can answer a finding: a JSON list of {"author", "at", "body", "on"}, already narrowed by
pr-review.sh to comments by people with write access whose first line names the lessons review,
from this pull request ("on" empty) and from an earlier one it replaces ("on" its number, #1340).

Without --comments it prints how many findings of the review have a CANDIDATE earlier finding on
this Mac (the same file, the cited lines unchanged since, the same claim), which the caller names
when the comments cannot be read. With --comments it prints one line per finding that repeats an
answered one: "<n>\\t<sha>\\t<author>\\t<at>\\t<on>\\t<how>", where n counts the review's finding
lines from 1, on is the earlier pull request's number or "-" (a tab separated field read by bash
must never be empty, since bash drops an empty one), and how is "review" (an earlier review on this
Mac raised it, the rule below) or
"quote" (the answer quotes it, QUOTED ANSWERS below; sha is then the head the answer names).
Anything that goes wrong exits non zero, and the caller then takes every finding as new, which is
what the gate did before this existed.

WHY. On 2026-10-19 a Bidspoke pull request drew the same two findings at five heads in a row,
though both had been answered with evidence in "Lessons review" comments and every review was given
those comments. The reviewer's prompt asked it not to raise a settled point again, and a rule that
lives only in a prompt is a hope (L27). So the gate decides it, by a rule strict enough that a new
point is never let through for resembling an old one. A finding is answered only when ALL of these
hold for one earlier finding:

  1. the same file;
  2. the lines it cited (three either side, the window line_since in pr-review.sh judges) are
     unchanged from that earlier head to this one, and the file exists at both;
  3. this finding cites the earlier line as carried to this head through the edits above it (a
     hunk wholly above the window shifts it by its net lines), give or take three;
  4. largely the same claim: word overlap (Jaccard) of at least MIN_SIMILARITY, see below;
  5. a comment, given in --comments, written at or after that earlier review STARTED (no answer can
     come before the finding exists), naming the file and the earlier line as "<name>:<line>", the
     way the refusal's own lines and the answers written to them cite one ("Ans.swift:14:").

MIN_SIMILARITY was measured on 2026-10-19 over every pair of findings the stored reviews on the
personal MacBook raised on the same branch, same file, within three lines (657 pairs over 350
branches). Forty pairs between 0.1 and 0.75 were read and labelled by hand: of those raising a
DIFFERENT point at the same lines, the highest overlap was 0.31 and all others were at most 0.25;
those raising the SAME point again ran from 0.19 to 0.65. At 0.35 none of the different points
matched and 13 of 22 repeats did. A repeat it misses is shown as new, which is what happened before,
so the threshold errs that way.

QUOTED ANSWERS (claude-config#1340). The rule above needs this Mac's copy of the earlier finding, so
it cannot see a finding raised only on the other Mac, nor one raised before a REBASE (the earlier
head shares no commit of the branch's own with this one, so it is not this pull request's history
by earlier_rows). The refusal therefore asks for an answer to quote each finding it answers, on a
line of its own beginning "> ", exactly as the refusal showed it, under a first line naming the
head it was raised at ("Lessons review at 1a2b3c4:"). Such a quote is a finding line in the same
shape a review file holds, so it is matched by the same conditions, with the quote in place of the
stored finding and the head the answer names in place of the earlier review's:

  1. the quote names the same file, as its full path;
  2. and 3. the lines it cites are unchanged from the head NAMED above it (the nearest commit named
     before the quote, as a hex prefix of seven or more that this checkout resolves to a commit with
     that prefix) to this one, and carried to this finding's line, give or take three;
  4. largely the same claim, by the same MIN_SIMILARITY. A quote the refusal cut (ending "...") is
     compared with this finding cut to the same length;
  5. the comment is one --comments holds: written by somebody with write access, first line naming
     the lessons review. The quote is what ties the answer to the finding, so no time is compared.

A line not beginning "> " is prose, never a quote, so an answer's own words are not matched as a
finding. A head the comment does not name, or this checkout does not hold, leaves the quote
matching nothing, and the finding new.
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys

MIN_SIMILARITY = 0.35
WINDOW = 3
FINDING = re.compile(r'^([^ :]+):([0-9]+): (.*)$')
QUOTE = re.compile(r'^\s*>\s?`?([^\s`:]+):([0-9]+): (.*?)`?\s*$')
HEAD_TOKEN = re.compile(r'(?<![0-9A-Za-z])[0-9a-f]{7,40}(?![0-9A-Za-z])')
STOP = set('the a an of to in is and or it that this as on for be by not with at its are was from so '
           'but which when only one no should any'.split())


def findings_of(path):
    """The finding lines of a review file, in order: what follows the header's blank line."""
    out = []
    with open(path, encoding='utf-8', errors='replace') as f:
        body = False
        for line in f:
            line = line.rstrip('\n')
            if not body:
                body = line == ''
                continue
            m = FINDING.match(line)
            if m:
                out.append((m.group(1), int(m.group(2)), m.group(3)))
    return out


def words(claim):
    """The words a claim is compared by: its own, before the fix it asks for, without its severity
    and without any mark the review runner put on it, which says how the runner read the finding and
    is the same words on findings about different things (claude-config#1357)."""
    claim = claim.split(' [review harness:')[0]
    claim = re.sub(r'\[severity:[^\]]*\]', '', claim).split('Should be:')[0]
    return {w for w in re.findall(r'[a-z0-9_]+', claim.lower()) if len(w) > 2 and w not in STOP}


def similarity(a, b):
    a, b = words(a), words(b)
    return len(a & b) / max(1, len(a | b))


def git(repo, *args):
    return subprocess.run(['git', '-C', repo, *args], capture_output=True, text=True)


_carried = {}


def carried_line(repo, earlier, head, path, line):
    """Where an earlier head's cited line is at this head, or None when the lines around it changed
    (or the file is not at both heads). The same hunk rule as line_since in pr-review.sh."""
    key = (earlier, path)
    if key not in _carried:
        hunks = None
        if all(git(repo, 'cat-file', '-e', f'{sha}:{path}').returncode == 0 for sha in (earlier, head)):
            d = git(repo, 'diff', '--no-color', '--no-renames', '-U0', earlier, head, '--', f':(literal){path}')
            if d.returncode != 0:
                raise RuntimeError(f'git diff {earlier[:7]} {head[:7]} -- {path} failed: {d.stderr.strip()}')
            hunks = []
            for h in re.finditer(r'^@@ -(\d+)(?:,(\d+))? \+\d+(?:,(\d+))? @@', d.stdout, re.M):
                s, c = int(h.group(1)), int(h.group(2) if h.group(2) is not None else 1)
                c2 = int(h.group(3) if h.group(3) is not None else 1)
                hunks.append((s, s + 1 if c == 0 else s + c - 1, c2 - c))
        _carried[key] = hunks
    hunks = _carried[key]
    if hunks is None:
        return None
    lo, hi = max(1, line - WINDOW), line + WINDOW
    shift = 0
    for s, e, net in hunks:
        if s <= hi and e >= lo:
            return None
        if e < lo:
            shift += net
    return line + shift


def epoch(at):
    try:
        return datetime.datetime.strptime(at, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()
    except (TypeError, ValueError):
        return None


def answer_for(comments, path, line, started):
    name = re.escape(os.path.basename(path))
    cite = re.compile(r'(?<![A-Za-z0-9_.-])' + name + ':' + str(line) + r'(?![0-9])')
    for c in comments:
        t = epoch(c.get('at'))
        if t is not None and t >= started and cite.search(c.get('body') or ''):
            return c
    return None


_resolved = {}


def resolve(repo, token):
    """The commit a hex prefix names in this checkout, or None. Only an object name counts: a branch
    or tag that happens to be spelled in hex resolves to a commit NOT starting with it, and is refused."""
    if token not in _resolved:
        r = git(repo, 'rev-parse', '--verify', '--quiet', f'{token}^{{commit}}')
        full = r.stdout.strip() if r.returncode == 0 else ''
        _resolved[token] = full if full.startswith(token) else None
    return _resolved[token]


def quotes_of(repo, comments):
    """Every finding an answer quotes: (path, line, claim, the head named above it, the comment)."""
    out = []
    for c in comments:
        head = None
        for text in (c.get('body') or '').split('\n'):
            m = QUOTE.match(text)
            if m:
                if head:
                    out.append((m.group(1), int(m.group(2)), m.group(3), head, c))
                continue
            for token in HEAD_TOKEN.findall(text):
                full = resolve(repo, token)
                if full:
                    head = full
    return out


def same_claim(claim, quoted):
    """The similarity rule, with a quote the refusal cut compared against this claim cut alike."""
    if quoted.endswith('...'):
        quoted = quoted[:-3]
        claim = claim[:len(quoted)]
    return similarity(claim, quoted) >= MIN_SIMILARITY


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--repo', required=True)
    p.add_argument('--head', required=True)
    p.add_argument('--review', required=True)
    p.add_argument('--earlier', required=True)
    p.add_argument('--comments')
    a = p.parse_args()
    earlier = []
    with open(a.earlier, encoding='utf-8') as f:
        for row in f:
            parts = row.rstrip('\n').split('\t')
            if len(parts) == 3 and parts[0] and parts[1].isdigit():
                earlier.append((parts[0], int(parts[1]), findings_of(parts[2])))
    comments = None
    if a.comments:
        with open(a.comments, encoding='utf-8') as f:
            comments = json.load(f)
    quotes = quotes_of(a.repo, comments) if comments else []
    candidates = 0
    for n, (path, line, claim) in enumerate(findings_of(a.review), 1):
        found = None
        for sha, started, old in earlier:
            for opath, oline, oclaim in old:
                if opath != path or similarity(claim, oclaim) < MIN_SIMILARITY:
                    continue
                at = carried_line(a.repo, sha, a.head, path, oline)
                if at is None or abs(at - line) > WINDOW:
                    continue
                if comments is None:
                    found = True
                    break
                c = answer_for(comments, path, oline, started)
                if c:
                    found = (sha, c, 'review')
                    break
            if found:
                break
        if not found:
            for qpath, qline, qclaim, qhead, c in quotes:
                if qpath != path or not same_claim(claim, qclaim):
                    continue
                at = carried_line(a.repo, qhead, a.head, path, qline)
                if at is not None and abs(at - line) <= WINDOW:
                    found = (qhead, c, 'quote')
                    break
        if not found:
            continue
        candidates += 1
        if comments is not None:
            sha, c, how = found
            print(f"{n}\t{sha}\t{c.get('author') or 'someone'}\t{c.get('at') or 'an unknown time'}\t{c.get('on') or '-'}\t{how}")
    if comments is None:
        print(candidates)


if __name__ == '__main__':
    try:
        main()
    except Exception as e:  # the caller says this and takes every finding as new
        print(f'review-answered.py: {e}', file=sys.stderr)
        sys.exit(1)
