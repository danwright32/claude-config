export type ModKitBlocked = {
  /** The blocked call's tool_use_id, from the tool.call input. */
  toolUseId: string
  /** The guard's name as Dan reads it, e.g. "Secret guard". */
  guard: string
  /** What was blocked, one plain sentence. */
  reason: string
  /** The safe way instead, drawn dim; optional. */
  safeWay?: string
  /** Something the guard could not do, drawn dim under the safe way; optional. */
  note?: string
}

/** Called from another mod, each method answers asynchronously: await it. */
export type ModKit = {
  /** Records that a guard blocked this call, so its result row is drawn as the grey card. */
  blocked: (input: ModKitBlocked) => Promise<void>
  /**
   * The simple commands a Bash call would run, each as its words with quotes removed: heredoc
   * bodies dropped, assignments and sudo/env/exec and the like looked past, a shell's -c read as
   * the commands it runs. The one reader every mod uses (L613).
   */
  commands: (input: { command: string }) => Promise<string[][]>
  /** One command's words read as git: its subcommand after git's global options, and -C's folder. Undefined when not git. */
  git: (input: { words: string[] }) => Promise<ModKitGit | undefined>
  /**
   * Shows a row in the band above the prompt, or replaces the row this mod already shows under the
   * same id (it keeps its place). Claude Code gives the band ONE drawing, so no mod but mod-kit
   * hooks it (tools/check-mod-shared-parts.sh); every mod publishes its rows here and mod-kit draws
   * them in the settled order of the slots. Rejects a slot not in that list, or a row with no mod or
   * id. A Button in the row is drawn with the key `<mod>:<button>`; its press reaches the publisher
   * through `on('ui.press', { plugin: 'mod-kit', element: '<mod>:<button>' }, ...)`.
   */
  bandRow: (row: ModKitBandRow) => Promise<void>
  /** Takes this mod's row with that id out of the band. Clearing a row that is not there is fine. */
  clearBandRow: (input: { mod: string; id: string }) => Promise<void>
}

export type ModKitGit = { sub: string | undefined; args: string[]; dir: string | undefined }

/**
 * Where a band row sits, drawn top to bottom in this order (docs/mods-design.md, "The band, shared
 * by every mod"): the status rows first (the amber needs-a-look line, then the Compact row), then
 * what waits on Dan nearest the prompt (the steps card, then a message to send). An open question
 * takes the band alone, and everything else comes back once it is cleared.
 */
export type ModKitBandSlot = 'needs-a-look' | 'compact' | 'steps' | 'message' | 'question'

/** A run of text in a band line, in the terminal's own colours: `color` is a theme key ('warning' is amber) or a raw colour. */
export type ModKitBandText = { text: string; color?: string; bold?: boolean; dim?: boolean; strikethrough?: boolean }
/** Claude Code's own Button, `[ label ]`; `button` is its id within the publishing mod. */
export type ModKitBandButton = { button: string; label: string; hotkey?: string }
export type ModKitBandPart = ModKitBandText | ModKitBandButton

/** One mod's row: plain data, since only plain data crosses between mods. Each line is drawn as one terminal line. */
export type ModKitBandRow = { mod: string; id: string; slot: ModKitBandSlot; lines: ModKitBandPart[][] }

declare module 'claude-code' {
  interface EngineInterface {
    modkit: ModKit
  }
  interface PluginState {
    /** The band's rows, in the order they were first published; kept in $.state so a reload keeps them. */
    'mod-kit': { band: ModKitBandRow[] }
  }
}
