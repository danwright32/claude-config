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
#   5. It is not locked, or its lock was left by a Claude agent that is no longer running
#      (lib/agent-lock.sh, #1282). Claude Code locks a running agent's worktree and lifts the lock
#      when the agent finishes, so an agent that never finished (the Mac going down) left a lock
#      git refuses to remove past, and five landed worktrees were kept for ever on 2026-10-17. A
#      lock naming a pid no process has, or an agent that started before the last boot, is lifted
#      just before the removal; that covers the older form with no start time, "claude agent
#      <name> (pid <pid>)", whose pid nothing has. If git then refuses and leaves the worktree
#      whole, the lock is put back; if git stops part way and leaves it part deleted, the lock
#      stays off, so the next run can finish the removal. A live agent's lock, a pid now held by a
#      process whose start does not match the lock, an older lock whose pid is running, one whose
#      agent cannot be read, and any lock that is not a Claude agent's are left exactly as they
#      are. The same reading decides tools/shipped-worktrees.sh, so the two cleanups agree.
# Its BRANCH is never deleted, so every commit can be had back with `git worktree add`. What goes
# with the folder is only what git ignores (installed packages, a local settings file).
#
# A REMOVAL CUT OFF PART WAY IS FINISHED, NOT LEFT (L617). A `git worktree remove` killed part way
# leaves a part deleted folder that git still lists, and what is left reads as uncommitted
# DELETIONS, so every later run would keep it for ever as a worktree somebody is working in
# (measured 2026-10-16: killed 80ms in, 2412 of 3000 files left, 588 " D" lines and nothing else).
# So each removal writes a progress marker into the repository's git directory first and clears it
# after. A marker found by a later --remove run is a removal an earlier run decided on and never
# finished: it is finished when nothing but deletions is in the folder and nothing is running in
# it, and otherwise kept and said loudly, because a change since the cut is somebody's work. A
# removal git itself fails part way can leave a folder git no longer lists; that one is named on
# every run with the command that deletes it, and never deleted here.
#
# It is not run inside a prompt. The nudge starts it in the background, under no timeout and in a
# session of its own (lib/stale-worktree-run.py, #1247), because with 46 worktrees inspecting them
# took most of the nudge's five seconds and the whole run was killed, every session.
#
# A TIME BUDGET still bounds one run: no removal is STARTED past STALE_WT_BUDGET_SECS from the
# script's start, and the rest are named as left for the next run. It no longer guards a timeout;
# it bounds how long one run holds the lock that keeps the next one waiting. One removal measured
# at 0.13 to 0.18 seconds on 2026-10-14, so the default leaves room for hundreds.
#
# ONE network call, not one per worktree: the merged PRs come back in a single list. A repo with
# no worktree directory costs nothing at all, which is every project but this one.
#
# Run:  bash ~/.claude/hooks/check-stale-worktrees.sh [--remove] [repo-dir]
#
# Exit 0 = no worktree here holds work that has landed, including when there are none at all, and
#          no removal was left part way.
# Exit 1 = at least one does, or a removal an earlier run started was left part way: each is named,
#          with what was done about it (removed, finished, or the command and the reason it was
#          kept), so the caller has something to say.
# Exit 2 = it could not tell, so nothing is claimed and nothing removed: not a git repo, no gh, or
#          the merged PR list could not be read. Refusing rather than reporting a clean tree,
#          because reading nothing and finding nothing wrong are otherwise one answer (L98).
#
# Environment:
#   STALE_WT_GH              the gh to run, for a fixture that must not reach the network (L2)
#   STALE_WT_LIMIT           how many of the newest merged PRs to ask for (default 400); a worktree
#                            whose PR is older than these is kept, the harmless direction
#   STALE_WT_BUDGET_SECS     no removal starts later than this from the start (default 300)
#   STALE_WT_RECENT_MINUTES  a change this recent keeps a worktree (default 360)
#   AGENT_LOCK_PS            the ps that says whether a lock's agent is running (lib/agent-lock.sh)
#   AGENT_LOCK_BOOT_EPOCH    when this machine booted, in epoch seconds (lib/agent-lock.sh)

set -uo pipefail

REMOVE=0
if [ "${1:-}" = "--remove" ]; then REMOVE=1; shift; fi
REPO="${1:-$PWD}"
GH="${STALE_WT_GH:-gh}"
LIMIT="${STALE_WT_LIMIT:-400}"
BUDGET="${STALE_WT_BUDGET_SECS:-300}"
RECENT="${STALE_WT_RECENT_MINUTES:-360}"

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/merged-prs.sh" || {
  echo "check-stale-worktrees: lib/merged-prs.sh is missing, so whether any work landed cannot be read." >&2
  exit 2
}
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/agent-lock.sh" || {
  echo "check-stale-worktrees: lib/agent-lock.sh is missing, so whether a locked worktree's agent is still running cannot be read." >&2
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
# A lock is kept as the whole "locked ..." line, so the one read again just before an unlock can be
# compared with it exactly; a worktree with no lock has an empty one.
paths=(); branches=(); heads=(); locks=()
cur=""; curbranch=""; curhead=""; curlock=""
flush(){
  case "$cur" in "$WTDIR"/*) paths+=("$cur"); branches+=("$curbranch"); heads+=("$curhead"); locks+=("$curlock") ;; esac
  cur=""; curbranch=""; curhead=""; curlock=""
}
while IFS= read -r line; do
  case "$line" in
    "worktree "*) [ -n "$cur" ] && flush; cur="${line#worktree }" ;;
    "HEAD "*)     curhead="${line#HEAD }" ;;
    "branch "*)   curbranch="${line#branch refs/heads/}" ;;
    locked|"locked "*) curlock="$line" ;;
  esac
done < <(git -C "$top" worktree list --porcelain 2>/dev/null || true)
[ -n "$cur" ] && flush

# The progress markers, one file per removal in flight, named for the worktree and holding its
# path. In the git directory, so they are never part of anybody's working tree. Read BEFORE the
# answer "no worktrees, nothing to say", because a removal git failed part way can leave a folder
# git no longer lists, and when it is the last one there are no worktrees left to list at all.
common="$(cd "$top" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)"
MARKS="${common:-$top/.git}/claude-worktree-removing"
marked=0
for m in "$MARKS"/*; do [ -f "$m" ] && marked=1; done

[ "${#paths[@]}" -gt 0 ] || [ "$marked" -eq 1 ] || exit 0

# GitHub is asked only when there is a worktree to judge; a marker alone needs nothing from it.
merged=""
if [ "${#paths[@]}" -gt 0 ]; then
  command -v "$GH" >/dev/null 2>&1 || {
    echo "check-stale-worktrees: no gh on PATH, so whether these branches' PRs merged cannot be read. ${#paths[@]} worktree(s) left unjudged rather than called clean." >&2
    exit 2
  }
  merged="$(cd "$top" && merged_prs "$GH" "$LIMIT")" || {
    echo "check-stale-worktrees: could not read the merged pull requests, so ${#paths[@]} worktree(s) are left unjudged rather than called clean." >&2
    exit 2
  }
fi
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

# The lock git holds on one worktree now, as the whole "locked ..." line, or nothing.
# Read whole into a variable first: awk stopping at the first match would cut git off mid write,
# and under pipefail that fails the read.
lock_now(){
  local all; all="$(git -C "$top" worktree list --porcelain 2>/dev/null)"
  printf '%s\n' "$all" | awk -v p="worktree $1" '
    $0 == p { f = 1; next } /^worktree / { f = 0 } f && /^locked/ && !done { print; done = 1 }'
}

# Put back a lock this run lifted for a removal that then did not happen, so the worktree is left
# as it was found. Reads the loop's own $stale_lock, $reason and $p.
relock(){
  [ -n "$stale_lock" ] || return 0
  if git -C "$top" worktree lock --reason "$reason" "$p" >/dev/null 2>&1; then
    echo "    its lock is put back as it was found"
  else
    echo "    and its lock, lifted for the removal, could not be put back"
  fi
}

landed=0; removed=0; left=0; cut=0
settled=" "   # the worktrees a cut off removal already accounts for, so the loop below skips them
for m in "$MARKS"/*; do
  [ -f "$m" ] || continue
  p="$(head -n 1 "$m" 2>/dev/null)"; name="$(basename "$p")"; b=""; listed=0
  for i in "${!paths[@]}"; do [ "${paths[$i]}" = "$p" ] && { listed=1; b="${branches[$i]}"; }; done
  # Git no longer lists it and the folder is gone, so that removal finished after all and only the
  # marker was left.
  if [ "$listed" -eq 0 ] && [ ! -e "$p" ]; then rm -f "$m"; continue; fi
  # Git no longer lists it but the folder is still there: a removal that failed part way after git
  # had dropped its registration. It is a plain folder now, which this script does not delete (a
  # different operation, with nothing left to check it against), so it is named every run until a
  # person deletes it, and the marker is cleared on the run that finds it gone.
  if [ "$listed" -eq 0 ]; then
    cut=$((cut + 1))
    echo "  keeping $name: an earlier removal of it stopped part way after git had already let go of it, so what is left is a plain folder no worktree owns. Delete it by hand once nothing in it is wanted: rm -rf $p"
    continue
  fi
  cut=$((cut + 1)); settled="$settled$p "
  if [ "$REMOVE" -eq 0 ]; then
    echo "  CUT OFF $name [${b:-no branch}]: an earlier removal of it stopped part way"
    echo "    git -C $top worktree remove --force $p"
    continue
  fi
  # Anything in it but a deletion of a committed file is a change since the cut, which is somebody's.
  others="$(git -C "$p" status --porcelain 2>/dev/null | grep -v '^ D ' | grep -c . || true)"
  real="$(cd "$p" 2>/dev/null && pwd -P)" || real="$p"
  if [ "${others:-0}" -gt 0 ] || { [ -d "$p" ] && in_use "$real"; }; then
    echo "  keeping $name [${b:-no branch}]: an earlier removal of it was cut off part way, and something in it has changed since or is running in it, so it is left for a person. Its marker is $m"
    continue
  fi
  # Only deletions, so everything still to go is in a commit on its branch. A folder already gone
  # takes the plain command, since --force refuses one that is not there.
  force="--force"; [ -d "$p" ] || force=""
  if err="$(git -C "$top" worktree remove $force "$p" 2>&1)"; then
    rm -f "$m"; removed=$((removed + 1))
    echo "  finished removing $name [${b:-no branch}]: an earlier run started removing it and was cut off part way (its branch is kept)"
  else
    echo "  keeping $name [${b:-no branch}]: an earlier removal of it was cut off part way, and git would not finish it: $(printf '%s' "$err" | tr '\n' ' ')"
  fi
done

for i in "${!paths[@]}"; do
  p="${paths[$i]}"; b="${branches[$i]}"; h="${heads[$i]}"; name="$(basename "$p")"
  case "$settled" in *" $p "*) continue ;; esac
  # Whether its work landed is asked FIRST, because it costs nothing beyond the one list already
  # read, and a worktree whose PR has not landed is kept whatever else is true of it. Every check
  # after this walks the folder, so only a worktree that could be removed pays for one (#1247).
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
  # A lock is judged next, before anything walks the folder. Only a lock a Claude agent left behind
  # lets the worktree go on to the rules below; every other lock keeps it here, in report mode too,
  # so a worktree is never called stale when --remove would not take it.
  lock="${locks[$i]}"; reason="${lock#locked}"; reason="${reason# }"; stale_lock=""
  if [ -n "$lock" ]; then
    IFS=$'\t' read -r lv ldetail <<<"$(agent_lock_verdict "$reason")"
    case "$lv" in
      live) echo "  keeping $name [$b]: a Claude agent that is still running holds its lock ($ldetail)"; continue ;;
      unreadable) echo "  keeping $name [$b]: it is locked by a Claude agent, and whether that agent is still running could not be read ($ldetail), so the lock is left alone"; continue ;;
      reused) echo "  keeping $name [$b]: its lock names a pid now held by another process, which cannot prove its agent gone ($ldetail), so the lock is left alone"; continue ;;
      nostart) echo "  keeping $name [$b]: its lock names $ldetail, so the lock is left alone"; continue ;;
      dead|preboot) stale_lock="$ldetail" ;;
      *) echo "  keeping $name [$b]: git has it locked, and not by a Claude agent (${reason:-no reason given}), so the lock is left alone"; continue ;;
    esac
  fi
  # Uncommitted work settles it on its own: somebody may be part way through a change, and nothing
  # below is worth risking that (L5).
  dirty="$(git -C "$p" status --porcelain 2>/dev/null | grep -c . || true)"
  if [ "${dirty:-0}" -gt 0 ]; then
    echo "  keeping $name [$b]: it holds $dirty uncommitted change(s), so a session may be working in it"
    continue
  fi
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
    if [ -n "$stale_lock" ]; then
      echo "  STALE $name [$b]: PR #$num merged and nothing is uncommitted, and its lock was left by a Claude agent that is gone ($stale_lock)"
      echo "    git -C $top worktree unlock $p"
    else
      echo "  STALE $name [$b]: PR #$num merged and nothing is uncommitted"
    fi
    echo "    git -C $top worktree remove $p"
    continue
  fi
  if [ "$SECONDS" -ge "$BUDGET" ]; then
    left=$((left + 1))
    continue
  fi
  # A stale agent lock is lifted only now, the last moment before the removal, and only if it is
  # still the lock judged above: an agent that has taken the worktree since holds a lock of its own,
  # and that one is left alone.
  if [ -n "$stale_lock" ]; then
    if [ "$(lock_now "$p")" != "$lock" ]; then
      echo "  keeping $name [$b]: its lock changed while this run was looking at it, so whoever holds it now is left alone"
      continue
    fi
    if ! err="$(git -C "$top" worktree unlock "$p" 2>&1)"; then
      echo "  keeping $name [$b]: its lock was left by a Claude agent that is gone ($stale_lock), and git would not lift it: $(printf '%s' "$err" | tr '\n' ' ')"
      continue
    fi
  fi
  # The marker goes down BEFORE git starts deleting. A removal that cannot leave one is not started,
  # since one cut off without it would read as somebody's work for ever.
  if ! { mkdir -p "$MARKS" && printf '%s\n' "$p" >"$MARKS/$name"; } 2>/dev/null; then
    echo "  keeping $name [$b]: its progress marker could not be written in $MARKS, so a removal cut off part way could not be finished later"
    relock
    continue
  fi
  # No --force: git refuses a worktree with anything untracked or modified, so a change made since
  # the check above is a refusal, never a loss.
  if err="$(git -C "$top" worktree remove "$p" 2>&1)"; then
    removed=$((removed + 1))
    if [ -n "$stale_lock" ]; then
      echo "  removed $name [$b]: PR #$num merged and nothing in it was newer, and its lock was left by a Claude agent that is gone ($stale_lock). Its branch is kept"
    else
      echo "  removed $name [$b]: PR #$num merged and nothing in it was newer (its branch is kept)"
    fi
    rm -f "$MARKS/$name"
  else
    echo "  keeping $name [$b]: git would not remove it: $(printf '%s' "$err" | tr '\n' ' ')"
    # A refusal before anything is deleted (a lock, a change made since the check above) leaves the
    # worktree listed, whole and as it was, so there is nothing to finish. A failure PART WAY does
    # not: measured 2026-10-16 with one unwritable folder, git deleted the worktree's own files and
    # its registration and then stopped. The marker stays for anything but the first, so a later
    # run can say what is left.
    still="$(git -C "$top" worktree list --porcelain 2>/dev/null)"
    case $'\n'"$still"$'\n' in
      *$'\n'"worktree $p"$'\n'*)
        # A lifted lock goes back only on a worktree left whole. One left part deleted keeps its
        # marker for the finisher above, whose single --force git refuses on a locked worktree, so
        # putting a dead agent's lock back there would keep it part deleted for ever.
        if [ -d "$p" ] && [ -z "$(git -C "$p" status --porcelain 2>/dev/null | grep '^ D ')" ]; then
          rm -f "$MARKS/$name"
          relock
        elif [ -n "$stale_lock" ]; then
          echo "    its lock, left by a Claude agent that is gone, is not put back, so the next run can finish the removal"
        fi ;;
    esac
  fi
done

[ "$landed" -eq 0 ] && [ "$cut" -eq 0 ] && exit 0
if [ "$REMOVE" -eq 0 ]; then
  [ "$cut" -gt 0 ] && echo "$cut agent worktree(s) were left part deleted by a removal that stopped part way. The command that finishes one is printed under it."
  [ "$landed" -gt 0 ] && echo "$landed of ${#paths[@]} agent worktree(s) hold work that has landed. Each is a full copy of the tree, so every repo wide search returns its hits once more per copy. The command to remove one is printed under it."
else
  echo "removed $removed of ${#paths[@]} agent worktree(s), each one whose PR had merged with nothing newer in it; every one kept is named above with why."
  [ "$left" -gt 0 ] && echo "$left landed worktree(s) left for the next run, which stops starting removals ${BUDGET}s in."
fi
exit 1
