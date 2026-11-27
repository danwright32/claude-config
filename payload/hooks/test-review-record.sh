#!/usr/bin/env bash
# The end of turn review's own record that it was handed to the session and that Dan answered it
# (claude-config#3843), lib/review-record.py, and the one place that writes the hand over,
# lib/review-reason.py.
#
# Dan, 2026-11-27, on the issue: the Goal accomplished box is held "until the review is answered",
# and of how the box is to know, "The review says so itself". So the review records that it was
# handed over, its last step records that he answered it, and the goal box asks this record. The
# rules held here, each seen to fail before the code that keeps it (L1):
#
#   a hand over is recorded, per session and per turn, beside the session's transcript, and only for
#     an end of turn review (an instruction in the hooks' own review/ folder), never for another
#     Stop hook that builds its reason the same way;
#   the last step marks that hand over answered, and a later hand over is not answered by it;
#   the next prompt, of any origin, ends the record: a review handed over in an earlier turn and
#     never answered reads as none, and so does an answer left from one;
#   a Stop hook's feedback and a tool's result are the same turn;
#   a record that cannot be read is said (exit 3 and why), never read as none or as answered, and a
#     hand over that cannot be written is said in the reason Dan sees;
#   two writers at once leave a whole record: every write is a whole file moved into place;
#   record files whose transcript has gone are removed at the next hand over in that folder;
#   both review hooks, run for real, leave the hand over, and a turn they stay quiet on leaves none;
#   the reflection's instruction, handed over whenever a review is, names the last step's command,
#     and it is this file.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "SUITE-PART-UNMEASURED the record is kept by python3, which this machine lacks"; printf 'SUITE-RESULT passed=0 failed=0\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-review-record.XXXXXX")" || exit 2
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'." >&2; exit 2 ;;
esac
WORK="$(cd "$WORK" && pwd)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# Every hook run below is pinned to a throwaway spool, temp folder and sleep record (L2), and the
# record itself lands beside the throwaway transcript, which is the point of keeping it there.
export CLAUDE_ISSUE_SPOOL_DIR="$WORK/spool"
export TMPDIR="$WORK/tmp"
export CLAUDE_SLEEP_RECORD="$WORK/no-sleep-record.json"
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR" "$TMPDIR"
unset CLAUDE_DETACHED_RUN CLAUDE_CODE_SESSION_ID CLAUDE_TRANSCRIPT_ROOT CLAUDE_REVIEW_RECORD_MIDWRITE CLAUDE_REVIEW_REASON_FORCE_FAIL

python3 -I -B - "$DIR" "$WORK" <<'PY'
import glob, json, os, stat, subprocess, sys

hooks, work = sys.argv[1], sys.argv[2]
RECORD = os.path.join(hooks, 'lib', 'review-record.py')
REASON = os.path.join(hooks, 'lib', 'review-reason.py')
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


def run(argv, env=None, stdin=None):
    full = dict(os.environ)
    full.update(env or {})
    r = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=60, env=full)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def record(*args, env=None):
    return run([sys.executable, '-I', '-B', RECORD, *args], env=env)


# A transcript as Claude Code writes one, cut to the fields the record reads. The shape was measured
# on a real session's transcript on 2026-11-27 (L48): 2481 of its 2484 user lines carried a promptId,
# it changed at each of the 177 prompts of any origin, and a Stop hook's feedback line (isMeta, a
# string) and every tool result carried the promptId of the turn they belong to.
def user(pid, text=None, meta=False):
    o = {'type': 'user', 'isSidechain': False, 'sessionId': 's', 'message': {'role': 'user', 'content': text if text is not None else [{'type': 'tool_result', 'tool_use_id': 't1', 'content': 'ok'}]}}
    if pid is not None:
        o['promptId'] = pid
    if meta:
        o['isMeta'] = True
    return json.dumps(o)


def assistant(tool=None):
    content = [{'type': 'tool_use', 'name': tool, 'id': 't1', 'input': {}}] if tool else [{'type': 'text', 'text': 'done'}]
    return json.dumps({'type': 'assistant', 'message': {'role': 'assistant', 'content': content}})


WORKED = lambda pid: [user(pid, 'do the thing'), assistant('Edit'), user(pid), assistant()]


def transcript(name, lines, folder=None):
    d = folder or os.path.join(work, name + '-project')
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, name + '.jsonl')
    with open(path, 'w') as f:
        f.write(''.join(l + '\n' for l in lines))
    return path


def add(path, lines):
    with open(path, 'a') as f:
        f.write(''.join(l + '\n' for l in lines))


def state(path):
    """The state word, or 'exit N: stderr' when it could not be read."""
    code, out, err = record('state', '--transcript', path)
    if code != 0:
        return 'exit %d: %s' % (code, err)
    try:
        return json.loads(out)['state']
    except Exception as exc:
        return 'not the JSON it promises: %r (%s)' % (out, exc)


def said(what, got, want):
    check(what, None if got == want else 'it said %r, expected %r' % (got, want))


HANDED = lambda t: t + '.review-handed.json'
ANSWERED = lambda t: t + '.review-answered.json'


def beside(t):
    """Every file beside a transcript that is not the transcript."""
    return sorted(n for n in os.listdir(os.path.dirname(t)) if n != os.path.basename(t))


def load(path):
    """A record file as written, or an empty record when it is not there or does not parse."""
    try:
        with open(path) as f:
            o = json.load(f)
        return o if isinstance(o, dict) else {}
    except Exception:
        return {}


# ---- The record itself ----
t = transcript('plain', WORKED('p1'))
said('a turn with no review handed over reads as none', state(t), 'none')
check('asking the state writes nothing', None if beside(t) == [] else 'left %r' % beside(t))

code, out, err = record('handed', '--transcript', t, '--label', 'SESSION REFLECTION')
check('a hand over is recorded', None if code == 0 else 'exit %d: %s' % (code, err))
said('a review handed over and not yet answered reads as handed', state(t), 'handed')
check('the hand over is one file beside the transcript, named for it', None if beside(t) == [os.path.basename(HANDED(t))] else 'beside it: %r' % beside(t))
code, out, err = record('state', '--transcript', t)
try:
    o = json.loads(out)
    problem = None if o.get('label') == 'SESSION REFLECTION' and o.get('turn') == 'p1' and isinstance(o.get('handed_at'), (int, float)) else 'it printed %r' % out
except Exception as exc:
    problem = 'not JSON: %r' % out
check('the state names which review, which turn and when', problem)

# A Stop hook's feedback and the tool results after it are the same turn.
add(t, [user('p1', 'Stop hook feedback: SESSION REFLECTION. Read the instruction.', meta=True), assistant('Read'), user('p1')])
said("a Stop hook's feedback and a tool result keep the turn: still handed", state(t), 'handed')

code, out, err = record('answered', '--transcript', t)
check('the last step records the answer, and says so', None if code == 0 and 'answered' in out.lower() and 'nothing' not in out.lower() else 'exit %d, out %r, err %r' % (code, out, err))
said('once the last step has run the review reads as answered', state(t), 'answered')

# A second hand over in the same turn is a review of its own: the old answer does not answer it.
record('handed', '--transcript', t, '--label', 'END OF TURN ISSUE REVIEW')
said('a later hand over in the same turn is not answered by the earlier answer', state(t), 'handed')
record('answered', '--transcript', t)
said('and its own last step answers it', state(t), 'answered')

# The clear end: the next prompt, of any origin.
add(t, [user('p2', 'now something else'), assistant('Bash'), user('p2')])
said('the next prompt ends the record: an answer from the turn before is not this turn\'s', state(t), 'none')
t2 = transcript('stale', WORKED('p1'))
record('handed', '--transcript', t2)
add(t2, [user('p2', 'The goal-box plugin sent a message: call the box again'), assistant()])
said('a review handed over in an earlier turn and never answered does not hold the next turn', state(t2), 'none')
code, out, err = record('answered', '--transcript', t2)
check('the last step run in a turn with no hand over marks nothing, and says so', None if code == 0 and 'nothing' in out.lower() and not os.path.exists(ANSWERED(t2)) else 'exit %d, out %r, answered file there: %r' % (code, out, os.path.exists(ANSWERED(t2))))
record('handed', '--transcript', t2)
said('a hand over in the new turn holds it', state(t2), 'handed')

# The last step as the instructions give it: no transcript named, found by the session's id.
root = os.path.join(work, 'projects')
t3 = transcript('0a1b2c3d-session', WORKED('p1'), folder=os.path.join(root, '-Users-somebody-repo'))
record('handed', '--transcript', t3)
code, out, err = record('answered', env={'CLAUDE_CODE_SESSION_ID': '0a1b2c3d-session', 'CLAUDE_TRANSCRIPT_ROOT': root})
check("the last step finds the session's transcript by its id", None if code == 0 and state(t3) == 'answered' else 'exit %d, out %r, err %r, state %r' % (code, out, err, state(t3)))
code, out, err = record('answered', env={'CLAUDE_CODE_SESSION_ID': 'no-such-session', 'CLAUDE_TRANSCRIPT_ROOT': root})
check('a session whose transcript cannot be found is an error that says so, never a quiet success', None if code == 2 and 'no-such-session' in err else 'exit %d, out %r, err %r' % (code, out, err))
env = dict(os.environ)
env.pop('CLAUDE_CODE_SESSION_ID', None)
r = subprocess.run([sys.executable, '-I', '-B', RECORD, 'answered'], capture_output=True, text=True, timeout=60, env=env)
check('the last step with no session and no transcript named is an error that says so', None if r.returncode == 2 and r.stderr.strip() else 'exit %d, err %r' % (r.returncode, r.stderr))
code, out, err = record('answered', env={'CLAUDE_CODE_SESSION_ID': '../../etc/passwd', 'CLAUDE_TRANSCRIPT_ROOT': root})
check('a session id that is not one never goes into a path', None if code == 2 and 'not a session id' in err else 'exit %d, err %r' % (code, err))

# ---- A record that cannot be read is said, never taken for none or answered ----
t4 = transcript('broken', WORKED('p1'))
with open(HANDED(t4), 'w') as f:
    f.write('{"turn": "p1", "id": ')
got = state(t4)
check('a hand over file cut off mid write is "cannot be read", never none', None if got.startswith('exit 3: ') and 'review-handed.json' in got else got)
with open(HANDED(t4), 'w') as f:
    f.write('["a list, not a record"]')
got = state(t4)
check('a hand over file that is not a record is "cannot be read"', None if got.startswith('exit 3: ') else got)
os.remove(HANDED(t4))
record('handed', '--transcript', t4)
with open(ANSWERED(t4), 'w') as f:
    f.write('not json at all')
got = state(t4)
check('an answer file that cannot be read is "cannot be read", never answered and never handed', None if got.startswith('exit 3: ') and 'review-answered.json' in got else got)
code, out, err = record('answered', '--transcript', t4)
check('the last step writes over an answer file that could not be read', None if code == 0 and state(t4) == 'answered' else 'exit %d, err %r, state %r' % (code, err, state(t4)))
got = state(os.path.join(work, 'nowhere', 'gone.jsonl'))
check('a transcript that is not there is "cannot be read", never none', None if got.startswith('exit 3: ') else got)
code, out, err = record('handed', '--transcript', os.path.join(work, 'nowhere', 'gone.jsonl'))
check('a hand over for a transcript that is not there is an error that says so', None if code == 2 and err else 'exit %d, err %r' % (code, err))

# A transcript whose lines name no prompt: the turn cannot be told.
t5 = transcript('unkeyed', [user(None, 'do the thing'), assistant('Edit'), user(None), assistant()])
said('a transcript naming no prompt, with nothing handed over, reads as none', state(t5), 'none')
code, out, err = record('handed', '--transcript', t5)
check('a hand over is still written for a transcript naming no prompt', None if code == 0 and os.path.exists(HANDED(t5)) else 'exit %d, err %r' % (code, err))
got = state(t5)
check('and its state is "cannot be read", saying the turn cannot be told, never handed for ever', None if got.startswith('exit 3: ') and 'prompt' in got else got)

# A hand over that cannot be written.
t6 = transcript('readonly', WORKED('p1'))
os.chmod(os.path.dirname(t6), stat.S_IRUSR | stat.S_IXUSR)
code, out, err = record('handed', '--transcript', t6)
os.chmod(os.path.dirname(t6), stat.S_IRWXU)
check('a hand over that cannot be written is an error that names the file and why', None if code == 2 and 'review-handed.json' in err else 'exit %d, err %r' % (code, err))

# ---- Assume it runs twice ----
t7 = transcript('twice', WORKED('p1'))
record('handed', '--transcript', t7, '--label', 'FIRST')
first = load(HANDED(t7))
seam = os.path.join(work, 'midwrite.sh')
seen = os.path.join(work, 'midwrite.seen')
with open(seam, 'w') as f:
    f.write('#!/bin/bash\n"%s" -I -B "%s" state --transcript "%s" > "%s" 2>&1\nls "%s" >> "%s"\n' % (sys.executable, RECORD, t7, seen, os.path.dirname(t7), seen))
os.chmod(seam, stat.S_IRWXU)
code, out, err = record('handed', '--transcript', t7, '--label', 'SECOND', env={'CLAUDE_REVIEW_RECORD_MIDWRITE': seam})
mid = open(seen).read() if os.path.exists(seen) else ''
check('a write goes to a file of its own first: the seam between the write and the move ran', None if code == 0 and mid else 'exit %d, err %r, the seam left %r' % (code, err, mid))
check('at that instant a reader still sees the whole record from before', None if '"label": "FIRST"' in mid and '"state": "handed"' in mid else 'the reader saw %r' % mid)
check('and the new record is beside it under another name, not yet in place', None if '.tmp.' in mid else 'the folder held %r' % mid)
second = load(HANDED(t7))
check('after the move the record is the new one, whole, with a new id', None if second.get('label') == 'SECOND' and second.get('id') != first.get('id') else 'it holds %r' % second)
check('and nothing is left beside it', None if beside(t7) == [os.path.basename(HANDED(t7))] else 'beside it: %r' % beside(t7))

t8 = transcript('race', WORKED('p1'))
procs = [subprocess.Popen([sys.executable, '-I', '-B', RECORD, 'handed', '--transcript', t8, '--label', 'W%d' % i], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True) for i in range(12)]
reads = [state(t8) for _ in range(12)]
codes = [(p.wait(timeout=60), p.stderr.read()) for p in procs]
check('twelve hand overs at once all succeed', None if all(c == 0 for c, _ in codes) else 'exits and errors: %r' % [x for x in codes if x[0] != 0])
check('every read taken while they ran was a whole record or none', None if all(s in ('none', 'handed') for s in reads) else 'reads: %r' % reads)
said('and the record they leave is one whole hand over', state(t8), 'handed')
check('with no temp file left behind', None if beside(t8) == [os.path.basename(HANDED(t8))] else 'beside it: %r' % beside(t8))

# ---- Record files whose transcript has gone ----
t9 = transcript('kept', WORKED('p1'))
folder = os.path.dirname(t9)
gone = os.path.join(folder, 'gone.jsonl')
for path in (HANDED(gone), ANSWERED(gone), os.path.join(folder, 'notes.txt'), os.path.join(folder, 'other.jsonl.skip-stop-hooks')):
    with open(path, 'w') as f:
        f.write('{}')
other = transcript('other', WORKED('p1'), folder=folder)
record('handed', '--transcript', other)
record('handed', '--transcript', t9)
left = sorted(os.listdir(folder))
want = sorted(['kept.jsonl', 'kept.jsonl.review-handed.json', 'other.jsonl', 'other.jsonl.review-handed.json', 'notes.txt', 'other.jsonl.skip-stop-hooks'])
check("a hand over removes the record files of transcripts that have gone, and nothing else", None if left == want else 'the folder holds %r, expected %r' % (left, want))

# ---- The one place a hand over is written: lib/review-reason.py ----
def reason(argv_more, env=None):
    code, out, err = run([sys.executable, REASON, *argv_more], env=env)
    try:
        p = json.loads(out)
    except Exception:
        return code, None, err
    return code, (p.get('reason') if p.get('decision') == 'block' else None), err


t10 = transcript('reason', WORKED('p1'))
REFLECTION = os.path.join(hooks, 'review', 'session-reflection.md')
code, text, err = reason(['--instruction', REFLECTION, '--label', 'SESSION REFLECTION', '--transcript', t10])
check('building a review\'s reason records its hand over', None if code == 0 and text and state(t10) == 'handed' else 'exit %d, reason %r, state %r, err %r' % (code, text, state(t10), err))
check('and the reason Dan sees says nothing of the record when it was written', None if text and 'record' not in text.lower() else 'reason: %r' % text)
check('the hand over names which review it was', None if load(HANDED(t10)).get('label') == 'SESSION REFLECTION' else 'it holds %r' % load(HANDED(t10)))

# Another Stop hook builds its reason through the same helper (check-later-nudge.sh, pointing at a
# skill): that is no end of turn review, and it records nothing.
t11 = transcript('notreview', WORKED('p1'))
skill = os.path.join(work, 'skills', 'check-later', 'SKILL.md')
os.makedirs(os.path.dirname(skill))
with open(skill, 'w') as f:
    f.write('# check later\n')
code, text, err = reason(['--instruction', skill, '--label', 'CHECK LATER', '--transcript', t11])
check('a reason pointing at an instruction outside the review folder records no hand over', None if code == 0 and text and beside(t11) == [] else 'exit %d, reason %r, beside the transcript: %r' % (code, text, beside(t11)))
t12 = transcript('missing', WORKED('p1'))
code, text, err = reason(['--instruction', os.path.join(hooks, 'review', 'no-such-review.md'), '--label', 'SESSION REFLECTION', '--transcript', t12])
check('a review whose instruction is missing was not handed over, so nothing is recorded', None if code == 0 and text and 'CANNOT RUN' in text and beside(t12) == [] else 'exit %d, reason %r, beside: %r' % (code, text, beside(t12)))

# A hand over that could not be written is said in the reason, which is what Dan sees, and the
# review still goes out.
t13 = transcript('reasonro', WORKED('p1'))
os.chmod(os.path.dirname(t13), stat.S_IRUSR | stat.S_IXUSR)
code, text, err = reason(['--instruction', REFLECTION, '--label', 'SESSION REFLECTION', '--transcript', t13])
os.chmod(os.path.dirname(t13), stat.S_IRWXU)
check('a hand over that could not be written still sends the review', None if code == 0 and text and 'SESSION REFLECTION. ' in text else 'exit %d, reason %r, err %r' % (code, text, err))
check('and says in the reason that the record was not written, and why', None if text and 'REVIEW RECORD NOT WRITTEN' in text and 'review-handed.json' in text else 'reason: %r' % text)
code, text, err = reason(['--instruction', REFLECTION, '--label', 'SESSION REFLECTION'])
check('a review built with no transcript says the hand over could not be recorded', None if code == 0 and text and 'REVIEW RECORD NOT WRITTEN' in text else 'exit %d, reason %r' % (code, text))

# ---- Both review hooks, run for real ----
def hook(name, t, active=False):
    proj = os.path.join(work, 'proj-%s-%s' % (name, os.path.basename(t)))
    os.makedirs(proj, exist_ok=True)
    payload = json.dumps({'transcript_path': t, 'stop_hook_active': active, 'session_id': 's'})
    return run(['bash', os.path.join(hooks, name)], env={'CLAUDE_PROJECT_DIR': proj}, stdin=payload)


for name, label in (('session-reflection.sh', 'SESSION REFLECTION'), ('feature-issue-review.sh', 'END OF TURN ISSUE REVIEW')):
    th = transcript('hook-' + name, WORKED('p1'))
    code, out, err = hook(name, th)
    blocked = '"decision"' in out and 'block' in out
    check('%s, at the end of a turn that changed something, hands the review over and records it' % name, None if blocked and state(th) == 'handed' and load(HANDED(th)).get('label') == label else 'exit %d, out %r, state %r, err %r' % (code, out[:200], state(th), err[-300:]))
    tq = transcript('quiet-' + name, [user('p1', 'what does this do?'), assistant('Read'), user('p1'), assistant()])
    code, out, err = hook(name, tq)
    check('%s stays quiet on a read only turn and records nothing' % name, None if out == '' and beside(tq) == [] else 'out %r, beside the transcript: %r' % (out[:200], beside(tq)))
    ta = transcript('active-' + name, WORKED('p1'))
    code, out, err = hook(name, ta, active=True)
    check("%s stays quiet on its own continuation and records nothing" % name, None if out == '' and beside(ta) == [] else 'out %r, beside: %r' % (out[:200], beside(ta)))

# ---- The last step, as the instruction gives it ----
# The command lives in the reflection's instruction, in the part that holds whether or not the issue
# review fired (EITHER WAY). The issue review's own instruction stands at 2,995 of the 3,000
# characters test-review-instructions.sh allows it, so the step is not repeated there: the
# reflection is handed over in every turn the issue review is (checked below on one transcript, and
# the issue review's conditions are the reflection's plus a cooldown), and the goal box's own
# refusal names the command to a session that skipped it.
COMMAND = 'python3 ~/.claude/hooks/lib/review-record.py answered'
body = open(os.path.join(hooks, 'review', 'session-reflection.md')).read()
tail = body.split('EITHER WAY', 1)[1] if 'EITHER WAY' in body else ''
check('the reflection gives the last step its command, in the part that holds either way', None if COMMAND in tail else 'the command %r is not after EITHER WAY' % COMMAND)
check('and puts it before the call for the Goal accomplished box', None if COMMAND in tail and 'goal_accomplished' in tail.split(COMMAND, 1)[1] else 'goal_accomplished does not come after the command')
check('the file that command names is this one', None if os.path.isfile(RECORD) else 'no file at %s' % RECORD)
tb = transcript('both', WORKED('p1'))
spoke = ['"decision"' in hook(name, tb)[1] for name in ('feature-issue-review.sh', 'session-reflection.sh')]
check('on a turn the issue review is handed over, the reflection, which carries the last step, is too', None if spoke == [True, True] else 'issue review spoke: %r, reflection spoke: %r' % tuple(spoke))

# ---- It writes nothing into the hooks folder ----
caches = glob.glob(os.path.join(hooks, '**', '__pycache__', 'turn-worked*'), recursive=True) + glob.glob(os.path.join(hooks, '**', '__pycache__', 'review-record*'), recursive=True)
check('none of these runs left a compiled copy of the files they load', None if not caches else 'left %r' % caches)
done()
PY
