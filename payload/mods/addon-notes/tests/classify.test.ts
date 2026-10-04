import { expect, test } from 'claude-code/testing'
import { isAddOnNote, isAmendment, resumeLine } from '../hooks/classify.ts'

// The phrases Dan used when he interrupted a step only to add scope, mined from his chats
// (claude-config#620). Each must read as an amendment after an interrupt.
const AMENDMENTS = [
  'also do a direct link to commission',
  'Also, include the old invoices',
  'and open it in bbedit',
  'And make it bold',
  'include links',
  'including the footer',
  'sorry keep going',
  'Sorry, carry on',
  'keep going',
  'carry on',
  'continue',
  'oh and add a test for the empty case',
  'ok also check the other Mac',
  'plus the README row',
  '+ add the tests too',
  'also, don’t touch the migrations',
]

// A genuine change of direction after an interrupt is never taken for an add-on.
const REDIRECTS = [
  'stop, do the README first instead',
  'no, use the other file',
  'actually never mind, revert that',
  'wait',
  'and stop there, I will finish it',
  'also scrap the second part',
  'cancel that',
  'forget it',
  'that is wrong, start over',
  'sorry, I meant the staging database',
  'do the issue list now',
  'what does this function do?',
]

test('every phrase Dan used to add scope reads as an amendment', () => {
  for (const text of AMENDMENTS) expect([text, isAmendment(text)]).toEqual([text, true])
})

test('a genuine redirect is never read as an amendment', () => {
  for (const text of REDIRECTS) expect([text, isAmendment(text)]).toEqual([text, false])
})

test('a long message is a new instruction, not a short reply', () => {
  const long = 'also ' + Array.from({ length: 45 }, (_, i) => `word${i}`).join(' ')
  expect(isAmendment(long)).toBe(false)
})

test('an empty or blank reply is no amendment', () => {
  expect(isAmendment('')).toBe(false)
  expect(isAmendment('   ')).toBe(false)
  expect(isAmendment('+')).toBe(false)
})

test('a note starting with + is an add-on', () => {
  expect(isAddOnNote('+ also link the commission')).toBe(true)
  expect(isAddOnNote('+include links')).toBe(true)
  expect(isAddOnNote('  + and open it in bbedit')).toBe(true)
})

test('a + note carrying a markdown bullet list is still an add-on (lessons review)', () => {
  expect(isAddOnNote('+ also add these links:\n- the commission page\n- the invoice')).toBe(true)
  expect(isAddOnNote('+ include\n  - indented bullet')).toBe(true)
})

test('a diff of additions only, or one with a hunk header, is still not an add-on', () => {
  expect(isAddOnNote('+const a = 1\n+const b = 2')).toBe(false)
  expect(isAddOnNote('+ fix this\n@@ -1,2 +1,2 @@')).toBe(false)
  expect(isAddOnNote('+ a\n-removed line')).toBe(false)
})

test('a + with nothing after it, a ++ or a pasted diff is not an add-on', () => {
  expect(isAddOnNote('+')).toBe(false)
  expect(isAddOnNote('+   ')).toBe(false)
  expect(isAddOnNote('++ counter')).toBe(false)
  expect(isAddOnNote('+import a from "a"\n-import b from "b"')).toBe(false)
  expect(isAddOnNote('+1')).toBe(false)
  expect(isAddOnNote('also link it')).toBe(false)
})

test('the resume line is the first line of a reply when it has the agreed shape', () => {
  expect(resumeLine('+ add-on: Adding a direct link to the commission and carrying on.\n\nDone.')).toEqual({
    line: '+ add-on: Adding a direct link to the commission and carrying on.',
    rest: 'Done.',
  })
  expect(resumeLine('+ add-on: Carrying on.')).toEqual({ line: '+ add-on: Carrying on.', rest: '' })
  expect(resumeLine('Here is the plan.\n+ add-on: x')).toBeUndefined()
  expect(resumeLine('+ add-on:')).toBeUndefined()
})
