#!/usr/bin/env bash
# Tests for the Slack drafts gate's scheduling priority (claude-config#2918). On 2026-11-16 a cold
# judgement of `bash tests/test-claude-sync.sh` took 4.2 to 4.5 s on the personal MacBook's
# performance cores and 11.2 to 11.8 s on its efficiency cores, where 2 of 4 runs passed the gate's
# 11 s budget. Claude Code starts the gate at the legacy level (kernel base priority 31), the level
# every other session's suite runs at, so a busy Mac moves it to an efficiency core. Dan chose
# (2026-11-16) to raise the gate's QoS so it keeps a performance core.
#
# The priority is read from the kernel by the running gate (its trace line), never from what it asked
# for: asking for user initiated alone is accepted and changes nothing, because XNU squashes it to
# legacy for a task with no application role (measured: base priority 31 before and after). Every
# other judgement of the gate is in test-slack-drafts-only-gate.sh, whose helpers are copied here as
# they are, so a case is driven the same way: a hook payload piped into slack-drafts-only-gate.sh,
# exit 0 allowed and 2 refused, the reason on stderr.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/slack-drafts-only-gate.sh"
unset SLACK_GATE_UNWORKED_PATHS SLACK_GATE_TICK_BUDGET

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "FAIL: there is no slack-drafts-only-gate.sh beside this suite at $DIR, so no Slack send is refused."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/slack-gate-qos.XXXXXXXX")" || exit 1
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$T'" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT
# A cache of its own, so no judgement here reads or writes this Mac's ~/.claude/state.
export SLACK_GATE_CACHE_DIR="$T/gate-cache"

payload() {
  python3 -c '
import json, sys
tool, inp, cwd = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
print(json.dumps({"session_id": "f6017250-8f33-47ac-bbb2-b82a7c319d0d",
                  "transcript_path": "/tmp/transcript.jsonl", "cwd": cwd,
                  "permission_mode": "auto", "hook_event_name": "PreToolUse", "tool_name": tool,
                  "tool_input": inp, "tool_use_id": "toolu_01X4Qw7JnfYswF7UVX94Z4Sy"}))
' "$1" "$2" "${3:-$T}"
}
bash_input() { python3 -c 'import json, sys; print(json.dumps({"command": sys.argv[1], "description": "d"}))' "$1"; }

RC=0; OUT=""; ERR=""
refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:400}" ;; esac; }
lacks() { case "$ERR" in *"$2"*) check "$1" "stderr said '$2': ${ERR:0:400}" ;; *) check "$1" ok ;; esac; }

# The kernel's base priority of the calling thread, read by a python3 the suite starts itself, so the
# level the gate starts at comes from outside the gate (a guard and its reading never share a source).
qos_prio() {
  python3 -c '
import ctypes, os
c = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
c.pthread_threadid_np.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint64)]
c.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
t = ctypes.c_uint64(); c.pthread_threadid_np(None, ctypes.byref(t))
b = (ctypes.c_int32 * 40)()  # struct proc_threadinfo: two uint64 times (ints 0 to 3), then cpu_usage,
# policy, run_state, flags, sleep_time, curpri, and pth_priority, the base priority, is int 10
print(b[10] if c.proc_pidinfo(os.getpid(), 15, t.value, b, ctypes.sizeof(b)) > 0 else "unread")'
}
# judge <runner words...>: one plain script run judged through the wrapper, traced; sets RC, OUT, ERR
# and QOS_LINE, the trace's qos line.
judge() {
  : > "$T/trace"
  OUT="$(payload Bash "$(bash_input "bash $T/run.sh")" | SLACK_GATE_CACHE_TRACE="$T/trace" "$@" bash "$HOOK" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
  QOS_LINE="$(grep '^qos: ' "$T/trace")"
}

echo "slack drafts gate: the judgement runs at a raised scheduling priority (claude-config#2918)"

printf '%s\n' 'echo hi' > "$T/run.sh"

if [ "$(uname -s)" != Darwin ] || ! command -v taskpolicy >/dev/null 2>&1; then
  # Off macOS there is nothing to raise: the gate still judges, and says so in its trace. The level
  # itself is untaken here, said so in the one shape the runner counts, never passed (L411).
  judge env
  allowed "off macOS a plain script run is still judged and allowed"
  case "$QOS_LINE" in
    "qos: not raised: not macOS") check "and the gate traces that it did not raise its priority" ok ;;
    *) check "and the gate traces that it did not raise its priority" "trace: $(tr '\n' '|' < "$T/trace")" ;;
  esac
  echo "SUITE-PART-UNMEASURED the gate's scheduling priority is read only on macOS with taskpolicy, and this is $(uname -s)"
  echo
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit
fi

start="$(qos_prio)"
case "$start" in ''|*[!0-9]*) check "the suite reads the level a python3 it starts runs at" "read: $start" ;; esac

judge env
allowed "the control: a plain script run is judged and allowed"
case "$QOS_LINE" in
  "qos: user-initiated, base priority "*)
    got="${QOS_LINE##* }"
    if [ "$got" -gt "${start:-99}" ] 2>/dev/null && [ "$got" -gt 31 ]; then
      check "the gate judges above the level it was started at ($start), read from the kernel" ok
    else
      check "the gate judges above the level it was started at ($start), read from the kernel" "$QOS_LINE"
    fi ;;
  *) check "the gate traces the priority it judges at" "trace: $(tr '\n' '|' < "$T/trace")" ;;
esac

# The failure path: a QoS clamp is a ceiling nothing inside the process can lift (measured: under
# taskpolicy -c utility the base priority stays 20 after the raise). The gate still judges, and its
# trace says it could not raise, with the level it really ran at.
judge taskpolicy -c utility
allowed "under a utility clamp the same call is still judged and allowed"
case "$QOS_LINE" in
  "qos: not raised"*"base priority 20") check "and the gate says it could not raise its priority, naming the level it ran at" ok ;;
  *) check "and the gate says it could not raise its priority, naming the level it ran at" "trace: $(tr '\n' '|' < "$T/trace")" ;;
esac

# Run out of time under the clamp, and the refusal says the gate could not raise its priority, the
# likeliest reason it ran out (L11). The step clock (SLACK_GATE_TICK_BUDGET) makes it run out at once.
OUT="$(payload Bash "$(bash_input "bash $T/run.sh")" | HOOK_TESTS_RUNNING=1 SLACK_GATE_TICK_BUDGET=1 taskpolicy -c utility bash "$HOOK" 2>"$T/err")"; RC=$?
ERR="$(cat "$T/err")"
refused "out of time under the clamp is refused"
says "and the refusal says the gate could not raise its scheduling priority" "could not raise its scheduling priority"
says "naming the level it ran at" "base priority 20"
OUT="$(payload Bash "$(bash_input "bash $T/run.sh")" | HOOK_TESTS_RUNNING=1 SLACK_GATE_TICK_BUDGET=1 bash "$HOOK" 2>"$T/err")"; RC=$?
ERR="$(cat "$T/err")"
refused "the control: out of time with no clamp is refused too"
says "and says it ran out of time" "ran out of time"
lacks "but says nothing of the priority, which was raised" "scheduling priority"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
