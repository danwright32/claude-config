import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { rotationStamp } from '../hooks/prline.ts'
import {
  DAY_MS,
  ESCALATE_AGAIN_MS,
  ESCALATE_SESSIONS,
  ESCALATE_WINDOW_MS,
  LINE_EVERY_MS,
  claimStale,
  escalationKey,
  escalationNote,
  escalations,
  lineDue,
  parseLines,
  stampTime,
  weeklyLine,
  windowFiles,
  type Read,
} from '../hooks/weekly.ts'

// The weekly line in the issue review and the escalation of files sessions keep proceeding past
// (#1511). Pure: every clock is a number handed in (L524), every file a text handed in.

const NOW = Date.parse('2026-11-05T12:00:00.000Z')
const ago = (days: number) => new Date(NOW - days * DAY_MS).toISOString()
// Every fixture record is its own line, as real ones are (a call id, a duration): identical lines are read once.
let serial = 0
const line = (r: object) => JSON.stringify({ ...r, n: serial++ })
const loaded = (session: string, days = 1) => line({ v: 1, kind: 'loaded', at: ago(days), session, cwd: '/w/app', rule: 3 })
const judged = (o: { path?: string; repo?: string; decision?: 'quiet' | 'held'; applied?: string; state?: string; matches?: unknown[]; days?: number; session?: string } = {}) =>
  line({
    v: 2,
    kind: 'judged',
    at: ago(o.days ?? 1),
    session: o.session ?? 's1',
    agent: null,
    repo: o.repo ?? 'dan/app',
    path: o.path ?? 'src/a.ts',
    decision: o.decision ?? 'quiet',
    ...(o.applied ? { applied: o.applied } : {}),
    issues: { state: o.state ?? 'read', count: 3 },
    matches: o.matches ?? [],
    why: 'x',
  })
const decided = (o: { decision?: string; session?: string; agent?: string | null; path?: string; repo?: string; days?: number } = {}) =>
  line({ v: 3, kind: 'decided', at: ago(o.days ?? 1), session: o.session ?? 's1', agent: o.agent ?? null, repo: o.repo ?? 'dan/app', branch: 'b', mergeBase: null, path: o.path ?? 'src/a.ts', call: 'c', decision: o.decision ?? 'proceed', reason: 'r' })
const unread = (decision: 'held' | 'passed', days = 1) => line({ v: 1, kind: 'unread', at: ago(days), session: 's1', agent: null, repo: 'dan/app', word: 'sed', why: 'x', decision })
const unjudged = (days = 1) => line({ v: 1, kind: 'unjudged', at: ago(days), session: 's1', agent: null, path: 'src/a.ts', why: 'it has no origin remote' })
const err = (days = 1) => line({ v: 1, kind: 'error', at: ago(days), session: 's1', path: '/w/app/src/a.ts', error: 'boom' })

const read = (...lines: string[]): Read => ({ state: 'read', texts: [lines.join('\n') + '\n'] })
const none: Read = { state: 'missing' }
const TAIL = "Counts are this Mac's only: the other Mac keeps its own log."

test('the windows are a week for the line and thirty days and five sessions for an escalation', () => {
  expect(LINE_EVERY_MS).toBe(7 * DAY_MS)
  expect(ESCALATE_WINDOW_MS).toBe(30 * DAY_MS)
  expect(ESCALATE_AGAIN_MS).toBe(30 * DAY_MS)
  expect(ESCALATE_SESSIONS).toBe(5)
})

test('the weekly line counts each kind of record in the last seven days, and ends naming the other Mac', () => {
  const log = read(
    loaded('s1'), loaded('s1', 2), loaded('s2'),
    judged(), judged({ decision: 'held' }), judged({ decision: 'held' }), judged({ decision: 'held', applied: 'Proceed anyway' }),
    judged({ state: 'unread' }), unread('held'), unread('passed'),
    decided(), decided({ decision: 'fold' }), decided({ decision: 'restructure' }), decided(),
    unjudged(), unjudged(),
    // Older than the week: none of these count.
    loaded('s9', 8), judged({ days: 8, decision: 'held' }), decided({ days: 8 }), unjudged(8),
  )
  expect(weeklyLine(log, read(err(), err(9)), NOW)).toBe(
    'Area check, this Mac, last 7 days: loaded in 2 sessions; 7 first writes judged, 3 held; decided 2 proceed, 1 fold, 1 restructure, and 1 let through by Dan\'s standing answer; 1 judged with the issue list unread; 2 not judged; 1 error. ' + TAIL,
  )
})

test('a missing errors file is no errors, an unreadable one is said, never zero (L90)', () => {
  const log = read(loaded('s1'))
  expect(weeklyLine(log, none, NOW)).toContain('; 0 errors. ')
  const said = weeklyLine(log, { state: 'unreadable', code: 'EACCES' }, NOW)
  expect(said).toContain('errors not counted, the errors file could not be read (EACCES)')
  expect(said).not.toContain('0 errors')
})

test('a log that does not exist, cannot be read, or holds no readable line says so instead of zeros (L90)', () => {
  expect(weeklyLine(none, none, NOW)).toBe('Area check, this Mac, last 7 days: no load record, the log does not exist, so the mod has never started here. ' + TAIL)
  expect(weeklyLine({ state: 'unreadable', code: 'EACCES' }, none, NOW)).toBe('Area check, this Mac, last 7 days: no counts, the log could not be read (EACCES). ' + TAIL)
  expect(weeklyLine({ state: 'read', texts: ['not json\n{"half":\n'] }, none, NOW)).toBe('Area check, this Mac, last 7 days: no counts, none of its 2 lines could be read. ' + TAIL)
})

test('no load record in the week is said as the mod not starting, not as zero firings', () => {
  expect(weeklyLine(read(loaded('s1', 9)), none, NOW)).toBe(
    'Area check, this Mac, last 7 days: no load record in 7 days, so the mod did not start here; that is not zero firings. ' + TAIL,
  )
  // Anything else recorded in the week is still counted after it.
  expect(weeklyLine(read(judged({ decision: 'held' })), none, NOW)).toContain('that is not zero firings; 1 first write judged, 1 held;')
})

test('lines that cannot be read are counted and named, and an at that is not a time is one of them (L50)', () => {
  const out = weeklyLine(read(loaded('s1'), 'garbage', line({ kind: 'loaded', at: 'soon', session: 's2' })), none, NOW)
  expect(out).toContain('loaded in 1 session;')
  expect(out).toContain('2 lines of the log could not be read and were skipped')
})

test('the same line in two files (a crash between rotation steps) is counted once', () => {
  const j = judged({ decision: 'held' })
  const { records, malformed } = parseLines([`${loaded('s1')}\n${j}\n`, `${j}\n`])
  expect(records.length).toBe(2)
  expect(malformed).toBe(0)
})

test('the weekly line carries counts only, never a path from a work repository', () => {
  const out = weeklyLine(read(loaded('s1'), judged({ path: 'secret/work/thing.ts', repo: 'acme/private', decision: 'held' }), err()), read(err()), NOW)
  expect(out).not.toContain('secret/work')
  expect(out).not.toContain('acme')
  expect(out).not.toContain('/w/app')
})

test('the line is due once a week: a missing, invalid or future stamp is due, 6.9 days is not, 7 days is', () => {
  expect(lineDue(null, NOW)).toBe(true)
  expect(lineDue('soon', NOW)).toBe(true)
  expect(lineDue(String(NOW + DAY_MS), NOW)).toBe(true)
  expect(lineDue(String(NOW - 6.9 * DAY_MS), NOW)).toBe(false)
  expect(lineDue(String(NOW - 7 * DAY_MS), NOW)).toBe(true)
})

test('a rotated file name gives back the time rotationStamp wrote into it', () => {
  const at = Date.parse('2026-10-30T08:15:42.123Z')
  expect(stampTime(`${rotationStamp(at, 'abc-123')}.jsonl`)).toBe(at)
  expect(stampTime(`${rotationStamp(at, 'abc_1.2')}.rotating`)).toBe(at)
  expect(stampTime('nonsense.jsonl')).toBe(null)
})

test('the files read are every .rotating file and the archives rotated inside the window, never the decision copies', () => {
  const old = rotationStamp(NOW - 40 * DAY_MS, 's')
  const recent = rotationStamp(NOW - 3 * DAY_MS, 's')
  const names = [`${old}.jsonl`, `${old}.decisions.jsonl`, `${recent}.jsonl`, `${recent}.decisions.jsonl`, `${old}.rotating`, 'odd.jsonl', `${recent}.decisions.9.tmp`]
  expect(windowFiles(names, NOW - 30 * DAY_MS).sort()).toEqual([`${old}.rotating`, `${recent}.jsonl`, 'odd.jsonl'].sort())
})

const fiveSessions = (o: { days?: number } = {}) => ['a', 'b', 'c', 'd', 'e'].map(s => decided({ session: s, days: o.days }))
const recs = (...lines: string[]) => parseLines([lines.join('\n')]).records

test('a file proceeded past in five sessions in thirty days, with no issue naming it, escalates; four does not', () => {
  const five = escalations(recs(judged({ decision: 'held' }), ...fiveSessions()), 'Dan/App', NOW)
  expect(five).toEqual([{ repo: 'dan/app', path: 'src/a.ts', sessions: 5 }])
  expect(escalations(recs(judged(), ...fiveSessions().slice(1)), 'dan/app', NOW)).toEqual([])
})

test('four agents in one session count as one session', () => {
  const r = recs(judged(), ...['a', 'b', 'c', 'd'].map(s => decided({ session: s })), ...[1, 2, 3, 4].map(n => decided({ session: 'x', agent: `ag${n}` })))
  expect(escalations(r, 'dan/app', NOW)).toEqual([{ repo: 'dan/app', path: 'src/a.ts', sessions: 5 }])
  const four = recs(judged(), ...['a', 'b', 'c'].map(s => decided({ session: s })), ...[1, 2, 3, 4].map(n => decided({ session: 'x', agent: `ag${n}` })))
  expect(escalations(four, 'dan/app', NOW)).toEqual([])
})

test('an issue naming the file, or an issue list read unread or truncated, stops the escalation', () => {
  expect(escalations(recs(judged({ matches: [{ n: 7 }] }), ...fiveSessions()), 'dan/app', NOW)).toEqual([])
  expect(escalations(recs(judged({ state: 'unread' }), ...fiveSessions()), 'dan/app', NOW)).toEqual([])
  expect(escalations(recs(judged({ state: 'truncated' }), ...fiveSessions()), 'dan/app', NOW)).toEqual([])
  // No judged record in the window: nothing says no issue names it.
  expect(escalations(recs(...fiveSessions()), 'dan/app', NOW)).toEqual([])
  // The newest judgement decides: an older match no longer stops it.
  expect(escalations(recs(judged({ matches: [{ n: 7 }], days: 9 }), judged({ days: 2 }), ...fiveSessions()), 'dan/app', NOW).length).toBe(1)
})

test('only proceed counts, never fold, restructure or Dan\'s standing answer, and only inside thirty days, only for this repo', () => {
  const folds = ['a', 'b', 'c', 'd', 'e'].map(s => decided({ session: s, decision: 'fold' }))
  expect(escalations(recs(judged(), ...folds), 'dan/app', NOW)).toEqual([])
  const applied = ['a', 'b', 'c', 'd', 'e'].map(s => judged({ session: s, decision: 'held', applied: 'Proceed anyway' }))
  expect(escalations(recs(...applied), 'dan/app', NOW)).toEqual([])
  expect(escalations(recs(judged(), ...fiveSessions({ days: 31 })), 'dan/app', NOW)).toEqual([])
  expect(escalations(recs(judged(), ...fiveSessions()), 'dan/other', NOW)).toEqual([])
})

test('a claim is stale after thirty days, and a claim that cannot be read is stale', () => {
  expect(claimStale(JSON.stringify({ at: NOW - 29 * DAY_MS }), NOW)).toBe(false)
  expect(claimStale(JSON.stringify({ at: NOW - 30 * DAY_MS }), NOW)).toBe(true)
  expect(claimStale('{', NOW)).toBe(true)
  expect(claimStale(JSON.stringify({ at: 'x' }), NOW)).toBe(true)
})

test('the key is the repository lowercased and the path, and the note names the count and the file', () => {
  expect(escalationKey({ repo: 'Dan/App', path: 'src/a.ts', sessions: 5 })).toBe('dan/app\nsrc/a.ts')
  const note = escalationNote({ repo: 'dan/app', path: 'src/a.ts', sessions: 6 })
  expect(note).toContain('src/a.ts')
  expect(note).toContain('6 sessions')
  expect(note).toContain('30 days')
  expect(note.length).toBeLessThan(500)
})
