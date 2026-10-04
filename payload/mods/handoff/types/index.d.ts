/** The handoff this session shows in the band, by the repository it belongs to and when it was saved. */
export type HandoffShown = { key: string; savedAt: number }

declare module 'claude-code' {
  interface PluginState {
    /**
     * In $.state so a reload of the mod keeps them: the handoff shown in the band (null when none),
     * and whether Dan ran /handoff in this session, which alone lets the save tool write one.
     */
    handoff: { shown: HandoffShown | null; armed: boolean }
  }
}
