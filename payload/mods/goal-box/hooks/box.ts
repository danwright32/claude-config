import type { ModKitCard, ModKitGoal, ModKitRun } from '../.claude-plugin/types/mod-kit/index.d.ts'
import type { GoalBoxShown } from '../types/index.d.ts'
import type { PrAnswer } from './mod-kit/prmerged.ts'

// The Goal accomplished box (claude-config#1563), apart from the session: what the tool takes, what
// the box says, and whether it may be shown now. Pure, so every rule is tested without a session.
//
// Dan, 2026-10-23: "show me a green (if possible) box that says the goal has been accomplished when
// you either literally accomplish a goal or just complete what I originally asked you to do." And,
// the same day, on the issue: the box lists the goal plus a short list of what shipped (issues
// closed, PRs merged and live). Once per accomplishment, never while part of the request is still
// open, a merge is unconfirmed or a deploy is not yet live.

export const MOD = 'goal-box'
export const NAME = 'goal_accomplished'
export const TOOL = `mcp__${MOD}__${NAME}`

/** How long the goal line and each shipped line may be, and how many shipped lines a box holds. */
export const GOAL_MAX = 300
export const LINE_MAX = 200
export const SHIPPED_MAX = 12

export const DESCRIPTION = [
  "Shows Dan the green Goal accomplished box: the goal, then what shipped. Call it once, in the turn where the work Dan asked for in this session is finished: every part of his request done, every pull request merged with the merge confirmed, every deploy confirmed live.",
  'With a /goal set, do not call it yourself: when the goal\'s own check finds it met, you are told to call it.',
  'goal: what Dan asked for, in a few words of his own terms. shipped: one short line per thing that shipped, issues closed and pull requests merged and live, each naming its number (for example "#1563 closed: Goal accomplished box", "PR #1700 merged and live").',
  'It refuses while anything is still in flight (an agent still running, a merge or deploy not confirmed, a pull request this session touched still open), naming what; settle that and call it again. It shows at most once per request.',
].join(' ')

export const SCHEMA = {
  type: 'object',
  properties: {
    goal: { type: 'string', description: "What Dan asked for, in a few words; with a /goal, its condition is shown instead." },
    shipped: { type: 'array', items: { type: 'string' }, description: 'One short line per thing that shipped.' },
  },
  required: ['goal', 'shipped'],
}

export type BoxInput = { goal: string; shipped: string[] }

/** The input as the box will show it, or why it cannot be shown. */
export const readInput = (raw: Record<string, unknown>): BoxInput | { refusal: string } => {
  const goal = typeof raw.goal === 'string' ? raw.goal.replace(/\s+/g, ' ').trim() : ''
  if (!goal) return { refusal: 'goal must be what Dan asked for, in a few words' }
  if (goal.length > GOAL_MAX) return { refusal: `goal is ${goal.length} characters; say it in at most ${GOAL_MAX}` }
  if (!Array.isArray(raw.shipped)) return { refusal: 'shipped must be a list of short lines, one per thing that shipped' }
  const shipped: string[] = []
  for (const [i, l] of raw.shipped.entries()) {
    const line = typeof l === 'string' ? l.replace(/\s+/g, ' ').trim() : ''
    if (!line) return { refusal: `shipped line ${i + 1} is empty or not text` }
    if (line.length > LINE_MAX) return { refusal: `shipped line ${i + 1} is ${line.length} characters; keep each to ${LINE_MAX}` }
    shipped.push(line)
  }
  if (!shipped.length) return { refusal: 'shipped is empty; name what shipped, one short line each' }
  if (shipped.length > SHIPPED_MAX) return { refusal: `shipped has ${shipped.length} lines; keep the box to ${SHIPPED_MAX}, the most important first` }
  return { goal, shipped }
}

const HEADING = 'GOAL ACCOMPLISHED'

/**
 * The box as text: a three line double box labelled GOAL ACCOMPLISHED, the shape of the SESSION
 * REFLECTION box, then the goal and what shipped. It is the tool's result, so it is what the model
 * reads and what a surface that cannot draw the card shows.
 */
export const boxText = (goal: string, shipped: string[]): string =>
  [`╔${'═'.repeat(HEADING.length + 2)}╗`, `║ ${HEADING} ║`, `╚${'═'.repeat(HEADING.length + 2)}╝`, `Goal: ${goal}`, 'Shipped:', ...shipped.map(s => `• ${s}`)].join('\n')

/**
 * The same box as mod-kit's card, as Dan settled it in the #1563 design round (2026-10-24, "Green
 * border and heading", docs/design/1563-goal-box.html): the border, the heading (bold) and the bullets
 * in the success colour, the goal and each shipped line plain.
 */
export const cardOf = (toolUseId: string, goal: string, shipped: string[]): ModKitCard => {
  const run = (text: string, more: Partial<ModKitRun> = {}): ModKitRun => ({ text, ...more })
  return {
    toolUseId,
    border: 'success',
    title: [run(HEADING, { color: 'success', bold: true })],
    lines: [[run(goal)], ...shipped.map(s => [run('• ', { color: 'success' }), run(s)])],
  }
}

/** A pull request this session touched, as Claude Code's own pr-link record names it. */
export type Linked = { repo: string; pr: number }

/**
 * Every pull request this session touched, from the pr-link records Claude Code writes into its
 * transcript, one per pull request, repositories in lower case (GitHub's names are one name in any
 * case). Measured on this Mac on 2026-10-24: 888 pull requests across 54 transcripts, written when
 * the session or its agents created one (93 first seen at a gh pr create), merged one (144), viewed
 * one (13), or as an agent worked (638 more, at a call of the main loop's own that had nothing to
 * do with it). A line that is not such a record is skipped.
 */
export const linkedIn = (lines: string): Linked[] => {
  const seen = new Map<string, Linked>()
  for (const raw of lines.split('\n')) {
    if (!raw.trim()) continue
    let o: unknown
    try {
      o = JSON.parse(raw)
    } catch {
      continue
    }
    const r = o as { type?: unknown; prNumber?: unknown; prRepository?: unknown } | null
    if (!r || typeof r !== 'object' || r.type !== 'pr-link') continue
    if (typeof r.prRepository !== 'string' || !/^[\w.-]+\/[\w.-]+$/.test(r.prRepository)) continue
    if (typeof r.prNumber !== 'number' || !Number.isInteger(r.prNumber) || r.prNumber <= 0) continue
    const repo = r.prRepository.toLowerCase()
    seen.set(`${repo}#${r.prNumber}`, { repo, pr: r.prNumber })
  }
  return [...seen.values()]
}

/** What is still in flight, one sentence each; empty when nothing holds the box. */
export type Holds = string[]

/** is it live's record of this session's merges, as its state holds it (it may not be loaded). */
export type MergeFacts = {
  owed: { pr: number; repo?: string; how: string; at: number; cwd?: string }[]
  verdicts: Record<string, { state: string; at: number }>
}

/**
 * is it live's state as read, held to the shape its contract gives (L50: a value read from another
 * mod's state never feeds a comparison unchecked), or why it is not in that shape. Absent is none.
 */
export const mergeFactsOf = (owed: unknown, verdicts: unknown): MergeFacts | { why: string } => {
  const o = owed ?? []
  const v = verdicts ?? {}
  if (!Array.isArray(o)) return { why: 'its owed merges are not a list' }
  for (const x of o) {
    const e = x as { pr?: unknown; repo?: unknown; how?: unknown; at?: unknown; cwd?: unknown } | null
    if (!e || typeof e !== 'object' || typeof e.pr !== 'number' || typeof e.how !== 'string' || typeof e.at !== 'number' || (e.repo !== undefined && typeof e.repo !== 'string') || (e.cwd !== undefined && typeof e.cwd !== 'string')) return { why: `an owed merge is not a pull request it can name (${JSON.stringify(x)})` }
  }
  if (typeof v !== 'object' || Array.isArray(v)) return { why: 'its verdicts are not a record' }
  for (const [k, x] of Object.entries(v as Record<string, unknown>)) {
    if (!x || typeof x !== 'object' || typeof (x as { state?: unknown }).state !== 'string') return { why: `the verdict for ${k} has no state` }
    if (typeof (x as { at?: unknown }).at !== 'number') return { why: `the verdict for ${k} has no time` }
  }
  return { owed: o as MergeFacts['owed'], verdicts: v as MergeFacts['verdicts'] }
}

const prName = (repo: string | undefined, pr: number) => (repo ? `${repo}#${pr}` : `#${pr}`)
const fold = (repo: string) => repo.toLowerCase()

/**
 * Which pull request a background merge GitHub is asked about is: its repository where is it live
 * read one from the command, else the folder the helper ran in (where gh resolves the same one). Two
 * runs of the helper for one pull request are one question and one hold.
 */
export const waitKey = (o: { pr: number; repo?: string; cwd?: string }) => `${o.repo ? fold(o.repo) : `folder:${o.cwd ?? ''}`}#${o.pr}`

/**
 * What GitHub said of each background merge, by waitKey, as mod-kit's one check of whether a pull
 * request merged answers it (hooks/mod-kit/prmerged.ts, #1991), the check is it live's turn end makes
 * too: merged in that repository at that time, open, closed, no pull request, or why not proven.
 */
export type Confirmed = Record<string, PrAnswer>

/**
 * Whether a card made since `since` is kept for the pull request this session: under its repository,
 * or for a merge whose repository was never read, under any repository with that number (as is it
 * live's own turn end settles it). is it live crosses a carded merge off only at a turn end, so a
 * card made since then is read here rather than its record.
 */
const carded = (verdicts: MergeFacts['verdicts'], repo: string | undefined, pr: number, since: number) =>
  Object.entries(verdicts).some(([k, v]) => (repo ? fold(k) === `${fold(repo)}#${pr}` : k.endsWith(`#${pr}`)) && v.at >= since)

/**
 * The merges is it live says are not settled: a merge still owed its card, a background merge GitHub
 * has not confirmed (`confirmed`, asked by the box itself, #1818), a deploy not confirmed live. Each
 * said once. A background merge GitHub says was closed, or whose number is no pull request there,
 * merged nothing and is let go at is it live's own turn end, so it holds nothing here either (#1991).
 */
export const mergeHolds = (f: MergeFacts, confirmed: Confirmed = {}): Holds => {
  const out: Holds = []
  const owedCard = (name: string) => `${name} was merged and has no is it live card yet: check its deploy and call the card tool`
  for (const o of f.owed) {
    if (o.how === 'waiting') {
      const c = confirmed[waitKey(o)]
      if (c?.kind === 'closed' || c?.kind === 'not a pr') continue
      if (c?.kind === 'merged') {
        if (!carded(f.verdicts, c.repo, o.pr, Math.min(o.at, c.at))) out.push(owedCard(`${c.repo}#${o.pr}`))
        continue
      }
      const why = c?.kind === 'open' ? 'GitHub says it is still open' : c?.kind === 'unproven' ? c.why : undefined
      out.push(`the merge of ${prName(o.repo, o.pr)} has not been confirmed yet${why ? ` (${why})` : ''}`)
    } else if (!carded(f.verdicts, o.repo, o.pr, o.at)) out.push(owedCard(prName(o.repo, o.pr)))
  }
  for (const [key, v] of Object.entries(f.verdicts)) {
    if (v.state === 'deploying') out.push(`${key} is still deploying: check it is live and call the is it live card tool again`)
    else if (v.state === 'unconfirmed') out.push(`${key}'s deploy was not confirmed live`)
  }
  return [...new Set(out)]
}

/** The box this call would show, or every reason it may not be shown now. */
export type Decision = { show: { kind: GoalBoxShown['kind']; key: string; goal: string } } | { refuse: string[] }

/**
 * Whether the box may be shown now, as far as the goal and what is in flight say. `goal` is mod-kit's
 * reading of the session's /goal; `shown` the boxes already shown this session; `holds` what is
 * still in flight. A /goal still set is never shown over (its own check decides); a goal met and not
 * yet shown is shown under its condition; otherwise the box is for the request Dan made, which the
 * claim on the session's record allows once per message of his (register.ts, the one place that
 * rule is kept, since it must be judged and written in one step).
 */
export const decide = (q: { goal: ModKitGoal; input: BoxInput; shown: GoalBoxShown[]; prompts: number; holds: Holds }): Decision => {
  const { goal, input, shown, prompts, holds } = q
  if (goal.state === 'unreadable') return { refuse: [`this session's /goal could not be read (${goal.why}), so whether one is still open is not known`] }
  if (goal.state === 'set') return { refuse: [`the /goal "${goal.condition}" is still set and its own check has not found it met; the box comes when it does`] }
  if (holds.length) return { refuse: holds }
  const met = goal.met && !shown.some(s => s.key === `goal:${goal.met?.id}`) ? goal.met : undefined
  return met ? { show: { kind: 'goal', key: `goal:${met.id}`, goal: met.condition } } : { show: { kind: 'request', key: `request:${prompts}`, goal: input.goal } }
}

/** What the session is told when its /goal's check finds it met: call the tool now. */
export const askText = (condition: string): string =>
  `GOAL ACCOMPLISHED. The /goal "${condition}" was judged met. Show Dan the Goal accomplished box now: call ${TOOL} with goal set to the goal and shipped listing what shipped, one short line each (issues closed, pull requests merged and live). If it refuses, settle what it names, then call it again.`
