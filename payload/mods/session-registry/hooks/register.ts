import type { EngineInterface, Register } from 'claude-code'
import type { Sessions, SessionsList, SessionsRecord } from '../types/index.d.ts'

// ONE record of the open sessions on this Mac, read by the collision guard (#605), the background
// job watcher (#611) and the goal tracker (#612), which the milestone said must not each build
// their own (#612's consolidation note, L613). One file per session, so no two sessions ever write
// the same file; written whole and moved into place, so a reader never sees half of one.
//
// Settled with Dan on 2026-10-03: a session silent for five minutes counts as closed, and a
// session's requests are read from its own transcript when needed, never copied here.

const DEAD_MS = 5 * 60_000
const BEAT_MS = 60_000
const MAX_EDITS = 500

let home: string | undefined
let rec: SessionsRecord | undefined
let chain: Promise<unknown> = Promise.resolve()
// One beat per module load, however many times session.start fires on it (a /clear, a resume).
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
const save = (change: (r: SessionsRecord) => void): Promise<void> => {
  const next = chain.then(async () => {
    if (!rec || !home || !persist) return
    change(rec)
    await persist()
  })
  chain = next.catch(() => undefined)
  return next
}

const fresh = async ($: EngineInterface, sessionId: string, cwd: string): Promise<SessionsRecord> => {
  const now = await $.clock.now()
  let repoRoot: string | null = null
  try {
    const r = await $.process.run(['git', '-C', cwd, 'rev-parse', '--show-toplevel'])
    repoRoot = r.exitCode === 0 && r.stdout.trim() ? r.stdout.trim() : null
  } catch {
    repoRoot = null
  }
  return { v: 1, sessionId, cwd, repoRoot, startedAt: now, lastSeen: now, closedAt: null, transcriptPath: null, edits: [], extra: {} }
}

// A beat: the session's id can change under a running process (a /clear), and then this process
// carries on as a new session with a record of its own.
const beat = async ($: EngineInterface) => {
  if (!rec) return
  const id = await $.session.id()
  const now = await $.clock.now()
  if (id !== rec.sessionId) {
    // The new record replaces the old inside the queue, so a save still waiting there cannot write
    // the old record after it (lessons review of #632).
    const next = await fresh($, id, rec.cwd)
    await save(() => {
      rec = next
    })
    return
  }
  await save(r => {
    r.lastSeen = now
  })
}

const found = new Map<string, string>()

export const register: Register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    persist = async () => {
      if (!rec || !home) return
      const dir = dirOf(home)
      const tmp = `${dir}/.${rec.sessionId}.json.tmp`
      await built.fs.write(tmp, JSON.stringify(rec))
      const mv = await built.process.run(['mv', '-f', tmp, `${dir}/${rec.sessionId}.json`])
      if (mv.exitCode !== 0) built.ui.log(`session-registry: could not save this session's record: ${mv.stderr.trim()}`, { to: 'debug' })
    }
    // Where a session's transcript is, only if that file is really there: in the folder for the
    // directory it started in, else wherever a file named by its id is. Never a guessed path, so a
    // reader can say the transcript was not found rather than fail to read one that never existed.
    const transcriptOf = async (h: string, r: SessionsRecord): Promise<string | null> => {
      for (const p of [found.get(r.sessionId), r.transcriptPath, `${projectsOf(h)}/${folderOf(r.cwd)}/${r.sessionId}.jsonl`]) {
        if (p && (await built.fs.exists(p).catch(() => false))) {
          found.set(r.sessionId, p)
          return p
        }
      }
      try {
        const f = await built.process.run(['find', projectsOf(h), '-maxdepth', '2', '-name', `${r.sessionId}.jsonl`], { timeoutMs: 5_000 })
        const p = f.exitCode === 0 ? f.stdout.split('\n').map(l => l.trim()).find(Boolean) : undefined
        if (p) {
          found.set(r.sessionId, p)
          return p
        }
      } catch {
        // Not found is the answer: the reader says so by name.
      }
      return null
    }
    const sessions: Sessions = {
      list: async (): Promise<SessionsList> => {
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
            if (r.v !== 1 || typeof r.sessionId !== 'string' || typeof r.lastSeen !== 'number') throw new Error('shape')
          } catch {
            out.unreadable.push(ent.name)
            continue
          }
          const isOpen = r.closedAt === null && now - r.lastSeen <= DEAD_MS
          if (isOpen) r.transcriptPath = await transcriptOf(h, r)
          ;(isOpen ? out.open : out.closed).push(r)
        }
        return out
      },
      noteEdit: ({ path }) =>
        save(r => {
          r.edits = [...r.edits.filter(p => p !== path), path].slice(-MAX_EDITS)
        }),
      setExtra: ({ key, value }) =>
        save(r => {
          r.extra = { ...r.extra, [key]: value }
        }),
    }
    return { ...built, sessions }
  })

  on('session.start', async ($, e, next) => {
    home = await $.env.get('HOME')
    if (home) {
      await $.process.run(['mkdir', '-p', dirOf(home)])
      rec = await fresh($, await $.session.id(), e.cwd)
      await save(() => undefined)
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
    if (rec && rec.sessionId === e.sessionId) {
      await save(r => {
        r.closedAt = now
      })
    }
    return next(e)
  })
}
