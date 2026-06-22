#!/usr/bin/env bash
# create-milestone.sh — create a GitHub milestone and one issue per phase, all assigned to it.
#
# Usage:
#   create-milestone.sh <owner/name> <plan.json>
#
# plan.json shape:
#   {
#     "title": "Feature name",            # required — becomes the milestone title
#     "description": "markdown body",     # optional — milestone description
#     "due_on": "2026-09-01T00:00:00Z",   # optional — ISO8601 due date
#     "issues": [                          # optional — one GitHub issue each, assigned to the milestone
#       { "title": "Phase 1: ...", "body": "..." }
#     ]
#   }
#
# Set DRY_RUN=1 to print what would happen without calling GitHub.
# Prints: MILESTONE <url>, then ISSUE <url> per issue (or WOULD-CREATE-* lines in dry run).
set -euo pipefail

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

# --- create the milestone ---
if [[ -n "$dry" ]]; then
  echo "WOULD-CREATE-MILESTONE repo=$repo title=$title"
else
  args=(api "repos/$repo/milestones" -f "title=$title" -f "description=$description")
  [[ -n "$due_on" ]] && args+=(-f "due_on=$due_on")
  ms_url="$(gh "${args[@]}" --jq '.html_url')"
  echo "MILESTONE $ms_url"
fi

# --- create one issue per phase, assigned to the milestone ---
n="$(jq '.issues | length // 0' "$plan" 2>/dev/null || echo 0)"
i=0
while [[ "$i" -lt "$n" ]]; do
  it="$(jq -r ".issues[$i].title // empty" "$plan")"
  ib="$(jq -r ".issues[$i].body // \"\"" "$plan")"
  if [[ -z "$it" ]]; then
    i=$((i + 1)); continue
  fi
  if [[ -n "$dry" ]]; then
    echo "WOULD-CREATE-ISSUE repo=$repo milestone=$title title=$it"
  else
    iss_url="$(gh issue create --repo "$repo" --title "$it" --body "$ib" --milestone "$title")"
    echo "ISSUE $iss_url"
  fi
  i=$((i + 1))
done
