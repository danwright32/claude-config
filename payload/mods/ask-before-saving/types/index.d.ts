/** A save to lasting memory refused until Claude asks Dan in Claude Code's dialog and he answers (#777). */
export type AskBeforeSavingQuestion = {
  /** The refused call's tool_use_id, which the dialog's `metadata.source` names. */
  id: string
  /** The tool and its arguments as Claude sent them, which For good asks Claude to send again. */
  tool: 'Write' | 'Edit' | 'Bash'
  input: Record<string, unknown>
  /** Where it would go, as Dan reads it (home as ~). */
  files: string[]
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
  /**
   * Why the save Claude sent again was refused before this mod's check saw it (another guard), so
   * the approval stood unused: its lapse says so rather than calling it unused (#764).
   */
  refused?: string
  /**
   * Set on an approval Dan gave in the durable lesson picker (#867), as the rule compared (rules.ts
   * ruleText): a write that only adds this rule to the lessons file goes through. Its key is never a
   * save's, so a call is never matched to it by key.
   */
  lesson?: string
}

declare module 'claude-code' {
  interface PluginState {
    /**
     * In $.state so a reload of the mod keeps them, and dropped at session end: the refused saves
     * waiting for Claude to ask Dan in the dialog, the rules he gave for this session only, his
     * latest message, read for the words that already make a rule permanent, and the saves he
     * answered For good that Claude has yet to send again.
     */
    'ask-before-saving': { pending: AskBeforeSavingQuestion[]; rules: string[]; lastPrompt: string | null; approvals: AskBeforeSavingApproval[] }
  }
}
