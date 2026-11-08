import { expect } from 'claude-code/testing'
import type { EngineInterface } from 'claude-code'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { markLanded } from '../hooks/drafts.ts'

// #2436: the step a merge last landed at, written by markLanded. Two merges landing at once each take
// a step and then write it, so the write of the earlier step can arrive after the later one's.

// $.state standing in: one versioned value per key, a write with ifVersion refused when it is stale.
function store(seed: Record<string, number>) {
  const held = new Map<string, { value: number; version: number }>()
  for (const [k, v] of Object.entries(seed)) held.set(k, { value: v, version: 1 })
  const state = {
    get: async (ref: { key: string }) => held.get(ref.key) ?? { value: undefined, version: 0 },
    set: async (ref: { key: string }, value: number, opts?: { ifVersion?: number }) => {
      const now = held.get(ref.key)?.version ?? 0
      if (opts?.ifVersion !== undefined && opts.ifVersion !== now) return { isSet: false }
      held.set(ref.key, { value, version: now + 1 })
      return { isSet: true }
    },
  }
  return { $: { state } as unknown as EngineInterface, value: (key: string) => held.get(key)?.value }
}

test('a merge whose step was taken before another merge wrote a later one never lowers the landed step (#2436, lessons review of 25bcf07)', async () => {
  // One merge takes step 5, a draft settles at 6, another merge takes 7 and writes it first. Standing
  // in for that, the landed step is already past the step this merge takes.
  const s = store({ step: 4, landed: 7 })
  await markLanded(s.$)
  expect(s.value('step')).toBe(5)
  expect(s.value('landed')).toBe(7)
})

test('a merge landing after every other writes its own step as the landed step (#2436)', async () => {
  const s = store({ step: 4, landed: 3 })
  await markLanded(s.$)
  expect(s.value('landed')).toBe(5)
})
