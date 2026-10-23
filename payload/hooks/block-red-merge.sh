#!/bin/bash
# Block `gh pr merge`, or a merge through the GitHub API (claude-config#1181), unless that PR's checks
# are positively green.
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
# And the green has to have been earned against the base the merge lands on: the
# PR head must contain the base branch's current tip (#766). Two PRs that are each
# green can merge into a red main when the second was never tested with the first
# (L85, Try-Pennie/slate 2026-10-04), and on a free plan GitHub offers neither a
# required up to date branch nor a merge queue, so this gate is where it is held.
#
# Deliberate overrides, one per rule and all visible in the command, so none can
# happen by accident or go unnoticed in the transcript: ALLOW_RED_MERGE=1 skips
# the whole gate, SKIP_MERGE_TOOL=1 skips a repo's own merge script,
# ALLOW_BEHIND_MERGE=1 skips the up to date rule, and ALLOW_UNPINNED_MERGE=1
# skips the commit pin. Each answers only its own rule, because one token carrying
# two rules silently widens every use of it (L448).

set -uo pipefail

# The four things every merge gate has to work out before it can say anything
# about a pull request (is this a merge, which directory, which pull request,
# whose answer to trust) live in lib/merge-target.sh, shared with
# require-changelog-tag.sh. They were learned here and each carries the incident
# that produced it; they moved out when the second gate needed them, because two
# copies would drift silently, each passing its own tests while disagreeing about
# which pull request it is looking at.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload=$(cat)

# It runs before EVERY Bash command (claude-config#1181): it used to be registered behind an `if` of
# `Bash(gh pr merge*)`, so Claude Code never ran it for a merge through the GitHub API whatever the
# recogniser said. So the commonest case leaves here, before anything is loaded, by the words every
# merge route names (mt__might_merge in lib/merge-target.sh), as pr-review-gate.sh always has.
case "$payload" in *merge*|*Merge*|*enqueuePullRequest*) ;; *) exit 0 ;; esac

# shellcheck source=lib/merge-target.sh
. "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null || exit 0

# What this gate REFUSES with when a tool it reads through is not installed. On stderr with exit 2
# rather than through deny() below, because deny() builds its JSON with jq and jq is one of the
# tools that can be missing.
refuse_no_reader() {  # $1 = the absence clause, $2 = what it costs, $3 = what to install
  echo "Refusing to merge: $(ps_reader_absent_why "$1" "$2" "$3") Merging a pull request whose checks nothing has read is the mistake this gate exists to stop." >&2
  exit 2
}

# THE PAYLOAD'S OWN READER, asked before the payload is read (claude-config#480, L490).
#
# The command was parsed straight out of the JSON with a bare jq, one line above the `command -v
# gh` that names gh. With no jq the command came back EMPTY, mt_is_pr_merge answered no, and this
# gate exited 0 on every merge with nothing said: an absent reader is the one failure that looks
# exactly like a clean run (L42, L98).
#
# Read through ps_parse_payload, the shared reader, which takes jq OR python3. A machine holding
# either can still read a payload, so the commoner absence costs this gate nothing.
#
# With NEITHER installed nothing here can tell a merge from an `ls`, so what is refused is narrowed
# by the same cheap substring mt_is_pr_merge uses as its own first filter, already asked above: a
# payload naming no merge anywhere in it cannot be one. Refusing every Bash command instead would be a gate nobody
# keeps, and the override habit it teaches protects nothing at all (L36, L54).
if ps_reader_missing jq python3; then
  case "$payload" in
    *ALLOW_RED_MERGE=1*) exit 0 ;;
    *)
      refuse_no_reader "neither jq nor python3 is on PATH" \
        "block-red-merge.sh reads this command out of the hook payload, which is JSON, with one of them, so with neither installed it cannot tell whether this command merges a pull request at all, let alone which one." \
        "jq or python3" ;;
  esac
  exit 0
fi

parsed=$(ps_parse_payload "$payload" raw) || parsed=""
command="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"

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

# THIS GATE'S OWN READS ARE ASKED AGAIN when GitHub did not answer (claude-config#1081). Since #1061
# merge-when-ready.sh retries its reads, but it hands the final pinned merge to this gate, whose one
# shot reads turned a single TLS timeout or reset into a refusal that stopped the merge after the whole
# CI wait. So each read below is a reader returning 0 (answered), 1 (GitHub answered no, or failed in
# a way nobody recognised) or 2 (mt_gh_transient), run through mt_retry_read, the one retry loop the
# helper uses too. A refusal is believed the first time, and a read still failing after its tries
# refuses exactly as before: nothing merges on an unconfirmed read.
#
# The retries have a BUDGET, measured from the start of this hook in the shell's own SECONDS, because
# the harness gives this gate 30 seconds (a setting, not a measurement) and a gate killed for
# overrunning says nothing at all, which is no refusal. A retry whose wait would end past the budget
# is not made. Seams, for the tests and nothing else: BRM_READ_TRIES (3 in all), BRM_READ_RETRY_SECONDS
# (2), BRM_READ_BUDGET_SECONDS (12) and BRM_SLEEP (sleep), all chosen, not measured. None can let a
# merge through: the fewest tries is one, as before.
brm_num(){ case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
READ_TRIES="$(brm_num "${BRM_READ_TRIES:-}" 3)"
READ_WAIT="$(brm_num "${BRM_READ_RETRY_SECONDS:-}" 2)"
READ_DEADLINE="$(brm_num "${BRM_READ_BUDGET_SECONDS:-}" 12)"
READ_SLEEP="${BRM_SLEEP:-sleep}"
read_again(){ mt_retry_read "$READ_TRIES" "$READ_WAIT" "$READ_SLEEP" "$READ_DEADLINE" "" "$1"; }

command -v gh >/dev/null 2>&1 || deny "Cannot verify CI: gh is not on PATH. Merging blind is what this gate exists to stop."

# jq alone, with python3 present: the command above WAS readable, so this is known to be a merge,
# and everything left to do is jq's. gh's answer about the checks arrives as JSON and is read with
# jq all the way down, and deny() builds its own refusal with jq too. A gate that cannot tell a
# green rollup from a red one has to say so rather than fall through the reading and find nothing
# to complain about (claude-config#480, L490).
ps_reader_missing jq && refuse_no_reader "jq is not on PATH" \
  "block-red-merge.sh reads gh's answer about this pull request's checks with it, every field of it, so with jq absent nothing here can tell a green rollup from a red one." \
  "jq"

# The other tool this gate cannot work without, named the same way (claude-config#475). The shared
# library reads which pull request and which repository the merge names with python3, and without
# it both come back empty: this gate then asked gh about whatever pull request the current branch
# resolves to, and a green answer there merged THIS one unjudged. The not found refusal further
# down would have described a pull request nobody could find, which is a true sentence about a
# different fault and sends somebody to name a repository that was never the problem (L11).
mt_reader_missing && deny "Refusing to merge: $(mt_reader_absent_why) Verifying one pull request's checks and merging another is the mistake this gate exists to stop."

# ONE pull request per command (claude-config#1062). Everything below reads the first merge's number,
# repository and directory, so a second merge in the same command, of another pull request or in
# another checkout, landed with nobody having read its checks. This gate asks GitHub about one pull
# request and pins the merge to its head, so it refuses rather than judging each in turn.
if span_why="$(mt_merge_span_why "$command" "$cwd")"; then
  deny "Refusing to merge: $span_why"
fi

# A merge through the GitHub API (claude-config#1181): its pull request is named by its endpoint, or
# by a GraphQL node GitHub resolves here, once, in this shell, so every read below takes that answer.
# One that cannot be named is refused: read as the current branch's pull request, another pull
# request's checks would answer for it. Also sets MT_API_ROUTE and MT_API_PIN, which the commit pin
# at the foot of the file reads.
if mt_api_merge_untold "$command"; then
  deny "Refusing to merge: $MT_API_WHY"
fi
# How this merge is made, in the words a refusal names it by.
case "$MT_API_ROUTE" in
  rest|graphql) merge_route="the GitHub API" ;;
  *) merge_route="gh pr merge" ;;
esac

# The PR number if the command names one; otherwise gh resolves it from the
# current branch, which is also what the merge itself would do.
pr=$(mt_pr_number "$command")

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
      deny "This repo merges through its own commit pinned tool ($pinned_tool), not through $merge_route. Run: $pinned_how . It judges the checks against the commit at the head and hands GitHub that commit, so a push landing in the seconds between the two cannot be merged unjudged, and it confirms afterwards that the commit landed on the base its checks were run against. A plain merge skips all of that and looks identical afterwards. Deliberate override: SKIP_MERGE_TOOL=1 <the same command>, which skips this rule only: the merge must still pin its commit."
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
read_view(){
  envelope=$(mt_pr_view "$pr" "number,statusCheckRollup,mergeable,url,headRefOid,baseRefName,mergeStateStatus" "$remote_slug" "$repo_flag")
  mt_view_class "$envelope"
}
read_again read_view
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
      # Each probe asked again on a transient failure, by the same rule as this gate's other reads
      # (claude-config#1096), and read in this shell so what gh said reaches the refusal.
      mt_pinned_tool_remote "$repo_flag" "$view_account" read_again; remote_rc=$?
      remote_tool="$MT_REMOTE_TOOL"
      if [ "$remote_rc" = 0 ]; then
        deny "$repo_flag merges through its own commit pinned tool ($remote_tool), not through $merge_route. From a checkout of $repo_flag, run: $(mt_pinned_how_for "$remote_tool" "${pr:-}") . It judges the checks against the commit at the head and hands GitHub that commit, and it confirms afterwards that the commit landed on the base its checks were run against. A plain merge skips all of that and looks identical afterwards. Deliberate override: SKIP_MERGE_TOOL=1 <the same command>, which skips this rule only: the merge must still pin its commit."
      elif [ "$remote_rc" = 2 ]; then
        deny "Refusing to merge: could not tell whether $repo_flag carries its own commit pinned merge tool ($remote_tool), because GitHub did not answer that question${MT_REMOTE_ERR:+ (gh said: $MT_REMOTE_ERR)}. Where one exists it is the only way this gate lets that repository merge, so not knowing is not the same as it being absent. Run the merge from a checkout of $repo_flag, where the file can be read from disk. Deliberate override: SKIP_MERGE_TOOL=1 <the same command>."
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
    read_workflows(){ mt_remote_path "$repo_flag" ".github/workflows" "$view_account"; }
    read_again read_workflows
    case "$MT_REMOTE_STATE" in
      absent) exit 0 ;;
      present)
        deny "PR #$number has NO checks at all, but $repo_flag has workflows (.github/workflows), and from here the gate cannot read whether they run on pull requests, so something may have stopped them being scheduled: a workflow that will not parse, Actions disabled, or a run that never started. Run the merge from a checkout of $repo_flag, where its workflows can be read, or find out which before merging, because an empty check list is indistinguishable from a green one. Deliberate override: ALLOW_RED_MERGE=1 <the same command>."
        ;;
      *)
        deny "PR #$number has NO checks at all, and GitHub did not answer whether $repo_flag has any workflows${MT_REMOTE_ERR:+ (gh said: $MT_REMOTE_ERR)}, so an empty check list cannot be told from one that was never scheduled. Run the merge from a checkout of $repo_flag, where its workflows can be read. Deliberate override: ALLOW_RED_MERGE=1 <the same command>."
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
# every repo gets that protection from one flag. A merge through the GitHub API carries the same pin
# in its own words (claude-config#1181): the REST merge endpoint's `sha` parameter, and the GraphQL
# mutation's `expectedHeadOid`, each refused by GitHub when the head has moved.
#
# Reached only on a POSITIVE green reading, deliberately: the empty-rollup paths above exit before
# this, because the pin protects a VERDICT and there is no verdict in a repo with no CI. Requiring
# it there would block those repos for a reason that does not apply to them (L615, L324).
head_sha=$(printf '%s' "$rollup" | jq -r '.headRefOid // ""' 2>/dev/null)

# The repository the pull request is in, read from its own url, which is the one gh just answered
# about, then from what the merge or the folder named. Never from gh's {owner}/{repo} placeholder,
# which is filled in from whatever checkout the call happens to run in (#418). Both rules below ask
# GitHub about it, as the account that could see the pull request.
slug=$(printf '%s' "$rollup" | jq -r '.url // ""' 2>/dev/null \
  | sed -nE 's#^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+.*$#\1#p')
[ -n "$slug" ] || slug="$remote_slug"
# The one step remedy both rules hand over, carrying this merge's own method so it merges the same
# way. Only the flags the helper carries are read; anything else is not its to pass on.
#
# Read from the gh pr merge's OWN words, as the shell reads them, in whichever spelling gh takes
# (claude-config#1351): --squash or -s, --merge or -m, --rebase or -r, --delete-branch or -d, short
# ones clustered (-sd), and --flag=true. Searching the whole command text for the long spellings
# dropped every short one, and took a flag out of a --body or out of another command on the line.
# The value after a flag that takes one is skipped, so a body reading "-m" asks for nothing.
# The words are the merge's own as gh finds them (PS__R_TOOL, shell-words.py tool_field): pr's flags
# written in front of merge (gh pr -R o/x merge 7 -s) and every word after merge. Without a reading
# (python3 is refused above; this is a reader that crashed) no flag is read, so the hint names only
# what the helper said, rather than guessing from text that may hold a --body or another command.
want_squash=""; want_merge=""; want_rebase=""; want_delete=""
brm_merge_words(){   # fills brm_words with the words of the gh pr merge this command runs
  local i end w
  brm_words=()
  if ps__read "$command" || [ "$?" -eq 3 ]; then
    i="${PS__M_FIRST[$PS__HIT]}"; end=$((i + PS__M_COUNT[PS__HIT]))
    while [ "$i" -lt "$end" ]; do
      if ps_runs_at gh "$i" pr merge; then
        # tool 0x1d sub 0x1d action 0x1d the words, 0x1f between
        w="${PS__R_TOOL[$i]#*$'\x1d'*$'\x1d'*$'\x1d'}"
        while [ -n "$w" ]; do
          brm_words+=("${w%%$'\x1f'*}")
          case "$w" in *$'\x1f'*) w="${w#*$'\x1f'}" ;; *) w="" ;; esac
        done
        return 0
      fi
      i=$((i + 1))
    done
    return 0
  fi
}
brm_merge_words
brm_skip=""
for w in ${brm_words[@]+"${brm_words[@]}"}; do
  if [ -n "$brm_skip" ]; then brm_skip=""; continue; fi
  case "$w" in
    --) break ;;
    --squash|--squash=true) want_squash=1 ;;
    --merge|--merge=true) want_merge=1 ;;
    --rebase|--rebase=true) want_rebase=1 ;;
    --delete-branch|--delete-branch=true) want_delete=1 ;;
    --body|--body-file|--subject|--repo|--author-email|--match-head-commit) brm_skip=1 ;;
    --*) ;;
    -?*)
      c="${w#-}"
      while [ -n "$c" ]; do
        case "${c:0:1}" in
          s) want_squash=1 ;;
          m) want_merge=1 ;;
          r) want_rebase=1 ;;
          d) want_delete=1 ;;
          # A flag taking a value takes the rest of the cluster, or the next word when it ends it.
          b|F|t|R|A) [ "${#c}" -eq 1 ] && brm_skip=1; break ;;
          *) break ;;
        esac
        c="${c:1}"
      done ;;
  esac
done
# The helper never hands gh --delete-branch (it deletes the branch itself, after moving the pull
# requests stacked on it, claude-config#1337), so the merge it asks about here cannot show that it
# was asked to delete. It says so in MWR_DELETE_BRANCH=1 when it runs this gate, and the hint carries
# the flag, or following it exactly merges and leaves the branch on GitHub (claude-config#1351).
[ "${MWR_DELETE_BRANCH:-}" = 1 ] && want_delete=1
helper_flags="${want_squash:+ --squash}${want_merge:+ --merge}${want_rebase:+ --rebase}${want_delete:+ --delete-branch}"
helper_cmd="bash ~/.claude/hooks/lib/merge-when-ready.sh $number${slug:+ --repo $slug}$helper_flags"
gh_as_viewer(){   # gh, as the account that could see the pull request when that was not the active one
  local tok=""
  [ -n "$view_account" ] && tok=$(gh auth token -u "$view_account" 2>/dev/null)
  if [ -n "$tok" ]; then GH_TOKEN="$tok" gh "$@"; else gh "$@"; fi
}

# GREEN SO FAR IS NOT GREEN (claude-config#1087). The rollup lists the checks that have REGISTERED on
# the head, and a workflow run can exist for minutes before any of its jobs does. On 2026-10-12 Slate
# #3645 was merged on one check, a green one from a separate fast workflow, while its CI run had been
# waiting on a concurrency group for a minute with no jobs yet: every check that had reported was
# green, and this gate agreed (L98). So the runs GitHub has created for the head are read too, and any
# that has not finished refuses, by whatever name its checks will carry: nothing here knows any
# repository's check names.
#
# Fails CLOSED: a runs read that never answers, or answers with something that is not the list,
# refuses in its own words, because not knowing whether CI is still to come is not knowing it is not
# (L42). A repository with no Actions answers with an empty list, which is nothing to wait for.
#
# A rollup that named no head commit has no runs to ask about, and is not asked: the up to date rule
# and the pin below each refuse a head they cannot name, unless both their overrides are given.
if [ -n "$head_sha" ]; then
  [ -z "$slug" ] && deny "Refusing to merge: nothing here could name the repository PR #$number is in (gh reported no url for it, the merge names none with --repo, and this folder has no GitHub remote), so nothing could read whether CI is still to report on its head ${head_sha:0:7}. Name the repository with --repo owner/name on the merge. Deliberate override: ALLOW_RED_MERGE=1 <the same command>."
  read_runs(){ mt_unfinished_runs "$slug" "$head_sha" "$view_account"; }
  read_again read_runs; runs_rc=$?
  if [ "$runs_rc" -ne 0 ]; then
    deny "Refusing to merge: could not read which workflow runs GitHub has for PR #$number's head ${head_sha:0:7} in $slug (${MT_RUNS_ERR:-no answer}), so nothing here can tell whether CI is still to report on it. Not knowing is not the same as nothing being left to run: the checks reported so far may be a fast few, with the rest not registered yet. Re-run once GitHub answers. Deliberate override: ALLOW_RED_MERGE=1 <the same command>."
  fi
  if [ -n "$MT_RUNS_PENDING" ]; then
    deny "PR #$number is not green yet: every check that has reported on its head ${head_sha:0:7} is green, but GitHub has workflow runs for that head that have not finished: $MT_RUNS_PENDING. Their checks have not all registered, so the green so far is about part of the head's CI, which is how Slate #3645 was merged before its CI ran (claude-config#1087). Wait for them, or have it done in the background from a checkout of the repository: $helper_cmd . It waits for those runs and the lessons review, then merges only that head. Deliberate override: ALLOW_RED_MERGE=1 <the same command>."
  fi
fi

# UP TO DATE WITH THE BASE (#766). Green is a verdict on the head commit as it was built, which is
# on top of whatever base the branch was cut from. If the base has moved since, the combination main
# will hold after this merge was never tested: on 2026-10-04 Try-Pennie/slate #3237 was green, was
# branched before #3231 landed, merged after it, and turned main red (L85). So the head must CONTAIN
# the base branch's current tip, and with the green rollup above and the commit pin below, a merge
# then always lands a combination that was tested.
#
# Asked of GitHub's compare endpoint, BASE...HEAD, rather than of a local fetch, because this gate
# runs from worktrees, from /private/tmp and for repositories named with --repo that are not checked
# out here at all, and the answer has to be about the repository the pull request is in. behind_by is
# the number of commits on the base that the head does not have, so zero is up to date, whatever the
# base branch is called: it is the pull request's own base by name, never an assumed main.
#
# The repository is read from the pull request's own url, which is the one gh just answered about,
# then from what the merge or the folder named. Never from gh's {owner}/{repo} placeholder, which is
# filled in from whatever checkout the call happens to run in (#418): with no repository to name,
# this rule refuses rather than asking about one it cannot. Asked as the account that could see the
# pull request, for the same reason the view was.
#
# GitHub's mergeStateStatus is a second signal and only ever adds a refusal: BEHIND refuses even
# where the comparison read clean, while UNKNOWN, which GitHub answers while it is still working
# mergeability out, is evidence of nothing and leaves the comparison to decide.
#
# Fails CLOSED: a comparison gh could not make, or one that came back without a readable status and
# distance, refuses in its own words rather than reading as up to date (L42, L11).
#
# Reached only on a positive green reading, like the pin, so a repository with no checks is not even
# asked: there is no verdict there to have been earned against an old base (L615).
case "$command" in
  *ALLOW_BEHIND_MERGE=1*) ;;
  *)
    base_ref=$(printf '%s' "$rollup" | jq -r '.baseRefName // ""' 2>/dev/null)
    merge_state=$(printf '%s' "$rollup" | jq -r '.mergeStateStatus // ""' 2>/dev/null)
    update_cmd="gh pr update-branch $number${slug:+ --repo $slug}"
    behind_override="Deliberate override: ALLOW_BEHIND_MERGE=1 <the same command>, which skips this rule only: the checks must still be green and the merge must still pin its commit."

    [ -z "$base_ref" ] && deny "Refusing to merge: gh did not report which base branch PR #$number merges into, so nothing here could read that branch's current tip or tell whether the head contains it. A green verdict earned against an older base says nothing about what main will hold after the merge. Check the pull request's base, then re-run. $behind_override"
    [ -z "$head_sha" ] && deny "Refusing to merge: PR #$number reads green, but gh did not report its head commit, so nothing here could tell whether that head contains the current tip of $base_ref. Check which commit is at the head, then re-run. $behind_override"

    [ -z "$slug" ] && deny "Refusing to merge: nothing here could name the repository PR #$number is in (gh reported no url for it, the merge names none with --repo, and this folder has no GitHub remote), so nothing could read the current tip of its base branch $base_ref or tell whether the head contains it. Name the repository with --repo owner/name on the merge. $behind_override"
    # A comparison gh could not make is asked again only when what it printed names the transport or
    # GitHub's server (#1081); its readable answer is judged below whatever came back.
    read_compare(){
      local errf errs
      errf=$(mktemp "${TMPDIR:-/tmp}/brm-compare.XXXXXX" 2>/dev/null) || errf=/dev/null
      compare=$(gh_as_viewer api "repos/$slug/compare/$base_ref...$head_sha?per_page=1" 2>"$errf"); compare_rc=$?
      errs=$(cat "$errf" 2>/dev/null)
      compare_why=$(awk 'NF { print; exit }' "$errf" 2>/dev/null)
      [ "$errf" != /dev/null ] && rm -f "$errf"
      [ "$compare_rc" -eq 0 ] && return 0
      mt_gh_transient "$errs" && return 2
      return 1
    }
    read_again read_compare

    compare_status=$(printf '%s' "$compare" | jq -r '.status // ""' 2>/dev/null)
    behind_by=$(printf '%s' "$compare" | jq -r '.behind_by // ""' 2>/dev/null)
    case "$behind_by" in ''|*[!0-9]*) behind_by="" ;; esac
    case "$compare_status" in ahead|identical|behind|diverged) ;; *) behind_by="" ;; esac
    if [ "$compare_rc" != 0 ] || [ -z "$behind_by" ]; then
      deny "Refusing to merge: could not read whether PR #$number contains the current tip of its base branch $base_ref${slug:+ in $slug}, because GitHub's comparison of the two did not answer with a status and a distance this could read${compare_why:+ ($compare_why)}. Not knowing is not the same as being up to date: a green verdict earned against an older base says nothing about what $base_ref will hold after the merge. Re-run once GitHub answers. $behind_override"
    fi

    if [ "$behind_by" != 0 ] || [ "$merge_state" = "BEHIND" ]; then
      if [ "$behind_by" = 0 ]; then
        distance="GitHub reports it BEHIND $base_ref"
      elif [ "$behind_by" = 1 ]; then
        distance="it is 1 commit behind $base_ref"
      else
        distance="it is $behind_by commits behind $base_ref"
      fi
      deny "PR #$number is green, but its head does not contain the current tip of its base branch: $distance. Its checks were earned against an older base, so the combination $base_ref would hold after this merge has never been tested, which is how two green pull requests turn main red (L85). Run: $update_cmd , then wait for the new checks on the updated head to go green, and merge that head. Or do all of that in one step, in the background, from a checkout of the repository: $helper_cmd . It updates the branch, waits for the new head's checks and lessons review, asks this gate and the review gate about the exact pinned merge, and merges only that head (claude-config#851). $behind_override"
    fi
    ;;
esac

case "$command" in
  *ALLOW_UNPINNED_MERGE=1*) exit 0 ;;
esac

# Green, but gh did not say which commit it was green FOR. Fails closed, in its own words: telling
# somebody to add a flag whose value nothing here can supply is a refusal that cannot be cleared
# by the remedy it names (L11, L109).
[ -z "$head_sha" ] && deny "PR #$number reads green, but gh did not report its head commit, so this merge cannot be pinned to the commit those checks were actually run for. A rollup is about the pull request, not about a commit, and it is read a moment before the merge: without the pin, a push landing in between is merged unjudged and looks identical afterwards. Check which commit is at the head and that its checks are the green ones, then merge with ALLOW_UNPINNED_MERGE=1 <the same command>."

# The commit this merge pins, read by lib/merge-target.sh's mt_merge_pin, which holds the reasoning
# (#382, claude-config#1181): only the gh pr merge invocation's own words count, or the API call's.
# The verification merge check reads the same answer (claude-config#1529), so a flag after a pipe
# pins nothing for either gate (L613).
mt_merge_pin "$command"
bounds="$MT_PIN_BOUNDS"
inv_end="$MT_PIN_INV_END"
pinned_sha="$MT_PIN_SHA"

if [ -z "$pinned_sha" ]; then
  # The flag goes on the gh invocation itself, before any pipe, redirection or later command, so the
  # command handed back is the one that actually pins. Where the invocation could not be found, say
  # where the flag belongs rather than guess at a line that could hand it to something else.
  if [ "$MT_API_ROUTE" = rest ]; then
    suggestion="Add -f sha=$head_sha to the API call itself, which GitHub's merge endpoint takes as the head the pull request must still have."
  elif [ "$MT_API_ROUTE" = graphql ]; then
    suggestion="Add expectedHeadOid: \"$head_sha\" to the mutation's input, which GitHub takes as the head the pull request must still have."
  elif [ -n "$bounds" ]; then
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
