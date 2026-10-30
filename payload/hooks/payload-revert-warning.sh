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

# The questions about a checkout, from the library the payload write gate shares, so the two
# cannot come to two different answers about whether a hold is in force (claude-config#367, L370).
#
# A library it cannot load is not a checkout with nothing to say (claude-config#1900, L10). It was
# sourced with `|| exit 0`, so with it missing this hook said nothing in any checkout, which reads
# exactly as one nothing can revert. Now the state is "could not check", said once per session in
# this hook's own notice, naming the file.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_LOADED=0
# shellcheck source=lib/sync-clone.sh
{ . "$HOOK_DIR/lib/sync-clone.sh" 2>/dev/null && declare -F sc_hold_covers >/dev/null; } && SC_LOADED=1

input="$(cat 2>/dev/null || true)"

# The session, and the directory the prompt was sent from. Keyed on the session so two open at once
# each get their own record. With no session there is no way to tell a first prompt from a later
# one, and guessing would either speak on every prompt or never, so it says that it could not run
# rather than reporting silence as a clean answer (L98). Said as a systemMessage (#1906): the hooks
# documentation says Claude Code discards a hook's stderr on exit 0, and that a UserPromptSubmit
# hook's plain stdout reaches Claude as context with no visible transcript entry, so it was quiet to
# the person, and the systemMessage is the channel the documentation gives that is shown to them.
# shellcheck source=lib/hook-notice.sh
. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }
# Read as jq reads it, so a prompt holding a byte that is not UTF-8 is read rather than raising and
# leaving the session unknown (claude-config#1900).
read -r session cwd <<< "$(printf '%s' "$input" | python3 -c '
import json, sys
sys.stdout.reconfigure(errors="replace")
try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
except Exception:
    d = {}
print((d.get("session_id") or d.get("transcript_path") or "-"), (d.get("cwd") or "-"))
' 2>/dev/null || printf -- '- -')"
[ "$cwd" = "-" ] && cwd="$PWD"
if [ "$session" = "-" ] || [ -z "$session" ]; then
  hook_allow_notice "payload-revert-warning: the hook payload carried neither a session id nor a transcript path, so a first prompt cannot be told from a later one and nothing was said."
fi

key="$(printf '%s' "$session" | shasum | cut -c1-12)"
STATE_DIR="${CLAUDE_PAYLOAD_WARN_STATE_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE="$STATE_DIR/claude-payload-revert-${key}.state"

# With the library missing nothing below can be asked, not even whether this is a checkout, so it
# says that it could not check, once per session, the way every other state is said.
if [ "$SC_LOADED" -ne 1 ]; then
  state="no-library $HOOK_DIR/lib/sync-clone.sh"
  previous="$(cat "$STATE" 2>/dev/null || true)"
  printf '%s\n' "$state" > "$STATE" 2>/dev/null || true
  [ "$state" = "$previous" ] && exit 0
  echo "claude-sync: payload-revert-warning.sh could not load lib/sync-clone.sh from $HOOK_DIR/lib, so whether a watch daemon could overwrite edits to a development checkout's payload/ was not checked this session. That is not the same as nothing being at risk. The payload write gate refuses a call naming payload/ for the same reason until the library is back. Reinstall the hooks with: claude-sync pull"
  exit 0
fi

# ---------------------------------------------------------------------------
root="$(sc_clone_root_of "$cwd")" || exit 0
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
wcmd="$(sc_watcher_cmd || true)"

# WHETHER it is this checkout is answered by substring against the whole command line, not by
# parsing a path out of it. A command line cannot be tokenised unambiguously when a path holds a
# space, and the question that decides whether to speak is the one that must not be got wrong. The
# boundary matters: without it a watcher at /x/a/b/claude-sync would answer for a checkout at /a/b
# and the notice would go quiet on the checkout it exists for.
is_this_checkout(){ sc_is_this_clone "$root" "$wcmd"; }

# WHICH clone it is, for the message only. This one is a parse, so it is allowed to fail: the
# first absolute argument ending in /claude-sync. A path holding a space defeats it, and then the
# notice still goes out and says the directory could not be read rather than going quiet, because
# a watcher that is live and is not this checkout is the dangerous state whether or not its home
# can be named (L11).
watcher_clone_name(){
  local d
  # Reads to the end and keeps the first answer, never leaving early: a consumer that exits kills
  # its piped writer, and pipefail reports that death as a failure (L183, claude-config#1042).
  d="$(printf '%s' "$wcmd" | awk '!got {for (i = 1; i <= NF; i++) if ($i ~ /^\/.*\/claude-sync$/) { sub(/\/claude-sync$/, "", $i); print $i; got = 1; break }}')"
  if [ -n "$d" ]; then printf '%s' "$d"; else printf '%s' "a clone whose directory could not be read from its command line ($wcmd)"; fi
}

# ---------------------------------------------------------------------------
# Is a hold in force that covers THIS session? Read only, and expiry is the only thing that makes a
# marker stop counting. An UNREADABLE marker is not a hold: obeying one would silence this for as
# long as the bad file sits there, and that is the direction that loses a day of work. It is left on
# disk for claude-sync itself to report and clear, which it does in its own words.
#
# Only this session's own hold, or a terminal's, which records no session (claude-config#1886), the
# same question the payload write gate asks. Another session's hold is no remedy for this one: its
# edits are sent the moment that session releases, so the notice still speaks, and names whose
# hold it is.
sid="$(sc_payload_session "$input")"
hold_live(){ sc_hold_covers "$sid"; }

# ---------------------------------------------------------------------------
# The state this prompt is in, in one line. Everything that would change what the person needs to
# be told is in it, so a change in any of them speaks again and a repeat of the same state does not.
clone=""
if [ -z "$wcmd" ]; then
  state="no-watcher"
elif is_this_checkout; then
  state="editing-the-source $root"
elif sc_is_own_worktree "$root"; then
  # An agent's linked worktree on its own branch: nothing mirrors into it, the same answer the
  # payload write gate gives from the same shared question (claude-config#800, L370).
  state="own-worktree $root"
else
  clone="$(watcher_clone_name)"
  # Whose hold is in force is part of the state, so a hold another session takes or lifts while this
  # one is unprotected speaks again, naming who now holds it.
  others="$(sc_hold_others "$sid" | tr '\n' ' ')"
  if hold_live; then state="held $root $clone"; else state="warn $root $clone${others:+ $others}"; fi
fi

previous="$(cat "$STATE" 2>/dev/null || true)"
# Recorded BEFORE speaking, so a notice cannot repeat itself if anything below fails: the safe
# direction is saying it once too few rather than once per prompt for the rest of the session.
printf '%s\n' "$state" > "$STATE" 2>/dev/null || true

[ "$state" = "$previous" ] && exit 0
case "$state" in warn' '*) ;; *) exit 0 ;; esac
others_sentence="$(sc_hold_others_sentence "$sid")"

echo "claude-sync: this is a development checkout at $root, and a watch daemon is live on this Mac running from $clone. That daemon mirrors ~/.claude up over payload/ and pushes, so edits made to payload/ here are not merged with the config, they are overwritten by it, silently and with no conflict to notice. On 2026-09-03 it reverted 84 files of a day's work in one commit and deleted a file that existed only in the repo. Either edit ~/.claude directly, which needs no hold, or take a hold before editing here: claude-sync hold 120 \"why\". A hold expires, so afterwards make ~/.claude match what is in the checkout, or the next send reverts it again.${others_sentence:+ $others_sentence}"
exit 0
