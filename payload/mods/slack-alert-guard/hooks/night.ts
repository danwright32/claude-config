import type { SlackAlertChoice } from '../types/index.d.ts'
import { APPROVE, CHANGE, SOURCE, UNWIRED, fixedParts } from './rules.ts'

// Alert wording chosen in sleep mode (claude-config#2628). Dan, 2026-11-09: "Don't let alerts stop
// you in sleep mode. Just keep working and if I don't like them we'll change them tomorrow. You
// should just choose the alert in sleep mode and put it to me in the morning to see if I want
// something else." So while sleep mode is on, wording the guard holds can be chosen by the session
// that wrote it: the edit goes ahead and the choice is kept in the guard's store, apart from Dan's
// approvals, by the message as Slack would post it. A choice is never an approval:
//   1. no pull request carrying chosen wording may merge until Dan approves it, so nothing posts it;
//   2. it lets wording through only while sleep mode is on, so a day session asks him as before;
//   3. in the morning the session that chose it puts it to him in the guard's own picker, and only
//      his Approve wording there records an approval; Change wording, a dialog closed by itself, or
//      no answer leaves it held and asked again;
//   4. one unanswered for CHOICE_MS expires, said once in every session, and stays held: expiry
//      stops nothing being asked for, it never lets anything merge.
// Pure; register.ts reads the store, runs gh, and asks.

/** The tool a session calls to choose held wording while Dan is asleep, as Claude names it. */
export const CHOOSE_TOOL = 'mcp__slack-alert-guard__choose'
export const CHOOSE_NAME = 'choose'
export const CHOOSE_DESCRIPTION =
  'Only while sleep mode is on: choose the wording of a Slack alert the Slack alert guard held, so the edit can go ahead overnight. Give the held call id and the whole message as Slack will post it, every variable filled in from a realistic example. It is recorded as a choice, never as approved: Dan is asked in the morning, and nothing carrying it can merge until he approves it.'
export const CHOOSE_SCHEMA = {
  type: 'object',
  properties: {
    call: { type: 'string', description: 'The held call id the refusal names.' },
    rendered: { type: 'string', description: 'The whole message exactly as Slack will post it, every variable filled in from a realistic example.' },
  },
  required: ['call', 'rendered'],
}

/** Where a choice is kept: by the store key Dan's approval would be kept under, so the two never share a key. */
export const CHOSEN_PREFIX = 'chosen:'
export const chosenKey = (key: string): string => `${CHOSEN_PREFIX}${key}`
/** The morning question's `metadata.source`: the guard's own, then `chosen:<the chosen call's id>`. */
export const morningSource = (id: string): string => `${SOURCE}:${CHOSEN_PREFIX}${id}`

/** How long a choice waits on Dan before it expires: the night it was made, and two days after. */
export const CHOICE_MS = 3 * 24 * 60 * 60_000

/** The refusal while Dan is asleep: choose the wording, then send the call again. */
export const asleepRefusal = (blocked: string, id: string): string =>
  `${blocked}. Dan is asleep (sleep mode), so choose the wording yourself rather than stopping: call ${CHOOSE_TOOL} with {"call": "${id}", "rendered": "<the whole message as Slack will post it, every variable filled in from a realistic example>"}, then send this call again, unchanged. Your choice is recorded, not approved: Dan is asked in the morning whether to keep it, and no pull request carrying it can merge until he approves it.`

/**
 * The morning question: the message chosen overnight, put to Dan to keep or change. Approving sends
 * nothing. A module of message copy no file uses yet (#2720) is named as one, as the day question does.
 */
export const morningQuestion = (c: Pick<SlackAlertChoice, 'file' | 'from' | 'rendered' | 'unwired'>): string =>
  `Overnight, while you were asleep, Claude chose this wording for an automated Slack alert defined in ${c.from ?? c.file}${!c.from && c.unwired ? `, ${UNWIRED}` : ''}. Approve it? Approving sends nothing: it only lets a pull request carrying it merge.\n\n${c.rendered}`

export const MORNING_OPTIONS = [
  { label: APPROVE, description: 'Keep the wording chosen overnight. Only the pull request carrying it may merge.' },
  { label: CHANGE, description: 'Keep it held, and say what it should say instead.' },
]

/** One choice per chosen call, from the store's chosen records (one per key, each carrying its call's id). */
export const choicesOf = (records: readonly SlackAlertChoice[]): SlackAlertChoice[] => {
  const byId = new Map<string, SlackAlertChoice>()
  for (const r of records) if (!byId.has(r.id)) byId.set(r.id, r)
  return [...byId.values()].sort((a, b) => a.at - b.at)
}

/** Whether a choice has waited past its time without an answer. */
export const isOverdue = (c: SlackAlertChoice, now: number): boolean => c.expired === undefined && now - c.at >= CHOICE_MS

const asking = (c: SlackAlertChoice) =>
  `call AskUserQuestion with one question and metadata {"source": "${morningSource(c.id)}"} and no answers filled in; the guard words the question with the message chosen in it`

/**
 * What a session is told at Dan's message while he is awake (never while asleep, when no question
 * reaches him): each choice still waiting that this session made, or that a session since ended made,
 * put to him now; each expired one, once per session, named as expired and still held.
 */
export const morningLines = (choices: readonly SlackAlertChoice[], session: string, told: readonly string[]): string[] => {
  const lines: string[] = []
  for (const c of choices) {
    if (c.expired !== undefined) {
      if (told.includes(c.id)) continue
      lines.push(
        `Slack alert wording chosen overnight for ${c.file} expired unanswered: it was never approved, so it is still held and no pull request carrying it can merge. Tell Dan in one line, and if he wants to settle it, ${asking(c)}.`,
      )
      continue
    }
    if (c.session !== null && c.session !== session) continue
    lines.push(`Slack alert wording was chosen overnight for ${c.file} and waits on Dan: before anything else, put it to him: ${asking(c)}. Until he approves it, no pull request carrying it can merge.`)
  }
  return lines
}

/** The pull request a gh command merges, as `gh pr diff` takes it, or why it cannot be read. */
export type MergeOf = { selector: string[]; repo: string | null | undefined } | { unreadable: true } | undefined
type GhRead = { sub: string; act: string; positionals: string[]; named?: string | null; unreadable: boolean; api?: { method: string; endpoint: string | undefined; repo?: string | null; query?: string | null } }
// The REST merge endpoint, written bare or as a whole address, a query after it or not.
const API_MERGE = /^(?:https?:\/\/[^/]+(?:\/api\/v3)?)?\/?repos\/[^/]+\/[^/]+\/pulls\/(\d+)\/merge\/?(?:[?#].*)?$/
const GRAPHQL = /^(?:https?:\/\/[^/]+(?:\/api)?)?\/?graphql\/?(?:[?#].*)?$/
export const mergeOf = (g: GhRead | undefined): MergeOf => {
  if (!g) return undefined
  if (g.sub === 'api' && g.api) {
    const { endpoint, method } = g.api
    // A GraphQL call merges when its document asks to, or when no document can be read.
    if (endpoint !== undefined && GRAPHQL.test(endpoint)) return g.api.query === null || /\bmergePullRequest\b/.test(g.api.query ?? '') ? { unreadable: true } : undefined
    const m = endpoint === undefined ? null : API_MERGE.exec(endpoint)
    if (!m) return endpoint === undefined && method !== 'GET' ? { unreadable: true } : undefined
    // A GET there only asks whether the pull request is merged.
    if (method === 'GET') return undefined
    return g.api.repo ? { selector: [m[1] as string], repo: g.api.repo } : { unreadable: true }
  }
  if (g.sub !== 'pr' || g.act !== 'merge') return undefined
  if (g.unreadable || g.named === null) return { unreadable: true }
  return { selector: g.positionals.slice(0, 1), repo: g.named }
}

/**
 * The chosen texts a pull request's diff adds, read toward holding (L648): a text is carried when
 * every fixed part with letters in it (the words between its filled in values, each line apart)
 * stands in some line the diff adds, so a text filled in or split across lines differently still
 * holds the merge, while one reworded since (a fixed part gone) lets it through.
 */
export const carried = (diff: string, choices: readonly SlackAlertChoice[]): SlackAlertChoice[] => {
  const added = diff
    .split('\n')
    .filter(l => l.startsWith('+') && !l.startsWith('+++'))
    .map(l => l.slice(1))
  const parts = (s: string) =>
    fixedParts(s)
      .flatMap(p => p.split('\n'))
      .map(p => p.trim())
      .filter(p => /[A-Za-z]{2,}/.test(p))
  // A chosen removal (one adding nothing, as the guard keys it) is carried by the lines the diff
  // takes away; a reword is judged by the wording it adds alone.
  const gone = diff
    .split('\n')
    .filter(l => l.startsWith('-') && !l.startsWith('---'))
    .map(l => l.slice(1))
  const holds = (lines: string[]) => (s: string) => {
    const ps = parts(s)
    return ps.length > 0 && ps.every(p => lines.some(l => l.includes(p)))
  }
  return choices.filter(c => (c.added.length ? c.added.some(holds(added)) : c.removed.some(holds(gone))))
}

/** The refusal of a merge carrying chosen wording. */
export const mergeRefusal = (held: readonly SlackAlertChoice[]): string =>
  `Blocked: this pull request carries Slack alert wording chosen overnight that Dan has not approved (${held.map(c => `${c.file}: "${c.rendered}"`).join('; ')}). Nothing carrying it may merge until he approves it. ${held.map(c => `Put it to him: call AskUserQuestion with one question and metadata {"source": "${morningSource(c.id)}"}`).join('; ')}; while he is asleep, leave the pull request open for the morning.`
