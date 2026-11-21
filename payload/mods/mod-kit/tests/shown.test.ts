import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { MAX_QUESTION, MAX_QUESTION_ROWS, QUESTION_COLUMNS, askFault, rowsAt, shownFault, unindented, unseenIn } from '../hooks/shown.ts'

// Text a person approves in a picker (#3321): the one check every guard that records a picker's
// answer runs its call through, moved here from the lesson picker (#3295), whose own suite still
// holds each rule in full through the names it hands on. These hold the file as mod-kit's: every
// kind of refusal, each with the text that stands just inside it, and the whole call a guard hands
// over. No character refused here is written in this file: each is made from its code point.

const at = (point: number) => String.fromCodePoint(point)
const call = (top: Record<string, unknown> = {}, q: Record<string, unknown> = {}) => ({
  ...top,
  questions: [{ question: 'Let this edit go ahead without a round?', header: 'Design', options: [{ label: 'Yes', description: 'This once.' }, { label: 'No', description: 'Hold it.' }], multiSelect: false, ...q }],
})

test('plain prose of any alphabet stands, with one blank line between paragraphs', () => {
  expect(shownFault('Let this edit go ahead without a round?')).toBeUndefined()
  expect(shownFault(`Caf${at(0xe9)} ${at(0x4e2d)}${at(0x6587)} ${at(0x1f600)}`)).toBeUndefined()
  expect(shownFault('One.\n\nTwo.\n\nThree.')).toBeUndefined()
  expect(shownFault('Run `git log <range>` first.')).toBeUndefined()
})

test('a character he cannot see is refused by its code point and its place, whichever class it is in', () => {
  const classes: [string, number, string][] = [
    ['zero width', 0x200b, 'a zero width space'],
    ['direction control', 0x202e, 'a bidirectional control'],
    ['control', 0x1b, 'the escape character, which starts a terminal escape sequence'],
    ['tab inside a line', 0x09, 'a tab'],
    ['format', 0xad, 'a soft hyphen'],
    ['space that is not the plain one', 0xa0, 'a no break space'],
    ['tag block', 0xe0041, 'a tag character'],
    ['variation selector', 0xfe0f, 'a variation selector'],
    ['private use', 0xe000, 'a private use character'],
  ]
  for (const [name, point, what] of classes) {
    expect(`${name}: ${unseenIn(`ab${at(point)}cd`)?.what}`).toBe(`${name}: ${what}`)
    expect(`${name}: ${shownFault(`ab${at(point)}cd`)}`).toContain(`${name}: character 3 of it is U+`)
  }
  // Indentation at a line's two ends is the text's own and is not judged.
  expect(shownFault('One.\n\tTwo.  ')).toBeUndefined()
  expect(unindented('\t  x \t')).toBe('x')
})

test('text past what the dialog shows whole is refused, and text at the limit stands', () => {
  const prose = 'word '.repeat(MAX_QUESTION / 5)
  expect(prose.length).toBe(MAX_QUESTION)
  expect(shownFault(prose)).toBeUndefined()
  expect(shownFault(`${prose}.`)).toBe(`it is ${MAX_QUESTION + 1} UTF-16 code units, and the dialog shows text whole only up to ${MAX_QUESTION}`)
  // The dialog cuts at 2,000, so the limit is under it.
  expect(MAX_QUESTION).toBeLessThan(2000)
})

test('markup a surface hides or redraws is refused: a tag, a link, a definition, a character reference, a link to a file', () => {
  expect(shownFault('ok <x hidden words> ok')).toContain('it holds "<x" at character 4, which a surface that draws HTML takes for a tag or a comment and does not draw')
  expect(shownFault('See [the notes](x).')).toContain('which a surface that draws markdown takes for a link, an image or a link definition and draws as less than its text')
  expect(shownFault('[1]: hidden words')).toContain('it holds "]:" at character 3')
  expect(shownFault('a&nbsp;b')).toContain('it holds "&nbsp;" at character 2, which a surface that draws markdown draws as another character')
  // Code on one line hides nothing, but a link to a file is drawn as its label alone even there.
  expect(shownFault('Run `[the notes](file:///etc/hosts)` first.')).toBe('it holds "](file:" at character 16, a link to a file, which the terminal dialog can draw as its label alone')
  // Bold marks cannot split what is refused.
  expect(shownFault('See [the notes]**(x)**.')).toContain('with its bold marks dropped, as it is stored, it holds ')
})

test('a tall question is refused: a run of blank lines, and more rows than the limit as a narrow window wraps', () => {
  expect(shownFault('One.\n\n\nTwo.')).toBe('lines 2 and 3 of it are both blank, and a run of blank lines pushes what stands above it away from the answers')
  const lines = Array.from({ length: MAX_QUESTION_ROWS }, (_, k) => `Line ${k + 1}.`).join('\n')
  expect(shownFault(lines)).toBeUndefined()
  expect(shownFault(`${lines}\nOne more.`)).toBe(`it takes ${MAX_QUESTION_ROWS + 1} rows in a window ${QUESTION_COLUMNS} columns wide, and text is asked only up to ${MAX_QUESTION_ROWS} rows, so that no part of it is far above the answers`)
  expect(rowsAt('x'.repeat(QUESTION_COLUMNS))).toBe(1)
  expect(rowsAt('x'.repeat(QUESTION_COLUMNS + 1))).toBe(2)
})

test('every text of a call is judged, in whatever field: the question, a field beside it, an answer, a field of the call', () => {
  const zw = at(0x200b)
  expect(askFault(call())).toBeUndefined()
  expect(askFault(call({}, { question: `Bad${zw}` }))?.what).toBe('The question')
  expect(askFault(call({}, { description: `Bad${zw}` }))?.what).toBe('Field "description" of the question')
  expect(askFault(call({}, { options: [{ label: 'Yes', description: `Bad${zw}` }] }))?.what).toBe('Field "options" of the question')
  expect(askFault(call({}, { header: `Bad${zw}` }))?.what).toBe('Field "header" of the question')
  expect(askFault(call({ title: `Bad${zw}` }))?.what).toBe('Field "title"')
  // A second question is text the dialog gets too.
  expect(askFault({ questions: [call().questions[0], { question: `Bad${zw}` }] })?.what).toBe('Field "questions"')
  // What is never drawn is not judged: the engine's own keys, the metadata, answers already filled in.
  expect(askFault(call({ tool_use_id: `t${zw}`, agentId: `a${zw}`, requestMeta: { x: `y${zw}` }, answers: { q: `a${zw}` }, metadata: { source: 'x', note: `n${zw}` } }))).toBeUndefined()
})

test('the rows above the answers are counted together, so a field beside the question cannot add the rows it may not take', () => {
  const twelve = Array.from({ length: 12 }, (_, k) => `Line ${k + 1}.`).join('\n')
  expect(askFault(call({}, { question: twelve, description: 'One helper line.' }))).toBeUndefined()
  expect(askFault(call({}, { question: twelve, description: twelve }))).toEqual({
    what: 'The question',
    fault: `with the other text sent beside it, it takes 24 rows in a window ${QUESTION_COLUMNS} columns wide, and text is asked only up to ${MAX_QUESTION_ROWS} rows, so that no part of it is far above the answers`,
  })
  // The answers are the dialog's own rows and are not counted with those above them.
  const options = Array.from({ length: 4 }, (_, k) => ({ label: `Answer ${k + 1}`, description: twelve.slice(0, 40) }))
  expect(askFault(call({}, { question: twelve, options }))).toBeUndefined()
})

test('a call with no question to read is judged as holding none, never thrown on', () => {
  expect(askFault({})).toBeUndefined()
  expect(askFault({ questions: 'not a list' })?.what ?? 'none').toBe('none')
  expect(askFault({ questions: [null] })).toBeUndefined()
  expect(askFault({ questions: [{ question: 7 }] })).toBeUndefined()
})
