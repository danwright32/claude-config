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

rollup=$(gh pr view ${pr:+"$pr"} --json number,statusCheckRollup 2>/dev/null)
[ -z "$rollup" ] && deny "Cannot verify CI for this PR (gh pr view returned nothing). Check the PR manually, then re-run with ALLOW_RED_MERGE=1 if it is genuinely green."

number=$(printf '%s' "$rollup" | jq -r '.number // "?"')

# CheckRun entries report .conclusion; older StatusContext entries report .state.
verdicts=$(printf '%s' "$rollup" | jq -r '[.statusCheckRollup[]? | {
  name: (.name // .context // "check"),
  result: ((.conclusion // .state // "") | ascii_upcase)
}]')

total=$(printf '%s' "$verdicts" | jq 'length')
[ "$total" = "0" ] && exit 0  # no checks configured: nothing can be red

bad=$(printf '%s' "$verdicts" | jq -r '[.[] | select(.result | IN("SUCCESS","NEUTRAL","SKIPPED") | not)] | map("\(.name)=\(if .result == "" then "PENDING" else .result end)") | join(", ")')

[ -n "$bad" ] && deny "PR #$number is not green: $bad. Wait for it, or fix it. This gate exists because a red run was merged on 2026-07-28 by misreading the output. Deliberate override: ALLOW_RED_MERGE=1 <the same command>."

exit 0
