#!/usr/bin/env python3
"""When each lesson can act, which decides whether the PR lessons review can stand in for it
(claude-config#563).

    python3 tools/tag-lessons.py [--index-dir payload] [--batch 120] [--model sonnet]

Reads every `- Lnnn. ...` line of the LESSONS-INDEX files and asks a reader to tag each one:
  diff     the mistake shows in a branch's diff, so the PR lessons review can catch it;
  design   it acts while planning, before there is code for a review to read;
  operate  it acts while diagnosing, measuring, running commands or making claims in conversation.
The plan's rule: anything no PR review can see (design, operate) stays in the core whatever its rank.

The reader is `claude -p` with hooks off (--settings disableAllHooks; a headless claude otherwise runs
Dan's global hooks, and on 2026-09-24 the end of turn review replaced a reviewer's answer). A lesson
missing from an answer is asked again once in a batch of its own; still missing, two different
tags, or a tag outside the three is a REFUSAL naming the lesson, never a default, because a default
here decides whether a lesson loads (L517, L113, L340).

Output: one `Lnnn<TAB>tag` line per lesson, then END; exit 1 with UNTAGGED, BADTAG or CONFLICT lines.
"""
import argparse
import glob
import os
import re
import subprocess
import sys

LINE = re.compile(r"^- L([0-9]+)\. (.+)$")
ANSWER = re.compile(r"^L([0-9]+)\t(\S+)\s*$")
TAGS = ("diff", "design", "operate")

PROMPT = """You are sorting recorded lessons from past software mistakes by WHEN each one can act.

For each lesson line below, answer with exactly one tag:
- diff: the mistake it describes would be VISIBLE in a code diff, so a reviewer reading a branch's changes could catch it (for example a guard that fails open, a swallowed error, a missing test for a failure path, an unpinned value).
- design: it acts while PLANNING or deciding, before code exists, and a reader of the eventual diff could not tell it was ignored (for example choosing a threshold without measuring, stating data volume first, deciding who a feature is for).
- operate: it acts while diagnosing, measuring, running commands, reading output or making claims in conversation, where there is no diff at all (for example judging a command by its exit code, reproducing a bug before fixing it).
When a lesson plainly fits two, pick the one where it most often decides something.

OUTPUT FORMAT, follow it exactly: one line per lesson, the lesson number, a TAB, the tag, and nothing else at all. For example:
L41\tdiff
Answer every lesson below, once each.

LESSONS:
"""


def lesson_lines(index_dir):
    out = {}
    for path in sorted(glob.glob(os.path.join(index_dir, "LESSONS-INDEX-*.md"))):
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = LINE.match(line.rstrip("\n"))
                if m:
                    out[int(m.group(1))] = m.group(2)
    return out


NOTES = []


def ask(model, batch, timeout):
    """The reader's answer, or "" when it could not give one. A reader past its deadline or one that
    cannot start answers NOTHING, which the caller already turns into an UNTAGGED refusal, rather than
    ending the tool in a traceback (found by the PR lessons review of #575)."""
    body = "\n".join(f"L{n}. {text}" for n, text in batch)
    cmd = ["env", "-u", "CLAUDECODE", "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1", "claude", "-p",
           PROMPT + body, "--model", model, "--settings", '{"disableAllHooks":true}']
    try:
        done = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        NOTES.append(f"NOTE the reader timed out after {timeout}s on a batch of {len(batch)} lessons")
        return ""
    except OSError as e:
        NOTES.append(f"NOTE the reader could not start: {e}")
        return ""
    return done.stdout


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--index-dir", default="payload")
    ap.add_argument("--batch", type=int, default=120)
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--timeout", type=int, default=600)
    a = ap.parse_args(argv)

    lessons = lesson_lines(a.index_dir)
    if not lessons:
        print(f"NO LESSONS: no `- Lnnn.` line in {a.index_dir}/LESSONS-INDEX-*.md")
        return 1
    tags, problems = {}, []
    items = sorted(lessons.items())

    def absorb(text, asked):
        for line in text.splitlines():
            m = ANSWER.match(line.strip("\r"))
            if not m:
                continue
            n, tag = int(m.group(1)), m.group(2).lower()
            if n not in asked:
                continue
            if tag not in TAGS:
                problems.append(f"BADTAG L{n} {tag}")
                continue
            if n in tags and tags[n] != tag:
                problems.append(f"CONFLICT L{n} {tags[n]} and {tag}")
                continue
            tags[n] = tag

    for i in range(0, len(items), a.batch):
        chunk = items[i:i + a.batch]
        absorb(ask(a.model, chunk, a.timeout), {n for n, _ in chunk})
    missing = [(n, t) for n, t in items if n not in tags]
    if missing:
        absorb(ask(a.model, missing, a.timeout), {n for n, _ in missing})
    for n, _ in items:
        if n not in tags:
            problems.append(f"UNTAGGED L{n}")

    for n, _ in items:
        if n in tags:
            print(f"L{n}\t{tags[n]}")
    for note in NOTES:
        print(note)
    if problems:
        for p in problems:
            print(p)
        return 1
    print(f"END {len(tags)} lessons tagged")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
