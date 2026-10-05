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

declare module 'claude-code' {
  interface EngineInterface {
    jobs: Jobs
  }
}
