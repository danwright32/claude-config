import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import type {} from '../types/index.d.ts'

// Picker manners (#615) leaves the asking to Claude Code's own dialog (#744, decided with Dan on
// 2026-10-05): its band question waited for a press through the mod's own $ noun, which Claude Code
// cuts off at 10 seconds in a live session, so the dialog then asked every question a second time.
// What the mod still does: one question per call, and next issue pickers off for the session on
// request, back with /pickers on.

const QUESTION = {
  question: "How long should the registry keep a closed session's record?",
  header: 'Retention',
  multiSelect: false,
  options: [
    { label: '1 day', description: 'Smallest folder, but a Friday session is gone by Monday.' },
    { label: '7 days', description: 'Covers a long weekend and a week away.' },
  ],
}

// Claude Code beneath the mod: its own question dialog, the transcript's dim lines, the memory
// section of the system prompt, and the commands registered.
const world = (on: On) => {
  const logs: string[] = []
  const reachedEngine: string[] = []
  on('tool.call', ($, e) => {
    reachedEngine.push(String(e.tool))
    return { result: { questions: [], answers: { engine: 'picker' } } } as never
  })
  on('prompt.submit', ($, e) => ({ text: e.text }))
  on('prompt.section', ($, e) => ({ text: e.text }))
  on('ui.invalidate', () => ({ value: undefined }) as never)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('command.register', ($, e) => ({ value: { command: e.name } }) as never)
  on('ui.log', ($, e) => {
    logs.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  return { logs, reachedEngine }
}

type T$ = {
  tool: { call: (e: never) => Promise<unknown> }
  prompt: { submit: (e: never) => Promise<unknown>; section: (e: never) => Promise<{ text: string | null }> }
  session: { start: (e: never) => Promise<unknown> }
  command: { run: (e: never) => Promise<unknown> }
}
type Answered = { result?: { answers: Record<string, string> }; deny?: string; text?: string }
const ask = ($: T$, q: object = QUESTION, extra: object = {}) => $.tool.call({ tool: 'AskUserQuestion', tool_use_id: 'q1', questions: [q], ...extra } as never) as Promise<Answered>
const type = ($: T$, text: string, kind = 'composer') => $.prompt.submit({ text, origin: { kind }, wait: false } as never)
const memory = async ($: T$) => (await $.prompt.section({ name: 'memory', text: 'core memory' } as never)).text
const refused = (r: Answered) => r.deny ?? r.text

test("a question goes to Claude Code's own dialog, which asks it once", {}, async ($, on) => {
  const w = world(on)
  const r = await ask($ as never)
  expect(r.result?.answers).toEqual({ engine: 'picker' })
  expect(w.reachedEngine).toEqual(['AskUserQuestion'])
})

// The limit on asking a question again counted Dan passing over it in the band (#703), which is
// gone, so nothing counts a pass. One counted by an earlier build and left in the session's state
// is never acted on: the question is asked (L377).
test('a question counted as talked past twice by an earlier build is still asked', {}, async ($, on) => {
  const w = world(on)
  on('state.get', ($, e, next) => {
    if ((e as { key?: string }).key === 'passed') return { value: { value: [{ question: "how long should the registry keep a closed session s record", header: 'retention', count: 2 }], version: 2 } } as never
    return next(e)
  })
  const r = await ask($ as never)
  expect(r.result?.answers).toEqual({ engine: 'picker' })
  expect(w.reachedEngine).toEqual(['AskUserQuestion'])
})

test('more than one question in a call is refused, and so is none (one question per call)', {}, async ($, on) => {
  const w = world(on)
  const two = (await $.tool.call({ tool: 'AskUserQuestion', questions: [QUESTION, QUESTION] } as never)) as Answered
  expect(refused(two)).toBe('Ask one question per call: Dan answers pickers one at a time.')
  const none = (await $.tool.call({ tool: 'AskUserQuestion', questions: [] } as never)) as Answered
  expect(refused(none)).toBe('Ask one question per call: Dan answers pickers one at a time.')
  expect(w.reachedEngine).toEqual([])
})

test('"no next issue" silences next issue pickers for the session, other pickers still ask, and /pickers on restores them', {}, async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
  await type($ as never, 'no next issue, just stop there')
  expect(w.logs).toEqual(['Next issue pickers are off for this session; /pickers on brings them back.'])
  const offer = await ask($ as never, QUESTION, { metadata: { source: 'next-issue' } })
  expect(refused(offer)).toBe('Dan turned off next issue pickers for this session (/pickers on brings them back). Give the suggestions as a plain list instead.')
  expect(w.reachedEngine).toEqual([])
  // A hook driven picker (the end of turn issue review) still asks.
  expect((await ask($ as never, QUESTION, { metadata: { source: 'issue-review' } })).result?.answers).toEqual({ engine: 'picker' })
  expect(((await $.command.run({ command: 'pickers', args: 'on' } as never)) as { text?: string }).text).toBe('Next issue pickers are back on.')
  expect((await ask($ as never, QUESTION, { metadata: { source: 'next-issue' } })).result?.answers).toEqual({ engine: 'picker' })
  expect(w.reachedEngine).toEqual(['AskUserQuestion', 'AskUserQuestion'])
})

// #703: Dan's messages from his phone through Remote Control count as his own, as in every mod.
test('"just give me the list" from his phone counts as his own, and a peer session saying it does not', {}, async ($, on) => {
  world(on)
  await type($ as never, 'just give me the list', 'peer')
  expect((await ask($ as never, QUESTION, { metadata: { source: 'next-issue' } })).result?.answers).toEqual({ engine: 'picker' })
  await type($ as never, 'just give me the list', 'bridge')
  expect(refused(await ask($ as never, QUESTION, { metadata: { source: 'next-issue' } }))).toMatch(/^Dan turned off next issue pickers/)
})

test('/pickers with anything but on changes nothing and says what it understands', {}, async ($, on) => {
  world(on)
  await type($ as never, 'no next issue')
  expect(((await $.command.run({ command: 'pickers', args: 'off' } as never)) as { text?: string }).text).toBe('/pickers on brings next issue pickers back; nothing else is understood.')
  expect(refused(await ask($ as never, QUESTION, { metadata: { source: 'next-issue' } }))).toMatch(/^Dan turned off next issue pickers/)
})

// #703: CLAUDE.md's keep the issue loop moving rule has Claude offer next issues as a picker, and an
// offer made from that rule carries no next-issue tag for the refusal to see. Claude's system prompt
// says pickers are off for as long as they are, so the rule is overridden for the session (spec #615
// point 4), and says nothing once /pickers on brings them back.
test('while next issue pickers are off, the system prompt tells Claude so, and stops once /pickers on brings them back', {}, async ($, on) => {
  world(on)
  expect(await memory($ as never)).toBe('core memory')
  await type($ as never, 'just give me the list')
  const section = String(await memory($ as never))
  expect(section).toMatch(/^core memory\n\n/)
  expect(section).toContain('Dan turned off next issue pickers for this session')
  expect(section).toContain('never as a picker')
  await $.command.run({ command: 'pickers', args: 'on' } as never)
  expect(await memory($ as never)).toBe('core memory')
})
