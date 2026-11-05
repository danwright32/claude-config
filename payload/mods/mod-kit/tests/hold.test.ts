import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { CATCH_RESERVE_MS, neverThrows, withinGrace } from '../hooks/hold.ts'

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

