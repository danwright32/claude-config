import type { ModKitGh } from '../.claude-plugin/types/mod-kit/index.d.ts'
import type { IsItLiveOwed } from '../types/index.d.ts'
import { MOD } from './card.ts'

// The card after every merge (#1244). The card used to appear only when Claude chose to call a
// deferred tool whose description, the one place that said to call it, Claude never saw. Now a
// merge GitHub confirms carries a line saying to show the card and how to load the tool, and a turn
// end is refused while a PR merged in the session has no card. Pure: register.ts reads the command
// through mod-kit's readers, asks GitHub, and keeps what this decides.

export const TOOL = `mcp__${MOD}__card`
const LOAD = `load the card tool with ToolSearch with the query "select:${TOOL}"`

/**
 * A merge a command makes at once: the PR as it names it (a number, a link or a branch; none for the
 * checkout's own), its number where that says it, and the repository it names (lower case; null when
 * it names one that cannot be read). Undefined for anything but `gh pr merge`, and for --auto and
 * --disable-auto, which merge nothing at the time they run.
 */
export type MergeCall = { selector?: string; pr?: number; named?: string | null }
export const mergeCallOf = (a: ModKitGh | undefined): MergeCall | undefined => {
  if (!a || a.sub !== 'pr' || a.act !== 'merge') return undefined
  if (a.flags.some(f => f.name === '--auto' || f.name === '--disable-auto')) return undefined
  const selector = a.positionals[0]
  const n = selector === undefined ? undefined : (/^#?(\d+)$/.exec(selector)?.[1] ?? /\/pull\/(\d+)\/?(?:[?#].*)?$/.exec(selector)?.[1])
  return {
    ...(selector !== undefined ? { selector } : {}),
    ...(n !== undefined ? { pr: Number(n) } : {}),
    ...(a.unreadable ? { named: null } : a.named !== undefined ? { named: a.named } : {}),
  }
}

/** What GitHub is asked about a merge: the fields proofOf reads. */
export const VIEW_FIELDS = 'number,state,mergedAt,url'
/** How far GitHub's clock may sit behind this Mac's before a merge reads as older than the command. */
export const SKEW_MS = 10 * 60_000
/** How long a merge the helper makes in the background is asked about before it is let go: its own deadline is an hour. */
export const WAIT_MS = 3 * 60 * 60_000

/**
 * What GitHub said about the PR a merge named, for a command that ran at `since`: merged by it, open
 * or closed (so it merged nothing), or not proven either way, with why. A PR GitHub found merged
 * before the command ran is not proven to be the one it merged: the same number in another
 * repository, asked in the wrong folder, would read as merged too (L237).
 */
export type Proof = { kind: 'merged'; pr: number; url: string } | { kind: 'open' } | { kind: 'closed' } | { kind: 'unproven'; why: string }
export const proofOf = (stdout: string, since: number): Proof => {
  let v: { number?: unknown; state?: unknown; mergedAt?: unknown; url?: unknown }
  try {
    v = JSON.parse(stdout)
  } catch {
    return { kind: 'unproven', why: "GitHub's answer could not be read" }
  }
  if (v.state === 'OPEN') return { kind: 'open' }
  if (v.state === 'CLOSED') return { kind: 'closed' }
  if (v.state !== 'MERGED' || typeof v.number !== 'number' || typeof v.url !== 'string') return { kind: 'unproven', why: `GitHub answered state ${JSON.stringify(v.state)}` }
  const at = typeof v.mergedAt === 'string' ? Date.parse(v.mergedAt) : NaN
  if (Number.isNaN(at)) return { kind: 'unproven', why: 'GitHub gave no time for the merge' }
  if (at < since - SKEW_MS) return { kind: 'unproven', why: `the #${v.number} GitHub found from this folder merged at ${v.mergedAt}, before this command ran, so it may be another repository's` }
  return { kind: 'merged', pr: v.number, url: v.url }
}

/** How an owed merge is named: its repository and number, or the number alone, said. */
export const nameOf = (o: Pick<IsItLiveOwed, 'repo' | 'pr'>) => (o.repo ? `${o.repo}#${o.pr}` : `#${o.pr} (its repository was not read from the command)`)

const REPORT = 'Name it in your report: the session that dispatched you shows Dan its is it live card, and its turn cannot end until one is made.'

/** The line a merge's result carries, by what GitHub said; `agent` for a subagent's call. */
export const nudgeOf = (o: IsItLiveOwed, agent: boolean): string => {
  if (o.how === 'waiting') {
    return `merge-when-ready.sh is merging #${o.pr} in the background. When it reports #${o.pr} merged, ${agent ? REPORT.charAt(0).toLowerCase() + REPORT.slice(1) : `show Dan its is it live card: ${LOAD}. A turn end after the merge is refused until a card for it is made.`}`
  }
  if (o.how === 'unproven') {
    const lead = `GitHub did not confirm that #${o.pr} merged just now (${o.why ?? 'no reason given'}).`
    return agent
      ? `${lead} If it did, ${REPORT.charAt(0).toLowerCase() + REPORT.slice(1)}`
      : `${lead} If it did, show Dan its is it live card: ${LOAD}. If it did not, call the card tool for it anyway: it asks GitHub, and its answer that #${o.pr} is not merged settles it. The turn cannot end until one of the two.`
  }
  return agent
    ? `You merged ${nameOf(o)}. ${REPORT}`
    : `You merged ${nameOf(o)}. Show Dan its is it live card now: ${LOAD}, then call it with deploy "deploying" while the deploy runs, and again once you have checked it. The turn cannot end until a card for it is made.`
}

/** Why a turn end is refused, naming every merge still owed a card. */
export const refusalOf = (owed: IsItLiveOwed[]): string =>
  `No is it live card yet for ${owed.map(nameOf).join(', ')}, merged in this session. ${LOAD.charAt(0).toUpperCase() + LOAD.slice(1)}, and call it for each, with deploy "deploying", "live", "failed", "unreachable" or "none", whichever you can honestly say now. For a merge GitHub never confirmed, the card tool's answer that it is not merged settles it too.`

/** What is said when a turn ends while a card is still owed, the turn end having been refused once in this chain. */
export const letGoOf = (owed: IsItLiveOwed[]): string => `No is it live card for ${owed.map(nameOf).join(', ')}: the turn ended without one.`
