#!/usr/bin/env bash
# Block `gh issue create` unless the issue carries a milestone, a priority level and
# at least one category label.
#
# The rules, the messages and the per-rule overrides all live in issue_field_gate.py.
# This is only the wrapper: read the payload, run the gate, and make a crash visible.
#
# It replaced three separate hooks that shared everything except their rule, which
# also meant three Python processes on every Bash command Claude ran, not just the
# ones filing issues.
#
# Fails OPEN by design: anything it cannot parse exits quietly rather than blocking
# work. A false block on a command it merely could not read would teach the override
# habit, and the overrides are the one thing that must stay rare.
#
# Deliberate overrides, each waiving ONE rule and only for the command it prefixes:
#   SKIP_MILESTONE_CHECK=1 / SKIP_PRIORITY_CHECK=1 / SKIP_CATEGORY_CHECK=1

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
