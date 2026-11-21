import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { recordsAnswer, unreadMorningPicker } from '../hooks/unread.ts'

// #3321: sleep mode records Dan's answer to a morning picker naming a number this session offered,
// so such a picker is held to the one check of text a person approves in a picker before he is
// asked. The refused character is made from its code point, never written here.

const zw = String.fromCodePoint(0x200b)
const none: ReadonlySet<string> = new Set()
const asked: ReadonlySet<string> = new Set(['3.1', '3.2'])
const offered: ReadonlySet<string> = new Set(['1.1', '1.2'])
const question = (text: string, labels: string[] = ['Keep it', 'Drop it']) => ({ question: text, header: 'Morning', multiSelect: false, options: labels.map(label => ({ label, description: 'What it does.' })) })

test('a picker is one whose answer is recorded only when it names a number this session offered', () => {
  expect(recordsAnswer([question('3.1 Keep the old export flag?')], asked, none)).toBe(true)
  expect(recordsAnswer([question('File these?', ['1.2 Rename the flag', 'None'])], none, offered)).toBe(true)
  // A second question of the call counts as the first does.
  expect(recordsAnswer([question('Anything else?'), question('3.2 Drop the table?')], asked, none)).toBe(true)
  // A number nobody offered, a number mid sentence, and a picker of no number record nothing.
  expect(recordsAnswer([question('3.9 Keep the old export flag?')], asked, offered)).toBe(false)
  expect(recordsAnswer([question('About 3.1: keep the old export flag?')], asked, offered)).toBe(false)
  expect(recordsAnswer([question('File these?', ['1.9 Rename the flag'])], asked, offered)).toBe(false)
  expect(recordsAnswer([question('Keep the old export flag?')], asked, offered)).toBe(false)
  // With nothing offered this session, and with no list of questions, nothing is recorded.
  expect(recordsAnswer([question('3.1 Keep the old export flag?')], none, none)).toBe(false)
  expect(recordsAnswer(undefined, asked, offered)).toBe(false)
  expect(recordsAnswer('3.1 not a list', asked, offered)).toBe(false)
})

test('a recorded picker he could not read as written is refused, in words that say what is at fault and how to ask', () => {
  const refused = unreadMorningPicker({ questions: [question(`3.1 Keep the old${zw} export flag?`)] }, asked, none)
  expect(refused).toContain('The question would not reach Dan as written: character 17 of it is U+200B, a zero width space')
  expect(refused).toContain('nothing was asked and nothing is recorded')
  expect(refused).toContain('in more than one picker')
  // Every field the dialog gets is judged: an answer, a field beside the questions, a second question.
  expect(unreadMorningPicker({ questions: [question('File these?', [`1.1 Rename${zw} the flag`])] }, none, offered)).toContain('Field "options" of the question would not reach Dan as written')
  expect(unreadMorningPicker({ title: `Morning${zw}`, questions: [question('3.1 Keep the old export flag?')] }, asked, none)).toContain('Field "title" would not reach Dan as written')
  expect(unreadMorningPicker({ questions: [question('3.1 Keep the old export flag?'), question(`And${zw} this?`)] }, asked, none)).toContain('Field "questions" would not reach Dan as written')
  // Too long for the dialog to show whole, and markup a surface hides.
  expect(unreadMorningPicker({ questions: [question(`3.1 ${'word '.repeat(400)}`)] }, asked, none)).toContain('UTF-16 code units')
  expect(unreadMorningPicker({ questions: [question('3.1 Keep <flag> as it is?')] }, asked, none)).toContain('it holds "<flag>"')
})

test('a picker he can read, and one whose answer is not recorded here, are let through', () => {
  expect(unreadMorningPicker({ questions: [question('3.1 Keep the old export flag?')] }, asked, offered)).toBeUndefined()
  expect(unreadMorningPicker({ questions: [question('File these?', ['1.1 Rename the flag', '1.2 Drop the table'])] }, asked, offered)).toBeUndefined()
  // Not this mod's to judge: nothing is recorded from it.
  expect(unreadMorningPicker({ questions: [question(`Keep the old${zw} export flag?`)] }, asked, offered)).toBeUndefined()
  expect(unreadMorningPicker({ questions: [question(`3.1 Keep the old${zw} export flag?`)] }, none, none)).toBeUndefined()
  expect(unreadMorningPicker({}, asked, offered)).toBeUndefined()
})
