import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type { ModKitBandRow, ModKitPane } from '../types/index.d.ts'
import { clicksReach, mostRows } from '../hooks/band.ts'

// #939: a band or pane Button is pressed by a click only where the surface reports clicks. The
// terminal reports them in the fullscreen layout alone, and Apple Terminal only while its per tab
// View > Allow Mouse Reporting is ticked, a switch cmd R flips and a mod cannot read. Dan's steps card
// drew [ Done ] and [ Copy link ] in a tab where it was off (measured 2026-10-08), so a click did
// nothing. Wherever a click may not reach it, every button is drawn as text: the publisher's own
// `instead`, or else "type: /press <mod> <button>", the command that presses it the same way. Both
// a click and /press raise modkit.press, which the publisher answers.
const publisher: { name: string; register: Register } = {
  name: 'publisher',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => {
      const [verb, ...rest] = String((e as { command?: string }).command).split(' ')
      try {
        if (verb === 'show') await $.modkit.bandRow(JSON.parse(rest.join(' ')) as ModKitBandRow)
        if (verb === 'pane') await $.modkit.pane(JSON.parse(rest.join(' ')) as ModKitPane)
        if (verb === 'clickable') return { deny: `clickable ${String(await $.modkit.clickable(JSON.parse(rest.join(' '))))}` }
      } catch (err) {
        return { deny: `refused: ${String((err as Error).message ?? err)}` }
      }
      return { deny: 'done' }
    })
    on('modkit.press', async ($, e, next) => {
      if (e.element !== 'publisher:done' && e.element !== 'publisher:compact') return next(e)
      $.ui.toast(`pressed ${e.element} by ${e.how} on ${e.surface}`)
      // Done sends a prompt, as manual-steps' does: a typed /press must be able to.
      if (e.element === 'publisher:done') await $.prompt.submit({ text: 'step 1 done', asUser: true })
      return { value: { isAnswered: true } }
    })
  },
}
const withPublisher = { plugins: [publisher] }

type Caller = { tool: { call: (e: never) => Promise<unknown> } }
const run = async ($: Caller, command: string) => {
  const out = (await $.tool.call({ tool: 'Bash', command } as never)) as { deny?: string; text?: string }
  return out.deny ?? out.text ?? ''
}
const engine = (on: On) => {
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
}
const toasts = (on: On) => {
  const seen: string[] = []
  on('ui.toast', ($, e) => {
    seen.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  return seen
}

const submits = (on: On) => {
  const sent: string[] = []
  on('prompt.submit', ($, e) => {
    sent.push(e.text)
    return { text: e.text }
  })
  return sent
}

const INSTEAD = [{ text: 'type: ', dim: true }, { text: 'step 1 done' }]
const lines = [
  [{ text: '1. Turn on the WAF rule', bold: true }, { text: '  ' }, { button: 'done', label: 'Done', instead: INSTEAD }],
  [{ text: 'https://dash.cloudflare.com/waf' }, { text: '  ' }, { button: 'copy', label: 'Copy link', instead: [] }],
  [{ text: 'ctx 74% ' }, { button: 'compact', label: 'Compact' }],
]
const row = { mod: 'publisher', id: 'steps', slot: 'steps', frame: { kind: 'left-rule', color: 'warning' }, lines }
const bandProps = { hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 100, scroll: { offset: 0, bodyRows: 20 }, view: {} }
type Viewport = { columns: number; rows: number; isFullscreen?: boolean } | undefined
const FULL: Viewport = { columns: 120, rows: 40, isFullscreen: true }
const MAIN: Viewport = { columns: 120, rows: 40, isFullscreen: false }
const band = (surface: 'terminal' | 'desktop', viewport: Viewport) =>
  ({ plugin: 'mod-kit', surface, component: 'AbovePrompt', props: bandProps, ...(viewport ? { viewport } : {}) }) as never
const pane = (surface: 'terminal' | 'desktop', viewport: Viewport) =>
  ({ plugin: 'mod-kit', surface, component: 'Pane', requestId: 'steps', props: { title: 'Manual steps', isFocused: false, bodyColumns: 60 }, ...(viewport ? { viewport } : {}) }) as never

type Found = { text: string; children: unknown[]; props?: Record<string, unknown> }
type Ui = { find: (q: object) => Promise<{ props: Record<string, unknown> } | undefined>; findAll: (q: { type: string }) => Promise<Found[]>; press: (q: { key: string }) => Promise<unknown>; unmount: () => Promise<void> }
const texts = async (ui: Ui) => (await ui.findAll({ type: 'Text' })).filter(t => t.children.every(c => typeof c === 'string')).map(t => t.text)

test('clicksReach: only a terminal in the fullscreen layout that is not Apple Terminal, or a surface drawing native buttons', () => {
  expect(clicksReach({ surface: 'terminal', isFullscreen: true, terminal: 'iTerm.app' })).toBe(true)
  expect(clicksReach({ surface: 'terminal', isFullscreen: true, terminal: 'ghostty' })).toBe(true)
  // Apple Terminal reports clicks only while a per tab switch is on, which no mod can read.
  expect(clicksReach({ surface: 'terminal', isFullscreen: true, terminal: 'Apple_Terminal' })).toBe(false)
  // The main screen reports no clicks in any terminal.
  expect(clicksReach({ surface: 'terminal', isFullscreen: false, terminal: 'iTerm.app' })).toBe(false)
  // Not measured, or a terminal that could not be read: taken as a click that may not land.
  expect(clicksReach({ surface: 'terminal', isFullscreen: undefined, terminal: 'iTerm.app' })).toBe(false)
  expect(clicksReach({ surface: 'terminal', isFullscreen: true, terminal: undefined })).toBe(false)
  // A remote surface draws its own native buttons, whatever terminal the session runs in.
  for (const surface of ['desktop', 'vscode', 'mobile'] as const) expect(clicksReach({ surface, isFullscreen: false, terminal: 'Apple_Terminal' })).toBe(true)
})

test('in Apple Terminal, even fullscreen, no button is drawn: one with instead is that text, one without says the /press that presses it', withPublisher, async ($, on) => {
  engine(on)
  mock.env(on, { TERM_PROGRAM: 'Apple_Terminal' })
  expect(await run($, `show ${JSON.stringify(row)}`)).toBe('done')
  expect(await run($, `pane ${JSON.stringify({ ...row, slot: undefined })}`)).toBe('done')
  for (const target of [band('terminal', FULL), pane('terminal', FULL)]) {
    const ui = (await $.ui.mount(target)) as unknown as Ui
    expect(await ui.find({ type: 'Button', key: 'publisher:done' })).toBeUndefined()
    expect(await ui.find({ type: 'Button', key: 'publisher:copy' })).toBeUndefined()
    const shown = await texts(ui)
    expect(shown).toContain('type: ')
    expect(shown).toContain('step 1 done')
    expect((await ui.find({ type: 'Text', text: 'type: ' }))?.props).toMatchObject({ dimColor: true })
    expect(shown).toContain('https://dash.cloudflare.com/waf')
    expect(await ui.find({ type: 'Button', key: 'publisher:compact' })).toBeUndefined()
    expect(shown).toContain('/press publisher compact')
    expect(await ui.find({ type: 'Button' })).toBeUndefined()
    await ui.unmount()
  }
})

test('on the main screen a button with instead is text in any terminal; with no viewport measured, too', withPublisher, async ($, on) => {
  engine(on)
  mock.env(on, { TERM_PROGRAM: 'iTerm.app' })
  await run($, `show ${JSON.stringify(row)}`)
  for (const viewport of [MAIN, undefined]) {
    const ui = (await $.ui.mount(band('terminal', viewport))) as unknown as Ui
    expect(await ui.find({ type: 'Button', key: 'publisher:done' })).toBeUndefined()
    expect(await texts(ui)).toContain('step 1 done')
    await ui.unmount()
  }
})

test('where clicks reach (a fullscreen terminal that reports them, or the desktop) the button is a Button and its press reaches the publisher', withPublisher, async ($, on) => {
  engine(on)
  const seen = toasts(on)
  const sent = submits(on)
  mock.env(on, { TERM_PROGRAM: 'iTerm.app' })
  await run($, `show ${JSON.stringify(row)}`)
  const ui = (await $.ui.mount(band('terminal', FULL))) as unknown as Ui
  expect((await ui.find({ type: 'Button', key: 'publisher:done' }))?.props.label).toBe('Done')
  expect(await texts(ui)).not.toContain('step 1 done')
  await ui.press({ key: 'publisher:done' })
  expect(seen).toEqual(['pressed publisher:done by click on terminal'])
  expect(sent).toEqual(['step 1 done'])
  await ui.unmount()
})

test('the desktop draws its native Button even when the session runs in Apple Terminal', withPublisher, async ($, on) => {
  engine(on)
  mock.env(on, { TERM_PROGRAM: 'Apple_Terminal' })
  await run($, `pane ${JSON.stringify({ ...row, slot: undefined })}`)
  const ui = (await $.ui.mount(pane('desktop', MAIN))) as unknown as Ui
  expect((await ui.find({ type: 'Button', key: 'publisher:done' }))?.props.label).toBe('Done')
  await ui.unmount()
})

test('a terminal whose name cannot be read draws the text, never a Button that may not answer', withPublisher, async ($, on) => {
  engine(on)
  on('env.get', () => {
    throw new Error('env unreadable')
  })
  await run($, `show ${JSON.stringify(row)}`)
  const ui = (await $.ui.mount(band('terminal', FULL))) as unknown as Ui
  expect(await ui.find({ type: 'Button', key: 'publisher:done' })).toBeUndefined()
  expect(await texts(ui)).toContain('step 1 done')
  await ui.unmount()
})

test('instead must be a list of text runs: a button or a malformed run in it is refused by name', withPublisher, async ($, on) => {
  engine(on)
  const withInstead = (instead: unknown) => ({ ...row, lines: [[{ button: 'done', label: 'Done', instead }]] })
  expect(await run($, `show ${JSON.stringify(withInstead('type it'))}`)).toMatch(/refused: .*instead must be a list of text runs/)
  expect(await run($, `show ${JSON.stringify(withInstead([{ button: 'x', label: 'X' }]))}`)).toMatch(/refused: .*instead must be a list of text runs/)
  expect(await run($, `show ${JSON.stringify(withInstead([{ text: 'a', wrap: 'yes' }]))}`)).toMatch(/refused: .*wrap must be true/)
  expect(await run($, `show ${JSON.stringify({ ...row, lines: [[{ text: 'a', instead: [] }]] })}`)).toMatch(/refused: .*only a button can have instead/)
})

// Dan, 2026-10-08: a long Google Sheets link was cut at the edge with Copy link dead. Drawn in a pane
// 30 columns wide in Apple Terminal, the steps card's link line (the shape manual-steps publishes) is
// a wrapping run holding the whole address, alone on its line, with no Button anywhere.
test('a long link on its own line is drawn whole and wrapping in a narrow Apple Terminal pane', withPublisher, async ($, on) => {
  engine(on)
  mock.env(on, { TERM_PROGRAM: 'Apple_Terminal' })
  const url = `https://docs.google.com/spreadsheets/d/1aFt8ks89lkzLV${'x'.repeat(120)}/edit?gid=0#gid=0`
  const card = {
    mod: 'publisher',
    id: 'steps',
    frame: { kind: 'left-rule', color: 'warning' },
    lines: [[{ text: 'Where: ', bold: true, whole: true, indent: 3 }, { button: 'copy', label: 'Copy link', instead: [] }], [{ text: url, href: url, wrap: true, indent: 3 }]],
  }
  expect(await run($, `pane ${JSON.stringify(card)}`)).toBe('done')
  const ui = (await $.ui.mount({ plugin: 'mod-kit', surface: 'terminal', component: 'Pane', requestId: 'steps', props: { title: 'Manual steps', isFocused: false, bodyColumns: 30 }, viewport: { columns: 30, rows: 40, isFullscreen: true } } as never)) as unknown as Ui
  expect(await ui.find({ type: 'Button' })).toBeUndefined()
  const link = await ui.find({ type: 'Link' })
  expect(link?.props.href).toBe(url)
  // The Text holding it wraps rather than being cut at 30 columns, and it is alone on its line.
  const holder = (await ui.findAll({ type: 'Text' })).find(t => JSON.stringify(t).includes(url)) as unknown as { props: Record<string, unknown> } | undefined
  expect(holder?.props.wrap).toBe('wrap')
  expect((await ui.findAll({ type: 'Box' })).filter(b => b.props?.paddingLeft === 3 && JSON.stringify(b).includes(url))).toHaveLength(1)
  await ui.unmount()
})

type Commander = { command: { run: (e: object) => Promise<{ text?: string }> } }
const press = async ($: unknown, args: string) => ((await ($ as Commander).command.run({ command: 'press', args })) as { text?: string }).text

// The press runs once the command has returned, since a prompt cannot be sent from inside
// command.run (Claude Code's own check: it would wait on the turn the hook holds).
test('/press presses a button showing in the band or a pane, through the same modkit.press a click raises', withPublisher, async ($, on) => {
  engine(on)
  const clock = mock.clock(on, { now: 0 })
  const seen = toasts(on)
  const sent = submits(on)
  await run($, `show ${JSON.stringify(row)}`)
  expect(await press($, 'publisher compact')).toBe('Pressing Compact.')
  expect(await press($, '  publisher   done ')).toBe('Pressing Done.')
  await clock.advance(1)
  expect(seen).toEqual(['pressed publisher:compact by typed on terminal', 'pressed publisher:done by typed on terminal'])
  expect(sent).toEqual(['step 1 done'])
})

test('/press refuses a button that is not showing, and says so when nothing answers one that is', withPublisher, async ($, on) => {
  engine(on)
  const clock = mock.clock(on, { now: 0 })
  const seen = toasts(on)
  await run($, `show ${JSON.stringify(row)}`)
  // Not showing (never published, or a line typed again after the row was cleared): nothing pressed.
  expect(await press($, 'publisher go')).toMatch(/^No button "publisher go" is showing/)
  expect(await press($, 'publisher')).toMatch(/^No button "publisher" is showing/)
  expect(await press($, '')).toMatch(/^No button "" is showing/)
  await clock.advance(1)
  expect(seen).toEqual([])
  // Showing, but no mod answers it: said, never a silent no-op.
  expect(await press($, 'publisher copy')).toBe('Pressing Copy link.')
  await clock.advance(1)
  expect(seen).toEqual([expect.stringMatching(/^Nothing answered the button publisher:copy/)])
})

test('a clicked button nothing answers says so in a toast', withPublisher, async ($, on) => {
  engine(on)
  const seen = toasts(on)
  mock.env(on, { TERM_PROGRAM: 'iTerm.app' })
  await run($, `show ${JSON.stringify(row)}`)
  const ui = (await $.ui.mount(band('terminal', FULL))) as unknown as Ui
  await ui.press({ key: 'publisher:copy' })
  expect(seen).toEqual([expect.stringMatching(/^Nothing answered the button publisher:copy/)])
  await ui.unmount()
})

// A mod drawing its own Button (outside the band and a pane) asks mod-kit, so there is one answer.
test('$.modkit.clickable gives a mod drawing its own Button the same answer', withPublisher, async ($, on) => {
  engine(on)
  mock.env(on, { TERM_PROGRAM: 'Apple_Terminal' })
  const ask = (site: object) => run($, `clickable ${JSON.stringify(site)}`)
  expect(await ask({ surface: 'terminal', viewport: FULL })).toBe('clickable false')
  expect(await ask({ surface: 'desktop', viewport: MAIN })).toBe('clickable true')
  expect(await ask({ surface: 'terminal' })).toBe('clickable false')
})

test('a left rule over a wrapping line counts a button by the longer of its label and the text drawn in its place', () => {
  const long = [{ text: 'type: ' }, { text: 'step 12 done, a long phrase' }]
  const n = mostRows([[{ text: 'x', wrap: true }, { button: 'done', label: 'Done', instead: long }]])
  expect(n).toBeGreaterThanOrEqual(1 + 'type: step 12 done, a long phrase'.length)
  // With no instead, the /press line drawn in its place.
  expect(mostRows([[{ text: 'x', wrap: true }, { button: 'compact', label: 'Go' }]], 'status-bar')).toBeGreaterThanOrEqual(1 + 'type: /press status-bar compact'.length)
})
