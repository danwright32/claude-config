import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { turnNow, type TurnStore } from '../hooks/turnnow.ts'

// #2461, #2437: the one reader of whether a main turn is running, kept by every mod that must not
// queue a prompt behind one. What the module saw decides; a fresh module reads $.state.
const store = (opts: { setFails?: string; getFails?: string; held?: string | null } = {}) => {
  const debug: string[] = []
  let held: string | null | undefined = opts.held
  const s: TurnStore = {
    get: async () => {
      if (opts.getFails) throw new Error(opts.getFails)
      return held
    },
    set: async id => {
      if (opts.setFails) throw new Error(opts.setFails)
      held = id
    },
    log: line => debug.push(line),
  }
  return { s, debug, now: () => held }
}

test('a turn that started is running until it ends, and the id is kept for a reload', async () => {
  const t = turnNow('demo')
  const { s, now } = store()
  expect(await t.running(s)).toBe(null)
  await t.started(s, 't1')
  expect(await t.running(s)).toBe('t1')
  expect(now()).toBe('t1')
  await t.ended(s)
  expect(await t.running(s)).toBe(null)
  expect(now()).toBe(null)
})

test('a fresh module (after a reload) reads the running turn from the store', async () => {
  const { s } = store({ held: 't9' })
  const t = turnNow('demo')
  expect(await t.running(s)).toBe('t9')
  // Forgetting what it saw hands the answer back to the store, as session.start does.
  await t.ended(s)
  t.forget()
  expect(await t.running(s)).toBe(null)
})

test('an end the store failed to record still reads as ended here, and the failure is said', async () => {
  const t = turnNow('demo')
  const { s, debug } = store({ setFails: 'state is read only', held: 't1' })
  await t.ended(s)
  expect(await t.running(s)).toBe(null)
  expect(debug).toEqual(['demo: could not record that the main turn ended: state is read only'])
})

test('a store that cannot be read throws, never reads as idle', async () => {
  const t = turnNow('demo')
  const { s } = store({ getFails: 'state unavailable' })
  let thrown = ''
  try {
    await t.running(s)
  } catch (err) {
    thrown = (err as Error).message
  }
  expect(thrown).toBe('state unavailable')
})
