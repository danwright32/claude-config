/** A scope mode, which leads the amber line in bold while it is on (docs/mods-design.md, scope mode round). */
export type StatusBarMode = 'NO BUILD' | 'WINDING DOWN' | 'AWAY'

/** Called from another mod (the scope modes mod, #616, and away and home, #621): await it. */
export type StatusBar = {
  /**
   * Sets the scope mode the amber line leads with, or clears it with null. While a mode is on the
   * band shows, even with nothing else in it. Rejects any other value, by name.
   */
  setMode: (input: { mode: StatusBarMode | null }) => Promise<void>
}

/** What this session's status line reads from the mod: one file per session, this Mac only. */
export type StatusBarFacts = {
  v: 1
  sessionId: string
  /** When the prompt cache goes cold, in ms since the epoch: an hour after the last main turn ended. Null before any. */
  cacheExpiresAt: number | null
}

declare module 'claude-code' {
  interface EngineInterface {
    statusbar: StatusBar
  }
  interface PluginState {
    /** In $.state so a reload of the mod keeps them: the mode, and when the prompt cache goes cold. */
    'status-bar': { mode: StatusBarMode | null; cacheExpiresAt: number | null }
  }
}
