#!/usr/bin/env python3
"""The end of turn review's record that it was handed to the session, and that Dan answered it.

Usage:
  review-record.py handed   --transcript <path> [--label <text>]
  review-record.py answered [--transcript <path>]
  review-record.py state    --transcript <path>

Why this exists (claude-config#3843). The Goal accomplished box could show before the end of turn
review's picker, where more work gets chosen. Dan, 2026-11-27, on the issue: hold the box "until
the review is answered", and, of how the box is to know, "The review says so itself". So the review
records that it was handed over, its last step records that he answered it (or that it asked him
nothing), and the goal box mod asks `state`. This file is the one owner of that record: the hooks
and the mod run it and never read or write its files themselves, so the writer and the reader
cannot come to keep it differently (L70).

WHO CALLS WHAT.
  handed    lib/review-reason.py, the one place both review hooks build their payload, when the
            instruction it points at is an end of turn review's.
  answered  the session, as the last step of the review (review/issue-review.md step 6,
            review/session-reflection.md EITHER WAY). With no --transcript it finds the session's
            transcript by CLAUDE_CODE_SESSION_ID, which a Bash call carries, under
            CLAUDE_TRANSCRIPT_ROOT (default ~/.claude/projects).
  state     the goal box mod, before it shows a box. One JSON line on stdout:
            {"state": "none" | "handed" | "answered", "turn": ..., "handed_at": ..., "label": ...}.

WHERE. Two files beside the session's transcript, as the kill switch (`.skip-stop-hooks`) is:
  <transcript>.review-handed.json     {"v": 1, "turn": <key or null>, "id": <fresh>, "at": <epoch s>, "label": ...}
  <transcript>.review-answered.json   {"v": 1, "turn": <key>, "handed": <the id it answers>, "at": <epoch s>}
Beside the transcript so that a suite running the real hooks on a throwaway transcript writes into
its own throwaway folder, by construction (L719), and so the key is the transcript both sides were
already handed. Two files so that no command ever reads a record, changes it and writes it back:
a hand over writes a fresh id, an answer names the id it answers, and a later hand over has a new
id that no earlier answer names. Every write is a whole file written under another name and moved
into place, so two writers at once leave one whole record and a reader never sees half of one.

THE TURN. A record belongs to one turn, and the next prompt of any origin ends it: a review handed
over in an earlier turn and never answered (Dan closed the picker, the session was compacted) reads
as none, and so does an answer left from one. The turn's key is the `promptId` of the transcript's
last user line. Measured on a real session's transcript on 2026-11-27: 2481 of 2484 user lines
carried one, it changed at each of 177 prompts (Dan's own, a mod's, a subagent's hand back), and a
Stop hook's feedback line and every tool result carried the id of the turn they belong to.

FAILING. `state` exits 3 with one line on stderr when the record or the transcript cannot be read,
or when a hand over is on file and the transcript names no prompt to tell its turn by: never "none"
and never "answered" (L10, L50). `handed` and `answered` exit 2 with one line on stderr when they
could not write or could not find what to write for.

Record files whose transcript has gone are removed at the next hand over in the same folder.

Seam: CLAUDE_REVIEW_RECORD_MIDWRITE names a command run between the write and the move, for the
suite (test-review-record.sh).
"""
import sys

# First, before anything is loaded by path below: this file loads turn-worked.py from the hooks
# folder, and Python would otherwise leave a compiled copy beside it (test-lib-bytecode-importers.sh).
sys.dont_write_bytecode = True

import argparse
import glob
import importlib.util
import json
import os
import re
import subprocess
import time
import uuid

HANDED_SUFFIX = ".review-handed.json"
ANSWERED_SUFFIX = ".review-answered.json"
# What a session id looks like; anything else never goes into a path.
SESSION_ID = re.compile(r"^[A-Za-z0-9-]+$")
# A temp file a killed writer left is removed once it is this old.
TEMP_MAX_AGE = 3600


class Unreadable(Exception):
    """The record, or the transcript it is keyed by, could not be read."""


def _lines_from_end():
    """turn-worked.py's reader of a transcript from its end, loaded from that file: the review hooks
    read a turn with it, and a second copy here would drift from it (L370)."""
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "turn-worked.py")
    spec = importlib.util.spec_from_file_location("turn_worked", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.lines_from_end


def turn_of(transcript):
    """The promptId of the transcript's last user line, or None when no user line carries one."""
    try:
        reader = _lines_from_end()
        with open(transcript, "rb") as f:
            for raw in reader(f, [0]):
                try:
                    obj = json.loads(raw.decode("utf-8", "replace"))
                except Exception:
                    continue
                if not isinstance(obj, dict) or obj.get("type") != "user" or obj.get("isSidechain") is True:
                    continue
                pid = obj.get("promptId")
                if isinstance(pid, str) and pid:
                    return pid
    except Exception as exc:
        raise Unreadable("the transcript at %s could not be read (%s)" % (transcript, exc))
    return None


def read_record(path):
    """A record file as a dict, None when it is not there; anything else is Unreadable."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        return None
    except Exception as exc:
        raise Unreadable("%s could not be read (%s)" % (path, exc))
    try:
        obj = json.loads(text)
    except Exception as exc:
        raise Unreadable("%s does not hold a record (%s)" % (path, exc))
    if not isinstance(obj, dict):
        raise Unreadable("%s does not hold a record (it holds %s)" % (path, type(obj).__name__))
    return obj


def write_record(path, obj):
    """The whole record under another name, then moved into place."""
    temp = "%s.tmp.%d.%s" % (path, os.getpid(), uuid.uuid4().hex[:8])
    try:
        with open(temp, "w", encoding="utf-8") as f:
            f.write(json.dumps(obj) + "\n")
            f.flush()
            os.fsync(f.fileno())
        seam = os.environ.get("CLAUDE_REVIEW_RECORD_MIDWRITE")
        if seam:
            subprocess.run([seam, path], check=False)
        os.replace(temp, path)
    except Exception:
        try:
            os.remove(temp)
        except OSError:
            pass
        raise


def sweep(folder):
    """Removes record files whose transcript has gone, and temp files a killed writer left."""
    try:
        names = os.listdir(folder)
    except OSError:
        return
    now = time.time()
    for name in names:
        path = os.path.join(folder, name)
        try:
            for suffix in (HANDED_SUFFIX, ANSWERED_SUFFIX):
                if name.endswith(".jsonl" + suffix) and not os.path.exists(path[: -len(suffix)]):
                    os.remove(path)
                elif (".jsonl" + suffix + ".tmp.") in name and now - os.path.getmtime(path) > TEMP_MAX_AGE:
                    os.remove(path)
        except OSError as exc:
            print("review-record: a leftover record file could not be removed (%s)" % exc, file=sys.stderr)


def handed_now(transcript):
    """(the turn's key, the hand over on file for this turn or None). Raises Unreadable."""
    turn = turn_of(transcript)
    handed = read_record(transcript + HANDED_SUFFIX)
    if handed is None:
        return turn, None
    hid, at = handed.get("id"), handed.get("at")
    if not isinstance(hid, str) or not hid or isinstance(at, bool) or not isinstance(at, (int, float)):
        raise Unreadable("%s does not hold a hand over (no id or no time)" % (transcript + HANDED_SUFFIX))
    if turn is None:
        raise Unreadable(
            "a review was handed over, but the transcript at %s names no prompt id on its user lines, "
            "so which turn the hand over belongs to cannot be told" % transcript
        )
    if handed.get("turn") != turn:
        return turn, None
    return turn, handed


def record_handed(transcript, label=""):
    """Records that a review was handed to the session whose transcript this is. Returns the turn's
    key, None when the transcript names no prompt (the hand over is then on file with no turn, and
    `state` says it cannot be read). Raises, naming the file and why, when it could not be written.
    lib/review-reason.py calls this in its own process; the `handed` command is the same call."""
    if not transcript:
        raise ValueError("no transcript was named, so there is no session to record the hand over for")
    path = transcript + HANDED_SUFFIX
    try:
        turn = turn_of(transcript)
        write_record(path, {"v": 1, "turn": turn, "id": uuid.uuid4().hex, "at": time.time(), "label": label or ""})
    except Exception as exc:
        raise RuntimeError("the hand over could not be written to %s (%s)" % (path, exc))
    sweep(os.path.dirname(os.path.abspath(transcript)))
    return turn


def cmd_handed(args):
    try:
        turn = record_handed(args.transcript, args.label)
    except Exception as exc:
        print("review-record: %s" % exc, file=sys.stderr)
        return 2
    if turn is None:
        print("review-record: the transcript names no prompt id, so the hand over is on file with no turn", file=sys.stderr)
    return 0


def transcripts_of_session():
    """The transcripts Claude Code keeps under this session's id, or (None, why)."""
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID") or ""
    if not sid:
        return None, "no --transcript was given and CLAUDE_CODE_SESSION_ID is not set, so which session's review was answered is not known"
    if not SESSION_ID.match(sid):
        return None, "CLAUDE_CODE_SESSION_ID is not a session id (%r)" % sid
    root = os.environ.get("CLAUDE_TRANSCRIPT_ROOT") or os.path.expanduser("~/.claude/projects")
    found = sorted(glob.glob(os.path.join(glob.escape(root), "*", sid + ".jsonl")))
    if not found:
        return None, "no transcript for session %s was found under %s" % (sid, root)
    return found, ""


def cmd_answered(args):
    if args.transcript:
        found = [args.transcript]
    else:
        found, why = transcripts_of_session()
        if found is None:
            print("review-record: the answer could not be recorded: %s." % why, file=sys.stderr)
            return 2
    marked = 0
    failed = 0
    for transcript in found:
        try:
            turn, handed = handed_now(transcript)
            if handed is None:
                continue
            write_record(transcript + ANSWERED_SUFFIX, {"v": 1, "turn": turn, "handed": handed["id"], "at": time.time()})
            marked += 1
        except Exception as exc:
            failed += 1
            print("review-record: the answer could not be recorded beside %s (%s)" % (transcript, exc), file=sys.stderr)
    if failed:
        return 2
    if marked:
        print("Recorded: the end of turn review handed over this turn is answered. The Goal accomplished box no longer waits for it.")
    else:
        print("Nothing to mark: no end of turn review is on record as handed over in this turn.")
    return 0


def cmd_state(args):
    if not args.transcript:
        print("review-record: state needs --transcript", file=sys.stderr)
        return 3
    try:
        turn, handed = handed_now(args.transcript)
        if handed is None:
            print(json.dumps({"state": "none", "turn": turn}))
            return 0
        answered = read_record(args.transcript + ANSWERED_SUFFIX)
        if answered is not None and not isinstance(answered.get("handed"), str):
            raise Unreadable("%s does not hold an answer (it names no hand over)" % (args.transcript + ANSWERED_SUFFIX))
        is_answered = answered is not None and answered.get("handed") == handed["id"]
        print(json.dumps({"state": "answered" if is_answered else "handed", "turn": turn, "handed_at": handed["at"], "label": handed.get("label") if isinstance(handed.get("label"), str) else ""}))
        return 0
    except Unreadable as exc:
        print("review-record: %s" % exc, file=sys.stderr)
        return 3
    except Exception as exc:
        print("review-record: the review's record could not be read (%s)" % exc, file=sys.stderr)
        return 3


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("command", choices=["handed", "answered", "state"])
    ap.add_argument("--transcript", default="")
    ap.add_argument("--label", default="")
    args = ap.parse_args()
    return {"handed": cmd_handed, "answered": cmd_answered, "state": cmd_state}[args.command](args)


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main())
