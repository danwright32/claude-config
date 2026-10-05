import { expect, mock, test } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'

const MIN = 60_000
const T0 = 1_000 * MIN

type Msg = { role: 'user' | 'assistant'; text: string; toolUses: never[] }
type Reply = string | { failed: 'api-error' | 'empty-reply' | 'aborted' } | 'throws'
type Rename = 'set' | 'refused' | 'refused-for-mod' | 'unknown' | 'throws'
type Opts = { replies?: Reply[]; rename?: Rename; messages?: Msg[]; messagesThrow?: boolean; holdHaiku?: Promise<void>; holdRename?: Promise<void> }

const exchange = (): Msg[] => [
  { role: 'user', text: 'Build the auto session name mod from issue 635', toolUses: [] },
  { role: 'assistant', text: 'Reading the issue and the mod API first.', toolUses: [] },
]

// The engine beneath the mod: the clock, the session, Haiku and the built-in /rename. Every Haiku
// prompt, every rename asked of the engine and every transcript line is recorded.
const world = (on: On, o: Opts = {}) => {
  const w = {
    prompts: [] as string[],
    renames: [] as { args: string; origin: unknown }[],
    logs: [] as string[],
    debug: [] as string[],
    messages: o.messages ?? exchange(),
  }
  const clock = mock.clock(on, { now: T0 })
  on('session.id', () => ({ value: 's1' }) as never)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.messages', () => {
    if (o.messagesThrow) return { deny: 'transcript unavailable' } as never
    return { value: w.messages } as never
  })
  let replies = 0
  on('model.complete', async ($, e) => {
    if (o.holdHaiku) await o.holdHaiku
    w.prompts.push((e as unknown as { prompt: string }).prompt)
    const r = o.replies?.[replies++] ?? 'Auto session name mod'
    if (r === 'throws') return { deny: 'model blocked by policy' } as never
    if (typeof r === 'string') return { value: { isAnswered: true, text: r, usage: {} } } as never
    return { value: { isAnswered: false, reason: r.failed, status: r.failed === 'api-error' ? 529 : undefined, error: 'overloaded', usage: {} } } as never
  })
  on('command.run', { command: 'rename' }, async ($, e) => {
    w.renames.push({ args: e.args, origin: e.origin })
    if (o.holdRename && (e.origin as { kind?: string } | undefined)?.kind === 'plugin') await o.holdRename
    const fromMod = (e.origin as { kind?: string } | undefined)?.kind === 'plugin'
    const how = o.rename === 'refused-for-mod' ? (fromMod ? 'refused' : 'set') : (o.rename ?? 'set')
    // A hook that throws is skipped, so nothing answers and $.command.run rejects.
    if (how === 'throws') throw new Error('rename is not available to plugins')
    if (how === 'refused') return { text: 'Cannot rename: This session is a teammate. Teammate names are set by the team leader.' }
    if (how === 'unknown') return {}
    return { text: `Session renamed to: ${e.args}` }
  })
  on('classic.UserPromptSubmit', () => ({}))
  on('classic.SessionStart', () => ({}))
  on('turn.complete', ($, e) => ({ text: e.answer }))
  on('ui.log', ($, e) => {
    ;(e.to === 'debug' ? w.debug : w.logs).push(e.text)
    return { value: undefined }
  })
  return { ...w, clock }
}

type T = {
  session: { start: (e: never) => Promise<unknown> }
  turn: { complete: (e: never) => Promise<unknown> }
  classic: { UserPromptSubmit: (e: never) => Promise<unknown>; SessionStart: (e: never) => Promise<unknown> }
  command: { run: (e: never) => Promise<unknown> }
}
const start = ($: T, isInteractive = true) => $.session.start({ cwd: '/repo', surface: isInteractive ? 'terminal' : null, isInteractive } as never)
const turnEnds = ($: T, agentId?: string) =>
  $.turn.complete({ answer: 'done', durationMs: 10, isAborted: false, turnId: 't', reason: 'answer', ...(agentId ? { agentId } : {}) } as never)
const prompt = ($: T, fields: Record<string, unknown> = {}) =>
  $.classic.UserPromptSubmit({ prompt: 'next thing', source: 'user', ...fields } as never) as Promise<{ sessionTitle?: string }>

test('an unnamed session is named once, ten minutes after it starts, silently', async ($, on) => {
  const w = world(on)
  await start($)
  await w.clock.advance(10 * MIN - 1)
  expect(w.prompts.length).toBe(0)
  await w.clock.advance(1)
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]).toContain('Build the auto session name mod from issue 635')
  expect(w.renames.map(r => r.args)).toEqual(['Auto session name mod'])
  expect(w.logs).toEqual([])
  // Nothing more for the rest of the session: no refresh, no second Haiku call.
  await turnEnds($)
  await w.clock.advance(60 * MIN)
  await turnEnds($)
  await w.clock.settle()
  expect(w.prompts.length).toBe(1)
  expect(w.renames.length).toBe(1)
})

test('a session with nothing asked at ten minutes is named after its first exchange', async ($, on) => {
  const w = world(on, { messages: [] })
  await start($)
  await w.clock.advance(10 * MIN)
  expect(w.prompts.length).toBe(0)
  expect(w.renames.length).toBe(0)
  expect(w.logs).toEqual([])
  // The person asks; the turn is still running, so only the request is there.
  w.messages.push(exchange()[0] as Msg)
  await turnEnds($, undefined).catch(() => undefined)
  await w.clock.settle()
  expect(w.prompts.length).toBe(0)
  w.messages.push(exchange()[1] as Msg)
  await turnEnds($)
  await w.clock.settle()
  expect(w.prompts.length).toBe(1)
  expect(w.renames.map(r => r.args)).toEqual(['Auto session name mod'])
})

test('a first exchange before ten minutes does not name it early', async ($, on) => {
  const w = world(on)
  await start($)
  await turnEnds($)
  await w.clock.settle()
  expect(w.prompts.length).toBe(0)
  await w.clock.advance(10 * MIN)
  expect(w.renames.length).toBe(1)
})

test('a subagent finishing its turn is not an idle point of the session', async ($, on) => {
  const w = world(on, { messages: [] })
  await start($)
  await w.clock.advance(10 * MIN)
  w.messages.push(...exchange())
  await turnEnds($, 'agent-1')
  await w.clock.settle()
  expect(w.prompts.length).toBe(0)
  await turnEnds($)
  await w.clock.settle()
  expect(w.prompts.length).toBe(1)
})

test('a session resumed with a name is left alone', async ($, on) => {
  const w = world(on)
  await $.classic.SessionStart({ source: 'resume', session_title: 'Invoice rework' } as never)
  await start($)
  await w.clock.advance(10 * MIN)
  expect(w.prompts.length).toBe(0)
  expect(w.renames.length).toBe(0)
  expect(w.logs).toEqual([])
})

test('a name Dan sets with /rename during the ten minutes wins', async ($, on) => {
  const w = world(on)
  await start($)
  await w.clock.advance(4 * MIN)
  await $.command.run({ command: 'rename', args: 'My own name' } as never)
  await w.clock.advance(6 * MIN)
  expect(w.prompts.length).toBe(0)
  expect(w.renames.map(r => r.args)).toEqual(['My own name'])
})

test('a name seen on a message during the ten minutes wins too', async ($, on) => {
  const w = world(on)
  await start($)
  await prompt($, { session_title: 'Named elsewhere' })
  await w.clock.advance(10 * MIN)
  expect(w.prompts.length).toBe(0)
  expect(w.renames.length).toBe(0)
})

test('a rename Dan makes while Haiku is answering wins over the name it returns', async ($, on) => {
  let release = () => undefined as void
  const w = world(on, { holdHaiku: new Promise<void>(r => (release = r)) })
  await start($)
  const due = w.clock.advance(10 * MIN)
  await w.clock.settle()
  await $.command.run({ command: 'rename', args: 'Mine' } as never)
  release()
  await due
  await w.clock.settle()
  expect(w.renames.map(r => r.args)).toEqual(['Mine'])
})

test('a reload of the mod does not name twice, nor restart the ten minutes', async ($, on) => {
  const w = world(on)
  await start($)
  await w.clock.advance(6 * MIN)
  // A hot reload fires session.start again; the ten minutes still count from the first start.
  await start($)
  await w.clock.advance(4 * MIN)
  expect(w.renames.length).toBe(1)
  await start($)
  await w.clock.advance(20 * MIN)
  await turnEnds($)
  await w.clock.settle()
  expect(w.prompts.length).toBe(1)
  expect(w.renames.length).toBe(1)
})

test('a claude -p run is never named', async ($, on) => {
  const w = world(on)
  await start($, false)
  await w.clock.advance(10 * MIN)
  await turnEnds($)
  await w.clock.settle()
  expect(w.prompts.length).toBe(0)
  expect(w.renames.length).toBe(0)
})

test('a quoted reply with a dash is cleaned before it is used', async ($, on) => {
  const w = world(on, { replies: ['"Status bar - band layout."\nExtra words'] })
  await start($)
  await w.clock.advance(10 * MIN)
  expect(w.renames.map(r => r.args)).toEqual(['Status bar band layout'])
  expect(w.logs).toEqual([])
})

test('an empty reply is refused with one line, and retried once at the next idle point', async ($, on) => {
  const w = world(on, { replies: ['  ', 'Second try name'] })
  await start($)
  await w.clock.advance(10 * MIN)
  expect(w.renames.length).toBe(0)
  expect(w.logs).toEqual(["Auto session name couldn't name this session: Haiku's reply was empty. It will try once more when the session is next idle."])
  await turnEnds($)
  await w.clock.settle()
  expect(w.prompts.length).toBe(2)
  expect(w.renames.map(r => r.args)).toEqual(['Second try name'])
  expect(w.logs.length).toBe(1)
})

test('a reply too long to be a name is refused', async ($, on) => {
  const w = world(on, { replies: ['This is a very long name that goes on well past six words', 'Short one'] })
  await start($)
  await w.clock.advance(10 * MIN)
  expect(w.renames.length).toBe(0)
  expect(w.logs[0]).toContain("Haiku's reply was too long to be a name")
})

test('a failed call gives one line and exactly one retry, then gives up with a second line', async ($, on) => {
  const w = world(on, { replies: [{ failed: 'api-error' }, { failed: 'aborted' }, 'Never asked'] })
  await start($)
  await w.clock.advance(10 * MIN)
  expect(w.logs).toEqual(["Auto session name couldn't name this session: Haiku returned an error (529). It will try once more when the session is next idle."])
  await turnEnds($)
  await w.clock.settle()
  expect(w.logs[1]).toBe("Auto session name couldn't name this session: Haiku did not answer within 30 seconds. It won't try again, so /rename names it.")
  // No retry loop beyond that one.
  await turnEnds($)
  await w.clock.advance(60 * MIN)
  await turnEnds($)
  await w.clock.settle()
  expect(w.prompts.length).toBe(2)
  expect(w.renames.length).toBe(0)
  expect(w.logs.length).toBe(2)
})

test('a model call the engine refuses is a failure that gives its reason', async ($, on) => {
  const w = world(on, { replies: ['throws'] })
  await start($)
  await w.clock.advance(10 * MIN)
  expect(w.logs[0]).toContain('the call to Haiku was refused (model blocked by policy)')
})

test('an unreadable conversation is a failure that names it', async ($, on) => {
  const w = world(on, { messagesThrow: true })
  await start($)
  await w.clock.advance(10 * MIN)
  expect(w.prompts.length).toBe(0)
  expect(w.logs[0]).toContain('the conversation could not be read (transcript unavailable)')
})

test('when /rename refuses a plugin, the name is set by sessionTitle on the next message', async ($, on) => {
  const w = world(on, { rename: 'refused' })
  await start($)
  await w.clock.advance(10 * MIN)
  expect(w.renames.length).toBe(1)
  expect(w.logs).toEqual([])
  const r = await prompt($)
  expect(r.sessionTitle).toBe('Auto session name mod')
  // Only once.
  const again = await prompt($, { session_title: 'Auto session name mod' })
  expect(again.sessionTitle).toBeUndefined()
})

test('when /rename rejects the call outright, the fallback route still names it', async ($, on) => {
  const w = world(on, { rename: 'throws' })
  await start($)
  await w.clock.advance(10 * MIN)
  expect((await prompt($)).sessionTitle).toBe('Auto session name mod')
  expect(w.debug.join('\n')).toContain('/rename answered refused (no implementation for command.run)')
})

test('when /rename says nothing, the next message checks the name took before setting it again', async ($, on) => {
  const w = world(on, { rename: 'unknown' })
  await start($)
  await w.clock.advance(10 * MIN)
  expect((await prompt($, { session_title: 'Auto session name mod' })).sessionTitle).toBeUndefined()
})

test('a fallback name waiting for the next message gives way to a rename Dan makes first', async ($, on) => {
  const w = world(on, { rename: 'refused-for-mod' })
  await start($)
  await w.clock.advance(10 * MIN)
  await $.command.run({ command: 'rename', args: 'Mine' } as never)
  expect((await prompt($)).sessionTitle).toBeUndefined()
})

test('a fallback name gives way to a different name already on the next message', async ($, on) => {
  const w = world(on, { rename: 'refused' })
  await start($)
  await w.clock.advance(10 * MIN)
  expect((await prompt($, { session_title: 'Set some other way' })).sessionTitle).toBeUndefined()
})

test('a claude -p prompt never carries a fallback name', async ($, on) => {
  const w = world(on, { rename: 'refused' })
  await start($)
  await w.clock.advance(10 * MIN)
  expect((await prompt($, { source: 'sdk' })).sessionTitle).toBeUndefined()
  expect((await prompt($)).sessionTitle).toBe('Auto session name mod')
})

test('a name that shows up on a message while Haiku is answering wins over the name it returns', async ($, on) => {
  let release = () => undefined as void
  const w = world(on, { holdHaiku: new Promise<void>(r => (release = r)) })
  await start($)
  const due = w.clock.advance(10 * MIN)
  await w.clock.settle()
  await prompt($, { session_title: 'Named elsewhere' })
  release()
  await due
  await w.clock.settle()
  expect(w.renames.length).toBe(0)
})

// Reports each wait the mod asks for as a debug line, since the test's own clock already answers
// clock.after and an event takes one test hook.
const waitSpy: { name: string; register: Register } = {
  name: 'wait-spy',
  register: on => {
    on('clock.after', ($, e, next) => {
      $.ui.log(`WAIT ${(e as unknown as { ms: number }).ms}`, { to: 'debug' })
      return next(e)
    })
  },
}

test('a reload waits only for what is left of the ten minutes', { plugins: [waitSpy] }, async ($, on) => {
  const w = world(on)
  await start($)
  await w.clock.advance(6 * MIN)
  await start($)
  expect(w.debug.filter(l => l.startsWith('WAIT '))).toEqual([`WAIT ${10 * MIN}`, `WAIT ${4 * MIN}`])
})

test('two timers due at once (a reload while the first still runs) make one Haiku call', async ($, on) => {
  let release = () => undefined as void
  const w = world(on, { holdHaiku: new Promise<void>(r => (release = r)) })
  await start($)
  await w.clock.advance(6 * MIN)
  await start($)
  const due = w.clock.advance(4 * MIN)
  await w.clock.settle()
  release()
  await due
  await w.clock.settle()
  expect(w.prompts.length).toBe(1)
  expect(w.renames.length).toBe(1)
})

// Lessons review of #657: work started off a hook (the ten minute timer, a turn's end) must not lose
// a failure to an unhandled rejection, and bookkeeping around Dan's own /rename must never break it.
const failingState = (on: On) => {
  const s = { failing: false }
  on('state.set', async ($, e, next) => (s.failing ? ({ deny: 'state store unavailable' } as never) : next(e)))
  return s
}

test('a state write that fails at the ten minute mark is said in one line, not lost', async ($, on) => {
  const s = failingState(on)
  const w = world(on)
  await start($)
  s.failing = true
  await w.clock.advance(10 * MIN)
  await w.clock.settle()
  expect(w.prompts.length).toBe(0)
  expect(w.logs.length).toBe(1)
  expect(w.logs[0]).toContain("couldn't name this session")
  expect(w.logs[0]).toContain('state store unavailable')
  expect(w.logs[0]).toContain('try again when the session is next idle')
})

test('a state write that fails after a turn ends is said in one line, not lost', async ($, on) => {
  const s = failingState(on)
  const w = world(on, { messages: [] })
  await start($)
  await w.clock.advance(10 * MIN)
  s.failing = true
  await turnEnds($)
  await w.clock.settle()
  expect(w.logs.length).toBe(1)
  expect(w.logs[0]).toContain('state store unavailable')
  expect(w.logs[0]).toContain('try again when the session is next idle')
  // A store that stays broken is said once, not on every turn.
  await turnEnds($)
  await w.clock.settle()
  expect(w.logs.length).toBe(1)
})

test("Dan's own /rename still answers when the bookkeeping write around it fails", async ($, on) => {
  const s = failingState(on)
  const w = world(on)
  await start($)
  s.failing = true
  const r = (await $.command.run({ command: 'rename', args: 'Mine', origin: { kind: 'user' } } as never)) as { text?: string }
  expect(r.text).toBe('Session renamed to: Mine')
})

// Lessons review of #657: only a /rename that took counts as Dan naming the session himself.
test("a /rename of Dan's that is refused leaves the session to be named", async ($, on) => {
  const w = world(on, { rename: 'refused' })
  await start($)
  await $.command.run({ command: 'rename', args: 'x', origin: { kind: 'user' } } as never).catch(() => undefined)
  await w.clock.advance(10 * MIN)
  await w.clock.settle()
  expect(w.prompts.length).toBe(1)
})

test("a /rename of Dan's that throws leaves the session to be named", async ($, on) => {
  const w = world(on, { rename: 'throws' })
  await start($)
  await $.command.run({ command: 'rename', args: 'x', origin: { kind: 'user' } } as never).catch(() => undefined)
  await w.clock.advance(10 * MIN)
  await w.clock.settle()
  expect(w.prompts.length).toBe(1)
})

// Lessons review of #657: an attempt whose claim went stale and was taken over must not record its
// failure over the attempt that took over.
test('a failure from an attempt that lost its claim changes nothing for the one that took over', async ($, on) => {
  let release = () => {}
  const held = new Promise<void>(r => { release = r })
  const w = world(on, { replies: ['', 'Taken over name'], holdHaiku: held })
  await start($)
  await w.clock.advance(10 * MIN)
  await w.clock.advance(3 * MIN + 1)
  await turnEnds($)
  await w.clock.settle()
  release()
  await w.clock.settle()
  expect(w.logs).toEqual([])
  expect(w.renames.map(r => r.args)).toEqual(['Taken over name'])
})

// #701: the ten minute mark can fall in the middle of a turn, and /rename waits for that turn to end,
// which can be long after the claim's few minutes. The attempt keeps its claim fresh while it waits,
// so the turn's end finds it held: one Haiku call and one name, as the spec allows.
test('a /rename waiting through a long turn keeps its claim: one Haiku call and one rename', async ($, on) => {
  let release = () => {}
  const held = new Promise<void>(r => { release = r })
  const w = world(on, { holdRename: held, replies: ['Name A', 'Name B'] })
  await start($)
  await w.clock.advance(10 * MIN)
  // The turn running at the ten minute mark goes on for four more minutes, then ends.
  await w.clock.advance(4 * MIN)
  await turnEnds($)
  await w.clock.settle()
  release()
  await w.clock.settle()
  expect(w.prompts.length).toBe(1)
  expect(w.renames.map(r => r.args)).toEqual(['Name A'])
  expect(w.logs).toEqual([])
})

// Lessons review of #657: the final write after /rename answers also belongs only to the attempt
// still holding the claim. A claim goes stale only when its attempt stops keeping it fresh (a reload
// drops the attempt's timers; here its writes fail for the while), and the attempt that takes over
// uses the name already made rather than asking Haiku again (#701).
test('an attempt whose claim went stale during /rename does not overwrite the record, and the name is not asked for twice', async ($, on) => {
  const writes: { outcome?: string }[] = []
  const s = { failing: false }
  on('state.set', async ($, e, next) => {
    if (s.failing) return { deny: 'state store unavailable' } as never
    const r = await next(e)
    // A hook sees the result in its envelope; only a write that landed counts.
    if ((r as { value?: { isSet?: boolean } }).value?.isSet) writes.push(e.value as { outcome?: string })
    return r
  })
  let release = () => {}
  const held = new Promise<void>(r => { release = r })
  const w = world(on, { holdRename: held, replies: ['Name A', 'Name B'] })
  await start($)
  await w.clock.advance(10 * MIN)
  await w.clock.settle()
  // The first attempt waits in /rename and cannot keep its claim fresh, so it goes stale.
  s.failing = true
  await w.clock.advance(3 * MIN + 1)
  s.failing = false
  await turnEnds($)
  await w.clock.settle()
  expect(w.prompts.length).toBe(1)
  expect(w.renames.map(r => r.args)).toEqual(['Name A', 'Name A'])
  release()
  await w.clock.settle()
  expect(writes.filter(v => v.outcome === 'named').length).toBe(1)
  expect(w.logs).toEqual([])
})

// #701: the failure line at the ten minute mark promises another try at the next idle point, so a
// write that failed there must not leave the session waiting for a mark that never comes again.
test('a session whose ten minute write failed is named at the next idle point once the store recovers', async ($, on) => {
  const s = failingState(on)
  const w = world(on)
  await start($)
  s.failing = true
  await w.clock.advance(10 * MIN)
  await w.clock.settle()
  expect(w.logs.length).toBe(1)
  expect(w.prompts.length).toBe(0)
  s.failing = false
  await turnEnds($)
  await w.clock.settle()
  expect(w.prompts.length).toBe(1)
  expect(w.renames.map(r => r.args)).toEqual(['Auto session name mod'])
  expect(w.logs.length).toBe(1)
})
