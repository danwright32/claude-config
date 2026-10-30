#!/usr/bin/env bash
# Tests for lib/bounded-run.sh, the one bound check-free-space.sh's `top` and free-space-nudge.sh's
# Xcode sweep share (claude-config#1770).
#
# What has to hold: a command inside its bound hands back what it printed and its exit code; one
# that outlives the bound is stopped with everything it started, and says 124; and a bound of 0,
# which perl's alarm would read as no bound at all, runs nothing. Judged by state (what came back,
# what is still running), never by how many seconds a run took (L290).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/hang-wait.sh" || { echo "FAIL: lib/hang-wait.sh is missing"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
. "$DIR/lib/bounded-run.sh" || { echo "FAIL: lib/bounded-run.sh is missing"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/bounded-run.XXXXXXXX")" || TMP=""
case "${TMP%/}" in
  ''|/|"${HOME%/}") echo "test-bounded-run: refusing to run: throwaway directory came back as '$TMP'." >&2; exit 2 ;;
esac
trap ': > "$TMP/release"; rm -rf "$TMP"' EXIT

# Inside the bound: the output, standard error included, and the exit code come back as they were.
bounded_run 30 sh -c 'echo out; echo err >&2; exit 3'
check "a command inside its bound hands back what it printed, standard error included" \
  "$([ "$BOUNDED_OUT" = "$(printf 'out\nerr')" ] && echo ok || echo "got: $BOUNDED_OUT")"
check "and its own exit code" "$([ "$BOUNDED_RC" -eq 3 ] && echo ok || echo "rc $BOUNDED_RC")"

# Past the bound: a command that starts a child and then holds until released. When bounded_run
# returns, both must be gone, which is untrue only if the group was not killed. The child does not
# hold the capture open, so a bound that killed only the parent returns at once with the child
# still running, rather than waiting for it and hiding the fault. The hold has a ceiling only a
# hang reaches, so a broken bound still ends.
HOLD="$TMP/hold.sh"
cat > "$HOLD" <<SH
#!/bin/sh
( n=0; while [ ! -e "$TMP/release" ] && [ "\$n" -lt $((HANG_S * 10)) ]; do sleep 0.1; n=\$((n + 1)); done ) > /dev/null 2>&1 &
echo "\$!" > "$TMP/child.pid"
echo "\$\$" > "$TMP/parent.pid"
n=0; while [ ! -e "$TMP/release" ] && [ "\$n" -lt $((HANG_S * 10)) ]; do sleep 0.1; n=\$((n + 1)); done
echo "should never be printed"
SH
chmod +x "$HOLD"
bounded_run 1 "$HOLD"
running=""
for pidfile in "$TMP/parent.pid" "$TMP/child.pid"; do
  p="$(cat "$pidfile" 2>/dev/null || true)"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && running="$running $p"
done
: > "$TMP/release"
check "a command past its bound comes back as 124" "$([ "$BOUNDED_RC" -eq 124 ] && echo ok || echo "rc $BOUNDED_RC, said: $BOUNDED_OUT")"
check "and it and the child it started are both gone when it returns" \
  "$([ -f "$TMP/child.pid" ] && [ -z "$running" ] && echo ok || echo "still running:${running:- none, but no child pid was written}")"
check "and nothing it would have printed after the bound arrives" \
  "$(! grep -qF 'should never be printed' <<< "$BOUNDED_OUT" && echo ok || echo "said: $BOUNDED_OUT")"

# A bound of 0 or one that is not a number runs nothing and says so, rather than running unbounded.
rm -f "$TMP/ran"
bounded_run 0 sh -c ": > '$TMP/ran'"
check "a bound of 0 runs nothing and comes back as 125" \
  "$([ "$BOUNDED_RC" -eq 125 ] && [ ! -e "$TMP/ran" ] && echo ok || echo "rc $BOUNDED_RC, ran: $([ -e "$TMP/ran" ] && echo yes || echo no)")"
bounded_run abc sh -c ": > '$TMP/ran'"
check "a bound that is not a number runs nothing either" \
  "$([ "$BOUNDED_RC" -eq 125 ] && [ ! -e "$TMP/ran" ] && echo ok || echo "rc $BOUNDED_RC")"
# Zero written with leading zeros is zero (claude-config#1931). "00" passed the check for a literal
# 0 and reached perl's alarm, which reads it as 0 and so set no bound at all: the command ran
# unbounded, the one outcome this library exists to prevent.
for zero in 00 000; do
  bounded_run "$zero" sh -c ": > '$TMP/ran'"
  check "a bound of $zero runs nothing and comes back as 125, never unbounded" \
    "$([ "$BOUNDED_RC" -eq 125 ] && [ ! -e "$TMP/ran" ] && echo ok || echo "rc $BOUNDED_RC, ran: $([ -e "$TMP/ran" ] && echo yes || echo no)")"
  rm -f "$TMP/ran"
done
# A bound with a leading zero that is not zero is still that many seconds, as perl reads it.
bounded_run 05 sh -c ": > '$TMP/ran'"
check "and a bound of 05 runs the command" "$([ -e "$TMP/ran" ] && [ "$BOUNDED_RC" -eq 0 ] && echo ok || echo "rc $BOUNDED_RC")"
rm -f "$TMP/ran"
# The control on the two above: the same command with a real bound does run (L159).
bounded_run 30 sh -c ": > '$TMP/ran'"
check "and the same command with a real bound does run" "$([ -e "$TMP/ran" ] && [ "$BOUNDED_RC" -eq 0 ] && echo ok || echo "rc $BOUNDED_RC")"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
