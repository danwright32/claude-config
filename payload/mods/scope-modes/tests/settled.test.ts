import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { answerKey } from '../hooks/bedtime.ts'
import { answeredIn, distinctQuestions, judgeNamed, linkNumber, linksIn, namedItems, notAQuestion, settledKey } from '../hooks/settled.ts'
import { proposalsIn, type NightQuestion } from '../hooks/wake.ts'

// #3018: on 2026-11-15 a session was told to put four leftover overnight questions to Dan. Two were
// one build order note recorded twice that said itself it was not a question; two Dan had answered
// the morning after, their pull request merged. Nothing the offer read said any of that.

const q = (o: Partial<NightQuestion> & { text: string }): NightQuestion => ({ by: 's5', repo: null, issue: null, cwd: null, ...o })
const line = (n: Record<string, unknown>) => JSON.stringify({ v: 1, generation: 'g0', at: 1, by: 's5', ...n })
const NOTE = 'Build order for tonight: the schema change lands before the importer. This is not a question, nothing to answer.'

describe('notAQuestion: a note that says itself it is no question, with no choices', () => {
  test('a note with no choices that says it is not a question is not one', () => {
    expect(notAQuestion(q({ text: NOTE }))).toBe(true)
    expect(notAQuestion(q({ text: 'FYI: the importer waits on the schema change. No answer needed.' }))).toBe(true)
  })
  test('a real question is one, and so is a note with choices whatever its words say', () => {
    expect(notAQuestion(q({ text: 'Round totals up or down?' }))).toBe(false)
    expect(notAQuestion(q({ text: NOTE, options: ['Yes', 'No'] }))).toBe(false)
  })
})

describe('distinctQuestions: the same question recorded twice is one', () => {
  test('once by repository and once by folder, it is one question carrying both', () => {
    const out = distinctQuestions([q({ repo: 'exampleco/ledger', text: 'Keep the old flag?' }), q({ cwd: '/w/ledger', text: 'Keep  the old flag?' })])
    expect(out).toEqual([q({ repo: 'exampleco/ledger', cwd: '/w/ledger', text: 'Keep the old flag?' })])
  })
  test('the same words about two repositories, or two issues, stay two questions', () => {
    expect(distinctQuestions([q({ repo: 'exampleco/ledger', text: 'Keep it?' }), q({ repo: 'exampleco/atlas', text: 'Keep it?' })]).length).toBe(2)
    expect(distinctQuestions([q({ repo: 'exampleco/ledger', issue: 3, text: 'Keep it?' }), q({ repo: 'exampleco/ledger', issue: 4, text: 'Keep it?' })]).length).toBe(2)
  })
  test('the same words from two folders, neither naming its repository, stay two questions (#3018 review)', () => {
    expect(distinctQuestions([q({ cwd: '/w/ledger', text: 'Keep it?' }), q({ cwd: '/w/atlas', text: 'Keep it?' })]).length).toBe(2)
  })
  test('the same repository noted from two folders, such as a worktree, is one question', () => {
    expect(distinctQuestions([q({ repo: 'exampleco/ledger', cwd: '/w/ledger', text: 'Keep it?' }), q({ repo: 'exampleco/ledger', cwd: '/w/ledger-wt', text: 'Keep it?' })]).length).toBe(1)
  })
})

describe("proposalsIn leaves out notes that are no question, and reads a question twice as once (#3018)", () => {
  test('the incident: a note recorded per repository and per folder, beside a real question', () => {
    const p = proposalsIn(
      [
        line({ kind: 'question', repo: 'exampleco/ledger', text: NOTE }),
        line({ kind: 'question', cwd: '/w/ledger', questions: [NOTE] }),
        line({ kind: 'question', repo: 'exampleco/ledger', issue: 41, text: 'Apply the migration in PR #52?', options: ['Apply it', 'Leave it'] }),
        line({ kind: 'question', cwd: '/w/ledger', questions: ['Apply the migration in PR #52?'] }),
      ].join('\n'),
    )
    expect(p.questions.map(x => x.text)).toEqual(['Apply the migration in PR #52?'])
    expect(p.questions[0]).toMatchObject({ repo: 'exampleco/ledger', issue: 41, cwd: '/w/ledger', options: ['Apply it', 'Leave it'] })
    expect(p.bad).toBe(0)
  })
})

describe('namedItems: the issues and pull requests a question names', () => {
  test('its issue, and each number in its words, in its own repository or the one written with it', () => {
    expect(namedItems(q({ repo: 'exampleco/ledger', issue: 41, text: 'Apply the migration in PR #52, and close exampleco/atlas#7?' }), 'exampleco/ledger')).toEqual([
      { repo: 'exampleco/ledger', number: 41 },
      { repo: 'exampleco/ledger', number: 52 },
      { repo: 'exampleco/atlas', number: 7 },
    ])
    // A link's repository is read by mod-kit's link reader in register.ts, and handed in.
    expect(namedItems(q({ text: 'Merge https://example.test/exampleco/atlas/pull/9 now? Not #9 of ledger.' }), null, [{ repo: 'exampleco/atlas', number: 9 }])).toEqual([{ repo: 'exampleco/atlas', number: 9 }])
  })
  test('the addresses in its words, and the number each ends on', () => {
    expect(linksIn('See https://example.test/o/r/pull/9, and https://example.test/o/r/issues/12.')).toEqual(['https://example.test/o/r/pull/9', 'https://example.test/o/r/issues/12'])
    expect(linkNumber('https://example.test/o/r/pull/9')).toBe(9)
    expect(linkNumber('https://example.test/o/r/issues/12#issuecomment-1')).toBe(12)
    expect(linkNumber('https://example.test/o/r/blob/main/a.ts')).toBe(null)
  })
  test('a bare number with no repository to read it in, or one glued to a short name, names nothing', () => {
    expect(namedItems(q({ text: 'Merge PR #52?' }), null)).toEqual([])
    expect(namedItems(q({ text: 'As in ledger#52, keep it?' }), 'exampleco/ledger')).toEqual([])
  })
  test('a number named twice is asked about once', () => {
    expect(namedItems(q({ repo: 'exampleco/ledger', issue: 52, text: 'PR #52 or #52?' }), 'exampleco/ledger')).toEqual([{ repo: 'exampleco/ledger', number: 52 }])
  })
})

describe('judgeNamed: settled only when everything it names is closed or merged', () => {
  const a = { repo: 'exampleco/ledger', number: 52 }
  const b = { repo: 'exampleco/ledger', number: 53 }
  test('all closed is settled; one still open is not; naming nothing is not', () => {
    expect(judgeNamed([{ item: a, state: { state: 'closed' } }, { item: b, state: { state: 'closed' } }])).toEqual({ settled: true })
    expect(judgeNamed([{ item: a, state: { state: 'closed' } }, { item: b, state: { state: 'open' } }])).toEqual({ settled: false })
    expect(judgeNamed([])).toEqual({ settled: false })
  })
  test('a lookup that failed never settles it: it is asked, saying the check could not be made', () => {
    expect(judgeNamed([{ item: a, state: { state: 'closed' } }, { item: b, state: { state: 'unchecked', why: 'HTTP 502' } }])).toEqual({
      settled: false,
      unchecked: 'whether exampleco/ledger#53 is still open could not be checked with GitHub: HTTP 502',
    })
  })
})

describe("settledKey: an answer is kept where the before bed round keeps one", () => {
  test('a question about an issue has the key its bedtime answer has', () => {
    expect(settledKey('Exampleco/Ledger', { issue: 41, text: 'Keep  it?' })).toBe(answerKey('exampleco/ledger', 41, 'Keep it?'))
  })
  test('one with no repository or issue still has a key of its own', () => {
    expect(settledKey(null, { issue: null, text: 'Keep it?' })).not.toBe(settledKey(null, { issue: null, text: 'Drop it?' }))
  })
})

describe('answeredIn: the 3.n questions Dan answered in a morning picker', () => {
  const offered = new Set(['3.1', '3.2'])
  test('a picker whose question starts with its number, answered, is answered', () => {
    const qs = [{ question: '3.1 Apply the migration in PR #52?' }, { question: '3.2 Keep the old flag?' }]
    expect(answeredIn(qs, { '3.1 Apply the migration in PR #52?': 'Apply it', '3.2 Keep the old flag?': '' }, offered)).toEqual([{ n: '3.1', answer: 'Apply it' }])
  })
  test('a number this session did not offer, or a picker with no number, records nothing', () => {
    expect(answeredIn([{ question: '3.9 Other?' }, { question: 'Keep the old flag?' }], { '3.9 Other?': 'Yes', 'Keep the old flag?': 'Yes' }, offered)).toEqual([])
  })
})
