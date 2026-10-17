#!/usr/bin/env bash
#
# shipped-worktrees.sh: which agent worktrees have shipped, and, only when asked, removing them.
#
#   bash tools/shipped-worktrees.sh [repo]            report, change nothing (the default)
#   bash tools/shipped-worktrees.sh --remove [repo]   remove the ones proven safe, naming each
#
# Why this exists (claude-config#448): Claude Code puts each agent's worktree under
# .claude/worktrees/ and nothing ever removes it. On 2026-09-18 five sat in this checkout, every
# one backing a pull request merged days before. They cost disk on a Mac that has run out before,
# and they blur which work is still live.
#
# It is the sibling of shipped-branches.sh, not a mode of it, because the two are allowed to know
# different things. shipped-branches.sh ACTS ON NOTHING, so it may fall back to a guess from a
# matching commit subject. This one deletes a directory, and a guess is not enough to delete on
# (L5), so it takes its verdict from GitHub's own record of the pull request and from nothing else.
# What the two share lives once in lib/: which branch counts as main (default-branch.sh) and how
# that record of pull requests is read (pull-requests.sh).
#
# A worktree is REMOVABLE only when every one of these is proven, and KEEP names each that is not:
#
#   merged      gh reports a MERGED pull request from its branch, and none still OPEN. Ancestry
#                 cannot say this in a repo that squashes on merge: a merged branch is never an
#                 ancestor of main (L642).
#   clean       no uncommitted change and no untracked file.
#   pushed      no commit that is not on main, on the remote branch, or at the head a merged pull
#                 request recorded. The last one matters because this repo deletes the remote
#                 branch on merge, and the squash rewrote the commits, so the merged head is the
#                 only place a finished branch's work is still recorded as shipped.
#   unlocked    not locked, or locked by a Claude agent that is gone. Claude Code locks the
#                 worktree of an agent it starts and lifts the lock when the agent finishes, so an
#                 agent that never finished (the Mac going down) leaves a lock behind (#1282). The
#                 lock is read by payload/hooks/lib/agent-lock.sh, the one reading
#                 check-stale-worktrees.sh uses too, so the two cleanups agree: a lock whose pid no
#                 process has, or whose agent started before the last boot, keeps nothing, and is
#                 lifted just before the removal (only if it is still that lock, and put back if
#                 git then refuses and leaves the worktree whole; one left part deleted stays
#                 unlocked so a single --force can finish it). An older lock with no start time, "claude agent <name> (pid
#                 <pid>)", keeps nothing only when no process has its pid. A live agent's lock, a
#                 pid now held by a process started at another time, an older lock whose pid is
#                 running, a lock whose agent cannot be read, and any other lock keep it.
#   unoccupied  no running process has its current directory in it. Another session's shell can
#                 be standing there, and removing a directory out from under it is not safe.
#
# When GitHub cannot be read the whole run REFUSES, with exit 3, and nothing is removed.
# Unreadable is neither merged nor unmerged: taking it as unmerged reports a quiet checkout that
# is not quiet, and taking it as merged deletes live work (L98, L320).
#
# With --remove it removes each REMOVABLE worktree with `git worktree remove`, never forced, so git
# makes its own dirty check as well, and then deletes that worktree's LOCAL branch. It never
# touches a remote branch, never removes the primary checkout, and never switches any branch.
#
# Exit 0 on a report or on removals that all succeeded, 1 when a removal failed, 2 on a target or
# option it cannot use, 3 when GitHub could not be read.

set -uo pipefail

fail() {
  printf 'shipped-worktrees: %s\n' "$1" >&2
  exit 2
}

remove=0
repo=""
for arg in "$@"; do
  case "$arg" in
    --remove) remove=1 ;;
    -h|--help) sed -n '3,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) fail "unknown option $arg (the only one is --remove)" ;;
    *) [ -z "$repo" ] || fail "one checkout at a time, and it was given both $repo and $arg"
       repo="$arg" ;;
  esac
done
repo="${repo:-$PWD}"

[ -d "$repo" ] || fail "there is no directory at $repo"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
  || fail "$repo is not a git checkout, so there are no worktrees here to judge"
command -v jq >/dev/null 2>&1 || fail "it needs jq to read what gh answers, and jq is not installed"

libdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
for lib in default-branch.sh pull-requests.sh; do
  [ -f "$libdir/$lib" ] || fail "its library is missing: $libdir/$lib"
done
# shellcheck source=lib/default-branch.sh
. "$libdir/default-branch.sh"
# shellcheck source=lib/pull-requests.sh
. "$libdir/pull-requests.sh"
agent_lock_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/payload/hooks/lib/agent-lock.sh"
[ -f "$agent_lock_lib" ] || fail "its library is missing: $agent_lock_lib"
# shellcheck source=../payload/hooks/lib/agent-lock.sh
. "$agent_lock_lib"

refuse_gh() {  # refuse_gh <what gh said>
  printf 'shipped-worktrees: could not read GitHub, so nothing was judged and nothing was removed.\n' >&2
  printf '  A pull request that cannot be read is neither merged nor unmerged. gh said:\n' >&2
  printf '%s\n' "$1" | sed 's/^/    /' >&2
  exit 3
}
command -v gh >/dev/null 2>&1 || refuse_gh "gh is not installed"

# EVERY WORKTREE, from git's own list. The first entry is always the primary checkout, whichever
# worktree this was run from, so a run from inside an agent's worktree still judges them all.
porcelain="$(git -C "$repo" worktree list --porcelain 2>/dev/null)" \
  || fail "git could not list the worktrees of $repo"

wt_path=(); wt_branch=(); wt_locked=(); wt_lockreason=(); wt_detached=()
i=-1
while IFS= read -r line; do
  case "$line" in
    "worktree "*)
      i=$((i + 1))
      wt_path[i]="${line#worktree }"; wt_branch[i]=""; wt_locked[i]=0; wt_lockreason[i]=""
      wt_detached[i]=0 ;;
    "branch refs/heads/"*) wt_branch[i]="${line#branch refs/heads/}" ;;
    detached) wt_detached[i]=1 ;;
    locked) wt_locked[i]=1 ;;
    "locked "*) wt_locked[i]=1; wt_lockreason[i]="${line#locked }" ;;
  esac
done <<EOF
$porcelain
EOF
[ "$i" -ge 0 ] || fail "git listed no worktrees at all for $repo"

primary="$(cd "${wt_path[0]}" 2>/dev/null && pwd -P)" || fail "the primary checkout ${wt_path[0]} cannot be entered"
default="$(default_branch "$primary")" \
  || fail "cannot work out which branch things merge into ($default is not a ref here)"
agent_root="$primary/.claude/worktrees"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/shipped-worktrees.XXXXXXXX")" || fail "no scratch directory"
trap 'rm -rf "$scratch"' EXIT

# WHO IS STANDING WHERE: every process's current directory, read in one call. `lsof +D` walks the
# whole tree and is unbounded on a worktree holding node_modules; this is one line per process.
#
# The listing proves itself before it is believed: this script's own process must be in it. On a
# machine where lsof sees less than it should, an empty listing would otherwise read as nobody
# standing anywhere, and every worktree would pass the one check that protects a live session.
read_cwds() {
  lsof -a -d cwd -Fpcn 2>/dev/null | awk '
    /^p/ { pid = substr($0, 2); cmd = "" }
    /^c/ { cmd = substr($0, 2) }
    /^n/ { printf "%s\t%s\t%s\n", pid, cmd, substr($0, 2) }
  ' > "$scratch/cwds"
  awk -F'\t' -v me="$$" '$1 == me { found = 1 } END { exit found ? 0 : 1 }' "$scratch/cwds"
}
occupant() {  # occupant <resolved path>: "pid (command)" of one process standing in it, or nothing
  awk -F'\t' -v p="$1" '
    $3 == p || substr($3, 1, length(p) + 1) == p "/" { printf "%s (%s)", $1, $2; exit }
  ' "$scratch/cwds"
}
cwds_readable=1
read_cwds || cwds_readable=0

dirty_count() {  # dirty_count <worktree>: changed or untracked files, or fails when unreadable
  local s
  s="$(git -C "$1" status --porcelain --untracked-files=all 2>/dev/null)" || return 1
  [ -n "$s" ] || { echo 0; return 0; }
  printf '%s\n' "$s" | wc -l | tr -d ' '
}

# The lock git holds on one worktree now, as the whole "locked ..." line, or nothing. Read whole
# first, so an awk stopping at its match cannot cut git off under pipefail.
lock_now() {  # lock_now <path as git lists it>
  local all; all="$(git -C "$primary" worktree list --porcelain 2>/dev/null)"
  printf '%s\n' "$all" | awk -v p="worktree $1" '
    $0 == p { f = 1; next } /^worktree / { f = 0 } f && /^locked/ && !done { print; done = 1 }'
}

rows=()
removable=()
removable_detail=()
wt_stalelock=()
kept=0
outside=0

for ((n = 1; n <= i; n++)); do
  path="${wt_path[n]}"
  branch="${wt_branch[n]}"
  real="$(cd "$path" 2>/dev/null && pwd -P || true)"
  case "${real:-$path}/" in
    "$agent_root"/*/) ;;
    *) outside=$((outside + 1)); continue ;;
  esac
  rel="${real:-$path}"; rel="${rel#"$primary"/}"
  reasons=()

  if [ -z "$real" ]; then
    rows+=("$(printf '  %-9s  %-46s its directory is gone; git worktree prune clears the record' KEEP "$rel")")
    kept=$((kept + 1)); continue
  fi
  if [ "${wt_detached[n]}" = 1 ] || [ -z "$branch" ]; then
    rows+=("$(printf '  %-9s  %-46s detached, so there is no branch whose pull request could prove it merged' KEEP "$rel")")
    kept=$((kept + 1)); continue
  fi

  # MERGED, from GitHub, through the one reading shipped-branches.sh uses too.
  prs="$(pull_requests "$primary" "$branch")" || refuse_gh "$prs"
  merged="$(awk '$1 == "MERGED" { print $2, $3 }' <<< "$prs")"
  open="$(awk '$1 == "OPEN" { printf "%s#%s", (n++ ? ", " : ""), $2 }' <<< "$prs")"
  merged_numbers="$(printf '%s\n' "$merged" | awk 'NF { printf "%s#%s", (n++ ? ", " : ""), $1 }')"

  if [ -z "$merged" ]; then
    if [ -n "$open" ]; then reasons+=("no merged pull request from this branch ($open open)")
    else reasons+=("no merged pull request from this branch"); fi
  elif [ -n "$open" ]; then
    reasons+=("pull request $open from this branch is still open")
  fi

  # CLEAN.
  if d="$(dirty_count "$real")"; then
    [ "$d" = 0 ] || reasons+=("$d uncommitted or untracked file$([ "$d" = 1 ] || echo s)")
  else
    reasons+=("its status could not be read")
  fi

  # PUSHED: nothing reachable from its tip that is not on main, the remote branch, or a merged head.
  shipped_to=("$default")
  shipped_names="$default"
  if git -C "$primary" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    shipped_to+=("refs/remotes/origin/$branch"); shipped_names="$shipped_names, origin/$branch"
  fi
  while read -r _num oid; do
    [ -n "${oid:-}" ] || continue
    git -C "$primary" cat-file -e "$oid^{commit}" 2>/dev/null && shipped_to+=("$oid")
  done <<< "$merged"
  [ -z "$merged_numbers" ] || shipped_names="$shipped_names or merged pull request $merged_numbers"
  if u="$(git -C "$real" rev-list --count HEAD --not "${shipped_to[@]}" 2>/dev/null)"; then
    [ "$u" = 0 ] || reasons+=("$u commit$([ "$u" = 1 ] || echo s) not on $shipped_names")
  else
    reasons+=("which of its commits are pushed could not be read")
  fi

  # UNLOCKED, or locked by a Claude agent that is gone.
  wt_stalelock[n]=""
  if [ "${wt_locked[n]}" = 1 ]; then
    IFS=$'\t' read -r lv ldetail <<< "$(agent_lock_verdict "${wt_lockreason[n]}")"
    case "$lv" in
      dead|preboot) wt_stalelock[n]="$ldetail" ;;
      live) reasons+=("a Claude agent that is still running holds its lock ($ldetail)") ;;
      reused) reasons+=("its lock names a pid now held by another process, which cannot prove its agent gone ($ldetail)") ;;
      nostart) reasons+=("its lock names $ldetail (locked: ${wt_lockreason[n]})") ;;
      unreadable) reasons+=("it is locked by a Claude agent, and whether that agent is still running could not be read ($ldetail; locked: ${wt_lockreason[n]})") ;;
      *) reasons+=("locked${wt_lockreason[n]:+: ${wt_lockreason[n]}}") ;;
    esac
  fi

  # UNOCCUPIED.
  if [ "$cwds_readable" = 1 ]; then
    who="$(occupant "$real")"
    [ -z "$who" ] || reasons+=("it is the current directory of pid $who")
  else
    reasons+=("could not check whether a process is standing in it")
  fi

  if [ "${#reasons[@]}" -eq 0 ]; then
    detail="$branch: pull request $merged_numbers merged, clean, nothing unpushed"
    [ -z "${wt_stalelock[n]}" ] || detail="$detail; its lock was left by a Claude agent that is gone (${wt_stalelock[n]})"
    rows+=("$(printf '  %-9s  %-46s %s' REMOVABLE "$rel" "$detail")")
    removable+=("$n")
    removable_detail+=("$detail")
  else
    joined="$(printf '%s; ' "${reasons[@]}")"
    rows+=("$(printf '  %-9s  %-46s %s: %s' KEEP "$rel" "$branch" "${joined%; }")")
    kept=$((kept + 1))
  fi
done

printf 'shipped-worktrees: %s, judged against %s\n' "$primary" "$default"
printf '  merged means GitHub reports a merged pull request from the branch, read with gh.\n\n'
if [ "${#rows[@]}" -eq 0 ]; then
  printf '  There are no worktrees under .claude/worktrees, so there is nothing to judge.\n'
fi

failed=0
removed=0
if [ "$remove" = 0 ]; then
  [ "${#rows[@]}" -eq 0 ] || printf '%s\n' "${rows[@]}"
else
  # Kept rows first, then each removal as it happens, so a failure part way still leaves a record
  # of everything decided before it.
  for r in ${rows[@]+"${rows[@]}"}; do
    case "$r" in "  REMOVABLE"*) ;; *) printf '%s\n' "$r" ;; esac
  done
  for ((k = 0; k < ${#removable[@]}; k++)); do
    n="${removable[k]}"
    real="$(cd "${wt_path[n]}" 2>/dev/null && pwd -P || true)"
    rel="${real#"$primary"/}"
    branch="${wt_branch[n]}"
    # Judged a moment ago is not judged now: a session can have walked in or written a file since
    # (L567). Both are re-read immediately before the one step that cannot be undone.
    read_cwds || { printf '  %-9s  %-46s %s: could not re-check who is standing in it\n' KEPT "$rel" "$branch"; continue; }
    who="$(occupant "$real")"
    if [ -n "$who" ]; then
      printf '  %-9s  %-46s %s: pid %s walked into it after it was judged\n' KEPT "$rel" "$branch" "$who"; continue
    fi
    d="$(dirty_count "$real" || echo unreadable)"
    if [ "$d" != 0 ]; then
      printf '  %-9s  %-46s %s: it changed after it was judged (%s files)\n' KEPT "$rel" "$branch" "$d"; continue
    fi
    # A lock its agent left behind is lifted only now, and only if it is still that lock: an agent
    # that has taken the worktree since holds a lock of its own, and that one is left alone.
    stale="${wt_stalelock[n]}"
    if [ -n "$stale" ]; then
      if [ "$(lock_now "${wt_path[n]}")" != "locked ${wt_lockreason[n]}" ]; then
        printf '  %-9s  %-46s %s: its lock changed after it was judged\n' KEPT "$rel" "$branch"; continue
      fi
      if ! err="$(git -C "$primary" worktree unlock "${wt_path[n]}" 2>&1)"; then
        printf '  %-9s  %-46s %s: git would not lift the lock its agent left: %s\n' KEPT "$rel" "$branch" "$err"; continue
      fi
    fi
    if ! err="$(git -C "$primary" worktree remove "$real" 2>&1)"; then
      printf '  %-9s  %-46s %s: git refused: %s\n' "NOT DONE" "$rel" "$branch" "$err"
      # Put a lifted lock back on a worktree git left whole, so a removal that did not happen leaves
      # it as it was found. One git left part deleted (still listed, files gone) stays unlocked, the
      # same rule as check-stale-worktrees.sh: finishing it takes one --force, which git refuses on
      # a locked worktree, and the agent the lock names is gone.
      if [ -n "$stale" ] && [ -d "$real" ]; then
        still="$(git -C "$primary" worktree list --porcelain 2>/dev/null)"
        case $'\n'"$still"$'\n' in
          *$'\n'"worktree ${wt_path[n]}"$'\n'*)
            gone_files="$(git -C "$real" status --porcelain 2>/dev/null | grep -c '^ D ' || true)"
            if [ "${gone_files:-0}" -gt 0 ]; then
              printf '             its lock, left by a Claude agent that is gone, is not put back, so it can be finished with: git -C %s worktree remove --force %s\n' "$primary" "$real"
            else
              git -C "$primary" worktree lock --reason "${wt_lockreason[n]}" "${wt_path[n]}" >/dev/null 2>&1 \
                || printf '             and its lock, lifted for the removal, could not be put back\n'
            fi ;;
        esac
      fi
      failed=$((failed + 1)); continue
    fi
    if err="$(git -C "$primary" branch -D "$branch" 2>&1)"; then
      printf '  %-9s  %-46s %s; worktree and local branch removed\n' REMOVED "$rel" "${removable_detail[k]}"
    else
      printf '  %-9s  %-46s %s; worktree removed, but its local branch was not: %s\n' \
        REMOVED "$rel" "${removable_detail[k]}" "$err"
      failed=$((failed + 1))
    fi
    removed=$((removed + 1))
  done
fi

printf '\n'
if [ "$remove" = 0 ]; then
  printf '  %d removable, %d kept.\n' "${#removable[@]}" "$kept"
else
  printf '  %d removed, %d kept.\n' "$removed" "$((kept + ${#removable[@]} - removed))"
fi
[ "$outside" = 0 ] || printf '  %d other worktree(s) outside .claude/worktrees were not looked at.\n' "$outside"
if [ "$remove" = 0 ]; then
  printf '  Nothing was changed.'
  if [ "${#removable[@]}" -gt 0 ]; then
    printf ' To remove the REMOVABLE ones:\n  bash %s --remove %s\n' "${BASH_SOURCE[0]}" "$primary"
  else
    printf '\n'
  fi
fi
[ "$failed" = 0 ] || exit 1
exit 0
