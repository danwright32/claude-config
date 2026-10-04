import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'

// The /goals pane (Dan, 2026-10-04, docs/mods-design.md "Goals pane"): every open session on this
// Mac, two lines each, ordered waiting on you, failed, stalled, working, done, the state word alone
// coloured. A live pane that closes itself when Dan next sends a message.

// The registry stand-in: what it lists is whatever the test last put in the world, read through a
// process call (an inline plugin cannot reach this file's variables).
const deps: { name: string; register: Register } = {
  name: 'deps',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return {
        ...built,
        sessions: {
          list: async () => {
            const r = await built.process.run(['__sessions'])
            if (r.exitCode !== 0) throw new Error(r.stderr)
            return JSON.parse(r.stdout)
          },
          noteEdit: async () => undefined,
          setExtra: async () => undefined,
        },
      }
    })
  },
}
const withDeps = { plugins: [deps] }
const MIN = 60_000

type Listing = { open: unknown[]; closed: unknown[]; unreadable: string[]; selfId: string } | 'throws'
const world = (on: On, listing: { now: Listing }, openReason?: string) => {
  const w = { opened: [] as unknown[], closed: [] as string[], commands: [] as string[], invalidated: 0 }
  on('process.run', ($, e) => {
    if (e.argv[0] !== '__sessions') return { value: { exitCode: 1, stdout: '', stderr: 'unexpected', isStdoutTruncated: false, isStderrTruncated: false } }
    const l = listing.now
    return { value: l === 'throws' ? { exitCode: 1, stdout: '', stderr: 'the sessions folder could not be read', isStdoutTruncated: false, isStderrTruncated: false } : { exitCode: 0, stdout: JSON.stringify(l), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('command.register', ($, e) => {
    w.commands.push(e.name)
    return { value: undefined } as never
  })
  on('ui.open', ($, e) => {
    w.opened.push(e)
    return { value: openReason ? { isPlaced: false, reason: openReason } : { isPlaced: true } } as never
  })
  on('ui.close', ($, e) => {
    w.closed.push(e.id)
    return { value: undefined } as never
  })
  on('ui.invalidate', () => {
    w.invalidated += 1
    return { value: undefined } as never
  })
  on('prompt.submit', ($, e) => ({ text: e.text }) as never)
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  return w
}

const progress = (p: Record<string, unknown>) => ({ steps: [], done: 0, total: 0, current: null, startedAt: 0, lastStepAt: 0, lastActivityAt: 0, ...p })
const session = (id: string, project: string, p: Record<string, unknown> | undefined) => ({
  v: 1,
  sessionId: id,
  cwd: `/Users/dan/Apps/${project}`,
  repoRoot: `/Users/dan/Apps/${project}`,
  startedAt: 0,
  lastSeen: 0,
  closedAt: null,
  transcriptPath: null,
  edits: [],
  extra: p ? { progress: progress(p) } : {},
})
const FIVE = (now: number): Listing => ({
  open: [
    session('d', 'Downbeat', { total: 4, done: 4, request: 'Release notes', lastActivityAt: now }),
    session('k', 'claude-config', { total: 7, done: 4, goal: 'Mods design rounds', current: 'Writing the design doc', lastActivityAt: now }),
    session('s', 'PostRoll', { total: 6, done: 2, request: 'Caption retry', lastActivityAt: now - 14 * MIN }),
    session('f', 'Overture', { total: 3, done: 1, request: 'Gmail send fix', failed: 'Exit code 1', lastActivityAt: now }),
    session('w', 'Ovation', { total: 5, done: 3, request: 'Invoice export', waiting: { question: 'Which date format for the CSV?', since: now, kind: 'question' }, lastActivityAt: now }),
  ],
  closed: [session('gone', 'Old', { total: 1, done: 0, request: 'Long gone' })],
  unreadable: [],
  selfId: 'k',
})

const start = ($: { session: { start: (e: never) => Promise<unknown> } }) => $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
const goals = ($: { command: { run: (e: never) => Promise<unknown> } }) => $.command.run({ command: 'goals', args: '', origin: { kind: 'composer' }, presentation: { mode: 'main', columns: 120 } } as never)
const PANE_PROPS = { title: 'Goals', isFocused: false, bodyColumns: 100, placement: 'inline', scroll: { top: 0, bodyRows: 30, contentRows: 0 }, view: {} } as never
const mount = ($: { ui: { mount: (t: never) => Promise<unknown> } }) =>
  $.ui.mount({ plugin: 'goal-tracker', surface: 'terminal', component: 'Pane', requestId: 'goals', props: PANE_PROPS } as never) as Promise<{
    findAll: (q: { type?: string; key?: string; text?: string | RegExp }) => Promise<{ text: string; props: Record<string, unknown>; key: string | undefined }[]>
    find: (q: { type?: string; key?: string; text?: string | RegExp }) => Promise<{ text: string; props: Record<string, unknown> } | undefined>
    redraw: () => Promise<void>
    drawn: () => Promise<Node>
  }>

// The drawing read back as each session's two lines: a keyed Box per session holding the top line,
// then the second line's state word and dim sentence.
type Node = { type: string; props?: Record<string, unknown>; children?: (Node | string)[] }
const textOf = (n: Node | string | undefined): string => (n === undefined ? '' : typeof n === 'string' ? n : (n.children ?? []).map(textOf).join(''))
const rowsDrawn = async (ui: { drawn: () => Promise<Node> }) => {
  const tree = await ui.drawn()
  return (tree.children ?? [])
    .filter((c): c is Node => typeof c !== 'string' && String(c.props?.key ?? '').startsWith('session-'))
    .map(box => {
      const [top, second] = (box.children ?? []) as Node[]
      const [, state, sentence] = (second?.children ?? []) as Node[]
      return { top: textOf(top), state: textOf(state), colour: state?.props?.color, sentence: textOf(sentence), dim: sentence?.props?.dimColor }
    })
}

test('/goals is a command, and opens the goals pane', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { now: FIVE(0) })
  await start($)
  expect(w.commands).toContain('goals')
  await goals($)
  expect(w.opened).toEqual([expect.objectContaining({ id: 'goals', title: 'Goals' })])
})

test('every open session shows as two lines, in the settled order, the state word coloured', withDeps, async ($, on) => {
  mock.clock(on, { now: 72 * MIN })
  world(on, { now: FIVE(72 * MIN) })
  await start($)
  await goals($)
  const ui = await mount($)
  const rows = await rowsDrawn(ui)
  expect(rows.map(r => r.top)).toEqual(['Ovation  Invoice export', 'Overture  Gmail send fix', 'PostRoll  Caption retry', 'claude-config  Mods design rounds', 'Downbeat  Release notes'])
  expect(rows.map(r => [r.state, r.colour])).toEqual([
    ['waiting on you', 'warning'],
    ['failed', 'error'],
    ['stalled', 'warning'],
    ['working', 'suggestion'],
    ['done', 'success'],
  ])
  expect(rows.map(r => [r.sentence, r.dim])).toEqual([
    [', 3 of 5 steps, 1h 12m. "Which date format for the CSV?"', true],
    [', 1 of 3 steps, 1h 12m. Exit code 1 (3 failed calls in a row)', true],
    [', 2 of 6 steps, 1h 12m. nothing for 14m', true],
    [', 4 of 7 steps, 1h 12m. Writing the design doc', true],
    [', 4 of 4 steps, 1h 12m', true],
  ])
  expect(await ui.find({ text: /Long gone/ })).toBeUndefined()
})

test('a session registry that cannot be read is said, never drawn as no sessions', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  world(on, { now: 'throws' })
  await start($)
  await goals($)
  const ui = await mount($)
  expect((await ui.find({ type: 'Text', text: /could not be read/ }))?.text).toBe('Session records could not be read: the sessions folder could not be read.')
})

test('records that cannot be read are counted beneath the sessions that can', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const l = FIVE(0) as Exclude<Listing, 'throws'>
  world(on, { now: { ...l, unreadable: ['a.json', 'b.json'] } })
  await start($)
  await goals($)
  const ui = await mount($)
  expect((await rowsDrawn(ui)).length).toBe(5)
  expect((await ui.find({ type: 'Text', text: /could not be read/ }))?.text).toBe('2 session records could not be read.')
})

test('the pane follows the sessions as they move', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const listing = { now: FIVE(0) }
  const w = world(on, listing)
  await start($)
  await goals($)
  const ui = await mount($)
  const before = w.invalidated
  listing.now = { open: [session('w', 'Ovation', { total: 5, done: 4, request: 'Invoice export' })], closed: [], unreadable: [], selfId: 'w' }
  await clock.advance(5_000)
  expect(w.invalidated).toBeGreaterThan(before)
  await ui.redraw()
  expect((await rowsDrawn(ui)).map(r => r.sentence)).toEqual([', 4 of 5 steps, 0m'])
})

test('the pane closes itself when Dan next sends a message, and stops following', withDeps, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on, { now: FIVE(0) })
  await start($)
  await goals($)
  await $.prompt.submit({ text: '/goals', origin: { kind: 'composer' }, wait: false } as never)
  expect(w.closed).toEqual([])
  await $.prompt.submit({ text: 'thanks, carry on', origin: { kind: 'composer' }, wait: false } as never)
  expect(w.closed).toEqual(['goals'])
  const after = w.invalidated
  await clock.advance(30_000)
  expect(w.invalidated).toBe(after)
})

test('a message while the pane is shut closes nothing', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world(on, { now: FIVE(0) })
  await start($)
  await $.prompt.submit({ text: 'hello', origin: { kind: 'composer' }, wait: false } as never)
  expect(w.closed).toEqual([])
})

test('a pane that waits for a wider window says so', withDeps, async ($, on) => {
  mock.clock(on, { now: 0 })
  world(on, { now: FIVE(0) }, 'the terminal is 90 columns, under 110')
  await start($)
  const r = (await goals($)) as { text?: string }
  expect(r.text).toBe('The goals pane is open but not shown: the terminal is 90 columns, under 110.')
})
