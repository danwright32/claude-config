#!/usr/bin/env bash
#
# check-stale-worktrees.sh: name, and with --remove remove, the worktrees whose work has already
# landed (claude-config#423, #1199, #2309).
#
# EVERY WORKTREE GIT LISTS IS JUDGED, wherever its folder is, except the main checkout (the first
# one git lists), which is never judged (#2309). Until 2026-11-05 only folders under
# .claude/worktrees were, and only by a merged PR: one work repository held 84 worktrees, 71 safe
# to remove, and the sweep reached few, because they sat in sibling folders, under a session's
# scratchpad, or were detached, and work shipped inside a combined batch branch passed no rule.
# A worktree under .claude/worktrees is named by its folder; any other by its whole path.
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
#   1. Its work is held somewhere other than this folder. Asked in this order, cheapest first:
#      its branch's PR merged holding every commit the worktree has (lib/merged-prs.sh: HEAD is
#      the PR's last commit or an ancestor of it); else every commit on its branch is also on
#      another branch, local or remote, main among them (which covers a squash of the branch
#      carried by a batch, a merge with no PR, and work pushed but never opened as a PR); or, on
#      no branch, its HEAD is on the default branch (lib/default-branch.sh). Under --just-merged
#      only the merged PR counts, since with rule 3 off a fresh branch off main would qualify.
#   2. Nothing is uncommitted, untracked files included (L5), and git could read its folder and
#      its status: a folder that cannot be read or a status git cannot give keeps it, since a
#      failed read and a clean tree are otherwise one answer.
#   3. Nothing in it changed in the last STALE_WT_RECENT_MINUTES (six hours). A session's shell
#      does not stay in the folder between commands, so a running process is not enough to see a
#      session at work; a recent change is. Off under --just-merged (below).
#      A find that could not read every file in it, and saw nothing recent, keeps it too.
#   4. No running process has it as its working directory. An lsof (or /proc) that lists no
#      process at all has failed, since this run's own shell has a working directory, so it keeps
#      every worktree rather than reading as nothing running anywhere.
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
# --just-merged <worktree> JUDGES THAT ONE WORKTREE, with rule 3 off (claude-config#1521). It is how
# lib/merge-when-ready.sh removes the merged branch's agent worktree the moment the merge lands, so
# the rules stay here and are never copied there (L370). Recency is the one rule a worktree merged a
# moment ago can never pass, and what it stands for is covered at that moment by the others: a
# running Claude agent holds its worktree's lock (rule 5), a process in it is seen (rule 4), and the
# caller never names the folder it was run from. Every other worktree and every other marker is left
# to the sweep, and a path that is not an agent worktree git lists is refused with exit 2.
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
# ONE network call, not one per worktree: the merged PRs come back in a single list. A repo where
# git lists no worktree but the main checkout costs nothing at all.
#
# Run:  bash ~/.claude/hooks/check-stale-worktrees.sh [--remove] [--just-merged <worktree>] [repo-dir]
#
# Exit 0 = no worktree here holds work that has landed, including when there are none at all, and
#          no removal was left part way.
# Exit 1 = at least one does, or a removal an earlier run started was left part way: each is named,
#          with what was done about it (removed, finished, or the command and the reason it was
#          kept), so the caller has something to say.
# Exit 2 = it could not tell, so nothing is claimed and nothing removed: not a git repo, no gh, or
#          the merged PR list could not be read, or --just-merged named no agent worktree git lists.
#          Refusing rather than reporting a clean tree,
#          because reading nothing and finding nothing wrong are otherwise one answer (L98).
#
# Environment:
#   STALE_WT_GH              the gh to run, for a fixture that must not reach the network (L2)
#   STALE_WT_LIMIT           how many of the newest merged PRs to ask for (default 400); a worktree
#                            whose PR is older than these is kept, the harmless direction
#   STALE_WT_BUDGET_SECS     no removal starts later than this from the start (default 300)
#   STALE_WT_RECENT_MINUTES  a change this recent keeps a worktree (default 360)
#   STALE_WT_LSOF            the lsof to run, for a fixture that must see it fail (default lsof)
#   AGENT_LOCK_PS            the ps that says whether a lock's agent is running (lib/agent-lock.sh)
#   AGENT_LOCK_BOOT_EPOCH    when this machine booted, in epoch seconds (lib/agent-lock.sh)

set -uo pipefail

REMOVE=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --remove) REMOVE=1; shift ;;
    --just-merged)
      [ -n "${2:-}" ] || { echo "check-stale-worktrees: --just-merged names the one worktree to judge, and none was named." >&2; exit 2; }
      ONLY="$2"; shift 2 ;;
    *) break ;;
  esac
done
REPO="${1:-$PWD}"
GH="${STALE_WT_GH:-gh}"
LIMIT="${STALE_WT_LIMIT:-400}"
BUDGET="${STALE_WT_BUDGET_SECS:-300}"
RECENT="${STALE_WT_RECENT_MINUTES:-360}"
LSOF="${STALE_WT_LSOF:-lsof}"

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) _HD="${BASH_SOURCE[0]%/*}" ;; *) _HD=. ;; esac
_HD="$(cd "${_HD:-/}" && pwd)"
. "$_HD/lib/merged-prs.sh" || {
  echo "check-stale-worktrees: lib/merged-prs.sh is missing, so whether any work landed cannot be read." >&2
  exit 2
}
. "$_HD/lib/agent-lock.sh" || {
  echo "check-stale-worktrees: lib/agent-lock.sh is missing, so whether a locked worktree's agent is still running cannot be read." >&2
  exit 2
}
. "$_HD/lib/default-branch.sh" || {
  echo "check-stale-worktrees: lib/default-branch.sh is missing, so whether a detached worktree's HEAD is on the default branch cannot be read." >&2
  exit 2
}

top="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$top" ]; then
  echo "check-stale-worktrees: '$REPO' is not inside a git repository, so there is nothing to judge." >&2
  exit 2
fi

WTDIR="$top/.claude/worktrees"
# --just-merged names one worktree, as git lists it or as any path that resolves to it. Anything
# else is not judged at all rather than reported clean (L98).
ONLY_REAL=""
[ -z "$ONLY" ] || ONLY_REAL="$(cd "$ONLY" 2>/dev/null && pwd -P)"
named(){ [ -z "$ONLY" ] || [ "$1" = "$ONLY" ] || { [ -n "$ONLY_REAL" ] && [ "$1" = "$ONLY_REAL" ]; }; }
not_listed(){
  echo "check-stale-worktrees: $ONLY is not an agent worktree git lists under $WTDIR, so there is nothing to judge." >&2
  exit 2
}
# --just-merged judges only an agent worktree, so with no agent worktree directory there is nothing
# it could name. The sweep goes on, since its worktrees can live anywhere.
[ -d "$WTDIR" ] || [ -z "$ONLY" ] || not_listed

# A worktree's name in the report: its folder under the agent worktree directory, its whole path
# anywhere else, since folders elsewhere repeat (every scratchpad worktree is called "wt").
label(){ case "$1" in "$WTDIR"/*) basename "$1" ;; *) printf '%s\n' "$1" ;; esac; }
# Its progress marker's file name: the folder name under the agent worktree directory, which the
# markers already written use, and the folder name plus a checksum of the path anywhere else.
markname(){
  case "$1" in
    "$WTDIR"/*) basename "$1" ;;
    *) printf '%s-%s\n' "$(basename "$1")" "$(printf '%s' "$1" | cksum | awk '{ print $1 }')" ;;
  esac
}

# The worktrees GIT knows about. Read from git rather than from the filesystem, because a directory
# sitting there that git has forgotten is not a worktree and removing it is a different operation
# with a different command. The FIRST one git lists is the main checkout, which is never judged
# ($top can be a linked worktree, so it is not the test), and neither is a bare repository's own
# entry. --just-merged narrows them to the agent worktree directory, as it always has.
# A lock is kept as the whole "locked ..." line, so the one read again just before an unlock can be
# compared with it exactly; a worktree with no lock has an empty one.
paths=(); branches=(); heads=(); locks=()
cur=""; curbranch=""; curhead=""; curlock=""; curbare=0; mainwt=""
flush(){
  if [ -z "$mainwt" ]; then
    mainwt="$cur"
  elif [ "$curbare" -eq 0 ] && named "$cur"; then
    local take=1
    [ -z "$ONLY" ] || case "$cur" in "$WTDIR"/*) ;; *) take=0 ;; esac
    [ "$take" -eq 0 ] || { paths+=("$cur"); branches+=("$curbranch"); heads+=("$curhead"); locks+=("$curlock"); }
  fi
  cur=""; curbranch=""; curhead=""; curlock=""; curbare=0
}
loop_input="$(git -C "$top" worktree list --porcelain 2>/dev/null)" || {
  echo "check-stale-worktrees: git could not list this repository's worktrees, so none is judged rather than all called clean." >&2
  exit 2
}
while IFS= read -r line; do
  case "$line" in
    "worktree "*) [ -n "$cur" ] && flush; cur="${line#worktree }" ;;
    "HEAD "*)     curhead="${line#HEAD }" ;;
    "branch "*)   curbranch="${line#branch refs/heads/}" ;;
    locked|"locked "*) curlock="$line" ;;
    bare)         curbare=1 ;;
  esac
done <<LOOP_INPUT
$loop_input
LOOP_INPUT
[ -n "$cur" ] && flush

# The progress markers, one file per removal in flight, named for the worktree and holding its
# path. In the git directory, so they are never part of anybody's working tree. Read BEFORE the
# answer "no worktrees, nothing to say", because a removal git failed part way can leave a folder
# git no longer lists, and when it is the last one there are no worktrees left to list at all.
common="$(cd "$top" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)"
MARKS="${common:-$top/.git}/claude-worktree-removing"
marked=0
# With --just-merged only the named worktree's own marker counts: the rest are the sweep's.
for m in "$MARKS"/*; do [ -f "$m" ] && named "$(head -n 1 "$m" 2>/dev/null)" && marked=1; done

if [ "${#paths[@]}" -eq 0 ] && [ "$marked" -eq 0 ]; then
  [ -z "$ONLY" ] || not_listed
  exit 0
fi

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
# Every process has a working directory, this run's own shell among them, so a reading that lists
# none has failed rather than found nothing running, and is treated as unable to see (#2309).
cwds=""; can_see_use=1; blind_why=""
if command -v "$LSOF" >/dev/null 2>&1; then
  cwds="$("$LSOF" -a -d cwd -F n 2>/dev/null | sed -n 's/^n//p')"
  [ -n "$cwds" ] || { can_see_use=0; blind_why="lsof listed no running process at all"; }
elif [ -d /proc/self/cwd ] || [ -L /proc/self/cwd ]; then
  cwds="$(for c in /proc/[0-9]*/cwd; do readlink "$c" 2>/dev/null; done)"
  [ -n "$cwds" ] || { can_see_use=0; blind_why="/proc listed no running process at all"; }
else
  can_see_use=0; blind_why="neither lsof nor /proc is here"
fi
in_use(){   # $1 = a worktree's resolved path
  [ "$can_see_use" -eq 1 ] || return 0
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

# The default branch, read once from the main checkout, for judging detached worktrees. Not needed
# by --just-merged, which never qualifies a worktree on no branch.
def=""; def_ok=1
if [ -z "$ONLY" ] && [ -n "$mainwt" ]; then def="$(default_branch "$mainwt")"; def_ok=$?; fi

landed=0; removed=0; left=0; cut=0
settled=" "   # the worktrees a cut off removal already accounts for, so the loop below skips them
for m in "$MARKS"/*; do
  [ -f "$m" ] || continue
  p="$(head -n 1 "$m" 2>/dev/null)"; name="$(label "$p")"; b=""; listed=0
  named "$p" || continue
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
    # The finisher's --force is the one place it is used, and only here, on a removal this script
    # itself started and recorded in a marker.
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
  p="${paths[$i]}"; b="${branches[$i]}"; h="${heads[$i]}"; name="$(label "$p")"; bl="${b:-no branch}"
  case "$settled" in *" $p "*) continue ;; esac
  # Whether its work landed is asked FIRST, because it costs only local git and the one list already
  # read, and a worktree whose work has not landed is kept whatever else is true of it. Every check
  # after this walks the folder, so only a worktree that could be removed pays for one (#1247).
  # stale_why and gone_why are what the STALE and removed lines say qualified it.
  if [ -z "$b" ]; then
    if [ -n "$ONLY" ]; then
      echo "  keeping $name [no branch]: it is not on a branch, so no PR can say whether its work landed"
      continue
    fi
    # Detached: its HEAD is the only commit it can hold that no branch names, so it qualifies when
    # the default branch, remote or local, already has that commit.
    if [ "$def_ok" -ne 0 ]; then
      echo "  keeping $name [no branch]: which branch is the default could not be read, so nothing can say its HEAD is kept anywhere else"
      continue
    fi
    on=""
    for ref in "$def" "refs/heads/${def#origin/}"; do
      git -C "$top" rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || continue
      git -C "$top" merge-base --is-ancestor "$h" "$ref" 2>/dev/null; rc=$?
      if [ "$rc" -eq 0 ]; then on="${ref#refs/heads/}"; break; fi
      [ "$rc" -eq 1 ] || { on="?"; break; }
    done
    case "$on" in
      "?") echo "  keeping $name [no branch]: git could not say whether its HEAD is on $def"; continue ;;
      "") echo "  keeping $name [no branch]: its HEAD is not on $def, so a commit made in it may be kept nowhere else"; continue ;;
    esac
    stale_why="its HEAD is on $on, and nothing is uncommitted"; gone_why="its HEAD is on $on"; kept_note="no branch was touched"
  else
    IFS=$'\t' read -r verdict num <<<"$(pr_landing "$top" "$b" "$h" "$merged")"
    case "$verdict" in
      landed) why="" ;;
      newer) why="it has commits PR #$num never held, so not all of its work has landed" ;;
      unconfirmed) why="PR #$num merged at a commit this repository does not have, so whether it holds this worktree's commits cannot be read here" ;;
      *) why="no merged PR has this branch" ;;
    esac
    if [ -z "$why" ]; then
      stale_why="PR #$num merged and nothing is uncommitted"; gone_why="PR #$num merged and nothing in it was newer"
    elif [ -n "$ONLY" ]; then
      # --just-merged qualifies by its merged PR alone: with rule 3 off, a branch made off main a
      # moment ago has every commit on main too, and would otherwise qualify.
      echo "  keeping $name [$b]: $why"
      continue
    else
      # Every commit its HEAD reaches that no OTHER branch, local or remote, also reaches. Branch
      # names cannot hold glob characters, so --exclude names exactly its own.
      n="$(git -C "$top" rev-list --count "$h" --not --exclude="$b" --branches --remotes 2>/dev/null)" || n=""
      case "$n" in
        0) : ;;
        ""|*[!0-9]*) echo "  keeping $name [$b]: $why, and git could not say whether its commits are on any other branch"; continue ;;
        *) echo "  keeping $name [$b]: $why, and $n commit(s) on it are on no other branch, local or remote"; continue ;;
      esac
      stale_why="every commit on it is also on another branch, local or remote, and nothing is uncommitted"
      gone_why="every commit on it is also on another branch, local or remote"
    fi
    kept_note="its branch is kept"
  fi
  # A lock is judged next, before anything walks the folder. Only a lock a Claude agent left behind
  # lets the worktree go on to the rules below; every other lock keeps it here, in report mode too,
  # so a worktree is never called stale when --remove would not take it.
  lock="${locks[$i]}"; reason="${lock#locked}"; reason="${reason# }"; stale_lock=""
  if [ -n "$lock" ]; then
    IFS=$'\t' read -r lv ldetail <<<"$(agent_lock_verdict "$reason")"
    case "$lv" in
      live) echo "  keeping $name [$bl]: a Claude agent that is still running holds its lock ($ldetail)"; continue ;;
      unreadable) echo "  keeping $name [$bl]: it is locked by a Claude agent, and whether that agent is still running could not be read ($ldetail), so the lock is left alone"; continue ;;
      reused) echo "  keeping $name [$bl]: its lock names a pid now held by another process, which cannot prove its agent gone ($ldetail), so the lock is left alone"; continue ;;
      nostart) echo "  keeping $name [$bl]: its lock names $ldetail, so the lock is left alone"; continue ;;
      dead|preboot) stale_lock="$ldetail" ;;
      *) echo "  keeping $name [$bl]: git has it locked, and not by a Claude agent (${reason:-no reason given}), so the lock is left alone"; continue ;;
    esac
  fi
  # Every rule below reads the folder, so one that cannot be read keeps it: a status that fails
  # would otherwise read as nothing uncommitted (#2309).
  if [ ! -e "$p" ]; then
    echo "  keeping $name [$bl]: its folder is not there, so git's record of it is all that is left; git -C $top worktree prune clears that"
    continue
  fi
  if [ ! -d "$p" ] || [ ! -r "$p" ] || [ ! -x "$p" ]; then
    echo "  keeping $name [$bl]: its folder cannot be read, so whether anything in it is uncommitted cannot be told"
    continue
  fi
  # Uncommitted work settles it on its own: somebody may be part way through a change, and nothing
  # below is worth risking that (L5).
  if ! st="$(git -C "$p" status --porcelain --untracked-files=all 2>/dev/null)"; then
    echo "  keeping $name [$bl]: git could not read its status, so whether anything in it is uncommitted cannot be told"
    continue
  fi
  dirty="$(printf '%s\n' "$st" | grep -c . || true)"
  if [ "${dirty:-0}" -gt 0 ]; then
    echo "  keeping $name [$bl]: it holds $dirty uncommitted change(s), so a session may be working in it"
    continue
  fi
  real="$(cd "$p" 2>/dev/null && pwd -P)" || real="$p"
  # Off for --just-merged: its caller has just merged this worktree's branch, so everything in it
  # is minutes old by construction, and the rules around this one carry the protection instead.
  # A find that hit a file it could not read and saw nothing recent has not shown nothing is recent.
  if [ -z "$ONLY" ]; then
    recent="$(find "$p" -mmin "-$RECENT" -not -name .git -print -quit 2>/dev/null)"; frc=$?
    if [ -n "$recent" ]; then
      echo "  keeping $name [$bl]: something in it changed in the last $RECENT minutes, so a session may still be using it"
      continue
    fi
    if [ "$frc" -ne 0 ]; then
      echo "  keeping $name [$bl]: some of its files could not be read, so whether anything in it changed in the last $RECENT minutes cannot be told"
      continue
    fi
  fi
  if in_use "$real"; then
    if [ "$can_see_use" -eq 1 ]; then
      echo "  keeping $name [$bl]: a running process is working in it"
    else
      echo "  keeping $name [$bl]: $blind_why, so whether anything is running in it cannot be seen"
    fi
    continue
  fi
  landed=$((landed + 1))
  if [ "$REMOVE" -eq 0 ]; then
    if [ -n "$stale_lock" ]; then
      echo "  STALE $name [$bl]: $stale_why, and its lock was left by a Claude agent that is gone ($stale_lock)"
      echo "    git -C $top worktree unlock $p"
    else
      echo "  STALE $name [$bl]: $stale_why"
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
      echo "  keeping $name [$bl]: its lock changed while this run was looking at it, so whoever holds it now is left alone"
      continue
    fi
    if ! err="$(git -C "$top" worktree unlock "$p" 2>&1)"; then
      echo "  keeping $name [$bl]: its lock was left by a Claude agent that is gone ($stale_lock), and git would not lift it: $(printf '%s' "$err" | tr '\n' ' ')"
      continue
    fi
  fi
  # The marker goes down BEFORE git starts deleting. A removal that cannot leave one is not started,
  # since one cut off without it would read as somebody's work for ever.
  mk="$MARKS/$(markname "$p")"
  if ! { mkdir -p "$MARKS" && printf '%s\n' "$p" >"$mk"; } 2>/dev/null; then
    echo "  keeping $name [$bl]: its progress marker could not be written in $MARKS, so a removal cut off part way could not be finished later"
    relock
    continue
  fi
  # No --force: git refuses a worktree with anything untracked or modified, so a change made since
  # the check above is a refusal, never a loss.
  if err="$(git -C "$top" worktree remove "$p" 2>&1)"; then
    removed=$((removed + 1))
    if [ -n "$stale_lock" ]; then
      echo "  removed $name [$bl]: $gone_why, and its lock was left by a Claude agent that is gone ($stale_lock); $kept_note"
    else
      echo "  removed $name [$bl]: $gone_why ($kept_note)"
    fi
    rm -f "$mk"
  else
    echo "  keeping $name [$bl]: git would not remove it: $(printf '%s' "$err" | tr '\n' ' ')"
    # A refusal before anything is deleted (a change made since the check above, say) leaves the
    # worktree listed, whole and as it was, so there is nothing to finish. A lock no longer gets
    # this far: every lock but a stale agent's keeps the worktree before any removal is tried, and
    # a stale one is lifted first. A failure PART WAY does
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
          rm -f "$mk"
          relock
        elif [ -n "$stale_lock" ]; then
          echo "    its lock, left by a Claude agent that is gone, is not put back, so the next run can finish the removal"
        fi ;;
    esac
  fi
done

[ "$landed" -eq 0 ] && [ "$cut" -eq 0 ] && exit 0
if [ "$REMOVE" -eq 0 ]; then
  [ "$cut" -gt 0 ] && echo "$cut worktree(s) were left part deleted by a removal that stopped part way. The command that finishes one is printed under it."
  [ "$landed" -gt 0 ] && echo "$landed of ${#paths[@]} worktree(s) hold work that has landed. Each is a full copy of the tree, so every repo wide search returns its hits once more per copy. The command to remove one is printed under it."
else
  echo "removed $removed of ${#paths[@]} worktree(s), each one whose work was already kept elsewhere (a merged PR, another branch, or the default branch) with nothing uncommitted in it; every one kept is named above with why."
  [ "$left" -gt 0 ] && echo "$left landed worktree(s) left for the next run, which stops starting removals ${BUDGET}s in."
fi
exit 1
