// The Slack alert guard's rules (claude-config#2242), pure: what counts as a file that posts to
// Slack, what in it is message text a person reads, and what an edit changes of that text. Dan,
// 2026-11-04: "anytime a slack alert is created, we need to have a design-rounds esque check on
// wording so I can approve the wording before it's created".
//
// Decisions given with the issue:
// 1. What counts: an edit whose changed text carries message text, in a file that posts to Slack,
//    recognised by a Slack posting marker in the file (slackMarked). A template with no marker in
//    its own file counts too when another file in its repository sends it (#2248): that file
//    carries a Slack marker and names the template's path (refersTo).
// 2. Approval is for exact wording (L64): any change to approved text is held again, and a change
//    to an alert file that touches no message text passes unasked.
// 3. Approval is keyed to the wording, never the file (wordingKey), so the same wording approved in
//    one file goes through in another.
//
// Narrowed to text a Slack send builds (#2361, #2364, #2290, #2287; Dan, 2026-11-06, reversing the
// earlier "no file is exempted" in decision 3): a test file (testFile) and a doc send nothing, and
// neither is a template nor a sender; a string handed to a query builder call, a select list, or a
// code template is not message text (stringsOf, isMessage); a file in no git repository, as a
// scratchpad script is, has nothing that sends it. A module whose user also imports a Slack send
// helper (a copy or notice builder) is held, which a marker or reference search alone misses. A
// file a sender only names, never imports or reads, is not its template (refersTo, Dan's item 1).
//
// Narrowed to text a Slack send carries (#2570; Dan, 2026-11-09: "these aren't alerts that are going
// to fire into Slack, right? If not, I don't need you to ask me for approval"): in a JavaScript,
// TypeScript or python file, a changed string is held only when sends.ts traces it to a send call's
// arguments, in its own file or from a file that sends it. A file whose send cannot be traced (any
// other language, a text template, a send the reading cannot find, a module used whole) is held as
// before. A python docstring is never message text (#2574).
//
// Narrowed to code that posts (#2662; Dan, 2026-11-10: "Recognise refusal code"). A gate that
// refuses Slack posts has to name what it refuses, and was read as a file that posts: on 2026-11-09
// what the Slack drafts gate prints on stderr, and edits to a script its docstrings name, were held
// as Slack wording. A marker is now told apart by how it is written (matchedAt). A name (an
// endpoint, an SDK, a setting) written as one alternative of a pattern, or as the middle of a glob,
// is only being matched; written any other way (in an address, after a dot or a $, as a whole
// string, as a bare word) it is used, as before. A file is no sender only when every marker it
// carries is matched that way, or sits in a comment, AND the file makes no request and starts no
// program that could (makesRequest), so a file that matches an endpoint and then calls it is still
// one. Only shell, python, JavaScript and TypeScript are read for this: in any other language a
// marker anywhere is a sender, as before. No file is named or exempted. Not recognised, so still
// held: a sentence that spells an endpoint out, a list of bare names, a pattern in a regex literal.

export const GUARD = 'Slack alert guard'
export const SOURCE = 'slack-alert-guard'
export const HEADER = 'Slack alert'
export const APPROVE = 'Approve wording'
export const CHANGE = 'Change wording'
/**
 * How long the search for a file that sends a template may take, every git call and read in it.
 * Claude Code kills a hook that runs past HookBudget.ms, 10 s (tools/typescript/claude-code-types/
 * claude-code/index.d.ts), so 7 s leaves 3 s to build and return the refusal. The 3 s this replaced
 * ran out on a work repository's 185 reads even at load 6.4 (#2510).
 */
export const SCAN_MS = 7000
/**
 * The most files the search reads for one template before it holds the call for Dan, naming no
 * sender since it could not tell which file sends it (#2364). Sized from the largest real searches
 * (#2510): NurseDex, the largest repository on the personal MacBook the search walks (1,061
 * JavaScript, TypeScript and python files), reads 213 files for its widely imported utils.ts, in
 * 1.65 to 1.70 s at load 27, about 8 ms a file; a work repository's two copy files read 185. 500
 * leaves more than twice the largest, and at 8 ms a file still ends well inside SCAN_MS.
 */
export const MOST_READ = 500
/** How many files that import and re-export a template the search follows before it holds as could not check (#2286). */
export const REEXPORT_HOPS = 3
/**
 * The most bytes of file names one git grep is handed: the files whose lines are listed go to git
 * by name, in groups no larger than this, well inside macOS's 1 MB limit on a command line and its
 * environment together.
 */
export const PATHSPEC_BYTES = 200_000

// Files that can post: code and the config that carries a message. Prose files post nothing.
const CODE = new Set(['ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs', 'py', 'rb', 'go', 'sh', 'bash', 'zsh', 'swift', 'kt', 'java', 'php', 'cs', 'rs', 'json', 'yml', 'yaml'])
const extOf = (path: string): string | undefined => {
  const name = path.slice(path.lastIndexOf('/') + 1)
  const dot = name.lastIndexOf('.')
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : undefined
}

/** Whether a file is one this guard reads: a code or config extension, or a script with a shebang and no extension. */
export const inScope = (path: string, text: string): boolean => {
  const ext = extOf(path)
  return ext === undefined ? text.startsWith('#!') : CODE.has(ext)
}

// Prose files are read by people, never run, so they post nothing. Only these are ruled out as
// senders: a file in a language CODE does not list (a .vue, a .sql posting through pg_net, a .toml)
// may still send, so it is read as a sender is.
const PROSE = new Set(['md', 'markdown', 'mdx', 'rst', 'adoc', 'txt'])
/** Whether a file is prose (a README, a CLAUDE.md, a runbook), which can name a template but never send it. */
export const isProseFile = (path: string): boolean => PROSE.has(extOf(path) ?? '')

/**
 * A file's text with its comments blanked and its strings kept, as its language writes comments, so
 * a sender is judged by what it runs (Pivot, 2026-11-06: a workflow comment naming a test file made
 * that test a Slack template; #2361: a runbook named in a code comment). One reader for both: the
 * Slack marker and handsOn read this, and refersTo reads it for a reference. A `#` or `//` inside a
 * string is kept, and code after a closed block comment is still read.
 */
export const codeOf = (path: string, text: string): string => withoutComments(text, languageOf(path, text) !== 'c')

// Each marker is written so this file's own source does not match it: a dot or underscore escaped
// or in a class, so the guard's rules are not themselves read as a Slack poster.
//
// The markers that are a name: a webhook's host, the chat API's method, a Slack SDK, a Slack setting.
// A name can be written only to be matched (matchedAt).
const NAMES: RegExp[] = [/hooks\.slack\.com/, /chat[._]postMessage/, /@slack\//, /slack[_]sdk/, /slack-go\//, /SLACK[_]\w*(WEBHOOK|TOKEN|CHANNEL)/i]
// The markers that are a send helper named for Slack, called or imported, which is always a use.
const HELPERS: RegExp[] = [
  /\b(send|post|notify|alert)\w*slack\w*\s*\(/i,
  // The same helper imported without being called, as a test asserting its wording does. Only an
  // import or require line counts, so the name in a comment or a config key is not a post.
  /^\s*(import|from)\b[^\n]*\b(send|post|notify|alert)\w*slack/im,
  /\b(send|post|notify|alert)\w*slack\w*\b[^\n]*\brequire\s*\(/i,
  /\bslack\w*\.(send|post|notify|chat)\w*\s*\(/i,
  /\bslack\w*(send|post|notify|message|alert)\w*\s*\(/i,
]
export const MARKERS: RegExp[] = [...NAMES, ...HELPERS]

/** Whether a text carries a Slack marker: a webhook, the chat API, a Slack SDK, a Slack env setting, or a send helper named for Slack. */
export const slackMarked = (text: string): boolean => MARKERS.some(m => m.test(text))

// Each marker as it is searched for every place it stands, the names first as MARKERS has them.
const EVERY = MARKERS.map(m => new RegExp(m.source, `${m.flags}g`))

// A bar that separates a pattern's alternatives: one bar, never the two of an "or" in code.
const barAt = (code: string, i: number, out: 1 | -1): boolean => code[i] === '|' && code[i + out] !== '|'
/**
 * Whether the name at [at, to) of a file's code is only being matched (#2662), by how it is written:
 * the middle of a glob, a star at each side (`*name*`), or one alternative of a pattern, a bar at
 * one side and at the other a bar, the group's bracket, an anchor or the string's quote
 * (`'other|name'`). The name is taken to the end of its word first, so a longer name it starts is
 * judged whole. Anything else is a use: an address (a slash beside it), a setting read (a `$`, a
 * dot or a brace before it), a method called, a whole quoted string, a bare word. This file's own
 * source spells no marker out, here included, so the guard never reads itself as a sender.
 */
const matchedAt = (code: string, at: number, to: number): boolean => {
  while (at > 0 && /\w/.test(code[at - 1] as string)) at--
  while (to < code.length && /\w/.test(code[to] as string)) to++
  const [l, r] = [code[at - 1] ?? '', code[to] ?? '']
  if (l === '*' && r === '*') return true
  const [lBar, rBar] = [barAt(code, at - 1, -1), barAt(code, to, 1)]
  return (lBar && (rBar || /[)$'"`]/.test(r))) || (rBar && /[(^'"`]/.test(l))
}

/** The languages a file is read in for whether it makes a request (#2662). */
export type RequestLanguage = 'shell' | 'python' | 'js'
/** Which of them a file is written in, by its extension, or its shebang when it has none; none for any other language. */
export const requestLanguage = (path: string, text: string): RequestLanguage | undefined => {
  const ext = extOf(path)
  const end = text.indexOf('\n')
  const shebang = ext === undefined && text.startsWith('#!') ? text.slice(0, end < 0 ? text.length : end) : ''
  if (ext === 'py' || /python/.test(shebang)) return 'python'
  if (ext === 'sh' || ext === 'bash' || ext === 'zsh' || /\b(ba|z|da|k)?sh\b/.test(shebang)) return 'shell'
  if (ext === undefined ? /\b(node|deno|bun)\b/.test(shebang) : JS.has(ext)) return 'js'
  return undefined
}

import { fileReach } from './mod-kit/reaches.ts'

// What makes a request, or starts a program that could, in each language (#2662). Each is wide on
// purpose: a sentence that reads like one of these keeps its file a sender, which only holds an edit
// that was held before. Python and JavaScript reach the network or another program only through a
// module they import or a call they make, which mod-kit's file reader judges (fileReach, #2710: the
// one judge of what code can do lives in mod-kit, #712), so a program's name in their strings, a
// pattern or a comment is data (a gate's list of the programs it refuses) and never counts. A shell
// script's words are what it runs, and its inline python or node sits in its quotes, so that is
// read whole.
// A program that makes a request, followed by what it is handed; HTTPie's http and https; bash's own
// /dev/tcp; and, where a command starts, any program named for Slack (a helper a script calls with
// no brackets, which no marker sees).
const SHELL_REQUEST =
  /(^|[^\w.-])(curl|wget|xh|httpie|curlie|nc|ncat|netcat|socat|telnet|ssh|scp|sftp|ftp|rsync|sendmail|mailx?|openssl)[ \t]+\S|(^|[\s;&|(])https?[ \t]+[-:\w"'$]|\/dev\/(tcp|udp)\/|(^|[;&|(){]|\b(then|do|else|if|while|until|exec|eval|command|xargs|sudo|nohup|time)[ \t])[ \t]*[\w.\/~$-]*slack[\w.\/-]*([ \t]+\S|[ \t]*$)/im

/** Whether a file's code makes a request, or starts a program that could. Inline python or JavaScript in a shell script is the script's own text, so it is read there too. */
const makesRequest = (lang: RequestLanguage, code: string): boolean =>
  lang === 'python'
    ? fileReach('python', code) !== undefined
    : lang === 'js'
      ? fileReach('node', code) !== undefined
      : SHELL_REQUEST.test(code) || fileReach('python', code, { whole: true }) !== undefined || fileReach('node', code, { whole: true }) !== undefined

// Whether a file's code only names what it matches: every marker in it a name being matched, and
// nothing in it making a request. Never so in a language not read for requests. The names are read
// first and the reading stops at the first one that is used, so a file that posts, which is nearly
// every file carrying a marker, costs what finding its marker did before. Only a file read to the
// end as matching pays more (2026-11-10, load 22: the 179 KB drafts gate 0.9 ms before, 2.8 to
// 3.1 ms now; 500 of those would be 1.6 s of SCAN_MS).
const onlyMatches = (lang: RequestLanguage | undefined, code: string): boolean => {
  if (lang === undefined) return false
  for (const m of EVERY.slice(0, NAMES.length)) for (const x of code.matchAll(m)) if (!matchedAt(code, x.index ?? 0, (x.index ?? 0) + x[0].length)) return false
  return !HELPERS.some(m => m.test(code)) && !makesRequest(lang, code)
}

/**
 * Where a file's code names a Slack send (#2662): every marker in it, or none when the file only
 * names what it matches, as a gate naming the endpoints it refuses does. `lang` is none for a
 * language not read for requests, where every marker counts as before.
 */
export const sendMarks = (lang: RequestLanguage | undefined, code: string): number[] =>
  onlyMatches(lang, code) ? [] : EVERY.flatMap(m => [...code.matchAll(m)].map(x => x.index ?? 0))

/**
 * Whether a file posts to Slack: its code (comments left out) carries a marker, and the file does
 * more than name what it matches (sendMarks). `inComments` for the file being edited or written to,
 * which a marker in a comment has always made a sender: it still does, unless the file only names
 * what it matches, a comment naming an endpoint being no more a send than a pattern matching it.
 */
export const isSender = (path: string, text: string, inComments = false): boolean => {
  const code = codeOf(path, text)
  return slackMarked(inComments ? text : code) && !onlyMatches(requestLanguage(path, text), code)
}

/**
 * What the repository is searched for before any file is read, case ignored: every marker names
 * slack or postMessage, so no file slackMarked would match is left out (a test holds every marker
 * to it). The marker itself is still decided by slackMarked alone.
 */
export const SENDER_PREFILTER = 'slack|postmessage'

/**
 * The files that could carry a Slack marker, as git grep -E -i lists them: each marker's run of
 * characters that holds no space or line break, so a file the marker matches in its code always
 * holds one (a comment is blanked to a single space, which none of these runs can hold). A file that
 * only mentions Slack (a design page, a settings label) holds none, so it is never listed as one
 * that might send, and its lines are never listed either: a work repository's design pages, which mention Slack
 * on lines of up to 730 KB, made one listing 9.9 MB after #2481. Written as POSIX ERE, with no \b
 * or \w, which macOS git grep -E does not read, and with a sign in brackets where the markers have
 * one, so this file is not itself read as a Slack poster; a test holds every marker to it.
 */
export const MARKER_PREFILTER = [
  'hooks\\.slack\\.com',
  'chat[._]postmessage',
  '@slack[/]',
  'slack[_]sdk',
  'slack-go[/]',
  'slack_[a-z0-9_]*(webhook|token|channel)',
  '(send|post|notify|alert)[a-z0-9_]*slack',
  'slack[a-z0-9_]*\\.(send|post|notify|chat)',
  'slack[a-z0-9_]*(send|post|notify|message|alert)',
].join('|')

/**
 * Whether a path, relative to its repository's root, is a test: a .test. or .spec. file, a _test or
 * _spec one, a python test_ module, a test- shell suite or node test script (test-*.ts and its
 * JavaScript and TSX forms, #2509, as a work repository runs its tests), or anything in a test or
 * mock folder. A test never posts to Slack, so its titles and fixtures are never message text
 * (#2290), and it is never a sender.
 */
export const testFile = (rel: string): boolean => {
  const segs = rel.split('/')
  const name = segs[segs.length - 1] ?? ''
  if (/\.(test|spec)\.[^/]+$/.test(name) || /_(test|spec)\.[^/.]+$/.test(name) || /^test_[^/]*\.py$/.test(name) || /^test-[^/]*\.(sh|bash|zsh|[cm]?[jt]sx?)$/.test(name)) return true
  return segs.slice(0, -1).some(s => TEST_DIRS.has(s))
}
const TEST_DIRS = new Set(['__tests__', '__mocks__', '__fixtures__', 'test', 'tests', 'spec', 'specs', 'e2e'])

// Prose files a script reads and sends as they are, each line its own message text (#2248). Docs
// (markdown) are not among them: a runbook is read by people, never posted (#2361).
const TEXT_TEMPLATE = new Set(['txt', 'hbs', 'handlebars', 'mustache', 'j2', 'jinja', 'jinja2', 'tmpl', 'tpl', 'liquid', 'ejs', 'erb'])
/** Whether a file is a text template: wording a script reads and sends, with no code around it. */
export const textTemplate = (path: string): boolean => {
  const ext = extOf(path)
  return ext !== undefined && TEXT_TEMPLATE.has(ext)
}
/** A text template's lines, each trimmed, the blank ones dropped. */
export const templateLines = (text: string): string[] => text.split('\n').map(l => l.trim()).filter(Boolean)

const stemOf = (name: string): string => {
  const dot = name.lastIndexOf('.')
  return dot > 0 ? name.slice(0, dot) : name
}
// A package's own file, which a sender names by its folder.
const PACKAGE = new Set(['index', '__init__'])

/** The word a sender has to write to name a template: its file name without the extension, or its folder's name for an index or __init__. */
export const searchTerm = (rel: string): string => {
  const segs = rel.split('/')
  const stem = stemOf(segs[segs.length - 1] ?? '')
  return PACKAGE.has(stem) && segs.length > 1 ? (segs[segs.length - 2] ?? stem) : stem
}
/** A word escaped for an extended regular expression, as git grep -E reads one. */
export const escapeRe = (s: string): string => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

// The extensions one JavaScript or TypeScript import may name the same file by.
const JS = new Set(['ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs', 'mts', 'cts'])
/** Whether a file is JavaScript or TypeScript, whose single and double quotes fill nothing in. */
export const isJs = (path: string): boolean => {
  const e = extOf(path)
  return e !== undefined && JS.has(e)
}
// One path segment naming another: equal, or without its extension, or by a sibling JS one.
const sameName = (s: string, t: string): boolean => {
  if (s === t) return true
  const se = extOf(s)
  if (se === undefined) return s === stemOf(t)
  const te = extOf(t)
  return te !== undefined && JS.has(se) && JS.has(te) && stemOf(s) === stemOf(t)
}
// How many segments two paths share counted from the end, the last compared by sameName.
const sharedTail = (s: string[], t: string[], eq: (a: string, b: string) => boolean): number => {
  let n = 0
  while (n < s.length && n < t.length) {
    const a = s[s.length - 1 - n] as string
    const b = t[t.length - 1 - n] as string
    if (!(n === 0 ? eq(a, b) : a === b)) break
    n++
  }
  return n
}
const resolve = (base: string[], segs: string[]): string[] | undefined => {
  const out = [...base]
  for (const s of segs) {
    if (s === '.' || s === '') continue
    if (s === '..') {
      if (!out.length) return undefined
      out.pop()
    } else out.push(s)
  }
  return out
}
// The modules a python style import line names: `from X import a, b` names X, X.a and X.b;
// `import X.Y as z` names X.Y. A line holding a quote or a brace is another language's import.
const importedModules = (text: string): string[] => {
  const out: string[] = []
  const word = (s: string) => (s.trim().split(/\s+/)[0] ?? '').replace(/[^\w.]/g, '')
  for (const line of text.split('\n')) {
    if (/["'`{}]/.test(line)) continue
    const from = /^\s*from\s+([\w.]+)\s+import\s+(.+)$/.exec(line)
    if (from) {
      const x = from[1] as string
      out.push(x)
      for (const n of (from[2] as string).replace(/[()\\]/g, ' ').split(',').map(word))
        if (n && n !== '*') out.push(x.endsWith('.') ? `${x}${n}` : `${x}.${n}`)
      continue
    }
    const imp = /^\s*import\s+(.+)$/.exec(line)
    if (imp) for (const n of (imp[1] as string).split(',').map(word)) if (n) out.push(n)
  }
  return out
}

// A line that imports a file or reads its text: an import, require, from or export line, an include
// or load, a call that opens, reads or renders a file, cat, a shell source line, or $(< file); or one
// that builds a path to read later (path.join, resolve, Path, __dirname), as `const T = path.join(...)`
// before `readFileSync(T)` does; or curl's data or form argument taking a file's text by `@`, as a
// workflow's `curl ... --data-binary @alerts/late.txt` posts it (#2368). Matched on lower cased text,
// so every alternative is written lower case: `Path(` and `URL(` are read as path( and url( (#2416).
const READS =
  /\b(import|require|from|export|cat|source)\b|\b(include|load\w*|open|read\w*|render\w*|\w*template\w*|send_?file|join|resolve|path|url)\s*\(|__dirname|__file__|import\.meta|\$\(\s*<|^\s*\.\s+\S|(^|\s)(-d|--data(-[a-z]+)?)(\s+|=)['"]?@|(^|\s)(-f|--form)\s+['"]?[\w-]+=@/

/**
 * Whether a sender's text imports or reads a template, both given relative to the repository root.
 * Only the lines of its code (comments left out) that import or read a file (READS) are searched, so
 * a path the sender only names, as `git add` or a list of tracked files does, never counts. In
 * those lines, read as a path (a token holding a slash, or a file name with the template's
 * extension): a relative one resolved from the sender's folder or the root must be the template itself; any other
 * shares at least its last two segments, or is the bare file name with its extension. Read as a
 * module (a dotted name, or what a python import line names): its last two names match, or the
 * whole of an imported one does. A bare word that only shares the template's name never counts.
 */
export const refersTo = (senderRel: string, text: string, templateRel: string): boolean => {
  const t = templateRel.toLowerCase().split('/')
  const last = t[t.length - 1] ?? ''
  const tExt = extOf(last)
  const pkg = PACKAGE.has(stemOf(last)) && t.length > 1
  const paths = pkg ? [t, t.slice(0, -1)] : [t]
  const mod = [...t.slice(0, -1), stemOf(last)]
  const mods = pkg ? [mod, t.slice(0, -1)] : [mod]
  const senderDir = senderRel.toLowerCase().split('/').slice(0, -1)
  // A path named only in a comment is a note to a reader, never a file the sender reads (#2361).
  const lower = codeOf(senderRel, text).toLowerCase()
  const byModule = (name: string, whole: boolean): boolean => {
    const m = name.split('.').filter(Boolean)
    return m.length > 0 && mods.some(f => {
      const n = sharedTail(m, f, (a, b) => a === b)
      return n >= 2 || (whole && n === m.length)
    })
  }
  // Only a line that imports or reads a file can bring its text to a send; a path a sender only
  // names (git add package.json, a list of tracked files) brings nothing (Dan's item 1, #2371).
  const reading = lower
    .split('\n')
    .filter(l => READS.test(l))
    .join('\n')
  for (const raw of reading.match(/[\w@~$.\/-]+/g) ?? []) {
    const tok = raw.replace(/\.+$/, '')
    const ext = tok.includes('/') ? undefined : extOf(tok)
    const named = ext !== undefined && tExt !== undefined && (ext === tExt || (JS.has(ext) && JS.has(tExt)))
    if (tok.includes('/') || named) {
      const segs = tok.split('/')
      if (segs[0] === '.' || segs[0] === '..') {
        for (const base of [senderDir, []]) {
          const r = resolve(base, segs)
          if (r && paths.some(f => r.length === f.length && sharedTail(r, f, sameName) === r.length)) return true
        }
        continue
      }
      const s = segs.filter(x => x !== '' && x !== '.' && x !== '~' && !x.startsWith('@') && !x.startsWith('$'))
      if (s.length && paths.some(f => {
        const n = sharedTail(s, f, sameName)
        return n >= 2 || (s.length === 1 && n === 1 && extOf(s[0] as string) !== undefined)
      }))
        return true
    } else if (tok.includes('.') && byModule(tok, false)) return true
  }
  return importedModules(lower).some(m => byModule(m, true))
}

/**
 * Whether a file can hand what it imports on to another file (#2286): a JavaScript or TypeScript
 * file with an export, or any python module, since python exposes every name a module imports.
 * Other languages are not followed.
 */
export const handsOn = (rel: string, text: string): boolean => {
  const ext = extOf(rel)
  if (ext === 'py') return true
  if (ext === undefined || !JS.has(ext)) return false
  return /(^|\n)[ \t]*export[\s{*]/.test(text) || /(^|[^.\w$])(module\.exports|exports\.[\w$]+\s*=)/.test(text)
}

// The paths of a JavaScript or TypeScript file's local imports, as written: a relative or aliased
// path, never a bare package.
const localSpecs = (text: string): string[] =>
  [...withoutComments(text, false).matchAll(/(?:\bfrom\s*|\brequire\s*\(\s*|\bimport\s*\(\s*|\bimport\s+)["'`]([^"'`\n]+)["'`]/g)]
    .map(m => m[1] as string)
    .filter(spec => spec.startsWith('.') || spec.includes('/'))

/**
 * Every module a file imports, as the file names it (#2637): each local JavaScript or TypeScript
 * import path whole, and each python module. Two files of one name in different folders are two
 * modules here, where importTerms gives one word for both.
 */
export const moduleSpecs = (text: string): string[] => [...new Set([...localSpecs(text), ...importedModules(withoutComments(text, true))])]

/**
 * The words a search for the modules a file imports looks for (#2361): the last name of each local
 * JavaScript or TypeScript import (a relative or aliased path, never a bare package), its folder's for
 * an index, and the last name of each python import.
 */
export const importTerms = (text: string): string[] => {
  const out = new Set<string>()
  for (const spec of localSpecs(text)) {
    const segs = spec.split('/').filter(s => s && s !== '.' && s !== '..')
    const stem = stemOf(segs[segs.length - 1] ?? '')
    const term = PACKAGE.has(stem) ? (segs[segs.length - 2] ?? '') : stem
    if (term.length > 1) out.add(term)
  }
  for (const mod of importedModules(withoutComments(text, true))) {
    const last = mod.split('.').filter(Boolean).pop() ?? ''
    if (last.length > 1) out.add(last)
  }
  return [...out]
}

/**
 * Whether a file is a UI component (#2519): a React file (.tsx, .jsx) in a components, screens or
 * views folder, never a test. Dan, 2026-11-09: a file imported only by UI components is not on a
 * path that posts to Slack, so the search for its sender settles there rather than following the
 * components on. A React file elsewhere (an email, a Slack message built in JSX) is not one, and a
 * component that itself sends is still found by the sender check. Swift view files need no rule,
 * as the search never follows a Swift file (mayHandOn).
 */
const UI_DIRS = new Set(['components', 'screens', 'views'])
export const uiComponent = (rel: string): boolean => {
  const e = extOf(rel)
  if ((e !== 'tsx' && e !== 'jsx') || testFile(rel)) return false
  return rel.split('/').slice(0, -1).some(s => UI_DIRS.has(s.toLowerCase()))
}

/** Whether a template may be handed on through this file: a JavaScript, TypeScript or python one. */
const LINK_EXTS = new Set([...JS, 'py'])
export const mayHandOn = (rel: string): boolean => {
  const e = extOf(rel)
  return e !== undefined && LINK_EXTS.has(e)
}

// A character that cannot be part of a name, and one that also cannot open a quote or a brace, which
// a python import line never holds (importedModules). Written without \b, which macOS git grep -E
// reads as matching nothing.
const EDGE = '[^A-Za-z0-9_]'
const NAME_END = `(${EDGE}|$)`
const BARE = '[^"\'`{}]'
const BARE_EDGE = '[^A-Za-z0-9_"\'`{}]'

/**
 * How the files that may name any of `rels` are listed (#2371, #2462): `words`, the names alone,
 * which git grep is given as fixed strings, case ignored, and `shape`, a regular expression tested
 * here, case ignored, on each line git lists: the name in a form refersTo can accept. That is after a
 * slash (a path), as a file name with its extension, after its folder's name and a dot (a dotted
 * module), or on a python import line; a package's index or __init__ is named by its folder, as a
 * whole word. A word the name is only a piece of (et in settings, memory in "kept in memory") is
 * never listed, so a common short name no longer lists a crowd of files to read. Every form
 * refersTo accepts holds one of these, so nothing it would find is left out. The shape is never
 * handed to git: for the importers of a widely imported module it runs to tens of kilobytes, which
 * git tested on every line, 5.5 to 7.7 seconds for 150 names over 1,430 files, where the names as
 * fixed strings took 55 ms and the shape tested here on the lines they listed 14 ms (#2462).
 */
export const namePatterns = (rels: string[]): { words: string[]; shape: string } => {
  const words = new Set<string>()
  const shapes = new Set<string>()
  for (const r of rels) {
    const segs = r.split('/')
    const term = searchTerm(r)
    const t = escapeRe(term)
    words.add(term)
    if (PACKAGE.has(stemOf(segs[segs.length - 1] ?? '')) && segs.length > 1) {
      shapes.add(`(^|${EDGE})${t}${NAME_END}`)
      continue
    }
    shapes.add(`/${t}${NAME_END}`)
    const ext = extOf(r)
    if (ext !== undefined) shapes.add(`(^|${EDGE})${t}\\.(${(JS.has(ext) ? [...JS] : [ext]).map(escapeRe).join('|')})${NAME_END}`)
    const dir = segs[segs.length - 2]
    if (dir) shapes.add(`${escapeRe(dir)}\\.${t}${NAME_END}`)
    shapes.add(`^[ \t]*(from|import)([ \t]|[ \t]${BARE}*${BARE_EDGE})${t}(${BARE_EDGE}[^"'\`{}#]*)?(#.*)?$`)
  }
  return { words: [...words], shape: [...shapes].join('|') }
}

// A name written as a git glob matches it as written, its glob signs escaped.
const globName = (s: string): string => s.replace(/[*?[\]\\]/g, '\\$&')

/**
 * The git pathspecs for every file a module's local imports can be (#2371): each imported name as a
 * file of any extension, a folder's index, or a python package, in any folder, case ignored. A send
 * helper is found by its path, as the import names it, never by what its text happens to hold.
 */
export const importSpecs = (text: string): string[] =>
  importTerms(text).flatMap(t => {
    const g = globName(t)
    return [`:(glob,icase)**/${g}.*`, `:(glob,icase)**/${g}/index.*`, `:(glob,icase)**/${g}/__init__.py`]
  })

/** How a file's strings are read: python through mod-kit's reader, YAML with its plain values, a hash comment language, or a C-like one. */
export const languageOf = (path: string, text: string): 'python' | 'yaml' | 'hash' | 'c' => {
  const ext = extOf(path)
  const shebang = text.startsWith('#!') ? (text.split('\n')[0] ?? '') : ''
  if (ext === 'py' || (ext === undefined && /python/.test(shebang))) return 'python'
  if (ext === 'yml' || ext === 'yaml') return 'yaml'
  if (ext === undefined || ext === 'sh' || ext === 'bash' || ext === 'zsh' || ext === 'rb') return 'hash'
  return 'c'
}

const unescape = (s: string): string => s.replace(/\\([\s\S])/g, (_m, c: string) => (c === 'n' ? '\n' : c === 't' ? '\t' : c))

/**
 * Every string literal in a file's text, comments passed over: double, single and backtick quoted,
 * escapes read. `hash` for a language whose comments open with a hash, else // and block comments.
 */
export const literalsOf = (text: string, hash: boolean): string[] => stringsOf(text, hash).map(s => s.text)

// A JavaScript template's ${...}, read to its own closing brace past a template, a quoted string or
// a brace pair inside it, so a nested template literal is one string (#2371, Dan's item 5). One that
// never closes is read as plain text, as before.
const SUBST = /\$\{(?:[^{}`'"]|`(?:\\[\s\S]|[^`\\])*`|'(?:\\.|[^'\\\n])*'|"(?:\\.|[^"\\\n])*"|\{[^{}]*\})*\}/.source

// A file's comments and strings, as literalsOf reads them: a hash comment language, or a C-like one.
const HASH_TOKENS = /#[^\n]*|"((?:\\[\s\S]|[^"\\])*)"|'((?:\\[\s\S]|[^'\\\n])*)'|`((?:\\[\s\S]|[^`\\])*)`/.source
const C_TOKENS = `${/\/\/[^\n]*|\/\*[\s\S]*?\*\/|"((?:\\[\s\S]|[^"\\\n])*)"|'((?:\\[\s\S]|[^'\\\n])*)'/.source}|\`((?:\\\\[\\s\\S]|${SUBST}|[^\`\\\\])*)\``

// The query builder calls whose arguments are a database's words, never a person's (#2364). Names an
// ordinary array, string or promise method shares (filter, join, from, match, not) are left out, so an
// alert inside such a call is still read; a SQL string handed to query or execute is caught by sqlText.
const QUERY_CALLS =
  'select|order|eq|neq|gt|gte|lt|lte|like|ilike|contains|containedBy|overlaps|textSearch|rpc|schema|onConflict|returning|where|orWhere|andWhere|whereIn|whereRaw|orderBy|groupBy|having|leftJoin|innerJoin|raw'
const CALL_TOKENS = `(\\.\\s*(?:${QUERY_CALLS})\\s*\\()|(\\()|(\\))`

/** One string literal: its text with escapes read, where its text starts, and how it is used. */
export type Str = {
  text: string
  start: number
  /** Whether it is a direct argument of a query builder call (never one of a call nested inside it), or a sql tagged template. */
  query: boolean
  /** The ${...} placeholders it holds as written text rather than filled at run time (JavaScript only). */
  literal: string[]
}

/**
 * Every string literal in a file's text, comments passed over, as literalsOf reads them, each with
 * whether it is a query builder's argument (#2364) and, in JavaScript (`js`), which ${...} it writes
 * as text: all of them in single or double quotes, and an escaped \${...} in a template.
 */
export const stringsOf = (text: string, hash: boolean, js = false): Str[] => {
  const tokens = new RegExp(`${hash ? HASH_TOKENS : C_TOKENS}|${CALL_TOKENS}`, 'g')
  const calls: boolean[] = []
  const out: Str[] = []
  for (const m of text.matchAll(tokens)) {
    if (m[4] !== undefined) calls.push(true)
    else if (m[5] !== undefined) calls.push(false)
    else if (m[6] !== undefined) calls.pop()
    const body = m[1] ?? m[2] ?? m[3]
    if (body === undefined) continue
    const at = m.index ?? 0
    const tagged = m[3] !== undefined && /(^|[^\w$])sql\s*$/i.test(text.slice(Math.max(0, at - 12), at))
    const literal = !js ? [] : m[3] === undefined ? [...body.matchAll(/\$\{[^}]*\}/g)].map(x => x[0]) : [...body.matchAll(/\\(\$\{[^}]*\})/g)].map(x => x[1] as string)
    const query = tagged || calls[calls.length - 1] === true
    out.push({ text: unescape(body), start: at + 1, query, literal })
    // The strings inside a C-like template's ${...} are wording of their own, as a nested template
    // literal's is (#2371): each is read where it stands, and is a query when its template is.
    if (m[3] !== undefined && !hash)
      for (const s of body.matchAll(new RegExp(`(?<!\\\\)${SUBST}`, 'g'))) {
        const from = at + 1 + (s.index ?? 0) + 2
        for (const inner of stringsOf(s[0].slice(2, -1), false, js)) out.push({ ...inner, start: from + inner.start, query: query || inner.query })
      }
  }
  return out
}

/** A file's text with its comments blanked, its strings kept. */
export const withoutComments = (text: string, hash: boolean): string =>
  text.replace(new RegExp(hash ? HASH_TOKENS : C_TOKENS, 'g'), t => (t.startsWith('#') || t.startsWith('//') || t.startsWith('/*') ? ' ' : t))

/**
 * A YAML file's plain (unquoted) values, each line's text after its key or list mark; quoted ones are
 * read by literalsOf. A script block (`script: |`, as github-script takes) is JavaScript, whose words
 * are code and whose wording is only ever quoted, so its lines are never plain values (#2371).
 */
export const plainYamlValues = (text: string): string[] => {
  const out: string[] = []
  let script = -1
  for (const line of text.split('\n')) {
    const indent = /^\s*/.exec(line)![0].length
    if (script >= 0 && (!line.trim() || indent > script)) continue
    script = -1
    const opens = /^(\s*)(-\s+)?script:\s*[|>][-+]?\d*\s*$/.exec(line)
    if (opens) {
      script = (opens[1] as string).length + (opens[2] ?? '').length
      continue
    }
    const m = /^\s*(?:-\s+)?(?:[\w.-]+:\s+)?(.*)$/.exec(line)
    const v = (m?.[1] ?? '').replace(/\s+#.*$/, '').trim()
    if (!v || v.startsWith('#') || /^["'|>&*!]/.test(v) || /^[\w.-]+:$/.test(v)) continue
    out.push(v)
  }
  return out
}

// A value filled in at run time, in any common spelling: ${x}, #{x}, \(x), {x}, %s, $X.
const FILLED = /\$\{[^}]*\}|#\{[^}]*\}|\\\([^)]*\)|\{[^{}]*\}|%[sd]|\$[A-Za-z_]\w*/g
const WORD = /^[A-Za-z]{2,}[a-z']*[.,:;!?)]*$/
const FILLED_MARK = '\u0000'
/** A string with each value filled in at run time made a mark, a ${...} read to its own closing brace however much code is inside it (#2371). */
const markFilled = (s: string): string => s.replace(new RegExp(SUBST, 'g'), ` ${FILLED_MARK} `).replace(FILLED, ` ${FILLED_MARK} `)
/** The fixed parts of a string: the words between the values filled in at run time, never the code that fills them. */
export const fixedParts = (s: string): string[] => markFilled(s).split(FILLED_MARK)

/** Whether a string reads as text a person reads: two words, or a word beside a filled in value; never a key, a path, a URL or a class list. */
export const isProse = (s: string): boolean => {
  const words = markFilled(s).split(/\s+/).filter(Boolean)
  return words.length >= 2 && words.some(w => WORD.test(w))
}

// A string split at its commas outside any parentheses.
const topLevelItems = (s: string): string[] => {
  const out: string[] = []
  let depth = 0
  let cur = ''
  for (const c of s) {
    if (c === '(') depth++
    else if (c === ')') depth = Math.max(0, depth - 1)
    if (c === ',' && depth === 0) {
      out.push(cur.trim())
      cur = ''
    } else cur += c
  }
  out.push(cur.trim())
  return out
}
const SELECT_ITEM = /^(\w+:)?[\w*.]+(!\w+)*(\([\s\S]*\))?$/

/**
 * Whether a string is a database select list (#2364): two or more comma separated column names, each
 * a bare name with any alias, hints and embedded list, and either one written as a database writes it
 * (an underscore, a hint, an embed, a star) or none capitalised as a sentence opens.
 */
export const selectList = (s: string): boolean => {
  const items = topLevelItems(s)
  if (items.length < 2 || !items.every(i => SELECT_ITEM.test(i))) return false
  return items.some(i => /[_!(*:.]/.test(i)) || !items.some(i => /^[A-Z]/.test(i))
}

// What code reads like, as a string a program writes out (a sandbox's module, a script) does.
const CODE_SIGNS = [
  /=>/,
  /\b(const|let|var)\s+[\w$]+\s*=/,
  /\bfunction\b\s*[\w$]*\s*\(/,
  /\bexport\s+(default|const|function|async|class|\{)/,
  /\bimport\s+[\w${*][^\n]*\bfrom\b/,
  /\breturn\b[^\n]*;/,
  /\bawait\s+[\w$.]+\(/,
  /;\s*(\n|$)/,
  /\)\s*\{/,
  /\bmodule\.exports\b/,
  /\bnew\s+[A-Z]\w*\(/,
]
/** Whether a string is code a program writes out (#2361): two or more signs of code in it. */
export const codeText = (s: string): boolean => CODE_SIGNS.filter(r => r.test(s)).length >= 2

// A SQL select list item: a column, a function call, a cast, an alias.
const SQL_ITEM = '[\\w.*"`]+(\\([^()]*\\))?(\\s*::\\s*\\w+)?(\\s+as\\s+[\\w"`]+)?'
const SQL_SHAPES = [
  new RegExp(`^\\s*\\(?\\s*select\\s+(distinct\\s+)?${SQL_ITEM}(\\s*,\\s*${SQL_ITEM})*\\s+from\\s+\\S`, 'i'),
  /^\s*insert\s+into\s+[\w."`]+\s*(\(|values\b|select\b|default\b)/i,
  /^\s*update\s+[\w."`]+\s+set\s+[\w"`]+\s*=/i,
  /^\s*delete\s+from\s+[\w."`]+(\s+where\b|\s*;?\s*$)/i,
  /^\s*with\s+(recursive\s+)?\w+\s+as\s*\(/i,
  /^\s*(create|alter|drop)\s+(or\s+replace\s+)?(unique\s+)?(table|index|view|function|trigger|policy|schema|type|extension)\b/i,
  /^\s*(where|and|or|join|left\s+join|inner\s+join|order\s+by|group\s+by|having|on\s+conflict|returning)\s+[\w."`]+\s*(=|<>|!=|<=|>=|<|>|\s+is\s+(not\s+)?(null|true|false)\b|\s+in\s*\(|\s+i?like\b|\s+between\b|\s+on\b|\s+(asc|desc)\b|,)/i,
]
/** Whether a string is a SQL statement or a fragment of one (#2364, #2371): a database's words, never a person's. */
export const sqlText = (s: string): boolean => SQL_SHAPES.some(r => r.test(s))

/** Whether a string is message text: prose, and neither a select list, code, nor SQL. */
export const isMessage = (s: string): boolean => isProse(s) && !selectList(s) && !codeText(s) && !sqlText(s)

// claude-config#2720. On 2026-11-10 four alert messages were written into a new copy module that no
// file sent yet, so the guard, which held wording by whether a Slack send reaches it, let them in
// unasked; they were held only later, at the edit importing the module, which the question then
// blamed. A module of message copy is now known by what it is, by its path or by its shape, and its
// new wording held when it is written, even while nothing sends it. Only where nothing sends it:
// a module a sender imports is still judged by what that sender sends (#2570).

// The words of a path part: split at anything but a letter or digit, and where a lower case letter
// or digit meets a capital, so quietFeedCopy is quiet, feed, copy.
const wordsOf = (s: string): string[] =>
  s
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean)
// A name ending in one of these is copy: outage-copy, quietFeedCopy, wording. Starting with one is
// a verb (copy-assets, copyFiles), which is not.
const COPY_WORDS = new Set(['copy', 'copies', 'wording', 'wordings'])
// Words naming an alert, and words naming a message, which together name a module of alert copy
// (slack-messages, alertText, alerts/templates). Either alone names many other things: a Slack gate,
// a list of alerts, an error module.
const ALERT_WORDS = new Set(['slack', 'alert', 'alerts', 'alarm', 'alarms', 'notify', 'notifier'])
const MESSAGE_WORDS = new Set(['message', 'messages', 'msg', 'msgs', 'text', 'texts', 'template', 'templates', 'notice', 'notices', 'blocks'])

/** Whether a repository path names a module of message copy (#2720): a name ending in copy or wording, a copy folder, or alert and message words together. */
const copyByPath = (rel: string): boolean => {
  const segs = rel.split('/')
  const dirs = segs.slice(0, -1)
  const stem = wordsOf(stemOf(segs[segs.length - 1] ?? ''))
  if (COPY_WORDS.has(stem[stem.length - 1] ?? '') || dirs.some(d => COPY_WORDS.has(d.toLowerCase()))) return true
  const words = [...dirs.flatMap(wordsOf), ...stem]
  return words.some(w => ALERT_WORDS.has(w)) && words.some(w => MESSAGE_WORDS.has(w))
}

// Slack's own formatting in a string: a link with its label (<https://x|label>, <${url}|label>), a
// mention of a channel or group (<!here>, <!channel>, <!subteam^ID>), or a Block Kit text type. Only
// a Slack message is written this way.
const SLACK_LINK = /<(?:https?:\/\/|mailto:|\$\{|\{|#|@)[^<>|\s]*\|[^<>\n]+>/
const SLACK_MENTION = /<!(?:here|channel|everyone|subteam\^)[^<>\s]*>/

// A top level declaration that only builds a string: a function returning one string or template
// straight away, as a copy builder does (`(feed) => \`The ${feed} feed...\``, `return f"..."`). A
// function that does other work and prints or throws a message on the way is not one: measured on
// this repository on 2026-11-10, counting those (and shell scripts) read 16 of its 665 code files as
// copy modules, scripts and mods among them; this reads 1, mod-kit's typed answer wording (#2720).
const JS_BUILDER =
  /^(?:export\s+)?(?:(?:async\s+)?function\s*[\w$]+\s*\([^)]*\)\s*(?::[^{]*)?\{\s*return\s*\(?\s*[`'"]|(?:const|let|var)\s+[\w$]+\s*(?::[^=\n]*)?=\s*(?:async\s+)?(?:\([^)]*\)|[\w$]+)\s*(?::[^=\n]*)?=>\s*\(?\s*[`'"])/
const PY_BUILDER = /^(?:async\s+)?def\s+\w+\s*\([^)]*\)\s*(?:->[^:]*)?:\s*(?:\n\s+(?:"""[\s\S]*?"""|'''[\s\S]*?'''))?\s*\n\s+return\s+[rRbBuUfF]*["']/

// A shell script is a program, never a module of copy another file imports.
const SHELL_SCRIPT = new Set(['sh', 'bash', 'zsh'])

/**
 * Whether a file is a module of message copy (#2720), by its repository path or by its shape: Slack
 * formatting in any of its strings, or, in JavaScript, TypeScript or python, mostly functions that
 * only build message text with values filled in (two or more, and at least half its top level
 * declarations). A test, a prose file, a shell script and a UI component never are: a test sends
 * nothing (#2290), and a screen's text is not posted (#2519).
 */
export const copyModule = (rel: string, text: string): boolean => {
  const ext = extOf(rel)
  if (testFile(rel) || isProseFile(rel) || uiComponent(rel) || ext === undefined || SHELL_SCRIPT.has(ext)) return false
  if (copyByPath(rel)) return true
  const lang = languageOf(rel, text)
  const strings = stringsOf(text, lang !== 'c', lang === 'c' && isJs(rel)).filter(s => !s.query)
  // Block Kit's text type, as a pattern so this file holds no such string and is not read as copy.
  if (strings.some(s => /^mrkdwn$/.test(s.text) || (isMessage(s.text) && (SLACK_LINK.test(s.text) || SLACK_MENTION.test(s.text))))) return true
  const python = lang === 'python'
  if (!python && !(lang === 'c' && isJs(rel))) return false
  const r = modelReading(text, python, tokenRanges(text, python))
  const builders = r.decls.filter(d => {
    // The file's own text, where a python docstring is a string the pattern steps over.
    if (!(python ? PY_BUILDER : JS_BUILDER).test(text.slice(d.from, d.to))) return false
    return strings.some(s => s.start >= d.from && s.start < d.to && isMessage(s.text) && fixedParts(s.text).length > 1)
  })
  return builders.length >= 2 && builders.length * 2 >= r.decls.length
}

/** Whether a file is a CI workflow, whose names, needs, descriptions and commands a pipeline runs rather than posts. */
export const ciWorkflow = (path: string): boolean =>
  /(^|\/)\.github\/workflows\/[^/]+\.ya?ml$/.test(path) || /(^|\/)\.gitlab-ci\.ya?ml$/.test(path) || /(^|\/)\.circleci\/config\.ya?ml$/.test(path) || /(^|\/)bitbucket-pipelines\.ya?ml$/.test(path)

// The keys whose value is text a step posts: a Slack action's payload or message, a message env value.
const MESSAGE_KEY = /(^|[-_.])(text|message|msg|title|pretext|fallback|payload|blocks|body|summary|content|subject|footer|header)$/i
// The keys whose value can be a YAML list of shell commands: GitLab's script lists, and Bitbucket's
// script and after-script (#2401, #2416).
const SCRIPT_LIST_KEY = /^(script|before_script|after_script|after-script)$/
// The script lists that run in a shell of their own, apart from the job's other lists (#2416).
const AFTER_KEY = /^after[-_]script$/

// A YAML scalar as the shell receives it, and a flow list's items, read by mod-kit's one reader of
// quoted strings that are not shell (#2467).
import { yamlFlowList, yamlScalar } from './mod-kit/quoted.ts'

/**
 * The commands of a YAML list opening on the line after a key at `indent` (a GitLab `script:` list),
 * each item one shell command: a plain or quoted item with its continuation lines, or a block item
 * (`- |`, `- >`). Comments between items are skipped; the list ends at the first line outside it.
 */
const listCommands = (lines: string[], from: number, indent: number): string[] => {
  const out: string[] = []
  let at = -1
  let cur: string[] | undefined
  let block = ''
  const close = () => {
    if (!cur) return
    const text = block === '|' ? cur.join('\n') : cur.join(' ')
    out.push(block ? text.trim() : yamlScalar(text.trim()))
    cur = undefined
  }
  for (let j = from; j < lines.length; j++) {
    const line = lines[j] as string
    if (!line.trim()) continue
    const lead = /^\s*/.exec(line)![0].length
    if (cur && lead > at) {
      cur.push(line.trim())
      continue
    }
    if (line.trim().startsWith('#') && (at < 0 || lead <= at)) continue
    const item = /^(\s*)-(?:\s+(.*))?$/.exec(line)
    if (!item || lead < indent || (at >= 0 && lead !== at)) break
    close()
    at = lead
    const first = (item[2] ?? '').trim()
    block = /^[|>][-+]?\d*$/.test(first) ? first[0] as string : ''
    cur = block ? [] : [first]
  }
  close()
  return out
}

/**
 * The commands of a YAML flow list (`script: ["a", "b"]`) opening in `raw` on line `from`, read on
 * over the lines after it until the list closes: each item with its quoting undone (#2416), read by
 * mod-kit's yamlFlowList (#2467).
 */
export const flowCommands = (lines: string[], from: number, raw: string): string[] => yamlFlowList([raw, ...lines.slice(from + 1)].join('\n'))

/**
 * The line that opens the mapping a key at line `i` and column `column` sits in: the key's own line
 * when it opens a list item (`- script:`), else the nearest line above it indented less than it.
 */
const mappingOf = (lines: string[], i: number, column: number, item: boolean): number => {
  if (item) return i
  for (let j = i - 1; j >= 0; j--) {
    const l = lines[j] as string
    if (l.trim() && !l.trim().startsWith('#') && /^\s*/.exec(l)![0].length < column) return j
  }
  return -1
}

/**
 * The text a CI workflow can post (Dan's item 1, #2371): the value of a message key (a Slack step's
 * payload, text or message, a MESSAGE env value), each string inside a JSON payload, and the strings
 * of a run command that itself posts to Slack (a curl to a webhook), a JSON body's strings included.
 * A GitLab or Bitbucket script is a run command too, written as a list (block or flow), a block, or
 * one string: the lists one shell runs (a job's before_script and script, or after_script on its
 * own) are read together as one run block, so when any of it posts to Slack, every string in it is
 * shown, a message one item sets for a later item to post included (#2401, #2416). A script block in
 * a GitHub workflow is github-script's JavaScript, read as code. Step and job names, needs lists,
 * input descriptions and every other run command are left out. `path` is the file's path.
 */
export const ciMessages = (text: string, path: string): string[] => {
  const lines = text.split('\n')
  // Each key's messages in file order; a shell's place is held by its key until all its lists are read.
  const parts: (string[] | string)[] = []
  const shells = new Map<string, string[]>()
  const github = /(^|\/)\.github\/workflows\//.test(path)
  const strings = (t: string): string[] => stringsOf(t, true).flatMap(s => [s.text, ...(s.text.trimStart().startsWith('{') ? literalsOf(s.text, true) : [])])
  for (let i = 0; i < lines.length; i++) {
    const m = /^(\s*)(-\s+)?([\w.-]+):(?:\s+(.*))?$/.exec(lines[i] as string)
    if (!m) continue
    const indent = (m[1] as string).length + (m[2] ?? '').length
    const key = m[3] as string
    const raw = (m[4] ?? '').trim()
    const at = i
    let value = raw
    if (/^[|>][-+]?\d*$/.test(raw)) {
      const block: string[] = []
      while (i + 1 < lines.length && (!(lines[i + 1] as string).trim() || /^\s*/.exec(lines[i + 1] as string)![0].length > indent)) block.push(lines[++i] as string)
      value = block.join('\n').trim()
    }
    // A script (GitLab, Bitbucket) is a run block, whatever its YAML shape: its commands join those of
    // the other lists its shell runs, read once the whole file is (#2401, #2416). A list's lines are
    // left for this loop too, and a script value still takes the paths below, so nothing read before
    // is read any less. A GitHub script block or string is JavaScript, read below as it always was.
    if (SCRIPT_LIST_KEY.test(key)) {
      const shellText = !github || key !== 'script'
      const cmds = !raw
        ? listCommands(lines, at + 1, indent)
        : raw.startsWith('[')
          ? flowCommands(lines, at, raw)
          : !shellText
            ? []
            : value !== raw
              ? [value]
              : [yamlScalar(value)]
      if (cmds.length) {
        const shell = `${mappingOf(lines, at, indent, m[2] !== undefined)}${AFTER_KEY.test(key) ? ' after' : ''}`
        if (!shells.has(shell)) {
          shells.set(shell, [])
          parts.push(shell)
        }
        shells.get(shell)!.push(...cmds)
      }
    }
    if (!value) continue
    if (MESSAGE_KEY.test(key)) {
      if (/^["'{[]/.test(value)) parts.push(literalsOf(value, true))
      else parts.push([value])
    } else if (key === 'run' && slackMarked(value)) parts.push(strings(value))
    // A script step (github-script) that posts to Slack is JavaScript: each string in it, a piece of
    // a concatenation included, is wording, and the code around them never is (#2371, Dan's item 5).
    else if (key === 'script' && slackMarked(value)) parts.push(stringsOf(value, false, true).filter(s => !s.query).map(s => s.text))
  }
  return parts.flatMap(p => {
    if (typeof p !== 'string') return p
    const cmds = shells.get(p) ?? []
    // An item that posts is read whatever the rest of its shell holds, so no shape hides it (#2401).
    return cmds.some(slackMarked) || slackMarked(cmds.join('\n')) ? cmds.flatMap(strings) : []
  })
}

/** The message text among a file's literals, each kept as often as it appears. */
export const wordingOf = (literals: string[]): string[] => literals.filter(isMessage)

/** The message text an edit adds and takes away, counted, so text only moved is no change. */
export const wordingChange = (before: string[], after: string[]): { added: string[]; removed: string[] } => {
  const left = new Map<string, number>()
  for (const s of before) left.set(s, (left.get(s) ?? 0) + 1)
  const added: string[] = []
  for (const s of after) {
    const n = left.get(s) ?? 0
    if (n > 0) left.set(s, n - 1)
    else added.push(s)
  }
  const removed: string[] = []
  for (const s of before) {
    const n = left.get(s) ?? 0
    if (n > 0) {
      removed.push(s)
      left.set(s, n - 1)
    }
  }
  return { added, removed }
}

// Text only a model reads (#2475). A module a Slack sender imports can hold a model's own
// instructions beside the words it posts, and those instructions were held as Slack wording, the
// whole prompt shown in the picker. A string is read only by a model when it is the value of a key
// only a model reads (system, instructions, prompt, or a message's content beside its role), or sits
// in a top level declaration whose every use, in its own file and in every other file naming it, is
// such a value, an import of it by its own name, or a part of another such declaration. One use of
// any other kind (posted, logged, handed to a function, renamed on export) and it counts as wording,
// so nothing the guard cannot follow is let through.

/** A stretch of a file's text, from its first character up to but not including `to`. */
export type Range = { from: number; to: number }

/** The stretches of a file's text that are the inside of a string, and its comments, as stringsOf reads them. */
export const tokenRanges = (text: string, hash: boolean): { strings: Range[]; comments: Range[] } => {
  const strings: Range[] = []
  const comments: Range[] = []
  for (const m of text.matchAll(new RegExp(hash ? HASH_TOKENS : C_TOKENS, 'g'))) {
    const from = m.index ?? 0
    const to = from + m[0].length
    if (m[1] === undefined && m[2] === undefined && m[3] === undefined) comments.push({ from, to })
    else strings.push({ from: from + 1, to: to - 1 })
  }
  return { strings, comments }
}

// A file's text with its comments blanked character for character, so every place in it stays where
// it was.
const blankComments = (text: string, comments: Range[]): string => {
  let out = ''
  let at = 0
  for (const c of [...comments].sort((a, b) => a.from - b.from)) {
    if (c.from < at) continue
    out += text.slice(at, c.from) + text.slice(c.from, c.to).replace(/[^\n]/g, ' ')
    at = c.to
  }
  return out + text.slice(at)
}

const MODEL_KEYS = 'system|system_?prompt|instructions|prompt'
// What comes before a model's input: an object's or dict's key after a brace or a comma, or a python
// keyword argument after a bracket or a comma, the value possibly reached through a module
// (copy.PROMPT). `const system = x` is a variable, never a key, so it is not one.
const MODEL_VALUE = new RegExp(`(?:[{,]\\s*["']?(?:${MODEL_KEYS})["']?\\s*:|[(,]\\s*(?:${MODEL_KEYS})\\s*=)\\s*(?:[\\w$]+\\s*\\.\\s*)*$`, 'i')
const CONTENT_VALUE = /[{,]\s*["']?content["']?\s*:\s*(?:[\w$]+\s*\.\s*)*$/i
const ROLE = /["']?\brole["']?\s*:/

/**
 * Whether what stands at `at` in `code` (its comments blanked) is handed to a model: the value of a
 * system, instructions or prompt key or keyword, or the content of a message object that carries a role.
 */
export const modelInput = (code: string, at: number): boolean => {
  const before = code.slice(Math.max(0, at - 400), at)
  if (MODEL_VALUE.test(before)) return true
  if (!CONTENT_VALUE.test(before)) return false
  const open = code.lastIndexOf('{', at)
  const close = code.indexOf('}', at)
  return open >= 0 && close > at && ROLE.test(code.slice(open, close))
}

/** A top level declaration: its name, where the name is, its whole text, and whether another file can import it. */
export type Decl = { name: string; at: number; from: number; to: number; open: boolean }
/** A file read for what only a model reads: its text with comments blanked, its language, its top level declarations. */
export type ModelReading = { code: string; python: boolean; decls: Decl[] }

const JS_DECL = /^(export\s+)?(?:declare\s+)?(?:(?:const|let|var)\s+([\w$]+)\s*(?::[^=\n]*)?=(?!=)|(?:async\s+)?function\s*\*?\s*([\w$]+)\s*[(<])/
const PY_DECL = /^(?:([A-Za-z_]\w*)\s*(?::[^=\n]*)?=(?!=)|(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\()/
const nameRe = (name: string) => new RegExp(`(?<![\\w$])${escapeRe(name)}(?![\\w$])`, 'g')
const usesOf = (code: string, name: string): number[] => [...code.matchAll(nameRe(name))].map(m => m.index ?? 0)
const inside = (rs: Range[], i: number) => rs.some(r => i >= r.from && i < r.to)
// A name in a JavaScript export list under its own name: export { A, B }.
const EXPORT_LIST = /\bexport\s+(?:type\s+)?\{[\w$\s,]*$/
const exportListed = (code: string, at: number, name: string): boolean =>
  EXPORT_LIST.test(code.slice(Math.max(0, at - 400), at)) && /^\s*[,}]/.test(code.slice(at + name.length))

/**
 * A file read for its top level declarations (#2475). A statement starts on a line beginning with
 * anything but a space, a closing bracket, a quote or a dot, outside any string, so a line of a
 * multi line prompt is never taken for one; a declaration runs to the next statement. A python name
 * not starting with an underscore, or a JavaScript one exported, can be imported by another file.
 */
export const modelReading = (text: string, python: boolean, ranges: { strings: Range[]; comments: Range[] }): ModelReading => {
  const code = blankComments(text, ranges.comments)
  const starts: number[] = []
  let i = 0
  for (const line of code.split('\n')) {
    if (/^[^\s)\]}'"`.]/.test(line) && !inside(ranges.strings, i)) starts.push(i)
    i += line.length + 1
  }
  starts.push(code.length)
  const decls: Decl[] = []
  for (let k = 0; k < starts.length - 1; k++) {
    const from = starts[k] as number
    const to = starts[k + 1] as number
    const m = (python ? PY_DECL : JS_DECL).exec(code.slice(from, to))
    if (!m) continue
    const name = (python ? (m[1] ?? m[2]) : (m[2] ?? m[3])) as string
    const at = from + m[0].search(new RegExp(nameRe(name).source))
    const open = python ? !name.startsWith('_') : m[1] !== undefined || usesOf(code, name).some(u => exportListed(code, u, name))
    decls.push({ name, at, from, to, open })
  }
  return { code, python, decls }
}

const hostOf = (r: ModelReading, i: number): Decl | undefined => r.decls.find(d => i >= d.from && i < d.to)

/**
 * The declarations a change could make read only by a model: those holding a changed string (`starts`),
 * and every declaration using one of them, so a prompt built from parts is judged as a whole.
 */
export const modelCandidates = (r: ModelReading, starts: number[]): Decl[] => {
  const out = new Set<Decl>()
  const todo = starts.flatMap(s => hostOf(r, s) ?? [])
  while (todo.length) {
    const d = todo.pop() as Decl
    if (out.has(d)) continue
    out.add(d)
    for (const at of usesOf(r.code, d.name)) {
      const h = hostOf(r, at)
      if (h && h !== d && !out.has(h)) todo.push(h)
    }
  }
  return [...out]
}

/**
 * The names among `candidates` whose uses in other files must be read before they can count as read
 * only by a model: those another file can import, whose every use here could be a model's.
 */
export const foreignNames = (r: ModelReading, candidates: Decl[]): string[] =>
  candidates
    .filter(d => d.open)
    .filter(d =>
      usesOf(r.code, d.name).every(at => {
        if (at === d.at) return true
        const h = hostOf(r, at)
        return (h !== undefined && h !== d && candidates.includes(h)) || modelInput(r.code, at) || (!r.python && exportListed(r.code, at, d.name))
      }),
    )
    .map(d => d.name)

/** How the other files of a repository use a name: ok when every use is an import of it by its own name or a model's input; model when one is a model's input. */
export type Foreign = Map<string, { ok: boolean; model: boolean }>

const JS_IMPORT = /\b(?:import|export)\s+(?:type\s+)?\{[\w$\s,]*$/
const JS_IMPORT_END = /^\s*(?:,[\w$\s,]*)?\}\s*from\b/
const PY_IMPORT = /(?:^|\n)[ \t]*from[ \t]+[\w.]+[ \t]+import[ \t]+(?:\([\w\s,]*|[\w \t,]*)$/
const PY_IMPORT_END = /^[ \t]*(?:[,)#\n]|$)/

/** How one other file uses `name` (#2475): an import by its own name is no use, a model's input is a model use, anything else is not ok. */
export const foreignUse = (rel: string, text: string, name: string): { ok: boolean; model: boolean } => {
  const lang = languageOf(rel, text)
  const python = lang === 'python'
  const code = blankComments(text, tokenRanges(text, lang !== 'c').comments)
  let model = false
  for (const at of usesOf(code, name)) {
    const before = code.slice(Math.max(0, at - 400), at)
    const after = code.slice(at + name.length)
    if (python ? PY_IMPORT.test(before) && PY_IMPORT_END.test(after) : JS_IMPORT.test(before) && JS_IMPORT_END.test(after)) continue
    if (modelInput(code, at)) {
      model = true
      continue
    }
    return { ok: false, model: false }
  }
  return { ok: true, model }
}

/**
 * The candidates read only by a model (#2475): every use of one, here and in the other files that
 * name it (`foreign`, which must carry each name foreignNames gave, or it counts as wording), is a
 * model's input, an import or export under its own name, or a part of another such declaration, and
 * at least one is a model's, so a constant used nowhere still counts.
 */
export const modelOnlyDecls = (r: ModelReading, candidates: Decl[], foreign: Foreign): Set<Decl> => {
  const only = new Set<Decl>()
  for (let grew = true; grew; ) {
    grew = false
    for (const d of candidates) {
      if (only.has(d)) continue
      const far = d.open ? foreign.get(d.name) : { ok: true, model: false }
      if (!far?.ok) continue
      let ok = true
      let model = far.model
      for (const at of usesOf(r.code, d.name)) {
        if (at === d.at) continue
        const h = hostOf(r, at)
        if ((h && h !== d && only.has(h)) || modelInput(r.code, at)) model = true
        else if (r.python || !exportListed(r.code, at, d.name)) {
          ok = false
          break
        }
      }
      if (ok && model) {
        only.add(d)
        grew = true
      }
    }
  }
  return only
}

/** Whether the string whose text starts at `start` is read only by a model: inside a declaration only a model reads, or itself a model key's value. */
export const modelLiteral = (r: ModelReading, only: Set<Decl>, start: number): boolean => {
  for (const d of only) if (start >= d.from && start < d.to) return true
  let i = start
  while (i > 0 && /["'`]/.test(r.code[i - 1] ?? '')) i--
  while (i > 0 && start - i < 6 && /[rRbBfFuU]/.test(r.code[i - 1] ?? '')) i--
  return modelInput(r.code, i)
}

// cyrb53, as the design round guard keys a call: the hash finds the record, and the record keeps the text.
const hash = (text: string): string => {
  let h1 = 0xdeadbeef
  let h2 = 0x41c6ce57
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i)
    h1 = Math.imul(h1 ^ c, 2654435761)
    h2 = Math.imul(h2 ^ c, 1597334677)
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909)
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909)
  return `${(4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(16)}:${text.length}`
}

/** Where Dan's approval of one exact wording is kept: by the wording alone, never the file (decision 3). */
export const wordingKey = (text: string): string => `wording:${hash(text)}`
/** Where his approval of taking text away from one file is kept: by the file and the text removed. */
export const removalKey = (file: string, removed: string[]): string => `removal:${hash(JSON.stringify([file, [...removed].sort()]))}`
/**
 * Where his approval of one shell call is kept: by its whole command and the files it writes, as
 * absolute paths, never the folder it runs from (#2371, Dan's item 4). The same command run again
 * keeps his answer, by a resumed agent or from another folder; words that write a different file from
 * there are another call.
 */
export const shellKey = (command: string, paths: string[]): string => `shell:${hash(JSON.stringify([command, [...new Set(paths)].sort()]))}`
/**
 * Where his approval of one edit the guard could not trace is kept (#2709): by the file and the
 * whole text the edit finds there and leaves, so it lets through that one edit and no other. Any
 * other edit to the file, or the same edit to a file that has changed since, is asked about again.
 */
export const untracedKey = (file: string, before: string, after: string): string => `untraced:${hash(JSON.stringify([file, before, after]))}`

/** The lines an edit adds and takes away, each exactly as written and in its order, blank lines left out (#2709). */
export const changedLines = (before: string, after: string): { added: string[]; removed: string[] } => {
  const lines = (t: string) => t.split('\n').filter(l => l.trim())
  const counted = (ls: string[]) => {
    const m = new Map<string, number>()
    for (const l of ls) m.set(l, (m.get(l) ?? 0) + 1)
    return m
  }
  // The lines of `ls` left once each line `other` also holds has been matched off, one for one.
  const beyond = (ls: string[], other: string[]) => {
    const left = counted(other)
    return ls.filter(l => {
      const n = left.get(l) ?? 0
      if (n > 0) left.set(l, n - 1)
      return n === 0
    })
  }
  const [was, now] = [lines(before), lines(after)]
  return { added: beyond(now, was), removed: beyond(was, now) }
}

/**
 * The text a call leaves in a file it edits, from the file as it is: a Write's content, an Edit's
 * (one match, or every match with replace_all, as Edit itself requires), MultiEdit's edits in turn.
 * Undefined for an edit that would not apply and for any other tool.
 */
export const editedText = (before: string, tool: string, input: Record<string, unknown>): string | undefined => {
  const apply = (text: string, edit: unknown): string | undefined => {
    const e = (edit ?? {}) as Record<string, unknown>
    if (typeof e.old_string !== 'string' || typeof e.new_string !== 'string' || !e.old_string) return undefined
    const parts = text.split(e.old_string)
    if (parts.length < 2 || (parts.length > 2 && e.replace_all !== true)) return undefined
    return parts.join(e.new_string)
  }
  if (tool === 'Write') return typeof input.content === 'string' ? input.content : undefined
  if (tool === 'Edit') return apply(before, input)
  if (tool !== 'MultiEdit' || !Array.isArray(input.edits) || !input.edits.length) return undefined
  let text: string | undefined = before
  for (const e of input.edits) if ((text = apply(text, e)) === undefined) return undefined
  return text
}

/** The text an edit's own halves carry, for an edit that would not apply to the file as it is. */
export const editHalves = (tool: string, input: Record<string, unknown>): { before: string; after: string } => {
  const edits = tool === 'MultiEdit' && Array.isArray(input.edits) ? (input.edits as Record<string, unknown>[]) : [input]
  return { before: edits.map(e => String(e.old_string ?? '')).join('\n'), after: edits.map(e => String(e.new_string ?? e.content ?? '')).join('\n') }
}

const norm = (s: string): string => s.replace(/\s+/g, ' ').trim()
const PLACEHOLDER = /\$\{[^}]*\}|#\{[^}]*\}|\{\{[^}]*\}\}|%[sd]\b|\{[A-Za-z_][\w.]*\}/

/**
 * Why the message Claude shows Dan is not yet the real one, or undefined when it is: it must be
 * given, carry no placeholder still to fill, and hold every fixed part of each string the call adds.
 * A placeholder in `literal`, one the code writes as text rather than fills (stringsOf), is the
 * message as posted, so it may stand (#2361).
 */
export const renderedProblem = (rendered: unknown, added: string[], literal: string[] = []): string | undefined => {
  if (typeof rendered !== 'string' || !rendered.trim())
    return 'Give metadata "rendered": the message exactly as Slack will post it, every variable filled in from a realistic example.'
  const left = [...rendered.matchAll(new RegExp(PLACEHOLDER.source, 'g'))].map(m => m[0]).find(p => !literal.includes(p))
  if (left !== undefined) return `The message shown still has ${left} in it: fill every variable in from a realistic example, so Dan reads the message as Slack will post it.`
  const shown = norm(rendered)
  for (const s of added)
    for (const part of fixedParts(s).map(norm))
      if (/[A-Za-z]{2,}/.test(part) && !shown.includes(part)) return `The message shown leaves out "${part}", which the edit adds: show the whole message as Slack will post it.`
  return undefined
}

/** Whether a path is this mod's own store file, which only Dan's answer may write. */
export const isOwnRecord = (path: string): boolean => /\/plugins\/store\/slack-alert-guard[_.]/.test(path) || /(^|\/)slack-alert-guard_[^/]*$/.test(path)
/** Whether a shell command names the plugin store, which the write reader may not follow into. */
export const mentionsStore = (text: string): boolean => /plugins\/store/.test(text)

const listed = (xs: string[]): string => xs.map(x => `"${x}"`).join(', ')

/** What a held module of message copy that no file uses yet is called on the card, refusals and question (#2720). */
export const UNWIRED = 'a module of message copy not yet wired to Slack'

/** What changes, in the words the refusal and card name it by. */
export const changeText = (added: string[], removed: string[]): string =>
  added.length ? `adds Slack message text Dan has not approved: ${listed(added)}` : `takes Slack message text away: ${listed(removed)}`

/**
 * What is held, as the card and both refusals open. A shell command carries no wording the guard
 * can read before it runs, so it is named as that rather than as an empty list taken away. A
 * template another file sends (#2248) names that file, its sender, so Dan sees what posts it. An
 * edit that adds no text of its own and brings another file's to a send (#2637) names that file,
 * `from`, as where the text is. A module of message copy no file uses yet (#2720), `unwired`, is
 * named as that, so Dan can tell it from a live send (his choice of words, 2026-11-11).
 */
export const heldText = (file: string, added: string[], removed: string[], sender?: string, from?: string, unwired?: boolean): string =>
  from
    ? `This edit to ${file} makes ${sender && sender !== file ? sender : 'it'} send Slack message text from ${from} that Dan has not approved: ${listed(added)}`
    : added.length || removed.length
    ? `This edit to ${file}${sender ? `, which ${sender} sends to Slack,` : unwired ? `, ${UNWIRED},` : ''} ${changeText(added, removed)}`
    : `This shell command writes to ${file}, ${sender ? `which ${sender} sends to Slack` : unwired ? UNWIRED : 'which posts to Slack'}, and the wording it leaves cannot be read until it runs`

export const blocked = (file: string, added: string[], removed: string[], sender?: string, from?: string, unwired?: boolean): string =>
  `Blocked: t${heldText(file, added, removed, sender, from, unwired).slice(1)}`

/** The main session's refusal: show Dan the message as Slack will post it, then ask. */
export const refusal = (id: string, file: string, added: string[], removed: string[], sender?: string, from?: string, unwired?: boolean): string =>
  `${blocked(file, added, removed, sender, from, unwired)}. Every new Slack alert's wording waits until Dan approves it. Show him the whole message as Slack will post it, with every variable filled in from a realistic example (real looking names, numbers and links, never a placeholder), then ask him with AskUserQuestion, carrying metadata {"source": "${SOURCE}:${id}", "rendered": "<that message>"} and no answers filled in. The guard words the question. Send this call again, unchanged, once he answers ${APPROVE}.`

/** A subagent's refusal: it may not ask Dan, so it stops and reports. */
export const agentRefusal = (id: string, file: string, added: string[], removed: string[], sender?: string, from?: string, unwired?: boolean): string =>
  `${blocked(file, added, removed, sender, from, unwired)}. Slack alert wording waits on Dan's approval, which only the main session can ask for. Stop and report to the main session that call ${id} waits on Dan approving this wording, with the message as Slack will post it, every variable filled in from a realistic example.`

/**
 * An edit the guard could not trace (#2709): the trace stopped at one of its limits, which it meets
 * the same way on every try, so trying again can never get it through. What it changes, line by
 * line, and why the guard stopped.
 */
export const untracedText = (file: string, added: string[], removed: string[], why: string): string => {
  const parts = [...(added.length ? [`adds ${listed(added)}`] : []), ...(removed.length ? [`takes away ${listed(removed)}`] : [])]
  const what = parts.length ? parts.join(' and ') : 'changes only blank lines or the order of its lines'
  return `This edit to ${file} ${what}, and the Slack alert guard could not trace whether that reaches Slack: ${why}`
}

/** The main session's refusal of an untraced edit: ask Dan, who sees the lines the guard shows him. */
export const untracedRefusal = (id: string, file: string, added: string[], removed: string[], why: string): string =>
  `Blocked: t${untracedText(file, added, removed, why).slice(1)}. Trying again is held the same way, so Dan decides this one edit. Ask him with AskUserQuestion, carrying metadata {"source": "${SOURCE}:${id}"} and no answers filled in. The guard words the question and shows him the lines. Send this call again, unchanged, once he answers ${APPROVE}.`

/** A subagent's refusal of an untraced edit: it may not ask Dan, so it stops and reports. */
export const untracedAgentRefusal = (id: string, file: string, added: string[], removed: string[], why: string): string =>
  `Blocked: t${untracedText(file, added, removed, why).slice(1)}. Trying again is held the same way, and only the main session can ask Dan to approve this one edit. Stop and report to the main session that call ${id} waits on Dan approving an edit the Slack alert guard could not trace.`

/** The question for an untraced edit: the file, that the guard could not trace it, why, and its exact lines. */
export const untracedQuestion = (file: string, added: string[], removed: string[], why: string): string => {
  const lines = [...(added.length ? [`Adds:\n${added.join('\n')}`] : []), ...(removed.length ? [`Takes away:\n${removed.join('\n')}`] : [])]
  const shown = lines.length ? lines.join('\n\n') : 'Changes only blank lines or the order of its lines.'
  return `The Slack alert guard could not trace whether this edit to ${file} reaches Slack. Approve this one edit? Approving sends nothing: it only lets that edit go ahead.\n\nWhy: ${why}\n\n${shown}`
}

/**
 * The question Dan is asked, with the message itself in it. Approving posts nothing: it only lets
 * the held edit through, so the question never asks to post (claude-config#2284). For wording an
 * edit brings in from another file (#2637), `from` is the file that holds it. For a module of
 * message copy no file uses yet (#2720), `unwired`, the file is named as that.
 */
export const question = (file: string, rendered: string, from?: string, unwired?: boolean): string =>
  from
    ? `Approve the wording of an automated Slack alert defined in ${from}, which the held edit to ${file} brings into use? Approving sends nothing: it only lets that edit go ahead.\n\n${rendered}`
    : `Approve the wording of an automated Slack alert defined in ${file}${unwired ? `, ${UNWIRED}` : ''}? Approving sends nothing: it only lets the held edit to that file go ahead.\n\n${rendered}`
