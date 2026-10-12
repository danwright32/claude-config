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
# A category label the repo does not have yet is created once the milestone's own
# refusals have been checked and before the milestone is touched (grey, with a
# description naming the plan that first used it), because gh refuses an issue carrying
# an unknown label. A missing label that is not a short kebab case name, or one that
# cannot be created, files nothing at all (exit 9), and a refused milestone creates no
# label.
#
# This script is the ONE issue-filing path the PreToolUse gates cannot see (they read
# the Bash command, and here the create runs inside a script), so both rules are
# enforced here instead.
#
# Set DRY_RUN=1 to print what would happen without writing to GitHub.
# Prints: CATEGORY-LABEL-CREATED <name> per label it had to make, MILESTONE <url> (or
# MILESTONE-EXISTS ...), then ISSUE <url> per issue, or WOULD-CREATE-* lines in dry run.
#
# Callers reach this only after the user has previewed and approved the plan, so it
# passes --create-approved. It still aborts without filing anything when the helper
# finds a near duplicate or a closed milestone with the same name, because those
# need a human decision and half filed issues are worse than none.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENSURE="${ENSURE_MILESTONE_SH:-$HERE/ensure-milestone.sh}"
# shellcheck source=labels-lib.sh
. "$HERE/labels-lib.sh" || {
  echo "labels-lib.sh is missing beside create-milestone.sh, so the plan's labels cannot be checked. Nothing was filed." >&2
  exit 1
}

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

# --- make sure every category label the plan uses exists (claude-config#1034) ---
# gh fails the WHOLE issue create on an unknown label, so the first run of a plan whose
# phases used a label new to the repo filed none of those phases and had to be re-run
# once the label was made by hand. Every label is collected across the whole plan and
# the repo's list is read once. The missing ones are made only after the milestone's
# own refusals have been checked, and before the milestone is touched, so a refused
# plan creates nothing at all. Re-running is safe: a label already there is left alone.
plan_labels=""
missing_labels=""
seen_labels=""  # the same names lowercased, which is how GitHub tells two labels apart
i=0
while [[ "$i" -lt "$n_issues" ]]; do
  # A phase with no title is never filed below, so its labels are not made either.
  if [[ -n "$(jq -r ".issues[$i].title // empty" "$plan")" ]]; then
    while IFS= read -r l; do
      [[ -z "$l" ]] && continue
      [[ "$l" =~ ^priority-[pP][0-4]$ ]] && continue  # ensure-priority-labels.sh owns these
      lb_has "$seen_labels" "$l" && continue
      seen_labels="$seen_labels"$'\n'"$(printf '%s' "$l" | tr '[:upper:]' '[:lower:]')"
      plan_labels="${plan_labels:+$plan_labels$'\n'}$l"
    done <<<"$(labels_for "$i")"
  fi
  i=$((i + 1))
done

if [[ -n "$plan_labels" ]]; then
  label_err="$(mktemp)"
  if ! existing_labels="$(lb_read "$repo" "$label_err")"; then
    echo "Could not read the label list for $repo: $(tr '\n' ' ' <"$label_err")" >&2
    echo "ABORTED: no issues were filed, and the milestone was not touched, because which of the plan's labels are missing could not be told." >&2
    rm -f "$label_err"
    exit 9
  fi
  missing_labels=""
  badly_named=""
  while IFS= read -r l; do
    lb_has "$existing_labels" "$l" && continue
    missing_labels="${missing_labels:+$missing_labels$'\n'}$l"
    # A NEW label is a short kebab case name (NAMING.md), at most GitHub's 50 characters.
    if [[ ! "$l" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ || "${#l}" -gt 50 ]]; then
      badly_named="$badly_named  \"$l\""$'\n'
    fi
  done <<<"$plan_labels"
  if [[ -n "$badly_named" ]]; then
    echo "LABEL-NOT-KEBAB these labels are not in $repo yet, and a new label must be a short kebab case name (lowercase words joined by single hyphens, at most 50 characters):" >&2
    printf '%s' "$badly_named" >&2
    echo "Rename them in the plan, or use a label the repo already has (\`gh label list --limit 100\`)." >&2
    echo "ABORTED: no issues were filed, and the milestone was not touched." >&2
    rm -f "$label_err"
    exit 9
  fi
  rm -f "$label_err"
fi

# --- the milestone's own refusals, before anything is written ---------------
# The plan's own issue count is passed through, so the "2 or more issues" threshold
# is enforced on this path too rather than only on the ad hoc filing paths. A plan
# with a single phase is a label with extra steps just as much as a single ad hoc
# issue is, so it gets the same refusal and the same visible override.
ensure_args=("$repo" "$title" --create-approved --for-issues "$n_issues" --description "$description")
[[ -n "$due_on" ]] && ensure_args+=(--due "$due_on")

# The labels below must not be made for a plan the milestone step then refuses (a
# closed or near duplicate milestone, a title not shaped like a feature, a single
# issue), or a refused plan would leave labels behind. So the helper first classifies
# the title without writing anything, and every one of its refusals stops the plan
# here. Only a change on GitHub between this read and the real resolution below, a
# milestone created or closed in those seconds, can still refuse after the labels exist.
if [[ -z "$dry" && -n "$missing_labels" ]]; then
  pre_out="$(DRY_RUN=1 bash "$ENSURE" "${ensure_args[@]}" 2>&1)"
  pre_rc=$?
  if [[ "$pre_rc" -ne 0 ]]; then
    printf '%s\n' "$pre_out"
    echo "ABORTED: no issues were filed, and nothing was created, because the milestone could not be resolved."
    exit "$pre_rc"
  fi
fi

# --- create the labels the repo is missing ----------------------------------
if [[ -n "$missing_labels" ]]; then
  label_err="$(mktemp)"
  label_failed=0
  while IFS= read -r l; do
    [[ -z "$l" ]] && continue
    if [[ -n "$dry" ]]; then
      echo "WOULD-CREATE-LABEL $l"
      continue
    fi
    lb_create "$repo" "$l" "ededed" "Category first used by the plan for ${title:0:60}" "$label_err"
    case $? in
      0) echo "CATEGORY-LABEL-CREATED $l" ;;
      3) echo "CATEGORY-LABEL-EXISTS $l" ;;
      *) echo "LABEL-FAILED $l: $(tr '\n' ' ' <"$label_err")" >&2
         label_failed=$((label_failed + 1)) ;;
    esac
  done <<<"$missing_labels"
  rm -f "$label_err"
  if [[ "$label_failed" -gt 0 ]]; then
    echo "ABORTED: no issues were filed, and the milestone was not touched, because $label_failed label(s) the plan uses could not be created and gh would refuse every issue carrying one. Re-running is safe: labels already made are left alone." >&2
    exit 9
  fi
fi

# --- resolve the milestone through the shared helper ----------------------
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
verdict="$(printf '%s\n' "$ms_out" | grep -E '^(MILESTONE-EXISTS|MILESTONE-CREATED|WOULD-CREATE-MILESTONE|WOULD-REOPEN-MILESTONE)' | awk 'NR <= 1')"
resolved="$(printf '%s\n' "$ms_out" | sed -n 's/^MILESTONE-TITLE //p' | awk 'NR <= 1')"
case "$verdict" in
  # WOULD-REOPEN is the dry run's answer for a closed catch-all (claude-config#1058): the
  # milestone exists with a real title, it is only left closed, so preview against it.
  MILESTONE-EXISTS*|MILESTONE-CREATED*|WOULD-REOPEN-MILESTONE*)
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
