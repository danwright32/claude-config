#!/usr/bin/env bash
# Tests for tdd-nudge.sh (UserPromptSubmit hook).
# Run: ./test-tdd-nudge.sh   Exits nonzero on any failure.
#
# The hook is a fixed line of context, so the contract worth pinning is what that line
# POINTS AT: the test-first skill, and the recorded test speed lessons. A pointer that quietly
# names a section LESSONS.md no longer has would send every coding turn to nothing, so the
# section name is checked against the real lessons file, not against this test's own guess.

set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tdd-nudge.sh"
# The REPO's lessons file, not the deployed copy under the config directory. This read
# `$HOME/.claude/LESSONS.md`, which is where the sync PUTS this file, and a CI runner has no
# such copy: `grep` on a path that is not there exits 1, so "the runner has no deployed config"
# and "the section the hook points at has been renamed" produced the same red line, and every
# push to main since 2026-08-29 carried it. This repo is where the file is maintained, so this is
# the copy whose headings the hook's pointer has to agree with (L41), and it is present wherever
# the suite can run at all.
LESSONS="${LESSONS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/LESSONS.md}"
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

grep -qF 'superpowers:test-driven-development' <<< "$out"
check "it still names the test-first skill" $?

grep -qF '## Test speed' <<< "$out"
check "it points a coding turn at the Test speed lessons section" $?

grep -qF 'LESSONS-INDEX.md' <<< "$out"
check "it names the index the section is read from" $?

# Whether the file is THERE is asked first, and separately. Without this, an absent file answers
# the question below in the same word as a renamed section, and the reader is sent to look for a
# heading that is exactly where it always was (L11, L98).
[ -f "$LESSONS" ]
check "the lessons file the pointer is checked against is present at $LESSONS" $?

# The section it names must exist in the lessons file, or the pointer is a dead link that
# reads as guidance (L41: a list mirroring another source is derived from it, or it drifts).
if [ -f "$LESSONS" ]; then
  grep -qE '^## Test speed[[:space:]]*$' "$LESSONS"
  check "LESSONS.md actually has a '## Test speed' section" $?
else
  check "LESSONS.md actually has a '## Test speed' section" 1
fi

# No dashes as punctuation and no emoji in what every prompt receives (the style rule applies
# to generated output, and this text lands in every session).
if grep -q $'\u2014\|\u2013' <<< "$out"; then check "no em or en dash in the injected text" 1
else check "no em or en dash in the injected text" 0; fi

echo "passed: $PASS, failed: $FAIL"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
