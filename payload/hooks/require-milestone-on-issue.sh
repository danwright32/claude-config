#!/usr/bin/env bash
# Block `gh issue create` unless the issue is assigned to a milestone.
#
# Why this exists: on 2026-07-29 Dan went through every project by hand attaching
# orphaned issues to milestones. The rule "always give an issue a milestone" was
# written in the issue review prompt and in CLAUDE.md, but a rule that lives only
# in a prompt is a hope: the ad hoc creates (the ones typed on request, mid flow)
# had no milestone at all. So the check moves out of the model's memory and into a
# gate that sees the actual command.
#
# Fails OPEN by design: anything it cannot parse exits quietly rather than
# blocking work. It is a completeness gate, not a safety gate, and a false block
# on an unparseable command would teach the override habit.
#
# The milestone must belong to the create command itself, in the same shell
# segment. Reading the whole command string would let a `--milestone` sitting on a
# neighbouring command satisfy the check.
#
# The command splitting is shared with require-priority-on-issue.sh via
# gh_issue_scan.py, so the two gates cannot disagree about what counts as a create.
#
# Deliberate override: SKIP_MILESTONE_CHECK=1 gh issue create ... (visible in the
# command, so it cannot happen by accident or go unnoticed in the transcript).

set -uo pipefail

payload="$(cat)"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

read -r -d '' PROG <<'PY'
import importlib.util
import json
import os
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


def has_milestone(args):
    """Does this argument list name a non-empty milestone?"""
    return any(v.strip() for v in scan.flag_values(args, "--milestone", "-m"))


try:
    creates = scan.scan_creates(command, override="SKIP_MILESTONE_CHECK=1")
except scan.Unreadable:
    sys.exit(0)  # not ours to judge

offenders = sum(1 for args, waived in creates if not waived and not has_milestone(args))

if not offenders:
    sys.exit(0)

reason = (
    "This command would file {c} with no milestone. Every issue belongs to a "
    "milestone, so the backlog stays grouped by the work it serves.\n\n"
    "Do this instead:\n"
    "1. Read the repo's open milestones: gh api \"repos/<owner>/<name>/milestones?state=open&per_page=100\" "
    "--jq '.[] | \"#\\(.number) \\(.title)\"'\n"
    "2. If one fits, add --milestone \"<title>\" to the create command and re-run it.\n"
    "3. If none fits, do NOT invent one silently. Resolve it through the shared helper, which reuses a "
    "match, refuses to create a near duplicate, and only creates with explicit approval:\n"
    "   bash ~/.claude/skills/milestone/ensure-milestone.sh \"<owner>/<name>\" \"<milestone title>\"\n"
    "   Then ask the user via an AskUserQuestion picker before creating anything new, offering the closest "
    "existing milestones alongside the proposed new one, and re-run the helper with --create-approved once "
    "they choose.\n\n"
    "A milestone title is a CATEGORY of work, not a narrative sentence: Accessibility, UI/UX, Monitoring "
    "and alerting, Analytics, Tech debt and CI hygiene. The full rule, with examples, is in "
    "~/.claude/skills/milestone/NAMING.md.\n\n"
    "If this issue genuinely should not have a milestone (a repo you do not own, a throwaway repo), say so "
    "and re-run with the visible override: SKIP_MILESTONE_CHECK=1 <the same command>."
).format(c=scan.plural_issues(offenders))

json.dump(scan.deny_payload(reason), sys.stdout)
PY

# A crash here must not block work, but it must not be invisible either: a silent
# failure would leave the gate switched off with everything looking normal.
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
out="$(printf '%s' "$payload" | GATE_DIR="$HERE" python3 -c "$PROG" 2>"$err")"
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "MILESTONE GATE DID NOT RUN: require-milestone-on-issue.sh failed (rc=$rc). This issue may be filed without a milestone. $(tr '\n' ' ' <"$err")" >&2
  exit 0
fi

printf '%s' "$out"
exit 0
