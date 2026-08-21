#!/bin/bash
# Block `gh pr merge` unless that PR's checks are positively green.
#
# Why this exists: on 2026-07-28 a PR was merged while its test run was failing.
# The command printed "conclusion=failure" and then merged anyway, because the
# shell chain checked that the query SUCCEEDED rather than what it SAID. Reading
# the output correctly is exactly the kind of discipline that fails under
# momentum, so the check moves out of the model's judgment and into a gate.
#
# Fails CLOSED: anything other than a positive all-green reading blocks. Pending
# counts as not-green, because "merge as soon as it goes green" is the habit that
# produced the mistake. A repo with no checks at all is allowed, since there is
# nothing that could be red.
#
# Deliberate override: ALLOW_RED_MERGE=1 gh pr merge ... (visible in the command,
# so it cannot happen by accident or go unnoticed in the transcript).

set -uo pipefail

payload=$(cat)
command=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)

# Not a merge: stay out of the way.
case "$command" in
  *"gh pr merge"*) ;;
  *) exit 0 ;;
esac

deny() {
  jq -nc --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# An explicit, visible override.
case "$command" in
  *ALLOW_RED_MERGE=1*) exit 0 ;;
esac

command -v gh >/dev/null 2>&1 || deny "Cannot verify CI: gh is not on PATH. Merging blind is what this gate exists to stop."

# The PR number if the command names one; otherwise gh resolves it from the
# current branch, which is also what the merge itself would do.
pr=$(printf '%s' "$command" | grep -oE 'gh pr merge[[:space:]]+(--[^[:space:]]+[[:space:]]+)*([0-9]+)' | grep -oE '[0-9]+$' | head -1)

# Resolve the directory the merge will actually run in, which is not necessarily
# the session cwd: PET keeps its git repo in a pet/ subdirectory, so the hook
# started outside any repo and gh could not resolve the PR at all. That produced
# a false block on a green PR the first time this ran.
#
# Order: an explicit `cd` at the head of the command wins, because that is where
# the merge itself will run. Otherwise the session cwd, then walk up for a repo,
# then look one level down.
resolve_repo_dir() {
  # Bash's own regex, not sed: macOS sed is BRE and treats \+ as a literal plus,
  # so a sed version of this silently matched nothing and every merge was blocked.
  local from_cd=""
  if [[ "$command" =~ ^[[:space:]]*cd[[:space:]]+(\"[^\"]+\"|\'[^\']+\'|[^[:space:]\&\|\;]+) ]]; then
    from_cd="${BASH_REMATCH[1]}"
    from_cd="${from_cd%\"}"; from_cd="${from_cd#\"}"
    from_cd="${from_cd%\'}"; from_cd="${from_cd#\'}"
  fi
  if [ -n "$from_cd" ] && [ -d "$from_cd" ]; then printf '%s' "$from_cd"; return; fi

  local d
  d=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)
  [ -n "$d" ] && [ -d "$d" ] || d=$PWD

  local up=$d
  while [ "$up" != "/" ]; do
    [ -e "$up/.git" ] && { printf '%s' "$up"; return; }
    up=$(dirname "$up")
  done

  local sub
  for sub in "$d"/*/; do
    [ -e "${sub}.git" ] && { printf '%s' "${sub%/}"; return; }
  done
  printf '%s' "$d"
}

cd "$(resolve_repo_dir)" 2>/dev/null || true

# A repo carrying its own commit pinned merge tool must merge through it
# (#711 for PostRoll, agent-onboarding #673).
#
# The rollup read below answers about the pull request, not about a particular
# commit, and it is read a moment BEFORE the merge. Four things slip through
# that gap: an empty answer that reads as green, a superseded run answering for
# a commit nobody judged, a head that moves between the reading and the merge,
# and a green earned against a base that has since moved. A repo's own tool
# knows about those, and pins the merge to the commit it actually judged, so the
# merge either takes that commit or is refused. None of that is worth anything
# if the safe route is merely available, so where one exists it is the only one.
#
# A table rather than a branch per repo. The reasoning is identical in every
# case, and two copies of it drift: the whole point of the rule is that one
# mechanism has one implementation.
#
# Only where a tool exists, so every other project keeps the old gate rather
# than being blocked by a rule about a file it does not have.
pinned_tool=""
pinned_how=""
if [ -f "tools/wait_for_checks.py" ]; then
  pinned_tool="tools/wait_for_checks.py"
  pinned_how="venv/bin/python tools/wait_for_checks.py ${pr:-<pr>} --merge"
elif [ -f ".github/scripts/merge-pr.sh" ]; then
  pinned_tool=".github/scripts/merge-pr.sh"
  pinned_how="npm run merge -- ${pr:-<pr>}"
fi

if [ -n "$pinned_tool" ]; then
  case "$command" in
    *ALLOW_UNPINNED_MERGE=1*) ;;
    *)
      deny "This repo merges through its own commit pinned tool ($pinned_tool), not through gh pr merge. Run: $pinned_how . It judges the checks against the commit at the head and hands GitHub that commit, so a push landing in the seconds between the two cannot be merged unjudged, and it confirms afterwards that the commit landed on the base its checks were run against. A plain merge skips all of that and looks identical afterwards. Deliberate override: ALLOW_UNPINNED_MERGE=1 <the same command>."
      ;;
  esac
fi

rollup=$(gh pr view ${pr:+"$pr"} --json number,statusCheckRollup,mergeable 2>/dev/null)
[ -z "$rollup" ] && deny "Cannot verify CI for this PR (gh pr view returned nothing). Check the PR manually, then re-run with ALLOW_RED_MERGE=1 if it is genuinely green."

number=$(printf '%s' "$rollup" | jq -r '.number // "?"')

# CheckRun entries report .conclusion; older StatusContext entries report .state.
verdicts=$(printf '%s' "$rollup" | jq -r '[.statusCheckRollup[]? | {
  name: (.name // .context // "check"),
  result: ((.conclusion // .state // "") | ascii_upcase)
}]')

total=$(printf '%s' "$verdicts" | jq 'length')

# NO checks at all has two very different causes and they must not share an answer
# (claude-config#131, L11).
#
# The benign one is a repo with no CI: nothing can be red, and blocking would make every such
# repo unmergeable. That is what this used to assume for every empty answer.
#
# The dangerous one is a pull request whose checks were never SCHEDULED. A branch that conflicts
# with its base has no merge commit for GitHub to build, so the workflow never starts and the
# rollup comes back empty, identical to the benign case. This gate would then merge a pull request
# whose tests never ran, which is the one thing it exists to prevent. Measured on 2026-08-21:
# PR #130 sat with no checks for twenty minutes and `gh pr checks` said only "no checks reported",
# which reads exactly like a queue that has not started.
if [ "$total" = "0" ]; then
  mergeable=$(printf '%s' "$rollup" | jq -r '.mergeable // ""')
  if [ "$mergeable" = "CONFLICTING" ]; then
    deny "PR #$number has NO checks because it conflicts with its base branch. GitHub cannot build a merge commit for a conflicting branch, so it never scheduled the tests, and an empty check list looks exactly like a queue that has not started yet. Rebase onto the base branch (or merge the base into it) and the tests will run. Deliberate override: ALLOW_RED_MERGE=1 <the same command>."
  fi

  # Not a conflict. Does this repo have anything that WOULD have checked a pull request? If it
  # does, the absence of checks is unexplained, and merging on an unexplained absence is merging
  # blind. If it does not, an empty answer is the honest one and the merge goes through.
  #
  # UNKNOWN is deliberately not treated as either: GitHub answers that while it is still working
  # the mergeability out, so it is evidence of nothing and this question decides instead.
  pr_ci=""
  for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -f "$wf" ] || continue
    grep -qE '^[[:space:]]*pull_request(_target)?:' "$wf" && { pr_ci="$wf"; break; }
  done
  if [ -n "$pr_ci" ]; then
    deny "PR #$number has NO checks at all, but this repo runs $pr_ci on pull requests, so something stopped them being scheduled: a workflow that will not parse, Actions disabled, or a run that never started. Find out which before merging, because an empty check list is indistinguishable from a green one here. Deliberate override: ALLOW_RED_MERGE=1 <the same command>."
  fi
  exit 0   # no CI that runs on pull requests: nothing can be red
fi

bad=$(printf '%s' "$verdicts" | jq -r '[.[] | select(.result | IN("SUCCESS","NEUTRAL","SKIPPED") | not)] | map("\(.name)=\(if .result == "" then "PENDING" else .result end)") | join(", ")')

[ -n "$bad" ] && deny "PR #$number is not green: $bad. Wait for it, or fix it. This gate exists because a red run was merged on 2026-07-28 by misreading the output. Deliberate override: ALLOW_RED_MERGE=1 <the same command>."

exit 0
