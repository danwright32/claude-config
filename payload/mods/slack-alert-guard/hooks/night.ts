import type { SlackAlertChoice } from '../types/index.d.ts'
import { APPROVE, CHANGE, SOURCE } from './rules.ts'

// Alert wording chosen in sleep mode (claude-config#2628). Dan, 2026-11-09: "Don't let alerts stop
// you in sleep mode. Just keep working and if I don't like them we'll change them tomorrow. You
// should just choose the alert in sleep mode and put it to me in the morning to see if I want
// something else." So while sleep mode is on, wording the guard holds can be chosen by the session
// that wrote it: the edit goes ahead and the choice is kept in the guard's store, apart from Dan's
// approvals, by the message as Slack would post it. A choice is never an approval:
//   1. it lets wording through only while sleep mode is on, so a day session asks him as before;
//   2. in the morning the session that chose it (once that one ended, a session working in the
//      repository it was made in or let wording through in, #2833) puts it to him in the guard's own
//      picker, and only his Approve wording there records an approval; Change wording, a dialog
//      closed by itself, or no answer leaves it unapproved and asked again; one still unapproved two
//      hours after sleep ended is put to him once by every other awake session on the Mac, whatever
//      its project, until he approves it or answers Change wording (#2993);
//   3. one unanswered for CHOICE_MS expires, said once in each session that may ask it, and stays
//      unapproved: expiry stops nothing being asked for, and never approves it.
// A choice waiting on Dan holds no merge, in any repository (#3030; Dan, 2026-11-16: "I'd actually
// prefer it didn't hold merges anywhere. It's more of a nice to have but it shouldn't hold up
// progress."). Pure; register.ts reads the store and asks.

/** The tool a session calls to choose held wording while Dan is asleep, as Claude names it. */
export const CHOOSE_TOOL = 'mcp__slack-alert-guard__choose'
export const CHOOSE_NAME = 'choose'
export const CHOOSE_DESCRIPTION =
  'Only while sleep mode is on: choose the wording of a Slack alert the Slack alert guard held, so the edit can go ahead overnight. Give the held call id and the whole message as Slack will post it, every variable filled in from a realistic example. It is recorded as a choice, never as approved: Dan is asked in the morning whether to keep it.'
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
  `${blocked}. Dan is asleep (sleep mode), so choose the wording yourself rather than stopping: call ${CHOOSE_TOOL} with {"call": "${id}", "rendered": "<the whole message as Slack will post it, every variable filled in from a realistic example>"}, then send this call again, unchanged. Your choice is recorded, not approved: Dan is asked in the morning whether to keep it.`

/**
 * The morning question: the message chosen overnight, put to Dan to keep or change. Approving sends
 * nothing. The file named is the one that posts it, the only kind the guard holds (#2837).
 */
export const morningQuestion = (c: Pick<SlackAlertChoice, 'file' | 'rendered'>, repo: string | null = null): string =>
  `Overnight, while you were asleep, Claude chose this wording for an automated Slack alert defined in ${c.file}${repo ? ` in ${repo}` : ''}. Approve it? Approving sends nothing: it only records the wording as yours.\n\n${c.rendered}`

export const MORNING_OPTIONS = [
  { label: APPROVE, description: 'Keep the wording chosen overnight. This sends nothing.' },
  { label: CHANGE, description: 'Say what it should say instead.' },
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
 * put to him now; each expired one, once per session, named as expired and unapproved. Given only the
 * choices this session may ask (register.ts askedHere, #2833): its own, or ones made in its repository.
 */
export const morningLines = (choices: readonly SlackAlertChoice[], session: string, told: readonly string[]): string[] => {
  const lines: string[] = []
  for (const c of choices) {
    if (c.expired !== undefined) {
      if (told.includes(c.id)) continue
      lines.push(
        `Slack alert wording chosen overnight for ${c.file} expired unanswered: it was never approved. Tell Dan in one line, and if he wants to settle it, ${asking(c)}.`,
      )
      continue
    }
    if (!morningReaches(c, session)) continue
    lines.push(`Slack alert wording was chosen overnight for ${c.file} and waits on Dan: before anything else, put it to him: ${asking(c)}.`)
  }
  return lines
}

/**
 * Whether the morning lines reach a choice in this session, given it is one the session may ask
 * (askedHere): its own or an ended session's at every message, and an expired one once.
 */
export const morningReaches = (c: SlackAlertChoice, session: string): boolean => c.expired !== undefined || c.session === null || c.session === session

/**
 * How long a choice may wait unapproved after the sleep it was chosen in ended before any awake
 * session on the Mac puts it to Dan (#2993): the morning question reaches him only from the session
 * that made it, or one in its repository once that ended, so an open session he is not writing in,
 * or work in another project, left it unasked for hours.
 */
export const REASK_MS = 2 * 60 * 60_000

/**
 * When the sleep a choice was made in ended: the first end at or after the choice, or null where no
 * end can be read or none came after it.
 */
export const sleepEndOf = (c: Pick<SlackAlertChoice, 'at'>, ends: readonly number[] | null): number | null =>
  (ends ?? []).filter(t => t >= c.at).sort((a, b) => a - b)[0] ?? null

/**
 * The choices to put to Dan again in this session (#2993): still unapproved more than REASK_MS after
 * the sleep they were chosen in ended, never one he answered Change wording to, one already put to
 * him again in this session (`done`), or one this session's morning lines reach (`morning`). With no
 * sleep end read, the wait counts from the choice itself (L648): Dan is awake whenever this is read,
 * so asking early costs one question, while waiting on an end nobody can read leaves it unasked.
 */
export const reaskDue = (all: readonly SlackAlertChoice[], now: number, ends: readonly number[] | null, done: readonly string[], morning: ReadonlySet<string>): SlackAlertChoice[] =>
  all.filter(c => c.rejected === undefined && !done.includes(c.id) && !morning.has(c.id) && now - (sleepEndOf(c, ends) ?? c.at) > REASK_MS)

/**
 * What a session is told for each choice it puts to Dan again (#2993), naming its project when known,
 * its file and its wording. `ended`: whether the sleep end was read, so the line claims only what was (L11).
 */
export const reaskLine = (c: SlackAlertChoice, repo: string | null, ended: boolean): string =>
  `Slack alert wording chosen overnight${repo ? ` in ${repo}` : ''} for ${c.file} is still not approved, more than two hours after ${ended ? 'sleep mode ended' : 'it was chosen'}: "${c.rendered}". Put it to Dan now, once in this session: ${asking(c)}.`
