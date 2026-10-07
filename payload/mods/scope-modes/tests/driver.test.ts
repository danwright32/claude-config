import { describe, expect, test } from 'claude-code/testing'
import {
  LIMITS, activeMs, decideFailure, decideStop, freshDriver, heldClaim, overnightRules, progressOf, readDriver, resumeDue,
  type ClaimReading, type DriverReading, type DriverRecord, type StopInput,
} from '../hooks/driver.ts'

// The overnight driver's decisions (#844), on recorded state only. Every limit is read from LIMITS,
// never written here as a literal at its edge (L401), so moving one moves its tests with it.

const MIN = 60_000
const T0 = 1_000_000_000
const RULES = overnightRules('s1', '/repo')
const ok = (record: DriverRecord): DriverReading => ({ state: 'ok', record })
const none: ClaimReading = { state: 'none' }
const held = (attempts = 1, since = T0): ClaimReading => ({ state: 'held', claim: { repo: 'o/r', issue: 7, attempts, since } })
const input = (o: Partial<StopInput> = {}): StopInput => ({
  now: T0, self: 's1', generation: 'g1', repo: 'o/r', driver: { state: 'none' }, fingerprint: 'notes=0;refs=', notesText: '',
  weekly: 10, claim: none, rules: RULES, ...o,
})
// A record from earlier tonight whose last progress reading was nothing at all.
const after = (o: Partial<DriverRecord> = {}): DriverRecord => ({ ...freshDriver('g1', 's1', T0), fingerprint: 'notes=0;refs=', weeklyAt: T0, ...o })

describe('the counter', () => {
  test('a counter that cannot be read stops the driver, never a fresh start (L105)', () => {
    for (const text of ['{"v":1', '[]', '{"v":2}', JSON.stringify({ ...after(), generation: 'g0' }), JSON.stringify({ ...after(), blocks: 'x' })]) {
      const r = readDriver(text, 'g1', 's1')
      expect(r.state).toBe('unreadable')
      const d = decideStop(input({ driver: r }))
      expect(d.kind).toBe('stop')
      expect(d.record).toBe(null)
      expect(d.notes[0]?.kind).toBe('stopped')
      expect(String(d.notes[0]?.text)).toMatch(/cannot count its blocks and stopped rather than loop/)
    }
  })
  test('no counter yet is a fresh night; a whole one reads back as written', () => {
    expect(readDriver(null, 'g1', 's1').state).toBe('none')
    const r = readDriver(JSON.stringify(after({ blocks: 4 })), 'g1', 's1')
    expect(r.state === 'ok' && r.record.blocks).toBe(4)
  })
  test('the loop counter counts every block itself; stop_hook_active plays no part (#839)', () => {
    let d: DriverReading = { state: 'none' }
    for (let n = 1; n <= 3; n++) {
      const r = decideStop(input({ driver: d, fingerprint: `notes=${n};refs=`, now: T0 + n * MIN }))
      expect(r.kind).toBe('block')
      d = ok(r.record as DriverRecord)
      expect(r.record?.blocks).toBe(n)
    }
  })
})

describe('the block', () => {
  test('carries the overnight rules whole, so they survive compaction', () => {
    const r = decideStop(input())
    expect(r.kind === 'block' && r.reason).toContain(RULES)
    expect(RULES).toContain('sleep-queue.sh next /repo s1')
    expect(RULES).toContain('sleep-queue.sh release /repo <issue> s1 done|parked|failed')
    expect(RULES).toMatch(/never from what you say/)
  })
  test('says which issue is held, and writes a heartbeat naming it', () => {
    const r = decideStop(input({ claim: held() }))
    expect(r.kind === 'block' && r.reason).toMatch(/^You hold #7 in o\/r \(attempt 1\): carry on with it\./)
    expect(r.notes).toEqual([{ kind: 'heartbeat', repo: 'o/r', issue: 7 }])
  })
  test('the rules carry no long dash', () => {
    const dashes = [0x2014, 0x2013].map(c => String.fromCharCode(c))
    expect(dashes.some(c => RULES.includes(c))).toBe(false)
  })
})

describe('the circuit breaker (H3)', () => {
  test('blocks in a row with nothing new let the session stop at the limit, with a failed note', () => {
    let d: DriverReading = ok(after())
    for (let n = 0; n < LIMITS.breakerBlocks; n++) {
      const r = decideStop(input({ driver: d, now: T0 + n * MIN }))
      expect(r.kind).toBe('block')
      d = ok(r.record as DriverRecord)
    }
    const r = decideStop(input({ driver: d, now: T0 + LIMITS.breakerBlocks * MIN }))
    expect(r.kind === 'stop' && r.why).toBe(`circuit breaker: ${LIMITS.breakerBlocks} blocks in a row with no new commit, claim or note`)
    expect(r.notes.map(n => n.kind)).toEqual(['failed', 'stopped'])
  })
  test('with a claim held, the breaker ends the claim as failed through the queue, which writes that note', () => {
    const r = decideStop(input({ driver: ok(after({ idleBlocks: LIMITS.breakerBlocks })), claim: held() }))
    expect(r.kind === 'stop' && r.release).toEqual({ issue: 7, state: 'failed', why: expect.stringMatching(/^circuit breaker/) })
    expect(r.notes.map(n => n.kind)).toEqual(['stopped'])
  })
  test('a new commit or note resets the run: progress is never what the model says', () => {
    const r = decideStop(input({ driver: ok(after({ idleBlocks: LIMITS.breakerBlocks - 1 })), fingerprint: 'notes=1;refs=abc' }))
    expect(r.kind).toBe('block')
    expect(r.record?.idleBlocks).toBe(0)
  })
  test('a progress reading that cannot be taken is no progress, so the breaker still trips', () => {
    expect(decideStop(input({ driver: ok(after({ idleBlocks: LIMITS.breakerBlocks })), fingerprint: null })).kind).toBe('stop')
  })
  test('active minutes with nothing new trip it; time spent waiting on a limit does not count', () => {
    const at = T0 + LIMITS.breakerMs
    expect(decideStop(input({ driver: ok(after()), now: at })).kind).toBe('stop')
    expect(decideStop(input({ driver: ok(after()), now: at - 1 })).kind).toBe('block')
    const waited = after({ waits: [{ from: T0 + MIN, until: T0 + 61 * MIN }] })
    expect(decideStop(input({ driver: ok(waited), now: at + 60 * MIN - 1 })).kind).toBe('block')
  })
  test('the per night cap stops a session that keeps making progress', () => {
    const r = decideStop(input({ driver: ok(after({ blocks: LIMITS.nightCap })), fingerprint: 'notes=9;refs=' }))
    expect(r.kind === 'stop' && r.why).toBe(`this session reached the night's cap of ${LIMITS.nightCap} blocks`)
    expect(decideStop(input({ driver: ok(after({ blocks: LIMITS.nightCap - 1 })), fingerprint: 'notes=9;refs=' })).kind).toBe('block')
  })
  test('once stopped, never blocks again that night', () => {
    const r = decideStop(input({ driver: ok(after({ stopped: 'earlier' })), fingerprint: 'notes=9;refs=' }))
    expect(r.kind === 'stop' && r.why).toBe('earlier')
    expect(r.notes).toEqual([])
  })
  test('a stopped note from the session itself (nothing left to claim) lets it stop, and only its own', () => {
    const mine = JSON.stringify({ kind: 'stopped', by: 's1', at: T0 + 1 })
    expect(decideStop(input({ driver: ok(after()), notesText: mine })).kind).toBe('stop')
    const theirs = JSON.stringify({ kind: 'stopped', by: 's2', at: T0 + 1 })
    expect(decideStop(input({ driver: ok(after()), notesText: theirs })).kind).toBe('block')
  })
  test('claims that cannot be read stop the session, said, rather than judge a claim it cannot see', () => {
    const r = decideStop(input({ claim: { state: 'unknown', why: 'a line of the claims could not be read' } }))
    expect(r.kind).toBe('stop')
    expect(r.notes[0]).toEqual({ kind: 'failed', repo: 'o/r', text: 'the claims could not be read (a line of the claims could not be read)' })
  })
})

describe('stuck work (M2, L27, L737)', () => {
  test('an attempt past the limit is parked at once', () => {
    const r = decideStop(input({ claim: held(LIMITS.attempts + 1) }))
    expect(r.kind === 'block' && r.release).toEqual({ issue: 7, state: 'parked', why: `attempt ${LIMITS.attempts + 1}: an issue is parked after ${LIMITS.attempts} attempts in a night` })
    expect(r.kind === 'block' && r.reason).toMatch(/^The driver parked #7 .*claim the next issue\. You hold no issue/)
    expect('release' in decideStop(input({ claim: held(LIMITS.attempts) }))).toBe(false)
  })
  test('active time on a claim, waits left out, parks it at the limit', () => {
    const at = (now: number, waits: { from: number; until: number }[] = []) =>
      decideStop(input({ now, driver: ok(after({ progressAt: now, weeklyAt: now, waits })), claim: held(1, T0) }))
    expect('release' in at(T0 + LIMITS.stuckMs - 1)).toBe(false)
    const r = at(T0 + LIMITS.stuckMs)
    expect(r.kind === 'block' && r.release?.state).toBe('parked')
    // An hour waited on a limit while the claim was held does not count toward it.
    expect('release' in at(T0 + LIMITS.stuckMs, [{ from: T0 + MIN, until: T0 + 61 * MIN }])).toBe(false)
  })
  test('activeMs leaves out only the part of a wait inside the span', () => {
    expect(activeMs([{ from: 0, until: 10 }], 5, 20)).toBe(10)
    expect(activeMs([{ from: 30, until: 40 }], 5, 20)).toBe(15)
  })
  test('a park the watchdog made between Stops is said at the next one, once', () => {
    const r = decideStop(input({ driver: ok(after({ parked: 'The watchdog parked #9.' })) }))
    expect(r.kind === 'block' && r.reason).toMatch(/^The watchdog parked #9\. You hold no issue/)
    expect(r.record?.parked).toBe(null)
  })
})

describe('the weekly limit (L706, M6)', () => {
  test('at the limit the issue in hand is parked and the session stops', () => {
    const r = decideStop(input({ weekly: LIMITS.weeklyStop, claim: held() }))
    expect(r.kind === 'stop' && r.release).toEqual({ issue: 7, state: 'parked', why: `the weekly limit is at ${LIMITS.weeklyStop}%, past the ${LIMITS.weeklyStop}% the night stops at` })
    expect(decideStop(input({ weekly: LIMITS.weeklyStop - 0.1 })).kind).toBe('block')
  })
  test('no reading for the limit finishes the issue in hand, then stops, with an unmeasured finding once', () => {
    const at = T0 + LIMITS.unmeasuredMs
    const progress = (n: number) => `notes=${n};refs=`
    expect(decideStop(input({ now: at - 1, weekly: null, driver: ok(after({ progressAt: at - 1 })), fingerprint: progress(1), claim: held(1, at - MIN) })).kind).toBe('block')
    const r = decideStop(input({ now: at, weekly: null, driver: ok(after({ progressAt: at })), fingerprint: progress(1), claim: held(1, at - MIN) }))
    expect(r.kind === 'block' && r.reason).toMatch(new RegExp(`^Finish #7 and release it, then claim nothing new: the weekly usage has had no reading for ${LIMITS.unmeasuredMs / MIN} minutes`))
    expect(r.notes.map(n => n.kind)).toEqual(['finding', 'heartbeat'])
    expect(r.record?.finishing).toBe(true)
    // Once the issue is released (no claim held), it stops, with no second finding.
    const s = decideStop(input({ now: at + MIN, weekly: null, driver: ok(r.record as DriverRecord), fingerprint: progress(2), claim: none }))
    expect(s.kind).toBe('stop')
    expect(s.notes.map(n => n.kind)).toEqual(['stopped'])
  })
})

describe('StopFailure (H2, L365, Dan 2026-10-07)', () => {
  const fail = (o: Partial<Parameters<typeof decideFailure>[0]> = {}) =>
    decideFailure({ now: T0, self: 's1', generation: 'g1', repo: 'o/r', driver: { state: 'none' }, error: 'rate_limit', message: 'API Error: 429', weekly: 50, ...o })
  test('a rate limit, overloaded or server error waits 5, 10, 20, 40, then an hour each, all night, each wait noted', () => {
    let d: DriverReading = { state: 'none' }
    const got: number[] = []
    for (let n = 0; n < 8; n++) {
      const now = T0 + n * 2 * 60 * MIN
      const r = fail({ driver: d, error: ['rate_limit', 'server_error', 'overloaded'][n % 3] as string, now })
      if (r.kind !== 'wait') throw new Error(`expected a wait, got ${r.kind}`)
      got.push(r.minutes)
      expect(r.notes).toEqual([{ kind: 'wait', repo: 'o/r', minutes: r.minutes, error: expect.any(String), text: 'API Error: 429' }])
      expect(r.record.resumeAt).toBe(now + r.minutes * MIN)
      d = ok(r.record)
    }
    expect(got).toEqual([5, 10, 20, 40, 60, 60, 60, 60])
  })
  test('a turn that ends well starts the waits over', () => {
    const r = fail()
    const s = decideStop(input({ driver: ok(r.record as DriverRecord), fingerprint: 'notes=1;refs=' }))
    expect(s.record?.waitStep).toBe(0)
    expect(s.record?.resumeAt).toBe(null)
  })
  test('sign in, billing and a refused request are noted and stop: waiting does not cure them', () => {
    for (const error of ['authentication_failed', 'billing_error', 'invalid_request', 'oauth_org_not_allowed', 'unknown']) {
      const r = fail({ error, message: 'API Error: 401 nope' })
      expect(r.kind).toBe('stop')
      expect(r.notes.map(n => n.kind)).toEqual(['failed', 'stopped'])
      expect(String(r.notes[0]?.text)).toBe(`the API answered ${error} (API Error: 401 nope), which waiting does not cure`)
    }
  })
  test('only the weekly limit stops the waiting', () => {
    expect(fail({ weekly: LIMITS.weeklyStop }).kind).toBe('stop')
    expect(fail({ weekly: LIMITS.weeklyStop - 1 }).kind).toBe('wait')
    expect(fail({ weekly: null }).kind).toBe('wait')
  })
  test('an unreadable counter stops rather than retry', () => {
    expect(fail({ driver: { state: 'unreadable', why: 'x' } }).kind).toBe('stop')
  })
  test('resume is due at its time and not a ms before, and never once stopped', () => {
    const d = fail().record as DriverRecord
    expect(resumeDue(d, (d.resumeAt as number) - 1)).toBe(false)
    expect(resumeDue(d, d.resumeAt as number)).toBe(true)
    expect(resumeDue({ ...d, stopped: 'x' }, d.resumeAt as number)).toBe(false)
  })
})

describe('the readings', () => {
  test("progress counts only this session's own notes that are not bookkeeping, and the branch tips", () => {
    const notes = [
      { kind: 'heartbeat', by: 's1' }, { kind: 'wait', by: 's1' }, { kind: 'finding', by: 's1' }, { kind: 'claim', by: 's1' }, { kind: 'finding', by: 's2' },
    ].map(n => JSON.stringify(n)).join('\n') + '\nnot json'
    expect(progressOf(notes, 's1', 'b\na\n')).toBe('notes=2;refs=a,b')
    // The driver's own notes (an unmeasured finding, a claim it could not end) are never progress.
    const own = [{ kind: 'finding', by: 's1', driver: true }, { kind: 'failed', by: 's1', driver: true }].map(n => JSON.stringify(n)).join('\n')
    expect(progressOf(own, 's1', '')).toBe('notes=0;refs=')
    expect(progressOf(null, 's1', '')).toBe(null)
    expect(progressOf('', 's1', null)).toBe(null)
  })
  test("the claim held is the one whose newest entry is this session's claim", () => {
    const line = (issue: number, entries: unknown[]) => JSON.stringify({ repo: 'o/r', issue, attempts: 2, entries })
    const text = [
      line(1, [{ kind: 'claim', session: 's1', at: 5 }, { kind: 'done', session: 's1', at: 6 }]),
      line(2, [{ kind: 'claim', session: 's2', at: 7 }]),
      line(3, [{ kind: 'claim', session: 's1', at: 9 }]),
    ].join('\n')
    expect(heldClaim(text, 's1')).toEqual({ state: 'held', claim: { repo: 'o/r', issue: 3, attempts: 2, since: 9 } })
    expect(heldClaim(line(1, [{ kind: 'claim', session: 's2', at: 1 }]), 's1')).toEqual({ state: 'none' })
    expect(heldClaim('{oops', 's1').state).toBe('unknown')
  })
})
