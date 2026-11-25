#!/usr/bin/env python3
"""Scan what was posted to a repository in a window for work names, before it turns public.

claude-config#3582. The publish gate (work_names_publish_gate.py) judges text posted to a PUBLIC
repository and lets a private one through without reading its lists. So text posted while a
repository is private is judged by nothing, and it is still unjudged when the repository turns
public. On 2026-11-24 this repository was private for some hours, 83 texts were posted meanwhile,
and a scan written by hand that night found 8 lines naming a work organisation or repository. This
is that scan as one shipped command, which the gate's refusal of `gh repo edit --visibility public`
names as the thing to run first.

  python3 posted-text-scan.py <owner/name> --since <ISO time with its zone> [--budget SECONDS]

  --since   when the window opens, for example 2026-11-24T13:30:00-05:00 or 2026-11-24T18:30:00Z.
            A time with no zone is refused: read as UTC it would move the window by hours. The
            window runs from then to now.
  --budget  the seconds the whole run may take (default 100, which fits one command's default time
            limit). A run that spends it fails and says so; it never reports what it had by then.

IT READS ONLY. Every call is a GET through `gh api --paginate --slurp`, or a GraphQL query. It posts
nothing, edits nothing, and writes no file: the report is its standard output.

THE CONTROL GOES FIRST (L1, L248). Before anything is read from the repository, a name taken from
the lists at run time is planted on one line of a made up text, with a second text that holds no
name. The scan must report the first at exactly that line and stay quiet about the second, or the
run stops and says the scan cannot be trusted: a scan that cannot see a planted name proves nothing
by finding none, and one that reports every line proves nothing by finding some.

WHAT IT READS, each scanned by lib/work-names.py's own work_repo_names and scan_text, the lists and
the line scan the publish gate and --work-repos use (one reader, never a second copy of the rule):
  issues and pull requests updated in the window: title and body
  issue and pull request comments, review comments and commit comments updated in the window
  the review bodies and the commit messages of every pull request updated in the window, which
      reaches a commit whose branch was deleted after its merge
  commit messages dated in the window on every branch, and every branch's name
  every release's title, tag and notes, whenever published, since GitHub records no edit of one
  the repository's description, homepage and topics
  the earlier revisions GitHub still holds of each body above, and the earlier titles of each issue
      and pull request, through GraphQL (userContentEdits and RenamedTitleEvent). Measured
      2026-11-24: a revision's `diff` field is that revision's whole text, and the oldest is the
      text as first posted.

WHAT IT PRINTS. A name found is reported as `label:line: which kind of name`, in work-names.py's own
words, and never the name: a report is read in transcripts and pasted into issues. A branch is
labelled by its tip commit, never its name, for the same reason.

WHAT IT DOES NOT READ is printed at the end of every run, measured where it can be: a revision
deleted from an edit history has no text left (counted), a release and the repository's description
keep no history (measured 2026-11-24: GraphQL's Release type has no userContentEdits), and a commit
dated before the window but pushed inside it is found only through a pull request, because GitHub
does not say when a commit was pushed.

A FAILURE IS NEVER A SHORT CLEAN RESULT (L98). A call that fails, a page that is not the list asked
for, an item missing the field its text is in, a text GitHub left out of an edit history answer, a
history longer than one answer holds and a spent budget each end the run with exit 2.

Exit: 0 none found in what was read; 1 at least one line names one (each listed); 2 could not check.

Volume, measured on this repository on 2026-11-24. The calls are one per branch and two per pull
request updated in the window, run six at a time, and one per 50 texts for the edit history: a nine
hour window was 330 texts in 95 calls and 18 seconds, and a week was 3,106 texts in 531 calls and
204 seconds, so a window of more than a day or two needs a larger --budget.

Seam (tests): POSTED_TEXT_SCAN_LIB, a stand in for lib/work-names.py, honoured only under
HOOK_TESTS_RUNNING=1 as that library's own seams are, so no real run can be handed a blind scanner.
"""
import concurrent.futures
import datetime
import importlib.util
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.parse

# Loading lib/work-names.py by path must leave no bytecode beside it in the installed lib/ (#2080).
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ISSUE = "claude-config#3582"
USAGE = ("usage: posted-text-scan.py <owner/name> --since <ISO time with its zone, for example "
         "2026-11-24T13:30:00-05:00> [--budget SECONDS]")
SLUG = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+$")
NODE_ID = re.compile(r"^[A-Za-z0-9_=+/-]+$")
BUDGET_DEFAULT = 100
CALL_TIMEOUT = 60
WORKERS = 6
BATCH = 50
# GitHub lists at most this many of a pull request's commits (its REST documentation).
PR_COMMITS_CAP = 250

EDITS = "userContentEdits(first: 100) { pageInfo { hasNextPage } nodes { editedAt deletedAt diff } }"
RENAMES = ("timelineItems(itemTypes: [RENAMED_TITLE_EVENT], first: 100) { pageInfo { hasNextPage } nodes { "
           "... on RenamedTitleEvent { createdAt previousTitle } } }")
HISTORY = ("query { nodes(ids: %%s) { __typename id ... on Issue { %(e)s %(r)s } ... on PullRequest "
           "{ %(e)s %(r)s } ... on IssueComment { %(e)s } ... on PullRequestReviewComment { %(e)s } "
           "... on PullRequestReview { %(e)s } ... on CommitComment { %(e)s } } }"
           % {"e": EDITS, "r": RENAMES})


class Failed(Exception):
    """The scan could not be completed; the message says what could not be read."""


def load_library():
    """lib/work-names.py, the one reader of the lists and the one line scan."""
    path = os.path.join(HERE, "work-names.py")
    if os.environ.get("HOOK_TESTS_RUNNING") == "1" and os.environ.get("POSTED_TEXT_SCAN_LIB"):
        path = os.environ["POSTED_TEXT_SCAN_LIB"]
    try:
        spec = importlib.util.spec_from_file_location("work_names", path)
        lib = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(lib)
    except (OSError, ImportError, SyntaxError, AttributeError) as e:
        raise Failed("the work names library (%s) could not be loaded (%s)" % (path, e))
    return lib


def parse_time(raw):
    """-> an aware UTC datetime, or a str saying why the text is not a time with its zone."""
    text = raw.strip()
    if text[-1:] in ("Z", "z"):
        text = text[:-1] + "+00:00"
    try:
        when = datetime.datetime.fromisoformat(text)
    except ValueError:
        return "%r is not an ISO time" % raw
    if when.tzinfo is None:
        return ("%r has no time zone, and read as UTC it would move the window by hours: end it with "
                "Z for UTC, or with an offset such as -05:00 for Eastern standard time" % raw)
    return when.astimezone(datetime.timezone.utc)


def parse_since(raw):
    """-> an aware UTC datetime, or a str saying why the time cannot open a window. Only the window's
    own opening is refused for being still to come: a time GitHub gives is read as it is, since
    GitHub's clock and this Mac's need not agree to the second."""
    when = parse_time(raw)
    if not isinstance(when, str) and when > datetime.datetime.now(datetime.timezone.utc):
        return "%r is still to come, so nothing can have been posted since then" % raw
    return when


def eastern(when):
    """The time as Dan reads it. Where this machine holds no time zone data it says so, since a
    window shown in UTC alone is easy to read five hours out (L11)."""
    try:
        from zoneinfo import ZoneInfo
        local = when.astimezone(ZoneInfo("America/New_York"))
    except Exception:
        return " (Eastern time not shown: this machine has no time zone data)"
    hour = local.hour % 12 or 12
    return " (%d:%02d %s ET on %s)" % (hour, local.minute, "AM" if local.hour < 12 else "PM",
                                       local.strftime("%Y-%m-%d"))


class Reader:
    """gh, read only, under one time budget for the whole run."""

    def __init__(self, budget):
        self.budget = budget
        self.deadline = time.monotonic() + budget
        self.calls = 0
        self.lock = threading.Lock()

    def left(self):
        return self.deadline - time.monotonic()

    def spent(self, what):
        return Failed("the %g second budget was spent before %s could be read. Run it again with a "
                      "larger --budget (and a command time limit to match), or a later --since"
                      % (self.budget, what))

    def gh(self, args, what):
        left = self.left()
        if left <= 0:
            raise self.spent(what)
        with self.lock:
            self.calls += 1
        try:
            # Its own process group, so a call stopped at the deadline takes with it the real gh
            # the guard on PATH started (L321).
            p = subprocess.Popen(["gh"] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 stdin=subprocess.DEVNULL, start_new_session=True)
        except FileNotFoundError:
            raise Failed("gh is not on PATH, so %s could not be read" % what)
        try:
            out, err = p.communicate(timeout=min(CALL_TIMEOUT, left))
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                pass
            p.communicate()
            if self.left() <= 0:
                raise self.spent(what)
            raise Failed("gh did not answer for %s within %d seconds" % (what, CALL_TIMEOUT))
        if p.returncode != 0:
            raise Failed("gh could not read %s (exit %d): %s"
                         % (what, p.returncode, err.decode("utf-8", "replace").strip()[:300]))
        return out.decode("utf-8", "replace")

    def pages(self, path, of=list):
        """Every page of one GET. -> the items of every page (of=list), or the one object (of=dict)."""
        raw = self.gh(["api", "--paginate", "--slurp", path], path)
        try:
            got = json.loads(raw)
        except ValueError:
            raise Failed("%s answered with something that is not JSON (%d bytes), so it was cut short "
                         "or is no page at all" % (path, len(raw)))
        if not isinstance(got, list) or not got or not all(isinstance(p, of) for p in got):
            raise Failed("%s did not answer with the pages asked for" % path)
        if of is dict:
            return got[0]
        items = [item for page in got for item in page]
        if not all(isinstance(item, dict) for item in items):
            raise Failed("%s answered with a page whose entries are not records" % path)
        return items

    def query(self, text, what):
        raw = self.gh(["api", "graphql", "-f", "query=" + text], what)
        try:
            got = json.loads(raw)
        except ValueError:
            raise Failed("%s answered with something that is not JSON" % what)
        if not isinstance(got, dict) or got.get("errors") or not isinstance(got.get("data"), dict):
            raise Failed("%s answered with an error or no data" % what)
        return got["data"]


def field(item, key, kind, where, empty_ok=False):
    """item[key], which must be there and of the kind asked for: an item without the field its text
    is in is a page this cannot read, never an item with no text."""
    if key not in item:
        raise Failed("%s answered with an entry that has no %s field" % (where, key))
    value = item[key]
    if value is None and empty_ok:
        return ""
    if not isinstance(value, kind) or isinstance(value, bool):
        raise Failed("%s answered with an entry whose %s is not what GitHub documents" % (where, key))
    return value


class Gathered:
    def __init__(self):
        self.texts = []      # (label, text), in the order read
        self.counts = {}     # what was read, by kind
        self.history = []    # (node id, label, text as it stands, has a title)
        self.seen_commits = set()
        self.deleted = 0
        self.incomplete = []
        self.revisions = set()   # the labels of earlier revisions, whose remedy is a deletion
        self.old_titles = set()  # the labels of earlier titles, which no menu deletes

    def count(self, kind, n=1):
        self.counts[kind] = self.counts.get(kind, 0) + n

    def add(self, label, text):
        if text.strip():
            self.texts.append((label, text))
            return True
        return False

    def commit(self, entry, where):
        sha = field(entry, "sha", str, where)
        message = field(field(entry, "commit", dict, where), "message", str, where)
        if sha in self.seen_commits:
            return
        self.seen_commits.add(sha)
        self.count("commit message")
        self.add("commit %s message" % sha[:10], message)


def gather(reader, repo, since, got, progress):
    stamp = since.strftime("%Y-%m-%dT%H:%M:%SZ")
    base = "repos/%s" % repo

    info = reader.pages(base, of=dict)
    got.add("repository description", field(info, "description", str, base, empty_ok=True))
    got.add("repository homepage", field(info, "homepage", str, base, empty_ok=True))
    topics = info.get("topics") or []
    if not isinstance(topics, list):
        raise Failed("%s answered with topics that are not a list" % base)
    got.add("repository topics", "\n".join(str(t) for t in topics))

    path = "%s/issues?state=all&since=%s&per_page=100" % (base, stamp)
    pulls = []
    for it in reader.pages(path):
        number = field(it, "number", int, path)
        kind = "pull request" if "pull_request" in it else "issue"
        got.count(kind)
        if kind == "pull request":
            pulls.append(number)
        got.add("%s #%d title" % (kind, number), field(it, "title", str, path))
        body = field(it, "body", str, path, empty_ok=True)
        got.add("%s #%d body" % (kind, number), body)
        got.history.append((field(it, "node_id", str, path), "%s #%d" % (kind, number), body, True))

    for kind, sub in (("comment", "issues/comments"), ("review comment", "pulls/comments")):
        path = "%s/%s?since=%s&per_page=100" % (base, sub, stamp)
        for c in reader.pages(path):
            label = "%s %s" % (kind, field(c, "html_url", str, path))
            body = field(c, "body", str, path, empty_ok=True)
            got.count(kind)
            got.add(label, body)
            got.history.append((field(c, "node_id", str, path), label, body, False))

    # Commit comments have no since filter, so every one is listed and the window is applied here.
    path = "%s/comments?per_page=100" % base
    for c in reader.pages(path):
        updated = parse_time(field(c, "updated_at", str, path))
        if isinstance(updated, str):
            raise Failed("%s answered with a comment whose updated_at is not a time" % path)
        if updated < since:
            continue
        label = "commit comment %s" % field(c, "html_url", str, path)
        body = field(c, "body", str, path, empty_ok=True)
        got.count("commit comment")
        got.add(label, body)
        got.history.append((field(c, "node_id", str, path), label, body, False))

    path = "%s/releases?per_page=100" % base
    for r in reader.pages(path):
        rid = field(r, "id", int, path)
        got.count("release")
        got.add("release %d title" % rid, field(r, "name", str, path, empty_ok=True))
        got.add("release %d tag" % rid, field(r, "tag_name", str, path, empty_ok=True))
        got.add("release %d notes" % rid, field(r, "body", str, path, empty_ok=True))

    path = "%s/branches?per_page=100" % base
    branches = []
    for b in reader.pages(path):
        name = field(b, "name", str, path)
        tip = field(field(b, "commit", dict, path), "sha", str, path)
        branches.append(name)
        got.count("branch name")
        got.add("branch name (tip %s)" % tip[:10], name)

    # One page set per branch and two per pull request, six at a time, kept in the order asked.
    jobs = [("reviews", n, "%s/pulls/%d/reviews?per_page=100" % (base, n)) for n in pulls]
    jobs += [("pull commits", n, "%s/pulls/%d/commits?per_page=100" % (base, n)) for n in pulls]
    jobs += [("branch commits", b, "%s/commits?sha=%s&since=%s&per_page=100"
              % (base, urllib.parse.quote(b, safe=""), stamp)) for b in branches]
    progress("reading %d more page sets: 2 for each of %d pull requests updated in the window, 1 for "
             "each of %d branches" % (len(jobs), len(pulls), len(branches)))
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS)
    futures = []
    try:
        futures = [pool.submit(reader.pages, path) for _, _, path in jobs]
        answers = [f.result() for f in futures]
    finally:
        for f in futures:
            f.cancel()
        pool.shutdown(wait=True)
    for (what, which, path), items in zip(jobs, answers):
        if what == "reviews":
            for r in items:
                label = "review %s" % field(r, "html_url", str, path)
                body = field(r, "body", str, path, empty_ok=True)
                if got.add(label, body):
                    got.count("review")
                got.history.append((field(r, "node_id", str, path), label, body, False))
        else:
            if what == "pull commits" and len(items) >= PR_COMMITS_CAP:
                got.incomplete.append("pull request #%d has %d commits or more, and GitHub lists no more "
                                      "than that of a pull request's" % (which, PR_COMMITS_CAP))
            for c in items:
                got.commit(c, path)
    got.count("branch", len(branches))


def gather_history(reader, got, progress):
    """The earlier revisions and titles GitHub still holds of each body read, as texts of their own."""
    wanted = {}
    for node_id, label, body, titled in got.history:
        if not NODE_ID.match(node_id):
            raise Failed("%s has an id GitHub's GraphQL cannot be asked for" % label)
        wanted[node_id] = (label, body, titled)
    ids = list(wanted)
    if ids:
        progress("reading the edit history of %d texts" % len(ids))
    for start in range(0, len(ids), BATCH):
        batch = ids[start:start + BATCH]
        what = "the edit history of %d texts" % len(batch)
        nodes = reader.query(HISTORY % json.dumps(batch), what).get("nodes")
        if not isinstance(nodes, list):
            raise Failed("%s answered with no list of texts" % what)
        answered = {n.get("id"): n for n in nodes if isinstance(n, dict)}
        for node_id in batch:
            label, body, titled = wanted[node_id]
            node = answered.get(node_id)
            if node is None:
                raise Failed("GitHub left %s out of %s, so its earlier revisions could not be read"
                             % (label, what))
            body_label = "%s body" % label if titled else label
            edits = node.get("userContentEdits")
            if not isinstance(edits, dict) or not isinstance(edits.get("nodes"), list):
                raise Failed("GitHub gave no edit history for %s" % label)
            if cut_short(edits, "the edit history of %s" % label):
                got.incomplete.append("%s has more revisions than the 100 one answer holds" % body_label)
            for e in edits["nodes"]:
                if not isinstance(e, dict):
                    raise Failed("GitHub gave a revision of %s that is no record" % label)
                if e.get("deletedAt"):
                    got.deleted += 1
                    continue
                text = e.get("diff")
                if not isinstance(text, str):
                    got.incomplete.append("a revision of %s came back with no text and no deletion"
                                          % body_label)
                    continue
                if text.replace("\r\n", "\n") == body.replace("\r\n", "\n"):
                    continue
                got.count("earlier revision")
                revision = "%s, revision of %s" % (body_label, e.get("editedAt"))
                got.revisions.add(revision)
                got.add(revision, text)
            if not titled:
                continue
            renames = node.get("timelineItems")
            if not isinstance(renames, dict) or not isinstance(renames.get("nodes"), list):
                raise Failed("GitHub gave no title history for %s" % label)
            if cut_short(renames, "the title history of %s" % label):
                got.incomplete.append("%s had its title changed more times than the 100 one answer "
                                      "holds" % label)
            for r in renames["nodes"]:
                if not isinstance(r, dict) or not isinstance(r.get("previousTitle"), str):
                    raise Failed("GitHub gave a title change of %s with no earlier title" % label)
                got.count("earlier title")
                old_title = "%s title before %s" % (label, r.get("createdAt"))
                got.old_titles.add(old_title)
                got.add(old_title, r["previousTitle"])


def cut_short(connection, what):
    """True when GitHub says more of the list exists than it handed over. Read from pageInfo and
    never from totalCount: a timeline's totalCount counts every item whatever itemTypes asked for
    (measured 2026-11-24, when it called 14 pull requests' title histories cut short that were
    whole). An answer that does not say either way is one this cannot read."""
    info = connection.get("pageInfo")
    if not isinstance(info, dict) or not isinstance(info.get("hasNextPage"), bool):
        raise Failed("GitHub did not say whether %s was handed over whole" % what)
    return info["hasNextPage"]


def control(lib, matcher, odd):
    """Raises Failed unless the scan reports a planted name at its line and nothing else."""
    names = sorted(matcher.names) or list(odd)
    if not names:
        raise Failed("the lists hold no name that can be planted as a control, so the scan cannot be "
                     "trusted and nothing was read")
    with_name, without = [], []
    lib.scan_text("x0\nx1\nx2 %s x2\nx3" % names[0], "control", matcher, with_name, odd)
    lib.scan_text("x0\nx1\nx2 x2 x2\nx3", "control", matcher, without, odd)
    if len(with_name) != 1 or not with_name[0].startswith("control:3: "):
        raise Failed("CONTROL NOT REPORTED: a name from the lists, planted on line 3 of a made up text, "
                     "was not reported at that line (%d lines reported), so the scan cannot be trusted "
                     "and nothing was read" % len(with_name))
    if without:
        raise Failed("CONTROL REPORTED WITH NO NAME IN IT: a made up text holding no name had %d of its "
                     "lines reported, so the scan cannot be trusted and nothing was read" % len(without))


def plural(n, noun):
    special = {"branch": "branches", "earlier revision": "earlier revisions"}
    return "%d %s" % (n, noun if n == 1 else special.get(noun, noun + "s"))


def not_read(got):
    was = "was" if got.deleted == 1 else "were"
    return [
        "What this scan did not read:",
        "- %s deleted from an edit history, and GitHub hands over no text for a deleted revision. A "
        "comment, review, issue or release deleted before this ran is gone the same way."
        % (plural(got.deleted, "earlier revision") + " " + was),
        "- Earlier wording of a release or of the repository's description, which GitHub keeps no "
        "history of, and a commit that no branch and no pull request reaches any more (amended or "
        "force pushed away, or on a branch deleted with no pull request).",
        "- A commit dated before the window and pushed inside it, unless a pull request updated in "
        "the window holds it: commits are chosen by their own date, and GitHub does not say when one "
        "was pushed. An earlier --since takes them in.",
        "- Files and their history, discussions, the wiki, labels, milestones, projects, tags, gists "
        "and text inside an image or an attachment.",
    ]


def main(argv):
    repo, since_raw, budget_raw = None, None, None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--since", "--budget") and i + 1 < len(argv):
            if a == "--since":
                since_raw = argv[i + 1]
            else:
                budget_raw = argv[i + 1]
            i += 2
            continue
        if a.startswith("-") or repo is not None:
            sys.stderr.write("posted-text-scan: %r is not something this takes.\n%s\n" % (a, USAGE))
            return 2
        repo = a
        i += 1
    if repo is None or since_raw is None:
        sys.stderr.write("posted-text-scan: a repository and --since are both needed.\n%s\n" % USAGE)
        return 2
    if not SLUG.match(repo):
        sys.stderr.write("posted-text-scan: %r is not a repository written as owner/name.\n%s\n" % (repo, USAGE))
        return 2
    since = parse_since(since_raw)
    if isinstance(since, str):
        sys.stderr.write("posted-text-scan: --since %s.\n%s\n" % (since, USAGE))
        return 2
    budget = BUDGET_DEFAULT
    if budget_raw is not None:
        try:
            budget = float(budget_raw)
        except ValueError:
            budget = float("nan")
        if not 0 < budget < float("inf"):
            sys.stderr.write("posted-text-scan: --budget %r is not a number of seconds above zero.\n%s\n"
                             % (budget_raw, USAGE))
            return 2

    def progress(text):
        sys.stderr.write("posted-text-scan: %s...\n" % text)
        sys.stderr.flush()

    started = time.monotonic()
    reader = Reader(budget)
    got = Gathered()
    hits = []
    try:
        lib = load_library()
        try:
            matcher, _owners, odd = lib.work_repo_names(lib.GitHub(budget, "the posted text scan"))
        except (lib.CannotTell, ValueError) as e:
            raise Failed("%s" % e)
        control(lib, matcher, odd)
        print("posted-text-scan: %s, text posted or changed since %s%s"
              % (repo, since.strftime("%Y-%m-%dT%H:%M:%SZ"), eastern(since)))
        print("control: a name from the lists, planted in a made up text, was reported at its line, "
              "and a text with no name was not, so this scan can see one")
        sys.stdout.flush()
        gather(reader, repo, since, got, progress)
        gather_history(reader, got, progress)
        for label, text in got.texts:
            lib.scan_text(text, label, matcher, hits, odd)
    except Failed as e:
        sys.stderr.write("posted-text-scan: %s. A scan that could not read everything is not a clean "
                         "one (%s).\n" % (e, ISSUE))
        return 2

    order = ["issue", "pull request", "comment", "review comment", "review", "commit comment",
             "commit message", "branch", "branch name", "release", "earlier revision", "earlier title"]
    read = ", ".join(plural(got.counts.get(k, 0), k) for k in order if k != "branch name")
    print("read: %s, and the repository's description, in %d texts, %d calls and %d seconds"
          % (read, len(got.texts), reader.calls, time.monotonic() - started))
    for h in hits:
        print(h)
    for line in not_read(got):
        print(line)
    names = ("the work organisation names and domains and %d work repository and owner names from the "
             "work repository list, this Mac's dev update registry and the work MacBook's project list"
             % (len(matcher.names) + len(odd) + len(matcher.project_hashes)))
    if got.incomplete:
        sys.stdout.flush()
        sys.stderr.write("posted-text-scan: %d part%s could not be read in full: %s. A scan that could "
                         "not read everything is not a clean one (%s).\n"
                         % (len(got.incomplete), "" if len(got.incomplete) == 1 else "s",
                            "; ".join(got.incomplete), ISSUE))
        return 2
    if hits:
        # A hit is `label:line: kind`, so its label is what stands before the last two colons.
        labels = [h.rsplit(": ", 1)[0].rsplit(":", 1)[0] for h in hits]
        in_revisions = sum(1 for label in labels if label in got.revisions)
        in_titles = sum(1 for label in labels if label in got.old_titles)
        print("result: %d line%s name%s one (%d in text as it stands, %d in an earlier revision, %d in an "
              "earlier title), checked against %s. Rewrite text as it stands where it stands. Delete an "
              "earlier revision by hand on GitHub, from the edited menu above the text, since no API "
              "deletes one. An earlier title is kept in the timeline's record of the rename, which that "
              "menu does not reach. Then run this again: a revision deleted is counted, not read."
              % (len(hits), "" if len(hits) == 1 else "s", "s" if len(hits) == 1 else "",
                 len(hits) - in_revisions - in_titles, in_revisions, in_titles, names))
        return 1
    print("result: none found in the %d texts read, checked against %s. That is what was read, not "
          "the whole repository: see what this scan did not read." % (len(got.texts), names))
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main(sys.argv[1:]))
