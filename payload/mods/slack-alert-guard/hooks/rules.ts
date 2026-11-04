// The Slack alert guard's rules (claude-config#2242), pure: what counts as a file that posts to
// Slack, what in it is message text a person reads, and what an edit changes of that text. Dan,
// 2026-11-04: "anytime a slack alert is created, we need to have a design-rounds esque check on
// wording so I can approve the wording before it's created".
//
// Decisions given with the issue:
// 1. What counts: an edit whose changed text carries message text, in a file that posts to Slack,
//    recognised by a Slack posting marker in the file (slackMarked). A template with no marker in
//    its own file is outside this guard.
// 2. Approval is for exact wording (L64): any change to approved text is held again, and a change
//    to an alert file that touches no message text passes unasked.
// 3. Approval is keyed to the wording, never the file (wordingKey), so a test repeating wording Dan
//    already approved goes through, and a test carrying wording he has not seen is held. No file is
//    exempted.

export const GUARD = 'Slack alert guard'
export const SOURCE = 'slack-alert-guard'
export const HEADER = 'Slack alert'
export const APPROVE = 'Approve wording'
export const CHANGE = 'Change wording'

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

// Each marker is written so this file's own source does not match it: a dot or underscore escaped
// or in a class, so the guard's rules are not themselves read as a Slack poster.
const MARKERS: RegExp[] = [
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
export const literalsOf = (text: string, hash: boolean): string[] => {
  const tokens = hash
    ? /#[^\n]*|"((?:\\[\s\S]|[^"\\])*)"|'((?:\\[\s\S]|[^'\\\n])*)'|`((?:\\[\s\S]|[^`\\])*)`/g
    : /\/\/[^\n]*|\/\*[\s\S]*?\*\/|"((?:\\[\s\S]|[^"\\\n])*)"|'((?:\\[\s\S]|[^'\\\n])*)'|`((?:\\[\s\S]|[^`\\])*)`/g
  const out: string[] = []
  for (const m of text.matchAll(tokens)) {
    const body = m[1] ?? m[2] ?? m[3]
    if (body !== undefined) out.push(unescape(body))
  }
  return out
}

/** A YAML file's plain (unquoted) values, each line's text after its key or list mark; quoted ones are read by literalsOf. */
export const plainYamlValues = (text: string): string[] => {
  const out: string[] = []
  for (const line of text.split('\n')) {
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

/** Whether a string reads as text a person reads: two words, or a word beside a filled in value; never a key, a path, a URL or a class list. */
export const isProse = (s: string): boolean => {
  const words = s.replace(FILLED, ' \u0000 ').split(/\s+/).filter(Boolean)
  return words.length >= 2 && words.some(w => WORD.test(w))
}

/** The message text among a file's literals, each kept as often as it appears. */
export const wordingOf = (literals: string[]): string[] => literals.filter(isProse)

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
/** Where his approval of one shell call is kept: by its folder and its whole command. */
export const shellKey = (cwd: string, command: string): string => `shell:${hash(JSON.stringify([cwd, command]))}`

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
 */
export const renderedProblem = (rendered: unknown, added: string[]): string | undefined => {
  if (typeof rendered !== 'string' || !rendered.trim())
    return 'Give metadata "rendered": the message exactly as Slack will post it, every variable filled in from a realistic example.'
  const left = PLACEHOLDER.exec(rendered)?.[0]
  if (left !== undefined) return `The message shown still has ${left} in it: fill every variable in from a realistic example, so Dan reads the message as Slack will post it.`
  const shown = norm(rendered)
  for (const s of added)
    for (const part of s.split(FILLED).map(norm))
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
 * can read before it runs, so it is named as that rather than as an empty list taken away.
 */
export const heldText = (file: string, added: string[], removed: string[]): string =>
  added.length || removed.length
    ? `This edit to ${file} ${changeText(added, removed)}`
    : `This shell command writes to ${file}, which posts to Slack, and the wording it leaves cannot be read until it runs`

const blocked = (file: string, added: string[], removed: string[]): string => `Blocked: t${heldText(file, added, removed).slice(1)}`

/** The main session's refusal: show Dan the message as Slack will post it, then ask. */
export const refusal = (id: string, file: string, added: string[], removed: string[]): string =>
  `${blocked(file, added, removed)}. Every new Slack alert's wording waits until Dan approves it. Show him the whole message as Slack will post it, with every variable filled in from a realistic example (real looking names, numbers and links, never a placeholder), then ask him with AskUserQuestion, carrying metadata {"source": "${SOURCE}:${id}", "rendered": "<that message>"} and no answers filled in. The guard words the question. Send this call again, unchanged, once he answers ${APPROVE}.`

/** A subagent's refusal: it may not ask Dan, so it stops and reports. */
export const agentRefusal = (id: string, file: string, added: string[], removed: string[]): string =>
  `${blocked(file, added, removed)}. Slack alert wording waits on Dan's approval, which only the main session can ask for. Stop and report to the main session that call ${id} waits on Dan approving this wording, with the message as Slack will post it, every variable filled in from a realistic example.`

/** The question Dan is asked, with the message itself in it. */
export const question = (file: string, rendered: string): string => `Post this Slack message from ${file}?\n\n${rendered}`
