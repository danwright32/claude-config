#!/usr/bin/env bash
# Tests for answering each orchestrated item where it came from (claude-config#2199).
#
# On 2026-11-04 Dan asked that every item handed to an orchestrator gets, when done, a reply saved
# as a draft at the alert or post it came from, and that the config makes it mandatory. The same
# day he ruled that a Slack list row gets no reply ("ok ignore slack lists then. just update the
# waiting/in progress/done indicator instead. and make sure the claude config makes that mandatory
# as well"), because a list record's thread refuses a draft with channel_not_found (measured
# 2026-11-04). Two thread drafts in one channel were both accepted, so the one draft per channel
# limit does not stand in the way of one draft per thread.
#
# What this holds the skill to, each a fixed phrase it must carry:
#   1. intake records each item's source in a form a reply can be aimed at;
#   2. the board has a Source column;
#   3. a Slack message item gets a draft reply in its thread, through /no-ai-tells, never sent;
#   4. a Slack list row gets no reply and has its Status moved through the three values;
#   5. an issue is answered where it came from;
#   6. Finish lists every saved draft with its link;
#   7. both halves are stated as mandatory.
#
# ORCHESTRATE_SKILL points the suite at another copy, which is how a broken copy is shown to fail.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="${ORCHESTRATE_SKILL:-$DIR/SKILL.md}"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}

# A section runs from its heading to the next heading of the same or a higher level.
section() { # section <exact heading line>
  awk -v h="$1" '
    BEGIN { n = index(h, " ") - 1 }
    $0 == h { on = 1; next }
    on && /^#+ / { m = index($0, " ") - 1; if (m <= n) exit }
    on { print }
  ' "$SKILL" 2>/dev/null
}
has() { # has <description> <section text> <fixed text>   case insensitive
  check "$1" "$(grep -q -i -F -- "$3" <<< "$2" && echo ok || echo "no '$3' where expected in $SKILL")"
}

[ -r "$SKILL" ] || { check "the orchestrate skill is readable" "cannot read $SKILL"; }

intake="$(section "## 1. Intake")"
board="$(section "## 2. Dispatch board")"
reply="$(section "### Answering each item at its source")"
finish="$(section "## 6. Finish")"

# ---- 1. intake records the source ----
has "intake records a Slack message's channel id and ts" "$intake" "channel id and message ts"
has "intake records a list row's list id and record id" "$intake" "list id and record id"
has "intake records an issue's number" "$intake" "issue number"

# ---- 2. the board has a Source column ----
check "the dispatch board has a Source column" \
  "$(grep -q -E '^\| # \| Item \| Source \|' <<< "$board" && echo ok || echo "no Source column in the board")"

# ---- 3. a Slack message item gets a draft thread reply, never sent ----
check "the skill holds the source reply section exactly once" \
  "$([ "$(grep -c -x -F '### Answering each item at its source' "$SKILL" 2>/dev/null)" = "1" ] && echo ok || echo "the section is missing or repeated")"
has "a Slack message item's reply is saved as a draft" "$reply" "slack_send_message_draft"
has "the draft goes in the message's thread" "$reply" "thread_ts"
has "the draft goes through /no-ai-tells first" "$reply" "/no-ai-tells"
has "the draft is never sent" "$reply" "Nothing is sent"
has "one draft per thread is allowed in one channel" "$reply" "one draft per thread"

# ---- 4. a Slack list row gets its Status moved instead of a reply ----
has "a list row gets no reply" "$reply" "gets no reply"
has "the reason a list row cannot take a draft is recorded" "$reply" "channel_not_found"
has "a list row's Status moves to In progress when its agent reports" "$reply" "In progress when its agent reports"
has "a list row's Status moves to Done once approved follow ons finish" "$reply" "Done once every follow on Dan approved is finished"
has "a list row's Status moves to Waiting when parked" "$reply" "Waiting when it is parked until a later date or event"
has "the Status is moved with the list record tool" "$reply" "slack_update_list_record"

# ---- 5. an issue is answered where it came from ----
has "an issue item is answered on the issue" "$reply" "comment on the issue"

# ---- 6. Finish lists every saved draft ----
has "Finish lists each saved draft with its link" "$finish" "each draft reply saved, with its link"
has "Finish lists each list row whose Status was moved" "$finish" "each list row whose Status moved"

# ---- 7. both halves are mandatory, with Dan's ruling and date ----
has "both halves are stated as mandatory" "$reply" "Both halves are mandatory"
has "the section carries Dan's ruling date" "$reply" "2026-11-04"

# ---- 8. the style rule: no em or en dash in the skill ----
# One -e per character, never a \| alternation, which basic regex grep honours on some systems only.
dashes="$(grep -n -e $'\xe2\x80\x94' -e $'\xe2\x80\x93' "$SKILL" 2>/dev/null)"
check "the orchestrate skill holds no em or en dash" "$([ -z "$dashes" ] && echo ok || echo "$dashes")"

# claude-config#2490: on 2026-11-09 a restart of the work MacBook emptied /private/tmp, taking a
# session's handoff note and a background agent's working tree with an uncommitted fix. Briefs give
# each agent a working folder in the session's notes folder and a worktree inside the repo, never
# anything under the temp folder, and the rules every agent reads say the same.
RULES="${ORCHESTRATE_RULES:-$DIR/agent-rules.md}"
has(){ grep -F -q -- "$2" "$1" && echo ok || echo "missing: $2"; }
check "#2490 a brief's working folder is under the notes folder" "$(has "$SKILL" '5. The working folder: `<notes folder>/')"
check "#2490 a brief's worktree is inside the repo, never the temp folder" "$(has "$SKILL" 'never under `/tmp`, `/private/tmp` or the scratchpad')"
check "#2490 the orchestrator's handoff note is in the notes folder" "$(has "$SKILL" '`handoff.md` at the root of this session'"'"'s notes folder')"
check "#2490 no brief part still names the scratchpad as the working folder" "$(grep -n 'The scratchpad folder:' "$SKILL" >/dev/null && echo 'still names the scratchpad folder' || echo ok)"
check "#2490 agents write working files in the notes folder" "$(has "$RULES" 'never in the scratchpad under `/private/tmp`')"
check "#2490 agents never put a worktree in the temp folder" "$(has "$RULES" 'Never put a worktree under `/tmp`')"

# claude-config#3028: on 2026-11-14 a gate refused an independent reviewer's comparison, and the
# reviewer reran it in pieces and then as a temporary test file, which the auto mode check refused
# as going round a guard. The rules every dispatched agent reads say once that a refusal is final.
# They reach a reviewer through the first part of every brief, so that pointer is held here too.
check "#3028 agent rules say a refused command is final" "$(has "$RULES" 'A refused command is final.')"
check "#3028 agent rules name every other way a refusal is never retried" "$(has "$RULES" 'never retried in pieces, as a test file, through another tool or by another agent')"
check "#3028 agent rules say to stop and report the refusal" "$(has "$RULES" 'stop and report the refusal')"
# claude-config#3173: the Slack drafts gate names one route in some of its refusals, the no network
# wrapper, and Dan decided on 2026-11-18 that a command run under it passes. The rules say a
# refusal that names that route may be run again that way, and only then.
check "#3173 agent rules let a refused command be run again under the no network wrapper when the refusal says so" "$(has "$RULES" 'when the refusal itself says the command may be run again under the no network wrapper')"
check "#3173 agent rules keep a refusal that names no such route final" "$(has "$RULES" 'A refusal that names no such route stays final')"
# The gate passes the wrapper only as the whole of a call, after nothing but a cd and with nothing
# after its command, so the rules say how the second run is made and where a filter goes.
check "#3173 agent rules say the run under the wrapper is a call of its own, after only a cd" "$(has "$RULES" 'in a call of its own, with the path it names as the first word of that command and nothing before it but a cd')"
check "#3173 agent rules say nothing follows the wrapped command in that call" "$(has "$RULES" 'nothing after that command but its output sent to a file (no pipe, no second command, no second line)')"
check "#3173 agent rules say a filter or a second step goes inside the wrapped command" "$(has "$RULES" 'A filter or a second step goes inside the wrapped command')"
# On 2026-11-16 two builders decided area check holds on commands their briefs did not cover, and
# the auto mode safety check refused what followed, so the exception for a resent hold is bounded.
check "#3028 only a hold the brief lets the agent decide is resent" "$(has "$RULES" 'a hold your brief lets you decide')"
check "#3028 a hold the brief does not cover is reported, not decided" "$(has "$RULES" 'is not yours to decide: stop and report it like any other refusal')"

# claude-config#3390: measured on 2026-11-21, of 1,102 builder runs that made a commit, 11 loaded
# the skill the test first rule named, while 509 wrote a test, ran it and saw it fail before the
# fix. The rule holds without the skill, so it asks for the behaviour itself, in the words of the
# check the orchestrator runs on a report ("its claim that the test failed first"), and names no
# skill a builder does not load.
check "#3390 agent rules ask for a test seen to fail before the code is edited" "$(has "$RULES" 'Test first: write the test, run it, and see it fail before you edit the code it covers.')"
check "#3390 agent rules name no skill for working test first" "$(grep -F -q -- 'superpowers:test-driven-development' "$RULES" && echo 'still names superpowers:test-driven-development' || echo ok)"
# Measured on 2026-11-23 on the personal MacBook: 74% of builds that changed a test and its code ran
# the test and saw it fail first, while the orchestrator checked that claim after about 1 hand back
# in 100. So the builder keeps the failing run as red.txt and the orchestrator reads it, rerunning
# only when it is missing or names no new test. Dan, 2026-11-24, by picker: "3.2.1 Make the change
# (Recommended)".
check "#3390 agent rules say to save the failing run as red.txt in the working folder" "$(has "$RULES" 'as `red.txt` in your working folder')"
check "#3390 agent rules say red.txt must name the new test or case" "$(has "$RULES" 'must name the new test or case')"
review_step="$(section "## 5. When an agent reports" | grep '^1\. ')"
before_put_back="${review_step%%git checkout origin/main*}"
text_has() { grep -F -q -- "$2" <<< "$1" && echo ok || echo "$3"; }
check "#3390 the review step reads the agent's red.txt" "$(text_has "$review_step" 'read its `red.txt`' 'step 1 does not read red.txt')"
check "#3390 the review step reruns only when red.txt is missing or names no new test" "$(text_has "$review_step" 'only when `red.txt` is missing or does not name the new test' 'no rerun condition on red.txt')"
check "#3390 the review step reads red.txt before it reruns" "$(text_has "$before_put_back" 'red.txt' 'red.txt is not read before the put back')"
check "#3028 every brief, a reviewer's included, starts with the agent rules" "$(has "$SKILL" '1. `Read ~/.claude/skills/orchestrate/agent-rules.md before anything else and follow it.`')"
check "#3028 the brief parts apply to a reviewer's brief too" "$(has "$SKILL" 'Every brief has exactly these parts')"

# claude-config#3095: measured on 2026-11-16, the Chrome navigate tool refuses about:blank, so a
# tab cannot be blanked before it is closed, and a clicked link can open a new tab inside the
# session's shared tab group, where the agent can act on it and has to close it. A brief written
# that day got both wrong, so the rules every browser agent reads say both.
check "#3095 agent rules say navigate refuses about:blank" "$(has "$RULES" '`navigate` refuses `about:blank`')"
check "#3095 agent rules say tabs_close_mcp alone finishes a tab" "$(has "$RULES" '`tabs_close_mcp` alone finishes a tab')"
check "#3095 agent rules say a clicked link can open a tab in the shared group" "$(has "$RULES" 'A link you click can open a new tab, and that tab lands in the shared tab group')"
check "#3095 agent rules say to list tabs before and after a click that may open one" "$(has "$RULES" 'call `tabs_context_mcp` just before any click that may open a tab and again just after it')"
check "#3095 agent rules say to close every tab the agent did not mean to open" "$(has "$RULES" 'close with `tabs_close_mcp` every tab that appeared between the two lists that you did not mean to open')"
check "#3095 agent rules say to finish by closing every tab the agent opened" "$(has "$RULES" 'close every tab you opened')"
check "#3095 the tabs_context_mcp prohibition carries the one exception" "$(has "$RULES" 'except to close a tab your own click opened')"

# claude-config#3542: on the night of 2026-11-23 the orchestrator restated these rules by hand in every
# brief, one brief left one out, and that agent pushed past a lessons review finding with the review's
# read key. Each now lives once in the agent rules, and a brief names only what is particular to its
# item. Each check matches a phrase only that rule writes, so a later trim cannot drop one in silence.
check "#3542 agent rules forbid the lessons review's read key" "$(has "$RULES" "Never use the lessons review's read key")"
check "#3542 agent rules say a finding judged not real is handed back and the push waits" "$(has "$RULES" 'hand it back, and the push waits')"
check "#3542 agent rules read the load before a push against the brief's limit" "$(has "$RULES" 'run `uptime` before each push')"
check "#3542 agent rules run only the brief's suites, one at a time, on a quiet Mac" "$(has "$RULES" 'unless your brief says the Mac must stay quiet')"
check "#3542 agent rules leave an hour long count to the main session" "$(has "$RULES" 'An hour long count')"
check "#3542 agent rules let an agent decide an area check hold, never by restructure" "$(has "$RULES" 'never `restructure`')"
check "#3542 agent rules stop for Dan before any allowlist or exemption entry" "$(has "$RULES" 'add an allowlist or exemption entry')"
check "#3542 agent rules forbid an amend or a force push" "$(has "$RULES" 'Never amend a commit or force push')"
check "#3542 agent rules point a no verdict refusal at its one home" "$(has "$RULES" 'One unchanged resend after no verdict')"
check "#3542 agent rules never count refusals their own way" "$(grep -i -F -q -- 'refused twice' "$RULES" && echo 'says refused twice, which the no verdict rule does not' || echo ok)"
briefs="$(section "## 3. Briefs")"
check "#3542 a brief names only what is particular to its item" "$(text_has "$briefs" 'a brief names only what is particular to its item' 'section 3 does not limit a brief to its item')"
check "#3542 a brief never restates a shared rule" "$(text_has "$briefs" 'never restates a shared rule' 'section 3 does not forbid restating a shared rule')"

# claude-config#2563: the merge command written in the skill and in the global rules must carry
# every argument the helper's usage marks required, say it runs from inside a checkout, and say how
# the merge method is chosen. Required is read from the helper's own usage line: a token outside [].
HELPER="${MERGE_HELPER:-$DIR/../../hooks/lib/merge-when-ready.sh}"
GLOBAL_RULES="${GLOBAL_RULES_FILE:-$DIR/../../CLAUDE.md}"
usage_line="$(grep -m1 'echo "usage: ' "$HELPER")"
required="$(printf '%s' "$usage_line" | sed 's/.*\$SELF //; s/".*//; s/\[[^]]*\]//g')"
case "$required" in
  *[![:space:]]*) parsed=ok ;;
  *) parsed="none parsed from: $usage_line" ;;
esac
check "#2563 the helper's usage names a required argument" "$parsed"
# ok when the text holds the words, else the reason given. Matched with case, never a pipe into
# grep -q, which can stop reading early and fail the pipeline under pipefail.
holds() { case "$1" in *"$2"*) echo ok ;; *) echo "$3" ;; esac; }
for f in "$SKILL" "$GLOBAL_RULES"; do
  cmd_line="$(grep -m1 -F 'merge-when-ready.sh' "$f")"
  for tok in $required; do
    case "$tok" in
      "<pr>") want='merge-when-ready.sh <' ;;
      *) want="$tok" ;;
    esac
    check "#2563 $(basename "$(dirname "$f")")/$(basename "$f") command carries required $tok" "$(holds "$cmd_line" "$want" "missing $want")"
  done
  check "#2563 $(basename "$f") says it runs from inside a checkout" "$(holds "$cmd_line" 'inside a checkout' 'no checkout requirement')"
  method="$(holds "$cmd_line" '--squash' 'no merge method rule')"
  [ "$method" = ok ] && method="$(holds "$cmd_line" 'its history uses' 'no merge method rule')"
  check "#2563 $(basename "$f") names the merge method and how it is chosen" "$method"
done

# claude-config#3317: on 2026-11-19 two sessions, one on each Mac, built the same fix, because a
# branch in a local worktree is invisible to the other Mac and nothing on the issue said it was
# taken. A build item from an issue is claimed on the issue, by claim-issue.sh, before its builder
# is dispatched, and released when it ends without closing the issue.
claiming="$(section "### Claiming an issue before its builder starts")"
check "#3317 the skill holds the claiming section" "$(holds "$claiming" 'claim-issue.sh' 'no claiming section naming claim-issue.sh')"
check "#3317 the claim command is written out" "$(holds "$claiming" 'bash ~/.claude/skills/orchestrate/claim-issue.sh claim <owner/repo> <issue number> <branch>' 'no claim command')"
check "#3317 the claim goes up before the dispatch" "$(holds "$claiming" 'before its builder is dispatched' 'no before the dispatch')"
check "#3317 a builder is dispatched on exit 0 only" "$(holds "$claiming" 'Dispatch on exit 0 only' 'no exit 0 rule')"
check "#3317 a held item is not started and the board says who holds it" "$(holds "$claiming" '`held by <who>`' 'no held by board wording')"
check "#3317 a failed check is not read as free" "$(holds "$claiming" 'nothing was claimed' 'no could not check rule')"
check "#3317 the release command is written out" "$(holds "$claiming" 'bash ~/.claude/skills/orchestrate/claim-issue.sh release <owner/repo> <issue number> <branch>' 'no release command')"
check "#3317 a read only item needs no claim" "$(holds "$claiming" 'needs no claim' 'no read only exemption')"
# claude-config#3788: a pull request holds an issue only when it is built for it. The skill says
# which pull requests those are, and that a `mentioned, not held` line is no reason to hold back.
check "#3788 the skill says which pull requests hold an issue" "$(holds "$claiming" 'the open pull requests built for it' 'no built for wording')"
check "#3788 the skill says a mention is a note that holds nothing" "$(holds "$claiming" '`mentioned, not held`' 'no mentioned, not held wording')"
# claude-config#3804: two sessions on one Mac are two claimants. The skill says what a session is
# to the script and that it is the same one after a compaction, that ALREADY CLAIMED
# means this session's own claim, what makes a branch under the claimed name this session's, and
# how a claim that names no session is taken over on purpose.
check "#3804 the skill says what identifies the claiming session" "$(holds "$claiming" 'CLAUDE_CODE_SESSION_ID' 'no word of what identifies a session')"
check "#3804 the skill says a session is the same after a compaction" "$(holds "$claiming" 'it is the same after a compaction, and a new one after a `/clear`' 'no word of a compaction')"
# A restart is said as far as it was measured, and no further: the transcript went on under one
# id, and the variable the script reads was not read in a restarted session (the lessons review of
# the second round of review fixes).
check "#3804 the skill says what was measured after a restart, and what was not" "$(holds "$claiming" 'the variable itself was not read in a restarted session' 'no word that the variable was not read after a restart')"
check "#3804 the skill says what a restarted session meets if its id changed" "$(holds "$claiming" 'A restarted session that is told `HELD` by a claim it posted has been given a new id' 'no word of a restarted session held by its own claim')"
check "#3804 the skill says ALREADY CLAIMED is this session's own claim" "$(holds "$claiming" "\`ALREADY CLAIMED\` is this session's own claim" 'no word that ALREADY CLAIMED is this session alone')"
check "#3804 the skill says another session on the same Mac is held" "$(holds "$claiming" 'another session on the same Mac' 'no word of two sessions on one Mac')"
check "#3804 the skill says what makes a branch under the claimed name this session's" "$(holds "$claiming" 'accounts for it' 'no word of what makes a branch this session own')"
check "#3804 the skill says how a claim with no session recorded is taken over" "$(holds "$claiming" 'no session recorded' 'no word of a claim with no session recorded')"
check "#3804 the skill says a session id that cannot be read stops the claim" "$(holds "$claiming" 'cannot read its session' 'no word of an unreadable session id')"
# The review of that change: taking over a claim with no session recorded is a word of its own,
# never what a plain release does (Finish runs release for every claim, so a release that took
# claims over would do it by accident), and a session that is not the claimant is held by the
# claimant's pushed branch or open pull request for as long as either is up, not only until the
# claim goes stale.
check "#3804 the take over command is written out" "$(holds "$claiming" 'bash ~/.claude/skills/orchestrate/claim-issue.sh takeover <owner/repo> <issue number> <branch> "<reason>"' 'no take over command')"
check "#3804 the skill says a plain release never ends a claim with no session recorded" "$(holds "$claiming" '`release` never ends a claim with no session recorded' 'no word that release leaves such a claim alone')"
check "#3804 the skill says a release that ended nothing for that reason exits 1" "$(holds "$claiming" 'answers `NOT RELEASED`, exit 1' 'no word that NOT RELEASED is exit 1')"
# The second review of that change: that answer is the one a session with no claim of its own on
# the branch gets. With one, the release ends that claim alone and says the other still stands.
check "#3804 the skill says which session gets NOT RELEASED" "$(holds "$claiming" 'Under one from this Mac, where this session has no claim of its own on that branch, it posts nothing' 'no word of which session is answered NOT RELEASED, under which claim')"
check "#3804 the skill says the other Mac's claim changes nothing in what a release answers" "$(holds "$claiming" 'A claim from the other Mac changes nothing in what `release` answers' 'no word of a release under the other Mac claim')"
check "#3804 the skill says a release beside this session's own claim ends that claim alone" "$(holds "$claiming" 'Where it has one, it releases that claim alone, answers `RELEASED`, exit 0, and says the claim with no session recorded still stands' 'no word of a release beside the session own claim')"
check "#3804 the skill says a branch or pull request holds a session that is not the claimant for as long as it is up" "$(holds "$claiming" 'for as long as it is up' 'no word of how long a pushed branch holds')"
check "#3804 the skill says no command lets a session that is not the claimant through" "$(holds "$claiming" 'no command of this script lets it through' 'no word that nothing lets another session through')"
check "#3804 Finish says what a NOT RELEASED answer means" "$(holds "$finish" '`NOT RELEASED`' 'Finish does not say what a NOT RELEASED answer means')"
check "#3804 Finish never takes a claim over to clear it" "$(holds "$finish" '`takeover` is never part of finishing' 'Finish does not say takeover is never part of finishing')"
check "#3804 the skill says a take over ends this session's own claim on that branch with it" "$(holds "$claiming" "this session's own claim on that branch, if it has one, ends with it" 'no word that a take over ends the caller own claim on the branch too')"
check "#3317 the board states include held by" "$(holds "$(section "## 4. While agents run")" '`held by <who>`' 'no held by state')"
check "#3317 Finish releases claims left standing" "$(holds "$finish" 'claim-issue.sh release' 'Finish does not release claims')"
check "#3317 the script the skill names is there and executable" "$([ -x "$DIR/claim-issue.sh" ] && echo ok || echo "$DIR/claim-issue.sh missing or not executable")"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
