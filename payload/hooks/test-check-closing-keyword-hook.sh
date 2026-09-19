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

# --- the detector's own reader (claude-config#486) -----------------------------
#
# The negation detector is python3 and nothing asked whether python3 was installed. Without it the
# findings came back empty, the emptiness test passed, and this gate exited 0 on exactly the
# phrasing it exists to stop, with nothing said (L490, L42, L98).
. "$DIR/lib/no-python-path.sh"
NOPY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/check-closing-nopy.XXXXXXXX")"
NOPY="$NOPY_ROOT/bin"
# jq linked in, so the payload is still legible and only the detector's interpreter is gone.
npp_build_bin "$NOPY" jq
if npp_reaches_python3 "$NOPY"; then
  fail=$((fail+1)); echo "FAIL: the bare directory really reaches no python3 (it found one, so nothing below measures its absence)"
else pass=$((pass+1)); fi

# run_nopy <description> <expected-exit> <command-string> [needle the message must carry]
run_nopy() {
  local desc="$1" want="$2" command="$3" needle="${4:-}"
  local payload msg got
  payload="$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"command": sys.argv[1]}, "cwd": "/tmp"}))
' "$command")"
  msg="$(printf '%s' "$payload" | env PATH="$NOPY" "$NOPY/bash" "$HOOK" 2>&1 >/dev/null)"; got=$?
  if [ "$got" -eq "$want" ]; then pass=$((pass+1));
  else fail=$((fail+1)); echo "FAIL: $desc (wanted exit $want, got $got)"; fi
  if [ -n "$needle" ]; then
    case "$msg" in
      *"$needle"*) pass=$((pass+1)) ;;
      *) fail=$((fail+1)); echo "FAIL: $desc: the message did not name [$needle], said: $msg" ;;
    esac
  fi
}

# A body with NO negation in it at all, on purpose: nothing here can tell the two apart, so the
# refusal comes from the detector being absent rather than from anything it found (L11).
run_nopy "with no python3 a pr create is refused rather than passed unread" $BLOCK \
  'gh pr create --title x --body "Part of #897, which stays open."' 'python3'
run_nopy "and a commit is refused the same way" $BLOCK \
  'git commit -m "Part of #897, which stays open."'
# A command the missing detector takes nothing from is not refused (L54, L324).
run_nopy "a push cannot link an issue, so it is not refused over a detector it never needed" $ALLOW \
  'git push -u origin branch'
# The documented override still clears it (L109).
run_nopy "the visible override still clears the missing detector refusal" $ALLOW \
  'SKIP_CLOSING_CHECK=1 gh pr create --title x --body "Part of #897, which stays open."'
# The control, the same command with python3 present: allowed, so the refusals above are the
# detector's absence and not a fixture that refuses everything (L159).
run "the control still allows the same pr create with python3 present" $ALLOW \
  'gh pr create --title x --body "Part of #897, which stays open."'

rm -rf "$NOPY_ROOT"

echo
echo "passed: $pass   failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
