// Whether a main turn is running now, the one reader every mod that asks keeps (#2461, #2437).
//
// A mod's $.prompt.submit and $.command.run wait until the session is idle: Claude Code queues them
// at the lowest priority, and a running turn takes in only its own priority's entries at each tool
// call, never a slash command (measured on Claude Code 2.1.319, 2026-11-08). So a mod that would
// reach a running turn must know a turn is running, and say what it has to say another way: a note
// on the next tool result it reads (a tool.call hook's `context`), which the same measurement saw
// reach the very next request of the running turn.
//
// What this module saw decides while it holds anything; a write of that to $.state that fails
// (said in the debug log, never failing the turn event it rides on) then strands nothing here. A
// fresh module after a reload reads $.state alone, so a reload in the middle of a turn still reads
// it as running (#1703). Only the main loop raises turn.start; a subagent's turn is never one.
//
// It cannot be a member of mod-kit's noun: it must work when mod-kit's loaded copy is the older
// one, and each mod keeps its own record. So each mod that asks keeps a copy of this file at
// hooks/mod-kit/turnnow.ts, byte for byte, which tools/check-mod-shared-parts.sh holds to this one.
// The engine requires $ spelled in place at every call, so the caller hands its own store, each a
// one line closure over its own $ and its own $.state key.

/** Where a mod keeps the running turn's id across a reload, and its debug log. */
export type TurnStore = {
  get: () => Promise<string | null | undefined>
  set: (turnId: string | null) => Promise<void>
  log: (line: string) => void
}

export type TurnNow = {
  /** A main turn started (turn.start): its id, kept. */
  started: (store: TurnStore, turnId: string) => Promise<void>
  /** The main turn ended (turn.complete with no agentId). */
  ended: (store: TurnStore) => Promise<void>
  /** The main turn running now, or null when none is. A $.state that cannot be read throws. */
  running: (store: TurnStore) => Promise<string | null>
  /** Forget what this module saw, so $.state decides, as in a fresh module (session.start). */
  forget: () => void
}

const why = (err: unknown) => (err instanceof Error ? err.message : String(err))

/** One mod's reader of the running turn, named by the mod for its debug lines. */
export const turnNow = (mod: string): TurnNow => {
  let seen: { id: string | null } | undefined
  const keep = async (store: TurnStore, turnId: string | null) => {
    seen = { id: turnId }
    try {
      await store.set(turnId)
    } catch (err) {
      store.log(`${mod}: could not record that the main turn ${turnId === null ? 'ended' : 'started'}: ${why(err)}`)
    }
  }
  return {
    started: (store, turnId) => keep(store, turnId),
    ended: store => keep(store, null),
    running: async store => (seen !== undefined ? seen.id : ((await store.get()) ?? null)),
    forget: () => {
      seen = undefined
    },
  }
}
