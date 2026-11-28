#!/usr/bin/env python3
"""decisions.py: what Dan decided about each kind of Slack draft edit, kept on this Mac (claude-config#3554).

    python3 decisions.py status
    python3 decisions.py author <Slack member id>
    python3 decisions.py record "<kind>" accepted --where no-ai-tells|global-claude-md|project [--project <folder name>]
    python3 decisions.py record "<kind>" not-now
    python3 decisions.py record "<kind>" never
    python3 decisions.py forget "<kind>"
    python3 decisions.py reviewed

The draft-edit-review skill offers each recurring kind of edit to Dan as a writing rule. This keeps
his answer, so a rule he accepted or said never to offer again is not put to him the next week:
hooks/lib/draft-edit-diff.py reads decisions.json itself and leaves those kinds out, and `status`
prints the same as --skip arguments for a run made by hand. A kind he
answered "not now" is recorded and offered again. `forget` takes an answer back, so a wrong one is
never permanent (L1008). `reviewed` records that a review finished, which is what the weekly notice
(hooks/draft-edit-review-notice.sh) reads to know nothing new is waiting.

WHERE, AND WHY THERE. ~/.claude/state/draft-edit-review/ on each Mac, which the config sync does
not carry. Per Mac on purpose: the config repository is public, and this holds a Slack member id
and where a rule went, which can name a private project; and the counts an offer rests on come
from one Mac's own session records. What that costs: "never" said on one Mac is not known to the
other, so the other can offer that kind once more.

IT HOLDS NO MESSAGE TEXT, and takes none: a kind is one of KINDS, a decision one of three words,
where is one of the three labels in PLACES, and a project is a folder's name checked for its
length and characters. Nothing typed freely is kept or printed back. It never reads a session record, and must not start to: it writes
files, and the Slack drafts gate refuses a program that can write and reads those. Reading them is
draft-edit-diff.py's job, which only prints.

State that cannot be read is refused by name, exit 3, and never read as nothing decided: that would
offer again what Dan declined, and the next save would write over what was there (L98).

Exit codes: 0 done; 2 a wrong argument; 3 the state could not be read or written.
"""
import argparse
import datetime
import json
import os
import re
import sys

sys.stdout.reconfigure(errors="replace")
sys.stderr.reconfigure(errors="replace")

# The kinds a rule can be offered for: OFFERED in hooks/lib/draft-edit-diff.py, and the skill's suite
# fails when the two differ.
KINDS = ("figures cut", "length cut", "the ask reworded", "the opening changed")
# Decisions that keep a kind from being offered again. hooks/lib/draft-edit-diff.py reads
# decisions.json itself and holds the same pair as DECIDED_FOR_GOOD; the suite fails when they differ.
SKIPPED = ("accepted", "never")
# Where an accepted rule was written: one of these labels and nothing typed, so no message text, name
# or channel can be put here and printed back by status. The words are what status prints.
PLACES = {"no-ai-tells": "the no-ai-tells skill",
          "global-claude-md": "the Slack section of the global CLAUDE.md",
          "project": "the project's own file"}
PROJECT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,59}\Z")  # a folder's name, never a path or a sentence
MEMBER_ID = re.compile(r"[A-Z0-9]{6,20}\Z")
LATEST = 10 ** 11  # seconds since 1970 past any time a calendar here can show: a stored time at or over it is not one


class Unreadable(Exception):
    pass


def seam(name):
    """A setting the suites move (the folder, the clock), read only under HOOK_TESTS_RUNNING=1, as the
    notice hook reads the same two: nothing in a real session's environment moves either."""
    return os.environ.get(name, "") if os.environ.get("HOOK_TESTS_RUNNING") == "1" else ""


def state_dir():
    home = os.environ.get("CLAUDE_HOME") or os.path.join(os.path.expanduser("~"), ".claude")
    return seam("DRAFT_EDIT_REVIEW_STATE_DIR") or os.path.join(home, "state", "draft-edit-review")


def now():
    at = seam("DRAFT_EDIT_REVIEW_NOW")
    return int(at) if at.isdigit() else int(datetime.datetime.now().timestamp())


def day(seconds):
    return datetime.datetime.fromtimestamp(seconds).strftime("%Y-%m-%d")


def read_text(name):
    """A state file's text, None when it is not there. Raises Unreadable when it is and cannot be read."""
    path = os.path.join(state_dir(), name)
    if not os.path.lexists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError as e:
        raise Unreadable("%s could not be read (%s)" % (path, e.strerror or e))


def load():
    """The decisions, as {kind: {"decision", "at", "where"}}."""
    text = read_text("decisions.json")
    if text is None:
        return {}
    path = os.path.join(state_dir(), "decisions.json")
    try:
        data = json.loads(text)
    except ValueError:
        raise Unreadable("%s could not be read (it is not JSON)" % path)
    found = data.get("decisions") if isinstance(data, dict) else None
    if not isinstance(found, dict):
        raise Unreadable("%s could not be read (it holds no decisions object)" % path)
    for kind, entry in found.items():
        if kind not in KINDS or not isinstance(entry, dict) or entry.get("decision") not in ("accepted", "not-now", "never") \
                or not isinstance(entry.get("at"), int) or isinstance(entry.get("at"), bool) \
                or not 0 <= entry["at"] < LATEST or not placed(entry):
            raise Unreadable("%s could not be read (its entry for %r is not one this wrote)" % (path, str(kind)[:40]))
    return found


def placed(entry):
    """Whether an entry's place is one this writes: a label of PLACES for an accepted rule, with a
    project's folder name beside "project" at most, and no place at all for any other answer."""
    where, project = entry.get("where"), entry.get("project")
    if entry.get("decision") != "accepted":
        return where is None and project is None
    if where not in PLACES:
        return False
    if project is None:
        return True
    return where == "project" and isinstance(project, str) and bool(PROJECT_NAME.match(project))


def write_text(name, text):
    """The whole file replaced in one move. Raises OSError when it cannot be."""
    folder = state_dir()
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, name)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8", errors="replace") as f:
            f.write(text)
        os.replace(tmp, path)
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def save(decisions):
    write_text("decisions.json", json.dumps({"version": 1, "decisions": decisions}, indent=2, sort_keys=True) + "\n")


def status():
    decisions = load()
    author = (read_text("author") or "").strip()
    reviewed = (read_text("last-review") or "").strip()
    if author and not MEMBER_ID.match(author):
        raise Unreadable("%s could not be read (it does not hold a Slack member id)" % os.path.join(state_dir(), "author"))
    if reviewed and not (reviewed.isdigit() and len(reviewed) <= 12 and int(reviewed) < LATEST):
        raise Unreadable("%s could not be read (it does not hold a time)" % os.path.join(state_dir(), "last-review"))
    print("state folder: " + state_dir())
    print("author: " + (author or "not set"))
    print("last review: " + (day(int(reviewed)) if reviewed else "never"))
    if not decisions:
        print("decisions: none")
    else:
        print("decisions:")
    for kind in KINDS:
        entry = decisions.get(kind)
        if entry is None:
            continue
        when = day(entry["at"])
        if entry["decision"] == "accepted":
            named = " (%s)" % entry["project"] if entry.get("project") else ""
            print("  %s: accepted on %s, written to %s%s" % (kind, when, PLACES[entry["where"]], named))
        elif entry["decision"] == "never":
            print("  %s: never offer again, decided %s" % (kind, when))
        else:
            print("  %s: not now, decided %s (it is offered again at the next review)" % (kind, when))
    skip = ['--skip "%s"' % kind for kind in KINDS if decisions.get(kind, {}).get("decision") in SKIPPED]
    print("skip arguments: " + (" ".join(skip) if skip else "none"))


def main():
    parser = argparse.ArgumentParser(description="Keep what Dan decided about each kind of Slack draft edit.")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    sub.add_parser("reviewed")
    p = sub.add_parser("author")
    p.add_argument("member_id")
    p = sub.add_parser("record")
    p.add_argument("kind")
    p.add_argument("decision")
    p.add_argument("--where", default="")
    p.add_argument("--project", default="")
    p = sub.add_parser("forget")
    p.add_argument("kind")
    args = parser.parse_args()

    if args.command in ("record", "forget") and args.kind not in KINDS:
        print("decisions.py: the kind is one of: " + "; ".join(KINDS) + ". Got: " + args.kind[:60], file=sys.stderr)
        return 2
    if args.command == "record":
        if args.decision not in ("accepted", "not-now", "never"):
            print("decisions.py: the decision is accepted, not-now or never. Got: " + args.decision[:40], file=sys.stderr)
            return 2
        if args.decision == "accepted" and not args.where:
            print("decisions.py: a rule is accepted only once it is written somewhere, so name the place with "
                  "--where. Nothing was recorded.", file=sys.stderr)
            return 2
        if args.decision == "accepted" and args.where not in PLACES:
            print("decisions.py: --where is no-ai-tells, global-claude-md or project, never the rule, a path or "
                  "a message. Nothing was recorded.", file=sys.stderr)
            return 2
        if args.decision != "accepted" and (args.where or args.project):
            print("decisions.py: --where and --project go with accepted only. Nothing was recorded.", file=sys.stderr)
            return 2
        if args.project and (args.where != "project" or not PROJECT_NAME.match(args.project)):
            print("decisions.py: --project goes with --where project, and is the project's folder name: 1 to 60 "
                  "letters, digits, dots, dashes or underscores. Nothing was recorded.", file=sys.stderr)
            return 2
    if args.command == "author" and not MEMBER_ID.match(args.member_id):
        print("decisions.py: a Slack member id is 6 to 20 capital letters and digits. Nothing was recorded.",
              file=sys.stderr)
        return 2

    try:
        if args.command == "status":
            status()
            return 0
        if args.command == "author":
            write_text("author", args.member_id + "\n")
            print("author recorded")
            return 0
        if args.command == "reviewed":
            write_text("last-review", "%d\n" % now())
            print("review recorded as finished")
            return 0
        decisions = load()
        if args.command == "forget":
            if decisions.pop(args.kind, None) is None:
                print("nothing was recorded for %s" % args.kind)
                return 0
            save(decisions)
            print("forgotten: %s is offered again at the next review" % args.kind)
            return 0
        entry = {"decision": args.decision, "at": now()}
        if args.decision == "accepted":
            entry["where"] = args.where
            if args.project:
                entry["project"] = args.project
        decisions[args.kind] = entry
        save(decisions)
        print("recorded: %s, %s" % (args.kind, args.decision))
        return 0
    except Unreadable as e:
        print("decisions.py: %s. Nothing was changed, and nothing here is read as undecided." % e, file=sys.stderr)
        return 3
    except OSError as e:
        print("decisions.py: the state in %s could not be written (%s), so this was not recorded."
              % (state_dir(), e.strerror or e), file=sys.stderr)
        return 3


sys.exit(main())
