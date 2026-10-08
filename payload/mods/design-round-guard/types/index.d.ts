/** One thing a design round is settled or skipped for: an issue, or a branch naming none (#978). */
export type DesignRoundSubject = {
  /** Where Dan's answer is kept in the mod's store: the project's main working tree, then the issue or branch. */
  key: string
  /** How Dan and Claude read it: "issue #978 in claude-config". */
  label: string
}

/** A look changing edit refused until Dan answers "Skip design rounds for this issue?" or settles a round (#978). */
export type DesignRoundPending = {
  /** The refused call's tool_use_id, which the dialog's `metadata.source` names. */
  id: string
  /** The tool the refused call used. */
  tool: string
  /** The files it would change how they look, as Dan reads them. */
  files: string[]
  /** What has no settled round and no skip yet; Dan's Skip them answers every one. */
  subjects: DesignRoundSubject[]
  /** Set when a subagent's call was refused: the agent is told to make the change again, not the main loop. */
  agent?: true
}

/** Dan's own answer, kept in the mod's store under its subject's key (this Mac, every session). */
export type DesignRoundRecord = {
  /** settled: his Settled to "Is this design settled?". skipped: his Skip them to "Skip design rounds for this issue?". */
  kind: 'settled' | 'skipped'
  /** When he answered, in milliseconds since the epoch, as $.clock.now() reads. */
  at: number
  /** The subject as the question he answered named it. */
  label: string
}

declare module 'claude-code' {
  interface PluginState {
    /** The look changing edits waiting on Dan's answer, by the refused call's id; dropped at session end. */
    'design-round-guard': { pending: DesignRoundPending[] }
  }
}
