import { describe, expect, test } from 'claude-code/testing'
import {
  KINDS,
  LONG_WORDS,
  MIN_WORDS,
  REPORT_EVERY_MS,
  TECH_SHARE,
  judge,
  kindOf,
  measure,
  pressAt,
  pressKey,
  replyHead,
  requestText,
  sameReply,
  weeklyLine,
} from '../hooks/simpler.ts'

const prose = (n: number, word = 'the') => Array.from({ length: n }, () => word).join(' ')
// The two dashes the writing rule forbids, built from their code points so this file holds neither.
const DASHES = new RegExp(`[${String.fromCharCode(0x2014, 0x2013)}]`)

describe('the threshold', () => {
  test('an answer over the length threshold gets the button, one at it does not', () => {
    expect(judge(prose(LONG_WORDS + 1))?.reason).toBe('long')
    expect(judge(prose(LONG_WORDS))).toBeNull()
  })

  test('a short plain answer gets no button', () => {
    expect(judge('Done. The PR is merged and the deploy finished.')).toBeNull()
    expect(judge('')).toBeNull()
  })

  test('a mid length answer heavy in technical terms gets the button', () => {
    // 100 words, a fifth of them identifiers, paths, flags and issue numbers.
    const tech = Array.from({ length: 20 }, (_, i) => ['`$.store.get`', 'register.tsx', 'isFirstOfReply', '#619', '--squash'][i % 5]).join(' ')
    const text = `${prose(80, 'word')} ${tech}`
    expect(measure(text).words).toBe(100)
    expect(measure(text).technical).toBe(20)
    expect(judge(text)?.reason).toBe('technical')
  })

  test('a mid length answer just under the technical share gets no button, just at it gets one', () => {
    const words = 100
    const at = Math.ceil(words * TECH_SHARE)
    const make = (n: number) => `${prose(words - n, 'word')} ${Array.from({ length: n }, () => 'snake_case').join(' ')}`
    expect(measure(make(at)).words).toBe(words)
    expect(judge(make(at))?.reason).toBe('technical')
    expect(judge(make(at - 1))).toBeNull()
  })

  test('the same share of technical terms in an answer under the minimum gets no button', () => {
    const text = `${prose(MIN_WORDS - 20, 'word')} ${Array.from({ length: 18 }, () => 'snake_case').join(' ')}`
    expect(measure(text).words).toBeLessThan(MIN_WORDS)
    expect(judge(text)).toBeNull()
  })

  test('a mid length answer in plain prose gets no button', () => {
    const text = 'I looked at how the button decides when to show. '.repeat(15)
    expect(measure(text).words).toBeGreaterThanOrEqual(MIN_WORDS)
    expect(measure(text).words).toBeLessThanOrEqual(LONG_WORDS)
    expect(judge(text)).toBeNull()
  })

  test('each line of a code block counts as a technical term and is not read as prose', () => {
    const fence = '```ts\nconst a = 1\nconst b = 2\n\nreturn a + b\n```'
    const m = measure(`${prose(10, 'word')}\n${fence}`)
    expect(m.technical).toBe(3)
    expect(m.words).toBe(13)
  })

  test('ordinary capitals and words with full stops are not technical terms', () => {
    expect(measure('I think OK, the PR in ET is fine. It ended, e.g. at noon.').technical).toBe(0)
  })
})

describe('the kind of answer', () => {
  test('every kind has a singular and plural name, one list for the log and the weekly line', () => {
    for (const k of KINDS) {
      expect(k.one.length).toBeGreaterThan(0)
      expect(k.many.length).toBeGreaterThan(0)
    }
    expect(KINDS.map(k => k.kind)).toEqual(['design', 'plan', 'diagnosis', 'status', 'explanation'])
  })

  test('reads the kind from what the answer is mostly about', () => {
    expect(kindOf('There are two options. The trade-off between the approaches: I recommend option B.')).toBe('design')
    expect(kindOf('Plan:\n1. Write the test\n2. Build it\n3. Ship the phase')).toBe('plan')
    expect(kindOf('The root cause of the bug: the test was failing because the error was swallowed.')).toBe('diagnosis')
    expect(kindOf('Merged and pushed. CI is green and it deployed.')).toBe('status')
    expect(kindOf('Here is how sync carries a file between the two Macs.')).toBe('explanation')
  })

  test('the judgement carries the kind and the word count', () => {
    const j = judge(`There are two options and a trade-off. ${prose(LONG_WORDS)}`)
    expect(j).toMatchObject({ reason: 'long', kind: 'design' })
    expect(j?.words).toBeGreaterThan(LONG_WORDS)
  })
})

describe('matching the reply drawn to the answer judged', () => {
  test('the first block of the answer matches, whatever its whitespace', () => {
    const answer = `First paragraph of the answer.\n\nSecond   paragraph. ${prose(300)}`
    expect(sameReply(replyHead(answer), 'First paragraph of the answer.\n\nSecond paragraph.')).toBe(true)
    expect(sameReply(replyHead(answer), answer)).toBe(true)
  })

  test('an earlier reply does not match', () => {
    expect(sameReply(replyHead(`The latest answer. ${prose(300)}`), 'An earlier answer.')).toBe(false)
    expect(sameReply(replyHead(`The latest answer. ${prose(300)}`), '   ')).toBe(false)
  })
})

describe('the request a press submits', () => {
  test('asks for 2 to 3 plain sentences, the open decision restated, one example from the project, the long version kept', () => {
    const t = requestText('Bidspoke')
    expect(t).toContain('2 to 3 plain sentences')
    expect(t).toContain('decision')
    expect(t).toContain('one concrete example from Bidspoke')
    expect(t).toMatch(/long version/)
  })

  test('without a project name it still asks for an example from the project', () => {
    expect(requestText(undefined)).toContain('one concrete example from this project')
  })

  test('carries no dash used as punctuation', () => {
    expect(requestText('x')).not.toMatch(DASHES)
    expect(requestText('x')).not.toMatch(/\s-\s/)
  })
})

describe('the press log', () => {
  test('a key carries the time it was pressed, and reads back', () => {
    const k = pressKey(1234, 'ab')
    expect(k).toBe('press:1234:ab')
    expect(pressAt(k)).toBe(1234)
    expect(pressAt('reportedAt')).toBeUndefined()
    expect(pressAt('press:x:ab')).toBeUndefined()
  })
})

describe('the weekly count', () => {
  test('is reported once a week', () => {
    expect(REPORT_EVERY_MS).toBe(7 * 24 * 60 * 60 * 1000)
  })

  test('names which kinds needed simplifying, most first', () => {
    expect(weeklyLine(['plan', 'design', 'design', 'diagnosis'], 7)).toBe(
      'Simpler was pressed 4 times in the last 7 days: after 2 design answers, 1 plan and 1 diagnosis.',
    )
  })

  test('one press reads in the singular', () => {
    expect(weeklyLine(['status'], 8)).toBe('Simpler was pressed once in the last 8 days: after 1 status report.')
  })

  test('says so when it was not pressed', () => {
    expect(weeklyLine([], 7)).toBe('Simpler was not pressed in the last 7 days.')
  })
})
