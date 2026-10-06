import type { Lang } from './program.ts'

// What inline code can do, judged per language from that language's own surface (lessons review
// of #714 at fad450f). Built for no build, which refuses code that can write a file or run a
// process, and code that builds code at run time, which cannot be read: a hand list of write idioms
// let every route not on it through (os.system, subprocess, child_process, backticks, open(p,
// 'r+'), L257). Each rule names what it saw, and the refusal says so. Moved here from scope-modes in
// #712, so the reader judges each command's program once and $.modkit.writes reports what inline
// code writes by the same rules, in place of the write reader's own idiom list.
//
// It reads the text, not a parse of it, so it errs toward refusing: a word that only looks like a
// call (a comment, a string) is refused too. What it still cannot see is said where it applies: a
// file the code reads and runs is "code it cannot read", as is a name computed at run time.

/** What the code can do, and the words that showed it. */
export type CodeVerdict = { does: 'run a process' | 'write files' | 'unreadable'; seen: string }

type Rule = { re: RegExp; seen: string | ((m: RegExpExecArray) => string) }
// `canonical` rewrites the language's other spellings of a capability to the one the rules read.
type Surface = { process: Rule[]; write: Rule[]; dynamic: Rule[]; judge?: (code: string) => CodeVerdict | undefined; canonical?: (code: string) => string }

// A Python or Ruby call's arguments, split at the top level commas, and where the call ends: the
// text after the opening bracket is cut into string literals, brackets, commas and the rest, so a
// comma or bracket inside a string stays in it. (These are the code's own literals; the shell's
// words came from mod-kit.)
const TOKEN = /(['"])(?:\\[\s\S]|(?!\1)[^\\])*\1|[([{]|[)\]}]|,|[^'"()[\]{},]+|['"]/g
const callAt = (code: string, open: number): { args: string[]; end: number } => {
  const args: string[] = []
  let depth = 0
  let cur = ''
  for (const m of code.slice(open + 1).matchAll(TOKEN)) {
    const t = m[0]
    if ('([{'.includes(t)) depth++
    else if (')]}'.includes(t)) {
      if (depth === 0) {
        if (cur.trim()) args.push(cur.trim())
        return { args, end: open + 1 + (m.index ?? 0) + 1 }
      }
      depth--
    } else if (t === ',' && depth === 0) {
      args.push(cur.trim())
      cur = ''
      continue
    }
    cur += t
  }
  if (cur.trim()) args.push(cur.trim())
  return { args, end: code.length }
}
const argsAt = (code: string, open: number): string[] => callAt(code, open).args
const stringValue = (arg: string | undefined): string | undefined => /^[rbuf]*(['"])(.*)\1$/s.exec(arg ?? '')?.[2]
const escaped = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

// Python's open, read by where each API takes its mode (#724: `Image.open('a.png')` and
// `gzip.open('data.json.gz')` were refused because the filename held an a). The builtin and the
// modules whose open takes (file, mode), io, codecs, gzip, bz2, lzma, tarfile, wave and the rest,
// take it second or as mode=; dbm and shelve take a flag second (c and n create, w writes; shelve's
// default is c); os.open takes O_ flags; any other .open is a method, a pathlib Path's taking the
// mode first: its argument counts as the mode only when it reads as one, so a filename alone is a
// read. A mode with w, a, x or + before any : (tarfile's 'w:gz') writes or updates.
const MODE_SECOND = new Set(['io', 'codecs', 'gzip', 'bz2', 'lzma', 'tarfile', 'wave', 'aifc', 'sunau', 'builtins', 'Image'])
const FLAG_SECOND = new Map([['dbm', 'r'], ['gnu', 'r'], ['ndbm', 'r'], ['dumb', 'r'], ['shelve', 'c']])
const PY_MODE = /^[rwxabtU+]+(?::\w*)?$/
const writesMode = (mode: string) => /[wax+]/.test(mode.split(':')[0] as string)
const pythonOpen = (code: string): CodeVerdict | undefined => {
  for (const m of code.matchAll(/(?:\b([A-Za-z_]\w*)\s*\.\s*|(\.)\s*|(?<![\w.]))open\s*\(/g)) {
    const receiver = m[1] ?? (m[2] ? '' : undefined)
    const args = argsAt(code, (m.index ?? 0) + m[0].length - 1)
    const kw = (name: string) => stringValue(args.find(a => new RegExp(`^${name}\\s*=`).test(a))?.replace(/^\w+\s*=\s*/, ''))
    if (receiver === 'os') {
      if (/O_(?:WRONLY|RDWR|CREAT|APPEND|TRUNC)/.test(args[1] ?? '')) return { does: 'write files', seen: 'os.open for writing' }
      continue
    }
    const flagDefault = receiver === undefined ? undefined : FLAG_SECOND.get(receiver)
    if (flagDefault !== undefined) {
      const flag = kw('flag') ?? stringValue(args[1]) ?? flagDefault
      if (/[cnw]/.test(flag)) return { does: 'write files', seen: `${receiver === 'shelve' ? 'shelve' : 'dbm'}.open with flag ${flag}` }
      continue
    }
    const positional = args.filter(a => !/^\w+\s*=/.test(a)).map(stringValue)
    const mode =
      kw('mode') ??
      (receiver === undefined || MODE_SECOND.has(receiver) ? positional[1] : [positional[0], positional[1]].find(a => a !== undefined && PY_MODE.test(a)))
    if (mode !== undefined && writesMode(mode)) return { does: 'write files', seen: `open in mode ${mode}` }
  }
  return undefined
}

// fileinput rewrites every file it reads when inplace is set, by name or as its second argument
// (#730). The reader's canonical spelling makes `from fileinput import input` read as fileinput.
const FALSE = /^(?:False|0|None)$/
const pythonFileinput = (code: string): CodeVerdict | undefined => {
  for (const m of code.matchAll(/\bfileinput\s*\.\s*(?:input|FileInput)\s*\(/g)) {
    const args = argsAt(code, (m.index ?? 0) + m[0].length - 1)
    const named = args.find(a => /^inplace\s*=/.test(a))?.replace(/^inplace\s*=\s*/, '')
    const inplace = named ?? args.filter(a => !/^\w+\s*=/.test(a))[1]
    if (inplace !== undefined && !FALSE.test(inplace.trim())) return { does: 'write files', seen: 'fileinput with inplace' }
  }
  return undefined
}

// pathlib's rename and replace move a file (#730). Told from str.replace, which takes two
// arguments or more, and from a data frame's rename or replace, which take keywords, a mapping or a
// function: only a call with one plain argument and no keywords is read as a move.
// A pandas series or data frame's rename and replace take one name too (#760: `s.rename('total')`
// was refused as a move, Dan's decision 2026-10-05), so a receiver provably bound from pandas is
// exempt, and only that receiver: pandas being imported says nothing about any other object
// (lessons review of #818). A chained call (`pd.Series([1]).rename('t')`) has no name to prove,
// so it is still read as a move, a refusal of the safe kind. The code arrives in its canonical spelling, so
// every alias of pandas reads as `pandas.` and `from pandas import Series` makes `Series(` read as
// `pandas.Series(`. A name is pandas's when it is assigned from an expression starting with
// `pandas.` or with a name already known to be, which follows `df = pandas.read_csv(...)` then
// `s = df['x']`; a receiver is that name, or a subscript of it.
// A name counts only when EVERY assignment to it is from pandas: one rebound to anything else
// (`df = Path('a')`), or bound by any other route (a for loop, a with, a parameter, a tuple target,
// :=), is unproven and judged like any other receiver (lessons review of #818).
const pandasNames = (code: string): Set<string> => {
  const assigned = new Map<string, (string | undefined)[]>()
  for (const m of code.matchAll(/(?:^|[;\n])[ \t]*([A-Za-z_]\w*)\s*=(?!=)\s*([A-Za-z_]\w*)?/g)) {
    const roots = assigned.get(m[1] as string) ?? []
    roots.push(m[2])
    assigned.set(m[1] as string, roots)
  }
  const reboundElsewhere = (name: string): boolean => {
    const n = escaped(name)
    return [
      new RegExp(`\\bfor\\s+[^:\\n]*\\b${n}\\b[^:\\n]*\\bin\\b`),
      new RegExp(`\\bas\\s+${n}\\b`),
      new RegExp(`\\b${n}\\s*:=`),
      new RegExp(`(?:^|[;\\n])[ \\t]*[\\w\\s,()[\\]*]*,\\s*\\(?\\s*${n}\\s*\\)?\\s*(?:,[^=\\n]*)?=(?!=)`),
      new RegExp(`(?:^|[;\\n])[ \\t]*\\(?\\s*${n}\\s*,[^=\\n]*=(?!=)`),
      new RegExp(`\\b(?:def\\s+\\w+\\s*\\([^)]*|lambda\\b[^:]*)\\b${n}\\b`),
    ].some(r => r.test(code))
  }
  const names = new Set<string>(['pandas'])
  for (let grew = true; grew; ) {
    grew = false
    for (const [name, roots] of assigned) {
      if (names.has(name) || reboundElsewhere(name)) continue
      // `s = s.rename(...)` derives the name from itself, which keeps whatever the rest made it.
      if (roots.every(r => r !== undefined && (names.has(r) || r === name)) && roots.some(r => r !== undefined && names.has(r))) {
        names.add(name)
        grew = true
      }
    }
  }
  return names
}
const pythonMoves = (code: string): CodeVerdict | undefined => {
  const pandas = pandasNames(code)
  for (const m of code.matchAll(/\.\s*(rename|replace)\s*\(/g)) {
    const receiver = /([A-Za-z_]\w*)(?:\s*\[[^\]]*\])*\s*$/.exec(code.slice(0, m.index))?.[1]
    if (receiver !== undefined && pandas.has(receiver)) continue
    const args = argsAt(code, (m.index ?? 0) + m[0].length - 1)
    if (args.length === 1 && !/^\w+\s*=|^[{[]|^lambda\b|^str\s*\./.test(args[0] as string)) return { does: 'write files', seen: m[1] as string }
  }
  return undefined
}
const pythonJudge = (code: string): CodeVerdict | undefined => pythonOpen(code) ?? pythonFileinput(code) ?? pythonMoves(code)

// Python binds a module or one of its functions in many spellings, each rewritten here to the one
// the rules read (#724: `__import__('os').system(...)` and `from os import system` ran unjudged).
// A module named by a string (__import__, import_module, sys.modules) becomes its name; `import X as
// Y` and `Y = X` make Y. read as X.; `from X import a as b` makes b read as X.a; a star import
// judges every bare call once more as that module's; and posix and nt are os.
const SAME_MODULE = new Map([['posix', 'os'], ['nt', 'os']])
const pyModule = (m: string) => SAME_MODULE.get(m) ?? m
const pythonCanonical = (code: string): string => {
  let text = ''
  let at = 0
  for (const m of code.matchAll(/\b(?:__import__|import_module)\s*\(/g)) {
    const open = (m.index ?? 0) + m[0].length - 1
    if ((m.index ?? 0) < at) continue
    const call = callAt(code, open)
    const name = stringValue(call.args[0])
    if (name === undefined || !/^[\w.]+$/.test(name)) continue
    text += code.slice(at, m.index) + name
    at = call.end
  }
  text = (text + code.slice(at)).replace(/\bsys\s*\.\s*modules\s*\[\s*[rbu]*(['"])([\w.]+)\1\s*\]/g, '$2')
  const modules = new Map<string, string>()
  const imported = new Set<string>()
  for (const m of text.matchAll(/(?:^|[;\n])[ \t]*import\s+([^;\n#]+)/g)) {
    for (const part of (m[1] as string).split(',')) {
      const p = /^\s*([\w.]+)(?:\s+as\s+(\w+))?\s*$/.exec(part)
      if (!p) continue
      const mod = pyModule(p[1] as string)
      imported.add(p[1] as string)
      if (p[2]) modules.set(p[2], mod)
      else if (mod !== p[1]) modules.set(p[1] as string, mod)
    }
  }
  for (const m of text.matchAll(/(?:^|[;\n])[ \t]*(\w+)\s*=\s*([\w.]+)\s*(?=$|[;\n#])/g)) {
    const target = m[2] as string
    if (imported.has(target) || modules.has(target)) modules.set(m[1] as string, modules.get(target) ?? pyModule(target))
  }
  const names = new Map<string, string>()
  const stars: string[] = []
  for (const m of text.matchAll(/(?:^|[;\n])[ \t]*from\s+([\w.]+)\s+import\s+(\([^)]*\)|[^;\n#]+)/g)) {
    const mod = pyModule(m[1] as string)
    const list = (m[2] as string).replace(/[()]/g, '')
    if (list.trim() === '*') stars.push(mod)
    else
      for (const part of list.split(',')) {
        const p = /^\s*(\w+)(?:\s+as\s+(\w+))?\s*$/.exec(part)
        if (p) names.set((p[2] ?? p[1]) as string, `${mod}.${p[1]}`)
      }
  }
  for (const [alias, mod] of modules) text = text.replace(new RegExp(`(?<![\\w.])${escaped(alias)}\\s*\\.`, 'g'), `${mod}.`)
  for (const [name, full] of names) text = text.replace(new RegExp(`(?<![\\w.])${escaped(name)}\\b`, 'g'), full)
  const bound = text
  for (const mod of stars) text += `\n${bound.replace(/(?<![\w.])([A-Za-z_]\w*)(?=\s*\()/g, `${mod}.$1`)}`
  return text
}

// node binds fs under any name, by require or import, or takes its functions out by destructuring;
// each is rewritten to fs. so the rules see `fs.rm(` however it was reached (#724).
const NODE_FS = /^(?:node:)?fs(?:\/promises)?$/
const nodeCanonical = (code: string): string => {
  const aliases: string[] = []
  const names = new Map<string, string>()
  // require('fs') or import('fs'), and its .promises, the module's name in the group `mod`.
  const from = `(?:await\\s+)?(?:require|import)\\s*\\(\\s*(?<q>['"\`])(?<mod>[^'"\`]+)\\k<q>\\s*\\)(?:\\s*\\.\\s*promises)?`
  const isFs = (m: RegExpMatchArray) => NODE_FS.test(m.groups?.mod ?? m[3] ?? '')
  for (const m of code.matchAll(new RegExp(`\\b(?:const|let|var)\\s+([\\w$]+)\\s*=\\s*${from}`, 'g'))) if (isFs(m)) aliases.push(m[1] as string)
  for (const m of code.matchAll(/\bimport\s+(?:\*\s+as\s+)?([\w$]+)\s+from\s+(['"])([^'"]+)\2/g)) if (isFs(m)) aliases.push(m[1] as string)
  const parts = (list: string, sep: RegExp) => {
    for (const part of list.split(',')) {
      const [orig, bound] = part.split(sep).map(s => s.trim())
      if (orig && /^[\w$]+$/.test(orig)) names.set(bound && /^[\w$]+$/.test(bound) ? bound : orig, orig)
    }
  }
  for (const m of code.matchAll(new RegExp(`\\b(?:const|let|var)\\s*\\{([^}]*)\\}\\s*=\\s*${from}`, 'g'))) if (isFs(m)) parts(m[1] as string, /:/)
  for (const m of code.matchAll(/\bimport\s*\{([^}]*)\}\s*from\s*(['"])([^'"]+)\2/g)) if (isFs(m)) parts(m[1] as string, /\s+as\s+/)
  let text = code
  for (const alias of aliases) text = text.replace(new RegExp(`(?<![\\w$.])${escaped(alias)}\\s*\\.`, 'g'), 'fs.')
  for (const [name, orig] of names) text = text.replace(new RegExp(`(?<![\\w$.])${escaped(name)}(?![\\w$])`, 'g'), `fs.${orig}`)
  return text
}

// A ruby builtin reached through its own module is the builtin (#724: Kernel.system,
// ::Kernel.system and Kernel::system ran unjudged), and Const::name is Const.name (IO::popen).
const rubyCanonical = (code: string): string => code.replace(/\b([A-Z]\w*)\s*::\s*(?=[a-z_])/g, '$1.').replace(/(?:::)?\bKernel\s*\.\s*/g, '')
// A perl builtin reached through CORE::, CORE::GLOBAL:: or POSIX:: is the builtin (#724).
const perlCanonical = (code: string): string => code.replace(/(?:(?<!&)&\s*)?\bCORE::(?:GLOBAL::)?(?=\w)|\bPOSIX::(?=\w)/g, '')

// Ruby's File.open and File.new take the mode second, as a string or File:: flags.
const rubyOpen = (code: string): CodeVerdict | undefined => {
  for (const m of code.matchAll(/\bFile\.(open|new)\s*\(?/g)) {
    const at = (m.index ?? 0) + m[0].length - 1
    const args = m[0].endsWith('(') ? argsAt(code, at) : argsAt(`(${code.slice(at + 1).split(/\bdo\b|\{|\n|;/)[0]})`, 0)
    const mode = stringValue(args[1])
    if (mode !== undefined && /[wa+]/.test(mode)) return { does: 'write files', seen: `File.${m[1]} in mode ${mode}` }
    if (/File::(?:WRONLY|RDWR|CREAT|APPEND|TRUNC)/.test(args[1] ?? '')) return { does: 'write files', seen: `File.${m[1]} for writing` }
  }
  return undefined
}

// Perl's open: a mode or a two argument target starting with > or +< (or +>) writes, and one with
// | at either end, or the |- and -| modes, runs a process.
const perlOpen = (code: string): CodeVerdict | undefined => {
  for (const m of code.matchAll(/(?<![\w$@%:]|->|(?<!&)&)open\s*\(?/g)) {
    const rest = code.slice((m.index ?? 0) + m[0].length).split(';')[0] ?? ''
    for (const s of rest.matchAll(/(['"])(.*?)\1/g)) {
      const v = (s[2] as string).trim()
      if (/^\|-?$|^-\|$|^\||\|$/.test(v)) return { does: 'run a process', seen: 'open to a pipe' }
      if (/^(?:\+?>|\+<)/.test(v)) return { does: 'write files', seen: 'open for writing' }
    }
  }
  return undefined
}

const SURFACES: Record<Lang, Surface> = {
  python: {
    process: [
      { re: /\bos\.(system|popen|spawn\w*|exec\w*|fork\w*|posix_spawn\w*|startfile)\b/, seen: m => `os.${m[1]}` },
      { re: /\bsubprocess\b/, seen: 'subprocess' },
      { re: /\bpty\b/, seen: 'pty' },
      { re: /\basyncio\.create_subprocess_\w+/, seen: 'asyncio.create_subprocess' },
    ],
    write: [
      { re: /\bos\.(remove|unlink|rename|renames|replace|rmdir|removedirs|mkdir|makedirs|truncate|chmod|chown|lchown|link|symlink|utime|write|mkfifo|mknod)\s*\(/, seen: m => `os.${m[1]}` },
      { re: /\bshutil\.(copy\w*|move|rmtree|chown|make_archive|unpack_archive)\s*\(/, seen: m => `shutil.${m[1]}` },
      { re: /\.(write_text|write_bytes|touch|mkdir|rmdir|unlink|symlink_to|hardlink_to|chmod)\s*\(/, seen: m => m[1] as string },
    ],
    dynamic: [
      { re: /(?<![\w.])(eval|exec|compile)\s*\(/, seen: m => m[1] as string },
      { re: /\b__import__\s*\(\s*(?!['"])/, seen: '__import__ of a computed name' },
      { re: /\bimport_module\s*\(\s*(?!['"])/, seen: 'import_module of a computed name' },
      { re: /\bgetattr\s*\(\s*(?:os|subprocess|shutil|builtins)\b/, seen: 'getattr on os' },
    ],
    judge: pythonJudge,
    canonical: pythonCanonical,
  },
  node: {
    process: [
      { re: /\bchild_process\b/, seen: 'child_process' },
      { re: /\b(Bun\.spawn\w*|Bun\.\$|Deno\.run|Deno\.Command)/, seen: m => m[1] as string },
    ],
    write: [
      { re: /\b(writeFile|writeFileSync|appendFile|appendFileSync|createWriteStream|rmSync|unlinkSync|renameSync|copyFileSync|cpSync|mkdirSync|rmdirSync|truncateSync|symlinkSync|linkSync|chmodSync|chownSync|utimesSync|mkdtempSync|writeSync|ftruncateSync|writev|writevSync)\b/, seen: m => m[1] as string },
      { re: /\b(?:fs|fsp|fsPromises|promises)\s*\.\s*(rm|unlink|rename|copyFile|cp|mkdir|rmdir|truncate|symlink|link|chmod|chown|utimes|mkdtemp|write)\s*\(/, seen: m => `fs.${m[1]}` },
      { re: /\bopen(?:Sync)?\s*\([^)]*,\s*['"][^'"]*[wa+][^'"]*['"]/, seen: 'open for writing' },
      { re: /\b(Bun\.write|Deno\.(?:writeTextFile|writeFile|remove|rename|mkdir|create|truncate|symlink|copyFile|chmod))\b/, seen: m => m[1] as string },
    ],
    dynamic: [
      { re: /(?<![\w.$])eval\s*\(/, seen: 'eval' },
      { re: /\bnew\s+Function\s*\(|(?<![\w.$])Function\s*\(/, seen: 'new Function' },
      { re: /\brequire\s*\(\s*(?!(['"])[^'"]*\1\s*\)|`[^`$]*`\s*\))/, seen: 'require of a computed path' },
      { re: /\bimport\s*\(\s*(?!(['"])[^'"]*\1\s*\)|`[^`$]*`\s*\))/, seen: 'import of a computed path' },
      { re: /\bvm\s*\.\s*(?:runIn\w*|compileFunction|Script)\b/, seen: 'vm' },
      { re: /\bprocess\.(?:binding|dlopen)\b/, seen: 'process.binding' },
    ],
    canonical: nodeCanonical,
  },
  ruby: {
    process: [
      { re: /(?<![\w.:])(system|exec|spawn|fork|syscall)\b(?!\?)/, seen: m => m[1] as string },
      { re: /`[^`]*`/, seen: 'backticks' },
      { re: /%x[[{(<|!/]/, seen: '%x' },
      { re: /\b(IO\.popen|Open3|Process\.spawn|Process\.exec|Process\.fork|PTY)\b/, seen: m => m[1] as string },
      // A builtin named to send or method runs on any receiver ("".send(:system, ...)), where a
      // method of that name on an object (conn.exec) is not the builtin. The whole name, so
      // send(:spawn_worker) and method(:fork_helper) name no builtin (#730).
      { re: /\b(?:send|__send__|public_send|method|instance_method)\s*\(?\s*[:'"](?:(system|exec|spawn|fork|syscall)(?![\w?!])|`)/, seen: m => m[1] ?? 'backticks' },
      { re: /(?<![\w.])open\s*\(?\s*['"]\|/, seen: 'open of a pipe' },
    ],
    write: [
      { re: /\bFile\.(write|binwrite|delete|unlink|rename|symlink|link|chmod|chown|lchmod|lchown|truncate|utime|mkfifo)\b/, seen: m => `File.${m[1]}` },
      { re: /\b(IO\.write|IO\.binwrite|IO\.copy_stream|FileUtils|Dir\.mkdir|Dir\.rmdir|Dir\.delete|Dir\.unlink)\b/, seen: m => m[1] as string },
    ],
    dynamic: [
      { re: /(?<![\w.:])(eval|instance_eval|class_eval|module_eval|instance_exec)\b/, seen: m => m[1] as string },
      // A send whose method is named by a literal is read above; one built at run time cannot be.
      // `def send(x)` defines a method of that name, which sends nothing (#760, Dan's decision).
      { re: /(?<![\w.])(?<!\bdef\s+(?:self\s*\.\s*)?)(?:send|public_send|__send__)\s*(?:\(\s*|\s+)(?!(?::\w+[?!=]?|(['"])\w+[?!=]?\1)\s*(?:[,)\n;]|$))/, seen: 'send of a computed name' },
      { re: /(?<![\w.])(require|require_relative|load)\s*\(?\s*(?!['"])[\w$@]/, seen: m => `${m[1]} of a computed path` },
    ],
    judge: rubyOpen,
    canonical: rubyCanonical,
  },
  perl: {
    process: [
      { re: /(?<![\w$@%:{]|->|(?<!&)&)(system|exec|fork)\b/, seen: m => m[1] as string },
      { re: /\bIPC::(Open[23]|Run3?|Cmd|System::Simple)\b/, seen: m => `IPC::${m[1]}` },
      { re: /`[^`]*`/, seen: 'backticks' },
      { re: /\bqx\s*[^\w\s]/, seen: 'qx' },
    ],
    write: [
      { re: /(?<![\w$@%:{]|->|(?<!&)&)(unlink|rename|mkdir|rmdir|chmod|chown|truncate|symlink|link|utime)\b/, seen: m => m[1] as string },
      { re: /\b(File::Copy|File::Path|copy|move|mkpath|rmtree|make_path|remove_tree)\s*[(:]/, seen: m => m[1] as string },
    ],
    dynamic: [
      // eval of a string; an eval block (`eval { ... }`) only catches errors.
      { re: /(?<![\w$@%:]|->|(?<!&)&)eval\b\s*(?!\{)\S/, seen: 'eval of a string' },
      { re: /\bdo\s+['"$]/, seen: 'do of a file' },
      { re: /\brequire\s+['"$]/, seen: 'require of a file' },
    ],
    judge: perlOpen,
    canonical: perlCanonical,
  },
  // AppleScript, and JavaScript for Automation (osascript -l JavaScript), which reaches the same
  // capabilities by other names and adds the Objective-C bridge (#760: doShellScript, $.NSTask and
  // $.NSFileManager ran unjudged). Both are read whatever -l says: neither language's words for a
  // process or a write mean anything else in the other.
  osascript: {
    process: [
      { re: /\bdo shell script\b/i, seen: 'do shell script' },
      // Terminal's do script runs its text as a shell command in a new window.
      { re: /\bdo script\b/i, seen: 'do script' },
      { re: /\.\s*doShellScript\s*\(/, seen: 'doShellScript' },
      { re: /\.\s*doScript\s*\(/, seen: 'doScript' },
      { re: /\b(NSTask|NSWorkspace\b[\s\S]*?\b(?:launchApplication|openURL|openFile|openApplicationAtURL))\b/, seen: m => (m[1] as string).startsWith('NSTask') ? 'NSTask' : 'NSWorkspace launching' },
      // The C library through the bridge: ObjC.import('stdlib') then $.system('...').
      { re: /\$\s*\.\s*(system|popen|execv\w*|execl\w*|posix_spawn\w*|fork)\s*\(/, seen: m => `$.${m[1]}` },
    ],
    write: [
      { re: /\bwith write permission\b/i, seen: 'open for access with write permission' },
      { re: /\btell application\s+"(?:Finder|System Events)"[\s\S]*?\b(delete|duplicate|move|make new)\b/i, seen: m => `Finder ${m[1]}` },
      { re: /\bwritePermission\s*:\s*true\b/, seen: 'openForAccess with writePermission' },
      { re: /\bApplication\s*\(\s*(['"])(?:Finder|System Events)\1\s*\)[\s\S]*?\.\s*(delete|duplicate|move|make)\s*\(/, seen: m => `Finder ${m[2]}` },
      { re: /\b(NSFileManager|NSFileHandle\s*\.\s*fileHandleForWriting\w*)\b/, seen: m => (m[1] as string).startsWith('NSFileManager') ? 'NSFileManager' : 'NSFileHandle for writing' },
      { re: /\.\s*(writeToFile\w*|writeToURL\w*)\b/, seen: m => m[1] as string },
      { re: /\$\s*\.\s*(unlink|remove|rename|mkdir|rmdir|fopen|open|creat|truncate|chmod|symlink|link)\s*\(/, seen: m => `$.${m[1]}` },
    ],
    dynamic: [
      { re: /\b(run script|load script)\b/i, seen: m => m[1] as string },
      { re: /(?<![\w.$])eval\s*\(/, seen: 'eval' },
      { re: /\bnew\s+Function\s*\(|(?<![\w.$])Function\s*\(/, seen: 'new Function' },
      { re: /\.\s*(runScript|loadScript)\s*\(/, seen: m => m[1] as string },
      { re: /\b(NSAppleScript|OSAScript)\b/, seen: m => m[1] as string },
      { re: /\bObjC\s*\.\s*bindFunction\b|\$\s*\.\s*dl(?:open|sym)\s*\(|\bperformSelector\w*\b|\bNSSelectorFromString\b/, seen: 'a call the bridge builds at run time' },
    ],
  },
  awk: {
    process: [
      { re: /\bsystem\s*\(/, seen: 'system' },
      { re: /\|\s*&?\s*getline\b|\bprintf?\b[^;{}\n]*\|\s*&?\s*["A-Za-z_($]/, seen: 'a pipe' },
    ],
    write: [{ re: /\bprintf?\b[^;{}\n]*?>>?\s*["A-Za-z_($]/, seen: 'print to a file' }],
    dynamic: [{ re: /@(include|load)\b/, seen: m => `@${m[1]}` }],
  },
  sed: {
    // GNU sed's e command and s///e flag run the pattern space as a shell command; w writes it.
    process: [{ re: /(?:^|[;\n{}/\d$!])\s*e(?:\s|;|$|\})|\/[gpIiMmw0-9]*e[gpIiMm0-9]*(?:\s|;|$|\})/, seen: 'the e command' }],
    write: [{ re: /(?:^|[;\n{}\d$!])\s*[wW]\s+\S|\/[gpIiMme0-9]*w\s+\S/, seen: 'the w command' }],
    dynamic: [],
  },
}

const first = (rules: Rule[], code: string): string | undefined => {
  for (const r of rules) {
    const m = r.re.exec(code)
    if (m) return typeof r.seen === 'string' ? r.seen : r.seen(m)
  }
  return undefined
}

/** What inline code in a language can do that no build refuses, or undefined when it only reads. */
export const codeVerdict = (lang: Lang, inline: string): CodeVerdict | undefined => {
  const s = SURFACES[lang]
  // Read in the one spelling the rules know, whichever of the language's others it was written in.
  const code = s.canonical?.(inline) ?? inline
  const process = first(s.process, code)
  if (process) return { does: 'run a process', seen: process }
  const judged = s.judge?.(code)
  if (judged?.does === 'run a process') return judged
  const write = first(s.write, code)
  if (write) return { does: 'write files', seen: write }
  if (judged) return judged
  const dynamic = first(s.dynamic, code)
  if (dynamic) return { does: 'unreadable', seen: dynamic }
  return undefined
}
