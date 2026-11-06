import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { neverThrows } from '../hooks/mod-kit/hold.ts'

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
