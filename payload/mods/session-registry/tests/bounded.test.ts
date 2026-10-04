import { expect, test } from 'claude-code/testing'
import { remember } from '../hooks/bounded.ts'

// The transcript lookup cache is keyed by session id, and every /clear mints a new one, so it is
// held to a fixed size, the oldest entry going first (lessons review of #640).
test('a bounded map keeps at most its limit, dropping the oldest entry', () => {
  const m = new Map<string, number>()
  for (let i = 0; i < 5; i++) remember(m, `s${i}`, i, 3)
  expect([...m.keys()]).toEqual(['s2', 's3', 's4'])
})

test('setting a key again refreshes it rather than counting twice', () => {
  const m = new Map<string, number>()
  remember(m, 'a', 1, 2)
  remember(m, 'b', 2, 2)
  remember(m, 'a', 3, 2)
  remember(m, 'c', 4, 2)
  expect([...m.entries()]).toEqual([['a', 3], ['c', 4]])
})
