import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import {
  goalIssues,
  answerChoices,
  answerKey,
  askOptions,
  askText,
  decisionComment,
  GO_TO_SLEEP,
  goalAnswer,
  goalOptions,
  goalQuestion,
  goalUnreadQuestion,
  NO_GOAL,
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
    const r = questionsIn([line({ kind: 'question', repo: 'o/r', issue: 12, text: 'Which copy?' })].join('\n'))
    expect(r).toEqual({ questions: [{ repo: 'o/r', issue: 12, text: 'Which copy?', options: [], at: 100 }], bad: 0 })
  })

  test('a note from before options were asked for, holding a yes or no question, is offered Yes and No (#1771)', () => {
    const r = questionsIn([line({ kind: 'question', repo: 'o/r', issue: 12, text: 'Keep the old flag?' }), line({ kind: 'question', repo: 'o/r', issue: 13, text: 'Drop it?', options: ['Only one'] })].join('\n'))
    expect(r.questions.map(q => q.options)).toEqual([
      ['Yes', 'No'],
      ['Yes', 'No'],
    ])
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

describe('answerChoices: the choices a question is offered with (#1771)', () => {
  test('two or more choices it was given are its choices, each once, never skip or go to sleep', () => {
    expect(answerChoices('Which copy?', ['Short', 'Long', 'Short', ' '])).toEqual(['Short', 'Long'])
    expect(answerChoices('Keep it?', ['Keep', GO_TO_SLEEP, SKIP_QUESTION, 'Drop'])).toEqual(['Keep', 'Drop'])
  })

  test('a yes or no question given fewer than two is offered Yes and No', () => {
    expect(answerChoices('Keep the old flag?', [])).toEqual(['Yes', 'No'])
    expect(answerChoices("May the settled test's wording change so such a job is named as finished?", [])).toEqual(['Yes', 'No'])
    expect(answerChoices('Is this design settled?', ['Settled'])).toEqual(['Yes', 'No'])
    // The question is the sentence the question mark ends, read after what leads up to it.
    expect(answerChoices("9.6: a builder's read was refused overnight. Its first half merged, and the rest waits. Run it now?", [])).toEqual(['Yes', 'No'])
  })

  test('a question between alternatives, or one asking which, what, how or when, is not yes or no, so it is given none', () => {
    for (const t of [
      'Should the last before bed question drop "Skip this one", or keep both options?',
      'Slot shape: every Nth recommendation, one fixed option in each picker, or a weekly structural pick?',
      'For a wait ending on a weekend or evening: keep the exact time, or move the reminder to the next working morning?',
      'Which mechanism measures egress on macOS without a password prompt per run?',
      'For the Mac apps: which Playwright should the design side use, a shared install or one per app?',
      'How often should it run per repo?',
      'Should the proof be the path, or the record? The record is stronger.',
      'Not a question at all.',
    ])
      expect(answerChoices(t, [])).toEqual([])
  })
})

describe('the dialog', () => {
  test('the question names its issues, and one with no choices offers to skip it and to go to sleep', () => {
    const one: OpenQuestion = { repo: 'o/r', text: 'Keep the old flag?', issues: [12, 14], options: [], at: 1 }
    expect(askText(one)).toBe('o/r#12 and #14: Keep the old flag?')
    expect(askOptions(one)).toEqual([SKIP_QUESTION, GO_TO_SLEEP])
  })

  test('skip and go to sleep say what each does: this one question, or every question left (#1771)', () => {
    expect(SKIP_QUESTION).toBe('Skip this one')
    expect(GO_TO_SLEEP).toBe('Go to sleep, no more questions')
  })

  test('the last question drops skip, which there does what going to sleep does, and has room for a third choice (#1771)', () => {
    const one: OpenQuestion = { repo: 'o/r', text: 'Which?', issues: [3], options: ['A', 'B', 'C', 'D'], at: 1 }
    expect(askOptions(one, true)).toEqual(['A', 'B', 'C', GO_TO_SLEEP])
    expect(askOptions({ ...one, options: ['Yes', 'No'] }, true)).toEqual(['Yes', 'No', GO_TO_SLEEP])
    // One with no choices keeps skip: the dialog shows two at least, and pads fewer with Yes and No.
    expect(askOptions({ ...one, options: [] }, true)).toEqual([SKIP_QUESTION, GO_TO_SLEEP])
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

// Sleep mode works only a goal Dan set (#1242, Dan's decision of 2026-10-16: "it should just work with
// the built in /goal"). How a session's goal is read from its transcript is mod-kit's to test
// (mod-kit/tests/goal.test.ts, every case these tests held before #1252 moved the reader there);
// here, what a worker with none is asked and what its answer gives it.
describe('the goal a session has set (#1242)', () => {
  test('the question names the session, says no goal means no work, and offers no work and going to sleep', () => {
    const q = goalQuestion('The session in o/r ("Fix the parser")')
    expect(q).toMatch(/^The session in o\/r \("Fix the parser"\) has no \/goal set/)
    expect(q).toMatch(/does no work tonight/)
    expect(goalOptions()).toEqual([NO_GOAL, GO_TO_SLEEP])
  })
  // #1636: a goal that could not be read is never said as none.
  test('a goal that could not be read is asked with why, and never says the session has no /goal set', () => {
    const q = goalUnreadQuestion('this session', 'its transcript was not found')
    expect(q).toMatch(/^The \/goal of this session could not be read, because its transcript was not found\. It may have one set/)
    expect(q).toMatch(/does no work tonight unless you give it one here/)
    expect(q).not.toMatch(/has no \/goal set/)
  })
  test('an answer typed is the goal; no work, an empty answer and going to sleep are none', () => {
    expect(goalAnswer('  Close #12 and #14 ')).toEqual({ goal: 'Close #12 and #14' })
    expect(goalAnswer(NO_GOAL)).toEqual({ goal: null })
    expect(goalAnswer('   ')).toEqual({ goal: null })
    expect(goalAnswer(GO_TO_SLEEP)).toEqual({ goal: null, slept: true })
  })
})

// #1279: the issues a goal names, whose Open questions /sleep asks before the night.
describe('the issues a goal names', () => {
  test('#N in the worker\'s repository, owner/name#N anywhere, each once', () => {
    expect(goalIssues('Close #7 and #9, then #7 again', 'o/r')).toEqual([{ repo: 'o/r', issue: 7 }, { repo: 'o/r', issue: 9 }])
    expect(goalIssues('Land o/other#12 and #3', 'o/r')).toEqual([{ repo: 'o/other', issue: 12 }, { repo: 'o/r', issue: 3 }])
  })
  test('a number named as a pull request is not read as an issue (lessons review)', () => {
    expect(goalIssues('Merge PR #31, then close #7; pull request #40 too', 'o/r')).toEqual([{ repo: 'o/r', issue: 7 }])
    expect(goalIssues('Merge PRs #31 and #32, pull requests #3, #4 and o/r#5, then close #9', 'o/r')).toEqual([{ repo: 'o/r', issue: 9 }])
  })
  test('a goal naming no issue, or a worker in no repository, names none it can read', () => {
    expect(goalIssues('Finish the Saved views milestone', 'o/r')).toEqual([])
    expect(goalIssues('Close #7', null)).toEqual([])
    expect(goalIssues('Close o/r#7', null)).toEqual([{ repo: 'o/r', issue: 7 }])
  })
})
