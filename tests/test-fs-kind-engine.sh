#!/usr/bin/env bash
# The engine's $.fs reports a fifo and /dev/stdin as kind `other`, never `file`, and a folder
# listing never calls a fifo a file (claude-config#1830), kept measured against the REAL Claude Code
# engine (L82).
#
# mod-kit's inputTexts and currentText (hooks/inputs.ts, #1765 and #1814) keep the mods from
# hanging on a fifo or a device by opening only what $.fs.stat calls a `file`, and the design round
# guard reads only what a listing calls one. `claude plugin test` runs against a stand-in disk that
# cannot reach the real file system, so the only proof was a one off headless probe on 2026-10-27.
# tests/fs-kind-engine-check.sh makes that probe a standing one: a probe mod (tests/fs-kind-probe)
# run headless against a real mkfifo in a mktemp folder, /dev/stdin, a link to it and an ordinary
# file as the control. The model is the scripted stand-in (tests/sleep-real-engine-model.py), so a
# run costs no tokens; even so the probe runs once per Claude Code version (and again only when the
# probe itself changes), and every other run reports the stored result for that version, saying
# when it was measured. The store is ~/.claude-engine-checks/fs-kinds, outside the repository and
# outside anything the sync carries.
#
# Part one drives the script with a stub claude, so every decision it makes is seen: no claude, CI,
# switched off, a version it cannot read, a first measurement, the stored one reused, a new version,
# a changed probe, a corrupt store, a probe that times out, one that answers nothing, and each wrong
# kind. Part two runs it for real on this Mac, where it says SUITE-PART-UNMEASURED (never a pass)
# whenever it cannot measure: no claude, CI, or the probe not answering within its deadline.
# FS_KIND_REAL_ENGINE=0 skips part two.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0
fail=0
unmeasured_parts=""
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); echo "ok: $1"; else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

HELPER="$DIR/fs-kind-engine-check.sh"
REAL_HOME="$HOME"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-fs-kind-engine.XXXXXX")"
case "${WORK%/}" in
  ''|/|"${REAL_HOME%/}")
    echo "FAIL: $(basename "$0"): refusing to run: the throwaway directory came back as '$WORK'."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1 ;;
esac
trap 'rm -rf "$WORK"' EXIT

# ---- part one: the decisions, with a stub claude ----
# The stub answers --version with STUB_VERSION (none: prints nothing and fails). As the engine
# (-p), it records the call, what it was handed and its own pid in STUB_CALLS, then per STUB_MODE
# answers as the probe mod would (reading the fixture from disk, so a fifo that is not a real fifo
# is reported as what it really is), hangs, or exits having answered nothing. STUB_KINDS overrides
# answers, as key=value words.
STUB="$WORK/stub-claude"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  [ "${STUB_VERSION:-}" = none ] && exit 1
  echo "${STUB_VERSION:-9.9.9} (Claude Code)"
  exit 0
fi
plugin=""
while [ $# -gt 0 ]; do [ "$1" = --plugin-dir ] && plugin="$2"; shift; done
[ -f "$plugin/hooks/register.ts" ] && p=probe-loaded || p=no-probe
printf 'call pid=%s %s home=%s base=%s\n' "$$" "$p" "$HOME" "${ANTHROPIC_BASE_URL:-}" >> "$STUB_CALLS"
case "${STUB_MODE:-answer}" in
  hang) sleep 600; exit 0 ;;
  silent) exit 0 ;;
esac
d="$FS_KIND_PROBE_DIR"
kind() { if [ -p "$1" ]; then echo other; elif [ -L "$1" ]; then echo other; elif [ -f "$1" ]; then echo file; else echo missing; fi; }
fifo="$(kind "$d/probe.fifo")"; plain="$(kind "$d/plain.txt")"
[ -L "$d/stdin.link" ] && link=other || link=missing
{
  echo "fifo=$fifo"; echo "devnull=other"; echo "stdin=other"; echo "stdin_link=$link"; echo "plain=$plain"
  echo "list_fifo=$fifo"; echo "list_plain=$plain"; echo "list_files=plain.txt"
} > "$FS_KIND_PROBE_OUT.stub"
for kv in ${STUB_KINDS:-}; do
  grep -v "^${kv%%=*}=" "$FS_KIND_PROBE_OUT.stub" > "$FS_KIND_PROBE_OUT.stub2"
  echo "$kv" >> "$FS_KIND_PROBE_OUT.stub2"
  mv "$FS_KIND_PROBE_OUT.stub2" "$FS_KIND_PROBE_OUT.stub"
done
cat "$FS_KIND_PROBE_OUT.stub" >> "$FS_KIND_PROBE_OUT"
rm -f "$FS_KIND_PROBE_OUT.stub"
[ "${STUB_NO_DONE:-}" = 1 ] || echo done=1 >> "$FS_KIND_PROBE_OUT"
exit 0
SH
chmod +x "$STUB"

CALLS="$WORK/calls"
SCRATCH_TMP="$WORK/tmp"
mkdir -p "$SCRATCH_TMP"
OUT=""
CODE=0
# run_stub STORE [VAR=value...]: the script with the stub as claude, its scratch files in
# SCRATCH_TMP, CI and the switch cleared. Sets OUT and CODE.
run_stub() {
  local store="$1"; shift
  OUT="$(env -u CI -u FS_KIND_REAL_ENGINE FS_KIND_CLAUDE="$STUB" FS_KIND_STORE="$store" \
    STUB_CALLS="$CALLS" TMPDIR="$SCRATCH_TMP" "$@" bash "$HELPER" 2>&1)"
  CODE=$?
}
calls() { if [ -f "$CALLS" ]; then grep -c '^call ' "$CALLS"; else echo 0; fi; }
verdict() { printf '%s\n' "$OUT" | grep '^FS-KIND-VERDICT ' | tail -1; }
# Matched from a here string or a case, never a pipe into grep -q, which can stop reading early and
# fail its producer under pipefail (test-pipefail-shortcircuit.sh).
said() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
says() { grep -q -- "$1" <<< "$(verdict)"; }
show() { printf '%s' "exit=$CODE verdict=[$(verdict)] out=$(printf '%s' "$OUT" | tr '\n' '|' | cut -c1-600)"; }

if [ ! -f "$HELPER" ]; then
  check "the check script is tests/fs-kind-engine-check.sh" "it is missing"
fi

# Nothing to run with: no claude on PATH, a named claude that is not there, CI, the switch.
STORE="$WORK/store-none"
OUT="$(env -u CI -u FS_KIND_REAL_ENGINE -u FS_KIND_CLAUDE PATH="$WORK/empty-bin:/usr/bin:/bin" FS_KIND_STORE="$STORE" TMPDIR="$SCRATCH_TMP" bash "$HELPER" 2>&1)"; CODE=$?
[ "$CODE" -eq 3 ] && says '^FS-KIND-VERDICT unmeasured .*no claude command on PATH' \
  && check "no claude on PATH is unmeasured, never a pass" ok || check "no claude on PATH is unmeasured, never a pass" "$(show)"
run_stub "$STORE" FS_KIND_CLAUDE="$WORK/not-there"
[ "$CODE" -eq 3 ] && says '^FS-KIND-VERDICT unmeasured .*no claude at ' \
  && check "a named claude that is not there is unmeasured" ok || check "a named claude that is not there is unmeasured" "$(show)"
run_stub "$STORE" CI=true
[ "$CODE" -eq 3 ] && says '^FS-KIND-VERDICT unmeasured .*CI' && [ "$(calls)" = 0 ] \
  && check "under CI it is unmeasured and runs nothing" ok || check "under CI it is unmeasured and runs nothing" "$(show) calls=$(calls)"
run_stub "$STORE" FS_KIND_REAL_ENGINE=0
[ "$CODE" -eq 3 ] && says '^FS-KIND-VERDICT unmeasured .*FS_KIND_REAL_ENGINE=0' && [ "$(calls)" = 0 ] \
  && check "FS_KIND_REAL_ENGINE=0 is unmeasured and runs nothing" ok || check "FS_KIND_REAL_ENGINE=0 is unmeasured and runs nothing" "$(show) calls=$(calls)"
run_stub "$STORE" STUB_VERSION=none
[ "$CODE" -eq 3 ] && says '^FS-KIND-VERDICT unmeasured .*version' && [ "$(calls)" = 0 ] \
  && check "a claude whose version cannot be read is unmeasured and runs nothing" ok || check "a claude whose version cannot be read is unmeasured and runs nothing" "$(show) calls=$(calls)"
[ ! -e "$STORE" ] || [ -z "$(ls -A "$STORE")" ] \
  && check "and none of those stored anything" ok || check "and none of those stored anything" "$(ls -A "$STORE")"

# A first measurement: the probe runs once, isolated, against a real fifo, and its result is kept
# for that version.
STORE="$WORK/store"
: > "$CALLS"
run_stub "$STORE" STUB_VERSION=2.1.900
[ "$CODE" -eq 0 ] && says '^FS-KIND-VERDICT pass ' && [ "$(calls)" = 1 ] \
  && check "a new version is probed once, and the right kinds pass" ok || check "a new version is probed once, and the right kinds pass" "$(show) calls=$(calls)"
said "measured now" && said "2.1.900" \
  && check "and it says it measured now, on which version" ok || check "and it says it measured now, on which version" "$(show)"
grep -q 'probe-loaded' "$CALLS" \
  && check "the engine is handed the probe mod" ok || check "the engine is handed the probe mod" "$(cat "$CALLS")"
grep '^call ' "$CALLS" > "$WORK/calls-seen"; grep -v "home=${REAL_HOME} " "$WORK/calls-seen" > "$WORK/calls-away"; grep -q 'base=http://127.0.0.1:' "$WORK/calls-away" \
  && check "in a scratch home, with the stand-in model, so no real hook, mod or token is touched" ok \
  || check "in a scratch home, with the stand-in model, so no real hook, mod or token is touched" "$(cat "$CALLS")"
[ -f "$STORE/claude-2.1.900.txt" ] && grep -q '^fifo=other$' "$STORE/claude-2.1.900.txt" \
  && check "the result is stored under that version" ok || check "the result is stored under that version" "$(ls -A "$STORE" 2>&1)"
[ -z "$(ls -A "$SCRATCH_TMP")" ] \
  && check "every probe file, the fifo with them, is deleted afterwards" ok || check "every probe file, the fifo with them, is deleted afterwards" "$(ls -A "$SCRATCH_TMP")"

# The same version again: no probe, the stored result, said as measured earlier and when.
run_stub "$STORE" STUB_VERSION=2.1.900
[ "$CODE" -eq 0 ] && says '^FS-KIND-VERDICT pass ' && [ "$(calls)" = 1 ] \
  && check "the same version again reuses the stored result and runs no probe" ok || check "the same version again reuses the stored result and runs no probe" "$(show) calls=$(calls)"
sed 's/^measured=.*/measured=1000000000/' "$STORE/claude-2.1.900.txt" > "$WORK/planted" && mv "$WORK/planted" "$STORE/claude-2.1.900.txt"
run_stub "$STORE" STUB_VERSION=2.1.900
said "measured earlier" && said "2001-09-08 21:46 ET" \
  && check "and says it was measured earlier, and when, in Eastern time" ok || check "and says it was measured earlier, and when, in Eastern time" "$(show)"

# A new version is probed again; a changed probe is probed again.
run_stub "$STORE" STUB_VERSION=2.1.901
[ "$CODE" -eq 0 ] && [ "$(calls)" = 2 ] && [ -f "$STORE/claude-2.1.901.txt" ] \
  && check "a changed version is probed again" ok || check "a changed version is probed again" "$(show) calls=$(calls)"
cp -R "$DIR/fs-kind-probe" "$WORK/probe-copy"
run_stub "$STORE" STUB_VERSION=2.1.901 FS_KIND_PROBE_SRC="$WORK/probe-copy"
echo '// changed' >> "$WORK/probe-copy/hooks/register.ts"
run_stub "$STORE" STUB_VERSION=2.1.901 FS_KIND_PROBE_SRC="$WORK/probe-copy"
[ "$CODE" -eq 0 ] && [ "$(calls)" = 3 ] && said "probe has changed" \
  && check "a changed probe is probed again, and says why" ok || check "a changed probe is probed again, and says why" "$(show) calls=$(calls)"

# A stored result that cannot be read is measured again, never trusted, and replaced.
printf 'garbage\n' > "$STORE/claude-2.1.901.txt"
run_stub "$STORE" STUB_VERSION=2.1.901
[ "$CODE" -eq 0 ] && [ "$(calls)" = 4 ] && said "could not be read" && grep -q '^fifo=other$' "$STORE/claude-2.1.901.txt" \
  && check "a corrupt stored result is measured again and replaced" ok || check "a corrupt stored result is measured again and replaced" "$(show) calls=$(calls)"
grep -v '^stdin_link=' "$STORE/claude-2.1.901.txt" > "$WORK/partial" && mv "$WORK/partial" "$STORE/claude-2.1.901.txt"
run_stub "$STORE" STUB_VERSION=2.1.901
[ "$CODE" -eq 0 ] && [ "$(calls)" = 5 ] && said "it lacks stdin_link" && grep -q '^stdin_link=other$' "$STORE/claude-2.1.901.txt" \
  && check "a stored result missing one kind is measured again, never judged on what is left" ok || check "a stored result missing one kind is measured again, never judged on what is left" "$(show) calls=$(calls)"

# A probe that never answers is stopped at its deadline and is unmeasured; nothing is stored and
# nothing it started is left running. The deadline is a window the stub always runs out.
STORE="$WORK/store-hang"
: > "$CALLS"
run_stub "$STORE" STUB_VERSION=2.1.902 STUB_MODE=hang FS_KIND_DEADLINE=2
pid="$(sed -n 's/^call pid=\([0-9]*\) .*/\1/p' "$CALLS")"
[ "$CODE" -eq 3 ] && says '^FS-KIND-VERDICT unmeasured .*deadline' \
  && check "a probe that does not answer within its deadline is unmeasured" ok || check "a probe that does not answer within its deadline is unmeasured" "$(show)"
[ ! -e "$STORE/claude-2.1.902.txt" ] && [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null \
  && check "and nothing is stored, and the stopped engine is not left running" ok || check "and nothing is stored, and the stopped engine is not left running" "pid=$pid store=$(ls -A "$STORE" 2>&1)"
[ -z "$(ls -A "$SCRATCH_TMP")" ] \
  && check "and its probe files are deleted too" ok || check "and its probe files are deleted too" "$(ls -A "$SCRATCH_TMP")"

# An engine that ran but whose probe answered nothing (the mod never loaded), or answered only part.
run_stub "$STORE" STUB_VERSION=2.1.902 STUB_MODE=silent
[ "$CODE" -eq 3 ] && says '^FS-KIND-VERDICT unmeasured .*answered nothing' && [ ! -e "$STORE/claude-2.1.902.txt" ] \
  && check "a probe that answered nothing is unmeasured, and nothing is stored" ok || check "a probe that answered nothing is unmeasured, and nothing is stored" "$(show)"
run_stub "$STORE" STUB_VERSION=2.1.902 STUB_NO_DONE=1
[ "$CODE" -eq 3 ] && says '^FS-KIND-VERDICT unmeasured .*cut short' && [ ! -e "$STORE/claude-2.1.902.txt" ] \
  && check "a record cut short is unmeasured, and nothing is stored" ok || check "a record cut short is unmeasured, and nothing is stored" "$(show)"

# Each wrong kind fails, naming what was wrong; a measured wrong kind is stored, so the same
# version keeps failing without probing again.
wrong() {  # name STUB_KINDS expected-words
  STORE="$WORK/store-$2"; STORE="${STORE//[^A-Za-z0-9\/._-]/_}"
  : > "$CALLS"
  run_stub "$STORE" STUB_VERSION=2.1.903 STUB_KINDS="$2"
  [ "$CODE" -eq 1 ] && says "^FS-KIND-VERDICT fail .*$3" \
    && check "$1 fails" ok || check "$1 fails" "$(show)"
}
wrong "a fifo stat reports as a file" "fifo=file" "fifo"
run_stub "$STORE" STUB_VERSION=2.1.903 STUB_KINDS="fifo=file"
[ "$CODE" -eq 1 ] && [ "$(calls)" = 1 ] && said "measured earlier" \
  && check "and the same version keeps failing from the stored result, with no new probe" ok || check "and the same version keeps failing from the stored result, with no new probe" "$(show) calls=$(calls)"
wrong "/dev/null, a device, reported as a file" "devnull=file" "/dev/null"
wrong "/dev/stdin reported as a file" "stdin=file" "/dev/stdin"
wrong "/dev/stdin reported as a folder" "stdin=dir" "/dev/stdin"
wrong "a link to /dev/stdin reported as a file" "stdin_link=file" "link to /dev/stdin"
wrong "a device that throws" "devnull=error:EPERM" "devnull threw (error:EPERM)"
wrong "a listing calling the fifo a file" "list_fifo=file list_files=plain.txt,probe.fifo" "listing called the fifo file"
wrong "a listing calling the fifo a file, alone" "list_fifo=file" "listing called the fifo file"
wrong "a listing calling any name but the control a file" "list_files=plain.txt,stdin.link" "stdin.link"
wrong "the control, an ordinary file, not reported as a file" "plain=other" "ordinary file"
wrong "a stat that throws" "fifo=error:EPERM" "fifo threw (error:EPERM)"
[ ! -e "$WORK/store-fifo_error_EPERM/claude-2.1.903.txt" ] \
  && check "and a stat that throws is not stored, so the next run measures again" ok || check "and a stat that throws is not stored, so the next run measures again" "$(ls -A "$WORK/store-fifo_error_EPERM" 2>&1)"

# /dev/stdin asked as mod-kit asks (links followed) leads through /dev/fd/0 to whatever the engine's
# own standard input is, and in a headless run Claude Code 2.1.312 cannot resolve that and throws
# EBADF (measured 2026-10-27). A throw is never `file`, so no mod reads it: that passes, says the
# exact answer, and is stored like any other measurement.
STORE="$WORK/store-ebadf"
: > "$CALLS"
run_stub "$STORE" STUB_VERSION=2.1.904 "STUB_KINDS=stdin=error:x_failed:_EBADF stdin_link=error:x_failed:_EBADF"
[ "$CODE" -eq 0 ] && says '^FS-KIND-VERDICT pass .*/dev/stdin could not be looked at (EBADF).*link to it could not be looked at (EBADF)' \
  && check "/dev/stdin and a link to it that cannot be looked at are never a file: they pass, saying so" ok \
  || check "/dev/stdin and a link to it that cannot be looked at are never a file: they pass, saying so" "$(show)"
run_stub "$STORE" STUB_VERSION=2.1.904
[ "$CODE" -eq 0 ] && [ "$(calls)" = 1 ] && said "measured earlier" && says '(EBADF)' \
  && check "and that answer is stored, so the same version is not probed again" ok || check "and that answer is stored, so the same version is not probed again" "$(show) calls=$(calls)"

# ---- part two: the real engine on this Mac ----
if [ "${FS_KIND_REAL_ENGINE:-}" = 0 ]; then
  unmeasured_parts="the fs kinds on the real Claude Code engine were not checked: FS_KIND_REAL_ENGINE=0 skips it"
else
  REAL_OUT="$(bash "$HELPER" 2>&1)"; REAL_CODE=$?
  printf '%s\n' "$REAL_OUT" | grep -v '^FS-KIND-VERDICT ' | sed 's/^/   /'
  why="$(printf '%s\n' "$REAL_OUT" | sed -n 's/^FS-KIND-VERDICT [a-z]* //p' | tail -1)"
  case "$REAL_CODE" in
    0) check "on this Mac's Claude Code: $why" ok ;;
    3) unmeasured_parts="the fs kinds on the real Claude Code engine: $why" ;;
    *) check "on this Mac's Claude Code, \$.fs reports a fifo and /dev/stdin as other and lists no fifo as a file" "${why:-the check printed no verdict, exit $REAL_CODE}" ;;
  esac
  # A headless run measures /dev/stdin as its own standard input is; an interactive session's is a
  # terminal, which no headless run can be.
  [ "$REAL_CODE" = 3 ] || echo "SUITE-PART-UNMEASURED what /dev/stdin reads as in an interactive session, whose standard input is a terminal; the probe is a headless run and measures its own"
fi

[ -n "$unmeasured_parts" ] && echo "SUITE-PART-UNMEASURED $unmeasured_parts"
printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
