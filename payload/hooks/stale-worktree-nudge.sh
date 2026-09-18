#!/usr/bin/env bash
#
# stale-worktree-nudge.sh: say, unprompted, when agent worktrees are sitting on work that has
# already landed (claude-config#423).
#
# check-stale-worktrees.sh answers the question correctly and nothing would ever ask it. The
# failure it catches is silent by nature: the worktrees sit there, every repo wide search quietly
# returns each real hit once more per copy, and nothing anywhere says why. Built is not wired
# (L3), so the check runs on UserPromptSubmit, which is the same shape and the same reason as
# project-list-nudge.sh and rule-files-changed.sh.
#
# WHAT IT COSTS, which is the thing that decides whether a per prompt hook is allowed to exist.
# Every project but this one has no .claude/worktrees directory, and the check exits immediately
# without asking GitHub anything, so the common case is one stat. Where there ARE worktrees the
# check costs a network call, and this is the only hook on this event that makes one, so it runs
# the check AT MOST ONCE PER SESSION: the record is written and read BEFORE the check, not after
# it. Written the other way round, deduplicating the message after computing it, the message
# appeared once and the call was paid on every prompt for the rest of the session, which is the
# cost this comment exists to bound.
#
# What that trades away is stated rather than hidden: a worktree that goes stale part way through a
# session is reported by the NEXT session rather than this one. For a notice about tidying up, a
# day late is nothing and a network call per prompt is not (L112).
#
# It NEVER blocks the prompt. A UserPromptSubmit hook exiting non-zero stops the turn, and a
# worktree nobody has tidied is something to mention, not a reason to refuse to work (L54). Every
# path here exits 0.
#
# It never REMOVES anything, and neither does the check: see the header of check-stale-worktrees.sh
# for why an automatic sweep is the wrong shape for a worktree.
#
# Environment:
#   STALE_WT_CHECK      run this instead of the check beside it, for a fixture
#   STALE_WT_STATE_DIR  where the per session record is kept (default TMPDIR). A DIRECTORY, so two
#                       sessions at once each get their own and neither is told about the other's.
set -uo pipefail

input="$(cat 2>/dev/null || true)"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${STALE_WT_CHECK:-$DIR/check-stale-worktrees.sh}"
[ -f "$CHECK" ] || exit 0

say(){ printf '%s\n' "$1"; exit 0; }

session="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
print(d.get("session_id") or d.get("transcript_path") or "")
' 2>/dev/null || true)"

run_check(){
  # Judged by the exit CODE, never by a line of the output: a tool's last line is routinely a
  # different measurement than its verdict and usually the more reassuring one (L184).
  local answer verdict
  answer="$(bash "$CHECK" 2>/dev/null)"; verdict=$?
  # 0 is nothing to remove. 2 is could not tell, which is about gh or about this not being a
  # repository, and neither is actionable by the person from here: the check says it on stderr for
  # anybody looking, and a notice nobody can act on is the alert that teaches people to skim
  # (L36, L112). Only 1 has something to do.
  [ "$verdict" -eq 1 ] || return 0
  say "$answer"
}

# With no session there is nothing to key the record on, and it RUNS: said twice is a smaller
# failure than never said, and silence is what this exists to end (L11, L98). Why it could not
# deduplicate goes to stderr, which a UserPromptSubmit hook does not show the person.
if [ -z "$session" ]; then
  echo "stale-worktree-nudge: the hook payload carried neither a session id nor a transcript path, so this check could not be held to once per session and may run on every prompt." >&2
  run_check
  exit 0
fi

key="$(printf '%s' "$session" | shasum | cut -c1-12)"
STATE_DIR="${STALE_WT_STATE_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE="$STATE_DIR/claude-stale-worktrees-${key}.state"

# THE RECORD IS READ BEFORE THE CHECK RUNS, which is the whole of the cost bound: once this session
# has asked, no later prompt in it asks again, whatever the answer was.
[ -f "$STATE" ] && exit 0

# And written before the check runs, not after, so a check that dies part way through cannot leave
# the session paying for it on every prompt (L514: the signal that something ran belongs on every
# exit path, and the cheapest way to have one here is to write it first).
: > "$STATE" 2>/dev/null || true
run_check
exit 0
