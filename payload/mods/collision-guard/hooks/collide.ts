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

// The files a shell command writes (#654), read from the words mod-kit's command reader gives
// ($.modkit.commands), so this keeps no reader of its own (L613). Each is a path made absolute
// against the folder the command runs in, following any cd earlier in the same command. A cp or mv
// onto one existing name may land inside it if it is a folder, which only the disk can say, so that
// write carries its sources and the hook looks.
//
// Decided for #654 (docs/mods-design.md): what the words do not name is not guessed at. A script, a
// python -c, a make, or a path built from a variable, a glob or a command substitution writes
// files this cannot see, and those are neither judged nor noted.
//
// An rm or unlink is a write too (#674): it `removes` the file, and with -r it removes a `tree`,
// the folder and everything under it, so the hook judges every file another session edited there.
export type ShellWrite = { path: string; sources?: string[]; removes?: true; tree?: true }

const WRITE_REDIRECT = /^(\d*>>?|\d*>\||&>>?|>&)$/
const UNNAMEABLE = /[$`*?[\]{}]/

// A word as an absolute path, or undefined when it cannot be named: built from a variable or a
// pattern, a ~user, relative to a folder that is not known, or a device such as /dev/null.
export const absolutePath = (word: string, dir: string | undefined, home: string | undefined): string | undefined => {
  if (!word || UNNAMEABLE.test(word)) return undefined
  let p = word
  if (p === '~' || p.startsWith('~/')) {
    if (!home) return undefined
    p = home + p.slice(1)
  } else if (p.startsWith('~')) return undefined
  if (!p.startsWith('/')) {
    if (!dir) return undefined
    p = `${dir}/${p}`
  }
  const parts: string[] = []
  for (const seg of p.split('/')) {
    if (seg === '' || seg === '.') continue
    if (seg === '..') parts.pop()
    else parts.push(seg)
  }
  const out = '/' + parts.join('/')
  return out === '/dev' || out.startsWith('/dev/') ? undefined : out
}

const baseOf = (p: string) => p.split('/').filter(Boolean).pop() ?? p

// The operands of a command after its options, taking a value from the next word for the options
// named in `valued`. After -- everything is an operand.
const operands = (args: string[], valued: Set<string>): { ops: string[]; opts: Map<string, string | true> } => {
  const ops: string[] = []
  const opts = new Map<string, string | true>()
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    if (a === '--') {
      ops.push(...args.slice(i + 1))
      break
    }
    if (a.startsWith('-') && a !== '-') {
      if (valued.has(a)) opts.set(a, args[++i] ?? '')
      else opts.set(a, true)
    } else ops.push(a)
  }
  return { ops, opts }
}

// sed's files when it edits them in place: -i, -i<suffix>, --in-place[=suffix], with BSD's -i ''
// or -i .bak taking the next word as the suffix. The script is the first operand unless -e or -f
// gave it.
const sedInPlace = (args: string[]): string[] => {
  let inPlace = false
  let scripted = false
  const ops: string[] = []
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    if (a === '-e' || a === '-f' || a === '--expression' || a === '--file') {
      scripted = true
      i++
    } else if (a.startsWith('--expression=') || a.startsWith('--file=')) scripted = true
    else if (a === '-i') {
      inPlace = true
      const next = args[i + 1]
      if (next !== undefined && (next === '' || next.startsWith('.'))) i++
    } else if (a === '--in-place' || a.startsWith('--in-place=') || /^-[a-zA-Z]*i/.test(a)) inPlace = true
    else if (a.startsWith('-') && a !== '-') continue
    else ops.push(a)
  }
  if (!inPlace) return []
  return scripted ? ops : ops.slice(1)
}

// perl's files when -i edits them in place. In a cluster such as -pi.bak or -pie, what follows the
// i is its suffix; an e or E takes the rest of the cluster, or the next word, as the script.
const perlInPlace = (args: string[]): string[] => {
  let inPlace = false
  let scripted = false
  const ops: string[] = []
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    if (a === '--') {
      ops.push(...args.slice(i + 1))
      break
    }
    if (!a.startsWith('-') || a === '-') {
      ops.push(a)
      continue
    }
    const letters = a.slice(1)
    for (let j = 0; j < letters.length; j++) {
      const l = letters[j] as string
      if (l === 'i') {
        inPlace = true
        break
      }
      if (l === 'e' || l === 'E') {
        scripted = true
        if (j === letters.length - 1) i++
        break
      }
      // The rest of the cluster is this letter's value (-Ilib, -MPOSIX), never more letters, so
      // the i in -Ilib is not -i.
      if ('IMmxCdD0l'.includes(l)) break
    }
  }
  if (!inPlace) return []
  return scripted ? ops : ops.slice(1)
}

export const shellWrites = (cmds: string[][], cwd: string, home: string | undefined): ShellWrite[] => {
  const out: ShellWrite[] = []
  const seen = new Set<string>()
  // A path named twice is kept once, and a later removal of it keeps its flags, so `echo > d; rm
  // -r d` is still judged as taking the folder away (lessons review of #691).
  const add = (path: string | undefined, sources?: string[], extra?: Pick<ShellWrite, 'removes' | 'tree'>) => {
    if (!path) return
    if (seen.has(path)) {
      const had = out.find(w => w.path === path)
      if (had && extra) Object.assign(had, extra)
      return
    }
    seen.add(path)
    out.push({ path, ...(sources ? { sources } : {}), ...extra })
  }
  let dir: string | undefined = cwd
  for (const words of cmds) {
    // Redirects first, and taken out of the words, so what is left is the command and its operands.
    const args: string[] = []
    for (let i = 0; i < words.length; i++) {
      const w = words[i] as string
      if (WRITE_REDIRECT.test(w)) {
        const target = words[++i]
        if (target !== undefined) add(absolutePath(target, dir, home))
      } else if (/^\d*>&[0-9-]+$/.test(w)) continue
      else if (/^\d*<$/.test(w)) i++
      else args.push(w)
    }
    const name = baseOf(args[0] ?? '')
    const rest = args.slice(1)
    const abs = (w: string) => absolutePath(w, dir, home)
    switch (name) {
      case 'cd': {
        // cd - goes back to a folder this cannot know, so relative paths after it are not named.
        const target = rest.find(a => !a.startsWith('-') || a === '-') ?? '~'
        dir = target === '-' ? undefined : absolutePath(target, dir, home)
        break
      }
      case 'tee':
        for (const f of operands(rest, new Set()).ops) add(abs(f))
        break
      case 'touch':
        for (const f of operands(rest, new Set(['-t', '-r', '-d'])).ops) add(abs(f))
        break
      case 'sed':
        for (const f of sedInPlace(rest)) add(abs(f))
        break
      case 'perl':
        for (const f of perlInPlace(rest)) add(abs(f))
        break
      case 'rm':
      case 'unlink': {
        // rm takes no option values, so every option is a flag: -r, -R or --recursive in any
        // cluster (-rf, -fR) makes each operand a whole folder.
        const { ops, opts } = operands(rest, new Set())
        const tree = name === 'rm' && [...opts.keys()].some(k => k === '--recursive' || /^-[A-Za-z]*[rR]/.test(k))
        for (const f of ops) add(abs(f), undefined, tree ? { removes: true, tree: true } : { removes: true })
        break
      }
      case 'cp':
      case 'mv': {
        const { ops, opts } = operands(rest, new Set(['-t', '--target-directory', '-S', '--suffix']))
        const named = ops.map(o => ({ word: o, path: abs(o) }))
        const intoOpt = opts.get('-t') ?? opts.get('--target-directory') ?? [...opts.keys()].find(k => k.startsWith('--target-directory='))?.slice('--target-directory='.length)
        let sources = named
        let into: string | undefined
        let dest: { word: string; path: string | undefined } | undefined
        if (typeof intoOpt === 'string') into = abs(intoOpt)
        else {
          dest = named[named.length - 1]
          sources = named.slice(0, -1)
          if (!dest || sources.length === 0) break
          if (sources.length > 1 || dest.word.endsWith('/')) into = dest.path
        }
        const srcPaths = sources.map(s => s.path).filter((p): p is string => !!p)
        if (into) for (const s of srcPaths) add(`${into}/${baseOf(s)}`)
        else if (dest?.path) add(dest.path, srcPaths.length ? srcPaths : undefined)
        // mv takes each source away whole: a folder with everything under it, as rm -r does.
        if (name === 'mv') for (const s of srcPaths) add(s, undefined, { removes: true, tree: true })
        break
      }
    }
  }
  return out
}
