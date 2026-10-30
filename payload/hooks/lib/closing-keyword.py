#!/usr/bin/env python3
"""Find a closing keyword GitHub will honour for an issue the text says it is NOT closing (L1018).

    closing-keyword.py text          any text on stdin (a command, a PR body, a commit message)
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

Two hooks ask this, so the rule is the same where text is written and where a pull request merges:
check-closing-keyword.sh (a pull request or commit being written) and check-closing-merge.sh (the
body GitHub holds, at merge, claude-config#1550).
"""
import json
import re
import io
import sys

KEYWORD = r"(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)"
# An issue reference in any form GitHub itself honours: the full URL, owner/repo#12, or #12.
REF = (r"(?:https?://[^\s/]+/(?P<{p}uo>[\w.-]+)/(?P<{p}un>[\w.-]+)/issues/(?P<{p}n3>\d+)"
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


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    if mode == "text":
        for key, reason in findings(io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace").read(), None, None):
            print("%s: %s" % (show(key, None), reason))
        return 0
    if mode == "pr" and len(argv) > 2:
        slug = argv[2]
        try:
            view = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
            refs = view["closingIssuesReferences"]
            closing = {(("%s/%s" % (r["repository"]["owner"]["login"], r["repository"]["name"])).lower(),
                        int(r["number"])) for r in refs}
        except (ValueError, KeyError, TypeError) as exc:
            sys.stderr.write("closing-keyword.py: the pull request could not be read: %s\n" % exc)
            return 3
        for key, reason in findings(view.get("body") or "", closing, slug):
            print("%s: %s" % (show(key, slug), reason))
        return 0
    sys.stderr.write("usage: closing-keyword.py text | closing-keyword.py pr <owner/name>\n")
    return 64


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main(sys.argv))
