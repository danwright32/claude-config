#!/usr/bin/env python3
"""Build the JSON payload a Stop hook emits, as a POINTER rather than a wall of text.

Usage:
  review-reason.py --instruction <path> --label <text>
                   [--findings <path>] [--extra <line>]... [--transcript <path>]

Why this exists. A Stop hook hands its instruction to Claude through the payload's
`reason`, and `reason` is printed to Dan verbatim. Both Stop hooks used to carry
their entire instruction there, about 7,000 characters each, and the issue review
appended the spooled subagent findings on top of that. All of it was addressed to
Claude and all of it landed on Dan's screen. His words, 2026-08-31: "I think
showing this all is unnecessary and ugly".

So the instruction lives in a file and this builds a short pointer to it. The
property that matters is that the reason does not grow with what is pending:
a pointer that carries its target is the same defect wearing a different shape.
test-review-reason.sh holds it to a budget against a 50,000 character findings
file rather than a tidy one.

WHAT STAYS IN THE REASON AND WHY. Findings go in the file. Anything the hook
SETTLES on the strength of having reported it stays here, in the text Dan
actually sees. The issue review files its harvest failure records away, and
restarts the week on its held-back count, because those "went out with this
review"; if the only copy were in a file nobody opened, the report would be lost
and the next one silenced. That is what `--extra` is for, and it is why the
counts below are computed rather than left to the file.

Exits non-zero ONLY when it cannot produce a payload at all. Callers fall back to
a static payload of their own, because losing the whole review is worse than
losing the pointer's detail.

READ ONCE PER SESSION. Every fire used to send Claude back to read the whole
instruction, and each read stayed in the transcript where every later request
re-read it (the two instruction files' reads were 0.93% of every token read in
Slate sessions, Oct 1 to 15 2026). Given --transcript, the full "read it now"
pointer goes out only when the session has not read the file since its last
compaction, or the file changed after that read; otherwise a short pointer at the
copy already in context. Every way of failing to tell (no transcript, an
unreadable line, a timestamp that will not parse) falls toward the full pointer,
because a review run from a copy that is not in context is the worse failure.
What counts as a read is a Read of exactly that file, or a Bash segment led by a
command that prints it (cat, sed, head, tail, awk, less, more, bat); a listing,
a count, an existence test, a diff or an edit only names it. Judged from the
record rather than from a marker this helper would have to keep in step with
compactions.

Seam: CLAUDE_REVIEW_REASON_FORCE_FAIL makes this fail on purpose, so that caller
fallback is tested rather than assumed.
"""
import argparse
import json
import os
import re
import sys
from datetime import datetime


def count_pending(text):
    """Count what the spool's renderer produced, by the prefixes it writes.

    The renderer is issue_spool_pending in lib/issue-spool.sh, and this reads its
    OUTPUT rather than reimplementing its predicate, so the two cannot drift about
    what a finding is (L107).

    A line matching none of the known prefixes is COUNTED as an "other", never
    dropped. Silently ignoring one would understate what is waiting, and an
    understatement is indistinguishable from a quiet spool (L98).
    """
    findings = failures = other = 0
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("FINDING ("):
            findings += 1
        elif line.startswith("...and ") and "more findings" in line:
            # The renderer's own truncation line. Its number is the findings it
            # held back, so they are counted here rather than reported as an
            # unrecognised line.
            head = line[len("...and "):].split(" ", 1)[0]
            findings += int(head) if head.isdigit() else 1
        elif line.startswith("HARVEST FAILED"):
            failures += 1
        else:
            other += 1
    return findings, failures, other


def plural(n, one, many):
    return "%d %s" % (n, one if n == 1 else many)


def phrase(findings, failures, other):
    parts = []
    if findings:
        parts.append(plural(findings, "finding", "findings"))
    if failures:
        parts.append(plural(failures, "harvest failure", "harvest failures"))
    if other:
        parts.append(plural(other, "other line", "other lines"))
    if not parts:
        return ""
    if len(parts) == 1:
        return parts[0]
    return ", ".join(parts[:-1]) + " and " + parts[-1]


def _stamp(value):
    """An ISO transcript timestamp as epoch seconds, or None when it will not parse."""
    if not isinstance(value, str):
        return None
    try:
        return datetime.strptime(value.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S.%f%z").timestamp()
    except ValueError:
        try:
            return datetime.strptime(value.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S%z").timestamp()
        except ValueError:
            return None


# Commands that print a file's text. Naming the file is not reading it: ls, grep -c, test -f, a
# diff or an Edit leave the text out of context, so only a segment led by one of these counts.
PRINTERS = {"cat", "sed", "head", "tail", "awk", "less", "more", "bat"}
SEGMENT_SPLIT = re.compile(r"\|\||&&|[|;\n]")


def _is_read(item, spellings, pattern):
    """A Read of exactly the file, or a Bash segment that prints it."""
    name = item.get("name")
    inp = item.get("input") or {}
    if name == "Read":
        return inp.get("file_path") in spellings
    if name != "Bash":
        return False
    for segment in SEGMENT_SPLIT.split(str(inp.get("command") or "")):
        if not pattern.search(segment):
            continue
        words = segment.split()
        while words and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):
            words.pop(0)  # leading VAR=value assignments
        if words and os.path.basename(words[0]) in PRINTERS:
            return True
    return False


def read_this_session(transcript, instruction):
    """True only when the transcript shows a read of the CURRENT instruction since the last compaction."""
    if not transcript:
        return False
    home = os.path.expanduser("~")
    spellings = {instruction}
    if home and instruction.startswith(home + "/"):
        spellings.add("~" + instruction[len(home):])
    # The path must end where the name ends, so foo.md.bak or foo.md-notes is not a read of foo.md.
    pattern = re.compile("(?:%s)(?![A-Za-z0-9_.-])" % "|".join(re.escape(s) for s in sorted(spellings)))
    last = None
    try:
        with open(transcript, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if "compact_boundary" in line:
                    try:
                        if json.loads(line).get("subtype") == "compact_boundary":
                            last = None
                            continue
                    except Exception:
                        pass
                if not any(s in line for s in spellings):
                    continue
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                if entry.get("type") != "assistant":
                    continue
                content = (entry.get("message") or {}).get("content") or []
                if not isinstance(content, list):
                    continue
                for item in content:
                    if isinstance(item, dict) and item.get("type") == "tool_use" \
                            and _is_read(item, spellings, pattern):
                        # A read whose time cannot be told is no evidence of having the current file.
                        last = _stamp(entry.get("timestamp"))
    except OSError:
        return False
    if last is None:
        return False
    try:
        return os.path.getmtime(instruction) <= last
    except OSError:
        return False


def build_reason(instruction, label, findings_path, extras, transcript=""):
    if not os.path.isfile(instruction):
        # Loud, and its own message. A half applied sync on the other Mac leaves
        # the hook present and its instruction absent, and staying silent there
        # is indistinguishable from a turn with nothing to review (L11, L98).
        return (
            "%s CANNOT RUN: its instruction file is missing at %s. Do not invent a "
            "review from this line. Tell Dan that his Claude config looks half applied "
            "on this machine, and that running `claude-sync pull` should restore it."
            % (label, instruction)
        )

    if read_this_session(transcript, instruction):
        reason = (
            "%s. Follow %s again; you read it earlier this session. "
            "Re-read it only if it is no longer in your context." % (label, instruction)
        )
    else:
        reason = "%s. Read %s now and follow it exactly. This line only points at it." % (label, instruction)

    if findings_path:
        try:
            with open(findings_path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except Exception as exc:
            reason += (
                "\n\nSUBAGENT FINDINGS: something is waiting but the file holding it could "
                "not be read at %s (%s). Say so rather than reporting that nothing was found."
                % (findings_path, exc)
            )
            return reason
        counts = phrase(*count_pending(text))
        if counts:
            reason += (
                "\n\nSUBAGENT FINDINGS: %s, waiting in %s. They were harvested from "
                "subagents that finished for this project, so they are NOT in your "
                "context. Read that file and handle them as the instruction says."
                % (counts, findings_path)
            )

    for extra in extras:
        if extra and extra.strip():
            reason += "\n\n" + extra.strip()

    return reason


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--instruction", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--findings", default="")
    ap.add_argument("--extra", action="append", default=[])
    ap.add_argument("--transcript", default="")
    args = ap.parse_args()

    if os.environ.get("CLAUDE_REVIEW_REASON_FORCE_FAIL"):
        print("review-reason: failing on purpose (test seam)", file=sys.stderr)
        return 1

    payload = {
        "decision": "block",
        "reason": build_reason(args.instruction, args.label, args.findings, args.extra, args.transcript),
    }
    print(json.dumps(payload))
    return 0


if __name__ == "__main__":
    sys.exit(main())
