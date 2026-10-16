#!/usr/bin/env bash
#
# stale-worktree-nudge.sh: remove, once a session, the agent worktrees whose work has already
# landed, and say what it removed and what it kept (claude-config#423, #1199, #1247).
#
# check-stale-worktrees.sh answers the question correctly and nothing would ever ask it. The
# failure it catches is silent by nature: the worktrees sit there, every repo wide search quietly
# returns each real hit once more per copy, and nothing anywhere says why. Built is not wired
# (L3), so the check runs on UserPromptSubmit, which is the same shape and the same reason as
# project-list-nudge.sh and rule-files-changed.sh.
#
# THE CHECK DOES NOT RUN INSIDE THE PROMPT (#1247). This hook has five seconds, and with 46
# worktrees the check took 3.9 to 4.8 of them before removing anything (measured 2026-10-16), so
# Claude Code killed it at five and threw its answer away in every session, and nothing was removed
# for two days. So the first prompt of a session STARTS lib/stale-worktree-run.py, detached and not
# waited for, and returns at once. That runner holds the lock that keeps two sessions from removing
# at once, runs the check with no timeout over it (a removal killed part way is L617's leftover),
# and writes down anything worth saying. A later prompt says it: the same session's next prompt, or
# the next session's first when this one had no later prompt. Each answer is said once, to
# whichever prompt claims it first, never to every session open in the repository.
#
# WHAT IT COSTS, which is the thing that decides whether a per prompt hook is allowed to exist.
# On every prompt, one glob of the state directory for answers waiting to be said; only when one is
# there does it ask git which repository this is. On the first prompt of a session, one git call
# and the start of a process it does not wait for. The run itself makes the one network call, and
# it starts AT MOST ONCE PER SESSION: the record is written and read BEFORE the run is started, not
# after it. Written the other way round, deduplicating the message after computing it, the message
# appeared once and the call was paid on every prompt for the rest of the session.
#
# What that trades away is stated rather than hidden: a worktree that goes stale part way through a
# session is removed by the NEXT session rather than this one. For tidying up, a day late is
# nothing and a network call per prompt is not (L112).
#
# It NEVER blocks the prompt. A UserPromptSubmit hook exiting non-zero stops the turn, and a
# worktree nobody has tidied is something to mention, not a reason to refuse to work (L54). Every
# path here exits 0.
#
# It REMOVES, by Dan's decision of 2026-10-14 (#1199), through check-stale-worktrees.sh --remove,
# whose header holds every rule a worktree must pass first.
#
# Environment:
#   STALE_WT_CHECK      run this instead of the check beside it, for a fixture
#   STALE_WT_STATE_DIR  where the per session records, the lock and the answers are kept (default
#                       TMPDIR). A DIRECTORY, so two sessions at once each get their own record.
set -uo pipefail

input="$(cat 2>/dev/null || true)"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${STALE_WT_CHECK:-$DIR/check-stale-worktrees.sh}"
RUNNER="$DIR/lib/stale-worktree-run.py"
[ -f "$CHECK" ] || exit 0
STATE_DIR="${STALE_WT_STATE_DIR:-${TMPDIR:-/tmp}}"
STATE_DIR="${STATE_DIR%/}"

# The runner is python3, and it is what puts the run in a session of its own and holds the lock.
# Without it the only way left to run the check is inside the prompt, which is the defect this
# hook was rebuilt to end, so it starts nothing and says why where anybody looking will see it.
if ! command -v python3 >/dev/null 2>&1; then
  echo "stale-worktree-nudge: python3 is not on PATH, and the background run that removes finished agent worktrees runs under it, so no cleanup was started." >&2
  exit 0
fi
[ -f "$RUNNER" ] || exit 0

session="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
print(d.get("session_id") or d.get("transcript_path") or "")
' 2>/dev/null || true)"

top=""; rkey=""
which_repo(){
  [ -n "$top" ] && return 0
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] || return 1
  rkey="$(printf '%s' "$top" | shasum | cut -c1-12)"
}

# --- say what a finished run left to say ----------------------------------
# Claimed by a rename before it is read, so of two sessions at once exactly one says it. The last
# one said is kept as .shown rather than deleted, so "said" and "never written" stay two different
# states on disk (L258).
said=""
shopt -s nullglob
waiting=("$STATE_DIR"/claude-stale-worktrees-repo-*.result.*)
shopt -u nullglob
if [ "${#waiting[@]}" -gt 0 ] && which_repo; then
  for f in "${waiting[@]}"; do
    case "$f" in "$STATE_DIR/claude-stale-worktrees-repo-$rkey.result."*) ;; *) continue ;; esac
    case "$f" in *.tmp.*) continue ;; esac
    claimed="$STATE_DIR/claude-stale-worktrees-repo-$rkey.claimed.$$"
    mv "$f" "$claimed" 2>/dev/null || continue
    said="$said$(cat "$claimed" 2>/dev/null)"$'\n'
    mv -f "$claimed" "$STATE_DIR/claude-stale-worktrees-repo-$rkey.shown" 2>/dev/null || true
  done
fi
[ -z "$said" ] || printf '%s' "$said"

# --- start this session's run ---------------------------------------------
start_run(){
  which_repo || return 0   # not a repository: there is nothing to judge
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  # No stdin, no stdout, no stderr, not waited for, not in this shell's job table: a run that held
  # the hook's stdout would hold the prompt for as long as it ran (L235).
  nohup python3 "$RUNNER" --check "$CHECK" --repo "$top" --state-dir "$STATE_DIR" --key "$rkey" \
    </dev/null >/dev/null 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  [ -z "${STATE:-}" ] || printf 'runner %s\n' "$pid" >>"$STATE" 2>/dev/null || true
}

# With no session there is nothing to key the record on, and it starts a run on every prompt: said
# twice is a smaller failure than never said, and the lock keeps the runs from overlapping (L11,
# L98). Why it could not deduplicate goes to stderr, which a UserPromptSubmit hook does not show.
if [ -z "$session" ]; then
  echo "stale-worktree-nudge: the hook payload carried neither a session id nor a transcript path, so this check could not be held to once per session and may run on every prompt." >&2
  STATE=""
  start_run
  exit 0
fi

key="$(printf '%s' "$session" | shasum | cut -c1-12)"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE="$STATE_DIR/claude-stale-worktrees-${key}.state"

# THE RECORD IS READ BEFORE THE RUN STARTS, which is the whole of the cost bound: once this session
# has started one, no later prompt in it starts another, whatever the answer was.
[ -f "$STATE" ] && exit 0

# And written before the run starts, not after, so a start that fails cannot leave the session
# paying for it on every prompt (L514). It also records the runner's process, which is how a run
# from this session can be found later.
: > "$STATE" 2>/dev/null || true
start_run
exit 0
