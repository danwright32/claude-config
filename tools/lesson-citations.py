#!/usr/bin/env python3
"""How often each lesson is cited in Claude's own PROSE on this Mac (claude-config#563).

    python3 tools/lesson-citations.py [--days 60] [--projects DIR] [--exclude-session ID]
                                      [--ledger PATH] [--sample L1,L2,L3]

The 2026-09-24 ranking behind the lessons core plan counted every lesson number Claude wrote, and
84 percent of this Mac's (lesson, session) pairs came from numbers written INTO artifacts: heredocs
5,296, gh bodies 3,223, commits 1,463, Write 1,238, against 1,283 from prose. L98 was in 176
sessions but in prose in 13. That ranking measured annotation habit, so this one reads only:

  - assistant records, and within them only `text` blocks. Tool inputs are where Write and Edit
    content, heredocs, commit messages and PR bodies live, and thinking is not what Dan reads;
  - outside fenced code blocks, and never a `#L123` line anchor;
  - never a sidechain record or a transcript under subagents/ (lesson auditors cite nearly
    everything), never a session whose project directory is claude-config (where lessons are the
    subject rather than the tool), never the session doing the recording (--exclude-session).

Plus the PR lessons review's own citations, from the ledger it keeps (--ledger, default
~/.claude/state/ai-review/citations.tsv), counted as the number of reviews citing each lesson.

Prints a header line (host, window, files read, unread, excluded by reason), then one line per
lesson, tab separated: lesson, prose sessions, prose mentions, reviews citing, then END. Prints
lesson numbers and counts only, never conversation text, except under --sample, which prints each
sentence that cited the named lessons so a person can judge the counter's precision (L147).
Exits 1 when no transcript could be read, since an empty table would read as nothing cited (L98).
"""
import argparse
import glob
import json
import os
import re
import socket
import sys
import time

LESSON = re.compile(r"(?<![A-Za-z0-9#/._-])L([1-9][0-9]{0,3})(?![0-9])")
FENCE = re.compile(r"```.*?(```|$)", re.S)
SENTENCE = re.compile(r"[^.;!?\n]+[.;!?]?")
# A sentence saying a lesson does NOT apply is a dismissal, not a use. Measured 2026-09-24: the push
# time lessons advisory names lessons by pattern and asks for a one line reply on each, and its own
# picks (L5, L7, L9, L290, L524) topped the prose ranking through those replies.
DISMISSAL = re.compile(r"(do(es)?n'?t|do(es)? not|not|never) apply|n/a\b|not applicable|irrelevant here", re.I)


def prose_blocks(rec):
    if rec.get("type") != "assistant" or rec.get("isSidechain"):
        return
    content = (rec.get("message") or {}).get("content")
    if isinstance(content, str):
        yield content
        return
    for block in content or []:
        if isinstance(block, dict) and block.get("type") == "text":
            yield block.get("text", "")


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=60)
    ap.add_argument("--projects", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--exclude-session", action="append", default=[])
    ap.add_argument("--ledger", default=os.path.expanduser("~/.claude/state/ai-review/citations.tsv"))
    ap.add_argument("--sample", default="")
    a = ap.parse_args(argv)

    cutoff = time.time() - a.days * 86400
    want_sample = {int(x.strip().lstrip("L")) for x in a.sample.split(",") if x.strip()}
    sessions, mentions, reviews = {}, {}, {}
    read = unread = 0
    excluded = {"subagent": 0, "claude-config": 0, "recording": 0}
    dismissed = 0
    samples = []

    for f in sorted(glob.glob(os.path.join(a.projects, "**", "*.jsonl"), recursive=True)):
        try:
            if os.path.getmtime(f) < cutoff:
                continue
        except OSError:
            unread += 1
            continue
        if "/subagents/" in f:
            excluded["subagent"] += 1
            continue
        if "claude-config" in os.path.basename(os.path.dirname(f)):
            excluded["claude-config"] += 1
            continue
        if os.path.splitext(os.path.basename(f))[0] in a.exclude_session:
            excluded["recording"] += 1
            continue
        seen = set()
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    try:
                        rec = json.loads(line)
                    except ValueError:
                        continue
                    for text in prose_blocks(rec):
                        text = FENCE.sub(" ", text)
                        kept = []
                        for sent in SENTENCE.findall(text):
                            if DISMISSAL.search(sent):
                                dismissed += len(LESSON.findall(sent))
                            else:
                                kept.append(sent)
                        text = " ".join(kept)
                        for m in LESSON.finditer(text):
                            n = int(m.group(1))
                            mentions[n] = mentions.get(n, 0) + 1
                            seen.add(n)
                            if n in want_sample:
                                start = max(0, text.rfind(".", 0, m.start()) + 1)
                                end = text.find(".", m.end())
                                samples.append((n, text[start:end + 1 if end >= 0 else None].strip()[:300]))
            read += 1
        except OSError:
            unread += 1
            continue
        for n in seen:
            sessions[n] = sessions.get(n, 0) + 1

    # Three states, never two: a ledger that exists but cannot be read must not print as present
    # beside zero review citations, which would read as reviews citing nothing (L11).
    ledger_state = "absent" if not os.path.exists(a.ledger) else "read"
    try:
        with open(a.ledger, encoding="utf-8") as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 6:
                    continue
                try:
                    if int(parts[0]) < cutoff:
                        continue
                except ValueError:
                    continue
                for tok in parts[5].split(","):
                    tok = tok.strip()
                    if tok.startswith("L") and tok[1:].isdigit():
                        n = int(tok[1:])
                        reviews[n] = reviews.get(n, 0) + 1
    except OSError:
        if ledger_state == "read":
            ledger_state = "unreadable"

    host = socket.gethostname().split(".")[0]
    ex = " ".join(f"{k}={v}" for k, v in excluded.items())
    print(f"HOST {host} DAYS {a.days} READ {read} UNREAD {unread} EXCLUDED {ex} LEDGER {ledger_state} DISMISSED {dismissed}")
    if read == 0:
        print("NOTHING READ: no transcript in the window could be read, so these counts measure nothing")
        return 1
    for n in sorted(set(sessions) | set(mentions) | set(reviews)):
        print(f"L{n}\t{sessions.get(n, 0)}\t{mentions.get(n, 0)}\t{reviews.get(n, 0)}")
    print(f"END {len(set(sessions) | set(reviews))} lessons")
    for n, s in samples:
        print(f"SAMPLE L{n}\t{s}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
