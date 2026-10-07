import type { ScopeModesPlace } from '../types/index.d.ts'

// Sleep mode phase 1 (#840): the machine wide sleep record. One file for the whole Mac,
// ~/.claude/state/sleep/current.json, written whole beside itself and linked into place, so a
// reader never sees half a record. Asleep is quiet for every session; working overnight is only
// for the sessions the record names in `workers`.
//
// Whether the Mac is asleep is decided here, by readSleep, from the record's text, the time and
// this boot, and nowhere else: every decision point reads the file afresh and asks it (L83, L175),
// and the shell's sleep_state (payload/hooks/lib/sleep.sh) answers the same question the same way,
// both held to one committed fixture set (tests/sleep-fixtures.ts, L26).

/** The record as written at /sleep. `v` gates the reader (`v >= 1`), so a later writer adding a field still reads as asleep (L255). */
export type SleepRecord = {
  v: number
  /** This sleep's own id, unique per /sleep: the moved aside record and its notes are named by it. */
  generation: string
  /** When /sleep wrote it, ms since the epoch. */
  since: number
  /** When it stops holding by itself: noon ET the day after `night` (L523). */
  until: number
  /** The evening it began, as an ET date (YYYY-MM-DD); before noon ET counts as the night before. */
  night: string
  /** This boot's start in seconds (sysctl kern.boottime): a record from another boot reads as awake. */
  bootTime: number
  /** Where the night's report goes (written by phase 4, #835). */
  report: string
  /** Where sleep was started: the session and its folder. */
  startedBy: { sessionId: string; cwd: string }
  /** The sessions that work overnight; every other session is only kept quiet. */
  workers: string[]
  /** Where Dan was before sleep (home or away), put back on every session at wake. */
  placeBefore: ScopeModesPlace
}

/**
 * What the record says now. Only `asleep` is asleep: no record is awake, and a record past its
 * `until` or from another boot is awake too (it is moved aside by the first session to see it),
 * and so is one that cannot be read, since a mute that cannot say when it ends must not hold.
 */
export type SleepReading =
  | { state: 'none' }
  | { state: 'asleep'; record: SleepRecord }
  | { state: 'expired'; record: SleepRecord }
  | { state: 'other-boot'; record: SleepRecord }
  | { state: 'unreadable'; why: string }

const isNum = (x: unknown): x is number => typeof x === 'number' && Number.isFinite(x)

/**
 * The one predicate (#840). `text` is the record file's content, null when there is no file; `now`
 * in ms; `boot` this boot's start in seconds, null when it could not be read (then only the end decides). The checks run in
 * the order the shell reader runs them, so the two answer alike on a record wrong in two ways.
 */
export const readSleep = (text: string | null, now: number, boot: number | null): SleepReading => {
  if (text === null) return { state: 'none' }
  let j: unknown
  try {
    j = JSON.parse(text)
  } catch {
    return { state: 'unreadable', why: 'the sleep record is not JSON' }
  }
  if (!j || typeof j !== 'object' || Array.isArray(j)) return { state: 'unreadable', why: 'the sleep record is not a record' }
  const r = j as Record<string, unknown>
  if (!isNum(r.v) || r.v < 1) return { state: 'unreadable', why: 'the sleep record has no version this reader knows' }
  if (!isNum(r.until)) return { state: 'unreadable', why: 'the sleep record names no end' }
  if (!isNum(r.bootTime)) return { state: 'unreadable', why: 'the sleep record names no boot' }
  const record = r as unknown as SleepRecord
  // This boot unknown (sysctl failed) only skips the boot check: a sound record still holds until
  // its end, which bounds it either way, and is never called broken for what this side could not read.
  if (boot !== null && r.bootTime !== boot) return { state: 'other-boot', record }
  if (now >= r.until) return { state: 'expired', record }
  return { state: 'asleep', record }
}

/** This boot's start in seconds, from `sysctl -n kern.boottime`'s text, or null. */
export const bootOf = (text: string): number | null => {
  const m = /\bsec\s*=\s*(\d+)/.exec(text)
  return m ? Number(m[1]) : null
}

// ET, always America/New_York whatever zone the Mac is set to, one helper for every date (L39).
const ET = new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23', weekday: 'short' })
type EtParts = { y: number; mo: number; d: number; h: number; mi: number; wd: string }
const etParts = (ms: number): EtParts => {
  const p: Record<string, string> = {}
  for (const x of ET.formatToParts(ms)) p[x.type] = x.value
  return { y: Number(p.year), mo: Number(p.month), d: Number(p.day), h: Number(p.hour), mi: Number(p.minute), wd: p.weekday ?? '' }
}
const pad = (n: number) => String(n).padStart(2, '0')
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

/** Noon ET on a calendar date, in ms: 16:00 UTC under EDT, 17:00 under EST, read off the zone itself. */
const noonEt = (y: number, mo: number, d: number): number => {
  const edt = Date.UTC(y, mo - 1, d, 16)
  return etParts(edt).h === 12 ? edt : Date.UTC(y, mo - 1, d, 17)
}

/** The night a moment belongs to, as an ET date: before noon ET it is still the night before. */
export const nightOf = (ms: number): string => {
  const p = etParts(ms)
  const day = p.h < 12 ? new Date(Date.UTC(p.y, p.mo - 1, p.d - 1)) : new Date(Date.UTC(p.y, p.mo - 1, p.d))
  return `${day.getUTCFullYear()}-${pad(day.getUTCMonth() + 1)}-${pad(day.getUTCDate())}`
}

/** When a night's sleep ends by itself: noon ET the next day. */
export const untilOf = (night: string): number => {
  const [y, mo, d] = night.split('-').map(Number) as [number, number, number]
  const next = new Date(Date.UTC(y, mo - 1, d + 1))
  return noonEt(next.getUTCFullYear(), next.getUTCMonth() + 1, next.getUTCDate())
}

/** A moment as Dan reads it: "11:42 PM ET on Wed Oct 7". */
export const etWhen = (ms: number): string => {
  const p = etParts(ms)
  const h12 = p.h % 12 === 0 ? 12 : p.h % 12
  return `${h12}:${pad(p.mi)} ${p.h < 12 ? 'AM' : 'PM'} ET on ${p.wd} ${MONTHS[p.mo - 1]} ${p.d}`
}

/** Where everything sleep keeps lives, this Mac only (never synced). */
export const sleepDir = (home: string) => `${home.replace(/\/+$/, '')}/.claude/state/sleep`
