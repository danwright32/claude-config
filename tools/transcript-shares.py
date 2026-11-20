#!/usr/bin/env python3
"""What the tokens of a window's requests were spent carrying, from the transcripts (claude-config#1940).

    python3 tools/transcript-shares.py --since 2026-11-02 --until 2026-11-16 [--tz America/New_York]
        [--project NAME ...] [--root ~/.claude/projects] [--compactions 3,5] [--top 5] [--jobs 1]

Measures the three costs #1940 tracks: subagents reading code, agent reports carried in the main
session, and very long sessions. `--project` matches part of a project folder's name (the folder
Claude Code names after the repository's path, so worktree folders of the same repository match
too); with none, every project is read. `--since` and `--until` are dates or times in `--tz`.

The method, the one the baseline on #1940 (16 to 30 October 2026) and its re-measure (2 to 16
November 2026) both used, so figures from this tool are comparable with them:

- Tokens read are each request's usage (input + cache read + cache write, the sum
  hooks/lib/context_size.py defines), counted once per message id; `<synthetic>` lines are not
  requests. A request is placed in the window by its own timestamp, never its file's date.
- What a request carried is estimated from the size of each transcript item before it, at 2.78
  characters a token, so an item costs its size times the number of later requests in the same
  context. A compaction starts a new context. `estimated_over_measured` on each KIND line says how
  close the estimate comes to the measured total (0.95 and 1.02 on the re-measure).
- Code reading is the output of Read, Grep, and Bash commands that start (after any `cd ... &&`,
  `NAME=value` or `rtk` prefix) with sed, cat, grep, rg or git show.
- Agent reports are `<task-notification>` blocks (each read once however often it arrives), the
  `<agent-message>` an agent sends back, and the Agent tool's own result (the launch receipt).
- A transcript is a subagent when it lives under `subagents/` or says `isSidechain: true`; otherwise
  it is interactive (`entrypoint` cli), headless (sdk-cli) or other.

Reads item sizes and kinds only and prints no transcript text (L222). A window holding no
transcripts or no requests exits 1 rather than report an empty measurement (L98). Faults are
counted and named, and END then says `complete=no`:

- MALFORMED, per file: lines that are not JSON, are nested too deep to parse, or carry an id that is
  not a string. The line is skipped and the rest of the file is read.
- UNREADABLE: a file that cannot be opened, a folder that cannot be listed, and a file whose read
  fails part way. For the last, NOTHING from that file is counted (a partial transcript would carry
  a wrong context into every share), and the line says after which line it failed.

Output is tab separated: WINDOW, INPUT, UNREADABLE, MALFORMED, TOTAL, then KIND,
SHARE, READS and WORDS per kind, SESSION for the largest main sessions, COMPACTIONS, END.
"""
import argparse
import collections
import datetime
import hashlib
import json
import os
import re
import statistics
import sys

try:
    import zoneinfo
except ImportError:  # Python before 3.9, or a build without it: refused in main, by name
    zoneinfo = None

# The one sum of a request's context, shared with the context size hook and tools/cache-usage.py.
sys.dont_write_bytecode = True   # no cache left in the hooks lib (#2600)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "payload", "hooks", "lib"))
import context_size  # noqa: E402

CPT = 2.78                       # characters a token, the baseline's figure
IMAGE_CHARS = int(1500 * CPT)    # an image counted as about 1,500 tokens (an estimate)
LONG_READ_LINES = 150            # the narrow read cap agent briefs ask for
WORD_CAP = 300                   # the report length cap agent briefs ask for

# Lines of these types hold request shapes and queue bookkeeping, never a request, and can be large,
# so they are recognised from their first characters and not parsed.
SKIP_HEAD = re.compile(r'"type"\s*:\s*"(?:api-request[^"]*|queue-operation)"')
LEAD = re.compile(r"^\s*(?:(?:cd\s+(?:\"[^\"]*\"|'[^']*'|\S+)\s*(?:&&|;)\s*)|(?:[A-Z_][A-Z0-9_]*=\S*\s+)|(?:rtk\s+))+")
CODE = re.compile(r"^(?:sed|cat|grep|rg)\b|^git(?:\s+-C\s+(?:\"[^\"]*\"|'[^']*'|\S+))?\s+show\b")
RESULT = re.compile(r"<result>(.*?)</result>", re.S)


def parse_ts(text):
    if not isinstance(text, str):
        return None
    try:
        dt = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo is not None else dt.replace(tzinfo=datetime.timezone.utc)


def bash_is_code_read(cmd):
    if not isinstance(cmd, str):
        return False
    return bool(CODE.match(LEAD.sub("", cmd, count=1).lstrip()))


def text_of(content):
    """(chars, text, images) of a tool result or message content."""
    if isinstance(content, str):
        return len(content), content, 0
    chars, parts, images = 0, [], 0
    if isinstance(content, list):
        for b in content:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text" and isinstance(b.get("text"), str):
                chars += len(b["text"])
                parts.append(b["text"])
            elif b.get("type") == "image":
                images += 1
    return chars, "\n".join(parts), images


def notice_kind(s):
    if s.startswith("<task-notification>"):
        return "agent_report_bg", "reports_bg"
    if s.startswith("<agent-message"):
        return "agent_message", "reports_am"
    return None, None


def notice_words(s, rk):
    if rk == "reports_bg":
        m = RESULT.search(s)
        return len((m.group(1) if m else s).split())
    body = s.split(">", 1)[1] if ">" in s else s
    return len(body.rsplit("</agent-message>", 1)[0].split())


def new_agg():
    return {"measured": 0, "requests": 0, "carried": collections.Counter(), "first": [],
            "code_reads": [], "reports_bg": [], "reports_fg": [], "reports_am": []}


def has_bad_id(o):
    """True when a message id, tool use id or tool result's tool_use_id is present but not a string."""
    msg = o.get("message")
    if not isinstance(msg, dict):
        return False
    if msg.get("id") is not None and not isinstance(msg["id"], str):
        return True
    cont = msg.get("content")
    for b in cont if isinstance(cont, list) else ():
        if isinstance(b, dict):
            for key in ("id", "tool_use_id"):
                if b.get(key) is not None and not isinstance(b[key], str):
                    return True
    return False


def counted(fh, out):
    """The file's lines, recording each one as done only once the loop comes back for the next."""
    for n, line in enumerate(fh, 1):
        yield line
        out["lines_done"] = n


def new_result(path):
    return {"path": path, "kind": None, "agg": None, "session": None, "err": None, "malformed": 0,
            "untimed": 0, "lines_done": 0}


def process(job):
    """One transcript, with a failure boundary: a read that fails part way, or anything else raised
    while reading it, names the file UNREADABLE and counts NOTHING from it, so one bad file never
    stops the run (in a worker it would otherwise end it with a traceback)."""
    path = job[0]
    out = new_result(path)
    try:
        return read_transcript(job, out)
    except Exception as e:
        failed = new_result(path)
        detail = str(e) if isinstance(e, OSError) else "%s: %s" % (type(e).__name__, e)
        failed["err"] = "read failed after line %d, nothing from this file counted: %s" % (out["lines_done"], detail)
        return failed


def read_transcript(job, out):
    """One transcript: its kind, its totals for requests in the window, and what went wrong reading it."""
    path, since, until = job
    kind ="subagent" if "%ssubagents%s" % (os.sep, os.sep) in path else None
    entry = None
    ctx = collections.Counter()
    tools = {}
    seen = set()
    notif_seen = set()
    first_done = False
    compactions = 0
    first_ts = last_ts = None
    agg = None

    def get_agg():
        nonlocal agg
        if agg is None:
            agg = new_agg()
        return agg

    def notice(s, size, rk, nk, inw):
        h = hashlib.sha1(s.encode("utf-8", "replace")).hexdigest()
        if h in notif_seen:
            return
        notif_seen.add(h)
        ctx[nk] += size
        if inw:
            get_agg()[rk].append(notice_words(s, rk))

    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError as e:
        out["err"] = e.strerror or str(e)
        return out
    with fh:
        for line in counted(fh, out):
            if not line.strip() or SKIP_HEAD.search(line[:120]):
                continue
            try:
                o = json.loads(line)
            except (ValueError, RecursionError):
                out["malformed"] += 1
                continue
            if not isinstance(o, dict) or has_bad_id(o):
                out["malformed"] += 1
                continue
            t = o.get("type")
            if o.get("isSidechain") is True:
                kind = "subagent"
            if entry is None and isinstance(o.get("entrypoint"), str):
                entry = o["entrypoint"]
            d = parse_ts(o.get("timestamp"))
            inw = d is not None and since <= d < until
            if t == "system" and o.get("subtype") == "compact_boundary":
                ctx = collections.Counter()
                if inw:
                    compactions += 1
                continue
            msg = o.get("message") if isinstance(o.get("message"), dict) else {}
            if t == "assistant":
                mid = msg.get("id")
                u = msg.get("usage")
                if mid and mid not in seen and msg.get("model") != "<synthetic>" and isinstance(u, dict):
                    seen.add(mid)
                    tok = context_size.context_of(u)
                    if d is None:
                        out["untimed"] += 1
                    if inw:
                        a = get_agg()
                        a["measured"] += tok
                        a["requests"] += 1
                        a["carried"].update(ctx)
                        first_ts = first_ts or d
                        last_ts = d
                    if not first_done:
                        first_done = True
                        if inw:
                            get_agg()["first"].append(tok)
                cont = msg.get("content")
                if isinstance(cont, list):
                    for b in cont:
                        if not isinstance(b, dict):
                            continue
                        bt = b.get("type")
                        if bt == "text":
                            ctx["assistant_text"] += len(b.get("text") or "")
                        elif bt == "thinking":
                            ctx["thinking"] += len(b.get("thinking") or "")
                        elif bt == "tool_use":
                            name = b.get("name")
                            inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                            ctx["tool_call"] += len(json.dumps(inp))
                            if name in ("Read", "Grep") or (name == "Bash" and bash_is_code_read(inp.get("command"))):
                                cat = "code_read"
                            elif name in ("Agent", "Task"):
                                cat = "agent_report_fg"
                            else:
                                cat = "tool_output_other"
                            tools[b.get("id")] = cat
                continue
            if t == "user":
                cont = msg.get("content")
                if isinstance(cont, str):
                    s = cont.lstrip()
                    nk, rk = notice_kind(s)
                    if nk:
                        notice(s, len(cont), rk, nk, inw)
                    elif o.get("isCompactSummary"):
                        ctx["compact_summary"] += len(cont)
                    else:
                        ctx["user_text"] += len(cont)
                elif isinstance(cont, list):
                    for b in cont:
                        if not isinstance(b, dict):
                            continue
                        bt = b.get("type")
                        if bt == "tool_result":
                            chars, text, imgs = text_of(b.get("content"))
                            cat = tools.get(b.get("tool_use_id"), "tool_output_other")
                            ctx[cat] += chars
                            ctx["image"] += imgs * IMAGE_CHARS
                            if inw and cat == "code_read":
                                get_agg()["code_reads"].append((text.count("\n") + 1 if text else 0, chars))
                            if inw and cat == "agent_report_fg":
                                get_agg()["reports_fg"].append(len(text.split()))
                        elif bt == "text":
                            s = b.get("text") or ""
                            nk, rk = notice_kind(s.lstrip())
                            if nk:
                                notice(s.lstrip(), len(s), rk, nk, inw)
                            else:
                                ctx["user_text"] += len(s)
                        elif bt == "image":
                            ctx["image"] += IMAGE_CHARS
                continue
            if t == "attachment":
                a = o.get("attachment") if isinstance(o.get("attachment"), dict) else {}
                at = a.get("type")
                p = a.get("prompt")
                nk, rk = notice_kind(p.lstrip()) if (at == "queued_command" and isinstance(p, str)) else (None, None)
                if nk:
                    notice(p.lstrip(), len(p), rk, nk, inw)
                else:
                    ctx["att:%s" % at] += len(json.dumps(a))
    if kind is None:
        kind = {"cli": "interactive", "sdk-cli": "headless"}.get(entry, "other:%s" % entry)
    out["kind"] = kind
    if agg is not None:
        agg["carried"] = dict(agg["carried"])
        out["agg"] = agg
        if agg["requests"]:
            out["session"] = {"tokens": agg["measured"], "requests": agg["requests"], "compactions": compactions,
                              "first": first_ts, "last": last_ts}
    return out


def find_files(root, projects, since):
    """(matched project count, [(path, problem or None)], files older than the window,
    [(folder, problem)] for folders that could not be listed, whose transcripts are unknown)."""
    names = sorted(n for n in os.listdir(root) if os.path.isdir(os.path.join(root, n))
                   and (not projects or any(p in n for p in projects)))
    found, old, unlisted = [], 0, []
    floor = since.timestamp()

    def cannot_list(e):
        unlisted.append((e.filename, "folder cannot be listed: %s" % (e.strerror or str(e))))

    for n in names:
        for dp, _dn, fn in os.walk(os.path.join(root, n), onerror=cannot_list):
            for f in sorted(fn):
                if not f.endswith(".jsonl"):
                    continue
                p = os.path.join(dp, f)
                try:
                    mtime = os.stat(p).st_mtime
                except OSError as e:
                    found.append((p, e.strerror or str(e)))
                    continue
                # A file last written before the window began cannot hold a request inside it.
                if mtime < floor:
                    old += 1
                    continue
                found.append((p, None))
    return len(names), found, old, unlisted


def pct(a, b):
    return "n/a" if not b else "%.1f%%" % (100.0 * a / b)


def num(x):
    if x is None:
        return "n/a"
    return "%d" % x if float(x).is_integer() else "%.1f" % x


def med(x):
    return statistics.median(x) if x else None


def local_time(d, zone):
    return d.astimezone(zone).strftime("%Y-%m-%d %H:%M %Z")


def parse_bound(text, zone):
    try:
        dt = datetime.datetime.fromisoformat(text)
    except ValueError:
        return None
    return dt.replace(tzinfo=zone) if dt.tzinfo is None else dt


def main(argv):
    ap = argparse.ArgumentParser(description="Shares of transcript tokens (claude-config#1940).")
    ap.add_argument("--root", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--project", action="append", default=[],
                    help="part of a project folder name; repeat for several; none reads every project")
    ap.add_argument("--since", required=True, help="start of the window, a date or time in --tz")
    ap.add_argument("--until", required=True, help="end of the window (excluded), a date or time in --tz")
    ap.add_argument("--tz", default="America/New_York")
    ap.add_argument("--compactions", default="3,5", help="compaction counts to report sessions at or past")
    ap.add_argument("--top", type=int, default=5, help="how many of the largest main sessions to list")
    ap.add_argument("--jobs", type=int, default=1, help="worker processes")
    a = ap.parse_args(argv)

    if zoneinfo is None:
        print("NO ZONEINFO: this Python has no zoneinfo module (it needs 3.9 or later), so --tz %s "
              "cannot be read" % a.tz)
        return 2
    try:
        zone = zoneinfo.ZoneInfo(a.tz)
    except (zoneinfo.ZoneInfoNotFoundError, ValueError):
        print("BAD --tz: %s" % a.tz)
        return 2
    since, until = parse_bound(a.since, zone), parse_bound(a.until, zone)
    if since is None or until is None or until <= since:
        print("BAD WINDOW: --since %s --until %s" % (a.since, a.until))
        return 2
    try:
        thresholds = sorted({int(x) for x in a.compactions.split(",") if x.strip()})
    except ValueError:
        print("BAD --compactions: %s" % a.compactions)
        return 2

    out = ["WINDOW\tsince=%s\tuntil=%s\ttz=%s" % (since.isoformat(), until.isoformat(), a.tz)]
    if not os.path.isdir(a.root):
        print("\n".join(out + ["NO TRANSCRIPTS ROOT: %s" % a.root]))
        return 1
    try:
        nproj, found, old, unlisted = find_files(a.root, a.project, since)
    except OSError as e:
        print("\n".join(out + ["NO TRANSCRIPTS ROOT: %s cannot be listed: %s" % (a.root, e.strerror or e)]))
        return 1
    jobs = [(p, since, until) for p, err in found if err is None]
    if a.jobs > 1 and len(jobs) > 1:
        from multiprocessing import Pool
        with Pool(a.jobs) as pool:
            results = list(pool.imap_unordered(process, jobs, chunksize=4))
    else:
        results = [process(j) for j in jobs]
    results.sort(key=lambda r: r["path"])

    unreadable = [(p, err) for p, err in found if err is not None] + unlisted
    unreadable += [(r["path"], r["err"]) for r in results if r["err"]]
    read = [r for r in results if not r["err"]]
    active = [r for r in read if r["agg"] and r["agg"]["requests"]]
    malformed = [(r["path"], r["malformed"]) for r in read if r["malformed"]]
    requests = sum(r["agg"]["requests"] for r in active)
    out.append("INPUT\tprojects=%d\tfiles_found=%d\tfiles_older_than_window=%d\tfiles_read=%d"
               "\tfiles_with_requests_in_window=%d\trequests_in_window=%d\tunreadable=%d\tmalformed_lines=%d"
               "\tuntimed_requests=%d" % (nproj, len(found) + old, old, len(read), len(active), requests,
                                         len(unreadable), sum(n for _, n in malformed),
                                         sum(r["untimed"] for r in read)))
    out += ["UNREADABLE\t%s\t%s" % (p, err) for p, err in sorted(unreadable)]
    out += ["MALFORMED\t%s\tlines=%d" % (p, n) for p, n in malformed]
    if not found and not old:
        out.append("NO TRANSCRIPTS: no .jsonl file in %d matching project folder(s) under %s" % (nproj, a.root))
        print("\n".join(out))
        return 1
    if not requests:
        out.append("NO REQUESTS IN WINDOW")
        print("\n".join(out))
        return 1

    groups = collections.defaultdict(lambda: {"files": 0, "agg": new_agg()})
    for r in read:
        if not r["agg"]:
            continue
        g = groups[r["kind"]]
        g["files"] += 1
        for k, v in r["agg"].items():
            if k == "carried":
                g["agg"]["carried"].update(v)
            else:
                g["agg"][k] += v   # a list extends, a count adds
    total = sum(g["agg"]["measured"] for g in groups.values())
    out.append("TOTAL\ttokens=%d" % total)
    for kind, g in sorted(groups.items(), key=lambda x: (-x[1]["agg"]["measured"], x[0])):
        s = g["agg"]
        m, c = s["measured"], s["carried"]
        est = sum(c.values()) / CPT
        rep = c.get("agent_report_bg", 0) + c.get("agent_message", 0) + c.get("agent_report_fg", 0)
        out.append("KIND\t%s\tfiles=%d\trequests=%d\ttokens=%d\tshare_of_all=%s\testimated_over_measured=%s"
                   "\tfirst_request_median=%s" % (kind, g["files"], s["requests"], m, pct(m, total),
                                                  "%.2f" % (est / m) if m else "n/a", num(med(s["first"]))))
        out.append("SHARE\t%s\tcode_reading=%s\tagent_reports=%s\ttask_notifications=%s\tagent_messages=%s"
                   "\tagent_launches=%s" % (kind, pct(c.get("code_read", 0) / CPT, m), pct(rep / CPT, m),
                                            pct(c.get("agent_report_bg", 0) / CPT, m),
                                            pct(c.get("agent_message", 0) / CPT, m),
                                            pct(c.get("agent_report_fg", 0) / CPT, m)))
        cr = s["code_reads"]
        big = [x for x in cr if x[0] > LONG_READ_LINES]
        out.append("READS\t%s\tcode_reads=%d\tover_%d_lines=%s\ttheir_share_of_code_read_chars=%s\tmedian_lines=%s"
                   % (kind, len(cr), LONG_READ_LINES, pct(len(big), len(cr)),
                      pct(sum(x[1] for x in big), sum(x[1] for x in cr)), num(med([x[0] for x in cr]))))
        for key, label in (("reports_bg", "task_notifications"), ("reports_am", "agent_messages"),
                           ("reports_fg", "agent_launches")):
            x = s[key]
            if x:
                out.append("WORDS\t%s\t%s\tcount=%d\tmedian=%s\tover_%d=%s\tp90=%d"
                           % (kind, label, len(x), num(med(x)), WORD_CAP, pct(sum(1 for v in x if v > WORD_CAP), len(x)),
                              sorted(x)[int(len(x) * 0.9)]))

    sessions = sorted(((r["session"], r["kind"]) for r in active if r["kind"] != "subagent"),
                      key=lambda x: -x[0]["tokens"])
    for s, kind in sessions[:a.top]:
        out.append("SESSION\t%s\ttokens=%d\tshare_of_all=%s\tcompactions=%d\trequests=%d\tfirst=%s\tlast=%s"
                   % (kind, s["tokens"], pct(s["tokens"], total), s["compactions"], s["requests"],
                      local_time(s["first"], zone), local_time(s["last"], zone)))
    for n in thresholds:
        hit = [s for s, _ in sessions if s["compactions"] >= n]
        out.append("COMPACTIONS\tat_least=%d\tsessions=%d\tshare_of_all=%s"
                   % (n, len(hit), pct(sum(s["tokens"] for s in hit), total)))
    out.append("END\tcomplete=%s" % ("no" if unreadable or malformed else "yes"))
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
