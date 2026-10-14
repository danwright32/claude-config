#!/usr/bin/env bash
#
# check-stale-worktrees.sh: name, and with --remove remove, the agent worktrees whose work has
# already landed (claude-config#423, #1199).
#
# Claude Code parks an isolated worktree under <repo>/.claude/worktrees/ when an agent asks for
# one, and only removes one that has no changes, so every agent that commits leaves one behind. On
# 2026-10-14 this repo held 50, 47 of them for merged PRs, about 2 GB. Each is a full working
# tree, so every repo wide search returns each real hit once more per copy.
#
# REMOVING IS DAN'S DECISION, MADE ON 2026-10-14 (#1199). This began as report only (#423), on the
# reasoning that a worktree can be the workspace a live session is standing in. That reasoning
# still sets the rules: --remove takes a worktree only when every one of these holds, and says
# which one kept each of the others.
#   1. Its branch's PR merged holding every commit the worktree has (lib/merged-prs.sh: HEAD is
#      the PR's last commit or an ancestor of it). A commit after the merge is work nobody shipped.
#   2. Nothing is uncommitted, untracked files included (L5).
#   3. Nothing in it changed in the last STALE_WT_RECENT_MINUTES (six hours). A session's shell
#      does not stay in the folder between commands, so a running process is not enough to see a
#      session at work; a recent change is.
#   4. No running process has it as its working directory.
# Its BRANCH is never deleted, so every commit can be had back with `git worktree add`. What goes
# with the folder is only what git ignores (installed packages, a local settings file).
#
# A TIME BUDGET, because the nudge that runs this has five seconds and a removal killed part way
# leaves a half deleted folder (L617). No removal is STARTED past STALE_WT_BUDGET_SECS from the
# script's start; the rest are named as left for the next run. One removal measured at 0.13 to
# 0.18 seconds on 2026-10-14, so one in flight at the budget ends well inside the timeout.
#
# ONE network call, not one per worktree: the merged PRs come back in a single list. A repo with
# no worktree directory costs nothing at all, which is every project but this one.
#
# Run:  bash ~/.claude/hooks/check-stale-worktrees.sh [--remove] [repo-dir]
#
# Exit 0 = no worktree here holds work that has landed, including when there are none at all.
# Exit 1 = at least one does: each is named, with what was done about it (removed, or the command
#          and the reason it was kept), so the caller has something to say.
# Exit 2 = it could not tell, so nothing is claimed and nothing removed: not a git repo, no gh, or
#          the merged PR list could not be read. Refusing rather than reporting a clean tree,
#          because reading nothing and finding nothing wrong are otherwise one answer (L98).
#
# Environment:
#   STALE_WT_GH              the gh to run, for a fixture that must not reach the network (L2)
#   STALE_WT_LIMIT           how many of the newest merged PRs to ask for (default 400); a worktree
#                            whose PR is older than these is kept, the harmless direction
#   STALE_WT_BUDGET_SECS     no removal starts later than this from the start (default 3)
#   STALE_WT_RECENT_MINUTES  a change this recent keeps a worktree (default 360)

set -uo pipefail

REMOVE=0
if [ "${1:-}" = "--remove" ]; then REMOVE=1; shift; fi
REPO="${1:-$PWD}"
GH="${STALE_WT_GH:-gh}"
LIMIT="${STALE_WT_LIMIT:-400}"
BUDGET="${STALE_WT_BUDGET_SECS:-3}"
RECENT="${STALE_WT_RECENT_MINUTES:-360}"

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/merged-prs.sh" || {
  echo "check-stale-worktrees: lib/merged-prs.sh is missing, so whether any work landed cannot be read." >&2
  exit 2
}

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
paths=(); branches=(); heads=()
cur=""; curbranch=""; curhead=""
flush(){
  case "$cur" in "$WTDIR"/*) paths+=("$cur"); branches+=("$curbranch"); heads+=("$curhead") ;; esac
  cur=""; curbranch=""; curhead=""
}
while IFS= read -r line; do
  case "$line" in
    "worktree "*) [ -n "$cur" ] && flush; cur="${line#worktree }" ;;
    "HEAD "*)     curhead="${line#HEAD }" ;;
    "branch "*)   curbranch="${line#branch refs/heads/}" ;;
  esac
done < <(git -C "$top" worktree list --porcelain 2>/dev/null || true)
[ -n "$cur" ] && flush

[ "${#paths[@]}" -gt 0 ] || exit 0

command -v "$GH" >/dev/null 2>&1 || {
  echo "check-stale-worktrees: no gh on PATH, so whether these branches' PRs merged cannot be read. ${#paths[@]} worktree(s) left unjudged rather than called clean." >&2
  exit 2
}
merged="$(cd "$top" && merged_prs "$GH" "$LIMIT")" || {
  echo "check-stale-worktrees: could not read the merged pull requests, so ${#paths[@]} worktree(s) are left unjudged rather than called clean." >&2
  exit 2
}
# An EMPTY list is a legitimate answer, from a repo that has merged nothing, and is left as one.

# The working directories of every running process, read once. Without lsof or /proc nothing can
# be seen, and that is said and treated as in use, never as idle (L11).
# Read in report mode too, so a worktree is only ever called stale when --remove would take it.
cwds=""; can_see_use=1
if command -v lsof >/dev/null 2>&1; then
  cwds="$(lsof -a -d cwd -F n 2>/dev/null | sed -n 's/^n//p')"
elif [ -d /proc/self/cwd ] || [ -L /proc/self/cwd ]; then
  cwds="$(for c in /proc/[0-9]*/cwd; do readlink "$c" 2>/dev/null; done)"
else
  can_see_use=0
fi
in_use(){   # $1 = a worktree's resolved path
  [ "$can_see_use" -eq 1 ] || return 0
  [ -n "$cwds" ] || return 1
  printf '%s\n' "$cwds" | awk -v p="$1" '$0 == p || index($0, p "/") == 1 { found = 1 } END { exit !found }'
}

landed=0; removed=0; left=0
for i in "${!paths[@]}"; do
  p="${paths[$i]}"; b="${branches[$i]}"; h="${heads[$i]}"; name="$(basename "$p")"
  # Uncommitted work settles it on its own: somebody may be part way through a change, and nothing
  # below is worth risking that (L5).
  dirty="$(git -C "$p" status --porcelain 2>/dev/null | grep -c . || true)"
  if [ "${dirty:-0}" -gt 0 ]; then
    echo "  keeping $name [${b:-no branch}]: it holds $dirty uncommitted change(s), so a session may be working in it"
    continue
  fi
  if [ -z "$b" ]; then
    echo "  keeping $name [no branch]: it is not on a branch, so no PR can say whether its work landed"
    continue
  fi
  IFS=$'\t' read -r verdict num <<<"$(pr_landing "$top" "$b" "$h" "$merged")"
  case "$verdict" in
    landed) : ;;
    newer) echo "  keeping $name [$b]: it has commits PR #$num never held, so not all of its work has landed"; continue ;;
    unconfirmed) echo "  keeping $name [$b]: PR #$num merged at a commit this repository does not have, so whether it holds this worktree's commits cannot be read here"; continue ;;
    *) echo "  keeping $name [$b]: no merged PR has this branch"; continue ;;
  esac
  real="$(cd "$p" 2>/dev/null && pwd -P)" || real="$p"
  if [ -n "$(find "$p" -mmin "-$RECENT" -not -name .git -print -quit 2>/dev/null)" ]; then
    echo "  keeping $name [$b]: something in it changed in the last $RECENT minutes, so a session may still be using it"
    continue
  fi
  if in_use "$real"; then
    if [ "$can_see_use" -eq 1 ]; then
      echo "  keeping $name [$b]: a running process is working in it"
    else
      echo "  keeping $name [$b]: neither lsof nor /proc is here, so whether anything is running in it cannot be seen"
    fi
    continue
  fi
  landed=$((landed + 1))
  if [ "$REMOVE" -eq 0 ]; then
    echo "  STALE $name [$b]: PR #$num merged and nothing is uncommitted"
    echo "    git -C $top worktree remove $p"
    continue
  fi
  if [ "$SECONDS" -ge "$BUDGET" ]; then
    left=$((left + 1))
    continue
  fi
  # No --force: git refuses a worktree with anything untracked or modified, so a change made since
  # the check above is a refusal, never a loss.
  if err="$(git -C "$top" worktree remove "$p" 2>&1)"; then
    removed=$((removed + 1))
    echo "  removed $name [$b]: PR #$num merged and nothing in it was newer (its branch is kept)"
  else
    echo "  keeping $name [$b]: git would not remove it: $(printf '%s' "$err" | tr '\n' ' ')"
  fi
done

[ "$landed" -eq 0 ] && exit 0
if [ "$REMOVE" -eq 0 ]; then
  echo "$landed of ${#paths[@]} agent worktree(s) hold work that has landed. Each is a full copy of the tree, so every repo wide search returns its hits once more per copy. The command to remove one is printed under it."
else
  echo "removed $removed of ${#paths[@]} agent worktree(s), each one whose PR had merged with nothing newer in it; every one kept is named above with why."
  [ "$left" -gt 0 ] && echo "$left landed worktree(s) left for the next run, which stops starting removals ${BUDGET}s in."
fi
exit 1
