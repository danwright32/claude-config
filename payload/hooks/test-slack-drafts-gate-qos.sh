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

# lib/gate-qos.py on its own, loaded by path as the gate loads it, in a python3 of its own so the
# raise touches nothing else: on macOS it must report raised, off macOS that there is nothing to
# raise. The state is judged by the platform alone, since the module never consults taskpolicy.
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
if [ "$(uname -s)" = Darwin ]; then want="raised"; else want="not macOS"; fi
case "$lib_state" in
  "$want|"*) check "lib/gate-qos.py on its own reports $want" ok ;;
  *) check "lib/gate-qos.py on its own reports $want" "got: ${lib_state:0:300}" ;;
esac

# A python3 built without _ctypes has nothing to raise the priority with. lib/gate-qos.py imported
# ctypes as it loaded, outside any try, and the gate loads it as it starts, so on such a python3
# the gate failed before judging anything and every call it would judge was refused as one it could
# not judge (claude-config#3151; measured 2026-11-17 by the cases below: exit 2, "No module named
# '_ctypes'"). A _ctypes that raises as the missing one does stands in for that python3, in front
# of the real one on the path. The gate must judge all the same, and say why it did not raise.
mkdir -p "$T/noctypes"
printf '%s\n' "raise ModuleNotFoundError(\"No module named '_ctypes'\")" > "$T/noctypes/_ctypes.py"
if python3 -B -c 'import ctypes' 2>/dev/null && ! PYTHONPATH="$T/noctypes" python3 -B -c 'import ctypes' 2>/dev/null; then
  if [ "$(uname -s)" = Darwin ]; then want_state="not raised"; want_line="qos: not raised: this python3 has no ctypes"
  else want_state="not macOS"; want_line="qos: not raised: not macOS"; fi
  lib_state="$(PYTHONPATH="$T/noctypes" python3 -B - "$QOS_LIB" 2>&1 <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gate_qos", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
state, line = mod.raise_qos()
print(f"{state}|{line}")
PY
)"
  case "$lib_state" in
    "$want_state|$want_line"*) check "with no ctypes, lib/gate-qos.py still loads and says why it did not raise" ok ;;
    *) check "with no ctypes, lib/gate-qos.py still loads and says why it did not raise" "got: ${lib_state:0:400}" ;;
  esac
  judge env SLACK_GATE_CACHE_DIR="$T/gate-cache-noctypes" PYTHONPATH="$T/noctypes"
  allowed "with no ctypes a plain script run is still judged and allowed"
  case "$QOS_LINE" in
    "$want_line"*) check "and the gate traces why it did not raise its priority" ok ;;
    *) check "and the gate traces why it did not raise its priority" "trace: $(tr '\n' '|' < "$T/trace")" ;;
  esac
  if [ "$(uname -s)" = Darwin ]; then
    OUT="$(payload Bash "$(bash_input "bash $T/run.sh")" | HOOK_TESTS_RUNNING=1 SLACK_GATE_TICK_BUDGET=1 PYTHONPATH="$T/noctypes" bash "$HOOK" 2>"$T/err")"; RC=$?
    ERR="$(cat "$T/err")"
    refused "out of time with no ctypes is refused"
    says "and the refusal says the gate could not raise its scheduling priority" "could not raise its scheduling priority"
    says "and that this python3 has no ctypes" "this python3 has no ctypes"
  fi
else
  echo "SUITE-PART-UNMEASURED the gate on a python3 with no ctypes, because a _ctypes in front of the real one did not stand in for that here"
fi

# priority_checks <label> <cache folder>: the level the gate judges at, which waits on the platform
# alone, and the QoS clamp's failure path, which waits on taskpolicy as well. taskpolicy sets the
# clamp and nothing else here needs it: the gate raises its priority with or without it. The suite
# took its off macOS branch whenever taskpolicy was not on the PATH, and failed there on a Mac,
# where the gate had raised its priority as it should (claude-config#3151; measured 2026-11-17 with
# /usr/sbin off the PATH: 2 passed, 1 failed). So only the clamp's checks wait on it, and without it
# they are said as unmeasured (L411). A function, so the same checks run a second time below with
# taskpolicy taken off the PATH. Sets OFF_MACOS and HAVE_CLAMP.
priority_checks() {
  local label="$1" cache="$2" start got
  OFF_MACOS=0
  if [ "$(uname -s)" != Darwin ]; then
    # Off macOS there is nothing to raise: the gate still judges, and says so in its trace. The level
    # itself is untaken here, said so in the one shape the runner counts, never passed (L411).
    OFF_MACOS=1
    judge env SLACK_GATE_CACHE_DIR="$cache"
    allowed "${label}off macOS a plain script run is still judged and allowed"
    case "$QOS_LINE" in
      "qos: not raised: not macOS") check "${label}and the gate traces that it did not raise its priority" ok ;;
      *) check "${label}and the gate traces that it did not raise its priority" "trace: $(tr '\n' '|' < "$T/trace")" ;;
    esac
    echo "SUITE-PART-UNMEASURED the gate's scheduling priority is read only on macOS, and this is $(uname -s)"
    return 0
  fi
  HAVE_CLAMP=1
  command -v taskpolicy >/dev/null 2>&1 || HAVE_CLAMP=0

  start="$(qos_prio)"
  case "$start" in ''|*[!0-9]*) check "${label}the suite reads the level a python3 it starts runs at" "read: $start" ;; esac

  judge env SLACK_GATE_CACHE_DIR="$cache"
  allowed "${label}the control: a plain script run is judged and allowed"
  case "$QOS_LINE" in
    "qos: user-initiated, base priority "*)
      got="${QOS_LINE##* }"
      if [ "$got" -gt "${start:-99}" ] 2>/dev/null && [ "$got" -gt 31 ]; then
        check "${label}the gate judges above the level it was started at ($start), read from the kernel" ok
      else
        check "${label}the gate judges above the level it was started at ($start), read from the kernel" "$QOS_LINE"
      fi ;;
    *) check "${label}the gate traces the priority it judges at" "trace: $(tr '\n' '|' < "$T/trace")" ;;
  esac

  # The failure path: a QoS clamp is a ceiling nothing inside the process can lift (measured: under
  # taskpolicy -c utility the base priority stays 20 after the raise). The gate still judges, and its
  # trace says it could not raise, with the level it really ran at. A cache of its own, so the allow
  # the control stored cannot answer it: the call is judged afresh at the clamped level (L159).
  if [ "$HAVE_CLAMP" -eq 1 ]; then
    judge env SLACK_GATE_CACHE_DIR="$cache-clamp" taskpolicy -c utility
    allowed "${label}under a utility clamp the same call is still judged and allowed"
    if grep -q '^miss: ' "$T/trace" && ! grep -qx 'hit' "$T/trace"; then
      check "${label}and it was judged afresh under the clamp, not answered from the cache" ok
    else
      check "${label}and it was judged afresh under the clamp, not answered from the cache" "trace: $(tr '\n' '|' < "$T/trace")"
    fi
    case "$QOS_LINE" in
      "qos: not raised"*"base priority 20") check "${label}and the gate says it could not raise its priority, naming the level it ran at" ok ;;
      *) check "${label}and the gate says it could not raise its priority, naming the level it ran at" "trace: $(tr '\n' '|' < "$T/trace")" ;;
    esac
    # Run out of time under the clamp, and the refusal says the gate could not raise its priority, the
    # likeliest reason it ran out (L11). The step clock (SLACK_GATE_TICK_BUDGET) makes it run out at once.
    OUT="$(payload Bash "$(bash_input "bash $T/run.sh")" | HOOK_TESTS_RUNNING=1 SLACK_GATE_TICK_BUDGET=1 taskpolicy -c utility bash "$HOOK" 2>"$T/err")"; RC=$?
    ERR="$(cat "$T/err")"
    refused "${label}out of time under the clamp is refused"
    says "${label}and the refusal says the gate could not raise its scheduling priority" "could not raise its scheduling priority"
    says "${label}naming the level it ran at" "base priority 20"
  else
    echo "SUITE-PART-UNMEASURED the gate under a QoS clamp, because taskpolicy, which sets one, is not on this PATH"
  fi
}

priority_checks "" "$T/gate-cache"
if [ "$OFF_MACOS" -eq 1 ]; then
  echo
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit
fi

# The same checks again with taskpolicy taken off the PATH, the run that failed on a Mac
# (claude-config#3151): the raise must still be measured and pass, and only the clamp's checks may
# go unmeasured. Where taskpolicy was never on the PATH, the run above was already that run. A cache
# of its own, so the call is judged afresh. What the second run prints is kept in a file and only
# its failures shown: its unmeasured line is expected, and the clamp was measured above.
if [ "$HAVE_CLAMP" -eq 1 ]; then
  WITH_TASKPOLICY_PATH="$PATH"
  bare_path=""
  IFS=: read -r -a path_dirs <<< "$PATH"
  for d in ${path_dirs[@]+"${path_dirs[@]}"}; do
    [ -x "$d/taskpolicy" ] || bare_path="${bare_path:+$bare_path:}$d"
  done
  PATH="$bare_path"
  if command -v taskpolicy >/dev/null 2>&1; then
    check "taskpolicy is taken off the PATH for the second run" "still found: $(command -v taskpolicy)"
  else
    before_second=$pass
    priority_checks "with taskpolicy off the PATH: " "$T/gate-cache-bare" > "$T/second.out"
    grep '^FAIL' "$T/second.out"
    if [ "$OFF_MACOS" -eq 0 ] && [ $((pass - before_second)) -eq 2 ]; then
      check "with taskpolicy off the PATH the suite still measures the raise on a Mac (2 checks)" ok
    else
      check "with taskpolicy off the PATH the suite still measures the raise on a Mac (2 checks)" "off macOS branch: $OFF_MACOS, passed there: $((pass - before_second)), said: $(tr '\n' '|' < "$T/second.out")"
    fi
    if [ "$HAVE_CLAMP" -eq 0 ] && grep -q '^SUITE-PART-UNMEASURED the gate under a QoS clamp' "$T/second.out"; then
      check "and says the clamp's checks as unmeasured" ok
    else
      check "and says the clamp's checks as unmeasured" "said: $(tr '\n' '|' < "$T/second.out")"
    fi
  fi
  PATH="$WITH_TASKPOLICY_PATH"
fi
OUT="$(payload Bash "$(bash_input "bash $T/run.sh")" | HOOK_TESTS_RUNNING=1 SLACK_GATE_TICK_BUDGET=1 bash "$HOOK" 2>"$T/err")"; RC=$?
ERR="$(cat "$T/err")"
refused "the control: out of time with no clamp is refused too"
says "and says it ran out of time" "ran out of time"
lacks "but says nothing of the priority, which was raised" "scheduling priority"

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

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
