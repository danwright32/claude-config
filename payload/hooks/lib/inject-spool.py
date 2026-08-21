#!/usr/bin/env python3
"""Fold spooled subagent findings into the issue review's payload.

Usage: cat payload.json | inject-spool.py <path-to-pending-text-file>

The pending text arrives as a FILE, not as an argument. Passed as one argv
element it is bounded by ARG_MAX (1 MiB on macOS), and the spool has no
natural size limit, so a busy project would eventually fail the exec and the
review would silently stop happening.

The review's instruction stays a single static heredoc in the hook, so it can go
on being checked as one literal block; this only appends to its `reason`. If the
pending text is empty or the file is unreadable, the payload passes through
untouched, because a review without the spool text is worth far more than no
review at all.

Exits non-zero only when the PAYLOAD itself does not parse. The caller is
expected to fall back to the payload it already has.

Seam: CLAUDE_INJECT_SPOOL_FORCE_FAIL makes this fail on purpose, so the caller's
fallback can be tested rather than assumed.
"""
import json
import os
import sys

PREAMBLE = (
    "\n\nSUBAGENT FINDINGS, ALREADY COLLECTED. Subagents that ran for this project "
    "left the observations below. They were harvested from each agent's own "
    "transcript when it finished, so they are NOT in your context and you cannot "
    "rediscover them by thinking harder: treat this list as the input it is. Fold "
    "them into section 1 alongside anything you found yourself, number them in the "
    "same 1.x sequence, and put them in the SAME picker. Judge them against the "
    "same quality bar you apply to your own ideas and drop the ones that do not "
    "clear it, saying in one line how many you dropped. A line reading HARVEST "
    "FAILED is not a finding: it means one agent could not be read at all, so say "
    "so plainly rather than reporting that agent as having found nothing. There is "
    "nothing you or I can do about one, and showing it to you is what files it "
    "away, so it will not come back. A line "
    "reading REPLY COULD NOT BE READ means the harvest ran but its answer could "
    "not be parsed, so anything that agent found was not captured; say that too.\n\n"
    "AFTER the picker is answered, and only then, run this to file them away so "
    "they are not offered again:\n"
    "  bash ~/.claude/hooks/lib/issue-spool.sh clear \"$PWD\"\n"
    "Run it whether I chose to file every item or none of them: my answer is what "
    "settles them, not whether an issue was created. If you skip it they come back "
    "at the next review, which is the safe direction to fail and still worth not "
    "doing twice.\n\n"
    "THE FINDINGS:\n"
)


def main():
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
    except Exception as exc:
        print("inject-spool: payload does not parse: %s" % exc, file=sys.stderr)
        return 1

    if os.environ.get("CLAUDE_INJECT_SPOOL_FORCE_FAIL"):
        print("inject-spool: failing on purpose (test seam)", file=sys.stderr)
        return 1

    pending = ""
    if len(sys.argv) > 1 and sys.argv[1]:
        try:
            with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as fh:
                pending = fh.read()
        except Exception:
            pending = ""

    if pending.strip():
        payload["reason"] = (payload.get("reason") or "") + PREAMBLE + pending.strip()

    print(json.dumps(payload))
    return 0


if __name__ == "__main__":
    sys.exit(main())
