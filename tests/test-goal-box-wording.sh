#!/usr/bin/env bash
# What does not hold the Goal accomplished box, and what a session says when it holds the box back,
# said the same way in every place a session reads it (claude-config#3864).
#
# The rule has one home in code, payload/mods/goal-box/hooks/box.ts: NOT_HELD names what does not
# hold the box (a step only Dan can take, a check /check-later has scheduled, work he declined in a
# picker), and HELD_SAY is the one line a session gives when it holds the box for work of its own.
# The tool's description is built from those two, and the mod's own tests hold it and the mod's
# prompts. The two end of turn review instructions are files a session reads beside the tool,
# payload/hooks/review/session-reflection.md and issue-review.md, written in Dan's voice, so they
# cannot be built from the constants. This suite holds them to the same rule, and fails when:
#
#   box.ts stops naming one of the three things, or its description stops carrying either constant;
#   the reflection's last line stops naming one of the three, or stops asking for the one line;
#   the issue review's last step stops asking for the one line;
#   any of them asks a session to say nothing of a box it holds back, which is the fault this fixes:
#     a box held on purpose and a box forgotten then look the same to Dan.
#
# Seen to fail on the instructions as they were before the rule was written into them (L1).
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

command -v python3 >/dev/null 2>&1 || unmeasured "the files are read with python3, which this machine lacks"

python3 -I -B - "$ROOT" <<'PY'
import os, re, sys

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
        with open(os.path.join(root, rel), encoding='utf-8') as f:
            return f.read()
    except OSError:
        return None


def constant(source, name):
    """A constant of box.ts written as one plain string, or None: a built string cannot be read here."""
    m = re.search(r'^export const %s =\s*\n?\s*(["\'])(.*)\1\s*$' % re.escape(name), source or '', re.M)
    return None if not m or '${' in m.group(2) else m.group(2).replace("\\'", "'")


BOX = 'payload/mods/goal-box/hooks/box.ts'
REVIEW = 'payload/mods/goal-box/hooks/review.ts'
REFLECTION = 'payload/hooks/review/session-reflection.md'
ISSUES = 'payload/hooks/review/issue-review.md'

box = text_of(BOX)
not_held = constant(box, 'NOT_HELD')
held_say = constant(box, 'HELD_SAY')
check('box.ts holds what does not hold the box as one plain sentence', None if not_held else 'NOT_HELD is not a plain string constant in %s' % BOX)
check('box.ts holds the one line a session gives when it holds the box', None if held_say else 'HELD_SAY is not a plain string constant in %s' % BOX)
box, not_held, held_say = box or '', not_held or '', held_say or ''

# The three things, each by the words both the code and the instruction use for it. The step is
# Dan's in the code ("only Dan can take") and his own in the instruction ("only I can take").
THREE = (
    ("a step that is Dan's alone to take", 'a step only Dan can take', 'a step only I can take'),
    ('a check /check-later has scheduled', '/check-later', '/check-later'),
    ('work Dan declined in a picker', 'declined in a picker', 'declined in a picker'),
)
for what, in_code, _ in THREE:
    check('box.ts says %s does not hold the box' % what, None if in_code in not_held else 'NOT_HELD does not hold the words %r' % in_code)
check("box.ts says a step of Dan's holds the box only with the session's own work behind it", None if 'only while work of your own waits behind it' in not_held else 'NOT_HELD does not say when a step of his does hold it')
check('box.ts asks for one line', None if 'one line' in held_say and 'waiting on' in held_say else 'HELD_SAY is %r' % held_say)
check('and only again when what it waits on changes', None if 'unless you have said so already and it has not changed' in held_say else 'HELD_SAY is %r' % held_say)

m = re.search(r'^export const DESCRIPTION = \[\n(.*?)^\]\.join', box, re.M | re.S)
description = m.group(1) if m else ''
check("the tool's description can be read out of box.ts", None if m else 'DESCRIPTION is not a list of lines joined in %s' % BOX)
check("the tool's description carries what does not hold the box", None if re.search(r'^\s*NOT_HELD,\s*$', description, re.M) else 'DESCRIPTION has no NOT_HELD line')
check("the tool's description carries the one line", None if '${HELD_SAY}' in description else 'DESCRIPTION does not use HELD_SAY')

# The reflection's last line, which is handed over in every turn a review is.
reflection = text_of(REFLECTION) or ''
last = [l for l in reflection.split('\n') if l.startswith('EITHER WAY')]
check('the reflection has its one EITHER WAY line', None if len(last) == 1 else 'found %d in %s' % (len(last), REFLECTION))
last = last[0] if last else ''
after_call = last.split('goal_accomplished', 1)[1] if 'goal_accomplished' in last else ''
check('the reflection still asks for the box, and still says an early call is refused', None if 'its own checks refuse an early call' in after_call else 'the EITHER WAY line does not say so after naming goal_accomplished')
for what, _, in_words in THREE:
    check('the reflection says %s does not hold the box' % what, None if in_words in after_call else 'the EITHER WAY line does not hold the words %r after naming goal_accomplished' % in_words)
check('the reflection asks for one line when the box is held, once', None if 'say in one line what it waits on, once, and again only when that changes' in after_call else 'the EITHER WAY line does not ask for it')

# The issue review's own last step, kept because a folded reflection's line was once dropped.
issues = text_of(ISSUES) or ''
step = [l for l in issues.split('\n') if l.startswith('6 GOAL BOX')]
check('the issue review has its one GOAL BOX step', None if len(step) == 1 else 'found %d in %s' % (len(step), ISSUES))
step = step[0] if step else ''
check('the issue review asks the session to say what the box waits on, once', None if 'else say once what it waits on' in step else 'its step 6 is %r' % step)
check("the issue review counts only the session's own part of the request", None if 'your part done, call it' in step else 'its step 6 is %r' % step)
# Both halves of the step sit under its two conditions: with a /goal set, or the tool not offered,
# the box waits on nothing of the session's, and a line saying so every turn would be noise.
check('the issue review asks for neither with a /goal set or the tool not offered', None if step.startswith('6 GOAL BOX, last (no /goal set, goal_accomplished offered): ') else 'its step 6 does not open with its two conditions around both halves: %r' % step)

# Nothing a session reads about the box asks for silence.
for rel, body in ((BOX, box), (REVIEW, text_of(REVIEW)), (REFLECTION, last), (ISSUES, step)):
    if body is None:
        check('%s can be read' % rel, 'it could not be opened')
        continue
    hit = re.search(r'say nothing', body, re.I)
    check('%s never asks a session to say nothing of the box' % rel, None if not hit else 'it still holds %r' % body[max(0, hit.start() - 40):hit.end() + 20])
done()
PY
