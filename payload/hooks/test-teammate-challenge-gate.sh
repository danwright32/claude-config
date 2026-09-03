#!/usr/bin/env bash
# Tests for teammate-challenge-gate.sh, the TeammateIdle hook that nudges a teammate once to
# surface disagreement before it goes quiet (claude-config#124).
#
# It holds a teammate back by exiting 2, which is the contract for "send this message and keep it
# working". Getting that wrong in one direction gives a teammate that never gets challenged; in
# the other it gives an idle LOOP, a teammate held back for ever by a hook that fires every time.
# The only thing standing between those is a marker file named after an identifier from the
# payload, and it had no test.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="$DIR/teammate-challenge-gate.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.teammate.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-teammate-challenge-gate: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# Its markers go in a throwaway of this run's own. Pointed at the real temp root, this suite would
# mark a teammate that is genuinely working right now and it would never be challenged (L2).
run() { TMPDIR="$TMPROOT" bash "$H" 2>"$TMPROOT/err"; }
errtext() { cat "$TMPROOT/err" 2>/dev/null; }

# ---------------------------------------------------------------------------
# The nudge fires ONCE, and holding the teammate back is what exit 2 means.
# ---------------------------------------------------------------------------
printf '{"agent_id":"plan-redteam-1"}' | run; code1=$?
[ "$code1" -eq 2 ] \
  && check "the first idle is held back rather than allowed" ok \
  || check "the first idle is held back rather than allowed" "exit=$code1"
msg="$(errtext)"
grep -qi 'disagree' <<< "$msg" \
  && check "and the message asks for the disagreement it exists to surface" ok \
  || check "and the message asks for the disagreement it exists to surface" "msg=$msg"
grep -qi 'you may stop' <<< "$msg" \
  && check "and says how to finish, so it is not a wall" ok \
  || check "and says how to finish, so it is not a wall" "msg=$msg"

printf '{"agent_id":"plan-redteam-1"}' | run; code2=$?
[ "$code2" -eq 0 ] \
  && check "the same teammate is allowed to idle the second time" ok \
  || check "the same teammate is allowed to idle the second time" "exit=$code2, which is an idle loop"
[ -z "$(errtext)" ] \
  && check "and is not nudged again" ok \
  || check "and is not nudged again" "it said: $(errtext)"

# A DIFFERENT teammate is still challenged, or every check above is satisfied by a hook that
# stopped nudging anybody after the first (L159).
printf '{"agent_id":"plan-security-1"}' | run; code3=$?
[ "$code3" -eq 2 ] \
  && check "a different teammate still gets its own nudge" ok \
  || check "a different teammate still gets its own nudge" "exit=$code3"

# ---------------------------------------------------------------------------
# No stable identifier means do NOTHING, which is the deliberate choice that makes an idle loop
# impossible: with no marker to write, a hook that nudged anyway would nudge for ever.
# ---------------------------------------------------------------------------
printf '{"something_else":"x"}' | run; code_noid=$?
[ "$code_noid" -eq 0 ] \
  && check "a payload naming no teammate lets it idle rather than looping" ok \
  || check "a payload naming no teammate lets it idle rather than looping" "exit=$code_noid"
printf 'not json at all' | run; code_junk=$?
[ "$code_junk" -eq 0 ] \
  && check "a payload that does not parse lets it idle too" ok \
  || check "a payload that does not parse lets it idle too" "exit=$code_junk"

# ---------------------------------------------------------------------------
# The identifier can arrive under several names, because the payload's shape is the platform's to
# change, not this repo's. Each is checked, or one of them silently stops working and the teammates
# arriving under that name are never challenged (L96).
# ---------------------------------------------------------------------------
i=0
for key in agentId teammate teammate_name teammateName name session_id sessionId; do
  i=$((i + 1))
  python3 -c 'import json,sys; print(json.dumps({sys.argv[1]: "who-%s" % sys.argv[2]}))' "$key" "$i" | run
  [ "$?" -eq 2 ] \
    && check "a teammate named by '$key' is challenged" ok \
    || check "a teammate named by '$key' is challenged" "it was let through"
done

# ---------------------------------------------------------------------------
# The identifier reaches a filesystem path, so it is stripped to a safe alphabet first (L50).
# ---------------------------------------------------------------------------
ESCAPE="$TMPROOT/escaped"
python3 -c 'import json,sys; print(json.dumps({"agent_id": "../../.." + sys.argv[1]}))' "$ESCAPE" | run
[ ! -e "$ESCAPE" ] \
  && check "an identifier carrying path separators cannot steer the marker write" ok \
  || check "an identifier carrying path separators cannot steer the marker write" "it wrote $ESCAPE"
# And it still WORKS on such an identifier rather than merely being safe: nudged once, then quiet.
python3 -c 'import json,sys; print(json.dumps({"agent_id": "../../.." + sys.argv[1]}))' "$ESCAPE" | run
[ "$?" -eq 0 ] \
  && check "and such a teammate is still only nudged once" ok \
  || check "and such a teammate is still only nudged once" "it nudged again, so the marker never stuck"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
