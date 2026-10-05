/** How an open question ended: an option pressed, numbered prose typed, a message typed instead, or the call withdrawn. */
export type PickersOutcome = { kind: 'answer'; answer: string } | { kind: 'prose'; answers: string[] } | { kind: 'message' } | { kind: 'withdrawn' }

/** The question open in the band, by the tool call that asked it. */
export type PickersOpen = {
  id: string
  question: { question: string; header: string; multiSelect: boolean; options: { label: string; description?: string }[] }
  /** A multi select question's options chosen so far, by label. */
  chosen: string[]
}

/**
 * A question of Claude's that Dan talked past or dismissed this session, as the limit on asking
 * again compares it (#703): its text and chip lower cased with punctuation and spacing gone, its
 * answers' labels sorted, and how many times.
 */
export type PickersPassed = { question: string; header: string; labels: string[]; count: number }

/**
 * The picker manners mod's own wait, on $ so that a tool.call hook waiting on Dan spends no hook
 * budget: a `$` call's time is free, a plain promise's is not (measured, 2026-10-04: a plain await
 * past 10 seconds lets the engine's own picker run instead). Called by this mod alone.
 */
export type Pickers = {
  wait: (input: { id: string }) => Promise<PickersOutcome>
}

declare module 'claude-code' {
  interface EngineInterface {
    pickers: Pickers
  }
  interface PluginState {
    /**
     * In $.state so a reload keeps them: the open question, whether next issue pickers are off for
     * this session, and the questions of Claude's Dan talked past or dismissed.
     */
    'picker-manners': { open: PickersOpen | null; quiet: boolean; passed: PickersPassed[] }
  }
}
