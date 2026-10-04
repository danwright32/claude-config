/** A merged change's card as kept in the store, one list per repository (`cards:<owner/name>`). */
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
