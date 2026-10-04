import { expect, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'

// mod-kit, standing in: a mod cannot import another mod's files. It keeps the rows published and
// draws each line as a keyed Box of its parts; a question row takes the band alone, as mod-kit's
// own composer does (proved in mod-kit's tests).
type Part = { text?: string; color?: string; bold?: boolean; dim?: boolean; indent?: number; button?: string; label?: string; hotkey?: string }
type Row = { mod: string; id: string; slot: string; lines: Part[][] }
const modKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const rows = async () => (((await built.state.get({ plugin: 'mod-kit', key: 'band' })) as { value?: Row[] }).value ?? [])
      const modkit = {
        bandRow: async (row: Row) => {
          const now = (await rows()).filter(r => !(r.mod === row.mod && r.id === row.id))
          await built.state.set({ plugin: 'mod-kit', key: 'band' }, [...now, row] as never)
          // Told to the test, which waits on it rather than on a fixed time.
          built.ui.log(`BAND ${row.slot}`, { to: 'debug' })
        },
        clearBandRow: async ({ mod, id }: { mod: string; id: string }) => {
          await built.state.set({ plugin: 'mod-kit', key: 'band' }, (await rows()).filter(r => !(r.mod === mod && r.id === id)) as never)
          built.ui.log('BAND cleared', { to: 'debug' })
        },
      }
      return { ...built, modkit } as never
    })
    on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
      const all = ((await $.state.get({ plugin: 'mod-kit', key: 'band' })) as { value?: Row[] }).value ?? []
      const rows = all.some(r => r.slot === 'question') ? all.filter(r => r.slot === 'question') : all
      if (!rows.length) return next(e)
      const { Box, Button, Text } = $.ui.resolve(e)
      return (
        <Box flexDirection="column">
          {rows.flatMap(r =>
            r.lines.map((l, n) => (
              <Box key={`line:${r.id}:${n}`} flexDirection="row">
                {l.map((p, i) =>
                  p.button ? (
                    <Button key={`${r.mod}:${p.button}`} label={p.label as string} hotkey={p.hotkey} onPress={() => undefined} />
                  ) : (
                    <Text key={String(i)} color={p.color} bold={p.bold} dimColor={p.dim}>
                      {`${' '.repeat(p.indent ?? 0)}${p.text}`}
                    </Text>
                  ),
                )}
              </Box>
            )),
          )}
        </Box>
      )
    })
  },
}
const withKit = { plugins: [modKit] }

const QUESTION = {
  question: "How long should the registry keep a closed session's record?",
  header: 'Retention',
  multiSelect: false,
  options: [
    { label: '1 day', description: 'Smallest folder, but a Friday session is gone by Monday.' },
    { label: '7 days', description: 'Covers a long weekend and a week away.' },
    { label: '30 days', description: 'Keeps a month of history for the goals pane.' },
    { label: 'Until I clear it', description: 'Nothing is deleted on its own.' },
  ],
}

// Claude Code beneath the mod: its own band, its own picker (which must never be reached), the
// transcript's dim lines, toasts, and the commands registered.
const world = (on: On) => {
  const logs: string[] = []
  const shown: string[] = []
  const toasts: string[] = []
  const reachedEngine: string[] = []
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine band</Text>
  })
  on('tool.call', ($, e) => {
    reachedEngine.push(String(e.tool))
    return { result: { questions: [], answers: { engine: 'picker' } } } as never
  })
  on('prompt.submit', ($, e) => ({ text: e.text }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('command.register', ($, e) => ({ value: { command: e.name } }) as never)
  on('ui.log', ($, e) => {
    const text = String((e as { text?: string }).text)
    if (text.startsWith('BAND ')) shown.push(text.slice(5))
    else logs.push(text)
    return { value: undefined } as never
  })
  on('ui.toast', ($, e) => {
    toasts.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  return { logs, shown, toasts, reachedEngine }
}

const band = { plugin: 'mod-kit', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false, isWorking: true, maxRows: 20, bodyColumns: 120, scroll: { offset: 0, bodyRows: 20 }, view: {} } } as never
type El = { type: string; key?: string; props: Record<string, unknown>; children: (El | string)[] }
type Ui = { findAll: (q: { type: string }) => Promise<El[]>; find: (q: object) => Promise<El | undefined>; press: (t: object) => Promise<unknown>; unmount: () => Promise<void> }
const textOf = (el: El | string): string => (typeof el === 'string' ? el : el.type === 'Button' ? `[${String(el.props.label)}]` : (el.children ?? []).map(textOf).join(''))
const lines = async (ui: Ui) => {
  const rows = (await ui.findAll({ type: 'Box' })).filter(b => String(b.key ?? b.props.key ?? '').startsWith('line:'))
  return rows.length ? rows.map(textOf) : (await ui.findAll({ type: 'Text' })).map(textOf)
}
type T$ = { tool: { call: (e: never) => Promise<unknown> }; ui: { mount: (t: never) => Promise<unknown> }; prompt: { submit: (e: never) => Promise<unknown> }; session: { start: (e: never) => Promise<unknown> }; command: { run: (e: never) => Promise<unknown> } }
const ask = ($: T$, q: object = QUESTION, extra: object = {}) =>
  $.tool.call({ tool: 'AskUserQuestion', tool_use_id: 'q1', questions: [q], ...extra } as never) as Promise<{ result?: { answers: Record<string, string> }; deny?: string; text?: string }>
const type = ($: T$, text: string) => $.prompt.submit({ text, origin: { kind: 'composer' }, wait: false } as never)
// Waits on the condition, never a fixed time (L290): until the question is in the band, so the
// call has reached its wait. Gives up after two seconds, naming what it waited for.
const tick = async (w: { shown: string[] }) => {
  for (let n = 0; n < 200; n++) {
    if (w.shown[w.shown.length - 1] === 'question') return
    await new Promise(r => setTimeout(r, 10))
  }
  throw new Error('the question never reached the band')
}

test('a question is drawn in the band, never as a modal, and a press there answers it', withKit, async ($, on) => {
  const w = world(on)
  const call = ask($ as never)
  await tick(w)
  const ui = (await $.ui.mount(band)) as unknown as Ui
  expect(await lines(ui)).toEqual([
    "[Retention] How long should the registry keep a closed session's record?",
    '1. [1 day]',
    '   Smallest folder, but a Friday session is gone by Monday.',
    '2. [7 days]',
    '   Covers a long weekend and a week away.',
    '3. [30 days]',
    '   Keeps a month of history for the goals pane.',
    '4. [Until I clear it]',
    '   Nothing is deleted on its own.',
  ])
  expect((await ui.find({ type: 'Text', text: QUESTION.question }))?.props).toMatchObject({ color: 'warning', bold: true })
  expect((await ui.find({ type: 'Button', key: 'picker-manners:opt2' }))?.props).toMatchObject({ hotkey: '2' })
  await ui.press({ key: 'picker-manners:opt2' })
  const r = await call
  expect(r.result?.answers).toEqual({ [QUESTION.question]: '7 days' })
  expect(w.reachedEngine).toEqual([])
  expect(await lines(ui)).toEqual(['engine band'])
  await ui.unmount()
})

test('typing while a question is open is a message: the question is withdrawn and Claude told to answer it first', withKit, async ($, on) => {
  const w = world(on)
  const call = ask($ as never)
  await tick(w)
  await type($ as never, 'wait, what does 7 days cover exactly?')
  const r = await call
  expect(r.deny ?? r.text).toMatch(/^Dan did not pick an answer: he is sending a message instead/)
  expect(r.result).toBeUndefined()
  expect(w.reachedEngine).toEqual([])
})

test('a question talked past is asked again once, and never a third time', withKit, async ($, on) => {
  const w = world(on)
  for (let n = 0; n < 2; n++) {
    const call = ask($ as never)
    await tick(w)
    await type($ as never, 'let me explain first')
    await call
  }
  const third = await ask($ as never)
  expect(third.deny ?? third.text).toBe('Dan has talked past this question twice, so it is not asked again. Carry on from what he said.')
})

test('a numbered prose answer is mapped onto the question and echoed back in one line', withKit, async ($, on) => {
  const w = world(on)
  const call = ask($ as never)
  await tick(w)
  await type($ as never, '1. 7 days')
  const r = await call
  expect(r.result?.answers).toEqual({ [QUESTION.question]: '7 days' })
  expect(w.logs).toEqual(['Q1 Retention: 7 days'])
})

test('more than one question in a call is refused (one question per call)', withKit, async ($, on) => {
  world(on)
  const r = (await $.tool.call({ tool: 'AskUserQuestion', questions: [QUESTION, QUESTION] } as never)) as { deny?: string; text?: string }
  expect(r.deny ?? r.text).toBe('Ask one question per call: Dan answers pickers one at a time.')
})

test('"no next issue" silences next issue pickers for the session, other pickers still ask, and /pickers on restores them', withKit, async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
  await type($ as never, 'no next issue, just stop there')
  expect(w.logs).toEqual(['Next issue pickers are off for this session; /pickers on brings them back.'])
  const offer = await ask($ as never, QUESTION, { metadata: { source: 'next-issue' } })
  expect(offer.deny ?? offer.text).toMatch(/^Dan turned off next issue pickers for this session/)
  // A hook driven picker (the end of turn issue review) is still drawn in the band.
  const review = ask($ as never, QUESTION, { metadata: { source: 'issue-review' } })
  await tick(w)
  const ui = (await $.ui.mount(band)) as unknown as Ui
  expect((await lines(ui))[0]).toBe("[Retention] How long should the registry keep a closed session's record?")
  await ui.press({ key: 'picker-manners:opt1' })
  expect((await review).result?.answers).toEqual({ [QUESTION.question]: '1 day' })
  await ui.unmount()
  expect(((await $.command.run({ command: 'pickers', args: 'on' } as never)) as { text?: string }).text).toBe('Next issue pickers are back on.')
  const again = ask($ as never, QUESTION, { metadata: { source: 'next-issue' } })
  await tick(w)
  await type($ as never, '1. 30 days')
  expect((await again).result?.answers).toEqual({ [QUESTION.question]: '30 days' })
})

test('a multi select question toggles its options and answers with Submit', withKit, async ($, on) => {
  const w = world(on)
  const call = ask($ as never, { ...QUESTION, multiSelect: true })
  await tick(w)
  const ui = (await $.ui.mount(band)) as unknown as Ui
  await ui.press({ key: 'picker-manners:submit' })
  expect(w.toasts).toEqual(['Nothing is chosen yet.'])
  await ui.press({ key: 'picker-manners:opt3' })
  await ui.press({ key: 'picker-manners:opt1' })
  await ui.press({ key: 'picker-manners:opt3' })
  await ui.press({ key: 'picker-manners:opt2' })
  expect((await lines(ui)).filter(l => l.endsWith(' chosen'))).toEqual(['1. [1 day] chosen', '2. [7 days] chosen'])
  await ui.press({ key: 'picker-manners:submit' })
  expect((await call).result?.answers).toEqual({ [QUESTION.question]: '1 day, 7 days' })
  await ui.unmount()
})

test('a prompt that is not Dan typing (a plugin or a peer) leaves the question open', withKit, async ($, on) => {
  const w = world(on)
  const call = ask($ as never)
  await tick(w)
  await $.prompt.submit({ text: 'a peer session says hello', origin: { kind: 'peer' }, wait: false } as never)
  const ui = (await $.ui.mount(band)) as unknown as Ui
  expect((await lines(ui))[0]).toMatch(/^\[Retention\]/)
  await ui.press({ key: 'picker-manners:opt4' })
  expect((await call).result?.answers).toEqual({ [QUESTION.question]: 'Until I clear it' })
  await ui.unmount()
})

// The build time check the spec asks for (#615): the hook waits on Dan through its own $ call, whose
// time is free, so a press long after a hook's 10 second budget still answers, and Claude Code's own
// picker is never reached. A plain promise awaited here was measured to overrun the budget instead.
test('a press after more than a hook budget of real time still answers from the band', { plugins: [modKit], timeoutMs: 30_000 }, async ($, on) => {
  const w = world(on)
  const call = ask($ as never)
  await tick(w)
  await new Promise(r => setTimeout(r, 11_000))
  const ui = (await $.ui.mount(band)) as unknown as Ui
  await ui.press({ key: 'picker-manners:opt3' })
  expect((await call).result?.answers).toEqual({ [QUESTION.question]: '30 days' })
  expect(w.reachedEngine).toEqual([])
  await ui.unmount()
})
