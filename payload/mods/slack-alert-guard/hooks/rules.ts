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

export const GUARD = 'Slack alert guard'
export const SOURCE = 'slack-alert-guard'
export const HEADER = 'Slack alert'
export const APPROVE = 'Approve wording'
export const CHANGE = 'Change wording'
/** How long the search for a file that sends a template may take, every git call and read in it. */
export const SCAN_MS = 3000
/** How many files that import and re-export a template the search follows before it holds as could not check (#2286). */
export const REEXPORT_HOPS = 3

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
export const MARKERS: RegExp[] = [
  /hooks\.slack\.com/,
  /chat[._]postMessage/,
  /@slack\//,
  /slack[_]sdk/,
  /slack-go\//,
  /SLACK[_]\w*(WEBHOOK|TOKEN|CHANNEL)/i,
  /\b(send|post|notify|alert)\w*slack\w*\s*\(/i,
  // The same helper imported without being called, as a test asserting its wording does. Only an
  // import or require line counts, so the name in a comment or a config key is not a post.
  /^\s*(import|from)\b[^\n]*\b(send|post|notify|alert)\w*slack/im,
  /\b(send|post|notify|alert)\w*slack\w*\b[^\n]*\brequire\s*\(/i,
  /\bslack\w*\.(send|post|notify|chat)\w*\s*\(/i,
  /\bslack\w*(send|post|notify|message|alert)\w*\s*\(/i,
]

/** Whether a file's text posts to Slack: a webhook, the chat API, a Slack SDK, a Slack env setting, or a send helper named for Slack. */
export const slackMarked = (text: string): boolean => MARKERS.some(m => m.test(text))

/**
 * What the repository is searched for before any file is read, case ignored: every marker names
 * slack or postMessage, so no file slackMarked would match is left out (a test holds every marker
 * to it). The marker itself is still decided by slackMarked alone.
 */
export const SENDER_PREFILTER = 'slack|postmessage'

/**
 * Whether a path, relative to its repository's root, is a test: a .test. or .spec. file, a _test or
 * _spec one, a python test_ module, a test- shell suite, or anything in a test or mock folder. A test
 * never posts to Slack, so its titles and fixtures are never message text (#2290).
 */
export const testFile = (rel: string): boolean => {
  const segs = rel.split('/')
  const name = segs[segs.length - 1] ?? ''
  if (/\.(test|spec)\.[^/]+$/.test(name) || /_(test|spec)\.[^/.]+$/.test(name) || /^test_[^/]*\.py$/.test(name) || /^test-[^/]*\.(sh|bash|zsh)$/.test(name)) return true
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
// workflow's `curl ... --data-binary @alerts/late.txt` posts it (#2368). Matched on lower cased text.
const READS =
  /\b(import|require|from|export|cat|source)\b|\b(include|load\w*|open|read\w*|render\w*|\w*template\w*|send_?file|join|resolve|Path|URL)\s*\(|__dirname|__file__|import\.meta|\$\(\s*<|^\s*\.\s+\S|(^|\s)(-d|--data(-[a-z]+)?)(\s+|=)['"]?@|(^|\s)(-f|--form)\s+['"]?[\w-]+=@/

/**
 * Whether a sender's text names a template's path, both given relative to the repository root.
 * Read as a path (a token holding a slash, or a file name with the template's extension): a
 * relative one resolved from the sender's folder or the root must be the template itself; any other
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

/**
 * The words a search for the modules a file imports looks for (#2361): the last name of each local
 * JavaScript or TypeScript import (a relative or aliased path, never a bare package), its folder's for
 * an index, and the last name of each python import.
 */
export const importTerms = (text: string): string[] => {
  const out = new Set<string>()
  const code = withoutComments(text, false)
  for (const m of code.matchAll(/(?:\bfrom\s*|\brequire\s*\(\s*|\bimport\s*\(\s*|\bimport\s+)["'`]([^"'`\n]+)["'`]/g)) {
    const spec = m[1] as string
    if (!spec.startsWith('.') && !spec.includes('/')) continue
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

/** The files a template may be handed on through, as git pathspecs. */
export const LINK_PATHS = [...JS, 'py'].map(e => `*.${e}`)

// A character that cannot be part of a name, and one that also cannot open a quote or a brace, which
// a python import line never holds (importedModules). Written without \b, which macOS git grep -E
// reads as matching nothing.
const EDGE = '[^A-Za-z0-9_]'
const NAME_END = `(${EDGE}|$)`
const BARE = '[^"\'`{}]'
const BARE_EDGE = '[^A-Za-z0-9_"\'`{}]'

/**
 * What git grep -E, case ignored, is given to list the files that may name any of `rels` (#2371):
 * `word`, the names alone, which git tests first and cheaply, and `shape`, tested only on a line
 * holding one (`-e word --and -e shape`): the name in a form refersTo can accept. That is after a
 * slash (a path), as a file name with its extension, after its folder's name and a dot (a dotted
 * module), or on a python import line; a package's index or __init__ is named by its folder, as a
 * whole word. A word the name is only a piece of (et in settings, memory in "kept in memory") is
 * never listed, so a common short name no longer lists a crowd of files to read. Every form
 * refersTo accepts holds one of these, so nothing it would find is left out.
 */
export const namePatterns = (rels: string[]): { word: string; shape: string } => {
  const words = new Set<string>()
  const shapes = new Set<string>()
  for (const r of rels) {
    const segs = r.split('/')
    const t = escapeRe(searchTerm(r))
    words.add(t)
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
  const w = [...words]
  return { word: w.length === 1 ? (w[0] as string) : `(${w.join('|')})`, shape: [...shapes].join('|') }
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
const fixedParts = (s: string): string[] => markFilled(s).split(FILLED_MARK)

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

/** Whether a file is a CI workflow, whose names, needs, descriptions and commands a pipeline runs rather than posts. */
export const ciWorkflow = (path: string): boolean =>
  /(^|\/)\.github\/workflows\/[^/]+\.ya?ml$/.test(path) || /(^|\/)\.gitlab-ci\.ya?ml$/.test(path) || /(^|\/)\.circleci\/config\.ya?ml$/.test(path) || /(^|\/)bitbucket-pipelines\.ya?ml$/.test(path)

// The keys whose value is text a step posts: a Slack action's payload or message, a message env value.
const MESSAGE_KEY = /(^|[-_.])(text|message|msg|title|pretext|fallback|payload|blocks|body|summary|content|subject|footer|header)$/i
// The keys whose value can be a YAML list of shell commands: GitLab's script lists, and Bitbucket's script (#2401).
const SCRIPT_LIST_KEY = /^(script|before_script|after_script)$/

/** A YAML scalar as the shell receives it: a quoted one with its quoting undone, a plain one as written. */
const yamlScalar = (s: string): string => {
  if (s.length >= 2 && s.startsWith("'") && s.endsWith("'")) return s.slice(1, -1).replace(/''/g, "'")
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) return s.slice(1, -1).replace(/\\(.)/g, (_, c: string) => (c === 'n' ? '\n' : c === 't' ? '\t' : c))
  return s
}

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
 * The text a CI workflow can post (Dan's item 1, #2371): the value of a message key (a Slack step's
 * payload, text or message, a MESSAGE env value), each string inside a JSON payload, and the strings
 * of a run command that itself posts to Slack (a curl to a webhook), a JSON body's strings included.
 * Step and job names, needs lists, input descriptions and every other run command are left out.
 */
export const ciMessages = (text: string): string[] => {
  const lines = text.split('\n')
  const out: string[] = []
  const strings = (t: string): string[] => stringsOf(t, true).flatMap(s => [s.text, ...(s.text.trimStart().startsWith('{') ? literalsOf(s.text, true) : [])])
  for (let i = 0; i < lines.length; i++) {
    const m = /^(\s*)(-\s+)?([\w.-]+):(?:\s+(.*))?$/.exec(lines[i] as string)
    if (!m) continue
    const indent = (m[1] as string).length + (m[2] ?? '').length
    const key = m[3] as string
    const raw = (m[4] ?? '').trim()
    let value = raw
    if (/^[|>][-+]?\d*$/.test(raw)) {
      const block: string[] = []
      while (i + 1 < lines.length && (!(lines[i + 1] as string).trim() || /^\s*/.exec(lines[i + 1] as string)![0].length > indent)) block.push(lines[++i] as string)
      value = block.join('\n').trim()
    }
    // A script list (GitLab, Bitbucket) is a run block written one command per item: each item that
    // posts to Slack is read as a run command that posts, and an item that posts nothing never is (#2401).
    // Its lines are left for this loop too, so nothing read before is read any less.
    if (!raw && SCRIPT_LIST_KEY.test(key)) for (const c of listCommands(lines, i + 1, indent)) if (slackMarked(c)) out.push(...strings(c))
    if (!value) continue
    if (MESSAGE_KEY.test(key)) {
      if (/^["'{[]/.test(value)) out.push(...literalsOf(value, true))
      else out.push(value)
    } else if (key === 'run' && slackMarked(value)) out.push(...strings(value))
    // A script step (github-script) that posts to Slack is JavaScript: each string in it, a piece of
    // a concatenation included, is wording, and the code around them never is (#2371, Dan's item 5).
    else if (key === 'script' && slackMarked(value)) out.push(...stringsOf(value, false, true).filter(s => !s.query).map(s => s.text))
  }
  return out
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

/** What changes, in the words the refusal and card name it by. */
export const changeText = (added: string[], removed: string[]): string =>
  added.length ? `adds Slack message text Dan has not approved: ${listed(added)}` : `takes Slack message text away: ${listed(removed)}`

/**
 * What is held, as the card and both refusals open. A shell command carries no wording the guard
 * can read before it runs, so it is named as that rather than as an empty list taken away. A
 * template another file sends (#2248) names that file, its sender, so Dan sees what posts it.
 */
export const heldText = (file: string, added: string[], removed: string[], sender?: string): string =>
  added.length || removed.length
    ? `This edit to ${file}${sender ? `, which ${sender} sends to Slack,` : ''} ${changeText(added, removed)}`
    : `This shell command writes to ${file}, which ${sender ? `${sender} sends to Slack` : 'posts to Slack'}, and the wording it leaves cannot be read until it runs`

const blocked = (file: string, added: string[], removed: string[], sender?: string): string =>
  `Blocked: t${heldText(file, added, removed, sender).slice(1)}`

/** The main session's refusal: show Dan the message as Slack will post it, then ask. */
export const refusal = (id: string, file: string, added: string[], removed: string[], sender?: string): string =>
  `${blocked(file, added, removed, sender)}. Every new Slack alert's wording waits until Dan approves it. Show him the whole message as Slack will post it, with every variable filled in from a realistic example (real looking names, numbers and links, never a placeholder), then ask him with AskUserQuestion, carrying metadata {"source": "${SOURCE}:${id}", "rendered": "<that message>"} and no answers filled in. The guard words the question. Send this call again, unchanged, once he answers ${APPROVE}.`

/** A subagent's refusal: it may not ask Dan, so it stops and reports. */
export const agentRefusal = (id: string, file: string, added: string[], removed: string[], sender?: string): string =>
  `${blocked(file, added, removed, sender)}. Slack alert wording waits on Dan's approval, which only the main session can ask for. Stop and report to the main session that call ${id} waits on Dan approving this wording, with the message as Slack will post it, every variable filled in from a realistic example.`

/**
 * The question Dan is asked, with the message itself in it. Approving posts nothing: it only lets
 * the held edit through, so the question never asks to post (claude-config#2284).
 */
export const question = (file: string, rendered: string): string =>
  `Approve the wording of an automated Slack alert defined in ${file}? Approving sends nothing: it only lets the held edit to that file go ahead.\n\n${rendered}`
