#!/usr/bin/env python3
"""sleep-report.py: the night's sleep report and the notes it is built from (claude-config#835).

Sleep mode keeps one record for the whole Mac (~/.claude/state/sleep/current.json, phase 1, #840)
and one notes file per sleep beside it, notes/<generation>.jsonl: one JSON object per line, only
ever appended to. The report, the markdown file the record names in `report` (in ~/Downloads), is
DERIVED from the record and the notes, never edited in place, so any session can render it at any
moment and the last render wins with nothing lost (no lock): it is rendered after every note, best
effort, and once more at wake, when it also reads GitHub for what was really done.

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
                                         from GitHub, sessions and claims that went quiet flagged.

Every other phase writes through sleep_note in lib/sleep.sh, never this file's notes directly.

A note is an object with a `kind` (a plain lowercase word); the writer adds `v`, `generation` and,
when the caller gave none, `at` (ms since the epoch, stamped at write time, L37). The kinds the
report knows, and the fields each reads (every other field is kept, and shown nowhere):

  start      power                          written here at /sleep
  claim      repo, issue                    a worker took an issue (phase 5)
  done       repo, issue?, pr?, text        finished; checked against GitHub at wake
  parked     repo, issue, branch?, text     set aside with why (phase 8: 2 hours or 2 attempts)
  failed     repo, issue?, text             could not be done (a refusal, an error)
  question   repo, issue, text              something only Dan can answer; or cwd, questions (a
                                            list), as scope modes notes a refused question (#841)
  save       files, rule                    a save ask before saving held for Dan (#841)
  issue      repo, title, priority?, labels?, text    a proposed issue (nothing is filed overnight)
  lesson     text                           a proposed lesson
  finding    repo?, text                    anything else noticed
  heartbeat  repo?, issue?, usage?          each pass of the overnight driver (phase 8)
  wait       minutes, error?, text?         each rate limit or overload wait (#844)
  usage      usage                          a reading taken at report time
  stopped    text                           a worker that stopped on purpose (queue empty, cap)
  woke, limit  reason?                      how the night ended (written by the scope modes mod)

`by` is the session id that wrote it. `usage` is {costUsd?, rateLimits?: [{kind, percentUsed,
resetsAt?}]}, as $.session.usage() reads it. A note of a kind not listed is shown under Other notes.

Seams for tests: SLEEP_REPORT_NOW_MS stands in for the clock, SLEEP_REPORT_GH_TOTAL_S for the
time GitHub's reads may take together; pmset and gh are found on PATH.
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
ENDED = ("woke", "limit")
TERMINAL = ("done", "parked", "failed")
KNOWN = ("start", "claim", "done", "parked", "failed", "question", "issue", "lesson", "finding",
         "heartbeat", "wait", "usage", "stopped", "save") + ENDED
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
    note["v"] = 1
    note["generation"] = record["generation"]
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


def gh_list(repo, what, since, deadline):
    """Merged PRs or closed issues in a repo since sleep began: (items, None) or (None, why)."""
    left = int(deadline - time.monotonic())
    if left <= 0:
        return None, "the report ran out of its %d seconds for GitHub before reaching it" % GH_TOTAL_S
    field = "mergedAt" if what == "pr" else "closedAt"
    words = ["gh", what, "list", "-R", repo, "--state", "merged" if what == "pr" else "closed",
             "--search", "%s:>=%s" % ("merged" if what == "pr" else "closed", iso(since)),
             "--json", "number,title,url,%s%s" % (field, "" if what == "pr" else ",stateReason"),
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
        elif at >= since:
            out.append(dict(it, at=at))
    return {"items": out, "undated": undated, "full": len(items) >= GH_LIMIT}, None


# ---- the markdown ----

def where(n):
    repo = n.get("repo") or "a repo not named"
    return "%s#%s" % (repo, n["issue"]) if n.get("issue") is not None else repo


def text_of(n):
    t = n.get("text")
    return " ".join(str(t).split()) if t else ""


def build(record, notes, bad, final, now, github):
    since = record["since"]
    ended = [n for n in notes if n["kind"] in ENDED and num(n.get("at"))]
    end_note = ended[-1] if ended else None
    end_at = end_note["at"] if end_note else now
    out = ["# Sleep report, night of %s" % night_title(record.get("night")), ""]

    start = next((n for n in notes if n["kind"] == "start"), None)
    power = start.get("power") if start else None
    cwd = (record.get("startedBy") or {}).get("cwd")
    head = "Started %s%s%s." % (et_when(since), " in %s" % cwd if cwd else "", ", %s" % power if power else "")
    if end_note and end_note["kind"] == "woke":
        head += " Woke at %s." % et_when(end_at)
    elif end_note:
        head += " Ended by itself at %s%s." % (et_when(end_at), ": %s" % end_note["reason"] if end_note.get("reason") else "")
    else:
        head += " Still asleep as of %s; this report is checked against GitHub at wake." % et_when(now)
    out.append(head)
    workers = [w for w in record.get("workers") or [] if isinstance(w, str)]
    if workers:
        out.append("Overnight workers: %d session%s (%s)." % (len(workers), "" if len(workers) == 1 else "s", ", ".join(short(w) for w in workers)))
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
            mine = [n for n in notes if n.get("by") == w and num(n.get("at"))]
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
            if not any(n["kind"] in TERMINAL and (n.get("repo"), n.get("issue")) == key for n in notes):
                look.append("%s, claimed by %s at %s, ended unexpectedly: no done, parked or failed note." % (where(c), short(c.get("by")), et_time(c["at"]) if num(c.get("at")) else "an unknown time"))
        look.extend(github["flags"])
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

    pf = []
    for n in notes:
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
        issues.append("%s: %s%s%s" % (n.get("repo") or "a repo not named", n.get("title") or "(no title)",
                                       " (%s)" % ", ".join(extra) if extra else "", ". %s" % text_of(n) if text_of(n) else ""))
    section("Proposed issues", issues)
    section("Proposed lessons", [text_of(n) for n in notes if n["kind"] == "lesson"])
    section("Saves waiting for you", ["%s, to %s" % (" ".join(str(n.get("rule") or text_of(n) or "(no rule given)").split()),
                                                    ", ".join(str(f) for f in n["files"]) if isinstance(n.get("files"), list) and n["files"] else "a file not named")
                                      for n in notes if n["kind"] == "save"])
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
            rows.append("%s: %s" % (short(w), "last heard %s" % et_time(max(ats)) if ats else "not heard from"))
        section("Workers", rows)
    return "\n".join(out).rstrip() + "\n"


def github_done(record, notes):
    since = record["since"]
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
    for repo in repos:
        prs, why_p = gh_list(repo, "pr", since, deadline)
        issues, why_i = gh_list(repo, "issue", since, deadline)
        noted = [n for n in notes if n["kind"] == "done" and n.get("repo") == repo]
        for why in [w for w in (why_p, why_i) if w]:
            flags.append("Done could not be read from GitHub for %s: %s.%s" % (repo, why, " What its sessions noted as done is under Done, unchecked." if noted else ""))
        # A note is unchecked only when the list that would check it failed: a PR note by the PR
        # list, an issue only note by the issue list, so the list that answered never repeats it.
        done.extend("%s%s: %s (as noted, unchecked)" % (where(n), ", PR #%s" % n["pr"] if n.get("pr") is not None else "", text_of(n))
                    for n in noted if (why_p if n.get("pr") is not None else why_i))
        asked = set()
        if prs:
            if prs["full"]:
                flags.append("GitHub returned %d merged PRs for %s, the most asked for, so some may be missing." % (GH_LIMIT, repo))
            for p in prs["undated"]:
                flags.append("%s PR #%d came back from GitHub with no merge time that could be read (%s), so whether it was merged tonight is unchecked." % (repo, p["number"], json.dumps(p.get("mergedAt"))))
            merged = {p["number"] for p in prs["items"] + prs["undated"]}
            for p in sorted(prs["items"], key=lambda p: p["at"]):
                done.append("%s PR #%d %s, merged %s" % (repo, p["number"], p.get("title") or "", et_time(p["at"])))
                if (repo, p["number"]) not in noted_prs:
                    flags.append("%s PR #%d merged with no session noting it." % (repo, p["number"]))
            for n in notes:
                if n["kind"] == "done" and n.get("repo") == repo and n.get("pr") is not None and n["pr"] not in merged and ("pr", n["pr"]) not in asked:
                    asked.add(("pr", n["pr"]))
                    confirm(repo, "pr", n["pr"], since, deadline, done, flags)
        if issues:
            if issues["full"]:
                flags.append("GitHub returned %d closed issues for %s, the most asked for, so some may be missing." % (GH_LIMIT, repo))
            for i in issues["undated"]:
                flags.append("%s issue #%d came back from GitHub with no close time that could be read (%s), so whether it was closed tonight is unchecked." % (repo, i["number"], json.dumps(i.get("closedAt"))))
            closed = {i["number"] for i in issues["items"] + issues["undated"]}
            for i in sorted(issues["items"], key=lambda i: i["at"]):
                reason = i.get("stateReason")
                done.append("%s issue #%d %s, closed %s%s" % (repo, i["number"], i.get("title") or "", et_time(i["at"]),
                                                             " as not planned" if reason == "NOT_PLANNED" else ""))
                if (repo, i["number"]) not in noted_issues:
                    flags.append("%s issue #%d closed with no session noting it." % (repo, i["number"]))
            for n in notes:
                if n["kind"] == "done" and n.get("repo") == repo and n.get("pr") is None and n.get("issue") is not None and n["issue"] not in closed and ("issue", n["issue"]) not in asked:
                    asked.add(("issue", n["issue"]))
                    confirm(repo, "issue", n["issue"], since, deadline, done, flags)
    return {"done": done, "flags": flags}


def confirm(repo, what, number, since, deadline, done, flags):
    """A noted done the search did not return is read by its number before it is called wrong: a
    search answers from an index that can lag (L1014, L119)."""
    field = "mergedAt" if what == "pr" else "closedAt"
    verb = "merged" if what == "pr" else "closed"
    label = "PR" if what == "pr" else "issue"
    left = int(deadline - time.monotonic())
    why = None
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
                if at is not None and at >= since:
                    done.append("%s %s #%s %s, %s %s (found by its number; GitHub's search had not listed it)" % (repo, label, number, j.get("title") or "", verb, et_time(at)))
                    return
        except subprocess.TimeoutExpired:
            why = "gh did not answer within %d seconds" % min(GH_TIMEOUT_S, left)
        except (OSError, ValueError) as e:
            why = "gh could not be read (%s)" % e
    if why:
        flags.append("%s %s #%s was noted done, and GitHub could not confirm it: %s." % (repo, label, number, why))
    else:
        flags.append("%s %s #%s was noted done, but GitHub does not show it %s since sleep began." % (repo, label, number, verb))


def render(record_path, record, final):
    notes, bad = read_notes(notes_path(record_path, record))
    now = now_ms()
    github = github_done(record, notes) if final else {"done": [], "flags": []}
    text = build(record, notes, bad, final, now, github)
    dest = record["report"]
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
