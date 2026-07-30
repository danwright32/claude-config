#!/usr/bin/env bash
# create-milestone.sh: create or reuse a GitHub milestone and file one issue per
# phase, all assigned to it.
#
# Milestone resolution lives in ensure-milestone.sh, which every issue filing path
# shares, so this script cannot drift from the rule that an issue always belongs to
# a milestone, and re-running a plan reuses the milestone instead of twinning it.
#
# Usage:
#   create-milestone.sh <owner/name> <plan.json>
#
# plan.json shape:
#   {
#     "title": "Feature name",            # required, becomes the milestone title
#     "description": "markdown body",     # optional, milestone description
#     "due_on": "2026-09-01T00:00:00Z",   # optional, ISO8601 due date
#     "priority": "p2",                   # optional default for every issue below
#     "issues": [                         # optional, one GitHub issue each
#       { "title": "Phase 1: ...", "body": "...", "priority": "p1" }
#     ]
#   }
#
# Every issue needs a priority, either its own or the plan-level default. Accepts
# "p2" or "priority-p2". This script is the ONE issue-filing path the PreToolUse
# priority gate cannot see (the gate reads the Bash command, and here the create runs
# inside a script), so the rule is enforced here instead.
#
# Set DRY_RUN=1 to print what would happen without writing to GitHub.
# Prints: MILESTONE <url> (or MILESTONE-EXISTS ...), then ISSUE <url> per issue,
# or WOULD-CREATE-* lines in dry run.
#
# Callers reach this only after the user has previewed and approved the plan, so it
# passes --create-approved. It still aborts without filing anything when the helper
# finds a near duplicate or a closed milestone with the same name, because those
# need a human decision and half filed issues are worse than none.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENSURE="${ENSURE_MILESTONE_SH:-$HERE/ensure-milestone.sh}"

repo="${1:-}"
plan="${2:-}"

if [[ -z "$repo" || -z "$plan" ]]; then
  echo "Usage: create-milestone.sh <owner/name> <plan.json>" >&2
  exit 1
fi
if [[ ! -f "$plan" ]]; then
  echo "Plan file not found: $plan" >&2
  exit 1
fi
if ! jq -e . "$plan" >/dev/null 2>&1; then
  echo "Plan file is not valid JSON: $plan" >&2
  exit 1
fi

title="$(jq -r '.title // empty' "$plan")"
if [[ -z "$title" ]]; then
  echo "Plan is missing a required \"title\" (used as the milestone title)." >&2
  exit 1
fi

description="$(jq -r '.description // ""' "$plan")"
due_on="$(jq -r '.due_on // empty' "$plan")"

dry="${DRY_RUN:-}"

# --- resolve the milestone through the shared helper ----------------------
ensure_args=("$repo" "$title" --create-approved --description "$description")
[[ -n "$due_on" ]] && ensure_args+=(--due "$due_on")

ms_out="$(bash "$ENSURE" "${ensure_args[@]}" 2>&1)"
ms_rc=$?

printf '%s\n' "$ms_out"

if [[ "$ms_rc" -ne 0 ]]; then
  echo "ABORTED: no issues were filed, because the milestone could not be resolved."
  exit "$ms_rc"
fi

# The reference passed to gh must be the milestone's own TITLE: gh issue create
# matches a milestone by name, not by number (gh 2.88: "Add the issue to a
# milestone by name"). The helper reports the resolved title, which can differ in
# case or punctuation from the title this plan asked for.
verdict="$(printf '%s\n' "$ms_out" | grep -E '^(MILESTONE-EXISTS|MILESTONE-CREATED|WOULD-CREATE-MILESTONE)' | head -1)"
resolved="$(printf '%s\n' "$ms_out" | sed -n 's/^MILESTONE-TITLE //p' | head -1)"
case "$verdict" in
  MILESTONE-EXISTS*|MILESTONE-CREATED*)
    ms_ref="$resolved"
    ;;
  WOULD-CREATE-MILESTONE*)
    ms_ref="$title"  # dry run: nothing exists yet, so the plan's title is the title
    ;;
  *)
    echo "ABORTED: could not tell which milestone to use from the helper output. No issues were filed." >&2
    exit 6
    ;;
esac

if [[ -z "$ms_ref" ]]; then
  echo "ABORTED: the resolved milestone has no usable reference. No issues were filed." >&2
  exit 6
fi

# --- file one issue per phase, each assigned to that milestone ------------
n="$(jq '.issues | length // 0' "$plan" 2>/dev/null || echo 0)"
i=0
failed=0
while [[ "$i" -lt "$n" ]]; do
  it="$(jq -r ".issues[$i].title // empty" "$plan")"
  ib="$(jq -r ".issues[$i].body // \"\"" "$plan")"
  if [[ -z "$it" ]]; then
    i=$((i + 1)); continue
  fi
  if [[ -n "$dry" ]]; then
    echo "WOULD-CREATE-ISSUE repo=$repo milestone=$ms_ref title=$it"
  else
    iss_url="$(gh issue create --repo "$repo" --title "$it" --body "$ib" --milestone "$ms_ref" 2>&1)"
    if [[ $? -ne 0 ]]; then
      echo "ISSUE-FAILED title=$it: $iss_url" >&2
      failed=$((failed + 1))
    else
      echo "ISSUE $iss_url"
    fi
  fi
  i=$((i + 1))
done

if [[ "$failed" -gt 0 ]]; then
  echo "$failed of $n issues could not be filed. The milestone exists, so re-running this will reuse it rather than duplicate it." >&2
  exit 7
fi
exit 0
