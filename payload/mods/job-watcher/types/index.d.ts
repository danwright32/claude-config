/** One background job this session is running, as the status bar (#610) shows it. */
export type JobsEntry = {
  /** A short name: the name Claude gave a kept job ("dev server"), else its command cut short. */
  label: string
  /** How long it has run, in milliseconds, at the moment the list was read. */
  runMs: number
  /** Claude kept it on purpose, with a reason. */
  kept: boolean
  /** The watcher measured it as stalled: the same output over and over, or silent past ten minutes. */
  stuck: boolean
  /**
   * What the watcher last measured (#784): running; waiting, a poll loop quiet or repeating a line
   * that is no error, which waits on something outside (a queued CI run); stalled, as `stuck`.
   */
  state: 'running' | 'waiting' | 'stalled'
  /** The background agent whose job it is, by its task's description; null for this conversation's own. */
  owner: string | null
  /** That agent's id, so two agents given the same description stay apart; null for this conversation's own. */
  ownerId: string | null
  /** #1583: how a stalled job stalled (no new output, or the same output over and over); null while it is not stalled. */
  stall: 'silent' | 'repeating' | null
  /** How long a silent stalled job has printed nothing, in milliseconds, as of the read; null otherwise. */
  quietMs: number | null
}

/** A background agent listed as running whose tool calls have stopped for twenty minutes (#759). */
export type QuietAgent = {
  /** Its task's description, as the Agent call gave it. */
  name: string
  /** How long since a tool call of its last started or finished, in milliseconds. */
  quietMs: number
}

/** Called from another mod: await it. It refuses, never answers, when the clock cannot be read. */
export type Jobs = {
  /** This session's running jobs, oldest first. */
  list: () => Promise<JobsEntry[]>
  /** The running background agents gone quiet; refuses when the agent list cannot be read. */
  agents: () => Promise<QuietAgent[]>
}

/** Claude kept the job on purpose, with a reason (Dan, 2026-10-04). quiet: never reported for going silent. */
export type WatchedJobKept = { name: string; reason: string; quiet: boolean; at: number }
/**
 * One background job on the watcher's record. pgid: its process group, traced through its output
 * file, or null while untraced. owner: the background agent whose loop started it, absent for this
 * conversation's own.
 */
export type WatchedJob = {
  id: string
  command: string
  outputPath: string
  pgid: number | null
  startedAt: number
  kept?: WatchedJobKept
  owner?: { id: string; name: string }
}

/** Something the watcher will tell Claude, addressed to a background agent's loop by its id, or to this conversation without one. wake: start a turn of this idle conversation to say it (#1234). */
export type WatcherNotice = { to?: string; text: string; wake?: true }
/** A background agent's last sign of life (#759): when a tool call of its last started or finished, the last one it started and when, how many are still running, and whether its quiet spell was said. */
export type AgentSeen = { at: number; lastTool?: string; startedAt?: number; inFlight: number; told: boolean }
/**
 * What the watcher last measured of one job (#706, #784, #1517, #1583): its output's size (null
 * before the first look) and when it last changed, its state, whether Claude was told of the spell
 * it is in and since when it has been healthy, the once told flags, what Claude Code last said of
 * it, what its processes measured and how it stalled.
 */
export type JobWatch = {
  lastSize: number | null
  lastGrowth: number
  state: 'running' | 'waiting' | 'stalled'
  told: boolean
  healthySince?: number
  toldUnreadable: boolean
  toldUntraced: boolean
  toldLookFailed: boolean
  harness?: string
  measured?: 'runs' | 'unknown'
  stalledBy?: 'silent' | 'repeating'
}
declare module 'claude-code' {
  interface EngineInterface {
    jobs: Jobs
  }
  interface PluginState {
    /**
     * The watcher's session facts (#1695, #1703), each in $.state, which the engine holds for the
     * session across a hot reload of the mod: a reload runs the code again in a fresh module and
     * fires session.start again, so none of these may live in a module variable.
     */
    'job-watcher': {
      /** The one list of this session's background jobs (#1695), the reminder's, the keep tool's and the status bar's. */
      jobs: WatchedJob[]
      /** Which agent started each piece of background work, by the task id Claude Code lists it under (#1326). */
      startedBy: Record<string, string>
      /** How many times running each agent's stop has been refused, by agent id (#1326). */
      stopRefusals: Record<string, number>
      /** What Claude has still to be told, oldest first. */
      notices: WatcherNotice[]
      /** Each agent whose loop has not ended, with its last sign of life, by agent id (#759). */
      agents: Record<string, AgentSeen>
      /** Whether this conversation's own loop has a turn running (#1234). */
      mainTurn: 'idle' | 'busy'
      /** What the watcher last measured of each job on the list, by job id. */
      watch: Record<string, JobWatch>
    }
  }
}
