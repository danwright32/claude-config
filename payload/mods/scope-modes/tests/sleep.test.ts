import { describe, expect, test } from 'claude-code/testing'
import { BOOT_TIME_TOLERANCE_S, bootOf, bootSessionOf, endSaid, etWhen, isDaytimeEt, nightOf, readSleep, untilOf } from '../hooks/sleep.ts'
import { BOOT_FIXTURES, SESSION_FIXTURES, SLEEP_FIXTURES } from './sleep-fixtures.ts'

type Fixture = { name: string; text: string | null; now: number; boot: number | null; session?: string | null; state: string }
const bootIn = (f: Fixture) => ({ time: f.boot, session: f.session ?? null })
const UNKNOWN = { time: null, session: null }

// One fixture set for both readers (L26): the shell's sleep_state is held to the same states in
// payload/hooks/test-sleep-state.sh, so the two cannot drift apart.
describe('readSleep, against the fixture set the shell reader shares', () => {
  for (const f of SLEEP_FIXTURES as Fixture[]) {
    test(f.name, () => {
      expect(readSleep(f.text, f.now, bootIn(f)).state).toBe(f.state)
    })
  }
  test('the set covers every state, so neither reader can agree by never meeting one', () => {
    expect(new Set((SLEEP_FIXTURES as Fixture[]).map(f => f.state))).toEqual(new Set(['asleep', 'expired', 'other-boot', 'unreadable', 'none']))
  })
  test('asleep carries the record; unreadable says why', () => {
    const f = (SLEEP_FIXTURES as Fixture[])[0] as Fixture
    const r = readSleep(f.text, f.now, bootIn(f))
    expect(r.state === 'asleep' && r.record.generation).toBe('g1')
    const bad = readSleep('{"v":1', f.now, bootIn(f))
    expect(bad.state === 'unreadable' && bad.why).toMatch(/not JSON/)
    // An unknown boot never makes a sound record read as broken: its end still bounds it.
    expect(readSleep(f.text, f.now, UNKNOWN).state).toBe('asleep')
  })
  // The edge fixtures (300 s and 301 s off, both ways) are written against this value; the shell's
  // TOLERANCE_S is held to the same edges, so a change to either fails one of the two suites.
  test('the start may sit as far as the tolerance from the record one, and no further', () => {
    expect(BOOT_TIME_TOLERANCE_S).toBe(300)
  })
})

describe('bootSessionOf: this boot, from sysctl kern.bootsessionuuid', () => {
  // The shell's sleep_boot_session_of is held to the same cases in payload/hooks/test-sleep-state.sh (L26).
  for (const f of SESSION_FIXTURES as { name: string; text: string; session: string | null }[]) {
    test(`the fixture the shell shares: ${f.name}`, () => {
      expect(bootSessionOf(f.text)).toBe(f.session)
    })
  }
})

// The night and its end (noon ET the day after it), computed in America/New_York whatever zone the Mac is set to.
const utc = (y: number, mo: number, d: number, h: number, mi = 0, s = 0, ms = 0) => Date.UTC(y, mo - 1, d, h, mi, s, ms)

describe('the night and when sleep ends, in ET', () => {
  // Dan, 2026-10-21 (#1479): a /sleep from 9 AM ET on is the coming night and runs to noon ET the next
  // day; one before 9 AM still belongs to the night just ending, which ends at noon that day.
  test('the night turns over at 9 AM ET: a moment before is still the night before', () => {
    // 8:59:59.999 AM EDT on Oct 21 is 12:59:59.999 UTC.
    expect(nightOf(utc(2026, 10, 21, 12, 59, 59, 999))).toBe('2026-10-20')
    expect(nightOf(utc(2026, 10, 21, 13))).toBe('2026-10-21')
    // 11:30 PM EDT on Oct 7 is 03:30 UTC on Oct 8, still the night of the 7th.
    expect(nightOf(utc(2026, 10, 8, 3, 30))).toBe('2026-10-07')
  })
  test('a /sleep before 9 AM ends at noon the same day; from 9 AM, at noon the next day', () => {
    // 8:59 AM EDT: the night just ending, three hours left of it.
    expect(untilOf(nightOf(utc(2026, 10, 21, 12, 59)))).toBe(utc(2026, 10, 21, 16))
    // 9:00 AM EDT: the coming night, to noon on Thu Oct 22.
    expect(untilOf(nightOf(utc(2026, 10, 21, 13)))).toBe(utc(2026, 10, 22, 16))
  })
  test('a /sleep in the seconds before noon runs to noon the next day, never seconds (#1469)', () => {
    // 11:59:55 AM EDT on Oct 21, the moment of the 2026-10-21 flake, which ended 4.8 s later.
    const at = utc(2026, 10, 21, 15, 59, 55)
    expect(nightOf(at)).toBe('2026-10-21')
    expect(untilOf(nightOf(at))).toBe(utc(2026, 10, 22, 16))
  })
  test('noon and after are the coming night too', () => {
    expect(nightOf(utc(2026, 10, 21, 16))).toBe('2026-10-21')
    expect(untilOf(nightOf(utc(2026, 10, 21, 16)))).toBe(utc(2026, 10, 22, 16))
  })
  test('on the fall change day, 9 AM is in EST, an hour later in UTC', () => {
    // Nov 1 2026: 8:59 AM EST is 13:59 UTC, 9:00 AM EST is 14:00 UTC.
    expect(nightOf(utc(2026, 11, 1, 13, 59))).toBe('2026-10-31')
    expect(untilOf(nightOf(utc(2026, 11, 1, 13, 59)))).toBe(utc(2026, 11, 1, 17))
    expect(nightOf(utc(2026, 11, 1, 14))).toBe('2026-11-01')
    expect(untilOf(nightOf(utc(2026, 11, 1, 14)))).toBe(utc(2026, 11, 2, 17))
  })
  test('on the spring change day, 9 AM is in EDT', () => {
    // Mar 8 2026: 8:59 AM EDT is 12:59 UTC, 9:00 AM EDT is 13:00 UTC.
    expect(nightOf(utc(2026, 3, 8, 12, 59))).toBe('2026-03-07')
    expect(untilOf(nightOf(utc(2026, 3, 8, 12, 59)))).toBe(utc(2026, 3, 8, 16))
    expect(nightOf(utc(2026, 3, 8, 13))).toBe('2026-03-08')
    expect(untilOf(nightOf(utc(2026, 3, 8, 13)))).toBe(utc(2026, 3, 9, 16))
  })
  test('a /sleep at any minute lasts at least the three hours from 8:59 AM to noon, across both changes', () => {
    let shortest = Infinity
    for (const [y, mo, d] of [[2026, 3, 7], [2026, 10, 20], [2026, 10, 31]] as const) {
      for (let t = utc(y, mo, d, 0); t < utc(y, mo, d + 3, 0); t += 60_000) shortest = Math.min(shortest, untilOf(nightOf(t)) - t)
    }
    expect(shortest).toBe(3 * 3_600_000 + 60_000)
  })
  test('sleep ends at noon ET the day after the night', () => {
    expect(untilOf('2026-10-07')).toBe(utc(2026, 10, 8, 16))
  })
  test('across the fall change, noon is in EST, an hour later in UTC', () => {
    expect(untilOf('2026-10-31')).toBe(utc(2026, 11, 1, 17))
    expect(untilOf('2026-11-01')).toBe(utc(2026, 11, 2, 17))
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

// What /sleep, the prompt note and "already on" say of the end (#1479): the real day, so a /sleep
// at 8:59 AM reads "noon ET today" and one at 9 AM "noon ET tomorrow".
describe('endSaid: when sleep ends, as Dan reads it', () => {
  test('noon the next ET day is noon tomorrow, with its day', () => {
    expect(endSaid(utc(2026, 10, 22, 16), utc(2026, 10, 21, 13))).toBe('noon ET tomorrow (Thu Oct 22)')
    // 11:30 PM EDT on Oct 21 is 03:30 UTC on Oct 22, and its noon is still tomorrow's.
    expect(endSaid(utc(2026, 10, 22, 16), utc(2026, 10, 22, 3, 30))).toBe('noon ET tomorrow (Thu Oct 22)')
  })
  test('noon the same ET day is noon today, with its day', () => {
    expect(endSaid(utc(2026, 10, 21, 16), utc(2026, 10, 21, 12, 59))).toBe('noon ET today (Wed Oct 21)')
    // After midnight, the night's noon is today's.
    expect(endSaid(utc(2026, 10, 22, 16), utc(2026, 10, 22, 4, 30))).toBe('noon ET today (Thu Oct 22)')
  })
  test('on the fall change day noon is read in EST', () => {
    expect(endSaid(utc(2026, 11, 1, 17), utc(2026, 11, 1, 13, 59))).toBe('noon ET today (Sun Nov 1)')
    expect(endSaid(utc(2026, 11, 2, 17), utc(2026, 11, 1, 14))).toBe('noon ET tomorrow (Mon Nov 2)')
  })
  test('any other end is said as its time and day, never rounded to noon', () => {
    // An end that is not noon (an hour on, as the real engine suite sets it), or more than a day away.
    expect(endSaid(utc(2026, 10, 21, 17, 30), utc(2026, 10, 21, 16, 30))).toBe('1:30 PM ET on Wed Oct 21')
    expect(endSaid(utc(2026, 10, 23, 16), utc(2026, 10, 21, 13))).toBe('12:00 PM ET on Fri Oct 23')
    // An end already past is never called today's or tomorrow's noon.
    expect(endSaid(utc(2026, 10, 21, 16), utc(2026, 10, 21, 17))).toBe('12:00 PM ET on Wed Oct 21')
  })
})

// Phase 9 (#837): a message from Dan between 7 AM and 7 PM ET while asleep asks whether he is up.
describe('isDaytimeEt: 7 AM up to 7 PM ET, read off the zone itself', () => {
  test('both edges in winter (EST, UTC minus 5)', () => {
    expect(isDaytimeEt(utc(2026, 1, 15, 11, 59, 59, 999))).toBe(false)
    expect(isDaytimeEt(utc(2026, 1, 15, 12))).toBe(true)
    expect(isDaytimeEt(utc(2026, 1, 15, 23, 59, 59, 999))).toBe(true)
    expect(isDaytimeEt(utc(2026, 1, 16, 0))).toBe(false)
  })
  test('both edges in summer (EDT, UTC minus 4)', () => {
    expect(isDaytimeEt(utc(2026, 7, 15, 10, 59, 59, 999))).toBe(false)
    expect(isDaytimeEt(utc(2026, 7, 15, 11))).toBe(true)
    expect(isDaytimeEt(utc(2026, 7, 15, 22, 59, 59, 999))).toBe(true)
    expect(isDaytimeEt(utc(2026, 7, 15, 23))).toBe(false)
  })
  test('on the spring change day, morning is already EDT', () => {
    // Mar 8 2026: 2 AM EST becomes 3 AM EDT, so 7 AM is 11:00 UTC, not 12:00.
    expect(isDaytimeEt(utc(2026, 3, 8, 10, 59))).toBe(false)
    expect(isDaytimeEt(utc(2026, 3, 8, 11))).toBe(true)
    expect(isDaytimeEt(utc(2026, 3, 8, 22, 59))).toBe(true)
    expect(isDaytimeEt(utc(2026, 3, 8, 23))).toBe(false)
  })
  test('on the fall change day, morning is already EST', () => {
    // Nov 1 2026: 2 AM EDT becomes 1 AM EST, so 7 AM is 12:00 UTC and 7 PM is 00:00 UTC on Nov 2.
    expect(isDaytimeEt(utc(2026, 11, 1, 11, 59))).toBe(false)
    expect(isDaytimeEt(utc(2026, 11, 1, 12))).toBe(true)
    expect(isDaytimeEt(utc(2026, 11, 1, 23, 59))).toBe(true)
    expect(isDaytimeEt(utc(2026, 11, 2, 0))).toBe(false)
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
  // The shell's sleep_boot_of is held to the same cases in payload/hooks/test-sleep-state.sh (L26).
  for (const f of BOOT_FIXTURES as { name: string; text: string; boot: number | null }[]) {
    test(`the fixture the shell shares: ${f.name}`, () => {
      expect(bootOf(f.text)).toBe(f.boot)
    })
  }
})
