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
// changed, which touches no other session's work.
export type ShellWrite = { path: string; sources?: string[]; removes?: true; tree?: true }

type Written = {
  files: { path?: string; sources?: string[]; mayBeFolder?: true }[]
  changes: { path?: string; does: string; tree?: true }[]
}
export const judgedWrites = (w: Written): ShellWrite[] => {
  const out: ShellWrite[] = []
  // A path named twice is kept once, and a removal of it keeps its flags whichever came first, so
  // `echo > d; rm -r d` is still judged as taking the folder away (lessons review of #691).
  const add = (path: string, extra: Omit<ShellWrite, 'path'>) => {
    const had = out.find(x => x.path === path)
    if (!had) out.push({ path, ...extra })
    else Object.assign(had, extra.removes ? { removes: true } : {}, extra.tree ? { tree: true } : {})
  }
  for (const f of w.files) if (f.path) add(f.path, f.mayBeFolder && f.sources?.length ? { sources: f.sources } : {})
  for (const c of w.changes) {
    if (!c.path) continue
    if (c.does === 'remove') add(c.path, c.tree ? { removes: true, tree: true } : { removes: true })
    else if (c.does === 'touch' || c.does === 'truncate') add(c.path, {})
  }
  return out
}
