import type { Lang } from './program.ts'

// What inline code can do, judged per language from that language's own surface (lessons review
// of #714 at fad450f). No build refuses code that can write a file or run a process, and code that
// builds code at run time, which cannot be read: a hand list of write idioms let every route not on
// it through (os.system, subprocess, child_process, backticks, open(p, 'r+'), L257). Each rule
// names what it saw, and the refusal says so.
//
// It reads the text, not a parse of it, so it errs toward refusing: a word that only looks like a
// call (a comment, a string) is refused too. What it still cannot see is said where it applies: a
// file the code reads and runs is "code it cannot read", as is a name computed at run time.

/** What the code can do, and the words that showed it. */
export type CodeVerdict = { does: 'run a process' | 'write files' | 'unreadable'; seen: string }

type Rule = { re: RegExp; seen: string | ((m: RegExpExecArray) => string) }
type Surface = { process: Rule[]; write: Rule[]; dynamic: Rule[]; judge?: (code: string) => CodeVerdict | undefined }

// A Python or Ruby call's arguments, split at the top level commas: the text after the opening
// bracket is cut into string literals, brackets, commas and the rest, so a comma or bracket inside
// a string stays in it. (These are the code's own literals; the shell's words came from mod-kit.)
const TOKEN = /(['"])(?:\\[\s\S]|(?!\1)[^\\])*\1|[([{]|[)\]}]|,|[^'"()[\]{},]+|['"]/g
const argsAt = (code: string, open: number): string[] => {
  const out: string[] = []
  let depth = 0
  let cur = ''
  for (const [t] of code.slice(open + 1).matchAll(TOKEN)) {
    if ('([{'.includes(t)) depth++
    else if (')]}'.includes(t)) {
      if (depth === 0) break
      depth--
    } else if (t === ',' && depth === 0) {
      out.push(cur.trim())
      cur = ''
      continue
    }
    cur += t
  }
  if (cur.trim()) out.push(cur.trim())
  return out
}
const stringValue = (arg: string | undefined): string | undefined => /^[rbuf]*(['"])(.*)\1$/s.exec(arg ?? '')?.[2]

// Python's open, in each of its spellings: the builtin, io.open and codecs.open take the mode
// second, a pathlib Path's .open takes it first, and os.open takes flags. A mode with w, a, x or +
// writes or updates.
const pythonOpen = (code: string): CodeVerdict | undefined => {
  for (const m of code.matchAll(/(\bos\.|\bio\.|\bcodecs\.|\.|(?<![\w.]))open\s*\(/g)) {
    const how = m[1] as string
    const args = argsAt(code, (m.index ?? 0) + m[0].length - 1)
    if (how === 'os.') {
      if (/O_(?:WRONLY|RDWR|CREAT|APPEND|TRUNC)/.test(args[1] ?? '')) return { does: 'write files', seen: 'os.open for writing' }
      continue
    }
    const kw = args.find(a => /^mode\s*=/.test(a))
    const mode = stringValue(kw ? kw.replace(/^mode\s*=\s*/, '') : how === '.' ? args[0] : args[1])
    if (mode !== undefined && /[waxX+]/.test(mode)) return { does: 'write files', seen: `open in mode ${mode}` }
  }
  return undefined
}

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
  for (const m of code.matchAll(/(?<![\w$@%&:]|->)open\s*\(?/g)) {
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
    judge: pythonOpen,
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
  },
  ruby: {
    process: [
      { re: /(?<![\w.:])(system|exec|spawn|fork|syscall)\b(?!\?)/, seen: m => m[1] as string },
      { re: /`[^`]*`/, seen: 'backticks' },
      { re: /%x[[{(<|!/]/, seen: '%x' },
      { re: /\b(IO\.popen|Open3|Process\.spawn|Process\.exec|PTY)\b/, seen: m => m[1] as string },
      { re: /(?<![\w.])open\s*\(?\s*['"]\|/, seen: 'open of a pipe' },
    ],
    write: [
      { re: /\bFile\.(write|binwrite|delete|unlink|rename|symlink|link|chmod|chown|lchmod|lchown|truncate|utime|mkfifo)\b/, seen: m => `File.${m[1]}` },
      { re: /\b(IO\.write|IO\.binwrite|IO\.copy_stream|FileUtils|Dir\.mkdir|Dir\.rmdir|Dir\.delete|Dir\.unlink)\b/, seen: m => m[1] as string },
    ],
    dynamic: [
      { re: /(?<![\w.:])(eval|instance_eval|class_eval|module_eval|instance_exec)\b/, seen: m => m[1] as string },
      { re: /(?<![\w.])(send|public_send|__send__)\s*\(/, seen: m => m[1] as string },
      { re: /(?<![\w.])(require|require_relative|load)\s*\(?\s*(?!['"])[\w$@]/, seen: m => `${m[1]} of a computed path` },
    ],
    judge: rubyOpen,
  },
  perl: {
    process: [
      { re: /(?<![\w$@%&:{]|->)(system|exec|fork)\b/, seen: m => m[1] as string },
      { re: /`[^`]*`/, seen: 'backticks' },
      { re: /\bqx\s*[^\w\s]/, seen: 'qx' },
    ],
    write: [
      { re: /(?<![\w$@%&:{]|->)(unlink|rename|mkdir|rmdir|chmod|chown|truncate|symlink|link|utime)\b/, seen: m => m[1] as string },
      { re: /\b(File::Copy|File::Path|copy|move|mkpath|rmtree|make_path|remove_tree)\s*[(:]/, seen: m => m[1] as string },
    ],
    dynamic: [
      // eval of a string; an eval block (`eval { ... }`) only catches errors.
      { re: /(?<![\w$@%&:]|->)eval\b\s*(?!\{)\S/, seen: 'eval of a string' },
      { re: /\bdo\s+['"$]/, seen: 'do of a file' },
      { re: /\brequire\s+['"$]/, seen: 'require of a file' },
    ],
    judge: perlOpen,
  },
  osascript: {
    process: [{ re: /\bdo shell script\b/i, seen: 'do shell script' }],
    write: [
      { re: /\bwith write permission\b/i, seen: 'open for access with write permission' },
      { re: /\btell application\s+"(?:Finder|System Events)"[\s\S]*?\b(delete|duplicate|move|make new)\b/i, seen: m => `Finder ${m[1]}` },
    ],
    dynamic: [{ re: /\b(run script|load script)\b/i, seen: m => m[1] as string }],
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
export const codeVerdict = (lang: Lang, code: string): CodeVerdict | undefined => {
  const s = SURFACES[lang]
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
