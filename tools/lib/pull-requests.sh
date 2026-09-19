# pull-requests.sh: GitHub's own record of the pull requests opened from a branch. Sourced, not run.
#
# One copy, shared by shipped-branches.sh and shipped-worktrees.sh, because both read a merged pull
# request as the proof that a branch shipped, and two readings of that proof drift apart with no
# symptom (L613). What each does with an unreadable answer differs and stays with the caller:
# shipped-worktrees.sh deletes things, so it refuses; shipped-branches.sh changes nothing, so it
# says so and falls back to its labelled guess. Neither may read unreadable as "none" (L98).
#
# pull_requests <repo> <branch>
#   <branch> is the branch's own name on the remote, like fix/thing, never origin/fix/thing.
#   On success prints one line per pull request from that branch, "<state> <number> <head oid>",
#   state being MERGED, OPEN or CLOSED, and prints nothing when there are none. Returns 0.
#   Returns 1 when the record cannot be read (gh or jq missing, gh failing, or an answer that is
#   not a list of pull requests), printing what went wrong instead of any pull request, so a caller
#   can never mistake an unreadable answer for an empty one.

pull_requests() {
  local repo="$1" branch="$2" answer err_file err
  command -v gh >/dev/null 2>&1 || { printf 'gh is not installed\n'; return 1; }
  command -v jq >/dev/null 2>&1 \
    || { printf 'jq is not installed, and it is needed to read what gh answers\n'; return 1; }
  err_file="$(mktemp "${TMPDIR:-/tmp}/pull-requests.err.XXXXXXXX")" \
    || { printf 'no scratch file to hold what gh says\n'; return 1; }
  # --head comes first in the call so a log of it is easy to read.
  if ! answer="$(cd "$repo" && gh pr list --head "$branch" --state all \
      --json number,state,headRefOid --limit 100 2>"$err_file")"; then
    err="$(cat "$err_file")"; rm -f "$err_file"
    printf '%s\n' "${err:-gh failed and said nothing}"
    return 1
  fi
  rm -f "$err_file"
  if ! jq -e 'type == "array" and all(.[]; type == "object" and has("state") and has("number"))' \
      >/dev/null 2>&1 <<< "$answer"; then
    printf 'an answer about %s that is not a list of pull requests: %s\n' "$branch" "${answer:0:200}"
    return 1
  fi
  jq -r '.[] | "\(.state) \(.number) \(.headRefOid // "")"' <<< "$answer"
}
