#!/usr/bin/env python3
"""A record of every usage limit message on this Mac, with its kind and the reset time it names,
and the reader that prints limit days by kind (claude-config#3308).

    limit-messages.py record      the hook: a StopFailure or SubagentStop payload on stdin
    limit-messages.py scan        the backfill: every transcript under ~/.claude/projects
    limit-messages.py days        the reader: limit days by kind, in ET

WHY. The reading for #3061 counted three kinds of limit as one (the five hour limit, a limit on one
model, a weekly limit), and nothing held each message with the reset time it names, so one
account's cycle could not be told from another's. Dan, 2026-11-19: "Find the missing use first".

WHERE A LIMIT MESSAGE CAN BE SEEN, measured on 2026-11-23 on the personal MacBook:
  * The transcript. Claude Code writes the message as an assistant line with isApiErrorMessage set,
    error "rate_limit" (or "unknown" with apiErrorStatus 429 for the account rate limit), the
    wording as its text, and since about 2.1.311 a structured block, quotaLimits, carrying
    rateLimitType, resetsAt (seconds), overageStatus and overageDisabledReason. 19 such lines
    were found in this Mac's transcripts, main sessions, headless runs and subagents alike.
  * The StopFailure hook. Its payload carries error and last_assistant_message, the wording itself;
    the overnight driver's notes hold that wording, written from this event, on 2026-10-25 and
    2026-11-06, so the event is seen to fire on a usage limit.
  * SubagentStop, for an agent: its own transcript (agent_transcript_path) holds the line.
So the hook reads the transcript the payload names for limit lines not yet recorded, and falls
back to the payload's own wording when the line is not there (it may not be written yet).

WHAT A RECORD HOLDS: when, the kind, the model a model limit names, the reset time and whether it
came from the structured block or the wording, the structured limit type and overage fields, who
was stopped (main, headless or agent from the transcript line, or unknown for a line that names no
entrypoint; "session" for a record made from the hook's own wording, which cannot tell a main
session from a headless run), a cycle key (kind, model and reset time: two different reset
times for one kind at once are two accounts or two cycles), and the account as far as it can be
read. No conversation text, no session id, no email, no project folder.

THE ACCOUNT. A transcript line names no account. The status bar mod records each session's account
at session start in ~/.claude/state/status-bar/<session>.json, and removes it when the session
ends, so a live hook can read it and the backfill mostly cannot. It is kept as the account room
keys it (the first 16 hex digits of SHA-256 over "<account id>:<org id>"), never as a name. Where it
cannot be read the record says so (account null), never a guess from whatever is signed in now.

THE RECORD lives at ~/.claude/state/limit-messages/records.jsonl, local to this Mac and never
synced. Each message is written once, keyed by its transcript line's uuid (a hashed key for one
taken from the hook's wording), under a lock, so a hook that runs twice or races the backfill adds
nothing.

A FAILURE (a payload that is not a JSON object, a transcript that cannot be read, a record that
cannot be written, anything no handler foresaw) is said as the step that had it and kept in failures.jsonl beside the record where that can be written, for the reader to
say, and then told according to sleep mode, as Dan chose on 2026-11-24. Awake, it is one plain line
on stderr and exit 1, never a traceback. Asleep (lib/sleep.sh's sleep_active, the one predicate),
nothing is printed at all: the failure becomes a note for the morning report through sleep_note,
the one writer of the night's notes, and the hook exits 0 once that note is written (1, still
silent, when it could not be). A normal run is the same awake or asleep: silent, and it records.
"""
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover
    ZoneInfo = None

ET = "America/New_York"
KIND_TITLES = [
    ("five_hour", "Five hour limit"),
    ("weekly", "Weekly limit"),
    ("model", "Model limit"),
    ("spend", "Monthly spend limit"),
    ("credits", "Usage credits"),
    ("rate", "Account rate limit"),
    ("other", "Other limit"),
]
MONTHS = {m: i for i, m in enumerate(["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], 1)}
TIME_RE = r"(\d{1,2})(?::(\d{2}))?\s*(am|pm)"
RESET_DATED = re.compile(r"resets\s+([A-Z][a-z]{2})\s+(\d{1,2})\s+at\s+" + TIME_RE + r"\s*\(([^)]+)\)", re.I)
RESET_TIME = re.compile(r"resets\s+" + TIME_RE + r"\s*\(([^)]+)\)", re.I)
MODEL_RE = re.compile(r"hit your ([A-Za-z][\w.]*(?: [\w.]+){0,2}) limit")


def home():
    return os.path.expanduser("~")


def record_dir():
    return os.path.join(home(), ".claude", "state", "limit-messages")


def record_path():
    return os.path.join(record_dir(), "records.jsonl")


def iso(ts):
    return ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_at(s):
    if not isinstance(s, str) or not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def text_of(line):
    c = (line.get("message") or {}).get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return " ".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
    return ""


def kind_of(text, limit_type):
    """The kind, from the wording first (the issue: "the wording tells them apart"), then from the
    structured type. The Fable limit carried seven_day_overage_included, which names no model, so
    the structured type alone cannot tell a model limit from a weekly one."""
    t = text or ""
    low = t.lower()
    if re.search(r"hit your (5-hour|five.hour|session) limit", low):
        return "five_hour", None
    if "hit your weekly limit" in low:
        return "weekly", None
    if "monthly spend limit" in low or "spend limit" in low:
        return "spend", None
    if "usage credits" in low and "hit your" not in low:
        return "credits", None
    if "account's rate limit" in low or "rate limit" in low and "hit your" not in low:
        return "rate", None
    m = MODEL_RE.search(t)
    if m:
        return "model", m.group(1)
    return {"five_hour": ("five_hour", None), "seven_day": ("weekly", None)}.get(limit_type or "", ("other", None))


def is_limit_line(o):
    if not isinstance(o, dict) or not o.get("isApiErrorMessage"):
        return False
    if o.get("error") == "rate_limit" or o.get("apiErrorStatus") == 429 or o.get("quotaLimits"):
        return True
    return is_limit_wording(text_of(o))


def is_limit_wording(t):
    low = (t or "").lower()
    return bool(re.search(r"hit your .{0,40}limit", low)) or "usage credits" in low or "rate limit" in low


def zone(name):
    if ZoneInfo is None:
        return None
    try:
        return ZoneInfo(name)
    except Exception:
        return None


def hour24(h, ampm):
    h = int(h) % 12
    return h + 12 if ampm.lower() == "pm" else h


def reset_from_wording(text, at):
    """The reset time the wording names, read against the message's own time in the zone it names.
    A time alone is the next such time after the message; a date with no year is the next such
    date. None when the wording names none or a zone this Python cannot load."""
    if not text or at is None:
        return None
    m = RESET_DATED.search(text)
    if m:
        mon, day, h, mi, ampm, zname = m.groups()
        tz = zone(zname.strip())
        if tz is None or mon[:3].title() not in MONTHS:
            return None
        local = at.astimezone(tz)
        for year in (local.year, local.year + 1):
            try:
                cand = datetime(year, MONTHS[mon[:3].title()], int(day), hour24(h, ampm), int(mi or 0), tzinfo=tz)
            except ValueError:
                return None
            if cand >= local - timedelta(days=1):
                return cand
        return None
    m = RESET_TIME.search(text)
    if m:
        h, mi, ampm, zname = m.groups()
        tz = zone(zname.strip())
        if tz is None:
            return None
        local = at.astimezone(tz)
        cand = local.replace(hour=hour24(h, ampm), minute=int(mi or 0), second=0, microsecond=0)
        if cand <= local:
            cand = (cand + timedelta(days=1)).replace(hour=hour24(h, ampm), minute=int(mi or 0))
        return cand
    return None


def account_key(session_id):
    """The session's account as the status bar mod recorded it, keyed as the account room keys it.
    None when there is no such record or it names no account."""
    if not isinstance(session_id, str) or not re.fullmatch(r"[A-Za-z0-9-]+", session_id or ""):
        return None
    p = os.path.join(home(), ".claude", "state", "status-bar", session_id + ".json")
    try:
        with open(p, encoding="utf-8", errors="replace") as fh:
            o = json.load(fh)
    except (OSError, ValueError):
        return None
    a = o.get("account") if isinstance(o, dict) and o.get("v") == 1 else None
    if not isinstance(a, dict) or not a.get("accountUuid") or not a.get("organizationUuid"):
        return None
    return hashlib.sha256(("%s:%s" % (a["accountUuid"], a["organizationUuid"])).encode("utf-8", "surrogatepass")).hexdigest()[:16]


def who_of(o):
    if o.get("isSidechain") or o.get("agentId"):
        return "agent"
    ep = o.get("entrypoint") or ""
    if ep.startswith("sdk"):
        return "headless"
    return "main" if ep else "unknown"


def build(at, text, quota, who, session_id, rid, source, error):
    q = quota if isinstance(quota, dict) else {}
    limit_type = q.get("rateLimitType") if isinstance(q.get("rateLimitType"), str) else None
    kind, model = kind_of(text, limit_type)
    resets, frm = None, None
    if isinstance(q.get("resetsAt"), (int, float)) and q["resetsAt"] > 0:
        resets, frm = datetime.fromtimestamp(q["resetsAt"], timezone.utc), "structured"
    else:
        r = reset_from_wording(text, at)
        if r is not None:
            resets, frm = r, "wording"
    acct = account_key(session_id)
    rec = {
        "v": 1,
        "id": rid,
        "at": iso(at),
        "kind": kind,
        "model": model,
        "resets_at": iso(resets) if resets else None,
        "resets_from": frm,
        "limit_type": limit_type,
        "overage": q.get("overageStatus"),
        "overage_reason": q.get("overageDisabledReason"),
        "error": error,
        "who": who,
        "account": acct,
        "account_from": "status bar session record" if acct else None,
        "source": source,
    }
    rec["cycle"] = "%s%s@%s" % (kind, ":" + model if model else "", rec["resets_at"] or "unknown")
    return rec


def from_line(o):
    at = parse_at(o.get("timestamp"))
    if at is None:
        return None
    q = o.get("quotaLimits") or ((o.get("apiErrorParams") or {}).get("rate_limit_info") if isinstance(o.get("apiErrorParams"), dict) else None)
    rid = "line:" + hashlib.sha256(str(o.get("uuid") or (o.get("timestamp"), o.get("sessionId"))).encode("utf-8", "surrogatepass")).hexdigest()[:20]
    return build(at, text_of(o), q, who_of(o), o.get("sessionId"), rid, "transcript", o.get("error"))


def lines_in(path, texts=None):
    """The limit lines in one transcript, as records. Only lines that can be one are parsed. When
    `texts` is a set, each line's wording is added to it, for the hook to see whether the message
    it was handed is in the transcript at all."""
    out = []
    with open(path, "rb") as fh:
        for raw in fh:
            if b"isApiErrorMessage" not in raw:
                continue
            try:
                # Decoded first, so a byte that is not UTF-8 elsewhere on the line costs only that
                # byte, never the whole limit line.
                o = json.loads(raw.decode("utf-8", errors="replace"))
            except ValueError:
                continue
            if is_limit_line(o):
                if texts is not None:
                    texts.add(text_of(o).strip())
                r = from_line(o)
                if r:
                    out.append(r)
    return out


class Store:
    """The record, opened under an exclusive lock for one read and append, so two writers at once
    (a StopFailure and a SubagentStop, or a hook and the backfill) write each message once."""

    def __enter__(self):
        os.makedirs(record_dir(), exist_ok=True)
        self.lock = open(os.path.join(record_dir(), ".lock"), "a", encoding="utf-8", errors="replace")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        self.ids = set()
        try:
            with open(record_path(), encoding="utf-8", errors="replace") as fh:
                for l in fh:
                    try:
                        self.ids.add(json.loads(l).get("id"))
                    except ValueError:
                        continue
        except FileNotFoundError:
            pass
        return self

    def add(self, recs):
        new = [r for r in recs if r["id"] not in self.ids]
        if new:
            with open(record_path(), "a", encoding="utf-8", errors="replace") as fh:
                fh.write("".join(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n" for r in new))
            self.ids.update(r["id"] for r in new)
        return len(new)

    def __exit__(self, *a):
        fcntl.flock(self.lock, fcntl.LOCK_UN)
        self.lock.close()


def note_failure(why):
    try:
        os.makedirs(record_dir(), exist_ok=True)
        with open(os.path.join(record_dir(), "failures.jsonl"), "a", encoding="utf-8", errors="replace") as fh:
            fh.write(json.dumps({"at": iso(datetime.now(timezone.utc)), "why": why}) + "\n")
    except OSError:
        pass


def retry_delays():
    raw = os.environ.get("LIMIT_MESSAGES_RETRY_DELAYS", "0,1,2,4")
    try:
        return [float(x) for x in raw.split(",") if x.strip()]
    except ValueError:
        return [0.0]


# lib/sleep.sh beside this hook: the one sleep predicate (sleep_active) and the one writer of the
# night's notes (sleep_note), asked through bash since both are shell.
SLEEP_SH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "sleep.sh")


def asleep():
    """Whether the Mac is asleep, by lib/sleep.sh's sleep_active. A predicate that cannot be asked
    (sleep.sh missing or failing to load, no bash, a timeout) reads as AWAKE, so a failure is printed
    rather than lost: a line that should not have shown beats a silence nobody can see (L523)."""
    try:
        r = subprocess.run(["bash", "-c", '. "$1" && sleep_active', "_", SLEEP_SH],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode == 0


def note_for_morning(why):
    """The failure as a finding in the night's notes, through sleep_note. True once written. Its
    output is kept from Dan's screen: asleep, the hook prints nothing at all."""
    line = json.dumps({"kind": "finding", "text": "limit-messages: " + why})
    try:
        r = subprocess.run(["bash", "-c", '. "$1" && sleep_note "$2"', "_", SLEEP_SH, line],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode == 0


def failed(why):
    """Every failure of the record hook ends here: kept in failures.jsonl where that can be written,
    then one plain line on stderr while awake, or a note for the morning report and silence while
    asleep."""
    note_failure(why)
    if asleep():
        return 0 if note_for_morning(why) else 1
    print("limit-messages: " + why, file=sys.stderr)
    return 1


def cmd_record():
    try:
        return record_payload()
    except Exception as e:  # anything no handler foresaw: said in one line, never a traceback
        return failed("could not record: it failed unexpectedly (%s: %s)" % (type(e).__name__, " ".join(str(e).split())))


def record_payload():
    try:
        # Read as bytes: a byte that is not UTF-8 anywhere in the payload (the wording, a path)
        # must not cost the record of the limit itself.
        p = json.loads(sys.stdin.buffer.read().decode("utf-8", errors="replace"))
    except ValueError:
        return failed("could not record: the hook payload was not JSON")
    if not isinstance(p, dict):
        return failed("could not record: the hook payload was not a JSON object")
    event = p.get("hook_event_name")
    if event == "SubagentStop":
        path, error, said = p.get("agent_transcript_path"), None, None
    else:
        path, error, said = p.get("transcript_path"), p.get("error"), p.get("last_assistant_message")
        # A StopFailure that is not a limit (an overloaded server, a lost connection) is nothing here.
        if error != "rate_limit" and not is_limit_wording(said):
            return 0
    # Every limit line in the transcript not yet recorded is added, so one this hook missed (a
    # crash, a line written late) is picked up by the next run. The message the hook was handed
    # counts as present once its wording is on a limit line in the transcript. The waits happen
    # outside the lock, so a waiting hook never holds up another writer. Reading the transcript and
    # writing the record are each tried on their own, so a failure is said as the step that had it:
    # a transcript that cannot be read is never blamed on the record folder (claude-config#3567).
    wanted = (said or "").strip()
    for delay in retry_delays() if event != "SubagentStop" else [0.0]:
        if delay:
            time.sleep(delay)
        texts = set()
        try:
            recs = lines_in(path, texts) if isinstance(path, str) and os.path.isfile(path) else []
        except OSError as e:
            return failed("could not read the transcript %s, so any usage limit message in it is not recorded: %s" % (
                path, e.strerror or e))
        bad = store(recs)
        if bad is not None:
            return bad
        if event == "SubagentStop" or (wanted and wanted in texts) or (not wanted and recs):
            break
    else:
        # Not in the transcript after the waits: the hook's own wording stands in for it, with no
        # structured block. If its line is written later, a later run records that too, so this one
        # message can be counted twice; a limit DAY is counted once either way.
        now = datetime.now(timezone.utc)
        rid = "hook:" + hashlib.sha256(("%s|%s|%s" % (p.get("session_id"), said, now.strftime("%Y-%m-%dT%H:%M"))).encode("utf-8", "surrogatepass")).hexdigest()[:20]
        who = "agent" if p.get("agent_id") else "session"
        bad = store([build(now, said or "", None, who, p.get("session_id"), rid, "hook message", error)])
        if bad is not None:
            return bad
    return 0


def store(recs):
    """The records added to the record under its lock. None once written; the failure's exit code
    when the record folder could not be written, said as that folder."""
    try:
        with Store() as st:
            st.add(recs)
    except OSError as e:
        return failed("could not record a usage limit message in %s: %s" % (record_dir(), e))
    return None


def cmd_scan():
    root = os.path.join(home(), ".claude", "projects")
    files = 0
    unread = 0
    recs = []
    if not os.path.isdir(root):
        print("limit-messages: there is no transcript folder at %s to scan." % root, file=sys.stderr)
        return 1
    dirs_unread = []
    for dp, _, fs in os.walk(root, onerror=dirs_unread.append):
        for f in fs:
            if f.endswith(".jsonl"):
                try:
                    recs.extend(lines_in(os.path.join(dp, f)))
                    files += 1
                except OSError:
                    unread += 1
    try:
        with Store() as st:
            new = st.add(recs)
    except OSError as e:
        print("limit-messages: could not record the backfill in %s: %s" % (record_dir(), e), file=sys.stderr)
        return 1
    print("Scanned %d transcripts: %d usage limit messages, %d new to the record." % (files, len(recs), new))
    # A backfill that missed files or folders must not read as complete.
    if unread:
        print("%d transcript%s could not be read, so any limit message in %s is not in the record." % (
            unread, "" if unread == 1 else "s", "it" if unread == 1 else "them"), file=sys.stderr)
    if dirs_unread:
        print("%d folder%s under the transcripts could not be listed, so what %s hold%s is not in the record." % (
            len(dirs_unread), "" if len(dirs_unread) == 1 else "s", "it" if len(dirs_unread) == 1 else "they",
            "s" if len(dirs_unread) == 1 else ""), file=sys.stderr)
    return 1 if unread or dirs_unread else 0


def et(ts):
    tz = zone(ET)
    return ts.astimezone(tz) if tz else ts


def clock(ts):
    return ts.strftime("%I:%M %p").lstrip("0")


def cmd_days():
    rows, torn = [], 0
    try:
        with open(record_path(), encoding="utf-8", errors="replace") as fh:
            for l in fh:
                if not l.strip():
                    continue
                try:
                    r = json.loads(l)
                except ValueError:
                    r = None
                # A torn or foreign line is counted and said, never a reason to print nothing.
                if isinstance(r, dict) and parse_at(r.get("at")) is not None and isinstance(r.get("kind"), str):
                    rows.append(r)
                else:
                    torn += 1
    except FileNotFoundError:
        pass
    except OSError as e:
        print("The record at %s could not be read: %s" % (record_path(), e), file=sys.stderr)
        return 1
    failures, failures_unread = [], None
    try:
        with open(os.path.join(record_dir(), "failures.jsonl"), encoding="utf-8", errors="replace") as fh:
            for l in fh:
                try:
                    f = json.loads(l)
                except ValueError:
                    continue
                if isinstance(f, dict):
                    failures.append(f)
    except FileNotFoundError:
        pass
    except OSError as e:
        failures_unread = str(e)
    if not rows:
        print("No usage limit message has been recorded on this Mac. Run `limit-messages.py scan` to fill the record from the transcripts still on disk.")
    else:
        ats = sorted(parse_at(r["at"]) for r in rows)
        print("Usage limit messages on this Mac: %d recorded, from %s to %s ET." % (
            len(rows), et(ats[0]).strftime("%a %b %d %Y"), et(ats[-1]).strftime("%a %b %d %Y")))
        for kind, title in KIND_TITLES:
            mine = [r for r in rows if r.get("kind") == kind]
            if not mine:
                continue
            days = {}
            for r in mine:
                days.setdefault(et(parse_at(r["at"])).date(), []).append(r)
            cycles = sorted({r.get("cycle") for r in mine if r.get("resets_at")})
            print("")
            print("%s: %d day%s, %d message%s, %d distinct reset time%s" % (
                title, len(days), "" if len(days) == 1 else "s", len(mine), "" if len(mine) == 1 else "s",
                len(cycles), "" if len(cycles) == 1 else "s"))
            for d in sorted(days):
                rs = days[d]
                models = sorted({r["model"] for r in rs if r.get("model")})
                who = {}
                for r in rs:
                    who[r.get("who")] = who.get(r.get("who"), 0) + 1
                resets = sorted({r["resets_at"] for r in rs if r.get("resets_at")})
                accts = sorted({r["account"] for r in rs if r.get("account")})
                parts = ["%d message%s" % (len(rs), "" if len(rs) == 1 else "s"),
                         ", ".join("%s %d" % (k, who[k]) for k in sorted(who, key=str))]
                parts.append("; ".join("resets " + et(parse_at(x)).strftime("%a %b %d ") + clock(et(parse_at(x))) + " ET" for x in resets) or "no reset time named")
                parts.append("account " + ", ".join(accts) if accts else "account unread")
                print("  %s%s: %s" % (d.strftime("%a %b %d"), " (%s)" % ", ".join(models) if models else "", "; ".join(parts)))
        read = sum(1 for r in rows if r.get("account"))
        print("")
        print("Account read for %d of %d messages. It is read only while the session is running (the status bar mod's session record); messages found by the backfill after a session ended carry none." % (read, len(rows)))
    if torn:
        print("%d line%s of the record could not be read and %s left out." % (torn, "" if torn == 1 else "s", "is" if torn == 1 else "are"))
    if failures:
        last = parse_at(failures[-1].get("at"))
        print("The recorder failed %d time%s, last at %s: %s" % (
            len(failures), "" if len(failures) == 1 else "s",
            et(last).strftime("%a %b %d ") + clock(et(last)) + " ET" if last else "an unknown time", failures[-1].get("why")))
    if failures_unread:
        print("Whether the recorder has failed is not known: its failure log could not be read (%s)." % failures_unread)
    return 0


def main(argv):
    # A model name or a reset time read from a line holding a lone surrogate is still printed.
    sys.stdout.reconfigure(errors="replace")
    sys.stderr.reconfigure(errors="replace")
    cmds = {"record": cmd_record, "scan": cmd_scan, "days": cmd_days}
    if len(argv) != 2 or argv[1] not in cmds:
        print("usage: limit-messages.py record|scan|days", file=sys.stderr)
        return 2
    return cmds[argv[1]]()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
