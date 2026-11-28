#!/usr/bin/env bash
# What the Goal accomplished box reads before it asks about a steps card worked through, held to
# the code that writes it (claude-config#3864).
#
# The prompt (askAfterCard in payload/mods/goal-box/hooks/register.ts) reads three things it does
# not own: manual steps' record that a card emptied, manual steps' card, and the end of turn
# review's record of when a review was handed over. The goal box's own suite feeds it all three
# from stand ins, and manual steps' suite reads only its own writes, so a key or a field renamed on
# one side passed both and the prompt stopped, or went out untrue, with nothing said. This suite
# runs the real writer into the real reader for each, and fails when:
#
#   the state key manual steps writes its record or its card under is not the one the goal box reads;
#   the record manual steps' emptiedBy makes is not one the goal box's emptiedOf reads whole, with
#     the same time and the same count of steps done;
#   a card as manual steps makes and finishes it is not counted by the goal box's openStepsOf as
#     manual steps itself counts it: open while a step is open, none open once the last is recorded;
#   the time payload/hooks/lib/review-record.py prints for a hand over is not read by the goal
#     box's reviewRead as that moment in milliseconds.
#
# Seen to fail with each side changed in a scratch copy of the tree (L1).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not installed, so the mods' own code could not be run"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is not installed, so the review's record could not be written"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

node --experimental-strip-types --no-warnings --input-type=module - "$ROOT" <<'JS'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const root = process.argv[2]
let passed = 0
let failed = 0
const check = (what, problem) => {
  if (problem) {
    failed += 1
    console.log(`FAIL: ${what} (${problem})`)
  } else {
    passed += 1
    console.log(`PASS: ${what}`)
  }
}
const done = () => {
  console.log(`SUITE-RESULT passed=${passed} failed=${failed}`)
  process.exit(failed ? 1 : 0)
}
const textOf = rel => {
  try {
    return readFileSync(join(root, rel), 'utf8')
  } catch {
    return ''
  }
}
const load = async rel => {
  try {
    return await import(pathToFileURL(join(root, rel)).href)
  } catch (err) {
    return { unloaded: String(err && err.message ? err.message : err).split('\n')[0] }
  }
}
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)
const said = v => JSON.stringify(v)

const STEPS_REGISTER = 'payload/mods/manual-steps/hooks/register.tsx'
const BOX_REGISTER = 'payload/mods/goal-box/hooks/register.ts'
const steps = await load('payload/mods/manual-steps/hooks/card.ts')
const box = await load('payload/mods/goal-box/hooks/box.ts')
const review = await load('payload/mods/goal-box/hooks/review.ts')
for (const [name, mod, needs] of [
  ["manual steps' card.ts", steps, ['cardFrom', 'finish', 'nextStep', 'emptiedBy']],
  ["the goal box's box.ts", box, ['emptiedOf', 'openStepsOf']],
  ["the goal box's review.ts", review, ['reviewRead']],
]) {
  const missing = mod.unloaded ? [] : needs.filter(n => typeof mod[n] !== 'function')
  check(`${name} loads and still has what this suite runs`, mod.unloaded ? `it did not load: ${mod.unloaded}` : missing.length ? `no ${missing.join(', ')}` : null)
}
if (failed) done()

// ---- The state keys ----
// Each side names the key in a constant of its own, so the two are read out of the source and held
// to each other, and to the name manual steps is loaded under.
const refOf = (source, name) => {
  const m = new RegExp(`^const ${name} = \\{ plugin: '([^']+)', key: '([^']+)' \\} as const$`, 'm').exec(source)
  return m ? { plugin: m[1], key: m[2] } : null
}
const stepsSource = textOf(STEPS_REGISTER)
const boxSource = textOf(BOX_REGISTER)
let stepsName = ''
try {
  stepsName = JSON.parse(textOf('payload/mods/manual-steps/.claude-plugin/plugin.json')).name
} catch {
  stepsName = ''
}
check('manual steps says what name it is loaded under', typeof stepsName === 'string' && stepsName ? null : 'its plugin.json names none')
const KEYS = [
  ['the record that a card emptied', 'emptiedRef', '$.state.set(emptiedRef, emptiedBy(', 'stepsEmptiedRef', 'emptiedOf((await $.state.get(stepsEmptiedRef as never)).value'],
  ['the card', 'cardRef', '$.state.set(cardRef, ', 'stepsCardRef', 'openStepsOf((await $.state.get(stepsCardRef as never)).value'],
]
for (const [what, writer, writes, reader, reads] of KEYS) {
  const w = refOf(stepsSource, writer)
  const r = refOf(boxSource, reader)
  check(`manual steps writes ${what} under a key this suite can read`, w && stepsSource.includes(writes) ? null : `${writer}, or its write ${said(writes)}, is not in ${STEPS_REGISTER} as this suite reads it`)
  check(`the goal box reads ${what} under a key this suite can read`, r && boxSource.includes(reads) ? null : `${reader}, or its read ${said(reads)}, is not in ${BOX_REGISTER} as this suite reads it`)
  if (!w || !r) continue
  check(`the goal box reads ${what} under the key manual steps writes it under`, same(w, r) ? null : `manual steps writes ${said(w)} and the goal box reads ${said(r)}`)
  check(`and that key is manual steps' own`, w.plugin === stepsName ? null : `the key is under ${said(w.plugin)} and manual steps is loaded as ${said(stepsName)}`)
}

// ---- The record that a card emptied, and the card ----
const AT = 1_800_000_060_000
const through = value => JSON.parse(JSON.stringify(value))
const pinned = () =>
  steps.cardFrom({
    heading: 'Send the result',
    steps: [
      { title: 'Send the draft', url: 'https://a.example', checked: 'not-done' },
      { title: 'Run the command', location: 'Terminal, the claude-config window', checked: 'not-done' },
    ],
  })
const made = pinned()
check('manual steps makes a card of two open steps', made.card && made.card.steps.length === 2 ? null : `it answered ${said(made)}`)
if (!made.card) done()

// The card at each moment, as manual steps' own verdicts leave it, with how many steps manual steps
// itself holds open: nextStep is its test for "every step is finished".
const record = (card, n, verdict) => {
  const r = steps.finish(card, n, verdict, AT)
  return r.card ? r.card : { refused: r.refusal }
}
const one = record(made.card, 1, 'checked')
const reopened = record(made.card, 1, 'not-done')
const both = one.refused ? one : record(one, 2, 'per-you')
const offOne = record(made.card, 1, 'withdrawn')
const offBoth = offOne.refused ? offOne : record(offOne, 2, 'withdrawn')
const MOMENTS = [
  ['just pinned', made.card, 2],
  ['with its first step recorded', one, 1],
  ['with its first step checked and found not done', reopened, 2],
  ['with both steps recorded', both, 0],
  ['with both steps taken off undone', offBoth, 0],
]
for (const [when, card, open] of MOMENTS) {
  if (card.refused) {
    check(`manual steps records the card ${when}`, `it refused: ${card.refused}`)
    continue
  }
  const isDone = steps.nextStep(card) === undefined
  check(`manual steps holds the card ${when} as ${open ? 'still open' : 'finished'}`, isDone === (open === 0) ? null : `nextStep answered ${said(steps.nextStep(card))}`)
  const counted = box.openStepsOf(through(card))
  check(`the goal box counts ${open} open on the card ${when}`, counted === open ? null : `openStepsOf answered ${said(counted)}`)
}
check('the goal box counts none open once manual steps has taken the card away', box.openStepsOf(null) === 0 ? null : `openStepsOf(null) answered ${said(box.openStepsOf(null))}`)

for (const [what, card, doneHere] of [['a card with both steps recorded', both, 2], ['a card with both steps taken off undone', offBoth, 0]]) {
  if (card.refused) continue
  const written = steps.emptiedBy(card, 's1', AT)
  check(`manual steps records ${what} as emptied at that moment with ${doneHere} done`, same(written, { at: AT, done: doneHere }) ? null : `emptiedBy answered ${said(written)}`)
  const read = box.emptiedOf(through(written))
  check(`the goal box reads that record whole: the same time, the same count, and no field left unread`, same(read, written) ? null : `emptiedOf answered ${said(read)} for ${said(written)}`)
}

// ---- When a review was handed over ----
// The real record, written and read by its one owner beside a throwaway transcript, then put to
// the goal box's reader as the mod's own run would hand it over.
const RECORD = join(root, 'payload/hooks/lib/review-record.py')
const scratch = mkdtempSync(join(tmpdir(), 'goal-box-card-prompt-records-'))
try {
  const transcript = join(scratch, 's1.jsonl')
  const line = content => `${JSON.stringify({ type: 'user', promptId: 'p1', isSidechain: false, message: { role: 'user', content } })}\n`
  writeFileSync(transcript, line('do the thing') + line([{ type: 'tool_result', tool_use_id: 't1', content: 'ok' }]))
  const run = (...words) => spawnSync('python3', ['-I', '-B', RECORD, ...words, '--transcript', transcript], { encoding: 'utf8', timeout: 30_000 })
  const before = Date.now()
  const handed = run('handed', '--label', 'SESSION REFLECTION')
  const after = Date.now()
  check('the real record takes a hand over', handed.status === 0 ? null : `handed exited ${handed.status}: ${String(handed.stderr).trim().slice(-200)}`)
  const state = run('state')
  const read = review.reviewRead({ exitCode: state.status ?? -1, stdout: state.stdout ?? '', stderr: state.stderr ?? '' })
  check('the goal box reads the real record as handed over', read.state === 'handed' ? null : `reviewRead answered ${said(read)}`)
  // A second either side: the record's clock and this one are read a moment apart.
  const isThen = Number.isInteger(read.handedAt) && read.handedAt >= before - 1_000 && read.handedAt <= after + 1_000
  check('and reads when it was handed over as that moment, in milliseconds', isThen ? null : `handedAt is ${said(read.handedAt)}, and the hand over was made between ${before} and ${after}`)
} finally {
  rmSync(scratch, { recursive: true, force: true })
}
done()
JS
