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
#   the LABEL   changelog/visible | changelog/technical | changelog/none
#   the BODY    a "## Changelog" block carrying the sentence a manager reads,
#               required only for changelog/visible
#
# Both are read through lib/changelog-entry.js, which is the single definition of
# what a valid record is. A rule that lives only in a pull request template is a
# hope (L27): the template is the reminder, this is the enforcement.
#
# Scope: a repo is gated only when the /pennie-dev-update skill's repos.json
# lists it WITH a changelogFrom date. Every other repo on the machine is
# untouched. That file is the registry the update itself already reads, so Slate
# is added in one place rather than two.
#
# WHICH repo that is comes from the merge, resolved the way gh resolves it: its own --repo, -R
# or pull request link first, then the directory it runs in (claude-config#470).
#
# Fails CLOSED where it can tell there is a problem, and stands down where it
# genuinely has nothing to say. The three are deliberately different answers: a
# missing registry means the update tooling is not installed here, an unreadable
# one means the gate cannot tell whether this repo is in scope, and an unlisted
# repo means somebody chose not to gate it.
#
# Covers every route to a merge, including a repo's own wrapper, because a gate that
# only knows the direct command is dodged by the very route another gate makes
# mandatory (claude-config#351).
#
# Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command> (visible in the
# command, so it cannot happen by accident or go unnoticed in the transcript).
#
# Seams, for the tests: CHANGELOG_REGISTRY points at a different registry file.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/merge-target.sh
. "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null || exit 0

payload=$(cat)
command=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)

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

case "$command" in
  *ALLOW_UNTAGGED_MERGE=1*) exit 0 ;;
esac

REGISTRY="${CHANGELOG_REGISTRY:-$HOME/.claude/skills/pennie-dev-update/repos.json}"

# No registry at all: the dev update tooling is not installed on this machine, so
# there is no update for a record to feed and nothing to enforce. This is the one
# absence that is a genuine stand down rather than a blind spot.
[ -f "$REGISTRY" ] || exit 0

command -v node >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# The reader the shared library needs for a direct merge's own arguments (claude-config#475).
# Without python3 the pull request and the repository this command names both come back empty, so
# this gate read the record of whatever pull request gh resolves from the current branch, in
# whatever repository this folder belongs to. It refuses by name rather than letting that arrive
# as "no pull request was found", which is a true sentence about a different fault and sends
# somebody to name a repository that was never the problem (L11).
#
# Below the registry check deliberately: on a machine with no dev update tooling this gate has
# nothing to enforce and stands down, and a refusal about a reader would be a refusal about a rule
# that does not apply here. Only the direct form, because a wrapper names its number as a
# positional argument the shell reads and names no repository at all.
if mt_is_pr_merge "$command" && mt_reader_missing; then
  deny "Cannot tell whether this repo needs a changelog record: $(mt_reader_absent_why) Reading another pull request's record while merging this one would lose this change from the next manager update. Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command>."
fi

cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)

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
scope=$(HOOK_DIR="$HOOK_DIR" REGISTRY_PATH="$REGISTRY" SLUG="$slug" node -e '
  const fs = require("fs");
  const entry = require(process.env.HOOK_DIR + "/lib/changelog-entry.js");
  let registry = null;
  try { registry = JSON.parse(fs.readFileSync(process.env.REGISTRY_PATH, "utf8")); }
  catch (e) { registry = null; }
  process.stdout.write(JSON.stringify(entry.repoScope(registry, process.env.SLUG)));
' 2>/dev/null)

[ -n "$scope" ] || deny "Cannot tell whether this repo needs a changelog record: reading $REGISTRY through lib/changelog-entry.js produced nothing at all. That is the gate failing, not the repo opting out, so it refuses rather than merging blind. Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command>."

unreadable=$(printf '%s' "$scope" | jq -r '.unreadable // false')
if [ "$unreadable" = "true" ]; then
  deny "Cannot tell whether this repo needs a changelog record: $REGISTRY exists but does not parse as JSON naming a repos array. An unreadable registry is not the same as a repo nobody gated, and merging on it would silently lose the record for the next manager update. Fix the file, or override deliberately with ALLOW_UNTAGGED_MERGE=1 <the same command>."
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
    deny "Refusing to merge: the only answer gh gave was about $wrong, not about $slug. Reading one pull request's changelog record while merging a different one records the wrong thing about both. Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command>."
  fi
  # NOT FOUND is not "the record could not be read" (L11). Every account answered that there is no
  # such pull request there, so the fault is where it was looked for and the remedy is naming the
  # right repository, not the override: offering the override for a pull request whose record is
  # sitting in another repository teaches reaching for it (L36, claude-config#470).
  if [ "$(printf '%s' "$envelope" | jq -r '.notFound // false' 2>/dev/null)" = "true" ]; then
    deny "Refusing to merge: no $pr_label was found in $searched under any logged-in account, so there is no changelog record here to read. It was looked for there because $searched_why. If it lives in another repository, name that repository with --repo owner/name on the merge, or cd into its checkout before the merge."
  fi
  gh_error=$(printf '%s' "$envelope" | jq -r '.error // ""' 2>/dev/null)
  deny "Cannot read this pull request's changelog record (gh pr view returned nothing for the $pr_label in $searched under any logged-in account${gh_error:+, $gh_error}), so whether a manager would notice this change would go unrecorded. Check the pull request, then re-run with ALLOW_UNTAGGED_MERGE=1 if the record is genuinely there."
fi

view=$(printf '%s' "$envelope" | jq -c '.view')
number=$(printf '%s' "$view" | jq -r '.number // "?"')
author=$(printf '%s' "$view" | jq -r '.author.login // ""')

# Dependabot writes no body block and merges itself through the auto-merge
# workflow, so gating it would stall that workflow permanently on every bump.
# Its changes are also not a per-change record in the update: they collapse into
# one standing roll-up line about dependency updates, which is how the June to
# August post already treated them.
case "$author" in
  dependabot|dependabot\[bot\]|app/dependabot) exit 0 ;;
esac

verdict=$(printf '%s' "$view" | HOOK_DIR="$HOOK_DIR" node -e '
  const entry = require(process.env.HOOK_DIR + "/lib/changelog-entry.js");
  let raw = "";
  process.stdin.on("data", function (d) { raw += d; });
  process.stdin.on("end", function () {
    let pr;
    try { pr = JSON.parse(raw); } catch (e) { process.stdout.write(""); return; }
    const got = entry.parseEntry({ labels: pr.labels, body: pr.body });
    process.stdout.write(got.ok ? "" : got.reason);
  });
' 2>/dev/null)

[ -n "$verdict" ] && deny "PR #$number carries no usable changelog record. $verdict

This is checked at merge time because judging it later means re-reading every merged title, which is what assembling the June to August update actually cost. Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command>."

exit 0
