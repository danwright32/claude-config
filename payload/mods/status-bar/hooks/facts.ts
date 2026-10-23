import type { StatusBarMode } from '../types/index.d.ts'

// The status bar's judgments, pure so each is tested on its own (#610, docs/mods-design.md
// "Status bar (#610)"). The wording follows the design rounds' renderings, the jobs' as #784
// reworded them: "PR #636 checks failing", "1 job running", "dev server running 2h 14m",
// "2 unpushed commits", "context 74%".

const MIN = 60_000
const HOUR = 60 * MIN
const DAY = 24 * HOUR

/** Context above this share of the window shows the Compact row (the spec's "about 70%"). */
export const CONTEXT_LOOK = 70
/** The Compact row's cache line shows this close to the prompt cache going cold, and the toast fires. */
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
export type Job = { label: string; runMs: number; kept: boolean; stuck: boolean; state?: 'running' | 'waiting' | 'stalled'; owner?: string | null; ownerId?: string | null }
/** A background agent listed as running whose tool calls stopped twenty minutes ago or more (#759). */
export type QuietAgent = { name: string; quietMs: number }

export type LookPart = { text: string; color?: string; bold?: boolean; dim?: boolean }

const AMBER = 'warning'
// Work only going along (a job running or waiting, PR checks running) is lavender, so amber is left
// meaning something needs a look (Dan, 2026-10-14: "I don't like that the waiting indicator is yellow").
export const LAVENDER = '#C8A0F0'
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`

// How a job's state reads (#784, Dan, 2026-10-05: "kept" and "stuck" were internal words, and
// "stuck" was wrong for a run still queued). A stalled job says who acts on it, so Dan can see it is
// not his to do: Claude for this conversation's own, the agent for an agent's.
const stateOf = (j: Job): 'running' | 'waiting' | 'stalled' => j.state ?? (j.stuck ? 'stalled' : 'running')
const STATE_WORDS = { running: 'running', waiting: 'waiting', stalled: 'not progressing' } as const
const STATE_ORDER = ['stalled', 'waiting', 'running'] as const
// One owner's jobs as phrases, the stalled first: in each state its unkept jobs counted, then its
// kept ones each by the name Claude gave it, with its run time. A stalled phrase needs a look and is
// amber; a running or waiting one is lavender.
type Item = { text: string; color: string }
const jobPhrases = (jobs: readonly Job[], actor: string): Item[] => {
  const out: Item[] = []
  for (const s of STATE_ORDER) {
    const who = s === 'stalled' ? `, left to ${actor}` : ''
    const color = s === 'stalled' ? AMBER : LAVENDER
    const n = jobs.filter(j => !j.kept && stateOf(j) === s).length
    if (n) out.push({ text: `${plural(n, 'job', 'jobs')} ${STATE_WORDS[s]}${who}`, color })
    for (const j of jobs.filter(j => j.kept && stateOf(j) === s)) out.push({ text: `${j.label} ${STATE_WORDS[s]} ${span(j.runMs)}${who}`, color })
  }
  return out
}

/**
 * The needs-a-look line, amber where something needs a look and lavender for work only going
 * along, most urgent first so a narrow window cuts off what can wait longest: the scope modes in bold (no build or winding down, and away, can be on at once, each its own
 * bold item divided like the rest), then a failing or running PR, background agents gone quiet,
 * this conversation's jobs (not progressing, then waiting, then running), each background agent's
 * jobs under its task's name, and unpushed commits. Empty when nothing needs a look and no mode is
 * on, so the band does not show.
 */
export const lookParts = (f: { modes: readonly StatusBarMode[]; pr: PrReading | null; jobs: readonly Job[]; agents?: readonly QuietAgent[]; unpushed: UnpushedReading | null; now: number }): LookPart[] => {
  const items: Item[] = []
  // A reading whose refresh since failed is kept with its age, never blanked (L682).
  const age = (r: { readAt: number; isStale: boolean }) => (r.isStale ? `, as of ${span(f.now - r.readAt)} ago` : '')
  if (f.pr && (f.pr.checks === 'failing' || f.pr.checks === 'running')) items.push({ text: `PR #${f.pr.number} checks ${f.pr.checks}${age(f.pr)}`, color: f.pr.checks === 'running' ? LAVENDER : AMBER })
  // A background agent gone quiet comes first among the work in flight: it may be hung (#759).
  for (const a of f.agents ?? []) items.push({ text: `agent ${a.name} quiet ${span(a.quietMs)}, left to Claude`, color: AMBER })
  // This conversation's own jobs, a stalled one ahead of those running fine (#706), then each
  // background agent's as one item under its task's name (#784).
  items.push(...jobPhrases(f.jobs.filter(j => !j.owner), 'Claude'))
  // Grouped by the agent's id, never its description: two agents given the same task stay apart,
  // each then named with the start of its id (lessons review of PR 794).
  const keyOf = (j: Job) => j.ownerId ?? j.owner ?? ''
  const agentJobs = f.jobs.filter(j => !!j.owner)
  const keys = [...new Set(agentJobs.map(keyOf))]
  const nameOf = (k: string) => agentJobs.find(j => keyOf(j) === k)?.owner ?? ''
  for (const k of keys) {
    const name = nameOf(k)
    const shared = keys.filter(o => nameOf(o) === name).length > 1
    // One item for all of an agent's jobs, so it is amber when any of them is stalled.
    const phrases = jobPhrases(agentJobs.filter(j => keyOf(j) === k), 'the agent')
    const color = phrases.some(p => p.color === AMBER) ? AMBER : LAVENDER
    items.push({ text: `agent ${name}${shared ? ` (${k.slice(0, 6)})` : ''}: ${phrases.map(p => p.text).join(', ')}`, color })
  }
  if (f.unpushed && f.unpushed.count > 0) items.push({ text: `${plural(f.unpushed.count, 'unpushed commit', 'unpushed commits')}${age(f.unpushed)}`, color: AMBER })
  const parts: LookPart[] = []
  for (const m of f.modes) {
    if (parts.length) parts.push({ text: ' | ', dim: true })
    parts.push({ text: m, color: AMBER, bold: true })
  }
  for (const { text, color } of items) {
    if (parts.length) parts.push({ text: ' | ', dim: true })
    parts.push({ text, color })
  }
  return parts
}

/**
 * The context size, in tokens, from which compacting costs less than letting the cache go cold, so
 * the cache row offers Compact beside "send any message" (#1596). Below it the row offers only the
 * message: compacting a small conversation costs more than the cold re-read it avoids.
 *
 * The arithmetic, in units of the base input price, at Anthropic's LIST prices (Opus 4.5: input $5,
 * output $25, one hour cache write $10, cache read $0.50 per million tokens; Sonnet 4.5 the same
 * multiples at $3, $15, $6, $0.30), so it holds for any model priced at those multiples: output 5x,
 * a one hour cache write 2x, a cache read 0.1x. With T the context now, S the summary a compaction
 * writes and T2 the context the first request after it carries (system prompt and tools included,
 * which no compaction removes):
 *
 *   left to go cold, the next request writes T again:          2 T
 *   compacted, the call reads T warm and writes S, and the
 *   next request writes T2:                                    0.1 T + 5 S + 2 T2
 *
 * so compacting saves once 1.9 T > 5 S + 2 T2, that is T > (5 S + 2 T2) / 1.9.
 *
 * Measured on 2026-10-23 over the 31 compactions in this Mac's transcripts that could be paired
 * with their summary and the request after (S estimated as the summary's characters / 4): S median
 * 3,207 and p90 4,454; T2 median 110,061 and p90 127,565; the break even per compaction median
 * 126,838, p90 142,718, max 182,651 (23 of the 31 were main sessions, p90 142,718). 150,000 is past
 * the break even of 21 of those 23. It leans high on purpose (L648): an offer that saves nothing
 * costs a summary call and the detail compacting drops, while one left out costs only the
 * difference, and /compact and the context row above 70% are still there.
 */
export const COMPACT_SAVES_TOKENS = 150_000

/** A part of the Compact row: text, or the Compact button with what to type where a click cannot land. */
export type CompactPart = LookPart | { button: 'compact'; label: 'Compact'; instead: LookPart[] }
const COMPACT_BUTTON: CompactPart = { button: 'compact', label: 'Compact', instead: [{ text: 'type: ', dim: true }, { text: '/compact' }] }

/**
 * The Compact row's lines, each saying why it shows (#1596, Dan 2026-10-23: "ctx 18% [ Compact ]"
 * read as the context being full). Empty when it does not show.
 * - Context above 70%: "context 82%" and Compact.
 * - The cache within 5 minutes of going cold: "cache goes cold in 4m: send any message to keep it
 *   warm", since any message reads the cache and starts its hour again; ", or [ Compact ]" only from
 *   COMPACT_SAVES_TOKENS. Not while a main turn runs (`isWorking`): each request it makes keeps the
 *   cache warm, and Dan has nothing to do about a cache Claude is about to use again (#697).
 * - Both: the context line with Compact, then the cache line, so each reason is said once and each
 *   line fits an 80 column band.
 */
export const compactLines = (f: {
  contextPercent: number | undefined
  contextTokens: number | undefined
  cacheExpiresAt: number | null
  now: number
  isWorking: boolean
}): CompactPart[][] => {
  const percent = f.contextPercent
  const byContext = percent !== undefined && percent > CONTEXT_LOOK
  const left = f.cacheExpiresAt === null ? 0 : f.cacheExpiresAt - f.now
  const byCache = !f.isWorking && left > 0 && left <= CACHE_WARN_MS
  const lines: CompactPart[][] = []
  if (byContext) lines.push([{ text: `context ${Math.round(percent)}% `, color: AMBER }, COMPACT_BUTTON])
  if (byCache) {
    const cold = `cache goes cold in ${span(left)}: send any message to keep it warm`
    const saves = !byContext && (f.contextTokens ?? 0) >= COMPACT_SAVES_TOKENS
    lines.push(saves ? [{ text: `${cold}, or `, color: AMBER }, COMPACT_BUTTON] : [{ text: cold, color: AMBER }])
  }
  return lines
}
