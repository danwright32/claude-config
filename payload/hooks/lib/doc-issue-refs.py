#!/usr/bin/env python3
"""Find the lines in a document that say a GitHub issue is still PENDING.

    doc-issue-refs.py <file>...            read the named files
    doc-issue-refs.py --stdin <name>       read one document from stdin, reported under <name>
    doc-issue-refs.py --explain ...        append a tab and the phrase that matched to each row

Prints one row per candidate, and nothing when there are none:

    <file>:<line>:<issue>:<the line, stripped>

where <issue> is a bare number for a `#NNNN` reference and `owner/repo#NNNN` for a full GitHub
issue or pull URL, because a URL can point at a different repository than the one being pushed
and the caller has to ask the right one. Exit 0 either way; the caller decides what a candidate
means. This file NEVER calls gh or touches the network: it answers "which lines make a pending
claim about an issue" and nothing else, so the test can drive it on text alone and the hook
(check-doc-issue-refs.sh) owns the lookups.

Why this exists (claude-config#431): `docs/pii.md` in Slate said "#1041 is the issue for putting a
privacy link and consent copy on the booker", #1041 closed on 2026-08-17, and a month later an
outside reviewer read the doc and reported the gap as open. Nothing anywhere compared what a doc
CLAIMS about an issue with what GitHub knows (L32, L244).

What counts as a pending claim
------------------------------
A SENTENCE is judged, not a line. Markdown prose is hard wrapped, so the reference and the words
that give it its tense are routinely on different lines; each paragraph is joined and split into
sentences first, and the row carries the line the reference sits on. A list item and a table cell
each start a sentence of their own, fenced code is skipped, and so is inline code, because a
`Closes #N` in a quoted commit message and a `#666` colour are not claims about anything.

Every phrase below is ANCHORED to the reference (the issue is the subject of "will", "tracks",
"covers", or the object of "tracked in", "once", "when"). The first draft matched the phrase
anywhere in the sentence, and measured over Slate main on 2026-09-18 that reported 63 rows of which
about 10 were pending claims: "will", "still", "until #N", "covers" and "pending" each turned up
in sentences that merely CITED a finished issue ("Until #1629 it saw only ...", "which is the
#1495 failure itself", "#428 reconcileCancelledBusyBlocks covers windows ..."). Almost every
issue a doc names is closed (48 of 50 distinct references in that sweep), so a loose phrase does
not produce noise, it produces a refusal on nearly every push that touches AGENTS.md. Anchoring
took the sweep to the rows listed in the hook's header, every one of them a claim that the
issue is unfinished.

One veto stands behind the phrases: a reference followed by a past tense verb is a citation of
finished work whatever future word follows it ("#730 added a guard that will fail the build" is
a true statement about a closed issue). A parenthetical citation needs no veto of its own,
because every phrase is anchored to its reference and "(#730) will refuse" has a `)` where the
phrase needs a space. The brief's named false positive, "#1041 added the links", is a past
claim and produces no row.
"""
import re
import sys

# The marker that stands in for a reference once it has been recognised, so the patterns below
# can say "right before the issue" without re-matching the reference's own syntax.
REF = "\x00"
R = REF + r"(?:\d+|[\w./-]+#\d+)"          # one marked reference
ISSUE_WORD = r"(?:issue |ticket |pr |pull request |the )?"

# One list, one reason each. The pattern runs over the lowercased sentence with references
# marked. Add here and nowhere else.
PENDING_PHRASES = [
    (R + r"\**\s+is the (issue|ticket|item|one) (for|that|to|which|where)\b",
     "names the issue as the one that will do the thing"),
    (r"\btracked (in|by|as|under) " + ISSUE_WORD + R,
     "points at where unfinished work is tracked"),
    (ISSUE_WORD + R + r"\**\s+tracks\b",
     "the issue is the tracker for an unfinished thing"),
    (ISSUE_WORD + R + r"\**\s+covers\b",
     "the issue covers work not yet done, in Slate's own idiom"),
    (ISSUE_WORD + R + r"\**\s+(\w+\s+){0,3}will\b",
     "a future tense claim with the issue as its subject"),
    (r"\bwill\s+(\w+\s+){0,4}(in|by|with|under|as|through) " + ISSUE_WORD + R,
     "a future tense claim with the issue as where it happens"),
    (r"\bonce " + ISSUE_WORD + R, "\"once #N ...\" waits on the issue"),
    (r"\bwhen " + ISSUE_WORD + R, "\"when #N ...\" waits on the issue"),
    (R + r"\**\s+(\w+\s+){0,2}(lands|ships|merges|closes)\b",
     "the issue has not landed yet"),
    (R + r"\**\s+(is|remains|stays) (still )?open\b", "a direct claim that it is open"),
    (r"\bopen issue " + R, "a direct claim that it is open"),
    (R + r"\**\s+(is )?(still )?pending\b", "a direct claim that it is pending"),
    (r"\bpending (in|on|as|under) " + ISSUE_WORD + R, "a direct claim that it is pending"),
    (R + r"\**\s+(has|is|was) not yet\b", "a direct claim that it has not happened"),
    (r"\bnot yet\b[^.;]{0,60}\(?" + R, "a direct claim that it has not happened"),
    (r"\bplanned (in|as|under|for) " + ISSUE_WORD + R, "the work is planned, so not done"),
    (r"\bbelongs to " + ISSUE_WORD + R, "the work is assigned to the issue, so not done"),
    (r"\bfiled as " + ISSUE_WORD + R, "the gap is filed, so not closed"),
    (r"\bdeferred to " + ISSUE_WORD + R, "the work was pushed to the issue"),
]
# "see #N" is a pointer, not a claim, so it counts only beside a future tense word.
SEE_REF = re.compile(r"\bsee " + ISSUE_WORD + R)
FUTURE_WORDS = re.compile(r"\b(will|once|when|until|planned|pending|later|not yet|to ?do)\b")

# A reference in a PAST position is a citation of something already done. The issue as the
# subject of a past tense verb, or inside parentheses that make no pending claim of their own.
PAST_VERBS = (
    "added|fixed|closed|shipped|landed|merged|built|made|put|moved|removed|replaced|rebuilt|"
    "introduced|wired|found|reported|measured|settled|retired|deleted|renamed|changed|"
    "widened|narrowed|reversed|split|folded|routed|gave|took|brought|kept|left|did|was|were|"
    "had|has|have|corrected|confirmed|proved|showed|opened|caught|dropped|stranded|cost|armed"
)
PAST_AFTER_REF = re.compile(REF + r"(\d+|[\w./-]+#\d+)\)?\**,? (" + PAST_VERBS + r")\b")

ISSUE_REF = re.compile(
    r"(?<![\w/&])#(\d{1,5})(?![\w-])"
    r"|https?://github\.com/([\w.-]+/[\w.-]+)/(?:issues|pull)/(\d+)"
)
FENCE = re.compile(r"^\s*(```|~~~)")
LIST_ITEM = re.compile(r"^\s*([-*+]|\d+[.)])\s+|^\s*\|")
INLINE_CODE = re.compile(r"`[^`\n]*`")
SENTENCE_END = re.compile(r"(?<=[.!?])\s+(?=[A-Z*`#(\"'\[\x00])|\s*\|\s*")


def paragraphs(lines):
    """Yield (start_index, [lines]) for each run of prose lines, skipping fenced code. A list
    item or table row starts a run of its own, since its neighbours are not its sentence."""
    in_fence = False
    buf, start = [], 0
    for i, raw in enumerate(lines):
        if FENCE.match(raw):
            in_fence = not in_fence
            if buf:
                yield start, buf
                buf = []
            continue
        if in_fence:
            continue
        if raw.strip() == "" or (buf and LIST_ITEM.match(raw)):
            if buf:
                yield start, buf
                buf = []
            if raw.strip() == "":
                continue
        if not buf:
            start = i
        buf.append(raw)
    if buf:
        yield start, buf


def blank_inline_code(text):
    """Inline code keeps its length (so offsets still map to lines) and loses its content."""
    return INLINE_CODE.sub(lambda m: " " * len(m.group(0)), text)


def pending_refs(sent_lc):
    """The references a pending phrase is ABOUT, as {offset_in_sentence: reason}.

    Only the reference inside the phrase's own match counts, never every reference in the
    sentence: "Issue #246 tracks committing a benchmark (noted in #246 and #240)" is a pending
    claim about the first #246 and a citation of the other two."""
    found = {}
    for pat, reason in PENDING_PHRASES:
        for m in re.finditer(pat, sent_lc):
            for r in re.finditer(REF, sent_lc[m.start():m.end()]):
                found.setdefault(m.start() + r.start(), reason)
    if FUTURE_WORDS.search(sent_lc):
        for m in SEE_REF.finditer(sent_lc):
            for r in re.finditer(REF, sent_lc[m.start():m.end()]):
                found.setdefault(m.start() + r.start(), "\"see #N\" beside a future tense word")
    return found


def in_past_position(sent_lc, offset):
    """Is the reference at this offset the subject of a past tense verb? Then the sentence is a
    citation of finished work, whatever future word follows ("#730 added a guard that will
    fail the build")."""
    return PAST_AFTER_REF.match(sent_lc, offset) is not None


# A file that DECLARES itself a dated record, which is not scanned at all.
#
# The whole file is read on purpose, because a claim goes stale by the world moving
# rather than by anybody editing it. That is right for a doc describing the CURRENT
# state and wrong for an append only diary, where an old entry IS the record of what was
# true that day: the remedy this gate prints, rewrite the sentence, would mean editing
# history to say something nobody knew at the time.
#
# Measured 2026-09-21 in danwright32/downbeat: six pushes in one session, every one
# refused, every time on the same six paragraphs of docs/PROJECT-LOG.md that the push had
# not touched, written weeks earlier by other commits. The override was used six times,
# which is how a gate stops being read (L36).
#
# DECLARED, not inferred. A marker somebody has to write is a decision, and a rule that
# guessed from prose would silently exempt any doc that happened to word itself that way,
# which is the exemption nobody chose (L250).
#
# Near the TOP only. A diary grows for years, and a marker further down would declare the
# file historical from the middle while every reader above it believes the check ran.
DATED_RECORD = "<!-- doc-issue-refs: dated-record -->"
DATED_RECORD_WITHIN_LINES = 20


def is_dated_record(text):
    """Whether this file has opted out, by declaring itself near its top."""
    head = text.split("\n")[:DATED_RECORD_WITHIN_LINES]
    return any(DATED_RECORD in line for line in head)


def scan(name, text, explain=False):
    if is_dated_record(text):
        return []
    rows = []
    lines = text.split("\n")
    for start, para in paragraphs(lines):
        parts, owner = [], []
        for k, raw in enumerate(para):
            s = raw.strip()
            parts.append(s)
            owner.extend([start + k] * (len(s) + 1))
        joined = blank_inline_code(" ".join(parts))
        # References are found on the joined text, so each one knows its own line; the marked
        # copy the phrases run over is built from the same matches, so the two cannot disagree.
        refs = list(ISSUE_REF.finditer(joined))
        if not refs:
            continue
        marked, prev, ref_ids, ref_lines = "", 0, [], []
        for m in refs:
            issue = m.group(1) or (m.group(2) + "#" + m.group(3))
            marked += joined[prev:m.start()] + REF + issue
            ref_ids.append(issue)
            ref_lines.append(owner[m.start()] + 1)
            prev = m.end()
        marked += joined[prev:]
        bounds, prev = [], 0
        for m in SENTENCE_END.finditer(marked):
            if m.start() > prev:
                bounds.append((prev, m.start()))
            prev = m.end()
        bounds.append((prev, len(marked)))
        for a, b in bounds:
            sent = marked[a:b].lower()
            if REF not in sent:
                continue
            for offset, reason in sorted(pending_refs(sent).items()):
                if in_past_position(sent, offset):
                    continue
                # Which reference of the paragraph this is: the count of markers before it.
                idx = marked[: a + offset].count(REF)
                issue, line_no = ref_ids[idx], ref_lines[idx]
                row = f"{name}:{line_no}:{issue}:{lines[line_no - 1].strip()}"
                if explain:
                    row += f"\t[{reason}]"
                rows.append(row)
    return rows


def main(argv):
    args = list(argv)
    explain = "--explain" in args
    if explain:
        args.remove("--explain")
    out = []
    if args and args[0] == "--stdin":
        name = args[1] if len(args) > 1 else "(stdin)"
        out.extend(scan(name, sys.stdin.read(), explain))
    else:
        for path in args:
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError as e:
                print(f"{path}:0:0:could not read: {e}", file=sys.stderr)
                continue
            out.extend(scan(path, text, explain))
    for row in out:
        print(row)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
