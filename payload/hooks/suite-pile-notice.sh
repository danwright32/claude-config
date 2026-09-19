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
# FAILS QUIET. A notice must never stand in the way of a prompt, so every path exits 0, and anything
# it cannot read (the process table, its limits, its own library, the session, its record) means it
# says nothing on the prompt. A record it cannot write means it could not stay quiet next time, so it
# does not speak now either: once too few, never once per prompt (L36). Faults go to stderr, which
# the person does not see, and `claude-sync status` remains the place that reports in full.
#
# Env:
#   SYNC_SUITE_PILE_REARM         seconds of healthy samples that end a stretch (default 600)
#   SYNC_SUITE_MAX_AGE, SYNC_SUITE_MAX_ROOTS   the limits, shared with status (see the library)
#   SYNC_PS_FIXTURE               a process table to judge instead of the real one (tests, L2)
#   CLAUDE_SUITE_PILE_STATE_DIR   where each session's record is kept (default TMPDIR). Losing it
#                                 costs one repeated notice and nothing else.
#   CLAUDE_SUITE_PILE_NOW         the clock, as an epoch, so a test can cross the window (L290)
set -uo pipefail

input="$(cat 2>/dev/null || true)"

# The session, matched in bash rather than by starting python, because this runs on every prompt.
session=""
re_sid='"session_id"[[:space:]]*:[[:space:]]*"([^"]+)"'
re_tp='"transcript_path"[[:space:]]*:[[:space:]]*"([^"]+)"'
if [[ $input =~ $re_sid ]]; then session="${BASH_REMATCH[1]}"
elif [[ $input =~ $re_tp ]]; then session="${BASH_REMATCH[1]}"
fi
if [ -z "$session" ]; then
  echo "suite-pile-notice: the hook payload carried neither a session id nor a transcript path, so a first prompt cannot be told from a later one and nothing was checked." >&2
  exit 0
fi
key="${session//[^A-Za-z0-9_-]/_}"
[ "${#key}" -le 120 ] || key="${key: -120}"

LIB="$(dirname "${BASH_SOURCE[0]}")/lib/suite-pile.sh"
if [ ! -f "$LIB" ]; then
  echo "suite-pile-notice: $LIB is missing, so whether this repo's suites have piled up was not checked." >&2
  exit 0
fi
# shellcheck source=lib/suite-pile.sh
. "$LIB" 2>/dev/null || { echo "suite-pile-notice: $LIB could not be read, so nothing was checked." >&2; exit 0; }

# TEN MINUTES, and a chosen number rather than a measurement. It has to be long enough that suites
# starting and finishing around the breadth limit read as one stretch, and short enough that a pile
# killed and then rebuilt the same afternoon is said again. Being wrong costs one repeated notice in
# one direction, and a rebuilt pile going unsaid for up to ten minutes in the other.
SYNC_SUITE_PILE_REARM="${SYNC_SUITE_PILE_REARM:-600}"
case "$SYNC_SUITE_MAX_AGE$SYNC_SUITE_MAX_ROOTS$SYNC_SUITE_PILE_REARM" in
  ''|*[!0-9]*)
    echo "suite-pile-notice: SYNC_SUITE_MAX_AGE='$SYNC_SUITE_MAX_AGE', SYNC_SUITE_MAX_ROOTS='$SYNC_SUITE_MAX_ROOTS' and SYNC_SUITE_PILE_REARM='$SYNC_SUITE_PILE_REARM' must all be whole numbers, so nothing was checked." >&2
    exit 0 ;;
esac
now="${CLAUDE_SUITE_PILE_NOW:-}"
case "$now" in ''|*[!0-9]*) now="$(date +%s)" ;; esac

table="$(suite_pile_table)" || { echo "suite-pile-notice: the process table could not be read, so nothing was checked." >&2; exit 0; }
pile="$(printf '%s\n' "$table" | suite_pile_scan "$SYNC_SUITE_MAX_AGE" "$SYNC_SUITE_MAX_ROOTS")" \
  || { echo "suite-pile-notice: judging the process table failed, so nothing was checked." >&2; exit 0; }

STATE_DIR="${CLAUDE_SUITE_PILE_STATE_DIR:-${TMPDIR:-/tmp}}"
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
  echo "suite-pile-notice: could not write $STATE, so a pile was not said rather than said on every prompt." >&2
  exit 0
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
printf '%s\n' "$msg"
exit 0
