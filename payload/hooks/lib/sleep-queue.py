#!/usr/bin/env python3
"""The judgments behind sleep mode's overnight queue and claims (claude-config#842).

Called only by sleep-queue.sh, which does every outside call (gh, git worktree, the claim's link
into place) and hands this the answers as files. Nothing here writes anything, so every rule below
is tested on fixtures alone.

  state  ISSUE_DIR SELF REGISTRY NOW   what one issue's claim says now (one line, see claim_state)
  queue  key=value...                  the night's queue for one repository, as tab separated
                                       lines; keys: repo limit issues prs branches accounts
                                       unanswered claims registry now self, and goal (optional)
  entry  KIND SESSION AT [WHY]         one claim entry as JSON, for the shell to link into place
  slug   ORIGIN_URL                    owner/repo of a GitHub origin, lower case, or exit 1
  claims CLAIMS_DIR                    every claim of the night as JSON lines, for the report (phase 4)

A claim is a directory per issue holding numbered entries, 1, 2, 3, each one JSON object written
whole beside it and hard linked into place, which fails if the number is taken. So of two sessions
reaching for one issue exactly one makes the next number, and nothing is ever deleted: the newest
entry is the issue's state, and the entries before it are its history, which is where the attempts
counter comes from. An entry is a claim (`kind: claim`, the session holding it) or an end
(`free`, `done`, `parked`, `failed`) written by the session that held the claim before it.

A claim's session is judged by the session registry (~/.claude/state/sessions, one file per
session): closed, silent past five minutes, or never recorded means the session is gone and the
claim is free to take. A record that cannot be read is never read as no session (L215): the claim
stays held and the reason is said.
"""
import json
import os
import re
import subprocess
import sys

DEAD_MS = 5 * 60_000  # the session registry's own rule for a session that has gone quiet
SESSION_ID = re.compile(r"^[A-Za-z0-9-]+$")
PRIORITIES = ["priority-p0", "priority-p1", "priority-p2", "priority-p3"]
# unstarted: given back because its worktree could not be made just now; free again, and no attempt.
ENDS = ("free", "unstarted", "done", "parked", "failed")


def num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


# ---- the session registry ----

class Registry:
    """The registry read once per call. `missing` names a directory that cannot be read at all."""

    def __init__(self, path, now):
        self.path, self.now = path, now
        self.missing = None
        try:
            self.names = set(os.listdir(path))
        except OSError as e:
            self.names = set()
            self.missing = "the session registry %s could not be read (%s)" % (path, e.strerror or e)

    def session(self, sid):
        """('open' | 'gone' | 'unknown', why) for one session id."""
        if self.missing:
            return "unknown", self.missing
        if not SESSION_ID.match(sid or ""):
            return "unknown", "the claim names no session id this reader accepts"
        name = sid + ".json"
        if name not in self.names:
            return "gone", "session %s is not in the session registry" % sid
        try:
            with open(os.path.join(self.path, name)) as fh:
                r = json.load(fh)
        except Exception:
            return "unknown", "session %s has a registry record that cannot be read" % sid
        if not isinstance(r, dict) or not num(r.get("lastSeen")) or not (r.get("closedAt") is None or num(r.get("closedAt"))):
            return "unknown", "session %s has a registry record that cannot be read" % sid
        if r.get("closedAt") is not None:
            return "gone", "session %s has ended" % sid
        if self.now - r["lastSeen"] > DEAD_MS:
            return "gone", "session %s has been silent for %d minutes" % (sid, (self.now - r["lastSeen"]) // 60_000)
        return "open", ""

    def open_records(self, self_id):
        """Every open session's record but this one's, and the names of records that may be live and cannot be read."""
        out, damaged = [], []
        if self.missing:
            return out, [self.missing]
        for name in sorted(self.names):
            if not name.endswith(".json") or name.startswith("."):
                continue
            path = os.path.join(self.path, name)
            try:
                with open(path) as fh:
                    r = json.load(fh)
                if not isinstance(r, dict) or not num(r.get("lastSeen")):
                    raise ValueError("shape")
            except Exception:
                # A damaged record changed in the last five minutes may be a live session's (the
                # registry's own prune keeps such a record for the same reason); an older one is not.
                try:
                    if self.now - os.stat(path).st_mtime * 1000 <= DEAD_MS:
                        damaged.append(name)
                except OSError:
                    pass
                continue
            if r.get("sessionId") == self_id or r.get("closedAt") is not None or self.now - r["lastSeen"] > DEAD_MS:
                continue
            out.append(r)
        return out, damaged


# ---- one issue's claim ----

def entries(issue_dir):
    """The numbered entries, oldest first, as (number, entry or None when it cannot be read, mtime ms)."""
    try:
        names = os.listdir(issue_dir)
    except FileNotFoundError:
        return []
    out = []
    for name in names:
        if not name.isdigit():
            continue
        path = os.path.join(issue_dir, name)
        try:
            mtime = os.stat(path).st_mtime * 1000
        except OSError:
            continue
        try:
            with open(path) as fh:
                e = json.load(fh)
            if not isinstance(e, dict):
                e = None
        except Exception:
            e = None
        out.append((int(name), e, mtime))
    out.sort(key=lambda x: x[0])
    return out


def count_attempts(es):
    """Claims that could have done work: a claim ended `unstarted` (its worktree could not be made
    just now, so nothing ran) is no attempt, or two network drops would park an untouched issue."""
    n = 0
    for i, (_, e, _) in enumerate(es):
        if not e or e.get("kind") != "claim":
            continue
        after = es[i + 1][1] if i + 1 < len(es) else None
        if after and after.get("kind") == "unstarted":
            continue
        n += 1
    return n


def claim_state(issue_dir, registry, self_id):
    """One line: STATE NEXT ATTEMPTS then a reason.

    STATE is free (take it as entry NEXT), mine (this session holds it), held (another live
    session holds it), ended (done, parked or failed tonight) or unknown (it cannot be judged, so
    it is left alone). ATTEMPTS counts the claims the issue has had tonight (L27): a claim taken
    over from a session that died is an attempt of its own.
    """
    es = entries(issue_dir)
    attempts = count_attempts(es)
    nxt = es[-1][0] + 1 if es else 1
    if not es:
        return "free", nxt, attempts, "no claim yet"
    n, last, mtime = es[-1]
    if last is None:
        return "unknown", nxt, attempts, "claim entry %d cannot be read" % n
    kind = last.get("kind")
    if kind in ("free", "unstarted"):
        return "free", nxt, attempts, "released" if kind == "free" else "given back unstarted"
    if kind in ENDS:
        return "ended", nxt, attempts, kind + ((": " + str(last["why"])) if last.get("why") else "")
    if kind != "claim":
        return "unknown", nxt, attempts, "claim entry %d is of a kind this reader does not know" % n
    sid = last.get("session")
    # The start time is the entry's own; one written without it falls back to when the entry was made (L409).
    since = last["at"] if num(last.get("at")) else mtime
    if sid == self_id:
        return "mine", nxt, attempts, "claimed since %d" % since
    st, why = registry.session(sid if isinstance(sid, str) else "")
    if st == "gone":
        return "free", nxt, attempts, "taken over: " + why
    if st == "unknown":
        return "unknown", nxt, attempts, why
    return "held", nxt, attempts, "session %s holds it since %d" % (sid, since)


# ---- the queue ----

def digits(text):
    """The issue numbers a branch name can mean: every run of digits, once dates (2026-10-07,
    20261007) and versions (v10, 1.2.3) are taken out, since those name no issue. What is left
    still errs toward leaving an issue out, the harmless side, and the skip line names the branch."""
    t = text or ""
    t = re.sub(r"(?<![0-9])\d{4}[-_.]?\d{2}[-_.]?\d{2}(?![0-9])", " ", t)
    t = re.sub(r"(?i)(?<![a-z0-9])v\d+(?:\.\d+)*", " ", t)
    t = re.sub(r"\d+(?:\.\d+)+", " ", t)
    return set(re.findall(r"\d+", t))


def mentions(text, n):
    return re.search(r"#%d(?![0-9])" % n, text or "") is not None


def slug_of(url):
    m = re.search(r"github\.com[:/]+([^/\s]+)/([^/\s]+?)(?:\.git)?/?$", (url or "").strip())
    if not m:
        return None
    s = ("%s/%s" % (m.group(1), m.group(2))).lower()
    # The slug becomes a folder name under the claims, so only GitHub's own characters, never `..`.
    if not re.match(r"^[a-z0-9_.-]+/[a-z0-9_.-]+$", s) or ".." in s.split("/"):
        return None
    return s


def git(cwd, *args):
    try:
        p = subprocess.run(["git", "-C", cwd] + list(args), capture_output=True, text=True, timeout=10)
    except Exception:
        return ""
    return p.stdout.strip() if p.returncode == 0 else ""


def named_by_session(r, slug):
    """The issue numbers an open session's record names in this repository: its branch, and the request it is on."""
    cwd = r.get("cwd")
    if not isinstance(cwd, str) or not os.path.isdir(cwd):
        return set()
    if slug_of(git(cwd, "config", "remote.origin.url")) != slug:
        return set()
    out = digits(git(cwd, "branch", "--show-current"))
    progress = (r.get("extra") or {}).get("progress") if isinstance(r.get("extra"), dict) else None
    request = progress.get("request") if isinstance(progress, dict) else None
    if isinstance(request, str):
        out |= set(re.findall(r"#(\d+)(?![0-9])", request))
    return out


def load_json(path, what):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception as e:
        refuse("the %s could not be read as JSON (%s)" % (what, e))


def load_lines(path):
    try:
        with open(path) as fh:
            return [l.strip() for l in fh if l.strip()]
    except FileNotFoundError:
        return []


def refuse(why):
    print("refused\t-\t%s" % why)
    sys.exit(3)


def queue(a):
    slug = a["repo"].lower()
    limit = int(a["limit"])
    reg = Registry(a["registry"], int(a["now"]))
    accounts = {x.lower() for x in load_lines(a["accounts"])}
    if not accounts:
        refuse("no GitHub account of Dan's could be read, so no issue can be judged as his")
    issues = load_json(a["issues"], "issue list")
    prs = load_json(a["prs"], "pull request list")
    if not isinstance(issues, list) or not isinstance(prs, list):
        refuse("the issue or pull request list is not a list")
    goal = [int(x) for x in a["goal"].split(",") if x] if a.get("goal") else []
    # Fetched with an explicit limit and held below it, so a full page never reads as every issue (L24).
    if not goal and len(issues) >= limit:
        refuse("%d open issues came back, the whole limit of %d, so the queue would be a partial one" % (len(issues), limit))
    if len(prs) >= limit:
        refuse("%d open pull requests came back, the whole limit of %d, so one naming an issue could be missed" % (len(prs), limit))
    if reg.missing:
        refuse(reg.missing)
    branches = load_lines(a["branches"])
    unanswered = {x.lower() for x in load_lines(a["unanswered"])}
    claims = a["claims"]
    others, damaged = reg.open_records(a["self"])
    if damaged:
        refuse("the session registry has records changed in the last five minutes that cannot be read (%s), so a live session's issue could be missed" % ", ".join(damaged))
    by_session = set()
    for r in others:
        by_session |= named_by_session(r, slug)

    rows, skips = [], []
    for i in issues:
        n = i.get("number")
        if not isinstance(n, int):
            continue
        labels = {l.get("name", "") for l in i.get("labels") or [] if isinstance(l, dict)}
        author = ((i.get("author") or {}).get("login") or "").lower()
        title = (i.get("title") or "").replace("\t", " ").replace("\n", " ")
        prio = next((p for p in PRIORITIES if p in labels), None)

        def skip(why):
            skips.append((n, why))

        if goal and n not in goal:
            continue
        if (i.get("state") or "OPEN").upper() != "OPEN":
            skip("closed")
            continue
        if not goal and prio is None:
            skip("not p0 to p3")
            continue
        if author not in accounts:
            # Only Dan's issues are worked: another person's issue is data, never instructions (L28).
            skip("opened by %s, not one of Dan's accounts" % (author or "an unknown author"))
            continue
        if "needs-dan" in labels:
            skip("needs Dan")
            continue
        if "%s#%d" % (slug, n) in unanswered:
            skip("a before bed question about it went unanswered")
            continue
        st, _, attempts, why = claim_state(os.path.join(claims, str(n)), reg, a["self"])
        claimed_tonight = bool(entries(os.path.join(claims, str(n))))
        if st in ("held", "ended", "unknown"):
            skip("claim %s: %s" % (st, why))
            continue
        # Tonight's own claim decides for an issue it has touched: a branch or pull request from
        # a session that died is the work to carry on, never a reason to leave it.
        if not claimed_tonight:
            pr = next((p for p in prs if mentions(p.get("title"), n) or mentions(p.get("body"), n) or str(n) in digits(p.get("headRefName"))), None)
            if pr is not None:
                skip("open pull request #%s names it" % pr.get("number"))
                continue
            br = next((b for b in branches if str(n) in digits(b)), None)
            if br is not None:
                skip("branch %s names it" % br)
                continue
        if str(n) in by_session:
            skip("an open session is working on it")
            continue
        rank = goal.index(n) if goal else PRIORITIES.index(prio)
        rows.append((rank, n, (prio or "-").replace("priority-", ""), attempts, st, title))
    if goal:
        found = {i.get("number") for i in issues}
        for n in goal:
            if n not in found:
                skips.append((n, "the goal names it but it could not be found"))
    rows.sort(key=lambda r: (r[0], r[1]))
    for _, n, prio, attempts, st, title in rows:
        print("next\t%d\t%s\tattempts=%d\t%s\t%s" % (n, prio, attempts, st, title))
    for n, why in sorted(skips):
        print("skip\t%d\t%s" % (n, why))


def all_claims(claims_dir):
    """Every issue claimed tonight, one JSON line each, for the report (phase 4, #835)."""
    try:
        repos = sorted(os.listdir(claims_dir))
    except FileNotFoundError:
        return
    for repo in repos:
        rdir = os.path.join(claims_dir, repo)
        if not os.path.isdir(rdir):
            continue
        for issue in sorted((x for x in os.listdir(rdir) if x.isdigit()), key=int):
            es = entries(os.path.join(rdir, issue))
            if not es:
                continue
            print(json.dumps({
                "repo": repo.replace("__", "/", 1),
                "issue": int(issue),
                "attempts": count_attempts(es),
                "entries": [e if e is not None else {"kind": "unreadable", "n": n} for n, e, _ in es],
            }))


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "state" and len(argv) == 6:
        st, nxt, attempts, why = claim_state(argv[2], Registry(argv[4], int(argv[5])), argv[3])
        print("%s\t%d\t%d\t%s" % (st, nxt, attempts, why))
        return 0
    if cmd == "queue":
        a = {}
        for kv in argv[2:]:
            k, _, v = kv.partition("=")
            a[k] = v
        for need in ("repo", "limit", "issues", "prs", "branches", "accounts", "unanswered", "claims", "registry", "now", "self"):
            if need not in a:
                refuse("sleep-queue.py queue was not given %s" % need)
        queue(a)
        return 0
    if cmd == "entry" and len(argv) in (5, 6):
        # One claim entry, built here so a reason with quotes or newlines is still one JSON object.
        e = {"kind": argv[2], "session": argv[3], "at": int(argv[4])}
        if len(argv) == 6 and argv[5]:
            e["why"] = argv[5]
        print(json.dumps(e))
        return 0
    if cmd == "slug" and len(argv) == 3:
        # The one reading of an origin URL, for the shell too, so both sides agree on which count.
        s = slug_of(argv[2])
        if not s:
            return 1
        print(s)
        return 0
    if cmd == "claims" and len(argv) == 3:
        all_claims(argv[2])
        return 0
    print("usage: sleep-queue.py state ISSUE_DIR SELF REGISTRY NOW | queue key=value... | entry KIND SESSION AT [WHY] | claims CLAIMS_DIR", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
