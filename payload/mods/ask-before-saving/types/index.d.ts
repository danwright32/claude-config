/** A save to lasting memory waiting on Dan's answer in the band. */
export type AskBeforeSavingQuestion = {
  /** The refused call's tool_use_id. */
  id: string
  /** The tool and its arguments as Claude sent them, which For good asks Claude to send again. */
  tool: 'Write' | 'Edit' | 'Bash'
  input: Record<string, unknown>
  /** Where it would go, as Dan reads it (home as ~). */
  files: string[]
  /** What would be saved: the new lines of a Write, an Edit's new text, a Bash command as written. */
  text: string
  /**
   * What the save writes (rules.ts saveKey), taken where Dan is asked, so For good approves the file
   * he was shown however the session moves before he answers. Absent on a question stored before
   * #738's review, which For good keys where it is answered.
   */
  key?: string
}

/** A save Dan answered For good, waiting for Claude to send the call again (#738). */
export type AskBeforeSavingApproval = {
  /** The question's id. */
  id: string
  /** What the save writes (rules.ts saveKey): the call that matches it goes through, once. */
  key: string
  /** Where it goes, as Dan reads it. */
  files: string[]
  /** When it lapses, in milliseconds since the epoch, as $.clock.now() reads. */
  until: number
  /** How Claude was asked: a note read at its next step, or a prompt of its own. */
  told: 'note' | 'prompt'
  /** What Claude was asked, sent again as a prompt when a note went unread. */
  text: string
}

declare module 'claude-code' {
  interface PluginState {
    /**
     * In $.state so a reload of the mod keeps them, and dropped at session end: the questions waiting
     * on Dan (the first is the one shown), the rules he gave for this session only, his latest
     * message, read for the words that already make a rule permanent, the saves he answered For good
     * that Claude has yet to send again, and the main loop's running turn, null between turns.
     */
    'ask-before-saving': { pending: AskBeforeSavingQuestion[]; rules: string[]; lastPrompt: string | null; approvals: AskBeforeSavingApproval[]; turn: string | null }
  }
}
