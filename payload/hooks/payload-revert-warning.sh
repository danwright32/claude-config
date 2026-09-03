#!/usr/bin/env bash
#
# payload-revert-warning.sh: say, before the work is done rather than after, that payload edits
# made in this checkout will be reverted by the watch daemon (claude-config#279).
#
# On 2026-09-03 most of a day's work was made in the development checkout and pushed. At 11:03 the
# watch daemon on the SAME Mac mirrored its ~/.claude up over payload/ and reverted 84 files in one
# commit: a whole style sweep, two finished issues, part of a third, part of a fourth, and
# lib/match-open-issues.py deleted outright, because a file that exists only in the repo is one the
# mirror has never heard of and it runs with --delete.
#
# The mechanism is not a bug. ~/.claude is the source and payload/ is its mirror, and a change made
# in the mirror is not merged with the source, it is overwritten by it. None of the two Mac merge
# machinery applies, because both copies are on one machine and only one of them is the source. It
# is silent in both directions: nothing warned before the revert, and the tests passed afterwards,
# because they were reverted alongside the code they covered. It was found days later by an
# unrelated ratchet. The rule was then written into DESIGN.md, which is a rule in prose and
# therefore a hope (L27). This is the same rule with something to say it.
#
# WARNS, IT DOES NOT REFUSE, and that is a decision rather than the easier option. A refusal can
# only cover the edit routes it can see. Every PreToolUse hook in this config matches Bash, and the
# edits in this repo are made through Bash (a heredoc, sed, a short script), where a refusal would
# have to either parse shell text, which is unreliable, or refuse a whole category of command,
# which deadlocks the moment the remedy is itself a command (L362: an exemption written as one
# named case stops covering as soon as a second case satisfies its reason). A notice on
# UserPromptSubmit arrives BEFORE any of those routes, costs a `ps` and two small file reads, and
# is what would actually have prevented the incident: the loss was a day of work, not one edit.
#
# ONCE PER STATE, not once per prompt, which is the sibling rule rule-files-changed.sh follows for
# the same reason. It is deliberately unlike that sibling in one way: it speaks on the FIRST prompt
# of a session rather than re-seeding quietly, because there the subject is a change and here the
# condition itself is the report. The state includes whether a hold is in force, so a hold that
# EXPIRES while a session is still editing brings the notice back. That is the same loss with a
# delay on it, and nothing else would report it.
#
# It READS the hold marker and never clears it. claude-sync's own hold_remaining deletes an expired
# or unreadable marker, which is right for the tool that owns it and wrong here: a hook that
# removes a decision somebody made destroys state it does not own (L5).
#
# Env:
#   SYNC_WATCH_PID_FILE            the watcher's pid file (default ~/.claude-sync-watch.pid)
#   SYNC_HOLD_FILE                 the hold marker (default ~/.claude-sync-hold)
#   CLAUDE_PAYLOAD_WARN_STATE_DIR  where the per session state is kept (default TMPDIR). A
#                                  DIRECTORY, for the sibling's reason: pointed at a single file,
#                                  two sessions would overwrite each other's record.
set -uo pipefail

SYNC_WATCH_PID_FILE="${SYNC_WATCH_PID_FILE:-$HOME/.claude-sync-watch.pid}"
SYNC_HOLD_FILE="${SYNC_HOLD_FILE:-$HOME/.claude-sync-hold}"

input="$(cat 2>/dev/null || true)"

# The session, and the directory the prompt was sent from. Keyed on the session so two open at once
# each get their own record. With no session there is no way to tell a first prompt from a later
# one, and guessing would either speak on every prompt or never, so it says on stderr that it could
# not run rather than reporting silence as a clean answer (L98). stderr on a UserPromptSubmit hook
# is not shown to the person, which is why this path stays quiet to them.
read -r session cwd <<< "$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
print((d.get("session_id") or d.get("transcript_path") or "-"), (d.get("cwd") or "-"))
' 2>/dev/null || printf -- '- -')"
[ "$cwd" = "-" ] && cwd="$PWD"
if [ "$session" = "-" ] || [ -z "$session" ]; then
  echo "payload-revert-warning: the hook payload carried neither a session id nor a transcript path, so a first prompt cannot be told from a later one and nothing was said." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Is this a clone of this tool at all, and where is its root? Found by walking up for a directory
# holding BOTH a claude-sync and a payload/, which is what makes a directory a clone of it. Not
# through git: a session is routinely in a subdirectory, a worktree, or a copy with no repository,
# and the question is about the mirror rather than about revision control.
clone_root_of(){ # clone_root_of <dir> -> the clone root, or nothing
  local d
  d="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/claude-sync" ] && [ -d "$d/payload" ]; then printf '%s' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}
root="$(clone_root_of "$cwd")" || exit 0
[ -n "$root" ] || exit 0

# ---------------------------------------------------------------------------
# Is a watcher live, and does it run from THIS checkout? Taken from the process itself: the thing
# that would do the reverting is the thing that names where it runs from, so the answer and the
# subject come from one source rather than from a registry maintained beside it (L41).
#
# The pid is confirmed against what that process actually IS, never taken from the file alone. A
# stale pid is reused by the system constantly, and a number alone cannot tell a live watcher from
# whatever inherited it (L237). This is deliberately the same test claude-sync's own
# watch_already_running applies, for the same reason.
watcher_cmd(){ # -> a live watcher's command line, or nothing
  local pid cmd
  [ -f "$SYNC_WATCH_PID_FILE" ] || return 1
  pid="$(head -1 "$SYNC_WATCH_PID_FILE" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
  case "$cmd" in *claude-sync*watch*) printf '%s' "$cmd"; return 0 ;; esac
  return 1
}
wcmd="$(watcher_cmd || true)"

# WHETHER it is this checkout is answered by substring against the whole command line, not by
# parsing a path out of it. A command line cannot be tokenised unambiguously when a path holds a
# space, and the question that decides whether to speak is the one that must not be got wrong. The
# boundary matters: without it a watcher at /x/a/b/claude-sync would answer for a checkout at /a/b
# and the notice would go quiet on the checkout it exists for.
is_this_checkout(){
  case "$wcmd" in "$root/claude-sync"*|*" $root/claude-sync"*) return 0 ;; esac
  return 1
}

# WHICH clone it is, for the message only. This one is a parse, so it is allowed to fail: the
# first absolute argument ending in /claude-sync. A path holding a space defeats it, and then the
# notice still goes out and says the directory could not be read rather than going quiet, because
# a watcher that is live and is not this checkout is the dangerous state whether or not its home
# can be named (L11).
watcher_clone_name(){
  local d
  d="$(printf '%s' "$wcmd" | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^\/.*\/claude-sync$/) { sub(/\/claude-sync$/, "", $i); print $i; exit }}')"
  if [ -n "$d" ]; then printf '%s' "$d"; else printf '%s' "a clone whose directory could not be read from its command line ($wcmd)"; fi
}

# ---------------------------------------------------------------------------
# Is a hold in force? Read only, and expiry is the only thing that makes a marker stop counting.
# An UNREADABLE marker is not a hold: obeying one would silence this for as long as the bad file
# sits there, and that is the direction that loses a day of work. It is left on disk for claude-sync
# itself to report and clear, which it does in its own words.
hold_live(){
  local until now
  [ -f "$SYNC_HOLD_FILE" ] || return 1
  until="$(awk 'NR==1{print $1}' "$SYNC_HOLD_FILE" 2>/dev/null)"
  case "$until" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  [ "$now" -lt "$until" ]
}

# ---------------------------------------------------------------------------
# The state this prompt is in, in one line. Everything that would change what the person needs to
# be told is in it, so a change in any of them speaks again and a repeat of the same state does not.
clone=""
if [ -z "$wcmd" ]; then
  state="no-watcher"
elif is_this_checkout; then
  state="editing-the-source $root"
else
  clone="$(watcher_clone_name)"
  if hold_live; then state="held $root $clone"; else state="warn $root $clone"; fi
fi

key="$(printf '%s' "$session" | shasum | cut -c1-12)"
STATE_DIR="${CLAUDE_PAYLOAD_WARN_STATE_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE="$STATE_DIR/claude-payload-revert-${key}.state"

previous="$(cat "$STATE" 2>/dev/null || true)"
# Recorded BEFORE speaking, so a notice cannot repeat itself if anything below fails: the safe
# direction is saying it once too few rather than once per prompt for the rest of the session.
printf '%s\n' "$state" > "$STATE" 2>/dev/null || true

[ "$state" = "$previous" ] && exit 0
case "$state" in warn' '*) ;; *) exit 0 ;; esac

echo "claude-sync: this is a development checkout at $root, and a watch daemon is live on this Mac running from $clone. That daemon mirrors ~/.claude up over payload/ and pushes, so edits made to payload/ here are not merged with the config, they are overwritten by it, silently and with no conflict to notice. On 2026-09-03 it reverted 84 files of a day's work in one commit and deleted a file that existed only in the repo. Either edit ~/.claude directly, which needs no hold, or take a hold before editing here: claude-sync hold 120 \"why\". A hold expires, so afterwards make ~/.claude match what is in the checkout, or the next send reverts it again."
exit 0
