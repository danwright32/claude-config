/** How a finished step finished: found done before it was shown, checked by Claude after Done, or taken on Dan's word. */
export type StepsFinish = 'already' | 'checked' | 'per-you'

/** One manual step as the card holds it. */
export type StepsStep = {
  title: string
  /** The page the step is done on; a step has this or `location`. */
  url?: string
  /** Where the step is done when there is no page: the app, screen and section. */
  location?: string
  /** The exact click path on that page. */
  clicks?: string
  /** A value to paste, with Copy beside it. */
  value?: string
  /** Set once it is finished, and how. */
  finished?: StepsFinish
  /** Done was pressed and "step N done" sent; Claude has not yet said whether it took. */
  isSent?: boolean
}

/** The steps card: one per project, kept in $.store so unfinished steps carry over to the next session there. */
export type StepsCard = {
  heading: string
  steps: StepsStep[]
  /** Read from an earlier session and not yet re-checked by Claude in this one. */
  isCarried?: boolean
}

declare module 'claude-code' {
  interface PluginState {
    /** The card the pane and band draw from, and where it is shown. In $.state so a reload keeps them. */
    'manual-steps': { card: StepsCard | null; place: 'pane' | 'band' | null }
  }
}
