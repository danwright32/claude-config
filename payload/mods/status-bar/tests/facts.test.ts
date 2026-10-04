import { describe, expect, test } from 'claude-code/testing'
import { checksOf, compactDue, lookParts, span, unpushedOf } from '../hooks/facts.ts'

const MIN = 60_000
const HOUR = 60 * MIN

describe('span', () => {
  test('reads as minutes, hours and minutes, or days and hours', () => {
    expect(span(30_000)).toBe('<1m')
    expect(span(14 * MIN)).toBe('14m')
    expect(span(2 * HOUR + 14 * MIN + 59_000)).toBe('2h 14m')
    expect(span(27 * HOUR)).toBe('1d 3h')
  })
  test('a negative span is no time at all, never a minus sign', () => {
    expect(span(-5 * MIN)).toBe('<1m')
  })
})

describe('checksOf', () => {
  test('a failing check wins over a running one: it is the more urgent', () => {
    expect(checksOf([{ status: 'IN_PROGRESS' }, { status: 'COMPLETED', conclusion: 'FAILURE' }])).toBe('failing')
    expect(checksOf([{ state: 'ERROR' }])).toBe('failing')
    expect(checksOf([{ status: 'COMPLETED', conclusion: 'TIMED_OUT' }])).toBe('failing')
  })
  test('anything not finished is running', () => {
    expect(checksOf([{ status: 'QUEUED' }, { status: 'COMPLETED', conclusion: 'SUCCESS' }])).toBe('running')
    expect(checksOf([{ state: 'PENDING' }])).toBe('running')
  })
  test('all finished well, skipped or neutral is passing, and no checks at all is nothing to show', () => {
    expect(checksOf([{ status: 'COMPLETED', conclusion: 'SUCCESS' }, { status: 'COMPLETED', conclusion: 'SKIPPED' }, { state: 'SUCCESS' }])).toBe('passing')
    expect(checksOf([])).toBe('none')
  })
})

describe('unpushedOf', () => {
  test('reads git rev-list --count', () => {
    expect(unpushedOf('3\n')).toBe(3)
    expect(unpushedOf('0\n')).toBe(0)
  })
  test('anything that is not a count is not a reading', () => {
    expect(unpushedOf('fatal: x')).toBeUndefined()
    expect(unpushedOf('')).toBeUndefined()
  })
})

const texts = (parts: ReturnType<typeof lookParts>) => parts.map(p => ('text' in p ? p.text : `[${p.label}]`)).join('')
const now = 100 * HOUR

describe('lookParts', () => {
  test('nothing needing a look and no mode: no line at all', () => {
    expect(lookParts({ modes: [], pr: null, jobs: [], unpushed: 0, now })).toEqual([])
  })
  test('most urgent first: mode, PR, running jobs, kept jobs, unpushed commits', () => {
    const parts = lookParts({
      modes: ['NO BUILD'],
      pr: { number: 636, checks: 'failing', readAt: now, isStale: false },
      jobs: [
        { label: 'dev server', runMs: 2 * HOUR + 14 * MIN, kept: true, stuck: false },
        { label: 'npm test', runMs: MIN, kept: false, stuck: false },
      ],
      unpushed: 2,
      now,
    })
    expect(texts(parts)).toBe('NO BUILD | PR #636 checks failing | 1 job running | dev server kept 2h 14m | 2 unpushed commits')
  })
  test('the mode is bold amber, the items amber, the separators dim', () => {
    const parts = lookParts({ modes: ['AWAY'], pr: null, jobs: [], unpushed: 1, now })
    expect(parts).toEqual([
      { text: 'AWAY', color: 'warning', bold: true },
      { text: ' | ', dim: true },
      { text: '1 unpushed commit', color: 'warning' },
    ])
  })
  test('two modes at once (no build while away) both lead, each bold, divided like the items', () => {
    const parts = lookParts({ modes: ['NO BUILD', 'AWAY'], pr: null, jobs: [], unpushed: 1, now })
    expect(parts).toEqual([
      { text: 'NO BUILD', color: 'warning', bold: true },
      { text: ' | ', dim: true },
      { text: 'AWAY', color: 'warning', bold: true },
      { text: ' | ', dim: true },
      { text: '1 unpushed commit', color: 'warning' },
    ])
  })
  test('a mode alone still makes a line: the band shows while a mode is on', () => {
    expect(texts(lookParts({ modes: ['WINDING DOWN'], pr: null, jobs: [], unpushed: 0, now }))).toBe('WINDING DOWN')
  })
  test('passing checks need no look; running ones are shown', () => {
    expect(lookParts({ modes: [], pr: { number: 9, checks: 'passing', readAt: now, isStale: false }, jobs: [], unpushed: 0, now })).toEqual([])
    expect(texts(lookParts({ modes: [], pr: { number: 9, checks: 'running', readAt: now, isStale: false }, jobs: [], unpushed: 0, now }))).toBe('PR #9 checks running')
  })
  test('a PR whose last refresh failed shows what was last read, with its age, never blank (L682)', () => {
    const pr = { number: 636, checks: 'running' as const, readAt: now - 12 * MIN, isStale: true }
    expect(texts(lookParts({ modes: [], pr, jobs: [], unpushed: 0, now }))).toBe('PR #636 checks running, as of 12m ago')
  })
  test('a stale PR that last read as passing stays hidden: only an item that needed a look is kept', () => {
    const pr = { number: 7, checks: 'passing' as const, readAt: now - 3 * MIN, isStale: true }
    expect(lookParts({ modes: [], pr, jobs: [], unpushed: 0, now })).toEqual([])
  })
  test('jobs counted, and every kept job named with its run time', () => {
    const jobs = [
      { label: 'a', runMs: MIN, kept: false, stuck: false },
      { label: 'b', runMs: MIN, kept: false, stuck: true },
      { label: 'dev server', runMs: 30 * MIN, kept: true, stuck: false },
      { label: 'watcher', runMs: 3 * HOUR, kept: true, stuck: false },
    ]
    expect(texts(lookParts({ modes: [], pr: null, jobs, unpushed: 0, now }))).toBe('2 jobs running | dev server kept 30m | watcher kept 3h 0m')
  })
})

describe('compactDue', () => {
  test('context above 70% shows the Compact row', () => {
    expect(compactDue({ contextPercent: 71, cacheExpiresAt: null, now })).toBe(true)
    expect(compactDue({ contextPercent: 70, cacheExpiresAt: null, now })).toBe(false)
  })
  test('the cache within 5 minutes of going cold shows it, and once cold it is gone', () => {
    expect(compactDue({ contextPercent: 10, cacheExpiresAt: now + 5 * MIN, now })).toBe(true)
    expect(compactDue({ contextPercent: 10, cacheExpiresAt: now + 6 * MIN, now })).toBe(false)
    expect(compactDue({ contextPercent: 10, cacheExpiresAt: now, now })).toBe(false)
  })
  test('no context reading yet and no cache is no row', () => {
    expect(compactDue({ contextPercent: undefined, cacheExpiresAt: null, now })).toBe(false)
  })
})
