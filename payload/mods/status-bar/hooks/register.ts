import type { EngineInterface, Register } from 'claude-code'
import type { StatusBar, StatusBarFacts, StatusBarMode } from '../types/index.d.ts'
import { CACHE_WARN_MS, checksOf, compactDue, lookParts, unpushedOf } from './facts.ts'
import type { Job, PrReading, RollupEntry } from './facts.ts'

// The status bar (#610), settled with Dan on 2026-10-04 (docs/mods-design.md "Status bar (#610)").
//
// Two surfaces, because a probe showed a mod's own status line is drawn as an amber warning notice:
// - the always-shown facts stay on the classic status line under the prompt, drawn by
//   statusline.sh beside this file, which reads what only this mod knows (when the prompt cache
//   goes cold) from one small file per session that this mod writes;
// - what needs a look (a scope mode, a failing or running PR, jobs, unpushed commits) is the amber
//   line in the band above the prompt, and the Compact row under it, both published through
//   mod-kit, which draws the band once for every mod.

const MIN = 60_000
const HOUR = 60 * MIN
// The prompt cache lives an hour from the last request (the spec's "1 hour prompt cache").
const CACHE_MS = HOUR
// How often git, the PR and the jobs are read again, and the cache warning is checked.
const TICK_MS = MIN
const MODES: readonly StatusBarMode[] = ['NO BUILD', 'WINDING DOWN', 'AWAY']
const SESSION_ID = /^[A-Za-z0-9-]+$/
const MOD = 'status-bar'

const modesRef = { plugin: 'status-bar', key: 'modes' } as const
const cacheRef = { plugin: 'status-bar', key: 'cacheExpiresAt' } as const

/** The job watcher's noun (#611) as its contract will be; it may not be loaded at all. */
type Jobs = { list: () => Promise<Job[]> }

let home: string | undefined
let startCwd = ''
let ticking = false
let interactive = false
// One reading at a time: a slow gh must not let the next tick start a second one beside it.
let reading = false
let pr: PrReading | null = null
let unpushed = 0
let jobs: Job[] = []
let jobsNoted = false
let context: number | undefined
let toastedFor: number | null = null
let shownLook = ''
let shownCompact = ''
let writtenId: string | undefined
let chain: Promise<unknown> = Promise.resolve()

const dirOf = (h: string) => `${h}/.claude/state/status-bar`
const serial = <T>(work: () => Promise<T>): Promise<T> => {
  const next = chain.then(work)
  chain = next.catch(() => undefined)
  return next
}

const isJob = (j: unknown): j is Job => {
  const o = j as Job
  return !!o && typeof o.label === 'string' && typeof o.runMs === 'number' && typeof o.kept === 'boolean'
}

// This session's facts for the status line script, written whole and moved into place so the
// script never reads half a file. After a /clear the session id changes, and the old file goes.
const writeFacts = async ($: EngineInterface) => {
  if (!home) return
  const id = await $.session.id()
  if (!SESSION_ID.test(id)) return
  const cache = (await $.state.get(cacheRef)).value ?? null
  const facts: StatusBarFacts = { v: 1, sessionId: id, cacheExpiresAt: cache }
  const tmp = `${dirOf(home)}/.${id}.json.tmp`
  await $.fs.write(tmp, JSON.stringify(facts))
  const mv = await $.process.run(['mv', '-f', tmp, `${dirOf(home)}/${id}.json`])
  if (mv.exitCode !== 0) {
    $.ui.log(`status-bar: could not save the status line's facts: ${mv.stderr.trim()}`, { to: 'debug' })
    return
  }
  if (writtenId && writtenId !== id) await $.process.run(['rm', '-f', `${dirOf(home)}/${writtenId}.json`]).catch(() => undefined)
  writtenId = id
}

const readUnpushed = async ($: EngineInterface, root: string): Promise<number> => {
  try {
    // No remote is nothing to push to: every commit would otherwise count as unpushed.
    const rem = await $.process.run(['git', '-C', root, 'remote'], { timeoutMs: 10_000 })
    if (rem.exitCode !== 0 || !rem.stdout.trim()) return 0
    const c = await $.process.run(['git', '-C', root, 'rev-list', '--count', 'HEAD', '--not', '--remotes'], { timeoutMs: 10_000 })
    return (c.exitCode === 0 ? unpushedOf(c.stdout) : undefined) ?? 0
  } catch {
    return 0
  }
}

// The branch's PR. A refresh that fails keeps what was last read, marked stale with its age, never
// blank (L682); only gh saying there is no PR clears it.
const readPr = async ($: EngineInterface, root: string) => {
  const now = await $.clock.now()
  try {
    const r = await $.process.run(['gh', 'pr', 'view', '--json', 'number,state,statusCheckRollup'], { cwd: root, timeoutMs: 20_000 })
    if (r.exitCode === 0) {
      const j = JSON.parse(r.stdout) as { number?: number; state?: string; statusCheckRollup?: RollupEntry[] }
      if (typeof j.number !== 'number') throw new Error('no PR number in gh output')
      pr = j.state === 'OPEN' ? { number: j.number, checks: checksOf(j.statusCheckRollup ?? []), readAt: now, isStale: false } : null
      return
    }
    if (/no pull requests found/i.test(r.stderr)) {
      pr = null
      return
    }
    throw new Error(r.stderr.trim() || `gh exited ${r.exitCode}`)
  } catch {
    if (pr) pr = { ...pr, isStale: true }
  }
}

// The job watcher may not be loaded: that is no job item, never an error. One that is loaded and
// fails to answer is named once in the debug log.
const readJobs = async ($: EngineInterface) => {
  try {
    const list = await ($ as unknown as { jobs: Jobs }).jobs.list()
    jobs = Array.isArray(list) ? list.filter(isJob) : []
    jobsNoted = false
  } catch (err) {
    jobs = []
    const msg = String((err as Error)?.message ?? err)
    const isAbsent = err instanceof TypeError && /undefined|not a function|null/.test(msg)
    if (!isAbsent && !jobsNoted) {
      jobsNoted = true
      $.ui.log(`status-bar: the job watcher's jobs could not be read, so no job shows: ${msg}`, { to: 'debug' })
    }
  }
}

// How the band is reached, made in engine.create from the built $ (which may be used there, never
// passed out), so a mode set by another mod through $.statusbar redraws the band as a hook does.
type BandIo = {
  now: () => Promise<number>
  modes: () => Promise<StatusBarMode[]>
  cache: () => Promise<number | null>
  show: (row: { mod: string; id: string; slot: 'needs-a-look' | 'compact'; lines: unknown[][] }) => Promise<void>
  clear: (id: string) => Promise<void>
  log: (text: string) => void
}
let io: BandIo | undefined

// What the band shows from this mod: the amber line and the Compact row, each published only when
// it changed, and cleared when there is nothing to show.
const publish = () =>
  serial(async () => {
    if (!io) return
    const now = await io.now()
    const cache = await io.cache()
    const look = lookParts({ modes: await io.modes(), pr, jobs, unpushed, now })
    const due = compactDue({ contextPercent: context, cacheExpiresAt: cache, now })
    const compact = due
      ? [...(context === undefined ? [] : [{ text: `ctx ${Math.round(context)}% `, color: 'warning' }]), { button: 'compact', label: 'Compact' }]
      : []
    try {
      const lookKey = JSON.stringify(look)
      if (lookKey !== shownLook) {
        if (look.length) await io.show({ mod: MOD, id: 'look', slot: 'needs-a-look', lines: [look] })
        else await io.clear('look')
        shownLook = lookKey
      }
      const compactKey = JSON.stringify(compact)
      if (compactKey !== shownCompact) {
        if (compact.length) await io.show({ mod: MOD, id: 'compact', slot: 'compact', lines: [compact] })
        else await io.clear('compact')
        shownCompact = compactKey
      }
    } catch (err) {
      io.log(`status-bar: the band could not be updated: ${String((err as Error)?.message ?? err)}`)
    }
  })

// One toast per hour of cache, 5 minutes before it goes cold (the spec).
const warnCache = async ($: EngineInterface) => {
  const cache = (await $.state.get(cacheRef)).value ?? null
  if (cache === null || toastedFor === cache) return
  const left = cache - (await $.clock.now())
  if (left <= 0 || left > CACHE_WARN_MS) return
  toastedFor = cache
  const m = Math.ceil(left / MIN)
  $.ui.toast(`The prompt cache goes cold in ${m} ${m === 1 ? 'minute' : 'minutes'}.`)
}

const tick = async ($: EngineInterface) => {
  if (reading) return
  reading = true
  try {
    await read($)
  } finally {
    reading = false
  }
}

const read = async ($: EngineInterface) => {
  const root = await $.session.root().catch(() => startCwd)
  unpushed = await readUnpushed($, root)
  await readPr($, root)
  await readJobs($)
  try {
    const p = (await $.session.usage()).context.percent
    if (typeof p === 'number') context = p
  } catch {
    // The next measurement brings it.
  }
  await warnCache($)
  await publish()
  if ((await $.session.id()) !== writtenId) await writeFacts($)
}

export const register: Register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    io = {
      now: () => built.clock.now(),
      modes: async () => (await built.state.get(modesRef)).value ?? [],
      cache: async () => (await built.state.get(cacheRef)).value ?? null,
      show: row => built.modkit.bandRow(row as never),
      clear: id => built.modkit.clearBandRow({ mod: MOD, id }),
      log: text => built.ui.log(text, { to: 'debug' }),
    }
    const setModes: StatusBar['setModes'] = async ({ modes }) => {
      if (!Array.isArray(modes)) throw new Error('modes must be a list of scope modes')
      for (const m of modes) if (!MODES.includes(m)) throw new Error(`"${String(m)}" is not a scope mode; the modes are ${MODES.join(', ')}`)
      if (new Set(modes).size !== modes.length) throw new Error(`a scope mode is named twice in ${modes.join(', ')}`)
      await built.state.set(modesRef, [...modes])
      await publish()
    }
    const statusbar: StatusBar = {
      setModes,
      setMode: ({ mode }) => setModes({ modes: mode === null ? [] : [mode] }),
    }
    return { ...built, statusbar }
  })

  on('session.start', async ($, e, next) => {
    // A session with no screen (claude -p, a hook's detached run) shows no status line or band, so
    // it reads no git or GitHub and writes no file.
    if (!e.isInteractive) return next(e)
    interactive = true
    startCwd = e.cwd
    home = await $.env.get('HOME')
    if (home) {
      await $.process.run(['mkdir', '-p', dirOf(home)])
      await writeFacts($)
    } else {
      $.ui.log("Status bar couldn't find the home folder, so the status line can't show the cache time.")
    }
    if (!ticking) {
      ticking = true
      $.clock.every(TICK_MS, () => void tick($))
    }
    // The first reading runs after the session is ready rather than holding up its start.
    $.clock.after(0, () => void tick($))
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (interactive && e.agentId === undefined) {
      await $.state.set(cacheRef, (await $.clock.now()) + CACHE_MS)
      await writeFacts($)
      await publish()
      // A turn may have committed or pushed: read git again now rather than at the next tick.
      $.clock.after(0, () => void tick($))
    }
    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    if (typeof e.context.percent === 'number') context = e.context.percent
    await publish()
    return next(e)
  })

  on('ui.press', { plugin: 'mod-kit', element: 'status-bar:compact' }, async ($, e) => {
    try {
      const r = (await $.session.compact()) as { skip?: string }
      if (r && typeof r.skip === 'string') $.ui.toast(`Compact did not run: ${r.skip}`)
    } catch (err) {
      $.ui.toast(`Compact did not run: ${String((err as Error)?.message ?? err)}`)
    }
    return { element: e.element }
  })

  on('session.end', async ($, e, next) => {
    if (home && SESSION_ID.test(e.sessionId)) {
      await $.process.run(['rm', '-f', `${dirOf(home)}/${e.sessionId}.json`]).catch(() => undefined)
      if (writtenId === e.sessionId) writtenId = undefined
    }
    // A /clear starts a new conversation, whose cache starts cold.
    if (e.reason === 'clear') {
      await $.state.set(cacheRef, null)
      toastedFor = null
    }
    return next(e)
  })
}
