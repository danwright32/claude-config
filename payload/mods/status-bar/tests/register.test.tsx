import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type { ModKitBandRow } from '../.claude-plugin/types/mod-kit/index.d.ts'
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
    const ORDER = ['needs-a-look', 'compact', 'steps', 'message']
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const rows = async () => (((await built.state.get({ plugin: 'mod-kit', key: 'band' })) as { value?: Row[] }).value ?? [])
      const modkit = {
        bandRow: async (row: ModKitBandRow) => {
          const now = (await rows()).filter(r => !(r.mod === row.mod && r.id === row.id))
          await built.state.set({ plugin: 'mod-kit', key: 'band' }, [...now, row] as never)
        },
        clearBandRow: async ({ mod, id }: { mod: string; id: string }) => {
          await built.state.set({ plugin: 'mod-kit', key: 'band' }, (await rows()).filter(r => !(r.mod === mod && r.id === id)) as never)
        },
        // The kit's other members, which these tests never reach: each refuses by name if one ever is.
        blocked: async () => { throw new Error("mod-kit's blocked is not stood in by these tests") },
        card: async () => { throw new Error("mod-kit's card is not stood in by these tests") },
        commands: async () => { throw new Error("mod-kit's commands is not stood in by these tests") },
        writes: async () => { throw new Error("mod-kit's writes is not stood in by these tests") },
        git: async () => { throw new Error("mod-kit's git is not stood in by these tests") },
        pipeline: async () => { throw new Error("mod-kit's pipeline is not stood in by these tests") },
        workingTree: async () => { throw new Error("mod-kit's workingTree is not stood in by these tests") },
        pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
        clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
        screen: async () => { throw new Error("mod-kit's screen is not stood in by these tests") },
      }
      return { ...built, modkit }
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
type Run = { exitCode: number; stdout: string; stderr: string }
type World = {
  remotes: string
  unpushed: string
  // git's answers when a test needs them to fail: an exit and its words, or 'throws' for a git
  // that never answered (timed out, could not start).
  remote: Run | 'throws' | null
  revList: Run | 'throws' | null
  gh: { exitCode: number; stdout: string; stderr: string }
  usage: number | undefined
  compact: () => unknown
  // A disk that will not take the facts file, or its folder: the reason, or empty when it will.
  writeFails: string
  mkdirFails: string
}
const world = (on: On, init: Partial<World> = {}) => {
  const w: World = {
    remotes: 'origin\n',
    unpushed: '0\n',
    remote: null,
    revList: null,
    gh: { exitCode: 1, stdout: '', stderr: 'no pull requests found for branch "x"' },
    usage: undefined,
    compact: () => ({ messages: [{ role: 'assistant', text: 'summary', toolUses: [] }] }),
    writeFails: '',
    mkdirFails: '',
    ...init,
  }
  // A Mac with no claude.ai login unless a test logs it in (#815).
  const files: Record<string, string> = { '/Users/x/.claude.json': '{}' }
  const toasts: string[] = []
  const logs: string[] = []
  const debug: string[] = []
  const compacts: number[] = []
  const runs: string[][] = []
  mock.env(on, { HOME: '/Users/x' })
  const clock = mock.clock(on, { now: T0 })
  on('fs.write', ($, e) => {
    // Refused with the disk's reason, which is how a failed write reaches the mod.
    if (w.writeFails) return { deny: w.writeFails } as never
    // A folder that could not be made has nothing to write into.
    if (w.mkdirFails) return { deny: `ENOENT: no such file or directory, open '${e.path}'` } as never
    files[e.path] = e.text
    return { value: undefined }
  })
  // The Mac's login file, which a test rewrites to log the Mac in to another account mid session.
  on('fs.exists', ($, e) => ({ value: e.path in files }) as never)
  on('fs.read', ($, e) => {
    const text = files[e.path]
    if (text === undefined) return { deny: `ENOENT: no such file or directory, open '${e.path}'` } as never
    return { value: text } as never
  })
  on('process.run', ($, e) => {
    runs.push([...e.argv])
    const [cmd, ...rest] = e.argv
    const r = (exitCode: number, stdout = '', stderr = '') => ({ value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false } })
    const answer = (got: Run | 'throws') => {
      if (got === 'throws') throw new Error('git did not answer within 10 seconds')
      return r(got.exitCode, got.stdout, got.stderr)
    }
    if (cmd === 'mkdir') return w.mkdirFails ? r(1, '', w.mkdirFails) : r(0)
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
    if (cmd === 'git' && rest.includes('remote')) return w.remote ? answer(w.remote) : r(0, w.remotes)
    if (cmd === 'git' && rest.includes('rev-list')) return w.revList ? answer(w.revList) : r(0, w.unpushed)
    if (cmd === 'gh') return r(w.gh.exitCode, w.gh.stdout, w.gh.stderr)
    return r(1, '', 'unexpected')
  })
  // Claude Code sending a model request: it answers at once with nothing.
  on('turn.step', async function* ($, e) {
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn', usage: null } as never
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
    const l = e as { text?: string; to?: string }
    ;(l.to === 'debug' ? debug : logs).push(String(l.text))
    return { value: undefined } as never
  })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine band</Text>
  })
  return { w, files, toasts, logs, debug, compacts, runs, clock }
}

const start = async ($: { session: { start: (e: never) => Promise<unknown> } }, clock: { settle: () => Promise<void> }) => {
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
  await clock.settle()
}
const turn = ($: { turn: { complete: (e: never) => Promise<unknown> } }) =>
  $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 't', reason: 'answer' } as never)
// One model request of a turn, main's unless a subagent's id is given, read to its end.
const step = async ($: unknown, clock: { settle: () => Promise<void> }, agentId?: string) => {
  const s = ($ as { turn: { step: (e: never) => AsyncIterable<unknown> } }).turn.step({ turnId: 't', index: 0, model: 'opus', messageCount: 2, ...(agentId ? { agentId } : {}) } as never)
  for await (const _chunk of s) {
    // Each chunk is the response arriving; nothing to read here.
  }
  await clock.settle()
}
const cacheIn = (files: Record<string, string>) => (JSON.parse(files[`${DIR}/s1.json`] as string) as { cacheExpiresAt: number | null }).cacheExpiresAt
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

test('a request starts the hour of cache: the status line file says when it goes cold', withKit, async ($, on) => {
  const { files, clock } = world(on)
  await start($, clock)
  expect(JSON.parse(files[`${DIR}/s1.json`] as string)).toEqual({ v: 1, sessionId: 's1', cacheExpiresAt: null, account: {} })
  await step($, clock)
  expect(JSON.parse(files[`${DIR}/s1.json`] as string)).toEqual({ v: 1, sessionId: 's1', cacheExpiresAt: T0 + HOUR, account: {} })
})

// #697: the spec's "1 hour prompt cache measured from the last request". Every request of a turn
// keeps the cache warm, so each one restarts the hour; a subagent's requests carry its own
// conversation, not this one, and the turn's end makes no request of its own.
test('each main request restarts the hour; a subagent request and the turn ending do not move it', withKit, async ($, on) => {
  const { files, clock } = world(on)
  await start($, clock)
  await step($, clock)
  await clock.advance(30 * MIN)
  await step($, clock)
  expect(cacheIn(files)).toBe(T0 + 30 * MIN + HOUR)
  await clock.advance(10 * MIN)
  await step($, clock, 'sub-1')
  expect(cacheIn(files)).toBe(T0 + 30 * MIN + HOUR)
  await turn($)
  await clock.settle()
  expect(cacheIn(files)).toBe(T0 + 30 * MIN + HOUR)
})

test('while a turn runs no cache toast or cache Compact row, however long since its last request; idle, both come on time', withKit, async ($, on) => {
  const { toasts, clock, w } = world(on)
  w.usage = 30
  await start($, clock)
  const ui = await $.ui.mount(band)
  // A first turn, then ten minutes later a second whose first request is followed by a tool that
  // runs for 56 minutes before the next one: the cache is within 5 minutes of its hour meanwhile.
  await step($, clock)
  await turn($)
  await clock.advance(10 * MIN)
  await step($, clock)
  await clock.advance(56 * MIN)
  expect(toasts).toEqual([])
  expect(await shown(ui as never)).toBe('engine band')
  await step($, clock)
  await turn($)
  await clock.advance(55 * MIN)
  expect(toasts).toEqual(['The prompt cache goes cold in 5 minutes.'])
  expect(await shown(ui as never)).toBe('ctx 30% ')
  await ui.unmount()
})

test('5 minutes before the cache goes cold: one toast and the Compact row, gone once it is cold', withKit, async ($, on) => {
  const { toasts, clock, w } = world(on)
  w.usage = 30
  await start($, clock)
  await step($, clock)
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

test('a session with no screen (claude -p) reads nothing and writes nothing: nobody sees a status line there', withKit, async ($, on) => {
  const { clock, runs, files } = world(on, { unpushed: '2\n' })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: false } as never)
  await clock.advance(5 * MIN)
  expect(runs.filter(r => r[0] === 'git' || r[0] === 'gh')).toEqual([])
  expect(Object.keys(files).filter(f => f !== '/Users/x/.claude.json')).toEqual([])
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
        if (arg.includes('+')) await $.statusbar.setModes({ modes: arg.split('+') as never })
        else await $.statusbar.setMode({ mode: (arg === 'off' ? null : arg) as never })
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

test('two modes at once both lead the line, in the order given; a bad or repeated one is refused', { plugins: [modKit, modes] }, async ($, on) => {
  const { clock } = world(on)
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  await start($, clock)
  expect(await call($, 'WINDING DOWN+AWAY')).toBe('done')
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('WINDING DOWN | AWAY')
  expect(await call($, 'AWAY+LUNCH')).toMatch(/refused: .*"LUNCH"/)
  expect(await call($, 'AWAY+AWAY')).toMatch(/refused: .*twice/)
  expect(await shown(ui as never)).toBe('WINDING DOWN | AWAY')
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
        { label: 'npm test', runMs: 60_000, kept: false, stuck: false, state: 'running', owner: null },
        { label: 'dev server', runMs: 2 * 3_600_000 + 14 * 60_000, kept: true, stuck: false, state: 'running', owner: null },
        { label: 'PR 776 rerun wait', runMs: 12 * 60_000, kept: true, stuck: false, state: 'waiting', owner: 'fix CI' },
      ]
      const agents = async () => [{ name: 'fix CI', quietMs: 34 * 60_000 }]
      return { ...built, jobs: { list, agents } }
    })
  },
}
// A watcher from before #784 and #759: no state, no owner, and no agents to ask.
const olderWatcher: { name: string; register: Register } = {
  name: 'job-watcher',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const list = async () => [{ label: 'npm test', runMs: 60_000, kept: false, stuck: true }]
      return { ...built, jobs: { list } }
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
      return { ...built, jobs: { list } }
    })
  },
}

test('running and kept jobs from the job watcher join the line', { plugins: [modKit, watcher] }, async ($, on) => {
  const { clock } = world(on)
  await start($, clock)
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('agent fix CI quiet 34m, left to Claude | 1 job running | dev server running 2h 14m | agent fix CI: PR 776 rerun wait waiting 12m')
  await ui.unmount()
})

test('a job watcher from before agents were watched still shows its jobs, with no error (#784)', { plugins: [modKit, olderWatcher] }, async ($, on) => {
  const { clock, logs, debug } = world(on)
  await start($, clock)
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('1 job not progressing, left to Claude')
  expect([...logs, ...debug.filter(l => /status-bar/.test(l))]).toEqual([])
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
  const { clock, debug } = world(on, { unpushed: '1\n' })
  await start($, clock)
  await clock.advance(MIN)
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('1 unpushed commit')
  expect(debug.filter(l => /jobs could not be read.*registry unreadable/.test(l))).toHaveLength(1)
  await ui.unmount()
})

// #697: pressing Compact replaces the conversation, so the hour of cache it was counting down
// belongs to a conversation that is gone: the clock starts again from nothing, as after a /clear,
// and a Compact row that showed for the cache goes with it.
test('a Compact that runs resets the cache clock: the row it showed for goes, and the status line shows no cache', withKit, async ($, on) => {
  const { files, clock, w, toasts } = world(on)
  w.usage = 30
  await start($, clock)
  await step($, clock)
  await turn($)
  await clock.advance(56 * MIN)
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('ctx 30% ')
  await (ui as unknown as { press: (t: object) => Promise<unknown> }).press({ key: 'status-bar:compact' })
  await clock.settle()
  expect(await shown(ui as never)).toBe('engine band')
  expect(cacheIn(files)).toBeNull()
  // The next request starts a fresh hour.
  await step($, clock)
  expect(cacheIn(files)).toBe(T0 + 56 * MIN + HOUR)
  expect(toasts).toEqual(['The prompt cache goes cold in 5 minutes.'])
  await ui.unmount()
})

const compactEvent = (trigger: string, extra: Record<string, unknown> = {}) =>
  ({ trigger, messages: [{ role: 'user', text: 'keep going', toolUses: [] }], ...extra }) as never

test('a compaction from anywhere else resets it too; one that is skipped, a subagent one or a precompute does not', withKit, async ($, on) => {
  const { files, clock, w } = world(on)
  await start($, clock)
  await step($, clock)
  // A subagent compacting its own transcript, and the engine working one out ahead of time, leave
  // this conversation as it is.
  await $.session.compact(compactEvent('auto', { agentId: 'sub-1' }))
  await $.session.compact(compactEvent('precompute'))
  await clock.settle()
  expect(cacheIn(files)).toBe(T0 + HOUR)
  w.compact = () => ({ skip: 'Not enough messages to compact.' })
  await $.session.compact(compactEvent('manual'))
  await clock.settle()
  expect(cacheIn(files)).toBe(T0 + HOUR)
  w.compact = () => ({ messages: [{ role: 'assistant', text: 'summary', toolUses: [] }] })
  await $.session.compact(compactEvent('manual'))
  await clock.settle()
  expect(cacheIn(files)).toBeNull()
})

// #697: an unpushed count that cannot be read is never a zero (L215). The commits keep their place
// with the age of the last reading, as a PR whose refresh failed does, and the failure is said once
// in the debug log. A folder that is no repository, or one with no commits yet, has nothing to push.
test('an unpushed count git cannot give keeps the last reading with its age, said once in the debug log', withKit, async ($, on) => {
  const { clock, w, debug, logs } = world(on, { unpushed: '2\n' })
  await start($, clock)
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('2 unpushed commits')
  w.revList = { exitCode: 128, stdout: '', stderr: 'fatal: unable to read refs' }
  await clock.advance(MIN)
  expect(await shown(ui as never)).toBe('2 unpushed commits, as of 1m ago')
  w.revList = 'throws'
  await clock.advance(MIN)
  expect(await shown(ui as never)).toBe('2 unpushed commits, as of 2m ago')
  w.remote = 'throws'
  await clock.advance(MIN)
  expect(await shown(ui as never)).toBe('2 unpushed commits, as of 3m ago')
  expect(debug.filter(l => /could not read the unpushed commits/.test(l))).toHaveLength(1)
  expect(debug.find(l => /could not read the unpushed commits/.test(l))).toContain('unable to read refs')
  expect(logs).toEqual([])
  // Readable again: the age goes, and a later failure is said again.
  w.revList = null
  w.remote = null
  w.unpushed = '1\n'
  await clock.advance(MIN)
  expect(await shown(ui as never)).toBe('1 unpushed commit')
  await ui.unmount()
})

test('an unpushed count never read at all shows no item, and is said in the debug log', withKit, async ($, on) => {
  const { clock, debug } = world(on, { revList: { exitCode: 1, stdout: '', stderr: 'fatal: bad object HEAD' } })
  await start($, clock)
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('engine band')
  expect(debug.filter(l => /could not read the unpushed commits.*bad object HEAD/.test(l))).toHaveLength(1)
  await ui.unmount()
})

test('a folder that is no repository, or a repository with no commits yet, has nothing to push and is no failure', withKit, async ($, on) => {
  const { clock, w, debug } = world(on, {
    unpushed: '3\n',
    remote: { exitCode: 128, stdout: '', stderr: 'fatal: not a git repository (or any of the parent directories): .git' },
  })
  await start($, clock)
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('engine band')
  w.remote = null
  w.revList = { exitCode: 128, stdout: '', stderr: "fatal: ambiguous argument 'HEAD': unknown revision or path not in the working tree." }
  await clock.advance(MIN)
  expect(await shown(ui as never)).toBe('engine band')
  expect(debug.filter(l => /unpushed/.test(l))).toEqual([])
  await ui.unmount()
})

// #815: the status line names the session's own account, the one its limits belong to, so the
// account is read from the Mac's login file once, at session start, and carried in the facts file.
// Another session logging the Mac in to another account (a Switch does) must not change this one's.
const LOGIN_FILE = '/Users/x/.claude.json'
const loginAs = (files: Record<string, string>, id: string, name: string, org: string) => {
  files[LOGIN_FILE] = JSON.stringify({ oauthAccount: { accountUuid: id, organizationUuid: `org-${id}`, displayName: name, emailAddress: `${id}@example.com`, organizationName: org }, other: 'kept out' })
}
const accountIn = (files: Record<string, string>) => (JSON.parse(files[`${DIR}/s1.json`] as string) as { account: unknown }).account

test("the facts file names the session's own account, read at its start, and keeps it when the Mac logs in elsewhere (#815)", withKit, async ($, on) => {
  const { files, clock } = world(on)
  loginAs(files, 'acct-1', 'Dan', 'Pennie')
  await start($, clock)
  const mine = { accountUuid: 'acct-1', organizationUuid: 'org-acct-1', displayName: 'Dan', emailAddress: 'acct-1@example.com', organizationName: 'Pennie' }
  expect(accountIn(files)).toEqual(mine)
  // Another session switches the Mac's login; this session's next facts write keeps its own account.
  loginAs(files, 'acct-2', 'Dan', 'Personal')
  await step($, clock)
  expect(cacheIn(files)).toBe(T0 + HOUR)
  expect(accountIn(files)).toEqual(mine)
})

test('a second session start in the same session, as a reload of the mod brings, keeps the account first read (#815)', withKit, async ($, on) => {
  const { files, clock } = world(on)
  loginAs(files, 'acct-1', 'Dan', 'Pennie')
  await start($, clock)
  loginAs(files, 'acct-2', 'Dan', 'Personal')
  await start($, clock)
  expect((accountIn(files) as { accountUuid: string }).accountUuid).toBe('acct-1')
})

test('a Mac with no login file at all is no account, not an unknown one (#815)', withKit, async ($, on) => {
  const { files, clock } = world(on)
  delete files[LOGIN_FILE]
  await start($, clock)
  expect(accountIn(files)).toEqual({})
})

test('a login file that cannot be read at session start is recorded as unknown, never as no login (#815)', withKit, async ($, on) => {
  const { files, clock } = world(on)
  files[LOGIN_FILE] = 'not json'
  await start($, clock)
  expect(accountIn(files)).toBeNull()
})

test('a Mac with no claude.ai login at session start (an API key) is recorded as no account (#815)', withKit, async ($, on) => {
  const { files, clock } = world(on)
  files[LOGIN_FILE] = '{}'
  await start($, clock)
  expect(accountIn(files)).toEqual({})
})

// #697: the facts file is the status line's only source for the cache. One that cannot be written
// (a full or unwritable disk) is said once, in the guards' note style, and nothing else stops: the
// refresh is still armed at session start, the band still updates and a turn still ends.
test('a facts file that cannot be written is said once, and the band and turns go on', withKit, async ($, on) => {
  const { clock, w, logs } = world(on, { writeFails: 'ENOSPC: no space left on device', unpushed: '0\n' })
  await start($, clock)
  expect(logs.filter(l => /Status bar couldn't save the cache time/.test(l))).toHaveLength(1)
  expect(logs[0]).toContain('no space left on device')
  // The one minute refresh was armed: a commit made since shows at the next tick.
  w.unpushed = '1\n'
  await clock.advance(MIN)
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('1 unpushed commit')
  await step($, clock)
  const ended = (await turn($)) as { text?: string }
  expect(ended.text).toBe('done')
  expect(logs.filter(l => /Status bar couldn't save the cache time/.test(l))).toHaveLength(1)
  await ui.unmount()
})

test('a facts folder that cannot be made is said, and the rest still runs', withKit, async ($, on) => {
  const { clock, w, logs, files } = world(on, { mkdirFails: 'mkdir: /Users/x/.claude/state: Permission denied', unpushed: '2\n' })
  await start($, clock)
  expect(logs.filter(l => /Status bar couldn't save the cache time.*Permission denied/.test(l))).toHaveLength(1)
  expect(Object.keys(files).filter(f => f !== '/Users/x/.claude.json')).toEqual([])
  const ui = await $.ui.mount(band)
  expect(await shown(ui as never)).toBe('2 unpushed commits')
  w.mkdirFails = ''
  await ui.unmount()
})
