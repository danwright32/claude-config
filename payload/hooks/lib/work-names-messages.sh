#!/usr/bin/env bash
#
# work-names-messages.sh: the messages of the commits a push adds, read by the work names scanner
# (claude-config#1995). Sourced, never executed, after lib/push-scope.sh, whose readers it uses.
#
# This repository is public and squash merges with the commit messages as the body, so a message
# naming a work organisation lands in main without ever being a file the whole tree scan reads. On
# 2026-10-31 one did reach a commit (a fixture quoting a work organisation and repository) and was
# caught only by reading it by hand before the push. The scanner is lib/work-names.py, the one rule
# for files and text alike (L370); this file only decides WHICH messages a push adds and hands them
# to it, through its --texts0-from stream.
#
#   wnm_push_messages <command>   run in the repository; sets WNM_OUT, WNM_JUDGED, WNM_BASE
#
# WHAT A PUSH ADDS. Every commit reachable from HEAD that is on neither the branch's upstream (already
# pushed) nor the remote's default branch (already published, or about to be by somebody else's
# merge). A branch with no upstream is therefore judged against the default branch alone, and a
# repository that knows no remote at all has nothing published, so every commit in it is one the
# push adds: judged, never skipped. Merge commits are judged too, since a squash message carries
# theirs. HEAD is what is judged, as every other push gate here judges it.
#
# Returns 0 when every message added is clean or there is none to judge (HEAD has no commit), 1 when
# at least one names an organisation, 2 when the messages could not be judged (git could not list
# them, or the scanner could not run or could not judge them), and 3 when the command commits before
# it pushes: that commit's message is not in git yet, so it cannot be read before the push, and
# reading only the commits already made would pass the one most likely to carry the name.
#   WNM_OUT     what the scanner printed, hits and its summary with the remedy, or why it could not
#   WNM_JUDGED  a phrase naming which commits were judged, for the refusal
#   WNM_BASE    the commit the added ones start from, for a reset that rewords them, or empty
# Seam: WNM_SCANNER (default lib/work-names.py beside this file).

WNM_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

wnm_push_messages() {   # $1 = the push command
  local scanner="${WNM_SCANNER:-$WNM_HERE/work-names.py}" up def stream rc
  local -a not=()
  WNM_OUT=""; WNM_JUDGED=""; WNM_BASE=""
  if ps_commit_in_chain "$1"; then
    WNM_OUT="this command commits before it pushes, and the message of the commit it makes is not written yet, so it cannot be read before the push"
    return 3
  fi
  git rev-parse --verify --quiet HEAD >/dev/null 2>&1 || return 0
  up="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
  git rev-parse --verify --quiet "$up" >/dev/null 2>&1 || up=""
  def="$(ps__default_ref 2>/dev/null)"
  [ -n "$up" ] && not+=("^$up")
  [ -n "$def" ] && [ "$def" != "$up" ] && not+=("^$def")
  if [ -n "$up" ] && [ -n "$def" ] && [ "$up" != "$def" ]; then WNM_JUDGED="the commits on neither $up nor $def"
  elif [ -n "$up" ]; then WNM_JUDGED="the commits not on $up"
  elif [ -n "$def" ]; then WNM_JUDGED="the commits not on $def (the branch has no upstream yet)"
  else WNM_JUDGED="every commit, since this repository knows no remote branch to compare against"; fi
  WNM_BASE="$(git merge-base HEAD "${up:-$def}" 2>/dev/null)"
  [ -f "$scanner" ] || { WNM_OUT="the work names scanner $scanner is missing"; return 2; }
  # Each commit is "commit <sha>" then its whole message. With -z git ends every entry with a NUL
  # (measured on git 2.51: the stream's last byte is one), so a last message that is empty is still a
  # text and never a label left without one, and nothing is added here.
  stream="$(mktemp "${TMPDIR:-/tmp}/work-names-messages.XXXXXX")" \
    || { WNM_OUT="no temporary file could be made for the messages"; return 2; }
  if ! git log -z --format='commit %h%x00%B' HEAD ${not[@]+"${not[@]}"} -- > "$stream" 2>/dev/null; then
    rm -f "$stream"
    WNM_OUT="git could not list the commits this push adds ($WNM_JUDGED)"
    return 2
  fi
  if [ ! -s "$stream" ]; then rm -f "$stream"; return 0; fi
  WNM_OUT="$(python3 "$scanner" --texts0-from "$stream" 2>&1)"; rc=$?
  rm -f "$stream"
  case "$rc" in
    0|1) return "$rc" ;;
    *) WNM_OUT="lib/work-names.py gave no verdict (exit $rc): $WNM_OUT"; return 2 ;;
  esac
}
