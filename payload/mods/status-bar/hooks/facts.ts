import type { StatusBarMode } from '../types/index.d.ts'

// The status bar's judgments, pure so each is tested on its own (#610, docs/mods-design.md
// "Status bar (#610)"). The wording follows the design rounds' renderings: "PR #636 checks
// failing", "1 job running", "dev server kept 2h 14m", "2 unpushed commits", "ctx 74%".

const MIN = 60_000
const HOUR = 60 * MIN
const DAY = 24 * HOUR

/** Context above this share of the window shows the Compact row (the spec's "about 70%"). */
export const CONTEXT_LOOK = 70
/** The Compact row also shows this close to the prompt cache going cold, and the toast fires. */
export const CACHE_WARN_MS = 5 * MIN

/** A length of time as the band shows it: 14m, 2h 14m, 1d 3h; under a minute <1m. */
export const span = (ms: number): string => {
  if (!(ms >= MIN)) return '<1m'
  if (ms >= DAY) return `${Math.floor(ms / DAY)}d ${Math.floor((ms % DAY) / HOUR)}h`
  if (ms >= HOUR) return `${Math.floor(ms / HOUR)}h ${Math.floor((ms % HOUR) / MIN)}m`
  return `${Math.floor(ms / MIN)}m`
}

export type Checks = 'failing' | 'running' | 'passing' | 'none'
/** One entry of gh's statusCheckRollup: a check run (status, conclusion) or a commit status (state). */
export type RollupEntry = { status?: string; conclusion?: string | null; state?: string }

const FAILED = new Set(['FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'STARTUP_FAILURE'])
const UNFINISHED_STATE = new Set(['PENDING', 'EXPECTED'])

/** The checks on a PR as one state, failing ahead of running since it is the more urgent. */
export const checksOf = (rollup: readonly RollupEntry[]): Checks => {
  if (rollup.length === 0) return 'none'
  if (rollup.some(c => FAILED.has(String(c.conclusion ?? '')) || FAILED.has(String(c.state ?? '')))) return 'failing'
  const unfinished = (c: RollupEntry) =>
    c.state !== undefined ? UNFINISHED_STATE.has(c.state) : c.status !== undefined && c.status !== 'COMPLETED'
  if (rollup.some(unfinished)) return 'running'
  return 'passing'
}

/** git rev-list --count's answer, or undefined when it is not a count (never read as zero, L215). */
export const unpushedOf = (stdout: string): number | undefined => {
  const t = stdout.trim()
  return /^\d+$/.test(t) ? Number(t) : undefined
}

/** The last reading of the branch's PR, and whether the refresh since then failed. */
export type PrReading = { number: number; checks: Checks; readAt: number; isStale: boolean }
/**
 * The last reading of the commits not pushed anywhere, and whether the refresh since then failed:
 * a count that could not be read again is never a zero (L215), it is the last one, aged (#697).
 */
export type UnpushedReading = { count: number; readAt: number; isStale: boolean }
/**
 * One background job as the job watcher (#611) reports it through $.jobs. state and owner came with
 * #784; a watcher older than that sends neither, and its stuck flag stands for stalled.
 */
export type Job = { label: string; runMs: number; kept: boolean; stuck: boolean; state?: 'running' | 'waiting' | 'stalled'; owner?: string | null }
/** A background agent listed as running whose tool calls stopped twenty minutes ago or more (#759). */
export type QuietAgent = { name: string; quietMs: number }

export type LookPart = { text: string; color?: string; bold?: boolean; dim?: boolean }

const AMBER = 'warning'
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`

/**
 * The amber needs-a-look line, most urgent first so a narrow window cuts off what can wait longest:
 * the scope modes in bold (no build or winding down, and away, can be on at once, each its own
 * bold item divided like the rest), then a failing or running PR, stuck jobs, running jobs, kept jobs, unpushed
 * commits. Empty when nothing needs a look and no mode is on, so the band does not show.
 */
// How a job's state reads (#784, Dan, 2026-10-05: "kept" and "stuck" were internal words, and
// "stuck" was wrong for a run still queued). A stalled job says who acts on it, so Dan can see it is
// not his to do: Claude for this conversation's own, the agent for an agent's.
const stateOf = (j: Job): 'running' | 'waiting' | 'stalled' => j.state ?? (j.stuck ? 'stalled' : 'running')
const STATE_WORDS = { running: 'running', waiting: 'waiting', stalled: 'not progressing' } as const
const STATE_ORDER = ['stalled', 'waiting', 'running'] as const
// One owner's jobs as phrases, the stalled first: in each state its unkept jobs counted, then its
// kept ones each by the name Claude gave it, with its run time.
const jobPhrases = (jobs: readonly Job[], actor: string): string[] => {
  const out: string[] = []
  for (const s of STATE_ORDER) {
    const who = s === 'stalled' ? `, left to ${actor}` : ''
    const n = jobs.filter(j => !j.kept && stateOf(j) === s).length
    if (n) out.push(`${plural(n, 'job', 'jobs')} ${STATE_WORDS[s]}${who}`)
    for (const j of jobs.filter(j => j.kept && stateOf(j) === s)) out.push(`${j.label} ${STATE_WORDS[s]} ${span(j.runMs)}${who}`)
  }
  return out
}

export const lookParts = (f: { modes: readonly StatusBarMode[]; pr: PrReading | null; jobs: readonly Job[]; agents?: readonly QuietAgent[]; unpushed: UnpushedReading | null; now: number }): LookPart[] => {
  const items: string[] = []
  // A reading whose refresh since failed is kept with its age, never blanked (L682).
  const age = (r: { readAt: number; isStale: boolean }) => (r.isStale ? `, as of ${span(f.now - r.readAt)} ago` : '')
  if (f.pr && (f.pr.checks === 'failing' || f.pr.checks === 'running')) items.push(`PR #${f.pr.number} checks ${f.pr.checks}${age(f.pr)}`)
  // A background agent gone quiet comes first among the work in flight: it may be hung (#759).
  for (const a of f.agents ?? []) items.push(`agent ${a.name} quiet ${span(a.quietMs)}, left to Claude`)
  // This conversation's own jobs, a stalled one ahead of those running fine (#706), then each
  // background agent's as one item under its task's name (#784).
  items.push(...jobPhrases(f.jobs.filter(j => !j.owner), 'Claude'))
  const owners = [...new Set(f.jobs.map(j => j.owner).filter((o): o is string => !!o))]
  for (const o of owners) items.push(`agent ${o}: ${jobPhrases(f.jobs.filter(j => j.owner === o), 'the agent').join(', ')}`)
  if (f.unpushed && f.unpushed.count > 0) items.push(`${plural(f.unpushed.count, 'unpushed commit', 'unpushed commits')}${age(f.unpushed)}`)
  const parts: LookPart[] = []
  for (const m of f.modes) {
    if (parts.length) parts.push({ text: ' | ', dim: true })
    parts.push({ text: m, color: AMBER, bold: true })
  }
  for (const t of items) {
    if (parts.length) parts.push({ text: ' | ', dim: true })
    parts.push({ text: t, color: AMBER })
  }
  return parts
}

/**
 * Whether the Compact row shows: context above 70%, or the cache within 5 minutes of going cold. Not
 * the cache while a main turn runs (`isWorking`): each request it makes keeps the cache warm, and
 * Dan has nothing to do about a cache Claude is about to use again (#697).
 */
export const compactDue = (f: { contextPercent: number | undefined; cacheExpiresAt: number | null; now: number; isWorking: boolean }): boolean => {
  if ((f.contextPercent ?? 0) > CONTEXT_LOOK) return true
  if (f.isWorking || f.cacheExpiresAt === null) return false
  const left = f.cacheExpiresAt - f.now
  return left > 0 && left <= CACHE_WARN_MS
}
