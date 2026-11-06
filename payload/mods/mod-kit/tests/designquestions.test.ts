import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { DESIGN_SETTLED_QUESTION, DESIGN_SETTLED_SOURCE, DESIGN_SKIP_QUESTION, DESIGN_SKIP_SOURCE, guardAsks, guardIgnores, guardQuestion } from '../hooks/designquestions.ts'

// #2253: the design round guard counts Dan's answer only from its own picker, a question asked with
// its metadata source. On 2026-11-04 a plain question in the guard's words was answered Skip them,
// picker manners checked it off on the issue, and the guard refused the next edit anyway. One place
// says which questions the guard asks, so the guard and the recorder read the same rule.

// The sentence the guard composes, copied into a plain question on 2026-11-04 (names invented).
const COPIED = `The sign in button gets a new colour. ${DESIGN_SKIP_QUESTION} This is for issue #12 in o/r; the file is app/SignIn.tsx.`

test("the guard asks only under its own sources, the skip one carrying a refused call's id (#2253)", () => {
  expect(guardAsks(`${DESIGN_SKIP_SOURCE}:toolu_1`)).toBe(true)
  expect(guardAsks(DESIGN_SETTLED_SOURCE)).toBe(true)
  // The guard passes these through untouched, so it asks none of them.
  expect(guardAsks(DESIGN_SKIP_SOURCE)).toBe(false)
  expect(guardAsks(`x${DESIGN_SKIP_SOURCE}:toolu_1`)).toBe(false)
  expect(guardAsks('next-issue')).toBe(false)
  expect(guardAsks(undefined)).toBe(false)
  expect(guardAsks(7)).toBe(false)
})

test('a question in the guard words asked without its source is one the guard ignores (#2253)', () => {
  expect(guardIgnores(COPIED, undefined)).toBe(true)
  expect(guardIgnores(DESIGN_SKIP_QUESTION, 'next-issue')).toBe(true)
  expect(guardIgnores(DESIGN_SETTLED_QUESTION, undefined)).toBe(true)
  // A rewording, any case, and a source that only looks like the guard's.
  expect(guardIgnores('Skip design rounds for issue #12?', undefined)).toBe(true)
  expect(guardIgnores('o/r#12: skip the design round for the sign in button?', undefined)).toBe(true)
  expect(guardIgnores('is this  design settled?', undefined)).toBe(true)
  expect(guardIgnores(COPIED, DESIGN_SKIP_SOURCE)).toBe(true)
})

test("the guard's own picker, and a question about anything else, are not ignored (#2253)", () => {
  expect(guardIgnores(COPIED, `${DESIGN_SKIP_SOURCE}:toolu_1`)).toBe(false)
  expect(guardIgnores(DESIGN_SETTLED_QUESTION, DESIGN_SETTLED_SOURCE)).toBe(false)
  expect(guardIgnores('For o/r#7, keep the old flag?', undefined)).toBe(false)
  expect(guardIgnores('Run design rounds on the settings screen next?', undefined)).toBe(false)
  expect(guardIgnores('Is the API design settled enough to build on?', undefined)).toBe(false)
})

test("a guard question is told by its words alone, whatever asked it, as /sleep reads an issue's items (#2261)", () => {
  expect(guardQuestion(DESIGN_SKIP_QUESTION)).toBe(true)
  expect(guardQuestion(DESIGN_SETTLED_QUESTION)).toBe(true)
  expect(guardQuestion(COPIED)).toBe(true)
  expect(guardQuestion('o/r#12: skip the design round for the sign in button?')).toBe(true)
  expect(guardQuestion('Keep the old flag?')).toBe(false)
  expect(guardQuestion('Run design rounds on the settings screen next?')).toBe(false)
  expect(guardQuestion('Is the API design settled enough to build on?')).toBe(false)
})
