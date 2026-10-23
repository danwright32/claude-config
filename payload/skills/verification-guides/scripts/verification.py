#!/usr/bin/env python3
"""The one reader of every verification file (claude-config#1528), shared with the merge check (#1529).

A project opts in to verification guides with its own `.claude/verification/areas.json`; this
repository holds no list of projects. Everything that READS one of the formats below lives here,
once, so the skill that writes them and the merge check that judges them cannot drift apart (L370,
L655). The merge check calls this file's CLI, or imports it, and never re-parses a format itself.

Formats, each versioned in its own `schema` field. A consumer accepts any record whose schema is
the major version it knows and ignores keys it does not, so an additive change never breaks it
(L255); a breaking change takes a new major version, which is refused by name.

  verification-areas/1    .claude/verification/areas.json, written by CREATE (see SKILL.md)
  guide (no version)      .claude/verification/guides/<area>.md, the fixed template
  verification-run/1      one fenced ```verification-run block per area in a PR comment
  verification-receipt/1  <home>/receipts/<id>/receipt.json, written only by run_session.py
                          (and drives.jsonl beside it, one line per drive call)
  verification-tally/1    <home>/merge-tally/<owner>/<name>.jsonl, the merge check's warn tally (#1529)

The merge check (#1529) is merge_check.py beside this file: it judges a pull request through these
readers and parses no format itself.

CLI (every refusal prints `verification: <kind>: <message>` on stderr, one line per problem):

  verification.py areas validate <areas.json> [--root <repo>]
  verification.py bucket <areas.json> [<path> ...]          paths on stdin when none are given
  verification.py guide check <guide.md>
  verification.py done-when                                 PR body on stdin
  verification.py record parse [--sha <40 hex>]             a comment body on stdin
  verification.py record render --pr-body <file>            a draft on stdin (see SKILL.md)
  verification.py receipt show <receipt id>
  verification.py tally due [--mark]                        repositories due the switch to block question
  verification.py nonce
  verification.py whoami <nonce>

Exit codes, one per class of cause:
  0 ok  2 usage  3 not found (areas-missing, record-none, receipt-missing, agent-not-found)
  4 malformed or refused  5 ambiguous  6 record-other-sha  7 bucket-unowned or bucket-ambiguous

Env: VERIFICATION_HOME (default ~/.claude-verification, outside ~/.claude on purpose: the sync
mirrors ~/.claude to a public repository, and receipts hold screenshots of private apps), and
VERIFICATION_TRANSCRIPTS (default ~/.claude/projects) for whoami.
"""

import json
import os
import re
import secrets
import socket
import sys
import time

AREAS_SCHEMA = "verification-areas/1"
RUN_SCHEMA = "verification-run/1"
RECEIPT_SCHEMA = "verification-receipt/1"
AREAS_PATH = ".claude/verification/areas.json"

GUIDE_SECTIONS = ("Roles", "Reach", "State setup", "Checks", "Known traps")
CHECKS_MIN, CHECKS_MAX = 3, 6
NOTE_MAX = 300

AREA_NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
RECEIPT_ID_RE = re.compile(r"^\d{8}T\d{6}Z-[0-9a-f]{7}-[0-9a-f]{6}$")
AGENT_ID_RE = re.compile(r"^[A-Za-z0-9_-]{2,64}$")
CHECK_ID_RE = re.compile(r"^C[1-9][0-9]?$")
DONE_ID_RE = re.compile(r"^D[1-9][0-9]?$")
SHOT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.(png|jpg|jpeg)$")
NONCE_RE = re.compile(r"^vg-[0-9a-f]{16}$")
LOCAL_URL = re.compile(r"^http://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]{1,5})?(/.*)?$")

COMMANDS_REQUIRED = ("serve", "ready", "stop", "drive")
COMMANDS_OPTIONAL = ("stamp",)
TIMEOUT_DEFAULTS = {"ready_s": 300, "ready_interval_s": 2, "max_run_s": 3600, "stop_s": 60}
MODES = ("warn", "block")
RESULTS = ("pass", "fail")
BLAMES = ("code", "guide")

EXIT_BY_KIND = {
    "usage": 2,
    "areas-missing": 3, "record-none": 3, "receipt-missing": 3, "agent-not-found": 3,
    "commit-missing": 3,
    "agent-ambiguous": 5, "run-busy": 5,
    "record-other-sha": 6,
    "bucket-unowned": 7, "bucket-ambiguous": 7,
    # run_session.py: the run itself failed
    "ready-timeout": 8, "serve-stopped": 8, "serve-survived": 8, "supervisor-failed": 8,
    "supervisor-hung": 8, "drive-failed": 8, "disk-full": 8, "start-error": 8, "start-cleanup-failed": 8,
}


class VerificationError(Exception):
    """One or more problems, each a (kind, message) pair. `code` is the exit code of the first."""

    def __init__(self, problems):
        if isinstance(problems, tuple):
            problems = [problems]
        self.problems = list(problems)
        super().__init__("; ".join("%s: %s" % p for p in self.problems))

    @property
    def code(self):
        return EXIT_BY_KIND.get(self.problems[0][0], 4)


def fail(kind, message):
    raise VerificationError((kind, message))


def one_line(s):
    return isinstance(s, str) and s.strip() != "" and "\n" not in s and "\r" not in s


def verification_home():
    return os.environ.get("VERIFICATION_HOME") or os.path.expanduser("~/.claude-verification")


def receipt_dir(receipt_id, home=None):
    if not isinstance(receipt_id, str) or not RECEIPT_ID_RE.match(receipt_id):
        fail("receipt-bad-id", "%r is not a receipt id (shape 20261022T230000Z-0123456-a1b2c3)" % receipt_id)
    return os.path.join(home or verification_home(), "receipts", receipt_id)


def machine_name():
    """This Mac's short host name, the same spelling the receipt and the merge check compare."""
    return socket.gethostname().split(".")[0]


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# ---------------------------------------------------------------------------------------------
# areas.json


def _glob_problem(glob):
    if not isinstance(glob, str) or glob.strip() == "":
        return "an empty pattern"
    if glob.startswith("/") or "\\" in glob:
        return "%r is not a repository relative POSIX path" % glob
    parts = glob.split("/")
    if any(p in ("", ".", "..") for p in parts):
        return "%r has an empty, . or .. segment" % glob
    if re.search(r"[\[\]{}]", glob):
        return "%r uses brackets or braces, which are not supported: list each pattern" % glob
    for p in parts:
        if "**" in p and p != "**":
            return "%r puts ** inside a segment; ** must be a whole segment" % glob
    return None


def glob_to_regex(glob):
    parts = glob.split("/")
    out = []
    for i, part in enumerate(parts):
        last = i == len(parts) - 1
        if part == "**":
            out.append(".*" if last else "(?:[^/]+/)*")
            continue
        seg = ""
        for ch in part:
            seg += "[^/]*" if ch == "*" else "[^/]" if ch == "?" else re.escape(ch)
        out.append(seg if last else seg + "/")
    return re.compile("^" + "".join(out) + "$")


def glob_matches(glob, path):
    return bool(glob_to_regex(glob).match(path))


def _int_field(problems, where, value, minimum):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value < minimum:
        problems.append(("areas-bad-timeout", "%s must be a number of seconds of at least %s, not %r"
                         % (where, minimum, value)))
        return False
    return True


def parse_areas(text, root=None):
    """Validate areas.json text. Every problem is reported at once, each with its own kind (L11).

    `root` is the checkout the file belongs to; when given, each area's guide must exist there.
    Returns the document with `timeouts` filled from the defaults.
    """
    try:
        doc = json.loads(text)
    except ValueError as e:
        fail("areas-not-json", "areas.json is not JSON: %s" % e)
    if not isinstance(doc, dict):
        fail("areas-not-object", "areas.json must be a JSON object, not %s" % type(doc).__name__)
    p = []
    schema = doc.get("schema")
    if schema is None:
        p.append(("areas-missing-key", "missing key: schema (want %r)" % AREAS_SCHEMA))
    elif schema != AREAS_SCHEMA:
        fail("areas-schema-unsupported", "schema %r is not %r, the version this reader knows"
             % (schema, AREAS_SCHEMA))

    for key, kind in (("mode", str), ("url", str), ("commands", dict), ("areas", list)):
        if key not in doc:
            p.append(("areas-missing-key", "missing key: %s" % key))
        elif not isinstance(doc[key], kind):
            p.append(("areas-wrong-type", "%s must be a %s" % (key, "list" if kind is list else
                                                               "object" if kind is dict else "string")))
    if isinstance(doc.get("mode"), str) and doc["mode"] not in MODES:
        p.append(("areas-bad-mode", "mode %r is not one of %s" % (doc["mode"], ", ".join(MODES))))
    if isinstance(doc.get("url"), str) and not LOCAL_URL.match(doc["url"]):
        p.append(("areas-url-not-local", "url %r is not http on this machine (127.0.0.1, localhost or [::1]):"
                  " a verification run never drives a deployment" % doc["url"]))

    cmds = doc.get("commands")
    if isinstance(cmds, dict):
        for name in COMMANDS_REQUIRED + COMMANDS_OPTIONAL:
            if name not in cmds:
                if name in COMMANDS_REQUIRED:
                    p.append(("areas-missing-key", "missing key: commands.%s" % name))
                continue
            if not isinstance(cmds[name], str):
                p.append(("areas-wrong-type", "commands.%s must be a string" % name))
            elif cmds[name].strip() == "":
                p.append(("areas-empty-command", "commands.%s is empty" % name))

    timeouts = dict(TIMEOUT_DEFAULTS)
    raw_t = doc.get("timeouts", {})
    if not isinstance(raw_t, dict):
        p.append(("areas-wrong-type", "timeouts must be an object"))
        raw_t = {}
    t_ok = True
    for key, value in raw_t.items():
        if key in TIMEOUT_DEFAULTS:
            minimum = 0.1 if key == "ready_interval_s" else 1
            t_ok = _int_field(p, "timeouts." + key, value, minimum) and t_ok
            timeouts[key] = value
    if t_ok and timeouts["max_run_s"] <= timeouts["ready_s"]:
        p.append(("areas-bad-timeout", "timeouts.max_run_s (%s) must be longer than timeouts.ready_s (%s)"
                  % (timeouts["max_run_s"], timeouts["ready_s"])))

    names = set()
    for i, area in enumerate(doc.get("areas") if isinstance(doc.get("areas"), list) else []):
        where = "areas[%d]" % i
        if not isinstance(area, dict):
            p.append(("areas-wrong-type", "%s must be an object" % where))
            continue
        name = area.get("name")
        if not isinstance(name, str) or not AREA_NAME.match(name):
            p.append(("areas-bad-area-name", "%s name %r must be lower case letters, digits and hyphens" % (where, name)))
        elif name in names:
            p.append(("areas-duplicate-area", "area %r is defined twice" % name))
        else:
            names.add(name)
        guide = area.get("guide")
        if not isinstance(guide, str) or guide.startswith("/") or ".." in guide.split("/") or not guide.endswith(".md"):
            p.append(("areas-bad-guide-path", "%s guide %r must be a repository relative .md path" % (where, guide)))
        elif root is not None and not os.path.isfile(os.path.join(root, guide)):
            p.append(("areas-guide-missing", "%s guide %s does not exist in %s" % (where, guide, root)))
        owns = area.get("owns")
        if not isinstance(owns, list) or not owns:
            p.append(("areas-no-owns", "%s owns no files: give it at least one pattern" % where))
        else:
            for g in owns:
                why = _glob_problem(g)
                if why:
                    p.append(("areas-bad-glob", "%s owns %s" % (where, why)))

    exempt = doc.get("exempt", [])
    if not isinstance(exempt, list):
        p.append(("areas-wrong-type", "exempt must be a list"))
        exempt = []
    for i, ex in enumerate(exempt):
        where = "exempt[%d]" % i
        if not isinstance(ex, dict):
            p.append(("areas-wrong-type", "%s must be an object" % where))
            continue
        why = _glob_problem(ex.get("glob"))
        if why:
            p.append(("areas-bad-glob", "%s %s" % (where, why)))
        if not one_line(ex.get("why")):
            p.append(("areas-exempt-no-why", "%s needs a one line why: an exemption with no reason has no reviewer" % where))

    if p:
        raise VerificationError(p)
    doc["timeouts"] = timeouts
    doc.setdefault("exempt", [])
    return doc


def load_areas(path, root=None):
    try:
        with open(path) as f:
            text = f.read()
    except FileNotFoundError:
        fail("areas-missing", "%s does not exist: this project has not opted in to verification guides" % path)
    except OSError as e:
        fail("areas-unreadable", "%s could not be read: %s" % (path, e))
    return parse_areas(text, root=root)


def area_names(areas):
    return [a["name"] for a in areas["areas"]]


def bucket(areas, paths):
    """Put each path in exactly one bucket: `area:<name>` or `exempt`. Zero or two is named."""
    files, unowned, ambiguous, touched = [], [], [], []
    rules = [("area:" + a["name"], g) for a in areas["areas"] for g in a["owns"]]
    rules += [("exempt", ex["glob"]) for ex in areas.get("exempt", [])]
    compiled = [(b, glob_to_regex(g)) for b, g in rules]
    for path in paths:
        hits = []
        for b, rx in compiled:
            if rx.match(path) and b not in hits:
                hits.append(b)
        if len(hits) == 1:
            files.append({"path": path, "bucket": hits[0]})
            name = hits[0][len("area:"):] if hits[0].startswith("area:") else None
            if name and name not in touched:
                touched.append(name)
        else:
            files.append({"path": path, "bucket": None, "matches": hits})
            if hits:
                ambiguous.append({"path": path, "buckets": hits})
            else:
                unowned.append(path)
    return {"files": files, "unowned": unowned, "ambiguous": ambiguous, "touched_areas": touched}


# ---------------------------------------------------------------------------------------------
# guides


CHECK_LINE = re.compile(r"^\s*[-*]\s+\[(C[0-9]+)\]\s+(\S.*?)\s*$")


def _sections(text):
    out, current = {}, None
    for line in text.splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            current = m.group(1)
            out.setdefault(current, [])
        elif current is not None:
            out[current].append(line)
    return out


def parse_guide(text):
    """A guide's checks, in order. The template's five sections must all be there."""
    p = []
    secs = _sections(text)
    for s in GUIDE_SECTIONS:
        if s not in secs:
            p.append(("guide-missing-section", "the guide has no '## %s' section" % s))
    checks, seen = [], set()
    for line in secs.get("Checks", []):
        if not line.strip():
            continue
        m = CHECK_LINE.match(line)
        if not m or not CHECK_ID_RE.match(m.group(1)):
            p.append(("guide-bad-check-line", "a line under Checks is not '- [C<n>] <one sentence>': %r" % line.strip()))
            continue
        cid = m.group(1)
        if cid in seen:
            p.append(("guide-duplicate-check", "check %s appears twice" % cid))
            continue
        seen.add(cid)
        checks.append({"id": cid, "text": m.group(2)})
    if "Checks" in secs and not (CHECKS_MIN <= len(checks) <= CHECKS_MAX):
        p.append(("guide-check-count", "the guide has %d checks; a guide holds %d to %d"
                  % (len(checks), CHECKS_MIN, CHECKS_MAX)))
    if p:
        raise VerificationError(p)
    title = next((l[2:].strip() for l in text.splitlines() if l.startswith("# ")), "")
    return {"title": title, "checks": checks}


def load_guide(path):
    try:
        with open(path) as f:
            return parse_guide(f.read())
    except FileNotFoundError:
        fail("guide-missing", "%s does not exist" % path)


# ---------------------------------------------------------------------------------------------
# a PR body's ## Done when


def done_when_items(body):
    """The `## Done when` list of a PR body, numbered D1.. in order. No section is no items."""
    items, inside = [], False
    for line in (body or "").replace("\r\n", "\n").splitlines():
        if re.match(r"^#{1,6}\s", line):
            inside = bool(re.match(r"^##\s+Done when\s*$", line, re.I))
            continue
        if not inside:
            continue
        m = re.match(r"^\s*[-*]\s+(?:\[[ xX]\]\s+)?(\S.*?)\s*$", line)
        if m:
            items.append({"id": "D%d" % (len(items) + 1), "text": m.group(1)})
    return items


# ---------------------------------------------------------------------------------------------
# run records


FENCE_OPEN = "```verification-run"
FENCE_CLOSE = "```"


def _check_items(p, rec, key, id_re, need_blame):
    items = rec.get(key)
    if not isinstance(items, list):
        p.append(("record-bad-field", "%s must be a list" % key))
        return []
    if key == "checks" and not items:
        p.append(("record-no-checks", "a record with no checks verifies nothing"))
    ids = set()
    for i, it in enumerate(items):
        where = "%s[%d]" % (key, i)
        if not isinstance(it, dict):
            p.append(("record-bad-field", "%s must be an object" % where))
            continue
        cid = it.get("id")
        if not isinstance(cid, str) or not id_re.match(cid):
            p.append(("record-bad-field", "%s id %r is malformed" % (where, cid)))
        elif cid in ids:
            p.append(("record-duplicate-id", "%s %s appears twice" % (key, cid)))
        else:
            ids.add(cid)
        if not one_line(it.get("text")):
            p.append(("record-bad-field", "%s text must be one non empty line" % where))
        result = it.get("result")
        if result not in RESULTS:
            p.append(("record-bad-result", "%s result %r is not pass or fail" % (where, result)))
        note = it.get("note")
        if not one_line(note) or len(note) > NOTE_MAX:
            p.append(("record-bad-note", "%s note must be one non empty line of at most %d characters" % (where, NOTE_MAX)))
        blame = it.get("blame")
        if need_blame:
            if result == "fail" and blame not in BLAMES:
                p.append(("record-missing-blame", "%s failed, so it must say whether the code or the guide is wrong"
                          " (blame: code or guide), not %r" % (where, blame)))
            if result == "pass" and blame is not None:
                p.append(("record-blame-on-pass", "%s passed, so it carries no blame" % where))
    return [it for it in items if isinstance(it, dict)]


def validate_record(rec):
    """Raise VerificationError naming every problem with one record; return it with `passed` added."""
    if not isinstance(rec, dict):
        fail("record-bad-field", "a record must be a JSON object")
    schema = rec.get("schema")
    if schema != RUN_SCHEMA:
        if isinstance(schema, str) and schema.startswith("verification-run/"):
            fail("record-schema-unsupported", "schema %r is not %r, the version this reader knows" % (schema, RUN_SCHEMA))
        fail("record-missing-key" if schema is None else "record-bad-field", "schema must be %r" % RUN_SCHEMA)
    p = []
    for key in ("area", "head_sha", "receipt_id", "machine", "runner_agent_id", "checks", "done_when",
                "screenshots", "guide_edits"):
        if key not in rec:
            p.append(("record-missing-key", "missing key: %s" % key))
    shapes = (("area", AREA_NAME), ("head_sha", SHA_RE), ("receipt_id", RECEIPT_ID_RE),
              ("runner_agent_id", AGENT_ID_RE))
    for key, rx in shapes:
        if key in rec and not (isinstance(rec[key], str) and rx.match(rec[key])):
            p.append(("record-bad-field", "%s %r is malformed" % (key, rec[key])))
    if "machine" in rec and not one_line(rec["machine"]):
        p.append(("record-bad-field", "machine must be one non empty line"))
    checks = _check_items(p, rec, "checks", CHECK_ID_RE, True) if "checks" in rec else []
    if "done_when" in rec:
        _check_items(p, rec, "done_when", DONE_ID_RE, False)
    shots = rec.get("screenshots", [])
    if not isinstance(shots, list):
        p.append(("record-bad-field", "screenshots must be a list"))
        shots = []
    for s in shots:
        if not isinstance(s, str) or not SHOT_RE.match(s):
            p.append(("record-bad-screenshot", "screenshot %r must be a plain .png or .jpg file name beside the receipt" % (s,)))
    if len(set(x for x in shots if isinstance(x, str))) != len(shots):
        p.append(("record-bad-screenshot", "a screenshot is named twice"))
    edits = rec.get("guide_edits", [])
    if not isinstance(edits, list):
        p.append(("record-bad-field", "guide_edits must be a list"))
        edits = []
    # Only string ids go in the set: a list or object as an id is already named as record-bad-field,
    # and must not crash the membership tests below.
    check_ids = {c.get("id") for c in checks if isinstance(c.get("id"), str)}
    edited = set()
    for i, e in enumerate(edits):
        where = "guide_edits[%d]" % i
        if not isinstance(e, dict) or not isinstance(e.get("check_id"), str) or e["check_id"] not in check_ids:
            p.append(("record-bad-guide-edit", "%s must name a check in this record" % where))
            continue
        if not all(one_line(e.get(k)) for k in ("old", "new", "why")) or e["old"] == e["new"]:
            p.append(("record-bad-guide-edit", "%s needs one line old, new and why, and new must differ from old" % where))
            continue
        edited.add(e["check_id"])
    for c in checks:
        if c.get("blame") == "guide" and isinstance(c.get("id"), str) and c["id"] not in edited:
            p.append(("record-guide-blame-without-edit", "check %s is blamed on the guide, so the record must carry"
                      " the guide edit (old check, new check, why)" % c.get("id")))
    if p:
        raise VerificationError(p)
    out = dict(rec)
    out["passed"] = all(c["result"] == "pass" for c in rec["checks"]) and \
        all(d["result"] == "pass" for d in rec["done_when"])
    return out


def record_blocks(body):
    """The text of every ```verification-run block in a comment body, in order."""
    blocks, cur = [], None
    for line in (body or "").replace("\r\n", "\n").split("\n"):
        if cur is None:
            if line.strip() == FENCE_OPEN:
                cur = []
        elif line.strip() == FENCE_CLOSE:
            blocks.append("\n".join(cur))
            cur = None
        else:
            cur.append(line)
    if cur is not None:
        blocks.append("\n".join(cur))
    return blocks


def read_block(text, index=0):
    """One ```verification-run block's text, read: (record or None, problems, area or None).

    The area of a block that fails validation is kept when it can be read, so a reader choosing the
    newest record for an area can tell that its newest block is broken rather than absent (L10).
    """
    try:
        obj = json.loads(text)
    except ValueError as e:
        return None, [("record-not-json", "block %d is not JSON: %s" % (index, e))], None
    area = obj.get("area") if isinstance(obj, dict) and isinstance(obj.get("area"), str) else None
    try:
        return validate_record(obj), [], area
    except VerificationError as e:
        return None, e.problems, area


def comment_records(bodies):
    """Every block across a pull request's comments, oldest first, valid or not (claude-config#1529).

    Each entry is {comment, block, record, errors, area}: `record` is the validated record (with
    `passed`) or None, `errors` its problems, `area` the area it names when that can be read.
    """
    out = []
    for ci, body in enumerate(bodies):
        for bi, text in enumerate(record_blocks(body)):
            rec, errors, area = read_block(text, bi)
            out.append({"comment": ci, "block": bi, "record": rec, "errors": errors,
                        "area": rec["area"] if rec else area})
    return out


def parse_comment(body, sha=None):
    """Every record in one comment: the valid ones, and each invalid block with its problems.

    A malformed block is reported, never skipped, so a broken newest record reads as broken and not
    as absent (L10). With `sha`, `matching` holds the valid records made at that head.
    """
    blocks = record_blocks(body)
    if not blocks:
        fail("record-none", "the comment holds no ```verification-run block")
    records, invalid = [], []
    for i, text in enumerate(blocks):
        rec, errors, _area = read_block(text, i)
        if rec is None:
            invalid.append({"index": i, "errors": errors})
            continue
        if sha is not None:
            rec["sha_matches"] = rec["head_sha"] == sha
        records.append(rec)
    out = {"records": records, "invalid": invalid}
    if sha is not None:
        out["matching"] = [r for r in records if r["sha_matches"]]
    return out


def _json_for_fence(obj):
    # A backtick inside a string could close the fence early, so each one is written as JSON's own
    # unicode escape for it (backslash, u, 0060), which any JSON reader decodes to the same string.
    return json.dumps(obj, indent=2, ensure_ascii=False).replace("`", "\\u0060")


def _cell(s):
    return s.replace("|", "\\|")


def _render_area(rec):
    n_pass = sum(1 for c in rec["checks"] if c["result"] == "pass")
    lines = ["### %s: %d of %d checks pass" % (rec["area"], n_pass, len(rec["checks"])), "",
             "| Check | Result | Note |", "|---|---|---|"]
    for c in rec["checks"]:
        res = c["result"] + (" (%s is wrong)" % c["blame"] if c.get("blame") else "")
        lines.append("| %s %s | %s | %s |" % (c["id"], _cell(c["text"]), res, _cell(c["note"])))
    if rec["done_when"]:
        lines += ["", "| Done when | Result | Note |", "|---|---|---|"]
        for d in rec["done_when"]:
            lines.append("| %s %s | %s | %s |" % (d["id"], _cell(d["text"]), d["result"], _cell(d["note"])))
    if rec["guide_edits"]:
        lines += ["", "Guide edits, decided by the runner:", "",
                  "| Check | Old check | New check | Why |", "|---|---|---|---|"]
        for e in rec["guide_edits"]:
            lines.append("| %s | %s | %s | %s |" % (e["check_id"], _cell(e["old"]), _cell(e["new"]), _cell(e["why"])))
    if rec["screenshots"]:
        lines += ["", "Screenshots beside the receipt: " + ", ".join(rec["screenshots"])]
    lines += ["", FENCE_OPEN, _json_for_fence(rec), FENCE_CLOSE, ""]
    return lines


def load_receipt(receipt_id, home=None):
    rdir = receipt_dir(receipt_id, home)
    path = os.path.join(rdir, "receipt.json")
    try:
        with open(path) as f:
            text = f.read()
    except FileNotFoundError:
        fail("receipt-missing", "no receipt %s at %s" % (receipt_id, path))
    try:
        rec = json.loads(text)
    except ValueError as e:
        fail("receipt-not-json", "%s is not JSON: %s" % (path, e))
    if not isinstance(rec, dict) or rec.get("schema") != RECEIPT_SCHEMA:
        fail("receipt-schema-unsupported", "%s is not a %s receipt" % (path, RECEIPT_SCHEMA))
    return rec


def load_drives(receipt_id, home=None):
    """Every drive call a run logged, from drives.jsonl beside its receipt (claude-config#1529).

    run_session.py appends one line per call: {at, area, args, exit}. A run with no log made no
    call, which is an answer (no calls), not a fault. A line that is not that shape is named.
    """
    path = os.path.join(receipt_dir(receipt_id, home), "drives.jsonl")
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return []
    except OSError as e:
        fail("drives-unreadable", "%s could not be read: %s" % (path, e))
    calls = []
    for n, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except ValueError as e:
            fail("drives-not-json", "%s line %d is not JSON: %s" % (path, n, e))
        ok = isinstance(obj, dict) and isinstance(obj.get("area"), str) and \
            isinstance(obj.get("exit"), int) and not isinstance(obj.get("exit"), bool)
        if not ok:
            fail("drives-bad-line", "%s line %d is not {area, exit}: %r" % (path, n, line[:200]))
        calls.append(obj)
    return calls


# ---------------------------------------------------------------------------------------------
# the warn tally (claude-config#1529)
#
# In `mode: warn` the merge check allows every merge and appends its verdict here, one line per
# judgment, keyed by pull request; the latest line for a pull request is its verdict. A main session
# hook asks Dan whether to switch a repository to block once TALLY_ASK_EVERY distinct pull requests
# have been judged since he was last asked. Kept under VERIFICATION_HOME, never ~/.claude, because
# the sync mirrors ~/.claude to a public repository and these lines name work repositories.

TALLY_SCHEMA = "verification-tally/1"
TALLY_ASK_EVERY = 5   # chosen, not measured: enough merges to see whether block would refuse them all
SLUG_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def tally_dir(home=None):
    return os.path.join(home or verification_home(), "merge-tally")


def tally_file(slug, home=None):
    if not isinstance(slug, str) or not SLUG_RE.match(slug) or ".." in slug.split("/"):
        fail("tally-bad-repo", "%r is not an owner/name repository" % (slug,))
    owner, name = slug.split("/")
    return os.path.join(tally_dir(home), owner, name + ".jsonl")


def tally_append(slug, pr, head_sha, passed, kinds, home=None):
    path = tally_file(slug, home)
    line = json.dumps({"schema": TALLY_SCHEMA, "repo": slug, "pr": int(pr), "head_sha": head_sha,
                       "at": utc_now(), "passed": bool(passed), "kinds": sorted(set(kinds))}) + "\n"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # One write to a file opened for append, so two merges judged at once never interleave a line.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, line.encode())
    finally:
        os.close(fd)


def tally_summary(slug, home=None):
    """{prs: {pr: latest entry}, unreadable_lines: n} for one repository's tally."""
    path = tally_file(slug, home)
    prs, bad = {}, 0
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        lines = []
    for line in lines:
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
            pr = int(obj["pr"])
        except (ValueError, KeyError, TypeError):
            bad += 1
            continue
        if obj.get("schema") != TALLY_SCHEMA:
            bad += 1
            continue
        prs[pr] = obj
    return {"prs": prs, "unreadable_lines": bad}


def tally_read(slug, home=None):
    return tally_summary(slug, home)["prs"]


def _asked_path(slug, home=None):
    return tally_file(slug, home)[:-len(".jsonl")] + ".asked"


def _asked_at(slug, home=None):
    """How many pull requests the tally held when Dan was last asked; 0 when he never was."""
    try:
        with open(_asked_path(slug, home)) as f:
            return int(f.read().strip() or 0)
    except (OSError, ValueError):
        return 0


def tally_progress(slug, home=None, every=TALLY_ASK_EVERY):
    """(pull requests judged so far, the count at which Dan is next asked) for one repository."""
    return len(tally_read(slug, home)), _asked_at(slug, home) + every


def tally_due(home=None, every=TALLY_ASK_EVERY, mark=False):
    """Every repository whose tally has grown by `every` pull requests since Dan was last asked.

    With `mark`, records each one as asked at its current count, so the next question waits for
    `every` more pull requests rather than repeating on every tool call.
    """
    root = tally_dir(home)
    due = []
    for owner in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        odir = os.path.join(root, owner)
        for name in sorted(os.listdir(odir)) if os.path.isdir(odir) else []:
            if not name.endswith(".jsonl"):
                continue
            slug = "%s/%s" % (owner, name[:-len(".jsonl")])
            try:
                s = tally_summary(slug, home)
            except VerificationError:
                continue
            asked = _asked_at(slug, home)
            n = len(s["prs"])
            if n < asked + every:
                continue
            counts = {}
            for e in s["prs"].values():
                for k in e.get("kinds") or []:
                    counts[k] = counts.get(k, 0) + 1
            passed = sum(1 for e in s["prs"].values() if e.get("passed") is True)
            due.append({"repo": slug, "prs": n, "passed": passed, "refused": n - passed, "kinds": counts,
                        "asked_at": asked, "unreadable_lines": s["unreadable_lines"]})
            if mark:
                tmp = _asked_path(slug, home) + ".tmp"
                with open(tmp, "w") as f:
                    f.write(str(n))
                os.replace(tmp, _asked_path(slug, home))
    return due


def render_comment(draft, home=None, transcripts=None, pr_body=""):
    """Turn a runner's draft into the PR comment body, filling every measured field itself.

    The runner supplies only judgments: each check's result, note and blame, each done when item's
    result and note, screenshot names and guide edits. The head SHA, machine and receipt come from
    the receipt; check text and old guide text from the guide copy the run took at start; done when
    text from the PR body; the runner's agent id from its own transcript (L161). The receipt must
    show serve stopped, so a record can only be written after the run is over.
    """
    if not isinstance(draft, dict) or not isinstance(draft.get("areas"), list) or not draft["areas"]:
        fail("render-bad-draft", "the draft must be an object with receipt_id, nonce and a non empty areas list")
    rid = draft.get("receipt_id")
    receipt = load_receipt(rid, home)
    rdir = receipt_dir(rid, home)
    if not receipt.get("stopped_at"):
        fail("render-receipt-not-stopped", "receipt %s shows serve still running: run run_session.py stop first" % rid)
    if receipt.get("machine") != machine_name():
        fail("render-other-machine", "receipt %s was made on %s, not this machine (%s)"
             % (rid, receipt.get("machine"), machine_name()))
    agent = find_agent_id(draft.get("nonce"), transcripts)
    done = done_when_items(pr_body)
    done_text = {d["id"]: d["text"] for d in done}
    p, records, seen = [], [], set()
    for a in draft["areas"]:
        name = a.get("area") if isinstance(a, dict) else None
        if name not in receipt.get("areas", []):
            p.append(("render-area-not-in-run", "area %r was not served by run %s (it served %s)"
                      % (name, rid, ", ".join(receipt.get("areas", [])))))
            continue
        if name in seen:
            p.append(("render-duplicate-area", "area %s appears twice in the draft" % name))
            continue
        seen.add(name)
        guide = load_guide(os.path.join(rdir, "guides", name + ".md"))
        gtext = {c["id"]: c["text"] for c in guide["checks"]}
        not_lists = [k for k in ("checks", "done_when", "screenshots", "guide_edits")
                     if not isinstance(a.get(k, []), list)]
        if not_lists:
            p.append(("render-bad-draft", "area %s: %s must be a list" % (name, " and ".join(not_lists))))
            continue
        checks = [c for c in a.get("checks", []) if isinstance(c, dict)]
        # Every id as a string, so an entry with no id is a mismatch, never a crash in sorted().
        got = [str(c.get("id")) for c in checks]
        if sorted(got) != sorted(gtext) or len(got) != len(set(got)):
            p.append(("render-checks-mismatch", "area %s: the guide's checks are %s, the draft has %s"
                      % (name, ", ".join(gtext), ", ".join(map(str, got)) or "none")))
            continue
        dw = [d for d in a.get("done_when", []) if isinstance(d, dict)]
        if sorted(str(d.get("id")) for d in dw) != sorted(done_text):
            p.append(("render-done-when-mismatch", "area %s: the PR's done when items are %s, the draft has %s"
                      % (name, ", ".join(done_text) or "none", ", ".join(str(d.get("id")) for d in dw) or "none")))
            continue
        shots = a.get("screenshots", [])
        for s in shots if isinstance(shots, list) else []:
            if isinstance(s, str) and SHOT_RE.match(s) and not os.path.isfile(os.path.join(rdir, s)):
                p.append(("render-screenshot-missing", "screenshot %s is not beside receipt %s" % (s, rid)))
        edits = []
        for e in a.get("guide_edits", []):
            e = dict(e) if isinstance(e, dict) else {}
            # A check_id that is not a string (a list, a number) names no check: validate_record
            # below refuses it as record-bad-guide-edit rather than this lookup crashing.
            cid = e.get("check_id") if isinstance(e.get("check_id"), str) else None
            edits.append({"check_id": cid, "old": gtext.get(cid, ""), "new": e.get("new"), "why": e.get("why")})
        rec = {
            "schema": RUN_SCHEMA,
            "area": name,
            "head_sha": receipt.get("head_sha"),
            "receipt_id": rid,
            "machine": receipt.get("machine"),
            "runner_agent_id": agent,
            "checks": [dict({k: c.get(k) for k in ("id", "result", "note")}, text=gtext[c["id"]],
                            **({"blame": c["blame"]} if c.get("blame") is not None else {}))
                       for c in sorted(checks, key=lambda c: int(c["id"][1:]))],
            "done_when": [{"id": d["id"], "text": done_text[d["id"]], "result": d.get("result"), "note": d.get("note")}
                          for d in sorted(dw, key=lambda d: int(d["id"][1:]))],
            "screenshots": shots,
            "guide_edits": edits,
        }
        try:
            validate_record(rec)
        except VerificationError as e:
            p.extend(e.problems)
            continue
        records.append(rec)
    missing = [x for x in receipt.get("areas", []) if x not in seen]
    if missing and not p:
        p.append(("render-area-missing", "the run served %s but the draft has no record for it" % ", ".join(missing)))
    if p:
        raise VerificationError(p)
    head = ["## Verification run at %s" % receipt["head_sha"][:7], "",
            "Receipt `%s` on %s, runner agent `%s`. Serve stopped at %s (%s)."
            % (rid, receipt["machine"], agent, receipt["stopped_at"], receipt.get("stopped_by")), ""]
    for rec in records:
        head += _render_area(rec)
    return "\n".join(head)


# ---------------------------------------------------------------------------------------------
# who is the runner


def new_nonce():
    return "vg-" + secrets.token_hex(8)


def _first_prompt_text(line):
    try:
        obj = json.loads(line)
    except ValueError:
        return ""
    if not isinstance(obj, dict) or obj.get("parentUuid") is not None or obj.get("type") != "user":
        return ""
    content = (obj.get("message") or {}).get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict))
    return ""


def find_agent_id(nonce, transcripts=None, max_age_s=3 * 86400):
    """The id of the one subagent whose BRIEF (its first message) carries the nonce.

    The brief is the only place the nonce is put, so this is measured rather than claimed: an agent
    that merely mentions it later, like the session that dispatched it, is not matched.
    """
    if not isinstance(nonce, str) or not NONCE_RE.match(nonce):
        fail("agent-bad-nonce", "%r is not a nonce from `verification.py nonce`" % (nonce,))
    root = transcripts or os.environ.get("VERIFICATION_TRANSCRIPTS") or os.path.expanduser("~/.claude/projects")
    found, cutoff = [], time.time() - max_age_s
    for proj in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        pdir = os.path.join(root, proj)
        for sess in sorted(os.listdir(pdir)) if os.path.isdir(pdir) else []:
            sdir = os.path.join(pdir, sess, "subagents")
            if not os.path.isdir(sdir):
                continue
            for name in sorted(os.listdir(sdir)):
                if not (name.startswith("agent-") and name.endswith(".jsonl")):
                    continue
                path = os.path.join(sdir, name)
                try:
                    if os.path.getmtime(path) < cutoff:
                        continue
                    with open(path, errors="replace") as f:
                        first = f.readline(4 * 1024 * 1024)
                except OSError:
                    continue  # a transcript removed between listing and reading cannot be this agent's
                if nonce in _first_prompt_text(first):
                    try:
                        aid = json.loads(first).get("agentId")
                    except (ValueError, AttributeError):
                        aid = None
                    found.append(aid if isinstance(aid, str) and aid else name[len("agent-"):-len(".jsonl")])
    if not found:
        fail("agent-not-found", "no subagent transcript under %s has %s in its brief: the runner must be"
             " dispatched by the main session with the nonce in its prompt" % (root, nonce))
    if len(set(found)) > 1:
        fail("agent-ambiguous", "%d subagents have %s in their brief (%s): use a fresh nonce per run"
             % (len(found), nonce, ", ".join(found)))
    return found[0]


# ---------------------------------------------------------------------------------------------
# CLI


def _print_problems(err):
    for kind, msg in err.problems:
        print("verification: %s: %s" % (kind, msg), file=sys.stderr)


def _read_stdin():
    return sys.stdin.read()


def _cmd(argv):
    if argv[:2] == ["areas", "validate"] and len(argv) in (3, 5):
        root = argv[4] if len(argv) == 5 and argv[3] == "--root" else None
        if len(argv) == 5 and root is None:
            return None
        if root is None:
            root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(argv[2]))))
        doc = load_areas(argv[2], root=root)
        print(json.dumps({"ok": True, "areas": area_names(doc), "mode": doc["mode"]}))
        return 0
    if argv[:1] == ["bucket"] and len(argv) >= 2:
        doc = load_areas(argv[1])
        paths = argv[2:] or [l.strip() for l in _read_stdin().splitlines() if l.strip()]
        out = bucket(doc, paths)
        print(json.dumps(out, indent=2))
        p = [("bucket-unowned", "%s is owned by no area and no exemption" % u) for u in out["unowned"]]
        p += [("bucket-ambiguous", "%s is claimed by %s" % (a["path"], " and ".join(a["buckets"])))
              for a in out["ambiguous"]]
        if p:
            raise VerificationError(p)
        return 0
    if argv[:2] == ["guide", "check"] and len(argv) == 3:
        g = load_guide(argv[2])
        print(json.dumps(g, indent=2))
        return 0
    if argv == ["done-when"]:
        print(json.dumps(done_when_items(_read_stdin()), indent=2))
        return 0
    if argv[:2] == ["record", "parse"] and len(argv) in (2, 4):
        sha = None
        if len(argv) == 4:
            if argv[2] != "--sha" or not SHA_RE.match(argv[3]):
                return None
            sha = argv[3]
        out = parse_comment(_read_stdin(), sha=sha)
        print(json.dumps(out, indent=2))
        if out["invalid"]:
            raise VerificationError([pr for inv in out["invalid"] for pr in inv["errors"]])
        if sha is not None and not out["matching"]:
            fail("record-other-sha", "no valid record here was made at %s (records are at %s)"
                 % (sha, ", ".join(sorted({r["head_sha"][:7] for r in out["records"]}))))
        return 0
    if argv[:2] == ["record", "render"] and len(argv) == 4 and argv[2] == "--pr-body":
        try:
            with open(argv[3]) as f:
                body = f.read()
        except OSError as e:
            fail("render-bad-draft", "the PR body file %s could not be read: %s" % (argv[3], e))
        try:
            draft = json.loads(_read_stdin())
        except ValueError as e:
            fail("render-bad-draft", "the draft on stdin is not JSON: %s" % e)
        sys.stdout.write(render_comment(draft, pr_body=body))
        return 0
    if argv[:2] == ["receipt", "show"] and len(argv) == 3:
        print(json.dumps(load_receipt(argv[2]), indent=2))
        return 0
    if argv[:2] == ["tally", "due"] and argv[2:] in ([], ["--mark"]):
        print(json.dumps(tally_due(mark=argv[2:] == ["--mark"]), indent=2))
        return 0
    if argv == ["nonce"]:
        print(new_nonce())
        return 0
    if argv[:1] == ["whoami"] and len(argv) == 2:
        print(find_agent_id(argv[1]))
        return 0
    return None


def main(argv):
    try:
        rc = _cmd(argv)
    except VerificationError as e:
        _print_problems(e)
        return e.code
    if rc is None:
        print("verification: usage: see the docstring at the top of %s" % os.path.abspath(__file__), file=sys.stderr)
        return 2
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
