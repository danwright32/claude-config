import { expect, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'

// mod-kit, standing in: a mod cannot import another mod's files. It keeps the questions published
// and draws the first one asked, alone, as mod-kit does (one question at a time, #703): the chip
// and question, each option as a plain numbered button, a description under it. mod-kit's own tests
// prove the real drawing; here what matters is what picker manners asks it to draw and when.
type Ask = { mod: string; id: string; chip: string; question: string; options: { button: string; label: string; description?: string; chosen?: boolean }[]; submit?: { button: string; label: string } }
const modKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const ref = { plugin: 'mod-kit', key: 'band' } as never
      const rows = async () => (((await built.state.get(ref)) as { value?: Ask[] }).value ?? [])
      const modkit = {
        question: async (q: Ask) => {
          const all = await rows()
          const i = all.findIndex(r => r.mod === q.mod && r.id === q.id)
          await built.state.set(ref, (i < 0 ? [...all, q] : all.map((r, n) => (n === i ? q : r))) as never)
          // Told to the test, which waits on it rather than on a fixed time.
          built.ui.log(`BAND question ${JSON.stringify(q)}`, { to: 'debug' })
        },
        shownQuestion: async () => {
          const q = (await rows())[0]
          return q ? { mod: q.mod, id: q.id } : null
        },
        clearBandRow: async ({ mod, id }: { mod: string; id: string }) => {
          // A question whose text asks for it stands for a band that cannot be cleared.
          if ((await rows()).some(r => r.mod === mod && r.id === id && r.question.includes('cannot be cleared'))) throw new Error('the band is gone')
          await built.state.set(ref, (await rows()).filter(r => !(r.mod === mod && r.id === id)) as never)
          built.ui.log(`BAND cleared ${JSON.stringify({ mod })}`, { to: 'debug' })
        },
        // The screen (#707): refuses a call carrying SCREEN-REFUSES, as the secret guard refuses a
        // token; mod-kit's own tests prove the real one asks the secret guard.
        screen: async (call: unknown) => (JSON.stringify(call).includes('SCREEN-REFUSES') ? { deny: 'Blocked: this message contains a secret. Refer to it by its name, not its value.' } : null),
      }
      return { ...built, modkit } as never
    })
    on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
      const q = (((await $.state.get({ plugin: 'mod-kit', key: 'band' } as never)) as { value?: Ask[] }).value ?? [])[0]
      if (!q) return next(e)
      const { Box, Button, Text } = $.ui.resolve(e)
      const lines = [
        <Box key="line:head" flexDirection="row">
          <Text dimColor>{`[${q.chip}] `}</Text>
          <Text color="warning" bold>
            {q.question}
          </Text>
        </Box>,
      ]
      q.options.forEach((o, i) => {
        lines.push(
          <Box key={`line:o${i}`} flexDirection="row">
            {[
              <Button key={`${q.mod}:${o.button}`} label={o.label} hotkey={String(i + 1)} plain onPress={() => undefined} />,
              ...(o.chosen ? [<Text key="chosen" dimColor>{' chosen'}</Text>] : []),
            ]}
          </Box>,
        )
        if (o.description)
          lines.push(
            <Box key={`line:d${i}`} flexDirection="row">
              <Text dimColor>{`   ${o.description}`}</Text>
            </Box>,
          )
      })
      if (q.submit)
        lines.push(
          <Box key="line:submit" flexDirection="row">
            <Button key={`${q.mod}:${q.submit.button}`} label={q.submit.label} onPress={() => undefined} />
          </Box>,
        )
      return <Box flexDirection="column">{lines}</Box>
    })
  },
}

// Another mod with a question of its own in the band (ask before saving's, which waits while
// Claude carries on), and another that asks Dan through $.ui.ask (the keystroke guard's heads up).
const otherAsker: { name: string; register: Register } = {
  name: 'other-asker',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
      const command = String((e as { command?: string }).command)
      if (command === 'save-question') {
        await $.modkit.question({ mod: 'ask-before-saving', id: 'question:t1', chip: 'Standing rule', question: 'Save this as a standing rule?', options: [{ button: 'for-good', label: 'For good' }] } as never)
        return { deny: 'asked' }
      }
      if (command === 'save-answered') {
        await $.modkit.clearBandRow({ mod: 'ask-before-saving', id: 'question:t1' })
        return { deny: 'cleared' }
      }
      if (command === 'ready') {
        try {
          return { deny: `asked: ${await $.ui.ask("I'm about to type into Overture. Ready?", { header: 'Taking over', options: ['Go ahead', 'Not now'] })}` }
        } catch (err) {
          return { deny: `rejected: ${String((err as Error).message ?? err)}` }
        }
      }
      return next(e)
    })
  },
}
const withKit = { plugins: [modKit, otherAsker] }

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

// Claude Code beneath the mod: its own band, its own picker (reached only where no band can be
// drawn), the surfaces the session draws on, the transcript's dim lines, toasts, the memory section
// of the system prompt, and the commands registered.
const world = (on: On, init: { surfaces?: string[]; surfacesFail?: boolean } = {}) => {
  const logs: string[] = []
  const pm: string[] = []
  const asks: Ask[] = []
  const debug: string[] = []
  const toasts: string[] = []
  const reachedEngine: string[] = []
  on('session.surfaces', () => {
    if (init.surfacesFail) throw new Error('no surfaces here')
    return { value: init.surfaces ?? ['terminal'] } as never
  })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine band</Text>
  })
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
    const text = String((e as { text?: string }).text)
    const band = /^BAND (question|cleared) (.*)$/s.exec(text)
    if (band) {
      const body = JSON.parse(band[2] as string) as Ask
      if (band[1] === 'question') asks.push(body)
      if (body.mod === 'picker-manners') pm.push(band[1] as string)
    } else if ((e as { to?: string }).to === 'debug') debug.push(text)
    else logs.push(text)
    return { value: undefined } as never
  })
  on('ui.toast', ($, e) => {
    toasts.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  return { logs, asks, pm, debug, toasts, reachedEngine }
}

const band = { plugin: 'mod-kit', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false, isWorking: true, maxRows: 20, bodyColumns: 120, scroll: { offset: 0, bodyRows: 20 }, view: {} } } as never
type El = { type: string; key?: string; props: Record<string, unknown>; children: (El | string)[] }
type Ui = { findAll: (q: { type: string }) => Promise<El[]>; find: (q: object) => Promise<El | undefined>; press: (t: object) => Promise<unknown>; unmount: () => Promise<void> }
const textOf = (el: El | string): string =>
  typeof el === 'string' ? el : el.type === 'Button' ? (el.props.plain ? `${el.props.hotkey ? `${String(el.props.hotkey)}: ` : ''}${String(el.props.label)}` : `[${String(el.props.label)}]`) : (el.children ?? []).map(textOf).join('')
const lines = async (ui: Ui) => {
  const rows = (await ui.findAll({ type: 'Box' })).filter(b => String(b.key ?? b.props.key ?? '').startsWith('line:'))
  return rows.length ? rows.map(textOf) : (await ui.findAll({ type: 'Text' })).map(textOf)
}
type T$ = {
  tool: { call: (e: never) => Promise<unknown> }
  ui: { mount: (t: never) => Promise<unknown> }
  prompt: { submit: (e: never) => Promise<unknown>; section: (e: never) => Promise<{ text: string | null }> }
  session: { start: (e: never) => Promise<unknown> }
  command: { run: (e: never) => Promise<unknown> }
}
type Answered = { result?: { answers: Record<string, string> }; deny?: string; text?: string }
const ask = ($: T$, q: object = QUESTION, extra: object = {}) => $.tool.call({ tool: 'AskUserQuestion', tool_use_id: 'q1', questions: [q], ...extra } as never) as Promise<Answered>
const bash = async ($: T$, command: string) => ((await $.tool.call({ tool: 'Bash', command } as never)) as Answered).deny
const type = ($: T$, text: string, kind = 'composer') => $.prompt.submit({ text, origin: { kind }, wait: false } as never)
const memory = async ($: T$) => (await $.prompt.section({ name: 'memory', text: 'core memory' } as never)).text
// Waits on the condition, never a fixed time (L290): until picker manners' question is in the band,
// so the call has reached its wait. Gives up after two seconds, naming what it waited for.
const tick = async (w: { pm: string[] }) => {
  for (let n = 0; n < 200; n++) {
    if (w.pm[w.pm.length - 1] === 'question') return
    await new Promise(r => setTimeout(r, 10))
  }
  throw new Error('the question never reached the band')
}
const MESSAGE = 'Dan did not pick an answer: he is sending a message instead, which follows. Answer his message first.'

test('a question is asked in the band through mod-kit, never as a modal, and a press there answers it', withKit, async ($, on) => {
  const w = world(on)
  const call = ask($ as never)
  await tick(w)
  expect(w.asks).toEqual([
    {
      mod: 'picker-manners',
      id: 'question',
      chip: 'Retention',
      question: QUESTION.question,
      options: QUESTION.options.map((o, i) => ({ button: `opt${i + 1}`, label: o.label, description: o.description })),
    },
  ])
  const ui = (await $.ui.mount(band)) as unknown as Ui
  expect((await lines(ui))[0]).toBe("[Retention] How long should the registry keep a closed session's record?")
  expect((await ui.find({ type: 'Button', key: 'picker-manners:opt2' }))?.props).toMatchObject({ hotkey: '2', plain: true })
  await ui.press({ key: 'picker-manners:opt2' })
  const r = await call
  expect(r.result?.answers).toEqual({ [QUESTION.question]: '7 days' })
  expect(w.reachedEngine).toEqual([])
  expect(await lines(ui)).toEqual(['engine band'])
  await ui.unmount()
})

// #707: this mod answers every AskUserQuestion itself, so the secret guard beneath it never sees the
// question; it asks mod-kit's screen first. A question carrying a token is refused before it is
// drawn in the band or kept as the open question.
test('a question a guard refuses is refused before it is drawn in the band (#707)', withKit, async ($, on) => {
  const w = world(on)
  const r = await ask($ as never, { ...QUESTION, options: [...QUESTION.options, { label: 'Use SCREEN-REFUSES', description: 'the key' }] })
  expect(r.deny ?? r.text).toBe('Blocked: this message contains a secret. Refer to it by its name, not its value.')
  expect(w.asks).toEqual([])
  expect(w.reachedEngine).toEqual([])
})

test('typing while a question is open is a message: the question is withdrawn and Claude told to answer it first', withKit, async ($, on) => {
  const w = world(on)
  const call = ask($ as never)
  await tick(w)
  await type($ as never, 'wait, what does 7 days cover exactly?')
  const r = await call
  expect(r.deny ?? r.text).toBe(`${MESSAGE} If this question is still unanswered after that, ask it again once; never more than once.`)
  expect(r.result).toBeUndefined()
  expect(w.reachedEngine).toEqual([])
})

// #703: the second talk past still said "ask it again once", and the third asking was then refused.
test('a question talked past is asked again once: the second pass tells Claude not to ask again, and a third asking is refused', withKit, async ($, on) => {
  const w = world(on)
  const told: string[] = []
  for (let n = 0; n < 2; n++) {
    const call = ask($ as never)
    await tick(w)
    await type($ as never, 'let me explain first')
    const r = await call
    told.push(String(r.deny ?? r.text))
  }
  expect(told[0]).toMatch(/ask it again once; never more than once\.$/)
  expect(told[1]).toBe(`${MESSAGE} He has now talked past or dismissed this question twice, so do not ask it again: carry on from what he says.`)
  const third = await ask($ as never)
  expect(third.deny ?? third.text).toBe('Dan has talked past or dismissed this question twice, so it is not asked again. Carry on from what he said.')
})

// #703: the limit keyed on the exact wording, and Claude rewords a question when it asks again.
test('the limit holds when Claude rewords the question, and a different question under the same chip is still asked', withKit, async ($, on) => {
  const w = world(on)
  const reworded = { ...QUESTION, question: 'How long do you want closed sessions kept?' }
  for (const q of [QUESTION, reworded]) {
    const call = ask($ as never, q)
    await tick(w)
    await type($ as never, 'hang on')
    await call
  }
  expect((await ask($ as never, { ...QUESTION, question: 'So, how long should closed sessions be kept for?' })).deny).toMatch(/^Dan has talked past or dismissed this question twice/)
  const other = ask($ as never, { ...QUESTION, question: 'Where should the registry live?', options: [{ label: 'Home' }, { label: 'Scratch' }] })
  await tick(w)
  await type($ as never, '1. Home')
  expect((await other).result?.answers).toEqual({ 'Where should the registry live?': 'Home' })
})

// #703: the keystroke guard asks "I'm about to type into <app>. Ready?" the same way every time, so
// once Dan had typed over it twice every later keystroke into that app was refused unasked.
test("another mod's question, asked through $.ui.ask, is drawn every time: the limit on asking again is for Claude's own questions", withKit, async ($, on) => {
  const w = world(on)
  for (let n = 0; n < 3; n++) {
    const r = bash($ as never, 'ready')
    await tick(w)
    await type($ as never, 'not yet, one moment')
    expect(await r).toMatch(/^rejected: /)
  }
  const r = bash($ as never, 'ready')
  await tick(w)
  const ui = (await $.ui.mount(band)) as unknown as Ui
  expect((await lines(ui))[0]).toBe("[Taking over] I'm about to type into Overture. Ready?")
  await ui.press({ key: 'picker-manners:opt1' })
  expect(await r).toBe('asked: Go ahead')
  await ui.unmount()
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

// #703: the band is not drawn on the phone, and only typing at the Mac counted, so a question open
// while Dan was on Remote Control could be neither answered nor dismissed.
test("Dan's messages from his phone count as his own: one withdraws the question, numbered prose answers it, and \"no next issue\" quiets", withKit, async ($, on) => {
  const w = world(on)
  let call = ask($ as never)
  await tick(w)
  await type($ as never, 'what does that mean?', 'bridge')
  expect((await call).deny).toMatch(/^Dan did not pick an answer/)
  call = ask($ as never)
  await tick(w)
  await type($ as never, '1. 30 days', 'bridge')
  expect((await call).result?.answers).toEqual({ [QUESTION.question]: '30 days' })
  await type($ as never, 'no next issue', 'bridge')
  expect((await ask($ as never, QUESTION, { metadata: { source: 'next-issue' } })).deny).toMatch(/^Dan turned off next issue pickers/)
})

// #703: where no band is drawn (a claude -p or SDK run, Dan's phone or VS Code attached) a question
// put in the band waited for ever. Claude Code's own dialog, drawn on every surface, asks instead,
// and in a -p run refuses, so another mod's $.ui.ask fails closed there as it is written to.
for (const [name, init] of [
  ['a claude -p run, drawing nowhere', { surfaces: [] }],
  ["Dan's phone attached", { surfaces: ['terminal', 'mobile'] }],
  ['surfaces that cannot be read', { surfacesFail: true }],
] as const) {
  test(`with ${name}, the question goes to Claude Code's own dialog, never the band`, withKit, async ($, on) => {
    const w = world(on, init)
    const r = await ask($ as never)
    expect(w.reachedEngine).toEqual(['AskUserQuestion'])
    expect(r.result?.answers).toEqual({ engine: 'picker' })
    expect(w.asks).toEqual([])
  })
}

// #703: with one question drawn at a time, picker manners' question can wait behind another mod's.
// Dan cannot have talked past a question he never saw, and "1. yes" typed then answers nothing here.
test("a question waiting behind another mod's: typing withdraws it uncounted, and numbered prose is no answer to it", withKit, async ($, on) => {
  const w = world(on)
  expect(await bash($ as never, 'save-question')).toBe('asked')
  const hidden = ask($ as never)
  await tick(w)
  await type($ as never, '1. 7 days')
  const r = await hidden
  expect(r.result).toBeUndefined()
  expect(r.deny).toBe(MESSAGE)
  expect(w.logs).toEqual([])
  await bash($ as never, 'save-answered')
  // In view now: the first pass that counts allows one more asking.
  const seen = ask($ as never)
  await tick(w)
  await type($ as never, 'one moment')
  expect((await seen).deny).toMatch(/ask it again once; never more than once\.$/)
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

// #703: CLAUDE.md's keep the issue loop moving rule has Claude offer next issues as a picker, and an
// offer made from that rule carries no next-issue tag for the refusal to see. Claude's system prompt
// says pickers are off for as long as they are, so the rule is overridden for the session (spec #615
// point 4), and says nothing once /pickers on brings them back.
test('while next issue pickers are off, the system prompt tells Claude so, and stops once /pickers on brings them back', withKit, async ($, on) => {
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
  expect((await lines(ui)).filter(l => l.endsWith(' chosen'))).toEqual(['1: 1 day chosen', '2: 7 days chosen'])
  await ui.press({ key: 'picker-manners:submit' })
  expect((await call).result?.answers).toEqual({ [QUESTION.question]: '1 day, 7 days' })
  await ui.unmount()
})

test('a prompt that is not Dan (a plugin or a peer) leaves the question open', withKit, async ($, on) => {
  const w = world(on)
  const call = ask($ as never)
  await tick(w)
  await type($ as never, 'a peer session says hello', 'peer')
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

// A hook that throws is skipped and the chain goes on, so a pass that cannot be recorded must not
// throw: Claude Code's own picker would then ask the question Dan just talked past.
test('a talk past that cannot be recorded is logged, and the question still ends with its refusal, never the engine picker', withKit, async ($, on) => {
  const w = world(on)
  on('state.set', ($, e, next) => {
    if ((e as { key?: string }).key === 'passed') return { deny: 'the store is gone' } as never
    return next(e)
  })
  const call = ask($ as never)
  await tick(w)
  await type($ as never, 'one moment')
  const r = await call
  expect(r.deny).toBe(MESSAGE)
  expect(w.reachedEngine).toEqual([])
  expect(w.debug).toHaveLength(1)
  expect(w.debug[0]).toMatch(/^Picker manners could not record that Dan passed over this question, so it may be asked again: .*the store is gone$/)
})

test('a band that cannot be cleared is logged, and the answer still reaches Claude', withKit, async ($, on) => {
  const w = world(on)
  const q = { ...QUESTION, question: 'Which one, though this band cannot be cleared?' }
  const call = ask($ as never, q)
  await tick(w)
  const ui = (await $.ui.mount(band)) as unknown as Ui
  await ui.press({ key: 'picker-manners:opt1' })
  expect((await call).result?.answers).toEqual({ [q.question]: '1 day' })
  expect(w.debug).toEqual(['Picker manners could not clear the question: the band is gone'])
  await ui.unmount()
})
