import type { ModKitBandFrame, ModKitBandLine, ModKitBandPart, ModKitBandRow, ModKitBandSlot } from '../types/index.d.ts'

// The band above the prompt, composed once for every mod (docs/mods-design.md, "The band, shared
// by every mod", settled with Dan 2026-10-04). Status rows on top, what waits on Dan nearest the
// prompt (the handoff card, which appears only at session start, the held while away card, the
// steps card, a message to send), and an open question alone so a number key can only mean its answer.
//
// A Record over the slot type, so a slot added to the contract without a place here fails to type
// check rather than sorting as undefined (L113).
const RANK: Record<ModKitBandSlot, number> = {
  'needs-a-look': 0,
  compact: 1,
  handoff: 2,
  held: 3,
  steps: 4,
  message: 5,
  question: 6,
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
  if (plain !== undefined && plain !== true) return `a button's plain must be true or left out, not ${JSON.stringify(plain)}`
  return undefined
}

export const isSlot = (s: unknown): s is ModKitBandSlot => typeof s === 'string' && Object.prototype.hasOwnProperty.call(RANK, s)

/** Why a row cannot be shown, or undefined when it can. */
export const refusal = (row: ModKitBandRow): string | undefined => {
  if (!row || typeof row.mod !== 'string' || !row.mod || typeof row.id !== 'string' || !row.id) return 'a band row needs a mod and an id'
  if (!isSlot(row.slot)) return `a band row's slot "${String(row.slot)}" is not one of ${Object.keys(RANK).join(', ')}`
  if (!Array.isArray(row.lines) || !row.lines.every(l => Array.isArray(l) || isDivider(l)))
    return `band row ${row.mod}/${row.id}: lines must be a list of lines, each a list of parts or { divider: true }`
  for (const l of row.lines) {
    if (!Array.isArray(l)) continue
    for (const p of l) {
      const why = partRefusal(p)
      if (why) return `band row ${row.mod}/${row.id}: ${why}`
    }
  }
  // Refused here rather than drawn as no frame: a card that lost its frame reads as another mod's row.
  if (row.frame !== undefined) {
    const f = row.frame as { kind?: unknown; color?: unknown } | null
    if (!f || typeof f !== 'object') return `band row ${row.mod}/${row.id}: a frame must be { kind, color? }`
    if (typeof f.kind !== 'string' || !Object.prototype.hasOwnProperty.call(FRAMES, f.kind))
      return `band row ${row.mod}/${row.id}: frame kind "${String(f.kind)}" is not one of ${Object.keys(FRAMES).join(', ')}`
    if (f.color !== undefined && (typeof f.color !== 'string' || !f.color)) return `band row ${row.mod}/${row.id}: a frame colour must be a theme key or a colour name`
  }
  return undefined
}

/** The rows with this one put in: in place when the mod already shows a row under its id, else last. */
export const put = (rows: readonly ModKitBandRow[], row: ModKitBandRow): ModKitBandRow[] => {
  const i = rows.findIndex(r => r.mod === row.mod && r.id === row.id)
  if (i < 0) return [...rows, row]
  const next = [...rows]
  next[i] = row
  return next
}

export const drop = (rows: readonly ModKitBandRow[], mod: string, id: string): ModKitBandRow[] => rows.filter(r => !(r.mod === mod && r.id === id))

/** What the band draws, top to bottom: by slot, publishing order within one; a question alone. */
export const compose = (rows: readonly ModKitBandRow[]): ModKitBandRow[] => {
  const questions = rows.filter(r => r.slot === 'question')
  if (questions.length) return questions
  // Array sort is stable, so rows in one slot keep the order they were first published in.
  return [...rows].sort((a, b) => RANK[a.slot] - RANK[b.slot])
}
