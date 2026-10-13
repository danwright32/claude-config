#!/usr/bin/env python3
"""The tracker skill's local helpers, run through tracker.sh, never on their own.

  tracker_lib.py new-token      a fresh token, written straight into config.local.json
  tracker_lib.py sheet-id       the id of the one sheet SKILL.md names (claude-config#1080)

Every write of a *.local.json file goes through write_local_json: the half written copy is
itself named *.local.json, so the skill's .gitignore and claude-sync's mirror both leave it out,
it is readable by its owner only, and it is renamed into place whole. A file that exists but
cannot be read is never overwritten: it may hold the only copy of the web app link or the token.
"""
import json
import os
import re
import secrets
import string
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "config.local.json")
EXAMPLE = os.path.join(HERE, "config.example.json")
SKILL_MD = os.path.join(HERE, "SKILL.md")


class Refusal(Exception):
    """A refusal, said in one sentence on stderr, exit 1, nothing written."""


def read_object(path, missing_ok=False):
    """The JSON object in path; None when it is missing and that is allowed. Anything else that
    cannot be read as an object is a refusal, never an empty default (L5)."""
    if not os.path.exists(path):
        if missing_ok:
            return None
        raise Refusal("%s is missing" % path)
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:  # any unreadable file is refused by name, never read as empty
        raise Refusal("%s could not be read (%s). Fix or remove it, then try again; nothing was written" % (path, type(e).__name__))
    if not isinstance(data, dict):
        raise Refusal("%s is not a JSON object. Fix or remove it, then try again; nothing was written" % path)
    return data


def write_local_json(path, data):
    """Writes data to path (a *.local.json file) whole, or not at all."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".writing.", suffix=".local.json")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    if os.environ.get("TRACKER_TEST_STOP_BEFORE_RENAME") == "1":
        os._exit(9)  # test seam: stands in for a run killed between the write and the rename
    os.replace(tmp, path)


def new_token(args):
    if args:
        raise Refusal("new-token takes no arguments")
    src = CONFIG if os.path.exists(CONFIG) else EXAMPLE
    try:
        data = read_object(src)
    except Refusal as r:
        raise Refusal("Refusing to write a token: %s" % r)
    alphabet = string.ascii_letters + string.digits
    data["token"] = "".join(secrets.choice(alphabet) for _ in range(40))
    write_local_json(CONFIG, data)
    print("Wrote a new token to %s (not shown here). Copy it from that file into the TOKEN line of "
          "the Apps Script, then deploy a new version." % CONFIG)


SHEET_LINK = re.compile(r"docs\.google\.com/spreadsheets/d/([A-Za-z0-9_-]+)")


def sheet_id_of(skill_md=SKILL_MD):
    """The id in SKILL.md's sheet link, the one declared home of which sheet the tracker writes.
    A SKILL.md naming no sheet, or two different ones, is a refusal, never a guess."""
    try:
        with open(skill_md, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        raise Refusal("%s could not be read (%s), so which sheet the web app must answer for is unknown. Nothing was sent" % (skill_md, type(e).__name__))
    ids = sorted(set(SHEET_LINK.findall(text)))
    if not ids:
        raise Refusal("SKILL.md names no sheet (it has no docs.google.com/spreadsheets/d/ link), so which sheet the web app must answer for is unknown. Nothing was sent")
    if len(ids) > 1:
        raise Refusal("SKILL.md names more than one sheet (%s), so which one the web app must answer for is unknown. Leave one sheet link in it. Nothing was sent" % ", ".join(ids))
    return ids[0]


def sheet_id(args):
    if args:
        raise Refusal("sheet-id takes no arguments")
    print(sheet_id_of())


COMMANDS = {
    "new-token": new_token,
    "sheet-id": sheet_id,
}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        sys.stderr.write("tracker_lib.py: unknown command %r; it is run through tracker.sh\n" % (argv[0] if argv else ""))
        return 2
    try:
        COMMANDS[argv[0]](argv[1:])
    except Refusal as r:
        sys.stderr.write("tracker.sh: %s.\n" % r)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
