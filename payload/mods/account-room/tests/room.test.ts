import { expect, test } from 'claude-code/testing'
import { ago, card, clockText, effective, fromRateLimits, nameOf, verdict, triggered } from '../hooks/room.ts'
import type { Account, Reading } from '../hooks/room.ts'

// The account room's judgments (#659), pure so each is tested on its own. The cases are the ones
// Dan gave in the spec (98% against 95% weekly, 99% against 98% 5 hour) and the settled wording
// from the design rounds (docs/mods-design.md "Account room (#659)").

const MIN = 60_000
const HOUR = 60 * MIN
const DAY = 24 * HOUR
// Sunday 2026-10-04 12:00 UTC; with the offset below that is 8:00 AM in New York (EDT, UTC-4).
const NOW = Date.UTC(2026, 9, 4, 12, 0)
const ET = -240

const reading = (five: number | undefined, week: number | undefined, at = NOW - 2 * HOUR, fiveReset = NOW + 3 * HOUR, weekReset = NOW + 4 * DAY): Reading => ({
  takenAt: at,
  ...(five === undefined ? {} : { five: { used: five, resetsAt: fiveReset } }),
  ...(week === undefined ? {} : { week: { used: week, resetsAt: weekReset } }),
})
const account = (id: string, nickname: string | null, r?: Reading): Account => ({ id, email: `${id}@example.com`, org: 'Acme', nickname, ...(r ? { reading: r } : {}) })

test('rate limit windows become a reading, the reset as milliseconds, other windows ignored', () => {
  const r = fromRateLimits(
    [
      { kind: 'five_hour', percentUsed: 12.5, resetsAt: '2026-10-04T18:40:00Z' },
      { kind: 'seven_day', percentUsed: 30, resetsAt: '2026-10-08T13:00:00Z' },
      { kind: 'spend_limit', percentUsed: 5 },
    ],
    NOW,
  )
  expect(r).toEqual({ takenAt: NOW, five: { used: 12.5, resetsAt: Date.UTC(2026, 9, 4, 18, 40) }, week: { used: 30, resetsAt: Date.UTC(2026, 9, 8, 13, 0) } })
  // No subscription windows at all is no reading, never a reading of zero (L90).
  expect(fromRateLimits([], NOW)).toBeUndefined()
  // A reset that does not parse is kept as unknown, not as now.
  expect(fromRateLimits([{ kind: 'five_hour', percentUsed: 40, resetsAt: 'soon' }], NOW)).toEqual({ takenAt: NOW, five: { used: 40, resetsAt: null } })
})

test('a saved reading whose reset has passed counts as 0% for that limit', () => {
  expect(effective({ used: 99, resetsAt: NOW - 1 }, NOW)).toBe(0)
  expect(effective({ used: 99, resetsAt: NOW + 1 }, NOW)).toBe(99)
  expect(effective({ used: 99, resetsAt: null }, NOW)).toBe(99)
  expect(effective(undefined, NOW)).toBeUndefined()
})

test('the trigger is 95% on the 5 hour limit or 90% on the weekly one, and not below', () => {
  expect(triggered(reading(95, 10), NOW)).toEqual(['five'])
  expect(triggered(reading(94.9, 10), NOW)).toEqual([])
  expect(triggered(reading(10, 90), NOW)).toEqual(['week'])
  expect(triggered(reading(10, 89.9), NOW)).toEqual([])
  expect(triggered(reading(96, 91), NOW)).toEqual(['five', 'week'])
  expect(triggered(undefined, NOW)).toEqual([])
})

test('98% weekly here: an account at 95% weekly has more room and qualifies (no fixed cutoff)', () => {
  const here = account('here', 'This', reading(10, 98))
  const v = verdict(here, [account('work', 'Work', reading(50, 95))], NOW)
  expect(v.kind).toBe('room')
  expect(v.kind === 'room' && v.best.id).toBe('work')
})

test('99% 5 hour here: an account at 98% 5 hour qualifies; one at 99% does not', () => {
  const here = account('here', 'This', reading(99, 10))
  expect(verdict(here, [account('work', 'Work', reading(98, 50))], NOW).kind).toBe('room')
  expect(verdict(here, [account('work', 'Work', reading(99, 50))], NOW).kind).toBe('no-room')
})

test('room on the triggering limit is not enough when the other limit is at 100%', () => {
  const here = account('here', 'This', reading(10, 95))
  expect(verdict(here, [account('work', 'Work', reading(100, 20))], NOW).kind).toBe('no-room')
  // At 100% but past its reset it is 0%, so it qualifies again.
  expect(verdict(here, [account('work', 'Work', reading(100, 20, NOW - 6 * HOUR, NOW - HOUR))], NOW).kind).toBe('room')
})

test('a reading past its weekly reset counts as full room and qualifies', () => {
  const here = account('here', 'This', reading(10, 95))
  const v = verdict(here, [account('work', 'Work', reading(10, 99, NOW - 8 * DAY, NOW - 7 * DAY, NOW - DAY))], NOW)
  expect(v.kind === 'room' && v.best.id).toBe('work')
})

test('among those that qualify, the most weekly room wins', () => {
  const here = account('here', 'This', reading(96, 50))
  const v = verdict(here, [account('a', 'A', reading(10, 60)), account('b', 'B', reading(80, 20)), account('c', 'C', reading(5, 40))], NOW)
  expect(v.kind === 'room' && v.best.id).toBe('b')
})

test('below the trigger there is no card at all', () => {
  expect(verdict(account('here', 'This', reading(50, 50)), [account('work', 'Work', reading(1, 1))], NOW).kind).toBe('none')
})

test('no account qualifies: the soonest reset across every account, this one included, and the unread ones by name', () => {
  const here = account('here', 'This', reading(64, 91, NOW - 2 * HOUR, NOW + 3 * HOUR, NOW + 2 * DAY))
  const v = verdict(here, [account('work', 'Work', reading(20, 95, NOW - HOUR, NOW + 5 * HOUR, NOW + 4 * DAY)), account('side', 'Side')], NOW)
  expect(v.kind).toBe('no-room')
  if (v.kind !== 'no-room') return
  expect(v.soonest).toEqual({ account: here, limit: 'five', at: NOW + 3 * HOUR })
  expect(v.unread.map(a => a.id)).toEqual(['side'])
})

test('an account is named by its nickname, else its email and org', () => {
  expect(nameOf(account('work', 'Work'))).toBe('Work')
  expect(nameOf(account('work', null))).toBe('work@example.com (Acme)')
})

test('reset times read in the Mac own time zone: today as a time, later as weekday and time', () => {
  // 18:40 UTC is 2:40 PM in New York.
  expect(clockText(Date.UTC(2026, 9, 4, 18, 40), NOW, ET)).toBe('2:40 PM')
  // Thursday 13:00 UTC is 9 AM in New York: minutes left out on the hour.
  expect(clockText(Date.UTC(2026, 9, 8, 13, 0), NOW, ET)).toBe('Thu 9 AM')
  // The day is the local one: 03:30 UTC on Monday is still Sunday evening in New York, and
  // 04:30 UTC is just past local midnight.
  expect(clockText(Date.UTC(2026, 9, 5, 3, 30), NOW, ET)).toBe('11:30 PM')
  expect(clockText(Date.UTC(2026, 9, 5, 4, 30), NOW, ET)).toBe('Mon 12:30 AM')
})

test('each time reads in the offset in force at that instant, so a reset after a clock change is not an hour off', () => {
  // New York leaves daylight time on 1 November: a reset after it is UTC-5, today is UTC-4.
  const offsetAt = (ms: number) => (ms >= Date.UTC(2026, 10, 1, 6, 0) ? -300 : -240)
  expect(clockText(Date.UTC(2026, 10, 2, 14, 0), NOW, offsetAt)).toBe('Mon 9 AM')
  expect(clockText(Date.UTC(2026, 9, 4, 18, 40), NOW, offsetAt)).toBe('2:40 PM')
})

test('a time zone that could not be read shows the time in UTC and says so, never as if local', () => {
  expect(clockText(Date.UTC(2026, 9, 4, 18, 40), NOW, null)).toBe('6:40 PM UTC')
  expect(clockText(Date.UTC(2026, 9, 8, 13, 0), NOW, null)).toBe('Thu 1 PM UTC')
})

test('the age of a reading in its largest unit', () => {
  expect(ago(30_000)).toBe('<1m')
  expect(ago(14 * MIN)).toBe('14m')
  expect(ago(2 * HOUR + 59 * MIN)).toBe('2h')
  expect(ago(3 * DAY)).toBe('3d')
})

type Line = ({ text?: string; color?: string; button?: string; label?: string } | { divider: true })[] | { divider: true }
const text = (lines: Line[]) => lines.map(l => (Array.isArray(l) ? l.map(p => ('text' in p ? p.text : 'label' in p ? `[ ${p.label} ]` : '')).join('') : '---'))

test('the card naming the best account: amber lead with Switch and Dismiss, then room left, resets and age', () => {
  const here = account('here', 'This', reading(10, 95))
  const work = account('work', 'Work', reading(12, 30, NOW - 2 * HOUR, Date.UTC(2026, 9, 4, 22, 40), Date.UTC(2026, 9, 8, 13, 0)))
  const v = verdict(here, [work], NOW)
  const c = card({ verdict: v, phase: { kind: 'idle' }, now: NOW, offset: ET, unavailable: [] })
  expect(c.frame).toEqual({ kind: 'box' })
  expect(text(c.lines as Line[])).toEqual(['This account is low. Work has room  [ Switch ] [ Dismiss ]', '88% of 5h left, resets 6:40 PM · 70% of week left, resets Thu 9 AM · as of 2h ago'])
  const lead = (c.lines[0] as { text?: string; color?: string }[])[0]
  expect(lead).toMatchObject({ color: 'warning' })
})

test('while Switch works the lead is the progress with elapsed seconds, and the buttons go', () => {
  const v = verdict(account('here', 'This', reading(10, 95)), [account('work', 'Work', reading(12, 30))], NOW)
  const c = card({ verdict: v, phase: { kind: 'working', step: 'logout', since: NOW - 25_000 }, now: NOW, offset: ET, unavailable: [] })
  expect(text(c.lines as Line[])[0]).toBe('Switching to Work: signing claude.ai out in the browser… 25s')
  expect(JSON.stringify(c.lines)).not.toContain('"button"')
  const login = card({ verdict: v, phase: { kind: 'working', step: 'login', since: NOW - 3_000 }, now: NOW, offset: ET, unavailable: [] })
  expect(text(login.lines as Line[])[0]).toBe('Switching to Work: opening the sign in page… 3s')
})

test('a sign out that is not confirmed turns the lead red, claiming only that, with Try again and Dismiss', () => {
  const v = verdict(account('here', 'This', reading(10, 95)), [account('work', 'Work', reading(12, 30))], NOW)
  const c = card({ verdict: v, phase: { kind: 'failed', cause: 'not-confirmed' }, now: NOW, offset: ET, unavailable: [] })
  expect(text(c.lines as Line[])[0]).toBe("claude.ai didn't confirm the sign out. Nothing else was changed.  [ Try again ] [ Dismiss ]")
  expect((c.lines[0] as { color?: string }[])[0]).toMatchObject({ color: 'error' })
  // A failure stored by a build before #736 carried no cause, and that build only ever said this.
  expect(text(card({ verdict: v, phase: { kind: 'failed' }, now: NOW, offset: ET, unavailable: [] }).lines as Line[])[0]).toBe(text(c.lines as Line[])[0])
})

test('a Switch stopped for another reason says what was measured, never that claude.ai was asked (#736, L11, L440)', () => {
  const v = verdict(account('here', 'This', reading(10, 95)), [account('work', 'Work', reading(12, 30))], NOW)
  const lead = (cause: 'no-route' | 'logout-failed' | 'check-not-run' | 'interrupted') => {
    const c = card({ verdict: v, phase: { kind: 'failed', cause }, now: NOW, offset: ET, unavailable: [] })
    expect((c.lines[0] as { color?: string }[])[0]).toMatchObject({ color: 'error' })
    return text(c.lines as Line[])[0]
  }
  expect(lead('no-route')).toBe('No sign out was attempted: no browser logout route is set up. Nothing was changed.  [ Try again ] [ Dismiss ]')
  expect(lead('logout-failed')).toBe('The browser logout command failed. Nothing else was changed.  [ Try again ] [ Dismiss ]')
  expect(lead('check-not-run')).toBe('The signed out check could not be run. Nothing else was changed.  [ Try again ] [ Dismiss ]')
  expect(lead('interrupted')).toBe('A reload cut Switch off before the sign out was confirmed. Nothing else was changed.  [ Try again ] [ Dismiss ]')
})

test('the no room card: amber lead with Dismiss, then the soonest reset and the unread account', () => {
  const here = account('here', 'This', reading(64, 91, NOW - HOUR, Date.UTC(2026, 9, 4, 22, 40), NOW + 2 * DAY))
  const v = verdict(here, [account('work', 'Work', reading(20, 95, NOW - HOUR, NOW + 20 * HOUR, NOW + 4 * DAY)), account('side', 'Side')], NOW)
  const c = card({ verdict: v, phase: { kind: 'idle' }, now: NOW, offset: ET, unavailable: [] })
  expect(text(c.lines as Line[])).toEqual(['This account is low. No other account has room  [ Dismiss ]', "This account's 5h resets first, at 6:40 PM · Side has no reading yet and may have room"])
})

test("another account's reset coming first is named by that account", () => {
  const here = account('here', 'This', reading(10, 95, NOW - HOUR, NOW + 4 * HOUR, NOW + 2 * DAY))
  const v = verdict(here, [account('work', 'Work', reading(100, 20, NOW - HOUR, NOW + HOUR, NOW + 3 * DAY))], NOW)
  const c = card({ verdict: v, phase: { kind: 'idle' }, now: NOW, offset: ET, unavailable: [] })
  expect(text(c.lines as Line[])[1]).toBe("Work's 5h resets first, at 9 AM")
})

test("an unreadable other Mac's readings are named as unavailable, never dropped", () => {
  const v = verdict(account('here', 'This', reading(10, 95)), [], NOW)
  const c = card({ verdict: v, phase: { kind: 'idle' }, now: NOW, offset: ET, unavailable: [{ mac: 'Dans-MacBook-Pro', why: 'not readable JSON (Unexpected end)' }] })
  expect(text(c.lines as Line[])).toContain("Dans-MacBook-Pro's readings are unavailable: not readable JSON (Unexpected end)")
})

test("what GitHub could not give is said on the card: every other Mac's readings when the folder could not be listed, and this Mac's own save (#750)", () => {
  const v = verdict(account('here', 'This', reading(10, 95)), [], NOW)
  const c = card({ verdict: v, phase: { kind: 'idle' }, now: NOW, offset: ET, unavailable: [{ mac: null, why: 'gh is not logged in to GitHub (gh auth login)' }], unsaved: { mac: 'Daniels-MacBook-Pro-2', why: 'gh is not logged in to GitHub (gh auth login)' } })
  expect(text(c.lines as Line[]).slice(-2)).toEqual(["The other Macs' readings are unavailable: gh is not logged in to GitHub (gh auth login)", "Daniels-MacBook-Pro-2's readings could not be saved to GitHub: gh is not logged in to GitHub (gh auth login)"])
  // Below the trigger there is no card, so none of it is drawn.
  expect(card({ verdict: verdict(account('here', 'This', reading(10, 10)), [], NOW), phase: { kind: 'idle' }, now: NOW, offset: ET, unavailable: [], unsaved: { mac: 'm', why: 'x' } }).lines).toEqual([])
})
