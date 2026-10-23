#!/usr/bin/env bash
# Tests for stale-worktree-nudge.sh and the run it starts, lib/stale-worktree-run.py.
#
# The nudge decides WHEN a cleanup run starts and when its answer is said; the runner holds the
# lock, records the run and writes the answer down. What the answer SAYS is check-stale-worktrees.sh's,
# tested on its own in test-check-stale-worktrees.sh, so here the check is replaced by a stub whose
# verdict and output the test sets, except in the last section, which drives the real check end to
# end against a fixture repository.
#
# No fixed sleeps (L290, L524). A run is held part way by a GATE, a file the stub waits for, and the
# test waits on conditions: the stub reaching its gate, the runner's process ending. Every wait has
# a deadline of its own, so a stub this suite forgets is gone within a minute rather than for ever.
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
# The hooks block beside this copy of the hooks, the shipped or the installed one (claude-config#1237).
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
TMP="$(mktemp -d)"
case "${TMP%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$TMP'." >&2; exit 2 ;;
esac
TMP="$(cd "$TMP" && pwd -P)"
# The runners this suite starts are in sessions of their own, so the deadline's process tree kill
# cannot reach them. Opening every gate lets each one finish on its own in a moment.
trap 'touch "$TMP"/gate* 2>/dev/null; rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected: $2"; echo "  actual: $3"; fi }
check_not(){ if [[ "$3" != *"$2"* ]]; then ok; else bad "$1 (should not contain '$2')"; echo "  actual: $3"; fi }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi }
G(){ git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# The timeout Claude Code gives this hook, read from the settings that install it rather than
# written here, so the test holds the hook to whatever the hook is actually given (L188).
TIMEOUT="$(python3 -c '
import json, sys
for m in json.load(open(sys.argv[1]))["hooks"]["UserPromptSubmit"]:
    for h in m.get("hooks", []):
        if "stale-worktree-nudge.sh" in h.get("command", ""):
            print(h.get("timeout", 60))
' "$SETTINGS" 2>/dev/null)"
[ -n "$TIMEOUT" ] && ok || bad "${SETTINGS:-no settings file beside $DIR} names a timeout for stale-worktree-nudge.sh"
TIMEOUT="${TIMEOUT:-5}"

# The stub check. Its verdict, output and stderr are set from outside. It RECORDS every call and
# the session it ran in, and with STUB_GATE set it marks that it has started and then waits for
# the gate, which is how a run is held part way.
STUB="$TMP/check.sh"
cat >"$STUB" <<'EOS'
#!/usr/bin/env bash
printf 'ran %s\n' "$*" >>"$STUB_CALLS"
python3 -c 'import os; print(os.getsid(0))' >>"$STUB_SIDS" 2>/dev/null
if [ -n "${STUB_GATE:-}" ]; then
  : >"$STUB_GATE.reached"
  n=0; while [ ! -e "$STUB_GATE" ] && [ "$n" -lt 1200 ]; do sleep 0.05; n=$((n + 1)); done
fi
printf '%s\n' "${STUB_SAYS:-}"
[ -z "${STUB_ERR:-}" ] || printf '%s\n' "$STUB_ERR" >&2
exit "${STUB_RC:-0}"
EOS
chmod +x "$STUB"
export STUB_CALLS="$TMP/check-calls.log" STUB_SIDS="$TMP/check-sids.log"
: >"$STUB_CALLS"; : >"$STUB_SIDS"
calls(){ grep -c . "$STUB_CALLS" 2>/dev/null || true; }

PROJ="$TMP/proj"; mkdir -p "$PROJ"; G -C "$PROJ" init -q -b main
STATE_DIR="$TMP/state"
export STALE_WT_STATE_DIR="$STATE_DIR"
OUT=""; RC=0; ERR=""
fire(){ # fire <session id> [env assignments...]: one prompt in $PROJ
  local s="$1"; shift
  OUT="$(cd "$PROJ" && printf '{"session_id":"%s"}' "$s" \
    | env STALE_WT_CHECK="$STUB" "$@" bash "$SCRIPT" 2>"$TMP/err")"
  RC=$?; ERR="$(cat "$TMP/err")"
}
skey(){ printf '%s' "$1" | shasum | cut -c1-12; }
# Wait for every run a session started to end, judged by the runner's own process, never a sleep.
settle(){ # settle <session id>
  local f="$STATE_DIR/claude-stale-worktrees-$(skey "$1").state" pid n
  for pid in $(sed -n 's/^runner //p' "$f" 2>/dev/null); do
    n=0; while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 600 ]; do sleep 0.05; n=$((n + 1)); done
    kill -0 "$pid" 2>/dev/null && bad "the run session $1 started (process $pid) finished within 30s"
  done
  return 0
}
reached(){ # reached <gate>: wait for the stub to reach it
  local n=0; while [ ! -e "$1.reached" ] && [ "$n" -lt 600 ]; do sleep 0.05; n=$((n + 1)); done
  [ -e "$1.reached" ]
}
last_record(){ cat "$STATE_DIR"/claude-stale-worktrees-repo-*.last 2>/dev/null; }

export STUB_SAYS="  removed agent-x [fix/1-x]: PR #1 merged and nothing in it was newer (its branch is kept)"

# --- the defect: the check ran inside the prompt, past the hook's timeout (claude-config#1247) ---
# With 46 worktrees the check took 3.9 to 4.8 seconds before removing anything (measured
# 2026-10-16), so Claude Code killed the hook at 5 and threw its output away, every session. The
# stub here does not finish
# until the test opens its gate, so a hook that waits for the check cannot return in time, and the
# hook is run under exactly the timeout the settings give it. Captured through a pipe, so a run
# that kept the hook's stdout open would hold the capture too (L235).
HOOK_RC="$(cd "$PROJ" && STUB_GATE="$TMP/gate-slow" STUB_RC=1 STALE_WT_CHECK="$STUB" python3 -c '
import subprocess, sys
try:
    r = subprocess.run(["bash", sys.argv[1]], input=b"{\"session_id\":\"slow\"}",
                       capture_output=True, timeout=float(sys.argv[2]))
    print(r.returncode)
except subprocess.TimeoutExpired:
    print("timed out")
' "$SCRIPT" "$TIMEOUT")"
check_eq "the hook returns inside its ${TIMEOUT}s timeout while the check is still running" 0 "$HOOK_RC"
if reached "$TMP/gate-slow"; then ok; else bad "the check was started at all, rather than skipped to return quickly"; fi
# It runs in a session of its own, so nothing aimed at the session the prompt came from (the
# terminal closing, Ctrl+C, a kill of the hook's group) reaches a removal part way through (L617).
check_not "the run is in a session of its own, not the prompt's" "$(python3 -c 'import os; print(os.getsid(0))')" "$(cat "$STUB_SIDS")"
: >"$TMP/gate-slow"; settle slow
fire slow
check "and the answer it could not give in time is given on the next prompt" "removed agent-x" "$OUT"

# --- nothing to say -------------------------------------------------------
STUB_RC=0 fire s1
check_eq "a first prompt says nothing, since the run has only just started" "" "$OUT"
check_eq "and never blocks the prompt" 0 "$RC"
settle s1
STUB_RC=0 fire s1
check_eq "a run that found nothing says nothing on the next prompt either" "" "$OUT"
check "and its outcome is recorded for anybody looking" '"verdict": 0' "$(last_record)"

# --- could not tell is not the person's problem ---------------------------
# Exit 2 means gh could not be read or this is not a repository. Putting that in front of the
# person is an alert nobody can act on (L36, L112), so it is recorded instead, stderr included.
STUB_RC=2 STUB_ERR="check-stale-worktrees: could not read the merged pull requests" fire s2
settle s2
STUB_RC=2 fire s2
check_eq "a check that could not tell says nothing to the person" "" "$OUT"
check "but its verdict is recorded" '"verdict": 2' "$(last_record)"
check "and so is what it said on stderr" "could not read the merged pull requests" "$(last_record)"

# --- something to say -----------------------------------------------------
STUB_RC=1 fire s3
check_eq "a run with something to say is not waited for" "" "$OUT"
settle s3
STUB_RC=1 fire s3
check "what it removed is said on the next prompt" "removed agent-x" "$OUT"
check "saying where and when it ran, since it is said later than it happened" "Agent worktree cleanup in $PROJ" "$OUT"
check_eq "and even then it does not block the prompt" 0 "$RC"
# Dan's decision on 2026-10-14 (#1199): finished worktrees are removed, not just named.
check_eq "every run of the check is asked to remove, not only to report" "$(calls)" "$(grep -c -- '^ran --remove' "$STUB_CALLS")"
STUB_RC=1 fire s3
check_eq "the same answer is not said twice" "" "$OUT"

# --- once per session, not once per prompt --------------------------------
# The cost bound: the record is read BEFORE a run is started, so a session starts one run however
# many prompts it has. Asserted on the exact number of runs, because "it only spoke once" is true
# either way.
before="$(calls)"
STUB_RC=1 fire s3; STUB_RC=1 fire s3; settle s3
check_eq "a session that has started its run starts no other, at any price" "$before" "$(calls)"

# --- and again within a long session, every three hours (claude-config#1521) ---
# One coordinator session ran for three days, dispatched over 60 builders, and never started the
# sweep after its first prompt, so 63 merged worktrees piled up. A session now starts it again once
# three hours have passed since its last start, on the injected clock (L524), and not before.
T0="$(date +%s)"
STUB_RC=0 fire r1 STALE_WT_NOW="$T0"; settle r1
before="$(calls)"
STUB_RC=0 fire r1 STALE_WT_NOW="$((T0 + 179 * 60))"; settle r1
check_eq "#1521 a prompt under three hours after the session's run starts no other" "$before" "$(calls)"
STUB_RC=0 fire r1 STALE_WT_NOW="$((T0 + 181 * 60))"; settle r1
check_eq "#1521 the first prompt past three hours starts the sweep again" "$((before + 1))" "$(calls)"
STUB_RC=0 fire r1 STALE_WT_NOW="$((T0 + 182 * 60))"; settle r1
check_eq "#1521 and the three hours count from that run, not the first" "$((before + 1))" "$(calls)"
STUB_RC=0 fire r1 STALE_WT_NOW="$((T0 + 362 * 60))"; settle r1
check_eq "#1521 so the next starts three hours after it" "$((before + 2))" "$(calls)"
# A record the earlier nudge wrote holds no start time, so its age cannot be read: the next prompt
# starts a run and records one, rather than never running again in a session open across the change.
: >"$STATE_DIR/claude-stale-worktrees-$(skey r2).state"
before="$(calls)"
STUB_RC=0 fire r2 STALE_WT_NOW="$T0"; settle r2
check_eq "#1521 a session record with no start time starts a run" "$((before + 1))" "$(calls)"
STUB_RC=0 fire r2 STALE_WT_NOW="$((T0 + 60))"; settle r2
check_eq "#1521 and records one, so the prompt after it starts none" "$((before + 1))" "$(calls)"

# --- the next session hears what the last one never came back for ---------
STUB_RC=1 fire s4; settle s4
before="$(calls)"
STUB_RC=0 fire s5
check "a session's answer is said to the next session when it had no later prompt" "removed agent-x" "$OUT"
settle s5
check_eq "and that next session still starts its own run" "$((before + 1))" "$(calls)"
STUB_RC=0 fire s4
check_eq "an answer said once is not said again to the session that started it" "" "$OUT"

# --- two sessions at once run the check once -------------------------------
STUB_GATE="$TMP/gate-two" STUB_RC=0 fire s6
reached "$TMP/gate-two" || bad "the first run reached its gate"
before="$(calls)"
STUB_RC=0 fire s7; settle s7
check_eq "a second session starting while a run holds the lock does not run the check too" "$before" "$(calls)"
: >"$TMP/gate-two"; settle s6

# --- a run that never ends is said, not waited on in silence ---------------
# A run holding the lock for ever stops every later one, which is the failure #1247 was: nothing
# removed, for days, and nothing said why (L13, L98).
STUB_GATE="$TMP/gate-stuck" STUB_RC=0 fire s8
reached "$TMP/gate-stuck" || bad "the stuck run reached its gate"
STUB_RC=0 fire s9; settle s9; STUB_RC=0 fire s9
check_eq "a run that has held the lock a moment is not called stuck" "" "$OUT"
LATE="$(( $(date +%s) + 31 * 60 ))"
STUB_RC=0 fire s10 STALE_WT_NOW="$LATE"; settle s10
# A second session meeting the same stuck run says nothing more: one hang is one notice, however
# many sessions start while it lasts.
# Counted across every prompt, since the second session's own first prompt says what is waiting.
STUB_RC=0 fire s10b STALE_WT_NOW="$LATE"; SAID="$OUT"; settle s10b
STUB_RC=0 fire s10; SAID="$SAID"$'\n'"$OUT"
check "a run that has held the lock past its limit is said to be still running" "still running" "$SAID"
check "naming the process, so it can be looked at" "process " "$SAID"
check_eq "and said once, not once per session that met it" 1 "$(printf '%s\n' "$SAID" | grep -c 'still running' || true)"
: >"$TMP/gate-stuck"; settle s8

# --- a run that died part way is said -------------------------------------
# A record with a start and no finish, and the lock free, is a run that was stopped part way, which
# is exactly what a kill at the hook's timeout used to leave (L617).
for f in "$STATE_DIR"/claude-stale-worktrees-repo-*.last; do printf '{"started": 1700000000, "pid": 4242}\n' >"$f"; done
STUB_RC=0 fire s11; settle s11; STUB_RC=0 fire s11
check "a run before this one that never finished is said, although this one found nothing" "never recorded finishing" "$OUT"
check "naming the process it was" "4242" "$OUT"

# --- a check that broke is said --------------------------------------------
STUB_RC=3 STUB_ERR="line 9: syntax error" fire s12; settle s12; STUB_RC=0 fire s12
check "an exit the check never returns on purpose is said" "exit 3" "$OUT"
check "with what it said on stderr" "syntax error" "$OUT"

# --- no session id --------------------------------------------------------
# Said twice is a smaller failure than never said, so with nothing to key the record on it starts a
# run on every prompt, and says on stderr that it could not hold itself to once per session (L622).
nosession_settle(){ # wait until the check has run $1 times and the run holding the lock has ended
  local n=0
  while [ "$(calls)" -lt "$1" ] && [ "$n" -lt 600 ]; do sleep 0.05; n=$((n + 1)); done
  python3 -c '
import fcntl, glob, os, signal, sys
signal.alarm(30)
for p in glob.glob(os.path.join(sys.argv[1], "claude-stale-worktrees-repo-*.lock")):
    fd = os.open(p, os.O_RDWR)
    fcntl.flock(fd, fcntl.LOCK_EX)
    os.close(fd)
' "$STATE_DIR"
}
fire_bare(){ OUT="$(cd "$PROJ" && printf '{}' | STALE_WT_CHECK="$STUB" STUB_RC=1 bash "$SCRIPT" 2>"$TMP/err")"; ERR="$(cat "$TMP/err")"; }
before="$(calls)"
fire_bare
check "with no session it says on stderr that it could not hold itself to once per session" "once per session" "$ERR"
nosession_settle "$((before + 1))"
fire_bare
check "and goes on speaking rather than falling silent" "removed agent-x" "$OUT"
nosession_settle "$((before + 2))"
check_eq "starting a run on every prompt" "$((before + 2))" "$(calls)"

# --- what cannot start a run says nothing and blocks nothing ----------------
before="$(calls)"
OUT="$(cd "$PROJ" && printf '{"session_id":"s13"}' | STALE_WT_CHECK="$TMP/not-there.sh" bash "$SCRIPT" 2>/dev/null)"; RC=$?
check_eq "a check that is not installed says nothing" "" "$OUT"
check_eq "and exits 0 rather than stopping the turn" 0 "$RC"
mkdir -p "$TMP/notarepo"
OUT="$(cd "$TMP/notarepo" && printf '{"session_id":"s14"}' | STALE_WT_CHECK="$STUB" bash "$SCRIPT" 2>/dev/null)"; RC=$?
settle s14
check_eq "outside any repository it says nothing" "" "$OUT"
check_eq "and starts no run" "$before" "$(calls)"

# Without python3 there is no way to start a run in a session of its own, and running the check
# inline is the defect itself, so it starts nothing and says why on stderr.
. "$DIR/lib/no-python-path.sh"
NOPY="$TMP/nopy"; npp_build_bin "$NOPY"
if npp_reaches_python3 "$NOPY"; then
  bad "the premise: the bare PATH reaches no python3"
else
  OUT="$(cd "$PROJ" && printf '{"session_id":"s15"}' | PATH="$NOPY" STALE_WT_CHECK="$STUB" STUB_RC=1 \
    "$NOPY/bash" "$SCRIPT" 2>"$TMP/err")"; RC=$?
  check_eq "with no python3 it says nothing to the person" "" "$OUT"
  check_eq "and exits 0" 0 "$RC"
  check "and says on stderr that python3 is why" "python3" "$(cat "$TMP/err")"
  check_eq "and never runs the check inside the prompt instead" "$before" "$(calls)"
fi

# --- end to end: the real check, with a GitHub that answers slowly ----------
# The exact shape #1247 measured: the merged pull request list is the slow part. A fixture repo
# with one landed worktree, and a gh that does not answer until its gate opens.
REPO="$TMP/repo"; mkdir -p "$REPO"; G -C "$REPO" init -q -b main
printf 'x\n' >"$REPO/f.txt"; G -C "$REPO" add f.txt; G -C "$REPO" commit -qm base
WT="$REPO/.claude/worktrees"; mkdir -p "$WT"
G -C "$REPO" worktree add -q -b fix/415-landed "$WT/agent-landed" >/dev/null 2>&1
find "$WT/agent-landed" -exec touch -t 202601010000 {} + 2>/dev/null
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
: >"$GH_GATE.reached"
n=0; while [ ! -e "$GH_GATE" ] && [ "$n" -lt 1200 ]; do sleep 0.05; n=$((n + 1)); done
cat "$GH_MERGED"
STUB
chmod +x "$TMP/bin/gh"
export GH_GATE="$TMP/gate-gh" GH_MERGED="$TMP/merged.tsv"
printf 'fix/415-landed\t%s\t415\n' "$(G -C "$WT/agent-landed" rev-parse HEAD)" >"$GH_MERGED"
E2E_STATE="$TMP/e2e-state"
HOOK_RC="$(cd "$REPO" && STALE_WT_GH="$TMP/bin/gh" STALE_WT_STATE_DIR="$E2E_STATE" python3 -c '
import subprocess, sys
try:
    r = subprocess.run(["bash", sys.argv[1]], input=b"{\"session_id\":\"e2e\"}",
                       capture_output=True, timeout=float(sys.argv[2]))
    print(r.returncode)
except subprocess.TimeoutExpired:
    print("timed out")
' "$SCRIPT" "$TIMEOUT")"
check_eq "with the real check and a slow GitHub, the hook returns inside its timeout" 0 "$HOOK_RC"
reached "$GH_GATE" || bad "the real check reached GitHub"
check_eq "and the landed worktree is still there while GitHub has not answered" yes "$([ -d "$WT/agent-landed" ] && echo yes || echo no)"
: >"$GH_GATE"
STATE_DIR="$E2E_STATE" settle e2e
OUT="$(cd "$REPO" && printf '{"session_id":"e2e"}' | STALE_WT_STATE_DIR="$E2E_STATE" bash "$SCRIPT" 2>/dev/null)"
check "once it has answered, the removal is said on the next prompt" "removed agent-landed [fix/415-landed]: PR #415 merged" "$OUT"
check_eq "and the landed worktree is gone" no "$([ -d "$WT/agent-landed" ] && echo yes || echo no)"

echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
