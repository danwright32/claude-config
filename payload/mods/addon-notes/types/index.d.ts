/** A reply block's opening resume line, and the rest of the block under it. */
export type AddonNotesResume = {
  /** The resume line as Claude wrote it, "+ add-on: ..." with its trailing space trimmed. */
  line: string
  /** The rest of the block under the line, trimmed; empty when the block is only the line. */
  rest: string
}

/** Read by other mods (Simpler, which redraws the same reply block, #701): await it. */
export type AddonNotes = {
  /**
   * Whether `text`, a reply block's text, opens with the agreed resume line ("+ add-on: ... and
   * carrying on."): the line and the rest of the block, or null when it does not. The one reading
   * of the line: this mod draws it dim by the same rule. Throws on a text that is not a string, so
   * a malformed question is never answered as no line.
   */
  resumeLine: (q: { text: string }) => Promise<AddonNotesResume | null>
}

declare module 'claude-code' {
  interface EngineInterface {
    addonNotes: AddonNotes
  }
}
