#!/usr/bin/env bash
# Tests for check-rtk-exit-fidelity.sh (claude-config#319).
#
# That script answers one question: when the rtk rewrite hook swaps a real command for an rtk
# substitute, does the substitute still report the same PASS or FAIL? Twice the answer was no and
# both times a person found it by hand: claude-config#259 (a Playwright run summarised as
# `PASS (0) FAIL (3)` for a run with 4356 passes, exiting 0) and claude-config#318 (`rtk diff`
# printing a difference and exiting 0 where real diff exits 1).
#
# The script measures the REAL binary, which is the whole point of it, so everything here drives it
# through its two seams instead: RTK_FIDELITY_RTK and RTK_FIDELITY_HOOK. Those are the only two it
# honours, they are set for every case below, and no case leaves either real (L284). What that buys
# is each outcome in its contract being PRODUCED by a test rather than merely passed over (L151),
# including the ones that only appear when the machine is broken.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$DIR/check-rtk-exit-fidelity.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

[ -f "$S" ] || { echo "test-check-rtk-exit-fidelity: $S is not there, so nothing was verified." >&2; exit 2; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.fidelity.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-check-rtk-exit-fidelity: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"; mkdir -p "$BIN"

# A stub rtk whose exit code per subcommand is read from a file, so a scenario can make any
# destination agree with the real tool or lie about it, and nothing here depends on which rtk is
# installed on this Mac.
cat > "$BIN/rtk" <<'STUB'
#!/usr/bin/env bash
sub="${1:-}"
if [ "$sub" = "rewrite" ]; then
  # Everything is rewritten to `rtk <first word> <rest>`, which is the shape the real one emits.
  shift
  set -- $1
  printf 'rtk %s\n' "$*"
  exit 0
fi
# LIE_<sub> forces this subcommand's exit code; absent means run the real tool and pass its code on.
lie_var="LIE_${sub}"
if [ -n "${!lie_var:-}" ]; then exit "${!lie_var}"; fi
shift
command "$sub" "$@" >/dev/null 2>&1
exit $?
STUB
chmod +x "$BIN/rtk"

# A stub hook. It answers like the real one: silence means the command passes through (the
# destination is refused), any output means it is rewritten. REFUSE holds the subcommands it
# refuses, so a scenario can put a lying destination inside or outside the hook's protection.
cat > "$BIN/hook.sh" <<'HOOKSTUB'
#!/usr/bin/env bash
cmd="$(cat)"
cmd="$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tool_input"]["command"])' 2>/dev/null)"
first="${cmd%% *}"
case " ${REFUSE:-} " in
  *" $first "*) exit 0 ;;
esac
printf '{"hookSpecificOutput":{"updatedInput":{"command":"rtk %s"}}}\n' "$cmd"
HOOKSTUB
chmod +x "$BIN/hook.sh"

# The exit code is read from a FILE rather than returned through a command substitution: `rc=$?`
# set inside `$( ... )` is set in a subshell and never reaches the caller, which is how the first
# version of this helper silently compared against a stale code.
rc=0
run() { # run  -> the script's output, with its exit code left in $rc
  RTK_FIDELITY_RTK="$BIN/rtk" RTK_FIDELITY_HOOK="$BIN/hook.sh" bash "$S" > "$TMPROOT/out" 2>&1
  rc=$?
  cat "$TMPROOT/out"
}

# ---------------------------------------------------------------------------
# Everything agrees. The ordinary green, and the run has to SAY how many it compared, because a
# run that probed nothing and a run where everything passed are otherwise the same event (L98).
# ---------------------------------------------------------------------------
REFUSE="" run > /dev/null; out="$(cat "$TMPROOT/out")"
[ "$rc" -eq 0 ] && check "a run where every destination agrees exits 0" ok \
  || check "a run where every destination agrees exits 0" "rc=$rc out=$out"
grep -Eq 'compared [1-9][0-9]*' <<< "$out" \
  && check "and says how many it actually compared" ok \
  || check "and says how many it actually compared" "out=$out"

# ---------------------------------------------------------------------------
# A destination that LIES and that the hook ALLOWS. This is the whole reason the script exists and
# it must be a hard failure that NAMES the destination, not a line in a report nobody reads.
# ---------------------------------------------------------------------------
REFUSE="" LIE_find=0 run > /dev/null; out="$(cat "$TMPROOT/out")"
[ "$rc" -eq 1 ] && check "an allowed destination that lies about its exit code fails the run" ok \
  || check "an allowed destination that lies about its exit code fails the run" "rc=$rc out=$out"
grep -q 'find' <<< "$out" \
  && check "and names which destination lied" ok \
  || check "and names which destination lied" "out=$out"

# ---------------------------------------------------------------------------
# The SAME lie, with the hook refusing that destination. Contained, so it is reported and the run
# is green: that is what the refusals in rtk-rewrite.sh are for, and a check that failed anyway
# would make the remedy unreachable (L362).
# ---------------------------------------------------------------------------
REFUSE="find" LIE_find=0 run > /dev/null; out="$(cat "$TMPROOT/out")"
[ "$rc" -eq 0 ] && check "the same lie is contained when the hook refuses that destination" ok \
  || check "the same lie is contained when the hook refuses that destination" "rc=$rc out=$out"
grep -qi 'contained\|refused' <<< "$out" \
  && check "and the containment is reported rather than passed over in silence" ok \
  || check "and the containment is reported rather than passed over in silence" "out=$out"

# ---------------------------------------------------------------------------
# Which tools the probe set actually reaches (claude-config#321).
#
# Every green above is about the probes that EXIST. A rewritten command with no probe is exempt
# from the whole check while the run still reports a clean bill of health, which is the state
# nobody can see (L96, L98). So the script says which tools it examined, and this holds that list
# to the ones measured to be rewritten here with an exit code that means something.
#
# The list is written out rather than derived, and that is deliberate: rtk 0.31.0's rewrite
# registry is ARGUMENT sensitive (`git status` rewrites, `git x` does not; `gh issue list` does,
# `gh x` does not), so asking rtk about a generic shape reports git, gh and docker as never
# rewritten and any guard built on it would be blind in precisely the safe looking direction
# (L98). A written list that goes red when somebody drops a probe is the honest version.
# ---------------------------------------------------------------------------
REFUSE="" run > /dev/null; out="$(cat "$TMPROOT/out")"
examined="$(grep -i '^tools examined:' <<< "$out" || true)"
[ -n "$examined" ] \
  && check "the run says which tools its probes examined" ok \
  || check "the run says which tools its probes examined" "no 'tools examined' line in: $out"
for t in diff find ls git grep curl gh; do
  grep -q " $t\( \|$\)" <<< "$examined" \
    && check "the probe set reaches $t, whose exit code carries a verdict" ok \
    || check "the probe set reaches $t, whose exit code carries a verdict" "examined=[$examined]"
done

# ---------------------------------------------------------------------------
# The instrument proving it can still tell a mismatch APART. Without this every green above is
# satisfied by a script that compares nothing (L1, L159). It is deliberately built on `true` and
# `false` rather than on the known rtk mismatch, because a control that rots the day rtk is fixed
# would leave the suite green for the wrong reason (L182).
# ---------------------------------------------------------------------------
REFUSE="" run > /dev/null; out="$(cat "$TMPROOT/out")"
grep -qi 'control' <<< "$out" \
  && check "the run states that its own comparison was proved able to see a mismatch" ok \
  || check "the run states that its own comparison was proved able to see a mismatch" "out=$out"

# ---------------------------------------------------------------------------
# rtk absent. Not a pass: a check that could not run has to say so and exit non-zero, or "rtk is
# gone" reads exactly like "everything agreed" (L98, L11).
# ---------------------------------------------------------------------------
out="$(RTK_FIDELITY_RTK="$TMPROOT/no-such-rtk" RTK_FIDELITY_HOOK="$BIN/hook.sh" bash "$S" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && check "rtk missing exits 2 rather than reporting a clean run" ok \
  || check "rtk missing exits 2 rather than reporting a clean run" "rc=$rc out=$out"
grep -qi 'rtk' <<< "$out" \
  && check "and names what is missing" ok \
  || check "and names what is missing" "out=$out"

# ---------------------------------------------------------------------------
# The hook absent. Same shape, different cause, and it gets its OWN message: one message covering
# both would let the missing hook be diagnosed as a missing rtk (L11).
# ---------------------------------------------------------------------------
out="$(RTK_FIDELITY_RTK="$BIN/rtk" RTK_FIDELITY_HOOK="$TMPROOT/no-such-hook.sh" bash "$S" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && check "the hook missing exits 2 too" ok \
  || check "the hook missing exits 2 too" "rc=$rc out=$out"
grep -qi 'hook' <<< "$out" \
  && check "and says it was the hook, not rtk" ok \
  || check "and says it was the hook, not rtk" "out=$out"

# ---------------------------------------------------------------------------
# Every probe skipped because the real tools are not on PATH. A run that compared NOTHING must not
# report a clean bill of health (L98). PATH holds only the stubs, so no diff, find, ls or git.
# ---------------------------------------------------------------------------
# A PATH holding what the SCRIPT ITSELF needs to run and none of the tools it probes. Built by
# naming what it needs rather than by pruning, because a pruned PATH keeps whatever nobody thought
# to remove and the run then quietly probes it. Asserted below, or the case could pass by the
# script failing to start for some unrelated reason (L140).
BARE="$TMPROOT/bare-bin"; mkdir -p "$BARE"
for t in bash python3 mktemp mkdir dirname rm; do
  src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$BARE/$t"
done
ln -sf "$BIN/rtk" "$BARE/rtk"
for needed in bash python3 mktemp; do
  PATH="$BARE" command -v "$needed" >/dev/null 2>&1 \
    && check "the bare PATH still has $needed, so the script can start at all" ok \
    || check "the bare PATH still has $needed, so the script can start at all" "missing"
done
for absent in diff find ls git; do
  PATH="$BARE" command -v "$absent" >/dev/null 2>&1 \
    && check "and really has no $absent for a probe to compare against" "$absent is still reachable" \
    || check "and really has no $absent for a probe to compare against" ok
done
out="$(PATH="$BARE" RTK_FIDELITY_RTK="$BIN/rtk" RTK_FIDELITY_HOOK="$BIN/hook.sh" bash "$S" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && check "a run that could compare nothing exits 2, not 0" ok \
  || check "a run that could compare nothing exits 2, not 0" "rc=$rc out=$out"

# ---------------------------------------------------------------------------
# And the real thing. Everything above drives the script through stubs, which proves its logic and
# nothing about the binary actually installed here, and the binary is the entire subject (L52, L3).
# So the last case RUNS it, against the real rtk and the real hook. The three outcomes get three
# different endings, because "rtk is not on this Mac" and "rtk is here and the measurement failed"
# are not the same event and one message covering both would hide the second (L11, L98).
# ---------------------------------------------------------------------------
if ! command -v rtk >/dev/null 2>&1; then
  echo "note: rtk is not installed on this Mac, so the REAL measurement did not run. Everything above used stubs."
else
  real_out="$(bash "$S" 2>&1)"; real_rc=$?
  case "$real_rc" in
    0) check "against the real rtk, every substitution the hook allows still agrees" ok ;;
    1) check "against the real rtk, every substitution the hook allows still agrees" \
         "a destination the hook ALLOWS now disagrees with the tool it replaces: $real_out" ;;
    *) check "against the real rtk, the check could measure at all" \
         "rtk is installed but the check exited $real_rc without measuring: $real_out" ;;
  esac
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
