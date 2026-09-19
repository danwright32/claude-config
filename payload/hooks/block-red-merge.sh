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
# Deliberate overrides, one per rule and all visible in the command, so none can
# happen by accident or go unnoticed in the transcript: ALLOW_RED_MERGE=1 skips
# the whole gate, SKIP_MERGE_TOOL=1 skips a repo's own merge script, and
# ALLOW_UNPINNED_MERGE=1 skips the commit pin. Each answers only its own rule,
# because one token carrying two rules silently widens every use of it (L448).

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

# The other tool this gate cannot work without, named the same way (claude-config#475). The shared
# library reads which pull request and which repository the merge names with python3, and without
# it both come back empty: this gate then asked gh about whatever pull request the current branch
# resolves to, and a green answer there merged THIS one unjudged. The not found refusal further
# down would have described a pull request nobody could find, which is a true sentence about a
# different fault and sends somebody to name a repository that was never the problem (L11).
mt_reader_missing && deny "Refusing to merge: $(mt_reader_absent_why) Verifying one pull request's checks and merging another is the mistake this gate exists to stop."

# The PR number if the command names one; otherwise gh resolves it from the
# current branch, which is also what the merge itself would do.
pr=$(mt_pr_number "$command")

cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)

# WHICH repository, resolved the way gh itself resolves it (claude-config#463): the merge's own
# --repo or -R first, then a cd in the command (anywhere the shared reader finds one, not only at
# its head), then the working directory. This gate used to ask gh about the session's folder
# whatever the merge named, so merging danwright32/backstage#26 with --repo from an Ovation session
# was refused as "gh returned nothing", on a pull request whose checks had both passed.
repo_flag="$(mt_repo_flag "$command")"
cd "$(mt_repo_dir "$command" "$cwd")" 2>/dev/null || true

# Landed somewhere that is not a checkout, with MORE THAN ONE below it. The resolver refuses to
# guess between them (claude-config#346), so say which they were: everything after this would
# answer about whichever repository gh happened to resolve, and the generic "gh returned nothing"
# further down is a true sentence about a different fault that sends somebody to check a pull
# request in the wrong project (L11, L521). A merge naming its repository with --repo has nothing
# left to guess, so it is not asked.
if [ -z "$repo_flag" ] && [ ! -e ".git" ]; then
  ambiguous=$(mt_checkout_candidates "$PWD" | tr '\n' ' ')
  case "$ambiguous" in
    *" "*" "*)
      deny "Refusing to merge: $PWD is not a checkout and holds more than one below it ($ambiguous), so nothing here can say which repository this merge is about. Run the merge from inside the one you mean, or put an explicit cd at the head of the command. Guessing is what this gate exists to stop, and picking one of them would look identical afterwards to having read the right one."
      ;;
  esac
fi

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
# A table rather than a branch per repo, and ONE table rather than one per question.
# It lives in lib/merge-target.sh as MT_MERGE_TOOLS, beside the matcher that decides
# which COMMANDS run these tools, because this gate asking which REPOS carry one is the
# same list read for a different reason. Keeping a second copy here is what produced
# claude-config#351: wait_for_checks.py was named in this file and missing from the
# matcher, so the changelog gate enforced nothing in PET (L41). test-block-red-merge.sh
# scans this file for a tool path of its own, since two copies agreeing is exactly what
# the tests looked like until the day they stopped.
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
#
# A merge whose --repo names a repository OTHER than this checkout's is judged against that
# repository's files, not this folder's, which say nothing about it (claude-config#463). That
# reading needs the account that can see the pull request, so it happens after the lookup below.
local_slug=$(mt_remote_slug)
foreign=""
if [ -n "$repo_flag" ] && \
   [ "$(printf '%s' "$repo_flag" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$local_slug" | tr '[:upper:]' '[:lower:]')" ]; then
  foreign=1
fi
pinned_tool=""
[ -z "$foreign" ] && pinned_tool="$(mt_pinned_tool "$PWD" || true)"
pinned_how=""
[ -n "$pinned_tool" ] && pinned_how="$(mt_pinned_how "$PWD" "${pr:-}")"

# ONE OVERRIDE PER RULE. This rule reads SKIP_MERGE_TOOL, and the commit pin at the foot of the
# file reads ALLOW_UNPINNED_MERGE. They shared the second name until #347, which meant somebody
# bypassing this repo's script silently also lost the pin, landing on the weakest merge available
# and the one they were least likely to have asked for: a second rule put behind an existing
# override widens every use of that override, and nothing at the point of use says so (L448).
if [ -n "$pinned_tool" ]; then
  case "$command" in
    *SKIP_MERGE_TOOL=1*) ;;
    *)
      deny "This repo merges through its own commit pinned tool ($pinned_tool), not through gh pr merge. Run: $pinned_how . It judges the checks against the commit at the head and hands GitHub that commit, so a push landing in the seconds between the two cannot be merged unjudged, and it confirms afterwards that the commit landed on the base its checks were run against. A plain merge skips all of that and looks identical afterwards. Deliberate override: SKIP_MERGE_TOOL=1 <the same command>, which skips this rule only: the merge must still pin its commit."
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
#
# Where the merge names its repository with --repo, THAT is the identity: it comes from the
# command, not from gh, so the answer is still checked against something gh did not supply.
remote_slug="${repo_flag:-$local_slug}"

# What the refusals below name as the place that was searched, and why it was that place, so a
# pull request looked for in the wrong repository is visible as such (claude-config#463). The
# sentences are the library's, shared with the changelog gate, which has the same thing to say
# and would otherwise say it differently (claude-config#470, L613).
searched="$(mt_searched_repo "$repo_flag" "$remote_slug" "$PWD")"
searched_why="$(mt_searched_why "$repo_flag" "$remote_slug" "$PWD")"
pr_label="$(mt_pr_label "$pr")"

# headRefOid comes from the SAME call as the verdict, deliberately: the commit the merge is
# pinned to has to be the commit these checks were read for, and a second lookup could answer
# about a head that had already moved (L70, #345).
envelope=$(mt_pr_view "$pr" "number,statusCheckRollup,mergeable,url,headRefOid" "$remote_slug" "$repo_flag")
view_account=""
if [ "$(printf '%s' "$envelope" | jq -r '.found // false' 2>/dev/null)" = "true" ]; then
  rollup=$(printf '%s' "$envelope" | jq -c '.view')
  view_account=$(printf '%s' "$envelope" | jq -r '.account // ""' 2>/dev/null)
else
  rollup=""
  wrong_repo=$(printf '%s' "$envelope" | jq -r '.wrongRepo // ""' 2>/dev/null)
  if [ -n "$wrong_repo" ]; then
    deny "Refusing to merge: the only answer gh gave was about $wrong_repo, not about $remote_slug. Verifying one pull request's checks and merging another is the exact mistake this gate exists to stop. Deliberate override: ALLOW_RED_MERGE=1 <the same command>."
  fi
  # NOT FOUND is not "could not confirm it is green" (L11). Every account answered that there is no
  # such pull request there, so the fault is where it was looked for, and the remedy is naming the
  # right repository, never the override: offering the override for a pull request that is green
  # somewhere else teaches reaching for it (L36).
  if [ "$(printf '%s' "$envelope" | jq -r '.notFound // false' 2>/dev/null)" = "true" ]; then
    deny "Refusing to merge: no $pr_label was found in $searched under any logged-in account, so there is nothing here to judge. It was looked for there because $searched_why. If it lives in another repository, name that repository with --repo owner/name on the merge, or cd into its checkout before the merge."
  fi
fi
if [ -z "$rollup" ]; then
  gh_error=$(printf '%s' "$envelope" | jq -r '.error // ""' 2>/dev/null)
  deny "Cannot verify CI for this PR: gh pr view failed for the $pr_label in $searched under every logged-in account${gh_error:+ ($gh_error)}. Check the PR manually, then re-run with ALLOW_RED_MERGE=1 if it is genuinely green."
fi

# The repository the merge names is not this checkout, so its merge tool is read from GitHub. Same
# rule, same override and same wording as above, with the one difference that the tool has to be
# run from a checkout of that repository.
if [ -n "$foreign" ]; then
  case "$command" in
    *SKIP_MERGE_TOOL=1*) ;;
    *)
      remote_tool="$(mt_pinned_tool_remote "$repo_flag" "$view_account")"; remote_rc=$?
      if [ "$remote_rc" = 0 ]; then
        deny "$repo_flag merges through its own commit pinned tool ($remote_tool), not through gh pr merge. From a checkout of $repo_flag, run: $(mt_pinned_how_for "$remote_tool" "${pr:-}") . It judges the checks against the commit at the head and hands GitHub that commit, and it confirms afterwards that the commit landed on the base its checks were run against. A plain merge skips all of that and looks identical afterwards. Deliberate override: SKIP_MERGE_TOOL=1 <the same command>, which skips this rule only: the merge must still pin its commit."
      elif [ "$remote_rc" = 2 ]; then
        deny "Refusing to merge: could not tell whether $repo_flag carries its own commit pinned merge tool ($remote_tool), because GitHub did not answer that question. Where one exists it is the only way this gate lets that repository merge, so not knowing is not the same as it being absent. Run the merge from a checkout of $repo_flag, where the file can be read from disk. Deliberate override: SKIP_MERGE_TOOL=1 <the same command>."
      fi
      ;;
  esac
fi

number=$(printf '%s' "$rollup" | jq -r '.number // "?"')

# CheckRun entries report .conclusion; older StatusContext entries report .state.
#
# ONE VERDICT PER CHECK, taken from its NEWEST run (#382). The rollup is about the head commit, but
# it lists every run of a check on that commit, a superseded one included: on ovation PR 312 a
# description check failed, the description was edited, the check passed on the same head, and this
# gate refused the merge on the old failure, so the only way through was pushing a commit nobody
# needed (L179).
#
# "Newest" is decided by startedAt, never by position in the array. The array is not in run order:
# on ovation 305, 310 and 311 (read 2026-09-17) it listed the newer run first as often as last.
# startedAt is what gh reports for both kinds of entry, and it is written as UTC seconds with a
# trailing Z, a form in which comparing the strings compares the instants. A value in any other form
# (fractional seconds would sort wrongly as text) is treated as undated rather than compared.
#
# A check is one workflow's job of one name, or one status context. Two workflows can each carry a
# job called `test`, and a pass in one must not answer for a failure in the other.
#
# Every way this ordering can be wrong fails CLOSED:
#   1. A run that has not finished makes the whole check pending, whatever its date. A queued run has
#      no start time, and gh writes that as the zero time, which would sort OLDEST and let the pass
#      before it answer for a run nobody has seen finish.
#   2. A check with more than one run where any run is undated cannot be put in order, so every run
#      counts, which is what this gate did before.
#   3. Runs tied on the newest start time all count, so a failure started in the same second as a
#      pass is not hidden by it.
verdicts=$(printf '%s' "$rollup" | jq -r '
  def dated: (. // "") as $t
    | if ($t | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
         and ($t | startswith("0001-") | not)
      then $t else null end;
  [.statusCheckRollup[]? | {
    key: [(.__typename // ""), (.workflowName // ""), (.name // .context // "check")],
    name: (.name // .context // "check"),
    result: ((.conclusion // .state // "") | ascii_upcase),
    started: ((.startedAt // .createdAt) | dated)
  } | .finished = (.result | IN("", "PENDING", "EXPECTED") | not)]
  | group_by(.key)
  | map(
      if length == 1 then .
      elif any(.[]; .finished | not) then [first(.[] | select(.finished | not))]
      elif any(.[]; .started == null) then .
      else (map(.started) | max) as $newest | map(select(.started == $newest))
      end)
  | flatten
  | map({name, result})')

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
  #
  # A repository named with --repo that is not this checkout has its workflows on GitHub, not in
  # this folder, whose workflows say nothing about it (claude-config#463). With none at all there is
  # nothing that could be red. With some, whether they run on pull requests cannot be read from
  # here, so the unexplained absence refuses, as it does below; and not knowing refuses too.
  if [ -n "$foreign" ]; then
    case "$(mt_remote_path "$repo_flag" ".github/workflows" "$view_account")" in
      absent) exit 0 ;;
      present)
        deny "PR #$number has NO checks at all, but $repo_flag has workflows (.github/workflows), and from here the gate cannot read whether they run on pull requests, so something may have stopped them being scheduled: a workflow that will not parse, Actions disabled, or a run that never started. Run the merge from a checkout of $repo_flag, where its workflows can be read, or find out which before merging, because an empty check list is indistinguishable from a green one. Deliberate override: ALLOW_RED_MERGE=1 <the same command>."
        ;;
      *)
        deny "PR #$number has NO checks at all, and GitHub did not answer whether $repo_flag has any workflows, so an empty check list cannot be told from one that was never scheduled. Run the merge from a checkout of $repo_flag, where its workflows can be read. Deliberate override: ALLOW_RED_MERGE=1 <the same command>."
        ;;
    esac
  fi
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

# Where the gh invocation's OWN words are in the command, as "start end" character offsets (#382).
#
# The pin has to be read from, and suggested into, exactly that stretch. The whole line used to
# serve for both, and they failed together: a piped merge was told to run
# `gh pr merge 305 --squash 2>&1 | cat --match-head-commit <sha>`, which hands the flag to cat, and
# the reading below then found the flag in that line and let the unpinned merge through with
# nothing saying so. Fixing only the suggestion would leave the next hand written copy of the same
# mistake accepted.
#
# The invocation ends at the first unquoted pipe, `&`, `;`, redirection, parenthesis or newline, and
# a file descriptor number written against its redirection (the 2 of `2>&1`) belongs to the
# redirection. Quotes are tracked, so a `--body` holding a pipe or a semicolon does not end it.
#
# Its one blind spot, stated rather than hidden: a heredoc body is scanned as if it were commands, so
# a body line that itself begins `gh pr merge` would be taken for the invocation. The matcher that
# decided this is a merge strips bodies first, and in that shape the pin is read from the body line,
# finds nothing, and refuses, so the blind spot can only refuse a merge, never let one through.
merge_invocation_bounds() {  # $1 = command ; prints "start end", or fails when there is none
  local cmd="$1" n=${#1} i=0 c="" quote="" start=0 end seg
  local head='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:]]*/)?gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
  local fd='[[:space:]]([0-9]+)$'
  while [ "$i" -le "$n" ]; do
    c="${cmd:$i:1}"   # empty at i == n, so the end of the command closes the last invocation
    if [ -n "$quote" ]; then
      if [ "$c" = "\\" ] && [ "$quote" = '"' ]; then i=$((i + 2)); continue; fi
      [ "$c" = "$quote" ] && quote=""
      i=$((i + 1)); continue
    fi
    case "$c" in
      "\\") i=$((i + 2)); continue ;;
      "'"|'"') quote="$c" ;;
      ""|"|"|"&"|";"|">"|"<"|"("|")"|$'\n')
        seg="${cmd:$start:$((i - start))}"
        if [[ "$seg" =~ $head ]]; then
          end=$i
          if [ "$c" = ">" ] || [ "$c" = "<" ]; then
            [[ "$seg" =~ $fd ]] && end=$((end - ${#BASH_REMATCH[1]}))
          fi
          while [ "$end" -gt "$start" ]; do
            case "${cmd:$((end - 1)):1}" in
              " "|$'\t') end=$((end - 1)) ;;
              *) break ;;
            esac
          done
          printf '%s %s' "$start" "$end"
          return 0
        fi
        start=$((i + 1))
        ;;
    esac
    i=$((i + 1))
  done
  return 1
}

bounds=$(merge_invocation_bounds "$command") || bounds=""
invocation=""
if [ -n "$bounds" ]; then
  inv_start=${bounds% *}
  inv_end=${bounds#* }
  invocation="${command:$inv_start:$((inv_end - inv_start))}"
fi

pinned_sha=$(printf '%s' "$invocation" \
  | grep -oE '\-\-match-head-commit[[:space:]=]+[0-9a-fA-F]+' \
  | grep -oE '[0-9a-fA-F]+$' | awk 'NR <= 1')

if [ -z "$pinned_sha" ]; then
  # The flag goes on the gh invocation itself, before any pipe, redirection or later command, so the
  # command handed back is the one that actually pins. Where the invocation could not be found, say
  # where the flag belongs rather than guess at a line that could hand it to something else.
  if [ -n "$bounds" ]; then
    suggestion="Run: ${command:0:$inv_end} --match-head-commit $head_sha${command:$inv_end} ."
  else
    suggestion="Add --match-head-commit $head_sha to the gh pr merge invocation itself, before any pipe, redirection or following command."
  fi
  deny "PR #$number is green at $head_sha, but the merge does not pin that commit. The rollup just read is about the pull request, not about a commit, so a push landing between this reading and the merge would be merged unjudged and would look identical afterwards. $suggestion GitHub refuses the merge if the head has moved. A flag after a pipe or in a later command pins nothing, so it does not count. Deliberate override: ALLOW_UNPINNED_MERGE=1 <the same command>."
fi

# Pinned to something else is worse than unpinned, not better: it hands GitHub a commit nothing
# here judged while reading as the careful route.
if [ "$(printf '%s' "$pinned_sha" | tr 'A-F' 'a-f')" != "$(printf '%s' "$head_sha" | tr 'A-F' 'a-f')" ]; then
  deny "PR #$number is green at $head_sha, but this merge pins $pinned_sha, which is a different commit and not the one these checks were read for. Merging it would land a commit nothing judged, by the route that is supposed to prevent exactly that. Pin $head_sha instead, or re-read the checks if the head has genuinely moved. Deliberate override: ALLOW_UNPINNED_MERGE=1 <the same command>."
fi

exit 0
