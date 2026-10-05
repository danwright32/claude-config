/**
 * A merged change's card as kept in the store, one list per repository (`cards:<owner/name>`, the
 * repository as GitHub's own link for the PR names it). The store key is in lowercase; the card's
 * `repo` keeps GitHub's own spelling.
 */
export type IsItLiveCard = {
  repo: string
  pr: number
  /** The pull request's own title and link, as GitHub gave them. */
  title: string
  url: string
  state: 'live' | 'deploying' | 'unconfirmed' | 'no-deploy'
  /** When the card was made, ms since the epoch. */
  at: number
  requester?: { name: string; via: 'issue' | 'slack' | 'named'; issue?: number }
  message?: string
  /** When Dan pressed Mark sent; absent while the message waits. */
  sentAt?: number
}

/** What the newest card for a merged PR says about its deploy (#687), and when it was made. */
export type IsItLiveVerdict = { state: IsItLiveCard['state']; at: number }

/** Read by other mods (scope-modes' wind down, #687): await it. */
export type IsItLive = {
  /**
   * The verdict of the newest card made in this session for `pr` in `repo` (owner/name, in any
   * case: GitHub's names are one name in any case), or null when no card has been made for it.
   * Throws on a repo that is not owner/name or a pr that is not a pull request number, so a
   * malformed question is never answered as no card.
   */
  verdict: (q: { repo: string; pr: number }) => Promise<IsItLiveVerdict | null>
}

declare module 'claude-code' {
  interface EngineInterface {
    isItLive: IsItLive
  }
  interface PluginState {
    /** Session state rather than the store: its ref names this plugin, so any mod's read finds it. */
    'is-it-live': {
      /**
       * Each card's verdict this session, keyed `owner/name#pr` with the repository as GitHub's own
       * link for the PR names it, in lowercase; the newest card's winning.
       */
      verdicts: Record<string, IsItLiveVerdict>
    }
  }
}
