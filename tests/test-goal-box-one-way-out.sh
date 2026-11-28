#!/usr/bin/env bash
# The Goal accomplished box's one way out (claude-config#3843).
#
# A prompt of the goal box mod that asks for the box starts a turn whose call would show it, and
# the box itself is a call's result. Both go out through one function, `leave` in
# payload/mods/goal-box/hooks/register.ts, which weighs the end of turn review before either. A
# send or a showing written anywhere else skips that, and the box then shows behind a review Dan
# has not answered. A rule each new site has to remember is a rule one site forgets, so this suite
# reads every .ts file under payload/mods/goal-box/hooks, mod-kit's copies included, and fails when:
#
#   the engine's prompt noun is reached anywhere outside leave (a send): as a member, by a quoted
#     index, or taken out of the engine by name;
#   the card, the box's text, the record of a box shown or a tool result is reached anywhere
#     outside leave (a showing);
#   leave reaches a send before it has asked what the turn ends found of the review, or a showing
#     before it has asked the record;
#   leave or the files cannot be found, or the scan finds no send and no showing inside leave,
#     which is never read as nothing to check (L98).
#
# What the mod does once inside leave is held by its own tests
# (payload/mods/goal-box/tests/register.test.ts). This suite holds only that there is no other door.
#
# The scan is then run on copies of the source held in memory, each with one site planted to go
# round leave, and the suite fails unless every plant is refused (L1).
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

command -v python3 >/dev/null 2>&1 || unmeasured "the scan is run with python3, which this machine lacks"

# GOAL_BOX_HOOKS_DIR points the scan at another copy of the hooks folder, for a control run on a
# planted file. Left unset, it is the real one.
python3 -I - "${GOAL_BOX_HOOKS_DIR:-$ROOT/payload/mods/goal-box/hooks}" <<'PY'
import os, re, sys

hooks = sys.argv[1]
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


REGISTER = 'register.ts'
# The line leave's body opens on, and the first line after it that is a closing brace alone.
OPENS = re.compile(r'^async function leave\(.*\): Promise<PromptLeft \| BoxLeft> \{$')

# A send: the engine's prompt noun, however it is reached. Read on the raw text, comments and
# strings included, so nothing a reader of the code could miss is skipped; a comment that spells
# one of these outside leave fails too, and is reworded.
SENDS = [
    ('the prompt noun as a member', re.compile(r'\.\s*prompt\b')),
    ('the prompt noun by a quoted index', re.compile(r'''[\w$)\]]\s*\[\s*['"`]prompt['"`]\s*\]''')),
    ('the prompt noun taken out by name', re.compile(r'\{[^{}\n]*\bprompt\b[^{}\n]*\}\s*=[^=>]')),
]
# A showing: the card drawn, the box's text built, a box recorded as shown, a tool result returned.
SHOWS = [
    ('the card', re.compile(r'\.\s*card\s*\(')),
    ("the box's text", re.compile(r'\bboxText\s*\(')),
    ("the card's content", re.compile(r'\bcardOf\s*\(')),
    ('the record of a box shown', re.compile(r'\bclaim\s*\(')),
]
RESULT = ('a tool result', re.compile(r'\breturn\b[^\n]*\{\s*result\s*:'))


def read_tree(folder):
    files = {}
    for at, _, names in os.walk(folder):
        for name in sorted(names):
            if name.endswith('.ts'):
                path = os.path.join(at, name)
                with open(path) as f:
                    files[os.path.relpath(path, folder)] = f.read()
    return files


def scan(files):
    """Every way round leave in these files, and what was found inside it."""
    problems, inside = [], {'send': 0, 'show': 0}
    source = files.get(REGISTER)
    if source is None:
        return ['%s is not among the files read, so leave cannot be found' % REGISTER], inside
    lines = source.split('\n')
    opens = [i for i, l in enumerate(lines) if OPENS.match(l)]
    if len(opens) != 1:
        return ['leave was found %d times in %s where it must be found once, so no site can be placed inside or outside it' % (len(opens), REGISTER)], inside
    first = opens[0]
    last = next((i for i in range(first + 1, len(lines)) if lines[i] == '}'), None)
    if last is None:
        return ["the end of leave's body was not found in %s" % REGISTER], inside
    for rel in sorted(files):
        for n, line in enumerate(files[rel].split('\n')):
            within = rel == REGISTER and first <= n <= last
            for kind, group in (('send', SENDS), ('show', SHOWS + ([RESULT] if rel == REGISTER else []))):
                for what, pattern in group:
                    if not pattern.search(line):
                        continue
                    if within:
                        inside[kind] += 1
                    else:
                        problems.append('%s:%d reaches %s outside leave: %s' % (rel, n + 1, what, line.strip()[:120]))
    body = '\n'.join(lines[first:last + 1])

    def at(pattern):
        m = re.search(pattern, body)
        return m.start() if m else None

    send, asked, kept = at(r'\.\s*prompt\b'), at(r'\breadAtEnd\s*\('), at(r'\breviewOpenRef\b')
    if send is not None and (asked is None or kept is None or not asked < kept < send):
        problems.append('leave sends a prompt before it has read what the turn ends found of the review (readAtEnd, then reviewOpenRef, then the send)')
    review = at(r'\breviewNow\s*\(')
    for what, pattern in SHOWS:
        shows = at(pattern.pattern)
        if shows is not None and (review is None or not review < shows):
            problems.append('leave reaches %s before it has asked the record at the call (reviewNow)' % what)
    return problems, inside


files = read_tree(hooks)
check('the hooks folder holds the mod, its register.ts among at least five files', None if REGISTER in files and len(files) >= 5 else 'read %d .ts files under %s: %s' % (len(files), hooks, sorted(files)))
if REGISTER not in files:
    done()
problems, inside = scan(files)
check('every send of a prompt and every showing of the box goes through leave', '; '.join(problems) if problems else None)
check('leave itself holds the send and the showing, so the scan had something to place', None if inside['send'] >= 1 and inside['show'] >= 4 else 'found %d sends and %d showings inside leave' % (inside['send'], inside['show']))

# ---- The scan is seen to fail: one site planted at a time, in memory ----
other = next(rel for rel in sorted(files) if rel != REGISTER)


def planted(rel, change):
    copy = dict(files)
    copy[rel] = change(copy[rel])
    return copy


def after(text):
    return lambda source: source + '\n' + text + '\n'


def swap(old, new):
    def change(source):
        if source.count(old) != 1:
            raise ValueError('%r is in %s %d times, expected once' % (old, REGISTER, source.count(old)))
        return source.replace(old, new)
    return change


PLANTS = [
    ('a second send written after leave', REGISTER, after("const roundIt = async ($: EngineInterface) => $.prompt.submit({ text: askDoneText() })"), r'reaches the prompt noun as a member outside leave'),
    ('a send in another file of the mod', other, after("export const roundIt = ($: { prompt: { submit: (q: { text: string }) => unknown } }) => $.prompt.submit({ text: 'x' })"), r'reaches the prompt noun as a member outside leave'),
    ('the prompt noun reached by a quoted index', REGISTER, after("const roundIt = ($: EngineInterface) => ($ as never)['prompt']"), r'reaches the prompt noun by a quoted index outside leave'),
    ('the prompt noun taken out of the engine by name', REGISTER, after("const roundIt = ($: EngineInterface) => { const { prompt } = $; return prompt }"), r'reaches the prompt noun taken out by name outside leave'),
    ('a card drawn outside leave', REGISTER, after("const showIt = ($: EngineInterface) => $.modkit.card({ toolUseId: 't', title: [], lines: [] })"), r'reaches the card outside leave'),
    ("the box's text built outside leave", REGISTER, after("const showIt = () => boxText('g', [])"), r"reaches the box's text outside leave"),
    ("the card's content built outside leave", other, after("export const showIt = () => cardOf('t', 'g', [])"), r"reaches the card's content outside leave"),
    ('a box recorded as shown outside leave', REGISTER, after("const showIt = ($: EngineInterface, entry: GoalBoxShown) => claim($, entry)"), r'reaches the record of a box shown outside leave'),
    ('a tool result returned outside leave', REGISTER, after("const showIt = () => { return { result: 'GOAL ACCOMPLISHED', text: '' } }"), r'reaches a tool result outside leave'),
    ('leave sending without reading what the turn ends found', REGISTER, swap('  await readAtEnd($, q.end)\n  const open', '  const open'), r'leave sends a prompt before it has read'),
    ('leave showing the box without asking the record', REGISTER, swap('await reviewNow($, prompts)', 'null'), r'before it has asked the record at the call'),
    ('leave gone, its sites left where they were', REGISTER, lambda source: source.replace('async function leave(', 'async function leaves('), r'leave was found 0 times'),
]
for what, rel, change, expected in PLANTS:
    try:
        found, _ = scan(planted(rel, change))
    except ValueError as err:
        check('planted, the scan refuses %s' % what, 'the control could not be planted: %s' % err)
        continue
    check('planted, the scan refuses %s' % what, None if any(re.search(expected, p) for p in found) else 'it reported %r' % found)
done()
PY
