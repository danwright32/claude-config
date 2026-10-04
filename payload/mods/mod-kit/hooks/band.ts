import type { ModKitBandFrame, ModKitBandLine, ModKitBandPart, ModKitBandRow, ModKitBandSlot, ModKitPane, ModKitQuestion } from '../types/index.d.ts'

// The band above the prompt, composed once for every mod (docs/mods-design.md, "The band, shared
// by every mod", settled with Dan 2026-10-04). Status rows on top, then the account room card (#659)
// about this account's limits, what waits on Dan nearest the
// prompt (the handoff card, which appears only at session start, the held while away card, the
// steps card, a message to send), and an open question alone so a number key can only mean its
// answer: one question at a time, since two mods can each have one open (#703).
//
// A Record over the slot type, so a slot added to the contract without a place here fails to type
// check rather than sorting as undefined (L113).
const RANK: Record<ModKitBandSlot, number> = {
  'needs-a-look': 0,
  compact: 1,
  room: 2,
  handoff: 3,
  held: 4,
  steps: 5,
  message: 6,
  question: 7,
}

// Also a Record over the type, so a frame kind added to the contract without being drawn fails to type check.
const FRAMES: Record<ModKitBandFrame['kind'], true> = { box: true, 'left-rule': true }

export const isDivider = (l: ModKitBandLine): l is { divider: true } => !Array.isArray(l) && !!l && (l as { divider?: unknown }).divider === true

const partRefusal = (p: ModKitBandPart): string | undefined => {
  if (!p || typeof p !== 'object') return 'a part must be a text run or a button'
  const indent = (p as { indent?: unknown }).indent
  if (indent !== undefined && !(typeof indent === 'number' && Number.isInteger(indent) && indent >= 0)) return `a part's indent must be a whole number of columns, not ${JSON.stringify(indent)}`
  // Refused rather than drawn bracketed: a picker whose options lost their plain style reads as another mod's buttons.
  const plain = (p as { plain?: unknown }).plain
  if (plain !== undefined && !('button' in p)) return 'only a button can be plain; a text run draws as it is'
  if (plain !== undefined && plain !== true) return `a button's plain must be true or left out, not ${JSON.stringify(plain)}`
  const wrap = (p as { wrap?: unknown }).wrap
  if (wrap !== undefined && 'button' in p) return 'only a text run can wrap; a button is drawn whole'
  if (wrap !== undefined && wrap !== true) return `a text run's wrap must be true or left out, not ${JSON.stringify(wrap)}`
  // Refused rather than drawn as plain text: a link that cannot be followed is what #708 fixed.
  const href = (p as { href?: unknown }).href
  if (href !== undefined && 'button' in p) return 'only a text run can be a link; a button is pressed, not followed'
  if (href !== undefined && (typeof href !== 'string' || !href.trim())) return `a link's href must be its address, not ${JSON.stringify(href)}`
  // One could end the terminal's hyperlink sequence early and have what follows written as is.
  if (typeof href === 'string' && /[\u0000-\u001f\u007f-\u009f]/.test(href)) return `a link's href ${JSON.stringify(href)} holds a control character`
  return undefined
}

const wraps = (l: ModKitBandLine): boolean => Array.isArray(l) && l.some(p => (p as { wrap?: unknown }).wrap === true)

export const isSlot = (s: unknown): s is ModKitBandSlot => typeof s === 'string' && Object.prototype.hasOwnProperty.call(RANK, s)

// What a band row and a pane both carry, checked once for both (#690): who publishes it, then its
// lines and its frame. `what` names which it is in the refusal.
const ownerRefusal = (card: ModKitPane, what: string): string | undefined =>
  !card || typeof card.mod !== 'string' || !card.mod || typeof card.id !== 'string' || !card.id ? `a ${what} needs a mod and an id` : undefined

const bodyRefusal = (card: ModKitPane, what: string): string | undefined => {
  const name = `${what} ${card.mod}/${card.id}`
  if (!Array.isArray(card.lines) || !card.lines.every(l => Array.isArray(l) || isDivider(l))) return `${name}: lines must be a list of lines, each a list of parts or { divider: true }`
  for (const l of card.lines) {
    if (!Array.isArray(l)) continue
    for (const p of l) {
      const why = partRefusal(p)
      if (why) return `${name}: ${why}`
    }
  }
  // Refused here rather than drawn as no frame: a card that lost its frame reads as another mod's row.
  if (card.frame !== undefined) {
    const f = card.frame as { kind?: unknown; color?: unknown } | null
    if (!f || typeof f !== 'object') return `${name}: a frame must be { kind, color? }`
    if (typeof f.kind !== 'string' || !Object.prototype.hasOwnProperty.call(FRAMES, f.kind)) return `${name}: frame kind "${String(f.kind)}" is not one of ${Object.keys(FRAMES).join(', ')}`
    if (f.color !== undefined && (typeof f.color !== 'string' || !f.color)) return `${name}: a frame colour must be a theme key or a colour name`
    // The rule is one mark per line, so a line that wrapped onto two would leave its rule short.
    if (f.kind === 'left-rule' && card.lines.some(wraps)) return `${name}: a run cannot wrap inside a left rule, which draws one mark per line`
  }
  return undefined
}

/** Why a row cannot be shown, or undefined when it can. */
export const refusal = (row: ModKitBandRow): string | undefined => {
  const who = ownerRefusal(row, 'band row')
  if (who) return who
  if (!isSlot(row.slot)) return `a band row's slot "${String(row.slot)}" is not one of ${Object.keys(RANK).join(', ')}`
  // Built only by questionRow, so no mod draws a question its own way (#703, #705: two hand built
  // question rows had drifted into two looks on one surface).
  if (row.slot === 'question') return `band row ${row.mod}/${row.id}: a question is asked with $.modkit.question, so every question in the band reads the same`
  return bodyRefusal(row, 'band row')
}

// Hotkeys are the digits 1 to 9, one per option.
const MAX_OPTIONS = 9

/** Why a question cannot be asked, or undefined when it can. */
export const questionRefusal = (q: ModKitQuestion): string | undefined => {
  const who = ownerRefusal(q as unknown as ModKitPane, 'question')
  if (who) return who
  const name = `question ${q.mod}/${q.id}`
  if (typeof q.chip !== 'string' || !q.chip.trim()) return `${name}: a question needs a chip, the short label drawn before it`
  if (typeof q.question !== 'string' || !q.question.trim()) return `${name}: a question needs its text`
  if (!Array.isArray(q.options) || q.options.length === 0) return `${name}: a question needs at least one option`
  if (q.options.length > MAX_OPTIONS) return `${name}: a question takes at most ${MAX_OPTIONS} options, one per number key, not ${q.options.length}`
  const buttons = new Set<string>()
  const claim = (button: unknown): string | undefined => {
    if (typeof button !== 'string' || !button) return `${name}: every option and Submit needs a button id`
    if (buttons.has(button)) return `${name}: button "${button}" twice, so a press could not tell which was meant`
    buttons.add(button)
    return undefined
  }
  for (const o of q.options) {
    if (!o || typeof o.label !== 'string' || !o.label.trim()) return `${name}: every option needs a label`
    const twice = claim(o.button)
    if (twice) return twice
    if (o.description !== undefined && typeof o.description !== 'string') return `${name}: an option's description must be text`
  }
  if (q.submit !== undefined) {
    if (!q.submit || typeof q.submit.label !== 'string' || !q.submit.label.trim()) return `${name}: Submit needs a label`
    const twice = claim(q.submit.button)
    if (twice) return twice
  }
  if (q.body !== undefined && !Array.isArray(q.body)) return `${name}: body must be a list of lines`
  return bodyRefusal({ mod: q.mod, id: q.id, lines: questionRow(q).lines }, 'question')
}

/**
 * The question as the band draws it (docs/mods-design.md, "Picker manners (#615)" and "Ask before
 * saving (#618)"): the chip in grey and the question in amber, as it waits on Dan, on one line; the
 * asker's own lines; each option as Claude Code's plain button, "1: 7 days", with its description
 * indented 3 columns, under the label rather than the number; Submit last, bracketed.
 */
export const questionRow = (q: ModKitQuestion): ModKitBandRow => {
  const lines: ModKitBandLine[] = [[{ text: `[${q.chip}] `, dim: true }, { text: q.question, color: 'warning', bold: true, wrap: true }], ...(q.body ?? [])]
  q.options.forEach((o, i) => {
    const line: ModKitBandPart[] = [{ button: o.button, label: o.label, hotkey: String(i + 1), plain: true }]
    if (o.chosen) line.push({ text: ' chosen', dim: true })
    lines.push(line)
    if (o.description) lines.push([{ text: o.description, dim: true, indent: 3, wrap: true }])
  })
  if (q.submit) lines.push([{ button: q.submit.button, label: q.submit.label }])
  return { mod: q.mod, id: q.id, slot: 'question', lines }
}

/**
 * Why a pane cannot be drawn, or undefined when it can. Claude Code keys a pane by its id alone,
 * so a pane another mod already draws under that id is refused rather than taken over.
 */
export const paneRefusal = (pane: ModKitPane, panes: readonly ModKitPane[]): string | undefined => {
  const why = ownerRefusal(pane, 'pane') ?? bodyRefusal(pane, 'pane')
  if (why) return why
  const holder = panes.find(p => p.id === pane.id && p.mod !== pane.mod)
  return holder ? `pane "${pane.id}" is already drawn for ${holder.mod}` : undefined
}

/** The rows with this one put in: in place when the mod already shows a row under its id, else last. */
export const put = <R extends ModKitPane>(rows: readonly R[], row: R): R[] => {
  const i = rows.findIndex(r => r.mod === row.mod && r.id === row.id)
  if (i < 0) return [...rows, row]
  const next = [...rows]
  next[i] = row
  return next
}

export const drop = <R extends ModKitPane>(rows: readonly R[], mod: string, id: string): R[] => rows.filter(r => !(r.mod === mod && r.id === id))

/** The question the band draws: the first asked of those open (rows keep the order first published in). */
export const shownQuestion = (rows: readonly ModKitBandRow[]): ModKitBandRow | undefined => rows.find(r => r.slot === 'question')

/** What the band draws, top to bottom: by slot, publishing order within one; one question, alone. */
export const compose = (rows: readonly ModKitBandRow[]): ModKitBandRow[] => {
  const question = shownQuestion(rows)
  if (question) return [question]
  // Array sort is stable, so rows in one slot keep the order they were first published in.
  return [...rows].sort((a, b) => RANK[a.slot] - RANK[b.slot])
}
