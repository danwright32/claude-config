import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type { StepsCard } from '../types/index.d.ts'

// mod-kit, standing in: a mod cannot import another mod's files, and the kit loads this stand in as
// a module of its own, so it keeps the rows and the pane in its own $.state and draws them in the
// band and the pane, text and buttons keyed as the real one keys them, so a test reads and presses
// what Dan would. It refuses every row and pane while KIT_REFUSE is set. mod-kit's own tests prove
// the real drawing, the same in both (#690).
type Row = { mod: string; id: string; slot: string; frame?: { kind: string; color?: string }; lines: Record<string, unknown>[][] }
const modKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    const bandRef = { plugin: 'mod-kit', key: 'band' } as const
    const paneRef = { plugin: 'mod-kit', key: 'panes' } as const
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const held = async () => ((await built.state.get(bandRef as never)) as { value?: Row[] }).value ?? []
      const heldPanes = async () => ((await built.state.get(paneRef as never)) as { value?: Row[] }).value ?? []
      const modkit = {
        bandRow: async (row: Row) => {
          const refuse = await built.env.get('KIT_REFUSE')
          if (refuse) throw new Error(refuse)
          await built.state.set(bandRef as never, [...(await held()).filter(r => !(r.mod === row.mod && r.id === row.id)), row] as never)
        },
        clearBandRow: async ({ mod, id }: { mod: string; id: string }) => {
          await built.state.set(bandRef as never, (await held()).filter(r => !(r.mod === mod && r.id === id)) as never)
        },
        pane: async (pane: Row) => {
          const refuse = (await built.env.get("KIT_REFUSE")) || (await built.env.get("KIT_REFUSE_PANE"))
          if (refuse) throw new Error(refuse)
          await built.state.set(paneRef as never, [...(await heldPanes()).filter(r => !(r.mod === pane.mod && r.id === pane.id)), pane] as never)
        },
        clearPane: async ({ mod, id }: { mod: string; id: string }) => {
          await built.state.set(paneRef as never, (await heldPanes()).filter(r => !(r.mod === mod && r.id === id)) as never)
        },
      }
      return { ...built, modkit } as never
    })
    // How a test reads the rows and panes it holds: a Bash call of "band" or "panes", answered here as JSON.
    on('tool.call', { tool: 'Bash' }, async ($, e) => {
      const command = (e as { command?: string }).command
      if (command === 'panes') return { deny: JSON.stringify(((await $.state.get(paneRef as never)) as { value?: Row[] }).value ?? []) }
      if (command !== 'band') return { deny: 'not the band' }
      return { deny: JSON.stringify(((await $.state.get(bandRef as never)) as { value?: Row[] }).value ?? []) }
    })
    on('ui.render', { component: 'Pane' }, async ($, e, next) => {
      const pane = (((await $.state.get(paneRef as never)) as { value?: Row[] }).value ?? []).find(r => r.id === e.requestId)
      if (!pane) return next(e)
      const { Box, Button, Text } = $.ui.resolve(e)
      return (
        <Box flexDirection="column">
          {pane.lines.map((l, n) => (
            <Box key={String(n)} flexDirection="row">
              {l.map((p, i) =>
                p.button ? (
                  <Button key={`${pane.mod}:${p.button as string}`} label={p.label as string} onPress={() => undefined} />
                ) : (
                  <Text key={String(i)} bold={p.bold as boolean | undefined}>
                    {p.text as string}
                  </Text>
                ),
              )}
            </Box>
          ))}
        </Box>
      )
    })
    on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
      const shown = ((await $.state.get(bandRef as never)) as { value?: Row[] }).value ?? []
      if (!shown.length) return next(e)
      const { Box, Button, Text } = $.ui.resolve(e)
      return (
        <Box flexDirection="column">
          {shown.flatMap(r =>
            r.lines.map((l, n) => (
              <Box key={`${r.id}${n}`} flexDirection="row">
                {l.map((p, i) =>
                  p.button ? (
                    <Button key={`${r.mod}:${p.button as string}`} label={p.label as string} onPress={() => undefined} />
                  ) : (
                    <Text key={String(i)}>{p.text as string}</Text>
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

// The scope modes mod (#621), standing in: Dan is away while AWAY is set, and a hold is reported
// as a toast the test reads, as the real one keeps it for the held card.
const scopeModes: { name: string; register: Register } = {
  name: 'scope-modes',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const away = async () => (await built.env.get('AWAY')) === '1'
      const modes = {
        isAway: away,
        hold: async ({ label, prompt }: { label: string; prompt: string }) => {
          if ((await built.env.get('AWAY')) === 'broken') throw new Error('the held list could not be read')
          if (!(await away())) return { isHeld: false }
          built.ui.toast(`held: ${label} | ${prompt}`)
          return { isHeld: true }
        },
      }
      return { ...built, scopeModes: modes } as never
    })
  },
}
const withAway = { plugins: [modKit, scopeModes] }

const TOOL = 'mcp__manual-steps__steps'
const VERDICT = 'mcp__manual-steps__steps_done'
const ROOT = '/repo'

// Claude Code beneath the mod: the session, the plugin's store in memory, panes that fit or do not
// as each test sets, the prompt, the clipboard and toasts, each recorded.
type World = { wide: boolean; copied: boolean; submitFails: boolean; storeFails: boolean }
const world = (on: On, init: Partial<World> = {}, store: Record<string, unknown> = {}, env: Record<string, string> = {}) => {
  const w: World = { wide: false, copied: true, submitFails: false, storeFails: false, ...init }
  const mem: Record<string, unknown> = { ...store }
  const opened: string[] = []
  const closed: string[] = []
  const prompts: string[] = []
  const toasts: string[] = []
  const copies: string[] = []
  const tools: string[] = []
  const commands: string[] = []
  mock.env(on, env)
  on('store.get', ($, e) => ({ value: mem[e.key] }) as never)
  on('store.set', ($, e) => {
    if (w.storeFails) throw new Error('the store is over 4 MiB')
    mem[e.key] = JSON.parse(JSON.stringify(e.value))
    return { value: undefined } as never
  })
  on('store.delete', ($, e) => {
    delete mem[e.key]
    return { value: undefined } as never
  })
  on('session.root', () => ({ value: ROOT }) as never)
  on('session.cwd', () => ({ value: ROOT }) as never)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('tool.register', ($, e) => {
    tools.push(String((e as { name?: string }).name))
    return { value: undefined } as never
  })
  on('command.register', ($, e) => {
    commands.push(String((e as { name?: string }).name))
    return { value: undefined } as never
  })
  on('ui.open', ($, e) => {
    opened.push(e.id)
    return { value: w.wide ? { isPlaced: true } : { isPlaced: false, reason: 'unasked panes need 144 columns; the terminal is 120' } } as never
  })
  on('ui.close', ($, e) => {
    closed.push(e.id)
    return { value: undefined } as never
  })
  on('prompt.submit', ($, e) => {
    if (w.submitFails) throw new Error('the prompt queue is closed')
    prompts.push(e.text)
    return { text: e.text } as never
  })
  on('ui.copy', ($, e) => {
    copies.push(e.text)
    return { value: w.copied ? { isCopied: true } : { isCopied: false, reason: 'no-clipboard' } } as never
  })
  on('ui.toast', ($, e) => {
    toasts.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  on('ui.log', () => ({ value: undefined }) as never)
  on('prompt.context', ($, e) => ({ blocks: e.blocks }))
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine band</Text>
  })
  return { w, mem, opened, closed, prompts, toasts, copies, tools, commands }
}

type Mounted = { press: (t: object) => Promise<unknown>; find: (q: object) => Promise<{ props: Record<string, unknown>; children: unknown[] } | undefined>; unmount: () => Promise<void> }
type Engine = {
  session: { start: (e: never) => Promise<unknown> }
  tool: { call: (e: never) => Promise<unknown> }
  ui: { mount: (e: never) => Promise<Mounted> }
}
const start = ($: Engine) => $.session.start({ cwd: ROOT, surface: 'terminal', isInteractive: true } as never)
const call = async ($: Engine, tool: string, input: object) => {
  const r = (await $.tool.call({ tool, tool_use_id: 't1', ...input } as never)) as { deny?: string; text?: string; result?: unknown }
  return r.deny !== undefined ? `refused: ${r.deny}` : String(r.result ?? r.text ?? '')
}
const step = (over: Record<string, unknown> = {}) => ({ title: 'Turn on the WAF rule', url: 'https://dash.cloudflare.com/waf', checked: 'not-done', ...over })
const hand = ($: Engine, steps: object[], heading = 'Cloudflare WAF') => call($, TOOL, { heading, steps })
// The card's row as the stand in mod-kit holds it now, and its lines as text.
const band = async ($: Engine) => {
  const out = (await $.tool.call({ tool: 'Bash', tool_use_id: 'b1', command: 'band' } as never)) as { deny?: string; text?: string }
  const rows = JSON.parse(out.deny ?? out.text ?? '[]') as Row[]
  return rows.find(r => r.mod === 'manual-steps' && r.id === 'steps')
}
// The card's pane as the stand in mod-kit holds it now.
const paneShown = async ($: Engine) => {
  const out = (await $.tool.call({ tool: 'Bash', tool_use_id: 'p1', command: 'panes' } as never)) as { deny?: string; text?: string }
  return (JSON.parse(out.deny ?? out.text ?? '[]') as Row[]).find(r => r.mod === 'manual-steps' && r.id === 'steps')
}
const bandText = async ($: Engine) => ((await band($))?.lines ?? []).map(l => l.map(p => (p.text as string) ?? `[${p.button as string}]`).join(''))
const stored = (mem: Record<string, unknown>) => mem[`card:${ROOT}`] as StepsCard | undefined
const bandProps = { hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 100, scroll: { offset: 0, bodyRows: 20 }, view: {} }
// Dan pressing a button the card shows in the band, as he would: on mod-kit's drawing.
const press = async ($: Engine, button: 'done' | 'copy') => {
  const ui = await $.ui.mount({ plugin: 'mod-kit', surface: 'terminal', component: 'AbovePrompt', props: bandProps } as never)
  await ui.press({ key: `manual-steps:${button}` })
  await ui.unmount()
}

test('the tools and /steps exist only where a person is at the prompt', withKit, async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: ROOT, surface: null, isInteractive: false } as never)
  expect(w.tools).toEqual([])
  await start($)
  expect(w.tools.sort()).toEqual(['steps', 'steps_done'])
  expect(w.commands).toEqual(['steps'])
})

test('a step with no link or exact location is refused, and nothing is pinned', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  const out = await hand($, [step(), step({ title: 'Save it', url: undefined })])
  expect(out).toMatch(/^refused: Step 2 \(Save it\) has no link or exact location/)
  expect(await band($)).toBeUndefined()
  expect(w.opened).toEqual([])
  expect(stored(w.mem)).toBeUndefined()
})

test('at laptop width the card is the steps row of the band, with the amber left rule', withKit, async ($, on) => {
  const w = world(on, { wide: false })
  await start($)
  const out = await hand($, [step(), step({ title: 'Purge the cache' })])
  expect(out).toMatch(/step 1 of 2 is next/)
  // The pane was tried unasked and did not fit, so it was closed rather than left waiting.
  expect(w.opened).toEqual(['steps'])
  expect(w.closed).toEqual(['steps'])
  expect(await band($)).toMatchObject({ slot: 'steps', frame: { kind: 'left-rule', color: 'warning' } })
  expect(await bandText($)).toEqual(['Cloudflare WAF', '1. Turn on the WAF rule  [done]', 'https://dash.cloudflare.com/waf', '2. Purge the cache'])
})

test('when the terminal is wide the card is the side pane, and the band stays clear', withKit, async ($, on) => {
  const w = world(on, { wide: true })
  await start($)
  await hand($, [step()])
  expect(w.closed).toEqual([])
  expect(await band($)).toBeUndefined()
  // Drawn by mod-kit with the band's own drawing, the amber left rule included (#690).
  expect(await paneShown($)).toMatchObject({ frame: { kind: 'left-rule', color: 'warning' } })
  const ui = await $.ui.mount({ plugin: 'mod-kit', surface: 'terminal', component: 'Pane', requestId: 'steps', props: { bodyColumns: 50 } } as never)
  expect(await ui.find({ type: 'Text', text: 'Cloudflare WAF' })).toBeDefined()
  expect((await ui.find({ type: 'Text', text: '1. Turn on the WAF rule' }))?.props).toMatchObject({ bold: true })
  expect((await ui.find({ type: 'Button', key: 'manual-steps:done' }))?.props.label).toBe('Done')
  expect((await paneShown($))?.lines.length).toBe(3)
  // Done pressed in the pane does what Done in the band does.
  await ui.press({ key: 'manual-steps:done' })
  expect(w.prompts).toEqual(['step 1 done'])
  await ui.unmount()
  // The pane shows the change: the step waits on Claude, its Done gone.
  const after = ((await paneShown($))?.lines ?? []).map(l => l.map(p => (p.text as string) ?? `[${p.button as string}]`).join(''))
  expect(after[1]).toBe('1. Turn on the WAF rule  sent')
  // Claude's verdict ends the card, and the pane with it.
  expect(await call($, VERDICT, { step: 1, checked: 'checked' })).toMatch(/every step is finished/i)
  expect(await paneShown($)).toBeUndefined()
  expect(w.closed).toEqual(['steps'])
})

// A pane mod-kit will not draw is never opened empty: the card goes to the band instead.
test('when mod-kit refuses the pane, the card is the steps row of the band and no pane opens', withKit, async ($, on) => {
  const w = world(on, { wide: true }, {}, { KIT_REFUSE_PANE: 'the pane is held by another mod' })
  await start($)
  expect(await hand($, [step()])).toMatch(/step 1 of 1 is next/)
  expect(w.opened).toEqual([])
  expect(await paneShown($)).toBeUndefined()
  expect(await bandText($)).toEqual(['Cloudflare WAF', '1. Turn on the WAF rule  [done]', 'https://dash.cloudflare.com/waf'])
})

test('steps found already done are marked so, and a card that is all done is not pinned', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  const out = await hand($, [step({ checked: 'already-done' }), step({ checked: 'already-done', title: 'Second' })])
  expect(out).toMatch(/all 2 steps were already done/i)
  expect(await band($)).toBeUndefined()
  expect(w.opened).toEqual([])
  await hand($, [step({ checked: 'already-done', title: 'Made the token' }), step({ title: 'Second' })])
  expect((await bandText($)).slice(0, 3)).toEqual(['Cloudflare WAF', '1. Made the token  already done', '2. Second  [done]'])
})

test('a step that does not say it was checked first is refused', withKit, async ($, on) => {
  world(on)
  await start($)
  expect(await hand($, [step({ checked: undefined })])).toMatch(/refused: .*checked to already-done, not-done or cannot-check/)
})

test('Done on a step Claude can check: "step 1 done" is sent, then Claude marks it checked, in green, and the next step opens', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  await hand($, [step(), step({ title: 'Purge the cache' })])
  await press($, 'done')
  expect(w.prompts).toEqual(['step 1 done'])
  expect((await bandText($))[1]).toBe('1. Turn on the WAF rule  sent')
  expect(await call($, VERDICT, { step: 1, checked: 'checked' })).toMatch(/step 2 of 2 is next/)
  expect((await band($))?.lines[1]?.[1]).toEqual({ text: '  checked', color: 'success' })
  expect((await bandText($))[2]).toBe('2. Purge the cache  [done]')
})

test('Done on a step Claude cannot check reads "done, per you"; the last one finished takes the card away', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  await hand($, [step({ checked: 'cannot-check' }), step({ title: 'Purge the cache' })])
  await press($, 'done')
  expect(w.prompts).toEqual(['step 1 done'])
  await call($, VERDICT, { step: 1, checked: 'per-you' })
  expect((await band($))?.lines[1]?.[1]).toEqual({ text: '  done, per you', dim: true })
  expect(stored(w.mem)?.steps[0]?.finished).toBe('per-you')
  expect(await call($, VERDICT, { step: 2, checked: 'per-you' })).toMatch(/every step is finished/i)
  expect(await band($)).toBeUndefined()
  expect(stored(w.mem)).toBeUndefined()
})

test('a step Claude found did not take opens again, with Done', withKit, async ($, on) => {
  world(on)
  await start($)
  await hand($, [step()])
  await press($, 'done')
  await call($, VERDICT, { step: 1, checked: 'not-done' })
  expect((await bandText($))[1]).toBe('1. Turn on the WAF rule  [done]')
})

test('a Done that cannot reach Claude opens the step again and says so', withKit, async ($, on) => {
  const w = world(on, { submitFails: true })
  await start($)
  await hand($, [step()])
  await press($, 'done')
  expect((await bandText($))[1]).toBe('1. Turn on the WAF rule  [done]')
  // A hook beneath that fails is skipped, so Claude Code answers that nothing took the prompt.
  expect(w.toasts).toHaveLength(1)
  expect(w.toasts[0]).toMatch(/^Could not tell Claude step 1 is done: .+\. Press Done again\.$/)
  expect(w.prompts).toEqual([])
})

test('a verdict with no card, or on a step that is not there, is refused by name', withKit, async ($, on) => {
  world(on)
  await start($)
  expect(await call($, VERDICT, { step: 1, checked: 'checked' })).toMatch(/refused: No steps are pinned/)
  await hand($, [step()])
  expect(await call($, VERDICT, { step: 4, checked: 'checked' })).toMatch(/refused: There is no step 4/)
})

test('Copy puts the value on the clipboard, and says when it could not', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  await hand($, [step({ value: 'ip.src eq 1.2.3.4' })])
  await press($, 'copy')
  expect(w.copies).toEqual(['ip.src eq 1.2.3.4'])
  expect(w.toasts).toEqual(['Copied the value for step 1.'])
  w.w.copied = false
  await press($, 'copy')
  expect(w.toasts[1]).toBe('Could not copy the value for step 1 (no-clipboard).')
})

test('when mod-kit refuses the row, the handover says the card could not be shown', withKit, async ($, on) => {
  world(on, {}, {}, { KIT_REFUSE: 'mod-kit is not loaded' })
  await start($)
  expect(await hand($, [step()])).toMatch(/could not be shown: mod-kit is not loaded/)
})

test('a store that cannot be written is said, and the card still shows', withKit, async ($, on) => {
  const w = world(on, { storeFails: true })
  await start($)
  expect(await hand($, [step()])).toMatch(/step 1 of 1 is next/)
  expect(w.toasts).toHaveLength(1)
  expect(w.toasts[0]).toMatch(/^The manual steps could not be saved for the next session: .+\.$/)
  expect((await bandText($))[1]).toBe('1. Turn on the WAF rule  [done]')
})

test('unfinished steps carry over: the next session in the project holds them until Claude re-checks them', withKit, async ($, on) => {
  const card: StepsCard = {
    heading: 'Cloudflare WAF',
    steps: [
      { title: 'Made the token', url: 'https://a.example', finished: 'checked' },
      { title: 'Purge the cache', url: 'https://b.example' },
    ],
  }
  const w = world(on, {}, { [`card:${ROOT}`]: card })
  await start($)
  // Held, not shown, until re-checked.
  expect(await band($)).toBeUndefined()
  expect(w.opened).toEqual([])
  const ctx = (await ($ as unknown as { prompt: { context: (e: object) => Promise<{ blocks: { name: string; text: string }[] }> } }).prompt.context({ blocks: [] })).blocks
  const note = ctx.find(b => b.name === 'manualSteps')?.text ?? ''
  expect(note).toMatch(/carried over/)
  expect(note).toMatch(/step 2: Purge the cache \(https:\/\/b\.example\)/)
  expect(note).not.toMatch(/Made the token/)
  // Done cannot be recorded on steps nobody has re-checked.
  expect(await call($, VERDICT, { step: 2, checked: 'checked' })).toMatch(/refused: No steps are pinned/)
  // Re-pinned by Claude after checking: shown, the note no longer sent, the store holding the new card.
  await hand($, [step({ title: 'Purge the cache', url: 'https://b.example' })])
  expect((await bandText($))[1]).toBe('1. Purge the cache  [done]')
  expect(stored(w.mem)?.steps.map(s => s.title)).toEqual(['Purge the cache'])
  const after = (await ($ as unknown as { prompt: { context: (e: object) => Promise<{ blocks: { name: string }[] }> } }).prompt.context({ blocks: [] })).blocks
  expect(after.find(b => b.name === 'manualSteps')).toBeUndefined()
})

test('a finished card is not carried over', withKit, async ($, on) => {
  const card: StepsCard = { heading: 'x', steps: [{ title: 'Done already', url: 'https://a.example', finished: 'checked' }] }
  world(on, {}, { [`card:${ROOT}`]: card })
  await start($)
  const ctx = (await ($ as unknown as { prompt: { context: (e: object) => Promise<{ blocks: { name: string }[] }> } }).prompt.context({ blocks: [] })).blocks
  expect(ctx.find(b => b.name === 'manualSteps')).toBeUndefined()
})

test('a handover is kept per project for the next session, and /steps shows it again', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  await hand($, [step()])
  expect(stored(w.mem)?.heading).toBe('Cloudflare WAF')
  expect(await band($)).toBeDefined()
  // Asked, the pane is placed at any width, and the band row gives way to it.
  w.w.wide = true
  const r = (await ($ as unknown as { command: { run: (e: object) => Promise<{ text?: string }> } }).command.run({ command: 'steps' })) as { text?: string }
  expect(r.text).toBe('The steps card is open.')
  expect(w.opened).toEqual(['steps', 'steps'])
  expect(await band($)).toBeUndefined()
})

// Dan closing the pane by hand (the card then moves to the band) is not covered here: the test
// kit's engine carries no ui.close to raise with a person's origin (2.1.289), so only a live
// session shows it.

test('while Dan is away the steps are held for the held card, not shown on the Mac, and kept', withAway, async ($, on) => {
  const w = world(on, { wide: true }, {}, { AWAY: '1' })
  await start($)
  const out = await hand($, [step(), step({ title: 'Purge the cache' })])
  expect(out).toMatch(/Dan is away/)
  expect(w.opened).toEqual([])
  expect(await band($)).toBeUndefined()
  expect(w.toasts).toHaveLength(1)
  expect(w.toasts[0]).toMatch(/^held: Cloudflare WAF \| .*check each against the current state/)
  // Kept for the next session too, in case Dan comes home in another one.
  expect(stored(w.mem)?.steps.map(s => s.title)).toEqual(['Turn on the WAF rule', 'Purge the cache'])
})

test('at home, with the scope modes mod loaded, the card shows as usual', withAway, async ($, on) => {
  const w = world(on, { wide: false })
  await start($)
  expect(await hand($, [step()])).toMatch(/step 1 of 1 is next/)
  expect(w.toasts).toEqual([])
  expect((await bandText($))[1]).toBe('1. Turn on the WAF rule  [done]')
})

test('when the scope modes mod cannot answer, the card is shown rather than lost', withAway, async ($, on) => {
  world(on, { wide: false }, {}, { AWAY: 'broken' })
  await start($)
  expect(await hand($, [step()])).toMatch(/step 1 of 1 is next/)
  expect((await bandText($))[1]).toBe('1. Turn on the WAF rule  [done]')
})

test('/steps with nothing pinned says so', withKit, async ($, on) => {
  world(on)
  await start($)
  const r = (await ($ as unknown as { command: { run: (e: object) => Promise<{ text?: string }> } }).command.run({ command: 'steps' })) as { text?: string }
  expect(r.text).toBe('No manual steps are pinned for this project.')
})
