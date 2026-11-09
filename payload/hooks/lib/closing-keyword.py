#!/usr/bin/env python3
"""Find a closing keyword GitHub will honour for an issue the text says it is NOT closing (L1018),
and, since claude-config#2464, one before an open pull request, one in the middle of a sentence
before an open issue, and one whose number could not be looked up.

    closing-keyword.py text [<owner/name>]
                                     any text on stdin (a command, a PR body, a commit message),
                                     <owner/name> being the repository a bare #N belongs to
    closing-keyword.py pr <owner/name>
                                     a pull request as `gh pr view --json
                                     number,url,body,closingIssuesReferences` prints it, on stdin,
                                     <owner/name> being the repository the pull request is in

Prints one finding per line and exits 0 whether or not it found anything (the caller decides what a
finding means). In `pr` mode an answer that is not JSON, or carries no closingIssuesReferences list,
exits 3: a pull request that could not be read is never one with nothing wrong in it (L98).

WHY. GitHub's linked issue parser matches a closing keyword (close, closes, closed, fix, fixes,
fixed, resolve, resolves, resolved) followed by an issue reference and does no reading of the
sentence around it, so "This does not close #897" closes #897 on merge (Overture #912). The careful
author is the one who trips it: a pull request that deliberately finishes only part of an issue
says so. Measured on 2026-10-24 over every merged pull request in claude-config (633) and Overture
(1,925): a dozen merges closed an issue their own body meant to leave open, in four shapes.

WHAT COUNTS. A closing keyword followed by an issue reference (#12, owner/name#12, or the issue's
URL) for an issue that CLOSES, where:

  negated      a negation is among the last four words of the keyword's own sentence
               ("does not close #897")
  conditional  so is a conditional ("would also have closed #2584", "could fix #12")
  which        so is "which", the keyword describing another change ("Follows #4036, which closed
               #3769")
  partial      so is a word making it partial ("Partially closes #2265", "helps fix #12")

or, about the same issue anywhere in the text:

  part of      it is also called "Part of #953" (not "not part of"), which says this change does
               not finish it (claude-config#970: "The next PR ... closes #953")
  stays open   it is also said to stay, remain or be kept open ("#3566 should stay open")

Only the keyword's OWN sentence is read for the first four, cut at the last sentence end or line
break before it: "This does not attempt X. Closes #910." is honest English and passes. The last
two are about the one issue named, never a neighbour: "Closes #771; #800 stays open" passes.

WHICH ISSUES CLOSE. In `pr` mode, exactly the ones GitHub lists in closingIssuesReferences, which
also holds an issue linked by hand in the sidebar (so a body saying such an issue stays open is
contradicted by the merge although no keyword is in it). A keyword before an issue GitHub does not
list closes nothing and is not judged. A bare #12 is the pull request's own repository's issue. In
`text` mode nothing is listed yet, so every issue a keyword is followed by counts as closing, and a
bare #12 is only ever the same issue as another bare #12.

EVERY PAIR, LOOKED UP (claude-config#2464). The rules above read only the sentence, so a closing
word written in passing ("including the p0 fix #2451") passed, and on 2026-11-08 merging #2456
closed the open pull request #2451 unmerged. GitHub closes a pull request named after a closing
word just as it closes an issue, but never lists one in closingIssuesReferences. So every keyword
and number pair is now looked up (gh api repos/<owner>/<name>/issues/<n>, whose pull_request field
tells a pull request), and the text is refused where a pair names:

  an OPEN PULL REQUEST, wherever the pair sits: merging would close it unmerged. To mean "this
               replaces #N", write "Supersedes #N" and close it by hand.
  an OPEN ISSUE the change does not mean to close, which is how "means to close" is read here: a
               pair means to close when its keyword starts a line (past indentation, a list marker
               or a quote mark) or starts a sentence (right after a full stop, question or
               exclamation mark), or follows such a pair on its line with nothing but commas, "and"
               or semicolons between ("Closes #12, closes #13"). A keyword anywhere else is a word
               in a sentence ("the follow up fix #12"), and GitHub closes the issue all the same.
               In `text` mode the start of a quoted argument counts as a line start too, so
               `-m "Closes #12"` is one. In `pr` mode only an issue GitHub lists closes, so an
               unlisted one is not judged, and a listed one is never looked up again.

A closed issue or pull request is not judged: merging cannot close it again. A lookup that fails,
that answers in a shape that is not GitHub's, or a bare #N with no repository to look it up in
(`text` mode with no <owner/name>) is refused with its reason, never passed (L98). A number
already refused for its sentence is not looked up, since nothing the lookup says could clear it.

CLOSING_KEYWORD_LOOKUP names an executable run as `<it> <owner/name> <n>` in place of gh, printing
the same JSON, for the tests; CLOSING_LOOKUP_BUDGET_SECONDS (10) bounds every lookup together.

Two hooks ask this, so the rule is the same where text is written and where a pull request merges:
check-closing-keyword.sh (a pull request or commit being written) and check-closing-merge.sh (the
body GitHub holds, at merge, claude-config#1550).
"""
import json
import os
import re
import io
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import repo_slug  # noqa: E402

KEYWORD = r"(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)"
# An issue reference in any form GitHub itself honours: the full URL, owner/repo#12, or #12. The URL
# of a pull request too (/pull/N), which GitHub closes the same way (claude-config#2464).
REF = (r"(?:https?://[^\s/]+/(?P<{p}uo>[\w.-]+)/(?P<{p}un>[\w.-]+)/(?:issues|pull)/(?P<{p}n3>\d+)"
       r"|(?P<{p}owner>[\w.-]+)/(?P<{p}name>[\w.-]+)#(?P<{p}n1>\d+)"
       r"|#(?P<{p}n2>\d+))")

# No leading word boundary and any whitespace between keyword and reference: the reading this
# detector had when it lived inside check-closing-keyword.sh, kept so the move narrows nothing. A
# colon after the keyword ("Closes: #12") is also honoured by GitHub.
CLOSING = re.compile(r"(?P<kw>" + KEYWORD + r"):?\s+" + REF.format(p=""), re.IGNORECASE)
PART_OF = re.compile(r"\bpart\s+of\s+" + REF.format(p=""), re.IGNORECASE)
NOT_BEFORE = re.compile(r"\b(?:not|no)\s+$", re.IGNORECASE)
# The reference, then up to forty characters holding no other reference and no sentence end, then
# the verb: "#3566 should stay open", "#40 remains open". "left open" is not one of them: "the
# decision #3078 left open" is the issue leaving something open (overture#3618).
STAYS_OPEN = re.compile(REF.format(p="") + r"[^#.!?\n]{0,40}?\b(?:stays?|remains?|kept|keeps?)\s+open\b",
                        re.IGNORECASE)

# Matched against words with their apostrophes taken out, so "doesn't" is "doesnt".
KINDS = (
    ("negated", {"not", "dont", "doesnt", "didnt", "wont", "cant", "cannot", "never", "no",
                 "isnt", "arent", "wasnt", "neither", "nor", "without", "shouldnt", "wouldnt",
                 "couldnt", "hasnt", "havent"}),
    ("conditional", {"would", "could", "should", "might", "if", "unless", "whether", "until"}),
    ("which", {"which"}),
    ("partial", {"partly", "partially", "half", "help", "helps", "toward", "towards", "begin",
                 "begins", "start", "starts"}),
)
WHY = {
    "negated": "the closing word sits in a negated sentence",
    "conditional": "the closing word sits in a conditional sentence",
    "which": "the closing word sits in a \"which\" clause, describing another change",
    "partial": "the closing word sits in a sentence saying the work is partial",
}

WINDOW_WORDS = 4


def ref_key(m, slug):
    """(repository, number) for a REF match; a bare #N belongs to `slug` (None in text mode)."""
    if m.group("n3"):
        return ("%s/%s" % (m.group("uo"), m.group("un"))).lower(), int(m.group("n3"))
    if m.group("n1"):
        return ("%s/%s" % (m.group("owner"), m.group("name"))).lower(), int(m.group("n1"))
    return (slug.lower() if slug else None), int(m.group("n2"))


def show(key, slug):
    repo, number = key
    if repo is None or (slug and repo == slug.lower()):
        return "#%d" % number
    return "%s#%d" % (repo, number)


def sentence_before(text, start):
    """The keyword's own sentence up to the keyword: cut at the last sentence end or line break."""
    return re.split(r"[.!?\n]", text[:start])[-1]


def kind_of(sentence):
    # Apostrophes, the ascii one and the typographic one, are stripped BEFORE tokenizing, or the
    # contraction tokenizes to "doesn" and sails past a list holding "doesnt".
    flat = re.sub("[’']", "", sentence.lower())
    words = re.findall(r"[a-z]+", flat)[-WINDOW_WORDS:]
    for kind, vocab in KINDS:
        if any(w in vocab for w in words):
            return kind
    return None


def quote(sentence, match_text):
    return (" ".join(sentence.split()[-6:]) + " " + " ".join(match_text.split())).strip()


def findings(text, closing, slug):
    """[(key, reason)] for each way `text` contradicts closing an issue in `closing`.

    `closing` is a set of keys, or None to count every issue a keyword is followed by."""
    text = text or ""
    occurrences = [(m, ref_key(m, slug)) for m in CLOSING.finditer(text)]
    if closing is None:
        closing = {key for _, key in occurrences}
    out = []
    seen = set()

    def add(key, reason):
        if (key, reason) not in seen:
            seen.add((key, reason))
            out.append((key, reason))

    for m, key in occurrences:
        if key not in closing:
            continue
        sentence = sentence_before(text, m.start())
        kind = kind_of(sentence)
        if kind:
            add(key, "%s: \"%s\"" % (WHY[kind], quote(sentence, m.group(0))))
    for m in PART_OF.finditer(text):
        key = ref_key(m, slug)
        if key in closing and not NOT_BEFORE.search(text[:m.start()]):
            add(key, "the body also calls this change \"Part of %s\", so it does not finish it"
                % show(key, slug))
    for m in STAYS_OPEN.finditer(text):
        key = ref_key(m, slug)
        if key in closing:
            add(key, "the body also says it stays open: \"%s\"" % " ".join(m.group(0).split()))
    return out


# Where a pair means to close (claude-config#2464, the docstring's "means to close"): its keyword is
# what its line holds first, past indentation, list markers and quote marks; or it starts a sentence;
# or, in text mode, it starts a quoted argument; or it follows such a pair on its line with nothing
# but commas, semicolons or "and" between.
LINE_START = re.compile(r"[ \t]*(?:(?:[-*+>]|\d+[.)])[ \t]*)*")
AFTER_SENTENCE = re.compile(r"[.!?][)\]\"'*_]*[ \t]+$")
AFTER_QUOTE = re.compile(r"(?:^|[\s=])\$?[\"']$")
CHAINED = re.compile(r"[\s,;]*(?:and\b[\s,]*)?", re.IGNORECASE)
SLUG = re.compile(r"[\w.-]+/[\w.-]+")


def means_to_close(text, m, prev, text_mode):
    """Whether the pair `m` sits where a pair that means to close sits. `prev` is (end, verdict) of
    the pair before it on the same line, or None."""
    prefix = text[text.rfind("\n", 0, m.start()) + 1:m.start()]
    if LINE_START.fullmatch(prefix) or AFTER_SENTENCE.search(prefix):
        return True
    if text_mode and AFTER_QUOTE.search(prefix):
        return True
    return bool(prev and prev[1] and CHAINED.fullmatch(text[prev[0]:m.start()]))


class LookupFailed(Exception):
    pass


def _number(value, default):
    try:
        n = float(value)
        return n if n > 0 else default
    except (TypeError, ValueError):
        return default


class Lookup:
    """(kind, state) of an issue or pull request, from gh api repos/<repo>/issues/<n>.

    Tried under the active gh account, then under each other logged in account with its token
    scoped to the one call, never `gh auth switch`: a repository owned by one of Dan's accounts
    answers 404 under the other (the reasoning mt_pr_view in lib/merge-target.sh records)."""

    def __init__(self):
        self.exe = os.environ.get("CLOSING_KEYWORD_LOOKUP") or ""
        self.budget = _number(os.environ.get("CLOSING_LOOKUP_BUDGET_SECONDS"), 10.0)
        self.deadline = time.monotonic() + self.budget
        self.accounts = None
        self.seen = {}

    def _run(self, argv, env=None):
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise LookupFailed("the lookup budget of %g seconds was spent before it could be asked" % self.budget)
        try:
            p = subprocess.run(argv, capture_output=True, text=True, timeout=left, env=env)
        except FileNotFoundError:
            raise LookupFailed("%s is not on PATH" % argv[0])
        except subprocess.TimeoutExpired:
            raise LookupFailed("no answer within the lookup budget of %g seconds" % self.budget)
        except OSError as exc:
            raise LookupFailed("%s could not run: %s" % (argv[0], exc))
        return p.returncode, p.stdout, p.stderr

    def _fetch(self, repo, number):
        if self.exe:
            rc, out, err = self._run([self.exe, repo, str(number)])
            if rc != 0:
                raise LookupFailed(last_line(err) or "the lookup exited %d" % rc)
            return out
        argv = ["gh", "api", "repos/%s/issues/%d" % (repo, number)]
        rc, out, err = self._run(argv)
        if rc == 0:
            return out
        first = last_line(err) or "gh exited %d" % rc
        if self.accounts is None:
            _, so, se = self._run(["gh", "auth", "status"])
            self.accounts = sorted(set(re.findall(r"account ([A-Za-z0-9_.-]+)", so + se)))
        for account in self.accounts:
            trc, token, _ = self._run(["gh", "auth", "token", "-u", account])
            if trc != 0 or not token.strip():
                continue
            env = dict(os.environ, GH_TOKEN=token.strip())
            rc, out, _ = self._run(argv, env)
            if rc == 0:
                return out
        raise LookupFailed(first + " (under every logged in gh account)" if self.accounts else first)

    def __call__(self, repo, number):
        key = (repo, number)
        if key not in self.seen:
            try:
                answer = json.loads(self._fetch(repo, number))
                # Only the two states GitHub has: anything else would compare as "not open" and
                # pass as closed, so it is a shape this cannot read (L50).
                if not isinstance(answer, dict) or str(answer.get("state")).lower() not in ("open", "closed"):
                    raise ValueError("no state")
                self.seen[key] = ("pull request" if answer.get("pull_request") else "issue",
                                  answer["state"].lower())
            except LookupFailed as exc:
                self.seen[key] = exc
            except ValueError:
                self.seen[key] = LookupFailed("the answer was not GitHub's shape for an issue or a pull request")
        if isinstance(self.seen[key], LookupFailed):
            raise self.seen[key]
        return self.seen[key]


def last_line(text):
    lines = [ln.strip() for ln in (text or "").splitlines() if ln.strip()]
    return lines[-1][:300] if lines else ""


def pair_findings(text, slug, listed, already, lookup, text_mode):
    """[(key, reason)] for each keyword and number pair naming an open pull request, or an open issue
    the text does not mean to close, or one that could not be looked up (claude-config#2464).

    `listed` is the set of keys GitHub will close (pr mode), or None (text mode, where every issue a
    keyword is followed by counts). Keys in `already` were refused for their sentence and are skipped."""
    text = text or ""
    out = []
    seen = set()
    prev = None
    for m in CLOSING.finditer(text):
        # A keyword inside a longer word ("prefix #12", "unfixed #4") is no keyword to GitHub. The
        # sentence rules above keep their unbounded reading; this rule, which refuses on placement
        # alone, needs the word to start where GitHub's does.
        if m.start() > 0 and (text[m.start() - 1].isalnum() or text[m.start() - 1] == "_"):
            continue
        key = ref_key(m, slug)
        if prev and text.rfind("\n", 0, m.start()) >= prev[0]:
            prev = None
        meant = means_to_close(text, m, prev, text_mode)
        prev = (m.end(), meant)
        if key in already or key in seen:
            continue
        phrase = quote(sentence_before(text, m.start()), m.group(0))
        if listed is not None and key in listed:
            kind, state = "issue", "open"
        elif key[0] is None:
            seen.add(key)
            out.append((key, "cannot tell which repository %s is in, so \"%s\" could not be looked up to tell a pull request from an issue" % (show(key, slug), phrase)))
            continue
        else:
            try:
                kind, state = lookup(key[0], key[1])
            except LookupFailed as exc:
                seen.add(key)
                out.append((key, "could not look up %s#%d (%s), so whether \"%s\" closes a pull request or an open issue is unknown, and unknown is not neither" % (key[0], key[1], exc, phrase)))
                continue
        if state != "open":
            continue
        if kind == "pull request":
            seen.add(key)
            out.append((key, "\"%s\" names pull request %s, and GitHub closes a pull request named after a closing word, so merging this closes it unmerged" % (phrase, show(key, slug))))
        elif not meant and (listed is None or key in listed):
            seen.add(key)
            out.append((key, "\"%s\" puts a closing word before issue %s not at the start of a line or sentence, so it reads as a passing mention, yet GitHub closes the issue on merge" % (phrase, show(key, slug))))
    return out


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    if mode == "text":
        # A slug that is not owner/name is no repository at all: a bare #N then refuses, unlooked up.
        slug = argv[2] if len(argv) > 2 and SLUG.fullmatch(argv[2]) else None
        text = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace").read()
        found = findings(text, None, slug)
        found += pair_findings(text, slug, None, {k for k, _ in found}, Lookup(), True)
        for key, reason in found:
            print("%s: %s" % (show(key, slug), reason))
        return 0
    if mode == "pr" and len(argv) > 2:
        slug = argv[2]
        try:
            view = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
            refs = view["closingIssuesReferences"]
            # A reference whose repository cannot give a whole slug stops the check (RepoSlugError
            # is a ValueError) rather than reading as a pull request that closes nothing.
            closing = {(repo_slug.slug(r["repository"]).lower(), int(r["number"])) for r in refs}
        except (ValueError, KeyError, TypeError) as exc:
            sys.stderr.write("closing-keyword.py: the pull request could not be read: %s\n" % exc)
            return 3
        body = view.get("body") or ""
        found = findings(body, closing, slug)
        found += pair_findings(body, slug, closing, {k for k, _ in found}, Lookup(), False)
        for key, reason in found:
            print("%s: %s" % (show(key, slug), reason))
        return 0
    sys.stderr.write("usage: closing-keyword.py text [<owner/name>] | closing-keyword.py pr <owner/name>\n")
    return 64


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main(sys.argv))
