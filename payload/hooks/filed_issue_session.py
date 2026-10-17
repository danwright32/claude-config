"""After `gh issue create`, read the filed issue's body from GitHub and add the session line it lacks.

The issue field gate (issue_field_gate.py) holds a create whose body does not name the session that
filed it (claude-config#536), but it runs BEFORE the command, so it can only read a body the command
shows: since claude-config#1246 a body file the same command writes from shown text is judged from the
command, and a body written any other way (by a script, by cat of another file, by a heredoc or
printf that expands a variable or a substitution) passes it unread, as a completeness gate that
fails open must (claude-config#1272). This runs AFTER the command, reads what GitHub holds, and
closes that gap however the body was written:

- Each issue address gh printed, on a line of its own, is read back (`gh issue view --json
  body,createdAt`). One not created in the last CREATED_WITHIN_S seconds is not one this command
  filed (a `gh issue view` beside the create printing an old issue's address), and is never edited.
- A body carrying the line is left alone, with nothing said.
- A body without it gets the line added at its end, after a blank line, through `gh issue edit
  --body-file -`, and is read back to confirm the line is there before anything says it was added.
  Both Dan (systemMessage) and Claude (additionalContext) are told the issue was edited on GitHub.
- A body that cannot be read, an edit GitHub refuses, or a create whose output names no issue at all
  (sent to a file, say) is said with the reason and the line to add, never as checked.

Outside a Claude session there is no line to require, and a command filing no issue, or one whose
create failed and printed no address, is left alone. Never blocks: the issue already exists.
"""

import importlib.util
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime

_HERE = os.environ.get("GATE_DIR") or os.path.dirname(os.path.abspath(__file__))


def _load(name):
    """A sibling module, by its explicit path, as issue_field_gate.py loads the scanner."""
    path = os.path.join(_HERE, name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError("cannot load %s" % path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gate = _load("issue_field_gate")
scan = gate.scan

# gh prints the new issue's address alone on a line.
ISSUE_URL = re.compile(r"^https://[^/\s]+/[^/\s]+/[^/\s]+/issues/(\d+)$")
# An issue this command filed was created moments ago; a create may wait on a slow GitHub, and the
# tool call's own clock is not in the payload, so the window is wide.
CREATED_WITHIN_S = 15 * 60
GH_TIMEOUT_S = 15
# The whole run's time, inside the 60 s settings.hooks.json gives this hook, so the hook is never
# killed partway, between an edit and its read back (lessons review). Each gh call gets what is left,
# at most GH_TIMEOUT_S; an issue there is too little left for is said as unchecked, and an edit is
# started only with room left to read it back: it may use all but READ_BACK_S of what is left, which
# is kept for the read back, since an edit that timed out may still have landed and only reading the
# body tells. FILED_ISSUE_BUDGET_S sets the budget for the tests.
BUDGET_S = 45
MIN_CALL_S = 3
READ_BACK_S = 3
# The override the issue field gate gives the session line (issue_field_gate.session_rule): a create
# that waives the line before it runs waives it here too.
OVERRIDE = "SKIP_SESSION_LINE_CHECK=1"


class Clock:
    """What is left of the run's budget."""

    def __init__(self, budget):
        self.end = time.monotonic() + budget

    def left(self):
        return max(0.0, self.end - time.monotonic())


def _seconds(name, default):
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


# The most an edit waits, at most GH_TIMEOUT_S; FILED_ISSUE_EDIT_WAIT_S shortens it for the test of an
# edit GitHub never answers, so that test waits a second rather than fifteen, whatever the load.
def _edit_wait():
    return min(GH_TIMEOUT_S, _seconds("FILED_ISSUE_EDIT_WAIT_S", GH_TIMEOUT_S))


def _budget():
    try:
        return float(os.environ.get("FILED_ISSUE_BUDGET_S", BUDGET_S))
    except ValueError:
        return BUDGET_S


class TimedOut(Exception):
    """gh did not answer in time, so what it did is not known."""


def _gh_issue(action, args, clock, stdin=None, keep=0.0, most=GH_TIMEOUT_S):
    """Run `gh issue <action> <args>`: (ok, stdout, the reason it failed), leaving `keep` seconds of
    the budget unused. It runs gh, and reads no command, so it is no reading of a subcommand
    (lib/word-position-scan.py). Raises TimedOut when gh does not answer in the time it is given."""
    wait = max(0.1, min(most, clock.left() - keep))
    try:
        r = subprocess.run(["gh", "issue", action] + args, input=stdin, capture_output=True, text=True, timeout=wait)
    except subprocess.TimeoutExpired:
        raise TimedOut("gh did not answer within %.0f seconds" % wait)
    except OSError as e:
        return False, "", "gh could not be run (%s)" % e
    if r.returncode != 0:
        why = (r.stderr.strip().splitlines() or ["exit %d" % r.returncode])[0]
        return False, r.stdout, why
    return True, r.stdout, ""


def _read(url, clock):
    """The issue's body and when it was created, or the reason it could not be read."""
    try:
        ok, out, why = _gh_issue("view", [url, "--json", "body,createdAt"], clock)
    except TimedOut as e:
        return None, None, str(e)
    if not ok:
        return None, None, why
    try:
        d = json.loads(out)
        created = datetime.strptime(d["createdAt"], "%Y-%m-%dT%H:%M:%SZ")
        epoch = (created - datetime(1970, 1, 1)).total_seconds()
        return d.get("body") or "", epoch, ""
    except (ValueError, KeyError, TypeError) as e:
        return None, None, "gh gave an answer that could not be read (%s)" % e


def check_issue(url, line, now, clock):
    """What to say about one issue the command printed, or None for nothing to say."""
    number = ISSUE_URL.match(url).group(1)
    if clock.left() < MIN_CALL_S:
        return ("there was no time left to read issue #%s (%s) back from GitHub, so whether it names this "
                "session was not checked. Check it ends with the line:\n%s" % (number, url, line)), None
    body, created, why = _read(url, clock)
    if body is None:
        return ("could not read issue #%s's body back from GitHub (%s), so whether it names this session was "
                "not checked. Check %s ends with the line:\n%s" % (number, why, url, line)), None
    if now - created > CREATED_WITHIN_S:
        return None, None
    if gate.SESSION_MARK in body:
        return None, None
    fixed = body.rstrip() + "\n\n" + line if body.strip() else line
    if clock.left() < MIN_CALL_S + READ_BACK_S:
        return ("issue #%s (%s) was filed without the line naming this session, and there was no time left "
                "to add it and read it back. Add it at the end of the body yourself:\n%s" % (number, url, line)), None
    timed_out = None
    try:
        ok, _, why = _gh_issue("edit", [url, "--body-file", "-"], clock, stdin=fixed, keep=READ_BACK_S, most=_edit_wait())
    except TimedOut as e:
        timed_out = str(e)
    else:
        if not ok:
            return ("issue #%s (%s) was filed without the line naming this session, and could not add it on "
                    "GitHub (%s). Add it at the end of the body yourself:\n%s" % (number, url, why, line)), None
    after, _, why = _read(url, clock)
    if timed_out and (after is None or line not in after):
        # It may still land, so a second add could put the line in twice.
        return ("issue #%s (%s) was filed without the line naming this session; the edit adding it did not "
                "answer in time (%s) and the body read back %s, so it may or may not land. Before adding it, "
                "read the body and add only if it does not end with:\n%s"
                % (number, url, timed_out, "failed (%s)" % why if after is None else "does not carry it yet", line)), None
    if after is None or line not in after:
        return ("issue #%s (%s) was filed without the line naming this session; the edit adding it was "
                "accepted, but reading the body back %s, so it may not be there. Check it ends with:\n%s"
                % (number, url, "failed (%s)" % why if after is None else "did not find it", line)), None
    return ("issue #%s (%s) was filed without the line naming this session, so this hook added the line "
            "to the end of its body on GitHub:\n%s" % (number, url, line)), (
            "Issue #%s was filed without the line saying which session filed it, so it was added to the "
            "issue's description on GitHub." % number)


def evaluate(data, line, now, clock):
    """(what Claude is told, what Dan is told), each a list of sentences."""
    command = (data.get("tool_input") or {}).get("command") or ""
    try:
        creates = scan.scan_creates(command)
    except scan.Unreadable:
        creates = []
    if not creates or any(OVERRIDE in envs for _, envs in creates):
        return [], []
    resp = data.get("tool_response")
    resp = resp if isinstance(resp, dict) else {}
    stdout = resp.get("stdout") if isinstance(resp.get("stdout"), str) else ""
    urls = []
    for raw in stdout.splitlines():
        u = raw.strip()
        if ISSUE_URL.match(u) and u not in urls:
            urls.append(u)
    if not urls:
        code = resp.get("exit_code")
        if code not in (None, 0, "0") or resp.get("interrupted") is True:
            return [], []
        return [("a gh issue create ran, but its output named no issue, so whether the filed issue names "
                 "this session could not be read back from GitHub. If an issue was filed, check its body "
                 "ends with the line:\n%s" % line)], []
    claude, dan = [], []
    for u in urls:
        said, told = check_issue(u, line, now, clock)
        if said:
            claude.append(said)
        if told:
            dan.append(told)
    return claude, dan


def main():
    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        return 0
    if not isinstance(data, dict):
        return 0
    command = (data.get("tool_input") or {}).get("command") or ""
    if "issue" not in command or "create" not in command:
        return 0
    line = gate.session_line()
    if not line:
        return 0
    claude, dan = evaluate(data, line, time.time(), Clock(_budget()))
    if not claude and not dan:
        return 0
    context = "\n\n".join("Filed issue check: " + c for c in claude)
    out = {"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": context}}
    if dan:
        out["systemMessage"] = " ".join(dan)
    json.dump(out, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
