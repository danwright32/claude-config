#!/usr/bin/env bash
#
# check-stale-worktrees.sh: name the agent worktrees whose work has already landed
# (claude-config#423).
#
# Claude Code parks an isolated worktree under <repo>/.claude/worktrees/ when an agent asks for
# one, and nothing removes it when the work lands. Five were sitting in this repo on 2026-09-17,
# every one for a closed issue. Each is a full working tree, so every repo wide search returns each
# real hit once more per copy: the first grep of that session came back with 36 lines of which 31
# were duplicates from these. The cost is not disk, it is that searching the repo stops telling you
# the truth about the repo.
#
# IT REMOVES NOTHING, AND THAT IS THE DESIGN RATHER THAN AN OMISSION. A worktree is not scratch. It
# can be the workspace a live session is standing in, and two sessions routinely share one checkout
# here, so an automatic sweep would eventually delete somebody's open work with no way back (L5,
# L9, and the CLAUDE.md rule about never deleting a branch this session did not create). What can
# be automated safely is NOTICING, so this reports and prints the command, and a person runs it.
#
# HOW IT DECIDES THE WORK HAS LANDED. Not by ancestry: this repo squash merges, so no merged branch
# is ever an ancestor of main and every local way of asking reports every branch as unmerged
# (L642). It reads the issue number out of the branch name and asks whether that issue is closed.
# A branch carrying no number, or one whose issue is open, is left alone AND said to be left alone,
# because a worktree that could be in use is the one to keep, and a keep nobody can see reads the
# same as a worktree that was never looked at.
#
# ONE network call, not one per worktree: the closed issue numbers come back in a single list. A
# repo with no worktree directory costs nothing at all, which is every project but this one.
#
# Run:  bash ~/.claude/hooks/check-stale-worktrees.sh [repo-dir]
#
# Exit 0 = nothing to remove, including the case where there are no worktrees at all.
# Exit 1 = at least one worktree holds work that has landed. Each is named with its command.
# Exit 2 = it could not tell, so nothing is claimed either way: not a git repo, no gh, or the
#          closed issue list could not be read. Refusing rather than reporting a clean tree,
#          because reading nothing and finding nothing wrong are otherwise one answer (L98).
#
# Environment:
#   STALE_WT_GH     the gh to run, for a fixture that must not reach the network (L2)
#   STALE_WT_LIMIT  how many closed issues to ask for (default 400)

set -uo pipefail

REPO="${1:-$PWD}"
GH="${STALE_WT_GH:-gh}"
LIMIT="${STALE_WT_LIMIT:-400}"

top="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$top" ]; then
  echo "check-stale-worktrees: '$REPO' is not inside a git repository, so there is nothing to judge." >&2
  exit 2
fi

WTDIR="$top/.claude/worktrees"
# No directory is the ordinary case in every other project, and it is a real answer rather than a
# reason to refuse: there are no agent worktrees, so none of them is stale.
[ -d "$WTDIR" ] || exit 0

# The worktrees GIT knows about, narrowed to the ones under that directory. Read from git rather
# than from the filesystem, because a directory sitting there that git has forgotten is not a
# worktree and removing it is a different operation with a different command.
paths=(); branches=()
cur=""; curbranch=""
flush(){
  case "$cur" in "$WTDIR"/*) paths+=("$cur"); branches+=("$curbranch") ;; esac
  cur=""; curbranch=""
}
while IFS= read -r line; do
  case "$line" in
    "worktree "*) [ -n "$cur" ] && flush; cur="${line#worktree }" ;;
    "branch "*)   curbranch="${line#branch refs/heads/}" ;;
  esac
done < <(git -C "$top" worktree list --porcelain 2>/dev/null || true)
[ -n "$cur" ] && flush

[ "${#paths[@]}" -gt 0 ] || exit 0

issue_of(){ printf '%s' "$1" | grep -oE '[0-9]+' | awk 'NR==1'; }

# Every issue number these branches name, asked for ONCE. A branch with no number cannot be judged
# and is reported as such below rather than counted either way.
want=""
for b in "${branches[@]}"; do
  n="$(issue_of "$b" || true)"
  [ -n "$n" ] && want="$want $n"
done

closed=""
if [ -n "$want" ]; then
  command -v "$GH" >/dev/null 2>&1 || {
    echo "check-stale-worktrees: no gh on PATH, so whether these branches' issues are closed cannot be read. ${#paths[@]} worktree(s) left unjudged rather than called clean." >&2
    exit 2
  }
  closed="$("$GH" issue list --state closed --limit "$LIMIT" --json number --jq '.[].number' 2>/dev/null)" || {
    echo "check-stale-worktrees: could not read the closed issues, so ${#paths[@]} worktree(s) are left unjudged rather than called clean." >&2
    exit 2
  }
  # An EMPTY list is a legitimate answer, from a repo that has closed nothing, and is left as one.
fi

stale=0
for i in "${!paths[@]}"; do
  p="${paths[$i]}"; b="${branches[$i]}"
  # Uncommitted work settles it on its own: somebody may be part way through a change, and nothing
  # below is worth risking that (L5).
  dirty="$(git -C "$p" status --porcelain 2>/dev/null | grep -c . || true)"
  if [ "${dirty:-0}" -gt 0 ]; then
    echo "  keeping $(basename "$p") [$b]: it holds $dirty uncommitted change(s), so a session may be working in it"
    continue
  fi
  n="$(issue_of "$b" || true)"
  if [ -z "$n" ]; then
    echo "  keeping $(basename "$p") [$b]: its branch names no issue, so whether the work landed cannot be read from here"
    continue
  fi
  if ! printf '%s\n' "$closed" | grep -qx "$n"; then
    echo "  keeping $(basename "$p") [$b]: issue #$n is not closed"
    continue
  fi
  stale=$((stale + 1))
  echo "  STALE $(basename "$p") [$b]: issue #$n is closed and nothing is uncommitted"
  echo "    git -C $top worktree remove $p"
done

[ "$stale" -eq 0 ] && exit 0
echo "$stale of ${#paths[@]} agent worktree(s) hold work that has landed. Each is a full copy of the tree, so every repo wide search returns its hits once more per copy. The command to remove one is printed under it; nothing here removes anything, because a worktree can be the workspace a live session is standing in."
exit 1
