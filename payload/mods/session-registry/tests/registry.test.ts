import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'

const DIR = '/Users/x/.claude/state/sessions'
const MIN = 60_000

// A consumer standing in for the collision guard, the job watcher and the goal tracker: Bash
// commands it is handed are calls on $.sessions, and it answers with what came back. The engine
// requires a noun to be called in place ($.sessions.list()), never held in a variable.
const consumer: { name: string; register: Register } = {
  name: 'consumer',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => {
      const [verb, arg] = String((e as { command?: string }).command).split(' ')
      if (verb === 'list') {
        try {
          return { deny: JSON.stringify(await $.sessions.list()) }
        } catch (err) {
          return { deny: `list failed: ${err instanceof Error ? err.message : String(err)}` }
        }
      }
      if (verb === 'edit') await $.sessions.noteEdit({ path: arg as string })
      if (verb === 'extra') await $.sessions.setExtra({ key: 'jobs', value: [arg] })
      return { deny: 'done' }
    })
  },
}
// Claude Code's built-in security default, as it sat on both Macs until each was given a managed
// settings file (#751, #876). It seats itself outermost for a Team or Enterprise organization and
// sends every classic hook event past the tier a person's own plugins load in, so no mod of ours
// sees one wherever that file is missing. This is its own code for
// that event, copied from the 2.1.292 binary: `e("classic.*",(n,o,t)=>t.to(o,"append"))`. The
// debug log of a real /clear on 2026-10-06 said the same of this mod: "classic.SessionStart
// bypassed by cc-plugin-sec-default (tier user); beneath runs".
const secDefault: { name: string; tier: 'prepend'; register: Register } = {
  name: 'sec-default-stand-in',
  tier: 'prepend',
  register: on => {
    on('classic.*', ($, e, next) => next.to(e, 'append'))
  },
}
const withConsumer = { plugins: [secDefault, consumer] }

// This Mac beneath the registry: a filesystem in memory, git, the session's id, the clock. A file's
// modification time is the one opts.mtimes gives it, else a stamp moved on by every write and carried
// by a move, as a real file's is; the folder listing answers it, as Claude Code's does.
type WorldOpts = {
  files?: Record<string, string>
  id?: () => string
  mtimes?: Record<string, number>
  mvThrows?: boolean
  during?: (command: string) => Promise<void>
  // A listing with no modification times in it.
  noMtimes?: boolean
  // Runs as each mv starts, before anything moves, so an owner's write can land in between.
  beforeMv?: (argv: string[]) => void
}
const world = (on: On, opts: WorldOpts = {}) => {
  const files: Record<string, string> = { ...(opts.files ?? {}) }
  const stamps: Record<string, number> = {}
  let tick = 0
  const stampOf = (p: string) => opts.mtimes?.[p] ?? stamps[p] ?? 100 * MIN
  const logs: string[] = []
  const removed: string[] = []
  const writes: string[] = []
  const reads: string[] = []
  const finds: string[] = []
  // Each command run and the timeout it was given, so a bound can be asserted (#802).
  const bounds: [string, number | undefined][] = []
  mock.env(on, { HOME: '/Users/x' })
  const clock = mock.clock(on, { now: 100 * MIN })
  const put = (p: string, text: string) => {
    files[p] = text
    stamps[p] = 100 * MIN + ++tick / 1000
  }
  on('fs.write', ($, e) => {
    writes.push(e.path)
    put(e.path, e.text)
    return { value: undefined }
  })
  // A read of the path given to hang() does not answer until unhang().
  let hangs: string | undefined
  // A read of the path given to vanish() finds it moved away just after the listing named it.
  let vanishing: string | undefined
  let unhang = () => undefined as void
  const hung = new Promise<void>(r => (unhang = r))
  let reached = () => undefined as void
  const hangReached = new Promise<void>(r => (reached = r))
  on('fs.read', async ($, e) => {
    reads.push(e.path)
    if (e.path === hangs) {
      reached()
      await hung
    }
    if (e.path === vanishing) delete files[e.path]
    if (!(e.path in files)) throw new Error(`no file ${e.path}`)
    return { value: files[e.path] as string }
  })
  on('fs.exists', ($, e) => ({ value: e.path in files }) as never)
  on('fs.stat', ($, e) => {
    if (!(e.path in files)) throw new Error(`no file ${e.path}`)
    return { value: { kind: 'file', size: 1, mtimeMs: stampOf(e.path), isLink: false } } as never
  })
  on('fs.list', ($, e) => {
    const names = new Map<string, 'file' | 'dir'>()
    for (const p of Object.keys(files)) {
      if (!p.startsWith(e.path + '/')) continue
      const rest = p.slice(e.path.length + 1)
      const cut = rest.indexOf('/')
      names.set(cut < 0 ? rest : rest.slice(0, cut), cut < 0 ? 'file' : 'dir')
    }
    return {
      value: [...names].map(([name, kind]) => {
        const p = `${e.path}/${name}`
        const isFile = kind === 'file'
        return { name, kind, size: isFile ? (files[p] as string).length : 0, mtimeMs: isFile && !opts.noMtimes ? stampOf(p) : 0, isLink: false }
      }),
    } as never
  })
  // A gate the test can close to hold every move into place, so a save can be caught part way.
  const gate = { held: false, release: () => undefined as void, wait: Promise.resolve() }
  const hold = () => {
    gate.held = true
    gate.wait = new Promise<void>(r => (gate.release = () => { gate.held = false; r() }))
  }
  on('process.run', async ($, e) => {
    if (e.argv[0] === 'mv' && gate.held) await gate.wait
    bounds.push([e.argv[0] as string, (e.init as { timeoutMs?: number } | undefined)?.timeoutMs])
    // Refused, which is how a run the engine cut off at its timeout reaches the mod.
    if (e.argv[0] === 'mv' && opts.mvThrows) return { deny: 'mv did not answer within 5 seconds' } as never
    const [cmd, ...rest] = e.argv
    const [a, b] = rest.filter(x => !x.startsWith('-'))
    const ok = (stdout = '') => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })
    if (cmd === 'mkdir') return ok()
    if (cmd === 'rm') {
      const tree = rest.some(x => /^-[a-z]*r/.test(x))
      for (const f of rest.filter(x => !x.startsWith('-'))) {
        removed.push(f)
        for (const p of Object.keys(files)) if (p === f || (tree && p.startsWith(f + '/'))) delete files[p]
      }
      return ok()
    }
    // mv [-f|-n] SOURCE... DEST, where a DEST ending in / is a folder the sources go into, by name.
    if (cmd === 'mv' && a && b) {
      opts.beforeMv?.(e.argv as string[])
      const args = rest.filter(x => !x.startsWith('-'))
      const dest = args[args.length - 1] as string
      let missing = ''
      for (const src of args.slice(0, -1)) {
        const to = dest.endsWith('/') ? dest + src.split('/').pop() : dest
        if (!(src in files)) {
          missing += `mv: ${src}: No such file or directory\n`
          continue
        }
        if (rest.includes('-n') && to in files) continue
        files[to] = files[src] as string
        stamps[to] = stampOf(src)
        delete files[src]
        delete stamps[src]
      }
      return missing ? { value: { exitCode: 1, stdout: '', stderr: missing, isStdoutTruncated: false, isStderrTruncated: false } } : ok()
    }
    if (cmd === 'git') return ok('/repo\n')
    if (cmd === 'find' && a) {
      finds.push(rest[rest.indexOf('-name') + 1] as string)
      const name = rest[rest.indexOf('-name') + 1] as string
      return ok(Object.keys(files).filter(p => p.startsWith(a + '/') && p.endsWith('/' + name)).map(p => p + '\n').join(''))
    }
    return { value: { exitCode: 1, stdout: '', stderr: 'unexpected', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('session.id', () => ({ value: (opts.id ?? (() => 's1'))() }) as never)
  // A /clear or a /resume as Claude Code runs one: the session ends inside the command (the debug
  // log of a real /clear: session.end settled, then the command), and the command finishes under
  // whatever id the session then has. opts.during is what happens inside it.
  on('command.run', async ($, e) => {
    if (e.command === 'clear' || e.command === 'resume') await opts.during?.(e.command)
    return { text: '' } as never
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }) as never)
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  on('ui.log', ($, e) => {
    logs.push(e.text)
    return { value: undefined }
  })
  const own = (id = 's1') => JSON.parse(files[`${DIR}/${id}.json`] ?? 'null')
  // A file written by someone other than the registry (its owner in another session, or the test).
  const touch = put
  return { files, writes, reads, finds, logs, removed, bounds, clock, own, touch, hang: (p: string) => void (hangs = p), vanish: (p: string) => void (vanishing = p), unhang: () => unhang(), hangReached, hold, release: () => gate.release() }
}

const start = ($: { session: { start: (e: never) => Promise<unknown> } }) =>
  $.session.start({ cwd: '/repo/app', surface: 'terminal', isInteractive: true } as never)
const call = async ($: { tool: { call: (e: never) => Promise<unknown> } }, command: string) => {
  const r = (await $.tool.call({ tool: 'Bash', command } as never)) as { deny?: string; text?: string }
  return r.deny ?? r.text ?? ''
}

test('a session that starts writes its own record', withConsumer, async ($, on) => {
  const w = world(on)
  await start($)
  expect(w.own()).toEqual({
    v: 1,
    sessionId: 's1',
    cwd: '/repo/app',
    repoRoot: '/repo',
    startedAt: 100 * MIN,
    lastSeen: 100 * MIN,
    closedAt: null,
    transcriptPath: null,
    edits: [],
    extra: {},
  })
})

test('the record is written whole, never in place, so a reader cannot see half of it', withConsumer, async ($, on) => {
  const w = world(on)
  await start($)
  expect(w.writes.length).toBeGreaterThan(0)
  expect(w.writes.every(p => p !== `${DIR}/s1.json`)).toBe(true)
})

test("the save's move and the repository lookup are bounded under a noun's 10 s (#802)", withConsumer, async ($, on) => {
  const w = world(on)
  await start($)
  const of = (cmd: string) => w.bounds.filter(([c]) => c === cmd).map(([, t]) => t)
  expect(of('mv').length).toBeGreaterThan(0)
  expect(of('mv').every(t => t === 5_000)).toBe(true)
  expect(of('git').length).toBeGreaterThan(0)
  expect(of('git').every(t => t === 5_000)).toBe(true)
})

test('after a /clear, the new record\'s repository lookup is bounded too (#802)', withConsumer, async ($, on) => {
  let id = 's1'
  let before = 0
  const w = world(on, {
    id: () => id,
    during: async c => {
      await $.session.end({ reason: c, sessionId: id } as never)
      before = w.bounds.length
      id = 's2'
    },
  })
  await start($)
  await run($ as never, 'clear')
  const after = w.bounds.slice(before).filter(([c]) => c === 'git').map(([, t]) => t)
  expect(after.length).toBeGreaterThan(0)
  expect(after.every(t => t === 5_000)).toBe(true)
})

test('a save whose move throws is said in the debug log, and the session goes on (#802)', withConsumer, async ($, on) => {
  const w = world(on, { mvThrows: true })
  await start($)
  expect(w.logs.some(l => /^session-registry: could not save this session's record: .*mv did not answer within 5 seconds/.test(l))).toBe(true)
})

test('it beats every minute while the session runs', withConsumer, async ($, on) => {
  const w = world(on)
  await start($)
  await w.clock.advance(MIN + 1)
  // The beat fires on the minute, and stamps the time it fired.
  expect(w.own().lastSeen).toBe(101 * MIN)
})

test('a second start does not double the beat (lessons review)', withConsumer, async ($, on) => {
  const w = world(on)
  await start($)
  await start($)
  const before = w.writes.length
  await w.clock.advance(MIN + 1)
  // One beat in the minute is one write; a doubled timer would write twice.
  expect(w.writes.length - before).toBe(1)
})

test('a clean end marks it closed', withConsumer, async ($, on) => {
  const w = world(on)
  await start($)
  await $.session.end({ reason: 'other', sessionId: 's1' } as never)
  expect(w.own().closedAt).toBe(100 * MIN)
})

test('an edit is noted once, newest last', withConsumer, async ($, on) => {
  const w = world(on)
  await start($)
  await call($, 'edit /repo/a.ts')
  await call($, 'edit /repo/b.ts')
  await call($, 'edit /repo/a.ts')
  expect(w.own().edits).toEqual(['/repo/b.ts', '/repo/a.ts'])
})

test('other mods keep their own keys on the record', withConsumer, async ($, on) => {
  const w = world(on)
  await start($)
  await call($, 'extra job-1')
  expect(w.own().extra).toEqual({ jobs: ['job-1'] })
})

test('the list sorts sessions into open and closed, and names what it cannot read', withConsumer, async ($, on) => {
  const rec = (id: string, lastSeen: number, closedAt: number | null) =>
    JSON.stringify({ v: 1, sessionId: id, cwd: '/repo', repoRoot: '/repo', startedAt: 0, lastSeen, closedAt, transcriptPath: null, edits: [], extra: {} })
  const w = world(on, {
    files: {
      [`${DIR}/fresh.json`]: rec('fresh', 99 * MIN, null),
      [`${DIR}/quiet.json`]: rec('quiet', 94 * MIN, null),
      [`${DIR}/ended.json`]: rec('ended', 99 * MIN, 99 * MIN),
      [`${DIR}/broken.json`]: '{ half a rec',
    },
  })
  await start($)
  const l = JSON.parse(await call($, 'list')) as { open: { sessionId: string }[]; closed: { sessionId: string }[]; unreadable: string[]; selfId: string }
  expect(l.open.map(s => s.sessionId).sort()).toEqual(['fresh', 's1'])
  expect(l.closed.map(s => s.sessionId).sort()).toEqual(['ended', 'quiet'])
  expect(l.unreadable).toEqual(['broken.json'])
  expect(l.selfId).toBe('s1')
  void w
})

test('after a /clear the process carries on under its new id, with a record of its own', withConsumer, async ($, on) => {
  let id = 's1'
  const w = world(on, { id: () => id })
  await start($)
  await $.session.end({ reason: 'clear', sessionId: 's1' } as never)
  id = 's2'
  await w.clock.advance(MIN + 1)
  expect(w.own('s1').closedAt).toBe(100 * MIN)
  expect(w.own('s2').closedAt).toBe(null)
  expect(w.own('s2').sessionId).toBe('s2')
})

// A slash command typed at the prompt, run through every plugin as the REPL runs it.
const run = ($: { command: { run: (e: never) => Promise<unknown> } }, command: string) => $.command.run({ command, args: '' } as never)
type Classic = { classic: { SessionStart: (e: never) => Promise<unknown> } }

// The control for the stand-in (L159): a classic hook of a person's own plugin runs without it and
// is sent past with it, so a test that passes beside it cannot be leaning on a classic hook.
const probe: { name: string; register: Register } = {
  name: 'probe',
  register: on => {
    on('classic.SessionStart', async ($, e, next) => {
      await $.ui.log('probe ran', { to: 'debug' })
      return next(e)
    })
  },
}
const probeRan = async ($: unknown, on: On) => {
  const logs: string[] = []
  on('ui.log', ($, e) => {
    logs.push(e.text)
    return { value: undefined }
  })
  on('classic.SessionStart', () => ({}) as never)
  await ($ as Classic).classic.SessionStart({ source: 'clear' } as never)
  return logs.includes('probe ran')
}
test("a person's own classic SessionStart hook runs where no security default is seated (#751)", { plugins: [probe] }, async ($, on) => {
  expect(await probeRan($, on)).toBe(true)
})
test("the security default's stand-in sends that hook past, as the real one does (#751)", { plugins: [secDefault, probe] }, async ($, on) => {
  expect(await probeRan($, on)).toBe(false)
})

// #751: where the security default above is seated no classic hook of ours runs, so the look that
// settles a /clear comes from the /clear itself: once its command has run, the session has ended and
// its id has switched, and the new conversation has its record before any beat. No clock moves.
// What happens inside a /clear or a /resume: the session ends under the id it has, then takes `to`.
type Ender = { session: { end: (e: never) => Promise<unknown> } }
const ends = ($: Ender, ids: { id: string }, to?: string) => async (command: string) => {
  await $.session.end({ reason: command, sessionId: ids.id } as never)
  if (to) ids.id = to
}
test('with the security default seated, a /clear makes the new record as its command finishes, before any beat (#751)', withConsumer, async ($, on) => {
  const ids = { id: 's1' }
  const w = world(on, { id: () => ids.id, during: ends($, ids, 's2') })
  await start($)
  await run($ as never, 'clear')
  expect(w.own('s1').closedAt).toBe(100 * MIN)
  expect(w.own('s2')).toMatchObject({ sessionId: 's2', closedAt: null, cwd: '/repo/app', edits: [], extra: {} })
})

// #735: the new conversation's record is made when its id is first seen, never at the next beat, so
// for that minute /goals does not miss it and the goal tracker and job watcher do not write into
// the record session.end just closed. No clock moves in these two.
test('after a /clear a write from the new conversation lands on its own record at once, never on the closed one (#735)', withConsumer, async ($, on) => {
  let id = 's1'
  const w = world(on, { id: () => id })
  await start($)
  await call($, 'extra job-1')
  await $.session.end({ reason: 'clear', sessionId: 's1' } as never)
  id = 's2'
  await call($, 'extra job-2')
  await call($, 'edit /repo/b.ts')
  expect(w.own('s1')).toMatchObject({ closedAt: 100 * MIN, extra: { jobs: ['job-1'] }, edits: [] })
  expect(w.own('s2')).toMatchObject({ closedAt: null, extra: { jobs: ['job-2'] }, edits: ['/repo/b.ts'] })
})

test('after a /clear the list names the new conversation as this session at once (#735)', withConsumer, async ($, on) => {
  let id = 's1'
  world(on, { id: () => id })
  await start($)
  await $.session.end({ reason: 'clear', sessionId: 's1' } as never)
  id = 's2'
  const l = JSON.parse(await call($, 'list')) as { open: { sessionId: string }[]; closed: { sessionId: string }[]; selfId: string }
  expect(l.selfId).toBe('s2')
  expect(l.open.map(s => s.sessionId)).toEqual(['s2'])
  expect(l.closed.map(s => s.sessionId)).toEqual(['s1'])
})

// #739: after a /clear the write path asks for the session's id, and a lookup that fails must not
// fail the write for the collision guard, the goal tracker and the job watcher. Nor may the write go
// to the record session.end just closed, which no reader counts as open (lessons review of #739).
const throwing = () => {
  throw new Error('no id to give')
}
test('after a /clear, writes made while the id cannot be read are held for the new record, said once in the debug log (#739)', withConsumer, async ($, on) => {
  let id: () => string = () => 's1'
  const w = world(on, { id: () => id() })
  await start($)
  await $.session.end({ reason: 'clear', sessionId: 's1' } as never)
  id = throwing
  await call($, 'edit /repo/a.ts')
  await call($, 'extra job-1')
  expect(w.own('s1')).toMatchObject({ closedAt: 100 * MIN, edits: [], extra: {} })
  // Two writes, one line: the engine hands the reason on as its own (no implementation once the
  // hook beneath throws), so the line is found by what the registry says.
  expect(w.logs.filter(l => l.includes("could not read this session's id"))).toHaveLength(1)
  // Once the id can be read, the next write makes the new conversation's record, the held ones on it.
  id = () => 's2'
  await call($, 'edit /repo/b.ts')
  expect(w.own('s2')).toMatchObject({ sessionId: 's2', closedAt: null, edits: ['/repo/a.ts', '/repo/b.ts'], extra: { jobs: ['job-1'] } })
  expect(w.own('s1')).toMatchObject({ edits: [], extra: {} })
})

test('writes held while the id cannot be read land on the record it has once the /resume has run and finds it unchanged (#739)', withConsumer, async ($, on) => {
  let id: () => string = () => 's1'
  let during: string[] = []
  const w = world(on, {
    id: () => id(),
    during: async c => {
      await $.session.end({ reason: c, sessionId: 's1' } as never)
      id = throwing
      await call($, 'edit /repo/a.ts')
      during = w.own('s1').edits
      id = () => 's1'
    },
  })
  await start($)
  await run($ as never, 'resume')
  expect(during).toEqual([])
  expect(w.own('s1').edits).toEqual(['/repo/a.ts'])
})

test('a /clear that keeps the same id stops asking for it once its command has run and looked (#739)', withConsumer, async ($, on) => {
  let asks = 0
  let before = 0
  world(on, {
    id: () => {
      asks++
      return 's1'
    },
    during: async c => {
      await $.session.end({ reason: c, sessionId: 's1' } as never)
      before = asks
    },
  })
  await start($)
  await run($ as never, 'clear')
  expect(asks - before).toBe(1)
  await call($, 'edit /repo/a.ts')
  await call($, 'extra job-1')
  await call($, 'list')
  expect(asks - before).toBe(1)
})

// A read can come while the /clear is still under way (a pane drawn) and find the old id; it must
// not settle the question, or the new conversation's writes go to the closed record.
test("after a /clear, a read before the id changes does not stop the command's own look making the new record (#739)", withConsumer, async ($, on) => {
  let id = 's1'
  const w = world(on, {
    id: () => id,
    during: async c => {
      await $.session.end({ reason: c, sessionId: 's1' } as never)
      await call($, 'list')
      id = 's2'
    },
  })
  await start($)
  await run($ as never, 'clear')
  expect(w.own('s2')).toMatchObject({ sessionId: 's2', closedAt: null })
})

test('after a /clear, a read before the id changes does not stop a write after it reaching the new record (#739)', withConsumer, async ($, on) => {
  let id = 's1'
  const w = world(on, { id: () => id })
  await start($)
  await $.session.end({ reason: 'clear', sessionId: 's1' } as never)
  await call($, 'list')
  id = 's2'
  await call($, 'edit /repo/b.ts')
  expect(w.own('s2')).toMatchObject({ sessionId: 's2', closedAt: null, edits: ['/repo/b.ts'] })
  expect(w.own('s1').edits).toEqual([])
})

test('after a /clear, an edit queued before the switch lands on the old record, never the new (lessons review)', withConsumer, async ($, on) => {
  let id = 's1'
  const w = world(on, { id: () => id })
  await start($)
  // Hold one save part way, queue an edit behind it, then let the session id change and the beat
  // run before anything is released: the edit was made under s1 and must stay there.
  w.hold()
  const first = call($, 'edit /repo/first.ts')
  const second = call($, 'edit /repo/second.ts')
  id = 's2'
  // The beat runs, and finds its id changed, while the first save is still held.
  await w.clock.advance(MIN + 1)
  w.release()
  await Promise.all([first, second])
  await w.clock.advance(1)
  expect(w.own('s1').edits).toEqual(['/repo/first.ts', '/repo/second.ts'])
  expect(w.own('s2').edits).toEqual([])
})

// #751: session.end closes the record before anyone knows whether the id will change. When it does
// not (a resume of this same session), the conversation goes on under that record, so the look
// that settles it reopens the record; a read or a write during the /clear never does, since it can
// see the old id before the switch.
test('an end that keeps its id reopens the record once its command has run and finds the id unchanged (#751)', withConsumer, async ($, on) => {
  let closed: number | null = null
  const w = world(on, {
    during: async c => {
      await $.session.end({ reason: c, sessionId: 's1' } as never)
      closed = w.own('s1').closedAt
    },
  })
  await start($)
  await run($ as never, 'resume')
  expect(closed).toBe(100 * MIN)
  expect(w.own('s1').closedAt).toBe(null)
  const l = JSON.parse(await call($, 'list')) as { open: { sessionId: string }[] }
  expect(l.open.map(s => s.sessionId)).toEqual(['s1'])
})

test('an end that keeps its id is reopened by the beat too, when no command looks (#751)', withConsumer, async ($, on) => {
  const w = world(on)
  await start($)
  await $.session.end({ reason: 'clear', sessionId: 's1' } as never)
  await w.clock.advance(MIN + 1)
  expect(w.own('s1').closedAt).toBe(null)
})

test('a read or a write during the /clear never reopens the record, though it sees the old id (#751)', withConsumer, async ($, on) => {
  const w = world(on)
  await start($)
  await $.session.end({ reason: 'clear', sessionId: 's1' } as never)
  await call($, 'list')
  await call($, 'edit /repo/a.ts')
  expect(w.own('s1').closedAt).toBe(100 * MIN)
})

test('an end that is not a /clear or a resume is never reopened by the beat (#751)', withConsumer, async ($, on) => {
  const w = world(on)
  await start($)
  await $.session.end({ reason: 'other', sessionId: 's1' } as never)
  await w.clock.advance(MIN + 1)
  expect(w.own('s1').closedAt).toBe(100 * MIN)
})

test('a record reopened before the id switched is closed again when the new conversation gets its own (#751)', withConsumer, async ($, on) => {
  const ids = { id: 's1' }
  const w = world(on, { id: () => ids.id, during: ends($, ids) })
  await start($)
  // Should the id switch only after the /clear's command has finished, its look sees the old id
  // and reopens the record.
  await run($ as never, 'clear')
  expect(w.own('s1').closedAt).toBe(null)
  ids.id = 's2'
  await w.clock.advance(MIN + 1)
  expect(w.own('s1').closedAt).toBe(101 * MIN)
  expect(w.own('s2')).toMatchObject({ sessionId: 's2', closedAt: null })
})

test('the look once a /clear or a /resume has run says in the debug log which id it saw against the one session.end closed (#751)', withConsumer, async ($, on) => {
  const ids = { id: 's1' }
  let to: string | undefined = 's2'
  const w = world(on, { id: () => ids.id, during: c => ends($, ids, to)(c) })
  await start($)
  await run($ as never, 'clear')
  expect(w.logs).toContain('session-registry: once the /clear had run, the session id read s2; session.end had closed s1, so the id had already switched.')
  to = undefined
  await run($ as never, 'resume')
  expect(w.logs).toContain('session-registry: once the /resume had run, the session id read s2; session.end had closed s2, so the id had not changed.')
})

// The look is the /clear's or the /resume's own: any other command leaves the record as it is.
test('a command that is not a /clear or a /resume never looks for a new id (#751)', withConsumer, async ($, on) => {
  let asks = 0
  world(on, {
    id: () => {
      asks++
      return 's1'
    },
  })
  await start($)
  const before = asks
  await run($ as never, 'compact')
  expect(asks - before).toBe(0)
})

// The transcript path never reaches a module from the start hook (live check of #605, 2026-10-04:
// every record on this Mac had none), so the registry works it out where it is read, from Claude
// Code's own layout, and hands it on only when that file is really there.
const other = (id: string, cwd: string) =>
  JSON.stringify({ v: 1, sessionId: id, cwd, repoRoot: '/repo', startedAt: 0, lastSeen: 100 * MIN, closedAt: null, transcriptPath: null, edits: [], extra: {} })
const openOf = async ($: Parameters<typeof call>[0], id: string) =>
  (JSON.parse(await call($, 'list')) as { open: { sessionId: string; transcriptPath: string | null }[] }).open.find(r => r.sessionId === id)

test("an open session's transcript is found in Claude Code's folder for its working directory", withConsumer, async ($, on) => {
  const T = '/Users/x/.claude/projects/-Users-x-my-app-v2/s2.jsonl'
  world(on, { files: { [`${DIR}/s2.json`]: other('s2', '/Users/x/my_app.v2'), [T]: '' } })
  await start($)
  expect((await openOf($, 's2'))?.transcriptPath).toBe(T)
})

test('a transcript filed under another folder is found by the session id (a session that changed folder)', withConsumer, async ($, on) => {
  const T = '/Users/x/.claude/projects/-Users-x-elsewhere/s2.jsonl'
  world(on, { files: { [`${DIR}/s2.json`]: other('s2', '/Users/x/app'), [T]: '' } })
  await start($)
  expect((await openOf($, 's2'))?.transcriptPath).toBe(T)
})

test('a transcript that is nowhere is handed on as none, never as a guessed path', withConsumer, async ($, on) => {
  world(on, { files: { [`${DIR}/s2.json`]: other('s2', '/Users/x/app') } })
  await start($)
  const r = await openOf($, 's2')
  expect(r).toBeDefined()
  expect(r?.transcriptPath).toBeNull()
})

test('a transcript that is nowhere is searched for once a minute, not on every read', withConsumer, async ($, on) => {
  const w = world(on, { files: { [`${DIR}/s2.json`]: other('s2', '/Users/x/app') } })
  await start($)
  const ofS2 = () => w.finds.filter(f => f === 's2.jsonl').length
  await openOf($, 's2')
  await openOf($, 's2')
  expect(ofS2()).toBe(1)
  await w.clock.advance(MIN + 1)
  await openOf($, 's2')
  expect(ofS2()).toBe(2)
})

test('a session id that is not an id is never put into a path or a search', withConsumer, async ($, on) => {
  const w = world(on, { files: { [`${DIR}/s2.json`]: other('../*', '/Users/x/app') } })
  await start($)
  const r = (JSON.parse(await call($, 'list')) as { open: { sessionId: string; transcriptPath: string | null }[] }).open.find(x => x.sessionId === '../*')
  expect(r?.transcriptPath).toBeNull()
  // Only this session's own record (s1) was searched for.
  expect(w.finds).toEqual(['s1.jsonl'])
})

// Decided with Dan (2026-10-04, #633): a closed session's record is kept 7 days, then deleted at
// session start; a damaged record older than that is deleted too, with one grey line naming it.
// Since #911 a record that ended over an hour ago waits out those 7 days in the archive beside the
// sessions folder, in a folder for the day it ended (UTC), which goes once that whole day is 7 days
// past. The mock clock stands at 01:40 on 1970-01-01, so 6 days back is 1969-12-26.
const DAY = 24 * 60 * MIN
const HOUR = 60 * MIN
const NOW = 100 * MIN
const ARCH = '/Users/x/.claude/state/sessions-archive'
const recOf = (id: string, over: Record<string, unknown>) =>
  JSON.stringify({ v: 1, sessionId: id, cwd: '/repo', repoRoot: '/repo', startedAt: NOW - 9 * DAY, lastSeen: NOW, closedAt: null, transcriptPath: null, edits: [], extra: {}, ...over })

test('a record closed more than 7 days ago is gone after session start, a newer one is kept', withConsumer, async ($, on) => {
  const recent = recOf('recent', { closedAt: NOW - 6 * DAY, lastSeen: NOW - 6 * DAY })
  const w = world(on, {
    files: {
      [`${DIR}/old.json`]: recOf('old', { closedAt: NOW - 8 * DAY, lastSeen: NOW - 8 * DAY }),
      [`${DIR}/recent.json`]: recent,
    },
  })
  await start($)
  expect(Object.keys(w.files).filter(p => p.endsWith('/old.json'))).toEqual([])
  expect(w.files[`${ARCH}/1969-12-26/recent.json`]).toBe(recent)
  expect(w.logs.filter(l => l.includes('old.json'))).toEqual([])
})

test('a crashed session, never closed and silent more than 7 days, is gone too', withConsumer, async ($, on) => {
  const w = world(on, { files: { [`${DIR}/crashed.json`]: recOf('crashed', { lastSeen: NOW - 8 * DAY }) } })
  await start($)
  expect(Object.keys(w.files).filter(p => p.endsWith('/crashed.json'))).toEqual([])
})

test('a damaged record older than 7 days is deleted and named in one line; a newer one is left to block', withConsumer, async ($, on) => {
  const w = world(on, {
    files: { [`${DIR}/broken-old.json`]: '{not json', [`${DIR}/broken-new.json`]: '{not json' },
    mtimes: { [`${DIR}/broken-old.json`]: NOW - 8 * DAY, [`${DIR}/broken-new.json`]: NOW - DAY },
  })
  await start($)
  expect(w.removed).toEqual([`${DIR}/broken-old.json`])
  expect(w.logs.filter(l => l.includes('broken-old.json')).length).toBe(1)
  const list = JSON.parse(await call($, 'list')) as { unreadable: string[] }
  expect(list.unreadable).toEqual(['broken-new.json'])
})

test('an open session is never deleted or archived however long ago it started', withConsumer, async ($, on) => {
  const w = world(on, { files: { [`${DIR}/live.json`]: recOf('live', { startedAt: NOW - 30 * DAY, lastSeen: NOW - MIN }) } })
  await start($)
  expect(w.removed).toEqual([])
  expect(`${DIR}/live.json` in w.files).toBe(true)
})

test('a record whose closed time is not a number counts as damaged, so a recent one is kept', withConsumer, async ($, on) => {
  const w = world(on, {
    files: { [`${DIR}/odd.json`]: recOf('odd', { closedAt: 'yesterday' }) },
    mtimes: { [`${DIR}/odd.json`]: NOW - DAY },
  })
  await start($)
  expect(w.removed).toEqual([])
})

test('the list and the cleanup agree on what is damaged: a non-number closed time is unreadable to both', withConsumer, async ($, on) => {
  world(on, { files: { [`${DIR}/odd.json`]: recOf('odd', { closedAt: 'yesterday' }) }, mtimes: { [`${DIR}/odd.json`]: NOW - DAY } })
  await start($)
  const list = JSON.parse(await call($, 'list')) as { unreadable: string[] }
  expect(list.unreadable).toEqual(['odd.json'])
})

// #911: on 2026-10-07 the folder held 1,337 records, 2 of them open, and the list read every one on
// every call; under a load near 200 it passed the collision guard's 10 second budget every time, and
// the guard, failing closed as it must, refused every file write for over an hour.
type SessionLike = { sessionId: string; lastSeen: number; edits: string[]; extra: Record<string, unknown> }
type Listed = { open: SessionLike[]; closed: SessionLike[]; unreadable: string[]; selfId: string | null }
const listed = async ($: Parameters<typeof call>[0]) => {
  const text = await call($, 'list')
  if (!text.startsWith('{')) throw new Error(text)
  return JSON.parse(text) as Listed
}
const ids = (rs: SessionLike[]) => rs.map(r => r.sessionId).sort()
const timed = async (f: () => Promise<unknown>) => {
  const t = performance.now()
  await f()
  return performance.now() - t
}
const median = (xs: number[]) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)] as number
const job = { id: 'b1', command: 'npm run dev', outputPath: '/tmp/b1.output', pgid: 4242, startedAt: NOW - 3 * HOUR }

test('2,000 closed records and 2 open ones are listed in a tenth of what reading every record costs in the same run (#911)', withConsumer, async ($, on) => {
  const ended = NOW - 2 * HOUR
  const open = { [`${DIR}/o1.json`]: recOf('o1', { lastSeen: NOW - MIN }), [`${DIR}/o2.json`]: recOf('o2', { lastSeen: NOW - MIN }) }
  const w = world(on, { files: { ...open } })
  const pile = (tag: string) => {
    for (const p of Object.keys(w.files)) if (p.startsWith(`${DIR}/`) && !(p in open)) delete w.files[p]
    for (let i = 0; i < 2000; i++) w.files[`${DIR}/${tag}${i}.json`] = recOf(`${tag}${i}`, { closedAt: ended, lastSeen: ended })
  }
  // The yardstick, taken in this run on this machine as loaded as it is (L224): a list that must read
  // all 2,002 records, the work every list did before #911. Three piles under names never seen, so
  // nothing one list remembers can serve the next, and the median of the three (L656).
  const yard: number[] = []
  for (const tag of ['a', 'b', 'c']) {
    pile(tag)
    yard.push(await timed(() => listed($)))
  }
  // Pile c, closed two hours ago, is what a session finds when it starts, as on 2026-10-07.
  await start($)
  const after: number[] = []
  for (let i = 0; i < 5; i++) after.push(await timed(() => listed($)))
  expect(median(after) * 10).toBeLessThan(median(yard))
  const l = await listed($)
  expect(ids(l.open)).toEqual(['o1', 'o2', 's1'])
  expect(l.unreadable).toEqual([])
  // Moved, never deleted: every one of the 2,000 is in the archive.
  expect(Object.keys(w.files).filter(p => p.startsWith(`${ARCH}/1969-12-31/c`)).length).toBe(2000)
})

test('a record that ended over an hour ago is moved to the archive, never deleted; a newer one stays (#911)', withConsumer, async ($, on) => {
  const gone = recOf('gone', { closedAt: NOW - 2 * HOUR, lastSeen: NOW - 2 * HOUR })
  const quiet = recOf('quiet', { lastSeen: NOW - 2 * HOUR })
  const w = world(on, {
    files: { [`${DIR}/gone.json`]: gone, [`${DIR}/quiet.json`]: quiet, [`${DIR}/fresh.json`]: recOf('fresh', { closedAt: NOW - 30 * MIN, lastSeen: NOW - 30 * MIN }) },
  })
  await start($)
  expect(w.files[`${ARCH}/1969-12-31/gone.json`]).toBe(gone)
  expect(w.files[`${ARCH}/1969-12-31/quiet.json`]).toBe(quiet)
  expect(`${DIR}/gone.json` in w.files).toBe(false)
  expect(`${DIR}/quiet.json` in w.files).toBe(false)
  expect(`${DIR}/fresh.json` in w.files).toBe(true)
  expect(ids((await listed($)).closed)).toEqual(['fresh'])
})

test('a closed record still naming background jobs stays for the job watcher until its 7 days are up (#911)', withConsumer, async ($, on) => {
  const w = world(on, {
    files: {
      [`${DIR}/j1.json`]: recOf('j1', { closedAt: NOW - 2 * HOUR, lastSeen: NOW - 2 * HOUR, extra: { jobs: [job] } }),
      [`${DIR}/j8.json`]: recOf('j8', { closedAt: NOW - 8 * DAY, lastSeen: NOW - 8 * DAY, extra: { jobs: [job] } }),
    },
  })
  await start($)
  expect(`${DIR}/j1.json` in w.files).toBe(true)
  expect(Object.keys(w.files).filter(p => p.endsWith('/j8.json'))).toEqual([])
  expect(ids((await listed($)).closed)).toEqual(['j1'])
})

// Every reader of the list, read 2026-10-07: the collision guard and scope modes read only the open
// sessions and the records that cannot be read; the goal tracker reads this session's own record,
// open or closed; the job watcher reads the closed records for the jobs they name. The sleep queue
// reads the folder itself, and judges a session whose record is absent gone, as it judges one that
// has ended (test-sleep-queue.sh: "a claim by a session the registry never saw is free"), so a record
// moved out changes none of its answers. The handoff and account room mods read no session record.
test('archiving changes nothing a reader reads: the open sessions, the unreadable, this session, and the closed records with jobs (#911)', withConsumer, async ($, on) => {
  const w = world(on, {
    files: {
      [`${DIR}/o1.json`]: recOf('o1', { lastSeen: NOW - MIN }),
      [`${DIR}/r1.json`]: recOf('r1', { closedAt: NOW - 10 * MIN, lastSeen: NOW - 10 * MIN }),
      [`${DIR}/c1.json`]: recOf('c1', { closedAt: NOW - 2 * HOUR, lastSeen: NOW - 2 * HOUR }),
      [`${DIR}/k1.json`]: recOf('k1', { lastSeen: NOW - 3 * HOUR }),
      [`${DIR}/j1.json`]: recOf('j1', { closedAt: NOW - 2 * HOUR, lastSeen: NOW - 2 * HOUR, extra: { jobs: [job] } }),
      [`${DIR}/b1.json`]: '{ half a rec',
    },
    mtimes: { [`${DIR}/b1.json`]: NOW - MIN },
  })
  const withJobs = (l: Listed) => ids(l.closed.filter(r => Array.isArray(r.extra.jobs) && r.extra.jobs.length > 0))
  const before = await listed($)
  await start($)
  const after = await listed($)
  // Something was archived, so the comparison below is over a real change (L159).
  expect(`${ARCH}/1969-12-31/c1.json` in w.files && `${ARCH}/1969-12-31/k1.json` in w.files).toBe(true)
  expect(ids(after.open).filter(id => id !== 's1')).toEqual(ids(before.open))
  expect(after.unreadable).toEqual(before.unreadable)
  expect(withJobs(after)).toEqual(withJobs(before))
  expect(withJobs(after)).toEqual(['j1'])
  expect([...after.open, ...after.closed].some(r => r.sessionId === after.selfId)).toBe(true)
})

test('a record its owner wrote again just as it was archived is put back, so a live session is never hidden (#911)', withConsumer, async ($, on) => {
  let wrote = false
  const w = world(on, {
    files: { [`${DIR}/k1.json`]: recOf('k1', { lastSeen: NOW - 2 * HOUR }) },
    beforeMv: argv => {
      if (wrote || !argv.includes(`${DIR}/k1.json`)) return
      wrote = true
      w.touch(`${DIR}/k1.json`, recOf('k1', { lastSeen: NOW }))
    },
  })
  await start($)
  expect(wrote).toBe(true)
  expect(JSON.parse(w.files[`${DIR}/k1.json`] ?? 'null')?.lastSeen).toBe(NOW)
  expect(ids((await listed($)).open)).toEqual(['k1', 's1'])
})

test("an archive folder for a day 7 days past is removed; a later day's, and anything not named for a day, are kept (#911)", withConsumer, async ($, on) => {
  const w = world(on, {
    files: { [`${ARCH}/1969-12-24/a.json`]: recOf('a', {}), [`${ARCH}/1969-12-26/b.json`]: recOf('b', {}), [`${ARCH}/notes/c.json`]: 'mine' },
  })
  await start($)
  expect(`${ARCH}/1969-12-24/a.json` in w.files).toBe(false)
  expect(`${ARCH}/1969-12-26/b.json` in w.files).toBe(true)
  expect(`${ARCH}/notes/c.json` in w.files).toBe(true)
})

test('a list reads again only the records whose file changed since the last, by the time the folder listing gives (#911)', withConsumer, async ($, on) => {
  const files: Record<string, string> = { [`${DIR}/o1.json`]: recOf('o1', { lastSeen: NOW - MIN }) }
  for (let i = 0; i < 50; i++) files[`${DIR}/c${i}.json`] = recOf(`c${i}`, { closedAt: NOW - 10 * MIN, lastSeen: NOW - 10 * MIN })
  const w = world(on, { files })
  await start($)
  await listed($)
  const first = w.reads.length
  await listed($)
  // The open sessions are read every time; a closed record whose file is as it was is not.
  expect(w.reads.slice(first).sort()).toEqual([`${DIR}/o1.json`, `${DIR}/s1.json`])
  w.touch(`${DIR}/c7.json`, recOf('c7', { closedAt: NOW - 5 * MIN, lastSeen: NOW - 5 * MIN, edits: ['/repo/x.ts'] }))
  const second = w.reads.length
  const l = await listed($)
  expect(w.reads.slice(second).sort()).toEqual([`${DIR}/c7.json`, `${DIR}/o1.json`, `${DIR}/s1.json`])
  expect(l.closed.find(r => r.sessionId === 'c7')?.edits).toEqual(['/repo/x.ts'])
  expect(l.closed.length).toBe(50)
})

test('a folder listing with no modification times has every record read on every list, said once in the debug log (#911, L289)', withConsumer, async ($, on) => {
  const files: Record<string, string> = {}
  for (let i = 0; i < 3; i++) files[`${DIR}/c${i}.json`] = recOf(`c${i}`, { closedAt: NOW - 10 * MIN, lastSeen: NOW - 10 * MIN })
  const w = world(on, { files, noMtimes: true })
  await start($)
  const first = w.reads.length
  await listed($)
  await listed($)
  expect(w.reads.slice(first).filter(p => p === `${DIR}/c0.json`).length).toBe(2)
  expect(w.logs.filter(l => l.includes('no modification times')).length).toBe(1)
})

test('a list that cannot read every record within its own time refuses, naming how many it read, before the 10 second budget (#911)', withConsumer, async ($, on) => {
  const w = world(on, { files: { [`${DIR}/o1.json`]: recOf('o1', { lastSeen: NOW - MIN }), [`${DIR}/slow.json`]: recOf('slow', { lastSeen: NOW - MIN }) } })
  await start($)
  w.hang(`${DIR}/slow.json`)
  const pending = call($, 'list')
  // Waits on the read having started, never on a fixed time (L290).
  await w.hangReached
  await w.clock.advance(9_000)
  const said = await pending
  w.unhang()
  expect(said).toMatch(/^list failed: session-registry read 2 of 3 session records within 8 seconds/)
})

test('a record moved away between the listing and its read is left out, never named unreadable (#911)', withConsumer, async ($, on) => {
  const w = world(on, { files: { [`${DIR}/o1.json`]: recOf('o1', { lastSeen: NOW - MIN }), [`${DIR}/moved.json`]: recOf('moved', { lastSeen: NOW - MIN }) } })
  await start($)
  w.vanish(`${DIR}/moved.json`)
  const l = await listed($)
  expect(l.unreadable).toEqual([])
  expect(ids(l.open)).toEqual(['o1', 's1'])
})
