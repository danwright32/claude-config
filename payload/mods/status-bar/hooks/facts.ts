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
/** One background job as the job watcher (#611) reports it through $.jobs. */
export type Job = { label: string; runMs: number; kept: boolean; stuck: boolean }

export type LookPart = { text: string; color?: string; bold?: boolean; dim?: boolean }

const AMBER = 'warning'
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`

/**
 * The amber needs-a-look line, most urgent first so a narrow window cuts off what can wait longest:
 * the scope modes in bold (no build or winding down, and away, can be on at once, each its own
 * bold item divided like the rest), then a failing or running PR, running jobs, kept jobs, unpushed
 * commits. Empty when nothing needs a look and no mode is on, so the band does not show.
 */
export const lookParts = (f: { modes: readonly StatusBarMode[]; pr: PrReading | null; jobs: readonly Job[]; unpushed: number; now: number }): LookPart[] => {
  const items: string[] = []
  if (f.pr && (f.pr.checks === 'failing' || f.pr.checks === 'running')) {
    const age = f.pr.isStale ? `, as of ${span(f.now - f.pr.readAt)} ago` : ''
    items.push(`PR #${f.pr.number} checks ${f.pr.checks}${age}`)
  }
  const running = f.jobs.filter(j => !j.kept).length
  if (running) items.push(`${plural(running, 'job', 'jobs')} running`)
  for (const j of f.jobs.filter(j => j.kept)) items.push(`${j.label} kept ${span(j.runMs)}`)
  if (f.unpushed > 0) items.push(plural(f.unpushed, 'unpushed commit', 'unpushed commits'))
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

/** Whether the Compact row shows: context above 70%, or the cache within 5 minutes of going cold. */
export const compactDue = (f: { contextPercent: number | undefined; cacheExpiresAt: number | null; now: number }): boolean => {
  if ((f.contextPercent ?? 0) > CONTEXT_LOOK) return true
  if (f.cacheExpiresAt === null) return false
  const left = f.cacheExpiresAt - f.now
  return left > 0 && left <= CACHE_WARN_MS
}
