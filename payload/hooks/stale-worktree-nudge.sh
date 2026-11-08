#!/usr/bin/env bash
#
# stale-worktree-nudge.sh: remove, every few hours of a session, the agent worktrees whose work has already
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
# for two days. So a prompt on which a run is due (a session's first, then one every three hours,
# below) STARTS lib/stale-worktree-run.py, detached and not
# waited for, and returns at once. That runner holds the lock that keeps two sessions from removing
# at once, runs the check with no timeout over it (a removal killed part way is L617's leftover),
# and writes down anything worth saying. A later prompt says it: the same session's next prompt, or
# the next session's first when this one had no later prompt. Each answer is said once, to
# whichever prompt claims it first, never to every session open in the repository.
#
# WHAT IT COSTS, which is the thing that decides whether a per prompt hook is allowed to exist.
# On every prompt, one glob of the state directory for answers waiting to be said (only when one is
# there does it need to know which repository this is, which it remembers per directory, so git is
# asked once per directory), and a read of this session's record against the clock. When a run is
# due, that same remembered repository and the start of a process it does not wait for. The run
# itself makes the one network call, and it starts AT MOST ONCE EVERY STALE_WT_RERUN_MINUTES PER
# SESSION: the record is written and read BEFORE the run is started, not after it. Written the
# other way round, deduplicating the message after computing it, the message appeared once and the
# call was paid on every prompt for the rest of the session. The network call must never run per
# prompt: the merged pull request list is GitHub's shared hourly allowance, and a prompt is not a
# reason to spend it.
#
# AND IT STARTS AS FEW PROGRAMS AS IT CAN, because on a loaded Mac starting one is what costs
# (#2453). The hook took 5.2 to 10.5 s in 11 of 24 runs under tools/load-window.sh (measured
# 2026-11-07) against its 5 s timeout, so the reminder was lost on exactly the busy days it is for.
# Under a 48 spawner window a subshell cost nothing measurable while each program started cost 0.17
# to 0.23 s and python3 0.47, and the hook started ten of them besides bash (cat, python3 for the
# session id, shasum and cut twice, mkdir twice, date, git), and two renames more to say an answer.
# It now reads its input and the session id in bash, names the session's record after the id
# rather than a hash, remembers which repository a directory is in, and claims an answer in one
# rename: most prompts start date alone, saying an answer adds mv, and only the first prompt ever
# in a directory asks git and shasum. Its suite counts them on every path and holds them, at the
# worst cost measured, to the timeout.
#
# AGAIN EVERY THREE HOURS, not only at the first prompt (claude-config#1521). This ran once per
# session, on the premise that a worktree going stale part way through a session is removed by the
# next one and "a day late is nothing". That premise expired (L316): on 2026-10-22 one coordinator
# session had run for three days and dispatched over 60 builders, no other session started in the
# repository, and 66 worktrees (63 merged, about 2.5 GB) sat there while the disk fell to 12 GB.
# Two things now cover it. lib/merge-when-ready.sh removes the merged branch's worktree at the
# merge, which is most of them; this sweep takes the rest, the ones kept at the merge (the merging
# agent's own folder, a live agent's lock, a process standing in it) once they are free. Why three
# hours: the sweep keeps anything changed in the last six, so a worktree can go at most about nine
# hours after its last change, a few hundred MB at that building rate rather than gigabytes, for
# one network call per session every three hours. Sweeping every hour would gain at most two hours
# on a six hour floor. A setting, not a measurement.
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
#   STALE_WT_RERUN_MINUTES  how long after a session's last run it starts another (default 180)
#   STALE_WT_NOW        the clock in epoch seconds, for a fixture (L524)
set -uo pipefail

# Read by bash itself, never by cat: on a loaded Mac each program started costs a fifth of a second
# or more, and a subshell nothing (#2453, below).
{ input="$(</dev/stdin)"; } 2>/dev/null
# Cleaned by the shared reader when it loads: a lone surrogate escape anywhere in the payload
# (an emoji cut in half is enough) makes jq read none of it (claude-config#1944). Without the
# library the payload is read as it came, as before.
case "${BASH_SOURCE[0]}" in */*) _ps_dir="${BASH_SOURCE[0]%/*}" ;; *) _ps_dir=. ;; esac
. "$_ps_dir/lib/push-scope.sh" 2>/dev/null && input="$(ps_clean_payload "$input")"

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) DIR="${BASH_SOURCE[0]%/*}" ;; *) DIR=. ;; esac
DIR="$(cd "${DIR:-/}" && pwd)"
CHECK="${STALE_WT_CHECK:-$DIR/check-stale-worktrees.sh}"
RUNNER="$DIR/lib/stale-worktree-run.py"
[ -f "$CHECK" ] || exit 0
STATE_DIR="${STALE_WT_STATE_DIR:-${TMPDIR:-/tmp}}"
STATE_DIR="${STATE_DIR%/}"

# The runner is python3, and it is what puts the run in a session of its own and holds the lock.
# Without it the only way left to run the check is inside the prompt, which is the defect this
# hook was rebuilt to end, so it starts nothing and says why where anybody looking will see it: a
# systemMessage (#1906), since the hooks documentation says Claude Code discards a hook's stderr on
# exit 0 and a UserPromptSubmit hook's plain stdout reaches only Claude.
if ! command -v python3 >/dev/null 2>&1; then
  # shellcheck source=lib/hook-notice.sh
  . "$DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
    printf '%s\n' "$1" >&2
    printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }
  hook_allow_notice "stale-worktree-nudge: python3 is not on PATH, and the background run that removes finished agent worktrees runs under it, so no cleanup was started."
fi
[ -f "$RUNNER" ] || exit 0

# The session id is read by bash's own pattern match, which every payload Claude Code sends
# satisfies: a top level "session_id" whose value holds no escape. A JSON string cannot hold a bare
# quote, so the pattern cannot match one inside the prompt text. Anything else (no id, an empty
# one, an escape in it) is read by python3 as before, which falls back to the transcript path.
# Matched through payload_match, as every hook reading its raw payload is (#1885): a byte that is not
# UTF-8 before the id would hide it from =~ in the session locale, so a miss is asked again under C.
# BASH_REMATCH is the matching try's.
payload_match() { [[ $1 =~ $2 ]] && return 0; local LC_ALL=C; [[ $1 =~ $2 ]]; }
session_re='"session_id"[[:space:]]*:[[:space:]]*"([^"\\]*)"'
if payload_match "$input" "$session_re" && [ -n "${BASH_REMATCH[1]}" ]; then
  session="${BASH_REMATCH[1]}"
else
  session="$(printf '%s' "$input" | python3 -c '
import json, sys
sys.stdout.reconfigure(errors="replace")
try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
except Exception:
    d = {}
print(d.get("session_id") or d.get("transcript_path") or "")
' 2>/dev/null || true)"
fi

# Which repository this directory is in, and its key, asked of git and shasum once per directory
# and then remembered beside the records (#2453): asked on every prompt with an answer waiting, the
# two programs were most of what such a prompt cost on a loaded Mac. A remembered answer is used
# only while it still holds: written for this exact directory, which still lies under its top, the
# top still a repository, and this directory not since made a repository of its own. Anything else
# asks again and remembers anew (a directory reached through a symlink, whose path git names
# differently, always asks, which is the cost before this was remembered, never a wrong answer).
# Two prompts writing it at once write the same three lines, and a half written one fails the test
# above and is asked again, so it needs no lock.
top=""; rkey=""
which_repo(){
  [ -n "$top" ] && return 0
  local dkey="${PWD//[^A-Za-z0-9_.-]/_}" c cpwd ctop ckey
  [ "${#dkey}" -le 100 ] || dkey="${dkey: -100}"
  local cache="$STATE_DIR/claude-stale-worktrees-dir-$dkey.repo"
  if [ -f "$cache" ]; then
    { c="$(<"$cache")"; } 2>/dev/null
    cpwd="${c%%$'\n'*}"; c="${c#*$'\n'}"; ctop="${c%%$'\n'*}"; ckey="${c#*$'\n'}"
    if [ "$cpwd" = "$PWD" ] && [ -n "$ctop" ] && [ -e "$ctop/.git" ] \
       && { [ "$ctop" = "$PWD" ] || { [[ $PWD == "$ctop"/* ]] && [ ! -e "$PWD/.git" ]; }; } \
       && [[ $ckey =~ ^[0-9a-f]{12}$ ]]; then
      top="$ctop"; rkey="$ckey"; return 0
    fi
  fi
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] || return 1
  # The same twelve characters `| cut -c1-12` gave, cut by bash rather than a second program.
  rkey="$(printf '%s' "$top" | shasum)"
  rkey="${rkey:0:12}"
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s\n%s\n%s\n' "$PWD" "$top" "$rkey" >"$cache" 2>/dev/null || true
}

# --- say what a finished run left to say ----------------------------------
# Claimed by a rename before it is read, so of two sessions at once exactly one says it. It is
# renamed straight to its said name, .shown.<this process>, rather than deleted, so "said" and
# "never written" stay two different states on disk (L258), and in one rename rather than two
# (#2453): a claim then a second rename to one shared .shown cost a program start more. The runner
# deletes said answers a day old, keeping the newest (lib/stale-worktree-run.py).
said=""
shopt -s nullglob
waiting=("$STATE_DIR"/claude-stale-worktrees-repo-*.result.*)
shopt -u nullglob
if [ "${#waiting[@]}" -gt 0 ] && which_repo; then
  for f in "${waiting[@]}"; do
    case "$f" in "$STATE_DIR/claude-stale-worktrees-repo-$rkey.result."*) ;; *) continue ;; esac
    case "$f" in *.tmp.*) continue ;; esac
    shown="$STATE_DIR/claude-stale-worktrees-repo-$rkey.shown.$$"
    mv "$f" "$shown" 2>/dev/null || continue
    said="$said$(<"$shown")"$'\n'
  done
fi
[ -z "$said" ] || printf '%s' "$said"

# --- start this session's run ---------------------------------------------
start_run(){
  which_repo || return 0   # not a repository: there is nothing to judge
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || true
  # No stdin, no stdout, no stderr, not waited for: a run that held the hook's stdout would hold the
  # prompt for as long as it ran (L235). Started by a subshell whose own output is /dev/null, so the
  # runner is never this hook's child and that subshell, which records its pid, can write into no
  # pipe (L1035, #1989).
  ( nohup python3 "$RUNNER" --check "$CHECK" --repo "$top" --state-dir "$STATE_DIR" --key "$rkey" \
      </dev/null >/dev/null 2>&1 &
    [ -z "${STATE:-}" ] || printf 'runner %s\n' "$!" >>"$STATE" 2>/dev/null || true
  ) </dev/null >/dev/null 2>&1
}

# With no session there is nothing to key the record on, and it starts a run on every prompt: said
# twice is a smaller failure than never said, and the lock keeps the runs from overlapping (L11,
# L98). Why it could not deduplicate goes to stderr, which a UserPromptSubmit hook does not show.
if [ -z "$session" ]; then
  echo "stale-worktree-nudge: the hook payload carried neither a session id nor a transcript path, so this check could not be held to once per session every three hours and may run on every prompt." >&2
  STATE=""
  start_run
  exit 0
fi

# The record is named after the session id itself, made safe for a file name, rather than a hash of
# it: a hash took two programs (shasum, which is perl, and cut) on every prompt (#2453). A session
# id is a UUID, so it comes through whole; a transcript path, the fallback, keeps its last 100
# characters, which end in the session's own id.
key="${session//[^A-Za-z0-9_.-]/_}"
[ "${#key}" -le 100 ] || key="${key: -100}"
[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE="$STATE_DIR/claude-stale-worktrees-${key}.state"

# THE RECORD IS READ BEFORE THE RUN STARTS, which is the whole of the cost bound: once this session
# has started one, no later prompt in it starts another until STALE_WT_RERUN_MINUTES have passed
# since, whatever the answer was. That is a read of a few lines and the clock, never git or the
# network. A record with no start in it (one the earlier nudge wrote, which started a run once a
# session) cannot say how old it is, so it is treated as due.
RERUN="${STALE_WT_RERUN_MINUTES:-180}"
case "$RERUN" in ''|*[!0-9]*) RERUN=180 ;; esac
now="${STALE_WT_NOW:-}"
case "$now" in ''|*[!0-9]*) now="${EPOCHSECONDS:-$(date +%s)}" ;; esac
if [ -f "$STATE" ]; then
  last=""
  while IFS=' ' read -r k v _; do [ "$k" = started ] && last="$v"; done <"$STATE"
  case "$last" in ''|*[!0-9]*) ;; *) [ $((now - last)) -lt $((RERUN * 60)) ] && exit 0 ;; esac
fi

# And written before the run starts, not after, so a start that fails cannot leave the session
# paying for it on every prompt (L514). It also records the runner's process, which is how a run
# from this session can be found later.
printf 'started %s\n' "$now" >>"$STATE" 2>/dev/null || true
start_run
exit 0
