/** A scope mode: what Claude may do (#616). One at a time; setting one replaces the other. */
export type ScopeModesScope = 'NO BUILD' | 'WINDING DOWN'
/** Where Dan is (#621): home delivers on the Mac as CLAUDE.md says, away publishes pages for the phone. */
export type ScopeModesPlace = 'home' | 'away'
/** One thing held while Dan was away: `label` is its row in the held card, `prompt` what Claude is asked to do when he presses it. */
export type ScopeModesHeld = { id: string; label: string; prompt: string }
/**
 * What winding down is finishing, read when it turned on: the branch the session is on, the issue
 * numbers its name carries, and once found, its PR and the issues that PR closes. `main` is the
 * project's main working tree and `repo` the owner/name of its origin, as the session's repository
 * gave them when winding down turned on: where the check reads once the session's own folder (a
 * worktree winding down removes when it cleans up) is gone (#1059). Absent when they could not be read.
 */
export type ScopeModesTarget = { root: string; branch: string; isDefault: boolean; issues: number[]; pr: number | null; closes?: number[]; main?: string; repo?: string }
/** A PR this session opened (a `gh pr create` by the session or any of its agents), in the repository its link names. */
export type ScopeModesOpened = { repo: string; number: number; closes?: number[] }
/**
 * A PR Dan himself chose to leave open (#917), from his answer to leave_pr_open: the repository and
 * number, the head commit it was on when he answered (a new push asks again), and why, as asked.
 */
export type ScopeModesLeftOpen = { repo: string; number: number; head: string; why: string }
/**
 * A PR closed without merging that Dan himself chose to leave closed (#1033), from his answer to
 * leave_pr_open: the repository and number, and why, as asked. It carries no head: a closed PR
 * merges nothing until it is reopened, and reopened it is open, which this answer never covers.
 */
export type ScopeModesLeftClosed = { repo: string; number: number; closed: true; why: string }
/** Dan's own answer about one PR, open or closed, found by its repository and number; one per PR. */
export type ScopeModesLeftAsIs = ScopeModesLeftOpen | ScopeModesLeftClosed

/** Called from another mod (manual steps, #614, holds its items here while Dan is away): await it. */
export type ScopeModes = {
  /** Whether Dan is away, as this session knows it. */
  isAway: () => Promise<boolean>
  /**
   * Holds something that needs Dan at the Mac, for the held card when he is home again. Answers
   * whether it was held: false at home, where nothing is held and the caller goes ahead as usual.
   * Held, it also gives the refusal worded as this mod's own held calls are, for a guard holding a
   * tool call (the keystroke guard, #707): `card` to draw with `$.modkit.blocked` under the call's
   * id, and `deny` for Claude to read.
   */
  hold: (input: { label: string; prompt: string }) => Promise<ScopeModesHold>
  /**
   * Whether the Mac is asleep (sleep mode, #840), read from the sleep record now through the one
   * predicate, readSleep. A record that cannot be read, or past its end, is awake. For a mod that
   * would otherwise reach Dan (a notification, a question) and stays quiet while this is true (#841).
   */
  isAsleep: () => Promise<boolean>
  /**
   * Notes something for Dan's morning report while asleep (#841), in the night's notes beside the
   * record, stamped with when and by which session. Answers whether it was noted: false while awake,
   * when nothing is written. Throws when the note could not be written, so the caller can say so.
   */
  sleepNote: (note: { kind: string } & Record<string, unknown>) => Promise<{ isNoted: boolean }>
}

/** What `hold` answers: not held (at home), or held with the refusal a held tool call is answered with. */
export type ScopeModesHold = { isHeld: false } | { isHeld: true; card: { guard: string; reason: string; safeWay: string }; deny: string }

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
      /** The PRs this session opened, which winding down finishes when the session's own branch has none (#702). */
      opened: ScopeModesOpened[]
      /**
       * The PRs Dan chose to leave as they are: open (#917), settled at that head, or closed without
       * merging (#1033), settled while closed. The key keeps its first name, so an answer recorded
       * before #1033 still reads.
       */
      leftOpen: ScopeModesLeftAsIs[]
      /** Set on coming home, cleared once Claude has been told on the next prompt. */
      justHome: boolean
    }
  }
}
