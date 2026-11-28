import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { acknowledge, ackOn, ackOnSaid } from '../hooks/modes.ts'
import { asleepRecord, closingChecks, command, CURRENT, say, start, withDeps, world } from './engine-harness.tsx'

// ---- Sleep and wake say what they do, as every other switch does (#1086) ----
// Dan, 2026-10-12: sleep and wake get the same acknowledgement as the other modes.
// Moved here from register.test.tsx with the engine harness (#3446), unchanged.
test('/sleep that starts tells Claude to open its reply with what sleep mode does; one that changes nothing does not (#1086)', withDeps, async ($, on) => {
  const { clock } = world(on)
  await start($ as never, clock)
  const r = await command($ as never, 'sleep')
  expect(r.text).toMatch(/^Sleep mode is on until/)
  expect(r.context).toEqual([ackOn('sleep')])
  expect((await command($ as never, 'sleep')).context).toBeUndefined()
})

test('/wake that wakes tells Claude to open its reply with what waking does; one with nothing to wake does not (#1086)', withDeps, async ($, on) => {
  const { clock } = world(on, { files: { [CURRENT]: asleepRecord() } })
  await start($ as never, clock)
  const r = await command($ as never, 'wake')
  expect(r.text).toMatch(/^Sleep mode is off\./)
  expect(r.context).toEqual([ackOn('wake')])
  expect((await command($ as never, 'wake')).context).toBeUndefined()
})

test('"I\'m up" acknowledges waking right after the line saying what waking did (#1086)', withDeps, async ($, on) => {
  const { clock } = world(on, { files: { [CURRENT]: asleepRecord() } })
  await start($ as never, clock)
  const ctx = (await say($ as never, "I'm up")).context ?? []
  expect(ctx).toContain(acknowledge([ackOnSaid('wake')], { after: 'the line saying what waking did' }))
})

// The last line of the file (#3446): its two closing checks read every world above. These tests
// make the mod send no prompt and ask Dan nothing, so no hold is reached and no question counted.
closingChecks({ holds: [] })
