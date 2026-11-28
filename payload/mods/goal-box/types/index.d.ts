/** A Goal accomplished box shown in this session: what it was for, and when. */
export type GoalBoxShown = {
  /** `goal:<the met judgement's id>` for a /goal met, `request:<Dan's request count>` for a request finished. */
  key: string
  kind: 'goal' | 'request'
  /** When it was shown, ms since the epoch. */
  at: number
  /** How many requests Dan had made in the session when it was shown (`prompts` below): a second box needs a new one. */
  prompts: number
}

/**
 * #3843: an answer Dan gave in a picker that no work has followed yet, with why whether a later tool
 * call changed something could not be read, when it could not.
 */
export type GoalBoxPicker = { unread?: string }

declare module 'claude-code' {
  interface PluginState {
    /** In $.state so a reload of the mod keeps them: the rules of once per accomplishment live here. */
    'goal-box': {
      /** Whether somebody is at the prompt: only then is the tool offered, or the session asked about a met goal or finished work. */
      interactive: boolean
      /**
       * How many requests Dan has made in this session: each message he typed (mod-kit's one reader of
       * his own words), and since #3843 each answer he gave in a picker that the session then did work
       * after. The name is from when only messages counted; values an earlier build stored still fit.
       */
      prompts: number
      /** #3843: his answer in a picker that no work has followed yet; null once work followed or he typed. */
      picker: GoalBoxPicker | null
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
      /** #3770: the request (Dan's request count, `prompts` above) the close card was last pinned for, and whether it still shows. */
      closed: { prompts: number; pinned: boolean }
      /** #3770: what a command this session ran did that may leave a process behind; once set, for the session. */
      leftBehind: string
      /**
       * #3843: whether the turn under this closeSeq has had a main conversation call the end of turn
       * review's test counts, which makes its review still to come, or why that could not be read.
       */
      reviewWork: { seq: number; worked: boolean; unread?: string }
      /**
       * #3843: the request (`prompts` above) in which a box was last refused until the review was
       * answered; null once a message Dan typed has begun another request, which drops the hold.
       */
      reviewHeld: number | null
      /**
       * #3843: the value of `prompts` when the request's one message asking for such a box again
       * was last spent at a turn's end: sent, or given up because a review handed over that turn
       * was not answered.
       */
      reviewAsked: number
      /**
       * #3843: the request whose box is held for the review with no prompt asking for it sent yet: a
       * call was refused until the review was answered, or a prompt about the box was given up at a
       * turn's end over an unanswered review. Null once such a prompt was sent, or a message Dan
       * typed has moved it to `reviewOwed`.
       */
      reviewOwing: number | null
      /**
       * #3843: the earlier request whose held box was never shown when a message Dan typed began
       * another, to be asked for once at a later turn's end.
       */
      reviewOwed: { request: number } | null
      /**
       * #3843: a review found handed over and not answered at a turn's end of the main conversation
       * since Dan last typed a message. `now`: found at the latest end of the turn still current.
       * `earlier`: found at the end of a turn that has since passed. Null when neither, and once
       * he types.
       */
      reviewOpen: { earlier: boolean; now: boolean } | null
      /**
       * #3843: why the review's record could not be read at a turn's end of the main conversation
       * since Dan last typed a message; null when every reading since came back, and once he types.
       */
      reviewUnsure: string | null
      /** #3843: the request in which Dan was last told, in a line he sees, that the box waits on the review. */
      reviewTold: number
      /** #3843: the request whose box was shown over a reading of the review that failed, and what was said of it. */
      reviewUnread: { prompts: number; text: string }
    }
  }
}
