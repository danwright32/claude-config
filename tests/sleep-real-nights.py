#!/usr/bin/env python3
"""What this Mac's real nights of sleep mode have measured (claude-config#1662).

tests/test-sleep-real-engine.sh runs a night with the real engine but a headless session and a
scripted model, so six parts of sleep mode cannot happen in it. Each is measured only by a real
night, so this reads the durable record a real night leaves for each one (L239), read only: every
ended night's record in <state>/ended/*.json and its notes in <state>/notes/<generation>.jsonl.
The night in progress (current.json) is never read.

    python3 sleep-real-nights.py <sleep state dir> <now, ms> [<max age, days>]

Prints one line per part, in PARTS order: `measured<TAB><key><TAB><evidence>` when an ended night
no older than the max age (30 days by default) shows it, else `unmeasured<TAB><key><TAB><why>`,
saying the last night that showed it when one did. Exit 0 whenever it could read the folder, 2 when
it could not, saying why on stderr: an unreadable record is a failure, never a night that showed
nothing (L10).
"""
import json
import os
import re
import sys
from datetime import datetime, timezone

HOUR_MS = 60 * 60 * 1000
# Before bed questions are answered in the ten minutes before the record is placed (QUESTION_MS).
BEDTIME_MS = 15 * 60 * 1000

# Each part: its key, what it is, and why the headless suite cannot measure it.
PARTS = [
    ("enrolment", "a real interactive session's enrolment by /sleep",
     "a headless run is never interactive, so /sleep never enrols it (by design, #840)"),
    ("told-to-start", "an idle worker told to start by /sleep",
     "it needs a second live interactive session to send to (#1242)"),
    ("bedtime-questions", "the before bed questions",
     "they need a person at a prompt to answer them (#836)"),
    ("model-rules", "a real model following the overnight rules",
     "the suite's model is a scripted stand-in"),
    ("hour", "a full hour of work",
     "the suite's night lasts about a minute"),
    ("usage-limit", "a real usage limit",
     "the stand-in model never reports one"),
]


def fail(why):
    print(f"sleep-real-nights: {why}", file=sys.stderr)
    sys.exit(2)


def listing(folder, suffix):
    """The files in a folder ending in suffix. A folder that is not there holds none; one that is
    there but cannot be read raises, so it is never taken for an empty one (L10)."""
    try:
        names = os.listdir(folder)
    except FileNotFoundError:
        return []
    return sorted(os.path.join(folder, n) for n in names if n.endswith(suffix))


def notes_of(state, generation):
    path = os.path.join(state, "notes", re.sub(r"[^\w.-]", "_", generation) + ".jsonl")
    out = []
    try:
        f = open(path, encoding="utf-8")
    except FileNotFoundError:
        return []  # a night that wrote no notes; a notes file that cannot be read raises
    with f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                n = json.loads(line)
            except ValueError:
                continue  # a torn line is skipped, as the report skips it
            if isinstance(n, dict):
                out.append(n)
    return out


def answered_at(state):
    """When each before bed answer was recorded (answered/*.json), in ms."""
    out = []
    for path in listing(os.path.join(state, "answered"), ".json"):
        with open(path, encoding="utf-8") as f:
            try:
                at = json.load(f).get("at")
            except ValueError:
                continue
        if isinstance(at, (int, float)):
            out.append(at)
    return out


def evidence(record, notes, answers):
    """What this night shows of each part, by key: a sentence, or absent."""
    shown = {}
    starter = (record.get("startedBy") or {}).get("sessionId")
    workers = [w for w in record.get("workers") or [] if isinstance(w, str)]
    goals = record.get("goals") or {}
    since = record.get("since")
    if starter and starter in workers:
        shown["enrolment"] = f"the session that ran /sleep ({starter[:8]}) was enrolled as a worker"
    by = {}
    for n in notes:
        if isinstance(n.get("by"), str):
            by.setdefault(n["by"], []).append(n)
    for w in workers:
        if w != starter and w in goals and by.get(w):
            shown["told-to-start"] = f"worker {w[:8]}, another session with a goal, worked that night ({len(by[w])} notes)"
            break
    if isinstance(since, (int, float)):
        asked = [n for n in notes if n.get("kind") == "question" and "issue" in n and n.get("at") == since]
        answered = [a for a in answers if since - BEDTIME_MS <= a <= since]
        if asked or answered:
            shown["bedtime-questions"] = f"{len(asked)} left for the morning and {len(answered)} answered at bedtime"
    claims = [n for n in notes if n.get("kind") == "claim" and n.get("by") in workers]
    if claims:
        shown["model-rules"] = f"{len(claims)} issue{'s' if len(claims) != 1 else ''} claimed by a worker through the queue, as the rules tell it"
    for w, ns in by.items():
        beats = [n["at"] for n in ns if n.get("kind") == "heartbeat" and isinstance(n.get("at"), (int, float))]
        if w in workers and len(beats) > 1 and max(beats) - min(beats) >= HOUR_MS:
            shown["hour"] = f"worker {w[:8]} kept working for {round((max(beats) - min(beats)) / 60000)} minutes"
            break
    waits = [n for n in notes if n.get("kind") == "wait" and n.get("error")]
    if waits:
        shown["usage-limit"] = f"{len(waits)} wait{'s' if len(waits) != 1 else ''} on a usage limit"
    return shown


def main():
    if len(sys.argv) not in (3, 4):
        fail("usage: sleep-real-nights.py <sleep state dir> <now, ms> [<max age, days>]")
    state, now = sys.argv[1], int(sys.argv[2])
    max_age_ms = int(sys.argv[3] if len(sys.argv) == 4 else 30) * 24 * HOUR_MS
    try:
        paths = listing(os.path.join(state, "ended"), ".json")
        answers = answered_at(state)
        nights = []
        for path in paths:
            with open(path, encoding="utf-8") as f:
                record = json.load(f)
            if not isinstance(record, dict) or not isinstance(record.get("generation"), str):
                fail(f"{path} is not a sleep record")
            nights.append((record, evidence(record, notes_of(state, record["generation"]), answers), os.path.basename(path)))
    except (OSError, ValueError) as err:
        fail(f"a night could not be read: {err}")
    # Newest first, by when each night began.
    nights.sort(key=lambda n: n[0].get("since") or 0, reverse=True)
    for key, name, why in PARTS:
        last = next(((r, s[key], p) for r, s, p in nights if key in s), None)
        if last is None:
            told = "no real night on this Mac has shown it yet" if nights else "no real night has ended on this Mac yet"
            print(f"unmeasured\t{key}\t{name}: {why}, and {told}")
            continue
        record, said, on_disk = last
        night = record.get("night") or "an unnamed night"
        since = record.get("since") or 0
        if now - since > max_age_ms:
            print(f"unmeasured\t{key}\t{name}: {why}, and the last real night that showed it, {night}, is more than {max_age_ms // (24 * HOUR_MS)} days old")
            continue
        print(f"measured\t{key}\t{name}: the real night of {night} ({said}; ended/{on_disk})")


if __name__ == "__main__":
    main()
