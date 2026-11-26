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
  guide (no version)      .claude/verification/guides/<area>.md, one of two fixed templates: by hand
                          (guide-template.md) or model check (model-check-template.md, #3471)
  verification-run/1      one fenced ```verification-run block per area in a PR comment
  verification-receipt/1  <home>/receipts/<id>/receipt.json, written only by run_session.py
                          (and drives.jsonl beside it, one line per drive call)
  verification-rendered/1 <home>/receipts/<id>/rendered.jsonl, one line per record `record render`
                          wrote, so the merge check can refuse a record edited after render (#1572)
  verification-tally/1    <home>/merge-tally/<owner>/<name>.jsonl, the merge check's warn tally (#1529)
  verification-screenshots/1  the `## Screenshots` block of a PR body, read by screenshots.py beside
                          this file, which owns that one format (#2516); its `screens`, `seeds` and
                          `screenshots` keys in areas.json are validated here with the rest

The merge check (#1529) is merge_check.py beside this file: it judges a pull request through these
readers and parses no format itself.

CLI (every refusal prints `verification: <kind>: <message>` on stderr, one line per problem):

  verification.py areas validate <areas.json> [--root <repo>]
  verification.py bucket <areas.json> [<path> ...]          paths on stdin when none are given
  verification.py guide check <guide.md>                    a by hand or a model check guide (#3471)
  verification.py guide stale <areas.json> <area> [--repo <checkout>]
                                                            a model check guide's owned files changed
                                                            since its Last checked commit: exit 9
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
  8 the run itself failed (run_session.py)  9 guide-stale (a model check to run again)

Env: VERIFICATION_HOME (default ~/.claude-verification, outside ~/.claude on purpose: the sync
mirrors ~/.claude to a public repository, and receipts hold screenshots of private apps), and
VERIFICATION_TRANSCRIPTS (default ~/.claude/projects) for whoami.
"""

import hashlib
import ipaddress
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import time

AREAS_SCHEMA = "verification-areas/1"
RUN_SCHEMA = "verification-run/1"
RECEIPT_SCHEMA = "verification-receipt/1"
RENDERED_SCHEMA = "verification-rendered/1"
AREAS_PATH = ".claude/verification/areas.json"

GUIDE_SECTIONS = ("Roles", "Reach", "State setup", "Checks", "Known traps")
# A model check guide (claude-config#3471): rules about the order things happen in, checked
# against a model written from the code. A guide is one kind or the other by its sections, the way
# a screen is web or native by its keys, and never both.
MODEL_GUIDE_SECTIONS = ("Rules", "Not covered", "Model", "Last checked", "Checks", "Known traps")
BY_HAND_ONLY = tuple(s for s in GUIDE_SECTIONS if s not in MODEL_GUIDE_SECTIONS)
MODEL_ONLY = tuple(s for s in MODEL_GUIDE_SECTIONS if s not in GUIDE_SECTIONS)
GUIDE_KINDS = ("by-hand", "model-check")
CHECKS_MIN, CHECKS_MAX = 3, 6
NOTE_MAX = 300

AREA_NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}\Z")
SHA_RE = re.compile(r"^[0-9a-f]{40}\Z")
RECEIPT_ID_RE = re.compile(r"^\d{8}T\d{6}Z-[0-9a-f]{7}-[0-9a-f]{6}\Z")
AGENT_ID_RE = re.compile(r"^[A-Za-z0-9_-]{2,64}\Z")
CHECK_ID_RE = re.compile(r"^C[1-9][0-9]?\Z")
DONE_ID_RE = re.compile(r"^D[1-9][0-9]?\Z")
SHOT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.(png|jpg|jpeg)\Z")
NONCE_RE = re.compile(r"^vg-[0-9a-f]{16}\Z")
# A native screen's test, as xcodebuild's -only-testing names one (Target, Target/Class, or
# Target/Suite/function() in Swift Testing) and swift test's --filter accepts: segments of
# identifier characters joined by single slashes, the last optionally ending in (). Nothing a
# shell would read as anything but text (claude-config#2696).
NATIVE_TEST_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.]{0,99}(/[A-Za-z_][A-Za-z0-9_.]{0,99}){0,2}(\(\))?\Z")
LOCAL_URL = re.compile(r"^http://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]{1,5})?(/.*)?\Z")

COMMANDS_REQUIRED = ("stop", "drive")
COMMANDS_OPTIONAL = ("stamp", "native_shot")
# What a run needs to serve the app (claude-config#2951). Required unless the project is all native
# (a native screen and no web one), which has nothing to serve and gives all three or none.
SERVE_COMMANDS = ("serve", "ready")
SERVE_SETTINGS = ("url",) + tuple("commands." + c for c in SERVE_COMMANDS)
TIMEOUT_DEFAULTS = {"ready_s": 300, "ready_interval_s": 2, "max_run_s": 3600, "stop_s": 60, "egress_s": 30}
# The hosts a served app may always reach: this machine. areas.json's egress.allow adds to them,
# and a run's egress verdict is clean only when nothing outside the combined list was reached.
EGRESS_LOCAL_HOSTS = ("127.0.0.1", "localhost", "::1")
EGRESS_HOST = re.compile(r"^(?=.{1,253}\Z)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
                         r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\Z")
EGRESS_VERDICTS = ("clean", "not-clean", "unmeasured")
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
    # a model check guide whose area has changed since it was last checked, or never checked
    "guide-stale": 9,
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


def first_line(s):
    """The first line of a tool's output that holds anything, stripped; "" when none does."""
    return next((l.strip() for l in (s or "").splitlines() if l.strip()), "")


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
    return re.compile("^" + "".join(out) + r"\Z")


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
            if key != "url":  # settled with serve and ready, once the areas say whether anything is web
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
        for name in COMMANDS_REQUIRED + SERVE_COMMANDS + COMMANDS_OPTIONAL:
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

    seeds = _parse_seeds(p, doc.get("seeds", {}))
    shots = doc.get("screenshots", {})
    if not isinstance(shots, dict):
        p.append(("areas-wrong-type", "screenshots must be an object"))
        shots = {}
    if shots.get("mode", "warn") not in MODES:
        p.append(("areas-bad-screenshots-mode", "screenshots.mode %r is not one of %s" % (shots.get("mode"), ", ".join(MODES))))

    names = set()
    native, web_areas = False, []
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
        kinds = _check_screens(p, where, area.get("screens", []), seeds)
        native |= "native" in kinds
        if "web" in kinds:
            web_areas.append(name if isinstance(name, str) else where)

    if native and isinstance(cmds, dict) and "native_shot" not in cmds:
        p.append(("areas-native-no-shot-command", "a screen is a native one (a test and a frame), and"
                  " commands.native_shot, the command that runs the offscreen test photographing it, is missing"))

    _check_serve_settings(p, doc, cmds, native, web_areas)

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

    allow = list(EGRESS_LOCAL_HOSTS)
    egress = doc.get("egress", {})
    if not isinstance(egress, dict):
        p.append(("areas-wrong-type", "egress must be an object"))
        egress = {}
    extra = egress.get("allow", [])
    if not isinstance(extra, list):
        p.append(("areas-wrong-type", "egress.allow must be a list"))
        extra = []
    for i, host in enumerate(extra):
        if not egress_host_ok(host):
            p.append(("areas-bad-egress-host", "egress.allow[%d] %r is not a host name or an IP address: give"
                      " the bare host, with no scheme, port, path or wildcard" % (i, host)))
        elif host not in allow:
            allow.append(host)

    if p:
        raise VerificationError(p)
    doc["timeouts"] = timeouts
    doc.setdefault("exempt", [])
    doc["egress"] = dict(egress, allow=allow)
    doc["seeds"] = seeds
    # The screenshots block switch (claude-config#2516): present, and warn until it has been seen
    # working on real pull requests for a week.
    doc["screenshots"] = dict(shots, mode=shots.get("mode", "warn"))
    for area in doc["areas"]:
        area.setdefault("screens", [])
    return doc


def serves(doc):
    """Whether a run of this parsed areas.json serves the app: false only for a project whose areas
    are all native and which gives no serve command (claude-config#2951)."""
    return "serve" in doc["commands"]


def _check_serve_settings(p, doc, cmds, native, web_areas):
    """url, commands.serve and commands.ready: what a run needs to serve the app (claude-config#2951).

    A project is all native when at least one of its screens is native and none is web; an area
    with no screens is neither. Such a project has nothing to serve, so the three are optional, but
    a run cannot serve without all three, so it gives all of them or none. Any other project needs
    all three: one with no native screen (web screens only, or none) is told key by key, as it
    always was, and one with a native screen is told which area made serving necessary.
    """
    # Given means the key is there: a null is the wrong type, already said, not also missing. With no
    # commands object, that is already said too, and only url is judged here.
    judged = SERVE_SETTINGS if isinstance(cmds, dict) else ("url",)
    present = [k for k in judged if k.split(".")[-1] in (doc if k == "url" else cmds)]
    missing = [k for k in judged if k not in present]
    if not missing:
        return
    if native and not web_areas:
        if present:
            p.append(("areas-serve-incomplete", "every area is native, so url, commands.serve and commands.ready"
                      " may all be left out, but a run cannot serve with only %s; missing: %s"
                      % (", ".join(present), ", ".join(missing))))
        return
    if not native:
        for k in missing:
            p.append(("areas-missing-key", "missing key: %s" % k))
        return
    p.append(("areas-web-needs-serve", "area %s has a web screen, a route on the served app, so the run must"
              " serve it; missing: %s" % (", ".join(repr(a) for a in web_areas), ", ".join(missing))))


def _parse_seeds(p, seeds):
    """The seeds screens are shot with, {name: {synthetic, why}} (claude-config#2516).

    `synthetic` true declares the seed made up, which is the only case a public repository may hold
    its pictures. The why is required either way, so a declaration always carries its reason (L540).
    """
    if not isinstance(seeds, dict):
        p.append(("areas-wrong-type", "seeds must be an object"))
        return {}
    for name, seed in seeds.items():
        if not AREA_NAME.match(name) or not isinstance(seed, dict) or not isinstance(seed.get("synthetic"), bool):
            p.append(("areas-bad-seed", "seeds.%s must be {\"synthetic\": true or false, \"why\": <one line>}, with a"
                      " lower case hyphenated name" % name))
        elif not one_line(seed.get("why")):
            p.append(("areas-seed-no-why", "seeds.%s needs a one line why: what the seed holds and where it comes from" % name))
    return seeds


def _check_screens(p, where, screens, seeds):
    """An area's screens: what its pull requests are pictured at (claude-config#2516, #2696).

    A web screen is a route on the served app, `path`, with an optional CSS selector `rows` and its
    `min_rows`. A native screen is an offscreen test, `test`, and the `frame` it draws, with an
    optional `min_rows` the test reports it drew. Returns the set of kinds its screens are, "web"
    and "native" (claude-config#2951).
    """
    kinds = set()
    if not isinstance(screens, list):
        p.append(("areas-wrong-type", "%s screens must be a list" % where))
        return kinds
    seen = set()
    for j, sc in enumerate(screens):
        at = "%s screens[%d]" % (where, j)
        if not isinstance(sc, dict):
            p.append(("areas-wrong-type", "%s must be an object" % at))
            continue
        name = sc.get("name")
        if not isinstance(name, str) or not AREA_NAME.match(name) or "__" in name:
            p.append(("areas-bad-screen", "%s name %r must be lower case letters, digits and single hyphens" % (at, name)))
        elif name in seen:
            p.append(("areas-bad-screen", "%s name %r is used twice in this area" % (at, name)))
        else:
            seen.add(name)
        seed = sc.get("seed")
        if not isinstance(seed, str) or seed not in seeds:
            p.append(("areas-unknown-seed", "%s seed %r is not declared in seeds" % (at, seed)))
        if "path" in sc and "test" in sc:
            p.append(("areas-bad-screen", "%s gives a path and a test: a screen is a route or a test, not both" % at))
        elif "test" in sc:
            kinds.add("native")
            _check_native_screen(p, at, sc)
        else:
            kinds.add("web")
            _check_web_screen(p, at, sc)
    return kinds


def _check_web_screen(p, at, sc):
    path = sc.get("path")
    if not isinstance(path, str) or not path.startswith("/") or not one_line(path) or " " in path:
        p.append(("areas-bad-screen", "%s path %r must be a route on the served app, starting with /" % (at, path)))
    rows, minimum = sc.get("rows"), sc.get("min_rows")
    if (rows is None) != (minimum is None):
        p.append(("areas-bad-screen", "%s gives rows and min_rows together or neither" % at))
    elif rows is not None and (not one_line(rows) or not _whole_at_least_one(minimum)):
        p.append(("areas-bad-screen", "%s rows must be a CSS selector and min_rows a whole number of at least 1" % at))


def _check_native_screen(p, at, sc):
    """A native screen (claude-config#2696): the offscreen test that photographs it, and its frame."""
    test = sc.get("test")
    if not isinstance(test, str) or not NATIVE_TEST_RE.fullmatch(test):
        p.append(("areas-bad-screen", "%s test %r must name the offscreen test that photographs it, as"
                  " Target, Target/Suite or Target/Suite/function()" % (at, test)))
    frame = sc.get("frame")
    if not isinstance(frame, str) or not AREA_NAME.fullmatch(frame) or "__" in frame:
        p.append(("areas-bad-screen", "%s frame %r must be the name the test draws it by, in lower case"
                  " letters, digits and single hyphens" % (at, frame)))
    if "rows" in sc:
        p.append(("areas-bad-screen", "%s is a native screen, which has no CSS selector: give min_rows alone,"
                  " and the test reports how many rows it drew" % at))
    elif "min_rows" in sc and not _whole_at_least_one(sc["min_rows"]):
        p.append(("areas-bad-screen", "%s min_rows %r must be a whole number of at least 1" % (at, sc["min_rows"])))


def _whole_at_least_one(n):
    return isinstance(n, int) and not isinstance(n, bool) and n >= 1


def egress_host_ok(host):
    """A bare host name or IP address, the only shape egress.allow accepts."""
    if not isinstance(host, str):
        return False
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return bool(EGRESS_HOST.match(host))


def load_areas(path, root=None):
    try:
        with open(path, errors="strict") as f:
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


CHECK_LINE = re.compile(r"^\s*[-*]\s+\[(C[0-9]+)\]\s+(\S.*?)\s*\Z")


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


RULE_LINE = re.compile(r"^[-*]\s+\[(R[0-9]+)\]\s+(\S.*?)\s*\Z")
RULE_ID_RE = re.compile(r"^R[1-9][0-9]?\Z")
RULE_FIELD = re.compile(r"^\s+[-*]\s+(Good outcome|Approved by Dan):\s*(.*?)\s*\Z")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}\Z")
LAST_FIELD = re.compile(r"^\s*[-*]\s+(Commit|Result):\s*(.*?)\s*\Z")


def guide_kind(secs):
    """'model-check' when the guide has a section only that kind has, else 'by-hand'. A guide holding
    sections of both kinds is refused, so neither reading is a guess."""
    by_hand = [s for s in BY_HAND_ONLY if s in secs]
    model = [s for s in MODEL_ONLY if s in secs]
    if by_hand and model:
        fail("guide-mixed-kinds", "the guide has sections of a by hand guide (%s) and of a model check guide (%s): a guide is one kind"
             % (", ".join(by_hand), ", ".join(model)))
    return "model-check" if model else "by-hand"


def _parse_rules(p, lines):
    rules, seen, current = [], set(), None
    for line in lines:
        if not line.strip():
            continue
        m = RULE_LINE.match(line)
        if m and RULE_ID_RE.match(m.group(1)):
            current = None
            if m.group(1) in seen:
                p.append(("guide-duplicate-rule", "rule %s appears twice" % m.group(1)))
                continue
            seen.add(m.group(1))
            current = {"id": m.group(1), "text": m.group(2), "good_outcome": None, "approved": None}
            rules.append(current)
            continue
        f = RULE_FIELD.match(line)
        if f and current is not None:
            key = "good_outcome" if f.group(1) == "Good outcome" else "approved"
            current[key] = f.group(2) or None
            continue
        p.append(("guide-bad-rule-line", "a line under Rules is not '- [R<n>] <one sentence>' or one of its"
                  " indented 'Good outcome:' and 'Approved by Dan:' lines: %r" % line.strip()))
    if not rules and not any(k == "guide-bad-rule-line" for k, _ in p):
        p.append(("guide-no-rules", "the guide has no rule under Rules: a model check holds at least one"))
    for r in rules:
        if not r["good_outcome"]:
            p.append(("guide-rule-no-good-outcome", "%s has no 'Good outcome:' line, so a model where nothing"
                      " happens would pass it" % r["id"]))
        if not (r["approved"] and DATE_RE.match(r["approved"])):
            p.append(("guide-rule-not-approved", "%s has no 'Approved by Dan: <YYYY-MM-DD>' line: a rule is"
                      " modelled only once Dan has approved its sentence" % r["id"]))
    return rules


def _parse_last_checked(p, lines):
    got = {}
    for line in lines:
        m = LAST_FIELD.match(line)
        if m:
            got[m.group(1)] = m.group(2)
    commit, result = got.get("Commit", ""), got.get("Result", "")
    if not (commit == "never" or SHA_RE.match(commit)):
        p.append(("guide-bad-last-checked", "Last checked needs '- Commit: <40 hex>' or '- Commit: never', not %r" % commit))
    if not result:
        p.append(("guide-bad-last-checked", "Last checked needs '- Result: <one line>'"))
    return {"commit": None if commit == "never" else commit, "result": result}


def parse_guide(text):
    """A guide's kind and checks, in order. A by hand guide has the template's five sections; a
    model check guide (claude-config#3471) has model-check-template.md's six, with its rules, each
    approved by Dan, and the commit it was last checked against."""
    p = []
    secs = _sections(text)
    kind = guide_kind(secs)
    for s in (MODEL_GUIDE_SECTIONS if kind == "model-check" else GUIDE_SECTIONS):
        if s not in secs:
            p.append(("guide-missing-section", "the guide has no '## %s' section" % s))
    extra = {}
    if kind == "model-check":
        extra["rules"] = _parse_rules(p, secs.get("Rules", []))
        for s in ("Not covered", "Model"):
            if s in secs and not any(l.strip() for l in secs[s]):
                p.append(("guide-empty-section", "the guide's '## %s' section is empty" % s))
        if "Last checked" in secs:
            extra["last_checked"] = _parse_last_checked(p, secs["Last checked"])
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
    return dict({"title": title, "kind": kind, "checks": checks}, **extra)


def load_guide(path):
    try:
        with open(path, errors="strict") as f:
            return parse_guide(f.read())
    except FileNotFoundError:
        fail("guide-missing", "%s does not exist" % path)


def guide_stale(areas_path, area_name, repo):
    """Whether a model check guide must be checked again (claude-config#3471): the files its area
    owns that changed between the commit the guide was last checked against and HEAD of `repo`.
    Returns {"area", "last_checked", "changed"}; raises guide-stale when anything changed or the
    guide was never checked, so a caller cannot read a stale guide as a current one."""
    doc = load_areas(areas_path)
    area = next((a for a in doc["areas"] if a["name"] == area_name), None)
    if area is None:
        fail("usage", "areas.json has no area named %s (it has %s)" % (area_name, ", ".join(area_names(doc))))
    guide = load_guide(os.path.join(repo, area["guide"]))
    if guide["kind"] != "model-check":
        fail("guide-not-model-check", "%s is a %s guide; only a model check guide records the commit it was"
             " last checked against" % (area["guide"], guide["kind"]))
    commit = guide["last_checked"]["commit"]
    if commit is None:
        fail("guide-stale", "%s has never been checked (Last checked says never): run its model check" % area["guide"])
    known = subprocess.run(["git", "-C", repo, "cat-file", "-e", commit + "^{commit}"],
                           capture_output=True, text=True, timeout=60)
    if known.returncode != 0:
        fail("commit-missing", "%s was last checked against %s, which this checkout does not hold: fetch it,"
             " or run the model check again" % (area["guide"], commit))
    diff = subprocess.run(["git", "-C", repo, "diff", "--name-only", "-z", commit, "HEAD", "--"],
                          capture_output=True, timeout=120)
    if diff.returncode != 0:
        fail("git-failed", "git diff %s HEAD failed in %s: %s"
             % (commit[:7], repo, first_line(diff.stderr.decode("utf-8", "replace"))))
    paths = [x for x in diff.stdout.decode("utf-8", "strict").split("\0") if x]
    changed = sorted(x for x in paths if any(glob_matches(g, x) for g in area["owns"]))
    out = {"area": area_name, "last_checked": commit, "changed": changed}
    if changed:
        print(json.dumps(out, indent=2))
        fail("guide-stale", "%s owns files changed since %s, its last check: %s"
             % (area_name, commit[:7], ", ".join(changed)))
    return out


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
        with open(path, errors="strict") as f:
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


# Keys a reader adds to a record it parsed, never part of what record render wrote.
_READER_KEYS = ("passed", "sha_matches")


def record_digest(rec):
    """The fingerprint of one record as record render wrote it (claude-config#1572).

    Taken over every key the record carries, results, notes and text included, so a comment edited
    after render (a failing check changed to pass, a note rewritten) no longer matches. JSON with
    sorted keys, so the same record parsed back from a comment gives the same fingerprint.
    """
    body = {k: val for k, val in rec.items() if k not in _READER_KEYS}
    text = json.dumps(body, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()  # as render writes it (#1944)


def remember_rendered(receipt_id, records, home=None):
    """Append each rendered record's fingerprint to rendered.jsonl beside its receipt.

    Append only: an area rendered twice (a second run of record render) keeps both, and the merge
    check passes a record matching either, since both were written by render. A write that fails
    is a refusal (render-not-remembered), never a silent skip, or the record would be refused later
    with nobody told why (L10).
    """
    path = os.path.join(receipt_dir(receipt_id, home), "rendered.jsonl")
    lines = "".join(json.dumps({"schema": RENDERED_SCHEMA, "area": r["area"], "digest": record_digest(r),
                                "at": utc_now()}) + "\n" for r in records)
    try:
        with open(path, "a", errors="replace") as f:
            f.write(lines)
    except OSError as e:
        fail("render-not-remembered", "the fingerprint of what was rendered could not be written to %s (%s),"
             " so the merge check would refuse the record: render it again once that is fixed" % (path, e))


def load_rendered(receipt_id, home=None):
    """Every fingerprint record render wrote for this receipt, by area: {area: set of digests}.

    A receipt with no rendered.jsonl had nothing rendered from it, which is an answer ({}), not a
    fault. A line that is not that shape is named, never skipped (L10).
    """
    path = os.path.join(receipt_dir(receipt_id, home), "rendered.jsonl")
    try:
        with open(path, errors="strict") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return {}
    except OSError as e:
        fail("rendered-unreadable", "%s could not be read: %s" % (path, e))
    out = {}
    for n, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except ValueError as e:
            fail("rendered-not-json", "%s line %d is not JSON: %s" % (path, n, e))
        ok = isinstance(obj, dict) and obj.get("schema") == RENDERED_SCHEMA and \
            isinstance(obj.get("area"), str) and isinstance(obj.get("digest"), str)
        if not ok:
            fail("rendered-bad-line", "%s line %d is not a %s line: %r" % (path, n, RENDERED_SCHEMA, line[:200]))
        out.setdefault(obj["area"], set()).add(obj["digest"])
    return out


def load_drives(receipt_id, home=None):
    """Every drive call a run logged, from drives.jsonl beside its receipt (claude-config#1529).

    run_session.py appends one line per call: {at, area, args, exit}. A run with no log made no
    call, which is an answer (no calls), not a fault. A line that is not that shape is named.
    """
    path = os.path.join(receipt_dir(receipt_id, home), "drives.jsonl")
    try:
        with open(path, errors="strict") as f:
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
SLUG_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")


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
        os.write(fd, line.encode("ascii", "strict"))
    finally:
        os.close(fd)


def tally_summary(slug, home=None):
    """{prs: {pr: latest entry}, unreadable_lines: n} for one repository's tally."""
    path = tally_file(slug, home)
    prs, bad = {}, 0
    try:
        # Replaced (#1923): the tally only decides when to ask, and a line a stand in breaks is
        # counted below as unreadable, so one damaged tally does not stop every other repository's.
        with open(path, errors="replace") as f:
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
        with open(_asked_path(slug, home), errors="replace") as f:
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
                with open(tmp, "w", errors="replace") as f:
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
        if guide["kind"] == "model-check":
            # A served run drove no model checker, so a record here would read as a checked model
            # and could satisfy the merge check (#3471). Its result lives in the guide's Last checked.
            p.append(("render-model-check", "area %s has a model check guide, which a served run does not check:"
                      " leave it out of the run and follow SKILL.md's Model check guides steps" % name))
            continue
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
    remember_rendered(rid, records, home)
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
                    # Replaced, not refused (#1923): every agent's transcript is read here, and one
                    # holding a byte that is not UTF-8 is not a reason to stop looking for this one.
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
    # Refused by name rather than replaced (claude-config#1923): what arrives here is a PR body, a
    # comment or a draft that a merge is judged on, so a byte that is not UTF-8 means the text is not
    # what GitHub holds, and judging a stand in for it would decide the merge on text nobody wrote.
    raw = sys.stdin.buffer.read()
    try:
        return raw.decode("utf-8", "strict")
    except UnicodeDecodeError as e:
        fail("stdin-not-utf8", "standard input holds a byte that is not UTF-8 (0x%02x at offset %d), so it is not the text it should be"
             % (raw[e.start], e.start))


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
    if argv[:2] == ["guide", "stale"] and len(argv) in (4, 6):
        if len(argv) == 6 and argv[4] != "--repo":
            return None
        repo = argv[5] if len(argv) == 6 else os.getcwd()
        print(json.dumps(guide_stale(argv[2], argv[3], repo), indent=2))
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
            with open(argv[3], errors="strict") as f:
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
    except UnicodeDecodeError as e:
        # Its files are read strictly and refused here by name (claude-config#1923): an areas file,
        # guide or receipt decides a merge, so it is not judged on a stand in for a byte it holds.
        print("verification: file-not-utf8: a file this reads holds a byte that is not UTF-8 (0x%02x at offset %d)"
              % (e.object[e.start], e.start), file=sys.stderr)
        return 4
    if rc is None:
        print("verification: usage: see the docstring at the top of %s" % os.path.abspath(__file__), file=sys.stderr)
        return 2
    return rc


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main(sys.argv[1:]))
