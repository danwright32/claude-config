"""Build the session records the draft edit suites read (claude-config#3554).

Usage: python3 build.py <folder to fill> <which>

Every word of message text here is invented, and so is every name, member id and channel id: no
real message, person, channel or workspace is in this file (L48, L155). What the shape rests on is
said in ../lib/draft-edit-diff.py, under WHAT THE SHAPE RESTS ON.

It writes its records under the folder it is handed and nowhere else, and reads nothing.

WHAT WAS MEASURED, by counts, field names and the punctuation of headings only, on the work MacBook
on 2026-11-27 (pull request 3848): the thread and channel headings, the From, Time and Message TS
lines, the two fields "messages" and "pagination_info", a "Reactions:" line under the text of some
thread messages (layout "trailing"), the section heading over a thread's replies, a concise read
with none of those, a channel heading with no name or with an address, and the two ways a mention
is written. Every fixture of those is still invented text in that layout.

"body_first", "labelled", "split" and "some_labelled" were NOT seen. They move only the TEXT of a
message, or put an unmeasured label line under it, and "unknown" has no heading at all. They are
here so the suite can show the reader fails aloud, or sets a pair aside, instead of counting edits
nobody made.

NOT seen either, and here for the same reason (the second review of pull request 3848):
"first_label" and "some_first_label" (a label line right under the Message TS line), "above" (one
above it, with the text in place), "most_wordless", "unlisted" (labels in no fixed list),
"pagination" (text in the result's other fields: the field was measured, whether it ever holds
text was not), "no_messages_field", "odd_id", "other_mentions" (a channel, a group and a here
mention with a name added), "own_drafted", "own_added" and "own_every" (his own lines shaped like
a label) and "alerts" (most messages, by somebody else, beginning and ending in such a line).
"bands" is ten pairs whose likeness is known by construction, for the count by likeness.
"""
import datetime
import json
import os.path
import sys

SERVER = "mcp__claude_ai_Slack__"
BASE = 1793631600  # an arbitrary second; every time in a fixture is this plus an offset
ME = ("Ada Example", "U0FIXTUREA")
OTHER = ("Ben Sample", "U0FIXTUREB")


def iso(seconds):
    t = datetime.datetime.fromtimestamp(BASE + seconds, datetime.timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%S.000Z")


def ts(seconds):
    return "%d.000100" % (BASE + seconds)


class Records:
    def __init__(self):
        self.lines = []
        self.n = 0

    def use(self, at, tool, tool_input, blob=False, timed=True):
        self.n += 1
        call = "toolu_fixture_%04d" % self.n
        message = {"role": "assistant", "content": [
            {"type": "tool_use", "id": call, "name": SERVER + tool, "input": tool_input}]}
        if timed:
            self.lines.append({"type": "assistant", "timestamp": iso(at), "sessionId": "fixture",
                               "isSidechain": False, "message": message})
        if blob or not timed:  # the copy Claude Code keeps of the request, which carries no time
            self.lines.append({"type": "api-request-blob", "hash": "fixture", "sessionId": "fixture",
                               "message": message})
        return call

    def result(self, at, call, text, error=False, as_list=True):
        item = {"type": "tool_result", "tool_use_id": call,
                "content": [{"type": "text", "text": text}] if as_list else text}
        if error:
            item["is_error"] = True
        self.lines.append({"type": "user", "timestamp": iso(at), "sessionId": "fixture",
                           "message": {"role": "user", "content": [item]}})

    def draft(self, at, channel, thread, text, saved=True, answer=None, blob=False, timed=True):
        tool_input = {"channel_id": channel, "message": text}
        if thread is not None:
            tool_input["thread_ts"] = ts(thread)
        call = self.use(at, "slack_send_message_draft", tool_input, blob, timed)
        if answer is not None:
            self.result(at + 1, call, answer)
        elif saved:
            self.result(at + 1, call, json.dumps({"result": "Draft saved", "channel_link": "https://example.invalid/client/T0FIXTURE/" + channel}))
        else:
            self.result(at + 1, call, "Error: the draft could not be saved", error=True, as_list=False)

    def thread(self, at, channel, parent, posts, layout="thread", fields=None):
        """posts: (seconds, who, text). The first is the thread's parent message. fields are further
        fields of the result's JSON object, written after "messages"."""
        call = self.use(at, "slack_read_thread", {"channel_id": channel, "message_ts": ts(parent)})
        answer = {"messages": thread_text(posts, layout)}
        answer.update(fields or {})
        self.result(at + 1, call, json.dumps(answer))

    def channel(self, at, channel, posts):
        call = self.use(at, "slack_read_channel", {"channel_id": channel})
        out = []
        for seconds, who, text in posts:
            out.append("=== Message from %s (%s) at 2026-11-02 10:00:00 EST ===\nMessage TS: %s\n%s\n" % (who[0], who[1], ts(seconds), text))
        self.result(at + 1, call, json.dumps({"messages": "\n".join(out)}))

    def write(self, folder, name, extra=b""):
        path = os.path.join(folder, name)
        body = "".join(json.dumps(line) + "\n" for line in self.lines).encode("utf-8", "replace")
        with open(path, "wb") as f:
            f.write(body + extra)


def thread_text(posts, layout):
    if layout == "unknown":
        return "\n".join("%s said at %s: %s" % (who[0], ts(seconds), text) for seconds, who, text in posts)
    out = []
    for i, (seconds, who, text) in enumerate(posts):
        if i == 0:
            out.append("=== THREAD PARENT MESSAGE ===")
        else:
            if i == 1:
                out.append("=== THREAD REPLIES (%d total) ===\n" % (len(posts) - 1))
            out.append("--- Reply %d of %d ---" % (i, len(posts) - 1))
        head = "From: %s (%s)\nTime: 2026-11-02 10:00:00 EST\n" % (who[0], who[1])
        marked = layout == "labelled" or (layout == "some_labelled" and i % 5 == 2)
        first = layout == "first_label" or (layout == "some_first_label" and i % 5 == 2)
        if text == "":                       # a post that holds a file and no words
            out.append(head + "Message TS: %s\n" % ts(seconds))
        elif first:                          # a label line nobody measured, right under the Message TS line
            out.append(head + "Message TS: %s\nThread TS: %s\n%s\n" % (ts(seconds), ts(posts[0][0]), text))
        elif layout == "above":              # the text in place, and a line nobody measured above the Message TS line
            out.append(head + "Thread TS: %s\nMessage TS: %s\n%s\n" % (ts(posts[0][0]), ts(seconds), text))
        elif layout == "unlisted":           # a label that is in no fixed list, under the text and above the line
            out.append(head + "Quay marker: 2\nMessage TS: %s\n%s\nHarbour note: 1\n" % (ts(seconds), text))
        elif layout == "body_first":         # the text sits above the Message TS line
            out.append(head + "%s\nMessage TS: %s\n" % (text, ts(seconds)))
        elif layout == "split":              # the text above it, and a label line nobody measured under it
            out.append(head + "%s\nMessage TS: %s\nAttachments: 1\n" % (text, ts(seconds)))
        elif layout == "trailing":           # MEASURED: a Reactions line under the text of a message
            out.append(head + "Message TS: %s\n%s\nReactions: thumbsup (2)\n" % (ts(seconds), text))
        elif marked:                         # a label line nobody measured, under the text
            out.append(head + "Message TS: %s\n%s\nAttachments: 1\n" % (ts(seconds), text))
        else:
            out.append(head + "Message TS: %s\n%s\n" % (ts(seconds), text))
    return "\n".join(out)


LONG = ("The harbour survey covered 14 berths, 3 cranes and 220 metres of quay. "
        "Of the 14 berths, 9 need new fenders and 5 need dredging. "
        "Can you confirm which berths the dredger should start on?")
# An edit and not a rewrite: one figure gone, the ask put another way, and most of the words kept.
SHORT = ("The harbour survey covered 14 berths, 3 cranes and the quay. "
         "Of the 14 berths, 9 need new fenders and 5 need dredging. "
         "Which berths does the dredger start on?")


def basics(folder):
    r = Records()
    # One: a figure cut, shortened, the ask reworded, the opening kept. Somebody else posts in between.
    r.draft(100, "C0FIXTURE01", 0, LONG, blob=True)
    r.thread(900, "C0FIXTURE01", 0, [
        (0, OTHER, "How did the harbour survey go?"),
        (150, OTHER, "Any numbers yet?"),
        (200, ME, SHORT)])
    # Two: sent as drafted once Slack's formatting is set aside.
    r.draft(1000, "C0FIXTURE02", 1000, "**Lighthouse** rota is in [the tide table](https://example.invalid/tides).\n- Monday: north lamp\n- Tuesday: south lamp")
    r.thread(1900, "C0FIXTURE02", 1000, [
        (1000, OTHER, "Who has the lamps this week?"),
        (1200, ME, "*lighthouse* rota is in <https://example.invalid/tides|the tide table>.\n• Monday: north lamp\n• Tuesday:  south lamp")])
    # Three: a post with no draft before it, and a draft nobody read back.
    r.thread(2900, "C0FIXTURE03", 2000, [
        (2000, OTHER, "Is the ferry timetable out?"),
        (2100, ME, "Not yet, the printer is late.")])
    r.draft(3000, "C0FIXTURE04", 3000, "The buoy inspection is booked for the spring tide.")
    # Four: a draft that was never saved, in two ways, so the post after them has no draft before it.
    r.draft(4000, "C0FIXTURE05", 4000, "Unsaved wording about the slipway.", saved=False)
    r.draft(4010, "C0FIXTURE05", 4000, "Second unsaved wording about the slipway.",
            answer=json.dumps({"ok": False, "error": "attached_draft_exists"}))
    r.thread(4900, "C0FIXTURE05", 4000, [
        (4000, OTHER, "When does the slipway reopen?"),
        (4100, ME, "The slipway reopens on Friday.")])
    # Five: two drafts, then a post (the later draft is the one compared), then a post with no new draft.
    r.draft(5000, "C0FIXTURE06", 5000, "First wording: the pilot boat is back in the water.")
    r.draft(5050, "C0FIXTURE06", 5000, "The pilot boat is back in the water and running.")
    r.thread(5900, "C0FIXTURE06", 5000, [
        (5000, OTHER, "Pilot boat news?"),
        (5100, ME, "The pilot boat is back in the water and running."),
        (5200, ME, "It will need a second look in a month.")])
    # Six: a draft at the top of a channel, read back through the channel. What was posted shares
    # nothing with it, so it is heavily rewritten and in no kind a rule is offered for.
    r.draft(6000, "C0FIXTURE07", None, "The winter mooring list is ready for the harbour office to read through and comment on.")
    r.channel(6900, "C0FIXTURE07", [
        (6100, ME, "Nothing here matches the draft at all, it was written again from the start."),
        (6050, OTHER, "Morning all.")])
    # Seven: the line leading up to the point is cut, and every other word kept.
    r.draft(7000, "C0FIXTURE08", 7000, "Hi all, a quick note on the buoys: the buoy inspection is booked for the spring tide and the diver is confirmed for the day.")
    r.thread(7900, "C0FIXTURE08", 7000, [
        (7000, OTHER, "Is the buoy inspection booked?"),
        (7100, ME, "The buoy inspection is booked for the spring tide and the diver is confirmed for the day.")])
    # A line that is not UTF-8 and a line that is not JSON, which a record file can hold.
    r.write(folder, "session-one.jsonl", extra=b'{"type":"user","message":"\xff\xfe"}\n{not json\n')
    # The same records again in a second file, as a resumed session keeps them.
    r.write(folder, "session-one-resumed.jsonl")


KEEPER = " The keeper has logged every reading and will send the sheet on Friday."
GAUGE_DRAFT = "Gauge %d read 41 at dawn, 57 at noon and 63 at dusk, against 38, 52 and 60 last week." + KEEPER
GAUGE_SENT = "Gauge %d read 57 at noon and 63 at dusk." + KEEPER          # four figures and a third of it cut
GAUGE_NEARLY = "Gauge %d read 41 at dawn, 57 at noon and 63 at dusk, against 38 and 60 last week." + KEEPER
STRAY = "Is the ferry still on for Friday?"                              # shares nothing with a draft
DAY = 86400


def many(folder, per_thread, strays=(), nearly=None, stray_after=100):
    """Pairs that each cut figures and length and keep most of the draft's words, spread over
    threads as per_thread says. strays[t] adds that many drafts to thread t that were never sent,
    each followed stray_after seconds later by a post about something else. nearly is the number of
    the one pair, counted from 0 across the threads, whose post drops a single figure and no more."""
    r = Records()
    at = 10000
    n = 0
    for t, count in enumerate(per_thread):
        parent = at
        channel = "C0FIXTURE%02d" % (20 + t)
        posts = [(parent, OTHER, "Thread %d about the tide gauge." % t)]
        for k in range(count):
            at += 100
            r.draft(at, channel, parent, GAUGE_DRAFT % k)
            at += 100
            posts.append((at, ME, (GAUGE_NEARLY if n == nearly else GAUGE_SENT) % k))
            n += 1
        for _ in range(strays[t] if t < len(strays) else 0):
            at += 100
            r.draft(at, channel, parent, GAUGE_DRAFT % 99)
            at += stray_after
            posts.append((at, ME, STRAY))
        at += 100
        r.thread(at, channel, parent, posts)
        at += 1000
    r.write(folder, "session-many.jsonl")


WORD_FOR_WORD = "Gauge %d read 41 at dawn, 57 at noon and 63 at dusk. Can you confirm the dusk reading?"


OWN_FIRST = "Update: gauge %d read 41 at dawn and 57 at noon."
OWN_LAST = "\nNext step: check the dusk reading on gauge %d."


ALERT = "Alert: gauge %d is over the high water mark.\nSource: the tide gauge at the quay"


def word_for_word(folder, layout, wordless=0, fields=None, own="", alerts=0):
    """Twelve drafts in three threads, each posted WORD FOR WORD as drafted: the truth is twelve sent
    as drafted, whatever the layout. wordless adds that many posts with no words to each thread.
    fields are further fields of each read result, beside "messages".

    own puts lines of HIS that are shaped like a label into two posts of each thread: one post that
    is a single "Update: ..." line, and one that ends in a "Next step: ..." line. With own "drafted"
    the draft holds those lines too, so the truth is still twelve sent as drafted. With own "added"
    the draft is without them: he put them in by hand, and nothing can tell them from the connector's.

    alerts adds that many posts by SOMEBODY ELSE to each thread, each beginning and ending in a line
    shaped like a label, as an alert a program posts does. They are most of the messages, and none
    is his: the truth is still twelve sent as drafted."""
    r = Records()
    at = 10000
    for t in range(3):
        parent = at
        channel = "C0FIXTURE%02d" % (40 + t)
        posts = [(parent, OTHER, "Thread %d about the tide gauge." % t)]
        for a in range(alerts):
            at += 100
            posts.append((at, OTHER, ALERT % a))
        for k in range(4):
            draft = sent = WORD_FOR_WORD % k
            if own == "every":               # every post of his is one "Update: ..." line, as drafted
                draft = sent = OWN_FIRST % k
            elif own and k == 1:
                sent = OWN_FIRST % k
                draft = sent if own == "drafted" else sent[len("Update: "):]
            elif own and k == 2:
                sent = draft + OWN_LAST % k
                draft = sent if own == "drafted" else draft
            at += 100
            r.draft(at, channel, parent, draft)
            at += 100
            posts.append((at, ME, sent))
        for _ in range(wordless):
            at += 100
            posts.append((at, ME, ""))
        at += 100
        r.thread(at, channel, parent, posts, layout, fields)
        at += 1000
    r.write(folder, "session-%s.jsonl" % layout)


def no_messages_field(folder):
    """A read result whose JSON object has no "messages" string: the layout of its text is right, and
    it sits under a key nobody measured. One draft, posted word for word."""
    r = Records()
    r.draft(100, "C0FIXTURE31", 0, "The lock gates close at nine.")
    call = r.use(900, "slack_read_thread", {"channel_id": "C0FIXTURE31", "message_ts": ts(0)})
    r.result(901, call, json.dumps({"result": thread_text([
        (0, OTHER, "When do the lock gates close?"), (200, ME, "The lock gates close at nine.")], "thread")}))
    r.write(folder, "session-no-messages-field.jsonl")


def odd_id(folder):
    """A tool_result whose tool_use_id is a list, which no real record was seen to hold, beside one
    draft posted word for word. The reader has to pass it over and still read the rest."""
    r = Records()
    r.draft(100, "C0FIXTURE32", 0, "The lock gates close at nine.")
    r.lines.append({"type": "user", "timestamp": iso(500), "sessionId": "fixture", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": ["toolu_fixture_odd"], "content": "The slipway reopens on Friday."}]}})
    r.thread(900, "C0FIXTURE32", 0, [(0, OTHER, "When do the lock gates close?"), (200, ME, "The lock gates close at nine.")])
    r.write(folder, "session-odd-id.jsonl")


def other_mentions(folder):
    """A channel, a group and a "here" mention, each written bare in the draft and with a name added
    in the read, as a mention of a person was MEASURED to be. These three were not measured: they are
    the same mechanism. Three drafts in three threads, each posted word for word."""
    r = Records()
    cases = (
        ("<#C0FIXTURE99> has the winter mooring list for the harbour office to read.",
         "<#C0FIXTURE99|harbour-office> has the winter mooring list for the harbour office to read."),
        ("<!subteam^S0FIXTURE1> please read the winter mooring list before the tide turns.",
         "<!subteam^S0FIXTURE1|@harbour-crew> please read the winter mooring list before the tide turns."),
        ("<!here> the slipway reopens on Friday at nine.",
         "<!here|here> the slipway reopens on Friday at nine."),
    )
    for n, (draft, sent) in enumerate(cases):
        start = 1000 * n
        channel = "C0FIXTURE%02d" % (33 + n)
        r.draft(start + 100, channel, start, draft)
        r.thread(start + 900, channel, start, [(start, OTHER, "Any news from the harbour?"), (start + 200, ME, sent)])
    r.write(folder, "session-other-mentions.jsonl")


def tide_words(count, changed):
    """count invented words in a row, the first `changed` of them swapped for other invented words.
    Every word is different, so the likeness of two such rows of fifty is (50 - changed) / 50."""
    letters = "abcdefghijklmnopqrstuvwxyz"
    return " ".join(("ebb" if i < changed else "tide") + letters[i // 26] + letters[i % 26] for i in range(count))


# How many of a draft's fifty words each post swaps, and so its likeness: 0 is the same (1.00), then
# 0.98, 0.96, 0.94, 0.90, 0.88, 0.80, 0.78, 0.70 and 0.68. Four of them sit exactly on a band's edge.
BAND_SWAPS = (0, 1, 2, 3, 5, 6, 10, 11, 15, 16)
# The posts that are NOT the last message of the read they are in: somebody answers after them.
BAND_ANSWERED = (1, 2)


def bands(folder):
    """Ten drafts of fifty invented words in ten threads, each posted with a known number of words
    swapped, so the count of pairs in each band of likeness has a known answer. The first is posted
    with bold added and nothing else changed."""
    r = Records()
    for n, swapped in enumerate(BAND_SWAPS):
        start = 1000 * n
        channel = "C0FIXTURE%02d" % (60 + n)
        sent = tide_words(50, swapped)
        if swapped == 0:
            sent = "*" + sent + "*"
        posts = [(start, OTHER, "Any news from the tide gauge?"), (start + 200, ME, sent)]
        if swapped in BAND_ANSWERED:
            posts.append((start + 300, OTHER, "Thank you."))
        r.draft(start + 100, channel, start, tide_words(50, 0))
        r.thread(start + 900, channel, start, posts)
    r.write(folder, "session-bands.jsonl")


def unknown(folder):
    r = Records()
    r.draft(100, "C0FIXTURE30", 0, "The lock gates close at nine.")
    r.thread(900, "C0FIXTURE30", 0, [
        (0, OTHER, "When do the lock gates close?"),
        (200, ME, "The lock gates close at nine.")], layout="unknown")
    r.write(folder, "session-unknown.jsonl")


def concise(folder, detailed_too):
    """MEASURED on the work MacBook on 2026-11-27: a read whose call passes response_format "concise"
    answers with no heading, no From line and no Message TS line, in the same two fields. Two drafts
    in two threads, each posted word for word and read back only that way; with detailed_too, a
    third thread read back in the layout the reader knows."""
    r = Records()
    for n, channel in enumerate(("C0FIXTURE80", "C0FIXTURE81")):
        start = 1000 * n
        r.draft(start + 100, channel, start, "The lock gates close at nine.")
        call = r.use(start + 900, "slack_read_thread",
                     {"channel_id": channel, "message_ts": ts(start), "response_format": "concise"})
        r.result(start + 901, call, json.dumps({
            "messages": "Ben Sample: When do the lock gates close?\nAda Example: The lock gates close at nine.",
            "pagination_info": ""}))
    if detailed_too:
        r.draft(5100, "C0FIXTURE82", 5000, "The slipway reopens on Friday at nine.")
        r.thread(5900, "C0FIXTURE82", 5000, [(5000, OTHER, "When does the slipway reopen?"),
                                               (5200, ME, "The slipway reopens on Friday at nine.")])
    r.write(folder, "session-concise.jsonl")


def headings(folder):
    """MEASURED on the work MacBook on 2026-11-27, by punctuation only: a channel message heading can
    have NOTHING between "Message from" and the bracketed id, and can carry an address in angle
    brackets with more fields inside the brackets. Three drafts at the top of a channel, each posted
    word for word, one under each such heading. How the spaces fall was not measured, so both are here."""
    r = Records()
    texts = ("The winter mooring list is ready.", "The pilot boat is back in the water.", "The ferry timetable is out.")
    heads = ("=== Message from  (%s) at 2026-11-02 10:00:00 EST ===" % ME[1],
             "=== Message from (%s) at 2026-11-02 10:00:00 EST ===" % ME[1],
             "=== Message from %s <ada@example.invalid> (%s, guest: no) at 2026-11-02 10:00:00 EST ===" % ME)
    out = []
    for n, (text, head) in enumerate(zip(texts, heads)):
        r.draft(1000 * n + 100, "C0FIXTURE85", None, text)
        out.append("%s\nMessage TS: %s\n%s\n" % (head, ts(1000 * n + 200), text))
    call = r.use(9000, "slack_read_channel", {"channel_id": "C0FIXTURE85"})
    r.result(9001, call, json.dumps({"messages": "\n".join(out), "pagination_info": ""}))
    r.write(folder, "session-headings.jsonl")


def mentions(folder):
    """MEASURED on the work MacBook on 2026-11-27: a mention is <@id> in a draft call and <@id|name>
    in a read result. One draft that opens with a mention, posted word for word."""
    r = Records()
    r.draft(100, "C0FIXTURE86", 0, "<@%s> the tide table is ready for Friday, and <@%s> has the keys." % (OTHER[1], ME[1]))
    r.thread(900, "C0FIXTURE86", 0, [
        (0, OTHER, "Is the tide table ready?"),
        (200, ME, "<@%s|%s> the tide table is ready for Friday, and <@%s|%s> has the keys." % (OTHER[1], OTHER[0], ME[1], ME[0]))])
    r.write(folder, "session-mentions.jsonl")


def second_post(folder, second_after=120):
    """A draft, then a quick line of his own about something else, then the draft posted word for
    word, second_after seconds after the draft was saved. The reader pairs the draft with the first
    post after it. Not measured anywhere: it is here to show what that rule does, and that the count
    beside it says so."""
    r = Records()
    r.draft(100, "C0FIXTURE87", 0, "The harbour office has the winter mooring list and will answer by Friday.")
    r.thread(100 + second_after + 600, "C0FIXTURE87", 0, [
        (0, OTHER, "Any word on the moorings?"),
        (160, ME, "Give me a minute."),
        (100 + second_after, ME, "The harbour office has the winter mooring list and will answer by Friday.")])
    r.write(folder, "session-second-post.jsonl")


def differences(folder):
    """Seven drafts in seven threads. Six were posted word for word, and what was read back differs
    in ONE thing a read result might add or write another way; the seventh was really edited. NONE of
    the six differences was measured: they are guesses at why so few real pairs read as sent as
    drafted, and they are here so the reader's --differences count can be seen to tell them apart."""
    r = Records()
    party = chr(0x1F389)  # an emoji as a character, written by its number so this file holds none
    cases = (
        ("The winter mooring list is in <https://example.invalid/moorings|the mooring list> for the harbour office to read.",
         "The winter mooring list is in <https://example.invalid/moorings|Winter moorings, harbour office> for the harbour office to read."),
        ("The tide table for the week is at https://example.invalid/tides and is ready.",
         "The tide table for the week is at <https://example.invalid/tides|example.invalid/tides> and is ready."),
        ("The slipway reopened this morning and the pilot boat is back :tada:",
         "The slipway reopened this morning and the pilot boat is back " + party),
        ("The buoy inspection is booked for the spring tide next week.",
         "The buoy inspection is booked for the spring tide next week. (edited)"),
        ("The ferry timetable for the winter is attached for the office.",
         "The ferry timetable for the winter is attached for the office.\ntimetable.pdf (12 kB)"),
        ("The ferry timetable is out, and the printer is paid.",
         "The ferry timetable is out and the printer is paid"),
        ("The lock gates close at nine tonight for the high water.",
         "The lock gates close at ten tonight for the high water."),
    )
    for n, (draft, sent) in enumerate(cases):
        start = 1000 * n
        channel = "C0FIXTURE%02d" % (90 + n % 9)
        r.draft(start + 100, channel, start, draft)
        r.thread(start + 900, channel, start, [(start, OTHER, "Any news from the harbour?"), (start + 200, ME, sent)])
    r.write(folder, "session-differences.jsonl")


def broadcast(folder, channel_first):
    """One reply the author sent, which Slack also shows in the channel, read back both ways. An
    older draft for the top of that channel was never sent. The truth: one pair, in the thread."""
    r = Records()
    r.draft(50, "C0FIXTURE50", None, "The winter mooring list is ready for the harbour office to read.")
    r.draft(100, "C0FIXTURE50", 0, "The slipway reopens on Friday at nine.")
    posts = [(0, OTHER, "When does the slipway reopen?"), (200, ME, "The slipway reopens on Friday at nine.")]
    if channel_first:
        r.channel(900, "C0FIXTURE50", posts)
        r.thread(950, "C0FIXTURE50", 0, posts)
    else:
        r.thread(900, "C0FIXTURE50", 0, posts)
        r.channel(950, "C0FIXTURE50", posts)
    r.write(folder, "session-broadcast.jsonl")


def untimed(folder):
    """A saved draft whose call is kept only in the copy of the request, which carries no time."""
    r = Records()
    r.draft(100, "C0FIXTURE60", 0, "The lock gates close at nine.", timed=False)
    r.thread(900, "C0FIXTURE60", 0, [
        (0, OTHER, "When do the lock gates close?"),
        (200, ME, "The lock gates close at nine.")])
    r.write(folder, "session-untimed.jsonl")


def keys(folder):
    """A read result whose JSON object holds a key that is a sentence, beside two plain field names."""
    r = Records()
    call = r.use(900, "slack_read_thread", {"channel_id": "C0FIXTURE70", "message_ts": ts(0)})
    r.result(901, call, json.dumps({
        "The lock gates close at nine and this whole sentence is a key " + "x" * 300: "nothing",
        "messages": thread_text([(0, OTHER, "When do the lock gates close?")], "thread"),
        "pagination": ""}))
    r.write(folder, "session-keys.jsonl")


def main():
    folder, which = sys.argv[1], sys.argv[2]
    if which == "basics":
        basics(folder)
    elif which == "recurring":
        many(folder, [4, 4, 4])
    elif which == "lopsided":
        many(folder, [8, 4])
    elif which == "few":
        many(folder, [3, 3, 3])
    elif which == "few_strays":      # nine edits and three posts that were never edits of a draft
        many(folder, [3, 3, 3], strays=[1, 1, 1])
    elif which == "tail_stray":      # twelve edits, and the latest pair of all is a stray
        many(folder, [4, 4, 4], strays=[0, 0, 1])
    elif which == "strays":          # no draft was sent: twelve strays, each half an hour on
        many(folder, [0, 0, 0], strays=[4, 4, 4], stray_after=1800)
    elif which == "late_strays":     # the same, each thirty days after its draft
        many(folder, [0, 0, 0], strays=[4, 4, 4], stray_after=30 * DAY)
    elif which == "hour_inside":     # each stray a second short of an hour after its draft
        many(folder, [0, 0, 0], strays=[4, 4, 4], stray_after=3599)
    elif which == "hour_outside":    # each stray an hour and a fraction of a second after its draft
        many(folder, [0, 0, 0], strays=[4, 4, 4], stray_after=3600)
    elif which == "nearly":          # twelve edits; the sixth keeps more of its draft than any other
        many(folder, [4, 4, 4], nearly=5)
    elif which == "differences":
        differences(folder)
    elif which == "unknown":
        unknown(folder)
    elif which in ("wordforword", "body_first", "trailing", "labelled", "split", "some_labelled",
                   "first_label", "some_first_label", "above", "unlisted"):
        word_for_word(folder, "thread" if which == "wordforword" else which)
    elif which == "most_wordless":   # six posts with no words beside five with them, in each thread
        word_for_word(folder, "thread", wordless=6)
    elif which == "pagination":      # the result's other fields hold text, one of them under a key in no list
        word_for_word(folder, "thread", fields={
            "pagination_info": "There are 4 more replies in the lighthouse thread. Pass the cursor to read them.",
            "next_cursor": "bGlnaHRob3VzZQ", "has_more": True, "pagination": "",
            "A keeper wrote this whole key": "The lighthouse keeper has the cursor."})
    elif which == "own_drafted":     # label shaped lines of his own, which the draft holds too
        word_for_word(folder, "thread", own="drafted")
    elif which == "own_added":       # the same lines, put in by hand after the draft was saved
        word_for_word(folder, "thread", own="added")
    elif which == "own_every":       # every post of his is one such line, and the draft held it
        word_for_word(folder, "thread", own="every")
    elif which == "alerts":          # seven posts by somebody else in each thread that begin and end in a label line
        word_for_word(folder, "thread", alerts=7)
    elif which == "no_messages_field":
        no_messages_field(folder)
    elif which == "odd_id":
        odd_id(folder)
    elif which == "other_mentions":
        other_mentions(folder)
    elif which == "bands":
        bands(folder)
    elif which == "concise":
        concise(folder, detailed_too=False)
    elif which == "concise_beside_detailed":
        concise(folder, detailed_too=True)
    elif which == "headings":
        headings(folder)
    elif which == "mentions":
        mentions(folder)
    elif which == "second_post":
        second_post(folder)
    elif which == "second_post_late":  # the word for word post comes two hours after the draft
        second_post(folder, second_after=7200)
    elif which == "some_wordless":
        word_for_word(folder, "thread", wordless=1)
    elif which in ("broadcast", "broadcast_channel_first"):
        broadcast(folder, which == "broadcast_channel_first")
    elif which == "untimed":
        untimed(folder)
    elif which == "keys":
        keys(folder)
    else:
        sys.exit("build.py: no fixture called " + which)


main()
