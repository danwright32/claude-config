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
   * Done was pressed and "step N done" sent; Claude has not yet said whether it took. Never kept
   * in the store: the turn that would answer it does not reach another session.
   */
  isSent?: boolean
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

/** A step another mod hands the card (#1107): the steps tool's own fields, a link or a location required. */
export type ManualStepsAdded = { title: string; url?: string; location?: string; clicks?: string | string[]; value?: string }

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
}

declare module 'claude-code' {
  interface EngineInterface {
    manualSteps: ManualSteps
  }
  interface PluginState {
    /**
     * The card the pane and band draw from, where it is shown (the band, or the pane by its id),
     * and the turn a Done waits on. In $.state so a reload keeps them.
     */
    'manual-steps': { card: StepsCard | null; place: StepsPaneId | 'band' | null; waiting: StepsWaiting | null }
  }
}
