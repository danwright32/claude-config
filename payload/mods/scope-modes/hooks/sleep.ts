import type { ScopeModesPlace } from '../types/index.d.ts'
import type { NightRepos } from './mergedeploy.ts'

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
  /** The evening it began, as an ET date (YYYY-MM-DD), from nightOf: before 9 AM ET counts as the night before (before noon on a record written before #1479). Read as written, never recomputed. */
  night: string
  /** This boot's start in seconds (sysctl kern.boottime): a record from another boot reads as awake. Judged within BOOT_TIME_TOLERANCE_S, and only where `bootSession` cannot decide. */
  bootTime: number
  /** This boot's session (sysctl kern.bootsessionuuid), which only a restart changes: absent on a record written before it was kept, or when it could not be read. */
  bootSession?: string
  /** Where the night's report goes (written by phase 4, #835); since #1287 the /sleep session's own. */
  report: string
  /**
   * One report per session with news (#1287): each names its own in reports/<generation>/<session>.path,
   * and the report script writes each. Absent on an older record, which keeps the one `report`.
   */
  reportsPerSession?: boolean
  /** Where sleep was started: the session and its folder. */
  startedBy: { sessionId: string; cwd: string }
  /** The sessions that work overnight; every other session is only kept quiet. */
  workers: string[]
  /**
   * What each worker works toward tonight (#1242), by session id: the condition its /goal set, or
   * the goal Dan gave it before bed. A worker with no entry has no goal and does no work; absent on a
   * record written before goals were kept, where no worker has one.
   */
  goals?: Record<string, string>
  /** Where Dan was before sleep (home or away), put back on every session at wake. */
  placeBefore: ScopeModesPlace
  /** The night's merge and deploy lists as settled at bedtime (#843, mergedeploy.ts); absent on an older record, which closes every repository. */
  repos?: NightRepos
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

/** This boot as a reader knows it: its session and its start in seconds, each null when it could not be read. */
export type Boot = { session: string | null; time: number | null }

/**
 * How far this boot's start may sit from the record's and still be the same boot, when no boot
 * session decides. macOS derives kern.boottime from the wall clock minus uptime, so a clock
 * correction moves it by seconds with no restart (2 s on 2026-10-08, which ended the night on the
 * shell side while this mod, holding its first reading, still said asleep); a real restart moves it
 * by the whole time the Mac had been up. The shell's TOLERANCE_S (hooks/lib/sleep.sh) is the same,
 * held to it by the shared fixtures at both edges.
 */
export const BOOT_TIME_TOLERANCE_S = 300

/**
 * The one predicate (#840). `text` is the record file's content, null when there is no file; `now`
 * in ms; `boot` this boot (with neither half known, only the end decides). The record's boot
 * session decides which boot it belongs to whenever both sides have one, and only otherwise its
 * start, within BOOT_TIME_TOLERANCE_S. The checks run in the order the shell reader runs them, so
 * the two answer alike on a record wrong in two ways.
 */
export const readSleep = (text: string | null, now: number, boot: Boot): SleepReading => {
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
  if ('bootSession' in r && !(typeof r.bootSession === 'string' && r.bootSession)) return { state: 'unreadable', why: 'the sleep record names a boot session this reader cannot read' }
  const record = r as unknown as SleepRecord
  // This boot unknown both ways (sysctl failed) only skips the boot check: a sound record still holds
  // until its end, which bounds it either way, and is never called broken for what this side could not read.
  const same =
    typeof r.bootSession === 'string' && boot.session !== null
      ? r.bootSession.toUpperCase() === boot.session.toUpperCase()
      : boot.time !== null
        ? Math.abs(r.bootTime - boot.time) <= BOOT_TIME_TOLERANCE_S
        : true
  if (!same) return { state: 'other-boot', record }
  if (now >= r.until) return { state: 'expired', record }
  return { state: 'asleep', record }
}

/** A worker's goal as the record keeps it: its text, or null for none, a field that cannot be read included (#1242). */
export const goalOf = (record: SleepRecord, session: string): string | null => {
  const g = record.goals && typeof record.goals === 'object' && !Array.isArray(record.goals) ? (record.goals as Record<string, unknown>)[session] : undefined
  return typeof g === 'string' && g.trim() ? g.trim() : null
}

/** This boot's start in seconds, from `sysctl -n kern.boottime`'s text, or null. */
export const bootOf = (text: string): number | null => {
  const m = /\bsec\s*=\s*(\d+)/.exec(text)
  return m ? Number(m[1]) : null
}

/** This boot's session, from `sysctl -n kern.bootsessionuuid`'s text: its first line when that is a UUID, in upper case, or null. */
export const bootSessionOf = (text: string): string | null => {
  const line = (text.split('\n')[0] ?? '').trim()
  return /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/.test(line) ? line.toUpperCase() : null
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

/**
 * The hour (ET, 24 hour clock) from which a moment belongs to the coming night rather than the one
 * ending. Dan, 2026-10-21 (#1479, "Run to tomorrow's noon"): a /sleep from 9 AM ET on is the coming
 * night and lasts until noon ET the next day; one before 9 AM still belongs to the night just ending,
 * as before. It was noon until then, so a /sleep at 11:59:55 AM ended 4.8 seconds later (#1469).
 */
export const NIGHT_TURNS_AT_HOUR = 9

/**
 * The night a moment belongs to, as an ET date: before 9 AM ET it is still the night before. The one
 * place a night is computed: /sleep writes it into the record with `untilOf`'s end, and every reader
 * (the report, its name, the morning review, the shell) reads the record's own `night` and `until`,
 * never recomputes them, so a record written under the old noon turn keeps its meaning (L1010).
 */
export const nightOf = (ms: number): string => {
  const p = etParts(ms)
  const day = p.h < NIGHT_TURNS_AT_HOUR ? new Date(Date.UTC(p.y, p.mo - 1, p.d - 1)) : new Date(Date.UTC(p.y, p.mo - 1, p.d))
  return `${day.getUTCFullYear()}-${pad(day.getUTCMonth() + 1)}-${pad(day.getUTCDate())}`
}

/** When a night's sleep ends by itself: noon ET the next day. */
export const untilOf = (night: string): number => {
  const [y, mo, d] = night.split('-').map(Number) as [number, number, number]
  const next = new Date(Date.UTC(y, mo - 1, d + 1))
  return noonEt(next.getUTCFullYear(), next.getUTCMonth() + 1, next.getUTCDate())
}

/**
 * When sleep ends, as Dan reads it at `now` (#1479): "noon ET today (Wed Oct 21)" or "noon ET
 * tomorrow (Thu Oct 22)" when the end is that noon and still ahead, so a /sleep at 8:59 AM and one at
 * 9 AM read apart; any other end (one past, further off, or not at noon) is its time and day.
 */
export const endSaid = (until: number, now: number): string => {
  const e = etParts(until)
  const n = etParts(now)
  const tomorrow = new Date(Date.UTC(n.y, n.mo - 1, n.d + 1))
  const when =
    until <= now || until !== noonEt(e.y, e.mo, e.d)
      ? null
      : e.y === n.y && e.mo === n.mo && e.d === n.d
        ? 'today'
        : e.y === tomorrow.getUTCFullYear() && e.mo === tomorrow.getUTCMonth() + 1 && e.d === tomorrow.getUTCDate()
          ? 'tomorrow'
          : null
  return when ? `noon ET ${when} (${e.wd} ${MONTHS[e.mo - 1]} ${e.d})` : etWhen(until)
}

/** The calendar date of a moment in ET, YYYY-MM-DD: what a decision Dan gave is dated with (L249). */
export const etDate = (ms: number): string => {
  const p = etParts(ms)
  return `${p.y}-${pad(p.mo)}-${pad(p.d)}`
}

/**
 * Whether a moment is daytime in ET, 7 AM up to (not including) 7 PM, read off the zone itself so it
 * holds across the change to and from daylight time (#837): a message from Dan in it while asleep
 * asks whether he is up, since only /wake or "I'm up" ends sleep.
 */
export const isDaytimeEt = (ms: number): boolean => {
  const h = etParts(ms).h
  return h >= 7 && h < 19
}

/** A moment as Dan reads it: "11:42 PM ET on Wed Oct 7". */
export const etWhen = (ms: number): string => {
  const p = etParts(ms)
  const h12 = p.h % 12 === 0 ? 12 : p.h % 12
  return `${h12}:${pad(p.mi)} ${p.h < 12 ? 'AM' : 'PM'} ET on ${p.wd} ${MONTHS[p.mo - 1]} ${p.d}`
}

/** Where everything sleep keeps lives, this Mac only (never synced). */
export const sleepDir = (home: string) => `${home.replace(/\/+$/, '')}/.claude/state/sleep`

/** A night's notes file, named by its generation as hooks/lib/sleep-report.py names it (notes_path). */
export const notesOf = (home: string, generation: string) => `${sleepDir(home)}/notes/${generation.replace(/[^\w.-]/g, '_')}.jsonl`
