#!/usr/bin/env bash
#
# judged-worktree.sh: how the two worktree cleanups run git in a worktree they are judging
# (claude-config#3355).
#
# Sourced by hooks/check-stale-worktrees.sh and tools/shipped-worktrees.sh. Each decides whether a
# linked worktree's work has landed and, when asked, removes it, and each asks git about that
# worktree on the way: is anything uncommitted, which of its commits are pushed, remove it. git
# answers those with the worktree's own configuration (the repository's, the worktree's own
# config.worktree, and that of any submodule checked out in it), and a setting there can name a
# program git then starts. Measured 2026-11-20 for #3328 and again here: a plain status started
# core.fsmonitor and a filter, and worktree remove those and the post-index-change hook. So judging
# a worktree ran whatever its configuration named, in a sweep that starts by itself in every
# session (hooks/stale-worktree-nudge.sh) and judges every worktree git lists, wherever it lies.
#
# ONE HELPER, NOT TWO. Every such call goes through dc_git (lib/disk-clean-predicates.sh, #3328),
# which turns those settings off for the one call and refuses any command it was not measured
# with. This file sources that library and holds no setting of its own, so there is one list of
# them. dc_git stays where disk cleanup's command check and its measuring suite
# (hooks/test-disk-clean-git.sh) hold it; what is here is only what these two tools need on top.
#
# The calls, as the tools write them. hooks/test-judged-worktree.sh sees each program run when the
# call is written bare and not run when it is written so:
#   dc_git <worktree> status --porcelain [--untracked-files=all]
#   dc_git <worktree> rev-list --count HEAD --not <refs>        (tools/shipped-worktrees.sh)
#   jw_remove <repository> <worktree> [--force]
#
# What stays plain in both tools: git run in the repository itself about its own records (list its
# worktrees, lock and unlock one, read a ref, delete a branch). That is the repository the tool was
# run for, where every other git call of the session runs too, and no call the suites' fixtures
# reach started a program there. (Two they do not reach, the sweep's reflog show and log -1 over a
# remote branch, are log commands, which run gpg.program over a signed commit when the repository
# sets log.showSignature.) Each tool's suite reads its source and fails on a plain git call of any
# other kind.
#
# Commands it runs: git, only through dc_git; tr and sed, to put a reason on one line; and the
# builtins cd, pwd, printf and echo. Sourcing defines functions, sources the library above and
# does nothing else. bash 3.2 safe.

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) _JW_LIB="${BASH_SOURCE[0]%/*}" ;; *) _JW_LIB=. ;; esac
. "${_JW_LIB:-/}/disk-clean-predicates.sh" || {
  echo "judged-worktree: lib/disk-clean-predicates.sh is missing beside it, so git cannot be run in a worktree with its program running settings off" >&2
  return 1
}

# The folder git keeps a repository's shared records in, as git answers when asked in <folder>,
# resolved. Two folders that print the same one are checkouts of one repository.
_jw_common() { # <folder>
  local c
  c="$(dc_git "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null </dev/null)" || return 1
  [ -n "$c" ] || return 1
  (CDPATH= cd -P "$c" 2>/dev/null && pwd -P)
}

# jw_remove <repository folder> <worktree, as an absolute path> [--force]: git worktree remove with
# the worktree's program running settings off.
#
# git is run IN THE WORKTREE, where both tools ran it in the repository before. dc_git reads which
# filter programs to turn off from the folder it is given, and given the repository's folder it
# reads the main checkout's: a filter named only in the worktree's own config.worktree stayed on
# and ran (measured, test-judged-worktree.sh). The status worktree remove asks for is the
# worktree's, so the worktree is the folder whose settings must be read.
#
# Running git there changes ONE thing, and it is refused here. git removes the worktree it finds
# at that folder, which is this repository's only while the folder's .git still names it. A folder
# whose .git names another repository's worktree record was removed through that repository
# (measured), where git asked from the listing repository refuses it ("validation failed"). So this
# asks git which repository answers in the worktree and which in the repository's folder, and
# refuses unless they are one. Everything else git checks itself, as it did: the main checkout, a
# lock, a folder whose .git is missing, anything uncommitted or untracked.
#
# A worktree whose folder is gone is removed from the repository's folder, as before: git drops its
# record, asks for no status and starts nothing (measured).
#
# --force is what the finisher of a removal cut off part way passes (check-stale-worktrees.sh). With
# it git asks for no status at all, and nothing ran even called bare (measured).
#
# Exit: git's own, with git's words on stderr; or 125 with a line starting "jw_remove: refused:"
# or "dc_git: refused:" when git was never asked to remove anything.
jw_remove() { # <repository folder> <worktree> [--force]
  local repo="${1:-}" p="${2:-}" force="${3:-}" ours theirs
  if [ $# -lt 2 ] || [ $# -gt 3 ] || [ -z "$repo" ] || [ -z "$p" ]; then
    echo "jw_remove: refused: it takes the repository's folder, the worktree and at most --force" >&2
    return 125
  fi
  case "$force" in
    ""|--force) ;;
    *) echo "jw_remove: refused: $force is not an option it passes to worktree remove" >&2; return 125 ;;
  esac
  case "$p" in
    /*) ;;
    *) echo "jw_remove: refused: $p is not an absolute path, and git would read it against the worktree it is run in" >&2; return 125 ;;
  esac
  if [ ! -d "$p" ]; then
    dc_git "$repo" worktree remove ${force:+"$force"} "$p"
    return
  fi
  ours="$(_jw_common "$repo")" || {
    echo "jw_remove: refused: git names no repository at $repo, so whether $p is one of its worktrees could not be told, and nothing was removed" >&2
    return 125
  }
  theirs="$(_jw_common "$p")" || {
    echo "jw_remove: refused: git names no repository for $p, so it was not removed as a worktree of $repo" >&2
    return 125
  }
  if [ "$ours" != "$theirs" ]; then
    echo "jw_remove: refused: in $p git answers for another repository ($theirs), not the one that lists it ($ours), so removing it there would not be removing this repository's worktree" >&2
    return 125
  fi
  dc_git "$p" worktree remove ${force:+"$force"} "$p"
}

# After a status of <worktree> through dc_git has failed: why, on one line, from asking once more
# and keeping only what git or dc_git said. Empty when the second asking worked.
jw_status_why() { # <worktree> [<status options>...]
  local p="$1" w
  shift
  w="$(dc_git "$p" status --porcelain "$@" 2>&1 >/dev/null </dev/null)" && return 0
  printf '%s' "$w" | tr '\n' ' ' | sed 's/  *$//'
}
