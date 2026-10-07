import type { StepsCard, StepsFinish, StepsStep } from '../types/index.d.ts'

// The steps card's data (#614, docs/mods-design.md "Manual steps"): what a handover must carry, and
// the lines the card is drawn as. Pure, so the band (through mod-kit) and the side pane draw the
// same lines from one place.

/** What Claude says it found when it checked a step against the current state before handing it over. */
export const CHECKED = ['already-done', 'not-done', 'cannot-check'] as const
/**
 * What Claude says after Dan pressed Done: it checked it took, it cannot check (so on Dan's word), or
 * it did not take. Or, at any time, that a step cannot be done now and comes off the card (#872).
 */
export const VERDICTS = ['checked', 'per-you', 'not-done', 'withdrawn'] as const
export type StepsVerdict = (typeof VERDICTS)[number]

// How a finished step reads after its title. A Record over the type, so a new way of finishing
// cannot ship without its words (L113). Grey reads as old (#886: Dan took steps recorded a minute
// before for ones "done days ago"), so only a step finished before this card is grey: found done
// when it was pinned, or finished in an earlier session. One finished in this session is struck
// through in the terminal's own colour, with the time it finished. `earlier` is the words before
// "in an earlier session".
type Finish = { text: string; earlier: string; color?: string; isUndone?: true }
const FINISH: Record<StepsFinish, Finish> = {
  already: { text: 'already done before this card', earlier: 'already done' },
  checked: { text: 'checked', earlier: 'checked', color: 'success' },
  // Recorded by Claude on Dan's word with no Done pressed: labelled so, never read as his press.
  'per-you': { text: 'done, per you, recorded', earlier: 'done, per you,' },
  // Removed, never done (#872): its title is not struck through, which is how a done step reads.
  withdrawn: { text: 'taken off, not done', earlier: 'taken off, not done,', isUndone: true },
}
// A per you verdict on a step whose Done Dan pressed: the card asked, so it says he pressed it.
const PRESSED: Finish = { text: 'done, you pressed Done', earlier: 'done, you pressed Done,' }
const finishOf = (s: StepsStep): Finish => (s.finished === 'per-you' && s.isPressed ? PRESSED : FINISH[s.finished ?? 'already'])

/** The moment a card is drawn, and the zone its times are read in (left out, this Mac's own). */
export type DrawnAt = { now: number; timeZone?: string }

// When a step finished, as a clock time that never goes stale on a card nobody redraws (L589):
// "at 3:41 PM" on the day it is drawn, else "on Oct 4 at 3:41 PM", with the year when it differs.
// A zone Intl does not know is read as this Mac's own rather than refusing to draw the card.
export const finishedWhen = (at: number, drawn: DrawnAt): string => {
  const parts = (t: number, o: Intl.DateTimeFormatOptions) => {
    try {
      return new Intl.DateTimeFormat('en-US', { ...o, timeZone: drawn.timeZone }).format(t)
    } catch {
      return new Intl.DateTimeFormat('en-US', o).format(t)
    }
  }
  const time = parts(at, { hour: 'numeric', minute: '2-digit' })
  const day = (t: number) => parts(t, { year: 'numeric', month: 'short', day: 'numeric' })
  if (day(at) === day(drawn.now)) return `at ${time}`
  const sameYear = parts(at, { year: 'numeric' }) === parts(drawn.now, { year: 'numeric' })
  return `on ${parts(at, sameYear ? { month: 'short', day: 'numeric' } : { year: 'numeric', month: 'short', day: 'numeric' })} at ${time}`
}

const AMBER = 'warning'

type Refused = { refusal: string }
type Made = { card: StepsCard }

const str = (v: unknown): string | undefined => (typeof v === 'string' && v.trim() ? v.trim() : undefined)
// One line each, its spacing collapsed: a value or a title is cut at the band's edge, and a click path
// or a location wraps there (#734), as one line of text either way.
const oneLine = (s: string) => s.replace(/\s+/g, ' ').trim()

// The labels the card draws before a step's place and its clicks (#872), bold and whole, so the
// author never writes them. A bare location line read to Dan as an unexplained fragment.
const WHERE = 'Where: '
const WHAT = 'What to do: '
// A label an author wrote anyway, taken off the front so the card never draws it twice: the card's
// own two and the names an author reaches for instead, however cased or spaced.
const AUTHOR_LABEL = /^(?:where|location|what to do|then|clicks)\s*:\s*/i
const unlabelled = (s: string | undefined) => (s === undefined ? undefined : str(s.replace(AUTHOR_LABEL, '')))
// A list number an author put before an action, taken off since the card numbers the list itself.
// Only one a space follows, so a number that is the action's own text ("1.5x zoom") stays whole.
const AUTHOR_NUMBER = /^\d+[.)]\s+/

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
    const location = unlabelled(str(s.location))
    if (!url && !location)
      return {
        refusal: `${name} has no link or exact location, so Dan would have to hunt for it. Give its url (https://...), or where there is no page, a place Dan can find: the app and the window, then the screen or section.`,
      }
    // The whole link, not only its start: a space or a control character anywhere is no address,
    // and a control character would reach the terminal's hyperlink as it is (#708).
    if (url && !/^https?:\/\/[^\s/\u0000-\u001f\u007f-\u009f]+[^\s\u0000-\u001f\u007f-\u009f]*$/.test(url))
      return { refusal: `${name}: its link ${JSON.stringify(url)} is not a web address; give the whole https:// link.` }
    const checked = s.checked
    if (typeof checked !== 'string' || !(CHECKED as readonly string[]).includes(checked))
      return {
        refusal: `${name} does not say whether you checked it against the current state first. Check it, then set checked to already-done, not-done or cannot-check.`,
      }
    const step: StepsStep = { title: oneLine(title) }
    if (url) step.url = url
    if (location) step.location = oneLine(location)
    // The clicks as one string, or as a list of actions the card numbers one per line (#872). A list
    // of one is that one action as a string, drawn as a string always was.
    if (Array.isArray(s.clicks)) {
      if (!s.clicks.every(a => typeof a === 'string'))
        return { refusal: `${name}: its clicks must be a list of actions, each one a string.` }
      const actions = (s.clicks as string[])
        .map((a, k) => (k === 0 ? unlabelled(str(a)) : str(a)))
        .map(a => (a === undefined ? undefined : str(a.replace(AUTHOR_NUMBER, ''))))
        .filter((a): a is string => a !== undefined)
        .map(oneLine)
      if (actions.length === 1) step.clicks = actions[0]
      else if (actions.length > 1) step.clicks = actions
    } else {
      const clicks = unlabelled(str(s.clicks))
      if (clicks) step.clicks = oneLine(clicks)
    }
    // The value is kept exactly as given, since Copy must paste what Claude handed over.
    if (typeof s.value === 'string' && s.value.trim()) step.value = s.value
    if (checked === 'already-done') step.finished = 'already'
    steps.push(step)
  }
  return { card: { heading: oneLine(heading), steps } }
}

/**
 * `into` with the unfinished steps of `from` after its own, each titled with `from`'s heading. For a
 * card kept under a worktree's own folder before #708 beside one kept under the repository root:
 * both are held for Claude to re-check, so nothing is lost and nothing shows unchecked. A step
 * already there (its title and link) is not added again, whether it is there under its own title,
 * a step held under both keys (#734), or under the heading an earlier fold gave it, so folding
 * twice changes nothing.
 */
export const fold = (into: StepsCard, from: StepsCard): StepsCard => {
  const keyOf = (title: string, s: StepsStep) => `${title}\n${s.url ?? s.location}`
  const has = new Set(into.steps.map(s => keyOf(s.title, s)))
  const extra = (Array.isArray(from.steps) ? from.steps : [])
    .filter(s => s && typeof s.title === 'string' && !s.finished)
    .filter(s => !has.has(keyOf(s.title, s)) && !has.has(keyOf(`${from.heading}: ${s.title}`, s)))
    .map(s => ({ ...s, title: `${from.heading}: ${s.title}` }))
  return extra.length ? { ...into, steps: [...into.steps, ...extra] } : into
}

/**
 * How long a sent step waits, with no main turn running, for the turn its "step N done" starts
 * before Done comes back (#734). Between one turn's end and the next turn's start the settings
 * hooks run: the Stop hooks (15 seconds at most each) and the UserPromptSubmit hooks (10 at most),
 * each event's in parallel, so about 25 seconds at worst. Two minutes is well past that, and short
 * enough that a dropped prompt does not leave Done gone for long.
 */
export const DROPPED_AFTER_MS = 2 * 60_000

/** The index of the step to do next: the first not yet finished. */
export const nextStep = (card: StepsCard): number | undefined => {
  const i = card.steps.findIndex(s => !s.finished)
  return i < 0 ? undefined : i
}

/**
 * The card with step `i` (0 based) marked as sent, or no longer sent. Sent marks it pressed too,
 * which only `forgetPress` takes back, for a Done that never reached Claude (#886).
 */
export const sent = (card: StepsCard, i: number, isSent: boolean, forgetPress = false): StepsCard => ({
  ...card,
  steps: card.steps.map((s, k) => {
    if (k !== i) return s
    if (isSent) return { ...s, isSent, isPressed: true }
    if (!forgetPress) return { ...s, isSent }
    const { isPressed: _pressed, ...rest } = s
    return { ...rest, isSent }
  }),
})

/**
 * The card after Claude's verdict on step `n` (1 based), finished at `at` (epoch milliseconds), or
 * why it cannot be applied. Only the open step takes checked, per-you or not-done (#886): "step 2
 * done" with step 1 open was recorded as both, and the card claimed an install Dan never did, so a
 * verdict on any other step is refused and Claude is told to ask which he means. withdrawn takes any
 * unfinished step off, since it claims nothing was done.
 */
export const finish = (card: StepsCard, n: number, verdict: StepsVerdict, at?: number): Made | Refused => {
  if (!(VERDICTS as readonly string[]).includes(verdict)) return { refusal: `"${String(verdict)}" is not one of ${VERDICTS.join(', ')}.` }
  const step = Number.isInteger(n) ? card.steps[n - 1] : undefined
  if (!step) return { refusal: `There is no step ${n}; the card has ${card.steps.length}.` }
  if (step.finished) return { refusal: `Step ${n} is already finished (${finishOf(step).text}).` }
  const open = nextStep(card)
  if (verdict !== 'withdrawn' && open !== undefined && open !== n - 1) {
    const o = card.steps[open]
    return {
      refusal: `Step ${n} (${step.title}) is not the open step; step ${open + 1} (${o?.title ?? ''}) is. Do not guess which step Dan means, and do not record the steps before it to reach it. Ask Dan which step he means, then record only the open step; a step further on can be recorded once every step before it is finished.`,
    }
  }
  const next: StepsStep =
    // not-done answers the press, so it is forgotten: a later verdict on Dan's words never says he
    // pressed Done, and a new press marks it again.
    verdict === 'not-done'
      ? (({ isPressed: _pressed, ...rest }) => ({ ...rest, isSent: false }))(step)
      : { ...step, isSent: false, finished: verdict, ...(at === undefined ? {} : { finishedAt: at }) }
  return { card: { ...card, steps: card.steps.map((s, k) => (k === n - 1 ? next : s)) } }
}

/**
 * `card`, just pinned, with each step found already done keeping how and when it finished on `prior`,
 * the card it replaces (#886): pinned again, a step finished a minute ago, or days ago in an earlier
 * session, would otherwise read as "already done" with no time. Matched by title and link or location.
 * A step from a held card (carried from an earlier session) is marked as finished in one.
 */
export const keepFinished = (card: StepsCard, prior: StepsCard | null | undefined): StepsCard => {
  if (!prior || !Array.isArray(prior.steps)) return card
  const keyOf = (s: StepsStep) => `${s.title}\n${s.url ?? s.location}`
  const was = new Map(prior.steps.filter(s => s && s.finished && s.finished !== 'withdrawn').map(s => [keyOf(s), s]))
  const steps = card.steps.map(s => {
    const p = s.finished === 'already' ? was.get(keyOf(s)) : undefined
    if (!p?.finished) return s
    const kept: StepsStep = { ...s, finished: p.finished }
    if (p.finishedAt !== undefined) kept.finishedAt = p.finishedAt
    if (p.isPressed) kept.isPressed = true
    if (p.isEarlier || prior.isCarried) kept.isEarlier = true
    return kept
  })
  return { ...card, steps }
}

// A finished step's line (#886): its title, then how and when it finished. Grey, struck through, only
// for a step finished before this card: found already done (when, unknown), or in an earlier session
// (the card itself held from one, or a step pinned again from it). One finished in this session is
// struck through in the terminal's own colour. A withdrawn step is never struck through (#872).
const finishedLine = (s: StepsStep, label: string, isCarried: boolean, drawn: DrawnAt): CardPart[] => {
  const f = finishOf(s)
  const when = s.finishedAt === undefined ? '' : ` ${finishedWhen(s.finishedAt, drawn)}`
  const isOld = s.finished === 'already' || s.isEarlier === true || isCarried
  // Taken off, it reads as removed rather than done in either session: dimmed, never struck (#872).
  // The time goes with being taken off, never after "not done", which would read as not done then.
  if (f.isUndone) {
    if (!isOld && !when) return [{ text: label, dim: true }, { text: `  ${f.text}`, dim: true }]
    return [{ text: label, dim: true }, { text: `  taken off${isOld ? ' in an earlier session' : ''}${when}, not done`, dim: true }]
  }
  const title: CardPart = { text: label, ...(isOld ? { dim: true } : {}), strikethrough: true }
  if (s.finished === 'already' && !s.isEarlier && !isCarried) return [title, { text: `  ${f.text}`, dim: true }]
  if (isOld) return [title, { text: `  ${f.earlier} in an earlier session${when}`, dim: true }]
  return [title, { text: `  ${f.text}${when}`, ...(f.color ? { color: f.color } : {}) }]
}

/** One part of a card line, in mod-kit's band row shape (plain data); `href` makes it a link. */
export type CardPart =
  | { text: string; href?: string; color?: string; bold?: boolean; dim?: boolean; strikethrough?: boolean; indent?: number; wrap?: true; whole?: true }
  | { button: 'done' | 'copy' | 'copy-link'; label: string }

/**
 * The card's lines: the amber heading, "waiting on you" after it while the open step is Dan's,
 * then each step on its own line. Only the next step is open,
 * bold in the terminal's own text colour, with Done and, indented under it, its link or location
 * after a bold "Where:", its clicks after a bold "What to do:" (several actions numbered one per
 * line under it), and any value with Copy (#872). A later step is its title alone; a finished one is dimmed and
 * struck through, then how it finished. The link is a link part, which mod-kit draws as Claude
 * Code's Link, so one cut at the edge still opens and copies whole where the terminal draws
 * hyperlinks, with Copy link beside it for the terminals that do not, Apple Terminal among them (#708).
 */
export const cardLines = (card: StepsCard, drawn: DrawnAt = { now: Date.now() }): CardPart[][] => {
  const open = nextStep(card)
  // While the open step is Dan's to do, the heading says it waits on him (#863), on the card's own
  // line rather than a row of its own beside the card, so the band and the pane state it once.
  // Sent, it waits on Claude, and the step line says so.
  const isDans = open !== undefined && !card.steps[open]?.isSent
  const lines: CardPart[][] = [[{ text: card.heading, color: AMBER }, ...(isDans ? [{ text: '  waiting on you', dim: true }] : [])]]
  card.steps.forEach((s, i) => {
    const label = `${i + 1}. ${s.title}`
    if (s.finished) {
      lines.push(finishedLine(s, label, card.isCarried === true, drawn))
      return
    }
    if (i !== open) {
      lines.push([{ text: label }])
      return
    }
    lines.push([{ text: label, bold: true }, ...(s.isSent ? [{ text: '  sent', dim: true }] : [{ text: '  ' }, { button: 'done' as const, label: 'Done' }])])
    // Under the title, where its text starts.
    const indent = String(i + 1).length + 2
    // Each led by its label, bold and drawn whole, so a long link cut at the edge or a long location
    // wrapping beside it never takes the label with it (#872).
    const lead = (text: string): CardPart => ({ text, bold: true, whole: true, indent })
    if (s.url) lines.push([lead(WHERE), { text: s.url, href: s.url }, { text: '  ' }, { button: 'copy-link', label: 'Copy link' }])
    // A long location or click path wraps under its step rather than being cut at the edge (#734):
    // mod-kit's left rule reaches down every row it takes. It wraps beside its label, so the rows it
    // continues on sit under its own first word.
    else if (s.location) lines.push([lead(WHERE), { text: s.location, wrap: true }])
    if (typeof s.clicks === 'string') lines.push([lead(WHAT), { text: s.clicks, wrap: true }])
    else if (Array.isArray(s.clicks) && s.clicks.length) {
      // Several actions: the label on its own line, then each action numbered under it, its number
      // drawn whole and the action wrapping beside it (#872).
      lines.push([lead(WHAT)])
      const width = String(s.clicks.length).length
      s.clicks.forEach((a, k) => lines.push([{ text: `${String(k + 1).padStart(width)}. `, whole: true, indent: indent + 2 }, { text: a, wrap: true }]))
    }
    if (s.value) lines.push([{ text: oneLine(s.value), indent }, { text: '  ' }, { button: 'copy', label: 'Copy' }])
  })
  return lines
}

/** The widest a docked pane asks to be: past it, the transcript beside it gets too narrow. */
export const MAX_PANE_COLUMNS = 80
// The left rule and the gap after it.
const RULE = 2

/**
 * How wide the side pane asks to be while docked: its widest line, so a click path or an exact
 * location is not cut at the dock's edge (#708), up to MAX_PANE_COLUMNS. A link is not measured,
 * since it opens and copies whole however much of it shows; a button is its label in brackets.
 */
export const paneColumns = (card: StepsCard, drawn: DrawnAt = { now: Date.now() }): number => {
  const width = (l: CardPart[]) =>
    l.reduce((sum, p) => sum + ('button' in p ? p.label.length + 2 : p.href ? 0 : (p.indent ?? 0) + p.text.length), 0)
  return Math.min(MAX_PANE_COLUMNS, RULE + Math.max(...cardLines(card, drawn).map(width)))
}

/** What the next session's Claude reads about steps carried over from an earlier one in this project. */
export const carriedNote = (card: StepsCard): string => {
  const left = card.steps.map((s, i) => ({ s, n: i + 1 })).filter(x => !x.s.finished)
  return [
    `Manual steps carried over from an earlier session in this project, not yet shown to Dan: "${card.heading}".`,
    ...left.map(({ s, n }) => `- step ${n}: ${s.title} (${s.url ?? s.location})`),
    // The tool is the only way out: a card whose every step is already-done is not pinned and the
    // kept steps are cleared, where saying so in a reply would leave them to come back (#708).
    'Before they are shown, check each against the current state, then pin them again with the manual-steps steps tool, checked set for each: already-done for one you find done. Do that even when every one is done, since that is what clears the kept steps; otherwise they come back at every session start here.',
  ].join('\n')
}
