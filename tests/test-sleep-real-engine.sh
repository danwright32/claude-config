#!/usr/bin/env bash
# Sleep mode phase 10 (claude-config#838): one night of sleep mode run by the REAL Claude Code
# engine (L52, L82). Every other sleep suite holds a part to its contract with the engine stubbed;
# here Claude Code itself loads the five mods sleep mode needs and runs headless sessions, and each
# step is judged by the state it leaves on disk.
#
#   1. /sleep starts it: the record placed, the night's report begun, the Mac held awake.
#   2. An overnight ban refuses something: from a session that is not a worker, a force push to a
#      scratch branch (the #834 ban list) and a push to main (#843, a default branch), each refused
#      before it runs, with origin left as it was.
#   3. A worker's own permission prompt is approved overnight, but never over a refusal beneath
#      it: a settings PermissionRequest hook that denies one command still wins (#834). A session
#      that is not a worker gets neither, the control. That worker then makes no progress, so the
#      driver's circuit breaker lets it go.
#   4. A worker is kept going by the driver: its Stop is blocked with the overnight rules, and it
#      claims the queued issue with sleep-queue.sh, works it in the claim's worktree, ends the claim
#      and stops when nothing is left (#842, #844).
#   5. Notes reach the report: the claim, its end, the driver's heartbeats and a proposed issue are
#      in the night's notes and in the report rendered from them (#835, #905).
#   6. /wake ends it: the record moved aside, the Mac let go, the report finished and held rather
#      than opened (away before sleep), and the morning instruction submitted as a turn of its own,
#      offering the proposed issue (#837).
#
# The model is a scripted stand-in (tests/sleep-real-engine-model.py, reached through
# ANTHROPIC_BASE_URL with a key that is not a real one), the way the engine spike answered its error
# runs (#839). Everything the plan depends on the engine for is real: hook order, a Stop block
# keeping a session going, a tool.call refusal coming before the call runs, a PermissionRequest
# hook's decision, `$.prompt.submit` starting a turn. What the stand-in replaces is the model's own
# judgement, so whether a real model follows the overnight rules for a night is not measured here:
# the first real night measures that (Dan, 2026-10-07: build now, measure on night one). A run of
# this suite's first version against the real model (haiku, 2026-10-07) is recorded in the PR.
#
# Never the real ~/.claude, ~/Downloads, GitHub or a real repository (L2): HOME is a scratch folder
# holding copies of the mods and the sleep shell tools; the repository is a scratch clone whose
# GitHub looking origin is rewritten to a local bare repository; `gh` first on PATH records every
# call and fails; the queue reads its one issue from a stand-in source (SLEEP_QUEUE_SOURCE, the
# seam test-sleep-queue.sh uses); `pmset` answers AC power; and the notifier, sound, open and
# osascript record and do nothing. The end of the run checks that the real ~/.claude/state/sleep
# and ~/Downloads gained nothing (L322).
#
# What a headless run cannot show, said rather than passed:
#   - /sleep enrols interactive sessions only, and a `claude -p` run is never one (by design,
#     #840). So steps 3 and 4 enrol their sessions by adding their ids to the record /sleep wrote;
#     a real interactive session's enrolment is UNMEASURED here.
#   - The before bed questions need a person at a prompt, so none is asked here.
#   - A full hour of work, a real usage limit and a real model's night: the first real night.
#
# It costs nothing (the key it is given is not a real one, so nothing it sends could be billed) and
# takes under a minute, so it runs in every local run; SLEEP_REAL_ENGINE=0 skips it. Wherever there
# is no Claude Code or no macOS (CI's Linux runner), it says UNMEASURED and why.
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
unmeasured() { echo "UNMEASURED: $1"; printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"; [ "$fail" -eq 0 ]; exit $?; }

# The session driver itself, which needs only python3 and so runs everywhere, CI included: a session
# that exits without reading its input must still end in a summary naming that, never a traceback
# with no summary, which would leave every check after it judging an empty answer (lessons review
# of d547970). A message bigger than a pipe holds makes the write fail every time, not by a race.
DRV_TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-sleep-real-engine-driver.XXXXXX")"
DRV_SAID="$(python3 "$DIR/sleep-real-engine-session.py" "$DRV_TMP/out.jsonl" 30 1 "$(python3 -c 'print("x" * 200000)')" -- /bin/sh -c 'exit 3' 2>"$DRV_TMP/err")"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d["exit"] == 3 and d["results"] == 0 and "input" in d.get("input_error", "") else 1)' "$DRV_SAID" 2>/dev/null \
  && check "the session driver says a session that stopped reading its input, with a summary" ok \
  || check "the session driver says a session that stopped reading its input, with a summary" "said: ${DRV_SAID:-nothing}; stderr: $(head -c 300 "$DRV_TMP/err")"
rm -rf "$DRV_TMP"

if [ "${SLEEP_REAL_ENGINE:-}" = 0 ]; then
  unmeasured "sleep mode against the real Claude Code engine was not run: SLEEP_REAL_ENGINE=0 skips it"
fi
[ "$(uname)" = Darwin ] || unmeasured "sleep mode reads macOS's sysctl and caffeinate, which this machine lacks"
CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || unmeasured "there is no claude command on PATH to run the engine with"

REAL_HOME="$HOME"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-sleep-real-engine.XXXXXX")"
case "${WORK%/}" in
  ''|/|"${REAL_HOME%/}")
    echo "FAIL: $(basename "$0"): refusing to run: the throwaway directory came back as '$WORK'."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1 ;;
esac
STARTED="$(date +%s)"
MODEL_PID=""
# The stand-in model and the caffeinate hold /sleep starts are stopped here whatever happens: the
# hold by its own number and only while that number is still caffeinate, as wake does (#844).
cleanup() {
  local f="$WORK/home/.claude/state/sleep/caffeinate.pid" pid
  stop_model
  if [ -f "$f" ]; then
    pid="$(cut -d' ' -f1 "$f")"
    case "$(ps -o comm= -p "$pid" 2>/dev/null)" in *caffeinate) kill "$pid" 2>/dev/null ;; esac
  fi
  if [ "${KEEP:-}" = 1 ]; then echo "kept: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

unmeasured_parts=()
# The stand-in model is stopped and reaped quietly, so the SUITE-RESULT line stays the last thing said.
stop_model() { if [ -n "$MODEL_PID" ]; then { kill "$MODEL_PID"; wait "$MODEL_PID"; } 2>/dev/null; MODEL_PID=""; fi; }
finish() {
  stop_model
  echo "time: $(( $(date +%s) - STARTED )) seconds; cost: none, the model is the scripted stand-in"
  local u
  for u in ${unmeasured_parts[@]+"${unmeasured_parts[@]}"}; do echo "UNMEASURED: $u"; done
  echo "UNMEASURED: a real interactive session's enrolment by /sleep (a headless run is never one), the before bed questions, a real model following the overnight rules, a full hour of work and a real usage limit; the first real night measures them"
  printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit $?
}

# ---- the scratch Mac ----
export HOME="$WORK/home"
STATE="$HOME/.claude/state/sleep"
mkdir -p "$HOME/.claude/mods" "$HOME/.claude/hooks/lib" "$HOME/.claude/state/sessions" "$HOME/Downloads" "$WORK/bin"
PLUGIN_ARGS=()
for m in mod-kit status-bar session-registry is-it-live scope-modes; do
  cp -R "$ROOT/payload/mods/$m" "$HOME/.claude/mods/$m"
  PLUGIN_ARGS+=(--plugin-dir "$HOME/.claude/mods/$m")
done
cp "$ROOT/payload/mods/sleep-repos.json" "$HOME/.claude/mods/sleep-repos.json"
for f in sleep.sh sleep-report.py sleep-queue.sh sleep-queue.py; do cp "$ROOT/payload/hooks/lib/$f" "$HOME/.claude/hooks/lib/$f"; done

# Stand-ins for what lies outside the engine.
cat > "$WORK/bin/gh" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/gh-called"
echo "gh is not available in this test: nothing reaches GitHub" >&2
exit 1
EOF
cat > "$WORK/bin/pmset" <<'EOF'
#!/bin/sh
echo "Now drawing from 'AC Power'"
EOF
for s in terminal-notifier afplay open osascript; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/screen-called"\n' "$s" "$WORK" > "$WORK/bin/$s"
done
# A settings PermissionRequest hook that denies one command and records every prompt it sees.
cat > "$WORK/bin/deny-hook" <<EOF
#!/bin/sh
input="\$(cat)"
printf '%s\n' "\$input" >> "$WORK/permission-hook.log"
case "\$input" in
  *denied-by-settings*) printf '%s' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"denied by the settings hook"}}}' ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/"*

# The repository the night works in, as test-sleep-queue.sh builds it: origin reads as GitHub, so
# its slug is danwright32/sleepdemo, and is rewritten to a local bare repository for every fetch
# and push.
git -c init.defaultBranch=main init -q --bare "$WORK/sleepdemo.git"
git -c init.defaultBranch=main init -q "$WORK/seed"
git -C "$WORK/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m first
git -C "$WORK/seed" push -q "$WORK/sleepdemo.git" HEAD:main
git clone -q "$WORK/sleepdemo.git" "$WORK/repo"
git -C "$WORK/repo" config remote.origin.url https://github.com/danwright32/sleepdemo.git
git -C "$WORK/repo" config url."$WORK/sleepdemo.git".insteadOf https://github.com/danwright32/sleepdemo.git
git -C "$WORK/repo" config user.email sleep@test.invalid
git -C "$WORK/repo" config user.name "Sleep test"
SEED="$(git -C "$WORK/sleepdemo.git" rev-parse main)"
REPO="$WORK/repo"

# The queue's one issue, from the stand-in source.
FX="$WORK/fx"; mkdir -p "$FX"
printf 'danwright32\n' > "$FX/accounts"
printf '[{"number":1,"title":"Add hello.txt","labels":[{"name":"priority-p2"}],"author":{"login":"danwright32"}}]' > "$FX/issues.json"
printf '{"number":1,"title":"Add hello.txt","labels":[{"name":"priority-p2"}],"author":{"login":"danwright32"},"state":"OPEN"}' > "$FX/issue-1.json"
printf '[]' > "$FX/prs.json"
printf 'main\n' > "$FX/branches"
cat > "$WORK/bin/queue-source" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/source.log"
case "\$1" in
  accounts) cat "$FX/accounts" ;;
  issues) cat "$FX/issues.json" ;;
  issue) cat "$FX/issue-\$3.json" ;;
  prs) cat "$FX/prs.json" ;;
  branches) cat "$FX/branches" ;;
  *) echo "the stand-in source does not know \$1" >&2; exit 2 ;;
esac
EOF
chmod +x "$WORK/bin/queue-source"

# The scripted model, on a free local port, logging every request.
python3 "$DIR/sleep-real-engine-model.py" "$WORK/model.port" "$WORK/model.log" &
MODEL_PID=$!
for _ in $(seq 1 50); do [ -s "$WORK/model.port" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
[ -s "$WORK/model.port" ] || { check "the stand-in model starts" "no port after 5 seconds"; finish; }
PORT="$(cat "$WORK/model.port")"

# What the real home holds, so the end can say nothing there changed.
touch "$WORK/started"
real_changed() {
  { find "$REAL_HOME/.claude/state/sleep" -mindepth 1 -newer "$WORK/started" 2>/dev/null
    find "$REAL_HOME/Downloads" -maxdepth 1 -name 'Sleep report*' -newer "$WORK/started" 2>/dev/null; } | sort
}

# One headless session: OUT DEADLINE RESULTS SESSION_ID [claude args...] -- MESSAGE...
session() {
  local out="$1" deadline="$2" want="$3" sid="$4"; shift 4
  local extra=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do extra+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  local summary
  summary="$(cd "$REPO" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT -u CLAUDE_CODE_OAUTH_TOKEN \
    CLAUDE_CODE_PLUGIN_DIRS= ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" ANTHROPIC_API_KEY=test-key-not-real \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 SHELL=/bin/bash PATH="$WORK/bin:$PATH" \
    SLEEP_QUEUE_SOURCE="$WORK/bin/queue-source" \
    python3 "$DIR/sleep-real-engine-session.py" "$out" "$deadline" "$want" "$@" -- \
      "$CLAUDE_BIN" -p --session-id "$sid" --model haiku --setting-sources project --permission-mode manual \
      --input-format stream-json --output-format stream-json --verbose "${PLUGIN_ARGS[@]}" ${extra[@]+"${extra[@]}"})"
  printf '%s\n' "$summary" > "$out.summary"
  echo "   session: $summary" | cut -c1-400
}
result_text() { python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["texts"]; print(t[int(sys.argv[2])] if len(t) > int(sys.argv[2]) else "")' "$1.summary" "$2"; }
jget() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d = d.get(k) if isinstance(d, dict) else None
print(json.dumps(d) if not isinstance(d, str) else d)' "$1" "$2" 2>/dev/null; }
uuid() { uuidgen | tr 'A-Z' 'a-z'; }
# The first N characters of a value, for a failure's evidence, without a pipe that can stop early (L183).
clip() { local v="$1"; printf '%s' "${v:0:${2:-300}}"; }
# Every Bash call a session's stream shows: the command, a tab, what came back.
calls() { python3 - "$1" <<'PY'
import json, sys
uses, out = {}, []
for line in open(sys.argv[1]):
    try: m = json.loads(line)
    except ValueError: continue
    msg = m.get('message') if isinstance(m, dict) else None
    content = msg.get('content') if isinstance(msg, dict) else None
    for c in content if isinstance(content, list) else []:
        if not isinstance(c, dict): continue
        if c.get('type') == 'tool_use': uses[c.get('id')] = (c.get('input') or {}).get('command', '')
        if c.get('type') == 'tool_result' and c.get('tool_use_id') in uses:
            body = c.get('content'); body = body if isinstance(body, str) else json.dumps(body)
            out.append(uses[c['tool_use_id']].replace('\n', ' ') + '\t' + body.replace('\n', ' '))
print('\n'.join(out))
PY
}
enrol() { python3 - "$REC" "$@" <<'PY'
import json, os, sys
rec = sys.argv[1]
d = json.load(open(rec))
d['workers'] = list(dict.fromkeys((d.get('workers') or []) + sys.argv[2:]))
tmp = rec + '.enrol.tmp'
open(tmp, 'w').write(json.dumps(d))
os.replace(tmp, rec)
PY
}

# ---- 1. /sleep starts it ----
S1="$(uuid)"
echo "-- /away then /sleep (session $S1)"
session "$WORK/s1.jsonl" 240 2 "$S1" -- "/away" "/sleep"
SLEEP_SAID="$(result_text "$WORK/s1.jsonl" 1)"
REC="$STATE/current.json"
if [ ! -f "$REC" ]; then
  check "/sleep places the sleep record" "no record at $REC; /sleep said: $SLEEP_SAID"
  echo "Nothing after /sleep can be measured without its record."
  finish
fi
check "/sleep places the sleep record" ok
grep -q '^scope-modes: Sleep mode is on until' <<<"$SLEEP_SAID" && check "/sleep says it is on and until when" ok || check "/sleep says it is on and until when" "said: $SLEEP_SAID"
[ "$(jget "$REC" v)" = 1 ] && [ "$(jget "$REC" startedBy.sessionId)" = "$S1" ] \
  && check "the record is version 1 and names the session that started it" ok \
  || check "the record is version 1 and names the session that started it" "$(head -c 300 "$REC")"
[ "$(jget "$REC" workers)" = "[]" ] \
  && check "a headless run is never enrolled as a worker (#840)" ok \
  || check "a headless run is never enrolled as a worker (#840)" "workers=$(jget "$REC" workers)"
[ "$(jget "$REC" placeBefore)" = away ] \
  && check "the record keeps where Dan was before sleep (away here)" ok \
  || check "the record keeps where Dan was before sleep (away here)" "placeBefore=$(jget "$REC" placeBefore)"
# Every listed repository is checked with GitHub at bedtime; gh failing here, each must close (#843).
python3 - "$REC" "$HOME/.claude/mods/sleep-repos.json" <<'PY' && check "a listed repository GitHub cannot confirm is closed for the night, never let through (#843)" ok || check "a listed repository GitHub cannot confirm is closed for the night, never let through (#843)" "$(clip "$(jget "$REC" repos)" 300)"
import json, sys
rec, lists = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
named = {e if isinstance(e, str) else e.get('repo') for k in ('mergeOnly', 'mayDeploy') for e in lists.get(k, [])}
r = rec.get('repos') or {}
closed = {c.get('repo') for c in r.get('closed', [])}
sys.exit(0 if named and named <= closed and not r.get('mayDeploy') and not r.get('mergeOnly') else 1)
PY
REPORT="$(jget "$REC" report)"
case "$REPORT" in "$HOME/Downloads/Sleep report "*.md) check "the report is named for the night, in the scratch Downloads" ok ;; *) check "the report is named for the night, in the scratch Downloads" "report=$REPORT" ;; esac
[ -s "$REPORT" ] && check "the report exists from the first minute (#835)" ok || check "the report exists from the first minute (#835)" "nothing at $REPORT"
CAF="$(cut -d' ' -f1 "$STATE/caffeinate.pid" 2>/dev/null)"
case "$(ps -o comm= -p "${CAF:-0}" 2>/dev/null)" in *caffeinate) check "/sleep holds the Mac awake with caffeinate (#844)" ok ;; *) check "/sleep holds the Mac awake with caffeinate (#844)" "caffeinate.pid=${CAF:-none}" ;; esac
GEN="$(jget "$REC" generation)"
NOTES="$STATE/notes/$(printf '%s' "$GEN" | sed 's/[^A-Za-z0-9_.-]/_/g').jsonl"

# ---- 2. overnight bans refuse, in a session that is not a worker ----
S2="$(uuid)"
echo "-- two banned pushes (session $S2)"
session "$WORK/s2.jsonl" 180 1 "$S2" --allowedTools Bash -- "BAN-STEP: run the two pushes."
BAN="$(calls "$WORK/s2.jsonl")"
FORCED="$(grep -F 'git push --force origin HEAD:refs/heads/scratch-forced' <<<"$BAN")"
case "$FORCED" in
  *'sleep mode is on and Dan bans this while he sleeps'*) check "a force push while asleep is refused by the overnight ban list (#834)" ok ;;
  *) check "a force push while asleep is refused by the overnight ban list (#834)" "calls: $(clip "$BAN" 400)" ;;
esac
TO_MAIN="$(grep -F 'git push origin HEAD:main' <<<"$BAN")"
case "$TO_MAIN" in
  *'Blocked overnight'*) check "a push to the default branch while asleep is refused (#843)" ok ;;
  *) check "a push to the default branch while asleep is refused (#843)" "calls: $(clip "$BAN" 400)" ;;
esac
[ "$(git -C "$WORK/sleepdemo.git" for-each-ref --format='%(refname) %(objectname)')" = "refs/heads/main $SEED" ] \
  && check "and origin is exactly as it was" ok \
  || check "and origin is exactly as it was" "$(git -C "$WORK/sleepdemo.git" for-each-ref --format='%(refname) %(objectname)' | tr '\n' ' ')"

# ---- 3. a worker's permission prompt approved overnight, never over a refusal beneath ----
# The same two prompts twice, under a settings PermissionRequest hook that denies one of them. First
# from a session that is not a worker, where nobody answers a headless prompt, so neither runs: the
# control that shows an approval below comes from sleep mode and not from the engine (L159).
HOOKS_JSON="{\"hooks\":{\"PermissionRequest\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"$WORK/bin/deny-hook\"}]}]}}"
P0="$(uuid)"
echo "-- permission prompts, not a worker (session $P0)"
session "$WORK/p0.jsonl" 180 1 "$P0" --settings "$HOOKS_JSON" -- "PERMISSION-STEP: run the two commands."
if [ ! -s "$WORK/permission-hook.log" ]; then
  unmeasured_parts+=("a worker's permission prompt: no PermissionRequest reached the settings hook in a headless session ($(clip "$(calls "$WORK/p0.jsonl")" 300)), so approval overnight is measured only by the mod's own suite")
else
  [ ! -e "$REPO/allowed-overnight.txt" ] && [ ! -e "$REPO/denied-by-settings.txt" ] \
    && check "control: a session that is not a worker gets no prompt approved while asleep" ok \
    || check "control: a session that is not a worker gets no prompt approved while asleep" "$(ls "$REPO"); $(clip "$(calls "$WORK/p0.jsonl")" 300)"
  P1="$(uuid)"
  enrol "$P1"
  echo "-- permission prompts, a worker (session $P1, enrolled)"
  session "$WORK/p1.jsonl" 180 1 "$P1" --settings "$HOOKS_JSON" -- "PERMISSION-STEP: run the two commands."
  [ ! -e "$REPO/denied-by-settings.txt" ] \
    && check "a command a settings PermissionRequest hook denies stays refused for a worker asleep (#834)" ok \
    || check "a command a settings PermissionRequest hook denies stays refused for a worker asleep (#834)" "the file was made: $(clip "$(calls "$WORK/p1.jsonl")" 300)"
  [ -e "$REPO/allowed-overnight.txt" ] \
    && check "and a worker's own permission prompt with nothing against it is approved (#834)" ok \
    || check "and a worker's own permission prompt with nothing against it is approved (#834)" "$(clip "$(calls "$WORK/p1.jsonl")" 300)"
  # This worker claims nothing and notes nothing, so the driver's circuit breaker lets it go.
  [ "$(jget "$STATE/driver/$GEN/$P1.json" stopped)" = 'circuit breaker: 3 blocks in a row with no new commit, claim or note' ] \
    && check "a worker that makes no progress is let go by the circuit breaker after 3 blocks (#844)" ok \
    || check "a worker that makes no progress is let go by the circuit breaker after 3 blocks (#844)" "$(head -c 400 "$STATE/driver/$GEN/$P1.json" 2>&1)"
fi

# ---- 4. a worker kept going by the driver, claiming and ending one issue ----
W1="$(uuid)"
enrol "$W1"
echo "-- the worker (session $W1, enrolled)"
session "$WORK/w1.jsonl" 600 1 "$W1" --allowedTools Bash Read -- "WORKER-STEP: sleep mode is on and this session is enrolled to work overnight."
DRIVER="$STATE/driver/$GEN/$W1.json"
BLOCKS="$(jget "$DRIVER" blocks)"
case "$BLOCKS" in ''|null|0) check "the driver blocked the worker's Stop and kept it going (#844)" "driver record: $(head -c 400 "$DRIVER" 2>&1)" ;; *) check "the driver blocked the worker's Stop and kept it going (#844)" ok ;; esac
grep -q '^issues' "$WORK/source.log" 2>/dev/null \
  && check "the worker ran sleep-queue.sh next, which read the queue" ok \
  || check "the worker ran sleep-queue.sh next, which read the queue" "the stand-in source was never asked: $(clip "$(calls "$WORK/w1.jsonl")" 400)"
KINDS="$(python3 - "$NOTES" "$W1" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    try: n = json.loads(line)
    except ValueError: continue
    if n.get('by') == sys.argv[2]: print(n.get('kind'), n.get('issue', ''), 'driver' if n.get('driver') else '')
PY
)"
echo "   the worker's notes: $(tr '\n' ';' <<<"$KINDS")"
grep -q '^claim 1' <<<"$KINDS" && check "a claim was taken on the queued issue, and noted" ok || check "a claim was taken on the queued issue, and noted" "notes: $KINDS"
grep -q '^done 1' <<<"$KINDS" && check "and the claim was ended as done, and noted" ok || check "and the claim was ended as done, and noted" "notes: $KINDS"
grep -q '^heartbeat' <<<"$KINDS" && check "each block wrote a heartbeat note" ok || check "each block wrote a heartbeat note" "notes: $KINDS"
grep -q '^stopped' <<<"$KINDS" && check "the worker stopped with a note when nothing was left" ok || check "the worker stopped with a note when nothing was left" "notes: $KINDS"
[ "$(jget "${DRIVER:-/nonexistent}" stopped)" = 'the session said it stopped (its stopped note)' ] \
  && check "and the driver let it stop on that note, not on a breaker or a limit" ok \
  || check "and the driver let it stop on that note, not on a breaker or a limit" "stopped=$(jget "${DRIVER:-/nonexistent}" stopped)"
git -C "$WORK/sleepdemo.git" cat-file -e "refs/heads/sleep/1:hello.txt" 2>/dev/null \
  && check "the work landed on the claim's own branch on origin" ok \
  || check "the work landed on the claim's own branch on origin" "origin has $(git -C "$WORK/sleepdemo.git" for-each-ref --format='%(refname)' | tr '\n' ' '); calls: $(clip "$(calls "$WORK/w1.jsonl" | grep hello)" 300)"
[ "$(git -C "$REPO" branch --show-current)" = main ] \
  && check "the primary checkout was never switched off main (H7)" ok \
  || check "the primary checkout was never switched off main (H7)" "it is on $(git -C "$REPO" branch --show-current)"

# ---- 5. notes reach the report ----
grep -q 'Add goodbye.txt' "$REPORT" && check "the worker's proposed issue is in the report" ok || check "the worker's proposed issue is in the report" "$(head -c 400 "$REPORT")"
grep -q '#1' "$REPORT" && check "the report names the claimed issue" ok || check "the report names the claimed issue" "$(head -c 400 "$REPORT")"
grep -q 'issue create\|pr merge\|pr create' "$WORK/gh-called" 2>/dev/null \
  && check "nothing tried to file an issue, open or merge a PR on GitHub overnight" "gh calls: $(cat "$WORK/gh-called")" \
  || check "nothing tried to file an issue, open or merge a PR on GitHub overnight" ok

# ---- 6. /wake ends it and produces the morning instruction ----
# Wake puts every session back where Dan was before sleep and opens the report in BBEdit unless that
# place is away. A record that would not keep the report off the screen is not woken here: it is
# moved aside and the run fails, rather than open anything on the Mac.
if [ "$(jget "$REC" placeBefore)" != away ]; then
  check "the record keeps the report off the screen at wake" "placeBefore=$(jget "$REC" placeBefore); not woken"
  mkdir -p "$STATE/ended" && mv "$REC" "$STATE/ended/test-not-woken.json"
  finish
fi
S3="$(uuid)"
echo "-- /wake (session $S3)"
session "$WORK/s3.jsonl" 240 2 "$S3" -- "/wake"
WAKE_SAID="$(result_text "$WORK/s3.jsonl" 0)"
[ ! -e "$REC" ] && ls "$STATE/ended/"*"-woke-$S3.json" >/dev/null 2>&1 \
  && check "/wake moves the record aside, in the waking session's name (#840)" ok \
  || check "/wake moves the record aside, in the waking session's name (#840)" "current: $(ls "$REC" 2>&1); ended: $(ls "$STATE/ended" 2>&1)"
grep -q '^scope-modes: Sleep mode is off' <<<"$WAKE_SAID" && check "/wake says sleep mode is off" ok || check "/wake says sleep mode is off" "said: $WAKE_SAID"
grep -q 'not opened on the Mac' <<<"$WAKE_SAID" && check "away before sleep, the report waits in the held card, never opened on the screen (#837)" ok || check "away before sleep, the report waits in the held card, never opened on the screen (#837)" "said: $WAKE_SAID"
case "$(ps -o comm= -p "${CAF:-0}" 2>/dev/null)" in *caffeinate) check "/wake lets the caffeinate hold go" "pid $CAF still running" ;; *) check "/wake lets the caffeinate hold go" ok ;; esac
grep -q '"kind": *"woke"' "$NOTES" && check "the end of the night is noted (woke)" ok || check "the end of the night is noted (woke)" "no woke note in $NOTES"
grep -q 'Add goodbye.txt' "$REPORT" && grep -qi 'sleep/1\|claim' "$REPORT" \
  && check "the finished report still holds the night's claim and proposal" ok \
  || check "the finished report still holds the night's claim and proposal" "$(head -c 400 "$REPORT")"
MORNING="$(python3 - "$HOME/.claude/projects" "$S3" <<'PY'
import glob, json, os, sys
for path in glob.glob(os.path.join(sys.argv[1], '*', sys.argv[2] + '.jsonl')):
    for line in open(path):
        try: m = json.loads(line)
        except ValueError: continue
        c = (m.get('message') or {}).get('content') if m.get('type') == 'user' else None
        texts = [c] if isinstance(c, str) else [x.get('text', '') for x in c or [] if isinstance(x, dict)]
        for t in texts:
            if 'Dan is up: sleep mode is off.' in t: print(t)
PY
)"
[ -n "$MORNING" ] && check "/wake submits the morning instruction as a turn of its own (#837)" ok \
  || check "/wake submits the morning instruction as a turn of its own (#837)" "no turn holding 'Dan is up' in the waking session's transcript; results: $(head -c 300 "$WORK/s3.jsonl.summary")"
grep -q '1.1 danwright32/sleepdemo: Add goodbye.txt' <<<"$MORNING" \
  && check "and it offers the worker's proposed issue for the morning picker" ok \
  || check "and it offers the worker's proposed issue for the morning picker" "$(head -c 400 <<<"$MORNING")"

# ---- nothing outside the scratch Mac was touched ----
CHANGED="$(real_changed)"
[ -z "$CHANGED" ] && check "the real ~/.claude/state/sleep and ~/Downloads gained nothing" ok || check "the real ~/.claude/state/sleep and ~/Downloads gained nothing" "changed: $CHANGED"
[ ! -s "$WORK/screen-called" ] && check "nothing was opened, sounded or notified on the screen" ok || check "nothing was opened, sounded or notified on the screen" "$(cat "$WORK/screen-called")"
finish
