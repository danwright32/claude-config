#!/usr/bin/env python3
"""draft-edit-diff.py: compare each Slack draft a session saved with what was sent (claude-config#3554).

Sessions save every Slack message as a draft, and Dan edits it before he sends it. Nothing read
back what he sent, so the same edits were made by hand every day. This reads this Mac's session
records, pairs each saved draft with the post that followed it, and prints how often each kind of
edit was made, with the number of pairs each count rests on.

    python3 draft-edit-diff.py --author <Slack member id or display name> [--records <folder>]
                               [--examples] [--skip "<kind>"]... [--shapes]

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
  * A post more than PAIR_WITHIN_DAYS days after that draft is not paired with it. Both are left
    out and counted.
  * Both are compared after Slack's formatting is set aside (links, bold, italics, bullets, quote
    markers at the start of a line, the name a read adds inside a mention, spacing and case), by
    words, with difflib.
  * The FIRST post after a draft takes it. A later post that is more like that draft is left out
    and counted, so the count says how often that rule may have made the wrong pair.

WHAT IT CANNOT SEE, so nobody reads more into a count than it measured.
  * A thread no later session read back. Its draft is counted as having no post read back after it.
  * A draft Dan deleted. If he wrote something else in that thread within PAIR_WITHIN_DAYS days, the
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
  * How the connector shows a mention, an emoji or a quotation mark against how the draft wrote it.
    Only links, bold, italics, bullets, quote markers at the start of a line, spacing and case are
    set aside, so a draft that opens with a mention can read as the opening changed.
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
a message is read as the lines under its Message TS line, less any Reactions line. The connector's
own account of a read says its default answer "includes reactions + thread info", and no line for
thread info was measured. So:
  * a message with no text under its Message TS line is counted, and is no post: never a pair;
  * a pair whose post ends in a line shaped like a label (a word or three and a colon, as From and
    Time are written) is set aside and counted, since that line may be the connector's and not his;
  * the run exits 4 and says nothing was measured when most messages have no text there, or hold a
    line above the Message TS line that is neither From nor Time, or end in such a label line;
  * --shapes counts the lines of text under and above the Message TS lines, and names a label line
    only when its name is in KNOWN_LABELS, a fixed list. Any other is counted by its length alone.
These four guards have not met a real read yet: the run that measured the layout was made before
they were written. They make a layout that differs fail aloud.

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
# A post more than this many days after the latest draft before it is not paired with that draft.
# A setting chosen on 2026-11-27, not a measurement: nobody has measured how long Dan takes to send a
# draft. A week is long enough for a draft left over a weekend and short enough that a thread he
# comes back to next month is not read as an edit of a draft he dropped.
PAIR_WITHIN_DAYS = 7
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
# A mention is <@id> in a draft call and <@id|name> in a read result (measured there: 39 of 144
# pairs counted as the opening changed differed in nothing else).
MENTION = re.compile(r"<@([A-Za-z0-9]+)\|[^>]*>")
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
ASK = re.compile(r"\?$|\b(?:can you|could you|would you|will you|do you|are you able|please|let me know|any chance)\b")
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
    """The connector answers with a JSON object whose strings hold the messages. Returns the text to
    read for messages and the object's field names; text that is no JSON object is read as it is."""
    try:
        parsed = json.loads(text)
    except ValueError:
        return text, []
    if not isinstance(parsed, dict):
        return text, []
    strings = [v for v in parsed.values() if isinstance(v, str)]
    return "\n".join(strings), sorted(str(k) for k in parsed)


def label_seen(line, where, shape):
    """Counts a line shaped like a label for --shapes: by name when the name is one of KNOWN_LABELS,
    and by its length alone when it is not, since it can then be the start of somebody's message."""
    m = LABEL_LINE.match(line)
    if not m:
        return
    name = m.group(1)
    if name in KNOWN_LABELS:
        shape["label lines %s a Message TS line, %s" % (where, name)] += 1
    else:
        shape["label lines %s a Message TS line, not a known name, of %d characters" % (where, len(name))] += 1


def posts_in(text, shape):
    """Each message WITH TEXT in a read result as (ts, name, member id, body, labelled), where
    labelled says its last line is shaped like a label. shape counts what was seen, including the
    messages found with no text under their Message TS line, which are no post here: unread."""
    posts = []
    cur = None

    def close():
        if cur is None:
            return
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
        for x in lines:
            label_seen(x, "under", shape)
        labelled = bool(LABEL_LINE.match(lines[-1]))
        if labelled:
            shape[LABELLED] += 1
        posts.append((cur["ts"], cur["name"], cur["uid"], "\n".join(cur["body"]).strip(), labelled))

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
    posts = {}    # (channel, ts) -> (place, name, member id, body, whether its last line is label shaped)
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
    inner, fields = unwrap(text)
    for field in fields:
        # A key is printed only when it is one of KNOWN_FIELDS. Any other could be anything, a
        # sentence of somebody's included, so only its length is counted (the review, S1).
        if field in KNOWN_FIELDS:
            shape["result field " + field] += 1
        else:
            shape["result fields not in the fixed list, of %d characters" % len(field)] += 1
    found = posts_in(inner, shape)
    if not found:
        # No message with text: no heading this knows, or every message's text is somewhere else.
        shape["in a layout this cannot read"] += 1
        return
    shape["read results with messages"] += 1
    for ts, name, uid, body, labelled in found:
        place = (channel, "") if tool == CHANNEL_TOOL or ts == parent else (channel, parent)
        known = posts.get((channel, ts))
        if known is not None and known[0][1] and not place[1]:
            # Already read inside its thread. A reply Slack also shows in the channel is ONE post, in
            # its thread, whichever read came first: it is never a second post at the top (S6).
            place = known[0]
        posts[(channel, ts)] = (place, name, uid, body, labelled)


def sentences(text):
    """The text with Slack's formatting set aside, as a list of sentences in lower case."""
    t = html.unescape(text)
    t = MENTION.sub(r"<@\1>", t)
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


def pair_up(drafts, saved, posts, author, concise):
    """Pairs as (place, post time, draft text, sent text), and what was left out."""
    want = author.strip().lower()
    by_place = collections.defaultdict(list)
    for call, d in drafts.items():
        if saved.get(call) and d["at"] is not None:
            by_place[d["place"]].append((d["at"], call, d["text"]))
    mine = collections.defaultdict(list)
    for (_channel, ts), (place, name, uid, body, labelled) in posts.items():
        if uid.lower() == want or name.strip().lower() == want:
            mine[place].append((float(ts), body, labelled))
    pairs, used, no_draft, doubtful = [], set(), 0, 0
    late, late_posts = set(), 0
    paired_at, closer = {}, 0  # draft call -> the likeness of the pair it made
    for place, sent in mine.items():
        ds = sorted(by_place.get(place, []))
        for at, body, labelled in sorted(sent):
            before = [d for d in ds if d[0] < at]
            if not before or before[-1][1] in used:
                no_draft += 1
                # The first post after a draft takes it. When this later one is MORE like that draft,
                # the pair made may be the wrong one, so it is counted. The rule is not changed here:
                # whether the likeliest post should take the draft is for Dan (pull request 3848).
                took = paired_at.get(before[-1][1]) if before else None
                if took is not None and not labelled and kinds_of(before[-1][2], body)[1] > took:
                    closer += 1
                continue
            if at - before[-1][0] > PAIR_WITHIN_DAYS * 86400:
                # Too long after that draft to be read as what became of it: neither is in a pair.
                late_posts += 1
                late.add(before[-1][1])
                continue
            used.add(before[-1][1])
            if labelled:
                # Its last line may be the connector's and not his, so the pair is set aside and counted:
                # compared, a post sent word for word would read as edited (L648).
                doubtful += 1
                continue
            paired_at[before[-1][1]] = kinds_of(before[-1][2], body)[1]
            pairs.append((place, at, before[-1][2], body))
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
    for key in (FOUND, TEXT_LINES, NO_TEXT, ABOVE, ABOVE_LINES, LABELLED, CONCISE):
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
          "From nor Time: %d; last line shaped like a label: %d)" % (found, wordless, shape[ABOVE], shape[LABELLED]))
    if shape["read results"] and not shape["read results with messages"] and (unreadable or shape[CONCISE]):
        if not unreadable:
            print("Nothing was measured: every thread or channel read in the records is a concise read, which "
                  "shows no time for a post, so no draft can be paired with what was sent.")
        else:
            print("Nothing was measured: thread or channel reads are in the records and not one could be read, so "
                  "a count of pairs here would be a count of this program's blind spot.")
        return 4
    # The headings can all match while the TEXT sits where this does not look (review M1). Each of the
    # three is a failure when it is true of most messages, never a count: a post read with no text, or
    # with a line of the connector's own in it, is compared as an edit Dan never made.
    misplaced = ""
    if 2 * wordless > found:
        misplaced = "most of the messages found have no text under their Message TS line"
    elif 2 * shape[ABOVE] > found:
        misplaced = "most of the messages found hold a line above their Message TS line that is neither From nor Time"
    elif 2 * shape[LABELLED] > found - wordless:
        misplaced = ("most of the messages found end in a line shaped like a label (a word or three and a colon), "
                     "which is how the connector writes its own lines")
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
          "with: %d (the first post after a draft takes it)" % left["closer"])
    print("also left out: pairs whose post ends in a line shaped like a label: %d (that line may be the "
          "connector's and not his)" % left["doubtful"])
    print("also left out: posts more than %d days after the draft before them: %d (drafts: %d). The %d days "
          "is a setting chosen on 2026-11-27, not a measurement." % (
              PAIR_WITHIN_DAYS, left["late_posts"], left["late_drafts"], PAIR_WITHIN_DAYS))
    print("also left out: saved drafts with no time on their record: %d (nothing can be said to come after "
          "one)" % left["untimed"])
    tally = collections.defaultdict(list)
    for place, at, draft, sent in pairs:
        kinds, likeness = kinds_of(draft, sent)
        for kind in kinds:
            tally[kind].append((place, at, draft, sent, likeness))
    for kind in REPORTED:
        print("%s: %d of %s" % (kind, len(tally[kind]), plural(len(pairs), "pair")))
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
    return 0


sys.exit(main())
