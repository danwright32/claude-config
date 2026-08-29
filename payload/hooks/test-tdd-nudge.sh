#!/usr/bin/env bash
# Tests for tdd-nudge.sh (UserPromptSubmit hook).
# Run: ./test-tdd-nudge.sh   Exits nonzero on any failure.
#
# The hook is a fixed line of context, so the contract worth pinning is what that line
# POINTS AT: the test-first skill, and the recorded test speed lessons. A pointer that quietly
# names a section LESSONS.md no longer has would send every coding turn to nothing, so the
# section name is checked against the real lessons file, not against this test's own guess.

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tdd-nudge.sh"
LESSONS="${LESSONS_FILE:-$HOME/.claude/LESSONS.md}"
PASS=0
FAIL=0

check() {
  # $1 desc, $2 condition result (0 = pass)
  if [ "$2" -eq 0 ]; then PASS=$((PASS+1)); echo "PASS: $1"
  else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi
}

out="$(printf '{}' | "$HOOK" 2>/dev/null)"
status=$?
check "the hook exits 0" "$status"

printf '%s' "$out" | grep -qF 'superpowers:test-driven-development'
check "it still names the test-first skill" $?

printf '%s' "$out" | grep -qF '## Test speed'
check "it points a coding turn at the Test speed lessons section" $?

printf '%s' "$out" | grep -qF 'LESSONS-INDEX.md'
check "it names the index the section is read from" $?

# The section it names must exist in the lessons file, or the pointer is a dead link that
# reads as guidance (L41: a list mirroring another source is derived from it, or it drifts).
grep -qE '^## Test speed[[:space:]]*$' "$LESSONS"
check "LESSONS.md actually has a '## Test speed' section" $?

# No dashes as punctuation and no emoji in what every prompt receives (the style rule applies
# to generated output, and this text lands in every session).
if printf '%s' "$out" | grep -q $'—\|–'; then check "no em or en dash in the injected text" 1
else check "no em or en dash in the injected text" 0; fi

echo "passed: $PASS, failed: $FAIL"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
