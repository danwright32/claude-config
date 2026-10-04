import { expect, test } from 'claude-code/testing'
import { accountKey, combine, macsIn, merge, mergeReading, parseMacFile, parseNicknames, serialize, withSighting } from '../hooks/store.ts'
import type { MacFile } from '../hooks/store.ts'

// The two files the account room keeps (#659): one readings file per Mac in iCloud Drive, each Mac
// writing only its own so iCloud never makes conflict copies (L83), and the nicknames file in the
// claude-sync payload. Pure, so the merging and the refusals are tested on their own.

const H = 3_600_000
const T = 1_000 * H

const file = (mac: string, accounts: MacFile['accounts']): MacFile => ({ v: 1, mac, accounts })

test('the key is a hash of the account and org ids, so neither id is ever stored', async () => {
  const k = await accountKey('11111111-aaaa', '22222222-bbbb')
  expect(k).toMatch(/^[0-9a-f]{16}$/)
  expect(k).not.toContain('1111')
  expect(await accountKey('11111111-aaaa', '22222222-bbbb')).toBe(k)
  // The same account in another org is another key: limits are per account and org.
  expect(await accountKey('11111111-aaaa', '33333333-cccc')).not.toBe(k)
})

test("two Macs' files merge by the newest reading per account", () => {
  const here = file('Daniels-MacBook-Pro-2', {
    a: { email: 'a@x.com', org: 'Acme', seenAt: T, reading: { takenAt: T, five: { used: 10, resetsAt: null } } },
    b: { email: 'b@x.com', org: 'Acme', seenAt: T, reading: { takenAt: T + 2 * H, week: { used: 40, resetsAt: null } } },
  })
  const there = file('Dans-MacBook-Pro', {
    a: { email: 'a@x.com', org: 'Acme', seenAt: T + H, reading: { takenAt: T + H, five: { used: 70, resetsAt: null } } },
    b: { email: 'b@x.com', org: 'Acme', seenAt: T + H, reading: { takenAt: T + H, week: { used: 5, resetsAt: null } } },
    c: { email: 'c@x.com', org: 'Side', seenAt: T },
  })
  const m = merge([here, there])
  expect(m.get('a')?.reading?.five?.used).toBe(70)
  expect(m.get('b')?.reading?.week?.used).toBe(40)
  // Seen on the other Mac with no reading yet: known, and unread.
  expect(m.get('c')).toEqual({ id: 'c', email: 'c@x.com', org: 'Side' })
})

test("a session's sighting keeps a newer reading already in the file (two sessions, out of order)", () => {
  const f = file('m', { a: { email: 'a@x.com', org: 'Acme', seenAt: T, reading: { takenAt: T + H, five: { used: 50, resetsAt: null } } } })
  const older = withSighting(f, 'm', { id: 'a', email: 'a@x.com', org: 'Acme' }, { takenAt: T, five: { used: 1, resetsAt: null } }, T + 2 * H)
  expect(older.accounts.a?.reading?.five?.used).toBe(50)
  const newer = withSighting(f, 'm', { id: 'a', email: 'a@x.com', org: 'Acme' }, { takenAt: T + 3 * H, five: { used: 90, resetsAt: null } }, T + 3 * H)
  expect(newer.accounts.a?.reading?.five?.used).toBe(90)
  // A sighting with no reading (a session start) records the account without losing the reading.
  const seen = withSighting(f, 'm', { id: 'a', email: 'a@x.com', org: 'Acme' }, undefined, T + 4 * H)
  expect(seen.accounts.a?.reading?.five?.used).toBe(50)
  expect(seen.accounts.a?.seenAt).toBe(T + 4 * H)
})

test('a reading carrying one window keeps the other window from before, dated by the older of the two (L510)', () => {
  const f = file('m', { a: { email: 'a@x.com', org: 'Acme', seenAt: T, reading: { takenAt: T, five: { used: 10, resetsAt: null }, week: { used: 40, resetsAt: null } } } })
  const next = withSighting(f, 'm', { id: 'a', email: 'a@x.com', org: 'Acme' }, { takenAt: T + H, five: { used: 20, resetsAt: null } }, T + H)
  expect(next.accounts.a?.reading).toEqual({ takenAt: T, five: { used: 20, resetsAt: null, takenAt: T + H }, week: { used: 40, resetsAt: null } })
  expect(mergeReading({ takenAt: T, week: { used: 40, resetsAt: null } }, { takenAt: T + H, five: { used: 20, resetsAt: null }, week: { used: 50, resetsAt: null } })).toEqual({ takenAt: T + H, five: { used: 20, resetsAt: null }, week: { used: 50, resetsAt: null } })
  expect(mergeReading(undefined, { takenAt: T, five: { used: 1, resetsAt: null } })).toEqual({ takenAt: T, five: { used: 1, resetsAt: null } })
})

test('an entry this build cannot read is carried through a rewrite unchanged, never erased (L105)', () => {
  const p = parseMacFile(JSON.stringify({ v: 1, mac: 'm', accounts: { a: { email: 'a@x.com', org: 'Acme', seenAt: T }, z: { email: 'z@x.com', future: true } } }))
  if (typeof p === 'string') throw new Error(p)
  const next = withSighting(p, 'm', { id: 'a', email: 'a@x.com', org: 'Acme' }, undefined, T + H)
  expect(JSON.parse(serialize(next)).accounts.z).toEqual({ email: 'z@x.com', future: true })
  // Not counted as an account the card can use.
  expect(merge([next]).has('z')).toBe(false)
})

test('readings are combined window by window whichever arrives first, on one Mac and across Macs (L510)', () => {
  const fiveNew = { takenAt: T + H, five: { used: 70, resetsAt: null } }
  const weekOld = { takenAt: T, week: { used: 30, resetsAt: null } }
  // Out of order on one Mac: the newer five hour reading is already there, the older weekly one arrives.
  const f = file('m', { a: { email: 'a@x.com', org: 'Acme', seenAt: T + H, reading: fiveNew } })
  expect(withSighting(f, 'm', { id: 'a', email: 'a@x.com', org: 'Acme' }, weekOld, T + 2 * H).accounts.a?.reading).toEqual({ takenAt: T, five: { used: 70, resetsAt: null, takenAt: T + H }, week: { used: 30, resetsAt: null } })
  // Across Macs: one has the newer five hour figure, the other the only weekly one.
  const m = merge([file('A', { a: { email: 'a@x.com', org: 'Acme', seenAt: T + H, reading: fiveNew } }), file('B', { a: { email: 'a@x.com', org: 'Acme', seenAt: T, reading: weekOld } })])
  expect(m.get('a')?.reading).toEqual({ takenAt: T, five: { used: 70, resetsAt: null, takenAt: T + H }, week: { used: 30, resetsAt: null } })
})

test('each window keeps its own time, so a later merge never puts an older figure over a newer one', () => {
  // Stored: five hour from T+H, weekly from T. Arriving: both windows from T+H/2.
  const stored = { takenAt: T, five: { used: 80, resetsAt: null, takenAt: T + H }, week: { used: 30, resetsAt: null } }
  const arriving = { takenAt: T + H / 2, five: { used: 60, resetsAt: null }, week: { used: 35, resetsAt: null } }
  expect(combine(stored, arriving)).toEqual({ takenAt: T + H / 2, five: { used: 80, resetsAt: null, takenAt: T + H }, week: { used: 35, resetsAt: null } })
  expect(combine(arriving, stored)).toEqual(combine(stored, arriving))
})

test('a readings file that does not parse is refused with why, never read as no readings (L215)', () => {
  expect(parseMacFile('{"v":1,"mac":"m","accounts":{}}')).toEqual({ v: 1, mac: 'm', accounts: {} })
  expect(parseMacFile('{"v":1,"mac":"m","acc')).toMatch(/^not readable JSON/)
  expect(parseMacFile('{"v":2,"mac":"m","accounts":{}}')).toMatch(/version 2/)
  expect(parseMacFile('[]')).toMatch(/not a readings file/)
  // A malformed entry is dropped rather than taking the whole file with it.
  const p = parseMacFile(JSON.stringify({ v: 1, mac: 'm', accounts: { a: { email: 'a@x.com', org: 'Acme', seenAt: T, reading: { takenAt: 'yesterday' } }, b: { email: 'b@x.com', org: 'B', seenAt: T } } }))
  expect(typeof p === 'object' && Object.keys(p.accounts)).toEqual(['b'])
})

test("the folder listing names each Mac's file, and one iCloud has not downloaded as unavailable", () => {
  expect(macsIn(['Daniels-MacBook-Pro-2.json', 'Dans-MacBook-Pro.json', '.DS_Store', 'notes.txt'], 'Daniels-MacBook-Pro-2')).toEqual([{ mac: 'Dans-MacBook-Pro', file: 'Dans-MacBook-Pro.json' }])
  expect(macsIn(['.Dans-MacBook-Pro.json.icloud'], 'Daniels-MacBook-Pro-2')).toEqual([{ mac: 'Dans-MacBook-Pro', notDownloaded: true }])
  // Our own file, even as a placeholder, is never another Mac.
  expect(macsIn(['.Daniels-MacBook-Pro-2.json.icloud'], 'Daniels-MacBook-Pro-2')).toEqual([])
})

test('nicknames: a name, or null for an account whose ask was skipped; anything else is refused', () => {
  expect(parseNicknames('{"v":1,"names":{"a":"Work","b":null}}')).toEqual({ v: 1, names: { a: 'Work', b: null } })
  expect(parseNicknames('{"v":1,"names":{"a":7}}')).toMatch(/not a name/)
  expect(parseNicknames('nope')).toMatch(/^not readable JSON/)
})
