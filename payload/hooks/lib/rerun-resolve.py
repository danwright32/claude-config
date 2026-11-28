#!/usr/bin/env python3
"""The hand rerun resolver's Python (claude-config#3613), run by lib/rerun-resolve.sh by path. One
program for both of its modes, so the date reading and the windows are written once:

  resolve <claim> <history> <out dir> <now> <unread days> <flake days>
      judges the waiting reruns into files in <out dir> (keep, resolved, findings, history, dropped)
  commit <history> <new lines> <now> <flake days>
      adds the new flake lines and removes those past the flake window, under the history's lock

<now> is seconds since the epoch and the day counts are whole numbers above zero, all read and checked
once by issue_spool_rerun_limits in issue-spool.sh.
"""
import datetime, errno, fcntl, json, os, signal, subprocess, sys, time

sys.stdout.reconfigure(errors="replace")
sys.stderr.reconfigure(errors="replace")

NO_TIME = "no time left this turn"


def epoch(ts):
    """Seconds since the epoch of the ts of a record, or None when it has none that can be read."""
    if not isinstance(ts, str) or not ts.strip():
        return None
    s = ts.strip()
    try:
        return int(datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp())
    except ValueError:
        pass
    try:
        d = datetime.datetime.fromisoformat(s[:-1] + "+00:00" if s.endswith("Z") else s)
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return int(d.timestamp())


def line_epoch(raw):
    try:
        h = json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        return None
    return epoch(h.get("ts")) if isinstance(h, dict) else None


def commit(path, new_path, now, days):
    """Add the new flake lines and remove every line older than the window, never losing a line
    another review adds meanwhile. Every writer of the history takes its lock, an flock on a file
    beside it that the kernel releases if the holder dies, and the trim reads, writes a temporary
    file beside it and renames it over the history all while holding it, so a line another review
    appends lands either before the read or after the rename. A line with no readable date, or that
    is not JSON, is kept."""
    cutoff = int(now) - int(days) * 86400
    wait = float(os.environ.get("CLAUDE_RERUN_LOCK_WAIT") or 3)
    try:
        with open(new_path, "rb") as fh:
            new = fh.read()
    except FileNotFoundError:
        new = b""
    if new and not new.endswith(b"\n"):
        new += b"\n"
    lost = (", so the flakes resolved this turn will not count toward a later one" if new else "")
    try:
        lock = open(path + ".lock", "ab")
    except OSError as e:
        print("issue-spool: the flake history at %s could not be locked (%s)%s." % (path, e, lost), file=sys.stderr)
        return 1
    deadline = time.monotonic() + wait
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError as e:
            if e.errno not in (errno.EAGAIN, errno.EACCES) or time.monotonic() >= deadline:
                print("issue-spool: the flake history at %s could not be locked: another review held it for "
                      "%.1f seconds%s, and nothing older was removed." % (path, wait, lost), file=sys.stderr)
                return 1
            time.sleep(0.05)
    rc = 0
    try:
        try:
            with open(path, "rb") as fh:
                lines = fh.read().splitlines(True)
        except FileNotFoundError:
            lines = []
        kept = [r if r.endswith(b"\n") else r + b"\n" for r in lines
                if not (line_epoch(r) is not None and line_epoch(r) < cutoff)]
        if len(kept) < len(lines):
            tmp = "%s.trim.%d" % (path, os.getpid())
            try:
                with open(tmp, "wb") as fh:
                    fh.write(b"".join(kept) + new)
                    fh.flush()
                    os.fsync(fh.fileno())
                os.replace(tmp, path)
                return 0
            except OSError as e:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                print("issue-spool: the flake history at %s could not be trimmed (%s); lines older than %s days "
                      "are kept until a later review can." % (path, e, days), file=sys.stderr)
                rc = 1
        if new:
            try:
                with open(path, "ab") as fh:
                    fh.write(new)
            except OSError as e:
                print("issue-spool: the flake history at %s could not be written (%s)%s." % (path, e, lost), file=sys.stderr)
                return 1
        return rc
    finally:
        lock.close()


MODE = sys.argv[1]
if MODE == "commit":
    sys.exit(commit(*sys.argv[2:6]))
claim, history_path, out = sys.argv[2:5]
NOW = int(sys.argv[5])
UNREAD_DAYS = int(sys.argv[6])
UNREAD_CUTOFF = NOW - UNREAD_DAYS * 86400
FLAKE_CUTOFF = NOW - int(sys.argv[7]) * 86400

BUDGET = float(os.environ.get("CLAUDE_RERUN_RESOLVE_BUDGET") or 5)
PER_CALL = float(os.environ.get("CLAUDE_RERUN_CALL_TIMEOUT") or 4)
GH = os.environ.get("CLAUDE_RERUN_GH") or "gh"
FAILED = {"failure", "timed_out"}
GREEN = {"success", "skipped", "neutral"}
start = time.monotonic()


def left():
    return BUDGET - (time.monotonic() - start)


def gh_values(args):
    """Every JSON value gh printed, or (None, why) when it could not be read in time."""
    t = min(PER_CALL, left())
    if t < 0.5:
        return None, NO_TIME
    try:
        p = subprocess.Popen([GH] + args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, start_new_session=True)
    except OSError as e:
        return None, "gh could not start: %s" % e
    try:
        so, se = p.communicate(timeout=t)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.communicate()
        return None, "gh gave no answer in %.0f seconds" % t
    if p.returncode != 0:
        return None, "gh exited %d: %s" % (p.returncode, se.decode("utf-8", "replace").strip()[:200])
    text, vals, i, dec = so.decode("utf-8", "replace"), [], 0, json.JSONDecoder()
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            break
        try:
            v, i = dec.raw_decode(text, i)
        except ValueError:
            return None, "gh printed something that is not JSON"
        vals.append(v)
    return vals, None


def host_args(repo):
    parts = repo.split("/")
    return (["--hostname", parts[0]], "/".join(parts[1:])) if len(parts) == 3 else ([], repo)


recs, bad = [], 0
for line in open(claim, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        r = json.loads(line)
    except ValueError:
        bad += 1
        continue
    if isinstance(r, dict) and r.get("repo") and (r.get("run") or r.get("job")):
        recs.append(r)
    else:
        bad += 1
if bad:
    print("issue-spool: %d line(s) in the waiting reruns were not rerun records and were dropped." % bad,
          file=sys.stderr)

history = []
try:
    for line in open(history_path, encoding="utf-8", errors="replace"):
        try:
            h = json.loads(line)
        except ValueError:
            continue
        # Older than the flake window it no longer counts (the commit below also removes it); a line
        # with no readable date is kept and counts, as every line did before the window existed.
        if isinstance(h, dict):
            t = epoch(h.get("ts"))
            if t is None or t >= FLAKE_CUTOFF:
                history.append(h)
except FileNotFoundError:
    pass
seen = {(h.get("repo"), str(h.get("run")), h.get("workflow"), h.get("job")) for h in history}

# One group per run (or per job, while its run is unknown), newest first.
groups = {}
for r in recs:
    k = (r["repo"], ("run", str(r["run"])) if r.get("run") else ("job", str(r["job"])))
    groups.setdefault(k, []).append(r)
order = sorted(groups, key=lambda k: max(x.get("ts") or "" for x in groups[k]), reverse=True)

keep, resolved, findings, new_hist, dropped, said = [], [], [], [], [], []
now = datetime.datetime.fromtimestamp(NOW, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def put_back(rs, why):
    """Back to wait, or, tried this turn and unreadable since it was FIRST recorded the keep days
    ago or more, dropped with one line. A run with no readable date is never aged, and is said."""
    r0 = rs[0]
    name = "%s run %s" % (r0["repo"], r0["run"]) if r0.get("run") else "%s job %s" % (r0["repo"], r0.get("job"))
    if why != NO_TIME:
        times = [t for t in (epoch(r.get("ts")) for r in rs) if t is not None]
        if not times:
            print("issue-spool: the waiting hand rerun of %s has no readable date, so it cannot be aged "
                  "and is kept (%s)." % (name, why), file=sys.stderr)
        elif min(times) <= UNREAD_CUTOFF:
            first = datetime.datetime.fromtimestamp(min(times), datetime.timezone.utc).strftime("%Y-%m-%d")
            said.append("Hand rerun of %s dropped unread after %d days: its result could not be read since "
                        "it was recorded on %s (last: %s)." % (name, UNREAD_DAYS, first, " ".join(why.split())))
            dropped.extend(rs)
            return
    for r in rs:
        r["tries"] = r.get("tries", 0) + 1
        r["last_unread"] = why
        keep.append(r)


def finding(first, text):
    rec = {"ts": now, "status": "found", "agent": "rerun record", "cwd": first.get("cwd") or "",
           "findings": [text], "rerun": {"repo": first["repo"], "run": first.get("run")}}
    if first.get("session"):
        rec["session"] = first["session"]
    findings.append(rec)


def ordinal(n):
    return "%d%s" % (n, "th" if 10 <= n % 100 <= 20 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th"))


for k in order:
    rs = groups[k]
    repo, (kind, ident) = k
    hargs, path_repo = host_args(repo)
    if kind == "job":
        vals, why = gh_values(["api"] + hargs + ["repos/%s/actions/jobs/%s" % (path_repo, ident)])
        run = vals[0].get("run_id") if vals and isinstance(vals[0], dict) else None
        if not run:
            put_back(rs, why or "the run of the job could not be read")
            continue
        for r in rs:
            r["run"] = str(run)
        ident = str(run)
    vals, why = gh_values(["api"] + hargs + ["--paginate",
                          "repos/%s/actions/runs/%s/jobs?filter=all&per_page=100" % (path_repo, ident),
                          "--jq", ".jobs[]"])
    jobs = [j for j in (vals or []) if isinstance(j, dict) and j.get("name") is not None]
    if not jobs:
        put_back(rs, why or "the run listed no jobs")
        continue
    attempts = [int(j.get("run_attempt") or 1) for j in jobs]
    if max(attempts) < 2:
        put_back(rs, "the attempt of the rerun has not appeared yet")
        continue
    by_job = {}
    for j in jobs:
        by_job.setdefault((j.get("workflow_name") or "", j["name"]), []).append(j)
    finals = {}
    for jk, entries in by_job.items():
        entries.sort(key=lambda j: int(j.get("run_attempt") or 1))
        finals[jk] = entries
    if any(e[-1].get("status") != "completed" for e in finals.values()):
        put_back(rs, "the run is still in progress")
        continue
    green = all(e[-1].get("conclusion") in GREEN for e in finals.values())
    first = rs[0]
    for (wf, name), entries in sorted(finals.items()):
        last = entries[-1]
        earlier_failed = any(e.get("conclusion") in FAILED and int(e.get("run_attempt") or 1) < int(last.get("run_attempt") or 1)
                             for e in entries[:-1])
        if not earlier_failed:
            continue
        label = "\x27%s\x27%s in %s" % (name, (" (workflow \x27%s\x27)" % wf) if wf else "", repo)
        if last.get("conclusion") in FAILED:
            finding(first, "Job %s failed again on its hand rerun (run %s, attempt %s). Rerunning it a third time "
                    "will not help: look for the cause, or file an issue for it." % (label, ident, last.get("run_attempt")))
        elif green and last.get("conclusion") == "success":
            ev = (repo, ident, wf, name)
            if ev in seen:
                continue
            seen.add(ev)
            new_hist.append({"ts": now, "repo": repo, "run": ident, "workflow": wf, "job": name,
                             "sha": last.get("head_sha")})
            runs = sorted({str(h.get("run")) for h in history + new_hist
                           if h.get("repo") == repo and h.get("workflow") == wf and h.get("job") == name})
            if len(runs) >= 2:
                finding(first, "Job %s failed and then passed on a hand rerun for the %s time (runs %s). A repeat "
                        "flake: add this run to that job\x27s flake issue, or open one." % (label, ordinal(len(runs)), ", ".join(runs)))
    resolved.extend(rs)


def dump(name, rows):
    with open(os.path.join(out, name), "w", encoding="utf-8", errors="replace") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")


dump("keep.jsonl", keep)
dump("resolved.jsonl", resolved)
dump("findings.jsonl", findings)
dump("history.jsonl", new_hist)
dump("dropped.jsonl", dropped)
with open(os.path.join(out, "dropped.txt"), "w", encoding="utf-8", errors="replace") as fh:
    for s in said:
        fh.write(s + "\n")
