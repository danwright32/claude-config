// tests/test-catch-grace.sh runs these in a temporary copy of this fixture holding the real
// mod-kit hold.ts and hang-ceiling.ts (#2039).
import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'

const call = async (run: (command: string) => Promise<unknown>, command: string) =>
  run(command).then(
    v => JSON.stringify(v),
    err => String(err),
  )

test('control: a catch whose slow part runs past the grace is cut, and the call runs unguarded', async ($, on) => {
  let ran = 0
  on('tool.call', async () => (ran++, { result: 'ran', text: 'ran' }) as never)
  const r = await call(command => $.tool.call({ tool: 'Bash', command, tool_use_id: 'g1' } as never), 'bare')
  console.log(`GRACE bare ran=${ran} r=${r.slice(0, 200)}`)
  expect(ran).toBe(1)
})

test('withinGrace holds the call when the grace is nearly spent, with the could not check words', async ($, on) => {
  let ran = 0
  on('tool.call', async () => (ran++, { result: 'ran', text: 'ran' }) as never)
  const r = await call(command => $.tool.call({ tool: 'Bash', command, tool_use_id: 'g2' } as never), 'checked')
  console.log(`GRACE checked ran=${ran} r=${r.slice(0, 200)}`)
  expect(ran).toBe(0)
  expect(r).toContain('it ran out of time')
})
