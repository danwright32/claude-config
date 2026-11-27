/** A Goal accomplished box shown in this session: what it was for, and when. */
export type GoalBoxShown = {
  /** `goal:<the met judgement's id>` for a /goal met, `request:<Dan's message count>` for a request finished. */
  key: string
  kind: 'goal' | 'request'
  /** When it was shown, ms since the epoch. */
  at: number
  /** How many messages Dan had typed in the session when it was shown: a second box needs a new one. */
  prompts: number
}

declare module 'claude-code' {
  interface PluginState {
    /** In $.state so a reload of the mod keeps them: the rules of once per accomplishment live here. */
    'goal-box': {
      /** Whether somebody is at the prompt: only then is the tool offered, or the session asked about a met goal or finished work. */
      interactive: boolean
      /** How many messages Dan has typed in this session (mod-kit's one reader of his own words). */
      prompts: number
      /** When Dan last typed a message in this session, ms since the epoch (#2523). */
      requestAt: number
      /** The value of `prompts` when the session was last asked whether its work was finished (#2523). */
      askedDone: number
      /** Every box shown in this session, oldest first. */
      shown: GoalBoxShown[]
      /** The met goals the session has already been told to show the box for, by judgement id. */
      asked: string[]
      /**
       * #3770: counts every turn start and every message of any origin, so a quiet period armed at a
       * turn's end knows a later one began.
       */
      closeSeq: number
      /** #3770: what the main conversation's last stop carried, under the closeSeq it came in. */
      closeStop: { seq: number; tasks: unknown; crons: unknown }
      /** #3770: the answer the last main turn ended with, under its closeSeq. */
      closeAnswer: { seq: number; text: unknown }
      /** #3770: the request (Dan's message count) the close card was last pinned for, and whether it still shows. */
      closed: { prompts: number; pinned: boolean }
      /** #3770: what a command this session ran did that may leave a process behind; once set, for the session. */
      leftBehind: string
    }
  }
}
