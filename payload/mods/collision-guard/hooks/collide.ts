// The collision guard's rules, apart from the hooks (claude-config#605).

export type Rec = { sessionId: string; cwd: string; repoRoot: string | null; edits: string[]; transcriptPath: string | null }
export type Verdict = { verdict: 'Proceed' | 'Worktree' | 'Stop'; reason: string }

// The checkout wide git commands the spec watches: each moves or rewrites the whole working tree,
// or stages files the other session left there. Anything else is left alone.
export const watchedGit = (g: { sub: string | undefined; args: string[] }): string | undefined => {
  const { sub, args } = g
  const label = `git ${[sub, ...args].join(' ')}`
  switch (sub) {
    case 'checkout': {
      // Putting files back (checkout <ref> -- <path>) touches only those, unless what follows -- is
      // the whole tree or a folder: checkout -- . discards every change (lessons review of #632).
      const dd = args.indexOf('--')
      if (dd < 0) return label
      const paths = args.slice(dd + 1)
      return paths.length === 0 || paths.some(p => p === '.' || p === ':/' || p.endsWith('/')) ? label : undefined
    }
    case 'switch':
      return label
    case 'branch': {
      // A forced delete in any spelling: -D, -d with -f or --force, combined (-df, -fd) or apart.
      const flags = args.filter(a => a.startsWith('-'))
      const short = flags.filter(a => /^-[A-Za-z]+$/.test(a)).join('')
      const deletes = short.includes('d') || flags.includes('--delete')
      const forces = short.includes('f') || flags.includes('--force')
      return short.includes('D') || (deletes && forces) ? label : undefined
    }
    case 'reset':
      return args.includes('--hard') ? label : undefined
    case 'stash':
      return args[0] === 'pop' ? label : undefined
    case 'add':
      return args.some(a => a === '-A' || a === '--all' || a === '.') ? label : undefined
    default:
      return undefined
  }
}

// Other open sessions, never this one: a subagent of this session works as this session.
export const othersEditing = <R extends Rec>(open: R[], selfId: string | null, path: string): R[] =>
  open.filter(r => r.sessionId !== selfId && r.edits.includes(path))

// Whether a path is the folder itself or anything under it.
export const insideRoot = (path: string, root: string): boolean => root === '/' || path === root || path.startsWith(root + '/')

// Scratch (#674, #700): the temporary folders, the scratchpad under them, and wherever TMPDIR points.
// A write there is never recorded as a session's edit unless it lies inside the session's own root.
const SCRATCH = ['/tmp', '/private/tmp', '/var/folders', '/private/var/folders']
export const isScratch = (path: string, tmpdir: string | undefined): boolean => {
  const t = tmpdir?.replace(/\/+$/, '')
  return [...SCRATCH, ...(t && t.startsWith('/') ? [t] : [])].some(r => insideRoot(path, r))
}

// The files other open sessions edited inside a folder an rm -r takes away (#674), each once, in
// the order first found, so each can be judged by othersEditing like a single write.
export const editedUnder = <R extends Rec>(open: R[], selfId: string | null, folder: string): string[] => {
  const out: string[] = []
  for (const r of open) {
    if (r.sessionId === selfId) continue
    for (const p of r.edits) if (insideRoot(p, folder) && !out.includes(p)) out.push(p)
  }
  return out
}

// A session whose repository could not be read when it started is matched by its folder, so a
// failed lookup there cannot hide it from a branch switch here (the empty answer is not "elsewhere").
export const othersInRepo = <R extends Rec>(open: R[], selfId: string | null, root: string | null): R[] =>
  root === null
    ? []
    : open.filter(r => r.sessionId !== selfId && (r.repoRoot === root || (r.repoRoot === null && (r.cwd === root || r.cwd.startsWith(root + '/')))))

// #3398: a folder a git command names (-C, --git-dir, --work-tree, GIT_DIR, GIT_WORK_TREE) as git is
// handed it once the shell has read the word: the home folder written out for a leading ~ or $HOME,
// anything else as written. Undefined where the shell fills it in (a $, a backtick, a pattern, a
// brace list, another user's home), where it is empty, and where home is needed and not known: git
// asked about the characters as typed would answer for a folder named "$X". Read as mod-kit's git
// reader reads a -C to chain it, so the two never part on what can be followed.
export const namedFolder = (value: string, home: string): string | undefined => {
  if (value === '') return undefined
  const v = value.replace(/^\$(?:HOME|\{HOME\})(?=\/|$)/, '~')
  if (/[$`*?[\]{}]/.test(v)) return undefined
  if (v === '~' || v.startsWith('~/')) return home ? home.replace(/\/+$/, '') + v.slice(1) : undefined
  return v.startsWith('~') ? undefined : v
}

// #3398 (Dan, 2026-11-22: "Follow the variable first"): a git command's words with each folder a -C
// names by a variable the call itself sets written out, so the command is judged by the folder it
// really names. `followed` is what mod-kit's reader gives for each word (pipeline asked with
// `follow`): the value where the word is one variable alone and the call's own text makes its value
// certain, else null, and nothing at all from a reader that followed nothing. Whether a variable
// can be followed is decided there and nowhere here. Undefined where no word changes, so a caller
// reads the command as typed and a folder the shell fills in stays one the guard cannot tell.
// Only the word after a -C of git's own is read so: one standing before the subcommand, as `g`
// (mod-kit's reading of the same words) places it. A followed word never starts with a dash, so
// before the subcommand it can only be the value of the option in front of it, and that option is
// git's own -C exactly when it is written -C. A value for any other word is left alone: a
// subcommand's -C names a branch (git switch -C), and a repository or working folder named by a
// variable is not followed (the pull request's "For Dan" list).
export const followedFolders = (words: readonly string[], followed: readonly (string | null)[] | undefined, g: { sub: string | undefined; args: readonly string[] }): string[] | undefined => {
  if (!followed) return undefined
  const sub = g.sub === undefined ? words.length : words.length - g.args.length - 1
  let read: string[] | undefined
  for (let i = 2; i < sub; i++) {
    const value = followed[i]
    if (words[i - 1] !== '-C' || value === null || value === undefined) continue
    read ??= [...words]
    read[i] = value
  }
  return read
}

// #3398: where a watched git command is put to git, to find the checkouts it acts on. git acts on
// the repository the command names, never on the folder the call was typed in: the folder a cd
// before it leaves the shell in (`folder`, as mod-kit's pipeline gives it, null where it cannot be
// followed), then every -C, each read from the one before it (mod-kit's `chained`, else `dir`),
// then the repository and the working folder it names apart (`gitDir`, `workTree`, from its
// options or from GIT_DIR and GIT_WORK_TREE written in front of it). `at` is git's own options for
// the folder it runs in, so git reads a relative -C itself and nothing is worked out here; `apart`
// the two namings, each written out. `asToday` says `at` is the folder the guard always asked
// about (`dir`, else the session's folder), so that question is not put twice.
// `unknown` is why the guard cannot tell, in words: a folder the shell fills in, a cd it cannot
// follow under a relative folder, and either variable named anywhere else in the call (an export, a
// plain assignment, a setting on another command), which git reads only if it was exported and no
// reader here follows.
export type GitWhere = { at: string[]; apart: string[]; asToday: boolean } | { unknown: string }
export const whereGit = (
  g: { dir: string | undefined; chained?: string | null; gitDir?: string; workTree?: string },
  folder: string | null,
  cwd: string,
  home: string,
  command: string,
): GitWhere => {
  for (const [name, named] of [['GIT_DIR', g.gitDir], ['GIT_WORK_TREE', g.workTree]] as const)
    if (named === undefined && new RegExp(`\\b${name}\\b`).test(command)) return { unknown: `the call names ${name} somewhere other than as a setting on the git command itself` }
  if (g.chained === null) return { unknown: 'its -C options lead to a folder the shell fills in' }
  const word = g.chained ?? g.dir
  const uncd = { unknown: 'the cd before it cannot be followed' }
  let at: string[]
  let asToday: boolean
  if (word === undefined || word === '') {
    if (folder === null) return uncd
    at = ['-C', folder]
    asToday = folder === cwd
  } else {
    const named = namedFolder(word, home)
    if (named === undefined) return { unknown: `the shell fills in the folder -C names (${word})` }
    if (!named.startsWith('/') && folder === null) return uncd
    at = named.startsWith('/') ? ['-C', named] : ['-C', folder as string, '-C', named]
    asToday = g.chained === undefined && named === word && (named.startsWith('/') || folder === cwd)
  }
  // Each naming mod-kit's reader handed on, written out for git as the option it stands for.
  const apart: string[] = []
  const unfollowed = (what: string, value: string) => ({ unknown: `it names its ${what} as ${value === '' ? 'nothing' : value}, which the guard cannot follow to a folder` })
  if (g.gitDir !== undefined) {
    const repository = namedFolder(g.gitDir, home)
    if (repository === undefined) return unfollowed('repository', g.gitDir)
    apart.push(`--git-dir=${repository}`)
  }
  if (g.workTree !== undefined) {
    const folder = namedFolder(g.workTree, home)
    if (folder === undefined) return unfollowed('working folder', g.workTree)
    apart.push(`--work-tree=${folder}`)
  }
  return { at, apart, asToday }
}

// The files a message to another session names (#700). A message carries text only, so each name is
// written as a quoted string (JSON's own quoting), which no comma, space, quote or curly apostrophe
// inside a name can break, and read back the same way. A message from a guard before #700 named them
// unquoted and comma separated, and is still read that way, since a session keeps the code it loaded.
export const quoteNames = (names: string[]): string => names.map(n => JSON.stringify(n)).join(', ')

export type Wanted = { verb: 'edit' | 'remove'; names: string[] }
const STRING = '"(?:[^"\\\\]|\\\\.)*"'
const QUOTED_LIST = new RegExp(`wanted to (edit|remove) (${STRING}(?:, ${STRING})*) while you are working on it`)
export const wantedFiles = (text: string): Wanted | undefined => {
  const q = QUOTED_LIST.exec(text)
  if (q) {
    try {
      return { verb: q[1] as Wanted['verb'], names: ((q[2] as string).match(new RegExp(STRING, 'g')) ?? []).map(s => JSON.parse(s) as string) }
    } catch {
      // Not quoting this guard wrote: read as the older shape below.
    }
  }
  const old = /wanted to (edit|remove) (.+?) while you are working on it/.exec(text)
  return old ? { verb: old[1] as Wanted['verb'], names: (old[2] as string).split(', ') } : undefined
}

// The judge answers JSON; anything that is not exactly one of the three verdicts with a reason is
// no verdict, and the guard stops (L42, the spec).
export const parseVerdict = (text: string): Verdict | undefined => {
  const m = /\{[\s\S]*\}/.exec(text)
  if (!m) return undefined
  try {
    const v = JSON.parse(m[0]) as { verdict?: unknown; reason?: unknown }
    if ((v.verdict === 'Proceed' || v.verdict === 'Worktree' || v.verdict === 'Stop') && typeof v.reason === 'string' && v.reason.trim()) {
      return { verdict: v.verdict, reason: v.reason.trim() }
    }
  } catch {
    // Not JSON: no verdict.
  }
  return undefined
}

// The last request typed into a session, read from the tail of its transcript: the newest user row
// that carries text rather than tool results. A tail may begin part way through a line.
export const latestRequest = (tail: string): string | undefined => {
  const lines = tail.split('\n').reverse()
  for (const line of lines) {
    let row: { type?: string; message?: { role?: string; content?: unknown } }
    try {
      row = JSON.parse(line)
    } catch {
      continue
    }
    if (row.type !== 'user' || row.message?.role !== 'user') continue
    const c = row.message.content
    if (typeof c === 'string' && c.trim()) return c.trim().slice(0, 600)
    if (Array.isArray(c)) {
      const text = c
        .filter((b): b is { type: string; text: string } => !!b && (b as { type?: string }).type === 'text')
        .map(b => b.text)
        .join('\n')
        .trim()
      if (text) return text.slice(0, 600)
    }
  }
  return undefined
}

// The files a shell command writes (#654), as this guard judges them, read from mod-kit's one write
// reader ($.modkit.writes, #712), so this keeps no reader of its own (L613): every file content goes
// into, or that is stamped or emptied, judged as an edit; and every file removed, judged as a
// removal, a folder with everything under it where the reader says the removal reaches its tree
// (rm -r, a mv's source, find -delete, #674). A cp or mv of one source onto one existing name may
// land inside it if it is a folder, which only the disk can say, so that write carries its sources
// and the hook looks.
//
// Decided for #654 (docs/mods-design.md): what the words do not name is not guessed at. A script, a
// python -c, a make, or a path built from a variable, a glob or a command substitution writes
// files this cannot see, and those are neither judged nor noted; nor is a folder made or a mode
// changed, which touches no other session's work. Since #1592 a file handed to a script file as its
// argument (mod-kit's `runs`, #1586) is judged and noted as an edit of it, as an Edit of that file is:
// what the script does with it cannot be read before it runs. What a script writes that no argument
// names is still not seen.
// Since #3323 (Dan, 2026-11-21: "Turn it round, with the list (Recommended)") a file handed to a
// program mod-kit's reader does not know (a run marked `unknown`) is judged the same way, and is
// marked `unknown` with the program and what the reader calls it, so the question names it and the
// path is NOT noted as this session's edit. Most words such a program is handed spell a path without
// being a file it writes (`gh pr view 5` hands pr, view and 5 in the checkout), a session's edits
// are capped at twenty, and each one noted is a file another session would then be asked about. So
// a real write by such a program is not recorded as an edit, as it was not before. A path a write
// the words name, or a script, also reaches is an edit, and carries no mark.
export type ShellWrite = { path: string; sources?: string[]; removes?: true; tree?: true; unknown?: { program: string; what: string } }

// What git itself changes is judged the same way (#1136, Dan, 2026-10-13): a checkout of a path and a
// restore of the working tree put back what they name, an edit; git rm and a git mv's source take it
// away, a removal; each over everything under it where the reader says it may be a folder. A git
// pathspec matched across folders (`:/x`, a pattern) names no path, and is not guessed at.
type Written = {
  files: { path?: string; sources?: string[]; mayBeFolder?: true; tree?: true }[]
  changes: { path?: string; does: string; tree?: true }[]
  byGit?: { path?: string; does: 'write' | 'remove'; tree?: true }[]
  runs?: { script?: string; what?: string; unknown?: true; args: { path?: string }[] }[]
}
/**
 * One more reading of a path already kept, folded in: a removal keeps its flags whichever came
 * first, and the mark of a program the reader does not know (#3323) stands only while every
 * reading of the path carries it, so a path anything else writes is an edit.
 */
export const foldWrite = (had: ShellWrite, extra: Omit<ShellWrite, 'path'>): void => {
  Object.assign(had, extra.removes ? { removes: true } : {}, extra.tree ? { tree: true } : {})
  if (!extra.unknown) delete had.unknown
}
export const judgedWrites = (w: Written): ShellWrite[] => {
  const out: ShellWrite[] = []
  // A path named twice is kept once, and a removal of it keeps its flags whichever came first, so
  // `echo > d; rm -r d` is still judged as taking the folder away (lessons review of #691).
  const add = (path: string, extra: Omit<ShellWrite, 'path'>) => {
    const had = out.find(x => x.path === path)
    if (!had) out.push({ path, ...extra })
    else foldWrite(had, extra)
  }
  for (const f of w.files) if (f.path) add(f.path, { ...(f.mayBeFolder && f.sources?.length ? { sources: f.sources } : {}), ...(f.tree ? { tree: true as const } : {}) })
  for (const c of w.changes) {
    if (!c.path) continue
    if (c.does === 'remove') add(c.path, c.tree ? { removes: true, tree: true } : { removes: true })
    else if (c.does === 'touch' || c.does === 'truncate') add(c.path, {})
  }
  for (const g of w.byGit ?? []) {
    if (!g.path) continue
    const tree = g.tree ? { tree: true as const } : {}
    add(g.path, g.does === 'remove' ? { removes: true, ...tree } : tree)
  }
  for (const r of w.runs ?? []) {
    const unknown = r.unknown ? { unknown: { program: r.script ?? 'a program', what: r.what ?? 'a program the write reader does not know' } } : {}
    for (const a of r.args) if (a.path) add(a.path, unknown)
  }
  return out
}
