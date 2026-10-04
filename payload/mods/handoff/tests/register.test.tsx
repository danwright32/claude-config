import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'

// mod-kit, standing in: a mod cannot import another mod's files. It keeps the rows the handoff
// publishes and draws each line as a keyed Box of its parts, so the test reads the band as Dan
// would, line by line, with each part's own colour. mod-kit's own tests prove the real composer.
type Part = { text?: string; color?: string; bold?: boolean; dim?: boolean; indent?: number; button?: string; label?: string }
type Row = { mod: string; id: string; slot: string; lines: Part[][] }
const modKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const rows = async () => (((await built.state.get({ plugin: 'mod-kit', key: 'band' })) as { value?: Row[] }).value ?? [])
      const modkit = {
        bandRow: async (row: Row) => {
          if (!['needs-a-look', 'compact', 'handoff', 'held', 'steps', 'message', 'question'].includes(row.slot)) throw new Error(`no slot ${row.slot}`)
          const now = (await rows()).filter(r => !(r.mod === row.mod && r.id === row.id))
          await built.state.set({ plugin: 'mod-kit', key: 'band' }, [...now, row] as never)
        },
        clearBandRow: async ({ mod, id }: { mod: string; id: string }) => {
          await built.state.set({ plugin: 'mod-kit', key: 'band' }, (await rows()).filter(r => !(r.mod === mod && r.id === id)) as never)
        },
      }
      return { ...built, modkit } as never
    })
    on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
      const rows = ((await $.state.get({ plugin: 'mod-kit', key: 'band' })) as { value?: Row[] }).value ?? []
      if (!rows.length) return next(e)
      const { Box, Button, Text } = $.ui.resolve(e)
      return (
        <Box flexDirection="column">
          {rows.flatMap(r =>
            r.lines.map((l, n) => (
              <Box key={`line:${r.id}:${n}`} flexDirection="row">
                {l.map((p, i) =>
                  p.button ? (
                    <Button key={`${r.mod}:${p.button}`} label={p.label as string} onPress={() => undefined} />
                  ) : (
                    <Text key={String(i)} color={p.color} bold={p.bold} dimColor={p.dim}>
                      {`${' '.repeat(p.indent ?? 0)}${p.text}`}
                    </Text>
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

const MIN = 60_000
const HOUR = 60 * MIN
const T0 = 1_000 * HOUR
const DIR = '/Users/x/.claude/state/handoff/repo'
const CURRENT = `${DIR}/current.json`
const PROMPT = 'Continue milestone 18 in claude-config. Read #615 and its latest comment first. Do not build anything without asking.'

type Gh = Record<string, { exitCode: number; stdout?: string; stderr?: string }>
const issue = (state: string, updated: string, extra: object = {}) => ({ exitCode: 0, stdout: JSON.stringify({ state, updated_at: updated, ...extra }) })

// This Mac beneath the handoff: files in memory, mv and mkdir acting on them, gh answering per
// path as each test sets it, the clock, the session's repository, and Claude Code's own band.
const world = (on: On, init: { files?: Record<string, string>; gh?: Gh; root?: string; submit?: () => void; mvFailsTo?: string; noHome?: boolean } = {}) => {
  const files: Record<string, string> = { ...init.files }
  const gh: Gh = { ...init.gh }
  const toasts: string[] = []
  const logs: string[] = []
  const submitted: { text: string; asUser?: boolean }[] = []
  const commands: string[] = []
  const tools: string[] = []
  mock.env(on, init.noHome ? {} : { HOME: '/Users/x' })
  const clock = mock.clock(on, { now: T0 })
  on('fs.write', ($, e) => {
    files[e.path] = e.text
    return { value: undefined }
  })
  on('fs.read', ($, e) => {
    if (!(e.path in files)) throw new Error(`ENOENT: ${e.path}`)
    return { value: files[e.path] as string }
  })
  on('fs.exists', ($, e) => ({ value: e.path in files }) as never)
  on('process.run', ($, e) => {
    const [cmd, ...rest] = e.argv
    const r = (exitCode: number, stdout = '', stderr = '') => ({ value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false } })
    if (cmd === 'mkdir') return r(0)
    if (cmd === 'mv') {
      const [a, b] = rest.filter(x => !x.startsWith('-')) as [string, string]
      if (!(a in files)) return r(1, '', `mv: ${a}: No such file or directory`)
      if (b === init.mvFailsTo) return r(1, '', `mv: rename ${a} to ${b}: Permission denied`)
      if (rest.includes('-n') && b in files) return r(0)
      files[b] = files[a] as string
      delete files[a]
      return r(0)
    }
    if (cmd === 'gh' && rest[0] === 'api') {
      const a = gh[rest[1] as string] ?? { exitCode: 1, stderr: `gh: Not Found (HTTP 404)` }
      return r(a.exitCode, a.stdout ?? '', a.stderr ?? '')
    }
    return r(1, '', 'unexpected')
  })
  on('session.repo', () => ({ value: { root: init.root ?? '/repo', remote: 'git@github.com:x/repo.git', internal: false, name: null } }) as never)
  on('session.root', () => ({ value: '/repo' }) as never)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('command.register', ($, e) => {
    commands.push(e.name)
    return { value: { command: e.name } } as never
  })
  on('tool.register', ($, e) => {
    tools.push(e.name)
    return { value: { tool: `mcp__handoff__${e.name}` } } as never
  })
  on('prompt.submit', ($, e) => {
    init.submit?.()
    submitted.push({ text: e.text, asUser: (e.origin as { asUser?: boolean }).asUser })
    return { text: e.text }
  })
  on('ui.toast', ($, e) => {
    toasts.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  on('ui.log', ($, e) => {
    logs.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine band</Text>
  })
  return { files, gh, toasts, logs, submitted, commands, tools, clock }
}

const start = async ($: { session: { start: (e: never) => Promise<unknown> } }, clock: { settle: () => Promise<void> }, isInteractive = true) => {
  await $.session.start({ cwd: '/repo', surface: isInteractive ? 'terminal' : null, isInteractive } as never)
  await clock.settle()
}
const BASELINE = [
  { kind: 'milestone', number: 18, state: 'open', updatedAt: 'm' },
  { kind: 'issue', number: 615, state: 'open', updatedAt: 'a' },
]
const saved = (over: object = {}) => JSON.stringify({ v: 1, repo: '/repo', savedAt: T0 - 3 * HOUR, title: 'Continue milestone 18 design rounds', prompt: PROMPT, baseline: BASELINE, ...over })
// GitHub as it stood when the handoff was saved: milestone 18 and #615 both open, unchanged.
const M18 = { 'repos/{owner}/{repo}/milestones/18': issue('open', 'm') }

const band = { plugin: 'mod-kit', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 120, scroll: { offset: 0, bodyRows: 20 }, view: {} } } as never
type El = { type: string; key?: string; props: Record<string, unknown>; children: (El | string)[] }
type Ui = { findAll: (q: { type: string }) => Promise<El[]>; find: (q: object) => Promise<El | undefined>; press: (t: object) => Promise<unknown>; unmount: () => Promise<void> }
const textOf = (el: El | string): string => (typeof el === 'string' ? el : el.type === 'Button' ? `[${String(el.props.label)}]` : (el.children ?? []).map(textOf).join(''))
// The band as Dan reads it, one string per line; 'engine band' when the handoff shows nothing.
const lines = async (ui: Ui) => {
  const rows = (await ui.findAll({ type: 'Box' })).filter(b => String(b.key ?? b.props.key ?? '').startsWith('line:'))
  if (rows.length) return rows.map(textOf)
  return (await ui.findAll({ type: 'Text' })).map(textOf)
}
const mount = async ($: { ui: { mount: (t: never) => Promise<unknown> } }) => (await $.ui.mount(band)) as unknown as Ui

test('/handoff asks Claude to write it, and the save stores it with what it names as GitHub has them now', withKit, async ($, on) => {
  const w = world(on, { gh: { ...M18, 'repos/{owner}/{repo}/issues/615': issue('open', 'a') } })
  await start($, w.clock)
  expect(w.commands).toEqual(['handoff'])
  expect(w.tools).toEqual(['save'])
  await $.command.run({ command: 'handoff', args: 'stop before building' } as never)
  await w.clock.settle()
  expect([w.toasts, w.logs]).toEqual([[], []])
  expect(w.submitted).toHaveLength(1)
  expect(w.submitted[0]?.text).toContain('mcp__handoff__save')
  expect(w.submitted[0]?.text).toContain('stop before building')
  const r = (await $.tool.call({ tool: 'mcp__handoff__save', title: 'Continue milestone 18 design rounds', prompt: PROMPT } as never)) as { result?: string; deny?: string }
  expect(r.deny).toBeUndefined()
  expect(r.result).toContain(PROMPT)
  expect(JSON.parse(w.files[CURRENT] as string)).toEqual({
    v: 1,
    repo: '/repo',
    savedAt: T0,
    title: 'Continue milestone 18 design rounds',
    prompt: PROMPT,
    baseline: BASELINE,
  })
})

test('Claude cannot write a handoff on its own: the save is refused until Dan runs /handoff', withKit, async ($, on) => {
  const w = world(on)
  await start($, w.clock)
  const r = (await $.tool.call({ tool: 'mcp__handoff__save', title: 'T', prompt: 'P' } as never)) as { deny?: string; isError?: boolean; text?: string }
  expect(r.deny ?? r.text).toBe('A handoff is written only when Dan runs /handoff.')
  expect(CURRENT in w.files).toBe(false)
})

test('a save with no title or no prompt is refused, naming what is missing', withKit, async ($, on) => {
  const w = world(on)
  await start($, w.clock)
  await $.command.run({ command: 'handoff', args: '' } as never)
  const r = (await $.tool.call({ tool: 'mcp__handoff__save', title: ' ', prompt: PROMPT } as never)) as { deny?: string; text?: string }
  expect(r.deny ?? r.text).toBe('The handoff needs a title of a few words and the whole opening prompt.')
  expect(CURRENT in w.files).toBe(false)
})

test('a new /handoff replaces the saved one, and the old one is archived, never deleted', withKit, async ($, on) => {
  const w = world(on, { files: { [CURRENT]: saved() }, gh: { ...M18, 'repos/{owner}/{repo}/issues/615': issue('open', 'a') } })
  await start($, w.clock)
  await $.command.run({ command: 'handoff', args: '' } as never)
  await $.tool.call({ tool: 'mcp__handoff__save', title: 'New work', prompt: 'Pick up #615.' } as never)
  expect(JSON.parse(w.files[CURRENT] as string).title).toBe('New work')
  expect(JSON.parse(w.files[`${DIR}/archive/${T0}-replaced.json`] as string).title).toBe('Continue milestone 18 design rounds')
})

test('the next session start shows the handoff with its age, amber lead, then Use and Dismiss', withKit, async ($, on) => {
  const w = world(on, { files: { [CURRENT]: saved() }, gh: { ...M18, 'repos/{owner}/{repo}/issues/615': issue('open', 'a') } })
  await start($, w.clock)
  const ui = await mount($)
  expect(await lines(ui)).toEqual(['Handoff saved 3h ago: Continue milestone 18 design rounds', '[Use]  [Dismiss]'])
  expect((await ui.find({ type: 'Text', text: 'Handoff saved 3h ago: ' }))?.props).toMatchObject({ color: 'warning', bold: true })
  await ui.unmount()
})

test('something it names that changed since gets its own grey line under it (an injected issue state change)', withKit, async ($, on) => {
  const w = world(on, { files: { [CURRENT]: saved() }, gh: { ...M18, 'repos/{owner}/{repo}/issues/615': issue('closed', 'b') } })
  await start($, w.clock)
  const ui = await mount($)
  expect(await lines(ui)).toEqual(['Handoff saved 3h ago: Continue milestone 18 design rounds', '   changed since: #615 closed', '[Use]  [Dismiss]'])
  expect((await ui.find({ type: 'Text', text: '   changed since: #615 closed' }))?.props).toMatchObject({ dimColor: true })
  expect((await ui.find({ type: 'Text', text: '   changed since: #615 closed' }))?.props.color).toBeUndefined()
  await ui.unmount()
})

test('a name GitHub cannot be asked about is said so on the band, never shown as current (L61)', withKit, async ($, on) => {
  const w = world(on, { files: { [CURRENT]: saved() }, gh: { ...M18, 'repos/{owner}/{repo}/issues/615': { exitCode: 1, stderr: 'error connecting to api.github.com\nmore' } } })
  await start($, w.clock)
  const ui = await mount($)
  expect((await lines(ui))[1]).toBe('   #615 could not be checked: error connecting to api.github.com')
  await ui.unmount()
})

test('a worktree of the repository sees the repository handoff: keyed on the repository, not the folder', withKit, async ($, on) => {
  const w = world(on, { files: { [CURRENT]: saved() }, gh: { ...M18, 'repos/{owner}/{repo}/issues/615': issue('open', 'a') } })
  await $.session.start({ cwd: '/repo/.claude/worktrees/wt', surface: 'terminal', isInteractive: true } as never)
  await w.clock.settle()
  const ui = await mount($)
  expect((await lines(ui))[0]).toBe('Handoff saved 3h ago: Continue milestone 18 design rounds')
  await ui.unmount()
})

test('Use submits the handoff as Dan, archives it as used, and it is never offered again', withKit, async ($, on) => {
  const w = world(on, { files: { [CURRENT]: saved() }, gh: { ...M18, 'repos/{owner}/{repo}/issues/615': issue('open', 'a') } })
  await start($, w.clock)
  const ui = await mount($)
  await ui.press({ key: 'handoff:use' })
  await w.clock.settle()
  expect(w.submitted).toEqual([{ text: PROMPT, asUser: true }])
  expect(CURRENT in w.files).toBe(false)
  expect(JSON.parse(w.files[`${DIR}/archive/${T0}-used.json`] as string).prompt).toBe(PROMPT)
  expect(await lines(ui)).toEqual(['engine band'])
  await ui.unmount()
})

test('Use after another session already took it submits nothing and says so', withKit, async ($, on) => {
  const w = world(on, { files: { [CURRENT]: saved() }, gh: { ...M18, 'repos/{owner}/{repo}/issues/615': issue('open', 'a') } })
  await start($, w.clock)
  const ui = await mount($)
  delete w.files[CURRENT]
  await ui.press({ key: 'handoff:use' })
  await w.clock.settle()
  expect(w.submitted).toEqual([])
  expect(w.toasts).toEqual(['This handoff was already used or dismissed in another session.'])
  expect(await lines(ui)).toEqual(['engine band'])
  await ui.unmount()
})

test('a Use that cannot send puts the handoff back and says why', withKit, async ($, on) => {
  const w = world(on, {
    files: { [CURRENT]: saved() },
    gh: { ...M18, 'repos/{owner}/{repo}/issues/615': issue('open', 'a') },
    submit: () => {
      throw new Error('the session is closing')
    },
  })
  await start($, w.clock)
  const ui = await mount($)
  await ui.press({ key: 'handoff:use' })
  await w.clock.settle()
  expect(JSON.parse(w.files[CURRENT] as string).prompt).toBe(PROMPT)
  expect(w.toasts).toHaveLength(1)
  expect(w.toasts[0]).toMatch(/^Use did not send the handoff: \S/)
  expect((await lines(ui))[0]).toBe('Handoff saved 3h ago: Continue milestone 18 design rounds')
  await ui.unmount()
})

test('Dismiss archives it without sending anything', withKit, async ($, on) => {
  const w = world(on, { files: { [CURRENT]: saved() }, gh: { ...M18, 'repos/{owner}/{repo}/issues/615': issue('open', 'a') } })
  await start($, w.clock)
  const ui = await mount($)
  await ui.press({ key: 'handoff:dismiss' })
  expect(w.submitted).toEqual([])
  expect(CURRENT in w.files).toBe(false)
  expect(`${DIR}/archive/${T0}-dismissed.json` in w.files).toBe(true)
  expect(await lines(ui)).toEqual(['engine band'])
  await ui.unmount()
})

test('a saved handoff that cannot be read is named in one dim line, never offered or taken for none', withKit, async ($, on) => {
  const w = world(on, { files: { [CURRENT]: '{"v":1,' } })
  await start($, w.clock)
  const ui = await mount($)
  expect(await lines(ui)).toEqual(['engine band'])
  expect(w.logs).toHaveLength(1)
  expect(w.logs[0]).toMatch(/^The saved handoff could not be read \(\/Users\/x\/\.claude\/state\/handoff\/repo\/current\.json\): \S/)
  await ui.unmount()
})

test('a session with no one at the prompt shows nothing and reads nothing', withKit, async ($, on) => {
  const w = world(on, { files: { [CURRENT]: saved() } })
  await start($, w.clock, false)
  const ui = await mount($)
  expect(await lines(ui)).toEqual(['engine band'])
  await ui.unmount()
})

for (const button of ['use', 'dismiss'] as const) {
  test(`${button === 'use' ? 'Use' : 'Dismiss'} on a handoff replaced since the band showed it acts on nothing, and the band shows the new one`, withKit, async ($, on) => {
    const w = world(on, { files: { [CURRENT]: saved() }, gh: { ...M18, 'repos/{owner}/{repo}/issues/615': issue('open', 'a') } })
    await start($, w.clock)
    const ui = await mount($)
    // Another session saved a new handoff for this repository after this band was drawn.
    w.files[CURRENT] = saved({ savedAt: T0 - MIN, title: 'Newer work', prompt: 'Pick up the next one.', baseline: [] })
    await ui.press({ key: `handoff:${button}` })
    await w.clock.settle()
    expect(w.submitted).toEqual([])
    expect(JSON.parse(w.files[CURRENT] as string).title).toBe('Newer work')
    expect(w.toasts).toEqual(['The handoff was replaced since this session started; the band now shows the new one.'])
    expect(await lines(ui)).toEqual(['Handoff saved 1m ago: Newer work', '[Use]  [Dismiss]'])
    await ui.unmount()
  })
}

test('a save that cannot be moved into place is refused with the reason, not reported as saved', withKit, async ($, on) => {
  const w = world(on, { gh: { ...M18, 'repos/{owner}/{repo}/issues/615': issue('open', 'a') }, mvFailsTo: CURRENT })
  await start($, w.clock)
  await $.command.run({ command: 'handoff', args: '' } as never)
  const r = (await $.tool.call({ tool: 'mcp__handoff__save', title: 'T', prompt: PROMPT } as never)) as { deny?: string; text?: string; result?: string }
  expect(r.result).toBeUndefined()
  expect(r.deny ?? r.text).toBe(`The handoff could not be saved: mv: rename ${DIR}/.current.json.tmp to ${CURRENT}: Permission denied`)
  expect(CURRENT in w.files).toBe(false)
})

test('/handoff whose prompt cannot be submitted says so in a toast', withKit, async ($, on) => {
  const w = world(on, {
    submit: () => {
      throw new Error('the session is closing')
    },
  })
  await start($, w.clock)
  await $.command.run({ command: 'handoff', args: '' } as never)
  await w.clock.settle()
  expect(w.toasts).toHaveLength(1)
  expect(w.toasts[0]).toMatch(/^\/handoff could not ask for the handoff: \S/)
})

test('a handoff that cannot be offered at all says why in one dim line', withKit, async ($, on) => {
  const w = world(on, { files: { [CURRENT]: saved() }, noHome: true })
  await start($, w.clock)
  expect(w.logs).toEqual(['The saved handoff could not be offered: HOME is not set.'])
})

test('a Use that cannot send never puts its handoff back over a newer one saved meanwhile', withKit, async ($, on) => {
  const newer = saved({ savedAt: T0 - MIN, title: 'Newer work', prompt: 'Pick up the next one.', baseline: [] })
  const box: { w?: ReturnType<typeof world> } = {}
  box.w = world(on, {
    files: { [CURRENT]: saved() },
    gh: { ...M18, 'repos/{owner}/{repo}/issues/615': issue('open', 'a') },
    submit: () => {
      ;(box.w as ReturnType<typeof world>).files[CURRENT] = newer
      throw new Error('the session is closing')
    },
  })
  const w = box.w
  await start($, w.clock)
  const ui = await mount($)
  await ui.press({ key: 'handoff:use' })
  await w.clock.settle()
  expect(JSON.parse(w.files[CURRENT] as string).title).toBe('Newer work')
  expect(JSON.parse(w.files[`${DIR}/archive/${T0}-used.json`] as string).title).toBe('Continue milestone 18 design rounds')
  // The engine words the refusal its own way; what matters is the newer one being named as kept.
  expect(w.toasts).toHaveLength(1)
  expect(w.toasts[0]).toMatch(/^Use did not send the handoff: \S.*\. A newer one was saved meanwhile, so this one stays in the archive\.$/)
  await ui.unmount()
})

test('a save whose old handoff cannot be archived is refused, and the old one is kept', withKit, async ($, on) => {
  const w = world(on, { files: { [CURRENT]: saved() }, gh: { ...M18, 'repos/{owner}/{repo}/issues/615': issue('open', 'a') }, mvFailsTo: `${DIR}/archive/${T0}-replaced.json` })
  await start($, w.clock)
  await $.command.run({ command: 'handoff', args: '' } as never)
  const r = (await $.tool.call({ tool: 'mcp__handoff__save', title: 'New work', prompt: 'Pick up #615.' } as never)) as { deny?: string; text?: string; result?: string }
  expect(r.result).toBeUndefined()
  expect(r.deny ?? r.text).toBe(`The handoff could not be saved: the one it replaces could not be archived (mv: rename ${CURRENT} to ${DIR}/archive/${T0}-replaced.json: Permission denied)`)
  expect(JSON.parse(w.files[CURRENT] as string).title).toBe('Continue milestone 18 design rounds')
})
