// Sleep mode's morning reminder (#1107). Dan, 2026-10-12 and 13: "Can you make it so when I enter
// sleep mode, the manual steps panel pops up with a step to rescue the night's findings?" and,
// choosing the morning reminder reading: "Basically I want a way to remember in the morning to review
// the issues." So /sleep pins one step on the manual steps card, and it comes off only once the
// morning review has happened: the wake pickers answered, or a night with nothing proposed, said so.
// Never by time, and never by a wake that offered him nothing to answer (a phone wake whose pickers
// he never saw).
//
// The step can sit in one session's card while Dan wakes in another, so whether the review happened
// is kept on disk beside the sleep record (`morning-review.json`), and every session takes the step
// off its own card once it reads that it did. Only the decisions live here; register.ts carries
// them out.

/** The heading of a card made for the step alone, when no card is pinned at bedtime. */
export const MORNING_HEADING = 'The morning after sleep mode'

/** The step, by its night (the ET date sleep began on), so each night's step is told apart by its title. */
export const morningStep = (night: string) => ({
  title: `When you are up: review the night's proposed issues (${night})`,
  location: "This Mac, in the session where you say I'm up or type /wake",
  clicks: ["Say I'm up, or type /wake", "Answer the pickers for the night's proposed issues and lessons"],
})

/** How a night's morning review happened: nothing was proposed, or Dan answered the wake pickers. */
export type ReviewHow = 'nothing-proposed' | 'pickers-answered'
/** One night's morning review, by the sleep record's generation: pending until `done`. */
export type MorningReview = { generation: string; night: string; done?: { at: number; how: ReviewHow } }

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
    const done = r.done && typeof r.done.at === 'number' && (r.done.how === 'nothing-proposed' || r.done.how === 'pickers-answered') ? { done: r.done } : {}
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
 * Whether the night left nothing to review: no issue or lesson proposed, every note read, and the
 * notes themselves read. Notes that could not be read may hide a proposal, so they are not nothing.
 */
export const nothingProposed = (p: { issues: readonly unknown[]; lessons: readonly unknown[]; bad?: number; unread?: string }): boolean =>
  p.unread === undefined && !p.bad && p.issues.length === 0 && p.lessons.length === 0

/**
 * Whether a picker reached Dan and came back with his answer: not refused (a refusal never reached
 * him, and the picker is asked again), not failed, not closed by itself while he was away, and at
 * least one question answered. Undefined for a refused one, which counts neither way.
 */
export const pickerAnswered = (r: { deny?: unknown; isError?: unknown; result?: unknown }): boolean | undefined => {
  if (r.deny !== undefined) return undefined
  if (r.isError) return false
  const out = (r.result ?? {}) as { answers?: unknown; afkTimeoutMs?: unknown }
  if (out.afkTimeoutMs !== undefined) return false
  const answers = out.answers && typeof out.answers === 'object' ? Object.values(out.answers as Record<string, unknown>) : []
  return answers.some(a => (typeof a === 'string' && a.trim() !== '') || (Array.isArray(a) && a.length > 0))
}

/** The morning turn's pickers, counted: the review happened once it ended answered, with every picker answered. */
export type MorningWatch = { generation: string; night: string; turnId?: string; answered: number; unanswered: number }
export const reviewedAtEnd = (w: MorningWatch, reason: string): boolean => reason === 'answer' && w.answered > 0 && w.unanswered === 0

/** What is said once the step comes off, by how the review happened. */
export const clearedSaid = (how: ReviewHow): string =>
  how === 'nothing-proposed'
    ? 'Nothing was proposed overnight, so the reminder to review it came off the manual steps card.'
    : "The night's proposals were reviewed, so the reminder to review them came off the manual steps card."
