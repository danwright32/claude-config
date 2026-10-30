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
  bracketsOpen,
  commentOnlyChange,
  dataOnlyChange,
  shellUnread,
  targetUnread,
  addedOntoFolder,
  shellBraces,
  afterVariable,
  editedText,
  editWouldNotApply,
  stale,
  forged,
  inScratchpad,
  isModHook,
  isModHookTs,
  drawnParts,
  modHookTsHold,
  messageWordings,
  heldWords,
  type Worded,
  isOwnRecord,
  isDesignRecord,
  sealCheck,
  RECORD_REMOVED,
  scriptUnread,
  settledNotSealed,
  settledUnchecked,
  settledUnread,
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
  nameFromOutput,
  nameFromVariable,
  outputTrusted,
  relTo,
  shapeKind,
  shellVarPath,
  mentionedLookFiles,
  mentionsStore,
  namesScratchpad,
  modHookLogicOnly,
  modHookDrawingUntouched,
  messageWordingSame,
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
  skipIssueProblem,
  namedByIssue,
  subjectsOf,
  settledNotYet,
  settledTypedSaid,
  skipTyped,
  spoolNote,
  unreadable,
  unreadableCard,
  unreadPutBack,
  unsureCard,
  unsure,
} from './rules.ts'
import { errorText } from './mod-kit/skew.ts'
import { currentText, inputTexts, type Current } from './mod-kit/inputs.ts'

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
//   dataOnlyChange), and the skip question's third answer, Not a look or wording change, lets one refused call
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
//   those use. Any other edit there passes, as does every edit to a .ts file that draws nothing,
//   unless it changes the words of a message a person reads (since #1841, below).
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
// - Since #1341: an Edit, MultiEdit or Write changing only the comments of a mod's hook file, .ts, .tsx
//   or .jsx, a JSX comment standing between tags included, passes unasked (rules.ts
//   commentOnlyChange); words spelled like a comment in a string, JSX text or a quoted prop are what is
//   shown, and an app's screen file is not read so, since Tailwind reads its comments for classes.
// - Since #1576: a shell write to a mod's hook file, .ts, .tsx or .jsx, one that draws included, runs
//   and is judged by what it leaves, by the rule its Edit is (afterShell), so the two routes agree; and
//   a returned conditional is read as each value it may return (rules.ts drawnParts), so turning
//   `return c ? undefined : x` into ifs returning the same values draws nothing new.
// - Since #1740: Dan's Skip them on a builder's starting branch (worktree-agent-<id>) is also kept
//   under that worktree's own folder, and an issue a later branch of the SAME worktree names reads it
//   when the issue has no answer of its own (rules.ts worktreeKey, answerOf below), so renaming the
//   branch to name its issue does not ask him again. Never kept under the issue: another worktree,
//   the main checkout and any later builder are still asked (#1306). A settled round is not carried.
// - Since #1904: the skip question may carry metadata "issue", the issue a refused builder works on,
//   and a subject on its worktree-agent branch is then named "issue #N in <repo> (this builder
//   only)" in the question, its answers and the record's label (rules.ts namedByIssue). Where the
//   answer is kept does not change. Contract 3, raised with the design rounds skill.
// - Since #1911: the skip question's third answer reads "Not a look or wording change", and its
//   other answers name wording beside the look, since a hold can be for a message's words alone.
// - Since #1586: a script file a command runs (`python3 gen.py`, `bash x.sh`, `./tool`, make-settled.py)
//   writes what cannot be read before it runs, so each file it is handed as an argument (mod-kit's
//   `runs`) is judged as a write of it, as an Edit would be, and the refusal says why (rules.ts
//   scriptUnread); a settled design under docs/design handed to one is judged after it runs (#1593).
// - Since #1593: a settled design under docs/design a script run is handed is judged by what the run
//   leaves (afterShell), as a mod's hook file is: unchanged, or still sealed by the skill's own check,
//   it stands; otherwise, on an issue Dan has not answered for, it is put back, what the script wrote
//   kept first, and the call waits on him. Since #1682 mod-kit's `runs` also gives a module run with
//   python -m and a tool run through npx, each judged here as a script run is.
// - Since #1756: the words a mod hands mod-kit's blocked card (`$.modkit.blocked`: its guard name,
//   reason and safe way) are copy in a tool result row, not drawing, so a changed refusal passed (since
//   #1841 it is held again as a message's words); the card's look is mod-kit's own, judged in its
//   card.ts (rules.ts DRAW_CALL). And an Edit, MultiEdit
//   or Write leaving a mod's .ts hook file with a bracket open, half of a change made in two edits,
//   passes, the edit closing it judged against the file before the first (drawingChange, midEdits).
// - Since #1773: a pattern's groups (bash's extglob, zsh's alternation and qualifiers, a bar) are
//   read as the names they can spell, the characters as written among them (rules.ts
//   groupSpellings), where every group was unreadable and held. So a quoted code snippet a script is
//   handed (`'if (a || b) {'`), which spells no look changing name however it is read, runs, while a
//   group that may spell one (`'app/page.(tsx|md)'`) is held as before. A name ending inside a
//   command substitution is still unreadable, and zsh's globbing flags are read by no rule.
// - Since #1815: a tool run through npx or a module run with python -m (mod-kit's `tool`) handed a
//   name a command substitution fills in (`npx prettier --write $(git ls-files src)`) is held as a
//   name no rule reads (rules.ts nameFromOutput), where it named nothing judged and passed. A script
//   file handed one is judged as before: on this Mac every one measured was a commit, a test scope
//   or quoted text.
// - Since #1823: an Edit to a mod's .tsx or .jsx hook file held only for a drawing word (an import
//   naming StepsCard, a sentence naming the card) is read beside the mod's other hook files, as a .ts
//   one is, and passes where the lines it touches lie outside everything the mod draws and every
//   function that draws, no name what is drawn uses is imported anew, and the wording of every message
//   a person reads (a toast, a notification, a transcript line, a stop or refusal reason, a tool
//   result, a command's reply) is unchanged (rules.ts modHookDrawingUntouched and
//   messageWordingSame, in nothingShown; Dan, 2026-10-27: "Timing wording can go through, but
//   message wording should be asked about"). A JSX element or a colour in those lines is held as before.
// - Since #1841: a mod's .ts hook file is held for the same wording too, not only for what it draws
//   (rules.ts modHookTsHold: drawsChange, or messageWordingSame false), by an Edit, a git put back or
//   a shell write alike, so a toast, a refusal's reason or a tool's result reworded there is asked
//   about. When a message is sent, the logic around it, and a tool's or schema's description pass; a
//   property a tool's input schema names `reason` or `text` is no message. Only the words a person
//   reads count there (Dan, 2026-10-28: "Narrow it first"): a regular expression, a value compared,
//   a type's union, a command's words and flags, what a string is split, searched or keyed by, and a
//   string with no letter in it, which a message is only computed from, pass.
// - Since #1864: a one word tag passes too where its own place shows it is one (rules.ts readMod's
//   tagAt and answerTag): a field of a record that holds more than words (`kind: 'focus'`, an argv's
//   `'gh'`), an argument a function of the file only runs, searches or compares, and an answer the
//   function's own signature names. A .tsx or .jsx file's messages are read for their words the same
//   way, which releases the one edit #1823 held for a compared button name (Dan approved, 2026-10-28).
// - Since #1859: an edit held only because a message's words changed (rules.ts modHookTsHold for a
//   .ts file, wordsOnly for a .tsx or .jsx one) is refused saying so, naming the words, by its
//   refusal, its card and, for a shell write, what became of it, never that it changes how the
//   screen looks or what the mod draws (L11). What is held is unchanged; only what it says is.
// - Since #1832: a script file handed a name a command substitution fills in is held the same way,
//   unless every substitution in it is `git rev-parse`, alone or with -C (rules.ts outputTrusted; Dan,
//   2026-10-27: "git rev-parse only"), so a commit handed as `--sha` passes and a scope list is held.
// - Since #1925 and #1934: the words Dan reads in a mod's picker are a message's too (rules.ts
//   readMod): an answer's label and description, and the question's own text and header.
// - Since #1933: a shell command taking away a mod hook file git has never tracked (untracked, by
//   git's own index) passes, as a scratch copy a session made there by mistake holds no words of the
//   mod as it ships. A tracked one's removal is judged as before, and so is one git cannot answer for.
// - Since #1951: a pattern a script file is handed with every pattern character quoted or escaped
//   (mod-kit's `quoted`: the search term '*push*'), which the shell matched against no file, is
//   judged as the one file its characters name, so a quoted glob handed as data runs. A glob the
//   shell expands, one spelled bare anywhere in the command, a quoted name that is itself a look
//   changing or mod hook file's or holds a group, and any pattern handed to a tool are held as before.
// - Since #1953: a name a shell variable fills in, handed to a script or a tool, is held as a name no
//   rule reads (rules.ts nameFromVariable), as a command's output is; one the command sets to a plain
//   name is judged by that name, and a folder variable ($PWD, $HOME) names no file.
// - Since #1954: an Edit or MultiEdit the guard would hold that would not apply to the file as it
//   stands (rules.ts editWouldNotApply) is told so, to be sent again with the file's own text, with
//   no card and nothing asked of Dan, never held as a change it cannot read.
// - Anything it cannot tell (the branch, the checkout, its own record) refuses, saying which.

const pendingRef = { plugin: 'design-round-guard', key: 'pending' } as const

// A subagent's calls the tool.call hook judged and let through, by tool_use_id: the tool.check hook
// beneath, which cannot see which loop a call runs in, does not judge them again.
const fromAgent = new Set<string>()

// #1296: a mod's .ts hook file a shell write may change, as it stood before the command ran: its path,
// checkout, name in its hooks folder, text (undefined for one not there) and the mod's hook files.
// `tsx` for a TSX or JSX hook file (#1576), judged after by the rule its Edit is (nothingShown), where a
// .ts file is judged by rules.ts modHookTsHold over `files` (#1841, #1859). `record` for a settled design under docs/design a
// script run is handed (#1593), judged after by the design rounds skill's seal check (sealedAfter).
type Watched = { path: string; tree: string; name: string; before: string | undefined; files: ModFile[]; tsx?: true; record?: true }
// The main session's passing shell calls with files to read again once they ran, by tool_use_id: set
// by the tool.check hook, which judges them, and taken by the tool.call hook around them.
const watching = new Map<string, Watched[]>()
const WATCH_MAX = 64
// #1756: a mod's .ts hook file an Edit, MultiEdit or Write the guard let through left with a bracket
// open (rules.ts bracketsOpen), by its path, and its text before that edit, against which the edit
// closing it is judged. Kept in memory: after a reload such a file has no earlier text, and an edit to
// it is held, as every edit to a file the reader cannot follow was before.
const midEdits = new Map<string, string>()
const MID_EDITS_MAX = 64

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
// `run`, for a file a script run is handed as its argument, is that script's file (#1586).
// `tool`, on such a file, is set when the run is a tool through npx or a module through python -m (#1815).
// `removes`, for a file the shell command takes away (rm, unlink, the source mv moves), as mod-kit
// reads it, never one it empties or writes (#1933).
// `quoted`, for a pattern a script file is handed with every pattern character quoted, read as the
// one file its characters name (#1951).
type Target = { path?: string; folder?: string; word: string; text?: string; from?: string; run?: string; tool?: true; removes?: true; quoted?: true }

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
  for (const c of w.changes)
    if (c.does === 'remove' || c.does === 'truncate') targets.push({ word: c.word, ...(c.path ? { path: c.path } : {}), ...(c.folder ? { folder: c.folder } : {}), ...(c.does === 'remove' ? { removes: true as const } : {}) })
  // What git itself changes (#1136, Dan, 2026-10-13): a checkout of a path or a restore puts a file
  // back, git rm and git mv take it away or move it, each changing the look as a write does. A git
  // pathspec matched across folders (`:/x`, a pattern) has no path, so it is held as a write that
  // cannot be followed, or judged as a pattern. What a checkout or restore puts back is judged by the
  // lines it changes, as an edit is (#1158).
  for (const g of w.byGit ?? []) targets.push({ word: g.word, ...(g.path ? { path: g.path } : {}), ...(g.does === 'write' && g.from !== undefined ? { from: g.from } : {}) })
  // A script file the command runs (#1586, measured live on 2026-10-23: `python3 gen.py app/page.tsx`
  // and make-settled.py handed a page under docs/design were not held): what it writes cannot be read
  // before it runs, so each file it is handed as an argument is judged as a write of it, as an Edit of
  // that file would be. What it writes that no argument names (a path in its own text) is not read.
  // The spool helper's note writes none of what it is handed (#1747, rules.ts spoolNote).
  for (const r of w.runs ?? []) {
    if (spoolNote(r, at.home)) continue
    for (const a of r.args) {
      // A pattern the shell matched against no file, every pattern character quoted (#1951: the
      // search term '*push*' a sweep script was handed), reaches a script file as its characters, so
      // it is judged as the one file they name, as every other argument a script is handed is
      // (#1586): what a script then matches itself is what it chooses, which is not read, as with a
      // folder it is handed. Read so only where that name is no look changing file, no mod's hook
      // file and holds no group (#1773 reads groups as the names they spell); otherwise, and for a
      // tool, which expands its own operands (#1815), it is the pattern it was.
      const literal = a.quoted && !r.tool && a.folder ? `${a.folder}/${a.word.split('/').pop() ?? ''}` : undefined
      if (literal && shapeKind(literal) === null && !isModHookTs(literal) && !isModHook(literal) && !isGroupPattern(literal.split('/').pop() ?? '')) {
        targets.push({ word: a.word, path: literal, run: r.path ?? r.script, quoted: true })
        continue
      }
      targets.push({ word: a.word, ...(a.path ? { path: a.path } : {}), ...(a.folder ? { folder: a.folder } : {}), ...(r.tool ? { tool: true as const } : {}), run: r.path ?? r.script })
    }
  }
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
    // Otherwise what the command, and any patch or script file it reads, mentions is the guess. One it
    // reads from a device or a fifo is never opened (#1765), as a missing one never was: the read
    // waits for ever, and one fed on standard input is the heredoc, already in the command.
    const texts = [command, ...(await inputTexts({ exists: p => $.fs.exists(p), stat: (p, o) => $.fs.stat(p, o), read: p => $.fs.read(p) }, u.inputs))]
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
  // A quoted pattern read as its one name (#1951) is still one the script may match itself.
  const unfollowed = w.unnamed.length > 0 || targets.some(t => !t.path || t.quoted)
  return { targets, storeMentioned: unfollowed && mentionsStore(command) }
}

// Whether a Swift file is a SwiftUI view: the text the call carries, beside the file as it is now.
// Text that cannot be had (a file the shell writes, a file that cannot be read) counts as one. A file
// that is no ordinary file (a fifo, a link to a device) is never opened (#1814), counts as one, and
// says why, for the refusal to carry.
const swiftView = async ($: EngineInterface, t: Target, tool: string, input: Record<string, unknown>): Promise<boolean | { unreadable: string }> => {
  const texts: string[] = []
  if (t.text !== undefined) texts.push(t.text)
  // The text an edit carries (Edit's, each of MultiEdit's), judged beside the file as it is now.
  const carried = tool === 'Bash' || t.text !== undefined ? [] : textsOf(input)
  texts.push(...carried)
  if (t.path && t.text === undefined) {
    if (!(await $.fs.exists(t.path).catch(() => false))) return !carried.length || isSwiftUI(texts.join('\n'))
    let now: Current
    try {
      now = await targetNow($, t.path)
    } catch {
      return true
    }
    if ('unreadable' in now) return { unreadable: now.unreadable }
    if ('text' in now) texts.push(now.text)
  }
  return isSwiftUI(texts.join('\n'))
}

type Place = { main: string; repo: string; branch: string; isDefault: boolean; issues: readonly number[]; root: string }
// Where a checkout stands, by mod-kit's one reading of it (#978), and the project's name by its one
// reading of a repository (#951); why not, with the project where git named it.
const placeOf = async ($: EngineInterface, tree: string): Promise<Place | { why: string; main?: string; repo?: string }> => {
  const b = await $.modkit.branch({ path: tree })
  if (b === null) return { why: `${tree} is in no git checkout` }
  const main = b.main ?? tree
  const repo = (await $.modkit.repo({ root: main, remote: null })).name ?? main
  if ('unreadable' in b) return { why: b.unreadable, ...(b.main ? { main, repo } : {}) }
  return { main, repo, branch: b.branch, isDefault: b.isDefault, issues: b.issues, root: b.root }
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

// Dan's answer for a subject: its own, or, for an issue a linked worktree's later branch names, his
// skip on that worktree's starting worktree-agent branch (#1740, rules.ts worktreeKey). Every reader
// of whether a subject is answered asks here, so a carried skip never lets an edit through that the
// pending list or the skip question would still call open. A store that cannot be read throws, as
// each reader already handles.
const answerOf = async ($: EngineInterface, s: DesignRoundSubject): Promise<DesignRoundRecord | undefined> => {
  const own = recordOf(await $.store.get(s.key), s.key)
  if (own || s.carriedFrom === undefined) return own
  const carried = recordOf(await $.store.get(s.carriedFrom), s.carriedFrom)
  return carried?.kind === 'skipped' ? carried : undefined
}

// Dan's Not a look or wording change for this very call (#1010). A store that cannot be read here is read again
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

// #1933: whether git has never tracked the file at `path` in the checkout `tree`, by its own index
// (`git ls-files`, which names a tracked file, a staged one included, and prints nothing for any
// other). Matched literally, so a name holding a pattern's characters is no pattern, and in any case,
// as this Mac's disk finds a file. Anything git cannot answer counts as tracked, so the removal is
// judged as before rather than passed.
const neverTracked = async ($: EngineInterface, path: string, tree: string): Promise<boolean> => {
  try {
    const r = await $.process.run(['git', '-C', tree, 'ls-files', '-z', '--', `:(literal,icase)${relTo(path, tree)}`], { timeoutMs: 5000 })
    return r.exitCode === 0 && !r.isStdoutTruncated && r.stdout === ''
  } catch {
    return false
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
// read, a call naming more than one file), which is never judged by its lines and is asked about. A
// file that is no ordinary file (/dev/stdin, a fifo, a link to a device) is never opened (#1814) and
// is `unreadable`, with why, for the refusal to say.
type Change = { before: string; after: string } | { unread: string } | { unreadable: string } | undefined
const changeOf = async ($: EngineInterface, t: Target & { path: string }, tree: string, tool: string, input: Record<string, unknown>, notAlone: string | undefined): Promise<Change> => {
  if (!judgedByText(t.path) || (tool === 'Bash' ? t.from === undefined : pathsOf(input).length !== 1)) return undefined
  let before: string
  try {
    const now = await targetNow($, t.path)
    if ('unreadable' in now) return { unreadable: now.unreadable }
    if ('absent' in now) return undefined
    before = now.text
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
// changedRuns), as the separate edits a restore puts back were each judged. Since #1823 a change to a
// mod's hook file held only for a drawing word is read beside the mod's other hook files, as a .ts
// one is, and passes where it touches nothing the mod draws and changes no message's words (rules.ts
// modHookDrawingUntouched); hook files that cannot be listed or read leave it held. `words` false
// leaves the messages' wording out (#1859), only to tell a hold for wording alone (wordsOnly).
const nothingShown = async ($: EngineInterface, path: string, tree: string, before: string, after: string, words = true): Promise<boolean> => {
  // Only a real Claude Code mod's folder, whose plugin.json says so; one that cannot be read is asked.
  const modHook = isModHook(relTo(path, tree)) && (await $.fs.exists(modManifestOf(path)).catch(() => false))
  const name = path.slice(path.lastIndexOf('/') + 1)
  let files: ModFile[] | null | undefined
  const modFiles = async (): Promise<ModFile[] | null> => {
    if (files === undefined) files = await hookFilesBeside($, path)
    return files
  }
  // Whether a run passed only by the #1823 reading, so the whole change's message wording is asked.
  let readByDrawing = false
  const shows = async (b: string, a: string) => {
    if (dataOnlyChange(b, a)) return false
    if (!modHook) return true
    if (modHookLogicOnly(b, a) || commentOnlyChange(b, a, true)) return false
    const others = await modFiles()
    if (!others || !modHookDrawingUntouched(others, name, b, a, words)) return true
    readByDrawing = true
    return false
  }
  if (before === after || !(await shows(before, after))) return true
  const runs = changedRuns(before, after)
  if (runs.length < 2) return false
  readByDrawing = false
  for (const [b, a] of runs) if (await shows(b, a)) return false
  // Judged a run at a time, a message's new words in a run the word reading passes would slip
  // beside a run only #1823's reading let through, so the change as a whole keeps its wording.
  if (!readByDrawing || !words) return true
  const others = await modFiles()
  return !!others && messageWordingSame(others, name, before, after)
}

// The mod's other hook files beside the hook file `path`, each by name and text, or null where the
// folder cannot be listed or one of them read.
const hookFilesBeside = async ($: EngineInterface, path: string): Promise<ModFile[] | null> => {
  const dir = path.slice(0, path.lastIndexOf('/'))
  const name = path.slice(dir.length + 1)
  try {
    const read: ModFile[] = []
    for (const e of await $.fs.list(dir))
      if (e.kind === 'file' && e.name !== name && /\.(ts|tsx|mts|cts|jsx)$/i.test(e.name) && !/\.d\.[mc]?ts$/i.test(e.name)) read.push({ name: e.name, text: String(await $.fs.read(`${dir}/${e.name}`)) })
    return read
  } catch {
    return null
  }
}

// Whether a change nothingShown holds is held for a message's wording alone (#1859): it would pass
// with the wording left out. The words heldWords names when it is, so the refusal says that and never
// the screen's look (L11); undefined for any other hold, a look change or one that cannot be read.
const wordsOnly = async ($: EngineInterface, path: string, tree: string, before: string, after: string): Promise<string | undefined> => {
  if (!(await nothingShown($, path, tree, before, after, false))) return undefined
  const others = await hookFilesBeside($, path)
  const w = others && messageWordings(others, path.slice(path.lastIndexOf('/') + 1), before, after)
  return w ? heldWords(w.said, w.says) : undefined
}

// Whether a call's change to a mod's plain TypeScript hook file (rules.ts isModHookTs) changes what the
// mod draws (#1275) or a message's words (#1841, rules.ts modHookTsHold): 'held' when it does, or
// when the mod's hook files cannot be listed or read, and `worded` with the words heldWords names where
// only a message's wording changes (#1859, rules.ts modHookTsHold); the
// reason, for a git checkout or restore whose lines could not be read, judged whole; 'pass' otherwise,
// and for a folder no plugin.json makes a mod. What a call leaves: a Write's content, an Edit's or
// MultiEdit's text applied to the file, what git puts back (#1158). A shell write, which cannot be read
// before it runs, passes into `watch`, to be judged by the file it leaves once it ran (afterShell): one
// to a file that drew nothing since #1296, and since #1576 one to a file that draws too, so a shell
// write and an Edit making the same change are judged alike. Any other call that cannot be read before
// it runs (an edit that would not apply, a call naming several files) is held where the file draws
// or sends a message now and passes where it does neither; an Edit or MultiEdit so held that would not
// apply at all is then told so instead (judged, #1954). A change to its comments alone passes (rules.ts commentOnlyChange,
// #1341).
const drawingChange = async (
  $: EngineInterface,
  t: Target & { path: string },
  tree: string,
  tool: string,
  input: Record<string, unknown>,
  notAlone: string | undefined,
  watch: Watched[],
): Promise<'held' | 'pass' | { unread: string } | { worded: string }> => {
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
    // Held where the file draws or sends a message now. One that only sends a message is held for a
    // message's words (#1859), naming none: which would change cannot be read.
    if (tool !== 'Bash') {
      const hold = modHookTsHold(files, name, undefined, now)
      return !hold ? 'pass' : 'worded' in hold ? { worded: '' } : 'held'
    }
    // A file whose drawing cannot be read now could not be judged after either: held.
    if (drawnParts(files, name) === null) return 'held'
    // Once per file, however many of the command's words write it (lessons review).
    if (!watch.some(x => x.path === t.path)) watch.push({ path: t.path, tree, name, before: now, files })
    return 'pass'
  }
  if (now !== undefined && commentOnlyChange(now, after, /\.(tsx|jsx)$/i.test(name))) return 'pass'
  // #1756: a change made in more than one edit can leave a bracket open between them, as the #1747
  // builder's Edit giving a loop its opening brace did. That text is no TypeScript, so it draws
  // nothing: the edit leaving it passes, and the one closing it is judged against the file as it was
  // before the first, so a look change made across the edits is still held. Only by Edit, MultiEdit
  // or Write: a shell write to such a file is held whole, as before (git's put back never gets here).
  if (t.from === undefined && /\.(ts|mts|cts)$/i.test(name) && now !== undefined) {
    const was = midEdits.get(t.path)
    const nowOpen = bracketsOpen(now)
    if (!nowOpen) midEdits.delete(t.path)
    if (bracketsOpen(after)) {
      if (!nowOpen && drawnParts(files, name) !== null) {
        if (midEdits.size >= MID_EDITS_MAX) midEdits.delete(midEdits.keys().next().value as string)
        midEdits.set(t.path, now)
        return 'pass'
      }
      if (nowOpen && was !== undefined) return 'pass'
    } else if (nowOpen && was !== undefined) {
      const hold = modHookTsHold(files, name, was, after)
      if (hold) return 'worded' in hold ? hold : 'held'
      midEdits.delete(t.path)
      return 'pass'
    }
  }
  const hold = modHookTsHold(files, name, now, after)
  return !hold ? 'pass' : 'worded' in hold ? hold : 'held'
}

// The file a command copies whole into `path`, when the command is one cp alone with no option, naming
// its source and destination in plain words (no variable, pattern or brace the shell would change), so
// the source as it is now is what lands (#1524); else why what it leaves cannot be read before it runs.
const copiedFrom = async ($: EngineInterface, command: string, path: string, at: Where): Promise<string | { why: string }> => {
  const shell = { why: 'a shell command, whose result cannot be read before it runs unless it is one plain cp alone' }
  let cmds: Awaited<ReturnType<EngineInterface['modkit']['pipeline']>>
  try {
    cmds = await $.modkit.pipeline({ command })
  } catch (err) {
    return { why: `mod-kit could not read the command: ${message(err)}` }
  }
  const only = cmds.length === 1 ? cmds[0] : undefined
  const [cp, src, dest, ...more] = only?.words ?? []
  if (!only || cp !== 'cp' || src === undefined || dest === undefined || more.length || only.pipedFrom || only.heredocs || only.xargs || only.substitution) return shell
  if ([src, dest].some(w => w.startsWith('-') || /[$`*?[\]{}]/.test(w))) return shell
  if (resolvePath(dest, at.cwd, at.home) !== path) return shell
  return resolvePath(src, at.cwd, at.home)
}

// What a call leaves in a settled design's place under docs/design (#1524), read before it runs: a
// Write's content; an Edit's or MultiEdit's change applied to the file as it is; what a git checkout or
// restore alone puts back (putBack, `notAlone` being restoreAlone's answer); what a cp alone copies in
// whole, read from its source. Anything else is why it cannot be read.
const recordText = async (
  $: EngineInterface,
  t: Target & { path: string },
  tree: string,
  tool: string,
  input: Record<string, unknown>,
  at: Where,
  notAlone: string | undefined,
): Promise<{ text: string } | { why: string }> => {
  if (tool !== 'Bash') {
    if (pathsOf(input).length !== 1) return { why: 'the call names more than one file' }
    let before = ''
    if (tool !== 'Write') {
      try {
        const now = await targetNow($, t.path)
        if ('absent' in now) return { why: 'the file is not there to change' }
        // Never opened (#1814): a read of /dev/stdin or a fifo waits for ever.
        if ('unreadable' in now) return { why: `the file could not be read: ${now.unreadable}` }
        before = String(now.text)
      } catch (err) {
        return { why: `the file could not be read: ${message(err)}` }
      }
    }
    const after = editedText(before, tool, input)
    return after === undefined ? { why: 'what the call writes could not be read from it' } : { text: after }
  }
  if (t.from !== undefined) {
    if (notAlone !== undefined) return { why: notAlone }
    const back = await putBack($, t.path, tree, t.from)
    return 'why' in back ? { why: back.why } : { text: back.text }
  }
  const src = await copiedFrom($, String(input.command ?? ''), t.path, at)
  if (typeof src !== 'string') return src
  // What it copies, never opened when it is /dev/stdin or a fifo (#1814): a read of one waits for ever.
  try {
    const from = await targetNow($, src)
    if ('unreadable' in from) return { why: `${src}, which it copies, could not be read: ${from.unreadable}` }
    if ('absent' in from) return { why: `${src}, which it copies, could not be read: it is not there` }
    return { text: String(from.text) }
  } catch (err) {
    return { why: `${src}, which it copies, could not be read: ${message(err)}` }
  }
}

// Whether a call writes a settled design under docs/design exactly as make-settled.py wrote and sealed
// it (#1524, Dan, 2026-10-23: "Let it through"): true, judged by the design rounds skill's own check
// of the text the call leaves (rules.ts sealCheck), never by the blocks being there, since a hand edited
// file still carries them. Otherwise what the refusal says of the file: the check's own reason, why the
// text could not be read first, or why the check could not be run, each held, never passed.
const settledRecord = async (
  $: EngineInterface,
  t: Target & { path: string },
  tree: string,
  tool: string,
  input: Record<string, unknown>,
  at: Where,
  notAlone: string | undefined,
): Promise<true | string> => {
  const file = relTo(t.path, tree)
  const r = await recordText($, t, tree, tool, input, at, notAlone)
  if ('why' in r) return settledUnread(file, r.why)
  return sealed($, file, r.text, at.home)
}

// Whether `text` is a settled design exactly as make-settled.py wrote and sealed it, by the design
// rounds skill's own check (rules.ts sealCheck): true, or what the refusal says of `file`, the check's
// own reason or why it could not be run, each held, never passed. The one reading a call's text before
// it runs (settledRecord) and a script run's after it ran (sealedAfter, #1593) share.
const sealed = async ($: EngineInterface, file: string, text: string, home: string): Promise<true | string> => {
  const argv = sealCheck(home)
  try {
    const run = await $.process.run(argv, { stdin: text, timeoutMs: 10_000 })
    if (run.exitCode === 0 && run.stdout.trim() === 'sealed') return true
    const said = run.stdout.trim().replace(/^not sealed: /, '')
    if (run.exitCode === 1 && said) return settledNotSealed(file, said)
    return settledUnchecked(file, `${argv.join(' ')} exited ${run.exitCode}: ${run.stderr.trim().split('\n')[0] || 'with no message'}`)
  } catch (err) {
    return settledUnchecked(file, message(err))
  }
}

// What a script run left in a settled design's place under docs/design (#1593), read once it ran:
// undefined while it is still a settled design exactly as make-settled.py sealed it, else what the
// refusal says of it. One the run took away is no settled design.
const sealedAfter = async ($: EngineInterface, w: Watched, after: string | undefined): Promise<string | undefined> => {
  const file = relTo(w.path, w.tree)
  if (after === undefined) return settledNotSealed(file, RECORD_REMOVED)
  const s = await sealed($, file, after, (await $.env.get('HOME')) ?? '')
  return s === true ? undefined : s
}

// `worded`, the files held only for a message's wording, with its words (#1859), which a refusal says
// in place of the screen's look.
// `stale`, the file an Edit or MultiEdit that would not apply names (#1954), which is told so rather
// than held for Dan.
type Verdict =
  | { pass: true; watch?: Watched[] }
  | { forged: string }
  | { stale: string }
  | { unsure: string[]; why: string; worded?: Worded[] }
  | { unreadable: { files: string[]; subjects: DesignRoundSubject[]; why: string; worded?: Worded[] } }
  | { missing: { files: string[]; subjects: DesignRoundSubject[]; trees: string[]; unread: string[]; worded?: Worded[] } }

// The judgement every call gets, the main session's and a subagent's alike. Dan's Not a look or wording change
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
  // Per checkout, what a refusal says of a git checkout or restore whose lines could not be read (#1158),
  // or of a shell write to a mod hook file, which cannot be read before it runs (#1341).
  const unreadIn = new Map<string, string[]>()
  // restoreAlone's answer for this call once asked; null until then.
  let notAlone: string | undefined | null = null
  const unsureFiles: string[] = []
  // The mod .ts hook files a shell write passing now may change, read again once it ran (#1296).
  const watch: Watched[] = []
  // The files held only for a message's wording (#1859), as a refusal names them.
  const worded: Worded[] = []
  // Each file an Edit, MultiEdit or Write names, with the checkout it is in, read for an edit that
  // would not apply (#1954).
  const editedIn = new Map<string, string>()
  const passing = (): Verdict => (watch.length ? { pass: true, watch } : { pass: true })
  let why = ''
  for (const t of targets) {
    // A name the shell expands as a pattern (#1015) is judged by every name it may expand to, and in
    // the checkout its folder is in, wherever mod-kit's write reader could place it (#1123): relative
    // or spelled from the top of the disk or home, a cd before it followed. A folder in no checkout is
    // in no project, whatever the name. A group (`x.(css|md)`) is read as a name by mod-kit, which
    // gives it a path.
    // A name a command's output fills in, handed to a tool through npx or a module through python -m
    // (#1815: `npx prettier --write $(git ls-files src)`), is judged the same way, as a name no rule
    // reads. So is one a script file is handed (#1832), unless every substitution in it is
    // `git rev-parse` run alone, the one output Dan trusts to name no file (2026-10-27, picker
    // answer "git rev-parse only"): `--sha "$(git rev-parse HEAD)"` passes, a test scope list
    // (`$(cat scope.txt)`) is held.
    const output = !t.path && nameFromOutput(t.word) && (t.tool === true || !outputTrusted(t.word))
    // A name a shell variable fills in, handed to a script or a tool (#1953: `P='app/*push*'; python3
    // sweep.py $P`), is judged the same way, as a name no rule reads: mod-kit gives a path where the
    // command sets it to a plain name, and judged by that path it is any file; otherwise its value is
    // a glob the shell expands (placed in its folder by mod-kit), a loop's words or what a read takes
    // in, none of which the guard reads. A folder variable ($PWD, $HOME) names no file.
    const variable = !output && !t.path && t.run !== undefined && nameFromVariable(t.word)
    if (tool === 'Bash' && (output || variable || (t.path ? isGroupPattern(t.word.split('/').pop() ?? '') : isPattern(t.word)))) {
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
      const may = variable ? 'unread' : patternMayBeLook(t.word)
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
        output
          ? `where the command writes ${t.word} could not be followed, and its name is a command's output, which the design round guard cannot read before it runs, so it may name a look changing file`
          : variable
          ? `where the command writes ${t.word} could not be followed, and its name is a shell variable's value, which the design round guard cannot read before it runs, so it may name a look changing file`
          : may === 'unread'
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
    if (tool !== 'Bash') editedIn.set(t.path, tree)
    // A test of a screen passes (Dan, 2026-10-08: "On, but let tests through"), judged by the path
    // inside its project, so a folder named tests above the checkout lets nothing through.
    if (modTs ? isTestPath(relTo(t.path, tree)) || !isModHookTs(relTo(t.path, tree)) : lookKindIn(t.path, tree) === null) continue
    // #1933: taking away a mod hook file git has never tracked (a scratch copy made there by mistake)
    // takes no words of the mod as it ships away, and passes. What the same command writes there is a
    // target of its own, judged as ever.
    if (t.removes && (modTs || isModHook(relTo(t.path, tree))) && (await neverTracked($, t.path, tree))) continue
    // A settled design make-settled.py wrote, under docs/design exactly as it sealed it, passes unasked
    // whatever the issue's answers (#1524, Dan, 2026-10-23: "Let it through"): it changes no screen of
    // the product, and the design it holds was settled on the issue it came from. Any other text there,
    // a hand edit included, is judged as before, and the refusal says why it was not let through.
    // One a script run is handed (#1593), check-decision-map.py and make-settled.py among them, runs and
    // is read again once it ran (afterShell): what a script writes cannot be read before it runs. One
    // that cannot be read now could not be judged after either, and is held, saying so.
    if (!modTs && t.run !== undefined && isDesignRecord(relTo(t.path, tree))) {
      let before: string | undefined
      try {
        before = await textNow($, t.path)
      } catch (err) {
        const notes = unreadIn.get(tree) ?? []
        const said = shellUnread(relTo(t.path, tree), message(err))
        if (!notes.includes(said)) notes.push(said)
        unreadIn.set(tree, notes)
        const files = byTree.get(tree) ?? []
        if (!files.includes(t.path)) files.push(t.path)
        byTree.set(tree, files)
        continue
      }
      if (!watch.some(x => x.path === t.path)) watch.push({ path: t.path, tree, name: t.path.slice(t.path.lastIndexOf('/') + 1), before, files: [], record: true })
      continue
    }
    if (!modTs && isDesignRecord(relTo(t.path, tree))) {
      if (tool === 'Bash' && t.from !== undefined && notAlone === null) notAlone = await restoreAlone($, String(input.command ?? ''))
      const sealed = await settledRecord($, { ...t, path: t.path }, tree, tool, input, at, notAlone ?? undefined)
      if (sealed === true) continue
      const notes = unreadIn.get(tree) ?? []
      if (!notes.includes(sealed)) notes.push(sealed)
      unreadIn.set(tree, notes)
    }
    // Only now is a Swift file read for SwiftUI, so a test is never read, nor held when it cannot be
    // (lessons review of #991).
    if (kind === 'swift') {
      const view = await swiftView($, t, tool, input)
      if (view === false) continue
      // One that is no ordinary file (#1814) is held, saying why.
      if (view !== true) {
        const notes = unreadIn.get(tree) ?? []
        const said = targetUnread(relTo(t.path, tree), view.unreadable)
        if (!notes.includes(said)) notes.push(said)
        unreadIn.set(tree, notes)
      }
    }
    if (t.from !== undefined && (judgedByText(t.path) || modTs) && notAlone === null) notAlone = await restoreAlone($, String(input.command ?? ''))
    if (modTs) {
      const drawn = await drawingChange($, { ...t, path: t.path }, tree, tool, input, notAlone ?? undefined, watch)
      if (drawn === 'pass') continue
      if (drawn !== 'held' && 'worded' in drawn) worded.push({ file: relTo(t.path, tree), words: drawn.worded })
      else if (drawn !== 'held') {
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
    } else if (change && 'unreadable' in change) {
      // A file that is no ordinary file (#1814): never opened, judged whole, saying why.
      const said = targetUnread(relTo(t.path, tree), change.unreadable)
      const notes = unreadIn.get(tree) ?? []
      if (!notes.includes(said)) notes.push(said)
      unreadIn.set(tree, notes)
    } else if (change && (await nothingShown($, t.path, tree, change.before, change.after))) continue
    else if (!change && tool === 'Bash' && t.from === undefined && isModHook(relTo(t.path, tree)) && (await $.fs.exists(modManifestOf(t.path)).catch(() => false))) {
      // A shell write to a mod's TSX or JSX hook file, which cannot be read before it runs (#1341), is
      // judged by what it leaves once it ran, by the rule an Edit there is (#1576, afterShell). A file
      // that cannot be read now is held whole, saying so.
      let before: string | undefined
      try {
        before = await textNow($, t.path)
      } catch (err) {
        const notes = unreadIn.get(tree) ?? []
        const said = shellUnread(relTo(t.path, tree), message(err))
        if (!notes.includes(said)) notes.push(said)
        unreadIn.set(tree, notes)
        const files = byTree.get(tree) ?? []
        if (!files.includes(t.path)) files.push(t.path)
        byTree.set(tree, files)
        continue
      }
      if (!watch.some(x => x.path === t.path)) watch.push({ path: t.path, tree, name: t.path.slice(t.path.lastIndexOf('/') + 1), before, files: [], tsx: true })
      continue
    } else if (t.run !== undefined && !isDesignRecord(relTo(t.path, tree))) {
      // A file a script is handed (#1586): the refusal says why it was judged as a write of it. A
      // settled design's own reason is said above, with the way that goes through.
      const notes = unreadIn.get(tree) ?? []
      const said = scriptUnread(relTo(t.run, tree), relTo(t.path, tree))
      if (!notes.includes(said)) notes.push(said)
      unreadIn.set(tree, notes)
    }
    // A mod hook file held for a message's wording alone says so (#1859).
    if (change && 'after' in change) {
      const words = await wordsOnly($, t.path, tree, change.before, change.after)
      if (words !== undefined) worded.push({ file: relTo(t.path, tree), words })
    }
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
      for (const s of subjects) if (!(await answerOf($, s))) lacking.push(s)
    } catch (err) {
      return { unreadable: { files: shown, subjects, why: message(err), worded } }
    }
    if (!lacking.length) continue
    missingFiles.push(...shown)
    missingTrees.push(tree)
    unread.push(...(unreadIn.get(tree) ?? []))
    for (const s of lacking) if (!missing.some(m => m.key === s.key)) missing.push(s)
  }
  // #1954: an Edit or MultiEdit held here that would not apply to the file as it stands changes
  // nothing, since the tool refuses it, and what it would change cannot be read: it is told so, to be
  // sent again with the file's own text, rather than held for Dan as a change it may not make. The
  // #1951 builder's slip, a comment's parenthesis lost from its old text, was held for Dan as a change
  // to a message's words. Only for a file whose checkout is known, read as it stands now.
  if ((unsureFiles.length || missing.length) && (tool === 'Edit' || tool === 'MultiEdit')) {
    for (const [path, tree] of editedIn) {
      const now = await textNow($, path).catch(() => undefined)
      if (now !== undefined && editWouldNotApply(now, tool, input)) return { stale: relTo(path, tree) }
    }
  }
  if (unsureFiles.length) return { unsure: unsureFiles, why, worded }
  if (missing.length) return { missing: { files: missingFiles, subjects: missing, trees: missingTrees, unread, worded } }
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
  // An edit that would not apply asks nothing of Dan (#1954): no card, nothing left waiting.
  if ('stale' in v) return stale(v.stale)
  if ('unsure' in v) {
    const c = unsureCard(v.unsure, v.worded)
    await drawCard($, call.id, c.reason, c.safeWay)
    return unsure(v.unsure, v.why, v.worded)
  }
  if ('unreadable' in v) {
    const u = v.unreadable
    const c = unreadableCard(u.files, u.worded)
    await drawCard($, call.id, c.reason, c.safeWay)
    return unreadable(u.files, u.subjects, u.why, u.worded)
  }
  const { files, subjects, trees, unread, worded } = v.missing
  const waiting: DesignRoundPending = { id: call.id, tool: call.tool, files, subjects, trees, key: call.called.key, call: call.called.call, ...(call.agent ? { agent: true as const } : {}) }
  await update($, pendingRef, p => [...(p ?? []).filter(x => x.id !== call.id), waiting])
  const c = card(files, subjects, worded)
  await drawCard($, call.id, c.reason, c.safeWay)
  return call.agent ? agentRefusal(files, subjects, call.id, unread, worded) : refusal(call.id, files, subjects, unread, worded)
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

// What a file holds now, by mod-kit's one reader of a file a call writes (#1814): one that is no
// ordinary file (/dev/stdin, a fifo, a link to a device) is never opened, since a read of one waits
// for ever and the call never runs, and is unreadable with why, never empty.
const targetNow = ($: EngineInterface, path: string): Promise<Current> =>
  currentText({ exists: p => $.fs.exists(p), stat: (p, o) => $.fs.stat(p, o), read: p => $.fs.read(p) }, path)

// A file's text as it stands, undefined for one not there. One that is no ordinary file throws why
// (#1814), which each caller says as a file it could not read.
const textNow = async ($: EngineInterface, path: string): Promise<string | undefined> => {
  const now = await targetNow($, path)
  if ('unreadable' in now) throw new Error(now.unreadable)
  return 'text' in now ? String(now.text) : undefined
}

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

// After a shell call the guard let through (#1296): each mod hook file it may have changed, read again
// (a .ts file since #1296, a TSX or JSX one and one that already drew since #1576), and each settled
// design under docs/design a script run was handed, by its seal (#1593). One whose change
// shows, by the rule an Edit of it is judged by, in a checkout whose issue Dan has not answered for (and not his Not a look
// change for this very call), is put back (undoOne) and the call waits on him as a refused edit does,
// its result withheld for the guard's words; one that cannot be read is said and waits alike.
const afterShell = async (
  $: EngineInterface,
  r: Awaited<ReturnType<EngineInterface['tool']['call']>>,
  watch: readonly Watched[],
  call: { id: string; tool: string; agent: boolean; input: Record<string, unknown> },
): Promise<typeof r> => {
  if (r.deny !== undefined) return r
  // `why`, for a settled design (#1593), what the refusal says of it: the seal check's own reason.
  // `words`, for a hook file whose change was held for a message's wording alone (#1859), its words.
  const changed: { w: Watched; after?: string; unread?: string; why?: string; words?: string }[] = []
  for (const w of watch) {
    let after: string | undefined
    try {
      after = await textNow($, w.path)
    } catch (err) {
      changed.push({ w, unread: message(err) })
      continue
    }
    if (after === w.before) continue
    // A settled design a script run was handed (#1593), by the skill's seal check of what it left.
    if (w.record) {
      const why = await sealedAfter($, w, after)
      if (why !== undefined) changed.push({ w, after, why })
      continue
    }
    // A TSX or JSX hook file by the rule its Edit is judged by (#1576); one made or taken away is a change.
    if (!w.tsx) {
      const hold = modHookTsHold(w.files, w.name, w.before, after)
      if (hold) changed.push({ w, after, ...('worded' in hold ? { words: hold.worded } : {}) })
      continue
    }
    if (w.before !== undefined && after !== undefined && (await nothingShown($, w.path, w.tree, w.before, after))) continue
    const words = w.before === undefined || after === undefined ? undefined : await wordsOnly($, w.path, w.tree, w.before, after)
    changed.push({ w, after, ...(words === undefined ? {} : { words }) })
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
        for (const s of at.subjects) if (!(await answerOf($, s))) open.push(s)
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
    if (c.unread !== undefined) said.push(shellOutcome({ file, unread: c.unread }, c.w.record))
    else said.push(shellOutcome(await undoOne($, c.w, c.after, file, scratch && `${scratch}/design-round-guard/${call.id}-${c.w.name}`), c.w.record, c.words))
  }
  const files = held.map(c => relTo(c.w.path, c.w.tree))
  const whys = held.flatMap(c => (c.why === undefined ? [] : [c.why]))
  const worded = held.flatMap(c => (c.words === undefined ? [] : [{ file: relTo(c.w.path, c.w.tree), words: c.words }]))
  const v: Exclude<Verdict, { pass: true }> = unknown.files.length
    ? { unsure: unknown.files, why: unknown.why.join('; '), worded }
    : unread.files.length
      ? { unreadable: { files: unread.files, subjects: unread.subjects, why: unread.why.join('; '), worded } }
      : { missing: { files, subjects: lacking, trees, unread: whys, worded } }
  const refused = await refuse($, v, { id: call.id, tool: call.tool, agent: call.agent, called })
  // What the command printed is never repeated here: only the tool's own result passes the secret
  // guard's scrub, so a secret it printed would reach Claude through this text (lessons review).
  return { deny: `${said.join(' ')} ${refused} What the command printed is withheld with this refusal.` }
}

// What a check with no call id is told: the refusal the call would meet, with no id to ask Dan under.
const previewed = (v: Exclude<Verdict, { pass: true }>): string => {
  if ('forged' in v) return forged(v.forged)
  if ('stale' in v) return stale(v.stale)
  if ('unsure' in v) return unsure(v.unsure, v.why, v.worded)
  if ('unreadable' in v) return unreadable(v.unreadable.files, v.unreadable.subjects, v.unreadable.why, v.unreadable.worded)
  return checked(v.missing.files, v.missing.subjects, v.missing.unread, v.missing.worded)
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
    for (const x of w.subjects) if (!(await answerOf($, x))) lacking = true
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
          // A skip on a builder's starting branch is kept under its worktree too, first, so a subject
          // is said as recorded only once both are (#1740).
          if (kind === 'skipped' && s.carryTo !== undefined) await $.store.set(s.carryTo, { kind, at: now, label: s.label, reading: ISSUE_READING } satisfies DesignRoundRecord)
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
        // The issue a refused builder works on (#1904), read in place of its worktree-agent branch;
        // one that is no whole number is refused by name before anything is asked.
        const badIssue = skipIssueProblem(ask.metadata?.issue)
        if (badIssue !== undefined) return { deny: badIssue }
        const issue = typeof ask.metadata?.issue === 'number' ? ask.metadata.issue : undefined
        // Only what still has no answer of his is asked about and recorded: a subject he has since
        // settled keeps its settlement, never overwritten by a skip (lessons review of #991).
        // What the refused call waits on, as the settled question naming it reads it (#1046). Only
        // the label is changed by a named issue: the key, and the worktree a skip is also kept under,
        // stay the branch's, so no other checkout reads his answer (#1306, #1740).
        const open: DesignRoundSubject[] = []
        for (const x of waitsOn(waiting)) if (!(await answerOf($, x))) open.push(namedByIssue(x, issue))
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
          // His word that this one call changes neither the look nor any wording, kept with why (#1010, #1911): the same
          // call sent again goes through, and nothing is recorded for the issue.
          try {
            const pass: DesignRoundPass = { kind: 'not-look', at: await $.clock.now(), tool: waiting.tool, files: waiting.files, subjects: open.map(x => x.label), why: notLookWhy(waiting.files), onScreen, call: waiting.call }
            await $.store.set(passKey(waiting.key), pass)
          } catch (err) {
            return say(r, `Dan answered ${NOT_LOOK}, but it could not be recorded (${message(err)}), so the edit to ${listed(waiting.files)} stays blocked. Tell him, and ask again.`)
          }
          await update($, pendingRef, p => (p ?? []).filter(x => x.id !== id))
          return say(r, `Dan answered ${NOT_LOOK}: this one edit to ${listed(waiting.files)} goes ahead, recorded as his word that it changes neither the look nor any wording. ${again(waiting)} Any other edit that changes the look on ${s} is still held.`)
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
