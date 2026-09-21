#!/usr/bin/env bash
#
# take-section-time-reading.sh: take ONE section time reading in a quiet window and append it to the
# committed record (claude-config#520).
#
# The margin recorded above SUITE_WORK_BUDGET_PCT in the sync suite is a paragraph, and the sync
# suite holds that paragraph to the readings in tests/section-time-readings.tsv, so it cannot drift
# from the data. What nothing did was take a FRESH reading, so the premise behind the budget was
# still a dated sentence somebody has to trust (L316). This is what the monthly launch agent runs.
#
# A reading is a whole suite run, fifteen to thirty minutes, so it WAITS for the machine to be
# quiet by the measurer's own standard rather than competing with whoever is working, and it
# refuses rather than reporting a number taken on a busy machine.
#
# Usage: take-section-time-reading.sh
#   SECTION_TIME_MEASURER   the measurer (default: tools/measure-section-time.sh beside this file)
#   SECTION_TIME_RECORD     the record to append to (default: tests/section-time-readings.tsv)
#   SECTION_TIME_LOG        where to write what happened (default: ~/.claude-section-time.log)
#   SECTION_TIME_WAIT       seconds to wait for a quiet window (default 7200)
#   SECTION_TIME_LOCK       the lock file (default: beside the record)
#
# It appends to a file in the working tree and commits nothing. That is deliberate: a fresh reading
# makes the suite fail until the paragraph is updated to match, which is the drift being caught
# rather than sitting (claude-config#520), and a job that committed would be writing the repository
# from a launch agent nobody is watching.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # before any cd (L372)
REPO="$(cd "$HERE/.." && pwd)"
MEASURER="${SECTION_TIME_MEASURER:-$HERE/measure-section-time.sh}"
RECORD="${SECTION_TIME_RECORD:-$REPO/tests/section-time-readings.tsv}"
LOG="${SECTION_TIME_LOG:-$HOME/.claude-section-time.log}"
WAIT="${SECTION_TIME_WAIT:-7200}"
LOCK="${SECTION_TIME_LOCK:-$RECORD.reading.lock}"

say(){ printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG"; }

[ -x "$MEASURER" ] || { say "section-time: no measurer at $MEASURER, so no reading was taken."; exit 1; }

# One reading at a time: two readings at once measure each other, and each is a whole suite run.
# mkdir is the atomic test-and-set, and the lock names the process holding it so a stale one can be
# told from a live one (L444).
if ! mkdir "$LOCK" 2>/dev/null; then
  say "section-time: a reading is already running (lock $LOCK held by pid $(cat "$LOCK/pid" 2>/dev/null || printf 'unknown')), so this one did nothing."
  exit 0
fi
printf '%s\n' "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# The wait is bounded by the clock AND by a sample count, because the measurer stops at whichever
# comes first and a wait bounded only by the clock is unbounded work when sampling is cheap (L704).
# The measurer samples every ten seconds, so the count has to cover the whole wait or the wait ends
# early and silently.
samples=$(( WAIT / 10 + 60 ))

say "section-time: taking a reading, waiting up to ${WAIT}s for a quiet window. Record: $RECORD"
out="$(MEASURE_RECORD="$RECORD" MEASURE_WAIT_SECONDS="$WAIT" MEASURE_WAIT_MAX_SAMPLES="$samples" \
       MEASURE_RUNS="${SECTION_TIME_RUNS:-3}" "$MEASURER" 2>&1)"; rc=$?
printf '%s\n' "$out" >> "$LOG"
if [ "$rc" -ne 0 ]; then
  say "section-time: the measurer refused (exit $rc), so no reading was taken this time. The record is unchanged."
  exit "$rc"
fi
say "section-time: reading appended to $RECORD. The sync suite now fails until the paragraph above SUITE_WORK_BUDGET_PCT quotes these readings, which is the point of taking it."
exit 0
