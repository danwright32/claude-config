#!/usr/bin/env bash
#
# sync-clone.sh: the questions every hook about a config CHECKOUT has to answer
# (claude-config#367).
#
# Sourced, never executed. payload-revert-warning.sh worked these out for itself, and the gate that
# refuses a payload write without a hold needs the same ones. Two copies of "is a hold in force"
# would be two answers to one question, each reading as correct on its own, which is the shape this
# repo keeps finding (L370).
#
#   sc_clone_root_of   is this directory inside a clone of the tool, and where is its root
#   sc_watcher_cmd     the command line of a LIVE watch daemon, or nothing
#   sc_is_this_clone   does that watcher run from the clone in question
#   sc_hold_covers     is a hold in force that protects THIS session's writes: its own, or a terminal's
#   sc_hold_others     the short names of the other sessions holding the watcher
#   sc_payload_session the session a hook payload names
#   sc_is_own_worktree is this clone a linked worktree on its own branch, which nothing mirrors into
#
# Env, honoured by every caller so a test can point all of them at a fixture:
#   SYNC_WATCH_PID_FILE     the watcher's pid file (default ~/.claude-sync-watch.pid)
#   SYNC_HOLD_FILE          the hold marker (default ~/.claude-sync-hold)
#   CLAUDE_CODE_SESSION_ID  the session asking, as Claude Code gives it to every hook it runs

SYNC_WATCH_PID_FILE="${SYNC_WATCH_PID_FILE:-$HOME/.claude-sync-watch.pid}"
SYNC_HOLD_FILE="${SYNC_HOLD_FILE:-$HOME/.claude-sync-hold}"

# The record is parsed in ONE place, shared with claude-sync itself, so the hooks and the tool
# cannot come to two answers about whose hold a line is (claude-config#1886, L370).
#
# Missing, this file STILL loads, and no hold counts for anyone. Failing to load would be the
# opposite: every hook that sources this treats a library it cannot load as nothing to say, and
# allows the write, so a missing reader would let every payload write through in silence (the
# lessons review of #1894, L42). Counting no hold refuses instead, and the refusal says why.
# Found beside this file by parameter expansion, never dirname, which a PATH holding nothing cannot
# start (claude-config#1104).
SC_LIB_DIR="${BASH_SOURCE[0]%/*}"; [ "$SC_LIB_DIR" != "${BASH_SOURCE[0]}" ] || SC_LIB_DIR=.
SC_HOLD_READER=""
# shellcheck source=hold-record.sh
if . "$SC_LIB_DIR/hold-record.sh" 2>/dev/null && declare -F hold_record_rows >/dev/null 2>&1; then
  SC_HOLD_READER=1
fi

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
  local gd common cd br def
  gd="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  # Read first and refused when empty: `cd ""` succeeds, so an unanswered lookup would otherwise
  # resolve to the checkout itself and pass for a linked worktree.
  common="$(cd "$1" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common" ] || return 1
  cd="$(cd "$1" 2>/dev/null && cd "$common" 2>/dev/null && pwd -P)" || return 1
  [ -n "$gd" ] && [ -n "$cd" ] || return 1
  [ "$(cd "$gd" 2>/dev/null && pwd -P)" != "$cd" ] || return 1      # the primary checkout
  # A rebase detaches HEAD, so mid rebase the branch is the one being rebased, read from the rebase
  # state in THIS worktree's own git dir (claude-config#904). Only a name under refs/heads/ counts:
  # a rebase of a detached HEAD records no branch, and stays judged as on no branch. With no rebase
  # in progress a detached HEAD is judged exactly as before.
  br="$(git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null)" || {
    local rb hn
    for rb in rebase-merge rebase-apply; do
      [ -f "$gd/$rb/head-name" ] || continue
      hn="$(head -1 "$gd/$rb/head-name" 2>/dev/null)"
      case "$hn" in refs/heads/?*) br="${hn#refs/heads/}"; break ;; esac
    done
  }
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

# Is a hold in force that protects THIS session's writes? Read only, and expiry is the only thing
# that makes a marker stop counting.
# An UNREADABLE marker is NOT a hold: treating one as a hold would silence every guard built on
# this for as long as the bad file sits there, and that is the direction that loses a day of work
# (L42). It is left on disk for claude-sync itself to report and clear, in its own words, because a
# hook that removes a decision somebody made destroys state it does not own (L5).
#
#
# The marker holds one line per session holding (claude-config#1863), so a line counts wherever it
# sits. claude-sync writes the longest hold first, but a reader that trusted that would be right
# only while every writer kept to it.
#
# Only the asking session's own hold counts, or one with no session recorded, which is a terminal's
# and covers anyone (claude-config#1886). Before this any session's hold let every session write,
# so session B's half written files went out the moment session A released. The session asking is
# the one named, from the hook payload, and CLAUDE_CODE_SESSION_ID: Claude Code gives both, and a
# hold recorded under either is that session's. A caller whose session is not known at all is
# covered only by a terminal's hold, the same "unknown" a hold it took itself would record.
sc_hold_covers(){   # $1 = the session asking, from the hook payload (may be empty)
  local a b
  [ -n "$SC_HOLD_READER" ] || return 1     # no reader: no hold can be read, so none counts
  a="$(hold_record_session "${1:-}")"
  b="$(hold_record_session "${CLAUDE_CODE_SESSION_ID:-}")"
  hold_record_rows "$SYNC_HOLD_FILE" "$(date +%s)" | awk -F '\037' -v a="$a" -v b="$b" \
    '$1 == "live" && ($5 == "unknown" || $5 == a || $5 == b) { ok = 1 } END { exit ok ? 0 : 1 }'
}

# The other sessions holding the watcher, one short name a line, the name status shows and
# `claude-sync release --other` takes: what a refusal names when a hold is in force but is not this
# session's. Nothing when there is none.
sc_hold_others(){   # $1 = the session asking, as for sc_hold_covers
  local a b o loop_input
  [ -n "$SC_HOLD_READER" ] || return 0
  a="$(hold_record_session "${1:-}")"
  b="$(hold_record_session "${CLAUDE_CODE_SESSION_ID:-}")"
  loop_input="$(hold_record_rows "$SYNC_HOLD_FILE" "$(date +%s)" | awk -F '\037' -v a="$a" -v b="$b" \
    '$1 == "live" && $5 != "unknown" && $5 != a && $5 != b && !seen[$5]++ { print $5 }')" || true
  while IFS= read -r o; do
    [ -n "$o" ] || continue
    hold_record_short "$o"; echo
  done <<LOOP_INPUT
$loop_input
LOOP_INPUT
}

# What every refusal or warning says when a hold is in force but is not this session's, in one
# wording for every hook that says it: whose it is, and that this session needs its own. Nothing
# when no other session holds the watcher, so a caller can always append it.
sc_hold_others_sentence(){   # $1 = the session asking, as for sc_hold_covers
  local o list="" n=0
  if [ -z "$SC_HOLD_READER" ]; then
    printf 'No hold can count here: lib/hold-record.sh, which reads the hold record, is missing beside lib/sync-clone.sh at %s, so this stands even under a hold. Restore it with: git checkout -- payload/hooks/lib/hold-record.sh' "$SC_LIB_DIR"
    return 0
  fi
  local loop_input; loop_input="$(sc_hold_others "${1:-}")" || true
  while IFS= read -r o; do
    [ -n "$o" ] || continue
    n=$((n + 1)); list="${list:+$list, }$o"
  done <<LOOP_INPUT
$loop_input
LOOP_INPUT
  [ "$n" -gt 0 ] || return 0
  if [ "$n" -eq 1 ]; then list="session $list holds"; else list="sessions $list hold"; fi
  printf "A hold is in force, but it is not this session's: %s the watcher. Another session's hold does not protect this session's edits, which are sent the moment that hold is released, so this session needs its own hold." "$list"
}

# The session a hook payload names, read without python3 so a hook whose JSON reader is missing
# still knows who is asking. Nothing when it names none, or one not the shape of an id. A quote
# inside any string value is escaped in JSON, so only the payload's own key can match.
sc_payload_session(){   # $1 = the hook payload
  local re='"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"' id
  [ -n "$SC_HOLD_READER" ] || return 0
  [[ "${1:-}" =~ $re ]] || return 0
  id="${BASH_REMATCH[1]}"
  [ "$(hold_record_session "$id")" = "$id" ] || return 0
  printf '%s' "$id"
}
