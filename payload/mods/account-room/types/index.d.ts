/** Who this session runs as, captured once at session start (L175), and where its files are. */
export type AccountRoomSession = {
  /** The account's key: a hash of its account and org ids, never the ids themselves. */
  id: string
  email: string
  org: string
  /** Whether the session has a screen: only then is the band drawn or a nickname asked. */
  isInteractive: boolean
  home: string
  /** This Mac's name for its readings file (LocalHostName), or null when it could not be read. */
  mac: string | null
}

/** One limit as read: how much is used (0 to 100) and when it resets, in ms; null when not said. */
export type AccountRoomLimit = {
  used: number
  resetsAt: number | null
  /** When this window was read, when that differs from its reading's own time (carried over from an earlier one). */
  takenAt?: number
}
export type AccountRoomReading = { takenAt: number; five?: AccountRoomLimit; week?: AccountRoomLimit }

/**
 * Why a Switch stopped before its sign in page, as measured (#736): no logout route was set up, so
 * nothing was attempted; the logout command failed or could not be run; the signed out check could
 * not be run; the check ran and did not print "signed out"; or a reload cut the run off.
 */
export type AccountRoomStop = 'no-route' | 'logout-failed' | 'check-not-run' | 'not-confirmed' | 'interrupted'

/**
 * What Switch is doing: nothing, a step under way since a moment, or stopped at the sign out. A
 * stop stored by a build before #736 has no cause; that build only ever said "not confirmed".
 */
export type AccountRoomPhase = { kind: 'idle' } | { kind: 'working'; step: 'logout' | 'login'; since: number } | { kind: 'failed'; cause?: AccountRoomStop }

/** The nickname dialog's account, while it is open. */
export type AccountRoomAsking = { id: string; email: string; org: string; current: string | null }

declare module 'claude-code' {
  interface PluginState {
    /** In $.state so a reload of the mod keeps them for the rest of the session. */
    'account-room': {
      session: AccountRoomSession | null
      /** This session's latest reading of its own account. */
      live: AccountRoomReading | null
      phase: AccountRoomPhase
      /** Dismiss hides the card for this session only (the spec). */
      isDismissed: boolean
      asking: AccountRoomAsking | null
      /** What has been typed into the nickname field so far. */
      typed: string
    }
  }
}
