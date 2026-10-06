#!/usr/bin/env bash
#
# sync-clone.sh: the questions every hook about a config CHECKOUT has to answer
# (claude-config#367).
#
# Sourced, never executed. payload-revert-warning.sh worked these out for itself, and the gate that
# refuses a payload write without a hold needs the same four. Two copies of "is a hold in force"
# would be two answers to one question, each reading as correct on its own, which is the shape this
# repo keeps finding (L370).
#
#   sc_clone_root_of   is this directory inside a clone of the tool, and where is its root
#   sc_watcher_cmd     the command line of a LIVE watch daemon, or nothing
#   sc_is_this_clone   does that watcher run from the clone in question
#   sc_hold_live       is a hold in force right now
#   sc_is_own_worktree is this clone a linked worktree on its own branch, which nothing mirrors into
#
# Env, honoured by every caller so a test can point all of them at a fixture:
#   SYNC_WATCH_PID_FILE  the watcher's pid file (default ~/.claude-sync-watch.pid)
#   SYNC_HOLD_FILE       the hold marker (default ~/.claude-sync-hold)

SYNC_WATCH_PID_FILE="${SYNC_WATCH_PID_FILE:-$HOME/.claude-sync-watch.pid}"
SYNC_HOLD_FILE="${SYNC_HOLD_FILE:-$HOME/.claude-sync-hold}"

# Is this a clone of the tool at all, and where is its root? Found by walking up for a directory
# holding BOTH a claude-sync and a payload/, which is what makes a directory a clone of it. Not
# through git: a session is routinely in a subdirectory, a worktree, or a copy with no repository,
# and the question is about the mirror rather than about revision control.
sc_clone_root_of(){ # sc_clone_root_of <dir> -> the clone root, or nothing
  local d
  d="$(cd "${1:-}" 2>/dev/null && pwd -P)" || return 1
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/claude-sync" ] && [ -d "$d/payload" ]; then printf '%s' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}

# A live watcher's command line. Taken from the process itself: the thing that would do the
# reverting is the thing that names where it runs from, so the answer and the subject come from one
# source rather than from a registry maintained beside it (L41).
#
# The pid is confirmed against what that process actually IS, never taken from the file alone. A
# stale pid is reused by the system constantly, and a number alone cannot tell a live watcher from
# whatever inherited it (L237). Deliberately the same test claude-sync's own watch_already_running
# applies, for the same reason.
sc_watcher_cmd(){ # -> a live watcher's command line, or nothing
  local pid cmd
  [ -f "$SYNC_WATCH_PID_FILE" ] || return 1
  pid="$(head -1 "$SYNC_WATCH_PID_FILE" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
  case "$cmd" in *claude-sync*watch*) printf '%s' "$cmd"; return 0 ;; esac
  return 1
}

# Does that watcher run from THIS clone? Answered by substring against the whole command line, not
# by parsing a path out of it: a command line cannot be tokenised unambiguously when a path holds a
# space, and this is the question that decides whether to speak. The boundary matters: without it a
# watcher at /x/a/b/claude-sync would answer for a clone at /a/b.
sc_is_this_clone(){ # sc_is_this_clone <clone root> <watcher command line>
  case "${2:-}" in "$1/claude-sync"*|*" $1/claude-sync"*) return 0 ;; esac
  return 1
}

# Is this clone somewhere the daemon can NOT overwrite (claude-config#800)? The daemon mirrors
# ~/.claude over payload/ in its OWN clone and pushes to main; it never writes into a linked
# worktree, and a branch other than the default reaches main only by a reviewed merge. So a linked
# worktree on such a branch is not at risk, and every other checkout still is: the primary checkout
# (whatever branch it is on), a linked worktree on the default branch, and one on no branch at all.
# Written as the reason for refusing rather than a list of exempt places (L615). Any question git
# cannot answer counts as at risk (L42). The default branch is origin's, else main, else master.
sc_is_own_worktree(){ # sc_is_own_worktree <clone root>
  local gd cd br def
  gd="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  cd="$(cd "$1" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || return 1
  [ -n "$gd" ] && [ -n "$cd" ] || return 1
  [ "$(cd "$gd" 2>/dev/null && pwd -P)" != "$cd" ] || return 1      # the primary checkout
  br="$(git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null)" || return 1
  [ -n "$br" ] || return 1                                          # on no branch
  def="$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
  def="${def#origin/}"
  if [ -z "$def" ]; then
    if git -C "$1" show-ref -q --verify refs/heads/main 2>/dev/null; then def=main
    elif git -C "$1" show-ref -q --verify refs/heads/master 2>/dev/null; then def=master
    else return 1; fi
  fi
  [ "$br" != "$def" ]
}

# Is a hold in force? Read only, and expiry is the only thing that makes a marker stop counting.
# An UNREADABLE marker is NOT a hold: treating one as a hold would silence every guard built on
# this for as long as the bad file sits there, and that is the direction that loses a day of work
# (L42). It is left on disk for claude-sync itself to report and clear, in its own words, because a
# hook that removes a decision somebody made destroys state it does not own (L5).
sc_hold_live(){
  local until now
  [ -f "$SYNC_HOLD_FILE" ] || return 1
  until="$(awk 'NR==1{print $1}' "$SYNC_HOLD_FILE" 2>/dev/null)"
  case "$until" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  [ "$now" -lt "$until" ]
}
