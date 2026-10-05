import type { Account, Limit, Reading } from './room.ts'

// The account room's two files (#659), as pure data so the merging and refusals are tested alone.
//
// Readings: one file per Mac in iCloud Drive (`account-room/<Mac>.json`). Each Mac writes only its
// own, so iCloud never makes a conflict copy (L83); each reads every Mac's and keeps the newest
// reading per account. A file that cannot be read is named, never read as no readings (L215).
//
// Nicknames: one file in the claude-sync payload, so both Macs share them. The repository is
// public, so accounts are keyed by a hash of the account and org ids and no email is written there.
// Two Macs can answer for one account before a sync, so each entry carries when it was recorded and
// copies are merged entry by entry (a name over a skip, the later of two names), never replaced (#747).

/**
 * One Mac's readings file. `kept` holds entries this build cannot read (a newer version's, say):
 * never used, but written back unchanged so a rewrite does not erase them (L105).
 */
export type MacFile = { v: 1; mac: string; accounts: Record<string, MacEntry>; kept?: Record<string, unknown> }
/** An account as one Mac last saw it: who it is (for the card) and its newest reading there. */
export type MacEntry = { email: string; org: string; seenAt: number; reading?: Reading }
/**
 * One account's nickname: a name, or null where the ask was skipped so it is not asked again, and
 * when it was recorded (ms). An entry written by the first build (file version 1) has no time.
 */
export type NickEntry = { name: string | null; at?: number }
/** The nicknames, whichever version of the file they were read from. */
export type Nicknames = { names: Record<string, NickEntry> }

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

/**
 * The nicknames file, or why it cannot be read. Each version is read by the rules it was written
 * under (L1010, L1013): version 1 holds a name or null per account; version 2 (#747) an entry with
 * the name and the time it was recorded. A later version is named, never read as no nicknames, so
 * nothing is written over it (L105).
 */
export const parseNicknames = (text: string): Nicknames | string => {
  const j = json(text)
  if (typeof j === 'string' && j.startsWith('not readable JSON')) return j
  const o = j as { v?: unknown; names?: unknown }
  if (!o || typeof o !== 'object' || Array.isArray(o) || !o.names || typeof o.names !== 'object' || Array.isArray(o.names)) return 'not a nicknames file'
  if (o.v !== 1 && o.v !== 2) return o.v === undefined ? 'not a nicknames file' : `written by version ${String(o.v)} of the mod, which this one cannot read`
  const names: Record<string, NickEntry> = {}
  for (const [id, raw] of Object.entries(o.names as Record<string, unknown>)) {
    if (o.v === 1) {
      if (raw !== null && typeof raw !== 'string') return `the entry for ${id} is not a name`
      names[id] = { name: raw }
      continue
    }
    const e = raw as { name?: unknown; at?: unknown }
    const nameOk = !!e && typeof e === 'object' && (e.name === null || typeof e.name === 'string')
    const atOk = !!e && (e.at === undefined || (typeof e.at === 'number' && Number.isFinite(e.at)))
    if (!nameOk || !atOk) return `the entry for ${id} is not a name`
    names[id] = { name: e.name as string | null, ...(e.at === undefined ? {} : { at: e.at as number }) }
  }
  return { names }
}

/**
 * Which of two answers for one account stands (#747). A name beats a skip whatever their times: a
 * skip only means "do not ask again", so it never takes a name away, whichever Mac recorded it or
 * when. Of two names, or two skips, the later stands, an entry with no time (the first build's)
 * counting as older than any with one. An exact tie goes to the greater name, so every Mac settles
 * on the same entry whichever file it read first.
 */
const settle = (a: NickEntry, b: NickEntry): NickEntry => {
  if ((a.name === null) !== (b.name === null)) return a.name !== null ? a : b
  const ta = a.at ?? -Infinity
  const tb = b.at ?? -Infinity
  if (ta !== tb) return ta > tb ? a : b
  return (a.name ?? '') >= (b.name ?? '') ? a : b
}

/** Every account across several copies of the nicknames, each settled entry by entry. */
export const mergeNicknames = (files: readonly Nicknames[]): Nicknames => {
  const names: Record<string, NickEntry> = {}
  for (const f of files) {
    for (const [id, e] of Object.entries(f.names)) names[id] = own(names, id) ? settle(names[id] as NickEntry, e) : e
  }
  return { names }
}

/**
 * One answer recorded, merged rather than replacing (#747): a skip over a name changes nothing, and
 * a rename is stamped later than the name it replaces even when the other Mac's clock ran ahead, so
 * a rename made here is the answer that stands. A name over a skip takes this Mac's time as it is:
 * a skip's time never decides between names, so it is not carried into one.
 */
export const withName = (f: Nicknames, id: string, name: string | null, now: number): Nicknames => {
  const was = own(f.names, id) ? f.names[id] : undefined
  const rename = name !== null && was !== undefined && was.name !== null && was.at !== undefined
  const mine: NickEntry = { name, at: rename ? Math.max(now, (was.at as number) + 1) : now }
  return { names: { ...f.names, [id]: was ? settle(was, mine) : mine } }
}

/**
 * The file's text, version 2: one account per line, in key order, so the same nicknames are the
 * same bytes on both Macs and two Macs answering different accounts touch different lines. It holds
 * only the hashed keys and the names; the repository is public, so no email is ever written here.
 */
export const serializeNicknames = (f: Nicknames): string => {
  const ids = Object.keys(f.names).sort()
  if (!ids.length) return '{\n  "v": 2,\n  "names": {}\n}\n'
  const line = (id: string) => {
    const e = f.names[id] as NickEntry
    return `    ${JSON.stringify(id)}: ${JSON.stringify({ name: e.name, ...(e.at === undefined ? {} : { at: e.at }) })}`
  }
  return `{\n  "v": 2,\n  "names": {\n${ids.map(line).join(',\n')}\n  }\n}\n`
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
