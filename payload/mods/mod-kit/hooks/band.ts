import type { ModKitBandRow, ModKitBandSlot } from '../types/index.d.ts'

// The band above the prompt, composed once for every mod (docs/mods-design.md, "The band, shared
// by every mod", settled with Dan 2026-10-04). Status rows on top, what waits on Dan nearest the
// prompt, and an open question alone so a number key can only mean its answer.
//
// A Record over the slot type, so a slot added to the contract without a place here fails to type
// check rather than sorting as undefined (L113).
const RANK: Record<ModKitBandSlot, number> = {
  'needs-a-look': 0,
  compact: 1,
  steps: 2,
  message: 3,
  question: 4,
}

export const isSlot = (s: unknown): s is ModKitBandSlot => typeof s === 'string' && Object.prototype.hasOwnProperty.call(RANK, s)

/** Why a row cannot be shown, or undefined when it can. */
export const refusal = (row: ModKitBandRow): string | undefined => {
  if (!row || typeof row.mod !== 'string' || !row.mod || typeof row.id !== 'string' || !row.id) return 'a band row needs a mod and an id'
  if (!isSlot(row.slot)) return `a band row's slot "${String(row.slot)}" is not one of ${Object.keys(RANK).join(', ')}`
  if (!Array.isArray(row.lines) || !row.lines.every(l => Array.isArray(l))) return `band row ${row.mod}/${row.id}: lines must be a list of lines, each a list of parts`
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
