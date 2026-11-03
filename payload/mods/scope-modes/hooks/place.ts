// #2099: the away or home switch Dan types is kept in one record every session on this Mac reads at
// its next prompt or minute (Dan, 2026-11-03), so no message between sessions is needed: in auto mode
// every real message telling another session got no verdict, and those sessions stayed where they
// were. A /away, /home or switch in words writes the record only when Dan typed it; ending sleep
// (/wake, or the noon limit) writes it too, putting every session back where it was before sleep, as
// ending sleep already does for the whole Mac (register.ts decides all of that). A session never
// writes back what it read. Only the record's shape and what a switch says live here.

import type { ScopeModesPlace } from '../types/index.d.ts'

/** How the switch was made: Dan's command, his words, waking, or the limit ending his /sleep. */
export type PlaceHow = '/away' | '/home' | 'typed' | 'wake' | 'sleep limit'
const HOWS: readonly PlaceHow[] = ['/away', '/home', 'typed', 'wake', 'sleep limit']

export type PlaceRecord = {
  v: 1
  place: ScopeModesPlace
  /** When it was made, in ms from the engine's clock. */
  at: number
  /** The session it was made in. */
  by: string
  /** The folder that session runs in, so a switch can be traced to where it was typed. */
  cwd: string
  how: PlaceHow
}

/**
 * What a switch did for the other sessions: recorded for them (counted when the session registry
 * answers, null when it does not), not recorded and why, or not Dan's, so recorded for none.
 */
export type PlaceOutcome = { recorded: true; others: number | null } | { recorded: false; why: string } | { notDans: true }

/** Under this Mac's own state, outside any repository; claude-sync carries only the payload, so it is never synced. */
export const placeFile = (home: string) => `${home.replace(/\/+$/, '')}/.claude/state/scope-modes/place.json`

export const placeText = (r: PlaceRecord) => `${JSON.stringify(r)}\n`

const shown = (x: unknown) => JSON.stringify(x) ?? String(x)
const notOurs = (what: string) => ({ why: `the switch record is not one scope modes wrote (${what})` })

/** The record read back, or why it is not one: never read as a switch when it is anything else (L50). */
export const readPlace = (text: string): { record: PlaceRecord } | { why: string } => {
  let o: unknown
  try {
    o = JSON.parse(text)
  } catch (err) {
    return { why: `the switch record is not JSON (${err instanceof Error ? err.message : String(err)})` }
  }
  if (typeof o !== 'object' || o === null || Array.isArray(o)) return notOurs('not an object')
  const r = o as Record<string, unknown>
  if (r.v !== 1) return notOurs(`version ${shown(r.v)}`)
  if (r.place !== 'away' && r.place !== 'home') return notOurs(`place ${shown(r.place)}`)
  if (typeof r.at !== 'number' || !Number.isFinite(r.at) || r.at < 0) return notOurs(`time ${shown(r.at)}`)
  if (typeof r.by !== 'string' || !r.by) return notOurs(`session ${shown(r.by)}`)
  if (typeof r.cwd !== 'string') return notOurs(`folder ${shown(r.cwd)}`)
  if (!HOWS.includes(r.how as PlaceHow)) return notOurs(`made by ${shown(r.how)}`)
  return { record: { v: 1, place: r.place, at: r.at, by: r.by, cwd: r.cwd, how: r.how as PlaceHow } }
}

/** Whether a session takes this switch: only one newer than the newest it holds, its own included. */
export const isNewer = (r: PlaceRecord, seen: number) => r.at > seen

/** What a switch says to Dan, and opens Claude's acknowledgement with. */
export const placeSaid = (place: ScopeModesPlace, o: PlaceOutcome): string => {
  const name = place === 'away' ? 'Away' : 'Home'
  if ('notDans' in o) return `${name} is on in this session only: Dan did not type this switch, so it reaches no other session.`
  if (!o.recorded) {
    const band = place === 'away' ? 'does not show AWAY' : 'still shows AWAY'
    return `${name} is on in this session only: the other sessions stay where they are, because the switch could not be recorded for them (${o.why}). To switch one, type /${place} in it: any session whose band ${band}.`
  }
  // A registry that cannot be read is never read as no other session (L215).
  if (o.others === null) return `${name} is on in this session; every other open session on this Mac switches to ${place} within a minute.`
  if (o.others === 0) return `${name} is on in this session.`
  if (o.others === 1) return `${name} is on in this session; the other open session switches to ${place} within a minute.`
  return `${name} is on in this session; the ${o.others} other open sessions switch to ${place} within a minute.`
}
