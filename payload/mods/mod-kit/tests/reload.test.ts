import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

// #960, measured 2026-10-08 with throwaway mods in a session this suite never touches: when one
// delivery changes mod-kit AND a mod that starts using something mod-kit only now provides (the
// steps card hooking modkit.press, #946), an open session reloads the changed mods dependents first.
// That mod is then built against the mod-kit still loaded, which lacks the new member, so Claude Code
// unloads it (its tools go, "MCP server removed from the configuration") while its notice says "the
// previous version stays loaded". Nothing retries it once mod-kit has reloaded. A busy session
// reloads the whole delivery at its turn's end in that same order, so writing mod-kit first does not
// help. A save to the mod's folder after mod-kit has reloaded loads it again, and that is what
// mod-kit does here, from its own reload: it touches every mod that depends on it and changed since
// mod-kit last started in this session.

const T0 = 1_791_000_000_000
const MIN = 60_000

type Mod = { deps?: string[]; mtimeMs: number; manifest?: string; touchedAt?: number; noHooks?: boolean; noManifest?: boolean; manifestUnreadable?: boolean }

// The mods folder beneath mod-kit: each mod's manifest and its files' times, wherever the folder is.
const world = (on: On, init: { mods: Record<string, Mod>; touchFails?: string[]; homeUnreadable?: boolean; duringTouch?: (name: string, now: number) => void }) => {
  const mods = init.mods
  const touched: string[] = []
  const argv: string[][] = []
  const logs: string[] = []
  const clock = mock.clock(on, { now: T0 })
  const modOf = (path: string) => {
    const parts = path.split('/')
    const at = parts.findIndex(p => p in mods)
    return at < 0 ? undefined : { name: parts[at] as string, rest: parts.slice(at + 1).join('/') }
  }
  on('fs.list', ($, e) => {
    const m = modOf(e.path)
    if (!m) {
      if (init.homeUnreadable) throw new Error(`EACCES: permission denied, scandir '${e.path}'`)
      // The folder holding every mod: one directory per mod, and a stray file beside them.
      return { value: [...Object.keys(mods).map(name => ({ name, kind: 'dir' as const, size: 0, mtimeMs: 0, isLink: false })), { name: 'account-room-nicknames.json', kind: 'file' as const, size: 1, mtimeMs: T0 + 9 * MIN, isLink: false }] } as never
    }
    const mod = mods[m.name] as Mod
    if (m.rest === '.claude-plugin') return { value: [{ name: 'plugin.json', kind: 'file', size: 1, mtimeMs: mod.touchedAt ?? mod.mtimeMs, isLink: false }, { name: 'types', kind: 'dir', size: 0, mtimeMs: 0, isLink: false }] } as never
    if (m.rest === 'hooks' && mod.noHooks) throw new Error(`ENOENT: no such file or directory, scandir '${e.path}'`)
    if (m.rest === 'hooks') return { value: [{ name: 'hooks.json', kind: 'file', size: 1, mtimeMs: T0 - 99 * MIN, isLink: false }, { name: 'register.ts', kind: 'file', size: 1, mtimeMs: mod.mtimeMs, isLink: false }] } as never
    throw new Error(`ENOENT: ${e.path}`)
  })
  on('fs.exists', ($, e) => {
    const m = modOf(e.path)
    const mod = m && (mods[m.name] as Mod)
    return { value: !!mod && !(m.rest === 'hooks' && mod.noHooks) && !(m.rest === '.claude-plugin/plugin.json' && mod.noManifest) } as never
  })
  on('fs.stat', ($, e) => {
    const m = modOf(e.path)
    const mod = m && (mods[m.name] as Mod)
    if (!mod || m.rest !== '.claude-plugin/plugin.json' || mod.noManifest) throw new Error(`ENOENT: ${e.path}`)
    return { value: { kind: 'file', size: 1, mtimeMs: mod.touchedAt ?? mod.mtimeMs, isLink: false } } as never
  })
  on('fs.read', ($, e) => {
    const m = modOf(e.path)
    if (!m || m.rest !== '.claude-plugin/plugin.json') throw new Error(`ENOENT: ${e.path}`)
    const mod = mods[m.name] as Mod
    if (mod.noManifest) throw new Error(`ENOENT: ${e.path}`)
    if (mod.manifestUnreadable) throw new Error(`EACCES: permission denied, open '${e.path}'`)
    return { value: mod.manifest ?? JSON.stringify({ name: m.name, version: '0.1.0', ...(mod.deps ? { dependencies: mod.deps } : {}) }) } as never
  })
  on('process.run', async ($, e) => {
    const r = (exitCode: number, stderr = '') => ({ value: { exitCode, stdout: '', stderr, isStdoutTruncated: false, isStderrTruncated: false } })
    argv.push([...e.argv])
    if (e.argv[0] !== 'touch') return r(1, 'unexpected')
    const path = e.argv[e.argv.length - 1] as string
    if (init.touchFails?.some(name => path.includes(`/${name}/`))) return r(1, `touch: ${path}: Permission denied`)
    touched.push(path)
    // A touch takes a few milliseconds and stamps the manifest with the time it ran, after mod-kit
    // read the clock at its start: the mocked clock stands still unless moved, the disk's does not.
    await clock.advance(5)
    const m = modOf(path)
    if (m) (mods[m.name] as Mod).touchedAt = clock.now()
    if (m) init.duringTouch?.(m.name, clock.now())
    return r(0)
  })
  on('ui.log', ($, e) => {
    logs.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  on('command.register', ($, e) => ({ value: { command: e.name } }) as never)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  // Which of the mods a touch reached, by name, each time one did.
  const reached = () => touched.map(p => modOf(p)?.name + ':' + modOf(p)?.rest)
  return { touched, argv, reached, logs, clock }
}

type Starter = { session: { start: (e: never) => Promise<unknown> } }
const start = ($: unknown) => ($ as Starter).session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)

// The delivery of #946: mod-kit and the steps card changed together, minutes after the session began.
const delivery = (): Record<string, Mod> => ({
  'mod-kit': { mtimeMs: T0 + 5 * MIN },
  'manual-steps': { deps: ['mod-kit'], mtimeMs: T0 + 5 * MIN },
  'is-it-live': { deps: ['mod-kit'], mtimeMs: T0 - 60 * MIN },
  'session-registry': { mtimeMs: T0 + 5 * MIN },
  'goal-tracker': { deps: ['session-registry'], mtimeMs: T0 + 5 * MIN },
})

test("mod-kit's reload makes a mod that depends on it and changed since its last start load again", async ($, on) => {
  const w = world(on, { mods: delivery() })
  await start($)
  await w.clock.advance(10 * MIN)
  await start($)
  // Exactly once, and only the steps card: is-it-live has not changed since mod-kit started, and
  // goal-tracker depends on another mod, so neither is reloaded for nothing.
  expect(w.reached()).toEqual(['manual-steps:.claude-plugin/plugin.json'])
  // A touch that changes only the time, so the sync sees no difference to carry and nothing a
  // delivery just wrote can be overwritten with an older copy.
  expect(w.touched.every(p => p.endsWith('/manual-steps/.claude-plugin/plugin.json'))).toBe(true)
})

test('the touch is a time change alone, never a rewrite of the file', async ($, on) => {
  const w = world(on, { mods: delivery() })
  await start($)
  await w.clock.advance(10 * MIN)
  await start($)
  expect(w.argv.length).toBe(1)
  expect(w.argv[0]?.slice(0, 2)).toEqual(['touch', '-c'])
})

test("the session's own start loads every mod as it is on disk, so it touches nothing", async ($, on) => {
  const w = world(on, { mods: delivery() })
  await w.clock.advance(10 * MIN)
  await start($)
  expect(w.touched).toEqual([])
})

test('a second reload with nothing new since the first touches nothing more', async ($, on) => {
  const w = world(on, { mods: delivery() })
  await start($)
  await w.clock.advance(10 * MIN)
  await start($)
  await w.clock.advance(10 * MIN)
  await start($)
  expect(w.reached()).toEqual(['manual-steps:.claude-plugin/plugin.json'])
})

test('a touch that fails is said, naming the mod and that a new session brings it back, and the rest are still touched', async ($, on) => {
  const mods = { ...delivery(), handoff: { deps: ['mod-kit'], mtimeMs: T0 + 5 * MIN } }
  const w = world(on, { mods, touchFails: ['manual-steps'] })
  await start($)
  await w.clock.advance(10 * MIN)
  await start($)
  expect(w.reached()).toEqual(['handoff:.claude-plugin/plugin.json'])
  const said = w.logs.filter(l => l.includes('manual-steps'))
  expect(said.length).toBe(1)
  expect(said[0]).toContain('Permission denied')
  expect(said[0]).toContain('new session')
})

test("a mod whose manifest cannot be read is said and skipped, and the session's start still completes", async ($, on) => {
  const mods = { ...delivery(), 'half-written': { deps: ['mod-kit'], mtimeMs: T0 + 5 * MIN, manifest: '{ "name": "half-wr' } }
  const w = world(on, { mods })
  await start($)
  await w.clock.advance(10 * MIN)
  const r = (await start($)) as { cwd?: string }
  expect(r.cwd).toBe('/repo')
  expect(w.reached()).toEqual(['manual-steps:.claude-plugin/plugin.json'])
  expect(w.logs.filter(l => l.includes('half-written')).length).toBe(1)
})

test('a mods folder that cannot be listed is said, and the start still completes', async ($, on) => {
  const w = world(on, { mods: delivery(), homeUnreadable: true })
  await start($)
  await w.clock.advance(10 * MIN)
  const r = (await start($)) as { cwd?: string }
  expect(r.cwd).toBe('/repo')
  expect(w.touched).toEqual([])
  // The kit turns a throwing answer into a missing one, so the reason it gives is its own.
  expect(w.logs.filter(l => l.includes('mods folder') && l.includes('could not be read') && l.includes('new session')).length).toBe(1)
})

// #967 review: a mod whose touch failed, or that went unexamined because the folder could not be
// listed, is still unloaded, so the next reload must try it again rather than count it as done.
test('a mod whose touch failed is tried again at the next reload', async ($, on) => {
  const init = { mods: delivery(), touchFails: ['manual-steps'] }
  const w = world(on, init)
  await start($)
  await w.clock.advance(10 * MIN)
  await start($)
  expect(w.reached()).toEqual([])
  init.touchFails = []
  await w.clock.advance(10 * MIN)
  await start($)
  expect(w.reached()).toEqual(['manual-steps:.claude-plugin/plugin.json'])
})

test('a mods folder that could not be listed is listed again at the next reload', async ($, on) => {
  const init = { mods: delivery(), homeUnreadable: true }
  const w = world(on, init)
  await start($)
  await w.clock.advance(10 * MIN)
  await start($)
  expect(w.reached()).toEqual([])
  init.homeUnreadable = false
  await w.clock.advance(10 * MIN)
  await start($)
  expect(w.reached()).toEqual(['manual-steps:.claude-plugin/plugin.json'])
})

// #967 review, second round: one mod that keeps failing must not make the others' own touches
// read as changes at every later reload, and a dependent with no hooks folder has no module, so no
// tools to lose: it is passed over, not counted as a failure.
test('while one mod keeps failing, a mod touched at one reload is not touched again at the next', async ($, on) => {
  const mods = { ...delivery(), handoff: { deps: ['mod-kit'], mtimeMs: T0 + 5 * MIN } }
  const w = world(on, { mods, touchFails: ['handoff'] })
  await start($)
  for (let i = 0; i < 3; i++) {
    await w.clock.advance(10 * MIN)
    await start($)
  }
  expect(w.reached()).toEqual(['manual-steps:.claude-plugin/plugin.json'])
  // The failing one is still tried, and said, at every reload.
  expect(w.logs.filter(l => l.includes('handoff')).length).toBe(3)
})

test('a dependent with no hooks folder is passed over without a failure, and holds nothing back', async ($, on) => {
  const mods = { ...delivery(), 'no-hooks': { deps: ['mod-kit'], mtimeMs: T0 + 5 * MIN, noHooks: true } }
  const w = world(on, { mods })
  await start($)
  await w.clock.advance(10 * MIN)
  await start($)
  await w.clock.advance(10 * MIN)
  await start($)
  expect(w.reached()).toEqual(['manual-steps:.claude-plugin/plugin.json'])
  expect(w.logs.filter(l => l.includes('no-hooks'))).toEqual([])
})

// #967 review, third round. A manifest that is there but cannot be read is a mod that may be
// unloaded, not a folder that is no mod: it is said and asked again. And a delivery landing while a
// reload is still asking must not be lost: the next reload compares against the time the pass began,
// with mod-kit's own touches told apart by the time each one left.
test('a manifest that is there but cannot be read is said and asked again; a folder with none stays silent', async ($, on) => {
  const mods = { ...delivery(), locked: { deps: ['mod-kit'], mtimeMs: T0 + 5 * MIN, manifestUnreadable: true }, 'not-a-mod': { mtimeMs: T0 + 5 * MIN, noManifest: true } }
  const w = world(on, { mods })
  await start($)
  await w.clock.advance(10 * MIN)
  await start($)
  // The kit turns a throwing answer into a missing one, so the reason in the line is its own.
  expect(w.logs.filter(l => l.includes('locked') && l.includes('could not be asked')).length).toBe(1)
  expect(w.logs.filter(l => l.includes('not-a-mod'))).toEqual([])
  ;(mods.locked as Mod).manifestUnreadable = false
  await w.clock.advance(10 * MIN)
  await start($)
  expect(w.reached()).toEqual(['manual-steps:.claude-plugin/plugin.json', 'locked:.claude-plugin/plugin.json'])
})

test('a delivery that lands while a reload is asking is still asked about at the next reload', async ($, on) => {
  const mods: Record<string, Mod> = { 'a-steps': { deps: ['mod-kit'], mtimeMs: T0 - 60 * MIN }, ...delivery() }
  // a-steps is looked at first and is unchanged; while manual-steps is being touched, a delivery
  // writes a-steps' module.
  const w = world(on, { mods, duringTouch: (name, now) => { if (name === 'manual-steps') (mods['a-steps'] as Mod).mtimeMs = now } })
  await start($)
  await w.clock.advance(10 * MIN)
  await start($)
  expect(w.reached()).toEqual(['manual-steps:.claude-plugin/plugin.json'])
  await w.clock.advance(10 * MIN)
  await start($)
  expect(w.reached()).toEqual(['manual-steps:.claude-plugin/plugin.json', 'a-steps:.claude-plugin/plugin.json'])
})
