#!/bin/bash
# mod-kit's withinGrace, seen holding a real call end to end, and seen failing without it (#2039, L1).
#
# A guard's catch gets 1,000 ms from the engine. A catch that spends its own time and then waits on
# something the engine does not count as a $ call is cut at the grace, and the call it was guarding
# RUNS. withinGrace (payload/mods/mod-kit/hooks/hold.ts) checks how much of the grace is left before
# the slow part starts, and holds the call when too little is. Its unit tests hand in a budget; this
# suite drives the engine itself, through tests/catch-grace-probe, a stand-in guard whose catch uses
# its time up to the reserve:
#   - the real hold.ts: the control call (no withinGrace) runs, proving the stand-in overruns, and the
#     checked call is held with "it ran out of time";
#   - a stub hold.ts whose withinGrace always runs the work: the checked call must FAIL, so a helper
#     that stops checking is caught here, not only in its unit tests.
# The fixture holds no hold.ts of its own: each arm copies the real one (or its stub) into a temporary
# copy, so this never tests a stale committed copy.
#
# Needs Claude Code's `claude plugin test`; without a claude command (CI's Linux runner) the suite
# says UNMEASURED and why (L411).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}

FIXTURE="$DIR/catch-grace-probe"
HOLD="$ROOT/payload/mods/mod-kit/hooks/hold.ts"
CEILING="$ROOT/payload/mods/mod-kit/tests/hang-ceiling.ts"
CONTROL='control: a catch whose slow part runs past the grace is cut, and the call runs unguarded'
HELD='withinGrace holds the call when the grace is nearly spent, with the could not check words'

CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || true)}"
if [ -z "$CLAUDE_BIN" ]; then
  echo "SUITE-PART-UNMEASURED withinGrace holding a call end to end: there is no claude command on PATH to run claude plugin test with"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-catch-grace.XXXXXX")" || { check "a temporary folder" "mktemp failed"; printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# arm <folder name> <hold.ts to use>: a temporary copy of the fixture holding that hold.ts; prints the
# suite's whole output.
arm(){
  local copy="$WORK/$1"
  cp -R "$FIXTURE" "$copy" && cp "$2" "$copy/hooks/hold.ts" && cp "$CEILING" "$copy/tests/hang-ceiling.ts" || {
    echo "COPY FAILED"
    return
  }
  "$CLAUDE_BIN" plugin test "$copy" 2>&1
}

# The real helper: both tests pass.
real="$(arm real "$HOLD")"
for name in "$CONTROL" "$HELD"; do
  case "$real" in
    *"(pass) $name"*) check "with the real hold.ts: $name" ok ;;
    *) check "with the real hold.ts: $name" "no (pass) line for it; the suite said: $(printf '%s\n' "$real" | tail -6 | tr '\n' ' ')" ;;
  esac
done

# The stub: withinGrace always runs the work. The stub must really differ from the real file, or the
# arm below proves nothing (L100).
sed 's#^): R | Promise<R> => (budget.remainingMs >= reserveMs ? work() : outOfTime())$#): R | Promise<R> => work()#' "$HOLD" >"$WORK/stub-hold.ts"
if cmp -s "$HOLD" "$WORK/stub-hold.ts"; then
  check "the stub withinGrace differs from the real one" "the sed matched nothing in hold.ts, so there is no stub to run against; update the expression to withinGrace's body"
else
  check "the stub withinGrace differs from the real one" ok
  stub="$(arm stub "$WORK/stub-hold.ts")"
  case "$stub" in
    *"(fail) $HELD"*) check "against a withinGrace that always runs the work, the held test fails" ok ;;
    *) check "against a withinGrace that always runs the work, the held test fails" "no (fail) line for it; the suite said: $(printf '%s\n' "$stub" | tail -6 | tr '\n' ' ')" ;;
  esac
  case "$stub" in
    *"(pass) $CONTROL"*) check "against the stub, the control still passes" ok ;;
    *) check "against the stub, the control still passes" "no (pass) line for it; the suite said: $(printf '%s\n' "$stub" | tail -6 | tr '\n' ' ')" ;;
  esac
fi

printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
