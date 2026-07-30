#!/usr/bin/env bash
# Block `gh issue create` unless the issue carries a priority label (priority-p0
# through priority-p4).
#
# Why this exists: on 2026-07-30 Dan looked at a repo's open issues and found the
# priority labels applied to some and not others, with two rival scales (sev-* and
# severity:*) sitting alongside them, so the backlog could not be read by urgency.
# The rule "every issue gets a priority" is written in the skills, but a rule that
# lives only in a prompt is a hope. This gate sees the actual command.
#
# It also carries the scale itself in its refusal, because the moment of being
# blocked is exactly when the levels need to be to hand: p0 broken now, p1 do next,
# p2 normal, p3 nice to have, p4 someday. And it carries the rule about WHO picks:
# when Dan reported the problem himself, he chooses from a picker; when the model
# found it, the model chooses and says so.
#
# Fails OPEN by design, like its milestone sibling: anything it cannot parse exits
# quietly rather than blocking work. It is a completeness gate, not a safety gate,
# and a false block on an unparseable command would teach the override habit.
#
# The command splitting is shared with require-milestone-on-issue.sh via
# gh_issue_scan.py, so the two gates cannot disagree about what counts as a create.
#
# Deliberate override: SKIP_PRIORITY_CHECK=1 gh issue create ... (visible in the
# command, so it cannot happen by accident or go unnoticed in the transcript). It
# is separate from SKIP_MILESTONE_CHECK: waiving one never waives the other.

set -uo pipefail

payload="$(cat)"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

read -r -d '' PROG <<'PY'
import importlib.util
import json
import os
import re
import sys

# The scanner is a sibling file, loaded by its explicit path rather than by name.
# `python3 -c` puts the working directory first on the import path, so importing by
# name would let any gh_issue_scan.py sitting in whatever project the command runs
# from shadow the real one, and the gate would enforce someone else's logic.
#
# A failure here must crash loudly rather than be caught: the wrapper turns a
# non-zero exit into a visible "gate did not run" warning, so a missing scanner can
# never read as a clean pass.
_path = os.path.join(os.environ["GATE_DIR"], "gh_issue_scan.py")
_spec = importlib.util.spec_from_file_location("gh_issue_scan", _path)
if _spec is None or _spec.loader is None:
    raise ImportError("cannot load the shared scanner at %s" % _path)
scan = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(scan)

RAW = sys.stdin.read()

try:
    data = json.loads(RAW)
    command = (data.get("tool_input") or {}).get("command") or ""
except Exception:
    sys.exit(0)

# Anchored: `priority-p10` is not level 1, and `priority` alone is not a level.
LEVEL = re.compile(r"^priority-p[0-4]$", re.IGNORECASE)


def has_priority(args):
    """Does this argument list carry a priority label?"""
    for value in scan.flag_values(args, "--label", "-l"):
        # gh accepts a comma separated list in one --label flag.
        for name in value.split(","):
            if LEVEL.match(name.strip()):
                return True
    return False


try:
    creates = scan.scan_creates(command, override="SKIP_PRIORITY_CHECK=1")
except scan.Unreadable:
    sys.exit(0)  # not ours to judge

offenders = sum(1 for args, waived in creates if not waived and not has_priority(args))

if not offenders:
    sys.exit(0)

reason = (
    "This command would file {c} with no priority label. Every issue carries one, so the "
    "backlog can be read by urgency at a glance.\n\n"
    "The scale:\n"
    "  priority-p0   broken now, drop everything\n"
    "  priority-p1   important, do next\n"
    "  priority-p2   normal, the default for real work\n"
    "  priority-p3   nice to have\n"
    "  priority-p4   someday, maybe never\n\n"
    "Who picks the level:\n"
    "1. If Dan reported this himself (he noticed it while looking at the product and told you), "
    "ASK him with an AskUserQuestion picker and put the meanings above in the option descriptions, "
    "so the scale is in front of him as he chooses. Do not guess on his behalf.\n"
    "2. If you found it yourself (an audit, a sweep, the end of turn issue review), choose the level "
    "and say in one line which you chose and why.\n\n"
    "Then add --label \"priority-pN\" to the create and re-run it. If the five labels do not exist in "
    "the repo yet, create them first (idempotent, safe to re-run):\n"
    "   bash ~/.claude/skills/milestone/ensure-priority-labels.sh \"<owner>/<name>\"\n\n"
    "Priority is the ONLY urgency scale. Do not add a sev-* or severity:* label alongside it: two "
    "scales on one issue is what made the backlog unreadable in the first place.\n\n"
    "If this issue genuinely should not carry a priority (a repo you do not own, a throwaway repo), say "
    "so and re-run with the visible override: SKIP_PRIORITY_CHECK=1 <the same command>."
).format(c=plural_issues(offenders))

json.dump(deny_payload(reason), sys.stdout)
PY

# A crash here must not block work, but it must not be invisible either: a silent
# failure would leave the gate switched off with everything looking normal.
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
out="$(printf '%s' "$payload" | GATE_DIR="$HERE" python3 -c "$PROG" 2>"$err")"
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "PRIORITY GATE DID NOT RUN: require-priority-on-issue.sh failed (rc=$rc). This issue may be filed without a priority label. $(tr '\n' ' ' <"$err")" >&2
  exit 0
fi

printf '%s' "$out"
exit 0
