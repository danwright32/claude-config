#!/usr/bin/env python3
"""Annotate spooled findings with the open issue that already covers them.

WHY. On 2026-09-01 eight read only agents audited every open issue in one repo against main. The
SubagentStop harvest spooled their observations, another session's review offered them as fresh
findings, and four were filed: each was a twin of the issue the agent had been READING, created
minutes after the agents finished and closed as a duplicate within the hour. The harvest prompt
deliberately covers agents whose job is finding problems, which is right, and it has no way to know
the problem is already tracked. So every audit of the backlog refiles the backlog, across sessions,
and the person answering the picker is not the one who dispatched the agents (claude-config#256,
L333, L363).

WHAT IT IS NOT. It does not decide anything. It puts the issue number beside the finding and lets
the reader judge, which is the same refusal milestone-candidates.sh makes about relatedness: a
matcher that ruled would be a word counter deciding what a reader can see for themselves
(claude-config#265). It is deliberately hard to trigger, because a wrong `already #N` is worse than
none: it would talk somebody out of filing a real finding.

FAILS OPEN. No gh, no network, no repo, a slow call: the findings go out unannotated. This is a
convenience on a review, and losing it must never cost the review itself. Which is also why the
repo is RESOLVED rather than assumed: failing open in a project whose checkout sits below the
workspace root meant this never ran there at all, and a footnote at the foot of the findings does
not read as "this whole review was blind" (claude-config#344).

Usage:  match-open-issues.py <project dir> < findings.txt > annotated.txt
"""
import json
import os
import re
import subprocess
import sys

TIMEOUT = float(os.environ.get("CLAUDE_ISSUE_MATCH_TIMEOUT") or 20)

# A path with an extension, which is what a finding names when it names anything.
PATH_RE = re.compile(
    r"[A-Za-z0-9_][A-Za-z0-9_./-]*\.(?:py|js|mjs|ts|tsx|jsx|sh|swift|rb|go|rs|java|kt|"
    r"md|json|yml|yaml|sql|css|html|txt|tsv)\b")

# Words that say nothing about WHICH finding this is. Every repo has its own generic vocabulary and
# no list here can know it, which is why a shared word is never enough on its own: it only breaks a
# tie between issues that already share a file path.
GENERIC = {
    "the", "a", "an", "and", "or", "but", "not", "is", "are", "was", "were", "be", "been",
    "to", "of", "in", "on", "for", "with", "that", "this", "it", "its", "as", "at", "by",
    "from", "has", "have", "had", "no", "so", "than", "then", "there", "which", "when",
    "test", "tests", "issue", "issues", "add", "fix", "make", "use", "using", "run", "runs",
    "file", "files", "code", "line", "lines", "check", "checks", "error", "errors",
}


def checkout_dir(project):
    """(the checkout `project` belongs to, why it could not be resolved).

    The directory, so gh has a repository to resolve from.

    The project directory is NOT always a checkout. In PET the workspace root is one level above
    the repo, so `gh issue list` run there refused with "not a git repository" and every review in
    that project fell back to the unannotated list: the duplicate check had never once run there
    (claude-config#344). Failing open was right; being blind for months was not.

    The walk itself lives in merge-target.sh, which the merge gates source, because a second copy
    of it here would be a second rule that drifts, each half passing its own suite (L263, L370).
    Its executed mode exists for this caller.

    Fails open to the directory as given: a missing helper, a broken bash, a slow one, and gh is
    asked exactly what it used to be asked.
    """
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)), "merge-target.sh")
    if not os.path.isfile(helper):
        return project, ""
    try:
        out = subprocess.run(["bash", helper, "checkout-dir", project],
                             capture_output=True, text=True, timeout=TIMEOUT)
    except Exception:
        return project, ""
    resolved = (out.stdout or "").strip()
    if out.returncode != 0 or not resolved or not os.path.isdir(resolved):
        return project, ""
    if resolved != project or os.path.isdir(os.path.join(project, ".git")):
        return resolved, ""
    # It came back unchanged and this directory is not itself a checkout. Two reasons, and they
    # need different words: there is no checkout anywhere, or there is more than one and the
    # resolver refuses to pick (claude-config#346). Reporting the second as gh complaining about
    # a directory that is not a repository is true and is a different fault with a different
    # remedy, and the remedy here is the reader's to apply (L11).
    try:
        listed = subprocess.run(["bash", helper, "checkout-candidates", project],
                                capture_output=True, text=True, timeout=TIMEOUT)
        found = [c for c in (listed.stdout or "").split("\n") if c.strip()]
    except Exception:
        found = []
    if len(found) > 1:
        return project, ("%s holds more than one checkout (%s) and nothing here can say which "
                         "repository this project's issues live in" % (project, ", ".join(found)))
    return project, ""


def open_issues(project):
    """(issues, why it could not be read). Both empty means the repo genuinely has no open issue."""
    where, unresolved = checkout_dir(project)
    if unresolved:
        return [], unresolved
    try:
        out = subprocess.run(
            ["gh", "issue", "list", "--state", "open", "--limit", "300",
             "--json", "number,title,body"],
            cwd=where, capture_output=True, text=True, timeout=TIMEOUT)
    except Exception as exc:
        return [], "gh could not be run (%s)" % type(exc).__name__
    if out.returncode != 0:
        return [], "gh refused: %s" % (out.stderr or "").strip().splitlines()[:1]
    if not out.stdout.strip():
        return [], "gh answered with nothing at all"
    try:
        rows = json.loads(out.stdout)
    except Exception:
        return [], "gh answered with something that is not the issue list"
    return ([(r.get("number"), r.get("title") or "", r.get("body") or "")
             for r in rows if isinstance(r, dict) and r.get("number")], "")


def words(text):
    return {w for w in re.findall(r"[a-z][a-z0-9_-]{2,}", text.lower()) if w not in GENERIC}


def match(finding, issues):
    """The issues that already cover this finding, best first. Empty when nothing clearly does."""
    paths = {p for p in PATH_RE.findall(finding)}
    if not paths:
        # With no file path there is nothing specific enough to match on. Title words alone
        # produced false siblings twice in the milestone helper, always claiming a cluster that was
        # not there, and the same words would do the same here (claude-config#265).
        return []
    # The PATH IS REMOVED from both sides before the words are compared. A path tokenises into
    # words of its own ("widget", "cache"), so leaving it in makes the word test agree with the
    # path test by construction and it stops being a second signal at all: measured, it matched a
    # finding about logging against an issue about invalidation, on nothing but the filename.
    fw = words(PATH_RE.sub(" ", finding))
    hits = []
    for number, title, body in issues:
        text = title + "\n" + body
        shared_paths = {p for p in paths if p in text}
        if not shared_paths:
            continue
        # A shared path and nothing else is a file two unrelated findings both mention. The words
        # are what say it is the same SUBJECT, and they are only ever a tie breaker. Two of them,
        # because one generic word is the false sibling this repo has already been caught by twice.
        shared_words = fw & words(PATH_RE.sub(" ", text))
        if len(shared_words) < 2:
            continue
        hits.append((len(shared_paths), len(shared_words), number, title))
    hits.sort(reverse=True)
    return [(n, t) for _, _, n, t in hits[:2]]


def main():
    project = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    text = sys.stdin.read()
    if "FINDING" not in text:
        sys.stdout.write(text)
        return 0
    issues, why = open_issues(project)
    if why:
        # SAID. Failing open is right, and a review that could not look is not the same as one
        # that looked and matched nothing: without this line the reader has no way to tell an
        # unannotated list from a list with no duplicates in it (L10, L11).
        sys.stdout.write(text.rstrip("\n") +
                         "\nOPEN ISSUES NOT READ, so none of these carry the issue that may "
                         "already cover them: %s\n" % why)
        return 0
    if not issues:
        sys.stdout.write(text)
        return 0
    out = []
    for line in text.split("\n"):
        if line.startswith("FINDING"):
            for number, title in match(line, issues):
                line += "  [already #%d: %s]" % (number, title[:70])
        out.append(line)
    sys.stdout.write("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
