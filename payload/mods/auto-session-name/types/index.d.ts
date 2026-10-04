/**
 * What the auto session name mod keeps about the session it runs in, held in `$.state` so a hot
 * reload of the mod (which fires `session.start` again) finds it and never names twice (#635).
 */
export type AutoSessionNameRecord = {
  /** The session this record is about; a record for any other id is treated as absent. */
  sessionId: string
  /** When this mod first saw the session start; the 10 minutes count from here, across reloads. */
  startedAt: number
  /** Whether a person is at the prompt. Null until `session.start` says. */
  isInteractive: boolean | null
  /**
   * Where naming stands. `waiting`: not yet named. `named`: this mod set the name. `left`: the
   * session already had a name, or Dan renamed it, so it is left alone. `gave-up`: two failures.
   */
  outcome: 'waiting' | 'named' | 'left' | 'gave-up'
  /** Failed attempts so far: 0, 1 or 2. One failure earns exactly one retry at the next idle point. */
  failures: number
  /**
   * Set once the 10 minutes have passed. From then on the end of each main turn (an idle point) may
   * name it: the first exchange when nothing was asked by then, and the one retry after a failure.
   */
  isDue: boolean
  /** The newest session name Claude Code reported (`session_title`), empty when none. */
  knownTitle: string
  /** Set when Dan ran /rename himself (seen by the `command.run` hook). */
  isRenamedByHand: boolean
  /**
   * A name made but not confirmed as set, applied as `sessionTitle` on Dan's next message unless
   * that message shows it already took (the fallback route).
   */
  pendingTitle: string | null
  /**
   * The attempt that holds the work, so a second caller stands down: its own id, and when it claimed
   * it (a claim older than a few minutes belongs to an attempt a reload cut off, and is taken over).
   */
  claim: { id: string; at: number } | null
}

declare module 'claude-code' {
  interface PluginState {
    'auto-session-name': { record: AutoSessionNameRecord | null }
  }
}
