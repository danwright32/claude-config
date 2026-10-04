export type ModKitBlocked = {
  /** The blocked call's tool_use_id, from the tool.call input. */
  toolUseId: string
  /** The guard's name as Dan reads it, e.g. "Secret guard". */
  guard: string
  /** What was blocked, one plain sentence. */
  reason: string
  /** The safe way instead, drawn dim; optional. */
  safeWay?: string
}

/** Called from another mod, each method answers asynchronously: await it. */
export type ModKit = {
  /** Records that a guard blocked this call, so its result row is drawn as the grey card. */
  blocked: (input: ModKitBlocked) => Promise<void>
  /**
   * The simple commands a Bash call would run, each as its words with quotes removed: heredoc
   * bodies dropped, assignments and sudo/env/exec and the like looked past, a shell's -c read as
   * the commands it runs. The one reader every mod uses (L613).
   */
  commands: (input: { command: string }) => Promise<string[][]>
  /** One command's words read as git: its subcommand after git's global options, and -C's folder. Undefined when not git. */
  git: (input: { words: string[] }) => Promise<ModKitGit | undefined>
}

export type ModKitGit = { sub: string | undefined; args: string[]; dir: string | undefined }

declare module 'claude-code' {
  interface EngineInterface {
    modkit: ModKit
  }
}
