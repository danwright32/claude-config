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
import contextlib, glob, importlib.util, io, json, os, re, stat, subprocess, sys

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


def unmeasured(what, why):
    """One check this machine cannot make, said on the line run-all-tests.sh counts, never as a pass
    and never as a fail (L411)."""
    print('SUITE-PART-UNMEASURED %s (%s)' % (what, why))


NOT_LOCKED = 'a write into a folder with its write permission taken away succeeded on this machine, as it does for the superuser, so this suite cannot make a folder nothing can be written in'


def locked(folder):
    """Takes the right to write in a folder away and says whether that holds here, by trying a write.
    It does not hold for the superuser, whose writes pass the permission bits by: a check that needs
    the write refused would then fail for a reason that is not the code's, so its caller says it is
    unmeasured. The caller gives the right back."""
    os.chmod(folder, stat.S_IRUSR | stat.S_IXUSR)
    probe = os.path.join(folder, 'probe')
    try:
        open(probe, 'w').close()
    except OSError:
        return True
    os.remove(probe)
    return False


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
# A byte that is not UTF-8. Every record is written as ASCII, so such a byte is damage: the file is
# "cannot be read" in one line, never a traceback, and never read around the byte, which would make
# a hand over of a damaged id that no answer could ever name.
t4b = transcript('badbyte', WORKED('p1'))
with open(HANDED(t4b), 'wb') as f:
    f.write(b'{"v": 1, "turn": "p1", "id": "h1\xff", "at": 1800000000.0, "label": ""}\n')
code, out, err = record('state', '--transcript', t4b)
check('a hand over file holding a byte that is not UTF-8 is "cannot be read" in one line, with no traceback, never read around the byte', None if code == 3 and not out and len(err.splitlines()) == 1 and 'Traceback' not in err and 'review-handed.json' in err else 'exit %d, out %r, err %r' % (code, out, err))
code, out, err = record('answered', '--transcript', t4b)
check('and the last step for it is one line of error, with no traceback and no answer written', None if code == 2 and len(err.splitlines()) == 1 and 'Traceback' not in err and not os.path.exists(ANSWERED(t4b)) else 'exit %d, out %r, err %r, answer file there: %r' % (code, out, err, os.path.exists(ANSWERED(t4b))))
record('handed', '--transcript', t4b)
with open(ANSWERED(t4b), 'wb') as f:
    f.write(b'{"v": 1, "turn": "p1", "handed": "\xc3\x28", "at": 1800000000.0}\n')
code, out, err = record('state', '--transcript', t4b)
check('an answer file holding a byte that is not UTF-8 is "cannot be read" in one line, with no traceback', None if code == 3 and not out and len(err.splitlines()) == 1 and 'Traceback' not in err and 'review-answered.json' in err else 'exit %d, out %r, err %r' % (code, out, err))
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
# A hand over written with no turn stays "cannot be read" after the transcript comes to name a
# prompt: which turn it belongs to still cannot be told, and "none" there would say nothing of it.
add(t5, [user('p9', 'the next thing'), assistant()])
got = state(t5)
check('a hand over written with no turn stays "cannot be read" once the transcript names a prompt, never none in silence', None if got.startswith('exit 3: ') and 'names no turn' in got else got)
code, out, err = record('answered', '--transcript', t5)
check('and the last step for it is an error that says so, never "nothing to mark"', None if code == 2 and 'names no turn' in err and 'Nothing to mark' not in out else 'exit %d, out %r, err %r' % (code, out, err))
add(t5, WORKED('p10'))
record('handed', '--transcript', t5)
said('until the next hand over, in a turn that can be told, replaces it', state(t5), 'handed')

# The same for a hand over file that holds no usable turn however it came to: no turn, a null one,
# a number, an empty one.
t5b = transcript('noturn', WORKED('p1'))
for what, more in (('no turn at all', {}), ('a null turn', {'turn': None}), ('a number for its turn', {'turn': 7}), ('an empty turn', {'turn': ''})):
    with open(HANDED(t5b), 'w') as f:
        json.dump(dict({'v': 1, 'id': 'h1', 'at': 1800000000.0, 'label': ''}, **more), f)
    got = state(t5b)
    check('a hand over holding %s is "cannot be read", never none in silence' % what, None if got.startswith('exit 3: ') and 'names no turn' in got else got)

# A hand over whose time is not a number, and an answer that names no hand over.
t5c = transcript('oddtime', WORKED('p1'))
with open(HANDED(t5c), 'w') as f:
    json.dump({'v': 1, 'turn': 'p1', 'id': 'h1', 'at': True, 'label': ''}, f)
got = state(t5c)
check('a hand over whose time is true, not a number, is "cannot be read"', None if got.startswith('exit 3: ') and 'no time' in got else got)
t5d = transcript('oddanswer', WORKED('p1'))
record('handed', '--transcript', t5d)
with open(ANSWERED(t5d), 'w') as f:
    json.dump({'v': 1, 'turn': 'p1', 'at': 1800000000.0}, f)
got = state(t5d)
check('an answer that names no hand over is "cannot be read", never "not answered"', None if got.startswith('exit 3: ') and 'review-answered.json' in got and 'names no hand over' in got else got)

# Which line is the turn's prompt.
t5e = transcript('sidechain', WORKED('p1'))
record('handed', '--transcript', t5e)
side = json.loads(user('p2', 'a prompt handed to a subagent'))
side['isSidechain'] = True
add(t5e, [json.dumps(side)])
said("a subagent's line in the transcript is not the turn's prompt: the hand over still reads handed", state(t5e), 'handed')
t5f = transcript('fallback', WORKED('p1'))
record('handed', '--transcript', t5f)
add(t5f, [user(None, 'a line that names no prompt')])
said('a last user line naming no prompt falls back to the line before it, so the hand over still reads handed', state(t5f), 'handed')

# A hand over that cannot be written.
t6 = transcript('readonly', WORKED('p1'))
holds = locked(os.path.dirname(t6))
code, out, err = record('handed', '--transcript', t6)
os.chmod(os.path.dirname(t6), stat.S_IRWXU)
WHAT = 'a hand over that cannot be written is an error that names the file and why'
if holds:
    check(WHAT, None if code == 2 and 'review-handed.json' in err else 'exit %d, err %r' % (code, err))
else:
    unmeasured(WHAT, NOT_LOCKED)
# The same rule where no permission is involved, so it is measured for the superuser too: a folder
# sits where the record's file goes, and the move into place is refused for anybody.
t6b = transcript('inplace', WORKED('p1'))
os.mkdir(HANDED(t6b))
code, out, err = record('handed', '--transcript', t6b)
check('a hand over whose file cannot be moved into place is an error that names the file and why', None if code == 2 and 'review-handed.json' in err else 'exit %d, err %r' % (code, err))
check('and it leaves no half written file beside the transcript', None if beside(t6b) == [os.path.basename(HANDED(t6b))] else 'beside it: %r' % beside(t6b))
# An answer that cannot be written: the same folder in the way, where the answer's file goes.
t6c = transcript('answerinplace', WORKED('p1'))
record('handed', '--transcript', t6c)
os.mkdir(ANSWERED(t6c))
code, out, err = record('answered', '--transcript', t6c)
check('an answer that could not be written is an error that names the file, never a quiet success', None if code == 2 and 'review-answered.json' in err and 'Recorded' not in out else 'exit %d, out %r, err %r' % (code, out, err))

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
check("and none of them says anything of another's files on the way", None if not any(e.strip() for _, e in codes) else 'they said: %r' % sorted(set(e.strip() for _, e in codes if e.strip())))
check('every read taken while they ran was a whole record or none', None if all(s in ('none', 'handed') for s in reads) else 'reads: %r' % reads)
said('and the record they leave is one whole hand over', state(t8), 'handed')
check('with no temp file left behind', None if beside(t8) == [os.path.basename(HANDED(t8))] else 'beside it: %r' % beside(t8))

# ---- Record files whose transcript has gone ----
# The tidy up deletes files without asking, so each of its limits is held here by a planted file
# that taking the limit away would remove, or leave. It removes exactly two
# things: a record this file wrote, for a transcript that is no longer there, and a temp file of this
# file's own naming that is more than an hour old. Everything else in the folder stays.
t9 = transcript('kept', WORKED('p1'))
folder = os.path.dirname(t9)
HOUR = 3600


def put(name, text='{}', age=0):
    path = os.path.join(folder, name)
    with open(path, 'w') as f:
        f.write(text)
    if age:
        then = os.path.getmtime(path) - age
        os.utime(path, (then, then))
    return path


def real_records(name):
    """Both record files of a transcript, written by the record itself, and the transcript then removed."""
    gone = transcript(name, WORKED('p1'), folder=folder)
    record('handed', '--transcript', gone)
    record('answered', '--transcript', gone)
    os.remove(gone)
    return [os.path.basename(HANDED(gone)), os.path.basename(ANSWERED(gone))]


A_RECORD = json.dumps({'v': 1, 'turn': 'p1', 'id': 'h1', 'at': 1800000000.0, 'label': ''})
# Every hand over tidies the folder, so the two that set this up come before anything is planted.
other = transcript('other', WORKED('p1'), folder=folder)
record('handed', '--transcript', other)
record('answered', '--transcript', other)
removed = real_records('gone')
removed += [os.path.basename(put('kept.jsonl.review-handed.json.tmp.4242.0a1b2c3d', A_RECORD, age=HOUR + 300))]
removed += [os.path.basename(put('gone.jsonl.review-answered.json.tmp.7.ffffffff', '{"v": 1, "tur', age=2 * HOUR))]
kept = ['kept.jsonl', 'other.jsonl', 'other.jsonl.review-handed.json', 'other.jsonl.review-answered.json']
# Not this file's to remove, each by one limit.
kept += [os.path.basename(put(n, t, age=a)) for n, t, a in (
    ('notes.txt', '{}', 0),
    ('other.jsonl.skip-stop-hooks', '', 0),
    # A temp file still inside the hour: a second writer may be about to move it into place.
    ('kept.jsonl.review-handed.json.tmp.4243.0a1b2c3e', A_RECORD, 0),
    ('kept.jsonl.review-answered.json.tmp.4244.0a1b2c3f', A_RECORD, HOUR - 300),
    # Old, and named like a temp file, but not as this file names one.
    ('report.jsonl.review-handed.json.tmp.keep', A_RECORD, 2 * HOUR),
    ('report.jsonl.review-handed.json.tmp.12.0a1b2c3d.bak', A_RECORD, 2 * HOUR),
    # A record's ending on a file not named for a transcript, and a record's name with more after it.
    ('x.review-handed.json', A_RECORD, 2 * HOUR),
    ('lost.jsonl.review-handed.json.bak', A_RECORD, 2 * HOUR),
    # A record's name, or a temp file's, with a line end after it: the name must end where the
    # record's does, and each of these has its transcript there.
    ('kept.jsonl.review-handed.json\n', A_RECORD, 2 * HOUR),
    ('other.jsonl.review-answered.json\n', A_RECORD, 2 * HOUR),
    ('kept.jsonl.review-handed.json.tmp.4245.0a1b2c40\n', A_RECORD, 2 * HOUR),
    # Named exactly as a record of a transcript that is gone, and holding something else.
    ('mine.jsonl.review-handed.json', 'my own notes, not a record', 2 * HOUR),
    ('mine.jsonl.review-answered.json', '{"turn": "p1"}', 2 * HOUR),
    ('list.jsonl.review-handed.json', '[1, 2]', 2 * HOUR),
    # Another tool's file under a record's name: it carries the version, and none of a record's fields.
    ('tool.jsonl.review-handed.json', '{"v": 1, "notes": "kept by another tool"}', 2 * HOUR),
    ('tool.jsonl.review-answered.json', json.dumps({'v': 1, 'turn': 'p1', 'id': 'h1', 'at': 1800000000.0, 'label': ''}), 2 * HOUR),
    # A hand over's fields with no version, with a time that is no number, and with no time.
    ('nov.jsonl.review-handed.json', json.dumps({'turn': 'p1', 'id': 'h1', 'at': 1800000000.0, 'label': ''}), 2 * HOUR),
    ('soon.jsonl.review-handed.json', json.dumps({'v': 1, 'turn': 'p1', 'id': 'h1', 'at': 'soon', 'label': ''}), 2 * HOUR),
    ('when.jsonl.review-answered.json', json.dumps({'v': 1, 'turn': 'p1', 'handed': 'h1'}), 2 * HOUR),
    ('noid.jsonl.review-handed.json', json.dumps({'v': 1, 'turn': 'p1', 'at': 1800000000.0, 'label': ''}), 2 * HOUR),
    # Reads as a record, and is far larger than any record this file writes.
    ('big.jsonl.review-handed.json', A_RECORD + ' ' * 70000, 2 * HOUR),
)]
# A folder named as a record, a link named as a record (pointing at a file that holds one), and a
# record inside a folder beneath.
os.mkdir(os.path.join(folder, 'dir.jsonl.review-handed.json'))
os.symlink(os.path.join(folder, 'x.review-handed.json'), os.path.join(folder, 'link.jsonl.review-handed.json'))
os.mkdir(os.path.join(folder, 'beneath'))
with open(os.path.join(folder, 'beneath', 'deep.jsonl.review-handed.json'), 'w') as f:
    f.write(A_RECORD)
kept += ['dir.jsonl.review-handed.json', 'link.jsonl.review-handed.json', 'beneath']
# A transcript that is a link pointing at nothing is still there by name: its record stays.
os.symlink(os.path.join(folder, 'nowhere.jsonl'), os.path.join(folder, 'dangling.jsonl'))
put('dangling.jsonl.review-handed.json', A_RECORD, age=2 * HOUR)
kept += ['dangling.jsonl', 'dangling.jsonl.review-handed.json']
# Named as a record of a transcript that is gone, and holding a byte that is not UTF-8: it is never
# read around the byte, so it is not known to be a record, and it stays.
with open(os.path.join(folder, 'bytes.jsonl.review-handed.json'), 'wb') as f:
    f.write(b'{"v": 1, "turn": "p1", "id": "h1", "at": 1800000000.0, "label": "\xff"}')
kept += ['bytes.jsonl.review-handed.json']
before = sorted(os.listdir(folder))
check('the tidy up test starts with every file it means to plant', None if before == sorted(kept + removed) else 'the folder holds %r' % before)
code, out, err = record('handed', '--transcript', t9)
kept += ['kept.jsonl.review-handed.json']
left = sorted(os.listdir(folder))
check('a hand over removes the records of transcripts that have gone and its own temp files past an hour old', None if not [n for n in removed if n in left] else 'still there: %r' % [n for n in removed if n in left])
check('and nothing else: a fresh temp file, a file not named as it names one, a file that holds no record of its or is far too large to be one, a folder, a link, a folder beneath, the record of a transcript that is a dangling link', None if left == sorted(kept) else 'gone that should have stayed: %r; there that should not be: %r' % (sorted(set(kept) - set(left)), sorted(set(left) - set(kept))))
check('the record beneath is untouched', None if os.path.exists(os.path.join(folder, 'beneath', 'deep.jsonl.review-handed.json')) else 'it was removed')
check('and it says nothing of what it left alone, the folder named as a record included', None if code == 0 and not err else 'exit %d, it said %r' % (code, err))

# Two hand overs at once tidy one folder. A temp file listed a moment ago has since been moved into
# place by its writer, and a leftover has since been removed by the other's tidy up: gone is what
# the tidy up wanted, so neither is said as a file that "could not be removed", a false line in what
# Dan reads. The tidy up is handed the folder's listing as it stood a moment before, with none of
# the files there, which is the race itself and waits on no timing (L290). Only the copy of the
# record's file loaded here sees that listing.
def tidy_says(names, refuses=False):
    spec = importlib.util.spec_from_file_location('review_record_under_test', RECORD)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    class Moment:
        def __getattr__(self, name):
            return getattr(os, name)

        def listdir(self, folder):
            return list(names)

        def remove(self, path):
            if refuses:
                raise PermissionError(13, 'Permission denied', path)
            return os.remove(path)

    module.os = Moment()
    said = io.StringIO()
    with contextlib.redirect_stderr(said):
        module.sweep(os.path.join(work, 'tidy-project'))
    return said.getvalue().strip()


said('a temp file its writer has since moved into place is passed over, with nothing said', tidy_says(['w.jsonl.review-handed.json.tmp.4242.0a1b2c3d']), '')
said('a leftover another hand over has since removed is passed over, with nothing said', tidy_says(['gone.jsonl.review-handed.json', 'gone.jsonl.review-answered.json']), '')
# A leftover that is there (a record of this file's, its transcript gone) and whose removal is refused.
os.makedirs(os.path.join(work, 'tidy-project'))
with open(os.path.join(work, 'tidy-project', 'gone.jsonl.review-handed.json'), 'w') as f:
    f.write(A_RECORD)
got = tidy_says(['gone.jsonl.review-handed.json'], refuses=True)
check('a leftover that is there and cannot be removed is still said', None if 'could not be removed' in got and 'Permission denied' in got else 'it said %r' % got)

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
holds = locked(os.path.dirname(t13))
code, text, err = reason(['--instruction', REFLECTION, '--label', 'SESSION REFLECTION', '--transcript', t13])
os.chmod(os.path.dirname(t13), stat.S_IRWXU)
for what, problem in (
    ('a hand over that could not be written still sends the review', None if code == 0 and text and 'SESSION REFLECTION. ' in text else 'exit %d, reason %r, err %r' % (code, text, err)),
    ('and says in the reason that the record was not written, and why', None if text and 'REVIEW RECORD NOT WRITTEN' in text and 'review-handed.json' in text else 'reason: %r' % text),
):
    if holds:
        check(what, problem)
    else:
        unmeasured(what, NOT_LOCKED)
# Measured for the superuser too: a folder sits where the record's file goes.
t13b = transcript('reasoninplace', WORKED('p1'))
os.mkdir(HANDED(t13b))
code, text, err = reason(['--instruction', REFLECTION, '--label', 'SESSION REFLECTION', '--transcript', t13b])
check('a hand over whose file could not be moved into place still sends the review, and says the record was not written', None if code == 0 and text and 'SESSION REFLECTION. ' in text and 'REVIEW RECORD NOT WRITTEN' in text and 'review-handed.json' in text else 'exit %d, reason %r, err %r' % (code, text, err))
code, text, err = reason(['--instruction', REFLECTION, '--label', 'SESSION REFLECTION'])
check('a review built with no transcript says the hand over could not be recorded', None if code == 0 and text and 'REVIEW RECORD NOT WRITTEN' in text else 'exit %d, reason %r' % (code, text))

# The hand over is recorded only once the reason is built: a reason that could not be built was never
# handed to the session, and a record of it would hold the box for a review nobody was given. The
# builder is made to fail inside a copy of the helper loaded here, since no input makes it fail.
t14 = transcript('unbuilt', WORKED('p1'))
spec = importlib.util.spec_from_file_location('review_reason_under_test', REASON)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


def unbuilt(*args, **kwargs):
    raise RuntimeError('the reason could not be built')


helper.build_reason = unbuilt
argv, sys.argv = sys.argv, [REASON, '--instruction', REFLECTION, '--label', 'SESSION REFLECTION', '--transcript', t14]
try:
    helper.main()
    raised = 'main returned without the failure'
except RuntimeError as exc:
    raised = str(exc)
finally:
    sys.argv = argv
check('a reason that could not be built fails the helper', None if raised == 'the reason could not be built' else raised)
check('and records no hand over: nothing is beside the transcript', None if beside(t14) == [] else 'beside it: %r' % beside(t14))

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
# review fired (EITHER WAY). The issue review's own instruction is at the size limit
# test-review-instructions.sh holds it to, so the step is not repeated there: the
# reflection is handed over in every turn the issue review is (checked below on one transcript, and
# the issue review's conditions are the reflection's plus a cooldown), and the goal box's own
# refusal names the command to a session that skipped it.
COMMAND = 'python3 ~/.claude/hooks/lib/review-record.py answered'
body = open(os.path.join(hooks, 'review', 'session-reflection.md')).read()
tail = body.split('EITHER WAY', 1)[1] if 'EITHER WAY' in body else ''
check('the reflection gives the last step its command, in the part that holds either way', None if COMMAND in tail else 'the command %r is not after EITHER WAY' % COMMAND)
check('and puts it before the call for the Goal accomplished box', None if COMMAND in tail and 'goal_accomplished' in tail.split(COMMAND, 1)[1] else 'goal_accomplished does not come after the command')
check('the file that command names is this one', None if os.path.isfile(RECORD) else 'no file at %s' % RECORD)
# The record's own account of who runs the last step names the instruction files that carry it. Each
# file it names does carry the command, so that account cannot go on naming one that never did.
source = open(RECORD).read()
account = source.split('  answered  ', 1)[1].split('  state  ', 1)[0] if '  answered  ' in source and '  state  ' in source else ''
named = sorted(set(re.findall(r'review/([a-z-]+\.md)', account)))
lacking = [n for n in named if COMMAND not in open(os.path.join(hooks, 'review', n)).read()]
check("every instruction the record's own account says runs the last step holds its command", None if named and not lacking else 'it names %r, and the command is not in %r' % (named, lacking))
tb = transcript('both', WORKED('p1'))
spoke = ['"decision"' in hook(name, tb)[1] for name in ('feature-issue-review.sh', 'session-reflection.sh')]
check('on a turn the issue review is handed over, the reflection, which carries the last step, is too', None if spoke == [True, True] else 'issue review spoke: %r, reflection spoke: %r' % tuple(spoke))

# ---- It writes nothing into the hooks folder ----
caches = glob.glob(os.path.join(hooks, '**', '__pycache__', 'turn-worked*'), recursive=True) + glob.glob(os.path.join(hooks, '**', '__pycache__', 'review-record*'), recursive=True)
check('none of these runs left a compiled copy of the files they load', None if not caches else 'left %r' % caches)
done()
PY
