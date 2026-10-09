#!/usr/bin/env bash
# Tests for create-milestone.sh.
#
# A fake gh on PATH stands in for GitHub, so no test can reach the network or touch
# a real repository. Milestone resolution is delegated to ensure-milestone.sh, so
# these tests cover the wiring: the resolved milestone reaches every issue, and a
# resolution that needs a human decision files nothing at all.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

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
# The reason, which was not written down and had to be rediscovered: SKILL.md
# documents an empty "issues" array as the way to create a container before its
# issues exist. It matters because ensure-milestone.sh now refuses a milestone for a
# single issue, and refusing zero as well would have broken this documented flow.
# The threshold therefore refuses exactly ONE, and an empty create announces itself.
echo '{ "title": "Just a milestone", "issues": [] }' >"$TMP/noissues.json"
out_noissues="$(DRY_RUN=1 run "$TMP/none.json" "acme/widgets" "$TMP/noissues.json")"; rc=$?
check_eq "zero issues still succeeds" "0" "$rc"
check "milestone previewed even with no issues" "WOULD-CREATE-MILESTONE repo=acme/widgets title=Just a milestone" "$out_noissues"
n0="$(printf '%s\n' "$out_noissues" | grep -c '^WOULD-CREATE-ISSUE')"
check_eq "no issue lines when issues empty" "0" "$n0"

# --- the filed issues name the session that filed them (claude-config#536) ---
# This script calls gh itself, so the issue gate never sees its creates and cannot ask for the line.
out="$(CLAUDE_CODE_BRIDGE_SESSION_ID=session_01XyZ run "$TMP/none.json" "acme/widgets" "$TMP/plan.json")"
# Counted over the whole log: a body is several lines, so the line sits below its create's first.
n_marked="$(grep -c 'Claude-Session: https://claude.ai/code/session_01XyZ' "$TMP/calls.log")"
check_eq "every issue filed from a session carries its session line" "3" "$n_marked"
out="$(env -u CLAUDE_CODE_BRIDGE_SESSION_ID -u CLAUDE_CODE_SESSION_ID PATH="$TMP/bin:$PATH" GH_CALLS="$TMP/calls.log" GH_FIXTURE="$TMP/none.json" bash -c ': > "$GH_CALLS"; bash "$0" "$@"' "$SCRIPT" "acme/widgets" "$TMP/plan.json" 2>&1)"
n_marked="$(grep -c 'Claude-Session:' "$TMP/calls.log")"
check_eq "and outside a session no line is invented" "0" "$n_marked"

# --- a category label new to the repo is created before anything is filed (claude-config#1034) ---
# gh refuses an issue carrying a label the repo does not have ("could not add label: X not found"),
# which is how milestone #21's first run lost the phases labelled `tracker` and `tests`. This fake gh
# holds the repo's labels in a file: `label list` reads it, `label create` adds to it, and
# `issue create` refuses an unknown label exactly as GitHub does, so a plan whose labels were never
# made fails here the way it failed for real.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
if [ "${1:-}" = "label" ] && [ "${2:-}" = "list" ]; then
  if [ -n "${GH_LABEL_LIST_FAIL:-}" ]; then echo "HTTP 502: Bad Gateway" >&2; exit 1; fi
  python3 -c 'import json, sys; print(json.dumps([{"name": l.rstrip("\n")} for l in open(sys.argv[1]) if l.strip()]))' "$GH_LABELS"
  exit 0
fi
if [ "${1:-}" = "label" ] && [ "${2:-}" = "create" ]; then
  case "${3:-}" in priority-*) printf '%s\n' "$3" >>"$GH_LABELS"; exit 0 ;; esac
  if [ -n "${GH_LABEL_CREATE_FAIL:-}" ]; then echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; fi
  # A 422 that is NOT the label existing: GitHub rejects the request and makes no label.
  if [ -n "${GH_LABEL_CREATE_INVALID:-}" ]; then echo "HTTP 422: Validation Failed (description is too long (maximum is 100 characters))" >&2; exit 1; fi
  printf '%s\n' "$3" >>"$GH_LABELS"
  # Somebody else made it between the read and this create: GitHub answers 422.
  if [ -n "${GH_LABEL_CREATE_RACE:-}" ]; then echo "HTTP 422: Validation Failed (already_exists)" >&2; exit 1; fi
  exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "create" ]; then
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--label" ] && ! grep -qixF -- "$a" "$GH_LABELS"; then
      echo "could not add label: '$a' not found" >&2
      exit 1
    fi
    prev="$a"
  done
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
export GH_LABELS="$TMP/labels.txt"
labels_are() { printf '%s\n' "$@" >"$GH_LABELS"; }  # labels_are <name>... : the repo's labels
label_creates() { grep -c "^label create $1 " "$TMP/calls.log" 2>/dev/null; }
first_line() { grep -n -m 1 -- "$1" "$TMP/calls.log" 2>/dev/null | cut -d: -f1; }
milestone_writes() { grep -c -- 'api repos/acme/widgets/milestones -f' "$TMP/calls.log" 2>/dev/null; }

# Two phases share `tracker`, one also uses `tests`, and `enhancement` and a label with spaces are
# already in the repo, so only the two new ones may be made, each once.
cat >"$TMP/plan-newlabels.json" <<'JSON'
{
  "title": "Onboarding revamp",
  "priority": "p2",
  "issues": [
    { "title": "Phase 1", "body": "b", "labels": ["tracker", "enhancement"] },
    { "title": "Phase 2", "body": "b", "labels": ["tracker", "tests"] },
    { "title": "Phase 3", "body": "b", "labels": ["good first issue"] }
  ]
}
JSON
labels_are enhancement "good first issue"
out="$(run "$TMP/none.json" "acme/widgets" "$TMP/plan-newlabels.json")"; rc=$?
calls="$(cat "$TMP/calls.log")"
check "the fake gh was asked for the repo's labels" "label list --repo acme/widgets" "$calls"
check_eq "a plan using new labels exits 0" "0" "$rc"
check_eq "every phase is filed" "3" "$(issues_filed)"
check "the new label tracker is named as created" "CATEGORY-LABEL-CREATED tracker" "$out"
check "the new label tests is named as created" "CATEGORY-LABEL-CREATED tests" "$out"
check_eq "tracker is created once, though two phases use it" "1" "$(label_creates tracker)"
check "a created label carries a colour and a description naming the plan" "label create tracker --repo acme/widgets --color ededed --description Category first used by the plan for Onboarding revamp" "$calls"
check_eq "a label the repo already has is not created" "0" "$(label_creates enhancement)"
check_eq "nor is an existing label whose name has spaces" "0" "$(grep -c '^label create good' "$TMP/calls.log")"
check_eq "a priority level is made once, by ensure-priority-labels.sh, never again by this step" "1" "$(label_creates priority-p2)"
lc="$(first_line '^label create tracker ')"; mw="$(first_line 'api repos/acme/widgets/milestones -f')"; ic="$(first_line '^issue create')"
[[ -n "$lc" && -n "$mw" && "$lc" -lt "$mw" ]] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: the labels are made before the milestone is touched (label at $lc, milestone at $mw)"; }
[[ -n "$lc" && -n "$ic" && "$lc" -lt "$ic" ]] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: the labels are made before the first issue is filed (label at $lc, issue at $ic)"; }

# Re-running the same plan: the labels are there now, so nothing is created a second time.
out="$(run "$TMP/existing.json" "acme/widgets" "$TMP/plan-newlabels.json")"; rc=$?
check_eq "a re-run exits 0" "0" "$rc"
check_eq "a re-run creates no category label" "0" "$(grep -cE '^label create (tracker|tests) ' "$TMP/calls.log")"
check_eq "and files every phase" "3" "$(issues_filed)"

# The dry run previews the labels it would make and makes none.
labels_are enhancement "good first issue"
out="$(DRY_RUN=1 run "$TMP/none.json" "acme/widgets" "$TMP/plan-newlabels.json")"; rc=$?
check_eq "a dry run exits 0" "0" "$rc"
check "a dry run names the label it would create" "WOULD-CREATE-LABEL tracker" "$out"
check_eq "a dry run creates no label" "0" "$(grep -c '^label create' "$TMP/calls.log")"

# Another writer made the label between the read and the create: that is the label existing.
labels_are enhancement "good first issue"
out="$(GH_LABEL_CREATE_RACE=1 run "$TMP/none.json" "acme/widgets" "$TMP/plan-newlabels.json")"; rc=$?
check_eq "a create that lost the race still exits 0" "0" "$rc"
check "the race is reported as the label existing" "CATEGORY-LABEL-EXISTS tracker" "$out"
check_eq "and every phase is filed" "3" "$(issues_filed)"

# A label that cannot be created files NOTHING, and the milestone is not touched.
labels_are enhancement "good first issue"
out="$(GH_LABEL_CREATE_FAIL=1 run "$TMP/none.json" "acme/widgets" "$TMP/plan-newlabels.json")"; rc=$?
check_eq "a label that cannot be created exits 9" "9" "$rc"
check "the failed label is named with gh's reason" "LABEL-FAILED tracker: HTTP 403" "$out"
check "the refusal says nothing was filed" "no issues were filed, and the milestone was not touched" "$out"
check_eq "the refusal files nothing" "0" "$(issues_filed)"
check_eq "and creates no milestone" "0" "$(milestone_writes)"

# A 422 for any other reason is a failure, never read as the label existing: GitHub made no label,
# so carrying on would only file every phase into gh's refusal.
labels_are enhancement "good first issue"
out="$(GH_LABEL_CREATE_INVALID=1 run "$TMP/none.json" "acme/widgets" "$TMP/plan-newlabels.json")"; rc=$?
check_eq "a 422 that is not the label existing exits 9" "9" "$rc"
check "it is named as a failure with gh's reason" "LABEL-FAILED tracker: HTTP 422: Validation Failed (description is too long" "$out"
check_eq "it is never reported as the label existing" "" "$(printf '%s\n' "$out" | grep 'CATEGORY-LABEL-EXISTS')"
check_eq "and nothing is filed" "0" "$(issues_filed)"

# An unreadable label list refuses too, rather than creating blind or filing into gh's refusal.
out="$(GH_LABEL_LIST_FAIL=1 run "$TMP/none.json" "acme/widgets" "$TMP/plan-newlabels.json")"; rc=$?
check_eq "an unreadable label list exits 9" "9" "$rc"
check "the read failure explains itself" "Could not read the label list for acme/widgets: HTTP 502" "$out"
check_eq "the read failure creates no label" "0" "$(grep -c '^label create' "$TMP/calls.log")"
check_eq "and files nothing" "0" "$(issues_filed)"

# A plan the MILESTONE step refuses creates nothing either: a refused plan must not leave the labels
# it would have used behind. One case per refusal that can come from the milestone list or the title.
labels_are enhancement "good first issue"
out="$(run "$TMP/near.json" "acme/widgets" "$TMP/plan-newlabels.json")"; rc=$?
check_eq "a near duplicate milestone with new labels still exits 4" "4" "$rc"
check_eq "the near duplicate refusal leaves no label behind" "0" "$(grep -c '^label create' "$TMP/calls.log")"
check_eq "and files nothing" "0" "$(issues_filed)"
# Each case starts from a repo missing both labels, so "nothing created" is never just "nothing
# left to create" from the case before (L159).
labels_are enhancement "good first issue"
out="$(run "$TMP/closed.json" "acme/widgets" "$TMP/plan-newlabels.json")"; rc=$?
check_eq "a closed milestone with new labels still exits 3" "3" "$rc"
check_eq "the closed milestone refusal leaves no label behind" "0" "$(grep -c '^label create' "$TMP/calls.log")"
cat >"$TMP/plan-sentence.json" <<'JSON'
{
  "title": "Fix the onboarding, then ship it.",
  "priority": "p2",
  "issues": [
    { "title": "Phase 1", "body": "b", "labels": ["tracker"] },
    { "title": "Phase 2", "body": "b", "labels": ["tests"] }
  ]
}
JSON
labels_are enhancement
out="$(run "$TMP/none.json" "acme/widgets" "$TMP/plan-sentence.json")"; rc=$?
check_eq "a title not shaped like a feature with new labels still exits 8" "8" "$rc"
check_eq "the title shape refusal leaves no label behind" "0" "$(grep -c '^label create' "$TMP/calls.log")"
check "and says nothing was created" "nothing was created" "$out"
# The check that runs first writes nothing, so the plan that passes it gets exactly one milestone.
labels_are enhancement "good first issue"
out="$(run "$TMP/none.json" "acme/widgets" "$TMP/plan-newlabels.json")"; rc=$?
check_eq "a plan that passes the milestone check exits 0" "0" "$rc"
check_eq "and creates its milestone exactly once" "1" "$(milestone_writes)"

# A NEW label must be a short kebab case name (NAMING.md); one that is not is refused, not made.
cat >"$TMP/plan-badlabel.json" <<'JSON'
{
  "title": "Onboarding revamp",
  "priority": "p2",
  "issues": [
    { "title": "Phase 1", "body": "b", "labels": ["Needs Review"] },
    { "title": "Phase 2", "body": "b", "labels": ["tracker"] }
  ]
}
JSON
labels_are enhancement
out="$(run "$TMP/none.json" "acme/widgets" "$TMP/plan-badlabel.json")"; rc=$?
check_eq "a new label that is not kebab case exits 9" "9" "$rc"
check "the refusal names the label" "\"Needs Review\"" "$out"
check "and the rule" "LABEL-NOT-KEBAB" "$out"
check_eq "no label is created, not even the well named one" "0" "$(grep -c '^label create' "$TMP/calls.log")"
check_eq "and nothing is filed" "0" "$(issues_filed)"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
