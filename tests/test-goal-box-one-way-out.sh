#!/usr/bin/env bash
# The Goal accomplished box's one way out (claude-config#3843).
#
# A prompt of the goal box mod that asks for the box starts a turn whose call would show it, and
# the box itself is a call's result. Both go out through one function, `leave` in
# payload/mods/goal-box/hooks/register.ts, which weighs the end of turn review before either. A
# send or a showing written anywhere else skips that, and the box then shows behind a review Dan
# has not answered.
#
# WHAT THIS SUITE IS. A scan of the mod's text for the spellings of a send and of a showing that
# are listed below. It is not a proof that leave is the only way out: a spelling that is not
# listed passes it, and the list of those known is under WHAT IT DOES NOT SEE.
#
# It reads every file under payload/mods/goal-box (but the typings Claude Code writes into
# .claude-plugin/types, which git ignores) and fails when, outside leave:
#
#   a send:
#     the engine's prompt noun is reached, as a member, by a quoted index, or taken out by name
#       in a pattern, on one line or over several;
#     the engine is reached by an index, or anything is called by the name submit;
#     another engine call that puts text before a model is made: session.append, session.send,
#       command.run, command.register, agent.spawn, agent.call, agent.register, tool.call,
#       mcp.call, model.complete, model.fork, model.classify, ui.ask; or one of those nouns is
#       taken from `$` as a value where it is not called at once;
#   a showing:
#     the card is reached, as a member, by a quoted index, or taken out of `$` by name;
#     boxText or cardOf is named at all, outside box.ts, which defines them, and the one
#       statement of register.ts that imports them, where neither may be given another name;
#       box.ts imported whole or passed on by another file;
#     the heading is named (HEADING), outside box.ts, or its words are set down with a colon
#       after them as the box sets them;
#     the record of a box shown is written (claim);
#     a `result` key is written, whatever the line looks like: with a colon, as a shorthand, in
#       quotes, or assigned to. The one place outside leave is the type of what leave returns
#       (type BoxLeft), which must be a type alone on its line;
#   a way in for code the scan does not check:
#     hooks/hooks.json names any module but ./register.ts, or plugin.json declares hooks;
#     a file outside tests/ imports, other than as a type, anything that is not a file this
#       scan checks, or loads anything at run time (import(), require());
#     a file of the mod sits outside hooks/, tests/ and types/, or cannot be read as text.
#
# And when, inside leave: there is not exactly one send, one card, one text, one card's content,
# one record and one result; a send comes before leave has asked what the turn ends found of the
# review, or a showing before it has asked the record; or leave, its type or the import cannot be
# found, which is never read as nothing to check (L98).
#
# The mod's own tests (tests/) are read and not scanned, since they name every one of these to
# test it. What keeps them out of a session is the rule above on hooks.json and on imports.
#
# WHAT IT DOES NOT SEE.
#   A send or a showing that is inside leave and past the review only by where it stands among
#     leave's lines: the one send moved into the branch that holds, or a hold that no longer
#     refuses. The mod's tests hold those (payload/mods/goal-box/tests/register.test.ts), as they
#     hold everything leave decides.
#   A name built at run time (an index made of joined pieces), the engine held under another
#     name with one of the nouns above taken from it as a value, the heading built from pieces or
#     written with no colon, claim under another name. Mod-kit's noun taken from `$` as a value
#     and the card then taken out of that value: mod-kit's own files, copied into this mod, name
#     `$.modkit` in their comments and take a field called card out of a stored value, so neither
#     can be a rule here.
#   Text put before the model with no call on the engine: the words of a refusal, a context line
#     on another tool's result, a hook on an event whose answer is part of the prompt, and any
#     part of a mod that is not its hooks module (a settings hook, a slash command, a skill, an
#     agent, a connected server). The scan fails only on a file in a folder the mod does not have.
#   Engine calls that show Dan something and are not said to reach the model (ui.log, ui.notify,
#     ui.toast, ui.status, ui.notice, ui.place, ui.open): a second showing built on one is seen
#     only through the box's text, card or heading. tool.register, which the mod calls once at a
#     session's start, puts the tool's description before the model and is left alone.
#   A call a later release of Claude Code adds. The list above was made from the typings Claude
#     Code installs beside a mod (.claude-plugin/types/claude-code/index.d.ts), which hold calls
#     the copy in tools/typescript/claude-code-types does not.
#
# WHAT CLAUDE CODE REFUSES BY ITSELF. Not measured by this suite, and seen when each was tried
# on this mod: Claude Code does not load a mod that takes `$` apart in a parameter or by a
# pattern, reaches it as `$[name]`, or uses `$.modkit` as a value, and does not let a tool.call
# hook call `$.prompt.submit`. For those shapes the loader is the stronger guard, and for
# `$.modkit` as a value it is the only one.
#
# The scan is then run on copies of the mod's files held in memory, each with one site planted to
# go round leave, and the suite fails unless every plant is refused (L1).
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

# GOAL_BOX_MOD_DIR points the scan at another copy of the mod's folder, for a control run on a
# planted copy. Left unset, it is the real one.
python3 -I - "${GOAL_BOX_MOD_DIR:-$ROOT/payload/mods/goal-box}" <<'PY'
import json, os, re, sys

mod = sys.argv[1]
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


REGISTER = 'hooks/register.ts'
BOX = 'hooks/box.ts'
MODULES = 'hooks/hooks.json'
MANIFEST = '.claude-plugin/plugin.json'
TESTS = 'tests/'
# Written by Claude Code into a checkout whose mod it has tested, and ignored by git: the
# engine's own typings, whose examples spell every call this scan refuses.
ENGINE_TYPES = '.claude-plugin/types'
PLACES = ('hooks/', 'tests/', 'types/')
ALONE = (MANIFEST, 'tsconfig.json')

# The line leave's body opens on, and the first line after it that is a closing brace alone.
OPENS = re.compile(r'^async function leave\(.*\): Promise<PromptLeft \| BoxLeft> \{$')

SEND = 'the prompt noun as a member'
CARD = 'the card'
TEXT = "the box's text"
CONTENT = "the card's content"
RECORD = 'the record of a box shown'
RESULT = 'a tool result'
# What leave must hold exactly one of.
ONCE = (SEND, CARD, TEXT, CONTENT, RECORD, RESULT)


def read_disk(folder):
    """Every file of the mod as text, by its path under the mod with forward slashes; None where it is not text."""
    disk = {}
    for at, dirs, names in os.walk(folder):
        rel_at = os.path.relpath(at, folder).replace(os.sep, '/')
        dirs[:] = sorted(d for d in dirs if (d if rel_at == '.' else rel_at + '/' + d) != ENGINE_TYPES)
        for name in sorted(names):
            if name == '.DS_Store':
                continue
            rel = name if rel_at == '.' else rel_at + '/' + name
            with open(os.path.join(at, name), 'rb') as f:
                raw = f.read()
            try:
                disk[rel] = raw.decode('utf-8')
            except UnicodeDecodeError:
                disk[rel] = None
    return disk


# The type of what leave returns: a type alone on its line, so nothing on that line can run.
SHAPE = re.compile(r'''^type BoxLeft = [^()=`'"$\n]*$''')
# The statement that brings box.ts into register.ts by plain names.
BRINGS = re.compile(r'''^import \{[^{}]*\} from '\./box\.ts'$''', re.M)

# Each rule: what it is, its pattern, the files it may be met in anywhere, and the places of
# register.ts besides leave it may be met in. Read on the raw text, comments and strings
# included, so nothing a reader of the code could miss is skipped; a comment that spells one of
# these outside leave fails too, and is reworded.
SENDS = [
    (SEND, r'\.\s*prompt\b'),
    ('the prompt noun by a quoted index', r'''[\w$)\]]\s*\[\s*['"`]prompt['"`]\s*\]'''),
    ('the prompt noun taken out by name', r'\{[^{}]*\bprompt\b[^{}]*\}\s*(?::|=(?![=>]))'),
    ('the engine by an index', r'\$\s*\[|\$\s+as\b[^\n()]*\)\s*\['),
    ('a call by the name submit', r'\.\s*submit\s*\('),
    ('a row appended to the conversation (session.append)', r'\.\s*session\s*\.\s*append\b'),
    ('a message sent to an agent or a session (session.send)', r'\.\s*session\s*\.\s*send\b'),
    ('a slash command run or declared (command.run, command.register)', r'\.\s*command\s*\.\s*(?:run|register)\b'),
    ('an agent started, called or declared (agent.spawn, agent.call, agent.register)', r'\.\s*agent\s*\.\s*(?:spawn|call|register)\b'),
    ('a tool run (tool.call)', r'\.\s*tool\s*\.\s*call\b'),
    ("a connected server's tool run (mcp.call)", r'\.\s*mcp\s*\.\s*call\b'),
    ('a completion (model.complete, model.fork, model.classify)', r'\.\s*model\s*\.\s*(?:complete|fork|classify)\b'),
    ('a question put by the engine (ui.ask)', r'\.\s*ui\s*\.\s*ask\b'),
    # Not mod-kit's noun: the comments of mod-kit's copies in this mod name it in passing.
    ('an engine noun that can send, taken as a value', r'\$\s*\.\s*(?:session|command|agent|tool|mcp|model|ui)\b(?!\s*\.\s*\w+\s*\()'),
]
SHOWS = [
    (CARD, r'\.\s*card\b', (), ()),
    ('the card by a quoted index', r'''[\w$)\]]\s*\[\s*['"`]card['"`]\s*\]''', (), ()),
    # Only out of `$`: mod-kit's copy of inflight.ts takes a field named card out of a stored value.
    ('the card taken out of the engine by name', r'\{[^{}]*\bcard\b[^{}]*\}\s*=\s*(?:await\s+)?\$', (), ()),
    (TEXT, r'\bboxText\b', (BOX,), ('bring',)),
    (CONTENT, r'\bcardOf\b', (BOX,), ('bring',)),
    ("the box's text or card under another name", r'\b(?:boxText|cardOf)\s+as\b', (), ()),
    ('box.ts imported whole', r'''\*\s*as\s+\w+\s*from\s*['"][^'"\n]*\bbox\.ts['"]''', (), ()),
    ('box.ts passed on', r'''\bexport\s*(?:\*|\{[^{}]*\})\s*from\s*['"][^'"\n]*\bbox\.ts['"]''', (), ()),
    ("the heading's name", r'\bHEADING\b', (BOX,), ()),
    ("the heading's words with a colon after them", r'(?i)goal accomplished\s*:', (BOX,), ()),
    (RECORD, r'(?<![\w.$])claim\s*\(', (), ()),
    (RESULT, r'\bresult\s*:', (), ('shape',)),
    ('a tool result as a shorthand', r'[{,]\s*(?P<at>result)\s*[,}]', (), ()),
    ('a tool result by a quoted key', r'''['"`]result['"`]''', (), ()),
    ('a tool result assigned to', r'\.\s*result\s*=(?!=)', (), ()),
]
RULES = [('send', what, re.compile(p), (), ()) for what, p in SENDS] + [('show', what, re.compile(p), free, spans) for what, p, free, spans in SHOWS]

# An import or a re-export of named things, of everything, or of a default, and where from.
STATEMENT = re.compile(r'''^(?P<lead>(?:import|export)\s+(?:type\s+)?)(?:\*\s*(?:as\s+\w+\s*)?|\{[^{}]*\}\s*|\w+\s*(?:,\s*(?:\{[^{}]*\}|\*\s*as\s+\w+)\s*)?)from\s*['"](?P<spec>[^'"\n]+)['"]''', re.M)
BARE = re.compile(r'''^import\s*['"](?P<spec>[^'"\n]+)['"]''', re.M)
LOADS = re.compile(r'\b(?:import|require)\s*\(')


def line_of(text, at):
    n = text.count('\n', 0, at)
    return n + 1, text.split('\n')[n].strip()[:120]


def scan(disk):
    """Every way round leave in these files that the rules above spell, and what was found inside it."""
    problems, inside = [], {}
    for rel in sorted(disk):
        if disk[rel] is None:
            problems.append('%s could not be read as text, so nothing in it was checked' % rel)
        if not (rel.startswith(PLACES) or rel in ALONE):
            problems.append('%s is a file of the mod outside hooks/, tests/ and types/: a part of the mod this scan has no rule for' % rel)
    files = {rel: text for rel, text in disk.items() if text is not None and not rel.startswith(TESTS)}
    source = files.get(REGISTER)
    if source is None:
        return problems + ['%s is not among the files read, so leave cannot be found' % REGISTER], inside
    lines = source.split('\n')
    opens = [i for i, l in enumerate(lines) if OPENS.match(l)]
    if len(opens) != 1:
        return problems + ['leave was found %d times in %s where it must be found once, so no site can be placed inside or outside it' % (len(opens), REGISTER)], inside
    first = opens[0]
    last = next((i for i in range(first + 1, len(lines)) if lines[i] == '}'), None)
    if last is None:
        return problems + ["the end of leave's body was not found in %s" % REGISTER], inside
    starts = [0]
    for l in lines:
        starts.append(starts[-1] + len(l) + 1)
    where = {'leave': (starts[first], starts[last + 1])}
    shapes = [i for i, l in enumerate(lines) if re.match(r'type BoxLeft\b', l) and SHAPE.match(l)]
    if len(shapes) != 1:
        return problems + ['the type of what leave returns (type BoxLeft) was found %d times in %s as a type alone on its line, where it must be found once' % (len(shapes), REGISTER)], inside
    where['shape'] = (starts[shapes[0]], starts[shapes[0] + 1])
    brings = [m for m in BRINGS.finditer(source) if re.search(r'\b(?:boxText|cardOf)\b', m.group(0))]
    if len(brings) != 1:
        return problems + ["the statement of %s that imports boxText and cardOf from './box.ts' by plain names was found %d times, where it must be found once" % (REGISTER, len(brings))], inside
    where['bring'] = brings[0].span()

    for rel in sorted(files):
        text = files[rel]
        for kind, what, pattern, free, spans in RULES:
            for m in pattern.finditer(text):
                at = m.start('at') if 'at' in pattern.groupindex else m.start()
                if rel == REGISTER and where['leave'][0] <= at < where['leave'][1]:
                    inside[what] = inside.get(what, 0) + 1
                    continue
                if rel in free or (rel == REGISTER and any(where[s][0] <= at < where[s][1] for s in spans)):
                    continue
                n, line = line_of(text, at)
                problems.append('%s:%d reaches %s outside leave: %s' % (rel, n, what, line))
        for m in LOADS.finditer(text):
            n, line = line_of(text, m.start())
            problems.append('%s:%d loads code at run time, which this scan cannot follow: %s' % (rel, n, line))
        for m in list(STATEMENT.finditer(text)) + list(BARE.finditer(text)):
            if re.search(r'\btype\s*$', m.groupdict().get('lead') or ''):
                continue
            spec = m.group('spec')
            n, line = line_of(text, m.start())
            target = os.path.normpath(os.path.join(os.path.dirname(rel), spec)).replace(os.sep, '/')
            if not spec.startswith('.') or target not in files:
                problems.append("%s:%d imports '%s', which is not a file this scan checks (outside the mod, among its tests, or not there): %s" % (rel, n, spec, line))

    try:
        modules = json.loads(files.get(MODULES, ''))
    except ValueError:
        modules = None
    if modules != {'modules': ['./register.ts']}:
        problems.append('%s must hold ./register.ts as its one module and nothing else, and holds %r' % (MODULES, modules if modules is not None else files.get(MODULES)))
    try:
        manifest = json.loads(files.get(MANIFEST, ''))
    except ValueError:
        manifest = None
    if not isinstance(manifest, dict):
        problems.append('%s could not be read as an object, so what it declares was not checked' % MANIFEST)
    elif 'hooks' in manifest:
        problems.append('%s declares hooks, which this scan does not read' % MANIFEST)

    for what in ONCE:
        if inside.get(what, 0) != 1:
            problems.append('leave holds %s %d times, where it must hold it once' % (what, inside.get(what, 0)))
    body = source[where['leave'][0]:where['leave'][1]]

    def at(pattern):
        m = re.search(pattern, body)
        return m.start() if m else None

    send, asked, kept = at(r'\.\s*prompt\b'), at(r'\breadAtEnd\s*\('), at(r'\breviewOpenRef\b')
    if send is not None and (asked is None or kept is None or not asked < kept < send):
        problems.append('leave sends a prompt before it has read what the turn ends found of the review (readAtEnd, then reviewOpenRef, then the send)')
    review = at(r'\breviewNow\s*\(')
    for kind, what, pattern, free, spans in RULES:
        if kind != 'show':
            continue
        shows = at(pattern.pattern)
        if shows is not None and (review is None or not review < shows):
            problems.append('leave reaches %s before it has asked the record at the call (reviewNow)' % what)
    return problems, inside


disk = read_disk(mod)
hooks = [rel for rel in disk if rel.startswith('hooks/')]
check("the mod was read: register.ts and box.ts among at least five files of its hooks folder", None if REGISTER in disk and BOX in disk and len(hooks) >= 5 else 'read %d files under %s/hooks: %s' % (len(hooks), mod, sorted(hooks)))
if REGISTER not in disk:
    done()
problems, inside = scan(disk)
check('every send and every showing the scan knows the spelling of goes through leave', '; '.join(problems) if problems else None)
check('leave itself holds the send and the showing, so the scan had something to place', None if all(inside.get(what, 0) >= 1 for what in ONCE) else 'found inside leave: %r' % inside)

# ---- The scan is seen to fail: one site planted at a time, in memory ----
OTHER = 'hooks/request.ts'


def after(rel, text):
    def change(copy):
        copy[rel] = copy[rel] + '\n' + text + '\n'
    return change


def put(rel, text):
    def change(copy):
        if rel in copy:
            raise ValueError('%s is already a file of the mod' % rel)
        copy[rel] = text + '\n'
    return change


def swap(rel, old, new):
    def change(copy):
        if copy[rel].count(old) != 1:
            raise ValueError('%r is in %s %d times, expected once' % (old, rel, copy[rel].count(old)))
        copy[rel] = copy[rel].replace(old, new)
    return change


def both(*changes):
    def change(copy):
        for c in changes:
            c(copy)
    return change


OUT = r' outside leave'
ROUND = "export const roundIt = ($: { prompt: { submit: (q: { text: string }) => unknown } }) => $.prompt.submit({ text: 'x' })"
PLANTS = [
    # Sends.
    ('a second send written after leave', after(REGISTER, "const roundIt = async ($: EngineInterface) => $.prompt.submit({ text: askDoneText() })"), r'reaches the prompt noun as a member' + OUT),
    ('a send in another file of the hooks folder', after(OTHER, ROUND), r'hooks/request\.ts:\d+ reaches the prompt noun as a member' + OUT),
    ('a send in a file of the mod outside its hooks folder', both(put('lib/round.ts', ROUND), after(REGISTER, "import { roundIt } from '../lib/round.ts'\nexport const again = roundIt")), r'lib/round\.ts:1 reaches the prompt noun as a member' + OUT),
    ('a send in a file of the hooks folder that is not a .ts file', both(put('hooks/round.mts', ROUND), after(REGISTER, "import { roundIt } from './round.mts'\nexport const again = roundIt")), r'hooks/round\.mts:1 reaches the prompt noun as a member' + OUT),
    ('the prompt noun reached by a quoted index', after(REGISTER, "const roundIt = ($: EngineInterface) => ($ as never)['prompt']"), r'reaches the prompt noun by a quoted index' + OUT),
    ('the prompt noun taken out of the engine by name', after(REGISTER, "const roundIt = ($: EngineInterface) => { const { prompt } = $; return prompt }"), r'reaches the prompt noun taken out by name' + OUT),
    ('the prompt noun taken out of the engine in a parameter', after(REGISTER, "const roundIt = async ({ prompt }: EngineInterface) => prompt.submit({ text: askDoneText() })"), r'reaches the prompt noun taken out by name' + OUT),
    ('the prompt noun taken out of the engine over several lines', after(REGISTER, "const roundIt = async ($: EngineInterface) => {\n  const {\n    prompt,\n  } = $\n  return prompt.submit({ text: askDoneText() })\n}"), r'reaches the prompt noun taken out by name' + OUT),
    ('the engine reached by an index held in a name', after(REGISTER, "const NOUN = 'prompt' as const\nconst roundIt = async ($: EngineInterface) => $[NOUN].submit({ text: askDoneText() })"), r'reaches the engine by an index' + OUT),
    ('a submit called on something handed in', after(REGISTER, "const roundIt = async (door: { submit: (q: { text: string }) => unknown }) => door.submit({ text: askDoneText() })"), r'reaches a call by the name submit' + OUT),
    ('a row appended to the conversation', after(REGISTER, "const roundIt = async ($: EngineInterface) => $.session.append({ door: 'prompt', message: { text: askDoneText() } } as never)"), r'reaches a row appended to the conversation \(session\.append\)' + OUT),
    ('a message sent to a session', after(REGISTER, "const roundIt = async ($: EngineInterface, sessionId: string) => $.session.send({ to: { sessionId }, text: askDoneText() })"), r'session\.send\)' + OUT),
    ('a slash command run', after(REGISTER, "const roundIt = async ($: EngineInterface) => $.command.run({ command: 'goal' })"), r'command\.register\)' + OUT),
    ('an agent started', after(REGISTER, "const roundIt = async ($: EngineInterface) => $.agent.spawn({ prompt: askDoneText() })"), r'agent\.register\)' + OUT),
    ('a tool run by the mod', after(REGISTER, "const roundIt = async ($: EngineInterface) => $.tool.call({ tool: TOOL, input: {} } as never)"), r'\(tool\.call\)' + OUT),
    ("a connected server's tool run", after(REGISTER, "const roundIt = async ($: EngineInterface) => $.mcp.call(MOD, NAME, {})"), r'\(mcp\.call\)' + OUT),
    ('a completion asked for', after(REGISTER, "const roundIt = async ($: EngineInterface) => $.model.complete({ prompt: askDoneText() } as never)"), r'model\.classify\)' + OUT),
    ('a question put by the engine', after(REGISTER, "const roundIt = async ($: EngineInterface) => $.ui.ask('Show the box?')"), r'\(ui\.ask\)' + OUT),
    ('the session noun taken from the engine as a value', after(REGISTER, "const roundIt = async ($: EngineInterface) => { const s = $.session; return s }"), r'reaches an engine noun that can send, taken as a value' + OUT),
    # Showings.
    ('a card drawn outside leave', after(REGISTER, "const showIt = ($: EngineInterface) => $.modkit.card({ toolUseId: 't', title: [], lines: [] })"), r'reaches the card' + OUT),
    ('the card taken as a value', after(REGISTER, "const showIt = ($: EngineInterface) => { const draw = $.modkit.card; return draw }"), r'reaches the card' + OUT),
    ('the card reached by a quoted index', after(REGISTER, "const showIt = ($: EngineInterface) => $.modkit['card']({ toolUseId: 't', title: [], lines: [] } as never)"), r'reaches the card by a quoted index' + OUT),
    ('the card taken out by name over several lines', after(REGISTER, "const showIt = ($: EngineInterface) => {\n  const {\n    card,\n  } = $.modkit\n  return card({ toolUseId: 't', title: [], lines: [] } as never)\n}"), r'reaches the card taken out of the engine by name' + OUT),
    ("the box's text built outside leave", after(REGISTER, "const showIt = () => boxText('g', [])"), r"reaches the box's text" + OUT),
    ("the box's text held under another name with no call", after(REGISTER, "const words = boxText"), r"reaches the box's text" + OUT),
    ("the box's text imported under another name by another file", after(OTHER, "import { boxText as words } from './box.ts'\nexport const showIt = () => words('g', [])"), r"hooks/request\.ts:\d+ reaches the box's text or card under another name" + OUT),
    ("the box's text imported under another name by register.ts", swap(REGISTER, 'askText, boxText, cardOf, cardedSince', 'askText, boxText as words, cardOf, cardedSince'), r"reaches the box's text or card under another name" + OUT),
    ("the box's text imported a second time by register.ts", after(REGISTER, "import { boxText } from './box.ts'"), r'by plain names was found 2 times'),
    ("the card's content built outside leave", after(OTHER, "export const showIt = () => cardOf('t', 'g', [])"), r"reaches the card's content" + OUT),
    ('box.ts imported whole', after(OTHER, "import * as box from './box.ts'\nexport const showIt = () => Object.values(box)"), r'reaches box\.ts imported whole' + OUT),
    ('box.ts passed on by another file', after('hooks/review.ts', "export * from './box.ts'"), r'reaches box\.ts passed on' + OUT),
    ("the heading named outside box.ts", after(REGISTER, "import { HEADING } from './box.ts'\nconst showIt = (goal: string) => `${HEADING} ${goal}`"), r"reaches the heading's name" + OUT),
    ("the heading's words set down as the box sets them", after(REGISTER, "const showIt = (goal: string) => `Goal accomplished: ${goal}`"), r"reaches the heading's words with a colon after them" + OUT),
    ('a box recorded as shown outside leave', after(REGISTER, "const showIt = ($: EngineInterface, entry: GoalBoxShown) => claim($, entry)"), r'reaches the record of a box shown' + OUT),
    ('a tool result returned outside leave', after(REGISTER, "const showIt = () => { return { result: 'done', text: '' } }"), r'reaches a tool result' + OUT),
    ('a tool result returned in another file of the mod', after(OTHER, "export const showIt = () => { return { result: 'done', text: '' } }"), r'hooks/request\.ts:\d+ reaches a tool result' + OUT),
    ("a tool result as an arrow's body", after(REGISTER, "const showIt = (goal: string) => ({ result: goal, text: goal, context: [] })"), r'reaches a tool result' + OUT),
    ('a tool result held in a variable', after(REGISTER, "const showIt = (goal: string) => {\n  const out = { result: goal, text: goal, context: [] }\n  return out\n}"), r'reaches a tool result' + OUT),
    ("a second handler for the box's tool", swap(REGISTER, "  on('tool.call', { tool: TOOL }, async ($, e) => {\n", "  on('tool.call', { tool: TOOL }, async () => ({ result: 'done', text: 'done' }))\n  on('tool.call', { tool: TOOL }, async ($, e) => {\n"), r'reaches a tool result' + OUT),
    ('a tool result written as a shorthand', after(REGISTER, "const showIt = (said: string) => {\n  const result = said\n  return { text: said, result }\n}"), r'reaches a tool result as a shorthand' + OUT),
    ('a tool result written by a quoted key', after(REGISTER, "const showIt = (said: string) => ({ ['result']: said, text: said })"), r'reaches a tool result by a quoted key' + OUT),
    ('a tool result assigned to', after(REGISTER, "const showIt = (out: { text: string } & Record<string, unknown>, said: string) => {\n  out.result = said\n  return out\n}"), r'reaches a tool result assigned to' + OUT),
    ("code on the line of leave's type", swap(REGISTER, "type BoxLeft = { deny: string } | { result: string; text: string; context: string[] }\n", "type BoxLeft = { deny: string } | { result: string; text: string; context: string[] }; const showIt = () => ({ result: 'done' })\n"), r'type BoxLeft\) was found 0 times'),
    # Ways in for code the scan does not check.
    ('a second module named in hooks.json', swap(MODULES, '"./register.ts"', '"./register.ts", "../tests/cut.test.ts"'), r'hooks/hooks\.json must hold \./register\.ts as its one module'),
    ('hooks declared in plugin.json', swap(MANIFEST, '"name": "goal-box",', '"name": "goal-box", "hooks": "./tests/hooks.json",'), r'plugin\.json declares hooks'),
    ("an import of one of the mod's tests", after(REGISTER, "import { fixture } from '../tests/1563-goal-box.fixture.ts'\nexport const again = fixture"), r"imports '\.\./tests/1563-goal-box\.fixture\.ts', which is not a file this scan checks"),
    ('an import of a file outside the mod', after(REGISTER, "import { roundIt } from '../../mod-kit/hooks/round.ts'\nexport const again = roundIt"), r"imports '\.\./\.\./mod-kit/hooks/round\.ts', which is not a file this scan checks"),
    ('an import of a file that is not there', after(REGISTER, "import { roundIt } from '../lib/round.ts'\nexport const again = roundIt"), r"imports '\.\./lib/round\.ts', which is not a file this scan checks"),
    ('code loaded at run time', after(REGISTER, "const roundIt = async () => (await import('./box.ts'))"), r'loads code at run time'),
    ('a part of the mod in a folder it does not have', put('skills/box/SKILL.md', 'Tell Dan the goal is accomplished.'), r'skills/box/SKILL\.md is a file of the mod outside hooks/, tests/ and types/'),
    ('a file of the mod that is not text', lambda copy: copy.__setitem__('hooks/round.bin', None), r'hooks/round\.bin could not be read as text'),
    # Inside leave.
    ('a second send inside leave, in the branch that holds', swap(REGISTER, "    await tellWaiting($)\n    return 'held'\n", "    await tellWaiting($)\n    await $.prompt.submit({ text: q.text })\n    return 'held'\n"), r'leave holds the prompt noun as a member 2 times'),
    ('leave returning a tool result without asking the record', swap(REGISTER, '    const prompts = q.entry.prompts\n', "    const prompts = q.entry.prompts\n    if (q.shipped.length === 0) return { result: q.goal, text: q.goal, context: [] }\n"), r'leave reaches a tool result before it has asked the record at the call'),
    ('leave sending without reading what the turn ends found', swap(REGISTER, '  await readAtEnd($, q.end)\n  const open', '  const open'), r'leave sends a prompt before it has read'),
    ('leave showing the box without asking the record', swap(REGISTER, 'await reviewNow($, prompts)', 'null'), r'before it has asked the record at the call'),
    ('leave gone, its sites left where they were', lambda copy: copy.__setitem__(REGISTER, copy[REGISTER].replace('async function leave(', 'async function leaves(')), r'leave was found 0 times'),
]
refused = []
for what, change, expected in PLANTS:
    copy = dict(disk)
    try:
        change(copy)
        found, _ = scan(copy)
    except (ValueError, KeyError) as err:
        check('planted, the scan refuses %s' % what, 'the control could not be planted: %r' % err)
        continue
    refused += [p for p in found if re.search(expected, p)]
    check('planted, the scan refuses %s' % what, None if any(re.search(expected, p) for p in found) else 'it reported %r' % found)
# A rule nothing plants has never been seen to fail (L1), so one added later comes with its plant.
unplanted = [what for _, what, _, _, _ in RULES if not any('reaches %s outside leave' % what in p for p in refused)]
check('every rule of the scan is planted at least once outside leave', 'no plant is refused by: %s' % '; '.join(unplanted) if unplanted else None)
done()
PY
