import type { StepsPaneId } from '../types/index.d.ts'

// Where the steps card is shown, and where it goes when the window changes width (#1752). Pure, so
// the rule is tested on its own; register.tsx reads Claude Code's pane list and acts on it.

// The pane /steps opens, and the one a new card tries unasked: never the same id, since Claude Code
// places an unasked pane from 110 columns rather than 144 once its id has been asked for (#708).
export const ASKED_PANE = 'steps' satisfies StepsPaneId
export const UNASKED_PANE = 'steps-card' satisfies StepsPaneId
export const PANES: readonly StepsPaneId[] = [ASKED_PANE, UNASKED_PANE]

/** Where the card is shown: the steps row of the band, one of its panes, or nowhere. */
export type StepsPlace = 'band' | StepsPaneId | null

/** The unasked pane's row in Claude Code's pane list (`$.ui.panes()`), or undefined when it is not open. */
export type UnaskedRow = { isPlaced: boolean } | undefined

/**
 * What the card does now: `to-pane` once Claude Code draws the unasked pane a band card waits in,
 * `to-band` once it stops drawing the unasked pane the card is in, `stay` while neither changed, and
 * `stop` when there is nothing to follow, so the reading stops.
 */
export type Follow = 'to-pane' | 'to-band' | 'stay' | 'stop'

// #1752: a card pinned under 144 columns went to the band and stayed there after the window was
// widened (Dan, 2026-10-26, a PostRoll card pinned at 121 columns). The unasked pane is left open
// while it waits undrawn, and Claude Code draws it once the window reaches the floor; the card then
// leaves the band, and goes back to it should the pane stop being drawn. Only a card placed unasked
// is followed: one in the pane /steps opened, or in the band after Dan closed the pane by hand (no
// unasked pane is then open), stays where he put it.
export const follow = (place: StepsPlace, unasked: UnaskedRow): Follow => {
  if (unasked === undefined) return 'stop'
  if (place === 'band') return unasked.isPlaced ? 'to-pane' : 'stay'
  if (place === UNASKED_PANE) return unasked.isPlaced ? 'stay' : 'to-band'
  return 'stop'
}

// How often the pane list is read while a card is shown: once a second, so after a resize the card
// shows in both the band and the pane, or in neither, for at most that long. Chosen, not measured:
// each reading is one call answered from Claude Code's own record of its panes.
export const FOLLOW_MS = 1000
