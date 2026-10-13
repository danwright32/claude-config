#!/usr/bin/env python3
"""The tracker skill's local helpers, run through tracker.sh, never on their own.

  tracker_lib.py new-token      a fresh token, written straight into config.local.json
  tracker_lib.py sheet-id       the id of the one sheet SKILL.md names (claude-config#1080)
  and the commands behind /tracker --scan (claude-config#1032, SKILL.md "Scanning git work"):
  scan, set-authors, ignore-repo, unignore-repo, authors-found, reconcile, snapshot, scan-cells.

Every write of a *.local.json file goes through write_local_json: the half written copy is
itself named *.local.json, so the skill's .gitignore and claude-sync's mirror both leave it out,
it is readable by its owner only, and it is renamed into place whole. A file that exists but
cannot be read is never overwritten: it may hold the only copy of the web app link or the token.
"""
import json
import os
import re
import secrets
import string
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "config.local.json")
EXAMPLE = os.path.join(HERE, "config.example.json")
SKILL_MD = os.path.join(HERE, "SKILL.md")
SCAN_STATE = os.path.join(HERE, "scan-state.local.json")
SCAN_SH = os.path.join(HERE, "scan.sh")


class Refusal(Exception):
    """A refusal, said in one sentence on stderr, exit 1, nothing written."""


def read_object(path, missing_ok=False):
    """The JSON object in path; None when it is missing and that is allowed. Anything else that
    cannot be read as an object is a refusal, never an empty default (L5)."""
    if not os.path.exists(path):
        if missing_ok:
            return None
        raise Refusal("%s is missing" % path)
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:  # any unreadable file is refused by name, never read as empty
        raise Refusal("%s could not be read (%s). Fix or remove it, then try again; nothing was written" % (path, type(e).__name__))
    if not isinstance(data, dict):
        raise Refusal("%s is not a JSON object. Fix or remove it, then try again; nothing was written" % path)
    return data


def write_local_json(path, data):
    """Writes data to path (a *.local.json file) whole, or not at all."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".writing.", suffix=".local.json")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    if os.environ.get("TRACKER_TEST_STOP_BEFORE_RENAME") == "1":
        os._exit(9)  # test seam: stands in for a run killed between the write and the rename
    os.replace(tmp, path)


def new_token(args):
    if args:
        raise Refusal("new-token takes no arguments")
    src = CONFIG if os.path.exists(CONFIG) else EXAMPLE
    try:
        data = read_object(src)
    except Refusal as r:
        raise Refusal("Refusing to write a token: %s" % r)
    alphabet = string.ascii_letters + string.digits
    data["token"] = "".join(secrets.choice(alphabet) for _ in range(40))
    write_local_json(CONFIG, data)
    print("Wrote a new token to %s (not shown here). Copy it from that file into the TOKEN line of "
          "the Apps Script, then deploy a new version." % CONFIG)


SHEET_LINK = re.compile(r"docs\.google\.com/spreadsheets/d/([A-Za-z0-9_-]+)")


def sheet_id_of(skill_md=SKILL_MD):
    """The id in SKILL.md's sheet link, the one declared home of which sheet the tracker writes.
    A SKILL.md naming no sheet, or two different ones, is a refusal, never a guess."""
    try:
        with open(skill_md, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        raise Refusal("%s could not be read (%s), so which sheet the web app must answer for is unknown. Nothing was sent" % (skill_md, type(e).__name__))
    ids = sorted(set(SHEET_LINK.findall(text)))
    if not ids:
        raise Refusal("SKILL.md names no sheet (it has no docs.google.com/spreadsheets/d/ link), so which sheet the web app must answer for is unknown. Nothing was sent")
    if len(ids) > 1:
        raise Refusal("SKILL.md names more than one sheet (%s), so which one the web app must answer for is unknown. Leave one sheet link in it. Nothing was sent" % ", ".join(ids))
    return ids[0]


def sheet_id(args):
    if args:
        raise Refusal("sheet-id takes no arguments")
    print(sheet_id_of())


# --- /tracker --scan (claude-config#1032) -------------------------------------------------------
# The scan reads three optional keys of config.local.json, none of which the append path ever
# looks at: authors (the user's names or emails), scan_roots (folders to search, ~ for HOME) and
# scan_window_days. Absent, scan.sh's own defaults apply (HOME, 30 days), so they live in one place.
# The repositories the user never wants offered live apart, in scan-state.local.json, so the flow
# that writes them often never rewrites the file holding the token.


def text_list(obj, key, where, required=False):
    """obj[key] as a list of non blank strings; [] when absent. Any other shape is refused by
    name, never dropped (L320)."""
    v = obj.get(key)
    if v is None and not required:
        return []
    if not isinstance(v, list) or (required and not v) or not all(isinstance(x, str) and x.strip() for x in v):
        raise Refusal("%s: %s must be a list of %s, each one non empty text" % (where, key, "at least one value" if required else "values"))
    return [x.strip() for x in v]


def scan_settings():
    cfg = read_object(CONFIG, missing_ok=True) or {}
    state = read_object(SCAN_STATE, missing_ok=True) or {}
    where = os.path.basename(CONFIG)
    days = cfg.get("scan_window_days")
    if days is not None and (isinstance(days, bool) or not isinstance(days, int) or days < 1):
        raise Refusal("%s: scan_window_days must be a whole number of days above zero, not %r" % (where, days))
    return {
        "authors": text_list(cfg, "authors", where),
        "roots": [os.path.expanduser(r) for r in text_list(cfg, "scan_roots", where)],
        "days": days,
        "ignored": text_list(state, "ignored", os.path.basename(SCAN_STATE)),
    }


def scan(args):
    s = scan_settings()
    argv = ["bash", SCAN_SH]
    for r in s["roots"]:
        argv += ["--root", r]
    for a in s["authors"]:
        argv += ["--author", a]
    if s["days"] is not None:
        argv += ["--days", str(s["days"])]
    for i in s["ignored"]:
        argv += ["--ignore", i]
    sys.stdout.flush()
    os.execvp("bash", argv + list(args))


def parse_json_arg(text, what):
    try:
        return json.loads(text)
    except ValueError:
        raise Refusal("the %s are not JSON" % what)


def set_authors(args):
    if len(args) != 1:
        raise Refusal("usage: tracker.sh set-authors '<JSON list of your names or emails>'")
    # The same check the scan makes when it reads them back, so what is saved is what it accepts.
    authors = text_list({"authors": parse_json_arg(args[0], "authors")}, "authors", "set-authors", required=True)
    src = CONFIG if os.path.exists(CONFIG) else EXAMPLE
    data = read_object(src)
    data["authors"] = authors
    write_local_json(CONFIG, data)
    print("Saved %d author%s to %s." % (len(authors), "" if len(authors) == 1 else "s", CONFIG))


def repo_path(arg):
    p = os.path.expanduser(arg)
    # Resolved, as scan.sh compares them, so /tmp/x and /private/tmp/x are one repository.
    return os.path.realpath(p) if os.path.exists(p) else os.path.abspath(p)


def ignore_repo(args, add=True):
    verb = "ignore-repo" if add else "unignore-repo"
    if len(args) != 1 or not args[0].strip():
        raise Refusal("usage: tracker.sh %s '<path of a repository>'" % verb)
    path = repo_path(args[0])
    state = read_object(SCAN_STATE, missing_ok=True) or {}
    ignored = text_list(state, "ignored", os.path.basename(SCAN_STATE))
    if add:
        if path not in ignored:
            ignored.append(path)
    else:
        if path not in ignored:
            raise Refusal("%s is not ignored; %s lists %s" % (path, os.path.basename(SCAN_STATE), ", ".join(ignored) or "nothing"))
        ignored.remove(path)
    state["ignored"] = ignored
    write_local_json(SCAN_STATE, state)
    print("%s %s; %s now lists %d." % ("Ignoring" if add else "No longer ignoring", path, SCAN_STATE, len(ignored)))


def load_scan(path):
    scan_out = read_object(path)
    if scan_out.get("scan_version") != 1 or not isinstance(scan_out.get("repos"), list):
        raise Refusal("%s is not the JSON tracker.sh scan prints (scan_version 1)" % path)
    return scan_out


def authors_found(args):
    if len(args) != 1:
        raise Refusal("usage: tracker.sh authors-found '<file holding the scan JSON>'")
    scan_out = load_scan(args[0])
    found = {}
    for repo in scan_out["repos"]:
        people = repo.get("authors_in_window")
        if people is None:
            sys.stderr.write("tracker.sh: the authors of %s could not be read, so they are not listed.\n" % repo.get("path"))
            continue
        for a in people:
            key = a["email"].casefold()
            e = found.setdefault(key, {"email": a["email"], "names": {}, "commits": 0, "repos": set()})
            e["names"][a["name"]] = e["names"].get(a["name"], 0) + a["commits"]
            e["commits"] += a["commits"]
            e["repos"].add(repo["path"])
    out = [{"email": e["email"], "name": max(sorted(e["names"]), key=lambda n: e["names"][n]),
            "commits": e["commits"], "repos": len(e["repos"])} for e in found.values()]
    out.sort(key=lambda e: (-e["commits"], e["email"].casefold()))
    print(json.dumps(out, indent=2, ensure_ascii=False))


def norm_header(h):
    return str(h).strip().casefold()


def load_sheet(path):
    """The sheet as the connector read it: {"range", "values"} or a bare list of rows, row 1 the
    headers. Returns (headers, [(sheet row number, {header: text})]) for every non empty row, each
    padded to the headers' width, since the connector stops a row at its last non empty cell."""
    try:
        with open(path, encoding="utf-8") as f:
            raw = json.load(f)
    except Exception as e:  # unreadable is refused by name, never read as an empty sheet
        raise Refusal("%s could not be read as the sheet's JSON (%s)" % (path, type(e).__name__))
    values = raw
    if isinstance(raw, dict):
        rng = raw.get("range")
        if rng is not None and not re.match(r"^\$?A\$?1(:|$)", str(rng).split("!")[-1], re.I):
            raise Refusal("%s was read from %s, not from A1, so every row number would be wrong. Read the sheet from A1" % (path, rng))
        values = raw.get("values")
    if not isinstance(values, list) or not values or not all(isinstance(r, list) for r in values):
        raise Refusal("%s holds no rows: it must be the connector's values, a list of rows with the headers first" % path)
    headers = ["" if h is None else str(h).strip() for h in values[0]]
    for want in ("Project Name", "Link"):
        n = sum(1 for h in headers if norm_header(h) == norm_header(want))
        if n == 0:
            raise Refusal("%s has no %s column, so its rows cannot be matched" % (path, want))
        if n > 1:
            raise Refusal("%s has more than one %s column, so which one to match on is unknown" % (path, want))
    rows = []
    for i, r in enumerate(values[1:], start=2):
        cells = ["" if c is None else str(c) for c in r] + [""] * (len(headers) - len(r))
        if not any(c.strip() for c in cells):
            continue
        row = {}
        for h, c in zip(headers, cells):
            if h and h not in row:
                row[h] = c
        rows.append((i, row))
    return headers, rows


def cell(row, header):
    return next((v for h, v in row.items() if norm_header(h) == norm_header(header)), "").strip()


def normalize_link(link):
    """host/owner/repo for a repository address, by scan.sh's own normalizer, or None. A Link
    typed without its scheme (github.com/owner/repo) is read as https."""
    tries = [link]
    if "://" not in link and ":" not in link and re.match(r"^[A-Za-z0-9.-]+\.[A-Za-z]+/", link):
        tries.append("https://" + link)
    for t in tries:
        r = subprocess.run(["bash", SCAN_SH, "--normalize-url", t], capture_output=True, text=True)
        if r.returncode == 0:
            return r.stdout.strip()
        if r.returncode != 1:
            raise Refusal("scan.sh --normalize-url failed (exit %d): %s" % (r.returncode, r.stderr.strip()))
    return None


def reconcile(args):
    if len(args) != 2:
        raise Refusal("usage: tracker.sh reconcile '<file holding the scan JSON>' '<file holding the sheet as read>'")
    scan_out = load_scan(args[0])
    if not scan_out.get("authors"):
        raise Refusal("the scan was run with no authors set, so none of its commits can be counted as yours. "
                      "Run tracker.sh authors-found on it, ask which identities are yours, save them with "
                      "tracker.sh set-authors, and scan again")
    _, rows = load_sheet(args[1])

    by_url = {}
    tracked_not_here = []
    for n, row in rows:
        link = cell(row, "Link")
        url = normalize_link(link) if link else None
        entry = {"row_number": n, "project_name": cell(row, "Project Name"), "link": link, "normalized_url": url, "row": row}
        if url:
            by_url.setdefault(url, []).append(entry)
        else:
            entry["reason"] = "its Link is not a repository address" if link else "it has no Link"
            tracked_not_here.append(entry)

    groups = {}
    for repo in scan_out["repos"]:
        key = repo.get("normalized_url") or ("path:" + repo["path"])
        groups.setdefault(key, []).append(repo)

    matched, new_here, no_commits, questions = [], [], [], []
    for key, repos in sorted(groups.items()):
        url = repos[0].get("normalized_url")
        hits = by_url.pop(url, []) if url else []
        counts = [r.get("window_commit_count") for r in repos]
        q = {"normalized_url": url, "rows": [h["row_number"] for h in hits], "paths": [r["path"] for r in repos]}
        if any(c is None for c in counts):
            q["reason"] = "the commits of %s could not be read (%s), so whether it holds your work is unknown" % (
                ", ".join(r["path"] for r in repos), "; ".join(e for r in repos for e in r.get("errors") or []) or "no detail")
            questions.append(q)
            continue
        mine = sum(counts)
        if len(repos) > 1:
            q["reason"] = "%d copies of this repository are on this Mac; ask which one is the project's, or ignore the others" % len(repos)
            questions.append(q)
        elif len(hits) > 1:
            q["reason"] = "more than one row (%s) has this repository's Link, so which one to update is unknown; ask, and update none until one remains" % ", ".join(str(h["row_number"]) for h in hits)
            questions.append(q)
        elif len(hits) == 1:
            h = hits[0]
            matched.append({"status": "update" if mine > 0 else "current", "row_number": h["row_number"],
                            "project_name": h["project_name"], "link": h["link"], "normalized_url": url,
                            "row": h["row"], "repo": repo_summary(repos[0])})
        elif not url and mine > 0:
            q["reason"] = "it has your commits but no hosted remote, so no Link can ever match it; ask whether to add it with an empty Link, or ignore it"
            questions.append(q)
        elif mine > 0:
            new_here.append(repo_summary(repos[0]))
        else:
            no_commits.append({k: repos[0].get(k) for k in ("path", "normalized_url", "repo_name")})
    for url, entries in by_url.items():
        for e in entries:
            e["reason"] = "no repository on this Mac has its Link"
            tracked_not_here.append(e)

    tracked_not_here.sort(key=lambda e: e["row_number"])
    matched.sort(key=lambda e: e["row_number"])
    questions.sort(key=lambda q: (q["rows"][:1] or [10 ** 9], q["paths"]))
    out = {k: scan_out.get(k) for k in ("authors", "since", "until", "window_days", "roots_searched", "ignored", "warnings")}
    out.update({
        "matched": matched, "tracked_not_here": [{k: e[k] for k in ("row_number", "project_name", "link", "reason")} for e in tracked_not_here],
        "new_here": new_here, "no_commits_by_you": no_commits, "questions": questions,
    })
    print(json.dumps(out, indent=2, ensure_ascii=False))


def repo_summary(repo):
    return {k: repo.get(k) for k in ("path", "normalized_url", "repo_name", "remote_url", "window_commit_count",
                                     "window_subjects", "first_commit_date", "last_commit_date", "is_shallow", "worktrees")}


def snapshot(args):
    if len(args) != 1:
        raise Refusal("usage: tracker.sh snapshot '<file holding the sheet as read>'")
    src = args[0]
    load_sheet(src)  # the same reading the reconcile makes, so a snapshot is never of something unreadable
    folder = os.environ.get("TRACKER_SNAPSHOT_DIR") or os.path.join(os.path.expanduser("~"), ".claude-tracker-snapshots")
    synced = os.path.realpath(os.path.join(os.path.expanduser("~"), ".claude"))
    real = os.path.realpath(folder)
    if real == synced or real.startswith(synced + os.sep):
        raise Refusal("the snapshot folder %s is inside ~/.claude, which syncs to the public repository, so a copy of the sheet would travel with it. Choose a folder outside it" % folder)
    os.makedirs(folder, mode=0o700, exist_ok=True)
    with open(src, "rb") as f:
        content = f.read()
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    for n in range(1, 1000):
        path = os.path.join(folder, "sheet-%s%s.json" % (stamp, "" if n == 1 else "-%d" % n))
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            continue
        with os.fdopen(fd, "wb") as f:
            f.write(content)
        print(path)
        return
    raise Refusal("could not find a free snapshot name in %s" % folder)


# A dash used as punctuation, in any of its forms, and a pipe used as a separator: the writing
# style allows a hyphen only inside a word. Made with chr() so this file holds no such character.
SEPARATORS = re.compile(r"\s*[" + re.escape(chr(0x2014) + chr(0x2013) + "|") + r"]\s*|\s+-\s+")


def clean_text(s):
    s = SEPARATORS.sub(", ", s)
    s = re.sub(r"(\s*,\s*){2,}", ", ", s)
    return s.strip().strip(",").strip()


def scan_cells(args):
    if len(args) != 2:
        raise Refusal("usage: tracker.sh scan-cells '<the row as it is, header:value>' '<the cells to write, header:value>'")
    row = parse_json_arg(args[0], "row's values")
    cells = parse_json_arg(args[1], "cells")
    if not isinstance(row, dict):
        raise Refusal("the row must be a JSON object of header:value, {} for a new row")
    if not isinstance(cells, dict) or not cells:
        raise Refusal("the cells must be a JSON object naming at least one column")
    has = lambda h: str(cell({k: "" if v is None else str(v) for k, v in row.items()}, h))
    out = {}
    for k, v in cells.items():
        h = norm_header(k)
        if h == norm_header("Date Started") and has("Date Started"):
            raise Refusal("Date Started is already %r on this row, and the scan keeps it; leave it out of the cells" % has("Date Started"))
        if h == norm_header("Date Completed") and has("Date Completed") and (v is None or (isinstance(v, str) and not v.strip())):
            raise Refusal("Date Completed is already %r on this row, and the scan never clears it" % has("Date Completed"))
        if h == norm_header("Link") and has("Link") and (not isinstance(v, str) or v.strip() != has("Link")):
            raise Refusal("the scan never changes the Link a row is found by (%r)" % has("Link"))
        out[k] = clean_text(v) if isinstance(v, str) and h != norm_header("Link") else v
    print(json.dumps(out, ensure_ascii=False))


COMMANDS = {
    "new-token": new_token,
    "sheet-id": sheet_id,
    "scan": scan,
    "set-authors": set_authors,
    "ignore-repo": ignore_repo,
    "unignore-repo": lambda args: ignore_repo(args, add=False),
    "authors-found": authors_found,
    "reconcile": reconcile,
    "snapshot": snapshot,
    "scan-cells": scan_cells,
}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        sys.stderr.write("tracker_lib.py: unknown command %r; it is run through tracker.sh\n" % (argv[0] if argv else ""))
        return 2
    try:
        COMMANDS[argv[0]](argv[1:])
    except Refusal as r:
        sys.stderr.write("tracker.sh: %s.\n" % r)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
