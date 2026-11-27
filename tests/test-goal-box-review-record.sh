#!/usr/bin/env bash
# The Goal accomplished box's read of the end of turn review's record, run against the real record
# (claude-config#3843).
#
# The box waits until the end of turn review has been handed to the session and Dan has answered
# it. It knows by asking payload/hooks/lib/review-record.py, the record's one owner, with the command
# in payload/mods/goal-box/hooks/review.ts, and it tells a session that skipped the review's last
# step which command to run. The goal box's own suite stands in for both with strings it wrote
# (reviewSays and LAST_STEP in payload/mods/goal-box/tests/register.test.ts). Strings nobody measured
# would defend whatever they said (L48), so this suite runs the mod's own two commands against the
# real file and fails when:
#
#   the command the mod reads the record with cannot be read out of review.ts, or the real file does
#     not answer it with one of the three states the mod's reader knows, for a turn in each state;
#   the real file answers a record it cannot read with anything the mod's reader would take for a
#     state, where the mod must be told it could not be read;
#   the command the mod hands the session as the review's last step does not, run as written with a
#     path holding a space and an apostrophe, turn a handed over review into an answered one;
#   the stand in's answers in the goal box suite are not the shape the real file prints;
#   the read leaves anything beside the files it loads.
#
# Seen to fail with the state word the real file prints changed (L1).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
unmeasured() { echo "SUITE-PART-UNMEASURED $1"; printf 'SUITE-RESULT passed=0 failed=0\n'; exit 0; }

command -v python3 >/dev/null 2>&1 || unmeasured "the record is read with python3, which this machine lacks"

python3 -I -B - "$ROOT" <<'PY'
import json, os, re, shutil, subprocess, sys, tempfile

root = sys.argv[1]
passed = failed = 0


def check(what, problem):
    global passed, failed
    if problem:
        failed += 1
        print('FAIL: %s (%s)' % (what, problem))
    else:
        passed += 1
        print('PASS: ' + what)


def done():
    print('SUITE-RESULT passed=%d failed=%d' % (passed, failed))
    sys.stdout.flush()
    sys.exit(1 if failed else 0)


def text_of(rel):
    try:
        with open(os.path.join(root, rel)) as f:
            return f.read()
    except OSError:
        return None


source = text_of('payload/mods/goal-box/hooks/review.ts') or ''

# The read, as the mod's command builder holds it: python3, its options, the file, state, the transcript.
m = re.search(r"\['python3', ((?:'-[A-Za-z]', )+)reviewRecordFile\(home\), 'state', '--transcript', transcript\]", source)
f = re.search(r"reviewRecordFile = \(home: string\): string => `\$\{home\.replace\([^)]*\)\}/\.claude/(hooks/lib/review-record\.py)`", source)
check('the command the mod reads the record with can be read out of review.ts', None if m and f else 'reviewStateArgv or reviewRecordFile is not written as this suite reads it')
s = re.search(r"^const STATES = \[([^\]]*)\] as const$", source, re.M)
STATES = re.findall(r"'([a-z]+)'", s.group(1)) if s else []
check("the states the mod's reader knows can be read out of review.ts", None if sorted(STATES) == ['answered', 'handed', 'none'] else 'read %r' % STATES)
c = re.search(r"answeredCommand = \(transcript: string\): string => `(python3 ~/\.claude/hooks/lib/review-record\.py answered --transcript) \$\{quoted\(transcript\)\}`", source)
check("the last step's command can be read out of review.ts", None if c else 'answeredCommand is not written as this suite reads it')
if not (m and f and s and c):
    done()
OPTIONS = re.findall(r"'(-[A-Za-z])'", m.group(1))
REAL = os.path.join(root, 'payload', f.group(1))
check('the file the mod asks is in the payload, where the sync installs it from', None if os.path.isfile(REAL) else 'no file at %s' % REAL)


def state(transcript):
    r = subprocess.run([sys.executable, *OPTIONS, REAL, 'state', '--transcript', transcript], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def word(transcript):
    code, out, err = state(transcript)
    try:
        return (code, json.loads(out).get('state'))
    except Exception:
        return (code, 'not JSON: %r %r' % (out, err[-200:]))


def line(pid, text=None):
    return json.dumps({'type': 'user', 'promptId': pid, 'isSidechain': False, 'message': {'role': 'user', 'content': text if text is not None else [{'type': 'tool_result', 'tool_use_id': 't1', 'content': 'ok'}]}}) + '\n'


with tempfile.TemporaryDirectory() as d:
    # A home of its own, so the last step's command runs as written, with its ~ and all, against a
    # copy of the real hooks files and never the installed ones. The project folder's name holds a
    # space and an apostrophe, as the work MacBook's does.
    home = os.path.join(d, 'home')
    lib = os.path.join(home, '.claude', 'hooks', 'lib')
    os.makedirs(lib)
    shutil.copy(REAL, lib)
    shutil.copy(os.path.join(root, 'payload', 'hooks', 'turn-worked.py'), os.path.join(home, '.claude', 'hooks'))
    project = os.path.join(d, "Documents - Dan's MacBook Pro", '-repo')
    os.makedirs(project)
    t = os.path.join(project, 's1.jsonl')
    with open(t, 'w') as fh:
        fh.write(line('p1', 'do the thing') + line('p1'))

    check('a turn with nothing handed over: the real file says none, as the mod reads it', None if word(t) == (0, 'none') else 'it answered %r' % (word(t),))
    r = subprocess.run([sys.executable, '-I', '-B', REAL, 'handed', '--transcript', t, '--label', 'SESSION REFLECTION'], capture_output=True, text=True, timeout=30)
    check('a review handed over: the real file says handed', None if r.returncode == 0 and word(t) == (0, 'handed') else 'handed exited %d (%s), state %r' % (r.returncode, r.stderr.strip(), word(t)))

    # The last step, exactly as the mod's refusal hands it to the session: one line for a shell.
    quoted = "'" + t.replace("'", "'\\''") + "'"
    command = '%s %s' % (c.group(1), quoted)
    env = dict(os.environ, HOME=home)
    env.pop('CLAUDE_CODE_SESSION_ID', None)
    r = subprocess.run(['bash', '-c', command], capture_output=True, text=True, timeout=30, env=env)
    check("the last step's command, run as the mod writes it, records the answer", None if r.returncode == 0 and word(t) == (0, 'answered') else 'it exited %d, said %r %r, and the state is then %r' % (r.returncode, r.stdout.strip(), r.stderr.strip()[-200:], word(t)))
    check('each state the real file printed is one the mod knows', None if {'none', 'handed', 'answered'} <= set(STATES) else 'the mod knows only %r' % STATES)

    # The next prompt ends the record.
    with open(t, 'a') as fh:
        fh.write(line('p2', 'and now something else'))
    check('the next prompt: the real file says none again', None if word(t) == (0, 'none') else 'it answered %r' % (word(t),))

    # Unreadable is never a state.
    with open(t + '.review-handed.json', 'w') as fh:
        fh.write('{"turn": "p2", "id": ')
    code, out, err = state(t)
    check('a record that cannot be read exits with an error and its reason, and prints no state', None if code != 0 and err and not out else 'it exited %d, printed %r, said %r' % (code, out, err))
    code, out, err = state(os.path.join(project, 'gone.jsonl'))
    check('a transcript that is not there is an error too', None if code != 0 and err and not out else 'it exited %d, printed %r, said %r' % (code, out, err))

    # Asking writes nothing beside the files it loads (L322: where the writes land).
    os.remove(t + '.review-handed.json')
    os.remove(t + '.review-answered.json')
    hooks = os.path.join(home, '.claude', 'hooks')
    r = subprocess.run([sys.executable, *OPTIONS, os.path.join(lib, 'review-record.py'), 'state', '--transcript', t], capture_output=True, text=True, timeout=30)
    left = sorted(os.listdir(hooks)) + sorted(os.listdir(lib)) + sorted(os.listdir(project))
    check('the read leaves nothing beside the files it loads, or beside the transcript', None if r.returncode == 0 and left == ['lib', 'turn-worked.py', 'review-record.py', 's1.jsonl'] else 'exit %d, and the folders then held %r' % (r.returncode, left))

# The stand in's answers, in the goal box suite, are the shape the real file prints: one JSON object
# on a line, its state under "state".
suite = text_of('payload/mods/goal-box/tests/register.test.ts') or ''
stand = re.search(r"^const reviewSays = \(state: 'none' \| 'handed' \| 'answered'\): Gh => \(\{ exitCode: 0, stdout: `\$\{JSON\.stringify\(state === 'none' \? \{ state, turn: 'p1' \} : \{ state, turn: 'p1', handed_at: [0-9_]+, label: '[A-Z ]+' \}\)\}\\n` \}\)$", suite, re.M)
check('the stand in for the record in the goal box suite answers as the real file does: exit 0, one JSON object, its state under "state"', None if stand else 'reviewSays in register.test.ts is not written as this suite reads it, so its shape is no longer held to the real file')
done()
PY
