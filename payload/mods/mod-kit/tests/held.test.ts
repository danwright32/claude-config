import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { HOLD_MAX_MS, whileHeld, type Held } from '../hooks/held.ts'

// #2132: every long wait in a mod holds back mod-kit's reload of it through one helper, which takes
// the hold, runs the wait, and lets go on every way out. A hold or a letting go mod-kit refuses is
// said in the debug log and the wait runs as before, since a reload is a risk to the wait, never a
// reason not to wait.
const world = (opts: { holdFails?: string; releaseFails?: string } = {}) => {
  const order: string[] = []
  const debug: string[] = []
  const held = (id: string, what: string, ms: number): Held => ({
    mod: 'demo',
    id,
    what,
    ms,
    hold: async input => {
      if (opts.holdFails) throw new Error(opts.holdFails)
      order.push(`hold ${JSON.stringify(input)}`)
    },
    release: async input => {
      if (opts.releaseFails) throw new Error(opts.releaseFails)
      order.push(`release ${JSON.stringify(input)}`)
    },
    log: line => debug.push(line),
  })
  return { order, debug, held }
}

test('a wait is held for as long as it runs, and let go once it returns (#2132)', async () => {
  const { order, held } = world()
  const r = await whileHeld(held('resume', 'the resume prompt it sent', 60_000), async () => {
    order.push('wait')
    return 7
  })
  expect(r).toBe(7)
  expect(order).toEqual([
    `hold ${JSON.stringify({ mod: 'demo', id: 'resume', what: 'the resume prompt it sent', ms: 60_000 })}`,
    'wait',
    `release ${JSON.stringify({ mod: 'demo', id: 'resume' })}`,
  ])
})

test('a wait that throws is let go of, and its error reaches the caller unchanged (#2132)', async () => {
  const { order, held } = world()
  const boom = new Error('the session went away')
  let caught: unknown
  try {
    await whileHeld(held('ask', "Dan's answer", 60_000), async () => {
      order.push('wait')
      throw boom
    })
  } catch (err) {
    caught = err
  }
  expect(caught).toBe(boom)
  expect(order.at(-1)).toBe(`release ${JSON.stringify({ mod: 'demo', id: 'ask' })}`)
})

test('a hold mod-kit refuses is said in the debug log, the wait still runs, and nothing is let go of (#2132)', async () => {
  const { order, debug, held } = world({ holdFails: 'mod-kit is not loaded' })
  const r = await whileHeld(held('ask', "Dan's answer", 60_000), async () => {
    order.push('wait')
    return 'yes'
  })
  expect(r).toBe('yes')
  expect(order).toEqual(['wait'])
  expect(debug).toEqual([`demo: could not hold back a reload while it waits on Dan's answer, so one now would drop that wait (mod-kit is not loaded)`])
})

test('a letting go mod-kit refuses is said in the debug log, and the wait keeps its result (#2132)', async () => {
  const { debug, held } = world({ releaseFails: 'the state could not be written' })
  expect(await whileHeld(held('ask', "Dan's answer", 90_000), async () => 1)).toBe(1)
  expect(debug).toEqual([`demo: could not let go of its hold on a reload while it waited on Dan's answer; it lapses by itself within 2 minutes (the state could not be written)`])
})

test('a member the loaded mod-kit lacks is named as the skew it is, not a bare TypeError (#2132)', async () => {
  const { debug, held } = world()
  const $ = { modkit: {} } as unknown as { modkit: { hold: (x: unknown) => Promise<void> } }
  const h = { ...held('ask', "Dan's answer", 60_000), hold: (x: unknown) => $.modkit.hold(x) }
  expect(await whileHeld(h, async () => 2)).toBe(2)
  expect(debug.length).toBe(1)
  expect(debug[0]).toContain('demo and mod-kit are out of step in this session')
})

test("the longest hold a wait may ask for is mod-kit's own ceiling, an hour (#2132)", async () => {
  expect(HOLD_MAX_MS).toBe(60 * 60_000)
})
