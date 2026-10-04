import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import { ADD_ON_CONTEXT, AMENDMENT_CONTEXT, TOAST } from '../hooks/classify.ts'

// Add-on notes (claude-config#620). What the mod changes is only ever what the model reads beside
// the prompt (its context) and one toast; the words Dan typed reach the model as typed.

type Seen = { text: string; context: readonly string[] }

const world = (on: On, opts: { dropBelow?: boolean } = {}) => {
  const seen: Seen[] = []
  const toasts: string[] = []
  // Claude Code beneath the mod: records what entered, or refuses it.
  on('prompt.submit', ($, e) => {
    if (opts.dropBelow) return { drop: 'blocked by a settings hook' }
    seen.push({ text: e.text, context: e.context ?? [] })
    return { text: e.text, context: e.context, origin: e.origin }
  })
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('turn.complete', ($, e) => ({ text: e.answer }))
  on('session.end', () => ({ sessionId: 's1' }) as never)
  return { seen, toasts }
}

// A prompt as Claude Code raises it: typed at the terminal, mid turn when turnId is set.
const typed = (text: string, turnId?: string, kind: string = 'composer') =>
  ({ text, wait: false, origin: { kind }, ...(turnId ? { turnId } : {}) }) as never

const ended = (reason: 'answer' | 'aborted' | 'error', extra: Record<string, unknown> = {}) =>
  ({ answer: '', durationMs: 10, isAborted: reason === 'aborted', turnId: 't1', reason, ...extra }) as never

test('a + note mid turn is marked as an add-on and acknowledged with a toast', async ($, on) => {
  const w = world(on)
  const r = await $.prompt.submit(typed('+ also link the commission', 't1'))
  expect(w.seen).toEqual([{ text: '+ also link the commission', context: [ADD_ON_CONTEXT] }])
  expect(w.toasts).toEqual([TOAST])
  expect(TOAST).toBe('Noted, applying after this step.')
  expect((r as { text?: string }).text).toBe('+ also link the commission')
})

test('a + note from the phone counts too', async ($, on) => {
  const w = world(on)
  await $.prompt.submit(typed('+ include links', 't1', 'bridge'))
  expect(w.seen[0]?.context).toEqual([ADD_ON_CONTEXT])
  expect(w.toasts).toEqual([TOAST])
})

test('context another hook already attached is kept beside the add-on note', async ($, on) => {
  const w = world(on)
  await $.prompt.submit({ ...(typed('+ include links', 't1') as object), context: ['earlier'] } as never)
  expect(w.seen[0]?.context).toEqual(['earlier', ADD_ON_CONTEXT])
})

test('a plain message mid turn is left to Claude Code, which already delivers it', async ($, on) => {
  const w = world(on)
  await $.prompt.submit(typed('also link the commission', 't1'))
  expect(w.seen).toEqual([{ text: 'also link the commission', context: [] }])
  expect(w.toasts).toEqual([])
})

test('a + message from another session or a background task is not Dan, so it is left alone', async ($, on) => {
  const w = world(on)
  await $.prompt.submit(typed('+ also x', 't1', 'peer'))
  await $.prompt.submit(typed('+ also x', 't1', 'task-notification'))
  expect(w.seen.map(s => s.context)).toEqual([[], []])
  expect(w.toasts).toEqual([])
})

test('no toast when the note never entered: refused beneath', async ($, on) => {
  const w = world(on, { dropBelow: true })
  const r = await $.prompt.submit(typed('+ also x', 't1'))
  expect((r as { drop?: string }).drop).toBe('blocked by a settings hook')
  expect(w.toasts).toEqual([])
})

// Each phrase Dan used after pressing Esc (from the issue): the interrupted step resumes.
for (const phrase of ['also do a direct link to commission', 'and open it in bbedit', 'include links', 'sorry keep going', '+ add the tests too']) {
  test(`after an interrupt, "${phrase}" is an amendment that resumes the step`, async ($, on) => {
    const w = world(on)
    await $.turn.complete(ended('aborted'))
    await $.prompt.submit(typed(phrase))
    expect(w.seen).toEqual([{ text: phrase, context: [AMENDMENT_CONTEXT] }])
    // The acknowledgement after an interrupt is Claude's own one line, not a toast.
    expect(w.toasts).toEqual([])
  })
}

for (const phrase of ['stop, do the README first instead', 'no, use the other file', 'actually never mind, revert that', 'do the issue list now']) {
  test(`after an interrupt, the redirect "${phrase}" is not read as an add-on`, async ($, on) => {
    const w = world(on)
    await $.turn.complete(ended('aborted'))
    await $.prompt.submit(typed(phrase))
    expect(w.seen).toEqual([{ text: phrase, context: [] }])
    expect(w.toasts).toEqual([])
  })
}

test('the same reply after a turn that finished normally is a new message', async ($, on) => {
  const w = world(on)
  await $.turn.complete(ended('answer'))
  await $.prompt.submit(typed('also do a direct link to commission'))
  expect(w.seen[0]?.context).toEqual([])
})

test('a finished turn after an interrupt clears it', async ($, on) => {
  const w = world(on)
  await $.turn.complete(ended('aborted'))
  await $.turn.complete(ended('answer'))
  await $.prompt.submit(typed('also do a direct link to commission'))
  expect(w.seen[0]?.context).toEqual([])
})

test('a turn that died on an API error is no interrupt', async ($, on) => {
  const w = world(on)
  await $.turn.complete(ended('error'))
  await $.prompt.submit(typed('also do a direct link to commission'))
  expect(w.seen[0]?.context).toEqual([])
})

test('a subagent interrupted is not the session interrupted', async ($, on) => {
  const w = world(on)
  await $.turn.complete(ended('aborted', { agentId: 'a1' }))
  await $.prompt.submit(typed('also do a direct link to commission'))
  expect(w.seen[0]?.context).toEqual([])
})

test('an interrupt is answered once: the next message uses it up, add-on or not', async ($, on) => {
  const w = world(on)
  await $.turn.complete(ended('aborted'))
  await $.prompt.submit(typed('no, use the other file'))
  await $.prompt.submit(typed('also include links'))
  expect(w.seen.map(s => s.context)).toEqual([[], []])
})

test('an amendment uses the interrupt up too', async ($, on) => {
  const w = world(on)
  await $.turn.complete(ended('aborted'))
  await $.prompt.submit(typed('also include links'))
  await $.prompt.submit(typed('and the footer'))
  expect(w.seen.map(s => s.context)).toEqual([[AMENDMENT_CONTEXT], []])
})

test('a message from another session after an interrupt does not use it up', async ($, on) => {
  const w = world(on)
  await $.turn.complete(ended('aborted'))
  await $.prompt.submit(typed('Another session finished', undefined, 'peer'))
  await $.prompt.submit(typed('also include links'))
  expect(w.seen.map(s => s.context)).toEqual([[], [AMENDMENT_CONTEXT]])
})

test('a /clear forgets the interrupt', async ($, on) => {
  const w = world(on)
  await $.turn.complete(ended('aborted'))
  await $.session.end({ reason: 'clear' } as never)
  await $.prompt.submit(typed('also include links'))
  expect(w.seen[0]?.context).toEqual([])
})

test('a + note after an interrupt is an amendment, with no toast', async ($, on) => {
  const w = world(on)
  await $.turn.complete(ended('aborted'))
  await $.prompt.submit(typed('+ include links'))
  expect(w.seen[0]?.context).toEqual([AMENDMENT_CONTEXT])
  expect(w.toasts).toEqual([])
})

test('a + note while idle with no interrupt is passed through as typed', async ($, on) => {
  const w = world(on)
  await $.prompt.submit(typed('+ include links'))
  expect(w.seen).toEqual([{ text: '+ include links', context: [] }])
  expect(w.toasts).toEqual([])
})

test('the amendment tells Claude to resume, keep scope, and open with the agreed resume line', () => {
  expect(AMENDMENT_CONTEXT).toContain('Resume the step you were on')
  expect(AMENDMENT_CONTEXT).toContain('Keep every part of the scope already agreed')
  // The agreed wording (docs/mods-design.md, Add-on notes): it names the addition only.
  expect(AMENDMENT_CONTEXT).toContain('+ add-on: Adding a direct link to the commission and carrying on.')
  expect(ADD_ON_CONTEXT).toContain('not a redirect')
})
