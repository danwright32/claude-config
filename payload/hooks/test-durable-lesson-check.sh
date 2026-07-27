#!/usr/bin/env bash
# Tests for durable-lesson-check.sh (PostToolUse Bash hook).
# Run: ./test-durable-lesson-check.sh   Exits nonzero on any failure.

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/durable-lesson-check.sh"
PASS=0
FAIL=0

payload() { printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"; }

run_hook() {
  # $1 payload json, $2 TMPDIR to use, remaining args are extra env VAR=val pairs
  local p="$1" tmp="$2"; shift 2
  printf '%s' "$p" | env -u CLAUDE_DETACHED_RUN TMPDIR="$tmp" CLAUDE_PROJECT_DIR="/fake/project" "$@" "$HOOK" 2>/dev/null
}

check() {
  # $1 description, $2 expected (fires|silent), $3 actual output
  local desc="$1" expected="$2" out="$3"
  local got="silent"
  printf '%s' "$out" | grep -q '"decision":"block"' && got="fires"
  if [ "$got" = "$expected" ]; then
    PASS=$((PASS+1)); echo "PASS: $desc"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $desc (expected $expected, got $got)"
  fi
}

if [ ! -x "$HOOK" ]; then
  echo "FAIL: hook not found or not executable at $HOOK"
  exit 1
fi

# 1. Fires on a plain gh issue create command.
T=$(mktemp -d)
out=$(run_hook "$(payload 'gh issue create --title "Bug in scout" --body "text"')" "$T")
check "fires on plain gh issue create" fires "$out"

# 2. Fires when the create is a later segment of a chain.
T=$(mktemp -d)
out=$(run_hook "$(payload 'git add -A && gh issue create -t "t" -b "b"')" "$T")
check "fires on chained segment" fires "$out"

# 3. Silent when the command merely mentions gh issue create in a payload.
T=$(mktemp -d)
out=$(run_hook "$(payload 'echo "run gh issue create later"')" "$T")
check "silent on payload mention" silent "$out"

# 4. Silent on gh issue list or other gh issue subcommands.
T=$(mktemp -d)
out=$(run_hook "$(payload 'gh issue list --state all')" "$T")
check "silent on gh issue list" silent "$out"

# 5. Silent when CLAUDE_DETACHED_RUN is set.
T=$(mktemp -d)
out=$(printf '%s' "$(payload 'gh issue create -t x')" | env TMPDIR="$T" CLAUDE_PROJECT_DIR="/fake/project" CLAUDE_DETACHED_RUN=1 "$HOOK" 2>/dev/null)
check "silent on detached run" silent "$out"

# 6. Silent with the documented SKIP_LESSON_CHECK=1 inline override.
T=$(mktemp -d)
out=$(run_hook "$(payload 'SKIP_LESSON_CHECK=1 gh issue create -t x')" "$T")
check "silent on SKIP_LESSON_CHECK=1" silent "$out"

# 7. Cooldown: a second create in the same window is silent (batch evaluates once).
T=$(mktemp -d)
out1=$(run_hook "$(payload 'gh issue create -t first')" "$T")
out2=$(run_hook "$(payload 'gh issue create -t second')" "$T")
check "first create in window fires" fires "$out1"
check "second create in window is silent" silent "$out2"

# 8. Fails quiet (exit 0, no output) on malformed payload.
T=$(mktemp -d)
out=$(printf 'not json at all' | env TMPDIR="$T" CLAUDE_PROJECT_DIR="/fake/project" "$HOOK" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  PASS=$((PASS+1)); echo "PASS: malformed payload fails quiet"
else
  FAIL=$((FAIL+1)); echo "FAIL: malformed payload (rc=$rc, out=${out:0:60})"
fi

# 9. The fired instruction names the lessons file and requires approval before editing it.
T=$(mktemp -d)
out=$(run_hook "$(payload 'gh issue create -t x -b y')" "$T")
if printf '%s' "$out" | grep -q 'LESSONS.md' && printf '%s' "$out" | grep -qi 'approval'; then
  PASS=$((PASS+1)); echo "PASS: instruction references LESSONS.md and approval"
else
  FAIL=$((FAIL+1)); echo "FAIL: instruction missing LESSONS.md or approval requirement"
fi

echo "----"
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
