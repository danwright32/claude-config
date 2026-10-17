// Sleep mode's morning reminder (#1107). Dan, 2026-10-12 and 13: "Can you make it so when I enter
// sleep mode, the manual steps panel pops up with a step to rescue the night's findings?" and,
// choosing the morning reminder reading: "Basically I want a way to remember in the morning to review
// the issues." So /sleep pins one step on the manual steps card, and it comes off only once the
// morning review has happened: the wake pickers answered, or a night with nothing proposed, said so.
// Never by time, and never by a wake that offered him nothing to answer (a phone wake whose pickers
// he never saw).
//
// #1283 reverses that. Dan, 2026-10-17: "manual step only comes up on the chat that I entered sleep
// mode in. It should be on every session and it should be completed automatically when I exit sleep
// mode", and "sleep mode ending shouhld be the review of the night automatically". Ending sleep, by
// any route, is the review: every session then puts its own questions and approvals to him as
// pickers (#1285). So the step says waking is the whole of it, is pinned in every live session while
// asleep, and comes off everywhere once the night has ended, never gated on pickers answered.
//
// The step sits in every session's card, so whether the night has ended is kept on disk beside the
// sleep record (`morning-review.json`), and every session takes the step off its own card once it
// reads that it has. Only the decisions live here; register.ts carries them out.

/** The heading of a card made for the step alone, when no card is pinned at bedtime. */
export const MORNING_HEADING = 'The morning after sleep mode'

/** The step, by its night (the ET date sleep began on), so each night's step is told apart by its title. */
export const morningStep = (night: string) => ({
  title: `When you are up, end sleep mode (${night})`,
  location: 'Any Claude Code session on this Mac',
  clicks: ["Say I'm up, or type /wake, in any session"],
})

/** What is said once the step comes off at the end of a night (#1283). */
export const ENDED_SAID = "Sleep mode is off, so the reminder to end it came off this session's manual steps card, and comes off every other session's within a minute."

/**
 * How a night's review happened: `sleep-ended` since #1283; `nothing-proposed` and
 * `pickers-answered` were written before it. Any way written is read as done (L255).
 */
export type ReviewHow = string
/** One night's morning review, by the sleep record's generation: pending until `done`. */
export type MorningReview = { generation: string; night: string; done?: { at: number; how: ReviewHow } }

/** The pending nights that have ended: every one but the night asleep now, however it ended (#1283). */
export const stalePending = (all: readonly MorningReview[], asleep: string | null): MorningReview[] => all.filter(x => !x.done && x.generation !== asleep)

/** How many nights are kept: a step older than two weeks still on a card is taken off by Done. */
export const KEPT_NIGHTS = 14

/** The nights in the file, or why it could not be read: never read as no nights (L215). */
export const reviewsIn = (text: string): MorningReview[] | { unreadable: string } => {
  let j: unknown
  try {
    j = JSON.parse(text)
  } catch {
    return { unreadable: 'it is not JSON' }
  }
  if (!Array.isArray(j)) return { unreadable: 'it is not a list of nights' }
  const out: MorningReview[] = []
  for (const x of j) {
    const r = x as Partial<MorningReview> | null
    if (!r || typeof r.generation !== 'string' || typeof r.night !== 'string') return { unreadable: 'a night in it names no generation or night' }
    // Done any way written, an older way or a later one, so no reader turns a done night back into a pending step (L255).
    const done = r.done && typeof r.done.at === 'number' && Number.isFinite(r.done.at) && typeof r.done.how === 'string' ? { done: { at: r.done.at, how: r.done.how } } : {}
    out.push({ generation: r.generation, night: r.night, ...done })
  }
  return out
}

/** The nights with this one pending, written once, the most recent KEPT_NIGHTS kept. */
export const withPending = (all: readonly MorningReview[], r: { generation: string; night: string }): MorningReview[] =>
  [...all.filter(x => x.generation !== r.generation), { generation: r.generation, night: r.night }].slice(-KEPT_NIGHTS)

/** The nights with this one's review done, the first way it happened kept. A night not in the list is added done. */
export const withDone = (all: readonly MorningReview[], r: { generation: string; night: string }, done: { at: number; how: ReviewHow }): MorningReview[] =>
  all.some(x => x.generation === r.generation)
    ? all.map(x => (x.generation === r.generation && !x.done ? { ...x, done } : x))
    : [...all, { generation: r.generation, night: r.night, done }].slice(-KEPT_NIGHTS)

/**
 * Whether a picker reached Dan and came back with his answer: not refused (a refusal never reached
 * him, and the picker is asked again), not failed, not closed by itself while he was away, and at
 * least one question answered. Undefined for a refused one, which counts neither way. Since #1283 it
 * no longer gates the reminder; a session's morning turn counts with it, so one left unanswered is
 * asked again (#1285).
 */
export const pickerAnswered = (r: { deny?: unknown; isError?: unknown; result?: unknown }): boolean | undefined => {
  if (r.deny !== undefined) return undefined
  if (r.isError) return false
  const out = (r.result ?? {}) as { answers?: unknown; afkTimeoutMs?: unknown }
  if (out.afkTimeoutMs !== undefined) return false
  const answers = out.answers && typeof out.answers === 'object' ? Object.values(out.answers as Record<string, unknown>) : []
  return answers.some(a => (typeof a === 'string' && a.trim() !== '') || (Array.isArray(a) && a.length > 0))
}
