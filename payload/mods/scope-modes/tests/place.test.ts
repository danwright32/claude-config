import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { isNewer, placeFile, placeSaid, placeText, readPlace, type PlaceRecord } from '../hooks/place.ts'

// #2099: the away or home switch Dan types is kept in one record every session on this Mac reads at
// its next prompt or minute, so no message between sessions is needed (Dan, 2026-11-03).
const REC: PlaceRecord = { v: 1, place: 'away', at: 1_000, by: 's1', cwd: '/repo', how: '/away' }

describe('the switch record', () => {
  test('lives under the Mac\'s own state, outside any repository and never synced', () => {
    expect(placeFile('/Users/x')).toBe('/Users/x/.claude/state/scope-modes/place.json')
    expect(placeFile('/Users/x/')).toBe('/Users/x/.claude/state/scope-modes/place.json')
  })
  test('reads back what was written, with who switched, when, from where and how', () => {
    expect(readPlace(placeText(REC))).toEqual({ record: REC })
  })
  test('anything else is said as not read, never read as a switch (L50)', () => {
    expect(readPlace('{')).toEqual({ why: expect.stringMatching(/^the switch record is not JSON/) })
    expect(readPlace('null')).toEqual({ why: 'the switch record is not one scope modes wrote (not an object)' })
    expect(readPlace(JSON.stringify({ ...REC, v: 2 }))).toEqual({ why: 'the switch record is not one scope modes wrote (version 2)' })
    expect(readPlace(JSON.stringify({ ...REC, place: 'asleep' }))).toEqual({ why: 'the switch record is not one scope modes wrote (place "asleep")' })
    expect(readPlace(JSON.stringify({ ...REC, at: '1000' }))).toEqual({ why: 'the switch record is not one scope modes wrote (time "1000")' })
    expect(readPlace(JSON.stringify({ ...REC, at: -1 }))).toEqual({ why: 'the switch record is not one scope modes wrote (time -1)' })
    expect(readPlace(JSON.stringify({ ...REC, by: 7 }))).toEqual({ why: 'the switch record is not one scope modes wrote (session 7)' })
  })
  test('a session takes a switch only when it is newer than the newest it holds', () => {
    expect(isNewer(REC, 999)).toBe(true)
    // Its own switch, and one made before it started, are not taken again.
    expect(isNewer(REC, 1_000)).toBe(false)
    expect(isNewer(REC, 1_001)).toBe(false)
  })
})

describe('what a switch says', () => {
  test('with no other session open, only this one', () => {
    expect(placeSaid('away', { recorded: true, others: 0 })).toBe('Away is on in this session.')
  })
  test('the other open sessions follow within a minute, counted when the registry answers', () => {
    expect(placeSaid('away', { recorded: true, others: 1 })).toBe('Away is on in this session; the other open session switches to away within a minute.')
    expect(placeSaid('home', { recorded: true, others: 3 })).toBe('Home is on in this session; the 3 other open sessions switch to home within a minute.')
    // A registry that cannot be read is never read as no other session (L215).
    expect(placeSaid('home', { recorded: true, others: null })).toBe('Home is on in this session; every other open session on this Mac switches to home within a minute.')
  })
  test('a record that could not be written says why, and how Dan switches the rest by hand', () => {
    expect(placeSaid('away', { recorded: false, why: 'EACCES: permission denied' })).toBe(
      'Away is on in this session only: the other sessions stay where they are, because the switch could not be recorded for them (EACCES: permission denied). To switch one, type /away in it: any session whose band does not show AWAY.',
    )
    expect(placeSaid('home', { recorded: false, why: 'mv exited 1' })).toBe(
      'Home is on in this session only: the other sessions stay where they are, because the switch could not be recorded for them (mv exited 1). To switch one, type /home in it: any session whose band still shows AWAY.',
    )
  })
  test('a switch Dan did not type reaches no other session', () => {
    expect(placeSaid('away', { notDans: true })).toBe('Away is on in this session only: Dan did not type this switch, so it reaches no other session.')
  })
})
