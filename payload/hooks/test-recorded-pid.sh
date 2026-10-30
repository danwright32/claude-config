#!/usr/bin/env bash
# Tests for lib/recorded-pid.sh (claude-config#1909): the one rule for a process id written down
# moments ago whose command line cannot vouch for it yet. PR #1897 found the scanners gate reading
# the empty command line a Linux process shows inside execve as "the run I recorded is gone", and
# fixed it there; this is that rule moved to one place, so every site that checks a recorded id by
# its command line applies the same one (L370).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/recorded-pid.sh"

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
eq(){ if [ "$2" = "$3" ]; then ok; else bad "$1 (wanted '$2', got '$3')"; fi; }

if [ ! -f "$LIB" ]; then
  echo "FAIL: there is no shared rule at $LIB, so each site that checks a recorded process id by its command line keeps its own copy, or none"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# Asked in a shell of its own each time, so nothing one case defines reaches the next.
young(){   # young <pid> <recorded at> -> the helper's exit code
  bash -c '. "$1"; recorded_pid_young "$2" "$3"; echo $?' _ "$LIB" "$1" "$2"
}
# The same, recorded <seconds> before the clock is read in that same shell, so the age is set by the
# case rather than by how long this suite took to reach it (L290).
young_ago(){   # young_ago <pid> <seconds> -> the helper's exit code
  bash -c '. "$1"; recorded_pid_young "$2" "$(( $(date +%s) - $3 ))"; echo $?' _ "$LIB" "$1" "$2"
}

now="$(date +%s)"
# A process of this suite's own, so nothing here can reach anything else, ended by the trap.
sleep 600 </dev/null >/dev/null 2>&1 &
LIVE=$!
trap 'kill -9 "$LIVE" 2>/dev/null' EXIT
# A pid that is certainly not running: one this suite started and has reaped.
sleep 0 & DEAD=$!; wait "$DEAD" 2>/dev/null

eq "#1909 the window is one minute, the setting #1897 chose" 60 "$(bash -c '. "$1"; printf %s "$RECORDED_PID_YOUNG"' _ "$LIB")"
eq "#1909 a running process recorded moments ago counts as itself" 0 "$(young_ago "$LIVE" 0)"
# Well inside the minute rather than at its edge, so a second ticking over between the two reads of
# the clock cannot carry it across.
eq "#1909 and so does one recorded 50 seconds ago" 0 "$(young_ago "$LIVE" 50)"
eq "#1909 one recorded 61 seconds ago does not" 1 "$(young_ago "$LIVE" 61)"
eq "#1909 nor one recorded an hour ago: its id may since belong to anything" 1 "$(young_ago "$LIVE" 3600)"
eq "#1909 a process that is not running never counts, however recently it was recorded" 1 "$(young_ago "$DEAD" 0)"
eq "#1909 a recording time in the future is not believed" 1 "$(young_ago "$LIVE" -3600)"
eq "#1909 an unreadable recording time is not believed" 1 "$(young "$LIVE" "")"
eq "#1909 nor one that is not a number" 1 "$(young "$LIVE" "soon")"
eq "#1909 an empty pid is not a process" 1 "$(young "" "$now")"
eq "#1909 nor one that is not a number" 1 "$(young "12x" "$now")"
# kill -0 0 signals this process's own group and succeeds, so 0 would read as running.
eq "#1909 and 0, which kill -0 answers for the whole process group, is not a process" 1 "$(young 0 "$now")"

# Every site that checks a recorded id by its command line takes the rule from here, never from a
# window of its own (L370, L613). A site's own copy of the minute is what this replaced.
for site in scanners-before-push.sh lib/suite-deadline.sh; do
  if grep -Eq '^[^#]*\. .*lib/recorded-pid\.sh|^[^#]*\. .*/recorded-pid\.sh' "$DIR/$site"; then ok
  else bad "#1909 $site takes the rule from lib/recorded-pid.sh"; fi
done
if grep -Eq '^[^#]*_SC_RUN_YOUNG' "$DIR/scanners-before-push.sh"; then
  bad "#1909 the scanners gate no longer keeps a young run window of its own"
else ok; fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
