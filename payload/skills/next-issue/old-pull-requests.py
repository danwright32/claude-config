#!/usr/bin/env python3
"""List the signed in account's open pull requests older than 3 days, for /next-issue (claude-config#3614).

WHY. While a session is alive its pull request is looked after; once the session ends, nothing looks
at a pull request it left open, and /next-issue ranked open issues only. So before the ranked issues
the skill shows these rows, each with "Finish this" offered as a pick. A rule asking the reader to
remember old pull requests would be a hope (L27), so the listing and each row's state are this
script's, never a judgement made by hand.

WHAT IT READS. One `gh pr list --author @me --state open` call in the repository it is run in. It
takes no repository argument and passes none to gh, so it can never read another repository.

AGE. Decided from each pull request's own createdAt against --now (default: the clock now), so no
test depends on the calendar day. Older than 3 days means more than exactly 3 days.

STATE. Derived from the fields gh returns, in this order, joined by commas: draft (isDraft),
conflicting (mergeable CONFLICTING), not yet checked for conflicts (mergeable UNKNOWN: GitHub works
mergeability out lazily, and measured on 2026-11-26 in claude-config the first read gave UNKNOWN on
37 of 42 open pull requests and a read about a minute later on none, so UNKNOWN is said, never read as no
conflict), checks red (a completed check run whose conclusion is a failure, or a commit status in
failure or error), changes requested, then approved and waiting (approved with nothing above in its
way) or approved. With none of these it is waiting.

LIMIT. --limit (default 200) is passed to gh. gh lists newest first, so a list cut at its limit
drops the OLDEST pull requests, the ones this exists to show; a list as long as its limit is
refused with exit 3 rather than shown partly.

Usage:  old-pull-requests.py [--now <ISO 8601 time>] [--limit 200]
        (OLD_PRS_GH names the gh to run and OLD_PRS_GH_TIMEOUT its timeout in seconds, for tests.)

Prints one `OLD PR #<n> [<age>, <state>] <title>` row per old pull request, oldest first, then one
`OLD PRS` line. With none old (or none open) it prints nothing and exits 0.
Exit 0 listed (including none), 2 the pull requests could not be listed or read (said on stderr,
with nothing on stdout), 3 the list reached its limit.
"""
import json
import os
import signal
import subprocess
import sys
from datetime import datetime, timedelta, timezone

DAYS = 3
DEFAULT_LIMIT = 200
FIELDS = "number,title,url,createdAt,isDraft,mergeable,reviewDecision,statusCheckRollup"
RED_CONCLUSIONS = {"FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"}
RED_STATES = {"FAILURE", "ERROR"}


def fail(code, message):
    print(message, file=sys.stderr)
    sys.exit(code)


def unlisted(why):
    fail(2, f"UNLISTED could not list this repository's open pull requests: {why}. "
            "Say so; this is not the same as having none.")


def parse_time(text):
    """An ISO 8601 time as gh writes it (2026-11-23T06:53:13Z), as an aware datetime, or None."""
    if not isinstance(text, str):
        return None
    try:
        when = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return when if when.tzinfo else None


def parse_args(argv):
    opts = {"now": None, "limit": DEFAULT_LIMIT}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("--now", "--limit") and i + 1 < len(argv):
            value = argv[i + 1]
            if arg == "--now":
                opts["now"] = parse_time(value)
                if opts["now"] is None:
                    fail(2, f"--now takes a time with its zone, such as 2026-11-26T07:00:00Z, got {value!r}")
            else:
                try:
                    opts["limit"] = int(value)
                except ValueError:
                    fail(2, f"--limit takes a number, got {value!r}")
                if opts["limit"] < 1:
                    fail(2, "--limit must be at least 1")
            i += 2
            continue
        fail(2, f"unknown argument {arg!r}")
    if opts["now"] is None:
        opts["now"] = datetime.now(timezone.utc)
    return opts


def run_gh(limit):
    """The one gh call, as (stdout bytes) or exit 2 naming why it could not be made."""
    gh = os.environ.get("OLD_PRS_GH") or "gh"
    try:
        timeout = float(os.environ.get("OLD_PRS_GH_TIMEOUT") or 60)
    except ValueError:
        timeout = 60.0
    args = [gh, "pr", "list", "--author", "@me", "--state", "open", "--limit", str(limit), "--json", FIELDS]
    try:
        # Its own process group, so a timeout stops gh and anything it started (L321).
        proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except OSError as e:
        unlisted(f"could not run gh ({e})")
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            proc.kill()
        proc.communicate()
        secs = f"{timeout:g} second" + ("" if timeout == 1 else "s")
        unlisted(f"gh did not answer within {secs}")
    if proc.returncode != 0:
        said = err.decode("utf-8", errors="replace").strip() or "it printed nothing"
        unlisted(f"gh exited {proc.returncode}: {said}")
    return out


def read_rows(raw):
    text = raw.decode("utf-8", errors="replace")
    if not text.strip():
        unlisted("gh exited 0 with an empty answer")
    try:
        data = json.loads(text)
    except ValueError:
        unlisted("gh answered something that is not JSON")
    if not isinstance(data, list):
        unlisted("gh's answer is not a list of pull requests")
    rows = []
    for r in data:
        if not isinstance(r, dict) or not isinstance(r.get("number"), int):
            unlisted("gh's answer holds an entry with no pull request number")
        n = r["number"]
        created = parse_time(r.get("createdAt"))
        if created is None:
            unlisted(f"pull request #{n} has no readable createdAt, so its age is unknown")
        checks = r.get("statusCheckRollup")
        if checks is None:
            checks = []
        if not isinstance(checks, list) or not all(isinstance(c, dict) for c in checks):
            unlisted(f"pull request #{n} has a statusCheckRollup that is not a list of checks")
        for field, kind in (("isDraft", bool), ("mergeable", str), ("reviewDecision", str)):
            if not isinstance(r.get(field), kind):
                unlisted(f"pull request #{n} has no {field} as gh gives it")
        rows.append({
            "number": n,
            "title": str(r.get("title") or ""),
            "created": created,
            "draft": r["isDraft"],
            "mergeable": r["mergeable"],
            "review": r["reviewDecision"],
            "checks": checks,
        })
    return rows


def red(checks):
    for c in checks:
        if c.get("__typename") == "StatusContext":
            if str(c.get("state") or "").upper() in RED_STATES:
                return True
        elif str(c.get("status") or "").upper() == "COMPLETED" and str(c.get("conclusion") or "").upper() in RED_CONCLUSIONS:
            return True
    return False


def state(row):
    says = []
    if row["draft"]:
        says.append("draft")
    if row["mergeable"] == "CONFLICTING":
        says.append("conflicting")
    elif row["mergeable"] == "UNKNOWN":
        says.append("not yet checked for conflicts")
    if red(row["checks"]):
        says.append("checks red")
    if row["review"] == "CHANGES_REQUESTED":
        says.append("changes requested")
    if row["review"] == "APPROVED":
        blocked = row["draft"] or row["mergeable"] == "CONFLICTING" or red(row["checks"])
        says.append("approved" if blocked else "approved and waiting")
    return ", ".join(says) or "waiting"


def age(row, now):
    days = (now - row["created"]).days
    return f"{days} day" + ("" if days == 1 else "s")


def main(argv):
    opts = parse_args(argv)
    sys.stdout.reconfigure(errors="replace")
    rows = read_rows(run_gh(opts["limit"]))
    if len(rows) >= opts["limit"]:
        fail(3, f"TRUNCATED gh returned {len(rows)} open pull requests, its whole --limit, and it lists "
                f"newest first, so the oldest may be cut off; run again with a higher --limit")
    cutoff = opts["now"] - timedelta(days=DAYS)
    old = sorted((r for r in rows if r["created"] < cutoff), key=lambda r: (r["created"], r["number"]))
    if not old:
        return 0
    for r in old:
        print(f"OLD PR #{r['number']} [{age(r, opts['now'])}, {state(r)}] {r['title']}")
    print(f"OLD PRS {len(old)} of {len(rows)} open pull requests you opened here are older than {DAYS} days; "
          "offer Finish this for them, oldest first, ahead of the ranked issues")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
