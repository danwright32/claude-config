import type { EngineInterface, Register } from 'claude-code'
import type { StatusBar, StatusBarAccount, StatusBarFacts, StatusBarMode } from '../types/index.d.ts'
import { CACHE_WARN_MS, checksOf, compactDue, lookParts, unpushedOf } from './facts.ts'
import type { Job, PrReading, QuietAgent, RollupEntry, UnpushedReading } from './facts.ts'

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
// How often GitHub is asked about the branch's PR when nothing on it is moving: no PR, or one whose
// checks have finished (#1014). Each ask spends a point of the GraphQL allowance every session on
// the Mac shares, 5,000 an hour, and asking every tick cost each open session 60 points an hour
// whether or not anything could change; on 2026-10-09 the open sessions' status bars were about a fifth of
// this Mac's measured spend. Running checks are still read every tick, and a turn's end always asks
// (it may have pushed or opened a PR), so what waits up to this long is only a change made from
// outside the session: a PR opened, merged or re-run elsewhere.
const PR_IDLE_MS = 10 * MIN
const MODES: readonly StatusBarMode[] = ['ASLEEP', 'NO BUILD', 'WINDING DOWN', 'AWAY']
const SESSION_ID = /^[A-Za-z0-9-]+$/
const MOD = 'status-bar'

const modesRef = { plugin: 'status-bar', key: 'modes' } as const
const cacheRef = { plugin: 'status-bar', key: 'cacheExpiresAt' } as const
const accountRef = { plugin: 'status-bar', key: 'account' } as const

/** The job watcher's noun (#611) as its contract will be; it may not be loaded at all. */
type Jobs = { list: () => Promise<Job[]>; agents?: () => Promise<QuietAgent[]> }

let home: string | undefined
let startCwd = ''
let ticking = false
let interactive = false
// One reading at a time: a slow gh must not let the next tick start a second one beside it.
let reading = false
let pr: PrReading | null = null
// When GitHub last ANSWERED about the PR (#1014). An ask that fails sets nothing, so after a failed
// ask (idle or a turn end's forced one) the next comes at the first tick at least PR_IDLE_MS after
// the last ANSWER: the very next tick when that much has already passed, and otherwise once it
// has, or on every tick while that answer had checks running (prDue). Until then the band keeps
// that answer marked stale with its age (L682), never blank.
let prAskedAt: number | undefined
let unpushed: UnpushedReading | null = null
let unpushedNoted = false
let jobs: Job[] = []
let jobsNoted = false
let agents: QuietAgent[] = []
let agentsNoted = false
let context: number | undefined
let toastedFor: number | null = null
let shownLook = ''
let shownCompact = ''
let writtenId: string | undefined
let toldSave = false
// Whether a main turn is running: from its first request to its end. Every request it makes keeps
// the cache warm, so the cache warning and a cache Compact row wait for it to end (#697).
let turnRunning = false
let chain: Promise<unknown> = Promise.resolve()

const msg = (err: unknown) => String((err as Error)?.message ?? err)
const dirOf = (h: string) => `${h}/.claude/state/status-bar`
const serial = <T>(work: () => Promise<T>): Promise<T> => {
  const next = chain.then(work)
  chain = next.catch(() => undefined)
  return next
}

const isQuietAgent = (a: unknown): a is QuietAgent => {
  const o = a as QuietAgent
  return !!o && typeof o.name === 'string' && typeof o.quietMs === 'number'
}
const isJob = (j: unknown): j is Job => {
  const o = j as Job
  return !!o && typeof o.label === 'string' && typeof o.runMs === 'number' && typeof o.kept === 'boolean'
}

// The facts file is the status line's only source for the cache time, so one that cannot be saved
// is said, once a session, in the guards' note style: the status line then shows an old or unknown
// cache time (#697).
const cannotSave = ($: EngineInterface, why: string) => {
  if (toldSave) return
  toldSave = true
  $.ui.log(`Status bar couldn't save the cache time for the status line, so it may show it out of date: ${why}`)
}

// This session's facts for the status line script, written whole and moved into place so the
// script never reads half a file. After a /clear the session id changes, and the old file goes. A
// write that fails (an unwritable or full disk) is said, never thrown: nothing after it stops, not
// the refresh being armed at session start, the band, or a turn ending (#697).
const writeFacts = async ($: EngineInterface) => {
  if (!home) return
  try {
    const id = await $.session.id()
    if (!SESSION_ID.test(id)) return
    const cache = (await $.state.get(cacheRef)).value ?? null
    const account = (await $.state.get(accountRef)).value ?? null
    const facts: StatusBarFacts = { v: 1, sessionId: id, cacheExpiresAt: cache, account }
    const tmp = `${dirOf(home)}/.${id}.json.tmp`
    await $.fs.write(tmp, JSON.stringify(facts))
    const mv = await $.process.run(['mv', '-f', tmp, `${dirOf(home)}/${id}.json`])
    if (mv.exitCode !== 0) throw new Error(mv.stderr.trim() || `mv exited ${mv.exitCode}`)
    if (writtenId && writtenId !== id) await $.process.run(['rm', '-f', `${dirOf(home)}/${writtenId}.json`]).catch(() => undefined)
    writtenId = id
  } catch (err) {
    cannotSave($, msg(err))
  }
}

// The account this session runs on, the one its limits belong to (#815): the Mac's login as it
// stands at session start. Read once, here, because the login file names whatever the Mac is logged
// in to NOW, which another session's Switch changes under this one. No login at all (an API key) is
// an empty record; a file that cannot be read is null, said as unknown, never as no login (L11).
const readAccount = async ($: EngineInterface, h: string): Promise<StatusBarAccount | null> => {
  try {
    // No login file at all is no claude.ai login, like an empty one; only a file that is there and
    // cannot be read or parsed is unknown.
    if (!(await $.fs.exists(`${h}/.claude.json`))) return {}
    const o = (JSON.parse(await $.fs.read(`${h}/.claude.json`)) as { oauthAccount?: Record<string, unknown> }).oauthAccount
    const out: StatusBarAccount = {}
    if (!o || typeof o !== 'object') return out
    for (const k of ['accountUuid', 'organizationUuid', 'displayName', 'emailAddress', 'organizationName'] as const) {
      const v = o[k]
      if (typeof v === 'string') out[k] = v
    }
    return out
  } catch (err) {
    $.ui.log(`status-bar: ~/.claude.json could not be read at session start, so the status line shows this session's account as unknown: ${msg(err)}`, { to: 'debug' })
    return null
  }
}

// The commits not pushed anywhere. No repository, no remote, or no commit yet is nothing to push:
// a reading of zero. Anything else git cannot answer (an error, a timeout) is no reading: never a
// zero, which would drop the commits off the line (L215, #697).
const countUnpushed = async ($: EngineInterface, root: string): Promise<{ count: number } | { unreadable: string }> => {
  try {
    const rem = await $.process.run(['git', '-C', root, 'remote'], { timeoutMs: 10_000 })
    if (rem.exitCode !== 0) {
      if (/not a git repository/i.test(rem.stderr)) return { count: 0 }
      return { unreadable: rem.stderr.trim() || `git remote exited ${rem.exitCode}` }
    }
    // No remote is nothing to push to: every commit would otherwise count as unpushed.
    if (!rem.stdout.trim()) return { count: 0 }
    const c = await $.process.run(['git', '-C', root, 'rev-list', '--count', 'HEAD', '--not', '--remotes'], { timeoutMs: 10_000 })
    if (c.exitCode === 0) {
      const n = unpushedOf(c.stdout)
      return n === undefined ? { unreadable: `git gave no count (${c.stdout.trim() || 'nothing'})` } : { count: n }
    }
    // A repository with no commit yet has no HEAD, and nothing to push.
    if (/unknown revision|ambiguous argument 'HEAD'/i.test(c.stderr)) return { count: 0 }
    return { unreadable: c.stderr.trim() || `git rev-list exited ${c.exitCode}` }
  } catch (err) {
    return { unreadable: msg(err) }
  }
}

// A refresh that fails keeps what was last read, marked stale with its age, as the PR does (L682),
// and says so once in the debug log until a reading comes again.
const readUnpushed = async ($: EngineInterface, root: string) => {
  const now = await $.clock.now()
  const got = await countUnpushed($, root)
  if ('count' in got) {
    unpushed = { count: got.count, readAt: now, isStale: false }
    unpushedNoted = false
    return
  }
  if (unpushed) unpushed = { ...unpushed, isStale: true }
  if (unpushedNoted) return
  unpushedNoted = true
  const kept = unpushed ? 'so the last count stays, with its age' : 'so none is shown'
  $.ui.log(`status-bar: could not read the unpushed commits, ${kept}: ${got.unreadable}`, { to: 'debug' })
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
      prAskedAt = now
      return
    }
    if (/no pull requests found/i.test(r.stderr)) {
      pr = null
      prAskedAt = now
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
  // The noun is called in place each time, as the engine requires, never held in a variable.
  try {
    const list = await ($ as unknown as { jobs: Jobs }).jobs.list()
    jobs = Array.isArray(list) ? list.filter(isJob) : []
    jobsNoted = false
  } catch (err) {
    jobs = []
    agents = []
    const msg = String((err as Error)?.message ?? err)
    const isAbsent = err instanceof TypeError && /undefined|not a function|null/.test(msg)
    if (!isAbsent && !jobsNoted) {
      jobsNoted = true
      $.ui.log(`status-bar: the job watcher's jobs could not be read, so no job shows: ${msg}`, { to: 'debug' })
    }
    return
  }
  // The quiet agents (#759), in a failure boundary of their own so the jobs still show (L73): a
  // watcher from before them has no agents to ask, which is none.
  try {
    const quiet = await ($ as unknown as { jobs: Required<Jobs> }).jobs.agents()
    agents = Array.isArray(quiet) ? quiet.filter(isQuietAgent) : []
    agentsNoted = false
  } catch (err) {
    agents = []
    const msg = String((err as Error)?.message ?? err)
    const isAbsent = err instanceof TypeError && /undefined|not a function|null/.test(msg)
    if (!isAbsent && !agentsNoted) {
      agentsNoted = true
      $.ui.log(`status-bar: the job watcher's quiet agents could not be read, so none shows: ${msg}`, { to: 'debug' })
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
    const look = lookParts({ modes: await io.modes(), pr, jobs, agents, unpushed, now })
    const due = compactDue({ contextPercent: context, cacheExpiresAt: cache, now, isWorking: turnRunning })
    const compact = due
      ? [...(context === undefined ? [] : [{ text: `ctx ${Math.round(context)}% `, color: 'warning' }]), { button: 'compact', label: 'Compact', instead: [{ text: 'type: ', dim: true }, { text: '/compact' }] }]
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

// One toast per hour of cache, 5 minutes before it goes cold (the spec). Not while a main turn runs:
// its next request warms the cache again, and Dan has nothing to do about it then (#697).
const warnCache = async ($: EngineInterface) => {
  if (turnRunning) return
  const cache = (await $.state.get(cacheRef)).value ?? null
  if (cache === null || toastedFor === cache) return
  const left = cache - (await $.clock.now())
  if (left <= 0 || left > CACHE_WARN_MS) return
  toastedFor = cache
  const m = Math.ceil(left / MIN)
  $.ui.toast(`The prompt cache goes cold in ${m} ${m === 1 ? 'minute' : 'minutes'}.`)
}

// Whether this reading asks GitHub about the PR (#1014): always when told to (a turn just ended),
// on the first reading, and while the last answer had checks running; otherwise once PR_IDLE_MS has
// passed since GitHub last answered.
const prDue = (now: number, force: boolean): boolean =>
  force || prAskedAt === undefined || pr?.checks === 'running' || now - prAskedAt >= PR_IDLE_MS
// A turn's end that asked while a reading was already running: kept for the next reading rather
// than dropped with the tick, so that ask still happens.
let prForced = false

const tick = async ($: EngineInterface, force = false) => {
  if (force) prForced = true
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
  await readUnpushed($, root)
  if (prDue(await $.clock.now(), prForced)) {
    prForced = false
    await readPr($, root)
  }
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

// The cache clock moved (a request started a new hour, or a compaction replaced the conversation):
// the status line's file and the band follow, off the path of whatever moved it.
const cacheMoved = async ($: EngineInterface) => {
  await writeFacts($)
  await publish().catch(err => $.ui.log(`status-bar: the band could not be updated: ${msg(err)}`, { to: 'debug' }))
}

// A compaction replaces the conversation, so the hour being counted belonged to one that is gone:
// the clock starts again from nothing, as after a /clear, and a Compact row shown for the cache
// goes with it (#697).
const cacheReplaced = async ($: EngineInterface) => {
  await $.state.set(cacheRef, null)
  toastedFor = null
  await cacheMoved($)
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
      // Read once a session: a second session.start in the same process (a reload of the mod) keeps
      // the account first read, since the login file may name another session's Switch by then.
      if ((await $.state.get(accountRef)).value === undefined) await $.state.set(accountRef, await readAccount($, home))
      const made = await $.process.run(['mkdir', '-p', dirOf(home)]).catch(err => ({ exitCode: -1, stderr: msg(err) }))
      if (made.exitCode === 0) await writeFacts($)
      else cannotSave($, made.stderr.trim() || `mkdir exited ${made.exitCode}`)
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

  // The hour of cache starts again at every main request (the spec's "measured from the last
  // request", #697), so a long turn keeps it warm on the status line as each of its requests really
  // does. A subagent's request carries its own conversation, not this one. The file and the band
  // follow off the request's path, so a slow disk never holds a request up.
  on('turn.step', async function* ($, e, next) {
    if (interactive && e.agentId === undefined) {
      turnRunning = true
      try {
        await $.state.set(cacheRef, (await $.clock.now()) + CACHE_MS)
        $.clock.after(0, () => void cacheMoved($))
      } catch (err) {
        $.ui.log(`status-bar: could not restart the cache clock: ${msg(err)}`, { to: 'debug' })
      }
    }
    return yield* next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (interactive && e.agentId === undefined) {
      turnRunning = false
      // The turn's end makes no request, so the cache clock stays where its last request put it;
      // only the band changes, since a cache warning waits for the turn to end.
      await publish().catch(err => $.ui.log(`status-bar: the band could not be updated: ${msg(err)}`, { to: 'debug' }))
      // A turn may have committed, pushed or opened a PR: read git and ask about the PR now rather
      // than at the next tick, however recently it was last asked (#1014).
      $.clock.after(0, () => void tick($, true))
    }
    return next(e)
  })

  // Any compaction of this conversation (the Compact row, /compact, the threshold) resets the cache
  // clock. A subagent compacting its own transcript, a precompute that installs nothing, and a
  // compaction that was skipped leave this conversation as it is.
  on('session.compact', async ($, e, next) => {
    const r = await next(e)
    const skipped = typeof (r as { skip?: unknown } | undefined)?.skip === 'string'
    if (interactive && e.agentId === undefined && e.trigger !== 'precompute' && !skipped) {
      await cacheReplaced($).catch(err => $.ui.log(`status-bar: could not reset the cache clock after compacting: ${msg(err)}`, { to: 'debug' }))
    }
    return r
  })

  on('session.measure', async ($, e, next) => {
    if (typeof e.context.percent === 'number') context = e.context.percent
    await publish()
    return next(e)
  })

  // Compact, pressed by a click or by /press (#939): mod-kit raises both as modkit.press.
  on('modkit.press', ($, e, next) => {
    if (e.element !== 'status-bar:compact') return next(e)
    // Taken at once and done just after: a noun's call is cut off at 10 s (#744), and compacting
    // runs a model call that takes longer.
    $.clock.after(0, () => {
      void compactNow($).catch(err => $.ui.toast(`Compact did not run: ${msg(err)}`))
    })
    return { value: { isAnswered: true } }
  })

  on('session.end', async ($, e, next) => {
    if (home && SESSION_ID.test(e.sessionId)) {
      await $.process.run(['rm', '-f', `${dirOf(home)}/${e.sessionId}.json`]).catch(() => undefined)
      if (writtenId === e.sessionId) writtenId = undefined
    }
    // A /clear starts a new conversation, whose cache starts cold, and ends any turn.
    if (e.reason === 'clear') {
      await $.state.set(cacheRef, null)
      toastedFor = null
      turnRunning = false
    }
    return next(e)
  })
}

// What Compact does, pressed or typed (#939).
const compactNow = async ($: EngineInterface) => {
  let r: { skip?: string } | undefined
  try {
    r = (await $.session.compact()) as { skip?: string }
  } catch (err) {
    $.ui.toast(`Compact did not run: ${msg(err)}`)
    return
  }
  if (r && typeof r.skip === 'string') {
    $.ui.toast(`Compact did not run: ${r.skip}`)
    return
  }
  // Reset here as well: this mod's own call does not pass through its own session.compact hook
  // (the engine skips the calling plugin, measured in the tests), and resetting twice changes nothing.
  await cacheReplaced($).catch(err => $.ui.log(`status-bar: could not reset the cache clock after compacting: ${msg(err)}`, { to: 'debug' }))
}
