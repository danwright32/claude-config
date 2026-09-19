#!/usr/bin/env bash
# Tests for stale-worktree-nudge.sh, which decides WHEN to speak. What it speaks is
# check-stale-worktrees.sh's answer, tested on its own in test-check-stale-worktrees.sh, so the
# check is replaced here by a stub whose verdict and output the test sets. Two suites, two
# questions, and neither can pass by accident on the other's behalf.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/stale-worktree-nudge.sh"
TMP="$(mktemp -d)"
case "${TMP%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$TMP'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected: $2"; echo "  actual: $3"; fi }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi }

# The stub check. Its verdict and its output are both set from outside, so every arm of the WHEN
# decision can be driven without a repository behind it.
# It RECORDS every call, because the property that decides whether this hook may exist at all is
# how often the check runs, and only a count of its invocations can say (L3, L467: a presence guard
# is blind to a second call, so the assertion has to be on the exact number).
STUB="$TMP/check.sh"
cat >"$STUB" <<'EOS'
#!/usr/bin/env bash
printf 'ran\n' >>"$STUB_CALLS"
printf '%s\n' "${STUB_SAYS:-}"
exit "${STUB_RC:-0}"
EOS
chmod +x "$STUB"
export STUB_CALLS="$TMP/check-calls.log"
: >"$STUB_CALLS"
calls(){ grep -c . "$STUB_CALLS" 2>/dev/null || echo 0; }

STATE_DIR="$TMP/state"
OUT=""; RC=0
fire(){ # fire <session id>
  OUT="$(printf '{"session_id":"%s"}' "$1" \
    | STALE_WT_CHECK="$STUB" STALE_WT_STATE_DIR="$STATE_DIR" bash "$SCRIPT" 2>/dev/null)"
  RC=$?
}

export STUB_SAYS="  STALE agent-x [fix/1-x]: issue #1 is closed and nothing is uncommitted"

# --- nothing to say -------------------------------------------------------
STUB_RC=0 fire s1
check_eq "a check that found nothing says nothing" "" "$OUT"
check_eq "and never blocks the prompt" 0 "$RC"

# --- could not tell is not the person's problem ---------------------------
# Exit 2 means gh could not be read or this is not a repository. The check says that on stderr for
# anybody looking; putting it in front of the person on every prompt is an alert nobody can act on,
# which is how a channel stops being read (L36, L112).
STUB_RC=2 fire s2
check_eq "a check that could not tell says nothing to the person" "" "$OUT"
check_eq "and still never blocks the prompt" 0 "$RC"

# --- something to say -----------------------------------------------------
STUB_RC=1 fire s3
check "a stale worktree is reported" "STALE agent-x" "$OUT"
check_eq "and even then it does not block the prompt" 0 "$RC"

# --- once per session, not once per prompt --------------------------------
STUB_RC=1 fire s3
check_eq "the same answer in the same session is not repeated" "" "$OUT"
# A DIFFERENT session is told, because that session has been told nothing.
STUB_RC=1 fire s4
check "a different session is told the same thing" "STALE agent-x" "$OUT"

# --- and the check itself is not run again either --------------------------
# This is the cost bound, and it is the reason the record is read BEFORE the check rather than
# after it. The check asks GitHub, and this hook runs on every prompt: deduplicating the MESSAGE
# after computing it would pay that call all session while saying nothing. Asserted on the exact
# number of invocations, because "it still only spoke once" is true either way.
before="$(calls)"
STUB_RC=1 fire s3
STUB_RC=1 fire s3
check_eq "and the check is not run again in that session, at any price" "$before" "$(calls)"
# The trade that buys: a worktree going stale part way through a session waits for the next one.
# Written down as a test rather than left as a comment, so it is a decision and not a surprise.
STUB_SAYS="  STALE agent-y [fix/2-y]: issue #2 is closed" STUB_RC=1 fire s3
check_eq "a newly stale worktree is left for the next session, not said in this one" "" "$OUT"

# --- no session id --------------------------------------------------------
# Said twice is a smaller failure than never said, so with nothing to deduplicate against it
# speaks (L98). Driven twice, because speaking once proves nothing about which way it chose.
OUT="$(printf '{}' | STALE_WT_CHECK="$STUB" STALE_WT_STATE_DIR="$STATE_DIR" \
  env STUB_RC=1 bash "$SCRIPT" 2>/dev/null)"
check "with no session to key on it speaks" "STALE agent-x" "$OUT"
OUT="$(printf '{}' | STALE_WT_CHECK="$STUB" STALE_WT_STATE_DIR="$STATE_DIR" \
  env STUB_RC=1 bash "$SCRIPT" 2>/dev/null)"
check "and goes on speaking rather than falling silent it cannot account for" "STALE agent-x" "$OUT"
# It says on stderr that it could not hold itself to once per session, because a hook paying a
# network call on every prompt must not do it silently (L622).
ERRS="$(printf '{}' | STALE_WT_CHECK="$STUB" STALE_WT_STATE_DIR="$STATE_DIR" \
  env STUB_RC=1 bash "$SCRIPT" 2>&1 >/dev/null)"
check "and says that it could not hold itself to once per session" "once per session" "$ERRS"

# --- a missing check is not a crash ---------------------------------------
OUT="$(printf '{"session_id":"s9"}' \
  | STALE_WT_CHECK="$TMP/not-there.sh" STALE_WT_STATE_DIR="$STATE_DIR" bash "$SCRIPT" 2>/dev/null)"
RC=$?
check_eq "a check that is not installed says nothing" "" "$OUT"
check_eq "and exits 0 rather than stopping the turn" 0 "$RC"

echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
