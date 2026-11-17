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
# qos_prio 11 reads pth_maxpriority instead, the ceiling the kernel holds that thread under.
qos_prio() {
  python3 -c '
import ctypes, os, sys
c = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
c.pthread_threadid_np.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint64)]
c.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
t = ctypes.c_uint64(); c.pthread_threadid_np(None, ctypes.byref(t))
b = (ctypes.c_int32 * 40)()  # struct proc_threadinfo: two uint64 times (ints 0 to 3), then cpu_usage,
# policy, run_state, flags, sleep_time, curpri, then pth_priority, the base priority, is int 10 and
# pth_maxpriority is int 11
print(b[int(sys.argv[1])] if c.proc_pidinfo(os.getpid(), 15, t.value, b, ctypes.sizeof(b)) > 0 else "unread")' "${1:-10}"
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

# The level this suite was itself started at, which it cannot set (claude-config#3175, L411). The
# sync watcher is a launchd agent the kernel holds at base priority 20 under a ceiling of 20 (measured
# 2026-11-17, where a session's shell reads 31 under 63), and the send gate runs this suite from it.
# A raise lands above the legacy level, 31, so under a ceiling at or below that none can be seen and
# the two checks that need one are said unmeasured at the end, never failed: red there held this suite
# back from 227 sends in one day while every hand run was green. The ceiling is the kernel's own
# reading, never the base priority alone, which a lowered thread with no ceiling shares and can leave.
start="unread"; ceiling="unread"; CLAMPED=0
if [ "$(uname -s)" = Darwin ]; then
  start="$(qos_prio)"; ceiling="$(qos_prio 11)"
  case "$ceiling" in ''|*[!0-9]*) ;; *) [ "$ceiling" -le 31 ] && CLAMPED=1 ;; esac
fi

# lib/gate-qos.py on its own, loaded by path as the gate loads it, in a python3 of its own so the
# raise touches nothing else: on macOS it must report raised, off macOS that there is nothing to
# raise. The state is judged by the platform alone, since the module never consults taskpolicy.
# Started under a clamp it must say it could not raise, at the level this suite read for itself.
QOS_LIB="$DIR/lib/gate-qos.py"
lib_state="$(python3 -B - "$QOS_LIB" 2>&1 <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gate_qos", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
state, line = mod.raise_qos()
print(f"{state}|{line}")
PY
)"
if [ "$CLAMPED" -eq 1 ]; then
  case "$lib_state" in
    "not raised|qos: not raised: the level did not rise"*"base priority $start") check "lib/gate-qos.py on its own says it could not raise under the clamp this suite started under" ok ;;
    *) check "lib/gate-qos.py on its own says it could not raise under the clamp this suite started under" "started at base priority $start, got: ${lib_state:0:300}" ;;
  esac
else
  if [ "$(uname -s)" = Darwin ]; then want="raised"; else want="not macOS"; fi
  case "$lib_state" in
    "$want|"*) check "lib/gate-qos.py on its own reports $want" ok ;;
    *) check "lib/gate-qos.py on its own reports $want" "got: ${lib_state:0:300}" ;;
  esac
fi

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

case "$start" in ''|*[!0-9]*) check "the suite reads the level a python3 it starts runs at" "read: $start" ;; esac
case "$ceiling" in ''|*[!0-9]*) check "the suite reads the ceiling a python3 it starts runs under" "read: $ceiling" ;; esac

judge env
allowed "the control: a plain script run is judged and allowed"
if [ "$CLAMPED" -eq 0 ]; then
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
fi

# The failure path: a QoS clamp is a ceiling nothing inside the process can lift (measured: under
# taskpolicy -c utility the base priority stays 20 after the raise). The gate still judges, and its
# trace says it could not raise, with the level it really ran at. A cache of its own, so the allow
# the control stored cannot answer it: the call is judged afresh at the clamped level (L159).
judge env SLACK_GATE_CACHE_DIR="$T/gate-cache-clamp" taskpolicy -c utility
allowed "under a utility clamp the same call is still judged and allowed"
if grep -q '^miss: ' "$T/trace" && ! grep -qx 'hit' "$T/trace"; then
  check "and it was judged afresh under the clamp, not answered from the cache" ok
else
  check "and it was judged afresh under the clamp, not answered from the cache" "trace: $(tr '\n' '|' < "$T/trace")"
fi
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
# Started under a clamp there is no run without one, so that refusal rightly names the priority.
[ "$CLAMPED" -eq 1 ] || lacks "but says nothing of the priority, which was raised" "scheduling priority"

# The level asked for but never read back: the raise was not refused, so the refusal may not say it
# could not raise, only that its priority could not be read back (L11). A copy of the gate stands in
# whose read of the kernel's level answers nothing, the case proc_pidinfo failing produces.
mkdir -p "$T/unread/hooks"
cp "$HOOK" "$T/unread/hooks/slack-drafts-only-gate.sh"
ln -s "$DIR/lib" "$T/unread/hooks/lib"
cat > "$T/unread/hooks/slack_drafts_only_gate.py" <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("gate", os.environ["UNREAD_REAL_READER"])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
gate.raise_qos.__globals__["_base_priority"] = lambda libc: None
gate.main()
PY
: > "$T/trace"
OUT="$(payload Bash "$(bash_input "bash $T/run.sh")" | HOOK_TESTS_RUNNING=1 SLACK_GATE_TICK_BUDGET=1 SLACK_GATE_CACHE_TRACE="$T/trace" UNREAD_REAL_READER="$DIR/slack_drafts_only_gate.py" bash "$T/unread/hooks/slack-drafts-only-gate.sh" 2>"$T/err")"; RC=$?
ERR="$(cat "$T/err")"
refused "out of time with the level unread is refused"
says "and the refusal says its priority could not be read back" "its priority could not be read back"
lacks "and never that it could not raise it, which was not measured" "could not raise"
case "$(grep '^qos: ' "$T/trace")" in
  "qos: unread: "*) check "and the trace says the level was not read back, not that it was not raised" ok ;;
  *) check "and the trace says the level was not read back, not that it was not raised" "trace: $(tr '\n' '|' < "$T/trace")" ;;
esac

# The suite itself started under a clamp (claude-config#3175): the sync watcher is a launchd agent the
# kernel holds at base priority 20 with a ceiling of 20 (measured 2026-11-17), and the send gate runs
# this suite from it. There no raise can be seen at all, so of the three checks that failed there, the
# two that need a raise are said unmeasured, never failed (L411), and the helper's own is turned round
# to require that it says it could not raise. Red there held this suite back from 227 sends in one day
# while every hand run was green. Run once more under a utility clamp, unless this run is that one, or
# is clamped already and so is the case itself.
if [ -z "${SLACK_GATE_QOS_NESTED:-}" ] && [ "$CLAMPED" -eq 0 ]; then
  nested="$(SLACK_GATE_QOS_NESTED=1 taskpolicy -c utility bash "${BASH_SOURCE[0]}" 2>&1)"; nested_rc=$?
  if [ "$nested_rc" -eq 0 ]; then
    check "started under a utility clamp, this suite passes" ok
  else
    check "started under a utility clamp, this suite passes" "exit $nested_rc: $(printf '%s' "$nested" | grep '^FAIL' | cut -c1-160 | tr '\n' '|')"
  fi
  case "$nested" in
    *"SUITE-PART-UNMEASURED the gate's raise"*"ceiling 20"*) check "and says the raise was not measured there, naming the ceiling it read" ok ;;
    *) check "and says the raise was not measured there, naming the ceiling it read" "it printed: $(printf '%s' "$nested" | grep 'UNMEASURED' | cut -c1-200 | tr '\n' '|')" ;;
  esac
  case "$nested" in
    *"SUITE-RESULT passed=0 "*) check "and still ran its other checks there" "$(printf '%s' "$nested" | grep '^SUITE-RESULT')" ;;
    *"SUITE-RESULT passed="*) check "and still ran its other checks there" ok ;;
    *) check "and still ran its other checks there" "no SUITE-RESULT line" ;;
  esac
fi
if [ "$CLAMPED" -eq 1 ]; then
  echo "SUITE-PART-UNMEASURED the gate's raise above the legacy level, and a refusal that leaves the priority out because it was raised: this suite was started under a QoS clamp (kernel ceiling $ceiling, base priority $start), which nothing inside a process can lift"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
