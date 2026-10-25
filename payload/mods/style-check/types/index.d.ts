/** A count of this session's replies, for /style-count. */
export type StyleCheckCount = number
/** Whether this session's counts may be short. */
export type StyleCheckShort = boolean

declare module 'claude-code' {
  interface PluginState {
    /**
     * This session's counts for /style-count (#1703), in $.state, which the engine holds for the
     * session across a hot reload of the mod: a reload fires session.start again in a fresh module,
     * so a count kept in the module started again from nought while the session went on.
     */
    'style-check': {
      /** Replies this session carrying a dash or emoji. */
      hits: StyleCheckCount
      /** Replies this session the scanner could not check. */
      unchecked: StyleCheckCount
      /** Whether a reply this session could not be counted, so the counts may be short. */
      uncounted: StyleCheckShort
    }
  }
}
