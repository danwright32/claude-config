#!/usr/bin/env bash
# When Claude Code re-reads the rule files, and what hooks/rule-files-changed.sh says about it
# (claude-config#1580), measured against the REAL Claude Code engine (L34, L82).
#
# rule-files-changed.sh tells a session, once, that a rule file changed on disk after it loaded it,
# "so what is in this session's context is the older copy". That sentence is only true while the
# session really holds the older copy, so its baseline must move exactly when Claude Code re-reads
# the files, and at no other moment. Whether it re-reads them at a compaction, a /clear or a resume
# was not written down anywhere; the binary only lists an InstructionsLoaded load_reason of
# "compact". So Claude Code itself runs a headless session here, with ~/.claude/CLAUDE.md and one
# import each carrying a marker word, a Bash step that rewrites both with a new word, and the real
# rule-files-changed.sh wired to SessionStart and UserPromptSubmit. Two readings, independent of
# each other and of the hook (L58), say which copy the session holds after each step:
#
#   what the model is sent  the scripted stand-in (tests/sleep-real-engine-model.py) logs every
#                           marker in each request it receives, and how many of the hook's notices
#   InstructionsLoaded      a throwaway hook logs each load's load_reason and the marker in the file
#                           it was handed
#
# and the steps are:
#
#   one            the first prompt: the first copy, no notice
#   after-edit     a prompt after the files changed mid session: still the first copy (Claude Code
#                  does NOT re-read them between prompts), and the hook says so, once. The
#                  control that the notice can speak at all (L1).
#   after-compact  the files changed again after that prompt, then /compact: the session now holds
#                  the copy on disk at the compaction, so the hook must say nothing (#1580)
#   after-clear    changed again, then /clear: a new session id, holding the copy on disk then
#   resumed        changed again with no session running, then `claude -p --resume`: the copy on
#                  disk then, with Claude Code's own note that it replaces the earlier one, and no
#                  notice from the hook
#
# Measured on 2026-10-24 with Claude Code 2.1.309: every step above held as described, and before
# the #1580 change the hook said the false notice at after-compact and at resumed.
#
# The model costs nothing (a key that is not a real one, ANTHROPIC_BASE_URL at the stand-in); HOME
# is a scratch folder. Wherever there is no Claude Code or no macOS (CI's Linux runner) it says
# UNMEASURED and why; RULE_FILES_REAL_ENGINE=0 skips it.
#
# What a headless run cannot show, said rather than passed: the interactive /resume picker, which a
# headless session does not offer (read from its own list of slash commands below), and whether the
# MODS are renamed at a compaction, which this suite does not set up.
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

if [ "${RULE_FILES_REAL_ENGINE:-}" = 0 ]; then
  unmeasured "when Claude Code re-reads the rule files was not measured: RULE_FILES_REAL_ENGINE=0 skips it"
fi
[ "$(uname)" = Darwin ] || unmeasured "when Claude Code re-reads the rule files is measured by running Claude Code itself, on macOS only"
CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || unmeasured "there is no claude command on PATH to run the engine with"

REAL_HOME="$HOME"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-rule-files-reload.XXXXXX")"
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
  printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit $?
}

# ---- the scratch Mac: rule files with a marker, the real hook, and a load logger ----
export HOME="$WORK/home"
RULES="$HOME/.claude"
mkdir -p "$RULES" "$WORK/repo" "$WORK/state"
git -C "$WORK/repo" init -q
# The marker word is never written whole in a prompt: the edit step names only its suffix, so a
# marker the model is sent can only have come from a rule file.
cat > "$WORK/edit.sh" <<EOF
#!/bin/bash
printf '# probe rules\nRULEPROBE-Main%s\n@RULES-B.md\n' "\$1" > "$RULES/CLAUDE.md"
printf 'RULEPROBE-Import%s\n' "\$1" > "$RULES/RULES-B.md"
EOF
bash "$WORK/edit.sh" ONE
cat > "$WORK/loaded.py" <<'PY'
import json, os, re, sys
d = json.load(sys.stdin)
p = d.get('file_path') or ''
marks = re.findall(r'RULEPROBE-[A-Za-z0-9]+', open(p).read()) if p and os.path.isfile(p) else []
with open(sys.argv[1], 'a') as f:
    f.write(json.dumps({'session': d.get('session_id'), 'reason': d.get('load_reason'), 'marks': marks}) + '\n')
PY
HOOK="$ROOT/payload/hooks/rule-files-changed.sh"
python3 - "$RULES/settings.json" "$HOOK" "$WORK/loaded.py" "$WORK/loaded.log" <<'PY'
import json, shlex, sys
out, hook, loaded, log = sys.argv[1:]
run = {'hooks': [{'type': 'command', 'command': 'bash ' + shlex.quote(hook)}]}
json.dump({'hooks': {
    'SessionStart': [run],
    'UserPromptSubmit': [run],
    'InstructionsLoaded': [{'hooks': [{'type': 'command', 'command': 'python3 %s %s' % (shlex.quote(loaded), shlex.quote(log))}]}],
}}, open(out, 'w'))
PY
: > "$WORK/loaded.log"

python3 "$DIR/sleep-real-engine-model.py" "$WORK/model.port" "$WORK/model.log" &
MODEL_PID=$!
hang_wait '[ -s "$WORK/model.port" ]'
[ -s "$WORK/model.port" ] || { check "the stand-in model starts" "no port within the hang ceiling, ${HANG_S}s"; finish; }
PORT="$(cat "$WORK/model.port")"

step() { echo "PROBE-RUN: echo $1 # STEP=$1"; }
edit() { echo "PROBE-RUN: bash $WORK/edit.sh $1 # STEP=edit-$1"; }

# One headless session: OUT [claude args...] -- MESSAGE...
session() {
  local out="$1"; shift
  local extra=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do extra+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  local summary
  summary="$(cd "$WORK/repo" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_SESSION_ID \
    CLAUDE_CODE_PLUGIN_DIRS= ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" ANTHROPIC_API_KEY=test-key-not-real \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 SHELL=/bin/bash \
    CLAUDE_RULES_DIR="$RULES" CLAUDE_RULES_STATE_DIR="$WORK/state" \
    python3 "$DIR/sleep-real-engine-session.py" "$out" 180 "$#" "$@" -- \
      "$CLAUDE_BIN" -p --model haiku --setting-sources user,project --allowedTools Bash \
      --input-format stream-json --output-format stream-json --verbose ${extra[@]+"${extra[@]}"})"
  echo "   session: $summary" | cut -c1-300
}

SID="$(uuidgen | tr 'A-Z' 'a-z')"
echo "-- one session ($SID): a prompt, an edit, a prompt, an edit, /compact, an edit, /clear"
session "$WORK/s1.jsonl" --session-id "$SID" -- \
  "$(step one)" "$(edit TWO)" "$(step after-edit)" "$(edit THREE)" "/compact" "$(step after-compact)" \
  "$(edit FOUR)" "/clear" "$(step after-clear)"
echo "-- edited with no session running, then resumed"
bash "$WORK/edit.sh" FIVE
session "$WORK/s2.jsonl" --resume "$SID" -- "$(step resumed)"
stop_model

# ---- what the steps left ----
# The reader writes to a file, never through a command substitution, whose parse of a heredoc
# holding a quote bash 3.2 gets wrong.
python3 - "$WORK/model.log" "$WORK/loaded.log" "$WORK/s1.jsonl" "$SID" > "$WORK/verdict" <<'PY'
import glob, json, os, re, sys
model_log, loaded_log, s1, sid = sys.argv[1:]
said = []
def check(name, problem):
    said.append(('ok' if not problem else problem, name))
def mk(word):
    return ['RULEPROBE-Import' + word, 'RULEPROBE-Main' + word]

# The first request of each step: which markers it carried, and how many notices.
first = {}
for line in open(model_log):
    d = json.loads(line)
    m = re.search(r'# STEP=(\S+)', d.get('probe') or '')
    if m and 'marks' in d and m.group(1) not in first:
        first[m.group(1)] = (d['marks'], d['notices'])
want = {
    'one': (mk('ONE'), 0, 'the first prompt is sent the first copy, and no notice'),
    'after-edit': (mk('ONE'), 1, 'a prompt after a mid session edit is still sent the first copy (no re-read between prompts), with one notice'),
    'after-compact': (mk('THREE'), 0, '/compact re-reads the rule files: the next prompt is sent the copy on disk at the compaction, and no notice'),
    'after-clear': (mk('FOUR'), 0, '/clear re-reads the rule files: the next prompt is sent the copy on disk then, and no notice'),
    'resumed': (sorted(mk('FIVE') + mk('THREE')), 0, '--resume re-reads the rule files: the resumed prompt is sent the copy on disk then beside the one its transcript holds, and no notice'),
}
for step, (marks, notices, name) in want.items():
    got = first.get(step)
    if got is None:
        check(name, 'the stand-in model was never sent this step')
        continue
    check(name, '' if (got[0], got[1]) == (marks, notices) else f'sent markers {got[0]} and {got[1]} notices')

# Claude Code's own note that a resume's re-read copy replaces the earlier one, in what the model is
# sent. Read from the resumed session's transcript, which holds what the session was given.
note = False
for path in glob.glob(os.path.join(os.environ['HOME'], '.claude', 'projects', '*', sid + '.jsonl')):
    note = note or ('Instruction files were re-read' in open(path).read())
check("the resumed session is told the re-read copy replaces the earlier one", '' if note else 'no such note in its transcript')

# The second reading: InstructionsLoaded, per session, in order.
loads = [json.loads(l) for l in open(loaded_log) if l.strip()]
def reasons(session):
    return [(x['reason'], x['marks']) for x in loads if x['session'] == session]
mine = reasons(sid)
check('InstructionsLoaded: a load with reason compact carried the copy on disk at the compaction',
      '' if ('compact', ['RULEPROBE-MainTHREE']) in mine else f'loads of {sid}: {mine}')
check('InstructionsLoaded: the resume loaded the copy on disk then, as a session_start load',
      '' if ('session_start', ['RULEPROBE-MainFIVE']) in mine else f'loads of {sid}: {mine}')
cleared = [x for x in loads if x['session'] != sid]
check('InstructionsLoaded: /clear started a new session id that loaded the copy on disk then',
      '' if any(x['reason'] == 'session_start' and x['marks'] == ['RULEPROBE-MainFOUR'] for x in cleared) else f'other loads: {cleared}')
# The copy written mid session and replaced before the compaction is never loaded: nothing re-reads
# the files between prompts.
check('InstructionsLoaded: no load between prompts (the copy written mid session is never loaded)',
      '' if not any(x['marks'] and x['marks'][0].endswith('TWO') for x in loads) else f'loads: {loads}')

# The interactive /resume picker: said as unmeasured only when the headless session itself does not
# offer it, read from its own list of slash commands (L460).
offered = None
for line in open(s1):
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if d.get('type') == 'system' and d.get('subtype') == 'init':
        offered = 'resume' in (d.get('slash_commands') or [])
        break
if offered is None:
    check('the session listed its slash commands', 'no init line')
elif offered:
    check('the in process /resume is measured', 'a headless session now offers /resume, so this suite should measure it rather than call it unmeasured')
else:
    print('unmeasured\tthe in process /resume picker: a headless session does not offer /resume (its own slash command list), so --resume is measured instead; and whether mods are renamed at a compaction')
for verdict, name in said:
    print(f'{verdict}\t{name}')
PY
VERDICT="$(cat "$WORK/verdict")"
while IFS=$'\t' read -r verdict name; do
  [ -n "$name" ] || continue
  if [ "$verdict" = unmeasured ]; then echo "SUITE-PART-UNMEASURED $name"; else check "$name" "$verdict"; fi
done <<< "$VERDICT"
[ -n "$VERDICT" ] || check "the steps' logs could be read" "the reader printed nothing"
finish
