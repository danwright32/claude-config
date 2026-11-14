// The Slack alert guard's rules (claude-config#2242), pure: what counts as a file that posts to
// Slack, what in it is message text a person reads, and what an edit changes of that text. Dan,
// 2026-11-04: "anytime a slack alert is created, we need to have a design-rounds esque check on
// wording so I can approve the wording before it's created".
//
// Decisions given with the issue:
// 1. What counts: an edit whose changed text carries message text, in a file that posts to Slack,
//    recognised by a Slack posting marker in the file's own code (isSender). Only that file
//    (#2837; Dan, 2026-11-12: "I'd much rather an alert get posted to slack that I didn't approve
//    than deal with stopping every 2 seconds to approve wording that nobody will ever see"): a
//    template another file sends (#2248), a module a sender imports (#2570, #2637), a module of
//    message copy nothing sends yet (#2720) and a folder a copy lands in (#2773) all pass, and no
//    other file in the repository is searched.
// 2. Approval is for exact wording (L64): any change to approved text is held again, and a change
//    to an alert file that touches no message text passes unasked.
// 3. Approval is keyed to the wording, never the file (wordingKey), so the same wording approved in
//    one file goes through in another.
//
// Narrowed to text a Slack send builds (#2361, #2364, #2290, #2287; Dan, 2026-11-06, reversing the
// earlier "no file is exempted" in decision 3): a test file (testFile) and a doc send nothing, and
// is never a sender; a string handed to a query builder call, a select list, or a code template is
// not message text (stringsOf, isMessage); a file in no git repository, as a scratchpad script is,
// posts nothing.
//
// Narrowed to text a Slack send carries (#2570; Dan, 2026-11-09: "these aren't alerts that are going
// to fire into Slack, right? If not, I don't need you to ask me for approval"): in a JavaScript,
// TypeScript or python file, a changed string is held only when sends.ts traces it to one of the
// file's own send calls. A file whose send cannot be traced (any other language, a send the reading
// cannot find) is held for all the wording it changes. A python docstring is never message text
// (#2574). In a shell script, a string only an echo or printf to the error stream prints passes
// (#2792, shellLogWording).
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

import type { SlackAlertSend } from '../types/index.d.ts'

export const GUARD = 'Slack alert guard'
export const SOURCE = 'slack-alert-guard'
export const HEADER = 'Slack alert'
export const APPROVE = 'Approve wording'
export const CHANGE = 'Change wording'
/**
 * How long each git call the guard makes may take: naming a file's repository, and reading the
 * other uses of a model prompt (#2475). Claude Code kills a hook that runs past HookBudget.ms, 10 s
 * (tools/typescript/claude-code-types/claude-code/index.d.ts), so 7 s leaves 3 s to build and
 * return the refusal.
 */
export const SCAN_MS = 7000

/** Why a call is held when the guard could not check it, the failure in its own words. */
export const cannotCheck = (why: string) =>
  `Blocked: the Slack alert guard could not check this call (${why}), so it is held rather than let through unchecked. Try it again; if it keeps failing, tell Dan what failed.`
/**
 * Why a call is held when the guard ran out of time checking it (#2792): said as a timeout, never as
 * a refusal, with when to send it again and when to stop. On 2026-11-11, at load average 60 to 200,
 * the could not check answer read as a refusal and agents sent the same call up to six times.
 */
export const outOfTime = (why: string) =>
  `This is a timeout, not a refusal: the Slack alert guard ran out of time before it could check this call (${why}), so the call did not run, nothing in it was judged, and nothing waits on Dan. It happens when the Mac is heavily loaded. Send the same call again in about a minute; if it runs out of time three times in a row, stop and tell Dan the Slack alert guard could not finish checking it.`
/**
 * What a call is told when the guard's hook failed (`next.error`, the engine's HookFailure): a hook
 * Claude Code cut off for running past its time is a timeout; any other failure is could not check,
 * in `said`, the failure's own words.
 */
export const hookFailed = (failure: unknown, said: string): string =>
  !!failure && typeof failure === 'object' && (failure as { kind?: unknown }).kind === 'timeout'
    ? outOfTime('the check took longer than Claude Code gives a hook')
    : cannotCheck(said)
/**
 * The most files read for the other uses of a model prompt (#2475) before the prompt counts as
 * wording, held as any other. 500 is more than twice the most a real search read (#2510: 213 in
 * NurseDex, about 8 ms a file), so it still ends well inside SCAN_MS.
 */
export const MOST_READ = 500

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
 * Slack marker reads this. A `#` or `//` inside a
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

/** A word escaped for a regular expression, as nameRe matches a name. */
const escapeRe = (s: string): string => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

// The extensions one JavaScript or TypeScript import may name the same file by.
const JS = new Set(['ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs', 'mts', 'cts'])
/** Whether a file is JavaScript or TypeScript, whose single and double quotes fill nothing in. */
export const isJs = (path: string): boolean => {
  const e = extOf(path)
  return e !== undefined && JS.has(e)
}
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

/** One command of a shell script as mod-kit's reader gives it ($.modkit.pipeline), of it what a log line is judged by. */
export type ShellCommand = { words: string[]; pipedFrom?: string[]; heredocs?: unknown; substitution?: true; derived?: unknown[] }

// A word of a command that is a redirect, as mod-kit's reader gives one (a word of its own): an
// optional descriptor or &, then > or <.
const isRedirect = (word: string): boolean => /^(?:\d+|&)?[<>]/.test(word)

/**
 * The strings of a shell script that only a log can read (#2792), by their text: each one whose
 * every place in the script is a whole argument of an echo or printf whose output goes to the error
 * stream and nowhere else (`echo "..." >&2`, `>&2 echo "..."`), alone, after a test, or in a branch
 * or a group. The guard follows no send in a shell script, so until this every string in one that
 * posts was held, a log line included. `commands` is the script as mod-kit's reader gives it
 * ($.modkit.pipeline: this file reads no shell itself, #712), `literals` the text of each string in
 * it, once per place.
 *
 * Never a log, since each can carry the text to a send: standard output (a caller may capture it), a
 * pipe, a file, a variable (`printf -v`), any other command, a command inside a substitution, a string that runs
 * a command itself (`$(...)`, backticks), a line of a heredoc's body, and any line of a script that
 * points its own error stream somewhere (exec with a redirect) or opens a heredoc that never ends,
 * which takes every line after it. A string in one log line and anywhere else is no log either: a
 * text is one only when the log lines carry it as many times as the script holds it. The gap,
 * decided with the rule: a caller that joins the error stream of the function a log line is in to
 * what it posts (`tell 2>&1 | curl ...`) is not followed.
 */
export const shellLogWording = (commands: ShellCommand[], literals: string[]): Set<string> => {
  const out = new Set<string>()
  const opensHeredoc = (word: string) => /^\d*<</.test(word) && !/^\d*<<</.test(word)
  // The reader gives `exec 2> f` as its redirects alone, exec being a launcher it reads through, so
  // a command that is only redirects is the script pointing its own streams somewhere.
  const ownStreams = (c: ShellCommand) => c.words.some(isRedirect) && (c.words.every(isRedirect) || c.words.find(w => !isRedirect(w)) === 'exec')
  if (commands.some(c => ownStreams(c) || (!c.heredocs && c.words.some(opensHeredoc)))) return out
  const key = (words: string[]) => words.join('\u0000')
  const fed = new Set(commands.flatMap(c => (c.pipedFrom ? [key(c.pipedFrom)] : [])))
  const logged = new Map<string, number>()
  for (const c of commands) {
    const redirects = c.words.filter(isRedirect)
    const [program, ...told] = c.words.filter(w => !isRedirect(w))
    if (program !== 'echo' && program !== 'printf') continue
    // printf -v sets a variable instead of printing, and a variable can be posted later.
    if (program === 'printf' && told.some(w => /^-[^-]*v/.test(w))) continue
    if (!redirects.length || !redirects.every(r => /^1?>&2$/.test(r))) continue
    if (c.substitution || c.heredocs || c.derived?.some(d => d) || fed.has(key(c.words))) continue
    if (told.some(w => w.includes('$(') || w.includes('`'))) continue
    for (const w of told) logged.set(w, (logged.get(w) ?? 0) + 1)
  }
  const held = new Map<string, number>()
  for (const l of literals) held.set(l, (held.get(l) ?? 0) + 1)
  for (const [text, places] of held) if ((logged.get(text) ?? 0) >= places) out.add(text)
  return out
}

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
/** Whether a shell command names the plugin store, where any write the reader cannot place is refused (writesOwnRecord). */
export const mentionsStore = (text: string): boolean => /plugins\/store/.test(text)

/** A place a shell command writes or changes, as mod-kit's write reader gives it. */
type Placed = { path?: string }
/**
 * Whether a shell command, as mod-kit's write reader reads it, can write this mod's own record
 * (#2904): any file it writes, changes or has git change is the record, in any command; and in a
 * command naming the store, any place it reaches is the store folder or a folder holding it (a
 * removal, a move or a copy onto it), or anything it writes cannot be named: a path the reader could
 * not resolve, a program, xargs, a patch, or a script handed arguments. A listing, a search or a read
 * of the store writes nothing, so it passes.
 */
export const writesOwnRecord = (
  w: { files: Placed[]; changes: Placed[]; byGit?: Placed[]; unnamed: unknown[]; runs?: unknown[] },
  home: string,
  named: boolean,
): boolean => {
  const placed = [...w.files, ...w.changes, ...(w.byGit ?? [])]
  if (placed.some(p => p.path !== undefined && isOwnRecord(p.path))) return true
  if (!named) return false
  const store = `${home}/.claude/plugins/store`
  const holdsStore = (path: string): boolean => {
    const p = path.replace(/\/+$/, '')
    return /\/plugins\/store$/.test(p) || (p !== '' && store.startsWith(`${p}/`))
  }
  return placed.some(p => p.path === undefined || holdsStore(p.path)) || w.unnamed.length > 0 || (w.runs ?? []).length > 0
}

const listed = (xs: string[]): string => xs.map(x => `"${x}"`).join(', ')

/** What changes, in the words the refusal and card name it by. */
export const changeText = (added: string[], removed: string[]): string =>
  added.length ? `adds Slack message text Dan has not approved: ${listed(added)}` : `takes Slack message text away: ${listed(removed)}`

/** Why held text's send could not be traced, so all the file's new wording was held (#2586). */
export const UNTRACED_LANGUAGE = 'it follows sends only in JavaScript, TypeScript and python'
export const UNTRACED_EDIT = 'the edit does not match the file as it is now'
export const UNTRACED_NONE = 'it found no send call in the file that it could follow'

/**
 * Where the held text goes (#2586): the sends of the file it reaches, by what each calls and its
 * line, or, held without one being found, that none could be traced and why, never a send it did not
 * find (L11). Text taken away reached its send in the file as it was.
 */
const sendText = (file: string, removing: boolean, send: SlackAlertSend): string => {
  if ('untraced' in send) return `; the guard could not trace which Slack send in it carries this text, because ${send.untraced}`
  if (!send.sends.length) return ''
  const each = send.sends.map(s => `${s.callee} on line ${s.line}`)
  const named = each.length === 1 ? `send ${each[0]}` : `sends ${each.slice(0, -1).join(', ')} and ${each.at(-1)}`
  return `, which ${removing ? 'reached' : 'reaches'} the Slack ${named} of ${file}`
}

/**
 * What is held, as the card and both refusals open: always a file that posts to Slack by itself
 * (#2837), with the send its text reaches (#2586). A shell command carries no wording the guard can
 * read before it runs, so it is named as that rather than as an empty list taken away.
 */
export const heldText = (file: string, added: string[], removed: string[], send?: SlackAlertSend): string =>
  added.length || removed.length
    ? `This edit to ${file} ${changeText(added, removed)}${send ? sendText(file, !added.length, send) : ''}`
    : `This shell command writes to ${file}, which posts to Slack, and the wording it leaves cannot be read until it runs`

export const blocked = (file: string, added: string[], removed: string[], send?: SlackAlertSend): string => `Blocked: t${heldText(file, added, removed, send).slice(1)}`

/** The main session's refusal: show Dan the message as Slack will post it, then ask. */
export const refusal = (id: string, file: string, added: string[], removed: string[], send?: SlackAlertSend): string =>
  `${blocked(file, added, removed, send)}. Every new Slack alert's wording waits until Dan approves it. Show him the whole message as Slack will post it, with every variable filled in from a realistic example (real looking names, numbers and links, never a placeholder), then ask him with AskUserQuestion, carrying metadata {"source": "${SOURCE}:${id}", "rendered": "<that message>"} and no answers filled in. The guard words the question. Send this call again, unchanged, once he answers ${APPROVE}.`

/** A subagent's refusal: it may not ask Dan, so it stops and reports. */
export const agentRefusal = (id: string, file: string, added: string[], removed: string[], send?: SlackAlertSend): string =>
  `${blocked(file, added, removed, send)}. Slack alert wording waits on Dan's approval, which only the main session can ask for. Stop and report to the main session that call ${id} waits on Dan approving this wording, with the message as Slack will post it, every variable filled in from a realistic example.`

/**
 * The question Dan is asked, with the message itself in it. Approving posts nothing: it only lets
 * the held edit through, so the question never asks to post (claude-config#2284).
 */
export const question = (file: string, rendered: string): string =>
  `Approve the wording of an automated Slack alert defined in ${file}? Approving sends nothing: it only lets the held edit to that file go ahead.\n\n${rendered}`
