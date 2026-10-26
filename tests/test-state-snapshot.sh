#!/usr/bin/env bash
# Whether every $.state.get in one hook run reads one snapshot (claude-config#1720), measured against
# the REAL Claude Code engine (L34, L82).
#
# The mods change a shared session fact by version and retry (job-watcher's changeFact since #1695,
# every fact #1703 moved into $.state, docs/mods-design.md standing rule 6): read the value and its
# version, write at that version, and on a miss read again and try again. That retry only works if
# the second read sees the write that beat the first. The engine's own type file says "Every `get` of
# one dispatch reads one moment, whatever is written meanwhile": if that held, a write refused in a
# hook run could never land on a retry in the same run, and would need carrying to the next run.
#
# So Claude Code itself runs one headless session here with a probe mod (tests/state-snapshot-probe)
# that, on each tagged Bash call, records what $.state answered inside that one tool.call hook run:
#
#   own    a read after this same run's own write
#   race   two writers at once, each the versioned retry the mods use: the loser's second read
#   cross  a read after a write made by ANOTHER dispatch (a timer's) while this run waited, and a
#          write at the version read before that other write
#   timer  the race again inside a timer's dispatch (job-watcher's minute look runs on a timer)
#   after  the next hook run's view of every value
#
# Measured on 2026-10-25 with Claude Code 2.1.310: no read in one hook run is a snapshot. A read sees
# the run's own write, the losing writer's second read sees the winner's write and its retry lands
# (in a hook run and in a timer's dispatch alike), and a read after another dispatch's write sees
# that write, so the versioned retry the mods use lands in place and nothing needs carrying to the
# next run. Each check below fails if a later engine makes reads one snapshot after all, which is
# the day the retry has to change.
#
# The model costs nothing (a key that is not a real one, ANTHROPIC_BASE_URL at the stand-in
# tests/sleep-real-engine-model.py); HOME is a scratch folder. Wherever there is no Claude Code or no
# macOS (CI's Linux runner) it says UNMEASURED and why; STATE_SNAPSHOT_REAL_ENGINE=0 skips it.
#
# What a headless run cannot show, said rather than passed: a ui.render hook (a headless session
# draws nothing), where the engine refuses a write anyway.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

# Every wait on a condition gives up at the one ceiling only a hang reaches (lib/hang-wait.sh,
# claude-config#1679).
. "$ROOT/payload/hooks/lib/hang-wait.sh" || {
  echo "FAIL: $(basename "$0"): lib/hang-wait.sh is missing, so this suite's waits have no ceiling."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); echo "ok: $1"; else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
unmeasured() { echo "SUITE-PART-UNMEASURED $1"; printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"; [ "$fail" -eq 0 ]; exit $?; }

if [ "${STATE_SNAPSHOT_REAL_ENGINE:-}" = 0 ]; then
  unmeasured "whether one hook run's state reads are one snapshot was not measured: STATE_SNAPSHOT_REAL_ENGINE=0 skips it"
fi
[ "$(uname)" = Darwin ] || unmeasured "whether one hook run's state reads are one snapshot is measured by running Claude Code itself, on macOS only"
CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || unmeasured "there is no claude command on PATH to run the engine with"

REAL_HOME="$HOME"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-state-snapshot.XXXXXX")"
case "${WORK%/}" in
  ''|/|"${REAL_HOME%/}")
    echo "FAIL: $(basename "$0"): refusing to run: the throwaway directory came back as '$WORK'."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1 ;;
esac
STARTED="$(date +%s)"
MODEL_PID=""
stop_model() { if [ -n "$MODEL_PID" ]; then { kill "$MODEL_PID"; wait "$MODEL_PID"; } 2>/dev/null; MODEL_PID=""; fi; }
cleanup() { stop_model; if [ "${KEEP:-}" = 1 ]; then echo "kept: $WORK"; else rm -rf "$WORK"; fi; }
trap cleanup EXIT
finish() {
  stop_model
  echo "time: $(( $(date +%s) - STARTED )) seconds; cost: none, the model is the scripted stand-in"
  echo "SUITE-PART-UNMEASURED a ui.render hook's reads, which a headless session never draws"
  printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit $?
}

# ---- the scratch Mac: the probe mod and a repository to run in ----
export HOME="$WORK/home"
PROBE="$WORK/state-snapshot-probe"
mkdir -p "$HOME" "$WORK/repo"
if [ ! -d "$DIR/state-snapshot-probe" ]; then
  check "the probe mod is in tests/state-snapshot-probe" "it is missing"
  finish
fi
cp -R "$DIR/state-snapshot-probe" "$PROBE"
git -C "$WORK/repo" init -q
PROBE_LOG="$WORK/probe.log"
: > "$PROBE_LOG"

python3 "$DIR/sleep-real-engine-model.py" "$WORK/model.port" "$WORK/model.log" &
MODEL_PID=$!
hang_wait '[ -s "$WORK/model.port" ]'
[ -s "$WORK/model.port" ] || { check "the stand-in model starts" "no port within the hang ceiling, ${HANG_S}s"; finish; }
PORT="$(cat "$WORK/model.port")"

step() { echo "PROBE-RUN: echo $1 # PROBE-TAG=$1"; }
TAGS=(own race cross timer after)
echo "-- one session, one tagged Bash call per step: ${TAGS[*]}"
summary="$(cd "$WORK/repo" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_SESSION_ID \
  CLAUDE_CODE_PLUGIN_DIRS= ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" ANTHROPIC_API_KEY=test-key-not-real \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 SHELL=/bin/bash STATE_SNAPSHOT_PROBE_OUT="$PROBE_LOG" \
  python3 "$DIR/sleep-real-engine-session.py" "$WORK/s1.jsonl" 180 "${#TAGS[@]}" \
    "$(step own)" "$(step race)" "$(step cross)" "$(step timer)" "$(step after)" -- \
    "$CLAUDE_BIN" -p --model haiku --setting-sources project --allowedTools Bash \
    --input-format stream-json --output-format stream-json --verbose --plugin-dir "$PROBE")"
echo "   session: $summary" | cut -c1-300
echo "   engine: $("$CLAUDE_BIN" --version 2>/dev/null)"
stop_model

# ---- what the steps left ----
# The reader writes to a file, never through a command substitution, whose parse of a heredoc
# holding a quote bash 3.2 gets wrong.
python3 - "$PROBE_LOG" > "$WORK/verdict" <<'PY'
import json, sys
rows = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if line:
        d = json.loads(line)
        rows.setdefault(d.get('tag'), []).append(d)
said = []
def check(name, problem):
    said.append(('ok' if not problem else problem, name))
def one(tag):
    got = rows.get(tag, [])
    if len(got) != 1:
        check(f'{tag}: the probe recorded the step once', f'{len(got)} records')
        return None
    if 'error' in got[0]:
        check(f'{tag}: the probe ran without an error', got[0]['error'])
        return None
    return got[0]
def race(tag, where):
    r = one(tag)
    if not r:
        return
    w = r['writers']
    if not isinstance(w, list):
        check(f'{tag}: both writers finished', str(w))
        return
    lost = [x for x in w if len(x['tries']) > 1]
    check(f'{where}: two writers at once, one misses its first versioned write (the race is real)',
          '' if len(lost) == 1 and not lost[0]['tries'][0]['isSet'] else f'tries {[len(x["tries"]) for x in w]}')
    if lost:
        t = lost[0]['tries']
        check(f"{where}: the loser's second read sees the winner's write (no snapshot)",
              '' if t[1]['read'] > t[0]['read'] else f'it read version {t[1]["read"]} again')
        check(f"{where}: the loser's retry lands in the same run, so nothing needs carrying to the next",
              '' if lost[0]['landed'] and len(t) == 2 else f'landed {lost[0]["landed"]} after {len(t)} tries')
    check(f'{where}: neither write is lost', '' if r['end'].get('value') == 2 else f'the value ended at {r["end"].get("value")}')

r = one('own')
if r:
    check("own: a read after this hook run's own write sees it",
          '' if r['again'].get('value') == 1 and r['again']['version'] == r['wrote']['version'] else f'wrote {r["wrote"]}, then read {r["again"]}')
race('race', 'race in one tool.call hook run')
r = one('cross')
if r:
    other = r['other']
    check('cross: the other dispatch (a timer) wrote while the hook run waited (the control)',
          '' if isinstance(other, dict) and other.get('isSet') else f'it answered {other}')
    check("cross: the hook run's read after it sees the other dispatch's write (no snapshot)",
          '' if r['again'].get('value') == 100 and r['again']['version'] > r['before']['version'] else f'it read {r["again"]}')
    check('cross: a write at the version read before that write is refused, never landed over it',
          '' if r['wrote']['isSet'] is False else 'it landed')
race('timer', "race in a timer's dispatch")
r = one('after')
if r:
    check("after: the next hook run sees every value as the steps left it",
          '' if (r['own'].get('value'), r['race'].get('value'), r['cross'].get('value'), r['timerRace'].get('value')) == (1, 2, 100, 2) else json.dumps(r))
for verdict, name in said:
    print(f'{verdict}\t{name}')
PY
VERDICT="$(cat "$WORK/verdict")"
while IFS=$'\t' read -r verdict name; do
  [ -n "$name" ] && check "$name" "$verdict"
done <<< "$VERDICT"
[ -n "$VERDICT" ] || check "the probe's record could be read" "the reader printed nothing"
finish
