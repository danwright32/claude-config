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
  /** The ${...} placeholders the added text writes as text rather than fills, which the message shown to Dan may carry (#2361). */
  literal?: string[]
  /** A subagent's call, told to stop and report rather than ask. */
  agent?: true
}

/** Dan's approval of one exact wording (or one removal, or one shell call), kept in the mod's store. */
export type SlackAlertApproval = { at: number; file: string; text: string[]; rendered: string }

/**
 * Wording a session chose while Dan was asleep (#2628), kept in the mod's store under `chosen:<key>`
 * for each store key his approval would be kept under. Never an approval: no pull request carrying it
 * may merge until he answers Approve wording in the morning picker.
 */
export type SlackAlertChoice = {
  /** The held call's id, which the morning question's `metadata.source` names. */
  id: string
  at: number
  file: string
  added: string[]
  removed: string[]
  keys: string[]
  /** The message as Slack would post it, as the session chose it. */
  rendered: string
  /** The session that asks Dan in the morning; null once that session has ended, when any session asks. */
  session: string | null
  /** When it expired unanswered: still held, said once in every session. */
  expired?: number
  /**
   * Where it holds merges (#2833): the file it was chosen in, then each file in another place its
   * wording was let through while Dan was asleep, with the GitHub repository each is in as owner/name
   * in lower case, null where that could not be read (read again at a merge). Absent on a choice
   * made before #2833, read from `file` at a merge.
   */
  places?: SlackAlertPlace[]
}

export type SlackAlertPlace = { file: string; repo: string | null }

declare module 'claude-code' {
  interface PluginState {
    /** The calls waiting on Dan's approval, by the refused call's id; dropped at session end. */
    'slack-alert-guard': { pending: SlackAlertPending[]; told: string[] }
  }
}
