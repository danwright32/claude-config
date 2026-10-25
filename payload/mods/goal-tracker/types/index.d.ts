/** What `waitingOnYou` answers: sent, or why not (the Mac asleep, or the notifier's own reason). */
export type GoalTrackerNotified = { isSent: true } | { isSent: false; reason: string }

/**
 * This mod's noun, for other mods (#1245). Answered by this mod's own hook on its event, which has
 * the whole engine, so it reaches scope modes' sleep check wherever the folders sort.
 */
export type GoalTracker = {
  /**
   * Tells Dan, with the macOS notification a question sends, that this session waits on him:
   * titled "<project> is waiting on you", `message` its body. Sends nothing while the Mac is asleep
   * (sleep mode, #841) and says so. Await it: it answers once terminal-notifier has.
   */
  waitingOnYou: (input: { message: string }) => Promise<GoalTrackerNotified>
}

/** A step's status, as the task tools and TodoWrite give it. */
export type GoalTrackerStepStatus = 'pending' | 'in_progress' | 'completed'
/** One step of the session's task list. */
export type GoalTrackerStep = { id: string; subject: string; activeForm?: string; status: GoalTrackerStepStatus }
/** One session's task list and its state (#612), as the registry and the /goals pane read it. */
export type GoalTrackerProgress = {
  steps: GoalTrackerStep[]
  done: number
  total: number
  /** The step under way, as Claude Code's spinner names it. */
  current: string | null
  startedAt: number
  /** When a step last finished. */
  lastStepAt: number
  /** When anything last happened: a step, or any tool call. */
  lastActivityAt: number
  /**
   * Set while the session waits on Dan: a question (its text), or a permission prompt (what the
   * permission is for, in `question`).
   */
  waiting?: { question: string; since: number; kind?: 'question' | 'permission' }
  failed?: string
  /** The /goal condition, while one is set (Dan, 2026-10-04: the pane's goal text). */
  goal?: string
  /** The session's first request, cut to a few words: the goal text when no /goal is set. */
  request?: string
}

/** How many tool calls in a row have failed or been refused, nothing succeeding between. */
export type GoalTrackerStreak = number

declare module 'claude-code' {
  interface EngineInterface {
    goalTracker: GoalTracker
  }
  interface PluginState {
    /**
     * This conversation's progress (#1703), in $.state, which the engine holds for the session across
     * a hot reload of the mod: a reload fires session.start again in a fresh module, and a list kept
     * only in the module was written over with an empty one. Null once a /clear has begun a new
     * conversation and before it records anything.
     */
    'goal-tracker': { progress: GoalTrackerProgress | null; streak: GoalTrackerStreak }
  }
}
