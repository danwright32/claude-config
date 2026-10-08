import { expect, mock, test } from 'claude-code/testing'
import type { Mounted as KitMounted } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type { ModKitBandRow, ModKitPane } from '../.claude-plugin/types/mod-kit/index.d.ts'
import { DROPPED_AFTER_MS } from '../hooks/card.ts'
import { STEPS_DESCRIPTION, VERDICT_DESCRIPTION, VERDICT_INPUT } from '../hooks/register.tsx'
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
        bandRow: async (row: ModKitBandRow) => {
          const refuse = await built.env.get('KIT_REFUSE')
          if (refuse) throw new Error(refuse)
          await built.state.set(bandRef as never, [...(await held()).filter(r => !(r.mod === row.mod && r.id === row.id)), row] as never)
        },
        clearBandRow: async ({ mod, id }: { mod: string; id: string }) => {
          await built.state.set(bandRef as never, (await held()).filter(r => !(r.mod === mod && r.id === id)) as never)
        },
        pane: async (pane: ModKitPane) => {
          const refuse = (await built.env.get("KIT_REFUSE")) || (await built.env.get("KIT_REFUSE_PANE"))
          if (refuse) throw new Error(refuse)
          await built.state.set(paneRef as never, [...(await heldPanes()).filter(r => !(r.mod === pane.mod && r.id === pane.id)), pane] as never)
        },
        clearPane: async ({ mod, id }: { mod: string; id: string }) => {
          await built.state.set(paneRef as never, (await heldPanes()).filter(r => !(r.mod === mod && r.id === id)) as never)
        },
        // The screen (#707): refuses a call carrying SCREEN-REFUSES, as the secret guard refuses a
        // token; mod-kit's own tests prove the real one asks the secret guard.
        screen: async (call: unknown) => (JSON.stringify(call).includes('SCREEN-REFUSES') ? { deny: 'Blocked: this message contains a secret. Refer to it by its name, not its value.' } : null),
        // #939: a press raised by the kit's Button below, and whether a click lands; every Button here is clickable.
        press: async () => ({ isAnswered: false }),
        clickable: async () => true,
        // The kit's other members, which these tests never reach: each refuses by name if one ever is.
        blocked: async () => { throw new Error("mod-kit's blocked is not stood in by these tests") },
        card: async () => { throw new Error("mod-kit's card is not stood in by these tests") },
        commands: async () => { throw new Error("mod-kit's commands is not stood in by these tests") },
        writes: async () => { throw new Error("mod-kit's writes is not stood in by these tests") },
        git: async () => { throw new Error("mod-kit's git is not stood in by these tests") },
        pipeline: async () => { throw new Error("mod-kit's pipeline is not stood in by these tests") },
        workingTree: async () => { throw new Error("mod-kit's workingTree is not stood in by these tests") },
      }
      return { ...built, modkit }
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
                  <Button key={`${pane.mod}:${p.button as string}`} label={p.label as string} onPress={press => void $.modkit.press({ element: press.element, surface: String(press.surface), how: 'click' })} />
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
                    <Button key={`${r.mod}:${p.button as string}`} label={p.label as string} onPress={press => void $.modkit.press({ element: press.element, surface: String(press.surface), how: 'click' })} />
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
      return { ...built, scopeModes: modes }
    })
  },
}
const withAway = { plugins: [modKit, scopeModes] }

const TOOL = 'mcp__manual-steps__steps'
const VERDICT = 'mcp__manual-steps__steps_done'
const ROOT = '/repo'

// Claude Code beneath the mod: the session, the plugin's store in memory, panes placed by Claude
// Code's own rule (asked, at any width; unasked, from 144 columns, or 110 for an id once asked,
// which it remembers), the prompt, the clipboard and toasts, each recorded. `wide` is a 160 column
// terminal, else 120, a laptop. `root` is where the session runs, `repoRoot` the repository's root
// (the main checkout's for a worktree), null outside one.
// `placesNoPanes` is a session whose attached surfaces place no panes at all, asked or not.
type World = { wide: boolean; copied: boolean; submitFails: boolean; storeFails: boolean; root: string; repoRoot: string | null; repoFails: boolean; isAsking: boolean; placesNoPanes: boolean }
const world = (on: On, init: Partial<World> = {}, store: Record<string, unknown> = {}, env: Record<string, string> = {}) => {
  const w: World = { wide: false, copied: true, submitFails: false, storeFails: false, root: ROOT, repoRoot: ROOT, repoFails: false, isAsking: false, placesNoPanes: false, ...init }
  const mem: Record<string, unknown> = { ...store }
  const asked = new Set<string>()
  const opens: { id: string; columns?: number }[] = []
  const opened: string[] = []
  const closed: string[] = []
  const prompts: string[] = []
  const toasts: string[] = []
  const copies: string[] = []
  const tools: string[] = []
  const commands: string[] = []
  // Read at each call, so a test can change one part way through.
  on('env.get', ($, e) => ({ value: env[e.name] }) as never)
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
  on('session.root', () => ({ value: w.root }) as never)
  on('session.cwd', () => ({ value: w.root }) as never)
  on('session.repo', () => {
    if (w.repoFails) throw new Error('git could not read the working copy')
    return { value: w.repoRoot === null ? null : { root: w.repoRoot, remote: null, internal: false, name: null } } as never
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('turn.complete', ($, e) => ({ text: e.answer }))
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
    opens.push({ id: e.id, columns: e.columns })
    if (w.placesNoPanes) return { value: { isPlaced: false, reason: 'the attached surfaces place no panes' } } as never
    if (w.isAsking) asked.add(e.id)
    const floor = asked.has(e.id) ? 110 : 144
    const columns = w.wide ? 160 : 120
    if (w.isAsking || columns >= floor) return { value: { isPlaced: true } } as never
    return { value: { isPlaced: false, reason: `unasked panes need ${floor} columns; the terminal is ${columns}` } } as never
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
  // The settings Stop hooks beneath the mods: they block nothing, unless STOP_BLOCK names a block.
  on('classic.Stop', () => (env.STOP_BLOCK ? { block: env.STOP_BLOCK } : {}) as never)
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine band</Text>
  })
  return { w, mem, opened, opens, closed, prompts, toasts, copies, tools, commands }
}

type Mounted = Pick<KitMounted<'terminal'>, 'press' | 'find' | 'unmount'>
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
// The card's pane as the stand in mod-kit holds it now, under whichever of its ids; never two.
const paneShown = async ($: Engine) => {
  const out = (await $.tool.call({ tool: 'Bash', tool_use_id: 'p1', command: 'panes' } as never)) as { deny?: string; text?: string }
  const mine = (JSON.parse(out.deny ?? out.text ?? '[]') as Row[]).filter(r => r.mod === 'manual-steps')
  expect(mine.length).toBeLessThanOrEqual(1)
  return mine[0]
}
const bandText = async ($: Engine) => ((await band($))?.lines ?? []).map(l => l.map(p => (p.text as string) ?? `[${p.button as string}]`).join(''))
const stored = (mem: Record<string, unknown>) => mem[`card:${ROOT}`] as StepsCard | undefined
const bandProps = { hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 100, scroll: { offset: 0, bodyRows: 20 }, view: {} }
// Dan pressing a button the card shows in the band, as he would: on mod-kit's drawing.
const press = async ($: Engine, button: 'done' | 'copy' | 'copy-link') => {
  const ui = await $.ui.mount({ plugin: 'mod-kit', surface: 'terminal', component: 'AbovePrompt', props: bandProps } as never)
  await ui.press({ key: `manual-steps:${button}` })
  await ui.unmount()
}
// Dan typing /steps: a pane it opens is asked for, which Claude Code places at any width.
const slashSteps = async ($: Engine, w: World) => {
  w.isAsking = true
  try {
    return ((await ($ as unknown as { command: { run: (e: object) => Promise<{ text?: string }> } }).command.run({ command: 'steps' })) as { text?: string }).text
  } finally {
    w.isAsking = false
  }
}
// What Claude reads beside Dan's next message.
const context = async ($: Engine) => (await ($ as unknown as { prompt: { context: (e: object) => Promise<{ blocks: { name: string; text: string }[] }> } }).prompt.context({ blocks: [] })).blocks
// A main loop turn starting with a prompt, and ending.
type Turns = { turn: { start: (e: object) => Promise<unknown>; complete: (e: object) => Promise<unknown> } }
const turnStart = ($: Engine, text: string, turnId: string) => ($ as unknown as Turns).turn.start({ text, turnId })
const turnEnd = ($: Engine, turnId: string, reason: 'answer' | 'aborted' = 'answer', agentId?: string) =>
  ($ as unknown as Turns).turn.complete({ answer: 'Checked it.', durationMs: 5, isAborted: reason === 'aborted', turnId, reason, ...(agentId ? { agentId } : {}) })

test('the tools and /steps exist only where a person is at the prompt', withKit, async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: ROOT, surface: null, isInteractive: false } as never)
  expect(w.tools).toEqual([])
  await start($)
  expect(w.tools.sort()).toEqual(['steps', 'steps_done'])
  expect(w.commands).toEqual(['steps'])
})

// #707: this mod answers its tools itself, so the secret guard beneath it never sees them; it asks
// mod-kit's screen first. A step whose value carries a token is refused before anything is pinned,
// drawn with Copy or kept for the next session, and so is a verdict carrying one.
test('steps a guard refuses are refused before anything is pinned, shown or kept (#707)', withKit, async ($, on) => {
  const w = world(on, { wide: true })
  await start($)
  const out = await hand($, [step({ value: 'sk_live_SCREEN-REFUSES' })])
  expect(out).toBe('refused: Blocked: this message contains a secret. Refer to it by its name, not its value.')
  expect(await band($)).toBeUndefined()
  expect(await paneShown($)).toBeUndefined()
  expect(w.opened).toEqual([])
  expect(stored(w.mem)).toBeUndefined()
  // A clean card pins as ever; a verdict on it carrying a token is refused and changes nothing.
  expect(await hand($, [step()])).toMatch(/^Pinned/)
  const v = await call($, VERDICT, { step: 1, checked: 'per-you', note: 'SCREEN-REFUSES' })
  expect(v).toBe('refused: Blocked: this message contains a secret. Refer to it by its name, not its value.')
  expect(stored(w.mem)?.steps[0]?.finished).toBeUndefined()
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
  expect(w.opened).toHaveLength(1)
  expect(w.closed).toEqual(w.opened)
  expect(await band($)).toMatchObject({ slot: 'steps', frame: { kind: 'left-rule', color: 'warning' } })
  expect(await bandText($)).toEqual(['Cloudflare WAF  waiting on you', '1. Turn on the WAF rule  [done]', 'Where: [copy-link]', 'https://dash.cloudflare.com/waf', '2. Purge the cache'])
})

test('when the terminal is wide the card is the side pane, and the band stays clear', withKit, async ($, on) => {
  const w = world(on, { wide: true })
  await start($)
  await hand($, [step()])
  expect(w.closed).toEqual([])
  expect(await band($)).toBeUndefined()
  // Drawn by mod-kit with the band's own drawing, the amber left rule included (#690).
  expect(await paneShown($)).toMatchObject({ frame: { kind: 'left-rule', color: 'warning' } })
  expect(w.opened).toHaveLength(1)
  const ui = await $.ui.mount({ plugin: 'mod-kit', surface: 'terminal', component: 'Pane', requestId: w.opened[0], props: { bodyColumns: 50 } } as never)
  expect(await ui.find({ type: 'Text', text: 'Cloudflare WAF' })).toBeDefined()
  expect((await ui.find({ type: 'Text', text: '1. Turn on the WAF rule' }))?.props).toMatchObject({ bold: true })
  expect((await ui.find({ type: 'Button', key: 'manual-steps:done' }))?.props.label).toBe('Done')
  expect((await paneShown($))?.lines.length).toBe(4)
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
  expect(w.closed).toEqual(w.opened)
})

// A pane mod-kit will not draw is never opened empty: the card goes to the band instead.
test('when mod-kit refuses the pane, the card is the steps row of the band and no pane opens', withKit, async ($, on) => {
  const w = world(on, { wide: true }, {}, { KIT_REFUSE_PANE: 'the pane is held by another mod' })
  await start($)
  expect(await hand($, [step()])).toMatch(/step 1 of 1 is next/)
  expect(w.opened).toEqual([])
  expect(await paneShown($)).toBeUndefined()
  expect(await bandText($)).toEqual(['Cloudflare WAF  waiting on you', '1. Turn on the WAF rule  [done]', 'Where: [copy-link]', 'https://dash.cloudflare.com/waf'])
})

test('steps found already done are marked so, and a card that is all done is not pinned', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  const out = await hand($, [step({ checked: 'already-done' }), step({ checked: 'already-done', title: 'Second' })])
  expect(out).toMatch(/all 2 steps were already done/i)
  expect(await band($)).toBeUndefined()
  expect(w.opened).toEqual([])
  await hand($, [step({ checked: 'already-done', title: 'Made the token' }), step({ title: 'Second' })])
  expect((await bandText($)).slice(0, 3)).toEqual(['Cloudflare WAF  waiting on you', '1. Made the token  already done before this card', '2. Second  [done]'])
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
  expect((await band($))?.lines[1]?.[1]).toMatchObject({ text: expect.stringMatching(/^  checked on [A-Z][a-z]{2} \d{1,2} at \d{1,2}:\d{2} [AP]M$/), color: 'success' })
  expect((await bandText($))[2]).toBe('2. Purge the cache  [done]')
})

// #939 review: where Done cannot be clicked the card says what to type, which must be the very prompt
// a press sends, read from the press itself rather than from a second literal.
test('the words Done says to type are the prompt a Done press sends', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  await hand($, [step(), step({ title: 'Purge the cache' })])
  const done = (await band($))?.lines[1]?.find(p => p.button === 'done') as { instead?: { text: string }[] } | undefined
  const typed = (done?.instead ?? []).map(r => r.text).join('')
  await press($, 'done')
  expect(typed).toBe(`type: ${w.prompts[0]}`)
})

test('Done on a step Claude cannot check reads "done, you pressed Done" with its time; the last one finished takes the card away', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  await hand($, [step({ checked: 'cannot-check' }), step({ title: 'Purge the cache' })])
  await press($, 'done')
  expect(w.prompts).toEqual(['step 1 done'])
  await call($, VERDICT, { step: 1, checked: 'per-you' })
  expect((await band($))?.lines[1]?.[1]).toEqual({ text: expect.stringMatching(/^  done, you pressed Done on [A-Z][a-z]{2} \d{1,2} at \d{1,2}:\d{2} [AP]M$/) })
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

// #708: Claude Code draws no hyperlinks on Apple Terminal, where a long link is plain text cut at
// the edge, so Copy link is what takes the whole address on every terminal.
test('Copy link puts the open step\'s whole link on the clipboard, and says when it could not', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  const url = `https://dash.cloudflare.com/${'a'.repeat(200)}/security/waf`
  await hand($, [step({ url, value: 'ip.src eq 1.2.3.4' })])
  await press($, 'copy-link')
  expect(w.copies).toEqual([url])
  expect(w.toasts).toEqual(['Copied the link for step 1.'])
  w.w.copied = false
  await press($, 'copy-link')
  expect(w.toasts[1]).toBe('Could not copy the link for step 1 (no-clipboard).')
  // Copy beside the value still copies the value.
  w.w.copied = true
  await press($, 'copy')
  expect(w.copies[2]).toBe('ip.src eq 1.2.3.4')
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
  // Asked, the pane is placed at any width (this terminal is 120), and the band row gives way to it.
  expect(await slashSteps($, w.w)).toBe('The steps card is open.')
  expect(w.opened).toHaveLength(2)
  expect(await band($)).toBeUndefined()
  expect((await paneShown($))?.lines.length).toBe(4)
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
  const w = world(on)
  await start($)
  expect(await slashSteps($, w.w)).toBe('No manual steps are pinned for this project.')
})

// #708: the gaps the milestone audit found.

test('the carried note names a way out that clears: every step re-pinned as already-done empties the store, and no note comes back', withKit, async ($, on) => {
  const card: StepsCard = { heading: 'Cloudflare WAF', steps: [{ title: 'Purge the cache', url: 'https://b.example' }] }
  const w = world(on, {}, { [`card:${ROOT}`]: card })
  await start($)
  expect((await context($)).find(b => b.name === 'manualSteps')?.text).toMatch(/already-done/)
  // Claude checks, finds it done, and does what the note asks.
  expect(await hand($, [step({ title: 'Purge the cache', url: 'https://b.example', checked: 'already-done' })])).toMatch(/already done, so nothing was pinned/)
  expect(stored(w.mem)).toBeUndefined()
  expect((await context($)).find(b => b.name === 'manualSteps')).toBeUndefined()
  // The next session in the project has nothing carried.
  await start($)
  expect((await context($)).find(b => b.name === 'manualSteps')).toBeUndefined()
  expect(await slashSteps($, w.w)).toBe('No manual steps are pinned for this project.')
})

test('steps are kept under the repository root, so a worktree session and the main checkout share one card', withKit, async ($, on) => {
  const w = world(on, { root: `${ROOT}/.claude/worktrees/a1`, repoRoot: ROOT })
  await start($)
  await hand($, [step()])
  expect(Object.keys(w.mem)).toEqual([`card:${ROOT}`])
  expect(stored(w.mem)?.heading).toBe('Cloudflare WAF')
})

test('a card kept by the main checkout is carried into a worktree session of the same repository', withKit, async ($, on) => {
  const card: StepsCard = { heading: 'Cloudflare WAF', steps: [{ title: 'Purge the cache', url: 'https://b.example' }] }
  world(on, { root: `${ROOT}/.claude/worktrees/a1`, repoRoot: ROOT }, { [`card:${ROOT}`]: card })
  await start($)
  expect((await context($)).find(b => b.name === 'manualSteps')?.text).toMatch(/step 1: Purge the cache/)
})

// Not knowing the repository is not the same as being outside one: kept under the worktree's own
// folder, the card would be lost to the main checkout, the defect #708 fixed.
test('a repository that cannot be read keeps nothing under the folder, and says the steps were not saved', withKit, async ($, on) => {
  const w = world(on, { root: `${ROOT}/.claude/worktrees/a1`, repoRoot: ROOT, repoFails: true })
  await start($)
  expect(await hand($, [step()])).toMatch(/step 1 of 1 is next/)
  expect(Object.keys(w.mem)).toEqual([])
  expect(w.toasts).toHaveLength(1)
  // The kit skips a hook beneath that throws and answers that nothing implements the call, so the
  // reason is the engine's, not this world's.
  expect(w.toasts[0]).toMatch(/^The manual steps could not be saved for the next session: .+\.$/)
  expect((await bandText($))[1]).toBe('1. Turn on the WAF rule  [done]')
})

test('outside a repository the steps are kept under the folder', withKit, async ($, on) => {
  const w = world(on, { root: '/notes', repoRoot: null })
  await start($)
  await hand($, [step()])
  expect(Object.keys(w.mem)).toEqual(['card:/notes'])
})

test('a card a worktree session kept under the worktree before #708 is found, and moved to the repository root', withKit, async ($, on) => {
  const tree = `${ROOT}/.claude/worktrees/a1`
  const card: StepsCard = { heading: 'Cloudflare WAF', steps: [{ title: 'Purge the cache', url: 'https://b.example' }] }
  const w = world(on, { root: tree, repoRoot: ROOT }, { [`card:${tree}`]: card })
  await start($)
  expect((await context($)).find(b => b.name === 'manualSteps')?.text).toMatch(/step 1: Purge the cache/)
  expect(Object.keys(w.mem)).toEqual([`card:${ROOT}`])
  expect(stored(w.mem)?.heading).toBe('Cloudflare WAF')
})

// #708 lessons review: with a card under the root too, the worktree's own was never read again.
test('a card kept under the worktree beside one under the root is folded into the held card for Claude to re-check, never lost', withKit, async ($, on) => {
  const tree = `${ROOT}/.claude/worktrees/a1`
  const atRoot: StepsCard = { heading: 'Cloudflare WAF', steps: [{ title: 'Purge the cache', url: 'https://b.example' }] }
  const inTree: StepsCard = {
    heading: 'DNS',
    steps: [
      { title: 'Made the record', url: 'https://c.example', finished: 'checked' },
      { title: 'Add the CNAME', url: 'https://d.example' },
    ],
  }
  const w = world(on, { root: tree, repoRoot: ROOT }, { [`card:${ROOT}`]: atRoot, [`card:${tree}`]: inTree })
  await start($)
  const note = (await context($)).find(b => b.name === 'manualSteps')?.text ?? ''
  expect(note).toMatch(/step 1: Purge the cache \(https:\/\/b\.example\)/)
  expect(note).toMatch(/step 2: DNS: Add the CNAME \(https:\/\/d\.example\)/)
  expect(note).not.toMatch(/Made the record/)
  expect(Object.keys(w.mem)).toEqual([`card:${ROOT}`])
  expect(stored(w.mem)?.steps.map(s => s.title)).toEqual(['Purge the cache', 'DNS: Add the CNAME'])
})

test('a reload mid session keeps the live card live: verdicts land, and no carried note is sent', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  await hand($, [step(), step({ title: 'Purge the cache' })])
  await press($, 'done')
  // The mod reloaded: Claude Code runs session.start again and keeps $.state.
  await start($)
  expect((await context($)).find(b => b.name === 'manualSteps')).toBeUndefined()
  expect(await call($, VERDICT, { step: 1, checked: 'checked' })).toMatch(/step 2 of 2 is next/)
  expect((await bandText($))[2]).toBe('2. Purge the cache  [done]')
  expect(w.toasts).toEqual([])
})

test('a Done Claude never answers comes back when the turn it started ends, and says so', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  await hand($, [step()])
  await press($, 'done')
  expect((await bandText($))[1]).toBe('1. Turn on the WAF rule  sent')
  // "sent" is never kept for another session: that turn will not answer there.
  expect(stored(w.mem)?.steps[0]?.isSent).toBeUndefined()
  await turnStart($, 'step 1 done', 'T2')
  await turnEnd($, 'T2')
  expect((await bandText($))[1]).toBe('1. Turn on the WAF rule  [done]')
  expect(w.toasts).toEqual(['Claude did not say whether step 1 took. Press Done to ask again.'])
  // A verdict Claude gives later still lands.
  expect(await call($, VERDICT, { step: 1, checked: 'checked' })).toMatch(/every step is finished/i)
})

test('an interrupted turn brings Done back too', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  await hand($, [step()])
  await press($, 'done')
  await turnStart($, 'step 1 done', 'T2')
  await turnEnd($, 'T2', 'aborted')
  expect((await bandText($))[1]).toBe('1. Turn on the WAF rule  [done]')
  expect(w.toasts).toHaveLength(1)
})

test('only the end of the turn "step N done" started counts: one already running, or a subagent\'s, leaves it sent', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  await hand($, [step()])
  // Done pressed while Claude was busy: the prompt waits behind the running turn.
  await turnStart($, 'fix the tests', 'T1')
  await press($, 'done')
  await turnEnd($, 'T1')
  await turnEnd($, 'T9', 'answer', 'agent-1')
  expect((await bandText($))[1]).toBe('1. Turn on the WAF rule  sent')
  // Its own turn runs, and Claude answers in it: nothing comes back and nothing is said.
  await turnStart($, 'step 1 done', 'T2')
  expect(await call($, VERDICT, { step: 1, checked: 'checked' })).toMatch(/every step is finished/i)
  await turnEnd($, 'T2')
  expect(await band($)).toBeUndefined()
  expect(w.toasts).toEqual([])
})

// #734: a "step N done" prompt queued behind a running turn and then dropped (Esc drops the queue)
// starts no turn, so the guard above never arms. Once nothing has run for DROPPED_AFTER_MS with the
// step still sent and its turn never started, Done comes back with the same toast. The clock is the
// test's: nothing here waits for real.
const RELEASED = 'Claude did not say whether step 1 took. Press Done to ask again.'
test('a Done whose prompt is dropped behind a running turn comes back once nothing has run for a while, and says so (#734)', withKit, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await hand($, [step()])
  await turnStart($, 'fix the tests', 'T1')
  await press($, 'done')
  // Claude works on past the bound: a prompt waiting behind a running turn is never taken for dropped.
  await clock.advance(DROPPED_AFTER_MS * 3)
  expect((await bandText($))[1]).toBe('1. Turn on the WAF rule  sent')
  // Esc: the running turn ends interrupted, and the queued prompt goes with it.
  await turnEnd($, 'T1', 'aborted')
  await clock.advance(DROPPED_AFTER_MS - 1)
  expect((await bandText($))[1]).toBe('1. Turn on the WAF rule  sent')
  expect(w.toasts).toEqual([])
  await clock.advance(1)
  expect((await bandText($))[1]).toBe('1. Turn on the WAF rule  [done]')
  expect(w.toasts).toEqual([RELEASED])
  // A verdict Claude gives later still lands.
  expect(await call($, VERDICT, { step: 1, checked: 'checked' })).toMatch(/every step is finished/i)
})

test('a Done pressed with nothing running whose prompt starts no turn comes back too (#734)', withKit, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await hand($, [step()])
  // The prompt went in, but a prompt hook refused it, so no turn began.
  await press($, 'done')
  await clock.advance(DROPPED_AFTER_MS)
  expect((await bandText($))[1]).toBe('1. Turn on the WAF rule  [done]')
  expect(w.toasts).toEqual([RELEASED])
})

// The queued prompt's turn starts only after the settings hooks that end a turn and begin the next
// have run, which can take seconds; it is never released in that gap, nor while its turn runs, and
// the fallback armed at the press does not fire early just after the turn it waited behind ended.
test('a queued Done whose turn starts after the turn ahead of it ends is never released by the fallback (#734)', withKit, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world(on)
  await start($)
  await hand($, [step()])
  await turnStart($, 'fix the tests', 'T1')
  await press($, 'done')
  await clock.advance(DROPPED_AFTER_MS - 1_000)
  await turnEnd($, 'T1')
  // Past the press's own bound, a few seconds after the turn ahead ended: still waiting.
  await clock.advance(30_000)
  expect((await bandText($))[1]).toBe('1. Turn on the WAF rule  sent')
  await turnStart($, 'step 1 done', 'T2')
  await clock.advance(DROPPED_AFTER_MS * 2)
  expect((await bandText($))[1]).toBe('1. Turn on the WAF rule  sent')
  expect(await call($, VERDICT, { step: 1, checked: 'checked' })).toMatch(/every step is finished/i)
  await turnEnd($, 'T2')
  expect(w.toasts).toEqual([])
})

test('/steps does not lower the width a card opened unasked needs: the next one at laptop width is still the band', withKit, async ($, on) => {
  const w = world(on, { wide: false })
  await start($)
  await hand($, [step()])
  expect(await band($)).toBeDefined()
  expect(await slashSteps($, w.w)).toBe('The steps card is open.')
  // The pane /steps opens is not the one a new card tries unasked.
  expect(new Set(w.opened).size).toBe(2)
  expect(await call($, VERDICT, { step: 1, checked: 'checked' })).toMatch(/every step is finished/i)
  // A later card, unasked, at 120 columns: the band, as at any laptop width.
  await hand($, [step({ title: 'Purge the cache' })])
  expect((await bandText($))[1]).toBe('1. Purge the cache  [done]')
  expect(await paneShown($)).toBeUndefined()
})

test('/steps with the card in the pane opened unasked moves it to its own pane and closes the other, so there are never two', withKit, async ($, on) => {
  const w = world(on, { wide: true })
  await start($)
  await hand($, [step()])
  const unasked = w.opened[0]
  expect(await slashSteps($, w.w)).toBe('The steps card is open.')
  const askedId = w.opened[1]
  expect(askedId).not.toBe(unasked)
  expect(w.closed).toEqual([unasked])
  expect(await paneShown($)).toMatchObject({ id: askedId })
  // Done from the pane /steps opened, and the last verdict closes that pane.
  const ui = await $.ui.mount({ plugin: 'mod-kit', surface: 'terminal', component: 'Pane', requestId: askedId, props: { bodyColumns: 50 } } as never)
  await ui.press({ key: 'manual-steps:done' })
  await ui.unmount()
  expect(w.prompts).toEqual(['step 1 done'])
  await call($, VERDICT, { step: 1, checked: 'checked' })
  expect(w.closed).toEqual([unasked, askedId])
  expect(await paneShown($)).toBeUndefined()
})

// #708 lessons review: the band took the card while the pane opened unasked still showed it.
test('/steps where its pane cannot be placed moves the card to the band and closes the pane that held it', withKit, async ($, on) => {
  const w = world(on, { wide: true })
  await start($)
  await hand($, [step()])
  const unasked = w.opened[0]
  expect(await paneShown($)).toBeDefined()
  w.w.placesNoPanes = true
  expect(await slashSteps($, w.w)).toBe('The steps card is in the band above the prompt.')
  expect((await bandText($))[1]).toBe('1. Turn on the WAF rule  [done]')
  expect(w.closed).toContain(unasked)
  expect(await paneShown($)).toBeUndefined()
})

test('a new card mod-kit will not draw in the open pane goes to the band, and the pane with the old card closes', withKit, async ($, on) => {
  const env: Record<string, string> = {}
  const w = world(on, { wide: true }, {}, env)
  await start($)
  await hand($, [step()])
  expect(await paneShown($)).toBeDefined()
  env.KIT_REFUSE_PANE = 'the pane is held by another mod'
  expect(await hand($, [step({ title: 'Purge the cache' })])).toMatch(/step 1 of 1 is next/)
  expect((await bandText($))[1]).toBe('1. Purge the cache  [done]')
  expect(w.closed).toContain(w.opened[0])
  expect(await paneShown($)).toBeUndefined()
})

test('a card pinned while /steps has the pane open replaces the card in that pane, opening nothing more', withKit, async ($, on) => {
  const w = world(on, { wide: false })
  await start($)
  await hand($, [step()])
  await slashSteps($, w.w)
  const opens = w.opened.length
  await hand($, [step({ title: 'Purge the cache' })])
  expect(w.opened).toHaveLength(opens)
  expect(await band($)).toBeUndefined()
  expect((await paneShown($))?.lines[1]?.[0]).toMatchObject({ text: '1. Purge the cache' })
})

test('the pane asks for a dock as wide as the open step\'s lines, so a click path is not cut, up to 80 columns', withKit, async ($, on) => {
  const w = world(on, { wide: true })
  await start($)
  const clicks = 'Websites, example.com, Security, WAF, Custom rules, Create rule'
  // Each card finished before the next, so each opens the pane afresh.
  const pinFresh = async (over: Record<string, unknown>) => {
    await hand($, [step(over)])
    await call($, VERDICT, { step: 1, checked: 'checked' })
  }
  await pinFresh({ clicks })
  // The rule and its gap, the indent under the title, the bold label (#872), then the click path.
  expect(w.opens[0]?.columns).toBe(2 + 3 + 'What to do: '.length + clicks.length)
  // A link is not measured: it opens whole however much of it shows. The widest line left is the
  // title with the words drawn where Done cannot be clicked (#939).
  await pinFresh({ url: `https://dash.cloudflare.com/${'a'.repeat(150)}` })
  expect(w.opens[1]?.columns).toBe(2 + '1. Turn on the WAF rule  type: step 1 done'.length)
  await pinFresh({ clicks: 'x'.repeat(200) })
  expect(w.opens[2]?.columns).toBe(80)
  expect(w.opens).toHaveLength(3)
})

// ---- #863: a step handed over in prose is put on the card ----

// The turn's end as Claude Code raises it: Claude's final message, and whether a Stop hook already
// blocked this chain of turn ends.
const turnStop = async ($: Engine, said: string, isActive = false) =>
  (await ($ as unknown as { classic: { Stop: (e: object) => Promise<unknown> } }).classic.Stop({
    hook_event_name: 'Stop',
    session_id: 's1',
    transcript_path: '/t',
    cwd: ROOT,
    stop_hook_active: isActive,
    last_assistant_message: said,
  })) as { block?: string }
const PROSE_STEP = "The one thing still waiting on you is the migration command from my earlier message. #3415 merges after that, and it's the last piece of the goal."

test('a step left waiting on Dan in prose, with no card, blocks the turn end once and asks for the steps tool (#863)', withKit, async ($, on) => {
  world(on)
  await start($)
  const r = await turnStop($, PROSE_STEP)
  expect(r.block).toMatch(/"waiting on you"/)
  expect(r.block).toMatch(/mcp__manual-steps__steps\b/)
  expect(r.block).toMatch(/check it against the current state/i)
  // The same chain's next turn end is never blocked again, so it cannot loop.
  expect((await turnStop($, PROSE_STEP, true)).block).toBeUndefined()
})

test('with an unfinished step on the card, the same words pass (#863)', withKit, async ($, on) => {
  world(on)
  await start($)
  await hand($, [step()])
  expect((await turnStop($, PROSE_STEP)).block).toBeUndefined()
  // Once every step is finished the card is gone, and the words block again.
  await call($, VERDICT, { step: 1, checked: 'checked' })
  expect((await turnStop($, PROSE_STEP)).block).toMatch(/steps tool/)
})

test('ordinary prose at the turn end passes (#863)', withKit, async ($, on) => {
  world(on)
  await start($)
  expect((await turnStop($, 'Merged #812 and the deploy is live. Nothing else is waiting on you.')).block).toBeUndefined()
  expect((await turnStop($, 'The tests pass and the PR is up.')).block).toBeUndefined()
})

test('steps carried from an earlier session and not yet re-checked are not a card Dan can see, so the words block (#863)', withKit, async ($, on) => {
  const card: StepsCard = { heading: 'Cloudflare WAF', steps: [{ title: 'Purge the cache', url: 'https://b.example' }] }
  world(on, {}, { [`card:${ROOT}`]: card })
  await start($)
  expect((await turnStop($, PROSE_STEP)).block).toMatch(/steps tool/)
})

test('a -p run or the SDK, where nobody is at the prompt and there is no steps tool, is never blocked (#863)', withKit, async ($, on) => {
  world(on)
  await $.session.start({ cwd: ROOT, surface: null, isInteractive: false } as never)
  expect((await turnStop($, PROSE_STEP)).block).toBeUndefined()
})

test('a block another Stop hook gives is kept beside this one (#863)', withKit, async ($, on) => {
  world(on, {}, {}, { STOP_BLOCK: 'Winding down is not finished: PR #12 is not merged yet.' })
  await start($)
  const r = await turnStop($, PROSE_STEP)
  expect(r.block).toMatch(/^Winding down is not finished: PR #12 is not merged yet\./)
  expect(r.block).toMatch(/steps tool/)
})

test('the band says the open step is waiting on Dan while it is, and clears once it is done (#863)', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  await hand($, [step(), step({ title: 'Purge the cache' })])
  expect((await bandText($)).slice(0, 2)).toEqual(['Cloudflare WAF  waiting on you', '1. Turn on the WAF rule  [done]'])
  // Sent, it waits on Claude, not on Dan.
  await press($, 'done')
  expect(w.prompts).toEqual(['step 1 done'])
  expect((await bandText($))[0]).toBe('Cloudflare WAF')
  // The next step is Dan's again.
  await call($, VERDICT, { step: 1, checked: 'checked' })
  expect((await bandText($))[0]).toBe('Cloudflare WAF  waiting on you')
  expect((await bandText($))[2]).toBe('2. Purge the cache  [done]')
  await call($, VERDICT, { step: 2, checked: 'checked' })
  expect(await band($)).toBeUndefined()
})

// #872, Dan: "step 5 can't be done right now. you should only show me what can be done". The steps
// tool says a step goes on the card only when Dan can do it now, and a step pinned anyway comes off
// through steps_done as withdrawn, shown as taken off rather than done.
test('the steps tool asks only for steps Dan can do now; one waiting on something else stays in the issue', () => {
  expect(STEPS_DESCRIPTION).toMatch(/only a step Dan can do now/)
  expect(STEPS_DESCRIPTION).toMatch(/waiting on something else .*stays in the issue/)
  expect((VERDICT_INPUT.properties.checked as { enum: string[] }).enum).toContain('withdrawn')
})

test('steps_done withdrawn takes a pinned step off the card as not done, and the card moves on', withKit, async ($, on) => {
  world(on)
  await start($)
  await hand($, [step(), step({ title: 'Watch the next merge' })])
  expect(await call($, VERDICT, { step: 2, checked: 'withdrawn' })).toMatch(/^Step 2 recorded/)
  expect(await bandText($)).toEqual([
    'Cloudflare WAF  waiting on you',
    '1. Turn on the WAF rule  [done]',
    'Where: [copy-link]', 'https://dash.cloudflare.com/waf',
    expect.stringMatching(/^2\. Watch the next merge  taken off on [A-Z][a-z]{2} \d{1,2} at \d{1,2}:\d{2} [AP]M, not done$/),
  ])
  expect(await call($, VERDICT, { step: 1, checked: 'withdrawn' })).toMatch(/card is gone/)
  expect(await band($)).toBeUndefined()
})

// #886: "step 2 done" on a three step card with step 1 open was recorded as steps 1 and 2, and the
// card said Dan installed a checker he never touched. Only the open step takes a verdict.
test('"step 2 done" with step 1 open is refused with the ask, and nothing is recorded (#886)', withKit, async ($, on) => {
  const w = world(on)
  await start($)
  await hand($, [step({ title: 'Pull' }), step({ title: 'Install the checker' }), step({ title: 'Run the check' })])
  for (const checked of ['per-you', 'checked'])
    expect(await call($, VERDICT, { step: 2, checked })).toMatch(/^refused: Step 2 \(Install the checker\) is not the open step; step 1 \(Pull\) is\. .*Ask Dan which step he means/)
  expect(stored(w.mem)?.steps.map(s => s.finished ?? null)).toEqual([null, null, null])
  expect((await bandText($))[1]).toBe('1. Pull  [done]')
  // The open one takes it.
  expect(await call($, VERDICT, { step: 1, checked: 'per-you' })).toMatch(/^Step 1 recorded; step 2 of 3 is next/)
})

// #886: steps Claude recorded on Dan's word turned grey, and he read them as done days ago.
test('a step recorded per you, with no Done pressed, is labelled so with its time, and is not grey (#886)', withKit, async ($, on) => {
  mock.clock(on, { now: Date.UTC(2026, 9, 7, 16, 0) })
  const w = world(on, {}, {}, { TZ: 'America/New_York' })
  await start($)
  await hand($, [step({ checked: 'cannot-check' }), step({ title: 'Purge the cache' })])
  await call($, VERDICT, { step: 1, checked: 'per-you' })
  const how = (await band($))?.lines[1]
  expect(how?.[0]).toEqual({ text: '1. Turn on the WAF rule', strikethrough: true })
  expect(how?.[1]).toEqual({ text: '  done, per you, recorded on Oct 7 at 12:00 PM' })
  expect(stored(w.mem)?.steps[0]).toMatchObject({ finished: 'per-you', finishedAt: Date.UTC(2026, 9, 7, 16, 0) })
})

test('a step finished in an earlier session shows its age and is grey, on the held card and once pinned again (#886)', withKit, async ($, on) => {
  const NOW = Date.UTC(2026, 9, 7, 16, 0)
  mock.clock(on, { now: NOW })
  const card: StepsCard = {
    heading: 'Chrome sign out',
    steps: [
      { title: 'Sign out', url: 'https://a.example', finished: 'per-you', finishedAt: NOW - 3 * 86_400_000 },
      { title: 'Sign in again', url: 'https://b.example' },
    ],
  }
  // Tokyo, nine hours ahead: Oct 4 at 16:00 there is Oct 5 at 1:00 AM, so the zone is the one set.
  const w = world(on, {}, { [`card:${ROOT}`]: card }, { TZ: 'Asia/Tokyo' })
  await start($)
  await slashSteps($, w.w)
  const held = (await paneShown($))?.lines.map(l => l.map(p => (p.text as string) ?? '').join(''))
  expect(held?.[1]).toBe('1. Sign out  done, per you, in an earlier session on Oct 5 at 1:00 AM')
  expect((await paneShown($))?.lines[1]?.[1]).toMatchObject({ dim: true })
  await hand($, [step({ title: 'Sign out', url: 'https://a.example', checked: 'already-done' }), step({ title: 'Sign in again', url: 'https://b.example' })], 'Chrome sign out')
  const shown = (await paneShown($))?.lines ?? (await band($))?.lines ?? []
  expect(shown[1]?.map(p => p.text).join('')).toBe('1. Sign out  done, per you, in an earlier session on Oct 5 at 1:00 AM')
})

test('steps_done says only the open step takes a verdict, and to ask Dan which step he means (#886)', () => {
  expect(VERDICT_DESCRIPTION).toMatch(/only the open step/i)
  expect(VERDICT_DESCRIPTION).toMatch(/ask Dan which step he means/)
})
