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

declare module 'claude-code' {
  interface EngineInterface {
    goalTracker: GoalTracker
  }
}
