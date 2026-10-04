import { expect, test } from 'claude-code/testing'
import { cleanName, hasExchange, namePrompt, renameOutcome } from '../hooks/name.ts'

// The two long dashes, built from their code points so this file holds neither character.
const EM = String.fromCharCode(0x2014)
const EN = String.fromCharCode(0x2013)
const OPEN_Q = String.fromCharCode(0x201c)
const CLOSE_Q = String.fromCharCode(0x201d)

test('a plain reply is kept as it is', async () => {
  expect(cleanName('Fix the invoice table layout')).toEqual({ name: 'Fix the invoice table layout' })
})

test('quotes, a label and a closing full stop are stripped', async () => {
  expect(cleanName('"Fix the invoice table layout."')).toEqual({ name: 'Fix the invoice table layout' })
  expect(cleanName(`Name: ${OPEN_Q}Auto session name mod${CLOSE_Q}`)).toEqual({ name: 'Auto session name mod' })
  expect(cleanName("'Rebuild the sync lock'")).toEqual({ name: 'Rebuild the sync lock' })
  expect(cleanName('`Collision guard tests`')).toEqual({ name: 'Collision guard tests' })
  expect(cleanName('**Collision guard tests**')).toEqual({ name: 'Collision guard tests' })
})

test('only the first line of a reply is used', async () => {
  expect(cleanName('\n  Session registry retention\nThis name says what the work is.')).toEqual({ name: 'Session registry retention' })
})

test('dashes used as punctuation become spaces, while a hyphen inside a word stays', async () => {
  expect(cleanName(`Status bar ${EM} band layout`)).toEqual({ name: 'Status bar band layout' })
  expect(cleanName(`Status bar${EM}band layout`)).toEqual({ name: 'Status bar band layout' })
  expect(cleanName(`Status bar ${EN} band layout`)).toEqual({ name: 'Status bar band layout' })
  expect(cleanName('Status bar - band layout')).toEqual({ name: 'Status bar band layout' })
  expect(cleanName('Fix two-way sync deletes')).toEqual({ name: 'Fix two-way sync deletes' })
})

test('an empty reply is refused, also one that is only quotes and punctuation', async () => {
  expect(cleanName('')).toEqual({ refused: 'empty' })
  expect(cleanName('   \n  ')).toEqual({ refused: 'empty' })
  expect(cleanName('""')).toEqual({ refused: 'empty' })
  expect(cleanName(EM)).toEqual({ refused: 'empty' })
})

test('a reply too long to be a name is refused, by words or by characters', async () => {
  expect(cleanName('This is a very long name that goes on well past six words')).toEqual({ refused: 'too-long' })
  expect(cleanName('Supercalifragilisticexpialidocious antidisestablishmentarianism reconfiguration')).toEqual({ refused: 'too-long' })
  // Eight words is the most kept: a little over the six asked for still names the work.
  expect(cleanName('One two three four five six seven eight')).toEqual({ name: 'One two three four five six seven eight' })
  expect(cleanName('One two three four five six seven eight nine')).toEqual({ refused: 'too-long' })
})

test('the prompt carries the opening request and the recent messages, each cut short', async () => {
  const long = 'x'.repeat(5000)
  const p = namePrompt([
    { role: 'user', text: 'Build the auto session name mod', toolUses: [] },
    { role: 'assistant', text: 'Reading the issue first.', toolUses: [] },
    { role: 'user', text: long, toolUses: [] },
  ])
  expect(p).toContain('Build the auto session name mod')
  expect(p).toContain('Reading the issue first.')
  expect(p).toContain('3 to 6 words')
  expect(p.length).toBeLessThan(6000)
})

test('the opening request is the first message the person wrote, not a tool result', async () => {
  const p = namePrompt([
    { role: 'user', text: '', toolUses: [] },
    { role: 'user', text: 'Rename the status bar items', toolUses: [] },
    { role: 'assistant', text: 'ok', toolUses: [] },
  ])
  expect(p).toContain('Opening request:\nRename the status bar items')
})

test('an exchange needs a request from the person and a reply', async () => {
  expect(hasExchange([])).toBe(false)
  expect(hasExchange([{ role: 'user', text: 'hello', toolUses: [] }])).toBe(false)
  expect(hasExchange([{ role: 'user', text: '', toolUses: [] }, { role: 'assistant', text: 'hi', toolUses: [] }])).toBe(false)
  expect(hasExchange([{ role: 'user', text: 'hello', toolUses: [] }, { role: 'assistant', text: 'hi', toolUses: [] }])).toBe(true)
})

test('the rename command answer is read by the shapes the built-in /rename prints', async () => {
  // Copied from the 2.1.289 build's /rename (its success and refusal messages).
  expect(renameOutcome('Session renamed to: Fix the invoice table')).toBe('set')
  expect(renameOutcome('Session renamed to: Fix the invoice table 2 ("Fix the invoice table" is held by another live session on this machine)')).toBe('set')
  expect(renameOutcome('Session is named: Other name (a newer rename landed first)')).toBe('set')
  expect(renameOutcome('Cannot rename: This session is a teammate. Teammate names are set by the team leader.')).toBe('refused')
  expect(renameOutcome('That name is empty once invisible characters are removed. Usage: /rename <name>')).toBe('refused')
  // Nothing printed as text, or anything else: it may or may not have taken, so it is checked later.
  expect(renameOutcome(undefined)).toBe('unknown')
  expect(renameOutcome('')).toBe('unknown')
  expect(renameOutcome('something new')).toBe('unknown')
})
