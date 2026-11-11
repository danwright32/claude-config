import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import type { SlackAlertChoice } from '../types/index.d.ts'
import { CHOICE_MS, carried, choicesOf, isOverdue, mergeOf, morningLines } from '../hooks/night.ts'

// Wording chosen in sleep mode (#2628): the pure rules, apart from the session.

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
