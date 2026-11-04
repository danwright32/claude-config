// A long wait held against mod-kit's reload of the mod waiting (#2132). mod-kit's dependents pass
// touches a dependent mod's manifest, which reloads it and cancels every pending wait in the old
// copy: a prompt sent and waiting for the session to be idle, or a picker waiting on Dan's answer,
// is dropped without a word (#2100). A mod holds that reload back with $.modkit.hold while it
// waits and lets go with $.modkit.release (#2121); this is the one way every mod does both, so no
// mod writes its own and none forgets the letting go on a way out.
//
// It takes the hold, runs the wait, and lets go on every way out (returned, thrown, cancelled by a
// race the caller lost). A hold mod-kit refuses (not loaded, a copy without hold, a bad input) is
// no reason not to wait, so it is said in the debug log and the wait runs as before; a letting go
// refused is said too, and the hold lapses by itself at its time. It cannot be a member of mod-kit's
// noun: it must work when mod-kit's loaded copy is the older one. So each mod that waits keeps a
// copy of this file at hooks/mod-kit/held.ts, beside its copy of skew.ts, byte for byte, which
// tools/check-mod-shared-parts.sh holds to this one.
//
// The engine requires $ spelled in place at every call, so the caller hands its own hold, release
// and log, each a one line closure over its own $.

import { errorText } from './skew.ts'

/** mod-kit's ceiling on a hold, an hour: a wait with no deadline of its own asks for this. */
export const HOLD_MAX_MS = 60 * 60_000

/** One wait's hold: which mod, an id naming the wait, the wait as Dan would say it, how long at most. */
export type Held = {
  mod: string
  id: string
  /** The wait, as Dan would name it ("Dan's answer to the Ready picker"), read when a hold lapses. */
  what: string
  /** The longest the hold may stand, at most HOLD_MAX_MS: the wait's own deadline where it has one. */
  ms: number
  hold: (input: { mod: string; id: string; what: string; ms: number }) => Promise<void>
  release: (input: { mod: string; id: string }) => Promise<void>
  /** The debug log, where a refused hold or letting go is said. */
  log: (line: string) => void
}

const minutes = (ms: number) => {
  const n = Math.max(1, Math.ceil(ms / 60_000))
  return n === 1 ? '1 minute' : `${n} minutes`
}

// mod-kit keeps one hold per mod and id, so two waits of one id in flight at once (two Done presses,
// two Ready questions) would share one, and the first to finish would let go of the other's. So each
// wait in flight takes a number under its id, the lowest free, and a second one holds under the id
// with its number after it ("ask 2"). The number is given back when the wait ends, held or not.
const inFlight = new Map<string, Set<number>>()
const takeNumber = (key: string): number => {
  const taken = inFlight.get(key) ?? new Set<number>()
  inFlight.set(key, taken)
  let n = 1
  while (taken.has(n)) n++
  taken.add(n)
  return n
}
const giveBack = (key: string, n: number) => {
  const taken = inFlight.get(key)
  taken?.delete(n)
  if (taken?.size === 0) inFlight.delete(key)
}

/** Runs `wait` with mod-kit's reload of `h.mod` held back, and lets go on every way out. */
export const whileHeld = async <T>(h: Held, wait: () => Promise<T>): Promise<T> => {
  const key = `${h.mod}\n${h.id}`
  const n = takeNumber(key)
  const id = n === 1 ? h.id : `${h.id} ${n}`
  try {
    let held = false
    try {
      await h.hold({ mod: h.mod, id, what: h.what, ms: h.ms })
      held = true
    } catch (err) {
      h.log(`${h.mod}: could not hold back a reload while it waits on ${h.what}, so one now would drop that wait (${errorText(err, h.mod)})`)
    }
    try {
      return await wait()
    } finally {
      if (held) {
        try {
          await h.release({ mod: h.mod, id })
        } catch (err) {
          h.log(`${h.mod}: could not let go of its hold on a reload while it waited on ${h.what}; it lapses by itself within ${minutes(h.ms)} (${errorText(err, h.mod)})`)
        }
      }
    }
  } finally {
    giveBack(key, n)
  }
}
