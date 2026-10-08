import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type { ModKitBandRow, ModKitPane } from '../types/index.d.ts'
import { clicksReach, mostRows } from '../hooks/band.ts'

// #939: a band or pane Button is pressed by a click only where the surface reports clicks. The
// terminal reports them in the fullscreen layout alone, and Apple Terminal only while its per tab
// View > Allow Mouse Reporting is ticked, a switch cmd R flips and a mod cannot read. Dan's steps card
// drew [ Done ] and [ Copy link ] in a tab where it was off (measured 2026-10-08), so a click did
// nothing. A button carrying `instead` is drawn as that text wherever a click may not reach it.
const publisher: { name: string; register: Register } = {
  name: 'publisher',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => {
      const [verb, ...rest] = String((e as { command?: string }).command).split(' ')
      try {
        if (verb === 'show') await $.modkit.bandRow(JSON.parse(rest.join(' ')) as ModKitBandRow)
        if (verb === 'pane') await $.modkit.pane(JSON.parse(rest.join(' ')) as ModKitPane)
      } catch (err) {
        return { deny: `refused: ${String((err as Error).message ?? err)}` }
      }
      return { deny: 'done' }
    })
    on('ui.press', { plugin: 'mod-kit', element: 'publisher:done' }, ($, e) => {
      $.ui.toast(`pressed ${e.element}`)
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

type Found = { text: string; children: unknown[] }
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

test('in Apple Terminal, even fullscreen, a button with instead is drawn as that text and is no Button at all; one without keeps its Button', withPublisher, async ($, on) => {
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
    // A button the publisher gave no text for is drawn as before (its mod's own issue to decide).
    expect((await ui.find({ type: 'Button', key: 'publisher:compact' }))?.props.label).toBe('Compact')
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
  mock.env(on, { TERM_PROGRAM: 'iTerm.app' })
  await run($, `show ${JSON.stringify(row)}`)
  const ui = (await $.ui.mount(band('terminal', FULL))) as unknown as Ui
  expect((await ui.find({ type: 'Button', key: 'publisher:done' }))?.props.label).toBe('Done')
  expect(await texts(ui)).not.toContain('step 1 done')
  await ui.press({ key: 'publisher:done' })
  expect(seen).toEqual(['pressed publisher:done'])
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

test('a left rule over a wrapping line counts a button by the longer of its label and its instead text', () => {
  const long = [{ text: 'type: ' }, { text: 'step 12 done, a long phrase' }]
  const n = mostRows([[{ text: 'x', wrap: true }, { button: 'done', label: 'Done', instead: long }]])
  expect(n).toBeGreaterThanOrEqual(1 + 'type: step 12 done, a long phrase'.length)
})
