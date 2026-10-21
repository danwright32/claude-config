#!/usr/bin/env bash
# The shared load average reader, asked directly (claude-config#1083 follow up).
#
# lib/load-average.sh arrived in #1094 and was exercised only through its callers: the runner's own
# suite set its figure through the seam, and the two suites that named it live in tests/ and tools/,
# which are not installed under ~/.claude/hooks. The installed coverage check therefore saw a hook
# with no suite at all, after a pull that CI had passed.
#
# What it decides is the sentence printed beside every failure, so both directions matter: calling
# a quiet machine busy sends a reader to rerun a real failure, and calling a busy one quiet leaves
# a load caused failure reading as broken code. And an unreadable figure must never come out as a
# number, least of all a zero, which reads as an idle machine (L90).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/load-average.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
is() { [ "$2" = "$3" ] && check "$1" ok || check "$1" "wanted [$2], got [$3]"; }

if [ ! -f "$LIB" ]; then
  echo "FAIL: no reader at $LIB"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
. "$LIB"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.loadavg.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-load-average: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT
says() { # says <name> <what it prints>  -> a command printing exactly that
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$2" > "$TMPROOT/$1"; chmod +x "$TMPROOT/$1"
  printf '%s' "$TMPROOT/$1"
}

# ---- the figure, through the seam ----
unset LOAD_AVERAGE_CMD LOAD_AVERAGE_CORES
is "the seam's figure is what is read" "12.75" "$(LOAD_AVERAGE_CMD="$(says high 12.75)" load_average_one_minute)"
is "a command passed as the argument wins over the seam" "3.5" \
  "$(LOAD_AVERAGE_CMD="$(says env 12.75)" load_average_one_minute "$(says arg 3.5)")"
is "a figure that is not a number reads as nothing, never as a zero" "" \
  "$(LOAD_AVERAGE_CMD="$(says junk 'load: high')" load_average_one_minute)"
is "two lines read as nothing rather than a guess at which one" "" \
  "$(LOAD_AVERAGE_CMD="$(says two '1.0
2.0')" load_average_one_minute)"
is "a command that prints nothing reads as nothing" "" \
  "$(LOAD_AVERAGE_CMD="$(says empty '')" load_average_one_minute)"

# ---- the figure, from this machine ----
# Read where it can be: /proc/loadavg on Linux (CI), sysctl on a Mac. Neither present is said, not
# failed, since it is the machine and not the reader that lacks it (L411).
real="$(load_average_one_minute)"
if [ -r /proc/loadavg ] || sysctl -n vm.loadavg >/dev/null 2>&1; then
  case "$real" in
    ''|*[!0-9.]*) check "this machine's own load average is read as a number" "got [$real]" ;;
    *) check "this machine's own load average is read as a number" ok ;;
  esac
else
  echo "SUITE-PART-UNMEASURED this machine has neither /proc/loadavg nor sysctl vm.loadavg, so the live read is not exercised here"
fi

# ---- the cores ----
is "the core count can be set" "8" "$(LOAD_AVERAGE_CORES=8 load_average_cores)"
is "a core count that is not a whole number reads as nothing" "" "$(LOAD_AVERAGE_CORES=eight load_average_cores)"
is "a core count of zero reads as nothing, since nothing can be judged against it" "" "$(LOAD_AVERAGE_CORES=0 load_average_cores)"
real_cores="$(load_average_cores)"
case "$real_cores" in
  ''|*[!0-9]*|0) check "this machine's own core count is a whole number above zero" "got [$real_cores]" ;;
  *) check "this machine's own core count is a whole number above zero" ok ;;
esac

# ---- the sentence ----
busy="more than this machine has cores"
is "a figure over the core count says so" \
  "load average 37.5 on 8 cores, $busy, so a timing or load sensitive check may have measured the machine: run it again alone before treating it as broken" \
  "$(load_average_note 37.5 8)"
# The boundary, both sides: equal to the cores is a fully used machine, not an oversubscribed one.
is "a figure equal to the core count is not called busy" "load average 8 on 8 cores" "$(load_average_note 8 8)"
over="$(load_average_note 8.01 8)"
case "$over" in
  *"$busy"*) check "a figure just over it is" ok ;;
  *) check "a figure just over it is" "got [$over]" ;;
esac
is "a quiet machine's figure is printed plainly" "load average 1.25 on 8 cores" "$(load_average_note 1.25 8)"
is "an unreadable figure is said, never shown as a number" \
  "load average could not be read, so whether the machine was busy is unknown" "$(load_average_note "" 8)"
is "an unreadable core count is said, and the figure is not judged" \
  "load average 4.5 (the core count could not be read, so it is not judged against one)" "$(load_average_note 4.5 "")"
# With no arguments it reads both itself, through the same seams.
is "with no arguments it reads the figure and the cores itself" "load average 9.5 on 4 cores, $busy, so a timing or load sensitive check may have measured the machine: run it again alone before treating it as broken" \
  "$(LOAD_AVERAGE_CMD="$(says nine 9.5)" LOAD_AVERAGE_CORES=4 load_average_note)"

# ---- the one predicate (claude-config#1259) ----
# Whether the machine was busier than it has cores is decided once, here, for the sentence above
# and for the sync suite's budgets, which no longer fail a run on a machine past it. A caller may
# name load of its own (the suite's shards) that is taken off first, since its own work competing
# with itself is what a budget exists to see.
busy_is(){ if load_average_busy "$@"; then printf busy; else printf quiet; fi; }
is "a figure over the cores is busy" busy "$(busy_is 59.86 12)"
is "a figure equal to the cores is not" quiet "$(busy_is 12 12)"
is "a figure just over the cores is" busy "$(busy_is 12.01 12)"
is "the caller's own load is taken off first: 15 on 12 cores with 4 of its own is not busy" quiet "$(busy_is 15 12 4)"
is "and 17 with 4 of its own is" busy "$(busy_is 17 12 4)"
is "the 2026-10-16 reading, 59.86 on 12 cores with the suite's 4 shards, is busy" busy "$(busy_is 59.86 12 4)"
# A figure it cannot judge is never called busy: busy excuses a failure, so an unreadable reading
# must not be the thing that excuses one (L90).
is "an unreadable figure is not busy" quiet "$(busy_is '' 12)"
is "an unreadable core count is not busy" quiet "$(busy_is 59.86 '')"
is "a figure that is not a number is not busy" quiet "$(busy_is high 12)"
is "own load that is not a number is not busy either, never read as zero" quiet "$(busy_is 59.86 12 four)"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
