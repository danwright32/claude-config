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
runs it. Dan chose that on 2026-11-27 (issue #3554). --shapes prints, in place of the tallies, how
the read results are laid out: counts and field names only.

HOW A PAIR IS MADE.
  * A draft is a slack_send_message_draft call whose answer says Slack saved it (not marked as an
    error and naming none of Slack's draft errors, as mods/is-it-live/hooks/threads.ts judges it).
    Its place is its channel and the thread it replies in, or the top of the channel with no thread.
    Its time is the time on its record.
  * A post is a message by --author in the result of a LATER slack_read_thread or slack_read_channel
    call in any session record. A thread's first message belongs to the top of its channel.
  * Each post is compared with the latest draft saved in the same place before it. A draft is used
    once: a second post after the same draft was written without one and is left out, as is a post
    with no draft before it, and a draft a later draft replaced before anything was posted.
  * Both are compared after Slack's formatting is set aside (links, bold, italics, bullets, quote
    marks, spacing and case), by words, with difflib.

WHAT IT CANNOT SEE, so nobody reads more into a count than it measured.
  * A thread no later session read back. Its draft is counted as having no post read back after it.
  * A draft Dan deleted. If he later wrote something else in that thread, the two are paired and
    read as heavily rewritten.
  * A message he wrote from the start with no draft: it is left out, never counted as an edit.
  * Anything on the other Mac: each Mac holds only its own records, for as long as it keeps them.

THE KINDS. A pair can be several at once, bar the first.
  sent as drafted     the two are the same once formatting is set aside
  heavily rewritten   their likeness is under HEAVY (0.70, the line issue #3554's measurement used)
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
other tools of the same Slack connector. That Mac held no draft call and no read that succeeded, so
the layout INSIDE a thread or channel read (the headings and the From, Time and Message TS lines)
was not measured there. It is written as the connector was seen to answer earlier, and it is the
part most likely to differ. So a read result with no message this can find is COUNTED and said, a
run in which no read result could be read exits 4 and says nothing was measured, and --shapes prints
what the results are made of so the layout can be checked on a Mac that holds them (L98, L177).

Exit codes: 0 measured; 2 a wrong argument; 3 the records folder could not be read; 4 read results
were there and none could be read.
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
EXAMPLE_CHARS = 600

REPORTED = ("sent as drafted", "heavily rewritten")
OFFERED = ("figures cut", "length cut", "the ask reworded", "the opening changed")

CHANNEL_HEAD = re.compile(r"^=== Message from (.+?) \(([A-Z0-9]+)\) at .* ===\s*$")
PARENT_HEAD = re.compile(r"^=== THREAD PARENT MESSAGE ===\s*$")
REPLY_HEAD = re.compile(r"^--- Reply \d+ of \d+ ---\s*$")
OTHER_HEAD = re.compile(r"^(?:=== .* ===|--- .* ---)\s*$")
FROM_LINE = re.compile(r"^From: (.+?)(?: \(([A-Z0-9]+)\))?\s*$")
TS_LINE = re.compile(r"^Message TS: (\d+\.\d+)\s*$")
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


def posts_in(text, shape):
    """Each message in a read result as (ts, name, member id, body). shape counts what was seen."""
    posts = []
    cur = None

    def close():
        if cur is not None and cur["ts"] and (cur["name"] or cur["uid"]):
            posts.append((cur["ts"], cur["name"], cur["uid"], "\n".join(cur["body"]).strip()))
        elif cur is not None:
            shape["headings with no author or no Message TS under them"] += 1

    for line in text.split("\n"):
        m = CHANNEL_HEAD.match(line)
        if m:
            close()
            shape["channel message headings"] += 1
            cur = {"name": m.group(1), "uid": m.group(2), "ts": "", "body": []}
            continue
        if PARENT_HEAD.match(line) or REPLY_HEAD.match(line):
            close()
            shape["thread parent headings" if PARENT_HEAD.match(line) else "thread reply headings"] += 1
            cur = {"name": "", "uid": "", "ts": "", "body": []}
            continue
        if OTHER_HEAD.match(line):
            close()
            shape["other headings"] += 1
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
            continue
        cur["body"].append(line)
    close()
    return posts


def read_records(root, shape):
    """Every saved draft and every message read back, from the record files under root."""
    drafts = {}   # call id -> {"place", "text", "at"}
    saved = {}    # call id -> whether Slack saved it
    reads = {}    # call id -> (tool, channel, parent ts)
    posts = {}    # (place, ts) -> (name, member id, body)
    done = set()  # read call ids whose result was taken
    files = 0
    for folder, _dirs, names in os.walk(root):
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
                        take_result(item, drafts, saved, reads, posts, done, shape)
    return files, drafts, saved, posts


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
    elif tool.endswith("__" + THREAD_TOOL):
        parent = args.get("message_ts")
        if isinstance(parent, str) and parent:
            reads[call] = (THREAD_TOOL, channel, parent)
    elif tool.endswith("__" + CHANNEL_TOOL):
        reads[call] = (CHANNEL_TOOL, channel, "")


def take_result(item, drafts, saved, reads, posts, done, shape):
    call = item.get("tool_use_id")
    if call in drafts:
        text, error = result_text(item)
        saved[call] = saved.get(call, False) or (not error and not DRAFT_ERROR.search(text))
        return
    if call not in reads or call in done:
        return
    done.add(call)
    tool, channel, parent = reads[call]
    text, error = result_text(item)
    shape["read results"] += 1
    if error:
        shape["read results marked as an error"] += 1
        return
    inner, fields = unwrap(text)
    for field in fields:
        shape["result field " + field] += 1
    found = posts_in(inner, shape)
    if not found:
        shape["in a layout this cannot read"] += 1
        return
    shape["read results with messages"] += 1
    for ts, name, uid, body in found:
        place = (channel, "") if tool == CHANNEL_TOOL or ts == parent else (channel, parent)
        posts[(place, ts)] = (name, uid, body)


def sentences(text):
    """The text with Slack's formatting set aside, as a list of sentences in lower case."""
    t = html.unescape(text)
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
    """The kinds of edit between a draft and what was sent."""
    d, s = sentences(draft), sentences(sent)
    dt, st = " ".join(d), " ".join(s)
    if dt == st:
        return ["sent as drafted"]
    kinds = []
    if difflib.SequenceMatcher(None, dt.split(), st.split(), autojunk=False).ratio() < HEAVY:
        kinds.append("heavily rewritten")
    if len(FIGURE.findall(st)) < len(FIGURE.findall(dt)):
        kinds.append("figures cut")
    if len(st) < SHORTER * len(dt):
        kinds.append("length cut")
    d_asks, s_asks = {x for x in d if ASK.search(x)}, {x for x in s if ASK.search(x)}
    if d_asks and s_asks and d_asks != s_asks:
        kinds.append("the ask reworded")
    if dt.split()[:OPENING_WORDS] != st.split()[:OPENING_WORDS]:
        kinds.append("the opening changed")
    return kinds


def pair_up(drafts, saved, posts, author):
    """Pairs as (place, post time, draft text, sent text), and what was left out."""
    want = author.strip().lower()
    by_place = collections.defaultdict(list)
    for call, d in drafts.items():
        if saved.get(call) and d["at"] is not None:
            by_place[d["place"]].append((d["at"], call, d["text"]))
    mine = collections.defaultdict(list)
    for (place, ts), (name, uid, body) in posts.items():
        if uid.lower() == want or name.strip().lower() == want:
            mine[place].append((float(ts), body))
    pairs, used, no_draft = [], set(), 0
    for place, sent in mine.items():
        ds = sorted(by_place.get(place, []))
        for at, body in sorted(sent):
            before = [d for d in ds if d[0] < at]
            if not before or before[-1][1] in used:
                no_draft += 1
                continue
            used.add(before[-1][1])
            pairs.append((place, at, before[-1][2], body))
    replaced = unread = 0
    for place, ds in by_place.items():
        ds.sort()
        for i, (at, call, _text) in enumerate(ds):
            if call in used:
                continue
            # Replaced when a later draft in the same place was the one a post was compared with.
            if any(later[1] in used for later in ds[i + 1:]):
                replaced += 1
            else:
                unread += 1
    return sorted(pairs, key=lambda p: p[1]), {"unread": unread, "replaced": replaced, "no_draft": no_draft}


def cut(text):
    return text if len(text) <= EXAMPLE_CHARS else text[:EXAMPLE_CHARS] + " (cut at %d characters)" % EXAMPLE_CHARS


def plural(n, word):
    return "%d %s" % (n, word if n == 1 else word + "s")


def print_shapes(shape):
    print("How the Slack read results in these records are laid out (counts and field names only)")
    for key in sorted(shape):
        print("  %s: %d" % (key, shape[key]))
    if not shape:
        print("  no draft call and no thread or channel read was found")


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
    shape = collections.Counter()
    files, drafts, saved, posts = read_records(args.records, shape)
    n_saved = sum(1 for call in drafts if saved.get(call))
    shape["draft calls"] = len(drafts)
    shape["draft calls Slack saved"] = n_saved
    shape["messages read back"] = len(posts)
    if args.shapes:
        print_shapes(shape)
        return 0
    pairs, left = pair_up(drafts, saved, posts, args.author)
    unreadable = shape["in a layout this cannot read"]
    print("Slack drafts compared with what was sent")
    print("record files read: %d (could not be opened: %d)" % (files, shape["record files that could not be opened"]))
    print("draft calls: %d (saved: %d)" % (len(drafts), n_saved))
    print("read results: %d (with messages: %d, marked as an error: %d)" % (
        shape["read results"], shape["read results with messages"], shape["read results marked as an error"]))
    if unreadable:
        print("read results in a layout this cannot read: %d. Their messages are in none of the counts below; "
              "run this with --shapes to see what they are made of." % unreadable)
    if shape["read results"] and not shape["read results with messages"] and unreadable:
        print("Nothing was measured: thread or channel reads are in the records and not one could be read, so "
              "a count of pairs here would be a count of this program's blind spot.")
        return 4
    if not n_saved:
        print("No saved draft is in these records, so there is nothing to compare on this Mac. Every count "
              "below is zero for that reason, and says nothing about how drafts are edited.")
    threads = {p[0] for p in pairs}
    print("pairs: %d in %s" % (len(pairs), plural(len(threads), "thread")))
    print("left out: drafts with no post read back after them: %d; drafts replaced by a later draft: %d; "
          "posts with no draft before them: %d" % (left["unread"], left["replaced"], left["no_draft"]))
    tally = collections.defaultdict(list)
    for pair in pairs:
        for kind in kinds_of(pair[2], pair[3]):
            tally[kind].append(pair)
    for kind in REPORTED:
        print("%s: %d of %s" % (kind, len(tally[kind]), plural(len(pairs), "pair")))
    examples = []
    for kind in OFFERED:
        found = tally[kind]
        in_threads = len({p[0] for p in found})
        if kind in args.skip:
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
            _place, _at, draft, sent = tally[kind][-1]  # the latest pair of that kind
            print("")
            print("Example for %s (Slack message text: show it to Dan, and copy it nowhere)" % kind)
            print("DRAFT: " + cut(draft))
            print("SENT: " + cut(sent))
    return 0


sys.exit(main())
