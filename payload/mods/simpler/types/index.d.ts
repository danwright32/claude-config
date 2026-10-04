/** What the latest answer is, when it earned the Simpler button; null once Dan types or a newer answer did not. */
export type SimplerOffer = {
  /** The answer's opening, whitespace collapsed, so the reply block drawn can be matched to it. */
  head: string
  /** The kind of answer, from the one list in hooks/simpler.ts (KINDS). */
  kind: string
  /** Why it earned the button: over the length threshold, or heavy in technical terms. */
  reason: 'long' | 'technical'
  /** Its length in words. */
  words: number
}

declare module 'claude-code' {
  interface PluginState {
    simpler: {
      offer: SimplerOffer | null
      /** The session's project, its folder's name, for the example the request asks for. */
      project: string | null
    }
  }
}
