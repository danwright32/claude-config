import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import type { SlackAlertChoice } from '../types/index.d.ts'
import { CHOICE_MS, CHOOSE_DESCRIPTION, MORNING_OPTIONS, REASK_MS, asleepRefusal, choicesOf, isOverdue, morningLines, morningQuestion, morningReaches, reaskDue, reaskLine, sleepEndOf } from '../hooks/night.ts'

// Wording chosen in sleep mode (#2628): the pure rules, apart from the session.

const HOUR = 60 * 60_000

const choice = (over: Partial<SlackAlertChoice> = {}): SlackAlertChoice => ({
  id: 't1',
  at: 0,
  file: '/w/app/lib/alert.ts',
  added: ['Deploy ${id} failed on production'],
  removed: [],
  keys: ['wording:abc'],
  rendered: 'Deploy 4182 failed on production',
  session: 's1',
  ...over,
})

test('the morning lines ask this session its own choices and an ended session\'s, and name an expired one once', () => {
  const mine = choice()
  const other = choice({ id: 't2', session: 's2' })
  const orphan = choice({ id: 't3', session: null })
  const expired = choice({ id: 't4', session: 's2', expired: 5 })
  const lines = morningLines([mine, other, orphan, expired], 's1', [])
  expect(lines.length).toBe(3)
  expect(lines.join('\n')).toContain('slack-alert-guard:chosen:t1')
  expect(lines.join('\n')).toContain('slack-alert-guard:chosen:t3')
  expect(lines.join('\n')).not.toContain('chosen:t2"')
  expect(lines.join('\n')).toContain('expired unanswered')
  expect(morningLines([expired], 's1', ['t4'])).toEqual([])
})

test('one choice per call, oldest first, and overdue only once its time has passed unanswered', () => {
  const a = choice({ id: 'a', at: 5, keys: ['k1'] })
  expect(choicesOf([a, { ...a, keys: ['k2'] }, choice({ id: 'b', at: 1 })]).map(c => c.id)).toEqual(['b', 'a'])
  expect(isOverdue(choice({ at: 0 }), CHOICE_MS - 1)).toBe(false)
  expect(isOverdue(choice({ at: 0 }), CHOICE_MS)).toBe(true)
  expect(isOverdue(choice({ at: 0, expired: 1 }), CHOICE_MS * 2)).toBe(false)
})

// #2837: the guard holds only a file that posts by itself, so the morning question names that file
// and the message chosen for it, and nothing else.
test('the morning question names the file that posts the chosen wording, and the message itself (#2837)', () => {
  const q = morningQuestion(choice())
  expect(q).toContain('defined in /w/app/lib/alert.ts. Approve it?')
  expect(q).toContain(choice().rendered)
  expect(q).not.toContain('not yet wired')
  // #2993: with its project, when that is known.
  expect(morningQuestion(choice(), 'danwright32/app')).toContain('defined in /w/app/lib/alert.ts in danwright32/app. Approve it?')
})

// #2993: put to Dan again by any session once still unapproved two hours after the sleep it was
// chosen in ended, once per session, never once he has approved or changed it.
test('a choice is asked again two hours after the sleep it was chosen in ended, once in each session, unless changed or asked here already', () => {
  const at = 10 * HOUR
  const c = choice({ at })
  // The first end after the choice decides, never an earlier night's or a later one's.
  expect(sleepEndOf(c, [HOUR, at + 6 * HOUR, at + 30 * HOUR])).toBe(at + 6 * HOUR)
  // No end readable, or none after it: none, and the wait counts from the choice, so it is asked early rather than never.
  for (const ends of [null, [], [HOUR]]) expect(sleepEndOf(c, ends)).toBeNull()
  expect(reaskDue([c], at + REASK_MS + 1, null, [], new Set()).map(x => x.id)).toEqual(['t1'])
  const ends = [at + 6 * HOUR]
  const due = (cs: SlackAlertChoice[], now: number, done: string[] = [], morning = new Set<string>()) => reaskDue(cs, now, ends, done, morning).map(x => x.id)
  expect(due([c], at + 6 * HOUR + REASK_MS)).toEqual([])
  expect(due([c], at + 6 * HOUR + REASK_MS + 1)).toEqual(['t1'])
  expect(due([c], at + 9 * HOUR, ['t1'])).toEqual([])
  expect(due([c], at + 9 * HOUR, [], new Set(['t1']))).toEqual([])
  expect(due([choice({ at, rejected: at + 7 * HOUR })], at + 9 * HOUR)).toEqual([])
  // An expired one is still unapproved, so it is asked too.
  expect(due([choice({ at, expired: at + 8 * HOUR })], at + 9 * HOUR)).toEqual(['t1'])
  const line = reaskLine(c, 'danwright32/app', true)
  for (const part of ['danwright32/app', c.file, c.rendered, 'slack-alert-guard:chosen:t1', 'after sleep mode ended']) expect(line).toContain(part)
  expect(reaskLine(c, null, true)).not.toContain(' in null')
  // When no sleep end could be read, the line claims only what was measured: the time since it was chosen.
  const unread = reaskLine(c, null, false)
  expect(unread).not.toContain('sleep mode ended')
  expect(unread).toContain('after it was chosen')
})

test('the morning lines reach a session\'s own choices, an ended session\'s, and every expired one, and nothing else', () => {
  expect(morningReaches(choice(), 's1')).toBe(true)
  expect(morningReaches(choice({ session: null }), 's1')).toBe(true)
  expect(morningReaches(choice({ session: 's2', expired: 1 }), 's1')).toBe(true)
  expect(morningReaches(choice({ session: 's2' }), 's1')).toBe(false)
})

// #3030: Dan, 2026-11-16: "I'd actually prefer it didn't hold merges anywhere. It's more of a nice
// to have but it shouldn't hold up progress." A choice holds no merge, so nothing the guard says about
// one may claim a merge waits on it (L11): not the tool, the refusal asleep, the morning question and
// its answers, nor the lines a session is told.
test('nothing said about wording chosen overnight claims a merge waits on it (#3030)', () => {
  const said = [
    CHOOSE_DESCRIPTION,
    asleepRefusal('Blocked: this edit changes Slack alert wording', 't1'),
    morningQuestion(choice(), 'danwright32/app'),
    ...MORNING_OPTIONS.map(o => `${o.label} ${o.description}`),
    ...morningLines([choice(), choice({ id: 't2', session: null, expired: 5 })], 's1', []),
    reaskLine(choice(), 'danwright32/app', true),
  ]
  expect(said.length).toBe(8)
  for (const s of said) expect({ s, merge: /\bmerge/i.test(s), held: /\b(still|stays|keeps it) held\b/i.test(s) }).toEqual({ s, merge: false, held: false })
})
