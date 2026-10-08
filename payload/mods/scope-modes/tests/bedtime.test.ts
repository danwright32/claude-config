import { describe, expect, test } from 'claude-code/testing'
import {
  answerKey,
  askOptions,
  askText,
  decisionComment,
  GO_TO_SLEEP,
  groupQuestions,
  orderQuestions,
  priorityRank,
  questionsIn,
  SKIP_QUESTION,
  unansweredText,
  type OpenQuestion,
} from '../hooks/bedtime.ts'
import { etDate } from '../hooks/sleep.ts'

// Sleep mode phase 6 (#836): the before bed questions about the queue's issues.

const line = (n: Record<string, unknown>) => JSON.stringify({ v: 1, generation: 'g1', at: 100, by: 's1', ...n })

describe('questionsIn: the questions earlier nights noted about an issue', () => {
  test('a question note naming a repository, an issue and its text is one question', () => {
    const r = questionsIn([line({ kind: 'question', repo: 'o/r', issue: 12, text: 'Keep the old flag?' })].join('\n'))
    expect(r).toEqual({ questions: [{ repo: 'o/r', issue: 12, text: 'Keep the old flag?', options: [], at: 100 }], bad: 0 })
  })

  test('an issue written as digits counts, and suggested choices are kept', () => {
    const r = questionsIn(line({ kind: 'question', repo: 'o/r', issue: '7', text: 'Which copy?', options: ['Short', 'Long', 3] }))
    expect(r.questions).toEqual([{ repo: 'o/r', issue: 7, text: 'Which copy?', options: ['Short', 'Long'], at: 100 }])
  })

  test('a question with no issue is not one an answer can be posted on: the refused question (#841) and the closed repository (#843) are left to the report', () => {
    const r = questionsIn(
      [
        line({ kind: 'question', cwd: '/repo', questions: ['Merge PR #31?'] }),
        line({ kind: 'question', repo: 'o/r', questions: ['Overnight in o/r, what may Claude do?'] }),
        line({ kind: 'finding', repo: 'o/r', issue: 3, text: 'not a question' }),
        line({ kind: 'question', repo: 'not a repo', issue: 3, text: 'x' }),
        line({ kind: 'question', repo: 'o/r', issue: 0, text: 'x' }),
        line({ kind: 'question', repo: 'o/r', issue: 4, text: '   ' }),
      ].join('\n'),
    )
    expect(r).toEqual({ questions: [], bad: 0 })
  })

  test('a line that is not JSON is counted, never dropped silently, and the rest still read (L215)', () => {
    const r = questionsIn(['{"kind":"question"', line({ kind: 'question', repo: 'o/r', issue: 2, text: 'a?' }), ''].join('\n'))
    expect(r.bad).toBe(1)
    expect(r.questions.map(q => q.issue)).toEqual([2])
  })
})

describe('groupQuestions: one question asked once, however many nights or issues noted it', () => {
  test('the same words on two nights are one question; on two issues, one question for both', () => {
    const g = groupQuestions([
      { repo: 'o/r', issue: 12, text: 'Keep the old flag?', options: [], at: 300 },
      { repo: 'O/R', issue: 12, text: 'Keep  the old\nflag?', options: [], at: 100 },
      { repo: 'o/r', issue: 14, text: 'Keep the old flag?', options: ['Yes'], at: 200 },
      { repo: 'o/other', issue: 12, text: 'Keep the old flag?', options: [], at: 50 },
    ])
    // The spelling first noted is kept; GitHub reads a repository's name in any case.
    expect(g).toEqual([
      { repo: 'o/other', text: 'Keep the old flag?', issues: [12], options: [], at: 50 },
      { repo: 'O/R', text: 'Keep the old flag?', issues: [12, 14], options: ['Yes'], at: 100 },
    ])
  })
})

describe('priorityRank', () => {
  test('p0 first, an issue with no priority last', () => {
    expect(priorityRank([{ name: 'priority-p0' }])).toBe(0)
    expect(priorityRank([{ name: 'bug' }, { name: 'priority-p3' }])).toBe(3)
    expect(priorityRank([{ name: 'bug' }])).toBe(5)
    expect(priorityRank(undefined)).toBe(5)
  })
})

describe('orderQuestions: the ones that unblock the most work first', () => {
  const q = (text: string, issues: number[], at = 100, repo = 'o/r'): OpenQuestion => ({ repo, text, issues, options: [], at })

  test('a question shared by more issues comes first', () => {
    const out = orderQuestions([q('one', [1]), q('two', [2, 3])], () => 2)
    expect(out.map(x => x.text)).toEqual(['two', 'one'])
  })

  test('then the one whose issue has fewest questions left, so an answer frees a whole issue soonest', () => {
    // Issue 1 waits on three questions, issue 2 on one: answering about issue 2 makes it workable.
    const out = orderQuestions([q('a', [1]), q('b', [1]), q('c', [1]), q('d', [2])], () => 2)
    expect(out[0]?.text).toBe('d')
  })

  test('then the higher priority issue, then the older question', () => {
    const ranks: Record<number, number> = { 1: 3, 2: 0, 3: 3 }
    const out = orderQuestions([q('low', [1], 50), q('high', [2], 900), q('low later', [3], 60)], (_r, n) => ranks[n] ?? 5)
    expect(out.map(x => x.text)).toEqual(['high', 'low', 'low later'])
  })
})

describe('the dialog', () => {
  test('the question names its issues, and every question offers to skip it and to go to sleep now', () => {
    const one: OpenQuestion = { repo: 'o/r', text: 'Keep the old flag?', issues: [12, 14], options: [], at: 1 }
    expect(askText(one)).toBe('o/r#12 and #14: Keep the old flag?')
    expect(askOptions(one)).toEqual([SKIP_QUESTION, GO_TO_SLEEP])
  })

  test('choices a session suggested come first, at most two, so the dialog keeps to its four', () => {
    const one: OpenQuestion = { repo: 'o/r', text: 'Which?', issues: [3], options: ['A', 'B', 'C', GO_TO_SLEEP], at: 1 }
    expect(askOptions(one)).toEqual(['A', 'B', SKIP_QUESTION, GO_TO_SLEEP])
    expect(askText(one)).toBe('o/r#3: Which?')
  })
})

describe('the decision posted on the issue (L249)', () => {
  test('dated in ET, the question quoted, and the answer as Dan gave it', () => {
    expect(decisionComment('Keep the old flag?\nOr drop it?', 'Drop it', '2026-10-07')).toBe(
      ['**Decision from Dan, 2026-10-07 (ET)**, answered before bed as sleep mode started.', '', '> Keep the old flag?', '> Or drop it?', '', 'Answer: Drop it'].join('\n'),
    )
  })

  test('the date is the ET calendar date, whatever the UTC date is', () => {
    // 11:30 PM ET on Oct 7 is already Oct 8 in UTC.
    expect(etDate(Date.UTC(2026, 9, 8, 3, 30))).toBe('2026-10-07')
    expect(etDate(Date.UTC(2026, 9, 8, 4, 30))).toBe('2026-10-08')
  })
})

describe('keys and the list the queue reads', () => {
  test('an answer is keyed by repository, issue and words, so a reworded or moved question is a new one', () => {
    const k = answerKey('o/r', 12, 'Keep the old flag?')
    expect(k).toMatch(/^[0-9a-f]{16}$/)
    expect(answerKey('O/R', 12, ' Keep  the old flag? ')).toBe(k)
    expect(answerKey('o/r', 13, 'Keep the old flag?')).not.toBe(k)
    expect(answerKey('o/r', 12, 'Keep the new flag?')).not.toBe(k)
  })

  test('the unanswered list is one owner/repo#N a line, each once, as sleep-queue.sh reads it', () => {
    expect(unansweredText([{ repo: 'o/r', issue: 14 }, { repo: 'o/r', issue: 12 }, { repo: 'O/R', issue: 14 }])).toBe('o/r#12\no/r#14\n')
    expect(unansweredText([])).toBe('')
  })
})
