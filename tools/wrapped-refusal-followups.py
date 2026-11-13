#!/usr/bin/env python3
"""How often the wrapped command gate refused, against every Bash call, and what came next
(claude-config#1492).

    python3 tools/wrapped-refusal-followups.py [--since 2026-10-23] [--until 2026-11-04]
        [--root ~/.claude/projects] [--ledger PATH] [--hook PATH]

payload/hooks/lib/wrapped-refusal-report.py reads the gate's own record, which says how many
refusals there were and of what shape, but not how many Bash calls they were out of, nor whether a
refusal taught anything. This reads the transcripts on this Mac for both, for a period of whole days
in US Eastern time (the last day not included):

- every Bash call in the period, each counted once however many transcript files repeat it (a
  resumed session copies its history into a new file with the same tool ids);
- every refusal the gate made, by the refusal Claude Code wrote back as that call's result, its
  PreToolUse prefix and the gate's issue number both present, so a read of the gate's source that
  quotes the sentence is no refusal;
- the shape of each refused command as TODAY's gate reads it (L107): the command is handed to
  check-wrapped-commands.sh itself, with its record pointed at a throwaway directory, and the shape
  is the row it writes, or that it now passes; for a script-file refusal, the script the gate's own
  sentence names, given by name only when it is one of the shared config's installed files (this
  public repository's), and otherwise only as a script outside the shared config;
- what came next, per episode: a run of refusals, ended by the first later call that ran git, gh or
  rtk without being refused (taught, or retried and failed for its own reason), an override, five
  Bash calls without one (dropped), or the transcript's end (ended). "Names git, gh or rtk" is the
  gate's own test of a command.

A transcript it cannot read, or one listed and gone before it could be read, is counted beside the
totals, each cause on its own line, so a short total says why it is short (claude-config#2239). A
call is only ever read from an assistant line and its result from a user line: any other line that
holds one (api-request-blob) echoes it with no time of its own (claude-config#2239).

It prints counts and shapes only. A command is read in memory and handed to the gate on its input,
and never printed, written or copied: transcripts hold other projects' commands, paths and names.
The gate's record is read through the report's own reader, so the two count the same rows.
"""
import argparse
import datetime
import glob
import importlib.util
import json
import os
import re
import socket
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_HOOK = os.path.join(REPO, "payload", "hooks", "check-wrapped-commands.sh")
REPORT = os.path.join(REPO, "payload", "hooks", "lib", "wrapped-refusal-report.py")
WINDOW = 5
# check-wrapped-commands.sh's own test that a command names git, gh or rtk.
GUARDED = re.compile(r"(^|[^A-Za-z0-9_.-])(git|gh|rtk)([^A-Za-z0-9_.-]|$)")
OVERRIDE = "SKIP_WRAPPED_CHECK=1"
# A PreToolUse refusal as Claude Code writes it back as the call's result, from this gate.
REFUSAL = re.compile(r"(?:^|\n)PreToolUse:Bash hook error: \[[^\]\n]*\]: BLOCKED: this command ")
GATE_ISSUE = "(claude-config#1478)"
OUTCOMES = (
    ("taught", "taught, the git, gh or rtk part ran on its own and succeeded"),
    ("failed", "retried on its own, but that call failed"),
    ("overridden", "overridden with SKIP_WRAPPED_CHECK=1"),
    ("dropped", "dropped, no later call ran git, gh or rtk within %d Bash calls" % WINDOW),
    ("ended", "ended, the refusal was the transcript's last Bash call"),
)
PASSES = "passes today's gate"
# The script a script-file refusal names, in the gate's sentence (lib/shell-words.py WHY_FILE).
SCRIPT_NAMED = re.compile(r"it runs the script file (.+?), whose commands are in the file")
# Where the shared config's own scripts are installed: their names are this public repository's.
SHARED_SCRIPT_DIRS = ("~/.claude/hooks/", "~/.claude/skills/", "~/.claude/commands/",
                      "~/.claude/agents/", "~/.claude/mods/", "~/claude-config-sync/")


def load_report():
    sys.dont_write_bytecode = True   # no cache left in the hooks lib (#2600)
    spec = importlib.util.spec_from_file_location("wrapped_refusal_report", REPORT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def eastern():
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo("America/New_York")
    except Exception:
        return None


def day_start(text, tz):
    d = datetime.datetime.strptime(text, "%Y-%m-%d")
    return d.replace(tzinfo=tz).timestamp() if tz else d.timestamp()


def parse_ts(text):
    if not isinstance(text, str):
        return None
    try:
        return datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def result_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and isinstance(b.get("text"), str))
    return ""


def read_transcripts(root, since):
    """Every transcript's Bash calls in order, as ids, plus each call's time and command and each
    result's (is_error, refused by this gate), keyed by tool id; the count of lines that looked
    like a call or a result and could not be read; and the counts of transcripts left out, as
    {"read", "unreadable", "gone"} (claude-config#2239). A transcript that cannot be opened, or
    fails partway through, is unreadable and contributes nothing, so no total holds half a file; one
    listed and then gone before it could be read (deleted, or rotated away) is gone. Neither is
    skipped silently: every total is short by whatever they held, and the report says so."""
    paths = glob.glob(os.path.join(root, "*", "*.jsonl"))
    paths += glob.glob(os.path.join(root, "*", "*", "subagents", "*.jsonl"))
    sequences, calls, results, bad = {}, {}, {}, 0
    files = {"read": 0, "unreadable": 0, "gone": 0}
    for p in sorted(paths):
        try:
            if os.path.getmtime(p) < since:
                continue
        except FileNotFoundError:
            files["gone"] += 1
            continue
        except OSError:
            files["unreadable"] += 1
            continue
        seq, fcalls, fresults, fbad = [], {}, {}, 0
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                for line in f:
                    if '"tool_use"' not in line and '"tool_result"' not in line:
                        continue
                    try:
                        d = json.loads(line)
                    except ValueError:
                        fbad += 1
                        continue
                    msg = d.get("message") if isinstance(d, dict) else None
                    content = msg.get("content") if isinstance(msg, dict) else None
                    if not isinstance(content, list):
                        continue
                    # A call is made in an assistant line and answered in a user line. Any other line
                    # holding one only echoes it: Claude Code's api-request-blob lines repeat earlier
                    # messages under the same ids, with no timestamp, and an echo read first gave a
                    # refused call no time, so it fell outside every period (claude-config#2239).
                    kind = d.get("type")
                    for b in content:
                        if not isinstance(b, dict):
                            continue
                        if kind == "assistant" and b.get("type") == "tool_use" and b.get("name") == "Bash":
                            cid = b.get("id")
                            cmd = (b.get("input") or {}).get("command")
                            if not isinstance(cid, str) or not isinstance(cmd, str):
                                continue
                            seq.append(cid)
                            fcalls.setdefault(cid, (parse_ts(d.get("timestamp")), cmd))
                        elif kind == "user" and b.get("type") == "tool_result" and isinstance(b.get("tool_use_id"), str):
                            text = result_text(b.get("content"))
                            refused = bool(REFUSAL.search(text)) and GATE_ISSUE in text
                            fresults.setdefault(b["tool_use_id"], (b.get("is_error") is True, refused))
        except FileNotFoundError:
            files["gone"] += 1
            continue
        except OSError:
            files["unreadable"] += 1
            continue
        files["read"] += 1
        bad += fbad
        for cid, v in fcalls.items():
            calls.setdefault(cid, v)
        for cid, v in fresults.items():
            results.setdefault(cid, v)
        if seq:
            sequences[p] = seq
    return sequences, calls, results, bad, files


def script_kind(stderr):
    """Which script a script-file refusal names, from the gate's own sentence (lib/shell-words.py
    WHY_FILE), named only when it is one of the shared config's own files, which are public:
    anything else is somebody's content and is said only as outside the shared config."""
    m = SCRIPT_NAMED.search(stderr or "")
    if not m:
        return None
    path = m.group(1)
    home = os.path.expanduser("~")
    if path.startswith(home + "/"):
        path = "~" + path[len(home):]
    for prefix in SHARED_SCRIPT_DIRS:
        if path.startswith(prefix) and re.fullmatch(r"~/[A-Za-z0-9_./-]+", path) and ".." not in path:
            return path
    return "a script outside the shared config"


def todays_shape(hook, cmd):
    """The shape today's gate gives the command: (wrapper, reason) from the row it records, PASSES
    when it lets the command through, or a sentence saying it could not be judged; and, for a
    script-file refusal, which script (script_kind)."""
    shape, stderr = _todays_shape(hook, cmd)
    return shape, (script_kind(stderr) if shape.endswith(", script-file") else None)


def _todays_shape(hook, cmd):
    with tempfile.TemporaryDirectory() as d:
        env = dict(os.environ, WRAPPED_REFUSAL_LEDGER_DIR=d)
        payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": d})
        try:
            r = subprocess.run(["bash", hook], input=payload, env=env, cwd=d, capture_output=True,
                               text=True, timeout=60)
        except (OSError, subprocess.SubprocessError):
            return "today's gate could not be run", ""
        if r.returncode == 0:
            return PASSES, ""
        try:
            with open(os.path.join(d, "refusals.tsv"), encoding="utf-8") as f:
                last = [line.rstrip("\n").split("\t") for line in f if line.strip()][-1]
            return "%s, %s" % (last[2], last[3]), r.stderr
        except (OSError, IndexError):
            return "refused today, with no row recorded (exit %d)" % r.returncode, ""


def episodes(sequences, calls, results, since, until):
    """Each episode as (its refusals, its last refusal's id, its outcome)."""
    def refused(cid):
        return results.get(cid, (False, False))[1]

    def in_period(cid):
        ts = calls[cid][0]
        return ts is not None and since <= ts < until

    where = {}
    for p, seq in sequences.items():
        for i, cid in enumerate(seq):
            if refused(cid) and in_period(cid):
                tail = len(seq) - i
                if cid not in where or tail > where[cid][2]:
                    where[cid] = (p, i, tail)
    absorbed, out = set(), []
    for cid in sorted(where, key=lambda c: (calls[c][0], c)):
        if cid in absorbed:
            continue
        p, i, _ = where[cid]
        seq = sequences[p]
        members, last, outcome, quiet, j = [cid], cid, None, 0, i + 1
        while j < len(seq):
            nxt = seq[j]
            j += 1
            if nxt in members:
                continue
            if refused(nxt):
                members.append(nxt)
                absorbed.add(nxt)
                last, quiet = nxt, 0
                continue
            cmd = calls[nxt][1]
            if OVERRIDE in cmd:
                outcome = "overridden"
                break
            if nxt in results and GUARDED.search(cmd):
                outcome = "failed" if results[nxt][0] else "taught"
                break
            quiet += 1
            if quiet >= WINDOW:
                outcome = "dropped"
                break
        if outcome is None:
            # Calls came after it but none ran the part refused: dropped. None came: ended.
            outcome = "dropped" if quiet else "ended"
        out.append((members, last, outcome))
    return out


def main(argv):
    ap = argparse.ArgumentParser(description="Wrapped command refusals against every Bash call, and what came next.")
    ap.add_argument("--since", required=False, default=None, help="first day, YYYY-MM-DD in ET")
    ap.add_argument("--until", required=False, default=None, help="day after the last, YYYY-MM-DD in ET")
    ap.add_argument("--root", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--ledger", default=None)
    ap.add_argument("--hook", default=DEFAULT_HOOK)
    a = ap.parse_args(argv)
    tz = eastern()
    zone = "ET" if tz else "local time"
    today = datetime.datetime.now(tz).strftime("%Y-%m-%d")
    until_day = a.until or today
    since_day = a.since or (datetime.datetime.strptime(until_day, "%Y-%m-%d") - datetime.timedelta(days=7)).strftime("%Y-%m-%d")
    try:
        since, until = day_start(since_day, tz), day_start(until_day, tz)
    except ValueError:
        print("wrapped-refusal-followups: --since and --until are dates, YYYY-MM-DD.", file=sys.stderr)
        return 2
    if until <= since:
        print("wrapped-refusal-followups: --until must be after --since.", file=sys.stderr)
        return 2
    report = load_report()
    ledger = a.ledger or report.ledger_default()
    days = round((until - since) / 86400)
    host = socket.gethostname().split(".")[0]

    sequences, calls, results, bad, files = read_transcripts(a.root, since)
    in_period = [c for c, (ts, _) in calls.items() if ts is not None and since <= ts < until]
    print("Wrapped command refusals and what came next on %s, %s %s to %s %s (%d days, the last day not included)"
          % (host, since_day, zone, until_day, zone, days))
    print("  %d transcripts read" % files["read"])
    print("  transcripts that could not be read: %d" % files["unreadable"])
    print("  transcripts gone before they could be read (deleted or moved after being listed): %d" % files["gone"])
    if files["unreadable"] or files["gone"]:
        print("  every total below leaves out whatever those %d transcripts hold"
              % (files["unreadable"] + files["gone"]))
    if bad:
        print("  %d transcript lines could not be read" % bad)
    if not in_period:
        print("  no Bash call found in the period, so nothing was measured.")
        return 1
    eps = episodes(sequences, calls, results, since, until)
    refusals = sum(len(m) for m, _, _ in eps)
    print("  Bash calls: %d" % len(in_period))
    print("  refused by the wrapped command gate: %d (%.1f%% of Bash calls), in %d episodes"
          % (refusals, 100.0 * refusals / len(in_period), len(eps)))

    if os.path.exists(ledger):
        try:
            rows, rbad = report.read(ledger)
        except OSError as e:
            print("  the record (refusals.tsv) could not be read (%s)" % e)
        else:
            skip = report.suite_rows(rows)
            kept = [r for i, r in enumerate(rows) if since <= r[0] < until and i not in skip]
            suite = sum(1 for i in skip if since <= rows[i][0] < until)
            print("  the record (refusals.tsv) holds %d refusals in the same period, not counting %d of the fail closed suite's own"
                  % (len(kept), suite))
            if rbad:
                print("  %d record lines could not be read" % rbad)
    else:
        print("  the record (refusals.tsv) does not exist on this Mac")

    shape_of, script_of, shapes, scripts = {}, {}, {}, {}
    for members, _, _ in eps:
        for cid in members:
            s, script = todays_shape(a.hook, calls[cid][1])
            shape_of[cid], script_of[cid] = s, script
            shapes[s] = shapes.get(s, 0) + 1
            if script:
                scripts[script] = scripts.get(script, 0) + 1
    print("  by shape, as today's gate reads each refused command, commonest first:")
    for s, n in sorted(shapes.items(), key=lambda kv: (-kv[1], kv[0])):
        print("    %d  %s" % (n, s))
    if scripts:
        print("  the script each script-file refusal names, commonest first:")
        for s, n in sorted(scripts.items(), key=lambda kv: (-kv[1], kv[0])):
            print("    %d  %s" % (n, s))

    print("  what came next, per episode (a run of refusals until the git, gh or rtk part ran, or %d Bash calls passed without it):" % WINDOW)
    counts = {k: 0 for k, _ in OUTCOMES}
    by_shape = {}
    for _, last, outcome in eps:
        counts[outcome] += 1
        by_shape.setdefault(shape_of[last], {k: 0 for k, _ in OUTCOMES})[outcome] += 1
    for k, label in OUTCOMES:
        print("    %s: %d" % (label, counts[k]))
    print("  outcomes by the shape of each episode's last refusal:")
    for s, c in sorted(by_shape.items(), key=lambda kv: (-sum(kv[1].values()), kv[0])):
        print("    %s: taught %d, retried and failed %d, overridden %d, dropped %d, ended %d"
              % (s, c["taught"], c["failed"], c["overridden"], c["dropped"], c["ended"]))
    by_script = {}
    for _, last, outcome in eps:
        if script_of.get(last):
            by_script.setdefault(script_of[last], {k: 0 for k, _ in OUTCOMES})[outcome] += 1
    if by_script:
        print("  outcomes by the script each script-file episode's last refusal names:")
        for s, c in sorted(by_script.items(), key=lambda kv: (-sum(kv[1].values()), kv[0])):
            print("    %s: taught %d, retried and failed %d, overridden %d, dropped %d, ended %d"
                  % (s, c["taught"], c["failed"], c["overridden"], c["dropped"], c["ended"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
