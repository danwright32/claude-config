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

# --- a dry run against a CLOSED catch-all previews, and reopens nothing (claude-config#1058) ---
# The helper's dry run now says it WOULD reopen the pen instead of reopening it, so this
# script has to read that answer as a milestone to preview against, or a dry run of a
# plan aimed at the pen would abort where the real run succeeds.
cat >"$TMP/closedpen.json" <<'JSON'
[ { "number": 5, "title": "Ungrouped", "state": "closed", "html_url": "https://github.com/acme/widgets/milestone/5" } ]
JSON
cat >"$TMP/plan-pen.json" <<'JSON'
{
  "title": "Ungrouped",
  "issues": [
    { "title": "Chore 1", "body": "b", "priority": "p3", "labels": ["enhancement"] },
    { "title": "Chore 2", "body": "b", "priority": "p3", "labels": ["enhancement"] }
  ]
}
JSON
out="$(DRY_RUN=1 run "$TMP/closedpen.json" "acme/widgets" "$TMP/plan-pen.json")"; rc=$?
check_eq "a dry run aimed at a closed pen exits 0" "0" "$rc"
check "it previews the reopen" "WOULD-REOPEN-MILESTONE 5 Ungrouped" "$out"
check "and previews each issue against the pen" "WOULD-CREATE-ISSUE repo=acme/widgets milestone=Ungrouped" "$out"
# The reads are `gh label list` and a plain `gh api`. Anything else counts as a write: a
# method, a field, or any other subcommand.
n_writes="$(awk '
  $1 == "label" && $2 == "list" { next }
  $1 != "api" || / (-X|--method|-f|-F|--field|--raw-field|--input)( |=|$)/
' "$TMP/calls.log" | grep -c .)"
check_eq "and writes nothing at all" "0" "$n_writes"

# --- the filed issues name the session that filed them (claude-config#536) ---
# This script calls gh itself, so the issue gate never sees its creates and cannot ask for the line.
out="$(CLAUDE_CODE_BRIDGE_SESSION_ID=session_01XyZ run "$TMP/none.json" "acme/widgets" "$TMP/plan.json")"
# Counted over the whole log: a body is several lines, so the line sits below its create's first.
n_marked="$(grep -c 'Claude-Session: https://claude.ai/code/session_01XyZ' "$TMP/calls.log")"
check_eq "every issue filed from a session carries its session line" "3" "$n_marked"
out="$(env -u CLAUDE_CODE_BRIDGE_SESSION_ID -u CLAUDE_CODE_SESSION_ID PATH="$TMP/bin:$PATH" GH_CALLS="$TMP/calls.log" GH_FIXTURE="$TMP/none.json" bash -c ': > "$GH_CALLS"; bash "$0" "$@"' "$SCRIPT" "acme/widgets" "$TMP/plan.json" 2>&1)"
n_marked="$(grep -c 'Claude-Session:' "$TMP/calls.log")"
check_eq "and outside a session no line is invented" "0" "$n_marked"
# #1279: every filed issue carries an Open questions section, None when its plan gave it none, since
# this script calls gh itself and the filing gate never sees its creates.
n_sections="$(grep -c '^## Open questions$' "$TMP/calls.log")"
check_eq "#1279 every issue filed carries an Open questions section" "3" "$n_sections"
# Over this run's own creates: the log was emptied as the run began, so three creates are its three.
check_eq "#1279 counted over this run's three creates alone (lessons review)" "3" "$(grep -c '^issue create' "$TMP/calls.log")"
# Counted as the heading with None right under it, so None anywhere else, or a heading with
# something else under it, does not count (lessons review).
under(){ python3 -c 'import sys; print(open(sys.argv[1]).read().count(sys.argv[2]))' "$TMP/calls.log" "$1"; }
check_eq "#1279 None right under each heading, since the plan gave them none" "3" "$(under $'## Open questions\n\nNone')"
# A phase whose plan already carries the section keeps its own, never a second one.
jq '.issues[0].body = "Design empty states.\n\n## Open questions\n\n- [ ] Which illustration style?"' "$TMP/plan.json" > "$TMP/plan-q.json"
out="$(run "$TMP/none.json" "acme/widgets" "$TMP/plan-q.json")"
check_eq "#1279 a plan's own section is kept, and none added beside it" "3" "$(grep -c '^## Open questions$' "$TMP/calls.log")"
check_eq "#1279 with its question right under its heading" "1" "$(under $'## Open questions\n\n- [ ] Which illustration style?')"
check_eq "#1279 and None right under only the other two" "2" "$(under $'## Open questions\n\nNone')"
# A heading that only starts with the words is another section, so the issue still gets its own.
jq '.issues[0].body = "Design empty states.\n\n## Open questions about the API\n\nWhich version first."' "$TMP/plan.json" > "$TMP/plan-q2.json"
out="$(run "$TMP/none.json" "acme/widgets" "$TMP/plan-q2.json")"
check_eq "#1279 a heading that only starts with the words still gets the section (lessons review)" "3" "$(under $'## Open questions\n\nNone')"

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

# --- a feature with a settled design (claude-config#1290) ------------------------
# A plan naming its settled design is held to the design's decision map before anything is written:
# every decision owned by a requirement or marked as having no code consequence, and every
# requirement named by an issue. Then the milestone gets one more issue, the comparison of the built
# screens against every design frame, so drift on the decisions that did have owners is found too.
design_file() { # design_file <path> <decisions json>
  printf '<!doctype html><html><body><main>screen</main>\n<script type="application/json" id="decision-map">{"decisions": %s}</script>\n</body></html>\n' "$2" >"$1"
}
design_file "$TMP/settled.html" '[{"id": "D1", "decision": "One column list", "requirement": "6.4"}, {"id": "D2", "decision": "Heading reads Invoices", "noCode": "copy only"}]'
design_file "$TMP/gap.html" '[{"id": "D1", "decision": "One column list", "requirement": "6.4"}, {"id": "D2", "decision": "Empty state shows last month"}]'
design_plan() { # design_plan <out> <design path> <phase 1 body>
  cat >"$1" <<JSON
{
  "title": "Invoices screen",
  "priority": "p2",
  "labels": ["enhancement"],
  "design": "$2",
  "issues": [
    { "title": "Phase 1: the list", "body": "$3" },
    { "title": "Phase 2: the heading", "body": "Copy." }
  ]
}
JSON
}
labels_are enhancement

design_plan "$TMP/plan-gap.json" "$TMP/gap.html" "Builds Requirement 6.4."
out="$(run "$TMP/none.json" "acme/widgets" "$TMP/plan-gap.json")"; rc=$?
check_eq "#1290 a design with an unowned decision exits 11" "11" "$rc"
check "#1290 the refusal names the unowned decision" "UNMAPPED D2: Empty state shows last month" "$out"
check_eq "#1290 and nothing is filed" "0" "$(issues_filed)"
check_eq "#1290 and no milestone is written" "0" "$(milestone_writes)"

design_plan "$TMP/plan-noissue.json" "$TMP/settled.html" "Builds the list."
out="$(run "$TMP/none.json" "acme/widgets" "$TMP/plan-noissue.json")"; rc=$?
check_eq "#1290 a requirement no issue names exits 11" "11" "$rc"
check "#1290 the refusal names the requirement" "NO-ISSUE Requirement 6.4 (D1)" "$out"
check_eq "#1290 and nothing is filed for it either" "0" "$(issues_filed)"

design_plan "$TMP/plan-relative.json" "settled.html" "Builds Requirement 6.4."
out="$(run "$TMP/none.json" "acme/widgets" "$TMP/plan-relative.json")"; rc=$?
check_eq "#1290 a design path that is not absolute exits 11" "11" "$rc"
check "#1290 and says so" "absolute" "$out"

design_plan "$TMP/plan-missing.json" "$TMP/not-there.html" "Builds Requirement 6.4."
out="$(run "$TMP/none.json" "acme/widgets" "$TMP/plan-missing.json")"; rc=$?
check_eq "#1290 a design file that is not there exits 11" "11" "$rc"
check "#1290 and says it could not be read" "DECISION-MAP UNREADABLE" "$out"

design_plan "$TMP/plan-design.json" "$TMP/settled.html" "Builds Requirement 6.4."
out="$(run "$TMP/none.json" "acme/widgets" "$TMP/plan-design.json")"; rc=$?
check_eq "#1290 a design whose map holds files the plan" "0" "$rc"
check_eq "#1290 with one more issue than the plan's phases" "3" "$(issues_filed)"
# From the last create to the end of the log, since a body spanning lines spreads one call over several.
last_create="$(sed -n "$(grep -n '^issue create' "$TMP/calls.log" | tail -n 1 | cut -d: -f1),\$p" "$TMP/calls.log")"
check "#1290 the last is the comparison against every design frame" "--title Compare the built screens against every frame of the settled design" "$last_create"
check "#1290 which names the design file" "$TMP/settled.html" "$last_create"
check "#1290 and carries the plan's priority and labels" "--label priority-p2 --label enhancement" "$last_create"
# A plan that already ends with the comparison does not get it twice.
jq '.issues += [{"title": "Compare the built screens against every frame of the settled design", "body": "own words"}]' "$TMP/plan-design.json" >"$TMP/plan-design-own.json"
out="$(run "$TMP/none.json" "acme/widgets" "$TMP/plan-design-own.json")"; rc=$?
check_eq "#1290 a plan carrying its own comparison files once" "3" "$(issues_filed)"

# Lessons review of #1290: a plan whose phases each carry their own level and categories, with no
# plan level default, is not refused over the comparison issue it never wrote; the issue takes the
# last phase's.
cat >"$TMP/plan-design-perissue.json" <<JSON
{
  "title": "Invoices screen",
  "design": "$TMP/settled.html",
  "issues": [
    { "title": "Phase 1: the list", "body": "Builds Requirement 6.4.", "priority": "p1", "labels": ["enhancement"] },
    { "title": "Phase 2: the heading", "body": "Copy.", "priority": "p3", "labels": ["ui-ux"] }
  ]
}
JSON
labels_are enhancement ui-ux
out="$(run "$TMP/none.json" "acme/widgets" "$TMP/plan-design-perissue.json")"; rc=$?
check_eq "#1290 a plan with only per phase levels and labels still files" "0" "$rc"
last_create="$(sed -n "$(grep -n '^issue create' "$TMP/calls.log" | tail -n 1 | cut -d: -f1),\$p" "$TMP/calls.log")"
check "#1290 and the comparison takes the last phase's level and labels" "--label priority-p3 --label ui-ux" "$last_create"
# An empty plan level default is no default, as labels_for reads it, so the last phase's still apply.
jq '.labels = [] | .priority = ""' "$TMP/plan-design-perissue.json" >"$TMP/plan-design-emptydefaults.json"
out="$(run "$TMP/none.json" "acme/widgets" "$TMP/plan-design-emptydefaults.json")"; rc=$?
check_eq "#1290 empty plan level defaults still file" "0" "$rc"
last_create="$(sed -n "$(grep -n '^issue create' "$TMP/calls.log" | tail -n 1 | cut -d: -f1),\$p" "$TMP/calls.log")"
check "#1290 with the last phase's level and labels on the comparison" "--label priority-p3 --label ui-ux" "$last_create"

# And the comparison is not counted as a phase: a design plan of ONE phase gets the same answer from
# the milestone helper as the same plan without a design, never a milestone it would refuse.
cat >"$TMP/plan-one.json" <<'JSON'
{ "title": "Invoices screen", "priority": "p2", "labels": ["enhancement"],
  "issues": [ { "title": "Phase 1: the list", "body": "Builds Requirement 6.4." } ] }
JSON
jq --arg d "$TMP/settled.html" '.design = $d' "$TMP/plan-one.json" >"$TMP/plan-one-design.json"
labels_are enhancement
out_plain="$(run "$TMP/none.json" "acme/widgets" "$TMP/plan-one.json")"; rc_plain=$?
out="$(run "$TMP/none.json" "acme/widgets" "$TMP/plan-one-design.json")"; rc=$?
check_eq "#1290 a one phase plan is refused without a design (the control)" "1" "$([ "$rc_plain" -ne 0 ] && echo 1 || echo 0)"
check_eq "#1290 and with one, by the same refusal" "$rc_plain" "$rc"
check "#1290 which is the single issue milestone refusal" "SINGLE-ISSUE-MILESTONE" "$out"
check_eq "#1290 filing nothing" "0" "$(issues_filed)"
# The design map's own refusal has a code of its own, never one the milestone helper uses (L11).
check_eq "#1290 the decision map refusal's code is not the single issue one" "1" "$([ "$rc" -ne 11 ] && echo 1 || echo 0)"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
