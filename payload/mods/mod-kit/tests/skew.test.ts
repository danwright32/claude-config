import { expect, test } from 'claude-code/testing'
import { errorText, missingOf, skewNews, skewSentence } from '../hooks/skew.ts'

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
