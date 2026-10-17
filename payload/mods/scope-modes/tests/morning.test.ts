import { describe, expect, test } from 'claude-code/testing'
import { ENDED_SAID, KEPT_NIGHTS, morningStep, pickerAnswered, reviewsIn, stalePending, withDone, withPending } from '../hooks/morning.ts'

// The morning reminder (#1107), and since #1283 ending sleep mode is the night's review: Dan,
// 2026-10-17, "it should be on every session and it should be completed automatically when I exit
// sleep mode". The tests for answering the wake pickers before the step came off are gone with that
// rule, which his words of that day reversed.

// The two dashes the style rule bans, named by code point so this file holds neither.
const DASHES = new RegExp(`[${String.fromCharCode(0x2014, 0x2013)}]| - `)

describe('the morning reminder: waking is the whole step (#1283)', () => {
  test("each night's step is its own, told apart by the night, and says that ending sleep mode is all there is to do", () => {
    expect(morningStep('2026-10-12')).toEqual({
      title: 'When you are up, end sleep mode (2026-10-12)',
      location: 'Any Claude Code session on this Mac',
      clicks: ["Say I'm up, or type /wake, in any session"],
    })
    expect(morningStep('2026-10-13').title).not.toBe(morningStep('2026-10-12').title)
  })
  test('what is said when it comes off names every session, and no dash', () => {
    expect(ENDED_SAID).toBe("Sleep mode is off, so the reminder to end it came off this session's manual steps card, and comes off every other session's within a minute.")
    expect(ENDED_SAID + JSON.stringify(morningStep('n'))).not.toMatch(DASHES)
  })
})

describe('the nights on disk', () => {
  test('are read, and a file that cannot be read is said, never read as none (L215)', () => {
    expect(reviewsIn('[{"generation":"g1","night":"2026-10-12"},{"generation":"g2","night":"2026-10-13","done":{"at":5,"how":"sleep-ended"}}]')).toEqual([
      { generation: 'g1', night: '2026-10-12' },
      { generation: 'g2', night: '2026-10-13', done: { at: 5, how: 'sleep-ended' } },
    ])
    expect(reviewsIn('{')).toEqual({ unreadable: 'it is not JSON' })
    expect(reviewsIn('{}')).toEqual({ unreadable: 'it is not a list of nights' })
    expect(reviewsIn('[{"night":"x"}]')).toEqual({ unreadable: 'a night in it names no generation or night' })
  })
  test('a night done any way it was written, the older ways and a later one included, stays done (L255)', () => {
    for (const how of ['nothing-proposed', 'pickers-answered', 'some-later-way'])
      expect(reviewsIn(`[{"generation":"g","night":"n","done":{"at":1,"how":"${how}"}}]`)).toEqual([{ generation: 'g', night: 'n', done: { at: 1, how } }])
    // A done with no time is not a done.
    expect(reviewsIn('[{"generation":"g","night":"n","done":{"how":"sleep-ended"}}]')).toEqual([{ generation: 'g', night: 'n' }])
  })
  test('a night is pending once, and done the first way it happened; only the latest nights are kept', () => {
    const one = withPending([], { generation: 'g1', night: 'n1' })
    expect(withPending(one, { generation: 'g1', night: 'n1' })).toEqual(one)
    const done = withDone(one, { generation: 'g1', night: 'n1' }, { at: 1, how: 'sleep-ended' })
    expect(done).toEqual([{ generation: 'g1', night: 'n1', done: { at: 1, how: 'sleep-ended' } }])
    expect(withDone(done, { generation: 'g1', night: 'n1' }, { at: 2, how: 'sleep-ended' })).toEqual(done)
    expect(withDone([], { generation: 'g0', night: 'n0' }, { at: 3, how: 'sleep-ended' })).toEqual([{ generation: 'g0', night: 'n0', done: { at: 3, how: 'sleep-ended' } }])
    let many: ReturnType<typeof withPending> = []
    for (let i = 0; i < KEPT_NIGHTS + 3; i++) many = withPending(many, { generation: `g${i}`, night: `n${i}` })
    expect(many.length).toBe(KEPT_NIGHTS)
    expect(many[0]?.generation).toBe('g3')
  })
  test('every pending night but the one asleep now has ended, however it ended, so it is done', () => {
    const all = [{ generation: 'g1', night: 'n1' }, { generation: 'g2', night: 'n2', done: { at: 1, how: 'sleep-ended' } }, { generation: 'g3', night: 'n3' }]
    expect(stalePending(all, 'g3')).toEqual([{ generation: 'g1', night: 'n1' }])
    expect(stalePending(all, null)).toEqual([{ generation: 'g1', night: 'n1' }, { generation: 'g3', night: 'n3' }])
  })
})

describe("a picker answered, as a session's morning turn counts them (#1285)", () => {
  test('only with an answer from Dan; a refused one counts neither way', () => {
    expect(pickerAnswered({ result: { answers: { 'File which?': '1.1, 1.2' } } })).toBe(true)
    expect(pickerAnswered({ result: { answers: { 'File which?': ['1.1'] } } })).toBe(true)
    expect(pickerAnswered({ result: { answers: { 'File which?': '' } } })).toBe(false)
    expect(pickerAnswered({ result: { answers: {} } })).toBe(false)
    expect(pickerAnswered({ result: { answers: { q: 'x' }, afkTimeoutMs: 60000 } })).toBe(false)
    expect(pickerAnswered({ isError: true, result: 'the dialog was dismissed' })).toBe(false)
    expect(pickerAnswered({ deny: 'Ask one question per call' })).toBeUndefined()
  })
})
