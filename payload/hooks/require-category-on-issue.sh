#!/usr/bin/env bash
# Block `gh issue create` unless the issue says what it is ABOUT: at least one label
# that is not the priority.
#
# Why this exists: on 2026-07-30 Dan settled the model for organising issues. A
# milestone is the feature the work ships with, priority is how urgent it is, and the
# category (what the issue is about) is a label, because an issue is routinely about
# more than one thing at once and can hold only one milestone. All three are required
# on every issue.
#
# What this gate deliberately does NOT do is police WHICH categories exist. Dan's
# words: "it does need category on every issue, and it can be multiple. I just don't
# want to restrict what those categories are." So the check is presence, not
# membership: any label that is not a priority level counts, including one invented
# for this issue. A closed vocabulary would go stale and start forcing bad fits.
#
# Fails OPEN by design, like its two siblings: anything it cannot parse exits quietly
# rather than blocking work. It is a completeness gate, not a safety gate.
#
# The command splitting is shared with the milestone and priority gates via
# gh_issue_scan.py, so the three cannot disagree about what counts as a create.
#
# Deliberate override: SKIP_CATEGORY_CHECK=1 gh issue create ... Separate from
# SKIP_MILESTONE_CHECK and SKIP_PRIORITY_CHECK: waiving one never waives another,
# because each answers a different question about the issue.

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

# Anchored, so `priority-review` and `priority-p9` are ordinary labels: only the five
# real levels are excluded from counting as a category.
LEVEL = re.compile(r"^priority-p[0-4]$", re.IGNORECASE)


def has_category(args):
    """Does this argument list carry any label that is not a priority level?"""
    for value in scan.flag_values(args, "--label", "-l"):
        # gh accepts a comma separated list in one --label flag.
        for name in value.split(","):
            name = name.strip()
            if name and not LEVEL.match(name):
                return True
    return False


try:
    creates = scan.scan_creates(command, override="SKIP_CATEGORY_CHECK=1")
except scan.Unreadable:
    sys.exit(0)  # not ours to judge

offenders = sum(1 for args, waived in creates if not waived and not has_category(args))

if not offenders:
    sys.exit(0)

reason = (
    "This command would file {c} with no category label. Every issue says what it is ABOUT, so the "
    "backlog can be filtered by area and not just by urgency.\n\n"
    "Add at least one label describing the issue, alongside its priority. Apply as many as genuinely "
    "apply: an issue is routinely about more than one thing, and an accessibility fix that is also tech "
    "debt should carry both.\n\n"
    "A good starting point, ONE of these for what kind of work it is:\n"
    "  bug   enhancement   tech-debt   documentation\n"
    "and ANY of these for what it touches:\n"
    "  accessibility   ui-ux   performance   security   data-integrity   error-handling\n"
    "  monitoring   analytics   ci-hygiene   test-coverage   onboarding   deployment\n\n"
    "Those are a starting point and not a fixed list. Two rules for going outside it:\n"
    "1. Read the repo's own labels first and prefer one that already exists over a near synonym of it "
    "(if the repo says `ux`, use `ux`, not `ui-ux`):\n"
    "   gh label list --limit 100\n"
    "2. If nothing covers this issue, create a label rather than forcing a bad fit or leaving the issue "
    "bare. Keep it short, kebab-case and reusable:\n"
    "   gh label create <name> --color <hex> --description \"<what it means>\"\n\n"
    "Never apply `claude-suggested` or any label attributing the issue to Claude or AI. Never apply "
    "`sev-*` or `severity:*`: priority is the only urgency scale. The full rule is in "
    "~/.claude/skills/milestone/NAMING.md.\n\n"
    "If this issue genuinely should not carry one (a repo you do not own, a throwaway repo), say so and "
    "re-run with the visible override: SKIP_CATEGORY_CHECK=1 <the same command>."
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
  echo "CATEGORY GATE DID NOT RUN: require-category-on-issue.sh failed (rc=$rc). This issue may be filed without a category label. $(tr '\n' ' ' <"$err")" >&2
  exit 0
fi

printf '%s' "$out"
exit 0
