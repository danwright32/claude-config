/**
 * How a finished step finished: found done before it was shown, checked by Claude after Done, taken
 * on Dan's word, or withdrawn by Claude as not doable now and taken off undone (#872).
 */
export type StepsFinish = 'already' | 'checked' | 'per-you' | 'withdrawn'

/** One manual step as the card holds it. */
export type StepsStep = {
  title: string
  /** The page the step is done on; a step has this or `location`. */
  url?: string
  /** Where the step is done when there is no page: the app, screen and section. */
  location?: string
  /**
   * What to do there: one action as a string, or several, in order, which the card numbers one per
   * line (#872). A card kept before #872 holds a string.
   */
  clicks?: string | string[]
  /** A value to paste, with Copy beside it. */
  value?: string
  /** Set once it is finished, and how. */
  finished?: StepsFinish
  /**
   * When it finished, in epoch milliseconds, so the card can say (#886). A step found done before it
   * was shown has none, and nor does one kept before #886.
   */
  finishedAt?: number
  /**
   * What this step needs from an earlier one, in a few words ("the password made in step 1"), drawn
   * under its title now that every step is open at once (#1239).
   */
  needs?: string
  /** Dan pressed its Done, so a verdict on it was asked for by the card, not taken from his words. */
  isPressed?: boolean
  /** Finished in an earlier session and carried into this one's card, so drawn grey with its age (#886). */
  isEarlier?: boolean
  /**
   * Added by another mod through the noun (#1107), not by Claude's steps tool, so a later pin, which
   * replaces the card, keeps it while it is unfinished.
   */
  isAdded?: boolean
  /**
   * For this session alone (#3770): never kept in the project's store, so it is not carried into the
   * next session, where the session it is about is gone.
   */
  isSessionOnly?: boolean
  /** Drawn with no Done (#3770): the step is done by an act that ends the session, so a press could only start a turn. */
  isNoDone?: boolean
  /**
   * The session that pinned it, by its id (#3770): set when the steps tool pins the step or another
   * mod adds it, and kept in the store, so a later session that carries the step in can tell it is
   * not its own. Pinned again by a later session after its check, a step keeps the session it had.
   * A step kept before this was recorded is given 'an earlier session' (card.ts EARLIER_SESSION) by
   * the session that carries it in at its own start, which knows only that it did not pin it. Absent
   * only on a step pinned before this was recorded in a session still running, or by a session whose
   * id could not be read: a reader treats that as not known, never as nobody's.
   */
  pinnedBy?: string
  /**
   * Done was pressed and "step N done" sent; Claude has not yet said whether it took. Never kept
   * in the store: the turn that would answer it does not reach another session.
   */
  isSent?: boolean
  /**
   * Done was pressed while a main turn ran (#2437): rather than a "step N done" queued behind the
   * turn, which a running turn never takes in, Claude is told on the turn's next tool result, and the
   * prompt is sent at the turn's end only if the step is still unrecorded. When it was pressed.
   * Never kept in the store, as isSent is not.
   */
  heldAt?: number
  /** When the note about a Done pressed mid turn rode on a tool result Claude read (#2437). */
  toldAt?: number
}

/**
 * The side pane's ids. Claude Code places a pane opened unasked from 144 columns, but from 110 for
 * an id the person once asked for (until they close it by hand), so the pane /steps opens never
 * shares the id a new card tries unasked (#708).
 */
export type StepsPaneId = 'steps' | 'steps-card'

/** The turn a "step N done" prompt started, so its end with no verdict brings Done back. */
export type StepsWaiting = { turnId: string; step: number }

/** The steps card: one per project, kept in $.store so unfinished steps carry over to the next session there. */
export type StepsCard = {
  heading: string
  steps: StepsStep[]
  /** Read from an earlier session and not yet re-checked by Claude in this one. */
  isCarried?: boolean
}

/**
 * That Claude's verdict (steps_done) finished the last open step of a card, so the card went
 * (#3864). Another mod reads it from this mod's state to act on a card worked through: the goal box
 * asks the session about its box. A step another mod finishes or takes off through the noun writes
 * none.
 */
export type StepsEmptied = {
  /** When, in epoch milliseconds, which tells one such moment from the next. */
  at: number
  /**
   * How many of the card's steps were done in this session, checked by Claude or taken on Dan's
   * word, and were this session's own or name no session. While this session's id cannot be read,
   * a step naming any session but an earlier one counts too. None when every step left was taken
   * off undone, was found done when pinned, or was another session's or another mod's.
   */
  done: number
}

/** A step another mod hands the card (#1107): the steps tool's own fields, a link or a location required. */
export type ManualStepsAdded = {
  title: string
  url?: string
  location?: string
  clicks?: string | string[]
  value?: string
  needs?: string
  /** For this session alone, never kept for the next (#3770). */
  sessionOnly?: boolean
  /** Drawn with no Done (#3770). */
  noDone?: boolean
}

/**
 * This mod's noun, for other mods (#1107). Each method is answered by this mod's own hook on its
 * event, which has the whole engine, so it reaches mod-kit to draw the card wherever the folders sort.
 */
export type ManualSteps = {
  /**
   * Adds one step to this project's card: at the end of the card pinned now, under its heading, or a
   * card of its own under `heading` when none is. A step already on the card unfinished, by its title,
   * is not added again. Shown as a new card is, never held while Dan is away: the caller decides when
   * to add. `isShown` false says why: nobody at the prompt, the card carried from an earlier session
   * and held, or the card could not be drawn. A step with no link or location throws, naming it.
   */
  add: (input: { heading: string; step: ManualStepsAdded }) => Promise<{ isShown: boolean; reason?: string }>
  /** Finishes the unfinished step titled `title` as checked, whichever step is open; false when there is none. */
  finish: (input: { title: string }) => Promise<{ isFinished: boolean }>
  /**
   * Takes the unfinished step titled `title` off as withdrawn (#3770), drawn "taken off, not done",
   * never as done; the card goes when nothing is left on it. False when there is none.
   */
  withdraw: (input: { title: string }) => Promise<{ isWithdrawn: boolean }>
}

/**
 * #1811: the pages of steps for Dan published since the last turn end, whether the steps tool was
 * called since then, and which pages the card shown now was pinned for, so publishing one of those
 * again while its card still shows asks nothing.
 */
export type StepsPages = {
  /** Pages of steps published since the last turn end, by the path each was published from. */
  turn: string[]
  /** The steps tool was called since the last turn end. */
  isPinned: boolean
  /** The pages the last refusal named, which the next card pinned covers. */
  owed: string[]
  /** The pages the card now shown was pinned for. */
  covered: string[]
}

declare module 'claude-code' {
  interface EngineInterface {
    manualSteps: ManualSteps
  }
  interface PluginState {
    /**
     * The card the pane and band draw from, where it is shown (the band, or the pane by its id),
     * and the turn a Done waits on; and the main turn running now, by its id, or null (#734, #1703).
     * In $.state so a reload keeps them. And the pages of steps published this turn (#1811), and
     * the last time Claude's verdict finished a card's last open step (#3864).
     */
    'manual-steps': { card: StepsCard | null; place: StepsPaneId | 'band' | null; waiting: StepsWaiting | null; runningTurn: string | null; pages: StepsPages | null; emptied: StepsEmptied | null }
  }
}
