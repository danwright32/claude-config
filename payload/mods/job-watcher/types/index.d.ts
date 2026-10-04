/** One background job this session is running, as the status bar (#610) shows it. */
export type JobsEntry = {
  /** A short name: the name Claude gave a kept job ("dev server"), else its command cut short. */
  label: string
  /** How long it has run, in milliseconds, at the moment the list was read. */
  runMs: number
  /** Claude kept it on purpose, with a reason. */
  kept: boolean
  /** The watcher measured it as stuck: repeating one line, or silent past ten minutes. */
  stuck: boolean
}

/** Called from another mod: await it. It refuses, never answers, when the clock cannot be read. */
export type Jobs = {
  /** This session's running jobs, oldest first. */
  list: () => Promise<JobsEntry[]>
}

declare module 'claude-code' {
  interface EngineInterface {
    jobs: Jobs
  }
}
