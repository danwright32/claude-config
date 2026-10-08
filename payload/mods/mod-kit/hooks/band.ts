import type { ModKitBandButton, ModKitBandFrame, ModKitBandLine, ModKitBandPart, ModKitBandRow, ModKitBandSlot, ModKitBandText, ModKitPane } from '../types/index.d.ts'

// The band above the prompt, composed once for every mod (docs/mods-design.md, "The band, shared
// by every mod", settled with Dan 2026-10-04). Status rows on top, then the account room card (#659)
// about this account's limits, what waits on Dan nearest the
// prompt (the handoff card, which appears only at session start, the held while away card, the
// steps card, a message to send). No question is drawn in the band: since #744 and #777 every
// question is Claude Code's own dialog.
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
}

// Also a Record over the type, so a frame kind added to the contract without being drawn fails to type check.
const FRAMES: Record<ModKitBandFrame['kind'], true> = { box: true, 'left-rule': true }

export const isDivider = (l: ModKitBandLine): l is { divider: true } => !Array.isArray(l) && !!l && (l as { divider?: unknown }).divider === true

/** What decides whether a click on a drawn Button reaches the mod (#939). */
export type ClickSite = { surface: string; isFullscreen: boolean | undefined; terminal: string | undefined }

/**
 * Whether a click on a Button drawn here reaches the mod. A remote surface (desktop, VS Code, mobile)
 * draws its own native buttons. The terminal reports clicks only in the fullscreen layout, and Apple
 * Terminal only while the tab's View > Allow Mouse Reporting is ticked, a switch cmd R flips and no
 * mod can read: off in Dan's tab when the steps card's Done did nothing (measured 2026-10-08). So a
 * terminal is trusted only when it is fullscreen, named, and not Apple Terminal; anything unmeasured
 * is taken as a click that may not land, since a dead control is worse than a typed fallback. A
 * multiplexer (tmux, screen) is unknown too: it names itself, not the terminal behind it.
 */
export const clicksReach = (site: ClickSite): boolean => {
  if (site.surface !== 'terminal') return true
  if (site.isFullscreen !== true) return false
  return typeof site.terminal === 'string' && site.terminal !== '' && !UNSURE_TERMINALS.has(site.terminal)
}

// Terminals a click may not reach through: Apple Terminal (its per tab switch), and the multiplexers,
// which name themselves rather than the terminal behind them, Apple Terminal among those (#946 review).
const UNSURE_TERMINALS = new Set(['Apple_Terminal', 'tmux', 'screen'])

/** What Dan types to press `mod`'s button `button` where a click cannot land (#939): mod-kit's /press. */
export const pressCommand = (mod: string, button: string): string => `/press ${mod} ${button}`

/**
 * What is drawn in a button's place where a click may not reach it: the publisher's `instead`, or
 * else the /press command that presses it the same way, which every publisher answers through
 * modkit.press, so no button anywhere is left dead (#939).
 */
export const fallbackOf = (mod: string, p: ModKitBandButton): ModKitBandText[] =>
  p.instead ?? [{ text: 'type: ', dim: true }, { text: pressCommand(mod, p.button) }]

/** The columns a button takes at most: its bracketed label, or the text drawn in its place where that is wider. */
export const buttonWidth = (p: ModKitBandButton, mod: string): number =>
  Math.max(p.label.length + 2, fallbackOf(mod, p).reduce((w, r) => w + r.text.length, 0)) + (p.indent ?? 0)

const insteadRefusal = (p: ModKitBandPart): string | undefined => {
  const instead = (p as { instead?: unknown }).instead
  if (instead === undefined) return undefined
  if (!('button' in p)) return 'only a button can have instead; a text run is drawn as it is'
  if (!Array.isArray(instead) || !instead.every(r => r && typeof r === 'object' && !('button' in r) && typeof (r as { text?: unknown }).text === 'string'))
    return `button "${p.button}": instead must be a list of text runs, drawn where a click cannot reach it`
  for (const r of instead as ModKitBandPart[]) {
    // Drawn as one plain run beside its neighbours: a layout field would be ignored, so it is refused.
    const run = r as { indent?: unknown; whole?: unknown; wrap?: unknown }
    if (run.indent !== undefined || run.whole !== undefined || run.wrap !== undefined)
      return `button "${p.button}" instead: an instead run takes no indent, whole or wrap; it is drawn as plain text where the button was`
    const why = partRefusal(r)
    if (why) return `button "${p.button}" instead: ${why}`
  }
  return undefined
}

const partRefusal = (p: ModKitBandPart): string | undefined => {
  if (!p || typeof p !== 'object') return 'a part must be a text run or a button'
  const insteadWhy = insteadRefusal(p)
  if (insteadWhy) return insteadWhy
  const indent = (p as { indent?: unknown }).indent
  if (indent !== undefined && !(typeof indent === 'number' && Number.isInteger(indent) && indent >= 0)) return `a part's indent must be a whole number of columns, not ${JSON.stringify(indent)}`
  // Refused rather than drawn bracketed: a picker whose options lost their plain style reads as another mod's buttons.
  const plain = (p as { plain?: unknown }).plain
  if (plain !== undefined && !('button' in p)) return 'only a button can be plain; a text run draws as it is'
  if (plain !== undefined && plain !== true) return `a button's plain must be true or left out, not ${JSON.stringify(plain)}`
  const wrap = (p as { wrap?: unknown }).wrap
  if (wrap !== undefined && 'button' in p) return 'only a text run can wrap; a button is drawn whole'
  if (wrap !== undefined && wrap !== true) return `a text run's wrap must be true or left out, not ${JSON.stringify(wrap)}`
  // #872: a label drawn whole beside a run that gives up the width; it cannot also be that run.
  const whole = (p as { whole?: unknown }).whole
  if (whole !== undefined && 'button' in p) return 'only a text run can be whole; a button is drawn whole already'
  if (whole !== undefined && whole !== true) return `a text run's whole must be true or left out, not ${JSON.stringify(whole)}`
  if (whole === true && wrap === true) return 'a text run cannot both wrap and be whole'
  // Refused rather than drawn as plain text: a link that cannot be followed is what #708 fixed.
  const href = (p as { href?: unknown }).href
  if (href !== undefined && 'button' in p) return 'only a text run can be a link; a button is pressed, not followed'
  if (href !== undefined && (typeof href !== 'string' || !href.trim())) return `a link's href must be its address, not ${JSON.stringify(href)}`
  // One could end the terminal's hyperlink sequence early and have what follows written as is.
  if (typeof href === 'string' && /[\u0000-\u001f\u007f-\u009f]/.test(href)) return `a link's href ${JSON.stringify(href)} holds a control character`
  return undefined
}

export const wraps = (l: ModKitBandLine): boolean => Array.isArray(l) && l.some(p => (p as { wrap?: unknown }).wrap === true)

/**
 * The most terminal rows `lines` can take at any width: one for a line that never wraps, and for one
 * that does one per character it holds, its indent and its buttons (the wider of brackets and instead text) included, since a row
 * holds at least one. What a left rule must reach down (#734); it is laid over the row's height and
 * clipped to it, so the bound only has to be no smaller than the truth.
 */
export const mostRows = (lines: ModKitBandLine[], mod: string): number =>
  lines.reduce(
    (n, l) => n + (Array.isArray(l) && wraps(l) ? Math.max(1, l.reduce((w, p) => w + ('button' in p ? buttonWidth(p, mod) : (p.indent ?? 0) + p.text.length), 0)) : 1),
    0,
  )

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
  }
  return undefined
}

/** Why a row cannot be shown, or undefined when it can. */
export const refusal = (row: ModKitBandRow): string | undefined => {
  const who = ownerRefusal(row, 'band row')
  if (who) return who
  if (!isSlot(row.slot)) return `a band row's slot "${String(row.slot)}" is not one of ${Object.keys(RANK).join(', ')}`
  return bodyRefusal(row, 'band row')
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

/** What the band draws, top to bottom: by slot, publishing order within one. */
export const compose = (rows: readonly ModKitBandRow[]): ModKitBandRow[] => {
  // A row stored under a slot the band no longer has (a question row kept in $.state from before
  // #796) has no place in the order and nothing left to answer it, so it is not drawn.
  // Array sort is stable, so rows in one slot keep the order they were first published in.
  return rows.filter(r => isSlot(r.slot)).sort((a, b) => RANK[a.slot] - RANK[b.slot])
}
