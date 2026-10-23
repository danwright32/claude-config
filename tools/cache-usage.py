#!/usr/bin/env python3
"""Prompt cache hit rate per main session and per subagent, from the transcripts (claude-config#1503).

    python3 tools/cache-usage.py [--days 7] [--now ISO] [--root ~/.claude/projects]
                                 [--rules ~/.claude/CLAUDE.md] [--summary]

Reads ONLY the usage fields of each assistant message, never its content (transcripts hold private
work, L222). Measured on Claude Code 2.1.309, 2026-10-23:

- A main session is `<root>/<project>/<session>.jsonl`; its lines carry `isSidechain: false`.
- A subagent is `<root>/<project>/<session>/subagents/agent-<id>.jsonl`; its lines carry
  `isSidechain: true` and `agentId`, and `agent-<id>.meta.json` beside it names its `agentType`.
  The kind is taken from the lines' `isSidechain`, the path only when no line says.
- One API response is written as one line per content block, every line repeating the same
  `message.id` and usage, so requests are counted by `message.id` (the last line's usage wins).
- `usage.cache_creation` splits each write into `ephemeral_5m_input_tokens` and
  `ephemeral_1h_input_tokens`, the two cache lifetimes.
- `model: "<synthetic>"` lines are written by the client, not the API, and are not requests.

Hit rate is cache read over all input (input + cache read + cache write). A subagent's FIRST request
cache write is its startup cost: the always loaded rules plus its brief, written uncached. It is set
against the size of the rules measured now: `--rules` and every `@file` it imports, in characters,
with tokens ESTIMATED as characters / 4 (labelled so; nothing here calls a tokenizer).

A transcript active in the window with no usage field at all is UNMEASURED, never zero (L90).
Exits 1 with NO TRANSCRIPTS ROOT or NO REQUESTS IN WINDOW rather than report an empty measurement.

Output is tab separated: WINDOW, RULES, SESSION rows (main and subagent), UNMEASURED rows, SUMMARY
per kind (main also split by `entrypoint`: `cli` is an interactive session, `sdk-cli` a headless
`claude -p` run), STARTUP, MALFORMED, END. `--summary` leaves out the per transcript rows.
"""
import argparse
import datetime
import glob
import json
import os
import re
import statistics
import sys

IMPORT = re.compile(r"^@(\S+)\s*$")


def parse_ts(text):
    if not isinstance(text, str):
        return None
    try:
        dt = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    # A timestamp written without an offset is read as UTC, the zone every transcript line uses,
    # rather than left naive to crash the comparison against the window.
    return dt if dt.tzinfo is not None else dt.replace(tzinfo=datetime.timezone.utc)


def iso(dt):
    return dt.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def num(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else 0


def rate(read, total):
    return "n/a" if total <= 0 else "%.1f%%" % (100.0 * read / total)


def measure_rules(path):
    """(files [(path, chars)], missing [path]) for a CLAUDE.md and its @imports, followed once each."""
    files, missing, seen, todo = [], [], set(), [os.path.abspath(path)]
    while todo:
        p = todo.pop(0)
        if p in seen:
            continue
        seen.add(p)
        try:
            with open(p, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            missing.append(p)
            continue
        files.append((p, len(text)))
        base = os.path.dirname(p)
        for line in text.splitlines():
            m = IMPORT.match(line)
            if m:
                target = os.path.expanduser(m.group(1))
                todo.append(os.path.abspath(os.path.join(base, target)))
    return files, missing


def read_transcript(path, since, until, counters):
    """Usage records of one transcript: a dict describing it, or None when it was not active."""
    is_side, agent_id, session_id, entrypoint = None, None, None, None
    requests = {}
    order = []
    no_usage = 0
    any_usage = False
    active = False
    first = None
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        counters["unreadable"] += 1
        return None
    with fh:
        for line in fh:
            if not line.strip():
                continue
            try:
                d = json.loads(line)
            except ValueError:
                counters["malformed"] += 1
                continue
            if not isinstance(d, dict):
                counters["malformed"] += 1
                continue
            ts = parse_ts(d.get("timestamp"))
            in_window = ts is not None and since <= ts < until
            if in_window:
                active = True
            if isinstance(d.get("isSidechain"), bool) and is_side is None:
                is_side = d["isSidechain"]
            if agent_id is None and isinstance(d.get("agentId"), str):
                agent_id = d["agentId"]
            if session_id is None and isinstance(d.get("sessionId"), str):
                session_id = d["sessionId"]
            if d.get("type") != "assistant":
                continue
            msg = d.get("message") if isinstance(d.get("message"), dict) else {}
            if msg.get("model") == "<synthetic>":
                continue
            usage = msg.get("usage")
            if not isinstance(usage, dict):
                if in_window:
                    no_usage += 1
                continue
            any_usage = True
            key = msg.get("id") or d.get("requestId") or ("line", counters["lines"])
            counters["lines"] += 1
            if key not in requests:
                order.append(key)
                if ts is None:
                    # No usable timestamp: it cannot be placed in or out of the window, so it is
                    # counted where the report says so, never silently dropped.
                    counters["untimed"] += 1
                if first is None:
                    first = (ts, usage)
            requests[key] = (ts, in_window, usage)
            if entrypoint is None and isinstance(d.get("entrypoint"), str):
                entrypoint = d["entrypoint"]
    if not active:
        return None
    return {
        "is_side": is_side, "agent_id": agent_id, "session_id": session_id,
        "entrypoint": entrypoint, "requests": [requests[k] for k in order],
        "no_usage": no_usage, "any_usage": any_usage, "first": first,
    }


def totals(usages):
    t = {"requests": 0, "input": 0, "read": 0, "write": 0, "w5": 0, "w1": 0}
    for u in usages:
        t["requests"] += 1
        t["input"] += num(u.get("input_tokens"))
        t["read"] += num(u.get("cache_read_input_tokens"))
        t["write"] += num(u.get("cache_creation_input_tokens"))
        cc = u.get("cache_creation") if isinstance(u.get("cache_creation"), dict) else {}
        t["w5"] += num(cc.get("ephemeral_5m_input_tokens"))
        t["w1"] += num(cc.get("ephemeral_1h_input_tokens"))
    t["all"] = t["input"] + t["read"] + t["write"]
    return t


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--rules", default=os.path.expanduser("~/.claude/CLAUDE.md"))
    ap.add_argument("--days", type=float, default=7)
    ap.add_argument("--now", default=None)
    ap.add_argument("--summary", action="store_true")
    a = ap.parse_args(argv)

    until = parse_ts(a.now) if a.now else datetime.datetime.now(datetime.timezone.utc)
    if until is None:
        print("BAD --now: %s" % a.now)
        return 2
    if until.tzinfo is None:
        until = until.replace(tzinfo=datetime.timezone.utc)
    since = until - datetime.timedelta(days=a.days)
    if not os.path.isdir(a.root):
        print("NO TRANSCRIPTS ROOT: %s" % a.root)
        return 1

    out = ["WINDOW\tsince=%s\tuntil=%s" % (iso(since), iso(until))]
    rule_files, rule_missing = measure_rules(a.rules)
    for p, chars in rule_files:
        out.append("RULES\tfile\t%s\tchars=%d" % (p, chars))
    for p in rule_missing:
        out.append("RULES\tmissing\t%s" % p)
    rule_chars = sum(c for _, c in rule_files)
    rule_tokens = rule_chars // 4
    out.append("RULES\ttotal\tfiles=%d\tchars=%d\tapprox_tokens=%d (chars/4, an estimate)"
               % (len(rule_files), rule_chars, rule_tokens))

    paths = glob.glob(os.path.join(a.root, "*", "*.jsonl"))
    paths += glob.glob(os.path.join(a.root, "*", "*", "subagents", "*.jsonl"))
    counters = {"malformed": 0, "unreadable": 0, "lines": 0, "untimed": 0}
    rows, unmeasured = [], []
    kinds = {"main": {"usages": [], "transcripts": 0, "unmeasured": 0},
             "subagent": {"usages": [], "transcripts": 0, "unmeasured": 0}}
    starts = []
    by_entry = {}
    since_epoch = since.timestamp()
    for path in sorted(paths):
        try:
            if os.path.getmtime(path) < since_epoch:
                continue
        except OSError:
            continue
        t = read_transcript(path, since, until, counters)
        if t is None:
            continue
        in_sub_dir = os.path.basename(os.path.dirname(path)) == "subagents"
        kind = "subagent" if (t["is_side"] if t["is_side"] is not None else in_sub_dir) else "main"
        if kind == "subagent":
            ident = t["agent_id"] or re.sub(r"^agent-", "", os.path.basename(path)[:-6])
            parent = os.path.basename(os.path.dirname(os.path.dirname(path)))
            agent_type = "unknown"
            meta = path[:-6] + ".meta.json"
            try:
                with open(meta, encoding="utf-8") as fh:
                    m = json.load(fh)
                if isinstance(m, dict) and isinstance(m.get("agentType"), str):
                    agent_type = m["agentType"]
            except (OSError, ValueError):
                pass
            label = "subagent\t%s\tparent=%s\ttype=%s" % (ident, parent, agent_type)
        else:
            ident = t["session_id"] or os.path.basename(path)[:-6]
            project = os.path.basename(os.path.dirname(path))
            label = "main\t%s\t%s\tentrypoint=%s" % (ident, project, t["entrypoint"] or "unknown")
        if not t["any_usage"]:
            kinds[kind]["unmeasured"] += 1
            unmeasured.append("UNMEASURED\t%s\tno usage field on any request" % label.split("\tentrypoint=")[0])
            continue
        usages = [u for _, inw, u in t["requests"] if inw]
        if not usages:
            continue
        kinds[kind]["transcripts"] += 1
        kinds[kind]["usages"].extend(usages)
        tt = totals(usages)
        first_ts, first_u = t["first"]
        first_write = num(first_u.get("cache_creation_input_tokens"))
        if kind == "subagent" and first_ts is not None and since <= first_ts < until:
            starts.append(first_write)
        if kind == "main":
            by_entry.setdefault(t["entrypoint"] or "unknown", [0, []])
            by_entry[t["entrypoint"] or "unknown"][0] += 1
            by_entry[t["entrypoint"] or "unknown"][1].extend(usages)
        rows.append("SESSION\t%s\trequests=%d\tinput=%d\tcache_read=%d\tcache_write=%d\thit_rate=%s"
                    "\tfirst_write=%d\tfirst_read=%d\tlines_without_usage=%d"
                    % (label, tt["requests"], tt["input"], tt["read"], tt["write"],
                       rate(tt["read"], tt["all"]), first_write,
                       num(first_u.get("cache_read_input_tokens")), t["no_usage"]))

    if not kinds["main"]["usages"] and not kinds["subagent"]["usages"]:
        print("\n".join(out))
        print("NO REQUESTS IN WINDOW: no transcript under %s recorded a usage field between %s and %s"
              % (a.root, iso(since), iso(until)))
        return 1

    if not a.summary:
        out.extend(rows)
    out.extend(unmeasured)
    for kind in ("main", "subagent"):
        k = kinds[kind]
        tt = totals(k["usages"])
        out.append("SUMMARY\t%s\ttranscripts=%d\tunmeasured=%d\trequests=%d\tinput=%d\tcache_read=%d"
                   "\tcache_write=%d\twrite_5m=%d\twrite_1h=%d\thit_rate=%s"
                   % (kind, k["transcripts"], k["unmeasured"], tt["requests"], tt["input"], tt["read"],
                      tt["write"], tt["w5"], tt["w1"], rate(tt["read"], tt["all"])))
        if kind == "main":
            for entry in sorted(by_entry):
                n, us = by_entry[entry]
                et = totals(us)
                out.append("SUMMARY\tmain\tentrypoint=%s\ttranscripts=%d\trequests=%d\tinput=%d"
                           "\tcache_read=%d\tcache_write=%d\twrite_5m=%d\twrite_1h=%d\thit_rate=%s"
                           % (entry, n, et["requests"], et["input"], et["read"], et["write"],
                              et["w5"], et["w1"], rate(et["read"], et["all"])))
    if starts:
        med = statistics.median(starts)
        ratio = ("%.1fx" % (med / rule_tokens)) if rule_tokens > 0 else "n/a"
        out.append("STARTUP\tsubagent\tstarts=%d\tmedian_first_write=%d\ttotal_first_write=%d"
                   "\tmedian_vs_rules=%s" % (len(starts), med, sum(starts), ratio))
    else:
        out.append("STARTUP\tsubagent\tstarts=0\tno subagent made its first request in the window")
    out.append("MALFORMED\tlines=%d\tunreadable_files=%d\tuntimed_requests=%d"
               % (counters["malformed"], counters["unreadable"], counters["untimed"]))
    out.append("END")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
