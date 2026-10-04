import { describe, expect, test } from 'claude-code/testing'
import { asksQuiet, bandLines, echoOf, proseAnswers, refusal } from '../hooks/pickers.ts'
import type { Question } from '../hooks/pickers.ts'

const RETENTION: Question = {
  question: "How long should the registry keep a closed session's record?",
  header: 'Retention',
  multiSelect: false,
  options: [
    { label: '7 days', description: 'Covers a long weekend and a week away.' },
    { label: '30 days', description: 'Keeps a month of history for the goals pane.' },
  ],
}

describe('bandLines', () => {
  test('the grey chip and the amber question on one line, then each option on its own line with its description indented under it', () => {
    expect(bandLines(RETENTION, [])).toEqual([
      [{ text: '[Retention] ', dim: true }, { text: RETENTION.question, color: 'warning', bold: true }],
      [{ text: '1. ' }, { button: 'opt1', label: '7 days', hotkey: '1' }],
      [{ text: 'Covers a long weekend and a week away.', dim: true, indent: 3 }],
      [{ text: '2. ' }, { button: 'opt2', label: '30 days', hotkey: '2' }],
      [{ text: 'Keeps a month of history for the goals pane.', dim: true, indent: 3 }],
    ])
  })
  test('an option with no description has no line under it', () => {
    const q: Question = { ...RETENTION, options: [{ label: 'Yes' }, { label: 'No', description: '' }] }
    expect(bandLines(q, []).length).toBe(3)
  })
  test('a multi select question marks what is chosen and ends with Submit', () => {
    const q: Question = { ...RETENTION, multiSelect: true }
    const lines = bandLines(q, ['30 days'])
    expect(lines[1]).toEqual([{ text: '1. ' }, { button: 'opt1', label: '7 days', hotkey: '1' }])
    expect(lines[3]).toEqual([{ text: '2. ' }, { button: 'opt2', label: '30 days', hotkey: '2' }, { text: ' chosen', dim: true }])
    expect(lines[lines.length - 1]).toEqual([{ button: 'submit', label: 'Submit' }])
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
    expect(refusal([RETENTION], { ...ok, talkedPast: 2 })).toBe('Dan has talked past this question twice, so it is not asked again. Carry on from what he said.')
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
