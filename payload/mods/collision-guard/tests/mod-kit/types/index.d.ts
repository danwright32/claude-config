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
   * shell's -c read as the commands it runs (alone or in a cluster, `bash -lc`, `zsh -ec`, `sh -ce`,
   * for sh, bash, zsh, dash and ksh), and so is a shell's script fed on standard input (a heredoc, a
   * here-string, or what echo, printf or cat pipes in, #712), env -S's string split into the command
   * it runs, what a find -exec runs read after the find as a command of its own (#730), a subshell's
   * parentheses each a command of their own (`['(']`, `[')']`), while one inside a word (`$(`, `<(`)
   * stays part of it, a case's `case WORD in` and `esac` each a command, its patterns none, and an
   * input redirect (`<file`, `<<EOF`, `<<<text`) a word of its own however it is spaced. The
   * commands each command substitution runs (`$(...)` or backticks, on the command line, in an
   * unquoted heredoc's body or in a shell's own script, nested ones too) come before the command
   * they sit in (#974); one in single quotes, `$'...'`, a comment or a quoted heredoc body is text.
   * So do the commands a process substitution runs (`<(...)`, `>(...)`, #975), never one in double
   * quotes or a heredoc body. The one reader every mod uses (L613).
   */
  commands: (input: { command: string }) => Promise<string[][]>
  /**
   * The files a Bash call would change, read from the same commands `pipeline` gives, with `cwd`
   * the folder it runs in and `home` the home folder. `files`, the files it puts content into:
   * redirects (`>& file` too), tee, cp, mv, ln, install, rsync and ditto's destinations (a copy into
   * a folder lands under each source's name), sed, perl, ruby and gawk editing in place (every file,
   * marked `edits`), dd's of=, find's -fprint, and curl and wget's files (an output file, a file
   * saved under the address's own name by `curl -O` or a plain `wget`, into `--output-dir` or `-P`,
   * and curl's cookie jar, dumped headers and trace, wget's log; `wget --spider` saves none), each
   * relative path resolved after any cd before it, a cd in a subshell ending with it, and a variable
   * the command set before it (`F=path; ... "$F"`, `export F=path`) read as its value where the
   * reader can be sure of it (#743). `changes`, the other changes it makes to files (#712): removed
   * (rm, unlink, rmdir, a mv's source, find -delete, shred -u), stamped (touch), emptied (truncate,
   * shred), made (mkdir) or changed in mode (chmod, chown, chgrp), `tree` when the whole folder is
   * reached (rm -r, -R, a mv's source, find -delete). And `unnamed`, the writes its words do not
   * name: a patch (git apply, git am, patch), a program the reader's judge finds writes files, runs a
   * process or cannot be read (inline or fed on standard input, for every interpreter however it is
   * versioned), a script fed on standard input from a file (the file in `inputs`) or from something
   * that cannot be read, a command xargs gives its files to, a download the server names (`curl -J`,
   * `wget --content-disposition`), a recursive wget, or one of the addresses in a file (`wget -i`,
   * the file in `inputs`). The one reader of what a command changes (L613); a script file named as
   * an operand is not guessed at.
   */
  writes: (input: { command: string; cwd: string; home: string }) => Promise<ModKitWrites>
  /** One command's words read as git: its subcommand after git's global options, and -C's folder. Undefined when not git. */
  git: (input: { words: string[] }) => Promise<ModKitGit | undefined>
  /**
   * The same commands as `commands`, each with `pipedFrom`, the words of the command whose output
   * a `|` (or `|&`) feeds into it, absent when nothing does. `;`, `&&`, `||`, `&` and a new line
   * link no two commands, and every command in a subshell, an if, while, until, for, case or `{ }`
   * group, or a shell's script, reads what feeds it; a piped group's output arrives as its closing
   * word (`)`, `}`, `done`, `fi`, `esac`). Only the reader can see which separator stood outside the
   * quotes, so no mod works it out from the list (#724).
   *
   * Each command a shell or interpreter runs also carries what it runs (#712): `program`, the text
   * of its inline code or of what its standard input gives it (`stdin`), or why that cannot be read
   * (`unreadable`: fed by what curl pipes into it, a heredoc with no body, a group's output, or the
   * rest of a script the shell reads); `script`, the file it runs instead, named as its operand or
   * fed on standard input (`cat x.scpt | osascript`); `language`, the language of either; and
   * `verdict`, what the program can do, judged per language (writes files, runs a process, or builds
   * code at run time and cannot be read), absent when it only reads. `xargs` marks a command xargs
   * runs, whose operands come from its input (#730); `found`, on a command a find -exec runs, the
   * folders find starts from, which its `{}` is written as and which stand for everything under
   * them (#760).
   *
   * Each command also carries `heredocs`, the body of every heredoc that feeds it, absent when none
   * does (#698), for a reader that judges what a heredoc feeds (`python3 - <<'EOF'`, `bash <<'EOF'`),
   * which `commands` drops: `word` is the place of its `<<` word in `words`, and `<<-` takes the
   * leading tabs off the body. `quoted` says whether any of its delimiter was quoted or escaped
   * (`<<'EOF'`, `<<"EOF"`, `<<\EOF`), which stops the shell expanding `$` and backticks in the body,
   * so the body is exactly the text the command reads (#831). `fd` names the descriptor a heredoc feeds when it is not standard
   * input (`3<<EOF`), absent when it is; `replaced` marks one on standard input that a later
   * redirect there (`< file`, `<<<`, another heredoc) replaces, so it is not what the command reads. A heredoc inside a word (`"$(cat <<'EOF' ... )"`) feeds no command
   * here, and one that never ends has no body (its lines are read as commands).
   *
   * `substitution` marks a command a command substitution runs (#974), given before the command it
   * sits in, so a guard can tell it from one on the command line where that matters.
   */
  pipeline: (input: { command: string }) => Promise<ModKitCommand[]>
  /**
   * The git working tree an absolute path sits in: the nearest folder at or above it holding a
   * `.git` entry (a folder, or the file a linked worktree has), found on the disk, never by running
   * git, at most 64 folders up; null when there is none. Rejects a path that is not absolute, a
   * look the disk cannot answer, and a path deeper than the 64 looks reach, rather than answering
   * null. The one reading every mod uses (L613).
   */
  workingTree: (input: { path: string }) => Promise<string | null>
  /**
   * A repository read from what `$.session.repo()` gives (`root`, the main working tree, and
   * `remote`, the origin's address), or from a remote's address alone (#951). Two answers, since
   * they are two questions: `github`, the GitHub repository as owner/name in the case written, null
   * for another host, a local path (owner/name alone is one to git) or no remote; and `name`, what
   * the repository is called, the origin's last part on any host, else the checkout folder's name,
   * a worktree under `.claude/worktrees/` naming its parent, null when neither names one. Git's own
   * reading of an address: https, ssh with a user and a port, the scp form (`git@host:o/r`), git://,
   * file:// and a local path, a trailing `.git` and slashes off. The one reading every mod uses
   * (L613); a gh command's own `-R` is read by that command's reader.
   */
  repo: (input: { root?: string | null; remote: string | null }) => Promise<ModKitRepo>
  /**
   * Where the checkout an absolute path sits in stands (#978): `root`, the checkout (found as
   * `workingTree` finds it); `main`, its project's main working tree, which every worktree of it
   * shares; `branch`; `defaultBranch`, the one origin/HEAD names, null when it names none;
   * `isDefault`, that branch, or main or master when there is none; and `issues`, every run of 2 to
   * 6 digits the branch name holds on its own (`978-guard`, `fix/issue-41-and-52`). Null when the
   * path is in no checkout. A branch git cannot read, a detached head, or no main working tree is
   * `unreadable`, saying which, with `main` where git named it. Rejects as `workingTree` does. Asked
   * of git with three reads at once, each bounded at 3 seconds. The one reading every mod uses (L613).
   */
  branch: (input: { path: string }) => Promise<ModKitBranch | null>
  /**
   * Shows a row in the band above the prompt, or replaces the row this mod already shows under the
   * same id (it keeps its place). Claude Code gives the band ONE drawing, so no mod but mod-kit
   * hooks it (tools/check-mod-shared-parts.sh); every mod publishes its rows here and mod-kit draws
   * them in the settled order of the slots. Rejects a slot not in that list, or a row with no mod or
   * id. A Button in the row is drawn with the key `<mod>:<button>`; its press, clicked or typed with
   * /press, reaches the publisher through `on('modkit.press', ...)` with that element (#939).
   */
  bandRow: (row: ModKitBandRow) => Promise<void>
  /** Takes this mod's row with that id out of the band. Clearing a row that is not there is fine. */
  clearBandRow: (input: { mod: string; id: string }) => Promise<void>
  /**
   * Draws a side pane the mod opened with `$.ui.open({ id })` as a card, with the band's own row
   * drawing, so a card reads the same in the pane and in the band (#690). The mod still opens and
   * closes the pane itself; publishing again replaces what it shows. No mod but mod-kit draws a
   * card in a pane (tools/check-mod-shared-parts.sh); a pane drawn its own way, such as the goals
   * pane's live list, is the mod's. A Button is keyed `<mod>:<button>` and its press
   * reaches the publisher through `on('modkit.press', ...)`, as in the band. Rejects a pane with no mod or id, lines or a frame of the wrong shape, and a pane
   * id another mod already draws (Claude Code keys a pane by its id alone).
   */
  pane: (pane: ModKitPane) => Promise<void>
  /** Stops drawing this mod's pane with that id; a pane still open is then drawn by Claude Code. Clearing one not drawn is fine. */
  clearPane: (input: { mod: string; id: string }) => Promise<void>
  /**
   * Whether a guard refuses a tool call, asked by a mod that answers the call itself (#707). Such a
   * hook never calls next, so the guards beneath it never see the call, and they sit beneath it
   * whenever its folder sorts first. Ask before acting on the call's input (showing, storing or
   * sending it), and answer with the refusal when there is one. The secret guard is asked, which
   * draws its card and toasts as when it refuses a call itself; null when nothing refuses or the
   * secret guard is not loaded. One that fails to answer refuses the call, with a card (L42).
   */
  screen: (call: ModKitCall) => Promise<{ deny: string } | null>
  /**
   * A press on a band or pane button (#939), raised by mod-kit and answered by the publisher's hook
   * on this event: `on('modkit.press', ($, e, next) => e.element === 'handoff:use' ? (act(), { value:
   * { isAnswered: true } }) : next(e))`. One path for both ways a button is pressed: a click where
   * the surface reports one, and `/press <mod> <button>`. Answer here rather than in a `ui.press`
   * hook, which a click alone reaches, so a typed press never misses a handler a click would reach.
   * Unanswered, `isAnswered` is false and mod-kit says nothing answered it.
   */
  press: (input: ModKitPress) => Promise<{ isAnswered: boolean }>
  /**
   * Whether a click on a Button a mod draws itself reaches it on the surface `e` names (#939): the
   * one answer, so a mod drawing its own Button (outside the band and a pane) shows it only where a
   * click lands and says what to do instead elsewhere. Pass the render hook's `e`.
   */
  clickable: (site: ModKitClickSite) => Promise<boolean>
}

/** A repository as `$.modkit.repo` reads it: its GitHub owner/name and its name, each null when there is none. */
export type ModKitRepo = { github: string | null; name: string | null }
/** Where a checkout stands, as `$.modkit.branch` reads it, or why that could not be read. */
export type ModKitBranch =
  | { root: string; main: string; branch: string; defaultBranch: string | null; isDefault: boolean; issues: number[] }
  | { root: string; main: string | null; unreadable: string }
/** A press on a button mod-kit drew: its `<mod>:<button>` key, the surface it came from, and how. */
export type ModKitPress = { element: string; surface: string; how: 'click' | 'typed' }
/** Where a Button is drawn, as a render hook's `e` carries it. */
export type ModKitClickSite = { surface: string; viewport?: { isFullscreen?: boolean } }

/** A tool call as a `tool.call` hook receives it: the tool, the call's id, and its arguments beside them. Plain data. */
export type ModKitCall = { tool: string; tool_use_id?: string } & Record<string, unknown>

/**
 * What a side pane shows: a band row's lines and frame, with no slot, since a pane holds one card.
 * `id` is the pane's id as the mod opened it with `$.ui.open`.
 */
export type ModKitPane = { mod: string; id: string; lines: ModKitBandLine[]; frame?: ModKitBandFrame }

/**
 * One simple command, as `pipeline` reads it: its words, those of the command a `|` feeds it from,
 * each heredoc feeding it, by its `<<` word's place, and for a shell or an interpreter what it runs.
 */
export type ModKitCommand = {
  words: string[]
  pipedFrom?: string[]
  heredocs?: { word: number; body: string; quoted: boolean; fd?: number; replaced?: true }[]
  xargs?: true
  found?: string[]
  language?: ModKitLanguage
  program?: ModKitProgram
  script?: { files: string[]; stdin?: true }
  verdict?: ModKitCodeVerdict
  substitution?: true
}

/** The languages whose inline code the reader judges. */
export type ModKitLanguage = 'python' | 'node' | 'ruby' | 'perl' | 'osascript' | 'awk' | 'sed'
/** A command's program: its text (`stdin` when it came on standard input), or why it cannot be read. */
export type ModKitProgram = { text: string; stdin?: true } | { unreadable: string }
/** What a program can do that only reading does not, and the words that showed it. */
export type ModKitCodeVerdict = { does: 'run a process' | 'write files' | 'unreadable'; seen: string }

export type ModKitGit = { sub: string | undefined; args: string[]; dir: string | undefined }

/**
 * One file a command writes: `word` as the command spells it, `path` the absolute path when the
 * words name one (absent for a path built from a variable other than HOME the command did not set
 * to a value the reader can be sure of, a command's output, a pattern, or a relative path after a
 * cd that cannot be followed), a copy's `sources`, `edits` for one edited in place, and
 * `mayBeFolder` for a copy of one source onto one name, which lands inside it when it is an existing
 * folder, as only the disk can say. A `word` holding `$F` with a `path` is a variable the command
 * set, read as its value (#743); a copy into a folder held in one keeps it (`$D/note.md`, #752).
 * A redirect's target is given as its own place in the command spells it; any other word is matched
 * to its spelling by string, so a literal word equal to a variable's value in the same command is
 * given as the variable (#752).
 */
export type ModKitWrite = { word: string; path?: string; sources?: string[]; edits?: true; mayBeFolder?: true; tree?: true }

/**
 * One change a command makes to a file that puts no content in it: removed, stamped (touch),
 * emptied (truncate, shred), made a folder (mkdir) or its mode or owner changed; `tree` when it
 * reaches everything under a folder. `word` and `path` as in a write.
 */
export type ModKitChange = { word: string; path?: string; does: 'remove' | 'touch' | 'truncate' | 'folder' | 'mode'; tree?: true }

/**
 * What a command changes: the files its words name content goes into, the other changes it makes
 * to files, and the writes its words do not name (`what` names it, "a patch" or "an inline python3
 * script"; `words` is the command as written, a variable's name left in it; `inputs` the files to read to find out, such as the patch file,
 * absolute; `into` the folder a download lands in, where the words name one; `script` when it is a
 * script file run on standard input, `sh < setup.sh` or `cat build.py | python3`, its files the inputs;
 * `targets`, for a program whose text names every file it writes, those files, absolute, so a reader
 * judges them rather than every path the text quotes, absent where the file of any write cannot be
 * named (#830)).
 */
export type ModKitWrites = {
  files: ModKitWrite[]
  changes: ModKitChange[]
  unnamed: { what: string; words: string[]; inputs: string[]; into?: string; script?: true; targets?: string[] }[]
}

/**
 * Where a band row sits, drawn top to bottom in this order (docs/mods-design.md, "The band, shared
 * by every mod"): the status rows first (the amber needs-a-look line, then the Compact row), the
 * account room card about this account's limits (#659), then
 * what waits on Dan nearest the prompt (the handoff card at session start, the held while away card,
 * the steps card, then a message to send). No question is drawn in the band: since #744 and #777
 * every question is Claude Code's own dialog.
 */
export type ModKitBandSlot = 'needs-a-look' | 'compact' | 'room' | 'handoff' | 'held' | 'steps' | 'message'

/**
 * A run of text in a band line, in the terminal's own colours: `color` is a theme key ('warning' is
 * amber) or a raw colour. `indent` is how many blank columns are drawn before it (after any
 * part before it on the line, so on a line's first part it is where the line starts), so a description can sit under
 * the option it describes. `wrap: true` carries a run too long for the band on to the lines under
 * it; any other run is cut at the band's edge. Refused in a row with a left rule, which draws one
 * mark per line. `href` makes the run Claude Code's Link to that address, a real terminal
 * hyperlink, so a long one cut at the edge still opens and copies whole where the terminal draws
 * hyperlinks (#708). `whole: true` draws the run at its full width however narrow the band, so a
 * label before a long run keeps every character and the long run is cut or wrapped instead (#872);
 * a run cannot both wrap and be whole.
 */
export type ModKitBandText = { text: string; href?: string; color?: string; bold?: boolean; dim?: boolean; strikethrough?: boolean; indent?: number; wrap?: true; whole?: true }
/**
 * Claude Code's own Button, `[ label ]`; `button` is its id within the publishing mod. `plain: true`
 * draws it in Claude Code's plain style, a survey's row: the hotkey in the accent colour, a colon,
 * the label (`1: 7 days`), or the label alone when it has no hotkey (#667). `instead` is the text
 * drawn in the button's place wherever a click may not reach it (#939): a terminal's main screen,
 * and Apple Terminal, whose tab only reports clicks while View > Allow Mouse Reporting is ticked,
 * which no mod can read. An empty list draws nothing there, for a button whose content sits beside
 * it as text, and an instead run takes no indent, whole or wrap. Left out, mod-kit draws "type:
 * /press <mod> <button>" there, which presses it the same way.
 */
export type ModKitBandButton = { button: string; label: string; hotkey?: string; plain?: true; indent?: number; instead?: ModKitBandText[] }
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
    /**
     * The band's rows, in the order they were first published; kept in $.state so a reload keeps
     * them. `started`: when mod-kit last started in this session, so its reload can tell which mods
     * that depend on it changed since (#960). `askAgain`: the mods a pass could not ask to load
     * again, asked again at the next one. `stamped`: the time each manifest mod-kit touched was left
     * with, by mod, so its own touch is not read as a change. `swept`: where each provider other than
     * mod-kit was last looked at, at a turn's start (#966), `from` for one not looked at yet.
     */
    'mod-kit': { band: ModKitBandRow[]; panes: ModKitPane[]; started: number; askAgain: string[]; stamped: Record<string, number>; swept: { from: number; at: Record<string, number> } }
  }
}
