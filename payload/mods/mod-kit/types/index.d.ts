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

/** A run of text on a card, in the terminal's own colours: `color` is a theme key ('success' green, 'warning' amber) or a raw colour. */
export type ModKitRun = { text: string; color?: string; bold?: boolean; dim?: boolean }

/**
 * A tool result drawn as the boxed card (#663), the blocked card's shape: a rounded grey border,
 * the title in bold, then each line. Plain data, since only plain data crosses between mods.
 */
export type ModKitCard = {
  /** The tool_use_id of the result row it is drawn for, from the tool.call input. */
  toolUseId: string
  /** One or more runs, drawn as one bold line, so a leading state word can carry its colour ("Live:" green). */
  title: ModKitRun[]
  /** The lines under the title, each one or more runs; a long line wraps. */
  lines: ModKitRun[][]
}

/**
 * Called from another mod, each method answers asynchronously: await it.
 *
 * mod-kit also tries every mod's refused `$.session.send` once more, through its session.send hook
 * rather than a method here, so the message still arrives as the sending mod's (#688). A mod sends
 * once and reports `reason` when `isDelivered` is false: that is the second refusal, its reason
 * trimmed and without a full stop of its own. A send that throws is not tried again, since it may
 * have landed, and is answered as not delivered with the error's message. Claude's own SendMessage
 * is left as it is. No mod keeps its own retry (tools/check-mod-shared-parts.sh).
 */
export type ModKit = {
  /** Records that a guard blocked this call, so its result row is drawn as the grey card (one use of `card`). */
  blocked: (input: ModKitBlocked) => Promise<void>
  /**
   * Draws this tool call's result row as the boxed card, in place of the tool's own text result,
   * which the model still reads. Only mod-kit draws a result row (tools/check-mod-shared-parts.sh),
   * so a mod's own tool shows its card through this. Rejects a card with no tool use id, no title,
   * or a line or run that is not plain data of the right shape. Kept in memory: after a reload an
   * earlier row is drawn as the tool's text result again.
   */
  card: (input: ModKitCard) => Promise<void>
  /**
   * The simple commands a Bash call would run, each as its words with quotes removed: heredoc
   * bodies dropped, assignments, the reserved words leading a command (then, do, else, `{`, `!`) and
   * sudo, env, timeout, nice, xargs and the like looked past, each runner by its own options, a
   * shell's -c read as
   * the commands it runs, a subshell's parentheses each a command of their own (`['(']`, `[')']`),
   * while one inside a word (`$(`, `<(`) stays part of it. The one reader every mod uses (L613).
   */
  commands: (input: { command: string }) => Promise<string[][]>
  /**
   * The files a Bash call would put content into, read from the same simple commands, with `cwd`
   * the folder it runs in and `home` the home folder: redirects, tee, cp, mv, ln, install, rsync
   * and ditto's destinations (a copy into a folder lands under each source's name), sed, perl, ruby
   * and gawk editing in place (every file), dd's of=, and curl and wget's output file, each relative
   * path resolved after any cd before
   * it. And the writes its words do not name: a patch (git apply, git am, patch), an inline script
   * that writes (python3 -c, node -e), a script fed on standard input. The one reader of what a
   * command writes (L613); a file only touched, removed or changed in mode is not reported.
   */
  writes: (input: { command: string; cwd: string; home: string }) => Promise<ModKitWrites>
  /** One command's words read as git: its subcommand after git's global options, and -C's folder. Undefined when not git. */
  git: (input: { words: string[] }) => Promise<ModKitGit | undefined>
  /**
   * The same commands as `commands`, each with `pipedFrom`, the words of the command whose output
   * a `|` (or `|&`) feeds into it, absent when nothing does. `;`, `&&`, `||`, `&` and a new line
   * link no two commands, and every command in a subshell, an if, while, until, for or `{ }` group,
   * or a shell's -c reads what feeds it; a piped group's output arrives as its closing word (`)`,
   * `}`, `done`, `fi`). Only the reader can see which
   * separator stood outside the quotes, so no mod works it out from the list (#724).
   */
  pipeline: (input: { command: string }) => Promise<ModKitCommand[]>
  /**
   * Shows a row in the band above the prompt, or replaces the row this mod already shows under the
   * same id (it keeps its place). Claude Code gives the band ONE drawing, so no mod but mod-kit
   * hooks it (tools/check-mod-shared-parts.sh); every mod publishes its rows here and mod-kit draws
   * them in the settled order of the slots. Rejects a slot not in that list, or a row with no mod or
   * id. A Button in the row is drawn with the key `<mod>:<button>`; its press reaches the publisher
   * through `on('ui.press', { plugin: 'mod-kit', element: '<mod>:<button>' }, ...)`.
   */
  bandRow: (row: ModKitBandRow) => Promise<void>
  /**
   * Asks a question in the band, drawn the one settled way (docs/mods-design.md, "The band, shared
   * by every mod"), or replaces the question this mod already asks under the same id (it keeps its
   * turn). The only way into the `question` slot: `bandRow` refuses a question row, so every
   * question reads the same (#703, #705). One question is drawn at a time, the first asked; the rest
   * wait, each drawn once the one before it is cleared with `clearBandRow`, so a number key can only
   * mean the answer to the question in view. Option n is pressed by the key n and its press reaches
   * the publisher as `<mod>:<button>`, as any band button's does. Rejects a question with no mod,
   * id, chip or question, no options or more than nine, an option with no label, a button id used
   * twice, or body lines of the wrong shape.
   */
  question: (question: ModKitQuestion) => Promise<void>
  /** The question the band draws now, the first asked of those open, or null when none is open. */
  shownQuestion: () => Promise<{ mod: string; id: string } | null>
  /** Takes this mod's row with that id out of the band, a question included. Clearing a row that is not there is fine. */
  clearBandRow: (input: { mod: string; id: string }) => Promise<void>
  /**
   * Draws a side pane the mod opened with `$.ui.open({ id })` as a card, with the band's own row
   * drawing, so a card reads the same in the pane and in the band (#690). The mod still opens and
   * closes the pane itself; publishing again replaces what it shows. No mod but mod-kit draws a
   * card in a pane (tools/check-mod-shared-parts.sh); a pane drawn its own way, such as the goals
   * pane's live list, is the mod's. A Button is keyed `<mod>:<button>` and its press
   * reaches the publisher through `on('ui.press', { plugin: 'mod-kit', element: '<mod>:<button>' }, ...)`,
   * as in the band. Rejects a pane with no mod or id, lines or a frame of the wrong shape, and a pane
   * id another mod already draws (Claude Code keys a pane by its id alone).
   */
  pane: (pane: ModKitPane) => Promise<void>
  /** Stops drawing this mod's pane with that id; a pane still open is then drawn by Claude Code. Clearing one not drawn is fine. */
  clearPane: (input: { mod: string; id: string }) => Promise<void>
}

/**
 * What a side pane shows: a band row's lines and frame, with no slot, since a pane holds one card.
 * `id` is the pane's id as the mod opened it with `$.ui.open`.
 */
export type ModKitPane = { mod: string; id: string; lines: ModKitBandLine[]; frame?: ModKitBandFrame }

/** One simple command, as `pipeline` reads it: its words, and those of the command a `|` feeds it from. */
export type ModKitCommand = { words: string[]; pipedFrom?: string[] }

export type ModKitGit = { sub: string | undefined; args: string[]; dir: string | undefined }

/**
 * One file a command writes: `word` as the command spells it, `path` the absolute path when the
 * words name one (absent for a path built from a variable other than HOME, a pattern, or a relative
 * path after a cd that cannot be followed), and a copy's `sources`.
 */
export type ModKitWrite = { word: string; path?: string; sources?: string[] }

/**
 * What a command writes: the files its words name, and the writes they do not (`what` names it, "a
 * patch" or "an inline python3 script"; `words` is the command; `inputs` the files to read to find
 * out, such as the patch file, absolute).
 */
export type ModKitWrites = { files: ModKitWrite[]; unnamed: { what: string; words: string[]; inputs: string[] }[] }

/**
 * One answer to a question in the band. `button` is its id within the mod (its press arrives as
 * `<mod>:<button>`), `label` what it reads, `description` the line drawn under it, and `chosen`
 * marks an option of a multi select question as picked so far.
 */
export type ModKitQuestionOption = { button: string; label: string; description?: string; chosen?: boolean }

/**
 * A question in the band, as `$.modkit.question` draws it: `[chip]` in grey and the question in
 * amber on one line; then `body`, any lines the asker shows before the answers (ask before saving's
 * rule and the file it goes to); then each option on its own line as Claude Code's plain button,
 * "1: label", its number its hotkey, its description dim and indented under it, wrapping at the
 * band's edge; then `submit`, when given, as a bracketed button (a multi select question's Submit).
 */
export type ModKitQuestion = {
  mod: string
  id: string
  chip: string
  question: string
  body?: ModKitBandLine[]
  options: ModKitQuestionOption[]
  submit?: { button: string; label: string }
}

/**
 * Where a band row sits, drawn top to bottom in this order (docs/mods-design.md, "The band, shared
 * by every mod"): the status rows first (the amber needs-a-look line, then the Compact row), then
 * what waits on Dan nearest the prompt (the handoff card at session start, the held while away card,
 * the steps card, then a message to send). An open question, published with `$.modkit.question`,
 * takes the band alone, one question at a time, and everything else comes back once it is cleared.
 */
export type ModKitBandSlot = 'needs-a-look' | 'compact' | 'handoff' | 'held' | 'steps' | 'message' | 'question'

/**
 * A run of text in a band line, in the terminal's own colours: `color` is a theme key ('warning' is
 * amber) or a raw colour. `indent` is how many blank columns are drawn before it (after any
 * part before it on the line, so on a line's first part it is where the line starts), so a description can sit under
 * the option it describes. `wrap: true` carries a run too long for the band on to the lines under
 * it; any other run is cut at the band's edge. Refused in a row with a left rule, which draws one
 * mark per line. `href` makes the run Claude Code's Link to that address, a real terminal
 * hyperlink, so a long one cut at the edge still opens and copies whole where the terminal draws
 * hyperlinks (#708).
 */
export type ModKitBandText = { text: string; href?: string; color?: string; bold?: boolean; dim?: boolean; strikethrough?: boolean; indent?: number; wrap?: true }
/**
 * Claude Code's own Button, `[ label ]`; `button` is its id within the publishing mod. `plain: true`
 * draws it in Claude Code's plain style, a survey's row: the hotkey in the accent colour, a colon,
 * the label (`1: 7 days`), or the label alone when it has no hotkey (#667).
 */
export type ModKitBandButton = { button: string; label: string; hotkey?: string; plain?: true; indent?: number }
export type ModKitBandPart = ModKitBandText | ModKitBandButton
/** A thin grey line across the band, between the lines of a card. */
export type ModKitBandDivider = { divider: true }
/** One terminal line: its parts, or a divider in place of them. */
export type ModKitBandLine = ModKitBandPart[] | ModKitBandDivider

/**
 * What a row is drawn inside: `box` a rounded border all round, `left-rule` a vertical rule down its
 * left edge only. `color` is a theme key or a raw colour; left out, the terminal's grey.
 */
export type ModKitBandFrame = { kind: 'box' | 'left-rule'; color?: string }

/** One mod's row: plain data, since only plain data crosses between mods. Each line is drawn as one terminal line, or more where a run wraps. */
export type ModKitBandRow = { mod: string; id: string; slot: ModKitBandSlot; lines: ModKitBandLine[]; frame?: ModKitBandFrame }

declare module 'claude-code' {
  interface EngineInterface {
    modkit: ModKit
  }
  interface PluginState {
    /** The band's rows, in the order they were first published; kept in $.state so a reload keeps them. */
    'mod-kit': { band: ModKitBandRow[]; panes: ModKitPane[] }
  }
}
