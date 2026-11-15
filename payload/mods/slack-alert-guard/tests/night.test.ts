import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import type { SlackAlertChoice } from '../types/index.d.ts'
import { CHOICE_MS, REASK_MS, carried, choicesOf, isOverdue, mergeOf, morningLines, morningQuestion, morningReaches, reaskDue, reaskLine, sleepEndOf } from '../hooks/night.ts'

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

test('a diff carries chosen wording when an added line holds a fixed part of it, never a removed or context line', () => {
  const c = choice()
  expect(carried('+++ b/lib/alert.ts\n+  text: `Deploy ${id} failed on production`,\n', [c]).length).toBe(1)
  // Filled in differently, the fixed words still hold the merge.
  expect(carried('+  text: "Deploy " + id + " failed on production",\n', [c]).length).toBe(1)
  expect(carried('-  text: `Deploy ${id} failed on production`,\n   context line\n', [c]).length).toBe(0)
  expect(carried('+  text: `Deploy ${id} did not finish`,\n', [c]).length).toBe(0)
  // A reword is judged by what it adds; a chosen removal by the lines the diff takes away.
  const reword = choice({ removed: ['Deploy ${id} failed'] })
  expect(carried('-  text: `Deploy ${id} failed`,\n+  text: `Deploy ${id} did not finish`,\n', [reword]).length).toBe(0)
  const removal = choice({ added: [], removed: ['Backup is late again'] })
  expect(carried('-  text: "Backup is late again",\n', [removal]).length).toBe(1)
  expect(carried('+  text: "Backup is late again",\n', [removal]).length).toBe(0)
})

test('the merge a gh command makes is read from gh pr merge and gh api, and anything unreadable is said so', () => {
  const pr = (positionals: string[], named?: string | null, unreadable = false) => ({ sub: 'pr', act: 'merge', flags: [], positionals, named, unreadable })
  expect(mergeOf(pr(['12']))).toEqual({ selector: ['12'], repo: undefined })
  expect(mergeOf(pr([], 'o/r'))).toEqual({ selector: [], repo: 'o/r' })
  expect(mergeOf(pr(['12'], null))).toEqual({ unreadable: true })
  expect(mergeOf(pr(['12'], undefined, true))).toEqual({ unreadable: true })
  expect(mergeOf({ sub: 'pr', act: 'view', positionals: ['12'], unreadable: false })).toBeUndefined()
  const api = (endpoint: string | undefined, method = 'PUT', repo: string | null | undefined = 'o/r', query: string | null = null) => ({ sub: 'api', act: '', positionals: [], unreadable: false, api: { method, endpoint, repo, query } })
  expect(mergeOf(api('repos/o/r/pulls/7/merge'))).toEqual({ selector: ['7'], repo: 'o/r' })
  // Written as a whole address, or with a query after it, it is the same merge.
  expect(mergeOf(api('https://api.github.com/repos/o/r/pulls/7/merge'))).toEqual({ selector: ['7'], repo: 'o/r' })
  expect(mergeOf(api('repos/o/r/pulls/7/merge?x=1'))).toEqual({ selector: ['7'], repo: 'o/r' })
  // One whose repository the reader leaves unnamed cannot be read for its diff.
  expect(mergeOf({ sub: 'api', act: '', positionals: [], unreadable: false, api: { method: 'PUT', endpoint: 'https://api.github.com/repos/o/r/pulls/7/merge', query: null } })).toEqual({ unreadable: true })
  // A GET there only asks whether it merged.
  expect(mergeOf(api('repos/o/r/pulls/7/merge', 'GET'))).toBeUndefined()
  expect(mergeOf(api('repos/o/r/pulls/7'))).toBeUndefined()
  expect(mergeOf(api(undefined))).toEqual({ unreadable: true })
  expect(mergeOf(api(undefined, 'GET'))).toBeUndefined()
  // GraphQL: a mergePullRequest mutation, or a document that cannot be read, is held; a query is not.
  expect(mergeOf(api('graphql', 'POST', undefined, 'mutation { mergePullRequest(input: {pullRequestId: "x"}) { clientMutationId } }'))).toEqual({ unreadable: true })
  expect(mergeOf(api('graphql', 'POST', undefined, null))).toEqual({ unreadable: true })
  expect(mergeOf(api('graphql', 'POST', undefined, 'query { viewer { login } }'))).toBeUndefined()
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
