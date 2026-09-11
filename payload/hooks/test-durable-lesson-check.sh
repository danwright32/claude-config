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

# 7b. A help invocation creates nothing, so there is no issue to draw a lesson from.
# This fired twice on 2026-07-29 for `gh issue create --help`.
T=$(mktemp -d)
out=$(run_hook "$(payload 'gh issue create --help')" "$T")
check "silent on --help" silent "$out"
T=$(mktemp -d)
out=$(run_hook "$(payload 'gh issue create -h')" "$T")
check "silent on -h" silent "$out"

# 7c. The override belongs to the command it prefixes, not to the whole call. Reading
# it across every segment lets a real create go unexamined.
T=$(mktemp -d)
out=$(run_hook "$(payload 'SKIP_LESSON_CHECK=1 gh issue create -t skipped && gh issue create -t "real one" -b b')" "$T")
check "override on one segment does not cover a later create" fires "$out"
T=$(mktemp -d)
out=$(run_hook "$(payload 'SKIP_LESSON_CHECK=1 gh issue create -t skipped
gh issue create -t "real one" -b b')" "$T")
check "override on line 1 does not cover a create on line 2" fires "$out"

# 7d. A create on a later LINE of a multi-line command is still a create.
T=$(mktemp -d)
out=$(run_hook "$(payload 'echo preparing
gh issue create -t "on line two" -b b')" "$T")
check "fires on a create on a later line" fires "$out"

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

# THE SHORT FORM. A lesson's rule sentence runs long because it carries the condition that makes
# it apply, and LESSONS-INDEX.md renders one line per lesson into every session in every project,
# where the platform warns past 150,000 characters (L429). About three quarters of the existing
# rules are too long for the cap, so a lesson written without a short form is the normal case, not
# the edge one. This instruction is the only thing that puts one there at the moment of writing;
# the send refuses to publish an over-cap lessons file, which is the guard behind it, because a
# rule that lives only in a prompt is a hope (L27).
T=$(mktemp -d)
out=$(run_hook "$(payload 'gh issue create -t x -b y')" "$T")
case "$out" in *'SHORT:'*) _has_short=1 ;; *) _has_short=0 ;; esac
if [ "$_has_short" = 1 ]; then
  PASS=$((PASS+1)); echo "PASS: instruction asks for a SHORT form on a rule too long for the index"
else
  FAIL=$((FAIL+1)); echo "FAIL: instruction says nothing about a SHORT form, so a new lesson arrives over the index cap and the send holds the whole lessons file back"
fi

# AND THE NUMBER IN IT IS THE REAL ONE. The instruction quotes the cap so a writer knows roughly
# what length to aim at, which makes it a SECOND copy of a number that already lives in
# test-rule-file-budget.sh. A document kept in step by a check on one token leaves the sentence
# beside it unverified, and the passing check makes that sentence MORE trusted rather than less
# (L210), so the quoted figure is compared against the cap itself.
T=$(mktemp -d)
out=$(run_hook "$(payload 'gh issue create -t x -b y')" "$T")
budget="$(dirname "${BASH_SOURCE[0]}")/test-rule-file-budget.sh"
realcap="$(awk -F= '/^ENTRY_CAP=[0-9]+$/ { print $2; exit }' "$budget" 2>/dev/null)"
if [ -z "$realcap" ]; then
  FAIL=$((FAIL+1)); echo "FAIL: could not read ENTRY_CAP from $budget, so the figure quoted in the instruction was compared against nothing"
elif case "$out" in *"$realcap characters today"*) true ;; *) false ;; esac; then
  PASS=$((PASS+1)); echo "PASS: the cap quoted in the instruction is the one the budget suite enforces ($realcap)"
else
  FAIL=$((FAIL+1)); echo "FAIL: the instruction quotes a different cap than the $realcap the budget suite enforces, so a lesson written to it is refused by the send"
fi

echo "----"
echo "passed $PASS, failed $FAIL"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
