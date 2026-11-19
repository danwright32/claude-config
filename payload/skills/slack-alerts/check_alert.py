#!/usr/bin/env python3
"""check_alert.py: reads one automated Slack message and fails it on the measurable rules of the
Slack alert standard (the slack-alerts skill beside this file, claude-config#3159).

The message is read as the text sent to Slack, in Slack's own markup: *bold*, a code fence for the
other system's response, <https://address|Label> for the link, <@U123> for a mention, and list
lines that start with a bullet character or a hyphen.

    python3 check_alert.py --kind alert [--urgent] [--app NAME] [FILE]    (FILE or standard input)
    python3 check_alert.py --kind alert --record RECORD --alert KEY --alert-keys KEY,KEY,... [FILE]

Exit 0 when the message passes, 1 with one FAIL line per broken rule, 2 on a bad command line, a
message that could not be read, or a project record that could not be read as written.

A project's record (claude-config#3226) names, each with the owner's date, the alerts that may show
a clock time in the person's own zone, a bare id on a labelled list line, or break one named rule.
With no record nothing beyond the standard is allowed, and a record with one bad line is refused
whole, never read as allowing anything.
The words inside the code fence are not judged, since that text belongs to the other system; only
its length, and that there is one closed block, are. What no script can
judge (whether the first line is true, whether the link opens the failed thing) stays with the
skill and with whoever reviews the wording.
"""
import argparse
import datetime
import re
import sys

KINDS = ("alert", "recovery", "reminder", "digest", "request")
WORDING_LIMIT = 200
ERROR_LIMIT = 500
LIST_LIMIT = 5
# Sentences allowed under the first line. A request may quote the asker's note and add one more.
SENTENCES = {"alert": 1, "recovery": 1, "reminder": 0, "digest": 1, "request": 2}
LINK_REQUIRED = ("alert", "reminder", "digest", "request")

RULES = (
    "empty", "first-line-bold", "first-line-title", "recovery-opening", "reminder-opening",
    "app-name", "mention", "wording-length", "sentences", "labelled-lines", "list-length",
    "error-block", "link-missing", "link-count", "link-last", "link-label", "bare-url",
    "time-format", "emoji", "dash", "capitals", "machine-plural", "issue-ref", "raw-id", "filler",
)

# Characters the style rules ban from source are built by code point, so this file holds none.
BULLET = chr(0x2022)
LONG_DASHES = (chr(0x2013), chr(0x2014))
EMOJI = re.compile(
    "[" + chr(0x1F000) + "-" + chr(0x1FAFF) + chr(0x2600) + "-" + chr(0x27BF)
    + chr(0x2B00) + "-" + chr(0x2BFF) + chr(0xFE0F) + "]"
)
SHORTCODE = re.compile(r"(?<![\w:]):[a-z][a-z0-9_+\-]*:(?!\w)")
FENCED = re.compile(r"```(.*?)```", re.S)
MENTION = r"(?:<@[UW][A-Z0-9]+>|<!(?:here|channel|everyone)>|<!subteam\^[A-Z0-9]+(?:\|[^>]*)?>)"
LEADING_MENTIONS = re.compile(r"^(?:" + MENTION + r"[,:]?\s*)+")
ANY_MENTION = re.compile(MENTION)
LINK_LINE = re.compile(r"^<(https?://[^|>\s]+)\|([^>]+)>$")
ANY_LINK = re.compile(r"<https?://[^>]*>")
LABELLED_LINK = re.compile(r"<https?://[^|>\s]+\|([^>]+)>")
LINK_LABEL = re.compile(r"^[A-Z][a-z]+(?: [A-Za-z0-9]+){1,3}$")
MORE_LINE = re.compile(r"^and \d[\d,]* more$")
LABELLED_LINE = re.compile(r"^\*[^*\n]{1,40}:\*")
SENTENCE_END = re.compile(r"(?<=[.!?])[\"')]*\s+(?=[\"'(]*[A-Z0-9])")
GENERIC_TITLE = re.compile(r"\b(?:alert|alerts|notification|notice|warning)$", re.I)
RECOVERY_OPENING = re.compile(r"^Recovered: \S+(?: \S+){2,}")
REMINDER_OPENING = re.compile(r"^Still open after \d+ (?:minute|minutes|hour|hours|day|days): \S+")
DIGIT_DATE = re.compile(r"\b\d{4}-\d{2}(?:-\d{2})?\b")
SECONDS = re.compile(r"\b\d{1,2}:\d{2}:\d{2}\b")
OTHER_ZONE = re.compile(r"\b(?:UTC|GMT|EST|EDT|CST|CDT|MST|MDT|PST|PDT|Eastern)\b")
CLOCK = re.compile(r"(?<![\d:])\d{1,2}:\d{2}(?![\d:])")
MERIDIEM = re.compile(r" (?:AM|PM)\b")
ZONE_OR_RANGE = re.compile(r"(?: ET\b| (?:to|and) \d{1,2}:\d{2} (?:AM|PM)\b)")
# The zones an alert the project records as own-zone may also name, for a person's own time
# (Dan, 18 Nov 2026, #3226: CT, MT, PT, AKT and HST, and AZ for Arizona, which never changes its
# clocks, so MT there reads an hour off for most of the year).
OWN_ZONES = ("CT", "MT", "PT", "AZ", "AKT", "HST")
OWN_ZONE_OR_RANGE = re.compile(
    r"(?: (?:ET|" + "|".join(OWN_ZONES) + r")\b| (?:to|and) \d{1,2}:\d{2} (?:AM|PM)\b)"
)
# A bare id an alert recorded as labelled-id may show: alone on a list line, after a label of one
# to four plain words saying what it is, such as "Queue row: 4817" (#3226).
LABELLED_ID_LINE = re.compile(r"^(?:" + BULLET + r"|-) [A-Z][A-Za-z]*(?: [A-Za-z]+){0,3}: (\S+)$")
RECORD_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
ALLOWANCES = ("own-zone", "labelled-id", "exempt")
YEAR = re.compile(r"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?,? (?:\d{1,2},? )?20\d{2}\b")
SHOUTED = re.compile(
    r"\b(?:NOT|NEVER|WRONG|FAILED|WARNING|DOWN|UNKNOWN|SKIPPED|MUST|ONLY|PRODUCTION|ERROR|"
    r"CRITICAL|URGENT|IMPORTANT|NOTE|LIVE|DEAD|LOST)\b"
)
MACHINE_PLURAL = re.compile(r"\w\(s\)")
ISSUE_REF = re.compile(r"(?<![\w&/#])#\d+\b")
RAW_ID = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I)
# Sentences about the alert instead of the event. Each was measured in real alerts or in the
# five baseline drafts written without the skill on 2026-11-17.
FILLER = (
    (re.compile(r"\bno action (?:is )?(?:needed|required)\b", re.I), "says no action is needed"),
    (re.compile(r"\bnothing (?:to do|more is needed|is needed|needs)\b", re.I), "says there is nothing to do"),
    (re.compile(r"\bthis (?:alert|check|message|notice|reminder|post)\b", re.I), "talks about the alert itself"),
    (re.compile(r"\b(?:posts?|fires?|clears?|repeats?|closes) (?:again|here|once|after|when)\b", re.I), "explains when the alert posts or clears"),
    (re.compile(r"\bneeds? a look\b", re.I), "says it needs a look"),
    (re.compile(r"\binformational\b", re.I), "calls itself informational"),
    (re.compile(r"\b(?:please note|note that|fyi|heads up)\b", re.I), "opens with a filler phrase"),
    (re.compile(r"\bfor more (?:information|details)\b", re.I), "points at more information"),
    (re.compile(r"\bsays what it means\b", re.I), "points at a document for its meaning"),
    (re.compile(r"\bas precisely as\b", re.I), "explains how the check measures"),
)


def plain(text):
    """The words a reader sees: markup, mentions and link addresses taken away."""
    text = LABELLED_LINK.sub(lambda m: m.group(1), text)
    text = ANY_LINK.sub("", text)
    text = ANY_MENTION.sub("", text)
    return re.sub(r"\s+", " ", text.replace("*", "").replace("`", "")).strip()


class RecordError(ValueError):
    """A project record that cannot be read as written. It is refused whole, never read as allowing
    anything, and the message names the line."""


class Record:
    """What a project's record allows each of its alerts, read by parse_record or load_record."""

    def __init__(self, keys, allowed):
        self.keys = frozenset(keys)
        self._allowed = {key: frozenset(entries) for key, entries in allowed.items()}

    def allows(self, alert):
        return self._allowed.get(alert, frozenset())


def parse_record(text, alert_keys, source="the record"):
    """Read a project's record. Each line is the owner's date, an alert key and what it allows:

        2026-11-18  time-off-note  own-zone
        2026-11-18  queue-backlog  labelled-id
        2026-11-18  page-watch     exempt bare-url

    alert_keys is every alert the project posts, so an entry naming any other is refused rather
    than left to allow nothing. Blank lines and lines starting with # are skipped."""
    keys = frozenset(key.strip() for key in alert_keys if key.strip())
    if not keys:
        raise RecordError(f"{source}: no alert keys were given, so its entries cannot be checked against the alerts the project posts")
    allowed, seen = {}, {}
    for number, raw in enumerate(text.split("\n"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        where = f"{source}, line {number}"
        words = line.split()
        if not RECORD_DATE.match(words[0]):
            raise RecordError(f'{where}: "{line}" does not start with the date the owner decided it, written YYYY-MM-DD')
        try:
            datetime.date.fromisoformat(words[0])
        except ValueError:
            raise RecordError(f"{where}: {words[0]} is not a day on the calendar") from None
        if len(words) < 3:
            raise RecordError(f"{where}: each entry is a date, an alert key and what it allows ({', '.join(ALLOWANCES)})")
        key, what, rest = words[1], words[2], words[3:]
        if key not in keys:
            raise RecordError(f'{where}: "{key}" is not one of the alerts the project posts ({", ".join(sorted(keys))})')
        if what == "exempt":
            if len(rest) != 1:
                raise RecordError(f"{where}: an exemption names exactly one rule")
            if rest[0] not in RULES or rest[0] == "empty":
                raise RecordError(f'{where}: "{rest[0]}" is not a rule an alert can be exempted from ({", ".join(r for r in RULES if r != "empty")})')
            entry = "exempt " + rest[0]
        elif what in ALLOWANCES:
            if rest:
                raise RecordError(f'{where}: {what} takes nothing after it, and "{" ".join(rest)}" follows')
            entry = what
        else:
            raise RecordError(f'{where}: "{what}" is not something a record can allow: own-zone, labelled-id, or exempt and one rule')
        if (key, entry) in seen:
            raise RecordError(f"{where}: {key} {entry} is already recorded on line {seen[(key, entry)]}")
        seen[(key, entry)] = number
        allowed.setdefault(key, set()).add(entry)
    return Record(keys, allowed)


def load_record(path, alert_keys):
    """parse_record on a file. A file that cannot be read raises OSError; one that is not UTF-8 is a
    RecordError, since a record read with replaced bytes could name a key nobody wrote."""
    with open(path, "rb") as handle:
        data = handle.read()
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise RecordError(f"{path}: not UTF-8 at byte {error.start}") from None
    return parse_record(text, alert_keys, source=path)


def is_labelled_id(line):
    """A list line holding one bare id after a label saying what it is, and nothing else."""
    match = LABELLED_ID_LINE.match(line)
    return bool(match and RAW_ID.fullmatch(match.group(1)))


def check(text, kind, urgent=False, apps=(), *, record=None, alert=None):
    """Every rule the message breaks, as (rule, what was measured), in the order of RULES. With a
    project's record and the alert this message is, what the record allows that alert is applied."""
    if kind not in KINDS:
        raise ValueError(f"unknown kind {kind!r}: one of {', '.join(KINDS)}")
    if (record is None) != (alert is None):
        raise ValueError("a project's record and the alert a message is go together")
    allowances = frozenset()
    if record is not None:
        if alert not in record.keys:
            raise ValueError(f"{alert!r} is not one of the alerts the record was read against")
        allowances = record.allows(alert)
    found = {}

    def fail(rule, said):
        found.setdefault(rule, said)

    blocks = FENCED.findall(text)
    outside = FENCED.sub("\n", text)
    lines = [line.strip() for line in outside.split("\n") if line.strip()]
    if not lines and not blocks:
        return [("empty", "the message is empty")]
    if "```" in outside:
        fail("error-block", "a code fence is opened and never closed")
    if len(blocks) > 1:
        fail("error-block", f"{len(blocks)} code blocks; the other system's response goes in one")
    for block in blocks:
        if len(block.strip()) > ERROR_LIMIT:
            fail("error-block", f"the code block is {len(block.strip())} characters; the limit is {ERROR_LIMIT}, cut on a word boundary")

    first = lines[0] if lines else ""
    leading = LEADING_MENTIONS.match(first)
    rest = first[leading.end():] if leading else first
    if not re.fullmatch(r"\*[^*]+\*", rest):
        fail("first-line-bold", "the first line is not one bold sentence (after any mention)")
    lead = plain(rest)
    words = lead.split()

    if kind == "recovery":
        if not RECOVERY_OPENING.match(lead):
            fail("recovery-opening", 'a recovery opens "Recovered: " and then says what recovered')
    elif kind == "reminder":
        if not REMINDER_OPENING.match(lead):
            fail("reminder-opening", 'a reminder opens "Still open after N hours: " and then repeats what happened')
    elif len(words) < 4 or GENERIC_TITLE.search(lead):
        fail("first-line-title", f'"{lead}" is a title; the first line says what happened and names the thing')
    for app in apps:
        if app and lead.lower().startswith(app.lower()):
            fail("app-name", f'the message opens with the app name "{app}"; the posting bot already carries it')

    mention_needed = kind == "request" or (urgent and kind in ("alert", "reminder"))
    if mention_needed and not leading:
        if kind == "request":
            fail("mention", "a request opens with a mention of the person asked")
        else:
            fail("mention", "an urgent alert and its reminder open with <!here>, or with the person the project's CLAUDE.md names")
    if not mention_needed and ANY_MENTION.search(outside):
        fail("mention", "a mention is for an urgent alert, its reminder, or a request to a person")

    body = lines[1:]
    links = [line for line in body if LINK_LINE.match(line)]
    items = [line for line in body if line.startswith(BULLET + " ") or line.startswith("- ")]
    prose = [line for line in body if line not in links and line not in items and not MORE_LINE.match(line)]
    prose_plain = [plain(line) for line in prose]

    wording = " ".join([lead] + [p for p in prose_plain if p])
    if len(wording) > WORDING_LIMIT:
        fail("wording-length", f"the wording is {len(wording)} characters; the limit is {WORDING_LIMIT} (list, code block and link not counted)")
    under = " ".join(p for p in prose_plain if p).strip()
    sentences = len([s for s in SENTENCE_END.split(under) if s.strip()]) if under else 0
    if sentences > SENTENCES[kind]:
        allowed = SENTENCES[kind]
        fail("sentences", f"{sentences} sentences under the first line; the {kind} kind takes at most {allowed}")
    if any(LABELLED_LINE.match(line) for line in body):
        fail("labelled-lines", "bold labelled lines; say what happened in the first line and at most one sentence")
    if len(items) > LIST_LIMIT:
        fail("list-length", f"{len(items)} list lines; show {LIST_LIMIT} and end with \"and {len(items) - LIST_LIMIT} more\"")

    every_link = ANY_LINK.findall(outside)
    if kind in LINK_REQUIRED and not links:
        fail("link-missing", f"a {kind} ends with one labelled link to the thing itself")
    if len(every_link) > 1 or (every_link and not links):
        fail("link-count", f"{len(every_link)} links, or a link inside a sentence; one link stands alone on the last line")
    if links:
        last = [line.strip() for line in text.split("\n") if line.strip()][-1]
        if last != links[-1]:
            fail("link-last", "the link is not the last line")
        label = LINK_LINE.match(links[-1]).group(2)
        if not LINK_LABEL.match(label):
            fail("link-label", f'"{label}" is not a verb and the thing it opens in two to four plain words, such as "View run"')
    if any("|" not in link for link in every_link) or "://" in ANY_LINK.sub("", outside):
        fail("bare-url", "a bare address; give the link a label")

    read = "\n".join(plain(line) for line in lines)
    times = []
    if DIGIT_DATE.search(read):
        times.append("a date or month written in digits")
    if SECONDS.search(read):
        times.append("seconds")
    if OTHER_ZONE.search(read):
        times.append("a zone that is not written ET")
    own_zone = "own-zone" in allowances
    zone_or_range = OWN_ZONE_OR_RANGE if own_zone else ZONE_OR_RANGE
    zones = "ET or the person's own zone (" + ", ".join(OWN_ZONES) + ")" if own_zone else "ET"
    for clock in CLOCK.finditer(read):
        after = read[clock.end():]
        if not MERIDIEM.match(after):
            times.append(f'"{clock.group(0)}" without AM or PM in capitals after a space')
        elif not zone_or_range.match(after[3:]):
            times.append(f'"{clock.group(0)}" without {zones} after it')
    if YEAR.search(read):
        times.append("a year")
    if times:
        fail("time-format", "; ".join(dict.fromkeys(times)) + '. Write "3:05 PM ET", or "3:05 PM ET, Nov 14" when it is not today')

    if EMOJI.search(read) or SHORTCODE.search(read):
        fail("emoji", "an emoji")
    if any(dash in read for dash in LONG_DASHES) or " - " in read:
        fail("dash", "a dash used as punctuation; use a comma, a colon or a new sentence")
    shouted = SHOUTED.search(read)
    if shouted:
        fail("capitals", f'"{shouted.group(0)}" in capitals for emphasis')
    if MACHINE_PLURAL.search(read):
        fail("machine-plural", 'a plural written "(s)"; write the word for the count')
    issue = ISSUE_REF.search(read)
    if issue:
        fail("issue-ref", f'an issue number, "{issue.group(0)}"; the reader cannot act on it')
    ids_read = read
    if "labelled-id" in allowances:
        ids_read = "\n".join(plain(line) for line in lines if not is_labelled_id(line))
    if RAW_ID.search(ids_read):
        fail("raw-id", "a bare id; link to the thing or leave the id out")
    for pattern, what in FILLER:
        said = pattern.search(read)
        if said:
            fail("filler", f'"{said.group(0)}" {what}; say only what happened')
            break

    # An exemption the record holds for this alert lifts that one rule and no other.
    return [(rule, found[rule]) for rule in RULES if rule in found and "exempt " + rule not in allowances]


def main(argv=None):
    parser = argparse.ArgumentParser(description="Check one automated Slack message against the Slack alert standard.")
    parser.add_argument("--kind", required=True, choices=KINDS, help="which kind of post this is")
    parser.add_argument("--urgent", action="store_true", help="the problem costs money or stops customers, so it carries a mention")
    parser.add_argument("--app", action="append", default=[], help="the app's name, which the message must not open with (repeatable)")
    parser.add_argument("--record", help="the project's record of what its alerts may do beyond the standard, each with the owner's date")
    parser.add_argument("--alert", help="which of the project's alerts this message is, as the record names it")
    parser.add_argument("--alert-keys", help="every alert the project posts, comma separated, so the record can name no other")
    parser.add_argument("file", nargs="?", help="the message file; standard input when left out")
    args = parser.parse_args(argv)
    record = None
    if args.record or args.alert or args.alert_keys:
        if not (args.record and args.alert and args.alert_keys):
            print("check_alert.py: --record, --alert and --alert-keys go together: the project's record, "
                  "which alert this message is, and every alert the project posts", file=sys.stderr)
            return 2
        keys = [key.strip() for key in args.alert_keys.split(",") if key.strip()]
        if args.alert not in keys:
            print(f'check_alert.py: --alert "{args.alert}" is not one of --alert-keys ({", ".join(keys)})', file=sys.stderr)
            return 2
        try:
            record = load_record(args.record, keys)
        except OSError as error:
            print(f"check_alert.py: cannot read the record {args.record}: {error}", file=sys.stderr)
            return 2
        except RecordError as error:
            print(f"check_alert.py: {error}", file=sys.stderr)
            return 2
    # A byte that is not UTF-8 is read as the replacement character, so the message is still
    # judged on its rules and a failure line that quotes it back can always be printed.
    try:
        if args.file:
            with open(args.file, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        else:
            text = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    except OSError as error:
        # Exit 1 means the message broke a rule, so a message that could not be read is exit 2.
        print(f"check_alert.py: cannot read {args.file or 'standard input'}: {error}", file=sys.stderr)
        return 2
    failures = check(text, args.kind, urgent=args.urgent, apps=args.app,
                     record=record, alert=args.alert if record else None)
    for rule, said in failures:
        print(f"FAIL {rule}: {said}")
    if failures:
        return 1
    lines = [line.strip() for line in FENCED.sub("\n", text).split("\n") if line.strip()]
    body = [line for line in lines[1:] if not LINK_LINE.match(line) and not MORE_LINE.match(line)
            and not line.startswith(BULLET + " ") and not line.startswith("- ")]
    lead = lines[0][LEADING_MENTIONS.match(lines[0]).end():] if LEADING_MENTIONS.match(lines[0]) else lines[0]
    used = len(" ".join([plain(lead)] + [plain(line) for line in body]))
    print(f"OK: wording {used} of {WORDING_LIMIT} characters")
    return 0


if __name__ == "__main__":
    sys.exit(main())
