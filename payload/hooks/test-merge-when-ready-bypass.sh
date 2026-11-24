#!/usr/bin/env bash
# Tests for lib/merge-when-ready.sh's bypass merge, the one merge it sends with --admin itself, and
# for sleep mode outranking it (claude-config#3534), with sleep mode's judgement asked through
# lib/sleep-admin-merge.mjs and the rulesets GitHub answered with in
# merge-when-ready-fixtures/review-bypass-2026-11-24.
#
# These were section 34 of test-merge-when-ready.sh until claude-config#3572. They added 249 checks
# and about 48 runs of the helper, each a second or more, to a suite that was already near
# run-all-tests.sh's 1,200 second wall limit, and on 2026-11-24 it ran out of time on a slow GitHub
# runner (exit 124), which stopped the config sync between the two Macs. A suite of their own is
# dealt to a part by its own measured cost (L315). Every check is as it was there.
#
# The world they run in (the fake gh, the injected clock and sleep, the stub gates and review
# checker, the checkout, the counters and the result line) is lib/merge-when-ready-harness.sh, the
# one place both suites take it from, so nothing of it is copied here. Nothing reaches the network
# or a real pull request (L2).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/merge-when-ready-harness.sh" || {
  echo "FAIL: $(basename "$0"): lib/merge-when-ready-harness.sh is missing, so there is no world to run the helper in. Refusing to run."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
mwr_harness_build

# =================================================================================================
# The bypass merge it sends itself (claude-config#3534). On 2026-11-24, in a repository whose
#     ruleset asks for one code owner approval and lets a team bypass it for pull requests, every
#     gate passed and then gh refused the merge: "the base branch policy prohibits the merge". gh
#     refuses a blocked pull request itself unless --admin is passed, and --admin is refused here as
#     an argument (test-merge-when-ready.sh, section 1), so the only way through was a second
#     command sent by hand. Now the helper sends that merge itself, with --admin and the same pin, and only when GitHub's own
#     answers at that moment say the review is the one thing missing and that the account merging
#     may bypass the ruleset asking for it. Anything else, an answer that could not be read
#     included, stops as before, saying the review is missing.
#     The fixtures are the shapes GitHub answered with on 2026-11-24 (the rules in force on a
#     branch, and each ruleset as the account asking is shown it), with every owner, repository,
#     team, name and id replaced by an invented one.
# =================================================================================================
BY_FIX="$DIR/merge-when-ready-fixtures/review-bypass-2026-11-24"
BY_AS='as a bypass of the approving review the ruleset "Owner approves main" requires'
by_state(){   # a green, up to date pull request the base branch's rules block for a missing review
  fresh "$OLD" 0 "$GREEN"
  : > "$ST/policy-blocks"; printf 'REVIEW_REQUIRED' > "$ST/review-decision"
  cp "$BY_FIX/rules.json" "$ST/rules"; cp "$BY_FIX/ruleset-501.json" "$ST/ruleset-501"; cp "$BY_FIX/ruleset-502.json" "$ST/ruleset-502"
}
by_edit(){ jq -c "$2" "$ST/$1" > "$ST/$1.tmp" && mv "$ST/$1.tmp" "$ST/$1"; }   # by_edit <state file> <jq filter>
by_admin(){ count gh-calls 'pr merge .* --admin '; }
by_refused(){   # by_refused <the case> <exit> <output>: a refusal sends no bypass merge and names the review
  check_eq "#3534 $1: it stops for a person" "1" "$2"
  check_eq "#3534 $1: no bypass merge is sent" "0" "$(by_admin)"
  check_eq "#3534 $1: nothing merged" "no" "$( [ -e "$ST/merged" ] && echo yes || echo no)"
  check "#3534 $1: it says an approving review is missing" "GitHub refused the merge of #7 at ${OLD:0:7} for main's branch policy: it lacks an approving review GitHub requires" "$3"
  check "#3534 $1: and that no bypass merge was sent" "No bypass merge was sent and nothing was merged." "$3"
}

# The review is the one thing missing and the account may bypass its ruleset: merged, as a bypass.
by_state
out="$(run 7 --repo acme/widget --squash --delete-branch --log="$WORKDIR/by.log")"; rc=$?
check_eq "#3534 a merge blocked only for a review the account may bypass merges" "0" "$rc"
check "#3534 said as a bypass of the review, naming the ruleset" "Merged #7 in acme/widget at ${OLD:0:7} $BY_AS. Deleted its branch feat/x." "$out"
check "#3534 and so does its log" "Merged #7 in acme/widget at ${OLD:0:7} $BY_AS" "$(cat "$WORKDIR/by.log")"
check_eq "#3534 the plain merge is tried first, then the bypass merge" "pr merge 7 --repo acme/widget --squash --match-head-commit $OLD|pr merge 7 --repo acme/widget --squash --admin --match-head-commit $OLD" "$(grep '^pr merge' "$ST/gh-calls" | tr '\n' '|' | sed 's/|$//')"
check "#3534 the checks gate is asked about the exact bypass command" "gh pr merge 7 --repo acme/widget --squash --admin --match-head-commit $OLD" "$(cat "$ST/red-gate-payloads")"
check "#3534 it says why it may, in GitHub's own word" "current_user_can_bypass: pull_requests_only" "$out"
check_eq "#3534 every ruleset in force on the branch is read, once each" "rulesets/501 rulesets/502" "$(grep -o 'rulesets/[0-9]*' "$ST/gh-calls" | sort | tr '\n' ' ' | sed 's/ $//')"
check_eq "#3534 the branch is deleted, once" "feat/x" "$(cat "$ST/deleted" 2>/dev/null)"
# A second run finds it merged: nothing more is read about a bypass, and nothing is merged again.
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#3534 a second run finds it merged" "0" "$rc"
check "#3534 and says so" "is already merged" "$out"
check_eq "#3534 with no second bypass merge" "1" "$(by_admin)"
check_eq "#3534 and no second read of the rules" "1" "$(count gh-calls 'rules/branches')"

# The REAL checks gate judges the bypass command as it judges the plain one: pinned to the head it
# read green, so the gate that insists on the pin allows it (L52).
by_state
out="$(MWR_RED_GATE="$DIR/block-red-merge.sh" run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#3534 the real block-red-merge.sh allows the pinned bypass merge" "0" "$rc"
check "#3534 and it merges as a bypass" "Merged #7 in acme/widget at ${OLD:0:7} $BY_AS" "$out"
# A bypass command the checks gate refuses is never sent.
by_state; printf 'the checks went red' > "$ST/red-gate-deny-admin"
out="$(run 7 --squash)"; rc=$?
check_eq "#3534 a bypass merge the checks gate refuses stops" "1" "$rc"
check "#3534 in the gate's words" "block-red-merge.sh refused the bypass merge of #7 at ${OLD:0:7}: the checks went red" "$out"
check_eq "#3534 and is not sent" "0" "$(by_admin)"

# Control: a merge nothing blocks reads none of this, and a typed --admin is still refused
# (test-merge-when-ready.sh, section 1).
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --squash)"; rc=$?
check_eq "#3534 control: an ordinary merge merges" "0" "$rc"
check_eq "#3534 control: with no read of the rules" "0" "$(count gh-calls 'rules/branches')"
check_eq "#3534 control: and no bypass merge" "0" "$(by_admin)"
check_not "#3534 control: and is not called a bypass" "bypass" "$out"

# The account may not bypass the ruleset that asks for the review.
by_state; by_edit ruleset-501 '.current_user_can_bypass = "never"'
out="$(run 7 --squash)"; rc=$?
by_refused "an account that may not bypass" "$rc" "$out"
check "#3534 it says the account may not bypass it, naming the ruleset and GitHub's answer" 'the active gh account may not bypass the ruleset "Owner approves main" that requires it (GitHub answers current_user_can_bypass: never)' "$out"
check "#3534 and what to do" "Have it approved, then run the same command again." "$out"

# An answer that cannot be read is never taken as permission.
by_state; by_edit ruleset-501 'del(.current_user_can_bypass)'
out="$(run 7 --squash)"; rc=$?
by_refused "a ruleset that does not say" "$rc" "$out"
check "#3534 it says GitHub did not say" 'GitHub did not say whether the active gh account may bypass the ruleset "Owner approves main"' "$out"
by_state; by_edit ruleset-501 '.current_user_can_bypass = "exempt"'
out="$(run 7 --squash)"; rc=$?
by_refused "an answer it does not know" "$rc" "$out"
by_state; printf 'gh: Server Error (HTTP 502)\n' > "$ST/ruleset-down"
out="$(run 7 --squash)"; rc=$?
by_refused "a ruleset GitHub would not show" "$rc" "$out"
check "#3534 it names the read that failed, and that it was asked again" "could not read ruleset 501 of acme/widget (gh: Server Error (HTTP 502), still failing after 4 tries" "$out"
check "#3534 and that an unread answer is not permission" "an answer that cannot be read is never taken as permission" "$out"
by_state; rm -f "$ST/ruleset-502"
out="$(run 7 --squash)"; rc=$?
by_refused "a ruleset GitHub answers 404 for" "$rc" "$out"
by_state; printf 'gh: Server Error (HTTP 502)\n' > "$ST/rules-down"
out="$(run 7 --squash)"; rc=$?
by_refused "rules GitHub would not list" "$rc" "$out"
check "#3534 it names the list" "could not read the rules in force on main in acme/widget" "$out"
by_state; printf '{"message":"nothing like a list"}' > "$ST/rules"
out="$(run 7 --squash)"; rc=$?
by_refused "an answer that is not a list of rules" "$rc" "$out"
by_state; by_edit rules '. as $r | [range(0; 100) | $r[0]]'
out="$(run 7 --squash)"; rc=$?
by_refused "a list GitHub may have cut short" "$rc" "$out"
check "#3534 it says the list may be cut short" "100 rules or more" "$out"
# A read made again after GitHub failed once is still believed.
by_state; printf 'gh: Server Error (HTTP 502)\n' > "$ST/ruleset-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#3534 a ruleset read GitHub fails once is asked again, and it merges" "0" "$rc"
check "#3534 as a bypass" "$BY_AS" "$out"

# The review is not simply still to come: nothing about a bypass is read at all.
for decision in CHANGES_REQUESTED APPROVED ""; do
  by_state; printf '%s' "$decision" > "$ST/review-decision"
  out="$(run 7 --squash)"; rc=$?
  check_eq "#3534 a blocked merge whose review reads '$decision' stops" "1" "$rc"
  check "#3534 '$decision': as the merge GitHub refused" "Stopped: gh pr merge did not merge #7 at ${OLD:0:7}: X Pull request acme/widget#7 is not mergeable: the base branch policy prohibits the merge." "$out"
  check "#3534 '$decision': saying how GitHub reads its review" "GitHub reads its review as ${decision:-not required}, not as an approving review still to come" "$out"
  check_eq "#3534 '$decision': no bypass merge is sent" "0" "$(by_admin)"
  check_eq "#3534 '$decision': and the rules are not read" "0" "$(count gh-calls 'rules/branches')"
done

# Every rule asking for a review must be one the account may bypass, and one must be found.
by_state
by_edit rules '. + [.[-1] | .ruleset_id = 503]'
jq -c '.id = 503 | .name = "Second approval" | .current_user_can_bypass = "never"' "$BY_FIX/ruleset-501.json" > "$ST/ruleset-503"
out="$(run 7 --squash)"; rc=$?
by_refused "a second review the account may not bypass" "$rc" "$out"
check "#3534 it names the ruleset it may not bypass" 'may not bypass the ruleset "Second approval" that requires it' "$out"
# Two rulesets ask for a review and the account may bypass both: merged, naming both.
by_state
by_edit rules '. + [.[-1] | .ruleset_id = 503]'
jq -c '.id = 503 | .name = "Second approval"' "$BY_FIX/ruleset-501.json" > "$ST/ruleset-503"
out="$(run 7 --squash)"; rc=$?
check_eq "#3534 two reviews the account may bypass merge" "0" "$rc"
check "#3534 naming both rulesets" 'as a bypass of the approving review the rulesets "Owner approves main" and "Second approval" require' "$out"
by_state; by_edit rules 'map(select(.ruleset_id == 502))'
out="$(run 7 --squash)"; rc=$?
by_refused "a review no ruleset asks for" "$rc" "$out"
check "#3534 it says no ruleset asks for the review" "no ruleset in force on main asks for that review" "$out"
by_state; by_edit rules 'map(if .ruleset_id == 501 then del(.parameters) else . end)'
out="$(run 7 --squash)"; rc=$?
by_refused "a pull request rule with nothing to read" "$rc" "$out"

# The bypass is for the missing review alone: a ruleset the account may bypass must hold nothing
# else a bypass merge would skip, whichever ruleset that is.
by_state; by_edit rules '. + [{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"deploy preview","integration_id":15368}]},"ruleset_source_type":"Repository","ruleset_source":"acme/widget","ruleset_id":501}]'
out="$(run 7 --squash)"; rc=$?
by_refused "a bypassed ruleset that also requires checks" "$rc" "$out"
check "#3534 it names the rule a bypass would skip, and its ruleset" 'the ruleset "Owner approves main", which the active gh account may bypass, also holds a required_status_checks rule that a bypass merge would skip unjudged' "$out"
by_state; by_edit ruleset-502 '.current_user_can_bypass = "always"'
out="$(run 7 --squash)"; rc=$?
by_refused "another ruleset the account may bypass" "$rc" "$out"
check "#3534 it names that ruleset's rule" 'the ruleset "Protect main", which the active gh account may bypass, also holds a required_status_checks rule' "$out"
by_state; by_edit rules 'map(if .ruleset_id == 501 then .parameters.required_review_thread_resolution = true else . end)'
out="$(run 7 --squash)"; rc=$?
by_refused "a ruleset that also wants conversations resolved" "$rc" "$out"
check "#3534 it says so" 'the ruleset "Owner approves main" also requires every review conversation resolved' "$out"
by_state; by_edit rules 'map(if .ruleset_id == 501 then .parameters.allowed_merge_methods = ["merge"] else . end)'
out="$(run 7 --squash)"; rc=$?
by_refused "a ruleset that does not allow the merge method" "$rc" "$out"
check "#3534 it names the method" 'the ruleset "Owner approves main" does not allow merging by squash' "$out"
# The method is read from the flag as it was passed, short or long.
by_state; by_edit rules 'map(if .ruleset_id == 501 then .parameters.allowed_merge_methods = ["squash", "rebase"] else . end)'
out="$(run 7 -m)"; rc=$?
by_refused "a short flag naming a method the ruleset does not allow" "$rc" "$out"
check "#3534 it names that method" 'the ruleset "Owner approves main" does not allow merging by merge commit' "$out"
by_state; by_edit rules 'map(if .ruleset_id == 501 then .parameters.allowed_merge_methods = ["squash", "rebase"] else . end)'
out="$(run 7 -s)"; rc=$?
check_eq "#3534 a short flag naming a method the ruleset allows merges" "0" "$rc"
check "#3534 as a bypass" "pr merge 7 --repo acme/widget -s --admin --match-head-commit $OLD" "$(cat "$ST/gh-calls")"
# Control: a rule no pull request merge can break, in the ruleset being bypassed, changes nothing.
by_state; by_edit rules '. + [{"type":"deletion","ruleset_source_type":"Repository","ruleset_source":"acme/widget","ruleset_id":501}]'
out="$(run 7 --squash)"; rc=$?
check_eq "#3534 control: a rule a merge cannot break in the bypassed ruleset still merges" "0" "$rc"
check "#3534 control: as a bypass" "$BY_AS" "$out"

# A merge queue is never jumped.
by_state; by_edit rules '. + [{"type":"merge_queue","parameters":{"merge_method":"SQUASH"},"ruleset_source_type":"Repository","ruleset_source":"acme/widget","ruleset_id":502}]'
out="$(run 7 --squash)"; rc=$?
by_refused "a base branch with a merge queue" "$rc" "$out"
check "#3534 it says the queue would be jumped" "main has a merge queue, which a bypass merge would jump" "$out"

# Classic branch protection is nothing a ruleset answers for.
BY_CLASSIC_ON='{"name":"main","protected":true,"protection":{"enabled":true,"required_status_checks":{"enforcement_level":"non_admins","contexts":["tests"],"checks":[]}}}'
by_state; printf '%s' "$BY_CLASSIC_ON" > "$ST/branch-summary"
printf '%s' '{"url":"https://api.github.com/repos/acme/widget/branches/main/protection","required_pull_request_reviews":{"required_approving_review_count":1},"enforce_admins":{"enabled":false}}' > "$ST/classic"
out="$(run 7 --squash)"; rc=$?
by_refused "a branch with classic protection too" "$rc" "$out"
check "#3534 it says classic protection is there" "main also has classic branch protection, which a bypass merge can skip and no ruleset answers for" "$out"
by_state; printf '%s' "$BY_CLASSIC_ON" > "$ST/branch-summary"; : > "$ST/classic-hidden"
out="$(run 7 --squash)"; rc=$?
by_refused "classic protection the account is not shown" "$rc" "$out"
check "#3534 it says that could not be read" "whether main also has classic branch protection could not be read" "$out"
by_state; printf '%s' '{"name":"main"}' > "$ST/branch-summary"
out="$(run 7 --squash)"; rc=$?
by_refused "a branch GitHub does not describe" "$rc" "$out"
by_state; printf 'gh: Server Error (HTTP 502)\n' > "$ST/branch-down"
out="$(run 7 --squash)"; rc=$?
by_refused "a branch GitHub would not show" "$rc" "$out"
# Control: GitHub marking the branch protected, with no classic protection behind it, still merges.
by_state; printf '%s' "$BY_CLASSIC_ON" > "$ST/branch-summary"
out="$(run 7 --squash)"; rc=$?
check_eq "#3534 control: protection that turns out to be the rulesets' own still merges" "0" "$rc"
check "#3534 control: as a bypass" "$BY_AS" "$out"

# The head moves between the gates and the bypass merge: the pin refuses it, and the new head is
# judged afresh, as on the plain path.
by_state; printf '%s\n' "printf '%s' $NEW > \"\$ST/head\"" > "$ST/on-rules-read"
out="$(run 7 --squash)"; rc=$?
check_eq "#3534 a head that moves before the bypass merge merges as the new head" "0" "$rc"
check "#3534 the pin on the old head is refused, and said" "The head moved while it was being merged (GitHub refused the pin on ${OLD:0:7}); judging the new head." "$out"
check "#3534 merged at the new head, as a bypass" "Merged #7 in acme/widget at ${NEW:0:7} $BY_AS" "$out"
check_eq "#3534 the old head was sent as a bypass once, never again" "1" "$(count gh-calls "pr merge 7 .*--admin --match-head-commit $OLD")"
check_eq "#3534 every gate judged the new head before it merged" "yes" "$(grep -q "match-head-commit $NEW" "$ST/review-gate-payloads" && echo yes || echo no)"
check_eq "#3534 and the rules were read again for it" "2" "$(count gh-calls 'rules/branches')"

# GitHub's rate limit and its Something went wrong, answered to the bypass merge, are handled as
# they are for the plain one: nothing merged, so every gate and every reading is asked again.
by_state; printf '%s\n' "$LIMITED" > "$ST/admin-merge-fails"
printf 'HTTP/2.0 200 OK\r\n\r\n{"resources":{"core":{"limit":5000,"remaining":4989,"reset":1003600},"graphql":{"limit":5000,"remaining":4900,"reset":1003600}}}\n' > "$ST/probe"
out="$(run 7 --squash)"; rc=$?
check_eq "#3534 a bypass merge refused for the rate limit merges once it lifts" "0" "$rc"
check "#3534 said as a rate limit" "GitHub refused the merge of #7 for its rate limit" "$out"
check_eq "#3534 two bypass merges, a pause apart" "2" "$(by_admin)"
check_not "#3534 a rate limit is not a stop" "Stopped" "$out"
by_state; printf '%s\n' "$LIMITED" > "$ST/rules-fails"
printf 'HTTP/2.0 200 OK\r\n\r\n{"resources":{"core":{"limit":5000,"remaining":4989,"reset":1003600},"graphql":{"limit":5000,"remaining":4900,"reset":1003600}}}\n' > "$ST/probe"
out="$(run 7 --squash)"; rc=$?
check_eq "#3534 a rules read refused for the rate limit is made again after the pause, and it merges" "0" "$rc"
check "#3534 said as a rate limit on that read" "GitHub refused reading the rules in force on main in acme/widget for its rate limit" "$out"
check_eq "#3534 with one bypass merge" "1" "$(by_admin)"
by_state; printf '%s\n' "$WRONG" > "$ST/admin-merge-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#3534 a bypass merge GitHub answers Something went wrong merges on the next try" "0" "$rc"
check "#3534 the retry is said" "GitHub answered the merge of #7 at ${OLD:0:7} with Something went wrong (try 1 of 3" "$out"
check_eq "#3534 after the 2 minute wait" "1" "$(count sleeps '^120$')"
check_eq "#3534 the checks gate judged each bypass command" "2" "$(grep -c -- ' --admin ' "$ST/red-gate-payloads")"
by_state; printf '%s\n%s\n%s\n%s\n' "$WRONG" "$WRONG" "$WRONG" "$WRONG" > "$ST/admin-merge-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#3534 a bypass merge GitHub keeps answering Something went wrong stops" "1" "$rc"
check_eq "#3534 after three tries" "3" "$(by_admin)"
check "#3534 naming the error and the tries" "with Something went wrong 3 times, 2m apart" "$out"

# GitHub refuses the bypass itself, whatever was read: it stops in GitHub's words, nothing merged.
by_state; printf 'GraphQL: Repository rule violations found. At least 1 approving review is required by reviewers with write access. (mergePullRequest)\n' > "$ST/bypass-denied"
out="$(run 7 --squash)"; rc=$?
check_eq "#3534 a bypass merge GitHub refuses stops" "1" "$rc"
check "#3534 saying it was sent as a bypass, with GitHub's refusal" "Stopped: GitHub did not merge #7 at ${OLD:0:7} $BY_AS: GraphQL: Repository rule violations found." "$out"
check_eq "#3534 one bypass merge, not tried again" "1" "$(by_admin)"
check_eq "#3534 and nothing merged" "no" "$( [ -e "$ST/merged" ] && echo yes || echo no)"

# Whether an account may bypass is GitHub's answer about the account ASKING, so every ruleset is
# read as the account the merge is made as, never the one that happened to read the pull request.
by_state; printf 'reader\nwriter\n' > "$ST/accounts"; printf READ > "$ST/perm-reader"
out="$(run 7 --squash)"; rc=$?
check_eq "#3534 a merge made as a second account merges as a bypass" "0" "$rc"
check_eq "#3534 every ruleset was read as the account that merges" "writer" "$(sort -u "$ST/ruleset-asked" | tr '\n' ' ' | sed 's/ $//')"
check_eq "#3534 and the bypass merge was made as it" "writer" "$(tail -n 1 "$ST/merge-as")"
check "#3534 which the line names" "which writer may bypass" "$out"

# SLEEP MODE OUTRANKS THE BYPASS (Dan, 2026-11-24: "Respect sleep mode first"). The bypass merge is made
# inside the helper, where no hook sees it, so while this Mac is asleep the helper asks sleep mode's
# own judgement of an admin merge in that repository tonight, at the moment of the bypass, and
# sends it only where that allows one. The judgement is the scope modes mod's (readSleep and
# adminMergeNightRefusal), asked through lib/sleep-admin-merge.mjs under node, so no rule of it is
# written a second time here or in the helper. Every case above ran with no sleep record (the
# suite's CLAUDE_SLEEP_RECORD names none), which is sleep mode off. Here the record is one of this
# boot, as a fixed sysctl prints it, ending long after the suite's clock (1000000 s, which is
# 1000000000 ms, the unit the record keeps its end in).
BY_ENTRY="$DIR/lib/sleep-admin-merge.mjs"
BY_SLEEP="$WORKDIR/by-sleep"; BY_REC="$BY_SLEEP/current.json"; mkdir -p "$BY_SLEEP/bin" "$BY_SLEEP/no-node"
BY_BOOT='{ sec = 1700000000, usec = 0 } Tue Nov 14 17:13:20 2023'
BY_SESSION='11111111-2222-3333-4444-555555555555'
printf '#!/usr/bin/env bash\ncase "$*" in\n  "-n kern.boottime") echo "%s" ;;\n  "-n kern.bootsessionuuid") echo "%s" ;;\n  *) exit 1 ;;\nesac\n' "$BY_BOOT" "$BY_SESSION" > "$BY_SLEEP/bin/sysctl"
# A node that cannot run the mod's judgement, as one too old to read its TypeScript answers.
printf '#!/usr/bin/env bash\necho "TypeError [ERR_UNKNOWN_FILE_EXTENSION]: Unknown file extension .ts" >&2\nexit 1\n' > "$BY_SLEEP/no-node/node"
chmod +x "$BY_SLEEP/bin/sysctl" "$BY_SLEEP/no-node/node"
by_night(){   # by_night <the night's lists, as JSON> [<when it ends, in ms>]: the record of a sleep of this boot
  jq -nc --argjson repos "$1" --argjson until "${2:-2000000000000}" --arg session "$BY_SESSION" '{v: 1, generation: "g", since: 1, until: $until, night: "2026-11-24", bootTime: 1700000000, bootSession: $session, report: "r", startedBy: {sessionId: "s", cwd: "/"}, workers: [], placeBefore: "home", repos: $repos}' > "$BY_REC"
}
by_lists(){ jq -nc --argjson e "$1" '{mayDeploy: [], mergeOnly: [$e], closed: []}'; }   # by_lists <one mergeOnly entry>
# What sleep mode answers for acme/widget at the suite's clock, asked of the entry directly: its verdict and why.
by_verdict(){ node --experimental-strip-types --no-warnings "$BY_ENTRY" "$BY_REC" acme/widget 1000000000 "$BY_BOOT" "${1:-$BY_SESSION}" 2>&1 | jq -r '[.verdict, (.why // "")] | join(": ")' 2>&1; }
by_asleep(){ PATH="$BY_SLEEP/bin:$PATH" CLAUDE_SLEEP_RECORD="$BY_REC" run "$@"; }
BY_OPTED='{"repo":"acme/widget","mergeDeploys":false,"adminMerge":"green-pinned"}'
BY_PLAIN='{"repo":"acme/widget","mergeDeploys":false}'
BY_SLEEP_NO="sleep mode is on and does not allow a merge past that review in acme/widget tonight (sleep mode will not admin merge a PR in acme/widget"

# Asleep, in a repository whose entry allows an admin merge tonight: sent, and said.
by_state; by_night "$(by_lists "$BY_OPTED")"
out="$(by_asleep 7 --squash)"; rc=$?
check_eq "#3534 asleep, where sleep mode allows an admin merge tonight, the bypass merge merges" "0" "$rc"
check "#3534 asleep and allowed: as a bypass" "Merged #7 in acme/widget at ${OLD:0:7} $BY_AS" "$out"
check "#3534 asleep and allowed: it says sleep mode allows it" "Sleep mode is on, and it allows a merge past an approving review in acme/widget tonight" "$out"
check_eq "#3534 asleep and allowed: said once, though sleep mode is asked twice" "1" "$(printf '%s\n' "$out" | grep -c 'Sleep mode is on, and it allows')"
check_eq "#3534 asleep and allowed: one bypass merge" "1" "$(by_admin)"

# Asleep, merge only, with no adminMerge on its entry: nothing merges there overnight past an approval.
by_state; by_night "$(by_lists "$BY_PLAIN")"
out="$(by_asleep 7 --squash)"; rc=$?
by_refused "asleep, merge only with no adminMerge" "$rc" "$out"
check "#3534 asleep, merge only with no adminMerge: it says sleep mode does not allow it there, in sleep mode's words" "$BY_SLEEP_NO, which does not allow admin merges overnight (adminMerge on its mergeOnly entry in mods/sleep-repos.local.json))" "$out"
check "#3534 asleep, merge only with no adminMerge: and what to do" "Have it approved, or run the same command again once sleep mode is off." "$out"
check_eq "#3534 asleep, merge only with no adminMerge: only the plain merge was sent" "1" "$(count gh-calls '^pr merge')"

# The same lists once the sleep has ended (its record still there, as it is until a session moves it
# aside): sleep mode is off, so the bypass merge is sent as it was before this.
by_state; by_night "$(by_lists "$BY_PLAIN")" 999999999
out="$(by_asleep 7 --squash)"; rc=$?
check_eq "#3534 a sleep that has ended is sleep mode off: the bypass merge merges" "0" "$rc"
check "#3534 a sleep that has ended: as a bypass" "Merged #7 in acme/widget at ${OLD:0:7} $BY_AS" "$out"
check_not "#3534 a sleep that has ended: and nothing is said about sleep mode" "leep mode" "$out"

# A record that cannot be read is never taken as permission, nor as sleep mode being off.
by_state; printf '{"v":1,' > "$BY_REC"
out="$(by_asleep 7 --squash)"; rc=$?
by_refused "a sleep record that cannot be read" "$rc" "$out"
check "#3534 a sleep record that cannot be read: it says so, with why" "sleep mode's record on this Mac could not be read (the sleep record is not JSON), so whether it allows a merge past that review in acme/widget tonight is not known, and an answer that cannot be read is never taken as permission" "$out"
check "#3534 a sleep record that cannot be read: and what to do" "Run the same command again once that can be read or sleep mode is off, or have it approved first." "$out"

# Nor is a judgement that could not be run: a record is there, and node cannot ask the mod about it.
by_state; by_night "$(by_lists "$BY_OPTED")"
out="$(PATH="$BY_SLEEP/no-node:$PATH" by_asleep 7 --squash)"; rc=$?
by_refused "sleep mode's judgement cannot be run" "$rc" "$out"
check "#3534 sleep mode's judgement cannot be run: it says so, with what node answered" "what sleep mode allows in acme/widget tonight could not be asked of the scope modes mod (node exited 1: TypeError [ERR_UNKNOWN_FILE_EXTENSION]: Unknown file extension .ts), and an answer that cannot be read is never taken as permission" "$out"

# A sleep that begins while the checks gate is asked about the bypass command, after bypass_judge
# found this Mac awake. The gate reads GitHub under a budget of its own, so sleep mode is asked
# again as the very last thing before the merge is sent, and the sleep is seen.
by_state; by_night "$(by_lists "$BY_PLAIN")"; mv "$BY_REC" "$BY_SLEEP/next.json"
printf 'cp "%s" "%s"' "$BY_SLEEP/next.json" "$BY_REC" > "$ST/on-red-gate-admin"
out="$(by_asleep 7 --squash)"; rc=$?
by_refused "a sleep that begins while the checks gate is asked" "$rc" "$out"
check "#3534 a sleep that begins while the checks gate is asked: it says sleep mode does not allow it there" "$BY_SLEEP_NO, which does not allow admin merges overnight" "$out"
check_eq "#3534 a sleep that begins while the checks gate is asked: the gate had been asked about the bypass command, so the first ask found this Mac awake" "1" "$(grep -c -- ' --admin ' "$ST/red-gate-payloads")"

# With no HOME there is nowhere to look for the record, which is not the same as there being none.
by_state
out="$(HOME="" CLAUDE_SLEEP_RECORD="" run 7 --squash)"; rc=$?
by_refused "no HOME folder to look for sleep mode's record under" "$rc" "$out"
check "#3534 no HOME folder: it says so" "this run has no HOME folder to look for sleep mode's record under, so whether sleep mode allows a merge past that review in acme/widget tonight is not known" "$out"

# What sleep mode answers for every other night, asked of the entry directly: one run of node each,
# not a whole run of the helper (L298). The helper sends the bypass merge on `awake` and `allowed`
# alone, which the runs above and the weakened helper prove; these prove which nights get which.
by_night "$(by_lists "$BY_OPTED")"
check_eq "#3534 sleep mode's answer: an entry with adminMerge green-pinned whose merge does not deploy" "allowed: " "$(by_verdict)"
check_eq "#3534 sleep mode's answer: a record of another boot is not this sleep" "awake: other-boot" "$(by_verdict 99999999-2222-3333-4444-555555555555)"
by_night "$(by_lists '{"repo":"acme/widget","mergeDeploys":true,"adminMerge":"green-pinned"}')"
check_eq "#3534 sleep mode's answer: where a merge deploys" "refused: admin merge a PR in acme/widget, where a merge deploys, so it is never merged overnight" "$(by_verdict)"
by_night "$(by_lists '{"repo":"acme/widget","mergeDeploys":"unknown","adminMerge":"green-pinned"}')"
check_eq "#3534 sleep mode's answer: where whether a merge deploys is not recorded" "refused: admin merge a PR in acme/widget, where whether a merge deploys is not recorded, so it is never merged overnight" "$(by_verdict)"
by_night "$(jq -nc --argjson e "$BY_OPTED" '{mayDeploy: [], mergeOnly: [$e], closed: [{repo: "acme/widget", why: "the question about acme/widget was left unanswered at bedtime"}]}')"
check_eq "#3534 sleep mode's answer: a repository closed for the night" "refused: admin merge a PR in acme/widget, and the question about acme/widget was left unanswered at bedtime, so tonight it neither merges nor deploys" "$(by_verdict)"
by_night "$(by_lists '{"repo":"acme/other","mergeDeploys":false,"adminMerge":"green-pinned"}')"
check_eq "#3534 sleep mode's answer: a repository on neither list" "refused: admin merge a PR in acme/widget, and acme/widget is on neither list in mods/sleep-repos.local.json, so tonight it neither merges nor deploys" "$(by_verdict)"
by_night '{"mayDeploy": ["acme/widget"], "mergeOnly": [], "closed": []}'
check "#3534 sleep mode's answer: a repository that may deploy is not one that allows an admin merge" "refused: admin merge a PR in acme/widget, which does not allow admin merges overnight" "$(by_verdict)"
by_night '{"mayDeploy": [], "mergeOnly": "acme/widget"}'
check_eq "#3534 sleep mode's answer: lists that are not the shape expected" "refused: admin merge a PR in acme/widget, and the sleep record carries no merge and deploy lists, so tonight it neither merges nor deploys" "$(by_verdict)"
by_night null
check_eq "#3534 sleep mode's answer: a record with no lists" "refused: admin merge a PR in acme/widget, and the sleep record carries no merge and deploy lists, so tonight it neither merges nor deploys" "$(by_verdict)"
printf '{"v":1,"bootTime":1700000000}' > "$BY_REC"
check_eq "#3534 sleep mode's answer: a record naming no end" "unreadable: the sleep record names no end" "$(by_verdict)"
rm -f "$BY_REC"
check_eq "#3534 sleep mode's answer: no record" "awake: none" "$(by_verdict)"

echo
mwr_harness_result
