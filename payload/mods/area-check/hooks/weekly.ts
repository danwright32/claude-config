// The area check's weekly line in the issue review, and the escalation of a file sessions keep
// proceeding past (#1511). Pure: the clock and every file's text are handed in, so the issue
// review's runner (hooks/lib/area-check-review.mjs) does the reading and this decides what it says.
// It is not a hook module (hooks.json does not list it); tests/weekly.test.ts proves it and
// tests/test-area-check-weekly.sh at the repository root proves the runner against the real rotation script.
//
// The line carries counts only, never a path: the review it lands in may be in any repository, and
// a path from a work repository must never reach another one's review. The escalation does name a
// file, and so is made only for the repository the reviewing session is in.

export const DAY_MS = 24 * 60 * 60 * 1000
/** The weekly line is shown at most once in this long, on this Mac. */
export const LINE_EVERY_MS = 7 * DAY_MS
/** An escalation counts the sessions that proceeded past a file in this long. */
export const ESCALATE_WINDOW_MS = 30 * DAY_MS
/** This many distinct sessions proceeding past one file makes it an escalation. */
export const ESCALATE_SESSIONS = 5
/** One file is escalated at most once in this long. */
export const ESCALATE_AGAIN_MS = 30 * DAY_MS
/** Beside the log: when the weekly line was last delivered, in milliseconds. */
export const STAMP = 'weekly-line.stamp'
/** Beside the log: one claim file per escalated file, named by a hash of its key. */
export const ESCALATED = 'escalated'

/** What reading one of the area check's files found. */
export type Read = { state: 'missing' } | { state: 'unreadable'; code: string } | { state: 'read'; texts: string[] }

export type Rec = { atMs: number; r: Record<string, unknown> }

const TAIL = "Counts are this Mac's only: the other Mac keeps its own log."
const HEAD = 'Area check, this Mac, last 7 days:'
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`

/** The time rotationStamp wrote into a rotated file's name, or null for a name it did not write. */
export const stampTime = (name: string): number | null => {
  const m = /^(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})-(\d{3})Z-/.exec(name)
  if (!m) return null
  const t = Date.parse(`${m[1]}T${m[2]}:${m[3]}:${m[4]}.${m[5]}Z`)
  return Number.isFinite(t) ? t : null
}

/**
 * The rotated files a read since `sinceMs` needs: every .rotating file (not yet settled), and every
 * archive rotated at or after it (an archive rotated earlier holds only older lines). A name whose
 * stamp cannot be read is kept, so an odd name costs a read, never a count. The .decisions.jsonl
 * copies are never read: their lines are in the archive beside them.
 */
export const windowFiles = (names: readonly string[], sinceMs: number): string[] =>
  names.filter(n => {
    if (n.endsWith('.rotating')) return true
    if (!n.endsWith('.jsonl') || n.endsWith('.decisions.jsonl')) return false
    const t = stampTime(n)
    return t === null || t >= sinceMs
  })

/** Every record in the texts, an identical line once; a line that is not an object with a real time is malformed (L50). */
export const parseLines = (texts: readonly string[]): { records: Rec[]; malformed: number; lines: number } => {
  const seen = new Set<string>()
  const records: Rec[] = []
  let malformed = 0
  for (const text of texts) {
    for (const raw of text.split('\n')) {
      const l = raw.trim()
      if (!l || seen.has(l)) continue
      seen.add(l)
      let r: unknown
      try {
        r = JSON.parse(l)
      } catch {
        malformed++
        continue
      }
      const at = r && typeof r === 'object' && !Array.isArray(r) ? (r as Record<string, unknown>).at : undefined
      const atMs = typeof at === 'string' ? Date.parse(at) : NaN
      if (!Number.isFinite(atMs)) {
        malformed++
        continue
      }
      records.push({ atMs, r: r as Record<string, unknown> })
    }
  }
  return { records, malformed, lines: seen.size }
}

const issueState = (r: Record<string, unknown>): unknown =>
  r.issues && typeof r.issues === 'object' ? (r.issues as Record<string, unknown>).state : undefined

/** The weekly line: counts of the last seven days, or what stopped them being counted, never zeros in their place (L90). */
export const weeklyLine = (log: Read, errors: Read, nowMs: number): string => {
  if (log.state === 'missing') return `${HEAD} no load record, the log does not exist, so the mod has never started here. ${TAIL}`
  if (log.state === 'unreadable') return `${HEAD} no counts, the log could not be read (${log.code}). ${TAIL}`
  const { records, malformed, lines } = parseLines(log.texts)
  if (lines > 0 && records.length === 0) return `${HEAD} no counts, none of its ${lines} lines could be read. ${TAIL}`
  const since = nowMs - LINE_EVERY_MS
  const week = records.filter(x => x.atMs >= since).map(x => x.r)
  const of = (kind: string) => week.filter(r => r.kind === kind)
  const judged = of('judged')
  const unread = of('unread')
  const decided = of('decided')
  const sessions = new Set(of('loaded').map(r => String(r.session))).size
  const firings = judged.length + unread.length
  const held = judged.filter(r => r.decision === 'held' && r.applied === undefined).length + unread.filter(r => r.decision === 'held').length
  const applied = judged.filter(r => r.applied !== undefined).length
  const by = (d: string) => decided.filter(r => r.decision === d).length
  const issuesUnread = judged.filter(r => issueState(r) === 'unread').length
  const unjudged = of('unjudged').length

  let errorPart: string
  let errorsSay = false
  if (errors.state === 'unreadable') {
    errorPart = `errors not counted, the errors file could not be read (${errors.code})`
    errorsSay = true
  } else {
    // Lines of the errors file that cannot be read are said beside the count, never dropped, or a
    // damaged file reads as a confident count (L90). A file none of whose lines parse has no count.
    const e = errors.state === 'missing' ? { records: [], malformed: 0, lines: 0 } : parseLines(errors.texts)
    const n = e.records.filter(x => x.atMs >= since).length
    if (e.lines > 0 && e.records.length === 0) {
      errorPart = `errors not counted, none of the errors file's ${e.lines} lines could be read`
    } else {
      errorPart = plural(n, 'error', 'errors')
      if (e.malformed > 0) errorPart += `, and ${plural(e.malformed, 'line of the errors file', 'lines of the errors file')} could not be read`
    }
    errorsSay = n > 0 || e.malformed > 0
  }
  const parts = [
    `${plural(firings, 'first write judged', 'first writes judged')}, ${held} held`,
    `decided ${by('proceed')} proceed, ${by('fold')} fold, ${by('restructure')} restructure, and ${applied} let through by Dan's standing answer`,
    `${issuesUnread} judged with the issue list unread`,
    `${unjudged} not judged`,
    errorPart,
  ]
  if (malformed > 0) parts.push(`${plural(malformed, 'line of the log', 'lines of the log')} could not be read and ${malformed === 1 ? 'was' : 'were'} skipped`)
  if (sessions === 0) {
    const anything = firings + decided.length + unjudged + malformed > 0 || errorsSay
    const lead = 'no load record in 7 days, so the mod did not start here; that is not zero firings'
    return `${HEAD} ${anything ? [lead, ...parts].join('; ') : lead}. ${TAIL}`
  }
  return `${HEAD} ${[`loaded in ${plural(sessions, 'session', 'sessions')}`, ...parts].join('; ')}. ${TAIL}`
}

/** Whether the weekly line is due: a missing, unreadable or future stamp is due, so a bad stamp costs one extra line, never silence. */
export const lineDue = (stamp: string | null, nowMs: number): boolean => {
  if (stamp === null) return true
  const t = Number(stamp.trim())
  if (!Number.isFinite(t) || t > nowMs) return true
  return nowMs - t >= LINE_EVERY_MS
}

export type Escalation = { repo: string; path: string; sessions: number }

/**
 * The files of one repository that sessions proceeded past in at least ESCALATE_SESSIONS distinct
 * sessions in ESCALATE_WINDOW_MS (subagents share their session's id, so four agents count once),
 * where the newest judgement of the file in the window read the whole issue list and found no issue
 * naming it. A list read unread or truncated cannot say no issue names it, so it does not escalate.
 * Dan's standing answer is not a session deciding, so it never counts.
 */
export const escalations = (records: readonly Rec[], repo: string, nowMs: number): Escalation[] => {
  const want = repo.toLowerCase()
  const since = nowMs - ESCALATE_WINDOW_MS
  const mine = records.filter(x => x.atMs >= since && typeof x.r.repo === 'string' && x.r.repo.toLowerCase() === want && typeof x.r.path === 'string')
  const sessions = new Map<string, Set<string>>()
  for (const { r } of mine) {
    if (r.kind !== 'decided' || r.decision !== 'proceed') continue
    const p = r.path as string
    const set = sessions.get(p) ?? new Set<string>()
    set.add(String(r.session))
    sessions.set(p, set)
  }
  const out: Escalation[] = []
  for (const [path, set] of sessions) {
    if (set.size < ESCALATE_SESSIONS) continue
    const newest = mine
      .filter(x => x.r.kind === 'judged' && x.r.path === path)
      .reduce<Rec | null>((a, x) => (a === null || x.atMs >= a.atMs ? x : a), null)
    if (!newest || issueState(newest.r) !== 'read') continue
    const m = newest.r.matches
    if (!Array.isArray(m) || m.length > 0) continue
    out.push({ repo: want, path, sessions: set.size })
  }
  return out.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0))
}

/** One file's identity for its claim: the repository lowercased and the path. */
export const escalationKey = (e: Escalation): string => `${e.repo.toLowerCase()}\n${e.path}`

/**
 * Whether a claim file's text is old enough, or unreadable enough, to escalate the file again. A
 * claim stamped in the future is stale, as a future stamp makes the line due: one extra note, never
 * a file kept quiet for as long as a skewed clock says.
 */
export const claimStale = (text: string, nowMs: number): boolean => {
  try {
    const at = (JSON.parse(text) as { at?: unknown }).at
    return typeof at !== 'number' || !Number.isFinite(at) || at > nowMs || nowMs - at >= ESCALATE_AGAIN_MS
  } catch {
    return true
  }
}

/** The finding the spool carries to this repository's issue review. */
export const escalationNote = (e: Escalation): string => {
  const path = e.path.length > 200 ? `${e.path.slice(0, 197)}...` : e.path
  return `The area check held first writes to ${path}, and sessions proceeded past it in ${e.sessions} sessions in the last 30 days, with no open issue naming the file. File one issue for its structure, so later holds can fold into it, or record why it needs none.`
}
