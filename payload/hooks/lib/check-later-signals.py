#!/usr/bin/env python3
"""Find what the latest turn left waiting on a later day (claude-config#2079).

    check-later-signals.py <transcript_path> <check-later SKILL.md path>

Read by check-later-nudge.sh, the Stop hook that sends a session to the /check-later skill so a
dated check reaches Dan's Slack list without his having to remember the command. Dan, 2026-11-02:
"I'd love for you to just automatically run /check-later without me having to remember anytime
something like that comes up for the future."

THE TURN is everything since the last genuine user message, found by turn-worked.py's own reader,
imported rather than copied, so the Stop hooks cannot disagree about where a turn starts.

THE THREE SIGNALS, and only these (decided for #2079):
  1. a one shot CronCreate (recurring false) whose next run falls on a later day than the call. A
     session cron dies with the session, which is how the Bidspoke EQX repull check for Nov 3 was
     nearly lost on 2026-11-02. A one shot later the same day is a wait, not a dated check. A
     schedule this cannot read counts as a later day, because missing a dated check costs more than
     one needless look (L648).
  2. a Write, Edit or MultiEdit to a project memory file (.../projects/<project>/memory/...) whose
     new text names a date after today. A past date (when a fact was learned) is not a signal.
  3. the assistant's OWN text promising to check again on a later day ("check again tomorrow",
     "re-check on Nov 5"). Tool results are never read, and text inside quotation marks, a code span
     or a quoted block is removed first, so a quoted "tomorrow" is not a promise.

SILENT when the flow already ran this turn: Dan typed /check-later, the session started the skill
itself through the Skill tool (claude-config#2532), or a row was written to the list the skill names. Matching an item against rows already on the list is the skill's own step 5,
which this does not repeat (L655).

"Today" is the local date of the transcript line that carries the signal, so a fixture carries its
own clock (L713) and a turn that crossed midnight judges each signal by when it was made.

OUTPUT: one plain line per signal on stdout, for Dan to read in the Stop hook's reason, and exit 0;
nothing and exit 0 when the turn left nothing dated. Exit 3, with the cause on stderr, when the
transcript cannot be read or holds no readable line: an unreadable turn is never reported as a turn
with nothing to check (L98).

The list id has one home, the check-later skill's "## The list" section (`list id `<id>``), and is
read from the SKILL.md given as the second argument, the same file the hook's reason points at, so a
list that moves is moved in one place (L83). It is read only when a signal is found AND the turn made a Slack list write call (a row can
only have been written then). Exit 4, with the
signals still on stdout and the cause on stderr, when that file names no list id: the turn left
something, but whether its row is already written cannot be told.
"""
import importlib.util
import json
import os
import re
import sys
from datetime import date, datetime, timedelta

HOOKS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIST_ID_RE = re.compile(r"list id `([A-Z0-9]+)`")


def _turn_reader():
    sys.dont_write_bytecode = True   # no cache beside the hooks (#2600)
    spec = importlib.util.spec_from_file_location("turn_worked", os.path.join(HOOKS, "turn-worked.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Unreadable(Exception):
    pass


class NoListId(Exception):
    pass


def list_id(skill):
    try:
        with open(skill, encoding="utf-8", errors="replace") as f:
            m = LIST_ID_RE.search(f.read())
    except OSError as e:
        raise NoListId("could not open %s (%s)" % (skill, e.strerror or e))
    if not m:
        raise NoListId("%s names no list id" % skill)
    return m.group(1)


def read_turn(path):
    """(lines of this turn in order, the user message that opened it or None)."""
    tw = _turn_reader()
    try:
        f = open(path, "rb")
    except OSError as e:
        raise Unreadable("could not open it: %s" % (e.strerror or e))
    turn, opener, seen_any = [], None, False
    try:
        for ln in tw.lines_from_end(f, [0]):
            try:
                obj = json.loads(ln.decode("utf-8", "replace"))
            except Exception:
                continue
            if not isinstance(obj, dict):
                continue
            seen_any = True
            if tw.is_genuine_user(obj):
                opener = obj
                break
            turn.append(obj)
    except OSError as e:
        raise Unreadable("reading it failed: %s" % (e.strerror or e))
    finally:
        f.close()
    if not seen_any:
        raise Unreadable("it holds no line that reads as a transcript entry")
    turn.reverse()
    return turn, opener


def local_time(obj):
    ts = obj.get("timestamp")
    if isinstance(ts, str):
        try:
            return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone().replace(tzinfo=None)
        except ValueError:
            pass
    return datetime.now()


def tool_uses(obj):
    if obj.get("type") != "assistant":
        return []
    content = (obj.get("message") or {}).get("content")
    if not isinstance(content, list):
        return []
    return [it for it in content if isinstance(it, dict) and it.get("type") == "tool_use"]


def own_text(obj):
    if obj.get("type") != "assistant":
        return ""
    content = (obj.get("message") or {}).get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    return "\n".join(it.get("text", "") for it in content
                     if isinstance(it, dict) and it.get("type") == "text" and isinstance(it.get("text"), str))


def day_label(d):
    return "%s %s %d" % (d.strftime("%a"), d.strftime("%b"), d.day)


def time_label(t):
    hour = t.hour % 12 or 12
    zone = datetime.now().astimezone().strftime("%Z")
    zone = "ET" if zone in ("EST", "EDT") else zone
    return "%d:%02d %s%s" % (hour, t.minute, "AM" if t.hour < 12 else "PM", (" " + zone) if zone else "")


# ---- 1. cron ----
NAMES = {"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9,
         "oct": 10, "nov": 11, "dec": 12, "sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5,
         "sat": 6}


def cron_field(text, lo, hi):
    """The set a cron field allows, or None when it is not the plain five field syntax."""
    out = set()
    for part in text.lower().split(","):
        step = 1
        if "/" in part:
            part, s = part.split("/", 1)
            if not s.isdigit() or int(s) == 0:
                return None
            step = int(s)
        if part == "*":
            a, b = lo, hi
        elif "-" in part:
            a, b = part.split("-", 1)
            a, b = NAMES.get(a, a), NAMES.get(b, b)
            if not (str(a).isdigit() and str(b).isdigit()):
                return None
            a, b = int(a), int(b)
        else:
            v = NAMES.get(part, part)
            if not str(v).isdigit():
                return None
            a = b = int(v)
        if a < lo or b > hi or a > b:
            return None
        out.update(range(a, b + 1, step))
    return out


def next_fire(cron, after):
    fields = cron.split()
    if len(fields) != 5:
        return None
    minute, hour, dom, mon, dow = (cron_field(fields[0], 0, 59), cron_field(fields[1], 0, 23),
                                   cron_field(fields[2], 1, 31), cron_field(fields[3], 1, 12),
                                   cron_field(fields[4], 0, 7))
    if None in (minute, hour, dom, mon, dow):
        return None
    if 7 in dow:
        dow = (dow - {7}) | {0}
    dom_any, dow_any = fields[2] == "*", fields[4] == "*"
    for offset in range(0, 366 * 5):
        d = after.date() + timedelta(days=offset)
        if d.month not in mon:
            continue
        on_dom, on_dow = d.day in dom, (d.weekday() + 1) % 7 in dow
        if dom_any and dow_any:
            ok = True
        elif dom_any:
            ok = on_dow
        elif dow_any:
            ok = on_dom
        else:
            ok = on_dom or on_dow
        if not ok:
            continue
        for h in sorted(hour):
            for m in sorted(minute):
                t = datetime(d.year, d.month, d.day, h, m)
                if t > after:
                    return t
    return None


def cron_signal(use, when):
    inp = use.get("input") or {}
    recurring = inp.get("recurring", True)
    if recurring not in (False, "false", "False"):
        return None
    cron = inp.get("cron") if isinstance(inp.get("cron"), str) else ""
    t = next_fire(cron, when)
    if t is None:
        return "a one shot reminder whose schedule could not be read (%s)" % (cron or "none given")
    if t.date() <= when.date():
        return None
    return "a one shot reminder for %s at %s" % (day_label(t), time_label(t))


# ---- dates in text ----
MONTHS = r"(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)"
ISO = re.compile(r"\b(20\d\d)-(\d\d)-(\d\d)\b")
NAMED = re.compile(r"\b" + MONTHS + r"\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:,?\s+(20\d\d))?")


def named_date(month, day, year, today):
    m = NAMES.get(month[:3].lower())
    try:
        if year:
            return date(int(year), m, int(day))
        d = date(today.year, m, int(day))
    except (ValueError, TypeError):
        return None
    # A date with no year is read as the one nearest today, so "Jan 2" written on Dec 30 is ahead.
    if (d - today).days > 183:
        d = date(d.year - 1, d.month, d.day)
    elif (today - d).days > 183:
        d = date(d.year + 1, d.month, d.day)
    return d


def dates_in(text, today):
    found = []
    for m in ISO.finditer(text):
        try:
            found.append((m.start(), m.end(), date(int(m.group(1)), int(m.group(2)), int(m.group(3)))))
        except ValueError:
            pass
    for m in NAMED.finditer(text):
        d = named_date(m.group(1), m.group(2), m.group(3), today)
        if d:
            found.append((m.start(), m.end(), d))
    return found


# ---- 2. memory ----
MEMORY_PATH = re.compile(r"/projects/[^/]+/memory/[^/]+$")


def memory_signal(use, when):
    if use.get("name") not in ("Write", "Edit", "MultiEdit"):
        return None
    inp = use.get("input") or {}
    path = inp.get("file_path") if isinstance(inp.get("file_path"), str) else ""
    if not MEMORY_PATH.search(path):
        return None
    texts = [inp.get("content"), inp.get("new_string")]
    texts += [e.get("new_string") for e in (inp.get("edits") or []) if isinstance(e, dict)]
    ahead = sorted(d for t in texts if isinstance(t, str) for _, _, d in dates_in(t, when.date())
                   if d > when.date())
    if not ahead:
        return None
    return "a memory note (%s) naming %s" % (os.path.basename(path), day_label(ahead[0]))


# ---- 3. a promise in the assistant's own words ----
VERB = re.compile(
    r"\b(?:re-?check|check(?: (?:it|this|that|them|in on it))? (?:again|back)|look(?: at [^.;!?]{0,40}?)? again"
    # A dated wait said without a check verb (measured on real transcripts, #2079): an issue kept
    # open for a later reading, or work waiting ON later data. "wait for" is left out, because it
    # is what a sentence choosing NOT to wait says ("rather than wait for tomorrow's run").
    r"|stays? open (?:for|until)|(?:is|are)? ?waiting on|waits? on"
    r"|re-?pull|re-?run|re-?read|revisit|circle back|come back to"
    r"|(?:I'll|I will|we'll|we will|I'm going to|I plan to|let's|I can) (?:check|look|verify|confirm|see|measure|watch|pull))\b",
    re.IGNORECASE)
WEEKDAYS = r"(?:Mon|Tues|Wednes|Thurs|Fri|Satur|Sun)day"
LATER = re.compile(
    r"\btomorrow\b|\b(?:on|this|next|by|after) " + WEEKDAYS + r"\b|\bnext (?:week|month)\b"
    r"|\bin (?:\d+|a|an|one|two|three|four|five|six|seven|a few|several) (?:days?|weeks?|months?)\b",
    re.IGNORECASE)
DATED = re.compile(r"\b(?:on|after|by|until)\s+(?=" + MONTHS + r"\.?\s+\d|20\d\d-\d\d-\d\d)")
QUOTED = re.compile(r"```.*?```|`[^`\n]*`|\"[^\"\n]*\"|“[^”\n]*”", re.DOTALL)
SENTENCE = re.compile(r"(?<=[.!?;])\s+|\n+")


def promise_signal(text, when):
    text = QUOTED.sub(" ", text)
    text = "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith(">"))
    # A month's abbreviation point ("Nov. 5") must not end the sentence it sits in.
    text = re.sub(r"\b(Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\.", r"\1", text)
    for sentence in SENTENCE.split(text):
        verb = VERB.search(sentence)
        if not verb:
            continue
        later = LATER.search(sentence)
        if not later:
            for m in DATED.finditer(sentence):
                ahead = [d for s, _, d in dates_in(sentence[m.end():], when.date()) if s == 0]
                if ahead and ahead[0] > when.date():
                    later = m
                    break
        if not later:
            continue
        a = min(verb.start(), later.start())
        b = max(verb.end(), later.end())
        if later is not None and later.re is DATED:
            tail = NAMED.match(sentence, later.end()) or ISO.match(sentence, later.end())
            b = max(b, tail.end() if tail else b)
        span = sentence[a:b].strip()
        if len(span) > 90:
            span = span[:87].rstrip() + "..."
        return 'a promise to look again: "%s"' % span
    return None


def already_ran(turn, opener, skill):
    if opener is not None:
        content = (opener.get("message") or {}).get("content")
        text = content if isinstance(content, str) else json.dumps(content)
        if "<command-name>/check-later</command-name>" in text or text.lstrip().startswith("/check-later"):
            return True
    wanted = None
    for obj in turn:
        for use in tool_uses(obj):
            name = use.get("name") or ""
            given = use.get("input")
            if name == "Skill" and isinstance(given, dict) and given.get("skill") == "check-later":
                return True
            if not name.endswith(("slack_add_list_record", "slack_update_list_record")):
                continue
            wanted = wanted or list_id(skill)
            if wanted in json.dumps(use.get("input") or {}):
                return True
    return False


def signals(turn, opener):
    out = []
    for obj in turn:
        when = local_time(obj)
        for use in tool_uses(obj):
            s = cron_signal(use, when) if use.get("name") == "CronCreate" else memory_signal(use, when)
            if s and s not in out:
                out.append(s)
        text = own_text(obj)
        if text:
            s = promise_signal(text, when)
            if s and s not in out:
                out.append(s)
    return out


def left_for_later(turn, opener, skill):
    out = signals(turn, opener)
    if out and already_ran(turn, opener, skill):
        return []
    return out


def main():
    if len(sys.argv) != 3 or not sys.argv[1] or not sys.argv[2]:
        print("check-later-signals: usage is check-later-signals.py <transcript> <check-later SKILL.md>", file=sys.stderr)
        return 3
    try:
        turn, opener = read_turn(sys.argv[1])
    except Unreadable as e:
        print("check-later-signals: %s" % e, file=sys.stderr)
        return 3
    try:
        found = left_for_later(turn, opener, sys.argv[2])
    except NoListId as e:
        for line in signals(turn, opener):
            print(line)
        print("check-later-signals: %s" % e, file=sys.stderr)
        return 4
    for line in found:
        print(line)
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main())
