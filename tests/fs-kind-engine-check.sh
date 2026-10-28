#!/usr/bin/env bash
# Whether the REAL Claude Code engine's $.fs reports a fifo and /dev/stdin as kind `other`, and a
# folder listing calls no fifo a `file` (claude-config#1830, L82), measured once per Claude Code
# version and kept. Run by tests/test-fs-kind-engine.sh, which also drives every decision here with
# a stub claude.
#
# mod-kit's inputTexts and currentText (hooks/inputs.ts, #1765 and #1814) open only what $.fs.stat
# calls a `file`, and the design round guard reads only what a listing calls one, so a fifo or a
# device read as `file` would bring back the hangs those fixes ended. `claude plugin test` runs on a
# stand-in disk that cannot reach the real file system, so only the real engine can say.
#
# The probe: a headless `claude -p` in a scratch HOME (so none of this Mac's hooks, settings or
# mods load, only the probe mod tests/fs-kind-probe, handed over with --plugin-dir), whose model is
# the scripted stand-in tests/sleep-real-engine-model.py on 127.0.0.1 with a key that is not a real
# one, so it spends no tokens and needs no network. The stand-in makes one Bash call; the probe
# mod's tool.call hook asks $.fs about a mktemp folder holding a real fifo (mkfifo), a link to
# /dev/stdin and an ordinary file (the control, which must read as `file`), and asks about
# /dev/null and /dev/stdin themselves. Every probe file is deleted afterwards, however the run ends.
# What each answer must be is in judge, below.
#
# The cost is a Claude Code start (seconds, more on a loaded Mac), so the result is kept per
# version in FS_KIND_STORE (~/.claude-engine-checks/fs-kinds, outside the repository and outside
# anything the sync carries) and the probe runs again only for a new version, a changed probe, or a
# stored result that cannot be read. A run that cannot measure (no claude, CI, switched off, a
# version it cannot read, a probe that does not answer within FS_KIND_DEADLINE seconds, or answers
# nothing or only part) stores nothing and says unmeasured, never pass.
#
# Environment: FS_KIND_CLAUDE (the claude to run; default the one on PATH), FS_KIND_STORE,
# FS_KIND_DEADLINE (default the hang ceiling, lib/hang-wait.sh), FS_KIND_PROBE_SRC (the probe mod;
# default tests/fs-kind-probe), FS_KIND_REAL_ENGINE=0 (skip), CI.
#
# Prints what it did, then one last line `FS-KIND-VERDICT <pass|fail|unmeasured> <why>`, and exits
# 0, 1 or 3 to match.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
. "$ROOT/payload/hooks/lib/hang-wait.sh" || { echo "FS-KIND-VERDICT unmeasured lib/hang-wait.sh is missing"; exit 3; }

WORK=""
MODEL_PID=""
stop_model() { if [ -n "$MODEL_PID" ]; then { kill "$MODEL_PID"; wait "$MODEL_PID"; } 2>/dev/null; MODEL_PID=""; fi; }
cleanup() { stop_model; [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

verdict() {
  echo "FS-KIND-VERDICT $1 $2"
  case "$1" in pass) exit 0 ;; fail) exit 1 ;; *) exit 3 ;; esac
}

# The keys the probe answers, in its order; every one must be there for a record to count.
KEYS="fifo devnull stdin stdin_link plain list_fifo list_plain list_files"

# ---- whether it can measure at all ----
[ "${FS_KIND_REAL_ENGINE:-}" = 0 ] && verdict unmeasured "switched off: FS_KIND_REAL_ENGINE=0 skips it"
case "${CI:-}" in ''|false|0) ;; *) verdict unmeasured "running under CI (CI=$CI), where there is no Claude Code to run" ;; esac
if [ -n "${FS_KIND_CLAUDE+set}" ]; then CLAUDE_BIN="$FS_KIND_CLAUDE"; else CLAUDE_BIN="$(command -v claude || true)"; fi
[ -n "$CLAUDE_BIN" ] || verdict unmeasured "there is no claude command on PATH to run the engine with"
[ -x "$CLAUDE_BIN" ] || verdict unmeasured "there is no claude at $CLAUDE_BIN to run the engine with"
command -v python3 >/dev/null 2>&1 || verdict unmeasured "there is no python3 to run the stand-in model and the session with"
command -v mkfifo >/dev/null 2>&1 || verdict unmeasured "there is no mkfifo to make the fifo with"
VERSION="$("$CLAUDE_BIN" --version 2>/dev/null)"
VERSION="${VERSION%%$'\n'*}"
VERSION="${VERSION%% *}"
case "$VERSION" in
  [0-9]*) case "$VERSION" in *[!0-9A-Za-z.+-]*) VERSION="" ;; esac ;;
  *) VERSION="" ;;
esac
[ -n "$VERSION" ] || verdict unmeasured "the Claude Code version could not be read from $CLAUDE_BIN --version, so there is no version to key a result on"

PROBE_SRC="${FS_KIND_PROBE_SRC:-$DIR/fs-kind-probe}"
[ -f "$PROBE_SRC/hooks/register.ts" ] || verdict unmeasured "the probe mod is missing from $PROBE_SRC"
hash_of() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -c1-16; }
PROBE_HASH="$(cat "$PROBE_SRC/hooks/register.ts" "$PROBE_SRC/hooks/hooks.json" "$PROBE_SRC/.claude-plugin/plugin.json" "$SELF" 2>/dev/null | hash_of)"
STORE="${FS_KIND_STORE:-$HOME/.claude-engine-checks/fs-kinds}"
STORED="$STORE/claude-$VERSION.txt"

et_time() {  # epoch -> "YYYY-MM-DD HH:MM ET"
  TZ=America/New_York date -r "$1" '+%Y-%m-%d %H:%M ET' 2>/dev/null || TZ=America/New_York date -d "@$1" '+%Y-%m-%d %H:%M ET'
}

# value_of FILE KEY: the value of the last KEY= line, or nothing.
value_of() { sed -n "s/^$2=//p" "$1" | tail -1; }

# judge FILE: the verdict on the kinds FILE holds, in RESULT (pass or fail) and WHY, and THREW set
# when a look threw where no throw is an answer (such a record is not kept: the next run looks
# again). The fifo, /dev/null and the control must each be exactly what the mods rely on, and the
# control must read as a file, or the probe cannot tell kinds apart at all.
#
# /dev/stdin and a link to it are asked as mod-kit asks, links followed, which leads through
# /dev/fd/0 to whatever the engine's own standard input is: `other`, or, in a headless run of Claude
# Code 2.1.312, a throw (EBADF, measured 2026-10-27; asked without following links it was `other`).
# Either way no mod reads it as a file, which is the fact the fixes need, so both pass and the
# answer is said; only `file`, or any other kind, fails.
judge() {
  local f="$1" k v name full wrong="" stdin_said=""
  RESULT=""; WHY=""; THREW=""
  for k in fifo devnull plain list_fifo list_plain list_files; do
    v="$(value_of "$f" "$k")"
    case "$v" in error:*) wrong="$wrong; the probe's look for $k threw ($v)"; THREW=1 ;; esac
  done
  if [ -z "$wrong" ]; then
    [ "$(value_of "$f" plain)" = file ] || wrong="$wrong; the control, an ordinary file, read as $(value_of "$f" plain), so the probe cannot tell kinds apart"
    [ "$(value_of "$f" list_plain)" = file ] || wrong="$wrong; the control, an ordinary file, was listed as $(value_of "$f" list_plain)"
    [ "$(value_of "$f" fifo)" = other ] || wrong="$wrong; \$.fs.stat called a real fifo $(value_of "$f" fifo), not other"
    [ "$(value_of "$f" devnull)" = other ] || wrong="$wrong; \$.fs.stat called /dev/null, a device, $(value_of "$f" devnull), not other"
    [ "$(value_of "$f" list_fifo)" = other ] || wrong="$wrong; a folder listing called the fifo $(value_of "$f" list_fifo), not other"
    [ "$(value_of "$f" list_files)" = plain.txt ] || wrong="$wrong; a folder listing called $(value_of "$f" list_files) a file, where only plain.txt is one"
  fi
  for k in stdin stdin_link; do
    v="$(value_of "$f" "$k")"
    [ "$k" = stdin ] && name=/dev/stdin || name="a link to it"
    [ "$k" = stdin ] && full=/dev/stdin || full="a link to /dev/stdin"
    case "$v" in
      other) stdin_said="$stdin_said, $name as other" ;;
      error:*) stdin_said="$stdin_said, $name could not be looked at (${v##*[ _:]})" ;;
      *) wrong="$wrong; \$.fs.stat called $full $v, never other or a refusal" ;;
    esac
  done
  if [ -n "$wrong" ]; then
    RESULT=fail; WHY="on Claude Code $VERSION:${wrong#;}"
  else
    RESULT=pass; WHY="on Claude Code $VERSION, \$.fs.stat reports a real fifo and /dev/null as other and an ordinary file as file$stdin_said (so no mod reads either as a file), and a folder listing calls only the ordinary file a file"
  fi
}

# ---- a stored result for this version and this probe is the answer ----
if [ -f "$STORED" ]; then
  problem=""
  [ "$(value_of "$STORED" version)" = "$VERSION" ] || problem="it names no version $VERSION"
  case "$(value_of "$STORED" measured)" in ''|*[!0-9]*) problem="${problem:-it holds no time it was measured}" ;; esac
  for k in $KEYS; do grep -q "^$k=" "$STORED" || problem="${problem:-it lacks $k}"; done
  if [ -n "$problem" ]; then
    echo "The stored result for Claude Code $VERSION ($STORED) could not be read ($problem), so it is measured again."
  elif [ "$(value_of "$STORED" probe)" != "$PROBE_HASH" ]; then
    echo "The probe has changed since Claude Code $VERSION was measured, so it is measured again."
  else
    judge "$STORED"
    verdict "$RESULT" "$WHY; measured earlier, at $(et_time "$(value_of "$STORED" measured)"), on this Mac, and kept in $STORED"
  fi
fi

# ---- the probe ----
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fs-kind-probe.XXXXXX")" || verdict unmeasured "no scratch folder could be made for the probe"
FIX="$WORK/fixture"
mkdir -p "$FIX" "$WORK/home" "$WORK/run"
mkfifo "$FIX/probe.fifo" || verdict unmeasured "mkfifo could not make the fifo in $FIX"
ln -s /dev/stdin "$FIX/stdin.link"
printf 'plain\n' > "$FIX/plain.txt"
cp -R "$PROBE_SRC" "$WORK/probe"
OUT="$WORK/probe.out"
DEADLINE="${FS_KIND_DEADLINE:-$HANG_S}"

python3 "$DIR/sleep-real-engine-model.py" "$WORK/model.port" "$WORK/model.log" &
MODEL_PID=$!
hang_wait '[ -s "$WORK/model.port" ]'
[ -s "$WORK/model.port" ] || verdict unmeasured "the stand-in model did not start within ${HANG_S}s"
PORT="$(cat "$WORK/model.port")"

echo "Measuring Claude Code $VERSION now: one headless session with the probe mod, a stand-in model and a ${DEADLINE}s deadline."
STARTED="$(date +%s)"
SUMMARY="$(cd "$WORK/run" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_SESSION_ID \
  HOME="$WORK/home" CLAUDE_CODE_PLUGIN_DIRS= ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" ANTHROPIC_API_KEY=test-key-not-real \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 SHELL=/bin/bash \
  FS_KIND_PROBE_DIR="$FIX" FS_KIND_PROBE_OUT="$OUT" \
  python3 "$DIR/sleep-real-engine-session.py" "$WORK/session.jsonl" "$DEADLINE" 1 \
    "PROBE-RUN: echo fs-kinds # PROBE-TAG=fs-kinds" -- \
    "$CLAUDE_BIN" -p --model haiku --setting-sources project --allowedTools Bash \
    --input-format stream-json --output-format stream-json --verbose --plugin-dir "$WORK/probe" 2>&1)"
TOOK=$(( $(date +%s) - STARTED ))
stop_model
COST="$(printf '%s' "$SUMMARY" | sed -n 's/.*"cost_usd": *\([0-9.]*\).*/\1/p' | tail -1)"
echo "time: $TOOK seconds; cost: none in tokens, the model is the scripted stand-in (the session reported \$${COST:-0})"

case "$SUMMARY" in
  *'"timed_out": true'*) verdict unmeasured "the probe did not answer within its deadline of ${DEADLINE}s on Claude Code $VERSION; nothing was stored, so the next run measures again" ;;
esac
[ -s "$OUT" ] || verdict unmeasured "Claude Code $VERSION ran, but the probe answered nothing (did the probe mod load?); session: $(printf '%s' "$SUMMARY" | tr '\n' ' ' | cut -c1-300)"
missing=""
for k in $KEYS "done"; do grep -q "^$k=" "$OUT" || missing="$missing $k"; done
[ -z "$missing" ] || verdict unmeasured "the probe's record was cut short on Claude Code $VERSION (no$missing); nothing was stored"
echo "kinds: $(grep -v '^done=' "$OUT" | tr '\n' ' ')"

# A look that threw where no throw is an answer is not kept: it may pass, and the next run should
# look again.
judge "$OUT"
if [ -z "$THREW" ]; then
  mkdir -p "$STORE" && {
    echo "version=$VERSION"
    echo "probe=$PROBE_HASH"
    echo "measured=$STARTED"
    echo "seconds=$TOOK"
    for k in $KEYS; do echo "$k=$(value_of "$OUT" "$k")"; done
  } > "$STORED.tmp.$$" && mv "$STORED.tmp.$$" "$STORED" || echo "The result could not be stored in $STORE, so the next run measures again."
fi
verdict "$RESULT" "$WHY; measured now, on this Mac"
