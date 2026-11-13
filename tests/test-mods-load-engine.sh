#!/usr/bin/env bash
# Every mod in payload/mods loads on the REAL Claude Code installed on this Mac, all of them in one
# session as the Macs load them (claude-config#2862).
#
# Claude Code 2.1.323 refuses an engine.create hook that replaces a member of $ another plugin added
# ("engine.create replaced $.designRound, added by design-round-guard; to change what a method does,
# hook the method") and unloads that whole hooks module, so picker-manners enforced nothing on this
# Mac from the day 2.1.323 arrived. `claude plugin test` never saw it: its test engine runs a mod's
# stand ins without that refusal, so all 39 picker-manners tests passed on 2.1.323 with the mod
# unable to load. Only the real engine, with the real neighbouring mods, can say a mod loads.
#
# A run: a headless `claude -p` in a scratch HOME (none of this Mac's hooks, settings or installed
# mods), every mod copied from payload/mods and named in CLAUDE_CODE_PLUGIN_DIRS, its model the
# scripted stand in tests/sleep-real-engine-model.py on 127.0.0.1 with a key that is not a real one,
# so it spends no tokens and needs no network. The debug log is then read: a mod fails when the
# engine says its hooks module did not load, and every mod with a hooks module must be seen loaded
# (the control, so a run where nothing loaded can never read as nothing failing, L98), and the
# engine must name design-round-guard as the one whose $.designRound it kept. A second run gives
# the guard's manifest without its hooks module, since picker-manners adds $.designRound itself
# when the guard's member is absent (#2261) and must load then too, naming itself as its source.
#
# It says SUITE-PART-UNMEASURED, never a pass, when it cannot measure: CI (no Claude Code there),
# no claude or python3, or a session that does not finish within its deadline.
# MODS_LOAD_CLAUDE names the claude to run (default the one on PATH); MODS_LOAD_REAL_ENGINE=0 skips.
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
unmeasured() { echo "SUITE-PART-UNMEASURED whether every mod loads on the real Claude Code: $1"; finish; }

[ "${MODS_LOAD_REAL_ENGINE:-}" = 0 ] && unmeasured "switched off by MODS_LOAD_REAL_ENGINE=0"
case "${CI:-}" in ''|false|0) ;; *) unmeasured "running under CI (CI=$CI), where there is no Claude Code to run" ;; esac
CLAUDE_BIN="${MODS_LOAD_CLAUDE:-$(command -v claude || true)}"
[ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ] || unmeasured "there is no claude command to run the engine with"
command -v python3 >/dev/null 2>&1 || unmeasured "there is no python3 to run the stand in model with"
VERSION="$("$CLAUDE_BIN" --version 2>/dev/null)"
VERSION="${VERSION%% *}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-mods-load-engine.XXXXXX")"
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "FAIL: refusing to run: the throwaway directory came back as '$WORK'."; fail=1; finish ;;
esac
MODEL_PID=""
cleanup() { if [ -n "$MODEL_PID" ]; then { kill "$MODEL_PID"; wait "$MODEL_PID"; } 2>/dev/null; fi; rm -rf "$WORK"; }
trap cleanup EXIT

# A copy, so the types the engine lays into a loaded mod's folder never land in the checkout.
cp -R "$ROOT/payload/mods" "$WORK/mods" || unmeasured "payload/mods could not be copied to $WORK"

python3 "$DIR/sleep-real-engine-model.py" "$WORK/model.port" "$WORK/model.log" &
MODEL_PID=$!
hang_wait '[ -s "$WORK/model.port" ]'
[ -s "$WORK/model.port" ] || unmeasured "the stand in model did not start within ${HANG_S}s"
PORT="$(cat "$WORK/model.port")"

# The mods with a hooks module, by folder name, one per line. The engine's log names a mod by its
# manifest's name, so a folder named otherwise reads as never seen loading: a failure, never a pass.
hooked_mods() {
  local d
  for d in "$WORK/mods"/*/; do
    [ -f "$d.claude-plugin/plugin.json" ] && [ -f "${d}hooks/hooks.json" ] || continue
    [ "$(basename "$d")" = "${1:-}" ] && continue
    basename "$d"
  done
}

# run_session LABEL [LEFT_OUT]: one headless session with every mod but LEFT_OUT; its debug log is
# $WORK/LABEL.log. Returns 3 when it could not measure.
run_session() {
  local label="$1" left="${2:-}" dirs="" m summary
  for m in $(hooked_mods "$left"); do dirs="${dirs:+$dirs:}$WORK/mods/$m"; done
  [ -n "$left" ] && dirs="$dirs:$WORK/stub/$left"
  mkdir -p "$WORK/$label-home" "$WORK/$label-run"
  summary="$(cd "$WORK/$label-run" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_SESSION_ID \
    HOME="$WORK/$label-home" CLAUDE_CODE_PLUGIN_DIRS="$dirs" ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" ANTHROPIC_API_KEY=test-key-not-real \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 SHELL=/bin/bash \
    python3 "$DIR/sleep-real-engine-session.py" "$WORK/$label.jsonl" "$HANG_S" 1 "Say hello." -- \
      "$CLAUDE_BIN" -p --model haiku --setting-sources project \
      --input-format stream-json --output-format stream-json --verbose --debug-file "$WORK/$label.log" 2>&1)"
  case "$summary" in *'"timed_out": true'*) echo "SUITE-PART-UNMEASURED the $label session did not finish within ${HANG_S}s on Claude Code $VERSION"; return 3 ;; esac
  [ -s "$WORK/$label.log" ] || { echo "SUITE-PART-UNMEASURED the $label session wrote no debug log on Claude Code $VERSION: $(printf '%s' "$summary" | tr '\n' ' ' | cut -c1-300)"; return 3; }
  return 0
}

# judge LABEL [LEFT_OUT]: every mod the session was given loaded, and none was refused.
judge() {
  local label="$1" left="${2:-}" log="$WORK/$1.log" m refused notseen=""
  refused="$(grep -E 'hooks module did not load|hooks module [^ ]+ failed in engine\.create' "$log" | sed 's/^[^]]*\] //' | sort -u)"
  if [ -z "$refused" ]; then check "$label: no mod's hooks module was refused on Claude Code $VERSION" ok
  else check "$label: no mod's hooks module was refused on Claude Code $VERSION" "the engine said: $(printf '%s' "$refused" | tr '\n' ' ')"; fi
  for m in $(hooked_mods "$left"); do
    grep -qE "hooks module $m@[^ ]+ loaded" "$log" || notseen="$notseen $m"
  done
  if [ -z "$notseen" ]; then check "$label: every mod given was seen loading (the control)" ok
  else
    check "$label: every mod given was seen loading (the control)" "never seen loading:$notseen"
    for m in $notseen; do grep -E "[^a-z-]$m([^a-z-]|$)" "$log" | grep -vE 'Read hooks.json|Loaded inline plugin|Checking plugin|is one plugin' | sed 's/^[^]]*\] /  log: /' | tail -4; done
  fi
}

echo "Measuring Claude Code $VERSION: headless sessions with every mod, a stand in model and a ${HANG_S}s deadline each."
# kept: whose $.designRound the engine kept, which it names on its engine.create line.
kept() {
  if grep -qF "\$.designRound ($2: answered)" "$WORK/$1.log"; then check "$1: \$.designRound is the one $2 adds ($3)" ok
  else check "$1: \$.designRound is the one $2 adds ($3)" "the engine named: $(grep -o '\$\.designRound ([^)]*)' "$WORK/$1.log" | sort -u | tr '\n' ' ')"; fi
}
if run_session all; then judge all; kept all design-round-guard "picker-manners leaves the guard's member alone"; fi

# The guard's plugin with no hooks module, as when its module fails to load: picker-manners declares
# it a dependency, and Claude Code 2.1.323 refuses a mod whose dependency is not there at all
# ("dependency-unsatisfied", measured 2026-11-12), so this is how $.designRound comes to be absent
# while picker-manners loads. Its own engine.create must then add the member its
# on('designRound.answered') hook needs (#2261).
mkdir -p "$WORK/stub/design-round-guard/.claude-plugin"
cp "$WORK/mods/design-round-guard/.claude-plugin/plugin.json" "$WORK/stub/design-round-guard/.claude-plugin/plugin.json"
if run_session no-guard design-round-guard; then judge no-guard design-round-guard; kept no-guard picker-manners "added by picker-manners when the guard's module is absent"; fi
finish
