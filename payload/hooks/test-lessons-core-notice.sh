#!/usr/bin/env bash
# Tests for lessons-core-notice.sh (claude-config#564): when the lessons core list is unusable and
# the whole library loads instead, the session is TOLD, once, in its own words. A fallback only the
# sync's output mentions reaches nobody, since the sync runs unattended (L357).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/lessons-core-notice.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:600}"; fi; }
check_eq(){ if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '${3:0:300}')"; fi; }

export CLAUDE_HOME="$WORK/home"; mkdir -p "$CLAUDE_HOME"
export LESSONS_CORE_NOTICE_DIR="$WORK/shown"
fire(){ printf '{"session_id":"%s","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$1" | bash "$HOOK" 2>&1; }

# No state at all (a Mac that has not run this version of the sync): silent.
check_eq "no recorded state says nothing" "" "$(fire s1)"
# Not in use: silent.
echo inactive > "$CLAUDE_HOME/.lessons-core-state"
check_eq "a core not in use says nothing" "" "$(fire s1)"
# In use: silent.
echo "active 150 19800 chars" > "$CLAUDE_HOME/.lessons-core-state"
check_eq "a core in use says nothing" "" "$(fire s1)"
# Fallen back: said, with the reason and the remedy.
echo "fallback shrunk 1 of 150" > "$CLAUDE_HOME/.lessons-core-state"
out="$(fire s1)"
check "a fallback is said in the session" "whole library" "$out"
check "with its reason" "shrunk 1 of 150" "$out"
check "and the command that fixes it" "claude-sync core-set" "$out"
check_eq "once per session" "" "$(fire s1)"
check "but every other session hears it" "whole library" "$(fire s2)"
# A different fallback is a new thing to say, even in a session that heard the first.
echo "fallback unreadable" > "$CLAUDE_HOME/.lessons-core-state"
check "a new reason is said again" "unreadable" "$(fire s1)"
# A state file that cannot be read is said, never taken as healthy (L98).
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$CLAUDE_HOME/.lessons-core-state"
  check "an unreadable state record is said" "could not be read" "$(fire s3)"
  chmod 644 "$CLAUDE_HOME/.lessons-core-state"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
