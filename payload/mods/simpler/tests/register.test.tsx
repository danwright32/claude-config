import { expect, mock, test } from 'claude-code/testing'
import type { On, PromptOrigin } from 'claude-code'
import type {} from '../types/index.d.ts'
import { LONG_WORDS, REPORT_EVERY_MS, judge, requestText } from '../hooks/simpler.ts'

const DAY = 24 * 60 * 60 * 1000
const SURFACES = ['terminal', 'desktop'] as const
const LONG = `There are two options here, and the trade-off is speed. ${Array.from({ length: LONG_WORDS }, () => 'word').join(' ')}`
const SHORT = 'Done. The PR is merged.'
const FIRST_BLOCK = 'There are two options here, and the trade-off is speed.'

// Everything beneath the mod: the clock, a store that can be made to fail, the engine's own
// drawing of a reply, the prompt box, submits, toasts and transcript lines.
const world = (on: On, opts: { now?: number; store?: Record<string, unknown>; drop?: string; submitThrows?: boolean } = {}) => {
  const clock = mock.clock(on, { now: opts.now ?? 100 * DAY })
  const store: Record<string, unknown> = { ...(opts.store ?? {}) }
  const fail = { get: false, set: false, keys: false }
  on('store.get', ($, e) => {
    if (fail.get) throw new Error('store unreadable')
    return { value: store[e.key] } as never
  })
  on('store.set', ($, e) => {
    if (fail.set) throw new Error('disk full')
    store[e.key] = e.value
    return { value: undefined } as never
  })
  on('store.keys', () => {
    if (fail.keys) throw new Error('store unreadable')
    return { value: Object.keys(store) } as never
  })
  const submits: { text: string; asUser?: boolean }[] = []
  on('prompt.submit', ($, e) => {
    if (opts.submitThrows) throw new Error('session closed')
    submits.push({ text: e.text, asUser: e.origin.kind === 'plugin' ? e.origin.asUser : undefined })
    if (opts.drop) return { drop: opts.drop }
    return { text: e.text }
  })
  on('prompt.edit', ($, e) => ({ text: e.text.slice(0, e.start) + e.inputText + e.text.slice(e.end), cursor: e.start + e.inputText.length }))
  on('turn.complete', ($, e) => ({ text: e.answer }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  const toasts: string[] = []
  const logs: string[] = []
  on('ui.toast', ($, e) => { toasts.push(e.text); return { value: undefined } as never })
  on('ui.log', ($, e) => { if (e.to !== 'debug') logs.push(e.text); return { value: undefined } as never })
  // The engine's own drawing of a reply, for every reply the mod leaves alone.
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text key="engine">{e.props.text}</Text>
  })
  return { clock, store, fail, submits, toasts, logs }
}

const answer = ($: Parameters<Parameters<typeof test>[1]>[0], text: string, extra: Record<string, unknown> = {}) =>
  $.turn.complete({ answer: text, durationMs: 1, isAborted: false, turnId: 't', reason: 'answer', ...extra } as never)
const start = ($: Parameters<Parameters<typeof test>[1]>[0], isInteractive = true) =>
  $.session.start({ cwd: '/Users/x/Documents/Bidspoke', surface: isInteractive ? 'terminal' : null, isInteractive })
const mountReply = ($: Parameters<Parameters<typeof test>[1]>[0], surface: (typeof SURFACES)[number], text = FIRST_BLOCK, isFirstOfReply = true) =>
  $.ui.mount({ plugin: 'simpler', surface, component: 'AssistantMessage', props: { text, isFirstOfReply } })
const type = ($: Parameters<Parameters<typeof test>[1]>[0], inputText: string) =>
  ($.prompt as unknown as { edit: (e: unknown) => Promise<unknown> }).edit({ origin: { kind: 'composer' }, text: '', cursor: 0, start: 0, end: 0, inputText })
const submitAs = ($: Parameters<Parameters<typeof test>[1]>[0], origin: PromptOrigin) =>
  ($.prompt as unknown as { submit: (e: unknown) => Promise<unknown> }).submit({ text: 'hi', wait: false, origin })

test('the threshold: a long answer gets the button at the top of its reply, on every surface', async ($, on) => {
  world(on)
  await start($)
  await answer($, LONG)
  for (const surface of SURFACES) {
    const ui = await mountReply($, surface)
    expect(await ui.find({ type: 'Button', key: 'simpler' })).toBeDefined()
    // The reply itself is still drawn, under the button.
    expect(await ui.find({ type: 'Markdown', text: FIRST_BLOCK })).toBeDefined()
    await ui.unmount()
  }
})

test('the threshold: a short answer gets no button, and the engine draws the reply', async ($, on) => {
  world(on)
  await start($)
  expect(judge(SHORT)).toBeNull()
  await answer($, SHORT)
  for (const surface of SURFACES) {
    const ui = await mountReply($, surface, SHORT)
    expect(await ui.find({ key: 'simpler' })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: SHORT })).toBeDefined()
    await ui.unmount()
  }
})

test('the button is only on the first block of the latest answer', async ($, on) => {
  world(on)
  await start($)
  await answer($, LONG)
  const later = await mountReply($, 'terminal', FIRST_BLOCK, false)
  expect(await later.find({ key: 'simpler' })).toBeUndefined()
  await later.unmount()
  const earlier = await mountReply($, 'terminal', 'An earlier answer about something else entirely.')
  expect(await earlier.find({ key: 'simpler' })).toBeUndefined()
  await earlier.unmount()
})

test('a newer short answer takes the button away; an aborted turn does too; a subagent turn does not', async ($, on) => {
  world(on)
  await start($)
  await answer($, LONG)
  await answer($, SHORT, { agentId: 'a1' })
  let ui = await mountReply($, 'terminal')
  expect(await ui.find({ key: 'simpler' })).toBeDefined()
  await ui.unmount()
  await answer($, LONG, { reason: 'aborted', isAborted: true })
  ui = await mountReply($, 'terminal')
  expect(await ui.find({ key: 'simpler' })).toBeUndefined()
  await ui.unmount()
  await answer($, LONG)
  await answer($, SHORT)
  ui = await mountReply($, 'terminal')
  expect(await ui.find({ key: 'simpler' })).toBeUndefined()
  await ui.unmount()
})

test('disappears once Dan types', async ($, on) => {
  world(on)
  await start($)
  await answer($, LONG)
  const ui = await mountReply($, 'terminal')
  expect(await ui.find({ key: 'simpler' })).toBeDefined()
  await type($, 'o')
  expect(await ui.find({ key: 'simpler' })).toBeUndefined()
  expect(await ui.find({ type: 'Markdown' })).toBeUndefined()
  await ui.unmount()
})

test("disappears when Dan sends from the phone, not when a background task's notice arrives", async ($, on) => {
  world(on)
  await start($)
  await answer($, LONG)
  await submitAs($, { kind: 'task-notification' })
  let ui = await mountReply($, 'terminal')
  expect(await ui.find({ key: 'simpler' })).toBeDefined()
  await ui.unmount()
  await submitAs($, { kind: 'bridge' })
  ui = await mountReply($, 'terminal')
  expect(await ui.find({ key: 'simpler' })).toBeUndefined()
  await ui.unmount()
})

test('pressing it submits the request as Dan, logs the press with the kind, and takes the button away', async ($, on) => {
  const w = world(on)
  await start($)
  await answer($, LONG)
  const ui = await mountReply($, 'terminal')
  await ui.press({ key: 'simpler' })
  expect(w.submits).toEqual([{ text: requestText('Bidspoke'), asUser: true }])
  const presses = Object.entries(w.store).filter(([k]) => k.startsWith('press:'))
  expect(presses).toHaveLength(1)
  expect(presses[0]?.[0]).toMatch(new RegExp(`^press:${100 * DAY}:[a-z0-9]+$`))
  expect(presses[0]?.[1]).toMatchObject({ at: 100 * DAY, kind: 'design', reason: 'long' })
  expect(await ui.find({ key: 'simpler' })).toBeUndefined()
  expect(w.toasts).toEqual([])
  await ui.unmount()
})

test('a refused submit says why and puts the button back; the press is still counted', async ($, on) => {
  const w = world(on, { drop: 'a hook refused it' })
  await start($)
  await answer($, LONG)
  const ui = await mountReply($, 'terminal')
  await ui.press({ key: 'simpler' })
  expect(w.toasts).toEqual(['Simpler could not ask for the short version: a hook refused it'])
  expect(await ui.find({ key: 'simpler' })).toBeDefined()
  expect(Object.keys(w.store).filter(k => k.startsWith('press:'))).toHaveLength(1)
  await ui.unmount()
})

test('a submit that throws says why and puts the button back', async ($, on) => {
  const w = world(on, { submitThrows: true })
  await start($)
  await answer($, LONG)
  const ui = await mountReply($, 'terminal')
  await ui.press({ key: 'simpler' })
  expect(w.toasts).toHaveLength(1)
  expect(w.toasts[0]).toContain('Simpler could not ask for the short version: ')
  expect(w.toasts[0]).toMatch(/: .+/)
  expect(await ui.find({ key: 'simpler' })).toBeDefined()
  await ui.unmount()
})

test('a press the store cannot record still asks, and says the count will miss it', async ($, on) => {
  const w = world(on)
  await start($)
  await answer($, LONG)
  w.fail.set = true
  const ui = await mountReply($, 'terminal')
  await ui.press({ key: 'simpler' })
  expect(w.submits).toHaveLength(1)
  expect(w.logs).toHaveLength(1)
  expect(w.logs[0]).toMatch(/^Simpler couldn't record this press, so the weekly count will miss it: .+/)
  await ui.unmount()
})

test('without a project name the request asks for an example from this project', async ($, on) => {
  const w = world(on)
  await answer($, LONG)
  const ui = await mountReply($, 'terminal')
  await ui.press({ key: 'simpler' })
  expect(w.submits[0]?.text).toBe(requestText(undefined))
  await ui.unmount()
})

test('the weekly count: the first session starts the week and says nothing', async ($, on) => {
  const w = world(on)
  await start($)
  expect(w.logs).toEqual([])
  expect(w.store.reportedAt).toBe(100 * DAY)
})

test('the weekly count: nothing before a week, then one line naming the kinds pressed since the last count', async ($, on) => {
  const since = 100 * DAY - REPORT_EVERY_MS
  const w = world(on, {
    now: 100 * DAY - 1,
    store: {
      reportedAt: since,
      // Before the last count: not this week's.
      [`press:${since - 1}:old`]: { at: since - 1, kind: 'status', reason: 'long', words: 300 },
      [`press:${since + 1}:a`]: { at: since + 1, kind: 'design', reason: 'long', words: 300 },
      [`press:${since + 2}:b`]: { at: since + 2, kind: 'design', reason: 'technical', words: 120 },
      [`press:${since + 3}:c`]: { at: since + 3, kind: 'plan', reason: 'long', words: 400 },
    },
  })
  await start($)
  expect(w.logs).toEqual([])
  await w.clock.set(100 * DAY)
  await start($)
  expect(w.logs).toEqual(['Simpler was pressed 3 times in the last 7 days: after 2 design answers and 1 plan.'])
  expect(w.store.reportedAt).toBe(100 * DAY)
  // Once a week: the next session the same day says nothing.
  await start($)
  expect(w.logs).toHaveLength(1)
})

test('the weekly count says so when Simpler was not pressed', async ($, on) => {
  const w = world(on, { store: { reportedAt: 100 * DAY - 8 * DAY } })
  await start($)
  expect(w.logs).toEqual(['Simpler was not pressed in the last 8 days.'])
})

test('the weekly count is not shown in a session nobody is at', async ($, on) => {
  const w = world(on, { store: { reportedAt: 0 } })
  await start($, false)
  expect(w.logs).toEqual([])
  expect(w.store.reportedAt).toBe(0)
})

test('a press log that cannot be read is named, and the count is tried again next session', async ($, on) => {
  const w = world(on, { store: { reportedAt: 0 } })
  w.fail.keys = true
  await start($)
  expect(w.logs).toHaveLength(1)
  expect(w.logs[0]).toMatch(/^Simpler couldn't read its press log, so this week's count is not shown: .+/)
  expect(w.store.reportedAt).toBe(0)
  w.fail.keys = false
  await start($)
  expect(w.logs[1]).toBe('Simpler was not pressed in the last 100 days.')
})
