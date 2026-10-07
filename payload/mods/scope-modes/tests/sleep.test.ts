import { describe, expect, test } from 'claude-code/testing'
import { bootOf, etWhen, nightOf, readSleep, untilOf } from '../hooks/sleep.ts'
import { SLEEP_FIXTURES } from './sleep-fixtures.ts'

type Fixture = { name: string; text: string | null; now: number; boot: number | null; state: string }

// One fixture set for both readers (L26): the shell's sleep_state is held to the same states in
// payload/hooks/test-sleep-state.sh, so the two cannot drift apart.
describe('readSleep, against the fixture set the shell reader shares', () => {
  for (const f of SLEEP_FIXTURES as Fixture[]) {
    test(f.name, () => {
      expect(readSleep(f.text, f.now, f.boot).state).toBe(f.state)
    })
  }
  test('the set covers every state, so neither reader can agree by never meeting one', () => {
    expect(new Set((SLEEP_FIXTURES as Fixture[]).map(f => f.state))).toEqual(new Set(['asleep', 'expired', 'other-boot', 'unreadable', 'none']))
  })
  test('asleep carries the record; unreadable says why', () => {
    const f = (SLEEP_FIXTURES as Fixture[])[0] as Fixture
    const r = readSleep(f.text, f.now, f.boot)
    expect(r.state === 'asleep' && r.record.generation).toBe('g1')
    const bad = readSleep('{"v":1', f.now, f.boot)
    expect(bad.state === 'unreadable' && bad.why).toMatch(/not JSON/)
    const noBoot = readSleep(f.text, f.now, null)
    expect(noBoot.state === 'unreadable' && noBoot.why).toMatch(/boot/)
  })
})

// Noon ET the day after the night, computed in America/New_York whatever zone the Mac is set to.
const utc = (y: number, mo: number, d: number, h: number, mi = 0, s = 0, ms = 0) => Date.UTC(y, mo - 1, d, h, mi, s, ms)

describe('the night and when sleep ends, in ET', () => {
  test('the night turns over at noon ET: a minute before is still the night before', () => {
    // 11:59:59.999 AM EDT on Oct 8 is 15:59:59.999 UTC.
    expect(nightOf(utc(2026, 10, 8, 15, 59, 59, 999))).toBe('2026-10-07')
    expect(nightOf(utc(2026, 10, 8, 16))).toBe('2026-10-08')
    // 11:30 PM EDT on Oct 7 is 03:30 UTC on Oct 8, still the night of the 7th.
    expect(nightOf(utc(2026, 10, 8, 3, 30))).toBe('2026-10-07')
  })
  test('sleep ends at noon ET the day after the night', () => {
    expect(untilOf('2026-10-07')).toBe(utc(2026, 10, 8, 16))
  })
  test('across the fall change, noon is in EST, an hour later in UTC', () => {
    expect(untilOf('2026-10-31')).toBe(utc(2026, 11, 1, 17))
    expect(untilOf('2026-11-01')).toBe(utc(2026, 11, 2, 17))
    expect(nightOf(utc(2026, 11, 1, 16, 59))).toBe('2026-10-31')
    expect(nightOf(utc(2026, 11, 1, 17))).toBe('2026-11-01')
  })
  test('across the spring change, noon is in EDT', () => {
    expect(untilOf('2026-03-07')).toBe(utc(2026, 3, 8, 16))
    expect(untilOf('2026-03-08')).toBe(utc(2026, 3, 9, 16))
  })
  test('the end of a month and a year', () => {
    expect(untilOf('2026-12-31')).toBe(utc(2027, 1, 1, 17))
    expect(untilOf('2026-09-30')).toBe(utc(2026, 10, 1, 16))
  })
  test('a time is said in ET with its day', () => {
    expect(etWhen(utc(2026, 10, 8, 3, 42))).toBe('11:42 PM ET on Wed Oct 7')
    expect(etWhen(utc(2026, 10, 8, 16))).toBe('12:00 PM ET on Thu Oct 8')
  })
})

describe('bootOf: this boot, from sysctl kern.boottime', () => {
  test('the seconds it names', () => {
    expect(bootOf('{ sec = 1759800000, usec = 123456 } Tue Oct  7 01:20:00 2025\n')).toBe(1759800000)
  })
  test('anything else is null, never a number', () => {
    expect(bootOf('')).toBeNull()
    expect(bootOf('sysctl: unknown oid')).toBeNull()
  })
})
