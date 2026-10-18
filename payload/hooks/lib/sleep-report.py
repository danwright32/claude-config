#!/usr/bin/env python3
"""sleep-report.py: the night's sleep report and the notes it is built from (claude-config#835).

Sleep mode keeps one record for the whole Mac (~/.claude/state/sleep/current.json, phase 1, #840)
and one notes file per sleep beside it, notes/<generation>.jsonl: one JSON object per line, only
ever appended to. The report, the markdown file the record names in `report` (in ~/Downloads), is
DERIVED from the record and the notes, never edited in place, so any session can render it at any
moment: the append is lockless, and renders take turns under a short lock with a deadline, so the
last to render read every note before it (#909). It is rendered after every note, best
effort, and once more at wake, when it also reads GitHub for what was really done.

Since #1287 (Dan, 2026-10-17: "One file per session. Even if multiple sessions are working on the
same project.") a record carrying `reportsPerSession` gets one report per session with news instead:
each session names its own file in reports/<generation>/<session>.path beside the notes, and every
render writes each, the session's own notes with the whole Mac's kinds (MAC_WIDE: the start and end,
the overnight check, limits and usage) and the sessions gone quiet, read from every note. A record
without it keeps the one report its `report` names.

Whether the Mac is asleep is never judged here. That is the one predicate in lib/sleep.sh and
mods/scope-modes/hooks/sleep.ts; this script is handed a record and writes for it. Its callers:

  start   --record PATH --by SESSION     at /sleep: a start note naming the power state, then the
                                         report, so it exists from the first minute (L10). A report
                                         that cannot be written fails, said.
  note    --record PATH --line JSON      one note, appended in one write in append mode, then the
                                         report again best effort. The note is the record of what
                                         happened, so a render failure after it is said on stderr
                                         and still exits 0, so nobody writes the note twice.
  render  --record PATH [--final]        the report again. --final is the wake render: done read
                                         from GitHub between sleep's start and its end (the woke or
                                         limit note; with neither, the render's own moment, never
                                         past the record's until, #1167), sessions and claims that
                                         went quiet flagged.

Every other phase writes through sleep_note in lib/sleep.sh, never this file's notes directly.

A note is an object with a `kind` (a plain lowercase word); the writer adds `v`, `generation` and,
when the caller gave none, `at` (ms since the epoch, stamped at write time, L37). The kinds the
report knows, and the fields each reads (every other field is kept, and shown nowhere):

  start      power                          written here at /sleep
  claim      repo, issue, attempts          a worker took an issue (phase 5; written by sleep-queue.sh)
  released   repo, issue, state, text?      a claim given back, free or unstarted (sleep-queue.sh)
  done       repo, issue?, pr?, text        finished; checked against GitHub at wake
  parked     repo, issue, branch?, text     set aside with why (phase 8: 2 hours or 2 attempts)
  failed     repo, issue?, text             could not be done (a refusal, an error)
  question   repo, issue, text              something only Dan can answer; or cwd, questions (a
                                            list), as scope modes notes a refused question (#841)
  save       files, rule                    a save ask before saving held for Dan (#841)
  issue      repo, title, priority?, labels?, milestone?, text
                                            a proposed issue (nothing is filed overnight): priority
                                            p0 to p4, labels a list; offered at wake in the end of
                                            turn review's picker with all three (#837)
  lesson     text                           a proposed lesson, the rule word for word: offered
                                            at wake in the durable lesson picker (#837)
  finding    repo?, text                    anything else noticed
  progress   text                           a step done toward a goal that names no issue, which
                                            has no claim whose commits could show it (#1242)
  heartbeat  repo?, issue?, usage?          each pass of the overnight driver (phase 8)
  wait       minutes, error?, text?         each rate limit or overload wait (#844)
  usage      usage                          a reading taken at report time
  stopped    text                           a worker that stopped on purpose (queue empty, cap)
  woke, limit  reason?                      how the night ended (written by the scope modes mod)
  outward    text                           the overnight check (#834): something done overnight
                                            that the ban list exists to stop, read from GitHub
  unmeasured text                           the overnight check: a read it could not make

`by` is the session id that wrote it, stamped by the writer when the caller gave none from the
local session id (CLAUDE_CODE_SESSION_ID), the id the record names its workers by (#1167). `link`, stamped by the writer when the caller gave none, is
the claude.ai session link of the session writing it (CLAUDE_CODE_BRIDGE_SESSION_ID), so what that
session's subagents merge is credited to it at wake (#1159). `usage` is {costUsd?, rateLimits?:
[{kind, percentUsed, resetsAt?}]}, as $.session.usage() reads it. A note of a kind not listed is shown under Other notes.

Seams for tests: SLEEP_REPORT_NOW_MS stands in for the clock, SLEEP_REPORT_GH_TOTAL_S for the
time GitHub's reads may take together, SLEEP_REPORT_LOCK_S for how long a render waits its turn;
SLEEP_REPORT_PAUSE holds a render between reading the notes and replacing the report until a `go`
file is in that folder, and SLEEP_REPORT_MARKS names a folder each render drops a marker in as it
pauses or waits (#909); pmset and gh are found on PATH.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover: python older than 3.9
    ZoneInfo = None

ET = ZoneInfo("America/New_York") if ZoneInfo else None
SILENT_MS = 30 * 60 * 1000
GH_LIMIT = 200
GH_TIMEOUT_S = 15
# All of GitHub's reads at wake together, inside the 90 seconds the scope modes mod gives the run: wake waits on it.
_total = os.environ.get("SLEEP_REPORT_GH_TOTAL_S", "")
GH_TOTAL_S = int(_total) if _total.isdigit() else 60
KIND = re.compile(r"^[a-z][a-z-]{0,31}$")
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
# A session as a pull request names it (#1159): the claude.ai link the harness ends every body
# with, or the local line lib/claude-session-line.sh writes when there is no link; and a claim's
# own branch, as sleep-queue.sh names it.
SESSION_ID = re.compile(r"^session_[A-Za-z0-9]+$")
SESSION_LINK = re.compile(r"claude\.ai/code/(session_[A-Za-z0-9]+)")
UUID = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
LOCAL_ID = re.compile(r"^%s$" % UUID)
SESSION_LOCAL = re.compile(r"Claude-Session: local (%s)" % UUID)
CLAIM_BRANCH = re.compile(r"^sleep/([1-9][0-9]*)$")
ENDED = ("woke", "limit")
TERMINAL = ("done", "parked", "failed")
KNOWN = ("start", "claim", "released", "done", "parked", "failed", "question", "issue", "lesson", "finding",
         "heartbeat", "wait", "usage", "stopped", "save", "outward", "unmeasured", "progress") + ENDED
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


class Refused(Exception):
    """A request this script will not carry out, said to the caller as itself."""


def now_ms():
    v = os.environ.get("SLEEP_REPORT_NOW_MS", "")
    return int(v) if v.isdigit() else int(time.time() * 1000)


def num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def et(ms):
    if ET is None:
        raise Refused("this python has no zoneinfo, so no time can be given in ET")
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).astimezone(ET)


def et_time(ms):
    """2:14 AM ET"""
    d = et(ms)
    h = d.hour % 12 or 12
    return "%d:%02d %s ET" % (h, d.minute, "AM" if d.hour < 12 else "PM")


def et_when(ms):
    """11:42 PM ET on Wed Oct 7, as the scope modes mod's etWhen says it."""
    d = et(ms)
    return "%s on %s %s %d" % (et_time(ms), DAYS[d.weekday()], MONTHS[d.month - 1], d.day)


def night_title(night):
    try:
        d = datetime.strptime(night, "%Y-%m-%d")
    except (TypeError, ValueError):
        return str(night)
    return "%s %s %d" % (DAYS[d.weekday()], MONTHS[d.month - 1], d.day)


def short(sid):
    return str(sid)[:8] if sid else "a session that did not say"


def minutes(ms):
    m = int(round(ms / 60000))
    if m < 120:
        return "%d minute%s" % (m, "" if m == 1 else "s")
    return "%dh %02dm" % (m // 60, m % 60)


def iso(ms):
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s):
    """Any ISO 8601 time with a zone (Z, an offset, fractional seconds); None for anything else."""
    if not isinstance(s, str):
        return None
    try:
        d = datetime.fromisoformat(s[:-1] + "+00:00" if s.endswith("Z") else s)
    except ValueError:
        return None
    return int(d.timestamp() * 1000) if d.tzinfo is not None else None


# ---- the record and the notes ----

def load_record(path):
    try:
        with open(path) as fh:
            r = json.load(fh)
    except OSError as e:
        raise Refused("the sleep record could not be read (%s)" % e)
    except ValueError:
        raise Refused("the sleep record is not JSON")
    if not isinstance(r, dict):
        raise Refused("the sleep record is not a record")
    missing = [k for k, ok in (("generation", isinstance(r.get("generation"), str) and r.get("generation")),
                               ("since", num(r.get("since"))),
                               ("report", isinstance(r.get("report"), str) and r.get("report")))
               if not ok]
    if missing:
        raise Refused("the sleep record has no %s, so no report can be written for it" % ", no ".join(missing))
    return r


def notes_path(record_path, record):
    d = os.path.dirname(os.path.abspath(record_path))
    if os.path.basename(d) == "ended":
        d = os.path.dirname(d)
    return os.path.join(d, "notes", re.sub(r"[^\w.-]", "_", record["generation"]) + ".jsonl")


def read_notes(path):
    """The notes in the order written, and how many lines could not be read (counted, never dropped silently)."""
    notes, bad = [], 0
    try:
        with open(path) as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        return notes, bad
    for line in lines:
        if not line.strip():
            continue
        try:
            j = json.loads(line)
        except ValueError:
            bad += 1
            continue
        if isinstance(j, dict) and isinstance(j.get("kind"), str):
            # A number field holding a list or object (written before the writer refused one) is
            # kept as its text, so it is flagged as not a number rather than breaking the report.
            for k in ("pr", "issue", "repo"):
                if isinstance(j.get(k), (list, dict)):
                    j[k] = json.dumps(j[k])
            notes.append(j)
        else:
            bad += 1
    return notes, bad


def append_note(record_path, record, line):
    try:
        note = json.loads(line)
    except ValueError:
        raise Refused("the note is not JSON")
    if not isinstance(note, dict):
        raise Refused("the note is not an object")
    kind = note.get("kind")
    if not isinstance(kind, str) or not KIND.match(kind):
        raise Refused("the note's kind must be a plain lowercase word, got %s" % json.dumps(kind))
    for k in ("pr", "issue"):
        v = note.get(k)
        if v is not None and (isinstance(v, bool) or not isinstance(v, int) or v <= 0):
            raise Refused("the note's %s must be a number, got %s" % (k, json.dumps(v)))
    if note.get("repo") is not None and not isinstance(note["repo"], str):
        raise Refused("the note's repo must be owner/name text, got %s" % json.dumps(note["repo"]))
    note["v"] = 1
    note["generation"] = record["generation"]
    # The claude.ai link of the session writing the note, from the environment Claude Code gives its
    # tool calls (as lib/claude-session-line.sh reads it): its subagents' pull requests carry the
    # same link in their bodies, so at wake what they merged is credited to this session (#1159).
    bridge = os.environ.get("CLAUDE_CODE_BRIDGE_SESSION_ID", "")
    if note.get("link") is None and SESSION_ID.match(bridge):
        note["link"] = bridge
    # And its local id as `by`, the id the record names its workers by, when the caller gave none,
    # so a worker whose notes named nobody is still heard from (#1167). A `by` the caller gave is
    # never replaced, and a value not of a local id's shape is never stamped.
    local = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if note.get("by") is None and LOCAL_ID.match(local):
        note["by"] = local
    if note.get("at") is None:
        note["at"] = now_ms()
    elif not (num(note["at"]) and 0 <= note["at"] < 1e14):
        # A time no clock gives would break every later render of the night, so it is refused here.
        raise Refused("the note's at must be ms since the epoch, got %s" % json.dumps(note["at"]))
    data = (json.dumps(note, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
    path = notes_path(record_path, record)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # One write in append mode: every writer's line lands whole after the others, with no lock.
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        if os.write(fd, data) != len(data):
            raise Refused("the note was cut short while being written to %s" % path)
    finally:
        os.close(fd)
    return note


# ---- what the night did, read outside the notes ----

def read_power():
    try:
        p = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as e:
        return "power unknown (%s)" % e
    if p.returncode != 0:
        return "power unknown (%s)" % ((p.stderr or p.stdout).strip() or "pmset exited %d" % p.returncode)
    if "'AC Power'" in p.stdout:
        return "on AC power"
    if "'Battery Power'" in p.stdout:
        m = re.search(r"(\d+)%", p.stdout)
        return "on battery (%s%%)" % m.group(1) if m else "on battery"
    first = p.stdout.strip().splitlines()[0] if p.stdout.strip() else "pmset said nothing"
    return "power unknown (%s)" % first


def night_end(record, notes, now):
    """When the night ended, as (ms, the note that says so or None), the one bound every reading of
    the night ends at (#1167): the woke or limit note; with neither, this moment, but never past the
    record's until, when the night ends by itself. Without it a render after wake took the day's
    merges for the night's (PR #1127, merged 8:32 AM ET after wake, listed under the night of
    2026-10-12)."""
    ended = [n for n in notes if n["kind"] in ENDED and num(n.get("at"))]
    if ended:
        return ended[-1]["at"], ended[-1]
    until = record.get("until")
    return (min(now, until) if num(until) else now), None


def gh_list(repo, what, since, until, deadline):
    """Merged PRs or closed issues in a repo between sleep's start and the night's end:
    (items, None) or (None, why)."""
    left = int(deadline - time.monotonic())
    if left <= 0:
        return None, "the report ran out of its %d seconds for GitHub before reaching it" % GH_TOTAL_S
    field = "mergedAt" if what == "pr" else "closedAt"
    words = ["gh", what, "list", "-R", repo, "--state", "merged" if what == "pr" else "closed",
             # Whole seconds, the end rounded up so the search never cuts inside the bound's own
             # second; the bound itself is applied to the millisecond below.
             "--search", "%s:%s..%s" % ("merged" if what == "pr" else "closed", iso(since), iso(until + 999)),
             # What ties each to a session (#1159): a PR's branch, body and the issues it closes; the
             # PRs that closed an issue.
             "--json", "number,title,url,%s,%s" % (field, "headRefName,body,closingIssuesReferences" if what == "pr"
                                                  else "stateReason,closedByPullRequestsReferences"),
             "--limit", str(GH_LIMIT)]
    try:
        p = subprocess.run(words, capture_output=True, text=True, timeout=min(GH_TIMEOUT_S, left))
    except subprocess.TimeoutExpired:
        return None, "gh did not answer within %d seconds" % min(GH_TIMEOUT_S, left)
    except OSError as e:
        return None, "gh could not be run (%s)" % e
    if p.returncode != 0:
        return None, (p.stderr.strip() or p.stdout.strip() or "gh exited %d" % p.returncode).splitlines()[0][:300]
    try:
        items = json.loads(p.stdout)
    except ValueError:
        return None, "gh answered with something that is not JSON"
    if not isinstance(items, list):
        return None, "gh answered with something that is not a list"
    out, undated = [], []
    for it in items:
        if not isinstance(it, dict) or not isinstance(it.get("number"), int):
            return None, "gh answered with an item that has no number"
        at = parse_iso(it.get(field))
        # The search narrows; the predicate is applied here too (L1014). One whose time cannot be
        # read is kept and said, never dropped (L215).
        if at is None:
            undated.append(it)
        elif since <= at <= until:
            out.append(dict(it, at=at))
    return {"items": out, "undated": undated, "full": len(items) >= GH_LIMIT}, None


# ---- the markdown ----

def where(n):
    repo = n.get("repo") or "a repo not named"
    return "%s#%s" % (repo, n["issue"]) if n.get("issue") is not None else repo


def text_of(n):
    t = n.get("text")
    return " ".join(str(t).split()) if t else ""


def build(record, notes, bad, final, now, github, session=None, all_notes=None):
    """The report. `session`, since #1287, is the one session it covers: `notes` are then its own
    with the whole Mac's kinds, and `all_notes` every note, read for which sessions went quiet."""
    every = notes if all_notes is None else all_notes
    since = record["since"]
    end_at, end_note = night_end(record, notes, now)
    if final and not end_note and num(github.get("until")):
        end_at = github["until"]  # the bound GitHub was read to, so the header names the same one
    out = ["# Sleep report, night of %s" % night_title(record.get("night")), ""]
    if session:
        out[1:1] = ["", "This report covers session %s; every other session with news overnight has a report of its own." % short(session)]

    start = next((n for n in notes if n["kind"] == "start"), None)
    power = start.get("power") if start else None
    cwd = (record.get("startedBy") or {}).get("cwd")
    head = "Started %s%s%s." % (et_when(since), " in %s" % cwd if cwd else "", ", %s" % power if power else "")
    if end_note and end_note["kind"] == "woke":
        head += " Woke at %s." % et_when(end_at)
    elif end_note:
        head += " Ended by itself at %s%s." % (et_when(end_at), ": %s" % end_note["reason"] if end_note.get("reason") else "")
    elif not final and end_at == now:
        head += " Still asleep as of %s; this report is checked against GitHub at wake." % et_when(now)
    else:
        # Rendered at wake when the woke note could not be written, or past the record's until.
        head += " No woke or limit note was written, so the night is read up to %s." % et_when(end_at)
    out.append(head)
    workers = [w for w in record.get("workers") or [] if isinstance(w, str)]
    # Each worker's goal (#1242): sleep mode works only a goal Dan set, and a worker without one does
    # no work. A record from before goals were kept has no goals at all and says nothing about them.
    kept = record.get("goals") if isinstance(record.get("goals"), dict) else None
    goals = {w: " ".join(str(g).split()) for w, g in (kept or {}).items() if isinstance(g, str) and g.strip()}
    idle = [w for w in workers if kept is not None and w not in goals]
    if workers:
        out.append("Overnight workers: %d session%s (%s)." % (len(workers), "" if len(workers) == 1 else "s", ", ".join(short(w) for w in workers)))
        if idle:
            out.append("No goal was set for %d session%s (%s), so %s no work tonight." % (
                len(idle), "" if len(idle) == 1 else "s", ", ".join(short(w) for w in idle), "it did" if len(idle) == 1 else "they did"))
    else:
        out.append("No session was enrolled to work overnight.")
    out.append("")

    def section(title, rows, empty=None):
        if not rows and empty is None:
            return
        out.append("## %s" % title)
        out.append("")
        out.extend(["- %s" % r for r in rows] if rows else [empty])
        out.append("")

    # What needs a look comes first (L609), and on a good night says so (L610).
    look = []
    if final:
        for w in workers:
            mine = [n for n in every if n.get("by") == w and num(n.get("at"))]
            # A worker with no goal had nothing to do, so its silence is expected, said in the header.
            if w in idle and not mine:
                continue
            if not mine:
                look.append("Session %s ended unexpectedly: it never wrote a note." % short(w))
                continue
            if any(n["kind"] == "stopped" for n in mine):
                continue
            last = max(n["at"] for n in mine)
            if end_at - last > SILENT_MS:
                look.append("Session %s ended unexpectedly: last heard %s, %s before the end, and it never said it stopped." % (short(w), et_time(last), minutes(end_at - last)))
        for c in [n for n in notes if n["kind"] == "claim"]:
            key = (c.get("repo"), c.get("issue"))
            if any(n["kind"] in TERMINAL and (n.get("repo"), n.get("issue")) == key for n in notes):
                continue
            # A claim given back (released free, or unstarted) and not ended by a later claim is
            # said as given back, never as ended unexpectedly: the queue wrote that it let go (#844).
            # Ordered by when each was written (at), file order breaking a tie, never file order
            # alone: concurrent writers land out of order (L751).
            events = sorted(((n["at"], i, n) for i, n in enumerate(notes)
                             if n["kind"] in ("claim", "released") and (n.get("repo"), n.get("issue")) == key and num(n.get("at"))),
                            key=lambda x: (x[0], x[1]))
            mine = next((k for k, (_, _, n) in enumerate(events) if n is c), None)
            later = [n for _, _, n in events[mine + 1:]] if mine is not None else []
            back = [n for n in later if n["kind"] == "released"]
            if any(n["kind"] == "claim" for n in later):
                continue  # a later claim of the same issue is judged on its own
            if back:
                b = back[-1]
                look.append("%s was given back by %s at %s%s and was not finished tonight." % (
                    where(c), short(b.get("by")), et_time(b["at"]), ": %s" % text_of(b) if text_of(b) else ""))
                continue
            look.append("%s, claimed by %s at %s, ended unexpectedly: no done, parked or failed note." % (where(c), short(c.get("by")), et_time(c["at"]) if num(c.get("at")) else "an unknown time"))
        look.extend(github["flags"])
    # The overnight check (#834) leads: what a text match could not stop, read from the real state.
    look[:0] = ["Done overnight, check it: %s" % text_of(n) for n in notes if n["kind"] == "outward"] + \
               ["Not checked overnight: %s" % text_of(n) for n in notes if n["kind"] == "unmeasured"]
    if bad:
        look.append("%d line%s of the notes could not be read." % (bad, "" if bad == 1 else "s"))
    if final or look:
        section("Needs a look", look, "Nothing needs a look.")

    qs = []
    for n in [n for n in notes if n["kind"] == "question"]:
        # Where it was asked: the repo and issue a worker named, else the folder the mod noted (#841).
        at = where(n) if n.get("repo") else (n.get("cwd") or "a session that did not say where")
        asked = [" ".join(str(q).split()) for q in n["questions"]] if isinstance(n.get("questions"), list) else []
        qs.extend("%s: %s" % (at, q) for q in (asked or [text_of(n)]))
    section("Questions for you", qs)

    if final:
        section("Done", github["done"], "Nothing was merged or closed in a repo worked tonight.")
    else:
        done = ["%s%s: %s" % (where(n), ", PR #%s" % n["pr"] if n.get("pr") is not None else "", text_of(n)) for n in notes if n["kind"] == "done"]
        if done:
            done.insert(0, "As the sessions noted it; checked against GitHub at wake.")
        section("Done", done)

    # A park or a failure the queue replaced is not one (#1119): it lets the holder's done land over
    # the driver's own end once a merged pull request closed the issue, and that done note says so
    # (`replaces`, by the same session, written after it). Only that one: a plain done after
    # another session's failure leaves the failure listed (lessons review of 162acef). Ordered by
    # when each was written, file order breaking a tie, as the claims above are.
    def replaced(i, n):
        key = (n.get("repo"), n.get("issue"), n.get("by"))
        if n.get("issue") is None or not num(n.get("at")):
            return False
        return any(d["kind"] == "done" and d.get("replaces") == n["kind"] and (d.get("repo"), d.get("issue"), d.get("by")) == key
                   and num(d.get("at")) and (d["at"], j) > (n["at"], i) for j, d in enumerate(notes))
    pf = []
    for i, n in enumerate(notes):
        if n["kind"] in ("parked", "failed") and replaced(i, n):
            continue
        if n["kind"] == "parked":
            pf.append("Parked %s%s: %s" % (where(n), " (branch %s)" % n["branch"] if n.get("branch") else "", text_of(n)))
        elif n["kind"] == "failed":
            pf.append("Failed %s: %s" % (where(n), text_of(n)))
    section("Parked and failed", pf)

    issues = []
    for n in [n for n in notes if n["kind"] == "issue"]:
        extra = [str(n["priority"])] if n.get("priority") else []
        if isinstance(n.get("labels"), list):
            extra += [str(x) for x in n["labels"]]
        if n.get("milestone"):
            extra.append("milestone %s" % n["milestone"])
        issues.append("%s: %s%s%s" % (n.get("repo") or "a repo not named", n.get("title") or "(no title)",
                                       " (%s)" % ", ".join(extra) if extra else "", ". %s" % text_of(n) if text_of(n) else ""))
    section("Proposed issues", issues)
    section("Proposed lessons", [text_of(n) for n in notes if n["kind"] == "lesson"])
    section("Saves waiting for you", ["%s, to %s" % (" ".join(str(n.get("rule") or text_of(n) or "(no rule given)").split()),
                                                    ", ".join(str(f) for f in n["files"]) if isinstance(n.get("files"), list) and n["files"] else "a file not named")
                                      for n in notes if n["kind"] == "save"])
    section("Progress toward goals", ["%s: %s" % (short(n.get("by")), text_of(n)) for n in notes if n["kind"] == "progress"])
    section("Findings", ["%s%s" % ("%s: " % n["repo"] if n.get("repo") else "", text_of(n)) for n in notes if n["kind"] == "finding"])

    limits = []
    for n in notes:
        if n["kind"] == "wait":
            m = n.get("minutes")
            limits.append("Waited %s from %s%s, %s%s" % (
                "%g minute%s" % (m, "" if m == 1 else "s") if num(m) else "an unrecorded time",
                et_time(n["at"]) if num(n.get("at")) else "an unknown time",
                " (%s)" % n["error"] if n.get("error") else "", short(n.get("by")),
                ": %s" % text_of(n) if text_of(n) else ""))
    latest = {}
    peak = {}
    for n in notes:
        u = n.get("usage")
        if not isinstance(u, dict) or not num(n.get("at")):
            continue
        # The latest by when it was read, never by file order: concurrent writers land out of order (L751).
        if num(u.get("costUsd")) and (n.get("by") not in latest or n["at"] >= latest[n.get("by")][0]):
            latest[n.get("by")] = (n["at"], u["costUsd"])
        for rl in u.get("rateLimits") or []:
            if isinstance(rl, dict) and isinstance(rl.get("kind"), str) and num(rl.get("percentUsed")):
                k = rl["kind"]
                if k not in peak or rl["percentUsed"] > peak[k][0]:
                    peak[k] = (rl["percentUsed"], n.get("by"), n["at"])
    if latest:
        total = sum(c for _, c in latest.values())
        last = max(a for a, _ in latest.values())
        limits.append("Paid usage: $%.2f, as /cost totals it, summed over each session's latest reading (%d session%s, last read %s)." % (
            total, len(latest), "" if len(latest) == 1 else "s", et_time(last)))
    else:
        limits.append("Paid usage: not measurable, since no session reported a cost reading.")
    names = {"five_hour": "5 hour limit", "seven_day": "Weekly limit", "spend_limit": "Spend limit"}
    for k in sorted(peak, key=lambda k: list(names).index(k) if k in names else 99):
        pct, by, at = peak[k]
        limits.append("%s: %s %s%% (%s at %s)." % (names.get(k, k), "reached" if pct >= 100 else "highest", ("%g" % pct), short(by), et_time(at)))
    section("Limits and usage", limits)

    other = ["%s from %s: %s" % (n["kind"], short(n.get("by")), text_of(n) or json.dumps({k: v for k, v in n.items() if k not in ("v", "generation", "kind", "by", "at")}, ensure_ascii=False))
             for n in notes if n["kind"] not in KNOWN]
    section("Other notes", other)

    if workers:
        rows = []
        for w in workers:
            ats = [n["at"] for n in notes if n.get("by") == w and num(n.get("at"))]
            goal = 'goal "%s", ' % goals[w] if w in goals else ""
            rows.append("%s: %s%s" % (short(w), goal, "last heard %s" % et_time(max(ats)) if ats else "not heard from"))
        section("Workers", rows)
    return "\n".join(out).rstrip() + "\n"


# ---- whose merges and closes they were (#1159) ----
# On 2026-10-12 the one overnight session's subagents merged 11 PRs and closed 21 issues, and every
# one was listed as merged or closed "with no session noting it": 32 lines of noise that hid what
# really needed a look. A subagent writes no note, but what it merges carries its session: the
# session link the harness ends every PR body with (the parent's, the same one append_note stamps on
# the parent's notes), a claim's own branch sleep/N (its reserved worktree's branch), or an issue the
# session claimed that the PR closes. An issue is accounted for when a PR some session accounts for
# closed it. Only what none of these ties to a session that worked tonight is listed.

def refs(items, repo):
    """Each reference GitHub gave (an issue a PR closes, a PR that closed an issue) as (owner/name
    lowercased, number); one naming no repository is in `repo`. Anything else is left out."""
    out = []
    for r in items if isinstance(items, list) else []:
        if not isinstance(r, dict) or isinstance(r.get("number"), bool) or not isinstance(r.get("number"), int):
            continue
        rp = r.get("repository") if isinstance(r.get("repository"), dict) else {}
        owner = rp.get("owner") if isinstance(rp.get("owner"), dict) else {}
        name = "%s/%s" % (owner["login"], rp["name"]) if isinstance(owner.get("login"), str) and isinstance(rp.get("name"), str) else repo
        out.append((name.lower(), r["number"]))
    return out


def tonight(record, notes):
    """Who worked tonight: the id of every session that wrote a note or that the record names as a
    worker, each claude.ai link a note carried mapped to the session that wrote it (None when no
    note with it said who), and the session of each claim by (repo lowercased, issue)."""
    ids = {n["by"] for n in notes if isinstance(n.get("by"), str) and n["by"]}
    ids |= {w for w in record.get("workers") or [] if isinstance(w, str) and w}
    links, claims = {}, {}
    for n in notes:
        by = n["by"] if isinstance(n.get("by"), str) and n["by"] else None
        link = n.get("link")
        if isinstance(link, str) and SESSION_ID.match(link) and links.get(link) is None:
            links[link] = by
        if n["kind"] == "claim" and isinstance(n.get("repo"), str) and isinstance(n.get("issue"), int):
            claims.setdefault((n["repo"].lower(), n["issue"]), by)
    return ids, links, claims


def session_name(s):
    """A session as the report names it: a local id by its first 8 characters, a link's id whole."""
    if not s:
        return "a session that did not say"
    return s if SESSION_ID.match(s) else "session %s" % short(s)


def credit(repo, p, who):
    """The session a merged PR no note names belongs to and why, as (session, why); or (None, why
    not) where why not names any session its body names that wrote nothing tonight, else None."""
    ids, links, claims = who
    branch = p.get("headRefName") if isinstance(p.get("headRefName"), str) else ""
    m = CLAIM_BRANCH.match(branch)
    if m and (repo.lower(), int(m.group(1))) in claims:
        return session_name(claims[(repo.lower(), int(m.group(1)))]), "its branch %s, that session's claim" % branch
    body = p.get("body") if isinstance(p.get("body"), str) else ""
    named = list(dict.fromkeys(SESSION_LINK.findall(body)))
    for link in named:
        if link in links:
            return session_name(links[link] or link), "the session link in its body"
    for local in SESSION_LOCAL.findall(body):
        if local in ids:
            return session_name(local), "the session line in its body"
    for key in refs(p.get("closingIssuesReferences"), repo):
        if key in claims:
            return session_name(claims[key]), "it closes %s#%d, which that session claimed" % key
    return None, ("its body names %s, which wrote no note tonight" % " and ".join(named)) if named else None


def github_done(record, notes, now):
    since = record["since"]
    until, end_note = night_end(record, notes, now)
    # How a merge after the bound is said: the night's end when a note says it, else only the bound.
    past = ("after the night ended at %s" if end_note else "after %s, as far as this report reads the night") % et_time(until)
    repos = sorted({n["repo"] for n in notes if isinstance(n.get("repo"), str) and REPO.match(n["repo"])})
    done, flags = [], []
    noted_prs = {(n.get("repo"), n.get("pr")) for n in notes if n.get("pr") is not None}
    noted_issues = {(n.get("repo"), n.get("issue")) for n in notes if n.get("issue") is not None}
    deadline = time.monotonic() + GH_TOTAL_S
    # A done note GitHub cannot check (no repo it can be asked about, or neither a PR nor an issue)
    # is shown as noted and said as unchecked, never dropped.
    for n in notes:
        if n["kind"] != "done":
            continue
        bad_repo = not (isinstance(n.get("repo"), str) and REPO.match(n["repo"]))
        if bad_repo or (n.get("pr") is None and n.get("issue") is None):
            done.append("%s: %s (as noted, unchecked: %s)" % (where(n), text_of(n), "it names no repo GitHub can be asked about" if bad_repo else "it names no PR or issue"))
    # Every repository is read before any is judged: an issue in one can be closed by a PR in another,
    # and whether that PR is accounted for decides the issue (#1159).
    reads = {repo: (gh_list(repo, "pr", since, until, deadline), gh_list(repo, "issue", since, until, deadline)) for repo in repos}
    who = tonight(record, notes)
    credits = {}
    for repo, ((prs, _), _) in reads.items():
        for p in (prs or {}).get("items", []):
            if (repo, p["number"]) not in noted_prs:
                credits[(repo, p["number"])] = credit(repo, p, who)
    # The PRs some session accounts for, by a note or by credit, across every repository read.
    accounted = {(r.lower(), n) for r, n in noted_prs if isinstance(r, str)} | \
                {(r.lower(), n) for (r, n), (s, _) in credits.items() if s}
    for repo in repos:
        (prs, why_p), (issues, why_i) = reads[repo]
        noted = [n for n in notes if n["kind"] == "done" and n.get("repo") == repo]
        unread = unread_line(repo, [(name, why) for name, why in (("PRs", why_p), ("issues", why_i)) if why])
        if unread:
            flags.append(unread + (" What its sessions noted as done is under Done, unchecked." if noted else ""))
        # A note is unchecked only when the list that would check it failed: a PR note by the PR
        # list, an issue only note by the issue list, so the list that answered never repeats it.
        done.extend("%s%s: %s (as noted, unchecked)" % (where(n), ", PR #%s" % n["pr"] if n.get("pr") is not None else "", text_of(n))
                    for n in noted if (n.get("pr") is not None and why_p) or (n.get("pr") is None and n.get("issue") is not None and why_i))
        asked = set()
        if prs:
            if prs["full"]:
                flags.append("GitHub returned %d merged PRs for %s, the most asked for, so some may be missing." % (GH_LIMIT, repo))
            for p in prs["undated"]:
                flags.append("%s PR #%d came back from GitHub with no merge time that could be read (%s), so whether it was merged tonight is unchecked." % (repo, p["number"], json.dumps(p.get("mergedAt"))))
            merged = {p["number"] for p in prs["items"] + prs["undated"]}
            for p in sorted(prs["items"], key=lambda p: p["at"]):
                line = "%s PR #%d %s, merged %s" % (repo, p["number"], p.get("title") or "", et_time(p["at"]))
                if (repo, p["number"]) in credits:
                    s, why = credits[(repo, p["number"])]
                    if s:
                        line += ", under %s (%s)" % (s, why)
                    else:
                        flags.append("%s PR #%d merged with no session accounting for it%s." % (repo, p["number"], " (%s)" % why if why else ""))
                done.append(line)
            for n in notes:
                if n["kind"] == "done" and n.get("repo") == repo and n.get("pr") is not None and n["pr"] not in merged and ("pr", n["pr"]) not in asked:
                    asked.add(("pr", n["pr"]))
                    confirm(repo, "pr", n["pr"], (since, until, past), deadline, done, flags)
        if issues:
            if issues["full"]:
                flags.append("GitHub returned %d closed issues for %s, the most asked for, so some may be missing." % (GH_LIMIT, repo))
            for i in issues["undated"]:
                flags.append("%s issue #%d came back from GitHub with no close time that could be read (%s), so whether it was closed tonight is unchecked." % (repo, i["number"], json.dumps(i.get("closedAt"))))
            closed = {i["number"] for i in issues["items"] + issues["undated"]}
            for i in sorted(issues["items"], key=lambda i: i["at"]):
                reason = i.get("stateReason")
                by = refs(i.get("closedByPullRequestsReferences"), repo)
                closers = " and ".join("PR #%d" % n if r == repo.lower() else "%s PR #%d" % (r, n) for r, n in by)
                done.append("%s issue #%d %s, closed %s%s%s" % (repo, i["number"], i.get("title") or "", et_time(i["at"]),
                                                               " by %s" % closers if closers else "",
                                                               " as not planned" if reason == "NOT_PLANNED" else ""))
                # Closed by a PR some session accounts for is accounted for too (#1159).
                if (repo, i["number"]) not in noted_issues and not any(k in accounted for k in by):
                    flags.append("%s issue #%d closed with no session accounting for it%s." % (repo, i["number"], " (by %s)" % closers if closers else ""))
            for n in notes:
                if n["kind"] == "done" and n.get("repo") == repo and n.get("pr") is None and n.get("issue") is not None and n["issue"] not in closed and ("issue", n["issue"]) not in asked:
                    asked.add(("issue", n["issue"]))
                    confirm(repo, "issue", n["issue"], (since, until, past), deadline, done, flags)
    return {"done": done, "flags": flags, "until": until}


def unread_line(repo, failed):
    """One line for a repository whose reads failed, naming each (#926): a reason shared by both is
    said once, and different reasons are each said beside their read. None when nothing failed."""
    if not failed:
        return None
    names = " and ".join(name for name, _ in failed)
    names = names[0].upper() + names[1:]
    whys = {why for _, why in failed}
    if len(whys) == 1:
        return "%s could not be read from GitHub for %s: %s." % (names, repo, failed[0][1])
    return "%s could not be read from GitHub for %s (%s)." % (names, repo, "; ".join("%s: %s" % f for f in failed))


def confirm(repo, what, number, night, deadline, done, flags):
    """A noted done the search did not return is read by its number before it is called wrong: a
    search answers from an index that can lag (L1014, L119). `night` is (since, until, how a time
    past until is said), the same bound the search used (#1167)."""
    since, until, past = night
    field = "mergedAt" if what == "pr" else "closedAt"
    verb = "merged" if what == "pr" else "closed"
    label = "PR" if what == "pr" else "issue"
    left = int(deadline - time.monotonic())
    why = None
    # Any session can write a note, so only a plain number ever reaches gh's command line.
    if isinstance(number, bool) or not isinstance(number, int) or number <= 0:
        flags.append("%s %s %s was noted done, but that is not a %s number, so GitHub was not asked." % (repo, label, json.dumps(number), label))
        return
    if left <= 0:
        why = "the report ran out of its %d seconds for GitHub" % GH_TOTAL_S
    else:
        try:
            p = subprocess.run(["gh", what, "view", str(number), "-R", repo, "--json", "number,title,%s" % field],
                               capture_output=True, text=True, timeout=min(GH_TIMEOUT_S, left))
            if p.returncode != 0:
                why = (p.stderr.strip() or "gh exited %d" % p.returncode).splitlines()[0][:300]
            else:
                j = json.loads(p.stdout)
                at = parse_iso(j.get(field)) if isinstance(j, dict) else None
                if at is not None and since <= at <= until:
                    done.append("%s %s #%s %s, %s %s (found by its number; GitHub's search had not listed it)" % (repo, label, number, j.get("title") or "", verb, et_time(at)))
                    return
                if at is not None and at > until:
                    # Done, but in the day: never the night's, and never said as not done (L11).
                    flags.append("%s %s #%s was noted done, but GitHub shows it %s %s, %s." % (repo, label, number, verb, et_time(at), past))
                    return
        except subprocess.TimeoutExpired:
            why = "gh did not answer within %d seconds" % min(GH_TIMEOUT_S, left)
        except (OSError, ValueError) as e:
            why = "gh could not be read (%s)" % e
    if why:
        flags.append("%s %s #%s was noted done, and GitHub could not confirm it: %s." % (repo, label, number, why))
    else:
        flags.append("%s %s #%s was noted done, but GitHub does not show it %s since sleep began." % (repo, label, number, verb))


def _mark(name):
    """Test seam (#909): with SLEEP_REPORT_MARKS naming a folder, a render drops a marker there at
    each step a test waits on, so the test waits on the step itself, never a fixed time."""
    d = os.environ.get("SLEEP_REPORT_MARKS", "")
    if d:
        try:
            with open(os.path.join(d, "%s.%d" % (name, os.getpid())), "w"):
                pass
        except OSError:
            pass


def _pause():
    """Test seam (#909): with SLEEP_REPORT_PAUSE naming a folder, a render waits after reading the
    notes and before replacing the report until a `go` file is there (at most 30 seconds), so a test
    can hold one render while another runs, the order that loses a note."""
    d = os.environ.get("SLEEP_REPORT_PAUSE", "")
    if not d:
        return
    _mark("paused")
    deadline = time.monotonic() + 30
    while not os.path.exists(os.path.join(d, "go")) and time.monotonic() < deadline:
        time.sleep(0.02)


# How long a render waits for another to finish; SLEEP_REPORT_LOCK_S stands in for it in tests.
_lock_s = os.environ.get("SLEEP_REPORT_LOCK_S", "")
RENDER_LOCK_S = int(_lock_s) if _lock_s.isdigit() else 15


class RenderLock:
    """One render of a night's report at a time, from reading the notes to replacing the report (#909).

    Appending a note stays lockless; only the render is serialised. A render reads the notes after it
    holds the lock, so the one that takes it last reads every note appended before it, and its report
    is the one left in place: two renders can no longer land out of order and put back a report missing
    the newer note. One that cannot take the lock within RENDER_LOCK_S gives up and says so (its note
    is written, and the render holding the lock, the next note's or wake's carries it, L110). flock is
    let go by the kernel when its holder dies, so a killed render never leaves it held (L409)."""

    def __init__(self, path):
        self.path = path
        self.fd = None

    def __enter__(self):
        import fcntl
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            self.fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | getattr(os, "O_CLOEXEC", 0), 0o600)
        except OSError as e:
            raise Refused("the report's render lock could not be opened at %s (%s)" % (self.path, e.strerror or e))
        deadline = time.monotonic() + RENDER_LOCK_S
        waited = False
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except BlockingIOError:
                if not waited:
                    waited = True
                    _mark("waiting")
                if time.monotonic() >= deadline:
                    os.close(self.fd)
                    self.fd = None
                    raise Refused("another render of this report held it for %d seconds, so this one gave up" % RENDER_LOCK_S)
                time.sleep(0.02)

    def __exit__(self, *exc):
        if self.fd is not None:
            os.close(self.fd)  # closing it lets the flock go
        return False


def render(record_path, record, final):
    path = notes_path(record_path, record)
    github = {"done": [], "flags": []}
    if final:
        # GitHub's reads take up to GH_TOTAL_S, so they run before the lock, never holding every
        # other render behind them; done is read from GitHub, the notes again under the lock.
        github = github_done(record, read_notes(path)[0], now_ms())
    with RenderLock(path[:-len(".jsonl")] + ".render.lock"):
        return _render_locked(path, record, final, github)


def _notes_size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return -1


RERENDERS = 5


def _render_locked(path, record, final, github):
    # Rendered again while the notes have grown since they were read, so a note whose own render
    # gave up waiting for this one is in the report all the same (#909); a few times at most.
    for _ in range(RERENDERS):
        size = _notes_size(path)
        dest = _render_once(path, record, final, github)
        if _notes_size(path) == size:
            break
    return dest


# The kinds every session's report carries whoever wrote them (#1287): how the night began and
# ended, the overnight check, and the limits and usage, which are the whole Mac's, not one session's.
MAC_WIDE = ("start", "woke", "limit", "outward", "unmeasured", "usage", "wait")


def session_reports(notes_file, record):
    """Each session's report on a record written since #1287 (reportsPerSession), {session: where},
    from reports/<generation>/<session>.path beside the notes; None on an older record, which keeps
    the one report its `report` names. A path file that cannot be read is refused, naming the
    session, never read as a session with no news (L215)."""
    if record.get("reportsPerSession") is not True:
        return None
    folder = os.path.join(os.path.dirname(os.path.dirname(notes_file)), "reports", re.sub(r"[^\w.-]", "_", record["generation"]))
    try:
        names = sorted(os.listdir(folder))
    except FileNotFoundError:
        return {}
    except OSError as e:
        raise Refused("the folder of the night's reports could not be read (%s)" % e)
    out = {}
    for name in names:
        if not name.endswith(".path"):
            continue
        try:
            with open(os.path.join(folder, name)) as fh:
                dest = fh.read().strip()
        except OSError as e:
            raise Refused("where session %s's report goes could not be read (%s)" % (name[:-len(".path")], e))
        if dest:
            out[name[:-len(".path")]] = dest
    return out


UNSAFE_NAME = re.compile(r"[/\\:\x00-\x1f\x7f]")


# How long a session has to name its own report, by its title, before this script names it by id:
# its minute runs every 60 seconds, so two leave it room (a chosen limit, not a measurement).
NAMING_GRACE_MS = 2 * 60 * 1000


def fallback_reports(notes_file, record, notes, named, final, now):
    """A report for every session with news (every worker, and any session that wrote a note of its
    own) that has not named its own (#1287): one that died before it could, or never ran its minute.
    Before the night ends only a session whose first note of its own is past NAMING_GRACE_MS, so a
    session's own name, by its title, is never beaten by this one (lessons review); at the end, every
    session with news. Named as the mod names one, by night, the folder its notes give and the first
    8 characters of its id; a name on the disk already (an earlier sleep the same night) takes (2)
    and on. Recorded by linking the name into place, so whichever is first keeps it."""
    folder = os.path.join(os.path.dirname(os.path.dirname(notes_file)), "reports", re.sub(r"[^\w.-]", "_", record["generation"]))
    downloads = os.path.dirname(record["report"])
    own = [n for n in notes if isinstance(n.get("by"), str) and n["by"] and n["kind"] not in MAC_WIDE]
    if final:
        news = [w for w in record.get("workers") or [] if isinstance(w, str) and w] + [n["by"] for n in own]
    else:
        first = {}
        for n in own:
            if num(n.get("at")):
                first[n["by"]] = min(first.get(n["by"], n["at"]), n["at"])
        news = [sid for sid, at in first.items() if now - at >= NAMING_GRACE_MS]
    out = dict(named)
    for sid in dict.fromkeys(news):
        if sid in out:
            continue
        mine = [n for n in notes if n.get("by") == sid]
        # The folder the session works in first, as the mod names a project; a note's repository can
        # be one it only wrote about (a repository closed for the night, say).
        project = next((os.path.basename(n["cwd"].rstrip("/")) for n in mine if isinstance(n.get("cwd"), str) and n["cwd"].strip("/")), None) \
            or next((n["repo"].split("/")[-1] for n in mine if isinstance(n.get("repo"), str) and "/" in n["repo"]), None)
        stem = " ".join(UNSAFE_NAME.sub(" ", "%s %s%s sleep report" % (record.get("night"), "%s " % project if project else "", sid[:8])).split())
        held = set(out.values())
        for k in range(1, 51):
            dest = os.path.join(downloads, "%s%s.md" % (stem, " (%d)" % k if k > 1 else ""))
            if dest not in held and not os.path.exists(dest):
                break
        else:
            raise Refused("no free name was found for session %s's report" % short(sid))
        os.makedirs(folder, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".%s." % sid, suffix=".tmp", dir=folder)
        try:
            with os.fdopen(fd, "w") as fh:
                fh.write(dest)
            os.link(tmp, os.path.join(folder, sid + ".path"))
        except FileExistsError:
            # The session named its own meanwhile: its name stands.
            with open(os.path.join(folder, sid + ".path")) as fh:
                dest = fh.read().strip()
        except OSError as e:
            raise Refused("session %s's report could not be named (%s)" % (short(sid), e))
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        out[sid] = dest
    return out


def scoped(github, repos):
    """GitHub's reading for one session's report: what was done in the repos it worked, and every
    flag, since what could not be checked belongs to the whole night."""
    low = [r.lower() for r in repos]
    # A repo's own lines only: "o/r PR #3" or "o/r#3: ...", never "o/ra" (lessons review).
    done = [d for d in github.get("done", []) if any(d.lower().startswith(r) and d[len(r):len(r) + 1] in (" ", "#", ":") for r in low)]
    return {**github, "done": done}


def _write(dest, text):
    try:
        os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
        # Written whole beside it and moved into place, so a reader never sees half a report.
        fd, tmp = tempfile.mkstemp(prefix=".sleep-report-", suffix=".tmp", dir=os.path.dirname(dest) or ".")
        try:
            with os.fdopen(fd, "w") as fh:
                fh.write(text)
            os.replace(tmp, dest)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    except OSError as e:
        raise Refused("the report could not be written to %s (%s)" % (dest, e))


def _render_once(path, record, final, github):
    notes, bad = read_notes(path)
    now = now_ms()
    dests = session_reports(path, record)
    if dests is not None:
        dests = fallback_reports(path, record, notes, dests, final, now)
        # One report per session with news (#1287): its own notes, with the whole Mac's sections.
        texts = {}
        for sid, dest in dests.items():
            mine = [n for n in notes if n.get("by") == sid or n["kind"] in MAC_WIDE]
            repos = {n["repo"] for n in notes if n.get("by") == sid and isinstance(n.get("repo"), str)}
            texts[dest] = build(record, mine, bad, final, now, scoped(github, repos), session=sid, all_notes=notes)
        _pause()
        for dest, text in texts.items():
            _write(dest, text)
        return "\n".join(texts) if texts else "no session has a report for this night yet"
    text = build(record, notes, bad, final, now, github)
    _pause()
    dest = record["report"]
    _write(dest, text)
    return dest


def main(argv):
    ap = argparse.ArgumentParser(prog="sleep-report.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("start")
    s.add_argument("--record", required=True)
    s.add_argument("--by", required=True)
    n = sub.add_parser("note")
    n.add_argument("--record", required=True)
    n.add_argument("--line", required=True)
    r = sub.add_parser("render")
    r.add_argument("--record", required=True)
    r.add_argument("--final", action="store_true")
    a = ap.parse_args(argv)
    try:
        record = load_record(a.record)
    except Refused as e:
        print(str(e), file=sys.stderr)
        return 2
    try:
        if a.cmd == "start":
            append_note(a.record, record, json.dumps({"kind": "start", "by": a.by, "power": read_power()}))
            print(render(a.record, record, False))
            return 0
        if a.cmd == "note":
            append_note(a.record, record, a.line)
            try:
                render(a.record, record, False)
            except Exception as e:  # any failure at all: the note is written and must not be written twice
                print("the note was written, but the report could not be rendered: %s: %s" % (type(e).__name__, e), file=sys.stderr)
            return 0
        print(render(a.record, record, a.final))
        return 0
    except Refused as e:
        print(str(e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
