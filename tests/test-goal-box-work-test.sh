#!/usr/bin/env bash
# The Goal accomplished box's reading of whether a tool can change something, run against the real
# end of turn review test (claude-config#3843).
#
# The box counts an answer Dan gives in a picker as a new request only when the session then does
# work. "Work" is the end of turn review hooks' own test of whether a turn changed something,
# is_mutating in payload/hooks/turn-worked.py, which the mod runs from that file by path with the
# Python in WORK_TEST (payload/mods/goal-box/hooks/request.ts). It keeps no list of tools of its own.
#
# The goal box's own suite stands in for that run with a table of tool names (WORK_TEST_SAYS in
# payload/mods/goal-box/tests/register.test.ts). A table nobody measured would defend whatever it
# said (L48), so this suite runs the mod's own command against the real file for every row of it,
# and fails when:
#
#   a row of the table is not what the real test says of that name;
#   the real test stops counting the box's own tool as one that can change something, which is why
#     the mod leaves that tool out by name: were it to stop, the comment and the exclusion are stale;
#   the command answers yes or no for a file that is not there, or one with no such test in it,
#     where the mod must be told it could not be read;
#   asking leaves anything beside the file it asks (a compiled copy, which Python writes by default);
#   a review hook stops asking turn-worked.py, so the mod would be asking a test they no longer use.
#
# Seen to fail with a row of the table turned over (L1).
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

command -v python3 >/dev/null 2>&1 || unmeasured "the test is run with python3, which this machine lacks"

python3 -I - "$ROOT" <<'PY'
import os, re, subprocess, sys, tempfile

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
    except OSError as err:
        return None


# The mod's own command text, as the template literal in request.ts holds it.
source = text_of('payload/mods/goal-box/hooks/request.ts')
m = re.search(r'^export const WORK_TEST = `\n(.*?)^`$', source or '', re.M | re.S)
if not m or '${' in m.group(1):
    check('the command can be read out of request.ts as plain text', 'WORK_TEST is not a plain template literal in payload/mods/goal-box/hooks/request.ts')
    done()
check('the command can be read out of request.ts as plain text', None)
WORK_TEST = m.group(1).replace('\\\\', '\\')
REAL = os.path.join(root, 'payload/hooks/turn-worked.py')


# The options the mod hands python3, as its command builder holds them, so the run here is the run
# the mod makes and never one this suite wrote for itself.
o = re.search(r"\['python3', ((?:'-[A-Za-z]', )+)'-c', WORK_TEST, ", source or '')
OPTIONS = re.findall(r"'(-[A-Za-z])'", o.group(1)) if o else None
check("the options the mod runs python3 with can be read out of request.ts", None if OPTIONS else 'workTestArgv does not begin python3, its options, -c, WORK_TEST')
if not OPTIONS:
    done()


def ask(path, name):
    r = subprocess.run([sys.executable, *OPTIONS, '-c', WORK_TEST, path, name], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


# The stand in's table, row by row.
suite = text_of('payload/mods/goal-box/tests/register.test.ts')
t = re.search(r"^const WORK_TEST_SAYS: Record<string, 'yes' \| 'no'> = \{\n(.*?)^\}$", suite or '', re.M | re.S)
rows = re.findall(r"^\s*'?([A-Za-z0-9_-]+)'?: '(yes|no)',$", t.group(1), re.M) if t else []
check('the stand in table can be read out of the goal box suite', None if len(rows) >= 6 else 'found %d rows of WORK_TEST_SAYS, expected at least 6' % len(rows))
if t:
    unread = [l for l in t.group(1).split('\n') if l.strip() and not re.match(r"^\s*'?[A-Za-z0-9_-]+'?: '(yes|no)',$", l)]
    check('every line of the table is a row this suite measured', None if not unread else 'not read as a row: %r' % unread)
for name, said in rows:
    code, out, err = ask(REAL, name)
    check('the real test says %s of %s, as the stand in does' % (said, name), None if (code, out) == (0, said) else 'it exited %d and said %r %s' % (code, out, err[-200:]))
check('the table holds a tool that changes something and one that does not', None if {s for _, s in rows} == {'yes', 'no'} else 'one answer only, which measures nothing')

# Why the mod leaves its own tool out by name: the review's test would count a call to it.
code, out, err = ask(REAL, 'mcp__goal-box__goal_accomplished')
check("the real test counts the box's own tool, so the mod must leave it out by name", None if (code, out) == (0, 'yes') else 'it exited %d and said %r' % (code, out))

# Unreadable is never an answer.
code, out, err = ask(os.path.join(root, 'payload/hooks/no-such-test.py'), 'Edit')
check('a file that is not there is an error, never yes or no', None if code != 0 and out not in ('yes', 'no') else 'it exited %d and said %r' % (code, out))
with tempfile.TemporaryDirectory() as d:
    other = os.path.join(d, 'turn-worked.py')
    with open(other, 'w') as f:
        f.write('def renamed(name):\n    return True\n')
    code, out, err = ask(other, 'Edit')
    check('a file with no such test in it is an error, never yes or no', None if code != 0 and out not in ('yes', 'no') else 'it exited %d and said %r' % (code, out))

# Asking writes nothing. Python importing a file by path leaves a compiled copy in a __pycache__
# folder beside it unless told not to, and the mod asks on tool calls of every session. The sync
# leaves such folders out, so nothing would travel, but a question should not write into the hooks
# folder at all. Measured on a copy of the real file in a folder of its own (L322: where the writes
# land, never the option that should stop them).
with tempfile.TemporaryDirectory() as d:
    copy = os.path.join(d, 'turn-worked.py')
    with open(copy, 'w') as f:
        f.write(text_of('payload/hooks/turn-worked.py') or '')
    code, out, err = ask(copy, 'Edit')
    left = sorted(os.listdir(d))
    check('asking the test leaves nothing beside its file', None if (code, out, left) == (0, 'yes', ['turn-worked.py']) else 'it exited %d, said %r, and the folder then held %r' % (code, out, left))

# The same test the review hooks use: both still ask this file.
for hook in ('payload/hooks/session-reflection.sh', 'payload/hooks/feature-issue-review.sh'):
    body = text_of(hook)
    check('%s still decides by turn-worked.py' % hook, None if body and 'turn-worked.py' in body else 'it no longer names turn-worked.py, so the box would be asking a test the review does not use')
done()
PY
