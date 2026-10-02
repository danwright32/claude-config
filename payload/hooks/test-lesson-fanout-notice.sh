#!/usr/bin/env bash
# Tests for lesson-fanout-notice.sh: the hook that asks for lib/lesson-fanout.sh to be run when a
# lesson appears that this Mac has not fanned out yet.
#
# Seams, all set: CLAUDE_HOME (a temp dir holding LESSONS.md, the ledger and the cooldown stamp),
# LESSON_FANOUT_NOW (the clock, so the cooldown is tested without waiting, L524). The hook makes
# no network call, so there is nothing else to fake.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/lesson-fanout-notice.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() { if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: $3"; fi; }
check_eq() { if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi; }

unset CLAUDE_DETACHED_RUN LESSON_FANOUT_OFF

world() {
  export CLAUDE_HOME="$TMP/$1"
  mkdir -p "$CLAUDE_HOME/state"
  cat >"$CLAUDE_HOME/LESSONS.md" <<'MD'
## Section

- **L1. First rule.** Why.
- **L2. Second rule,
  wrapped.** Why.
MD
}
add_lesson() { printf -- '- **L%s. Rule %s.** Why.\n' "$1" "$1" >>"$CLAUDE_HOME/LESSONS.md"; }
run() { out="$(echo '{}' | LESSON_FANOUT_NOW="${NOW:-1000}" bash "$HOOK" 2>&1)"; rc=$?; }
LEDGER() { cat "$CLAUDE_HOME/state/lesson-fanout.done" 2>/dev/null; }

# 1. first run seeds the ledger with what already exists and says nothing
world seed
run
check_eq "seed: exit 0" "0" "$rc"
check_eq "seed: silent" "" "$out"
check "seed: L1 recorded as baseline" "L1 baseline" "$(LEDGER)"
check "seed: L2 recorded as baseline" "L2 baseline" "$(LEDGER)"

# 2. a new lesson is announced with the exact command
world fresh
run
add_lesson 3
NOW=2000 run
check_eq "fresh: exit 0" "0" "$rc"
check "fresh: blocks so the session acts on it" '"decision":"block"' "$out"
check "fresh: names the lesson and the command" "lesson-fanout.sh L3" "$out"
echo "$out" | jq -e . >/dev/null 2>&1; check_eq "fresh: output is valid JSON" "0" "$?"

# 3. several pending lessons go in one command, in order
world several
run
add_lesson 10; add_lesson 9
NOW=2000 run
check "several: both, sorted by number" "lesson-fanout.sh L9 L10" "$out"

# 4. nothing pending, nothing said
world done
run
add_lesson 3
echo "L3 abc" >>"$CLAUDE_HOME/state/lesson-fanout.done"
NOW=2000 run
check_eq "done: silent" "" "$out"

# 5. cooldown: asked once, not again inside the window, again after it
world cool
run
add_lesson 3
NOW=2000 run
NOW=2100 run
check_eq "cool: silent inside the window" "" "$out"
NOW=3000 run
check "cool: asks again after the window, since it is still not done" "lesson-fanout.sh L3" "$out"

# 6. headless runs and the override say nothing and change nothing
world headless
run
add_lesson 3
out="$(echo '{}' | CLAUDE_DETACHED_RUN=1 LESSON_FANOUT_NOW=2000 bash "$HOOK" 2>&1)"
check_eq "headless: silent" "" "$out"
out="$(echo '{}' | LESSON_FANOUT_OFF=1 LESSON_FANOUT_NOW=2000 bash "$HOOK" 2>&1)"
check_eq "override: silent" "" "$out"

# 7. no lessons file: quiet, and no ledger made from nothing
world missing
rm "$CLAUDE_HOME/LESSONS.md"
run
check_eq "missing: exit 0" "0" "$rc"
check_eq "missing: silent" "" "$out"
check_eq "missing: no ledger seeded from an absent file" "" "$(LEDGER)"

printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
