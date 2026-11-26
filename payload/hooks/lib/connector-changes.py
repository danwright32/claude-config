"""Which connector calls connector-change-ask.sh asks Dan about (claude-config#3618).

Sessions reach business systems through MCP connectors. Database writes already stop for Dan
(db-write-ask.sh) and Slack messages are saved as drafts. For Regal, Better Stack and Cal a call
that deletes something or changes a live setting was decided by auto mode's check alone: in the 30
days to 2026-11-25 it let 7 writes to Regal and Better Stack through with nobody asked, by the
issue's own count. Dan chose on 2026-11-25 "Ask before live deletes and changes" and, asked whether
every write on these connectors should ask, "Keep it to deletes (Recommended)".

THE RULE, which is the whole of what is asked about:

  WHICH SERVER. A tool is named mcp__<server>__<tool>. The server is matched by a part of its
  name, never the whole of it, because one connector is reached under more than one server name
  (a claude.ai connector is claude_ai_<name>, a plugin's server is plugin_<plugin>_<server>, and a
  server somebody added by hand has whatever name they gave it):
    Regal         the server's name holds "regal", in any case
    Better Stack  the server's name holds "betterstack" once everything but letters and digits
                  is taken out, so Better_Stack, better-stack and betterstack all count
    Cal           one whole word of the server's name is "cal" or "calcom", so claude_ai_Cal and
                  cal_com count and Google_Calendar does not

  WHICH TOOL. On such a server, a tool whose own name holds delet, remov, cancel, reset or paus,
  in any case and anywhere in it. Those five are the issue's own count rule ("a name that reads as
  a delete, cancel, reset or pause", with Better Stack's and Cal's remove tools counted in). The
  part of a word is matched and not the whole word, so a name written with no separator still
  asks; the cost is that a read whose name holds one of them (a list of presets) asks too, which
  is the harmless side to be wrong on (L648). On Regal, four tools more, named by the issue
  because each changes what is live: update-journey, update-campaign, save-agent-live and
  update-routing-rule-set, however their words are joined.

  Everything else on these servers passes untouched: reads, creates and ordinary updates stay
  with auto mode's check, by Dan's second answer.

WHAT IT CANNOT READ IS ASKED ABOUT, never passed: a name on one of these servers with no tool
after it, and a payload that is not a tool call whose text names a tool the rule above asks about.

MEASURED. Regal's 115 tools and Cal's 92, as this Mac's session records listed them up to
2026-11-25, are in connector-change-ask-fixtures/ beside the hooks, and test-connector-change-ask.sh
runs every one of them through the hook: 14 of Regal's ask (10 deletes and the four above) and 7 of
Cal's (1 cancel, 4 deletes, 2 removes), and no other. Better Stack's tools are on the work MacBook
only, in a plugin's server, and were not measured: for them the rule rests on the verbs alone.

Run as a program it reads one hook payload on stdin and prints nothing (the call passes) or
"ask", the kind of call and why, split by the unit separator, for the hook to word and send.

  judge(name)            None, or (connector, tool, what it does) for a tool the rule asks about;
                         tool is None when the name has no tool this could read
  verdict(raw)           None, or (kind of call, why) for one hook payload as text
"""
import json
import re
import sys

US = "\x1f"
# How much of a call's input a question spells out.
INPUT_SHOWN = 300

# The part of a tool's own name that says what it does, and the word for it in a question.
VERBS = (("delet", "deletes"), ("remov", "removes"), ("cancel", "cancels"), ("reset", "resets"), ("paus", "pauses"))

# Regal's four tools that change what is live with no such word in their names.
REGAL_LIVE = {
    "update-journey": "changes a journey that may be live",
    "update-campaign": "changes a campaign that may be live",
    "save-agent-live": "saves an agent as its live version",
    "update-routing-rule-set": "changes a routing rule set that may be live",
}


def words_of(text):
    """The words of a name, lower case: split where it is not a letter or digit, and at a capital."""
    return [w for w in re.split(r"[^a-z0-9]+", re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", text).lower()) if w]


def is_regal(server):
    return "regal" in server.lower()


def is_better_stack(server):
    return "betterstack" in re.sub(r"[^a-z0-9]", "", server.lower())


def is_cal(server):
    w = words_of(server)
    return "cal" in w or "calcom" in w


CONNECTORS = (("Regal", is_regal), ("Better Stack", is_better_stack), ("Cal", is_cal))


def splits(name):
    """Every (server, tool) a name mcp__<server>__<tool> can be read as. Almost always one; a server
    whose own name holds a double underscore gives more, and each is judged."""
    rest = name[len("mcp__"):]
    out = []
    at = rest.find("__")
    while at != -1:
        if at > 0 and rest[at + 2:]:
            out.append((rest[:at], rest[at + 2:]))
        at = rest.find("__", at + 1)
    return out


def does(connector, tool):
    """What a tool does, by its name, when the rule asks about it; else None."""
    low = tool.lower()
    if connector == "Regal":
        key = "-".join(words_of(tool))
        if key in REGAL_LIVE:
            return REGAL_LIVE[key]
    for stem, verb in VERBS:
        if stem in low:
            rest = " ".join(w for w in words_of(tool) if stem not in w)
            return "by its name " + verb + " something live" + (" (" + rest + ")" if rest else "")
    return None


def judge(name):
    if not isinstance(name, str) or not name.startswith("mcp__"):
        return None
    parts = splits(name)
    if not parts:
        # No tool after the server: on one of these servers that is a call nobody can classify.
        for connector, on in CONNECTORS:
            if on(name[len("mcp__"):]):
                return connector, None, None
        return None
    for server, tool in parts:
        for connector, on in CONNECTORS:
            if on(server):
                what = does(connector, tool)
                if what:
                    return connector, tool, what
    return None


def shown(tool_input):
    """A call's input in a few words, for the question: each field and its value, cut short."""
    if not isinstance(tool_input, dict):
        return "an input this hook could not read"
    if not tool_input:
        return "no input"
    bits = []
    for k, v in tool_input.items():
        bits.append(str(k) + "=" + (v if isinstance(v, str) else json.dumps(v, ensure_ascii=True, separators=(",", ":"))))
    text = ", ".join(bits)
    text = "".join(c if c.isprintable() else " " for c in text)
    if len(text) > INPUT_SHOWN:
        text = text[:INPUT_SHOWN] + " ... (cut short)"
    return text


def verdict(raw):
    try:
        d = json.loads(raw)
    except Exception:
        d = None
    name = d.get("tool_name") if isinstance(d, dict) else None
    if isinstance(name, str):
        found = judge(name)
        if not found:
            return None
        connector, tool, what = found
        if tool is None:
            return ("this " + connector + " call",
                    name + ", whose name holds no tool this hook could read, so whether it deletes or changes "
                    "something live could not be told.")
        return ("this " + connector + " call",
                tool + ", which " + what + ". It was called with " + shown(d.get("tool_input")) + ".")
    # A payload that is not a tool call is judged by its text: the tool it names when it names one,
    # else every MCP tool name in it. One the rule asks about is asked about, saying why.
    m = re.search(r"\"tool_name\"\s*:\s*\"([^\"\\]*)\"", raw)
    names = [m.group(1)] if m else re.findall(r"mcp__[A-Za-z0-9_.-]+", raw)
    for n in names:
        found = judge(n)
        if found:
            connector, tool, what = found
            return ("this " + connector + " call",
                    "the payload could not be read as a tool call, and its text names " + n
                    + (", which " + what if what else "") + ".")
    return None


def main():
    sys.stdout.reconfigure(errors="replace")
    raw = sys.stdin.buffer.read().decode("utf-8", "replace")
    v = verdict(raw)
    if v:
        sys.stdout.write("ask" + US + US.join(t.replace(US, " ").replace("\x00", "") for t in v))


if __name__ == "__main__":
    main()
