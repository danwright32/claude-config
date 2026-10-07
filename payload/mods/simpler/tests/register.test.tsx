import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On, PromptOrigin, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { LONG_WORDS, REPORT_EVERY_MS, judge, requestText } from '../hooks/simpler.ts'

const DAY = 24 * 60 * 60 * 1000
const SURFACES = ['terminal', 'desktop'] as const
const LONG = `There are two options here, and the trade-off is speed. ${Array.from({ length: LONG_WORDS }, () => 'word').join(' ')}`
const SHORT = 'Done. The PR is merged.'
const FIRST_BLOCK = 'There are two options here, and the trade-off is speed.'

// Everything beneath the mod: the clock, a store that can be made to fail, the engine's own
// drawing of a reply, the prompt box, submits, toasts and transcript lines.
const world = (on: On, opts: { now?: number; store?: Record<string, unknown>; drop?: string; submitThrows?: boolean } = {}) => {
  const clock = mock.clock(on, { now: opts.now ?? 100 * DAY })
  const store: Record<string, unknown> = { ...(opts.store ?? {}) }
  const fail = { get: false, set: false, keys: false }
  // Runs after each read is answered, so a test can stage another session writing in between.
  const between = { afterGet: (_key: string) => {} }
  on('store.get', ($, e) => {
    if (fail.get) throw new Error('store unreadable')
    const value = store[e.key]
    between.afterGet(e.key)
    return { value } as never
  })
  on('store.set', ($, e) => {
    if (fail.set) throw new Error('disk full')
    store[e.key] = e.value
    return { value: undefined } as never
  })
  on('store.keys', () => {
    if (fail.keys) throw new Error('store unreadable')
    return { value: Object.keys(store) } as never
  })
  const submits: { text: string; asUser?: boolean }[] = []
  on('prompt.submit', ($, e) => {
    if (opts.submitThrows) throw new Error('session closed')
    submits.push({ text: e.text, asUser: e.origin.kind === 'plugin' ? e.origin.asUser : undefined })
    if (opts.drop) return { drop: opts.drop }
    return { text: e.text }
  })
  on('prompt.edit', ($, e) => ({ text: e.text.slice(0, e.start) + e.inputText + e.text.slice(e.end), cursor: e.start + e.inputText.length }))
  on('turn.complete', ($, e) => ({ text: e.answer }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  const toasts: string[] = []
  const logs: string[] = []
  const debug: string[] = []
  on('ui.toast', ($, e) => { toasts.push(e.text); return { value: undefined } as never })
  on('ui.log', ($, e) => { (e.to === 'debug' ? debug : logs).push(e.text); return { value: undefined } as never })
  // The engine's own drawing of a reply, for every reply the mod leaves alone.
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text key="engine">{e.props.text}</Text>
  })
  // The folders on this Mac every session shares, for the weekly count's claim: mkdir makes one or
  // says it exists, rmdir takes it away, stat reads its age. `mkdirFails` stands for a folder that
  // cannot be made at all (a full or unwritable disk).
  mock.env(on, { HOME: '/Users/x' })
  const dirs = new Map<string, number>()
  const disk = { mkdirFails: '' }
  on('process.run', ($, e) => {
    const [cmd, ...rest] = e.argv
    const path = rest.filter(a => !a.startsWith('-'))[0] ?? ''
    const r = (exitCode: number, stderr = '') => ({ value: { exitCode, stdout: '', stderr, isStdoutTruncated: false, isStderrTruncated: false } }) as never
    if (cmd === 'mkdir' && rest.includes('-p')) return r(0)
    if (cmd === 'mkdir') {
      if (disk.mkdirFails) return r(1, disk.mkdirFails)
      if (dirs.has(path)) return r(1, `mkdir: ${path}: File exists`)
      dirs.set(path, clock.now())
      return r(0)
    }
    if (cmd === 'rmdir') return r(dirs.delete(path) ? 0 : 1, dirs.has(path) ? '' : `rmdir: ${path}: No such file or directory`)
    return r(1, `unexpected command ${cmd}`)
  })
  on('fs.stat', ($, e) => {
    const at = dirs.get(e.path)
    if (at === undefined) return { deny: `no such file: ${e.path}` } as never
    return { value: { kind: 'dir', size: 0, mtimeMs: at, isLink: false } } as never
  })
  return { clock, store, fail, between, submits, toasts, logs, debug, dirs, disk }
}
const CLAIM = '/Users/x/.claude/state/simpler/weekly.lock'

const answer = ($: Engine, text: string, extra: Record<string, unknown> = {}) =>
  $.turn.complete({ answer: text, durationMs: 1, isAborted: false, turnId: 't', reason: 'answer', ...extra } as never)
const start = ($: Engine, isInteractive = true) =>
  $.session.start({ cwd: '/Users/x/Documents/Bidspoke', surface: isInteractive ? 'terminal' : null, isInteractive })
const mountReply = ($: Engine, surface: (typeof SURFACES)[number], text = FIRST_BLOCK, isFirstOfReply = true) =>
  $.ui.mount({ plugin: 'simpler', surface, component: 'AssistantMessage', props: { text, isFirstOfReply } })
const type = ($: Engine, inputText: string) =>
  ($.prompt as unknown as { edit: (e: unknown) => Promise<unknown> }).edit({ origin: { kind: 'composer' }, text: '', cursor: 0, start: 0, end: 0, inputText })
const submitAs = ($: Engine, origin: PromptOrigin) =>
  ($.prompt as unknown as { submit: (e: unknown) => Promise<unknown> }).submit({ text: 'hi', wait: false, origin })

// The drawing's leaves in document order: each Text's words and each Button's label.
const leaves = async (ui: { findAll: (q: object) => Promise<{ type: string; text: string }[]> }) =>
  (await ui.findAll({})).filter(n => n.type === 'Text' || n.type === 'Button').map(n => n.text)

test('the threshold: a long answer gets the button at the top of its reply, on every surface', async ($, on) => {
  world(on)
  await start($)
  await answer($, LONG)
  for (const surface of SURFACES) {
    const ui = await mountReply($, surface)
    expect(await ui.find({ type: 'Button', key: 'simpler' })).toBeDefined()
    // The reply itself is still drawn, under the button, by whatever draws it beneath this mod.
    expect(await leaves(ui as never)).toEqual(['Simpler', FIRST_BLOCK])
    await ui.unmount()
  }
})

// Add-on notes (#620), standing in, since a mod's tests cannot import another mod's files. As the
// real mod does, it owns the resume line that can open a reply: it answers what that line is through
// its noun ($.addonNotes.resumeLine), draws it dim where it opens a reply, and hands the rest of the
// block on. Everything it uses is inside register, which the kit loads as a module of its own, so
// the broken one (its noun throws) is a register of its own rather than an option.
const addonNotesDraws: Register = on => {
  const PREFIX = '+ add-on: '
  const resumeLine = (text: string) => {
    const nl = text.indexOf('\n')
    const line = (nl === -1 ? text : text.slice(0, nl)).trimEnd()
    if (!line.startsWith(PREFIX) || !line.slice(PREFIX.length).trim()) return null
    return { line, rest: nl === -1 ? '' : text.slice(nl + 1).trim() }
  }
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { ...built, addonNotes: { resumeLine: async ({ text }: { text: string }) => resumeLine(text) } }
  })
  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    const props = e.props as { text: string; isFirstOfReply: boolean }
    if (!props.isFirstOfReply) return next(e)
    const found = resumeLine(props.text)
    if (!found) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const line = <Text key="resume" dimColor>{found.line}</Text>
    if (!found.rest) return line
    return (
      <Box flexDirection="column">
        {line}
        {await next({ ...e, props: { ...e.props, text: found.rest } })}
      </Box>
    )
  })
}
const addonNotesBroken: Register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    const resumeLine = async () => {
      throw new Error('add-on notes is broken')
    }
    return { ...built, addonNotes: { resumeLine } }
  })
}
const AddonNotes = (tier: 'prepend' | 'append', register: Register = addonNotesDraws) => ({ name: 'addon-notes', tier, register })
const OPENING = '+ add-on: Adding a direct link to the commission and carrying on.'

// #701: both mods redraw a reply's first block. Hooks nest by tier and then by load order, which a
// mod cannot choose, so a long reply opening with the resume line must get both, drawn the same way,
// whichever of the two sits outermost: the dim line opening the reply, the button under it, the answer.
for (const [where, tier] of [['above', 'prepend'], ['beneath', 'append']] as const) {
  test(`a long reply opening with the add-on line gets the dim line, then the button, with add-on notes ${where} Simpler`, { plugins: [AddonNotes(tier)] }, async ($, on) => {
    world(on)
    await start($)
    await answer($, `${OPENING}\n\n${LONG}`)
    for (const surface of SURFACES) {
      const ui = await mountReply($, surface, `${OPENING}\n\n${FIRST_BLOCK}`)
      expect(await leaves(ui as never)).toEqual([OPENING, 'Simpler', FIRST_BLOCK])
      expect((await ui.find({ type: 'Text', text: OPENING }))?.props.dimColor).toBe(true)
      await ui.unmount()
    }
  })
}

test('with add-on notes not loaded, a reply opening with that line is one answer, the button above it all', async ($, on) => {
  world(on)
  await start($)
  await answer($, `${OPENING}\n\n${LONG}`)
  const ui = await mountReply($, 'terminal', `${OPENING}\n\n${FIRST_BLOCK}`)
  expect(await leaves(ui as never)).toEqual(['Simpler', `${OPENING}\n\n${FIRST_BLOCK}`])
  await ui.unmount()
})

test('an add-on notes that cannot read the line still leaves the button on the reply, said in the debug log', { plugins: [AddonNotes('append', addonNotesBroken)] }, async ($, on) => {
  const w = world(on)
  await start($)
  await answer($, `${OPENING}\n\n${LONG}`)
  const ui = await mountReply($, 'terminal', `${OPENING}\n\n${FIRST_BLOCK}`)
  expect(await ui.find({ type: 'Button', key: 'simpler' })).toBeDefined()
  expect(w.debug.filter(l => /add-on notes could not read/.test(l))).toHaveLength(1)
  expect(w.logs).toEqual([])
  await ui.unmount()
})

test('the threshold: a short answer gets no button, and the engine draws the reply', async ($, on) => {
  world(on)
  await start($)
  expect(judge(SHORT)).toBeNull()
  await answer($, SHORT)
  for (const surface of SURFACES) {
    const ui = await mountReply($, surface, SHORT)
    expect(await ui.find({ key: 'simpler' })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: SHORT })).toBeDefined()
    await ui.unmount()
  }
})

test('the button is only on the first block of the latest answer', async ($, on) => {
  world(on)
  await start($)
  await answer($, LONG)
  const later = await mountReply($, 'terminal', FIRST_BLOCK, false)
  expect(await later.find({ key: 'simpler' })).toBeUndefined()
  await later.unmount()
  const earlier = await mountReply($, 'terminal', 'An earlier answer about something else entirely.')
  expect(await earlier.find({ key: 'simpler' })).toBeUndefined()
  await earlier.unmount()
})

test('a newer short answer takes the button away; an aborted turn does too; a subagent turn does not', async ($, on) => {
  world(on)
  await start($)
  await answer($, LONG)
  await answer($, SHORT, { agentId: 'a1' })
  let ui = await mountReply($, 'terminal')
  expect(await ui.find({ key: 'simpler' })).toBeDefined()
  await ui.unmount()
  await answer($, LONG, { reason: 'aborted', isAborted: true })
  ui = await mountReply($, 'terminal')
  expect(await ui.find({ key: 'simpler' })).toBeUndefined()
  await ui.unmount()
  await answer($, LONG)
  await answer($, SHORT)
  ui = await mountReply($, 'terminal')
  expect(await ui.find({ key: 'simpler' })).toBeUndefined()
  await ui.unmount()
})

test('disappears once Dan types', async ($, on) => {
  world(on)
  await start($)
  await answer($, LONG)
  const ui = await mountReply($, 'terminal')
  expect(await ui.find({ key: 'simpler' })).toBeDefined()
  await type($, 'o')
  expect(await ui.find({ key: 'simpler' })).toBeUndefined()
  // The reply is left to whatever draws it beneath, once.
  expect(await leaves(ui as never)).toEqual([FIRST_BLOCK])
  await ui.unmount()
})

test("disappears when Dan sends from the phone, not when a background task's notice arrives", async ($, on) => {
  world(on)
  await start($)
  await answer($, LONG)
  await submitAs($, { kind: 'task-notification' })
  let ui = await mountReply($, 'terminal')
  expect(await ui.find({ key: 'simpler' })).toBeDefined()
  await ui.unmount()
  await submitAs($, { kind: 'bridge' })
  ui = await mountReply($, 'terminal')
  expect(await ui.find({ key: 'simpler' })).toBeUndefined()
  await ui.unmount()
})

test('pressing it submits the request as Dan, logs the press with the kind, and takes the button away', async ($, on) => {
  const w = world(on)
  await start($)
  await answer($, LONG)
  const ui = await mountReply($, 'terminal')
  await ui.press({ key: 'simpler' })
  expect(w.submits).toEqual([{ text: requestText('Bidspoke'), asUser: true }])
  const presses = Object.entries(w.store).filter(([k]) => k.startsWith('press:'))
  expect(presses).toHaveLength(1)
  expect(presses[0]?.[0]).toMatch(new RegExp(`^press:${100 * DAY}:[a-z0-9]+$`))
  expect(presses[0]?.[1]).toMatchObject({ at: 100 * DAY, kind: 'design', reason: 'long' })
  expect(await ui.find({ key: 'simpler' })).toBeUndefined()
  expect(w.toasts).toEqual([])
  await ui.unmount()
})

test('a refused submit says why and puts the button back; the press is still counted', async ($, on) => {
  const w = world(on, { drop: 'a hook refused it' })
  await start($)
  await answer($, LONG)
  const ui = await mountReply($, 'terminal')
  await ui.press({ key: 'simpler' })
  expect(w.toasts).toEqual(['Simpler could not ask for the short version: a hook refused it'])
  expect(await ui.find({ key: 'simpler' })).toBeDefined()
  expect(Object.keys(w.store).filter(k => k.startsWith('press:'))).toHaveLength(1)
  await ui.unmount()
})

test('a submit that throws says why and puts the button back', async ($, on) => {
  const w = world(on, { submitThrows: true })
  await start($)
  await answer($, LONG)
  const ui = await mountReply($, 'terminal')
  await ui.press({ key: 'simpler' })
  expect(w.toasts).toHaveLength(1)
  expect(w.toasts[0]).toContain('Simpler could not ask for the short version: ')
  expect(w.toasts[0]).toMatch(/: .+/)
  expect(await ui.find({ key: 'simpler' })).toBeDefined()
  await ui.unmount()
})

test('a press the store cannot record still asks, and says the count will miss it', async ($, on) => {
  const w = world(on)
  await start($)
  await answer($, LONG)
  w.fail.set = true
  const ui = await mountReply($, 'terminal')
  await ui.press({ key: 'simpler' })
  expect(w.submits).toHaveLength(1)
  expect(w.logs).toHaveLength(1)
  expect(w.logs[0]).toMatch(/^Simpler couldn't record this press, so the weekly count will miss it: .+/)
  await ui.unmount()
})

test('without a project name the request asks for an example from this project', async ($, on) => {
  const w = world(on)
  await answer($, LONG)
  const ui = await mountReply($, 'terminal')
  await ui.press({ key: 'simpler' })
  expect(w.submits[0]?.text).toBe(requestText(undefined))
  await ui.unmount()
})

test('the weekly count: the first session starts the week and says nothing', async ($, on) => {
  const w = world(on)
  await start($)
  expect(w.logs).toEqual([])
  expect(w.store.reportedAt).toBe(100 * DAY)
})

test('the weekly count: nothing before a week, then one line naming the kinds pressed since the last count', async ($, on) => {
  const since = 100 * DAY - REPORT_EVERY_MS
  const w = world(on, {
    now: 100 * DAY - 1,
    store: {
      reportedAt: since,
      // Before the last count: not this week's.
      [`press:${since - 1}:old`]: { at: since - 1, kind: 'status', reason: 'long', words: 300 },
      [`press:${since + 1}:a`]: { at: since + 1, kind: 'design', reason: 'long', words: 300 },
      [`press:${since + 2}:b`]: { at: since + 2, kind: 'design', reason: 'technical', words: 120 },
      [`press:${since + 3}:c`]: { at: since + 3, kind: 'plan', reason: 'long', words: 400 },
    },
  })
  await start($)
  expect(w.logs).toEqual([])
  await w.clock.set(100 * DAY)
  await start($)
  expect(w.logs).toEqual(['Simpler was pressed 3 times in the last 7 days: after 2 design answers and 1 plan.'])
  expect(w.store.reportedAt).toBe(100 * DAY)
  // Once a week: the next session the same day says nothing.
  await start($)
  expect(w.logs).toHaveLength(1)
})

test('the weekly count says so when Simpler was not pressed', async ($, on) => {
  const w = world(on, { store: { reportedAt: 100 * DAY - 8 * DAY } })
  await start($)
  expect(w.logs).toEqual(['Simpler was not pressed in the last 8 days.'])
})

test('the weekly count is not shown in a session nobody is at', async ($, on) => {
  const w = world(on, { store: { reportedAt: 0 } })
  await start($, false)
  expect(w.logs).toEqual([])
  expect(w.store.reportedAt).toBe(0)
})

test('a press log that cannot be read is named, and the count is tried again next session', async ($, on) => {
  const w = world(on, { store: { reportedAt: 0 } })
  w.fail.keys = true
  await start($)
  expect(w.logs).toHaveLength(1)
  expect(w.logs[0]).toMatch(/^Simpler couldn't read its press log, so this week's count is not shown: .+/)
  expect(w.store.reportedAt).toBe(0)
  w.fail.keys = false
  await start($)
  expect(w.logs[1]).toBe('Simpler was not pressed in the last 100 days.')
})

// #701: "once a week, at a session start". Two sessions started together once the week is up each
// read the last count's time before either records the new one, so the count is claimed on this Mac
// before it is shown, and read again under the claim.
test('the weekly count: two sessions starting at once once the week is up show it once', async ($, on) => {
  const w = world(on, { store: { reportedAt: 100 * DAY - 8 * DAY } })
  await Promise.all([start($), start($)])
  expect(w.logs).toEqual(['Simpler was not pressed in the last 8 days.'])
  expect(w.store.reportedAt).toBe(100 * DAY)
  // The claim is let go once the count is recorded, so next week's can be made.
  expect([...w.dirs.keys()]).toEqual([])
})

test('the weekly count: a claim another session holds means it is being shown there, so this one says nothing', async ($, on) => {
  const w = world(on, { store: { reportedAt: 100 * DAY - 8 * DAY } })
  w.dirs.set(CLAIM, 100 * DAY - 60_000)
  await start($)
  expect(w.logs).toEqual([])
  // Not closed here: the session holding the claim records it.
  expect(w.store.reportedAt).toBe(100 * DAY - 8 * DAY)
})

test('the weekly count: a claim left by a session that died holding it is taken over once it is old', async ($, on) => {
  const w = world(on, { store: { reportedAt: 100 * DAY - 8 * DAY } })
  w.dirs.set(CLAIM, 100 * DAY - 11 * 60_000)
  await start($)
  expect(w.logs).toEqual(['Simpler was not pressed in the last 8 days.'])
  expect(w.store.reportedAt).toBe(100 * DAY)
  expect([...w.dirs.keys()]).toEqual([])
})

test('the weekly count: a claim that cannot be made at all still shows the count, said in the debug log', async ($, on) => {
  const w = world(on, { store: { reportedAt: 100 * DAY - 8 * DAY } })
  w.disk.mkdirFails = 'mkdir: weekly.lock: Permission denied'
  await start($)
  expect(w.logs).toEqual(['Simpler was not pressed in the last 8 days.'])
  expect(w.debug.filter(l => /could not claim the weekly count.*Permission denied/.test(l))).toHaveLength(1)
})

test('the weekly count: a session that gets the claim after the count was recorded says nothing', async ($, on) => {
  const since = 100 * DAY - 8 * DAY
  const w = world(on, { store: { reportedAt: since } })
  // Another session records the count between this one's first read and its claim.
  let reads = 0
  w.between.afterGet = key => {
    if (key === 'reportedAt' && ++reads === 1) w.store.reportedAt = 100 * DAY - 60_000
  }
  await start($)
  expect(w.logs).toEqual([])
  expect(w.store.reportedAt).toBe(100 * DAY - 60_000)
  expect([...w.dirs.keys()]).toEqual([])
})
