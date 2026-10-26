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

# owner/name of a GitHub remote URL, in any spelling git takes for one: https or http, ssh (a port
# included, ssh.github.com:443 among them), git://, the scp like [user@]github.com:owner/name, with
# credentials in it, in any case of the host, with or without .git and trailing slashes.
# Exit 0 printing owner/name; 1, printing nothing, for a URL on another host (plainly off GitHub);
# 2, printing nothing, for one on github.com that names no owner/name to read. A caller must treat 2
# as a repository it cannot establish, never as off GitHub (claude-config#1723: an unparsed GitHub
# URL read as empty passed a delete unjudged).
sp_github_slug() {   # $1 = a remote URL
  local u="$1" rest host path owner name
  case "$u" in
    *://*)
      rest="${u#*://}"
      host="${rest%%/*}"; path="${rest:${#host}}"
      host="${host##*@}"; host="${host%%:*}" ;;
    *:*)
      # scp like: git reads it so only when no slash comes before the first colon.
      host="${u%%:*}"
      case "$host" in */*) return 1 ;; esac
      path="${u#*:}"; host="${host##*@}" ;;
    *) return 1 ;;
  esac
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  case "$host" in github.com|www.github.com|ssh.github.com) ;; *) return 1 ;; esac
  path="${path%%[?#]*}"
  while [ "${path#/}" != "$path" ]; do path="${path#/}"; done
  while [ "${path%/}" != "$path" ]; do path="${path%/}"; done
  path="${path%.git}"
  while [ "${path%/}" != "$path" ]; do path="${path%/}"; done
  case "$path" in */*/*|*//*) return 2 ;; */*) ;; *) return 2 ;; esac
  owner="${path%%/*}"; name="${path#*/}"
  [ -n "$owner" ] && [ -n "$name" ] || return 2
  printf '%s/%s' "$owner" "$name"
}
