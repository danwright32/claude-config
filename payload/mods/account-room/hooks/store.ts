import type { Account, Limit, Reading } from './room.ts'

// The account room's two files (#659), as pure data so the merging and refusals are tested alone.
//
// Readings: one file per Mac in iCloud Drive (`account-room/<Mac>.json`). Each Mac writes only its
// own, so iCloud never makes a conflict copy (L83); each reads every Mac's and keeps the newest
// reading per account. A file that cannot be read is named, never read as no readings (L215).
//
// Nicknames: one file in the claude-sync payload, so both Macs share them. The repository is
// public, so accounts are keyed by a hash of the account and org ids and no email is written there.

/**
 * One Mac's readings file. `kept` holds entries this build cannot read (a newer version's, say):
 * never used, but written back unchanged so a rewrite does not erase them (L105).
 */
export type MacFile = { v: 1; mac: string; accounts: Record<string, MacEntry>; kept?: Record<string, unknown> }
/** An account as one Mac last saw it: who it is (for the card) and its newest reading there. */
export type MacEntry = { email: string; org: string; seenAt: number; reading?: Reading }
/** The nicknames file: a name, or null where the ask was skipped so it is not asked again. */
export type Nicknames = { v: 1; names: Record<string, string | null> }

const own = (o: object, k: string) => Object.prototype.hasOwnProperty.call(o, k)

/** The account's key: the first 16 hex digits of SHA-256 over "<account id>:<org id>". */
export const accountKey = async (accountUuid: string, organizationUuid: string): Promise<string> => {
  const bytes = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${accountUuid}:${organizationUuid}`)))
  return Array.from(bytes.slice(0, 8), b => b.toString(16).padStart(2, '0')).join('')
}

const isLimit = (l: unknown): l is Limit => {
  const o = l as Limit
  return (
    !!o &&
    typeof o === 'object' &&
    typeof o.used === 'number' &&
    Number.isFinite(o.used) &&
    (o.resetsAt === null || (typeof o.resetsAt === 'number' && Number.isFinite(o.resetsAt))) &&
    (o.takenAt === undefined || (typeof o.takenAt === 'number' && Number.isFinite(o.takenAt)))
  )
}
const isReading = (r: unknown): r is Reading => {
  const o = r as Reading
  if (!o || typeof o !== 'object' || typeof o.takenAt !== 'number' || !Number.isFinite(o.takenAt)) return false
  if (o.five !== undefined && !isLimit(o.five)) return false
  if (o.week !== undefined && !isLimit(o.week)) return false
  return o.five !== undefined || o.week !== undefined
}
const isEntry = (e: unknown): e is MacEntry => {
  const o = e as MacEntry
  return !!o && typeof o === 'object' && typeof o.email === 'string' && typeof o.org === 'string' && typeof o.seenAt === 'number' && (o.reading === undefined || isReading(o.reading))
}

const json = (text: string): unknown | string => {
  try {
    return JSON.parse(text) as unknown
  } catch (err) {
    return `not readable JSON (${String((err as Error)?.message ?? err)})`
  }
}

/** A readings file, or why it cannot be read. A malformed entry is dropped, not the whole file. */
export const parseMacFile = (text: string): MacFile | string => {
  const j = json(text)
  if (typeof j === 'string' && j.startsWith('not readable JSON')) return j
  const o = j as Partial<MacFile>
  if (!o || typeof o !== 'object' || Array.isArray(o) || typeof o.accounts !== 'object' || o.accounts === null || typeof o.mac !== 'string') return 'not a readings file'
  if (o.v !== 1) return `written by version ${String(o.v)} of the mod, which this one cannot read`
  const accounts: Record<string, MacEntry> = {}
  const kept: Record<string, unknown> = {}
  for (const [id, e] of Object.entries(o.accounts)) {
    if (isEntry(e)) accounts[id] = e
    else kept[id] = e
  }
  return { v: 1, mac: o.mac, accounts, ...(Object.keys(kept).length ? { kept } : {}) }
}

/** The nicknames file, or why it cannot be read. */
export const parseNicknames = (text: string): Nicknames | string => {
  const j = json(text)
  if (typeof j === 'string' && j.startsWith('not readable JSON')) return j
  const o = j as Partial<Nicknames>
  if (!o || typeof o !== 'object' || o.v !== 1 || !o.names || typeof o.names !== 'object' || Array.isArray(o.names)) return 'not a nicknames file'
  for (const [id, n] of Object.entries(o.names)) if (n !== null && typeof n !== 'string') return `the entry for ${id} is not a name`
  return { v: 1, names: { ...o.names } }
}

/**
 * Two readings of one account combined window by window (L510): each window keeps its newest figure,
 * judged by that window's own time (`takenAt` on the limit when it was carried over from an earlier
 * reading, else the reading's). The result is dated by its oldest window, so "as of" never claims a
 * figure is fresher than it is, and a window whose time differs from that date carries its own.
 */
export const combine = (a: Reading | undefined, b: Reading | undefined): Reading | undefined => {
  if (!a || !b) return a ?? b
  const pick = (w: 'five' | 'week') => {
    const la = a[w] ? { ...a[w], takenAt: a[w]?.takenAt ?? a.takenAt } : undefined
    const lb = b[w] ? { ...b[w], takenAt: b[w]?.takenAt ?? b.takenAt } : undefined
    if (!la || !lb) return la ?? lb
    // On a tie the second, the later of the two by call, wins.
    return lb.takenAt >= la.takenAt ? lb : la
  }
  const five = pick('five')
  const week = pick('week')
  const takenAt = Math.min(...[five, week].filter(l => l !== undefined).map(l => l.takenAt))
  const strip = (l: Limit | undefined) => (l === undefined ? undefined : l.takenAt === takenAt ? { used: l.used, resetsAt: l.resetsAt } : l)
  const f = strip(five)
  const wk = strip(week)
  return { takenAt, ...(f ? { five: f } : {}), ...(wk ? { week: wk } : {}) }
}


/**
 * This Mac's file with one sighting of an account added: who it is and when it was seen, and the
 * reading when it is newer than the one already there (two sessions can write out of order).
 */
export const withSighting = (f: MacFile | undefined, mac: string, who: Pick<Account, 'id' | 'email' | 'org'>, reading: Reading | undefined, now: number): MacFile => {
  const accounts = { ...(f?.accounts ?? {}) }
  const was = own(accounts, who.id) ? accounts[who.id] : undefined
  const keep = combine(was?.reading, reading)
  accounts[who.id] = { email: who.email, org: who.org, seenAt: now, ...(keep ? { reading: keep } : {}) }
  const kept = { ...(f?.kept ?? {}) }
  delete kept[who.id]
  return { v: 1, mac, accounts, ...(Object.keys(kept).length ? { kept } : {}) }
}

/** The file's text, with any entries this build could not read put back unchanged. */
export const serialize = (f: MacFile): string => `${JSON.stringify({ v: 1, mac: f.mac, accounts: { ...(f.kept ?? {}), ...f.accounts } })}\n`

/** Every account across the Macs' files: the newest reading of each, and who it is as last seen. */
export const merge = (files: readonly MacFile[]): Map<string, Account> => {
  const out = new Map<string, Account>()
  const seen = new Map<string, number>()
  for (const f of files) {
    for (const [id, e] of Object.entries(f.accounts)) {
      const cur = out.get(id)
      const reading = combine(cur?.reading, e.reading)
      const fresher = !cur || e.seenAt > (seen.get(id) ?? -Infinity)
      const who = fresher ? { email: e.email, org: e.org } : { email: cur.email, org: cur.org }
      if (fresher) seen.set(id, e.seenAt)
      out.set(id, { id, ...who, ...(reading ? { reading } : {}) })
    }
  }
  return out
}

/** The other Macs' files in the folder listing: a downloaded one by name, or one iCloud has not downloaded. */
export type OtherMac = { mac: string; file: string } | { mac: string; notDownloaded: true }
export const macsIn = (names: readonly string[], ownMac: string): OtherMac[] => {
  const out: OtherMac[] = []
  for (const n of names) {
    const placeholder = /^\.(.+)\.json\.icloud$/.exec(n)
    if (placeholder) {
      if (placeholder[1] !== ownMac) out.push({ mac: placeholder[1] as string, notDownloaded: true })
      continue
    }
    const m = /^([^.][^/]*)\.json$/.exec(n)
    if (m && m[1] !== ownMac) out.push({ mac: m[1] as string, file: n })
  }
  return out
}
