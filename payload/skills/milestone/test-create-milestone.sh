#!/usr/bin/env bash
# Tests for create-milestone.sh.
#
# A fake gh on PATH stands in for GitHub, so no test can reach the network or touch
# a real repository. Milestone resolution is delegated to ensure-milestone.sh, so
# these tests cover the wiring: the resolved milestone reaches every issue, and a
# resolution that needs a human decision files nothing at all.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/create-milestone.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() { # check <description> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1"
    echo "  expected to contain: $2"
    echo "  actual: $3"
  fi
}
check_eq() { # check_eq <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 (expected '$2', got '$3')"
  fi
}

# --- the fake gh ---
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "create" ]; then
  echo "https://github.com/acme/widgets/issues/77"
  exit 0
fi
for a in "$@"; do
  if [ "$a" = "-f" ]; then cat "$GH_CREATED"; exit 0; fi
done
cat "$GH_FIXTURE"
exit 0
STUB
chmod +x "$TMP/bin/gh"

cat >"$TMP/none.json" <<'JSON'
[]
JSON
cat >"$TMP/existing.json" <<'JSON'
[ { "number": 3, "title": "Onboarding revamp", "state": "open", "html_url": "https://github.com/acme/widgets/milestone/3" } ]
JSON
cat >"$TMP/created.json" <<'JSON'
{ "number": 12, "title": "Onboarding revamp", "state": "open", "html_url": "https://github.com/acme/widgets/milestone/12" }
JSON

export GH_CREATED="$TMP/created.json"

cat >"$TMP/plan.json" <<'JSON'
{
  "title": "Onboarding revamp",
  "description": "Rework first-run experience.\n\nFrom /plan-council.",
  "issues": [
    { "title": "Phase 1: empty states", "body": "Design empty states.", "priority": "p1", "labels": ["enhancement", "onboarding"] },
    { "title": "Phase 2: tour", "body": "Build the product tour.", "priority": "p2", "labels": ["enhancement"] },
    { "title": "Phase 3: telemetry", "body": "Instrument funnel.", "priority": "p3", "labels": ["analytics"] }
  ]
}
JSON

run() { # run <fixture> <args...>
  export GH_CALLS="$TMP/calls.log"
  export GH_FIXTURE="$1"
  shift
  : >"$GH_CALLS"
  PATH="$TMP/bin:$PATH" bash "$SCRIPT" "$@" 2>&1
}
issues_filed() { grep -c '^issue create' "$TMP/calls.log" 2>/dev/null; }

# --- happy path, dry run: nothing exists yet ---
out="$(DRY_RUN=1 run "$TMP/none.json" "acme/widgets" "$TMP/plan.json")"; rc=$?
check_eq "dry run exits 0" "0" "$rc"
check "dry run previews the milestone" "WOULD-CREATE-MILESTONE repo=acme/widgets title=Onboarding revamp" "$out"
n_issues="$(printf '%s\n' "$out" | grep -c '^WOULD-CREATE-ISSUE')"
check_eq "one issue per phase" "3" "$n_issues"
# The preview shows the level and the categories too, so an approval is given with
# everything that will be applied in view, not just the titles.
check "issue carries the milestone, level and categories" "milestone=Onboarding revamp priority=priority-p1 labels=enhancement,onboarding title=Phase 1: empty states" "$out"
check "last phase present" "title=Phase 3: telemetry" "$out"
check_eq "dry run files nothing" "0" "$(issues_filed)"

# --- real run, nothing exists: milestone created, issues attached by number ---
out="$(run "$TMP/none.json" "acme/widgets" "$TMP/plan.json")"; rc=$?
check_eq "real run exits 0" "0" "$rc"
check "real run reports the created milestone" "MILESTONE-CREATED 12 Onboarding revamp" "$out"
check_eq "real run files every issue" "3" "$(issues_filed)"
check "issues are assigned to the resolved milestone by name" "--milestone Onboarding revamp" "$(cat "$TMP/calls.log")"
check "issue urls are reported" "ISSUE https://github.com/acme/widgets/issues/77" "$out"

# --- re-running reuses the milestone rather than twinning it ---
out="$(run "$TMP/existing.json" "acme/widgets" "$TMP/plan.json")"; rc=$?
check_eq "re-run exits 0" "0" "$rc"
check "re-run reuses the open milestone" "MILESTONE-EXISTS 3 Onboarding revamp" "$out"
check "re-run attaches issues to the existing milestone" "--milestone Onboarding revamp" "$(cat "$TMP/calls.log")"
milestone_writes="$(grep -c -- 'api repos/acme/widgets/milestones -f' "$TMP/calls.log" 2>/dev/null)"
check_eq "re-run creates no second milestone" "0" "$milestone_writes"

# The plan's wording may differ in case or punctuation from the milestone that is
# already there. gh matches milestones by name, so the issue must carry the
# milestone's own title, not the plan's variant of it.
cat >"$TMP/variant-plan.json" <<'JSON'
{
  "title": "onboarding revamp",
  "priority": "p2",
  "labels": ["enhancement"],
  "issues": [ { "title": "Phase 1: empty states", "body": "Design empty states." } ]
}
JSON
out="$(run "$TMP/existing.json" "acme/widgets" "$TMP/variant-plan.json")"; rc=$?
check_eq "title variant exits 0" "0" "$rc"
check "title variant passes the milestone's own title to gh" "--milestone Onboarding revamp" "$(cat "$TMP/calls.log")"

# --- resolution that needs a human decision files NOTHING ---
cat >"$TMP/near.json" <<'JSON'
[ { "number": 5, "title": "Onboarding revamp v2", "state": "open", "html_url": "https://github.com/acme/widgets/milestone/5" } ]
JSON
out="$(run "$TMP/near.json" "acme/widgets" "$TMP/plan.json")"; rc=$?
check_eq "near duplicate aborts with the helper's code" "4" "$rc"
check "near duplicate is surfaced" "NEAR-DUPLICATE" "$out"
check "abort says no issues were filed" "ABORTED: no issues were filed" "$out"
check_eq "near duplicate files no issues" "0" "$(issues_filed)"

cat >"$TMP/closed.json" <<'JSON'
[ { "number": 2, "title": "Onboarding revamp", "state": "closed", "html_url": "https://github.com/acme/widgets/milestone/2" } ]
JSON
out="$(run "$TMP/closed.json" "acme/widgets" "$TMP/plan.json")"; rc=$?
check_eq "closed match aborts with the helper's code" "3" "$rc"
check_eq "closed match files no issues" "0" "$(issues_filed)"

# --- failure path: a failing issue create is reported, not swallowed ---
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "create" ]; then
  echo "HTTP 403: forbidden" >&2
  exit 1
fi
for a in "$@"; do
  if [ "$a" = "-f" ]; then cat "$GH_CREATED"; exit 0; fi
done
cat "$GH_FIXTURE"
exit 0
STUB
chmod +x "$TMP/bin/gh"
out="$(run "$TMP/existing.json" "acme/widgets" "$TMP/plan.json")"; rc=$?
check_eq "failed issue creates exit non-zero" "7" "$rc"
check "each failure is named" "ISSUE-FAILED title=Phase 1: empty states" "$out"
check "the summary counts the failures" "3 of 3 issues could not be filed" "$out"
check "the summary says a re-run is safe" "reuse it rather than duplicate it" "$out"

# --- usage errors ---
out_noargs="$(bash "$SCRIPT" 2>&1)"; rc=$?
check_eq "missing args exits non-zero" "1" "$rc"
check "missing args prints usage" "Usage:" "$out_noargs"

echo '{ "issues": [] }' >"$TMP/notitle.json"
out_notitle="$(DRY_RUN=1 run "$TMP/none.json" "acme/widgets" "$TMP/notitle.json")"; rc=$?
check_eq "missing title exits non-zero" "1" "$rc"
check "missing title explains why" "title" "$out_notitle"

# --- priority reaches every issue this script files ---
# This is the one issue-filing path the PreToolUse priority gate cannot see: the gate
# reads the Bash command, and here the create runs inside a script, so `bash
# create-milestone.sh` looks like nothing to it. Without this, /plan-council and
# /plan-lite would be the only paths still filing issues with no priority at all.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "create" ]; then
  echo "https://github.com/acme/widgets/issues/77"
  exit 0
fi
if [ "${1:-}" = "label" ]; then
  if [ "${2:-}" = "list" ]; then echo '[]'; fi
  exit 0
fi
for a in "$@"; do
  if [ "$a" = "-f" ]; then cat "$GH_CREATED"; exit 0; fi
done
cat "$GH_FIXTURE"
exit 0
STUB
chmod +x "$TMP/bin/gh"

out="$(run "$TMP/existing.json" "acme/widgets" "$TMP/plan.json")"; rc=$?
calls="$(cat "$TMP/calls.log")"
check_eq "a plan carrying priorities exits 0" "0" "$rc"
check_eq "every phase is filed" "3" "$(issues_filed)"
check "the per-issue level is applied" "--label priority-p1" "$calls"
check "the second level is applied" "--label priority-p2" "$calls"
check "the third level is applied" "--label priority-p3" "$calls"
# The labels have to exist before an issue can reference one: gh fails the whole
# create on an unknown label.
check "the labels are ensured first" "label create priority-p0" "$calls"

# A bare level is accepted as well as the full label name, because a plan is written
# by hand and both readings are natural.
cat >"$TMP/plan-full.json" <<'JSON'
{
  "title": "Onboarding revamp",
  "labels": ["bug"],
  "issues": [ { "title": "Phase 1", "body": "b", "priority": "priority-p0" } ]
}
JSON
out="$(run "$TMP/existing.json" "acme/widgets" "$TMP/plan-full.json")"; rc=$?
check_eq "a full label name is accepted" "0" "$rc"
check "the full label name is applied once, not doubled" "--label priority-p0" "$(cat "$TMP/calls.log")"

# One default for the whole plan saves repeating it on every phase.
cat >"$TMP/plan-default.json" <<'JSON'
{
  "title": "Onboarding revamp",
  "priority": "p2",
  "labels": ["enhancement"],
  "issues": [
    { "title": "Phase 1", "body": "b" },
    { "title": "Phase 2", "body": "b", "priority": "p0" }
  ]
}
JSON
out="$(run "$TMP/existing.json" "acme/widgets" "$TMP/plan-default.json")"; rc=$?
check_eq "a plan-level default exits 0" "0" "$rc"
check "the default applies where a phase says nothing" "--label priority-p2" "$(cat "$TMP/calls.log")"
check "a phase still overrides the default" "--label priority-p0" "$(cat "$TMP/calls.log")"

# --- every issue also needs a category label ---
# Same blind spot as priority: the category gate reads the Bash command, and here the
# create runs inside a script, so without this /plan-council and /plan-lite would be
# the only paths still filing uncategorised issues.
cat >"$TMP/plan-labels.json" <<'JSON'
{
  "title": "Onboarding revamp",
  "priority": "p2",
  "labels": ["enhancement"],
  "issues": [
    { "title": "Phase 1", "body": "b" },
    { "title": "Phase 2", "body": "b", "labels": ["tech-debt", "accessibility"] }
  ]
}
JSON
out="$(run "$TMP/existing.json" "acme/widgets" "$TMP/plan-labels.json")"; rc=$?
calls="$(cat "$TMP/calls.log")"
check_eq "a plan carrying labels exits 0" "0" "$rc"
check "the plan-level label applies where a phase says nothing" "--label enhancement" "$calls"
check "a phase's own labels are applied" "--label tech-debt" "$calls"
check "several labels on one issue all apply" "--label accessibility" "$calls"

# The vocabulary is not restricted, so an unfamiliar label must pass straight through.
cat >"$TMP/plan-oddlabel.json" <<'JSON'
{
  "title": "Onboarding revamp",
  "priority": "p2",
  "issues": [ { "title": "Phase 1", "body": "b", "labels": ["wobbly-gizmo-behaviour"] } ]
}
JSON
out="$(run "$TMP/existing.json" "acme/widgets" "$TMP/plan-oddlabel.json")"; rc=$?
check_eq "an unfamiliar label is accepted" "0" "$rc"
check "the unfamiliar label reaches gh" "--label wobbly-gizmo-behaviour" "$(cat "$TMP/calls.log")"

# --- a plan with no category files NOTHING ---
cat >"$TMP/plan-nolabels.json" <<'JSON'
{
  "title": "Onboarding revamp",
  "priority": "p2",
  "issues": [
    { "title": "Phase 1", "body": "b" },
    { "title": "Phase 2", "body": "b", "labels": ["priority-p1"] }
  ]
}
JSON
out="$(run "$TMP/existing.json" "acme/widgets" "$TMP/plan-nolabels.json")"; rc=$?
check_eq "a plan with no category exits 9" "9" "$rc"
check "the refusal names the offending phase" "Phase 1" "$out"
# A priority in the labels array is still not a category.
check "a priority label does not count as a category" "Phase 2" "$out"
check "the refusal says nothing was filed" "no issues were filed" "$out"
check_eq "the refusal files nothing" "0" "$(issues_filed)"

# --- a plan with no priority at all files NOTHING ---
# Refusing beats defaulting: a silent default to p2 is how the priority labels became
# meaningless in the first place, and half a filed plan is worse than none.
cat >"$TMP/plan-nopriority.json" <<'JSON'
{
  "title": "Onboarding revamp",
  "labels": ["bug"],
  "issues": [
    { "title": "Phase 1", "body": "b" },
    { "title": "Phase 2", "body": "b" }
  ]
}
JSON
out="$(run "$TMP/existing.json" "acme/widgets" "$TMP/plan-nopriority.json")"; rc=$?
check_eq "a plan with no priority exits 9" "9" "$rc"
check "the refusal names the offending phase" "Phase 1" "$out"
check "the refusal says nothing was filed" "no issues were filed" "$out"
check "the refusal shows the scale" "priority-p2" "$out"
check_eq "the refusal files nothing" "0" "$(issues_filed)"

# An off-scale level is a mistake, not a level.
cat >"$TMP/plan-badpriority.json" <<'JSON'
{
  "title": "Onboarding revamp",
  "labels": ["bug"],
  "issues": [ { "title": "Phase 1", "body": "b", "priority": "p9" } ]
}
JSON
out="$(run "$TMP/existing.json" "acme/widgets" "$TMP/plan-badpriority.json")"; rc=$?
check_eq "an off-scale level exits 9" "9" "$rc"
check_eq "an off-scale level files nothing" "0" "$(issues_filed)"

# The check runs before any write, so a dry run refuses too.
out="$(DRY_RUN=1 run "$TMP/existing.json" "acme/widgets" "$TMP/plan-nopriority.json")"; rc=$?
check_eq "a dry run of a plan with no priority also exits 9" "9" "$rc"

# --- zero issues is allowed (milestone only) ---
echo '{ "title": "Just a milestone", "issues": [] }' >"$TMP/noissues.json"
out_noissues="$(DRY_RUN=1 run "$TMP/none.json" "acme/widgets" "$TMP/noissues.json")"; rc=$?
check_eq "zero issues still succeeds" "0" "$rc"
check "milestone previewed even with no issues" "WOULD-CREATE-MILESTONE repo=acme/widgets title=Just a milestone" "$out_noissues"
n0="$(printf '%s\n' "$out_noissues" | grep -c '^WOULD-CREATE-ISSUE')"
check_eq "no issue lines when issues empty" "0" "$n0"

echo
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
