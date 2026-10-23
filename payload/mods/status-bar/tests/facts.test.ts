import { describe, expect, test } from 'claude-code/testing'
import { checksOf, COMPACT_SAVES_TOKENS, compactLines, LAVENDER, lookParts, span, unpushedOf } from '../hooks/facts.ts'

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

const texts = (parts: ReturnType<typeof lookParts>) => parts.map(p => p.text).join('')
const now = 100 * HOUR
const fresh = (count: number) => ({ count, readAt: now, isStale: false })

describe('lookParts', () => {
  test('nothing needing a look and no mode: no line at all', () => {
    expect(lookParts({ modes: [], pr: null, jobs: [], unpushed: null, now })).toEqual([])
  })
  test('most urgent first: mode, PR, running jobs, kept jobs, unpushed commits', () => {
    const parts = lookParts({
      modes: ['NO BUILD'],
      pr: { number: 636, checks: 'failing', readAt: now, isStale: false },
      jobs: [
        { label: 'dev server', runMs: 2 * HOUR + 14 * MIN, kept: true, stuck: false },
        { label: 'npm test', runMs: MIN, kept: false, stuck: false },
      ],
      unpushed: fresh(2),
      now,
    })
    expect(texts(parts)).toBe('NO BUILD | PR #636 checks failing | 1 job running | dev server running 2h 14m | 2 unpushed commits')
  })
  test('the mode is bold amber, the items amber, the separators dim', () => {
    const parts = lookParts({ modes: ['AWAY'], pr: null, jobs: [], unpushed: fresh(1), now })
    expect(parts).toEqual([
      { text: 'AWAY', color: 'warning', bold: true },
      { text: ' | ', dim: true },
      { text: '1 unpushed commit', color: 'warning' },
    ])
  })
  test('two modes at once (no build while away) both lead, each bold, divided like the items', () => {
    const parts = lookParts({ modes: ['NO BUILD', 'AWAY'], pr: null, jobs: [], unpushed: fresh(1), now })
    expect(parts).toEqual([
      { text: 'NO BUILD', color: 'warning', bold: true },
      { text: ' | ', dim: true },
      { text: 'AWAY', color: 'warning', bold: true },
      { text: ' | ', dim: true },
      { text: '1 unpushed commit', color: 'warning' },
    ])
  })
  test('a mode alone still makes a line: the band shows while a mode is on', () => {
    expect(texts(lookParts({ modes: ['WINDING DOWN'], pr: null, jobs: [], unpushed: null, now }))).toBe('WINDING DOWN')
  })
  test('passing checks need no look; running ones are shown', () => {
    expect(lookParts({ modes: [], pr: { number: 9, checks: 'passing', readAt: now, isStale: false }, jobs: [], unpushed: null, now })).toEqual([])
    expect(texts(lookParts({ modes: [], pr: { number: 9, checks: 'running', readAt: now, isStale: false }, jobs: [], unpushed: null, now }))).toBe('PR #9 checks running')
  })
  test('a PR whose last refresh failed shows what was last read, with its age, never blank (L682)', () => {
    const pr = { number: 636, checks: 'running' as const, readAt: now - 12 * MIN, isStale: true }
    expect(texts(lookParts({ modes: [], pr, jobs: [], unpushed: null, now }))).toBe('PR #636 checks running, as of 12m ago')
  })
  test('a stale PR that last read as passing stays hidden: only an item that needed a look is kept', () => {
    const pr = { number: 7, checks: 'passing' as const, readAt: now - 3 * MIN, isStale: true }
    expect(lookParts({ modes: [], pr, jobs: [], unpushed: null, now })).toEqual([])
  })
  test('jobs counted, and every kept job named with its run time', () => {
    const jobs = [
      { label: 'a', runMs: MIN, kept: false, stuck: false },
      { label: 'b', runMs: MIN, kept: false, stuck: false },
      { label: 'dev server', runMs: 30 * MIN, kept: true, stuck: false },
      { label: 'watcher', runMs: 3 * HOUR, kept: true, stuck: false },
    ]
    expect(texts(lookParts({ modes: [], pr: null, jobs, unpushed: null, now }))).toBe('2 jobs running | dev server running 30m | watcher running 3h 0m')
  })
  // #706 (spec item 2 of #611), reworded by #784 (Dan, 2026-10-05: "I dont really know how to read
  // this"): a job the watcher measured as stalled says so in plain words and says who acts on it, so
  // Dan can see nothing is his to do; it comes ahead of the ones running fine.
  test('a stalled job says it is not progressing and that it is left to Claude, ahead of the running ones', () => {
    const jobs = [
      { label: 'a', runMs: MIN, kept: false, stuck: false },
      { label: 'b', runMs: MIN, kept: false, stuck: true, state: 'stalled' as const },
      { label: 'dev server', runMs: 30 * MIN, kept: true, stuck: true, state: 'stalled' as const },
    ]
    expect(texts(lookParts({ modes: [], pr: null, jobs, unpushed: null, now }))).toBe('1 job not progressing, left to Claude | dev server not progressing 30m, left to Claude | 1 job running')
    expect(texts(lookParts({ modes: [], pr: null, jobs: [jobs[1] as (typeof jobs)[number]], unpushed: null, now }))).toBe('1 job not progressing, left to Claude')
  })
  test('a job from a watcher that reports no state reads its stuck flag, so a bar newer than its watcher still says it (#784)', () => {
    const jobs = [{ label: 'b', runMs: MIN, kept: false, stuck: true }]
    expect(texts(lookParts({ modes: [], pr: null, jobs, unpushed: null, now }))).toBe('1 job not progressing, left to Claude')
  })
  // #784: a poll loop waiting on something outside (a queued CI run) is waiting, never stuck.
  test('a waiting job says waiting, never stuck', () => {
    const jobs = [
      { label: 'x', runMs: MIN, kept: false, stuck: false, state: 'waiting' as const },
      { label: 'PR 776 rerun wait', runMs: 12 * MIN, kept: true, stuck: false, state: 'waiting' as const },
    ]
    expect(texts(lookParts({ modes: [], pr: null, jobs, unpushed: null, now }))).toBe('1 job waiting | PR 776 rerun wait waiting 12m')
  })
  // #784: whose job it is. A background agent's jobs are one item under its task's name, so the line
  // never reads as though the conversation in front of Dan is hung, and say the agent acts on them.
  test("a background agent's jobs are one item under its name, saying it is the agent's to act on", () => {
    const jobs = [
      { label: 'dev server', runMs: 5 * MIN, kept: true, stuck: false, state: 'running' as const },
      { label: 'suite summary wait', runMs: 64 * MIN, kept: true, stuck: true, state: 'stalled' as const, owner: 'fix CI' },
      { label: 'PR 776 rerun wait', runMs: 12 * MIN, kept: true, stuck: false, state: 'waiting' as const, owner: 'fix CI' },
      { label: 'npm test', runMs: MIN, kept: false, stuck: false, state: 'running' as const, owner: 'fix CI' },
    ]
    expect(texts(lookParts({ modes: [], pr: null, jobs, unpushed: null, now }))).toBe(
      'dev server running 5m | agent fix CI: suite summary wait not progressing 1h 4m, left to the agent, PR 776 rerun wait waiting 12m, 1 job running',
    )
  })
  test('two agents with the same task description stay two items, told apart by their ids (lessons review of PR 794)', () => {
    const jobs = [
      { label: 'npm test', runMs: MIN, kept: false, stuck: true, state: 'stalled' as const, owner: 'fix CI', ownerId: 'a1b2c3d4e5' },
      { label: 'npm test', runMs: MIN, kept: false, stuck: false, state: 'running' as const, owner: 'fix CI', ownerId: 'f6a7b8c9d0' },
    ]
    expect(texts(lookParts({ modes: [], pr: null, jobs, unpushed: null, now }))).toBe(
      'agent fix CI (a1b2c3): 1 job not progressing, left to the agent | agent fix CI (f6a7b8): 1 job running',
    )
  })
  // #759: a background agent listed as running whose tool calls have stopped is named on the bar.
  test('a quiet background agent is named with how long it has been quiet, ahead of the jobs', () => {
    const jobs = [{ label: 'a', runMs: MIN, kept: false, stuck: false, state: 'running' as const }]
    const agents = [{ name: 'fix CI', quietMs: 34 * MIN }]
    expect(texts(lookParts({ modes: [], pr: null, jobs, agents, unpushed: null, now }))).toBe('agent fix CI quiet 34m, left to Claude | 1 job running')
  })
  // #697: an unpushed count that could not be read again is never a zero: the commits keep their
  // place on the line, with the age of the last reading, as a PR whose refresh failed does.
  test('unpushed commits whose last refresh failed keep their place, with the age of the last reading', () => {
    const unpushed = { count: 2, readAt: now - 3 * MIN, isStale: true }
    expect(texts(lookParts({ modes: [], pr: null, jobs: [], unpushed, now }))).toBe('2 unpushed commits, as of 3m ago')
  })
  test('no reading of unpushed commits yet, or none to push, is no item', () => {
    expect(lookParts({ modes: [], pr: null, jobs: [], unpushed: null, now })).toEqual([])
    expect(lookParts({ modes: [], pr: null, jobs: [], unpushed: fresh(0), now })).toEqual([])
  })
  // Dan, 2026-10-14: "I don't like that the waiting indicator is yellow." Work that is only going
  // along (a job running or waiting, PR checks running) is lavender; amber is kept for what needs a
  // look, so the two read apart at a glance.
  const colorOf = (parts: ReturnType<typeof lookParts>, text: string) => parts.find(p => p.text === text)?.color
  test('running and waiting jobs and running PR checks are lavender; what needs a look stays amber', () => {
    const jobs = [
      { label: 'a', runMs: MIN, kept: false, stuck: false, state: 'running' as const },
      { label: 'drift run', runMs: 20 * MIN, kept: true, stuck: false, state: 'waiting' as const },
      { label: 'b', runMs: MIN, kept: false, stuck: true, state: 'stalled' as const },
    ]
    const running = lookParts({ modes: ['AWAY'], pr: { number: 9, checks: 'running', readAt: now, isStale: false }, jobs, agents: [{ name: 'fix CI', quietMs: 34 * MIN }], unpushed: fresh(1), now })
    expect(colorOf(running, 'AWAY')).toBe('warning')
    expect(colorOf(running, 'PR #9 checks running')).toBe(LAVENDER)
    expect(colorOf(running, 'agent fix CI quiet 34m, left to Claude')).toBe('warning')
    expect(colorOf(running, '1 job not progressing, left to Claude')).toBe('warning')
    expect(colorOf(running, 'drift run waiting 20m')).toBe(LAVENDER)
    expect(colorOf(running, '1 job running')).toBe(LAVENDER)
    expect(colorOf(running, '1 unpushed commit')).toBe('warning')
    const failing = lookParts({ modes: [], pr: { number: 9, checks: 'failing', readAt: now, isStale: false }, jobs: [], unpushed: null, now })
    expect(colorOf(failing, 'PR #9 checks failing')).toBe('warning')
  })
  test("a background agent's jobs are lavender unless one of them is stalled", () => {
    const fine = [{ label: 'npm test', runMs: MIN, kept: false, stuck: false, state: 'running' as const, owner: 'fix CI' }]
    expect(colorOf(lookParts({ modes: [], pr: null, jobs: fine, unpushed: null, now }), 'agent fix CI: 1 job running')).toBe(LAVENDER)
    const mixed = [...fine, { label: 'wait', runMs: MIN, kept: false, stuck: true, state: 'stalled' as const, owner: 'fix CI' }]
    expect(colorOf(lookParts({ modes: [], pr: null, jobs: mixed, unpushed: null, now }), 'agent fix CI: 1 job not progressing, left to the agent, 1 job running')).toBe('warning')
  })
})

// #1596: the row says why it shows. For the cache the remedy is any message, which reads the cache
// and starts its hour again; Compact is offered for the cache only once the context is large enough
// for compacting to cost less than the cold re-read it avoids (COMPACT_SAVES_TOKENS).
describe('compactLines', () => {
  const COMPACT = { button: 'compact', label: 'Compact', instead: [{ text: 'type: ', dim: true }, { text: '/compact' }] }
  const small = { contextPercent: 18, contextTokens: 36_000 }
  const large = { contextPercent: 45, contextTokens: COMPACT_SAVES_TOKENS }
  const textOf = (lines: unknown[][]) => lines.map(l => l.map(p => ((p as { button?: string; label?: string; text?: string }).button ? `[ ${(p as { label: string }).label} ]` : (p as { text: string }).text)).join(''))
  test('context above 70% says so and offers Compact', () => {
    expect(compactLines({ contextPercent: 82, contextTokens: 164_000, cacheExpiresAt: null, now, isWorking: false })).toEqual([[{ text: 'context 82% ', color: 'warning' }, COMPACT]])
    expect(compactLines({ contextPercent: 70, contextTokens: 140_000, cacheExpiresAt: null, now, isWorking: false })).toEqual([])
  })
  test('the cache near cold with a small context says to send any message, and offers no Compact', () => {
    const lines = compactLines({ ...small, cacheExpiresAt: now + 4 * MIN, now, isWorking: false })
    expect(textOf(lines)).toEqual(['cache goes cold in 4m: send any message to keep it warm'])
    expect(lines.flat().some(p => 'button' in p)).toBe(false)
    expect(lines[0]?.[0]).toMatchObject({ color: 'warning' })
  })
  test('the cache near cold with a context large enough for compacting to save offers Compact beside the message', () => {
    expect(textOf(compactLines({ ...large, cacheExpiresAt: now + 4 * MIN, now, isWorking: false }))).toEqual(['cache goes cold in 4m: send any message to keep it warm, or [ Compact ]'])
    expect(textOf(compactLines({ ...large, contextTokens: COMPACT_SAVES_TOKENS - 1, cacheExpiresAt: now + 4 * MIN, now, isWorking: false }))).toEqual(['cache goes cold in 4m: send any message to keep it warm'])
  })
  test('the size is read in tokens, never as a share: 18% of a million is past the line, 70% of 200,000 is not', () => {
    expect(textOf(compactLines({ contextPercent: 18, contextTokens: 180_000, cacheExpiresAt: now + 4 * MIN, now, isWorking: false }))[0]).toMatch(/, or \[ Compact \]$/)
    expect(textOf(compactLines({ contextPercent: 70, contextTokens: 140_000, cacheExpiresAt: now + 4 * MIN, now, isWorking: false }))[0]).not.toMatch(/Compact/)
  })
  test('a context of unknown size offers no Compact for the cache, since nothing says it would save', () => {
    expect(textOf(compactLines({ contextPercent: undefined, contextTokens: undefined, cacheExpiresAt: now + 4 * MIN, now, isWorking: false }))).toEqual(['cache goes cold in 4m: send any message to keep it warm'])
  })
  test('both at once: the context line with its Compact, then the cache line, each reason said once', () => {
    expect(textOf(compactLines({ contextPercent: 82, contextTokens: 164_000, cacheExpiresAt: now + 4 * MIN, now, isWorking: false }))).toEqual([
      'context 82% [ Compact ]',
      'cache goes cold in 4m: send any message to keep it warm',
    ])
  })
  test('the cache row shows within 5 minutes of cold, and once cold it is gone', () => {
    expect(compactLines({ ...small, cacheExpiresAt: now + 5 * MIN, now, isWorking: false })).toHaveLength(1)
    expect(compactLines({ ...small, cacheExpiresAt: now + 6 * MIN, now, isWorking: false })).toEqual([])
    expect(compactLines({ ...small, cacheExpiresAt: now, now, isWorking: false })).toEqual([])
    expect(textOf(compactLines({ ...small, cacheExpiresAt: now + 30_000, now, isWorking: false }))).toEqual(['cache goes cold in <1m: send any message to keep it warm'])
  })
  // #697: while a main turn runs, every request it makes keeps the cache warm and Dan has nothing to
  // do about it, so the cache alone brings no row then. Context above 70% still does.
  test('while a turn runs, the cache alone brings no row; context still does', () => {
    expect(compactLines({ ...large, cacheExpiresAt: now + 5 * MIN, now, isWorking: true })).toEqual([])
    expect(textOf(compactLines({ contextPercent: 75, contextTokens: 150_000, cacheExpiresAt: now + 5 * MIN, now, isWorking: true }))).toEqual(['context 75% [ Compact ]'])
  })
  test('no context reading yet and no cache is no row', () => {
    expect(compactLines({ contextPercent: undefined, contextTokens: undefined, cacheExpiresAt: null, now, isWorking: false })).toEqual([])
  })
  test('the longest row fits an 80 column band', () => {
    const widest = [
      ...compactLines({ contextPercent: 100, contextTokens: 1_000_000, cacheExpiresAt: now + 5 * MIN, now, isWorking: false }),
      ...compactLines({ contextPercent: 69, contextTokens: 690_000, cacheExpiresAt: now + 5 * MIN, now, isWorking: false }),
    ]
    for (const line of textOf(widest)) expect(line.length).toBeLessThanOrEqual(80)
  })
})
