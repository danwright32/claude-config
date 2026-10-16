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
      /** The merges this session still owes a card (#1244), oldest first. */
      owed: IsItLiveOwed[]
      /** Whether the session has somebody at its prompt, from session.start (#1244). */
      interactive: boolean
      /**
       * The owed merges a turn end has already been refused for in the current chain of turn ends,
       * and those whose letting go has been said (#1244): each is refused once per chain.
       */
      refused: { keys: string[]; told: string[] }
    }
  }
}

/**
 * A merge this session made that still owes its card (#1244). `merged` GitHub confirmed just after
 * the command; `unproven` the command did not fail but GitHub could not confirm it (`why`); `waiting`
 * a merge the helper makes in the background, asked of GitHub again at each turn end and owed only
 * once GitHub says it merged. `repo` is owner/name as GitHub's link names it, absent where it could
 * not be read; `selector`, `named` and `cwd` are what GitHub is asked again with; `at` is when the
 * command ran, ms since the epoch, and a card made at or after it settles the merge.
 */
export type IsItLiveOwed = {
  key: string
  how: 'merged' | 'unproven' | 'waiting'
  pr: number
  at: number
  cwd: string
  repo?: string
  selector?: string
  named?: string
  why?: string
}
