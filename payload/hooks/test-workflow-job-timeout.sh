#!/usr/bin/env bash
# The one reader of a GitHub workflow job's timeout-minutes, asked directly (claude-config#1901).
#
# lib/workflow-job-timeout.sh is read by run-all-tests.sh, to hold a flake recheck to the CI job's
# own limit, and by tests/test-claude-sync.sh, to hold every job's timeout above the suite's
# ceiling. Both callers' suites drive it, but the second lives in tests/, which is not installed
# under ~/.claude/hooks. The edges belong here: which job's block a line belongs to, and that
# anything other than a plain whole number is read as no timeout rather than guessed at (L50).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/workflow-job-timeout.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$LIB" ]; then
  echo "FAIL: no reader at $LIB"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
. "$LIB"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.workflow-timeout.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-workflow-job-timeout: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

WF="$TMPROOT/wf.yml"
cat > "$WF" <<'YML'
name: fixture
on: [push]
env:
  timeout-minutes: 5
jobs:
  first:
    runs-on: ubuntu-26.04
    timeout-minutes: 40
    steps:
      - run: true
        timeout-minutes: 3
  second:
    runs-on: ubuntu-26.04
    steps:
      - run: true
  third:
    runs-on: ubuntu-26.04
    timeout-minutes: ${{ inputs.minutes }}
    steps:
      - run: true
  fourth:
    timeout-minutes: 90
    runs-on: ubuntu-26.04
YML

# 1. Every job is listed with its own limit, and a step's timeout or one outside jobs: is no job's.
got="$(workflow_job_timeouts "$WF")"
want="$(printf '%s\tfirst\t40\n%s\tsecond\tNONE\n%s\tthird\tNONE\n%s\tfourth\t90' "$WF" "$WF" "$WF" "$WF")"
[ "$got" = "$want" ] && check "each job is listed with its own timeout-minutes, and NONE where it has none" ok \
  || check "each job is listed with its own timeout-minutes, and NONE where it has none" "got: $got"

# 2. One job asked for by name.
m="$(workflow_job_timeout_minutes "$WF" first)"
[ "$m" = 40 ] && check "a job's minutes are read by its name" ok || check "a job's minutes are read by its name" "got '$m'"
m="$(workflow_job_timeout_minutes "$WF" fourth)"
[ "$m" = 90 ] && check "and a job whose timeout follows its runs-on line is read too" ok \
  || check "and a job whose timeout follows its runs-on line is read too" "got '$m'"

# 3. No answer is an answer of its own, never a number: a job with none, one holding an expression,
#    and a job that does not exist all fail and print nothing.
for j in second third nosuchjob; do
  m="$(workflow_job_timeout_minutes "$WF" "$j")"; rc=$?
  { [ "$rc" -ne 0 ] && [ -z "$m" ]; } && check "job '$j' has no readable timeout and says so by failing" ok \
    || check "job '$j' has no readable timeout and says so by failing" "rc=$rc got '$m'"
done

# 4. A file that is not there is no answer either.
m="$(workflow_job_timeout_minutes "$TMPROOT/absent.yml" first)"; rc=$?
{ [ "$rc" -ne 0 ] && [ -z "$m" ]; } && check "a workflow file that does not exist reads as no timeout" ok \
  || check "a workflow file that does not exist reads as no timeout" "rc=$rc got '$m'"

# 5. Several files at once, each job tagged with the file it came from.
WF2="$TMPROOT/wf2.yml"
printf 'jobs:\n  only:\n    timeout-minutes: 7\n' > "$WF2"
got="$(workflow_job_timeouts "$WF" "$WF2" | awk -F'\t' '$2 == "only" { print $1 "|" $3 }')"
[ "$got" = "$WF2|7" ] && check "several files are read, each job tagged with its own file" ok \
  || check "several files are read, each job tagged with its own file" "got: $got"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
