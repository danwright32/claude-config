#!/usr/bin/env bash
# Tests for the DEFAULT process budget run-all-tests.sh derives from the core count when
# HOOK_TESTS_BUDGET is unset (claude-config#2548).
#
# It was the cores capped at 8, so the work MacBook's 18 cores got the same 8 as the personal
# MacBook's 12. Now every machine of up to 12 cores keeps what it had (the CI runner's 2, the 12
# core Mac's 8), and above that the budget grows to two thirds of the cores, the share the 12 core
# Mac has run at since the cap was set (#130, 2026-08-21). The core count is set through
# HOOK_TESTS_CORES, the runner's seam for it, and every value is read back from the line the runner
# prints, which is the line a person reads to see what a run is doing (L442).
#
# Its own file rather than more lines in test-run-all-tests.sh, which #2463 is splitting.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$DIR/run-all-tests.sh"

. "$DIR/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [ "$2" = "ok" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.runner-budget.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$TMPROOT'" >&2; exit 2 ;; esac
trap 'rm -rf "$TMPROOT"' EXIT

# Two trivial suites, so the runner has something to divide the budget between.
FX="$TMPROOT/suites"
mkdir -p "$FX"
for n in one two; do
  printf '#!/usr/bin/env bash\nprintf "SUITE-RESULT passed=1 failed=0\\n"\n' > "$FX/test-$n.sh"
  chmod +x "$FX/test-$n.sh"
done

# Every run here removes any budget or job count the calling run exported, or that would decide
# instead of the core count, and keeps the timing record out of the real cache.
run_with_cores(){ env -u HOOK_TESTS_BUDGET -u HOOK_TESTS_JOBS HOOK_TESTS_TIMINGS= HOOK_TESTS_CORES="$1" bash "$RUNNER" "$FX" 2>&1; }
# The budget the runner said, read as the whole number ending its line, so a 12 never passes for 1.
budget_said(){ printf '%s\n' "$1" | sed -n 's/^run-all-tests: .* against a budget of \([0-9][0-9]*\)$/\1/p' | awk 'NR == 1'; }

# The reader itself, seen to fail (L1): a line saying 12 is not read as 1.
said="$(budget_said "run-all-tests: up to 6 suite(s) at once, so at most 12 process(es) at once, against a budget of 12")"
[ "$said" = 12 ] && check "the reader takes the whole number, so 12 is not read as 1" ok \
  || check "the reader takes the whole number, so 12 is not read as 1" "read '$said'"

for pair in 1:1 2:2 4:4 8:8 9:8 12:8 13:8 16:10 18:12 24:16; do
  cores="${pair%%:*}"; want="${pair##*:}"
  out="$(run_with_cores "$cores")"; code=$?
  said="$(budget_said "$out")"
  if [ "$code" -eq 0 ] && [ "$said" = "$want" ]; then check "$cores cores give a default budget of $want" ok
  else check "$cores cores give a default budget of $want" "exit=$code budget='$said' out=$out"; fi
done

# A budget set by hand still wins over the derived one.
out="$(env -u HOOK_TESTS_JOBS HOOK_TESTS_TIMINGS= HOOK_TESTS_BUDGET=4 HOOK_TESTS_CORES=18 bash "$RUNNER" "$FX" 2>&1)"
said="$(budget_said "$out")"
[ "$said" = 4 ] && check "HOOK_TESTS_BUDGET still overrides the derived budget" ok \
  || check "HOOK_TESTS_BUDGET still overrides the derived budget" "budget='$said' out=$out"

# A core count nobody can read is refused and named, never guessed at: it decides how many
# processes start (L50).
for bad in many 1.5 -3 0 ''; do
  out="$(run_with_cores "$bad")"; code=$?
  case "$code:$out" in
    0:*) check "a core count of '$bad' is refused" "exit=0 out=$out" ;;
    *"HOOK_TESTS_CORES='$bad'"*) check "a core count of '$bad' is refused, and named" ok ;;
    *) check "a core count of '$bad' is refused, and named" "exit=$code out=$out" ;;
  esac
done

# The control: with no seam set the runner still reads this machine's own core count and runs, so
# every refusal above is the seam's, not a runner refusing everything (L159).
out="$(env -u HOOK_TESTS_BUDGET -u HOOK_TESTS_JOBS -u HOOK_TESTS_CORES HOOK_TESTS_TIMINGS= bash "$RUNNER" "$FX" 2>&1)"; code=$?
case "$code:$out" in
  0:*"against a budget of "*) check "the control: with no seam the runner reads the real core count and runs" ok ;;
  *) check "the control: with no seam the runner reads the real core count and runs" "exit=$code out=$out" ;;
esac

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
