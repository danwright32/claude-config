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
# And once it reads green, the merge must PIN that commit with
# --match-head-commit, because the rollup answers about the pull request rather
# than about a commit and is read a moment before the merge (#345). GitHub
# refuses the merge if the head has moved since.
#
# Deliberate overrides, both visible in the command, so neither can happen by
# accident or go unnoticed in the transcript: ALLOW_RED_MERGE=1 for the green
# reading, ALLOW_UNPINNED_MERGE=1 for the commit pin.

set -uo pipefail

# The four things every merge gate has to work out before it can say anything
# about a pull request (is this a merge, which directory, which pull request,
# whose answer to trust) live in lib/merge-target.sh, shared with
# require-changelog-tag.sh. They were learned here and each carries the incident
# that produced it; they moved out when the second gate needed them, because two
# copies would drift silently, each passing its own tests while disagreeing about
# which pull request it is looking at.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/merge-target.sh
. "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null || exit 0

payload=$(cat)
command=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)

# Not a merge: stay out of the way.
mt_is_pr_merge "$command" || exit 0

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
pr=$(mt_pr_number "$command")

cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)
cd "$(mt_repo_dir "$command" "$cwd")" 2>/dev/null || true

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
# It still earns its place now that EVERY repo pins the merge (#345). The two
# mechanisms cover different halves of the list above: --match-head-commit
# refuses a head that moved, and that is all it does, while these tools also
# WAIT for the checks rather than reading whatever is there, and confirm
# afterwards that the commit landed on the base its checks were run against. So
# this is not the duplicate the paragraph above warns about: a repo carrying one
# of these tools gets the two halves the general pin cannot reach.
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

# The account gh has ACTIVE cannot necessarily see this repo. Dan runs
# concurrent sessions under different GitHub accounts, and a repo owned by one
# 404s under the other: `gh pr view` then returns nothing, which is
# indistinguishable from a pull request that does not exist, and this gate
# correctly refused to merge blind. Measured 2026-08-30 on nursedexapp/nursedex,
# where it blocked every merge.
#
# So: try the active account, then each other logged-in account, scoping the
# token PER CALL. Never `gh auth switch`, which changes the shared keyring's
# active account and would break whatever other session is using it.
#
# And prove the answer is about THIS repo. The identity comes from the git
# remote, not from gh, because a check whose two sides come from one lookup can
# only confirm that lookup is self-consistent, never that it is correct (L70).
# The hook did not verify this before; an answer about a different repo would
# have been read as this pull request's verdict.
remote_slug=$(mt_remote_slug)

# headRefOid comes from the SAME call as the verdict, deliberately: the commit the merge is
# pinned to has to be the commit these checks were read for, and a second lookup could answer
# about a head that had already moved (L70, #345).
envelope=$(mt_pr_view "$pr" "number,statusCheckRollup,mergeable,url,headRefOid" "$remote_slug")
if [ "$(printf '%s' "$envelope" | jq -r '.found // false' 2>/dev/null)" = "true" ]; then
  rollup=$(printf '%s' "$envelope" | jq -c '.view')
else
  rollup=""
  wrong_repo=$(printf '%s' "$envelope" | jq -r '.wrongRepo // ""' 2>/dev/null)
  if [ -n "$wrong_repo" ]; then
    deny "Refusing to merge: the only answer gh gave was about $wrong_repo, not about $remote_slug. Verifying one pull request's checks and merging another is the exact mistake this gate exists to stop. Deliberate override: ALLOW_RED_MERGE=1 <the same command>."
  fi
fi
[ -z "$rollup" ] && deny "Cannot verify CI for this PR (gh pr view returned nothing under any logged-in account). Check the PR manually, then re-run with ALLOW_RED_MERGE=1 if it is genuinely green."

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

# GREEN. Now pin the merge to the commit that reading was ABOUT (#345).
#
# Everything above answers about the pull request rather than about a commit, and it is read a
# moment BEFORE the merge runs. A push landing in that gap is merged unjudged, and afterwards it
# is indistinguishable from a merge that was judged (L179). Until now the only repos protected
# were the two carrying their own pinned merge tool, which is a script per repo for a rule that
# applies to all of them.
#
# gh pr merge takes --match-head-commit, and GitHub refuses the merge when the head has moved, so
# every repo gets that protection from one flag.
#
# Reached only on a POSITIVE green reading, deliberately: the empty-rollup paths above exit before
# this, because the pin protects a VERDICT and there is no verdict in a repo with no CI. Requiring
# it there would block those repos for a reason that does not apply to them (L615, L324).
case "$command" in
  *ALLOW_UNPINNED_MERGE=1*) exit 0 ;;
esac

head_sha=$(printf '%s' "$rollup" | jq -r '.headRefOid // ""' 2>/dev/null)

# Green, but gh did not say which commit it was green FOR. Fails closed, in its own words: telling
# somebody to add a flag whose value nothing here can supply is a refusal that cannot be cleared
# by the remedy it names (L11, L109).
[ -z "$head_sha" ] && deny "PR #$number reads green, but gh did not report its head commit, so this merge cannot be pinned to the commit those checks were actually run for. A rollup is about the pull request, not about a commit, and it is read a moment before the merge: without the pin, a push landing in between is merged unjudged and looks identical afterwards. Check which commit is at the head and that its checks are the green ones, then merge with ALLOW_UNPINNED_MERGE=1 <the same command>."

pinned_sha=$(printf '%s' "$command" \
  | grep -oE '\-\-match-head-commit[[:space:]=]+[0-9a-fA-F]+' \
  | grep -oE '[0-9a-fA-F]+$' | awk 'NR <= 1')

if [ -z "$pinned_sha" ]; then
  deny "PR #$number is green at $head_sha, but the merge does not pin that commit. The rollup just read is about the pull request, not about a commit, so a push landing between this reading and the merge would be merged unjudged and would look identical afterwards. Run: $command --match-head-commit $head_sha . GitHub refuses the merge if the head has moved. Deliberate override: ALLOW_UNPINNED_MERGE=1 <the same command>."
fi

# Pinned to something else is worse than unpinned, not better: it hands GitHub a commit nothing
# here judged while reading as the careful route.
if [ "$(printf '%s' "$pinned_sha" | tr 'A-F' 'a-f')" != "$(printf '%s' "$head_sha" | tr 'A-F' 'a-f')" ]; then
  deny "PR #$number is green at $head_sha, but this merge pins $pinned_sha, which is a different commit and not the one these checks were read for. Merging it would land a commit nothing judged, by the route that is supposed to prevent exactly that. Pin $head_sha instead, or re-read the checks if the head has genuinely moved. Deliberate override: ALLOW_UNPINNED_MERGE=1 <the same command>."
fi

exit 0
