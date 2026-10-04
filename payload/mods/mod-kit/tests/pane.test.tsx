import { expect, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type { ModKitPane } from '../types/index.d.ts'

// A mod's card in a side pane (#690): the mod opens the pane with $.ui.open as ever and publishes
// what is in it through $.modkit.pane, and mod-kit draws it with the band's own row drawing, so a
// card reads the same in the pane and in the band. A stand in publisher turns Bash commands into
// calls on the noun, as the band's tests do.
const publisher: { name: string; register: Register } = {
  name: 'publisher',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => {
      const [verb, ...rest] = String((e as { command?: string }).command).split(' ')
      try {
        if (verb === 'pane') await $.modkit.pane(JSON.parse(rest.join(' ')) as ModKitPane)
        if (verb === 'unpane') await $.modkit.clearPane({ mod: rest[0] as string, id: rest[1] as string })
        if (verb === 'band') await $.modkit.bandRow({ ...(JSON.parse(rest.join(' ')) as ModKitPane), slot: 'steps' })
      } catch (err) {
        return { deny: `refused: ${String((err as Error).message ?? err)}` }
      }
      return { deny: 'done' }
    })
    // The publisher's own handler for its button, reached through the press on mod-kit's drawing.
    on('ui.press', { plugin: 'mod-kit', element: 'publisher:done' }, ($, e) => {
      $.ui.toast(`pressed ${e.element} on ${String(e.surface)}`)
      return { element: e.element }
    })
  },
}
const withPublisher = { plugins: [publisher] }

type Caller = { tool: { call: (e: never) => Promise<unknown> } }
const run = async ($: Caller, command: string) => {
  const out = (await $.tool.call({ tool: 'Bash', command } as never)) as { deny?: string; text?: string }
  return out.deny ?? out.text ?? ''
}
const card = (over: Partial<ModKitPane> = {}): ModKitPane => ({
  mod: 'publisher',
  id: 'steps',
  frame: { kind: 'left-rule', color: 'warning' },
  lines: [[{ text: 'Cloudflare WAF', color: 'warning' }], [{ text: '1. Turn on the WAF rule', bold: true }, { text: '  ' }, { button: 'done', label: 'Done' }], [{ text: 'https://dash.cloudflare.com/waf', indent: 3 }]],
  ...over,
})
const pane = (surface: 'terminal' | 'desktop' = 'terminal', requestId = 'steps') =>
  ({ plugin: 'mod-kit', surface, component: 'Pane', requestId, props: { title: 'Manual steps', isFocused: false, bodyColumns: 50 } }) as never
const bandProps = { hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 100, scroll: { offset: 0, bodyRows: 20 }, view: {} }
type Found = { text: string; children: unknown[] }
const shown = async (ui: { findAll: (q: { type: string }) => Promise<Found[]> }) =>
  (await ui.findAll({ type: 'Text' })).filter(t => t.children.every(c => typeof c === 'string')).map(t => t.text)

// Claude Code beneath the kit: what it draws where no mod draws.
const engine = (on: On) => {
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
}

test('a published pane is drawn as its card, with the left rule in its colour, on every surface', withPublisher, async ($, on) => {
  engine(on)
  expect(await run($, `pane ${JSON.stringify(card())}`)).toBe('done')
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount(pane(surface))
    expect(await shown(ui)).toEqual(['│', '│', '│', 'Cloudflare WAF', '1. Turn on the WAF rule', '  ', 'https://dash.cloudflare.com/waf'])
    expect((await ui.find({ type: 'Text', text: '1. Turn on the WAF rule' }))?.props).toMatchObject({ bold: true })
    const rule = await ui.find({ type: 'Box', key: 'publisher/steps:rule' })
    const marks = (rule?.children ?? []) as { props: { color?: string } }[]
    expect(marks).toHaveLength(3)
    expect(marks.every(m => m.props.color === 'warning')).toBe(true)
    expect((await ui.findAll({ type: 'Box' })).filter(b => b.props.paddingLeft === 3).map(b => b.text)).toEqual(['https://dash.cloudflare.com/waf'])
    expect(await ui.find({ text: 'engine' })).toBeUndefined()
    await ui.unmount()
  }
})

test("a button in the pane is Claude Code's own, and its press reaches the publisher", withPublisher, async ($, on) => {
  engine(on)
  const toasts: string[] = []
  on('ui.toast', ($, e) => {
    toasts.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  await run($, `pane ${JSON.stringify(card())}`)
  const ui = await $.ui.mount(pane())
  expect((await ui.find({ type: 'Button', key: 'publisher:done' }))?.props.label).toBe('Done')
  await ui.press({ key: 'publisher:done' })
  expect(toasts).toEqual(['pressed publisher:done on terminal'])
  await ui.unmount()
})

test('the pane and the band draw one row the same way', withPublisher, async ($, on) => {
  engine(on)
  await run($, `pane ${JSON.stringify(card())}`)
  await run($, `band ${JSON.stringify(card())}`)
  const inPane = await $.ui.mount(pane())
  const inBand = await $.ui.mount({ plugin: 'mod-kit', surface: 'terminal', component: 'AbovePrompt', props: bandProps } as never)
  expect(await shown(inPane)).toEqual(await shown(inBand))
  await inPane.unmount()
  await inBand.unmount()
})

test('a pane nothing was published for, or one cleared, is left to whoever draws it', withPublisher, async ($, on) => {
  engine(on)
  let ui = await $.ui.mount(pane('terminal', 'other'))
  expect(await ui.find({ text: 'engine' })).toBeDefined()
  await ui.unmount()
  await run($, `pane ${JSON.stringify(card())}`)
  await run($, 'unpane publisher steps')
  ui = await $.ui.mount(pane())
  expect(await ui.find({ text: 'engine' })).toBeDefined()
  expect(await ui.find({ text: 'Cloudflare WAF' })).toBeUndefined()
  await ui.unmount()
})

test('a pane published again replaces what it showed', withPublisher, async ($, on) => {
  engine(on)
  await run($, `pane ${JSON.stringify(card())}`)
  await run($, `pane ${JSON.stringify(card({ lines: [[{ text: 'Every step is finished' }]] }))}`)
  const ui = await $.ui.mount(pane())
  expect(await shown(ui)).toEqual(['│', 'Every step is finished'])
  await ui.unmount()
})

test('a pane naming no mod or id, malformed lines, an unknown frame, or a pane another mod holds is refused by name', withPublisher, async ($, on) => {
  engine(on)
  expect(await run($, `pane ${JSON.stringify(card({ id: '' }))}`)).toMatch(/refused: .*mod and an id/)
  expect(await run($, `pane ${JSON.stringify(card({ lines: [{ divider: false }] as never }))}`)).toMatch(/refused: .*lines must be/)
  expect(await run($, `pane ${JSON.stringify(card({ frame: { kind: 'double' } as never }))}`)).toMatch(/refused: .*frame kind "double"/)
  expect(await run($, `pane ${JSON.stringify(card())}`)).toBe('done')
  // Claude Code keys a pane by its id alone, so two mods drawing one id would fight over it.
  expect(await run($, `pane ${JSON.stringify(card({ mod: 'someone-else' }))}`)).toMatch(/refused: .*pane "steps" is already drawn for publisher/)
  const ui = await $.ui.mount(pane())
  expect(await ui.find({ text: 'Cloudflare WAF' })).toBeDefined()
  await ui.unmount()
})
