import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { asksQuiet, issuesNamedIn, refusal, unreadRefusal, writtenOnIssue } from '../hooks/pickers.ts'

const RETENTION = {
  question: "How long should the registry keep a closed session's record?",
  header: 'Retention',
  multiSelect: false,
  options: [{ label: '7 days' }, { label: '30 days' }],
}

describe('refusal', () => {
  const ok = { quiet: false, source: undefined }
  test('one question per call (CLAUDE.md): two or more are refused, and so is none', () => {
    expect(refusal([RETENTION, RETENTION], ok)).toBe('Ask one question per call: Dan answers pickers one at a time.')
    expect(refusal([], ok)).toBe('Ask one question per call: Dan answers pickers one at a time.')
    expect(refusal([RETENTION], ok)).toBeUndefined()
  })
  test('a next issue offer while Dan has turned them off is refused, naming how they come back', () => {
    expect(refusal([RETENTION], { quiet: true, source: 'next-issue' })).toBe(
      'Dan turned off next issue pickers for this session (/pickers on brings them back). Give the suggestions as a plain list instead.',
    )
    expect(refusal([RETENTION], { quiet: true, source: 'issue-review' })).toBeUndefined()
    expect(refusal([RETENTION], { quiet: false, source: 'next-issue' })).toBeUndefined()
  })
})

// #3321: the one rule of which pickers this mod writes onto an issue, read by the hook and by the
// count of past pickers (tools/picker-check-count.ts), so the number is the code's own (L107).
describe('writtenOnIssue', () => {
  test('a question naming an issue is written onto it, by either spelling', () => {
    expect(writtenOnIssue('Keep the old flag for issue #12?', undefined)).toBe(true)
    expect(writtenOnIssue('o/r#7: Keep the old flag?', 'issue-review')).toBe(true)
    expect(issuesNamedIn('o/r#7 and issue #12')).toEqual(['o/r#7', 'issue #12'])
  })
  test('one naming no issue, or none at all, is not', () => {
    expect(writtenOnIssue('Keep the old flag?', undefined)).toBe(false)
    expect(writtenOnIssue('', undefined)).toBe(false)
  })
  test("the design round guard's own picker is the guard's to record, never written here", () => {
    expect(writtenOnIssue('Settled for issue #12?', 'design-round-guard:abc')).toBe(false)
    expect(writtenOnIssue('Settled for issue #12?', 'design-settled')).toBe(false)
  })
  test("a question in the guard's words asked without its source is written nowhere (#2253)", () => {
    expect(writtenOnIssue('Skip design rounds for issue #12?', undefined)).toBe(false)
    expect(writtenOnIssue('Skip design rounds for issue #12?', 'issue-review')).toBe(false)
  })
})

describe('unreadRefusal', () => {
  test('it leads with what is at fault, names the issue, and says what to change', () => {
    const said = unreadRefusal({ what: 'The question', fault: 'it holds a link' }, 'Keep the flag for issue #12 and o/r#7?')
    expect(said.startsWith('The question would not reach Dan as written: it holds a link.')).toBe(true)
    expect(said).toContain("o/r#7's, issue #12's Open questions")
    expect(said).toContain('Ask it again in plain words without what is at fault.')
  })
  test('one too long or too tall is told to be asked shorter, never to drop what is at fault', () => {
    for (const fault of ['it is 1800 UTF-16 code units, and the dialog shows text whole only up to 1500', 'it takes 30 rows in a window 76 columns wide, and text is asked only up to 20 rows']) {
      const said = unreadRefusal({ what: 'The question', fault }, 'Keep the flag for issue #12?')
      expect(said).toContain('Ask it again shorter')
      expect(said).not.toContain('without what is at fault')
    }
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
