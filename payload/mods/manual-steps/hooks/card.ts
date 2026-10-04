import type { StepsCard, StepsFinish, StepsStep } from '../types/index.d.ts'

// The steps card's data (#614, docs/mods-design.md "Manual steps"): what a handover must carry, and
// the lines the card is drawn as. Pure, so the band (through mod-kit) and the side pane draw the
// same lines from one place.

/** What Claude says it found when it checked a step against the current state before handing it over. */
export const CHECKED = ['already-done', 'not-done', 'cannot-check'] as const
/** What Claude says after Dan pressed Done: it checked it took, it cannot check (so on Dan's word), or it did not take. */
export const VERDICTS = ['checked', 'per-you', 'not-done'] as const
export type StepsVerdict = (typeof VERDICTS)[number]

// How a finished step reads after its struck title (design round: "already done" grey, "checked"
// green, "done, per you" grey). A Record over the type, so a new way of finishing cannot ship
// without its words (L113).
const FINISH: Record<StepsFinish, { text: string; color?: string; dim?: boolean }> = {
  already: { text: 'already done', dim: true },
  checked: { text: 'checked', color: 'success' },
  'per-you': { text: 'done, per you', dim: true },
}

const AMBER = 'warning'

type Refused = { refusal: string }
type Made = { card: StepsCard }

const str = (v: unknown): string | undefined => (typeof v === 'string' && v.trim() ? v.trim() : undefined)
// One terminal line each: the band cuts a line at its edge and never wraps it.
const oneLine = (s: string) => s.replace(/\s+/g, ' ').trim()

/** The card a handover describes, or why it is refused, naming the step. */
export const cardFrom = (input: unknown): Made | Refused => {
  const o = (input && typeof input === 'object' ? input : {}) as { heading?: unknown; steps?: unknown }
  const heading = str(o.heading)
  if (!heading) return { refusal: 'The card needs a heading: what the steps are for, in a few words.' }
  if (!Array.isArray(o.steps) || o.steps.length === 0) return { refusal: 'There are no steps to pin.' }
  const steps: StepsStep[] = []
  for (const [i, raw] of o.steps.entries()) {
    const s = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>
    const n = i + 1
    const title = str(s.title)
    if (!title) return { refusal: `Step ${n} has no title.` }
    const name = `Step ${n} (${oneLine(title)})`
    const url = str(s.url)
    const location = str(s.location)
    if (!url && !location)
      return {
        refusal: `${name} has no link or exact location, so Dan would have to hunt for it. Give its url (https://...), or where there is no page, the exact place: the app, screen and section.`,
      }
    if (url && !/^https?:\/\/[^\s/]+/.test(url)) return { refusal: `${name}: its link "${url}" is not a web address; give the whole https:// link.` }
    const checked = s.checked
    if (typeof checked !== 'string' || !(CHECKED as readonly string[]).includes(checked))
      return {
        refusal: `${name} does not say whether you checked it against the current state first. Check it, then set checked to already-done, not-done or cannot-check.`,
      }
    const step: StepsStep = { title: oneLine(title) }
    if (url) step.url = url
    if (location) step.location = oneLine(location)
    const clicks = str(s.clicks)
    if (clicks) step.clicks = oneLine(clicks)
    // The value is kept exactly as given, since Copy must paste what Claude handed over.
    if (typeof s.value === 'string' && s.value.trim()) step.value = s.value
    if (checked === 'already-done') step.finished = 'already'
    steps.push(step)
  }
  return { card: { heading: oneLine(heading), steps } }
}

/** The index of the step to do next: the first not yet finished. */
export const nextStep = (card: StepsCard): number | undefined => {
  const i = card.steps.findIndex(s => !s.finished)
  return i < 0 ? undefined : i
}

/** The card with step `i` (0 based) marked as sent, or no longer sent. */
export const sent = (card: StepsCard, i: number, isSent: boolean): StepsCard => ({
  ...card,
  steps: card.steps.map((s, k) => (k === i ? { ...s, isSent } : s)),
})

/** The card after Claude's verdict on step `n` (1 based), or why it cannot be applied. */
export const finish = (card: StepsCard, n: number, verdict: StepsVerdict): Made | Refused => {
  if (!(VERDICTS as readonly string[]).includes(verdict)) return { refusal: `"${String(verdict)}" is not one of ${VERDICTS.join(', ')}.` }
  const step = Number.isInteger(n) ? card.steps[n - 1] : undefined
  if (!step) return { refusal: `There is no step ${n}; the card has ${card.steps.length}.` }
  if (step.finished) return { refusal: `Step ${n} is already finished (${FINISH[step.finished].text}).` }
  const next: StepsStep = verdict === 'not-done' ? { ...step, isSent: false } : { ...step, isSent: false, finished: verdict }
  return { card: { ...card, steps: card.steps.map((s, k) => (k === n - 1 ? next : s)) } }
}

/** One part of a card line, in mod-kit's band row shape (plain data). */
export type CardPart = { text: string; color?: string; bold?: boolean; dim?: boolean; strikethrough?: boolean; indent?: number } | { button: 'done' | 'copy'; label: string }

/**
 * The card's lines: the amber heading, then each step on its own line. Only the next step is open,
 * bold in the terminal's own text colour, with Done and, indented under it, its link or location,
 * its clicks and any value with Copy. A later step is its title alone; a finished one is dimmed and
 * struck through, then how it finished.
 */
export const cardLines = (card: StepsCard): CardPart[][] => {
  const lines: CardPart[][] = [[{ text: card.heading, color: AMBER }]]
  const open = nextStep(card)
  card.steps.forEach((s, i) => {
    const label = `${i + 1}. ${s.title}`
    if (s.finished) {
      lines.push([{ text: label, dim: true, strikethrough: true }, { ...FINISH[s.finished], text: `  ${FINISH[s.finished].text}` }])
      return
    }
    if (i !== open) {
      lines.push([{ text: label }])
      return
    }
    lines.push([{ text: label, bold: true }, ...(s.isSent ? [{ text: '  sent', dim: true }] : [{ text: '  ' }, { button: 'done' as const, label: 'Done' }])])
    // Under the title, where its text starts.
    const indent = String(i + 1).length + 2
    const where = s.url ?? s.location
    if (where) lines.push([{ text: where, indent }])
    if (s.clicks) lines.push([{ text: s.clicks, indent }])
    if (s.value) lines.push([{ text: oneLine(s.value), indent }, { text: '  ' }, { button: 'copy', label: 'Copy' }])
  })
  return lines
}

/** What the next session's Claude reads about steps carried over from an earlier one in this project. */
export const carriedNote = (card: StepsCard): string => {
  const left = card.steps.map((s, i) => ({ s, n: i + 1 })).filter(x => !x.s.finished)
  return [
    `Manual steps carried over from an earlier session in this project, not yet shown to Dan: "${card.heading}".`,
    ...left.map(({ s, n }) => `- step ${n}: ${s.title} (${s.url ?? s.location})`),
    'Before they are shown, check each against the current state, then pin the ones still to do with the manual-steps steps tool (checked set for each), or tell Dan they are all done.',
  ].join('\n')
}
