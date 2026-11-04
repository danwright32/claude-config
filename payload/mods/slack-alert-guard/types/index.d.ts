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
