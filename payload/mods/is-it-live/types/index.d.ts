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
  /** Where the message's Slack draft goes (#2435): the thread a Slack requester asked in, or a user id for a DM. */
  slack?: { channel_id?: string; thread_ts?: string; user_id?: string }
  /** The place (card.ts draftKeyOf) a card's answer last asked the session to save this message's draft to. */
  draftAsked?: string
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
      /**
       * #2436: the Slack threads this session started from, oldest first: each one Dan pasted a
       * link to, and the first one the main session read when it had none. Since #2578 also those
       * recorded once the session was under way, marked `mid`.
       */
      threads: IsItLiveThread[]
      /**
       * #2436: the order of this session's thread events, counted up by one for each merge learned
       * of and each draft saved, so which came first never rests on two clock readings.
       */
      step: number
      /** #2436: the step at which this session last learned a merge of its own landed. */
      landed: number
      /** #2436: the draft holds already refused in this chain of turn ends, and those let go and said, as `refused`. */
      draftRefused: { keys: string[]; told: string[] }
      /** #2578: how many prompts Dan has typed in this session, counted only as far as 2. */
      prompts: number
      /**
       * #2653: the session said, by calling the unrelated_merges tool, that its merges have nothing
       * to do with the threads it was given. Since #2849 no merge then owes the reply the most recent
       * thread is owed (`defaulted`), those already landed included. Only its presence is read; the
       * landed step it carried until #2849 is no longer kept.
       */
      unrelated: Record<string, never>
    }
  }
}

/**
 * A Slack thread a session started from (#2436): its channel and its parent message's time, the
 * link Dan pasted when he pasted one, how it was found, when (ms since the epoch), and the step at
 * which its last draft reply was saved (`settled`). In a session started from a thread, every merge
 * owes a reply in the thread pasted most recently before its work began (`defaulted`, #2849), or in
 * the threads it started from that its pull request links, until the session says its merges are
 * unrelated (`unrelated`, #2653). A merge whose pull request links a thread marked `mid` owes that
 * thread instead, recorded in `related` (#2578), and a card's message for a thread is owed whatever
 * was said. Every draft saved to the thread settles it, whichever prompt led to it, so the card's own
 * message for a requester in that thread (#2435) settles it too, with no second record.
 */
export type IsItLiveThread = {
  channel: string
  ts: string
  link?: string
  from: 'link' | 'read'
  at: number
  /** #2849: the step it was recorded at, the same for every link in one prompt; absent on a thread recorded before #2849. */
  step?: number
  settled?: number
  /** #2849: the step of the latest merge that owes it the session's reply by the most recent link, or by its pull request linking a thread the session started from. */
  defaulted?: number
  /**
   * #2578: recorded once the session was under way (after Dan's first prompt, or after a merge), so
   * only a merge for it owes it a reply, never every merge of the session.
   */
  mid?: true
  /** #2578: for a thread recorded mid session, the step of the latest merge for it, and those merges since its last draft. */
  related?: number
  prs?: string[]
  /**
   * #2630: the message an is it live card asked a draft of in this thread (its PR as owner/name#n,
   * the person, the words), until a draft saved to the thread settles it. The hold names it rather
   * than asking for a second reply, since it is the text Dan was shown.
   */
  card?: { pr: string; name: string; message: string }
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
  /** #2436: for a `waiting` merge, the background task Claude Code started for the helper, as its result named it. */
  task?: string
  /** #2466: for a `waiting` merge past its window, why whether its helper is still in line could not be read, once said. */
  unread?: string
}
