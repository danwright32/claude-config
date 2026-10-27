#!/usr/bin/env python3
"""Refuse a comment, review, reply or Slack message that carries the Claude session link.

The session link belongs on commits, pull request descriptions and issue bodies, where the harness
and the issue field gate put it, so a session can tell who made what. A comment is addressed to
people, and there it is noise (Dan, 2026-10-27, after deleting it by hand from a reply to a teammate
on a Pivot issue; 32 Pivot comments carried it). Nothing appended it: the session wrote it by habit,
copying the commit and pull request rule, and the written rule alone did not stop it.

Judged here:
  gh issue comment, gh pr comment, gh pr review: --body/-b, and a --body-file/-F the gate can read
    (a file on disk, or a heredoc on standard input with -F -)
  gh issue close, gh pr close: --comment/-c
  gh api writing to a comments, replies or reviews endpoint (a review comment reply has no gh
    subcommand of its own)
  the Slack send, draft and schedule tools

Commands are read by the shared gh reader (gh_issue_scan.py), the one issue_field_gate.py uses.
Override for one command: ALLOW_SESSION_LINK_IN_COMMENT=1 <the command>.
"""

import importlib.util
import json
import os
import re
import sys

_HERE = os.environ.get("GATE_DIR") or os.path.dirname(os.path.abspath(__file__))
_path = os.path.join(_HERE, "gh_issue_scan.py")
_spec = importlib.util.spec_from_file_location("gh_issue_scan", _path)
if _spec is None or _spec.loader is None:
    raise ImportError("cannot load the shared scanner at %s" % _path)
scan = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(scan)

# Both spellings: the labelled line lib/claude-session-line.sh makes, and the bare link the harness
# puts at the end of a pull request description.
LINK = re.compile(r"Claude-Session:|claude\.ai/code/session_")
OVERRIDE = "ALLOW_SESSION_LINK_IN_COMMENT=1"
COMMENT_KINDS = frozenset({("issue", "comment"), ("pr", "comment"), ("pr", "review")})
# A close posts its --comment as an ordinary comment.
CLOSE_KINDS = frozenset({("issue", "close"), ("pr", "close")})
SLACK_SENDS = re.compile(r"mcp__.*slack.*__slack_(send_message|send_message_draft|schedule_message)")
API_COMMENT_ENDPOINT = re.compile(r"(?:^|/)(?:comments|replies|reviews)(?:/|\?|$)")
API_WRITE_FLAGS = {"-f", "-F", "--field", "--raw-field", "--input"}
API_WRITE_METHODS = {"POST", "PATCH", "PUT"}

REASON = (
    "This would post the Claude session link in a %s. The link goes on commits, pull request "
    "descriptions and issue bodies only, never in a comment, review, reply or message addressed to "
    "people (Dan, 2026-10-27).\n"
    "Remove the Claude-Session line (or the bare claude.ai/code/session link) from the body and re-run."
)
BASH_OVERRIDE = ("\nIf Dan has asked for the link in this one comment, say so and re-run with "
                 + OVERRIDE + " <the same command>, good for that one command only.")


def _comment_body_has_link(args, command, place):
    if any(LINK.search(a) for a in scan.flag_values(args, "--body", "-b")):
        return True
    # Standard input, fed by a heredoc or a pipe that is part of the command itself. flag_values
    # never returns a bare "-", which it reads as the next flag, so the spellings are matched here.
    reads_stdin = any(a in ("-F", "--body-file") and nxt == "-" for a, nxt in zip(args, args[1:])) \
        or any(a in ("-F-", "--body-file=-") for a in args)
    if reads_stdin and LINK.search(command):
        return True
    for word in scan.flag_values(args, "--body-file", "-F"):
        if word == "-":
            continue
        path, why = scan.resolve_path(word, place)
        if why or not path:
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                if LINK.search(f.read()):
                    return True
        except OSError:
            continue
    return False


def _file_has_link(word, cwd):
    """Whether a file a gh api call reads its body from holds the link. Relative paths are read
    against the payload's directory: a cd earlier in the command is not followed here."""
    path = os.path.expanduser(word)
    if not os.path.isabs(path):
        if not cwd:
            return False
        path = os.path.join(cwd, path)
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return LINK.search(f.read()) is not None
    except OSError:
        return False


def _api_writes_with_link(command, cwd):
    """Whether a gh api call in the command writes the link to a comment endpoint, unless overridden."""
    pipelines, _bodies = scan._stages(command)
    for stages in pipelines:
        if not isinstance(stages, list):
            continue
        for words, _redirects, heredocs in stages:
            # Which gh subcommand runs is read by the shared reader, never by word position (#1188).
            found = scan.gh_command(words)
            if not found or found[0] != "api" or OVERRIDE in words:
                continue
            args = list(found[2]) + list(found[3])
            method = {v.upper() for v in scan.flag_values(args, "--method", "-X")}
            writes = method & API_WRITE_METHODS or any(
                a in API_WRITE_FLAGS or any(a.startswith(f + "=") for f in API_WRITE_FLAGS if f.startswith("--"))
                for a in args)
            if not writes or not any(API_COMMENT_ENDPOINT.search(a) for a in args if not a.startswith("-")):
                continue
            if any(LINK.search(a) for a in args):
                return True
            # A body read from a file: -F key=@path, or the whole request from --input path.
            files = [v.split("=@", 1)[1] for v in scan.flag_values(args, "--field", "-F") if "=@" in v]
            files += scan.flag_values(args, "--input")
            if any(_file_has_link(p, cwd) for p in files if p != "-"):
                return True
            # The shared reader keeps only whether each heredoc body is shown, never its text, so a
            # body fed by one is judged from the command text, as a comment's -F - is.
            if heredocs and LINK.search(command):
                return True
    return False


def judge_bash(command, cwd):
    """The kind of post that would carry the link ("comment", "review", "closing comment" or
    "comment or reply"), or None."""
    # Only a command naming gh can post; a body file may hold the link the command text does not.
    if not re.search(r"\bgh\b", command):
        return None
    try:
        found = scan.scan_gh_in_context(command, cwd, dict(os.environ), COMMENT_KINDS | CLOSE_KINDS)
        for kind, args, envs, place in found:
            if OVERRIDE in envs:
                continue
            if kind in CLOSE_KINDS:
                if any(LINK.search(a) for a in scan.flag_values(args, "--comment", "-c")):
                    return "closing comment"
                continue
            if _comment_body_has_link(args, command, place):
                return "review" if kind == ("pr", "review") else "comment"
        if _api_writes_with_link(command, cwd):
            return "comment or reply"
    except scan.Unreadable:
        # A command nobody could tokenize: refuse when its text carries the link and plainly posts a
        # comment.
        if OVERRIDE not in command and LINK.search(command) and re.search(r"\bgh\b[^\n]*\b(?:comment|review|comments|replies)\b", command):
            return "comment"
    return None


def main():
    try:
        data = json.loads(sys.stdin.read())
    except ValueError as e:
        # Exit non zero so the wrapper says the gate did not run, rather than passing unjudged.
        print("the hook payload is not JSON: %s" % e, file=sys.stderr)
        return 1
    tool = data.get("tool_name") or ""
    tool_input = data.get("tool_input") or {}
    if tool == "Bash":
        cwd = data.get("cwd") if isinstance(data.get("cwd"), str) else None
        what = judge_bash(tool_input.get("command") or "", cwd)
    elif SLACK_SENDS.fullmatch(tool):
        what = "Slack message" if LINK.search(json.dumps(tool_input)) else None
    else:
        what = None
    if what:
        reason = REASON % what + (BASH_OVERRIDE if tool == "Bash" else "")
        json.dump(scan.deny_payload(reason), sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
