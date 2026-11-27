#!/usr/bin/env python3
"""draft-edit-diff.py: compare each Slack draft a session saved with what was sent (claude-config#3554).

Sessions save every Slack message as a draft, and Dan edits it before he sends it. Nothing read
back what he sent, so the same edits were made by hand every day. This reads this Mac's session
records, pairs each saved draft with the post that followed it, and prints how often each kind of
edit was made, with the number of pairs each count rests on.

    python3 draft-edit-diff.py --author <Slack member id or display name> [--records <folder>]
                               [--examples] [--skip "<kind>"]... [--shapes] [--differences] [--likeness]

IT ONLY PRINTS. It opens files to read and has no call that writes, moves or removes one, starts no
program and sends no request; it imports nothing that could. That is a rule and not a habit: the
session records it reads name Slack's posting address, and the Slack drafts gate refuses a script
that reads them and could write a file. test-draft-edit-diff.sh reads this source for exactly that.

WHAT IT PRINTS. Counts, by default, and no message text, name or channel. With --examples it also
prints ONE pair (the draft and what was sent, each cut at EXAMPLE_CHARS) for each kind of edit that
is recurring and was not passed with --skip, which puts Slack message text into the session that
runs it. Dan chose that on 2026-11-27 (issue #3554). The pair shown is the one of that kind most
like its draft. --shapes prints, in place of the tallies, how the read results are laid out: counts,
and a name only when it is in one of two fixed lists here (KNOWN_FIELDS, KNOWN_LABELS). A key or a
label not in them is counted by its length and never printed, since it could be anybody's words.

--differences adds, for the pairs that are changed but not heavily rewritten, how many would be the
same with one more thing set aside (what is inside angle brackets, how a link is written,
punctuation, emoji, a trailing "(edited)", the last or the first line read back), and the same count
for each kind a rule can be offered for. Counts only. It is there because the first real run read
far fewer pairs as sent as drafted than the issue's measurement did, and counts alone could not say
why. Each count is an UPPER BOUND on what a difference in how a read is written could explain, and
no more: he also changes punctuation and adds and cuts lines, and a heavily rewritten pair is not
looked at.

--likeness adds how many pairs sit in each band of likeness (the same; 0.98 and over; 0.95; 0.90;
0.80; 0.70; under 0.70, which is heavily rewritten), and how many posts were the last message of
the read their text was taken from. Counts only. It is the one count that can be set beside the
issue's four bands of 2026-11-24 (22 sent as drafted, 25 lightly edited, 30 edited and 29 heavily
rewritten, of 106): this reader calls a pair sent as drafted only when the two are the SAME once
formatting is set aside, and where the issue drew its lines is not on record.

WHAT DAN DECIDED BEFORE. A kind he accepted or said never to offer again is not offered: this reads
~/.claude/state/draft-edit-review/decisions.json itself, the file the skill's decisions.py writes,
so that holds whether or not the session passes anything. --skip adds to it. A decisions file that
is there and cannot be read is exit 3, never nothing decided. It looks under the home folder only:
CLAUDE_HOME, which decisions.py honours, is not read here.

HOW A PAIR IS MADE.
  * A draft is a slack_send_message_draft call whose answer says Slack saved it (not marked as an
    error and naming none of Slack's draft errors, as mods/is-it-live/hooks/threads.ts judges it).
    Its place is its channel and the thread it replies in, or the top of the channel with no thread.
    Its time is the time on its record. A saved draft whose record carries no time (one kept only
    in the copy of a request) is in no pair, and is counted.
  * A post is a message by --author in the result of a LATER slack_read_thread or slack_read_channel
    call in any session record. A thread's first message belongs to the top of its channel. A post
    is one post however many reads show it: a reply Slack also shows in the channel is in its thread.
  * Each post is compared with the latest draft saved in the same place before it. A draft is used
    once: a second post after the same draft was written without one and is left out, as is a post
    with no draft before it, and a draft a later draft replaced before anything was posted.
  * A post more than PAIR_WITHIN_MINUTES minutes after that draft is not paired with it. Both are left
    out and counted.
  * Both are compared after Slack's formatting is set aside (links, bold, italics, bullets, quote
    markers at the start of a line, the name a read adds inside a mention of a person, a channel or
    a group, spacing and case), by words, with difflib.
  * The FIRST post after a draft takes it. A later post that is more like that draft is left out,
    and is counted when it came within PAIR_WITHIN_MINUTES minutes of the draft, so the count says
    how often that rule may have made the wrong pair.

WHAT IT CANNOT SEE, so nobody reads more into a count than it measured.
  * A thread no later session read back. Its draft is counted as having no post read back after it.
  * A draft Dan deleted. If he wrote something else in that thread within PAIR_WITHIN_MINUTES minutes, the
    two are paired and read as heavily rewritten, which keeps the pair out of every kind a rule is
    offered for. If what he wrote happens to share most of the draft's words, it reads as an edit.
  * A draft he cut to under about half its length. By the likeness used here that is heavily
    rewritten too, so the strongest cuts are in no kind.
  * A message he wrote from the start with no draft: it is left out, never counted as an edit.
  * Anything on the other Mac: each Mac holds only its own records, for as long as it keeps them.
  * Who pressed send. A post a session sent as Dan is read as his own.
  * An edit he made after sending. The text compared is the one in whichever record was read last.
  * A read result that was cut short: a long thread, a channel read's limit, or an answer too large
    for the session, which Claude Code keeps as a preview. How a record holds one was not measured.
  * How the connector shows an emoji, a quotation mark, an apostrophe, a dash, a phone number or a
    link against how the draft wrote it. Only links in the three forms named above, bold, italics,
    bullets, quote markers at the start of a line, the name a read adds inside a mention, spacing
    and case are set aside, so any of those can read as an edit, and as the opening changed when it
    sits in the first OPENING_WORDS words.
  * "@Name" typed in a draft and turned into a real mention by hand before sending. That is an edit
    he makes, and it reads as the opening changed when the name opens the message.
  * His own line shaped like a label ("Update: ...", "Next step: ...") when it is the first or the
    last line of what he sent and the draft did not hold it there. The pair is set aside with the
    lines that may be the connector's, since nothing can tell the two apart.
  * A line of the connector's own, under or over the text, that is NOT shaped like a label and is
    not the Reactions line. It is read as his words. --differences counts how many pairs a first or
    a last line could explain.
  * Why a share is what it is. The first real run read 6 of 184 pairs as sent as drafted, against
    22 of 106 in the issue's count three days before. That is not explained (see --likeness).
  * A thread read that was handed a reply's own time, not its parent's: that reply is placed at the
    top of the channel unless another read shows it inside its thread.

THE KINDS. A pair is one of the first two and nothing else, or any number of the other four.
  sent as drafted     the two are the same once formatting is set aside
  heavily rewritten   their likeness is under HEAVY (0.70, the line issue #3554's measurement used).
                      Such a pair is counted here and in no kind below, so it cannot reach the floor
                      and is never the example: it may not be an edit of that draft at all.
  figures cut         what was sent holds fewer numbers than the draft
  length cut          what was sent is more than a tenth shorter than the draft
  the ask reworded    both hold a question or a request, and the wording of it differs
  the opening changed the first OPENING_WORDS words differ

THE FLOOR. A kind is called recurring, and so offered as a rule, only at FLOOR_PAIRS pairs in
FLOOR_THREADS threads or more. Both are settings chosen on 2026-11-27 and not measurements: under
ten pairs one long thread's back and forth is enough to make an edit look like a habit, and a rule
written from one or two threads is a rule about those conversations. The first two kinds are never
offered: neither says what to write differently.

WHAT THE SHAPE RESTS ON (L48). The record around a call (a tool_use item in an assistant record, its
tool_result in a user record, the result a string or a list of text items holding JSON, and copies
of a request kept with no time) was measured on the personal MacBook on 2026-11-27 from 24 calls to
other tools of the same Slack connector. That Mac held no draft call and no read that succeeded.
The layout INSIDE a thread or channel read was measured on the work MacBook on 2026-11-27, by counts,
field names and the punctuation of headings only (pull request 3848), over 1,765 read results:
  * a detailed or default read holds the thread parent, reply and channel message headings this
    looks for, with From, Time and Message TS lines under a thread heading, in the two fields
    "messages" and "pagination_info";
  * a read that asked for response_format "concise" holds none of them, and no time for a post: 998
    of the 1,013 results this could not read. It is counted as its own kind and never paired;
  * a channel message heading can have no name, or an address and more fields in its brackets;
  * a heading of the shape "=== words (words) ===" in a thread read holds no message;
  * a line beginning "Reactions:" sits in the body of some thread messages, and is set aside;
  * a mention is <@id> in a draft call and <@id|name> in a read result.
A read result with no message this can find is still COUNTED and said, a run in which no read result
could be read exits 4 and says nothing was measured, and --shapes prints what the results are made
of (L98, L177). What was NOT measured: any other line the connector writes under a message, what a
concise read looks like inside, and a read result too large for the session.

WHERE THE TEXT SITS is part of that layout, and matching headings say nothing about it. The text of
a message is read from the "messages" field of the result alone, as the lines under its Message TS
line, less any Reactions line. The connector's own account of a read says its default answer
"includes reactions + thread info", and no line for thread info was measured. So:
  * no other field of the result is read for a message: what "pagination_info" holds is no part of
    the last message of a read. A result whose JSON object has no "messages" string is counted as
    one this cannot read, and --shapes counts the other fields that hold text;
  * a message with no text under its Message TS line is counted, and is no post: never a pair;
  * a pair whose post BEGINS or ENDS in a line shaped like a label (a word or three and a colon, as
    From and Time are written) that its draft does not hold at that end is set aside and counted,
    since that line may be the connector's and not his;
  * the run exits 4 and says nothing was measured when most messages have no text there, or hold a
    line above the Message TS line that is neither From nor Time, or begin or end in such a label
    line;
  * --shapes counts the lines of text under and above the Message TS lines, and names a label line
    only when its name is in KNOWN_LABELS, a fixed list. Any other is counted by its length alone.
    It says where each label line sits: alone, first, last or inside the text.
These guards have not met a real read yet: the run that measured the layout was made before they
were written. They make a layout that differs fail aloud.

Exit codes: 0 measured; 2 a wrong argument; 3 the records folder or the decisions file could not be
read; 4 read results were there and none could be read, or the text of most messages is not where
this looks for it.
"""
import argparse
import collections
import datetime
import difflib
import html
import json
import os.path
import re
import sys

sys.stdout.reconfigure(errors="replace")
sys.stderr.reconfigure(errors="replace")

DRAFT_TOOL = "slack_send_message_draft"
THREAD_TOOL = "slack_read_thread"
CHANNEL_TOOL = "slack_read_channel"
# The errors Slack's draft tool names, and a JSON answer saying it did not work: threads.ts's list.
DRAFT_ERROR = re.compile(r'"ok"\s*:\s*false|\b(?:attached_draft_exists|channel_not_found|not_in_channel|'
                         r'failed_to_create_draft|invalid_thread_ts|thread_not_found)\b')

HEAVY = 0.70
SHORTER = 0.90
OPENING_WORDS = 6
FLOOR_PAIRS = 10
FLOOR_THREADS = 3
# A post more than this many minutes after the latest draft before it is not paired with that draft.
# A setting, chosen on 2026-11-27 from one measurement: on the work MacBook that day, of the 184
# pairs this reader made with no limit, 135 posts came within 10 minutes of their draft and 38 more
# within the hour (173 of 184); 11 came later, 4 of them more than a day later, and 9 of those 11
# read as heavily rewritten, which is what a post about something else paired with an old draft
# looks like (pull request 3848). An hour keeps the 173 and leaves the 11 out, counted. What it
# costs: a draft Dan sends, edited, more than an hour after it was saved is in no pair.
PAIR_WITHIN_MINUTES = 60
EXAMPLE_CHARS = 600

REPORTED = ("sent as drafted", "heavily rewritten")
OFFERED = ("figures cut", "length cut", "the ask reworded", "the opening changed")
# The answers in decisions.json that keep a kind from being offered again: SKIPPED in the skill's
# decisions.py, and the skill's suite fails when the two differ.
DECIDED_FOR_GOOD = ("accepted", "never")

# A channel message heading. The name can be EMPTY, and can carry an address in angle brackets, and
# the brackets can hold more fields than the member id: 198 headings with no name and three with an
# address were measured on the work MacBook on 2026-11-27, and the pattern that wanted a name and a
# bare id dropped the message under each one.
CHANNEL_HEAD = re.compile(r"^=== Message from\s*(.*?)\s*\(([^()]*)\) at .* ===\s*$")
MEMBER_ID = re.compile(r"\b[A-Z][A-Z0-9]{5,}\b")
PARENT_HEAD = re.compile(r"^=== THREAD PARENT MESSAGE ===\s*$")
REPLY_HEAD = re.compile(r"^--- Reply \d+ of \d+ ---\s*$")
# A heading of the shape "=== words (words) ===", as the one over a thread's replies: it holds no
# message (364 measured there, all in thread reads).
SECTION_HEAD = re.compile(r"^=== [^=()]+ \([^()]*\) ===\s*$")
OTHER_HEAD = re.compile(r"^(?:=== .* ===|--- .* ---)\s*$")
# A line the connector writes under the text of a message, measured there in 694 of 3,820 thread
# messages. It is no part of what was sent, so it is set aside wherever it sits in the body. A line
# of his own that begins with this word would go with it.
REACTIONS_LINE = re.compile(r"^Reactions:")
# A mention of a person is <@id> in a draft call and <@id|name> in a read result (measured there: in
# 39 of the 144 pairs counted as the opening changed, the openings differed only at the mention; with
# the name set aside, sent as drafted went from 2 pairs to 6). A channel (<#id|name>), a group
# (<!subteam^id|@name>) and a mention like <!here|here> are the same mechanism and are set aside the
# same way. Those three were NOT measured: no real read was seen to hold one.
MENTION = re.compile(r"<([@#!][^|<>\s]*)\|[^<>]*>")
CONCISE = "concise reads, which carry no time and cannot be paired"
FROM_LINE = re.compile(r"^From: (.+?)(?: \(([A-Z0-9]+)\))?\s*$")
TS_LINE = re.compile(r"^Message TS: (\d+\.\d+)\s*$")
TIME_LINE = re.compile(r"^Time: ")
# A line shaped as the connector writes its own: one to three words, the first capitalised, and a colon.
LABEL_LINE = re.compile(r"^([A-Z][A-Za-z]{0,20}(?: [A-Za-z]{1,20}){0,2}):(?: |$)")
# The only labels --shapes prints by name. A fixed list of plain structural words, none of them
# measured: it is here so that a first run on a Mac that holds read results can say which of them
# the connector writes, without printing a word of anybody's message.
KNOWN_LABELS = ("From", "Time", "Message TS", "Thread TS", "Reactions", "Reaction", "Files", "File",
                "Attachments", "Attachment", "Replies", "Reply count", "Latest reply", "Thread", "Edited",
                "Channel", "Type", "Subtype", "User", "Bot", "Link", "Permalink", "Pinned")
# The only keys of a read result's JSON object that --shapes prints by name: another fixed list of
# plain field names. A key not in it is counted by its length and never printed.
KNOWN_FIELDS = ("result", "results", "messages", "message", "channel_link", "pagination", "pagination_info",
                "next_cursor", "cursor", "has_more", "ok", "error", "warning", "channel", "channel_id",
                "thread_ts", "message_ts", "count", "total", "metadata", "response_metadata")
# What is counted about where the TEXT of a message sits. These are the names --shapes prints.
FOUND = "messages found (a heading with an author and a Message TS line)"
TEXT_LINES = "lines of text under a Message TS line"
NO_TEXT = "messages with no text under the Message TS line"
ABOVE = "messages with a line above the Message TS line that is neither From nor Time"
ABOVE_LINES = "lines above a Message TS line that are neither From nor Time"
LABELLED = "messages whose last line is shaped like a label"
LABELLED_FIRST = "messages whose first line is shaped like a label"
# The one field of a read result's JSON object that holds messages (measured: "messages" and
# "pagination_info" were the two fields of 1,731 results). No other field is read for a message.
MESSAGES_FIELD = "messages"
NO_MESSAGES_FIELD = "read results whose JSON object has no messages string"
# --likeness: the lower edge of each band of likeness between "the same" and heavily rewritten (HEAVY).
# Settings, not measurements: the issue's count of 2026-11-24 reported four bands and kept no record
# of where it drew them, so these are drawn finely enough to set beside any of the usual lines.
LIKENESS_BANDS = (0.98, 0.95, 0.90, 0.80)
ASK =re.compile(r"\?$|\b(?:can you|could you|would you|will you|do you|are you able|please|let me know|any chance)\b")
FIGURE = re.compile(r"\d[\d,]*(?:\.\d+)?")


def record_time(rec):
    """A record's time as seconds since 1970, or None when it carries none this can read."""
    stamp = rec.get("timestamp")
    if not isinstance(stamp, str):
        return None
    try:
        return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def result_text(item):
    """The text of a tool_result item, and whether it is marked as an error."""
    content = item.get("content")
    parts = []
    if isinstance(content, str):
        parts.append(content)
    elif isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and isinstance(block.get("text"), str):
                parts.append(block["text"])
    return "\n".join(parts), item.get("is_error") is True


def unwrap(text):
    """The connector answers with a JSON object whose "messages" string holds the messages. Returns
    the text to read for messages (None when the object has no such string), the object's field
    names, and the names of its OTHER fields that hold text. Text that is no JSON object is read as
    it is.

    Only that one field is read. Every string of the object used to be joined, so whatever
    "pagination_info" or any other field held became the last lines of the last message of the read,
    and was compared, and could be shown, as his words (the second review of pull request 3848, M3)."""
    try:
        parsed = json.loads(text)
    except ValueError:
        return text, [], []
    if not isinstance(parsed, dict):
        return text, [], []
    inner = parsed.get(MESSAGES_FIELD)
    other = sorted(str(k) for k, v in parsed.items() if k != MESSAGES_FIELD and isinstance(v, str) and v.strip())
    return (inner if isinstance(inner, str) else None), sorted(str(k) for k in parsed), other


def label_of(line):
    """The name of the label a line is shaped like, or "" when it is not shaped like one."""
    m = LABEL_LINE.match(line)
    return m.group(1) if m else ""


def label_seen(line, where, shape):
    """Counts a line shaped like a label for --shapes: by name when the name is one of KNOWN_LABELS,
    and by its length alone when it is not, since it can then be the start of somebody's message."""
    name = label_of(line)
    if not name:
        return
    if name in KNOWN_LABELS:
        shape["label lines %s a Message TS line, %s" % (where, name)] += 1
    else:
        shape["label lines %s a Message TS line, not a known name, of %d characters" % (where, len(name))] += 1


def end_labels(text):
    """The label names of the first and of the last line of a text that holds words: ("", "") for
    a text whose ends are not shaped like a label."""
    lines = [x for x in text.split("\n") if x.strip()]
    return (label_of(lines[0]), label_of(lines[-1])) if lines else ("", "")


def posts_in(text, shape):
    """Each message WITH TEXT in a read result as (ts, name, member id, body, final), where final
    says it is the last message of this read. shape counts what was seen, including the messages
    found with no text under their Message TS line, which are no post here: unread."""
    posts = []
    cur = None

    def close():
        if cur is None:
            return
        # Whatever is under the last heading of a read is the end of the field, where anything the
        # connector writes after the messages would land. Only a post made from it is the final one.
        if posts:
            posts[-1][4] = False
        if not (cur["ts"] and (cur["name"] or cur["uid"])):
            shape["headings with no author or no Message TS under them"] += 1
            return
        kept = [x for x in cur["body"] if not REACTIONS_LINE.match(x)]
        shape["Reactions lines under a message, set aside"] += len(cur["body"]) - len(kept)
        cur["body"] = kept
        lines = [x for x in kept if x.strip()]
        shape[FOUND] += 1
        shape[TEXT_LINES] += len(lines)
        if cur["above"]:
            shape[ABOVE] += 1
        if not lines:
            shape[NO_TEXT] += 1
            return
        # Where a label shaped line sits is said, since a line of the connector's own would sit at one
        # end of the text: right under the Message TS line, or under the last line of the message.
        for i, x in enumerate(lines):
            if len(lines) == 1:
                where = "alone under"
            elif i == 0:
                where = "first under"
            elif i == len(lines) - 1:
                where = "last under"
            else:
                where = "inside the text under"
            label_seen(x, where, shape)
        if label_of(lines[0]):
            shape[LABELLED_FIRST] += 1
        if label_of(lines[-1]):
            shape[LABELLED] += 1
        posts.append([cur["ts"], cur["name"], cur["uid"], "\n".join(cur["body"]).strip(), True])

    for line in text.split("\n"):
        m = CHANNEL_HEAD.match(line)
        if m:
            close()
            shape["channel message headings"] += 1
            uid = MEMBER_ID.search(m.group(2))
            cur = {"name": m.group(1), "uid": uid.group(0) if uid else "", "ts": "", "body": [], "above": 0}
            continue
        if PARENT_HEAD.match(line) or REPLY_HEAD.match(line):
            close()
            shape["thread parent headings" if PARENT_HEAD.match(line) else "thread reply headings"] += 1
            cur = {"name": "", "uid": "", "ts": "", "body": [], "above": 0}
            continue
        if SECTION_HEAD.match(line) or OTHER_HEAD.match(line):
            close()
            shape["section headings with no message under them" if SECTION_HEAD.match(line) else "other headings"] += 1
            cur = None
            continue
        if cur is None:
            continue
        if not cur["ts"]:
            m = FROM_LINE.match(line)
            if m and not cur["name"] and not cur["uid"]:
                shape["From lines"] += 1
                cur["name"], cur["uid"] = m.group(1), m.group(2) or ""
                continue
            m = TS_LINE.match(line)
            if m:
                shape["Message TS lines"] += 1
                cur["ts"] = m.group(1)
            elif TIME_LINE.match(line):
                shape["Time lines"] += 1
            elif line.strip():
                # A line this does not know, where only From and Time are expected: the text may sit here.
                cur["above"] += 1
                shape[ABOVE_LINES] += 1
                label_seen(line, "above", shape)
            continue
        cur["body"].append(line)
    close()
    return posts


def read_records(root, shape):
    """Every saved draft and every message read back, from the record files under root."""
    drafts = {}   # call id -> {"place", "text", "at"}
    saved = {}    # call id -> whether Slack saved it
    reads = {}    # call id -> (tool, channel, parent ts, whether it asked for the concise layout, its time)
    concise = {}  # place -> the latest time a concise read read it back (None: a time this could not read)
    posts = {}    # (channel, ts) -> (place, name, member id, body, whether it was the last message of its read)
    done = set()  # read call ids whose result was taken
    files = 0

    def unread(_error):  # a folder os.walk could not list is counted and said, never passed over
        shape["folders that could not be read"] += 1

    for folder, _dirs, names in os.walk(root, onerror=unread):
        for name in sorted(names):
            if not name.endswith(".jsonl"):
                continue
            try:
                with open(os.path.join(folder, name), "rb") as f:
                    raw = f.read()
            except OSError:
                shape["record files that could not be opened"] += 1
                continue
            files += 1
            if b"slack_" not in raw:
                continue
            for line in raw.split(b"\n"):
                if b"tool_use" not in line and b"tool_result" not in line:
                    continue
                try:
                    rec = json.loads(line.decode("utf-8", "replace"))
                except ValueError:
                    continue
                message = rec.get("message") if isinstance(rec, dict) else None
                content = message.get("content") if isinstance(message, dict) else None
                if not isinstance(content, list):
                    continue
                for item in content:
                    if not isinstance(item, dict):
                        continue
                    if item.get("type") == "tool_use":
                        take_call(item, rec, drafts, reads)
                    elif item.get("type") == "tool_result":
                        take_result(item, drafts, saved, reads, posts, done, shape, concise)
    return files, drafts, saved, posts, concise


def take_call(item, rec, drafts, reads):
    tool = str(item.get("name") or "")
    call = item.get("id")
    args = item.get("input")
    if not tool.startswith("mcp__") or not isinstance(call, str) or not isinstance(args, dict):
        return
    channel = args.get("channel_id")
    if not isinstance(channel, str) or not channel:
        return
    if tool.endswith("__" + DRAFT_TOOL):
        text = args.get("message")
        if not isinstance(text, str):
            return
        thread = args.get("thread_ts")
        at = record_time(rec)
        known = drafts.get(call)
        # A resumed session and the kept copy of a request repeat a call: one draft, at its earliest time.
        if known is None or (at is not None and (known["at"] is None or at < known["at"])):
            drafts[call] = {"place": (channel, thread if isinstance(thread, str) else ""), "text": text, "at": at}
    elif tool.endswith("__" + THREAD_TOOL) or tool.endswith("__" + CHANNEL_TOOL):
        which = THREAD_TOOL if tool.endswith("__" + THREAD_TOOL) else CHANNEL_TOOL
        parent = args.get("message_ts") if which == THREAD_TOOL else ""
        if which == THREAD_TOOL and not (isinstance(parent, str) and parent):
            return
        # A read that asked for the concise layout is answered with no heading, no From line and no
        # Message TS line (measured on the work MacBook on 2026-11-27: 998 such reads, 24 of them
        # holding any number shaped like a message time). Its posts cannot be placed in time, so it
        # is its own kind, and no pairing is guessed for it.
        short = args.get("response_format") == "concise"
        at = record_time(rec)
        known = reads.get(call)
        if known is not None and known[4] is not None and (at is None or known[4] > at):
            at = known[4]  # the copies of one call: its latest known time
        reads[call] = (which, channel, parent, short, at)


def take_result(item, drafts, saved, reads, posts, done, shape, concise):
    call = item.get("tool_use_id")
    if not isinstance(call, str):
        # No call has such an id (take_call keeps strings only), and a list here stopped the run with
        # a traceback. Passed over, and counted, so that it is in a count (L11).
        shape["tool results whose call id is no string, passed over"] += 1
        return
    if call in drafts:
        text, error = result_text(item)
        saved[call] = saved.get(call, False) or (not error and not DRAFT_ERROR.search(text))
        return
    if call not in reads or call in done:
        return
    done.add(call)
    tool, channel, parent, short, read_at = reads[call]
    text, error = result_text(item)
    shape["read results"] += 1
    if error:
        shape["read results marked as an error"] += 1
        return
    if short:
        shape[CONCISE] += 1
        place = (channel, parent)
        # The place it read back, and when, so a draft there can be said to have been read back this
        # way. None stands for a time this could not read, which is taken as after any draft.
        if place not in concise or read_at is None or (concise[place] is not None and read_at > concise[place]):
            concise[place] = read_at
        return
    inner, fields, holding = unwrap(text)
    for field in fields:
        # A key is printed only when it is one of KNOWN_FIELDS. Any other could be anything, a
        # sentence of somebody's included, so only its length is counted (the review, S1).
        if field in KNOWN_FIELDS:
            shape["result field " + field] += 1
        else:
            shape["result fields not in the fixed list, of %d characters" % len(field)] += 1
    for field in holding:
        # The other fields that hold text, which is read for no message. Counted, never printed.
        if field in KNOWN_FIELDS:
            shape["result field %s, holding text" % field] += 1
        else:
            shape["result fields not in the fixed list, holding text, of %d characters" % len(field)] += 1
    if inner is None:
        # A JSON object with no "messages" string. Its text is not looked for under another key:
        # that would be a guess at a layout nobody measured.
        shape[NO_MESSAGES_FIELD] += 1
        shape["in a layout this cannot read"] += 1
        return
    found = posts_in(inner, shape)
    if not found:
        # No message with text: no heading this knows, or every message's text is somewhere else.
        shape["in a layout this cannot read"] += 1
        return
    shape["read results with messages"] += 1
    for ts, name, uid, body, final in found:
        place = (channel, "") if tool == CHANNEL_TOOL or ts == parent else (channel, parent)
        known = posts.get((channel, ts))
        if known is not None and known[0][1] and not place[1]:
            # Already read inside its thread. A reply Slack also shows in the channel is ONE post, in
            # its thread, whichever read came first: it is never a second post at the top (S6).
            place = known[0]
        posts[(channel, ts)] = (place, name, uid, body, final)


def sentences(text):
    """The text with Slack's formatting set aside, as a list of sentences in lower case."""
    t = html.unescape(text)
    t = MENTION.sub(r"<\1>", t)
    t = re.sub(r"<(?:https?|mailto):[^|>\s]+\|([^>]*)>", r"\1", t)
    t = re.sub(r"<((?:https?|mailto):[^>\s]+)>", r"\1", t)
    t = re.sub(r"\[([^\]]+)\]\((?:https?|mailto):[^)\s]+\)", r"\1", t)
    t = re.sub(r"(?m)^[ \t]*>[ \t]?", "", t)
    t = re.sub(r"(?m)^[ \t]*(?:[-*•◦▪]|\d+[.)])[ \t]+", "", t)
    t = re.sub(r"[*_~`]", "", t)
    out = []
    for part in re.split(r"(?<=[.?!])\s+|\n+", t):
        part = re.sub(r"\s+", " ", part).strip().lower()
        if part:
            out.append(part)
    return out


def kinds_of(draft, sent):
    """The kinds of edit between a draft and what was sent, and their likeness (1 is the same words).

    A heavily rewritten pair is that and nothing else. A post that far from the draft before it may
    not be an edit of it at all (a draft he never sent, then a post about something else), and such a
    pair reads as figures cut, length cut and the opening changed all at once. Counted there, twelve
    drafts nobody sent offered four rules (the review of pull request 3848, M2). What that costs: a
    draft cut to under about half its length is heavily rewritten by this measure, and so is in no
    kind either."""
    d, s = sentences(draft), sentences(sent)
    dt, st = " ".join(d), " ".join(s)
    if dt == st:
        return ["sent as drafted"], 1.0
    likeness = difflib.SequenceMatcher(None, dt.split(), st.split(), autojunk=False).ratio()
    if likeness < HEAVY:
        return ["heavily rewritten"], likeness
    kinds = []
    if len(FIGURE.findall(st)) < len(FIGURE.findall(dt)):
        kinds.append("figures cut")
    if len(st) < SHORTER * len(dt):
        kinds.append("length cut")
    d_asks, s_asks = {x for x in d if ASK.search(x)}, {x for x in s if ASK.search(x)}
    if d_asks and s_asks and d_asks != s_asks:
        kinds.append("the ask reworded")
    if dt.split()[:OPENING_WORDS] != st.split()[:OPENING_WORDS]:
        kinds.append("the opening changed")
    return kinds, likeness


def may_be_connectors(draft, sent):
    """Whether the first or the last line of what was read back is shaped like a label that the draft
    does not hold at that same end. Such a line may be the connector's and not his: the connector's
    own account of a read says it "includes reactions + thread info", and where a thread info line
    sits was never measured, right under the Message TS line or under the text.

    A label line the DRAFT holds at the same end, by the same name, is his: "Update: ..." as the
    first line of both is no line of the connector's. What this still gets wrong, on the harmless
    side (L648): a line like that which he ADDED by hand is set aside with the connector's, so that
    pair is in no count; and a connector line whose label happens to be the one his draft begins or
    ends with is compared as his words."""
    d_first, d_last = end_labels(draft)
    s_first, s_last = end_labels(sent)
    return bool((s_first and s_first != d_first) or (s_last and s_last != d_last))


def pair_up(drafts, saved, posts, author, concise):
    """Pairs as (place, post time, draft text, sent text, whether the post was the last message of
    the read its text was taken from), and what was left out."""
    want = author.strip().lower()
    by_place = collections.defaultdict(list)
    for call, d in drafts.items():
        if saved.get(call) and d["at"] is not None:
            by_place[d["place"]].append((d["at"], call, d["text"]))
    mine = collections.defaultdict(list)
    for (_channel, ts), (place, name, uid, body, final) in posts.items():
        if uid.lower() == want or name.strip().lower() == want:
            mine[place].append((float(ts), body, final))
    pairs, used, no_draft, doubtful = [], set(), 0, 0
    late, late_posts = set(), 0
    paired_at, closer = {}, 0  # draft call -> the likeness of the pair it made
    for place, sent in mine.items():
        ds = sorted(by_place.get(place, []))
        for at, body, final in sorted(sent):
            before = [d for d in ds if d[0] < at]
            labelled = bool(before) and may_be_connectors(before[-1][2], body)
            if not before or before[-1][1] in used:
                no_draft += 1
                # The first post after a draft takes it. When this later one is MORE like that draft,
                # the pair made may be the wrong one, so it is counted. The rule is not changed here:
                # whether the likeliest post should take the draft is for Dan (pull request 3848).
                # Only a post inside the limit is counted: one past it could never have taken the draft.
                took = paired_at.get(before[-1][1]) if before else None
                if (took is not None and not labelled and at - before[-1][0] <= PAIR_WITHIN_MINUTES * 60
                        and kinds_of(before[-1][2], body)[1] > took):
                    closer += 1
                continue
            if at - before[-1][0] > PAIR_WITHIN_MINUTES * 60:
                # Too long after that draft to be read as what became of it: neither is in a pair.
                late_posts += 1
                late.add(before[-1][1])
                continue
            used.add(before[-1][1])
            if labelled:
                # Its first or last line may be the connector's and not his, so the pair is set aside
                # and counted: compared, a post sent word for word would read as edited (L648).
                doubtful += 1
                continue
            paired_at[before[-1][1]] = kinds_of(before[-1][2], body)[1]
            pairs.append((place, at, before[-1][2], body, final))
    replaced = unread = unread_concise = 0
    for place, ds in by_place.items():
        ds.sort()
        for i, (at, call, _text) in enumerate(ds):
            if call in used or call in late:
                continue
            # Replaced when a later draft in the same place was the one a post was compared with.
            if any(later[1] in used for later in ds[i + 1:]):
                replaced += 1
            else:
                unread += 1
                # Read back afterwards by a concise read, which shows no time: a post may be there.
                if place in concise and (concise[place] is None or concise[place] > at):
                    unread_concise += 1
    # A saved draft kept only in the copy of a request has no time, so nothing can be said to come
    # after it. It is in no pair, and it is counted so that it is in a count (S7).
    untimed = sum(1 for call, d in drafts.items() if saved.get(call) and d["at"] is None)
    return sorted(pairs, key=lambda p: p[1]), {"unread": unread, "replaced": replaced, "no_draft": no_draft,
                                               "doubtful": doubtful, "late_posts": late_posts,
                                               "late_drafts": len(late), "untimed": untimed,
                                               "unread_concise": unread_concise, "closer": closer}


def decisions_path():
    """Where the draft-edit-review skill's decisions.py keeps what Dan decided, on this Mac."""
    return os.path.join(os.path.expanduser("~"), ".claude", "state", "draft-edit-review", "decisions.json")


def decided_kinds():
    """The kinds Dan accepted or said never to offer again, read from the file decisions.py writes.

    Returns (kinds, None), or (None, why) when the file is there and cannot be read: that is never
    taken as nothing decided, which would put to him again what he declined. Reading it HERE is what
    makes "never" hold: it used to depend on the session passing --skip for each kind (S2)."""
    path = decisions_path()
    if not os.path.lexists(path):
        return set(), None
    try:
        with open(path, "rb") as f:
            data = json.loads(f.read().decode("utf-8", "replace"))
    except OSError as e:
        return None, "%s could not be read (%s)" % (path, e.strerror or e)
    except ValueError:
        return None, "%s could not be read (it is not JSON)" % path
    found = data.get("decisions") if isinstance(data, dict) else None
    if not isinstance(found, dict):
        return None, "%s could not be read (it holds no decisions object)" % path
    kinds = set()
    for kind, entry in found.items():
        answer = entry.get("decision") if isinstance(entry, dict) else None
        if kind not in OFFERED or answer not in ("accepted", "not-now", "never"):
            return None, "%s could not be read (an entry in it is not one decisions.py writes)" % path
        if answer in DECIDED_FOR_GOOD:
            kinds.add(kind)
    return kinds, None


ANGLED = re.compile(r"<[^<>\n]*>")
LINKISH = re.compile(r"<(?:https?|mailto):[^>\n]*>|\[[^\]\n]+\]\((?:https?|mailto):[^)\s]+\)|(?:https?://|mailto:)\S+")
EDITED_MARK = re.compile(r"\s*\(edited\)\s*$")
EMOJI_NAME = re.compile(r":[a-z0-9_+\-]+:")


def joined(text):
    return " ".join(sentences(text))


def no_emoji(text):
    """The text with emoji taken out, whether written as a :name: or as a character."""
    text = EMOJI_NAME.sub("", text)
    return "".join(c for c in text if not (0x2190 <= ord(c) <= 0x2BFF or 0xFE00 <= ord(c) <= 0xFE0F
                                           or 0x1F000 <= ord(c) <= 0x1FAFF or ord(c) == 0x200D))


def last_line_off(text):
    lines = [x for x in text.split("\n") if x.strip()]
    return "\n".join(lines[:-1]) if len(lines) > 1 else text


def first_line_off(text):
    lines = [x for x in text.split("\n") if x.strip()]
    return "\n".join(lines[1:]) if len(lines) > 1 else text


# --differences: one thing a read result may add or write another way, and what setting it aside
# means. NONE of these was measured: on the work MacBook on 2026-11-27, 6 of 184 pairs read as sent
# as drafted against 22 of 106 in the issue's measurement three days earlier, and counts could not
# say whether the rest are Dan's edits or a difference in how a read writes a message. This prints
# how many changed pairs each one would explain, so the next run can tell. Counts only.
SET_ASIDE = (
    ("what is inside angle brackets is set aside (a mention, a group or a link with a name added)",
     lambda d, s: joined(ANGLED.sub("<>", d)) == joined(ANGLED.sub("<>", s))),
    ("how a link is written is set aside",
     lambda d, s: joined(LINKISH.sub("LINK", d)) == joined(LINKISH.sub("LINK", s))),
    ("punctuation, symbols and spacing are set aside",
     lambda d, s: re.sub(r"[^a-z0-9]+", "", joined(d)) == re.sub(r"[^a-z0-9]+", "", joined(s))),
    ("emoji are set aside (a :name: or a character)",
     lambda d, s: joined(no_emoji(d)) == joined(no_emoji(s))),
    ("a trailing (edited) is set aside",
     lambda d, s: EDITED_MARK.search(s) is not None and joined(d) == joined(EDITED_MARK.sub("", s))),
    ("the last line of what was read back is set aside",
     lambda d, s: last_line_off(s) != s and joined(d) == joined(last_line_off(s))),
    ("the first line of what was read back is set aside",
     lambda d, s: first_line_off(s) != s and joined(d) == joined(first_line_off(s))),
)


def differences(draft, sent):
    """The names in SET_ASIDE under which this pair, which differs, would be the same."""
    return [name for name, test in SET_ASIDE if test(draft, sent)]


def cut(text):
    return text if len(text) <= EXAMPLE_CHARS else text[:EXAMPLE_CHARS] + " (cut at %d characters)" % EXAMPLE_CHARS


def plural(n, word):
    return "%d %s" % (n, word if n == 1 else word + "s")


def print_shapes(shape):
    print("How the Slack read results in these records are laid out (counts, and names from two fixed lists only)")
    for key in sorted(shape):
        print("  %s: %d" % (key, shape[key]))


def main():
    parser = argparse.ArgumentParser(description="Compare saved Slack drafts with what was sent. Prints only.")
    parser.add_argument("--records", default=os.path.join(os.path.expanduser("~"), ".claude", "projects"))
    parser.add_argument("--author", default="")
    parser.add_argument("--examples", action="store_true")
    parser.add_argument("--skip", action="append", default=[])
    parser.add_argument("--shapes", action="store_true")
    parser.add_argument("--differences", action="store_true")
    parser.add_argument("--likeness", action="store_true")
    args = parser.parse_args()
    for kind in args.skip:
        if kind not in OFFERED:
            print("draft-edit-diff: --skip takes one of: " + "; ".join(OFFERED) + ". Got: " + kind[:60], file=sys.stderr)
            return 2
    if not args.author.strip() and not args.shapes:
        print("draft-edit-diff: pass --author with the Slack member id, or the name as Slack shows it, of the "
              "person whose posts are compared with the drafts. Nothing was read.", file=sys.stderr)
        return 2
    if not os.path.isdir(args.records):
        print("draft-edit-diff: the records folder %s could not be read, so nothing was measured." % args.records,
              file=sys.stderr)
        return 3
    decided = set()
    if not args.shapes:
        decided, why = decided_kinds()
        if decided is None:
            print("draft-edit-diff: %s, so a kind Dan declined could be offered to him again. Nothing was "
                  "measured, and nothing here is read as undecided." % why, file=sys.stderr)
            return 3
    skipped = decided | set(args.skip)
    shape = collections.Counter()
    for key in (FOUND, TEXT_LINES, NO_TEXT, ABOVE, ABOVE_LINES, LABELLED, LABELLED_FIRST, CONCISE, NO_MESSAGES_FIELD):
        shape[key] = 0  # printed by --shapes at zero too: where the text sits is what a first run checks
    files, drafts, saved, posts, concise = read_records(args.records, shape)
    n_saved = sum(1 for call in drafts if saved.get(call))
    shape["draft calls"] = len(drafts)
    shape["draft calls Slack saved"] = n_saved
    shape["messages read back"] = len(posts)
    if args.shapes:
        print_shapes(shape)
        return 0
    pairs, left = pair_up(drafts, saved, posts, args.author, concise)
    unreadable = shape["in a layout this cannot read"]
    print("Slack drafts compared with what was sent")
    blind = shape["folders that could not be read"]
    print("record files read: %d (could not be opened: %d; folders that could not be read: %d)" % (
        files, shape["record files that could not be opened"], blind))
    if blind and not files:
        print("draft-edit-diff: no record file under %s could be reached, so nothing was measured." % args.records,
              file=sys.stderr)
        return 3
    if blind:
        print("Records in a folder that could not be read are in none of the counts below.")
    print("draft calls: %d (saved: %d)" % (len(drafts), n_saved))
    print("read results: %d (with messages: %d, marked as an error: %d)" % (
        shape["read results"], shape["read results with messages"], shape["read results marked as an error"]))
    print("%s: %d. A post read back only that way is in none of the counts below." % (CONCISE, shape[CONCISE]))
    if unreadable:
        print("read results in a layout this cannot read: %d. Their messages are in none of the counts below; "
              "run this with --shapes to see what they are made of." % unreadable)
    found, wordless = shape[FOUND], shape[NO_TEXT]
    print("messages found in them: %d (no text under the Message TS line: %d; a line above it that is neither "
          "From nor Time: %d; last line shaped like a label: %d; first line shaped like a label: %d)" % (
              found, wordless, shape[ABOVE], shape[LABELLED], shape[LABELLED_FIRST]))
    if shape["read results"] and not shape["read results with messages"] and (unreadable or shape[CONCISE]):
        if not unreadable:
            print("Nothing was measured: every thread or channel read in the records is a concise read, which "
                  "shows no time for a post, so no draft can be paired with what was sent.")
        else:
            print("Nothing was measured: thread or channel reads are in the records and not one could be read, so "
                  "a count of pairs here would be a count of this program's blind spot.")
        return 4
    # The headings can all match while the TEXT sits where this does not look (review M1). Each of the
    # four is a failure when it is true of most messages, never a count: a post read with no text, or
    # with a line of the connector's own in it, is compared as an edit Dan never made. The label line
    # is looked for at BOTH ends of the text: right under the Message TS line it made every opening
    # read as changed, and a rule was offered from twelve posts sent word for word (second review, M2).
    misplaced = ""
    if 2 * wordless > found:
        misplaced = "most of the messages found have no text under their Message TS line"
    elif 2 * shape[ABOVE] > found:
        misplaced = "most of the messages found hold a line above their Message TS line that is neither From nor Time"
    elif 2 * shape[LABELLED] > found - wordless:
        misplaced = ("most of the messages found end in a line shaped like a label (a word or three and a colon), "
                     "which is how the connector writes its own lines")
    elif 2 * shape[LABELLED_FIRST] > found - wordless:
        misplaced = ("most of the messages found begin with a line shaped like a label (a word or three and a "
                     "colon), which is how the connector writes its own lines")
    if misplaced:
        print("Nothing was measured: %s, so the text of a message is not where this looks for it. Run this with "
              "--shapes to see how the lines are laid out." % misplaced)
        return 4
    if not n_saved:
        print("No saved draft is in these records, so there is nothing to compare on this Mac. Every count "
              "below is zero for that reason, and says nothing about how drafts are edited.")
    threads = {p[0] for p in pairs}
    print("pairs: %d in %s" % (len(pairs), plural(len(threads), "thread")))
    print("left out: drafts with no post read back after them: %d; drafts replaced by a later draft: %d; "
          "posts with no draft before them: %d" % (left["unread"], left["replaced"], left["no_draft"]))
    print("drafts with no post read back: of those, in a place a concise read read back afterwards: %d (a post "
          "may be there, and a concise read shows no time to pair it by)" % left["unread_concise"])
    print("posts whose draft was already paired: of those, more like that draft than the post it was paired "
          "with: %d (the first post after a draft takes it; only a later post within %d minutes of the draft "
          "is counted)" % (left["closer"], PAIR_WITHIN_MINUTES))
    print("also left out: pairs whose post begins or ends in a line shaped like a label that its draft does not "
          "hold there: %d (that line may be the connector's and not his; one he added by hand is left out with "
          "it)" % left["doubtful"])
    print("also left out: posts more than %d minutes after the draft before them: %d (drafts: %d). The %d "
          "minutes is a setting, chosen on 2026-11-27 from one Mac's pairs that day." % (
              PAIR_WITHIN_MINUTES, left["late_posts"], left["late_drafts"], PAIR_WITHIN_MINUTES))
    print("also left out: saved drafts with no time on their record: %d (nothing can be said to come after "
          "one)" % left["untimed"])
    tally = collections.defaultdict(list)
    banded = []  # (likeness, whether sent as drafted, whether the post was the last message of its read)
    for place, at, draft, sent, final in pairs:
        kinds, likeness = kinds_of(draft, sent)
        banded.append((likeness, kinds == ["sent as drafted"], final))
        for kind in kinds or ["changed, in no kind"]:
            tally[kind].append((place, at, draft, sent, likeness))
    for kind in REPORTED:
        print("%s: %d of %s" % (kind, len(tally[kind]), plural(len(pairs), "pair")))
    # A pair that differs, is not heavily rewritten and is in none of the four kinds was in no line.
    print("changed, in none of the four kinds: %d of %s" % (len(tally["changed, in no kind"]), plural(len(pairs), "pair")))
    print("kept out of the four kinds below and of the floor, as heavily rewritten: %d (a post that far from "
          "the draft before it may not be an edit of it)" % len(tally["heavily rewritten"]))
    examples = []
    for kind in OFFERED:
        found = tally[kind]
        in_threads = len({p[0] for p in found})
        if kind in skipped:
            standing = "decided before, not offered"
        elif len(found) >= FLOOR_PAIRS and in_threads >= FLOOR_THREADS:
            standing = "recurring"
            examples.append(kind)
        else:
            standing = "too thin to offer a rule (it takes at least %d pairs in at least %d threads)" % (
                FLOOR_PAIRS, FLOOR_THREADS)
        print("%s: %d of %s, in %s: %s" % (kind, len(found), plural(len(pairs), "pair"),
                                          plural(in_threads, "thread"), standing))
    if args.examples:
        for kind in examples:
            # The pair of that kind most like its draft, and the latest of those: the one that shows
            # the edit with least else changed. The latest pair alone can be the least like one (S10).
            _place, _at, draft, sent, _likeness = max(tally[kind], key=lambda p: (p[4], p[1]))
            print("")
            print("Example for %s (Slack message text: show it to Dan, and copy it nowhere)" % kind)
            print("DRAFT: " + cut(draft))
            print("SENT: " + cut(sent))
    if args.differences:
        changed = {}  # a pair can be under several kinds, and is one pair: keyed by its place and time
        for kind in OFFERED + ("changed, in no kind",):
            for place, at, draft, sent, _likeness in tally[kind]:
                changed[(place, at)] = (draft, sent)
        counts = collections.Counter()
        explained = set()  # the pairs that one of those things alone would make the same
        for key, (draft, sent) in changed.items():
            found = differences(draft, sent)
            if found:
                explained.add(key)
            for name in found or ["none of these"]:
                counts[name] += 1
        print("")
        print("How the pairs changed but not heavily rewritten differ (counts only; a pair can be on more than "
              "one line)")
        print("pairs changed but not heavily rewritten: %d" % len(changed))
        for name, _test in SET_ASIDE:
            print("  the same once %s: %d" % (name, counts[name]))
        print("  none of these: %d" % counts["none of these"])
        # The same count for each kind a rule can be offered for, so the number a rule rests on is never
        # put to Dan without how much of it a difference in how a read is written could account for. It is
        # an upper bound and no more: punctuation, an emoji and a first or last line are also edits he makes.
        print("Of the pairs under each kind, how many one of the things above would make the same (an upper bound "
              "on how many may be no edit of his: he also changes punctuation, and adds and cuts lines)")
        for kind in OFFERED:
            under = {(place, at) for place, at, _draft, _sent, _likeness in tally[kind]}
            print("  %s: %d of %s" % (kind, len(under & explained), plural(len(under), "pair")))
    if args.likeness:
        # --likeness: how many pairs sit in each band of likeness. Counts only. It is here because the
        # issue's count of 2026-11-24 read 22 of 106 pairs as sent as drafted and the first run of this
        # reader read 6 of 184, and the likeliest cause is that the two meant different things by it:
        # this wants the two texts the same once formatting is set aside, and the issue reported four
        # bands of likeness. If that is the cause, about a fifth of the pairs sit in the top lines here.
        same = sum(1 for _likeness, as_drafted, _final in banded if as_drafted)
        rest = sorted(likeness for likeness, as_drafted, _final in banded if not as_drafted)
        print("")
        print("How like its draft each post is (counts only; likeness is the share of the words the two have in "
              "common, after formatting is set aside)")
        print("pairs by how like their draft they are: %d" % len(banded))
        print("  the same once formatting is set aside: %d" % same)
        upper = None
        for edge in LIKENESS_BANDS + (HEAVY,):
            n = sum(1 for likeness in rest if likeness >= edge and (upper is None or likeness < upper))
            if upper is None:
                print("  not the same, %.2f and over: %d" % (edge, n))
            else:
                print("  %.2f to under %.2f: %d" % (edge, upper, n))
            upper = edge
        print("  under %.2f, heavily rewritten: %d" % (HEAVY, sum(1 for likeness in rest if likeness < HEAVY)))
        # Whatever the connector writes after the messages of a read lands under the last one, so a
        # share sent as drafted that is lower among those posts than among the others points there.
        last = [as_drafted for _likeness, as_drafted, final in banded if final]
        other = [as_drafted for _likeness, as_drafted, final in banded if not final]
        print("posts that were the last message of the read their text was taken from: %d of %s (sent as drafted: "
              "%d of those %d, and %d of the other %d)" % (len(last), plural(len(banded), "pair"), sum(last),
                                                           len(last), sum(other), len(other)))
    return 0


sys.exit(main())
