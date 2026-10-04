import { expect, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type { ModKitBandRow, ModKitBandSlot } from '../types/index.d.ts'

// The band above the prompt, which Claude Code gives ONE drawing: every mod publishes its rows
// through $.modkit and mod-kit draws them in the settled order (docs/mods-design.md, "The band,
// shared by every mod"). A stand in publisher turns Bash commands into calls on the noun, as the
// session registry's tests do, since the engine requires a noun to be called in place.
const publisher: { name: string; register: Register } = {
  name: 'publisher',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => {
      const [verb, ...rest] = String((e as { command?: string }).command).split(' ')
      try {
        if (verb === 'show') await $.modkit.bandRow(JSON.parse(rest.join(' ')) as ModKitBandRow)
        if (verb === 'clear') await $.modkit.clearBandRow({ mod: rest[0] as string, id: rest[1] as string })
      } catch (err) {
        return { deny: `refused: ${String((err as Error).message ?? err)}` }
      }
      return { deny: 'done' }
    })
    // The publisher's own handler for its button, reached through the press on mod-kit's drawing.
    // It runs in the publisher's own environment, so it reports through a toast the test can see.
    on('ui.press', { plugin: 'mod-kit', element: 'publisher:go' }, ($, e) => {
      $.ui.toast(`pressed ${e.element}`)
      return { element: e.element }
    })
  },
}
const withPublisher = { plugins: [publisher] }

type Caller = { tool: { call: (e: never) => Promise<unknown> } }
const row = (slot: ModKitBandSlot, text: string, id: string = slot, mod = 'publisher'): ModKitBandRow => ({ mod, id, slot, lines: [[{ text, color: 'warning' }]] })
const show = async ($: Caller, r: unknown) => {
  const out = (await $.tool.call({ tool: 'Bash', command: `show ${JSON.stringify(r)}` } as never)) as { deny?: string; text?: string }
  return out.deny ?? out.text ?? ''
}
const clear = async ($: Caller, mod: string, id: string) => {
  await $.tool.call({ tool: 'Bash', command: `clear ${mod} ${id}` } as never)
}
const props = (hasSurvey = false) => ({ hasSurvey, isWorking: false, maxRows: 20, bodyColumns: 100, scroll: { offset: 0, bodyRows: 20 }, view: {} })
const band = (surface: 'terminal' | 'desktop' = 'terminal', hasSurvey = false) =>
  ({ plugin: 'mod-kit', surface, component: 'AbovePrompt', props: props(hasSurvey) }) as never
// What the band shows, top to bottom: the text of every leaf Text, in document order.
type Found = { text: string; children: unknown[] }
const shown = async (ui: { findAll: (q: { type: string }) => Promise<Found[]> }) =>
  (await ui.findAll({ type: 'Text' })).filter(t => t.children.every(c => typeof c === 'string')).map(t => t.text)

// Claude Code beneath the kit: what it draws in the band when no mod draws there.
const engineBand = (on: On) => {
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine band</Text>
  })
}

test('with no rows the band is left to Claude Code', withPublisher, async ($, on) => {
  engineBand(on)
  const ui = await $.ui.mount(band())
  expect(await ui.find({ text: 'engine band' })).toBeDefined()
  await ui.unmount()
})

test('rows are drawn in the settled order of their slots, whatever order they were published in', withPublisher, async ($, on) => {
  engineBand(on)
  await show($, row('message', 'Message for Kris'))
  await show($, row('steps', 'Steps for you'))
  await show($, row('held', 'Held while away'))
  await show($, row('handoff', 'Where you left off'))
  await show($, row('compact', 'ctx 74%'))
  await show($, row('needs-a-look', 'PR #636 checks failing'))
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount(band(surface))
    // Status first, then what waits on Dan nearest the prompt (docs/mods-design.md).
    expect(await shown(ui)).toEqual(['PR #636 checks failing', 'ctx 74%', 'Where you left off', 'Held while away', 'Steps for you', 'Message for Kris'])
    expect(await ui.find({ text: 'engine band' })).toBeUndefined()
    await ui.unmount()
  }
})

test('an open question takes the band alone, and the rest comes back once it is cleared', withPublisher, async ($, on) => {
  engineBand(on)
  await show($, row('needs-a-look', 'NO BUILD'))
  await show($, row('steps', 'Steps for you'))
  await show($, row('question', 'Which one?'))
  const ui = await $.ui.mount(band())
  expect(await shown(ui)).toEqual(['Which one?'])
  await clear($, 'publisher', 'question')
  expect(await shown(ui)).toEqual(['NO BUILD', 'Steps for you'])
  await ui.unmount()
})

test('a row published again under its id is replaced in place, and a cleared one is gone', withPublisher, async ($, on) => {
  engineBand(on)
  await show($, row('needs-a-look', 'first', 'a'))
  await show($, row('needs-a-look', 'second', 'b', 'other'))
  await show($, row('needs-a-look', 'first again', 'a'))
  const ui = await $.ui.mount(band())
  // Within a slot, rows keep the order they were first published in.
  expect(await shown(ui)).toEqual(['first again', 'second'])
  await clear($, 'other', 'b')
  expect(await shown(ui)).toEqual(['first again'])
  // Clearing what is not there changes nothing and is no error.
  await clear($, 'nobody', 'x')
  expect(await shown(ui)).toEqual(['first again'])
  await clear($, 'publisher', 'a')
  expect(await ui.find({ text: 'engine band' })).toBeDefined()
  await ui.unmount()
})

test('a survey holds the band: the rows yield to it', withPublisher, async ($, on) => {
  engineBand(on)
  await show($, row('needs-a-look', 'PR #636 checks failing'))
  const ui = await $.ui.mount(band('terminal', true))
  expect(await ui.find({ text: 'PR #636 checks failing' })).toBeUndefined()
  expect(await ui.find({ text: 'engine band' })).toBeDefined()
  await ui.unmount()
})

test("a button in a row is Claude Code's own, and its press reaches the publisher", withPublisher, async ($, on) => {
  engineBand(on)
  const presses: string[] = []
  on('ui.toast', ($, e) => {
    presses.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  await show($, { mod: 'publisher', id: 'compact', slot: 'compact', lines: [[{ text: 'ctx 74% ', color: 'warning' }, { button: 'go', label: 'Compact' }]] })
  const ui = await $.ui.mount(band())
  const b = await ui.find({ type: 'Button', key: 'publisher:go' })
  expect(b?.props.label).toBe('Compact')
  await ui.press({ key: 'publisher:go' })
  expect(presses).toEqual(['pressed publisher:go'])
  await ui.unmount()
})

// #667: a band button may ask for Claude Code's plain style (the hotkey in the accent colour, a
// colon, the label; the label alone with no hotkey), so an option reads "1: 7 days", not "[ 7 days ]".
test("a button marked plain is drawn in Claude Code's plain style, and one not marked keeps its brackets", withPublisher, async ($, on) => {
  engineBand(on)
  await show($, { mod: 'publisher', id: 'q', slot: 'question', lines: [[{ button: 'opt1', label: '7 days', hotkey: '1', plain: true }], [{ button: 'go', label: 'Submit' }]] })
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount(band(surface))
    const plain = await ui.find({ type: 'Button', key: 'publisher:opt1' })
    expect(plain?.props.plain).toBe(true)
    expect(plain?.props.hotkey).toBe('1')
    expect(plain?.props.label).toBe('7 days')
    expect((await ui.find({ type: 'Button', key: 'publisher:go' }))?.props.plain).toBeUndefined()
    await ui.unmount()
  }
})

// Lessons review of #678: plain is a button's style, so a text run carrying it is refused by name
// rather than quietly ignored.
test('plain on a text run is refused, naming the text run', withPublisher, async ($, on) => {
  engineBand(on)
  expect(await show($, { mod: 'publisher', id: 'q', slot: 'steps', lines: [[{ text: 'note', plain: true }]] })).toMatch(/refused: .*only a button can be plain/)
})

test('plain set to anything but true is refused at publish, never drawn as a bracketed button', withPublisher, async ($, on) => {
  engineBand(on)
  expect(await show($, { mod: 'publisher', id: 'q', slot: 'steps', lines: [[{ button: 'opt1', label: '7 days', plain: 'yes' }]] })).toMatch(/refused: .*plain must be true/)
  expect(await show($, { mod: 'publisher', id: 'q', slot: 'steps', lines: [[{ button: 'opt1', label: '7 days', plain: false }]] })).toMatch(/refused: .*plain must be true/)
})

test('a row in no settled slot, or naming no mod or id, is refused by name', withPublisher, async ($, on) => {
  engineBand(on)
  expect(await show($, { mod: 'publisher', id: 'x', slot: 'top', lines: [] })).toMatch(/refused: .*slot "top"/)
  expect(await show($, { mod: '', id: 'x', slot: 'steps', lines: [] })).toMatch(/refused: .*mod and an id/)
  const ui = await $.ui.mount(band())
  expect(await ui.find({ text: 'engine band' })).toBeDefined()
  await ui.unmount()
})

test('text styles reach the drawing: amber, bold, dim', withPublisher, async ($, on) => {
  engineBand(on)
  await show($, {
    mod: 'publisher',
    id: 'l',
    slot: 'needs-a-look',
    lines: [[{ text: 'NO BUILD', color: 'warning', bold: true }, { text: ' | ', dim: true }, { text: '2 unpushed commits', color: 'warning' }]],
  })
  const ui = await $.ui.mount(band())
  expect((await ui.find({ type: 'Text', text: 'NO BUILD' }))?.props).toMatchObject({ color: 'warning', bold: true })
  expect((await ui.find({ type: 'Text', text: ' | ' }))?.props).toMatchObject({ dimColor: true })
  await ui.unmount()
})

test('a box frame draws the row inside a rounded border, grey unless the row names a colour', withPublisher, async ($, on) => {
  engineBand(on)
  await show($, { mod: 'publisher', id: 'held', slot: 'held', frame: { kind: 'box' }, lines: [[{ text: 'Held while away' }]] })
  await show($, { mod: 'publisher', id: 'hand', slot: 'handoff', frame: { kind: 'box', color: 'warning' }, lines: [[{ text: 'Where you left off' }]] })
  const ui = await $.ui.mount(band())
  expect((await ui.find({ type: 'Box', key: 'publisher/held' }))?.props).toMatchObject({ borderStyle: 'round', borderColor: 'gray' })
  expect((await ui.find({ type: 'Box', key: 'publisher/hand' }))?.props).toMatchObject({ borderStyle: 'round', borderColor: 'warning' })
  expect(await shown(ui)).toEqual(['Where you left off', 'Held while away'])
  await ui.unmount()
})

test('a left rule frame draws one rule mark beside every line, in its colour, and no border', withPublisher, async ($, on) => {
  engineBand(on)
  await show($, {
    mod: 'publisher',
    id: 'steps',
    slot: 'steps',
    frame: { kind: 'left-rule', color: 'warning' },
    lines: [[{ text: 'Steps for you', color: 'warning' }], { divider: true }, [{ text: '1. Open the dashboard', bold: true }]],
  })
  await show($, { mod: 'publisher', id: 'plain', slot: 'message', frame: { kind: 'left-rule' }, lines: [[{ text: 'one line' }]] })
  const ui = await $.ui.mount(band())
  const steps = await ui.find({ type: 'Box', key: 'publisher/steps' })
  expect(steps?.props.borderStyle).toBeUndefined()
  const rule = await ui.find({ type: 'Box', key: 'publisher/steps:rule' })
  const marks = (rule?.children ?? []) as { props: { color?: string }; children: unknown[] }[]
  expect(marks).toHaveLength(3)
  expect(marks.every(m => m.props.color === 'warning' && m.children.join('') === '\u2502')).toBe(true)
  const plain = await ui.find({ type: 'Box', key: 'publisher/plain:rule' })
  expect(((plain?.children ?? []) as { props: { color?: string } }[]).map(m => m.props.color)).toEqual(['gray'])
  await ui.unmount()
})

test('a divider line is a thin grey line across the band, between the lines it separates', withPublisher, async ($, on) => {
  engineBand(on)
  await show($, { mod: 'publisher', id: 'card', slot: 'steps', lines: [[{ text: 'above' }], { divider: true }, [{ text: 'below' }]] })
  const ui = await $.ui.mount(band())
  const texts = await shown(ui)
  expect(texts).toHaveLength(3)
  expect(texts[0]).toBe('above')
  expect(texts[2]).toBe('below')
  // Full width: as many columns as the band has, cut at the edge by the frame it sits in.
  expect(texts[1]).toBe('\u2500'.repeat(100))
  const line = await ui.find({ type: 'Text', text: '\u2500' })
  expect(line?.props).toMatchObject({ color: 'gray', wrap: 'truncate-end' })
  await ui.unmount()
})

test('a part with an indent starts that many columns in', withPublisher, async ($, on) => {
  engineBand(on)
  await show($, { mod: 'publisher', id: 'q', slot: 'steps', lines: [[{ text: '1. Proceed', bold: true }], [{ text: 'runs it as asked', dim: true, indent: 3 }]] })
  const ui = await $.ui.mount(band())
  const boxes = (await ui.findAll({ type: 'Box' })).filter(b => b.props.paddingLeft === 3)
  expect(boxes).toHaveLength(1)
  expect(boxes[0]?.text).toContain('runs it as asked')
  expect((await ui.findAll({ type: 'Box' })).filter(b => b.text.includes('1. Proceed') && b.props.paddingLeft !== undefined)).toHaveLength(0)
  await ui.unmount()
})

test('an unknown frame kind, a malformed divider, or a bad indent is refused at publish, never drawn wrong', withPublisher, async ($, on) => {
  engineBand(on)
  expect(await show($, { mod: 'publisher', id: 'x', slot: 'steps', frame: { kind: 'double' }, lines: [] })).toMatch(/refused: .*frame kind "double"/)
  expect(await show($, { mod: 'publisher', id: 'x', slot: 'steps', frame: { kind: 'box', color: 7 }, lines: [] })).toMatch(/refused: .*frame colour/)
  expect(await show($, { mod: 'publisher', id: 'x', slot: 'steps', lines: [{ divider: false }] })).toMatch(/refused: .*lines must be/)
  expect(await show($, { mod: 'publisher', id: 'x', slot: 'steps', lines: [[{ text: 'a', indent: -1 }]] })).toMatch(/refused: .*indent/)
  expect(await show($, { mod: 'publisher', id: 'x', slot: 'steps', lines: [[{ text: 'a', indent: 1.5 }]] })).toMatch(/refused: .*indent/)
  const ui = await $.ui.mount(band())
  expect(await ui.find({ text: 'engine band' })).toBeDefined()
  await ui.unmount()
})
