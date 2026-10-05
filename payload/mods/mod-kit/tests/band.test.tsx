import { expect, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type { ModKitBandRow, ModKitBandSlot, ModKitQuestion } from '../types/index.d.ts'

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
        if (verb === 'ask') await $.modkit.question(JSON.parse(rest.join(' ')) as ModKitQuestion)
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
const ask = async ($: Caller, q: unknown) => {
  const out = (await $.tool.call({ tool: 'Bash', command: `ask ${JSON.stringify(q)}` } as never)) as { deny?: string; text?: string }
  return out.deny ?? out.text ?? ''
}
const question = (mod: string, text: string, extra: Partial<ModKitQuestion> = {}): ModKitQuestion => ({
  mod,
  id: 'question',
  chip: 'Pick',
  question: text,
  options: [
    { button: 'yes', label: 'Yes' },
    { button: 'no', label: 'No' },
  ],
  ...extra,
})
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
  await show($, row('room', 'This account is low. Work has room'))
  await show($, row('compact', 'ctx 74%'))
  await show($, row('needs-a-look', 'PR #636 checks failing'))
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount(band(surface))
    // Status first, the account room card with them, then what waits on Dan nearest the prompt
    // (docs/mods-design.md).
    expect(await shown(ui)).toEqual(['PR #636 checks failing', 'ctx 74%', 'This account is low. Work has room', 'Where you left off', 'Held while away', 'Steps for you', 'Message for Kris'])
    expect(await ui.find({ text: 'engine band' })).toBeUndefined()
    await ui.unmount()
  }
})

test('an open question takes the band alone, and the rest comes back once it is cleared', withPublisher, async ($, on) => {
  engineBand(on)
  await show($, row('needs-a-look', 'NO BUILD'))
  await show($, row('steps', 'Steps for you'))
  expect(await ask($, question('publisher', 'Which one?'))).toBe('done')
  const ui = await $.ui.mount(band())
  expect((await shown(ui))[1]).toBe('Which one?')
  expect(await shown(ui)).not.toContain('NO BUILD')
  expect(await shown(ui)).not.toContain('Steps for you')
  await clear($, 'publisher', 'question')
  expect(await shown(ui)).toEqual(['NO BUILD', 'Steps for you'])
  await ui.unmount()
})

// #703: two mods can each have a question open at once (ask before saving's question waits while
// Claude carries on; picker manners' band question beside it, until #744 removed it). Drawn together,
// both numbered from 1, a key meant for one answered the other. One question at a time: the first
// asked is drawn, alone, and the next waits its turn, so a number key can only mean the answer to the
// question in view.
test('two open questions: only the first asked is drawn, only its buttons hold the number keys, and the next follows once it is cleared', withPublisher, async ($, on) => {
  engineBand(on)
  await ask($, question('ask-before-saving', 'Save this as a standing rule?', { id: 'question:t1', chip: 'Standing rule' }))
  await ask($, question('second-asker', 'Which window?', { chip: 'Window' }))
  const firstInView = async (surface: 'terminal' | 'desktop' = 'terminal') => {
    const ui = await $.ui.mount(band(surface))
    expect(await shown(ui)).toContain('Save this as a standing rule?')
    expect(await shown(ui)).not.toContain('Which window?')
    expect((await ui.find({ type: 'Button', key: 'ask-before-saving:yes' }))?.props.hotkey).toBe('1')
    expect(await ui.find({ type: 'Button', key: 'second-asker:yes' })).toBeUndefined()
    await ui.unmount()
  }
  for (const surface of ['terminal', 'desktop'] as const) await firstInView(surface)
  // The one drawn published again (a multi select toggle) keeps its turn.
  await ask($, question('ask-before-saving', 'Save this as a standing rule?', { id: 'question:t1', chip: 'Standing rule', options: [{ button: 'yes', label: 'Yes', chosen: true }, { button: 'no', label: 'No' }] }))
  await firstInView()
  await clear($, 'ask-before-saving', 'question:t1')
  let ui = await $.ui.mount(band())
  expect(await shown(ui)).toContain('Which window?')
  expect((await ui.find({ type: 'Button', key: 'second-asker:yes' }))?.props.hotkey).toBe('1')
  await ui.unmount()
  await clear($, 'second-asker', 'question')
  ui = await $.ui.mount(band())
  expect(await ui.find({ text: 'engine band' })).toBeDefined()
  await ui.unmount()
})

// #703 and #705: the question rows picker manners and ask before saving drew by hand had drifted
// apart (a bracketed button against a plain one, an amber chip against a grey one, a 4 column
// indent against 3). mod-kit builds every question, so there is one look: the chip in grey and the
// question in amber on one line, anything the asker shows between, then each option as Claude
// Code's plain button with its description indented under it (docs/mods-design.md).
test('a question is drawn the settled way: grey chip, amber question, plain numbered options, descriptions indented under them', withPublisher, async ($, on) => {
  engineBand(on)
  await ask($, {
    mod: 'publisher',
    id: 'question',
    chip: 'Retention',
    question: 'How long should the registry keep it?',
    body: [{ divider: true }, [{ text: 'the rule itself' }]],
    options: [
      { button: 'opt1', label: '1 day', description: 'Smallest folder.' },
      { button: 'opt2', label: '7 days', chosen: true },
    ],
    submit: { button: 'submit', label: 'Submit' },
  })
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount(band(surface))
    const texts = await shown(ui)
    expect(texts.slice(0, 2)).toEqual(['[Retention] ', 'How long should the registry keep it?'])
    expect(texts).toContain('the rule itself')
    expect((await ui.find({ type: 'Text', text: '[Retention] ' }))?.props).toMatchObject({ dimColor: true })
    expect((await ui.find({ type: 'Text', text: 'How long should the registry keep it?' }))?.props).toMatchObject({ color: 'warning', bold: true })
    expect((await ui.find({ type: 'Button', key: 'publisher:opt1' }))?.props).toMatchObject({ label: '1 day', hotkey: '1', plain: true })
    expect((await ui.find({ type: 'Button', key: 'publisher:opt2' }))?.props).toMatchObject({ label: '7 days', hotkey: '2', plain: true })
    expect((await ui.find({ type: 'Text', text: ' chosen' }))?.props).toMatchObject({ dimColor: true })
    // The description sits 3 columns in, under the "1: " of its option, and wraps at the band's edge.
    const description = await ui.find({ type: 'Text', text: 'Smallest folder.' })
    expect(description?.props).toMatchObject({ dimColor: true, wrap: 'wrap' })
    const indented = (await ui.findAll({ type: 'Box' })).filter(b => b.props.paddingLeft === 3)
    expect(indented.map(b => b.text)).toEqual(['Smallest folder.'])
    const submit = await ui.find({ type: 'Button', key: 'publisher:submit' })
    expect(submit?.props.label).toBe('Submit')
    expect(submit?.props.hotkey).toBeUndefined()
    await ui.unmount()
  }
})

test('a question row published through bandRow is refused, naming the question builder', withPublisher, async ($, on) => {
  engineBand(on)
  expect(await show($, row('question', 'Which one?'))).toMatch(/refused: .*\$\.modkit\.question/)
  const ui = await $.ui.mount(band())
  expect(await ui.find({ text: 'engine band' })).toBeDefined()
  await ui.unmount()
})

test('a question with no options, more than nine, an empty label, a repeated button, or no chip is refused by name', withPublisher, async ($, on) => {
  engineBand(on)
  const opts = (n: number) => Array.from({ length: n }, (_, i) => ({ button: `o${i}`, label: `Option ${i}` }))
  expect(await ask($, question('publisher', 'Q?', { options: [] }))).toMatch(/refused: .*at least one option/)
  expect(await ask($, question('publisher', 'Q?', { options: opts(10) }))).toMatch(/refused: .*at most 9 options/)
  expect(await ask($, question('publisher', 'Q?', { options: [{ button: 'a', label: '' }] }))).toMatch(/refused: .*label/)
  expect(await ask($, question('publisher', 'Q?', { options: [{ button: 'a', label: 'A' }, { button: 'a', label: 'B' }] }))).toMatch(/refused: .*button "a" twice/)
  expect(await ask($, question('publisher', 'Q?', { chip: '' }))).toMatch(/refused: .*chip/)
  expect(await ask($, question('publisher', 'Q?', { submit: { button: 'a', label: 'Submit' }, options: [{ button: 'a', label: 'A' }] }))).toMatch(/refused: .*button "a" twice/)
  expect(await ask($, { ...question('publisher', 'Q?'), mod: '' })).toMatch(/refused: .*mod and an id/)
  const ui = await $.ui.mount(band())
  expect(await ui.find({ text: 'engine band' })).toBeDefined()
  await ui.unmount()
})

// #703: a run cut at the band's edge lost the end of a long option description, which in the end of
// turn issue review is where the brackets Dan checks sit. A run marked wrap goes on to the next line.
test('a text run marked wrap wraps at the band edge, any other is cut there', withPublisher, async ($, on) => {
  engineBand(on)
  await show($, { mod: 'publisher', id: 'w', slot: 'steps', lines: [[{ text: 'long and wrapped', wrap: true }], [{ text: 'long and cut' }]] })
  const ui = await $.ui.mount(band())
  expect((await ui.find({ type: 'Text', text: 'long and wrapped' }))?.props.wrap).toBe('wrap')
  expect((await ui.find({ type: 'Text', text: 'long and cut' }))?.props.wrap).toBe('truncate-end')
  await ui.unmount()
})

test('wrap on a button, or wrap set to anything but true, is refused by name', withPublisher, async ($, on) => {
  engineBand(on)
  expect(await show($, { mod: 'publisher', id: 'w', slot: 'steps', lines: [[{ button: 'go', label: 'Go', wrap: true }]] })).toMatch(/refused: .*only a text run can wrap/)
  expect(await show($, { mod: 'publisher', id: 'w', slot: 'steps', lines: [[{ text: 'a', wrap: 'yes' }]] })).toMatch(/refused: .*wrap must be true/)
})

// #734: a run that wraps is taken inside a left rule, whose rule then spans every row the lines take
// (the steps card's long click path was cut at the edge while the rule drew one mark per line). The
// rule is one column laid over the row's whole height and clipped to it, with a mark for every row
// the lines could take, since a terminal row holds at least one character. A row with no run that
// wraps keeps its one mark per line, above.
test('a left rule around a run that wraps is one rule over the row\'s whole height', withPublisher, async ($, on) => {
  engineBand(on)
  const path = 'Settings, then Security, then Web application firewall, then Custom rules, then Create rule'
  expect(
    await show($, {
      mod: 'publisher',
      id: 'w',
      slot: 'steps',
      frame: { kind: 'left-rule', color: 'warning' },
      lines: [[{ text: 'Steps for you', color: 'warning' }], { divider: true }, [{ text: path, indent: 3, wrap: true }], [{ text: 'Copy' }, { button: 'go', label: 'Go' }]],
    }),
  ).toBe('done')
  const ui = await $.ui.mount(band())
  // The surface's own table takes the tree as drawn.
  await ui.drawn()
  const rule = await ui.find({ type: 'Box', key: 'publisher/w:rule' })
  expect(rule?.props).toMatchObject({ position: 'absolute', top: 0, bottom: 0, left: 0, width: 1, overflow: 'hidden' })
  const marks = (rule?.children ?? []) as { props: { color?: string }; children: unknown[] }[]
  expect(marks).toHaveLength(1)
  expect(marks[0]?.props.color).toBe('warning')
  const rows = String(marks[0]?.children.join('')).split('\n')
  expect(rows.every(r => r === '│')).toBe(true)
  // The heading, the divider and the last line one row each, and the wrapping line one per character
  // it holds at most, indent included.
  expect(rows.length).toBeGreaterThanOrEqual(3 + 3 + path.length)
  // The lines stand clear of the rule as they do beside one mark per line: a column for it, one gap.
  expect((await ui.find({ type: 'Box', key: 'publisher/w:lines' }))?.props).toMatchObject({ paddingLeft: 2 })
  expect((await ui.find({ type: 'Text', text: path }))?.props.wrap).toBe('wrap')
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
  await show($, { mod: 'publisher', id: 'q', slot: 'steps', lines: [[{ button: 'opt1', label: '7 days', hotkey: '1', plain: true }], [{ button: 'go', label: 'Submit' }]] })
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

// #708: a long dashboard link cut at the band's edge showed broken and could not be copied. A run
// with an href is Claude Code's own Link, a real terminal hyperlink, so it opens and copies whole
// however much of its text shows.
test('a run with an href is drawn as Claude Code\'s Link to the whole address, cut at the edge like any run', withPublisher, async ($, on) => {
  engineBand(on)
  const url = `https://dash.cloudflare.com/${'a'.repeat(200)}/security/waf?zone=example.com`
  expect(await show($, { mod: 'publisher', id: 's', slot: 'steps', frame: { kind: 'left-rule' }, lines: [[{ text: url, href: url, indent: 3 }], [{ text: 'Security, WAF' }]] })).toBe('done')
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount(band(surface))
    const links = (await ui.findAll({ type: 'Link' })) as unknown as { props: { href?: string; label?: string }; children?: unknown[] }[]
    expect(links).toHaveLength(1)
    expect(links[0]?.props.href).toBe(url)
    // A run whose text is its own address is a Link with no text of its own: where the terminal
    // draws no hyperlinks (Apple Terminal), a Link with text is drawn as the text then the address,
    // which would show the address twice; one with neither shows it once.
    expect(links[0]?.children ?? []).toEqual([])
    expect(links[0]?.props.label).toBeUndefined()
    // Inside a run's own Text, so it takes the run's style and is cut at the edge, never wrapped.
    const run = (await ui.findAll({ type: 'Text' })).find(t => (t.children as { type?: string }[]).some(c => c?.type === 'Link')) as unknown as
      | { props: { wrap?: string } }
      | undefined
    expect(run?.props.wrap).toBe('truncate-end')
    // A run with no href is no link.
    expect((await ui.find({ type: 'Text', text: 'Security, WAF' }))?.children).toEqual(['Security, WAF'])
    await ui.unmount()
  }
})

test('a run with an href and text of its own is a Link carrying that text', withPublisher, async ($, on) => {
  engineBand(on)
  await show($, { mod: 'publisher', id: 's', slot: 'steps', lines: [[{ text: 'the WAF page', href: 'https://dash.cloudflare.com/waf' }]] })
  const ui = await $.ui.mount(band())
  const link = (await ui.find({ type: 'Link' })) as unknown as { props: { href?: string }; children?: unknown[] } | undefined
  expect(link?.props.href).toBe('https://dash.cloudflare.com/waf')
  expect(link?.children).toEqual(['the WAF page'])
  await ui.unmount()
})

test('an href that is not an address, or one on a button, is refused at publish, never drawn as plain text', withPublisher, async ($, on) => {
  engineBand(on)
  expect(await show($, { mod: 'publisher', id: 'x', slot: 'steps', lines: [[{ text: 'a', href: '' }]] })).toMatch(/refused: .*href/)
  expect(await show($, { mod: 'publisher', id: 'x', slot: 'steps', lines: [[{ text: 'a', href: 7 }]] })).toMatch(/refused: .*href/)
  expect(await show($, { mod: 'publisher', id: 'x', slot: 'steps', lines: [[{ button: 'go', label: 'Go', href: 'https://a.example' }]] })).toMatch(/refused: .*only a text run can be a link/)
  // A control character could end the terminal's hyperlink sequence early and write what follows.
  expect(await show($, { mod: 'publisher', id: 'x', slot: 'steps', lines: [[{ text: 'a', href: 'https://a.example/\u001b]8;;\u0007x' }]] })).toMatch(/refused: .*control character/)
  expect(await show($, { mod: 'publisher', id: 'x', slot: 'steps', lines: [[{ text: 'a', href: 'https://a.example/\u0007' }]] })).toMatch(/refused: .*control character/)
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
