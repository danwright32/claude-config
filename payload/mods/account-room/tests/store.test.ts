import { expect, test } from 'claude-code/testing'
import { accountKey, combine, isWorthWriting, macFiles, merge, mergeNicknames, nicknameRefusal, parseMacFile, parseNicknames, serialize, serializeNicknames, withAccount, withName, withSighting } from '../hooks/store.ts'
import type { Account } from '../hooks/room.ts'
import type { MacFile } from '../hooks/store.ts'

// The two files the account room keeps (#659): one readings file per Mac in a private GitHub
// repository (#750), each Mac writing only its own (L83), and the nicknames file in the claude-sync
// payload. Pure, so the merging and the refusals are tested on their own.

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
  expect(combine({ takenAt: T, week: { used: 40, resetsAt: null } }, { takenAt: T + H, five: { used: 20, resetsAt: null }, week: { used: 50, resetsAt: null } })).toEqual({ takenAt: T + H, five: { used: 20, resetsAt: null }, week: { used: 50, resetsAt: null } })
  expect(combine(undefined, { takenAt: T, five: { used: 1, resetsAt: null } })).toEqual({ takenAt: T, five: { used: 1, resetsAt: null } })
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

test("the repository's readings folder names each Mac's file; anything else in it is not a Mac", () => {
  expect(macFiles([
    { name: 'Daniels-MacBook-Pro-2.json', type: 'file' },
    { name: 'Dans-MacBook-Pro.json', type: 'file' },
    { name: 'README.md', type: 'file' },
    { name: '.hidden.json', type: 'file' },
    { name: 'old.json', type: 'dir' },
  ])).toEqual([
    { mac: 'Daniels-MacBook-Pro-2', file: 'Daniels-MacBook-Pro-2.json' },
    { mac: 'Dans-MacBook-Pro', file: 'Dans-MacBook-Pro.json' },
  ])
})

test("this Mac's file is rewritten only when a figure the card shows moved, an account is new or changed, or its newest reading is over 10 minutes old (#750)", () => {
  const MIN = 60_000
  const who = { id: 'a', email: 'a@x.com', org: 'Acme' }
  const r = (five: number, at: number, fiveReset = T + 3 * H) => ({ takenAt: at, five: { used: five, resetsAt: fiveReset }, week: { used: 30, resetsAt: T + 50 * H } })
  const cur = withSighting(undefined, 'm', who, r(40, T), T)
  const after = (reading: ReturnType<typeof r> | undefined, now: number, w = who) => isWorthWriting(cur, withSighting(cur, 'm', w, reading, now), now)
  // No file yet: the first sighting is written.
  expect(isWorthWriting(undefined, cur, T)).toBe(true)
  // The same figures a minute later: nothing to send.
  expect(after(r(40, T + MIN), T + MIN)).toBe(false)
  // A move the card cannot show (60% left either way) waits for the next one it can.
  expect(after(r(40.4, T + MIN), T + MIN)).toBe(false)
  expect(after(r(41, T + MIN), T + MIN)).toBe(true)
  // A reset time that moved is a figure that moved.
  expect(after(r(40, T + MIN, T + 4 * H), T + MIN)).toBe(true)
  // A quiet stretch: at ten minutes nothing yet, past ten the newest reading is sent so the other
  // Mac can tell this one is alive.
  expect(after(r(40, T + 10 * MIN), T + 10 * MIN)).toBe(false)
  expect(after(r(40, T + 10 * MIN + 1), T + 10 * MIN + 1)).toBe(true)
  // A sighting with no reading refreshes no reading, however long it has been.
  expect(after(undefined, T + 3 * H)).toBe(false)
  // Who the account is changed, or an account this file has not held: written.
  expect(after(undefined, T + MIN, { ...who, email: 'b@x.com' })).toBe(true)
  expect(after(undefined, T + MIN, { id: 'z', email: 'z@x.com', org: 'Acme' })).toBe(true)
})

// The nicknames file exactly as the first build wrote it (#659, version 1, a name or null per key and
// no time), kept as written so every later reader is held to it (L1010, L1013).
const NICKNAMES_V1 = '{\n  "v": 1,\n  "names": {\n    "f16e53befe6fbe12": null,\n    "0a1b2c3d4e5f6071": "Work"\n  }\n}\n'

test('nicknames written by the first build, with no times, still read: a name, or null where the ask was skipped (L1010, L1013)', () => {
  expect(parseNicknames(NICKNAMES_V1)).toEqual({ names: { f16e53befe6fbe12: { name: null }, '0a1b2c3d4e5f6071': { name: 'Work' } } })
  expect(parseNicknames('{"v":1,"names":{"a":7}}')).toMatch(/not a name/)
  expect(parseNicknames('nope')).toMatch(/^not readable JSON/)
})

test('nicknames version 2: each entry carries when it was recorded; anything else is refused with why', () => {
  expect(parseNicknames('{"v":2,"names":{"a":{"name":"Work","at":5},"b":{"name":null,"at":3}}}')).toEqual({ names: { a: { name: 'Work', at: 5 }, b: { name: null, at: 3 } } })
  expect(parseNicknames('{"v":2,"names":{"a":"Work"}}')).toMatch(/the entry for a is not a name/)
  expect(parseNicknames('{"v":2,"names":{"a":{"name":"Work","at":"noon"}}}')).toMatch(/the entry for a is not a name/)
  // A later version is named, never read as no nicknames, so nothing is written over it (L105).
  expect(parseNicknames('{"v":3,"names":{}}')).toMatch(/written by version 3/)
  expect(parseNicknames('{"names":{}}')).toMatch(/not a nicknames file/)
})

test('two Macs answering one account: a name beats a skip whichever came later, in either order (#747)', () => {
  const name = { name: 'dwright (team)', at: 100 }
  const skipLater = { name: null, at: 200 }
  const a = { names: { k: name } }
  const b = { names: { k: skipLater } }
  expect(mergeNicknames([a, b]).names.k).toEqual(name)
  expect(mergeNicknames([b, a]).names.k).toEqual(name)
  // A name the first build wrote, with no time, still beats a skip recorded later.
  expect(mergeNicknames([{ names: { k: { name: 'Work' } } }, b]).names.k).toEqual({ name: 'Work' })
})

test('two names for one account: the later stands, in either order; one with no time counts as older (#747)', () => {
  const early = { names: { k: { name: 'Home', at: 100 } } }
  const late = { names: { k: { name: 'Personal', at: 200 } } }
  expect(mergeNicknames([early, late]).names.k).toEqual({ name: 'Personal', at: 200 })
  expect(mergeNicknames([late, early]).names.k).toEqual({ name: 'Personal', at: 200 })
  expect(mergeNicknames([late, { names: { k: { name: 'Zed' } } }]).names.k).toEqual({ name: 'Personal', at: 200 })
  // An exact tie settles the same way on every Mac, whichever file it read first.
  const tieA = { names: { k: { name: 'Alpha', at: 300 } } }
  const tieB = { names: { k: { name: 'Beta', at: 300 } } }
  expect(mergeNicknames([tieA, tieB])).toEqual(mergeNicknames([tieB, tieA]))
  // Accounts only one side knows are kept from both.
  expect(Object.keys(mergeNicknames([{ names: { x: { name: 'X', at: 1 } } }, { names: { y: { name: null, at: 1 } } }]).names).sort()).toEqual(['x', 'y'])
})

test('recording an answer: a skip never replaces a name, a name replaces a skip, and a rename stands even over a clock that ran ahead (#747)', () => {
  const named = { names: { k: { name: 'Work', at: 500 } } }
  expect(withName(named, 'k', null, 900).names.k).toEqual({ name: 'Work', at: 500 })
  expect(withName({ names: { k: { name: null, at: 900 } } }, 'k', 'Work', 100).names.k).toEqual({ name: 'Work', at: 100 })
  // The other Mac stamped "Work" ahead of this Mac's clock: the rename is still the later answer.
  expect(withName(named, 'k', 'Job', 400).names.k).toEqual({ name: 'Job', at: 501 })
  expect(withName({ names: {} }, 'n', 'New', 7).names.n).toEqual({ name: 'New', at: 7 })
})

test('the nicknames file is written as version 2, one account per line in key order, and reads back the same', () => {
  const f = { names: { b: { name: null, at: 3 }, a: { name: 'Work', at: 5 }, c: { name: 'Old' } } }
  const text = serializeNicknames(f)
  expect(text).toBe('{\n  "v": 2,\n  "names": {\n    "a": {"name":"Work","at":5},\n    "b": {"name":null,"at":3},\n    "c": {"name":"Old"}\n  }\n}\n')
  expect(parseNicknames(text)).toEqual(f)
  expect(serializeNicknames({ names: {} })).toBe('{\n  "v": 2,\n  "names": {}\n}\n')
})

test('a nickname that looks like an email address is refused, since the nicknames file is public (#758)', () => {
  for (const n of ['dan@example.com', 'Work (dan@pennie.co.uk)', ' a.b+c@d.io ']) expect(nicknameRefusal(n)).toMatch(/looks like an email address/)
  // An at sign on its own, or a name with a dot, is a name.
  for (const n of ['Work', 'Dan @ Acme', 'team@home', 'dwright (team)', 'v1.2']) expect(nicknameRefusal(n)).toBeUndefined()
})

test('adding an account to a set of accounts copies it, so a set read and kept elsewhere is never changed (#758)', () => {
  const a: Account = { id: 'a', email: 'a@x.com', org: 'Acme', nickname: null }
  const b: Account = { id: 'b', email: 'b@x.com', org: 'Acme', nickname: null }
  const kept = new Map([['a', a]])
  const out = withAccount(kept, b)
  expect([...out.keys()]).toEqual(['a', 'b'])
  expect([...kept.keys()]).toEqual(['a'])
  // One already there is kept as it is, reading and all.
  expect(withAccount(kept, { ...a, email: 'other@x.com' }).get('a')).toBe(a)
})
