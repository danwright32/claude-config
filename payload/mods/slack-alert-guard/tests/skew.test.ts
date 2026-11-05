import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { errorCode, errorText, missingOf, skewNews, skewSentence } from '../hooks/mod-kit/skew.ts'

// #1281: a mod calls another mod's noun as that mod is loaded in this session. A mod reloaded
// before the mod it depends on keeps the older one's members until it loads again (measured on
// Claude Code 2.1.302: a provider reloading afterwards does not reach it), so a member added since
// throws at the call site. These errors are made the way the engine makes them, by calling a
// member or a noun that is not there through an object spelled `$`, so the shapes read here are
// the runtime's own (measured identical under `claude plugin test` and a real session).
const thrown = async (fn: () => Promise<unknown>): Promise<unknown> => {
  try {
    await fn()
  } catch (err) {
    return err
  }
  throw new Error('it did not throw')
}
const $ = { modkit: { pipeline: async () => [] }, scopeModes: {} } as unknown as {
  modkit: { pipeline: () => Promise<unknown>; mergeHelper: (c: unknown) => Promise<unknown> }
  scopeModes: { hold: (x: unknown) => Promise<unknown> }
  isItLive: { verdict: (x: unknown) => Promise<unknown> }
}
const DASHES = new RegExp(`[${String.fromCharCode(0x2014)}${String.fromCharCode(0x2013)}]`)

test('a member the loaded copy of a mod lacks is read as a skew, naming the noun, the member and the mod', async () => {
  const err = await thrown(() => $.modkit.mergeHelper({ words: [] }))
  expect(missingOf(err)).toEqual({ kind: 'member', noun: 'modkit', member: 'mergeHelper', provider: 'mod-kit' })
  expect(missingOf(await thrown(() => $.scopeModes.hold({})))).toEqual({ kind: 'member', noun: 'scopeModes', member: 'hold', provider: 'scope-modes' })
})

test('a noun named apart from its mod names that mod', async () => {
  const $ = { jobs: {}, sessions: {}, statusbar: {} } as unknown as {
    jobs: { list: () => Promise<unknown> }
    sessions: { list: () => Promise<unknown> }
    statusbar: { setModes: () => Promise<unknown> }
  }
  expect(missingOf(await thrown(() => $.jobs.list()))?.provider).toBe('job-watcher')
  expect(missingOf(await thrown(() => $.sessions.list()))?.provider).toBe('session-registry')
  expect(missingOf(await thrown(() => $.statusbar.setModes()))?.provider).toBe('status-bar')
})

test('a noun no loaded mod provides is read as that mod being absent, never as a skew', async () => {
  expect(missingOf(await thrown(() => $.isItLive.verdict({})))).toEqual({ kind: 'noun', noun: 'isItLive', member: 'verdict', provider: 'is-it-live' })
})

// A guard's .catch handler reads why its hook failed as plain data (next.error), the thrown
// TypeError's message without its class: measured {"kind":"throw","message":"$.prov.b is not a
// function. (In '$.prov.b()', '$.prov.b' is undefined)","budget":1000}.
test("a hook's failure as its .catch handler reads it is read the same way", async () => {
  const err = (await thrown(() => $.modkit.mergeHelper({}))) as Error
  expect(missingOf({ kind: 'throw', message: err.message, budget: 1000 })).toEqual({ kind: 'member', noun: 'modkit', member: 'mergeHelper', provider: 'mod-kit' })
  expect(missingOf({ kind: 'throw', message: 'gh exited 1', budget: 1000 })).toBeNull()
  expect(missingOf({ kind: 'timeout', budget: 1000 })).toBeNull()
  expect(errorText({ kind: 'throw', message: err.message, budget: 1000 }, 'collision-guard')).toMatch(/^collision-guard and mod-kit are out of step/)
  expect(errorText({ kind: 'throw', message: 'gh exited 1', budget: 1000 }, 'collision-guard')).toBe('gh exited 1')
  expect(errorText({ kind: 'timeout', budget: 1000 }, 'collision-guard')).toBe('it ran out of time')
})

test("anything else is neither: a mod's own failure, another TypeError, a string", async () => {
  expect(missingOf(new Error('$.modkit.mergeHelper is not a function'))).toBeNull()
  expect(missingOf(await thrown(async () => (null as unknown as { x: number }).x))).toBeNull()
  expect(missingOf(new TypeError('cannot read the band'))).toBeNull()
  expect(missingOf('$.modkit.mergeHelper is not a function')).toBeNull()
  expect(missingOf(undefined)).toBeNull()
})

test('the one sentence names both mods, the member, and the remedy, with no dash', async () => {
  const m = missingOf(await thrown(() => $.modkit.mergeHelper({}))) as NonNullable<ReturnType<typeof missingOf>>
  const said = skewSentence('scope-modes', m)
  expect(said).toBe(
    'scope-modes and mod-kit are out of step in this session: the mod-kit loaded here has no mergeHelper, which scope-modes needs, so a mod was updated after this session loaded it. A new session loads them together.',
  )
  expect(DASHES.test(said)).toBe(false)
})

test("an error's text is its message, and a skew's is the one sentence", async () => {
  expect(errorText(new Error('gh exited 1'), 'is-it-live')).toBe('gh exited 1')
  expect(errorText('plain words', 'is-it-live')).toBe('plain words')
  const skew = await thrown(() => $.modkit.mergeHelper({}))
  expect(errorText(skew, 'is-it-live')).toBe(skewSentence('is-it-live', missingOf(skew) as NonNullable<ReturnType<typeof missingOf>>))
  // An absent noun keeps its own message: what absence means is each caller's rule.
  const absent = await thrown(() => $.isItLive.verdict({}))
  expect(errorText(absent, 'scope-modes')).toBe(String((absent as Error).message))
})

// #2150: a call the engine refuses or fails arrives led by the engine's own name for it, which is
// shorthand Dan cannot read ("scope-modes: $.fs.read: EACCES: ..."). Two shapes are measured: a
// refusal ("<mod>: $.noun.member: <reason>", as the test kit's deny and the real engine's denied
// reads say it) and a failure ("<mod>: $.fs.stat(<path>) failed: ENOENT", the real engine, measured
// 2026-11-01). The text keeps which kind of failure it was, in words, and the path it was about.
test('a refused file read is said in plain words: what could not be done, why, and the path', async () => {
  expect(errorText(new Error("scope-modes: $.fs.read: EACCES: permission denied, open '/Users/x/.claude/state/place.json'"), 'scope-modes')).toBe(
    'the file could not be read: permission denied (/Users/x/.claude/state/place.json)',
  )
  expect(errorText(new Error('scope-modes: $.fs.stat(/Users/x/.claude/LESSONS.md) failed: ENOENT'), 'scope-modes')).toBe(
    'the file could not be looked up: there is no such file or folder (/Users/x/.claude/LESSONS.md)',
  )
  expect(errorText(new Error("job-watcher: $.fs.list: ENOTDIR: not a directory, scandir '/a/b'"), 'job-watcher')).toBe('the folder could not be listed: a part of its path is not a folder (/a/b)')
  expect(errorText(new Error('design-round-guard: $.fs.write: ENOSPC'), 'design-round-guard')).toBe('the file could not be written: the disk is full')
  expect(errorText(new Error('handoff: $.fs.exists: EACCES: /w/locked'), 'handoff')).toBe('whether the file is there could not be checked: permission denied (/w/locked)')
  // A hook's failure as its .catch handler reads it carries the same message.
  expect(errorText({ kind: 'throw', message: 'area-check: $.fs.read: EPERM: operation not permitted', budget: 1000 }, 'area-check')).toBe('the file could not be read: the operation is not permitted')
})

test('a failure the plain words do not cover keeps its own text, only without the engine prefix (L11)', async () => {
  // A code with no plain words keeps the engine's own reason, never a blank or a generic failure.
  expect(errorText(new Error("scope-modes: $.fs.read: EXDEV: cross-device link not permitted, rename '/a' -> '/b'"), 'scope-modes')).toBe(
    "the file could not be read: EXDEV: cross-device link not permitted, rename '/a' -> '/b'",
  )
  // A call that is not a file's keeps its reason as given.
  expect(errorText(new Error('area-check: $.process.run: git log was still running after 5000 ms'), 'area-check')).toBe('git log was still running after 5000 ms')
  expect(errorText(new Error('status-bar: $.process.run(gh) failed: EACCES'), 'status-bar')).toBe('permission denied (gh)')
  // An abandoned command's refusal has no reason after it, and /sleep reads it as abandoned (#1677).
  expect(errorText(new Error('scope-modes: $.process.run(mkdir) aborted'), 'scope-modes')).toBe('scope-modes: $.process.run(mkdir) aborted')
  // Nothing else is touched.
  expect(errorText(new Error('gh exited 1'), 'scope-modes')).toBe('gh exited 1')
  expect(errorText(new Error('EACCES: permission denied'), 'scope-modes')).toBe('EACCES: permission denied')
  for (const said of [
    errorText(new Error("scope-modes: $.fs.read: EACCES: permission denied, open '/p'"), 'scope-modes'),
    errorText(new Error('scope-modes: $.fs.stat(/p) failed: EBUSY'), 'scope-modes'),
  ]) {
    expect(said).not.toContain('$.')
    expect(said).not.toContain('scope-modes:')
    expect(DASHES.test(said)).toBe(false)
  }
})

test("a failed call's code is read from the engine's own text, for a caller deciding by it", async () => {
  expect(errorCode(new Error('job-watcher: $.fs.stat(/tmp/out) failed: ENOENT'))).toBe('ENOENT')
  expect(errorCode(new Error("scope-modes: $.fs.read: EACCES: permission denied, open '/p'"))).toBe('EACCES')
  expect(errorCode(Object.assign(new Error('gone'), { code: 'ENOENT' }))).toBe('ENOENT')
  expect(errorCode({ kind: 'throw', message: 'x: $.fs.stat(/p) failed: ENOTDIR', budget: 1000 })).toBe('ENOTDIR')
  expect(errorCode(new Error('area-check: $.process.run: git log was still running after 5000 ms'))).toBeNull()
  expect(errorCode(new Error('gh exited 1'))).toBeNull()
  expect(errorCode(undefined)).toBeNull()
})

// A path may hold a bracket ("/tmp/out (1)/job.log"), and a reading that stopped the path at the
// first ")" found no engine call at all: no code, so job-watcher never judged a gone file gone,
// and the engine's own text shown in place of the words.
test("a failed call's code and words are read whatever its path holds, a bracket included", async () => {
  expect(errorCode(new Error('job-watcher: $.fs.stat(/tmp/out (1)/job.log) failed: ENOENT'))).toBe('ENOENT')
  expect(errorCode(new Error('job-watcher: $.fs.stat(/tmp/a)b/job.log) failed: EACCES'))).toBe('EACCES')
  expect(errorText(new Error('scope-modes: $.fs.stat(/tmp/out (1)/job.log) failed: ENOENT'), 'scope-modes')).toBe(
    'the file could not be looked up: there is no such file or folder (/tmp/out (1)/job.log)',
  )
})

test('the news of a skew is given once per mod and member in a load, and never for anything else', async () => {
  const a = await thrown(() => $.modkit.mergeHelper({}))
  const b = await thrown(() => $.modkit.mergeHelper({}))
  expect(skewNews(a, 'news-mod')).toBe(skewSentence('news-mod', missingOf(a) as NonNullable<ReturnType<typeof missingOf>>))
  expect(skewNews(b, 'news-mod')).toBeNull()
  // Another mod's copy, or another member, is news of its own.
  expect(skewNews(b, 'other-mod')).not.toBeNull()
  expect(skewNews(await thrown(() => $.scopeModes.hold({})), 'news-mod')).not.toBeNull()
  expect(skewNews(new Error('gh exited 1'), 'news-mod')).toBeNull()
  expect(skewNews(await thrown(() => $.isItLive.verdict({})), 'news-mod')).toBeNull()
})
