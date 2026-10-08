#!/usr/bin/env python3
"""Condense Claude Code session transcripts into per-project friction files.

Auto-discovers project transcript dirs under ~/.claude/projects, skips tmp-dir
noise, and writes one condensed friction_<name>.txt per project to --out.

Usage: extract_friction.py [--days 14] [--min-sessions 3] --out <dir>
"""
import argparse, glob, json, os, re, sys, time
from datetime import datetime

BASE = os.path.expanduser("~/.claude/projects")
MAX_MSG = 700
SKIP_DIR_PATTERNS = (r"^-private-var-folders-", r"^-tmp-", r"-worktrees-")


def txt(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            b.get("text", "") for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


def clip(s, n=MAX_MSG):
    s = s.strip()
    return s if len(s) <= n else s[:n] + " …[clipped]"


def discover(cutoff, min_sessions):
    found = {}
    for d in sorted(glob.glob(os.path.join(BASE, "*"))):
        if not os.path.isdir(d):
            continue
        dirname = os.path.basename(d)
        if any(re.search(p, dirname) for p in SKIP_DIR_PATTERNS):
            continue
        files = [f for f in glob.glob(os.path.join(d, "*.jsonl"))
                 if os.path.getmtime(f) >= cutoff]
        if len(files) < min_sessions:
            continue
        segments = [s for s in dirname.lower().split("-") if s]
        name = segments[-1] if segments else dirname
        # De-collide short names (e.g. two dirs ending in the same word).
        base_name, i = name, 2
        while name in found:
            name = f"{base_name}{i}"
            i += 1
        found[name] = sorted(files, key=os.path.getmtime)
    return found


def condense(name, files, out_dir):
    """Write one project's friction file. Returns the transcripts that could not be read."""
    unreadable = []
    out_lines = []
    stats = {"sessions": 0, "user_msgs": 0, "interrupts": 0, "tool_errors": 0, "odd_records": 0}
    for f in files:
        sid = os.path.basename(f)[:8]
        session_lines = []
        err_counts, err_samples = {}, []
        n_user = 0
        try:
            with open(f, "r", errors="replace") as fh:
                for line in fh:
                    try:
                        rec = json.loads(line)
                    except json.JSONDecodeError:
                        continue  # a torn or partial line; the rest of the transcript still counts
                    try:
                        if not isinstance(rec, dict):
                            continue  # valid JSON that is not a record (null, a number, a list)
                        if rec.get("isSidechain"):
                            continue
                        ts = (rec.get("timestamp") or "")[:16]
                        if rec.get("type") != "user":
                            continue
                        message = rec.get("message")
                        content = message.get("content") if isinstance(message, dict) else None
                        if isinstance(content, list):
                            for b in content:
                                if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error"):
                                    et = b.get("content")
                                    et = et if isinstance(et, str) else txt(et)
                                    key = re.sub(r"\d+", "N", (et or "")[:80])
                                    err_counts[key] = err_counts.get(key, 0) + 1
                                    if len(err_samples) < 8:
                                        err_samples.append(clip(et or "", 300))
                                    stats["tool_errors"] += 1
                        t = txt(content)
                        if not t:
                            continue
                        if "<command-name>" in t:
                            m = re.search(r"<command-name>(.*?)</command-name>", t)
                            if m:
                                session_lines.append(f"  [{ts}] SLASH: {m.group(1)}")
                            continue
                        if t.startswith("<local-command") or "<local-command-stdout>" in t:
                            continue
                        if "[Request interrupted by user" in t:
                            stats["interrupts"] += 1
                            session_lines.append(f"  [{ts}] INTERRUPT: {clip(t, 300)}")
                            continue
                        if t.startswith("<") and "system-reminder" in t[:60]:
                            continue
                        n_user += 1
                        stats["user_msgs"] += 1
                        session_lines.append(f"  [{ts}] USER: {clip(t)}")
                    except (TypeError, AttributeError, ValueError):
                        # A record whose fields have shapes no transcript was seen to have. Counted
                        # and shown in the header, so a skipped record is never a silent one.
                        stats["odd_records"] += 1
        except OSError as e:
            session_lines.append(f"  READ-ERROR: {e}")
            unreadable.append((f, e))
        if not session_lines and not err_counts:
            continue
        stats["sessions"] += 1
        day = datetime.fromtimestamp(os.path.getmtime(f)).strftime("%Y-%m-%d")
        out_lines.append(f"\n=== SESSION {sid} ({day}) user_msgs={n_user} ===")
        out_lines.extend(session_lines)
        top_errs = sorted(err_counts.items(), key=lambda kv: -kv[1])[:6]
        if top_errs:
            out_lines.append("  -- top tool-error signatures --")
            out_lines.extend(f"  ({c}x) {k}" for k, c in top_errs)
            out_lines.extend(f"  ERRSAMPLE: {s}" for s in err_samples[:4])
    header = (f"PROJECT: {name} | {stats['sessions']} sessions w/ activity, "
              f"{stats['user_msgs']} user msgs, {stats['interrupts']} interrupts, "
              f"{stats['tool_errors']} tool errors"
              + (f", {stats['odd_records']} odd records skipped" if stats["odd_records"] else "")
              + "\n")
    path = os.path.join(out_dir, f"friction_{name}.txt")
    with open(path, "w") as fh:
        fh.write(header)
        fh.write("\n".join(out_lines))
    print(f"{header.strip()} -> {path} ({os.path.getsize(path) // 1024}KB)")
    return unreadable


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--min-sessions", type=int, default=3)
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    os.makedirs(args.out, exist_ok=True)
    cutoff = time.time() - args.days * 86400
    projects = discover(cutoff, args.min_sessions)
    if not projects:
        print("No project transcript dirs matched the window.")
        return 0
    unreadable = []
    for name, files in projects.items():
        unreadable += condense(name, files, args.out)
    # Every file that could be read is already written. A transcript that could not be is a hole
    # in the audit, so the run says which and fails rather than reading as complete (#677).
    if unreadable:
        print(f"extract_friction: {len(unreadable)} transcript(s) could not be read, so the friction "
              f"files above are missing their sessions:", file=sys.stderr)
        for f, e in unreadable:
            print(f"  {f}: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
