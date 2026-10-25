#!/usr/bin/env bash
#
# hang-wait.sh: the one ceiling a suite's wait on a condition gives up at (claude-config#1620).
#
# A wait on a condition needs a ceiling, or a broken fixture hangs the suite instead of failing it.
# What it must never be is a JUDGEMENT OF SPEED: a ceiling of a few seconds is reached by a loaded
# Mac with nothing broken (L290). On 2026-10-23 test-derived-data-sweep.sh's 30 s ceiling failed 16
# of 16 loaded copies (#1577), and the same shape sat in five more suites (#1620): 5, 20, 30, 40
# and 60 second ceilings, written as a `date +%s` plus a few seconds or a `sleep 0.1` loop of tens
# to hundreds of ticks. So every such wait takes its ceiling from here, one number only a hang
# reaches, as the mod tests take theirs from mod-kit's hang-ceiling.ts (#1577).
#
# THE NUMBER. 300 seconds, a setting rather than a measurement, the same the derived data sweep's
# suite took for #1577: the waits it bounds end in well under a second on a quiet Mac, and 300 is
# ten times the 30 s ceiling that 16 of 16 loaded copies of that suite ran past with nothing broken
# (2026-10-23). What each converted suite does under load is in #1620's pull request, not here, so
# this sentence cannot go stale as they change. A suite's own wall clock deadline
# (lib/suite-deadline.sh, 1200 s by default) stays the outer bound. SUITE_HANG_SECONDS overrides it
# for one run, which is how a control proves a wait still fails, quickly, when what it waits for
# never comes.
#
# Sourced, never executed. The clock is bash's own SECONDS, so a wait forks nothing per look but
# its condition and its sleep.

HANG_S="${SUITE_HANG_SECONDS:-300}"
case "$HANG_S" in ''|*[!0-9]*) HANG_S=300 ;; esac

# hang_wait <condition> [poll]: evaluates the condition (a shell string) until it succeeds, sleeping
# <poll> seconds (0.1) between looks. Returns 0 once it holds, 1 once HANG_S seconds have passed
# without it.
hang_wait(){
  local _hw_t0=$SECONDS _hw_poll="${2:-0.1}"
  until eval "$1"; do
    [ $(( SECONDS - _hw_t0 )) -lt "$HANG_S" ] || return 1
    sleep "$_hw_poll"
  done
  return 0
}

# window_wait <seconds> <condition> [poll]: the other kind of wait (claude-config#1679), for a
# condition the PASSING case is never meant to meet: a window a fault is given to show itself in,
# which a sound run always runs out. Its length is the caller's, stated at the call, because it is
# not a ceiling: reaching it is the expected outcome, and load can only make the window miss a
# fault, never fail a run with nothing broken. Returns 0 if the condition held inside the window, 1
# once it passed without it, 2 for a length that is not a whole number of seconds. A wait for
# something the passing case DOES meet takes hang_wait, and test-hand-rolled-wait.sh fails a suite
# that hand rolls either.
window_wait(){
  local _ww_t0=$SECONDS _ww_s="${1:-}" _ww_poll="${3:-0.1}"
  case "$_ww_s" in ''|*[!0-9]*) echo "window_wait: the window must be a whole number of seconds, not '$_ww_s'" >&2; return 2 ;; esac
  until eval "$2"; do
    [ $(( SECONDS - _ww_t0 )) -lt "$_ww_s" ] || return 1
    sleep "$_ww_poll"
  done
  return 0
}
