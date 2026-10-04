/** A scope mode: what Claude may do (#616). One at a time; setting one replaces the other. */
export type ScopeModesScope = 'NO BUILD' | 'WINDING DOWN'
/** Where Dan is (#621): home delivers on the Mac as CLAUDE.md says, away publishes pages for the phone. */
export type ScopeModesPlace = 'home' | 'away'
/** One thing held while Dan was away: `label` is its row in the held card, `prompt` what Claude is asked to do when he presses it. */
export type ScopeModesHeld = { id: string; label: string; prompt: string }
/** What winding down is finishing, read when it turned on. */
export type ScopeModesTarget = { root: string; branch: string; isDefault: boolean; issues: number[]; pr: number | null }

/** Called from another mod (manual steps, #614, holds its items here while Dan is away): await it. */
export type ScopeModes = {
  /** Whether Dan is away, as this session knows it. */
  isAway: () => Promise<boolean>
  /**
   * Holds something that needs Dan at the Mac, for the held card when he is home again. Answers
   * whether it was held: false at home, where nothing is held and the caller goes ahead as usual.
   */
  hold: (input: { label: string; prompt: string }) => Promise<{ isHeld: boolean }>
}

declare module 'claude-code' {
  interface EngineInterface {
    scopeModes: ScopeModes
  }
  interface PluginState {
    /** In $.state, so a reload keeps them; a new session starts with none of them (home, no scope). */
    'scope-modes': {
      scope: ScopeModesScope | null
      place: ScopeModesPlace
      held: ScopeModesHeld[]
      /** The next held item's id, so a pressed one's id is never reused for another. */
      heldSeq: number
      /** What winding down finishes; null outside a repository; unreadable when the read failed, read again at the next check. */
      target: ScopeModesTarget | null | { unreadable: string }
      /** Set on coming home, cleared once Claude has been told on the next prompt. */
      justHome: boolean
    }
  }
}
