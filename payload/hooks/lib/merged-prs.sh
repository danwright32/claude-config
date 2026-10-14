# merged-prs.sh: whether a branch's work has landed, read from its merged pull request
# (claude-config#1198, #1199). Sourced, never run: by check-stale-worktrees.sh, which removes the
# agent worktrees whose work has landed, and by claude-sync, which stops telling a finished
# worktree to pull. One reading for both, so the tool that removes a worktree and the tool that
# calls it finished cannot disagree about which ones are finished (L261).
#
# WHY A MERGED PR AND NOT ANCESTRY. This repo squash merges, so no merged branch is ever an
# ancestor of main and every local way of asking reports every branch as unmerged (L642).
#
# WHY CONTAINMENT AND NOT EQUALITY. A worktree's HEAD is often an EARLIER commit than the one its
# PR merged at, because the PR was pushed to again from somewhere else (a fix from another session,
# a rebase). Measured on 2026-10-14: 28 of the 47 merged agent worktrees here were behind their
# PR's last commit, every one of them contained in it. So the question is whether every commit the
# worktree holds was in the PR, which is whether HEAD is the PR's last commit or an ancestor of it.

# merged_prs <gh> <limit> [gh args...]: one line per merged PR, newest first, as
# "<branch><TAB><last commit><TAB><number>". ONE call however many branches are asked about. A
# failure returns non-zero with nothing printed, so a caller can never read "could not ask" as
# "nothing merged" (L98).
merged_prs(){
  local gh="$1" limit="$2" out
  shift 2
  out="$("$gh" pr list --state merged --limit "$limit" "$@" --json headRefName,headRefOid,number \
    --jq '.[] | "\(.headRefName)\t\(.headRefOid)\t\(.number)"' 2>/dev/null)" || return 1
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# pr_landing <git dir> <branch> <head> <merged list>: prints "<verdict><TAB><PR number>", the
# number empty when there is no PR to name. The verdicts:
#   landed       a merged PR of this branch holds HEAD (its last commit, or an earlier one)
#   newer        a PR of this branch merged, but HEAD has commits no merged PR of it held
#   unconfirmed  a PR of this branch merged, at a commit this repository does not have, so
#                whether it holds HEAD cannot be read here
#   unmerged     no merged PR has this branch, among the ones listed
# A branch name can be reused by a later PR, so every merged PR of the branch is tried.
pr_landing(){
  local dir="$1" branch="$2" head="$3" list="$4" b oid n verdict="unmerged" num=""
  [ -n "$branch" ] && [ -n "$head" ] || { printf 'unmerged\t\n'; return 0; }
  while IFS=$'\t' read -r b oid n; do
    [ "$b" = "$branch" ] || continue
    if [ "$oid" = "$head" ] || { git -C "$dir" cat-file -e "${oid}^{commit}" 2>/dev/null \
        && git -C "$dir" merge-base --is-ancestor "$head" "$oid" 2>/dev/null; }; then
      printf 'landed\t%s\n' "$n"; return 0
    fi
    if git -C "$dir" cat-file -e "${oid}^{commit}" 2>/dev/null; then
      [ "$verdict" = "unmerged" ] && { verdict="newer"; num="$n"; }
    else
      [ "$verdict" = "unmerged" ] && { verdict="unconfirmed"; num="$n"; }
    fi
  done <<EOF
$list
EOF
  printf '%s\t%s\n' "$verdict" "$num"
}
