/** A mode that leads the amber line in bold while it is on (docs/mods-design.md, scope mode round): a scope mode, away, or ASLEEP while the Mac's sleep record holds (#840). */
export type StatusBarMode = 'ASLEEP' | 'NO BUILD' | 'WINDING DOWN' | 'AWAY'

/** Called from another mod (the scope modes mod, #616, and away and home, #621): await it. */
export type StatusBar = {
  /**
   * Sets the scope mode the amber line leads with, or clears it with null. While a mode is on the
   * band shows, even with nothing else in it. Rejects any other value, by name.
   */
  setMode: (input: { mode: StatusBarMode | null }) => Promise<void>
  /**
   * Sets every scope mode that is on at once, in the order the line shows them (no build or winding
   * down, and away, can both be on), or clears them all with an empty list. Rejects a value that is
   * not a mode, or one named twice, by name.
   */
  setModes: (input: { modes: StatusBarMode[] }) => Promise<void>
}

/** What this session's status line reads from the mod: one file per session, this Mac only. */
export type StatusBarFacts = {
  v: 1
  sessionId: string
  /**
   * When the prompt cache goes cold, in ms since the epoch: an hour after the last main request.
   * Null before any request, and again after a compaction or /clear replaces the conversation.
   */
  cacheExpiresAt: number | null
  /**
   * The account this session runs on, read from the Mac's login file at session start (#815): empty
   * with no claude.ai login, null when the file could not be read then. Absent in a file written
   * before #815, where the status line reads the login file as it stands.
   */
  account?: StatusBarAccount | null
}

/** The login file's oauthAccount fields the status line names an account by. */
export type StatusBarAccount = {
  accountUuid?: string
  organizationUuid?: string
  displayName?: string
  emailAddress?: string
  organizationName?: string
}

declare module 'claude-code' {
  interface EngineInterface {
    statusbar: StatusBar
  }
  interface PluginState {
    /** In $.state so a reload of the mod keeps them: the modes on, when the prompt cache goes cold, and the session's account. */
    'status-bar': { modes: StatusBarMode[]; cacheExpiresAt: number | null; account: StatusBarAccount | null }
  }
}
