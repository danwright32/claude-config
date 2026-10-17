import type { ModKitBandRow, ModKitCommand } from '../.claude-plugin/types/mod-kit/index.d.ts'
import type { ScopeModesHeld } from '../types/index.d.ts'

// Away and home (#621). While Dan is away what needs him at the Mac is held, and on coming home each
// session shows what it held in one boxed card in the band, nothing running until he presses its
// button (design round, 2026-10-04). Sleep mode holds the same (#840).
//
// WHAT IS HELD changed with #1269. Dan, 2026-10-16 ET: "I don't care if you bring apps to the front
// or do automations for testing". Focus moving costs him nothing while he is not at the Mac, so
// opening an app or a file, BBEdit's helper, bringing an app forward and browser automation opening
// a page or a tab all run. Typing and clicking run only into a test build (isTestBuild), and the
// keystroke guard still proves by pid that the target is in front before any keystroke. Held, on
// his answers the same day: a dialog (it waits for a press nobody is there to give), a script whose
// text cannot be read (it could hold a dialog, or keystrokes no frontmost proof covers), typing or
// clicking into anything else (a keystroke into Mail or Messages could send what nobody reviewed),
// and what exists only to show him something: the Artifact tool's open action here, the report and
// the manual steps card in their own code.

const base = (p: string) => p.replace(/\/+$/, '').split('/').pop() || p
const isFlag = (w: string) => w.startsWith('-')
// A link is named by where it goes, never by its query or fragment, which can carry a token (L741).
const shown = (target: string) => (/^[a-z][a-z0-9+.-]*:\/\//i.test(target) ? target.replace(/[?#].*$/, '') : base(target))

/**
 * Every executable a keystroke guard action names: TARGET_APP=<executable path>, the guard's own
 * rule, read from the command as written, since the reader drops assignments. Every one, wherever
 * it stands (an echo, a second command), since a call is a test build's only when all of them are
 * (lessons review of #1269); the guard itself proves the one it reads is in front before any input.
 */
export const targetPaths = (raw: string): string[] =>
  [...raw.matchAll(/\bTARGET_APP=("[^"]+"|'[^']+'|\S+)/g)].map(m => (m[1] as string).replace(/^["']|["']$/g, ''))
/** The first of them, which the keystroke guard reads and the held row names. */
export const targetPath = (raw: string): string | undefined => targetPaths(raw)[0]
// The app it names, for the held row.
const targetApp = (raw: string): string | undefined => {
  const path = targetPath(raw)
  if (path === undefined) return undefined
  const app = /([^/]+)\.app\//.exec(path)
  return app ? (app[1] as string) : base(path)
}

/**
 * What isTestBuild asks of the Mac: the home folder, and the checkout a path sits in, which is
 * mod-kit's one reading of it ($.modkit.workingTree: the nearest folder at or above it holding .git,
 * a worktree's .git file included, or null), never a walk of this mod's own (L613).
 */
export type TestBuildFs = { home: string | undefined; treeOf: (path: string) => Promise<string | null> }

const SIMULATOR = /^\/Applications\/Xcode[^/]*\.app\/Contents\/Developer\/Applications\/Simulator\.app\/Contents\/MacOS\/Simulator$/
/**
 * Whether an executable is a test build (Dan, 2026-10-16 ET): under Xcode's DerivedData, inside a
 * project checkout, or Simulator where Xcode keeps it. Only an absolute path with no `..` is judged.
 * A checkout that is the home folder, any folder in /Users, or anything above them is not one, so a
 * repository of dotfiles in the home folder cannot make every app beneath it a test build. A
 * checkout that cannot be read (mod-kit not loaded, the disk not answering) is no test build, so the
 * action stays held (L42).
 */
export const isTestBuild = async (path: string, fs: TestBuildFs): Promise<boolean> => {
  if (!path.startsWith('/') || path.split('/').includes('..')) return false
  const home = fs.home?.replace(/\/+$/, '')
  if (home ? path.startsWith(`${home}/Library/Developer/Xcode/DerivedData/`) : /^\/Users\/[^/]+\/Library\/Developer\/Xcode\/DerivedData\//.test(path)) return true
  if (SIMULATOR.test(path)) return true
  let tree: string | null
  try {
    tree = await fs.treeOf(path)
  } catch {
    return false
  }
  if (!tree || tree === '/' || tree === '/Users' || /^\/Users\/[^/]+$/.test(tree)) return false
  return !(home && (tree === home || home.startsWith(`${tree}/`)))
}

/** What a guard acting on the Mac names when it asks to hold (the keystroke guard, #707). */
export type AwayAction = { kind: 'input' | 'focus'; target?: string }
/** Whether that action runs while Dan is away or asleep (#1269): bringing an app forward does; typing or clicking only into a test build. */
export const awayAllows = async (action: AwayAction, fs: TestBuildFs): Promise<boolean> =>
  action.kind === 'focus' || (action.target !== undefined && (await isTestBuild(action.target, fs)))

// A script that types or clicks; one that only reads, shows a notification banner or brings an app
// forward needs nobody (#1269). A dialog waits for a press nobody is there to give (#702).
const SCRIPT_TYPES = /\b(?:keystroke|key code|click)\b/i
// JavaScript for Automation spells each one as a method, `app.displayDialog()` (#730).
const SCRIPT_DIALOG = /\b(?:display (?:dialog|alert)|choose (?:file|folder|from list|color|application|remote application|URL|file name)|display(?:Dialog|Alert)|choose(?:File(?:Name)?|Folder|FromList|Color|Application|RemoteApplication|URL))\b/i

/**
 * What a Bash call would do on the Mac that needs Dan there (show a dialog, run a script it cannot
 * read, type or click into anything but a test build), as the line his held card names it by, or
 * undefined when it needs nothing of him. Each command comes with what mod-kit's reader found it
 * runs (#712): its program and what that can do, or the script file it runs, so an AppleScript fed
 * on standard input, or piped in from a file (`cat notify.scpt | osascript`, #730), is judged too.
 * `testBuild` says whether the app TARGET_APP names is a test build (isTestBuild, asked by the
 * caller, since it reads the file system).
 */
// The text of an osascript command's script, as the reader gave it.
const scriptOf = ({ words, program }: ModKitCommand): string =>
  [...words.slice(1).filter(a => !isFlag(a) && !a.startsWith('<')), ...(program && 'text' in program ? [program.text] : [])].join(' ')
// A command that types or clicks: an AppleScript keystroke, key code or click, cliclick, Peekaboo.
const typesOrClicks = (c: ModKitCommand): boolean => {
  const cmd = base(c.words[0] ?? '')
  return cmd === 'cliclick' || cmd === 'peekaboo' || (cmd === 'osascript' && SCRIPT_TYPES.test(scriptOf(c)))
}
// A marker written right before the command it names, as the keystroke guard's rule writes it.
const ATTACHED = /\bTARGET_APP=("[^"]+"|'[^']+'|\S+)\s+(?:\S*\/)?(?:osascript|cliclick|peekaboo)\b/g
/**
 * The executable each typing or clicking command in a call names, or undefined when that cannot be
 * told (lessons review of #1269): every one carries its own TARGET_APP written right before it, and
 * the call carries no other, so a marker in an echo, or one command's standing for another's, never
 * makes a call a test build's. The keystroke guard then proves the one it names is in front.
 */
export const typedTargets = (raw: string, commands: ModKitCommand[]): string[] | undefined => {
  const attached = [...raw.matchAll(ATTACHED)].map(m => (m[1] as string).replace(/^["']|["']$/g, ''))
  const inputs = commands.filter(typesOrClicks).length
  if (!attached.length || attached.length !== targetPaths(raw).length || attached.length !== inputs) return undefined
  return attached
}

export const needsTheMac = (call: { raw: string; commands: ModKitCommand[]; testBuild?: boolean }): string | undefined => {
  for (const command of call.commands) {
    const { words, program, script: file, verdict } = command
    const cmd = base(words[0] ?? '')
    if (cmd === 'osascript') {
      // A script whose text the reader never saw may do anything on the Mac: one piped in from what
      // cannot be read, a script file (#724: `osascript notify.scpt` ran while away; #730: one cat
      // pipes in), or a script it runs by name.
      if (program && 'unreadable' in program) return 'Run an AppleScript on the Mac'
      if (file) return 'Run an AppleScript on the Mac'
      if (verdict?.does === 'unreadable') return 'Run an AppleScript on the Mac'
      const script = scriptOf(command)
      if (SCRIPT_DIALOG.test(script)) return 'Show a dialog on the Mac'
      // Bringing an app forward runs (#1269); typing or clicking only into a test build.
      if (!SCRIPT_TYPES.test(script) || call.testBuild) continue
      const app = targetApp(call.raw)
      return app ? `Type into ${app}` : 'Type into an app'
    }
    if ((cmd === 'cliclick' || cmd === 'peekaboo') && !call.testBuild) {
      const app = targetApp(call.raw)
      return app ? `Click in ${app}` : `Click or type with ${cmd}`
    }
  }
  return undefined
}

/**
 * What a call to a tool other than Bash would show Dan on the Mac (#702), as its held row reads, or
 * undefined: the Artifact tool's open action, which opens a page in his browser for him to read.
 * Browser automation opening a page or a tab, by Playwright or in Chrome, is testing and runs
 * (#1269), as do reading a page already open and publishing a page.
 */
export const heldTool = (tool: string, input: Record<string, unknown>): string | undefined => {
  const url = typeof input.url === 'string' ? shown(input.url) : undefined
  if (tool === 'Artifact') return input.action === 'open' ? `Open ${url ?? 'the page'}` : undefined
  return undefined
}

/**
 * How a call held while Dan is away is refused: the grey card (its guard "Away") and the reason
 * Claude reads. One wording for every held call, this mod's own and one another guard holds through
 * `$.scopeModes.hold` (the keystroke guard, #707), so the two read the same (L605).
 */
export const heldRefusal = (label: string): { card: { guard: string; reason: string; safeWay: string }; deny: string } => ({
  card: { guard: 'Away', reason: `Held for when you are back: ${label}.`, safeWay: 'Claude publishes a private page for your phone instead.' },
  deny: `Held: Dan is away from the Mac, so "${label}" waits for him to come back. Publish what he needs to see as a private claude.ai page instead (the Artifact tool).`,
})

/**
 * The held while away card (design round, 2026-10-04): boxed, an amber heading, one row per held
 * thing with its own button and a thin line between rows. Undefined when nothing was held, so a
 * session that held nothing shows no card.
 */
export const heldCard = (held: readonly ScopeModesHeld[]): ModKitBandRow | undefined => {
  if (!held.length) return undefined
  const lines: ModKitBandRow['lines'] = [[{ text: 'Held while you were away', color: 'warning' }]]
  held.forEach((h, i) => {
    if (i > 0) lines.push({ divider: true })
    lines.push([{ text: `${h.label} ` }, { button: `held-${h.id}`, label: h.label.startsWith('Open') ? 'Open' : 'Do it' }])
  })
  return { mod: 'scope-modes', id: 'held', slot: 'held', frame: { kind: 'box' }, lines }
}
