// #1389: an overnight proposal is offered once and filed once. On 2026-10-20 an Overture session was
// handed four proposed issues as never put to Dan that had been filed on 2026-10-09, and three of
// them had been filed twice that day, by two sessions seconds apart. Nothing noticed a proposal had
// been acted on, and nothing stopped two sessions filing the same one.
//
// Each proposal has a folder in the shared sleep state, named by its repository and its title, so
// the same proposal from two nights or two sessions is one folder. It holds numbered entries, each
// linked into place whole, the way sleep-queue.sh keeps its claims (#842), so of two sessions
// writing the same number exactly one succeeds: a claim, taken before the proposal is offered and
// checked again before it is filed, a filed entry once it is, with the issue's link, and a declined
// entry when Dan leaves it unselected in a picker he answered. One GitHub already holds is found by
// the duplicate check each morning it is proposed, and shown, never recorded. Only the decisions
// live here; register.ts reads and writes the entries.

import { keyFile, repoKey } from './wake.ts'

/**
 * How long a claim holds while the session that took it stays open. A claim covers the gap between
 * offering a proposal and filing it. A session that has closed cannot file, so its claim ends at
 * once, by the session registry, and the proposal is free for the next morning (never lost). An open
 * one can: a morning picker left unanswered is put to Dan again with his next message in that
 * session, so its claim is kept through his day. A day, so a session left open and never answered
 * does not hold the proposal past the next night's morning.
 *
 * What it bounds (L174, L669): only how long a second session waits before offering a proposal
 * another session took and has not filed. Whether a proposal was FILED never rests on it: that is
 * the filed entry, or the duplicate check against GitHub, which find it whatever the window. Made
 * longer, an unanswered proposal is offered elsewhere later; made shorter than a day, a second
 * session could offer it while the first still waits on Dan, and the first one's filing would then
 * be refused as held elsewhere.
 */
export const CLAIM_MS = 24 * 60 * 60_000

// A title as words, so case and punctuation never make two proposals of one.
const words = (title: string) => title.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean).join('-')
// FNV-1a, enough to keep two long titles apart once cut to a file name's length.
const fnv = (s: string) => {
  let h = 0x811c9dc5
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i)
    h = Math.imul(h, 0x01000193) >>> 0
  }
  return h.toString(16).padStart(8, '0')
}

/** A proposal's folder in the sleep state; null for one with no title, which nothing can recognise again. */
export const proposalPath = (sleepDir: string, repo: string | null, title: string | null): string | null => {
  const w = words(title ?? '')
  if (!w) return null
  return `${sleepDir}/proposals/${keyFile(repoKey(repo))}/${w.slice(0, 80)}-${fnv(w)}`
}

type Entry =
  | { kind: 'claim'; by: string; at: number }
  | { kind: 'declined'; by: string; at: number }
  | { kind: 'filed'; by: string; at: number; url?: string; number?: number }

/**
 * Dan left this proposal unselected in a morning picker he answered. Declined is his decision, so it
 * never expires the way a claim does: a later night proposing it again shows it as declined rather
 * than offering it. Filing it anyway, when he asks, still files it, and filed outranks declined.
 */
export const declinedEntry = (by: string, at: number) => JSON.stringify({ kind: 'declined', by, at })

/** A claim on a proposal by this session, now. */
export const claimEntry = (by: string, at: number) => JSON.stringify({ kind: 'claim', by, at })
/**
 * A proposal a session filed, with the link gh printed and its number. Only a filing this mod saw
 * is recorded: a close match on GitHub only resembles, so it is shown each morning and never kept.
 */
export const filedEntry = (by: string, at: number, o: { url?: string; number?: number }) =>
  JSON.stringify({ kind: 'filed', by, at, ...(o.url ? { url: o.url } : {}), ...(o.number !== undefined ? { number: o.number } : {}) })

const entryOf = (text: string): Entry | null => {
  try {
    const j = JSON.parse(text) as Record<string, unknown>
    if (!j || typeof j !== 'object' || typeof j.by !== 'string' || typeof j.at !== 'number' || !Number.isFinite(j.at)) return null
    if (j.kind === 'claim') return { kind: 'claim', by: j.by, at: j.at }
    if (j.kind === 'declined') return { kind: 'declined', by: j.by, at: j.at }
    if (j.kind === 'filed')
      return {
        kind: 'filed',
        by: j.by,
        at: j.at,
        ...(typeof j.url === 'string' ? { url: j.url } : {}),
        ...(typeof j.number === 'number' && Number.isInteger(j.number) ? { number: j.number } : {}),
      }
    return null
  } catch {
    return null
  }
}

export type ProposalState =
  | { state: 'filed'; number: number | null; url: string | null }
  | { state: 'declined'; next: number }
  | { state: 'mine'; next: number }
  | { state: 'held'; by: string; at: number; next: number }
  | { state: 'free'; next: number }

/**
 * What a proposal's entries, by number, say of it now. Filed is for good. Otherwise the latest claim
 * decides: this session's own is its own; another's holds while its session is open (or the
 * registry cannot be read) and it is younger than CLAIM_MS; anything else is free. `next` is the
 * number the next entry takes: an entry that cannot be read decides nothing but keeps its number.
 */
export const judgeProposal = (entries: Readonly<Record<string, string>>, self: string, open: ReadonlySet<string> | null, now: number): ProposalState => {
  const read = Object.entries(entries)
    .map(([n, text]) => ({ n: Number(n), e: entryOf(text) }))
    .filter(x => Number.isInteger(x.n) && x.n > 0)
    .sort((a, b) => a.n - b.n)
  const next = (read.length ? (read[read.length - 1] as { n: number }).n : 0) + 1
  const filed = read.filter(x => x.e?.kind === 'filed').pop()?.e
  if (filed && filed.kind === 'filed') return { state: 'filed', number: filed.number ?? null, url: filed.url ?? null }
  if (read.some(x => x.e?.kind === 'declined')) return { state: 'declined', next }
  const claim = read.filter(x => x.e?.kind === 'claim').pop()?.e
  if (!claim) return { state: 'free', next }
  if (claim.by === self) return { state: 'mine', next }
  if (now - claim.at < CLAIM_MS && (open === null || open.has(claim.by))) return { state: 'held', by: claim.by, at: claim.at, next }
  return { state: 'free', next }
}

/**
 * The issue milestone-candidates.sh says a proposal already is: its first CLOSE-MATCH, the one line
 * of its output about the same work (issue-review.md drops an idea on it). Its siblings and its
 * duplicate risks only share words, and never rule.
 */
export const closeMatchIn = (stdout: string): { number: number; title: string; closed: boolean } | null => {
  for (const line of stdout.split('\n')) {
    const m = /^CLOSE-MATCH \S+ #(\d+) (.*?) \[in: [^\]]*\] \[shares: [^\]]*\]( \[closed\])?\s*$/.exec(line)
    if (m) return { number: Number(m[1]), title: m[2] as string, closed: m[3] !== undefined }
  }
  return null
}

/**
 * The issue link a `gh issue create` printed, and its number. Whose repository it is, is mod-kit's
 * link reader's to say ($.modkit.linkRepo), which register.ts asks before recording it.
 */
export const issueLinkIn = (text: string): { url: string; number: number } | null => {
  const m = /https?:\/\/\S+?\/issues\/(\d+)/.exec(text)
  return m ? { url: m[0], number: Number(m[1]) } : null
}

/**
 * The proposals Dan declined in a picker he answered (#1389): the options numbered as this session
 * offered them (1.n) that he did not select, by number. A picker with no answer declines nothing:
 * it is put to him again (#1285), never read as a no. An answer is matched by each option's label,
 * whether the picker gave the selection as a list or as one string of labels.
 */
export const declinedIn = (questions: unknown, answers: unknown, offered: ReadonlySet<string>): string[] => {
  if (!Array.isArray(questions) || !answers || typeof answers !== 'object') return []
  const out: string[] = []
  for (const q of questions as { question?: unknown; options?: unknown }[]) {
    const given = (answers as Record<string, unknown>)[String(q?.question ?? '')]
    const picked = Array.isArray(given) ? given.map(String) : typeof given === 'string' ? [given] : []
    if (!picked.some(p => p.trim() !== '')) continue
    for (const o of Array.isArray(q.options) ? (q.options as { label?: unknown }[]) : []) {
      const label = String(o?.label ?? '')
      const n = /^(1\.\d+)\b/.exec(label)?.[1]
      if (!n || !offered.has(n)) continue
      if (!picked.some(p => p.includes(label))) out.push(n)
    }
  }
  return out
}
