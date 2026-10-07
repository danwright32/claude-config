import type { EngineInterface, Register } from 'claude-code'
import type { Sessions, SessionsList, SessionsRecord } from '../types/index.d.ts'
import { remember } from './bounded.ts'

// ONE record of the open sessions on this Mac, read by the collision guard (#605), the background
// job watcher (#611) and the goal tracker (#612), which the milestone said must not each build
// their own (#612's consolidation note, L613). One file per session, so no two sessions ever write
// the same file; written whole and moved into place, so a reader never sees half of one.
//
// Settled with Dan on 2026-10-03: a session silent for five minutes counts as closed, and a
// session's requests are read from its own transcript when needed, never copied here.

const DEAD_MS = 5 * 60_000
// Decided with Dan (2026-10-04, #633): a record is kept 7 days after its session ended.
const KEEP_MS = 7 * 24 * 60 * 60_000
const BEAT_MS = 60_000
const MAX_EDITS = 500

let home: string | undefined
let rec: SessionsRecord | undefined
let chain: Promise<unknown> = Promise.resolve()
// One beat per module load, however many times session.start fires on it (a hot reload).
let beating = false

const dirOf = (h: string) => `${h}/.claude/state/sessions`
const projectsOf = (h: string) => `${h}/.claude/projects`
// Claude Code files a session's transcript under its starting folder, every character but a
// letter, a digit or a dash turned into a dash (measured against all 1451 transcripts on this Mac,
// 2026-10-04: the one miss was a session that changed folder, found by its id instead).
const folderOf = (cwd: string) => cwd.replace(/[^A-Za-z0-9-]/g, '-')

// The one writer of this session's record, made inside engine.create (the engine allows the built
// $ to be used there, not passed out) and used by every hook. Every write goes through one queue, so
// two hooks updating the record at once cannot interleave and lose either change (assume it runs
// twice).
let persist: (() => Promise<void>) | undefined
const enqueue = (work: () => Promise<void>): Promise<void> => {
  const next = chain.then(work)
  chain = next.catch(() => undefined)
  return next
}

// After a /clear or a resume (session.end with that reason) the process goes on under a new session
// id and no session.start fires (#735). From then on the next thing to touch the record makes the
// new conversation's own, inside the queue: the /clear's (or the /resume's) own look once its
// command has run, a write, or a read of the list. Never left to the next beat, which for up to a
// minute kept the new conversation out of /goals and let the goal tracker and the job watcher write
// into the record session.end had just closed. A write queued before the session ended stays on the old record. The
// beat still makes it for an id that changed with no session.end seen.
//
// Only a look that comes whatever happened, the command's or the beat's, settles that a
// session end kept its id (a resume of this same session), after which writes stop asking (#739).
// A write or a read of the list can come while the /clear is still under way and find the old id,
// so its look never settles it. A look that cannot read the id fails no write: what the mods write
// meanwhile is held, and goes on the record the next look that reads the id names, never on the
// record session.end just closed, which no reader counts as open. What that costs: until the id
// reads, other sessions do not see those writes, and if it never reads they never land, which the
// debug log says once (lessons review of #739).
//
// Measured (#751 item 1, L82): Claude Code has switched the id by the time the /clear's command has
// run. A real /clear in an interactive `claude --debug` session on Claude Code 2.1.292, on
// Daniels-MacBook-Pro-2 on 2026-10-07, with the managed settings file from #876 in place (so the
// built in security default was not seated and did not bypass the mod), logged:
//   session-registry: once the /clear had run, the session id read 22710d14-5752-45bc-9bb6-51fd4f045c46;
//   session.end had closed 28ec71a1-bfdd-470d-835f-6a7bc11c5f06, so the id had already switched.
// Every look once a /clear or a /resume has run still says in the debug log which id it saw against
// the id session.end closed, so a later Claude Code that reverses the order shows there. Should the
// command ever finish first, its look settles on the old id and reopens that record (as a resume
// would), the new conversation's writes land there until the beat sees the new id, and the beat then
// closes the old record and makes the new one: the #735 defect for that minute, never longer.
let expectNew = false
// Whether a failed id lookup has been said in the debug log since the last one that worked.
let toldNoId = false

// A change to the record: a file edited, or a key another mod keeps on it.
type Change = { edit: string } | { key: string; value: unknown }
type Changed = Pick<SessionsRecord, 'edits' | 'extra'>
const apply = (r: Changed, c: Change) => {
  if ('edit' in c) r.edits = [...r.edits.filter(p => p !== c.edit), c.edit].slice(-MAX_EDITS)
  else r.extra = { ...r.extra, [c.key]: c.value }
}
// The writes held while the id cannot be read, gathered as the record gathers them, so never larger
// than one; put on a record in the same order they would have reached it.
let held: Changed | undefined
const release = (r: SessionsRecord): boolean => {
  if (!held) return false
  for (const edit of held.edits) apply(r, { edit })
  for (const [key, value] of Object.entries(held.extra)) apply(r, { key, value })
  held = undefined
  return true
}

// Made inside engine.create with the built $. Runs inside the queue, and says what it found: 'new'
// when it made the record for a new id, 'held' when the id kept and writes held for it went on the
// record it has, 'same' when nothing changed, 'unread' when it looked and could not read the id.
// 'held' also covers a record reopened (#751). `afterCommand` is set by the look once a /clear or a
// /resume has run, alone, so that look can say in the debug log which id it saw.
type Rolled = 'new' | 'held' | 'same' | 'unread'
let roll: ((always: boolean, afterCommand?: boolean) => Promise<Rolled>) | undefined
// The id and the reason of the last session end that may keep or change the id, for that line.
let ended: { id: string; reason: string } | undefined
const save = (change?: Change): Promise<void> =>
  enqueue(async () => {
    if (!rec || !home || !persist) return
    if ((await roll?.(false)) === 'unread') {
      if (change) apply((held ??= { edits: [], extra: {} }), change)
      return
    }
    if (change) apply(rec, change)
    await persist()
  })
// The new conversation's record written as soon as its id is seen, with nothing else to write.
// `always` looks whether or not a session end is still waiting on its new id (the command's look).
const catchUp = (always: boolean, afterCommand = false): Promise<void> =>
  enqueue(async () => {
    if (!rec || !home || !persist) return
    const rolled = await roll?.(always, afterCommand)
    if (rolled === 'new' || rolled === 'held') await persist()
  })

// A new record. The engine refuses the built $ as an argument, so each caller asks git and the clock
// with its own $ and hands the answers here.
const topLevel = ['rev-parse', '--show-toplevel']
const rootOf = (r: { exitCode: number; stdout: string } | undefined): string | null => (r?.exitCode === 0 && r.stdout.trim() ? r.stdout.trim() : null)
const blank = (sessionId: string, cwd: string, now: number, repoRoot: string | null): SessionsRecord => ({
  v: 1,
  sessionId,
  cwd,
  repoRoot,
  startedAt: now,
  lastSeen: now,
  closedAt: null,
  transcriptPath: null,
  edits: [],
  extra: {},
})
const fresh = async ($: EngineInterface, sessionId: string, cwd: string): Promise<SessionsRecord> =>
  blank(sessionId, cwd, await $.clock.now(), rootOf(await $.process.run(['git', '-C', cwd, ...topLevel], { timeoutMs: 5_000 }).catch(() => undefined)))

// A beat: the session's id can change under a running process (a /clear), and then this process
// carries on as a new session with a record of its own. The new record replaces the old inside the
// queue, so a save still waiting there cannot write the old record after it (lessons review of #632).
const beat = async ($: EngineInterface) => {
  if (!rec) return
  const now = await $.clock.now()
  await enqueue(async () => {
    if (!rec || !home || !persist) return
    if ((await roll?.(true)) !== 'new') rec.lastSeen = now
    await persist()
  })
}

const found = new Map<string, string>()
// When a session's transcript was last searched for and not found: searched again after a minute,
// not on every read, since every guarded edit reads the list (lessons review of #636).
const missed = new Map<string, number>()
const SEARCH_AGAIN_MS = 60_000
// Far more sessions than are ever open at once; the cap only stops growth over a long process.
const CACHE_MAX = 200
// What a session id looks like; anything else read from disk never goes into a path or a search.
const SESSION_ID = /^[A-Za-z0-9-]+$/

// What a readable record is, one rule for every reader (the list and the cleanup), so a record is
// damaged or readable the same way everywhere (lessons review of #644). Every time it holds must be
// a number, or an age computed from it is NaN and slips past every check (L50).
const isRecord = (r: SessionsRecord): boolean =>
  r.v === 1 && typeof r.sessionId === 'string' && typeof r.lastSeen === 'number' && (r.closedAt === null || typeof r.closedAt === 'number')

// Clears out what has expired, once per session start so no edit pays for it (#633). A closed
// record goes 7 days after it closed; a crashed one, never closed, 7 days after it was last seen;
// a damaged one 7 days after its file last changed, named in one grey line. A damaged record any
// newer stays, since it may belong to a live session, and still stops guarded actions.
const prune = async ($: EngineInterface, h: string, now: number) => {
  const dir = dirOf(h)
  let entries: { name: string; kind: string }[]
  try {
    entries = await $.fs.list(dir)
  } catch {
    return
  }
  const damaged: string[] = []
  for (const ent of entries) {
    if (ent.kind !== 'file' || !ent.name.endsWith('.json') || ent.name.startsWith('.')) continue
    const path = `${dir}/${ent.name}`
    let endedAt: number | null
    let isDamaged = false
    try {
      const r = JSON.parse(await $.fs.read(path)) as SessionsRecord
      if (!isRecord(r)) throw new Error('shape')
      endedAt = r.closedAt ?? (now - r.lastSeen > DEAD_MS ? r.lastSeen : null)
    } catch {
      isDamaged = true
      try {
        endedAt = (await $.fs.stat(path)).mtimeMs
      } catch {
        continue
      }
    }
    if (endedAt === null || now - endedAt <= KEEP_MS) continue
    const rm = await $.process.run(['rm', '-f', path]).catch(() => undefined)
    if (rm?.exitCode === 0 && isDamaged) damaged.push(ent.name)
  }
  if (damaged.length) $.ui.log(`Session registry deleted ${damaged.length === 1 ? 'a damaged record' : `${damaged.length} damaged records`} older than ${KEEP_MS / (24 * 60 * 60_000)} days: ${damaged.join(', ')}.`)
}

export const register: Register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    persist = async () => {
      if (!rec || !home) return
      const dir = dirOf(home)
      const tmp = `${dir}/.${rec.sessionId}.json.tmp`
      await built.fs.write(tmp, JSON.stringify(rec))
      // Bounded under a noun's 10 s, since this runs inside engine.create's code (#802); a run cut off
      // is said like any other failed save.
      const mv = await built.process
        .run(['mv', '-f', tmp, `${dir}/${rec.sessionId}.json`], { timeoutMs: 5_000 })
        .catch((err: unknown) => ({ exitCode: -1, stderr: err instanceof Error ? err.message : String(err) }))
      if (mv.exitCode !== 0) built.ui.log(`session-registry: could not save this session's record: ${mv.stderr.trim()}`, { to: 'debug' })
    }
    // Runs inside the queue. `always` is the beat's and the command's, which look whether or
    // not a session end was seen; any other caller looks only after a /clear or a resume (above).
    roll = async (always, afterCommand = false) => {
      if (!rec || (!always && !expectNew)) return 'same'
      let id: string
      try {
        id = await built.session.id()
      } catch (err) {
        if (!toldNoId) {
          toldNoId = true
          built.ui.log(
            `session-registry: could not read this session's id (${err instanceof Error ? err.message : String(err)}). Until it can, writes made since a /clear or a resume are held for the record it names, and the beat keeps to the record of ${rec.sessionId}.`,
            { to: 'debug' },
          )
        }
        return 'unread'
      }
      toldNoId = false
      // Whether Claude Code had switched the id by the time the /clear's (or /resume's) command had
      // run, said in the debug log on every such look. This line is the measurement cited above
      // expectNew (#751 item 1), and keeps showing should a later Claude Code reverse the order.
      if (afterCommand && expectNew && ended) {
        built.ui.log(
          `session-registry: once the /${ended.reason} had run, the session id read ${id}; session.end had closed ${ended.id}, so the id had ${id === ended.id ? 'not changed' : 'already switched'}.`,
          { to: 'debug' },
        )
      }
      if (id === rec.sessionId) {
        // Only a settling look (the command's or the beat's) reopens a record a session end
        // closed and whose id kept (#751): a resume of this same session goes on under it, so every
        // reader must count it open. A read or a write during the /clear can see the old id before
        // the switch, so its look never does.
        let reopened = false
        if (always && expectNew) {
          expectNew = false
          if (rec.closedAt !== null) {
            rec.closedAt = null
            reopened = true
          }
        }
        return release(rec) || reopened ? 'held' : 'same'
      }
      expectNew = false
      // The conversation under the old id is over: a record still open (reopened by a look that came
      // before the switch, or one whose end was never seen) is closed before the new one is made.
      if (rec.closedAt === null) {
        rec.closedAt = await built.clock.now()
        await persist?.()
      }
      const cwd = rec.cwd
      rec = blank(id, cwd, await built.clock.now(), rootOf(await built.process.run(['git', '-C', cwd, ...topLevel], { timeoutMs: 5_000 }).catch(() => undefined)))
      release(rec)
      return 'new'
    }
    // Where a session's transcript is, only if that file is really there: in the folder for the
    // directory it started in, else wherever a file named by its id is. Never a guessed path, so a
    // reader can say the transcript was not found rather than fail to read one that never existed.
    const transcriptOf = async (h: string, r: SessionsRecord, now: number): Promise<string | null> => {
      if (!SESSION_ID.test(r.sessionId)) return null
      for (const p of [found.get(r.sessionId), r.transcriptPath, `${projectsOf(h)}/${folderOf(r.cwd)}/${r.sessionId}.jsonl`]) {
        if (p && (await built.fs.exists(p).catch(() => false))) {
          remember(found, r.sessionId, p, CACHE_MAX)
          return p
        }
      }
      const last = missed.get(r.sessionId)
      if (last !== undefined && now - last < SEARCH_AGAIN_MS) return null
      try {
        const f = await built.process.run(['find', projectsOf(h), '-maxdepth', '2', '-name', `${r.sessionId}.jsonl`], { timeoutMs: 5_000 })
        const p = f.exitCode === 0 ? f.stdout.split('\n').map(l => l.trim()).find(Boolean) : undefined
        if (p) {
          remember(found, r.sessionId, p, CACHE_MAX)
          missed.delete(r.sessionId)
          return p
        }
      } catch {
        // Not found is the answer: the reader says so by name.
      }
      remember(missed, r.sessionId, now, CACHE_MAX)
      return null
    }
    const sessions: Sessions = {
      list: async (): Promise<SessionsList> => {
        // After a /clear, this session is the new conversation from the first read (#735).
        if (expectNew) await catchUp(false)
        const h = home ?? (await built.env.get('HOME'))
        const out: SessionsList = { open: [], closed: [], unreadable: [], selfId: rec?.sessionId ?? null }
        if (!h) {
          out.unreadable.push('the sessions folder (HOME is not set)')
          return out
        }
        const now = await built.clock.now()
        let entries: { name: string; kind: string }[] = []
        try {
          entries = await built.fs.list(dirOf(h))
        } catch {
          out.unreadable.push('the sessions folder')
          return out
        }
        for (const ent of entries) {
          if (ent.kind !== 'file' || !ent.name.endsWith('.json') || ent.name.startsWith('.')) continue
          let r: SessionsRecord
          try {
            r = JSON.parse(await built.fs.read(`${dirOf(h)}/${ent.name}`)) as SessionsRecord
            if (!isRecord(r)) throw new Error('shape')
          } catch {
            out.unreadable.push(ent.name)
            continue
          }
          const isOpen = r.closedAt === null && now - r.lastSeen <= DEAD_MS
          if (isOpen) r.transcriptPath = await transcriptOf(h, r, now)
          ;(isOpen ? out.open : out.closed).push(r)
        }
        return out
      },
      noteEdit: ({ path }) => save({ edit: path }),
      setExtra: ({ key, value }) => save({ key, value }),
    }
    return { ...built, sessions }
  })

  on('session.start', async ($, e, next) => {
    home = await $.env.get('HOME')
    if (home) {
      await $.process.run(['mkdir', '-p', dirOf(home)])
      await prune($, home, await $.clock.now())
      rec = await fresh($, await $.session.id(), e.cwd)
      expectNew = false
      // A write held from before a fresh start has no record of its own to go on.
      held = undefined
      await save()
      if (!beating) {
        beating = true
        $.clock.every(BEAT_MS, () => beat($))
      }
    } else {
      $.ui.log("Session registry couldn't find the home folder, so other mods can't see this session.")
    }
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    const now = await $.clock.now()
    // Closed without looking for a new id, since this is the old conversation's last write; only
    // after it may the next one make the new conversation's record (#735).
    await enqueue(async () => {
      if (!rec || !persist || rec.sessionId !== e.sessionId) return
      rec.closedAt = now
      await persist()
    })
    if (e.reason === 'clear' || e.reason === 'resume') {
      expectNew = true
      ended = { id: e.sessionId, reason: e.reason }
    }
    return next(e)
  })

  // Once a /clear or a /resume has run, the new conversation's record is made (#735), looked for
  // even when a read during it already found the old id (#739). The look is the command's own, never
  // the classic SessionStart that announces the new conversation: Claude Code's built-in security
  // default, seated outermost on a Team or Enterprise organization (both Macs), sends every classic
  // hook event past the plugins a person installs, so that hook never ran (#751, measured on a real
  // /clear 2026-10-06). The session ends inside the command, so by the time it has run session.end
  // has said whether a new id is on the way.
  on('command.run', { command: ['clear', 'resume'] }, async ($, e, next) => {
    const result = await next(e)
    if (expectNew) await catchUp(true, true)
    return result
  })
}
