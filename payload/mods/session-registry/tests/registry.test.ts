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
      if (verb === 'list') return { deny: JSON.stringify(await $.sessions.list()) }
      if (verb === 'edit') await $.sessions.noteEdit({ path: arg as string })
      if (verb === 'extra') await $.sessions.setExtra({ key: 'jobs', value: [arg] })
      return { deny: 'done' }
    })
  },
}
const withConsumer = { plugins: [consumer] }

// This Mac beneath the registry: a filesystem in memory, git, the session's id, the clock.
const world = (on: On, opts: { files?: Record<string, string>; id?: () => string; mtimes?: Record<string, number>; mvThrows?: boolean } = {}) => {
  const files: Record<string, string> = { ...(opts.files ?? {}) }
  const logs: string[] = []
  const removed: string[] = []
  const writes: string[] = []
  const finds: string[] = []
  // Each command run and the timeout it was given, so a bound can be asserted (#802).
  const bounds: [string, number | undefined][] = []
  mock.env(on, { HOME: '/Users/x' })
  const clock = mock.clock(on, { now: 100 * MIN })
  on('fs.write', ($, e) => {
    writes.push(e.path)
    files[e.path] = e.text
    return { value: undefined }
  })
  on('fs.read', ($, e) => {
    if (!(e.path in files)) throw new Error(`no file ${e.path}`)
    return { value: files[e.path] as string }
  })
  on('fs.exists', ($, e) => ({ value: e.path in files }) as never)
  on('fs.stat', ($, e) => {
    if (!(e.path in files)) throw new Error(`no file ${e.path}`)
    return { value: { kind: 'file', size: 1, mtimeMs: opts.mtimes?.[e.path] ?? 100 * MIN, isLink: false } } as never
  })
  on('fs.list', ($, e) => ({
    value: Object.keys(files)
      .filter(p => p.startsWith(e.path + '/') && !p.slice(e.path.length + 1).includes('/'))
      .map(p => ({ name: p.slice(e.path.length + 1), kind: 'file' as const })),
  }) as never)
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
      for (const f of rest.filter(x => !x.startsWith('-'))) {
        removed.push(f)
        delete files[f]
      }
      return ok()
    }
    if (cmd === 'mv' && a && b) {
      files[b] = files[a] as string
      delete files[a]
      return ok()
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
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }) as never)
  on('classic.SessionStart', () => ({}) as never)
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  on('ui.log', ($, e) => {
    logs.push(e.text)
    return { value: undefined }
  })
  const own = (id = 's1') => JSON.parse(files[`${DIR}/${id}.json`] ?? 'null')
  return { files, writes, finds, logs, removed, bounds, clock, own, hold, release: () => gate.release() }
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
  const w = world(on, { id: () => id })
  await start($)
  await $.session.end({ reason: 'clear', sessionId: 's1' } as never)
  const before = w.bounds.length
  id = 's2'
  await ($ as unknown as { classic: { SessionStart: (e: never) => Promise<unknown> } }).classic.SessionStart({ source: 'clear' } as never)
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

// #735: the new conversation's record is made when its id is first seen, never at the next beat, so
// for that minute /goals does not miss it and the goal tracker and job watcher do not write into
// the record session.end just closed. No clock moves in these three.
type Classic = { classic: { SessionStart: (e: never) => Promise<unknown> } }
test('after a /clear the new conversation has its record as its session start is announced, before any beat (#735)', withConsumer, async ($, on) => {
  let id = 's1'
  const w = world(on, { id: () => id })
  await start($)
  await $.session.end({ reason: 'clear', sessionId: 's1' } as never)
  id = 's2'
  await ($ as unknown as Classic).classic.SessionStart({ source: 'clear' } as never)
  expect(w.own('s1').closedAt).toBe(100 * MIN)
  expect(w.own('s2')).toMatchObject({ sessionId: 's2', closedAt: null, cwd: '/repo/app', edits: [], extra: {} })
})

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

test('writes held while the id cannot be read land on the record it has once the announced start finds it unchanged (#739)', withConsumer, async ($, on) => {
  let id: () => string = () => 's1'
  const w = world(on, { id: () => id() })
  await start($)
  await $.session.end({ reason: 'resume', sessionId: 's1' } as never)
  id = throwing
  await call($, 'edit /repo/a.ts')
  expect(w.own('s1').edits).toEqual([])
  id = () => 's1'
  await ($ as unknown as Classic).classic.SessionStart({ source: 'resume' } as never)
  expect(w.own('s1').edits).toEqual(['/repo/a.ts'])
})

test('a /clear that keeps the same id stops asking for it once the announced start has looked (#739)', withConsumer, async ($, on) => {
  let asks = 0
  world(on, {
    id: () => {
      asks++
      return 's1'
    },
  })
  await start($)
  await $.session.end({ reason: 'clear', sessionId: 's1' } as never)
  const before = asks
  await ($ as unknown as Classic).classic.SessionStart({ source: 'clear' } as never)
  expect(asks - before).toBe(1)
  await call($, 'edit /repo/a.ts')
  await call($, 'extra job-1')
  await call($, 'list')
  expect(asks - before).toBe(1)
})

// A read can come while the /clear is still under way (a pane drawn) and find the old id; it must
// not settle the question, or the new conversation's writes go to the closed record.
test('after a /clear, a read before the id changes does not stop the announced start making the new record (#739)', withConsumer, async ($, on) => {
  let id = 's1'
  const w = world(on, { id: () => id })
  await start($)
  await $.session.end({ reason: 'clear', sessionId: 's1' } as never)
  await call($, 'list')
  id = 's2'
  await ($ as unknown as Classic).classic.SessionStart({ source: 'clear' } as never)
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
test('an end that keeps its id reopens the record once the announced start finds the id unchanged (#751)', withConsumer, async ($, on) => {
  const w = world(on)
  await start($)
  await $.session.end({ reason: 'resume', sessionId: 's1' } as never)
  expect(w.own('s1').closedAt).toBe(100 * MIN)
  await ($ as unknown as Classic).classic.SessionStart({ source: 'resume' } as never)
  expect(w.own('s1').closedAt).toBe(null)
  const l = JSON.parse(await call($, 'list')) as { open: { sessionId: string }[] }
  expect(l.open.map(s => s.sessionId)).toEqual(['s1'])
})

test('an end that keeps its id is reopened by the beat too, when no start is announced (#751)', withConsumer, async ($, on) => {
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
  let id = 's1'
  const w = world(on, { id: () => id })
  await start($)
  await $.session.end({ reason: 'clear', sessionId: 's1' } as never)
  // The announcement arrives before the switch: it sees the old id and reopens the record.
  await ($ as unknown as Classic).classic.SessionStart({ source: 'clear' } as never)
  expect(w.own('s1').closedAt).toBe(null)
  id = 's2'
  await w.clock.advance(MIN + 1)
  expect(w.own('s1').closedAt).toBe(101 * MIN)
  expect(w.own('s2')).toMatchObject({ sessionId: 's2', closedAt: null })
})

test('the announced start says in the debug log which id it saw against the one session.end closed (#751)', withConsumer, async ($, on) => {
  let id = 's1'
  const w = world(on, { id: () => id })
  await start($)
  await $.session.end({ reason: 'clear', sessionId: 's1' } as never)
  id = 's2'
  await ($ as unknown as Classic).classic.SessionStart({ source: 'clear' } as never)
  expect(w.logs).toContain('session-registry: the announced start after a clear saw session id s2; session.end had closed s1, so the id had already switched.')
  await $.session.end({ reason: 'resume', sessionId: 's2' } as never)
  await ($ as unknown as Classic).classic.SessionStart({ source: 'resume' } as never)
  expect(w.logs).toContain('session-registry: the announced start after a resume saw session id s2; session.end had closed s2, so the id had not changed.')
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
const DAY = 24 * 60 * MIN
const NOW = 100 * MIN
const recOf = (id: string, over: Record<string, unknown>) =>
  JSON.stringify({ v: 1, sessionId: id, cwd: '/repo', repoRoot: '/repo', startedAt: NOW - 9 * DAY, lastSeen: NOW, closedAt: null, transcriptPath: null, edits: [], extra: {}, ...over })

test('a record closed more than 7 days ago is deleted at session start, a newer one is kept', withConsumer, async ($, on) => {
  const w = world(on, {
    files: {
      [`${DIR}/old.json`]: recOf('old', { closedAt: NOW - 8 * DAY, lastSeen: NOW - 8 * DAY }),
      [`${DIR}/recent.json`]: recOf('recent', { closedAt: NOW - 6 * DAY, lastSeen: NOW - 6 * DAY }),
    },
  })
  await start($)
  expect(w.removed).toEqual([`${DIR}/old.json`])
  expect(`${DIR}/recent.json` in w.files).toBe(true)
  expect(w.logs.filter(l => l.includes('old.json'))).toEqual([])
})

test('a crashed session, never closed and silent more than 7 days, is deleted too', withConsumer, async ($, on) => {
  const w = world(on, { files: { [`${DIR}/crashed.json`]: recOf('crashed', { lastSeen: NOW - 8 * DAY }) } })
  await start($)
  expect(w.removed).toEqual([`${DIR}/crashed.json`])
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

test('an open session is never deleted however long ago it started', withConsumer, async ($, on) => {
  const w = world(on, { files: { [`${DIR}/live.json`]: recOf('live', { startedAt: NOW - 30 * DAY, lastSeen: NOW - MIN }) } })
  await start($)
  expect(w.removed).toEqual([])
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
