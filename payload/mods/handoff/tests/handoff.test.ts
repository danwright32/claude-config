import { describe, expect, test } from 'claude-code/testing'
import { ageOf, bandLines, changesOf, keyOf, namesIn, readingOf } from '../hooks/handoff.ts'
import type { Reading } from '../hooks/handoff.ts'

const MIN = 60_000
const HOUR = 60 * MIN

describe('namesIn', () => {
  test('finds every issue or PR number and every milestone, once each, in the order written', () => {
    expect(namesIn('Continue milestone 18. Read #613 to #621, the latest comment on #615, PR #634 and #615 again.')).toEqual([
      { kind: 'milestone', number: 18 },
      { kind: 'number', number: 613 },
      { kind: 'number', number: 621 },
      { kind: 'number', number: 615 },
      { kind: 'number', number: 634 },
    ])
  })
  test('a hex colour or an anchor is not an issue number', () => {
    expect(namesIn('Use #e5a50a for amber; see README#mods and #12.')).toEqual([{ kind: 'number', number: 12 }])
  })
  test('nothing named, nothing to check', () => {
    expect(namesIn('Pick up where we left off.')).toEqual([])
  })
})

describe('ageOf', () => {
  test('reads as minutes, hours or days ago', () => {
    expect(ageOf(30_000)).toBe('just now')
    expect(ageOf(12 * MIN)).toBe('12m ago')
    expect(ageOf(3 * HOUR + 40 * MIN)).toBe('3h ago')
    expect(ageOf(50 * HOUR)).toBe('2d ago')
  })
  test('a time in the future (a clock moved back) is just now, never a minus sign', () => {
    expect(ageOf(-5 * MIN)).toBe('just now')
  })
})

describe('readingOf', () => {
  test("reads gh's issues API for an issue, a PR, a merged PR and a milestone", () => {
    expect(readingOf({ kind: 'number', number: 615 }, { state: 'open', updated_at: '2026-10-04T10:00:00Z' })).toEqual({ kind: 'issue', number: 615, state: 'open', updatedAt: '2026-10-04T10:00:00Z' })
    expect(readingOf({ kind: 'number', number: 634 }, { state: 'closed', updated_at: 'u', pull_request: { merged_at: '2026-10-04T11:00:00Z' } })).toEqual({ kind: 'pr', number: 634, state: 'merged', updatedAt: 'u' })
    expect(readingOf({ kind: 'number', number: 634 }, { state: 'closed', updated_at: 'u', pull_request: { merged_at: null } })).toEqual({ kind: 'pr', number: 634, state: 'closed', updatedAt: 'u' })
    expect(readingOf({ kind: 'milestone', number: 18 }, { state: 'open', updated_at: 'u' })).toEqual({ kind: 'milestone', number: 18, state: 'open', updatedAt: 'u' })
  })
  test('an answer without a state is not a reading: it says what it lacked', () => {
    expect(readingOf({ kind: 'number', number: 1 }, { message: 'Not Found' })).toEqual({ kind: 'number', number: 1, error: 'gh answered without a state' })
  })
})

const issue = (number: number, state: 'open' | 'closed' | 'merged', updatedAt: string, kind: 'issue' | 'pr' = 'issue'): Reading => ({ kind, number, state, updatedAt })

describe('changesOf', () => {
  test('one line per thing that closed, merged or changed since, in the order the handoff names them', () => {
    const then = [issue(615, 'open', 'a'), issue(634, 'open', 'a', 'pr'), issue(612, 'open', 'a'), issue(600, 'open', 'a')]
    const now = [issue(615, 'closed', 'b'), issue(634, 'merged', 'b', 'pr'), issue(612, 'open', 'b'), issue(600, 'open', 'a')]
    expect(changesOf(then, now)).toEqual(['changed since: #615 closed', 'changed since: PR #634 merged', 'changed since: #612 updated'])
  })
  test('a milestone is named as one', () => {
    const then: Reading[] = [{ kind: 'milestone', number: 18, state: 'open', updatedAt: 'a' }]
    const now: Reading[] = [{ kind: 'milestone', number: 18, state: 'closed', updatedAt: 'b' }]
    expect(changesOf(then, now)).toEqual(['changed since: milestone 18 closed'])
  })
  test('a thing that could not be read now is said so, never left out as unchanged (L61)', () => {
    expect(changesOf([issue(615, 'open', 'a')], [{ kind: 'number', number: 615, error: 'gh: HTTP 502' }])).toEqual(['#615 could not be checked: gh: HTTP 502'])
  })
  test('a thing with no reading from when it was saved is judged by its state now', () => {
    const then: Reading[] = [{ kind: 'number', number: 615, error: 'offline' }, { kind: 'number', number: 616, error: 'offline' }]
    expect(changesOf(then, [issue(615, 'closed', 'b'), issue(616, 'open', 'b')])).toEqual(['changed since: #615 closed'])
  })
  test('nothing changed, no lines', () => {
    expect(changesOf([issue(615, 'open', 'a')], [issue(615, 'open', 'a')])).toEqual([])
  })
})

describe('keyOf', () => {
  test('one folder name per repository root, safe as a file name', () => {
    expect(keyOf('/Users/x/Apps/claude-config')).toBe('Users_x_Apps_claude-config')
    expect(keyOf('/Users/x/My Docs/Dan’s app')).toBe('Users_x_My_Docs_Dan_s_app')
  })
})

describe('bandLines', () => {
  test('the amber lead and its title on one line, each change grey and indented under it, then Use and Dismiss', () => {
    expect(bandLines({ age: '3h ago', title: 'Continue milestone 18 design rounds', changes: ['changed since: #615 closed'] })).toEqual([
      [{ text: 'Handoff saved 3h ago: ', color: 'warning', bold: true }, { text: 'Continue milestone 18 design rounds' }],
      [{ text: 'changed since: #615 closed', dim: true, indent: 3 }],
      [{ button: 'use', label: 'Use' }, { text: '  ' }, { button: 'dismiss', label: 'Dismiss' }],
    ])
  })
})
