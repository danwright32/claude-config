// What a FILE's text reaches beyond itself (#2710): a program it starts, a web request it makes, or
// a module it loads by a name given at run time. code.ts judges a command's inline code, through
// $.modkit.pipeline, and errs toward refusing, so a process word anywhere counts there, a string
// included. A file read for what it does is judged here instead, by what it imports or calls: a
// program's or a module's name in a string, a pattern, a comment or a template's text is data (a
// gate's list of what it refuses), and never counts. The Slack alert guard asked its own lists this
// (#2662) and now asks this, synchronously inside its search, from a byte for byte copy at
// hooks/mod-kit/reaches.ts (tools/check-mod-shared-parts.sh holds the copy to this one), since a mod
// cannot import another mod's files. Pure.
//
// It reads the text, not a parse of it. Each list is wide on purpose: a module that only can reach
// out (socket, ssl, asyncio) counts as one that does. What it cannot see: a module bound to another
// name and called later counts only by its import; a JavaScript quote opening a string that never
// closes (an apostrophe in JSX text) hides the rest of its line.
import { pythonText, quotedEnd } from './quoted.ts'

/** What a file's code reaches beyond itself, and the words that showed it. */
export type Reach = { does: 'run a process' | 'make a web request' | 'load a module by name'; seen: string }
/** The languages a file is read in, named as mod-kit's program reader names them. */
export type FileLang = 'python' | 'node'

type Rule = { re: RegExp; reach: (m: RegExpExecArray) => Reach }

// Python's modules that start a program, and those that reach the network. Slack's own client
// modules call its web API.
const PY_RUNS = 'subprocess|pty|multiprocessing|asyncio'
const PY_WEB = 'urllib\\d?|requests|httpx|aiohttp|httplib2?|http|socketserver|socket|pycurl|websockets?|smtplib|ftplib|telnetlib|ssl|xmlrpc|slack\\w*'
const PY_MODULES = `${PY_RUNS}|${PY_WEB}`
const pyModule = (seen: string): Reach => ({ does: new RegExp(`^(?:${PY_RUNS})$`).test(seen) ? 'run a process' : 'make a web request', seen })
const PY_RULES: Rule[] = [
  { re: new RegExp(`\\bfrom[ \\t]+(${PY_MODULES})(\\.[\\w.]+)?[ \\t]+import\\b`), reach: m => pyModule(m[1] as string) },
  { re: new RegExp(`\\bimport[ \\t]+(?:[\\w.]+(?:[ \\t]+as[ \\t]+\\w+)?[ \\t]*,[ \\t]*)*(${PY_MODULES})\\b`), reach: m => pyModule(m[1] as string) },
  { re: /\bos\s*\.\s*(system|popen\w*|exec[lv]\w*|spawn\w*|posix_spawn\w*|startfile)\s*\(/, reach: m => ({ does: 'run a process', seen: `os.${m[1]}` }) },
  { re: /\burlopen\s*\(/, reach: () => ({ does: 'make a web request', seen: 'urlopen' }) },
  { re: /\b(__import__|import_module)\s*\(/, reach: m => ({ does: 'load a module by name', seen: m[1] as string }) },
]

// Node's, Deno's and Bun's modules that start a program, and those that reach the network.
const NODE_RUNS = 'child_process|worker_threads'
const NODE_WEB = 'https?|http2|net|tls|dgram|node-fetch|cross-fetch|undici|axios|got|ky|superagent|needle|request|ws'
const NODE_RULES: Rule[] = [
  {
    re: new RegExp(`(?:\\bfrom\\s*|\\brequire\\s*\\(\\s*|\\bimport\\s*\\(\\s*|\\bimport\\s+)["'\`](?:node:)?(${NODE_RUNS}|${NODE_WEB})["'\`/]`),
    reach: m => ({ does: new RegExp(`^(?:${NODE_RUNS})$`).test(m[1] as string) ? 'run a process' : 'make a web request', seen: m[1] as string }),
  },
  { re: /\b(Bun|Deno)\s*\.\s*(spawn\w*|run|Command|connect)\b/, reach: m => ({ does: m[2] === 'connect' ? 'make a web request' : 'run a process', seen: `${m[1]}.${m[2]}` }) },
  { re: /\bprocess\s*\.\s*run\s*\(/, reach: () => ({ does: 'run a process', seen: 'process.run' }) },
  // Bun's and zx's shell, a template tagged with $.
  { re: /\$`/, reach: () => ({ does: 'run a process', seen: '$`' }) },
  { re: /\b(fetch|axios|got|ky|superagent|needle|sendBeacon)\s*\(/, reach: m => ({ does: 'make a web request', seen: m[1] as string }) },
  { re: /\b(axios|got|ky|superagent|needle|https?|undici)\s*\.\s*(\w+)\s*\(/, reach: m => ({ does: 'make a web request', seen: `${m[1]}.${m[2]}` }) },
  { re: /\bnew\s+(XMLHttpRequest|WebSocket|EventSource)\b/, reach: m => ({ does: 'make a web request', seen: m[1] as string }) },
]

const blank = (s: string): string => s.replace(/[^\n]/g, ' ')

// A python file's code with every string and comment emptied, each place kept where it was; an
// f-string keeps the code in its braces (`{{` is a brace of its text).
const pythonCode = (text: string): string => {
  const parts: string[] = []
  let at = 0
  for (const s of pythonText(text)) {
    parts.push(text.slice(at, s.from))
    const body = text.slice(s.from, s.to)
    if (s.kind !== 'formatted') parts.push(blank(body))
    else {
      let depth = 0
      let kept = ''
      for (let i = 0; i < body.length; i++) {
        const c = body[i] as string
        if (depth === 0 && (c === '{' || c === '}') && body[i + 1] === c) {
          kept += '  '
          i++
        } else if (c === '{') {
          depth++
          kept += depth === 1 ? ' ' : c
        } else if (c === '}' && depth > 0) {
          depth--
          kept += depth === 0 ? ' ' : c
        } else kept += depth > 0 || c === '\n' ? c : ' '
      }
      parts.push(kept)
    }
    at = s.to
  }
  parts.push(text.slice(at))
  return parts.join('')
}

// What may stand before a JavaScript regular expression literal, so a `/` there opens one rather
// than dividing: an operator or an opening bracket, a keyword that takes an expression, or nothing.
const REGEX_AFTER = /(?:[(,=:[!&|?{};+\-*%<>~^]|\b(?:return|typeof|instanceof|in|of|new|delete|void|throw|case|do|else|yield|await))$/
// What stands before a module specifier, whose string names what the file loads.
const SPECIFIER = /(?:\bfrom\s*|\brequire\s*\(\s*|\bimport\s*\(\s*|\bimport\s+)$/


// Where the regular expression literal opening at `i` closes, or -1 when it meets a line break first.
const regexEnd = (text: string, i: number): number => {
  let inClass = false
  for (let j = i + 1; j < text.length; j++) {
    const c = text[j]
    if (c === '\\') j++
    else if (c === '\n') return -1
    else if (c === '[') inClass = true
    else if (c === ']') inClass = false
    else if (c === '/' && !inClass) return j
  }
  return -1
}

// A JavaScript or TypeScript file's code with every comment, string, regular expression and
// template text emptied, each place kept where it was; a module specifier's string is kept, and a
// template's ${...} is code.
const nodeCode = (text: string): string => {
  const parts: string[] = []
  // The last characters of code copied, white space folded and emptied text left as one space,
  // which decide whether a `/` opens a pattern and whether a string is a module specifier.
  let tail = ''
  // Everything before `from` is written; each step copies or empties the text up to a place.
  let from = 0
  const copy = (to: number) => {
    if (to <= from) return
    const run = text.slice(from, to)
    parts.push(run)
    tail = (tail + run.replace(/\s+/g, ' ')).slice(-40)
    from = to
  }
  const empty = (to: number) => {
    if (to <= from) return
    parts.push(blank(text.slice(from, to)))
    tail = `${tail} `.slice(-40)
    from = to
  }
  // For each ${...} the scan is inside, how many braces of its own code are open.
  const fields: number[] = []
  // A template's text from `at`, emptied up to its closing backtick or the ${ of a field; where the
  // scan goes on.
  const templateText = (at: number): number => {
    copy(at)
    let j = at
    while (j < text.length && text[j] !== '`' && !(text[j] === '$' && text[j + 1] === '{')) j += text[j] === '\\' ? 2 : 1
    j = Math.min(j, text.length)
    empty(j)
    if (text[j] !== '$') return j + 1
    fields.push(0)
    return j + 2
  }
  let i = 0
  while (i < text.length) {
    const c = text[i] as string
    const next = text[i + 1]
    if (c === '`') i = templateText(i + 1)
    else if (c === '}' && fields.length && fields[fields.length - 1] === 0) {
      fields.pop()
      i = templateText(i + 1)
    } else if (c === '{' || c === '}') {
      if (fields.length) fields[fields.length - 1] = (fields[fields.length - 1] as number) + (c === '{' ? 1 : -1)
      i++
    } else if (c === '/' && (next === '/' || next === '*')) {
      const e = next === '/' ? text.indexOf('\n', i) : text.indexOf('*/', i + 2)
      const to = e < 0 ? text.length : next === '/' ? e : e + 2
      copy(i)
      empty(to)
      i = to
    } else if (c === '"' || c === "'") {
      const e = quotedEnd(text, i, 'code')
      const line = text.indexOf('\n', i)
      const to = e >= 0 ? e : line < 0 ? text.length : line
      const specifier = SPECIFIER.test(tail + text.slice(Math.max(from, i - 40), i).replace(/\s+/g, ' '))
      copy(i + 1)
      if (specifier) copy(to)
      else empty(to)
      i = e >= 0 ? e + 1 : to
    } else if (c === '/') {
      const ahead = (tail + text.slice(Math.max(from, i - 40), i).replace(/\s+/g, ' ')).trimEnd()
      const e = ahead === '' || REGEX_AFTER.test(ahead) ? regexEnd(text, i) : -1
      if (e > 0) {
        copy(i + 1)
        empty(e)
        i = e
      } else i++
    } else i++
  }
  copy(text.length)
  return parts.join('')
}

/**
 * What a file's code reaches beyond itself, by what it imports or calls, or undefined when it reaches
 * nothing: a program it starts, a web request it makes, or a module it loads by a name given at run
 * time. `whole` reads the text as it stands, strings and comments included, for code another program
 * holds as text (a shell script's `python3 -c '...'` or `node -e "..."`), whose quotes are that
 * program's.
 */
export const fileReach = (lang: FileLang, text: string, how: { whole?: boolean } = {}): Reach | undefined => {
  const rules = lang === 'python' ? PY_RULES : NODE_RULES
  // Emptying text only takes matches away, so text no rule matches as it stands is read no further:
  // the Slack drafts gate, 185 KB, read by the guard in 2.5 ms (load 23 on 12 cores), against 2.1 ms
  // with the guard's own lists (load 15) and 5.6 ms when every such file was emptied first (load 25),
  // medians of 18 reads each on 2026-11-10.
  if (!how.whole && !rules.some(r => r.re.test(text))) return undefined
  const code = how.whole ? text : lang === 'python' ? pythonCode(text) : nodeCode(text)
  for (const r of rules) {
    const m = r.re.exec(code)
    if (m) return r.reach(m)
  }
  return undefined
}
