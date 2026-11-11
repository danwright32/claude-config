/** An edit or shell call refused until Dan approves the Slack message it changes (#2242). */
export type SlackAlertPending = {
  /** The refused call's tool_use_id, which the dialog's `metadata.source` names. */
  id: string
  /** The tool the refused call used. */
  tool: string
  /** The file it changes, or the command it runs. */
  file: string
  /** Message text the call adds that Dan has not approved, each exactly as written. */
  added: string[]
  /** Message text it takes away. */
  removed: string[]
  /** The store keys Dan's Approve wording records: one per added string, or the call's own for a removal or a shell call. */
  keys: string[]
  /** For a template another file sends to Slack (#2248): that file, named on the card and refusal. */
  sender?: string
  /** The ${...} placeholders the added text writes as text rather than fills, which the message shown to Dan may carry (#2361). */
  literal?: string[]
  /** For wording the edit adds none of and brings to a Slack send from the files it imports (#2637): those files, named on the card, refusal and question. */
  from?: string
  /** For a module of message copy no file uses yet (#2720): named as one on the card, refusal and question. */
  unwired?: true
  /** A subagent's call, told to stop and report rather than ask. */
  agent?: true
}

/** Dan's approval of one exact wording (or one removal, or one shell call), kept in the mod's store. */
export type SlackAlertApproval = { at: number; file: string; text: string[]; rendered: string }

declare module 'claude-code' {
  interface PluginState {
    /** The calls waiting on Dan's approval, by the refused call's id; dropped at session end. */
    'slack-alert-guard': { pending: SlackAlertPending[] }
  }
}
