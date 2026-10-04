import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'

// mod-kit, standing in: a mod cannot import another mod's files. It keeps the rows the status bar
// publishes and draws them in the band in mod-kit's slot order, text and buttons, so the test reads
// what Dan would. mod-kit's own tests prove the real composer.
type Part = { text?: string; color?: string; bold?: boolean; dim?: boolean; button?: string; label?: string }
type Row = { mod: string; id: string; slot: string; lines: Part[][] }
const modKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    // Everything the stand-in uses is inside register: the kit loads it as a module of its own.
    const ORDER = ['needs-a-look', 'compact', 'steps', 'message', 'question']
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const rows = async () => (((await built.state.get({ plugin: 'mod-kit', key: 'band' })) as { value?: Row[] }).value ?? [])
      const modkit = {
        bandRow: async (row: Row) => {
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
      const rows = (((await $.state.get({ plugin: 'mod-kit', key: 'band' })) as { value?: Row[] }).value ?? []).sort((a, b) => ORDER.indexOf(a.slot) - ORDER.indexOf(b.slot))
      if (!rows.length) return next(e)
      const { Box, Button, Text } = $.ui.resolve(e)
      return (
        <Box flexDirection="column">
          {rows.flatMap(r =>
            r.lines.map((l, n) => (
              <Box key={`${r.id}${n}`} flexDirection="row">
                {l.map((p, i) =>
                  p.button ? (
                    <Button key={`${r.mod}:${p.button}`} label={p.label as string} onPress={() => undefined} />
                  ) : (
                    <Text key={String(i)} color={p.color} bold={p.bold} dimColor={p.dim}>
                      {p.text}
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
const DIR = '/Users/x/.claude/state/status-bar'

// This Mac beneath the status bar: files in memory, git and gh answering as each test sets them,
// the clock, the session, and Claude Code's own band beneath mod-kit's.
type World = {
  remotes: string
  unpushed: string
  gh: { exitCode: number; stdout: string; stderr: string }
  usage: number | undefined
  compact: () => unknown
}
const world = (on: On, init: Partial<World> = {}) => {
  const w: World = {
    remotes: 'origin\n',
    unpushed: '0\n',
    gh: { exitCode: 1, stdout: '', stderr: 'no pull requests found for branch "x"' },
    usage: undefined,
    compact: () => ({ messages: [{ role: 'assistant', text: 'summary', toolUses: [] }] }),
    ...init,
  }
  const files: Record<string, string> = {}
  const toasts: string[] = []
  const logs: string[] = []
  const compacts: number[] = []
  const runs: string[][] = []
  mock.env(on, { HOME: '/Users/x' })
  const clock = mock.clock(on, { now: T0 })
  on('fs.write', ($, e) => {
    files[e.path] = e.text
    return { value: undefined }
  })
  on('process.run', ($, e) => {
    runs.push([...e.argv])
    const [cmd, ...rest] = e.argv
    const r = (exitCode: number, stdout = '', stderr = '') => ({ value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false } })
    if (cmd === 'mkdir') return r(0)
    if (cmd === 'mv') {
      const [a, b] = rest.filter(x => !x.startsWith('-'))
      files[b as string] = files[a as string] as string
      delete files[a as string]
      return r(0)
    }
    if (cmd === 'rm') {
      for (const f of rest.filter(x => !x.startsWith('-'))) delete files[f]
      return r(0)
    }
    if (cmd === 'git' && rest.includes('remote')) return r(0, w.remotes)
    if (cmd === 'git' && rest.includes('rev-list')) return r(0, w.unpushed)
    if (cmd === 'gh') return r(w.gh.exitCode, w.gh.stdout, w.gh.stderr)
    return r(1, '', 'unexpected')
  })
  on('session.id', () => ({ value: 's1' }) as never)
  on('session.root', () => ({ value: '/repo' }) as never)
  on('session.usage', () => ({ value: { startedAt: T0, context: { window: 200_000, percent: w.usage }, rateLimits: [] } }) as never)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }) as never)
  on('session.measure', ($, e) => ({ changed: e.changed }) as never)
  on('session.compact', () => {
    compacts.push(1)
    return w.compact() as never
  })
  on('turn.complete', ($, e) => ({ text: e.answer }) as never)
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
  return { w, files, toasts, logs, compacts, runs, clock }
}

const start = async ($: { session: { start: (e: never) => Promise<unknown> } }, clock: { settle: () => Promise<void> }) => {
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
  await clock.settle()
}
const turn = ($: { turn: { complete: (e: never) => Promise<unknown> } }) =>
  $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 't', reason: 'answer' } as never)
const measure = ($: { session: { measure: (e: never) => Promise<unknown> } }, percent: number) =>
  $.session.measure({ context: { window: 200_000, percent }, rateLimits: [], changed: ['context'] } as never)

const band = { plugin: 'mod-kit', surface: 'terminal', component: 'AbovePrompt', props: { hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 120, scroll: { offset: 0, bodyRows: 20 }, view: {} } } as never
type Ui = { findAll: (q: { type: string }) => Promise<{ text: string; children: unknown[] }[]>; find: (q: object) => Promise<{ props: Record<string, unknown> } | undefined> }
// The band as lines of text: each row's leaf Texts joined.
const shown = async (ui: Ui) => (await ui.findAll({ type: 'Text' })).filter(t => t.children.every(c => typeof c === 'string')).map(t => t.text).join('')

const PR_FAILING = JSON.stringify({ number: 636, state: 'OPEN', statusCheckRollup: [{ status: 'COMPLETED', conclusion: 'FAILURE' }] })
const PR_RUNNING = JSON.stringify({ number: 649, state: 'OPEN', statusCheckRollup: [{ status: 'IN_PROGRESS' }] })

test('nothing needing a look: the band is left to Claude Code', { plugins: [modKit] }, async ($, on) => {
  const { clock } = world(on)
  await start($, clock)
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('engine band')
  await ui.unmount()
})

test('a failing PR and unpushed commits make the amber line, most urgent first', withKit, async ($, on) => {
  const { clock } = world(on, { unpushed: '2\n', gh: { exitCode: 0, stdout: PR_FAILING, stderr: '' } })
  await start($, clock)
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('PR #636 checks failing | 2 unpushed commits')
  expect((await ui.find({ type: 'Text', text: 'PR #636 checks failing' }))?.props).toMatchObject({ color: 'warning' })
  await ui.unmount()
})

test('a refresh that fails keeps the PR as last read, with its age, never blank (L682)', withKit, async ($, on) => {
  const { w, clock } = world(on, { gh: { exitCode: 0, stdout: PR_RUNNING, stderr: '' } })
  await start($, clock)
  w.gh = { exitCode: 1, stdout: '', stderr: 'error connecting to api.github.com' }
  await clock.advance(12 * MIN)
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('PR #649 checks running, as of 12m ago')
  // Once a refresh succeeds again the age goes.
  w.gh = { exitCode: 0, stdout: PR_RUNNING, stderr: '' }
  await clock.advance(MIN)
  expect(await shown(ui as never)).toBe('PR #649 checks running')
  await ui.unmount()
})

test('a branch with no PR, or one whose checks pass, shows no PR item', withKit, async ($, on) => {
  const { w, clock } = world(on, { gh: { exitCode: 0, stdout: PR_FAILING, stderr: '' } })
  await start($, clock)
  w.gh = { exitCode: 1, stdout: '', stderr: 'no pull requests found for branch "x"' }
  await clock.advance(MIN)
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('engine band')
  w.gh = { exitCode: 0, stdout: JSON.stringify({ number: 1, state: 'OPEN', statusCheckRollup: [{ status: 'COMPLETED', conclusion: 'SUCCESS' }] }), stderr: '' }
  await clock.advance(MIN)
  expect(await shown(ui as never)).toBe('engine band')
  await ui.unmount()
})

test('a repository with no remote has nothing to push to, so no unpushed item', withKit, async ($, on) => {
  const { clock, runs } = world(on, { remotes: '', unpushed: '40\n' })
  await start($, clock)
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('engine band')
  expect(runs.some(r => r.includes('rev-list'))).toBe(false)
  await ui.unmount()
})

test('context above 70% brings the Compact row, which compacts when pressed, and goes once context falls', withKit, async ($, on) => {
  const { clock, compacts, toasts } = world(on)
  await start($, clock)
  await measure($, 74)
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('ctx 74% ')
  expect((await ui.find({ type: 'Button', key: 'status-bar:compact' }))?.props).toMatchObject({ label: 'Compact' })
  await (ui as unknown as { press: (t: object) => Promise<unknown> }).press({ key: 'status-bar:compact' })
  expect(compacts).toHaveLength(1)
  expect(toasts).toEqual([])
  await measure($, 20)
  expect(await shown(ui as never)).toBe('engine band')
  await ui.unmount()
})

test('a Compact that does not run says why in a toast, rather than nothing', withKit, async ($, on) => {
  const { clock, toasts, w } = world(on, { compact: () => ({ skip: 'Not enough messages to compact.' }) })
  await start($, clock)
  await measure($, 90)
  const ui = await $.ui.mount(band)
  const press = (ui as unknown as { press: (t: object) => Promise<unknown> }).press
  await press({ key: 'status-bar:compact' })
  expect(toasts).toEqual(['Compact did not run: Not enough messages to compact.'])
  w.compact = () => {
    throw new Error('compaction failed')
  }
  await press({ key: 'status-bar:compact' })
  // A compaction that throws is still said, with whatever reason reached the mod.
  expect(toasts).toHaveLength(2)
  expect(toasts[1]).toMatch(/^Compact did not run: \S/)
  await ui.unmount()
})

test('the amber line and the Compact row show together, amber line on top', withKit, async ($, on) => {
  const { clock } = world(on, { unpushed: '1\n' })
  await start($, clock)
  await measure($, 80)
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('1 unpushed commitctx 80% ')
  await ui.unmount()
})

test('a turn starts the hour of cache: the status line file says when it goes cold', withKit, async ($, on) => {
  const { files, clock } = world(on)
  await start($, clock)
  expect(JSON.parse(files[`${DIR}/s1.json`] as string)).toEqual({ v: 1, sessionId: 's1', cacheExpiresAt: null })
  await turn($)
  expect(JSON.parse(files[`${DIR}/s1.json`] as string)).toEqual({ v: 1, sessionId: 's1', cacheExpiresAt: T0 + HOUR })
})

test('5 minutes before the cache goes cold: one toast and the Compact row, gone once it is cold', withKit, async ($, on) => {
  const { toasts, clock, w } = world(on)
  w.usage = 30
  await start($, clock)
  await turn($)
  await clock.advance(54 * MIN)
  expect(toasts).toEqual([])
  await clock.advance(MIN)
  expect(toasts).toEqual(['The prompt cache goes cold in 5 minutes.'])
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('ctx 30% ')
  await clock.advance(2 * MIN)
  expect(toasts).toHaveLength(1)
  await clock.advance(4 * MIN)
  expect(await shown(ui as never)).toBe('engine band')
  await ui.unmount()
})

test('a clean end deletes the session file, so no stale cache is read for it', withKit, async ($, on) => {
  const { files, clock } = world(on)
  await start($, clock)
  await $.session.end({ sessionId: 's1', reason: 'exit' } as never)
  expect(files[`${DIR}/s1.json`]).toBeUndefined()
})

// The scope modes mod (#616) and away and home (#621), standing in: Bash commands become calls.
const modes: { name: string; register: Register } = {
  name: 'modes',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => {
      const arg = String((e as { command?: string }).command)
      try {
        await $.statusbar.setMode({ mode: (arg === 'off' ? null : arg) as never })
      } catch (err) {
        return { deny: `refused: ${String((err as Error).message ?? err)}` }
      }
      return { deny: 'done' }
    })
  },
}
const call = async ($: { tool: { call: (e: never) => Promise<unknown> } }, command: string) => {
  const r = (await $.tool.call({ tool: 'Bash', command } as never)) as { deny?: string; text?: string }
  return r.deny ?? r.text ?? ''
}

test('a scope mode leads the amber line in bold, shows alone, and clears', { plugins: [modKit, modes] }, async ($, on) => {
  const { clock } = world(on, { unpushed: '2\n' })
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  await start($, clock)
  expect(await call($, 'NO BUILD')).toBe('done')
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('NO BUILD | 2 unpushed commits')
  expect((await ui.find({ type: 'Text', text: 'NO BUILD' }))?.props).toMatchObject({ color: 'warning', bold: true })
  expect(await call($, 'off')).toBe('done')
  expect(await shown(ui as never)).toBe('2 unpushed commits')
  expect(await call($, 'LUNCH')).toMatch(/refused: .*"LUNCH"/)
  await ui.unmount()
})

// The job watcher (#611), standing in: its noun as its contract will be. Each stand in holds its
// answer inside register, since the kit loads a test plugin as a module of its own.
const watcher: { name: string; register: Register } = {
  name: 'job-watcher',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const list = async () => [
        { label: 'npm test', runMs: 60_000, kept: false, stuck: false },
        { label: 'dev server', runMs: 2 * 3_600_000 + 14 * 60_000, kept: true, stuck: false },
      ]
      return { ...built, jobs: { list } } as never
    })
  },
}
const brokenWatcher: { name: string; register: Register } = {
  name: 'job-watcher',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const list = async () => {
        throw new Error('registry unreadable')
      }
      return { ...built, jobs: { list } } as never
    })
  },
}

test('running and kept jobs from the job watcher join the line', { plugins: [modKit, watcher] }, async ($, on) => {
  const { clock } = world(on)
  await start($, clock)
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('1 job running | dev server kept 2h 14m')
  await ui.unmount()
})

test('no job watcher loaded is no job item, and no error', withKit, async ($, on) => {
  const { clock, logs, toasts } = world(on, { unpushed: '1\n' })
  await start($, clock)
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('1 unpushed commit')
  expect([...logs, ...toasts]).toEqual([])
  await ui.unmount()
})

test('a job watcher that fails to answer is named once in the debug log, and the rest still shows', { plugins: [modKit, brokenWatcher] }, async ($, on) => {
  const { clock, logs } = world(on, { unpushed: '1\n' })
  await start($, clock)
  await clock.advance(MIN)
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('1 unpushed commit')
  expect(logs.filter(l => /jobs could not be read.*registry unreadable/.test(l))).toHaveLength(1)
  await ui.unmount()
})
