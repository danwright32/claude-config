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
      /** The folder the session started in, where Claude Code files its transcript by its id (#2898). */
      startCwd: string
    }
  }
}
