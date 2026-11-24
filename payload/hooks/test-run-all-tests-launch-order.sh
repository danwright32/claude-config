#!/usr/bin/env bash
# Tests that the launch order of a full run does not depend on which lane a suite was given in the
# run before (claude-config#3388).
#
# The runner launches longest first and gives lane 1, the first launch, the largest share of the
# budget. A suite that divides its own work by that share (tests/test-claude-sync.sh,
# tests/test-hang-wait-suites-gate.sh, payload/hooks/test-gates-fail-closed.sh) finishes far sooner
# in lane 1: the sync suite took about 7 minutes there and 23 to 27 outside it on the 18 core Mac.
# The record kept only the last wall clock, so a run that gave it lane 1 recorded it as quick, the
# next run launched it third or sixth and recorded it as slow, and the order alternated across all
# nine runs measured on 2026-11-20 and 21 (#2589).
#
# Every fixture suite here finishes at once, so each one, launched first, measures what a sharding
# suite measures in lane 1: much less than its record from an ordinary lane. The records are seeded
# in the shape the runner writes, `<seconds> <checks> <share>`, and the store is read back with the
# runner's own key, so nothing here agrees with a scheme only this file believes in.
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

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.launch-order.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$TMPROOT'" >&2; exit 2 ;; esac
trap 'rm -rf "$TMPROOT"' EXIT

mk_suite() { # mk_suite <dir> <name> [seconds to sleep]   -- a suite that passes one check
  mkdir -p "$1"
  {
    printf '#!/usr/bin/env bash\n'
    [ -n "${3:-}" ] && printf 'sleep %s\n' "$3"
    printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'
  } > "$1/test-$2.sh"
  chmod +x "$1/test-$2.sh"
}
key() { printf '%s' "suites/test-$1.sh" | sed 's/%/%25/g; s#/#%2F#g'; }   # the runner's suite_key
record() { cat "$1/$(key "$2")" 2>/dev/null; }                            # record <store> <name>
order_of() { printf '%s\n' "$1" | sed -n 's/^run-all-tests: launch order: //p' | awk 'END { print }'; }
# Four suites against four lanes at a budget of 8, so lane 1 is granted 4 slots and the others 2, 1
# and 1. Every run keeps out of the real cache, the flaky output store and this Mac's full suite slot.
run_fixture() { # run_fixture <root> <store> [budget] [jobs]
  env -u HOOK_TESTS_BUDGET -u HOOK_TESTS_JOBS HOOK_TESTS_ROOT="$1" HOOK_TESTS_TIMINGS="$2" \
    HOOK_TESTS_FLAKY_OUTPUT= HOOK_TESTS_SLOT=0 HOOK_TESTS_BUDGET="${3:-8}" HOOK_TESTS_JOBS="${4:-4}" \
    bash "$RUNNER" "$1/suites" 2>&1
}

# ---------------------------------------------------------------------------
# The order holds still across runs (the issue's own done line).
# ---------------------------------------------------------------------------
# `lead` is seeded at 5 seconds in an ordinary lane, `runnerup` at 3 (records this file writes, not
# measured). `runnerup` is the larger
# FILE, so a runner whose records all read 0 after one quick run orders by size and puts it first:
# that is the flip, reproduced without a minute of real waiting.
FX="$TMPROOT/flip"
ST="$TMPROOT/flip-store"
mkdir -p "$ST"
for n in lead runnerup q1 q2; do mk_suite "$FX/suites" "$n"; done
printf '# %s\n' "$(head -c 400 /dev/zero | tr '\0' 'x')" >> "$FX/suites/test-runnerup.sh"
printf '5 1 1\n' > "$ST/$(key lead)"
printf '3 1 1\n' > "$ST/$(key runnerup)"
printf '0 1 1\n' > "$ST/$(key q1)"
printf '0 1 1\n' > "$ST/$(key q2)"

out_a="$(run_fixture "$FX" "$ST")"; code_a=$?
order_a="$(order_of "$out_a")"
# The control: the seeded records are read as measurements, so the first run leads with `lead`.
# Without it, every check below could pass on a runner that ignored the store (L159).
[ "$code_a" -eq 0 ] && case "$order_a" in "test-lead.sh "*) true ;; *) false ;; esac \
  && check "the control: the first run leads with the suite recorded slowest" ok \
  || check "the control: the first run leads with the suite recorded slowest" "exit=$code_a order='$order_a' out=$out_a"

out_b="$(run_fixture "$FX" "$ST")"; code_b=$?
order_b="$(order_of "$out_b")"
case "$order_b" in
  "test-lead.sh "*) check "#3388 a suite that ran quickly in lane 1 still leads the next run" ok ;;
  *) check "#3388 a suite that ran quickly in lane 1 still leads the next run" "order was '$order_b', after '$order_a'; lead's record now reads '$(record "$ST" lead)'" ;;
esac
out_c="$(run_fixture "$FX" "$ST")"
order_c="$(order_of "$out_c")"
[ -n "$order_b" ] && [ "$order_c" = "$order_b" ] \
  && check "#3388 and two runs back to back of an unchanged tree launch in the same order" ok \
  || check "#3388 and two runs back to back of an unchanged tree launch in the same order" "'$order_b' then '$order_c'"

# The record keeps the share its figure was measured at, so a lane 1 time is never read as one from
# an ordinary lane. Five seconds at one slot (seeded above, not measured), then under a second at
# four slots: four slots cannot
# make a suite more than four times quicker, so its time at one slot is at most 4 seconds (the
# measurement rounds down, so one second more than it read), and that is what is kept.
case "$(record "$ST" lead)" in
  '4 1 1') check "#3388 lead's record keeps its one slot time, bounded by what four slots measured" ok ;;
  *) check "#3388 lead's record keeps its one slot time, bounded by what four slots measured" "it reads '$(record "$ST" lead)', expected '4 1 1'" ;;
esac

# And the run that led correctly says nothing about it. The check that names a wrong lead judged
# THIS run's wall clock, so a lead that finished quickly because it had lane 1 was named as wrong on
# every run that got the order right (L11, L36).
case "$out_a$out_b" in
  *"launched first is not the one"*) check "#3388 a lead that finished quickly in lane 1 is not reported as the wrong lead" "out=$out_a $out_b" ;;
  *) check "#3388 a lead that finished quickly in lane 1 is not reported as the wrong lead" ok ;;
esac

# ---------------------------------------------------------------------------
# A figure that is provably stale is brought down, so a suite that really got faster gives lane 1 up.
# ---------------------------------------------------------------------------
# Without the bound a suite holding lane 1 could never be measured anywhere else, and a figure from
# before it got quicker would keep lane 1 for it for good.
FX2="$TMPROOT/stale"
ST2="$TMPROOT/stale-store"
mkdir -p "$ST2"
for n in lead runnerup q1 q2; do mk_suite "$FX2/suites" "$n"; done
printf '50 1 1\n' > "$ST2/$(key lead)"
printf '3 1 1\n' > "$ST2/$(key runnerup)"
run_fixture "$FX2" "$ST2" >/dev/null
case "$(record "$ST2" lead)" in
  '4 1 1') check "#3388 a figure four slots prove too high is brought down to what they allow" ok ;;
  *) check "#3388 a figure four slots prove too high is brought down to what they allow" "it reads '$(record "$ST2" lead)', expected '4 1 1'" ;;
esac

# ---------------------------------------------------------------------------
# A suite that got slower even with the larger share raises its figure.
# ---------------------------------------------------------------------------
# More of the machine never makes a suite slower, so a time at four slots is also a floor for its
# time at one. One second of real sleep, the least that reads as more than zero.
FX3="$TMPROOT/slower"
ST3="$TMPROOT/slower-store"
mkdir -p "$ST3"
mk_suite "$FX3/suites" only 1
printf '0 1 1\n' > "$ST3/$(key only)"
run_fixture "$FX3" "$ST3" 4 4 >/dev/null
rec3="$(record "$ST3" only)"
read -r r3_sec r3_checks r3_share r3_rest <<< "$rec3"
if [ -n "${r3_sec:-}" ] && [ "${r3_share:-}" = 1 ] && [ -z "${r3_rest:-}" ] \
  && case "$r3_sec" in *[!0-9]*) false ;; *) [ "$r3_sec" -ge 1 ] ;; esac; then
  check "#3388 a suite slower at four slots than its one slot figure raises that figure" ok
else
  check "#3388 a suite slower at four slots than its one slot figure raises that figure" "it reads '$rec3', expected at least '1 1 1'"
fi

# ---------------------------------------------------------------------------
# A measurement at a smaller share than the figure's replaces it.
# ---------------------------------------------------------------------------
# One suite alone is granted the whole budget, so a budget of 4 measures it at four slots, which is
# closer to an ordinary lane than the eight its record was measured at.
FX4="$TMPROOT/smaller"
ST4="$TMPROOT/smaller-store"
mkdir -p "$ST4"
mk_suite "$FX4/suites" only
printf '50 1 8\n' > "$ST4/$(key only)"
run_fixture "$FX4" "$ST4" 4 4 >/dev/null
case "$(record "$ST4" only)" in
  '0 1 4') check "#3388 a measurement at a smaller share replaces a figure from a larger one" ok ;;
  *) check "#3388 a measurement at a smaller share replaces a figure from a larger one" "it reads '$(record "$ST4" only)', expected '0 1 4'" ;;
esac

# A record written before the share was kept has no third field, so nothing says what share its
# seconds were measured at. It is replaced by the next measurement, the way every record was before
# (L255): a reader refusing it would make the first run after this ships a cold start.
printf '50 1\n' > "$ST4/$(key only)"
run_fixture "$FX4" "$ST4" 4 4 >/dev/null
case "$(record "$ST4" only)" in
  '0 1 4') check "#3388 a record with no share is replaced by the next measurement and its share" ok ;;
  *) check "#3388 a record with no share is replaced by the next measurement and its share" "it reads '$(record "$ST4" only)', expected '0 1 4'" ;;
esac

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
