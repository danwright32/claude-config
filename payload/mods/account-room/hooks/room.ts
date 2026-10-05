import type { AccountRoomLimit, AccountRoomPhase, AccountRoomReading, AccountRoomStop } from '../types/index.d.ts'

// The account room's judgments (#659), pure so each is tested on its own. Behaviour is the spec
// agreed with Dan on 2026-10-04 (issue #659); the look and every sentence are the design rounds of
// the same day (docs/mods-design.md "Account room (#659)").

const MIN = 60_000
const HOUR = 60 * MIN
const DAY = 24 * HOUR

/** The two subscription limits, as the card names them. */
export type Which = 'five' | 'week'
const LABEL: Record<Which, string> = { five: '5h', week: 'week' }
/** The card appears at 95% on the 5 hour limit or 90% on the weekly one (the spec). */
export const TRIGGER: Record<Which, number> = { five: 95, week: 90 }
const KIND: Record<string, Which> = { five_hour: 'five', seven_day: 'week' }

/** One limit as read, and one account's figures at one moment: declared once, in the contract. */
export type Limit = AccountRoomLimit
export type Reading = AccountRoomReading
/** An account the mod knows of, by its key (a hash of the account and org ids, never the ids). */
export type Account = { id: string; email: string; org: string; nickname?: string | null; reading?: Reading }

/** One rate limit window as the engine reports it (SessionRateLimit). */
export type Window = { kind: string; percentUsed: number; resetsAt?: string }

/** The engine's windows as a reading; undefined when it reported neither subscription limit. */
export const fromRateLimits = (windows: readonly Window[], now: number): Reading | undefined => {
  const r: Reading = { takenAt: now }
  for (const w of windows) {
    const which = Object.prototype.hasOwnProperty.call(KIND, w.kind) ? KIND[w.kind] : undefined
    if (!which || typeof w.percentUsed !== 'number' || !Number.isFinite(w.percentUsed)) continue
    const at = w.resetsAt === undefined ? NaN : Date.parse(w.resetsAt)
    r[which] = { used: w.percentUsed, resetsAt: Number.isFinite(at) ? at : null }
  }
  return r.five || r.week ? r : undefined
}

/** A limit's use now: a reading whose reset has passed counts as 0% (the spec). */
export const effective = (l: Limit | undefined, now: number): number | undefined => {
  if (!l) return undefined
  if (l.resetsAt !== null && l.resetsAt <= now) return 0
  return l.used
}

/** Which limits of this account's own reading have reached the trigger. */
export const triggered = (r: Reading | undefined, now: number): Which[] =>
  (['five', 'week'] as const).filter(w => (effective(r?.[w], now) ?? -1) >= TRIGGER[w])

const OTHER: Record<Which, Which> = { five: 'week', week: 'five' }

/**
 * Whether another account has more room than this one on every limit that triggered the card, and
 * is not at 100% on a limit that did not. An account with no figure for a triggering limit cannot
 * be shown to have room, so it does not qualify.
 */
const qualifies = (other: Reading | undefined, here: Reading, on: readonly Which[], now: number): boolean => {
  if (!other) return false
  for (const w of on) {
    const theirs = effective(other[w], now)
    const mine = effective(here[w], now)
    if (theirs === undefined || mine === undefined || !(theirs < mine)) return false
  }
  for (const w of on.map(x => OTHER[x]).filter(x => !on.includes(x))) {
    if ((effective(other[w], now) ?? 0) >= 100) return false
  }
  return true
}

const room = (a: Account, w: Which, now: number) => {
  const e = effective(a.reading?.[w], now)
  return e === undefined ? -Infinity : 100 - e
}

/** The soonest reset still ahead across every account, this one included. */
export type Soonest = { account: Account; limit: Which; at: number }

export type Verdict =
  | { kind: 'none' }
  | { kind: 'room'; here: Account; best: Account }
  | { kind: 'no-room'; here: Account; soonest?: Soonest; unread: Account[] }

/**
 * What the card says: nothing below the trigger; else the qualifying account with the most weekly
 * room (then the most 5 hour room, then the newest reading); else that none has room, with the
 * soonest reset and every account with no reading yet, so a missing reading never reads as a full
 * account (L622).
 */
export const verdict = (here: Account, others: readonly Account[], now: number): Verdict => {
  const on = triggered(here.reading, now)
  if (!on.length || !here.reading) return { kind: 'none' }
  const mine = here.reading
  const fit = others.filter(a => a.id !== here.id && qualifies(a.reading, mine, on, now))
  if (fit.length) {
    const best = [...fit].sort(
      (a, b) => room(b, 'week', now) - room(a, 'week', now) || room(b, 'five', now) - room(a, 'five', now) || (b.reading?.takenAt ?? 0) - (a.reading?.takenAt ?? 0),
    )[0] as Account
    return { kind: 'room', here, best }
  }
  let soonest: Soonest | undefined
  for (const a of [here, ...others.filter(o => o.id !== here.id)]) {
    for (const w of ['five', 'week'] as const) {
      const at = a.reading?.[w]?.resetsAt
      if (typeof at === 'number' && at > now && (!soonest || at < soonest.at)) soonest = { account: a, limit: w, at }
    }
  }
  const unread = others.filter(a => a.id !== here.id && !a.reading)
  return { kind: 'no-room', here, ...(soonest ? { soonest } : {}), unread }
}

/** An account by its nickname, else its email and org (the spec: email plus org until one is set). */
export const nameOf = (a: Account): string => (a.nickname ? a.nickname : a.org ? `${a.email} (${a.org})` : a.email)

const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']

/**
 * A reset time as the card shows it, in the Mac's own time zone (`offset`, minutes east of UTC, as
 * `date +%z` gives it): "6:40 PM" when it falls on today's local date, "Thu 9 AM" otherwise, the
 * minutes left out on the hour, as the design rounds drew them. When the time zone could not be
 * read (`offset` null) the time is UTC and says so, rather than passing for local (L11). Given as a
 * function, the offset is the one in force at each instant, so a reset after a clock change reads
 * right.
 */
export type Offset = number | null | ((at: number) => number | null)

export const clockText = (at: number, now: number, offset: Offset): string => {
  const at0 = typeof offset === 'function' ? offset(at) : offset
  const now0 = typeof offset === 'function' ? offset(now) : offset
  if (at0 === null || now0 === null) return `${clockText(at, now, 0)} UTC`
  const local = new Date(at + at0 * MIN)
  const today = new Date(now + now0 * MIN)
  const h24 = local.getUTCHours()
  const m = local.getUTCMinutes()
  const h = h24 % 12 === 0 ? 12 : h24 % 12
  const time = `${h}${m ? `:${String(m).padStart(2, '0')}` : ''} ${h24 < 12 ? 'AM' : 'PM'}`
  const sameDay = local.getUTCFullYear() === today.getUTCFullYear() && local.getUTCMonth() === today.getUTCMonth() && local.getUTCDate() === today.getUTCDate()
  return sameDay ? time : `${DAYS[local.getUTCDay()]} ${time}`
}

/** How old a reading is, in its largest unit: "2h", as in "as of 2h ago". */
export const ago = (ms: number): string => {
  if (!(ms >= MIN)) return '<1m'
  if (ms >= DAY) return `${Math.floor(ms / DAY)}d`
  if (ms >= HOUR) return `${Math.floor(ms / HOUR)}h`
  return `${Math.floor(ms / MIN)}m`
}

/** What Switch is doing (the contract's AccountRoomPhase). */
export type Phase = AccountRoomPhase

/** The parts of a band line, as mod-kit draws them. */
export type Part = { text: string; color?: string; dim?: boolean } | { button: string; label: string }
export type Card = { lines: Part[][]; frame: { kind: 'box' } }

/**
 * Readings GitHub could not give, with why: one Mac's file, or every other Mac's (mac null) when the
 * repository's readings folder itself could not be listed.
 */
export type Unavailable = { mac: string | null; why: string }
/** This Mac's own readings that could not be saved to the repository, with why. */
export type Unsaved = { mac: string; why: string }

/**
 * What a limit's figure reads on the card: the whole percent left. One definition, so the card and
 * the rule deciding a figure has moved enough to send to the other Macs never disagree (L16).
 */
export const leftOf = (used: number): number => Math.max(0, Math.min(100, Math.round(100 - used)))

const AMBER = 'warning'
const RED = 'error'
const GAP = { text: '  ' }
const SPACE = { text: ' ' }
const SEP = ' · '

const figures = (a: Account, now: number, offset: Offset): string => {
  const parts: string[] = []
  for (const w of ['five', 'week'] as const) {
    const l = a.reading?.[w]
    if (!l) continue
    const left = leftOf(effective(l, now) ?? 0)
    // A reset already passed is not the next one, which the reading cannot know.
    const reset = l.resetsAt !== null && l.resetsAt > now ? `, resets ${clockText(l.resetsAt, now, offset)}` : ''
    parts.push(`${left}% of ${LABEL[w]} left${reset}`)
  }
  if (a.reading) parts.push(`as of ${ago(now - a.reading.takenAt)} ago`)
  return parts.join(SEP)
}

const listed = (names: string[]) => (names.length <= 1 ? names.join('') : `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`)

/**
 * The red lead for a Switch that stopped at the sign out, one sentence per measured cause (#736,
 * L11, L440). "claude.ai didn't confirm the sign out" is the design round's sentence and is kept for
 * the one case it describes, a check that ran and did not print "signed out"; the others say what
 * was found instead of claiming a check that never ran. Typed as a complete record, so a new cause
 * cannot fall back on another's sentence (L113).
 */
export const STOPPED: Record<AccountRoomStop, string> = {
  'no-route': 'No sign out was attempted: no browser logout route is set up. Nothing was changed.',
  'logout-failed': 'The browser logout command failed. Nothing else was changed.',
  'check-not-run': 'The signed out check could not be run. Nothing else was changed.',
  'not-confirmed': "claude.ai didn't confirm the sign out. Nothing else was changed.",
  interrupted: 'A reload cut Switch off before the sign out was confirmed. Nothing else was changed.',
}

/**
 * The boxed card in the band (design rounds 1 to 3 and the wording rounds): an amber lead line with
 * its buttons, then one line of figures or of the soonest reset. While Switch works the lead itself
 * is the progress with elapsed seconds and the buttons go; a Switch stopped at the sign out turns it
 * red, saying why (STOPPED).
 */
export const card = (f: { verdict: Verdict; phase: Phase; now: number; offset: Offset; unavailable: readonly Unavailable[]; unsaved?: Unsaved }): Card => {
  const v = f.verdict
  const lines: Part[][] = []
  if (v.kind === 'room') {
    const name = nameOf(v.best)
    if (f.phase.kind === 'working') {
      const secs = Math.max(0, Math.floor((f.now - f.phase.since) / 1000))
      const doing = f.phase.step === 'logout' ? 'signing claude.ai out in the browser' : 'opening the sign in page'
      lines.push([{ text: `Switching to ${name}: ${doing}… ${secs}s`, color: AMBER }])
    } else if (f.phase.kind === 'failed') {
      lines.push([{ text: STOPPED[f.phase.cause ?? 'not-confirmed'], color: RED }, GAP, { button: 'retry', label: 'Try again' }, SPACE, { button: 'dismiss', label: 'Dismiss' }])
    } else {
      lines.push([{ text: `This account is low. ${name} has room`, color: AMBER }, GAP, { button: 'switch', label: 'Switch' }, SPACE, { button: 'dismiss', label: 'Dismiss' }])
    }
    lines.push([{ text: figures(v.best, f.now, f.offset) }])
  } else if (v.kind === 'no-room') {
    lines.push([{ text: 'This account is low. No other account has room', color: AMBER }, GAP, { button: 'dismiss', label: 'Dismiss' }])
    const info: string[] = []
    if (v.soonest) {
      const who = v.soonest.account.id === v.here.id ? "This account's" : `${nameOf(v.soonest.account)}'s`
      info.push(`${who} ${LABEL[v.soonest.limit]} resets first, at ${clockText(v.soonest.at, f.now, f.offset)}`)
    }
    if (v.unread.length) info.push(`${listed(v.unread.map(nameOf))} ${v.unread.length === 1 ? 'has' : 'have'} no reading yet and may have room`)
    if (info.length) lines.push([{ text: info.join(SEP) }])
  }
  // Readings GitHub could not give, and this Mac's own that could not be saved, are said, never
  // dropped (the spec, L215). Their wording and place were not part of a design round: see
  // docs/mods-design.md.
  if (v.kind !== 'none') {
    for (const u of f.unavailable) lines.push([{ text: u.mac === null ? `The other Macs' readings are unavailable: ${u.why}` : `${u.mac}'s readings are unavailable: ${u.why}` }])
    if (f.unsaved) lines.push([{ text: `${f.unsaved.mac}'s readings could not be saved to GitHub: ${f.unsaved.why}` }])
  }
  return { lines, frame: { kind: 'box' } }
}
