#!/usr/bin/env python3
"""The context line and the long session nudge (claude-config#1960, #1940), read from transcripts.

Run by hooks/context-size-notice.sh on every PostToolUse, in the main session and in every
subagent, with the hook payload on stdin. It reads ONLY usage fields and three kinds of marker from
the transcript, never what anybody wrote (L222), and it reads each transcript once over its life:
the byte offset it has read to is kept per session and agent, and each run reads only what was
appended since, so a call costs the same at request 10 as at request 7,000.

THE CONTEXT LINE (#1960, decided by Dan 2026-11-01). A request's context is everything it sent:
input_tokens + cache_read_input_tokens + cache_creation_input_tokens of its usage. Once the last
request of a builder (any subagent) or an orchestrator (a main session that has dispatched an agent
or set a /goal) carries more than CONTEXT_LINE_TOKENS, it is told, once, to write down what it has
decided and then restart or compact. Said once per BAND of the line (200K, 400K, 600K, ...), so one
that carries on is told again a band later rather than on every call, and re-armed when a
compaction brings it back under the line.

  Default 200,000. Measured on the personal MacBook with
  `python3 tools/cache-usage.py --days 31 --now 2026-11-01T16:00:00Z --summary`, whose CONTEXT lines
  use this module's default and context_of, so re-running it re-measures this claim: 559 of 677
  subagents passed the line, and their requests over it were 75.1% of subagent requests and read
  88.5% of subagent tokens; 249 of 8,576 main sessions passed it, with 57.2% of main requests and
  85.4% of main tokens. The issue's own audit (one project, five days) found one goal run's
  orchestrator averaging about 500K a turn and peaking near 966K, 94% of that project's spend. The
  line sits where most builders cross it on purpose: the cost is in the requests above it.

THE LONG SESSION NUDGE (#1940, decided by Dan 2026-11-01). A main session compacted
CONTEXT_COMPACTIONS_NUDGE times is told, with Dan, that it should start fresh, and what its next
request costs: at least what its last one carried, beside its average, its size before its last
compaction, and what it started from. Said again at each further multiple. A compaction is a
`type: system, subtype: compact_boundary` line (measured on Claude Code 2.1.316 transcripts, its
compactMetadata carrying preTokens and postTokens).

  Default 5. Measured on Bidspoke 16 to 30 October 2026 (bidspoke#2192): one session with 13
  compactions and 7,309 requests read 3.63 billion tokens, 16% of everything in the window. On the
  personal MacBook, in the window above, no main session reached 5 (COMPACTIONS max=4), and the 4
  with 3 or more read 26.1% of main session tokens (`--compactions 3`). So the default fires on the
  rare runaway session, never on an ordinary long one. The COMPACTIONS line re-measures it.

An orchestrator is a main session whose transcript holds an Agent (or Task) tool_use in an assistant
message, or a goal_status attachment set by /goal (sentinel true, met false). "Has ever been" is the
question here, not "is now": a goal that ended still leaves the transcript it made, so this is not
the goal reader in mod-kit/hooks/goal.ts and does not answer its question (L342).

State: CONTEXT_SIZE_STATE_DIR (default $CLAUDE_HOME/state/context-size, never synced), one
<session>.<agent or main>.json and a .lock beside it per transcript. Two tool calls finishing at
once run this twice, so the read, decide and write happen under an flock taken without waiting: a
run that finds it held says nothing and leaves the work to the next call. Never blocks the tool:
the hook exits 0 on every path.
"""
import fcntl
import json
import os
import re
import sys

DEFAULT_LINE = 200_000
DEFAULT_COMPACTIONS = 5
STATE_VERSION = 1
CHUNK = 8 << 20
NAME = re.compile(r"^[A-Za-z0-9_-]+$")


def setting(name, default):
    raw = os.environ.get(name, "")
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value > 0 else default


def num(value):
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def context_of(usage):
    """A request's whole context, the one sum this hook and tools/cache-usage.py both use."""
    return (num(usage.get("input_tokens")) + num(usage.get("cache_read_input_tokens"))
            + num(usage.get("cache_creation_input_tokens")))


def fresh_state():
    return {"v": STATE_VERSION, "offset": 0, "last_id": None, "last_ctx": 0,
            "first_ctx": 0, "requests": 0, "ctx_sum": 0, "compactions": 0, "last_pre": 0,
            "orchestrator": False, "band_told": 0, "compactions_told": 0, "unreadable_told": False}


def is_dispatch(d):
    if d.get("type") != "assistant":
        return False
    content = (d.get("message") or {}).get("content")
    if not isinstance(content, list):
        return False
    return any(isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") in ("Agent", "Task")
               for b in content)


def is_goal_set(d):
    a = d.get("attachment") if d.get("type") == "attachment" else None
    return isinstance(a, dict) and a.get("type") == "goal_status" and a.get("sentinel") is True \
        and a.get("met") is False


def scan(state, data, is_main):
    """Fold the complete lines of `data` into `state`; returns the bytes consumed."""
    end = data.rfind(b"\n")
    if end < 0:
        return 0
    for raw in data[:end + 1].split(b"\n"):
        if not raw:
            continue
        line = raw.decode("utf-8", "replace")
        wanted_usage = '"usage"' in line and '"assistant"' in line
        wanted_compact = '"compact_boundary"' in line
        wanted_dispatch = is_main and not state["orchestrator"] and '"tool_use"' in line \
            and ('"name":"Agent"' in line or '"name":"Task"' in line)
        wanted_goal = is_main and not state["orchestrator"] and '"type":"goal_status"' in line
        if not (wanted_usage or wanted_compact or wanted_dispatch or wanted_goal):
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if not isinstance(d, dict):
            continue
        if wanted_compact and d.get("type") == "system" and d.get("subtype") == "compact_boundary":
            state["compactions"] += 1
            meta = d.get("compactMetadata") if isinstance(d.get("compactMetadata"), dict) else {}
            state["last_pre"] = num(meta.get("preTokens"))
        if (wanted_dispatch and is_dispatch(d)) or (wanted_goal and is_goal_set(d)):
            state["orchestrator"] = True
        if wanted_usage and d.get("type") == "assistant":
            msg = d.get("message") if isinstance(d.get("message"), dict) else {}
            usage = msg.get("usage")
            if not isinstance(usage, dict) or msg.get("model") == "<synthetic>":
                continue
            ctx = context_of(usage)
            mid = msg.get("id")
            if mid is not None and mid == state["last_id"]:
                # Another content block of the same request: the last line's usage is the request's.
                state["ctx_sum"] += ctx - state["last_ctx"]
            else:
                state["requests"] += 1
                state["ctx_sum"] += ctx
            if state["requests"] == 1:
                state["first_ctx"] = ctx
            state["last_id"] = mid
            state["last_ctx"] = ctx
    return end + 1


WRITE_DOWN = (
    "the goal or list being worked, in Dan's words, and every constraint he has stated, quoted with "
    "its date; every decision made in this conversation, with its reason and what was ruled out; "
    "the state left behind (branches, worktrees, commit shas, pull requests open, merged or live, "
    "agents and background jobs still running, with their ids); each item's status, and the exact next step of the "
    "one in progress; and every question waiting on Dan"
)


def line_notice(state, line, is_main):
    who = "this session's" if is_main else "this agent's"
    head = ("Context line (claude-config#1960): %s last request carried %s tokens of context, past "
            "the line of %s, and every request from here rereads all of it. "
            % (who, "{:,}".format(state["last_ctx"]), "{:,}".format(line)))
    if is_main:
        ctx = head + (
            "Before going on, write down what you have decided: put each decision that belongs to "
            "an issue on that issue as a comment, and the rest in handoff.md in your scratchpad "
            "folder, covering %s. Then tell Dan in one line that the session is at the context line "
            "and where the note is, so he can type /compact or start a fresh session from the note. "
            "Agents you dispatched keep running either way." % WRITE_DOWN)
        system = ("This session is past the context line: its last request carried %s tokens "
                  "(the line is %s). It has been asked to write down what it has decided, then "
                  "compact or start a fresh session (claude-config#1960)."
                  % ("{:,}".format(state["last_ctx"]), "{:,}".format(line)))
        return ctx, system
    ctx = head + (
        "Before going on, write down what you have decided in handoff.md in your scratchpad folder, "
        "covering %s. Then, unless only the push and the report are left, hand back now, saying you "
        "stopped at the context line and naming the handoff file, so the main session can give the "
        "rest to a fresh agent." % WRITE_DOWN)
    return ctx, ""


def compaction_notice(state):
    avg = state["ctx_sum"] // max(state["requests"], 1)
    parts = ["This session has been compacted %d times (claude-config#1940)." % state["compactions"],
             "Its next request reads at least %s tokens, what its last one carried;"
             % "{:,}".format(state["last_ctx"]),
             "across its %s requests it has averaged %s," % ("{:,}".format(state["requests"]),
                                                             "{:,}".format(avg))]
    if state["last_pre"]:
        parts.append("it grew to %s before its last compaction," % "{:,}".format(state["last_pre"]))
    parts.append("and it started from %s. A fresh session starts near that first figure: run "
                 "/handoff, then start a new session with the saved prompt."
                 % "{:,}".format(state["first_ctx"]))
    text = " ".join(parts)
    return text, text


def emit(ctx, system):
    out = {"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": ctx}}
    if system:
        out["systemMessage"] = system
    sys.stdout.write(json.dumps(out) + "\n")


def transcript_of(d):
    """(path, is_main, agent): the agent's OWN transcript in a subagent, never its parent's."""
    parent = d.get("transcript_path") if isinstance(d.get("transcript_path"), str) else ""
    if "agent_id" not in d:
        return parent, True, ""
    agent = d.get("agent_id") if isinstance(d.get("agent_id"), str) else ""
    own = d.get("agent_transcript_path")
    if isinstance(own, str) and own:
        return own, False, agent
    if parent.endswith(".jsonl") and NAME.match(agent or "-bad-"):
        return os.path.join(parent[:-len(".jsonl")], "subagents", "agent-%s.jsonl" % agent), False, agent
    return "", False, agent


def run(payload_bytes):
    try:
        d = json.loads(payload_bytes.decode("utf-8", "replace"))
    except ValueError:
        return
    if not isinstance(d, dict):
        return
    session = d.get("session_id") if isinstance(d.get("session_id"), str) else ""
    path, is_main, agent = transcript_of(d)
    if not path or not NAME.match(session or "-bad-") or (agent and not NAME.match(agent)):
        return
    home = os.environ.get("CLAUDE_HOME") or os.path.expanduser("~/.claude")
    state_dir = os.environ.get("CONTEXT_SIZE_STATE_DIR") or os.path.join(home, "state", "context-size")
    key = "%s.%s" % (session, agent or "main")
    try:
        os.makedirs(state_dir, exist_ok=True)
        lock_fd = os.open(os.path.join(state_dir, key + ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    except OSError as err:
        # Nothing said in the session: what cannot be recorded would be said on every call.
        sys.stderr.write("context-size-notice: state folder %s not writable (%s)\n" % (state_dir, err))
        return
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(lock_fd)
        return
    try:
        decide(state_dir, key, path, is_main)
    finally:
        os.close(lock_fd)


def save(state_path, state):
    tmp = state_path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, state_path)


def decide(state_dir, key, path, is_main):
    state_path = os.path.join(state_dir, key + ".json")
    try:
        with open(state_path) as fh:
            state = json.load(fh)
        if not isinstance(state, dict) or state.get("v") != STATE_VERSION:
            state = fresh_state()
    except (OSError, ValueError):
        state = fresh_state()
    try:
        size = os.path.getsize(path)
        fh = open(path, "rb")
    except OSError as err:
        if state.get("unreadable_told"):
            return
        state["unreadable_told"] = True
        try:
            save(state_path, state)
        except OSError:
            return
        msg = ("The context check could not read this %s's transcript (%s: %s), so its size is not "
               "being watched (claude-config#1960)." % ("session" if is_main else "agent", path,
                                                        err.strerror or err))
        emit(msg, msg if is_main else "")
        return
    with fh:
        if size < state["offset"]:
            state = fresh_state()   # rewritten under us: read it again from the start
        fh.seek(state["offset"])
        # Read in pieces, so the first run over a long resumed transcript never holds it whole.
        buf = b""
        while True:
            chunk = fh.read(CHUNK)
            if not chunk:
                break
            buf += chunk
            used = scan(state, buf, is_main)
            state["offset"] += used
            buf = buf[used:]
    state["unreadable_told"] = False

    line = setting("CONTEXT_LINE_TOKENS", DEFAULT_LINE)
    every = setting("CONTEXT_COMPACTIONS_NUDGE", DEFAULT_COMPACTIONS)
    band = state["last_ctx"] // line if state["requests"] else 0
    say = []
    if band == 0:
        state["band_told"] = 0
    elif band > state["band_told"] and (not is_main or state["orchestrator"]):
        state["band_told"] = band
        say.append(line_notice(state, line, is_main))
    step = state["compactions"] // every
    if is_main and step > state["compactions_told"]:
        state["compactions_told"] = step
        say.append(compaction_notice(state))
    try:
        save(state_path, state)
    except OSError as err:
        sys.stderr.write("context-size-notice: could not record %s (%s)\n" % (state_path, err))
        return
    if say:
        emit("\n\n".join(c for c, _ in say), "\n\n".join(s for _, s in say if s))


if __name__ == "__main__":
    try:
        run(sys.stdin.buffer.read())
    except Exception as err:  # a crash here must never reach the tool call as a failure
        sys.stderr.write("context-size-notice: %s\n" % err)
    sys.exit(0)
