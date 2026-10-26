import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { ASKED_PANE, FOLLOW_MS, follow, UNASKED_PANE } from '../hooks/place.ts'

// #1752: a card pinned in a narrow window went to the band and stayed there after the window was
// widened, since where it goes was decided only at the pin. The pane a new card opens unasked is now
// left open while it waits undrawn, and its state in Claude Code's own list ($.ui.panes()) is read
// while the card is shown, so the card goes where it would have gone had the window been that wide
// when it was pinned. `follow` is that decision, from where the card is and the unasked pane's row.

const placed = { isPlaced: true }
const waiting = { isPlaced: false }

describe('follow', () => {
  test('a card in the band moves to the pane once Claude Code places the pane it waits in', () => {
    expect(follow('band', placed)).toBe('to-pane')
  })

  test('a card in the band stays there while its pane still waits undrawn', () => {
    expect(follow('band', waiting)).toBe('stay')
  })

  test('a card in the unasked pane goes back to the band once the pane is no longer drawn', () => {
    expect(follow(UNASKED_PANE, waiting)).toBe('to-band')
  })

  test('a card in the unasked pane stays while it is drawn', () => {
    expect(follow(UNASKED_PANE, placed)).toBe('stay')
  })

  // Moved by hand: /steps put it in a pane of its own, placed at any width, or Dan closed the pane
  // and the card went to the band with no unasked pane left open. Neither is moved back.
  test('a card in the pane /steps opened is never moved, whatever the unasked pane says', () => {
    expect(follow(ASKED_PANE, placed)).toBe('stop')
    expect(follow(ASKED_PANE, waiting)).toBe('stop')
    expect(follow(ASKED_PANE, undefined)).toBe('stop')
  })

  test('with no unasked pane open, as after Dan closed it by hand, nothing is followed', () => {
    expect(follow('band', undefined)).toBe('stop')
    expect(follow(UNASKED_PANE, undefined)).toBe('stop')
  })

  test('a card shown nowhere (finished, held or carried) is not followed', () => {
    expect(follow(null, placed)).toBe('stop')
    expect(follow(null, waiting)).toBe('stop')
  })

  test('the two pane ids differ, so asking never lowers the width a card opened unasked needs (#708)', () => {
    expect(ASKED_PANE).not.toBe(UNASKED_PANE)
  })

  test('the follow reads the pane list about once a second, often enough to keep a resize quick', () => {
    expect(FOLLOW_MS).toBeGreaterThan(0)
    expect(FOLLOW_MS).toBeLessThanOrEqual(1000)
  })
})
