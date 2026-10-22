#!/usr/bin/env bash
# Block `gh issue create` unless the issue carries a milestone, a priority level and
# at least one category label. Also block gh issue edit and comment, and gh pr create, edit
# and comment, when their --body-file is one the gate cannot read (claude-config#1435).
#
# The rules, the messages and the per-rule overrides all live in issue_field_gate.py.
# This is only the wrapper: read the payload, run the gate, and make a crash visible.
#
# It replaced three separate hooks that shared everything except their rule, which
# also meant three Python processes on every Bash command Claude ran, not just the
# ones filing issues.
#
# A command it cannot read is refused when its text names a command the gate judges, saying
# which quote never closes and where, and passes untouched when it names none
# (claude-config#1485). A --body-file it cannot read in a command it did parse is refused
# (claude-config#1416).
#
# Deliberate overrides, each waiving ONE rule and only for the command it prefixes:
#   SKIP_MILESTONE_CHECK=1 / SKIP_PRIORITY_CHECK=1 / SKIP_CATEGORY_CHECK=1 /
#   SKIP_OPEN_QUESTIONS_CHECK=1 / SKIP_BODY_FILE_CHECK=1 / SKIP_SESSION_LINE_CHECK=1

set -uo pipefail

payload="$(cat)"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A crash here must not block work, but it must not be invisible either: a silent
# failure would leave the gate switched off with everything looking normal.
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
out="$(printf '%s' "$payload" | GATE_DIR="$HERE" python3 "$HERE/issue_field_gate.py" 2>"$err")"
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "ISSUE FIELD GATE DID NOT RUN: require-issue-fields.sh failed (rc=$rc). This issue may be filed without a milestone, a priority or a category. $(tr '\n' ' ' <"$err")" >&2
  exit 0
fi

printf '%s' "$out"
exit 0
