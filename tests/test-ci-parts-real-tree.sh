#!/usr/bin/env bash
# The real tree, dealt into the parts CI runs as separate jobs (claude-config#2463): every suite
# git tracks is in exactly one part, and every part has work. A suite in no part would run in no
# job and read as a pass (L96, L98). The count it is held to is git's, not the runner's discovery,
# so the two readings are independent. The deal is the runner's HOOK_TESTS_DEAL, which runs no
# suite, so this stays cheap enough for the push gate that runs every suite listing the repository
# (scanners-before-push.sh). How the deal refuses, and the workflow that uses it, are held in
# tests/test-ci-workflow.sh.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
RUNNER="$ROOT/payload/hooks/run-all-tests.sh"
WF="$ROOT/.github/workflows/tests.yml"

pass=0; fail=0
check(){ if [[ "$2" == "ok" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

# A copy with no repository has nothing tracked to compare against.
if ! git -C "$ROOT" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo "SUITE-NOT-RUN $ROOT is not a git checkout, so what it tracks cannot be read"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 0
fi

# How many parts the workflow deals into, read from the deal job's own setting, never restated.
parts="$(sed 's/[[:space:]]#.*$//' "$WF" | awk '/^[[:space:]]*HOOK_TESTS_DEAL:[[:space:]]*[0-9]+[[:space:]]*$/ { print $2; exit }')"
case "$parts" in
  ''|*[!0-9]*|0) check "#2463 the workflow's number of parts is read from HOOK_TESTS_DEAL" "read '$parts'"; parts=4 ;;
  *) check "#2463 the workflow's number of parts is read from HOOK_TESTS_DEAL ($parts)" ok ;;
esac

real_deal="$(HOOK_TESTS_ROOT="$ROOT" HOOK_TESTS_TIMINGS= HOOK_TESTS_DEAL="$parts" bash "$RUNNER" 2>/dev/null)"; rc=$?
tracked="$(git -C "$ROOT" ls-files | grep -E '(^|/)test-[^/]*\.sh$' | grep -v '^payload/hooks/run-all-tests\.sh$' | sort)"
dealt="$(printf '%s\n' "$real_deal" | awk -F'\t' 'NF >= 2 { print $2 }' | sort)"
dupes="$(printf '%s\n' "$dealt" | uniq -d | head -3 | tr '\n' ' ')"
missing="$(comm -23 <(printf '%s\n' "$tracked") <(printf '%s\n' "$dealt" | sort -u) | head -3 | tr '\n' ' ')"
[ "$rc" -eq 0 ] && [ -n "$tracked" ] && [ -z "$missing" ] \
  && check "#2463 every tracked suite ($(printf '%s\n' "$tracked" | grep -c .)) is dealt to some part of the real tree" ok \
  || check "#2463 every tracked suite is dealt to some part of the real tree" "rc=$rc, in no part: ${missing:-none}"
[ -z "$dupes" ] && [ -n "$dealt" ] \
  && check "#2463 and none is dealt twice" ok \
  || check "#2463 and none is dealt twice" "twice: ${dupes:-nothing dealt}"
want="$(seq 1 "$parts" | tr '\n' ' ')"
parts_used="$(printf '%s\n' "$real_deal" | awk -F'\t' 'NF >= 2 { print $1 }' | sort -n -u | tr '\n' ' ')"
[ "$parts_used" = "$want" ] \
  && check "#2463 and each of the $parts parts has work, and no other part exists" ok \
  || check "#2463 and each of the $parts parts has work, and no other part exists" "parts: '$parts_used'"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
