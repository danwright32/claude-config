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
  /** The send the held text reaches, or why that could not be traced (#2586). None for a shell command. */
  send?: SlackAlertSend
}

/**
 * Where held text goes (#2586): the file's own send calls it reaches, each by what it calls and its
 * line, or the reason no send could be traced, when the guard held all the file's new wording.
 */
export type SlackAlertSend = { sends: { callee: string; line: number }[] } | { untraced: string }

/** Dan's approval of one exact wording (or one removal, or one shell call), kept in the mod's store. */
export type SlackAlertApproval = { at: number; file: string; text: string[]; rendered: string }

/**
 * Wording a session chose while Dan was asleep (#2628), kept in the mod's store under `chosen:<key>`
 * for each store key his approval would be kept under. Never an approval: only his Approve wording in
 * the morning picker records one. It holds no merge (#3030).
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
  /**
   * The session that asks Dan in the morning; null once that session has ended, when a session in
   * a repository it holds asks (#2833), or any session when that repository cannot be read.
   */
  session: string | null
  /** When it expired unanswered: still unapproved, said once in each session that may ask it (#2833). */
  expired?: number
  /**
   * When Dan answered Change wording to it: still unapproved, and never put to him again by a session
   * that did not make it (#2993); the session that made it asks as before.
   */
  rejected?: number
  /**
   * Where it is put to Dan from (#2833): the file it was chosen in, then each file in another place its
   * wording was let through while Dan was asleep, with the GitHub repository each is in as owner/name
   * in lower case, null where that could not be read (read again when asked). Absent on a choice
   * made before #2833, read from `file`.
   */
  places?: SlackAlertPlace[]
}

export type SlackAlertPlace = { file: string; repo: string | null }

declare module 'claude-code' {
  interface PluginState {
    /**
     * The calls waiting on Dan's approval, by the refused call's id; dropped at session end.
     * `reasked`: the choices put to Dan again two hours after sleep ended (#2993), each once, with the session that asked.
     */
    'slack-alert-guard': { pending: SlackAlertPending[]; told: string[]; reasked: { session: string; ids: string[] } }
  }
}
