import { expect, test } from 'claude-code/testing'
import { etDateOf, issueRefsIn, openQuestionsIn, questionWords, withQuestion } from '../hooks/openquestions.ts'

// #1279, Dan 2026-10-17: every issue's body holds an "Open questions" section (the filing gate
// refuses one without it), listing what only Dan can decide, or None. /sleep asks every open item in
// its goal issues' sections before the night begins, and a question Dan is asked about an issue is
// added there. One reader and one writer of the section, kept here, copied byte for byte into the
// mods that use it (scope-modes asks and checks off, picker-manners adds), so the two cannot drift.
const SESSION = 'Claude-Session: https://claude.ai/code/session_01AbCdEf'

test('the open items of a section: unchecked boxes and plain bullets, never a checked one, never None', () => {
  const body = ['The bug.', '', '## Open questions', '', '- [ ] Keep the old flag?', '- [x] Rename it? (answered 2026-10-16 ET: Yes)', '* Which copy?', '', '## Notes', '- not a question', '', SESSION].join('\n')
  expect(openQuestionsIn(body)).toEqual({ found: true, open: ['Keep the old flag?', 'Which copy?'] })
  expect(openQuestionsIn('B\n\n### Open questions\nNone\n')).toEqual({ found: true, open: [] })
  expect(openQuestionsIn('B\n\n## Open Questions\n\n- [ ] Lower case is the same heading?')).toEqual({ found: true, open: ['Lower case is the same heading?'] })
})

test('a body with no section, or the words only in a sentence, has none found', () => {
  expect(openQuestionsIn('Just the bug, no open questions here.')).toEqual({ found: false, open: [] })
  expect(openQuestionsIn('')).toEqual({ found: false, open: [] })
})

test('a question is added as an open item, in place of None, before what follows the section', () => {
  const body = ['The bug.', '', '## Open questions', '', 'None', '', SESSION].join('\n')
  expect(withQuestion(body, 'Keep the old flag?')).toBe(['The bug.', '', '## Open questions', '', '- [ ] Keep the old flag?', '', SESSION].join('\n'))
  const listed = ['B', '', '## Open questions', '- [ ] First?', '', '## Notes', 'n'].join('\n')
  expect(withQuestion(listed, 'Second?')).toBe(['B', '', '## Open questions', '- [ ] First?', '- [ ] Second?', '', '## Notes', 'n'].join('\n'))
})

test('a body with no section gets one, before its session line', () => {
  expect(withQuestion(['The bug.', '', SESSION].join('\n'), 'Keep it?')).toBe(['The bug.', '', '## Open questions', '', '- [ ] Keep it?', '', SESSION].join('\n'))
  expect(withQuestion('The bug.', 'Keep it?')).toBe(['The bug.', '', '## Open questions', '', '- [ ] Keep it?'].join('\n'))
})

test('an answer checks the item off, saying the answer and its date; asked again it changes nothing', () => {
  const body = ['B', '', '## Open questions', '', '- [ ] Keep the old flag?', '- [ ] Other?'].join('\n')
  const answered = withQuestion(body, 'Keep the old flag?', { answer: 'Drop it', date: '2026-10-17' })
  expect(answered).toBe(['B', '', '## Open questions', '', '- [x] Keep the old flag? (answered 2026-10-17 ET: Drop it)', '- [ ] Other?'].join('\n'))
  expect(openQuestionsIn(answered).open).toEqual(['Other?'])
  // Asked again, open or answered: already there, so nothing is added twice (assume it runs twice).
  expect(withQuestion(answered, 'Keep the old flag?')).toBe(answered)
  expect(withQuestion(answered, 'Keep the old flag?', { answer: 'Keep it', date: '2026-10-18' })).toBe(answered)
  expect(withQuestion(body, 'Other?')).toBe(body)
})

test('a question asked and answered at once is added already checked off', () => {
  expect(withQuestion('B\n\n## Open questions\n\nNone', 'Ship it?', { answer: 'Yes', date: '2026-10-17' })).toBe('B\n\n## Open questions\n\n- [x] Ship it? (answered 2026-10-17 ET: Yes)')
})

test('the issues a question to Dan is about: owner/name#N, or issue #N in the session\'s repository', () => {
  expect(issueRefsIn('Should o/r#7 keep the old flag?', null)).toEqual([{ repo: 'o/r', issue: 7 }])
  expect(issueRefsIn('Skip design rounds for issue #1279?', 'danwright32/claude-config')).toEqual([{ repo: 'danwright32/claude-config', issue: 1279 }])
  expect(issueRefsIn('For Issue #12 and o/other#3, which first?', 'o/r')).toEqual([{ repo: 'o/r', issue: 12 }, { repo: 'o/other', issue: 3 }])
  // A bare #N may be a pull request, so it names nothing; nor does issue #N with no repository known.
  expect(issueRefsIn('Merge PR #31?', 'o/r')).toEqual([])
  expect(issueRefsIn('Skip design rounds for issue #1279?', null)).toEqual([])
})

test("a question's words, without the issues /sleep puts in front of them", () => {
  expect(questionWords('o/r#7: Keep the old flag?')).toBe('Keep the old flag?')
  expect(questionWords('o/r#12 and #14: Keep the old flag?')).toBe('Keep the old flag?')
  expect(questionWords('Should o/r#7 keep it?')).toBe('Should o/r#7 keep it?')
})

test('the date an answer is given, in ET', () => {
  // 03:30 UTC on Oct 18 is still Oct 17 in New York.
  expect(etDateOf(Date.UTC(2026, 9, 18, 3, 30))).toBe('2026-10-17')
  expect(etDateOf(Date.UTC(2026, 9, 18, 5, 0))).toBe('2026-10-18')
})

test('a question on several lines is kept on one, so it stays one item', () => {
  expect(openQuestionsIn(withQuestion('B', 'First line\nsecond line?')).open).toEqual(['First line second line?'])
})
