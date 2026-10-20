#!/usr/bin/env python3
"""design-score-reopen.py: reopen a "Match the settled design" issue, or its milestone, that was
closed below 100% where the close gate could not see it (claude-config#1386).

design-score-gate.sh refuses such a close when it is made from here: gh, a REST call, gh pr merge,
merge-when-ready.sh. Two closes never pass through it: one on GitHub's website, and a closing
keyword in a commit pushed straight to the default branch. So this looks afterwards. For every repo
the repo-digest lists (repos.json and repos-weekly.json, read live, never copied), it reads the Match
issues and the milestones closed since its last complete run of that repo, and judges each with the
GATE'S OWN JUDGE (design-score-gate.py's Gate, loaded, never copied), so the two can never disagree
about what 100% means, about a stale score, or about an exception Dan approved: an exception lives
in the design file, the score skips what it names, and a score taken with it reads 100%, so a close
made on purpose under one is left alone like any other close at 100%.

ON THE CODE IT WAS CLOSED ON. A close by a commit is judged on that commit; any other close on the
head of the default branch at the moment it was closed. Not today's head: main moving on after the
close must not turn a close that was at 100% into one that was not.

WHAT IT DOES TO A CLOSE BELOW 100%: one comment on the Match issue, carrying a mark naming that close
(what was closed, and when), then the reopen. In that order, so a run that dies between the two
leaves the mark and the next run only reopens; and the mark is read before commenting, so running
twice, or on both Macs, comments once per close. A close made again after the reopen is a new close,
with its own comment. A milestone has no comments, so its comment goes on its Match issue. Unmeasured
is never 100%: no score, a score that cannot be read, or a score for other code all reopen.

FAILS LOUD. A repository, a list or a score that cannot be read from GitHub is said, by name, and
that repository is not marked as checked, so the next run looks again over the same span. A reopen
GitHub refuses is said the same way. The reply is exit 1. Nothing is skipped in silence.

WHERE IT RUNS: design-score-reopen.sh, a SessionStart hook, starts it detached with --scheduled at
most once a day on each Mac, and says at the next session start what it did or could not do. With
--scheduled it holds a lock, logs every run (healthy ones too), leaves anything worth saying as a
result file for the hook, and records that it finished.

Usage: design-score-reopen.py [--dry-run] [--scheduled] [--state-dir D] [--repo owner/name ...]
  With no --repo, the repo-digest's lists. --dry-run reads everything and writes nothing anywhere.
"""
import importlib.util
import json
import os
import sys
import time
import traceback
from datetime import datetime, timedelta, timezone

sys.dont_write_bytecode = True
HOOKS = os.path.dirname(os.path.abspath(__file__))


def _load_gate():
    spec = importlib.util.spec_from_file_location("design_score_gate", os.path.join(HOOKS, "design-score-gate.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gate_mod = _load_gate()
sg = gate_mod.sg
Refuse = gate_mod.Refuse

DIGEST_REPO = "dwright-pennie/repo-digest"
DIGEST_LISTS = ("repos.json", "repos-weekly.json")
# The first span a repository is read over. Match issues began with claude-config#1364 (create-
# milestone.sh first filed one on 2026-10-19), so no close before this can be one: a fixed date, not
# a window that slides past a close nobody looked at (L665).
FLOOR = "2026-10-01T00:00:00Z"
# Each later run reads from ten minutes before the previous one STARTED, so a close made while a run
# was reading is read again by the next, never fallen between two.
OVERLAP = timedelta(minutes=10)
MARK = "design-score-reopen"
LOCK_STALE = 6 * 3600


def iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse(ts):
    return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def eastern(ts):
    """A GitHub time as Dan reads times: Eastern."""
    try:
        from zoneinfo import ZoneInfo
        local = parse(ts).astimezone(ZoneInfo("America/New_York"))
        return local.strftime("%Y-%m-%d %I:%M %p ET").replace(" 0", " ")
    except Exception:  # noqa: BLE001  no tz database: the UTC time, labelled as UTC rather than guessed
        return ts.replace("T", " ").replace("Z", " UTC")


def reopen_mark(kind, number, closed_at):
    return "<!-- %s %s -->" % (MARK, json.dumps({"kind": kind, "number": number, "closed_at": closed_at},
                                                  sort_keys=True))


class Checker:
    def __init__(self, github, dry_run=False):
        self.gh = github
        self.gate = gate_mod.Gate(github)
        self.dry = dry_run
        self.said = []          # what Dan is told: every reopen and every failure
        self.failed = False
        self.counts = {"repos": 0, "issues": 0, "milestones": 0, "reopened": 0}

    def say(self, line, failure=False):
        self.said.append(line)
        self.failed = self.failed or failure

    # --- what to read -------------------------------------------------------------------------
    def digest_repos(self):
        repos = []
        for name in DIGEST_LISTS:
            try:
                listed = json.loads(self.gh.raw(name, DIGEST_REPO).decode("utf-8", errors="replace"))["repos"]
                repos += ["%s/%s" % (r["owner"], r["name"]) for r in listed]
            except (sg.GitHubError, ValueError, KeyError, TypeError) as err:
                # A run over half the repositories reads like a run over all of them, so none is run.
                self.say("Could not read %s from %s (%s), so no repository was checked for a Match the settled "
                         "design issue closed below 100%%. The next run tries again." % (name, DIGEST_REPO, err),
                         failure=True)
                return None
        seen, out = set(), []
        for r in repos:
            if r.lower() not in seen:
                seen.add(r.lower())
                out.append(r)
        return out

    def head_at(self, repo, when):
        branch = self.gate.default_head(repo)
        found = self.gh.api("repos/%s/commits?sha=%s&until=%s&per_page=1" % (repo, branch, when), repo)
        if not isinstance(found, list) or not found or not found[0].get("sha"):
            raise sg.GitHubError("%s had no commit on %s at %s" % (repo, branch, when))
        return found[0]["sha"], "the head of %s when it was closed" % branch

    def closing(self, repo, number, closed_at):
        """(the commit to judge, how it is described, who closed it)."""
        events = self.gh.api("repos/%s/issues/%d/events?per_page=100" % (repo, number), repo, paginate=True)
        closes = [e for e in events if e.get("event") == "closed"]
        last = closes[-1] if closes else {}
        closer = (last.get("actor") or {}).get("login") or "someone"
        if last.get("commit_id"):
            return last["commit_id"], "the commit that closed it", closer
        ref, why = self.head_at(repo, closed_at)
        return ref, why, closer

    # --- one repository -----------------------------------------------------------------------
    def check_repo(self, repo, since):
        """True when every close since `since` was judged and anything below 100% was reopened."""
        try:
            issues = self.gh.api("repos/%s/issues?state=closed&since=%s&per_page=100" % (repo, since), repo,
                                 paginate=True)
            milestones = self.gh.api("repos/%s/milestones?state=closed&per_page=100" % repo, repo, paginate=True)
        except sg.GitHubError as err:
            self.say("Could not read %s (%s), so its closed Match the settled design issues and milestones were "
                     "not checked. The next run tries again." % (repo, err), failure=True)
            return False
        self.counts["repos"] += 1
        complete = True
        for issue in issues:
            if issue.get("pull_request"):
                continue
            try:
                is_match = sg.is_match_issue(issue)[0]
            except sg.GitHubError:
                # A mark that cannot be read still marks a Match issue: it goes to the judge, whose
                # failure to read it is then said by name, never skipped as "not a Match issue".
                is_match = True
            if is_match:
                complete = self.handle_issue(repo, issue) and complete
        for ms in milestones:
            if (ms.get("closed_at") or "") >= since:
                complete = self.handle_milestone(repo, ms) and complete
        return complete

    def handle_issue(self, repo, issue):
        n, closed_at = issue["number"], issue.get("closed_at") or ""
        label = "%s#%d (%s)" % (repo, n, issue.get("title", ""))
        self.counts["issues"] += 1
        try:
            ref, why, closer = self.closing(repo, n, closed_at)
            self.gate.judge_issue(repo, n, ref, why)
            return True
        except Refuse as r:
            reason = str(r)
        except sg.GitHubError as err:
            self.say("Could not check %s, closed %s: %s. It was left closed; the next run tries again."
                     % (label, eastern(closed_at), err), failure=True)
            return False
        head = ("**Reopened.** This issue was closed on %s by @%s while its design match score did not read 100%% "
                "on both halves for the code it was closed on (`%s`, %s)." % (eastern(closed_at), closer, ref[:7], why))
        return self.reopen(repo, n, label, "issue", n, closed_at, head, reason,
                           "repos/%s/issues/%d" % (repo, n))

    def handle_milestone(self, repo, ms):
        n, closed_at = ms["number"], ms.get("closed_at") or ""
        label = "milestone %d (%s) in %s" % (n, ms.get("title", ""), repo)
        self.counts["milestones"] += 1
        try:
            ref, why = self.head_at(repo, closed_at)
            self.gate.judge_milestone(repo, n, why, ref=ref)
            return True
        except Refuse as r:
            reason = str(r)
        except sg.GitHubError as err:
            self.say("Could not check %s, closed %s: %s. It was left closed; the next run tries again."
                     % (label, eastern(closed_at), err), failure=True)
            return False
        try:
            issues = self.gh.api("repos/%s/issues?milestone=%d&state=all&per_page=100" % (repo, n), repo, paginate=True)
        except sg.GitHubError as err:
            self.say("Could not read the issues of %s to say why it is reopened (%s); it was left closed. The next "
                     "run tries again." % (label, err), failure=True)
            return False
        targets = []
        for i in issues:
            try:
                if not i.get("pull_request") and sg.is_match_issue(i)[0]:
                    targets.append(i["number"])
            except sg.GitHubError:
                targets.append(i["number"])
        head = ("**Reopened the milestone %s.** It was closed on %s while this Match the settled design issue's "
                "design match score did not read 100%% on both halves for the code it was closed on (`%s`, %s)."
                % (ms.get("title", ""), eastern(closed_at), ref[:7], why))
        return self.reopen(repo, targets, label, "milestone", n, closed_at, head, reason,
                           "repos/%s/milestones/%d" % (repo, n))

    # --- the one outward action ---------------------------------------------------------------
    def reopen(self, repo, on, label, kind, number, closed_at, head, reason, reopened):
        """Comments on `on` (a Match issue, or a list of them), then sets the issue or milestone at
        the endpoint `reopened` open."""
        targets = on if isinstance(on, list) else [on]
        # The judge's first line, which names the issue and ends in the way to 100%: both are said
        # once already, by this line's start and by the comment.
        why_line = reason.replace(gate_mod.HOW, "").strip().split("\n")[0].strip()
        if why_line.startswith(label):
            why_line = why_line[len(label):].lstrip(" :")
        if self.dry:
            self.say("Would reopen %s, closed %s: %s" % (label, eastern(closed_at), why_line))
            return True
        mark = reopen_mark(kind, number, closed_at)
        body = "\n".join([mark, head, "",
                          "A close on GitHub's website, or by a closing keyword in a commit pushed straight to the "
                          "default branch, is not seen by the design score close gate, so this check undoes it. "
                          "Unmeasured is never 100%.", "",
                          "What was read:", "", "```text", reason.replace(gate_mod.HOW, "").strip(), "```", "",
                          "To close it: " + gate_mod.HOW, "",
                          "(claude-config#1386)"])
        try:
            for t in targets:
                comments = self.gh.api("repos/%s/issues/%d/comments?per_page=100" % (repo, t), repo, paginate=True)
                if not any(mark in (c.get("body") or "") for c in comments):
                    self.gh.write("POST", "repos/%s/issues/%d/comments" % (repo, t), repo, body=body)
            self.gh.write("PATCH", reopened, repo, state="open")
        except sg.GitHubError as err:
            self.say("Could not reopen %s, closed %s below 100%%: %s. The next run tries again." % (
                label, eastern(closed_at), err), failure=True)
            return False
        self.counts["reopened"] += 1
        where = "" if targets else " (it holds no Match issue, so no comment could say why)"
        self.say("Reopened %s, closed %s below 100%%%s: %s" % (label, eastern(closed_at), where, why_line))
        return True


# --- the run ----------------------------------------------------------------------------------
def _since_path(state, repo):
    return os.path.join(state, "since", repo.replace("/", "__"))


def _read_since(state, repo):
    try:
        with open(_since_path(state, repo)) as fh:
            value = fh.read().strip()
        parse(value)
        return value
    except (OSError, ValueError):
        return FLOOR


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as fh:
        fh.write(text)
    os.replace(tmp, path)


def _take_lock(state):
    lock = os.path.join(state, "lock")
    try:
        os.mkdir(lock)
        return lock
    except FileExistsError:
        try:
            age = time.time() - os.path.getmtime(lock)
        except OSError:
            age = 0
        if age > LOCK_STALE:      # a run killed part way leaves its lock; six hours is no live run
            try:
                os.rmdir(lock)
                os.mkdir(lock)
                return lock
            except OSError:
                return None
        return None


def run(argv, github, now, out):
    args = argv[1:]
    dry = "--dry-run" in args
    scheduled = "--scheduled" in args
    state = os.path.join(os.environ.get("CLAUDE_HOME") or os.path.expanduser("~/.claude"), "state", "design-score-reopen")
    repos = []
    i = 0
    while i < len(args):
        if args[i] == "--state-dir" and i + 1 < len(args):
            state = args[i + 1]
            i += 2
            continue
        if args[i] == "--repo" and i + 1 < len(args):
            repos.append(args[i + 1])
            i += 2
            continue
        i += 1
    started = parse(now)
    checker = Checker(github, dry_run=dry)
    if not repos:
        repos = checker.digest_repos() or []
    for repo in repos:
        since = _read_since(state, repo)
        if checker.check_repo(repo, since) and not dry:
            _write(_since_path(state, repo), iso(started - OVERLAP) + "\n")
    c = checker.counts
    summary = ("%s: checked %d of %d repositories, judged %d closed Match issues and %d closed milestones, "
               "reopened %d, %s." % (now, c["repos"], len(repos), c["issues"], c["milestones"], c["reopened"],
                                     "with failures" if checker.failed else "no failures"))
    for line in checker.said:
        out.write(line + "\n")
    out.write(("Dry run, nothing written. " if dry else "") + summary + "\n")
    if scheduled:
        with open(os.path.join(state, "log"), "a") as fh:
            for line in checker.said:
                fh.write("%s %s\n" % (now, line))
            fh.write(summary + "\n")
        if checker.said:
            _write(os.path.join(state, "result.%d.%d" % (int(time.time()), os.getpid())),
                   "\n".join(checker.said) + "\n")
    return 1 if checker.failed else 0


def main(argv, github=None, now=None, out=None):
    out = out or sys.stdout
    now = now or iso(datetime.now(timezone.utc))
    github = github or sg.GitHub()
    if "--scheduled" not in argv:
        return run(argv, github, now, out)
    args = argv[1:]
    state = args[args.index("--state-dir") + 1] if "--state-dir" in args else os.path.join(
        os.environ.get("CLAUDE_HOME") or os.path.expanduser("~/.claude"), "state", "design-score-reopen")
    os.makedirs(state, exist_ok=True)
    lock = _take_lock(state)
    if lock is None:
        with open(os.path.join(state, "log"), "a") as fh:
            fh.write("%s: another run holds %s, so this one checked nothing.\n" % (now, os.path.join(state, "lock")))
        return 0
    try:
        return run(argv, github, now, out)
    except Exception:  # noqa: BLE001  a crash is said where Dan sees it, never only in a log
        said = "The check for Match the settled design issues closed below 100% crashed: %s" % (
            traceback.format_exc().strip().splitlines()[-1])
        _write(os.path.join(state, "result.%d.%d" % (int(time.time()), os.getpid())), said + "\n")
        with open(os.path.join(state, "log"), "a") as fh:
            fh.write("%s %s\n%s\n" % (now, said, traceback.format_exc()))
        return 1
    finally:
        _write(os.path.join(state, "last-finish"), "%d\n" % int(time.time()))
        try:
            os.rmdir(lock)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main(sys.argv))
