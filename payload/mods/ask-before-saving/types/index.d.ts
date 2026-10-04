/** A save to lasting memory waiting on Dan's answer in the band. */
export type AskBeforeSavingQuestion = {
  /** The refused call's tool_use_id. */
  id: string
  /** The tool and its arguments as Claude sent them, replayed exactly on For good. */
  tool: 'Write' | 'Edit' | 'Bash'
  input: Record<string, unknown>
  /** Where it would go, as Dan reads it (home as ~). */
  files: string[]
  /** What would be saved: the new lines of a Write, an Edit's new text, a Bash command as written. */
  text: string
}

declare module 'claude-code' {
  interface PluginState {
    /**
     * In $.state so a reload of the mod keeps them, and dropped at session end: the questions waiting
     * on Dan (the first is the one shown), the rules he gave for this session only, and his latest
     * message, read for the words that already make a rule permanent.
     */
    'ask-before-saving': { pending: AskBeforeSavingQuestion[]; rules: string[]; lastPrompt: string | null }
  }
}
