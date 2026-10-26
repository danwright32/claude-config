#!/usr/bin/env bash
#
# stacked-prs.sh: the one reading of the open pull requests STACKED on a branch, that is, based on
# it (claude-config#1337, #1723). Sourced, never executed.
#
# WHY IT EXISTS. GitHub closes an open pull request the moment the branch it is based on is deleted
# through the API or a push, and a closed pull request's base can never be changed again, so it has
# to be opened again as a new one, losing its review thread and a CI round. That happened twice:
# bidspoke#2482 on 2026-10-19, when gh pr merge --delete-branch deleted the merged branch, and
# bidspoke#2763 on 2026-10-25, when the merged branch was deleted by hand with
# `gh api -X DELETE .../git/refs/heads/<branch>`. Two places now ask the question before a branch on
# GitHub goes: lib/merge-when-ready.sh, which moves every stacked pull request onto the merged one's
# base before deleting its branch, and stacked-branch-delete-gate.sh, which refuses a typed delete
# while any is stacked. They ask through this one function, so they cannot come to disagree about
# what counts as stacked, or about what a failed list is (L370).
#
# A list that could not be read is NEVER an empty one: "could not list" must not read as "nothing
# stacked", because the caller's next step is a delete that closes whatever it could not see.

# Sets SP_STACKED to the numbers of the open pull requests in $2 based on branch $3, one a line,
# empty for none, and returns 0. Returns 1 when GitHub's answer is not a list (gh failed, or printed
# something else), with SP_STACKED empty, SP_OUT holding what gh printed (stdout and stderr) and
# SP_RC its exit code, so the caller can say why in GitHub's own words and classify the failure.
# $1 runs gh: `gh` itself, or a caller's function that runs it as a particular account.
sp_read_stacked() {   # $1 = gh runner  $2 = owner/name  $3 = branch
  SP_STACKED=""
  SP_OUT="$("$1" pr list --repo "$2" --base "$3" --state open --limit 1000 --json number 2>&1)"; SP_RC=$?
  if [ "$SP_RC" -eq 0 ] \
    && SP_STACKED="$(printf '%s' "$SP_OUT" | jq -r 'if type == "array" then .[].number else error("not a list") end' 2>/dev/null)"; then
    return 0
  fi
  SP_STACKED=""
  return 1
}

# owner/name of a GitHub remote URL, in any of the spellings git takes for one (https, ssh, scp
# like git@github.com:owner/name, with or without .git); prints nothing for a remote elsewhere.
sp_github_slug() {   # $1 = a remote URL
  printf '%s' "$1" | sed -nE 's#^(https?://([^/@]+@)?|ssh://([^/@]+@)?|git://|([^/@]+@))github\.com[:/]([^/]+)/([^/]+)$#\5/\6#p' \
    | sed -E 's#\.git$##; s#/$##'
}
