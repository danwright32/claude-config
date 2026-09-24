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
#     "labels": ["enhancement"],          # optional default for every issue below
#     "issues": [                         # optional, one GitHub issue each
#       { "title": "Phase 1: ...", "body": "...", "priority": "p1",
#         "labels": ["tech-debt", "accessibility"] }
#     ]
#   }
#
# Every issue needs a priority AND at least one category label, either its own or the
# plan-level default. Priority accepts "p2" or "priority-p2". Categories are not
# restricted to any vocabulary: any label counts, as long as it is not just a priority
# level. Apply as many as genuinely apply.
#
# This script is the ONE issue-filing path the PreToolUse gates cannot see (they read
# the Bash command, and here the create runs inside a script), so both rules are
# enforced here instead.
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

# --- every issue needs a priority, checked BEFORE anything is written ----------
# Refusing beats defaulting. A silent default is how the priority labels became
# meaningless in the first place, and this runs before the milestone is touched so a
# plan missing a level files nothing at all rather than half of itself.
default_priority="$(jq -r '.priority // empty' "$plan")"
n_issues="$(jq '(.issues // []) | length' "$plan")"

# labels_for <index> : the issue's own labels, else the plan-level default, one per line
labels_for() {
  local n="$1" out
  out="$(jq -r "(.issues[$n].labels // []) | .[]" "$plan" 2>/dev/null)"
  [[ -z "$out" ]] && out="$(jq -r '(.labels // []) | .[]' "$plan" 2>/dev/null)"
  printf '%s' "$out"
}

# A category is any label that is not just a priority level, because the vocabulary is
# deliberately open: Dan restricted the levels, not the categories.
has_category() {
  local l
  while IFS= read -r l; do
    [[ -z "$l" ]] && continue
    if [[ ! "$l" =~ ^priority-[pP][0-4]$ ]]; then return 0; fi
  done <<<"$1"
  return 1
}

missing_priority=""
missing_category=""
i=0
while [[ "$i" -lt "$n_issues" ]]; do
  it="$(jq -r ".issues[$i].title // empty" "$plan")"
  lvl="$(jq -r ".issues[$i].priority // empty" "$plan")"
  [[ -z "$lvl" ]] && lvl="$default_priority"
  # "p2" and "priority-p2" are both natural to write by hand, so accept either.
  [[ "$lvl" =~ ^[pP][0-4]$ ]] && lvl="priority-${lvl}"
  if [[ ! "$lvl" =~ ^priority-[pP][0-4]$ ]]; then
    missing_priority="$missing_priority  \"${it:-<untitled issue $i>}\": ${lvl:-(none given)}"$'\n'
  fi
  if ! has_category "$(labels_for "$i")"; then
    missing_category="$missing_category  \"${it:-<untitled issue $i>}\""$'\n'
  fi
  i=$((i + 1))
done

if [[ -n "$missing_priority" ]]; then
  echo "MISSING-PRIORITY every issue needs a priority level, and these do not have a valid one:" >&2
  printf '%s' "$missing_priority" >&2
  echo "Add \"priority\" to each issue in the plan, or a plan-level \"priority\" as the default for all of them. Accepted: p0 to p4, or the full priority-p0 to priority-p4." >&2
  echo "  priority-p0 broken now, drop everything; priority-p1 important, do next; priority-p2 normal, the default for real work; priority-p3 nice to have; priority-p4 someday, maybe never." >&2
  echo "You choose the level per phase: these are your plan's phases, not something the user should have to grade. The rule is in ~/.claude/skills/milestone/NAMING.md." >&2
fi

if [[ -n "$missing_category" ]]; then
  echo "MISSING-CATEGORY every issue needs at least one label saying what it is about, and these have none:" >&2
  printf '%s' "$missing_category" >&2
  echo "Add \"labels\" to each issue in the plan, or a plan-level \"labels\" array as the default for all of them. Apply as many as genuinely apply, since a phase is often about more than one thing." >&2
  echo "A starting point, one for the kind of work (bug, enhancement, tech-debt, documentation) plus any that fit for what it touches (accessibility, ui-ux, performance, security, data-integrity, error-handling, monitoring, analytics, ci-hygiene, test-coverage, onboarding, deployment)." >&2
  echo "That list is NOT fixed. Prefer a label the repo already has (\`gh label list --limit 100\`) over a near synonym, and invent one when nothing fits rather than forcing a bad match. A priority level on its own does not count as a category." >&2
fi

if [[ -n "$missing_priority" || -n "$missing_category" ]]; then
  echo "ABORTED: no issues were filed, and the milestone was not touched." >&2
  exit 9
fi

# --- resolve the milestone through the shared helper ----------------------
# The plan's own issue count is passed through, so the "2 or more issues" threshold
# is enforced on this path too rather than only on the ad hoc filing paths. A plan
# with a single phase is a label with extra steps just as much as a single ad hoc
# issue is, so it gets the same refusal and the same visible override.
ensure_args=("$repo" "$title" --create-approved --for-issues "$n_issues" --description "$description")
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
verdict="$(printf '%s\n' "$ms_out" | grep -E '^(MILESTONE-EXISTS|MILESTONE-CREATED|WOULD-CREATE-MILESTONE)' | awk 'NR <= 1')"
resolved="$(printf '%s\n' "$ms_out" | sed -n 's/^MILESTONE-TITLE //p' | awk 'NR <= 1')"
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

# --- make sure the priority labels exist before referencing one -----------
# gh fails the WHOLE issue create on an unknown label, so a repo that has never been
# labelled would lose every issue in the plan. Idempotent, so a repo already set up
# costs one read.
if [[ -z "$dry" && "$n_issues" -gt 0 ]]; then
  if ! bash "$HERE/ensure-priority-labels.sh" "$repo" >/dev/null 2>&1; then
    echo "Could not confirm the priority labels exist in $repo. Filing would fail on an unknown label, so nothing was filed. Run ensure-priority-labels.sh to see why." >&2
    exit 9
  fi
fi

# --- file one issue per phase, each assigned to that milestone ------------
n="$n_issues"
i=0
failed=0
while [[ "$i" -lt "$n" ]]; do
  it="$(jq -r ".issues[$i].title // empty" "$plan")"
  ib="$(jq -r ".issues[$i].body // \"\"" "$plan")"
  lvl="$(jq -r ".issues[$i].priority // empty" "$plan")"
  [[ -z "$lvl" ]] && lvl="$default_priority"
  [[ "$lvl" =~ ^[pP][0-4]$ ]] && lvl="priority-${lvl}"
  if [[ -z "$it" ]]; then
    i=$((i + 1)); continue
  fi
  # One --label per name, so a label containing a comma cannot be split in two.
  label_args=(--label "$lvl")
  while IFS= read -r l; do
    [[ -z "$l" ]] && continue
    [[ "$l" =~ ^priority-[pP][0-4]$ ]] && continue  # the level is already applied
    label_args+=(--label "$l")
  done <<<"$(labels_for "$i")"

  if [[ -n "$dry" ]]; then
    echo "WOULD-CREATE-ISSUE repo=$repo milestone=$ms_ref priority=$lvl labels=$(printf '%s' "$(labels_for "$i")" | tr '\n' ',' | sed 's/,$//') title=$it"
  else
    # The issue names the session that filed it, from the one shared line maker (claude-config#536).
    # This script calls gh itself, so the gate that asks for the line never sees these creates.
    sess_line="$(bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib" 2>/dev/null && pwd)/claude-session-line.sh" 2>/dev/null)" || sess_line=""
    [[ -n "$sess_line" ]] && ib="$ib"$'\n\n'"$sess_line"
    iss_url="$(gh issue create --repo "$repo" --title "$it" --body "$ib" --milestone "$ms_ref" "${label_args[@]}" 2>&1)"
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
