import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { endedNameOf, readSleepEnds, readSleep, sleepEndsOf, type SleepReading } from '../hooks/sleep.ts'

// When each sleep on this Mac ended (#2993): the Slack alert guard asks Dan again about wording
// chosen overnight two hours after the sleep it was chosen in ended, so scope modes says when.

const BOOT = { time: 1759800000, session: null }
const record = (until: number) => JSON.stringify({ v: 1, generation: 'g1', until, bootTime: BOOT.time })
const NOW = 1791400000000
const asleep = readSleep(record(NOW + 1000), NOW, BOOT)
const expired = readSleep(record(NOW - 1000), NOW, BOOT)
const none: SleepReading = { state: 'none' }

test('one end per record moved aside at a wake or a noon end, read from the name the move gives it, oldest first', () => {
  const names = [endedNameOf(NOW - 5000, 'woke', 's1'), endedNameOf(NOW - 90000, 'limit', 's2')]
  expect(names[0]).toBe(`${NOW - 5000}-woke-s1.json`)
  expect(sleepEndsOf(names, none)).toEqual([NOW - 90000, NOW - 5000])
  // Anything else in the folder is not an end.
  expect(sleepEndsOf(['notes.txt', 'later-woke-s1.json', `${NOW}-slept-s1.json`, `${NOW}-woke-s1.json.tmp`], none)).toEqual([])
})

test('a record past its end that is not yet moved aside ended at its end; one asleep has not ended', () => {
  expect(asleep.state).toBe('asleep')
  expect(expired.state).toBe('expired')
  expect(sleepEndsOf([endedNameOf(NOW - 90000, 'woke', 's1')], asleep)).toEqual([NOW - 90000])
  expect(sleepEndsOf([endedNameOf(NOW - 90000, 'woke', 's1')], expired)).toEqual([NOW - 90000, NOW - 1000])
})

test('read from the ended folder: none there is no end, and a folder that cannot be listed throws', async () => {
  const dir = `${'/Users'}/x/.claude/state/sleep/ended`
  const seen: string[] = []
  const io = (present: boolean, listed: string[] | Error) => ({
    exists: async (p: string) => (seen.push(p), present),
    list: async (p: string) => {
      seen.push(p)
      if (listed instanceof Error) throw listed
      return listed.map(name => ({ name }))
    },
  })
  expect(await readSleepEnds(io(false, []), dir, none)).toEqual([])
  expect(seen).toEqual([dir])
  expect(await readSleepEnds(io(true, [endedNameOf(NOW - 5000, 'woke', 's1')]), dir, expired)).toEqual([NOW - 5000, NOW - 1000])
  await expect(readSleepEnds(io(true, new Error("EACCES: permission denied, scandir 'ended'")), dir, none)).rejects.toThrow('EACCES')
})
