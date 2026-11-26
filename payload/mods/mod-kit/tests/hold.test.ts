import { expect } from 'claude-code/testing'
import type { Register } from 'claude-code'
import { test } from './hang-ceiling.ts'
import { CATCH_RESERVE_MS, cutRefusal, cutCall, cutCheck, cutOwn, neverThrows, ownRefusal, watchesOnly, withinGrace } from '../hooks/hold.ts'

// #2039: a guard's catch is its last word on a call, so it must never throw. Each level is driven to
// fail here the ways a hook fails: a synchronous throw and an asynchronous rejection.
const HELD = { deny: 'held' }
const boom = (): never => {
  throw new Error('boom')
}
const rejects = async (): Promise<never> => {
  throw new Error('rejected')
}

test('work that answers is the answer, and the fallback is never run', async () => {
  let ran = 0
  const r = await neverThrows(() => ({ deny: 'judged' }), () => (ran++, { deny: 'fallback' }), HELD)
  expect(r).toEqual({ deny: 'judged' })
  expect(ran).toBe(0)
})

test('work that throws synchronously reaches the fallback', async () => {
  expect(await neverThrows(boom, () => ({ deny: 'fallback' }), HELD)).toEqual({ deny: 'fallback' })
})

test('work that rejects reaches the fallback', async () => {
  expect(await neverThrows(rejects, async () => ({ deny: 'fallback' }), HELD)).toEqual({ deny: 'fallback' })
})

test('a fallback that throws gives the last answer, never a throw', async () => {
  let thrown: unknown
  const r = await neverThrows(boom, boom, HELD).catch(err => ((thrown = err), undefined))
  expect(thrown).toBeUndefined()
  expect(r).toBe(HELD)
})

test('a fallback that rejects gives the last answer, never a throw', async () => {
  let thrown: unknown
  const r = await neverThrows(rejects, rejects, HELD).catch(err => ((thrown = err), undefined))
  expect(thrown).toBeUndefined()
  expect(r).toBe(HELD)
})

// #2039: a catch has a grace of 1,000 ms of its own time (its $ calls are not counted), and a catch
// still running past it is cut, and the call then runs as if no guard were there. withinGrace reads
// what is left of that grace before the slow part and holds the call when less than the reserve is
// left. The budget is handed in, so these tests set it rather than spend it (L524).
test('with the reserve left, the work runs and its answer stands', async () => {
  let held = 0
  const r = await withinGrace({ remainingMs: CATCH_RESERVE_MS }, () => ({ deny: 'judged' }), () => (held++, HELD))
  expect(r).toEqual({ deny: 'judged' })
  expect(held).toBe(0)
})

test('with less than the reserve left, the call is held and the work never starts', async () => {
  let ran = 0
  const r = await withinGrace({ remainingMs: CATCH_RESERVE_MS - 1 }, () => (ran++, { deny: 'judged' }), () => HELD)
  expect(r).toBe(HELD)
  expect(ran).toBe(0)
})

test('a budget that reads as no number holds the call, since how much is left is unknown', async () => {
  let ran = 0
  for (const remainingMs of [Number.NaN, undefined as unknown as number]) {
    expect(await withinGrace({ remainingMs }, () => (ran++, { deny: 'judged' }), () => HELD)).toBe(HELD)
  }
  expect(ran).toBe(0)
})

test('a reserve the caller names is the one read', async () => {
  expect(await withinGrace({ remainingMs: 100 }, () => ({ deny: 'judged' }), () => HELD, 50)).toEqual({ deny: 'judged' })
  expect(await withinGrace({ remainingMs: 100 }, () => ({ deny: 'judged' }), () => HELD, 150)).toBe(HELD)
})


// #3655: Claude Code cuts a tool.call or tool.check hook at 10 s of its own time, and a hook with no
// catch is then skipped: the call runs unjudged (6 of 6 runs, 2026-11-25, Claude Code 2.1.332). So
// every hook at those two events registers with one of the catches built here, and what each answers
// when the engine hands it a cut hook is pinned below. `next` is the engine's, stood in for: a
// function carrying `called` and `error`, as a catch reads them.
type Call = { deny: string } | { result: string }
type Check = { decision: 'allow' | 'ask' | 'deny'; reason?: string }
type In = { tool: string }
type Next<R> = ((e: In) => Promise<R>) & { readonly called: boolean; readonly error?: { kind: 'throw' | 'timeout'; message?: string } }
const caught = <R>(answer: R, called: boolean, error?: { kind: 'throw' | 'timeout'; message?: string }) => {
  let asked = 0
  const next = Object.assign(async (_e: { tool: string }): Promise<R> => (asked++, answer), { called, error })
  return { next, asked: () => asked }
}
const BASH = { tool: 'Bash' }
const TIMED_OUT = 'Blocked: the probe guard could not check this call (it ran out of time), so the call was refused and did not run. This is not a judgement of what the call does: send the same call again. If it keeps happening, tell Dan.'
const FAILED = 'Blocked: the probe guard could not check this call (it failed), so the call was refused and did not run. This is not a judgement of what the call does: send the same call again. If it keeps happening, tell Dan.'

test('#3655: a tool.call hook cut before it passed the call on is refused, in words naming the mod and the way out', async () => {
  const { next, asked } = caught<Call>({ result: 'ran' }, false, { kind: 'timeout' })
  expect(await cutCall('the probe guard', BASH, next)).toEqual({ deny: TIMED_OUT })
  expect(asked()).toBe(0)
  const thrown = caught<Call>({ result: 'ran' }, false, { kind: 'throw', message: 'boom' })
  expect(await cutCall('the probe guard', BASH, thrown.next)).toEqual({ deny: FAILED })
})

test('#3655: a tool.call hook cut after it passed the call on replays what the call settled to, refusing nothing', async () => {
  const { next, asked } = caught<Call>({ result: 'ran' }, true, { kind: 'timeout' })
  expect(await cutCall('the probe guard', BASH, next)).toEqual({ result: 'ran' })
  expect(asked()).toBe(1)
})

test('#3655: a tool.check hook that was cut is refused whether or not it had read the verdict beneath', async () => {
  for (const called of [false, true]) {
    const { next } = caught<Check>({ decision: 'allow' }, called, { kind: 'timeout' })
    expect(await cutCheck('the probe guard', next)).toEqual({ decision: 'deny', reason: TIMED_OUT })
  }
})

test("#3655: a mod's own tool that was cut is refused in words that do not claim nothing was done", async () => {
  const { next } = caught<Call>({ result: 'ran' }, false, { kind: 'timeout' })
  expect(await cutOwn('the probe guard', next)).toEqual({
    deny: 'Blocked: the probe guard could not finish answering this call to its own tool (it ran out of time), so the call was refused. What it had done by then stands, so check before sending the call again. If it keeps happening, tell Dan.',
  })
  expect(ownRefusal('the probe guard', undefined)).toContain('(it failed)')
})

test("#3655: a guard's own judgement in its catch is tried first, then its own refusal, then the last answer", async () => {
  const { next } = caught<Call>({ result: 'ran' }, false, { kind: 'throw', message: 'boom' })
  const own = { held: (): Call => ({ deny: 'own words' }), last: { deny: 'last words' } }
  expect(await cutCall('the probe guard', BASH, next, { ...own, work: (): Call => ({ deny: 'judged again' }) })).toEqual({ deny: 'judged again' })
  expect(await cutCall<In, Next<Call>, Call>('the probe guard', BASH, next, { ...own, work: boom })).toEqual({ deny: 'own words' })
  expect(await cutCall<In, Next<Call>, Call>('the probe guard', BASH, next, { work: boom, held: boom, last: { deny: 'last words' } })).toEqual({ deny: 'last words' })
  expect(await cutCall<In, Next<Call>, Call>('the probe guard', BASH, next, { work: rejects, held: rejects })).toEqual({ deny: cutRefusal('the probe guard', undefined) })
  expect(await cutCheck<Check>('the probe guard', caught<Check>({ decision: 'allow' }, false).next, { work: boom, held: boom })).toEqual({ decision: 'deny', reason: cutRefusal('the probe guard', undefined) })
  expect(await cutOwn<Call>('the probe guard', next, { work: boom, held: boom })).toEqual({ deny: ownRefusal('the probe guard', undefined) })
})

test("#3655: a hook that judges the call's result says so when cut after the call ran, and the bare replay stands where that fails", async () => {
  const { next, asked } = caught<Call>({ result: 'ran' }, true, { kind: 'timeout' })
  const noted = (n: Next<Call>) => cutCall<In, Next<Call>, Call>('the probe guard', BASH, n, { after: async () => ({ result: `${JSON.stringify(await n(BASH))} unjudged` }) })
  expect(await noted(next)).toEqual({ result: '{"result":"ran"} unjudged' })
  expect(await cutCall<In, Next<Call>, Call>('the probe guard', BASH, next, { after: boom })).toEqual({ result: 'ran' })
  expect(asked()).toBe(2)
  // Cut before the call ran, the same hook refuses as any guard does.
  expect(await noted(caught<Call>({ result: 'ran' }, false, { kind: 'timeout' }).next)).toEqual({ deny: TIMED_OUT })
})

test("#3655: a hook that judges only some calls leaves any other to the mod's next catch, cut before or after the call ran", async () => {
  // A mod's hooks on one event fail as one, and the first registered catch is asked first.
  for (const called of [false, true]) {
    const { next, asked } = caught<Call>({ result: 'ran' }, called, { kind: 'timeout' })
    expect(cutCall('the probe guard', BASH, next, { mine: () => false })).toBeUndefined()
    expect(cutCheck('the probe guard', next, { mine: () => false })).toBeUndefined()
    expect(cutOwn('the probe guard', next, { mine: () => false })).toBeUndefined()
    expect(asked()).toBe(0)
  }
  const { next } = caught<Call>({ result: 'ran' }, false, { kind: 'timeout' })
  expect(await cutCall('the probe guard', BASH, next, { mine: () => true })).toEqual({ deny: TIMED_OUT })
  // A reading of whose call it is that itself fails refuses, never hands on.
  expect(await cutCall('the probe guard', BASH, next, { mine: boom })).toEqual({ deny: TIMED_OUT })
  expect(await cutCheck('the probe guard', next, { mine: boom })).toEqual({ decision: 'deny', reason: TIMED_OUT })
})

test("#3655: the refusal says out of time for a timeout and for a missed heartbeat, and never quotes the failure's own words", () => {
  expect(cutRefusal('the probe guard', { kind: 'timeout', message: 'whatever next rejected with' })).toBe(TIMED_OUT)
  expect(cutRefusal('the probe guard', { kind: 'throw', message: 'no answer to a heartbeat within 5000ms: the hooks worker is wedged (a hook spinning without yielding)' })).toBe(TIMED_OUT)
  // A failure's words can quote the input the guard could not read, so none of them reach Claude.
  expect(cutRefusal('the probe guard', { kind: 'throw', message: 'could not parse TOKEN=not-a-real-secret' })).toBe(FAILED)
  expect(cutRefusal('the probe guard', undefined)).toBe(FAILED)
  expect(ownRefusal('the probe guard', { kind: 'throw', message: 'could not parse TOKEN=not-a-real-secret' })).not.toContain('TOKEN')
})

test('#3655: a hook that only watches answers nothing in its catch, which the engine reads as the hook absent', () => {
  expect(watchesOnly()).toBeUndefined()
})

// #3655: which catches the engine asks about a failed call. Each plugin below is written whole inside
// its own register, since an inline plugin cannot reach this file's variables. Seen the same way in
// live sessions on 2026-11-25 (Claude Code 2.1.332, 3 of 3 runs for each of the two cases).
const filteredFirst: { name: string; register: Register } = {
  name: 'filter-probe',
  register: on => {
    on('tool.call', { tool: 'Read' }, async (_$, e, next) => next(e)).catch(() => ({ deny: 'the catch of the Read hook answered' }))
    on('tool.call', { tool: 'Bash' }, async () => {
      throw new Error('the Bash hook failed')
    }).catch(() => ({ deny: 'the catch of the Bash hook answered' }))
  },
}
const unfilteredFirst: { name: string; register: Register } = {
  name: 'order-probe',
  register: on => {
    on('tool.call', async (_$, e, next) => next(e)).catch(() => ({ deny: 'the catch of the first hook answered' }))
    on('tool.call', { tool: 'Bash' }, async () => {
      throw new Error('the Bash hook failed')
    }).catch(() => ({ deny: 'the catch of the Bash hook answered' }))
  },
}

test("#3655: a catch is not asked about a call its hook's tool filter does not match, however early it was registered", { plugins: [filteredFirst] }, async ($, on) => {
  on('tool.call', async () => ({ result: 'ran' }))
  expect((await $.tool.call({ tool: 'Bash', command: 'true', tool_use_id: 't1' } as never)).deny).toBe('the catch of the Bash hook answered')
  // A call neither hook fails on is untouched by either catch.
  expect((await $.tool.call({ tool: 'Read', file_path: '/repo/a.ts', tool_use_id: 't2' } as never)).deny).toBeUndefined()
})

test('#3655: a first hook with no tool filter matches every call, so its catch answers for a later hook that failed', { plugins: [unfilteredFirst] }, async ($, on) => {
  on('tool.call', async () => ({ result: 'ran' }))
  expect((await $.tool.call({ tool: 'Bash', command: 'true', tool_use_id: 't1' } as never)).deny).toBe('the catch of the first hook answered')
})
