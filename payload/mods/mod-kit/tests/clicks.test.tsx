import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type { ModKitBandRow, ModKitPane } from '../types/index.d.ts'
import { appleTerminalTrusted, clicksReach, mostRows } from '../hooks/band.ts'

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

// A site as clicksReach is asked about it, with this Mac's Apple Terminal setting (#1012) off unless
// a case says otherwise.
const site = (surface: string, isFullscreen: boolean | undefined, terminal: string | undefined, isAppleTerminalTrusted = false) => ({ surface, isFullscreen, terminal, isAppleTerminalTrusted })

test('clicksReach: only a terminal in the fullscreen layout that is not Apple Terminal, or a surface drawing native buttons', () => {
  expect(clicksReach(site('terminal', true, 'iTerm.app'))).toBe(true)
  expect(clicksReach(site('terminal', true, 'ghostty'))).toBe(true)
  // Apple Terminal reports clicks only while a per tab switch is on, which no mod can read.
  expect(clicksReach(site('terminal', true, 'Apple_Terminal'))).toBe(false)
  // A multiplexer names itself, not the terminal behind it, which may be Apple Terminal (#946 review).
  expect(clicksReach(site('terminal', true, 'tmux'))).toBe(false)
  expect(clicksReach(site('terminal', true, 'screen'))).toBe(false)
  // The main screen reports no clicks in any terminal.
  expect(clicksReach(site('terminal', false, 'iTerm.app'))).toBe(false)
  // Not measured, or a terminal that could not be read: taken as a click that may not land.
  expect(clicksReach(site('terminal', undefined, 'iTerm.app'))).toBe(false)
  expect(clicksReach(site('terminal', true, undefined))).toBe(false)
  expect(clicksReach(site('terminal', true, ''))).toBe(false)
  // A remote surface draws its own native buttons, whatever terminal the session runs in.
  for (const surface of ['desktop', 'vscode', 'mobile'] as const) expect(clicksReach(site(surface, false, 'Apple_Terminal'))).toBe(true)
})

// #1012, Dan 2026-10-09: "Buttons always, I keep it on". With this Mac's setting saying Apple
// Terminal's Allow Mouse Reporting is kept on, Apple Terminal in the fullscreen layout is trusted like
// any other named terminal. Nothing else moves: the main screen still reports no clicks, a
// multiplexer still hides which terminal is behind it (and passes a click on only under its own mouse
// mode, which the setting says nothing about), and an unnamed terminal is still unknown.
test('clicksReach with the Apple Terminal setting on: Apple Terminal fullscreen is trusted, and every other unsure case is not', () => {
  expect(clicksReach(site('terminal', true, 'Apple_Terminal', true))).toBe(true)
  expect(clicksReach(site('terminal', false, 'Apple_Terminal', true))).toBe(false)
  expect(clicksReach(site('terminal', undefined, 'Apple_Terminal', true))).toBe(false)
  expect(clicksReach(site('terminal', true, 'tmux', true))).toBe(false)
  expect(clicksReach(site('terminal', true, 'screen', true))).toBe(false)
  expect(clicksReach(site('terminal', true, undefined, true))).toBe(false)
  expect(clicksReach(site('terminal', true, '', true))).toBe(false)
  expect(clicksReach(site('terminal', true, 'iTerm.app', true))).toBe(true)
  for (const surface of ['desktop', 'vscode', 'mobile'] as const) expect(clicksReach(site(surface, false, 'Apple_Terminal', true))).toBe(true)
})

// Claude Code hands mod-kit the setting as a boolean (`claude plugin configure` stores "true" as
// true, measured 2026-10-09). Anything else is taken as off, the side where no button is dead.
test('the Apple Terminal setting is on only for a true value; absent, false or anything else leaves it off', () => {
  expect(appleTerminalTrusted({ appleTerminalMouseReporting: true })).toBe(true)
  expect(appleTerminalTrusted({})).toBe(false)
  expect(appleTerminalTrusted(undefined)).toBe(false)
  expect(appleTerminalTrusted({ appleTerminalMouseReporting: false })).toBe(false)
  expect(appleTerminalTrusted({ appleTerminalMouseReporting: 'yes' })).toBe(false)
  expect(appleTerminalTrusted({ appleTerminalMouseReporting: 1 })).toBe(false)
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
    // Every publisher now answers modkit.press, which a typed /press raises, so a button with no
    // instead says the command that presses it.
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

// #1012: the setting as Claude Code hands it to mod-kit (from pluginConfigs in this Mac's own
// settings.json), injected here so no test reads the real one.
const SETTING_ON = { plugins: [publisher], options: { appleTerminalMouseReporting: true } }
const SETTING_OFF = { plugins: [publisher], options: { appleTerminalMouseReporting: false } }

test('with the Apple Terminal setting on, Apple Terminal fullscreen draws real Buttons in the band and a pane, and a click reaches the publisher', SETTING_ON, async ($, on) => {
  engine(on)
  const seen = toasts(on)
  const sent = submits(on)
  mock.env(on, { TERM_PROGRAM: 'Apple_Terminal' })
  await run($, `show ${JSON.stringify(row)}`)
  await run($, `pane ${JSON.stringify({ ...row, slot: undefined })}`)
  for (const target of [band('terminal', FULL), pane('terminal', FULL)]) {
    const ui = (await $.ui.mount(target)) as unknown as Ui
    expect((await ui.find({ type: 'Button', key: 'publisher:done' }))?.props.label).toBe('Done')
    expect((await ui.find({ type: 'Button', key: 'publisher:compact' }))?.props.label).toBe('Compact')
    const shown = await texts(ui)
    expect(shown).not.toContain('step 1 done')
    expect(shown).not.toContain('/press publisher compact')
    await ui.unmount()
  }
  const ui = (await $.ui.mount(band('terminal', FULL))) as unknown as Ui
  await ui.press({ key: 'publisher:done' })
  expect(seen).toEqual(['pressed publisher:done by click on terminal'])
  expect(sent).toEqual(['step 1 done'])
  await ui.unmount()
})

test('with the Apple Terminal setting off, Apple Terminal fullscreen still draws the typed fallback', SETTING_OFF, async ($, on) => {
  engine(on)
  mock.env(on, { TERM_PROGRAM: 'Apple_Terminal' })
  await run($, `show ${JSON.stringify(row)}`)
  const ui = (await $.ui.mount(band('terminal', FULL))) as unknown as Ui
  expect(await ui.find({ type: 'Button' })).toBeUndefined()
  expect(await texts(ui)).toContain('step 1 done')
  expect(await texts(ui)).toContain('/press publisher compact')
  await ui.unmount()
})

// Whether a band drawn here shows the typed fallback and no Button at all.
const typedOnly = async ($: { ui: { mount: (t: never) => Promise<unknown> } }, viewport: Viewport) => {
  const ui = (await $.ui.mount(band('terminal', viewport))) as unknown as Ui
  const button = await ui.find({ type: 'Button' })
  const shown = await texts(ui)
  await ui.unmount()
  return button === undefined && shown.includes('step 1 done') && shown.includes('/press publisher compact')
}

test('with the Apple Terminal setting on, Apple Terminal on the main screen or an unmeasured layout still draws the typed fallback', SETTING_ON, async ($, on) => {
  engine(on)
  mock.env(on, { TERM_PROGRAM: 'Apple_Terminal' })
  await run($, `show ${JSON.stringify(row)}`)
  expect(await typedOnly($ as never, MAIN)).toBe(true)
  expect(await typedOnly($ as never, undefined)).toBe(true)
})

// A multiplexer names itself, so the terminal behind it is unknown, and it passes a click on only
// under its own mouse mode: the Apple Terminal setting vouches for neither.
for (const multiplexer of ['tmux', 'screen'])
  test(`with the Apple Terminal setting on, ${multiplexer} fullscreen still draws the typed fallback`, SETTING_ON, async ($, on) => {
    engine(on)
    mock.env(on, { TERM_PROGRAM: multiplexer })
    await run($, `show ${JSON.stringify(row)}`)
    expect(await typedOnly($ as never, FULL)).toBe(true)
  })

test('with the Apple Terminal setting on, a remote surface is unchanged: its native Button', SETTING_ON, async ($, on) => {
  engine(on)
  mock.env(on, { TERM_PROGRAM: 'Apple_Terminal' })
  await run($, `pane ${JSON.stringify({ ...row, slot: undefined })}`)
  const ui = (await $.ui.mount(pane('desktop', MAIN))) as unknown as Ui
  expect((await ui.find({ type: 'Button', key: 'publisher:done' }))?.props.label).toBe('Done')
  await ui.unmount()
})

test('$.modkit.clickable gives the same answer with the Apple Terminal setting on', SETTING_ON, async ($, on) => {
  engine(on)
  mock.env(on, { TERM_PROGRAM: 'Apple_Terminal' })
  const ask = (site: object) => run($, `clickable ${JSON.stringify(site)}`)
  expect(await ask({ surface: 'terminal', viewport: FULL })).toBe('clickable true')
  expect(await ask({ surface: 'terminal', viewport: MAIN })).toBe('clickable false')
  expect(await ask({ surface: 'desktop', viewport: MAIN })).toBe('clickable true')
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
  // An instead run is drawn as one plain run beside its neighbours, so a layout field on it is refused
  // rather than ignored (#946 review).
  for (const field of [{ indent: 2 }, { whole: true }, { wrap: true }])
    expect(await run($, `show ${JSON.stringify(withInstead([{ text: 'a', ...field }]))}`)).toMatch(/refused: .*an instead run takes no indent, whole or wrap/)
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

// Lessons review of #946: a mod not yet moved onto modkit.press takes a click in its own ui.press
// hook, which answers it without calling next, so the Button's own press (the modkit.press raise)
// never runs and no false "Nothing answered" is toasted.
const oldPublisher: { name: string; register: Register } = {
  name: 'oldpub',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => {
      await $.modkit.bandRow(JSON.parse(String((e as { command?: string }).command).slice('show '.length)) as ModKitBandRow)
      return { deny: 'done' }
    })
    on('ui.press', { plugin: 'mod-kit', element: 'oldpub:go' }, ($, e) => {
      $.ui.toast('oldpub took the click')
      return { element: e.element }
    })
  },
}
test('a click a mod still answers in its ui.press hook is taken there, with no false toast', { plugins: [oldPublisher] }, async ($, on) => {
  engine(on)
  const seen = toasts(on)
  mock.env(on, { TERM_PROGRAM: 'iTerm.app' })
  await run($, `show ${JSON.stringify({ mod: 'oldpub', id: 'r', slot: 'steps', lines: [[{ button: 'go', label: 'Go' }]] })}`)
  const ui = (await $.ui.mount(band('terminal', FULL))) as unknown as Ui
  await ui.press({ key: 'oldpub:go' })
  expect(seen).toEqual(['oldpub took the click'])
  await ui.unmount()
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

test('a left rule over a wrapping line counts a button by the longer of its label and its instead text', () => {
  const long = [{ text: 'type: ' }, { text: 'step 12 done, a long phrase' }]
  const n = mostRows([[{ text: 'x', wrap: true }, { button: 'done', label: 'Done', instead: long }]], 'manual-steps')
  expect(n).toBeGreaterThanOrEqual(1 + 'type: step 12 done, a long phrase'.length)
  // With no instead, the /press line drawn in its place.
  expect(mostRows([[{ text: 'x', wrap: true }, { button: 'compact', label: 'Go' }]], 'status-bar')).toBeGreaterThanOrEqual(1 + 'type: /press status-bar compact'.length)
})

// #1190, 2026-10-14: the work MacBook drew "type: step 1 done" where the personal MacBook drew a
// Done button, and nothing said why (Dan: "why does my work mac want me to type step 1 done instead
// of clicking a done button"). The setting that turns buttons on lives in each Mac's own
// settings.json, which the sync never carries. So the first time on a Mac that a button is drawn as
// text where turning that setting on would draw it as a button (Apple Terminal, fullscreen, setting
// off), mod-kit says so once in the transcript, with the command, and records that it did in its own
// store, which is this Mac's alone.
type Kept = { [key: string]: unknown }
const world = (on: On, opts: { readFails?: boolean; writeFails?: boolean; kept?: Kept } = {}) => {
  const kept: Kept = { ...(opts.kept ?? {}) }
  const said: { text: string; to: string }[] = []
  on('store.get', ($, e) => {
    if (opts.readFails) throw new Error('the store could not be read')
    return { value: kept[e.key] } as never
  })
  on('store.set', ($, e) => {
    if (opts.writeFails) throw new Error('disk full')
    kept[e.key] = e.value
    return { value: undefined } as never
  })
  on('ui.log', ($, e) => {
    said.push({ text: String(e.text), to: String(e.to) })
    return { value: undefined } as never
  })
  return { kept, said }
}
const COMMAND = `echo '{"appleTerminalMouseReporting":"true"}' | claude plugin configure mod-kit@inline --values-stdin`
const isNotice = (s: { text: string }) => s.text.includes(COMMAND)
type Mounter = { ui: { mount: (t: never) => Promise<unknown> } }
type Advancer = { advance: (ms: number) => Promise<void> }
// Each target drawn twice, as a redraw would, the deferred work let run after each.
const drawTwice = async ($: Mounter, clock: Advancer, targets: never[]) => {
  for (const target of [...targets, ...targets]) {
    const ui = (await $.ui.mount(target)) as unknown as Ui
    await clock.advance(1)
    await ui.unmount()
  }
}
// A long dash, or a hyphen standing alone between words, spelled as escapes so this file holds none.
const DASHED = new RegExp('[\\u2012\\u2013\\u2014\\u2015]|\\s\\u002d\\s')

test('Apple Terminal fullscreen with the setting off says once, in the transcript, why buttons are text and the one command that turns them on', withPublisher, async ($, on) => {
  engine(on)
  const clock = mock.clock(on, { now: 5_000 })
  const { kept, said } = world(on)
  mock.env(on, { TERM_PROGRAM: 'Apple_Terminal' })
  await run($, `show ${JSON.stringify(row)}`)
  await run($, `pane ${JSON.stringify({ ...row, slot: undefined })}`)
  await drawTwice($ as never, clock, [band('terminal', FULL), pane('terminal', FULL)])
  const notices = said.filter(isNotice)
  expect(notices).toHaveLength(1)
  expect(notices[0]?.to).toBe('transcript')
  const text = notices[0]?.text ?? ''
  expect(text).toMatch(/Buttons are off on this Mac/)
  expect(text).toMatch(/new session/)
  expect(text).toMatch(/View > Allow Mouse Reporting/)
  expect(text).toMatch(/Cmd R/)
  expect(DASHED.test(text)).toBe(false)
  // Recorded in mod-kit's own store, so no later session on this Mac says it again.
  expect(Object.values(kept)).toEqual([5_000])
  expect(said.filter(s => !isNotice(s))).toEqual([])
})

test('once the store records it, a later session on the same Mac draws the text and says nothing', withPublisher, async ($, on) => {
  engine(on)
  const clock = mock.clock(on, { now: 0 })
  const { said } = world(on, { kept: { buttonsOffSaid: 5_000 } })
  mock.env(on, { TERM_PROGRAM: 'Apple_Terminal' })
  await run($, `show ${JSON.stringify(row)}`)
  await drawTwice($ as never, clock, [band('terminal', FULL)])
  expect(said).toEqual([])
})

// Where turning the setting on would not draw a button, saying so would send Dan to a fix that does
// nothing: the main screen, an unmeasured layout, a multiplexer, an unnamed terminal. Nor where
// buttons are already drawn, nor in a band holding no button at all.
test('nothing is said where the setting would not help, where buttons already work, or where no button is drawn', withPublisher, async ($, on) => {
  engine(on)
  const clock = mock.clock(on, { now: 0 })
  const { said } = world(on)
  const env: Record<string, string> = {}
  on('env.get', ($, e) => ({ value: env[e.name] }) as never)
  await run($, `show ${JSON.stringify(row)}`)
  const cases: [string | undefined, Viewport, 'terminal' | 'desktop'][] = [
    ['Apple_Terminal', MAIN, 'terminal'],
    ['Apple_Terminal', undefined, 'terminal'],
    ['tmux', FULL, 'terminal'],
    ['screen', FULL, 'terminal'],
    [undefined, FULL, 'terminal'],
    ['', FULL, 'terminal'],
    ['iTerm.app', FULL, 'terminal'],
    ['Apple_Terminal', MAIN, 'desktop'],
  ]
  for (const [name, viewport, surface] of cases) {
    if (name === undefined) delete env.TERM_PROGRAM
    else env.TERM_PROGRAM = name
    await drawTwice($ as never, clock, [band(surface, viewport)])
  }
  expect(said).toEqual([])
  // A band whose rows hold no button draws nothing as typed text.
  env.TERM_PROGRAM = 'Apple_Terminal'
  await run($, `show ${JSON.stringify({ ...row, lines: [[{ text: 'ctx 74%' }]] })}`)
  await drawTwice($ as never, clock, [band('terminal', FULL)])
  expect(said).toEqual([])
  // The control: the same band with a button in it, drawn the same way, does say it.
  await run($, `show ${JSON.stringify(row)}`)
  await drawTwice($ as never, clock, [band('terminal', FULL)])
  expect(said.filter(isNotice)).toHaveLength(1)
})

test('with the Apple Terminal setting on, Apple Terminal fullscreen draws buttons and says nothing', SETTING_ON, async ($, on) => {
  engine(on)
  const clock = mock.clock(on, { now: 0 })
  const { said } = world(on)
  mock.env(on, { TERM_PROGRAM: 'Apple_Terminal' })
  await run($, `show ${JSON.stringify(row)}`)
  await drawTwice($ as never, clock, [band('terminal', FULL)])
  expect(said).toEqual([])
})

// The failure path: a store that will not take the record. Said once in this session all the same,
// never on every redraw, with a line saying the next session will say it again, since a notice
// repeated once a session costs less than one never seen.
test('a store write that fails says the notice once this session, and says the record failed, never on every redraw', withPublisher, async ($, on) => {
  engine(on)
  const clock = mock.clock(on, { now: 0 })
  const { kept, said } = world(on, { writeFails: true })
  mock.env(on, { TERM_PROGRAM: 'Apple_Terminal' })
  await run($, `show ${JSON.stringify(row)}`)
  await run($, `pane ${JSON.stringify({ ...row, slot: undefined })}`)
  await drawTwice($ as never, clock, [band('terminal', FULL), pane('terminal', FULL), band('terminal', FULL)])
  expect(said.filter(isNotice)).toHaveLength(1)
  expect(said.filter(s => !isNotice(s))).toEqual([{ text: expect.stringMatching(/^mod-kit could not record that this Mac was told why buttons show as text \(.+\), so the next session will say it again\.$/), to: 'transcript' }])
  expect(kept).toEqual({})
})

test('a store that cannot be read says the notice once this session, and says why it may come again', withPublisher, async ($, on) => {
  engine(on)
  const clock = mock.clock(on, { now: 0 })
  const { said } = world(on, { readFails: true })
  mock.env(on, { TERM_PROGRAM: 'Apple_Terminal' })
  await run($, `show ${JSON.stringify(row)}`)
  await drawTwice($ as never, clock, [band('terminal', FULL), band('terminal', FULL)])
  expect(said.filter(isNotice)).toHaveLength(1)
  expect(said.filter(s => !isNotice(s))).toEqual([{ text: expect.stringMatching(/^mod-kit could not read whether this Mac was told why buttons show as text \(.+\), so it says it now/), to: 'transcript' }])
})

// A mod drawing its own Button (Simpler) asks $.modkit.clickable and draws text where it answers
// false, so that is a button drawn as text too.
test('$.modkit.clickable answering false in Apple Terminal fullscreen says the notice once as well', withPublisher, async ($, on) => {
  engine(on)
  const clock = mock.clock(on, { now: 0 })
  const { said } = world(on)
  mock.env(on, { TERM_PROGRAM: 'Apple_Terminal' })
  expect(await run($, `clickable ${JSON.stringify({ surface: 'terminal', viewport: MAIN })}`)).toBe('clickable false')
  await clock.advance(1)
  expect(said).toEqual([])
  expect(await run($, `clickable ${JSON.stringify({ surface: 'terminal', viewport: FULL })}`)).toBe('clickable false')
  expect(await run($, `clickable ${JSON.stringify({ surface: 'terminal', viewport: FULL })}`)).toBe('clickable false')
  await clock.advance(1)
  expect(said.filter(isNotice)).toHaveLength(1)
})
