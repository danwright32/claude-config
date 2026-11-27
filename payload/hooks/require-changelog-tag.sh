#!/usr/bin/env bash
#
# Block a pull request merge unless the change carries a changelog record.
#
# Why this exists: the first manager facing update covering June to August meant
# reading all 499 pull request titles merged in that period and judging each one
# as manager visible or plumbing by hand, because nothing recorded the
# distinction at the time the change shipped (PET #1186). Doing that every
# fortnight is the wrong cost, and the judgment is worse in arrears than it is at
# merge time, when the person who made the change is still holding it.
#
# The record is two halves:
#   the LABEL   changelog/visible | changelog/technical | changelog/none | changelog/announce
#   the BODY    a "## Changelog" block carrying the sentence a manager reads,
#               required for changelog/visible and changelog/announce, and under
#               changelog/announce an "## Announcement" block carrying the post for agents
#
# changelog/announce (claude-config#3665) is for a change whose agents must or can act
# differently. It is in use only in a repository whose registry entry names an
# announcements channel (announceChannel), and refused here everywhere else.
#
# Both are read through lib/changelog-entry.js, which is the single definition of
# what a valid record is. A rule that lives only in a pull request template is a
# hope (L27): the template is the reminder, this is the enforcement.
#
# Scope: a repo is gated only when the /pennie-dev-update registry lists it WITH a
# changelogFrom date. Every other repo on the machine is untouched. That file is the
# registry the update itself already reads, so a product is added in one place rather
# than two. It is a file each Mac keeps for itself, ~/.claude/skills/pennie-dev-update/
# repos.local.json, never the shared config, because it names work repositories and
# this repository is public (claude-config#1526). Where it lives and how it is read
# both come from lib/dev-update-registry.js, the one reader the skill uses too.
#
# WHICH repo that is comes from the merge, resolved the way gh resolves it: its own --repo, -R
# or pull request link first, then the directory it runs in (claude-config#470).
#
# Fails CLOSED where it can tell there is a problem, and stands down where it
# genuinely has nothing to say. The three are deliberately different answers: a
# MISSING registry and an unreadable one both mean the gate cannot tell whether this
# repo is in scope, and each is refused with its own message, while an unlisted repo
# means somebody chose not to gate it. A missing registry used to be a stand down,
# read as "the update tooling is not installed here", and that was true while the
# file travelled with the payload. Every Mac carrying this gate carries the skill, so
# once the file became each Mac's own, its absence is a Mac that lost or never made
# it, and standing down there would quietly ungate every repo (claude-config#1526,
# L98). Gating nothing on purpose is a registry listing no repos.
#
# Covers every route to a merge, including a repo's own wrapper, because a gate that
# only knows the direct command is dodged by the very route another gate makes
# mandatory (claude-config#351).
#
# Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command> (visible in the
# command, so it cannot happen by accident or go unnoticed in the transcript).
#
# The override does NOT cover a pull request carrying changelog/announce (Dan, 2026-11-25,
# claude-config#3665). So with it typed, in a repository the registry gates, the pull request is
# still read: one carrying that label is judged in full, as if the override were not there, and
# every other one merges with nothing said, as it always did. Where the labels cannot be read at
# all (gh gives no answer, the registry cannot say whether the repository is gated, a tool is
# missing) the override still lets the merge through, since it is the remedy this gate names for
# exactly that, and the allow says in one sentence that an announcement could not be ruled out.
# The exits that come before the command can even be read (the library that reads it is missing,
# neither jq nor python3 is installed, the payload is not a call any reader takes) let it through
# the same way, saying the same of a command that could not be read at all (claude-config#3742).
# A command merging more than one pull request is not such a case and is refused with the override
# typed too (Dan, 2026-11-25, claude-config#3666): its remedy, one pull request per command, is
# always open. Nor is a command written so that the pull request it merges cannot be told (Dan,
# 2026-11-26, claude-config#3742): its remedy, naming the pull request plainly, is always open too.
#
# An announce pull request also merges only on wording Dan approved (claude-config#3666): the
# Announcement block as GitHub holds it at the merge must hash to an approval lib/announce-approval.py
# holds for this repository, from his own picker answer about the file he was shown, and one
# approval covers one pull request (Dan, 2026-11-25). The last section of this file says how, and
# records the pull request as the one using the approval when the merge is let through.
#
# Seams, for the tests: CHANGELOG_REGISTRY points at a different registry file, and
# ANNOUNCE_APPROVALS_DIR (read by lib/announce-approval.py) at a different record of approved wording.

set -uo pipefail

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
payload=$(cat)

# It runs before EVERY Bash command (claude-config#1181): it used to be registered behind an `if` of
# `Bash(gh pr merge*)`, so Claude Code never ran it for a merge through the GitHub API, or for a
# repo's own merge tool, whatever mt_runs_merge said (#351 taught the recogniser the tools; the
# filter kept them from it). So the commonest case leaves here, before anything is loaded, by the
# words every merge route names (mt__might_merge in lib/merge-target.sh).
case "$payload" in *merge*|*Merge*|*enqueuePullRequest*) ;; *) exit 0 ;; esac

# How this gate says something beside a call it lets through (lib/hook-notice.sh). Loaded here, ahead
# of every exit the override can take, so each one can say its sentence (claude-config#3742, low 10):
# it used to be loaded after the three that come before the command is read, which therefore let the
# command through with nothing said.
. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }

# LET THROUGH, SAID OUT LOUD (Dan, 2026-11-25). With the override typed and the labels unread, the
# merge goes ahead, as the override always meant. But an unread pull request may be an announcement,
# and an allow that says nothing would read as "it was not one" (L98). So the person is shown one
# sentence and the session is handed the same one. `unread` is what is standing between the gate and
# the labels at each step below, in words for the notice. Given `command`, it is said of a command
# of which not even "does it merge a pull request" could be read, since a sentence may claim only
# what was measured (L11): the three exits ahead of the command's reading.
unread="this Mac's dev update registry could not be read"
override_allows() {  # $1 = `command` where the command itself could not be read
  local what="this merge" whether="whether it carries changelog/announce"
  if [ "${1:-}" = command ]; then
    what="this command"; whether="whether it merges a pull request carrying changelog/announce"
  fi
  hook_allow_notice "ALLOW_UNTAGGED_MERGE=1 let $what through, but $unread, so $whether was never read and an announcement, which the override does not cover, could not be ruled out." PreToolUse
}

# shellcheck source=lib/merge-target.sh
{ . "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null && declare -F mt_runs_merge >/dev/null; } || {
  # A library this gate cannot load is not a merge with nothing to check (claude-config#1900,
  # L10). Past the words above this may be a merge, so it is refused, naming the file. The override,
  # read off the payload's text, still lets it through, and says so.
  case "$payload" in
    *ALLOW_UNTAGGED_MERGE=1*)
      unread="require-changelog-tag.sh could not load lib/merge-target.sh, which reads whether a command merges a pull request and which one"
      override_allows command ;;
  esac
  echo "Cannot tell whether this repo needs a changelog record: require-changelog-tag.sh could not load $HOOK_DIR/lib/merge-target.sh, or lib/push-scope.sh beneath it, which reads whether this command merges a pull request and which one, so whether the change carries a changelog record could not be checked. A library this gate cannot load is not a merge with nothing to check. Reinstall the hooks with claude-sync pull. Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command>." >&2
  exit 2
}

# Where the registry is comes from its one reader (claude-config#1526), resolved once node is known
# to be here, below. CHANGELOG_REGISTRY names a file for the tests.
REGISTRY_READER="$HOOK_DIR/lib/dev-update-registry.js"
REGISTRY="${CHANGELOG_REGISTRY:-}"

# What this gate REFUSES with when a tool it reads through is not installed. On stderr with exit 2
# rather than through deny() below, because deny() builds its JSON with jq and jq is one of the
# tools that can be missing.
refuse_no_reader() {  # $1 = the absence clause, $2 = what it costs, $3 = what to install
  echo "Cannot tell whether this repo needs a changelog record: $(ps_reader_absent_why "$1" "$2" "$3") Losing this change from the next manager update is what this gate exists to stop. Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command>." >&2
  exit 2
}

# THE PAYLOAD'S OWN READER, asked before the payload is read (claude-config#480, L490).
#
# The command was parsed straight out of the JSON with a bare jq, ABOVE the `command -v jq` further
# down. With no jq it came back EMPTY, mt_runs_merge answered no, and this gate exited 0 on every
# merge with nothing said, never reaching the check that would have named jq: an absent reader is
# the one failure that looks exactly like a clean run (L42, L98).
#
# Read through ps_parse_payload, the shared reader, which takes jq OR python3, so the commoner
# absence costs this gate nothing at all.
#
# With NEITHER installed nothing here can tell a merge from an `ls`, so what is refused is narrowed
# to a payload that could hold one at all, by the same substring the matcher uses as its own first
# filter. Refusing every Bash command would be a gate nobody keeps (L36, L54). There is no registry
# stand down ahead of it any more (claude-config#1526): a Mac carrying this gate carries the dev
# update skill, so the rule applies here whether or not this Mac's registry is in place, and a
# missing one is refused in its own words once the command can be read.
if ps_reader_missing jq python3; then
  case "$payload" in
    *ALLOW_UNTAGGED_MERGE=1*)
      # The override still clears it, and says so (claude-config#3742, low 10), written by bash alone.
      unread="neither jq nor python3 is installed, so this command could not be read out of the hook payload"
      override_allows command ;;
    *)
      refuse_no_reader "neither jq nor python3 is on PATH" \
        "require-changelog-tag.sh reads this command out of the hook payload, which is JSON, with one of them, so with neither installed it cannot tell whether this command merges a pull request at all, let alone which one." \
        "jq or python3" ;;
  esac
  exit 0
fi

# Taken raw above so the commonest call leaves before anything loads, and cleaned here, before
# anything parses it: a lone surrogate escape made jq read nothing, and this gate let the merge
# through (claude-config#1944). A payload still unreadable is judged by its words (#1922).
payload="$(ps_clean_payload "$payload")"
parsed=$(ps_parse_payload "$payload" raw) || {
  # The shared refusal leaves with nothing said when the payload's words hold the override. So where
  # they do, and they name a merge, the sentence is said here first (claude-config#3742, low 10).
  # Asked of the same text the shared refusal reads, so the two agree on what the payload holds.
  unparsed_text="$(ps_payload_text "$payload")"
  case "$unparsed_text" in
    *ALLOW_UNTAGGED_MERGE=1*)
      case "$unparsed_text" in
        *merge*|*Merge*|*enqueuePullRequest*)
          unread="this hook's payload could not be read as a call"
          override_allows command ;;
      esac ;;
  esac
  ps_unparsed_refuse "$payload" require-changelog-tag.sh ALLOW_UNTAGGED_MERGE "a merge of a pull request" '*merge*' '*Merge*' '*enqueuePullRequest*'
}
command="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"

# Any route to a merge, not only the direct command (claude-config#351).
#
# This gate asked mt_is_pr_merge, which recognises only the direct form, while
# block-red-merge.sh REFUSES that form in any repo carrying its own commit pinned merge
# tool and names the tool as the route to take. PET carries one, so the only route
# available there was the one this gate could not see, and the record was enforced by
# nothing in the repo whose manager update cost 499 pull request titles read by hand.
#
# The two gates ask different questions on purpose. block-red-merge stays on
# mt_is_pr_merge, because firing on the wrapper it has just recommended would be a
# refusal nothing can clear (L109). This gate's rule has nothing to do with which route
# is taken, so it asks about the merge itself.
mt_runs_merge "$command" || exit 0

# THE OVERRIDE, read once (claude-config#3665; the head of this file). It used to leave here, before
# anything was read. `overridden` stays true until the pull request has been read and found to carry
# the announce label, which the override does not cover: from then on this merge is judged as if the
# override had not been typed. What it says when it lets a merge through unread is override_allows,
# near the top of this file, with `unread` set at each step below.
overridden=false
case "$command" in
  *ALLOW_UNTAGGED_MERGE=1*) overridden=true ;;
esac

# Every refusal below goes through here. While the override stands, a refusal is not given: each one
# ahead of the label reading is a way the labels could not be read, so it becomes the allow above.
deny() {
  [ "$overridden" = true ] && override_allows
  jq -nc --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# node reads the registry and the changelog entry itself, labels included, so it is asked first.
# With it absent this gate used to leave here in silence, as a machine with no rule it could apply
# (L324). But this is known to be a merge, the pull request may be an announcement, and the same
# state with jq missing is refused, while announce-label-ask.sh refuses with no node too: so every
# merge went through unjudged on a launch whose PATH lost node, with nothing said (claude-config#3742,
# item 5; L98). It is refused by name, as jq's absence is below, and with the override typed the
# merge goes through with the sentence about an announcement. Both write without jq and without node.
if ps_reader_missing node; then
  if [ "$overridden" = true ]; then
    unread="node is not installed, so neither this Mac's dev update registry nor the pull request's labels could be read"
    override_allows
  fi
  refuse_no_reader "node is not on PATH" \
    "require-changelog-tag.sh reads this Mac's dev update registry and the pull request's changelog record with it, labels included, so with node absent nothing here can tell whether this repository is gated, a tagged pull request from an untagged one, or an announcement from any other change." \
    "node"
fi

# Where this Mac's registry is, from its one reader. A reader that answers nothing cannot say where
# to look, and cannot tell is never "not gated" (L490).
[ -n "$REGISTRY" ] || REGISTRY="$(node "$REGISTRY_READER" path 2>/dev/null)"

# jq alone, with python3 present: the command above WAS readable, so this is known to be a merge,
# and everything left is jq's. The record arrives from gh as JSON, the scope answer is JSON, and
# deny() builds its own refusal with jq. A gate that cannot read any of that has to say so rather
# than fall through the reading and find nothing to complain about (claude-config#480, L490).
# With the override typed that refusal was never given, and still is not: the merge goes through,
# with the sentence about an announcement, which hook_allow_notice writes without jq.
if ps_reader_missing jq && [ "$overridden" = true ]; then
  unread="jq is not installed, so gh's answer about the pull request could not be read"
  override_allows
fi
ps_reader_missing jq && refuse_no_reader "jq is not on PATH" \
  "require-changelog-tag.sh reads gh's answer about this pull request with it, and the record it is looking for is inside that answer, so with jq absent nothing here can tell a tagged pull request from an untagged one." \
  "jq"

# The registry, judged before anything else is read, so a Mac that has lost it is told so by name
# rather than through whichever refusal below happened to need it first (claude-config#1526). Missing
# is refused like unreadable, with the path to create and what goes in it, because the person who
# meets it has to make the file and the message is the only place that can say how (L111).
[ -n "$REGISTRY" ] || deny "Cannot tell whether this repo needs a changelog record: $REGISTRY_READER did not say where this Mac's dev update registry lives, so the gate refuses rather than merging blind. Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command>."
reg_state="$(node "$REGISTRY_READER" state "$REGISTRY" 2>/dev/null)"
case "$(printf '%s' "$reg_state" | jq -r '.state // ""' 2>/dev/null)" in
  ok|unreadable) ;;   # unreadable keeps its own refusal below, which names the file
  missing) deny "Cannot tell whether this repo needs a changelog record. $(printf '%s' "$reg_state" | jq -r '.why') Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command>." ;;
  *) deny "Cannot tell whether this repo needs a changelog record: reading $REGISTRY through $REGISTRY_READER produced nothing at all. That is the gate failing, not the repo opting out. Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command>." ;;
esac

# The reader the shared library needs for a direct merge's own arguments (claude-config#475).
# Without python3 the pull request and the repository this command names both come back empty, so
# this gate read the record of whatever pull request gh resolves from the current branch, in
# whatever repository this folder belongs to. It refuses by name rather than letting that arrive
# as "no pull request was found", which is a true sentence about a different fault and sends
# somebody to name a repository that was never the problem (L11).
#
# Below the registry check deliberately: a Mac whose registry is missing or unreadable is told
# that first, in its own words, since fixing the registry is the step it needs before anything this
# check could say matters (claude-config#1526). Only the direct form, because a wrapper names its number as a
# positional argument the shell reads and names no repository at all.
if mt_is_pr_merge "$command" && mt_reader_missing; then
  unread="python3 is not installed, so which pull request this command merges could not be read"
  deny "Cannot tell whether this repo needs a changelog record: $(mt_reader_absent_why) Reading another pull request's record while merging this one would lose this change from the next manager update. Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command>."
fi

# What the registry says about one repository, as lib/changelog-entry.js's repoScope answers it: JSON,
# or nothing when the reading itself failed. The one question asked of the registry, whether for the
# merge below or for each target of a command merging several.
scope_for() {  # $1 = owner/name
  HOOK_DIR="$HOOK_DIR" REGISTRY_PATH="$REGISTRY" SLUG="$1" node -e '
    const entry = require(process.env.HOOK_DIR + "/lib/changelog-entry.js");
    const read = require(process.env.HOOK_DIR + "/lib/dev-update-registry.js").readRegistry(process.env.REGISTRY_PATH);
    const registry = read.state === "ok" ? read.registry : null;
    process.stdout.write(JSON.stringify(entry.repoScope(registry, process.env.SLUG)));
  ' 2>/dev/null
}

# ONE pull request per command (claude-config#1062): the record read below is the first merge's, so
# a second merge in the same command went through on it and its own change was lost from the next
# manager update. Asked after the registry check above, so a Mac whose registry is missing or
# unreadable hears that first (claude-config#1526).
#
# And refused only where the rule applies (merge time lessons review of #1072): when EVERY target is a
# repository the registry plainly does not gate, there is no record to lose, and a refusal about
# changelog records would claim a rule that is not there (L11). Any target the registry gates, or
# about which it cannot give a plain "not listed" (unreadable, listed with no date or a bad one), is
# a target this gate would refuse or judge alone, so the command is refused.
if span_why="$(mt_merge_span_why "$command" "$cwd")"; then
  gated=""
  # No targets to read while the command still spans (nothing could read it) is "cannot tell", and
  # cannot tell is never "nothing gated" (L490).
  t_all="$(mt_merge_targets "$command" "$cwd")"
  [ -n "$t_all" ] || gated="a repository nothing here could read"
  # Split by parameter expansion, never `IFS=$'\t' read`: a tab is whitespace to read, so an empty
  # first field (a checkout with no GitHub remote) collapsed and the path landed in t_slug.
  while IFS= read -r t_line; do
    [ -n "$t_line" ] || continue
    t_slug="${t_line%%$'\t'*}"; t_where="${t_line#*$'\t'}"; t_where="${t_where%%$'\t'*}"
    t_scope="$(scope_for "$t_slug")"
    if [ -z "$t_scope" ] || [ "$(printf '%s' "$t_scope" | jq -r '(.inScope // false) or (.unreadable // false) or (.missingFrom // false) or (.badDate // false)')" != "false" ]; then
      gated="${t_slug:-$t_where}"; break
    fi
  done <<< "$t_all"
  [ -n "$gated" ] || exit 0
  # THE OVERRIDE DOES NOT CLEAR THIS ONE (Dan, 2026-11-25, claude-config#3666: "Refuse it"). Phase 1
  # (#3665) let the command through when the override was typed, saying an announcement could not be
  # ruled out. But the override covers a pull request this gate read and found was no announcement,
  # and here it reads one of several, so an announcement among the others would merge with its post
  # and Dan's approval of it unjudged. Unlike a pull request that cannot be read at all, where the
  # override is the only way on, the remedy here is always open: one pull request per command. So it
  # is refused with or without the override, and the refusal no longer offers it (L111).
  overridden=false
  deny "Cannot judge this merge's changelog record: $span_why (One of them, $gated, may be gated by the changelog registry.) ALLOW_UNTAGGED_MERGE=1 does not clear this: the override does not cover a pull request carrying changelog/announce, and with several merges in one command this gate cannot rule one out among them. Merge one pull request per command."
fi

# A merge through the GitHub API whose pull request cannot be named (claude-config#1181). Nothing
# here can then say which repository it is in either, so whether the registry gates it cannot be
# told, and cannot tell is never "not gated" (L490). Asked in this shell, so a GraphQL merge's node is
# resolved once and the repository and number read below take that answer.
#
# TWO KINDS, and the override clears only one (claude-config#3742, item 6). A pull request GitHub
# gave no answer about (the node of a GraphQL merge that no logged-in account can resolve) is one
# nothing here can read however the command is written, so the override is the only way on and the
# merge goes through with the sentence (Dan, 2026-11-25: "Let it through, said out loud"). A command
# WRITTEN so its pull request cannot be told (one mutation merging several, a document kept in a
# file, an id passed nowhere, an endpoint or a repository flag naming no repository) is refused with
# or without the override (Dan, 2026-11-26, by picker: "Refuse them too"): like several merges in one
# command above, its remedy is always open, which is to name the pull request plainly. It was let
# through with the sentence, so an announcement merged unjudged behind an unusual spelling. The
# refusal does not offer an override that no longer clears it (L111).
if mt_api_merge_untold "$command"; then
  if [ "$MT_API_ROUTE" != graphql ]; then
    overridden=false
    deny "Cannot judge this merge's changelog record: $MT_API_WHY ALLOW_UNTAGGED_MERGE=1 does not clear this: the override does not cover a pull request carrying changelog/announce, and a command written so that its pull request cannot be told may be merging one. Name the pull request plainly, one per command: gh pr merge <number> --repo <owner>/<name>."
  fi
  unread="GitHub gave no answer about which pull request this command merges"
  deny "Cannot judge this merge's changelog record: $MT_API_WHY Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command>."
fi

# WHICH repository, resolved the way gh itself resolves it: the merge's own --repo, -R or pull
# request link first, then the directory the merge runs in (claude-config#463, #470).
#
# This gate asked gh about the session's folder whatever the merge named, exactly as
# block-red-merge.sh did before #463. A merge carrying --repo from another project was answered
# about a repository with no such pull request, so the record was refused as "gh returned
# nothing", and the registry was read for the folder's repository rather than the one being
# merged, which decides whether this gate applies at all.
repo_flag="$(mt_repo_flag "$command")"
cd "$(mt_repo_dir "$command" "$cwd")" 2>/dev/null || true

local_slug=$(mt_remote_slug)
slug="${repo_flag:-$local_slug}"

# Is this repo gated, and does the registry even parse? A registry that exists
# and cannot be read is NOT an opt out: it means the gate cannot tell, and
# treating "cannot tell" as "not in scope" is how a gate goes quiet at exactly
# the moment it stopped working (L214, L98).
scope=$(scope_for "$slug")
unread="this Mac's dev update registry could not say whether ${slug:-this repository} is gated"

[ -n "$scope" ] || deny "Cannot tell whether this repo needs a changelog record: reading $REGISTRY through lib/changelog-entry.js produced nothing at all. That is the gate failing, not the repo opting out, so it refuses rather than merging blind. Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command>."

unreadable=$(printf '%s' "$scope" | jq -r '.unreadable // false')
if [ "$unreadable" = "true" ]; then
  deny "Cannot tell whether this repo needs a changelog record: $REGISTRY exists but does not parse as JSON naming a repos list. An unreadable registry is not the same as a repo nobody gated, and merging on it would silently lose the record for the next manager update. Fix the file, or override deliberately with ALLOW_UNTAGGED_MERGE=1 <the same command>."
fi

# A changelogFrom that is not a date is a config error, and it must not read as a
# repo nobody gated. Standing down on an unreadable value would disable the gate
# on a typo and say nothing, which is the one state this design cannot afford:
# indistinguishable from a gate that is working (L98). The remedy is fixing the
# registry, not labelling the pull request, so it says that instead.
# A listed repo with NO changelogFrom is an unfinished setup, not an opt out, and it says so with
# its own message rather than taking the bare exit 0 below (claude-config#252). The repos that are
# genuinely ungated are the ones not listed at all, which is already how the registry's own note
# describes it, and that branch is untouched.
missing_from=$(printf '%s' "$scope" | jq -r '.missingFrom // false')
if [ "$missing_from" = "true" ]; then
  why=$(printf '%s' "$scope" | jq -r '.why // ""')
  deny "Cannot tell whether this repo needs a changelog record: $why. Add changelogFrom to its entry in $REGISTRY, or remove the entry if the repo is genuinely not gated. Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command>."
fi

bad_date=$(printf '%s' "$scope" | jq -r '.badDate // false')
if [ "$bad_date" = "true" ]; then
  why=$(printf '%s' "$scope" | jq -r '.why // ""')
  deny "Cannot tell whether this repo needs a changelog record: $why. Fix changelogFrom in $REGISTRY, or override deliberately with ALLOW_UNTAGGED_MERGE=1 <the same command>."
fi

in_scope=$(printf '%s' "$scope" | jq -r '.inScope // false')
[ "$in_scope" = "true" ] || exit 0

# An announcements channel that is not a channel id (claude-config#3665) is a config error in a gated
# repository, refused for every merge there in its own words, exactly as a start date that is not a
# date is above. Read as "this repository names no channel" it would refuse the announce label as
# never set up, which sends somebody to relabel when the remedy is one key in the registry, and it
# would quietly stop every later check that asks whether this repository announces (L98, L11).
#
# With the override typed it waits until the pull request has been read, below: the override clears
# it for a pull request that is not an announcement, as it clears a start date that is not a date,
# and does not clear it for one that is.
bad_announce=$(printf '%s' "$scope" | jq -r '.badAnnounce // false')
bad_announce_why=$(printf '%s' "$scope" | jq -r '.why // ""')
if [ "$bad_announce" = "true" ] && [ "$overridden" != true ]; then
  deny "Cannot tell whether this repo takes the changelog/announce label: $bad_announce_why. Fix announceChannel in its entry in $REGISTRY, or remove the key if the repo does not announce. Deliberate override, for a pull request that does not carry changelog/announce: ALLOW_UNTAGGED_MERGE=1 <the same command>."
fi

# Does this repository announce to agents at all? Only where its entry names a channel is a pull
# request asked whether it finishes a feature Dan said yes to announcing (claude-config#3669, below).
# A channel that is not a channel id is not a yes: without the override it was refused just above,
# and with it the merge of a pull request that is no announcement goes through as it always did.
announces=false
if [ "$bad_announce" != "true" ] && [ -n "$(printf '%s' "$scope" | jq -r '.announceChannel // ""')" ]; then
  announces=true
fi

pr=$(mt_pr_number "$command")

# The repository is passed to gh the same way the merge names it, so the question is about the
# pull request being merged rather than about the folder the session sits in.
envelope=$(mt_pr_view "$pr" "number,url,author,labels,body" "$slug" "$repo_flag")
found=$(printf '%s' "$envelope" | jq -r '.found // false' 2>/dev/null)

if [ "$found" != "true" ]; then
  searched="$(mt_searched_repo "$repo_flag" "$local_slug" "$PWD")"
  searched_why="$(mt_searched_why "$repo_flag" "$local_slug" "$PWD")"
  pr_label="$(mt_pr_label "$pr")"
  wrong=$(printf '%s' "$envelope" | jq -r '.wrongRepo // ""' 2>/dev/null)
  if [ -n "$wrong" ]; then
    unread="the only answer gh gave was about $wrong, not about $slug"
    deny "Refusing to merge: the only answer gh gave was about $wrong, not about $slug. Reading one pull request's changelog record while merging a different one records the wrong thing about both. Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command>."
  fi
  # NOT FOUND is not "the record could not be read" (L11). Every account answered that there is no
  # such pull request there, so the fault is where it was looked for and the remedy is naming the
  # right repository, not the override: offering the override for a pull request whose record is
  # sitting in another repository teaches reaching for it (L36, claude-config#470).
  if [ "$(printf '%s' "$envelope" | jq -r '.notFound // false' 2>/dev/null)" = "true" ]; then
    unread="no $pr_label was found in $searched"
    deny "Refusing to merge: no $pr_label was found in $searched under any logged-in account, so there is no changelog record here to read. It was looked for there because $searched_why. If it lives in another repository, name that repository with --repo owner/name on the merge, or cd into its checkout before the merge."
  fi
  gh_error=$(printf '%s' "$envelope" | jq -r '.error // ""' 2>/dev/null)
  unread="gh gave no answer about the $pr_label in $searched"
  deny "Cannot read this pull request's changelog record (gh pr view returned nothing for the $pr_label in $searched under any logged-in account${gh_error:+, $gh_error}), so whether a manager would notice this change would go unrecorded. Check the pull request, then re-run with ALLOW_UNTAGGED_MERGE=1 if the record is genuinely there."
fi

view=$(printf '%s' "$envelope" | jq -c '.view')
number=$(printf '%s' "$view" | jq -r '.number // "?"')
author=$(printf '%s' "$view" | jq -r '.author.login // ""')

# The record is read by parseEntry, which reads it the same on every Mac, and then judged by
# gateRefusal, which is this gate's alone and is handed what the registry said about THIS repository
# (claude-config#3665). The split is deliberate: parseEntry is also how merged history is read, so a
# rule about a registry in there would turn a change that shipped into a gap on a Mac whose registry
# differs.
#
# What comes back is one JSON object. `announce` is whether the pull request carries the announce
# label at all, asked first and of the label alone, because it decides whether the override covers
# this merge. Then `ok` when the merge may go ahead, or the refusal's `code` and its `reason`, which
# names the labels this repository takes. A judge that throws leaves `announce` standing with
# neither, and one that cannot even read the label prints nothing.
verdict=$(printf '%s' "$view" | HOOK_DIR="$HOOK_DIR" SCOPE="$scope" node -e '
  const entry = require(process.env.HOOK_DIR + "/lib/changelog-entry.js");
  let raw = "";
  process.stdin.on("data", function (d) { raw += d; });
  process.stdin.on("end", function () {
    let pr, scope, out;
    try {
      pr = JSON.parse(raw); scope = JSON.parse(process.env.SCOPE);
      out = { announce: entry.carriesAnnounce(pr.labels) === true };
    } catch (e) { process.stdout.write(""); return; }
    try {
      const got = entry.parseEntry({ labels: pr.labels, body: pr.body });
      const refused = entry.gateRefusal(got, pr.body, scope);
      if (refused) { out.code = refused.code; out.reason = refused.reason; } else { out.ok = true; }
    } catch (e) { /* announce alone: the judge failed, and whether this is an announcement is still known */ }
    process.stdout.write(JSON.stringify(out));
  });
' 2>/dev/null)

# Does it carry the announce label? "yes", "no", or nothing when not even that could be told.
carries=$(printf '%s' "$verdict" | jq -r 'if .announce == true then "yes" elif .announce == false then "no" else "" end' 2>/dev/null)

# THE ISSUES THE PULL REQUEST CLOSES, read once (claude-config#3666, #3669). Each comes with its
# milestone's number, title, description and open issues. One read serves both readers below: the
# `used` line an announcement's merge leaves, and the question of whether a pull request under
# another label finishes a feature Dan said yes to announcing. It sets closing_file to GitHub's
# answer, or closing_unread to why there is none. Called in this shell, never a subshell, so both
# reach the caller, who removes the file.
closing_file=""; closing_unread=""
read_closing() {
  local account
  account=$(printf '%s' "$envelope" | jq -r '.account // ""' 2>/dev/null)
  closing_unread=""
  closing_file=$(mktemp "${TMPDIR:-/tmp}/announce-closes.XXXXXX" 2>/dev/null) || closing_file=""
  if [ -n "$closing_file" ] \
    && mt_api_read "$closing_file" "$account" graphql \
         -f query='query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { closingIssuesReferences(first: 50) { totalCount nodes { number repository { nameWithOwner } milestone { number title description issues(states: OPEN, first: 100) { totalCount nodes { number } } } } } } } }' \
         -f owner="${slug%%/*}" -f name="${slug#*/}" -F number="$number" \
    && [ "$MT_READ_STATE" = ok ]; then
    return 0
  fi
  closing_unread="the issues this pull request closes could not be read from GitHub (${MT_READ_ERR:-no answer})"
  [ -n "$closing_file" ] && rm -f "$closing_file"
  closing_file=""
  return 1
}

# A FEATURE DAN SAID YES TO ANNOUNCING DOES NOT FINISH UNDER ANOTHER LABEL (claude-config#3669, R9).
#
# Feature discovery asks Dan whether a feature is announced to agents when it ships, and the
# milestone's description carries his answer as one line (skills/milestone/create-milestone.sh).
# A pull request that does NOT carry changelog/announce, in a repository that announces, is asked
# here whether it closes the last open issue of a milestone whose line says yes. When it does, and
# this Mac's record holds neither an announcement merged for that milestone nor his decline, it is
# DENIED: label it changelog/announce with wording he approved, or ask him with a picker whether it
# is still being announced. His `Not announcing` is read into the record by the same path as an
# approval (lib/announce-approval.py says how), and only that clears it.
#
# The judge is lib/announce-approval.py's `finishes`, handed GitHub's own answer: which milestone
# says yes, which is finished, and what the record holds are all its to say, so this file reads
# none of it a second way. It gives back `announced`, the pull requests the record holds as let
# through with an announcement for the milestone. That line says this gate let one through, never
# that GitHub merged it, so GitHub is asked about each, and only one that merged and still carries
# changelog/announce covers the milestone: one that has not merged, or that merged with the label
# taken off, announced nothing.
#
# A deny, never `ask`, like every refusal about an announcement: only his picker clears it. So the
# override does not clear it either. What GitHub or the record does not answer is refused in its
# own words, never read as "not the last" (L98), and there the override is the only way on, as it
# is for a pull request whose labels could not be read: the merge goes through and the allow says
# what was not read. Every other pull request leaves here with nothing said: one that closes no
# issue, one that leaves the milestone open, one whose milestone says no or that nobody was asked
# about, and any pull request in a repository that does not announce, which is not read at all.
finishes_announced_feature() {
  [ "$announces" = true ] || return 0
  local was_overridden="$overridden" verdict9="" state9="" n other other_state unmerged="" spent9=""
  r9_unread() {  # $1 = what could not be read
    [ -n "$closing_file" ] && rm -f "$closing_file"
    if [ "$was_overridden" = true ]; then
      hook_allow_notice "ALLOW_UNTAGGED_MERGE=1 let this merge through, but $1, so whether PR #$number finishes a feature Dan said yes to announcing to agents was never read, and one that does, which the override does not cover, could not be ruled out." PreToolUse
    fi
    overridden=false
    deny "Cannot tell whether PR #$number finishes a feature Dan said yes to announcing to agents: $1. Where a repository announces, the pull request that finishes such a feature merges under changelog/announce unless he declined in a picker, and what could not be read is never taken as a pull request that finishes none. Try the merge again. Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command>."
  }
  # $1 = the pull requests GitHub says did not merge as an announcement, comma separated, or nothing.
  # $2 = for the second question, what the first one spent of the time one call has for reading
  # noted sessions back. The two share that time, so asking twice reads back no longer than asking
  # once, and the library reads what is no count of seconds as no time left.
  r9_ask() {
    verdict9=$(printf '%s' "$payload" | python3 -B "$HOOK_DIR/lib/announce-approval.py" finishes --repo "$slug" --pr "$number" --answer-file "$closing_file" ${1:+--unmerged "$1"} ${2:+--spent "$2"} --hook 2>/dev/null)
    state9=$(printf '%s' "$verdict9" | jq -r '.state // ""' 2>/dev/null)
  }
  read_closing || r9_unread "$closing_unread"
  # A pull request that closes no issue finishes no milestone, and GitHub's answer alone says so:
  # a count of none beside an empty list, and nothing short of both. It leaves here before python3
  # or the library is needed, so a library that cannot answer refuses only the pull requests whose
  # verdict is the library's to give (any that closes an issue), never every merge in a repository
  # that announces. Any other answer, one that cannot be read included, goes on to the library.
  if jq -e '.data.repository.pullRequest.closingIssuesReferences | (.totalCount == 0) and ((.nodes | type) == "array") and ((.nodes | length) == 0)' "$closing_file" >/dev/null 2>&1; then
    rm -f "$closing_file"; closing_file=""
    return 0
  fi
  command -v python3 >/dev/null 2>&1 \
    || r9_unread "python3 is not installed, and lib/announce-approval.py, which reads the milestone's line and Dan's answers, runs under it"
  r9_ask ""
  if [ "$state9" = clear ]; then
    for n in $(printf '%s' "$verdict9" | jq -r '.announced[]?' 2>/dev/null); do
      # Its state and its labels in one read. The record's line is written before the merge runs,
      # so the pull request may have merged later with the announce label taken off: merged, and
      # nothing announced. It covers the milestone only when it merged AND still carries the
      # label, which lib/changelog-entry.js reads here as it does for the pull request being
      # merged. The answer is "<state> yes|no", or nothing when either was not in GitHub's answer.
      other=$(mt_pr_view "$n" "number,url,state,labels" "$slug" "$repo_flag")
      other_state=$(printf '%s' "$other" | HOOK_DIR="$HOOK_DIR" OTHER_PR="$n" node -e '
        const entry = require(process.env.HOOK_DIR + "/lib/changelog-entry.js");
        let raw = "";
        process.stdin.on("data", function (d) { raw += d; });
        process.stdin.on("end", function () {
          try {
            const got = JSON.parse(raw), view = got.view;
            if (got.found !== true || view.number !== Number(process.env.OTHER_PR)) return;
            if (typeof view.state !== "string" || !/^[A-Z]+$/.test(view.state) || !Array.isArray(view.labels)) return;
            process.stdout.write(view.state + " " + (entry.carriesAnnounce(view.labels) === true ? "yes" : "no"));
          } catch (e) { /* nothing printed: not read */ }
        });
      ' 2>/dev/null)
      case "$other_state" in
        "MERGED yes") ;;
        '') r9_unread "GitHub gave no answer that holds both the state and the labels of pull request $n, which this Mac's record holds as let through with an announcement for a milestone this pull request finishes, so whether that announcement merged, and merged under changelog/announce, could not be told" ;;
        *) unmerged="${unmerged:+$unmerged,}$n" ;;
      esac
    done
    if [ -n "$unmerged" ]; then
      spent9=$(printf '%s' "$verdict9" | jq -r 'if (.spent | type) == "number" then .spent else "unknown" end' 2>/dev/null)
      r9_ask "$unmerged" "${spent9:-unknown}"
    fi
  fi
  rm -f "$closing_file"; closing_file=""
  case "$state9" in
    clear) return 0 ;;
    owed)
      overridden=false
      deny "PR #$number cannot merge as it stands: it does not carry changelog/announce, and $(printf '%s' "$verdict9" | jq -r '.why // ""') $(printf '%s' "$verdict9" | jq -r '.how // ""')

This is checked at merge time because the pull request that closes a milestone's last open issue is the last one that can carry its announcement: after it, nothing asks again. ALLOW_UNTAGGED_MERGE=1 does not clear this: only Dan's answer in a picker does." ;;
    unread) r9_unread "$(printf '%s' "$verdict9" | jq -r '.why // ""')" ;;
    *) r9_unread "lib/announce-approval.py gave no verdict that could be read about the milestone it closes issues of" ;;
  esac
}

# Dependabot writes no body block and merges itself through the auto-merge
# workflow, so gating it would stall that workflow permanently on every bump.
# Its changes are also not a per-change record in the update: they collapse into
# one standing roll-up line about dependency updates, which is how the June to
# August post already treated them.
#
# It leaves here only once the label has been read and is not the announce label
# (claude-config#3703). This exit used to stand above that question, so a pull request the bot
# opened, relabelled changelog/announce and given an Announcement block, merged on wording nobody
# approved and left no line on the record. One that carries the label is judged like any other from
# here on, and so is one whose labels could not be read, since that is not known to be free of it.
#
# It does not leave past the question of whether it finishes a feature Dan said yes to announcing
# (claude-config#3669, just above): that rule has no exception for who opened the pull request.
if [ "$carries" = no ]; then
  case "$author" in
    dependabot|dependabot\[bot\]|app/dependabot) finishes_announced_feature; exit 0 ;;
  esac
fi

# THE OVERRIDE'S TWO EXCEPTIONS (the head of this file). The labels have been read, so the override
# is settled here and nowhere later. It does not cover two things:
#   1. a pull request that is an announcement. From this line on it is judged as if the override had
#      not been typed.
#   2. a pull request that is no announcement and finishes a feature Dan said yes to announcing
#      (claude-config#3669). So that is asked first, and it is refused with or without the override.
#      Only where whether it finishes one could not be read does the override let it through, and
#      that is said (finishes_announced_feature).
# Any other pull request that is no announcement takes the override, whatever is wrong with its
# record. Where the label could not be told the merge goes through and that is said.
if [ "$overridden" = true ]; then
  case "$carries" in
    no) finishes_announced_feature; exit 0 ;;
    yes) overridden=false ;;
    *) unread="lib/changelog-entry.js failed while reading the pull request's labels"
       override_allows ;;
  esac
fi

# What every refusal of a pull request carrying the announce label ends with, in place of the
# override the other refusals offer: offered there, it would send somebody to a command that is
# refused again.
not_covered="ALLOW_UNTAGGED_MERGE=1 does not cover a pull request carrying changelog/announce, so it is judged in full with or without it."

# The channel that is not a channel id, held back above while the override stood.
if [ "$bad_announce" = "true" ]; then
  deny "PR #$number cannot merge as it stands: it carries changelog/announce and $bad_announce_why. Fix announceChannel in its entry in $REGISTRY. $not_covered"
fi

# The judge says so when the record passes. Nothing at all is the judge failing (a library that
# threw, an answer that could not be read), and that is never a record with nothing wrong: it used
# to be read as one, since an empty answer was the passing answer (L98, L490).
verdict_ok=$(printf '%s' "$verdict" | jq -r '.ok // false' 2>/dev/null)
if [ "$verdict_ok" != "true" ]; then
  verdict_code=$(printf '%s' "$verdict" | jq -r '.code // ""' 2>/dev/null)
  verdict_reason=$(printf '%s' "$verdict" | jq -r '.reason // ""' 2>/dev/null)
  if [ -z "$verdict_reason" ]; then
    no_verdict="Cannot judge this merge's changelog record: reading PR #$number through lib/changelog-entry.js produced no verdict at all. That is the gate failing, not the record passing, so it refuses rather than merging blind."
    [ "$carries" = yes ] && deny "$no_verdict Reinstall the hooks with claude-sync pull. $not_covered"
    deny "$no_verdict Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command>."
  fi
  # A pull request carrying the announce label, whatever it is refused for: the label where it is
  # not in use, the post for agents under it (missing, empty, or holding what may not be drafted),
  # and equally the refusals it shares with a visible one (a second label, its Changelog sentence).
  if [ "$carries" = yes ]; then
    deny "PR #$number cannot merge as it stands. $verdict_reason

This is checked at merge time because the post under changelog/announce is drafted for agents exactly as the pull request holds it once the change is live. $not_covered"
  fi
  case "$verdict_code" in
    # A post for agents under another label. The override does cover this pull request, and its
    # refusal still does not print it, so nobody is pointed at the override for a post somebody
    # meant agents to read.
    ANNOUNCE_*|ANNOUNCEMENT_*|NO_ANNOUNCEMENT|EMPTY_ANNOUNCEMENT)
      deny "PR #$number cannot merge as it stands. $verdict_reason

This is checked at merge time because a post written under an Announcement heading is one somebody meant agents to read, and only changelog/announce drafts it." ;;
  esac
  deny "PR #$number carries no usable changelog record. $verdict_reason

This is checked at merge time because judging it later means re-reading every merged title, which is what assembling the June to August update actually cost. Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command>."
fi

# Every other pull request is done here, its record passed, once it has been asked whether it
# finishes a feature Dan said yes to announcing (claude-config#3669, R9).
if [ "$carries" != yes ]; then
  finishes_announced_feature
  exit 0
fi

# THE MERGE IS THE CALL'S ONE GITHUB WRITE (claude-config#3742, item 4).
#
# Everything below judges the Announcement block as GitHub holds it NOW, which is before this call
# runs. A call that edits the description and then merges (`gh pr edit 7 --body-file new.md && gh pr
# merge 7`) was judged on the wording as it stood: approved wording was found and claimed, then the
# command replaced the block and merged wording Dan never saw. So for an announcement a call holding
# any other GitHub write beside the one merge is refused and told to run them apart, which is always
# open. It is asked here, before the approval is claimed, so a call refused for it claims nothing.
#
# The count is gh_issue_scan.py's gh_writes, the one the label hook asks (announce_label_gate.py),
# never a second reading of the call kept here. A merge through the GitHub API is itself one of the
# writes it counts, so that route is allowed one (MT_API_ROUTE, set where the merge was told above).
# The merge helper's own call is gh, its merge arguments and the commit it pins: no other write.
# A count that could not be made is refused in its own words, never read as none (L98).
merge_writes=0
case "${MT_API_ROUTE:-}" in rest|graphql) merge_writes=1 ;; esac
call_writes=""
if command -v python3 >/dev/null 2>&1; then
  call_writes=$(printf '%s' "$command" | python3 -B "$HOOK_DIR/gh_issue_scan.py" writes "$cwd" 2>/dev/null)
fi
writes=$(printf '%s' "$call_writes" | jq -r 'if (.writes | type) == "number" then .writes else "" end' 2>/dev/null)
case "$writes" in
  ''|*[!0-9]*)
    writes_why=$(printf '%s' "$call_writes" | jq -r '.unread // ""' 2>/dev/null)
    deny "PR #$number cannot merge in this call: it carries changelog/announce, and whether the call holds another GitHub write beside the merge could not be read (${writes_why:-gh_issue_scan.py, which python3 runs beside this hook, gave no count}). Its announcement is judged as the description holds it before the call runs, so a write ahead of the merge could change the wording after it was judged. Run the merge as a call of its own: gh pr merge $number --repo $slug. If it is refused again, reinstall the hooks with claude-sync pull. $not_covered" ;;
esac
if [ "$writes" -gt "$merge_writes" ]; then
  deny "PR #$number cannot merge in this call: it carries changelog/announce, and the call holds $((writes - merge_writes)) other GitHub write$([ $((writes - merge_writes)) -eq 1 ] || printf 's') beside the merge (gh pr create, gh pr edit, gh issue edit or a gh api call that writes). Its announcement is judged as the description holds it before the call runs, so a write ahead of the merge could change the wording after Dan approved it and after it was judged. Run them apart: the other write in a call of its own, then the merge alone. $not_covered"
fi

# THE WORDING DAN APPROVED (claude-config#3666; Dan: "it should ask me before applying the label").
#
# The record passed, so this is an announcement carrying its post. That post is drafted for agents
# exactly as the pull request holds it once the change is live, so it merges only when it is wording
# Dan approved, after it was opened in front of him. The Announcement block as GitHub holds it NOW is
# hashed by lib/changelog-entry.js (its one normalised form) and lib/announce-approval.py is asked
# whether that hash is one he approved for this repository, in this session's own picker or on this
# Mac's record. An edit to the wording after he approved, by any route including GitHub's own page,
# changes the hash; an edit anywhere else in the description does not.
#
# This is the step every session route to a merge passes, which is why R2 is held here and not by
# the commands that add the label (announce-label-ask.sh is only the early refusal for those).
#
# Every refusal is a deny, never `ask`: a permission prompt shows the command and not the wording,
# and sleep mode can answer one with Dan asleep (db-write-ask.sh). Only his picker clears it. And a
# check that gives no verdict (python3 or node missing, the library throwing, an answer that cannot
# be read) is refused in its own words, since nothing at all is never an approval (L98).
#
# ONE APPROVAL COVERS ONE PULL REQUEST (Dan, 2026-11-25, by picker: "One approval, one pull
# request"). The question names this pull request and claims: the library, holding a lock on the
# record, decides and writes this pull request down as the one using the approval in one step, so
# of two pull requests reaching this gate at once on one approval exactly one is let through. The
# pull request that used an approval may try its merge again; a different one carrying the same
# wording is refused and asks him again. An approval nobody has used covers whichever pull request
# gets here first. And when the claim cannot be written the merge is REFUSED, saying what could not
# be written and where (Dan, 2026-11-25, by picker: "Refuse the merge"): let through unrecorded, the
# next pull request with the same wording would merge on the same approval. This is the last thing
# that can refuse, so a pull request refused for anything else has claimed nothing.
#
# The library's answer says which of these it is (.state), so each refusal's first sentence says
# what was found and no other (L11): wording he never approved, an approval another pull request
# used, or a use that could not be recorded.
block=$(printf '%s' "$view" | jq -r '.body // ""' | node "$HOOK_DIR/lib/changelog-entry.js" announcement-hash --body 2>/dev/null)
block_hash=$(printf '%s' "$block" | jq -r '.hash // ""' 2>/dev/null)
approval=""
if [ -n "$block_hash" ] && command -v python3 >/dev/null 2>&1; then
  approval=$(printf '%s' "$payload" | python3 -B "$HOOK_DIR/lib/announce-approval.py" check --repo "$slug" --hash "$block_hash" --pr "$number" --claim 2>/dev/null)
fi
case "$(printf '%s' "$approval" | jq -r 'if .approved == true then "yes" elif .approved == false then (if .state == "used" or .state == "unrecorded" then .state else "no" end) else "" end' 2>/dev/null)" in
  yes) ;;
  no)
    deny "PR #$number cannot merge as it stands: it carries changelog/announce, and its announcement is not wording Dan approved. $(printf '%s' "$approval" | jq -r '.why // ""') $(printf '%s' "$approval" | jq -r '.how // ""')

This is checked at merge time because the post is drafted for agents exactly as the pull request holds it once the change is live, so an edit to it after he approved, by any route, is asked about again. $not_covered" ;;
  used)
    deny "PR #$number cannot merge as it stands: it carries changelog/announce, and Dan's approval of its announcement was used by another pull request. $(printf '%s' "$approval" | jq -r '.why // ""') $(printf '%s' "$approval" | jq -r '.how // ""')

This is checked at merge time because each announcement that merges is drafted for agents once the change is live, so the same post in a second pull request is a second post, and he is asked about it. $not_covered" ;;
  unrecorded)
    deny "PR #$number cannot merge as it stands: it carries changelog/announce, and that it is using Dan's approval of its announcement could not be recorded. $(printf '%s' "$approval" | jq -r '.why // ""') $(printf '%s' "$approval" | jq -r '.how // ""')

This is checked at merge time because one approval of his covers one pull request, and a merge let through unrecorded would leave that approval open to the next pull request carrying the same wording. $not_covered" ;;
  *)
    deny "Cannot tell whether Dan approved the announcement in PR #$number: hashing its Announcement block through lib/changelog-entry.js and asking lib/announce-approval.py produced no verdict at all (python3 and node both run them). That is the gate failing, not the wording being approved, so it refuses rather than merging blind. Reinstall the hooks with claude-sync pull. $not_covered" ;;
esac

# THE ISSUES IT CLOSES. The gate is letting this merge go ahead, and the claim above already recorded
# this pull request as the one using the approval. Beside it goes each issue the pull request closes
# with that issue's milestone: what the later check that a feature Dan said yes to announcing does
# not finish under another label reads. Both are written before the merge runs, so they say this
# gate let it through, never that GitHub merged it. Nothing from here on can stop the merge: issues
# that cannot be read are recorded as unread with why, and a line that cannot be written is said
# beside the merge.
said=$(printf '%s' "$approval" | jq -r '(.notes // []) | join(" ")' 2>/dev/null)
closes=""; closes_unread=""
# The one read of the issues it closes (read_closing, above). Each is recorded with its milestone's
# title and number: the number is what `finishes` finds an announced milestone by (claude-config#3669).
if read_closing; then
  closes=$(jq -c '[.data.repository.pullRequest.closingIssuesReferences.nodes[] | {issue: .number, repo: .repository.nameWithOwner, milestone: (.milestone.title // null), milestone_number: (.milestone.number // null)}]' "$closing_file" 2>/dev/null)
  [ -n "$closes" ] || closes_unread="GitHub's answer about the issues this pull request closes could not be read"
  rm -f "$closing_file"
else
  closes_unread="$closing_unread"
fi
used=$(python3 -B "$HOOK_DIR/lib/announce-approval.py" used --repo "$slug" --hash "$block_hash" --pr "$number" \
  ${closes:+--closes "$closes"} ${closes_unread:+--unread "$closes_unread"} 2>/dev/null)
if [ "$(printf '%s' "$used" | jq -r '.written // false' 2>/dev/null)" != "true" ]; then
  said="${said:+$said }PR #$number is recorded as the one using Dan's approval, but the issues it closes could not be added to this Mac's record of approved announcements ($(printf '%s' "$used" | jq -r '.why // ""' 2>/dev/null)), so the check that a feature Dan said yes to announcing does not finish under another label will not find them there."
fi
# THIS MERGE OWES A DRAFT (claude-config#3667). Only an announcement the gate lets through reaches
# here, so its allow always says one line, to Dan and to the session, after anything said above:
# what the is it live card asks for once the change is live, and that a card silent about it is an
# old copy of the mod. Nothing the gate decides depends on it.
hook_allow_notice "${said:+$said }PR #$number owes agents its announcement: once its change is live, the is it live card for it tells the session to save the approved wording as a Slack draft for Dan to send. A session whose card for it says nothing about an announcement is running an old copy of the is it live mod: run /reload-plugins, then make the card again." PreToolUse

exit 0
