#!/usr/bin/env python3
"""The deterministic half of the architecture pass (claude-config#1504).

    python3 measure.py hotspots <repo> [--ref REF] [--since WHEN] [--top N]
    python3 measure.py kinds <repo> [--ref REF] [--since WHEN]
    python3 measure.py last-pass <repo> [--key OWNER/NAME]
    python3 measure.py record-pass <repo> [--key OWNER/NAME]

Everything the pass COUNTS lives here, with tests, because a counting rule written only in the
skill's prose is a hope (L27). The manual passes of 2026-10-22 taught three of them:

1. A fix is counted by its commit TITLE only. `git log --grep` also matches bodies, and it inflated
   one file from 5 real fixes to 59. This reads `%s`, the subject line, and nothing else.
2. Title words are noisy: about half of one repo's "fix" titles were new monitoring features worded
   "Page when X stops", or "Stop X" titles. So every candidate title is sorted into a KIND by rule,
   those two are reported beside the fixes rather than inside them, and a kind that keeps recurring
   is the signal, never a file's raw count.
3. Most hot files were hot because they GREW. Every file carries how many of its commits only added
   lines, and its net growth against its size now, so a file is never called a problem for growing.

hotspots and kinds print JSON naming the ref, its sha and the window they read (L454). last-pass
and record-pass keep the date of each repo's last pass in a file on this Mac, outside ~/.claude so
the sync never carries or deletes it: ARCH_PASS_STATE_DIR (default ~/.claude-architecture-pass).
ARCH_PASS_TODAY (YYYY-MM-DD) sets today, for tests.

Exit: 0 measured, 1 could not measure (the reason on stderr), 2 bad arguments.
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict

DUE_AFTER_DAYS = 30
DEFAULT_SINCE = "90 days ago"
STATE_FILE = "last-pass.json"


class MeasureError(Exception):
    pass


# ---- titles -------------------------------------------------------------------------------------

# A title is a fix CANDIDATE when it holds one of these words. Word boundaries, so "prefix" and
# "debugger" are not fixes. "no longer" is here because this owner's fixes are often worded as the
# behaviour now ("so git commit no longer hangs") with no fix word at all.
CANDIDATE = re.compile(
    r"\b(fix|fixes|fixed|fixing|hotfix|bug|bugs|broken|breaks?|crash(es|ed|ing)?|regression|"
    r"repair(s|ed|ing)?|no longer|wrong|incorrect(ly)?|stop(s|ped|ping)?|revert(s|ed)?)\b",
    re.IGNORECASE,
)

# Candidates that are NOT fixes, checked first. Reported beside the fixes, never in their total.
NOT_FIX_KINDS = [
    ("revert", re.compile(r"^revert\b", re.IGNORECASE)),
    ("alerting-feature", re.compile(
        r"^(page|alert|notify|warn|ping|tell|email|post|flag)\b.*\b(when|whenever|if|on)\b", re.IGNORECASE)),
    ("stop-title", re.compile(r"^stop\b", re.IGNORECASE)),
]

# The kind of a real fix, first match wins, so the order is part of the rule.
FIX_KINDS = [
    ("concurrency", r"\brace\w*|\bconcurren\w*|\btwice\b|\bdouble\w*|\bduplicat\w*|\block(s|ed|ing)?\b|"
                    r"\bidempoten\w*|\bin parallel\b|\bat once\b|\bretr(y|ies|ied)\b"),
    ("time", r"\btime ?zones?\b|\butc\b|\bdst\b|\bdates?\b|\bclock\b|\bdeadlines?\b|\bexpir\w*|"
             r"\bstale\b|\bmidnight\b"),
    ("missing-value", r"\bnull\b|\bundefined\b|\bmissing\b|\bempty\b|\bblank\b|\bnan\b|\babsent\b|\bnil\b"),
    ("hang-timeout", r"\bhang(s|ing)?\b|\bhung\b|\btime(d)? ?outs?\b|\bstuck\b|\bslow\w*|\bfor ever\b|\bforever\b"),
    ("auth", r"\bauth\w*|\bpermissions?\b|\btokens?\b|\blog ?in\b|\bsign ?in\b|\b40[13]\b|\bscopes?\b|"
             r"\bcredentials?\b|\baccounts?\b"),
    ("limits", r"\blimits?\b|\bcap(s|ped)?\b|\btruncat\w*|\bpaginat\w*|\b1,?000\b|\boverflow\w*|"
               r"\btoo (long|large|many|big)\b"),
    ("text-encoding", r"\bencod\w*|\bescap\w*|\bunicode\b|\bquot\w*|\bdash(es)?\b|\bemoji\b|\butf-?8\b|"
                      r"\bnewlines?\b|\bwhitespace\b"),
    ("tests", r"\bflak\w*|\btests?\b"),
]
FIX_KINDS = [(name, re.compile(rx, re.IGNORECASE)) for name, rx in FIX_KINDS]


def classify_title(title):
    """(is_fix, kind). kind is None when the title is not a fix candidate at all."""
    if not CANDIDATE.search(title):
        return False, None
    for name, rx in NOT_FIX_KINDS:
        if rx.search(title):
            return False, name
    for name, rx in FIX_KINDS:
        if rx.search(title):
            return True, name
    return True, "other"


# ---- git ----------------------------------------------------------------------------------------

def git(repo, *args):
    try:
        return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True, errors="replace").stdout
    except FileNotFoundError as e:
        raise MeasureError(f"git is not installed: {e}")
    except subprocess.CalledProcessError as e:
        raise MeasureError(f"git {' '.join(args[:3])} failed in {repo}: {e.stderr.strip() or e.returncode}")


RENAME_BRACE = re.compile(r"^(.*)\{(.*) => (.*)\}(.*)$")


def _tidy(path):
    return re.sub(r"/+", "/", path).lstrip("/")


def rename_parts(path):
    """(old, new) for a numstat path; old is None when the line is not a rename."""
    m = RENAME_BRACE.match(path)
    if m:
        pre, a, b, post = m.groups()
        return _tidy(pre + a + post), _tidy(pre + b + post)
    if " => " in path:
        old, new = path.split(" => ", 1)
        return old, new
    return None, path


# Files that are never a structural finding however often they change: prose, and what a package
# manager writes. On claude-config's own history the README topped every fix kind, because every
# change documents itself there, and buried the code each kind was about.
LOCKFILES = {"package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "Cargo.lock",
             "Package.resolved", "Podfile.lock", "Gemfile.lock", "poetry.lock", "uv.lock", "go.sum"}


def is_noise(path):
    name = path.rsplit("/", 1)[-1]
    return name in LOCKFILES or name.lower().endswith((".md", ".markdown", ".txt", ".rst"))


def default_ref(repo):
    """(ref, note). The origin default branch, which is what shipped, else HEAD with a note saying so."""
    try:
        name = git(repo, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD").strip()
        if name:
            return name, ""
    except MeasureError:
        pass
    for candidate in ("origin/main", "origin/master"):
        try:
            git(repo, "rev-parse", "--verify", "--quiet", f"refs/remotes/{candidate}")
            return candidate, ""
        except MeasureError:
            continue
    return "HEAD", ("no origin default branch here, so this read HEAD, which can differ from what "
                    "shipped; run git fetch and pass --ref to read origin")


def read_log(repo, ref, since):
    """Commits in the window, newest first: [{sha, title, files: [(path, added, deleted)]}].

    Paths are the file's CURRENT name: renames are followed newest to oldest, so a file's history
    before a move is counted under the name it has now.
    """
    out = git(repo, "log", ref, "--no-merges", f"--since={since}", "-M", "--numstat",
              "--format=%x1e%H%x1f%s")
    alias = {}

    def current(path):
        seen = set()
        while path in alias and path not in seen:
            seen.add(path)
            path = alias[path]
        return path

    commits = []
    for record in out.split("\x1e")[1:]:
        lines = record.split("\n")
        sha, title = lines[0].split("\x1f", 1)
        files = []
        for line in lines[1:]:
            if not line.strip():
                continue
            added, deleted, path = line.split("\t", 2)
            old, new = rename_parts(path)
            name = current(new)
            if old is not None and old != name:
                alias[old] = name
            if is_noise(name):
                continue
            if added == "-" or deleted == "-":
                files.append((name, None, None))  # binary
            else:
                files.append((name, int(added), int(deleted)))
        commits.append({"sha": sha, "title": title, "files": files})
    return commits


def _ref_info(repo, ref, since):
    note = ""
    if ref is None:
        ref, note = default_ref(repo)
    sha = git(repo, "rev-parse", "--verify", f"{ref}^{{commit}}").strip()
    info = {"repo": os.path.abspath(repo), "ref": ref, "ref_sha": sha, "since": since}
    if note:
        info["ref_note"] = note
    return info


def _size_now(repo, ref, path):
    try:
        return git(repo, "cat-file", "-p", f"{ref}:{path}").count("\n")
    except MeasureError:
        return None  # not in the tree at ref: deleted since


# ---- the two measurements -------------------------------------------------------------------------

def hotspots(repo, ref=None, since=DEFAULT_SINCE, top=30):
    info = _ref_info(repo, ref, since)
    commits = read_log(repo, info["ref"], since)
    rows = defaultdict(lambda: {"commits": 0, "fix_commits": 0, "pure_addition_commits": 0,
                                "added": 0, "deleted": 0})
    for c in commits:
        is_fix, _ = classify_title(c["title"])
        for path, added, deleted in c["files"]:
            row = rows[path]
            row["commits"] += 1
            row["fix_commits"] += int(is_fix)
            if added is not None:
                row["added"] += added
                row["deleted"] += deleted
                if added > 0 and deleted == 0:
                    row["pure_addition_commits"] += 1
    ranked = sorted(rows.items(), key=lambda kv: (-kv[1]["commits"], -kv[1]["fix_commits"], kv[0]))[:top]
    files = []
    for path, row in ranked:
        size = _size_now(repo, info["ref"], path)
        net = row["added"] - row["deleted"]
        files.append({
            "path": path, **row,
            "pure_addition_share": round(row["pure_addition_commits"] / row["commits"], 2),
            "size_now": size,
            "net_growth_share": round(net / size, 2) if size else None,
        })
    return {**info, "commits_read": len(commits), "files": files}


def kinds(repo, ref=None, since=DEFAULT_SINCE, examples=8):
    info = _ref_info(repo, ref, since)
    commits = read_log(repo, info["ref"], since)
    buckets = {True: defaultdict(list), False: defaultdict(list)}
    for c in commits:
        is_fix, kind = classify_title(c["title"])
        if kind is not None:
            buckets[is_fix][kind].append(c)

    def summarise(groups):
        out = []
        for kind, cs in groups.items():
            paths = Counter(p for c in cs for p in {f[0] for f in c["files"]})
            out.append({"kind": kind, "count": len(cs),
                        "titles": [c["title"] for c in cs[:examples]],
                        "paths": [{"path": p, "count": n}
                                  for p, n in sorted(paths.items(), key=lambda kv: (-kv[1], kv[0]))[:5]]})
        return sorted(out, key=lambda k: (-k["count"], k["kind"]))

    fixes = summarise(buckets[True])
    return {**info, "commits_read": len(commits), "fix_total": sum(k["count"] for k in fixes),
            "kinds": fixes, "not_fixes": summarise(buckets[False])}


# ---- when the last pass was -----------------------------------------------------------------------

REMOTE = re.compile(r"[:/]([^/:]+)/([^/]+?)(?:\.git)?/?$")


def repo_key(repo):
    url = git(repo, "remote", "get-url", "origin").strip() if _has_origin(repo) else ""
    m = REMOTE.search(url)
    if not m:
        raise MeasureError(f"{repo} has no origin remote naming owner/name ({url or 'none'}); pass --key OWNER/NAME")
    return f"{m.group(1)}/{m.group(2)}"


def _has_origin(repo):
    return "origin" in git(repo, "remote").split()


def _read_state(state_dir):
    path = os.path.join(state_dir, STATE_FILE)
    try:
        with open(path, errors="replace") as f:
            data = json.load(f)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as e:
        raise MeasureError(f"the record of past passes at {path} cannot be read ({e}); fix or move it, "
                           "since reading it as empty would lose every repo's date")
    if not isinstance(data, dict) or not all(isinstance(v, str) for v in data.values()):
        raise MeasureError(f"the record of past passes at {path} is not a map of repo to date")
    return data


def _parse_day(text, what):
    try:
        return datetime.date.fromisoformat(text)
    except ValueError:
        raise MeasureError(f"{what} is not a YYYY-MM-DD date: {text!r}")


def last_pass(key, state_dir, today):
    data = _read_state(state_dir)
    if key not in data:
        return f"No architecture pass recorded for {key} on this Mac. Monthly is suggested."
    then = _parse_day(data[key], f"the recorded pass of {key}")
    days = (_parse_day(today, "today") - then).days
    head = f"Last architecture pass of {key}: {then.isoformat()}, {days} days ago. Monthly is suggested"
    if days >= DUE_AFTER_DAYS:
        return f"{head}, so one is due."
    due = then + datetime.timedelta(days=DUE_AFTER_DAYS)
    return f"{head}, so the next is not due until {due.isoformat()}."


def record_pass(key, state_dir, today):
    _parse_day(today, "today")
    data = _read_state(state_dir)
    data[key] = today
    os.makedirs(state_dir, exist_ok=True)
    path = os.path.join(state_dir, STATE_FILE)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", errors="replace") as f:
        json.dump(data, f, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)
    return f"Recorded an architecture pass of {key} on {today}."


# ---- command line -------------------------------------------------------------------------------

def main(argv=None):
    p = argparse.ArgumentParser(prog="measure.py", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("hotspots", "kinds"):
        s = sub.add_parser(name)
        s.add_argument("repo")
        s.add_argument("--ref", default=None, help="default: origin's default branch, else HEAD with a note")
        s.add_argument("--since", default=DEFAULT_SINCE)
        if name == "hotspots":
            s.add_argument("--top", type=int, default=30)
    for name in ("last-pass", "record-pass"):
        s = sub.add_parser(name)
        s.add_argument("repo")
        s.add_argument("--key", default=None, help="owner/name, default: read from the origin remote")
    args = p.parse_args(argv)
    try:
        if args.cmd == "hotspots":
            print(json.dumps(hotspots(args.repo, args.ref, args.since, args.top), indent=1))
        elif args.cmd == "kinds":
            print(json.dumps(kinds(args.repo, args.ref, args.since), indent=1))
        else:
            key = args.key or repo_key(args.repo)
            state = os.environ.get("ARCH_PASS_STATE_DIR") or os.path.expanduser("~/.claude-architecture-pass")
            today = os.environ.get("ARCH_PASS_TODAY") or datetime.date.today().isoformat()
            fn = last_pass if args.cmd == "last-pass" else record_pass
            print(fn(key, state, today))
    except MeasureError as e:
        print(f"measure.py: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main())
