#!/usr/bin/env bash
# A mod's session id and the one a Bash call carries are the same id (claude-config#1575), measured
# against the REAL Claude Code engine (L34, L82).
#
# The one polling policy, hooks/lib/gh-poll.sh (#1482), caps GitHub looks per session in a state
# folder keyed on CLAUDE_CODE_SESSION_ID. A Bash call (merge-when-ready.sh, gh-poll.sh sourced by a
# loop) is keyed by the id Claude Code puts in that call's environment; a mod (status-bar,
# scope-modes) is keyed by $.session.id(), which mod-kit's hooks/ghpoll.ts hands the library as
# CLAUDE_CODE_SESSION_ID. Every other test of that path fakes the runner, so nothing had shown the
# two ids are one: were they not, a mod's looks and the session's merge helpers would spend two
# budgets and the cap would not be shared.
#
# So Claude Code itself runs headless sessions here with one probe mod (tests/session-id-probe),
# which on every tagged Bash call records $.session.id() and takes a look through the real
# ghpoll.ts and gh-poll.sh, while the Bash call records the CLAUDE_CODE_SESSION_ID it carries and
# takes a look through gh-poll.sh too. Each step is judged by what it leaves on disk:
#
#   main       the session's own call
#   agent      a subagent's call (the probe sees its agentId)
#   compacted  a call after /compact
#   cleared    a call after /clear, which starts a new id (a control: it must differ from main)
#   resumed    a call in `claude -p --resume`, which keeps the id
#   forked     a call in `--resume --fork-session`, which starts a new id (a control)
#   inherited  a session started with a stranger's CLAUDE_CODE_SESSION_ID already in its
#              environment, as a `claude -p` run from inside another session's Bash call is
#
# and for each, the two ids agree, and the gh-poll state holds exactly one folder per id with both
# sides' looks in it. A mod's OWN environment is said too, never judged: Claude Code does not put
# the session's id there (absent, or the stranger's when inherited), which is why ghpoll.ts passes
# $.session.id() explicitly rather than letting the library read whatever the mod inherited.
#
# The model is the scripted stand-in tests/sleep-real-engine-model.py (its PROBE steps), reached
# through ANTHROPIC_BASE_URL with a key that is not a real one, so it costs nothing. HOME is a
# scratch folder; nothing reaches GitHub (the looks are counted locally, never made). Wherever there
# is no Claude Code or no macOS (CI's Linux runner) it says UNMEASURED and why;
# SESSION_ID_REAL_ENGINE=0 skips it.
#
# What a headless run cannot show, said rather than passed: an interactive session's /resume picker
# (the --resume flag is measured instead), and a teammate or a fork subagent (a general purpose
# subagent is measured).
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
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); echo "ok: $1"; else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
unmeasured() { echo "SUITE-PART-UNMEASURED $1"; printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"; [ "$fail" -eq 0 ]; exit $?; }

if [ "${SESSION_ID_REAL_ENGINE:-}" = 0 ]; then
  unmeasured "the session id agreement against the real Claude Code engine was not run: SESSION_ID_REAL_ENGINE=0 skips it"
fi
[ "$(uname)" = Darwin ] || unmeasured "the session id agreement runs Claude Code itself, which is measured on macOS only"
CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || unmeasured "there is no claude command on PATH to run the engine with"

REAL_HOME="$HOME"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-session-id-agreement.XXXXXX")"
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
  echo "SUITE-PART-UNMEASURED an interactive session's /resume picker, a teammate and a fork subagent; a headless run measures --resume and a general purpose subagent"
  printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit $?
}

# ---- the scratch Mac: the probe mod, with the real ghpoll.ts beside it, and the real gh-poll.sh ----
export HOME="$WORK/home"
PROBE="$HOME/.claude/mods/session-id-probe"
mkdir -p "$HOME/.claude/mods" "$HOME/.claude/hooks/lib" "$WORK/repo"
if [ ! -d "$DIR/session-id-probe" ]; then
  check "the probe mod is in tests/session-id-probe" "it is missing"
  finish
fi
cp -R "$DIR/session-id-probe" "$PROBE"
mkdir -p "$PROBE/hooks/mod-kit"
cp "$ROOT/payload/mods/mod-kit/hooks/ghpoll.ts" "$PROBE/hooks/mod-kit/ghpoll.ts"
cp "$ROOT/payload/hooks/lib/gh-poll.sh" "$HOME/.claude/hooks/lib/gh-poll.sh"
git -C "$WORK/repo" init -q
POLL_STATE="$WORK/gh-poll"
BASH_LOG="$WORK/bash.log"
MOD_LOG="$WORK/mod.log"
: > "$BASH_LOG"; : > "$MOD_LOG"

python3 "$DIR/sleep-real-engine-model.py" "$WORK/model.port" "$WORK/model.log" &
MODEL_PID=$!
for _ in $(seq 1 50); do [ -s "$WORK/model.port" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
[ -s "$WORK/model.port" ] || { check "the stand-in model starts" "no port after 5 seconds"; finish; }
PORT="$(cat "$WORK/model.port")"

# The Bash call a step asks for: the id it carries and a look taken through gh-poll.sh, at one fixed
# moment (1,000,000 s) so no look ages out of the minute between steps, and under a cap no step can
# reach, so every look is taken and counted.
step() { echo "PROBE-RUN: printf '%s\t%s\t%s\n' $1 \"\$CLAUDE_CODE_SESSION_ID\" \"\$(bash ~/.claude/hooks/lib/gh-poll.sh take 1000000)\" >> $BASH_LOG # PROBE-TAG=$1"; }

# One headless session: OUT INHERITED [claude args...] -- MESSAGE...  INHERITED is the
# CLAUDE_CODE_SESSION_ID its environment starts with, or empty for none.
session() {
  local out="$1" inherited="$2"; shift 2
  local extra=() pre=(-u CLAUDE_CODE_SESSION_ID)
  while [ $# -gt 0 ] && [ "$1" != -- ]; do extra+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  [ -n "$inherited" ] && pre+=("CLAUDE_CODE_SESSION_ID=$inherited")
  local summary
  summary="$(cd "$WORK/repo" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT -u CLAUDE_CODE_OAUTH_TOKEN "${pre[@]}" \
    CLAUDE_CODE_PLUGIN_DIRS= ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" ANTHROPIC_API_KEY=test-key-not-real \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 SHELL=/bin/bash \
    GH_POLL_STATE_DIR="$POLL_STATE" GH_POLL_PER_MINUTE=1000 SESSION_ID_PROBE_OUT="$MOD_LOG" \
    python3 "$DIR/sleep-real-engine-session.py" "$out" 180 "$#" "$@" -- \
      "$CLAUDE_BIN" -p --model haiku --setting-sources project --allowedTools Bash Agent Task \
      --input-format stream-json --output-format stream-json --verbose --plugin-dir "$PROBE" ${extra[@]+"${extra[@]}"})"
  echo "   session: $summary" | cut -c1-300
}

SID="$(uuidgen | tr 'A-Z' 'a-z')"
STRANGER="$(uuidgen | tr 'A-Z' 'a-z')"
echo "-- one session ($SID): its own call, a subagent's, after /compact, after /clear"
session "$WORK/s1.jsonl" "" --session-id "$SID" -- "$(step main)" "PROBE-AGENT: $(step agent)" "/compact" "$(step compacted)" "/clear" "$(step cleared)"
echo "-- resumed, then resumed as a fork"
session "$WORK/s2.jsonl" "" --resume "$SID" -- "$(step resumed)"
session "$WORK/s3.jsonl" "" --resume "$SID" --fork-session -- "$(step forked)"
echo "-- a session started with another session's id in its environment ($STRANGER)"
session "$WORK/s4.jsonl" "$STRANGER" --session-id "$(uuidgen | tr 'A-Z' 'a-z')" -- "$(step inherited)"
stop_model

# ---- what the steps left ----
# The reader writes to a file, never through a command substitution, whose parse of a heredoc
# holding a quote bash 3.2 gets wrong.
python3 - "$BASH_LOG" "$MOD_LOG" "$POLL_STATE" "$SID" "$STRANGER" > "$WORK/verdict" <<'PY'
import os, re, sys
bash_log, mod_log, state, sid, stranger = sys.argv[1:]
TAGS = ['main', 'agent', 'compacted', 'cleared', 'resumed', 'forked', 'inherited']
UUID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
def rows(path, width):
    out = {}
    for line in open(path):
        f = line.rstrip('\n').split('\t')
        if len(f) >= 2:
            out.setdefault(f[0], []).append((f + [''] * width)[:width])
    return out
b, m = rows(bash_log, 3), rows(mod_log, 5)
said = []
def check(name, problem):
    said.append(('ok' if not problem else problem, name))
ids = {}
for t in TAGS:
    bb, mm = b.get(t, []), m.get(t, [])
    if len(bb) != 1 or len(mm) != 1:
        check(f'{t}: one Bash call and one mod record', f'{len(bb)} Bash rows and {len(mm)} mod rows')
        continue
    _, bid, btake = bb[0]
    _, mid, agent, own, look = mm[0]
    check(f'{t}: the Bash call carries a session id', '' if UUID.match(bid) else f'it carried "{bid}"')
    check(f"{t}: the mod's $.session.id() is the id the Bash call carries", '' if mid == bid else f'the mod read {mid}, the Bash call carried {bid}')
    check(f'{t}: both looks were taken through gh-poll.sh', '' if (btake, look) == ('ok', 'ok') else f'Bash: "{btake}", mod: "{look}"')
    print(f"note: {t}: a mod's own environment carries CLAUDE_CODE_SESSION_ID={own or '(none)'}", file=sys.stderr)
    ids[t] = (bid, agent)
if len(ids) == len(TAGS):
    main = ids['main'][0]
    check('main is the id the session was started with', '' if main == sid else f'{main}, not {sid}')
    check('the subagent call is the subagent\'s (the probe saw an agentId)', '' if ids['agent'][1] else 'no agentId')
    check('the subagent carries its session\'s id', '' if ids['agent'][0] == main else ids['agent'][0])
    check('/compact keeps the id', '' if ids['compacted'][0] == main else ids['compacted'][0])
    check('--resume keeps the id', '' if ids['resumed'][0] == main else ids['resumed'][0])
    check('/clear starts a new id (the control)', '' if ids['cleared'][0] != main else 'it is still the first id')
    check('--fork-session starts a new id (the control)', '' if ids['forked'][0] not in (main, ids['cleared'][0]) else 'it is an earlier id')
    other = {ids[t][0] for t in TAGS if t != 'inherited'}
    check('a session started with a stranger\'s id in its environment carries its own', '' if ids['inherited'][0] not in other | {stranger} else ids['inherited'][0])
    # One budget per id: a folder for each id, none for no-session or the stranger, holding both
    # sides' looks of every step with that id.
    want = {}
    for t in TAGS:
        want[ids[t][0]] = want.get(ids[t][0], 0) + 2
    have = {}
    for d in sorted(os.listdir(state)) if os.path.isdir(state) else []:
        p = os.path.join(state, d, 'polls')
        have[d] = sum(1 for x in open(p) if x.strip()) if os.path.isfile(p) else 0
    check('gh-poll keeps one folder per session id, and none for no-session or the stranger', '' if set(have) == set(want) else f'folders {sorted(have)}, ids {sorted(want)}')
    check("each id's folder holds the mod's and the Bash call's looks of every step with that id", '' if have == want else f'looks {have}, expected {want}')
for verdict, name in said:
    print(f'{verdict}\t{name}')
PY
VERDICT="$(cat "$WORK/verdict")"
while IFS=$'\t' read -r verdict name; do
  [ -n "$name" ] && check "$name" "$verdict"
done <<< "$VERDICT"
[ -n "$VERDICT" ] || check "the steps' logs could be read" "the reader printed nothing"
finish
