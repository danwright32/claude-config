#!/usr/bin/env bash
# WHOLE-HOOK tests for check-closing-keyword.sh: feeds it real PreToolUse payloads and asserts
# the exit code, rather than testing the detector in isolation.
#
# This layer exists because of a real miss. The detector had 26 green assertions and the hook
# still had a defect the detector could never see: the MATCHER scanned the entire command
# string, so it fired on any command whose PAYLOAD merely quoted a PR-creation command. It
# blocked its own issue-closing comment, whose body quoted the broken phrasing as an example.
#
# A command and a command's payload are different things. The detector cannot tell them apart,
# because it never sees the shell. Only this layer can.
#
# Run with SKIP_CLOSING_CHECK=1, since every payload here necessarily contains the exact
# phrasing the hook exists to block.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-closing-keyword.sh"

pass=0
fail=0

# run <description> <expected-exit> <command-string>
run() {
  local desc="$1" want="$2" command="$3"
  local payload got
  payload="$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"command": sys.argv[1]}, "cwd": "/tmp"}))
' "$command")"
  printf '%s' "$payload" | "$HOOK" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    echo "FAIL: $desc (wanted exit $want, got $got)"
  fi
}

BLOCK=2
ALLOW=0

# --- The bug this hook exists for ---
run "a PR body that negates a close"  $BLOCK 'gh pr create --title x --body "It does not close #897, which stays open."'
run "a commit message that negates"   $BLOCK 'git commit -m "this does not fix #12"'
run "a PR edit that negates"          $BLOCK 'gh pr edit 12 --body "does not resolve #5"'

# --- A genuine close must sail through, or the hook is useless ---
run "a real close"                    $ALLOW 'gh pr create --title x --body "Closes #897."'
run "the safe phrasing"               $ALLOW 'gh pr create --title x --body "Part of #897, which stays open."'
run "an ordinary commit"              $ALLOW 'git commit -m "#897: fix the ratchet only"'

# --- A command is not its payload ---
#
# The miss that created this file. Each of these CONTAINS the forbidden phrasing, and even
# contains the text of a PR-creation command, but none of them can close anything.
run "an issue comment quoting a pr create" $ALLOW \
  'gh issue close 912 --comment "example: gh pr create --body \"does not close #897\" is blocked"'
run "an issue comment discussing it"       $ALLOW \
  'gh issue comment 912 --body "this does not close #897 and that is the bug"'
run "a plain echo of the phrasing"         $ALLOW \
  'echo "gh pr create --body \"does not close #897\""'
run "a grep for the phrasing"              $ALLOW \
  'grep -r "does not close #897" .'

# --- Commands that cannot link an issue at all ---
run "a push"     $ALLOW 'git push -u origin branch'
run "a pr view"  $ALLOW 'gh pr view 914 --json state'

# --- The override, and failing open ---
run "the documented override" $ALLOW \
  'SKIP_CLOSING_CHECK=1 gh pr create --title x --body "It does not close #897."'
run "an env-prefixed real command still blocked" $BLOCK \
  'GH_TOKEN=abc gh pr create --title x --body "It does not close #897."'

echo
echo "passed: $pass   failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
