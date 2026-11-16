#!/usr/bin/env python3
"""How much the subagent cap was in the way, from the subagent transcripts (claude-config#2552).

    python3 tools/agent-cap-report.py --since ISO --until ISO --cap N
                                      [--root ~/.claude/projects] [--tz America/New_York]
                                      [--min-samples 8]

The cap for each Mac lives in payload/hooks/agent-cap.sh. This is the measurement that number is
reviewed against: run it over the days since the cap last changed, with --cap set to that cap, and
set the result beside the last reading on the issue. --since and --until need an offset
(2026-11-09T22:14:00-05:00), because a bare time would be read in whatever zone the Mac is in.

What it reads. One file per subagent, `<root>/<project>/<session>/subagents/agent-<id>.jsonl`.
From each line it takes the timestamp, the working folder, the usage fields, the tool call ids, the
text of an API error shown to the agent, and the text of a shell command, which it uses only to
name the command's KIND (tests, typecheck, build) and never prints: transcripts hold private work
(L222). The repository label is the name of the agent's working folder, with a worktree under
`.claude/worktrees/` named after the checkout it belongs to. No repository is named in this file.

What counts as running. An agent that reported and was woken again later is not running in
between: a gap of over five minutes with no command open ends one active stretch and starts the
next. Counting first line to last overstated running time by 43% on 2026-11-09. An agent whose
lines in the window span under 30 seconds never really ran and is left out (`dropped_short`).

Lines:

    WINDOW          the window, its length in days, the cap judged and the timezone for days
    AGENTS          agents kept, sessions, agent hours, and everything left out, each counted
    BY_DAY          agent hours per day
    BY_REPO         agents per working folder label
    BY_MODEL        agents, agent hours, output tokens and requests per agent hour, share in shell
    SESSION_LEVELS  inside one session: share of running time with k agents at once
    AT_CAP          session time at exactly the cap, its stretches of 5 minutes or more, and how
                    many sessions ever reached it
    ABOVE_CAP       session time above the cap (a planning panel is exempt from it)
    MAC_LEVELS      every session together: agents at once, by share of the time any agent ran
    TIME            share of agent time inside shell commands and inside heavy ones, tokens, requests
    HEAVY_OVERLAP   share of heavy command time by how many heavy commands were running at once
    SLOWDOWN        one label and kind: median seconds by how many agents were running at its start
    LIMIT_DAYS      days on which a usage limit or credit message reached an agent

Known limits, to carry into any reading:

- AT_CAP is an upper bound on what the cap cost. A session at the cap with nothing queued reads
  the same as one with ten items waiting.
- SLOWDOWN compares commands of one kind, which are often different commands, and only those of
  20 seconds or more. A bucket with under --min-samples commands prints `few`.
- A message whose model is `<synthetic>` is written by the client, not the API: it is not a
  request and does not name the agent's model.
- Agents started by a workflow run sit in `subagents/workflows/<run>/`. They are counted in
  `workflow_agents` and left out of every other figure, as the 2026-11-09 baseline left them out.

Exits 1 with NO TRANSCRIPTS ROOT, WINDOW IS EMPTY, NEEDS AN OFFSET or NO AGENTS IN WINDOW rather
than print an empty report, which would read as a quiet week (L90). A transcript that cannot be
opened is counted in `unreadable`, and a line that is not JSON in `bad_lines`. Read only.
"""
import argparse
import bisect
import collections
import glob
import json
import os
import re
import statistics
import sys
from datetime import datetime
from multiprocessing import Pool
from zoneinfo import ZoneInfo

H = 3600.0
IDLE_GAP_S = 300          # a longer gap with no command open is not running
SHORT_AGENT_S = 30        # an agent spanning less never really ran
STRETCH_S = 300           # a stretch at the cap shorter than this is not reported as one
SLOW_CALL_S = 20          # SLOWDOWN compares commands at least this long
HEAVY_CALL_S = 3          # a heavy command shorter than this is not kept
KINDS = [("config suite", re.compile(r"run-all-tests\.sh")),
         ("browser tests", re.compile(r"playwright")),
         ("tests", re.compile(r"vitest|npm (run )?test|pnpm (run )?test|jest|node --test|swift test")),
         ("typecheck", re.compile(r"\btsc\b|typecheck")),
         ("build", re.compile(r"next build|(npm|pnpm) run build|opennext|xcodebuild|swift build"))]
LEVEL_BUCKETS = ((1, 2), (3, 4), (5, 6), (7, 9), (10, None))
OVERLAP_BUCKETS = ((1, 1), (2, 2), (3, 4), (5, 8), (9, None))
SERIAL_BELOW = 64         # under this many files a worker pool costs more than it saves


def refuse(message):
    print(message)
    sys.exit(1)


def bucket_name(lo, hi):
    return f"{lo}+" if hi is None else str(lo) if lo == hi else f"{lo}-{hi}"


def in_bucket(n, lo, hi):
    return n >= lo and (hi is None or n <= hi)


def label_of(cwd):
    """The working folder's name, a worktree named after its checkout."""
    if not cwd:
        return "unknown"
    return os.path.basename(cwd.split("/.claude/worktrees/")[0].rstrip("/")) or "unknown"


def read_agent(job):
    """One transcript, cut to the window. Returns a dict, or None when no line fell inside it."""
    path, since, until = job
    segs = []
    seg_start = prev = None
    usage = {}
    model = cwd = None
    open_calls = {}
    shell_s = 0.0
    calls = []
    errors = []
    bad = 0
    try:
        handle = open(path, errors="replace")
    except OSError:
        return {"unreadable": True}
    with handle:
        for line in handle:
            try:
                d = json.loads(line)
            except ValueError:
                bad += 1
                continue
            stamp = d.get("timestamp") if isinstance(d, dict) else None
            if not stamp:
                continue
            try:
                t = datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
            except (AttributeError, TypeError, ValueError):   # a timestamp that is not ISO text
                bad += 1
                continue
            if t < since or t >= until:
                continue
            if prev is not None and t - prev > IDLE_GAP_S and not open_calls:
                segs.append((seg_start, prev))
                seg_start = t
            if seg_start is None:
                seg_start = t
            prev = t
            # The line was written at a real time, so the agent was alive then whatever else it
            # holds. A field of some other shape than the client writes (usage as a list, a
            # command that is not text) makes the whole line a bad line, never a crash and never
            # a request, a model or a label read from half of it.
            try:
                m = d.get("message")
                if not isinstance(m, dict):
                    if isinstance(d.get("cwd"), str):
                        cwd = cwd or d["cwd"]
                    continue
                content = m.get("content")
                error = None
                if d.get("isApiErrorMessage"):
                    first = content[0] if isinstance(content, list) and content else None
                    error = (t, str(first.get("text", "") if isinstance(first, dict) else content)[:70])
                request = None
                if m.get("usage") and m.get("id") and m.get("model") != "<synthetic>":
                    out = m["usage"].get("output_tokens", 0) or 0
                    if not isinstance(m["id"], str) or not isinstance(m.get("model") or "", str) or not isinstance(out, (int, float)):
                        raise TypeError("usage, id or model of the wrong shape")
                    request = (m["id"], out, m.get("model"))
                opened, closed = [], []
                for b in content if isinstance(content, list) else []:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "tool_use":
                        cmd = (b.get("input") or {}).get("command", "") if b.get("name") == "Bash" else None
                        if not isinstance(b.get("id"), str) or not isinstance(cmd, (str, type(None))):
                            raise TypeError("tool call id or command of the wrong shape")
                        opened.append((b["id"], cmd))
                    elif b.get("type") == "tool_result" and isinstance(b.get("tool_use_id"), str):
                        closed.append(b["tool_use_id"])
                if d.get("cwd") is not None and not isinstance(d["cwd"], str):
                    raise TypeError("working folder of the wrong shape")
            except (AttributeError, TypeError):
                bad += 1
                continue
            # Nothing above changed what is kept, so a bad line leaves no half of itself behind.
            cwd = cwd or d.get("cwd")
            if error:
                errors.append(error)
            if request:
                usage[request[0]] = request[1]
                model = request[2] or model
            for call_id, cmd in opened:
                open_calls[call_id] = (t, cmd)
            for call_id in closed:
                if call_id not in open_calls:
                    continue
                t0, cmd = open_calls.pop(call_id)
                if cmd is None:
                    continue
                dur = max(0.0, t - t0)
                shell_s += dur
                kind = next((k for k, rx in KINDS if rx.search(cmd)), None)
                if kind and dur >= HEAVY_CALL_S:
                    calls.append((t0, dur, kind))
    if prev is None:
        return None
    segs.append((seg_start, prev))
    return {"segs": segs, "start": segs[0][0], "end": prev, "label": label_of(cwd), "model": model or "none",
            "out": sum(usage.values()), "requests": len(usage),
            "shell_s": shell_s, "calls": calls, "errors": errors, "bad": bad}


def levels(events):
    """Seconds spent at each count, from (time, +1 or -1) events."""
    out = collections.Counter()
    k = 0
    prev = None
    for t, d in sorted(events):
        if prev is not None and k > 0:
            out[k] += t - prev
        k += d
        prev = t
    return out


def stretches(events, wanted):
    """Lengths of the unbroken stretches during which wanted(count) held."""
    out = []
    k = 0
    began = None
    for t, d in sorted(events):
        k += d
        if wanted(k) and began is None:
            began = t
        elif not wanted(k) and began is not None:
            out.append(t - began)
            began = None
    return out


def time_weighted(lv, pct):
    total = sum(lv.values())
    run = 0
    for k in sorted(lv):
        run += lv[k]
        if run >= total * pct / 100:
            return k
    return 0


def parse_when(name, text):
    try:
        when = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        refuse(f"NEEDS AN OFFSET: {name} {text!r} is not an ISO time such as 2026-11-09T22:14:00-05:00.")
    if when.tzinfo is None:
        refuse(f"NEEDS AN OFFSET: {name} {text!r} has no offset, so it would be read in whatever zone this Mac is in. "
               "Write it like 2026-11-09T22:14:00-05:00.")
    return when


def main():
    ap = argparse.ArgumentParser(description="How much the subagent cap was in the way, from the subagent transcripts.")
    ap.add_argument("--since", required=True)
    ap.add_argument("--until", required=True)
    ap.add_argument("--cap", required=True, type=int)
    ap.add_argument("--root", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--tz", default="America/New_York")
    ap.add_argument("--min-samples", type=int, default=8)
    a = ap.parse_args()

    since_dt, until_dt = parse_when("--since", a.since), parse_when("--until", a.until)
    since, until = since_dt.timestamp(), until_dt.timestamp()
    if until <= since:
        refuse(f"WINDOW IS EMPTY: --until {a.until} is not after --since {a.since}.")
    if not os.path.isdir(a.root):
        refuse(f"NO TRANSCRIPTS ROOT: {a.root} is not a folder.")
    zone = ZoneInfo(a.tz)
    day = lambda t: datetime.fromtimestamp(t, zone).strftime("%m-%d")

    # A file last written before the window began holds no line inside it. One that is gone by the
    # time it is looked at (deleted since the listing, or a link to nothing) is unreadable.
    everything = []
    unreadable = 0
    for path in (glob.glob(os.path.join(a.root, "*", "*", "subagents", "agent-*.jsonl"))
                 + glob.glob(os.path.join(a.root, "*", "*", "subagents", "workflows", "*", "agent-*.jsonl"))):
        try:
            written = os.stat(path).st_mtime
        except OSError:
            unreadable += 1
            continue
        if written >= since:
            everything.append((path, since, until))
    if len(everything) < SERIAL_BELOW:
        read = [read_agent(j) for j in everything]
    else:
        with Pool(min(8, os.cpu_count() or 1)) as pool:
            read = pool.map(read_agent, everything, chunksize=8)
    rows = []
    bad_lines = short = flow_agents = 0
    for (path, _, _), r in zip(everything, read):
        if r is None:
            continue
        if r.get("unreadable"):
            unreadable += 1
            continue
        bad_lines += r["bad"]
        if os.sep + "workflows" + os.sep in path[len(a.root):]:
            flow_agents += 1
            continue
        if r["end"] - r["start"] < SHORT_AGENT_S:
            short += 1
            continue
        r["session"] = os.path.relpath(path, a.root).split(os.sep)[1]
        r["active"] = max(1.0, sum(e - s for s, e in r["segs"]))
        rows.append(r)
    if not rows:
        refuse(f"NO AGENTS IN WINDOW: no subagent ran for {SHORT_AGENT_S} seconds or more between {a.since} and {a.until} "
               f"under {a.root} ({len(everything)} transcripts written since then, {unreadable} unreadable, "
               f"{short} too short, {flow_agents} from workflows).")

    total_s = sum(r["active"] for r in rows)
    sessions = {r["session"] for r in rows}
    print(f"WINDOW\tsince={since_dt.isoformat()}\tuntil={until_dt.isoformat()}\tdays={(until - since) / 86400:.1f}\tcap={a.cap}\ttz={a.tz}")
    print(f"AGENTS\tagents={len(rows)}\tsessions={len(sessions)}\tagent_hours={total_s / H:.2f}\tdropped_short={short}"
          f"\tworkflow_agents={flow_agents}\tbad_lines={bad_lines}\tunreadable={unreadable}")

    by_day = collections.Counter()
    for r in rows:
        for s, e in r["segs"]:
            by_day[day(s)] += e - s
    for d in sorted(by_day):
        print(f"BY_DAY\t{d}\t{by_day[d] / H:.2f}")
    for label, n in collections.Counter(r["label"] for r in rows).most_common():
        print(f"BY_REPO\t{label}\t{n}")
    by_model = collections.defaultdict(list)
    for r in rows:
        by_model[r["model"]].append(r)
    for model, g in sorted(by_model.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        s = sum(r["active"] for r in g)
        print(f"BY_MODEL\t{model}\tagents={len(g)}\tagent_hours={s / H:.2f}\tout_per_hour={sum(r['out'] for r in g) / (s / H):.0f}"
              f"\trequests_per_hour={sum(r['requests'] for r in g) / (s / H):.0f}\tshell={100 * sum(r['shell_s'] for r in g) / s:.0f}%")

    by_session = collections.defaultdict(list)
    mac = []
    for r in rows:
        for s, e in r["segs"]:
            if e > s:
                by_session[r["session"]] += [(s, 1), (e, -1)]
                mac += [(s, 1), (e, -1)]
    session_lv = collections.Counter()
    at_cap, above_cap = [], []
    reached = 0
    for ev in by_session.values():
        lv = levels(ev)
        session_lv.update(lv)
        reached += 1 if lv and max(lv) >= a.cap else 0
        at_cap += stretches(ev, lambda k: k == a.cap)
        above_cap += stretches(ev, lambda k: k > a.cap)
    session_s = sum(session_lv.values()) or 1.0
    print(f"SESSION_LEVELS\thours={session_s / H:.2f}\t" + "\t".join(f"{k}={100 * session_lv[k] / session_s:.0f}%" for k in sorted(session_lv)))
    long_at = [x for x in at_cap if x >= STRETCH_S]
    print(f"AT_CAP\thours={session_lv[a.cap] / H:.2f}\tshare={100 * session_lv[a.cap] / session_s:.1f}%\tstretches={len(long_at)}"
          f"\tstretch_hours={sum(long_at) / H:.2f}\tlongest_min={max(long_at, default=0) / 60:.0f}\tsessions_reached={reached}/{len(by_session)}")
    print(f"ABOVE_CAP\thours={sum(v for k, v in session_lv.items() if k > a.cap) / H:.2f}\tstretches={len(above_cap)}"
          f"\tlongest_min={max(above_cap, default=0) / 60:.0f}")
    mac_lv = levels(mac)
    print(f"MAC_LEVELS\tmedian={time_weighted(mac_lv, 50)}\tp90={time_weighted(mac_lv, 90)}\tp99={time_weighted(mac_lv, 99)}\tmost={max(mac_lv, default=0)}")

    heavy_s = sum(dur for r in rows for _, dur, _ in r["calls"])
    print(f"TIME\tshell={100 * sum(r['shell_s'] for r in rows) / total_s:.0f}%\theavy={100 * heavy_s / total_s:.0f}%"
          f"\tout_per_agent_hour={sum(r['out'] for r in rows) / (total_s / H):.0f}\trequests_per_agent_hour={sum(r['requests'] for r in rows) / (total_s / H):.0f}")
    heavy_lv = levels([ev for r in rows for t0, dur, _ in r["calls"] for ev in ((t0, 1), (t0 + dur, -1))])
    weighted = sum(k * v for k, v in heavy_lv.items()) or 1.0
    print("HEAVY_OVERLAP\t" + "\t".join(
        f"{bucket_name(lo, hi)}={100 * sum(k * v for k, v in heavy_lv.items() if in_bucket(k, lo, hi)) / weighted:.0f}%"
        for lo, hi in OVERLAP_BUCKETS) + f"\tmost={max(heavy_lv, default=0)}")

    starts = sorted(s for s, d in mac if d == 1)
    ends = sorted(e for e, d in mac if d == -1)
    running = lambda t: bisect.bisect_right(starts, t) - bisect.bisect_right(ends, t)
    groups = collections.defaultdict(lambda: collections.defaultdict(list))
    for r in rows:
        for t0, dur, kind in r["calls"]:
            if dur >= SLOW_CALL_S:
                n = running(t0)
                for b in LEVEL_BUCKETS:
                    if in_bucket(n, *b):
                        groups[(r["label"], kind)][b].append(dur)
    for (label, kind), g in sorted(groups.items(), key=lambda kv: (-sum(len(v) for v in kv[1].values()), kv[0])):
        if not any(len(g[b]) >= a.min_samples for b in LEVEL_BUCKETS):
            continue
        print(f"SLOWDOWN\t{label}\t{kind}\t" + "\t".join(
            f"{bucket_name(*b)}=" + (f"{statistics.median(g[b]):.0f}s({len(g[b])})" if len(g[b]) >= a.min_samples else "few")
            for b in LEVEL_BUCKETS))

    limit_days = sorted({day(t) for r in rows for t, text in r["errors"] if "limit" in text.lower() or "usage credits" in text.lower()})
    print("\t".join(["LIMIT_DAYS", f"days={len(limit_days)}"] + limit_days))


if __name__ == "__main__":
    main()
