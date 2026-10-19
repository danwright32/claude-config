import { update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'
import type { DesignRoundPass, DesignRoundPending, DesignRoundRecord, DesignRoundSubject } from '../types/index.d.ts'
import {
  CONTRACT,
  GUARD,
  ISSUE_READING,
  answerCounts,
  HEADER,
  NOT_LOOK,
  SETTLED_NO,
  SETTLED_SOURCE,
  SETTLED_YES,
  SKIP_NO,
  SKIP_SOURCE,
  SKIP_YES,
  SKILL,
  agentRefusal,
  callKey,
  callText,
  cannotCheck,
  changedRuns,
  contractOf,
  card,
  checked,
  dataOnlyChange,
  addedOntoFolder,
  shellBraces,
  afterVariable,
  editedText,
  forged,
  inScratchpad,
  isModHook,
  isModHookTs,
  drawsChange,
  isOwnRecord,
  isSwiftUI,
  joinedOnly,
  judgedByText,
  listed,
  lookKindIn,
  notLookWhy,
  isGroupPattern,
  isPattern,
  isTestPath,
  patternMayBeLook,
  relTo,
  shapeKind,
  shellVarPath,
  mentionedLookFiles,
  mentionsStore,
  namesScratchpad,
  modHookLogicOnly,
  modManifestOf,
  onScreenProblem,
  pathsOf,
  predates,
  READS_ONLY,
  ROUND_FILES,
  tempRoots,
  textsOf,
  type ModFile,
  refusal,
  resolvePath,
  shellOutcome,
  shellUnchecked,
  type ShellOutcome,
  settledOptions,
  settledQuestion,
  skipOptions,
  skipQuestion,
  subjectsOf,
  settledNotYet,
  settledTypedSaid,
  skipTyped,
  unreadable,
  unreadableCard,
  unreadPutBack,
  unsureCard,
  unsure,
} from './rules.ts'
import { errorText } from './mod-kit/skew.ts'

// Design round guard (claude-config#978). Dan, 2026-10-08: "claude should never design something
// without my input. If we can make this something that can't be ignored rather than just a memory,
// that would be great". Settled with him in a picker interview the same day: every edit that changes
// how a screen looks waits for a settled design round on its issue, unless he has said to skip them.
//
// - What counts (rules.ts lookKindIn): style files, screen and component files, SwiftUI views, in every
//   project, written by the shell (mod-kit's one write reader) or by any tool carrying a file path,
//   a tool known only to read it excepted (rules.ts READS_ONLY). A test file passes. A file in no git
//   checkout is in no project (a design round's own switcher in the scratchpad) and passes.
// - Settled: Dan's Settled to "Is this design settled?", the design rounds skill's closing picker
//   (metadata.source design-settled). Skipped: his Skip them to "Skip design rounds for this issue?",
//   asked about a refused call (metadata.source design-round-guard:<its id>), as ask before saving
//   asks (#777). The guard words both questions and their answers itself, and reads his choice from
//   the dialog's own result; an answer the call carries, his own typed words, a dialog that closed
//   while he was away, a subagent's question and any file Claude writes record nothing, and a write
//   to the guard's own record is refused.
// - Kept in the mod's store (this Mac, every session) under the project's main working tree and the
//   issue its branch names, or the branch; a new issue starts at yes (rules.ts subjectsOf). Settled
//   is for the project of the refused call, or of a path the question names, never the session's
//   folder (#1010).
// - Since #1010: an edit whose one change is a component's data prop passes unasked (rules.ts
//   dataOnlyChange), and the skip question's third answer, Not a look change, lets one refused call
//   through when it is sent again unchanged (`pass:<rules.ts callKey>` in the store).
// - A subagent is refused like the main session and told to stop and report; only the main session
//   asks Dan. Which loop a call runs in is known only at tool.call, so a subagent's call is judged
//   there; the main session's at tool.check, beneath every mod's tool.call hook and after the
//   settings hooks, so Dan is never asked about a call another guard refuses (#707, #875).
// - Since #1138: the skip question leads with `onScreen`, the session's plain sentence saying what on
//   screen changes or that nothing visible does, and names the file after it; without one nothing is
//   asked (rules.ts onScreenProblem). A typed answer to the skip question is said, to Dan in a toast
//   and to Claude, as not recorded, with the question to ask again; one to the settled question
//   counts as Not yet and is the next round's feedback (#1336, rules.ts settledTypedSaid). A mod's own hook file is judged by what it draws
//   (rules.ts modHookLogicOnly): an edit touching none of it passes unasked. Since #1248 the lines
//   it touches end where it ends (rules.ts changedSpan), so the untouched line below a change is not
//   read with it.
// - Since #1275: a mod's plain TypeScript hook file (rules.ts isModHookTs) counts too, judged by what
//   in it reaches what the mod draws (rules.ts drawsChange), read beside the mod's other hook files: a
//   line builder making mod-kit's text runs, dividers or buttons (manual steps' cardLines, where the
//   #1263 divider passed unasked), anything handed to a drawing call or used in JSX, and every name
//   those use. Any other edit there passes, as does every edit to a .ts file that draws nothing.
// - Since #1158: a git checkout or restore of such a file is judged by the lines it changes, against
//   what git puts back, by the edit's own rule (nothingShown), so undoing an edit it let through
//   passes; one git cannot read, or one beside any other command on the line (restoreAlone), is
//   judged whole, and the refusal says why. A refusal holds the change it refused, never the file.
// - Since #1191: a design round's working files go in the session's scratchpad (rules.ts
//   inScratchpad: Claude Code's temp folder, the session's id), in no checkout, so never held and
//   needing no issue or branch; a name a program only mentions and only joins onto a folder is read
//   there, not in the project, when the command names that scratchpad and the project has nothing
//   of that name (guessAt). Every refusal of a look changing edit says where a round's files go, so
//   a held round is never sent back to /design-rounds.
// - Since #1296: a value reaching a drawing call through a local or a parameter is followed (rules.ts
//   drawnParts), and a shell write to a mod's .ts hook file that draws nothing yet, whose result
//   cannot be read before it runs, is judged by the file it leaves (Dan, 2026-10-17: judge after, and
//   undo): one the command made draw, on an issue he has not answered for, is put back as it was,
//   with what the command wrote kept in the session's scratchpad first (afterShell).
// - Since #1322: an answer kept under an issue counts only when it carries the branch reading it was
//   kept by (rules.ts ISSUE_READING and answerCounts), since one kept before #1306 may sit under an
//   issue an agent branch's digits spelled. Such an answer is read as none and its issue asked again;
//   nothing in the store is deleted, and answers under a branch or a session still count.
// - Anything it cannot tell (the branch, the checkout, its own record) refuses, saying which.

const pendingRef = { plugin: 'design-round-guard', key: 'pending' } as const

// A subagent's calls the tool.call hook judged and let through, by tool_use_id: the tool.check hook
// beneath, which cannot see which loop a call runs in, does not judge them again.
const fromAgent = new Set<string>()

// #1296: a mod's .ts hook file a shell write may change, as it stood before the command ran: its path,
// checkout, name in its hooks folder, text (undefined for one not there) and the mod's hook files.
type Watched = { path: string; tree: string; name: string; before: string | undefined; files: ModFile[] }
// The main session's passing shell calls with files to read again once they ran, by tool_use_id: set
// by the tool.check hook, which judges them, and taken by the tool.call hook around them.
const watching = new Map<string, Watched[]>()
const WATCH_MAX = 64

// An error as words, a call to another mod's noun that failed for a member its loaded copy lacks said
// as the two mods out of step, never as the raw TypeError (#1299, mod-kit's one reader, hooks/skew.ts).
const message = (err: unknown) => errorText(err, 'design-round-guard')

// The arguments the tool takes, without the keys the engine carries beside them.
const argsOf = (e: Record<string, unknown>): Record<string, unknown> => {
  const { tool: _t, tool_use_id: _i, agentId: _a, consent: _c, ...input } = e
  return input
}

// `session`, the session's id, and `temps`, the temp folders Claude Code may keep it under, which
// together name its scratchpad (#1191).
type Where = { cwd: string; home: string; session: string; temps: string[] }
const whereOf = async ($: EngineInterface): Promise<Where> => ({
  cwd: await $.session.cwd(),
  home: (await $.env.get('HOME')) ?? '',
  session: await $.session.id(),
  temps: tempRoots(await $.env.get('CLAUDE_CODE_TMPDIR')),
})

// A name a program or a command only mentions, as a guess at a file it writes, placed in `folder`
// (#1151); only the word where that folder is unknown. Undefined for a design round's working file
// (#1191): where the command names the session's scratchpad, a relative name that `text` (where it
// was found) only ever joins onto a folder held elsewhere (rules.ts joinedOnly: `os.path.join(d,
// 'screen.css')`, `d / 'screen.css'`) and whose first part is not on the disk in
// `folder` is one joined onto the scratchpad folder the command names, never a file of the project.
// A name opened as written (`open('index.html')`), or whose first part is there (src/app/globals.css,
// src/app/new.css, an existing top level file), is still read in `folder`, and so is one the disk
// cannot answer for. What it cannot see (lessons review): the folder a join's variable holds, so a
// new top level look file joined onto the checkout by a program that also names the scratchpad passes.
// A name the shell spells through a variable (`$R/screen.css`) is where the command's own literal
// assignment of it puts it (rules.ts shellVarPath), judged as any path, so `$APP/globals.css` with
// APP the project's folder is held; one the command does not set is read as any name (lessons review).
// A name that looks absolute only because it is added onto a folder in a variable (`root +
// "/app/page.tsx"`, `f"{root}/app/page.tsx"`) is that folder's, read as a joined name (rules.ts
// addedOntoFolder, #1194): at the disk's root it was in no checkout, so it was never held.
// The shell's `${APP}/booker.css` (read as `/booker.css`) is its `$APP/booker.css`, judged by where
// the command sets APP (rules.ts shellBraces, lessons review of #1194), never as a joined name; one
// spelled after two variables is read as a name in `folder`, as a variable the command does not set is.
const guessAt = async ($: EngineInterface, found: string, folder: string | undefined, at: Where, scratch: boolean, read: string, shell: string): Promise<Target | undefined> => {
  const braces = shellBraces(read, found)
  const unbrace = (s: string) => (braces === undefined ? s : s.replace(/\$\{([A-Za-z_]\w*)\}/g, '$$$1'))
  const said = braces === undefined ? found : braces.length === 1 ? `${braces[0]}${found}` : found.slice(1)
  const text = unbrace(read)
  const command = unbrace(shell)
  const added = addedOntoFolder(text, said)
  // After variables of more than one kind: in a folder the guard cannot read, never the root's.
  const relative = added || (braces === undefined && afterVariable(text, said))
  const m = relative ? said.slice(1) : said
  if (!relative && /^(\/|~(\/|$)|\$HOME\/|\$\{HOME\}\/)/.test(m)) return { path: resolvePath(m, '/', at.home), word: m }
  const set = shellVarPath(command, text, m)
  if (set !== undefined && (set.startsWith('/') || /^~(\/|$)/.test(set) || folder !== undefined)) return { path: resolvePath(set, folder ?? '/', at.home), word: m }
  if (folder === undefined) return { word: m }
  const path = resolvePath(m, folder, at.home)
  if (!scratch || inScratchpad(path, at.session, at.temps) || !joinedOnly(text, m)) return { path, word: m }
  const first = m.split('/').find(p => p !== '' && p !== '.') ?? m
  const there = await $.fs.exists(resolvePath(first, folder, at.home)).catch(() => true)
  return there ? { path, word: m } : undefined
}

// One file a call would write: its absolute path, or only the word naming it when the reader could
// not follow where that is; and the text it will hold, where the call carries it.
// `folder`, for a shell write whose name is a pattern, is where mod-kit's write reader placed it (#1123).
// `from`, for a git checkout or restore, is where git puts the file back from (#1158).
type Target = { path?: string; folder?: string; word: string; text?: string; from?: string }

// Every file a call writes or removes, and whether it may write the guard's own record where its
// words do not say what it writes.
const targetsOf = async ($: EngineInterface, tool: string, input: Record<string, unknown>, at: Where): Promise<{ targets: Target[]; storeMentioned: boolean }> => {
  // Every tool but the shell names the files it writes by a path in its input (lessons review of
  // #991): Write, Edit, MultiEdit, NotebookEdit and any tool added later, a reading tool excepted.
  if (tool !== 'Bash') {
    if (READS_ONLY.has(tool)) return { targets: [], storeMentioned: false }
    // A Write's content is the whole file; any other tool's text is judged beside the file as it is.
    const text = tool === 'Write' ? String(input.content ?? '') : undefined
    return { targets: pathsOf(input).map(word => ({ path: resolvePath(word, at.cwd, at.home), word, ...(text === undefined ? {} : { text }) })), storeMentioned: false }
  }
  const command = String(input.command ?? '')
  const w = await $.modkit.writes({ command, cwd: at.cwd, home: at.home })
  const targets: Target[] = []
  // Whether the command names the session's scratchpad, where a round's files go (#1191).
  const scratch = namesScratchpad(command, at.session, at.temps)
  for (const f of w.files) targets.push({ word: f.word, ...(f.path ? { path: f.path } : {}), ...(f.folder ? { folder: f.folder } : {}) })
  // A removal or an emptying changes the look as surely as a write; a stamp, a folder or a mode does not.
  for (const c of w.changes) if (c.does === 'remove' || c.does === 'truncate') targets.push({ word: c.word, ...(c.path ? { path: c.path } : {}), ...(c.folder ? { folder: c.folder } : {}) })
  // What git itself changes (#1136, Dan, 2026-10-13): a checkout of a path or a restore puts a file
  // back, git rm and git mv take it away or move it, each changing the look as a write does. A git
  // pathspec matched across folders (`:/x`, a pattern) has no path, so it is held as a write that
  // cannot be followed, or judged as a pattern. What a checkout or restore puts back is judged by the
  // lines it changes, as an edit is (#1158).
  for (const g of w.byGit ?? []) targets.push({ word: g.word, ...(g.path ? { path: g.path } : {}), ...(g.does === 'write' && g.from !== undefined ? { from: g.from } : {}) })
  for (const u of w.unnamed) {
    // A program whose text names every file it writes is judged by those files (#830).
    if (u.targets) {
      for (const t of u.targets) targets.push({ path: t, word: t })
      continue
    }
    // A program the reader read is judged by its own text, in the folder it runs in (#1151): the
    // command's other heredocs are another command's data (a design round's spec naming its
    // stylesheet), and a bare name lands where the program runs, never in the session's folder.
    // After a cd the reader cannot follow, a bare name's place is unknown, and is held as such.
    // Only the names it can open count (#1165): mod-kit's `code` blanks what it holds only as data (a
    // comment, a block spanning lines it puts in a file), so test data quoting app/page.tsx is not a
    // write to it. Where mod-kit cannot tell data from code it gives none, and the whole text is read.
    if (u.program !== undefined) {
      // Its own words count too: a file handed to it as an argument (`python3 - app/site.css <<EOF`,
      // read as sys.argv) is one it may write (lessons review of #1151). A -c program is one of its
      // words, read as its code instead.
      const read = [u.code ?? u.program, ...u.words.filter(x => x !== u.program)].join('\n')
      for (const m of mentionedLookFiles(read)) {
        const t = await guessAt($, m, u.folder, at, scratch, read, command)
        if (t) targets.push(t)
      }
      continue
    }
    // Otherwise what the command, and any patch or script file it reads, mentions is the guess.
    const texts = [command]
    for (const f of u.inputs) if (await $.fs.exists(f)) texts.push(await $.fs.read(f))
    const named = scratch || texts.slice(1).some(t => namesScratchpad(t, at.session, at.temps))
    for (const t of texts)
      for (const m of mentionedLookFiles(t)) {
        const g = await guessAt($, m, at.cwd, at, named, t, command)
        if (g) targets.push(g)
      }
  }
  // A write the words do not name, or a destination the reader could not follow, may be the record
  // when the command names the plugin store at all: refused, failing closed as ask before saving does
  // for lasting memory (lessons review of #991).
  const unfollowed = w.unnamed.length > 0 || targets.some(t => !t.path)
  return { targets, storeMentioned: unfollowed && mentionsStore(command) }
}

// Whether a Swift file is a SwiftUI view: the text the call carries, beside the file as it is now.
// Text that cannot be had (a file the shell writes, a file that cannot be read) counts as one.
const swiftView = async ($: EngineInterface, t: Target, tool: string, input: Record<string, unknown>): Promise<boolean> => {
  const texts: string[] = []
  if (t.text !== undefined) texts.push(t.text)
  // The text an edit carries (Edit's, each of MultiEdit's), judged beside the file as it is now.
  const carried = tool === 'Bash' || t.text !== undefined ? [] : textsOf(input)
  texts.push(...carried)
  if (t.path && t.text === undefined) {
    if (!(await $.fs.exists(t.path).catch(() => false))) return !carried.length || isSwiftUI(texts.join('\n'))
    try {
      texts.push(await $.fs.read(t.path))
    } catch {
      return true
    }
  }
  return isSwiftUI(texts.join('\n'))
}

type Place = { main: string; repo: string; branch: string; isDefault: boolean; issues: readonly number[] }
// Where a checkout stands, by mod-kit's one reading of it (#978), and the project's name by its one
// reading of a repository (#951); why not, with the project where git named it.
const placeOf = async ($: EngineInterface, tree: string): Promise<Place | { why: string; main?: string; repo?: string }> => {
  const b = await $.modkit.branch({ path: tree })
  if (b === null) return { why: `${tree} is in no git checkout` }
  const main = b.main ?? tree
  const repo = (await $.modkit.repo({ root: main, remote: null })).name ?? main
  if ('unreadable' in b) return { why: b.unreadable, ...(b.main ? { main, repo } : {}) }
  return { main, repo, branch: b.branch, isDefault: b.isDefault, issues: b.issues }
}


// What Dan's answers about a checkout are kept under: the one reading the judge and his Settled for a
// named project share, so a project is never read one way to hold an edit and another to settle it
// (#1010). With `issue`, that issue in the project, which git names even on a detached head.
const subjectsIn = async ($: EngineInterface, tree: string, issue?: number): Promise<{ subjects: DesignRoundSubject[] } | { why: string }> => {
  const place = await placeOf($, tree)
  if (issue !== undefined) {
    if (place.main === undefined || place.repo === undefined) return { why: 'why' in place ? place.why : 'no project named' }
    return { subjects: subjectsOf({ main: place.main, repo: place.repo, session: '', issue }) }
  }
  if ('why' in place) return { why: place.why }
  return { subjects: subjectsOf({ ...place, session: await $.session.id() }) }
}

// Dan's answer kept under `key`, when it is one and still counts: one kept under an issue counts only
// from the fixed branch reading on (rules.ts answerCounts, #1322), so an answer an agent branch's
// digits misfiled before #1306 is read as none, and nothing is deleted to get there.
const recordOf = (v: unknown, key: string): DesignRoundRecord | undefined => {
  const r = v as Partial<DesignRoundRecord> | undefined
  return r && (r.kind === 'settled' || r.kind === 'skipped') && typeof r.label === 'string' && answerCounts(key, r.reading) ? (r as DesignRoundRecord) : undefined
}

// Dan's Not a look change for this very call (#1010). A store that cannot be read here is read again
// by the judgement that follows, which refuses saying so.
const passKey = (key: string) => `pass:${key}`
// A call as it is known: its key and its whole text, from its tool and input, in the folder it runs
// in, in this session.
type Called = { key: string; call: string }
const keyOf = async ($: EngineInterface, tool: string, input: Record<string, unknown>): Promise<Called> => {
  const at = { cwd: await $.session.cwd(), session: await $.session.id() }
  return { key: callKey(tool, input, at), call: callText(tool, input, at) }
}
// His word authorises a call, so it is judged on its age when used (L567): the call is resent within
// moments of his answer, and an hour on, the same call is asked about again.
const PASS_LASTS_MS = 60 * 60 * 1000
const passed = async ($: EngineInterface, c: Called): Promise<boolean> => {
  try {
    const p = (await $.store.get(passKey(c.key))) as Partial<DesignRoundPass> | undefined
    // The key is a hash, so the record holds the call itself, which must be this one exactly.
    if (p?.kind !== 'not-look' || p.call !== c.call || typeof p.at !== 'number') return false
    return (await $.clock.now()) - p.at < PASS_LASTS_MS
  } catch {
    return false
  }
}

// What git puts back in a file a checkout or restore names (#1158): the text at `from` (mod-kit's
// spelling: a ref, '' for the index, ':2' or ':3' for a side of a conflict), read in the checkout the
// file is in. Why not, in words, where git cannot say: the ref is missing, git fails or cannot run, or
// its answer is too long to read whole. Never read as no change, nor as the file as it is.
const putBack = async ($: EngineInterface, path: string, tree: string, from: string): Promise<{ text: string } | { why: string }> => {
  const spec = `${from}:${relTo(path, tree)}`
  const said = `git cat-file blob ${spec}`
  // git would read a source spelled like an option as one (lessons review).
  if (from.startsWith('-')) return { why: `the command names its source as an option (${from}), which is never handed to git` }
  try {
    const r = await $.process.run(['git', '-C', tree, 'cat-file', 'blob', spec], { timeoutMs: 5000 })
    if (r.exitCode !== 0) return { why: `${said} exited ${r.exitCode}: ${r.stderr.trim().split('\n')[0] || 'with no message'}` }
    if (r.isStdoutTruncated) return { why: `${said} gave more than could be read whole` }
    return { text: r.stdout }
  } catch (err) {
    return { why: `${said} could not be run: ${message(err)}` }
  }
}

// Why what git puts back cannot be read before a shell call runs, or undefined when it can (lessons
// review of #1158): putBack reads the source as it stands now, and any other command on the line may
// change what that source names first (`git switch x && git checkout HEAD -- f`, `git add f && git
// restore f`, a script that runs git). So only a line that is one git checkout or restore alone, a cd
// before it aside, is measured; anything else is judged whole, saying so. So is git told to read
// another index, repository or setting: a GIT_ variable set on the line (which the command reader
// drops from a command's words), or any of git's own options before the subcommand but -C, whose
// folder mod-kit already follows (lessons review).
const restoreAlone = async ($: EngineInterface, command: string): Promise<string | undefined> => {
  try {
    const rest = (await $.modkit.pipeline({ command })).filter(c => c.words[0] !== 'cd')
    const words = rest.length === 1 ? (rest[0]?.words ?? []) : []
    const g = words.length ? await $.modkit.git({ words }) : undefined
    if (!(g?.sub === 'checkout' || g?.sub === 'restore')) return 'the command runs more than this one git checkout or restore, and what runs first may change what it puts back'
    const before = words.slice(1, words.indexOf(g.sub, 1))
    if (/(^|[^\w$])GIT_\w*=/.test(command) || !before.every((w, i) => i % 2 === 1 || w === '-C') || before.length % 2)
      return `the command sets how git reads its repository (${before.length ? before.join(' ') : 'a GIT_ variable'}), so what it puts back may not be what this checkout holds`
    return undefined
  } catch (err) {
    return `mod-kit could not read the command: ${message(err)}`
  }
}

// What a call changes in a React screen file (rules.ts judgedByText), as the text before and after it:
// an Edit, MultiEdit or Write naming one existing file, from the text the call leaves; a git checkout
// or restore, from what git puts back (#1158), or why that could not be read (`notAlone`, restoreAlone's
// answer for the call). Undefined for anything else (a shell write, a new file, a file that cannot be
// read, a call naming more than one file), which is never judged by its lines and is asked about.
type Change = { before: string; after: string } | { unread: string } | undefined
const changeOf = async ($: EngineInterface, t: Target & { path: string }, tree: string, tool: string, input: Record<string, unknown>, notAlone: string | undefined): Promise<Change> => {
  if (!judgedByText(t.path) || (tool === 'Bash' ? t.from === undefined : pathsOf(input).length !== 1)) return undefined
  let before: string
  try {
    if (!(await $.fs.exists(t.path))) return undefined
    before = await $.fs.read(t.path)
  } catch {
    return undefined
  }
  if (t.from === undefined) {
    const after = editedText(before, tool, input)
    return after === undefined ? undefined : { before, after }
  }
  if (notAlone !== undefined) return { unread: notAlone }
  const back = await putBack($, t.path, tree, t.from)
  return 'why' in back ? { unread: back.why } : { before, after: back.text }
}

// Whether changing a React screen file from `before` to `after` changes nothing on screen, the one
// rule an edit and a git checkout or restore are judged by (#1158): a component's data prop (rules.ts
// dataOnlyChange), or, in a mod's own hook file, logic outside what it draws (rules.ts
// modHookLogicOnly, #1138); judged whole, else one run of changed lines at a time (rules.ts
// changedRuns), as the separate edits a restore puts back were each judged.
const nothingShown = async ($: EngineInterface, path: string, tree: string, before: string, after: string): Promise<boolean> => {
  // Only a real Claude Code mod's folder, whose plugin.json says so; one that cannot be read is asked.
  const modHook = isModHook(relTo(path, tree)) && (await $.fs.exists(modManifestOf(path)).catch(() => false))
  const shows = (b: string, a: string) => !dataOnlyChange(b, a) && !(modHook && modHookLogicOnly(b, a))
  if (before === after || !shows(before, after)) return true
  const runs = changedRuns(before, after)
  return runs.length > 1 && runs.every(([b, a]) => !shows(b, a))
}

// Whether a call's change to a mod's plain TypeScript hook file (rules.ts isModHookTs) changes what the
// mod draws (#1275): 'held' when it does, or when the mod's hook files cannot be listed or read; the
// reason, for a git checkout or restore whose lines could not be read, judged whole; 'pass' otherwise,
// and for a folder no plugin.json makes a mod. What a call leaves: a Write's content, an Edit's or
// MultiEdit's text applied to the file, what git puts back (#1158). One that cannot be read before it
// runs (a shell write, an edit that would not apply, a call naming several files) is held where the
// file draws now and passes where it does not; a shell write passing so goes into `watch`, to be
// judged by the file it leaves once it ran (afterShell, #1296).
const drawingChange = async (
  $: EngineInterface,
  t: Target & { path: string },
  tree: string,
  tool: string,
  input: Record<string, unknown>,
  notAlone: string | undefined,
  watch: Watched[],
): Promise<'held' | 'pass' | { unread: string }> => {
  if (!(await $.fs.exists(modManifestOf(t.path)).catch(() => false))) return 'pass'
  const dir = t.path.slice(0, t.path.lastIndexOf('/'))
  const name = t.path.slice(dir.length + 1)
  const files: ModFile[] = []
  try {
    for (const e of await $.fs.list(dir))
      if (e.kind === 'file' && /\.(ts|tsx|mts|cts|jsx)$/i.test(e.name) && !/\.d\.[mc]?ts$/i.test(e.name)) files.push({ name: e.name, text: String(await $.fs.read(`${dir}/${e.name}`)) })
  } catch {
    return 'held'
  }
  const now = files.find(f => f.name === name)?.text
  let after: string | undefined
  if (t.from !== undefined) {
    if (notAlone !== undefined) return { unread: notAlone }
    const back = await putBack($, t.path, tree, t.from)
    if ('why' in back) return { unread: back.why }
    after = back.text
  } else if (tool !== 'Bash' && pathsOf(input).length === 1) after = tool === 'Write' ? editedText('', tool, input) : now === undefined ? undefined : editedText(now, tool, input)
  if (after === undefined) {
    if (drawsChange(files, name, undefined, now)) return 'held'
    // Once per file, however many of the command's words write it (lessons review).
    if (tool === 'Bash' && !watch.some(x => x.path === t.path)) watch.push({ path: t.path, tree, name, before: now, files })
    return 'pass'
  }
  return drawsChange(files, name, now, after) ? 'held' : 'pass'
}

type Verdict =
  | { pass: true; watch?: Watched[] }
  | { forged: string }
  | { unsure: string[]; why: string }
  | { unreadable: { files: string[]; subjects: DesignRoundSubject[]; why: string } }
  | { missing: { files: string[]; subjects: DesignRoundSubject[]; trees: string[]; unread: string[] } }

// The judgement every call gets, the main session's and a subagent's alike. Dan's Not a look change
// for this very call (#1010) is looked up only for a call that would otherwise wait on him, so no
// other call pays a store read for it (lessons review of #1010).
const judge = async ($: EngineInterface, tool: string, input: Record<string, unknown>): Promise<Verdict> => {
  const v = await judged($, tool, input)
  if (!('unsure' in v || 'missing' in v)) return v
  return (await passed($, await keyOf($, tool, input))) ? { pass: true } : v
}

const judged = async ($: EngineInterface, tool: string, input: Record<string, unknown>): Promise<Verdict> => {
  // Only the shell, and a tool carrying a file path it may write, can change a file at all.
  if (tool !== 'Bash' && (READS_ONLY.has(tool) || !pathsOf(input).length)) return { pass: true }
  const at = await whereOf($)
  const { targets, storeMentioned } = await targetsOf($, tool, input, at)
  // By its path, or by its name where the reader could not follow the folder (lessons review of #991).
  const own = targets.find(t => isOwnRecord(t.path ?? t.word))
  if (own) return { forged: own.path ?? own.word }
  if (storeMentioned) return { forged: 'the plugin store, which this command names' }

  // The look changing files, each with the checkout it is in; a file in none is in no project.
  const byTree = new Map<string, string[]>()
  // Per checkout, what a refusal says of a git checkout or restore whose lines could not be read (#1158).
  const unreadIn = new Map<string, string[]>()
  // restoreAlone's answer for this call once asked; null until then.
  let notAlone: string | undefined | null = null
  const unsureFiles: string[] = []
  // The mod .ts hook files a shell write passing now may change, read again once it ran (#1296).
  const watch: Watched[] = []
  const passing = (): Verdict => (watch.length ? { pass: true, watch } : { pass: true })
  let why = ''
  for (const t of targets) {
    // A name the shell expands as a pattern (#1015) is judged by every name it may expand to, and in
    // the checkout its folder is in, wherever mod-kit's write reader could place it (#1123): relative
    // or spelled from the top of the disk or home, a cd before it followed. A folder in no checkout is
    // in no project, whatever the name. A group (`x.(css|md)`) is read as a name by mod-kit, which
    // gives it a path.
    if (tool === 'Bash' && (t.path ? isGroupPattern(t.word.split('/').pop() ?? '') : isPattern(t.word))) {
      const folder = t.path ? t.path.slice(0, t.path.lastIndexOf('/')) || '/' : t.folder
      let tree: string | null | undefined
      if (folder !== undefined) {
        try {
          tree = await $.modkit.workingTree({ path: folder })
        } catch (err) {
          unsureFiles.push(t.word)
          why ||= `the disk could not say which checkout ${folder} is in: ${message(err)}`
          continue
        }
        if (tree === null) continue
      }
      const may = patternMayBeLook(t.word)
      if (may === 'not') continue
      const shown = t.path ?? (folder === undefined ? t.word : `${folder}/${t.word.split('/').pop() ?? ''}`)
      // In a checkout, a pattern there waits on that issue's answer as a named file does, and one in a
      // test folder passes; Dan's answer covers it. Read nowhere else: no Swift text, no edit.
      if (tree) {
        if (isTestPath(relTo(shown, tree))) continue
        const files = byTree.get(tree) ?? []
        if (!files.includes(shown)) files.push(shown)
        byTree.set(tree, files)
        continue
      }
      unsureFiles.push(t.word)
      why ||=
        may === 'unread'
          ? `where the command writes ${t.word} could not be followed, and its name is a pattern the design round guard cannot read, so it may name a look changing file`
          : `where the command writes ${t.word} could not be followed, and its name is a pattern that may name a look changing file`
      continue
    }
    const kind = shapeKind(t.path ?? t.word)
    // A mod's plain TypeScript hook file may build what the mod draws (#1275), judged below by that.
    const modTs = kind === null && t.path !== undefined && isModHookTs(t.path)
    if (kind === null && !modTs) {
      // A destination the reader could not follow, spelled with no look changing name, may still be
      // one when the command names a look changing file anywhere: held, as ask before saving holds
      // lasting memory (lessons review of #991). A command naming none runs. Only a name the shell
      // fills in itself (a variable or a command's output in its last part) may be one: `$D/spec.json`
      // is a spec wherever $D is, so what its heredoc's data names is data (#1151).
      const unknownName = /[$`]/.test(t.word.split('/').pop() ?? '')
      const named = !t.path && tool === 'Bash' && unknownName ? mentionedLookFiles(String(input.command ?? '')) : []
      if (named.length) {
        unsureFiles.push(t.word)
        why ||= `where the command writes ${t.word} could not be followed, and the command names ${listed(named)}`
      }
      continue
    }
    if (!t.path) {
      unsureFiles.push(t.word)
      why ||= `where the command writes ${t.word} could not be followed`
      continue
    }
    let tree: string | null
    try {
      tree = await $.modkit.workingTree({ path: t.path })
    } catch (err) {
      unsureFiles.push(t.path)
      why ||= `the disk could not say which checkout ${t.path} is in: ${message(err)}`
      continue
    }
    if (tree === null) continue
    // A test of a screen passes (Dan, 2026-10-08: "On, but let tests through"), judged by the path
    // inside its project, so a folder named tests above the checkout lets nothing through.
    if (modTs ? isTestPath(relTo(t.path, tree)) || !isModHookTs(relTo(t.path, tree)) : lookKindIn(t.path, tree) === null) continue
    // Only now is a Swift file read for SwiftUI, so a test is never read, nor held when it cannot be
    // (lessons review of #991).
    if (kind === 'swift' && !(await swiftView($, t, tool, input))) continue
    if (t.from !== undefined && (judgedByText(t.path) || modTs) && notAlone === null) notAlone = await restoreAlone($, String(input.command ?? ''))
    if (modTs) {
      const drawn = await drawingChange($, { ...t, path: t.path }, tree, tool, input, notAlone ?? undefined, watch)
      if (drawn === 'pass') continue
      if (drawn !== 'held') {
        const notes = unreadIn.get(tree) ?? []
        const said = unreadPutBack(relTo(t.path, tree), drawn.unread)
        if (!notes.includes(said)) notes.push(said)
        unreadIn.set(tree, notes)
      }
      const files = byTree.get(tree) ?? []
      if (!files.includes(t.path)) files.push(t.path)
      byTree.set(tree, files)
      continue
    }
    // An edit whose one change is a component's data prop changes nothing on screen (#1010), nor
    // does one to a mod's hook file that touches none of what it draws (#1138), nor a git checkout or
    // restore putting back only such lines (#1158). One whose lines git could not give is judged
    // whole, and the refusal says why.
    // restoreAlone is asked above, once per call, and only of one that puts back a file judged by its lines.
    const change = await changeOf($, { ...t, path: t.path }, tree, tool, input, notAlone ?? undefined)
    if (change && 'unread' in change) {
      const said = unreadPutBack(relTo(t.path, tree), change.unread)
      const notes = unreadIn.get(tree) ?? []
      if (!notes.includes(said)) notes.push(said)
      unreadIn.set(tree, notes)
    } else if (change && (await nothingShown($, t.path, tree, change.before, change.after))) continue
    const files = byTree.get(tree) ?? []
    if (!files.includes(t.path)) files.push(t.path)
    byTree.set(tree, files)
  }
  if (!byTree.size && !unsureFiles.length) return passing()

  const missingFiles: string[] = []
  const missing: DesignRoundSubject[] = []
  const missingTrees: string[] = []
  const unread: string[] = []
  for (const [tree, paths] of byTree) {
    const shown = paths.map(p => relTo(p, tree))
    const at = await subjectsIn($, tree)
    if ('why' in at) {
      unsureFiles.push(...shown)
      why ||= at.why
      continue
    }
    const { subjects } = at
    const lacking: DesignRoundSubject[] = []
    try {
      for (const s of subjects) if (!recordOf(await $.store.get(s.key), s.key)) lacking.push(s)
    } catch (err) {
      return { unreadable: { files: shown, subjects, why: message(err) } }
    }
    if (!lacking.length) continue
    missingFiles.push(...shown)
    missingTrees.push(tree)
    unread.push(...(unreadIn.get(tree) ?? []))
    for (const s of lacking) if (!missing.some(m => m.key === s.key)) missing.push(s)
  }
  if (unsureFiles.length) return { unsure: unsureFiles, why }
  if (missing.length) return { missing: { files: missingFiles, subjects: missing, trees: missingTrees, unread } }
  return passing()
}

// The grey card Dan sees, drawn by mod-kit as every guard's is. One that cannot be drawn does not
// change the refusal, which Claude reads whatever happens to the card.
const drawCard = async ($: EngineInterface, toolUseId: string, reason: string, safeWay: string) => {
  try {
    await $.modkit.blocked({ toolUseId, guard: GUARD, reason, safeWay })
  } catch (err) {
    $.ui.log(`design-round-guard: the card could not be drawn: ${message(err)}`, { to: 'debug' })
  }
}

// What a refused call is told, and the card drawn for it; a missing round is kept waiting on Dan.
const refuse = async ($: EngineInterface, v: Exclude<Verdict, { pass: true }>, call: { id: string; tool: string; agent: boolean; called: Called }): Promise<string> => {
  if ('forged' in v) {
    await drawCard($, call.id, "This would change the design round guard's own record.", 'Only your answers to its two questions write it.')
    return forged(v.forged)
  }
  if ('unsure' in v) {
    const c = unsureCard(v.unsure)
    await drawCard($, call.id, c.reason, c.safeWay)
    return unsure(v.unsure, v.why)
  }
  if ('unreadable' in v) {
    const u = v.unreadable
    const c = unreadableCard(u.files)
    await drawCard($, call.id, c.reason, c.safeWay)
    return unreadable(u.files, u.subjects, u.why)
  }
  const { files, subjects, trees, unread } = v.missing
  const waiting: DesignRoundPending = { id: call.id, tool: call.tool, files, subjects, trees, key: call.called.key, call: call.called.call, ...(call.agent ? { agent: true as const } : {}) }
  await update($, pendingRef, p => [...(p ?? []).filter(x => x.id !== call.id), waiting])
  const c = card(files, subjects)
  await drawCard($, call.id, c.reason, c.safeWay)
  return call.agent ? agentRefusal(files, subjects, call.id, unread) : refusal(call.id, files, subjects, unread)
}

// The session's scratchpad on the disk (#1296): `<temp>/claude-<uid>/<project>/<session id>/scratchpad`,
// found under each temp folder Claude Code may use, or undefined where it is in none.
const scratchpadOf = async ($: EngineInterface, at: Where): Promise<string | undefined> => {
  for (const root of at.temps) {
    const tops = await $.fs.list(root).catch(() => [])
    for (const c of tops) {
      if (c.kind !== 'dir' || !/^claude-\d+$/.test(c.name)) continue
      for (const p of await $.fs.list(`${root}/${c.name}`).catch(() => [])) {
        const dir = `${root}/${c.name}/${p.name}/${at.session}/scratchpad`
        if (p.kind === 'dir' && (await $.fs.exists(dir).catch(() => false))) return dir
      }
    }
  }
  return undefined
}

// A file's text as it stands, undefined for one not there.
const textNow = async ($: EngineInterface, path: string): Promise<string | undefined> => ((await $.fs.exists(path)) ? String(await $.fs.read(path)) : undefined)

// Puts back one mod hook file a shell write made draw (#1296, Dan, 2026-10-17: judge after, and undo),
// keeping what the command wrote first: written to the session's scratchpad and read back before
// anything is overwritten; put back only while the file still holds exactly what the command wrote;
// and a put back that fails is said, never called undone. A file the command made is taken away.
const undoOne = async ($: EngineInterface, w: Watched, after: string | undefined, file: string, keep: string | undefined): Promise<ShellOutcome> => {
  if (keep === undefined) return { file, unkept: "the session's scratchpad could not be found" }
  try {
    // `$.fs.write` makes the folders it needs (the engine's contract: "creating it and its
    // directories as needed"), so the scratchpad's design-round-guard folder is made here; and the
    // copy is read back, so one that did not land stops the undo rather than going unnoticed.
    await $.fs.write(keep, after ?? '')
    if (String(await $.fs.read(keep)) !== (after ?? '')) return { file, unkept: `the copy at ${keep} read back different from what the command wrote` }
  } catch (err) {
    return { file, unkept: message(err) }
  }
  let now: string | undefined
  try {
    now = await textNow($, w.path)
  } catch (err) {
    return { file, failed: `it could not be read again before putting it back: ${message(err)}`, kept: keep }
  }
  if (now !== after) return { file, changed: keep }
  try {
    if (w.before === undefined) {
      const rm = await $.process.run(['rm', '-f', '--', w.path])
      if (rm.exitCode !== 0) return { file, failed: rm.stderr.trim() || `rm exited ${rm.exitCode}`, kept: keep }
      if (await $.fs.exists(w.path)) return { file, failed: 'it is still there after rm', kept: keep }
    } else {
      await $.fs.write(w.path, w.before)
      if ((await textNow($, w.path)) !== w.before) return { file, failed: 'it read back different from its earlier text', kept: keep }
    }
  } catch (err) {
    return { file, failed: message(err), kept: keep }
  }
  return { file, undone: keep }
}

// After a shell call the guard let through (#1296): each mod .ts hook file it may have changed, read
// again. One it made draw, in a checkout whose issue Dan has not answered for (and not his Not a look
// change for this very call), is put back (undoOne) and the call waits on him as a refused edit does,
// its result withheld for the guard's words; one that cannot be read is said and waits alike.
const afterShell = async (
  $: EngineInterface,
  r: Awaited<ReturnType<EngineInterface['tool']['call']>>,
  watch: readonly Watched[],
  call: { id: string; tool: string; agent: boolean; input: Record<string, unknown> },
): Promise<typeof r> => {
  if (r.deny !== undefined) return r
  const changed: { w: Watched; after?: string; unread?: string }[] = []
  for (const w of watch) {
    let after: string | undefined
    try {
      after = await textNow($, w.path)
    } catch (err) {
      changed.push({ w, unread: message(err) })
      continue
    }
    if (after !== w.before && drawsChange(w.files, w.name, w.before, after)) changed.push({ w, after })
  }
  if (!changed.length) return r
  // What each waits on: its checkout's issue, unless Dan has answered for it.
  const lacking: DesignRoundSubject[] = []
  const trees: string[] = []
  const held: typeof changed = []
  // As the judgement before it ran (judged): a checkout whose issue cannot be told, then a record
  // that cannot be read, each said with its own reason, before any issue Dan has not answered for.
  const unknown: { files: string[]; why: string[] } = { files: [], why: [] }
  const unread: { files: string[]; subjects: DesignRoundSubject[]; why: string[] } = { files: [], subjects: [], why: [] }
  for (const c of changed) {
    const at = await subjectsIn($, c.w.tree)
    const file = relTo(c.w.path, c.w.tree)
    let open: DesignRoundSubject[] = []
    if ('why' in at) {
      unknown.files.push(file)
      unknown.why.push(at.why)
    } else
      try {
        for (const s of at.subjects) if (!recordOf(await $.store.get(s.key), s.key)) open.push(s)
      } catch (err) {
        unread.files.push(file)
        unread.subjects.push(...at.subjects)
        unread.why.push(message(err))
        open = at.subjects
      }
    if ('why' in at || open.length) {
      held.push(c)
      if (!trees.includes(c.w.tree)) trees.push(c.w.tree)
      for (const s of open) if (!lacking.some(x => x.key === s.key)) lacking.push(s)
    }
  }
  if (!held.length) return r
  const called = await keyOf($, call.tool, call.input)
  if (await passed($, called)) return r
  const at = await whereOf($)
  const scratch = await scratchpadOf($, at)
  const said: string[] = []
  for (const c of held) {
    const file = relTo(c.w.path, c.w.tree)
    if (c.unread !== undefined) said.push(shellOutcome({ file, unread: c.unread }))
    else said.push(shellOutcome(await undoOne($, c.w, c.after, file, scratch && `${scratch}/design-round-guard/${call.id}-${c.w.name}`)))
  }
  const files = held.map(c => relTo(c.w.path, c.w.tree))
  const v: Exclude<Verdict, { pass: true }> = unknown.files.length
    ? { unsure: unknown.files, why: unknown.why.join('; ') }
    : unread.files.length
      ? { unreadable: { files: unread.files, subjects: unread.subjects, why: unread.why.join('; ') } }
      : { missing: { files, subjects: lacking, trees, unread: [] } }
  const refused = await refuse($, v, { id: call.id, tool: call.tool, agent: call.agent, called })
  // What the command printed is never repeated here: only the tool's own result passes the secret
  // guard's scrub, so a secret it printed would reach Claude through this text (lessons review).
  return { deny: `${said.join(' ')} ${refused} What the command printed is withheld with this refusal.` }
}

// What a check with no call id is told: the refusal the call would meet, with no id to ask Dan under.
const previewed = (v: Exclude<Verdict, { pass: true }>): string => {
  if ('forged' in v) return forged(v.forged)
  if ('unsure' in v) return unsure(v.unsure, v.why)
  if ('unreadable' in v) return unreadable(v.unreadable.files, v.unreadable.subjects, v.unreadable.why)
  return checked(v.missing.files, v.missing.subjects, v.missing.unread)
}

// A refused call waiting on Dan, by its id: the one lookup the skip question and the settled question
// naming a call share, so both answer for the project the refused call is in (#1010).
// A refused call left waiting by the guard before #1010 kept no project, key or call text; after a
// mod reload in the same session it is not waiting, so the edit is made again rather than settled or
// let through on what it lacks (lessons review of #1010).
const waitingAll = async ($: EngineInterface): Promise<DesignRoundPending[]> =>
  ((await $.state.get(pendingRef)).value ?? []).filter(w => Array.isArray(w.trees) && typeof w.key === 'string' && typeof w.call === 'string')
const waitingOf = async ($: EngineInterface, id: string): Promise<DesignRoundPending | undefined> => (await waitingAll($)).find(x => x.id === id)

const NAME_PROJECT =
  'No refused edit is waiting, and the design round guard never takes the project from the folder this session runs in, so nothing was asked. ' +
  'Give metadata "path" with the absolute path of a folder or file in the checkout of the project this design is for (and "issue" when its branch names none), or "call" with the id a refusal named.'

// A path the settled question names that is not absolute: refused by name, never as though no path
// were given (#1046, where that read as the path being ignored), with the refused edits waiting.
const notAbsolute = (path: unknown, waiting: readonly DesignRoundPending[]): string =>
  `"${String(path)}" is not an absolute path, and the design round guard never reads a path from the folder this session runs in, so nothing was asked. ` +
  (waiting.length
    ? `Give metadata "call" with the id of the refused edit this design is for (${waiting.map(w => `${w.id}: ${listed(w.subjects.map(x => x.label))}`).join('; ')}), or "path" as an absolute path.`
    : 'Give metadata "path" as the absolute path of a folder or file in the checkout of the project this design is for.')

// The refused calls still waiting on an answer of Dan's: those whose subjects are not all answered.
const unanswered = async ($: EngineInterface): Promise<DesignRoundPending[]> => {
  const open: DesignRoundPending[] = []
  for (const w of await waitingAll($)) {
    let lacking = false
    for (const x of w.subjects) if (!recordOf(await $.store.get(x.key), x.key)) lacking = true
    if (lacking) open.push(w)
  }
  return open
}

// What an answer about a refused call records for: what that call waits on, the subjects the judge
// found it lacking, which is all that lets it through when it is sent again. The skip question and the
// settled question naming a call both answer through this (#1046: the settled question recorded only
// an issue it named, so the call, waiting on another, was refused again and every answer looped).
const waitsOn = (w: DesignRoundPending): DesignRoundSubject[] => [...w.subjects]
// An issue the settled question names is recorded beside them, in the call's project, never instead.
const callSubjects = async ($: EngineInterface, w: DesignRoundPending, issue: number | undefined): Promise<{ subjects: DesignRoundSubject[] } | { why: string }> => {
  const subjects = waitsOn(w)
  if (issue === undefined) return { subjects }
  for (const tree of w.trees) {
    const at = await subjectsIn($, tree, issue)
    if ('why' in at) return at
    for (const x of at.subjects) if (!subjects.some(y => y.key === x.key)) subjects.push(x)
  }
  return { subjects }
}

// What the settled question records for (#1010, where Dan's Settled landed on the session's folder,
// Slate, while the refused edit was on trypennie): the refused call it names; else the path it names;
// else the refused calls waiting in this session, when they all wait on the same answer. Never the
// session's folder. `from` is each waiting call the answer is about.
type Found = { subjects: DesignRoundSubject[]; from: DesignRoundPending[] } | { deny: string }
const settledFor = async ($: EngineInterface, issue: number | undefined, call: unknown, path: unknown): Promise<Found> => {
  const noProject = (why: string) => ({ deny: `The design round guard could not tell which project this is (${why}), so nothing was asked. Try again.` })
  const forCall = async (w: DesignRoundPending, from: DesignRoundPending[]): Promise<Found> => {
    const c = await callSubjects($, w, issue)
    return 'why' in c ? noProject(c.why) : { subjects: c.subjects, from }
  }
  const inTrees = async (trees: readonly string[], from: DesignRoundPending[]): Promise<Found> => {
    const subjects: DesignRoundSubject[] = []
    for (const tree of trees) {
      const at = await subjectsIn($, tree, issue)
      if ('why' in at)
        return {
          deny:
            issue === undefined
              ? `The design round guard could not tell which issue or branch this design is for (${at.why}), so nothing was asked. Give metadata "issue" with the issue number, or check out its branch.`
              : noProject(at.why).deny,
        }
      for (const x of at.subjects) if (!subjects.some(y => y.key === x.key)) subjects.push(x)
    }
    return { subjects, from }
  }
  if (call !== undefined) {
    if (typeof call !== 'string' || !call) return { deny: `"${String(call)}" names no refused call: give metadata "call" as the id the refusal named, or leave it out.` }
    const w = await waitingOf($, call)
    if (!w) return { deny: `No look changing edit is waiting under ${call}: it was answered already, or the session ended. Give metadata "path" with the project's folder instead.` }
    return forCall(w, [w])
  }
  if (path !== undefined) {
    const home = (await $.env.get('HOME')) ?? ''
    if (typeof path !== 'string' || !(path.startsWith('/') || (home && path.startsWith('~/')))) return { deny: notAbsolute(path, await unanswered($)) }
    const abs = resolvePath(path, '/', home)
    let tree: string | null
    try {
      tree = await $.modkit.workingTree({ path: abs })
    } catch (err) {
      return { deny: `The design round guard could not tell which checkout ${abs} is in (${message(err)}), so nothing was asked. Try again.` }
    }
    if (tree === null) return { deny: `${abs} is in no git checkout, so there is no project to settle the design for. Give metadata "path" with a folder or file in the project's checkout.` }
    return inTrees([tree], [])
  }
  const open = await unanswered($)
  const first = open[0]
  if (!first) return { deny: NAME_PROJECT }
  const sig = (w: DesignRoundPending) => w.subjects.map(x => x.key).sort().join('\n')
  if (open.some(w => sig(w) !== sig(first)))
    return { deny: `Refused edits are waiting on different answers (${open.map(w => `${w.id}: ${listed(w.subjects.map(x => x.label))}`).join('; ')}), so nothing was asked. Give metadata "call" with the id of the one this design is for.` }
  return forCall(first, open)
}

// The contract newer than this guard's that a question carries, or the design rounds skill on disk
// states, if either does (#1057). A skill that is not there, or states none, is no claim; one that is
// there and cannot be read is said in the debug log and judged by the question alone.
const newerContract = async ($: EngineInterface, carried: unknown): Promise<number | undefined> => {
  if (typeof carried === 'number' && Number.isInteger(carried) && carried > CONTRACT) return carried
  const home = (await $.env.get('HOME')) ?? ''
  if (!home) return undefined
  const path = `${home}/.claude/skills/${SKILL}/SKILL.md`
  try {
    if (!(await $.fs.exists(path))) return undefined
    const stated = contractOf(String(await $.fs.read(path)))
    return stated !== undefined && stated > CONTRACT ? stated : undefined
  } catch (err) {
    $.ui.log(`design-round-guard: the ${SKILL} skill could not be read for its contract: ${message(err)}`, { to: 'debug' })
    return undefined
  }
}

type AskInput = { questions?: { question?: unknown }[]; answers?: unknown; metadata?: { source?: unknown; issue?: unknown; call?: unknown; path?: unknown; contract?: unknown; onScreen?: unknown }; agentId?: string }
type AskResult = { answers?: Record<string, unknown>; questions?: { question?: unknown }[]; afkTimeoutMs?: unknown }

export const register: Register = on => {
  // A subagent's call, judged where its loop is known: refused like the main session's, and told to
  // stop and report rather than ask Dan. One it lets through is not judged again beneath.
  on('tool.call', async ($, e, next) => {
    if (e.agentId === undefined || e.tool === 'AskUserQuestion') return next(e)
    const raw = e as unknown as Record<string, unknown>
    const id = String(raw.tool_use_id ?? '')
    const input = argsOf(raw)
    const v = await judge($, e.tool, input)
    // An empty id names no call to wait under: refused as a check with no id is (lessons review of #991).
    if (!('pass' in v)) return { deny: id ? await refuse($, v, { id, tool: e.tool, agent: true, called: await keyOf($, e.tool, input) }) : previewed(v) }
    // An empty id names no one call, so it is never marked: any other call carrying it would skip its
    // judgement (lessons review of #991). Such a call is judged again beneath, the same way.
    if (!id) return next(e)
    fromAgent.add(id)
    let r: Awaited<ReturnType<typeof next>>
    try {
      r = await next(e)
    } finally {
      fromAgent.delete(id)
    }
    // A shell write that may have made a mod's .ts hook file draw, judged by what it left (#1296).
    if (!v.watch) return r
    try {
      return await afterShell($, r, v.watch, { id, tool: e.tool, agent: true, input })
    } catch (err) {
      return r.deny !== undefined ? r : { ...r, context: [...(r.context ?? []), shellUnchecked(message(err))] }
    }
  }).catch(($, e, next) => ({ deny: cannotCheck(message(next.error)) }))

  // The main session's shell call, around the tool.check judgement beneath: one that passed with mod
  // .ts hook files to read again (watching) is judged by what it left once it ran (#1296). The check
  // having run, a failure here never says the call was stopped: it ran.
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if (e.agentId !== undefined) return next(e)
    const id = String((e as unknown as Record<string, unknown>).tool_use_id ?? '')
    let r: Awaited<ReturnType<typeof next>>
    let watch: Watched[] | undefined
    try {
      r = await next(e)
    } finally {
      watch = id ? watching.get(id) : undefined
      if (id) watching.delete(id)
    }
    if (!watch) return r
    try {
      return await afterShell($, r, watch, { id, tool: e.tool, agent: false, input: argsOf(e as unknown as Record<string, unknown>) })
    } catch (err) {
      return r.deny !== undefined ? r : { ...r, context: [...(r.context ?? []), shellUnchecked(message(err))] }
    }
  })

  // The main session's call, judged beneath every mod's tool.call hook. A call that passes goes on
  // untouched; one that is refused goes to the settings hooks first, so a call one of them refuses is
  // refused in its words and never turned into a question for Dan.
  on('tool.check', async ($, e, next) => {
    if (e.tool_use_id !== undefined && fromAgent.has(e.tool_use_id)) return next(e)
    const input = (e.input ?? {}) as Record<string, unknown>
    const v = await judge($, e.tool, input)
    if ('pass' in v) {
      const decided = await next(e)
      // Read again once it ran, by the tool.call hook around this one (#1296): only a call the checks
      // beneath let run, and never more than WATCH_MAX at once, since a check asked with an id that
      // no call follows ($.tool.check) is never taken (lessons review).
      if (v.watch && e.tool_use_id && decided.decision !== 'deny') {
        watching.set(e.tool_use_id, v.watch)
        while (watching.size > WATCH_MAX) watching.delete(watching.keys().next().value as string)
      }
      return decided
    }
    const decided = await next(e)
    if (decided.decision === 'deny') return decided
    // A check asked with no call id ($.tool.check) runs nothing: it is answered as the call would be,
    // with no card drawn and nothing left waiting on Dan (lessons review of #991).
    if (!e.tool_use_id) return { decision: 'deny', reason: previewed(v) }
    return { decision: 'deny', reason: await refuse($, v, { id: e.tool_use_id, tool: e.tool, agent: false, called: await keyOf($, e.tool, input) }) }
  }).catch(($, e, next) => ({ decision: 'deny', reason: cannotCheck(message(next.error)) }))

  // Dan's two questions, asked in Claude Code's own dialog. The guard words each question and its
  // answers, and reads his choice from the dialog's own result, the one place it comes from him.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    const ask = e as unknown as AskInput
    const source = ask.metadata?.source
    if (typeof source !== 'string') return next(e)
    const isSkip = source.startsWith(`${SKIP_SOURCE}:`)
    if (!isSkip && source !== SETTLED_SOURCE) return next(e)

    // Asked of Dan with the guard's own question and answers; his choice read back, or why there is none.
    const asked = async (question: string, options: { label: string; description: string }[]): Promise<{ r: Awaited<ReturnType<typeof next>>; chosen?: string; none?: string }> => {
      const r = await next({ ...e, questions: [{ question, header: HEADER, options, multiSelect: false }] } as typeof e)
      if (r.deny !== undefined || r.isError) return { r, none: '' }
      const out = (r.result ?? {}) as AskResult
      const shown = typeof out.questions?.[0]?.question === 'string' ? (out.questions[0].question as string) : question
      if (out.afkTimeoutMs !== undefined) return { r, none: 'Dan did not answer: the dialog closed by itself while he was away, so nothing is recorded. Ask him again when he is back.' }
      const chosen = out.answers?.[shown] ?? out.answers?.[question]
      if (typeof chosen !== 'string' || !chosen.trim()) return { r, none: 'Dan gave no answer, so nothing is recorded. Ask him again, or leave it.' }
      return { r, chosen }
    }
    // What Claude is told beside Dan's answer, in the dialog's own result; a refusal carries none.
    const say = (r: Awaited<ReturnType<typeof next>>, text: string) => (r.deny !== undefined ? r : { ...r, context: [...(r.context ?? []), text] })
    // Dan's answer kept for each subject, one at a time: what was kept, and, when a write failed,
    // what was not and why, so a branch naming two issues is never told neither was kept when one
    // was (lessons review of #991).
    const record = async (subjects: readonly DesignRoundSubject[], kind: DesignRoundRecord['kind']): Promise<{ done: DesignRoundSubject[]; left: DesignRoundSubject[]; why?: string }> => {
      const done: DesignRoundSubject[] = []
      try {
        const now = await $.clock.now()
        for (const s of subjects) {
          await $.store.set(s.key, { kind, at: now, label: s.label, reading: ISSUE_READING } satisfies DesignRoundRecord)
          done.push(s)
        }
        return { done, left: [] }
      } catch (err) {
        return { done, left: subjects.filter(s => !done.includes(s)), why: message(err) }
      }
    }
    // What Claude is told when a write failed: what was recorded, if anything, and what stays blocked.
    const partly = (answer: string, kept: { done: DesignRoundSubject[]; left: DesignRoundSubject[]; why?: string }) => {
      const left = listed(kept.left.map(x => x.label))
      const head = kept.done.length
        ? `Dan answered ${answer}; it was recorded for ${listed(kept.done.map(x => x.label))}, but not for ${left} (${kept.why})`
        : `Dan answered ${answer}, but it could not be recorded (${kept.why})`
      return `${head}, so edits that change the look on ${left} stay blocked. Tell him, and ask again.`
    }

    // Dan typed an answer to the skip question instead of choosing one (#1138): nothing is recorded, and mod-kit's one
    // wording (#1145) tells him so in a toast and tells Claude to say so and ask again. A mod-kit that
    // cannot (one loaded before it had the member) is said, so Claude knows Dan was not told.
    const typed = async (r: Awaited<ReturnType<typeof next>>, chosen: string, parts: { still: string; again: string }) => {
      try {
        return say(r, await $.modkit.typedAnswer({ guard: GUARD, typed: chosen, ...parts }))
      } catch (err) {
        return say(r, `Dan typed "${chosen}" instead of choosing, so nothing is recorded, and ${parts.still}; mod-kit could not tell him so (${message(err)}). Tell him that in one line, answer what he said, then ${parts.again}.`)
      }
    }

    // What Claude is told to do with a refused call once Dan's answer lets it through.
    const again = (w: DesignRoundPending) =>
      w.agent ? 'The refused change was a subagent\'s: tell that agent, or a new one, to make it again, unchanged.' : `Send the ${w.tool} call to ${listed(w.files)} again now, unchanged.`

    const decide = async () => {
      if (e.agentId !== undefined) return { deny: 'Only the main session asks Dan about design rounds. Stop and report to the main session that this waits on him.' }
      // Steps newer than this guard (#1057): the version the question carries, or the skill on disk
      // states, past CONTRACT. Read before anything is asked or recorded, so Dan is never asked a
      // question whose answer this guard would misread.
      const carried = ask.metadata?.contract
      // A contract given in any other form is refused by name, never read as no claim (lessons review of #1057).
      if (carried !== undefined && !(typeof carried === 'number' && Number.isInteger(carried) && carried > 0))
        return { deny: `${JSON.stringify(carried)} is not a contract version: give metadata "contract" as the whole number the design rounds steps state, or leave it out.` }
      const newer = await newerContract($, carried)
      if (newer !== undefined) return { deny: predates(newer) }
      const questions = Array.isArray(ask.questions) ? ask.questions : []

      if (isSkip) {
        const id = source.slice(SKIP_SOURCE.length + 1)
        const waiting = await waitingOf($, id)
        if (!waiting) return { deny: `No look changing edit is waiting under ${id}: it was answered already, or the session ended. Make the edit again, and you will be told how to ask.` }
        if (questions.length !== 1) return { deny: 'Ask Dan one question: "Skip design rounds for this issue?".' }
        if (ask.answers !== undefined && (typeof ask.answers !== 'object' || ask.answers === null || Object.keys(ask.answers).length > 0))
          return { deny: 'Ask Dan without answers already filled in: only his choice in the dialog decides this.' }
        // What changes on screen, in the session's plain words, leads the question; without it nothing
        // is asked, never the file path in its place (#1138).
        const problem = onScreenProblem(ask.metadata?.onScreen, waiting.files)
        if (problem !== undefined) return { deny: problem }
        const onScreen = String(ask.metadata?.onScreen).trim()
        // Only what still has no answer of his is asked about and recorded: a subject he has since
        // settled keeps its settlement, never overwritten by a skip (lessons review of #991).
        // What the refused call waits on, as the settled question naming it reads it (#1046).
        const open: DesignRoundSubject[] = []
        for (const x of waitsOn(waiting)) if (!recordOf(await $.store.get(x.key), x.key)) open.push(x)
        if (!open.length) {
          await update($, pendingRef, p => (p ?? []).filter(x => x.id !== id))
          return { deny: `Nothing to ask: ${listed(waiting.subjects.map(x => x.label))} already has his answer, so the edit goes through. Make it again.` }
        }
        const s = listed(open.map(x => x.label))
        const { r, chosen, none } = await asked(skipQuestion(onScreen, waiting.files, open), skipOptions(open))
        if (chosen === undefined) return none ? say(r, none) : r
        // The call stays waiting until his Skip them is recorded, so an answer in his own words, a
        // Run /design-rounds he changes his mind on, or a record that failed can be asked about again
        // (lessons review of #991).
        if (chosen === SKIP_NO) return say(r, `Dan answered ${SKIP_NO}: start /design-rounds now, and ask its closing question with metadata {"source": "${SETTLED_SOURCE}", "call": "${id}"}. Nothing that changes the look is edited on ${s} until he answers ${SETTLED_YES} to it. ${ROUND_FILES}`)
        if (chosen === NOT_LOOK) {
          // His word that this one call changes nothing on screen, kept with why (#1010): the same
          // call sent again goes through, and nothing is recorded for the issue.
          try {
            const pass: DesignRoundPass = { kind: 'not-look', at: await $.clock.now(), tool: waiting.tool, files: waiting.files, subjects: open.map(x => x.label), why: notLookWhy(waiting.files), onScreen, call: waiting.call }
            await $.store.set(passKey(waiting.key), pass)
          } catch (err) {
            return say(r, `Dan answered ${NOT_LOOK}, but it could not be recorded (${message(err)}), so the edit to ${listed(waiting.files)} stays blocked. Tell him, and ask again.`)
          }
          await update($, pendingRef, p => (p ?? []).filter(x => x.id !== id))
          return say(r, `Dan answered ${NOT_LOOK}: this one edit to ${listed(waiting.files)} goes ahead, recorded as his word that it changes nothing on screen. ${again(waiting)} Any other edit that changes the look on ${s} is still held.`)
        }
        if (chosen !== SKIP_YES) return typed(r, chosen, skipTyped(waiting.files, open))
        const kept = await record(open, 'skipped')
        if (kept.why !== undefined) return say(r, partly(SKIP_YES, kept))
        await update($, pendingRef, p => (p ?? []).filter(x => x.id !== id))
        return say(r, `Dan answered ${SKIP_YES}: edits that change the look go ahead on ${s} without a design round, until the next issue. ${again(waiting)}`)
      }

      // The design rounds skill's closing question: settled for the project of the refused call it
      // names, of the refused calls waiting, or of the path it names, and for the issue it names
      // there, which Dan reads in it. Never for the session's own folder (#1010).
      const named = ask.metadata?.issue
      if (named !== undefined && !(typeof named === 'number' && Number.isInteger(named) && named > 0)) return { deny: `"${String(named)}" is not an issue number: give metadata "issue" as a number, or leave it out to settle the design for its branch's issue.` }
      if (questions.length !== 1) return { deny: 'Ask Dan one question: "Is this design settled?".' }
      if (ask.answers !== undefined && (typeof ask.answers !== 'object' || ask.answers === null || Object.keys(ask.answers).length > 0))
        return { deny: 'Ask Dan without answers already filled in: only his choice in the dialog decides this.' }
      const found = await settledFor($, typeof named === 'number' ? named : undefined, ask.metadata?.call, ask.metadata?.path)
      if ('deny' in found) return { deny: found.deny }
      const { subjects, from } = found
      const s = listed(subjects.map(x => x.label))
      const { r, chosen, none } = await asked(settledQuestion(subjects), settledOptions(subjects))
      if (chosen === undefined) return none ? say(r, none) : r
      if (chosen === SETTLED_NO) return say(r, `Dan answered ${SETTLED_NO}: ${settledNotYet}`)
      // A typed answer counts as Not yet, and is the next round's feedback (#1336).
      if (chosen !== SETTLED_YES) return say(r, settledTypedSaid(chosen))
      const kept = await record(subjects, 'settled')
      if (kept.why !== undefined) return say(r, partly(SETTLED_YES, kept))
      // Each refused call his answer covers in full can be sent again. It stays on the waiting list,
      // where a skip question about it is told it already has his answer.
      const done = new Set(kept.done.map(x => x.key))
      const resend = from.filter(w => w.subjects.every(y => done.has(y.key))).map(again)
      return say(r, `Dan answered ${SETTLED_YES}: the design is recorded as settled for ${s}, and edits that change the look go ahead there. Now write the settled design file the design rounds skill describes.${resend.length ? ` ${resend.join(' ')}` : ''}`)
    }
    try {
      return await decide()
    } catch (err) {
      return { deny: `The design round guard could not read Dan's answer (${message(err)}), so nothing is recorded. Ask him again.` }
    }
  })

  // Dropped at session end, a /clear included: a refused call waits on Dan only in its own session.
  on('session.end', async ($, e, next) => {
    await $.state.set(pendingRef, [])
    return next(e)
  })
}
