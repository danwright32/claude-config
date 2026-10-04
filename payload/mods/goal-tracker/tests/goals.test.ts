import { describe, expect, test } from 'claude-code/testing'
import { empty, type Progress } from '../hooks/progress.ts'
import { firstWords, permissionFor, projectOf, rowsOf } from '../hooks/goals.ts'

const MIN = 60_000
const rec = (id: string, repoRoot: string | null, progress: Progress | undefined, cwd = '/Users/dan/x') => ({ sessionId: id, cwd, repoRoot, extra: progress ? { progress } : {} })
const at = (p: Partial<Progress>): Progress => ({ ...empty(0), ...p })

describe('a session in the goals pane', () => {
  test('its project is its repository folder, else the folder it started in', () => {
    expect(projectOf({ repoRoot: '/Users/dan/Apps/Ovation', cwd: '/Users/dan/Apps/Ovation/src' })).toBe('Ovation')
    expect(projectOf({ repoRoot: null, cwd: '/Users/dan/notes/' })).toBe('notes')
  })

  test('its goal is the /goal condition, else its first request', () => {
    const [withGoal, withRequest] = rowsOf([rec('a', '/r/A', at({ goal: 'all tests pass', request: 'fix the tests' })), rec('b', '/r/B', at({ request: 'fix the tests' }))], 0)
    expect(withGoal?.goal).toBe('all tests pass')
    expect(withRequest?.goal).toBe('fix the tests')
  })

  test('the five states are ordered waiting, failed, stalled, working, done', () => {
    const now = 30 * MIN
    const rows = rowsOf(
      [
        rec('done', '/r/Downbeat', at({ total: 4, done: 4, lastActivityAt: now })),
        rec('working', '/r/claude-config', at({ total: 7, done: 4, current: 'Writing the design doc', lastActivityAt: now })),
        rec('stalled', '/r/PostRoll', at({ total: 6, done: 2, lastActivityAt: now - 14 * MIN, lastStepAt: 0 })),
        rec('failed', '/r/Overture', at({ total: 3, done: 1, failed: 'Exit code 1', lastActivityAt: now })),
        rec('waiting', '/r/Ovation', at({ total: 5, done: 3, waiting: { question: 'Which date format for the CSV?', since: now, kind: 'question' } })),
      ],
      now,
    )
    expect(rows.map(r => r.state)).toEqual(['waiting on you', 'failed', 'stalled', 'working', 'done'])
  })

  test('each state carries its own detail, as the design round drew it', () => {
    const now = 72 * MIN
    const rows = rowsOf(
      [
        rec('w', '/r/Ovation', at({ total: 5, done: 3, waiting: { question: 'Which date format for the CSV?', since: now } })),
        rec('f', '/r/Overture', at({ total: 3, done: 1, failed: 'Exit code 1', lastActivityAt: now })),
        rec('s', '/r/PostRoll', at({ total: 6, done: 2, lastActivityAt: now - 14 * MIN, lastStepAt: 0 })),
        rec('k', '/r/claude-config', at({ total: 7, done: 4, current: 'Writing the design doc', lastActivityAt: now })),
        rec('d', '/r/Downbeat', at({ total: 4, done: 4, lastActivityAt: now })),
      ],
      now,
    )
    expect(rows.map(r => r.sentence)).toEqual([
      ', 3 of 5 steps, 1h 12m. "Which date format for the CSV?"',
      ', 1 of 3 steps, 1h 12m. Exit code 1 (3 failed calls in a row)',
      ', 2 of 6 steps, 1h 12m. nothing for 14m',
      ', 4 of 7 steps, 1h 12m. Writing the design doc',
      ', 4 of 4 steps, 1h 12m',
    ])
  })

  test('a session waiting on a permission names what it is for', () => {
    const [row] = rowsOf([rec('p', '/r/A', at({ waiting: { question: 'Run the test suite', since: 0, kind: 'permission' } }))], 0)
    expect(row?.state).toBe('waiting on you')
    expect(row?.sentence).toBe(', 0m. needs a permission: Run the test suite')
  })

  test('a session with no task list says no steps rather than 0 of 0', () => {
    const [row] = rowsOf([rec('a', '/r/A', at({ current: null }))], 5 * MIN)
    expect(row?.sentence).toBe(', 5m')
  })

  test('a session that records no progress is left out, never shown as a guess', () => {
    expect(rowsOf([rec('a', '/r/A', undefined), rec('b', '/r/B', at({}))], 0).map(r => r.project)).toEqual(['B'])
  })

  test('a progress record of the wrong shape is left out', () => {
    expect(rowsOf([{ sessionId: 'a', cwd: '/x', repoRoot: null, extra: { progress: { done: 'lots' } } }], 0)).toEqual([])
  })

  // Lessons review of 4cb9221: one malformed record from another session never breaks the pane.
  test('a record whose text fields are not text is left out, and the others still draw', () => {
    const bad = [{ goal: 42 }, { request: ['x'] }, { failed: {} }, { current: 7 }, { waiting: { question: null, since: 0 } }, { waiting: 'yes' }]
    const rows = rowsOf([...bad.map((b, i) => rec(`bad${i}`, `/r/Bad${i}`, at(b as Partial<Progress>))), rec('ok', '/r/Fine', at({ request: 'fine' }))], 0)
    expect(rows.map(r => r.project)).toEqual(['Fine'])
  })

  test('within a state the session that started first comes first', () => {
    const rows = rowsOf([rec('late', '/r/Late', at({ startedAt: 5 * MIN, lastActivityAt: 6 * MIN })), rec('early', '/r/Early', at({ startedAt: 0, lastActivityAt: 6 * MIN }))], 6 * MIN)
    expect(rows.map(r => r.project)).toEqual(['Early', 'Late'])
  })

  test('a long goal is cut to one line', () => {
    const [row] = rowsOf([rec('a', '/r/A', at({ goal: 'x'.repeat(300) }))], 0)
    expect(row?.goal?.length).toBe(80)
    expect(row?.goal?.endsWith('...')).toBe(true)
  })
})

describe('the first request, cut to a few words', () => {
  test('a short request is kept whole', () => {
    expect(firstWords('Fix the invoice export')).toBe('Fix the invoice export')
  })
  test('a long request keeps its first six words', () => {
    expect(firstWords('Please look at why the Gmail send keeps failing on large attachments')).toBe('Please look at why the Gmail...')
  })
  test('lines and spacing are collapsed', () => {
    expect(firstWords('  fix\n\nthe   tests ')).toBe('fix the tests')
  })
})

describe('what a permission is for', () => {
  test("a Bash call is named by its description, else only as a Bash command", () => {
    expect(permissionFor('Bash', { command: 'npm test', description: 'Run the test suite' })).toBe('Run the test suite')
    expect(permissionFor('Bash', { command: 'npm test' })).toBe('a Bash command')
  })
  test('a file tool is named by the file', () => {
    expect(permissionFor('Edit', { file_path: '/Users/dan/Apps/x/src/app.ts' })).toBe('Edit app.ts')
  })
  test('anything else is named by its tool', () => {
    expect(permissionFor('WebFetch', { url: 'https://example.com' })).toBe('WebFetch')
    expect(permissionFor('mcp__x__y', null)).toBe('mcp__x__y')
  })
  test('a command is never copied, since it can carry a secret into the shared registry and the notification', () => {
    expect(permissionFor('Bash', { command: 'curl -H "Authorization: Bearer sk-live-123" https://x' })).toBe('a Bash command')
  })
})
