#!/usr/bin/env bash
#
# pr-review-gate.sh
# Claude Code PreToolUse(Bash) hook.
#
# Refuse a merge until the lessons review of that pull request's head has FINISHED and its findings
# have been READ by the session merging (claude-config#560, #788): the merge presents the findings'
# read key as PR_REVIEW_READ=<key>, which only the messages carrying them hold. The review itself, and every outcome it can have, is
# lib/pr-review.sh; this hook only decides whether a command merges and which head it merges.
#
# EVERY MERGE ROUTE this hook can see: `gh pr merge`, and a repo's own merge script in command
# position (mt_runs_merge, the matcher block-red-merge.sh and the changelog gate share). It is
# registered WITHOUT an `if` filter, because block-red-merge's `Bash(gh pr merge*)` never fires for
# a script. A merge made INSIDE a script this hook cannot see (Overture's merge_pr is called by
# verify-and-merge-branch.sh and verify-and-merge-batch.sh, which are not merge tools by name) is
# covered by that script asking `pr-review.sh check` itself before it merges, so the rule lives in
# one place and every route asks it.
#
# The head is the PULL REQUEST's, read from GitHub (headRefOid) through mt_pr_view, never the local
# HEAD, which can be a different commit (L179). Refuses when the pull request cannot be found:
# merging something no review has read is what this gate exists to stop (L42).
#
# Override, one command, visible: SKIP_PR_REVIEW=1 on the merge. Explain to Dan first.

set -uo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload="$(cat)"

# It runs before EVERY Bash command, so the commonest case leaves before anything is loaded: every
# route mt_runs_merge recognises contains "merge", and a payload without it cannot be one.
case "$payload" in *merge*) ;; *) exit 0 ;; esac

refuse() { printf '%s\n' "$1" >&2; exit 2; }

# The libraries this gate reads through. Missing, it cannot tell a merge from anything else, so it
# refuses only what could be one, by the cheap substring the matcher itself starts with.
if ! . "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null; then
  case "$payload" in
    *SKIP_PR_REVIEW=1*) exit 0 ;;
    *merge*) refuse "Refusing to merge: lib/merge-target.sh is missing, so pr-review-gate.sh cannot tell whether this command merges a pull request or read its head for the lessons review. Override for one merge, explained to Dan first: SKIP_PR_REVIEW=1 <the same command>." ;;
  esac
  exit 0
fi
if ps_reader_missing jq python3 || ! command -v jq >/dev/null 2>&1; then
  case "$payload" in
    *SKIP_PR_REVIEW=1*) exit 0 ;;
    *merge*) refuse "Refusing to merge: jq is not on PATH, and the lessons review gate reads the pull request's head from GitHub with it. Install jq. Override for one merge, explained to Dan first: SKIP_PR_REVIEW=1 <the same command>." ;;
  esac
  exit 0
fi

parsed="$(ps_parse_payload "$payload" raw)" || parsed=""
command="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
mt_runs_merge "$command" || exit 0

if ps_has_override "$command" SKIP_PR_REVIEW; then
  echo "pr-review-gate: SKIP_PR_REVIEW=1 was set, so this merge was NOT held for the lessons review. Tell Dan why it was skipped; never skip it silently."
  exit 0
fi

repo_dir="$(mt_repo_dir "$command" "$cwd" 2>/dev/null)"
[ -n "$repo_dir" ] || repo_dir="$cwd"
cd "$repo_dir" 2>/dev/null || refuse "Refusing to merge: could not enter $repo_dir to find the lessons review for this merge. Override, explained to Dan first: SKIP_PR_REVIEW=1 <the same command>."

pr="$(mt_pr_number "$command")"
repo_flag="$(mt_repo_flag "$command")"
slug="${repo_flag:-$(mt_remote_slug)}"
envelope="$(mt_pr_view "$pr" "number,headRefOid,baseRefName,headRefName,url" "$slug" "$repo_flag")"
head="$(printf '%s' "$envelope" | jq -r 'if .found then .view.headRefOid // "" else "" end' 2>/dev/null)"
base="$(printf '%s' "$envelope" | jq -r 'if .found then .view.baseRefName // "" else "" end' 2>/dev/null)"
# The pull request's own branch labels the review, never the branch this checkout happens to be on,
# which on a shared primary checkout is another session's work (claude-config#852).
head_branch="$(printf '%s' "$envelope" | jq -r 'if .found then .view.headRefName // "" else "" end' 2>/dev/null)"
if [ -z "$head" ]; then
  err="$(printf '%s' "$envelope" | jq -r '.error // ""' 2>/dev/null)"
  refuse "Refusing to merge: could not read the head of $(mt_pr_label "$pr") in ${slug:-this repository} from GitHub${err:+ ($err)}, so there is no way to know which lessons review answers for it. Override, explained to Dan first: SKIP_PR_REVIEW=1 <the same command>."
fi

args=(check --dir "$repo_dir" --sha "$head")
[ -n "$base" ] && args+=(--base-ref "origin/$base")
[ -n "$head_branch" ] && args+=(--branch "$head_branch")
# The read key the findings' refusal carries, if this merge presents it (claude-config#788). The
# hook does not inherit the command's own assignments, so it is read from the command text and
# handed on; anything else in the environment is cleared, so only THIS command can present one.
#
# Only as an assignment in front of the MERGE segment itself: text in an echo, or an assignment in
# front of some other command, says nothing about this merge (L673). Segments are cut the way the
# merge matcher cuts them, so the segment judged a merge here is the one mt_runs_merge judged, and
# its leading assignments are read as the shell reads them, so a key before
# `GH_TOKEN=$(gh auth token -u x) gh pr merge` is found and quotes around it are removed.
read_key="$(mt_presented_read_key "$command" mt_runs_merge)"
out="$(PR_REVIEW_READ="$read_key" bash "$HOOK_DIR/lib/pr-review.sh" "${args[@]}" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && { printf 'pr-review-gate: %s\n' "$out"; exit 0; }
refuse "$out"
