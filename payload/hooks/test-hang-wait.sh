#!/usr/bin/env bash
# Tests for lib/hang-wait.sh (claude-config#1620): the one ceiling every suite's wait on a condition
# gives up at. Its ceiling is a hang ceiling, so the case that reaches it is run with the override
# set to one second rather than waited out; every other case waits on a condition the test sets.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/hang-wait.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.hangwait.XXXXXXXX")" || W=""
case "${W%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$W'" >&2; exit 2 ;; esac
trap 'rm -rf "$W"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
eq(){ if [ "$2" = "$3" ]; then ok; else bad "$1 (wanted '$2', got '$3')"; fi; }

eq "#1620 the default ceiling is 300 seconds" 300 "$(env -u SUITE_HANG_SECONDS bash -c ". '$LIB'; printf %s \"\$HANG_S\"")"
eq "#1620 SUITE_HANG_SECONDS sets it for one run" 7 "$(SUITE_HANG_SECONDS=7 bash -c ". '$LIB'; printf %s \"\$HANG_S\"")"
eq "#1620 a value that is not a whole number is not believed" 300 "$(SUITE_HANG_SECONDS=soon bash -c ". '$LIB'; printf %s \"\$HANG_S\"")"

# A condition already true returns at once with 0.
eq "#1620 a condition already true is met" 0 "$(bash -c ". '$LIB'; hang_wait true; echo \$?")"
# A condition that becomes true while it waits: a background step creates the file it waits for,
# released by the wait having started, so nothing here is timed.
rc="$(bash -c ". '$LIB'; ( until [ -e '$W/started' ]; do sleep 0.05; done; : > '$W/ready' ) & : > '$W/started'; hang_wait \"[ -e '$W/ready' ]\" 0.05; echo \$?")"
eq "#1620 a condition that becomes true while it waits is met" 0 "$rc"
# One that never holds gives up at the ceiling, here set to one second, with 1.
eq "#1620 a condition that never holds gives up at the ceiling with 1" 1 "$(SUITE_HANG_SECONDS=1 bash -c ". '$LIB'; hang_wait false 0.05; echo \$?")"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
