import { describe, expect, test } from 'claude-code/testing'
import { askOf, asksQuiet, bandEverywhere, echoOf, onAbort, passedOver, passesOver, proseAnswers, recordPass, refusal, refusalFor } from '../hooks/pickers.ts'
import type { Passed, Question } from '../hooks/pickers.ts'

const RETENTION: Question = {
  question: "How long should the registry keep a closed session's record?",
  header: 'Retention',
  multiSelect: false,
  options: [
    { label: '7 days', description: 'Covers a long weekend and a week away.' },
    { label: '30 days', description: 'Keeps a month of history for the goals pane.' },
  ],
}

describe('askOf', () => {
  // The look is mod-kit's ($.modkit.question builds every question the one settled way, #703); this
  // is what picker manners hands it: Claude's chip and question, each option under its own button.
  test("Claude's chip, question and options, each option's button numbered in order, its description carried", () => {
    expect(askOf(RETENTION, [])).toEqual({
      mod: 'picker-manners',
      id: 'question',
      chip: 'Retention',
      question: RETENTION.question,
      options: [
        { button: 'opt1', label: '7 days', description: 'Covers a long weekend and a week away.' },
        { button: 'opt2', label: '30 days', description: 'Keeps a month of history for the goals pane.' },
      ],
    })
  })
  test('an option with no description carries none', () => {
    const q: Question = { ...RETENTION, options: [{ label: 'Yes' }, { label: 'No', description: '' }] }
    expect(askOf(q, []).options).toEqual([
      { button: 'opt1', label: 'Yes' },
      { button: 'opt2', label: 'No' },
    ])
  })
  test('a multi select question marks what is chosen and ends with Submit', () => {
    const ask = askOf({ ...RETENTION, multiSelect: true }, ['30 days'])
    expect(ask.options.map(o => o.chosen === true)).toEqual([false, true])
    expect(ask.submit).toEqual({ button: 'submit', label: 'Submit' })
    expect(askOf(RETENTION, ['30 days']).submit).toBeUndefined()
  })
})

describe('refusal', () => {
  const ok = { quiet: false, source: undefined, talkedPast: 0 }
  test('one question per call (CLAUDE.md): two or more are refused', () => {
    expect(refusal([RETENTION, RETENTION], ok)).toBe('Ask one question per call: Dan answers pickers one at a time.')
    expect(refusal([RETENTION], ok)).toBeUndefined()
  })
  test('a next issue offer while Dan has turned them off is refused, naming how they come back', () => {
    expect(refusal([RETENTION], { ...ok, quiet: true, source: 'next-issue' })).toBe(
      'Dan turned off next issue pickers for this session (/pickers on brings them back). Give the suggestions as a plain list instead.',
    )
    expect(refusal([RETENTION], { ...ok, quiet: true, source: 'issue-review' })).toBeUndefined()
  })
  test('a question Dan talked past is asked again once, never more', () => {
    expect(refusal([RETENTION], { ...ok, talkedPast: 1 })).toBeUndefined()
    expect(refusal([RETENTION], { ...ok, talkedPast: 2 })).toBe('Dan has talked past or dismissed this question twice, so it is not asked again. Carry on from what he said.')
  })
})

// #703: the limit on asking again was keyed on the exact wording, and Claude rewords a question when
// it asks it again. The same question is the same text however it is spaced or punctuated, or the
// same chip over the same answers however the question itself is put.
describe('passedOver and recordPass', () => {
  test('a pass is counted against the question, and again on its next pass', () => {
    let passed: Passed[] = []
    expect(passedOver(RETENTION, passed)).toBe(0)
    passed = recordPass(RETENTION, passed)
    expect(passedOver(RETENTION, passed)).toBe(1)
    passed = recordPass(RETENTION, passed)
    expect(passedOver(RETENTION, passed)).toBe(2)
    expect(passed).toHaveLength(1)
  })
  test('the same question reworded counts as the same: the same text however it is written, or the same chip over the same answers', () => {
    const passed = recordPass(RETENTION, [])
    expect(passedOver({ ...RETENTION, question: "how long should the registry keep a closed session's record" }, passed)).toBe(1)
    expect(passedOver({ ...RETENTION, question: 'How long do you want closed sessions kept?' }, passed)).toBe(1)
    expect(passedOver({ ...RETENTION, question: 'How long do you want closed sessions kept?', options: [...RETENTION.options].reverse() }, passed)).toBe(1)
  })
  test('another question under the same chip, with other answers and other words, is a question of its own', () => {
    const passed = recordPass(RETENTION, [])
    expect(passedOver({ ...RETENTION, question: 'Which folder should it use?', options: [{ label: 'Home' }, { label: 'Scratch' }] }, passed)).toBe(0)
  })
})

describe('passesOver', () => {
  // Spec #615 point 3: after a dismissal or a talk past, the question is asked again once at most.
  test('a typed message and a dismissal each pass over the question; an answer does not', () => {
    expect(passesOver({ kind: 'message' })).toBe(true)
    expect(passesOver({ kind: 'withdrawn' })).toBe(true)
    expect(passesOver({ kind: 'answer', answer: 'x' })).toBe(false)
    expect(passesOver({ kind: 'prose', answers: ['x'] })).toBe(false)
  })
})

describe('proseAnswers', () => {
  const two: Question[] = [RETENTION, { ...RETENTION, question: 'Which window?', header: 'Window' }]
  test('numbered answers on one line or several map onto the open questions in order', () => {
    expect(proseAnswers('1. yes 2. 7 days', two)).toEqual(['yes', '7 days'])
    expect(proseAnswers('1) yes\n2) 7 days\n', two)).toEqual(['yes', '7 days'])
  })
  test('fewer answers than questions map the ones given', () => {
    expect(proseAnswers('1. 30 days', two)).toEqual(['30 days'])
  })
  test('anything else is a message, not an answer: unnumbered text, numbers out of order, or more answers than questions', () => {
    expect(proseAnswers('wait, what does 7 days cover?', two)).toBeUndefined()
    expect(proseAnswers('2. yes 1. no', two)).toBeUndefined()
    expect(proseAnswers('1. yes 2. no 3. maybe', two)).toBeUndefined()
    expect(proseAnswers('I think 1. is fine', two)).toBeUndefined()
  })
})

describe('echoOf', () => {
  test('one line per question answered, by its chip', () => {
    expect(echoOf([RETENTION, { ...RETENTION, header: 'Window' }], ['yes', '7 days'])).toEqual(['Q1 Retention: yes', 'Q2 Window: 7 days'])
  })
})

describe('asksQuiet', () => {
  test('"no next issue" and "just give me the list" turn next issue pickers off', () => {
    expect(asksQuiet('No next issue please')).toBe(true)
    expect(asksQuiet('just give me the list')).toBe(true)
    expect(asksQuiet('Just give me the list.')).toBe(true)
  })
  test('ordinary messages do not', () => {
    expect(asksQuiet('give me the next issue')).toBe(false)
    expect(asksQuiet('list the files')).toBe(false)
  })
})

describe('onAbort', () => {
  test('an interrupted call runs its withdrawal once, when the signal aborts', () => {
    const c = new AbortController()
    let n = 0
    onAbort(c.signal, () => n++)
    expect(n).toBe(0)
    c.abort()
    c.abort()
    expect(n).toBe(1)
  })
  test('a signal already aborted withdraws at once, and no signal at all is no withdrawal', () => {
    let n = 0
    onAbort(AbortSignal.abort(), () => n++)
    expect(n).toBe(1)
    onAbort(undefined, () => n++)
    expect(n).toBe(1)
  })
})

describe('refusalFor', () => {
  test('a withdrawn question and a typed message each tell Claude what happened, and an answer is no refusal', () => {
    expect(refusalFor({ kind: 'withdrawn' }, 0)).toBe('The question was withdrawn: the turn was interrupted.')
    expect(refusalFor({ kind: 'message' }, 0)).toBe('Dan did not pick an answer: he is sending a message instead, which follows. Answer his message first.')
    expect(refusalFor({ kind: 'answer', answer: 'x' }, 0)).toBeUndefined()
    expect(refusalFor({ kind: 'prose', answers: ['x'] }, 1)).toBeUndefined()
  })
  test('after the first pass Claude may ask once more; after the second it is told not to', () => {
    expect(refusalFor({ kind: 'message' }, 1)).toBe(
      'Dan did not pick an answer: he is sending a message instead, which follows. Answer his message first. If this question is still unanswered after that, ask it again once; never more than once.',
    )
    // #703: the second pass still said "ask it again once", and the mod then refused that asking.
    expect(refusalFor({ kind: 'message' }, 2)).toBe(
      'Dan did not pick an answer: he is sending a message instead, which follows. Answer his message first. He has now talked past or dismissed this question twice, so do not ask it again: carry on from what he says.',
    )
    expect(refusalFor({ kind: 'withdrawn' }, 2)).toMatch(/^The question was withdrawn: the turn was interrupted\. He has now talked past or dismissed this question twice, so do not ask it again/)
  })
})

describe('bandEverywhere', () => {
  // #703: the band is drawn on the terminal and the desktop alone, so a question put there in a
  // claude -p run, or while Dan is on his phone, could never be answered.
  test('true only when every surface the session draws on has the band', () => {
    expect(bandEverywhere(['terminal'])).toBe(true)
    expect(bandEverywhere(['terminal', 'desktop'])).toBe(true)
    expect(bandEverywhere(['terminal', 'mobile'])).toBe(false)
    expect(bandEverywhere(['vscode'])).toBe(false)
    expect(bandEverywhere([])).toBe(false)
    expect(bandEverywhere(null)).toBe(false)
  })
})
