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
# Fails CLOSED where it can tell there is a problem, and stands down where it
# genuinely has nothing to say. The three are deliberately different answers: a
# missing registry means the update tooling is not installed here, an unreadable
# one means the gate cannot tell whether this repo is in scope, and an unlisted
# repo means somebody chose not to gate it.
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

cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)
cd "$(mt_repo_dir "$command" "$cwd")" 2>/dev/null || true

slug=$(mt_remote_slug)

# Is this repo gated, and does the registry even parse? A registry that exists
# and cannot be read is NOT an opt out: it means the gate cannot tell, and
# treating "cannot tell" as "not in scope" is how a gate goes quiet at exactly
# the moment it stopped working (L214, L98).
scope=$(REGISTRY_PATH="$REGISTRY" SLUG="$slug" node -e '
  const fs = require("fs");
  const entry = require(process.env.HOOK_DIR + "/lib/changelog-entry.js");
  let registry = null;
  try { registry = JSON.parse(fs.readFileSync(process.env.REGISTRY_PATH, "utf8")); }
  catch (e) { registry = null; }
  process.stdout.write(JSON.stringify(entry.repoScope(registry, process.env.SLUG)));
' 2>/dev/null)
HOOK_DIR="$HOOK_DIR" export HOOK_DIR
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

in_scope=$(printf '%s' "$scope" | jq -r '.inScope // false')
[ "$in_scope" = "true" ] || exit 0

pr=$(mt_pr_number "$command")

view=$(mt_pr_view "$pr" "number,url,author,labels,body" "$slug") || view=""
if [ -z "$view" ]; then
  if [ -n "${MT_WRONG_REPO:-}" ]; then
    deny "Refusing to merge: the only answer gh gave was about $MT_WRONG_REPO, not about $slug. Reading one pull request's changelog record while merging a different one records the wrong thing about both. Deliberate override: ALLOW_UNTAGGED_MERGE=1 <the same command>."
  fi
  deny "Cannot read this pull request's changelog record (gh pr view returned nothing under any logged-in account), so whether a manager would notice this change would go unrecorded. Check the pull request, then re-run with ALLOW_UNTAGGED_MERGE=1 if the record is genuinely there."
fi

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
