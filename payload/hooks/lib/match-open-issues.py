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

ITEM MODE (claude-config#3555). Orchestrate's intake asks, for an item from Slack, whether an open
issue or an open pull request already covers it, through skills/orchestrate/find-existing.sh. It is
this matcher with two differences, both confined to that mode: it reads open pull requests as well,
and an item that names no file path may still match on words, under the strict word rule written
beside RARE_DF below. It does NOT fail
open: an intake that could not look must say so and exit 2, because there an empty answer would
send a second builder after work already in hand.

Usage:  match-open-issues.py <project dir> < findings.txt > annotated.txt
        match-open-issues.py --paths < issues.json > paths.json   (the area check's reader)
        match-open-issues.py --item <owner/repo or folder> < item.txt   (orchestrate's intake)
"""
import json
import os
import re
import subprocess
import io
import sys

TIMEOUT = float(os.environ.get("CLAUDE_ISSUE_MATCH_TIMEOUT") or 20)

# A path with an extension, which is what a finding names when it names anything. The one reader of
# the paths a text names: the area check mod (mods/area-check) asks it through `--paths` for every
# open issue's paths rather than keeping a second extractor (claude-config#1508, L655, L370), and
# test-match-open-issues-paths.sh holds every extension that mod counts as source to this list.
PATH_RE = re.compile(
    r"[A-Za-z0-9_][A-Za-z0-9_./-]*\.(?:py|js|mjs|cjs|ts|tsx|jsx|sh|swift|rb|go|rs|java|kt|kts|"
    r"vue|svelte|scss|php|cs|cpp|c|h|m|"
    r"md|json|yml|yaml|sql|css|html|txt|tsv)\b")


def paths(text):
    """Each path `text` names, once, in the order it first appears. A line or range after a path
    (`a.ts:12-40`) is not part of it, nor is a leading `./`: PATH_RE starts at a word character and
    ends at the extension, so neither is ever matched."""
    seen = []
    for p in PATH_RE.findall(text or ""):
        if p not in seen:
            seen.append(p)
    return seen


def paths_main():
    """`--paths`: a JSON list of issues (number, title, body) on stdin, each issue's paths out as
    {"<number>": [paths]}. A list that cannot be read exits 2, never read as issues naming nothing."""
    try:
        rows = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
    except Exception as exc:
        sys.stderr.write("match-open-issues --paths: stdin is not JSON (%s)\n" % type(exc).__name__)
        return 2
    if not isinstance(rows, list):
        sys.stderr.write("match-open-issues --paths: stdin is not a list of issues\n")
        return 2
    out = {}
    for r in rows:
        if not isinstance(r, dict) or r.get("number") is None:
            sys.stderr.write("match-open-issues --paths: an entry has no number\n")
            return 2
        out[str(r["number"])] = paths("%s\n%s" % (r.get("title") or "", r.get("body") or ""))
    sys.stdout.write(json.dumps(out))
    return 0

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
                             capture_output=True, text=True, timeout=TIMEOUT, errors="replace")
    except Exception:
        return project, ""
    resolved = (out.stdout or "").strip()
    if out.returncode != 0 or not resolved or not os.path.isdir(resolved):
        return project, ""
    # exists, never isdir (claude-config#402): in a git worktree .git is a FILE, and the helper this
    # re-checks tests with -e, so a directory test read every worktree as no checkout at all.
    if resolved != project or os.path.exists(os.path.join(project, ".git")):
        return resolved, ""
    # It came back unchanged and this directory is not itself a checkout. Two reasons, and they
    # need different words: there is no checkout anywhere, or there is more than one and the
    # resolver refuses to pick (claude-config#346). Reporting the second as gh complaining about
    # a directory that is not a repository is true and is a different fault with a different
    # remedy, and the remedy here is the reader's to apply (L11).
    try:
        listed = subprocess.run(["bash", helper, "checkout-candidates", project],
                                capture_output=True, text=True, timeout=TIMEOUT, errors="replace")
        found = [c for c in (listed.stdout or "").split("\n") if c.strip()]
    except Exception:
        found = []
    if len(found) > 1:
        return project, ("%s holds more than one checkout (%s) and nothing here can say which "
                         "repository this project's issues live in" % (project, ", ".join(found)))
    return project, ""


def gh_list(args, cwd, timeout):
    """(rows, gh's exit code, gh's first error line, what went wrong). The one place a list is asked
    of gh, for the review and the intake alike. `what went wrong` is "" when rows is a JSON list."""
    try:
        out = subprocess.run(["gh"] + args, cwd=cwd, capture_output=True, text=True,
                             timeout=timeout, errors="replace")
    except Exception as exc:
        return None, None, "", "could not be run (%s)" % type(exc).__name__
    if out.returncode != 0:
        return None, out.returncode, (out.stderr or "").strip().splitlines()[:1], "refused"
    if not out.stdout.strip():
        return None, 0, "", "empty"
    try:
        rows = json.loads(out.stdout)
    except Exception:
        return None, 0, "", "not json"
    if not isinstance(rows, list):
        return None, 0, "", "not json"
    return rows, 0, "", ""


def open_issues(project):
    """(issues, why it could not be read). Both empty means the repo genuinely has no open issue."""
    where, unresolved = checkout_dir(project)
    if unresolved:
        return [], unresolved
    rows, _, err, wrong = gh_list(["issue", "list", "--state", "open", "--limit", "300",
                                   "--json", "number,title,body"], where, TIMEOUT)
    if wrong.startswith("could not be run"):
        return [], "gh " + wrong
    if wrong == "refused":
        return [], "gh refused: %s" % err
    if wrong == "empty":
        return [], "gh answered with nothing at all"
    if wrong:
        return [], "gh answered with something that is not the issue list"
    return ([(r.get("number"), r.get("title") or "", r.get("body") or "")
             for r in rows if isinstance(r, dict) and r.get("number")], "")


def words(text):
    return {w for w in re.findall(r"[a-z][a-z0-9_-]{2,}", text.lower()) if w not in GENERIC}


# Item mode's word rule, for an item naming no file path. It needs BOTH of two signals:
#   - at least TITLE_SHARED words of the issue's or pull request's TITLE are in the item. A title is
#     the summary of a subject; a body is long enough to share three words with almost anything
#     (a Slack item about low free space on a backup drive shared "alert", "free", "morning" and
#     "space" with the body of an issue about the free space warning's projection, and only "free"
#     and "space" with its title);
#   - at least RARE_SHARED of the words they share are RARE in this repository's open issues and
#     pull requests, held by at most RARE_DF of them. Rarity is measured on the repository's own
#     text, which is the answer to "every repo has its own generic vocabulary and no list here can
#     know it": a word most issues use says nothing about which one this is.
# A matcher that cries wolf is ignored, so the rule is strict and misses wording that differs:
# nothing printed means no open item shares the item's words, never that none covers it. Measured on
# 2026-11-27 against claude-config's 200 open issues and 74 open pull requests, TITLES ONLY: 0 of 12
# made up items nothing covers matched anything, 6 of 7 paraphrases of open items found theirs, and
# 1 unrelated neighbour was offered beside them. Bodies were not read, so a match a body would add
# or take away is unmeasured (claude-config#3555's pull request has the detail).
RARE_DF = 3
RARE_SHARED = 2
TITLE_SHARED = 3


def rare_words(texts):
    """The words held by at most RARE_DF of `texts`, each text counted once per word."""
    df = {}
    for text in texts:
        for w in words(PATH_RE.sub(" ", text)):
            df[w] = df.get(w, 0) + 1
    return {w for w, n in df.items() if n <= RARE_DF}


def match(finding, issues, rare=None, most=2):
    """The issues that already cover this finding, best first, as (number, title, shared words).
    Empty when nothing clearly does.

    `rare` is item mode's word set (see rare_words). Left None, as the end of turn review leaves it,
    a text naming no file path never matches, exactly as it always has."""
    named = set(paths(finding))
    if not named and rare is None:
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
        shared_paths = {p for p in named if p in text}
        shared_words = fw & words(PATH_RE.sub(" ", text))
        # A shared path and nothing else is a file two unrelated findings both mention. The words
        # are what say it is the same SUBJECT, and they are only ever a tie breaker. Two of them,
        # because one generic word is the false sibling this repo has already been caught by twice.
        if shared_paths and len(shared_words) >= 2:
            hits.append((len(shared_paths), len(shared_words), number, title, shared_words))
            continue
        if rare is not None:
            in_title = fw & words(PATH_RE.sub(" ", title))
            shared_rare = shared_words & rare
            if len(in_title) >= TITLE_SHARED and len(shared_rare) >= RARE_SHARED:
                hits.append((0, len(in_title) + len(shared_rare), number, title,
                             in_title | shared_rare))
    hits.sort(key=lambda h: (h[0], h[1], h[2]), reverse=True)
    return [(n, t, sorted(s)) for _, _, n, t, s in hits[:most]]


# ---- item mode: orchestrate's intake (claude-config#3555) ----

# How many open issues, and separately open pull requests, one look reads. gh pages through them a
# hundred at a time, so 1000 is ten requests per list; claude-config had 178 and 44 open on
# 2026-11-26. A list that comes back FULL may have more behind it, and the look says so rather than
# reading the newest thousand as all of them.
def env_number(name, default, kind):
    """A number from the environment, or the default when unset or not a number. Read here rather
    than with a bare int() at import, where a bad value would crash the end of turn review too, a
    mode that must never cost the review."""
    try:
        value = kind(os.environ.get(name) or default)
    except ValueError:
        return default
    return value if value > 0 else default


ITEM_LIMIT = env_number("CLAUDE_ITEM_MATCH_LIMIT", 1000, int)
ITEM_TIMEOUT = env_number("CLAUDE_ITEM_MATCH_TIMEOUT", 60, float)
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
TITLE_REF_RE = re.compile(r"#(\d+)\b")


def could_not_look(why):
    sys.stdout.write("COULD NOT LOOK: %s\n" % why)
    return 2


def item_where(target):
    """(gh's extra args, the directory gh runs in, how to name the repository, why it cannot look)."""
    if os.path.isdir(target):
        where, unresolved = checkout_dir(target)
        if unresolved:
            return None, None, None, unresolved
        try:
            top = subprocess.run(["git", "-C", where, "rev-parse", "--show-toplevel"],
                                 capture_output=True, text=True, timeout=ITEM_TIMEOUT,
                                 errors="replace")
        except Exception as exc:
            return None, None, None, "git could not be run (%s)" % type(exc).__name__
        if top.returncode != 0 or not top.stdout.strip():
            return None, None, None, ("%s is not inside a git repository, so there is no issue "
                                      "tracker to read" % target)
        return [], top.stdout.strip(), "the repository at %s" % top.stdout.strip(), ""
    if REPO_RE.match(target):
        return ["--repo", target], None, target, ""
    return None, None, None, ("%s is neither a folder nor owner/repo, so there is no issue tracker "
                              "to read" % target)


def item_read(kind, fields, extra, where, name):
    """(rows, why it could not be read)."""
    noun = "open issues" if kind == "issue" else "open pull requests"
    rows, _, err, wrong = gh_list([kind, "list"] + extra +
                                  ["--state", "open", "--limit", str(ITEM_LIMIT), "--json", fields],
                                  where, ITEM_TIMEOUT)
    first = (err[0] if err else "").strip()
    if wrong == "refused" and "disabled issues" in first:
        return None, "%s has its issue tracker turned off (gh: %s)" % (name, first)
    if wrong == "refused":
        return None, "gh could not read the %s of %s: %s" % (noun, name, first or "no reason given")
    if wrong.startswith("could not be run"):
        return None, "gh %s, so the %s of %s were not read" % (wrong, noun, name)
    if wrong == "empty":
        return None, "gh answered with nothing at all for the %s of %s" % (noun, name)
    if wrong:
        return None, "gh answered with something that is not the list of %s of %s" % (noun, name)
    return [r for r in rows if isinstance(r, dict) and r.get("number")], ""


def pr_names(pr):
    """What a pull request says about the issues it covers: the ones GitHub records it closing,
    else the ones its title names, else that it names none."""
    closes = [c.get("number") for c in (pr.get("closingIssuesReferences") or [])
              if isinstance(c, dict) and c.get("number")]
    if closes:
        return "closes " + ", ".join("#%d" % n for n in closes)
    named = TITLE_REF_RE.findall(pr.get("title") or "")
    if named:
        return "names " + ", ".join("#%s" % n for n in named)
    return "names no issue"


def item_main(target):
    text = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace").read()
    if not text.strip():
        return could_not_look("no item text on standard input, so there was nothing to match")
    extra, where, name, why = item_where(target)
    if why:
        return could_not_look(why)
    issues, why = item_read("issue", "number,title,body", extra, where, name)
    if why:
        return could_not_look(why)
    prs, why = item_read("pr", "number,title,body,closingIssuesReferences", extra, where, name)
    if why:
        return could_not_look(why)
    entries = [("issue", r) for r in issues] + [("pull request", r) for r in prs]
    texts = ["%s\n%s" % (r.get("title") or "", r.get("body") or "") for _, r in entries]
    rare = rare_words(texts)
    hits = match(text, [(i, r.get("title") or "", r.get("body") or "")
                        for i, (_, r) in enumerate(entries)], rare=rare, most=3)
    out = []
    if hits:
        out.append("MAY ALREADY BE COVERED in %s (the orchestrating session decides):" % name)
        for i, title, shared in hits:
            kind, r = entries[i]
            line = "%s #%d: %s" % (kind, r["number"], title)
            if kind == "pull request":
                line += "  (%s)" % pr_names(r)
            out.append(line + "  [shares: %s]" % ", ".join(shared))
    for noun, rows in (("open issues", issues), ("open pull requests", prs)):
        if len(rows) >= ITEM_LIMIT:
            out.append("READ ONLY THE NEWEST %d %s of %s: any older one was not compared."
                       % (ITEM_LIMIT, noun, name))
    if out:
        sys.stdout.write("\n".join(out) + "\n")
    return 0


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--paths":
        return paths_main()
    if len(sys.argv) > 1 and sys.argv[1] == "--item":
        if len(sys.argv) != 3 or not sys.argv[2]:
            return could_not_look("usage: match-open-issues.py --item <owner/repo or folder> "
                                  "< item text")
        return item_main(sys.argv[2])
    project = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    text = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace").read()
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
            for number, title, _ in match(line, issues):
                line += "  [already #%d: %s]" % (number, title[:70])
        out.append(line)
    sys.stdout.write("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main())
