#!/usr/bin/env bash
# A git apply of a 2,000 line patch, on the REAL Claude Code with every mod loaded, answered inside the
# hooks worker's heartbeat (claude-config#2948).
#
# On 2026-11-13 and 14, in a work repository, `git apply <patch>` of a 2,234 line patch changing seven
# files under docs/design (three 720 line captured pages, four edits) failed five times with "no answer
# to a heartbeat within 5000ms: the hooks worker is wedged (a hook spinning without yielding)". Measured
# on 2026-11-14 with Claude Code 2.1.325: a captured page inlines its fonts as base64, and the design
# round guard's name reader before #2972 read each such run for minutes; the engine's debug log said
# "the heartbeat verdict names design-round-guard". No mod's own test can see this, since the
# heartbeat belongs to the engine's hooks worker, and `claude plugin test` has none.
#
# A run: a headless `claude -p` in a scratch HOME (none of this Mac's hooks, settings or installed
# mods), its model the scripted stand in tests/sleep-real-engine-model.py on 127.0.0.1, which runs one
# Bash call, `git apply` of the patch tests/large-apply-patch.py makes in a scratch checkout. Its debug
# log is then read.
#   - every: every mod in payload/mods. No heartbeat is missed, every tool.check and tool.call hook
#     settles within the heartbeat, and the call has its answer: applied, or held by a guard (the
#     design round guard holds it here, since nobody has answered for the scratch checkout).
#   - whole (the control, L1): mod-kit and tests/large-apply-probe, a stand-in hook reading for 7 s in
#     one stretch. The heartbeat is missed, so this suite is seen to catch a hook that stops answering,
#     and the engine's log names the stand-in, which is how the hook that did not answer is named.
#   - pieces: the same 7 s read in stretches of 50 ms with the pause the design round guard takes
#     between pieces (a call to $.clock.now()). No heartbeat is missed and the hook settles after its 7 s, so that
#     pause keeps the worker answering through a reading longer than the heartbeat.
#
# It says SUITE-PART-UNMEASURED, never a pass, when it cannot measure: CI (no Claude Code there), no
# claude, python3 or git, or a session that does not finish within its deadline.
# LARGE_APPLY_CLAUDE names the claude to run (default the one on PATH); LARGE_APPLY_REAL_ENGINE=0 skips.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
. "$ROOT/payload/hooks/lib/hang-wait.sh" || {
  echo "FAIL: $(basename "$0"): lib/hang-wait.sh is missing."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); echo "ok: $1"; else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
finish() { printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"; [ "$fail" -eq 0 ]; exit $?; }
unmeasured() { echo "SUITE-PART-UNMEASURED whether a large git apply is answered inside the heartbeat on the real Claude Code: $1"; finish; }

[ "${LARGE_APPLY_REAL_ENGINE:-}" = 0 ] && unmeasured "switched off by LARGE_APPLY_REAL_ENGINE=0"
case "${CI:-}" in ''|false|0) ;; *) unmeasured "running under CI (CI=$CI), where there is no Claude Code to run" ;; esac
CLAUDE_BIN="${LARGE_APPLY_CLAUDE:-$(command -v claude || true)}"
[ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ] || unmeasured "there is no claude command to run the engine with"
command -v python3 >/dev/null 2>&1 || unmeasured "there is no python3 to run the stand in model with"
command -v git >/dev/null 2>&1 || unmeasured "there is no git to make the patch with"
VERSION="$("$CLAUDE_BIN" --version 2>/dev/null)"
VERSION="${VERSION%% *}"
HEARTBEAT_MS=5000

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-large-git-apply-engine.XXXXXX")"
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "FAIL: refusing to run: the throwaway directory came back as '$WORK'."; fail=1; finish ;;
esac
MODEL_PID=""
cleanup() { if [ -n "$MODEL_PID" ]; then { kill "$MODEL_PID"; wait "$MODEL_PID"; } 2>/dev/null; fi; rm -rf "$WORK"; }
trap cleanup EXIT

# Copies, so the types the engine lays into a loaded mod's folder never land in the checkout.
cp -R "$ROOT/payload/mods" "$WORK/mods" || unmeasured "payload/mods could not be copied to $WORK"
cp -R "$DIR/large-apply-probe" "$WORK/probe" || unmeasured "tests/large-apply-probe could not be copied to $WORK"

python3 "$DIR/sleep-real-engine-model.py" "$WORK/model.port" "$WORK/model.log" &
MODEL_PID=$!
hang_wait '[ -s "$WORK/model.port" ]'
[ -s "$WORK/model.port" ] || unmeasured "the stand in model did not start within ${HANG_S}s"
PORT="$(cat "$WORK/model.port")"

# run_session LABEL PROBE_MODE DIRS: one headless session applying a fresh copy of the patch in its
# own scratch checkout. Its debug log is $WORK/LABEL.log, its output $WORK/LABEL.jsonl. Returns 3
# when it could not measure.
run_session() {
  local label="$1" mode="$2" dirs="$3" shape summary
  if ! shape="$(python3 "$DIR/large-apply-patch.py" "$WORK/$label-repo" 2>&1)"; then
    echo "SUITE-PART-UNMEASURED the $label patch could not be made: $(printf '%s' "$shape" | tr '\n' ' ' | cut -c1-300)"
    return 3
  fi
  read -r PATCH_LINES PATCH_BYTES PATCH_FILES <<<"$shape"
  mkdir -p "$WORK/$label-home"
  summary="$(cd "$WORK/$label-repo" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_SESSION_ID \
    LARGE_APPLY_PROBE="$mode" HOME="$WORK/$label-home" CLAUDE_CODE_PLUGIN_DIRS="$dirs" ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" ANTHROPIC_API_KEY=test-key-not-real \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 SHELL=/bin/bash \
    python3 "$DIR/sleep-real-engine-session.py" "$WORK/$label.jsonl" "$HANG_S" 1 "PROBE-RUN: git apply $WORK/$label-repo/design.patch" -- \
      "$CLAUDE_BIN" -p --model haiku --setting-sources project --allowedTools Bash \
      --input-format stream-json --output-format stream-json --verbose --debug-file "$WORK/$label.log" 2>&1)"
  case "$summary" in *'"timed_out": true'*) echo "SUITE-PART-UNMEASURED the $label session did not finish within ${HANG_S}s on Claude Code $VERSION"; return 3 ;; esac
  [ -s "$WORK/$label.log" ] || { echo "SUITE-PART-UNMEASURED the $label session wrote no debug log on Claude Code $VERSION: $(printf '%s' "$summary" | tr '\n' ' ' | cut -c1-300)"; return 3; }
  return 0
}

# The engine's line for each tool hook dispatch through the hooks worker: "<mods> tool.check settled
# in 208.4ms (worker hop, ...)". Prints "<event> <ms>" per line.
settled() { sed -n -E 's/.* (tool\.(check|call)) settled in ([0-9.]+)ms \(worker hop.*/\1 \3/p' "$WORK/$1.log"; }
missed() { grep -c 'no answer to a heartbeat within' "$WORK/$1.log"; }
answered() { grep -c '"type":"tool_result"' "$WORK/$1.jsonl"; }

echo "Measuring Claude Code $VERSION: headless sessions applying a large patch, a stand in model and a ${HANG_S}s deadline each."

every=""
for d in "$WORK/mods"/*/; do
  [ -f "$d.claude-plugin/plugin.json" ] && [ -f "${d}hooks/hooks.json" ] || continue
  every="${every:+$every:}${d%/}"
done
if run_session every "" "$every:$WORK/probe"; then
  if [ "$PATCH_LINES" -ge 2000 ] && [ "$PATCH_FILES" -eq 7 ]; then check "every: the patch is at least 2,000 lines across seven files ($PATCH_LINES lines, $PATCH_BYTES bytes)" ok
  else check "every: the patch is at least 2,000 lines across seven files" "it is $PATCH_LINES lines across $PATCH_FILES files"; fi
  n="$(missed every)"
  if [ "$n" -eq 0 ]; then check "every: no hook missed the hooks worker's heartbeat" ok
  else check "every: no hook missed the hooks worker's heartbeat" "missed $n times; the engine named: $(grep -o 'heartbeat verdict names [^ ]*' "$WORK/every.log" | sort -u | tr '\n' ' ')"; fi
  # The control for the timings: a dispatch of each was seen at all, so none missing reads as none slow (L98).
  for ev in tool.check tool.call; do
    times="$(settled every | awk -v e="$ev" '$1 == e { print $2 }')"
    if [ -z "$times" ]; then check "every: each $ev dispatch settled within ${HEARTBEAT_MS}ms" "the engine logged no $ev dispatch through the hooks worker"; continue; fi
    worst="$(printf '%s\n' "$times" | sort -n | tail -1)"
    if awk -v w="$worst" -v h="$HEARTBEAT_MS" 'BEGIN { exit !(w < h) }'; then check "every: each $ev dispatch settled within ${HEARTBEAT_MS}ms (slowest ${worst}ms)" ok
    else check "every: each $ev dispatch settled within ${HEARTBEAT_MS}ms" "the slowest took ${worst}ms"; fi
  done
  if [ "$(answered every)" -ge 1 ]; then check "every: the git apply call was answered" ok
  else check "every: the git apply call was answered" "no tool result in the session's output"; fi
fi

if run_session whole whole "$WORK/mods/mod-kit:$WORK/probe"; then
  if [ "$(missed whole)" -ge 1 ]; then check "whole (control): a hook reading 7 s in one stretch misses the heartbeat, and this suite sees it" ok
  else check "whole (control): a hook reading 7 s in one stretch misses the heartbeat, and this suite sees it" "no missed heartbeat in the log, so this suite cannot see one"; fi
  if grep -q 'heartbeat verdict names large-apply-probe' "$WORK/whole.log"; then check "whole (control): the engine names the hook that did not answer" ok
  else check "whole (control): the engine names the hook that did not answer" "the engine said: $(grep -o 'heartbeat verdict names .*' "$WORK/whole.log" | head -1)"; fi
fi

if run_session pieces pieces "$WORK/mods/mod-kit:$WORK/probe"; then
  n="$(missed pieces)"
  if [ "$n" -eq 0 ]; then check "pieces: a hook reading 7 s with a clock call between pieces never misses the heartbeat" ok
  else check "pieces: a hook reading 7 s with a clock call between pieces never misses the heartbeat" "missed $n times"; fi
  # Its own dispatch outlasting the heartbeat is what makes the line above a measurement.
  slowest="$(settled pieces | awk '$1 == "tool.check" { print $2 }' | sort -n | tail -1)"
  if [ -n "$slowest" ] && awk -v w="$slowest" -v h="$HEARTBEAT_MS" 'BEGIN { exit !(w >= h) }'; then check "pieces: the reading outlasted the heartbeat (${slowest}ms)" ok
  else check "pieces: the reading outlasted the heartbeat" "its tool.check settled in ${slowest:-no time logged}ms"; fi
fi
finish
