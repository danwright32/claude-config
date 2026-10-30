#!/usr/bin/env bash
#
# suite-pile-notice.sh: say, in the session, when this repo's test suites have piled up on this Mac
# (claude-config#466).
#
# On 2026-09-18 559 suite processes ran for up to seven hours at zero CPU, the machine sat at load
# 272, and every session on it was slow. PR #462 taught `claude-sync status` to report it, and
# nobody runs status while a pile is slowing them down, which is how that one ran seven hours
# unnoticed. A number nobody is shown is not a detector (L357), so this runs on UserPromptSubmit,
# which is where a person working is.
#
# IT COPIES NO PREDICATE. What a pile is, and the sentences describing one, are
# hooks/lib/suite-pile.sh, which `claude-sync status` calls too, so the two cannot disagree about
# the same machine (L41, L370). It names the same `kill -9` line status names.
#
# CHEAP, because it runs on every prompt in every project: one `ps` and one `awk`, no claude-sync,
# no network, no lock. Measured on this Mac, recorded in DESIGN.md beside SYNC_SUITE_PILE_REARM.
#
# ONCE PER STRETCH, PER SESSION. A stretch starts when a pile is first seen and ends only once no
# pile has been seen for SYNC_SUITE_PILE_REARM seconds of healthy samples in a row, so a pile that
# flickers across the breadth limit as suites start and finish is one stretch, not one notice per
# flicker (L160). A pile that is still there hours later is the same stretch however long nobody
# prompted, since nothing healthy was seen in between. Per session, because a session that was never
# told has not been told.
#
# FAILS OPEN, OUT LOUD. A notice must never stand in the way of a prompt, so every path exits 0, and
# anything it cannot read (the process table, its limits, its own library, the session, its record)
# means it says nothing about a pile on the prompt. A record it cannot write means it could not stay
# quiet next time, so it does not speak of the pile now either: once too few, never once per prompt
# (L36). Each such fault is said as a systemMessage (#1906). It used to go to stderr, which the hooks
# documentation says Claude Code discards on exit 0, so the person never saw it; a UserPromptSubmit
# hook's plain stdout reaches only Claude, and its systemMessage is not among those the documentation
# says are discarded. Each fault is said ONCE PER SESSION for each kind of fault (#1931): #1906 said a
# lasting fault on every prompt while it lasted, and a notice repeated on every prompt is the one a
# person learns to skip (L36). A different fault in the same session is new, and is said. The one
# fault said on every prompt is a payload with no session, since without one there is no session to
# be told once (sync-stuck-notice.sh says that one the same way). `claude-sync status` remains the
# place that reports in full.
#
# Env:
#   SYNC_SUITE_PILE_REARM         seconds of healthy samples that end a stretch (default 600)
#   SYNC_SUITE_MAX_AGE, SYNC_SUITE_MAX_ROOTS   the limits, shared with status (see the library)
#   SYNC_PS_FIXTURE               a process table to judge instead of the real one (tests, L2)
#   CLAUDE_SUITE_PILE_STATE_DIR   where each session's record is kept (default TMPDIR). Losing it
#                                 costs one repeated notice and nothing else.
#   CLAUDE_SUITE_PILE_NOW         the clock, as an epoch, so a test can cross the window (L290)
set -uo pipefail

# Cut in bash, since this runs on every prompt; a bare name (run from its own folder) is ".".
case "${BASH_SOURCE[0]}" in */*) SPN_DIR="${BASH_SOURCE[0]%/*}" ;; *) SPN_DIR=. ;; esac
# shellcheck source=lib/hook-notice.sh
. "$SPN_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }

input="$(cat 2>/dev/null || true)"
# Cleaned by the shared reader when it loads: a lone surrogate escape anywhere in the payload
# (an emoji cut in half is enough) makes jq read none of it (claude-config#1944). Without the
# library the payload is read as it came, as before.
case "${BASH_SOURCE[0]}" in */*) _ps_dir="${BASH_SOURCE[0]%/*}" ;; *) _ps_dir=. ;; esac
. "$_ps_dir/lib/push-scope.sh" 2>/dev/null && input="$(ps_clean_payload "$input")"

# The session, matched in bash rather than by starting python, because this runs on every prompt.
session=""
re_sid='"session_id"[[:space:]]*:[[:space:]]*"([^"]+)"'
re_tp='"transcript_path"[[:space:]]*:[[:space:]]*"([^"]+)"'
# Under a UTF-8 locale bash's =~ stops at a byte that is not UTF-8, so each is also looked for in the
# C locale, which reads every byte as a character (claude-config#1885).
payload_match() { [[ $1 =~ $2 ]] && return 0; local LC_ALL=C; [[ $1 =~ $2 ]]; }
if payload_match "$input" "$re_sid"; then session="${BASH_REMATCH[1]}"
elif payload_match "$input" "$re_tp"; then session="${BASH_REMATCH[1]}"
fi
if [ -z "$session" ]; then
  hook_allow_notice "suite-pile-notice: the hook payload carried neither a session id nor a transcript path, so a first prompt cannot be told from a later one and nothing was checked."
fi
key="${session//[^A-Za-z0-9_-]/_}"
[ "${#key}" -le 120 ] || key="${key: -120}"
STATE_DIR="${CLAUDE_SUITE_PILE_STATE_DIR:-${TMPDIR:-/tmp}}"

# fault_once <kind> <notice>: say a fault of this hook's own, once per session for each kind, and let
# the prompt through. The record is a marker file per session and kind, kept beside the pile record,
# or in TMPDIR when that directory is the thing that cannot be written. With nowhere to keep it, the
# fault is said on this prompt and the next, since a fault nobody hears is what #1906 closed.
fault_once() {
  local d m
  for d in "$STATE_DIR" "${TMPDIR:-/tmp}"; do
    m="${d%/}/claude-suite-pile-${key}.fault-$1"
    [ -e "$m" ] && exit 0
    { mkdir -p "$d" && : > "$m"; } 2>/dev/null && break
  done
  hook_allow_notice "$2 This is said once in this session."
}

LIB="$(dirname "${BASH_SOURCE[0]}")/lib/suite-pile.sh"
if [ ! -f "$LIB" ]; then
  fault_once lib-missing "suite-pile-notice: $LIB is missing, so whether this repo's suites have piled up was not checked."
fi
# shellcheck source=lib/suite-pile.sh
. "$LIB" 2>/dev/null || fault_once lib-unreadable "suite-pile-notice: $LIB could not be read, so nothing was checked."

# TEN MINUTES, and a chosen number rather than a measurement. It has to be long enough that suites
# starting and finishing around the breadth limit read as one stretch, and short enough that a pile
# killed and then rebuilt the same afternoon is said again. Being wrong costs one repeated notice in
# one direction, and a rebuilt pile going unsaid for up to ten minutes in the other.
SYNC_SUITE_PILE_REARM="${SYNC_SUITE_PILE_REARM:-600}"
case "$SYNC_SUITE_MAX_AGE$SYNC_SUITE_MAX_ROOTS$SYNC_SUITE_PILE_REARM" in
  ''|*[!0-9]*)
    fault_once settings "suite-pile-notice: SYNC_SUITE_MAX_AGE='$SYNC_SUITE_MAX_AGE', SYNC_SUITE_MAX_ROOTS='$SYNC_SUITE_MAX_ROOTS' and SYNC_SUITE_PILE_REARM='$SYNC_SUITE_PILE_REARM' must all be whole numbers, so nothing was checked." ;;
esac
now="${CLAUDE_SUITE_PILE_NOW:-}"
case "$now" in ''|*[!0-9]*) now="$(date +%s)" ;; esac

table="$(suite_pile_table)" || fault_once table "suite-pile-notice: the process table could not be read, so nothing was checked."
pile="$(printf '%s\n' "$table" | suite_pile_scan "$SYNC_SUITE_MAX_AGE" "$SYNC_SUITE_MAX_ROOTS")" \
  || fault_once judge "suite-pile-notice: judging the process table failed, so nothing was checked."

STATE="$STATE_DIR/claude-suite-pile-${key}.state"
# The record: "told <epoch the last pile was seen> <epoch healthy samples began, or ->".
told=0; healthy_since="-"
if [ -f "$STATE" ]; then
  read -r word _last healthy_since < "$STATE" 2>/dev/null || true
  [ "${word:-}" = told ] && told=1
  case "${healthy_since:-}" in ''|*[!0-9]*) healthy_since="-" ;; esac
fi
over(){ [ "$healthy_since" != "-" ] && [ $(( now - healthy_since )) -ge "$SYNC_SUITE_PILE_REARM" ]; }

if [ -z "$pile" ]; then
  [ "$told" -eq 1 ] || exit 0
  if over; then rm -f "$STATE" 2>/dev/null || true
  elif [ "$healthy_since" = "-" ]; then printf 'told %s %s\n' "$now" "$now" > "$STATE" 2>/dev/null || true
  fi
  exit 0
fi

# A pile. Said when this session has not been told of one, or when the last stretch it was told of
# has since ended.
speak=1
[ "$told" -eq 1 ] && ! over && speak=0
# Recorded BEFORE speaking, and a record that will not write means silence: the safe direction is
# saying it once too few, not once per prompt for the rest of the session.
if ! { mkdir -p "$STATE_DIR" && printf 'told %s -\n' "$now" > "$STATE"; } 2>/dev/null; then
  fault_once record "suite-pile-notice: could not write $STATE, so a pile was not said rather than said on every prompt."
fi
[ "$speak" -eq 1 ] || exit 0

summary="$(printf '%s\n' "$pile" | suite_pile_summary "$SYNC_SUITE_MAX_AGE" "$SYNC_SUITE_MAX_ROOTS" | tr '\n' ' ')"
kill="$(printf '%s\n' "$pile" | suite_pile_kill_pids)"
msg="claude-sync: this repo's test suites have piled up on this Mac, which slows every session on it and presents as slowness rather than as a failure. ${summary}"
status_says="claude-sync status lists them."
if [ -n "$kill" ]; then
  n="$(printf '%s\n' "$kill" | wc -w | tr -d ' ')"
  # Up to fifty pids are named here. Past that the line is status's to print in full, rather than a
  # partial kill line that reads as the whole of it.
  if [ "$n" -le 50 ]; then
    msg="${msg}To stop the ones past that age (a plain kill is held by a suite blocked on a child, so this is -9): kill -9 ${kill}. "
  else
    status_says="claude-sync status lists them, with the kill -9 line for all $n past that age, which is too long to put here."
  fi
fi
msg="${msg}${status_says} This is said once in this session, and again only if the pile clears for ${SYNC_SUITE_PILE_REARM}s and comes back."
# A deliberate load window running or just ended is named beside it (claude-config#1618): on
# 2026-10-23 one overlapped four builders' full suites and nothing said so. Read from
# lib/load-window.sh's record, which tools/load-window.sh writes; a lib that will not load adds nothing.
if . "$(dirname "${BASH_SOURCE[0]}")/lib/load-window.sh" 2>/dev/null; then
  wn="$(load_window_note "$now")"
  [ -z "$wn" ] || msg="${msg} ${wn}"
fi
printf '%s\n' "$msg"
exit 0
