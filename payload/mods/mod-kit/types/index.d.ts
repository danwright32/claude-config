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

export type ModKit = {
  /** Records that a guard blocked this call, so its result row is drawn as the grey card. */
  blocked: (input: ModKitBlocked) => void
}

declare module 'claude-code' {
  interface EngineInterface {
    modkit: ModKit
  }
}
