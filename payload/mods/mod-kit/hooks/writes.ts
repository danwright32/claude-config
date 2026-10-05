import type { ModKitWrite, ModKitWrites } from '../types/index.d.ts'
import { git } from './commands.ts'

// The one reader of which files a Bash call puts content into (#705, L613), over the simple
// commands the shared reader gives. Ask before saving kept its own copy and missed inline scripts,
// rsync, install, ln, dd, a patch, every file but the last of a sed -i, and a relative path after a
// cd; the collision guard's copy (#654) already followed a cd and a copy into a folder, and its
// path, sed and perl readings are carried over here as they were reviewed there. No build's copy
// (#616) listed the copying commands, dd and inline scripts; curl and wget's output files, gawk's
// and ruby's in place editing were missing from all three (#702). The collision guard and no build
// move onto this reader in #712.
//
// What it does not report: a file only created empty or stamped (touch), removed (rm, a mv's
// source), or changed in mode (chmod), and a script run from a file (python3 build.py), whose
// writes no word names and which are not guessed at (#654).

const WRITE_REDIRECT = /^(\d*>>?|\d*>\||&>>?)$/
const UNNAMEABLE = /[$`*?[\]{}]/
const HOME_VAR = /^\$(?:HOME|\{HOME\})(?=\/|$)/

const isDevice = (p: string) => p === '/dev' || p.startsWith('/dev/')

/**
 * A word as an absolute path, or undefined when it cannot be named: built from a variable other
 * than HOME or a pattern, a ~user, or relative to a folder that is not known.
 */
export const absolutePath = (word: string, dir: string | undefined, home: string): string | undefined => {
  if (!word) return undefined
  let p = word
  const hv = HOME_VAR.exec(p)
  if (hv) {
    if (!home) return undefined
    p = home + p.slice(hv[0].length)
  }
  if (UNNAMEABLE.test(p)) return undefined
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
  return `/${parts.join('/')}`
}

const baseOf = (p: string) => p.split('/').filter(Boolean).pop() ?? p

// The operands of a command after its options, taking a value from the next word for the options
// named in `valued` (an option written --name=value carries its own). After -- everything is an
// operand.
const operands = (args: string[], valued: ReadonlySet<string>): { ops: string[]; opts: Map<string, string | true> } => {
  const ops: string[] = []
  const opts = new Map<string, string | true>()
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    if (a === '--') {
      ops.push(...args.slice(i + 1))
      break
    }
    if (a.startsWith('-') && a !== '-') {
      const eq = a.indexOf('=')
      if (a.startsWith('--') && eq > 0) opts.set(a.slice(0, eq), a.slice(eq + 1))
      else if (valued.has(a)) opts.set(a, args[++i] ?? '')
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

// perl's (and ruby's) files when -i edits them in place. In a cluster such as -pi.bak or -pie, what
// follows the i is its suffix; a script letter (perl's e or E, ruby's e) takes the rest of the
// cluster, or the next word, as the script; a value letter takes the rest of the cluster as its value.
const PERL = { script: 'eE', valued: 'IMmxCdD0l' }
const RUBY = { script: 'e', valued: 'IrCEFxWTK0' }
const inPlaceCluster = (args: string[], letters: { script: string; valued: string }): string[] => {
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
    const cluster = a.slice(1)
    for (let j = 0; j < cluster.length; j++) {
      const l = cluster[j] as string
      if (l === 'i') {
        inPlace = true
        break
      }
      if (letters.script.includes(l)) {
        scripted = true
        if (j === cluster.length - 1) i++
        break
      }
      // The rest of the cluster is this letter's value (-Ilib, -MPOSIX), never more letters, so
      // the i in -Ilib is not -i.
      if (letters.valued.includes(l)) break
    }
  }
  if (!inPlace) return []
  return scripted ? ops : ops.slice(1)
}

// awk's files when gawk edits them in place (-i inplace, -iinplace, --include=inplace): every
// operand after the program, which is the first operand unless -f gave it.
const awkInPlace = (args: string[]): string[] => {
  let inPlace = false
  let scripted = false
  const ops: string[] = []
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    if (a === '-i' || a === '--include') {
      if (args[i + 1] === 'inplace') inPlace = true
      i++
    } else if (a === '-iinplace' || a === '--include=inplace') inPlace = true
    else if (a === '-f' || a === '--file') {
      scripted = true
      i++
    } else if (a === '-v' || a === '-F' || a === '-l' || a === '-E') i++
    else if (a.startsWith('-') && a !== '-') continue
    else ops.push(a)
  }
  if (!inPlace) return []
  return scripted ? ops : ops.slice(1)
}

// The value of a short option written alone (-o out), at the end of a cluster (-sSo out) or with
// its value attached (-oout), or of its long form (--output out, --output=out).
const optionValue = (args: string[], letter: string, long: string): string | undefined => {
  for (let i = 0; i < args.length; i++) {
    const a = args[i] as string
    if (a === '--') return undefined
    if (a === long) return args[i + 1]
    if (a.startsWith(`${long}=`)) return a.slice(long.length + 1)
    if (a.startsWith('-') && !a.startsWith('--')) {
      const j = a.indexOf(letter, 1)
      if (j < 0) continue
      return j === a.length - 1 ? args[i + 1] : a.slice(j + 1)
    }
  }
  return undefined
}

// The options that take a value, per command whose destination is its last operand, so a value is
// never taken for the destination (install -m 644, rsync --exclude .git, ditto --arch arm64).
const VALUED: Record<string, ReadonlySet<string>> = {
  cp: new Set(['-t', '-S', '--target-directory', '--suffix']),
  mv: new Set(['-t', '-S', '--target-directory', '--suffix']),
  ln: new Set(['-t', '-S', '--target-directory', '--suffix']),
  install: new Set(['-t', '-m', '-o', '-g', '-S', '-B', '-f', '-M', '--target-directory', '--mode', '--owner', '--group', '--suffix']),
  ditto: new Set(['--arch', '--bom']),
  rsync: new Set(['-e', '-f', '-T', '-B', '--rsh', '--exclude', '--include', '--filter', '--files-from', '--exclude-from', '--include-from', '--chmod', '--log-file', '--rsync-path', '--port', '--temp-dir', '--backup-dir', '--suffix', '--compare-dest', '--link-dest', '--copy-dest', '--block-size', '--bwlimit', '--timeout', '--max-size', '--min-size', '--partial-dir']),
}

// A destination on another machine (host:path, user@host:path) is no file here.
const isRemote = (w: string) => /^[^/]*:/.test(w) && !w.startsWith('/')

// Inline code that writes files, for the interpreters Claude reaches for when a write is refused.
const INTERPRETERS = new Set(['python', 'python3', 'node', 'ruby', 'perl', 'bun', 'deno'])
const SHELLS = new Set(['sh', 'bash', 'zsh'])
const INLINE_FLAGS = new Set(['-c', '-e', '-E', '--eval'])
const INLINE_WRITE = /open\([^)]*['"][wax]\+?b?['"]|\.write_(?:text|bytes)\(|writeFile|appendFile|fs\.(?:write|rm|unlink|rename|copyFile)|File\.write|shutil\.(?:copy|move)|os\.(?:rename|replace)|renameSync|copyFileSync/

// Input words: `<` and the file after it, `<file`, a heredoc's `<<EOF`, a here-string's `<<<` and
// its text. Taken out of a command's words, so its operands are what is left.
const splitInputs = (words: string[]): { rest: string[]; files: string[]; heredoc: boolean } => {
  const rest: string[] = []
  const files: string[] = []
  let heredoc = false
  for (let i = 0; i < words.length; i++) {
    const w = words[i] as string
    if (w === '<<<') i++
    else if (w.startsWith('<<<')) continue
    else if (w.startsWith('<<')) heredoc = true
    else if (w === '<') {
      if (words[i + 1] !== undefined) files.push(words[++i] as string)
    } else if (w.startsWith('<')) files.push(w.slice(1))
    else rest.push(w)
  }
  return { rest, files, heredoc }
}

/**
 * The files a Bash call puts content into, each as written and as an absolute path where its words
 * name one (home spelled out, a cd before it followed), with a copy's sources; and the writes whose
 * files its words do not name (a patch, an inline script, a script on standard input), each with
 * the files to read to find out, such as the patch.
 */
export const writes = (cmds: string[][], cwd: string, home: string): ModKitWrites => {
  const files: ModKitWrite[] = []
  const unnamed: ModKitWrites['unnamed'] = []
  const seen = new Set<string>()
  let dir: string | undefined = cwd
  const add = (word: string, path: string | undefined, sources?: string[]) => {
    if (!word || isDevice(path ?? word)) return
    const key = path ?? `word:${word}`
    if (seen.has(key)) return
    seen.add(key)
    files.push({ word, ...(path ? { path } : {}), ...(sources && sources.length ? { sources } : {}) })
  }
  const named = (w: string) => add(w, absolutePath(w, dir, home))
  for (const raw of cmds) {
    // Output redirects first, and taken out of the words, with descriptor copies (2>&1).
    const words: string[] = []
    for (let i = 0; i < raw.length; i++) {
      const w = raw[i] as string
      if (WRITE_REDIRECT.test(w)) {
        const target = raw[++i]
        if (target !== undefined) named(target)
      } else if (/^\d*>&[0-9-]*$/.test(w)) continue
      else words.push(w)
    }
    const { rest: args, files: inputs, heredoc } = splitInputs(words)
    const name = baseOf(args[0] ?? '')
    const rest = args.slice(1)
    if (name === 'cd' || name === 'pushd') {
      const target = rest.find(a => !a.startsWith('-') || a === '-')
      dir = target === undefined ? home || undefined : target === '-' ? undefined : absolutePath(target, dir, home)
      continue
    }
    if (name === 'tee') {
      for (const f of operands(rest, new Set()).ops) named(f)
      continue
    }
    if (name === 'sed' || name === 'gsed') {
      for (const f of sedInPlace(rest)) named(f)
      continue
    }
    const cluster = name === 'perl' ? PERL : name === 'ruby' ? RUBY : undefined
    if (cluster && inPlaceCluster(rest, cluster).length) {
      for (const f of inPlaceCluster(rest, cluster)) named(f)
      continue
    }
    if (name === 'awk' || name === 'gawk') {
      for (const f of awkInPlace(rest)) named(f)
      continue
    }
    if (name === 'dd') {
      for (const a of rest) if (a.startsWith('of=')) named(a.slice(3))
      continue
    }
    if (name === 'curl' || name === 'wget') {
      const out = name === 'curl' ? optionValue(rest, 'o', '--output') : optionValue(rest, 'O', '--output-document')
      if (out !== undefined && out !== '-') named(out)
      continue
    }
    const valued = VALUED[name]
    if (valued) {
      const { ops, opts } = operands(rest, valued)
      const intoOpt = opts.get('-t') ?? opts.get('--target-directory')
      let into: string | undefined
      let sources = ops
      if (typeof intoOpt === 'string') into = intoOpt
      else {
        const dest = ops[ops.length - 1]
        sources = ops.slice(0, -1)
        if (dest === undefined || sources.length === 0 || isRemote(dest)) continue
        // rsync copies a folder's contents for a source ending in /, so only the folder is known.
        if ((sources.length > 1 || dest.endsWith('/')) && !(name === 'rsync' && sources.some(s => s.endsWith('/')))) into = dest
        else {
          add(dest, absolutePath(dest, dir, home), sources.map(s => absolutePath(s, dir, home)).filter((p): p is string => !!p))
          continue
        }
      }
      for (const s of sources) {
        const intoPath = absolutePath(into, dir, home)
        add(`${into.replace(/\/+$/, '')}/${baseOf(s)}`, intoPath ? `${intoPath}/${baseOf(s)}` : undefined, [absolutePath(s, dir, home)].filter((p): p is string => !!p))
      }
      continue
    }
    if (name === 'patch') {
      const { ops, opts } = operands(rest, new Set(['-i', '-p', '-d', '-o', '-r', '-B', '-D', '-F', '-V', '-z', '--input', '--directory', '--output']))
      // patch [file to patch [patch file]]: the first operand is written, as named.
      if (ops[0] !== undefined) named(ops[0])
      const patches = [opts.get('-i'), opts.get('--input'), ops[1], ...inputs].filter((p): p is string => typeof p === 'string' && p !== '')
      unnamed.push({ what: 'a patch', words: raw, inputs: patches.map(p => absolutePath(p, dir, home)).filter((p): p is string => !!p) })
      continue
    }
    const g = git(args)
    if (g && (g.sub === 'apply' || g.sub === 'am')) {
      // Checked or summarised, a patch writes nothing.
      if (g.args.some(a => ['--check', '--stat', '--numstat', '--summary'].includes(a))) continue
      const at = g.dir === undefined ? dir : absolutePath(g.dir, dir, home)
      const patches = [...operands(g.args, new Set(['-p', '-C', '--directory', '--exclude', '--include'])).ops, ...inputs]
      unnamed.push({ what: 'a patch', words: raw, inputs: patches.map(p => absolutePath(p, at, home)).filter((p): p is string => !!p) })
      continue
    }
    // A shell fed its script on standard input (bash <<'EOF'): the reader drops a heredoc's body, so
    // what it writes is in no word here. bash -c reaches this reader already split into its commands.
    if (SHELLS.has(name)) {
      if ((heredoc || inputs.length) && !rest.some(a => !a.startsWith('-')))
        unnamed.push({ what: `a ${name} script on standard input`, words: raw, inputs: inputs.map(p => absolutePath(p, dir, home)).filter((p): p is string => !!p) })
      continue
    }
    if (INTERPRETERS.has(name)) {
      const code = name === 'deno' && rest[0] === 'eval' ? rest[1] : rest.find((_, i) => i > 0 && INLINE_FLAGS.has(rest[i - 1] as string))
      if (code !== undefined) {
        if (INLINE_WRITE.test(code)) unnamed.push({ what: `an inline ${name} script`, words: raw, inputs: [] })
      } else if (heredoc || inputs.length || rest.includes('-')) {
        unnamed.push({ what: `a ${name} script on standard input`, words: raw, inputs: inputs.map(p => absolutePath(p, dir, home)).filter((p): p is string => !!p) })
      }
    }
  }
  return { files, unnamed }
}
