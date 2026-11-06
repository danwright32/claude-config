import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { SETTLED_QUESTION, SETTLED_SOURCE, SKIP_QUESTION, SKIP_SOURCE } from '../hooks/rules.ts'
import { DESIGN_SETTLED_QUESTION, DESIGN_SETTLED_SOURCE, DESIGN_SKIP_QUESTION, DESIGN_SKIP_SOURCE, guardAsks } from '../hooks/mod-kit/designquestions.ts'

// #2253: picker manners leaves a question in this guard's words off its issue unless it carries the
// guard's source, reading mod-kit's designquestions.ts, the copy this guard's own source check
// reads too. The guard's words are still its own (rules.ts), so the two are held to agree here: a
// wording or source changed on one side alone would let picker manners record an answer the guard
// never read as settled.
test("the guard's questions and sources are the ones mod-kit's shared reader names (#2253)", () => {
  expect([SKIP_QUESTION, SETTLED_QUESTION, SKIP_SOURCE, SETTLED_SOURCE]).toEqual([DESIGN_SKIP_QUESTION, DESIGN_SETTLED_QUESTION, DESIGN_SKIP_SOURCE, DESIGN_SETTLED_SOURCE])
})

test('the guard answers only a question asked under its own sources (#2253)', () => {
  expect(guardAsks(`${SKIP_SOURCE}:toolu_1`)).toBe(true)
  expect(guardAsks(SETTLED_SOURCE)).toBe(true)
  expect(guardAsks(SKIP_SOURCE)).toBe(false)
  expect(guardAsks(undefined)).toBe(false)
})
