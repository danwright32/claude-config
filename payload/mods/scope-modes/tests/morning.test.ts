import { describe, expect, test } from 'claude-code/testing'
import { KEPT_NIGHTS, morningStep, nothingProposed, pickerAnswered, reviewedAtEnd, reviewsIn, withDone, withPending } from '../hooks/morning.ts'

// #1107: the morning reminder's decisions.
describe("the morning reminder to review the night's proposals (#1107)", () => {
  test("each night's step is its own, told apart by the night", () => {
    expect(morningStep('2026-10-12').title).toBe("When you are up: review the night's proposed issues (2026-10-12)")
    expect(morningStep('2026-10-13').title).not.toBe(morningStep('2026-10-12').title)
  })
  test('the nights on disk are read, and a file that cannot be read is said, never read as none (L215)', () => {
    expect(reviewsIn('[{"generation":"g1","night":"2026-10-12"},{"generation":"g2","night":"2026-10-13","done":{"at":5,"how":"nothing-proposed"}}]')).toEqual([
      { generation: 'g1', night: '2026-10-12' },
      { generation: 'g2', night: '2026-10-13', done: { at: 5, how: 'nothing-proposed' } },
    ])
    expect(reviewsIn('{')).toEqual({ unreadable: 'it is not JSON' })
    expect(reviewsIn('{}')).toEqual({ unreadable: 'it is not a list of nights' })
    expect(reviewsIn('[{"night":"x"}]')).toEqual({ unreadable: 'a night in it names no generation or night' })
    // A done that is not one of the two ways is not done.
    expect(reviewsIn('[{"generation":"g","night":"n","done":{"at":1,"how":"timed-out"}}]')).toEqual([{ generation: 'g', night: 'n' }])
  })
  test('a night is pending once, and done the first way it happened; only the latest nights are kept', () => {
    const one = withPending([], { generation: 'g1', night: 'n1' })
    expect(withPending(one, { generation: 'g1', night: 'n1' })).toEqual(one)
    const done = withDone(one, { generation: 'g1', night: 'n1' }, { at: 1, how: 'nothing-proposed' })
    expect(done).toEqual([{ generation: 'g1', night: 'n1', done: { at: 1, how: 'nothing-proposed' } }])
    expect(withDone(done, { generation: 'g1', night: 'n1' }, { at: 2, how: 'pickers-answered' })).toEqual(done)
    // A night whose pending note was never written (a sleep begun before #1107) is added done.
    expect(withDone([], { generation: 'g0', night: 'n0' }, { at: 3, how: 'pickers-answered' })).toEqual([{ generation: 'g0', night: 'n0', done: { at: 3, how: 'pickers-answered' } }])
    let many: ReturnType<typeof withPending> = []
    for (let i = 0; i < KEPT_NIGHTS + 3; i++) many = withPending(many, { generation: `g${i}`, night: `n${i}` })
    expect(many.length).toBe(KEPT_NIGHTS)
    expect(many[0]?.generation).toBe('g3')
  })
  test('nothing proposed is only a night whose notes were all read and held no proposal', () => {
    expect(nothingProposed({ issues: [], lessons: [] })).toBe(true)
    expect(nothingProposed({ issues: [{}], lessons: [] })).toBe(false)
    expect(nothingProposed({ issues: [], lessons: ['a rule'] })).toBe(false)
    expect(nothingProposed({ issues: [], lessons: [], bad: 1 })).toBe(false)
    expect(nothingProposed({ issues: [], lessons: [], unread: 'EACCES' })).toBe(false)
  })
  test('a picker counts as answered only with an answer from Dan; a refused one counts neither way', () => {
    expect(pickerAnswered({ result: { answers: { 'File which?': '1.1, 1.2' } } })).toBe(true)
    expect(pickerAnswered({ result: { answers: { 'File which?': ['1.1'] } } })).toBe(true)
    expect(pickerAnswered({ result: { answers: { 'File which?': '' } } })).toBe(false)
    expect(pickerAnswered({ result: { answers: {} } })).toBe(false)
    expect(pickerAnswered({ result: { answers: { q: 'x' }, afkTimeoutMs: 60000 } })).toBe(false)
    expect(pickerAnswered({ isError: true, result: 'the dialog was dismissed' })).toBe(false)
    expect(pickerAnswered({ deny: 'Ask one question per call' })).toBeUndefined()
  })
  test('the morning turn reviewed the night only once it ended answered with every picker answered', () => {
    const w = { generation: 'g', night: 'n', turnId: 't', answered: 2, unanswered: 0 }
    expect(reviewedAtEnd(w, 'answer')).toBe(true)
    expect(reviewedAtEnd({ ...w, answered: 0 }, 'answer')).toBe(false)
    expect(reviewedAtEnd({ ...w, unanswered: 1 }, 'answer')).toBe(false)
    expect(reviewedAtEnd(w, 'interrupted')).toBe(false)
  })
})
