"""Build the session records the draft edit suites read (claude-config#3554).

Usage: python3 build.py <folder to fill> <which>

Every word of message text here is invented, and so is every name, member id and channel id: no
real message, person, channel or workspace is in this file (L48, L155). What the shape rests on is
said in ../lib/draft-edit-diff.py, under WHAT THE SHAPE RESTS ON.

It writes its records under the folder it is handed and nowhere else, and reads nothing.
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

    def use(self, at, tool, tool_input, blob=False):
        self.n += 1
        call = "toolu_fixture_%04d" % self.n
        message = {"role": "assistant", "content": [
            {"type": "tool_use", "id": call, "name": SERVER + tool, "input": tool_input}]}
        self.lines.append({"type": "assistant", "timestamp": iso(at), "sessionId": "fixture",
                           "isSidechain": False, "message": message})
        if blob:  # the copy Claude Code keeps of the request, which carries no time
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

    def draft(self, at, channel, thread, text, saved=True, answer=None, blob=False):
        tool_input = {"channel_id": channel, "message": text}
        if thread is not None:
            tool_input["thread_ts"] = ts(thread)
        call = self.use(at, "slack_send_message_draft", tool_input, blob)
        if answer is not None:
            self.result(at + 1, call, answer)
        elif saved:
            self.result(at + 1, call, json.dumps({"result": "Draft saved", "channel_link": "https://example.invalid/client/T0FIXTURE/" + channel}))
        else:
            self.result(at + 1, call, "Error: the draft could not be saved", error=True, as_list=False)

    def thread(self, at, channel, parent, posts, layout="thread"):
        """posts: (seconds, who, text). The first is the thread's parent message."""
        call = self.use(at, "slack_read_thread", {"channel_id": channel, "message_ts": ts(parent)})
        self.result(at + 1, call, json.dumps({"messages": thread_text(posts, layout)}))

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
        out.append("From: %s (%s)\nTime: 2026-11-02 10:00:00 EST\nMessage TS: %s\n%s\n" % (who[0], who[1], ts(seconds), text))
    return "\n".join(out)


LONG = ("The harbour survey covered 14 berths, 3 cranes and 220 metres of quay. "
        "Of the 14 berths, 9 need new fenders and 5 need dredging. "
        "Can you confirm which berths the dredger should start on?")
SHORT = "9 berths need new fenders. Can you confirm where the dredger starts?"


def basics(folder):
    r = Records()
    # One: figures cut, shortened, the ask reworded. Somebody else posts in between.
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
    # Six: a draft at the top of a channel, read back through the channel.
    r.draft(6000, "C0FIXTURE07", None, "The winter mooring list is ready for the harbour office to read through and comment on.")
    r.channel(6900, "C0FIXTURE07", [
        (6100, ME, "Nothing here matches the draft at all, it was written again from the start."),
        (6050, OTHER, "Morning all.")])
    # A line that is not UTF-8 and a line that is not JSON, which a record file can hold.
    r.write(folder, "session-one.jsonl", extra=b'{"type":"user","message":"\xff\xfe"}\n{not json\n')
    # The same records again in a second file, as a resumed session keeps them.
    r.write(folder, "session-one-resumed.jsonl")


def many(folder, per_thread):
    """Pairs that each cut figures and length, spread over threads as per_thread says."""
    r = Records()
    at = 10000
    for t, count in enumerate(per_thread):
        parent = at
        channel = "C0FIXTURE%02d" % (20 + t)
        posts = [(parent, OTHER, "Thread %d about the tide gauge." % t)]
        for k in range(count):
            at += 100
            r.draft(at, channel, parent, "Gauge %d read 41 at dawn, 57 at noon and 63 at dusk, against 38, 52 and 60 last week." % k)
            at += 100
            posts.append((at, ME, "Gauge %d read 57 at noon." % k))
        at += 100
        r.thread(at, channel, parent, posts)
        at += 1000
    r.write(folder, "session-many.jsonl")


def unknown(folder):
    r = Records()
    r.draft(100, "C0FIXTURE30", 0, "The lock gates close at nine.")
    r.thread(900, "C0FIXTURE30", 0, [
        (0, OTHER, "When do the lock gates close?"),
        (200, ME, "The lock gates close at nine.")], layout="unknown")
    r.write(folder, "session-unknown.jsonl")


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
    elif which == "unknown":
        unknown(folder)
    else:
        sys.exit("build.py: no fixture called " + which)


main()
